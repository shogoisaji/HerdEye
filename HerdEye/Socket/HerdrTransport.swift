import Foundation

struct HerdrEventStream {
    let stream: AsyncThrowingStream<HerdrStreamLine, Error>
    /// Wait until the ack for `events.subscribe` is received.
    let waitUntilSubscribed: @Sendable () async throws -> Void
    let cancel: @Sendable () -> Void
}

protocol HerdrTransport: Sendable {
    /// One-shot RPC. Open a new connection for each request and finish after one
    /// response line (or EOF).
    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse

    /// Subscription stream. Send events.subscribe exactly once per connection,
    /// then yield the ack line followed by push lines. Finish when the connection closes.
    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream
}

enum HerdrTransportError: Error, Equatable {
    case socketUnavailable(String)
    case connectionFailed(Int32)
    case emptyResponse
    case rpcError(code: String, message: String)
}
