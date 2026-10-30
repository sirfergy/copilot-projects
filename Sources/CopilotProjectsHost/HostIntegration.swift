import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

public enum SessionInputValidation {
    /// Remote prompt pastes and review-prompt templates share this UTF-8 budget.
    public static let maximumPromptBytes = 8_192

    public static func isValidPrompt(_ value: String) -> Bool {
        let normalized = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              normalized.utf8.count <= maximumPromptBytes else {
            return false
        }
        for scalar in normalized.unicodeScalars {
            if scalar.value == 0x7f
                || (scalar.value < 0x20 && scalar != "\n" && scalar != "\t")
                || (0x80 ... 0x9f).contains(scalar.value) {
                return false
            }
        }
        return true
    }

    public static func isValidCommand(_ value: String) -> Bool {
        ProjectsTerminalView.remoteCommandTextBytes(value) != nil
    }
}

/// Optional in-process services. The standalone application installs none.
@MainActor
public protocol HostIntegration: AnyObject {
    var clearLocalNotification: ((UUID) -> Void)? { get set }
    func start()
    func stop()
    func command(_ action: String) -> ControlResponse
    func postNotification(_ event: NotificationEvent)
    func dismissNotification(_ id: UUID)
    func shutdown()
    func shutdownAndWait() async
}

/// Snapshot and mutation boundary; implementations retain ownership of live
/// terminals, session identity, and replay-safe operation acceptance.
@MainActor
public protocol SessionHost: AnyObject, Sendable {
    func workspace() -> RemoteWorkspaceSnapshot?
    func createProject(_ request: RemoteCreateProjectRequest) -> RemoteProjectCreationOutcome
    func hasSession(_ sessionId: String) -> Bool
    func createSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome
    func createConfiguredSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome
    func createAdversarialReviewSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome
    func screenRevision(sessionId: String) -> RemoteTerminalRevision?
    func screen(sessionId: String, revision: RemoteTerminalRevision, afterLine: Int?) -> RemoteTerminalScreen?
    func transcriptRevision(sessionId: String) -> RemoteTranscriptRevision
    /// The encoded `/transcript` response, or `nil` when it can't be served
    /// right now. A gateway must answer `nil` with an error status, never an
    /// empty success: clients replace their transcript with an empty one.
    func transcript(sessionId: String, limit: Int?) async -> Data?
    /// The transcript response for a client that sent a `TranscriptCursor`.
    func transcript(sessionId: String, limit: Int?, after cursor: TranscriptCursor?) async -> Data?
    func terminalImageData(sessionId: String, imageId: UInt32, version: UInt64) -> Data?
    func isRestoringImages(sessionId: String) -> Bool
    func performControl(_ message: RemoteClientMessage, perform: () -> RemoteControlResult) -> RemoteControlResult
    func sendInput(sessionId: String, value: String) -> RemoteTerminalInputResult
    func sendKey(sessionId: String, key: String) -> RemoteTerminalInputResult
    func sendCommand(sessionId: String, requestId: String, value: String) -> RemoteCommandResult
    func sendScroll(sessionId: String, delta: Int)
    func markRead(sessionId: String)
    /// Whether `markUnread` is implemented. A gateway routes
    /// `RemoteMarkUnreadContract.controlType` and advertises its capability only when true.
    var supportsMarkUnread: Bool { get }
    func markUnread(sessionId: String)
    func closeSession(sessionId: String) -> RemoteSessionCloseResult
    var supportsReopenClosedSession: Bool { get }
    func reopenClosedSession(id: String?) -> RemoteReopenSessionResult
    func moveSession(sessionId: String, toProjectId: String) -> RemoteSessionMoveResult
    func sendPrompt(sessionId: String, value: String) -> RemotePromptResult
    func answerUserInput(sessionId: String, answer: RemoteUserInputAnswer, operation: CLIOperationRequest?) -> RemoteUserInputResult
    func answerElicitation(sessionId: String, answer: RemoteElicitationAnswer, operation: CLIOperationRequest?) -> RemoteUserInputResult
    func setModel(sessionId: String, selection: RemoteModelSelection, operation: CLIOperationRequest?) -> RemoteUserInputResult
    func performSessionAction(sessionId: String, action: RemoteSessionAction, operation: CLIOperationRequest) -> RemoteUserInputResult
    var supportsSessionSearch: Bool { get }
    /// The `RemoteSessionSearchContract` capabilities `searchSessions` implements,
    /// such as `recentCapability`. A gateway advertises only those it also serves.
    var sessionSearchCapabilities: [String] { get }
    /// Cancelling the calling task stops the search, including a running Luna process.
    func searchSessions(_ request: RemoteSessionSearchRequest) async -> RemoteSessionSearchOutcome
    func resumeSearchSession(_ request: RemoteResumeSearchSessionRequest) -> RemoteResumeSearchSessionOutcome
    var supportsPullRequests: Bool { get }
    func pullRequestsOverview(refresh: Bool) async -> RemotePullRequestsOverviewOutcome
    func performPullRequestSession(_ request: RemotePullRequestSessionRequest) async -> RemotePullRequestSessionOutcome
}

public extension SessionHost {
    var supportsPullRequests: Bool { false }

    var supportsMarkUnread: Bool { false }

    func markUnread(sessionId: String) {}

    var supportsReopenClosedSession: Bool { false }

    func reopenClosedSession(id: String?) -> RemoteReopenSessionResult { .unsupported }

    /// Hosts without incremental support send their usual response. Clients
    /// merge by turn id, so ignoring the cursor costs only bandwidth.
    func transcript(sessionId: String, limit: Int?, after cursor: TranscriptCursor?) async -> Data? {
        await transcript(sessionId: sessionId, limit: limit)
    }

    func pullRequestsOverview(refresh: Bool) async -> RemotePullRequestsOverviewOutcome { .unsupported }

    func performPullRequestSession(_ request: RemotePullRequestSessionRequest) async -> RemotePullRequestSessionOutcome {
        .unsupported
    }

    func createProject(_ request: RemoteCreateProjectRequest) -> RemoteProjectCreationOutcome {
        .unsupported
    }

    var supportsSessionSearch: Bool { false }

    var sessionSearchCapabilities: [String] { [] }

    func searchSessions(_ request: RemoteSessionSearchRequest) async -> RemoteSessionSearchOutcome {
        .unsupported
    }

    func resumeSearchSession(_ request: RemoteResumeSearchSessionRequest) -> RemoteResumeSearchSessionOutcome {
        .unsupported
    }

    /// Older conformers must fail closed, not silently use legacy launch semantics.
    func createConfiguredSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        .unavailable
    }
}
