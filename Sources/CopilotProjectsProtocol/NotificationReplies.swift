import Foundation

/// How a client answers a notification without opening the session.
public enum RemoteNotificationReplyKind: String, Codable, Equatable, Sendable {
    /// Free-text follow-up sent as a native `session-send` prompt.
    case prompt
    /// An `ask_user` answer sent as `answer-user-input`.
    case userInput
    /// A single-field form answer sent as `answer-elicitation`.
    case elicitation
}

/// One selectable answer. `title` is what the user sees; `value` is submitted
/// verbatim, so a boolean field answers `.bool` and a labeled `oneOf` option
/// answers its `const` rather than its title.
public struct RemoteNotificationReplyChoice: Codable, Equatable, Sendable {
    public let title: String
    public let value: RemoteJSONValue

    public init(title: String, value: RemoteJSONValue) {
        self.title = title
        self.value = value
    }
}

/// Everything a client needs to answer a notification from its actions alone.
/// The host only attaches this when the session can accept the reply natively;
/// clients that don't understand it ignore it and keep tap-to-open behavior.
public struct RemoteNotificationReply: Codable, Equatable, Sendable {
    /// Notification action buttons beyond this are unreliable on Apple Watch.
    public static let maxChoices = 4
    public static let maxQuestionBytes = 1_024
    public static let maxChoiceTitleBytes = 256
    /// Budget for the encoded reply inside a 4 KB APNs payload that also
    /// carries the alert and routing keys.
    public static let maxEncodedBytes = 2_048

    public let kind: RemoteNotificationReplyKind
    /// The conversation this reply is fenced to; the host refuses it after a
    /// restart or `/clear`.
    public let conversationEpoch: String
    /// The question being answered. Nil for `.prompt`.
    public let requestId: String?
    public let question: String?
    public let choices: [RemoteNotificationReplyChoice]
    public let allowFreeform: Bool
    /// The single schema property an `.elicitation` answer fills.
    public let field: String?

    public init(
        kind: RemoteNotificationReplyKind,
        conversationEpoch: String,
        requestId: String? = nil,
        question: String? = nil,
        choices: [RemoteNotificationReplyChoice] = [],
        allowFreeform: Bool,
        field: String? = nil
    ) {
        self.kind = kind
        self.conversationEpoch = conversationEpoch
        self.requestId = requestId
        self.question = question
        self.choices = choices
        self.allowFreeform = allowFreeform
        self.field = field
    }

    public static func prompt(conversationEpoch: String) -> Self {
        Self(kind: .prompt, conversationEpoch: conversationEpoch, allowFreeform: true)
    }

    /// Whether the reply is internally consistent and representable as
    /// notification actions. Anything else must be dropped, never trimmed:
    /// a truncated choice would no longer match what the host validates.
    public var isValid: Bool {
        guard !conversationEpoch.isEmpty, conversationEpoch.utf8.count <= 256,
              choices.count <= Self.maxChoices,
              choices.allSatisfy({
                  !$0.title.isEmpty && $0.title.utf8.count <= Self.maxChoiceTitleBytes
              }),
              (question?.utf8.count ?? 0) <= Self.maxQuestionBytes,
              categoryIdentifier != nil else {
            return false
        }
        switch kind {
        case .prompt:
            return requestId == nil && choices.isEmpty && allowFreeform && field == nil
        case .userInput:
            return requestId?.isEmpty == false && field == nil
                && choices.allSatisfy {
                    if case .string(let value) = $0.value { return value == $0.title }
                    return false
                }
        case .elicitation:
            return requestId?.isEmpty == false && field?.isEmpty == false
        }
    }

    /// The notification category that exposes exactly these answers, or nil
    /// when there is nothing a notification action could submit.
    public var categoryIdentifier: String? {
        NotificationReplyContract.categoryIdentifier(
            choiceCount: choices.count,
            allowFreeform: allowFreeform
        )
    }

    /// The submitted value for a tapped choice action, if it's in range.
    public func choice(forActionIdentifier identifier: String) -> RemoteNotificationReplyChoice? {
        guard let index = NotificationReplyContract.choiceIndex(actionIdentifier: identifier),
              choices.indices.contains(index) else {
            return nil
        }
        return choices[index]
    }

