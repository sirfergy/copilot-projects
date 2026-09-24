import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost
@testable import SwiftTerm

final class SwiftTermEmbeddingTests: XCTestCase {
    @MainActor
    private final class ProcessDelegate: LocalProcessTerminalViewDelegate {
        var exited = false
        func processTerminated(source: TerminalView, exitCode: Int32?) {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(exitCode, 0)
            exited = true
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
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
        view.startProcess(
            executable: "/bin/sh",
            args: [
                "-c",
                "stty raw -echo; printf READY; exec /bin/cat >/dev/null",
            ],
            environment: []
        )
        defer {
            view.terminate()
            window.contentView = nil
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
        view.feed(text: "selected")
        view.selectAll()
        XCTAssertTrue(view.selectionActive)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)
        XCTAssertTrue(view.sendRestoredModifiedReturnIfNeeded(
            for: event,
            agentLive: true,
            agentActivity: .idle
        ))
        XCTAssertEqual(view.process.sendCount, sends + 1)
        XCTAssertFalse(view.selectionActive)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.keyboardEnhancementFlags.isEmpty == true)
    }

    @MainActor
    func testRestoredModifiedReturnLeavesOtherInputUnchanged() throws {
        let (view, window) = focusedInputTerminal()
        defer { window.contentView = nil }

        let rejected: [(NSEvent, Bool, FooterActivity)] = [
            (try keyEvent(in: view, modifiers: []), true, .idle),
            (try keyEvent(in: view, characters: "w", modifiers: .command, keyCode: 13), true, .idle),
            (try keyEvent(in: view, modifiers: .command), false, .idle),
            (try keyEvent(in: view, modifiers: .command), true, .unknown),
        ]
        for (event, agentLive, activity) in rejected {
            XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
                for: event,
                agentLive: agentLive,
                agentActivity: activity
            ))
        }
        view.feed(text: "\u{1b}[=10;1u")
        XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
            for: try keyEvent(in: view, modifiers: .command),
            agentLive: true,
            agentActivity: .idle
        ))
        XCTAssertEqual(
            view.terminalInputStateSnapshot()?.keyboardEnhancementFlags,
            [.reportEvents, .reportAllKeys]
        )
        view.feed(text: "\u{1b}[=0;1u")
        _ = window.makeFirstResponder(nil)
        XCTAssertFalse(view.sendRestoredModifiedReturnIfNeeded(
            for: try keyEvent(in: view, modifiers: .command),
            agentLive: true,
            agentActivity: .idle
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
