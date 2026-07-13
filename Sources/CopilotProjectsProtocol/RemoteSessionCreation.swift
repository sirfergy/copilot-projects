import Foundation

/// Wire contract for remote session creation. Additive and backward compatible:
/// older hosts simply don't route `createPath`, so a client that POSTs it gets a
/// 404 and can present the feature as unsupported.
public enum RemoteSessionContract {
    /// Path (relative to the gateway base, no leading slash) a client POSTs a
    /// `RemoteCreateSessionRequest` to. Mirrors the `NotificationSyncContract`
    /// style so both sides share one source of truth.
    public static let createPath = "sessions/create"
}

/// A remote client's request to create a new session in a host project. The
/// `requestId` is client-generated and retained across retries so the host can
/// make creation idempotent (the same request never spawns two sessions).
public struct RemoteCreateSessionRequest: Codable, Equatable, Sendable {
    public let requestId: UUID
    public let projectId: String

    public init(requestId: UUID, projectId: String) {
        self.requestId = requestId
        self.projectId = projectId
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
