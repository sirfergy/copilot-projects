import Combine
import XCTest
@testable import CopilotProjectsHost

@MainActor
final class NativeTranscriptImageTests: XCTestCase {
    private func transmit(_ capture: RemoteKittyImageCapture, data: Data) {
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=42,q=2", base64Payload: data.base64EncodedString()
        )[...])
    }

    func testImageChangesPublishWithoutPublishingOrdinaryTerminalOutput() {
        let capture = RemoteKittyImageCapture(epoch: 1, budget: RemoteKittyImageCaptureBudget())
        var generations: [UInt64] = []
        let observer = capture.$imageAvailabilityGeneration.dropFirst().sink { generations.append($0) }
        defer { observer.cancel() }
        capture.ingest(Array("ordinary terminal output".utf8)[...])
        XCTAssertTrue(generations.isEmpty)

        transmit(capture, data: remoteKittyTestPNGBytes(width: 4, height: 2))
        XCTAssertFalse(generations.isEmpty)
        XCTAssertEqual(generations.last, capture.imageAvailabilityGeneration)
        XCTAssertEqual(capture.retainedImageMetadata().count, 1)
        let firstCount = generations.count

        transmit(capture, data: remoteKittyTestPNGBytes(width: 6, height: 2))
        XCTAssertGreaterThan(generations.count, firstCount)
        let replacementCount = generations.count
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=42,q=2")[...])
        XCTAssertGreaterThan(generations.count, replacementCount)
        XCTAssertTrue(capture.retainedImageMetadata().isEmpty)
        XCTAssertEqual(generations.last, capture.imageAvailabilityGeneration)
    }

    func testCrossSessionEvictionPublishesToTheAffectedCapture() {
        let budget = RemoteKittyImageCaptureBudget(maxTotalEntries: 1)
        let first = RemoteKittyImageCapture(epoch: 1, budget: budget)
        let second = RemoteKittyImageCapture(epoch: 2, budget: budget)
        transmit(first, data: remoteKittyTestPNGBytes(width: 4, height: 2))
        var generations: [UInt64] = []
        let observer = first.$imageAvailabilityGeneration.dropFirst().sink { generations.append($0) }
        defer { observer.cancel() }

        transmit(second, data: remoteKittyTestPNGBytes(width: 4, height: 2))
        XCTAssertTrue(first.retainedImageMetadata().isEmpty)
        XCTAssertFalse(generations.isEmpty)
        XCTAssertEqual(generations.last, first.imageAvailabilityGeneration)
        XCTAssertEqual(second.retainedImageMetadata().count, 1)
    }

    func testThumbnailAndPreviewAreBoundedAndKeepAspectRatio() async throws {
        let data = remoteKittyTestPNGBytes(width: 1_200, height: 600)
        XCTAssertEqual(RemoteKittyPNGValidation.pixelSize(data), CGSize(width: 1_200, height: 600))
        let thumbnail = try await TranscriptImageDecoder.shared.decode(
            data, maximumDimension: TranscriptImageDecoder.thumbnailDimension
        )
        XCTAssertEqual(thumbnail.width, 768)
        XCTAssertEqual(thumbnail.height, 384)
        let preview = try await TranscriptImageDecoder.shared.decode(
            data, maximumDimension: TranscriptImageDecoder.previewDimension
        )
        XCTAssertLessThanOrEqual(preview.width, TranscriptImageDecoder.previewDimension)
        XCTAssertEqual(preview.width, preview.height * 2)
        XCTAssertGreaterThan(preview.width, thumbnail.width)
    }

    func testInvalidImagesAndDecodeSizesFailExplicitly() async {
        let valid = remoteKittyTestPNGBytes(width: 4, height: 2)
        let oversized = remoteKittyTestPNGBytes(width: 4_097, height: 1)
        XCTAssertNil(RemoteKittyPNGValidation.pixelSize(oversized))
        for (data, maximum) in [(Data([0, 1, 2]), 768), (oversized, 768), (valid, 0), (valid, 2_049)] {
            do {
                _ = try await TranscriptImageDecoder.shared.decode(data, maximumDimension: maximum)
                XCTFail("Invalid image or decode bound was accepted")
            } catch is TranscriptImageError {
                // Expected typed decoding failure.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancelledDecodeDoesNotProduceAnImage() async {
        let data = remoteKittyTestPNGBytes(width: 4, height: 2)
        let task = Task {
            try await TranscriptImageDecoder.shared.decode(data, maximumDimension: 768)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled decode returned pixels")
        } catch is CancellationError {
            // Expected cancellation, not an unavailable-image failure.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testImageTaskIdentityIncludesSessionAndExactVersion() {
        let first = TranscriptImageIdentity(sessionId: "first", imageId: 42, version: UInt64.max - 1)
        let newer = TranscriptImageIdentity(sessionId: "first", imageId: 42, version: UInt64.max)
        let other = TranscriptImageIdentity(sessionId: "second", imageId: 42, version: UInt64.max - 1)
        XCTAssertEqual(Set([first, newer, other]).count, 3)
    }
}
