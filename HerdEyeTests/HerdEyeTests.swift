import Foundation
import Testing
@testable import HerdEye

@Suite("HerdEye core")
struct HerdEyeTests {
    @Test("Prioritizes blocked and working agents")
    func barSelectionPrioritizesBlockedAndWorkingAgents() {
        let agents = [
            makeAgent(label: "idle", state: .idle, order: 0),
            makeAgent(label: "working", state: .working, order: 1),
            makeAgent(label: "blocked", state: .blocked, order: 2),
        ]

        #expect(
            BarAgentSelection.select(agents).map(\.agentLabel) ==
                ["blocked", "working", "idle"]
        )
    }

    @Test("Keeps first-seen order within a state and caps the result at nine agents")
    func barSelectionKeepsOrderAndCapsResult() {
        let idleAgents = (0..<12).map { index in
            makeAgent(label: "idle-\(index)", state: .idle, order: index)
        }
        let selected = BarAgentSelection.select(
            idleAgents + [makeAgent(label: "blocked", state: .blocked, order: 100)]
        )

        #expect(selected.count == BarAgentSelection.maxAgents)
        #expect(selected.first?.agentLabel == "blocked")
        #expect(Array(selected.dropFirst()).map(\.agentLabel) ==
            (0..<8).map { "idle-\($0)" })
    }

    @Test("Maps unknown and missing raw states to unknown")
    func agentStateFallsBackToUnknown() {
        #expect(AgentState(raw: "working") == .working)
        #expect(AgentState(raw: "future-state") == .unknown)
        #expect(AgentState(raw: nil) == .unknown)
    }

    @Test("Prefers an agent session identity and falls back to pane identity")
    func agentIdentityUsesStableFallbacks() {
        let sessionPane = PaneInfo(
            paneID: "pane:1",
            workspaceID: "workspace-1",
            agent: "agent",
            agentStatus: "working",
            agentSession: AgentSessionRef(
                source: "hooks",
                agent: "agent",
                kind: "native",
                value: "session-1"
            )
        )
        let paneOnly = PaneInfo(
            paneID: "pane:2",
            workspaceID: "workspace-1",
            agent: "agent",
            agentStatus: "working",
            agentSession: nil
        )

        #expect(AgentIdentity(pane: sessionPane).key == "session:session-1")
        #expect(AgentIdentity(pane: paneOnly).key == "pane:pane:2|agent")
    }

    @Test("Updates labels and state for an existing identity")
    func reducerUpdatesWorkspaceAndAgentLabelsForExistingIdentity() {
        let pane = PaneInfo(
            paneID: "pane:1",
            workspaceID: "workspace-1",
            agent: "new-agent",
            agentStatus: "working",
            agentSession: AgentSessionRef(
                source: nil,
                agent: nil,
                kind: nil,
                value: "session-1"
            )
        )
        let identity = AgentIdentity(key: "session:session-1")
        var current = [identity: PastureAgent(
            identity: identity,
            paneID: "pane:1",
            workspaceID: "workspace-1",
            workspaceLabel: "Old workspace",
            agentLabel: "old-agent",
            state: .idle,
            order: 0
        )]
        var nextOrder = 1

        current = PastureReducer.mergeSnapshot(
            panes: [pane],
            workspaces: [WorkspaceInfo(workspaceID: "workspace-1", label: "New workspace")],
            into: current,
            nextOrder: &nextOrder
        )

        #expect(current[identity]?.workspaceLabel == "New workspace")
        #expect(current[identity]?.agentLabel == "new-agent")
        #expect(current[identity]?.state == .working)
        #expect(nextOrder == 1)
    }

    @Test("Filters panes without agents and assigns first-seen order to new agents")
    func reducerFiltersInactivePanesAndAssignsOrder() {
        let panes = [
            PaneInfo(
                paneID: "pane:empty",
                workspaceID: "workspace-1",
                agent: nil,
                agentStatus: nil,
                agentSession: nil
            ),
            PaneInfo(
                paneID: "pane:new",
                workspaceID: "workspace-1",
                agent: "new-agent",
                agentStatus: nil,
                agentSession: nil
            ),
        ]
        var nextOrder = 4

        let result = PastureReducer.mergeSnapshot(
            panes: panes,
            workspaces: [WorkspaceInfo(workspaceID: "workspace-1", label: nil)],
            into: [:],
            nextOrder: &nextOrder
        )

        let identity = AgentIdentity(pane: panes[1])
        #expect(result.count == 1)
        #expect(result[identity]?.workspaceLabel == "workspace-1")
        #expect(result[identity]?.state == .unknown)
        #expect(result[identity]?.order == 4)
        #expect(nextOrder == 5)
    }

    @Test("Uses the first workspace label when duplicate workspace IDs are returned")
    func reducerUsesFirstDuplicateWorkspaceLabel() {
        let pane = PaneInfo(
            paneID: "pane:1",
            workspaceID: "workspace-1",
            agent: "agent",
            agentStatus: "idle",
            agentSession: nil
        )
        var nextOrder = 0

        let result = PastureReducer.mergeSnapshot(
            panes: [pane],
            workspaces: [
                WorkspaceInfo(workspaceID: "workspace-1", label: "First"),
                WorkspaceInfo(workspaceID: "workspace-1", label: "Second"),
            ],
            into: [:],
            nextOrder: &nextOrder
        )

        #expect(result[AgentIdentity(pane: pane)]?.workspaceLabel == "First")
    }

    @Test("Applies a status change only to matching panes")
    func reducerAppliesStatusChangeToMatchingPane() {
        let matching = makeAgent(label: "matching", state: .idle, order: 0)
        let other = makeAgent(label: "other", state: .working, order: 1)
        let change = AgentStatusChangedData(
            paneID: matching.paneID,
            workspaceID: nil,
            agent: nil,
            agentStatus: "future-state"
        )

        let result = PastureReducer.applyStatusChange(
            change,
            to: [matching.identity: matching, other.identity: other]
        )

        #expect(result[matching.identity]?.state == .unknown)
        #expect(result[other.identity]?.state == .working)
    }

    @Test("Removes only the agent belonging to a closed pane")
    func reducerRemovesClosedPane() {
        let removed = makeAgent(label: "removed", state: .idle, order: 0)
        let retained = makeAgent(label: "retained", state: .working, order: 1)

        let result = PastureReducer.removePane(
            removed.paneID,
            from: [removed.identity: removed, retained.identity: retained]
        )

        #expect(Set(result.keys) == [retained.identity])
    }

    @Test("Reconstructs NDJSON lines across multiple chunks")
    func ndjsonReaderHandlesMultipleChunks() {
        var reader = NDJSONLineReader()

        #expect(reader.append(Data("{\"a\":\"x".utf8)).isEmpty)
        #expect(
            reader.append(Data("\"}\n{\"b\":2}\n".utf8)) ==
                [Data("{\"a\":\"x\"}".utf8), Data("{\"b\":2}".utf8)]
        )
    }

    @Test("Reconstructs a line split inside a UTF-8 character")
    func ndjsonReaderHandlesUTF8Boundaries() {
        var reader = NDJSONLineReader()
        let input = Data("{\"message\":\"café\"}\n".utf8)
        let firstCharacterByte = Data("é".utf8).first!
        let split = input.firstIndex(of: firstCharacterByte)! + 1

        #expect(reader.append(Data(input.prefix(split))).isEmpty)
        #expect(reader.append(Data(input.suffix(from: split))) ==
            [Data("{\"message\":\"café\"}".utf8)])
    }

    @Test("Flushes an unterminated NDJSON line and skips empty lines")
    func ndjsonReaderFlushesAtEOF() {
        var reader = NDJSONLineReader()

        #expect(reader.append(Data("\n{\"a\":1".utf8)).isEmpty)
        #expect(reader.flush() == Data("{\"a\":1".utf8))

        var secondReader = NDJSONLineReader()
        #expect(secondReader.append(Data("{\"a\":1".utf8)).isEmpty)
        #expect(secondReader.flush() == Data("{\"a\":1".utf8))
        #expect(secondReader.flush() == nil)
    }

    @Test("Round-trips nested JSON values")
    func jsonValueRoundTripsNestedValues() throws {
        let value: JSONValue = .object([
            "name": .string("agent"),
            "enabled": .bool(true),
            "items": .array([.number(1), .null]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)

        #expect(decoded == value)
    }

    @Test("Decodes push events, responses, and undecodable lines")
    func herdrStreamLineDecodesWireFormats() {
        let pushLine = Data(#"{"event":"pane.closed","data":{"pane_id":"pane:1"}}"#.utf8)
        let responseLine = Data(#"{"id":"1","result":{"ok":true}}"#.utf8)

        guard case .push(let push) = HerdrStreamLine.decode(pushLine) else {
            Issue.record("Expected a push event")
            return
        }
        #expect(push.event == "pane.closed")

        guard case .response(let response) = HerdrStreamLine.decode(responseLine) else {
            Issue.record("Expected a response")
            return
        }
        #expect(response.id == "1")

        guard case .undecodable = HerdrStreamLine.decode(Data("not-json".utf8)) else {
            Issue.record("Expected an undecodable line")
            return
        }
    }

    @Test("Selects only agent panes and sorts pane subscriptions")
    func clientBuildsAgentRosterAndSubscriptions() {
        let panes = [
            PaneInfo(
                paneID: "pane:empty",
                workspaceID: "workspace-1",
                agent: nil,
                agentStatus: nil,
                agentSession: nil
            ),
            PaneInfo(
                paneID: "pane:2",
                workspaceID: "workspace-1",
                agent: "agent-2",
                agentStatus: "working",
                agentSession: nil
            ),
            PaneInfo(
                paneID: "pane:1",
                workspaceID: "workspace-1",
                agent: "agent-1",
                agentStatus: "idle",
                agentSession: nil
            ),
        ]

        #expect(HerdrClient.agentPaneIDs(panes) == ["pane:1", "pane:2"])
        #expect(HerdrClient.subscriptions(for: ["pane:2", "pane:1"]) == [
            .object(["type": .string("pane.closed")]),
            .object(["type": .string("pane.agent_detected")]),
            .object(["type": .string("pane.moved")]),
            .object(["type": .string("workspace.updated")]),
            .object(["type": .string("workspace.renamed")]),
            .object(["type": .string("workspace.closed")]),
            .object(["type": .string("pane.agent_status_changed"),
                     "pane_id": .string("pane:1")]),
            .object(["type": .string("pane.agent_status_changed"),
                     "pane_id": .string("pane:2")]),
        ])
    }

    @Test("Refreshes the snapshot when a workspace is renamed")
    func clientRefreshesSnapshotWhenWorkspaceIsRenamed() async throws {
        let transport = WorkspaceRenameTransport()
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        let connectingUpdate = await iterator?.next()
        #expect(connectingUpdate.flatMap(connectionState) == .connecting)
        let liveUpdate = await iterator?.next()
        #expect(liveUpdate.flatMap(connectionState) == .live)

        let initial = try #require(await iterator?.next())
        guard case .snapshot(_, let workspaces) = initial else {
            Issue.record("Expected the initial snapshot")
            return
        }
        #expect(workspaces.first?.label == "Before")

        let renamed = try #require(await iterator?.next())
        guard case .snapshot(_, let renamedWorkspaces) = renamed else {
            Issue.record("Expected the renamed snapshot")
            return
        }
        #expect(renamedWorkspaces.first?.label == "After")
    }

    @Test("Waits for subscription readiness before fetching a snapshot")
    func clientWaitsForSubscriptionBeforeFetchingSnapshot() async throws {
        let transport = SubscriptionGateTransport()
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        let connectingUpdate = await iterator?.next()
        #expect(connectingUpdate.flatMap(connectionState) == .connecting)

        await transport.waitUntilOpened()
        #expect(transport.snapshotCount == 0)

        transport.releaseSubscription()

        let liveUpdate = await iterator?.next()
        #expect(liveUpdate.flatMap(connectionState) == .live)
        _ = await iterator?.next()

        #expect(!transport.snapshotRequestedBeforeReady)
    }

    @Test("Emits a pane status change from the subscription stream")
    func clientEmitsPaneStatusChange() async throws {
        let transport = StatusChangeTransport()
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        _ = await iterator?.next()
        _ = await iterator?.next()
        _ = await iterator?.next()

        let update = try #require(await iterator?.next())
        guard case .statusChanged(let change) = update else {
            Issue.record("Expected a status change update")
            return
        }
        #expect(change.paneID == "pane:1")
        #expect(change.agentStatus == "working")
    }

    @Test("Emits a status-change update for underscored EventKind names")
    func clientEmitsPaneStatusChangeForUnderscoredEvent() async throws {
        let transport = StatusChangeTransport(underscoredEventName: true)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        _ = await iterator?.next()
        _ = await iterator?.next()
        _ = await iterator?.next()

        let update = try #require(await iterator?.next())
        guard case .statusChanged(let change) = update else {
            Issue.record("Expected a status change update from underscored event")
            return
        }
        #expect(change.paneID == "pane:1")
        #expect(change.agentStatus == "working")
    }

    @Test("Normalizes underscored herdr EventKind names to dotted form")
    func normalizesHerdrEventNames() {
        #expect(HerdrClient.normalizedEventName("pane_agent_detected") == "pane.agent_detected")
        #expect(HerdrClient.normalizedEventName("pane_agent_status_changed") == "pane.agent_status_changed")
        #expect(HerdrClient.normalizedEventName("pane_closed") == "pane.closed")
        #expect(HerdrClient.normalizedEventName("workspace_updated") == "workspace.updated")
        #expect(HerdrClient.normalizedEventName("pane.agent_detected") == "pane.agent_detected")
    }

    @Test("Prefers session.snapshot agents array over panes when present")
    func prefersSnapshotAgentsArray() {
        let panes = [
            PaneInfo(paneID: "p1", workspaceID: "w1", agent: nil, agentStatus: "unknown", agentSession: nil),
            PaneInfo(paneID: "p2", workspaceID: "w1", agent: "codex", agentStatus: "idle", agentSession: nil),
        ]
        let agents = [
            PaneInfo(paneID: "p2", workspaceID: "w1", agent: "codex", agentStatus: "working", agentSession: nil),
        ]
        let withAgents = SessionSnapshot(panes: panes, workspaces: [], agents: agents)
        let withoutAgents = SessionSnapshot(panes: panes, workspaces: [], agents: nil)

        #expect(HerdrClient.snapshotAgentPanes(withAgents).map(\.paneID) == ["p2"])
        #expect(HerdrClient.snapshotAgentPanes(withAgents).first?.agentStatus == "working")
        #expect(HerdrClient.snapshotAgentPanes(withoutAgents).map(\.paneID) == ["p1", "p2"])
    }

    @Test("Emits a pane-closed update for the dotted lifecycle event")
    func clientEmitsPaneClosed() async throws {
        let transport = PaneLifecycleTransport(scenario: .closed)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        let updates = client.updates()
        var iterator = updates.makeAsyncIterator()

        var closedPaneID: String?
        for _ in 0..<12 {
            guard let update = await iterator.next() else { break }
            if case .paneClosed(let paneID) = update {
                closedPaneID = paneID
                break
            }
        }

        #expect(closedPaneID == "pane:1")
    }

    @Test("Emits a pane-closed update for underscored EventKind names")
    func clientEmitsPaneClosedForUnderscoredEvent() async throws {
        let transport = PaneLifecycleTransport(scenario: .closedUnderscored)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        let updates = client.updates()
        var iterator = updates.makeAsyncIterator()

        var closedPaneID: String?
        for _ in 0..<12 {
            guard let update = await iterator.next() else { break }
            if case .paneClosed(let paneID) = update {
                closedPaneID = paneID
                break
            }
        }

        #expect(closedPaneID == "pane:1")
    }

    @Test("Refreshes the snapshot when a new agent is detected")
    func clientRefreshesSnapshotWhenAgentIsDetected() async throws {
        let transport = PaneLifecycleTransport(scenario: .detected)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        let updates = client.updates()
        var iterator = updates.makeAsyncIterator()

        var detectedPaneID: String?
        for _ in 0..<12 {
            guard let update = await iterator.next() else { break }
            guard case .snapshot(let panes, _) = update,
                  let pane = panes.first else { continue }
            detectedPaneID = pane.paneID
            break
        }

        #expect(detectedPaneID == "pane:1")
    }

    @Test("Refreshes the snapshot when agent is detected via underscored EventKind")
    func clientRefreshesSnapshotWhenAgentIsDetectedUnderscored() async throws {
        let transport = PaneLifecycleTransport(scenario: .detectedUnderscored)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        let updates = client.updates()
        var iterator = updates.makeAsyncIterator()

        var sawAgent = false
        for _ in 0..<12 {
            guard let update = await iterator.next() else { break }
            if case .snapshot(let panes, _) = update,
               panes.contains(where: { $0.agent != nil }) {
                sawAgent = true
                break
            }
        }

        #expect(sawAgent)
    }

    @Test("Refreshes the snapshot when an agent pane moves")
    func clientRefreshesSnapshotWhenPaneMoves() async throws {
        let transport = PaneLifecycleTransport(scenario: .moved)
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        let updates = client.updates()
        var iterator = updates.makeAsyncIterator()

        var movedPaneID: String?
        for _ in 0..<12 {
            guard let update = await iterator.next() else { break }
            guard case .snapshot(let panes, _) = update,
                  let pane = panes.first,
                  pane.paneID == "workspace-2:pane-1" else { continue }
            movedPaneID = pane.paneID
            break
        }

        #expect(movedPaneID == "workspace-2:pane-1")
    }

    @Test("Falls back to legacy snapshot endpoints when session.snapshot is unsupported")
    func clientFallsBackToLegacySnapshotEndpoints() async throws {
        let transport = LegacySnapshotTransport()
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        _ = await iterator?.next()
        let liveUpdate = try #require(await iterator?.next())
        #expect(connectionState(liveUpdate) == .live)
        _ = try #require(await iterator?.next())

        #expect(transport.requestedMethods.prefix(3) == [
            "session.snapshot",
            "pane.list",
            "workspace.list",
        ])
    }

    @Test("Recovers after a dropped connection when the pane roster becomes stale")
    func clientResetsRosterAndRecoversAfterRestart() async throws {
        let transport = RestartRosterTransport()
        let client = HerdrClient(
            transport: transport,
            config: .init(resubscribeDebounce: .zero, maxBackoff: 0),
            sleeper: { _ in }
        )
        var updates: AsyncStream<PastureUpdate>? = client.updates()
        var iterator: AsyncStream<PastureUpdate>.AsyncIterator? = updates?.makeAsyncIterator()
        defer {
            iterator = nil
            updates = nil
        }

        // After the simulated restart, herdr exposes a new pane ID and rejects
        // pane-specific subscriptions for the old one. The client must discard the
        // stale roster on the dropped connection so resubscription can succeed.
        var sawFreshPane = false
        for _ in 0..<40 {
            guard let update = await iterator?.next() else { break }
            if case .snapshot(let panes, _) = update,
               panes.contains(where: { $0.paneID == "new:1" }) {
                sawFreshPane = true
                break
            }
        }

        #expect(sawFreshPane)
    }

    private func makeAgent(label: String, state: AgentState, order: Int) -> PastureAgent {
        PastureAgent(
            identity: AgentIdentity(key: "agent:\(label)"),
            paneID: "pane:\(label)",
            workspaceID: "workspace:\(label)",
            workspaceLabel: label,
            agentLabel: label,
            state: state,
            order: order
        )
    }

    private func connectionState(_ update: PastureUpdate) -> ConnectionState? {
        guard case .connection(let state) = update else { return nil }
        return state
    }
}

