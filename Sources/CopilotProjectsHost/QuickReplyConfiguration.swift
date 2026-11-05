import Foundation

struct QuickReplyItem: Codable, Equatable, Identifiable, Sendable {
    static let maxCount = 12
    static let maxLabelLength = 24
    static let maxPromptLength = 2_000

    let label: String
    let prompt: String

    var id: String { label.folding(options: .caseInsensitive, locale: nil) }
}

enum QuickReplyValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case labelTooLong
    case emptyPrompt
    case promptTooLong
    case duplicateLabel(String)
    case tooManyReplies

    var message: String {
        switch self {
        case .emptyLabel:
            return "Label cannot be empty."
        case .labelTooLong:
            return "Label must be \(QuickReplyItem.maxLabelLength) characters or fewer."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case .promptTooLong:
            return "Prompt must be \(QuickReplyItem.maxPromptLength) characters or fewer."
        case .duplicateLabel(let label):
            return "A quick reply labeled “\(label)” already exists."
        case .tooManyReplies:
            return "You can configure at most \(QuickReplyItem.maxCount) quick replies."
        }
    }
}

enum QuickReplyConfiguration: Equatable, Sendable {
    static let storageKey = "quickReplyList"

    static let defaultItems: [QuickReplyItem] = [
        QuickReplyItem(label: "Approve", prompt: "Approve"),
        QuickReplyItem(label: "Post", prompt: "Post"),
        QuickReplyItem(label: "Merge when ready", prompt: "Merge when ready"),
        QuickReplyItem(label: "Request CCR", prompt: "Request CCR and when green mark ready"),
        QuickReplyItem(label: "Max review", prompt: "Do a max review"),
        QuickReplyItem(label: "Keep going", prompt: "Keep going!"),
        QuickReplyItem(label: "No bloat?", prompt: "No bloat or over-engineering?"),
    ]

    case defaultReplies
    case custom([QuickReplyItem])

    var isCustomized: Bool {
        if case .custom = self { return true }
        return false
    }

    var activeReplies: [QuickReplyItem] {
        switch self {
        case .defaultReplies:
            return Self.defaultItems
        case .custom(let items):
            return items
        }
    }

    static func validateItem(label: String, prompt: String) -> Result<QuickReplyItem, QuickReplyValidationError> {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            return .failure(.emptyLabel)
        }
        guard trimmedLabel.count <= QuickReplyItem.maxLabelLength else {
            return .failure(.labelTooLong)
        }
        guard !trimmedPrompt.isEmpty else {
            return .failure(.emptyPrompt)
        }
        guard trimmedPrompt.count <= QuickReplyItem.maxPromptLength else {
            return .failure(.promptTooLong)
        }
        return .success(QuickReplyItem(label: trimmedLabel, prompt: trimmedPrompt))
    }

    static func validateList(_ items: [QuickReplyItem]) -> Result<[QuickReplyItem], QuickReplyValidationError> {
        guard items.count <= QuickReplyItem.maxCount else {
            return .failure(.tooManyReplies)
        }
        var normalized: [QuickReplyItem] = []
        normalized.reserveCapacity(items.count)
        var seenLabels = Set<String>()
        for item in items {
            switch validateItem(label: item.label, prompt: item.prompt) {
            case .failure(let error):
                return .failure(error)
            case .success(let validItem):
                guard seenLabels.insert(validItem.id).inserted else {
                    return .failure(.duplicateLabel(validItem.label))
                }
                normalized.append(validItem)
            }
        }
        return .success(normalized)
    }

    static func resolved(fromJSON jsonString: String?) -> QuickReplyConfiguration {
        guard let data = jsonString?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([QuickReplyItem].self, from: data),
              case .success(let valid) = validateList(decoded) else {
            return .defaultReplies
        }
        return .custom(valid)
    }

    static func load(from defaults: UserDefaults) -> QuickReplyConfiguration {
        resolved(fromJSON: defaults.string(forKey: storageKey))
    }

    @discardableResult
    static func save(
        _ items: [QuickReplyItem],
        to defaults: UserDefaults
    ) -> Result<[QuickReplyItem], QuickReplyValidationError> {
        switch validateList(items) {
        case .failure(let error):
            return .failure(error)
        case .success(let validated):
            guard let data = try? JSONEncoder().encode(validated),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(.emptyLabel)
            }
            defaults.set(json, forKey: storageKey)
            return .success(validated)
        }
    }

    static func reset(in defaults: UserDefaults) {
        defaults.removeObject(forKey: storageKey)
    }
}
