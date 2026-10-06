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
            "--available-tools=",
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
        try Self.loginSeed(fromConfig: try? Data(contentsOf: userConfigURL))
            .write(to: home.appendingPathComponent("config.json"), options: .atomic)
        return home
    }

    static func failure(from result: LunaProcess.Result) -> LunaSearchError {
        let text = result.errorOutput + "\n" + result.output
        if text.contains("/login") || text.localizedCaseInsensitiveContains("not authenticated")
            || text.localizedCaseInsensitiveContains("authenticate") {
            return .notSignedIn
        }
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        return .failed(LunaSessionPrompt.clip(line ?? "exit status \(result.status)", 120))
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
        process.terminationHandler = { run.finish($0.terminationStatus) }
        try process.run()
        let outputReader = PipeReader(output)
        let errorReader = PipeReader(errorOutput)

        let watchdog = Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            run.terminate(timedOut: true)
        }
        defer { watchdog.cancel() }
        let status = await withTaskCancellationHandler {
            await run.exitStatus()
        } onCancel: {
            run.terminate(timedOut: false)
        }
        let stdout = await outputReader.text()
        let stderr = await errorReader.text()
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

        init(_ process: Process, terminationGrace: TimeInterval) {
            self.process = process
            self.terminationGrace = terminationGrace
        }

        var timedOut: Bool { lock.withLock { didTimeOut } }

        func finish(_ status: Int32) { exit.deliver(status) }

        func exitStatus() async -> Int32 { await exit.wait() }

        /// Asks the run and everything it started to stop, then kills whatever is
        /// left after the grace period: a run that ignores SIGTERM would otherwise
        /// never exit, and a subprocess holding the output pipes open would keep
        /// the reads from finishing.
        func terminate(timedOut: Bool) {
            let first: Bool = lock.withLock {
                if timedOut { didTimeOut = true }
                defer { isStopping = true }
                return !isStopping
            }
            guard first, process.isRunning else { return }
            let pid = process.processIdentifier
            let started = LunaProcess.descendants(of: pid)
            process.terminate()
            started.forEach { kill($0, SIGTERM) }
            let process = self.process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + terminationGrace) {
                let rootRunning = process.isRunning
                var survivors = Set(started)
                if rootRunning { survivors.formUnion(LunaProcess.descendants(of: pid)) }
                for child in survivors where kill(child, 0) == 0 { kill(child, SIGKILL) }
                if rootRunning { kill(pid, SIGKILL) }
            }
        }
    }

    /// Every process descended from `root`, read before it is signalled because
    /// orphans are re-parented and can no longer be traced back to it.
    static func descendants(of root: pid_t) -> [pid_t] {
        let tree = ProcessTree.snapshot()
        var found: [pid_t] = []
        var pending = tree.childrenOf[root] ?? []
        while let pid = pending.popLast() {
            guard !found.contains(pid) else { continue }
            found.append(pid)
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
