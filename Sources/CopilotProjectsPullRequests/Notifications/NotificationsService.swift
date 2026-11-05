import Foundation

/// GitHub's notifications REST API, called with the gh token of each account.
struct GitHubNotificationsAPI: Sendable {
    var base = URL(string: "https://api.github.com")!
    var timeout: TimeInterval = 30
    var send: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    struct Failure: Error, Equatable, LocalizedError {
        let status: Int?
        let message: String

        var isUnauthorized: Bool { status == 401 }
        var errorDescription: String? { message }
    }

    struct Page: Sendable {
        let threads: [NotificationThread]
        let next: URL?
        /// The number of the last page, when GitHub says.
        var lastPage: Int? = nil
        let lastModified: String?
        let pollInterval: TimeInterval?
    }

    enum Listing: Sendable {
        case page(Page)
        /// Nothing changed since `If-Modified-Since`; GitHub may still ask for a longer gap.
        case notModified(pollInterval: TimeInterval?)
    }

    func list(
        account: GitHubAccount, query: [URLQueryItem], ifModifiedSince: String? = nil
    ) async throws -> Listing {
        var components = URLComponents(url: base.appendingPathComponent("notifications"), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        return try await list(account: account, url: components.url!, ifModifiedSince: ifModifiedSince)
    }

    func list(account: GitHubAccount, url: URL, ifModifiedSince: String? = nil) async throws -> Listing {
        // Page links come from a response header; the token only goes to the API itself.
        guard url.scheme?.lowercased() == base.scheme?.lowercased(), url.host?.lowercased() == base.host?.lowercased(),
              url.port == base.port else {
            throw Failure(status: nil, message: "GitHub returned a page link outside \(base.host ?? "its API"); it wasn’t followed.")
        }
        var request = self.request(url, account: account, method: "GET")
        if let ifModifiedSince { request.setValue(ifModifiedSince, forHTTPHeaderField: "If-Modified-Since") }
        // A conditional poll must reach GitHub, never a local cache's answer.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 304 {
            return .notModified(pollInterval: http?.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init))
        }
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let link = http?.value(forHTTPHeaderField: "Link")
        return .page(Page(
            threads: try Self.decode(data, account: account.login),
            next: Self.link("next", in: link),
            lastPage: Self.link("last", in: link).flatMap(Self.pageNumber),
            lastModified: http?.value(forHTTPHeaderField: "Last-Modified"),
            pollInterval: http?.value(forHTTPHeaderField: "X-Poll-Interval").flatMap(TimeInterval.init)
        ))
    }

    /// The thread as GitHub has it now.
    func thread(account: GitHubAccount, threadId: String) async throws -> NotificationThread {
        var request = request(base.appendingPathComponent("notifications/threads/\(threadId)"), account: account, method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Self.failure(status: status, data: data) }
        let array = Data("[".utf8) + data + Data("]".utf8)
        guard let thread = try Self.decode(array, account: account.login).first else {
            throw Failure(status: status, message: "GitHub returned no thread \(threadId).")
        }
        return thread
    }

    /// Marks the thread read on GitHub, as opening it there would.
    func markRead(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)", method: "PATCH")
    }

    /// Marks the thread done: it leaves the inbox until something new happens on it.
    func markDone(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)", method: "DELETE")
    }

    /// Ignores the thread: no more notifications from it, even in a watched
    /// repository, unless the user is mentioned or asked again.
    func unsubscribe(account: GitHubAccount, threadId: String) async throws {
        try await act(account: account, path: "notifications/threads/\(threadId)/subscription", method: "PUT",
                      body: Data(#"{"ignored":true}"#.utf8))
    }

    private func act(account: GitHubAccount, path: String, method: String, body: Data? = nil) async throws {
        var request = request(base.appendingPathComponent(path), account: account, method: method)
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Self.failure(status: status, data: data) }
    }

    private func request(_ url: URL, account: GitHubAccount, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(account.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("copilot-projects", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func failure(status: Int, data: Data) -> Failure {
        struct Body: Decodable { let message: String? }
        let detail = (try? JSONDecoder().decode(Body.self, from: data))?.message
        switch status {
        case 401: return Failure(status: status, message: "GitHub rejected the gh token. Run gh auth login again.")
        case 403 where detail?.localizedCaseInsensitiveContains("rate limit") == true:
            return Failure(status: status, message: "GitHub’s rate limit was reached. Notifications refresh again shortly.")
        default:
            return Failure(status: status, message: detail.map { "GitHub returned HTTP \(status): \($0)" } ?? "GitHub returned HTTP \(status).")
        }
    }

    private struct Thread: Decodable {
        struct Subject: Decodable {
            let title: String?
            let url: String?
            let type: String?
        }
        struct Repository: Decodable {
            let full_name: String
        }
        let id: String
        let unread: Bool
        let reason: String
        let updated_at: Date
        let last_read_at: Date?
        let subject: Subject
        let repository: Repository
    }

    static func decode(_ data: Data, account: String) throws -> [NotificationThread] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Thread].self, from: data).map { thread in
            let apiURL = thread.subject.url.flatMap(URL.init(string:))
            return NotificationThread(
                key: .init(account: account, id: thread.id), unread: thread.unread,
                reason: NotificationReason(thread.reason), updatedAt: thread.updated_at,
                lastReadAt: thread.last_read_at, title: thread.subject.title ?? "", kind: NotificationSubjectKind(thread.subject.type ?? ""),
                repository: thread.repository.full_name, subjectAPIURL: apiURL,
                number: NotificationThread.number(apiURL: apiURL)
            )
        }
    }

    /// The `rel="next"` URL of a `Link` header.
    static func nextLink(_ header: String?) -> URL? { link("next", in: header) }

    static func link(_ relation: String, in header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2, pieces.dropFirst().contains(where: { $0 == "rel=\"\(relation)\"" }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">") else { continue }
            return URL(string: String(pieces[0].dropFirst().dropLast()))
        }
        return nil
    }

    static func pageNumber(_ url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value.flatMap(Int.init)
    }

    /// `url` asking for page `number` instead.
    static func page(_ number: Int, of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "page" } + [URLQueryItem(name: "page", value: "\(number)")]
        return components.url
    }
}

