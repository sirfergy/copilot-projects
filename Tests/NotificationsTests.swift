import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsPullRequests

/// GitHub's notifications API, answered from memory.
final class FakeGitHub: @unchecked Sendable {
    private let lock = NSLock()
    private var passes: [String: [[[String: Any]]]] = [:]
    private var _actions: [String] = []
    private var failing: Set<String> = []
    private var unchanged = false
    private var revoked: Set<String> = []

    /// Pages for one pass: `participating`, `unread`, or `read`.
    func answer(_ pass: String, pages: [[[String: Any]]]) { lock.withLock { passes[pass] = pages } }
    func fail(_ method: String) { lock.withLock { _ = failing.insert(method) } }
    func succeed() { lock.withLock { failing = [] } }
    func reportUnchanged(_ value: Bool) { lock.withLock { unchanged = value } }
    /// Answers 401 to reads made with `token`.
    func revoke(_ token: String) { lock.withLock { _ = revoked.insert(token) } }
    func restore(_ token: String) { lock.withLock { _ = revoked.remove(token) } }
    private var _bodies: [String: String] = [:]
    var bodies: [String: String] { lock.withLock { _bodies } }
    private var current: [String: [String: Any]] = [:]
    /// What `GET /notifications/threads/{id}` answers, when it differs from the listed copy.
    func setCurrent(_ thread: [String: Any]) { lock.withLock { current[thread["id"] as! String] = thread } }
    private var holding: Set<String> = []
    private var held: [String: CheckedContinuation<Void, Never>] = [:]
    /// Holds the next `GET /notifications/threads/{id}` until `release(id)`.
    func holdNextRead(_ id: String) { lock.withLock { _ = holding.insert(id) } }
    func isHolding(_ id: String) -> Bool { lock.withLock { held[id] != nil } }
    func release(_ id: String) { lock.withLock { held.removeValue(forKey: id) }?.resume() }
    private var holdingActions: Set<String> = []
    /// Holds the next non-GET request to `/notifications/threads/{id}` until `release(id)`.
    func holdNextAction(_ id: String) { lock.withLock { _ = holdingActions.insert(id) } }
    var actions: [String] { lock.withLock { _actions } }

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
        let method = request.httpMethod ?? "GET"
        func reply(_ status: Int, _ body: Data = Data("[]".utf8), headers: [String: String] = [:]) -> (Data, URLResponse) {
            (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
        }
        if method != "GET" {
            let id = url.lastPathComponent
            if lock.withLock({ holdingActions.remove(id) != nil }) {
                await withCheckedContinuation { continuation in lock.withLock { held[id] = continuation } }
            }
            return lock.withLock {
                _actions.append("\(method) \(url.path)")
                if let body = request.httpBody { _bodies["\(method) \(url.path)"] = String(decoding: body, as: UTF8.self) }
                if failing.contains(method) { return reply(500, Data(#"{"message":"boom"}"#.utf8)) }
                return reply(method == "PATCH" ? 205 : 204, Data())
            }
        }
        let token = request.value(forHTTPHeaderField: "Authorization")?.replacingOccurrences(of: "Bearer ", with: "") ?? ""
        if lock.withLock({ revoked.contains(token) }) { return reply(401, Data(#"{"message":"Bad credentials"}"#.utf8)) }
        let modified = ["Last-Modified": "Tue, 13 Oct 2026 22:52:51 GMT"]
        if url.path.hasPrefix("/notifications/threads/") {
            let id = url.lastPathComponent
            if lock.withLock({ holding.remove(id) != nil }) {
                await withCheckedContinuation { continuation in lock.withLock { held[id] = continuation } }
            }
            let thread: [String: Any]? = lock.withLock {
                current[id] ?? passes.values.flatMap { $0.flatMap { $0 } }.first { $0["id"] as? String == id }
            }
            guard let thread else { return reply(404, Data(#"{"message":"Not Found"}"#.utf8)) }
            return reply(200, try JSONSerialization.data(withJSONObject: thread))
        }
        if query["per_page"] == "1" {
            let stale = lock.withLock { unchanged }
            if request.value(forHTTPHeaderField: "If-Modified-Since") != nil, stale { return reply(304, Data()) }
            return reply(200, headers: modified)
        }
        let pass = query["participating"] == "true" ? "participating" : query["all"] == "true" ? "read" : "unread"
        let page = Int(query["page"] ?? "1") ?? 1
        let pages = lock.withLock { passes[pass] ?? [] }
        let threads = page <= pages.count ? pages[page - 1] : []
        var headers = modified
        if page < pages.count {
            var next = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            next.queryItems = (next.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(page + 1)")]
            var last = next
            last.queryItems = (last.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(pages.count)")]
            headers["Link"] = "<\(next.url!.absoluteString)>; rel=\"next\", <\(last.url!.absoluteString)>; rel=\"last\""
        }
        return reply(200, try JSONSerialization.data(withJSONObject: threads), headers: headers)
    }

    static func thread(
        _ id: String, reason: String, type: String = "PullRequest", repo: String = "octo/app", number: Int? = 1,
        unread: Bool = true, updated: Date, title: String = "A thread"
    ) -> [String: Any] {
        let collection = type == "Issue" ? "issues" : "pulls"
        var subject: [String: Any] = ["title": title, "type": type]
        subject["url"] = number.map { "https://api.github.com/repos/\(repo)/\(collection)/\($0)" } ?? NSNull()
        return [
            "id": id, "unread": unread, "reason": reason,
            "updated_at": ISO8601DateFormatter().string(from: updated),
            "subject": subject, "repository": ["full_name": repo],
        ]
    }
}

@MainActor
final class FakeBanners: NotificationBannerPosting {
    var posted: [[NotificationBanner]] = []
    func post(_ banners: [NotificationBanner]) { posted.append(banners) }
}

final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

@MainActor
final class NotificationsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_900_000)

    private func thread(
        _ id: String, _ reason: String, kind: NotificationSubjectKind = .pullRequest, unread: Bool = true,
        minutesAgo: Double = 10, account: String = "octocat", repo: String = "octo/app", number: Int? = 1
    ) -> NotificationThread {
        NotificationThread(
            key: .init(account: account, id: id), unread: unread, reason: NotificationReason(reason),
            updatedAt: now.addingTimeInterval(-minutesAgo * 60), title: "Thread \(id)", kind: kind,
            repository: repo, subjectAPIURL: number.map { URL(string: "https://api.github.com/repos/\(repo)/pulls/\($0)")! },
            number: number
        )
    }

    private func makeModel(
        _ github: FakeGitHub, clock: TestClock, defaults: UserDefaults? = nil,
        workspace: PullRequestsWorkspace = FakeWorkspace(), opened: ((URL) -> Void)? = nil,
        plan: NotificationsFetchPlan = NotificationsFetchPlan(), login: String = "octocat"
    ) -> NotificationsModel {
        let model = NotificationsModel(
            workspace: workspace, defaults: defaults ?? UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send), plan: plan,
            // Nothing listens there: details fail fast without leaving the machine.
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: login, token: "token")] },
            transcriptPath: { _ in nil },
            clock: { clock.now },
            openURL: opened ?? { _ in },
            isVisible: { false }
        )
        model.setBadge = { _ in }
        return model
    }

    // MARK: Decoding

    func testDecodesThreadsAndTheNextPage() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            FakeGitHub.thread("1", reason: "review_requested", repo: "Octo/App", number: 42, updated: now, title: "Add lanes"),
            FakeGitHub.thread("2", reason: "ci_activity", type: "CheckSuite", number: nil, unread: false, updated: now),
        ])
        let threads = try GitHubNotificationsAPI.decode(json, account: "octocat")
        XCTAssertEqual(threads.map(\.key.id), ["1", "2"])
        XCTAssertEqual(threads[0].reason, .reviewRequested)
        XCTAssertEqual(threads[0].pullRequestKey?.description, "octo/app#42")
        XCTAssertEqual(threads[0].shortName, "App#42")
        XCTAssertEqual(threads[0].webURL.absoluteString, "https://github.com/Octo/App/pull/42")
        XCTAssertEqual(threads[1].kind, .checkSuite)
        XCTAssertNil(threads[1].number)
        XCTAssertEqual(threads[1].webURL.absoluteString, "https://github.com/octo/app/actions")
        XCTAssertFalse(threads[1].unread)

        XCTAssertEqual(
            GitHubNotificationsAPI.nextLink(#"<https://api.github.com/notifications?page=2>; rel="next", <https://api.github.com/notifications?page=9>; rel="last""#)?.absoluteString,
            "https://api.github.com/notifications?page=2"
        )
        XCTAssertNil(GitHubNotificationsAPI.nextLink(#"<https://api.github.com/notifications?page=9>; rel="last""#))
    }

    func testWebURLsForEachSubject() {
        func web(_ path: String?, _ kind: NotificationSubjectKind) -> String {
            NotificationThread.webURL(apiURL: path.map { URL(string: "https://api.github.com\($0)")! }, repository: "o/r", kind: kind).absoluteString
        }
        XCTAssertEqual(web("/repos/o/r/issues/7", .issue), "https://github.com/o/r/issues/7")
        XCTAssertEqual(web("/repos/o/r/commits/abc123", .commit), "https://github.com/o/r/commit/abc123")
        XCTAssertEqual(web("/repos/o/r/releases/991", .release), "https://github.com/o/r/releases")
        XCTAssertEqual(web(nil, .discussion), "https://github.com/o/r/discussions")
        XCTAssertEqual(web(nil, .securityAlert), "https://github.com/o/r/security")
        XCTAssertEqual(NotificationThread.number(apiURL: URL(string: "https://api.github.com/repos/o/r/issues/12")), 12)
        XCTAssertNil(NotificationThread.number(apiURL: URL(string: "https://api.github.com/repos/o/r/releases/12")))
    }

    // MARK: Lanes

    func testReviewRequestsAreYoursUntilHistoryShowsOnlyATeam() {
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: nil), .reviewRequested)
        var direct = NotificationSubjectDetail()
        direct.viewerRequested = true
        direct.requestedTeams = ["octo/reviewers"]
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: direct), .reviewRequested)
        var team = NotificationSubjectDetail()
        team.requestedTeams = ["octo/reviewers", "octo/owners"]
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: team), .teamReviewRequested)
        // No request in the history at all stays with the user.
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: NotificationSubjectDetail()), .reviewRequested)

        let unknown = NotificationItem(thread: thread("1", "review_requested"), detail: nil, detailsSettled: false)
        XCTAssertTrue(unknown.isClassifying)
        XCTAssertEqual(unknown.detailParts(showsAccount: false), ["Checking who was asked…"])
        let unanswered = NotificationItem(thread: thread("1", "review_requested"), detail: nil, detailsSettled: true)
        XCTAssertFalse(unanswered.isClassifying)
        XCTAssertEqual(unanswered.detailParts(showsAccount: false), ["Couldn’t check who was asked"])

        team.viewerTeam = "octo/owners"
        team.state = .merged
        let item = NotificationItem(thread: thread("2", "review_requested", account: "hubot"), detail: team, detailsSettled: true)
        XCTAssertEqual(item.lane.band, .viaTeams)
        XCTAssertEqual(item.detailParts(showsAccount: true), ["@octo/owners", "Merged", "as hubot"])
    }

    func testOnlyReviewRequestsSettleWhenTheirPullRequestCloses() {
        var merged = NotificationSubjectDetail()
        merged.state = .merged
        let mention = NotificationItem(thread: thread("m", "mention"), detail: merged, detailsSettled: true)
        XCTAssertTrue(mention.needsYou, "a new mention on a merged pull request can still need an answer")
        let assigned = NotificationItem(thread: thread("a", "assign", kind: .issue), detail: merged, detailsSettled: true)
        XCTAssertTrue(assigned.needsYou)
        let review = NotificationItem(thread: thread("r", "review_requested"), detail: merged, detailsSettled: true)
        XCTAssertFalse(review.needsYou)
    }

    func testAnIncompleteRequestHistoryIsNotProofOfATeamRequest() throws {
        let json = """
        {"state":"OPEN","timelineItems":{"pageInfo":{"hasPreviousPage":true},"nodes":[
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}}
        ]}}
        """
        let subject = try JSONDecoder().decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
        let detail = NotificationDetailsFetcher.detail(subject, viewer: "octocat")
        XCTAssertFalse(detail.requestHistoryComplete)
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: detail), .reviewRequested,
                       "a direct request may be among the older events")
        let complete = try JSONDecoder().decode(
            NotificationDetailsFetcher.Subject.self, from: Data(json.replacingOccurrences(of: "true", with: "false").utf8)
        )
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: NotificationDetailsFetcher.detail(complete, viewer: "octocat")),
                       .teamReviewRequested)
    }

    func testEveryReasonHasALaneAndBand() {
        let expected: [(String, NotificationLane, NotificationBand)] = [
            ("mention", .mentioned, .toYou), ("assign", .assigned, .toYou), ("author", .yourWork, .toYou),
            ("comment", .conversations, .toYou), ("state_change", .conversations, .toYou),
            ("approval_requested", .reviewRequested, .toYou), ("team_mention", .teamMentioned, .viaTeams),
            ("subscribed", .watchedRepositories, .watching), ("manual", .subscribedThreads, .watching),
            ("ci_activity", .ciActivity, .quiet), ("security_alert", .other, .quiet), ("something_new", .other, .quiet),
        ]
        for (reason, lane, band) in expected {
            let result = NotificationItem.lane(for: NotificationReason(reason), detail: nil)
            XCTAssertEqual(result, lane, reason)
            XCTAssertEqual(result.band, band, reason)
        }
    }

    func testFreshnessIsMeasuredFromTheLastLook() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 10, day: 13, hour: 12))!
        let looked = noon.addingTimeInterval(-3600)
        func column(_ hoursAgo: Double, unread: Bool, looked: Date? = looked) -> NotificationFreshness {
            .of(updatedAt: noon.addingTimeInterval(-hoursAgo * 3600), unread: unread, lookedAt: looked, now: noon, calendar: calendar)
        }
        XCTAssertEqual(column(0.5, unread: true), .sinceYouLooked)
        XCTAssertEqual(column(0.5, unread: false), .today, "read since the look is no longer new")
        XCTAssertEqual(column(2, unread: true), .today, "unread but already seen")
        XCTAssertEqual(column(14, unread: true), .thisWeek, "yesterday")
        XCTAssertEqual(column(6 * 24, unread: false), .thisWeek)
        XCTAssertEqual(column(8 * 24, unread: true), .older)
        XCTAssertEqual(column(8 * 24, unread: true, looked: nil), .sinceYouLooked, "never looked: every unread thread is new")
    }

    func testLayoutKeepsBandOrderAndLeadsWithUnread() {
        let items = [
            thread("ci", "ci_activity", kind: .checkSuite, minutesAgo: 1),
            thread("old", "mention", unread: false, minutesAgo: 1),
            thread("new", "mention", minutesAgo: 30),
            thread("team", "team_mention"),
            thread("watch", "subscribed"),
        ].map { NotificationItem(thread: $0, detail: nil, detailsSettled: true) }
        let layout = NotificationLayout(items: items)
        XCTAssertEqual(layout.bands.map(\.band), [.toYou, .viaTeams, .watching, .quiet])
        XCTAssertEqual(layout.bands[0].lanes[0].items.map(\.thread.key.id), ["new", "old"])
        let counts = NotificationCounts(items: items)
        XCTAssertEqual([counts.toYou, counts.viaTeams, counts.watching, counts.quiet, counts.needsYou], [1, 1, 1, 1, 3])
        XCTAssertEqual(counts.badgeLabel, "3")
        var many = counts
        many.toYou = 2_000
        XCTAssertEqual(many.badgeLabel, "999+")
        XCTAssertNil(NotificationCounts(items: []).badgeLabel)

        var merged = NotificationSubjectDetail()
        merged.state = .merged
        var draft = NotificationSubjectDetail()
        draft.state = .draft
        let review = [
            NotificationItem(thread: thread("m", "review_requested"), detail: merged, detailsSettled: true),
            NotificationItem(thread: thread("d", "review_requested"), detail: draft, detailsSettled: true),
        ]
        XCTAssertFalse(review[0].needsYou, "a merged pull request has nothing left to review")
        XCTAssertTrue(review[1].needsYou)
        let settled = NotificationCounts(items: review)
        XCTAssertEqual([settled.toYou, settled.settled, settled.needsYou], [1, 1, 1])
    }

    // MARK: Details

    func testDetailsAreReadAFewSubjectsAtATime() {
        // Larger batches come back with some timelines silently empty, and an
        // empty history files a team's review request under To you.
        XCTAssertLessThanOrEqual(NotificationDetailsFetcher().batchSize, 5)
    }

    func testDetailsReadDirectAndTeamRequestsFromHistory() throws {
        let json = """
        {"state":"OPEN","isDraft":true,"headRefName":"octo/lanes","timelineItems":{"nodes":[
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}},
          {"requestedReviewer":{"__typename":"User","login":"OctoCat"}},
          {"requestedReviewer":{"__typename":"Team","slug":"owners","organization":{"login":"octo"}}},
          {"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}},
          {}
        ]}}
        """
        let subject = try JSONDecoder().decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
        let detail = NotificationDetailsFetcher.detail(subject, viewer: "octocat")
        XCTAssertEqual(detail.state, .draft)
        XCTAssertEqual(detail.headRefName, "octo/lanes")
        XCTAssertTrue(detail.viewerRequested)
        XCTAssertEqual(detail.requestedTeams, ["octo/reviewers", "octo/owners"], "most recent first, once each")

        let teamOnly = NotificationDetailsFetcher.detail(subject, viewer: "someone-else")
        XCTAssertFalse(teamOnly.viewerRequested)

        let issue = try JSONDecoder().decode(
            NotificationDetailsFetcher.Subject.self, from: Data(#"{"state":"CLOSED","stateReason":"NOT_PLANNED"}"#.utf8)
        )
        XCTAssertEqual(NotificationDetailsFetcher.detail(issue, viewer: nil).state, .notPlanned)
    }

    // MARK: Fetching

    func testFetchPlanMergesPassesAndReportsWhatItLeftOut() async throws {
        let github = FakeGitHub()
        let shared = FakeGitHub.thread("1", reason: "mention", updated: now.addingTimeInterval(-600))
        let newer = FakeGitHub.thread("1", reason: "mention", updated: now)
        github.answer("participating", pages: [[shared]])
        github.answer("unread", pages: [[newer], [FakeGitHub.thread("2", reason: "ci_activity", updated: now)], [FakeGitHub.thread("3", reason: "ci_activity", updated: now)]])
        github.answer("read", pages: [[FakeGitHub.thread("4", reason: "author", unread: false, updated: now)]])
        var plan = NotificationsFetchPlan()
        plan.unreadPages = 2
        let result = try await plan.fetch(
            account: GitHubAccount(login: "octocat", token: "t"), api: GitHubNotificationsAPI(send: github.send), now: now
        )
        XCTAssertEqual(Set(result.threads.map(\.key.id)), ["1", "2", "4"])
        XCTAssertEqual(result.threads.first { $0.key.id == "1" }?.updatedAt, now, "the newest copy wins")
        XCTAssertTrue(result.truncated)
    }

    func testPageLinksOffTheAPIAreNotFollowedWithTheToken() async {
        final class Sent: @unchecked Sendable {
            var urls: [URL] = []
        }
        let sent = Sent()
        let api = GitHubNotificationsAPI(send: { request in
            sent.urls.append(request.url!)
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let account = GitHubAccount(login: "octocat", token: "secret")
        for link in ["https://evil.example/notifications?page=2", "http://api.github.com/notifications?page=2",
                     "https://api.github.com:8443/notifications?page=2"] {
            do {
                _ = try await api.list(account: account, url: URL(string: link)!)
                XCTFail("followed \(link)")
            } catch {}
        }
        XCTAssertTrue(sent.urls.isEmpty, "\(sent.urls)")
        _ = try? await api.list(account: account, url: URL(string: "https://API.github.com/notifications?page=2")!)
        XCTAssertEqual(sent.urls.count, 1, "the API's own links are still followed")
    }

    func testRefreshShowsThreadsAndPublishesCounts() async {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now),
            FakeGitHub.thread("2", reason: "team_mention", type: "Issue", number: 2, updated: now),
        ]])
        github.answer("unread", pages: [[FakeGitHub.thread("3", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now)]])
        let summary = FileManager.default.temporaryDirectory.appendingPathComponent("summary-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: summary) }
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            summaryURL: summary, api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "t")] }, transcriptPath: { _ in nil }, clock: { clock.now }
        )
        var badge: String?
        model.setBadge = { badge = $0 }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.threads.count, 3)
        XCTAssertEqual(badge, "2", "CI never counts")
        let written = NotificationsSummary.read(from: summary)
        XCTAssertEqual(written?.needsYou, 2)
        XCTAssertEqual(written?.toYou, 1)
        XCTAssertEqual(written?.viaTeams, 1)
    }

    func testFailureBeforeAnythingLoadedIsShownAndLaterOnesAreWarnings() async {
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            loadAccounts: { throw NotificationsFetchError.notSignedIn }, transcriptPath: { _ in nil }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .failed(.notSignedIn))
    }

    // MARK: Actions

    func testOpeningMarksReadAndDoneRemovesUntilSomethingNewHappens() async throws {
        let github = FakeGitHub()
        let first = FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)
        github.answer("participating", pages: [[first, FakeGitHub.thread("2", reason: "author", type: "Issue", number: 2, updated: now)]])
        let clock = TestClock(now)
        var opened: [URL] = []
        let model = makeModel(github, clock: clock, opened: { opened.append($0) })
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first { $0.id.id == "1" })
        model.open(item)
        XCTAssertEqual(opened.map(\.absoluteString), ["https://github.com/octo/app/issues/1"])
        XCTAssertEqual(model.threads.first { $0.key.id == "1" }?.unread, false, "read at once, before GitHub answers")

        model.markDone([try XCTUnwrap(model.items.first { $0.id.id == "2" })])
        XCTAssertFalse(model.threads.contains { $0.key.id == "2" })
        try await waitUntil { github.actions.count == 2 }
        XCTAssertEqual(Set(github.actions), ["PATCH /notifications/threads/1", "DELETE /notifications/threads/2"])

        // A refresh that read GitHub before it saw either change keeps both.
        await model.refreshNow()
        XCTAssertEqual(model.threads.first { $0.key.id == "1" }?.unread, false)
        XCTAssertFalse(model.threads.contains { $0.key.id == "2" })

        // New activity brings a done thread back, unread.
        github.answer("participating", pages: [[first, FakeGitHub.thread("2", reason: "author", type: "Issue", number: 2, updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(model.threads.first { $0.key.id == "2" }?.unread, true)
    }

    func testAFailedDoneComesBackWithAWarning() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        github.fail("DELETE")
        model.markDone(model.items)
        XCTAssertTrue(model.threads.isEmpty)
        try await waitUntil { !model.threads.isEmpty }
        XCTAssertTrue(model.warning?.contains("Couldn’t mark as done") == true, model.warning ?? "no warning")
    }

    func testReadCoversACopyDatedAheadOfThisClock() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(120))]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        model.markRead(model.items)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        // A refresh that read GitHub before it saw the read keeps it read.
        await model.refreshNow()
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testDoneCoversActivityUpToTheClickNotJustTheCopyOnScreen() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-600))]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        // Activity the window hasn't shown yet arrives before the click.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-300))]])
        model.markDone(model.items)
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        await model.refreshNow()
        XCTAssertTrue(model.threads.isEmpty, "the done covered it")

        // A copy dated ahead of this clock stays done too.
        github.answer("participating", pages: [[FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(120))]])
        await model.refreshNow()
        model.markDone(model.items)
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/2") }
        await model.refreshNow()
        XCTAssertTrue(model.threads.isEmpty)

        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(model.threads.map(\.key.id), ["1"], "activity after the click brings it back")
    }

    func testOneRevokedAccountDoesNotBlockActingForTheOthers() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)]])
        github.revoke("stale")
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "stale")] },
            transcriptPath: { _ in nil }, clock: { self.now }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.warning?.contains("hubot") == true, model.warning ?? "no warning")
        let item = try XCTUnwrap(model.items.first { $0.thread.account == "octocat" })
        model.markDone([item])
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.threads.contains { $0.key == item.id }, "the healthy account's done stuck")
        XCTAssertFalse(model.warning?.contains("no longer signed in") == true)
    }

    // MARK: Looking and banners

    private func sinceYouLooked(_ model: NotificationsModel) -> [String] {
        NotificationLayout(items: model.items).lanes
            .flatMap { $0.items(in: .sinceYouLooked, lookedAt: model.lookedAt, now: now) }
            .map(\.id.id).sorted()
    }

    func testLookingAtTheWindowMovesNothing() {
        let clock = TestClock(now)
        let model = makeModel(FakeGitHub(), clock: clock)
        model.show([thread("1", "mention"), thread("2", "mention", number: 2)], accounts: ["octocat"], lookedAt: now.addingTimeInterval(-3600))
        model.beganLooking()
        XCTAssertTrue(model.isLooking)
        clock.now += 60
        model.finishedLooking()
        XCTAssertFalse(model.isLooking)
        model.beganLooking()
        XCTAssertEqual(model.lookedAt, now.addingTimeInterval(-3600))
        XCTAssertEqual(sinceYouLooked(model), ["1", "2"], "only acting on a thread moves it")
    }

    func testActingOnAThreadMovesItOutOfSinceYouLookedUntilItChanges() {
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let clock = TestClock(now)
        let model = makeModel(FakeGitHub(), clock: clock, defaults: defaults)
        let first = thread("1", "mention", minutesAgo: 10)
        model.show([first, thread("2", "mention", number: 2)], accounts: ["octocat"], lookedAt: now.addingTimeInterval(-3600))
        model.noteActed([first])
        XCTAssertEqual(sinceYouLooked(model), ["2"])
        XCTAssertNotNil(NotificationLayout(items: model.items).lanes.flatMap { $0.items(in: .today, lookedAt: model.lookedAt, now: now) }.first { $0.id.id == "1" })

        // Remembered across launches.
        let restarted = makeModel(FakeGitHub(), clock: clock, defaults: defaults)
        restarted.show([first, thread("2", "mention", number: 2)], accounts: ["octocat"], lookedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(sinceYouLooked(restarted), ["2"])

        // Something new after the action brings it back.
        clock.now += 60
        restarted.show([thread("1", "mention", minutesAgo: -1), thread("2", "mention", number: 2)], accounts: ["octocat"], lookedAt: now.addingTimeInterval(-3600))
        XCTAssertEqual(sinceYouLooked(restarted), ["1", "2"])
    }

    func testAnActionHoldsPastAWeekWhileItsThreadHasNothingNew() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let clock = TestClock(now)
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-600)),
            FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-600)),
        ]])
        let model = makeModel(github, clock: clock, defaults: defaults)
        await model.refreshNow()
        // Copy Link leaves the thread unread.
        model.noteActed([try XCTUnwrap(model.threads.first { $0.key.id == "1" })])
        clock.now += 8 * 86_400

        // A week on, the next read forgets old actions, but not one still in use.
        await model.refreshNow()
        XCTAssertEqual(sinceYouLooked(model), ["2"])
        let older = NotificationLayout(items: model.items).lanes.flatMap { $0.items(in: .older, lookedAt: model.lookedAt, now: clock.now) }
        XCTAssertEqual(older.map(\.id.id), ["1"])

        // Nor does a relaunch.
        let restarted = makeModel(github, clock: clock, defaults: defaults)
        await restarted.refreshNow()
        XCTAssertEqual(sinceYouLooked(restarted), ["2"])
    }

    func testActionsOlderThanAWeekAreForgottenOnceNoThreadNeedsThem() async {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let old = now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970
        defaults.set(["octocat|1": old, "octocat|3": old, "octocat|4": old], forKey: NotificationsModel.actedAtKey)
        // 1 is gone; 3 hasn't changed since; 4 has.
        github.answer("participating", pages: [[
            FakeGitHub.thread("3", reason: "mention", type: "Issue", number: 3, updated: now.addingTimeInterval(-9 * 86_400)),
            FakeGitHub.thread("4", reason: "mention", type: "Issue", number: 4, updated: now.addingTimeInterval(-600)),
        ]])
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        XCTAssertEqual(model.actedAt.keys.map(\.id), ["3"])
        XCTAssertEqual((defaults.dictionary(forKey: NotificationsModel.actedAtKey) ?? [:]).keys.sorted(), ["octocat|3"])
        XCTAssertEqual(sinceYouLooked(model), ["4"])
    }

    func testAnAccountThatWasntReadKeepsItsOldActions() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let old = now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970
        defaults.set(["octocat|1": old, "hubot|1": old], forKey: NotificationsModel.actedAtKey)
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-9 * 86_400)),
            FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-600)),
        ]])
        github.revoke("flaky")
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: defaults,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "flaky")] },
            transcriptPath: { _ in nil }, clock: { self.now }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        // Acting while hubot's inbox couldn't be read doesn't forget what was done there.
        model.noteActed([try XCTUnwrap(model.threads.first { $0.key == .init(account: "octocat", id: "2") })])

        github.restore("flaky")
        await model.refreshNow()
        XCTAssertEqual(model.threads.filter { $0.key.account == "hubot" }.count, 2)
        XCTAssertEqual(sinceYouLooked(model), ["2"])
    }

    func testAnActionOutOfReachInALargeInboxHoldsPastAWeek() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let clock = TestClock(now)
        let acted = FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-600))
        let other = FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-600))
        github.answer("participating", pages: [[acted, other]])
        // One page per read: anything on a second page is out of reach.
        let model = makeModel(github, clock: clock, defaults: defaults, plan: NotificationsFetchPlan(participatingPages: 1))
        await model.refreshNow()
        // Copy Link leaves it unread.
        model.noteActed([try XCTUnwrap(model.threads.first { $0.key.id == "1" })])

        // Newer threads push it off the first page for over a week.
        clock.now += 8 * 86_400
        let newer = FakeGitHub.thread("3", reason: "mention", type: "Issue", number: 3, updated: clock.now.addingTimeInterval(-60))
        github.answer("participating", pages: [[newer, other], [acted]])
        await model.refreshNow()
        XCTAssertEqual(model.truncatedAccounts, ["octocat"])

        // Back in reach with nothing new: not new to you.
        github.answer("participating", pages: [[acted, other]])
        await model.refreshNow()
        XCTAssertFalse(sinceYouLooked(model).contains("1"))
    }

    func testActionsOutOfReachAreCappedPerAccountKeepingTheNewest() async {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let limit = NotificationsModel.actedOutOfReachLimit
        var stored: [String: Double] = ["octocat|recent": now.addingTimeInterval(-3600).timeIntervalSince1970]
        for index in 0..<(limit + 2) {
            stored["octocat|gone\(index)"] = now.addingTimeInterval(-8 * 86_400 - Double(index + 1) * 3600).timeIntervalSince1970
        }
        defaults.set(stored, forKey: NotificationsModel.actedAtKey)
        github.answer("participating", pages: [
            [FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-60))],
            [FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-120))],
        ])
        let model = makeModel(github, clock: TestClock(now), defaults: defaults, plan: NotificationsFetchPlan(participatingPages: 1))
        await model.refreshNow()
        XCTAssertEqual(model.actedAt.count, limit + 1)
        XCTAssertNotNil(model.actedAt[.init(account: "octocat", id: "recent")], "a week's actions are never capped")
        XCTAssertNotNil(model.actedAt[.init(account: "octocat", id: "gone0")])
        XCTAssertNil(model.actedAt[.init(account: "octocat", id: "gone\(limit)")], "the oldest go first")
        XCTAssertEqual((defaults.dictionary(forKey: NotificationsModel.actedAtKey) ?? [:]).count, limit + 1)
    }

    func testActionsAreRememberedForAnAccountWithoutALogin() {
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let baseline = now.addingTimeInterval(-3600)
        // An older gh names no account.
        let acted = thread("1", "mention", account: "")
        let first = makeModel(FakeGitHub(), clock: TestClock(now), defaults: defaults)
        first.show([acted], accounts: [""], lookedAt: baseline)
        first.noteActed([acted])

        let restarted = makeModel(FakeGitHub(), clock: TestClock(now), defaults: defaults)
        restarted.show([acted], accounts: [""], lookedAt: baseline)
        XCTAssertEqual(sinceYouLooked(restarted), [])
    }

    func testTheFirstLookStartsFromTheLastReadOnGitHub() async {
        let github = FakeGitHub()
        var read = FakeGitHub.thread("1", reason: "author", type: "Issue", unread: false, updated: now.addingTimeInterval(-7200))
        read["last_read_at"] = ISO8601DateFormatter().string(from: now.addingTimeInterval(-3600))
        github.answer("participating", pages: [[
            FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-1800)),
            FakeGitHub.thread("3", reason: "mention", type: "Issue", number: 3, updated: now.addingTimeInterval(-5400)),
        ]])
        github.answer("read", pages: [[read]])
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        let lastRead = now.addingTimeInterval(-3600)
        XCTAssertEqual(model.lookedAt, lastRead)
        XCTAssertEqual(defaults.double(forKey: NotificationsModel.lookedAtKey), lastRead.timeIntervalSince1970)
        let columns = Dictionary(uniqueKeysWithValues: model.items.map {
            ($0.id.id, NotificationFreshness.of(updatedAt: $0.thread.updatedAt, unread: $0.thread.unread, lookedAt: model.lookedAt, now: now))
        })
        XCTAssertEqual(columns["2"], .sinceYouLooked)
        XCTAssertNotEqual(columns["3"], .sinceYouLooked, "unread before the last read on GitHub was already there to see")

        // A real look is never replaced by the seed.
        model.beganLooking()
        await model.refreshNow()
        XCTAssertEqual(model.lookedAt, lastRead)
    }

    func testTheFirstLookHoldsWhenNothingWasReadOnGitHubYet() async throws {
        let github = FakeGitHub()
        let clock = TestClock(now)
        let older = FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now.addingTimeInterval(-5400))
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-1800)), older,
        ]])
        let model = makeModel(github, clock: clock)
        await model.refreshNow()
        XCTAssertEqual(sinceYouLooked(model), ["1", "2"])

        // Opening one reads it on GitHub; that read doesn't move the other.
        model.open(try XCTUnwrap(model.items.first { $0.id.id == "1" }))
        clock.now += 60
        var read = FakeGitHub.thread("1", reason: "mention", type: "Issue", unread: false, updated: now.addingTimeInterval(-1800))
        read["last_read_at"] = ISO8601DateFormatter().string(from: clock.now)
        github.answer("participating", pages: [[older]])
        github.answer("read", pages: [[read]])
        await model.refreshNow()
        XCTAssertEqual(sinceYouLooked(model), ["2"])
    }

    func testBannersAnnounceOnlyNewThreadsThatNeedYou() async {
        let github = FakeGitHub()
        let clock = TestClock(now)
        github.answer("participating", pages: [[FakeGitHub.thread("old", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-60))]])
        let model = makeModel(github, clock: clock)
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()
        XCTAssertTrue(banners.posted.isEmpty, "the backlog waiting at first launch isn't announced")

        clock.now += 120
        github.answer("participating", pages: [[
            FakeGitHub.thread("old", reason: "mention", type: "Issue", updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("new", reason: "mention", type: "Issue", number: 5, updated: now.addingTimeInterval(60), title: "Composer loses focus"),
        ]])
        github.answer("unread", pages: [[FakeGitHub.thread("ci", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now.addingTimeInterval(60))]])
        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1)
        XCTAssertEqual(banners.posted[0].map(\.title), ["You were mentioned"])
        XCTAssertEqual(banners.posted[0].first?.subtitle, "app#5")
        XCTAssertEqual(banners.posted[0].first?.body, "Composer loses focus")

        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1, "each change is announced once")

        model.bannersToYou = false
        clock.now += 120
        github.answer("participating", pages: [[FakeGitHub.thread("later", reason: "mention", type: "Issue", updated: now.addingTimeInterval(200))]])
        await model.refreshNow()
        XCTAssertEqual(banners.posted.count, 1, "To you banners are off")
    }

    func testOneAccountsFailedRefreshDoesNotLoseItsBanners() async {
        let github = FakeGitHub()
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "flaky")] },
            transcriptPath: { _ in nil }, clock: { clock.now }
        )
        model.setBadge = { _ in }
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()

        // hubot fails while octocat reads a newer thread; then hubot recovers
        // with an older mention that arrived while it was failing.
        clock.now += 300
        github.revoke("flaky")
        github.answer("unread", pages: [[FakeGitHub.thread("ci", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now.addingTimeInterval(200))]])
        await model.refreshNow()
        github.restore("flaky")
        github.answer("unread", pages: [])
        github.answer("participating", pages: [[FakeGitHub.thread("m", reason: "mention", type: "Issue", updated: now.addingTimeInterval(100))]])
        clock.now += 300
        await model.refreshNow()
        let titles = banners.posted.flatMap { $0 }.map(\.title)
        XCTAssertTrue(titles.contains("You were mentioned"), "\(titles)")
    }

    func testOneAccountsFailedRefreshKeepsItsTruncationCaveat() async {
        let github = FakeGitHub()
        let ci: (String) -> [[String: Any]] = { [now] id in
            [FakeGitHub.thread(id, reason: "ci_activity", type: "CheckSuite", number: nil, updated: now)]
        }
        github.answer("unread", pages: [ci("1"), ci("2")])
        var plan = NotificationsFetchPlan()
        plan.unreadPages = 1
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send), plan: plan,
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "good"), GitHubAccount(login: "hubot", token: "flaky")] },
            transcriptPath: { _ in nil }, clock: { self.now }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.truncatedAccounts, ["octocat", "hubot"])

        // hubot fails while octocat's inbox now fits in what one refresh reads.
        github.revoke("flaky")
        github.answer("unread", pages: [ci("1")])
        await model.refreshNow()
        XCTAssertEqual(model.truncatedAccounts, ["hubot"], "hubot's older threads are still unseen")

        github.restore("flaky")
        await model.refreshNow()
        XCTAssertTrue(model.truncatedAccounts.isEmpty)
    }

    func testGoingToTheLinkedSessionMarksTheThreadRead() async throws {
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "author", updated: now)]])
        let model = makeModel(github, clock: TestClock(now), workspace: FakeWorkspace(snapshot: snapshot))
        // Your own pull requests are where sessions most often work.
        model.hidesYourPullRequests = false
        await model.pollWorkspace()
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first)
        let session = try XCTUnwrap(item.session)
        model.goToSession(session, for: item)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testGoingToASessionThatMovedProjectsShowsItWhereItIsNow() async throws {
        func snapshot(in project: String) -> WorkspaceSnapshot {
            WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: project, projects: [
                .init(id: project, name: "Workspace", sessions: [
                    .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#1"]),
                ]),
            ])
        }
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "author", updated: now)]])
        let workspace = FakeWorkspace(snapshot: snapshot(in: "p"))
        let model = makeModel(github, clock: TestClock(now), workspace: workspace)
        // Your own pull requests are where sessions most often work.
        model.hidesYourPullRequests = false
        await model.pollWorkspace()
        await model.refreshNow()
        let item = try XCTUnwrap(model.items.first)
        let session = try XCTUnwrap(item.session)
        workspace.answer(
            fetches: [.snapshot(snapshot(in: "q"))],
            reveals: [.refused(code: "conflict", message: "moved"), .done(code: "revealed", text: nil)]
        )
        model.goToSession(session, for: item)
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/1") }
        XCTAssertEqual(workspace.revealCalls.map(\.projectId), ["p", "q"])
        XCTAssertEqual(model.threads.first?.unread, false)
    }

    func testAStaleSessionMatchDoesNotOverwriteANewerOne() async throws {
        actor HeldTranscripts: PullRequestTranscriptReading {
            private var first: CheckedContinuation<Void, Never>?
            private var holding = true
            private(set) var reads = 0
            func evidence(
                for sources: [PullRequestTranscriptIndex.Source], branches: Set<String>
            ) async -> [String: TranscriptEvidence] {
                reads += 1
                if reads == 1, holding { await withCheckedContinuation { first = $0 } }
                return [:]
            }
            func release() {
                holding = false
                first?.resume()
                first = nil
            }
        }
        func snapshot(linking session: String) -> WorkspaceSnapshot {
            WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
                .init(id: "p", name: "Workspace", sessions: ["s1", "s2"].map {
                    .init(id: $0, title: $0, status: .waiting, copilotSessionId: "copilot-\($0)",
                          pullRequestKeys: $0 == session ? ["octo/app#1"] : [])
                }),
            ])
        }
        let transcripts = HeldTranscripts()
        let workspace = FakeWorkspace(snapshot: snapshot(linking: "s1"))
        let model = NotificationsModel(
            workspace: workspace, defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            loadAccounts: { [] }, transcripts: transcripts, transcriptPath: { "/nonexistent/\($0).jsonl" }
        )
        model.setBadge = { _ in }
        model.show([thread("1", "author")], accounts: ["octocat"])
        let stale = Task { await model.pollWorkspace() }
        var reads = 0
        for _ in 0..<250 where reads == 0 {
            try await Task.sleep(nanoseconds: 20_000_000)
            reads = await transcripts.reads
        }
        XCTAssertEqual(reads, 1)

        // The session working on it changes while the first match reads transcripts.
        workspace.answer(fetches: [.snapshot(snapshot(linking: "s2"))])
        await model.pollWorkspace()
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s2")
        await transcripts.release()
        await stale.value
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s2", "the older match's links were dropped")
    }

    func testABannerForAThreadNotLoadedStillMarksItRead() async throws {
        let github = FakeGitHub()
        var opened: [URL] = []
        let model = makeModel(github, clock: TestClock(now), opened: { opened.append($0) })
        let url = URL(string: "https://github.com/octo/app/issues/9")!
        model.openBanner(thread: .init(account: "octocat", id: "99"), url: url)
        XCTAssertEqual(opened, [url])
        try await waitUntil { github.actions.contains("PATCH /notifications/threads/99") }
    }

    func testUnsubscribeIgnoresTheThreadAndClearsIt() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "subscribed", type: "Issue", updated: now)]])
        let model = makeModel(github, clock: TestClock(now))
        await model.refreshNow()
        model.unsubscribe(try XCTUnwrap(model.items.first))
        try await waitUntil { github.actions.count == 2 }
        XCTAssertEqual(github.actions, ["PUT /notifications/threads/1/subscription", "DELETE /notifications/threads/1"])
        XCTAssertEqual(github.bodies["PUT /notifications/threads/1/subscription"], #"{"ignored":true}"#)
    }

    func testManyNewThreadsBecomeOneSummaryBanner() {
        let items = (0..<5).map { index in
            NotificationItem(thread: thread("\(index)", index < 2 ? "mention" : "team_mention"), detail: nil, detailsSettled: true)
        }
        let banners = NotificationsModel.banners(for: items)
        XCTAssertEqual(banners.count, 1)
        XCTAssertEqual(banners[0].title, "5 new notifications need you")
        XCTAssertEqual(banners[0].body, "2 to you · 3 via your teams")
        XCTAssertNil(banners[0].url)

        var team = NotificationSubjectDetail()
        team.requestedTeams = ["octo/reviewers"]
        let request = NotificationItem(thread: thread("r", "review_requested"), detail: team, detailsSettled: true)
        XCTAssertEqual(NotificationsModel.banner(request).title, "@octo/reviewers was asked to review")
    }

    // MARK: Sessions

    func testPullRequestThreadsLinkToTheSessionWorkingOnThem() async {
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Ship lanes", status: .waiting, pullRequestKeys: ["octo/app#7"]),
            ]),
        ])
        let model = makeModel(FakeGitHub(), clock: TestClock(now), workspace: FakeWorkspace(snapshot: snapshot))
        // Your own pull requests are where sessions most often work.
        model.hidesYourPullRequests = false
        model.show([thread("1", "author", number: 7), thread("2", "author", number: 8)], accounts: ["octocat"])
        await model.pollWorkspace()
        await model.matchSessions()
        XCTAssertEqual(model.items.first { $0.id.id == "1" }?.session?.id, "s1")
        XCTAssertNil(model.items.first { $0.id.id == "2" }?.session)
    }

    // MARK: Answered

    /// A pull request's history as GitHub returns it to the Engaged fragment.
    private func subject(
        _ events: String, reviews: String = "", body: String? = nil, activityTruncated: Bool = false
    ) throws -> NotificationDetailsFetcher.Subject {
        var json = #"{"state":"OPEN","createdAt":"2026-10-14T09:00:00Z","author":{"login":"author"},"#
        if let body { json += #""body":"\#(body)","# }
        json += #""prActivity":{"pageInfo":{"hasPreviousPage":\#(activityTruncated)},"nodes":["# + events + "]},"
        json += #""reviews":{"pageInfo":{"hasPreviousPage":false},"nodes":["# + reviews + "]}}"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(NotificationDetailsFetcher.Subject.self, from: Data(json.utf8))
    }

    private func answered(_ subject: NotificationDetailsFetcher.Subject, onTeam: (String) -> Bool? = { _ in nil }) -> Bool {
        NotificationDetailsFetcher.detail(subject, viewer: "octocat").isAnswered(onTeam: onTeam)
    }

    func testAThreadIsAnsweredWhenYouActedAfterTheLastAskOfYou() throws {
        // entitlements#143685: asked and mentioned, then approved; others approving later don't ask again.
        let asked = try subject("""
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T16:47:22Z","requestedReviewer":{"__typename":"User","login":"OctoCat"}},
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:30Z","actor":{"login":"octocat"}},
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:31Z","actor":{"login":"hubot"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T19:05:04Z","body":"LGTM, thanks @hubot","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T17:16:46Z","state":"APPROVED","author":{"login":"octocat"}},
        {"submittedAt":"2026-10-14T19:04:43Z","state":"APPROVED","body":"","author":{"login":"hubot"}}
        """)
        let detail = NotificationDetailsFetcher.detail(asked, viewer: "octocat")
        XCTAssertNotNil(detail.viewerTargetedAt)
        XCTAssertNotNil(detail.viewerActedAt)
        XCTAssertTrue(detail.isAnswered { _ in nil })

        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T16:47:30Z","actor":{"login":"octocat"}},
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T18:00:00Z","requestedReviewer":{"__typename":"User","login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T17:16:46Z","state":"APPROVED","author":{"login":"octocat"}}
        """)), "re-requested")

        XCTAssertTrue(answered(try subject("""
        {"__typename":"AssignedEvent","createdAt":"2026-10-14T10:00:00Z","assignee":{"login":"octocat"}},
        {"__typename":"ClosedEvent","createdAt":"2026-10-14T11:00:00Z","actor":{"login":"octocat"}}
        """)), "closed after being assigned")

        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"PENDING","author":{"login":"octocat"}}
        """)), "a draft review isn't an answer")

        XCTAssertFalse(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"on it","author":{"login":"octocat"}}
        """)), "with nothing aimed at you in the history, it can't be called answered")
    }

    func testAMentionInsideAReviewOrReviewCommentAsksAgain() throws {
        // GitHub records no mention event for these, so the text is what counts.
        let before = """
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"Looking now","author":{"login":"octocat"}}
        """
        XCTAssertTrue(answered(try subject(before)))
        XCTAssertFalse(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"COMMENTED","body":"@OctoCat fixed in the latest push, PTAL","author":{"login":"hubot"}}
        """)), "mentioned in a review body")
        XCTAssertFalse(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"COMMENTED","body":"","author":{"login":"hubot"},
         "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"createdAt":"2026-10-14T12:00:00Z","body":"what do you think, @octocat?","author":{"login":"hubot"}}]}}
        """)), "mentioned in an inline reply")
        XCTAssertFalse(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"COMMENTED","body":"","author":{"login":"hubot"},
         "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"createdAt":"2026-10-14T10:30:00Z","body":"what do you think, @octocat?","author":{"login":"hubot"}}]}}
        """)), "drafted before you answered, but sent after")
        XCTAssertFalse(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T09:30:00Z","lastEditedAt":"2026-10-14T12:00:00Z","body":"cc @octocat","author":{"login":"hubot"}},
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"done","author":{"login":"octocat"}}
        """)), "edited to mention you after you answered")
        XCTAssertTrue(answered(try subject(before, reviews: """
        {"submittedAt":"2026-10-14T12:00:00Z","state":"APPROVED","body":"thanks octocat@example.com and @octocats","author":{"login":"hubot"}}
        """)), "an email address or a longer login isn't a mention of you")
    }

    func testAnInlineReplyCountsAsAnswering() throws {
        // A reply made inline is a review with no body, which the timeline leaves out.
        XCTAssertTrue(answered(try subject("""
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"COMMENTED","body":"","author":{"login":"octocat"},
         "comments":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"createdAt":"2026-10-14T11:00:00Z","body":"good catch","author":{"login":"octocat"}}]}}
        """)))
    }

    func testTeamMentionsAndRequestsCountOnlyForYourTeams() throws {
        let teamMentioned = """
        {"__typename":"IssueComment","createdAt":"2026-10-14T10:00:00Z","body":"@Octo/Reviewers can someone look?","author":{"login":"hubot"}}
        """
        let replied = """
        {"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"taking it","author":{"login":"octocat"}}
        """
        XCTAssertEqual(NotificationDetailsFetcher.detail(try subject(teamMentioned), viewer: "octocat").teamTargetedAt.keys.sorted(), ["octo/reviewers"])
        XCTAssertTrue(answered(try subject(teamMentioned + "," + replied)), "a team mention you replied to")
        XCTAssertFalse(answered(try subject(replied + "," + teamMentioned.replacingOccurrences(of: "10:00", with: "12:00"))),
                       "your team mentioned again after you replied")
        let requested = replied.replacingOccurrences(of: "taking it", with: "@octocat-bot ping") + "," + """
        {"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},
        {"__typename":"ReviewRequestedEvent","createdAt":"2026-10-14T12:00:00Z","requestedReviewer":{"__typename":"Team","slug":"Reviewers","organization":{"login":"Octo"}}}
        """
        XCTAssertFalse(answered(try subject(requested)) , "unknown membership counts as yours")
        XCTAssertFalse(answered(try subject(requested), onTeam: { _ in true }), "your team was asked after you replied")
        XCTAssertTrue(answered(try subject(requested), onTeam: { _ in false }), "another team's request doesn't ask you")
    }

    func testACutShortHistoryNeverHidesWhatCameAfterYou() throws {
        // Only the newest events came back, and they start after your reply: what's between is unknown.
        XCTAssertFalse(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T12:00:00Z","body":"+1","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"APPROVED","author":{"login":"octocat"}}
        """, body: "@octocat please review", activityTruncated: true)))
        XCTAssertTrue(answered(try subject("""
        {"__typename":"IssueComment","createdAt":"2026-10-14T10:30:00Z","body":"+1","author":{"login":"hubot"}}
        """, reviews: """
        {"submittedAt":"2026-10-14T11:00:00Z","state":"APPROVED","author":{"login":"octocat"}}
        """, body: "@octocat please review", activityTruncated: true)), "the shown stretch reaches back past your answer")
    }

    func testMentionsAreReadLikeGitHubReadsThem() {
        let found = NotificationDetailsFetcher.mentions(in: "Hey @Octocat and @github/Copilot-Reviewers, see a@b.com, `@code`, @-dash, end @hubot.")
        XCTAssertEqual(found.users, ["octocat", "hubot"])
        XCTAssertEqual(found.teams, ["github/copilot-reviewers"])
    }

    func testASubjectGitHubErredInsideIsNeverAnswered() async {
        URLProtocol.registerClass(GraphQLStub.self)
        defer { URLProtocol.unregisterClass(GraphQLStub.self); GraphQLStub.respond = { _, _ in (500, "") } }
        let fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint))
        let threads = [thread("1", "mention", number: 1), thread("2", "mention", number: 2)]
        let subject = #"{"issueOrPullRequest":{"state":"OPEN","createdAt":"2026-10-14T09:00:00Z","author":{"login":"author"},"prActivity":{"pageInfo":{"hasPreviousPage":false},"nodes":[{"__typename":"MentionedEvent","createdAt":"2026-10-14T10:00:00Z","actor":{"login":"octocat"}},{"__typename":"IssueComment","createdAt":"2026-10-14T11:00:00Z","body":"done","author":{"login":"octocat"}}]}}}"#
        var erred: Set<String> = []
        func answered(errors: String) async -> [String: Bool] {
            GraphQLStub.respond = { _, _ in (200, #"{"data":{"viewer":{"login":"octocat"},"t0":\#(subject),"t1":\#(subject)}\#(errors)}"#) }
            let result = await fetcher.details(for: threads, account: GitHubAccount(login: "octocat", token: "token"))
            erred = Set(result.erred.map(\.id))
            return result.details.reduce(into: [:]) { $0[$1.key.id] = $1.value.isAnswered { _ in nil } }
        }
        let clean = await answered(errors: "")
        XCTAssertEqual(clean, ["1": true, "2": true])
        XCTAssertEqual(erred, [])
        let placed = await answered(errors: #","errors":[{"message":"timeout","path":["t1","issueOrPullRequest","reviews"]}]"#)
        XCTAssertEqual(placed, ["1": true, "2": false], "an error inside one subject may hide a later ask there")
        XCTAssertEqual(erred, ["2"], "and it's read again")
        let unplaced = await answered(errors: #","errors":[{"message":"Something went wrong"}]"#)
        XCTAssertEqual(unplaced, ["1": false, "2": false], "an error that can't be placed may be inside any of them")
        XCTAssertEqual(erred, ["1", "2"])
    }

    func testATeamListWithErrorsOrUnnamedTeamsIsNotWhole() async {
        URLProtocol.registerClass(GraphQLStub.self)
        defer { URLProtocol.unregisterClass(GraphQLStub.self); GraphQLStub.respond = { _, _ in (500, "") } }
        let fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint))
        func read(nodes: String, errors: String = "") async -> (teams: Set<String>, complete: Bool)? {
            GraphQLStub.respond = { _, _ in
                (200, #"{"data":{"organization":{"teams":{"pageInfo":{"hasNextPage":false},"nodes":[\#(nodes)]}}}\#(errors)}"#)
            }
            return await fetcher.viewerTeams(organization: "Octo", account: GitHubAccount(login: "octocat", token: "token"), login: "octocat")
        }
        let whole = await read(nodes: #"{"login":"Reviewers"}"#)
        XCTAssertEqual(whole?.teams, ["octo/reviewers"])
        XCTAssertEqual(whole?.complete, true)
        let unnamed = await read(nodes: #"{"login":"Reviewers"},null,{"login":null}"#)
        XCTAssertEqual(unnamed?.teams, ["octo/reviewers"], "the teams it could name are kept")
        XCTAssertEqual(unnamed?.complete, false)
        let erred = await read(nodes: #"{"login":"Reviewers"}"#, errors: #","errors":[{"message":"timeout","path":["organization","teams"]}]"#)
        XCTAssertEqual(erred?.complete, false)
    }

    func testPaginatesOlderReviewRequestEventsAndPendingReviewers() async {
        URLProtocol.registerClass(GraphQLStub.self)
        defer { URLProtocol.unregisterClass(GraphQLStub.self); GraphQLStub.respond = { _, _ in (500, "") } }
        let fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: GraphQLStub.endpoint))
        let threads = [
            thread("1", "review_requested", number: 1),
            thread("2", "review_requested", number: 2),
            thread("3", "review_requested", number: 3),
        ]
        let team = #"{"requestedReviewer":{"__typename":"Team","slug":"reviewers","organization":{"login":"octo"}}}"#
        let owners = #"{"requestedReviewer":{"__typename":"Team","slug":"owners","organization":{"login":"octo"}}}"#
        let direct = #"{"requestedReviewer":{"__typename":"User","login":"OctoCat"}}"#
        let other = #"{"requestedReviewer":{"__typename":"User","login":"hubot"}}"#
        let batchResponse = """
        {"data":{"viewer":{"login":"octocat"},
          "t0":{"issueOrPullRequest":{"state":"OPEN",
            "timelineItems":{"pageInfo":{"hasPreviousPage":true,"startCursor":"hist-1"},"nodes":[\(team)]},
            "pending":{"pageInfo":{"hasNextPage":true,"endCursor":"pend-1"},"nodes":[\(team)]}}},
          "t1":{"issueOrPullRequest":{"state":"OPEN",
            "timelineItems":{"pageInfo":{"hasPreviousPage":true,"startCursor":"hist-direct"},"nodes":[\(team)]},
            "pending":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[\(direct)]}}},
          "t2":{"issueOrPullRequest":{"state":"OPEN",
            "timelineItems":{"pageInfo":{"hasPreviousPage":true,"startCursor":"hist-broken"},"nodes":[\(team)]},
            "pending":{"pageInfo":{"hasNextPage":true,"endCursor":"pend-broken"},"nodes":[\(team)]}}}}}
        """
        GraphQLStub.respond = { _, body in
            let query = body["query"] as? String ?? ""
            let variables = body["variables"] as? [String: Any] ?? [:]
            if query.contains("fragment Engaged") { return (200, batchResponse) }
            if query.contains("before: $cursor") {
                switch variables["cursor"] as? String {
                case "hist-1":
                    return (200, #"{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasPreviousPage":true,"startCursor":"hist-2"},"nodes":[\#(team)]}}}}}"#)
                case "hist-2":
                    return (200, #"{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasPreviousPage":false,"startCursor":"hist-0"},"nodes":[\#(owners)]}}}}}"#)
                case "hist-direct":
                    return (200, #"{"data":{"repository":{"pullRequest":{"timelineItems":{"pageInfo":{"hasPreviousPage":false,"startCursor":"hist-0"},"nodes":[\#(direct)]}}}}}"#)
                default:
                    return (500, "")
                }
            }
            if query.contains("after: $cursor") {
                switch variables["cursor"] as? String {
                case "pend-1":
                    return (200, #"{"data":{"repository":{"pullRequest":{"pending":{"pageInfo":{"hasNextPage":true,"endCursor":"pend-2"},"nodes":[\#(team)]}}}}}"#)
                case "pend-2":
                    return (200, #"{"data":{"repository":{"pullRequest":{"pending":{"pageInfo":{"hasNextPage":false,"endCursor":"pend-3"},"nodes":[\#(other)]}}}}}"#)
                default:
                    return (500, "")
                }
            }
            return (500, "")
        }
        let result = await fetcher.details(for: threads, account: GitHubAccount(login: "octocat", token: "token"))
        let d1 = result.details[threads[0].key]
        XCTAssertEqual(d1?.requestHistoryComplete, true)
        XCTAssertEqual(d1?.viewerRequested, false)
        XCTAssertEqual(d1?.requestedTeams, ["octo/reviewers", "octo/owners"], "newest team request stays first after prepending older pages")
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: d1), .teamReviewRequested)
        XCTAssertEqual(d1?.pendingReviewers, ["octo/reviewers", "hubot"])

        let d2 = result.details[threads[1].key]
        XCTAssertEqual(d2?.requestHistoryComplete, true)
        XCTAssertEqual(d2?.viewerRequested, true, "direct review request on an older page keeps the PR in To you")
        XCTAssertEqual(NotificationItem.lane(for: .reviewRequested, detail: d2), .reviewRequested)

        let d3 = result.details[threads[2].key]
        XCTAssertEqual(d3?.requestHistoryComplete, false, "a failed older page leaves history incomplete")
        XCTAssertNil(d3?.pendingReviewers, "a failed pending page leaves pending reviewers unknown")
        XCTAssertTrue(result.erred.contains(threads[2].key))
    }

    /// Details GitHub would answer, changeable between refreshes.
    final class DetailBox: @unchecked Sendable {
        private let lock = NSLock()
        private var details: [String: NotificationSubjectDetail]
        var failing = false
        /// Subjects GitHub erred inside: what they show is kept, any answer isn't.
        var erring: Set<String> = []
        init(_ details: [String: NotificationSubjectDetail]) { self.details = details }
        func set(_ id: String, _ detail: NotificationSubjectDetail) { lock.withLock { details[id] = detail } }
        subscript(_ id: String) -> NotificationSubjectDetail? { lock.withLock { details[id] } }
    }

    private func answeringFetcher(_ box: DetailBox) -> NotificationDetailsFetcher {
        var fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2))
        fetcher.answer = { threads, account in
            var result = NotificationDetailsFetcher.Result(details: [:], settled: [], viewerLogin: account.login)
            guard !box.failing else { return result }
            for thread in threads {
                result.settled.insert(thread.key)
                result.details[thread.key] = box[thread.key.id]
                if box.erring.contains(thread.key.id) {
                    result.details[thread.key]?.viewerActedAt = nil
                    result.erred.insert(thread.key)
                }
            }
            return result
        }
        return fetcher
    }

    private func answeringModel(
        _ github: FakeGitHub, details box: DetailBox, clears: Bool, clock: TestClock, defaults: UserDefaults? = nil
    ) -> NotificationsModel {
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: defaults ?? UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            clearsAnswered: clears, api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: answeringFetcher(box),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil }, clock: { clock.now }, isVisible: { false }
        )
        model.setBadge = { _ in }
        return model
    }

    private var answeredDetail: NotificationSubjectDetail {
        var detail = NotificationSubjectDetail(state: .open)
        detail.viewerTargetedAt = now.addingTimeInterval(-7200)
        detail.viewerActedAt = now.addingTimeInterval(-3600)
        return detail
    }

    private var askedAgainDetail: NotificationSubjectDetail {
        var detail = answeredDetail
        detail.viewerTargetedAt = now.addingTimeInterval(-30)
        return detail
    }

    func testAnsweredThreadsAreMarkedDoneUntilYoureAskedAgain() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("2", reason: "mention", number: 2, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("3", reason: "author", number: 3, updated: now.addingTimeInterval(-60)),
        ]])
        var unanswered = answeredDetail
        unanswered.viewerActedAt = nil
        let box = DetailBox(["1": answeredDetail, "2": unanswered, "3": answeredDetail])
        let clock = TestClock(now)
        let model = answeringModel(github, details: box, clears: true, clock: clock)
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        XCTAssertEqual(github.actions, ["DELETE /notifications/threads/1"], "only the answered mention; your own PR's activity is never answered")
        XCTAssertEqual(Set(model.threads.map(\.key.id)), ["2", "3"])
        XCTAssertEqual(model.clearedAnswered.map(\.key.id), ["1"])
        XCTAssertTrue(banners.posted.isEmpty)
        XCTAssertNil(model.warning)

        // The same copy comes back from a refresh that raced the done: still cleared, not done twice.
        await model.refreshNow()
        XCTAssertFalse(model.threads.contains { $0.key.id == "1" })
        XCTAssertEqual(github.actions.filter { $0.hasSuffix("/1") }.count, 1)

        // On the same model: mentioned again after the answer, dated before this clock. It comes
        // back, needs you, and is never cleared again on the old judgment.
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-30)),
        ]])
        box.set("1", askedAgainDetail)
        await model.refreshNow()
        XCTAssertTrue(model.threads.contains { $0.key.id == "1" })
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(github.actions.filter { $0.hasSuffix("/1") }.count, 1)
        XCTAssertEqual(model.clearedAnswered.map(\.key.id), ["1"], "listed once")
    }

    func testAThreadThatChangedSinceItWasJudgedIsLeftForTheNextLook() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60))]])
        // A new mention landed after the inbox was read.
        github.setCurrent(FakeGitHub.thread("1", reason: "mention", number: 1, updated: now))
        let model = answeringModel(github, details: DetailBox(["1": answeredDetail]), clears: true, clock: TestClock(now))
        var published: [NotificationCounts] = []
        model.onCounts = { published.append($0) }
        await model.refreshNow()
        try await waitUntil { model.threads.contains { $0.key.id == "1" } && model.clearedAnswered.isEmpty }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(github.actions.contains { $0.hasPrefix("DELETE") }, "never done without a fresh look")
        XCTAssertNil(model.warning, "a thread that moved on isn't a failure")
        XCTAssertEqual(model.counts.needsYou, 1, "it may ask again, so it needs you until read again")
        XCTAssertEqual(published.last?.needsYou, 1, "and the badge says so")
    }

    func testAReopenedRequestThatStoppedAClearNeedsYouAgain() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now.addingTimeInterval(-60))]])
        // Closed when judged; reopened and asked again before the clear.
        github.setCurrent(FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now))
        var closed = answeredDetail
        closed.state = .closed
        let model = answeringModel(github, details: DetailBox(["1": closed]), clears: true, clock: TestClock(now))
        await model.refreshNow()
        try await waitUntil { model.threads.contains { $0.key.id == "1" } && model.clearedAnswered.isEmpty }
        XCTAssertFalse(github.actions.contains { $0.hasPrefix("DELETE") })
        XCTAssertEqual(model.counts.needsYou, 1, "the closed state it was judged on no longer stands")
        XCTAssertEqual(model.counts.settled, 0)
    }

    func testEveryClearedThreadIsCountedHoweverMany() async throws {
        let github = FakeGitHub()
        let ids = (1...150).map(String.init)
        github.answer("participating", pages: [ids.map { FakeGitHub.thread($0, reason: "mention", number: Int($0)!, updated: now.addingTimeInterval(-60)) }])
        let box = DetailBox(Dictionary(uniqueKeysWithValues: ids.map { ($0, answeredDetail) }))
        let model = answeringModel(github, details: box, clears: true, clock: TestClock(now))
        await model.refreshNow()
        try await waitUntil { github.actions.filter { $0.hasPrefix("DELETE") }.count == 150 }
        XCTAssertEqual(model.clearedAnswered.count, 150)
    }

    func testAStaleAnswerNeverHidesANewerCopy() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60))]])
        let box = DetailBox(["1": answeredDetail])
        let model = answeringModel(github, details: box, clears: false, clock: TestClock(now))
        await model.refreshNow()
        XCTAssertEqual(model.counts.answered, 1)
        // Something new arrives, and its details can't be read.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now)]])
        box.failing = true
        await model.refreshNow()
        XCTAssertEqual(model.counts.needsYou, 1, "the old answer was for an older copy")
    }

    func testASubjectThatErredIsReadAgainUnchanged() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(-60))]])
        let box = DetailBox(["1": answeredDetail])
        box.erring = ["1"]
        let model = answeringModel(github, details: box, clears: true, clock: TestClock(now))
        await model.refreshNow()
        XCTAssertEqual(model.counts.needsYou, 1, "what GitHub erred inside may have asked again")
        // GitHub recovers; the thread hasn't changed.
        box.erring = []
        await model.refreshNow()
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        XCTAssertEqual(model.clearedAnswered.map(\.key.id), ["1"])
    }

    func testAStaleClearNeverRevivesWhatANewerOneCleared() async throws {
        let github = FakeGitHub()
        let older = now.addingTimeInterval(-60), newer = now.addingTimeInterval(-30)
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: older)]])
        github.holdNextRead("1")
        let model = answeringModel(github, details: DetailBox(["1": answeredDetail]), clears: true, clock: TestClock(now))
        await model.refreshNow()
        try await waitUntil { github.isHolding("1") }
        // While the first clear looks again, the thread moves on, is judged answered
        // again, and a second clear finishes first.
        let moved = FakeGitHub.thread("1", reason: "mention", number: 1, updated: newer)
        github.answer("participating", pages: [[moved]])
        github.setCurrent(moved)
        await model.refreshNow()
        try await waitUntil { github.actions.contains("DELETE /notifications/threads/1") }
        github.release("1")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(github.actions, ["DELETE /notifications/threads/1"], "the first saw the change and stood down")
        XCTAssertFalse(model.threads.contains { $0.key.id == "1" }, "without bringing back its older copy")
        XCTAssertEqual(model.clearedAnswered.map(\.updatedAt), [newer])
        XCTAssertEqual(model.counts.needsYou, 0)
        XCTAssertNil(model.warning)
    }

    func testAReopenedRequestUnreadAfterAStaleClearNeedsYouAgain() async throws {
        let github = FakeGitHub()
        let older = now.addingTimeInterval(-60), newer = now.addingTimeInterval(-30)
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: older)]])
        github.holdNextRead("1")
        var closed = answeredDetail
        closed.state = .closed
        let box = DetailBox(["1": closed])
        let model = answeringModel(github, details: box, clears: true, clock: TestClock(now))
        await model.refreshNow()
        try await waitUntil { github.isHolding("1") }
        // While the clear looks again, the pull request is reopened and asks
        // again, and its details can't be read.
        let reopened = FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: newer)
        github.answer("participating", pages: [[reopened]])
        github.setCurrent(reopened)
        box.failing = true
        await model.refreshNow()
        XCTAssertTrue(model.threads.contains { $0.key.id == "1" })
        github.release("1")
        try await waitUntil { model.clearedAnswered.isEmpty }
        XCTAssertFalse(github.actions.contains { $0.hasPrefix("DELETE") })
        XCTAssertEqual(model.counts.needsYou, 1, "the closed state the stale clear was judged on no longer stands")
        XCTAssertEqual(model.counts.settled, 0)
    }

    func testReadOnlyCopiesNeverClearAnsweredThreads() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now)]])
        let model = answeringModel(github, details: DetailBox(["1": answeredDetail]), clears: false, clock: TestClock(now))
        await model.refreshNow()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(github.actions.isEmpty)
        XCTAssertEqual(model.counts.needsYou, 0, "answered doesn't need you")
        XCTAssertEqual(model.counts.answered, 1)
        XCTAssertTrue(model.clearedAnswered.isEmpty)
    }

    // MARK: Withdrawn requests

    func testPendingReviewRequestsAreReadWholeOrNotAtAll() throws {
        func pending(_ nodes: String, more: Bool = false) throws -> Set<String>? {
            let json = #"{"pageInfo":{"hasNextPage":\#(more)},"nodes":[\#(nodes)]}"#
            let decoded = try JSONDecoder().decode(NotificationDetailsFetcher.PendingRequests.self, from: Data(json.utf8))
            return NotificationDetailsFetcher.pendingReviewers(decoded)
        }
        let user = #"{"requestedReviewer":{"__typename":"User","login":"OctoCat"}}"#
        let team = #"{"requestedReviewer":{"__typename":"Team","slug":"Reviewers","organization":{"login":"Octo"}}}"#
        let bot = #"{"requestedReviewer":{"__typename":"Bot"}}"#
        XCTAssertEqual(try pending([user, team, bot].joined(separator: ",")), ["octocat", "octo/reviewers"], "a bot is never you")
        XCTAssertEqual(try pending(""), [])
        XCTAssertNil(try pending(user, more: true), "more than were read")
        XCTAssertNil(try pending(#"{"requestedReviewer":{"__typename":"EnterpriseTeam"}}"#), "a team it can't name may be yours")
        XCTAssertNil(try pending(#"{"requestedReviewer":null}"#))
        XCTAssertNil(try NotificationDetailsFetcher.pendingReviewers(
            JSONDecoder().decode(NotificationDetailsFetcher.PendingRequests.self, from: Data(#"{"pageInfo":{"hasNextPage":false},"nodes":null}"#.utf8))
        ))
        XCTAssertNil(NotificationDetailsFetcher.pendingReviewers(nil))
    }

    func testARequestIsWithdrawnOnlyWhenNothingOpenCouldReachYou() {
        func withdrawn(_ pending: Set<String>?, viewer: String = "OctoCat", onTeam: Bool? = nil) -> Bool {
            var detail = NotificationSubjectDetail(state: .open)
            detail.pendingReviewers = pending
            return detail.isWithdrawn(viewer: viewer) { _ in onTeam }
        }
        XCTAssertTrue(withdrawn([]))
        XCTAssertTrue(withdrawn(["hubot"]), "someone else still being asked isn't you")
        XCTAssertFalse(withdrawn(["octocat"]))
        XCTAssertFalse(withdrawn(["octo/reviewers"]), "a team you might be on")
        XCTAssertFalse(withdrawn(["octo/reviewers"], onTeam: true))
        XCTAssertTrue(withdrawn(["octo/reviewers"], onTeam: false))
        XCTAssertFalse(withdrawn(nil))
        XCTAssertFalse(withdrawn([], viewer: ""))
    }

    func testAWithdrawnRequestNoLongerNeedsYou() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("2", reason: "review_requested", number: 2, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("3", reason: "review_requested", number: 3, updated: now.addingTimeInterval(-60)),
        ]])
        var asked = NotificationSubjectDetail(state: .open)
        asked.viewerTargetedAt = now.addingTimeInterval(-7200)
        var withdrawn = asked
        withdrawn.pendingReviewers = []
        var teamStillAsked = asked
        // Membership can't be read here, so the team may be yours.
        teamStillAsked.pendingReviewers = ["octo/reviewers"]
        var reviewed = answeredDetail
        reviewed.pendingReviewers = []
        let box = DetailBox(["1": withdrawn, "2": teamStillAsked, "3": reviewed])
        let model = answeringModel(github, details: box, clears: false, clock: TestClock(now))
        await model.refreshNow()
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(model.items.filter(\.needsYou).map(\.id.id), ["2"])
        XCTAssertEqual(model.counts.settled, 1, "withdrawn is counted with merged and closed")
        XCTAssertEqual(model.counts.answered, 1, "reviewing takes you off the list too; that's answered")

        // Something new, and its details can't be read: the old judgment doesn't hold.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now)]])
        box.failing = true
        await model.refreshNow()
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(model.counts.settled, 0)
    }

    // MARK: Scope

    private func item(
        _ id: String, kind: NotificationSubjectKind = .pullRequest, repo: String = "octo/app",
        state: NotificationSubjectDetail.State?
    ) -> NotificationItem {
        NotificationItem(
            thread: thread(id, "mention", kind: kind, repo: repo),
            detail: state.map { NotificationSubjectDetail(state: $0) }, detailsSettled: true
        )
    }

    func testMergedAndClosedSubjectsAreHiddenByDefault() {
        let items = [
            item("open", state: .open), item("draft", state: .draft), item("merged", state: .merged),
            item("closed", state: .closed), item("issue", kind: .issue, state: .open),
            item("done", kind: .issue, state: .completed), item("dropped", kind: .issue, state: .notPlanned),
            item("unknown", state: nil), item("ci", kind: .checkSuite, state: nil),
        ]
        var scope = NotificationScope()
        var scoped = ScopedNotifications(items, scope: scope)
        XCTAssertEqual(scoped.shown.map(\.id.id), ["open", "issue", "unknown", "ci"], "an unknown state is never hidden")
        XCTAssertEqual(scoped.hiddenByState, 4)
        XCTAssertEqual(scoped.hiddenDrafts, 1)
        XCTAssertEqual(scoped.total, items.count)

        scope.hidesMergedPullRequests = false
        XCTAssertNil(scope.hidden(items[2]))
        XCTAssertEqual(scope.hidden(items[3]), .closedPullRequest, "closed and merged are separate choices")
        scope.hidesClosedPullRequests = false
        XCTAssertEqual(ScopedNotifications(items, scope: scope).hiddenByState, 2, "closed issues stay hidden")
        scope.hidesClosedIssues = false
        scope.hidesDraftPullRequests = false
        scoped = ScopedNotifications(items, scope: scope)
        XCTAssertEqual(scoped.shown.count, items.count)
    }

    func testOnlyAStateReadForThisCopyHidesItExceptAMerge() {
        func stale(_ id: String, kind: NotificationSubjectKind = .pullRequest, state: NotificationSubjectDetail.State) -> NotificationItem {
            NotificationItem(thread: thread(id, "mention", kind: kind), detail: NotificationSubjectDetail(state: state),
                             detailsSettled: true, stateIsCurrent: false)
        }
        let scope = NotificationScope()
        XCTAssertNil(scope.hidden(stale("reopened", kind: .issue, state: .completed)), "it may have been reopened since")
        XCTAssertNil(scope.hidden(stale("pr", state: .closed)))
        XCTAssertEqual(scope.hidden(stale("merged", state: .merged)), .mergedPullRequest, "nothing undoes a merge")
        XCTAssertTrue(scope.mightHide(stale("reopened", kind: .issue, state: .completed)))
        XCTAssertFalse(scope.mightHide(stale("open", state: .open)), "an open subject stays put while it's read again")

        let numberless = NotificationItem(thread: thread("x", "mention", number: nil), detail: nil, detailsSettled: false)
        XCTAssertFalse(scope.mightHide(numberless), "a subject with no number is never read, so it never waits")
        let scoped = ScopedNotifications([numberless, stale("reopened", kind: .issue, state: .closed)], scope: scope) { _ in true }
        XCTAssertEqual(scoped.shown.map(\.id.id), ["x"])
        XCTAssertEqual(scoped.pending, 1)
    }

    func testAReopenedIssueIsNotHiddenByItsOldClosedStateWhenItCantBeReadAgain() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", number: 1, updated: now.addingTimeInterval(-60)),
        ]])
        let box = DetailBox(["1": NotificationSubjectDetail(state: .completed)])
        let model = answeringModel(github, details: box, clears: false, clock: TestClock(now))
        await model.refreshNow()
        XCTAssertTrue(model.items.isEmpty, "closed issues are hidden")

        // Reopened and mentioned again, but its details can't be read.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", number: 1, updated: now)]])
        box.failing = true
        await model.refreshNow()
        XCTAssertEqual(model.items.map(\.id.id), ["1"])
        XCTAssertEqual(model.counts.needsYou, 1)
    }

    func testAReopenedReviewRequestNeedsYouWhenItsOldClosedStateCantBeReadAgain() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now.addingTimeInterval(-60)),
        ]])
        let box = DetailBox(["1": NotificationSubjectDetail(state: .closed)])
        let model = answeringModel(github, details: box, clears: false, clock: TestClock(now))
        var badge: String?
        model.setBadge = { badge = $0 }
        model.hidesClosedPullRequests = false
        await model.refreshNow()
        XCTAssertEqual(model.counts.settled, 1, "a closed pull request has nothing left to review")
        XCTAssertEqual(model.counts.needsYou, 0)

        // Reopened and asked again, but its details can't be read.
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "review_requested", number: 1, updated: now)]])
        box.failing = true
        await model.refreshNow()
        XCTAssertEqual(model.items.map(\.id.id), ["1"])
        XCTAssertEqual(model.counts.settled, 0, "the old close may have been undone")
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(badge, "1")

        // Hiding closed pull requests doesn't hide it either.
        model.hidesClosedPullRequests = true
        XCTAssertEqual(model.counts.needsYou, 1)
        XCTAssertEqual(badge, "1")

        let merged = NotificationItem(
            thread: thread("m", "review_requested"), detail: NotificationSubjectDetail(state: .merged), detailsSettled: true,
            stateIsCurrent: false
        )
        XCTAssertTrue(merged.isSettled, "nothing undoes a merge")
    }

    func testOwnersNarrowTheScopeWhateverTheirCase() {
        let items = [
            item("mine", repo: "Octo/app", state: .open),
            item("theirs", repo: "other/app", state: .open),
            item("theirs-merged", repo: "other/app", state: .merged),
        ]
        let scoped = ScopedNotifications(items, scope: NotificationScope(owners: ["octo"]))
        XCTAssertEqual(scoped.shown.map(\.id.id), ["mine"])
        XCTAssertEqual(scoped.hiddenByOwner, 2, "outside the owners is the reason, whatever the state")
        XCTAssertEqual(scoped.hiddenByState, 0)
        XCTAssertEqual(ScopedNotifications(items, scope: NotificationScope(owners: [])).hiddenByOwner, 0, "empty means every owner")
    }

    func testThePullDownAndNotesNameWhatIsHidden() {
        XCTAssertEqual(NotificationScope().hidingLabel, "Hiding CI, your PRs, drafts, merged & closed")
        XCTAssertEqual(NotificationScope(hidesDraftPullRequests: false).hidingLabel, "Hiding CI, your PRs, merged & closed")
        XCTAssertEqual(NotificationScope(hidesYourPullRequests: false, hidesDraftPullRequests: false).hidingLabel, "Hiding CI, merged & closed")
        XCTAssertEqual(
            NotificationScope(hidesCIActivity: false, hidesYourPullRequests: false, hidesDraftPullRequests: false).hidingLabel,
            "Hiding merged & closed"
        )
        XCTAssertEqual(
            NotificationScope(hidesClosedIssues: false, hidesCIActivity: false, hidesYourPullRequests: false, hidesDraftPullRequests: false).hidingLabel,
            "Hiding merged & closed PRs"
        )
        XCTAssertEqual(
            NotificationScope(hidesClosedPullRequests: false, hidesCIActivity: false, hidesYourPullRequests: false, hidesDraftPullRequests: false).hidingLabel,
            "Hiding merged PRs & closed issues"
        )
        XCTAssertEqual(
            NotificationScope(hidesMergedPullRequests: false, hidesClosedPullRequests: false, hidesYourPullRequests: false).hidingLabel,
            "Hiding CI, drafts, closed issues"
        )
        XCTAssertEqual(
            NotificationScope(
                hidesMergedPullRequests: false, hidesClosedPullRequests: false, hidesClosedIssues: false,
                hidesCIActivity: false, hidesYourPullRequests: false
            ).hidingLabel,
            "Hiding drafts"
        )
        XCTAssertEqual(
            NotificationScope(
                hidesMergedPullRequests: false, hidesClosedPullRequests: false, hidesClosedIssues: false,
                hidesCIActivity: false, hidesYourPullRequests: false, hidesDraftPullRequests: false
            ).hidingLabel,
            "Showing everything"
        )
        let scoped = ScopedNotifications(
            [item("m", state: .merged), item("x", repo: "other/app", state: .open)], scope: NotificationScope(owners: ["octo"])
        )
        XCTAssertEqual(
            NotificationsView.allHiddenDescription(scoped, owners: ["octo"]),
            "1 merged or closed thread and 1 thread outside octo are hidden. They stay in your GitHub inbox."
        )
        XCTAssertEqual(NotificationsView.countHelp(scoped, owners: ["octo"], unreadOnly: true),
                       "Hidden: 1 merged or closed · 1 outside octo\nRead threads are left out while Unread is on.")
    }

    func testCIIsHiddenByDefaultAndCanBeShown() {
        let ci = NotificationItem(thread: thread("ci", "ci_activity", kind: .checkSuite, number: nil), detail: nil, detailsSettled: true)
        let mention = item("m", state: .open)
        var scope = NotificationScope()
        var scoped = ScopedNotifications([ci, mention], scope: scope)
        XCTAssertEqual(scoped.shown.map(\.id.id), ["m"])
        XCTAssertEqual(scoped.hiddenCI, 1)
        XCTAssertEqual(scoped.total, 2)
        XCTAssertEqual(NotificationsView.countHelp(scoped, owners: [], unreadOnly: false), "Hidden: 1 CI")
        XCTAssertEqual(
            NotificationsView.allHiddenDescription(ScopedNotifications([ci], scope: scope), owners: []),
            "1 CI thread is hidden. They stay in your GitHub inbox."
        )
        scope.hidesCIActivity = false
        scoped = ScopedNotifications([ci, mention], scope: scope)
        XCTAssertEqual(scoped.shown.map(\.id.id), ["ci", "m"])
        XCTAssertEqual(scoped.hiddenCI, 0)
    }

    func testDraftsAreHiddenUntilReadyAndOnlyOnStateReadForThisCopy() {
        func pr(_ id: String, _ reason: String, _ state: NotificationSubjectDetail.State?, current: Bool = true) -> NotificationItem {
            NotificationItem(thread: thread(id, reason), detail: state.map { NotificationSubjectDetail(state: $0) },
                             detailsSettled: true, stateIsCurrent: current)
        }
        let draft = pr("draft", "review_requested", .draft)
        let ready = pr("ready", "review_requested", .open)
        let stale = pr("stale", "mention", .draft, current: false)
        var scope = NotificationScope()
        var scoped = ScopedNotifications([draft, ready, stale], scope: scope)
        XCTAssertEqual(scoped.shown.map(\.id.id), ["ready", "stale"], "a draft read for an older copy may be ready now")
        XCTAssertEqual(scoped.hiddenDrafts, 1)
        XCTAssertTrue(scope.mightHide(stale), "it waits while it's read again")
        XCTAssertEqual(ScopedNotifications([stale], scope: scope) { _ in true }.pending, 1)
        XCTAssertEqual(NotificationsView.countHelp(scoped, owners: [], unreadOnly: false), "Hidden: 1 draft")
        XCTAssertEqual(
            NotificationsView.allHiddenDescription(ScopedNotifications([draft], scope: scope), owners: []),
            "1 draft pull request is hidden. They stay in your GitHub inbox."
        )
        scope.hidesDraftPullRequests = false
        scoped = ScopedNotifications([draft, ready, stale], scope: scope)
        XCTAssertEqual(scoped.shown.count, 3)
    }

    func testActivityOnYourPullRequestsIsHiddenByDefaultButWhatAsksYouIsNot() {
        func mine(_ id: String, _ reason: String, kind: NotificationSubjectKind = .pullRequest) -> NotificationItem {
            NotificationItem(thread: thread(id, reason, kind: kind), detail: NotificationSubjectDetail(state: .open), detailsSettled: true)
        }
        let items = [mine("pr", "author"), mine("issue", "author", kind: .issue), mine("asked", "mention"), mine("review", "review_requested")]
        var scope = NotificationScope()
        var scoped = ScopedNotifications(items, scope: scope)
        XCTAssertEqual(scoped.shown.map(\.id.id), ["issue", "asked", "review"], "only activity on your pull requests goes")
        XCTAssertEqual(scoped.hiddenYourPullRequests, 1)
        XCTAssertEqual(NotificationsView.countHelp(scoped, owners: [], unreadOnly: false), "Hidden: 1 on your PRs")
        XCTAssertEqual(
            NotificationsView.allHiddenDescription(ScopedNotifications([items[0]], scope: scope), owners: []),
            "1 thread on your PRs is hidden. They stay in your GitHub inbox."
        )
        scope.hidesYourPullRequests = false
        scoped = ScopedNotifications(items, scope: scope)
        XCTAssertEqual(scoped.shown.count, 4)
    }

    func testEmptyLanesSayNothingIsUnreadHiddenOrClearUntilEverySubjectIsPlaced() {
        let read = NotificationItem(
            thread: thread("read", "mention", unread: false), detail: NotificationSubjectDetail(state: .open), detailsSettled: true
        )
        let reading = NotificationItem(thread: thread("new", "mention", number: 2), detail: nil, detailsSettled: false)
        let merged = item("merged", state: .merged)
        let scope = NotificationScope()
        XCTAssertEqual(
            NotificationsView.emptyContent(ScopedNotifications([read, reading], scope: scope) { _ in true }), .checking,
            "the unread subject still being read may yet show"
        )
        XCTAssertEqual(NotificationsView.emptyContent(ScopedNotifications([read, reading], scope: scope)), .noUnread)
        XCTAssertEqual(NotificationsView.emptyContent(ScopedNotifications([merged, reading], scope: scope) { _ in true }), .checking)
        XCTAssertEqual(NotificationsView.emptyContent(ScopedNotifications([merged], scope: scope)), .allHidden)
        XCTAssertEqual(NotificationsView.emptyContent(ScopedNotifications([], scope: scope)), .inboxClear)
    }

    func testHiddenThreadsNeitherCountNorBannerAndTheChoiceIsKept() async throws {
        let github = FakeGitHub()
        let clock = TestClock(now)
        let old = FakeGitHub.thread("old", reason: "mention", type: "Issue", number: 9, updated: now.addingTimeInterval(-60))
        github.answer("participating", pages: [[old]])
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let box = DetailBox([
            "old": NotificationSubjectDetail(state: .open), "1": NotificationSubjectDetail(state: .merged),
            "2": NotificationSubjectDetail(state: .open), "3": NotificationSubjectDetail(state: .open),
        ])
        let model = answeringModel(github, details: box, clears: false, clock: clock, defaults: defaults)
        var badge: String?
        model.setBadge = { badge = $0 }
        let banners = FakeBanners()
        model.banners = banners
        await model.refreshNow()

        clock.now += 120
        github.answer("participating", pages: [[
            old,
            FakeGitHub.thread("1", reason: "mention", number: 1, updated: now.addingTimeInterval(60)),
            FakeGitHub.thread("2", reason: "mention", repo: "other/app", number: 2, updated: now.addingTimeInterval(60)),
            FakeGitHub.thread("3", reason: "mention", number: 3, updated: now.addingTimeInterval(60)),
        ]])
        model.owners = "@Octo"
        XCTAssertEqual(defaults.string(forKey: NotificationsModel.ownersKey), "@Octo")
        await model.refreshNow()
        XCTAssertEqual(Set(model.items.map(\.id.id)), ["old", "3"])
        XCTAssertEqual(model.scoped.hiddenByState, 1)
        XCTAssertEqual(model.scoped.hiddenByOwner, 1)
        XCTAssertEqual(model.counts.needsYou, 2)
        XCTAssertEqual(badge, "2")
        XCTAssertEqual(banners.posted.flatMap { $0 }.compactMap(\.thread?.id), ["3"], "hidden threads raise no banner")

        model.hidesMergedPullRequests = false
        XCTAssertEqual(badge, "3", "the badge follows the choice at once")
        model.owners = ""
        XCTAssertEqual(badge, "4")
        model.hidesClosedIssues = false
        XCTAssertTrue(model.hidesCIActivity)
        model.hidesCIActivity = false
        XCTAssertTrue(model.hidesYourPullRequests)
        model.hidesYourPullRequests = false
        XCTAssertTrue(model.hidesDraftPullRequests)
        model.hidesDraftPullRequests = false

        let relaunched = answeringModel(github, details: box, clears: false, clock: clock, defaults: defaults)
        XCTAssertFalse(relaunched.hidesMergedPullRequests)
        XCTAssertTrue(relaunched.hidesClosedPullRequests)
        XCTAssertFalse(relaunched.hidesClosedIssues)
        XCTAssertFalse(relaunched.hidesCIActivity)
        XCTAssertFalse(relaunched.hidesYourPullRequests)
        XCTAssertFalse(relaunched.hidesDraftPullRequests)
        XCTAssertEqual(relaunched.owners, "")
    }

    func testASubjectReadForTheFirstTimeWaitsForItsStateInsteadOfFlashingPast() async throws {
        final class Probe: @unchecked Sendable {
            weak var model: NotificationsModel?
            var seen: [String]?
            var pending = 0
            var fails = false
        }
        let probe = Probe()
        var fetcher = NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2))
        fetcher.answer = { threads, account in
            await MainActor.run {
                probe.seen = probe.model?.items.map(\.id.id)
                probe.pending = probe.model?.scoped.pending ?? -1
            }
            var result = NotificationDetailsFetcher.Result(details: [:], settled: [], viewerLogin: account.login)
            guard !probe.fails else { return result }
            for thread in threads {
                result.settled.insert(thread.key)
                result.details[thread.key] = NotificationSubjectDetail(state: .merged)
            }
            return result
        }
        let github = FakeGitHub()
        let ci = FakeGitHub.thread("ci", reason: "ci_activity", type: "CheckSuite", number: nil, updated: now)
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, updated: now), ci]])
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            api: GitHubNotificationsAPI(send: github.send), detailsFetcher: fetcher,
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil }, clock: { clock.now }, isVisible: { false }
        )
        model.setBadge = { _ in }
        // The CI thread is the control: something that never waits for a state.
        model.hidesCIActivity = false
        probe.model = model
        await model.refreshNow()
        XCTAssertEqual(probe.seen, ["ci"], "the pull request waits while its state is read")
        XCTAssertEqual(probe.pending, 1)
        XCTAssertEqual(model.items.map(\.id.id), ["ci"], "and then stays out: it's merged")
        XCTAssertEqual(model.scoped.hiddenByState, 1)

        // A subject GitHub doesn't answer for shows once the read is over.
        probe.fails = true
        github.answer("participating", pages: [[FakeGitHub.thread("2", reason: "mention", number: 2, updated: now), ci]])
        await model.refreshNow()
        XCTAssertEqual(probe.seen, ["ci"])
        XCTAssertEqual(Set(model.items.map(\.id.id)), ["2", "ci"])
        XCTAssertEqual(model.scoped.pending, 0)
    }

    // MARK: Remembered dones

    private func doneThreads(_ defaults: UserDefaults) -> [String: Double] {
        (defaults.dictionary(forKey: NotificationsModel.doneThreadsKey) as? [String: Double]) ?? [:]
    }

    func testDoneThreadsStayDoneAfterARestart() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        // GitHub keeps listing a done thread among read ones.
        github.answer("read", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", unread: false, updated: now.addingTimeInterval(-60))]])
        let first = makeModel(github, clock: TestClock(now), defaults: defaults)
        await first.refreshNow()
        first.markDone(first.items)
        try await waitUntil { self.doneThreads(defaults)["octocat|1"] != nil }

        let second = makeModel(github, clock: TestClock(now), defaults: defaults)
        await second.refreshNow()
        XCTAssertTrue(second.threads.isEmpty)

        github.answer("read", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", unread: false, updated: now.addingTimeInterval(60))]])
        await second.refreshNow()
        XCTAssertEqual(second.threads.map(\.key.id), ["1"], "activity after the done brings it back")
        XCTAssertNil(doneThreads(defaults)["octocat|1"])
    }

    func testOnlyADoneGitHubAcceptedIsRemembered() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        github.answer("participating", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", updated: now)]])
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        github.holdNextAction("1")
        model.markDone(model.items)
        try await waitUntil { github.isHolding("1") }
        XCTAssertTrue(doneThreads(defaults).isEmpty, "not while it's in flight")
        let restarted = makeModel(github, clock: TestClock(now), defaults: defaults)
        await restarted.refreshNow()
        XCTAssertEqual(restarted.threads.map(\.key.id), ["1"])
        github.release("1")
        try await waitUntil { self.doneThreads(defaults)["octocat|1"] != nil }

        github.answer("participating", pages: [[FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, updated: now)]])
        await model.refreshNow()
        github.fail("DELETE")
        model.markDone(model.items.filter { $0.id.id == "2" })
        try await waitUntil { model.warning != nil }
        XCTAssertNil(doneThreads(defaults)["octocat|2"], "nor one that failed")
    }

    func testEachAcceptedDoneIsRememberedWithoutWaitingForTheRest() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        github.answer("read", pages: [[
            FakeGitHub.thread("1", reason: "mention", type: "Issue", number: 1, unread: false, updated: now.addingTimeInterval(-60)),
            FakeGitHub.thread("2", reason: "mention", type: "Issue", number: 2, unread: false, updated: now.addingTimeInterval(-60)),
        ]])
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        github.holdNextAction("2")
        model.markDone(model.items)
        try await waitUntil { github.isHolding("2") && self.doneThreads(defaults)["octocat|1"] != nil }

        // Quit while the other is still in flight.
        let restarted = makeModel(github, clock: TestClock(now), defaults: defaults)
        await restarted.refreshNow()
        XCTAssertEqual(restarted.threads.map(\.key.id), ["2"])
        github.release("2")
        try await waitUntil { self.doneThreads(defaults)["octocat|2"] != nil }
    }

    func testDonesAreRememberedForAnAccountWithoutALogin() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        github.answer("read", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", unread: false, updated: now.addingTimeInterval(-60))]])
        // An older gh names no account.
        let first = makeModel(github, clock: TestClock(now), defaults: defaults, login: "")
        await first.refreshNow()
        XCTAssertEqual(first.threads.map(\.key.id), ["1"])
        first.markDone(first.items)
        try await waitUntil { self.doneThreads(defaults)["|1"] != nil }

        let second = makeModel(github, clock: TestClock(now), defaults: defaults, login: "")
        await second.refreshNow()
        XCTAssertTrue(second.threads.isEmpty)
    }

    func testClearedThreadsAreNotClearedAgainAfterARestart() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        github.answer("read", pages: [[FakeGitHub.thread("1", reason: "mention", number: 1, unread: false, updated: now.addingTimeInterval(-60))]])
        let box = DetailBox(["1": answeredDetail])
        let first = answeringModel(github, details: box, clears: true, clock: TestClock(now), defaults: defaults)
        await first.refreshNow()
        try await waitUntil { self.doneThreads(defaults)["octocat|1"] != nil }

        let second = answeringModel(github, details: box, clears: true, clock: TestClock(now), defaults: defaults)
        await second.refreshNow()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(github.actions.filter { $0.hasPrefix("DELETE") }.count, 1)
        XCTAssertTrue(second.clearedAnswered.isEmpty)
        XCTAssertTrue(second.threads.isEmpty)
    }

    func testDonesOlderThanTheReadWindowAreForgotten() async throws {
        let github = FakeGitHub()
        let defaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let old = now.addingTimeInterval(-4 * 86_400)
        defaults.set(["octocat|1": old.timeIntervalSince1970], forKey: NotificationsModel.doneThreadsKey)
        github.answer("read", pages: [[FakeGitHub.thread("1", reason: "mention", type: "Issue", unread: false, updated: old.addingTimeInterval(-60))]])
        let model = makeModel(github, clock: TestClock(now), defaults: defaults)
        await model.refreshNow()
        XCTAssertEqual(model.threads.map(\.key.id), ["1"])
    }

    func testReviewInCopilotMatchesProjectStartsReviewLinksSessionAndMarksRead() async throws {
        let github = FakeGitHub()
        github.answer("participating", pages: [[
            FakeGitHub.thread("1", reason: "review_requested", repo: "octo/Ops", number: 19, updated: now),
            FakeGitHub.thread("2", reason: "mention", type: "Issue", repo: "octo/Ops", number: 20, updated: now),
        ]])
        let workspace = FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)])
        let recorder = HostRecorder()
        let clock = TestClock(now)
        let suiteDefaults = UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!
        let model = NotificationsModel(
            workspace: workspace,
            host: recorder.host,
            defaults: suiteDefaults,
            api: GitHubNotificationsAPI(send: github.send),
            detailsFetcher: NotificationDetailsFetcher(graphQL: GitHubGraphQL(endpoint: URL(string: "http://127.0.0.1:9/graphql")!, timeout: 2)),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil },
            clock: { clock.now },
            isVisible: { true },
            presentError: { title, message in recorder.alerts.append("\(title): \(message)") }
        )
        model.setBadge = { _ in }
        await model.pollWorkspace()
        await model.refreshNow()

        let prItem = try XCTUnwrap(model.items.first { $0.id.id == "1" })
        let issueItem = try XCTUnwrap(model.items.first { $0.id.id == "2" })
        XCTAssertTrue(model.canReviewInCopilot(prItem))
        XCTAssertFalse(model.canReviewInCopilot(issueItem))
        XCTAssertEqual(model.preferredProjectId(for: prItem.thread), "q", "matches the Ops project by repository name")

        var updatedSnapshot = fixtureSnapshot
        updatedSnapshot.projects[1].sessions.append(
            .init(id: "reviewed", title: "Review octo/Ops#19", status: .running, pullRequestKeys: ["octo/ops#19"])
        )
        workspace.answer(
            fetches: [.snapshot(fixtureSnapshot), .snapshot(updatedSnapshot)],
            reviews: [.unreachable, .unreachable, .done(code: "created", text: "reviewed")]
        )

        // First user attempt hits two unreachable responses and surfaces an alert while keeping
        // the pending requestId for retry.
        model.reviewInCopilot(prItem)
        try await waitUntil { model.reviewingThreads.isEmpty }
        XCTAssertEqual(workspace.reviewCalls.count, 2, "a lost answer is retried once with the same request id")
        let initialRequestId = workspace.reviewCalls[0].requestId
        XCTAssertEqual(workspace.reviewCalls[1].requestId, initialRequestId)
        XCTAssertEqual(recorder.alerts.count, 1)

        // Second user attempt reuses the exact same requestId and links the session on success.
        model.reviewInCopilot(prItem)
        try await waitUntil { model.reviewingThreads.isEmpty }
        XCTAssertEqual(workspace.reviewCalls.count, 3)
        XCTAssertEqual(workspace.reviewCalls[2].requestId, initialRequestId)
        XCTAssertEqual(workspace.reviewCalls[2].projectId, "q")
        XCTAssertEqual(workspace.reviewCalls[2].pullRequestURL, "https://github.com/octo/Ops/pull/19")
        XCTAssertEqual(workspace.revealCalls.last?.projectId, "q")
        XCTAssertEqual(workspace.revealCalls.last?.sessionId, "reviewed")
        XCTAssertEqual(recorder.activations, [4242])

        let linkedItem = try XCTUnwrap(model.items.first { $0.id.id == "1" })
        XCTAssertEqual(linkedItem.session?.id, "reviewed")
        XCTAssertFalse(model.canReviewInCopilot(linkedItem), "once linked to a live session, Go to Session takes over")
        XCTAssertFalse(linkedItem.thread.unread, "starting a review marks the thread read")

        // Choosing a project for review is remembered across threads and restarts, even when
        // another thread's repository name doesn't match that project.
        github.answer("participating", pages: [[
            FakeGitHub.thread("3", reason: "review_requested", repo: "other-org/unmatched-repo", number: 77, updated: now),
        ]])
        await model.refreshNow()
        let unmatchedItem = try XCTUnwrap(model.items.first { $0.id.id == "3" })
        XCTAssertEqual(
            model.preferredProjectId(for: unmatchedItem.thread),
            "q",
            "remembers the last project used for Review in Copilot instead of falling back to the first project"
        )
        workspace.answer(
            fetches: [.snapshot(updatedSnapshot)],
            reviews: [.done(code: "created", text: "reviewed-2")]
        )
        model.reviewInCopilot(unmatchedItem, projectId: "p")
        try await waitUntil { model.reviewingThreads.isEmpty }
        XCTAssertEqual(model.lastReviewProjectId, "p")
        XCTAssertEqual(model.preferredProjectId(for: prItem.thread), "p", "explicitly chosen project becomes the new default")

        let restartedModel = NotificationsModel(
            workspace: FakeWorkspace(fetches: [.snapshot(fixtureSnapshot)]),
            host: recorder.host,
            defaults: suiteDefaults,
            api: GitHubNotificationsAPI(send: github.send),
            loadAccounts: { [GitHubAccount(login: "octocat", token: "token")] },
            transcriptPath: { _ in nil },
            clock: { clock.now },
            isVisible: { true }
        )
        restartedModel.setBadge = { _ in }
        await restartedModel.pollWorkspace()
        XCTAssertEqual(restartedModel.lastReviewProjectId, "p")
        XCTAssertEqual(restartedModel.preferredProjectId(for: prItem.thread), "p", "last chosen review project persists across launches")
    }

    func testWorkspaceLoopRefreshesImmediatelyOnDiskEventsAndSkipsUnchangedPolls() async throws {
        let stateDir = FileManager.default.temporaryDirectory.appendingPathComponent("notif-ws-\(UUID().uuidString)", isDirectory: true)
        let sessionsDir = stateDir.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stateDir) }
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: stateDir.appendingPathComponent("state.json"), options: .atomic)

        let initialSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: []),
        ])
        let linkedSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Review PR", status: .running, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let waitingSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Review PR", status: .waiting, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let workspace = FakeWorkspace(fetches: [
            .snapshot(initialSnapshot),
            .snapshot(linkedSnapshot),
            .snapshot(waitingSnapshot),
        ])
        let clock = TestClock(now)
        let model = NotificationsModel(
            workspace: workspace,
            defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            workspaceStateDirectory: stateDir,
            workspacePollInterval: 30,
            workspaceUnchangedPollInterval: 15,
            workspaceWatchDebounce: 0.02,
            loadAccounts: { [] },
            transcriptPath: { _ in nil },
            clock: { clock.now },
            isVisible: { true }
        )
        model.setBadge = { _ in }
        model.show([thread("1", "review_requested")], accounts: ["octocat"])

        let loop = Task { await model.runWorkspaceLoop() }
        defer { loop.cancel() }

        try await waitUntil { workspace.snapshotCalls == 1 && model.workspace == .connected(initialSnapshot) }

        // Unchanged signature skips redundant polls.
        await model.pollWorkspaceIfNeeded()
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 1)

        // Writing state.json triggers an immediate refresh and links the new session.
        try Data(#"{"schemaVersion":1,"sessions":1}"#.utf8).write(
            to: stateDir.appendingPathComponent("state.json"),
            options: .atomic
        )
        try await waitUntil { model.links[PullRequestKey("octo/app#1")!] == "s1" }
        XCTAssertEqual(workspace.snapshotCalls, 2)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 2)

        // Writing a session status record in sessions/ triggers an immediate refresh.
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"status":"waiting"}"#.utf8).write(
            to: sessionsDir.appendingPathComponent("s1.status-record.json"),
            options: .atomic
        )
        try await waitUntil { model.liveSessions["s1"]?.status == .waiting }
        XCTAssertEqual(workspace.snapshotCalls, 3)
        await model.pollWorkspaceIfNeeded()
        XCTAssertEqual(workspace.snapshotCalls, 3)
    }

    func testSupersededWorkspaceSnapshotDoesNotOverwriteNewerPoll() async throws {
        actor DelayedWorkspace: PullRequestsWorkspace {
            private var continuations: [Int: CheckedContinuation<WorkspaceFetch, Never>] = [:]
            private var calls = 0
            let answers: [Int: WorkspaceFetch]
            let heldCalls: Set<Int>

            init(answers: [Int: WorkspaceFetch], heldCalls: Set<Int>) {
                self.answers = answers
                self.heldCalls = heldCalls
            }

            func snapshot() async -> WorkspaceFetch {
                calls += 1
                let call = calls
                if heldCalls.contains(call) {
                    return await withCheckedContinuation { continuations[call] = $0 }
                }
                return answers[call] ?? .unreachable
            }

            func isWaiting(call: Int) -> Bool { continuations[call] != nil }

            func release(call: Int) {
                continuations.removeValue(forKey: call)?.resume(returning: answers[call] ?? .unreachable)
            }

            func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult { .unreachable }
            func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult { .unreachable }
            func resumeCopilotSession(projectId: String, requestId: UUID, copilotSessionId: String) async -> WorkspaceCommandResult { .unreachable }
            func sendSessionPrompt(projectId: String?, sessionId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult { .unreachable }
        }

        let staleSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: []),
        ])
        let freshSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Workspace", sessions: [
                .init(id: "s1", title: "Fresh", status: .waiting, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let newestSnapshot = WorkspaceSnapshot(hostProcessIdentifier: 42, selectedProjectId: "q", projects: [
            .init(id: "q", name: "Moved", sessions: [
                .init(id: "s1", title: "Fresh", status: .running, pullRequestKeys: ["octo/app#1"]),
            ]),
        ])
        let workspace = DelayedWorkspace(
            answers: [1: .snapshot(staleSnapshot), 2: .snapshot(freshSnapshot), 3: .snapshot(freshSnapshot), 4: .snapshot(newestSnapshot)],
            heldCalls: [1, 3, 4]
        )
        let model = NotificationsModel(
            workspace: workspace,
            defaults: UserDefaults(suiteName: "notifications-\(UUID().uuidString)")!,
            loadAccounts: { [] },
            transcriptPath: { _ in nil },
            clock: { self.now }
        )
        model.setBadge = { _ in }
        model.show([thread("1", "review_requested")], accounts: ["octocat"])

        let firstPoll = Task { await model.pollWorkspace() }
        for _ in 0..<250 {
            if await workspace.isWaiting(call: 1) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await model.pollWorkspace()
        XCTAssertEqual(model.workspace, .connected(freshSnapshot))
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s1")

        await workspace.release(call: 1)
        await firstPoll.value
        XCTAssertEqual(model.workspace, .connected(freshSnapshot), "an older snapshot finishing late must be discarded")
        XCTAssertEqual(model.links[PullRequestKey("octo/app#1")!], "s1")

        // An earlier poll finishing while a newer poll is still in flight still applies its result.
        let thirdPoll = Task { await model.pollWorkspace() }
        for _ in 0..<250 {
            if await workspace.isWaiting(call: 3) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fourthPoll = Task { await model.pollWorkspace() }
        for _ in 0..<250 {
            if await workspace.isWaiting(call: 4) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        await workspace.release(call: 3)
        await thirdPoll.value
        XCTAssertEqual(model.liveSessions["s1"]?.projectId, "p", "an in-flight newer poll must not discard a completed refresh")
        await workspace.release(call: 4)
        await fourthPoll.value
        XCTAssertEqual(model.liveSessions["s1"]?.projectId, "q")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("condition not met in time") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

/// Native renders of the window with synthetic threads, for design review.
@MainActor
final class NotificationsDesignCaptureTests: XCTestCase {
    func testCaptureNativeDesignStates() async throws {
        guard let path = ProcessInfo.processInfo.environment["NOTIFICATIONS_DESIGN_CAPTURE_DIR"] else {
            throw XCTSkip("Set NOTIFICATIONS_DESIGN_CAPTURE_DIR to capture synthetic native states")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var details: [NotificationThread.Key: NotificationSubjectDetail] = [:]
        var threads: [NotificationThread] = []
        func add(
            _ id: String, _ reason: String, _ repo: String, _ number: Int?, _ title: String, minutes: Double,
            unread: Bool = true, kind: NotificationSubjectKind = .pullRequest, account: String = "octocat",
            state: NotificationSubjectDetail.State? = .open, team: String? = nil
        ) {
            let collection = kind == .issue ? "issues" : "pulls"
            let thread = NotificationThread(
                key: .init(account: account, id: id), unread: unread, reason: NotificationReason(reason),
                updatedAt: now.addingTimeInterval(-minutes * 60), title: title, kind: kind, repository: repo,
                subjectAPIURL: number.map { URL(string: "https://api.github.com/repos/\(repo)/\(collection)/\($0)")! },
                number: number
            )
            threads.append(thread)
            if kind == .pullRequest || kind == .issue {
                var detail = NotificationSubjectDetail(state: state, headRefName: "feature/\(id)")
                if let team { detail.requestedTeams = [team]; detail.viewerTeam = team }
                if reason == "review_requested", team == nil { detail.viewerRequested = true }
                details[thread.key] = detail
            }
        }
        add("1", "review_requested", "sample/workspace", 212, "Add review effort settings to the repository page", minutes: 20)
        add("2", "review_requested", "sample/api", 88, "Accept review effort in the settings API", minutes: 190)
        add("3", "review_requested", "sample/agents", 41, "Remove retired rollout flags", minutes: 2 * 1440, unread: false)
        add("4", "mention", "sample/mobile", 17, "Composer loses focus after sending a message", minutes: 45, kind: .issue)
        add("5", "author", "sample/workspace", 205, "Keep the selected conversation visible", minutes: 10)
        add("6", "author", "sample/automation", 9, "Refresh the target base before publishing", minutes: 300, state: .merged)
        add("7", "comment", "sample/api", 80, "Batch notification reads", minutes: 5 * 1440, unread: false)
        let teamTitles = [
            "Tighten review request routing", "Move inbox polling off the main thread",
            "Group workflow runs by branch", "Explain why a thread is quiet",
            "Cache team membership per organization", "Retry marking threads done",
            "Name the requested team in banners", "Remember the last look across launches",
        ]
        let teamAges: [Double] = [15, 25, 35, 50, 70, 95, 400, 3 * 1440]
        for index in teamTitles.indices {
            add("t\(index)", "review_requested", "sample/web", 330 + index, teamTitles[index], minutes: teamAges[index],
                account: index == 2 ? "hubot" : "octocat", state: index == 6 ? .draft : .open, team: "sample/review-crew")
        }
        add("8", "team_mention", "sample/platform", 77, "Quarterly reliability review", minutes: 1500, kind: .issue)
        add("9", "subscribed", "sample/docs", nil, "Release notes for 2.4", minutes: 9 * 1440, unread: false, kind: .discussion)
        add("10", "subscribed", "sample/infra", 3, "Rotate the staging certificates", minutes: 600, kind: .issue)
        add("11", "ci_activity", "sample/workspace", nil, "CI workflow run failed for main branch", minutes: 30, kind: .checkSuite)
        add("12", "ci_activity", "sample/api", nil, "Deploy workflow run succeeded for main branch", minutes: 1440 * 2, unread: false, kind: .checkSuite)
        let snapshot = WorkspaceSnapshot(hostProcessIdentifier: 4242, selectedProjectId: "p", projects: [
            .init(id: "p", name: "Features and infrastructure improvements", sessions: [
                .init(id: "s1", title: "Keep the selected conversation visible", status: .waiting),
            ]),
        ])
        let workspacePR = try XCTUnwrap(PullRequestKey("sample/workspace#205"))
        for (name, appearance, width, offline, owners) in [
            ("mac-dark", NSAppearance.Name.darkAqua, 1280.0, false, "sample"),
            ("mac-light", .aqua, 1280.0, false, ""),
            ("mac-compact", .darkAqua, 880.0, false, ""),
            ("mac-offline", .aqua, 880.0, true, ""),
            ("mac-all-hidden", .darkAqua, 880.0, false, "elsewhere"),
        ] {
            let workspace = FakeWorkspace(snapshot: snapshot)
            let model = NotificationsModel(
                workspace: workspace, defaults: UserDefaults(suiteName: "notifications-design-\(UUID().uuidString)")!,
                writesState: false, loadAccounts: { throw NotificationsFetchError.notSignedIn },
                transcriptPath: { _ in nil }, openURL: { _ in XCTFail("Capture must not open anything") }
            )
            model.setBadge = { _ in }
            model.owners = owners
            // The linked session sits on your own pull request; the compact
            // capture keeps the defaults to measure the longest default label.
            if name != "mac-compact" { model.hidesYourPullRequests = false }
            await model.pollWorkspace()
            if offline { workspace.answer(fetches: [.unreachable]); await model.pollWorkspace() }
            model.show(
                threads, details: details, accounts: ["octocat", "hubot"], links: [workspacePR: "s1"],
                lookedAt: now.addingTimeInterval(-3600), updated: now.addingTimeInterval(-60),
                truncated: offline ? ["octocat"] : [],
                warning: offline ? "GitHub refresh failed. Showing the last successful results." : nil,
                cleared: Array(threads.prefix(3))
            )
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearance)
            let host = NSHostingView(rootView: NotificationsView(model: model))
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

/// Reads the real inbox of every gh account, without changing anything.
@MainActor
final class NotificationsLiveTests: XCTestCase {
    func testReadsTheLiveInbox() async throws {
        guard ProcessInfo.processInfo.environment["NOTIFICATIONS_LIVE"] == "1" else {
            throw XCTSkip("Set NOTIFICATIONS_LIVE=1 to read the signed-in gh accounts' notifications")
        }
        let model = NotificationsModel(
            workspace: FakeWorkspace(), defaults: UserDefaults(suiteName: "notifications-live-\(UUID().uuidString)")!,
            writesState: false, transcriptPath: { _ in nil }, openURL: { _ in XCTFail("Must not open anything") }
        )
        model.setBadge = { _ in }
        await model.refreshNow()
        XCTAssertEqual(model.phase, .loaded, model.warning ?? "")
        let layout = NotificationLayout(items: model.items)
        for lane in layout.lanes {
            print("live lane \(lane.lane.band.title) / \(lane.lane.title): \(lane.items.count) threads, \(lane.unreadCount) unread")
        }
        let reviews = model.items.filter { $0.thread.reason == .reviewRequested }
        print("live review requests: \(reviews.filter { $0.lane == .reviewRequested }.count) to you, \(reviews.filter { $0.lane == .teamReviewRequested }.count) via teams, \(reviews.filter(\.isClassifying).count) unclassified, \(reviews.filter { $0.detail?.requestHistoryComplete == false }.count) with incomplete history")
        print("live counts: \(model.counts), accounts: \(model.accounts), truncated: \(model.truncatedAccounts)")
        let answered = model.items.filter(\.isAnswered)
        print("live answered (would clear): \(answered.count): " + answered.prefix(8).map(\.thread.shortName).joined(separator: ", "))
        XCTAssertTrue(reviews.allSatisfy { !$0.isClassifying }, "every review request is classified")
    }
}
