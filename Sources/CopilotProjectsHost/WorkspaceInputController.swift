import AppKit
import Combine

@MainActor
final class WorkspaceInputController: ObservableObject {
    @Published var imagePreview: TranscriptImagePreviewItem?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func presentImage(_ item: TranscriptImagePreviewItem) {
        guard model.globalSelectedSessionId == item.id.sessionId,
              model.isTranscriptDrawerOpen(sessionId: item.id.sessionId) else {
            NSLog("Ignoring an image preview from an inactive session drawer.")
            return
        }
        imagePreview = item
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
}
