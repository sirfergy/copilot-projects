import Foundation
import CopilotProjectsProtocol

/// Chooses how a remote notification can be answered from its actions alone.
/// Every reply mirrors what the host itself would accept for the same
/// snapshot, so a client never offers an answer that is bound to be refused.
enum NotificationReplyResolver {
    static let syntheticRequestPrefix = "synthetic::durable-ask-user::"
    /// `answerUserInput`/`answerElicitation` refuse longer request ids.
    static let maxRequestIdBytes = 200
    /// The gateway cuts APNs alert bodies at 1,500 bytes including its
    /// "Sent at" suffix; staying under this keeps numbered choices whole.
    static let maxNotificationBodyBytes = 1_400
    /// Keys that don't constrain a string, so any typed text the host accepts
    /// for the choice set also satisfies the field.
    private static let unconstrainedStringKeys: Set<String> = [
        "type", "enum", "oneOf", "title", "description", "default",
    ]

    struct PendingQuestion: Equatable {
        /// What the agent asked, for the notification body.
        let text: String
        let reply: RemoteNotificationReply?

        /// The question preview followed by numbered choices. iPhone action
        /// buttons can only say "Option N", so the body names what each means.
        /// Only the preview is shortened to fit; the choices always stay whole.
        var notificationBody: String? {
            let preview = NotificationSummary.preview(text)
            guard let choices = reply?.choices, !choices.isEmpty else { return preview }
            let numbered = choices.enumerated()
                .map { "\($0.offset + 1). \($0.element.title)" }
                .joined(separator: "\n")
            let budget = NotificationReplyResolver.maxNotificationBodyBytes
                - numbered.utf8.count - 1
            guard let preview, let fitted = Self.truncated(preview, maxBytes: budget) else {
                return numbered
            }
            return fitted + "\n" + numbered
        }

        private static func truncated(_ value: String, maxBytes: Int) -> String? {
            guard value.utf8.count > maxBytes else { return value }
            let ellipsis = "\u{2026}"
            var prefix = ""
            var bytes = 0
            for character in value {
                let size = String(character).utf8.count
                guard bytes + size <= maxBytes - ellipsis.utf8.count else { break }
                prefix.append(character)
                bytes += size
            }
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed + ellipsis
        }
    }

    /// A follow-up prompt reply when a native `session-send` would be accepted now.
    static func completionReply(
        snapshot: AgentActivitySnapshot,
        now: Date = Date()
    ) -> RemoteNotificationReply? {
        let projection = snapshot.remoteOperationProjection(at: now)
        guard projection.support == .receipts,
              let epoch = projection.conversationEpoch,
              let workflow = snapshot.workflow,
              workflow.supports(.send, at: now),
              workflow.sendReady,
              !snapshot.hasPendingInput else {
            return nil
        }
        return RemoteNotificationReply.prompt(conversationEpoch: epoch).fitted()
    }

    /// The question a waiting session is blocked on: the oldest `ask_user`,
    /// otherwise the oldest elicitation. Only a lone elicitation gets a reply,
    /// so a tapped answer can't land on a different form.
    static func pendingQuestion(
        in snapshot: AgentActivitySnapshot,
        now: Date = Date()
    ) -> PendingQuestion? {
        let epoch = snapshot.remoteOperationProjection(at: now).conversationEpoch
        let userInputs = (snapshot.trackedUserInputs ?? [])
            .filter { !$0.requestId.hasPrefix(syntheticRequestPrefix) }
        if let input = oldest(userInputs, requestedAt: \.requestedAt) {
            return PendingQuestion(
                text: input.question,
                reply: epoch.flatMap { userInputReply(input, conversationEpoch: $0) }
            )
        }
        let elicitations = snapshot.trackedElicitations ?? []
        guard let elicitation = oldest(elicitations, requestedAt: \.requestedAt) else {
            return nil
        }
        return PendingQuestion(
            text: elicitation.message,
            reply: elicitations.count == 1
                ? epoch.flatMap { elicitationReply(elicitation, conversationEpoch: $0) }
                : nil
        )
    }

