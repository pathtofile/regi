import JetKVMTransport
import Observation

/// Shared lookup that lets the MCP tools drive the SAME `Session` a GUI
/// window owns, instead of a separate headless one. The JetKVM firmware
/// allows only one session per device, so the human (watching + driving
/// in a window) and the LLM (driving via MCP) must share one peer
/// connection — otherwise the device kicks whichever connected second.
///
/// Windows register their `Session` on connect and unregister on close.
/// The registry holds them **weakly**: the window's `@State` owns the
/// lifetime, the registry only points at it. MCP tools resolve their
/// target from `targetSession` per call.
@MainActor
@Observable
final class SessionRegistry {
    /// One open KVM window's session, keyed by the window's identity.
    /// `session` is weak so a closed window's `Session` deallocates even
    /// if `unregister` somehow didn't run.
    struct Entry {
        let id: KVMSessionWindowID
        weak var session: Session?
    }

    private(set) var entries: [KVMSessionWindowID: Entry] = [:]

    /// The window MCP tools target. Set to the frontmost window as it
    /// becomes key, and to a freshly-registered window so it's
    /// addressable before it gains focus.
    private(set) var activeID: KVMSessionWindowID?

    /// True while MCP is bound to `activeID`'s session (between a
    /// successful `connect` tool call and `disconnect`/server stop).
    /// Read by `KVMSessionWindow.updateBandwidthGate` so the encoder
    /// feed isn't paused out from under the LLM's screenshots while the
    /// window is unfocused.
    private(set) var mcpActive = false

    // MARK: - Window lifecycle

    func register(id: KVMSessionWindowID, session: Session) {
        entries[id] = Entry(id: id, session: session)
        if activeID == nil { activeID = id }
    }

    func unregister(id: KVMSessionWindowID) {
        entries[id] = nil
        if activeID == id {
            activeID = entries.keys.first
        }
    }

    func setActive(_ id: KVMSessionWindowID) {
        guard entries[id] != nil else { return }
        activeID = id
    }

    func setMCPActive(_ active: Bool) {
        mcpActive = active
    }

    // MARK: - MCP target resolution

    /// The `Session` MCP tools operate on right now: the active window's,
    /// falling back to any open window (skips entries whose weak session
    /// has gone away).
    var targetSession: Session? {
        if let activeID, let s = entries[activeID]?.session { return s }
        return entries.values.lazy.compactMap(\.session).first
    }

    /// Identity of the targeted window, mirroring `targetSession`.
    var targetID: KVMSessionWindowID? {
        if let activeID, entries[activeID]?.session != nil { return activeID }
        return entries.values.first { $0.session != nil }?.id
    }

    func session(for id: KVMSessionWindowID) -> Session? {
        entries[id]?.session
    }

    /// Whether MCP is actively driving the given window — gates that
    /// window's bandwidth pause.
    func isMCPDriving(_ id: KVMSessionWindowID) -> Bool {
        mcpActive && activeID == id
    }
}
