import Foundation
#if canImport(Darwin)
import Darwin
#endif
import CopilotProjectsCore

/// Accepts one-shot JSON-line requests on a Unix domain socket and replies with
/// one JSON-line response. The handler runs on the server's background queue;
/// it is responsible for any main-actor hop it needs.
// The accept loop is confined to `queue`; start/stop run on the main actor and
// shutdown crosses the boundary only by closing the listening fd, which wakes
// `accept`. The class owns those synchronization rules explicitly.
final class ControlServer: @unchecked Sendable {
    typealias MainQueueScheduler = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// Default main-actor dispatch deadline for a control-socket command. Kept
    /// strictly below `ControlClient().timeout` (3s) so a stalled main thread
    /// returns `.failure("the app is busy", code: "busy")` before the client's
    /// socket read times out.
    static let defaultMainActorTimeout: TimeInterval = 2
    static let busyResponse = ControlResponse.failure("the app is busy", code: "busy")
    static let defaultMainQueueScheduler: MainQueueScheduler = { work in
        DispatchQueue.main.async(execute: work)
    }
    typealias Waiting = @Sendable () async -> ControlResponse

    private let socketPath: String
    /// The answer to a command that waits for its result, such as a park. It is
    /// awaited off the accept loop, so other commands are still served: a park
    /// stops a Copilot whose `session-ended` hook arrives on this socket.
    private let waiting: (ControlRequest) -> Waiting?
    private let handler: (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1
    private var running = false
    private var boundSocket = false
    private let queue = DispatchQueue(label: "com.obvioussean.copilot-projects.control")

    init(socketPath: String = Paths.socketPath,
         waiting: @escaping (ControlRequest) -> Waiting? = { _ in nil },
         handler: @escaping (ControlRequest) -> ControlResponse) {
        self.socketPath = socketPath
        self.waiting = waiting
        self.handler = handler
    }

    /// Dispatches `operation` onto the main actor and waits up to `timeout` seconds
    /// for the main queue to begin servicing it. If the deadline expires while the
    /// block is still queued, returns `nil` and marks the box `.timedOut` so the
    /// queued block becomes a no-op when the main queue later drains it. Once the
    /// main actor begins executing `operation` before the deadline, its side effects
    /// are in progress and this call waits for its result rather than reporting `busy`.
    static func runOnMainActor<Value: Sendable>(
        timeout: TimeInterval = defaultMainActorTimeout,
        scheduler: MainQueueScheduler = defaultMainQueueScheduler,
        _ operation: @escaping @MainActor @Sendable () -> Value
    ) -> Value? {
        let boundedTimeout = max(timeout, 0)
        let deadline = DispatchTime.now() + boundedTimeout
        let box = MainActorDispatchBox<Value>(deadline: deadline)
        let semaphore = DispatchSemaphore(value: 0)
        scheduler {
            guard box.beginExecution() else { return }
            let value = MainActor.assumeIsolated {
                operation()
            }
            box.complete(value)
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: deadline)
        switch box.resolveAfterDeadlineWait() {
        case .completed(let value):
            return value
        case .timedOutBeforeStart:
            return nil
        case .running:
            semaphore.wait()
            return box.completedValue()
        }
    }

    @discardableResult
    func start() -> Bool {
        Paths.ensureStateDir()
        // Don't steal the socket from a still-running instance: only remove a stale
        // socket file that nothing is listening on.
        if socketIsAlive(socketPath) {
            NSLog("copilot-projects control: another instance is already listening on \(socketPath); not starting a second control server")
            return false
        }
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("copilot-projects control: socket() failed errno \(errno)")
            return false
        }
        guard SocketOptions.suppressSigPipe(on: fd) else {
            NSLog("copilot-projects control: listener SO_NOSIGPIPE failed errno \(errno)")
            close(fd)
            return false
        }
        // Don't let spawned children (each dtach helper, and the shells under them)
        // inherit the listening socket. Without FD_CLOEXEC every dtach we launch keeps
        // a copy of this fd open, leaking one descriptor per session/relaunch and
        // pinning the socket inode — over a long-lived app that grows without bound.
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            NSLog("copilot-projects control: socket path too long")
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }

