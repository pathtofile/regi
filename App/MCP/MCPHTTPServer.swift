import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "mcp-http")

/// Minimal HTTP+SSE server for the MCP transport layer.
///
/// Listens on localhost TCP. Each incoming connection is handled as a
/// coroutine using async/await-wrapped NWConnection calls. Supports two
/// endpoints:
///   GET /sse   — opens an SSE stream; creates an MCPSSESession
///   POST /message — receives a JSON-RPC request body and routes it to
///                   the matching SSE session (by ?sessionId= or header)
///
/// All callbacks land on `.main` because NWListener is started on
/// DispatchQueue.main and NWConnections are started on the same queue.
@MainActor
final class MCPHTTPServer {
    private var listener: NWListener?
    private var sseSessions: [UUID: MCPSSESession] = [:]
    private let toolHandler: MCPToolHandler
    var onSessionCountChanged: ((Int) -> Void)?

    init(toolHandler: MCPToolHandler) {
        self.toolHandler = toolHandler
    }

    // MARK: - Lifecycle

    func start(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind to loopback only
        let nwPort = NWEndpoint.Port(rawValue: port)!
        let nwListener = try NWListener(using: params, on: nwPort)
        nwListener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in
                await self?.handleNewConnection(conn)
            }
        }
        nwListener.stateUpdateHandler = { state in
            log.info("MCP listener state: \(String(describing: state), privacy: .public)")
        }
        nwListener.start(queue: .main)
        listener = nwListener
        log.info("MCP HTTP server started on port \(port, privacy: .public)")
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for session in sseSessions.values { session.close() }
        sseSessions.removeAll()
        onSessionCountChanged?(0)
        log.info("MCP HTTP server stopped")
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ conn: NWConnection) async {
        conn.start(queue: .main)

        guard let request = await readHTTPRequest(conn) else {
            conn.cancel()
            return
        }

        let path = String(request.path.split(separator: "?", maxSplits: 1).first ?? Substring(request.path))

        if request.method == "OPTIONS" {
            await writeResponse(conn, status: 204, extraHeaders: corsHeaders(), body: nil)
            conn.cancel()
            return
        }

        if request.method == "GET" && (path == "/sse" || path == "/") {
            await serveSSE(conn, request: request)
        } else if request.method == "POST" && path == "/message" {
            await serveMessage(conn, request: request)
        } else {
            await writeResponse(conn, status: 404, extraHeaders: corsHeaders(), body: nil)
            conn.cancel()
        }
    }

    private func serveSSE(_ conn: NWConnection, request: HTTPRequest) async {
        let sessionID = UUID()
        let headers = "HTTP/1.1 200 OK\r\n" +
            "Content-Type: text/event-stream\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: keep-alive\r\n" +
            "Access-Control-Allow-Origin: *\r\n\r\n"
        await writeRaw(conn, data: Data(headers.utf8))

        let session = MCPSSESession(id: sessionID, connection: conn, toolHandler: toolHandler)
        sseSessions[sessionID] = session
        onSessionCountChanged?(sseSessions.count)
        log.info("SSE session \(sessionID.uuidString.prefix(8), privacy: .public) opened")

        session.sendEndpointEvent()

        // Remove session when the connection closes
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.sseSessions.removeValue(forKey: sessionID)
                    self.onSessionCountChanged?(self.sseSessions.count)
                    log.info("SSE session \(sessionID.uuidString.prefix(8), privacy: .public) closed")
                }
            default: break
            }
        }
        // SSE connection stays open — do not cancel `conn` here.
    }

    private func serveMessage(_ conn: NWConnection, request: HTTPRequest) async {
        // Respond to the POST immediately (non-blocking for the client)
        await writeResponse(conn, status: 202, extraHeaders: corsHeaders(), body: nil)
        conn.cancel()

        guard !request.body.isEmpty else { return }

        // Route to matching SSE session
        let targetSession = findSession(from: request) ?? sseSessions.values.first
        if let targetSession {
            await targetSession.handleRequest(request.body)
        } else {
            log.warning("POST /message: no active SSE session to deliver to")
        }
    }

    // MARK: - HTTP reading (async/await over NWConnection callbacks)

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private func readHTTPRequest(_ conn: NWConnection) async -> HTTPRequest? {
        var buffer = Data()
        let headerSeparator = Data("\r\n\r\n".utf8)

        // Accumulate until we have the full header block
        while buffer.range(of: headerSeparator) == nil {
            let (chunk, done) = await receiveChunk(conn)
            buffer.append(chunk)
            if done { break }
        }

        guard let sepRange = buffer.range(of: headerSeparator) else { return nil }
        let headerData  = buffer[..<sepRange.lowerBound]
        var body        = Data(buffer[sepRange.upperBound...])

        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        let lines  = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts  = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key   = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        while body.count < contentLength {
            let (chunk, done) = await receiveChunk(conn)
            body.append(chunk)
            if done { break }
        }

        return HTTPRequest(
            method:  parts[0].uppercased(),
            path:    parts[1],
            headers: headers,
            body:    Data(body.prefix(contentLength))
        )
    }

    private func receiveChunk(_ conn: NWConnection) async -> (Data, Bool) {
        await withCheckedContinuation { cont in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, _ in
                cont.resume(returning: (data ?? Data(), isComplete))
            }
        }
    }

    // MARK: - HTTP writing

    private func writeResponse(
        _ conn: NWConnection,
        status: Int,
        extraHeaders: [String: String],
        body: Data?
    ) async {
        var head = "HTTP/1.1 \(status) \(httpStatusText(status))\r\n"
        for (k, v) in extraHeaders { head += "\(k): \(v)\r\n" }
        if let body { head += "Content-Length: \(body.count)\r\n" }
        head += "\r\n"
        var responseData = Data(head.utf8)
        if let body { responseData.append(body) }
        await writeRaw(conn, data: responseData)
    }

    private func writeRaw(_ conn: NWConnection, data: Data) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    // MARK: - Helpers

    private func corsHeaders() -> [String: String] {
        [
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, Mcp-Session-Id",
        ]
    }

    private func httpStatusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 404: return "Not Found"
        default:  return "Error"
        }
    }

    private func findSession(from request: HTTPRequest) -> MCPSSESession? {
        // 1. Mcp-Session-Id header
        if let header = request.headers["mcp-session-id"],
           let uuid = UUID(uuidString: header) {
            return sseSessions[uuid]
        }
        // 2. ?sessionId= query parameter
        if let query = request.path.split(separator: "?").dropFirst().first {
            let params = query.split(separator: "&").reduce(into: [String: String]()) { acc, pair in
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                if kv.count == 2 { acc[kv[0]] = kv[1] }
            }
            if let sid = params["sessionId"], let uuid = UUID(uuidString: sid) {
                return sseSessions[uuid]
            }
        }
        return nil
    }
}
