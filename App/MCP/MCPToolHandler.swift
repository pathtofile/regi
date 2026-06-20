import Foundation
import JetKVMProtocol
import JetKVMTransport
import OSLog

private let log = Logger(subsystem: "app.regi.mac", category: "mcp-tools")

/// Error thrown by tool implementations. Reported back to the LLM as
/// tool-level errors (isError: true) rather than JSON-RPC protocol errors.
struct MCPToolError: Error {
    let message: String
    static func unknown(_ msg: String) -> MCPToolError { .init(message: msg) }
    static func noSession(_ msg: String = "Not connected. Call 'connect' first.") -> MCPToolError { .init(message: msg) }
}

/// Implements all 10 MCP tools. Tools operate on whichever GUI window's
/// `Session` is active (resolved per-call from `SessionRegistry`), so the
/// LLM drives the same connection the human watches. Holds weak
/// references so it doesn't extend their lifetimes.
@MainActor
final class MCPToolHandler {
    weak var registry: SessionRegistry?
    weak var frameCapture: MCPFrameCapture?
    weak var hostStore: HostStore?
    weak var discovery: DeviceDiscovery?
    /// Opens (or raises) a KVM session window so the user can watch what
    /// the LLM does. Forwards to SwiftUI's `openWindow(value:)`.
    let openWindow: (KVMSessionWindowID) -> Void

    init(
        registry: SessionRegistry,
        frameCapture: MCPFrameCapture,
        hostStore: HostStore,
        discovery: DeviceDiscovery,
        openWindow: @escaping (KVMSessionWindowID) -> Void
    ) {
        self.registry = registry
        self.frameCapture = frameCapture
        self.hostStore = hostStore
        self.discovery = discovery
        self.openWindow = openWindow
    }

    /// The `Session` the LLM drives right now — the active window's.
    /// Throws a clear "connect first" error when no window is open.
    private func requireSession() throws -> Session {
        guard let session = registry?.targetSession else { throw MCPToolError.noSession() }
        return session
    }

    // MARK: - Dispatch

    func call(name: String, input: [String: Any]) async throws -> [[String: Any]] {
        switch name {
        case "screenshot":   return try await toolScreenshot(input)
        case "key":          return try await toolKey(input)
        case "type":         return try await toolType(input)
        case "mouse_move":   return try toolMouseMove(input)
        case "mouse_click":  return try await toolMouseClick(input)
        case "mouse_scroll": return try toolMouseScroll(input)
        case "connect":      return try await toolConnect(input)
        case "disconnect":   return try await toolDisconnect()
        case "list_hosts":   return toolListHosts()
        case "get_status":   return toolGetStatus()
        default:
            throw MCPToolError.unknown("Unknown tool: \(name)")
        }
    }

    // MARK: - Tool: screenshot

