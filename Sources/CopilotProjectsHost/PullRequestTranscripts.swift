import Foundation

/// Finds many byte patterns in one pass over the input (Aho–Corasick compiled to
/// a DFA), so a transcript is read once however many pull requests are open.
struct MultiPatternMatcher: Sendable {
    let patternLengths: [Int]
    private let transitions: [Int32]
    /// `outputs[outputStart[state]..<outputStart[state + 1]]` end at `state`.
    private let outputStart: [Int32]
    private let outputs: [Int32]

    init(patterns: [[UInt8]]) {
        patternLengths = patterns.map(\.count)
        var next: [[Int32]] = [Array(repeating: -1, count: 256)]
        var ends: [[Int32]] = [[]]
        for (index, pattern) in patterns.enumerated() where !pattern.isEmpty {
            var state = 0
            for byte in pattern {
                let target = next[state][Int(byte)]
                if target >= 0 {
                    state = Int(target)
                } else {
                    next.append(Array(repeating: -1, count: 256))
                    ends.append([])
                    next[state][Int(byte)] = Int32(next.count - 1)
                    state = next.count - 1
                }
            }
            ends[state].append(Int32(index))
        }
        var fallback = [Int32](repeating: 0, count: next.count)
        var queue: [Int] = []
        for byte in 0..<256 {
            let target = next[0][byte]
            if target < 0 {
                next[0][byte] = 0
            } else {
                queue.append(Int(target))
            }
        }
        var head = 0
        while head < queue.count {
            let state = queue[head]
            head += 1
            // Breadth-first, so the fallback's outputs are already complete.
            if state != 0 { ends[state] += ends[Int(fallback[state])] }
            for byte in 0..<256 {
                let target = next[state][byte]
                if target < 0 {
                    next[state][byte] = next[Int(fallback[state])][byte]
                } else {
                    fallback[Int(target)] = state == 0 ? 0 : next[Int(fallback[state])][byte]
                    queue.append(Int(target))
                }
            }
        }
        transitions = next.flatMap { $0 }
        var start: [Int32] = [0]
        var flat: [Int32] = []
        for list in ends {
            flat += list
            start.append(Int32(flat.count))
        }
        outputStart = start
        outputs = flat
    }

    /// Calls `match(pattern, end)` for each occurrence; `end` is the index just past it.
    func scan(_ bytes: UnsafeBufferPointer<UInt8>, in range: Range<Int>, match: (Int, Int) -> Void) {
        transitions.withUnsafeBufferPointer { delta in
            outputStart.withUnsafeBufferPointer { starts in
                outputs.withUnsafeBufferPointer { found in
                    var state = 0
                    var index = range.lowerBound
                    while index < range.upperBound {
                        state = Int(delta[state &* 256 &+ Int(bytes[index])])
                        let first = Int(starts[state])
                        let last = Int(starts[state &+ 1])
                        if first != last {
                            for slot in first..<last { match(Int(found[slot]), index &+ 1) }
                        }
                        index &+= 1
                    }
                }
            }
        }
    }
}

/// Counts what ties a Copilot transcript to pull requests: head branch names, and
/// `github.com/<owner>/<repo>/pull/<n>` links.
enum TranscriptMentionScanner {
    static let urlMarker = Array("github.com/".utf8)

    struct Counts: Equatable {
        var branches: [String: Int] = [:]
        var urls: [PullRequestKey: Int] = [:]
    }

    /// Branch names, and optionally pull request links, compiled once and reused per file.
    struct Patterns: Sendable {
        let branches: [String]
        let includeURLs: Bool
        let matcher: MultiPatternMatcher

        init(branches: [String], includeURLs: Bool) {
            self.branches = branches
            self.includeURLs = includeURLs
            var patterns = branches.map { Array($0.utf8) }
            if includeURLs { patterns.append(TranscriptMentionScanner.urlMarker) }
            matcher = MultiPatternMatcher(patterns: patterns)
        }

        var isEmpty: Bool { branches.isEmpty && !includeURLs }
    }

    /// Only whole JSONL lines are read: through the last newline.
    static func completeLength(_ bytes: UnsafeBufferPointer<UInt8>) -> Int {
        var index = bytes.count
        while index > 0 {
            if bytes[index - 1] == UInt8(ascii: "\n") { return index }
            index -= 1
        }
        return 0
    }

