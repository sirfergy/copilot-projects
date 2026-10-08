import Foundation

/// The workspace as `list-sessions` reports it to the Copilot Pull Requests app:
/// every project and live session, with the attention state the workspace shows.
public struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public struct Session: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        /// The status the workspace shows: waiting while a question is pending.
        public var status: SessionStatus
        public var finishedUnseen: Bool
        public var hasPendingInput: Bool
        /// The Copilot CLI session last seen in this tab, from its resume marker.
        public var copilotSessionId: String?

        public init(
            id: String, title: String, status: SessionStatus, finishedUnseen: Bool = false,
            hasPendingInput: Bool = false, copilotSessionId: String? = nil
        ) {
            self.id = id
            self.title = title
            self.status = status
            self.finishedUnseen = finishedUnseen
            self.hasPendingInput = hasPendingInput
            self.copilotSessionId = copilotSessionId
        }
    }

    public struct Project: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var sessions: [Session]

        public init(id: String, name: String, sessions: [Session]) {
            self.id = id
            self.name = name
            self.sessions = sessions
        }
    }

    public var version: Int
    /// The host to activate before asking it to reveal a session.
    public var hostProcessIdentifier: Int32
    public var selectedProjectId: String?
    public var projects: [Project]

    public init(
        version: Int = WorkspaceSnapshot.currentVersion, hostProcessIdentifier: Int32,
        selectedProjectId: String?, projects: [Project]
    ) {
        self.version = version
        self.hostProcessIdentifier = hostProcessIdentifier
        self.selectedProjectId = selectedProjectId
        self.projects = projects
    }
}

/// Where the Copilot Pull Requests app lives and what crosses into it.
public enum PullRequestsAppBundle {
    public static let name = "Copilot Pull Requests"
    public static let executableName = "copilot-pull-requests"
    /// Appended to the host's bundle identifier.
    public static let bundleIdentifierSuffix = ".pull-requests"
    /// The helper's Info.plist key naming the host's bundle identifier, whose
    /// defaults domain keeps the Owners setting.
    public static let hostBundleIdentifierKey = "CopilotProjectsHostBundleIdentifier"

    /// The only variables either app passes when it opens the other. Tokens and
    /// everything else stay behind.
    public static let forwardedEnvironmentKeys = [
        "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_GH", "COPILOT_HOME",
    ]

    public static func forwardedEnvironment(_ environment: [String: String]) -> [String: String] {
        var forwarded: [String: String] = [:]
        for key in forwardedEnvironmentKeys {
            if let value = environment[key], !value.isEmpty { forwarded[key] = value }
        }
        return forwarded
    }

    /// A separate state directory or socket means an isolated instance, which
    /// gets its own copy of the other app rather than the user's running one.
    public static func isIsolated(_ environment: [String: String]) -> Bool {
        ["COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET"].contains {
            !(environment[$0] ?? "").isEmpty
        }
    }

    /// `Copilot Projects.app/Contents/Helpers/Copilot Pull Requests.app`.
    public static func helperURL(inHostBundle hostURL: URL) -> URL {
        hostURL.appendingPathComponent("Contents/Helpers/\(name).app", isDirectory: true)
    }

    public static func helperBundleIdentifier(hostBundleIdentifier: String) -> String {
        hostBundleIdentifier + bundleIdentifierSuffix
    }
}

extension Paths {
    /// Goal names, transcript match counts, and the Pull Requests app's lock.
    public static var pullRequestsStateDir: URL {
        stateDir.appendingPathComponent("pull-requests", isDirectory: true)
    }

    /// Held by the one Copilot Pull Requests instance that writes its state.
    public static var pullRequestsAppLockPath: String {
        pullRequestsStateDir.appendingPathComponent("app.lock").path
    }

    /// The lock holder's process id, so the host can bring it forward.
    public static var pullRequestsAppPIDPath: String {
        pullRequestsStateDir.appendingPathComponent("app.pid").path
    }
}
