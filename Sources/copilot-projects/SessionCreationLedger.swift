import Foundation
import CopilotProjectsCore

/// One remembered remote session creation: the client `requestId` mapped to the
/// project/session it produced and when. Persisted so a duplicate request after a
/// restart — or after the session has since been closed — is answered without
/// creating (or resurrecting) anything.
struct SessionCreationRecord: Codable, Equatable, Sendable {
    let requestId: String
    let projectId: String
    let sessionId: String
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
    /// Records older than this are dropped on the next load/prune. A week is long
    /// enough to cover realistic client retries while bounding tombstone lifetime.
    static let ttl: TimeInterval = 7 * 24 * 60 * 60

    private struct LedgerFile: Codable {
        var records: [SessionCreationRecord]
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL = Paths.sessionCreationLedgerPath) {
        self.url = url
    }

    /// The remembered record for `requestId`, if one is still live (not expired).
    func record(for requestId: UUID, now: Date = Date()) -> SessionCreationRecord? {
        lock.lock()
        defer { lock.unlock() }
        let pruned = Self.prune(load(), now: now)
        return pruned.first { $0.requestId == requestId.uuidString }
    }

    /// Remember a creation, then prune (TTL + bound) and persist atomically. An
    /// existing entry for the same `requestId` is replaced.
    func remember(_ record: SessionCreationRecord, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        var records = load().filter { $0.requestId != record.requestId }
        records.append(record)
        persist(Self.prune(records, now: now))
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

    // MARK: - Persistence

    private func load() -> [SessionCreationRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LedgerFile.self, from: data))?.records ?? []
    }

    /// Atomic 0600 persistence: the payload is written to a private temp file
    /// created with 0600, fsynced, then `rename(2)`'d over the destination so a
    /// reader never observes a partial or world-readable file.
    private func persist(_ records: [SessionCreationRecord]) {
        let directoryURL = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(LedgerFile(records: records))
            let temporaryURL = directoryURL
                .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard FileManager.default.createFile(
                atPath: temporaryURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                return
            }
            do {
                let handle = try FileHandle(forWritingTo: temporaryURL)
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                return
            }
            if rename(temporaryURL.path, url.path) != 0 {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        } catch {
            NSLog("copilot-projects: could not persist session creation ledger: \(error)")
        }
    }
}
