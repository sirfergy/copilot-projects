import Darwin
import Foundation
import SQLite3
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsPullRequests

/// A Copilot CLI home in a temporary folder: session folders and a
/// `session-store.db` with the CLI's schema, never the user's own.
final class CopilotHomeFixture {
    let root: URL
    let store: CopilotSessionStore

    init(root: URL, fullTextSearch: Bool = true) throws {
        self.root = root
        store = CopilotSessionStore(environment: ["COPILOT_HOME": root.path])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, repository TEXT, host_type TEXT, branch TEXT,
                summary TEXT, created_at TEXT DEFAULT (datetime('now')), updated_at TEXT DEFAULT (datetime('now')));
            CREATE TABLE session_refs (id INTEGER PRIMARY KEY AUTOINCREMENT,
                session_id TEXT NOT NULL REFERENCES sessions(id), ref_type TEXT NOT NULL, ref_value TEXT NOT NULL,
                turn_index INTEGER, created_at TEXT DEFAULT (datetime('now')),
                UNIQUE(session_id, ref_type, ref_value));
            """)
        if fullTextSearch {
            try execute("""
                CREATE VIRTUAL TABLE search_index USING fts5(content, session_id UNINDEXED,
                    source_type UNINDEXED, source_id UNINDEXED);
                """)
        }
    }

    /// A session folder with its `workspace.yaml` and event log, and what the
    /// index knows of it: the pull request numbers it referenced and text it said.
    @discardableResult
    func addSession(
        _ id: String = UUID().uuidString.lowercased(), cwd: String, client: String? = "github/cli",
        name: String = "Ship the thing", updated: Date = Date(timeIntervalSince1970: 1_800_000_000),
        transcript: String, refs: [Int] = [], said: [String] = []
    ) throws -> String {
        let directory = root.appendingPathComponent("session-state/\(id)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var yaml = "id: \(id)\ncwd: \(cwd)\n"
        if let client { yaml += "client_name: \(client)\n" }
        yaml += "name: \(name)\ncreated_at: \(formatter.string(from: updated.addingTimeInterval(-3_600)))\n"
        yaml += "updated_at: \(formatter.string(from: updated))\n"
        try Data(yaml.utf8).write(to: directory.appendingPathComponent("workspace.yaml"))
        try Data(transcript.utf8).write(to: directory.appendingPathComponent("events.jsonl"))
        try execute("INSERT INTO sessions (id, cwd) VALUES ('\(id)', '')")
        for number in refs { try addRef(id, number: number) }
        for text in said {
            try execute("""
                INSERT INTO search_index (content, session_id, source_type, source_id)
                VALUES ('\(text.replacingOccurrences(of: "'", with: "''"))', '\(id)', 'turn', '1')
                """)
        }
        return id
    }

    func addRef(_ id: String, number: Int) throws {
        try execute("INSERT INTO session_refs (session_id, ref_type, ref_value) VALUES ('\(id)', 'pr', '\(number)')")
    }

    func lock(_ id: String, pid: pid_t = getpid()) throws {
        try Data().write(to: root.appendingPathComponent("session-state/\(id)/inuse.\(pid).lock"))
    }

    private func execute(_ sql: String) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(store.databasePath, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "?"
            sqlite3_free(error)
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

/// `count` lines naming `text`, as a transcript does each time a branch is pushed.
func transcript(mentioning text: String, times count: Int) -> String {
    String(repeating: "{\"data\":{\"content\":\"git push origin \(text)\"}}\n", count: count)
}

final class ResumableSessionFinderTests: XCTestCase {
    private var root: URL!
    private var work: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        work = root.appendingPathComponent("work").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func finder(_ home: CopilotHomeFixture, budget: Int = ResumableSessionFinder.byteBudget,
                        cache: URL? = nil) -> ResumableSessionFinder {
        ResumableSessionFinder(store: home.store, cacheURL: cache, byteBudget: budget)
    }

    func testAnEndedSessionThatNamesThePullRequestIsOfferedWithItsNameAndFolder() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(7, repo: "o/r", branch: "me/resume-the-session")
        let updated = Date(timeIntervalSince1970: 1_790_000_000)
        let id = try home.addSession(
            cwd: work, name: "|-\n  Resume sessions\n  from the window", updated: updated,
            transcript: transcript(mentioning: "me/resume-the-session", times: 3),
            said: ["Opened https://github.com/o/r/pull/7 for review"]
        )
        let found = await finder(home).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(found, [pr.key: ResumableSession(
            copilotSessionId: id, name: "Resume sessions", cwd: work, lastActive: updated
        )])

        let branchOnly = makePR(8, repo: "o/r", branch: "me/named-in-prose")
        let other = try home.addSession(
            cwd: work, transcript: transcript(mentioning: "me/named-in-prose", times: 4),
            said: ["Pushed me/named-in-prose again"]
        )
        let byBranch = await finder(home).find(for: [branchOnly], liveCopilotSessionIds: [])
        XCTAssertEqual(byBranch[branchOnly.key]?.copilotSessionId, other, "the branch name finds it too")
    }

    func testANumberOnlyTheIndexTiesToThePullRequestIsRejectedByTheTranscript() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(42, repo: "o/r", branch: "me/the-real-branch")
        try home.addSession(cwd: work, transcript: transcript(mentioning: "someone/else-entirely", times: 9), refs: [42])
        let weak = try home.addSession(
            cwd: work, transcript: transcript(mentioning: "me/the-real-branch", times: 2), refs: [42]
        )
        let found = await finder(home).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertTrue(found.isEmpty, "another repository's #42, and a session that mentions the branch only twice")

        try Data(transcript(mentioning: "me/the-real-branch", times: 3).utf8)
            .write(to: home.root.appendingPathComponent("session-state/\(weak)/events.jsonl"))
        let verified = await finder(home).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(verified[pr.key]?.copilotSessionId, weak, "the index's number counts once the transcript agrees")
    }

    func testOnlySessionsThatCanBeResumedHereAreOffered() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        func session(_ number: Int, cwd: String? = nil, client: String? = "github/cli") throws -> (PullRequestSnapshot, String) {
            let pr = makePR(number, repo: "o/r", branch: "me/candidate-\(number)")
            let id = try home.addSession(
                cwd: cwd ?? work, client: client, transcript: transcript(mentioning: pr.headRefName, times: 5),
                said: ["github.com/o/r/pull/\(number)"]
            )
            return (pr, id)
        }
        let (resumable, resumableId) = try session(1)
        let (live, liveId) = try session(2)
        let (inUse, inUseId) = try session(3)
        let (moved, _) = try session(4, cwd: root.appendingPathComponent("deleted-worktree").path)
        let (editor, _) = try session(5, client: "vscode")
        let (unnamedClient, unnamedId) = try session(6, client: nil)
        try home.lock(inUseId)

        let found = await finder(home).find(
            for: [resumable, live, inUse, moved, editor, unnamedClient],
            liveCopilotSessionIds: [liveId.uppercased()]
        )
        XCTAssertEqual(found.mapValues(\.copilotSessionId), [resumable.key: resumableId, unnamedClient.key: unnamedId])
        XCTAssertNil(found[live.key], "already open in a tab")
        XCTAssertNil(found[inUse.key], "a running Copilot holds it")
        XCTAssertNil(found[moved.key], "its folder is gone; it never resumes somewhere else")
        XCTAssertNil(found[editor.key], "another client's session")
    }

    func testWithoutTheCopilotIndexNothingIsOfferedAndWithoutItsSearchTheReferencesStillAre() async throws {
        let missing = CopilotSessionStore(environment: ["COPILOT_HOME": root.appendingPathComponent("none").path])
        let pr = makePR(3, repo: "o/r", branch: "me/no-index-here")
        let none = await ResumableSessionFinder(store: missing, cacheURL: nil).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertTrue(none.isEmpty)

        let older = try CopilotHomeFixture(root: root.appendingPathComponent("older"), fullTextSearch: false)
        let id = try older.addSession(cwd: work, transcript: transcript(mentioning: pr.headRefName, times: 3), refs: [3])
        let found = await finder(older).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(found[pr.key]?.copilotSessionId, id)
    }

    func testSessionsThatNameThePullRequestAreReadFirstAndTheRestWaitForTheBudget() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(9, repo: "o/r", branch: "me/budgeted-branch")
        // As long as the other, so the budget fits exactly one of them.
        let named = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: transcript(mentioning: pr.headRefName, times: 3)
                + transcript(mentioning: "me/unrelated-branc", times: 3),
            said: ["see github.com/o/r/pull/9"]
        )
        let numbered = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: transcript(mentioning: pr.headRefName, times: 6), refs: [9]
        )
        let cache = root.appendingPathComponent("state/resumable-index.json")
        let size = { (id: String) throws -> Int in
            try Data(contentsOf: home.root.appendingPathComponent("session-state/\(id)/events.jsonl")).count
        }

        let first = finder(home, budget: try size(named), cache: cache)
        XCTAssertEqual(try size(named), try size(numbered))
        var found = await first.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(found[pr.key]?.copilotSessionId, named, "the session naming the pull request is read first")
        var read = await first.lastBytesRead()
        XCTAssertEqual(read, try size(named), "the budget leaves the older-ranked one for the next refresh")

        found = await first.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(found[pr.key]?.copilotSessionId, numbered, "read next time, it names the branch more")
        read = await first.lastBytesRead()
        XCTAssertEqual(read, try size(numbered))

        let relaunched = finder(home, cache: cache)
        found = await relaunched.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(found[pr.key]?.copilotSessionId, numbered)
        read = await relaunched.lastBytesRead()
        XCTAssertEqual(read, 0, "ended transcripts are never read twice")
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)

        // A pull request newly tied to the session reads it again for its branch.
        let sibling = makePR(10, repo: "o/other", branch: "me/sibling-branch")
        try home.addRef(numbered, number: 10)
        let handle = try FileHandle(forWritingTo: home.root.appendingPathComponent("session-state/\(numbered)/events.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(transcript(mentioning: "me/sibling-branch", times: 3).utf8))
        try handle.close()
        found = await relaunched.find(for: [pr, sibling], liveCopilotSessionIds: [])
        XCTAssertEqual(found[pr.key]?.copilotSessionId, numbered)
        XCTAssertEqual(found[sibling.key]?.copilotSessionId, numbered)
        read = await relaunched.lastBytesRead()
        XCTAssertEqual(read, try size(numbered), "the new branch is counted over what was read before")
    }

    func testCandidatesAreCappedPerPullRequest() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(11, repo: "o/r", branch: "me/popular-branch")
        let quiet = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_600_000_000),
            transcript: transcript(mentioning: pr.headRefName, times: 9), refs: [11]
        )
        for index in 0..<ResumableSessionFinder.candidateLimit {
            try home.addSession(
                cwd: work, updated: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(index)),
                transcript: transcript(mentioning: pr.headRefName, times: 3), refs: [11]
            )
        }
        let found = await finder(home).find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertNotNil(found[pr.key])
        XCTAssertNotEqual(found[pr.key]?.copilotSessionId, quiet, "only the twelve most recent are read")
    }

    func testMoreCandidatesThanTheCacheHoldsAreAllRead() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let count = ResumableTranscriptCache.capacity + 1
        var pullRequests: [PullRequestSnapshot] = []
        for number in 1...count {
            let pr = makePR(number, repo: "o/r", branch: "me/one-of-many-\(number)")
            try home.addSession(
                cwd: work, transcript: transcript(mentioning: pr.headRefName, times: 3), said: ["github.com/o/r/pull/\(number)"]
            )
            pullRequests.append(pr)
        }
        let search = await finder(home, cache: root.appendingPathComponent("state/resumable-index.json"))
            .search(for: pullRequests, liveCopilotSessionIds: [])
        XCTAssertEqual(search.sessions.count, count, "the last one is read too, not left out every time")
        XCTAssertNotNil(search.sessions[pullRequests[count - 1].key])
        XCTAssertFalse(search.deferred)
    }

    func testATranscriptBiggerThanTheBudgetIsReadAPieceAtATime() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(31, repo: "o/r", branch: "me/long-running-branch")
        let line = transcript(mentioning: pr.headRefName, times: 1).utf8.count
        let id = try home.addSession(
            cwd: work, transcript: transcript(mentioning: pr.headRefName, times: 6), said: ["github.com/o/r/pull/31"]
        )
        let cache = root.appendingPathComponent("state/resumable-index.json")
        var passes: [(found: String?, read: Int, deferred: Bool)] = []
        for _ in 0..<4 {
            // Each pass by a relaunched finder: what was read is kept.
            let finder = finder(home, budget: 2 * line + 1, cache: cache)
            let search = await finder.search(for: [pr], liveCopilotSessionIds: [])
            let read = await finder.lastBytesRead()
            passes.append((search.sessions[pr.key]?.copilotSessionId, read, search.deferred))
        }
        XCTAssertEqual(passes.map(\.read), [2 * line, 2 * line, 2 * line, 0], "whole lines, within the budget")
        XCTAssertEqual(passes.map(\.deferred), [true, true, false, false])
        XCTAssertEqual(passes.map(\.found), [nil, id, id, id], "found once enough of it is read")

        // A line longer than the budget is still read, one line at a time.
        let oneByte = self.finder(home, budget: 1)
        let search = await oneByte.search(for: [pr], liveCopilotSessionIds: [])
        let read = await oneByte.lastBytesRead()
        XCTAssertEqual(read, line)
        XCTAssertTrue(search.deferred)
    }

    func testAnUnfinishedLastLineNeverHoldsUpTheCandidatesAfterIt() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(51, repo: "o/r", branch: "me/after-the-tail")
        let valid = transcript(mentioning: pr.headRefName, times: 3)
        // Newer, so read first: Copilot stopped partway through writing its only line.
        try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: String(repeating: "x", count: valid.utf8.count * 2), said: ["github.com/o/r/pull/51"]
        )
        let id = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_700_000_000), transcript: valid,
            said: ["github.com/o/r/pull/51"]
        )
        let finder = finder(home, budget: valid.utf8.count, cache: root.appendingPathComponent("state/resumable-index.json"))
        var search = await finder.search(for: [pr], liveCopilotSessionIds: [])
        XCTAssertNil(search.sessions[pr.key])
        XCTAssertTrue(search.deferred, "it learned that only an unfinished line is left there")

        search = await finder.search(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(search.sessions[pr.key]?.copilotSessionId, id)
        let read = await finder.lastBytesRead()
        XCTAssertEqual(read, valid.utf8.count, "the unfinished line isn't read again until it changes")
        XCTAssertFalse(search.deferred)
    }

    func testANewBranchIsCountedOverSeveralPassesWithoutLosingWhatWasFound() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let first = makePR(41, repo: "o/r", branch: "me/first-branch-x")
        let second = makePR(42, repo: "o/r", branch: "me/other-branch-y")
        let half = transcript(mentioning: second.headRefName, times: 3)
        let id = try home.addSession(
            cwd: work, transcript: half + transcript(mentioning: first.headRefName, times: 3),
            said: ["github.com/o/r/pull/41 and github.com/o/r/pull/42"]
        )
        let cache = root.appendingPathComponent("state/resumable-index.json")
        let found = await finder(home, cache: cache).find(for: [first], liveCopilotSessionIds: [])
        XCTAssertEqual(found[first.key]?.copilotSessionId, id)

        var finder = finder(home, budget: half.utf8.count, cache: cache)
        var search = await finder.search(for: [first, second], liveCopilotSessionIds: [])
        var read = await finder.lastBytesRead()
        XCTAssertEqual(read, half.utf8.count, "the new branch is counted from the start, a budget at a time")
        XCTAssertTrue(search.deferred)
        XCTAssertEqual(search.sessions.mapValues(\.copilotSessionId), [first.key: id, second.key: id],
                       "what was found stays, and what the new branch has so far counts")

        finder = self.finder(home, budget: half.utf8.count, cache: cache)
        search = await finder.search(for: [first, second], liveCopilotSessionIds: [])
        read = await finder.lastBytesRead()
        XCTAssertEqual(read, half.utf8.count, "a relaunch picks up where it stopped")
        XCTAssertFalse(search.deferred)
        XCTAssertEqual(search.sessions.mapValues(\.copilotSessionId), [first.key: id, second.key: id])

        search = await finder.search(for: [first, second], liveCopilotSessionIds: [])
        read = await finder.lastBytesRead()
        XCTAssertEqual(read, 0)
        XCTAssertEqual(search.sessions.count, 2)
    }
}

final class ResumableOrderingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testEverySessionNamingAPullRequestIsReadBeforeAnyTheIndexOnlyNumbers() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let work = root.appendingPathComponent("work").path
        let named = makePR(1, repo: "o/r", branch: "me/branch-named")
        let numbered = makePR(2, repo: "o/r", branch: "me/branch-numbered")
        let first = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: transcript(mentioning: named.headRefName, times: 3), said: ["github.com/o/r/pull/1"]
        )
        let second = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: transcript(mentioning: named.headRefName, times: 6), said: ["github.com/o/r/pull/1"]
        )
        try home.addSession(cwd: work, transcript: transcript(mentioning: numbered.headRefName, times: 3), refs: [2])
        let size = { (id: String) throws -> Int in
            try Data(contentsOf: home.root.appendingPathComponent("session-state/\(id)/events.jsonl")).count
        }
        let budget = try size(first) + size(second)
        let finder = ResumableSessionFinder(store: home.store, cacheURL: nil, byteBudget: budget)
        let search = await finder.search(for: [named, numbered], liveCopilotSessionIds: [])
        XCTAssertEqual(search.sessions.mapValues(\.copilotSessionId), [named.key: second],
                       "a number-only candidate never pushes out another pull request's second named one")
        XCTAssertTrue(search.deferred, "the number-only candidate waits for the next pass")
        let read = await finder.lastBytesRead()
        XCTAssertEqual(read, budget)

        let next = await finder.search(for: [named, numbered], liveCopilotSessionIds: [])
        XCTAssertEqual(next.sessions.count, 2)
        XCTAssertFalse(next.deferred, "nothing is left unread")
    }

    func testTranscriptsReadInOneCallAreNeverEvictedByIt() async throws {
        let cache = ResumableTranscriptCache(storeURL: root.appendingPathComponent("cache.json"))
        let count = ResumableTranscriptCache.capacity + 1
        var requests: [ResumableTranscriptCache.Request] = []
        for index in 0..<count {
            let path = root.appendingPathComponent("t\(index).jsonl")
            try Data("x\n".utf8).write(to: path)
            requests.append(.init(copilotSessionId: "s\(index)", path: path.path, branches: []))
        }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await cache.evidence(for: requests, budget: 1 << 30, now: start)
        var read = await cache.bytesRead
        XCTAssertEqual(read, count * 2)
        var remembered = await cache.count
        XCTAssertEqual(remembered, count, "past capacity while all of it is in use")

        _ = await cache.evidence(for: requests, budget: 1 << 30, now: start.addingTimeInterval(60))
        read = await cache.bytesRead
        XCTAssertEqual(read, 0, "nothing read last time is read again")

        _ = await cache.evidence(for: [requests[0]], budget: 1 << 30, now: start.addingTimeInterval(120))
        remembered = await cache.count
        XCTAssertEqual(remembered, ResumableTranscriptCache.capacity, "the least recently used make room later")
        let again = await cache.evidence(for: [requests[0]], budget: 1 << 30, now: start.addingTimeInterval(180))
        XCTAssertNotNil(again.evidence["s0"])
        read = await cache.bytesRead
        XCTAssertEqual(read, 0)
    }
}

final class ResumableGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ id: String, active: TimeInterval) -> ResumableSession {
        ResumableSession(copilotSessionId: id, name: "Session \(id)", cwd: "/work",
                         lastActive: now.addingTimeInterval(active))
    }

    func testAPreviousSessionIsOfferedOnlyWhereNoLiveSessionIsAndCoversTheMostPullRequests() {
        let live = PullRequestSession(id: "tab", title: "Live - GitHub Copilot", projectId: "p", projectName: "Features")
        let driven = makePR(1, repo: "o/a", branch: "me/driven-branch")
        let first = makePR(2, repo: "o/a", branch: "me/shared-change")
        let second = makePR(3, repo: "o/b", branch: "me/shared-change")
        let third = makePR(4, repo: "o/c", branch: "me/shared-change")
        let lonely = makePR(5, repo: "o/d", branch: "me/lonely-branch")
        let older = candidate("older", active: -86_400)
        let newer = candidate("newer", active: -60)
        let goals = PullRequestGrouping.goals(
            pullRequests: [driven, first, second, third, lonely], links: [driven.key: live.id],
            sessions: [live.id: live], overrides: .init(), now: now,
            resumable: [driven.key: newer, first.key: older, second.key: older, third.key: newer, lonely.key: newer]
        )
        let byFirstKey = Dictionary(uniqueKeysWithValues: goals.map { ($0.items.map(\.pr.key).min()!, $0) })
        XCTAssertNil(byFirstKey[driven.key]?.resumable, "a live session already drives it")
        XCTAssertEqual(byFirstKey[first.key]?.items.count, 3)
        XCTAssertEqual(byFirstKey[first.key]?.resumable, older, "the session that worked on most of the goal")
        XCTAssertEqual(byFirstKey[lonely.key]?.resumable, newer)

        let tied = PullRequestGrouping.goals(
            pullRequests: [first, second], links: [:], sessions: [:], overrides: .init(), now: now,
            resumable: [first.key: older, second.key: newer]
        )
        XCTAssertEqual(tied.first?.resumable, newer, "a tie goes to the session active most recently")
    }
}

/// Stands in for the finder: answers each search in turn, repeating its last
/// answer, and can hold searches until released. Each search's answer is
/// chosen when it starts.
actor ScriptedResumableSearch: ResumableSessionSearching {
    private var answers: [ResumableSearch]
    private var holding: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var searches = 0

    init(_ answers: [ResumableSearch], holding: Bool = false) {
        self.answers = answers
        self.holding = holding
    }

    func search(for pullRequests: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>) async -> ResumableSearch {
        searches += 1
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        if holding { await withCheckedContinuation { held.append($0) } }
        return answer
    }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }
}

final class ResumableRefreshTests: XCTestCase {
    private var root: URL!
    private var home: CopilotHomeFixture!
    private var previousHome: String?
    private let key = PullRequestKey(owner: "o", repo: "r", number: 1)
    private let branch = "me/resume-from-refresh"
    private actor Counter { var value = 0; func bump() { value += 1 } }
    private let accountLoads = Counter()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        // Live sessions' transcripts are read from COPILOT_HOME too: keep them in the fixture.
        previousHome = ProcessInfo.processInfo.environment["COPILOT_HOME"]
        setenv("COPILOT_HOME", home.root.path, 1)
        URLProtocol.registerClass(GraphQLStub.self)
        GraphQLStub.respond = { [branch] _, body in
            let query = body["query"] as? String ?? ""
            if query.contains("search(") {
                return (200, """
                {"data":{"viewer":{"login":"good"},"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},
                 "nodes":[{"id":"PR_1","number":1,"title":"Resume it","url":"https://github.com/o/r/pull/1",
                  "isDraft":false,"state":"OPEN","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z",
                  "headRefName":"\(branch)","author":{"login":"good"},
                  "repository":{"nameWithOwner":"o/r","viewerPermission":"WRITE"},"reviewDecision":null,
                  "autoMergeRequest":null,"mergeQueueEntry":null,
                  "reviewThreads":{"pageInfo":{"hasPreviousPage":false,"startCursor":null},"nodes":[]},
                  "commits":{"nodes":[]}}]}}}
                """)
            }
            if query.contains("mergeStateStatus") {
                return (200, #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}}}"#)
            }
            return (500, "")
        }
    }

    override func tearDownWithError() throws {
        URLProtocol.unregisterClass(GraphQLStub.self)
        GraphQLStub.respond = { _, _ in (500, "") }
        if let previousHome { setenv("COPILOT_HOME", previousHome, 1) } else { unsetenv("COPILOT_HOME") }
        try? FileManager.default.removeItem(at: root)
    }

    private func snapshot(_ tabs: [(id: String, copilotId: String?)]) -> WorkspaceSnapshot {
        WorkspaceSnapshot(hostProcessIdentifier: 1, selectedProjectId: "p", projects: [
            .init(id: "p", name: "P", sessions: tabs.map {
                .init(id: $0.id, title: "Other - GitHub Copilot", status: .idle, copilotSessionId: $0.copilotId)
            }),
        ])
    }

    @MainActor
    private func makeModel(_ workspace: FakeWorkspace, finder: any ResumableSessionSearching) -> PullRequestsModel {
        PullRequestsModel(
            workspace: workspace, defaults: UserDefaults(suiteName: UUID().uuidString)!,
            stateDirectory: root.appendingPathComponent("state"),
            service: PullRequestService(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint)),
            loadAccounts: { [accountLoads] in
                await accountLoads.bump()
                return [GitHubAccount(login: "good", token: "good")]
            },
            resumableFinder: finder, isVisible: { true }, presentError: { _, _ in }
        )
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let met = await condition()
        XCTAssertTrue(met)
    }

    @MainActor
    private func refreshed(_ model: PullRequestsModel) async throws {
        let loads = await accountLoads.value
        model.refresh()
        try await waitUntil { await self.accountLoads.value > loads && !model.isRefreshing }
    }

    @MainActor
    func testARefreshOffersTheEndedSessionForAPullRequestNoLiveSessionDrives() async throws {
        let work = root.appendingPathComponent("work")
        let ended = try home.addSession(
            cwd: work.path, name: "Resume from refresh", transcript: transcript(mentioning: branch, times: 4),
            said: ["Opened https://github.com/o/r/pull/1"]
        )
        let elsewhere = try home.addSession(cwd: work.path, transcript: transcript(mentioning: "me/other-work", times: 9))
        let workspace = FakeWorkspace(snapshot: snapshot([("tab", elsewhere)]))
        let model = makeModel(workspace, finder: ResumableSessionFinder(
            store: home.store, cacheURL: root.appendingPathComponent("state/resumable-index.json")
        ))
        try await refreshed(model)
        try await waitUntil { model.resumable[self.key] != nil }
        XCTAssertEqual(model.resumable[key]?.copilotSessionId, ended)
        XCTAssertEqual(model.resumable[key]?.name, "Resume from refresh")
        XCTAssertEqual(model.goals().first?.resumable?.copilotSessionId, ended)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state/resumable-index.json").path))

        // Opened again in a tab, it drives the pull request live instead.
        workspace.answer(fetches: [.snapshot(snapshot([("tab", ended)]))])
        await model.pollWorkspace()
        try await waitUntil { model.links[self.key] == "tab" && model.resumable.isEmpty && !model.isRefreshing }
        let loads = await accountLoads.value
        XCTAssertEqual(loads, 2, "its coming back matched the transcripts again by itself")
        XCTAssertNil(model.goals().first?.resumable)
        XCTAssertEqual(model.goals().first?.session?.id, "tab")

        // Copilot Projects goes away: what was found stays until it can be checked again.
        workspace.answer(fetches: [.snapshot(snapshot([("tab", elsewhere)]))])
        await model.pollWorkspace()
        try await refreshed(model)
        try await waitUntil { model.resumable[self.key]?.copilotSessionId == ended }
        workspace.answer(fetches: [.unreachable])
        await model.pollWorkspace()
        try await refreshed(model)
        XCTAssertEqual(model.resumable[key]?.copilotSessionId, ended)
    }

    @MainActor
    func testCandidatesTheBudgetDeferredAreFoundWithoutAnotherRefresh() async throws {
        let work = root.appendingPathComponent("work").path
        try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_700_000_000),
            transcript: transcript(mentioning: branch, times: 3), said: ["github.com/o/r/pull/1"]
        )
        let numbered = try home.addSession(
            cwd: work, updated: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: transcript(mentioning: branch, times: 6), refs: [1]
        )
        let workspace = FakeWorkspace(snapshot: snapshot([]))
        let budget = try Data(contentsOf: home.root.appendingPathComponent("session-state/\(numbered)/events.jsonl")).count
        let model = makeModel(workspace, finder: ResumableSessionFinder(store: home.store, cacheURL: nil, byteBudget: budget))
        try await refreshed(model)
        try await waitUntil { model.resumable[self.key]?.copilotSessionId == numbered }
        let loads = await accountLoads.value
        XCTAssertEqual(loads, 1, "the search kept going on its own")
    }

    @MainActor
    func testASlowSearchNeverHoldsUpTheRefreshAndANewRefreshReplacesIt() async throws {
        func candidate(_ id: String) -> ResumableSession {
            ResumableSession(copilotSessionId: id, name: "Slow", cwd: "/work", lastActive: testNow)
        }
        let replaced = candidate("0f1e2d3c-4b5a-4000-8000-0000000000cc")
        let current = candidate("0f1e2d3c-4b5a-4000-8000-0000000000cf")
        let finder = ScriptedResumableSearch(
            [ResumableSearch(sessions: [key: replaced]), ResumableSearch(sessions: [key: current])], holding: true
        )
        let model = makeModel(FakeWorkspace(snapshot: snapshot([])), finder: finder)
        model.refresh()
        try await waitUntil { model.lastUpdated != nil && !model.isRefreshing }
        XCTAssertEqual(model.pullRequests.map(\.key), [key])
        XCTAssertEqual(model.phase, .loaded)
        try await waitUntil { await finder.searches == 1 }
        XCTAssertTrue(model.resumable.isEmpty, "the search is still running")

        try await refreshed(model)
        try await waitUntil { await finder.searches == 2 }
        await finder.release()
        try await waitUntil { model.resumable[self.key] == current }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.resumable[key], current, "the replaced search's answer is dropped")
    }

    @MainActor
    func testAResumedSessionKeepsItsPullRequestsUntilTheyAreLinkedToItsTab() async throws {
        let resumedId = "0f1e2d3c-4b5a-4000-8000-0000000000dd"
        let candidate = ResumableSession(copilotSessionId: resumedId, name: "Resumed", cwd: "/work", lastActive: testNow)
        // After the first search, the finder skips it: in use while it resumes, then live in its tab.
        let finder = ScriptedResumableSearch([ResumableSearch(sessions: [key: candidate]), ResumableSearch()])
        let other = "0f1e2d3c-4b5a-4000-8000-0000000000ee"
        let workspace = FakeWorkspace(snapshot: snapshot([("other", other)]))
        let model = makeModel(workspace, finder: finder)
        try await refreshed(model)
        try await waitUntil { model.resumable[self.key] == candidate }

        workspace.answer(fetches: [.snapshot(snapshot([("other", other), ("back", nil)]))],
                         resumes: [.done(code: "created", text: "back")])
        model.resume(candidate, projectId: "p")
        try await waitUntil { workspace.revealCalls.count == 1 }
        try await refreshed(model)
        try await waitUntil { await finder.searches == 2 }
        try await Task.sleep(nanoseconds: 50_000_000)
        var goal = try XCTUnwrap(model.goals().first)
        XCTAssertEqual(goal.resumable, candidate, "still resuming: the lane says so rather than offering Start Session")
        XCTAssertTrue(model.resumingSessions.contains(resumedId))

        // Copilot reports it live; its transcript doesn't name the branch enough to link it by itself.
        workspace.answer(fetches: [.snapshot(snapshot([("other", other), ("back", resumedId)]))])
        await model.pollWorkspace()
        XCTAssertTrue(model.resumingSessions.isEmpty)
        goal = try XCTUnwrap(model.goals().first)
        XCTAssertEqual(goal.session?.id, "back")
        XCTAssertNil(goal.resumable)
        try await waitUntil { await self.accountLoads.value == 3 && !model.isRefreshing }
        try await waitUntil { await finder.searches == 3 }
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<3 { await model.pollWorkspace() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let loads = await accountLoads.value
        XCTAssertEqual(loads, 3, "matched again once when it appeared, not on every poll")
        XCTAssertNil(model.links[key])
        XCTAssertEqual(model.resumable[key], candidate, "kept while its tab drives it without a link")
        goal = try XCTUnwrap(model.goals().first)
        XCTAssertEqual(goal.session?.id, "back", "the pull request stays on the resumed tab")
        XCTAssertNil(goal.resumable)
    }
}
