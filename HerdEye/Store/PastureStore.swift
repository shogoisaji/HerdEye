import Foundation
import Observation

@Observable @MainActor
final class PastureStore {
    private(set) var agentsByID: [AgentIdentity: PastureAgent] = [:]
    private(set) var connectionState: ConnectionState = .connecting

    /// Display list stably sorted by first-seen order.
    var sortedAgents: [PastureAgent] {
        agentsByID.values.sorted { $0.order < $1.order }
    }

    private let client: HerdrClient
    private var nextOrder = 0
    private var consumeTask: Task<Void, Never>?

    init(client: HerdrClient) {
        self.client = client
    }

    func start() {
        guard consumeTask == nil else { return }
        consumeTask = Task { [weak self] in
            guard let updates = self?.client.updates() else { return }
            for await update in updates {
                guard let self else { return }
                self.apply(update)
            }
        }
    }

    private func apply(_ update: PastureUpdate) {
        switch update {
        case .connection(let state):
            connectionState = state
        case .snapshot(let panes, let workspaces):
            agentsByID = PastureReducer.mergeSnapshot(
                panes: panes, workspaces: workspaces,
                into: agentsByID, nextOrder: &nextOrder)
        case .statusChanged(let change):
            agentsByID = PastureReducer.applyStatusChange(change, to: agentsByID)
        case .paneClosed(let paneID):
            agentsByID = PastureReducer.removePane(paneID, from: agentsByID)
        }
    }
}
