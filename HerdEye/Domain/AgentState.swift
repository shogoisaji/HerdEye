import Foundation

/// Mirror of the agent states reported by herdr without custom interpretation (ADR-0001).
enum AgentState: String, Codable, CaseIterable, Hashable {
    case idle
    case working
    case blocked
    case done
    case unknown

    init(raw: String?) {
        self = raw.flatMap(AgentState.init(rawValue:)) ?? .unknown
    }
}
