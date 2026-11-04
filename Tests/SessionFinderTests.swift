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

    func testMatchingReturnsNothingOnceCancelled() async {
        let entries = (0..<5).map { entry("Webhook \($0)") }
        let cancelled = await Task.detached { () -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return SessionFinderSearch.localMatches(for: "webhook", in: entries).count
        }.value
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(SessionFinderSearch.localMatches(for: "webhook", in: entries).count, 5)
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

    func testDeepSessionPromptAndParserValidateUUIDsAndExclusions() throws {
        let excludedId = "11111111-2222-3333-4444-555555555555"
        let validIdA = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let validIdB = "99999999-8888-4777-8666-555555555555"
        let prompt = LunaDeepSessionPrompt.build(
            query: "find the   beachball\nfix",
            excludedCopilotSessionIds: [excludedId.uppercased(), "not-a-uuid"]
        )
        XCTAssertTrue(prompt.contains("Looking for: find the beachball fix"))
        XCTAssertTrue(prompt.contains(excludedId))
        XCTAssertFalse(prompt.contains("not-a-uuid"))

        let output = """
        ```json
        {"matches":[
          {"id":"\(excludedId.uppercased())","reason":"already shown"},
          {"id":"not-a-valid-uuid","reason":"bad id"},
          {"id":"\(validIdA.uppercased())","reason":"Fixed the   beachball\\nhang"},
          {"id":"\(validIdA)","reason":"duplicate"},
          {"id":"\(validIdB)","reason":"profiled main thread"}
        ]}
        ```
        """
        let parsed = try LunaDeepSessionPrompt.parse(
            output,
            excludedCopilotSessionIds: [excludedId]
        )
        XCTAssertEqual(
            parsed,
            [
                LunaMatch(
                    sessionId: SessionFinderSource.resumableSessionId(for: validIdA),
                    reason: "Fixed the beachball hang"
                ),
                LunaMatch(
                    sessionId: SessionFinderSource.resumableSessionId(for: validIdB),
                    reason: "profiled main thread"
                ),
            ]
        )
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
        XCTAssertTrue(arguments.contains("--available-tools=none"))
        XCTAssertFalse(arguments.contains("--available-tools="), "An empty allowlist leaves every tool available")
        XCTAssertTrue(arguments.contains("--no-custom-instructions"))
        XCTAssertTrue(arguments.contains("--disable-builtin-mcps"))
        XCTAssertTrue(arguments.contains("--no-ask-user"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--allow") })

        let historyArguments = LunaSessionRanker.historySearchArguments(prompt: "search history")
        XCTAssertTrue(historyArguments.contains("--available-tools=session_store_sql,sql"))
        XCTAssertFalse(historyArguments.contains { $0.hasPrefix("--allow") })
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

    func testSearchHistorySnapshotsDatabaseIntoIsolatedHomeAndRemovesIt() async throws {
        let targetId = "59ff5130-adeb-4f0d-b713-d12e7a729c7e"
        let (ranker, root) = try fakeCopilot("""
        test -z "$COPILOT_PROJECTS_SESSION" || { echo leaked >&2; exit 3; }
        case "$*" in
          *--available-tools=session_store_sql,sql*) ;;
          *) echo missing-tools-flag >&2; exit 5 ;;
        esac
        test -s "$COPILOT_HOME/session-store.db" || { echo missing-db >&2; exit 4; }
        copied_id=$(/usr/bin/sqlite3 "$COPILOT_HOME/session-store.db" "SELECT id FROM sessions LIMIT 1")
        [ "$copied_id" = "\(targetId)" ] || { echo "wrong-db-contents:$copied_id" >&2; exit 6; }
        mkdir -p "$COPILOT_HOME/session-state/temp-finder-session"
        echo '{"type":"assistant.message","data":{"content":"{\\"matches\\":[{\\"id\\":\\"\(targetId)\\",\\"reason\\":\\"fixed the beachball issue\\"}]}"}}'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let userHome = root.appendingPathComponent("user-copilot")
        _ = try CopilotHomeFixture(root: userHome).addSession(
            targetId,
            cwd: root.path,
            name: "Fix Beachball Issue",
            transcript: #"{"type":"user.message","data":{"content":"beachball"}}"#
        )

        let matches = try await ranker.searchHistory(
            query: "beachball",
            excludedCopilotSessionIds: []
        )

        XCTAssertEqual(
            matches,
            [
                LunaMatch(
                    sessionId: SessionFinderSource.resumableSessionId(for: targetId),
                    reason: "fixed the beachball issue"
                )
            ]
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("runs").path),
            [],
            "The temporary COPILOT_HOME and the session opened to search history must be removed on completion"
        )
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

    func testSignInIsDetectedFromDiagnosticsNotTheEchoedPrompt() {
        let echoed = #"{"type":"user.message","data":{"content":"how do I /login and authenticate?"}}"#
        let reasoning = #"{"type":"assistant.reasoning","data":{"content":"they asked to authenticate"}}"#
        XCTAssertEqual(
            LunaSessionRanker.failure(from: .init(
                status: 2, output: echoed + "\n" + reasoning, errorOutput: "Model gpt-6-luna is not available\n"
            )),
            .failed("Model gpt-6-luna is not available")
        )
        XCTAssertEqual(
            LunaSessionRanker.failure(from: .init(
                status: 1, output: echoed + "\n" + #"{"type":"session.error","data":{"message":"Not authenticated"}}"#,
                errorOutput: ""
            )),
            .notSignedIn
        )
        XCTAssertEqual(
            LunaSessionRanker.failure(from: .init(status: 1, output: "Run copilot and use /login\n", errorOutput: "")),
            .notSignedIn
        )
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

    private func recordedPIDs(at url: URL) throws -> [pid_t] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func waitForRecordedPIDs(
        at url: URL,
        count: Int,
        copilotExited: Bool = false,
        timeout: TimeInterval = 5
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let pids = try? recordedPIDs(at: url),
               pids.count >= count,
               !copilotExited || ({
                   let pgid = getpgid(pids[0])
                   return pgid > 0 && kill(pgid, 0) != 0
               }()) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for subprocess readiness (count: \(count), copilotExited: \(copilotExited))")
    }

    private func assertProcessesExit(_ pids: [pid_t], timeout: TimeInterval = 3) async throws {
        let identities = pids.compactMap(LunaProcess.ProcessIdentity.init)
        defer { identities.forEach { $0.signal(SIGKILL) } }
        let deadline = Date().addingTimeInterval(timeout)
        while pids.contains(where: { kill($0, 0) == 0 }), Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for pid in pids {
            XCTAssertNotEqual(kill(pid, 0), 0, "pid \(pid) outlived the terminated Luna run")
        }
    }

    func testRankKillsARunAndItsSubprocessesWhenTheyIgnoreTermination() async throws {
        // The ignored SIGTERM is inherited, and the children hold the output pipes open
        // (including one in a separate process group and one that redirected its own output).
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pidsFile = rootURL.appendingPathComponent("pids")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let hasPerl = FileManager.default.isExecutableFile(atPath: "/usr/bin/perl")
        let expectedChildrenPerRun = hasPerl ? 3 : 2
        var (stubborn, root) = try fakeCopilot("""
        trap '' TERM
        /bin/sleep 30 &
        echo $! >> '\(pidsFile.path)'
        /bin/sleep 30 >/dev/null 2>&1 &
        echo $! >> '\(pidsFile.path)'
        if [ -x /usr/bin/perl ]; then
          /usr/bin/perl -e 'setpgrp(0, 0); open my $f, ">>", $ARGV[0] or die; syswrite($f, "$$\\n"); close $f; exec "/bin/sleep", "30"' '\(pidsFile.path)' &
        fi
        /bin/sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs").path
        stubborn.timeout = 4
        stubborn.terminationGrace = 0.3
        stubborn.sleep = { [weak self] timeout in
            try? await self?.waitForRecordedPIDs(
                at: pidsFile, count: expectedChildrenPerRun, timeout: timeout
            )
        }
        let started = Date()
        do {
            _ = try await stubborn.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let timedOutChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(timedOutChildren.count, expectedChildrenPerRun)
        try await assertProcessesExit(timedOutChildren)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])

        try Data().write(to: pidsFile)
        stubborn.timeout = 30
        stubborn.sleep = LunaProcess.defaultSleep
        let task = Task { try await stubborn.rank(query: "anything", entries: [entry("A")]) }
        try await waitForRecordedPIDs(at: pidsFile, count: expectedChildrenPerRun)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        let cancelledChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(cancelledChildren.count, expectedChildrenPerRun)
        try await assertProcessesExit(cancelledChildren)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])
    }

    func testRankStopsALeftoverSubprocessHoldingThePipesAfterCopilotExits() async throws {
        // copilot exits at once; the backgrounded sleep keeps stdout open and ignores SIGTERM.
        let pidsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pidsFile = pidsRoot.appendingPathComponent("pids")
        try FileManager.default.createDirectory(at: pidsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pidsRoot) }
        var (leaky, root) = try fakeCopilot("""
        trap '' TERM
        /bin/sleep 30 &
        echo $! >> '\(pidsFile.path)'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs").path
        leaky.timeout = 4
        leaky.terminationGrace = 0.3
        leaky.sleep = { [weak self] timeout in
            try? await self?.waitForRecordedPIDs(
                at: pidsFile, count: 1, copilotExited: true, timeout: timeout
            )
        }
        let started = Date()
        do {
            _ = try await leaky.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let timedOutChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(timedOutChildren.count, 1)
        try await assertProcessesExit(timedOutChildren)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])

        try Data().write(to: pidsFile)
        leaky.timeout = 30
        leaky.sleep = LunaProcess.defaultSleep
        let task = Task { try await leaky.rank(query: "anything", entries: [entry("A")]) }
        try await waitForRecordedPIDs(at: pidsFile, count: 1, copilotExited: true)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        let cancelledChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(cancelledChildren.count, 1)
        try await assertProcessesExit(cancelledChildren)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])
    }

    func testRankClosesPipesWhenAnOrphanedSeparateGroupGrandchildSurvives() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"))
        let pidsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pidsFile = pidsRoot.appendingPathComponent("pids")
        let epipeFile = pidsRoot.appendingPathComponent("epipe")
        try FileManager.default.createDirectory(at: pidsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pidsRoot) }
        // copilot emits partial output, starts a separate-group child holding stdout open,
        // and exits immediately so the child is reparented outside copilot's process tree.
        // After the grace period closes the read handle, the child's next write sees EPIPE.
        let perlFile = pidsRoot.appendingPathComponent("detached.pl")
        let perlScript = #"""
        use Errno qw(EPIPE);
        $SIG{TERM} = 'IGNORE';
        $SIG{PIPE} = 'IGNORE';
        setpgrp(0, 0);
        select undef, undef, undef, 0.01 while getppid() != 1;
        if (open my $p, '>>', $ARGV[1]) { print $p "$$\n"; close $p; }
        select STDOUT; $| = 1;
        print "{\"type\":\"user.message\",\"data\":{\"content\":\"partial\"}}\n";
        for (1..400) {
            select undef, undef, undef, 0.05;
            if (!defined syswrite(STDOUT, "\n", 1) && $! == EPIPE) {
                if (open my $f, '>>', $ARGV[0]) { print $f "epipe\n"; close $f; }
                exit 0;
            }
        }
        """#
        try perlScript.write(to: perlFile, atomically: true, encoding: .utf8)
        var (detached, root) = try fakeCopilot("""
        /usr/bin/perl '\(perlFile.path)' '\(epipeFile.path)' '\(pidsFile.path)' &
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let runs = root.appendingPathComponent("runs").path
        detached.timeout = 1.0
        detached.terminationGrace = 0.2
        let started = Date()
        do {
            _ = try await detached.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])
        let timedOutChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(timedOutChildren.count, 1)
        try await assertProcessesExit(timedOutChildren, timeout: 5)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: epipeFile.path),
            "Closing the pipe read handle should cause the surviving writer to observe EPIPE"
        )

        try? FileManager.default.removeItem(at: pidsFile)
        try? FileManager.default.removeItem(at: epipeFile)
        detached.timeout = 30
        let task = Task { try await detached.rank(query: "anything", entries: [entry("A")]) }
        let readyDeadline = Date().addingTimeInterval(5)
        while ((try? recordedPIDs(at: pidsFile).count) ?? 0) < 1, Date() < readyDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 5)
        let cancelledChildren = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(cancelledChildren.count, 1)
        try await assertProcessesExit(cancelledChildren, timeout: 5)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: epipeFile.path),
            "Closing the pipe read handle on cancellation should cause the surviving writer to observe EPIPE"
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: runs), [])
    }

    func testRankKillsSurvivingChildAfterPipesDrainOnTermination() async throws {
        let pidsRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pidsFile = pidsRoot.appendingPathComponent("pids")
        try FileManager.default.createDirectory(at: pidsRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: pidsRoot) }
        // Only the background children ignore SIGTERM and close their pipes (one direct
        // descendant and one reparented group member); the root shell exits on SIGTERM
        // so the pipes drain before the grace period elapses.
        var (ranker, root) = try fakeCopilot("""
        (trap '' TERM; exec /bin/sleep 30 >/dev/null 2>&1) &
        echo $! >> '\(pidsFile.path)'
        (trap '' TERM; /bin/sleep 30 >/dev/null 2>&1 & echo $! >> '\(pidsFile.path)')
        exec /bin/sleep 30
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        ranker.timeout = 1.0
        ranker.terminationGrace = 2.5
        let started = Date()
        do {
            _ = try await ranker.rank(query: "anything", entries: [entry("A")])
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? LunaSearchError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.8)
        let children = try recordedPIDs(at: pidsFile)
        XCTAssertEqual(children.count, 2)
        try await assertProcessesExit(children, timeout: 5)
    }

    func testLunaProcessCollectsMultiChunkStdoutAndStderrWithoutStalling() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lineCount = 4_000
        let outLine = String(repeating: "o", count: 50)
        let errLine = String(repeating: "e", count: 50)
        let script = """
        awk 'BEGIN { for (i = 0; i < \(lineCount); i++) print "\(outLine)" }' &
        awk 'BEGIN { for (i = 0; i < \(lineCount); i++) print "\(errLine)" }' >&2 &
        wait
        """
        let result = try await LunaProcess.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            directory: root,
            timeout: 10
        )
        let expectedOut = String(repeating: outLine + "\n", count: lineCount)
        let expectedErr = String(repeating: errLine + "\n", count: lineCount)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.count, expectedOut.count)
        XCTAssertEqual(result.errorOutput.count, expectedErr.count)
        XCTAssertEqual(result.output, expectedOut)
        XCTAssertEqual(result.errorOutput, expectedErr)
    }

    func testProcessIdentityStopsMatchingOnceTheProcessExits() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        let identity = try XCTUnwrap(LunaProcess.ProcessIdentity(sleeper.processIdentifier))
        XCTAssertTrue(identity.isCurrent)
        XCTAssertEqual(LunaProcess.ProcessIdentity(sleeper.processIdentifier), identity)
        sleeper.terminate()
        sleeper.waitUntilExit()
        XCTAssertFalse(identity.isCurrent)
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
    private var seenEntryIds: [[String]] = []
    var result: Result<[LunaMatch], Error>

    init(_ result: Result<[LunaMatch], Error>) { self.result = result }

    var queries: [String] { lock.withLock { calls } }
    var lastEntryIds: [String] { lock.withLock { seenEntryIds.last ?? [] } }

    func rank(query: String, entries: [SessionFinderEntry]) async throws -> [LunaMatch] {
        lock.withLock {
            calls.append(query)
            seenEntryIds.append(entries.map(\.id))
        }
        return try result.get()
    }
}

private final class FakeHistorySearcher: SessionHistorySearching, @unchecked Sendable {
    private let lock = NSLock()
    private var queriesWithExcluded: [(query: String, excluded: Set<String>)] = []
    var onSearch: (@Sendable () async -> Void)?
    var result: Result<[LunaMatch], Error>

    init(_ result: Result<[LunaMatch], Error>) { self.result = result }

    var calls: [(query: String, excluded: Set<String>)] { lock.withLock { queriesWithExcluded } }

    func searchHistory(
        query: String,
        excludedCopilotSessionIds: Set<String>
    ) async throws -> [LunaMatch] {
        lock.withLock {
            queriesWithExcluded.append((query, excludedCopilotSessionIds))
        }
        await onSearch?()
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

    func testEmptyQueryListsEverySessionAndAnyOtherQueryReachesLuna() async throws {
        let ranker = FakeRanker(.success([]))
        let finder = try await makeFinder(ranker)
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(Set(finder.rows.map(\.section)), [.recent])
        XCTAssertEqual(finder.highlightedId, "alpha")

        finder.query = "   "
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", "gamma"])
        XCTAssertEqual(finder.luna, .idle)
        XCTAssertEqual(ranker.queries, [])

        // Short searches such as "CI" or "PR" are worth asking about too.
        finder.query = "le"
        XCTAssertEqual(finder.rows.map(\.id), ["beta", "gamma"])
        XCTAssertEqual(finder.luna, .pending)
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertEqual(ranker.queries, ["le"])
        XCTAssertEqual(finder.rows.map(\.id), ["beta", "gamma"])
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

    func testLunaSuggestionsLeaveOutSessionsThatEndAfterLunaAnswers() async throws {
        let ranker = FakeRanker(.success([
            LunaMatch(sessionId: "gamma", reason: "shipped the changelog"),
            LunaMatch(sessionId: "beta", reason: "reconciled ledger entries"),
        ]))
        let finder = try await makeFinder(ranker)
        finder.query = "ledger"
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertEqual(finder.lunaSuggestionCount, 2)

        finder.retainSessions(["alpha", "beta"])
        XCTAssertEqual(finder.rows.map(\.id), ["beta"])
        XCTAssertEqual(finder.lunaSuggestionCount, 1)

        // The cached answer still names gamma, but it no longer counts.
        finder.query = "ledger "
        finder.query = "ledger"
        XCTAssertEqual(ranker.queries, ["ledger"])
        XCTAssertEqual(finder.lunaSuggestionCount, 1)

        finder.retainSessions(["alpha"])
        XCTAssertEqual(finder.rows.map(\.id), [])
        XCTAssertEqual(finder.lunaSuggestionCount, 0)
    }

    func testHighlightIsAnnouncedWhenItMovesOrLunaExplainsIt() async throws {
        let ranker = FakeRanker(.success([LunaMatch(sessionId: "beta", reason: "reconciled ledger entries")]))
        let finder = try await makeFinder(ranker)
        XCTAssertEqual(finder.highlight, .init(sessionId: "alpha", lunaReason: nil))

        let browsing = finder.highlight
        finder.query = "ledger"
        let instant = finder.highlight
        XCTAssertEqual(instant, .init(sessionId: "beta", lunaReason: nil))
        XCTAssertTrue(instant.isWorthAnnouncing(after: browsing))

        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        let explained = finder.highlight
        XCTAssertEqual(explained, .init(sessionId: "beta", lunaReason: "reconciled ledger entries"))
        XCTAssertTrue(explained.isWorthAnnouncing(after: instant))
        XCTAssertFalse(instant.isWorthAnnouncing(after: explained), "A reason dropping away mid-typing stays quiet")
        XCTAssertFalse(explained.isWorthAnnouncing(after: explained))
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

    func testResumableSessionsAppearInRecentEndedAndSearchAndLuna() async throws {
        let now = Date()
        let copilotId = "0f1e2d3c-4b5a-4000-8000-0000000000aa"
        let endedSource = SessionFinderSource(
            sessionId: SessionFinderSource.resumableSessionId(for: copilotId),
            projectId: "p2",
            projectName: "Docs",
            title: "Audit flaky webhook retry",
            cwd: "/r/docs",
            lastActivity: now.addingTimeInterval(-120),
            resumableCopilotSessionId: copilotId
        )
        let endedEntry = SessionFinderEntry(
            source: endedSource,
            requests: ["investigate the midnight timeout in webhook retries"],
            replies: ["found the race condition in retry backoff"],
            lastActivity: endedSource.lastActivity
        )
        let ranker = FakeRanker(.success([
            LunaMatch(sessionId: endedEntry.id, reason: "debugged midnight retry backoff"),
        ]))
        var opened: [String] = []
        let finder = SessionFinderModel(
            sources: [alpha, beta],
            currentSessionId: "alpha",
            ranker: ranker,
            lunaDelay: 0,
            loadTranscript: { _ in nil },
            loadResumableEntries: { [endedEntry] },
            onOpen: { opened.append($0) }
        )
        try await waitUntil { finder.hasResumableSessions }

        // Browsing lists live sessions under Recent Sessions and ended under Recent Ended Sessions,
        // while keeping the default highlight on the next live tab.
        XCTAssertEqual(finder.rows.map(\.id), ["alpha", "beta", endedEntry.id])
        XCTAssertEqual(finder.rows.map(\.section), [.recent, .recent, .recentEnded])
        XCTAssertEqual(finder.highlightedId, "beta")
        XCTAssertFalse(finder.highlightedIsResumable)

        finder.moveHighlight(1)
        XCTAssertEqual(finder.highlightedId, endedEntry.id)
        XCTAssertTrue(finder.highlightedIsResumable)
        finder.openHighlighted()
        XCTAssertEqual(opened, [endedEntry.id])

        // Searching matches ended conversation text and includes ended sessions in Luna.
        finder.query = "backoff"
        XCTAssertEqual(finder.rows.map(\.id), [endedEntry.id])
        XCTAssertEqual(finder.rows.map(\.section), [.matches])
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertTrue(ranker.lastEntryIds.contains(endedEntry.id))
        XCTAssertEqual(finder.rows.first?.lunaReason, "debugged midnight retry backoff")

        // Once the Copilot session becomes active in a tab, it leaves the resumable list.
        finder.retainSessions(["alpha", "beta"], activeCopilotSessionIds: [copilotId.uppercased()])
        XCTAssertTrue(finder.rows.isEmpty)
        XCTAssertFalse(finder.hasResumableSessions)
    }

    func testLunaSuggestionsAndSelectionPersistWhenEndedSessionsFinishAfterFirstLunaPass() async throws {
        let resumableGate = DispatchSemaphore(value: 0)
        let copilotId = "0f1e2d3c-4b5a-4000-8000-0000000000bb"
        let endedSource = SessionFinderSource(
            sessionId: SessionFinderSource.resumableSessionId(for: copilotId),
            projectId: "p2",
            projectName: "Docs",
            title: "Audit flaky webhook retry",
            cwd: "/r/docs",
            resumableCopilotSessionId: copilotId
        )
        let endedEntry = SessionFinderEntry(
            source: endedSource,
            requests: ["investigate the midnight timeout in webhook retries"],
            replies: ["found the race condition in retry backoff"]
        )
        let ranker = FakeRanker(.success([
            LunaMatch(sessionId: "beta", reason: "live retry analysis"),
        ]))
        let finder = SessionFinderModel(
            sources: [alpha, beta],
            currentSessionId: "alpha",
            ranker: ranker,
            lunaDelay: 0.2,
            loadTranscript: { _ in nil },
            loadResumableEntries: {
                resumableGate.wait()
                return [endedEntry]
            },
            onOpen: { _ in }
        )
        try await waitUntil { !finder.isIndexing }
        XCTAssertTrue(finder.isLoadingResumable)

        finder.query = "thundering herd"
        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertEqual(finder.rows.map(\.id), ["beta"])
        XCTAssertEqual(finder.highlightedId, "beta")

        // When ended-session loading finishes, the second Luna pass starts (.pending),
        // and the live-only Luna suggestion and selection remain visible in the meantime.
        ranker.result = .success([
            LunaMatch(sessionId: endedEntry.id, reason: "ended retry backoff"),
        ])
        resumableGate.signal()
        try await waitUntil { !finder.isLoadingResumable }
        XCTAssertEqual(finder.luna, .pending)
        XCTAssertEqual(finder.rows.map(\.id), ["beta"])
        XCTAssertEqual(finder.highlightedId, "beta")

        try await waitUntil { if case .finished = finder.luna { return true } else { return false } }
        XCTAssertEqual(finder.rows.map(\.id), [endedEntry.id, "beta"])
        XCTAssertEqual(finder.highlightedId, "beta")
    }

    func testTargetProjectMatchesByCwdFolderWorktreeAndRepositoryBeforeSelectedFallback() {
        let projects = [
            SessionFinderProjectTarget(
                id: "p-general", name: "General", cwd: "/Users/me/Repos",
                sessionCwds: ["/Users/me/Repos"]
            ),
            SessionFinderProjectTarget(
                id: "p-cp", name: "copilot-projects", cwd: "/Users/me/Repos",
                sessionCwds: ["/Users/me/Repos/copilot-projects"]
            ),
            SessionFinderProjectTarget(
                id: "p-ios", name: "copilot-projects-ios", cwd: "/Users/me/Repos/copilot-projects-ios",
                sessionCwds: []
            ),
            SessionFinderProjectTarget(
                id: "p-work", name: "Work", cwd: "/Users/me/Repos/widget",
                sessionCwds: []
            ),
        ]

        // Exact session cwd match (non-default startup dir).
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos/copilot-projects",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-cp"
        )
        // Exact project cwd match.
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos/copilot-projects-ios",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-ios"
        )
        // Project cwd folder matches worktree prefix and repository name even when project.name differs
        // and no live tabs remain at that directory.
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos/widget-fix",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-work"
        )
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos",
                repository: "owner/widget",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-work"
        )
        // Sibling worktree prefix prefers longest match (`copilot-projects-ios` over `copilot-projects`),
        // even when `copilot-projects` is selected.
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos/copilot-projects-ios-fix",
                repository: "sirfergy/copilot-projects-ios",
                projects: projects,
                selectedProjectId: "p-cp",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-ios"
        )
        // Worktree folder prefix match (`copilot-projects-fix` -> `copilot-projects`).
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos/copilot-projects-fix",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-cp"
        )
        // Generic startup dir uses repository name when it matches a project, else selectedProjectId.
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos",
                repository: "sirfergy/copilot-projects",
                projects: projects,
                selectedProjectId: "p-general",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-cp"
        )
        XCTAssertEqual(
            SessionFinderSearch.targetProject(
                forCwd: "/Users/me/Repos",
                projects: projects,
                selectedProjectId: "p-ios",
                defaultStartupDir: "/Users/me/Repos"
            )?.id,
            "p-ios"
        )
    }

    func testResumableLoaderIndexesUsableEndedSessionsFromDatabaseAndEvents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repoDir = root.appendingPathComponent("copilot-projects")
        let otherDir = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)

        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let resumableId = try home.addSession(
            cwd: repoDir.path,
            name: "Fix beachball in sidebar",
            updated: Date(timeIntervalSince1970: 1_800_000_100),
            transcript: """
            {"type":"user.message","data":{"content":"investigate the main-thread beachball"}}
            {"type":"assistant.message","data":{"content":"cached the file signature on background queue"}}
            """
        )
        let unindexedId = UUID().uuidString.lowercased()
        let unindexedDir = home.root.appendingPathComponent("session-state/\(unindexedId)")
        try FileManager.default.createDirectory(at: unindexedDir, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let unindexedDate = Date(timeIntervalSince1970: 1_800_000_500)
        try Data("""
            id: \(unindexedId)
            cwd: \(repoDir.path)
            client_name: github/cli
            name: Newer unindexed session
            created_at: \(formatter.string(from: unindexedDate.addingTimeInterval(-60)))
            updated_at: \(formatter.string(from: unindexedDate))
            """.utf8).write(to: unindexedDir.appendingPathComponent("workspace.yaml"))
        try Data(#"{"type":"user.message","data":{"content":"unindexed conversation"}}"#.utf8)
            .write(to: unindexedDir.appendingPathComponent("events.jsonl"))

        let missingWorkspaceCwdId = try home.addSession(
            cwd: repoDir.path,
            name: "Missing workspace cwd",
            updated: Date(timeIntervalSince1970: 1_800_000_600),
            transcript: #"{"type":"user.message","data":{"content":"has db cwd only"}}"#
        )
        try Data("id: \(missingWorkspaceCwdId)\nclient_name: github/cli\nname: Missing workspace cwd\n".utf8)
            .write(to: home.root.appendingPathComponent("session-state/\(missingWorkspaceCwdId)/workspace.yaml"))

        let liveId = try home.addSession(
            cwd: repoDir.path,
            name: "Already live",
            updated: Date(timeIntervalSince1970: 1_800_000_200),
            transcript: #"{"type":"user.message","data":{"content":"live work"}}"#
        )
        let lockedId = try home.addSession(
            cwd: otherDir.path,
            name: "Locked elsewhere",
            updated: Date(timeIntervalSince1970: 1_800_000_300),
            transcript: #"{"type":"user.message","data":{"content":"locked work"}}"#
        )
        try home.lock(lockedId)
        _ = try home.addSession(
            cwd: root.appendingPathComponent("missing-dir").path,
            name: "Deleted worktree",
            transcript: #"{"type":"user.message","data":{"content":"missing folder"}}"#
        )
        _ = try home.addSession(
            cwd: otherDir.path,
            client: "vscode",
            name: "Editor session",
            transcript: #"{"type":"user.message","data":{"content":"editor"}}"#
        )
        _ = try home.addSession(
            cwd: repoDir.path,
            name: "Metadata only with empty events",
            transcript: ""
        )

        let projects = [
            SessionFinderProjectTarget(id: "p1", name: "General", cwd: otherDir.path, sessionCwds: []),
            SessionFinderProjectTarget(id: "p2", name: "copilot-projects", cwd: otherDir.path, sessionCwds: [repoDir.path]),
        ]
        // Even with limit = 1, the newer directory-only session outranks the older database entry.
        let topOne = SessionFinderResumableLoader.load(
            store: home.store,
            projects: projects,
            selectedProjectId: "p1",
            liveCopilotSessionIds: [liveId],
            defaultStartupDir: root.path,
            limit: 1
        )
        XCTAssertEqual(topOne.map(\.source.resumableCopilotSessionId), [unindexedId])

        let loaded = SessionFinderResumableLoader.load(
            store: home.store,
            projects: projects,
            selectedProjectId: "p1",
            liveCopilotSessionIds: [liveId],
            defaultStartupDir: root.path
        )

        XCTAssertEqual(loaded.map(\.source.resumableCopilotSessionId), [unindexedId, resumableId])
        let entry = try XCTUnwrap(loaded.last)
        XCTAssertEqual(entry.source.resumableCopilotSessionId, resumableId)
        XCTAssertEqual(entry.source.projectId, "p2")
        XCTAssertEqual(entry.source.projectName, "copilot-projects")
        XCTAssertEqual(entry.source.title, "Fix beachball in sidebar")
        XCTAssertEqual(entry.requests, ["investigate the main-thread beachball"])
        XCTAssertEqual(entry.replies, ["cached the file signature on background queue"])

        // Specific ID loading validates and preserves caller ranking order while excluding live/locked/invalid IDs.
        let byIds = SessionFinderResumableLoader.loadEntries(
            forCopilotSessionIds: [resumableId, liveId, lockedId, missingWorkspaceCwdId, unindexedId],
            store: home.store,
            projects: projects,
            selectedProjectId: "p1",
            liveCopilotSessionIds: [liveId],
            defaultStartupDir: root.path
        )
        XCTAssertEqual(byIds.map(\.source.resumableCopilotSessionId), [resumableId, unindexedId])
    }

    func testDeepHistorySearchRunsOnlyAfterLunaFinishesAndPreservesHighlight() async throws {
        let recentCopilotId = "0f1e2d3c-4b5a-4000-8000-0000000000aa"
        let olderCopilotId = "0f1e2d3c-4b5a-4000-8000-0000000000bb"
        let recentEntry = SessionFinderEntry(
            source: SessionFinderSource(
                sessionId: SessionFinderSource.resumableSessionId(for: recentCopilotId),
                projectId: "p1",
                projectName: "Core",
                title: "Recent ended session",
                cwd: "/r/core",
                resumableCopilotSessionId: recentCopilotId
            ),
            requests: ["recent work"],
            replies: ["done"]
        )
        let olderEntry = SessionFinderEntry(
            source: SessionFinderSource(
                sessionId: SessionFinderSource.resumableSessionId(for: olderCopilotId),
                projectId: "p2",
                projectName: "Docs",
                title: "Older archived session",
                cwd: "/r/docs",
                resumableCopilotSessionId: olderCopilotId
            ),
            requests: ["deep archive topic"],
            replies: ["resolved months ago"]
        )

        let ranker = FakeRanker(.success([
            LunaMatch(sessionId: "beta", reason: "fast pass match"),
        ]))
        let deepGate = DispatchSemaphore(value: 0)
        let historySearcher = FakeHistorySearcher(.success([
            LunaMatch(sessionId: olderEntry.id, reason: "found in full session history"),
        ]))
        historySearcher.onSearch = {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    deepGate.wait()
                    continuation.resume()
                }
            }
        }

        var opened: [String] = []
        let finder = SessionFinderModel(
            sources: [alpha, beta],
            currentSessionId: "alpha",
            activeCopilotSessionIds: ["live-copilot-id"],
            ranker: ranker,
            historySearcher: historySearcher,
            lunaDelay: 0.15,
            loadTranscript: { _ in nil },
            loadResumableEntries: { [recentEntry] },
            loadResumableEntriesByIds: { ids in
                ids.contains(olderCopilotId) ? [olderEntry] : []
            },
            onOpen: { opened.append($0) }
        )
        try await waitUntil { !finder.isIndexing && !finder.isLoadingResumable }

        finder.query = "archive topic"
        // While Luna is pending, deep search has not started.
        XCTAssertEqual(finder.luna, .pending)
        XCTAssertEqual(finder.deepSearch, .idle)
        XCTAssertTrue(historySearcher.calls.isEmpty)

        // Once Luna finishes, deep search starts with active + already-displayed resumable IDs excluded,
        // while keeping unlisted indexed sessions eligible so deep SQL search can match their middle turns.
        try await waitUntil { finder.deepSearch == .searching && !historySearcher.calls.isEmpty }
        XCTAssertEqual(finder.luna, .finished([LunaMatch(sessionId: "beta", reason: "fast pass match")]))
        XCTAssertEqual(finder.rows.map(\.id), ["beta"])
        XCTAssertEqual(finder.highlightedId, "beta")
        XCTAssertEqual(historySearcher.calls.count, 1)
        XCTAssertEqual(historySearcher.calls.first?.query, "archive topic")
        XCTAssertEqual(historySearcher.calls.first?.excluded, ["live-copilot-id"])

        // Completing deep search appends the older session without moving the highlight off "beta".
        deepGate.signal()
        try await waitUntil {
            if case .finished = finder.deepSearch { return true }
            return false
        }
        XCTAssertEqual(finder.rows.map(\.id), ["beta", olderEntry.id])
        XCTAssertEqual(finder.rows.map(\.section), [.luna, .history])
        XCTAssertEqual(finder.highlightedId, "beta", "Late deep-history arrivals must not jump the highlight")
        XCTAssertEqual(finder.source(for: olderEntry.id)?.resumableCopilotSessionId, olderCopilotId)

        // Moving down highlights the deep-history resumable session and Return opens it.
        finder.moveHighlight(1)
        XCTAssertEqual(finder.highlightedId, olderEntry.id)
        XCTAssertTrue(finder.highlightedIsResumable)
        finder.openHighlighted()
        XCTAssertEqual(opened, [olderEntry.id])
    }

    func testDeepHistorySearchDebouncesRapidQueryChangesWhenAvailableEntriesAreEmpty() async throws {
        let olderCopilotId = "0f1e2d3c-4b5a-4000-8000-0000000000cc"
        let olderEntry = SessionFinderEntry(
            source: SessionFinderSource(
                sessionId: SessionFinderSource.resumableSessionId(for: olderCopilotId),
                projectId: "p1",
                projectName: "Core",
                title: "Archived session with empty workspace",
                cwd: "/r/core",
                resumableCopilotSessionId: olderCopilotId
            ),
            requests: ["historical migration details"],
            replies: ["completed"]
        )

        let ranker = FakeRanker(.success([]))
        let historySearcher = FakeHistorySearcher(.success([
            LunaMatch(sessionId: olderEntry.id, reason: "matched historical migration"),
        ]))

        let finder = SessionFinderModel(
            sources: [],
            ranker: ranker,
            historySearcher: historySearcher,
            lunaDelay: 0.15,
            loadTranscript: { _ in nil },
            loadResumableEntries: { [] },
            loadResumableEntriesByIds: { ids in
                ids.contains(olderCopilotId) ? [olderEntry] : []
            },
            onOpen: { _ in }
        )
        try await waitUntil { !finder.isIndexing && !finder.isLoadingResumable }

        finder.query = "m"
        XCTAssertEqual(finder.deepSearch, .pending)
        XCTAssertTrue(historySearcher.calls.isEmpty)

        try await Task.sleep(nanoseconds: 30_000_000)
        finder.query = "mi"
        XCTAssertEqual(finder.deepSearch, .pending)
        XCTAssertTrue(historySearcher.calls.isEmpty)

        try await Task.sleep(nanoseconds: 30_000_000)
        finder.query = "migration"
        XCTAssertEqual(finder.deepSearch, .pending)
        XCTAssertTrue(historySearcher.calls.isEmpty)

        try await waitUntil {
            if case .finished = finder.deepSearch { return true }
            return false
        }
        XCTAssertTrue(ranker.queries.isEmpty)
        XCTAssertEqual(historySearcher.calls.map(\.query), ["migration"])
        XCTAssertEqual(finder.rows.map(\.id), [olderEntry.id])
        XCTAssertEqual(finder.highlightedId, olderEntry.id)
    }
}
