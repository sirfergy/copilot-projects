import Foundation
import Darwin
import CopilotProjectsCore

/// Runs a short `gh` command with a deadline. Output stays in memory; nothing
/// secret is ever passed on the command line.
enum GitHubCLIProcess {
    struct Result: Equatable, Sendable {
        let status: Int32
        let output: String
        let errorOutput: String
    }

    struct TimedOut: Error, LocalizedError {
        var errorDescription: String? { "The GitHub CLI took too long to answer. Refresh to try again." }
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 2
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let exit = OneShot<Int32>()
        process.terminationHandler = { exit.deliver($0.terminationStatus) }
        let output = Collector(outputPipe)
        let errorOutput = Collector(errorPipe)
        do {
            try process.run()
        } catch {
            output.finish()
            errorOutput.finish()
            throw error
        }

        let run = Run(process: process, collectors: [output, errorOutput], grace: terminationGrace)
        run.recordLaunch()
        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            run.stop(timedOut: true)
        }
        defer { watchdog.cancel() }
        let (status, stdout, stderr) = await withTaskCancellationHandler {
            let status = await exit.wait()
            return (status, await output.text(), await errorOutput.text())
        } onCancel: {
            run.stop(timedOut: false)
        }
        run.markDrained()
        try Task.checkCancellation()
        if run.timedOut { throw TimedOut() }
        return Result(status: status, output: stdout, errorOutput: stderr)
    }

    /// A value delivered once, from a callback or another thread, to async waiters.
    private final class OneShot<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?
        private var waiters: [CheckedContinuation<Value, Never>] = []

        func deliver(_ delivered: Value) {
            let resumed: [CheckedContinuation<Value, Never>] = lock.withLock {
                guard value == nil else { return [] }
                value = delivered
                defer { waiters = [] }
                return waiters
            }
            resumed.forEach { $0.resume(returning: delivered) }
        }

        func wait() async -> Value {
            await withCheckedContinuation { continuation in
                let ready: Value? = lock.withLock {
                    if let value { return value }
                    waiters.append(continuation)
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        }
    }

    /// Reads a pipe as data arrives, so a full pipe never stalls the child and a
    /// stuck writer can be given up on.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let done = OneShot<Data>()
        private let handle: FileHandle

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                guard let self else { return }
                if chunk.isEmpty {
                    self.finish()
                } else {
                    self.lock.withLock { self.data.append(chunk) }
                }
            }
        }

        func finish() {
            handle.readabilityHandler = nil
            done.deliver(lock.withLock { data })
        }

        func text() async -> String {
            String(decoding: await done.wait(), as: UTF8.self)
        }
    }

    private final class Run: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let collectors: [Collector]
        private let grace: TimeInterval
        private var didTimeOut = false
        private var isStopping = false
        private var isDrained = false
        private var root: ProcessTree.Identity?

        init(process: Process, collectors: [Collector], grace: TimeInterval) {
            self.process = process
            self.collectors = collectors
            self.grace = grace
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func recordLaunch() {
            let identity = ProcessTree.Identity(process.processIdentifier)
            lock.withLock { root = identity }
        }

        /// gh has exited and closed its output, so there is nothing left to kill.
        func markDrained() { lock.withLock { isDrained = true } }

        /// The group's id is gh's pid, so the group is only signalled while that
        /// pid is still gh's or belongs to no process at all.
        private func signalGroup(_ pid: pid_t, _ signal: Int32) {
            let root = lock.withLock { self.root }
            if let current = ProcessTree.Identity(pid), current != root { return }
            kill(-pid, signal)
        }

        /// Asks gh and everything it started to stop, kills whatever is left
        /// after the grace period, and then stops waiting for output that
        /// something out of reach may still hold open. `Process` starts gh as
        /// the leader of its own process group, and the group still reaches
        /// subprocesses gh left behind when it exited.
        func stop(timedOut: Bool) {
            let first: Bool = lock.withLock {
                if timedOut { didTimeOut = true }
                defer { isStopping = true }
                return !isStopping
            }
            let pid = process.processIdentifier
            guard first, pid > 0 else { return }
            let rootRunning = process.isRunning
            let started = rootRunning ? ProcessTree.descendants(of: pid) : []
            if rootRunning { process.terminate() }
            signalGroup(pid, SIGTERM)
            started.forEach { $0.signal(SIGTERM) }
            let process = self.process
            let collectors = self.collectors
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [self] in
                // A drained run is over, and its ids may belong to other processes by now.
                if !lock.withLock({ isDrained }) {
                    let stillRunning = process.isRunning
                    var survivors = Set(started)
                    if stillRunning { survivors.formUnion(ProcessTree.descendants(of: pid)) }
                    survivors.forEach { $0.signal(SIGKILL) }
                    signalGroup(pid, SIGKILL)
                    if stillRunning { kill(pid, SIGKILL) }
                }
                collectors.forEach { $0.finish() }
            }
        }
    }
}
