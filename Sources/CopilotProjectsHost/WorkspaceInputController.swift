import AppKit
import Combine
import CopilotProjectsCore

@MainActor
final class WorkspaceInputController: ObservableObject {
    @Published var imagePreview: TranscriptImagePreviewItem?
    @Published var showsReleaseNotes = false
    @Published private(set) var sessionFinder: SessionFinderModel?
    private let model: AppModel
    private let sessionRanker: SessionRanking
    private let sessionHistorySearcher: SessionHistorySearching?
    private let copilotSessionStore: @Sendable () -> CopilotSessionStore

    init(
        model: AppModel,
        sessionRanker: SessionRanking = LunaSessionRanker(),
        sessionHistorySearcher: SessionHistorySearching? = nil,
        copilotSessionStore: @escaping @Sendable () -> CopilotSessionStore = { CopilotSessionStore() }
    ) {
        self.model = model
        self.sessionRanker = sessionRanker
        self.sessionHistorySearcher = sessionHistorySearcher ?? (sessionRanker as? SessionHistorySearching)
        self.copilotSessionStore = copilotSessionStore
    }

    /// A workspace sheet owns the keyboard, so workspace commands stay disabled.
    var hasWorkspaceSheet: Bool { imagePreview != nil || sessionFinder != nil || showsReleaseNotes }

    func presentReleaseNotes() {
        guard !hasWorkspaceSheet, NSApp.modalWindow == nil else { return }
        model.setNumberHint(.none)
        showsReleaseNotes = true
    }

    func presentImage(_ item: TranscriptImagePreviewItem) {
        guard sessionFinder == nil, !showsReleaseNotes else { return }
        guard model.globalSelectedSessionId == item.id.sessionId,
              model.isTranscriptDrawerOpen(sessionId: item.id.sessionId) else {
            NSLog("Ignoring an image preview from an inactive session drawer.")
            return
        }
        imagePreview = item
    }

