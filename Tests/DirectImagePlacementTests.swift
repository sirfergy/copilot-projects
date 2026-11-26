import Foundation
import XCTest
import SwiftTerm
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

/// Inline images drawn with direct Kitty placements: no `U=1` and no
/// placeholder cells. The frames are the ones Copilot CLI 1.0.116 writes for a
/// terminal that identifies as Ghostty.
@MainActor
final class DirectImagePlacementTests: XCTestCase {
    private final class Clock {
        var value = Date(timeIntervalSince1970: 100)
    }

    /// Stands in for the terminal: records every feed and reports a cursor.
    private final class Terminal {
        var fed: [ArraySlice<UInt8>] = []
        var cursor = RemoteKittyDirectAnchor(row: 0, column: 0, isAlternateBuffer: true)
    }

    private let png = remoteKittyTestPNGBytes(width: 2, height: 2)
    private let clock = Clock()
    private let terminal = Terminal()

    private func makeCapture() -> RemoteKittyImageCapture {
        RemoteKittyImageCapture(epoch: 0, budget: RemoteKittyImageCaptureBudget(), now: { [clock] in clock.value })
    }

    private func upload(_ id: Int, chunk: Int = 4_096) -> [UInt8] {
        let base64 = Array(png.base64EncodedString().utf8)
        var bytes: [UInt8] = []
        var offset = 0
        while offset < base64.count {
            let end = min(offset + chunk, base64.count)
            let more = end < base64.count ? 1 : 0
            bytes += remoteKittyFrameBytes(
                control: offset == 0 ? "a=t,f=100,i=\(id),q=2,m=\(more)" : "q=2,m=\(more)",
                base64Payload: String(decoding: base64[offset ..< end], as: UTF8.self)
            )
            offset = end
        }
        return bytes
    }

    private func draw(_ id: Int, placement: Int, rows: Int = 2, columns: Int = 6) -> [UInt8] {
        remoteKittyFrameBytes(
            control: "a=p,i=\(id),p=\(placement),x=0,y=0,w=2,h=2,c=\(columns),r=\(rows),C=1,q=2"
        )
    }

    private func erase(_ id: Int, placement: Int) -> [UInt8] {
        remoteKittyFrameBytes(control: "a=d,d=i,i=\(id),p=\(placement),q=2")
    }

    private func free(_ id: Int) -> [UInt8] {
        remoteKittyFrameBytes(control: "a=d,d=I,i=\(id),q=2")
    }

