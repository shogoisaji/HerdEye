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
    private var connectionGeneration = 0
    private var consumeTask: Task<Void, Never>?

    init(client: HerdrClient) {
        self.client = client
    }

    func start() {
        guard consumeTask == nil else { return }
        let generation = connectionGeneration
        consumeTask = Task { [weak self] in
            guard let updates = self?.client.updates() else { return }
            for await update in updates {
                guard let self, self.connectionGeneration == generation else { return }
                self.apply(update)
            }
        }
    }

    /// Cancel the current subscription and start a fresh connection.
    ///
    /// This is the manual counterpart to HerdrClient's automatic retry loop.
    /// Keep the current agents until the first snapshot of the new connection
    /// arrives so the popover does not unnecessarily lose its list while retrying.
    func reconnect() {
        connectionGeneration += 1
        consumeTask?.cancel()
        consumeTask = nil
        connectionState = .connecting
        start()
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
