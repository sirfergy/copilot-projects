import Foundation
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

/// Transcripts the index reads, with a stamp that changes whenever one is replaced.
private final class FakeTranscripts: @unchecked Sendable {
    private let lock = NSLock()
    private var transcripts: [String: TranscriptSnapshot] = [:]
    private var versions: [String: UInt64] = [:]
    private var dates: [String: Date] = [:]
    private var loads: [String: Int] = [:]
    var onLoad: @Sendable (String) -> Void = { _ in }

    func set(_ sessionId: String, requests: [String], replies: [String] = [], at date: Date = Date()) {
        let turns = requests.enumerated().map { index, request in
            TranscriptTurn(
                id: "t\(index)", startedAt: date.addingTimeInterval(-60), endedAt: date,
                kind: "user", userContent: request,
                assistantMessages: index < replies.count
                    ? [TranscriptAssistantMessage(id: "a\(index)", timestamp: date, content: replies[index])]
                    : [],
                tools: [], isAborted: false
            )
        }
        lock.withLock {
            transcripts[sessionId] = TranscriptSnapshot(
                schemaVersion: 3, updatedAt: date, copilotSessionId: "copilot", turns: turns
            )
            versions[sessionId, default: 0] += 1
            dates[sessionId] = date
        }
    }

    /// Changes when the transcript file was written without changing its conversation.
    func touch(_ sessionId: String, at date: Date) {
        lock.withLock {
            versions[sessionId, default: 0] += 1
            dates[sessionId] = date
        }
    }

    func stamp(_ sessionId: String) -> SessionSearchIndex.Stamp {
        let (version, date) = lock.withLock { (versions[sessionId], dates[sessionId]) }
        return SessionSearchIndex.Stamp(
            transcript: version.map {
                FileSignature(attributes: [
                    .size: NSNumber(value: $0), .systemFileNumber: NSNumber(value: 1),
                    .modificationDate: date ?? Date(),
                ])
            },
            owner: nil, quarantine: nil
        )
    }

    func load(_ sessionId: String) -> TranscriptSnapshot? {
        onLoad(sessionId)
        return lock.withLock {
            loads[sessionId, default: 0] += 1
            return transcripts[sessionId]
        }
    }

    func loadCount(_ sessionId: String) -> Int { lock.withLock { loads[sessionId] ?? 0 } }
    var totalLoads: Int { lock.withLock { loads.values.reduce(0, +) } }

    func index(idleLifetime: TimeInterval = 600, now: @escaping @Sendable () -> Date = { Date() }) -> SessionSearchIndex {
        SessionSearchIndex(
            stamp: { [self] in stamp($0) }, loadTranscript: { [self] in load($0) },
            idleLifetime: idleLifetime, now: now
        )
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Answers once released, recording every query it is asked.
private final class GatedRanker: SessionRanking, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var asked: [String] = []
    private var sizes: [Int] = []
    var result: Result<[LunaMatch], Error>
    /// Queries answered at once, so a run that should have been refused can't hang the test.
    var ungated: Set<String> = []

    init(_ result: Result<[LunaMatch], Error> = .success([])) { self.result = result }

    var queries: [String] { lock.withLock { asked } }
    var entryCounts: [Int] { lock.withLock { sizes } }
    var waitingCount: Int { lock.withLock { waiting.count } }

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        if lock.withLock({ ungated.contains(query) }) {
            lock.withLock { asked.append(query) }
            return try result.get()
        }
        await withCheckedContinuation { continuation in
            lock.withLock {
                asked.append(query)
                sizes.append(entries.count)
                waiting.append(continuation)
            }
        }
        return try result.get()
    }

    func releaseOne() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            waiting.isEmpty ? nil : waiting.removeFirst()
        }
        next?.resume()
    }
}

/// Runs until cancelled, like a Luna run nobody waits for any more.
private final class EndlessRanker: SessionRanking, @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0
    private var stopped = 0
    var startedCount: Int { lock.withLock { started } }
    var cancelledCount: Int { lock.withLock { stopped } }

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        lock.withLock { started += 1 }
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            lock.withLock { stopped += 1 }
            throw error
        }
        return []
    }
}

