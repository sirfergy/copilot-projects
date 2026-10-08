import AppKit
import Combine

@MainActor
final class WorkspaceInputController: ObservableObject {
    @Published var imagePreview: TranscriptImagePreviewItem?
    @Published private(set) var sessionFinder: SessionFinderModel?
    private let model: AppModel
    private let sessionRanker: SessionRanking

    init(model: AppModel, sessionRanker: SessionRanking = LunaSessionRanker()) {
        self.model = model
        self.sessionRanker = sessionRanker
    }

    /// A workspace sheet owns the keyboard, so workspace commands stay disabled.
    var hasWorkspaceSheet: Bool { imagePreview != nil || sessionFinder != nil }

    func presentImage(_ item: TranscriptImagePreviewItem) {
        guard sessionFinder == nil else { return }
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
        sessionFinder = SessionFinderModel(
            sources: model.sessionFinderSources,
            currentSessionId: model.globalSelectedSessionId,
            ranker: sessionRanker
        ) { [weak self] sessionId in
            self?.openFromSessionFinder(sessionId)
        }
    }

    func dismissSessionFinder() {
        sessionFinder?.cancel()
        sessionFinder = nil
    }

    func openFromSessionFinder(_ sessionId: String) {
        // A session that ended while the finder was open leaves it open.
        guard let project = model.projects.first(where: { project in
            project.sessions.contains { $0.id == sessionId }
        }) else { return }
        dismissSessionFinder()
        // Select the session first: switching projects marks the project's
        // selected tab as seen, and that should be the tab being opened.
        model.selectSession(projectId: project.id, sessionId: sessionId)
        if model.selectedProjectId != project.id { model.selectProject(project.id) }
        DispatchQueue.main.async { [model] in model.focusActiveTerminal() }
    }

    func allowsWorkspaceEvents(_ event: NSEvent) -> Bool {
        imagePreview == nil && NSApp.modalWindow == nil
            && event.window?.sheetParent == nil && event.window?.attachedSheet == nil
            && NSApp.keyWindow?.sheetParent == nil && NSApp.keyWindow?.attachedSheet == nil
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
        if imagePreview != nil {
            clearNumberHint()
            if (mods == .command && event.charactersIgnoringModifiers == "w")
                || (mods.isEmpty && event.keyCode == 53) {
                imagePreview = nil
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
        if mods == .command, event.charactersIgnoringModifiers == "k" {
            clearNumberHint()
            presentSessionFinder()
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