private func emptySnapshotResponse() -> HerdrResponse {
    HerdrResponse(
        id: "snapshot",
        result: .object([
            "snapshot": .object([
                "panes": .array([]),
                "workspaces": .array([]),
            ])
        ]),
        error: nil
    )
}

private final class WorkspaceRenameTransport: HerdrTransport, @unchecked Sendable {
    private var snapshotCount = 0

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        guard method == "session.snapshot" else {
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }

        snapshotCount += 1
        let label = snapshotCount == 1 ? "Before" : "After"
        let result: JSONValue = .object([
            "snapshot": .object([
                "panes": .array([]),
                "workspaces": .array([
                    .object([
                        "workspace_id": .string("workspace-1"),
                        "label": .string(label),
                    ])
                ]),
            ])
        ])
        return HerdrResponse(id: "test", result: result, error: nil)
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            continuation.yield(.push(HerdrPushEvent(
                event: "workspace.renamed",
                data: .object(["workspace_id": .string("workspace-1")])
            )))
            continuation.finish()
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {},
            cancel: {}
        )
    }
}

private final class StatusChangeTransport: HerdrTransport, @unchecked Sendable {
    /// When true, emit the wire EventKind name herdr 0.7.x actually pushes.
    private let underscoredEventName: Bool

    init(underscoredEventName: Bool = false) {
        self.underscoredEventName = underscoredEventName
    }

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        guard method == "session.snapshot" else {
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }
        return emptySnapshotResponse()
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let eventName = underscoredEventName
            ? "pane_agent_status_changed"
            : "pane.agent_status_changed"
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            continuation.yield(.push(HerdrPushEvent(
                event: eventName,
                data: .object([
                    "pane_id": .string("pane:1"),
                    "agent_status": .string("working"),
                ])
            )))
            continuation.finish()
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {},
            cancel: {}
        )
    }
}

