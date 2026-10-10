import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsPullRequests

final class PullRequestsPresentationTests: XCTestCase {
    private func item(_ number: Int, session: PullRequestSession?, pr: PullRequestSnapshot? = nil) -> PullRequestItem {
        let pr = pr ?? makePR(number)
        return PullRequestItem(
            pr: pr, assessment: PullRequestTriage.assess(pr, session: session, now: testNow),
            session: session, isManuallyAssigned: false
        )
    }

    private let waiting = PullRequestSession(
        id: "waiting", title: "Feature", projectId: "p", projectName: "Features", status: .waiting
    )
    private let idle = PullRequestSession(id: "idle", title: "Other", projectId: "p", projectName: "Features")

    func testReviewReadinessIsShownOnlyInChecksRegardlessOfApproval() {
        let reviews: [PullRequestSnapshot.ReviewDecision?] = [.reviewRequired, .approved, .changesRequested, nil]
        let checks: [PullRequestSnapshot.CheckState?] = [.pending, .expected, .failure, .error]
        for review in reviews {
            for check in checks {
                let pr = makePR(review: review, checks: check)
                let row = item(1, session: idle, pr: pr)
                XCTAssertEqual(row.assessment.stage, .checks)
                XCTAssertEqual(PullRequestsPresentation.reviewReadiness(row), "Ready for review")
            }
        }
        for pr in [makePR(draft: true), makePR(), makePR(mergeState: .clean, review: .approved)] {
            XCTAssertNil(PullRequestsPresentation.reviewReadiness(item(1, session: idle, pr: pr)))
        }
        let draftPlaceholder = PullRequestItem(
            pr: makePR(), assessment: .init(stage: .draft, reasons: [], status: "Draft"),
            session: nil, isManuallyAssigned: false
        )
        XCTAssertNil(PullRequestsPresentation.reviewReadiness(draftPlaceholder))
    }

    func testReadyForReviewRemainsVisibleWhileChecksDetermineTheColumn() {
        let reviews: [PullRequestSnapshot.ReviewDecision?] = [.reviewRequired, .approved, nil]
        for review in reviews {
            let row = item(1, session: idle, pr: makePR(review: review, checks: .pending))
            XCTAssertEqual(row.assessment.stage, .checks)
            XCTAssertEqual(row.assessment.status, "Checks running")
            XCTAssertEqual(row.assessment.reasons, [])
            XCTAssertEqual(PullRequestChip.statusText(row), "Checks running, Ready for review")
        }
        let draft = item(1, session: idle, pr: makePR(draft: true, checks: .pending))
        XCTAssertEqual(draft.assessment.stage, .draft)
        XCTAssertEqual(PullRequestChip.statusText(draft), "Draft")
    }

    func testFilterPreservesQuietSiblingsAndUsesAllAttentionIncludingNudges() {
        let active = PullRequestGoal(
            id: "active", kind: .manual, name: "Feature", session: nil,
            items: [item(1, session: waiting), item(2, session: idle)]
        )
        let quiet = PullRequestGoal(id: "quiet", kind: .session, name: "Other", session: idle, items: [item(3, session: idle)])
        let nudge = PullRequestGoal(id: "nudge", kind: .single, name: "Nudge", session: nil, items: [item(4, session: nil)])
        let goals = [active, quiet, nudge]
        XCTAssertEqual(PullRequestsFilter.all.goals(in: goals), goals)
        let filtered = PullRequestsFilter.needsYou.goals(in: goals)
        XCTAssertEqual(filtered.map(\.id), ["active", "nudge"])
        XCTAssertEqual(filtered[0].items.count, 2)
    }

    func testSharedWaitingStateLeavesTheReadyReasonAndTriageUntouched() {
        let row = item(1, session: waiting, pr: makePR(1, mergeState: .clean, review: .approved))
        XCTAssertEqual(row.assessment.reasons, [.sessionWaiting, .readyToMerge])
        XCTAssertEqual(PullRequestsPresentation.reasons(for: row, sessionStateInSummary: true), [.readyToMerge])
        XCTAssertEqual(row.assessment.urgency, 0)
        XCTAssertTrue(row.assessment.needsYou)
        XCTAssertEqual(PullRequestChip.statusText(row), "Session needs your input, Ready to merge")
    }

