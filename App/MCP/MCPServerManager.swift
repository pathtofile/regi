import Foundation
import JetKVMTransport
import OSLog
import Observation
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "mcp-server")

/// Top-level MCP server owner. Holds the HTTP server, the frame
/// capturer, and the tool handler. MCP tools drive whichever GUI
/// window's `Session` is active (via `SessionRegistry`) rather than a
/// separate headless one — the JetKVM allows only one session per
/// device, so the human and the LLM must share a single peer connection.
///
/// Injected as an @Observable environment object from RegiApp so
/// HostsView can show live status without knowing implementation details.
@MainActor
@Observable
final class MCPServerManager {
    private(set) var isRunning = false
    private(set) var connectedClientCount = 0
    let port: UInt16 = 8765

    let frameCapture = MCPFrameCapture()

    /// Set by HostsView once the SwiftUI `openWindow` action is in
    /// scope. The `connect` tool calls this to open/raise the window the
    /// user watches. Read lazily at call time so it doesn't matter
    /// whether this or `start()` ran first.
    var openSessionWindow: ((KVMSessionWindowID) -> Void)?

    private var httpServer: MCPHTTPServer?
    private var toolHandler: MCPToolHandler?
    private var trackObserverTask: Task<Void, Never>?
    /// The video track the frame capturer is currently attached to, so
    /// `stop()` can detach cleanly.
    private var attachedTrack: RTCVideoTrack?

    // Populated by configure() once SwiftUI environment objects exist
    private weak var hostStore: HostStore?
    private weak var discovery: DeviceDiscovery?
    private weak var registry: SessionRegistry?

    // MARK: - Setup

    /// Wire up the environment objects. Call before `start()`.
    func configure(hostStore: HostStore, discovery: DeviceDiscovery, registry: SessionRegistry) {
        self.hostStore = hostStore
        self.discovery = discovery
        self.registry = registry
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard let hostStore, let discovery, let registry else {
            log.error("start() called before configure() — ignoring")
            return
        }

        let th = MCPToolHandler(
            registry: registry,
            frameCapture: frameCapture,
            hostStore: hostStore,
            discovery: discovery,
            openWindow: { [weak self] id in self?.openSessionWindow?(id) }
        )
        toolHandler = th

        let server = MCPHTTPServer(toolHandler: th)
        server.onSessionCountChanged = { [weak self] count in
            self?.connectedClientCount = count
        }

        do {
            try server.start(port: port)
        } catch {
            log.error("failed to start MCP HTTP server: \(error.localizedDescription, privacy: .public)")
            return
        }

        httpServer = server
        isRunning = true
        startTrackObserver()
        log.info("MCP server started on port \(self.port, privacy: .public)")
    }

    func stop() async {
        guard isRunning else { return }
        trackObserverTask?.cancel()
        trackObserverTask = nil
        // Stop driving the user's window, but don't tear it down — the
        // human keeps watching. Just detach our frame renderer.
        if let track = attachedTrack { frameCapture.detach(from: track) }
        attachedTrack = nil
        registry?.setMCPActive(false)
        httpServer?.stop()
        httpServer = nil
        toolHandler = nil
        isRunning = false
        connectedClientCount = 0
        log.info("MCP server stopped")
    }

    // MARK: - Video track observation

    /// Attach/detach the frame capturer whenever the *active window's*
    /// video track changes — when the user switches which session is
    /// frontmost, or when a track comes/goes. Uses withObservationTracking
    /// to re-register on each change, forming a lightweight reactive loop.
    ///
    /// The capturer is a SECOND renderer on the same RTCVideoTrack the
    /// GUI already renders, so the LLM's screenshots are the exact frames
    /// the human sees.
    private func startTrackObserver() {
        trackObserverTask?.cancel()
        trackObserverTask = Task { [weak self] in
            await self?.observeVideoTrack()
        }
    }

    private func observeVideoTrack() async {
        guard !Task.isCancelled else { return }
        var currentTrack: RTCVideoTrack?
        withObservationTracking {
            // Tracks both registry.activeID and that session's videoTrack.
            currentTrack = registry?.targetSession?.videoTrack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.observeVideoTrack()
            }
        }
        // Sync frame capturer if the track changed.
        if currentTrack !== attachedTrack {
            if let old = attachedTrack { frameCapture.detach(from: old) }
            if let new = currentTrack { frameCapture.attach(to: new) }
            attachedTrack = currentTrack
        }
    }
}