/// How much of an inbox one refresh reads. A busy inbox gains hundreds of
/// threads a day, mostly CI, so the passes favor what reached the user.
struct NotificationsFetchPlan: Equatable, Sendable {
    /// Unread threads the user takes part in: reviews, mentions, their own work.
    var participatingPages = 20
    /// The newest unread threads of every kind, for watched repositories and CI.
    var unreadPages = 4
    /// Recently read threads, so All shows what was opened. GitHub lists done
    /// threads here too, with nothing to tell them apart; the model hides the
    /// ones it marked done.
    var readPages = 4
    var readWindow: TimeInterval = 3 * 86_400
    var perPage = 50

    struct Result: Sendable {
        var threads: [NotificationThread]
        /// Unread threads exist beyond the newest pages read.
        var truncated: Bool
    }

    func fetch(account: GitHubAccount, api: GitHubNotificationsAPI, now: Date) async throws -> Result {
        let since = ISO8601DateFormatter().string(from: now.addingTimeInterval(-readWindow))
        async let participating = pages(account, api, [("participating", "true")], limit: participatingPages)
        async let unread = pages(account, api, [], limit: unreadPages)
        async let read = pages(account, api, [("all", "true"), ("since", since)], limit: readPages)
        let passes = try await [participating, unread, read]
        var merged: [String: NotificationThread] = [:]
        for thread in passes.flatMap(\.threads) {
            if let existing = merged[thread.key.id], existing.updatedAt >= thread.updatedAt { continue }
            merged[thread.key.id] = thread
        }
        return Result(threads: Array(merged.values), truncated: passes[0].truncated || passes[1].truncated)
    }