@MainActor
final class RemoteSessionSearchTests: XCTestCase {
    private func source(_ id: String, _ title: String, project: String = "p1", cwd: String = "/r/work") -> SessionFinderSource {
        SessionFinderSource(
            sessionId: id, projectId: project, projectName: "Project \(project)", title: title, cwd: cwd
        )
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    private func matches(_ outcome: RemoteSessionSearchOutcome, mode: RemoteSessionSearchMode) -> [RemoteSessionSearchMatch]? {
        guard case .results(let response) = outcome, response.mode == mode else {
            XCTFail("Expected \(mode) results, got \(outcome)")
            return nil
        }
        return response.matches
    }

    // MARK: - Validation

    func testEmptyAndOversizedQueriesAreInvalidWithoutReadingOrAskingLuna() async {
        let transcripts = FakeTranscripts()
        let ranker = GatedRanker()
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: ranker)
        let sources = [source("a", "Webhook retries")]
        let oversized = String(repeating: "x", count: RemoteSessionSearchContract.maximumQueryLength + 1)

        for mode in [RemoteSessionSearchMode.instant, .luna] {
            let empty = await search.search(.init(query: " \n\t ", mode: mode)) { sources }
            XCTAssertEqual(empty, .invalid("Enter something to search for."))
            let long = await search.search(.init(query: "  \(oversized)  ", mode: mode)) { sources }
            XCTAssertEqual(long, .invalid("Searches can be at most 300 characters."))
        }
        XCTAssertEqual(transcripts.totalLoads, 0)
        XCTAssertEqual(ranker.queries, [])
        XCTAssertEqual(search.activeLunaRuns, 0)

        let longest = String(repeating: "x", count: RemoteSessionSearchContract.maximumQueryLength)
        let accepted = await search.search(.init(query: " \(longest) ", mode: .instant)) { sources }
        XCTAssertEqual(accepted, .results(.init(mode: .instant, matches: [])))
    }

    // MARK: - Instant

    func testInstantRanksNamesBeforeConversationWithSnippetsAndProjects() async {
        let transcripts = FakeTranscripts()
        let now = Date()
        transcripts.set("named", requests: ["unrelated"], at: now.addingTimeInterval(-3_600))
        transcripts.set("talked", requests: ["the billing webhook keeps timing out"], at: now)
        transcripts.set("other", requests: ["release notes"], at: now)
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: GatedRanker())
        let sources = [
            source("talked", "Investigate flake", project: "p1"),
            source("named", "Webhook retries", project: "p2"),
            source("other", "Release notes", project: "p1"),
        ]

        let outcome = await search.search(.init(query: "  WEBHOOK  ", mode: .instant)) { sources }

