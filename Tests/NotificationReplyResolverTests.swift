import XCTest
import AppKit
@testable import CopilotProjectsHost
import CopilotProjectsProtocol

final class NotificationReplyResolverTests: XCTestCase {
    private let copilotSessionId = "11111111-2222-3333-4444-555555555555"
    private let epoch = "11111111-2222-3333-4444-555555555555:1"

    private func snapshot(
        at date: Date = Date(),
        receipts: Bool = true,
        userInputs: [TrackedUserInput]? = nil,
        elicitations: [TrackedElicitation]? = nil,
        pendingPermissionRequestIds: [String]? = [],
        workflow: RemoteSessionWorkflow? = nil,
        conversationEpoch: String? = nil
    ) -> AgentActivitySnapshot {
        var snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: date.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: userInputs,
            trackedElicitations: elicitations,
            pendingPermissionRequestIds: pendingPermissionRequestIds
        )
        if receipts {
            snapshot.copilotSessionId = copilotSessionId
            snapshot.conversationEpoch = conversationEpoch ?? epoch
            snapshot.operationReceiptVersion = 1
        }
        snapshot.workflow = workflow
        return snapshot
    }

    private func workflow(
        at date: Date = Date(),
        capabilities: [String] = [RemoteSessionActionKind.send.rawValue],
        sendReady: Bool = true
    ) -> RemoteSessionWorkflow {
        RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(date.timeIntervalSince1970 * 1_000),
            capabilities: capabilities,
            sendReady: sendReady
        )
    }

    private func askUser(
        _ requestId: String = "ask-1",
        question: String = "Which database?",
        choices: [String] = ["Postgres", "SQLite"],
        allowFreeform: Bool = true,
        requestedAt: String = "2026-10-05T10:00:00.000Z"
    ) -> TrackedUserInput {
        TrackedUserInput(
            requestId: requestId,
            question: question,
            choices: choices,
            allowFreeform: allowFreeform,
            requestedAt: requestedAt,
            agentId: nil
        )
    }

    private func elicitation(
        _ requestId: String = "form-1",
        message: String = "Ship it?",
        mode: String? = nil,
        url: String? = nil,
        properties: [String: RemoteJSONValue],
        required: [String]? = nil,
        source: String? = nil,
        requestedAt: String = "2026-10-05T10:00:00.000Z"
    ) -> TrackedElicitation {
        var root: [String: RemoteJSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if let required {
            root["required"] = .array(required.map(RemoteJSONValue.string))
        }
        return TrackedElicitation(
            requestId: requestId,
            message: message,
            mode: mode,
            url: url,
            schema: .object(root),
            elicitationSource: source,
            requestedAt: requestedAt,
            agentId: nil
        )
    }

    private func field(_ entries: [String: RemoteJSONValue]) -> RemoteJSONValue {
        .object(entries)
    }

    private func reply(
        _ snapshot: AgentActivitySnapshot
    ) -> RemoteNotificationReply? {
        NotificationReplyResolver.pendingQuestion(in: snapshot)?.reply
    }

    // MARK: - ask_user

    func testOldestAskUserOffersVerbatimStringChoices() throws {
        let question = try XCTUnwrap(NotificationReplyResolver.pendingQuestion(in: snapshot(
            userInputs: [
                askUser("newer", question: "Later?", requestedAt: "2026-10-05T10:00:05.000Z"),
                askUser("older", requestedAt: "2026-10-05T10:00:01.000Z"),
            ],
            elicitations: [elicitation(properties: [
                "ok": field(["type": .string("boolean")]),
            ])]
        )))

        XCTAssertEqual(question.text, "Which database?")
        let reply = try XCTUnwrap(question.reply)
        XCTAssertEqual(reply, RemoteNotificationReply(
            kind: .userInput,
            conversationEpoch: epoch,
            requestId: "older",
            question: "Which database?",
            choices: [
                .init(title: "Postgres", value: .string("Postgres")),
                .init(title: "SQLite", value: .string("SQLite")),
            ],
            allowFreeform: true
        ))
        XCTAssertEqual(reply.categoryIdentifier, "copilot-projects.question.2.freeform")
        XCTAssertEqual(question.notificationBody, "Which database?\n1. Postgres\n2. SQLite")
    }

    func testBodyOmitsChoicesWhenTheyCannotBeTapped() {
        let unanswerable = NotificationReplyResolver.PendingQuestion(text: "Which **database**?", reply: nil)
        XCTAssertEqual(unanswerable.notificationBody, "Which database?")
        let freeText = NotificationReplyResolver.PendingQuestion(
            text: "Anything else?",
            reply: RemoteNotificationReply(
                kind: .userInput, conversationEpoch: "e", requestId: "r",
                question: "Anything else?", allowFreeform: true
            )
        )
        XCTAssertEqual(freeText.notificationBody, "Anything else?")
    }

    func testAskUserWithTooManyChoicesFallsBackToFreeTextOnly() throws {
        let five = ["a", "b", "c", "d", "e"]
        let freeform = try XCTUnwrap(reply(snapshot(userInputs: [
            askUser(choices: five, allowFreeform: true),
        ])))
        XCTAssertEqual(freeform.choices, [])
        XCTAssertTrue(freeform.allowFreeform)
        XCTAssertEqual(freeform.categoryIdentifier, NotificationReplyContract.textCategoryIdentifier)

        let closed = NotificationReplyResolver.pendingQuestion(in: snapshot(userInputs: [
            askUser(choices: five, allowFreeform: false),
        ]))
        XCTAssertEqual(closed?.text, "Which database?")
        XCTAssertNil(closed?.reply)

        let fourClosed = try XCTUnwrap(reply(snapshot(userInputs: [
            askUser(choices: ["a", "b", "c", "d"], allowFreeform: false),
        ])))
        XCTAssertEqual(fourClosed.choices.count, 4)
        XCTAssertEqual(fourClosed.categoryIdentifier, "copilot-projects.question.4")
    }

    func testAskUserRepliesThatCannotBeRepresentedAreDropped() {
        XCTAssertNil(reply(snapshot(userInputs: [
            askUser(choices: [String(repeating: "x", count: 300)]),
        ])))
        XCTAssertNil(reply(snapshot(userInputs: [
            askUser(choices: [], allowFreeform: false),
        ])))
        XCTAssertNil(reply(snapshot(userInputs: [
            askUser(String(repeating: "r", count: 201)),
        ])))
        XCTAssertNil(reply(snapshot(userInputs: [
            askUser("synthetic::durable-ask-user::call"),
        ])))
    }

    func testLongQuestionIsTruncatedButStillReplyable() throws {
        let long = String(repeating: "word ", count: 600)
        let reply = try XCTUnwrap(reply(snapshot(userInputs: [askUser(question: long)])))
        XCTAssertLessThanOrEqual(
            reply.question?.utf8.count ?? 0,
            RemoteNotificationReply.maxQuestionBytes
        )
        XCTAssertLessThanOrEqual(
            try JSONEncoder().encode(reply).count,
            RemoteNotificationReply.maxEncodedBytes
        )
    }

    // MARK: - elicitation

    func testBooleanFieldAnswersBooleansAndNeverFreeText() throws {
        let reply = try XCTUnwrap(reply(snapshot(elicitations: [
            elicitation(properties: ["confirm": field(["type": .string("boolean")])]),
        ])))
        XCTAssertEqual(reply.kind, .elicitation)
        XCTAssertEqual(reply.requestId, "form-1")
        XCTAssertEqual(reply.field, "confirm")
        XCTAssertEqual(reply.question, "Ship it?")
        XCTAssertEqual(reply.choices, [
            .init(title: "Yes", value: .bool(true)),
            .init(title: "No", value: .bool(false)),
        ])
        XCTAssertFalse(reply.allowFreeform)
    }

    func testStringEnumTrueStaysAString() throws {
        let reply = try XCTUnwrap(reply(snapshot(elicitations: [
            elicitation(
                properties: ["answer": field([
                    "type": .string("string"),
                    "enum": .array([.string("true"), .string("false")]),
                ])],
                required: ["answer"]
            ),
        ])))
        XCTAssertEqual(reply.choices, [
            .init(title: "true", value: .string("true")),
            .init(title: "false", value: .string("false")),
        ])
        XCTAssertTrue(reply.allowFreeform)
    }

    func testOneOfShowsTitlesButSubmitsConstants() throws {
        let reply = try XCTUnwrap(reply(snapshot(elicitations: [
            elicitation(properties: ["env": field([
                "type": .string("string"),
                "oneOf": .array([
                    .object(["const": .string("prod"), "title": .string("Production")]),
                    .object(["const": .string("stage")]),
                    .object(["const": .string("dev"), "title": .string("")]),
                ]),
            ])]),
        ])))
        XCTAssertEqual(reply.choices, [
            .init(title: "Production", value: .string("prod")),
            .init(title: "stage", value: .string("stage")),
            .init(title: "dev", value: .string("dev")),
        ])
    }

    func testFreeTextFollowsTheHostsElicitationSourceRule() throws {
        let properties: [String: RemoteJSONValue] = ["pick": field([
            "type": .string("string"),
            "enum": .array([.string("a"), .string("b")]),
        ])]
        let local = try XCTUnwrap(reply(snapshot(elicitations: [
            elicitation(properties: properties),
        ])))
        XCTAssertTrue(local.allowFreeform)
        let sourced = try XCTUnwrap(reply(snapshot(elicitations: [
            elicitation(properties: properties, source: "github-mcp"),
        ])))
        XCTAssertFalse(sourced.allowFreeform)
        XCTAssertEqual(sourced.categoryIdentifier, "copilot-projects.question.2")
    }

    func testUnsupportedElicitationsGetNoReply() {
        let boolean: [String: RemoteJSONValue] = ["ok": field(["type": .string("boolean")])]
        let enumField = { (count: Int) -> [String: RemoteJSONValue] in
            ["pick": self.field([
                "type": .string("string"),
                "enum": .array((0..<count).map { .string("option \($0)") }),
            ])]
        }
        let cases: [(String, TrackedElicitation)] = [
            ("synthetic", elicitation(
                "synthetic::durable-ask-user::call", mode: "terminal-default", properties: boolean
            )),
            ("terminal default", elicitation(mode: "terminal-default", properties: boolean)),
            ("url mode", elicitation(mode: "url", properties: boolean)),
            ("url", elicitation(url: "https://example.com", properties: boolean)),
            ("two fields", elicitation(properties: [
                "ok": field(["type": .string("boolean")]),
                "why": field(["type": .string("string")]),
            ])),
            ("too many choices", elicitation(properties: enumField(5))),
            ("plain string", elicitation(properties: ["why": field(["type": .string("string")])])),
            ("number", elicitation(properties: ["n": field([
                "type": .string("number"), "enum": .array([.number(1), .number(2)]),
            ])])),
            ("anyOf", elicitation(properties: ["pick": field([
                "type": .string("string"),
                "anyOf": .array([.object(["const": .string("a")])]),
            ])])),
            ("enum and oneOf", elicitation(properties: ["pick": field([
                "type": .string("string"),
                "enum": .array([.string("a")]),
                "oneOf": .array([.object(["const": .string("a")])]),
            ])])),
            ("mixed enum", elicitation(properties: ["pick": field([
                "type": .string("string"), "enum": .array([.string("a"), .number(1)]),
            ])])),
            ("host would refuse", elicitation(properties: ["pick": field([
                "type": .string("string"),
                "maxLength": .number(3),
                "enum": .array([.string("short"), .string("ok")]),
            ])])),
            ("unknown required", elicitation(properties: boolean, required: ["missing"])),
        ]
        for (name, request) in cases {
            XCTAssertNil(reply(snapshot(elicitations: [request])), name)
        }
        XCTAssertNotNil(reply(snapshot(elicitations: [
            elicitation(mode: "form", properties: enumField(4)),
        ])))
    }

    func testOnlyALoneElicitationIsReplyable() {
        let boolean: [String: RemoteJSONValue] = ["ok": field(["type": .string("boolean")])]
        let question = NotificationReplyResolver.pendingQuestion(in: snapshot(elicitations: [
            elicitation("second", message: "Second?", properties: boolean,
                        requestedAt: "2026-10-05T10:00:09.000Z"),
            elicitation("first", message: "First?", properties: boolean,
                        requestedAt: "2026-10-05T10:00:01.000Z"),
        ]))
        XCTAssertEqual(question?.text, "First?")
        XCTAssertNil(question?.reply)
    }

    func testQuestionsWithoutReceiptSupportKeepTextButGetNoReply() {
        let question = NotificationReplyResolver.pendingQuestion(in: snapshot(
            receipts: false,
            userInputs: [askUser()]
        ))
        XCTAssertEqual(question?.text, "Which database?")
        XCTAssertNil(question?.reply)
        XCTAssertNil(NotificationReplyResolver.pendingQuestion(in: snapshot()))
    }

    // MARK: - completion

    func testCompletionReplyRequiresANativeSendThatWouldBeAccepted() {
        XCTAssertEqual(
            NotificationReplyResolver.completionReply(snapshot: snapshot(workflow: workflow())),
            .prompt(conversationEpoch: epoch)
        )
        let refused: [(String, AgentActivitySnapshot)] = [
            ("legacy tracker", snapshot(receipts: false, workflow: workflow())),
            ("no workflow", snapshot()),
            ("not send ready", snapshot(workflow: workflow(sendReady: false))),
            ("no send capability", snapshot(workflow: workflow(capabilities: []))),
            ("stale workflow", snapshot(workflow: workflow(at: Date().addingTimeInterval(-60)))),
            ("stale snapshot", snapshot(at: Date().addingTimeInterval(-60), workflow: workflow())),
            ("pending question", snapshot(userInputs: [askUser()], workflow: workflow())),
            ("pending permission", snapshot(
                pendingPermissionRequestIds: ["permission"], workflow: workflow()
            )),
        ]
        for (name, snapshot) in refused {
            XCTAssertNil(NotificationReplyResolver.completionReply(snapshot: snapshot), name)
        }
    }
}

