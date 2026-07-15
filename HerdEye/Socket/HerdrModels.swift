import Foundation

// MARK: - Requests

struct HerdrRequest: Encodable {
    let id: String
    let method: String
    let params: [String: JSONValue]
}

// MARK: - Responses (one-shot RPC)

/// `{"id":..., "result":{...}}` or `{"id":..., "error":{...}}`.
struct HerdrResponse: Decodable {
    let id: String
    let result: JSONValue?
    let error: HerdrError?
}

struct HerdrError: Decodable, Error {
    let code: String
    let message: String
}

// MARK: - Push events (observed format: {"data":{...},"event":"<name>"})

struct HerdrPushEvent: Decodable {
    let event: String
    let data: JSONValue
}

/// Each line in a subscription stream is either a subscription ack (HerdrResponse)
/// or a push event.
enum HerdrStreamLine {
    case response(HerdrResponse)
    case push(HerdrPushEvent)
    case undecodable(String)

    static func decode(_ line: Data) -> HerdrStreamLine {
        let decoder = JSONDecoder()
        if let push = try? decoder.decode(HerdrPushEvent.self, from: line) {
            return .push(push)
        }
        if let resp = try? decoder.decode(HerdrResponse.self, from: line) {
            return .response(resp)
        }
        return .undecodable(String(data: line, encoding: .utf8) ?? "<non-utf8>")
    }
}

// MARK: - Domain-oriented payloads

struct PaneInfo: Decodable, Equatable {
    let paneID: String
    let workspaceID: String
    let agent: String?
    let agentStatus: String?
    let agentSession: AgentSessionRef?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agent
        case agentStatus = "agent_status"
        case agentSession = "agent_session"
    }
}

/// Native agent session reference included only when hooks integration is enabled.
struct AgentSessionRef: Decodable, Equatable {
    let source: String?
    let agent: String?
    let kind: String?
    let value: String?
}

struct WorkspaceInfo: Decodable, Equatable {
    let workspaceID: String
    let label: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

struct PaneListResult: Decodable {
    let panes: [PaneInfo]
}

struct WorkspaceListResult: Decodable {
    let workspaces: [WorkspaceInfo]
}

/// Result of `session.snapshot` (v0.7.2+). Returns panes and workspaces in one response.
/// The response has the form `{"type":"session_snapshot","snapshot":{...}}`.
struct SessionSnapshotResult: Decodable {
    let snapshot: SessionSnapshot
}

struct SessionSnapshot: Decodable {
    let panes: [PaneInfo]
    let workspaces: [WorkspaceInfo]
}

/// Data for pane.agent_status_changed (observed: no revision field).
struct AgentStatusChangedData: Decodable {
    let paneID: String
    let workspaceID: String?
    let agent: String?
    let agentStatus: String

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agent
        case agentStatus = "agent_status"
    }
}

/// Data for pane.created, pane.closed, pane.agent_detected, and similar events
/// (shared permissive shape).
struct PaneLifecycleData: Decodable {
    let paneID: String?
    let workspaceID: String?
    let agent: String?

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case workspaceID = "workspace_id"
        case agent
    }
}

struct WorkspaceLifecycleData: Decodable {
    let workspaceID: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id"
        case label
    }
}

// MARK: - JSONValue (permissive representation of arbitrary JSON)

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    /// Helper that re-decodes a nested JSONValue as a concrete type.
    func reencoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
