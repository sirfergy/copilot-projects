import Foundation
import CryptoKit
import CopilotProjectsCore

struct ProjectCreationRecord: Codable, Equatable, Sendable {
    let requestId: String
    let createdAt: Date
    let creationFingerprint: String

    static func fingerprint(name: String) -> String {
        // Bind retries without retaining renamed or deleted project names in the ledger.
        SHA256.hash(data: Data("copilot-projects/project-creation/v1\u{0}\(name)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

final class ProjectCreationLedger: @unchecked Sendable {
    static let maxRecords = SessionCreationLedger.maxRecords
    static let ttl = SessionCreationLedger.ttl

    private struct LedgerFile: Codable {
        let records: [ProjectCreationRecord]
    }

    private let url: URL
    private let lock = NSLock()

    init(url: URL = Paths.projectCreationLedgerPath) {
        self.url = url
    }

    func record(for requestId: UUID, now: Date = Date()) throws -> ProjectCreationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return Self.prune(try load(), now: now).first { $0.requestId == requestId.uuidString }
    }

    func remember(_ record: ProjectCreationRecord, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }
        var records = try load().filter { $0.requestId != record.requestId }
        records.append(record)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(LedgerFile(records: Self.prune(records, now: now)))
        try CreationLedgerFile.write(data, to: url)
    }

    static func prune(
        _ records: [ProjectCreationRecord],
        now: Date,
        ttl: TimeInterval = ProjectCreationLedger.ttl,
        maxRecords: Int = ProjectCreationLedger.maxRecords
    ) -> [ProjectCreationRecord] {
        let live = records.filter { now.timeIntervalSince($0.createdAt) <= ttl }
        guard live.count > maxRecords else { return live }
        let keep = Set(live.sorted { $0.createdAt > $1.createdAt }
            .prefix(maxRecords).map(\.requestId))
        return live.filter { keep.contains($0.requestId) }
    }

    private func load() throws -> [ProjectCreationRecord] {
        guard let data = try CreationLedgerFile.read(from: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LedgerFile.self, from: data).records
    }
}