    private func placeholderImage(_ id: Int) -> [UInt8] {
        remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(id),c=2,r=1", base64Payload: png.base64EncodedString()
        )
    }

    private func send(_ bytes: [UInt8], to capture: RemoteKittyImageCapture) {
        capture.ingest(bytes[...], feedingTerminal: { terminal.fed.append($0) }, cursor: { terminal.cursor })
    }

    private func placements(
        _ capture: RemoteKittyImageCapture, alternate: Bool = true
    ) -> [RemoteTerminalImagePlacement] {
        capture.directPlacements(isAlternateBuffer: alternate, rows: 0 ..< 100, relativeTo: 0)
    }

    private func placement(
        _ imageId: UInt32, _ version: UInt64, line: Int, column: Int, rows: Int = 2, columns: Int = 6
    ) -> RemoteTerminalImagePlacement {
        RemoteTerminalImagePlacement(
            imageId: imageId, contentVersion: version, line: line, column: column, rows: rows, columns: columns
        )
    }

    // MARK: Capture

    func testUploadThenDrawListsTheImageAndPlacesItAtTheCursor() {
        let capture = makeCapture()
        send(upload(7, chunk: 16), to: capture)
        XCTAssertEqual(capture.imageData(imageId: 7, version: 1), png)
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        let generation = capture.imageAvailabilityGeneration

        terminal.cursor = RemoteKittyDirectAnchor(row: 5, column: 2, isAlternateBuffer: true)
        send(draw(7, placement: 2, rows: 3, columns: 4), to: capture)

        XCTAssertEqual(placements(capture), [placement(7, 1, line: 5, column: 2, rows: 3, columns: 4)])
        XCTAssertEqual(
            capture.directPlacements(isAlternateBuffer: true, rows: 7 ..< 9, relativeTo: 3).map(\.line), [2]
        )
        XCTAssertTrue(placements(capture, alternate: false).isEmpty)
        XCTAssertTrue(capture.directPlacements(isAlternateBuffer: true, rows: 8 ..< 20, relativeTo: 0).isEmpty)
        XCTAssertEqual(capture.retainedImageMetadata().map(\.imageId), [7])
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
        XCTAssertEqual(capture.imageAvailabilityGeneration, generation &+ 1)
    }

    func testRedrawMovesThePlacementWithoutChangingAvailability() {
        let capture = makeCapture()
        send(upload(7) + draw(7, placement: 2), to: capture)
        let shownAt = clock.value
        let generation = capture.imageAvailabilityGeneration

        clock.value += 60
        terminal.cursor = RemoteKittyDirectAnchor(row: 9, column: 1, isAlternateBuffer: true)
        send(erase(7, placement: 2) + draw(7, placement: 3), to: capture)

        XCTAssertEqual(placements(capture), [placement(7, 1, line: 9, column: 1)])
        XCTAssertEqual(capture.imageAvailabilityGeneration, generation)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, shownAt)
    }

    func testFreeingADirectImageKeepsItListedAndAPlaceholderImageIsStillFreed() {
        let capture = makeCapture()
        send(upload(7) + draw(7, placement: 2) + placeholderImage(9), to: capture)
        let shownAt = clock.value
        XCTAssertEqual(capture.currentVersion(for: 9), 2)

        send(erase(7, placement: 2) + free(7) + free(9), to: capture)
        XCTAssertTrue(placements(capture).isEmpty)
        XCTAssertEqual(capture.retainedImageMetadata().map(\.imageId), [7])
        XCTAssertEqual(capture.imageData(imageId: 7, version: 1), png)
        XCTAssertNil(capture.imageData(imageId: 9, version: 2))

        // The image scrolls back into the CLI's view: the same bytes, a new version, the first display time.
        clock.value += 60
        send(upload(7) + draw(7, placement: 3), to: capture)
        XCTAssertEqual(placements(capture), [placement(7, 3, line: 0, column: 0)])
        XCTAssertEqual(capture.retainedImageMetadata().map(\.version), [3])
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, shownAt)
    }

    func testRetentionBoundEvictsTheOldestFreedDirectImageAndStillShowsTheNewOne() {
        let capture = makeCapture()
        send(upload(1) + draw(1, placement: 2), to: capture) // stays on screen
        // Sixteen more, each drawn and then freed: one entry past the per-session cap.
        for id in 2 ... 17 {
            send(upload(id) + draw(id, placement: 2) + erase(id, placement: 2) + free(id), to: capture)
        }

        XCTAssertNil(capture.imageData(imageId: 2, version: 2))
        XCTAssertEqual(capture.retainedImageMetadata().map(\.imageId), [1] + Array(3 ... 17))
        XCTAssertEqual(placements(capture).map(\.imageId), [1])
    }

    func testDrawsOutsideTheSubsetAreIgnoredAndNeverSplitTheFeed() {
        let capture = makeCapture()
        send(draw(7, placement: 2), to: capture) // nothing uploaded
        send(upload(7), to: capture)
        send(remoteKittyFrameBytes(control: "a=p,i=7,x=0,y=0,w=2,h=2,c=6,r=2,C=1,q=2"), to: capture) // no p
        send(remoteKittyFrameBytes(control: "a=p,i=7,p=2,C=1,q=2"), to: capture) // no c, r
        send(remoteKittyFrameBytes(
            control: "a=T,f=100,i=8,c=2,r=1,q=2", base64Payload: png.base64EncodedString()
        ), to: capture) // transmit and display without U=1
        send(draw(8, placement: 2), to: capture)

        XCTAssertTrue(placements(capture).isEmpty)
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        XCTAssertNil(capture.imageData(imageId: 8, version: 2))
        XCTAssertEqual(terminal.fed.count, 6)
    }

    // MARK: Feeding the terminal

    func testChunkWithoutADirectPlacementIsFedWholeInOneCallWithoutACopy() {
        let capture = makeCapture()
        let chunk = Array("plain \u{1B}[31mtext\u{1B}]0;title\u{07}".utf8)
            + upload(7, chunk: 16) + placeholderImage(9) + erase(7, placement: 4) + free(3)
            + draw(5, placement: 2) // an image that was never uploaded
        let slice = chunk[3...]

        capture.ingest(slice, feedingTerminal: { terminal.fed.append($0) }, cursor: {
            XCTFail("the cursor is read only for a direct placement")
            return nil
        })

        XCTAssertEqual(terminal.fed.count, 1)
        XCTAssertEqual(terminal.fed.first?.indices, slice.indices)
        XCTAssertEqual(terminal.fed.first.map { Array($0) }, Array(slice))
        let original = slice.withUnsafeBufferPointer { $0.baseAddress }
        XCTAssertEqual(terminal.fed.first?.withUnsafeBufferPointer { $0.baseAddress }, original)
    }

    func testChunkIsSplitBeforeTheByteThatEndsEachDirectPlacement() {
        let capture = makeCapture()
        send(upload(7), to: capture)
        terminal.fed.removeAll()
        let first = draw(7, placement: 2), second = draw(7, placement: 3)

        send(Array("ab".utf8) + first + Array("cd".utf8) + second + Array("ef".utf8), to: capture)
        XCTAssertEqual(terminal.fed.map { Array($0) }, [
            Array("ab".utf8) + first.dropLast(),
            [0x5C] + Array("cd".utf8) + second.dropLast(),
            [0x5C] + Array("ef".utf8),
        ])

        // The command ends in the next chunk: nothing of that chunk precedes its last byte.
        terminal.fed.removeAll()
        let third = draw(7, placement: 4)
        send(Array(third.dropLast()), to: capture)
        send([0x5C, 0x7A], to: capture)
        XCTAssertEqual(terminal.fed.map { Array($0) }, [Array(third.dropLast()), [], [0x5C, 0x7A]])
        XCTAssertEqual(placements(capture).count, 3)
    }

    // MARK: Disk

    func testOnlyTheFirstDrawOfAnImageWritesToDisk() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("direct-image-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = RemoteKittyImageCapture(
            sessionId: "direct", epoch: 0, budget: RemoteKittyImageCaptureBudget(), diskStore: store
        )
        send(upload(7) + draw(7, placement: 2, rows: 3, columns: 4), to: capture)
        await store.flush()
        let written = await store.manifestPersistCountForTesting()

        for next in 3 ... 6 {
            send(erase(7, placement: next - 1) + draw(7, placement: next, rows: 3, columns: 4), to: capture)
        }
        send(erase(7, placement: 6) + free(7), to: capture)
        await store.flush()
        let afterRedraws = await store.manifestPersistCountForTesting()
        XCTAssertEqual(afterRedraws, written)

        let restored = await RemoteKittyImageDiskStore(root: root).restore(sessionId: "direct")
        XCTAssertEqual(restored.entries.map(\.imageId), [7])
        XCTAssertEqual(restored.currentSelections, [RemoteKittyRestoredSelection(
            imageId: 7, version: 1, placementId: nil, rows: 3, columns: 4, x: nil, y: nil, z: nil
        )])
    }

    // MARK: Scanner

    func testScannerOrdersDirectPlacementsWithPlaceholderCells() {
        let cells = (0 ..< 3).map { RemoteKittyGridCell(lineId: 6, col: $0, imageId: 1) }
        let direct = [placement(2, 22, line: 5, column: 4)]
        let scanned = RemoteKittyPlacementScanner.scan(
            cells: cells, direct: direct, firstLine: 5, priorityLineRange: 0 ..< 10,
            currentVersion: { imageId, _ in imageId == 1 ? 11 : nil }
        )
        XCTAssertEqual(scanned, [
            placement(2, 22, line: 0, column: 4),
            placement(1, 11, line: 1, column: 0, rows: 1, columns: 3),
        ])
    }

    func testScannerCapCountsDirectPlacementsInTheirTier() {
        // Sixty-four placeholder images and one direct placement in the window: one more than the cap.
        let cells = (0 ..< 64).map { RemoteKittyGridCell(lineId: $0 * 2, col: 0, imageId: UInt32($0 + 1)) }
        let inside = placement(901, 9, line: 1, column: 0, rows: 1, columns: 1)
        let outside = placement(900, 9, line: 500, column: 0, rows: 1, columns: 1)
        let scanned = RemoteKittyPlacementScanner.scan(
            cells: cells, direct: [outside, inside], firstLine: 0, priorityLineRange: 0 ..< 200,
            currentVersion: { _, _ in 1 }
        )
        XCTAssertEqual(scanned.count, 64)
        XCTAssertTrue(scanned.contains(inside))
        XCTAssertFalse(scanned.contains(outside))
        XCTAssertFalse(scanned.contains { $0.imageId == 64 })
    }

    // MARK: Terminal view

    func testViewPlacesDirectImagesAtTheCursorInBothBuffers() throws {
        let view = ProjectsTerminalView(frame: .zero, options: TerminalOptions(cols: 20, rows: 8, scrollback: 50))

        // Normal buffer, after the screen has scrolled, with output after the draw.
        let scrolled = (1 ... 12).map { "line \($0)\r\n" }.joined() + "\u{1B}[4;3H"
        view.consumeProcessOutput(
            (upload(7) + Array(scrolled.utf8) + draw(7, placement: 2) + Array("after".utf8))[...]
        )
        let capture = view.kittyImageCapture
        let version7 = try XCTUnwrap(capture.currentVersion(for: 7))
        let history = try XCTUnwrap(view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 500)))
        XCTAssertGreaterThan(history.liveTopRow, 0)
        XCTAssertEqual(
            capture.directPlacements(isAlternateBuffer: false, rows: history.capturedRange, relativeTo: 0),
            [placement(7, version7, line: history.liveTopRow + 3, column: 2)]
        )
        XCTAssertTrue(history.rows[history.liveTopRow + 3 - history.capturedRange.lowerBound].text.contains("after"))

        // Alternate buffer: two images uploaded there, drawn with output between them, the second
        // draw ending in the next chunk.
        let chunk = Array("\u{1B}[?1049h".utf8) + upload(8) + upload(9)
            + Array("\u{1B}[3;5H".utf8) + draw(8, placement: 3)
            + Array("\u{1B}[1;1Hhello\u{1B}[6;2H".utf8) + draw(9, placement: 4, rows: 1, columns: 4)
        view.consumeProcessOutput(chunk.dropLast())
        view.consumeProcessOutput(([0x5C] + Array("\u{1B}[8;1Hbye".utf8))[...])
        let version8 = try XCTUnwrap(capture.currentVersion(for: 8))
        let version9 = try XCTUnwrap(capture.currentVersion(for: 9))
        let viewport = try XCTUnwrap(view.terminalContentSnapshot(region: .viewport))
        XCTAssertEqual(viewport.bufferKind, .alt)
        let placed = capture.directPlacements(
            isAlternateBuffer: true, rows: viewport.capturedRange, relativeTo: viewport.capturedRange.lowerBound
        ).sorted { $0.line < $1.line }
        XCTAssertEqual(placed, [
            placement(8, version8, line: 2, column: 4),
            placement(9, version9, line: 5, column: 1, rows: 1, columns: 4),
        ])
        XCTAssertTrue(viewport.rows[0].text.hasPrefix("hello"))
        XCTAssertTrue(viewport.rows[7].text.hasPrefix("bye"))
    }

    func testRemoteScreenCarriesADirectPlacementUntilTheCLIDeletesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            )
        )
        let view = try XCTUnwrap(model.controller(for: sessionId)).terminalView

        view.consumeProcessOutput(
            (Array("\u{1B}[?1049h".utf8) + upload(7) + Array("\u{1B}[3;5H".utf8) + draw(7, placement: 2))[...]
        )
        let version = try XCTUnwrap(view.kittyImageCapture.currentVersion(for: 7))
        let screen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(screen.scrollMode, .terminal)
        XCTAssertEqual(screen.images, [placement(7, version, line: 2, column: 4)])

        view.consumeProcessOutput((erase(7, placement: 2) + free(7))[...])
        XCTAssertEqual(try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil)).images, [])
        XCTAssertEqual(view.kittyImageCapture.retainedImageMetadata().map(\.imageId), [7])
    }
}
