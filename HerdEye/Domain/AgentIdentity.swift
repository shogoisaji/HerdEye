import Foundation

/// Identity key for an individual agent.
/// Prefer agent_session from the hooks integration when available because it remains
/// stable across herdr restarts.
/// Fall back to pane_id and the detected label when unavailable.
struct AgentIdentity: Hashable, Codable, Sendable {
    let key: String

    init(pane: PaneInfo) {
        if let session = pane.agentSession?.value, !session.isEmpty {
            self.key = "session:\(session)"
        } else {
            self.key = "pane:\(pane.paneID)|\(pane.agent ?? "unknown")"
        }
    }

    init(key: String) {
        self.key = key
    }
}
