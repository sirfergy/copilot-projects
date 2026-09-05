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
        if let override = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_DEFAULT_DIR"],
           !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let home = fm.homeDirectoryForCurrentUser
        let repos = home.appendingPathComponent("Repos", isDirectory: true)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: repos.path, isDirectory: &isDir), isDir.boolValue {
            return repos.path
        }
        return home.path
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

    /// Per-session status marker, written by the Copilot hook so status survives
    /// an app restart (and stays current even while the app isn't running).
    public static func statusMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).status").path
    }

    /// Timestamp of the most recent hook-driven status transition. Used to reject
    /// late async notification hooks that arrive after a newer lifecycle event.
    public static func statusTimestampMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).status-timestamp").path
    }

    public static func promptStatusTimestampMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).prompt-status-timestamp").path
    }

    /// Atomically replaced status + clock record. New app versions restore from this
    /// record so independently written compatibility markers can never be combined.
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

    /// Per-tab marker containing the Copilot session id whose full allow-all
    /// permission mode should be restored with that session.
    public static func copilotAllowAllMarkerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).copilot-allow-all").path
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

    /// Host-written request asking the owning tracker extension to terminate the
    /// Copilot CLI through its in-app `/exit` path before dtach is destroyed.
    public static func closeSessionRequestPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).close-session-request").path
    }

    public static func transcriptSnapshotPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript.json").path
    }

    public static func transcriptOwnerPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-owner.json").path
    }

    public static func transcriptOwnerLockPath(sessionId: String) -> String {
        sessionsDir.appendingPathComponent("\(sessionId).transcript-owner.json.lock").path
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

    /// Absolute `$HOME/Repos`, but only when it already exists and is a directory.
    /// Remote session creation requires this exact folder (never the literal
    /// `~/Repos`, and never a home-directory fallback), so a missing Repos fails
    /// closed instead of dropping a session at an unexpected working directory.
    public static var reposDirectory: String? {
        resolveReposDirectory()
    }

    static func resolveReposDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> String? {
        let repos = home.appendingPathComponent("Repos", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: repos.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return repos.path
        }
        return nil
    }

    /// Persisted idempotency ledger for remote session creation (requestId →
    /// created session), kept beside the rest of the private app state.
    public static var sessionCreationLedgerPath: URL {
        stateDir.appendingPathComponent("session-creation-ledger.json")
    }

    /// Root for the durable Kitty inline-image store (`RemoteKittyImageDiskStore`):
    /// exact retained PNG bytes + persisted current-selection/placement metadata,
    /// so a session's images survive an app relaunch (or a reboot that kills the
    /// dtach master) instead of only ever living in `RemoteKittyImageCapture`'s
    /// in-memory grace cache.
    public static var kittyImagesDir: URL {
        stateDir.appendingPathComponent("kitty-images", isDirectory: true)
    }

    /// Directory holding one file per retained `(session, imageId, version)`
    /// entry's exact PNG bytes.
    public static var kittyImagesDataDir: URL {
        kittyImagesDir.appendingPathComponent("data", isDirectory: true)
    }

    /// Directory holding one empty marker file per deliberately-destroyed
    /// session, written synchronously *before* that session's terminal/dtach
    /// teardown proceeds, so the marker survives even an immediate app exit —
    /// startup cleanup consults it to guarantee a destroyed session's images
    /// can never be resurrected, regardless of whether the async removal of
    /// its manifest entries/data files had a chance to finish first.
    public static var kittyImagesTombstonesDir: URL {
        kittyImagesDir.appendingPathComponent("tombstones", isDirectory: true)
    }

    /// The single schema-versioned manifest recording every retained disk
    /// entry and persisted current-selection/placement record, across every
    /// session, process-wide.
    public static var kittyImagesManifestPath: URL {
        kittyImagesDir.appendingPathComponent("manifest.json")
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
