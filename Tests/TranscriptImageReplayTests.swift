import Foundation
import XCTest
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class TranscriptImageReplayTests: XCTestCase {
    private final class Clock {
        var value = Date(timeIntervalSince1970: 100)
    }

    private func capture(_ clock: Clock) -> RemoteKittyImageCapture {
        RemoteKittyImageCapture(epoch: 0, budget: RemoteKittyImageCaptureBudget(), now: { clock.value })
    }

    private func transmit(_ capture: RemoteKittyImageCapture, png: Data, action: String = "T") {
        capture.ingest(remoteKittyFrameBytes(
            control: "a=\(action),f=100,t=d,U=1,i=42", base64Payload: png.base64EncodedString()
        )[...])
    }

    private func turn(_ id: String, start: TimeInterval) -> TranscriptTurn {
        TranscriptTurn(
            id: id, startedAt: Date(timeIntervalSince1970: start), endedAt: nil,
            kind: "foreground", userContent: id, assistantMessages: [], tools: [], isAborted: false
        )
    }

    private func snapshot(_ turns: [TranscriptTurn], totalTurns: Int? = nil) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Date(timeIntervalSince1970: 300),
            copilotSessionId: "fixture", turns: turns, totalTurns: totalTurns
        )
    }

    func testIdenticalRedrawKeepsOriginalTurnWithNewestFetchVersion() throws {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        let initial = TranscriptImageAssociation.attach(
            images: capture.retainedImageMetadata(), to: snapshot([turn("original", start: 90)])
        )
        XCTAssertEqual(initial.turns[0].images?.first?.contentVersion, 1)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("original", start: 90), turn("later", start: 200)]))
        let image = try XCTUnwrap(result.turns[0].images?.first)
        XCTAssertEqual(image.contentVersion, 2)
        XCTAssertEqual(capture.imageData(imageId: image.imageId, version: image.contentVersion), png)
        XCTAssertNil(result.turns[1].images)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
    }

    func testChangedBytesGetNewTurnInsteadOfBorrowingOldOrigin() {
        let clock = Clock(), capture = capture(clock)
        transmit(capture, png: remoteKittyTestPNGBytes(width: 2, height: 2))
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: remoteKittyTestPNGBytes(width: 3, height: 3))
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("original", start: 90), turn("later", start: 200)]))
        XCTAssertNil(result.turns[0].images)
        XCTAssertEqual(result.turns[1].images?.first?.contentVersion, 2)
    }

    func testPlacementResizeKeepsOriginWhileDataDeletionStartsFresh() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        clock.value = Date(timeIntervalSince1970: 250)
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=42")[...])
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=42,c=4,r=3")[...])
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, Date(timeIntervalSince1970: 100))
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=42")[...])
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }

    func testUndisplayedPreloadDoesNotBorrowEarlierTurn() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png, action: "t")
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }

    func testRedrawDoesNotMoveImageIntoNewerTranscriptWindow() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        transmit(capture, png: png)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        let result = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(),
            to: snapshot([turn("later", start: 200)], totalTurns: 2))
        XCTAssertNil(result.turns[0].images, "The image belongs to a turn outside this window")
        XCTAssertEqual(result.totalTurns, 2)
    }

    func testRestoreWithoutOriginDoesNotInventHistoricalAssociation() {
        let clock = Clock(), capture = capture(clock)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let restoredVersion = UInt64(1) << 32
        capture.beginRestoring()
        XCTAssertTrue(capture.restoreEntry(imageId: 42, version: restoredVersion, data: png))
        XCTAssertTrue(capture.restoreCurrentSelection(imageId: 42, version: restoredVersion, placementId: nil))
        capture.finishRestoring()
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        clock.value = Date(timeIntervalSince1970: 250)
        transmit(capture, png: png)
        XCTAssertEqual(capture.retainedImageMetadata().first?.displayedAt, clock.value)
    }
}