// MARK: - AppModel wiring

final class NotificationReplyWiringTests: XCTestCase {
    private let copilotSessionId = "11111111-2222-3333-4444-555555555555"
    private let epoch = "11111111-2222-3333-4444-555555555555:1"

    @MainActor
    private final class NotificationSpy: NotificationPosting {
        var events: [NotificationEvent] = []
        var onPost: ((NotificationEvent) -> Void)?
        func post(_ event: NotificationEvent) {
            events.append(event)
            onPost?(event)
        }
    }

    private struct Harness {
        let sessions: URL
        let session: Session
        let model: AppModel
        let spy: NotificationSpy
    }

    @MainActor
    private func makeHarness(
        retryDelays: [UInt64] = [5_000_000, 5_000_000],
        loader: @escaping @Sendable (String) -> TranscriptSnapshot = { _ in
            TranscriptSnapshot(schemaVersion: 3, updatedAt: Date(), copilotSessionId: "other", turns: [])
        }
    ) throws -> Harness {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "Replies", cwd: root.path)
        let project = Project(name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 1_000_000,
            completionTranscriptLoader: loader,
            elicitationReplyRetryDelaysNanoseconds: retryDelays,
            persistPermissionStatus: { _, _, _, _ in },
            isAppActive: { false },
            agentActivityDirectory: sessions,
            resumeMarkerDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            )
        )
        let spy = NotificationSpy()
        model.attach(notifications: spy)
        try Data(copilotSessionId.utf8).write(
            to: sessions.appendingPathComponent("\(session.id).copilot-session")
        )
        return Harness(sessions: sessions, session: session, model: model, spy: spy)
    }

    private func write(
        _ harness: Harness,
        receipts: Bool = true,
        epoch: String? = nil,
        userInputs: [TrackedUserInput]? = nil,
        workflow: RemoteSessionWorkflow? = nil
    ) throws {
        var snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: Date().ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: userInputs,
            pendingPermissionRequestIds: []
        )
        if receipts {
            snapshot.copilotSessionId = copilotSessionId
            snapshot.conversationEpoch = epoch ?? self.epoch
            snapshot.operationReceiptVersion = 1
        }
        snapshot.workflow = workflow
        try JSONEncoder().encode(snapshot).write(
            to: harness.sessions.appendingPathComponent("\(harness.session.id).agent-activity.json"),
            options: .atomic
        )
    }

    private func writeInputWait(_ harness: Harness, epoch: String, timestamp: Int64) throws {
        let record = SessionStatusRecord(
            status: .waiting,
            statusTimestamp: timestamp,
            promptStatusTimestamp: timestamp,
            inputWait: InputWaitContext(
                senderSessionId: copilotSessionId,
                rootSessionId: copilotSessionId,
                conversationEpoch: epoch
            )
        )
        try JSONEncoder().encode(record).write(
            to: harness.sessions.appendingPathComponent("\(harness.session.id).status-record.json"),
            options: .atomic
        )
    }

    private let question = TrackedUserInput(
        requestId: "ask-1",
        question: "Use **Postgres** or SQLite?",
        choices: ["Postgres", "SQLite"],
        allowFreeform: false,
        requestedAt: "2026-10-05T10:00:00.000Z",
        agentId: nil
    )

    @MainActor
    private func ask(_ harness: Harness, timestamp: Int64 = 100) {
        harness.model.setStatus(
            sessionId: harness.session.id,
            status: .waiting,
            text: nil,
            timestamp: timestamp,
            copilotSessionId: copilotSessionId,
            notification: .elicitation
        )
    }

    private func settle(_ nanoseconds: UInt64 = 60_000_000) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    // MARK: elicitation

    @MainActor
    func testQuestionAlreadyInTheSnapshotPostsImmediatelyWithReply() throws {
        let harness = try makeHarness()
        try writeInputWait(harness, epoch: epoch, timestamp: 100)
        try write(harness, userInputs: [question])
        ask(harness)

        let event = try XCTUnwrap(harness.spy.events.first)
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertEqual(event.kind, .elicitation)
        XCTAssertEqual(event.title, StatusNotificationKind.elicitation.title)
        XCTAssertEqual(event.body, "Use Postgres or SQLite?\n1. Postgres\n2. SQLite")
        XCTAssertEqual(event.reply?.kind, .userInput)
        XCTAssertEqual(event.reply?.requestId, "ask-1")
        XCTAssertEqual(event.reply?.conversationEpoch, epoch)
        XCTAssertEqual(event.reply?.choices.map(\.title), ["Postgres", "SQLite"])
        XCTAssertTrue(harness.model.projects[0].sessions[0].hasUnread)
    }

    @MainActor
    func testSessionsWithoutAReplyCapableTrackerPostImmediatelyAsBefore() throws {
        let missing = try makeHarness()
        ask(missing)
        XCTAssertEqual(missing.spy.events.count, 1)
        XCTAssertNil(missing.spy.events.first?.reply)
        XCTAssertNil(missing.spy.events.first?.body)

        let legacy = try makeHarness()
        try write(legacy, receipts: false, userInputs: [question])
        ask(legacy)
        XCTAssertEqual(legacy.spy.events.count, 1)
        XCTAssertNil(legacy.spy.events.first?.reply)
    }

    @MainActor
    func testQuestionPublishedAfterTheHookIsFoundByRetry() async throws {
        let harness = try makeHarness(retryDelays: [30_000_000, 30_000_000, 30_000_000])
        try write(harness)
        let posted = expectation(description: "question posted")
        harness.spy.onPost = { _ in posted.fulfill() }
        ask(harness)
        XCTAssertTrue(harness.spy.events.isEmpty)

        try write(harness, userInputs: [question])
        await fulfillment(of: [posted], timeout: 2)
        XCTAssertEqual(harness.spy.events.first?.reply?.requestId, "ask-1")
        await settle(150_000_000)
        XCTAssertEqual(harness.spy.events.count, 1)
    }

    @MainActor
    func testRetriesEndWithOnePlainNotification() async throws {
        let harness = try makeHarness(retryDelays: [5_000_000, 5_000_000, 5_000_000])
        try write(harness)
        let posted = expectation(description: "fallback posted")
        harness.spy.onPost = { _ in posted.fulfill() }
        ask(harness)
        await fulfillment(of: [posted], timeout: 2)
        await settle()
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertNil(harness.spy.events[0].reply)
        XCTAssertNil(harness.spy.events[0].body)
    }

    @MainActor
    func testLeavingWaitingCancelsThePendingNotification() async throws {
        let harness = try makeHarness(retryDelays: [20_000_000, 20_000_000])
        try write(harness)
        ask(harness)
        harness.model.setStatus(
            sessionId: harness.session.id, status: .running, text: nil, timestamp: 101
        )
        try write(harness, userInputs: [question])
        await settle(120_000_000)
        XCTAssertTrue(harness.spy.events.isEmpty)
    }

    @MainActor
    func testLaterWaitingStatusDoesNotDropTheNotification() async throws {
        let harness = try makeHarness(retryDelays: [20_000_000, 20_000_000])
        try write(harness)
        let posted = expectation(description: "question posted")
        harness.spy.onPost = { _ in posted.fulfill() }
        ask(harness)
        // A second question while already waiting arrives without a notification.
        harness.model.setStatus(
            sessionId: harness.session.id, status: .waiting, text: nil, timestamp: 101
        )
        try write(harness, userInputs: [question])
        await fulfillment(of: [posted], timeout: 2)
        await settle()
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertNotNil(harness.spy.events[0].reply)
    }

    @MainActor
    func testNewerHookSupersedesAnEarlierPendingOne() async throws {
        let harness = try makeHarness(retryDelays: [20_000_000, 20_000_000])
        try write(harness)
        let posted = expectation(description: "one notification for the newer hook")
        harness.spy.onPost = { _ in posted.fulfill() }
        ask(harness, timestamp: 100)
        ask(harness, timestamp: 101)
        await fulfillment(of: [posted], timeout: 2)
        await settle(100_000_000)
        XCTAssertEqual(harness.spy.events.count, 1)
    }

    @MainActor
    func testChangedConversationPostsWithoutReply() throws {
        let harness = try makeHarness(retryDelays: [1_000_000_000])
        try writeInputWait(harness, epoch: "\(copilotSessionId):0", timestamp: 100)
        try write(harness, userInputs: [question])
        ask(harness)
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertNil(harness.spy.events[0].reply)
        XCTAssertNil(harness.spy.events[0].body)
    }

    // MARK: completion

    @MainActor
    private func complete(_ harness: Harness, summaryContext: Bool) {
        harness.model.setStatus(
            sessionId: harness.session.id, status: .running, text: nil, timestamp: 2_000
        )
        harness.model.setStatus(
            sessionId: harness.session.id, status: .idle, text: nil, timestamp: 4_500,
            source: "session-idle",
            copilotSessionId: summaryContext ? copilotSessionId : nil,
            notification: .completed
        )
    }

    private func readyWorkflow(sendReady: Bool = true) -> RemoteSessionWorkflow {
        RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: [RemoteSessionActionKind.send.rawValue],
            sendReady: sendReady
        )
    }

    @MainActor
    func testCompletionOffersAFollowUpPromptWhenSendIsReady() async throws {
        let harness = try makeHarness()
        try write(harness, workflow: readyWorkflow())
        let posted = expectation(description: "completion posted")
        harness.spy.onPost = { _ in posted.fulfill() }
        complete(harness, summaryContext: true)
        await fulfillment(of: [posted], timeout: 3)
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertEqual(harness.spy.events[0].kind, .completed)
        XCTAssertEqual(harness.spy.events[0].reply, .prompt(conversationEpoch: epoch))

        let immediate = try makeHarness()
        try write(immediate, workflow: readyWorkflow())
        complete(immediate, summaryContext: false)
        XCTAssertEqual(immediate.spy.events.first?.reply, .prompt(conversationEpoch: epoch))
    }

    @MainActor
    func testCompletionWithoutSendReadinessHasNoReply() throws {
        let harness = try makeHarness()
        try write(harness, workflow: readyWorkflow(sendReady: false))
        complete(harness, summaryContext: false)
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertNil(harness.spy.events[0].reply)
    }

    @MainActor
    func testCompletionSupersededDuringSummaryLoadHasNoReply() async throws {
        let entered = expectation(description: "summary loading")
        entered.assertForOverFulfill = false
        let gate = DispatchSemaphore(value: 0)
        let harness = try makeHarness(loader: { _ in
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 3)
            return TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Date(), copilotSessionId: "other", turns: []
            )
        })
        try write(harness, workflow: readyWorkflow())
        let posted = expectation(description: "completion posted")
        harness.spy.onPost = { _ in posted.fulfill() }
        complete(harness, summaryContext: true)
        await fulfillment(of: [entered], timeout: 3)
        harness.model.setStatus(
            sessionId: harness.session.id, status: .running, text: nil, timestamp: 5_000
        )
        // The summary loader retries; release every attempt.
        for _ in 0..<3 { gate.signal() }
        await fulfillment(of: [posted], timeout: 3)
        XCTAssertEqual(harness.spy.events.count, 1)
        XCTAssertNil(harness.spy.events[0].reply)
    }
}
