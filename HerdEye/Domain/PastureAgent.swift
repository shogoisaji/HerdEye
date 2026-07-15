import Foundation

/// An agent displayed in the pasture. Herdr state has already been merged.
struct PastureAgent: Identifiable, Equatable {
    let identity: AgentIdentity
    var paneID: String
    var workspaceID: String
    var workspaceLabel: String
    var agentLabel: String
    var state: AgentState
    /// First-seen order, used to keep display order stable.
    var order: Int

    var id: AgentIdentity { identity }

    private var paneNumber: String {
        paneID.split(separator: ":").last.map(String.init) ?? paneID
    }

    /// Upper line of the label below the dot: workspace name.
    var primaryLabel: String { workspaceLabel }

    /// Lower line of the label below the dot: agent name and pane number.
    var secondaryLabel: String { "\(agentLabel) \(paneNumber)" }

    init(identity: AgentIdentity, paneID: String, workspaceID: String,
                workspaceLabel: String, agentLabel: String, state: AgentState,
                order: Int) {
        self.identity = identity
        self.paneID = paneID
        self.workspaceID = workspaceID
        self.workspaceLabel = workspaceLabel
        self.agentLabel = agentLabel
        self.state = state
        self.order = order
    }
}
