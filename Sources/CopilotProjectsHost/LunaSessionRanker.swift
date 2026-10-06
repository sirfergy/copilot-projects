import Foundation
import CopilotProjectsCore

protocol SessionRanking: Sendable {
    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch]
}

enum LunaSearchError: Error, Equatable {
    case copilotUnavailable
    case notSignedIn
    case timedOut
    case failed(String)
    case unreadableResponse

    var message: String {
        switch self {
        case .copilotUnavailable: return "Luna needs the Copilot CLI, which wasn't found."
        case .notSignedIn: return "Sign in to the Copilot CLI so Luna can search."
        case .timedOut: return "Luna took too long to answer. Keep typing to try again."
        case .failed(let detail): return "Luna couldn't search: \(detail)"
        case .unreadableResponse: return "Luna's answer couldn't be read. Keep typing to try again."
        }
    }
}

/// Ranks sessions with a one-shot, tool-less `copilot -p` run that always uses Luna.
///
/// Each run gets a throwaway `COPILOT_HOME` seeded only with the signed-in account
/// (the token itself stays in the keychain). That keeps these runs out of the
/// user's Copilot session history and skips their MCP servers, hooks, plugins, and
/// extensions, which also makes startup several seconds faster. Copilot Projects
/// session variables are never passed through, so neither the tracker nor the
/// hooks can mistake a run for a tab.
struct LunaSessionRanker: SessionRanking {
    static let model = "gpt-6-luna"
    /// Run directories left by a crash are reclaimed once they are this old.
    static let staleRunAge: TimeInterval = 600