        let bound = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            NSLog("copilot-projects control: bind failed errno \(errno)")
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)

        guard listen(fd, 16) == 0 else {
            NSLog("copilot-projects control: listen failed errno \(errno)")
            close(fd)
            return false
        }

        listenFD = fd
        running = true
        boundSocket = true
        queue.async { [weak self] in self?.acceptLoop() }
        NSLog("copilot-projects control: listening on \(socketPath)")
        return true
    }

    func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        if boundSocket {
            unlink(socketPath)
            boundSocket = false
        }
    }

    /// True if a process is currently accepting on `path` (a live listener), vs. a
    /// stale leftover socket file that connect() refuses with ECONNREFUSED.
    private func socketIsAlive(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return false }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let r = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return r == 0
    }

    private func acceptLoop() {
        acceptLoop: while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                let code = errno
                if !running { break }
                switch code {
                case EINTR, ECONNABORTED:
                    continue
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    usleep(100_000)
                    continue
                case EBADF, EINVAL:
                    break acceptLoop
                default:
                    NSLog("copilot-projects control: accept failed errno \(code)")
                    usleep(100_000)
                    continue
                }
            }
            // Spawned children must not inherit live client connections either.
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        var handedOver = false
        defer { if !handedOver { close(fd) } }

        // Bound the read so a stuck or malicious same-user client that connects and
        // never sends a newline can't wedge the (serial) accept loop or grow this
        // buffer without bound: time out the read and cap the request size.
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let maxRequest = 64 * 1024

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            data.append(contentsOf: buf[0..<n])
            if buf[0..<n].contains(0x0A) { break }
            if data.count > maxRequest { return }   // oversized, no newline → drop
        }
        guard !data.isEmpty else { return }

        let line = data.firstIndex(of: 0x0A)
            .map { data.subdata(in: data.startIndex..<$0) } ?? data

        let response: ControlResponse
        do {
            let req = try Wire.decode(ControlRequest.self, from: line)
            if let answer = waiting(req) {
                handedOver = true
                Task {
                    ControlServer.reply(await answer(), to: fd)
                    close(fd)
                }
                return
            }
            response = handler(req)
        } catch {
            response = .failure("bad request: \(error)")
        }
        ControlServer.reply(response, to: fd)
    }

    private static func reply(_ response: ControlResponse, to fd: Int32) {
        guard let out = try? Wire.encodeLine(response) else { return }
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var off = 0
            while off < raw.count {
                let n = write(fd, base + off, raw.count - off)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno != EPIPE
                        && errno != ECONNRESET
                        && errno != EAGAIN
                        && errno != EWOULDBLOCK {
                        NSLog("copilot-projects control: response write failed errno \(errno)")
                    }
                    break
                }
                if n == 0 { break }
                off += n
            }
        }
    }
}

final class MainActorDispatchBox<Value: Sendable>: @unchecked Sendable {
    enum WaitResolution {
        case completed(Value)
        case running
        case timedOutBeforeStart
    }

    private enum State {
        case pending
        case running
        case completed(Value)
        case timedOut
    }

    private let lock = NSLock()
    private let deadline: DispatchTime
    private var state: State = .pending

    init(deadline: DispatchTime) {
        self.deadline = deadline
    }

    func beginExecution() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .pending = state else { return false }
        guard DispatchTime.now() <= deadline else {
            state = .timedOut
            return false
        }
        state = .running
        return true
    }

    func complete(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        state = .completed(value)
    }

    func resolveAfterDeadlineWait() -> WaitResolution {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .completed(let value):
            return .completed(value)
        case .running:
            return .running
        case .pending:
            state = .timedOut
            return .timedOutBeforeStart
        case .timedOut:
            return .timedOutBeforeStart
        }
    }

    func completedValue() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        if case .completed(let value) = state {
            return value
        }
        return nil
    }
}
