import Foundation

/// One session's agent-activity snapshot as a scan found it on disk.
struct AgentActivityRead {
    enum Outcome {
        /// There's no snapshot file.
        case missing
        /// The file matches the cached signature, so the cached snapshot stands.
        case unchanged
        /// The file exists but couldn't be read (a transient `open()` denial or a
        /// racing writer); the cache is left alone so the next scan retries.
        case unreadable
        /// Read and decoded; a malformed file decodes to nil and is cached as such.
        case read(FileSignature, AgentActivitySnapshot?)
    }

    let outcome: Outcome
    /// Taken after the read, so a snapshot is never judged before it was read.
    let readAt: Date
}

/// Reads sessions' `<id>.agent-activity.json` files. It touches no app state, so
/// scans can run it off the main actor. An endpoint-security agent holds each
/// `open()` of a freshly rewritten heartbeat: 0.2 to 0.86s a file on a loaded
/// Mac, where reading 67 live sessions' files in turn took 8 to 11s. That is
/// longer than the 5s between heartbeats, so every scan re-read every file and
/// applied snapshots that were already going stale. Changed files are therefore
/// read together, one per core at a time.
enum AgentActivityReader {
    typealias Read = @Sendable (
        _ sessionIds: [String],
        _ directory: URL,
        _ cached: [String: FileSignature],
        _ clock: () -> Date
    ) -> [String: AgentActivityRead]

    static let read: Read = { sessionIds, directory, cached, clock in
        read(sessionIds, directory, cached, clock) { try Data(contentsOf: $0) }
    }

    static func read(
        _ sessionIds: [String],
        _ directory: URL,
        _ cached: [String: FileSignature],
        _ clock: () -> Date,
        load: (URL) throws -> Data
    ) -> [String: AgentActivityRead] {
        let fm = FileManager.default
        var reads: [String: AgentActivityRead] = [:]
        var changed: [(sessionId: String, signature: FileSignature, url: URL)] = []
        for sessionId in sessionIds {
            let url = directory
                .appendingPathComponent("\(sessionId).agent-activity.json", isDirectory: false)
            if let attributes = try? fm.attributesOfItem(atPath: url.path) {
                let signature = FileSignature(attributes: attributes)
                if cached[sessionId] == signature {
                    reads[sessionId] = AgentActivityRead(outcome: .unchanged, readAt: clock())
                } else {
                    changed.append((sessionId, signature, url))
                }
            } else {
                reads[sessionId] = AgentActivityRead(outcome: .missing, readAt: clock())
            }
        }
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: changed.count) { index in
            let (sessionId, signature, url) = changed[index]
            let outcome: AgentActivityRead.Outcome
            if let data = try? load(url) {
                outcome = .read(signature, try? JSONDecoder().decode(AgentActivitySnapshot.self, from: data))
            } else {
                outcome = .unreadable
            }
            lock.withLock { reads[sessionId] = AgentActivityRead(outcome: outcome, readAt: clock()) }
        }
        return reads
    }
}
