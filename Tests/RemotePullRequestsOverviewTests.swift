import Foundation
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsPullRequests
@testable import CopilotProjectsHost

private actor OverviewAccounts {
    var calls = 0
    var suspended = true
    var failure = false
    private var waiting: CheckedContinuation<Void, Never>?

    func load() async throws -> [GitHubAccount] {
        calls += 1
        if suspended { await withCheckedContinuation { waiting = $0 } }
        if failure { throw PullRequestFetchError.notSignedIn }
        return []
    }

    func release(failure: Bool = false) {
        self.failure = failure
        suspended = false
        waiting?.resume()
        waiting = nil
    }
}

@MainActor
final class RemotePullRequestsOverviewTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private var now = testNow
    private var current: WorkspaceSnapshot?

    override func setUp() async throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".scratch/overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "remote-pr-overview-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        now = testNow
        current = WorkspaceSnapshot(hostProcessIdentifier: 1, selectedProjectId: "p",
                                    projects: [.init(id: "p", name: "Project", sessions: [])])
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    private func make(
        loadAccounts: @escaping @Sendable () async throws -> [GitHubAccount] = { [] }
    ) -> (PullRequestsOverviewProvider, PullRequestsModel) {
        let model = PullRequestsModel(
            workspace: FakeWorkspace(snapshot: current), defaults: defaults, stateDirectory: root,
            service: PullRequestService(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint)),
            loadAccounts: loadAccounts,
            resumableFinder: ResumableSessionFinder(
                store: CopilotSessionStore(environment: ["COPILOT_HOME": root.appendingPathComponent("home").path]),
                cacheURL: nil
            ),
            hostedReadOnly: true, readOnlyGoalsURL: root.appendingPathComponent("goals.json"),
            transcriptPath: { _ in nil }, clock: { self.now },
            isVisible: { false }, presentError: { _, _ in XCTFail("Hosted engine must never alert") }
        )
        let provider = PullRequestsOverviewProvider(model: model, workspace: { self.current }, clock: { self.now })
        return (provider, model)
    }

    private func settle(_ model: PullRequestsModel) async throws {
        for _ in 0..<300 {
            await Task.yield()
            if !model.isRefreshing && !model.isMatchingSessions { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Hosted refresh did not settle")
    }

    func testFirstLoadDoesNotBlockAndCoalescesManualRefreshIncludingFailures() async throws {
        let accounts = OverviewAccounts()
        let (provider, model) = make(loadAccounts: { try await accounts.load() })
        let started = Date()
        let first = provider.snapshot()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertEqual(first.phase, "loading")
        XCTAssertTrue(first.isRefreshing)
        for _ in 0..<20 { _ = provider.snapshot(refresh: true) }
        for _ in 0..<50 where await accounts.calls == 0 { await Task.yield() }
        let count = await accounts.calls
        XCTAssertEqual(count, 1)
        await accounts.release(failure: true)
        try await settle(model)
        XCTAssertEqual(provider.snapshot().phase, "failed")
        now = now.addingTimeInterval(59)
        XCTAssertFalse(provider.snapshot(refresh: true).isRefreshing)
        now = now.addingTimeInterval(1)
        XCTAssertTrue(provider.snapshot(refresh: true).isRefreshing)
        try await settle(model)
        now = now.addingTimeInterval(299)
        XCTAssertFalse(provider.snapshot().isRefreshing)
        now = now.addingTimeInterval(1)
        XCTAssertTrue(provider.snapshot().isRefreshing)
        try await settle(model)
        let finalCount = await accounts.calls
        XCTAssertEqual(finalCount, 3, "failed attempts count toward both cadence limits")
    }

    func testWorkspaceAppearanceAndLiveAssociationsRegroupWithoutGitHubRefresh() async throws {
        let accounts = OverviewAccounts()
        await accounts.release()
        current = nil
        let (provider, model) = make(loadAccounts: { try await accounts.load() })
        _ = provider.snapshot()
        try await settle(model)
        model.show([makePR()], links: [:], updated: now)
        current = WorkspaceSnapshot(
            hostProcessIdentifier: 1, selectedProjectId: "p",
            projects: [.init(id: "p", name: "Project", sessions: [
                .init(id: "new", title: "New session", status: .waiting, pullRequestKeys: ["github/github#1"]),
            ])]
        )
        let snapshot = provider.snapshot()
        XCTAssertEqual(snapshot.goals.first?.session?.id, "new")
        XCTAssertEqual(snapshot.goals.first?.items.first?.session?.status, "waiting")
        try await settle(model)
        XCTAssertTrue(provider.snapshot().sessionsKnown)
        let count = await accounts.calls
        XCTAssertEqual(count, 1, "workspace-triggered rematching must not queue a GitHub fetch")
        current?.projects[0].sessions.removeAll()
        XCTAssertNil(provider.snapshot().goals.first?.session, "ended tabs stop claiming PRs immediately")
        try await settle(model)
    }

    func testStartWaitsForMatchingWhenWorkspaceChangesBetweenReadAndAction() async throws {
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([makePR()], links: [:], updated: now)
        current?.projects[0].sessions.append(.init(id: "appeared", title: "New tab", status: .idle))
        let request = RemotePullRequestSessionRequest(requestId: UUID(), kind: "start", projectId: "p",
                                                     pullRequestKeys: ["github/github#1"])
        guard case .stale = provider.validate(request, workspace: current!) else {
            return XCTFail("A changed workspace must be matched before claiming no live links")
        }
        try await settle(model)
        XCTAssertNil(provider.validate(request, workspace: current!))
        current?.projects[0].sessions[0].pullRequestKeys = ["github/github#1"]
        XCTAssertEqual(provider.validate(request, workspace: current!), .conflict)
    }

    func testOwnersReloadIsReadOnlyAndInvalidatesInFlightOldScope() async throws {
        let accounts = OverviewAccounts()
        let (provider, model) = make(loadAccounts: { try await accounts.load() })
        defaults.set("github", forKey: PullRequestsModel.ownersKey)
        XCTAssertEqual(provider.snapshot().owners, ["github"])
        for _ in 0..<50 where await accounts.calls == 0 { await Task.yield() }
        model.show([makePR()], links: [:])
        defaults.set("other", forKey: PullRequestsModel.ownersKey)
        let changed = provider.snapshot()
        XCTAssertEqual(changed.openCount, 0)
        XCTAssertEqual(changed.owners, ["other"])
        await accounts.release()
        try await settle(model)
        XCTAssertNil(model.lastUpdated, "an old in-flight scope cannot publish into the new scope")
        _ = provider.snapshot()
        try await settle(model)
        defaults.removeObject(forKey: PullRequestsModel.ownersKey)
        _ = provider.snapshot()
        XCTAssertNil(defaults.object(forKey: PullRequestsModel.ownersKey), "reading absent owners never writes an empty key")
        try await settle(model)
    }

    func testGoalOverridesKeepLastGoodOnMalformedOrReadErrorAndNeverWrite() async throws {
        let (provider, model) = make()
        let pr = makePR()
        var overrides = PullRequestGoalOverrides()
        overrides.names["manual:a"] = "My goal"
        overrides.assign(pr.key, to: "manual:a")
        let file = root.appendingPathComponent("goals.json")
        let original = try JSONEncoder().encode(overrides)
        try original.write(to: file, options: .atomic)
        model.show([pr], links: [:], updated: now)
        XCTAssertEqual(provider.snapshot().goals.first?.name, "My goal")
        try await settle(model)
        model.moveToNewGoal(pr.key, named: "Do not write")
        model.openHost()
        XCTAssertEqual(try Data(contentsOf: file), original)
        try Data("{".utf8).write(to: file, options: .atomic)
        let malformed = provider.snapshot()
        XCTAssertEqual(malformed.goals.first?.name, "My goal")
        XCTAssertNotNil(malformed.warning)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertNotNil(provider.snapshot().warning)
        XCTAssertEqual(provider.snapshot().goals.first?.name, "My goal")
        try FileManager.default.removeItem(at: file)
        XCTAssertNotEqual(provider.snapshot().goals.first?.name, "My goal")
        XCTAssertNil(provider.snapshot().warning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testPreviousSessionKeysAreTheRawVerifiedSubsetNotTheManualGoal() async throws {
        let (provider, model) = make()
        let first = makePR(1), second = makePR(2)
        let cid = UUID().uuidString.lowercased()
        let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: "/not-on-wire", lastActive: now)
        var overrides = PullRequestGoalOverrides()
        overrides.names["manual:a"] = "Together"
        for pr in [first, second] { overrides.assign(pr.key, to: "manual:a") }
        try JSONEncoder().encode(overrides).write(to: root.appendingPathComponent("goals.json"))
        model.show([first, second], links: [:], resumable: [first.key: candidate], updated: now)
        let snapshot = provider.snapshot()
        XCTAssertEqual(snapshot.goals.first?.resumable?.pullRequestKeys, [first.key.description])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("/not-on-wire"))
        let wrong = RemotePullRequestSessionRequest(requestId: UUID(), kind: "resume", projectId: "p",
                                                   pullRequestKeys: [second.key.description], copilotSessionId: cid)
        guard case .stale = provider.validate(wrong, workspace: current!) else { return XCTFail("unverified subset") }
        try await settle(model)
    }

    func testOverviewPartialStatusMatchesMacForUncountedThreadsAndUnknownRequiredChecks() {
        let (provider, model) = make()
        var incomplete = makePR(2)
        incomplete.isIncomplete = true
        var uncounted = makePR(3)
        uncounted.uncountedThreadsCursor = "older-threads"
        let prs = [
            makePR(1), incomplete, uncounted,
            makePR(4, checks: .failure),
            makePR(5, checks: .failure, requiredFailing: []),
            makePR(6, checks: .failure, requiredFailing: ["CI"]),
        ]
        model.apply(.snapshot(current!))
        model.show(prs, links: [:], updated: now)
        let items = Dictionary(uniqueKeysWithValues: provider.snapshot().goals.flatMap(\.items).map { ($0.id, $0) })
        XCTAssertEqual(prs.map { items[$0.key.description]?.isPartial }, [false, true, true, true, false, false])
        for pr in prs {
            XCTAssertEqual(items[pr.key.description]?.isPartial, PullRequestsPresentation.hasPartialStatus(pr))
        }
    }

    func testOverviewSessionStatusesPreserveUnseenCompletionWithoutLosingUnknownState() {
        let (provider, model) = make()
        let states: [(String, SessionStatus, Bool, String)] = [
            ("finished", .idle, true, "finished"),
            ("idle", .idle, false, "idle"),
            ("running", .running, true, "running"),
            ("waiting", .waiting, true, "waiting"),
        ]
        let prs = states.indices.map { makePR($0 + 1) }
        current?.projects[0].sessions = states.enumerated().map { index, state in
            .init(id: state.0, title: state.0, status: state.1, finishedUnseen: state.2,
                  pullRequestKeys: [prs[index].key.description])
        }
        model.apply(.snapshot(current!))
        model.show(prs, links: [:], updated: now)
        let goals = Dictionary(uniqueKeysWithValues: provider.snapshot().goals.map { ($0.session!.id, $0) })
        for state in states {
            XCTAssertEqual(goals[state.0]?.session?.status, state.3)
            XCTAssertEqual(goals[state.0]?.items.first?.session?.status, state.3)
        }
        current = nil
        let disconnected = provider.snapshot()
        XCTAssertEqual(disconnected.goals.count, states.count)
        XCTAssertTrue(disconnected.goals.allSatisfy {
            $0.session?.status == nil && $0.items.first?.session?.status == nil
        })
    }

    func testOverviewURLsUseCanonicalKnownPullRequestIdentity() {
        let (provider, model) = make()
        let pr = makePR(42, repo: "GitHub/Mixed-Case")
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], updated: now)
        let item = provider.snapshot().goals.first?.items.first
        XCTAssertEqual(item?.id, "github/mixed-case#42")
        XCTAssertEqual(item?.url, "https://github.com/github/mixed-case/pull/42")
        XCTAssertEqual(item.flatMap { RemotePullRequestsContract.validatedURL($0.url, key: $0.id)?.absoluteString },
                       item?.url)
    }

    func testInitialEnrichmentKeepsCreationUnavailableButPreservesLiveSessionNavigation() async throws {
        URLProtocol.registerClass(GraphQLStub.self)
        let enrichmentStarted = expectation(description: "Initial enrichment started after matching")
        let release = DispatchSemaphore(value: 0)
        defer {
            release.signal()
            URLProtocol.unregisterClass(GraphQLStub.self)
            GraphQLStub.respond = { _, _ in (500, "") }
        }
        let nodes = (1...2).map { number in
            """
            {"id":"PR_\(number)","number":\(number),"title":"PR \(number)","url":"https://github.com/o/r/pull/\(number)",
            "state":"OPEN","isDraft":false,"createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z",
            "headRefName":"me/branch-\(number)","author":{"login":"me"},"repository":{"nameWithOwner":"o/r"},
            "reviewThreads":{"pageInfo":{"hasPreviousPage":false},"nodes":[]},"commits":{"nodes":[]}}
            """
        }.joined(separator: ",")
        GraphQLStub.respond = { _, body in
            if (body["query"] as? String ?? "").contains("search(") {
                return (200, """
                {"data":{"viewer":{"login":"me"},"search":{"issueCount":2,
                "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\(nodes)]}}}
                """)
            }
            if (body["variables"] as? [String: Any])?["id"] as? String == "PR_1" {
                enrichmentStarted.fulfill()
                _ = release.wait(timeout: .now() + 10)
            }
            return (200, #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}}}"#)
        }
        current?.projects[0].sessions = [
            .init(id: "live", title: "Existing session", status: .running, pullRequestKeys: ["o/r#1"]),
        ]
        let (provider, model) = make(loadAccounts: { [GitHubAccount(login: "me", token: "fixture")] })
        XCTAssertEqual(provider.snapshot().phase, "loading")
        await fulfillment(of: [enrichmentStarted], timeout: 5)
        let pending = provider.snapshot()
        XCTAssertEqual(pending.phase, "loaded")
        XCTAssertNil(model.lastUpdated)
        XCTAssertFalse(model.isMatchingSessions, "This regression occurs after transcript matching finishes")
        XCTAssertTrue(pending.isRefreshing)
        XCTAssertFalse(pending.sessionsKnown, "Creation must wait for initial GitHub status enrichment")
        let live = pending.goals.first { $0.items.contains { $0.id == "o/r#1" } }
        XCTAssertEqual(live?.session?.id, "live", "Go to an existing session remains available")
        XCTAssertEqual(live?.items.first?.session?.id, "live")
        let request = RemotePullRequestSessionRequest(requestId: UUID(), kind: "start", projectId: "p",
                                                     pullRequestKeys: ["o/r#2"])
        if case .stale = provider.validate(request, workspace: current!) {
        } else {
            XCTFail("Initial enrichment must also gate host-side Start validation")
        }
        release.signal()
        try await settle(model)
        XCTAssertNotNil(model.lastUpdated)
        XCTAssertTrue(provider.snapshot().sessionsKnown)
        XCTAssertNil(provider.validate(request, workspace: current!))
    }

    func testGraphQLCacheUsesTheSamePipelineAndKeepsLastGoodOnFailure() async throws {
        URLProtocol.registerClass(GraphQLStub.self)
        defer { URLProtocol.unregisterClass(GraphQLStub.self); GraphQLStub.respond = { _, _ in (500, "") } }
        GraphQLStub.respond = { _, body in
            let query = body["query"] as? String ?? ""
            if query.contains("search(") {
                return (200, """
                {"data":{"viewer":{"login":"me"},"search":{"issueCount":1,
                "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{
                "id":"PR_1","number":1,"title":"Cached PR","url":"https://github.com/o/r/pull/1",
                "state":"OPEN","isDraft":false,"createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z",
                "headRefName":"me/cached-branch","author":{"login":"me"},"repository":{"nameWithOwner":"o/r"},
                "reviewThreads":{"pageInfo":{"hasPreviousPage":false},"nodes":[]},"commits":{"nodes":[]}
                }]}}}
                """)
            }
            return (200, #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}}}"#)
        }
        let (provider, model) = make(loadAccounts: { [GitHubAccount(login: "me", token: "fixture")] })
        XCTAssertEqual(provider.snapshot().phase, "loading")
        try await settle(model)
        XCTAssertEqual(provider.snapshot().goals.first?.items.first?.title, "Cached PR")
        try await settle(model)
        GraphQLStub.respond = { _, _ in (401, "") }
        now = now.addingTimeInterval(60)
        _ = provider.snapshot(refresh: true)
        try await settle(model)
        let cached = provider.snapshot()
        XCTAssertEqual(cached.openCount, 1)
        XCTAssertNotNil(cached.warning)
        XCTAssertFalse(cached.isRefreshing)
    }

    func testOldSessionJSONAndPersistedAssociationPriorityAreDeterministic() throws {
        let old = try JSONDecoder().decode(Session.self, from: Data(#"{"id":"old","title":"Old","cwd":"/work"}"#.utf8))
        XCTAssertNil(old.pullRequestKeys)
        var new = old
        new.pullRequestKeys = ["github/github#1"]
        XCTAssertEqual(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(new)), new)
        let key = makePR().key
        let a = PullRequestSession(id: "a", title: "A", projectId: "p", projectName: "P",
                                   pullRequestKeys: ["GITHUB/GITHUB#1", "not a key"])
        let z = PullRequestSession(id: "z", title: "Z", projectId: "p", projectName: "P",
                                   pullRequestKeys: ["github/github#1"])
        var overrides = PullRequestGoalOverrides()
        for sessions in [[a.id: a, z.id: z], [z.id: z, a.id: a]] {
            let goals = PullRequestGrouping.goals(pullRequests: [makePR()], links: [key: z.id],
                                                 sessions: sessions, overrides: overrides, now: now)
            XCTAssertEqual(goals.first?.session?.id, "a", "persisted keys precede transcript links with stable ties")
        }
        overrides.assign(key, to: "session:z")
        XCTAssertEqual(PullRequestGrouping.goals(pullRequests: [makePR()], links: [:], sessions: [a.id: a, z.id: z],
                                                overrides: overrides, now: now).first?.session?.id, "z")
    }
}
