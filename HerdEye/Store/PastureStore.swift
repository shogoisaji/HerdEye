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
        consumeTask = Task { [weak self] in
            await self?.runConsumeLoop()
        }
    }

    /// Cancel the current subscription and start a fresh connection.
    ///
    /// Used by the manual reconnect control and by event-driven recovery
    /// (system wake, herdr socket replaced). Keep the current agents until
    /// the first snapshot of the new connection arrives so the popover does
    /// not unnecessarily lose its list while retrying.
    func reconnect() {
        connectionGeneration += 1
        consumeTask?.cancel()
        consumeTask = nil
        connectionState = .connecting
        start()
    }

    // MARK: - Consume loop

    /// Run successive `HerdrClient.updates()` streams until cancelled.
    ///
    /// The client already retries inside one stream, but if that stream ends
    /// unexpectedly the store used to sit idle until a manual reconnect.
    /// Restarting here closes that gap without any polling.
    private func runConsumeLoop() async {
        while !Task.isCancelled {
            let generation = connectionGeneration
            let updates = client.updates()
            for await update in updates {
                guard !Task.isCancelled else { return }
                guard connectionGeneration == generation else { return }
                apply(update)
            }
            // Stream finished without a generation bump (unexpected end).
            // Leave if we were cancelled or superseded by reconnect().
            guard !Task.isCancelled, connectionGeneration == generation else { return }
            connectionState = .connecting
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