        XCTAssertEqual(matches(outcome, mode: .instant), [
            RemoteSessionSearchMatch(
                sessionId: "named", projectId: "p2", lastActivityAt: now.addingTimeInterval(-3_600)
            ),
            RemoteSessionSearchMatch(
                sessionId: "talked", projectId: "p1", snippet: "the billing webhook keeps timing out",
                lastActivityAt: now
            ),
        ])
    }

    func testInstantReturnsAtMostTheContractLimit() async {
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: GatedRanker())
        let sources = (0..<(RemoteSessionSearchContract.maximumMatches + 10)).map {
            source("s\($0)", "Webhook \($0)")
        }
        let outcome = await search.search(.init(query: "webhook", mode: .instant)) { sources }
        XCTAssertEqual(matches(outcome, mode: .instant)?.count, RemoteSessionSearchContract.maximumMatches)
    }

    func testResultsLeaveOutSessionsThatEndAndFollowSessionsThatMoveDuringTheSearch() async {
        let transcripts = FakeTranscripts()
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: GatedRanker())
        let before = [source("stays", "Webhook retries"), source("ends", "Webhook cleanup")]
        let after = [source("stays", "Webhook retries", project: "p9")]
        var reads = 0
        let outcome = await search.search(.init(query: "webhook", mode: .instant)) {
            reads += 1
            return reads == 1 ? before : after
        }
        XCTAssertEqual(matches(outcome, mode: .instant), [RemoteSessionSearchMatch(sessionId: "stays", projectId: "p9")])
    }

    // MARK: - Recent

    func testRecentListsEveryLiveSessionByTranscriptTimeWithoutReadingOrAskingLuna() async {
        let transcripts = FakeTranscripts()
        let base = Date(timeIntervalSince1970: 1_791_297_000)
        for id in ["a", "c", "e"] {
            transcripts.set(id, requests: ["about \(id)"], at: base.addingTimeInterval(-86_400))
        }
        transcripts.touch("a", at: base.addingTimeInterval(-60))
        transcripts.touch("c", at: base)
        transcripts.touch("e", at: base.addingTimeInterval(-60))
        let ranker = GatedRanker()
        let index = transcripts.index()
        let search = RemoteSessionSearch(index: index, ranker: ranker)
        let sources = [
            source("a", "Alpha"), source("b", "Plain terminal"), source("c", "Gamma", project: "p2"),
            source("d", "Another terminal"), source("e", "Epsilon"), source("a", "Alpha again"),
        ]
        let expected = [
            RemoteSessionSearchMatch(sessionId: "c", projectId: "p2", lastActivityAt: base),
            RemoteSessionSearchMatch(sessionId: "a", projectId: "p1", lastActivityAt: base.addingTimeInterval(-60)),
            RemoteSessionSearchMatch(sessionId: "e", projectId: "p1", lastActivityAt: base.addingTimeInterval(-60)),
            RemoteSessionSearchMatch(sessionId: "b", projectId: "p1"),
            RemoteSessionSearchMatch(sessionId: "d", projectId: "p1"),
        ]

        // The query is ignored, and may be empty.
        for query in ["", " \n\t ", "gamma"] {
            let outcome = await search.search(.init(query: query, mode: .recent)) { sources }
            XCTAssertEqual(matches(outcome, mode: .recent), expected)
        }
        XCTAssertEqual(transcripts.totalLoads, 0)
        XCTAssertEqual(ranker.queries, [])
        XCTAssertEqual(search.activeLunaRuns, 0)

        // A newer write moves the session up without its transcript being read.
        transcripts.touch("e", at: base.addingTimeInterval(1))
        let moved = await search.search(.init(query: "", mode: .recent)) { sources }
        XCTAssertEqual(matches(moved, mode: .recent)?.map(\.sessionId), ["e", "c", "a", "b", "d"])
        XCTAssertEqual(transcripts.totalLoads, 0)
        let cached = await index.cachedSessionIds
        XCTAssertEqual(cached, [])
    }

    func testRecentRejectsOnlyOversizedQueries() async {
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: GatedRanker())
        let oversized = String(repeating: "x", count: RemoteSessionSearchContract.maximumQueryLength + 1)
        let outcome = await search.search(.init(query: oversized, mode: .recent)) { [source("a", "A")] }
        XCTAssertEqual(outcome, .invalid("Searches can be at most 300 characters."))
    }

    func testRecentIsCappedAfterLeavingOutSessionsThatEndDuringTheSearch() async {
        let transcripts = FakeTranscripts()
        let base = Date(timeIntervalSince1970: 1_791_297_000)
        let count = RemoteSessionSearchContract.maximumMatches + 10
        let before = (0..<count).map { index in
            transcripts.touch("s\(index)", at: base.addingTimeInterval(TimeInterval(index)))
            return source("s\(index)", "Session \(index)")
        }
        // The newest session ends, and the next newest moves, while the search runs.
        let newest = "s\(count - 1)", moving = "s\(count - 2)"
        let after = before.compactMap { listed -> SessionFinderSource? in
            listed.sessionId == newest ? nil
                : listed.sessionId == moving ? source(moving, "Moved", project: "p9") : listed
        }
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: GatedRanker())
        var reads = 0
        let outcome = await search.search(.init(query: "", mode: .recent)) {
            reads += 1
            return reads == 1 ? before : after
        }
        let found = matches(outcome, mode: .recent) ?? []
        XCTAssertEqual(found.count, RemoteSessionSearchContract.maximumMatches)
        XCTAssertEqual(found.first, RemoteSessionSearchMatch(
            sessionId: moving, projectId: "p9", lastActivityAt: base.addingTimeInterval(TimeInterval(count - 2))
        ))
        XCTAssertEqual(
            found.map(\.sessionId),
            (0..<(count - 1)).reversed().prefix(RemoteSessionSearchContract.maximumMatches).map { "s\($0)" }
        )
    }

    func testCancelledRecentSearchReportsCancellation() async {
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: GatedRanker())
        let sources = [source("a", "A")]
        let outcome = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await search.search(.init(query: "", mode: .recent)) { sources }
        }.value
        XCTAssertEqual(outcome, .failed(RemoteSessionSearch.cancelledMessage))
    }

    func testEveryModeDatesSessionsByTheirTranscriptFileNotTheirLastTurn() async throws {
        let transcripts = FakeTranscripts()
        let turnTime = Date(timeIntervalSince1970: 1_791_200_000)
        let written = Date(timeIntervalSince1970: 1_791_297_000.5)
        transcripts.set("a", requests: ["billing webhook"], at: turnTime)
        transcripts.touch("a", at: written)
        let ranker = GatedRanker(.success([
            LunaMatch(sessionId: "a", reason: "webhooks"), LunaMatch(sessionId: "terminal", reason: "shell"),
        ]))
        ranker.ungated = ["webhook"]
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: ranker)
        let sources = [source("terminal", "Webhook shell"), source("a", "Alpha")]

        let instant = await search.search(.init(query: "webhook", mode: .instant)) { sources }
        let luna = await search.search(.init(query: "webhook", mode: .luna)) { sources }
        let recent = await search.search(.init(query: "", mode: .recent)) { sources }
        for (outcome, mode) in [(instant, RemoteSessionSearchMode.instant), (luna, .luna), (recent, .recent)] {
            let found = try XCTUnwrap(matches(outcome, mode: mode))
            let times = Dictionary(uniqueKeysWithValues: found.map { ($0.sessionId, $0.lastActivityAt) })
            XCTAssertEqual(times.count, 2, "\(mode)")
            XCTAssertEqual(times["a"], written, "\(mode)")
            XCTAssertEqual(times["terminal"], .some(nil), "\(mode)")
        }
    }

    // MARK: - Index cache

    func testIndexReadsOnlyTranscriptsThatChangedAndForgetsEndedSessions() async throws {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: ["first idea"])
        transcripts.set("b", requests: ["billing webhook"])
        let index = transcripts.index()
        let sources = [source("a", "Alpha"), source("b", "Beta"), source("c", "Plain terminal")]

        let first = await index.entries(for: sources)
        XCTAssertEqual(first?.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(["a", "b", "c"].map(transcripts.loadCount), [1, 1, 1])
        let second = await index.entries(for: sources)
        XCTAssertEqual(second, first)
        XCTAssertEqual(["a", "b", "c"].map(transcripts.loadCount), [1, 1, 1])

        transcripts.set("a", requests: ["first idea", "now about the ledger"])
        let reread = await index.entries(for: sources)
        let refreshed = try XCTUnwrap(reread)
        XCTAssertEqual(["a", "b", "c"].map(transcripts.loadCount), [2, 1, 1])
        XCTAssertEqual(refreshed.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(
            SessionFinderSearch.localMatches(for: "ledger", in: refreshed).map(\.entry.id), ["a"]
        )
        XCTAssertEqual(refreshed[0].lastActivity, transcripts.stamp("a").lastActivity)

        _ = await index.entries(for: [source("b", "Beta")])
        let cached = await index.cachedSessionIds
        XCTAssertEqual(cached, ["b"])
    }

    func testRenamedAndMovedSessionsAreReindexedWithoutReadingTheirTranscripts() async throws {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: ["billing webhook"])
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: GatedRanker())
        _ = await search.search(.init(query: "billing", mode: .instant)) { [source("a", "Old name")] }

        let renamed = [source("a", "Ledger cleanup", project: "p2", cwd: "/r/ledger")]
        let byName = await search.search(.init(query: "ledger", mode: .instant)) { renamed }
        XCTAssertEqual(matches(byName, mode: .instant), [
            RemoteSessionSearchMatch(sessionId: "a", projectId: "p2", lastActivityAt: transcripts.stamp("a").lastActivity),
        ])
        let stale = await search.search(.init(query: "old", mode: .instant)) { renamed }
        XCTAssertEqual(matches(stale, mode: .instant), [])
        let conversation = await search.search(.init(query: "webhook", mode: .instant)) { renamed }
        XCTAssertEqual(matches(conversation, mode: .instant)?.map(\.snippet), ["billing webhook"])
        XCTAssertEqual(transcripts.loadCount("a"), 1)
    }

    func testUnreadableConversationsAreRetriedAfterAPauseEvenWhenUnchanged() async throws {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: [])
        let clock = Clock()
        let index = transcripts.index(now: { clock.now })
        let sources = [source("a", "Alpha"), source("terminal", "Shell")]

        _ = await index.entries(for: sources)
        clock.advance(SessionSearchIndex.emptyRetryInterval - 1)
        _ = await index.entries(for: sources)
        XCTAssertEqual(transcripts.loadCount("a"), 1)

        clock.advance(1)
        _ = await index.entries(for: sources)
        XCTAssertEqual(transcripts.loadCount("a"), 2)
        // A session without a transcript file has nothing to retry.
        XCTAssertEqual(transcripts.loadCount("terminal"), 1)
    }

    func testCancelledIndexingStopsBetweenSessionsAndKeepsWhatItRead() async throws {
        let transcripts = FakeTranscripts()
        for id in ["a", "b", "c"] { transcripts.set(id, requests: ["about \(id)"]) }
        transcripts.onLoad = { id in
            if id == "b" { withUnsafeCurrentTask { $0?.cancel() } }
        }
        let index = transcripts.index()
        let sources = [source("a", "A"), source("b", "B"), source("c", "C")]

        let cancelled = await Task { await index.entries(for: sources) }.value
        XCTAssertNil(cancelled)
        XCTAssertEqual(["a", "b", "c"].map(transcripts.loadCount), [1, 1, 0])

        transcripts.onLoad = { _ in }
        let resumed = await index.entries(for: sources)
        let entries = try XCTUnwrap(resumed)
        XCTAssertEqual(entries.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(["a", "b", "c"].map(transcripts.loadCount), [1, 1, 1])
    }

    func testCancelledInstantSearchReportsCancellation() async {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: ["webhook"])
        transcripts.onLoad = { _ in withUnsafeCurrentTask { $0?.cancel() } }
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: GatedRanker())
        let sources = [source("a", "Webhook"), source("b", "Webhook too")]
        let outcome = await Task { @MainActor in
            await search.search(.init(query: "webhook", mode: .instant)) { sources }
        }.value
        XCTAssertEqual(outcome, .failed(RemoteSessionSearch.cancelledMessage))
    }

    func testIdleIndexDropsItsConversations() async throws {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: ["webhook"])
        let index = transcripts.index(idleLifetime: 0.05)
        _ = await index.entries(for: [source("a", "A")])
        try await Task.sleep(nanoseconds: 300_000_000)
        let cached = await index.cachedSessionIds
        XCTAssertEqual(cached, [])
        _ = await index.entries(for: [source("a", "A")])
        XCTAssertEqual(transcripts.loadCount("a"), 2)
    }

    // MARK: - Luna

    func testLunaRanksTheSameEntriesAndReportsReasonsForLiveSessions() async throws {
        let transcripts = FakeTranscripts()
        transcripts.set("a", requests: ["retry the billing webhook"])
        let ranker = GatedRanker(.success([
            LunaMatch(sessionId: "b", reason: "ledger work"),
            LunaMatch(sessionId: "gone", reason: "ended"),
            LunaMatch(sessionId: "a", reason: ""),
        ]))
        let search = RemoteSessionSearch(index: transcripts.index(), ranker: ranker)
        let sources = [source("a", "Webhook"), source("b", "Ledger", project: "p2"), source("gone", "Old")]
        let live = Array(sources.prefix(2))
        let reads = ReadCount()
        let task = Task { @MainActor in
            await search.search(.init(query: "  money   stuff \n", mode: .luna)) {
                reads.value += 1
                return reads.value == 1 ? sources : live
            }
        }
        try await waitUntil { ranker.waitingCount == 1 }
        ranker.releaseOne()
        let outcome = await task.value

        XCTAssertEqual(ranker.queries, ["money stuff"])
        XCTAssertEqual(ranker.entryCounts, [3])
        XCTAssertEqual(matches(outcome, mode: .luna), [
            RemoteSessionSearchMatch(sessionId: "b", projectId: "p2", reason: "ledger work"),
            RemoteSessionSearchMatch(sessionId: "a", projectId: "p1", lastActivityAt: transcripts.stamp("a").lastActivity),
        ])
        XCTAssertEqual(search.activeLunaRuns, 0)
    }

    func testLunaWithNoLiveSessionsAnswersWithoutRunning() async {
        let ranker = GatedRanker()
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: ranker)
        let outcome = await search.search(.init(query: "anything", mode: .luna)) { [] }
        XCTAssertEqual(outcome, .results(.init(mode: .luna, matches: [])))
        XCTAssertEqual(ranker.queries, [])
    }

    func testLunaFailuresUseTheFinderMessages() async {
        let sources = [source("a", "A")]
        for error in [LunaSearchError.notSignedIn, .timedOut, .unreadableResponse, .failed("exit status 2")] {
            let ranker = FailingRanker(error)
            let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: ranker)
            let outcome = await search.search(.init(query: "q", mode: .luna)) { sources }
            XCTAssertEqual(outcome, .failed(error.message))
            XCTAssertEqual(search.activeLunaRuns, 0)
        }
        let missing = RemoteSessionSearch(
            index: FakeTranscripts().index(), ranker: LunaSessionRanker(copilotExecutable: { nil })
        )
        let outcome = await missing.search(.init(query: "q", mode: .luna)) { sources }
        XCTAssertEqual(outcome, .failed("Luna needs the Copilot CLI, which wasn't found."))
    }

    func testAtMostTwoLunaRunsAtOnceAndFinishedRunsFreeTheirSlots() async throws {
        let ranker = GatedRanker()
        ranker.ungated = ["three"]
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: ranker)
        let sources = [source("a", "Webhook")]
        let first = Task { @MainActor in await search.search(.init(query: "one", mode: .luna)) { sources } }
        let second = Task { @MainActor in await search.search(.init(query: "two", mode: .luna)) { sources } }
        try await waitUntil { ranker.waitingCount == 2 }
        XCTAssertEqual(search.activeLunaRuns, 2)

        let third = await search.search(.init(query: "three", mode: .luna)) { sources }
        XCTAssertEqual(third, .busy)
        let instant = await search.search(.init(query: "webhook", mode: .instant)) { sources }
        XCTAssertEqual(matches(instant, mode: .instant)?.map(\.sessionId), ["a"])

        ranker.releaseOne()
        try await waitUntil { search.activeLunaRuns == 1 }
        let fourth = Task { @MainActor in await search.search(.init(query: "four", mode: .luna)) { sources } }
        try await waitUntil { ranker.waitingCount == 2 }
        XCTAssertEqual(search.activeLunaRuns, 2)
        ranker.releaseOne()
        ranker.releaseOne()
        for task in [first, second, fourth] {
            let outcome = await task.value
            XCTAssertEqual(outcome, .results(.init(mode: .luna, matches: [])))
        }
        XCTAssertEqual(search.activeLunaRuns, 0)
        XCTAssertEqual(ranker.queries.sorted(), ["four", "one", "two"])
    }

    func testCancellingALunaSearchStopsTheRankerAndFreesItsSlot() async throws {
        let ranker = EndlessRanker()
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: ranker)
        let sources = [source("a", "A")]
        let tasks = (0..<2).map { _ in
            Task { @MainActor in await search.search(.init(query: "q", mode: .luna)) { sources } }
        }
        try await waitUntil { ranker.startedCount == 2 }
        let busy = await search.search(.init(query: "q", mode: .luna)) { sources }
        XCTAssertEqual(busy, .busy)

        tasks[0].cancel()
        let outcome = await tasks[0].value
        XCTAssertEqual(outcome, .failed(RemoteSessionSearch.cancelledMessage))
        XCTAssertEqual(ranker.cancelledCount, 1)
        XCTAssertEqual(search.activeLunaRuns, 1)

        tasks[1].cancel()
        _ = await tasks[1].value
        XCTAssertEqual(search.activeLunaRuns, 0)
    }

    func testCancellingALunaSearchTerminatesTheCopilotProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("pid")
        let script = root.appendingPathComponent("copilot")
        // `exec` keeps the shell's pid, so the recorded pid is the running copilot.
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec /bin/sleep 30\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let path = script.path
        let ranker = LunaSessionRanker(
            copilotExecutable: { path }, workRoot: root.appendingPathComponent("runs"),
            environment: ["PATH": "/usr/bin:/bin", "COPILOT_HOME": root.path]
        )
        let search = RemoteSessionSearch(index: FakeTranscripts().index(), ranker: ranker)
        let sources = [source("a", "A")]
        let task = Task { @MainActor in await search.search(.init(query: "q", mode: .luna)) { sources } }
        try await waitUntil {
            ((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        let pid = try XCTUnwrap(pid_t(
            String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        let copilot = try XCTUnwrap(LunaProcess.ProcessIdentity(pid))

        let cancelled = Date()
        task.cancel()
        let outcome = await task.value

        XCTAssertEqual(outcome, .failed(RemoteSessionSearch.cancelledMessage))
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        XCTAssertFalse(copilot.isCurrent)
        XCTAssertEqual(search.activeLunaRuns, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path), [])
    }

    // MARK: - Host boundary

    func testOtherHostsDoNotSupportSearch() async {
        let host: any SessionHost = MinimalSessionHost()
        XCTAssertFalse(host.supportsSessionSearch)
        XCTAssertEqual(host.sessionSearchCapabilities, [])
        for mode in [RemoteSessionSearchMode.instant, .luna, .recent] {
            let outcome = await host.searchSessions(.init(query: "anything", mode: mode))
            XCTAssertEqual(outcome, .unsupported)
        }
    }

    func testOlderHostsAnswerCursorRequestsWithTheirUsualTranscript() async throws {
        let host: any SessionHost = MinimalSessionHost()
        let cursor = try XCTUnwrap(TranscriptCursor(afterMilliseconds: 1, copilotSessionId: "c"))
        let data = await host.transcript(sessionId: "s", limit: 5, after: cursor)
        XCTAssertEqual(data.map { String(decoding: $0, as: UTF8.self) }, "legacy s 5")
    }

    func testBridgeSearchesTheModelsLiveSessions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let webhook = Session(id: "webhook", title: "Webhook retries", cwd: root.path)
        let docs = Session(id: "docs", title: "Release notes", cwd: root.path)
        try repository.save(PersistedState(
            projects: [
                Project(id: "p1", name: "Payments", cwd: root.path, sessions: [webhook], selectedSessionId: webhook.id),
                Project(id: "p2", name: "Docs", cwd: root.path, sessions: [docs], selectedSessionId: docs.id),
            ],
            selectedProjectId: "p1"
        ))
        var model: AppModel? = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root
        )
        let transcripts = FakeTranscripts()
        let ranker = GatedRanker(.success([LunaMatch(sessionId: "docs", reason: "release work")]))
        model?.remoteSessionSearch = RemoteSessionSearch(index: transcripts.index(), ranker: ranker)
        let bridge: any SessionHost = RemoteModelBridge(model: try XCTUnwrap(model))
        XCTAssertTrue(bridge.supportsSessionSearch)
        XCTAssertEqual(
            bridge.sessionSearchCapabilities,
            [RemoteSessionSearchContract.capability, RemoteSessionSearchContract.recentCapability]
        )

        let instant = await bridge.searchSessions(.init(query: "payments", mode: .instant))
        XCTAssertEqual(matches(instant, mode: .instant), [RemoteSessionSearchMatch(sessionId: "webhook", projectId: "p1")])

        let luna = Task { @MainActor in await bridge.searchSessions(.init(query: "shipping", mode: .luna)) }
        try await waitUntil { ranker.waitingCount == 1 }
        ranker.releaseOne()
        let lunaOutcome = await luna.value
        XCTAssertEqual(matches(lunaOutcome, mode: .luna), [
            RemoteSessionSearchMatch(sessionId: "docs", projectId: "p2", reason: "release work"),
        ])
        XCTAssertEqual(ranker.entryCounts, [2])

        transcripts.touch("docs", at: Date(timeIntervalSince1970: 1_791_297_000))
        let recent = await bridge.searchSessions(.init(query: "", mode: .recent))
        XCTAssertEqual(matches(recent, mode: .recent), [
            RemoteSessionSearchMatch(
                sessionId: "docs", projectId: "p2", lastActivityAt: Date(timeIntervalSince1970: 1_791_297_000)
            ),
            RemoteSessionSearchMatch(sessionId: "webhook", projectId: "p1"),
        ])

        model = nil
        let released = await bridge.searchSessions(.init(query: "payments", mode: .instant))
        XCTAssertEqual(released, .failed("Copilot Projects is closing."))
    }
}

