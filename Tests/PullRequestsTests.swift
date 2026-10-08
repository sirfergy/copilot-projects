import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import CopilotProjectsHost

let testNow = Date(timeIntervalSince1970: 1_800_000_000)

func makePR(
    _ number: Int = 1, repo: String = "github/github", branch: String = "me/feature-branch",
    draft: Bool = false, updated: TimeInterval = -3_600, created: TimeInterval = -86_400,
    mergeable: PullRequestSnapshot.Mergeable = .mergeable, mergeState: PullRequestSnapshot.MergeState = .blocked,
    review: PullRequestSnapshot.ReviewDecision? = .reviewRequired, checks: PullRequestSnapshot.CheckState? = .success,
    requiredFailing: [String]? = nil, threads: Int = 0, copilotThreads: Int = 0, queued: Bool = false,
    autoMerge: Bool = false, mergeQueue: Bool = false, canMerge: Bool = true
) -> PullRequestSnapshot {
    var snapshot = PullRequestSnapshot(
        key: PullRequestKey(repository: repo, number: number)!, nodeId: "n\(number)", repository: repo,
        title: "PR \(number)", url: URL(string: "https://github.com/\(repo)/pull/\(number)")!, author: "me",
        isDraft: draft, createdAt: testNow.addingTimeInterval(created), updatedAt: testNow.addingTimeInterval(updated),
        headRefName: branch, reviewDecision: review, checks: checks, failingRequiredChecks: requiredFailing,
        unresolvedThreads: threads, unresolvedCopilotThreads: copilotThreads, inMergeQueue: queued, autoMergeEnabled: autoMerge,
        isMergeQueueEnabled: mergeQueue, viewerCanMerge: canMerge
    )
    snapshot.mergeable = mergeable
    snapshot.mergeState = mergeState
    return snapshot
}

final class PullRequestScannerTests: XCTestCase {
    private func withBytes<T>(_ text: String, _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        Array(text.utf8).withUnsafeBufferPointer(body)
    }

    func testMatcherFindsOverlappingPatternsInOnePass() {
        let matcher = MultiPatternMatcher(patterns: ["he", "she", "his", "hers"].map { Array($0.utf8) })
        var found: [(Int, Int)] = []
        withBytes("ushers") { bytes in
            matcher.scan(bytes, in: 0..<bytes.count) { found.append(($0, $1)) }
        }
        XCTAssertEqual(found.map(\.0).sorted(), [0, 1, 3])
        XCTAssertEqual(Set(found.map(\.1)), [4, 6])
    }

    func testBranchMentionsStandAloneButNotAsPrefixesOfLongerBranches() {
        let text = #"{"cmd":"git push origin me/auto-effort"} me/auto-effort-model "\nme/auto-effort\n" xme/auto-effort me/auto-effort/sub me/auto-effort."#
        let counts = withBytes(text) { bytes in
            TranscriptMentionScanner.count(
                in: bytes, range: 0..<bytes.count,
                patterns: .init(branches: ["me/auto-effort", "me/auto-effort-model"], includeURLs: false)
            )
        }
        XCTAssertEqual(counts.branches["me/auto-effort"], 3, "origin/…, an escaped line start, and a sentence end count")
        XCTAssertEqual(counts.branches["me/auto-effort-model"], 1)
    }

    func testPullRequestLinksStopAtTheNumber() {
        let text = "see https://github.com/GitHub/Github/pull/12 and github.com/github/github/pull/123/files and github.com/orgs/x"
        let counts = withBytes(text) { bytes in
            TranscriptMentionScanner.count(in: bytes, range: 0..<bytes.count, patterns: .init(branches: [], includeURLs: true))
        }
        XCTAssertEqual(counts.urls, [
            PullRequestKey(owner: "github", repo: "github", number: 12): 1,
            PullRequestKey(owner: "github", repo: "github", number: 123): 1,
        ])
    }

    func testIndexReadsOnlyWhatTheTranscriptGainedAndBackfillsNewBranches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("events.jsonl")
        try Data("push feature/one\nsee github.com/o/r/pull/7\n".utf8).write(to: log)
        let store = root.appendingPathComponent("index.json")
        let source = PullRequestTranscriptIndex.Source(sessionId: "s", path: log.path)

