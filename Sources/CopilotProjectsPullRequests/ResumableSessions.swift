import Foundation
import SQLite3
import CopilotProjectsCore

/// An ended Copilot CLI session that worked on a pull request, which Copilot
/// Projects can open again with `copilot --resume`.
struct ResumableSession: Equatable, Sendable {
    let copilotSessionId: String
    let name: String
    /// The folder it worked in; it resumes there.
    let cwd: String
    let lastActive: Date
}

/// One search for ended sessions.
struct ResumableSearch: Equatable, Sendable {
    var sessions: [PullRequestKey: ResumableSession] = [:]
    /// Candidates were left unread for the byte budget after this search made
    /// progress, so searching again finds more.
    var deferred = false
}

/// What the Pull Requests window asks for ended sessions.
protocol ResumableSessionSearching: Sendable {
    func search(for pullRequests: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>) async -> ResumableSearch
}

/// Finds the ended Copilot session that worked on each pull request no live
/// session drives. The Copilot CLI's session index names candidates; a candidate
/// counts only when its transcript names the pull request as often as a live
/// session's must. Without the index there are no candidates: transcripts are
/// far too large to search one by one.
actor ResumableSessionFinder: ResumableSessionSearching {
    static let candidateLimit = 12
    /// New transcript bytes one search may read; candidates past it wait for the next.
    static let byteBudget = 1 << 30

    struct Hits: Equatable {
        /// Sessions whose own words name the pull request's link or branch.
        var strong: Set<String> = []
        /// Sessions the index ties to a pull request with this number, in any repository.
        var weak: Set<String> = []
    }

    private let store: CopilotSessionStore
    private let cache: ResumableTranscriptCache
    private let byteBudget: Int

    init(store: CopilotSessionStore = CopilotSessionStore(), cacheURL: URL?, byteBudget: Int = ResumableSessionFinder.byteBudget) {
        self.store = store
        self.byteBudget = byteBudget
        cache = ResumableTranscriptCache(storeURL: cacheURL)
    }

    /// New transcript bytes the last search read.
    func lastBytesRead() async -> Int {
        await cache.bytesRead
    }

    func find(
        for pullRequests: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>
    ) async -> [PullRequestKey: ResumableSession] {
        await search(for: pullRequests, liveCopilotSessionIds: liveCopilotSessionIds).sessions
    }

    func search(
        for pullRequests: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>
    ) async -> ResumableSearch {
        guard !pullRequests.isEmpty else { return ResumableSearch() }
        let hits = Self.candidates(databasePath: store.databasePath, pullRequests: pullRequests)
        guard !hits.isEmpty else { return ResumableSearch() }
        let live = Set(liveCopilotSessionIds.map { $0.lowercased() })

        var records: [String: CopilotSessionRecord?] = [:]
        func usable(_ id: String) -> CopilotSessionRecord? {
            if let known = records[id] { return known }
            var record: CopilotSessionRecord?
            if CopilotSessionStore.isValidSessionId(id), !live.contains(id), let found = store.record(for: id),
               found.clientName == nil || found.clientName == "github/cli",
               let cwd = found.cwd, Self.isDirectory(cwd), !store.isInUse(id) {
                record = found
            }
            records[id] = .some(record)
            return record
        }
        func newestFirst(_ ids: Set<String>) -> [String] {
            ids.compactMap { id in usable(id).map { (id, $0.updatedAt ?? .distantPast) } }
                .sorted { ($0.1, $0.0) > ($1.1, $1.0) }
                .map(\.0)
        }

        var strongRanked: [PullRequestKey: [String]] = [:]
        var weakRanked: [PullRequestKey: [String]] = [:]
        var ranked: [PullRequestKey: [String]] = [:]
        var branches: [String: Set<String>] = [:]
        for pr in pullRequests {
            guard let found = hits[pr.key] else { continue }
            let strong = Array(newestFirst(found.strong).prefix(Self.candidateLimit))
            let weak = Array(newestFirst(found.weak.subtracting(found.strong)).prefix(Self.candidateLimit - strong.count))
            guard !strong.isEmpty || !weak.isEmpty else { continue }
            strongRanked[pr.key] = strong
            weakRanked[pr.key] = weak
            ranked[pr.key] = strong + weak
            let branch = PullRequestLinker.isDistinctiveBranch(pr.headRefName) ? [pr.headRefName] : []
            for id in strong + weak { branches[id, default: []].formUnion(branch) }
        }
        guard !ranked.isEmpty else { return ResumableSearch() }

        // Every session that names a pull request is read before any the index
        // only ties to its number, mostly another repository's pull request;
        // within each, every pull request's best candidate before its next best.
        var order: [String] = []
        var queued = Set<String>()
        for tier in [strongRanked, weakRanked] {
            let depth = tier.values.map(\.count).max() ?? 0
            for rank in 0..<depth {
                for pr in pullRequests {
                    guard let candidates = tier[pr.key], rank < candidates.count,
                          queued.insert(candidates[rank]).inserted else { continue }
                    order.append(candidates[rank])
                }
            }
        }
        // All of them: the budget, not the cache's capacity, decides what waits.
        let requests = order.compactMap { id in
            store.transcriptPath(for: id).map {
                ResumableTranscriptCache.Request(copilotSessionId: id, path: $0, branches: branches[id] ?? [])
            }
        }
        let (evidence, deferred) = await cache.evidence(for: requests, budget: byteBudget)

        var resumable: [PullRequestKey: ResumableSession] = [:]
        for pr in pullRequests {
            guard let candidates = ranked[pr.key] else { continue }
            let verified = candidates.reduce(into: [String: TranscriptEvidence]()) { result, id in
                result[id] = evidence[id]
            }
            guard let id = PullRequestLinker.links(pullRequests: [pr], evidence: verified)[pr.key],
                  let record = records[id] ?? nil, let cwd = record.cwd else { continue }
            resumable[pr.key] = ResumableSession(
                copilotSessionId: id, name: record.displayName ?? "Copilot session", cwd: cwd,
                lastActive: record.updatedAt ?? verified[id]?.lastModified ?? .distantPast
            )
        }
        return ResumableSearch(sessions: resumable, deferred: deferred)
    }

    /// Sessions the Copilot CLI's index ties to each pull request, read-only.
    /// Nothing when the index is missing or unreadable.
    static func candidates(databasePath: String, pullRequests: [PullRequestSnapshot]) -> [PullRequestKey: Hits] {
        guard !pullRequests.isEmpty, FileManager.default.fileExists(atPath: databasePath) else { return [:] }
        var connection: OpaquePointer?
        let uri = URL(fileURLWithPath: databasePath).absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let db = connection else {
            sqlite3_close(connection)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var hits: [PullRequestKey: Hits] = [:]
        var searchable = true
        for pr in pullRequests {
            var found = Hits()
            if searchable {
                var phrases = ["\(pr.key.owner)/\(pr.key.repo)/pull/\(pr.key.number)"]
                if PullRequestLinker.isDistinctiveBranch(pr.headRefName) { phrases.append(pr.headRefName) }
                for phrase in phrases {
                    let quoted = "\"" + phrase.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                    guard let ids = column(
                        db, "SELECT DISTINCT session_id FROM search_index WHERE search_index MATCH ?1", quoted
                    ) else {
                        // No full-text index in this version of the store.
                        searchable = false
                        break
                    }
                    found.strong.formUnion(ids)
                }
            }
            if let ids = column(
                db, "SELECT session_id FROM session_refs WHERE ref_type = 'pr' AND ref_value = ?1", String(pr.key.number)
            ) {
                found.weak.formUnion(ids)
            }
            if !found.strong.isEmpty || !found.weak.isEmpty { hits[pr.key] = found }
        }
        return hits
    }

    /// The first column of every row read, lowercased; nil when the query can't
    /// be prepared, as when this version of the store lacks its table.
    private static func column(_ db: OpaquePointer, _ sql: String, _ value: String) -> [String]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, value, -1, transient) == SQLITE_OK else { return [] }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text).lowercased()) }
        }
        return values
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Mention counts for ended sessions' transcripts, kept on disk. Ended
/// transcripts stop growing, so once read they cost nothing. A transcript too
/// big for one budget is read over several, picking up where the last stopped.
/// Entries stay until the least recently used make room; one just used never does.
actor ResumableTranscriptCache {
    struct Request: Sendable {
        let copilotSessionId: String
        let path: String
        let branches: Set<String>
    }

    private struct Item: Codable {
        var entry: PullRequestTranscriptIndex.Entry
        /// The transcript read again from the start for branches `entry` wasn't
        /// read for; it replaces `entry` once it has caught up.
        var rescan: PullRequestTranscriptIndex.Entry?
        /// The transcript's size when `entry` had read every complete line: until
        /// it changes, all that is left is an unfinished last line.
        var size: Int?
        var lastUsed: Date
    }

    private struct Store: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var entries: [String: Item]
    }

    static let capacity = 400

    private let storeURL: URL?
    private var items: [String: Item] = [:]
    private var loaded = false
    /// New bytes the last call read.
    private(set) var bytesRead = 0

    init(storeURL: URL?) {
        self.storeURL = storeURL
    }

    /// Number of transcripts it remembers.
    var count: Int { items.count }

    /// Reads what each transcript gained, and backfills new branches, in order
    /// until `budget` new bytes are spent. Later requests keep what was read
    /// before; `deferred` says some were left unread after something was read.
    func evidence(
        for requests: [Request], budget: Int, now: Date = Date()
    ) async -> (evidence: [String: TranscriptEvidence], deferred: Bool) {
        loadIfNeeded()
        struct Scan: Sendable {
            let request: Request
            let previous: PullRequestTranscriptIndex.Entry?
            let patterns: TranscriptMentionScanner.Patterns
            let rescans: Bool
            let limit: Int
        }
        var scans: [Scan] = []
        var current: [String: (item: Item, modified: Date)] = [:]
        var spent = 0
        var unread = false
        for request in requests {
            var info = stat()
            guard stat(request.path, &info) == 0 else { continue }
            let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            let size = Int(info.st_size)
            func reads(_ entry: PullRequestTranscriptIndex.Entry) -> Bool {
                entry.device == UInt64(bitPattern: Int64(info.st_dev)) && entry.inode == UInt64(info.st_ino)
                    && size >= entry.scannedBytes
            }
            var item = items[request.path]
            if let known = item, !reads(known.entry) { item = nil }
            if let rescan = item?.rescan, !reads(rescan) { item?.rescan = nil }
            // Branches it was read for before stay, so a pull request that comes
            // back never costs a second read.
            var branches = request.branches
            for entry in [item?.entry, item?.rescan].compactMap({ $0 }) { branches.formUnion(entry.branchMentions.keys) }
            if let item { current[request.copilotSessionId] = (item, modified) }
            let rescans = item.map { known in branches.contains { known.entry.branchMentions[$0] == nil } } ?? false
            if !rescans, item?.size == size { continue }
            let previous = rescans ? item?.rescan : item?.entry
            let remaining = size - (previous?.scannedBytes ?? 0)
            guard remaining > 0 else { continue }
            guard spent < budget else {
                unread = true
                continue
            }
            let limit = min(remaining, budget - spent)
            spent += limit
            scans.append(Scan(
                request: request, previous: previous,
                patterns: TranscriptMentionScanner.Patterns(branches: branches.sorted(), includeURLs: true),
                rescans: rescans, limit: limit
            ))
        }

        let results = await withTaskGroup(of: (Scan, PullRequestTranscriptIndex.Scan).self) { group in
            var results: [(Scan, PullRequestTranscriptIndex.Scan)] = []
            var pending = scans.makeIterator()
            func addNext() -> Bool {
                guard !Task.isCancelled, let scan = pending.next() else { return false }
                group.addTask(priority: .utility) {
                    (scan, PullRequestTranscriptIndex.scan(
                        scan.previous, path: scan.request.path, patterns: scan.patterns, limit: scan.limit
                    ))
                }
                return true
            }
            for _ in 0..<2 { guard addNext() else { break } }
            for await result in group {
                results.append(result)
                _ = addNext()
            }
            return results
        }

        var read = 0
        var progressed = false
        for (scan, result) in results {
            let path = scan.request.path
            read += result.read
            guard let entry = result.entry else {
                items[path] = nil
                current[scan.request.copilotSessionId] = nil
                continue
            }
            if !result.finished { unread = true }
            var item = Item(entry: entry, rescan: nil, size: result.finished ? result.size : nil, lastUsed: now)
            if scan.rescans, !result.finished, let known = items[path] {
                item = Item(entry: known.entry, rescan: entry, size: known.size, lastUsed: now)
            }
            // Learning that only an unfinished line is left lets the next pass skip it.
            progressed = progressed || item.size != items[path]?.size
            items[path] = item
            current[scan.request.copilotSessionId] = (item, result.modified ?? now)
        }
        if scans.count > results.count { unread = true }
        bytesRead = read
        for request in requests where items[request.path] != nil {
            items[request.path]?.lastUsed = now
        }
        if items.count > Self.capacity {
            // What this call used stays, even past capacity, so it is never read twice.
            let evicted = items.filter { $0.value.lastUsed < now }
                .sorted { ($0.value.lastUsed, $0.key) < ($1.value.lastUsed, $1.key) }
                .prefix(items.count - Self.capacity)
            for (path, _) in evicted { items[path] = nil }
        }
        save()

        var evidence: [String: TranscriptEvidence] = [:]
        for (id, value) in current {
            var branches = value.item.entry.branchMentions
            // A rescan's partial counts for branches the entry wasn't read for.
            for (branch, count) in value.item.rescan?.branchMentions ?? [:] where branches[branch] == nil {
                branches[branch] = count
            }
            var urls: [PullRequestKey: Int] = [:]
            for (text, count) in value.item.entry.urlMentions {
                if let key = PullRequestKey(text) { urls[key, default: 0] += count }
            }
            evidence[id] = TranscriptEvidence(branchMentions: branches, urlMentions: urls, lastModified: value.modified)
        }
        // A pass that learned nothing would leave the same candidates every time.
        return (evidence, unread && (read > 0 || progressed))
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Store.currentVersion else { return }
        items = store.entries
    }

    private func save() {
        guard let storeURL else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Store(entries: items)) else { return }
        try? data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}
