import Foundation

public enum RemoteAttachmentContract {
    public static let capability = "image-attachments-v1"
    public static let path = "attachments"
    public static let maxImages = 4
    public static let maxBytes = 2 * 1_024 * 1_024
    public static let maxPixels = 16_000_000
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60

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

    public init(
        id: String, sessionId: String, conversationEpoch: String,
        mimeType: String, byteCount: Int, expiresAtMilliseconds: Int64
    ) {
        self.id = id
        self.sessionId = sessionId
        self.conversationEpoch = conversationEpoch
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    public func isValid(at now: Date = Date()) -> Bool {
        RemoteAttachmentContract.validID(id)
            && RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: conversationEpoch)
            && ["image/png", "image/jpeg"].contains(mimeType)
            && byteCount > 0 && byteCount <= RemoteAttachmentContract.maxBytes
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
            && !mimeTypes.isEmpty && mimeTypes.allSatisfy { ["image/png", "image/jpeg"].contains($0) }
    }

    public func accepts(_ attachments: [RemoteAttachment], at now: Date = Date()) -> Bool {
        isValid && !attachments.isEmpty && attachments.count <= maxImages
            && Set(attachments.map(\.id)).count == attachments.count
            && attachments.allSatisfy {
                $0.isValid(at: now) && $0.byteCount <= maxBytes && mimeTypes.contains($0.mimeType)
            }
    }
}
