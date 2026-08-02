import Darwin
import Foundation
import os

/// Identity of the herdr Unix-domain socket file used to detect replace/remove
/// without reacting to unrelated directory activity (log writes, session.json, …).
struct HerdrSocketIdentity: Equatable, Sendable {
    var exists: Bool
    /// `(st_dev, st_ino)` when the path exists; `nil` when missing.
    var fileID: (UInt64, UInt64)?

    static func == (lhs: HerdrSocketIdentity, rhs: HerdrSocketIdentity) -> Bool {
        guard lhs.exists == rhs.exists else { return false }
        switch (lhs.fileID, rhs.fileID) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return l.0 == r.0 && l.1 == r.1
        default:
            return false
        }
    }

    /// Probe the filesystem for the socket path. Pure aside from the `stat` call.
    static func probe(path: String) -> HerdrSocketIdentity {
        var st = stat()
        guard stat(path, &st) == 0 else {
            return HerdrSocketIdentity(exists: false, fileID: nil)
        }
        return HerdrSocketIdentity(
            exists: true,
            fileID: (UInt64(st.st_dev), UInt64(st.st_ino))
        )
    }
}

/// Event-driven watcher for the herdr Unix-domain socket path.
///
/// Uses vnode notifications on the parent directory (not polling). Fires only when
/// the socket node itself is created, removed, or replaced — so log churn in
/// `~/.config/herdr` does not thrash the client into reconnect loops.
final class HerdrSocketWatcher: @unchecked Sendable {
    private let socketPath: String
    private let socketDirectory: String
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private let debounce: DispatchTimeInterval
    private let logger = Logger(subsystem: "com.example.HerdEye", category: "socket-watch")

    private var source: DispatchSourceFileSystemObject?
    private var watchedDirectory: String?
    private var watchGeneration = 0
    private var debounceItem: DispatchWorkItem?
    private var lastIdentity: HerdrSocketIdentity
    private var onChange: (@Sendable () -> Void)?
    private var isStarted = false

    init(
        socketPath: String = HerdrSocketTransport.defaultSocketPath,
        debounce: Duration = .milliseconds(300),
        queue: DispatchQueue = DispatchQueue(label: "com.example.HerdEye.socket-watch")
    ) {
        self.socketPath = socketPath
        self.socketDirectory = (socketPath as NSString).deletingLastPathComponent
        self.queue = queue
        self.debounce = Self.dispatchInterval(debounce)
        self.lastIdentity = HerdrSocketIdentity.probe(path: socketPath)
        queue.setSpecific(key: queueKey, value: ())
    }

    /// Begin watching. `onChange` runs on `queue` after debounce when the socket identity changes.
    func start(onChange: @escaping @Sendable () -> Void) {
        syncOnQueue {
            stopOnQueue()
            isStarted = true
            self.onChange = onChange
            lastIdentity = HerdrSocketIdentity.probe(path: socketPath)
            installBestAvailableWatch()
        }
    }

    func stop() {
        syncOnQueue {
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        isStarted = false
        debounceItem?.cancel()
        debounceItem = nil
        onChange = nil
        cancelCurrentSource()
    }

    deinit {
        stop()
    }

    // MARK: - Internals

    /// Watch the socket directory when it exists. If it does not, watch the
    /// closest existing ancestor and move the watch down as directories appear.
    private func installBestAvailableWatch(force: Bool = false) {
        guard isStarted else { return }
        guard let (directory, fd) = Self.openClosestDirectory(startingAt: socketDirectory) else {
            logger.warning("cannot watch an ancestor of \(self.socketDirectory, privacy: .public): errno \(errno)")
            return
        }

        guard force || directory != watchedDirectory else {
            close(fd)
            return
        }

        cancelCurrentSource()
        watchedDirectory = directory
        watchGeneration &+= 1
        let generation = watchGeneration

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.handleDirectoryEvent(generation: generation)
        }
        // Each source owns exactly the descriptor it was created with. Capturing
        // the local value prevents an old asynchronous cancel handler from
        // closing a descriptor installed by a later start/re-arm.
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()

        // Directory creation can outrun the stepwise ancestor re-arm. Probe
        // after the new source is active so a socket created in that window is
        // still observed even if its vnode event belonged to the previous watch.
        detectSocketIdentityChange()

        if directory == socketDirectory {
            logger.debug("watching \(directory, privacy: .public) for \(self.socketPath, privacy: .public)")
        } else {
            logger.debug(
                "watching ancestor \(directory, privacy: .public) until \(self.socketDirectory, privacy: .public) exists"
            )
        }
    }

    private func cancelCurrentSource() {
        watchGeneration &+= 1
        source?.cancel()
        source = nil
        watchedDirectory = nil
    }

    private func handleDirectoryEvent(generation: Int) {
        guard isStarted, generation == watchGeneration, let source else { return }
        let events = source.data
        detectSocketIdentityChange()

        // A source follows a vnode, not a pathname. Re-arm after the watched
        // directory itself is deleted/renamed, and move a fallback ancestor
        // watch closer whenever missing directories are created.
        let watchedNodeMoved = events.contains(.delete) || events.contains(.rename)
        installBestAvailableWatch(force: watchedNodeMoved)
    }

    private func detectSocketIdentityChange() {
        let identity = HerdrSocketIdentity.probe(path: socketPath)
        if identity != lastIdentity {
            lastIdentity = identity
            logger.info(
                "herdr socket identity changed (exists=\(identity.exists)); scheduling reconnect"
            )
            scheduleFire()
        }
    }

    private func scheduleFire() {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func syncOnQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            action()
        } else {
            queue.sync(execute: action)
        }
    }

    private static func openClosestDirectory(startingAt path: String) -> (String, Int32)? {
        var candidate = (path as NSString).standardizingPath
        while !candidate.isEmpty {
            let fd = open(candidate, O_EVTONLY)
            if fd >= 0 {
                var st = stat()
                if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
                    return (candidate, fd)
                }
                close(fd)
            }

            let parent = (candidate as NSString).deletingLastPathComponent
            guard parent != candidate else { break }
            candidate = parent
        }
        return nil
    }

    private static func dispatchInterval(_ duration: Duration) -> DispatchTimeInterval {
        let seconds = duration.components.seconds
        let attoseconds = duration.components.attoseconds
        let nanos = seconds * 1_000_000_000 + attoseconds / 1_000_000_000
        if nanos <= 0 { return .milliseconds(0) }
        if nanos % 1_000_000 == 0 {
            return .milliseconds(Int(nanos / 1_000_000))
        }
        return .nanoseconds(Int(nanos))
    }
}
