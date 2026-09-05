import Foundation

/// Reads the per-session targeting variables the app injects into each shell.
public enum Env {
    public static func projectId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_PROJECT"])
    }

    public static func sessionId(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_SESSION"])
    }

    public static func socket(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        nonEmpty(env["COPILOT_PROJECTS_SOCKET"])
    }

    public static func agentProcessNames(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> Set<String> {
        if let raw = env["COPILOT_PROJECTS_AGENT_PROCESSES"], !raw.isEmpty {
            let names = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty { return Set(names) }
        }
        return ["copilot"]
    }

    /// True when this process should install/refresh the global Copilot CLI
    /// integration (hooks + tracker extension) in `~/.copilot`.
    ///
    /// Only a *deliberately isolated* instance must skip it. The state dir and
    /// socket variables are injected into every session shell, so launching the
    /// app from a terminal running inside a session (`open -a "Copilot Projects"`)
    /// makes it inherit them — pointing at this very instance's own default
    /// location. Treating that as isolation silently skipped the install for the
    /// normal global instance, leaving a stale extension behind after an upgrade.
    /// Only a value that resolves somewhere *other* than the default counts.
    public static func shouldInstallGlobalIntegration(
        _ env: [String: String] = ProcessInfo.processInfo.environment,
        defaultStateDir: String = Paths.defaultStateDir.path,
        defaultSocketPath: String = Paths.defaultSocketPath
    ) -> Bool {
        guard nonEmpty(env["COPILOT_PROJECTS_NO_INSTALL"]) != "1"
        else { return false }

        if let stateDir = nonEmpty(env["COPILOT_PROJECTS_STATE_DIR"]),
           !isSamePath(stateDir, defaultStateDir) {
            return false
        }
        if let socket = socket(env), !isSamePath(socket, defaultSocketPath) {
            return false
        }
        return true
    }

    /// Compares two filesystem paths for equality after expanding `~`, resolving
    /// `.`/`..`, and following symlinks, so a trailing slash or an equivalent
    /// spelling of the default location isn't mistaken for a redirect.
    private static func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        func normalize(_ path: String) -> String {
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .standardizedFileURL
                .resolvingSymlinksInPath()
                .path
        }
        return normalize(lhs) == normalize(rhs)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