    /// The first page, then the rest up to `limit` at once when GitHub says
    /// how many there are, else one after another.
    private func pages(
        _ account: GitHubAccount, _ api: GitHubNotificationsAPI, _ query: [(String, String)], limit: Int
    ) async throws -> Result {
        guard case .page(let first) = try await api.list(
            account: account, query: query.map(URLQueryItem.init) + [URLQueryItem(name: "per_page", value: "\(perPage)")]
        ) else { return Result(threads: [], truncated: false) }
        guard let next = first.next else { return Result(threads: first.threads, truncated: false) }
        guard limit > 1 else { return Result(threads: first.threads, truncated: true) }
        if let last = first.lastPage {
            let urls = (2...max(2, min(last, limit))).compactMap { GitHubNotificationsAPI.page($0, of: next) }
            let rest = try await withThrowingTaskGroup(of: [NotificationThread].self) { group in
                for url in urls {
                    group.addTask {
                        if case .page(let page) = try await api.list(account: account, url: url) { return page.threads }
                        return []
                    }
                }
                var threads: [NotificationThread] = []
                for try await page in group { threads += page }
                return threads
            }
            return Result(threads: first.threads + rest, truncated: last > limit)
        }
        var threads = first.threads
        var url: URL? = next
        var read = 1
        while let current = url {
            guard read < limit else { return Result(threads: threads, truncated: true) }
            guard case .page(let page) = try await api.list(account: account, url: current) else { break }
            threads += page.threads
            read += 1
            url = page.next
        }
        return Result(threads: threads, truncated: false)
    }
}

/// Reads who was asked to review each pull request, and each subject's state,
/// in batched GraphQL queries.
struct NotificationDetailsFetcher: Sendable {
    var graphQL = GitHubGraphQL()
    /// Subjects per query. With more, GitHub silently returns some subjects'
    /// timelines empty, without an error, which reads as nobody asked: 20
    /// emptied 22 of 269 live review requests, 10 emptied 2, and 5 none.
    var batchSize = 5
    /// Batches in flight at once for one account.
    var concurrency = 4
    /// Answers in place of GitHub, for tests.
    var answer: (@Sendable ([NotificationThread], GitHubAccount) async -> Result)? = nil

    struct Result: Sendable {
        var details: [NotificationThread.Key: NotificationSubjectDetail]
        /// Threads GitHub answered for, with or without a subject it could show.
        var settled: Set<NotificationThread.Key>
        var viewerLogin: String?
        /// Subjects GitHub reported an error inside, or may have; read them again.
        var erred: Set<NotificationThread.Key> = []
    }

    /// Threads that ask something of the user need who was asked and whether
    /// they've answered since; everything else needs only its state.
    static let subjectFragment = """
    fragment Subject on IssueOrPullRequest {
      ... on PullRequest { state isDraft headRefName }
      ... on Issue { state stateReason }
    }
    """

    /// Who was asked and when, what the user did, and the text since: GitHub
    /// records no event for a mention inside a review, a review comment, or of
    /// a team, so the text itself is read for those.
    static let engagedFragment = """
    fragment Engaged on IssueOrPullRequest {
      ... on PullRequest {
        state isDraft headRefName createdAt body lastEditedAt author { login }
        timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 100) {
          pageInfo { hasPreviousPage startCursor }
          nodes { ... on ReviewRequestedEvent { requestedReviewer {
            __typename ... on User { login } ... on Team { slug organization { login } }
          } } }
        }
        prActivity: timelineItems(itemTypes: [MENTIONED_EVENT, ASSIGNED_EVENT, REVIEW_REQUESTED_EVENT, ISSUE_COMMENT, MERGED_EVENT, CLOSED_EVENT], last: 60) {
          pageInfo { hasPreviousPage }
          nodes { __typename ...Activity }
        }
        reviews(last: 20) {
          pageInfo { hasPreviousPage }
          nodes {
            submittedAt state body lastEditedAt author { login }
            comments(last: 20) { pageInfo { hasPreviousPage } nodes { createdAt body lastEditedAt author { login } } }
          }
        }
        pending: reviewRequests(first: 100) {
          pageInfo { hasNextPage endCursor }
          nodes { requestedReviewer {
            __typename ... on User { login } ... on Team { slug organization { login } }
          } }
        }
      }
      ... on Issue {
        state stateReason createdAt body lastEditedAt author { login }
        issueActivity: timelineItems(itemTypes: [MENTIONED_EVENT, ASSIGNED_EVENT, ISSUE_COMMENT, CLOSED_EVENT], last: 60) {
          pageInfo { hasPreviousPage }
          nodes { __typename ...Activity }
        }
      }
    }
    fragment Activity on Node {
      ... on MentionedEvent { createdAt actor { login } }
      ... on AssignedEvent { createdAt assignee { ... on User { login } } }
      ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } ... on Team { slug organization { login } } } }
      ... on IssueComment { createdAt body lastEditedAt author { login } }
      ... on MergedEvent { createdAt actor { login } }
      ... on ClosedEvent { createdAt actor { login } }
    }
    """

