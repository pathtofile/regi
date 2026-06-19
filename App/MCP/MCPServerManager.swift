import Foundation
import JetKVMTransport
import OSLog
import Observation
import WebRTC

private let log = Logger(subsystem: "app.regi.mac", category: "mcp-server")

/// Top-level MCP server owner. Holds the dedicated KVM session used by
/// MCP clients (separate from any window sessions), the HTTP server, the
/// frame capturer, and the tool handler.
///
/// Injected as an @Observable environment object from RegiApp so
/// HostsView can show live status without knowing implementation details.
@MainActor
@Observable
final class MCPServerManager {
    private(set) var isRunning = false
    private(set) var connectedClientCount = 0
    let port: UInt16 = 8765

    // Dedicated session for MCP — headless, no window attached
    let session = Session()
    let frameCapture = MCPFrameCapture()

    private var httpServer: MCPHTTPServer?
    private var toolHandler: MCPToolHandler?
    private var trackObserverTask: Task<Void, Never>?

    // Populated by configure() once SwiftUI environment objects exist
    private weak var hostStore: HostStore?
    private weak var discovery: DeviceDiscovery?

    // MARK: - Setup

    /// Wire up the environment objects. Call before `start()`.
    func configure(hostStore: HostStore, discovery: DeviceDiscovery) {
        self.hostStore = hostStore
        self.discovery = discovery
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        guard let hostStore, let discovery else {
            log.error("start() called before configure() — ignoring")
            return
        }

        let th = MCPToolHandler(
            session: session,
            frameCapture: frameCapture,
            hostStore: hostStore,
            discovery: discovery
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
        httpServer?.stop()
        httpServer = nil
        toolHandler = nil
        await session.disconnect()
        isRunning = false
        connectedClientCount = 0
        log.info("MCP server stopped")
    }

    // MARK: - Video track observation

    /// Attach/detach the frame capturer whenever the MCP session's video
    /// track changes. Uses withObservationTracking to re-register on each
    /// change, forming a lightweight reactive loop.
    private func startTrackObserver() {
        trackObserverTask?.cancel()
        trackObserverTask = Task { [weak self] in
            await self?.observeVideoTrack(previous: nil)
        }
    }

    private func observeVideoTrack(previous: RTCVideoTrack?) async {
        guard !Task.isCancelled else { return }
        var currentTrack: RTCVideoTrack?
        withObservationTracking {
            currentTrack = session.videoTrack
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.observeVideoTrack(previous: currentTrack)
            }
        }
        // Sync frame capturer if the track changed
        if currentTrack !== previous {
            if let old = previous { frameCapture.detach(from: old) }
            if let new = currentTrack { frameCapture.attach(to: new) }
        }
    }
}
