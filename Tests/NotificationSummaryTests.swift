import AppKit
import XCTest
@testable import copilot_projects
import CopilotProjectsCore
import CopilotProjectsProtocol

final class NotificationSummaryTests: XCTestCase {
    private let copilotSessionId = "completed-conversation"

    private func turn(
        id: String = "turn",
        startedAt: TimeInterval = 1,
        endedAt: TimeInterval? = 4,
        kind: String = "foreground",
        content: String? = "Fixed **notification previews**. All done.",
        messageAt: TimeInterval = 3,
        aborted: Bool = false
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map(Date.init(timeIntervalSince1970:)),
            kind: kind,
            userContent: "Do not use the user's request as a completion summary",
            assistantMessages: content.map {
                [TranscriptAssistantMessage(
                    id: "answer", timestamp: Date(timeIntervalSince1970: messageAt), content: $0
                )]
            } ?? [],
            tools: [TranscriptTool(id: "tool", name: "bash", title: "Run tests", success: true)],
            isAborted: aborted
        )
    }

    private func snapshot(_ turns: [TranscriptTurn], sessionId: String? = nil) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(timeIntervalSince1970: 5),
            copilotSessionId: sessionId ?? copilotSessionId,
            turns: turns
        )
    }

    private func context() throws -> CompletionSummaryContext {
        try XCTUnwrap(CompletionSummaryContext(
            copilotSessionId: copilotSessionId,
            activeTimestamp: 2_000,
            completionTimestamp: 4_500
        ))
    }

    func testPreviewStripsMarkdownAndCodeWithoutJoiningWords() {
        XCTAssertEqual(NotificationSummary.preview("""
        ## Result

        Fixed **previews** in `AppModel.swift`. See [details](https://example.com/private).

        ```swift
        let secret = "not notification content"
        ```

        - Mac notifications
        - Phone notifications
        """), "Result Fixed previews in AppModel.swift. See details. Mac notifications Phone notifications")
        XCTAssertEqual(NotificationSummary.preview("Hello\t world\n\nNext sentence."), "Hello world Next sentence.")
        XCTAssertNil(NotificationSummary.preview("\n \t"))
        XCTAssertNil(NotificationSummary.preview("```\ncode only\n```"))
    }

    func testPreviewIsBoundedByCharactersAndUTF8AtWordBoundaries() throws {
        let long = String(repeating: "Finished the implementation. ", count: 100)
        let preview = try XCTUnwrap(NotificationSummary.preview(long))
        XCTAssertLessThanOrEqual(preview.count, 320)
        XCTAssertLessThanOrEqual(preview.utf8.count, 1_000)
        XCTAssertTrue(preview.hasSuffix("implementation.\u{2026}") || preview.hasSuffix("the\u{2026}") || preview.hasSuffix("Finished\u{2026}"))
        let emoji = try XCTUnwrap(NotificationSummary.preview(String(repeating: "\u{1F469}\u{200D}\u{1F4BB}", count: 500)))
        XCTAssertLessThanOrEqual(emoji.utf8.count, 1_000)
        XCTAssertTrue(emoji.hasSuffix("\u{2026}"))
        XCTAssertTrue(emoji.dropLast().allSatisfy { $0 == "\u{1F469}\u{200D}\u{1F4BB}" })
        XCTAssertNil(NotificationSummary.preview(String(repeating: "**a**", count: 1_000)))
    }

    func testCompletionMatchesLongTurnNotJustTurnsStartingAfterLastTool() throws {
        XCTAssertEqual(
            NotificationSummary.completion(from: snapshot([turn()]), context: try context()),
            "Fixed notification previews. All done."
        )
        XCTAssertNotNil(NotificationSummary.completion(
            from: snapshot([turn(kind: "automated")]), context: try context()
        ))
    }

    func testCompletionRejectsStaleNewScheduledAbortedAndEmptyTurns() throws {
        let context = try context()
        for invalid in [
            turn(endedAt: 2),
            turn(startedAt: 5, endedAt: 6, messageAt: 5.5),
            turn(endedAt: nil),
            turn(kind: "scheduled"),
            turn(kind: "resume"),
            turn(content: nil),
            turn(content: ""),
            turn(messageAt: 5),
            turn(aborted: true),
        ] {
            XCTAssertNil(NotificationSummary.completion(
                from: snapshot([turn(id: "older"), invalid]), context: context
            ), "must not fall back to older content for \(invalid)")
        }
        XCTAssertNil(NotificationSummary.completion(
            from: snapshot([turn()], sessionId: "different-conversation"), context: context
        ))
        XCTAssertNil(CompletionSummaryContext(
            copilotSessionId: nil, activeTimestamp: 2_000, completionTimestamp: 4_500
        ))
        XCTAssertNil(CompletionSummaryContext(
            copilotSessionId: copilotSessionId, activeTimestamp: 5_000, completionTimestamp: 4_500
        ))
    }

    func testSnapshotFlushIsRetriedButMissingContentIsBounded() async throws {
        let pending = snapshot([turn(endedAt: nil)])
        let finished = snapshot([turn()])
        let source = SnapshotSource([pending, finished])
        let result = await NotificationSummary.loadCompletion(
            sessionId: "tab", context: try context(), loadSnapshot: { source.load($0) }
        )
        XCTAssertEqual(result, "Fixed notification previews. All done.")
        XCTAssertEqual(source.count, 2)
        let missing = SnapshotSource([snapshot([])])
        let absent = await NotificationSummary.loadCompletion(
            sessionId: "tab", context: try context(), loadSnapshot: { missing.load($0) }
        )
        XCTAssertNil(absent)
        XCTAssertEqual(missing.count, 3)
    }

    @MainActor
    func testCompletionBodyLoadsRealTranscriptAndKeepsRoutingAndTime() async throws {
        let session = Session(title: "Build previews", cwd: "/tmp")
        Paths.ensureStateDir()
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot([turn()])).write(to: URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: session.id)
        ), options: .atomic)
        let model = try model(session: session)
        let spy = NotificationSpy()
        let posted = expectation(description: "summary posted")
        spy.onPost = { posted.fulfill() }
        model.attach(notifications: spy)
        complete(model, session: session)
        XCTAssertTrue(model.projects[0].sessions[0].turnCompleted)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        await fulfillment(of: [posted], timeout: 3)
        let event = try XCTUnwrap(spy.events.first)
        XCTAssertEqual(event.body, "Fixed notification previews. All done.")
        XCTAssertEqual(event.subtitle, "Project \u{00B7} Build previews")
        XCTAssertEqual(event.sessionId, session.id)
        XCTAssertEqual(event.projectId, model.projects[0].id)
        XCTAssertEqual(event.kind, .completed)
        XCTAssertTrue(event.displayedBody.hasPrefix("Fixed notification previews. All done.\nSent at "))
        XCTAssertEqual(event.webBody, "Project \u{00B7} Build previews\nFixed notification previews. All done.")
        XCTAssertLessThan(abs(event.sentAt.timeIntervalSinceNow), 5)
    }

    @MainActor
    func testNewTurnDuringReadCannotContaminateOrDuplicateFrozenAlert() async throws {
        let session = Session(title: "Original title", cwd: "/tmp")
        let entered = expectation(description: "background reader entered")
        let gate = DispatchSemaphore(value: 0)
        let capturedSnapshot = snapshot([turn()])
        let model = try model(session: session, loader: { _ in
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return capturedSnapshot
        })
        let spy = NotificationSpy()
        let posted = expectation(description: "original alert posted once")
        spy.onPost = { posted.fulfill() }
        model.attach(notifications: spy)
        complete(model, session: session)
        await fulfillment(of: [entered], timeout: 3)
        // Duplicate completion must not launch a second reader.
        model.setStatus(sessionId: session.id, status: .idle, text: nil,
                        timestamp: 4_500, source: "session-idle",
                        copilotSessionId: copilotSessionId, notification: .completed)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 5_000)
        gate.signal()
        await fulfillment(of: [posted], timeout: 3)
        XCTAssertEqual(spy.events.count, 1)
        XCTAssertNil(spy.events[0].body)
        XCTAssertEqual(spy.events[0].subtitle, "Project \u{00B7} Original title")
        XCTAssertFalse(model.projects[0].sessions[0].turnCompleted)
    }

    @MainActor
    func testClosingSessionDuringReadPreservesClaimedGenericAlert() async throws {
        let session = Session(title: "Closed task", cwd: "/tmp")
        let entered = expectation(description: "reader entered")
        let gate = DispatchSemaphore(value: 0)
        let capturedSnapshot = snapshot([turn()])
        let model = try model(session: session, loader: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return capturedSnapshot
        })
        let spy = NotificationSpy()
        let posted = expectation(description: "claimed alert preserved")
        spy.onPost = { posted.fulfill() }
        model.attach(notifications: spy)
        complete(model, session: session)
        await fulfillment(of: [entered], timeout: 3)
        model.closeSession(projectId: model.projects[0].id, sessionId: session.id)
        gate.signal()
        await fulfillment(of: [posted], timeout: 3)
        XCTAssertEqual(spy.events.count, 1)
        XCTAssertNil(spy.events[0].body)
        XCTAssertEqual(spy.events[0].sessionId, session.id)
        XCTAssertEqual(spy.events[0].subtitle, "Project \u{00B7} Closed task")
    }

    @MainActor
    func testAgentStopThenSessionIdlePreservesOriginalActiveBoundary() async throws {
        let session = Session(title: "Two signals", cwd: "/tmp")
        let source = SnapshotSource([snapshot([turn()])])
        let model = try model(session: session, loader: { source.load($0) })
        let spy = NotificationSpy()
        let posted = expectation(description: "one summarized completion")
        spy.onPost = { posted.fulfill() }
        model.attach(notifications: spy)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 2_000)
        model.setStatus(sessionId: session.id, status: .idle, text: nil,
                        timestamp: 4_000, source: "agent-stop", copilotSessionId: copilotSessionId)
        model.setStatus(sessionId: session.id, status: .idle, text: nil,
                        timestamp: 4_500, source: "session-idle",
                        copilotSessionId: copilotSessionId, notification: .completed)
        await fulfillment(of: [posted], timeout: 3)
        XCTAssertEqual(spy.events.count, 1)
        XCTAssertEqual(spy.events[0].body, "Fixed notification previews. All done.")
        XCTAssertEqual(source.count, 1)
    }

    @MainActor
    private func model(
        session: Session,
        loader: @escaping @Sendable (String) -> TranscriptSnapshot = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        }
    ) throws -> AppModel {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let project = Project(name: "Project", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        return AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            completionTranscriptLoader: loader,
            isAppActive: { false }
        )
    }

    @MainActor
    private func complete(_ model: AppModel, session: Session) {
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 2_000)
        model.setStatus(sessionId: session.id, status: .idle, text: nil,
                        timestamp: 4_500, source: "session-idle",
                        copilotSessionId: copilotSessionId, notification: .completed)
    }

    @MainActor
    private final class NotificationSpy: NotificationPosting {
        var events: [NotificationEvent] = []
        var onPost: (() -> Void)?
        func post(_ event: NotificationEvent) {
            events.append(event)
            onPost?()
        }
    }

    private final class SnapshotSource: @unchecked Sendable {
        private let lock = NSLock()
        private let snapshots: [TranscriptSnapshot]
        private var reads = 0
        init(_ snapshots: [TranscriptSnapshot]) { self.snapshots = snapshots }
        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return reads
        }
        func load(_ sessionId: String) -> TranscriptSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let snapshot = snapshots[min(reads, snapshots.count - 1)]
            reads += 1
            return snapshot
        }
    }
}
