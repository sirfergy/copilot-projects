import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol

public enum SessionInputValidation {
    public static func isValidPrompt(_ value: String) -> Bool {
        ProjectsTerminalView.remotePromptPasteBytes(value) != nil
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
    func closeSession(sessionId: String) -> RemoteSessionCloseResult
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
    var supportsPullRequests: Bool { get }
    func pullRequestsOverview(refresh: Bool) async -> RemotePullRequestsOverviewOutcome
    func performPullRequestSession(_ request: RemotePullRequestSessionRequest) async -> RemotePullRequestSessionOutcome
}

public extension SessionHost {
    var supportsPullRequests: Bool { false }

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

    /// Older conformers must fail closed, not silently use legacy launch semantics.
    func createConfiguredSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        .unavailable
    }
}