    struct Login: Decodable { let login: String? }
    struct Reviewer: Decodable {
        let __typename: String?
        let login: String?
        let slug: String?
        let organization: Login?
    }
    struct Event: Decodable { let requestedReviewer: Reviewer? }
    struct Timeline: Decodable {
        struct PageInfo: Decodable { let hasPreviousPage: Bool?; var startCursor: String? = nil }
        var pageInfo: PageInfo?
        var nodes: [Event?]?
    }
    struct PageInfo: Decodable { let hasPreviousPage: Bool? }
    /// Something that asked for the user, or that they did.
    struct ActivityEvent: Decodable {
        let __typename: String?
        let createdAt: Date?
        let actor: Login?
        let author: Login?
        let assignee: Login?
        let requestedReviewer: Reviewer?
        var body: String? = nil
        var lastEditedAt: Date? = nil
    }
    struct Activity: Decodable {
        var pageInfo: PageInfo? = nil
        let nodes: [ActivityEvent?]?
    }
    struct ReviewComment: Decodable {
        let createdAt: Date?
        let body: String?
        var lastEditedAt: Date? = nil
        let author: Login?
    }
    struct ReviewComments: Decodable {
        var pageInfo: PageInfo? = nil
        let nodes: [ReviewComment?]?
    }
    struct Review: Decodable {
        let submittedAt: Date?
        let state: String?
        var body: String? = nil
        var lastEditedAt: Date? = nil
        let author: Login?
        var comments: ReviewComments? = nil
    }
    struct Reviews: Decodable {
        var pageInfo: PageInfo? = nil
        let nodes: [Review?]?
    }
    /// The review requests still open; GitHub drops one once it's reviewed or withdrawn.
    struct PendingRequests: Decodable {
        struct PageInfo: Decodable { let hasNextPage: Bool?; var endCursor: String? = nil }
        var pageInfo: PageInfo?
        var nodes: [Event?]?
    }
    struct Subject: Decodable {
        let state: String?
        let isDraft: Bool?
        let headRefName: String?
        let stateReason: String?
        var timelineItems: Timeline?
        var createdAt: Date? = nil
        var body: String? = nil
        var lastEditedAt: Date? = nil
        var author: Login? = nil
        var prActivity: Activity? = nil
        var issueActivity: Activity? = nil
        var reviews: Reviews? = nil
        var pending: PendingRequests? = nil
    }
    /// Each alias: a repository holding the subject, or the viewer.
    struct Node: Decodable {
        let login: String?
        var issueOrPullRequest: Subject?
    }
    /// A batch's answer, and which of its subjects (by index) GitHub reported
    /// an error inside; nil when an error can't be placed, so any may be.
    typealias Answer = (nodes: [String: Node?], erred: Set<Int>?)