    func testMixedManualGoalsRetainEachItemsSessionReasonIncludingNoSession() {
        for second in [item(2, session: nil), item(2, session: idle)] {
            let rows = [item(1, session: waiting), second]
            let goal = PullRequestGoal(id: "g", kind: .manual, name: "Mixed", session: nil, items: rows)
            XCTAssertFalse(PullRequestsPresentation.sharesSessionState(goal))
            for row in rows {
                XCTAssertEqual(PullRequestsPresentation.reasons(for: row, sessionStateInSummary: false), row.assessment.reasons)
            }
        }
    }

    func testAllSessionlessGoalCanSummarizeNoSessionOnce() {
        let rows = [item(1, session: nil), item(2, session: nil)]
        let goal = PullRequestGoal(id: "g", kind: .branch, name: "Feature", session: nil, items: rows)
        XCTAssertTrue(PullRequestsPresentation.sharesSessionState(goal))
        XCTAssertTrue(PullRequestsPresentation.reasons(for: rows[0], sessionStateInSummary: true).isEmpty)
    }

    func testPartialStatusIncludesUncountedThreadsAndUnknownRequiredChecks() {
        var pr = makePR()
        XCTAssertFalse(PullRequestsPresentation.hasPartialStatus(pr))
        pr.uncountedThreadsCursor = "more"
        XCTAssertTrue(PullRequestsPresentation.hasPartialStatus(pr))
        pr = makePR(checks: .failure)
        XCTAssertTrue(PullRequestsPresentation.hasPartialStatus(pr))
        pr.failingRequiredChecks = []
        XCTAssertFalse(PullRequestsPresentation.hasPartialStatus(pr))
        pr.isIncomplete = true
        XCTAssertTrue(PullRequestsPresentation.hasPartialStatus(pr))
    }

    func testSessionlessTextOnlyClaimsAnActiveMatchIsMatching() {
        for (connected, known, matching, manual, expected) in [
            (false, false, true, false, "Session unknown"),
            (true, false, true, false, "Matching sessions…"),
            (true, false, false, false, "Sessions not matched"),
            (true, true, false, false, "No session on this goal"),
            (true, true, false, true, "Your goal · no session"),
        ] {
            XCTAssertEqual(PullRequestsPresentation.sessionlessText(
                isConnected: connected, sessionsKnown: known, isMatchingSessions: matching, isManualGoal: manual
            ), expected)
        }
    }

    func testSpokenStatusIncludesPartialWarningAndEveryAttentionReason() {
        var incomplete = makePR(review: .approved)
        incomplete.isIncomplete = true
        var uncounted = makePR(review: .approved)
        uncounted.uncountedThreadsCursor = "more"
        for pr in [incomplete, uncounted] {
            let row = item(1, session: idle, pr: pr)
            XCTAssertEqual(PullRequestChip.statusText(row), "Approved, some status unavailable")
            XCTAssertEqual(PullRequestChip.statusText(row, checkingStatus: true), "Approved, checking status")
        }
        let waitingOnChecks = item(1, session: waiting, pr: makePR(checks: .failure, threads: 2))
        XCTAssertEqual(
            PullRequestChip.statusText(waitingOnChecks),
            "Session needs your input, Checks failing, 2 unresolved threads, Ready for review, some status unavailable"
        )
        let complete = item(1, session: idle, pr: makePR(review: .approved))
        XCTAssertEqual(PullRequestChip.statusText(complete, checkingStatus: true), "Approved")
    }