    static func count(in bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>, patterns: Patterns) -> Counts {
        var counts = Counts()
        guard !patterns.isEmpty, !range.isEmpty else { return counts }
        let urlPattern = patterns.branches.count
        let lengths = patterns.matcher.patternLengths
        var branchHits = [Int](repeating: 0, count: patterns.branches.count)
        patterns.matcher.scan(bytes, in: range) { pattern, end in
            if pattern == urlPattern {
                if let key = pullRequest(in: bytes, from: end, limit: range.upperBound) {
                    counts.urls[key, default: 0] += 1
                }
            } else if isBranchMention(bytes, start: end - lengths[pattern], end: end, limit: range.upperBound) {
                branchHits[pattern] += 1
            }
        }
        for (index, branch) in patterns.branches.enumerated() where branchHits[index] > 0 {
            counts.branches[branch, default: 0] += branchHits[index]
        }
        return counts
    }

    /// A branch name standing on its own, not the start of a longer one
    /// (`feature/x` inside `feature/x-2`) or the end of another word. A trailing
    /// period ends a sentence unless a name continues after it (`v1.2`).
    static func isBranchMention(_ bytes: UnsafeBufferPointer<UInt8>, start: Int, end: Int, limit: Int) -> Bool {
        if end < limit {
            let next = bytes[end]
            if next == UInt8(ascii: ".") {
                if end + 1 < limit, isBranchByte(bytes[end + 1]), bytes[end + 1] != UInt8(ascii: ".") { return false }
            } else if isBranchByte(next) || next == UInt8(ascii: "/") {
                return false
            }
        }
        guard start > 0 else { return true }
        let before = bytes[start - 1]
        guard isBranchByte(before) else { return true }
        // A JSON-escaped line break (`\n`, `\t`, `\r`) ends the previous line.
        let escapes: Set<UInt8> = [UInt8(ascii: "n"), UInt8(ascii: "t"), UInt8(ascii: "r")]
        return start > 1 && escapes.contains(before) && bytes[start - 2] == UInt8(ascii: "\\")
    }

    private static func isBranchByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."):
            return true
        default:
            return false
        }
    }

    /// `<owner>/<repo>/pull/<number>` starting at `index`.
    static func pullRequest(in bytes: UnsafeBufferPointer<UInt8>, from index: Int, limit: Int) -> PullRequestKey? {
        var cursor = index
        func read(_ allowed: (UInt8) -> Bool, maximum: Int) -> String? {
            let start = cursor
            while cursor < limit, cursor - start <= maximum, allowed(bytes[cursor]) { cursor += 1 }
            guard cursor > start, cursor - start <= maximum else { return nil }
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<cursor]), as: UTF8.self)
        }
        func expect(_ literal: String) -> Bool {
            for byte in literal.utf8 {
                guard cursor < limit, bytes[cursor] == byte else { return false }
                cursor += 1
            }
            return true
        }
        let isOwnerByte: (UInt8) -> Bool = { isBranchByte($0) && $0 != UInt8(ascii: ".") && $0 != UInt8(ascii: "_") }
        let isDigit: (UInt8) -> Bool = { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
        guard let owner = read(isOwnerByte, maximum: 39), expect("/"),
              let repo = read(isBranchByte, maximum: 100), expect("/pull/"),
              let digits = read(isDigit, maximum: 9), let number = Int(digits) else { return nil }
        return PullRequestKey(owner: owner, repo: repo, number: number)
    }
}