    private func toolScreenshot(_ input: [String: Any]) async throws -> [[String: Any]] {
        guard let fc = frameCapture else { throw MCPToolError.noSession() }
        let quality = input["quality"] as? Int ?? 65
        let maxWidth = input["maxWidth"] as? Int ?? 1280
        guard let jpeg = fc.captureJPEG(quality: quality, maxWidth: maxWidth) else {
            throw MCPToolError.noSession("No video frame available. Connect first and wait for video.")
        }
        return [["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]]
    }

    // MARK: - Tool: key

    private func toolKey(_ input: [String: Any]) async throws -> [[String: Any]] {
        let session = try requireSession()
        guard let combo = input["combo"] as? String else {
            throw MCPToolError.unknown("'combo' parameter required")
        }
        let count = max(1, input["count"] as? Int ?? 1)
        let (modifiers, key) = try MCPKeyInput.parseCombo(combo)

        for _ in 0..<count {
            for mod in modifiers { session.sendKeypress(virtualKeyCode: mod, pressed: true) }
            session.sendKeypress(virtualKeyCode: key, pressed: true)
            try await Task.sleep(for: .milliseconds(50))
            session.sendKeypress(virtualKeyCode: key, pressed: false)
            for mod in modifiers.reversed() { session.sendKeypress(virtualKeyCode: mod, pressed: false) }
            if count > 1 { try await Task.sleep(for: .milliseconds(80)) }
        }
        let mods = modifiers.isEmpty ? "" : "(with modifiers) "
        return [text("Key \(mods)'\(combo)' sent\(count > 1 ? " ×\(count)" : "")")]
    }

    // MARK: - Tool: type

    private func toolType(_ input: [String: Any]) async throws -> [[String: Any]] {
        let session = try requireSession()
        guard let str = input["text"] as? String else {
            throw MCPToolError.unknown("'text' parameter required")
        }
        var typed = 0
        let shiftKC: UInt16 = 0x38
        for char in str {
            guard let (kc, needsShift) = MCPKeyInput.charKeyMap[char] else {
                log.debug("type: no keycode for '\(char)' — skipping")
                continue
            }
            if needsShift { session.sendKeypress(virtualKeyCode: shiftKC, pressed: true) }
            session.sendKeypress(virtualKeyCode: kc, pressed: true)
            try await Task.sleep(for: .milliseconds(30))
            session.sendKeypress(virtualKeyCode: kc, pressed: false)
            if needsShift { session.sendKeypress(virtualKeyCode: shiftKC, pressed: false) }
            try await Task.sleep(for: .milliseconds(20))
            typed += 1
        }
        return [text("Typed \(typed) character(s)")]
    }

    // MARK: - Tool: mouse_move

    private func toolMouseMove(_ input: [String: Any]) throws -> [[String: Any]] {
        let session = try requireSession()
        let (nx, ny) = try normalizeCoords(input)
        session.sendPointerMotion(normalizedX: nx, normalizedY: ny, buttons: [])
        return [text("Mouse moved to (\(nx), \(ny))")]
    }

    // MARK: - Tool: mouse_click

    private func toolMouseClick(_ input: [String: Any]) async throws -> [[String: Any]] {
        let session = try requireSession()
        let (nx, ny) = try normalizeCoords(input)
        let buttonStr = input["button"] as? String ?? "left"
        let doubleClick = input["doubleClick"] as? Bool ?? false
        let btn = mouseButton(from: buttonStr)

        let clicks = doubleClick ? 2 : 1
        for i in 0..<clicks {
            if i > 0 { try await Task.sleep(for: .milliseconds(80)) }
            session.sendPointerButtonChange(normalizedX: nx, normalizedY: ny, buttons: btn)
            try await Task.sleep(for: .milliseconds(80))
            session.sendPointerButtonChange(normalizedX: nx, normalizedY: ny, buttons: [])
        }
        return [text("\(doubleClick ? "Double-clicked" : "Clicked") \(buttonStr) at (\(nx), \(ny))")]
    }

    // MARK: - Tool: mouse_scroll

    private func toolMouseScroll(_ input: [String: Any]) throws -> [[String: Any]] {
        let session = try requireSession()
        let dy = input["dy"] as? Int ?? input["deltaY"] as? Int ?? 0
        let dx = input["dx"] as? Int ?? input["deltaX"] as? Int ?? 0
        let wheelY = Int8(clamping: dy)
        let wheelX = Int8(clamping: dx)
        session.sendWheelReport(wheelY: wheelY, wheelX: wheelX)
        return [text("Scrolled dy=\(dy) dx=\(dx)")]
    }

    // MARK: - Tool: connect

    private func toolConnect(_ input: [String: Any]) async throws -> [[String: Any]] {
        guard let registry else { throw MCPToolError.unknown("Session registry unavailable") }

        let nameParam = input["name"] as? String
        let hostParam = input["host"] as? String
        let portParam = input["port"] as? Int ?? 80
        let useTLS    = input["useTLS"] as? Bool ?? (portParam == 443)
        let kindStr   = input["kind"] as? String ?? "jetkvm"
        let username  = input["username"] as? String ?? "admin"

        // Resolve the target window identity from a saved host or a raw
        // address. The window connects itself (loading the saved keychain
        // password), so we don't build/own a connection here.
        let id: KVMSessionWindowID
        let resolvedHost: String
        if let saved = findSavedHost(name: nameParam, host: hostParam) {
            id = KVMSessionWindowID(saved: saved)
            resolvedHost = saved.displayName
        } else if let hostParam {
            let kind: DeviceKind = kindStr.lowercased() == "pikvm" ? .piKVM : .jetKVM
            let endpoint = DeviceEndpoint(
                host: hostParam,
                port: portParam,
                useTLS: useTLS,
                kind: kind,
                username: kind == .piKVM ? username : nil
            )
            id = KVMSessionWindowID(displayName: hostParam, endpoint: endpoint)
            resolvedHost = hostParam
        } else {
            throw MCPToolError.unknown("Provide 'host' or 'name' parameter. Use list_hosts to see options.")
        }

        // Open (or raise) the window the user watches, and bind MCP to it.
        // Reusing an already-open window just brings it forward.
        registry.setMCPActive(true)
        openWindow(id)

        // The window's `.task` registers its session and connects. Poll
        // until it reaches a terminal-ish state or times out (~10s).
        for _ in 0..<100 {
            if let session = registry.session(for: id) {
                registry.setActive(id)
                switch session.state {
                case .connected:
                    return [text("Connected to \(resolvedHost) — sharing the window you're watching.")]
                case .awaitingPassword:
                    return [text("Password required for \(resolvedHost). Save its password in Regi, then reconnect.")]
                case .awaitingTrustOverride(let host, _):
                    return [text("TLS certificate for \(host) not trusted. Trust this host in Regi first.")]
                case .failed(let msg):
                    throw MCPToolError.unknown("Connection failed: \(msg)")
                default:
                    break
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return [text("Connecting to \(resolvedHost)... Use get_status to check progress.")]
    }

    // MARK: - Tool: disconnect

    private func toolDisconnect() async throws -> [[String: Any]] {
        // Release the LLM from driving, but leave the window open and
        // connected so the human keeps watching. (The single shared
        // session is the user's — tearing it down would yank their view.)
        registry?.setMCPActive(false)
        return [text("Released — your window stays connected.")]
    }

    // MARK: - Tool: list_hosts

    private func toolListHosts() -> [[String: Any]] {
        var lines: [String] = []

        if let hosts = hostStore?.hosts, !hosts.isEmpty {
            lines.append("Saved hosts:")
            for h in hosts {
                lines.append("  • \(h.displayName) (\(h.kind.displayName)) — \(h.urlString)")
            }
        } else {
            lines.append("No saved hosts.")
        }

        if let discovered = discovery?.hosts, !discovered.isEmpty {
            lines.append("\nDiscovered hosts (mDNS):")
            for h in discovered {
                let scheme = h.useTLS ? "https" : "http"
                let portStr = (h.useTLS && h.port == 443) || (!h.useTLS && h.port == 80)
                    ? "" : ":\(h.port)"
                lines.append("  • \(h.displayName) (\(h.kind.displayName)) — \(scheme)://\(h.host)\(portStr)")
            }
        }

        if lines.isEmpty { lines.append("No hosts found.") }
        return [text(lines.joined(separator: "\n"))]
    }

    // MARK: - Tool: get_status

    private func toolGetStatus() -> [[String: Any]] {
        guard let session = registry?.targetSession else {
            return [text("No active session. Call 'connect' to open a window first.")]
        }

        var parts: [String] = []
        parts.append("State: \(stateDescription(session.state))")

        if let stats = session.latestStats {
            if let rtt = stats.roundTripTimeMs { parts.append("Latency: \(Int(rtt))ms") }
            parts.append("FPS: \(Int(stats.framesPerSecond))")
            if let bps = stats.bitrateBitsPerSecond { parts.append("Bitrate: \(Int(bps / 1000))kbps") }
            if let codec = stats.codec { parts.append("Codec: \(codec)") }
        }

        if let fc = frameCapture, fc.currentSize.width > 0 {
            let w = Int(fc.currentSize.width)
            let h = Int(fc.currentSize.height)
            parts.append("Video: \(w)×\(h)")
        }

        return [text(parts.joined(separator: " | "))]
    }

    // MARK: - Tool definitions (for tools/list response)

    static let toolDefinitions: [[String: Any]] = [
        makeTool("screenshot",
                 description: "Capture the current remote screen as a JPEG image. Returns base64-encoded image data.",
                 properties: [
                    "quality": ["type": "integer", "description": "JPEG quality 1–100 (default 65)", "default": 65],
                    "maxWidth": ["type": "integer", "description": "Max width in pixels; 0 for full res (default 1280)", "default": 1280],
                 ]),
        makeTool("key",
                 description: "Press a key or key combination. Examples: 'ctrl+c', 'cmd+space', 'enter', 'f5', 'ctrl+alt+delete'.",
                 properties: [
                    "combo": ["type": "string", "description": "Key combo. Modifiers: ctrl, shift, alt/option, cmd/meta. Keys: W3C code names or shortcuts like enter, esc, tab, space, backspace, delete, up/down/left/right, f1–f12."],
                    "count": ["type": "integer", "description": "Repeat count (default 1)", "default": 1],
                 ],
                 required: ["combo"]),
        makeTool("type",
                 description: "Type a string of text on the remote machine using synthesized keypresses (US QWERTY layout).",
                 properties: [
                    "text": ["type": "string", "description": "Text to type"],
                 ],
                 required: ["text"]),
        makeTool("mouse_move",
                 description: "Move the mouse to a position on the remote screen.",
                 properties: [
                    "x": ["type": "number", "description": "Horizontal position as a fraction of screen width (0.0 = left, 1.0 = right)"],
                    "y": ["type": "number", "description": "Vertical position as a fraction of screen height (0.0 = top, 1.0 = bottom)"],
                 ],
                 required: ["x", "y"]),
        makeTool("mouse_click",
                 description: "Click the mouse at a position on the remote screen.",
                 properties: [
                    "x": ["type": "number", "description": "Horizontal fraction (0.0–1.0)"],
                    "y": ["type": "number", "description": "Vertical fraction (0.0–1.0)"],
                    "button": ["type": "string", "enum": ["left", "right", "middle"], "description": "Mouse button (default 'left')"],
                    "doubleClick": ["type": "boolean", "description": "Send a double-click (default false)"],
                 ],
                 required: ["x", "y"]),
        makeTool("mouse_scroll",
                 description: "Scroll the mouse wheel at the current cursor position.",
                 properties: [
                    "dy": ["type": "integer", "description": "Vertical scroll (positive = up, negative = down)"],
                    "dx": ["type": "integer", "description": "Horizontal scroll (default 0)"],
                 ],
                 required: ["dy"]),
        makeTool("connect",
                 description: "Open (or focus) a KVM window and drive it — you and the user share one connection, both watching and controlling the same machine. Provide 'name' to match a saved host by display name, or 'host' for a raw address. The password is loaded from the saved keychain entry.",
                 properties: [
                    "name": ["type": "string", "description": "Saved host display name (partial match)"],
                    "host": ["type": "string", "description": "Hostname or IP address"],
                    "port": ["type": "integer", "description": "Port (default 80)"],
                    "useTLS": ["type": "boolean", "description": "Use HTTPS/WSS (default false)"],
                    "kind": ["type": "string", "enum": ["jetkvm", "pikvm"], "description": "Device family (default 'jetkvm')"],
                    "username": ["type": "string", "description": "Login username for PiKVM (default 'admin')"],
                 ]),
        makeTool("disconnect",
                 description: "Stop driving the KVM session. The user's window stays open and connected — this only releases your control.",
                 properties: [:]),
        makeTool("list_hosts",
                 description: "List saved and mDNS-discovered KVM hosts available to connect to.",
                 properties: [:]),
        makeTool("get_status",
                 description: "Get the current session state, video dimensions, latency, FPS, and codec.",
                 properties: [:]),
    ]

    // MARK: - Helpers

    private func normalizeCoords(_ input: [String: Any]) throws -> (Int32, Int32) {
        guard let rawX = input["x"].flatMap({ $0 as? Double }) ?? (input["x"] as? NSNumber)?.doubleValue,
              let rawY = input["y"].flatMap({ $0 as? Double }) ?? (input["y"] as? NSNumber)?.doubleValue else {
            throw MCPToolError.unknown("'x' and 'y' parameters required (0.0–1.0)")
        }
        let nx = Int32(max(0.0, min(1.0, rawX)) * 32767)
        let ny = Int32(max(0.0, min(1.0, rawY)) * 32767)
        return (nx, ny)
    }

    private func mouseButton(from str: String) -> MouseButtons {
        switch str.lowercased() {
        case "right":  return .right
        case "middle": return .middle
        default:       return .left
        }
    }

    private func findSavedHost(name: String?, host: String?) -> SavedHost? {
        guard let hosts = hostStore?.hosts else { return nil }
        if let name {
            return hosts.first { $0.displayName.localizedCaseInsensitiveContains(name) }
        }
        if let host {
            return hosts.first { $0.host.lowercased() == host.lowercased() }
        }
        return nil
    }

    private func stateDescription(_ state: Session.State) -> String {
        switch state {
        case .idle:               return "idle"
        case .connected:          return "connected"
        case .connecting(let ph): return "connecting (\(ph))"
        case .awaitingPassword:   return "awaiting_password"
        case .awaitingTrustOverride: return "awaiting_trust"
        case .reconnecting(let n): return "reconnecting (attempt \(n))"
        case .kicked:             return "kicked"
        case .failed(let msg):    return "failed: \(msg)"
        }
    }

    private func text(_ s: String) -> [String: Any] { ["type": "text", "text": s] }

    private static func makeTool(
        _ name: String,
        description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}