    func testRefreshingCannotRedirectTheNextReturnToAnotherPullRequest() {
        let first = makePR(1).key
        let second = makePR(2).key
        XCTAssertNil(PullRequestsPresentation.selection(first, visible: [second], userChangedFilter: false))
        XCTAssertEqual(PullRequestsPresentation.selection(first, visible: [second], userChangedFilter: true), second)
        XCTAssertEqual(PullRequestsPresentation.selection(first, visible: [first, second], userChangedFilter: false), first)
        XCTAssertNil(PullRequestsPresentation.selection(first, visible: [], userChangedFilter: true))
    }

    func testPreviousSessionNameDoesNotRepeatTheGoalOrGenericFallback() {
        XCTAssertNil(PullRequestsPresentation.candidateName("Feature - GitHub Copilot", goalName: "feature"))
        XCTAssertNil(PullRequestsPresentation.candidateName("Copilot session", goalName: "Feature"))
        XCTAssertEqual(PullRequestsPresentation.candidateName("Fix retry handling", goalName: "Ship billing"), "Fix retry handling")
    }
}

@MainActor
final class PullRequestsDesignCaptureTests: XCTestCase {
    private struct NoHistoricalSessions: ResumableSessionSearching {
        func search(for prs: [PullRequestSnapshot], liveCopilotSessionIds: Set<String>) async -> ResumableSearch {
            ResumableSearch()
        }
    }

    func testNeedsYouEmptyStateDoesNotClaimUnknownGoalsAreClear() async {
        let model = PullRequestsModel(
            workspace: FakeWorkspace(snapshot: WorkspaceSnapshot(
                hostProcessIdentifier: 4242, selectedProjectId: "p", projects: [
                    .init(id: "p", name: "Features", sessions: [
                        .init(id: "idle", title: "Feature", status: .idle),
                    ]),
                ]
            )),
            defaults: UserDefaults(suiteName: "pr-design-\(UUID().uuidString)")!,
            stateDirectory: nil, resumableFinder: NoHistoricalSessions(),
            isVisible: { false }, presentError: { _, _ in }
        )
        await model.pollWorkspace()
        let complete = makePR()
        var incomplete = complete
        incomplete.isIncomplete = true
        var uncounted = complete
        uncounted.uncountedThreadsCursor = "more"
        for pr in [complete, incomplete, uncounted] {
            model.show([pr], links: [pr.key: "idle"])
            let goals = model.goals(now: testNow)
            XCTAssertEqual(goals.count, 1)
            XCTAssertTrue(PullRequestsFilter.needsYou.goals(in: goals).isEmpty)
            let state = PullRequestsView(pullRequests: model).needsYouEmptyState
            let isPartial = PullRequestsPresentation.hasPartialStatus(pr)
            XCTAssertEqual(state.title, isPartial ? "Some PR status is unknown" : "Nothing needs you")
            XCTAssertEqual(state.systemImage, isPartial ? "questionmark.circle" : "checkmark.circle")
        }
    }

