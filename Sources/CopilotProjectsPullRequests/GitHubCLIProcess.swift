import Foundation
import Darwin

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

        init(process: Process, collectors: [Collector], grace: TimeInterval) {
            self.process = process
            self.collectors = collectors
            self.grace = grace
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        /// Asks gh to stop, kills it after the grace period, and then stops
        /// waiting for output that something it started may still hold open.
        func stop(timedOut: Bool) {
            let first: Bool = lock.withLock {
                if timedOut { didTimeOut = true }
                defer { isStopping = true }
                return !isStopping
            }
            guard first else { return }
            if process.isRunning { process.terminate() }
            let process = self.process
            let collectors = self.collectors
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                collectors.forEach { $0.finish() }
            }
        }
    }
}