private final class LegacySnapshotTransport: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var methods: [String] = []

    var requestedMethods: [String] {
        lock.lock()
        defer { lock.unlock() }
        return methods
    }

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        lock.withLock {
            methods.append(method)
        }

        switch method {
        case "session.snapshot":
            throw HerdrTransportError.rpcError(code: "invalid_request", message: "unsupported")
        case "pane.list", "workspace.list":
            return HerdrResponse(
                id: method,
                result: method == "pane.list"
                    ? .object(["panes": .array([])])
                    : .object(["workspaces": .array([])]),
                error: nil
            )
        default:
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            continuation.finish()
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {},
            cancel: {}
        )
    }
}

private final class PaneLifecycleTransport: HerdrTransport, @unchecked Sendable {
    enum Scenario {
        case closed
        case closedUnderscored
        case detected
        case detectedUnderscored
        case moved
    }

    private let scenario: Scenario
    private let lock = NSLock()
    private var snapshotCount = 0
    private var streamCount = 0

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        guard method == "session.snapshot" else {
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }

        let count = lock.withLock {
            snapshotCount += 1
            return snapshotCount
        }

        switch scenario {
        case .closed, .closedUnderscored:
            return agentSnapshotResponse(paneID: "pane:1", workspaceID: "workspace-1")
        case .detected, .detectedUnderscored:
            return count == 1
                ? emptySnapshotResponse()
                : agentSnapshotResponse(paneID: "pane:1", workspaceID: "workspace-1")
        case .moved:
            return count <= 2
                ? agentSnapshotResponse(paneID: "workspace-1:pane-1", workspaceID: "workspace-1")
                : agentSnapshotResponse(paneID: "workspace-2:pane-1", workspaceID: "workspace-2")
        }
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let count = lock.withLock {
            streamCount += 1
            return streamCount
        }
        let scenario = scenario
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            switch scenario {
            case .closed where count == 2:
                continuation.yield(.push(HerdrPushEvent(
                    event: "pane.closed",
                    data: .object(["pane_id": .string("pane:1")])
                )))
            case .closedUnderscored where count == 2:
                continuation.yield(.push(HerdrPushEvent(
                    event: "pane_closed",
                    data: .object(["pane_id": .string("pane:1")])
                )))
            case .detected where count == 1:
                continuation.yield(.push(HerdrPushEvent(
                    event: "pane.agent_detected",
                    data: .object([
                        "pane_id": .string("pane:1"),
                        "workspace_id": .string("workspace-1"),
                        "agent": .string("agent"),
                    ])
                )))
            case .detectedUnderscored where count == 1:
                continuation.yield(.push(HerdrPushEvent(
                    event: "pane_agent_detected",
                    data: .object([
                        "pane_id": .string("pane:1"),
                        "workspace_id": .string("workspace-1"),
                        "agent": .string("agent"),
                        "type": .string("pane_agent_detected"),
                    ])
                )))
            case .moved where count == 2:
                continuation.yield(.push(HerdrPushEvent(
                    event: "pane.moved",
                    data: .object([
                        "pane_id": .string("workspace-2:pane-1"),
                        "workspace_id": .string("workspace-2"),
                    ])
                )))
            default:
                break
            }
            continuation.finish()
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {},
            cancel: {}
        )
    }
}

