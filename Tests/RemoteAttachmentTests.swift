import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol

final class RemoteAttachmentTests: XCTestCase {
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32
        ))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testImmutableUploadSurvivesRestartAndIsBoundToConversation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let id = UUID().uuidString.lowercased(), session = UUID().uuidString
        let bytes = try image()
        let now = Date()
        let metadata = try store.store(bytes, id: id, sessionId: session, conversationEpoch: "first", now: now)
        XCTAssertEqual(try store.store(bytes, id: id, sessionId: session, conversationEpoch: "first"), metadata)
        let reopened = RemoteAttachmentStore(sessionsDirectory: root)
        XCTAssertEqual(try reopened.image(id: id, sessionId: session, conversationEpoch: "first").1, bytes)
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: session, conversationEpoch: "second"))
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: UUID().uuidString, conversationEpoch: "first"))
        XCTAssertThrowsError(try reopened.image(id: "../anything", sessionId: session, conversationEpoch: "first"))
        XCTAssertThrowsError(try reopened.image(
            id: id, sessionId: session, conversationEpoch: "first",
            now: now.addingTimeInterval(RemoteAttachmentContract.lifetime + 1)
        ))
        let file = store.root.appendingPathComponent("\(id).image")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        try Data("changed".utf8).write(to: file)
        XCTAssertThrowsError(try reopened.image(id: id, sessionId: session, conversationEpoch: "first"))
    }

    func testRejectsNonImagesOversizeAndSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let session = UUID().uuidString
        for bytes in [Data("<svg/>".utf8), Data(repeating: 0, count: RemoteAttachmentContract.maxBytes + 1)] {
            XCTAssertThrowsError(try store.store(bytes, id: UUID().uuidString.lowercased(),
                                                 sessionId: session, conversationEpoch: "epoch"))
        }
        let id = UUID().uuidString.lowercased()
        _ = try store.store(image(), id: id, sessionId: session, conversationEpoch: "epoch")
        let file = store.root.appendingPathComponent("\(id).image")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("secret"))
        XCTAssertThrowsError(try store.image(id: id, sessionId: session, conversationEpoch: "epoch"))
    }

    func testAttachmentSchemaAndLimitsFailClosedWithoutBreakingText() {
        let id = UUID().uuidString.lowercased()
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "text", mode: .enqueue).isValid)
        XCTAssertTrue(RemoteSessionAction(kind: .send, prompt: "image", mode: .enqueue, attachmentIds: [id]).isValid)
        for ids in [[], ["../file"], [id, id], Array(repeating: id, count: 5)] {
            XCTAssertFalse(RemoteSessionAction(kind: .send, prompt: "image", mode: .enqueue, attachmentIds: ids).isValid)
        }
        XCTAssertFalse(RemoteSessionAction(kind: .abort, attachmentIds: [id]).isValid)
        let image = RemoteAttachment(id: id, sessionId: UUID().uuidString, conversationEpoch: "epoch",
            mimeType: "image/png", byteCount: 1000,
            expiresAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000) + 60000)
        XCTAssertTrue(RemoteImageCapabilities(maxImages: 1, maxBytes: 1000, mimeTypes: ["image/png"]).accepts([image]))
        XCTAssertFalse(RemoteImageCapabilities(maxImages: 1, maxBytes: 999, mimeTypes: ["image/png"]).accepts([image]))
        XCTAssertFalse(RemoteImageCapabilities(maxImages: 1, maxBytes: 1000, mimeTypes: ["image/jpeg"]).accepts([image]))
    }

    func testCorruptMetadataIsReclaimedAndModelRefusalDoesNotStoreBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let session = UUID().uuidString, corruptID = UUID().uuidString.lowercased()
        let image = try image()
        _ = try store.store(image, id: corruptID, sessionId: session, conversationEpoch: "epoch")
        try Data("corrupt".utf8).write(to: store.root.appendingPathComponent("\(corruptID).json"))
        let goodID = UUID().uuidString.lowercased()
        _ = try store.store(image, id: goodID, sessionId: session, conversationEpoch: "epoch")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(corruptID).image").path))
        XCTAssertEqual(try store.image(id: goodID, sessionId: session, conversationEpoch: "epoch").1, image)
        let refusedID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try store.store(image, id: refusedID, sessionId: session, conversationEpoch: "epoch",
            limits: RemoteImageCapabilities(maxImages: 1, maxBytes: 1, mimeTypes: ["image/png"])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.appendingPathComponent("\(refusedID).image").path))
    }
}
