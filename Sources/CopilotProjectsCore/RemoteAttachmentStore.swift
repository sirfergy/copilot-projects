import CryptoKit
import Foundation
import ImageIO
import CopilotProjectsProtocol

public enum RemoteAttachmentError: Error, LocalizedError {
    case invalid, unsupportedImage, tooLarge, expired, conflict, full

    public var errorDescription: String? {
        switch self {
        case .invalid: "Invalid screenshot or conversation."
        case .unsupportedImage: "Choose a valid PNG or JPEG screenshot (up to 16 megapixels)."
        case .tooLarge: "Screenshot exceeds the 2 MB upload limit."
        case .expired: "Screenshot is missing or expired. Remove it and attach it again."
        case .conflict: "This upload ID already belongs to different content."
        case .full: "Screenshot storage is full. Try again after older uploads expire."
        }
    }
}

/// Immutable uploads: a metadata file is the commit marker. Readers never see
/// partially written bytes, and capacity pressure never evicts queued input.
public struct RemoteAttachmentStore: Sendable {
    public static let directoryName = "attachments-v1"
    private static let writeLock = NSLock()
    private static let maxTotalBytes = 128 * 1_024 * 1_024
    private static let maxEntries = 128
    public let root: URL

    private struct Record: Codable {
        let attachment: RemoteAttachment
        let sha256: String
    }

    public init(sessionsDirectory: URL = Paths.sessionsDir) {
        root = sessionsDirectory.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func store(
        _ data: Data, id: String, sessionId: String, conversationEpoch: String,
        now: Date = Date(), limits: RemoteImageCapabilities? = nil
    ) throws -> RemoteAttachment {
        guard RemoteAttachmentContract.validID(id),
              RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: conversationEpoch),
              !data.isEmpty else { throw RemoteAttachmentError.invalid }
        guard data.count <= RemoteAttachmentContract.maxBytes else { throw RemoteAttachmentError.tooLarge }
        Self.writeLock.lock()
        defer { Self.writeLock.unlock() }
        let mimeType = try Self.validateImage(data)
        if let limits {
            guard limits.isValid, data.count <= limits.maxBytes, limits.mimeTypes.contains(mimeType) else {
                throw RemoteAttachmentError.unsupportedImage
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw RemoteAttachmentError.invalid
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let metadataURL = root.appendingPathComponent("\(id).json")
        if fm.fileExists(atPath: metadataURL.path) {
            let existing = try record(id: id, sessionId: sessionId, conversationEpoch: conversationEpoch, now: now)
            guard existing.sha256 == digest else { throw RemoteAttachmentError.conflict }
            _ = try image(id: id, sessionId: sessionId, conversationEpoch: conversationEpoch, now: now)
            return existing.attachment
        }
        let usage = try cleanExpired(now: now)
        guard usage.count < Self.maxEntries, usage.bytes + data.count <= Self.maxTotalBytes else {
            throw RemoteAttachmentError.full
        }
        let attachment = RemoteAttachment(
            id: id, sessionId: sessionId, conversationEpoch: conversationEpoch,
            mimeType: mimeType, byteCount: data.count,
            expiresAtMilliseconds: Int64(now.addingTimeInterval(RemoteAttachmentContract.lifetime).timeIntervalSince1970 * 1_000)
        )
        let imageURL = root.appendingPathComponent("\(id).image")
        try data.write(to: imageURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)
        try JSONEncoder().encode(Record(attachment: attachment, sha256: digest))
            .write(to: metadataURL, options: [.atomic])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
        return attachment
    }

    public func image(
        id: String, sessionId: String, conversationEpoch: String, now: Date = Date()
    ) throws -> (RemoteAttachment, Data) {
        let record = try record(id: id, sessionId: sessionId, conversationEpoch: conversationEpoch, now: now)
        let data = try Self.readRegularFile(root.appendingPathComponent("\(id).image"), limit: RemoteAttachmentContract.maxBytes)
        guard data.count == record.attachment.byteCount,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.sha256 else {
            throw RemoteAttachmentError.invalid
        }
        return (record.attachment, data)
    }

    private func record(id: String, sessionId: String, conversationEpoch: String, now: Date) throws -> Record {
        guard RemoteAttachmentContract.validID(id),
              RemoteAttachmentContract.validScope(sessionId: sessionId, conversationEpoch: conversationEpoch) else {
            throw RemoteAttachmentError.invalid
        }
        let data = try Self.readRegularFile(root.appendingPathComponent("\(id).json"), limit: 4_096)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.attachment.id == id, record.attachment.sessionId == sessionId,
              record.attachment.conversationEpoch == conversationEpoch else { throw RemoteAttachmentError.conflict }
        guard record.attachment.isValid(at: now) else { throw RemoteAttachmentError.expired }
        return record
    }

    private static func readRegularFile(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= limit else { throw RemoteAttachmentError.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw RemoteAttachmentError.tooLarge }
        return data
    }

    private func cleanExpired(now: Date) throws -> (count: Int, bytes: Int) {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard RemoteAttachmentContract.validID(id) else { continue }
            let shouldRemove: Bool
            do {
                let data = try Self.readRegularFile(file, limit: 4_096)
                let record = try JSONDecoder().decode(Record.self, from: data)
                shouldRemove = record.attachment.expiresAtMilliseconds <= Int64(now.timeIntervalSince1970 * 1_000)
            } catch {
                NSLog("Removing an unreadable screenshot cache entry %@: %@", id, error.localizedDescription)
                shouldRemove = true
            }
            if shouldRemove {
                let image = root.appendingPathComponent("\(id).image")
                if fm.fileExists(atPath: image.path) { try fm.removeItem(at: image) }
                try fm.removeItem(at: file)
            }
        }
        var count = 0
        var bytes = 0
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            where file.pathExtension == "image" {
            let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let metadata = file.deletingPathExtension().appendingPathExtension("json")
            if !fm.fileExists(atPath: metadata.path),
               let date = values.contentModificationDate, now.timeIntervalSince(date) > 3_600 {
                try fm.removeItem(at: file)
            } else {
                count += 1
                bytes += values.fileSize ?? Self.maxTotalBytes
            }
        }
        return (count, bytes)
    }

    private static func validateImage(_ data: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1, CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384,
              width <= RemoteAttachmentContract.maxPixels / height,
              CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 64,
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil else { throw RemoteAttachmentError.unsupportedImage }
        return type == "public.png" ? "image/png" : "image/jpeg"
    }
}
