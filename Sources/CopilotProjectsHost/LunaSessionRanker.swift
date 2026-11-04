import Foundation
import SQLite3
import CopilotProjectsCore

protocol SessionRanking: Sendable {
    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch]
}

protocol SessionHistorySearching: Sendable {
    func searchHistory(
        query: String,
        excludedCopilotSessionIds: Set<String>
    ) async throws -> [LunaMatch]
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
struct LunaSessionRanker: SessionRanking, SessionHistorySearching {
    static let model = "gpt-6-luna"
    /// Run directories left by a crash are reclaimed once they are this old.
    static let staleRunAge: TimeInterval = 600

    var copilotExecutable: @Sendable () -> String? = { Paths.copilotExecutable }
    var workRoot: URL = Paths.stateDir.appendingPathComponent("session-finder", isDirectory: true)
    var environment: [String: String] = ProcessInfo.processInfo.environment
    var timeout: TimeInterval = 45
    var historyTimeout: TimeInterval = 60
    /// How long a stopped run gets to exit before it and its subprocesses are killed.
    var terminationGrace: TimeInterval = 2
    var sleep: @Sendable (TimeInterval) async -> Void = LunaProcess.defaultSleep

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        guard let executable = copilotExecutable() else { throw LunaSearchError.copilotUnavailable }
        let built = LunaSessionPrompt.build(query: query, entries: entries)
        guard !built.aliases.isEmpty else { return [] }
        let home = try prepareRunHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let reply = try await runPrompt(
            executable: executable,
            arguments: Self.arguments(prompt: built.prompt),
            home: home,
            timeout: timeout
        )
        do {
            return try LunaSessionPrompt.parse(reply, aliases: built.aliases)
        } catch {
            throw LunaSearchError.unreadableResponse
        }
    }

    /// Searches the full local `session-store.db` via a one-shot `copilot -p` run in an
    /// isolated throwaway `COPILOT_HOME` containing a snapshot of the database. The
    /// temporary home (and the session opened inside it to run the search) is removed
    /// when the run completes or is cancelled.
    func searchHistory(
        query: String,
        excludedCopilotSessionIds: Set<String> = []
    ) async throws -> [LunaMatch] {
        guard let executable = copilotExecutable() else { throw LunaSearchError.copilotUnavailable }
        let trimmed = SessionFinderSearch.collapseWhitespace(query)
        guard !trimmed.isEmpty else { return [] }
        let sourceDB = userSessionStoreURL
        guard FileManager.default.fileExists(atPath: sourceDB.path) else { return [] }
        try Task.checkCancellation()
        let home = try prepareRunHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.copySessionStoreDatabase(
            from: sourceDB.path,
            to: home.appendingPathComponent("session-store.db").path
        )
        try Task.checkCancellation()
        let prompt = LunaDeepSessionPrompt.build(
            query: trimmed,
            excludedCopilotSessionIds: excludedCopilotSessionIds
        )
        let reply = try await runPrompt(
            executable: executable,
            arguments: Self.historySearchArguments(prompt: prompt),
            home: home,
            timeout: historyTimeout
        )
        do {
            return try LunaDeepSessionPrompt.parse(
                reply,
                excludedCopilotSessionIds: excludedCopilotSessionIds
            )
        } catch {
            throw LunaSearchError.unreadableResponse
        }
    }

    private func runPrompt(
        executable: String,
        arguments: [String],
        home: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let result = try await LunaProcess.run(
            executable: executable,
            arguments: arguments,
            environment: Self.childEnvironment(from: environment, copilotHome: home.path),
            directory: home,
            timeout: timeout,
            terminationGrace: terminationGrace,
            sleep: sleep
        )
        guard result.status == 0 else { throw Self.failure(from: result) }
        return Self.assistantReply(fromJSONL: result.output) ?? result.output
    }

    static func arguments(prompt: String) -> [String] {
        arguments(prompt: prompt, availableTools: "none")
    }

    static func historySearchArguments(prompt: String) -> [String] {
        arguments(prompt: prompt, availableTools: "session_store_sql,sql")
    }

