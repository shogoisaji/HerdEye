import Foundation
import os

enum ConnectionState: Equatable {
    case connecting
    case live
    case reconnecting(attempt: Int)
}

/// Preprocessed updates passed from the socket layer to the store layer.
enum PastureUpdate {
    case connection(ConnectionState)
    case snapshot(panes: [PaneInfo], workspaces: [WorkspaceInfo])
    case statusChanged(AgentStatusChangedData)
    case paneClosed(paneID: String)
}

/// Facade that owns connection, subscription, snapshot, and reconnection handling,
/// exposing only a serialized stream of PastureUpdate values to the store.
///
/// Observed herdr constraints:
/// - events.subscribe can be sent only once per connection, so subscription changes
///   require reconnecting.
/// - Pane-specific subscriptions require pane_id, so maintain a roster of known panes
///   and reconnect when it changes.
final class HerdrClient: @unchecked Sendable {
    struct Config {
        var resubscribeDebounce: Duration = .milliseconds(300)
        var maxBackoff: Double = 15.0
    }

    private let transport: HerdrTransport
    private let config: Config
    private let sleeper: @Sendable (Duration) async throws -> Void
    private let logger = Logger(subsystem: "com.example.HerdEye", category: "client")
    private let legacySnapshot = OSAllocatedUnfairLock(initialState: false)

    init(transport: HerdrTransport,
         config: Config = Config(),
         sleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.config = config
        self.sleeper = sleeper
    }

