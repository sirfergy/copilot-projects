import AppKit

@MainActor
final class CopilotPromptComposer: NSObject, NSTextViewDelegate {
    enum Outcome {
        case started, cancelled, newTerminal
    }

    let alert = NSAlert()
    let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
    private let instructions = "Write the first prompt for an interactive Copilot session. "
        + "Return adds a line; Command-Return starts Copilot. "
        + "If startup fails, use the tab's Copy Starting Prompt menu before closing the tab or quitting."

    override init() {
        super.init()
        alert.messageText = "Start Copilot with a Prompt"
        alert.addButton(withTitle: "Start Copilot")
        alert.addButton(withTitle: "Cancel")
        let terminalButton = alert.addButton(withTitle: "New Terminal")
        terminalButton.isHidden = true
        terminalButton.keyEquivalent = ""
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[0].keyEquivalentModifierMask = .command
        alert.buttons[1].keyEquivalent = "\u{1b}"

        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Starting prompt")
        textView.delegate = self

        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.window.initialFirstResponder = textView
        updateValidation()
    }

    func textDidChange(_ notification: Notification) {
        updateValidation()
    }

    private func updateValidation() {
        let valid = SessionInputValidation.isValidPrompt(textView.string)
        alert.buttons[0].isEnabled = valid
        alert.informativeText = valid || textView.string.isEmpty
            ? instructions
            : "Enter a nonempty prompt of at most 8,192 UTF-8 bytes, without terminal control characters."
    }

    func run(
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        start: @MainActor (String) throws -> Void
    ) -> Outcome {
        var offersTerminal = false
        while true {
            alert.buttons[2].isHidden = !offersTerminal
            alert.layout()
            alert.window.initialFirstResponder = textView
            let response = present(alert)
            if response == .alertThirdButtonReturn, offersTerminal {
                return .newTerminal
            }
            guard response == .alertFirstButtonReturn else { return .cancelled }
            do {
                try start(textView.string)
                return .started
            } catch {
                // Keep the same editor and its text on synchronous launch failures.
                alert.informativeText = error.localizedDescription
                switch error as? AppModel.CopilotSessionStartError {
                case .copilotUnavailable, .backendUnavailable:
                    offersTerminal = true
                default:
                    offersTerminal = false
                }
            }
        }
    }
}