        let index = PullRequestTranscriptIndex(storeURL: store)
        var evidence = await index.evidence(for: [source], branches: ["feature/one"])
        XCTAssertEqual(evidence["s"]?.branchMentions["feature/one"], 1)
        XCTAssertEqual(evidence["s"]?.urlMentions[PullRequestKey(owner: "o", repo: "r", number: 7)], 1)

        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("again feature/one feature/two\npartial feature/one".utf8))
        try handle.close()
        // A reopened index resumes from disk; the unterminated line waits.
        let reopened = PullRequestTranscriptIndex(storeURL: store)
        evidence = await reopened.evidence(for: [source], branches: ["feature/one", "feature/two"])
        XCTAssertEqual(evidence["s"]?.branchMentions["feature/one"], 2)
        XCTAssertEqual(evidence["s"]?.branchMentions["feature/two"], 1, "a new branch is counted over earlier bytes once")
        XCTAssertEqual(evidence["s"]?.urlMentions[PullRequestKey(owner: "o", repo: "r", number: 7)], 1)

        // A replaced file starts over.
        try FileManager.default.removeItem(at: log)
        try Data("feature/two\n".utf8).write(to: log)
        evidence = await reopened.evidence(for: [source], branches: ["feature/one", "feature/two"])
        XCTAssertEqual(evidence["s"]?.branchMentions["feature/one"], 0)
        XCTAssertEqual(evidence["s"]?.branchMentions["feature/two"], 1)
        XCTAssertNil(evidence["s"]?.urlMentions[PullRequestKey(owner: "o", repo: "r", number: 7)])
    }

    func testTranscriptPathRejectsUnsafeSessionIds() {
        XCTAssertEqual(
            PullRequestTranscriptIndex.transcriptPath(copilotSessionId: "283c2b7c-9f01-4e77", environment: [:], home: "/Users/me"),
            "/Users/me/.copilot/session-state/283c2b7c-9f01-4e77/events.jsonl"
        )
        XCTAssertEqual(
            PullRequestTranscriptIndex.transcriptPath(copilotSessionId: "283c2b7c-9f01", environment: ["COPILOT_HOME": "/c"], home: "/h"),
            "/c/session-state/283c2b7c-9f01/events.jsonl"
        )
        XCTAssertNil(PullRequestTranscriptIndex.transcriptPath(copilotSessionId: "../../etc/x", environment: [:], home: "/h"))
    }
}

