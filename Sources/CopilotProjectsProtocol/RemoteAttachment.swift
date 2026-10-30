import Foundation

public enum RemoteAttachmentContract {
    public static let capability = "image-attachments-v1"
    public static let fileCapability = "file-attachments-v1"
    public static let path = "attachments"
    public static let maxImages = 4
    public static let maxAttachments = maxImages
    public static let maxBytes = 2 * 1_024 * 1_024
    public static let maxTextBytes = 512 * 1_024
    public static let maxPixels = 16_000_000
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

    public static let imageMimeTypes: Set<String> = ["image/png", "image/jpeg"]

    public static let textMimeTypes: Set<String> = [
        "application/json",
        "application/x-json5",
        "text/markdown",
        "text/plain",
        "text/csv",
        "text/xml",
        "text/html",
        "text/css",
        "application/x-yaml",
        "application/x-toml",
        "application/x-graphql",
        "text/javascript",
        "application/javascript",
        "application/typescript",
        "text/x-typescript",
        "text/x-python",
        "text/x-swift",
        "text/x-c++",
        "text/x-csharp",
        "text/x-go",
        "text/x-java",
        "text/x-ruby",
        "text/x-rust",
        "text/x-sh",
        "text/x-shellscript",
        "text/x-sql",
        "text/x-diff",
        "text/x-patch",
    ]

    public static let supportedMimeTypes: Set<String> = imageMimeTypes.union(textMimeTypes)

    public static let extensionToTextMimeType: [String: String] = [
        "json": "application/json",
        "json5": "application/x-json5",
        "md": "text/markdown",
        "markdown": "text/markdown",
        "txt": "text/plain",
        "log": "text/plain",
        "text": "text/plain",
        "conf": "text/plain",
        "ini": "text/plain",
        "csv": "text/csv",
        "tsv": "text/csv",
        "xml": "text/xml",
        "plist": "text/xml",
        "yaml": "application/x-yaml",
        "yml": "application/x-yaml",
        "toml": "application/x-toml",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "mjs": "text/javascript",
        "cjs": "text/javascript",
        "jsx": "text/javascript",
        "ts": "application/typescript",
        "mts": "application/typescript",
        "cts": "application/typescript",
        "tsx": "application/typescript",
        "py": "text/x-python",
        "swift": "text/x-swift",
        "c": "text/x-c++",
        "h": "text/x-c++",
        "cc": "text/x-c++",
        "cpp": "text/x-c++",
        "cxx": "text/x-c++",
        "hpp": "text/x-c++",
        "m": "text/x-c++",
        "mm": "text/x-c++",
        "cs": "text/x-csharp",
        "go": "text/x-go",
        "java": "text/x-java",
        "rb": "text/x-ruby",
        "rs": "text/x-rust",
        "sh": "text/x-sh",
        "bash": "text/x-sh",
        "zsh": "text/x-sh",
        "sql": "text/x-sql",
        "graphql": "application/x-graphql",
        "gql": "application/x-graphql",
        "diff": "text/x-diff",
        "patch": "text/x-patch",
    ]

    private static let textMimeTypeAliases: [String: String] = [
        "application/xml": "text/xml",
        "application/toml": "application/x-toml",
        "application/yaml": "application/x-yaml",
        "text/yaml": "application/x-yaml",
        "text/x-yaml": "application/x-yaml",
        "text/json": "application/json",
        "text/x-markdown": "text/markdown",
    ]

    public static func isImageMimeType(_ mimeType: String) -> Bool {
        imageMimeTypes.contains(mimeType)
    }

    public static func isTextMimeType(_ mimeType: String) -> Bool {
        textMimeTypes.contains(mimeType)
    }

    public static func canonicalTextMimeType(forExtension ext: String) -> String? {
        extensionToTextMimeType[ext.lowercased()]
    }