    func presentSessionFinder() {
        guard !hasWorkspaceSheet, NSApp.modalWindow == nil else { return }
        model.setNumberHint(.none)
        let projects = model.sessionFinderProjectTargets
        let selectedProjectId = model.selectedProjectId
        let inMemoryCopilotIds = model.inMemoryActiveCopilotSessionIds()
        let initialSessionIds = model.projects.flatMap { $0.sessions.map(\.id) }
        let markerDirectory = model.resumeMarkerDirectory
        let storeProvider = copilotSessionStore
        let defaultStartupDir = Paths.defaultStartupDir
        sessionFinder = SessionFinderModel(
            sources: model.sessionFinderSources,
            currentSessionId: model.globalSelectedSessionId,
            activeCopilotSessionIds: inMemoryCopilotIds,
            ranker: sessionRanker,
            historySearcher: sessionHistorySearcher,
            loadResumableEntries: {
                let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                    sessionIds: initialSessionIds, directory: markerDirectory
                )
                return SessionFinderResumableLoader.load(
                    store: storeProvider(),
                    projects: projects,
                    selectedProjectId: selectedProjectId,
                    liveCopilotSessionIds: inMemoryCopilotIds.union(markerIds),
                    defaultStartupDir: defaultStartupDir
                )
            },
            loadResumableEntriesByIds: { candidateIds in
                let markerIds = AppModel.validatedMarkerCopilotSessionIds(
                    sessionIds: initialSessionIds, directory: markerDirectory
                )
                return SessionFinderResumableLoader.loadEntries(
                    forCopilotSessionIds: candidateIds,
                    store: storeProvider(),
                    projects: projects,
                    selectedProjectId: selectedProjectId,
                    liveCopilotSessionIds: inMemoryCopilotIds.union(markerIds),
                    defaultStartupDir: defaultStartupDir
                )
            }
        ) { [weak self] sessionId in
            self?.openFromSessionFinder(sessionId)
        }
    }

    func dismissSessionFinder() {
        sessionFinder?.cancel()
        sessionFinder = nil
    }

    func openFromSessionFinder(_ sessionId: String) {
        // Select a live session directly when it is open in the workspace.
        if let project = model.projects.first(where: { project in
            project.sessions.contains { $0.id == sessionId }
        }) {
            dismissSessionFinder()
            // Select the session first: switching projects marks the project's
            // selected tab as seen, and that should be the tab being opened.
            model.selectSession(projectId: project.id, sessionId: sessionId)
            if model.selectedProjectId != project.id { model.selectProject(project.id) }
            DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
            return
        }
        // Resume an ended Copilot CLI session into its matched project.
        guard let source = sessionFinder?.source(for: sessionId),
              let copilotSessionId = source.resumableCopilotSessionId else {
            return
        }
        switch model.resumeFromSessionFinder(
            copilotSessionId: copilotSessionId,
            preferredProjectId: source.projectId,
            cwd: source.cwd,
            repository: source.repository,
            title: source.title,
            store: copilotSessionStore()
        ) {
        case .opened(let projectId, let resumedSessionId):
            dismissSessionFinder()
            model.selectSession(projectId: projectId, sessionId: resumedSessionId)
            if model.selectedProjectId != projectId { model.selectProject(projectId) }
            DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
        case .permanentlyUnavailable(let message):
            sessionFinder?.removeResumableSession(id: sessionId, error: message)
        case .temporarilyUnavailable(let message):
            sessionFinder?.setResumeError(message)
        }
    }

    func allowsWorkspaceEvents(_ event: NSEvent) -> Bool {
        imagePreview == nil && !showsReleaseNotes && NSApp.modalWindow == nil
            && event.window?.sheetParent == nil && event.window?.attachedSheet == nil
            && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
    }

    func handleOtherMouse(_ event: NSEvent) -> NSEvent? {
        guard !hasWorkspaceSheet, allowsWorkspaceEvents(event) else { return event }
        switch event.buttonNumber {
        case 3:
            if event.type == .otherMouseDown {
                model.navigateSessionBack()
            }
            return nil
        case 4:
            if event.type == .otherMouseDown {
                model.navigateSessionForward()
            }
            return nil
        default:
            return event
        }
    }

    func handleKeyDown(_ event: NSEvent, cancelNumberHint: () -> Void = {}) -> NSEvent? {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        func clearNumberHint() {
            cancelNumberHint()
            model.setNumberHint(.none)
        }
        guard NSApp.modalWindow == nil else {
            clearNumberHint()
            return event
        }
        if let finder = sessionFinder {
            clearNumberHint()
            return handleSessionFinderKey(event, finder: finder, mods: mods)
        }
        if imagePreview != nil || showsReleaseNotes {
            clearNumberHint()
            if (mods == .command && event.charactersIgnoringModifiers == "w")
                || (mods.isEmpty && event.keyCode == 53) {
                imagePreview = nil
                showsReleaseNotes = false
                return nil
            }
            // Native preview controls keep their own keyboard handling. Events
            // aimed at the underlying workspace must not reach its terminal.
            return event.window?.sheetParent == nil ? nil : event
        }
        guard allowsWorkspaceEvents(event) else {
            clearNumberHint()
            return event
        }
        if mods == .command, event.charactersIgnoringModifiers == "w" {
            model.closeSelectedSession()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "v",
           let sessionId = model.globalSelectedSessionId,
           model.isTranscriptDrawerOpen(sessionId: sessionId),
           event.window?.firstResponder is NSTextView {
            let composer = model.sessionPromptComposer(sessionId: sessionId)
            if composer.isPromptFieldFocused {
                let workflow = model.sessionWorkflow(sessionId: sessionId)
                let operation = model.sessionOperationProjection(sessionId: sessionId)
                let allowImages = composer.imageLimits(workflow: workflow, operation: operation) != nil
                let allowTextFiles = composer.supportsFileAttachments(workflow: workflow, operation: operation)
                if DesktopScreenshotAttachmentImage.hasPasteboardImage(
                    allowImages: allowImages,
                    allowTextFiles: allowTextFiles
                ) {
                    clearNumberHint()
                    Task { @MainActor in
                        _ = await composer.pasteFromPasteboard(workflow: workflow, operation: operation)
                    }
                    return nil
                }
            }
        }
        if mods == .command, event.charactersIgnoringModifiers == "k" {
            clearNumberHint()
            presentSessionFinder()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers == "[" {
            clearNumberHint()
            model.navigateSessionBack()
            return nil
        }
        if mods == .command, event.charactersIgnoringModifiers == "]" {
            clearNumberHint()
            model.navigateSessionForward()
            return nil
        }
        if mods == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "a" {
            clearNumberHint()
            model.selectNextAttentionSession()
            return nil
        }
        if event.keyCode == 48 {
            if mods == .control { model.selectAdjacentSession(1); return nil }
            if mods == [.control, .shift] { model.selectAdjacentSession(-1); return nil }
        }
        if let value = event.charactersIgnoringModifiers, value.count == 1,
           let digit = Int(value), (1...9).contains(digit) {
            if mods == .command {
                clearNumberHint()
                model.selectProjectByIndex(digit - 1)
                return nil
            }
            if mods == .control {
                clearNumberHint()
                model.selectSessionByIndex(digit - 1)
                return nil
            }
        }
        clearNumberHint()
        if let controller = model.activeController,
           controller.terminalView.sendRestoredModifiedReturnIfNeeded(
               for: event,
               restoredAgentLive: controller.reattachedToExistingShell
                   && model.liveAgentSessions.contains(controller.sessionId),
               copilotFooterVisible: controller.showsCopilotFooter
           ) {
            return nil
        }
        return event
    }

    /// Navigation keys drive the finder's list while its search field keeps
    /// focus. Keys an input method is composing are left to the field.
    private func handleSessionFinderKey(
        _ event: NSEvent, finder: SessionFinderModel, mods: NSEvent.ModifierFlags
    ) -> NSEvent? {
        let key = event.charactersIgnoringModifiers
        if mods == .command, key == "w" || key == "k" {
            if key == "w" { dismissSessionFinder() }
            return nil
        }
        let composing = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        if !composing {
            switch event.keyCode {
            case 53 where mods.isEmpty:
                // Like Spotlight, Escape clears a search before it closes.
                if finder.query.isEmpty {
                    dismissSessionFinder()
                } else {
                    finder.query = ""
                }
                return nil
            case 125 where mods.isEmpty:
                finder.moveHighlight(1)
                return nil
            case 126 where mods.isEmpty:
                finder.moveHighlight(-1)
                return nil
            case 36 where mods.isEmpty, 76 where mods.isEmpty:
                finder.openHighlighted()
                return nil
            default:
                break
            }
            if mods == .control, key == "n" || key == "p" {
                finder.moveHighlight(key == "n" ? 1 : -1)
                return nil
            }
        }
        // Events aimed at the underlying workspace must not reach its terminal.
        return event.window?.sheetParent == nil ? nil : event
    }
}