final class PullRequestTriageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private let session = Session(title: "Block CCR - GitHub Copilot", cwd: "/tmp")

    func testReasonsArriveMostUrgentFirst() {
        var waiting = session
        waiting.status = .waiting
        let assessment = PullRequestTriage.assess(
            makePR(mergeable: .conflicting, mergeState: .dirty, review: .changesRequested, checks: .failure,
               requiredFailing: ["build"], threads: 2, copilotThreads: 2),
            session: waiting, now: now
        )
        XCTAssertEqual(assessment.reasons, [
            .sessionWaiting, .conflicts, .failingRequiredChecks(1), .changesRequested, .unresolvedThreads(2, copilot: 2),
        ])
        XCTAssertEqual(assessment.stage, .checks)
        XCTAssertEqual(PullRequestAttention.unresolvedThreads(2, copilot: 2).label, "2 Copilot threads open")
        XCTAssertEqual(PullRequestAttention.unresolvedThreads(3, copilot: 1).label, "3 unresolved threads")
    }

    func testOptionalCheckFailuresDoNotBlockAnApprovedPullRequest() {
        let assessment = PullRequestTriage.assess(
            makePR(mergeState: .unknown, review: .approved, checks: .failure, requiredFailing: []), session: session, now: now
        )
        XCTAssertEqual(assessment.reasons, [.readyToMerge])
        XCTAssertEqual(assessment.stage, .ready)

        let unknown = PullRequestTriage.assess(makePR(review: .approved, checks: .failure), session: session, now: now)
        XCTAssertEqual(unknown.reasons, [.failingChecks], "unreadable required checks still need a look")
    }

    func testWaitingSessionDoesNotHideThatAPullRequestIsReady() {
        var waiting = session
        waiting.status = .waiting
        let assessment = PullRequestTriage.assess(makePR(mergeState: .clean, review: .approved), session: waiting, now: now)
        XCTAssertEqual(assessment.reasons, [.sessionWaiting, .readyToMerge])
    }

    func testStagesAndWaitingStates() {
        XCTAssertEqual(PullRequestTriage.assess(makePR(draft: true), session: session, now: now).stage, .draft)
        let running = PullRequestTriage.assess(makePR(checks: .pending), session: session, now: now)
        XCTAssertEqual(running.stage, .checks)
        XCTAssertEqual(running.status, "Checks running")
        XCTAssertTrue(running.reasons.isEmpty)
        let review = PullRequestTriage.assess(makePR(), session: session, now: now)
        XCTAssertEqual(review.stage, .review)
        XCTAssertEqual(review.status, "Awaiting review")
        let queued = PullRequestTriage.assess(makePR(mergeState: .clean, review: .approved, queued: true), session: session, now: now)
        XCTAssertEqual(queued.stage, .ready)
        XCTAssertTrue(queued.reasons.isEmpty, "already merging")
        let behind = PullRequestTriage.assess(makePR(mergeState: .behind, review: .approved), session: session, now: now)
        XCTAssertEqual(behind.reasons, [.behindBase])
    }

    func testBehindAndReadyOnlyWhenTheyAreYoursToAct() {
        let queued = PullRequestTriage.assess(makePR(mergeState: .behind, review: .approved, mergeQueue: true), session: session, now: now)
        XCTAssertTrue(queued.reasons.isEmpty, "a merge queue keeps the branch current")
        let unreviewed = PullRequestTriage.assess(makePR(mergeState: .behind), session: session, now: now)
        XCTAssertTrue(unreviewed.reasons.isEmpty, "updating before review is noise")
        XCTAssertEqual(unreviewed.stage, .review)

        let upstream = PullRequestTriage.assess(makePR(mergeState: .unstable, review: nil, canMerge: false), session: session, now: now)
        XCTAssertTrue(upstream.reasons.isEmpty, "maintainers merge pull requests to repositories you can't write to")
        XCTAssertEqual(upstream.status, "Awaiting maintainers")
        XCTAssertEqual(upstream.stage, .review)

        let auto = PullRequestTriage.assess(makePR(autoMerge: true), session: session, now: now)
        XCTAssertEqual(auto.stage, .review)
        XCTAssertEqual(auto.status, "Awaiting review · auto-merge on")
        let unstable = PullRequestTriage.assess(makePR(mergeState: .unstable, review: .approved, checks: .pending), session: session, now: now)
        XCTAssertEqual(unstable.stage, .ready, "required checks pass when GitHub says unstable")
        XCTAssertEqual(unstable.reasons, [.readyToMerge])
    }

    func testIncompleteReadsAndUncountedThreadsAreNeverReady() {
        var unread = makePR(mergeState: .unknown, review: .approved)
        XCTAssertTrue(PullRequestTriage.isReady(unread), "GitHub still computing: the checks decide")
        unread.isIncomplete = true
        XCTAssertFalse(PullRequestTriage.isReady(unread), "a failed read says nothing")
        XCTAssertTrue(PullRequestTriage.assess(unread, session: session, now: now).reasons.isEmpty)
        var partial = makePR(mergeState: .clean, review: .approved)
        partial.isIncomplete = true
        XCTAssertFalse(PullRequestTriage.isReady(partial), "a field GitHub couldn't return could block it")

        var truncated = makePR(mergeState: .clean, review: .approved)
        truncated.uncountedThreadsCursor = "older"
        XCTAssertFalse(PullRequestTriage.isReady(truncated), "an uncounted thread could be open")
        XCTAssertTrue(PullRequestTriage.assess(truncated, session: session, now: now).reasons.isEmpty)
    }

    func testNudgesForMissingSessionsAndQuietPullRequests() {
        let orphan = PullRequestTriage.assess(makePR(updated: -4 * 86_400), session: nil, now: now)
        XCTAssertEqual(orphan.reasons, [.noSession, .stale(days: 4)])
        XCTAssertTrue(orphan.isNudgeOnly)
        XCTAssertFalse(orphan.needsAction)
        let matching = PullRequestTriage.assess(makePR(), session: nil, now: now, sessionsKnown: false)
        XCTAssertTrue(matching.reasons.isEmpty, "no session claim before transcripts are matched")
    }

    func testDistinctiveBranchesAndLinkThresholds() {
        XCTAssertTrue(PullRequestLinker.isDistinctiveBranch("obvioussean/ccr-auto-review-effort"))
        for common in ["main", "patch-1", "fix-12", "dev", "feature"] {
            XCTAssertFalse(PullRequestLinker.isDistinctiveBranch(common), common)
        }
        let owned = makePR(1, branch: "me/auto-effort")
        let shared = makePR(2, repo: "github/hydro", branch: "me/auto-effort")
        let patch = makePR(3, repo: "o/r", branch: "patch-1")
        let evidence: [String: TranscriptEvidence] = [
            "builder": TranscriptEvidence(branchMentions: ["me/auto-effort": 40], urlMentions: [:]),
            "reviewer": TranscriptEvidence(branchMentions: ["me/auto-effort": 2], urlMentions: [owned.key: 90, patch.key: 4]),
            "fixer": TranscriptEvidence(branchMentions: [:], urlMentions: [patch.key: 6]),
        ]
        let links = PullRequestLinker.links(pullRequests: [owned, shared, patch], evidence: evidence)
        XCTAssertEqual(links, [owned.key: "builder", shared.key: "builder", patch.key: "fixer"])
    }
}