    public static func canonicalTextMimeType(forMimeType mimeType: String) -> String? {
        let normalized = mimeType.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if textMimeTypes.contains(normalized) {
            return normalized
        }
        return textMimeTypeAliases[normalized]
    }

    public static func validDisplayName(_ name: String) -> Bool {
        let utf8Count = name.utf8.count
        guard (1...128).contains(utf8Count),
              name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
              !name.hasPrefix(".") else {
            return false
        }
        let forbiddenScalars: Set<UnicodeScalar> = ["/", "\\", "\"", "'", "<", ">", "&"]
        return name.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f && !forbiddenScalars.contains(scalar)
        }
    }

    public static func sanitizeDisplayName(_ rawName: String, fallbackMimeType: String? = nil) -> String? {
        let basename = URL(fileURLWithPath: rawName).lastPathComponent
        let forbiddenScalars: Set<UnicodeScalar> = ["/", "\\", "\"", "'", "<", ">", "&"]
        var cleanedScalars: [UnicodeScalar] = []
        for scalar in basename.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7f || forbiddenScalars.contains(scalar) {
                cleanedScalars.append("_")
            } else {
                cleanedScalars.append(scalar)
            }
        }
        var candidate = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while candidate.hasPrefix(".") {
            candidate.removeFirst()
        }
        candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.utf8.count > 128 {
            let ext = URL(fileURLWithPath: candidate).pathExtension
            let suffix = ext.isEmpty ? "" : ".\(ext.prefix(16))"
            let maxStemBytes = max(1, 128 - suffix.utf8.count)
            var stem = ext.isEmpty ? candidate : URL(fileURLWithPath: candidate).deletingPathExtension().lastPathComponent
            while stem.utf8.count > maxStemBytes && !stem.isEmpty {
                stem.removeLast()
            }
            candidate = (stem.isEmpty ? "attachment" : stem) + suffix
        }
        if validDisplayName(candidate) {
            return candidate
        }
        guard let fallbackMimeType else { return nil }
        let fallback = defaultDisplayName(forMimeType: fallbackMimeType)
        return validDisplayName(fallback) ? fallback : nil
    }

    public static func defaultDisplayName(forMimeType mimeType: String) -> String {
        switch mimeType {
        case "image/png": return "Screenshot.png"
        case "image/jpeg": return "Screenshot.jpg"
        case "application/json": return "attachment.json"
        case "application/x-json5": return "attachment.json5"
        case "text/markdown": return "attachment.md"
        case "text/csv": return "attachment.csv"
        case "text/xml": return "attachment.xml"
        case "text/html": return "attachment.html"
        case "text/css": return "attachment.css"
        case "application/x-yaml": return "attachment.yaml"
        case "application/x-toml": return "attachment.toml"
        case "application/x-graphql": return "attachment.graphql"
        case "text/javascript", "application/javascript": return "attachment.js"
        case "application/typescript", "text/x-typescript": return "attachment.ts"
        case "text/x-python": return "attachment.py"
        case "text/x-swift": return "attachment.swift"
        case "text/x-c++": return "attachment.cpp"
        case "text/x-csharp": return "attachment.cs"
        case "text/x-go": return "attachment.go"
        case "text/x-java": return "attachment.java"
        case "text/x-ruby": return "attachment.rb"
        case "text/x-rust": return "attachment.rs"
        case "text/x-sh", "text/x-shellscript": return "attachment.sh"
        case "text/x-sql": return "attachment.sql"
        case "text/x-diff": return "attachment.diff"
        case "text/x-patch": return "attachment.patch"
        default: return "attachment.txt"
        }
    }

    public static func validateTextData(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxTextBytes else { return nil }
        if data.count >= 2 {
            let prefix2 = Array(data.prefix(2))
            if prefix2 == [0xFF, 0xFE] || prefix2 == [0xFE, 0xFF] {
                return nil
            }
        }
        let stripped: Data
        if data.count >= 3 && Array(data.prefix(3)) == [0xEF, 0xBB, 0xBF] {
            stripped = Data(data.dropFirst(3))
        } else {
            stripped = data
        }
        guard !stripped.isEmpty, !stripped.contains(0),
              let text = String(data: stripped, encoding: .utf8),
              text.range(of: #"<\s*/\s*attachment\b"#, options: [.regularExpression, .caseInsensitive]) == nil else {
            return nil
        }
        return stripped
    }

    public static func accepts(
        _ attachments: [RemoteAttachment],
        capabilities: [String],
        imageLimits: RemoteImageCapabilities?,
        at now: Date = Date()
    ) -> Bool {
        guard !attachments.isEmpty,
              attachments.count <= maxAttachments,
              Set(attachments.map(\.id)).count == attachments.count,
              attachments.allSatisfy({ $0.isValid(at: now) }) else {
            return false
        }
        let images = attachments.filter(\.isImage)
        let texts = attachments.filter { !$0.isImage }
        if !texts.isEmpty && !capabilities.contains(fileCapability) {
            return false
        }
        if !images.isEmpty {
            guard capabilities.contains(capability),
                  let imageLimits,
                  imageLimits.accepts(images, at: now) else {
                return false
            }
        }
        return true
    }

    public static func validID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    public static func validScope(sessionId: String, conversationEpoch: String) -> Bool {
        UUID(uuidString: sessionId) != nil
            && !conversationEpoch.isEmpty && conversationEpoch.utf8.count <= 512
            && conversationEpoch.unicodeScalars.allSatisfy { (0x21...0x7e).contains($0.value) }
    }
}