    func details(
        for threads: [NotificationThread], account: GitHubAccount
    ) async -> Result {
        if let answer { return await answer(threads, account) }
        let subjects = threads.filter { ($0.kind == .pullRequest || $0.kind == .issue) && $0.number != nil }
        let batches = stride(from: 0, to: subjects.count, by: batchSize).map {
            Array(subjects[$0..<min($0 + batchSize, subjects.count)])
        }
        var result = Result(details: [:], settled: [], viewerLogin: account.login.isEmpty ? nil : account.login)
        var answers: [([NotificationThread], Answer)] = []
        await withTaskGroup(of: ([NotificationThread], Answer?).self) { group in
            var next = 0
            func addNext() {
                guard next < batches.count else { return }
                let batch = batches[next]
                next += 1
                group.addTask {
                    // Awaited before the tuple is built, as the inbox refresh must be.
                    let answer = await query(batch, account: account)
                    return (batch, answer)
                }
            }
            for _ in 0..<concurrency { addNext() }
            for await (batch, answer) in group {
                if let answer { answers.append((batch, answer)) }
                addNext()
            }
        }
        if result.viewerLogin == nil {
            result.viewerLogin = answers.lazy.compactMap { $0.1.nodes["viewer"]??.login }.first
        }
        for (batch, answer) in answers {
            for (index, thread) in batch.enumerated() {
                result.settled.insert(thread.key)
                guard let subject = answer.nodes["t\(index)"]??.issueOrPullRequest else { continue }
                var detail = Self.detail(subject, viewer: result.viewerLogin)
                // What GitHub failed to read may have asked again: it's never
                // answered, and a request it may have left out isn't withdrawn.
                if answer.erred?.contains(index) != false {
                    detail.viewerActedAt = nil
                    detail.pendingReviewers = nil
                    result.erred.insert(thread.key)
                }
                result.details[thread.key] = detail
            }
        }
        return result
    }

    private func query(_ batch: [NotificationThread], account: GitHubAccount) async -> Answer? {
        var declarations: [String] = []
        var fields = ["viewer { login }"]
        var variables: [String: Any] = [:]
        // GitHub refuses a query that defines a fragment it doesn't use.
        var used: Set<String> = []
        for (index, thread) in batch.enumerated() {
            let parts = thread.repository.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let number = thread.number else { continue }
            let fragment = NotificationItem.answerableReasons.contains(thread.reason) ? "Engaged" : "Subject"
            used.insert(fragment)
            declarations += ["$o\(index): String!", "$r\(index): String!", "$n\(index): Int!"]
            fields.append("t\(index): repository(owner: $o\(index), name: $r\(index)) { issueOrPullRequest(number: $n\(index)) { ...\(fragment) } }")
            variables["o\(index)"] = parts[0]
            variables["r\(index)"] = parts[1]
            variables["n\(index)"] = number
        }
        let header = declarations.isEmpty ? "" : "(\(declarations.joined(separator: ", ")))"
        let fragments = [used.contains("Subject") ? Self.subjectFragment : nil, used.contains("Engaged") ? Self.engagedFragment : nil]
        let text = "query\(header) {\n\(fields.joined(separator: "\n"))\n}\n" + fragments.compactMap { $0 }.joined(separator: "\n")
        do {
            // Partial answers are kept: a subject GitHub won't show settles without detail.
            let response = try await graphQL.run(text, variables: variables, token: account.token, as: [String: Node?].self)
            guard var nodes = response.data else { return nil }
            var erred: Set<Int>? = []
            for error in response.errors ?? [] {
                if case .field(let alias)? = error.path?.first, alias.hasPrefix("t"), let index = Int(alias.dropFirst()) {
                    erred?.insert(index)
                } else {
                    erred = nil
                }
            }
            for (index, thread) in batch.enumerated() where erred?.contains(index) == false && thread.reason == .reviewRequested {
                guard let subject = nodes["t\(index)"]??.issueOrPullRequest else { continue }
                let (completed, pageErred) = await completeReviewRequests(subject, thread: thread, token: account.token)
                var node = nodes["t\(index)"] ?? nil
                node?.issueOrPullRequest = completed
                nodes["t\(index)"] = node
                if pageErred { erred?.insert(index) }
            }
            return (nodes, erred)
        } catch {
            NSLog("copilot-notifications: subject details failed for \(account.login): \(error)")
            return nil
        }
    }

