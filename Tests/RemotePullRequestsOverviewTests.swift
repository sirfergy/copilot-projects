import Foundation
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsPullRequests
@testable import CopilotProjectsHost

private actor OverviewTranscriptReader: PullRequestTranscriptReading {
    private var holding = true
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var reads = 0

    func evidence(
        for sources: [PullRequestTranscriptIndex.Source], branches: Set<String>
    ) async -> [String: TranscriptEvidence] {
        reads += 1
        if holding { await withCheckedContinuation { held.append($0) } }
        return [:]
    }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }
}

private actor OverviewPreviousSearch: ResumableSessionSearching {
    private var pending: [Int: CheckedContinuation<ResumableSearch, Never>] = [:]
    private var stopped = false
    private(set) var searches = 0
    private(set) var completed: Set<Int> = []

    func search(for pullRequests: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>) async -> ResumableSearch {
        guard !stopped, !pullRequests.isEmpty else { return ResumableSearch() }
        searches += 1
        let call = searches
        let result = await withCheckedContinuation { pending[call] = $0 }
        completed.insert(call)
        return result
    }

    func complete(_ call: Int, with result: ResumableSearch = ResumableSearch()) {
        pending.removeValue(forKey: call)?.resume(returning: result)
    }

    func finish() {
        stopped = true
        for continuation in pending.values { continuation.resume(returning: ResumableSearch()) }
        pending = [:]
    }
}

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
        loadAccounts: @escaping @Sendable () async throws -> [GitHubAccount] = { [] },
        resumableFinder: (any ResumableSessionSearching)? = nil,
        transcriptIndex: (any PullRequestTranscriptReading)? = nil
    ) -> (PullRequestsOverviewProvider, PullRequestsModel) {
        let model = PullRequestsModel(
            workspace: FakeWorkspace(snapshot: current), defaults: defaults, stateDirectory: root,
            service: PullRequestService(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint)),
            loadAccounts: loadAccounts,
            resumableFinder: resumableFinder ?? ResumableSessionFinder(
                store: CopilotSessionStore(environment: ["COPILOT_HOME": root.appendingPathComponent("home").path]),
                cacheURL: nil
            ),
            transcriptIndex: transcriptIndex,
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
            if !model.isRefreshing && !model.isMatchingSessions && !model.isSearchingPreviousSessions { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Hosted refresh did not settle")
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Hosted background work did not reach the expected state")
    }

    func testLocalMatchingAdvertisesBusyWithoutChangingGitHubRefreshCadence() async throws {
        let reader = OverviewTranscriptReader()
        addTeardownBlock { await reader.release() }
        let accounts = OverviewAccounts()
        await accounts.release()
        let (provider, model) = make(loadAccounts: { try await accounts.load() }, transcriptIndex: reader)
        model.apply(.snapshot(current!))
        model.show([makePR()], links: [:], updated: now)
        current?.projects[0].sessions.append(.init(id: "appeared", title: "New tab", status: .idle))
        XCTAssertTrue(provider.snapshot().isRefreshing)
        try await waitUntil { await reader.reads == 1 }
        XCTAssertTrue(model.isMatchingSessions)
        XCTAssertFalse(model.isRefreshing, "The Mac's GitHub refresh flag keeps its existing meaning")
        XCTAssertFalse(provider.snapshot().sessionsKnown)
        XCTAssertTrue(provider.snapshot().isRefreshing, "Polling stays fast while local matching is held")
        let loadsDuringMatching = await accounts.calls
        XCTAssertEqual(loadsDuringMatching, 0)

        await reader.release()
        try await settle(model)
        XCTAssertTrue(provider.snapshot().sessionsKnown)
        XCTAssertFalse(provider.snapshot().isRefreshing)
        now = now.addingTimeInterval(299)
        XCTAssertFalse(provider.snapshot().isRefreshing)
        let loadsBeforeCadence = await accounts.calls
        XCTAssertEqual(loadsBeforeCadence, 0)
        now = now.addingTimeInterval(1)
        XCTAssertTrue(provider.snapshot().isRefreshing)
        try await settle(model)
        let loadsAtCadence = await accounts.calls
        XCTAssertEqual(loadsAtCadence, 1, "Fast UI polling does not shorten the five-minute GitHub cadence")
    }

    func testPreviousSessionSearchStaysBusyThroughDeferredPassesThenSettles() async throws {
        let finder = OverviewPreviousSearch()
        addTeardownBlock { await finder.finish() }
        let (provider, model) = make(resumableFinder: finder)
        let pr = makePR()
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], updated: now)
        current?.projects[0].sessions.append(.init(id: "appeared", title: "New tab", status: .idle))
        _ = provider.snapshot()
        try await waitUntil { await finder.searches == 1 && !model.isMatchingSessions }
        XCTAssertFalse(model.isRefreshing)
        XCTAssertTrue(model.isSearchingPreviousSessions)
        XCTAssertTrue(provider.snapshot().isRefreshing)
        XCTAssertTrue(provider.snapshot().sessionsKnown, "Historical discovery does not invalidate live matching")

        let candidate = ResumableSession(copilotSessionId: UUID().uuidString.lowercased(),
                                        name: "Previous", cwd: root.path, lastActive: now)
        await finder.complete(1, with: ResumableSearch(sessions: [pr.key: candidate], deferred: true))
        XCTAssertTrue(provider.snapshot().isRefreshing)
        try await waitUntil { await finder.searches == 2 }
        XCTAssertTrue(provider.snapshot().isRefreshing, "A deferred pass remains active work, not an idle handle")
        await finder.complete(2, with: ResumableSearch(sessions: [pr.key: candidate]))
        try await settle(model)
        XCTAssertFalse(model.isSearchingPreviousSessions)
        XCTAssertFalse(provider.snapshot().isRefreshing)
        XCTAssertEqual(provider.snapshot().goals.first?.resumable?.copilotSessionId, candidate.copilotSessionId)
        let searches = await finder.searches
        XCTAssertEqual(searches, 2)
    }

    func testCancelledPreviousSearchCannotClearTheReplacementSearchBusyState() async throws {
        let finder = OverviewPreviousSearch()
        addTeardownBlock { await finder.finish() }
        let (provider, model) = make(resumableFinder: finder)
        model.apply(.snapshot(current!))
        model.show([makePR()], links: [:], updated: now)
        current?.projects[0].sessions.append(.init(id: "first", title: "First", status: .idle))
        _ = provider.snapshot()
        try await waitUntil { await finder.searches == 1 }
        current?.projects[0].sessions.append(.init(id: "second", title: "Second", status: .idle))
        _ = provider.snapshot()
        try await waitUntil { await finder.searches == 2 && !model.isMatchingSessions }
        await finder.complete(1)
        try await waitUntil { await finder.completed.contains(1) }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(model.isSearchingPreviousSessions, "A cancelled generation cannot mark its replacement idle")
        XCTAssertTrue(provider.snapshot().isRefreshing)
        await finder.complete(2)
        try await settle(model)
        XCTAssertFalse(provider.snapshot().isRefreshing)
    }

    func testScopeChangeAndDisconnectClearPreviousSearchBusyWithoutWaitingForCancelledFinder() async throws {
        let finder = OverviewPreviousSearch()
        addTeardownBlock { await finder.finish() }
        let (provider, model) = make(resumableFinder: finder)
        model.apply(.snapshot(current!))
        model.show([makePR()], links: [:], updated: now)
        current?.projects[0].sessions.append(.init(id: "first", title: "First", status: .idle))
        _ = provider.snapshot()
        try await waitUntil { await finder.searches == 1 && !model.isMatchingSessions }
        current = nil
        XCTAssertFalse(provider.snapshot().isRefreshing)
        XCTAssertFalse(model.isSearchingPreviousSessions)
        await finder.complete(1)
        try await waitUntil { await finder.completed.contains(1) }

        current = WorkspaceSnapshot(hostProcessIdentifier: 1, selectedProjectId: "p",
                                    projects: [.init(id: "p", name: "Project", sessions: [])])
        _ = provider.snapshot()
        try await waitUntil { await finder.searches == 2 && !model.isMatchingSessions }
        defaults.set("other-owner", forKey: PullRequestsModel.ownersKey)
        _ = provider.snapshot()
        XCTAssertFalse(model.isSearchingPreviousSessions, "Scope invalidation ends the old search's busy lifetime")
        try await settle(model)
        XCTAssertFalse(provider.snapshot().isRefreshing)
        await finder.complete(2)
        try await waitUntil { await finder.completed.contains(2) }
        try await settle(model)
        XCTAssertFalse(provider.snapshot().isRefreshing)
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
        XCTAssertFalse(model.sessionsKnown, "Grouping and the wire must share the same readiness predicate")
        XCTAssertFalse(model.goals(now: now).flatMap(\.items).contains {
            $0.assessment.reasons.contains(.noSession)
        })
        XCTAssertFalse(pending.goals.flatMap(\.items).flatMap(\.reasons).contains { $0.kind == "noSession" },
                       "Unknown matching state must not claim that a PR has no session")
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
        XCTAssertTrue(provider.snapshot().goals.flatMap(\.items).contains {
            $0.id == "o/r#2" && $0.reasons.contains { $0.kind == "noSession" }
        })
        XCTAssertNil(provider.validate(request, workspace: current!))
    }

    func testFreshResumeRejectsLiveAssociationsManualAssignmentsAndTranscriptLinks() throws {
        let cid = UUID().uuidString.lowercased()
        let pr = makePR()
        let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: root.path, lastActive: now)
        let request = RemotePullRequestSessionRequest(requestId: UUID(), kind: "resume", projectId: "p",
                                                     pullRequestKeys: [pr.key.description], copilotSessionId: cid)
        current?.projects[0].sessions = [.init(id: "live", title: "Live", status: .idle)]
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], resumable: [pr.key: candidate], updated: now)
        XCTAssertNil(provider.validate(request, workspace: current!))

        current?.projects[0].sessions[0].pullRequestKeys = [pr.key.description]
        XCTAssertEqual(provider.validate(request, workspace: current!), .conflict)
        current?.projects[0].sessions[0].pullRequestKeys = nil

        var overrides = PullRequestGoalOverrides()
        overrides.assign(pr.key, to: "session:live")
        let file = root.appendingPathComponent("goals.json")
        try JSONEncoder().encode(overrides).write(to: file, options: .atomic)
        XCTAssertEqual(provider.validate(request, workspace: current!), .conflict)
        try FileManager.default.removeItem(at: file)

        model.show([pr], links: [pr.key: "live"], resumable: [pr.key: candidate], updated: now)
        XCTAssertEqual(provider.validate(request, workspace: current!), .conflict)
    }

    func testFreshResumeWaitsForMatchingEvenWithACachedVerifiedCandidate() async throws {
        let pr = makePR()
        let cid = UUID().uuidString.lowercased()
        let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: root.path, lastActive: now)
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], resumable: [pr.key: candidate], updated: now, sessionsMatched: false)
        let request = RemotePullRequestSessionRequest(requestId: UUID(), kind: "resume", projectId: "p",
                                                     pullRequestKeys: [pr.key.description], copilotSessionId: cid)
        guard case .stale = provider.validate(request, workspace: current!) else {
            return XCTFail("Fresh Resume must wait for current workspace matching")
        }
        try await settle(model)
    }

    func testExistingResumeRejectsOtherLiveClaimsButAllowsItsOwn() throws {
        let pr = makePR()
        let cid = UUID().uuidString.lowercased()
        let candidate = ResumableSession(copilotSessionId: cid, name: "Previous", cwd: root.path, lastActive: now)
        current?.projects[0].sessions = [
            .init(id: "existing", title: "Existing", status: .idle, copilotSessionId: cid),
            .init(id: "other", title: "Other", status: .running),
        ]
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], resumable: [pr.key: candidate], updated: now)
        let request = RemotePullRequestSessionRequest(
            requestId: UUID(), kind: "resume", projectId: "p",
            pullRequestKeys: [pr.key.description], copilotSessionId: cid
        )
        XCTAssertNil(provider.validate(request, workspace: current!, existingSessionId: "existing"))

        current?.projects[0].sessions[1].pullRequestKeys = [pr.key.description]
        XCTAssertEqual(provider.validate(request, workspace: current!, existingSessionId: "existing"), .conflict)
        current?.projects[0].sessions[0].pullRequestKeys = [pr.key.description]
        XCTAssertEqual(provider.validate(request, workspace: current!, existingSessionId: "existing"), .conflict,
                       "A claim on this tab must not hide a second live claim")
        current?.projects[0].sessions[1].pullRequestKeys = nil
        XCTAssertNil(provider.validate(request, workspace: current!, existingSessionId: "existing"))
        current?.projects[0].sessions[0].pullRequestKeys = nil

        var overrides = PullRequestGoalOverrides()
        overrides.assign(pr.key, to: "session:other")
        let file = root.appendingPathComponent("goals.json")
        try JSONEncoder().encode(overrides).write(to: file)
        XCTAssertEqual(provider.validate(request, workspace: current!, existingSessionId: "existing"), .conflict)
        try FileManager.default.removeItem(at: file)

        model.show([pr], links: [pr.key: "other"], resumable: [pr.key: candidate], updated: now)
        XCTAssertEqual(provider.validate(request, workspace: current!, existingSessionId: "existing"), .conflict)
        model.show([pr], links: [pr.key: "existing"], resumable: [pr.key: candidate], updated: now)
        XCTAssertNil(provider.validate(request, workspace: current!, existingSessionId: "existing"))

        current?.projects[0].sessions[0].pullRequestKeys = [pr.key.description]
        current?.projects[0].sessions[1].pullRequestKeys = [pr.key.description]
        model.show([], links: [:], updated: now)
        XCTAssertEqual(provider.validate(request, workspace: current!, existingSessionId: "existing"), .conflict,
                       "Persisted claims still conflict when a PR leaves the open list")
        current?.projects[0].sessions[1].pullRequestKeys = nil
        XCTAssertNil(provider.validate(request, workspace: current!, existingSessionId: "existing"))
    }

    func testExistingResumeRejectsTranscriptLinksFromAPreviousCopilotSessionInTheSameTab() {
        let pr = makePR()
        let previousId = UUID().uuidString.lowercased()
        current?.projects[0].sessions = [
            .init(id: "live", title: "Live", status: .idle, copilotSessionId: previousId),
        ]
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([pr], links: [pr.key: "live"], updated: now)
        let previousRequest = RemotePullRequestSessionRequest(
            requestId: UUID(), kind: "resume", projectId: "p",
            pullRequestKeys: [pr.key.description], copilotSessionId: previousId
        )
        XCTAssertNil(provider.validate(previousRequest, workspace: current!, existingSessionId: "live"))

        let currentId = UUID().uuidString.lowercased()
        current?.projects[0].sessions[0].copilotSessionId = currentId
        let currentRequest = RemotePullRequestSessionRequest(
            requestId: UUID(), kind: "resume", projectId: "p",
            pullRequestKeys: [pr.key.description], copilotSessionId: currentId
        )
        if case .stale = provider.validate(currentRequest, workspace: current!, existingSessionId: "live") {
        } else {
            XCTFail("The same tab ID does not verify a link for its new Copilot session")
        }
        XCTAssertFalse(model.sessionsKnown)
        XCTAssertEqual(model.links[pr.key], "live", "The previous transcript match is still cached")

        model.show([pr], links: [pr.key: "live"], updated: now)
        XCTAssertTrue(model.sessionsKnown)
        XCTAssertNil(provider.validate(currentRequest, workspace: current!, existingSessionId: "live"))
    }

    func testExistingResumeKeepsPersistedAssociationsAvailableDuringRematching() async throws {
        let reader = OverviewTranscriptReader()
        addTeardownBlock { await reader.release() }
        let pr = makePR()
        current?.projects[0].sessions = [
            .init(id: "live", title: "Live", status: .idle, copilotSessionId: UUID().uuidString.lowercased()),
        ]
        let (provider, model) = make(transcriptIndex: reader)
        model.apply(.snapshot(current!))
        model.show([pr], links: [pr.key: "live"], updated: now)
        let cid = UUID().uuidString.lowercased()
        current?.projects[0].sessions[0].copilotSessionId = cid
        _ = provider.snapshot()
        try await waitUntil { await reader.reads == 1 }
        XCTAssertTrue(model.isMatchingSessions)
        let request = RemotePullRequestSessionRequest(
            requestId: UUID(), kind: "resume", projectId: "p",
            pullRequestKeys: [pr.key.description], copilotSessionId: cid
        )
        if case .stale = provider.validate(request, workspace: current!, existingSessionId: "live") {
        } else {
            XCTFail("In-flight matching must not authorize a stale transcript link")
        }
        current?.projects[0].sessions[0].pullRequestKeys = [pr.key.description]
        XCTAssertNil(provider.validate(request, workspace: current!, existingSessionId: "live"))
        XCTAssertFalse(model.sessionsKnown)
        await reader.release()
        try await settle(model)
    }

    func testPreviousSessionWithoutMetadataDatesUsesConcreteTranscriptTimeAcrossCacheReload() async throws {
        let home = try CopilotHomeFixture(root: root.appendingPathComponent("copilot"))
        let pr = makePR(7, branch: "me/undated-session")
        let cid = try home.addSession(
            cwd: root.path, transcript: transcript(mentioning: pr.headRefName, times: 3), refs: [pr.key.number]
        )
        let directory = home.root.appendingPathComponent("session-state/\(cid)")
        try Data("id: \(cid)\ncwd: \(root.path)\nclient_name: github/cli\n".utf8)
            .write(to: directory.appendingPathComponent("workspace.yaml"))
        XCTAssertNil(home.store.record(for: cid)?.updatedAt)
        let transcriptURL = directory.appendingPathComponent("events.jsonl")
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: transcriptURL.path)
        let cacheURL = root.appendingPathComponent("resumable-index.json")
        let finder = ResumableSessionFinder(store: home.store, cacheURL: cacheURL)
        let first = await finder.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(first[pr.key]?.lastActive, now)

        let reopened = ResumableSessionFinder(store: home.store, cacheURL: cacheURL)
        let cached = await reopened.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertEqual(cached[pr.key]?.lastActive, now)
        let (provider, model) = make()
        model.apply(.snapshot(current!))
        model.show([pr], links: [:], resumable: cached, updated: now)
        XCTAssertEqual(provider.snapshot().goals.first?.resumable?.lastActiveAtMilliseconds,
                       Int64(now.timeIntervalSince1970 * 1_000))

        try FileManager.default.removeItem(at: transcriptURL)
        let missing = await reopened.find(for: [pr], liveCopilotSessionIds: [])
        XCTAssertTrue(missing.isEmpty, "Unreadable transcripts cannot supply cached evidence without a current timestamp")
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