public struct RemoteAttachment: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let sessionId: String
    public let conversationEpoch: String
    public let mimeType: String
    public let byteCount: Int
    public let expiresAtMilliseconds: Int64
    public let displayName: String?

    public init(
        id: String, sessionId: String, conversationEpoch: String,
        mimeType: String, byteCount: Int, expiresAtMilliseconds: Int64,
        displayName: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.conversationEpoch = conversationEpoch
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.expiresAtMilliseconds = expiresAtMilliseconds
        self.displayName = displayName
    }

    public var isImage: Bool {
        RemoteAttachmentContract.isImageMimeType(mimeType)
    }

    public func isValid(at now: Date = Date()) -> Bool {
        let maxAllowedBytes = isImage ? RemoteAttachmentContract.maxBytes : RemoteAttachmentContract.maxTextBytes
        return RemoteAttachmentContract.validID(id)
            && RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: conversationEpoch)
            && RemoteAttachmentContract.supportedMimeTypes.contains(mimeType)
            && byteCount > 0 && byteCount <= maxAllowedBytes
            && (displayName.map(RemoteAttachmentContract.validDisplayName) ?? true)
            && expiresAtMilliseconds > Int64(now.timeIntervalSince1970 * 1_000)
    }
}

public struct RemoteImageCapabilities: Codable, Equatable, Sendable {
    public let maxImages: Int
    public let maxBytes: Int
    public let mimeTypes: [String]

    public init(maxImages: Int, maxBytes: Int, mimeTypes: [String]) {
        self.maxImages = maxImages
        self.maxBytes = maxBytes
        self.mimeTypes = mimeTypes
    }

    public var isValid: Bool {
        (1...RemoteAttachmentContract.maxImages).contains(maxImages)
            && (1...RemoteAttachmentContract.maxBytes).contains(maxBytes)
            && !mimeTypes.isEmpty && mimeTypes.allSatisfy { RemoteAttachmentContract.isImageMimeType($0) }
    }

    public func accepts(_ attachments: [RemoteAttachment], at now: Date = Date()) -> Bool {
        isValid && !attachments.isEmpty && attachments.count <= maxImages
            && Set(attachments.map(\.id)).count == attachments.count
            && attachments.allSatisfy {
                $0.isValid(at: now) && $0.isImage && $0.byteCount <= maxBytes && mimeTypes.contains($0.mimeType)
            }
    }
}
