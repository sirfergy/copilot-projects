import Foundation

/// Filesystem locations used by both the app and the CLI.
///
/// All paths can be overridden via environment variables so that tagged / test
/// instances can run fully isolated from a production copilot-projects.
public enum Paths {
    /// Where new projects/sessions start by default: `~/Repos` when it exists,
    /// otherwise the home directory. Override with `COPILOT_PROJECTS_DEFAULT_DIR`
    /// (a leading `~` is expanded). Gives a deterministic startup folder instead of
    /// sometimes-`/` / sometimes-`~`.
    public static var defaultStartupDir: String {
        let fm = FileManager.default
        if let override = startupDirectoryOverride(environment: ProcessInfo.processInfo.environment) {
            return override
        }
        let home = fm.homeDirectoryForCurrentUser
        let repos = home.appendingPathComponent("Repos", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: repos.path, isDirectory: &isDir), isDir.boolValue {
            return repos.path
        }
        return home.path
    }

    private static func startupDirectoryOverride(environment: [String: String]) -> String? {
        guard let override = environment["COPILOT_PROJECTS_DEFAULT_DIR"], !override.isEmpty else {
            return nil
        }
        return (override as NSString).expandingTildeInPath
    }

    /// Normalize a working-directory value to a plain filesystem path. Shells emit
    /// OSC 7 as a `file://host/path` URL; stored and later reused verbatim it is not
    /// a path `chdir` accepts, so the shell silently falls back to `/`. Converts such
    /// URLs to their decoded path; returns any other value unchanged.
    public static func normalizedDirectory(_ raw: String) -> String {
        guard raw.hasPrefix("file://"), let url = URL(string: raw) else { return raw }
        let path = url.path
        return path.isEmpty ? raw : path
    }

