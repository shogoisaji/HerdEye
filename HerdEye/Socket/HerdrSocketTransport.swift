import Darwin
import Foundation
import os

/// POSIX Unix-domain socket implementation.
/// Herdr closes the connection immediately after a one-shot RPC response (observed),
/// so each call uses one connection.
final class HerdrSocketTransport: HerdrTransport, @unchecked Sendable {
    static let defaultSocketPath = NSString(string: "~/.config/herdr/herdr.sock").expandingTildeInPath

    private let socketPath: String
    private let logger = Logger(subsystem: "com.example.HerdEye", category: "transport")

    init(socketPath: String = HerdrSocketTransport.defaultSocketPath) {
        self.socketPath = socketPath
    }

    // MARK: - One-shot RPC

    func request(_ method: String, params: [String: JSONValue]) async throws -> HerdrResponse {
        let path = socketPath
        return try await Task.detached(priority: .userInitiated) {
            let fd = try Self.connectSocket(path: path, receiveTimeout: 5)
            defer { Darwin.close(fd) }

            let req = HerdrRequest(id: "req_\(UUID().uuidString.prefix(8))", method: method, params: params)
            var payload = try JSONEncoder().encode(req)
            payload.append(UInt8(ascii: "\n"))
            try Self.writeAll(fd: fd, data: payload)

            // Read until a newline or EOF. EOF is expected because the server closes
            // the connection immediately after responding.
            var reader = NDJSONLineReader()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &buf, buf.count)
                if n < 0 { throw HerdrTransportError.connectionFailed(errno) }
                if n == 0 {
                    if let rest = reader.flush(), let resp = try? JSONDecoder().decode(HerdrResponse.self, from: rest) {
                        return try Self.unwrap(resp)
                    }
                    throw HerdrTransportError.emptyResponse
                }
                if let line = reader.append(Data(buf[0..<n])).first {
                    return try Self.unwrap(try JSONDecoder().decode(HerdrResponse.self, from: line))
                }
            }
        }.value
    }

    private static func unwrap(_ resp: HerdrResponse) throws -> HerdrResponse {
        if let err = resp.error {
            throw HerdrTransportError.rpcError(code: err.code, message: err.message)
        }
        return resp
    }

    // MARK: - Subscription stream

    func openEventStream(subscriptions: [JSONValue]) -> HerdrEventStream {
        let path = socketPath
        let logger = self.logger
        let lifetime = EventStreamLifetime()
        let ready = SubscriptionReadySignal()
        let stream = AsyncThrowingStream<HerdrStreamLine, Error> { continuation in
            let task = Task.detached(priority: .utility) {
                var subscribed = false
                do {
                    let fd = try Self.connectSocket(path: path, receiveTimeout: 0)
                    lifetime.install(fd: fd)
                    defer { lifetime.closeFD() }

                    guard !Task.isCancelled else {
                        ready.fail(CancellationError())
                        continuation.finish()
                        return
                    }

                    let req = HerdrRequest(id: "sub", method: "events.subscribe",
                                           params: ["subscriptions": .array(subscriptions)])
                    var payload = try JSONEncoder().encode(req)
                    payload.append(UInt8(ascii: "\n"))
                    try Self.writeAll(fd: fd, data: payload)

                    var reader = NDJSONLineReader()
                    var buf = [UInt8](repeating: 0, count: 65536)
                    while !Task.isCancelled {
                        let n = Darwin.read(fd, &buf, buf.count)
                        if n <= 0 { break }
                        for line in reader.append(Data(buf[0..<n])) {
                            let decoded = HerdrStreamLine.decode(line)
                            if !subscribed, case .response(let response) = decoded {
                                subscribed = true
                                if let error = response.error {
                                    ready.fail(HerdrTransportError.rpcError(
                                        code: error.code, message: error.message))
                                } else {
                                    ready.succeed()
                                }
                            }
                            continuation.yield(decoded)
                        }
                    }
                    if !subscribed {
                        ready.fail(Task.isCancelled
                                   ? CancellationError()
                                   : HerdrTransportError.emptyResponse)
                    }
                    continuation.finish()
                } catch {
                    logger.error("event stream failed: \(String(describing: error))")
                    ready.fail(error)
                    continuation.finish(throwing: error)
                }
            }
            lifetime.install(task: task)
            continuation.onTermination = { _ in
                lifetime.cancel()
            }
        }
        return HerdrEventStream(
            stream: stream,
            waitUntilSubscribed: { try await ready.wait() },
            cancel: { lifetime.cancel() }
        )
    }

    // MARK: - POSIX helpers

    private static func connectSocket(path: String, receiveTimeout seconds: Int) throws -> Int32 {
        guard FileManager.default.fileExists(atPath: path) else {
            throw HerdrTransportError.socketUnavailable(path)
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrTransportError.connectionFailed(errno) }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE,
                   &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= maxLen else {
            Darwin.close(fd)
            throw HerdrTransportError.socketUnavailable(path)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }

        if seconds > 0 {
            var tv = timeval(tv_sec: seconds, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            throw HerdrTransportError.connectionFailed(err)
        }
        return fd
    }

    private static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { throw HerdrTransportError.connectionFailed(errno) }
                offset += n
            }
        }
    }

    private final class EventStreamLifetime: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var task: Task<Void, Never>?
        private var cancelled = false

        func install(task: Task<Void, Never>) {
            lock.lock()
            if cancelled {
                lock.unlock()
                task.cancel()
            } else {
                self.task = task
                lock.unlock()
            }
        }

        func install(fd: Int32) {
            lock.lock()
            if cancelled {
                lock.unlock()
                Darwin.close(fd)
            } else {
                self.fd = fd
                lock.unlock()
            }
        }

        func closeFD() {
            lock.lock()
            let fd = self.fd
            self.fd = -1
            lock.unlock()
            if fd >= 0 { Darwin.close(fd) }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            let fd = self.fd
            self.fd = -1
            lock.unlock()

            task?.cancel()
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    /// Cancellable wait signal that reports the subscription ack exactly once.
    private final class SubscriptionReadySignal: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        private var result: Result<Void, Error>?

        func wait() async throws {
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    lock.lock()
                    if let result {
                        lock.unlock()
                        continuation.resume(with: result)
                    } else if Task.isCancelled {
                        self.result = .failure(CancellationError())
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                    } else {
                        self.continuation = continuation
                        lock.unlock()
                    }
                }
            }, onCancel: {
                self.fail(CancellationError())
            })
        }

        func succeed() {
            resolve(.success(()))
        }

        func fail(_ error: Error) {
            resolve(.failure(error))
        }

        private func resolve(_ result: Result<Void, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
