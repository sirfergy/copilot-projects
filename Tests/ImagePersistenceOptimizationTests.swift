import Foundation
import XCTest
@testable import copilot_projects

final class ImagePersistenceOptimizationTests: XCTestCase {
    @MainActor
    func testMultiImagePlacementClearPersistsManifestOnce() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "batch-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=2,c=3,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()
        let before = await store.manifestPersistCountForTesting()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        let after = await store.manifestPersistCountForTesting()

        XCTAssertEqual(after - before, 1)
        XCTAssertEqual(capture.imageData(imageId: 1, version: 1), png)
        XCTAssertEqual(capture.imageData(imageId: 2, version: 2), png)

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [1, 2])
        XCTAssertTrue(restored.currentSelections.isEmpty)
    }

    @MainActor
    func testSelectivePlacementDeletionPreservesSiblingAndOtherImageSelections() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "selective-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=10,p=1,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=p,U=1,i=10,p=2,c=2,r=1"
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=20,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=10,p=1")[...])
        await store.flush()

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [10, 20])
        XCTAssertEqual(restored.currentSelections.count, 2)
        XCTAssertTrue(restored.currentSelections.contains {
            $0.imageId == 10 && $0.placementId == 2
        })
        XCTAssertTrue(restored.currentSelections.contains {
            $0.imageId == 20 && $0.placementId == nil
        })
        XCTAssertFalse(restored.currentSelections.contains {
            $0.imageId == 10 && $0.placementId == 1
        })
    }

    @MainActor
    func testBatchClearRemainsFIFOWithLaterRetain() async {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "ordered-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        for imageId: UInt32 in 1 ... 2 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId),c=1,r=1",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        await store.flush()

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=3,c=1,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.imageId)), [1, 2, 3])
        XCTAssertEqual(restored.currentSelections.map(\.imageId), [3])
    }

    @MainActor
    func testBatchClearPersistenceFailureFailClosesQueuedLaterRetain() async throws {
        let root = imagePersistenceTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "failed-clear"
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = imagePersistenceCapture(sessionId: sessionId, store: store)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        for imageId: UInt32 in 1 ... 2 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId),c=1,r=1",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        await store.flush()

        let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=3,c=1,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        XCTAssertTrue(store.isPersistenceDisabledForTesting(sessionId: sessionId))
        XCTAssertTrue(store.isTombstonedForTesting(sessionId: sessionId))
        let entryCount = await store.totalEntryCountForTesting()
        let reopened = RemoteKittyImageDiskStore(root: root)
        let restored = await reopened.restore(sessionId: sessionId)
        XCTAssertEqual(entryCount, 0)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.currentSelections.isEmpty)
    }
}

@MainActor
private func imagePersistenceCapture(
    sessionId: String,
    store: RemoteKittyImageDiskStore
) -> RemoteKittyImageCapture {
    RemoteKittyImageCapture(
        sessionId: sessionId,
        epoch: 0,
        budget: RemoteKittyImageCaptureBudget(),
        diskStore: store
    )
}

private func imagePersistenceTestRoot() -> URL {
    URL(fileURLWithPath: #filePath, isDirectory: false)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(".build", isDirectory: true)
        .appendingPathComponent("image-persistence-\(UUID().uuidString)", isDirectory: true)
}