    func testOrdinaryRefreshKeepsKnownSessionActionsAndReasonsStable() async throws {
        let model = PullRequestsModel(
            workspace: FakeWorkspace(snapshot: WorkspaceSnapshot(
                hostProcessIdentifier: 4242, selectedProjectId: nil, projects: []
            )),
            defaults: UserDefaults(suiteName: "pr-design-\(UUID().uuidString)")!,
            stateDirectory: nil,
            loadAccounts: {
                try await Task.sleep(nanoseconds: 150_000_000)
                throw PullRequestFetchError.notSignedIn
            },
            resumableFinder: NoHistoricalSessions(), isVisible: { false }, presentError: { _, _ in }
        )
        model.show([makePR()], links: [:])
        await model.pollWorkspace()
        XCTAssertTrue(model.sessionsMatched)
        let before = model.goals(now: testNow)
        model.refresh()
        for _ in 0..<50 where !model.isRefreshing { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(model.isRefreshing)
        XCTAssertFalse(model.isMatchingSessions)
        XCTAssertTrue(model.sessionsKnown)
        XCTAssertEqual(model.goals(now: testNow), before)
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(model.isMatchingSessions, "failure releases the pending state without discarding old data")
        XCTAssertEqual(model.pullRequests.count, 1)
        XCTAssertNotNil(model.warning)
    }

    func testCaptureNativeDesignStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["PR_DESIGN_CAPTURE_DIR"] else {
            throw XCTSkip("Set PR_DESIGN_CAPTURE_DIR to capture synthetic native states")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        let projectName = "Features and infrastructure improvements"
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 4242, selectedProjectId: "p", projects: [
            .init(id: "p", name: projectName, sessions: [
                .init(id: "s1", title: "Ship review settings", status: .waiting),
                .init(id: "s2", title: "Clean up feature flags", status: .running),
            ]),
        ])
        func pr(_ n: Int, repo: String, title: String, review: PullRequestSnapshot.ReviewDecision? = .reviewRequired,
                mergeState: PullRequestSnapshot.MergeState = .blocked, checks: PullRequestSnapshot.CheckState? = .success,
                draft: Bool = false) -> PullRequestSnapshot {
            PullRequestSnapshot(
                key: PullRequestKey(repository: repo, number: n)!, nodeId: "n\(n)", repository: repo,
                title: title, url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, author: "fixture",
                isDraft: draft, createdAt: now.addingTimeInterval(-86_400), updatedAt: now.addingTimeInterval(-3600),
                headRefName: "feature/\(n)", mergeable: .mergeable, mergeState: mergeState, reviewDecision: review,
                checks: checks, unresolvedThreads: 0, unresolvedCopilotThreads: 0, inMergeQueue: false, autoMergeEnabled: false
            )
        }
        var prs = [
            pr(14, repo: "sample/workspace", title: "Add review effort settings"),
            pr(27, repo: "sample/api", title: "Accept review effort", review: .approved, mergeState: .clean),
            pr(35, repo: "sample/agents", title: "Remove retired feature flags", checks: .pending),
            pr(18, repo: "sample/automation", title: "Refresh the target base before publishing", mergeState: .dirty, draft: true),
            pr(46, repo: "sample/mobile", title: "Keep the selected conversation visible", review: .approved),
        ]
        prs[4].isIncomplete = true
        let links: [PullRequestKey: String] = [prs[0].key: "s1", prs[1].key: "s1", prs[2].key: "s2"]
        let resume = ResumableSession(copilotSessionId: UUID().uuidString, name: "Fix base refresh when publishing",
                                     cwd: "/tmp", lastActive: now.addingTimeInterval(-2 * 86_400))
        for (name, appearance, width, offline) in [
            ("mac-dark", NSAppearance.Name.darkAqua, 1280.0, false),
            ("mac-light", .aqua, 1280.0, false),
            ("mac-compact", .darkAqua, 880.0, false),
            ("mac-offline", .aqua, 880.0, true),
        ] {
            let defaults = UserDefaults(suiteName: "pr-design-\(UUID().uuidString)")!
            let workspace = FakeWorkspace(snapshot: snapshot)
            let model = PullRequestsModel(
                workspace: workspace, defaults: defaults, stateDirectory: nil,
                loadAccounts: { throw PullRequestFetchError.notSignedIn }, resumableFinder: NoHistoricalSessions(),
                isVisible: { false }, presentError: { _, _ in XCTFail("Capture must not perform an action") }
            )
            await model.pollWorkspace()
            if offline { workspace.answer(fetches: [.unreachable]); await model.pollWorkspace() }
            model.show(prs, links: links, resumable: [prs[3].key: resume], updated: now.addingTimeInterval(-120),
                       warning: offline ? "GitHub refresh failed. Showing the last successful results." : nil)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: PullRequestsView(pullRequests: model))
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            window.orderFrontRegardless()
            for _ in 0..<15 {
                try await Task.sleep(nanoseconds: 50_000_000)
                host.layoutSubtreeIfNeeded()
            }
            let view = window.contentView?.superview ?? host
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: directory.appendingPathComponent("\(name).png"))
            window.close()
        }
    }
}