    /// Reads any older `ReviewRequestedEvent` pages and remaining pending
    /// `reviewRequests` pages so large CODEOWNERS fanouts (>100 requests) don't
    /// leave team review requests misclassified under To you or un-withdrawn.
    private func completeReviewRequests(
        _ subject: Subject, thread: NotificationThread, token: String
    ) async -> (Subject, Bool) {
        let parts = thread.repository.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let number = thread.number else { return (subject, false) }
        var subject = subject
        var erred = false
        struct Payload: Decodable {
            struct Repository: Decodable { let pullRequest: Subject? }
            let repository: Repository?
        }
        if subject.timelineItems?.pageInfo?.hasPreviousPage == true {
            let query = """
            query($owner: String!, $name: String!, $number: Int!, $cursor: String!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 100, before: $cursor) {
                    pageInfo { hasPreviousPage startCursor }
                    nodes { ... on ReviewRequestedEvent { requestedReviewer {
                      __typename ... on User { login } ... on Team { slug organization { login } }
                    } } }
                  }
                }
              }
            }
            """
            var seen: Set<String> = []
            for _ in 0..<10 where subject.timelineItems?.pageInfo?.hasPreviousPage == true {
                guard let existing = subject.timelineItems?.nodes,
                      let cursor = subject.timelineItems?.pageInfo?.startCursor, !cursor.isEmpty,
                      seen.insert(cursor).inserted,
                      let response = try? await graphQL.run(
                          query, variables: ["owner": parts[0], "name": parts[1], "number": number, "cursor": cursor],
                          token: token, as: Payload.self
                      ),
                      response.errors?.isEmpty != false,
                      let page = response.data?.repository?.pullRequest?.timelineItems,
                      let pageNodes = page.nodes else {
                    erred = true
                    break
                }
                subject.timelineItems?.nodes = pageNodes + existing
                subject.timelineItems?.pageInfo = page.pageInfo
            }
        }
        if subject.pending?.pageInfo?.hasNextPage == true {
            let query = """
            query($owner: String!, $name: String!, $number: Int!, $cursor: String!) {
              repository(owner: $owner, name: $name) {
                pullRequest(number: $number) {
                  pending: reviewRequests(first: 100, after: $cursor) {
                    pageInfo { hasNextPage endCursor }
                    nodes { requestedReviewer {
                      __typename ... on User { login } ... on Team { slug organization { login } }
                    } }
                  }
                }
              }
            }
            """
            var seen: Set<String> = []
            for _ in 0..<10 where subject.pending?.pageInfo?.hasNextPage == true {
                guard let existing = subject.pending?.nodes,
                      let cursor = subject.pending?.pageInfo?.endCursor, !cursor.isEmpty,
                      seen.insert(cursor).inserted,
                      let response = try? await graphQL.run(
                          query, variables: ["owner": parts[0], "name": parts[1], "number": number, "cursor": cursor],
                          token: token, as: Payload.self
                      ),
                      response.errors?.isEmpty != false,
                      let page = response.data?.repository?.pullRequest?.pending,
                      let pageNodes = page.nodes else {
                    erred = true
                    break
                }
                subject.pending?.nodes = existing + pageNodes
                subject.pending?.pageInfo = page.pageInfo
            }
        }
        return (subject, erred)
    }