    var copilotExecutable: @Sendable () -> String? = { Paths.copilotExecutable }
    var workRoot: URL = Paths.stateDir.appendingPathComponent("session-finder", isDirectory: true)
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var timeout: TimeInterval = 45
    /// How long a stopped run gets to exit before it and its subprocesses are killed.
    var terminationGrace: TimeInterval = 2

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        guard let executable = copilotExecutable() else { throw LunaSearchError.copilotUnavailable }
        let built = LunaSessionPrompt.build(query: query, entries: entries)
        guard !built.aliases.isEmpty else { return [] }
        let home = try prepareRunHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = try await LunaProcess.run(
            executable: executable,
            arguments: Self.arguments(prompt: built.prompt),
            environment: Self.childEnvironment(from: environment, copilotHome: home.path),
            directory: home,
            timeout: timeout,
            terminationGrace: terminationGrace
        )
        guard result.status == 0 else { throw Self.failure(from: result) }
        let reply = Self.assistantReply(fromJSONL: result.output) ?? result.output
        do {
            return try LunaSessionPrompt.parse(reply, aliases: built.aliases)
        } catch {
            throw LunaSearchError.unreadableResponse
        }
    }

    static func arguments(prompt: String) -> [String] {
        [
            "-p", prompt,
            "--model", model,
            // JSONL events carry the reply verbatim; plain text output is
            // word-wrapped, which can break a JSON answer across lines.
            "--output-format", "json",
            "--no-custom-instructions",
            "--disable-builtin-mcps",
            "--no-ask-user",
            // An allowlist naming no real tool. An empty `--available-tools=` is
            // ignored by Copilot CLI 1.0.92, which then still offers its shell tool.
            "--available-tools=none",
            "--stream", "off",
            "--no-auto-update",
            "--reasoning-effort", "low",
            "--no-color",
        ]
    }

    private struct Event: Decodable {
        struct Payload: Decodable { let content: String? }
        let type: String
        let data: Payload?
    }

    /// The last non-empty `assistant.message` content in `--output-format json` output.
    static func assistantReply(fromJSONL output: String) -> String? {
        let decoder = JSONDecoder()
        var reply: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)),
                  event.type == "assistant.message",
                  let content = event.data?.content,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            reply = content
        }
        return reply
    }

    private static let inheritedVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "TMPDIR", "PATH", "SHELL", "LANG", "LC_ALL", "LC_CTYPE",
        "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "ALL_PROXY",
        "https_proxy", "http_proxy", "no_proxy", "all_proxy",
        "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS",
        "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST",
    ]

    /// An allowlist, so session-targeting variables such as `COPILOT_PROJECTS_SESSION`
    /// and an enclosing Copilot session's own variables never reach the run.
    static func childEnvironment(from environment: [String: String], copilotHome: String) -> [String: String] {
        var child = environment.filter { inheritedVariables.contains($0.key) }
        child["COPILOT_HOME"] = copilotHome
        child["COPILOT_AUTO_UPDATE"] = "false"
        return child
    }

    /// The signed-in account fields from the user's Copilot `config.json`, which
    /// is JSON with `//` comment lines. Anything unreadable seeds an empty config,
    /// and the run then reports that sign-in is needed.
    static func loginSeed(fromConfig data: Data?) -> Data {
        let empty = Data("{}".utf8)
        guard let data, let text = String(data: data, encoding: .utf8) else { return empty }
        let json = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return empty
        }
        let seed = object.filter { $0.key == "lastLoggedInUser" || $0.key == "loggedInUsers" }
        return (try? JSONSerialization.data(withJSONObject: seed)) ?? empty
    }

    private var userConfigURL: URL {
        if let home = environment["COPILOT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                .appendingPathComponent("config.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/config.json")
    }

    private func prepareRunHome() throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: workRoot, withIntermediateDirectories: true)
        let cutoff = Date().addingTimeInterval(-Self.staleRunAge)
        for leftover in (try? fileManager.contentsOfDirectory(
            at: workRoot, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [] {
            let modified = (try? leftover.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if modified < cutoff { try? fileManager.removeItem(at: leftover) }
        }
        let home = workRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        do {
            try Self.loginSeed(fromConfig: try? Data(contentsOf: userConfigURL))
                .write(to: home.appendingPathComponent("config.json"), options: .atomic)
        } catch {
            try? fileManager.removeItem(at: home)
            throw error
        }
        return home
    }

    static func failure(from result: LunaProcess.Result) -> LunaSearchError {
        let text = diagnostics(from: result)
        if text.contains("/login") || text.localizedCaseInsensitiveContains("not authenticated")
            || text.localizedCaseInsensitiveContains("authenticate") {
            return .notSignedIn
        }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .failed(LunaSessionPrompt.clip(line ?? "exit status \(result.status)", 120))
    }

    private struct EventType: Decodable { let type: String }

    /// What the CLI itself said: stderr, plain stdout lines, and error events. The
    /// other JSONL events carry conversation text (`user.message` echoes the whole
    /// prompt), which can mention signing in without the run having failed for it.
    static func diagnostics(from result: LunaProcess.Result) -> String {
        let decoder = JSONDecoder()
        let lines = result.output.split(whereSeparator: \.isNewline).filter { line in
            guard let event = try? decoder.decode(EventType.self, from: Data(line.utf8)) else { return true }
            return event.type.localizedCaseInsensitiveContains("error")
        }
        return ([result.errorOutput] + lines.map(String.init)).joined(separator: "\n")
    }
}

/// Runs one process to completion, stopping it on cancellation or timeout.
enum LunaProcess {
    struct Result: Equatable, Sendable {
        let status: Int32
        let output: String
        let errorOutput: String
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
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        let run = RunState(process, terminationGrace: terminationGrace)
        // Weak, so a launch that throws can't strand the handler and state in a cycle.
        process.terminationHandler = { [weak run] in run?.finish($0.terminationStatus) }
        try process.run()
        run.recordLaunch()
        let outputReader = PipeReader(output)
        let errorReader = PipeReader(errorOutput)

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            run.terminate(timedOut: true)
        }
        defer { watchdog.cancel() }
        // Draining stays cancellable: a subprocess that outlives copilot can hold
        // the pipes open after copilot itself has exited.
        let (status, stdout, stderr) = await withTaskCancellationHandler {
            let status = await run.exitStatus()
            return (status, await outputReader.text(), await errorReader.text())
        } onCancel: {
            run.terminate(timedOut: false)
        }
        run.markDrained()
        // A terminated copilot can still exit 0, so our own reasons win.
        try Task.checkCancellation()
        if run.timedOut { throw LunaSearchError.timedOut }
        return Result(status: status, output: stdout, errorOutput: stderr)
    }

    /// A value delivered once from a callback or blocking thread to async waiters.
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

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let terminationGrace: TimeInterval
        private let exit = OneShot<Int32>()
        private var didTimeOut = false
        private var isStopping = false
        private var isDrained = false
        private var root: ProcessIdentity?

        init(_ process: Process, terminationGrace: TimeInterval) {
            self.process = process
            self.terminationGrace = terminationGrace
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func finish(_ status: Int32) { exit.deliver(status) }

        func exitStatus() async -> Int32 { await exit.wait() }

        func recordLaunch() {
            let identity = ProcessIdentity(process.processIdentifier)
            lock.withLock { root = identity }
        }

        /// The run has exited and closed its output, so there is nothing left to kill.
        func markDrained() { lock.withLock { isDrained = true } }

        /// The group's id is copilot's pid, so the group is only signalled while that
        /// pid is still copilot's or belongs to no process at all.
        private func signalGroup(_ pid: pid_t, _ signal: Int32) {
            let root = lock.withLock { self.root }
            if let current = ProcessIdentity(pid), current != root { return }
            kill(-pid, signal)
        }

        /// Asks the run and everything it started to stop, then kills whatever is
        /// left after the grace period: a run that ignores SIGTERM would otherwise
        /// never exit, and a subprocess holding the output pipes open would keep
        /// the reads from finishing. `Process` starts copilot as the leader of its
        /// own process group, and the group still reaches subprocesses that copilot
        /// left behind when it exited.
        func terminate(timedOut: Bool) {
            let first: Bool = lock.withLock {
                if timedOut { didTimeOut = true }
                defer { isStopping = true }
                return !isStopping
            }
            let pid = process.processIdentifier
            guard first, pid > 0 else { return }
            let rootRunning = process.isRunning
            let started = rootRunning ? LunaProcess.descendants(of: pid) : []
            if rootRunning { process.terminate() }
            signalGroup(pid, SIGTERM)
            started.forEach { $0.signal(SIGTERM) }
            let process = self.process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [self] in
                // A drained run is over, and its ids may belong to other processes by now.
                guard !lock.withLock({ isDrained }) else { return }
                let stillRunning = process.isRunning
                var survivors = Set(started)
                if stillRunning { survivors.formUnion(LunaProcess.descendants(of: pid)) }
                survivors.forEach { $0.signal(SIGKILL) }
                signalGroup(pid, SIGKILL)
                if stillRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// A process as it was when seen. The start time tells it apart from a later
    /// process that reuses its pid, so a delayed signal never reaches the wrong one.
    struct ProcessIdentity: Hashable, Sendable {
        let pid: pid_t
        let started: UInt64

        init?(_ pid: pid_t) {
            guard let started = Self.startTime(of: pid) else { return nil }
            self.pid = pid
            self.started = started
        }

        var isCurrent: Bool { Self.startTime(of: pid) == started }

        func signal(_ signal: Int32) {
            if isCurrent { kill(pid, signal) }
        }

        private static func startTime(of pid: pid_t) -> UInt64? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        }
    }

    /// Every process descended from `root`, read before it is signalled because
    /// orphans are re-parented and can no longer be traced back to it.
    static func descendants(of root: pid_t) -> [ProcessIdentity] {
        let tree = ProcessTree.snapshot()
        var seen = Set<pid_t>()
        var found: [ProcessIdentity] = []
        var pending = tree.childrenOf[root] ?? []
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let identity = ProcessIdentity(pid) { found.append(identity) }
            pending.append(contentsOf: tree.childrenOf[pid] ?? [])
        }
        return found
    }

    /// Drains a pipe on a dispatch thread so the blocking read never occupies the
    /// Swift concurrency pool, and a full pipe can never stall the child.
    private final class PipeReader: @unchecked Sendable {
        private let data = OneShot<Data>()

        init(_ pipe: Pipe) {
            let handle = pipe.fileHandleForReading
            let data = data
            DispatchQueue.global(qos: .userInitiated).async {
                data.deliver(handle.readDataToEndOfFile())
            }
        }

        func text() async -> String {
            String(decoding: await data.wait(), as: UTF8.self)
        }
    }
}
