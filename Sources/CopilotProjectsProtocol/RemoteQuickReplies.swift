import CryptoKit
import Foundation

public struct QuickReplyItem: Codable, Equatable, Hashable, Identifiable, Sendable {
    public static let maxCount = 12
    public static let maxLabelLength = 24
    public static let maxPromptLength = 2_000
    public static let maxPromptUTF8Bytes = 8_192

    public let label: String
    public let prompt: String

    public var id: String { label.folding(options: .caseInsensitive, locale: nil) }

    public init(label: String, prompt: String) {
        self.label = label
        self.prompt = prompt
    }
}

public enum QuickReplyValidationError: Error, Equatable, Sendable {
    case emptyLabel
    case labelTooLong
    case emptyPrompt
    case promptTooLong
    case duplicateLabel(String)
    case tooManyReplies

    public var message: String {
        switch self {
        case .emptyLabel:
            return "Label cannot be empty."
        case .labelTooLong:
            return "Label must be \(QuickReplyItem.maxLabelLength) characters or fewer."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case .promptTooLong:
            return "Prompt must be \(QuickReplyItem.maxPromptLength) characters and \(QuickReplyItem.maxPromptUTF8Bytes) UTF-8 bytes or fewer."
        case .duplicateLabel(let label):
            return "A quick reply labeled “\(label)” already exists."
        case .tooManyReplies:
            return "You can configure at most \(QuickReplyItem.maxCount) quick replies."
        }
    }
}

public enum QuickReplyConfiguration: Equatable, Sendable {
    public static let storageKey = "quickReplyList"

    public static let defaultItems: [QuickReplyItem] = [
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

    public var isCustomized: Bool {
        if case .custom = self { return true }
        return false
    }

    public var customItems: [QuickReplyItem]? {
        if case .custom(let items) = self { return items }
        return nil
    }

    public var activeReplies: [QuickReplyItem] {
        switch self {
        case .defaultReplies:
            return Self.defaultItems
        case .custom(let items):
            return items
        }
    }

    /// Compact change token for `RemoteWorkspaceSnapshot.quickRepliesDigest`:
    /// `nil` when built-in defaults apply, or a 16-hex-character SHA-256 prefix
    /// over the validated custom list.
    public var digest: String? {
        guard case .custom(let items) = self else { return nil }
        return Self.digest(for: items)
    }

    public static func digest(for items: [QuickReplyItem]) -> String {
        var hash = SHA256()
        for item in items {
            for field in [item.label, item.prompt] {
                let bytes = Data(field.utf8)
                var length = UInt64(bytes.count).bigEndian
                withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
                hash.update(data: bytes)
            }
        }
        return hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func validateItem(
        label: String,
        prompt: String
    ) -> Result<QuickReplyItem, QuickReplyValidationError> {
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
        guard trimmedPrompt.count <= QuickReplyItem.maxPromptLength,
              trimmedPrompt.utf8.count <= QuickReplyItem.maxPromptUTF8Bytes else {
            return .failure(.promptTooLong)
        }
        return .success(QuickReplyItem(label: trimmedLabel, prompt: trimmedPrompt))
    }

    public static func validateList(
        _ items: [QuickReplyItem]
    ) -> Result<[QuickReplyItem], QuickReplyValidationError> {
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

    public static func resolved(fromJSON jsonString: String?) -> QuickReplyConfiguration {
        guard let data = jsonString?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([QuickReplyItem].self, from: data),
              case .success(let valid) = validateList(decoded) else {
            return .defaultReplies
        }
        return .custom(valid)
    }
}

/// Wire contract for shared quick replies (`GET /quick-replies` and `POST /quick-replies`).
/// A gateway advertises `capability` only when it routes `path` to a host with
/// `supportsQuickReplies == true`.
public enum RemoteQuickRepliesContract {
    public static let capability = RemoteProtocolInfo.sharedQuickReplies
    public static let path = "/quick-replies"
    public static let maximumPayloadBytes = 196_608
}

/// Host quick-reply state returned by `GET /quick-replies` and `POST /quick-replies`.
/// `items` is `nil` when no custom list is stored on the Mac (built-in defaults apply),
/// or the validated custom list (including `[]` when intentionally emptied).
public struct RemoteQuickRepliesState: Codable, Equatable, Sendable {
    public let items: [QuickReplyItem]?
    public let digest: String?

    public var isCustomized: Bool { items != nil }

    public init(items: [QuickReplyItem]? = nil) {
        self.items = items
        self.digest = items.map(QuickReplyConfiguration.digest(for:))
    }

    public init(configuration: QuickReplyConfiguration) {
        self.init(items: configuration.customItems)
    }

    public var configuration: QuickReplyConfiguration {
        guard let items,
              case .success(let valid) = QuickReplyConfiguration.validateList(items) else {
            return .defaultReplies
        }
        return .custom(valid)
    }
}

/// Request body for `POST /quick-replies`.
/// - Pass `items: [...]` to replace the stored custom list (latest write wins).
/// - Pass `items: nil` (`{"items":null}`) to reset to defaults for all clients.
/// - Pass `onlyIfUnset: true` with a non-nil `items` list for one-time client
///   migration so the host stores `items` only when no custom list is currently stored.
public struct RemoteQuickRepliesUpdateRequest: Codable, Equatable, Sendable {
    public let items: [QuickReplyItem]?
    public let onlyIfUnset: Bool?

    private enum CodingKeys: String, CodingKey {
        case items
        case onlyIfUnset
    }

    public init(items: [QuickReplyItem]?, onlyIfUnset: Bool? = nil) {
        self.items = items
        self.onlyIfUnset = onlyIfUnset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.items = try container.decode([QuickReplyItem]?.self, forKey: .items)
        self.onlyIfUnset = try container.decodeIfPresent(Bool.self, forKey: .onlyIfUnset)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encodeIfPresent(onlyIfUnset, forKey: .onlyIfUnset)
    }
}

public enum RemoteQuickRepliesUpdateOutcome: Equatable, Sendable {
    case updated(RemoteQuickRepliesState)
    case invalid(String)
    case payloadTooLarge
    case unsupported
    case unavailable(String)
}