@MainActor
private final class ReadCount {
    var value = 0
}

private struct FailingRanker: SessionRanking {
    let error: LunaSearchError
    init(_ error: LunaSearchError) { self.error = error }
    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] { throw error }
}

/// A conformer that predates session search.
@MainActor
private final class MinimalSessionHost: SessionHost {
    func workspace() -> RemoteWorkspaceSnapshot? { nil }
    func hasSession(_ sessionId: String) -> Bool { false }
    func createSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome { .unavailable }
    func createAdversarialReviewSession(_ request: RemoteCreateSessionRequest) -> RemoteSessionCreationOutcome {
        .unavailable
    }
    func screenRevision(sessionId: String) -> RemoteTerminalRevision? { nil }
    func screen(sessionId: String, revision: RemoteTerminalRevision, afterLine: Int?) -> RemoteTerminalScreen? { nil }
    func transcriptRevision(sessionId: String) -> RemoteTranscriptRevision {
        RemoteTranscriptRevision(sessionId: sessionId, generation: "")
    }
    func transcript(sessionId: String, limit: Int?) async -> Data? {
        Data("legacy \(sessionId) \(limit.map(String.init) ?? "all")".utf8)
    }
    func terminalImageData(sessionId: String, imageId: UInt32, version: UInt64) -> Data? { nil }
    func isRestoringImages(sessionId: String) -> Bool { false }
    func performControl(_ message: RemoteClientMessage, perform: () -> RemoteControlResult) -> RemoteControlResult {
        perform()
    }
    func sendInput(sessionId: String, value: String) -> RemoteTerminalInputResult { .missing }
    func sendKey(sessionId: String, key: String) -> RemoteTerminalInputResult { .missing }
    func sendCommand(sessionId: String, requestId: String, value: String) -> RemoteCommandResult { .missing }
    func sendScroll(sessionId: String, delta: Int) {}
    func markRead(sessionId: String) {}
    func closeSession(sessionId: String) -> RemoteSessionCloseResult { .failed }
    func moveSession(sessionId: String, toProjectId: String) -> RemoteSessionMoveResult { .missing }
    func sendPrompt(sessionId: String, value: String) -> RemotePromptResult { .invalid }
    func answerUserInput(
        sessionId: String, answer: RemoteUserInputAnswer, operation: CLIOperationRequest?
    ) -> RemoteUserInputResult { .invalid }
    func answerElicitation(
        sessionId: String, answer: RemoteElicitationAnswer, operation: CLIOperationRequest?
    ) -> RemoteUserInputResult { .invalid }
    func setModel(
        sessionId: String, selection: RemoteModelSelection, operation: CLIOperationRequest?
    ) -> RemoteUserInputResult { .invalid }
    func performSessionAction(
        sessionId: String, action: RemoteSessionAction, operation: CLIOperationRequest
    ) -> RemoteUserInputResult { .invalid }
}
