import AppKit
import Combine
import ImageIO
import SwiftUI
import XCTest
@testable import CopilotProjectsCore
@testable import CopilotProjectsHost
@testable import CopilotProjectsProtocol

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

        let jpeg = try Self.makeSolidJPEG(width: 1_200, height: 600, color: .systemBlue, orientation: 6)
        XCTAssertNil(RemoteKittyPNGValidation.pixelSize(jpeg))
        XCTAssertEqual(TranscriptPromptAttachments.pixelSize(jpeg), CGSize(width: 600, height: 1_200))
        let jpegThumb = try await TranscriptImageDecoder.shared.decode(
            jpeg, maximumDimension: TranscriptImageDecoder.thumbnailDimension
        )
        XCTAssertEqual(jpegThumb.width, 384)
        XCTAssertEqual(jpegThumb.height, 768)

        let wideJPEG = try Self.makeSolidJPEG(width: 6_000, height: 100, color: .systemGreen)
        XCTAssertEqual(TranscriptPromptAttachments.pixelSize(wideJPEG), CGSize(width: 6_000, height: 100))
        let paddedJPEG = wideJPEG + Data([0x00, 0x00])
        XCTAssertEqual(TranscriptPromptAttachments.pixelSize(paddedJPEG), CGSize(width: 6_000, height: 100))
        let widePNG = remoteKittyTestPNGBytes(width: 5_120, height: 64)
        XCTAssertEqual(TranscriptPromptAttachments.pixelSize(widePNG), CGSize(width: 5_120, height: 64))
    }

    func testInvalidImagesAndDecodeSizesFailExplicitly() async throws {
        let valid = remoteKittyTestPNGBytes(width: 4, height: 2)
        let oversizedKitty = remoteKittyTestPNGBytes(width: 4_097, height: 1)
        let oversizedAttachment = remoteKittyTestPNGBytes(width: 16_385, height: 1)
        let validJPEG = try Self.makeSolidJPEG(width: 16, height: 16, color: .systemRed)
        let truncatedJPEG = validJPEG.dropLast(2)
        let emptyJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
        XCTAssertNil(RemoteKittyPNGValidation.pixelSize(oversizedKitty))
        XCTAssertNil(TranscriptPromptAttachments.pixelSize(oversizedAttachment))
        XCTAssertNil(TranscriptPromptAttachments.pixelSize(Data(truncatedJPEG)))
        XCTAssertNil(TranscriptPromptAttachments.pixelSize(emptyJPEG))
        for (data, maximum) in [
            (Data([0, 1, 2]), 768),
            (oversizedAttachment, 768),
            (Data(truncatedJPEG), 768),
            (emptyJPEG, 768),
            (valid, 0),
            (valid, 2_049),
        ] {
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

    func testPromptAttachmentsLoadsPNGFilePathsAndMissingPlaceholdersWithTurnScopedIdentity() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = tempRoot
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let t1 = ISO8601DateFormatter().date(from: "2026-04-15T12:00:01Z")!
        let t2 = ISO8601DateFormatter().date(from: "2026-04-15T12:05:00Z")!
        let pngBytes = remoteKittyTestPNGBytes(width: 240, height: 120)
        let existingURL = tempRoot.appendingPathComponent("attached.png", isDirectory: false)
        try pngBytes.write(to: existingURL)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: existingURL.path)
        let missingURL = tempRoot.appendingPathComponent("missing.png", isDirectory: false)

        let events = [
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-04-15T12:00:01Z","data":{"content":"Check attached image","attachments":[{"type":"file","path":"\#(existingURL.path)","displayName":"attached.png","mimeType":"image/png","byteLength":128}]}}"#,
            #"{"type":"user.message","id":"turn-2","timestamp":"2026-04-15T12:05:00Z","data":{"content":"Check missing image","attachments":[{"type":"file","path":"\#(missingURL.path)","displayName":"missing.png"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try events.write(
            to: sessionDir.appendingPathComponent("events.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: t2.addingTimeInterval(10),
            copilotSessionId: copilotSessionId,
            turns: [
                TranscriptTurn(
                    id: "turn-1",
                    startedAt: t1,
                    endedAt: t1.addingTimeInterval(5),
                    kind: "foreground",
                    userContent: "Check attached image",
                    assistantMessages: [],
                    tools: [],
                    isAborted: false
                ),
                TranscriptTurn(
                    id: "turn-2",
                    startedAt: t2,
                    endedAt: t2.addingTimeInterval(5),
                    kind: "foreground",
                    userContent: "Check missing image",
                    assistantMessages: [],
                    tools: [],
                    isAborted: false
                ),
            ]
        )

        let appSessionId = "desktop-session-1"
        let loaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            copilotHome: tempRoot.path
        )
        let turn1Items = loaded.items(
            forTurnId: "turn-1",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(turn1Items.count, 1)
        XCTAssertEqual(turn1Items[0].identity.sessionId, appSessionId)
        XCTAssertGreaterThanOrEqual(turn1Items[0].identity.imageId, 1 << 24)
        XCTAssertNotEqual(turn1Items[0].identity.version & (1 << 63), 0)
        XCTAssertEqual(turn1Items[0].data, pngBytes)

        let turn2Items = loaded.items(
            forTurnId: "turn-2",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(turn2Items.count, 1)
        XCTAssertEqual(turn2Items[0].identity.sessionId, appSessionId)
        XCTAssertEqual(turn2Items[0].identity.version & (1 << 63), 0)
        XCTAssertNil(turn2Items[0].data)

        // Cross-session and cross-turn queries never return another session's or turn's image.
        XCTAssertTrue(
            loaded.items(
                forTurnId: "turn-1",
                sessionId: "other-app-session",
                copilotSessionId: copilotSessionId
            ).isEmpty
        )
        XCTAssertTrue(
            loaded.items(
                forTurnId: "turn-1",
                sessionId: appSessionId,
                copilotSessionId: "other-copilot-session"
            ).isEmpty
        )
        XCTAssertNotEqual(turn1Items[0].identity, turn2Items[0].identity)
        XCTAssertFalse(loaded.hasWatchedFileChanges())

        // Restoring the missing file on disk (with mtime <= turn-2 startedAt) flips `hasWatchedFileChanges()` and updates `version` + `data`.
        try pngBytes.write(to: missingURL)
        try FileManager.default.setAttributes([.modificationDate: t2], ofItemAtPath: missingURL.path)
        XCTAssertTrue(loaded.hasWatchedFileChanges())
        let reloaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: loaded,
            copilotHome: tempRoot.path
        )
        let restoredTurn2 = reloaded.items(
            forTurnId: "turn-2",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(restoredTurn2.count, 1)
        XCTAssertNotEqual(restoredTurn2[0].identity.version & (1 << 63), 0)
        XCTAssertEqual(restoredTurn2[0].data, pngBytes)
        XCTAssertFalse(reloaded.hasWatchedFileChanges())

        // A file written within the same millisecond as `turn.startedAt` (e.g. `.000400` vs `.000000`) is accepted, whereas a modification >= 1ms later is rejected.
        try FileManager.default.setAttributes([.modificationDate: t1.addingTimeInterval(0.0004)], ofItemAtPath: existingURL.path)
        let sameMillisecond = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: reloaded,
            copilotHome: tempRoot.path
        )
        XCTAssertEqual(
            sameMillisecond.items(
                forTurnId: "turn-1",
                sessionId: appSessionId,
                copilotSessionId: copilotSessionId
            ).first?.data,
            pngBytes
        )

        try FileManager.default.setAttributes([.modificationDate: t1.addingTimeInterval(1)], ofItemAtPath: existingURL.path)
        XCTAssertTrue(sameMillisecond.hasWatchedFileChanges())
        let afterOverwrite = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: sameMillisecond,
            copilotHome: tempRoot.path
        )
        XCTAssertNil(
            afterOverwrite.items(
                forTurnId: "turn-1",
                sessionId: appSessionId,
                copilotSessionId: copilotSessionId
            ).first?.data
        )

        // Replacing `events.jsonl` while keeping the same turn IDs flips `hasWatchedFileChanges()` and rescans from 0.
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl", isDirectory: false)
        let replacedEvents = #"{"type":"user.message","id":"turn-1","timestamp":"2026-04-15T12:00:01Z","data":{"content":"No attachments now","attachments":[]}}"# + "\n"
        try replacedEvents.write(to: eventsURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(afterOverwrite.hasWatchedFileChanges())
        let afterJournalReplace = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: afterOverwrite,
            copilotHome: tempRoot.path
        )
        // If a snapshot already includes a turn whose `user.message` line has not been flushed to `events.jsonl` yet, `events.jsonl` stays in `watchedFiles` and a subsequent append resolves the turn.
        try pngBytes.write(to: existingURL)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: existingURL.path)
        let partialEvents = #"{"type":"user.message","id":"turn-1","timestamp":"2026-04-15T12:00:01Z","data":{"content":"Check attached image","attachments":[{"type":"file","path":"\#(existingURL.path)","displayName":"attached.png","mimeType":"image/png"}]}}"# + "\n"
        try partialEvents.write(to: eventsURL, atomically: true, encoding: .utf8)
        let beforeAppend = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: afterJournalReplace,
            copilotHome: tempRoot.path
        )
        XCTAssertTrue(
            beforeAppend.items(
                forTurnId: "turn-2",
                sessionId: appSessionId,
                copilotSessionId: copilotSessionId
            ).isEmpty
        )
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: Data(
                (#"{"type":"user.message","id":"turn-2","timestamp":"2026-04-15T12:05:00Z","data":{"content":"Check missing image","attachments":[{"type":"file","path":"\#(missingURL.path)","displayName":"missing.png"}]}}"# + "\n").utf8
            )
        )
        try handle.close()
        XCTAssertTrue(beforeAppend.hasWatchedFileChanges())
        let afterAppend = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: beforeAppend,
            copilotHome: tempRoot.path
        )
        let appendedItems = afterAppend.items(
            forTurnId: "turn-2",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(appendedItems.count, 1)
        XCTAssertEqual(appendedItems.first?.data, pngBytes)
        XCTAssertFalse(afterAppend.hasWatchedFileChanges())

        // Symlinks and files exceeding the 5 MiB per-image limit are rejected and surface as `data == nil` placeholders.
        let symlinkURL = tempRoot.appendingPathComponent("symlink.png", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: existingURL)
        let oversizedURL = tempRoot.appendingPathComponent("oversized.png", isDirectory: false)
        try Data(repeating: 0x5A, count: 5 * 1_024 * 1_024 + 64).write(to: oversizedURL)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: oversizedURL.path)
        let safetyEvents = [
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-04-15T12:00:01Z","data":{"content":"Check symlink","attachments":[{"type":"file","path":"\#(symlinkURL.path)","displayName":"symlink.png","mimeType":"image/png"}]}}"#,
            #"{"type":"user.message","id":"turn-2","timestamp":"2026-04-15T12:05:00Z","data":{"content":"Check oversized","attachments":[{"type":"file","path":"\#(oversizedURL.path)","displayName":"oversized.png","mimeType":"image/png"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try safetyEvents.write(to: eventsURL, atomically: true, encoding: .utf8)
        let afterSafetyCheck = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: afterAppend,
            copilotHome: tempRoot.path
        )
        let symlinkItems = afterSafetyCheck.items(
            forTurnId: "turn-1",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(symlinkItems.count, 1)
        XCTAssertNil(symlinkItems[0].data)
        let oversizedItems = afterSafetyCheck.items(
            forTurnId: "turn-2",
            sessionId: appSessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(oversizedItems.count, 1)
        XCTAssertNil(oversizedItems[0].data)
    }

    func testHostedTranscriptDrawerRendersPromptAttachmentsAndMissingFilePlaceholders() async throws {
        _ = NSApplication.shared
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = tempRoot
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let t1 = ISO8601DateFormatter().date(from: "2026-04-15T14:00:01Z")!
        let t2 = ISO8601DateFormatter().date(from: "2026-04-15T14:02:00Z")!
        let promptPNG = try Self.makeSolidPNG(
            width: 480,
            height: 180,
            color: NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.88, alpha: 1)
        )
        let terminalPNG = try Self.makeSolidPNG(
            width: 360,
            height: 140,
            color: NSColor(calibratedRed: 0.14, green: 0.68, blue: 0.36, alpha: 1)
        )
        let promptURL = tempRoot.appendingPathComponent("prompt-fixture.png", isDirectory: false)
        try promptPNG.write(to: promptURL)
        try FileManager.default.setAttributes([.modificationDate: t1], ofItemAtPath: promptURL.path)
        let missingURL = tempRoot.appendingPathComponent("deleted-fixture.png", isDirectory: false)

        let events = [
            #"{"type":"user.message","id":"turn-render-1","timestamp":"2026-04-15T14:00:01Z","data":{"content":"Verify attached prompt image and terminal Kitty graphic.","attachments":[{"type":"file","path":"\#(promptURL.path)","displayName":"prompt-fixture.png","mimeType":"image/png"}]}}"#,
            #"{"type":"user.message","id":"turn-render-2","timestamp":"2026-04-15T14:02:00Z","data":{"content":"Verify missing local attachment fallback on second turn.","attachments":[{"type":"file","path":"\#(missingURL.path)","displayName":"deleted-fixture.png"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try events.write(
            to: sessionDir.appendingPathComponent("events.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: t2.addingTimeInterval(10),
            copilotSessionId: copilotSessionId,
            turns: [
                TranscriptTurn(
                    id: "turn-render-1",
                    startedAt: t1,
                    endedAt: t1.addingTimeInterval(12),
                    kind: "foreground",
                    userContent: "Verify attached prompt image and terminal Kitty graphic.",
                    assistantMessages: [
                        TranscriptAssistantMessage(
                            id: "m1",
                            timestamp: t1.addingTimeInterval(3),
                            content: "Prompt attachment rendered above; terminal Kitty image rendered below."
                        )
                    ],
                    tools: [],
                    isAborted: false
                ),
                TranscriptTurn(
                    id: "turn-render-2",
                    startedAt: t2,
                    endedAt: t2.addingTimeInterval(8),
                    kind: "foreground",
                    userContent: "Verify missing local attachment fallback on second turn.",
                    assistantMessages: [
                        TranscriptAssistantMessage(
                            id: "m2",
                            timestamp: t2.addingTimeInterval(3),
                            content: "The second turn references a deleted local PNG."
                        )
                    ],
                    tools: [],
                    isAborted: false
                ),
            ]
        )

        let appSessionId = "desktop-render-session"
        let capture = RemoteKittyImageCapture(
            sessionId: appSessionId,
            epoch: 3,
            budget: RemoteKittyImageCaptureBudget(),
            now: { t1.addingTimeInterval(5) }
        )
        transmit(capture, data: terminalPNG)

        let promptAttachments = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            copilotHome: tempRoot.path
        )
        let turns = TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(), to: snapshot).turns

        defer {
            UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
        }

        let specs: [(appearance: NSAppearance.Name, width: CGFloat, fullWidth: Bool)] = [
            (.aqua, 420, false),
            (.darkAqua, 420, false),
            (.aqua, 960, true),
            (.darkAqua, 960, true),
        ]
        for spec in specs {
            UserDefaults.standard.set(spec.fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            let drawer = TranscriptDrawer(
                turns: turns,
                imageCapture: capture,
                sessionId: appSessionId,
                promptAttachments: promptAttachments,
                copilotSessionId: copilotSessionId,
                workflow: nil,
                operation: .unavailable,
                workflowProvider: nil,
                operationProvider: nil,
                promptComposer: nil,
                onClose: {},
                onAction: { _ in RemoteWorkflowActionResult(state: .applied) },
                onPreview: { _ in }
            )
            .environment(\.colorScheme, spec.appearance == .darkAqua ? .dark : .light)

            let height: CGFloat = spec.fullWidth ? 960 : 840
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: spec.width, height: height),
                styleMask: [.titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: spec.appearance)
            let host = NSHostingView(rootView: drawer)
            host.frame = NSRect(x: 0, y: 0, width: spec.width, height: height)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4_000, y: -4_000))
            window.orderFrontRegardless()
            var bitmap: NSBitmapImageRep?
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 25_000_000)
                host.layoutSubtreeIfNeeded()
                if let candidate = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: candidate)
                    bitmap = candidate
                    if Self.bitmapContainsTestFixturePixels(candidate) { break }
                }
            }
            let renderedBitmap = try XCTUnwrap(bitmap)
            XCTAssertTrue(
                Self.bitmapContainsTestFixturePixels(renderedBitmap),
                "Hosted TranscriptDrawer (\(spec)) must render the decoded prompt PNG pixels"
            )

            // Render Turn 2 in isolation (no Turn 1 async image decode) with vs without the missing attachment to prove the placeholder itself visibly renders.
            let turn2WithMissing = Self.renderDrawerPNG(
                window: window,
                turns: [turns[1]],
                sessionId: appSessionId,
                promptAttachments: promptAttachments,
                copilotSessionId: copilotSessionId,
                appearance: spec.appearance,
                size: NSSize(width: spec.width, height: 320)
            )
            let turn2WithoutMissing = Self.renderDrawerPNG(
                window: window,
                turns: [turns[1]],
                sessionId: appSessionId,
                promptAttachments: TranscriptPromptAttachments(),
                copilotSessionId: copilotSessionId,
                appearance: spec.appearance,
                size: NSSize(width: spec.width, height: 320)
            )
            XCTAssertNotEqual(
                turn2WithMissing,
                turn2WithoutMissing,
                "Hosted TranscriptDrawer (\(spec)) must visibly render the missing attachment's Image unavailable placeholder in turn 2"
            )
            window.close()
        }
    }

    @MainActor
    func testControllerPollsWatchedAttachmentWithoutTranscriptChange() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("controller-attachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let previousStateDir = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", tempRoot.path, 1)
        defer {
            if let previousStateDir {
                setenv("COPILOT_PROJECTS_STATE_DIR", previousStateDir, 1)
            } else {
                unsetenv("COPILOT_PROJECTS_STATE_DIR")
            }
            try? FileManager.default.removeItem(at: tempRoot)
        }
        Paths.ensureStateDir()

        let sessionId = "controller-session-\(UUID().uuidString)"
        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = tempRoot
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let turnStart = ISO8601DateFormatter().date(from: "2026-04-15T15:00:00Z")!
        let attachmentURL = tempRoot.appendingPathComponent("watched.png", isDirectory: false)
        let eventLine = #"{"type":"user.message","id":"turn-watch-1","timestamp":"2026-04-15T15:00:00Z","data":{"content":"Watched attachment","attachments":[{"type":"file","path":"\#(attachmentURL.path)","displayName":"watched.png","mimeType":"image/png"}]}}"# + "\n"
        try eventLine.write(
            to: sessionDir.appendingPathComponent("events.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: turnStart.addingTimeInterval(4),
            copilotSessionId: copilotSessionId,
            turns: [
                TranscriptTurn(
                    id: "turn-watch-1",
                    startedAt: turnStart,
                    endedAt: turnStart.addingTimeInterval(3),
                    kind: "foreground",
                    userContent: "Watched attachment",
                    assistantMessages: [],
                    tools: [],
                    isAborted: false
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )

        let controller = TranscriptController(sessionId: sessionId, copilotHome: tempRoot.path)
        controller.reload()
        for _ in 0..<80 {
            let items = controller.promptAttachments.items(
                forTurnId: "turn-watch-1",
                sessionId: sessionId,
                copilotSessionId: copilotSessionId
            )
            if items.count == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let initialItems = controller.promptAttachments.items(
            forTurnId: "turn-watch-1",
            sessionId: sessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(initialItems.count, 1)
        XCTAssertNil(initialItems[0].data)
        let initialVersion = initialItems[0].identity.version

        let pngBytes = remoteKittyTestPNGBytes(width: 120, height: 80)
        try pngBytes.write(to: attachmentURL)
        try FileManager.default.setAttributes([.modificationDate: turnStart], ofItemAtPath: attachmentURL.path)

        controller.pollTranscriptIfNeeded()
        for _ in 0..<80 {
            let items = controller.promptAttachments.items(
                forTurnId: "turn-watch-1",
                sessionId: sessionId,
                copilotSessionId: copilotSessionId
            )
            if items.first?.data != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let updatedItems = controller.promptAttachments.items(
            forTurnId: "turn-watch-1",
            sessionId: sessionId,
            copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(updatedItems.count, 1)
        XCTAssertEqual(updatedItems[0].data, pngBytes)
        XCTAssertNotEqual(updatedItems[0].identity.version, initialVersion)
        XCTAssertEqual(controller.snapshot?.updatedAt, snapshot.updatedAt)
    }

    private static func bitmapContainsTestFixturePixels(_ bitmap: NSBitmapImageRep) -> Bool {
        var sawPromptBlue = false
        var sawTerminalGreen = false
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.blueComponent > 0.65 && c.blueComponent > c.redComponent + 0.35 {
                    sawPromptBlue = true
                }
                if c.greenComponent > 0.50 && c.greenComponent > c.redComponent + 0.25 && c.greenComponent > c.blueComponent + 0.15 {
                    sawTerminalGreen = true
                }
                if sawPromptBlue && sawTerminalGreen {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    private static func renderDrawerPNG(
        window: NSWindow,
        turns: [TranscriptTurn],
        sessionId: String,
        promptAttachments: TranscriptPromptAttachments,
        copilotSessionId: String,
        appearance: NSAppearance.Name,
        size: NSSize
    ) -> Data? {
        let drawer = TranscriptDrawer(
            turns: turns,
            imageCapture: nil,
            sessionId: sessionId,
            promptAttachments: promptAttachments,
            copilotSessionId: copilotSessionId,
            workflow: nil,
            operation: .unavailable,
            workflowProvider: nil,
            operationProvider: nil,
            promptComposer: nil,
            onClose: {},
            onAction: { _ in RemoteWorkflowActionResult(state: .applied) },
            onPreview: { _ in }
        )
        .environment(\.colorScheme, appearance == .darkAqua ? .dark : .light)
        let host = NSHostingView(rootView: drawer)
        host.frame = NSRect(origin: .zero, size: size)
        window.setContentSize(size)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    private static func makeSolidPNG(
        width: Int,
        height: Int,
        color: NSColor,
        fileType: NSBitmapImageRep.FileType = .png,
        properties: [NSBitmapImageRep.PropertyKey: Any] = [:]
    ) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(rep.representation(using: fileType, properties: properties))
    }

    /// `pngBytes` grown to `targetBytes` with a text chunk, still a valid PNG of the same size in pixels.
    private static func makePaddedPNG(from pngBytes: Data, targetBytes: Int, seed: UInt8) -> Data {
        var out = Data(pngBytes.dropLast(12))
        let pad = max(4, targetBytes - pngBytes.count - 12)
        var len = UInt32(pad).bigEndian
        out.append(Data(bytes: &len, count: 4))
        out.append(contentsOf: "tEXt".utf8)
        out.append(contentsOf: "k\0".utf8)
        out.append(Data(repeating: seed, count: pad - 2))
        out.append(Data(repeating: 0, count: 4))
        out.append(pngBytes.suffix(12))
        return out
    }

    private static func makeSolidJPEG(
        width: Int,
        height: Int,
        color: NSColor,
        orientation: Int? = nil
    ) throws -> Data {
        let base = try makeSolidPNG(width: width, height: height, color: color, fileType: .jpeg, properties: [.compressionFactor: 0.9])
        guard let orientation, let rep = NSBitmapImageRep(data: base), let cgImage = rep.cgImage else { return base }
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, [
            kCGImageDestinationLossyCompressionQuality: 0.9,
            kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testPromptAttachmentsLoadsUploadedBlobsBinaryAssetsAndJPEGsWithBudgets() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-uploaded-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = tempRoot
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let eventsURL = sessionDir.appendingPathComponent("events.jsonl", isDirectory: false)

        let t1 = ISO8601DateFormatter().date(from: "2026-11-05T12:00:01Z")!
        let t2 = ISO8601DateFormatter().date(from: "2026-11-05T12:05:00Z")!
        let t3 = ISO8601DateFormatter().date(from: "2026-11-05T12:10:00Z")!

        let pngBytes = remoteKittyTestPNGBytes(width: 180, height: 90)
        let jpegBytes = try Self.makeSolidJPEG(width: 200, height: 100, color: .systemBlue)
        let gifBytes = try Self.makeSolidPNG(width: 8, height: 8, color: .systemRed, fileType: .gif)
        XCTAssertNil(TranscriptPromptAttachments.pixelSize(gifBytes))
        let localJPEGURL = tempRoot.appendingPathComponent("photo.jpg", isDirectory: false)
        try jpegBytes.write(to: localJPEGURL)
        try FileManager.default.setAttributes([.modificationDate: t2], ofItemAtPath: localJPEGURL.path)
        let deletedTempURL = tempRoot.appendingPathComponent("deleted-temp.png", isDirectory: false)
        let largeMetadata = String(repeating: "A", count: 300_000)

        let events = [
            #"{"type":"session.binary_asset","id":"a-unreferenced","data":{"assetId":"sha256:unreferenced-tool-asset","type":"image","mimeType":"image/png","data":"\#(pngBytes.base64EncodedString())"}}"#,
            #"{"type":"session.binary_asset","id":"a-1","data":{"assetId":"sha256:asset-jpeg","type":"image","mimeType":"image/jpeg","byteLength":\#(jpegBytes.count),"data":"\#(jpegBytes.base64EncodedString())"}}"#,
            #"{"type":"session.binary_asset","id":"a-2","data":{"metadata":{"assetId":"sha256:wrong","imageEditSource":{"data":"\#(largeMetadata)"}},"assetId":"sha256:asset-png","type":"image","mimeType":"image/png","byteLength":\#(pngBytes.count),"data":"\#(pngBytes.base64EncodedString())"}}"#,
            #"{"type":"session.binary_asset","id":"a-corrupt","data":{"assetId":"sha256:corrupt","type":"image","mimeType":"image/jpeg","data":"\#(Data([0xFF, 0xD8, 0x00, 0xFF, 0xD9]).base64EncodedString())"}}"#,
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-11-05T12:00:01Z","data":{"content":"Uploaded assets","attachments":[{"type":"blob","assetId":"sha256:asset-jpeg","displayName":"Screenshot.jpg","mimeType":"image/jpeg","byteLength":\#(jpegBytes.count)},{"assetId":"sha256:asset-png","mimeType":"image/png"},{"type":"blob","displayName":"notes.md","mimeType":"text/markdown","data":"aGVsbG8="}]}}"#,
            #"{"type":"user.message","id":"turn-2","timestamp":"2026-11-05T12:05:00Z","data":{"content":"Inline blobs and JPEG file","attachments":[{"type":"blob","displayName":"inline.jpg","mimeType":"image/jpeg","data":"\#(jpegBytes.base64EncodedString())"},{"type":"blob","displayName":"inline.png","mimeType":"image/png","data":"\#(pngBytes.base64EncodedString())"},{"type":"file","path":"\#(localJPEGURL.path)","displayName":"photo.jpg"},{"type":"file","path":"\#(localJPEGURL.path)","assetId":"sha256:asset-png","displayName":"overwritten.png","mimeType":"image/png"},{"type":"file","path":"\#(deletedTempURL.path)","assetId":"sha256:asset-png","displayName":"deleted-temp.png","mimeType":"image/png"}]}}"#,
            #"{"type":"user.message","id":"turn-3","timestamp":"2026-11-05T12:10:00Z","data":{"content":"Unavailable uploads","attachments":[{"type":"blob","assetId":"sha256:late-asset","displayName":"late.png","mimeType":"image/png"},{"type":"blob","assetId":"sha256:corrupt","displayName":"corrupt.jpg","mimeType":"image/jpeg"},{"type":"blob","displayName":"bad-inline.png","mimeType":"image/png","data":"\#(gifBytes.base64EncodedString())"},{"type":"blob","displayName":"omitted.png","mimeType":"image/png","omittedReason":"too_large"},{"type":"blob","displayName":"anim.gif","mimeType":"image/gif","data":"\#(gifBytes.base64EncodedString())"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try events.write(to: eventsURL, atomically: true, encoding: .utf8)

        let snapshot = TranscriptSnapshot(
            schemaVersion: 4,
            updatedAt: t3.addingTimeInterval(5),
            copilotSessionId: copilotSessionId,
            turns: [
                TranscriptTurn(id: "turn-1", startedAt: t1, endedAt: t1.addingTimeInterval(2), kind: "foreground", userContent: "Uploaded assets", assistantMessages: [], tools: [], isAborted: false),
                TranscriptTurn(id: "turn-2", startedAt: t2, endedAt: t2.addingTimeInterval(2), kind: "foreground", userContent: "Inline blobs and JPEG file", assistantMessages: [], tools: [], isAborted: false),
                TranscriptTurn(id: "turn-3", startedAt: t3, endedAt: t3.addingTimeInterval(2), kind: "foreground", userContent: "Unavailable uploads", assistantMessages: [], tools: [], isAborted: false),
            ]
        )

        let appSessionId = "desktop-upload-session"
        let loaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            copilotHome: tempRoot.path
        )
        XCTAssertNil(loaded.assetSpans["sha256:unreferenced-tool-asset"])
        XCTAssertEqual(Set(loaded.assetSpans.keys), ["sha256:asset-jpeg", "sha256:asset-png", "sha256:corrupt"])

        let turn1 = loaded.items(forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(turn1.map(\.data), [jpegBytes, pngBytes])
        XCTAssertNotEqual(turn1[0].identity, turn1[1].identity)

        let turn2 = loaded.items(forTurnId: "turn-2", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(turn2.map(\.data), [jpegBytes, pngBytes, jpegBytes, pngBytes, pngBytes])

        let turn3 = loaded.items(forTurnId: "turn-3", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(turn3.count, 4)
        XCTAssertTrue(turn3.allSatisfy { $0.data == nil && ($0.identity.version & (1 << 63)) == 0 })

        // Appending the missing `session.binary_asset` later flips `hasWatchedFileChanges()` and resolves only that attachment.
        let handle = try FileHandle(forWritingTo: eventsURL)
        try handle.seekToEnd()
        let appendedAsset = #"{"type":"session.binary_asset","id":"a-late","data":{"assetId":"sha256:late-asset","type":"image","mimeType":"image/png","data":"\#(pngBytes.base64EncodedString())"}}"# + "\n"
        try handle.write(contentsOf: Data(appendedAsset.utf8))
        try handle.close()
        XCTAssertTrue(loaded.hasWatchedFileChanges())

        let reloaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: loaded,
            copilotHome: tempRoot.path
        )
        let reloadedTurn3 = reloaded.items(forTurnId: "turn-3", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(reloadedTurn3.map(\.data), [pngBytes, nil, nil, nil])
        XCTAssertNotEqual(reloadedTurn3[0].identity.version & (1 << 63), 0)
        XCTAssertFalse(reloaded.hasWatchedFileChanges())

        // Appending a new turn that references an earlier unreferenced asset resolves it from `0..<startOffset`, and missing/invalid assets fall back to inline data or a validated local file path.
        let handle2 = try FileHandle(forWritingTo: eventsURL)
        try handle2.seekToEnd()
        let appendedTurn4 = #"{"type":"user.message","id":"turn-4","timestamp":"2026-11-05T12:12:00Z","data":{"content":"Historical asset","attachments":[{"type":"blob","assetId":"sha256:unreferenced-tool-asset","mimeType":"image/png"},{"type":"blob","assetId":"sha256:corrupt","mimeType":"image/png","data":"\#(pngBytes.base64EncodedString())"},{"type":"file","assetId":"sha256:missing-asset","path":"\#(localJPEGURL.path)","displayName":"photo.jpg"}]}}"# + "\n"
        try handle2.write(contentsOf: Data(appendedTurn4.utf8))
        try handle2.close()
        let snapshotWithTurn4 = TranscriptSnapshot(
            schemaVersion: 4,
            updatedAt: t3.addingTimeInterval(120),
            copilotSessionId: copilotSessionId,
            turns: snapshot.turns + [
                TranscriptTurn(id: "turn-4", startedAt: t3.addingTimeInterval(120), endedAt: t3.addingTimeInterval(122), kind: "foreground", userContent: "Historical asset", assistantMessages: [], tools: [], isAborted: false),
            ]
        )
        let withTurn4 = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshotWithTurn4,
            previous: reloaded,
            copilotHome: tempRoot.path
        )
        XCTAssertEqual(withTurn4.items(forTurnId: "turn-4", sessionId: appSessionId, copilotSessionId: copilotSessionId).map(\.data), [pngBytes, pngBytes, jpegBytes])
        XCTAssertEqual(withTurn4.items(forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: copilotSessionId), turn1)

        // Oversized (> 5 MiB) inline blob and binary_asset entries with structurally valid PNG bytes are rejected and surface as `data == nil` placeholders.
        let oversizedValidPNG = Self.makePaddedPNG(from: pngBytes, targetBytes: 5 * 1_024 * 1_024 + 64, seed: 0x41)
        XCTAssertGreaterThan(oversizedValidPNG.count, 5 * 1_024 * 1_024)
        XCTAssertEqual(TranscriptPromptAttachments.pixelSize(oversizedValidPNG), CGSize(width: 180, height: 90))
        let oversizedBase64 = oversizedValidPNG.base64EncodedString()
        let budgetEvents = [
            #"{"type":"session.binary_asset","id":"a-big","data":{"data":"\#(oversizedBase64)","type":"image","mimeType":"image/png","assetId":"sha256:oversized-asset"}}"#,
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-11-05T12:00:01Z","data":{"content":"Oversized","attachments":[{"type":"blob","assetId":"sha256:oversized-asset","mimeType":"image/png"},{"type":"blob","mimeType":"image/png","data":"\#(oversizedBase64)"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try budgetEvents.write(to: eventsURL, atomically: true, encoding: .utf8)
        let afterOversized = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: reloaded,
            copilotHome: tempRoot.path
        )
        let oversizedItems = afterOversized.items(forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(oversizedItems.map(\.data), [nil, nil])

        // Aggregate 32 MiB total budget: newest turns keep their image data while older turns exceeding 32 MiB become placeholders.
        let fourMiB1 = Self.makePaddedPNG(from: pngBytes, targetBytes: 4_500_000, seed: 0x41)
        let fourMiB2 = Self.makePaddedPNG(from: pngBytes, targetBytes: 4_500_000, seed: 0x42)
        let exactFiveMiB = Self.makePaddedPNG(from: pngBytes, targetBytes: 5 * 1_024 * 1_024, seed: 0x43)
        XCTAssertEqual(exactFiveMiB.count, 5 * 1_024 * 1_024)
        let turn1Attachments = ((0..<3).map { _ in #"{"type":"blob","assetId":"sha256:four-1","mimeType":"image/png"}"# } + [#"{"type":"blob","assetId":"sha256:exact-5m","mimeType":"image/png"}"#]).joined(separator: ",")
        let turn2Attachments = (0..<4).map { _ in #"{"type":"blob","mimeType":"image/png","data":"\#(fourMiB2.base64EncodedString())"}"# }.joined(separator: ",")
        let totalBudgetEvents = [
            #"{"type":"session.binary_asset","id":"a-4m","data":{"assetId":"sha256:four-1","type":"image","mimeType":"image/png","data":"\#(fourMiB1.base64EncodedString())"}}"#,
            #"{"type":"session.binary_asset","id":"a-5m","data":{"assetId":"sha256:exact-5m","type":"image","mimeType":"image/png","data":"\#(exactFiveMiB.base64EncodedString())"}}"#,
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-11-05T12:00:01Z","data":{"content":"Older 18MB","attachments":[\#(turn1Attachments)]}}"#,
            #"{"type":"user.message","id":"turn-2","timestamp":"2026-11-05T12:05:00Z","data":{"content":"Newer 18MB","attachments":[\#(turn2Attachments)]}}"#,
        ].joined(separator: "\n") + "\n"
        try totalBudgetEvents.write(to: eventsURL, atomically: true, encoding: .utf8)
        let afterTotalBudget = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            previous: afterOversized,
            copilotHome: tempRoot.path
        )
        let newerItems = afterTotalBudget.items(forTurnId: "turn-2", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        let olderItems = afterTotalBudget.items(forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: copilotSessionId)
        XCTAssertEqual(newerItems.compactMap(\.data).count, 4)
        XCTAssertEqual(olderItems.count, 4)
        XCTAssertEqual(olderItems.compactMap(\.data).count, 3)
        XCTAssertNil(olderItems[3].data)

        // When a newer turn references the exact-5-MiB asset that was previously rejected for insufficient aggregate budget, it loads cleanly.
        let handle3 = try FileHandle(forWritingTo: eventsURL)
        try handle3.seekToEnd()
        try handle3.write(contentsOf: Data((#"{"type":"user.message","id":"turn-4","timestamp":"2026-11-05T12:12:00Z","data":{"content":"Reuse exact 5MB","attachments":[{"type":"blob","assetId":"sha256:exact-5m","mimeType":"image/png"}]}}"# + "\n").utf8))
        try handle3.close()
        let afterExact5MReuse = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshotWithTurn4,
            previous: afterTotalBudget,
            copilotHome: tempRoot.path
        )
        XCTAssertEqual(afterExact5MReuse.items(forTurnId: "turn-4", sessionId: appSessionId, copilotSessionId: copilotSessionId).map(\.data), [exactFiveMiB])
    }

    func testTimelineItemsHidesMatchingPromptAttachmentAndKeepsDifferentOrOtherTurnImages() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-dedupe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = tempRoot
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let t1 = ISO8601DateFormatter().date(from: "2026-11-06T12:00:00Z")!
        let t2 = ISO8601DateFormatter().date(from: "2026-11-06T12:05:00Z")!
        let t3 = ISO8601DateFormatter().date(from: "2026-11-06T12:10:00Z")!

        let promptPNG = remoteKittyTestPNGBytes(width: 240, height: 120)
        let differentPNG = remoteKittyTestPNGBytes(width: 180, height: 90)

        func makeScreenshotPNG(width: Int, height: Int, changedLine: Bool = false) throws -> Data {
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                )
            )
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor(calibratedWhite: 0.14, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
            NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
            NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: max(8, height / 8))).fill()
            if changedLine {
                NSColor(calibratedWhite: 0.90, alpha: 1).setFill()
                NSBezierPath(rect: NSRect(x: width / 8, y: height / 2, width: width / 3, height: max(6, height / 36))).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        }

        let retinaPromptPNG = try makeScreenshotPNG(width: 1_230, height: 436)
        let downscaledEchoPNG = try makeScreenshotPNG(width: 896, height: 318)
        let oneLineChangedPNG = try makeScreenshotPNG(width: 896, height: 318, changedLine: true)
        let differentAspectPNG = try makeScreenshotPNG(width: 896, height: 360)

        let events = [
            #"{"type":"user.message","id":"turn-1","timestamp":"2026-11-06T12:00:00Z","data":{"content":"Turn 1 with duplicate attachments","attachments":[{"type":"blob","mimeType":"image/png","data":"\#(promptPNG.base64EncodedString())"},{"type":"blob","mimeType":"image/png","data":"\#(promptPNG.base64EncodedString())"}]}}"#,
            #"{"type":"user.message","id":"turn-2","timestamp":"2026-11-06T12:05:00Z","data":{"content":"Turn 2 without prompt attachment","attachments":[]}}"#,
            #"{"type":"user.message","id":"turn-3","timestamp":"2026-11-06T12:10:00Z","data":{"content":"Turn 3 with Retina prompt screenshot","attachments":[{"type":"blob","mimeType":"image/png","data":"\#(retinaPromptPNG.base64EncodedString())"}]}}"#,
        ].joined(separator: "\n") + "\n"
        try events.write(
            to: sessionDir.appendingPathComponent("events.jsonl", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        var currentNow = t1.addingTimeInterval(0.2)
        let appSessionId = "desktop-dedupe-session"
        let capture = RemoteKittyImageCapture(
            sessionId: appSessionId,
            epoch: 7,
            budget: RemoteKittyImageCaptureBudget(),
            now: { currentNow }
        )
        func ingest(id: UInt32, data: Data, at time: Date) {
            currentNow = time
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(id),q=2",
                base64Payload: data.base64EncodedString()
            )[...])
        }

        // Turn 1: two identical attachments hide at most two pre-reply echoes (ids 10 and 11),
        // keeping a third pre-reply same-byte capture (id 12), a different image (id 13),
        // and a post-reply tool capture of the same bytes (id 14).
        ingest(id: 10, data: promptPNG, at: t1.addingTimeInterval(0.1))
        ingest(id: 11, data: promptPNG, at: t1.addingTimeInterval(0.2))
        ingest(id: 12, data: promptPNG, at: t1.addingTimeInterval(0.3))
        ingest(id: 13, data: differentPNG, at: t1.addingTimeInterval(1.0))
        ingest(id: 14, data: promptPNG, at: t1.addingTimeInterval(3.0))
        // Turn 2: the same image from Turn 1 is displayed in a later turn (id 15).
        ingest(id: 15, data: promptPNG, at: t2.addingTimeInterval(1.0))
        // Turn 3: downscaled copy of 1230x436 -> 896x318 (id 16) is hidden;
        // near-identical 896x318 with one changed line (id 17) and different aspect ratio 896x360 (id 18) are kept.
        ingest(id: 16, data: downscaledEchoPNG, at: t3.addingTimeInterval(0.15))
        ingest(id: 17, data: oneLineChangedPNG, at: t3.addingTimeInterval(0.25))
        ingest(id: 18, data: differentAspectPNG, at: t3.addingTimeInterval(0.35))

        let snapshot = TranscriptSnapshot(
            schemaVersion: 4,
            updatedAt: t3.addingTimeInterval(5),
            copilotSessionId: copilotSessionId,
            turns: [
                TranscriptTurn(
                    id: "turn-1",
                    startedAt: t1,
                    endedAt: t1.addingTimeInterval(5),
                    kind: "foreground",
                    userContent: "Turn 1",
                    assistantMessages: [
                        TranscriptAssistantMessage(id: "m1", timestamp: t1.addingTimeInterval(2.0), content: "Checked.")
                    ],
                    tools: [],
                    isAborted: false
                ),
                TranscriptTurn(id: "turn-2", startedAt: t2, endedAt: t2.addingTimeInterval(5), kind: "foreground", userContent: "Turn 2", assistantMessages: [], tools: [], isAborted: false),
                TranscriptTurn(id: "turn-3", startedAt: t3, endedAt: t3.addingTimeInterval(5), kind: "foreground", userContent: "Turn 3", assistantMessages: [], tools: [], isAborted: false),
            ]
        )

        let promptAttachments = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            copilotHome: tempRoot.path
        )
        let attached = TranscriptImageAssociation.attach(
            images: capture.retainedImageMetadata(),
            to: snapshot
        )

        // Two identical attachments in one message keep their existing promptAttachments behavior.
        let turn1Attachments = promptAttachments.items(
            forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: copilotSessionId
        )
        XCTAssertEqual(turn1Attachments.map(\.data), [promptPNG, promptPNG])

        // Turn 1 timeline: matching prompt echoes (ids 10, 11) are hidden; exhausted 3rd copy (id 12),
        // different image (id 13), and post-reply tool image (id 14) are kept.
        let turn1Timeline = TranscriptImageAssociation.timelineItems(
            for: attached.turns[0], imageCapture: capture, promptAttachments: turn1Attachments
        )
        XCTAssertEqual(turn1Timeline.map(\.id), ["image-12", "image-13", "assistant-m1", "image-14"])

        // Turn 2 timeline: same image in another turn (id 15) is kept.
        let turn2Attachments = promptAttachments.items(
            forTurnId: "turn-2", sessionId: appSessionId, copilotSessionId: copilotSessionId
        )
        let turn2Timeline = TranscriptImageAssociation.timelineItems(
            for: attached.turns[1], imageCapture: capture, promptAttachments: turn2Attachments
        )
        XCTAssertEqual(turn2Timeline.map(\.id), ["image-15"])

        // Turn 3 timeline: downscaled copy (id 16) is hidden; similar-with-one-changed-line (id 17)
        // and different-aspect-ratio (id 18) are kept.
        let turn3Attachments = promptAttachments.items(
            forTurnId: "turn-3", sessionId: appSessionId, copilotSessionId: copilotSessionId
        )
        let turn3Timeline = TranscriptImageAssociation.timelineItems(
            for: attached.turns[2], imageCapture: capture, promptAttachments: turn3Attachments
        )
        XCTAssertEqual(turn3Timeline.map(\.id), ["image-17", "image-18"])

        // Updating imageId 16 with a new content version (now carrying the one-line-changed image)
        // invalidates the cached signature for that imageId and shows the new version.
        ingest(id: 16, data: oneLineChangedPNG, at: t3.addingTimeInterval(0.5))
        let reattached = TranscriptImageAssociation.attach(
            images: capture.retainedImageMetadata(),
            to: snapshot
        )
        let updatedTurn3Timeline = TranscriptImageAssociation.timelineItems(
            for: reattached.turns[2], imageCapture: capture, promptAttachments: turn3Attachments
        )
        XCTAssertEqual(updatedTurn3Timeline.map(\.id), ["image-17", "image-18", "image-16"])
    }

    // MARK: - Images returned by tools

    private func makeToolImageSession() throws -> (home: URL, copilotSessionId: String, events: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("tool-images-\(UUID().uuidString)", isDirectory: true)
        let copilotSessionId = UUID().uuidString.lowercased()
        let sessionDir = home
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, copilotSessionId, sessionDir.appendingPathComponent("events.jsonl", isDirectory: false))
    }

    private static func assetLine(_ assetId: String, _ bytes: Data, mimeType: String = "image/png") -> String {
        #"{"type":"session.binary_asset","data":{"assetId":"\#(assetId)","type":"image","mimeType":"\#(mimeType)","byteLength":\#(bytes.count),"data":"\#(bytes.base64EncodedString())"},"id":"asset-\#(assetId)"}"#
    }

    private static func promptLine(_ turnId: String) -> String {
        #"{"type":"user.message","data":{"content":"Look at this"},"id":"\#(turnId)","timestamp":"2026-11-13T12:00:00Z"}"#
    }

    /// A finished tool call that returned one image per asset id, in the shape the CLI records.
    private static func toolImageLine(_ toolCallId: String, _ assetIds: [String], agentId: String? = nil) -> String {
        let images = assetIds
            .map { #"{"type":"image","mimeType":"image/png","assetId":"\#($0)","byteLength":1}"# }
            .joined(separator: ",")
        let agent = agentId.map { #","agentId":"\#($0)""# } ?? ""
        return #"{"type":"tool.execution_complete","data":{"toolCallId":"\#(toolCallId)","success":true,"result":{"content":"ok","binaryResultsForLlm":[\#(images)]}},"id":"done-\#(toolCallId)"\#(agent)}"#
    }

    private static func toolTurn(
        _ id: String,
        kind: String = "foreground",
        tools: [String],
        pending: Bool = false
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endedAt: nil,
            kind: kind,
            userContent: "Look at this",
            assistantMessages: [],
            tools: tools.map { TranscriptTool(id: $0, name: "view", title: "\($0).png", success: pending ? nil : true) },
            isAborted: false
        )
    }

    private static func toolSnapshot(_ copilotSessionId: String, _ turns: [TranscriptTurn]) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 4,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            copilotSessionId: copilotSessionId,
            turns: turns
        )
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func append(_ lines: [String], to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// Replaces `old` with `new`, of the same length, where it stands: the file keeps its identity and size.
    private static func overwrite(_ old: String, with new: String, in url: URL) throws {
        XCTAssertEqual(old.utf8.count, new.utf8.count)
        let range = try XCTUnwrap(try Data(contentsOf: url).range(of: Data(old.utf8)))
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(range.lowerBound))
        try handle.write(contentsOf: Data(new.utf8))
    }

    func testToolImagesLoadFromBinaryAssetsUnderTheToolCallThatReturnedThem() throws {
        let session = try makeToolImageSession()
        let png = remoteKittyTestPNGBytes(width: 120, height: 60)
        let jpeg = try Self.makeSolidJPEG(width: 90, height: 60, color: .systemGreen)
        try Self.write([
            Self.assetLine("sha256:png", png),
            Self.assetLine("sha256:jpeg", jpeg, mimeType: "image/jpeg"),
            Self.promptLine("turn-1"),
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call-view","success":true,"result":{"content":"ok","binaryResultsForLlm":[{"type":"image","mimeType":"image/png","assetId":"sha256:png","description":"Image file at path /tmp/shot.png"},{"type":"resource","mimeType":"application/pdf","assetId":"sha256:pdf"},{"type":"image","mimeType":"image/jpeg","assetId":"sha256:jpeg"}]}},"id":"done-call-view"}"#,
            Self.toolImageLine("call-missing", ["sha256:not-in-the-file"]),
            Self.toolImageLine("call-subagent", ["sha256:png"], agentId: "agent-1"),
            Self.toolImageLine("call-in-no-turn", ["sha256:png"]),
            #"{"type":"tool.execution_complete","data":{"toolCallId":"call-text","success":true,"result":{"content":"no image"}},"id":"done-call-text"}"#,
            Self.toolImageLine("call-automated", ["sha256:png"]),
        ], to: session.events)
        let snapshot = Self.toolSnapshot(session.copilotSessionId, [
            Self.toolTurn("turn-1", tools: ["call-view", "call-missing", "call-subagent", "call-text"]),
            Self.toolTurn("automated-1", kind: "automated", tools: ["call-automated"]),
        ])
        let appSessionId = "desktop-tool-images"
        let loaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: snapshot,
            copilotHome: session.home.path
        )
        func toolImages(_ turnId: String) -> [TranscriptPromptAttachments.Item] {
            loaded.items(
                forTurnId: turnId, sessionId: appSessionId, copilotSessionId: session.copilotSessionId, fromTools: true
            )
        }

        // Images only, in result order, each under its own tool call. A sub-agent's result is not shown
        // even when a row has its id, and an asset that is not in the file is a placeholder.
        let turn1 = toolImages("turn-1")
        XCTAssertEqual(turn1.map(\.toolCallId), ["call-view", "call-view", "call-missing"])
        XCTAssertEqual(turn1.map(\.data), [png, jpeg, nil])
        let automated = toolImages("automated-1")
        XCTAssertEqual(automated.map(\.toolCallId), ["call-automated"])
        XCTAssertEqual(automated.map(\.data), [png])
        XCTAssertTrue(
            loaded.items(forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: session.copilotSessionId).isEmpty
        )

        // The same bytes under another tool call or turn are another image, and a tool image's id is
        // never a prompt image's (1 << 24) or a Kitty capture's (below 1 << 24).
        let identities = (turn1 + automated).map(\.identity)
        XCTAssertEqual(Set(identities).count, 4)
        XCTAssertTrue(identities.allSatisfy { $0.sessionId == appSessionId && $0.imageId >> 24 == 2 })

        // Nothing is handed to another session or another conversation.
        XCTAssertTrue(loaded.items(
            forTurnId: "turn-1", sessionId: "another-session", copilotSessionId: session.copilotSessionId, fromTools: true
        ).isEmpty)
        XCTAssertTrue(loaded.items(
            forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: "another-conversation", fromTools: true
        ).isEmpty)

        // A tool's asset is written before its completion, so one that is missing will not arrive:
        // it does not keep the events file watched.
        XCTAssertTrue(loaded.watchedFiles.isEmpty)
        XCTAssertFalse(loaded.hasWatchedFileChanges())
    }

    func testToolImageReadBeforeTheSnapshotShowsItsToolLoadsOnceTheToolIsDone() throws {
        let session = try makeToolImageSession()
        let png = remoteKittyTestPNGBytes(width: 120, height: 60)
        let completion = Self.toolImageLine("call-late", ["sha256:late"])
        try Self.write([Self.assetLine("sha256:late", png), Self.promptLine("turn-1"), completion], to: session.events)
        let appSessionId = "desktop-tool-order"
        func loadAttachments(
            _ turn: TranscriptTurn,
            previous: TranscriptPromptAttachments? = nil
        ) -> TranscriptPromptAttachments {
            TranscriptPromptAttachments.load(
                sessionId: appSessionId,
                snapshot: Self.toolSnapshot(session.copilotSessionId, [turn]),
                previous: previous,
                copilotHome: session.home.path
            )
        }
        // The tracker publishes the snapshot from events.jsonl, so the file runs ahead of it. Here the
        // whole file is read while the snapshot has no row for the tool, then the row appears running,
        // then finished. Each load is given the one before it, as the controller does.
        let beforeTheRow = loadAttachments(Self.toolTurn("turn-1", tools: []))
        XCTAssertEqual(beforeTheRow.scannedEventsBytes, try Data(contentsOf: session.events).count)
        XCTAssertTrue(beforeTheRow.toolItemsByTurnId.isEmpty)
        let whileRunning = loadAttachments(
            Self.toolTurn("turn-1", tools: ["call-late"], pending: true), previous: beforeTheRow
        )

        // Blank the completion where it was read. A load that had dropped the line has nothing left to
        // find; one that recorded it has no need to read it again.
        try Self.overwrite(completion, with: String(repeating: " ", count: completion.utf8.count), in: session.events)
        let done = loadAttachments(Self.toolTurn("turn-1", tools: ["call-late"]), previous: whileRunning).items(
            forTurnId: "turn-1", sessionId: appSessionId, copilotSessionId: session.copilotSessionId, fromTools: true
        )
        XCTAssertEqual(done.map(\.data), [png])
        XCTAssertEqual(done.map(\.toolCallId), ["call-late"])
    }

    func testToolImagesFollowTheFinishedToolRowsWhenTheirCountStaysTheSame() throws {
        let session = try makeToolImageSession()
        let png = remoteKittyTestPNGBytes(width: 120, height: 60)
        try Self.write([
            Self.assetLine("sha256:shot", png),
            Self.promptLine("turn-1"),
            Self.toolImageLine("call-dropped", ["sha256:shot"]),
            Self.toolImageLine("call-current", ["sha256:shot"]),
        ], to: session.events)
        let appSessionId = "desktop-tool-rows"
        func load(_ automated: TranscriptTurn, previous: TranscriptPromptAttachments?) -> TranscriptPromptAttachments {
            TranscriptPromptAttachments.load(
                sessionId: appSessionId,
                snapshot: Self.toolSnapshot(session.copilotSessionId, [Self.toolTurn("turn-1", tools: []), automated]),
                previous: previous,
                copilotHome: session.home.path
            )
        }

        // The tracker drops an automated turn as another finishes a tool: the prompt turns and the
        // number of finished tools are what they were, but the finished rows are not.
        let first = load(Self.toolTurn("automated-1", kind: "automated", tools: ["call-dropped"]), previous: nil)
        let second = load(Self.toolTurn("automated-2", kind: "automated", tools: ["call-current"]), previous: first)
        XCTAssertEqual(
            second.items(
                forTurnId: "automated-2", sessionId: appSessionId, copilotSessionId: session.copilotSessionId,
                fromTools: true
            ).map(\.toolCallId),
            ["call-current"]
        )
    }

    func testToolImagesLoadIncrementallyWithoutReadingAnEarlierTurnOrAMissingAssetAgain() throws {
        let session = try makeToolImageSession()
        let png = remoteKittyTestPNGBytes(width: 120, height: 60)
        let jpeg = try Self.makeSolidJPEG(width: 90, height: 60, color: .systemGreen)
        let firstAsset = Self.assetLine("sha256:first", png)
        let absentAsset = Self.assetLine("sha256:absent", png)
        let blank = String(repeating: " ", count: absentAsset.utf8.count)
        try Self.write([
            blank,
            firstAsset,
            Self.promptLine("turn-1"),
            Self.toolImageLine("call-absent", ["sha256:absent"]),
            Self.promptLine("turn-2"),
            Self.toolImageLine("call-first", ["sha256:first"]),
        ], to: session.events)
        let turns = [
            Self.toolTurn("turn-1", tools: ["call-absent"]),
            Self.toolTurn("turn-2", tools: ["call-first"]),
        ]
        let appSessionId = "desktop-tool-incremental"
        func toolImages(_ loaded: TranscriptPromptAttachments, _ turnId: String) -> [TranscriptPromptAttachments.Item] {
            loaded.items(
                forTurnId: turnId, sessionId: appSessionId, copilotSessionId: session.copilotSessionId, fromTools: true
            )
        }
        let first = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: Self.toolSnapshot(session.copilotSessionId, turns),
            copilotHome: session.home.path
        )
        XCTAssertEqual(toolImages(first, "turn-1").map(\.data), [nil])
        XCTAssertEqual(toolImages(first, "turn-2").map(\.data), [png])

        // In the part of the file already read: the asset turn 1 could not find now exists, and turn 2's
        // asset no longer decodes. A later load must read neither again.
        try Self.overwrite(blank, with: absentAsset, in: session.events)
        try Self.overwrite(firstAsset, with: Self.assetLine("sha256:first", Data(count: png.count)), in: session.events)
        try Self.append([
            Self.assetLine("sha256:second", jpeg, mimeType: "image/jpeg"),
            Self.promptLine("turn-3"),
            Self.toolImageLine("call-second", ["sha256:second"]),
        ], to: session.events)

        let second = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: Self.toolSnapshot(
                session.copilotSessionId,
                turns + [Self.toolTurn("turn-3", tools: ["call-second"])]
            ),
            previous: first,
            copilotHome: session.home.path
        )
        XCTAssertEqual(toolImages(second, "turn-3").map(\.data), [jpeg])
        XCTAssertEqual(toolImages(second, "turn-2"), toolImages(first, "turn-2"))
        XCTAssertEqual(toolImages(second, "turn-1").map(\.data), [nil])
        XCTAssertTrue(second.watchedFiles.isEmpty)
    }

    func testToolImagesTakeOnlyTheBudgetPromptImagesLeave() throws {
        let session = try makeToolImageSession()
        let big = Self.makePaddedPNG(
            from: remoteKittyTestPNGBytes(width: 180, height: 90),
            targetBytes: 4_500_000,
            seed: 0x44
        )
        try Self.write([
            Self.assetLine("sha256:big", big),
            #"{"type":"user.message","data":{"content":"Oldest turn","attachments":[{"type":"blob","assetId":"sha256:big","mimeType":"image/png"}]},"id":"turn-1"}"#,
            Self.promptLine("turn-2"),
            Self.toolImageLine("call-older", ["sha256:big", "sha256:big"]),
            Self.promptLine("turn-3"),
            Self.toolImageLine("call-newer", Array(repeating: "sha256:big", count: 6)),
        ], to: session.events)
        let appSessionId = "desktop-tool-budget"
        let loaded = TranscriptPromptAttachments.load(
            sessionId: appSessionId,
            snapshot: Self.toolSnapshot(session.copilotSessionId, [
                Self.toolTurn("turn-1", tools: []),
                Self.toolTurn("turn-2", tools: ["call-older"]),
                Self.toolTurn("turn-3", tools: ["call-newer"]),
            ]),
            copilotHome: session.home.path
        )
        func images(_ turnId: String, fromTools: Bool) -> [Data?] {
            loaded.items(
                forTurnId: turnId, sessionId: appSessionId, copilotSessionId: session.copilotSessionId,
                fromTools: fromTools
            ).map(\.data)
        }

        // 32 MiB in all and 4.5 MB an image. The prompt image is the oldest here and still loads,
        // because prompt images are served first; then tool images, newest turn first, until it runs out.
        XCTAssertEqual(images("turn-1", fromTools: false), [big])
        XCTAssertEqual(images("turn-3", fromTools: true), Array(repeating: Optional(big), count: 6))
        XCTAssertEqual(images("turn-2", fromTools: true), [nil, nil])
    }
}
