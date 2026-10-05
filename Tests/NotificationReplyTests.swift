import XCTest
import CopilotProjectsProtocol

final class NotificationReplyTests: XCTestCase {
    private func decodePayload(_ json: String) throws -> RemoteNotificationPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RemoteNotificationPayload.self, from: Data(json.utf8))
    }

    func testPayloadRoundTripsReply() throws {
        let reply = RemoteNotificationReply(
            kind: .elicitation,
            conversationEpoch: "epoch-1",
            requestId: "req-1",
            question: "Ship it?",
            choices: [
                .init(title: "Yes", value: .bool(true)),
                .init(title: "No", value: .bool(false)),
            ],
            allowFreeform: false,
            field: "confirm"
        )
        let payload = RemoteNotificationPayload(
            id: UUID(),
            kind: .elicitation,
            title: "Copilot has a question",
            body: "Ship it?",
            projectId: "p",
            sessionId: "s",
            sentAt: Date(timeIntervalSince1970: 1_800_000_000),
            reply: reply
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            RemoteNotificationPayload.self,
            from: encoder.encode(payload)
        )
        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.reply?.choices.first?.value, .bool(true))
    }

    func testPayloadWithoutReplyDecodesAsTapToOpen() throws {
        let payload = try decodePayload("""
        {"id":"\(UUID().uuidString)","title":"t","body":"b","sentAt":"2026-07-13T05:45:00Z"}
        """)
        XCTAssertNil(payload.reply)
    }

    func testUnusableReplyIsDroppedWithoutFailingThePayload() throws {
        let payload = try decodePayload("""
        {"id":"\(UUID().uuidString)","title":"t","body":"b","sentAt":"2026-07-13T05:45:00Z",
         "reply":{"kind":"future-kind","conversationEpoch":"e","choices":[],"allowFreeform":true}}
        """)
        XCTAssertNil(payload.reply)
        XCTAssertEqual(payload.title, "t")
    }

    func testCategoryMatchesAnswerShape() {
        XCTAssertEqual(
            RemoteNotificationReply.prompt(conversationEpoch: "e").categoryIdentifier,
            NotificationReplyContract.textCategoryIdentifier
        )
        XCTAssertEqual(
            NotificationReplyContract.categoryIdentifier(choiceCount: 2, allowFreeform: false),
            "copilot-projects.question.2"
        )
        XCTAssertEqual(
            NotificationReplyContract.categoryIdentifier(choiceCount: 4, allowFreeform: true),
            "copilot-projects.question.4.freeform"
        )
        XCTAssertNil(NotificationReplyContract.categoryIdentifier(choiceCount: 0, allowFreeform: false))
        XCTAssertNil(NotificationReplyContract.categoryIdentifier(choiceCount: 5, allowFreeform: true))
        XCTAssertEqual(NotificationReplyContract.allCategoryIdentifiers.count, 9)
        for identifier in NotificationReplyContract.allCategoryIdentifiers {
            let shape = NotificationReplyContract.shape(categoryIdentifier: identifier)
            XCTAssertNotNil(shape, identifier)
            XCTAssertEqual(
                shape.flatMap {
                    NotificationReplyContract.categoryIdentifier(
                        choiceCount: $0.choiceCount, allowFreeform: $0.allowFreeform
                    )
                },
                identifier
            )
        }
        XCTAssertNil(NotificationReplyContract.shape(categoryIdentifier: "copilot-projects.synced"))
        XCTAssertNil(NotificationReplyContract.shape(categoryIdentifier: "copilot-projects.question.02"))
    }

    func testChoiceActionsMapOnlyToOfferedChoices() {
        let reply = RemoteNotificationReply(
            kind: .userInput,
            conversationEpoch: "e",
            requestId: "r",
            question: "Pick",
            choices: [.init(title: "A", value: .string("A")), .init(title: "B", value: .string("B"))],
            allowFreeform: true
        )
        XCTAssertTrue(reply.isValid)
        XCTAssertEqual(
            reply.choice(forActionIdentifier: NotificationReplyContract.choiceActionIdentifier(index: 1))?.value,
            .string("B")
        )
        XCTAssertNil(reply.choice(forActionIdentifier: NotificationReplyContract.choiceActionIdentifier(index: 2)))
        XCTAssertNil(reply.choice(forActionIdentifier: NotificationReplyContract.textActionIdentifier))
        XCTAssertNil(reply.choice(forActionIdentifier: "copilot-projects.choice.-1"))
    }

    func testValidityRejectsInconsistentReplies() {
        XCTAssertFalse(RemoteNotificationReply(
            kind: .prompt, conversationEpoch: "", allowFreeform: true
        ).isValid)
        XCTAssertFalse(RemoteNotificationReply(
            kind: .userInput, conversationEpoch: "e", requestId: "r",
            choices: [.init(title: "Label", value: .string("other"))], allowFreeform: false
        ).isValid, "ask_user answers must be the verbatim choice text")
        XCTAssertFalse(RemoteNotificationReply(
            kind: .elicitation, conversationEpoch: "e", requestId: "r",
            choices: [.init(title: "Yes", value: .bool(true))], allowFreeform: false
        ).isValid, "elicitation replies name the field they fill")
        XCTAssertFalse(RemoteNotificationReply(
            kind: .userInput, conversationEpoch: "e", requestId: "r",
            choices: [], allowFreeform: false
        ).isValid, "nothing to submit")
        XCTAssertFalse(RemoteNotificationReply(
            kind: .userInput, conversationEpoch: "e", requestId: "r",
            choices: (0..<5).map { .init(title: "\($0)", value: .string("\($0)")) },
            allowFreeform: false
        ).isValid)
    }

    func testFittingTruncatesOnlyTheQuestion() throws {
        let longQuestion = String(repeating: "é", count: 3_000)
        let choices = (0..<4).map {
            RemoteNotificationReplyChoice(title: "Choice \($0)", value: .string("Choice \($0)"))
        }
        let reply = RemoteNotificationReply(
            kind: .userInput, conversationEpoch: "e", requestId: "r",
            question: longQuestion, choices: choices, allowFreeform: true
        )
        let fitted = try XCTUnwrap(reply.fitted(maxEncodedBytes: 600))
        XCTAssertEqual(fitted.choices, choices)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, 600)
        XCTAssertTrue(fitted.question?.hasSuffix("…") == true)

        let tooBig = RemoteNotificationReply(
            kind: .userInput, conversationEpoch: "e", requestId: "r",
            question: "q",
            choices: (0..<4).map {
                let title = String(repeating: "x", count: 250) + "\($0)"
                return .init(title: title, value: .string(title))
            },
            allowFreeform: false
        )
        XCTAssertNil(tooBig.fitted(maxEncodedBytes: 600), "choices are never trimmed")
    }
}
