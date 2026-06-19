import Foundation
import Network
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "mcp-sse")

/// One active MCP client connection. Owns the SSE `NWConnection` used to
/// push JSON-RPC responses back to the client. Receives request data from
/// `MCPHTTPServer` and dispatches tool calls to `MCPToolHandler`.
@MainActor
final class MCPSSESession {
    let id: UUID
    private let connection: NWConnection
    private let toolHandler: MCPToolHandler

    init(id: UUID, connection: NWConnection, toolHandler: MCPToolHandler) {
        self.id = id
        self.connection = connection
        self.toolHandler = toolHandler
    }

    // MARK: - Lifecycle

    /// Send the MCP endpoint event that tells the client where to POST.
    func sendEndpointEvent() {
        let event = "event: endpoint\ndata: /message?sessionId=\(id.uuidString)\n\n"
        send(raw: Data(event.utf8))
    }

    func close() {
        connection.cancel()
    }

    // MARK: - Request handling

    func handleRequest(_ data: Data) async {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            sendError(id: nil, code: -32700, message: "Parse error")
            return
        }

        let method = json["method"] as? String ?? ""
        let msgId  = json["id"]  // Any? — nil for notifications

        switch method {
        case "initialize":
            sendResult(id: msgId, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "Regi", "version": "1.0"],
            ])

        case "notifications/initialized", "notifications/cancelled":
            break  // no-op notifications

        case "tools/list":
            sendResult(id: msgId, result: ["tools": MCPToolHandler.toolDefinitions])

        case "tools/call":
            await handleToolCall(json, id: msgId)

        case "ping":
            sendResult(id: msgId, result: [:])

        default:
            if msgId != nil {
                sendError(id: msgId, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    // MARK: - Private

    private func handleToolCall(_ json: [String: Any], id: Any?) async {
        let params   = json["params"] as? [String: Any] ?? [:]
        let toolName = params["name"] as? String ?? ""
        let input    = params["arguments"] as? [String: Any] ?? [:]

        log.info("tools/call \(toolName, privacy: .public)")

        do {
            let content = try await toolHandler.call(name: toolName, input: input)
            sendResult(id: id, result: ["content": content])
        } catch let err as MCPToolError {
            // Tool-level error: return as content with isError flag
            sendResult(id: id, result: [
                "content": [["type": "text", "text": err.message]],
                "isError": true,
            ])
        } catch {
            sendResult(id: id, result: [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true,
            ])
        }
    }

    private func sendResult(id: Any?, result: [String: Any]) {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendError(id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id { response["id"] = id }
        sendJSON(response)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let frame = "event: message\ndata: \(jsonStr)\n\n"
        send(raw: Data(frame.utf8))
    }

    private func send(raw data: Data) {
        connection.send(content: data, completion: .contentProcessed { error in
            if let error { log.debug("SSE send error: \(error, privacy: .public)") }
        })
    }
}
