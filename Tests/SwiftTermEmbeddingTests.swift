import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost
@testable import SwiftTerm

final class SwiftTermEmbeddingTests: XCTestCase {
    @MainActor
    private final class ProcessDelegate: ProcessTerminalViewDelegate {
        var exited = false
        var titles: [String] = []
        var directories: [String?] = []
        func processTerminated(source: ProcessTerminalView, exitCode: Int32?) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(exitCode, 0)
            exited = true
        }
        func setTerminalTitle(source: ProcessTerminalView, title: String) { titles.append(title) }
        func hostCurrentDirectoryUpdate(source: ProcessTerminalView, directory: String?) {
            directories.append(directory)
        }
        func processFailedToStart(source: ProcessTerminalView, error: LocalProcessError) {}
    }

    /// Records every batch the process view hands over before parsing.
    private final class RecordingProcessView: ProcessTerminalView {
        var received: [UInt8] = []
        var batches = 0
        var deliveredOffMain = false
        override func consumeProcessOutput(_ slice: ArraySlice<UInt8>) {
            if !Thread.isMainThread { deliveredOffMain = true }
            received += slice
            batches += 1
            super.consumeProcessOutput(slice)
        }
    }

    @MainActor
    private func waitUntil(
        _ timeout: Duration = .seconds(5), _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @MainActor
    private final class MouseDelegate: TerminalViewDelegate {
        var writes: [[UInt8]] = []
        func send(source: TerminalView, data: ArraySlice<UInt8>) { writes.append(Array(data)) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    }

    /// Lets a test drive key status without a window server.
    private final class StubKeyWindow: NSWindow {
        var stubIsKey = false
        override var isKeyWindow: Bool { stubIsKey }
    }

    private final class ScrollEvent: NSEvent {
        var point: NSPoint = .zero
        var delta: CGFloat = 0
        var precise = true
        override var locationInWindow: NSPoint { point }
        override var scrollingDeltaY: CGFloat { delta }
        override var hasPreciseScrollingDeltas: Bool { precise }
        override var modifierFlags: NSEvent.ModifierFlags { [] }
    }

    @MainActor
    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in view: ProjectsTerminalView,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil),
            modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0))
    }

    @MainActor
    private func keyEvent(
        in view: ProjectsTerminalView,
        characters: String = "\r",
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16 = 36
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: view.window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: keyCode
        ))
    }

    @MainActor
    private func focusedInputTerminal() -> (
        view: ProjectsTerminalView,
        window: NSWindow
    ) {
        _ = NSApplication.shared
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        return (view, window)
    }

    /// Polls a PTY capture file until it holds `expected` or five seconds pass.
    private func captured(at url: URL, awaiting expected: Data) async throws -> Data {
        let deadline = ContinuousClock.now + .seconds(5)
        var data = Data()
        while data != expected, ContinuousClock.now < deadline {
            data = (try? Data(contentsOf: url)) ?? Data()
            if data != expected {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        return data
    }

    @MainActor
    func testRestoredModifiedReturnBytesPreserveModifiers() {
        let cases: [(NSEvent.ModifierFlags, String)] = [
            (.shift, "\u{1b}[13;2u"),
            (.option, "\u{1b}[13;3u"),
            (.control, "\u{1b}[13;5u"),
            (.command, "\u{1b}[13;9u"),
        ]
        for (modifiers, expected) in cases {
            XCTAssertEqual(
                ProjectsTerminalView.restoredModifiedReturnBytes(for: modifiers),
                Array(expected.utf8)
            )
        }
        XCTAssertNil(ProjectsTerminalView.restoredModifiedReturnBytes(for: []))
    }

    @MainActor
    func testRestoredModifiedReturnUsesLiveProcessInput() async throws {
        let (view, window) = focusedInputTerminal()
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("restored-return-\(UUID().uuidString)")
        view.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "stty raw -echo; printf READY; exec /bin/cat > \"$0\"",
                capture.path,
            ],
            environment: []
        )
        defer {
            view.terminate()
            window.contentView = nil
            try? FileManager.default.removeItem(at: capture)
        }

        let readyDeadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while !ready, ContinuousClock.now < readyDeadline {
            ready = view.terminalStateSnapshot().visibleRows.contains {
                $0.text.contains("READY")
            }
            if !ready {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTAssertTrue(ready)

        let sends = view.process.sendCount
        let event = try keyEvent(in: view, modifiers: .command)
        view.setMarkedText(
            "か",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
            for: event,
            restoredAgentLive: true,
            copilotFooterVisible: true
        ))
        XCTAssertEqual(view.process.sendCount, sends)
        view.unmarkText()

        view.feed(text: "selected")
        view.selectAll()
        XCTAssertTrue(view.selectionActive)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)
        XCTAssertTrue(view.sendRestoredModifiedReturnIfNeeded(
            for: event,
            restoredAgentLive: true,
            copilotFooterVisible: true
        ))
        XCTAssertEqual(view.process.sendCount, sends + 1)
        XCTAssertFalse(view.selectionActive)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)

        let expected = Data("\u{1b}[13;9u".utf8)
        let delivered = try await captured(at: capture, awaiting: expected)
        XCTAssertEqual(delivered, expected)
    }

    @MainActor
    func testRemoteInputScopesFocusFromTheLastDeliveredReport() async throws {
        _ = NSApplication.shared
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let window = StubKeyWindow(
            contentRect: view.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        XCTAssertTrue(window.makeFirstResponder(view))
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-focus-\(UUID().uuidString)")
        view.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "stty raw -echo; printf READY; exec /bin/cat > \"$0\"",
                capture.path,
            ],
            environment: []
        )
        defer {
            view.terminate()
            window.contentView = nil
            try? FileManager.default.removeItem(at: capture)
        }

        let readyDeadline = ContinuousClock.now + .seconds(5)
        var ready = false
        while !ready, ContinuousClock.now < readyDeadline {
            ready = view.terminalStateSnapshot().visibleRows.contains {
                $0.text.contains("READY")
            }
            if !ready {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        XCTAssertTrue(ready)

        var expected = Data()
        func expect(_ bytes: [UInt8]) async throws {
            expected.append(contentsOf: bytes)
            let delivered = try await captured(at: capture, awaiting: expected)
            XCTAssertEqual(
                String(decoding: delivered, as: UTF8.self).debugDescription,
                String(decoding: expected, as: UTF8.self).debugDescription
            )
            XCTAssertEqual(delivered, expected)
        }
        func expect(_ text: String) async throws {
            try await expect(Array(text.utf8))
        }

        // A first responder in a background window reports focus-out.
        view.feed(text: "\u{1b}[?1004h")
        try await expect("\u{1b}[O")

        XCTAssertTrue(view.sendRemoteCommand("a", forceFocusReporting: true))
        try await expect("\u{1b}[Ia\r\u{1b}[O")
        XCTAssertTrue(view.sendRemotePrompt("p"))
        try await expect("\u{1b}[I\u{1b}\u{1b}\u{1b}[200~p\u{1b}[201~\u{1b}[I\r\u{1b}[O")

        // Activation flips hasFocus before SwiftTerm's focus-in reaches the PTY,
        // so a command handled in between must still be scoped.
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(view.sendRemoteCommand("b", forceFocusReporting: true))
        try await expect("\u{1b}[Ib\r\u{1b}[O\u{1b}[I")

        XCTAssertTrue(view.sendRemoteCommand("c", forceFocusReporting: true))
        XCTAssertTrue(view.sendRemoteKey("enter", forceFocusReporting: true))
        try await expect("c\r\r")

        // The program still believes it is focused until the focus-out lands.
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(view.sendRemoteKey("enter", forceFocusReporting: true))
        try await expect("\r\u{1b}[O")

        // Re-enabling queues a focus-out report and activation queues focus-in
        // behind it; they reach the PTY in order and the later one decides.
        view.feed(text: "\u{1b}[?1004l\u{1b}[?1004h")
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await expect("\u{1b}[O\u{1b}[I")
        XCTAssertTrue(view.sendRemoteCommand("d", forceFocusReporting: true))
        try await expect("d\r")

        // Once the program turns reporting off, no report tracks later focus
        // changes, so the view's own focus decides.
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await expect("\u{1b}[O")
        view.feed(text: "\u{1b}[?1004l")
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(view.sendRemoteCommand("e", forceFocusReporting: true))
        try await expect("e\r")
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(view.sendRemoteCommand("f", forceFocusReporting: true))
        try await expect("\u{1b}[If\r\u{1b}[O")

        // With 8-bit controls (S8C1T) the reports use a single-byte CSI.
        view.feed(text: "\u{1b} G\u{1b}[?1004h")
        try await expect([0x9b, 0x4f])
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await expect([0x9b, 0x49])
        XCTAssertTrue(view.sendRemoteCommand("g", forceFocusReporting: true))
        try await expect("g\r")
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await expect([0x9b, 0x4f])
        XCTAssertTrue(view.sendRemoteCommand("h", forceFocusReporting: true))
        try await expect("\u{1b}[Ih\r\u{1b}[O")

        // A focus-in left over from before reporting was turned off must not
        // keep a later background command unscoped.
        window.stubIsKey = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await expect([0x9b, 0x49])
        view.feed(text: "\u{1b}[?1004l")
        window.stubIsKey = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertTrue(view.sendRemoteCommand("i", forceFocusReporting: true))
        try await expect("\u{1b}[Ii\r\u{1b}[O")
    }

    /// Remote Kitty capture only understands direct (`t=d`) frames. That is
    /// complete only while the terminal refuses local media, so clients that
    /// probe for file or shared-memory transfer fall back to direct frames.
    @MainActor
    func testKittyLocalMediaQueriesAreRefusedSoClientsSendDirectFrames() async throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        let path = Data("/tmp/tty-graphics-protocol-probe".utf8).base64EncodedString()
        let pixel = Data([0xff, 0x00, 0x00, 0xff]).base64EncodedString()
        for (id, medium) in [(1, "f"), (2, "t"), (3, "s")] {
            view.feed(text: "\u{1b}_Gi=\(id),a=q,t=\(medium),f=32,s=1,v=1;\(path)\u{1b}\\")
        }
        view.feed(text: "\u{1b}_Gi=4,a=q,t=d,f=32,s=1,v=1;\(pixel)\u{1b}\\")

        let deadline = ContinuousClock.now + .seconds(5)
        while delegate.writes.count < 4, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(delegate.writes.map { String(decoding: $0, as: UTF8.self) }, [
            "\u{1b}_Gi=1;EINVAL: unsupported medium\u{1b}\\",
            "\u{1b}_Gi=2;EINVAL: unsupported medium\u{1b}\\",
            "\u{1b}_Gi=3;EINVAL: unsupported medium\u{1b}\\",
            "\u{1b}_Gi=4;OK\u{1b}\\",
        ])
    }

    @MainActor
    func testRestoredModifiedReturnLeavesOtherInputUnchanged() throws {
        let (view, window) = focusedInputTerminal()
        defer { window.contentView = nil }

        let rejected: [(NSEvent, Bool, Bool)] = [
            (try keyEvent(in: view, modifiers: []), true, true),
            (try keyEvent(in: view, characters: "w", modifiers: .command, keyCode: 13), true, true),
            (try keyEvent(in: view, modifiers: .command), false, true),
            (try keyEvent(in: view, modifiers: .command), true, false),
        ]
        for (event, restoredAgentLive, copilotFooterVisible) in rejected {
            XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
                for: event,
                restoredAgentLive: restoredAgentLive,
                copilotFooterVisible: copilotFooterVisible
            ))
        }
        view.feed(text: "\u{1b}[=10;1u")
        XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
            for: try keyEvent(in: view, modifiers: .command),
            restoredAgentLive: true,
            copilotFooterVisible: true
        ))
        XCTAssertEqual(
            view.terminalInputStateSnapshot()?.keyboardEnhancementFlags,
            [.reportEvents, .reportAllKeys]
        )
        view.feed(text: "\u{1b}[=0;1u")
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
            for: try keyEvent(in: view, modifiers: .command),
            restoredAgentLive: true,
            copilotFooterVisible: true
        ))
    }

    @MainActor
    private func assertForwardedClickMatchesNative(
        _ view: ProjectsTerminalView,
        delegate: MouseDelegate,
        point: NSPoint,
        col: Int,
        row: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let viewportRow = try XCTUnwrap(
            view.terminalContentSnapshot(region: .viewport)).capturedRange.lowerBound
        let down = try mouseEvent(.leftMouseDown, at: point, in: view)
        let up = try mouseEvent(.leftMouseUp, at: point, in: view)
        view.allowMouseReporting = true
        delegate.writes.removeAll()
        view.mouseDown(with: down)
        view.mouseUp(with: up)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        let native = delegate.writes
        XCTAssertEqual(native, [
            Array("\u{1b}[<0;\(col + 1);\(row + 1)M".utf8),
            Array("\u{1b}[<0;\(col + 1);\(row + 1)m".utf8),
        ], "Native reporting must produce an independent press/release oracle", file: file, line: line)

        // Native input delivery reveals the caret; compare both routes in the
        // same viewport, including when the reader has scrolled into history.
        view.scrollTo(row: viewportRow, notifyAccessibility: false)
        XCTAssertEqual(view.terminalContentSnapshot(region: .viewport)?.capturedRange.lowerBound, viewportRow,
                       file: file, line: line)
        view.allowMouseReporting = false
        delegate.writes.removeAll()
        view.forwardClick(up)
        XCTAssertEqual(delegate.writes, native, "Forwarded hit differs from the rendered cell", file: file, line: line)
    }

    @MainActor
    func testForwardedClicksMatchNativeCellsAfterResizeAndFontChanges() async throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        view.linkHighlightMode = .hoverWithModifier
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(view.scrollerStyle, .overlay, "Optimal width must not include a reserved scrollbar")
        for fontSize: CGFloat in [13, 17] {
            view.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            for size in [
                NSSize(width: 1916, height: 1018),
                NSSize(width: 1919, height: 1021),
                NSSize(width: 1000, height: 700),
                NSSize(width: 800, height: 480),
            ] {
                view.setFrameSize(size)
                let dimensions = view.terminalDimensions
                let rendered = view.getOptimalFrameSize()
                let cellW = rendered.width / CGFloat(dimensions.cols)
                let cellH = rendered.height / CGFloat(dimensions.rows)
                for row in [0, dimensions.rows / 2, dimensions.rows - 1] {
                    for col in [0, dimensions.cols / 2, dimensions.cols - 1] {
                        let point = NSPoint(
                            x: (CGFloat(col) + 0.5) * cellW,
                            y: view.bounds.height - (CGFloat(row) + 0.5) * cellH)
                        try await assertForwardedClickMatchesNative(
                            view, delegate: delegate, point: point, col: col, row: row)
                    }
                }
            }
        }
    }

    @MainActor
    func testForwardedClicksConvertWindowCoordinatesAndIgnoreScrollbackOffset() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1300, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1300, height: 900))
        window.contentView = root
        let view = ProjectsTerminalView(frame: NSRect(x: 37, y: 21, width: 1007, height: 703))
        root.addSubview(view)
        defer { window.contentView = nil }
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        view.linkHighlightMode = .hoverWithModifier
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h"
            + (0..<150).map { "line \($0)\r\n" }.joined())
        view.scrollUp(lines: 5)
        let snapshot = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        XCTAssertGreaterThan(snapshot.capturedRange.lowerBound, 0)
        XCTAssertLessThan(snapshot.capturedRange.lowerBound, snapshot.liveTopRow)
        let dimensions = view.terminalDimensions
        let rendered = view.getOptimalFrameSize()
        let col = dimensions.cols - 2
        let row = dimensions.rows - 2
        let point = NSPoint(
            x: (CGFloat(col) + 0.5) * rendered.width / CGFloat(dimensions.cols),
            y: view.bounds.height - (CGFloat(row) + 0.5) * rendered.height / CGFloat(dimensions.rows))
        XCTAssertNotEqual(view.convert(point, to: nil), point)
        try await assertForwardedClickMatchesNative(view, delegate: delegate, point: point, col: col, row: row)
    }

    @MainActor
    func testForwardedClicksClampPaddingAndPreserveModifiers() throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 1919, height: 1021))
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = false
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let dimensions = view.terminalDimensions
        for (point, col, row) in [
            (NSPoint(x: -10, y: view.bounds.height + 10), 0, 0),
            (NSPoint(x: view.bounds.width - 0.1, y: 0.1), dimensions.cols - 1, dimensions.rows - 1),
            (NSPoint(x: view.bounds.width + 10, y: -10), dimensions.cols - 1, dimensions.rows - 1),
        ] {
            delegate.writes.removeAll()
            view.forwardClick(try mouseEvent(
                .leftMouseUp, at: point, in: view, modifiers: [.shift, .option, .control]))
            XCTAssertEqual(delegate.writes, [
                Array("\u{1b}[<28;\(col + 1);\(row + 1)M".utf8),
                Array("\u{1b}[<28;\(col + 1);\(row + 1)m".utf8),
            ])
        }
        view.setFrameSize(.zero)
        delegate.writes.removeAll()
        view.forwardClick(try mouseEvent(.leftMouseUp, at: .zero, in: view))
        XCTAssertEqual(delegate.writes, [Array("\u{1b}[<0;1;1M".utf8), Array("\u{1b}[<0;1;1m".utf8)])
    }

    @MainActor
    func testPreciseForwardedScrollUsesRenderedRowHeightAndCoordinates() {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 1919, height: 1021))
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = false
        view.feed(text: "\u{1b}[?1006h")
        let dimensions = view.terminalDimensions
        let rendered = view.getOptimalFrameSize()
        let cellH = rendered.height / CGFloat(dimensions.rows)
        let event = ScrollEvent()
        event.point = NSPoint(
            x: (CGFloat(dimensions.cols) - 1.5) * rendered.width / CGFloat(dimensions.cols),
            y: view.bounds.height - (CGFloat(dimensions.rows) - 1.5) * cellH)
        event.delta = cellH / 4
        for _ in 0..<3 {
            XCTAssertTrue(view.forwardScroll(event, agentLive: true))
            XCTAssertTrue(delegate.writes.isEmpty)
        }
        XCTAssertTrue(view.forwardScroll(event, agentLive: true))
        let up = Array("\u{1b}[<64;\(dimensions.cols - 1);\(dimensions.rows - 1)M".utf8)
        XCTAssertEqual(delegate.writes, [up])

        delegate.writes.removeAll()
        event.delta = -cellH
        XCTAssertTrue(view.forwardScroll(event, agentLive: true))
        let down = Array("\u{1b}[<65;\(dimensions.cols - 1);\(dimensions.rows - 1)M".utf8)
        XCTAssertEqual(delegate.writes, [down])

        delegate.writes.removeAll()
        event.precise = false
        event.delta = 100
        XCTAssertTrue(view.forwardScroll(event, agentLive: true))
        XCTAssertEqual(delegate.writes, Array(repeating: up, count: 8))
    }

    @MainActor
    func testLargeOutputReachesTheViewOnMainInOrderExactlyOnce() async throws {
        let view = RecordingProcessView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = ProcessDelegate()
        view.processDelegate = delegate
        let count = 32_768
        view.startProcess(
            executable: "/usr/bin/awk",
            args: ["BEGIN { for (i = 0; i < \(count); i++) printf \"%08x\", i }"],
            environment: [])
        defer { view.terminate() }
        try await waitUntil(.seconds(10)) { delegate.exited }
        XCTAssertTrue(delegate.exited)
        let expected = Array((0..<count).map { String(format: "%08x", $0) }.joined().utf8)
        XCTAssertEqual(view.received.count, expected.count)
        XCTAssertTrue(view.received == expected, "Batches must arrive in order, each once")
        XCTAssertGreaterThan(view.batches, 1)
        XCTAssertFalse(view.deliveredOffMain)
        XCTAssertEqual(view.diagnostics.bytesFed, expected.count)
    }

    @MainActor
    func testProcessTitleAndDirectoryReachTheDelegate() async throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = ProcessDelegate()
        view.processDelegate = delegate
        view.startProcess(
            executable: "/bin/sh",
            args: ["-c", "printf '\\033]0;fixture-title\\007\\033]7;file://localhost/tmp/fixture-cwd\\007'"],
            environment: [])
        defer { view.terminate() }
        try await waitUntil { delegate.exited && !delegate.titles.isEmpty && !delegate.directories.isEmpty }
        XCTAssertEqual(delegate.titles.last, "fixture-title")
        XCTAssertTrue(delegate.directories.last??.hasSuffix("/tmp/fixture-cwd") == true,
                      String(describing: delegate.directories))
    }

    @MainActor
    func testChildSeesTheCellGridInPixelsAtLaunchAndAfterResize() async throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let cell = try XCTUnwrap(view.cellDimension)
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        func expected(cols: Int, rows: Int) -> [Int] {
            [rows, cols, Int(cell.width * CGFloat(cols) * scale), Int(cell.height * CGFloat(rows) * scale)]
        }
        func childSize() -> [Int] {
            var size = winsize()
            guard ioctl(view.process.childfd, TIOCGWINSZ, &size) == 0 else { return [] }
            return [Int(size.ws_row), Int(size.ws_col), Int(size.ws_xpixel), Int(size.ws_ypixel)]
        }
        let launch = view.terminalDimensions
        XCTAssertEqual(childSize(), [])
        view.startProcess(executable: "/bin/cat", args: [], environment: [])
        defer { view.terminate() }
        XCTAssertEqual(childSize(), expected(cols: launch.cols, rows: launch.rows))

        view.resize(cols: 50, rows: 10)
        XCTAssertEqual(childSize(), expected(cols: 50, rows: 10))
    }

    @MainActor
    func testActualPTYOutputReachesCaptureAndParserExactlyOnce() async throws {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = ProcessDelegate()
        view.processDelegate = delegate
        let png = try makePNG()
        let placeholder = "\u{10EEEE}\u{0305}\u{030D}"
        let output = RemoteKittyReplayEncoding.transmitOnlyFrames(imageId: 55, data: png)
            + RemoteKittyReplayEncoding.placementFrame(
                imageId: 55, placementId: 77, rows: 1, columns: 2,
                x: nil, y: nil, z: nil)
            + Array(("\u{1b}[38;2;0;0;55;58;2;0;0;77m" + placeholder + placeholder
                     + "\u{1b}[0m text").utf8)
        view.startProcess(executable: "/bin/sh",
                          args: ["-c", "printf '%s' \"$1\"", "consumer-test", String(decoding: output, as: UTF8.self)],
                          environment: [])
        defer { view.terminate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !delegate.exited, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(delegate.exited)
        XCTAssertGreaterThan(view.remoteContentGeneration, 0)
        XCTAssertEqual(view.remoteContentGeneration, UInt64(view.diagnostics.batches))
        XCTAssertEqual(view.diagnostics.bytesFed, output.count)
        let version = try XCTUnwrap(view.kittyImageCapture.currentVersion(for: 55, placementId: 77))
        XCTAssertEqual(view.kittyImageCapture.imageData(imageId: 55, version: version), png)
        let snapshot = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        let cells = RemoteKittyPlacementScanner.gridCells(
            from: snapshot.rows, relativeTo: snapshot.capturedRange.lowerBound)
        XCTAssertEqual(cells.map(\.col), [0, 1])
        XCTAssertTrue(cells.allSatisfy { $0.imageId == 55 && $0.placementId == 77 && $0.lineId == 0 })
        let screen = RemoteTerminalScreen.capture(
            sessionId: "fixture", snapshot: snapshot, terminalScroll: true, afterLine: nil)
        XCTAssertEqual(screen.lines.first, "   text")
        let generation = view.remoteContentGeneration
        view.feed(text: " replay")
        XCTAssertEqual(view.remoteContentGeneration, generation, "Parser replay must not recapture raw output")
        XCTAssertEqual(view.kittyImageCapture.currentVersion(for: 55, placementId: 77), version)
    }

    @MainActor
    private func makePNG() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    func testRestoredPixelsFollowTheBufferedAlternateScreenSwitch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString
        store.persistRetain(
            sessionId: sessionId, imageId: 8, version: 321, data: try makePNG(),
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 321, placementId: 7, rows: 1, columns: 1, x: nil, y: nil, z: nil)])
        await store.flush()
        let view = ProjectsTerminalView(frame: .zero)
        defer { view.cancelImageRestore() }
        view.configureImagePersistence(sessionId: sessionId, diskStore: store)
        view.consumeProcessOutput(Array("\u{1b}[?1049h".utf8)[...])
        await view.waitForImageRestoreForTesting()
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        for transition in ["", "\u{1b}[?1049l", "\u{1b}[?1049h"] {
            if !transition.isEmpty { view.consumeProcessOutput(Array(transition.utf8)[...]) }
            view.replayRestoredPlacementsForTesting()
            let generation = view.remoteContentGeneration
            delegate.writes.removeAll()
            // A successful put proves the parser has the restored image bytes
            // in the active screen, including a freshly cleared alternate one.
            view.feed(text: "\u{1b}_Ga=p,U=1,i=8,p=9,c=1,r=1;\u{1b}\\")
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            let replies = delegate.writes.map { String(decoding: $0, as: UTF8.self) }
            XCTAssertEqual(replies, ["\u{1b}_Gi=8,p=9;OK\u{1b}\\"])
            XCTAssertEqual(view.kittyImageCapture.currentVersion(for: 8, placementId: 7), 321)
            XCTAssertEqual(view.remoteContentGeneration, generation)
        }
        await store.flush()
    }

    @MainActor
    func testSnapshotWireProjectionPreservesLegacyUnicodeAndWideTails() throws {
        let view = ProjectsTerminalView(frame: .zero, options: TerminalOptions(cols: 12, rows: 4, scrollback: 20))
        let cluster = "\u{A98F}\u{A9C0}\u{A994}\u{A9B8}"
        view.feed(text: cluster)
        let row = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport)?.rows.first)
        XCTAssertEqual(row.cells[0].text, cluster)
        XCTAssertEqual(row.cells[0].width, 2)
        XCTAssertEqual(row.remoteText, String(cluster.first!) + "\u{0}")
        XCTAssertNotEqual(row.remoteText, row.text, "Fixture demonstrates why the wire adapter must project cells")
        view.feed(text: "\u{1b}[2J\u{1b}[H界e\u{301} ")
        let wide = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport)?.rows.first)
        XCTAssertEqual(wide.remoteText, "界\u{0}e\u{301} ")
        let snapshot = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        let screen = RemoteTerminalScreen.capture(
            sessionId: "fixture", snapshot: snapshot, terminalScroll: true, afterLine: nil)
        XCTAssertEqual(screen.lines.first, "界 e\u{301} ")
    }

    @MainActor
    func testHistorySnapshotKeepsFiveHundredRowsAndIncrementalCoordinates() throws {
        let view = ProjectsTerminalView(frame: .zero, options: TerminalOptions(cols: 12, rows: 4, scrollback: 800))
        view.feed(text: (0..<1_000).map { "row\($0)\r\n" }.joined())
        let snapshot = try XCTUnwrap(view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 500)))
        let initial = RemoteTerminalScreen.capture(
            sessionId: "fixture", snapshot: snapshot, terminalScroll: false, afterLine: nil)
        XCTAssertEqual(initial.lines.count, 504)
        XCTAssertEqual(initial.historyStartLine, snapshot.capturedRange.lowerBound)
        XCTAssertEqual(initial.liveTopLine, snapshot.liveTopRow)
        let incremental = RemoteTerminalScreen.capture(
            sessionId: "fixture", snapshot: snapshot, terminalScroll: false,
            afterLine: snapshot.capturedRange.upperBound)
        XCTAssertFalse(incremental.reset)
        XCTAssertEqual(incremental.firstLine, snapshot.liveTopRow)
        XCTAssertEqual(incremental.lines, Array(initial.lines.suffix(4)))
    }

    @MainActor
    func testExplicitAgentWheelRemainsSGRAndBoundedWhenReportingIsDisabled() {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let delegate = MouseDelegate()
        view.terminalDelegate = delegate
        view.allowMouseReporting = false
        view.feed(text: "\u{1b}[?1006h")
        XCTAssertTrue(view.sendRemoteScroll(delta: Int.min, agentLive: true))
        let dimensions = view.terminalDimensions
        let expected = Array("\u{1b}[<65;\(dimensions.cols / 2 + 1);\(dimensions.rows / 2 + 1)M".utf8)
        XCTAssertEqual(delegate.writes, Array(repeating: expected, count: 8))
    }

    @MainActor
    private func makeRendererView(preference: String?) -> ProjectsTerminalView {
        let key = "COPILOT_PROJECTS_RENDERER"
        let previous = ProcessInfo.processInfo.environment[key]
        if let preference { setenv(key, preference, 1) } else { unsetenv(key) }
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
        }
        return ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
    }

    @MainActor
    func testForcedCoreGraphicsDisablesActualMetalAcrossAttachmentRevealAndParking() throws {
        let view = makeRendererView(preference: "coregraphics")
        defer { view.setRendererActive(false) }
        // Start with Metal on rather than relying on a particular upstream
        // initializer default. Shader loading failures must fail, not skip.
        try view.setUseMetal(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        XCTAssertFalse(view.isUsingMetalRenderer)
        view.setRendererActive(true)
        view.forceRedraw()
        XCTAssertEqual(view.rendererName, "coregraphics-forced")
        XCTAssertFalse(view.isUsingMetalRenderer)
        try view.setUseMetal(true)
        view.setRendererActive(true)
        XCTAssertFalse(view.isUsingMetalRenderer, "An unchanged warm-LRU flag must still enforce forced CG")
        view.setRendererActive(false)
        XCTAssertFalse(view.isUsingMetalRenderer)
    }

    @MainActor
    func testWarmLRURetainsExactlyThreeActualMetalRenderers() {
        let container = TerminalsContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let window = NSWindow(contentRect: container.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = container
        let ids = ["a", "b", "c", "d"]
        let views = Dictionary(uniqueKeysWithValues: ids.map { ($0, makeRendererView(preference: nil)) })
        defer {
            views.values.forEach { $0.setRendererActive(false) }
            window.contentView = nil
        }
        for id in ids {
            container.sync(order: ids, active: id, emptyHint: ("", ""), onNew: {}, provider: { views[$0] })
        }
        XCTAssertEqual(Set(views.filter { $0.value.isUsingMetalRenderer }.keys), Set(["b", "c", "d"]))
        XCTAssertFalse(views["a"]!.isUsingMetalRenderer)
        container.sync(order: ids, active: nil, emptyHint: ("", ""), onNew: {}, provider: { views[$0] })
        XCTAssertTrue(views.values.allSatisfy { !$0.isUsingMetalRenderer })
    }

    @MainActor
    func testStaleRevisionCannotReturnAnAlreadyCachedScreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Fixture", cwd: root.path)
        let project = Project(id: "fixture", name: "Fixture", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "fixture"))
        let model = AppModel(stateRepository: repository, isAppActive: { false },
                             agentActivityDirectory: root, resumeMarkerDirectory: root,
                             kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")))
        defer { model.detachAllClients() }
        let view = try XCTUnwrap(model.controller(for: sessionId)?.terminalView)
        let bridge = RemoteModelBridge(model: model)
        view.consumeProcessOutput(Array("first".utf8)[...])
        let before = try XCTUnwrap(bridge.screenRevision(sessionId: sessionId))
        XCTAssertNotNil(bridge.screen(sessionId: sessionId, revision: before, afterLine: nil))
        view.consumeProcessOutput(Array(" second".utf8)[...])
        XCTAssertNil(bridge.screen(sessionId: sessionId, revision: before, afterLine: nil))
        let after = try XCTUnwrap(bridge.screenRevision(sessionId: sessionId))
        XCTAssertNotEqual(before, after)
        let screen = try XCTUnwrap(bridge.screen(sessionId: sessionId, revision: after, afterLine: nil))
        XCTAssertTrue(screen.lines.contains("first second"))
        view.resize(cols: 50, rows: 8)
        XCTAssertNil(bridge.screen(sessionId: sessionId, revision: after, afterLine: nil))
        XCTAssertEqual(bridge.cachedScreenCount, 1)
        XCTAssertEqual(model.closeRemoteSession(sessionId: sessionId), .closed)
        XCTAssertNil(bridge.screen(sessionId: sessionId, revision: after, afterLine: nil))
        XCTAssertEqual(bridge.cachedScreenCount, 0)
        await model.detachAllClientsAndDrain()
    }
}