    /// The storage root. Honors `COPILOT_PROJECTS_STATE_DIR`; otherwise uses the
    /// default application state directory.
    public static var stateDir: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_STATE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return defaultStateDir
    }

    public static let defaultStateDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/copilot-projects", isDirectory: true)

    /// The socket a non-isolated instance listens on, ignoring any environment
    /// override. `socketPath` honors the override; this is the baseline it is
    /// compared against when deciding whether an instance is truly isolated.
    public static var defaultSocketPath: String {
        defaultStateDir.appendingPathComponent("control.sock").path
    }

    /// Unix domain socket the app listens on (override with `COPILOT_PROJECTS_SOCKET`).
    public static var socketPath: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_SOCKET"],
           !override.isEmpty {
            return override
        }
        return stateDir.appendingPathComponent("control.sock").path
    }

    /// Held exclusively by the running GUI process. This guards the terminal/session
    /// lifecycle itself; the control socket alone is insufficient because a second
    /// app instance can fail to bind yet continue creating dtach clients.
    public static var instanceLockPath: String {
        stateDir.appendingPathComponent("app.lock").path
    }

    /// Persisted projects/sessions.
    public static var statePath: URL {
        stateDir.appendingPathComponent("state.json")
    }

    /// Directory holding per-session dtach sockets.
    public static var sessionsDir: URL {
        stateDir.appendingPathComponent("sessions", isDirectory: true)
    }

    /// dtach socket for a session (kept short to stay under the ~104-byte sun_path limit).
    public static func dtachSocketPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).sock").path
    }

    /// Atomically replaced status + clock record, written by the Copilot hook and the
    /// app so status survives an app restart (and stays current while the app isn't
    /// running).
    public static func statusRecordPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).status-record.json").path
    }

    /// Present while the app has observed Copilot waiting on background agents.
    public static func backgroundAgentsMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).background-agents").path
    }

    /// Created after the CLI emits its first root session_idle notification. The
    /// footer scraper remains enabled until this proves the running CLI supports the
    /// authoritative idle signal; sessionStart removes it for a fresh CLI process.
    public static func sessionIdleHookMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).session-idle-hook").path
    }

    /// Per-session marker holding the last Copilot CLI session id seen in this tab
    /// (written by the hook from tool/notification payloads, which carry `sessionId`).
    /// Lets the app auto-resume the exact agent session after a reboot recreates the
    /// shell — `copilot --resume=<id>` — instead of guessing per tab.
    public static func copilotSessionMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).copilot-session").path
    }

    public static func scheduledTurnMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).scheduled-turn").path
    }

    public static func agentActivitySnapshotPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).agent-activity.json").path
    }

    /// Response file the host atomically writes to answer a structured `ask_user`
    /// question; the extension watches for it, replies over RPC, then removes it.
    public static func userInputResponsePath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).user-input-response.json").path
    }

    /// Response file the host atomically writes to answer an SDK elicitation.
    public static func elicitationResponsePath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).elicitation-response.json").path
    }

    /// Model switch request the host atomically writes; the extension applies it
    /// over RPC, then removes it.
    public static func setModelRequestPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).set-model-request.json").path
    }

    /// Host-written request asking the owning tracker extension to terminate the
    /// Copilot CLI through its in-app `/exit` path before dtach is destroyed.
    public static func closeSessionRequestPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).close-session-request").path
    }

    /// The sealed transcript: the finished turns, rewritten only when they change.
    public static func transcriptSnapshotPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript.json").path
    }

    /// The turn in progress, rewritten as it streams. It only counts while it
    /// extends the sealed transcript's revision (see `TranscriptFiles`).
    public static func transcriptLivePath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-live.json").path
    }

    public static func transcriptOwnerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-owner.json").path
    }

    public static func transcriptOwnerLockPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-owner.json.flock").path
    }

    public static func transcriptQuarantinePath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-quarantine.json").path
    }

    /// Absolute path to the `copilot` CLI, resolved without relying on an
    /// interactive login shell's rc files. Honors an explicit
    /// `COPILOT_PROJECTS_COPILOT` override, then
    /// `$HOME/.local/bin/copilot` (the documented install location), then the
    /// first executable named `copilot` on the app process `PATH`. Returns `nil`
    /// when none exists so remote session creation fails closed instead of
    /// launching a session that can never start Copilot.
    public static var copilotExecutable: String? {
        resolveCopilotExecutable()
    }

    static func resolveCopilotExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = environment["COPILOT_PROJECTS_COPILOT"],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }
        let local = home.appendingPathComponent(".local/bin/copilot").path
        if fileManager.isExecutableFile(atPath: local) {
            return local
        }
        // Scan the process PATH — the environment the app was launched with, not a
        // freshly sourced shell — for an absolute directory containing `copilot`.
        let pathValue = environment["PATH"] ?? ""
        for entry in pathValue.split(separator: ":", omittingEmptySubsequences: true) {
            let directory = String(entry)
            guard directory.hasPrefix("/") else { continue }
            let candidate = (directory as NSString).appendingPathComponent("copilot")
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Remote startup directory: `COPILOT_PROJECTS_DEFAULT_DIR`, or `$HOME/Repos`.
    /// Must expand to an existing absolute directory; invalid overrides never fall back.
    public static var reposDirectory: String? {
        resolveReposDirectory()
    }

    static func resolveReposDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let directory = startupDirectoryOverride(environment: environment)
            ?? home.appendingPathComponent("Repos", isDirectory: true).path
        guard directory.hasPrefix("/") else { return nil }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return directory
        }
        return nil
    }

    /// Persisted idempotency ledger for remote session creation (requestId →
    /// created session), kept beside the rest of the private app state.
    public static var sessionCreationLedgerPath: URL {
        stateDir.appendingPathComponent("session-creation-ledger.json")
    }

    public static var projectCreationLedgerPath: URL {
        stateDir.appendingPathComponent("project-creation-ledger.json")
    }

    /// Root for the durable Kitty inline-image store (`RemoteKittyImageDiskStore`):
    /// exact retained PNG bytes + persisted current-selection/placement metadata,
    /// so a session's images survive an app relaunch (or a reboot that kills the
    /// dtach master) instead of only ever living in `RemoteKittyImageCapture`'s
    /// in-memory grace cache.
    public static var kittyImagesDir: URL {
        stateDir.appendingPathComponent("kitty-images", isDirectory: true)
    }

    /// The bundled dtach helper (resumability backend), or an override, or nil.
    public static var dtachExecutable: String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_DTACH"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        guard let bundle = RunningExecutable.applicationBundle else { return nil }
        let bundled = bundle.bundleURL.appendingPathComponent("Contents/Helpers/dtach")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled.path
        }
        return nil
    }

    /// The Mach-O `copilot` wrapper that bridges a local `dtach` session to a
    /// remote SSH host while preserving `pbsi_comm == "copilot"` for process-tree
    /// liveness checks.
    public static var remoteCopilotWrapperExecutable: String? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["COPILOT_PROJECTS_REMOTE_WRAPPER"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let defaultWrapper = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/ccr-pr-review/bin/copilot")
            .path
        if FileManager.default.isExecutableFile(atPath: defaultWrapper) {
            return defaultWrapper
        }
        return nil
    }

    /// Best-effort creation of the (user-private) state directory.
    @discardableResult
    public static func ensureStateDir() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: stateDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? fm.createDirectory(
                at: sessionsDir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return true
        } catch {
            return false
        }
    }
}