    func updates() -> AsyncStream<PastureUpdate> {
        AsyncStream { continuation in
            let task = Task { [weak self] in
                await self?.run(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Main loop

    private enum ConnectionEnd {
        case rosterChanged
        case streamEnded
    }

    private func run(_ c: AsyncStream<PastureUpdate>.Continuation) async {
        var attempt = 0
        var roster = Set<String>()
        while !Task.isCancelled {
            do {
                c.yield(.connection(attempt == 0 ? .connecting : .reconnecting(attempt: attempt)))
                let end = try await runConnection(c, roster: &roster)
                attempt = 0
                switch end {
                case .rosterChanged:
                    // Batch consecutive pane additions and removals before reconnecting.
                    try await sleeper(config.resubscribeDebounce)
                case .streamEnded:
                    // The server closed the connection (for example, after a herdr restart):
                    // back off and reconnect.
                    attempt = 1
                    try await backoff(attempt: attempt)
                }
            } catch is CancellationError {
                return
            } catch {
                attempt += 1
                logger.warning("connection failed (attempt \(attempt)): \(String(describing: error))")
                do { try await backoff(attempt: attempt) } catch { return }
            }
        }
    }

    private func backoff(attempt: Int) async throws {
        let base = min(config.maxBackoff, 0.5 * pow(2.0, Double(attempt - 1)))
        let jitter = Double.random(in: 0.8...1.2)
        try await sleeper(.seconds(base * jitter))
    }

    /// Lifecycle of one subscription connection. Wait for the ack, fetch a snapshot,
    /// and keep streaming events.
    /// Return when the roster changes to trigger reconnection.
    private func runConnection(_ c: AsyncStream<PastureUpdate>.Continuation,
                               roster: inout Set<String>) async throws -> ConnectionEnd {
        let subs = Self.subscriptions(for: roster)
        let eventStream = transport.openEventStream(subscriptions: subs)
        defer { eventStream.cancel() }

        // Subscribe first: fetch the snapshot only after receiving the events.subscribe ack.
        // Starting the snapshot before the ack creates a race that can miss events received
        // while the snapshot is being fetched.
        // Limit the roster to panes with detected agents. Herdr UI helper panes are created
        // and destroyed rapidly, so including all panes causes an infinite reconnect loop
        // (confirmed empirically).
        try await eventStream.waitUntilSubscribed()
        let snapshot = try await fetchSnapshot()
        let snapshotPanes = Self.agentPaneIDs(snapshot.panes)
        c.yield(.connection(.live))
        c.yield(.snapshot(panes: snapshot.panes, workspaces: snapshot.workspaces))

        if snapshotPanes != roster {
            roster = snapshotPanes
            // The initial connection uses only global subscriptions, so reconnect to add
            // pane-specific subscriptions.
            return .rosterChanged
        }

        let currentRoster = roster
        return try await consumeEvents(eventStream.stream, c: c, roster: currentRoster)
    }

    /// Consume events and return when a roster change is detected.
    /// Also validate the ack response line here.
    ///
    /// pane.agent_detected fires repeatedly for transient panes that do not appear in the
    /// snapshot (observed). Blindly reconnecting would cause an infinite loop, so validate
    /// against the snapshot and reconnect only when the agent set actually changes.
    /// Do not revalidate transient panes already confirmed absent while the connection remains open.
    private func consumeEvents(_ stream: AsyncThrowingStream<HerdrStreamLine, Error>,
                               c: AsyncStream<PastureUpdate>.Continuation,
                               roster: Set<String>) async throws -> ConnectionEnd {
        var dismissedPanes = Set<String>()
        for try await line in stream {
            guard case .push(let push) = line else {
                if case .response(let ack) = line, let err = ack.error {
                    throw HerdrTransportError.rpcError(code: err.code, message: err.message)
                }
                continue
            }
            // Subscription types use dotted names (`pane.agent_detected`), but push
            // envelopes use underscored EventKind names (`pane_agent_detected`).
            switch Self.normalizedEventName(push.event) {
            case "pane.agent_status_changed":
                if let data = try? push.data.reencoded(as: AgentStatusChangedData.self) {
                    c.yield(.statusChanged(data))
                }
            case "pane.agent_detected":
                guard let data = try? push.data.reencoded(as: PaneLifecycleData.self),
                      data.agent != nil, let paneID = data.paneID,
                      !roster.contains(paneID), !dismissedPanes.contains(paneID) else { continue }
                let snap = try await fetchSnapshot()
                c.yield(.snapshot(panes: snap.panes, workspaces: snap.workspaces))
                if Self.agentPaneIDs(snap.panes) != roster {
                    return .rosterChanged
                }
                dismissedPanes.insert(paneID)
            case "pane.closed":
                if let data = try? push.data.reencoded(as: PaneLifecycleData.self),
                   let paneID = data.paneID, roster.contains(paneID) {
                    c.yield(.paneClosed(paneID: paneID))
                    return .rosterChanged
                }
            case "pane.moved", "workspace.updated", "workspace.renamed", "workspace.closed":
                let snap = try await fetchSnapshot()
                c.yield(.snapshot(panes: snap.panes, workspaces: snap.workspaces))
                if Self.agentPaneIDs(snap.panes) != roster {
                    return .rosterChanged
                }
            default:
                break
            }
        }
        return .streamEnded
    }

    private func fetchSnapshot() async throws -> (panes: [PaneInfo], workspaces: [WorkspaceInfo]) {
        if !legacySnapshot.withLock({ $0 }) {
            do {
                let resp = try await transport.request("session.snapshot", params: [:])
                let snap = try (resp.result ?? .null).reencoded(as: SessionSnapshotResult.self)
                // Prefer the dedicated agents array when present (same records as agent.list).
                // Fall back to panes so older herdr builds and tests keep working.
                let panes = Self.snapshotAgentPanes(snap.snapshot)
                return (panes, snap.snapshot.workspaces)
            } catch HerdrTransportError.rpcError(code: "invalid_request", message: _) {
                legacySnapshot.withLock { $0 = true }
            }
        }

        let paneResp = try await transport.request("pane.list", params: [:])
        let workspaceResp = try await transport.request("workspace.list", params: [:])
        let panes = try (paneResp.result ?? .null).reencoded(as: PaneListResult.self).panes
        let workspaces = try (workspaceResp.result ?? .null).reencoded(as: WorkspaceListResult.self).workspaces
        return (panes, workspaces)
    }

    /// Prefer `snapshot.agents` when herdr provides it; otherwise use panes that have an agent.
    static func snapshotAgentPanes(_ snapshot: SessionSnapshot) -> [PaneInfo] {
        if let agents = snapshot.agents, !agents.isEmpty {
            return agents
        }
        return snapshot.panes
    }

    /// Roster targets only panes with detected agents. Including UI helper panes causes
    /// an infinite reconnect loop.
    static func agentPaneIDs(_ panes: [PaneInfo]) -> Set<String> {
        Set(panes.filter { $0.agent != nil }.map(\.paneID))
    }

    /// Map wire event names to the dotted form used by subscription types and this client.
    ///
    /// herdr accepts dotted subscription types (`pane.agent_detected`) but emits underscored
    /// EventKind values (`pane_agent_detected`) on the push envelope.
    static func normalizedEventName(_ event: String) -> String {
        if event.contains(".") { return event }
        for prefix in ["pane_", "workspace_", "worktree_", "tab_", "layout_"] where event.hasPrefix(prefix) {
            let resource = String(prefix.dropLast())
            return resource + "." + event.dropFirst(prefix.count)
        }
        return event
    }

    /// Subscription list for the known pane set: global event types plus pane-specific
    /// status subscriptions.
    static func subscriptions(for roster: Set<String>) -> [JSONValue] {
        var subs: [JSONValue] = [
            .object(["type": "pane.closed"]),
            .object(["type": "pane.agent_detected"]),
            .object(["type": "pane.moved"]),
            .object(["type": "workspace.updated"]),
            .object(["type": "workspace.renamed"]),
            .object(["type": "workspace.closed"]),
        ]
        for paneID in roster.sorted() {
            subs.append(.object(["type": "pane.agent_status_changed", "pane_id": .string(paneID)]))
        }
        return subs
    }
}