/// Mentions per live session's Copilot transcript, kept on disk so a relaunch only
/// reads what the transcripts gained since.
actor PullRequestTranscriptIndex {
    struct Source: Hashable, Sendable {
        let sessionId: String
        let path: String
    }

    struct Entry: Codable, Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var scannedBytes: Int
        var branchMentions: [String: Int]
        var urlMentions: [String: Int]
    }

    private struct Store: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var entries: [String: Entry]
    }

    private let storeURL: URL?
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(storeURL: URL?) {
        self.storeURL = storeURL
    }

    /// The Copilot CLI's event log for one of its sessions.
    static func transcriptPath(
        copilotSessionId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String? {
        guard copilotSessionId.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        let copilotHome = environment["COPILOT_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (home as NSString).appendingPathComponent(".copilot")
        return ((copilotHome as NSString).appendingPathComponent("session-state") as NSString)
            .appendingPathComponent("\(copilotSessionId)/events.jsonl")
    }

    func evidence(for sources: [Source], branches: Set<String>) async -> [String: TranscriptEvidence] {
        loadIfNeeded()
        let current = entries
        let patterns = TranscriptMentionScanner.Patterns(branches: branches.sorted(), includeURLs: true)
        let updates = await withTaskGroup(of: (String, Entry?, Date?).self) { group in
            var results: [(String, Entry?, Date?)] = []
            var pending = Set(sources).makeIterator()
            func addNext() -> Bool {
                guard let source = pending.next() else { return false }
                let previous = current[source.path]
                group.addTask(priority: .utility) {
                    let (entry, modified) = Self.update(previous, path: source.path, patterns: patterns)
                    return (source.path, entry, modified)
                }
                return true
            }
            for _ in 0..<4 { guard addNext() else { break } }
            for await result in group {
                results.append(result)
                _ = addNext()
            }
            return results
        }
        var modifiedAt: [String: Date] = [:]
        var refreshed: [String: Entry] = [:]
        for (path, entry, modified) in updates {
            if let entry { refreshed[path] = entry }
            modifiedAt[path] = modified
        }
        entries = refreshed
        save()
        var evidence: [String: TranscriptEvidence] = [:]
        for source in sources {
            guard let entry = refreshed[source.path] else { continue }
            var urls: [PullRequestKey: Int] = [:]
            for (text, count) in entry.urlMentions {
                if let key = PullRequestKey(text) { urls[key, default: 0] += count }
            }
            evidence[source.sessionId] = TranscriptEvidence(
                branchMentions: entry.branchMentions, urlMentions: urls, lastModified: modifiedAt[source.path]
            )
        }
        return evidence
    }

    /// Reads what a transcript gained since `previous`, plus any new branch names
    /// over what was already read. Nil when the file is gone.
    static func update(
        _ previous: Entry?, path: String, patterns: TranscriptMentionScanner.Patterns
    ) -> (Entry?, Date?) {
        var info = stat()
        guard stat(path, &info) == 0 else { return (nil, nil) }
        let device = UInt64(bitPattern: Int64(info.st_dev))
        let inode = UInt64(info.st_ino)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        var entry = previous ?? Entry(device: device, inode: inode, scannedBytes: 0, branchMentions: [:], urlMentions: [:])
        if entry.device != device || entry.inode != inode || Int(info.st_size) < entry.scannedBytes {
            entry = Entry(device: device, inode: inode, scannedBytes: 0, branchMentions: [:], urlMentions: [:])
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return (previous, modified)
        }
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let complete = TranscriptMentionScanner.completeLength(bytes)
            let scanned = min(entry.scannedBytes, complete)
            let added = patterns.branches.filter { entry.branchMentions[$0] == nil }
            if !added.isEmpty, scanned > 0 {
                let counts = TranscriptMentionScanner.count(
                    in: bytes, range: 0..<scanned,
                    patterns: TranscriptMentionScanner.Patterns(branches: added, includeURLs: false)
                )
                entry.branchMentions.merge(counts.branches, uniquingKeysWith: +)
            }
            for branch in added where entry.branchMentions[branch] == nil { entry.branchMentions[branch] = 0 }
            if complete > scanned {
                let counts = TranscriptMentionScanner.count(in: bytes, range: scanned..<complete, patterns: patterns)
                entry.branchMentions.merge(counts.branches, uniquingKeysWith: +)
                for (key, count) in counts.urls { entry.urlMentions[key.description, default: 0] += count }
            }
            entry.scannedBytes = complete
        }
        let wanted = Set(patterns.branches)
        entry.branchMentions = entry.branchMentions.filter { wanted.contains($0.key) }
        return (entry, modified)
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let storeURL, let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == Store.currentVersion else { return }
        entries = store.entries
    }

    private func save() {
        guard let storeURL else { return }
        let directory = storeURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        guard let data = try? JSONEncoder().encode(Store(entries: entries)) else { return }
        try? data.write(to: storeURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}