private func agentSnapshotResponse(paneID: String, workspaceID: String) -> HerdrResponse {
    HerdrResponse(
        id: "snapshot",
        result: .object([
            "snapshot": .object([
                "panes": .array([
                    .object([
                        "pane_id": .string(paneID),
                        "workspace_id": .string(workspaceID),
                        "agent": .string("agent"),
                        "agent_status": .string("working"),
                    ])
                ]),
                "workspaces": .array([
                    .object([
                        "workspace_id": .string(workspaceID),
                        "label": .string(workspaceID),
                    ])
                ]),
            ])
        ]),
        error: nil
    )
}

/// Simulates a herdr restart: the exposed pane ID changes and pane-specific
/// subscriptions for the old pane are rejected, so the client must clear its
/// roster on a dropped connection to recover.
private final class RestartRosterTransport: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var streamCount = 0
    private let stalePane = "old:1"
    private let freshPane = "new:1"

    private var restarted: Bool {
        lock.withLock { streamCount >= 3 }
    }

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        guard method == "session.snapshot" else {
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }
        let pane = restarted ? freshPane : stalePane
        return agentSnapshotResponse(paneID: pane, workspaceID: "workspace-1")
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let count = lock.withLock {
            streamCount += 1
            return streamCount
        }
        let stalePane = stalePane
        let rejectsStalePane = count >= 3
            && subscriptions.contains { subscription in
                guard case .object(let object) = subscription,
                      case .string(let paneID)? = object["pane_id"] else { return false }
                return paneID == stalePane
            }
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { $0.finish() }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {
                if rejectsStalePane {
                    throw HerdrTransportError.rpcError(code: "unknown_pane", message: stalePane)
                }
            },
            cancel: {}
        )
    }
}

