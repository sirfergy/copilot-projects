import Foundation

/// Wire contract for remote session creation. Additive and backward compatible:
/// older hosts simply don't route `createPath`, so a client that POSTs it gets a
/// 404 and can present the feature as unsupported.
public enum RemoteSessionContract {
    /// Path (relative to the gateway base, no leading slash) a client POSTs a
    /// `RemoteCreateSessionRequest` to. Mirrors the `NotificationSyncContract`
    /// style so both sides share one source of truth.
    public static let createPath = "sessions/create"

    /// Dedicated path for a session that launches Copilot with the fixed local
    /// adversarial-review prompt. Keeping this separate makes older hosts return
    /// 404 instead of silently ignoring the additive request field.
    public static let reviewPath = "sessions/review"
}

/// A remote client's request to create a new session in a host project. The
/// `requestId` is client-generated and retained across retries so the host can
/// make creation idempotent (the same request never spawns two sessions).
public struct RemoteCreateSessionRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String
    public let pullRequestURL: String?

    public init(
        requestId: UUID,
        projectId: String,
        pullRequestURL: String? = nil
    ) {
        self.requestId = requestId
        self.projectId = projectId
        self.pullRequestURL = pullRequestURL
    }
}

/// A validated GitHub pull request used by the desktop and native iOS launch
/// affordances. The normalized URL is reconstructed from bounded path
/// components so pasted query strings, fragments, or sub-pages never reach the
/// agent prompt.
public struct PullRequestReviewTarget: Equatable, Sendable {
    public static let maximumInputBytes = 2_048

    public let owner: String
    public let repository: String
    public let number: Int
    public let url: String

    public var title: String {
        "Review \(owner)/\(repository)#\(number)"
    }

    public static func parse(_ input: String) -> Self? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= maximumInputBytes,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "github.com",
              components.user == nil,
              components.password == nil,
              components.port == nil else {
            return nil
        }

        let segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 4,
              segments[2] == "pull",
              isSafePathComponent(segments[0]),
              isSafePathComponent(segments[1]),
              let number = Int(segments[3]),
              number > 0 else {
            return nil
        }

        let owner = segments[0]
        let repository = segments[1]
        return Self(
            owner: owner,
            repository: repository,
            number: number,
            url: "https://github.com/\(owner)/\(repository)/pull/\(number)"
        )
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        return !value.isEmpty && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// The host's answer to a `RemoteCreateSessionRequest`. `sessionId` is the
/// deterministic id derived from `requestId`, echoed so the client can select the
/// session once the next workspace snapshot includes it. `projectId` reflects the
/// project that actually owns the session (identical to the request for a fresh
/// create; the owning project for an idempotent duplicate).
public struct RemoteCreateSessionResponse: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String
    public let sessionId: String

    public init(requestId: UUID, projectId: String, sessionId: String) {
        self.requestId = requestId
        self.projectId = projectId
        self.sessionId = sessionId
    }
}
