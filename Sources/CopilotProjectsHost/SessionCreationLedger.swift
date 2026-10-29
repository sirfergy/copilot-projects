import Foundation
import CryptoKit
import CopilotProjectsCore
import CopilotProjectsProtocol

/// One remembered remote session creation: the client `requestId` mapped to the
/// project/session it produced and when. Persisted so a duplicate request after a
/// restart — or after the session has since been closed — is answered without
/// creating (or resurrecting) anything.
struct SessionCreationRecord: Codable, Equatable, Sendable {
    let requestId: String
    let projectId: String
    let sessionId: String
    let createdAt: Date
    let creationFingerprint: String?

    init(
        requestId: String,
        projectId: String,
        sessionId: String,
        createdAt: Date,
        creationFingerprint: String? = nil
    ) {
        self.requestId = requestId
        self.projectId = projectId
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.creationFingerprint = creationFingerprint
    }

    static func fingerprint(
        projectId: String,
        kind: RemoteSessionKind,
        initialPrompt: String?,
        pullRequestURL: String?,
        hostId: String? = nil
    ) -> String {
        var hash = SHA256()
        var fields: [String?] = [
            "copilot-projects/session-creation/v1",
            pullRequestURL == nil ? "create" : "review",
            projectId,
            kind.rawValue,
            initialPrompt,
            pullRequestURL,
        ]
        if let hostId, !hostId.isEmpty {
            fields.append(hostId.lowercased())
        }
        for field in fields {
            guard let field else {
                hash.update(data: Data([0]))
                continue
            }
            hash.update(data: Data([1]))
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Binds a request to resume `copilotSessionId` in `projectId`; never equal to
    /// a creation's fingerprint.
    static func resumeFingerprint(projectId: String, copilotSessionId: String) -> String {
        var hash = SHA256()
        for field in ["copilot-projects/session-resume/v1", projectId, copilotSessionId.lowercased()] {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func pullRequestFingerprint(_ request: RemotePullRequestSessionRequest) -> String {
        let fields = ["copilot-projects/pull-request-session/v1", request.kind, request.projectId,
                      request.copilotSessionId ?? ""] + request.pullRequestKeys.sorted()
        var hash = SHA256()
        for field in fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// One remembered Pull Requests prompt dispatch: records delivery intent before
/// dispatch and final delivery state afterward so retries across host restarts
/// never send the same prompt twice.
struct PullRequestsPromptRecord: Codable, Equatable, Sendable {
    enum Route: String, Codable, Equatable, Sendable {
        case terminal
        case native
    }

    enum DeliveryState: String, Codable, Equatable, Sendable {
        case pending
        case queued
        case delivered
        case rejected
    }

    let requestId: String
    let sessionId: String
    let payloadFingerprint: String
    let route: Route
    let conversationEpoch: String?
    var state: DeliveryState
    let createdAt: Date
}

/// Thread-safe, bounded, persisted ledger of remote session creations. Acts as the
/// tombstone store behind idempotent creation: once a `requestId` is remembered the
/// host will never create for it again, so a session the user later closes is not
/// silently recreated by a retried request. Entries expire after a week and the
/// file is capped so a long-lived host can't grow it without bound.
final class SessionCreationLedger: @unchecked Sendable {
    /// Keep at most this many records — the most recently created win once the cap
    /// is exceeded. Real usage is a handful; the bound only guards against abuse.
    static let maxRecords = 512
    static let maxPromptRecords = 1_024
    /// Records older than this are dropped on the next load/prune. A week is long
    /// enough to cover realistic client retries while bounding tombstone lifetime.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    private struct LedgerFile: Codable {
        var records: [SessionCreationRecord]
        var promptRecords: [PullRequestsPromptRecord]? = nil
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL = Paths.sessionCreationLedgerPath) {
        self.url = url
    }

    /// The remembered record for `requestId`, if one is still live (not expired).
    func record(for requestId: UUID, now: Date = Date()) throws -> SessionCreationRecord? {
        lock.lock()
        defer { lock.unlock() }
        let pruned = Self.prune(try loadFile().records, now: now)
        return pruned.first { $0.requestId == requestId.uuidString }
    }

    /// Remember a creation, then prune (TTL + bound) and persist atomically. An
    /// existing entry for the same `requestId` is replaced.
    func remember(_ record: SessionCreationRecord, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = try loadFile()
        var records = file.records.filter { $0.requestId != record.requestId }
        records.append(record)
        file.records = Self.prune(records, now: now)
        if let promptRecords = file.promptRecords {
            file.promptRecords = Self.prunePrompts(promptRecords, now: now)
        }
        try persistFile(file)
    }

    /// The remembered Pull Requests prompt record for `requestId`, if still live.
    func promptRecord(for requestId: UUID, now: Date = Date()) throws -> PullRequestsPromptRecord? {
        lock.lock()
        defer { lock.unlock() }
        let pruned = Self.prunePrompts(try loadFile().promptRecords ?? [], now: now)
        return pruned.first { $0.requestId == requestId.uuidString }
    }

    /// Remember or update a Pull Requests prompt record atomically.
    func rememberPrompt(_ record: PullRequestsPromptRecord, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = try loadFile()
        file.records = Self.prune(file.records, now: now)
        var prompts = (file.promptRecords ?? []).filter { $0.requestId != record.requestId }
        prompts.append(record)
        file.promptRecords = Self.prunePrompts(prompts, now: now)
        try persistFile(file)
    }

    /// Removes an unconfirmed pending prompt record when pre-dispatch validation
    /// or synchronous rejection proved nothing was sent.
    func removePrompt(for requestId: UUID, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var file = try loadFile()
        guard let existing = file.promptRecords else { return }
        let filtered = Self.prunePrompts(
            existing.filter { $0.requestId != requestId.uuidString },
            now: now
        )
        file.promptRecords = filtered.isEmpty ? nil : filtered
        try persistFile(file)
    }

    // MARK: - Pure pruning (TTL then bound), exposed for tests.

    static func prune(
        _ records: [SessionCreationRecord],
        now: Date,
        ttl: TimeInterval = SessionCreationLedger.ttl,
        maxRecords: Int = SessionCreationLedger.maxRecords
    ) -> [SessionCreationRecord] {
        let live = records.filter { now.timeIntervalSince($0.createdAt) <= ttl }
        guard live.count > maxRecords else { return live }
        // Drop the oldest first, then restore the original (append) order so the
        // on-disk file stays chronological and lookups remain stable.
        let keep = Set(
            live.sorted { $0.createdAt > $1.createdAt }
                .prefix(maxRecords)
                .map(\.requestId)
        )
        return live.filter { keep.contains($0.requestId) }
    }

    static func prunePrompts(
        _ records: [PullRequestsPromptRecord],
        now: Date,
        ttl: TimeInterval = SessionCreationLedger.ttl,
        maxRecords: Int = SessionCreationLedger.maxPromptRecords
    ) -> [PullRequestsPromptRecord] {
        let live = records.filter { now.timeIntervalSince($0.createdAt) <= ttl }
        guard live.count > maxRecords else { return live }
        let keep = Set(
            live.sorted { $0.createdAt > $1.createdAt }
                .prefix(maxRecords)
                .map(\.requestId)
        )
        return live.filter { keep.contains($0.requestId) }
    }

    // MARK: - Persistence

    private func loadFile() throws -> LedgerFile {
        guard let data = try CreationLedgerFile.read(from: url) else {
            return LedgerFile(records: [], promptRecords: nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LedgerFile.self, from: data)
    }

    /// Atomic 0600 persistence: the payload is written to a private temp file
    /// created with 0600, fsynced, then `rename(2)`'d over the destination so a
    /// reader never observes a partial or world-readable file.
    private func persistFile(_ file: LedgerFile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try CreationLedgerFile.write(data, to: url)
    }
}
