import AppKit
import Combine
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

        let shotsDir = ProcessInfo.processInfo.environment["TRANSCRIPT_IMAGE_SHOTS_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let shotsDir {
            try FileManager.default.createDirectory(at: shotsDir, withIntermediateDirectories: true)
        }
        defer {
            UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
        }

        let specs: [(name: String, appearance: NSAppearance.Name, width: CGFloat, fullWidth: Bool)] = [
            ("drawer-420-light", .aqua, 420, false),
            ("drawer-420-dark", .darkAqua, 420, false),
            ("full-width-light", .aqua, 960, true),
            ("full-width-dark", .darkAqua, 960, true),
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
                "Hosted TranscriptDrawer (\(spec.name)) must render the decoded prompt PNG pixels"
            )
            let pngData = try XCTUnwrap(renderedBitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(pngData.count, 5_000)
            if let shotsDir {
                try pngData.write(to: shotsDir.appendingPathComponent("\(spec.name).png"))
            }

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
                "Hosted TranscriptDrawer (\(spec.name)) must visibly render the missing attachment's Image unavailable placeholder in turn 2"
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

    private static func makeSolidPNG(width: Int, height: Int, color: NSColor) throws -> Data {
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
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