final class PullRequestGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ref(_ title: String, waiting: Bool = false) -> PullRequestSessionRef {
        var session = Session(title: title, cwd: "/tmp")
        if waiting { session.status = .waiting }
        return PullRequestSessionRef(session: session, projectId: "p", projectName: "Features")
    }

    func testSessionsBecomeGoalsAndSiblingsOnTheSameBranchJoinThem() {
        let auto = ref("Integrate Auto Mode into Settings - GitHub Copilot")
        let flags = ref("Clean Up Feature Flags - Waiting for background shells - GitHub Copilot", waiting: true)
        let sessions = [auto.sessionId: auto, flags.sessionId: flags]
        let model = makePR(1, branch: "me/auto-effort-model")
        let hydro = makePR(2, repo: "github/hydro", branch: "me/auto-effort")
        let api = makePR(3, repo: "github/api", branch: "me/auto-effort")
        let flag = makePR(4, repo: "github/ccra", branch: "me/remove-flag")
        let orphanA = makePR(5, repo: "github/a", branch: "me/shared-fix-branch", created: -10)
        let orphanB = makePR(6, repo: "github/b", branch: "me/shared-fix-branch", created: -20)
        let lonely = makePR(7, repo: "github/ops", branch: "me/migrate-playbooks")
        let goals = PullRequestGrouping.goals(
            pullRequests: [model, hydro, api, flag, orphanA, orphanB, lonely],
            links: [model.key: auto.sessionId, hydro.key: auto.sessionId, flag.key: flags.sessionId],
            sessions: sessions, overrides: .init(), now: now
        )
        XCTAssertEqual(goals.map(\.name), [
            "Clean Up Feature Flags", "PR 6", "PR 7", "Integrate Auto Mode into Settings",
        ], "the waiting session's goal leads; goals with only nudges come before goals that need nothing")
        XCTAssertEqual(Set(goals[3].items.map(\.pr.key)), [model.key, hydro.key, api.key])
        XCTAssertEqual(goals[3].kind, .session)
        XCTAssertEqual(goals[1].kind, .branch)
        XCTAssertEqual(Set(goals[1].items.map(\.pr.key)), [orphanA.key, orphanB.key])
        XCTAssertEqual(goals[2].kind, .single)
        XCTAssertEqual(goals[2].items[0].assessment.reasons, [.noSession])
    }

    func testActiveSessionsOutrankGoalsNoSessionIsDriving() {
        let live = ref("Live - GitHub Copilot")
        let threads = makePR(1, branch: "me/live-branch", threads: 1)
        let conflicted = makePR(2, repo: "github/old", branch: "me/old-branch", mergeable: .conflicting, mergeState: .dirty)
        let goals = PullRequestGrouping.goals(
            pullRequests: [conflicted, threads], links: [threads.key: live.sessionId],
            sessions: [live.sessionId: live], overrides: .init(), now: now
        )
        XCTAssertEqual(goals.map(\.name), ["Live", "PR 2"])
        XCTAssertEqual(goals.map(\.focusRank), [0, 1])
    }

    func testManualGoalsSessionOverridesAndStartedSessions() {
        let auto = ref("Auto - GitHub Copilot")
        let other = ref("Other - GitHub Copilot")
        let sessions = [auto.sessionId: auto, other.sessionId: other]
        let first = makePR(1, branch: "me/first-branch")
        let second = makePR(2, branch: "me/second-branch")
        let third = makePR(3, branch: "me/third-branch")
        let fourth = makePR(4, branch: "me/fourth-branch")
        var overrides = PullRequestGoalOverrides()
        overrides.names["manual:x"] = "Hardening"
        overrides.assign(first.key, to: "manual:x")
        overrides.assign(second.key, to: PullRequestGrouping.sessionGoalId(other.sessionId))
        overrides.assign(fourth.key, to: "session:ended")
        overrides.sessionLinks[third.key.description] = other.sessionId
        let goals = PullRequestGrouping.goals(
            pullRequests: [first, second, third, fourth],
            links: [first.key: auto.sessionId, fourth.key: auto.sessionId],
            sessions: sessions, overrides: overrides, now: now
        )
        let byName = Dictionary(uniqueKeysWithValues: goals.map { ($0.name, $0) })
        XCTAssertEqual(byName["Hardening"]?.items.map(\.pr.key), [first.key])
        XCTAssertEqual(byName["Hardening"]?.items.first?.session?.sessionId, auto.sessionId, "its own session still counts")
        XCTAssertEqual(Set(byName["Other"]?.items.map(\.pr.key) ?? []), [second.key, third.key])
        XCTAssertEqual(byName["Auto"]?.items.map(\.pr.key), [fourth.key], "an ended session's override falls back")
        XCTAssertEqual(byName["Other"]?.items.first { $0.pr.key == second.key }?.isManuallyAssigned, true)

        overrides.assign(first.key, to: nil)
        XCTAssertTrue(overrides.names.isEmpty, "unused goal names are dropped")
    }

    func testGoalNamesComeFromCopilotTerminalTitles() {
        XCTAssertEqual(PullRequestGrouping.goalName(sessionTitle: "Block CCR - GitHub Copilot"), "Block CCR")
        XCTAssertEqual(
            PullRequestGrouping.goalName(sessionTitle: "Fix Display - Waiting for background shells - GitHub Co"),
            "Fix Display"
        )
        XCTAssertEqual(PullRequestGrouping.goalName(sessionTitle: "Copilot"), "Copilot")
    }
}

