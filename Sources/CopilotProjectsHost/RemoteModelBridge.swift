import Foundation
import CopilotProjectsProtocol

public struct RemoteTerminalRevision: Equatable, Sendable {
    public let contentGeneration: UInt64
    /// The advertising session's own `RemoteKittyImageCapture.imageAvailabilityGeneration`
    /// at the moment this revision was computed. Bumped not only by that
    /// session's own capture activity but also whenever the process-wide
    /// `RemoteKittyImageCaptureBudget` reclaims one of *this* session's
    /// currently-advertised images to satisfy a different session's request —
    /// so a cached screen here is correctly invalidated by cross-session
    /// global eviction, even though nothing about this session's own terminal
    /// content changed. Without this, a stale cached screen could keep
    /// advertising a placement whose backing image the global budget already
    /// evicted, and a client fetching it would 404.
    public let imageAvailabilityGeneration: UInt64
    public let cols: Int
    public let rows: Int
    public let terminalScroll: Bool
}

@MainActor
final class RemoteModelBridge: SessionHost {
    private struct CachedScreen {
        let revision: RemoteTerminalRevision
        let afterLine: Int?
        let screen: RemoteTerminalScreen?
    }

    private weak var model: AppModel?
    private var cachedScreens: [String: CachedScreen] = [:]
    var cachedScreenCount: Int { cachedScreens.count }

    init(model: AppModel) {
        self.model = model
    }

    func workspace() -> RemoteWorkspaceSnapshot? {
        model?.remoteWorkspaceSnapshot()
    }

    func hasSession(_ sessionId: String) -> Bool {
        model?.projects.contains {
            $0.sessions.contains { $0.id == sessionId }
        } == true
    }

