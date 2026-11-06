import AppKit
import CopilotProjectsProtocol
import SwiftTerm

/// Process events from a `ProcessTerminalView`, delivered on the main actor.
@MainActor
protocol ProcessTerminalViewDelegate: AnyObject {
    func setTerminalTitle(source: ProcessTerminalView, title: String)
    func hostCurrentDirectoryUpdate(source: ProcessTerminalView, directory: String?)
    func processTerminated(source: ProcessTerminalView, exitCode: Int32?)
    /// No process started, so no `processTerminated` follows.
    func processFailedToStart(source: ProcessTerminalView, error: LocalProcessError)
}

/// Runs a local process on a PTY, like SwiftTerm's `LocalProcessTerminalView`,
/// but hands every output batch to `consumeProcessOutput(_:)` on the main
/// thread before it is parsed.
///
/// `LocalProcess` delivers each batch with `DispatchQueue.main.sync`, so
/// batches arrive in order and its reader waits until each one returns.
/// Termination and launch failures are queued on main behind the output that
/// was already delivered.
class ProcessTerminalView: TerminalView, TerminalViewDelegate {
    private(set) var process: LocalProcess!
    weak var processDelegate: ProcessTerminalViewDelegate?
    var onDeepLink: ((AppDeepLink) -> Void)?
    private let events = ProcessEvents()
    private var isProbingExplicitLink = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupProcess()
    }

    override init(frame: CGRect, font: NSFont? = nil, options: TerminalOptions) {
        super.init(frame: frame, font: font, options: options)
        setupProcess()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupProcess()
    }

    private func setupProcess() {
        terminalDelegate = self
        events.view = self
        process = LocalProcess(delegate: events, dispatchQueue: .main)
    }

    /// Replaces the process with one built on this view's own delegate, so
    /// tests can script launch failures through the production callbacks.
    func replaceProcess(_ make: (LocalProcessDelegate) -> LocalProcess) {
        process = make(events)
    }

    /// Receives one output batch before parsing. It must feed the bytes, or
    /// keep them to feed later, before returning.
    func consumeProcessOutput(_ slice: ArraySlice<UInt8>) {
        feed(byteArray: slice)
    }

    func startProcess(
        executable: String = "/bin/bash",
        args: [String] = [],
        environment: [String]? = nil,
        execName: String? = nil,
        currentDirectory: String? = nil
    ) {
        process.startProcess(
            executable: executable, args: args, environment: environment,
            execName: execName, currentDirectory: currentDirectory)
    }

    func terminate() {
        process.terminate()
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        processDelegate?.processTerminated(source: self, exitCode: exitCode)
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        feed(text: "\r\nProcess launch failed: \(error)\r\n")
        processDelegate?.processFailedToStart(source: self, error: error)
    }

    /// The grid in cells and in pixels; programs that draw images size them
    /// from the pixel fields.
    func getWindowSize() -> winsize {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let dimensions = terminalDimensions
        // The default overlay scroller reserves no width, so the optimal
        // frame is exactly the cell grid.
        let grid = getOptimalFrameSize()
        return winsize(
            ws_row: UInt16(dimensions.rows), ws_col: UInt16(dimensions.cols),
            ws_xpixel: UInt16(Int(grid.width * scale)),
            ws_ypixel: UInt16(Int(grid.height * scale)))
    }

    // MARK: - TerminalViewDelegate

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        var size = getWindowSize()
        _ = process.updateWindowSize(&size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        processDelegate?.setTerminalTitle(source: self, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        processDelegate?.hostCurrentDirectoryUpdate(source: self, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let string = String(bytes: content, encoding: .utf8) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([string as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link),
           let deepLink = AppDeepLink(url: url),
           routeDeepLink(deepLink) {
            return
        }
        DefaultTerminalLinkDelegate.shared.requestOpenLink(source: source, link: link, params: params)
    }

    @discardableResult
    func routeDeepLink(_ deepLink: AppDeepLink) -> Bool {
        guard let onDeepLink else { return false }
        onDeepLink(deepLink)
        return true
    }

    func explicitLink(
        atCol col: Int,
        row: Int,
        preserveCommandHover: Bool = false
    ) -> String? {
        let dimensions = terminalDimensions
        guard col >= 0, col < dimensions.cols,
              row >= 0, row < dimensions.rows else {
            return nil
        }
        return probeExplicitLink(
            atVisualCol: col,
            row: row,
            preserveCommandHover: preserveCommandHover
        )
    }

    func appDeepLink(
        atCol col: Int,
        row: Int,
        preserveCommandHover: Bool = false
    ) -> AppDeepLink? {
        guard let link = explicitLink(
            atCol: col,
            row: row,
            preserveCommandHover: preserveCommandHover
        ),
        let url = URL(string: link) else {
            return nil
        }
        return AppDeepLink(url: url)
    }

    nonisolated override func send(source: Terminal, data: ArraySlice<UInt8>) {
        if Thread.isMainThread, MainActor.assumeIsolated({ isProbingExplicitLink }) {
            return
        }
        super.send(source: source, data: data)
    }

    private func probeExplicitLink(
        atVisualCol col: Int,
        row: Int,
        preserveCommandHover: Bool
    ) -> String? {
        guard enableOsc8Hyperlinks else { return nil }
        let dimensions = terminalDimensions
        let rendered = getOptimalFrameSize()
        guard dimensions.cols > 0, dimensions.rows > 0,
              rendered.width > 0, rendered.height > 0 else {
            return nil
        }
        let pointInView = NSPoint(
            x: (CGFloat(col) + 0.5) * rendered.width / CGFloat(dimensions.cols),
            y: bounds.height - (CGFloat(row) + 0.5) * rendered.height / CGFloat(dimensions.rows)
        )
        let pointInWindow = convert(pointInView, to: nil)
        guard let flagsOn = NSEvent.keyEvent(
            with: .flagsChanged,
            location: pointInWindow,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        ),
        let moveEvent = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ) else {
            return nil
        }
        let savedLinkReporting = linkReporting
        let savedHighlightMode = linkHighlightMode
        linkReporting = .none
        linkHighlightMode = .always
        isProbingExplicitLink = true
        defer {
            isProbingExplicitLink = false
            mouseExited(with: moveEvent)
            linkReporting = savedLinkReporting
            linkHighlightMode = savedHighlightMode
            if preserveCommandHover {
                flagsChanged(with: flagsOn)
            }
        }
        mouseExited(with: moveEvent)
        let existingFields = Set(
            subviews.compactMap { $0 as? NSTextField }
                .map(ObjectIdentifier.init)
        )
        flagsChanged(with: flagsOn)
        mouseMoved(with: moveEvent)
        let previewField = subviews.compactMap { $0 as? NSTextField }.last {
            !existingFields.contains(ObjectIdentifier($0))
        }
        return previewField?.stringValue
    }
}

@MainActor
private final class DefaultTerminalLinkDelegate: TerminalViewDelegate {
    static let shared = DefaultTerminalLinkDelegate()
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Forwards `LocalProcess` callbacks, which it delivers on the main queue.
private final class ProcessEvents: LocalProcessDelegate {
    weak var view: ProcessTerminalView?

    /// Called on the thread that starts the process, which is always main here.
    func getWindowSize() -> winsize {
        MainActor.assumeIsolated { view?.getWindowSize() ?? winsize() }
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { view?.consumeProcessOutput(slice) }
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        MainActor.assumeIsolated { view?.processTerminated(source, exitCode: exitCode) }
    }

    func processFailedToStart(_ source: LocalProcess, error: LocalProcessError) {
        MainActor.assumeIsolated { view?.processFailedToStart(source, error: error) }
    }
}