final class PullRequestServiceTests: XCTestCase {
    func testSnapshotCountsThreadsThatAreStillYoursToAnswer() throws {
        let json = """
        {"id":"PR_1","number":42,"title":"add things","url":"https://github.com/GitHub/Repo/pull/42","isDraft":false,
         "state":"OPEN","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-06T12:00:00Z","headRefName":"me/things",
         "author":{"login":"Me"},"repository":{"nameWithOwner":"GitHub/Repo"},"reviewDecision":"CHANGES_REQUESTED",
         "autoMergeRequest":null,"mergeQueueEntry":{"state":"QUEUED"},
         "reviewThreads":{"nodes":[
           {"isResolved":false,"isOutdated":false,"opener":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer"}}]},"latest":{"nodes":[{"author":{"login":"copilot-pull-request-reviewer"}}]}},
           {"isResolved":false,"isOutdated":false,"opener":{"nodes":[{"author":{"login":"alice"}}]},"latest":{"nodes":[{"author":{"login":"me"}}]}},
           {"isResolved":false,"isOutdated":true,"opener":{"nodes":[{"author":{"login":"alice"}}]},"latest":{"nodes":[{"author":{"login":"alice"}}]}},
           {"isResolved":true,"isOutdated":false,"opener":{"nodes":[{"author":{"login":"alice"}}]},"latest":{"nodes":[{"author":{"login":"alice"}}]}},
           {"isResolved":false,"isOutdated":false,"opener":{"nodes":[{"author":null}]},"latest":{"nodes":[{"author":null}]}}
         ]},
         "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"PENDING"}}}]}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let node = try decoder.decode(PullRequestNodes.Node.self, from: Data(json.utf8))
        let snapshot = try XCTUnwrap(node.snapshot(viewerLogins: ["me"]))
        XCTAssertEqual(snapshot.key, PullRequestKey(owner: "github", repo: "repo", number: 42))
        XCTAssertEqual(snapshot.shortName, "Repo#42")
        XCTAssertEqual(snapshot.unresolvedThreads, 2)
        XCTAssertEqual(snapshot.unresolvedCopilotThreads, 1)
        XCTAssertEqual(snapshot.reviewDecision, .changesRequested)
        XCTAssertEqual(snapshot.checks, .pending)
        XCTAssertTrue(snapshot.inMergeQueue)
        XCTAssertFalse(snapshot.autoMergeEnabled)
        XCTAssertFalse(snapshot.viewerCanMerge, "a permission GitHub didn't report can't merge")
        XCTAssertNil(snapshot.uncountedThreadsCursor)

        let writable = try decoder.decode(PullRequestNodes.Node.self, from: Data(json.replacingOccurrences(
            of: #""nameWithOwner":"GitHub/Repo"}"#, with: #""nameWithOwner":"GitHub/Repo","viewerPermission":"WRITE"}"#
        ).utf8))
        XCTAssertEqual(writable.snapshot(viewerLogins: ["me"])?.viewerCanMerge, true)
        let long = try decoder.decode(PullRequestNodes.Node.self, from: Data(json.replacingOccurrences(
            of: #""reviewThreads":{"#, with: #""reviewThreads":{"pageInfo":{"hasPreviousPage":true,"startCursor":"older"},"#
        ).utf8))
        XCTAssertEqual(long.snapshot(viewerLogins: ["me"])?.uncountedThreadsCursor, "older")

        let closed = try decoder.decode(PullRequestNodes.Node.self, from: Data(json.replacingOccurrences(of: "\"OPEN\"", with: "\"MERGED\"").utf8))
        XCTAssertNil(closed.snapshot(viewerLogins: ["me"]))
    }

    func testSignedInAccountsListTheActiveOneFirst() {
        let status = """
        {"hosts":{"github.com":[
          {"state":"success","active":false,"host":"github.com","login":"sirfergy"},
          {"state":"success","active":true,"host":"github.com","login":"obvioussean"},
          {"state":"error","active":false,"host":"github.com","login":"expired"}
        ],"ghe.example.com":[{"state":"success","active":true,"login":"elsewhere"}]}}
        """
        XCTAssertEqual(GitHubCLI.logins(fromStatus: Data(status.utf8)), ["obvioussean", "sirfergy"])
        XCTAssertEqual(GitHubCLI.logins(fromStatus: Data("not json".utf8)), [])
    }

    func testOwnersScopeTheSearch() {
        XCTAssertEqual(
            PullRequestService.searchQuery(owners: ["github", "bad owner", "sirfergy"]),
            "is:pr is:open author:@me archived:false sort:updated-desc user:github user:sirfergy"
        )
        XCTAssertEqual(PullRequestsModel.ownerList("github, @sirfergy  GitHub ,, -bad"), ["github", "sirfergy"])
    }

    @MainActor
    func testRefreshAskedForDuringARefreshRunsOnceMoreAndFailuresStayVisible() async throws {
        actor Calls { var count = 0; func bump() { count += 1 } }
        let calls = Calls()
        let model = PullRequestsModel(
            appModel: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!, stateDirectory: nil,
            loadAccounts: {
                await calls.bump()
                try await Task.sleep(nanoseconds: 50_000_000)
                throw PullRequestFetchError.notSignedIn
            },
            copilotSessionId: { _ in nil }, sessions: { [:] }, projects: { [] }
        )
        model.refresh()
        model.refresh()
        model.refresh()
        for _ in 0..<100 where await calls.count < 2 || model.isRefreshing {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let count = await calls.count
        XCTAssertEqual(count, 2, "requests during a refresh collapse into one more")
        XCTAssertEqual(model.phase, .failed(.notSignedIn))
    }

    @MainActor
    func testChangingOwnersDropsRowsOutsideTheNewScopeAtOnce() {
        let model = PullRequestsModel(
            appModel: nil, defaults: UserDefaults(suiteName: UUID().uuidString)!, stateDirectory: nil,
            loadAccounts: { [] }, copilotSessionId: { _ in nil }, sessions: { [:] }, projects: { [] }
        )
        model.show([makePR(1, repo: "github/github"), makePR(2, repo: "My-Org/tools")], links: [:])
        model.owners = "MY-ORG"
        XCTAssertEqual(model.pullRequests.map(\.key.description), ["my-org/tools#2"])
        model.owners = ""
        XCTAssertEqual(model.pullRequests.map(\.key.description), ["my-org/tools#2"], "widening waits for a refresh")
        XCTAssertEqual(
            PullRequestsModel.inScope([makePR(1), makePR(2, repo: "other/repo")], owners: ["GitHub"]).map(\.key.description),
            ["github/github#1"]
        )
    }

    func testShortReasonsAndGoalNames() {
        XCTAssertEqual(PullRequestAttention.sessionWaiting.shortLabel, "Needs input")
        XCTAssertEqual(PullRequestAttention.stale(days: 9).shortLabel, "Quiet 9d")
        XCTAssertEqual(PullRequestGrouping.sentenceCase("migrate playbooks"), "Migrate playbooks")
        XCTAssertEqual(PullRequestGrouping.sentenceCase("Block CCR"), "Block CCR")
    }

    func testStartingPromptListsEveryPullRequest() {
        let prompt = PullRequestsModel.startingPrompt(for: [makePR(1), makePR(2, repo: "github/hydro")])
        XCTAssertTrue(prompt.hasPrefix("Help me move these pull requests forward:"))
        XCTAssertTrue(prompt.contains("- https://github.com/github/github/pull/1\n- https://github.com/github/hydro/pull/2"))
    }
}

/// Answers GitHub GraphQL requests to `host` from `respond`.
final class GraphQLStub: URLProtocol {
    static let host = "graphql.stub.invalid"
    static var endpoint: URL { URL(string: "https://\(host)/graphql")! }
    /// Token and request body → HTTP status and response body.
    static var respond: (String, [String: Any]) -> (Int, String) = { _, _ in (500, "") }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "").replacingOccurrences(of: "bearer ", with: "")
        let (status, text) = Self.respond(token, body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class PullRequestServiceRequestTests: XCTestCase {
    private let service = PullRequestService(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint))

    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(GraphQLStub.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(GraphQLStub.self)
        GraphQLStub.respond = { _, _ in (500, "") }
        super.tearDown()
    }

    private func thread(resolved: Bool, by login: String) -> String {
        """
        {"isResolved":\(resolved),"isOutdated":false,"opener":{"nodes":[{"author":{"login":"\(login)"}}]},\
        "latest":{"nodes":[{"author":{"login":"\(login)"}}]}}
        """
    }

    private func pullRequest(_ number: Int, olderThreads cursor: String?, author: String = "good") -> String {
        let page = cursor.map { #"{"hasPreviousPage":true,"startCursor":"\#($0)"}"# } ?? #"{"hasPreviousPage":false,"startCursor":null}"#
        return """
        {"id":"PR_\(number)","number":\(number),"title":"long review","url":"https://github.com/o/r/pull/\(number)",
         "isDraft":false,"state":"OPEN","createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-06T00:00:00Z",
         "headRefName":"me/long-review-\(number)","author":{"login":"\(author)"},
         "repository":{"nameWithOwner":"o/r","viewerPermission":"WRITE"},"reviewDecision":null,
         "autoMergeRequest":null,"mergeQueueEntry":null,
         "reviewThreads":{"pageInfo":\(page),
           "nodes":[\(thread(resolved: true, by: "alice")),\(thread(resolved: false, by: "bad"))]},
         "commits":{"nodes":[]}}
        """
    }

    @MainActor
    func testOwnersAreStrictEvenForPullRequestsASessionKeepsNaming() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let copilotId = "abcdef12-0000-4000-8000-000000000001"
        let log = root.appendingPathComponent("session-state/\(copilotId)/events.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = String(repeating: "push me/elsewhere-branch https://github.com/someone/else/pull/9\n", count: 20)
        try Data(elsewhere.utf8).write(to: log)
        let previousHome = ProcessInfo.processInfo.environment["COPILOT_HOME"]
        setenv("COPILOT_HOME", root.path, 1)
        defer { if let previousHome { setenv("COPILOT_HOME", previousHome, 1) } else { unsetenv("COPILOT_HOME") } }

        let search = """
        {"data":{"viewer":{"login":"good"},"search":{"issueCount":1,"pageInfo":{"hasNextPage":false,"endCursor":null},
         "nodes":[\(pullRequest(1, olderThreads: nil))]}}}
        """
        var queries: [String] = []
        GraphQLStub.respond = { _, body in
            let query = body["query"] as? String ?? ""
            queries.append(query)
            if query.contains("search(") {
                XCTAssertEqual((body["variables"] as? [String: Any])?["q"] as? String,
                               "is:pr is:open author:@me archived:false sort:updated-desc user:o user:other-org")
                return (200, search)
            }
            if query.contains("mergeStateStatus") {
                return (200, #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":"BLOCKED"}}}"#)
            }
            return (500, "")
        }
        let session = Session(title: "Elsewhere - GitHub Copilot", cwd: "/tmp")
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("o, other-org", forKey: PullRequestsModel.ownersKey)
        let model = PullRequestsModel(
            appModel: nil, defaults: defaults, stateDirectory: root.appendingPathComponent("state"),
            service: service, loadAccounts: { [GitHubAccount(login: "good", token: "good")] },
            copilotSessionId: { _ in copilotId },
            sessions: { [session.id: PullRequestSessionRef(session: session, projectId: "p", projectName: "P")] },
            projects: { [] }
        )
        model.refresh()
        for _ in 0..<250 where model.isRefreshing || model.lastUpdated == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.pullRequests.map(\.key.description), ["o/r#1"])
        XCTAssertFalse(queries.contains { $0.contains("repository(owner:") }, "nothing outside the owners is looked up")
    }

    func testOwnersButtonNamesTwoThenCounts() {
        XCTAssertEqual(PullRequestsView.ownersLabel([]), "Every Owner")
        XCTAssertEqual(PullRequestsView.ownersLabel(["github", "my-org"]), "github, my-org")
        XCTAssertEqual(PullRequestsView.ownersLabel(["github", "my-org", "a", "b"]), "github, my-org +2")
    }

    @MainActor
    func testReturnInTheOwnersFieldAppliesPendingText() {
        var draft: [String] = []
        var submitted: [String]?
        let coordinator = OwnersTokenField.Coordinator(
            owners: Binding(get: { draft }, set: { draft = $0 }), onSubmit: { submitted = $0 }
        )
        let field = NSTokenField()
        field.stringValue = "github, @my-org"
        XCTAssertFalse(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertNil(submitted)
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submitted, ["github", "my-org"])
        XCTAssertEqual(draft, ["github", "my-org"])
    }

    func testSearchWarnsAboutAFailedAccountAndCountsOlderThreads() async throws {
        let search = """
        {"data":{"viewer":{"login":"good"},"search":{"issueCount":3,"pageInfo":{"hasNextPage":false,"endCursor":null},
         "nodes":[\(pullRequest(1, olderThreads: "c1")),\(pullRequest(2, olderThreads: "broken")),\(pullRequest(3, olderThreads: "partial"))]}},
         "errors":[{"message":"Something went wrong","type":"SERVICE_UNAVAILABLE","path":["search","nodes",0,"reviewDecision"]}]}
        """
        let partialThreads = """
        {"data":{"node":{"reviewThreads":{"pageInfo":{"hasPreviousPage":false,"startCursor":"c0"},"nodes":[null]}}},
         "errors":[{"message":"Something went wrong","path":["node","reviewThreads","nodes",0]}]}
        """
        let olderThreads = """
        {"data":{"node":{"reviewThreads":{"pageInfo":{"hasPreviousPage":false,"startCursor":"c0"},
         "nodes":[\(thread(resolved: false, by: "copilot-pull-request-reviewer")),\(thread(resolved: true, by: "alice"))]}}}}
        """
        GraphQLStub.respond = { token, body in
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if token == "bad" { return (502, "") }
            if query.contains("search(") { return (200, search) }
            if query.contains("before: $cursor") {
                switch variables["cursor"] as? String {
                case "c1": return (200, olderThreads)
                case "partial": return (200, partialThreads)
                default: return (500, "")
                }
            }
            return (500, "")
        }
        let fetch = try await service.search(
            accounts: [GitHubAccount(login: "bad", token: "bad"), GitHubAccount(login: "good", token: "good")], owners: []
        )
        XCTAssertEqual(fetch.warnings.first, "Couldn’t read bad’s pull requests: GitHub returned HTTP 502.")
        let byNumber = Dictionary(uniqueKeysWithValues: fetch.pullRequests.map { ($0.key.number, $0) })
        XCTAssertEqual(
            byNumber[1]?.unresolvedThreads, 1,
            "an open thread past the first page counts; one your other account answered doesn't"
        )
        XCTAssertEqual(byNumber[1]?.unresolvedCopilotThreads, 1)
        XCTAssertNil(byNumber[1]?.uncountedThreadsCursor)
        XCTAssertEqual(byNumber[2]?.uncountedThreadsCursor, "broken", "threads that couldn't be read stay uncounted")
        XCTAssertFalse(PullRequestTriage.isReady(try XCTUnwrap(byNumber[2])))
        XCTAssertEqual(byNumber[3]?.uncountedThreadsCursor, "partial", "a page read with errors stays uncounted")
        XCTAssertEqual(byNumber[1]?.isIncomplete, true, "an error inside a result marks only that result")
        XCTAssertEqual(byNumber[2]?.isIncomplete, false)
        XCTAssertFalse(PullRequestTriage.isReady(try XCTUnwrap(byNumber[1])))
    }

    func testEnrichFailsClosedAndCountsStaleRequiredChecks() async throws {
        let contexts = """
        {"data":{"node":{"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{
         "pageInfo":{"hasNextPage":false,"endCursor":null},
         "nodes":[{"name":"build","conclusion":"STALE","isRequired":true},{"name":"lint","conclusion":"FAILURE","isRequired":false}]
        }}}}]}}}}
        """
        let partial = #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":null}},"errors":[{"message":"timeout"}]}"#
        GraphQLStub.respond = { _, body in
            let query = body["query"] as? String ?? ""
            let id = (body["variables"] as? [String: Any])?["id"] as? String
            if query.contains("mergeStateStatus") {
                switch id {
                case "n1": return (502, "")
                case "n3": return (200, partial)
                default: return (200, #"{"data":{"node":{"mergeable":"MERGEABLE","mergeStateStatus":"UNKNOWN"}}}"#)
                }
            }
            if query.contains("contexts(") {
                return id == "n3" ? (200, contexts.replacingOccurrences(of: "}}}}]}}}}", with: #"}}}}]}}},"errors":[{"message":"timeout"}]}"#)) : (200, contexts)
            }
            return (500, "")
        }
        let unread = makePR(1, mergeState: .unknown, review: .approved)
        let stale = makePR(2, mergeState: .unknown, review: .approved, checks: .failure)
        let errored = makePR(3, mergeState: .unknown, review: .approved, checks: .failure)
        let enriched = await service.enrich(
            [unread, stale, errored], tokens: [unread.key: "t", stale.key: "t", errored.key: "t"]
        )
        XCTAssertTrue(enriched[0].isIncomplete)
        XCTAssertFalse(PullRequestTriage.isReady(enriched[0]), "a failed merge-state read isn't ready")
        XCTAssertFalse(enriched[1].isIncomplete)
        XCTAssertEqual(enriched[1].failingRequiredChecks, ["build"], "a stale required check fails")
        XCTAssertFalse(PullRequestTriage.isReady(enriched[1]))
        XCTAssertTrue(enriched[2].isIncomplete, "field errors are a failed read")
        XCTAssertNil(enriched[2].failingRequiredChecks, "required checks read with errors stay unknown")
    }
}