    static func userInputReply(
        _ input: TrackedUserInput,
        conversationEpoch: String
    ) -> RemoteNotificationReply? {
        guard isAnswerable(requestId: input.requestId) else { return nil }
        let choices: [RemoteNotificationReplyChoice]
        if input.choices.count > RemoteNotificationReply.maxChoices {
            // Too many buttons for a watch; typed answers still work if allowed.
            guard input.allowFreeform else { return nil }
            choices = []
        } else {
            choices = input.choices.map { .init(title: $0, value: .string($0)) }
        }
        return RemoteNotificationReply(
            kind: .userInput,
            conversationEpoch: conversationEpoch,
            requestId: input.requestId,
            question: input.question.isEmpty ? nil : input.question,
            choices: choices,
            allowFreeform: input.allowFreeform
        ).fitted()
    }

    /// A reply for a form with exactly one string-choice or boolean field.
    static func elicitationReply(
        _ request: TrackedElicitation,
        conversationEpoch: String
    ) -> RemoteNotificationReply? {
        guard isAnswerable(requestId: request.requestId),
              request.mode == nil || request.mode == "form",
              request.url == nil,
              case .object(let root)? = request.schema,
              case .object(let properties)? = root["properties"],
              properties.count == 1,
              let (field, fieldValue) = properties.first,
              case .object(let fieldSchema) = fieldValue,
              fieldSchema["anyOf"] == nil else {
            return nil
        }
        // Mirrors answerElicitation, which accepts a typed answer to a string
        // choice set only when the request has no elicitationSource.
        let acceptsFreeformStrings = request.elicitationSource == nil
        // Typed text must also satisfy length, pattern, or format rules the
        // host enforces, which a notification text field can't promise.
        let acceptsUnconstrainedText = acceptsFreeformStrings
            && Set(fieldSchema.keys).isSubset(of: unconstrainedStringKeys)
        let choices: [RemoteNotificationReplyChoice]
        let allowFreeform: Bool
        switch (fieldSchema["type"], fieldSchema["enum"], fieldSchema["oneOf"]) {
        case (.string("boolean")?, nil, nil):
            choices = [
                .init(title: "Yes", value: .bool(true)),
                .init(title: "No", value: .bool(false)),
            ]
            allowFreeform = false
        case (.string("string")?, .array(let values)?, nil):
            guard let strings = stringValues(values) else { return nil }
            choices = strings.map { .init(title: $0, value: .string($0)) }
            allowFreeform = acceptsUnconstrainedText
        case (.string("string")?, nil, .array(let options)?):
            guard let labeled = labeledConstants(options) else { return nil }
            choices = labeled.map { .init(title: $0.title, value: .string($0.value)) }
            allowFreeform = acceptsUnconstrainedText
        default:
            return nil
        }
        guard (1...RemoteNotificationReply.maxChoices).contains(choices.count),
              choices.allSatisfy({ choice in
                  let content = [field: choice.value]
                  return AppModel.isValidElicitationContent(content)
                      && AppModel.elicitationContent(
                          content,
                          satisfies: request.schema,
                          allowFreeformStringChoices: acceptsFreeformStrings
                      )
              }) else {
            return nil
        }
        return RemoteNotificationReply(
            kind: .elicitation,
            conversationEpoch: conversationEpoch,
            requestId: request.requestId,
            question: request.message.isEmpty ? nil : request.message,
            choices: choices,
            allowFreeform: allowFreeform,
            field: field
        ).fitted()
    }

    private static func isAnswerable(requestId: String) -> Bool {
        !requestId.isEmpty
            && requestId.utf8.count <= maxRequestIdBytes
            && !requestId.hasPrefix(syntheticRequestPrefix)
    }

    private static func oldest<Element>(
        _ elements: [Element],
        requestedAt: KeyPath<Element, String>
    ) -> Element? {
        func date(_ value: String) -> Date {
            (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                ?? (try? Date.ISO8601FormatStyle().parse(value))
                ?? .distantFuture
        }
        return elements.enumerated().min { lhs, rhs in
            (date(lhs.element[keyPath: requestedAt]), lhs.offset)
                < (date(rhs.element[keyPath: requestedAt]), rhs.offset)
        }?.element
    }

    private static func stringValues(_ values: [RemoteJSONValue]) -> [String]? {
        var strings: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            strings.append(string)
        }
        return strings
    }

    private static func labeledConstants(
        _ options: [RemoteJSONValue]
    ) -> [(title: String, value: String)]? {
        var labeled: [(title: String, value: String)] = []
        for option in options {
            guard case .object(let object) = option,
                  case .string(let value)? = object["const"] else { return nil }
            var title = value
            if case .string(let label)? = object["title"], !label.isEmpty {
                title = label
            }
            labeled.append((title, value))
        }
        return labeled
    }
}