    private static func arguments(prompt: String, availableTools: String) -> [String] {
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
            "--available-tools=\(availableTools)",
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

    private var userCopilotHomeURL: URL {
        if let home = environment["COPILOT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot", isDirectory: true)
    }

    private var userConfigURL: URL {
        userCopilotHomeURL.appendingPathComponent("config.json")
    }

    private var userSessionStoreURL: URL {
        userCopilotHomeURL.appendingPathComponent("session-store.db")
    }

    /// Snapshots `sourcePath` (opened strictly read-only) into a writable SQLite
    /// database at `destinationPath` so the isolated CLI run can query — and, if
    /// needed, migrate — its disposable copy without touching the user's store.
    static func copySessionStoreDatabase(from sourcePath: String, to destinationPath: String) throws {
        var sourceDB: OpaquePointer?
        let sourceURI = URL(fileURLWithPath: sourcePath).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(sourceURI, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let sourceDB else {
            let detail = sourceDB.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open source failed"
            sqlite3_close(sourceDB)
            throw LunaSearchError.failed(detail)
        }
        defer { sqlite3_close(sourceDB) }
        sqlite3_busy_timeout(sourceDB, 250)

        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(
            destinationPath,
            &destinationDB,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
            nil
        ) == SQLITE_OK, let destinationDB else {
            let detail = destinationDB.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "open copy failed"
            sqlite3_close(destinationDB)
            throw LunaSearchError.failed(detail)
        }
        defer { sqlite3_close(destinationDB) }
        sqlite3_busy_timeout(destinationDB, 250)

        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            let detail = sqlite3_errmsg(destinationDB).map { String(cString: $0) } ?? "backup init failed"
            throw LunaSearchError.failed(detail)
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            let detail = sqlite3_errmsg(destinationDB).map { String(cString: $0) } ?? "backup failed"
            throw LunaSearchError.failed(detail)
        }
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

    static let defaultSleep: @Sendable (TimeInterval) async -> Void = {
        try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000))
    }

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        directory: URL,
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 2,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = defaultSleep
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
        let output = Collector(outputPipe)
        let errorOutput = Collector(errorPipe)
        defer {
            output.finish()
            errorOutput.finish()
        }
        let run = RunState(
            process,
            collectors: [output, errorOutput],
            terminationGrace: terminationGrace
        )
        // Weak, so a launch that throws can't strand the handler and state in a cycle.
        process.terminationHandler = { [weak run] in run?.finish($0.terminationStatus) }
        try process.run()
        run.recordLaunch()

        let watchdog = Task.detached {
            await sleep(timeout)
            guard !Task.isCancelled else { return }
            run.terminate(timedOut: true)
        }
        defer { watchdog.cancel() }
        // Draining stays cancellable: a subprocess that outlives copilot can hold
        // the pipes open after copilot itself has exited.
        let (status, stdout, stderr) = await withTaskCancellationHandler {
            let status = await run.exitStatus()
            return (status, await output.text(), await errorOutput.text())
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
        private let collectors: [Collector]
        private let terminationGrace: TimeInterval
        private let exit = OneShot<Int32>()
        private var didTimeOut = false
        private var isStopping = false
        private var isDrained = false
        private var root: ProcessIdentity?

        init(_ process: Process, collectors: [Collector], terminationGrace: TimeInterval) {
            self.process = process
            self.collectors = collectors
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

        /// Asks the run and everything it started to stop, kills whatever is left
        /// after the grace period, and then stops waiting for output that
        /// something out of reach may still hold open. `Process` starts copilot as
        /// the leader of its own process group, and the group still reaches
        /// subprocesses that copilot left behind when it exited.
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
            let collectors = self.collectors
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) { [self] in
                // Once drained, the root pid may belong to another process, so only
                // start-time-verified identities and the guarded group are signalled.
                let stillRunning = !lock.withLock({ isDrained }) && process.isRunning
                var survivors = Set(started)
                if stillRunning { survivors.formUnion(LunaProcess.descendants(of: pid)) }
                survivors.forEach { $0.signal(SIGKILL) }
                signalGroup(pid, SIGKILL)
                if stillRunning { kill(pid, SIGKILL) }
                collectors.forEach { $0.finish() }
            }
        }
    }

    /// A process as it was when seen, shared with Copilot Pull Requests' `gh` runner.
    typealias ProcessIdentity = ProcessTree.Identity

    /// Every process descended from `root`, read before it is signalled because
    /// orphans are re-parented and can no longer be traced back to it.
    static func descendants(of root: pid_t) -> [ProcessIdentity] {
        ProcessTree.descendants(of: root)
    }

    /// Reads a pipe as data arrives and closes the read handle when finished, so a
    /// full pipe never stalls the child and a stuck writer can be given up on.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var isClosed = false
        private let done = OneShot<Data>()
        private let handle: FileHandle

        init(_ pipe: Pipe) {
            handle = pipe.fileHandleForReading
            handle.readabilityHandler = { [weak self] handle in
                guard let self else { return }
                let reachedEOF: Bool = self.lock.withLock {
                    guard !self.isClosed else { return false }
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        return true
                    }
                    self.data.append(chunk)
                    return false
                }
                if reachedEOF {
                    self.finish()
                }
            }
        }

        func finish() {
            let collected: Data? = lock.withLock {
                guard !isClosed else { return nil }
                isClosed = true
                handle.readabilityHandler = nil
                try? handle.close()
                return data
            }
            if let collected {
                done.deliver(collected)
            }
        }

        func text() async -> String {
            String(decoding: await done.wait(), as: UTF8.self)
        }
    }
}