private final class SubscriptionGateTransport: HerdrTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var readyContinuation: AsyncThrowingStream<Void, Error>.Continuation?
    private var eventContinuation: AsyncThrowingStream<HerdrStreamLine, Error>.Continuation?
    private var openedContinuation: CheckedContinuation<Void, Never>?
    private var subscriptionReleased = false

    private var _snapshotCount = 0
    private var _snapshotRequestedBeforeReady = false

    var snapshotCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _snapshotCount
    }

    var snapshotRequestedBeforeReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _snapshotRequestedBeforeReady
    }

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        guard method == "session.snapshot" else {
            throw HerdrTransportError.rpcError(code: "unexpected_method", message: method)
        }

        lock.withLock {
            _snapshotCount += 1
            if !subscriptionReleased {
                _snapshotRequestedBeforeReady = true
            }
        }

        return emptySnapshotResponse()
    }

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let ready = AsyncThrowingStream<Void, Error> { continuation in
            lock.lock()
            readyContinuation = continuation
            let opened = openedContinuation
            openedContinuation = nil
            lock.unlock()
            opened?.resume()
        }
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            lock.lock()
            eventContinuation = continuation
            lock.unlock()
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: {
                var iterator = ready.makeAsyncIterator()
                guard try await iterator.next() != nil else {
                    throw HerdrTransportError.emptyResponse
                }
            },
            cancel: { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let continuation = self.eventContinuation
                self.eventContinuation = nil
                self.lock.unlock()
                continuation?.finish()
            }
        )
    }

    func waitUntilOpened() async {
        await withCheckedContinuation { continuation in
            if registerOpenedContinuation(continuation) {
                continuation.resume()
            }
        }
    }

    private func registerOpenedContinuation(
        _ continuation: CheckedContinuation<Void, Never>
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if readyContinuation != nil {
            return true
        }
        openedContinuation = continuation
        return false
    }

    func releaseSubscription() {
        lock.lock()
        subscriptionReleased = true
        let ready = readyContinuation
        readyContinuation = nil
        let events = eventContinuation
        eventContinuation = nil
        lock.unlock()

        ready?.yield(())
        ready?.finish()
        events?.finish()
    }
}
