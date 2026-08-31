import AppKit
import SwiftTerm
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import copilot_projects

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
    func testFinalFallbackKeepsActualCoreGraphicsAfterReveal() throws {
        let view = makeRendererView(preference: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer {
            view.setRendererActive(false)
            window.contentView = nil
        }
        view.setRendererActive(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        try view.setUseMetal(false)
        view.metalRendererFallbackHandler?(.deviceUnavailable)
        try view.setUseMetal(true)
        view.setRendererActive(true)
        view.forceRedraw()
        XCTAssertEqual(view.rendererName, "coregraphics-fallback")
        XCTAssertFalse(view.isUsingMetalRenderer)
    }

    @MainActor
    func testTransientCapacityRefusalRetriesLaterWithoutLatchingFallback() throws {
        let view = makeRendererView(preference: nil)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer {
            view.setRendererActive(false)
            window.contentView = nil
        }
        view.setRendererActive(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        try view.setUseMetal(false)
        view.handleMetalActivationFailure(MetalError.inFlightLimitReached)
        XCTAssertFalse(view.isUsingMetalRenderer)
        XCTAssertEqual(view.rendererName, "coregraphics-pending-metal")
        // The next ordinary reconciliation retries even though the warm flag
        // is unchanged. The failure handler itself must not retry immediately.
        view.setRendererActive(true)
        XCTAssertTrue(view.isUsingMetalRenderer)
        XCTAssertEqual(view.rendererName, "metal")
        // The final automatic-fallback callback has a different contract,
        // even if it reports the same error after a genuine terminal failure.
        try view.setUseMetal(false)
        view.metalRendererFallbackHandler?(.inFlightLimitReached)
        view.setRendererActive(true)
        XCTAssertFalse(view.isUsingMetalRenderer)
        XCTAssertEqual(view.rendererName, "coregraphics-fallback")
    }

    @MainActor
    func testDeferredRevealRetriesCapacityUnlessParkedOrFinallyFallenBack() async throws {
        for cancellation in ["none", "park", "fallback"] {
            let view = makeRendererView(preference: nil)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            defer {
                view.setRendererActive(false)
                window.contentView = nil
            }
            view.setRendererActive(true)
            XCTAssertTrue(view.isUsingMetalRenderer)
            view.refreshSurface()
            // Inject the same post-refusal state before the queued reveal
            // pass, without saturating the GPU or exposing library budgets.
            try view.setUseMetal(false)
            view.handleMetalActivationFailure(MetalError.inFlightLimitReached)
            XCTAssertFalse(view.isUsingMetalRenderer)
            XCTAssertEqual(view.rendererName, "coregraphics-pending-metal")
            switch cancellation {
            case "park": view.setRendererActive(false)
            case "fallback": view.metalRendererFallbackHandler?(.commandTimedOut)
            default: break
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            // No external activation/reconciliation occurs between the
            // refusal and this assertion. Only the deferred pass can retry.
            XCTAssertEqual(view.isUsingMetalRenderer, cancellation == "none", cancellation)
            let expectedName = cancellation == "none" ? "metal"
                : cancellation == "park" ? "parked" : "coregraphics-fallback"
            XCTAssertEqual(view.rendererName, expectedName, cancellation)
        }
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
    func testStaleRevisionCannotReturnAnAlreadyCachedScreen() throws {
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
    }
}
