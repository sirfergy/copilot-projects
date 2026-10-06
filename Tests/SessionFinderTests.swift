import Foundation
import XCTest
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionFinderTests: XCTestCase {
    private func source(
        _ title: String, project: String = "Projects", cwd: String = "/tmp/work"
    ) -> SessionFinderSource {
        SessionFinderSource(
            sessionId: UUID().uuidString, projectId: "p-\(project)", projectName: project,
            title: title, cwd: cwd
        )
    }

    private func transcript(_ requests: [String], replies: [String] = [], endedAt: Date) -> TranscriptSnapshot {
        let turns = requests.enumerated().map { index, request in
            TranscriptTurn(
                id: "t\(index)", startedAt: endedAt.addingTimeInterval(-60), endedAt: endedAt,
                kind: "user", userContent: request,
                assistantMessages: index < replies.count
                    ? [TranscriptAssistantMessage(id: "a\(index)", timestamp: endedAt, content: replies[index])]
                    : [],
                tools: [], isAborted: false
            )
        }
        return TranscriptSnapshot(
            schemaVersion: 3, updatedAt: endedAt, copilotSessionId: "copilot", turns: turns
        )
    }

    private func entry(
        _ title: String, project: String = "Projects", cwd: String = "/tmp/work",
        requests: [String] = [], replies: [String] = [], endedAt: Date? = nil
    ) -> SessionFinderEntry {
        SessionFinderEntry(
            source: source(title, project: project, cwd: cwd),
            transcript: endedAt.map { transcript(requests, replies: replies, endedAt: $0) }
        )
    }

    // MARK: - Instant matching

    func testNamesOutrankConversationAndEveryWordMustMatch() {
        let now = Date()
        let conversation = entry(
            "Investigate flake", requests: ["the billing webhook keeps timing out"], endedAt: now
        )
        let named = entry("Billing webhook retries", endedAt: now.addingTimeInterval(-3_600))
        let unrelated = entry("Release notes", requests: ["billing"], endedAt: now)

        let matches = SessionFinderSearch.localMatches(
            for: "billing webhook", in: [conversation, named, unrelated]
        )

        XCTAssertEqual(matches.map(\.entry.id), [named.id, conversation.id])
        XCTAssertNil(matches[0].snippet)
        XCTAssertEqual(matches[1].snippet, "the billing webhook keeps timing out")
    }

    func testMatchingIgnoresCaseAndDiacriticsAndFindsProjectsAndFolders() {
        let accented = entry("Café menu", project: "Résumé site", cwd: "/Users/me/Repos/cafe-site")
        let other = entry("Unrelated")

        XCTAssertEqual(
            SessionFinderSearch.localMatches(for: "CAFE", in: [accented, other]).map(\.entry.id),
            [accented.id]
        )
        XCTAssertEqual(
            SessionFinderSearch.localMatches(for: "resume", in: [accented, other]).map(\.entry.id),
            [accented.id]
        )
        XCTAssertEqual(
            SessionFinderSearch.localMatches(for: "cafe-site", in: [accented, other]).map(\.entry.id),
            [accented.id]
        )
    }

    func testConversationMatchingIgnoresCaseAndDiacriticsAndCutsSnippetsForReturnedMatches() {
        let now = Date()
        let older = entry("Older", requests: ["Rebuilt the CAFÉ façade"], endedAt: now.addingTimeInterval(-60))
        let newer = entry("Newer", replies: ["x"], endedAt: now)
        let newest = entry(
            "Newest", requests: ["unrelated"], replies: ["the café Façade is done"], endedAt: now
        )

        let matches = SessionFinderSearch.localMatches(for: "cafe facade", in: [older, newer, newest])
        XCTAssertEqual(matches.map(\.entry.id), [older.id, newest.id])
        XCTAssertEqual(matches.map(\.snippet), ["Rebuilt the CAFÉ façade", "the café Façade is done"])

        let first = SessionFinderSearch.localMatches(for: "cafe", in: [older, newer, newest], limit: 1)
        XCTAssertEqual(first.map(\.entry.id), [older.id])
        XCTAssertEqual(first.first?.snippet, "Rebuilt the CAFÉ façade")
        XCTAssertFalse(SessionFinderSearch.containsBytes("cafe", in: ""))
    }

    func testLongConversationsKeepTheOpeningAndNewestRequestsWithinTheBudget() {
        let budget = SessionFinderEntry.maximumSearchCharacters
        let opening = "opening goal " + String(repeating: "o", count: SessionFinderEntry.maximumOpeningCharacters)
        let middle = (0..<4).map { "middle\($0) " + String(repeating: "m", count: budget / 3) }
        let long = entry(
            "Long", requests: [opening] + middle + ["latest ask"], endedAt: Date()
        )

        XCTAssertEqual(long.requests.first, String(opening.prefix(SessionFinderEntry.maximumOpeningCharacters)))
        XCTAssertEqual(long.requests.last, "latest ask")
        XCTAssertLessThan(long.requests.count, middle.count + 2)
        XCTAssertLessThanOrEqual(long.requests.reduce(0) { $0 + $1.count }, budget)
        XCTAssertEqual(SessionFinderSearch.localMatches(for: "opening goal", in: [long]).count, 1)
        XCTAssertEqual(SessionFinderSearch.localMatches(for: "latest", in: [long]).count, 1)
        XCTAssertTrue(SessionFinderSearch.localMatches(for: "middle0", in: [long]).isEmpty)
        XCTAssertTrue(
            LunaSessionPrompt.build(query: "goal", entries: [long]).prompt.contains("first asked: opening goal")
        )

        let short = entry("Short", requests: ["first", "second"], endedAt: Date())
        XCTAssertEqual(short.requests, ["first", "second"])
    }

    func testSnippetIsSingleLineAndMarksTrimmedEnds() {
        let text = String(repeating: "lead ", count: 20) + "needle\nin a\thaystack" + String(repeating: " tail", count: 20)
        let snippet = SessionFinderSearch.snippet(for: "needle", in: [text], radius: 10)
        XCTAssertEqual(snippet, "…lead lead needle in a hays…")
    }

    func testRecentOrdersByLastActivityThenWorkspaceOrder() {
        let now = Date()
        let plainA = entry("plain A")
        let old = entry("old", requests: ["x"], endedAt: now.addingTimeInterval(-86_400))
        let plainB = entry("plain B")
        let fresh = entry("fresh", requests: ["y"], endedAt: now)

        XCTAssertEqual(
            SessionFinderSearch.recent([plainA, old, plainB, fresh]).map(\.source.title),
            ["fresh", "old", "plain A", "plain B"]
        )
        XCTAssertTrue(SessionFinderSearch.localMatches(for: "   ", in: [plainA]).isEmpty)
    }

    func testIndexingStopsBetweenSessionsOnceCancelled() async {
        let sources = (0..<5).map { source("Session \($0)") }
        let (indexed, loads) = await Task.detached { () -> (Int, Int) in
            var loads = 0
            let entries = SessionFinderSearch.index(sources) { _ in
                loads += 1
                withUnsafeCurrentTask { $0?.cancel() }
                return nil
            }
            return (entries.count, loads)
        }.value
        XCTAssertEqual(indexed, 1)
        XCTAssertEqual(loads, 1)
    }

    // MARK: - Luna prompt and answer

    func testPromptListsSessionsByAliasWithinBudget() {
        let now = Date()
        let entries = (0..<200).map { index in
            entry(
                "Session \(index)", requests: [String(repeating: "word ", count: 200)],
                replies: [String(repeating: "reply ", count: 200)],
                endedAt: now.addingTimeInterval(TimeInterval(-index))
            )
        }
        let built = LunaSessionPrompt.build(query: "fix   the\nflaky test", entries: entries, now: now)

        XCTAssertTrue(built.prompt.contains("Looking for: fix the flaky test"))
        XCTAssertEqual(built.aliases["S1"], entries[0].id)
        XCTAssertTrue(built.prompt.contains("[S1] Session 0"))
        XCTAssertLessThan(built.aliases.count, entries.count)
        XCTAssertLessThan(built.prompt.count, LunaSessionPrompt.maximumSessionCharacters + 2_000)
    }

    func testParseAcceptsWrappedJSONAndDropsUnknownOrRepeatedIds() throws {
        let aliases = ["S1": "one", "S2": "two", "S3": "three"]
        let output = """
        Here you go:
        ```json
        {"matches":[{"id":"s2","reason":"Fixed the   flaky\\ntest"},{"id":"S9","reason":"made up"},{"id":"S2","reason":"again"},{"id":"S1"}]}
        ```
        """
        XCTAssertEqual(
            try LunaSessionPrompt.parse(output, aliases: aliases),
            [LunaMatch(sessionId: "two", reason: "Fixed the flaky test"), LunaMatch(sessionId: "one", reason: "")]
        )
        XCTAssertEqual(try LunaSessionPrompt.parse(#"{"matches":[]}"#, aliases: aliases), [])
        XCTAssertThrowsError(try LunaSessionPrompt.parse("I could not decide.", aliases: aliases))
        // Plain-text CLI output word-wraps long answers mid-string.
        XCTAssertEqual(
            try LunaSessionPrompt.parse("{\"matches\":[{\"id\":\"S3\",\"reason\":\"refunds around midnight\nUTC\"}]}", aliases: aliases),
            [LunaMatch(sessionId: "three", reason: "refunds around midnight UTC")]
        )
    }

    func testAssistantReplyIsTheLastAssistantMessageInJSONLOutput() {
        let output = """
        {"type":"session.mcp_servers_loaded","data":{"servers":[]}}
        {"type":"user.message","data":{"content":"{\\"matches\\":[{\\"id\\":\\"S9\\"}]}"}}
        {"type":"assistant.message","data":{"content":"","model":"gpt-6-luna"}}
        {"type":"assistant.message","data":{"content":"{\\"matches\\":[{\\"id\\":\\"S1\\",\\"reason\\":\\"a long reason that the text renderer would otherwise wrap\\"}]}","model":"gpt-6-luna"}}
        not json
        {"type":"result","data":{}}
        """
        XCTAssertEqual(
            LunaSessionRanker.assistantReply(fromJSONL: output),
            #"{"matches":[{"id":"S1","reason":"a long reason that the text renderer would otherwise wrap"}]}"#
        )
        XCTAssertNil(LunaSessionRanker.assistantReply(fromJSONL: #"{"matches":[]}"#))
    }

    func testParseKeepsAtMostFiveMatches() throws {
        let aliases = Dictionary(uniqueKeysWithValues: (1...8).map { ("S\($0)", "id\($0)") })
        let json = #"{"matches":["# + (1...8).map { #"{"id":"S\#($0)","reason":"r"}"# }.joined(separator: ",") + "]}"
        XCTAssertEqual(try LunaSessionPrompt.parse(json, aliases: aliases).map(\.sessionId), ["id1", "id2", "id3", "id4", "id5"])
    }

    // MARK: - Luna process

    func testArgumentsAlwaysUseLunaWithoutTools() {
        let arguments = LunaSessionRanker.arguments(prompt: "find it")
        XCTAssertEqual(LunaSessionRanker.model, "gpt-6-luna")
        XCTAssertEqual(arguments.prefix(2), ["-p", "find it"])
        let model = try? XCTUnwrap(arguments.firstIndex(of: "--model"))
        XCTAssertEqual(model.map { arguments[$0 + 1] }, "gpt-6-luna")
        let format = try? XCTUnwrap(arguments.firstIndex(of: "--output-format"))
        XCTAssertEqual(format.map { arguments[$0 + 1] }, "json")
        XCTAssertTrue(arguments.contains("--available-tools="))
        XCTAssertTrue(arguments.contains("--no-custom-instructions"))
        XCTAssertTrue(arguments.contains("--disable-builtin-mcps"))
        XCTAssertTrue(arguments.contains("--no-ask-user"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--allow") })
    }

    func testChildEnvironmentIsAnAllowlistWithAnIsolatedHome() {
        let child = LunaSessionRanker.childEnvironment(
            from: [
                "HOME": "/Users/me", "PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy",
                "COPILOT_PROJECTS_SESSION": "tab", "COPILOT_PROJECTS_SOCKET": "/tmp/s.sock",
                "COPILOT_PROJECTS_PROJECT": "p", "COPILOT_AGENT_SESSION_ID": "outer",
                "COPILOT_HOME": "/Users/me/.copilot", "OPENAI_API_KEY": "secret",
            ],
            copilotHome: "/tmp/run"
        )
        XCTAssertEqual(child, [
            "HOME": "/Users/me", "PATH": "/usr/bin", "HTTPS_PROXY": "http://proxy",
            "COPILOT_HOME": "/tmp/run", "COPILOT_AUTO_UPDATE": "false",
        ])
    }

    func testLoginSeedKeepsOnlyTheSignedInAccount() throws {
        let config = """
        // User settings belong in settings.json.
        // This file is managed automatically.
        {
          "firstLaunchAt": "2026-01-01T00:00:00.000Z",
          "lastLoggedInUser": {"host": "https://github.com", "login": "octocat"},
          "loggedInUsers": [{"host": "https://github.com", "login": "octocat", "kind": "user"}],
          "trustedFolders": ["/Users/octocat"],
          "installedPlugins": []
        }
        """
        let seed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: LunaSessionRanker.loginSeed(fromConfig: Data(config.utf8)))
                as? [String: Any]
        )
        XCTAssertEqual(Set(seed.keys), ["lastLoggedInUser", "loggedInUsers"])
        XCTAssertEqual(String(decoding: LunaSessionRanker.loginSeed(fromConfig: nil), as: UTF8.self), "{}")
        XCTAssertEqual(String(decoding: LunaSessionRanker.loginSeed(fromConfig: Data("{oops".utf8)), as: UTF8.self), "{}")
    }

    private func fakeCopilot(_ body: String) throws -> (ranker: LunaSessionRanker, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("copilot")
        try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let userHome = root.appendingPathComponent("user-copilot")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        try Data(#"{"lastLoggedInUser":{"login":"octocat"},"staff":true}"#.utf8)
            .write(to: userHome.appendingPathComponent("config.json"))
        let path = script.path
        let ranker = LunaSessionRanker(
            copilotExecutable: { path },
            workRoot: root.appendingPathComponent("runs"),
            environment: [
                "PATH": "/usr/bin:/bin", "COPILOT_HOME": userHome.path,
                "COPILOT_PROJECTS_SESSION": "must-not-leak",
            ]
        )
        return (ranker, root)
    }

    func testRankRunsInAnIsolatedHomeAndRemovesIt() async throws {
        let (ranker, root) = try fakeCopilot("""
        test -z "$COPILOT_PROJECTS_SESSION" || { echo leaked >&2; exit 3; }
        [ "$(pwd -P)" = "$(cd "$COPILOT_HOME" && pwd -P)" ] || { echo wrong-directory >&2; exit 4; }
        grep -q octocat "$COPILOT_HOME/config.json" || { echo no-login >&2; exit 5; }
        if grep -q staff "$COPILOT_HOME/config.json"; then echo copied-settings >&2; exit 6; fi
        mkdir -p "$COPILOT_HOME/session-state/run"
        echo '{"type":"user.message","data":{"content":"ignored"}}'
        echo '{"type":"assistant.message","data":{"content":"{\\"matches\\":[{\\"id\\":\\"S1\\",\\"reason\\":\\"names the webhook\\"}]}"}}'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = entry("Webhook retries", endedAt: Date())

        let matches = try await ranker.rank(query: "webhook", entries: [target])

        XCTAssertEqual(matches, [LunaMatch(sessionId: target.id, reason: "names the webhook")])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path), [])
    }

    func testRankReportsSignInAndOtherFailures() async throws {
        let (signedOut, root) = try fakeCopilot("echo 'Run copilot and use /login to sign in' >&2; exit 1\n")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await signedOut.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a sign-in failure")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .notSignedIn)
        }

        let (broken, brokenRoot) = try fakeCopilot("echo 'Model gpt-6-luna is not available' >&2; exit 2\n")
        defer { try? FileManager.default.removeItem(at: brokenRoot) }
        do {
            _ = try await broken.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a failure")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .failed("Model gpt-6-luna is not available"))
        }

        let (prose, proseRoot) = try fakeCopilot("echo 'I am not sure.'\n")
        defer { try? FileManager.default.removeItem(at: proseRoot) }
        do {
            _ = try await prose.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected an unreadable answer")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .unreadableResponse)
        }
    }

    func testRankTimesOutAndCancelsByTerminatingTheProcess() async throws {
        // `exec` keeps the shell's pid, so terminating it stops the sleep too.
        var (slow, root) = try fakeCopilot("exec /bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: root) }
        slow.timeout = 0.3
        let started = Date()
        do {
            _ = try await slow.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        slow.timeout = 30
        let task = Task { try await slow.rank(query: "anything", entries: [entry("A")]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path), [])
    }

    func testRankKillsARunAndItsSubprocessesWhenTheyIgnoreTermination() async throws {
        // The ignored SIGTERM is inherited, and both sleeps hold the output pipes open.
        var (stubborn, root) = try fakeCopilot("trap '' TERM\n/bin/sleep 30 &\n/bin/sleep 30\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs").path
        stubborn.timeout = 0.3
        stubborn.terminationGrace = 0.3
        let started = Date()
        do {
            _ = try await stubborn.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])

        stubborn.timeout = 30
        let task = Task { try await stubborn.rank(query: "anything", entries: [entry("A")]) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])
    }

    func testMissingCopilotIsReported() async {
        let ranker = LunaSessionRanker(copilotExecutable: { nil })
        do {
            _ = try await ranker.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected copilotUnavailable")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .copilotUnavailable)
        }
    }
}

// MARK: - Finder model

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class FakeRanker: SessionRanking, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var result: Result<[LunaMatch], Error>

    init(_ result: Result<[LunaMatch], Error>) { self.result = result }

    var queries: [String] { lock.withLock { calls } }

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        lock.withLock { calls.append(query) }
        return try result.get()
    }
}

@MainActor
final class SessionFinderModelTests: XCTestCase {
    private let alpha = SessionFinderSource(
        sessionId: "alpha", projectId: "p1", projectName: "Payments", title: "Webhook retries", cwd: "/r/pay"
    )
    private let beta = SessionFinderSource(
        sessionId: "beta", projectId: "p1", projectName: "Payments", title: "Ledger cleanup", cwd: "/r/pay"
    )
    private let gamma = SessionFinderSource(
        sessionId: "gamma", projectId: "p2", projectName: "Docs", title: "Release notes", cwd: "/r/docs"
    )

    private func makeFinder(
        _ ranker: FakeRanker, opened: @escaping (String) -> Void = { _ in }
    ) async throws -> SessionFinderModel {
        let finder = SessionFinderModel(
            sources: [alpha, beta, gamma], ranker: ranker, lunaDelay: 0,
            loadTranscript: { _ in nil }, onOpen: opened
        )
        try await waitUntil { !finder.isIndexing }
        return finder
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition())
    }

    func testEmptyQueryListsEverySessionAndShortQueriesSkipLuna() async throws {
        let ranker = FakeRanker(.success([]))
        let finder = try await makeFinder(ranker)
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(Set(finder.rows.map(\.section)), [.recent])
        XCTAssertEqual(finder.highlightedId, "alpha")

        finder.query = "le"
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(finder.rows.map(\.id), ["beta", "gamma"])
        XCTAssertEqual(finder.luna, .idle)
        XCTAssertEqual(ranker.queries, [])
    }

    func testLunaPicksAnnotateMatchesAndAppendBelowWithoutMovingTheHighlight() async throws {
        let ranker = FakeRanker(.success([
            LunaMatch(sessionId: "gamma", reason: "shipped the changelog"),
            LunaMatch(sessionId: "beta", reason: "reconciled ledger entries"),
        ]))
        var opened: [String] = []
        let finder = try await makeFinder(ranker) { opened.append($0) }

        finder.query = "ledger"
        XCTAssertEqual(finder.rows.map(\.id), ["beta"])
        XCTAssertEqual(finder.luna, .pending)
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }

        XCTAssertEqual(ranker.queries, ["ledger"])
        XCTAssertEqual(finder.rows.map(\.id), ["beta", "gamma"])
        XCTAssertEqual(finder.rows.map(\.section), [.matches, .luna])
        XCTAssertEqual(finder.rows.map(\.lunaReason), ["reconciled ledger entries", "shipped the changelog"])
        XCTAssertEqual(finder.highlightedId, "beta")

        finder.moveHighlight(1)
        finder.moveHighlight(1)
        XCTAssertEqual(finder.highlightedId, "gamma")
        finder.openHighlighted()
        XCTAssertEqual(opened, ["gamma"])

        // A repeated query is answered from this presentation's cache.
        finder.query = "ledger "
        finder.query = "ledger"
        XCTAssertEqual(ranker.queries, ["ledger"])
        XCTAssertEqual(finder.rows.map(\.id), ["beta", "gamma"])
    }

    func testBrowsingDefaultsPastTheCurrentSessionAndKeepsItsOrderOnceIndexed() async throws {
        let now = Date()
        func dated(_ source: SessionFinderSource, _ age: TimeInterval) -> SessionFinderSource {
            var copy = source
            copy.lastActivity = now.addingTimeInterval(-age)
            return copy
        }
        // Transcript turn times disagree with the file times read at open; the
        // order shown at open must survive indexing.
        let turnsByOrder: [String: Date] = ["alpha": now.addingTimeInterval(-9_000)]
        let finder = SessionFinderModel(
            sources: [dated(alpha, 60), dated(beta, 600), gamma],
            currentSessionId: "alpha",
            ranker: FakeRanker(.success([])), lunaDelay: 0,
            loadTranscript: { id in
                turnsByOrder[id].map {
                    TranscriptSnapshot(schemaVersion: 3, updatedAt: $0, copilotSessionId: id, turns: [
                        TranscriptTurn(id: "t", startedAt: $0, endedAt: $0, kind: "user", userContent: "x",
                                       assistantMessages: [], tools: [], isAborted: false),
                    ])
                }
            },
            onOpen: { _ in }
        )
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(finder.highlightedId, "beta")
        try await waitUntil { !finder.isIndexing }
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(finder.highlightedId, "beta")

        finder.query = "webhook"
        XCTAssertEqual(finder.highlightedId, "alpha", "Searches highlight the best match, even the current session")
    }

    func testSessionsThatEndWhileOpenLeaveTheList() async throws {
        let finder = try await makeFinder(FakeRanker(.success([])))
        finder.moveHighlight(1)
        XCTAssertEqual(finder.highlightedId, "beta")
        finder.retainSessions(["alpha", "gamma"])
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "gamma"])
        XCTAssertEqual(finder.highlightedId, "alpha")
        finder.query = "ledger"
        XCTAssertEqual(finder.rows.map(\.id), [])
    }

    func testClosingTheFinderStopsReadingTranscripts() async throws {
        let gate = DispatchSemaphore(value: 0)
        let loads = LoadCounter()
        let sources = (0..<20).map {
            SessionFinderSource(sessionId: "s\($0)", projectId: "p", projectName: "P", title: "S \($0)", cwd: "/r")
        }
        let finder = SessionFinderModel(
            sources: sources, ranker: FakeRanker(.success([])), lunaDelay: 0,
            loadTranscript: { _ in
                if loads.increment() == 1 { gate.wait() }
                return nil
            },
            onOpen: { _ in }
        )
        try await waitUntil { loads.value == 1 }
        finder.cancel()
        gate.signal()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(loads.value, 1)
        XCTAssertTrue(finder.isIndexing)
    }

    func testLunaLeadsWhenNothingMatchesInstantlyAndFailuresAreReported() async throws {
        let ranker = FakeRanker(.success([LunaMatch(sessionId: "alpha", reason: "retry storms")]))
        let finder = try await makeFinder(ranker)

        finder.query = "thundering herd"
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertEqual(finder.rows.map(\.id), ["alpha"])
        XCTAssertEqual(finder.highlightedId, "alpha")

        ranker.result = .failure(LunaSearchError.notSignedIn)
        finder.query = "something else"
        try await waitUntil { if case .failed = finder.luna { return true } else { return false } }
        XCTAssertEqual(finder.luna, .failed(LunaSearchError.notSignedIn.message))
        XCTAssertEqual(finder.rows.map(\.id), [])
    }
}