    /// Every pending review request, as lowercased logins and `org/slug` teams;
    /// nil unless the whole list was read and every reviewer named. Bots can't
    /// be the user or a team of theirs, so they don't count; anything else that
    /// can't be named (an enterprise team, say) might be theirs.
    static func pendingReviewers(_ pending: PendingRequests?) -> Set<String>? {
        guard let pending, pending.pageInfo?.hasNextPage == false, let nodes = pending.nodes else { return nil }
        var names: Set<String> = []
        for node in nodes {
            guard let reviewer = node?.requestedReviewer else { return nil }
            switch reviewer.__typename {
            case "User":
                guard let login = reviewer.login else { return nil }
                names.insert(login.lowercased())
            case "Team":
                guard let slug = reviewer.slug, let org = reviewer.organization?.login else { return nil }
                names.insert("\(org)/\(slug)".lowercased())
            case "Bot":
                continue
            default:
                return nil
            }
        }
        return names
    }

    static func detail(_ subject: Subject, viewer: String?) -> NotificationSubjectDetail {
        var detail = NotificationSubjectDetail()
        switch (subject.state, subject.isDraft, subject.stateReason) {
        case ("OPEN", true, _): detail.state = .draft
        case ("OPEN", _, _): detail.state = .open
        case ("MERGED", _, _): detail.state = .merged
        case ("CLOSED", _, "COMPLETED"): detail.state = .completed
        case ("CLOSED", _, "NOT_PLANNED"): detail.state = .notPlanned
        case ("CLOSED", _, _): detail.state = .closed
        default: break
        }
        detail.headRefName = subject.headRefName
        let reviewers = (subject.timelineItems?.nodes ?? []).compactMap { $0?.requestedReviewer }.reversed()
        let viewer = viewer?.lowercased()
        var teams: [String] = []
        for reviewer in reviewers {
            if reviewer.__typename == "User", let login = reviewer.login?.lowercased(), login == viewer {
                detail.viewerRequested = true
            } else if reviewer.__typename == "Team", let slug = reviewer.slug, let org = reviewer.organization?.login {
                let name = "\(org)/\(slug)"
                if !teams.contains(name) { teams.append(name) }
            }
        }
        detail.requestedTeams = teams
        // Older requests weren't read: a direct one may be among them.
        if !detail.viewerRequested, subject.timelineItems?.pageInfo?.hasPreviousPage == true {
            detail.requestHistoryComplete = false
        }
        detail.pendingReviewers = pendingReviewers(subject.pending)
        guard let viewer else { return detail }
        func latest(_ current: Date?, _ candidate: Date?) -> Date? {
            guard let candidate else { return current }
            return current.map { max($0, candidate) } ?? candidate
        }
        func isViewer(_ login: Login?) -> Bool { login?.login?.lowercased() == viewer }
        func targetViewer(_ at: Date?) { detail.viewerTargetedAt = latest(detail.viewerTargetedAt, at) }
        func targetTeam(_ team: String, _ at: Date?) { detail.teamTargetedAt[team] = latest(detail.teamTargetedAt[team], at) }
        func acted(_ at: Date?) { detail.viewerActedAt = latest(detail.viewerActedAt, at) }
        /// Someone else's text: a mention of the user or a team, as of its last edit.
        func read(_ body: String?, by author: Login?, at: Date?, edited: Date?) {
            guard let body, !isViewer(author) else { return }
            let when = latest(at, edited)
            let found = mentions(in: body)
            if found.users.contains(viewer) { targetViewer(when) }
            for team in found.teams { targetTeam(team, when) }
        }
        read(subject.body, by: subject.author, at: subject.createdAt, edited: subject.lastEditedAt)
        // Each history is its newest stretch. Where it was cut short, nothing
        // before its oldest entry is known, so that point counts as an ask.
        for activity in [subject.prActivity, subject.issueActivity].compactMap({ $0 }) {
            let events = (activity.nodes ?? []).compactMap { $0 }
            if activity.pageInfo?.hasPreviousPage == true { targetViewer(events.compactMap(\.createdAt).min()) }
            for event in events {
                switch event.__typename {
                case "MentionedEvent" where isViewer(event.actor),
                     "AssignedEvent" where isViewer(event.assignee):
                    targetViewer(event.createdAt)
                case "ReviewRequestedEvent":
                    guard let reviewer = event.requestedReviewer else { continue }
                    if reviewer.__typename == "User", reviewer.login?.lowercased() == viewer {
                        targetViewer(event.createdAt)
                    } else if reviewer.__typename == "Team", let slug = reviewer.slug, let org = reviewer.organization?.login {
                        targetTeam("\(org)/\(slug)".lowercased(), event.createdAt)
                    }
                case "IssueComment":
                    if isViewer(event.author) { acted(event.createdAt) }
                    read(event.body, by: event.author, at: event.createdAt, edited: event.lastEditedAt)
                case "MergedEvent" where isViewer(event.actor),
                     "ClosedEvent" where isViewer(event.actor):
                    acted(event.createdAt)
                default:
                    continue
                }
            }
        }
        // Reviews, read directly: the timeline leaves out replies made inline.
        if let reviews = subject.reviews {
            let nodes = (reviews.nodes ?? []).compactMap { $0 }
            if reviews.pageInfo?.hasPreviousPage == true { targetViewer(nodes.compactMap(\.submittedAt).min()) }
            for review in nodes where review.state != "PENDING" {
                if isViewer(review.author) {
                    acted(review.submittedAt)
                    continue
                }
                read(review.body, by: review.author, at: review.submittedAt, edited: review.lastEditedAt)
                for comment in (review.comments?.nodes ?? []).compactMap({ $0 }) {
                    // A comment drafted in a pending review asks only once the review is sent.
                    read(comment.body, by: comment.author, at: latest(comment.createdAt, review.submittedAt), edited: comment.lastEditedAt)
                }
                // Comments this review holds beyond those read may mention the user.
                if review.comments?.pageInfo?.hasPreviousPage == true { targetViewer(review.submittedAt) }
            }
        }
        return detail
    }

