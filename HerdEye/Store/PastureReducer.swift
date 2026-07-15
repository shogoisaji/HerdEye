import Foundation

/// Pure functions that fold PastureUpdate values into a dictionary.
/// Tested independently of sockets and UI.
enum PastureReducer {
    /// Reconcile against a snapshot. Only panes with detected agents become agents.
    /// Agents whose panes disappeared are removed; new agents receive a first-seen order.
    static func mergeSnapshot(panes: [PaneInfo],
                              workspaces: [WorkspaceInfo],
                              into current: [AgentIdentity: PastureAgent],
                              nextOrder: inout Int) -> [AgentIdentity: PastureAgent] {
        // Handle server responses leniently: duplicate workspace IDs do not crash (first wins).
        let labels = Dictionary(workspaces.map { ($0.workspaceID, $0.label ?? $0.workspaceID) },
                                uniquingKeysWith: { first, _ in first })
        var result: [AgentIdentity: PastureAgent] = [:]
        for pane in panes where pane.agent != nil {
            let identity = AgentIdentity(pane: pane)
            let wsLabel = labels[pane.workspaceID] ?? pane.workspaceID
            let newState = AgentState(raw: pane.agentStatus)
            if var existing = current[identity] {
                existing.paneID = pane.paneID
                existing.workspaceID = pane.workspaceID
                existing.workspaceLabel = wsLabel
                existing.agentLabel = pane.agent ?? existing.agentLabel
                existing.state = newState
                result[identity] = existing
            } else {
                result[identity] = PastureAgent(
                    identity: identity,
                    paneID: pane.paneID,
                    workspaceID: pane.workspaceID,
                    workspaceLabel: wsLabel,
                    agentLabel: pane.agent ?? "agent",
                    state: newState,
                    order: nextOrder
                )
                nextOrder += 1
            }
        }
        return result
    }

    /// Apply a status-change event by finding the target by pane ID and replacing its state.
    static func applyStatusChange(_ change: AgentStatusChangedData,
                                  to current: [AgentIdentity: PastureAgent]) -> [AgentIdentity: PastureAgent] {
        var result = current
        for (identity, agent) in current where agent.paneID == change.paneID {
            var updated = agent
            updated.state = AgentState(raw: change.agentStatus)
            result[identity] = updated
        }
        return result
    }

    /// Remove a pane and the agent that occupied it.
    static func removePane(_ paneID: String,
                           from current: [AgentIdentity: PastureAgent]) -> [AgentIdentity: PastureAgent] {
        current.filter { $0.value.paneID != paneID }
    }
}
