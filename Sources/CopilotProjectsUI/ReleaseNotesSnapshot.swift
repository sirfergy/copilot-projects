import Foundation

public struct ReleaseNotesSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let repository: String
    public let version: String
    public let build: String
    public let sourceRevision: String
    public let markdown: String
    public let plainText: String

    public var displayVersion: String {
        version == build ? version : "\(version) (\(build))"
    }

    public var releasesURL: URL? {
        URL(string: "https://github.com/\(repository)/releases")
    }

    public static func load(bundle: Bundle = .main) throws -> ReleaseNotesSnapshot? {
        guard let url = bundle.url(forResource: "release-notes", withExtension: "json") else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 256 * 1024 else { throw ReleaseNotesError.invalidDocument }
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
            throw ReleaseNotesError.versionMismatch
        }
        try snapshot.validate(version: version, build: build)
        return snapshot
    }

    public func validate(version: String, build: String) throws {
        guard schemaVersion == 1,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plainText.utf16.count <= 4000,
              sourceRevision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
              repository.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
            throw ReleaseNotesError.invalidDocument
        }
        guard self.version == version, self.build == build, !version.isEmpty, !build.isEmpty else {
            throw ReleaseNotesError.versionMismatch
        }
    }
}

public enum ReleaseNotesError: LocalizedError {
    case invalidDocument
    case versionMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "The release notes in this app are invalid."
        case .versionMismatch: "The release notes do not match this app version."
        }
    }
}