    private static let mentionPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_`/.-])@([A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)(?:/([A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9_]|[A-Za-z0-9]))?(?![A-Za-z0-9_-])"#
    )

    /// The logins and `org/team` names `@`-mentioned in `text`, lowercased.
    static func mentions(in text: String) -> (users: Set<String>, teams: Set<String>) {
        var users: Set<String> = []
        var teams: Set<String> = []
        let range = NSRange(text.startIndex..., in: text)
        for match in mentionPattern.matches(in: text, range: range) {
            guard let login = Range(match.range(at: 1), in: text).map({ String(text[$0]).lowercased() }) else { continue }
            if let slug = Range(match.range(at: 2), in: text).map({ String(text[$0]).lowercased() }) {
                teams.insert("\(login)/\(slug)")
            } else {
                users.insert(login)
            }
        }
        return (users, teams)
    }

    /// The teams in `organization` the viewer is on, and whether that list is
    /// the whole of it; only a whole list can say they're not on a team.
    func viewerTeams(organization: String, account: GitHubAccount, login: String) async -> (teams: Set<String>, complete: Bool)? {
        struct Teams: Decodable {
            struct Organization: Decodable {
                struct Connection: Decodable {
                    struct PageInfo: Decodable { let hasNextPage: Bool? }
                    let pageInfo: PageInfo?
                    let nodes: [Login?]?
                }
                let teams: Connection?
            }
            let organization: Organization?
        }
        // Each team's slug arrives as `login` so it decodes like the other names.
        let text = """
        query($org: String!, $login: String!) {
          organization(login: $org) { teams(first: 100, userLogins: [$login]) { pageInfo { hasNextPage } nodes { login: slug } } }
        }
        """
        guard let response = try? await graphQL.run(
            text, variables: ["org": organization, "login": login], token: account.token, as: Teams.self
        ), let connection = response.data?.organization?.teams, let nodes = connection.nodes else { return nil }
        let teams = Set(nodes.compactMap { $0?.login.map { "\(organization)/\($0)".lowercased() } })
        // An error or an unnamed team leaves the list short, however it was paged.
        let whole = connection.pageInfo?.hasNextPage == false && response.errors?.isEmpty != false
            && nodes.allSatisfy { $0?.login != nil }
        return (teams, whole)
    }
}