    /// Create (or idempotently resolve) a remote session. `.unavailable` when the
    /// model is gone so the gateway answers 503 rather than crashing.
    func createSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        model?.createRemoteSession(request) ?? .unavailable
    }

    func createConfiguredSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        model?.createRemoteConfiguredSession(request) ?? .unavailable
    }

    func createAdversarialReviewSession(
        _ request: RemoteCreateSessionRequest
    ) -> RemoteSessionCreationOutcome {
        model?.createRemoteAdversarialReviewSession(request) ?? .unavailable
    }

    func screenRevision(sessionId: String) -> RemoteTerminalRevision? {
        guard let model,
              let view = model.controller(for: sessionId)?.terminalView,
              !view.isRestoringImages,
              let input = view.terminalInputStateSnapshot() else { return nil }
        return RemoteTerminalRevision(
            contentGeneration: view.remoteContentGeneration,
            imageAvailabilityGeneration: view.kittyImageCapture.imageAvailabilityGeneration,
            cols: input.dimensions.cols,
            rows: input.dimensions.rows,
            terminalScroll: input.isAlternateBuffer
                || model.liveAgentSessions.contains(sessionId)
        )
    }

    func screen(
        sessionId: String,
        revision: RemoteTerminalRevision,
        afterLine: Int?
    ) -> RemoteTerminalScreen? {
        guard let model else {
            cachedScreens.removeAll()
            return nil
        }
        let liveSessions = Set(model.projects.flatMap(\.sessions).map(\.id))
        cachedScreens = cachedScreens.filter { liveSessions.contains($0.key) }
        guard screenRevision(sessionId: sessionId) == revision else { return nil }
        if let cached = cachedScreens[sessionId],
           cached.revision == revision,
           cached.afterLine == afterLine {
            return cached.screen
        }
        guard let screen = model.remoteScreen(sessionId: sessionId, afterLine: afterLine),
              screen.cols == revision.cols, screen.rows == revision.rows,
              (screen.scrollMode == .terminal) == revision.terminalScroll,
              screenRevision(sessionId: sessionId) == revision else { return nil }
        cachedScreens[sessionId] = CachedScreen(
            revision: revision,
            afterLine: afterLine,
            screen: screen
        )
        return screen
    }

    func performControl(
        _ message: RemoteClientMessage,
        perform: () -> RemoteControlResult
    ) -> RemoteControlResult {
        model?.performRemoteControl(message, perform: perform) ?? .missing
    }

    func sendInput(sessionId: String, value: String) -> RemoteTerminalInputResult {
        model?.sendRemoteInput(sessionId: sessionId, value: value) ?? .missing
    }

    func sendKey(sessionId: String, key: String) -> RemoteTerminalInputResult {
        model?.sendRemoteKey(sessionId: sessionId, key: key) ?? .missing
    }

    func sendCommand(
        sessionId: String,
        requestId: String,
        value: String
    ) -> RemoteCommandResult {
        model?.sendRemoteCommand(
            sessionId: sessionId,
            requestId: requestId,
            value: value
        ) ?? .missing
    }

    func sendScroll(sessionId: String, delta: Int) {
        model?.sendRemoteScroll(sessionId: sessionId, delta: delta)
    }

    func markRead(sessionId: String) {
        model?.markSessionRead(sessionId: sessionId)
    }

    func closeSession(sessionId: String) -> RemoteSessionCloseResult {
        model?.closeRemoteSession(sessionId: sessionId) ?? .failed
    }

    func moveSession(
        sessionId: String,
        toProjectId targetProjectId: String
    ) -> RemoteSessionMoveResult {
        model?.moveRemoteSession(
            sessionId: sessionId,
            toProjectId: targetProjectId
        ) ?? .missing
    }

    /// The transcript revision, folded together with the session's current
    /// image-availability generation so that capturing, displaying, evicting, or
    /// restoring an inline image (none of which touch the transcript file) still
    /// changes the revision and prompts clients to re-fetch `/transcript` — where
    /// the per-turn image associations are computed. Without this, conversation
    /// images would only refresh when the CLI happened to rewrite the transcript.
    func transcriptRevision(sessionId: String) -> RemoteTranscriptRevision {
        let base = TranscriptController.remoteRevision(sessionId: sessionId)
        guard let view = model?.controller(for: sessionId)?.terminalView else {
            return base
        }
        return RemoteTranscriptRevision(
            sessionId: base.sessionId,
            generation: "\(base.generation)#img\(view.kittyImageCapture.imageAvailabilityGeneration)"
        )
    }

    /// The currently-advertised inline images for `sessionId` paired with their
    /// display time, or `nil` if the session/view is gone. Read on the main
    /// actor (capture state is main-actor isolated); the caller joins this
    /// bounded metadata against the transcript turns off-actor.
    func retainedImageMetadata(sessionId: String) -> [RemoteKittyImageCapture.RetainedImageInfo]? {
        model?.controller(for: sessionId)?.terminalView.kittyImageCapture.retainedImageMetadata()
    }

    func transcript(sessionId: String, limit: Int?) async -> Data? {
        let images = retainedImageMetadata(sessionId: sessionId) ?? []
        return await Task.detached {
            TranscriptResponse.encodedResponse(
                snapshot: TranscriptController.loadRemoteSnapshot(sessionId: sessionId),
                images: images,
                limit: limit
            )
        }.value
    }

    func sendPrompt(sessionId: String, value: String) -> RemotePromptResult {
        model?.sendRemotePrompt(sessionId: sessionId, value: value) ?? .invalid
    }

    func answerUserInput(
        sessionId: String,
        answer: RemoteUserInputAnswer,
        operation: CLIOperationRequest?
    ) -> RemoteUserInputResult {
        model?.answerUserInput(
            sessionId: sessionId,
            answer: answer,
            operation: operation
        ) ?? .invalid
    }

    func answerElicitation(
        sessionId: String,
        answer: RemoteElicitationAnswer,
        operation: CLIOperationRequest?
    ) -> RemoteUserInputResult {
        model?.answerElicitation(
            sessionId: sessionId,
            answer: answer,
            operation: operation
        ) ?? .invalid
    }

    func setModel(
        sessionId: String,
        selection: RemoteModelSelection,
        operation: CLIOperationRequest?
    ) -> RemoteUserInputResult {
        model?.setModel(
            sessionId: sessionId,
            selection: selection,
            operation: operation
        ) ?? .invalid
    }

    func performSessionAction(
        sessionId: String,
        action: RemoteSessionAction,
        operation: CLIOperationRequest
    ) -> RemoteUserInputResult {
        model?.performSessionAction(
            sessionId: sessionId, action: action, operation: operation
        ) ?? .invalid
    }

    /// The exact retained PNG bytes for `(imageId, version)` in `sessionId`'s
    /// terminal, or `nil` if the session, id, or exact version isn't (or is no
    /// longer) available.
    func terminalImageData(
        sessionId: String,
        imageId: UInt32,
        version: UInt64
    ) -> Data? {
        model?.controller(for: sessionId)?.terminalView.kittyImageCapture.imageData(
            imageId: imageId,
            version: version
        )
    }

    /// True while `sessionId`'s durable Kitty-image restore is still
    /// pending — used to answer an exact-image request with a retryable
    /// status instead of a definitive 404 (see `RemoteGateway
    /// .handleTerminalImage`), since a request for a version a client
    /// already knows about from before an app relaunch could otherwise
    /// briefly (and wrongly) look permanently gone until the restore
    /// finishes replaying it.
    func isRestoringImages(sessionId: String) -> Bool {
        model?.controller(for: sessionId)?.terminalView.isRestoringImages ?? false
    }
}