    /// A copy whose question fits `maxEncodedBytes`, truncating only the
    /// display-only question text. Returns nil when the reply still can't fit
    /// or isn't valid.
    public func fitted(maxEncodedBytes: Int = Self.maxEncodedBytes) -> Self? {
        var candidate = self
        if let question, question.utf8.count > Self.maxQuestionBytes {
            candidate = candidate.with(
                question: Self.truncated(question, maxBytes: Self.maxQuestionBytes)
            )
        }
        guard candidate.isValid else { return nil }
        while let size = candidate.encodedSize, size > maxEncodedBytes {
            guard let question = candidate.question, !question.isEmpty else { return nil }
            let target = max(0, question.utf8.count - (size - maxEncodedBytes) - 3)
            candidate = candidate.with(
                question: target == 0 ? nil : Self.truncated(question, maxBytes: target)
            )
        }
        return candidate.encodedSize == nil ? nil : candidate
    }

    private var encodedSize: Int? {
        (try? JSONEncoder().encode(self))?.count
    }

    private func with(question: String?) -> Self {
        Self(
            kind: kind,
            conversationEpoch: conversationEpoch,
            requestId: requestId,
            question: question,
            choices: choices,
            allowFreeform: allowFreeform,
            field: field
        )
    }

    private static func truncated(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes else { return value }
        var result = ""
        var bytes = 0
        let ellipsis = "…"
        let limit = maxBytes - ellipsis.utf8.count
        for character in value {
            let size = String(character).utf8.count
            guard bytes + size <= limit else { break }
            result.append(character)
            bytes += size
        }
        return result + ellipsis
    }
}

/// Category and action identifiers shared by the host, gateway, iOS app, and
/// watch app. iOS categories are static, so each answer shape gets its own
/// category and the button count always matches the choices on offer.
public enum NotificationReplyContract {
    public static let replyKey = "reply"
    /// Free text only (follow-up prompts and open-ended questions).
    public static let textCategoryIdentifier = "copilot-projects.reply"
    public static let questionCategoryPrefix = "copilot-projects.question."
    public static let freeformSuffix = ".freeform"
    public static let choiceActionPrefix = "copilot-projects.choice."
    public static let textActionIdentifier = "copilot-projects.reply-text"

    public static func categoryIdentifier(choiceCount: Int, allowFreeform: Bool) -> String? {
        guard (0...RemoteNotificationReply.maxChoices).contains(choiceCount) else { return nil }
        if choiceCount == 0 {
            return allowFreeform ? textCategoryIdentifier : nil
        }
        return questionCategoryPrefix + String(choiceCount)
            + (allowFreeform ? freeformSuffix : "")
    }

    /// Every replyable category, for registration and watch scene binding.
    public static var allCategoryIdentifiers: [String] {
        var identifiers = [textCategoryIdentifier]
        for count in 1...RemoteNotificationReply.maxChoices {
            for freeform in [false, true] {
                if let identifier = categoryIdentifier(choiceCount: count, allowFreeform: freeform) {
                    identifiers.append(identifier)
                }
            }
        }
        return identifiers
    }

    /// The answer shape a category identifier encodes.
    public static func shape(categoryIdentifier: String) -> (choiceCount: Int, allowFreeform: Bool)? {
        if categoryIdentifier == textCategoryIdentifier { return (0, true) }
        guard categoryIdentifier.hasPrefix(questionCategoryPrefix) else { return nil }
        var rest = String(categoryIdentifier.dropFirst(questionCategoryPrefix.count))
        let allowFreeform = rest.hasSuffix(freeformSuffix)
        if allowFreeform { rest = String(rest.dropLast(freeformSuffix.count)) }
        guard let count = Int(rest), (1...RemoteNotificationReply.maxChoices).contains(count),
              String(count) == rest else {
            return nil
        }
        return (count, allowFreeform)
    }

    public static func choiceActionIdentifier(index: Int) -> String {
        choiceActionPrefix + String(index)
    }

    public static func choiceIndex(actionIdentifier: String) -> Int? {
        guard actionIdentifier.hasPrefix(choiceActionPrefix) else { return nil }
        let rest = actionIdentifier.dropFirst(choiceActionPrefix.count)
        guard let index = Int(rest), index >= 0, String(index) == rest else { return nil }
        return index
    }
}
