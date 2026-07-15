import Foundation

/// Pure function that selects up to nine agents for the menu bar's 3x3 dot display,
/// prioritizing agent state.
///
/// Always sort by priority and place non-idle agents in the top-left positions.
/// Priority (highest first): blocked > working > done > idle > unknown.
/// Preserve first-seen order (`PastureAgent.order`) within the same state.
/// When there are more than nine agents, select the nine highest-priority agents.
enum BarAgentSelection {
    static let maxAgents = 9

    /// Display priority for each state; smaller values have higher priority.
    static func priority(of state: AgentState) -> Int {
        switch state {
        case .blocked:  0
        case .working:  1
        case .done:     2
        case .idle:     3
        case .unknown:  4
        }
    }

    /// Sort agents by state priority and first-seen order, returning at most nine.
    /// Non-idle agents (blocked/working/done) are placed in the top-left positions.
    static func select(_ agents: [PastureAgent]) -> [PastureAgent] {
        let sorted = agents.sorted { a, b in
            let pa = priority(of: a.state)
            let pb = priority(of: b.state)
            if pa != pb { return pa < pb }
            return a.order < b.order
        }
        return Array(sorted.prefix(maxAgents))
    }
}
