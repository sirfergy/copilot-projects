import Foundation
import CopilotProjectsCore

enum PullRequestFetchError: Error, Equatable {
    case cliUnavailable
    case notSignedIn
    case failed(String)

    var title: String {
        switch self {
        case .cliUnavailable: return "GitHub CLI Needed"
        case .notSignedIn: return "Sign In to GitHub"
        case .failed: return "Couldn’t Load Pull Requests"
        }
    }

    var message: String {
        switch self {
        case .cliUnavailable:
            return "Pull requests are read with the accounts you use with gh. Install the GitHub CLI, then run gh auth login."
        case .notSignedIn:
            return "No GitHub account is signed in to gh. Run gh auth login in a terminal, then refresh."
        case .failed(let detail):
            return detail
        }
    }
}

/// A github.com account signed in to `gh`. The token stays in memory.
struct GitHubAccount: Equatable, Sendable {
    let login: String
    let token: String
}

/// Reads the accounts the user already signed in to with the GitHub CLI.
enum GitHubCLI {
    static let host = "github.com"

    static func executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = environment["COPILOT_PROJECTS_GH"], !override.isEmpty {
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")]
        for directory in path + fallbacks {
            let candidate = (directory as NSString).appendingPathComponent("gh")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Logins `gh auth status --json hosts` reports as signed in to github.com,
    /// the active account first.
    static func logins(fromStatus data: Data) -> [String] {
        struct Status: Decodable {
            struct Account: Decodable {
                let login: String?
                let state: String?
                let active: Bool?
            }
            let hosts: [String: [Account]]
        }
        guard let status = try? JSONDecoder().decode(Status.self, from: data) else { return [] }
        let accounts = (status.hosts[host] ?? []).filter { $0.state == "success" && !($0.login ?? "").isEmpty }
        let ordered = accounts.filter { $0.active == true } + accounts.filter { $0.active != true }
        var seen = Set<String>()
        return ordered.compactMap(\.login).filter { seen.insert($0.lowercased()).inserted }
    }

    static func accounts(
        executable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> [GitHubAccount] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        func run(_ arguments: [String]) async throws -> LunaProcess.Result {
            try await LunaProcess.run(
                executable: executable, arguments: arguments, environment: environment,
                directory: home, timeout: 20
            )
        }
        let status = try await run(["auth", "status", "--hostname", host, "--json", "hosts"])
        var logins = logins(fromStatus: Data(status.output.utf8))
        if logins.isEmpty, status.status != 0 || status.output.isEmpty {
            // Older gh without `--json`: the active account is still usable.
            logins = [""]
        }
        var accounts: [GitHubAccount] = []
        for login in logins {
            var arguments = ["auth", "token", "--hostname", host]
            if !login.isEmpty { arguments += ["--user", login] }
            let result = try await run(arguments)
            let token = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, !token.isEmpty, !token.contains(where: \.isWhitespace) else { continue }
            accounts.append(GitHubAccount(login: login, token: token))
        }
        return accounts
    }
}

struct GitHubGraphQLError: Error, Equatable {
    let status: Int?
    let message: String

    var isUnauthorized: Bool { status == 401 }
}

/// A minimal GitHub GraphQL client.
struct GitHubGraphQL: Sendable {
    var endpoint = URL(string: "https://api.github.com/graphql")!
    var timeout: TimeInterval = 30

    struct Response<Payload: Decodable>: Decodable {
        struct Message: Decodable { let message: String? }
        let data: Payload?
        let errors: [Message]?
    }

    func run<Payload: Decodable>(
        _ query: String, variables: [String: Any] = [:], token: String, as type: Payload.Type
    ) async throws -> Response<Payload> {
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("copilot-projects", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw GitHubGraphQLError(status: status, message: status == 401
                ? "GitHub rejected the gh token. Run gh auth login again."
                : "GitHub returned HTTP \(status).")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Response<Payload>.self, from: data)
    }
}

/// The GraphQL shapes pull request fields decode from.
enum PullRequestNodes {
    static let threadFields = """
    fragment ReviewThreadFields on PullRequestReviewThread {
      isResolved isOutdated
      opener: comments(first: 1) { nodes { author { login } } }
      latest: comments(last: 1) { nodes { author { login } } }
    }
    """

    /// The newest review threads come first: they are the ones still open.
    static let fields = """
    fragment PullRequestFields on PullRequest {
      id number title url isDraft state createdAt updatedAt headRefName isMergeQueueEnabled
      author { login }
      repository { nameWithOwner viewerPermission }
      reviewDecision
      autoMergeRequest { enabledAt }
      mergeQueueEntry { state }
      reviewThreads(last: 60) {
        pageInfo { hasPreviousPage startCursor }
        nodes { ...ReviewThreadFields }
      }
      commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
    }
    \(threadFields)
    """

    struct Login: Decodable { let login: String? }
    struct Comments: Decodable { let nodes: [Author?]? }
    struct Author: Decodable { let author: Login? }

    struct Thread: Decodable {
        let isResolved: Bool?
        let isOutdated: Bool?
        let opener: Comments?
        let latest: Comments?
    }

    struct Threads: Decodable {
        struct PageInfo: Decodable { let hasPreviousPage: Bool?; let startCursor: String? }
        let pageInfo: PageInfo?
        let nodes: [Thread?]?

        /// Where the older threads this page left out start; nil when there are none.
        var earlierCursor: String? {
            pageInfo?.hasPreviousPage == true ? pageInfo?.startCursor ?? "" : nil
        }
    }

    /// Open, current threads whose latest comment is someone else's, and how
    /// many of those Copilot code review started.
    static func count(_ threads: [Thread?], viewerLogins: Set<String>) -> (unresolved: Int, copilot: Int) {
        var unresolved = 0
        var copilot = 0
        for thread in threads {
            guard let thread, thread.isResolved == false, thread.isOutdated != true else { continue }
            let latest = thread.latest?.nodes?.last??.author?.login?.lowercased()
            if let latest, viewerLogins.contains(latest) { continue }
            unresolved += 1
            let opener = thread.opener?.nodes?.first??.author?.login?.lowercased() ?? ""
            if opener.hasPrefix("copilot") { copilot += 1 }
        }
        return (unresolved, copilot)
    }

    struct Node: Decodable {
        struct Repository: Decodable { let nameWithOwner: String?; let viewerPermission: String? }
        struct Present: Decodable {}
        struct Rollup: Decodable { let state: String? }
        struct Commit: Decodable { let statusCheckRollup: Rollup? }
        struct CommitNode: Decodable { let commit: Commit? }
        struct Commits: Decodable { let nodes: [CommitNode?]? }

        let id: String?
        let number: Int?
        let title: String?
        let url: String?
        let isDraft: Bool?
        let state: String?
        let createdAt: Date?
        let updatedAt: Date?
        let headRefName: String?
        let isMergeQueueEnabled: Bool?
        let author: Login?
        let repository: Repository?
        let reviewDecision: String?
        let autoMergeRequest: Present?
        let mergeQueueEntry: Present?
        let reviewThreads: Threads?
        let commits: Commits?

        /// Nil for anything that is not a readable, open pull request.
        func snapshot(viewerLogins: Set<String>) -> PullRequestSnapshot? {
            guard let id, let number, let title, let urlText = url, let url = URL(string: urlText),
                  let repository = repository?.nameWithOwner,
                  let key = PullRequestKey(repository: repository, number: number),
                  state == nil || state == "OPEN" else { return nil }
            let threads = PullRequestNodes.count(reviewThreads?.nodes ?? [], viewerLogins: viewerLogins)
            let rollup = commits?.nodes?.last??.commit?.statusCheckRollup?.state
            return PullRequestSnapshot(
                key: key, nodeId: id, repository: repository, title: title, url: url,
                author: author?.login ?? "",
                isDraft: isDraft ?? false,
                createdAt: createdAt ?? .distantPast,
                updatedAt: updatedAt ?? createdAt ?? .distantPast,
                headRefName: headRefName ?? "",
                reviewDecision: reviewDecision.flatMap(PullRequestSnapshot.ReviewDecision.init(rawValue:)),
                checks: rollup.flatMap(PullRequestSnapshot.CheckState.init(rawValue:)),
                unresolvedThreads: threads.unresolved,
                unresolvedCopilotThreads: threads.copilot,
                uncountedThreadsCursor: reviewThreads?.earlierCursor,
                inMergeQueue: mergeQueueEntry != nil,
                autoMergeEnabled: autoMergeRequest != nil,
                isMergeQueueEnabled: isMergeQueueEnabled ?? false,
                // A permission GitHub didn't report can't merge.
                viewerCanMerge: ["ADMIN", "MAINTAIN", "WRITE"].contains(self.repository?.viewerPermission ?? "")
            )
        }
    }
}

/// Open pull requests, plus which account can read each.
struct PullRequestFetch: Sendable {
    var pullRequests: [PullRequestSnapshot] = []
    var tokens: [PullRequestKey: String] = [:]
    var logins: Set<String> = []
    /// Open pull requests the search matched but did not return.
    var omitted = 0
    var warnings: [String] = []

    mutating func add(_ pr: PullRequestSnapshot, token: String) {
        guard tokens[pr.key] == nil else { return }
        pullRequests.append(pr)
        tokens[pr.key] = token
    }
}

struct PullRequestService: Sendable {
    var graphQL = GitHubGraphQL()
    var pageSize = 25
    var maximumPages = 4

    static func isValidOwner(_ owner: String) -> Bool {
        owner.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$"#, options: .regularExpression) != nil
    }

    static func searchQuery(owners: [String]) -> String {
        let scope = owners.filter(isValidOwner).map { "user:\($0)" }
        return (["is:pr", "is:open", "author:@me", "archived:false", "sort:updated-desc"] + scope)
            .joined(separator: " ")
    }

    /// Every account's open pull requests in `owners` (every owner when empty).
    func search(accounts: [GitHubAccount], owners: [String]) async throws -> PullRequestFetch {
        struct Payload: Decodable {
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Search: Decodable { let issueCount: Int; let pageInfo: PageInfo; let nodes: [PullRequestNodes.Node?] }
            let viewer: PullRequestNodes.Login
            let search: Search
        }
        let query = """
        query($q: String!, $first: Int!, $cursor: String) {
          viewer { login }
          search(query: $q, type: ISSUE, first: $first, after: $cursor) {
            issueCount
            pageInfo { hasNextPage endCursor }
            nodes { ...PullRequestFields }
          }
        }
        \(PullRequestNodes.fields)
        """
        let text = Self.searchQuery(owners: owners)
        var fetch = PullRequestFetch()
        var failures: [GitHubGraphQLError] = []
        var accountWarnings: [String] = []
        for account in accounts {
            var cursor: String?
            var found: [PullRequestSnapshot] = []
            var viewer = account.login
            var total = 0
            var hasMore = false
            do {
                for _ in 0..<maximumPages {
                    var variables: [String: Any] = ["q": text, "first": pageSize]
                    if let cursor { variables["cursor"] = cursor }
                    let response = try await graphQL.run(query, variables: variables, token: account.token, as: Payload.self)
                    guard let data = response.data else {
                        throw GitHubGraphQLError(status: nil, message: response.errors?.first?.message ?? "GitHub returned no data.")
                    }
                    viewer = data.viewer.login ?? viewer
                    fetch.logins.insert(viewer.lowercased())
                    if let message = response.errors?.first?.message { fetch.warnings.append(message) }
                    let mine: Set<String> = [viewer.lowercased()]
                    found += data.search.nodes.compactMap { $0?.snapshot(viewerLogins: mine) }
                    total = data.search.issueCount
                    hasMore = data.search.pageInfo.hasNextPage
                    guard hasMore, let next = data.search.pageInfo.endCursor else { break }
                    cursor = next
                }
            } catch {
                let failure = error as? GitHubGraphQLError ?? GitHubGraphQLError(status: nil, message: error.localizedDescription)
                failures.append(failure)
                let name = viewer.isEmpty ? "a signed-in account" : viewer
                accountWarnings.append("Couldn’t read \(name)’s pull requests: \(failure.message)")
                continue
            }
            if hasMore { fetch.omitted += max(0, total - found.count) }
            let mine: Set<String> = [viewer.lowercased()]
            for pr in found where fetch.tokens[pr.key] == nil {
                let counted = await countingEarlierThreads(pr, token: account.token, viewerLogins: mine)
                fetch.add(counted, token: account.token)
            }
        }
        if fetch.logins.isEmpty, let failure = failures.first {
            throw failure.isUnauthorized ? PullRequestFetchError.notSignedIn : PullRequestFetchError.failed(failure.message)
        }
        // Missing an account's pull requests matters more than a partial answer.
        fetch.warnings.insert(contentsOf: accountWarnings, at: 0)
        return fetch
    }

    struct Lookup {
        /// Open pull requests an account here wrote, with the token that read them.
        var found: [(PullRequestSnapshot, String)] = []
        /// Answered and definitely not shown: gone, closed, or someone else's.
        var missing: Set<PullRequestKey> = []
    }

    /// Looks up pull requests named in transcripts; keeps the open ones an
    /// account here wrote. Keys a failed request couldn't answer are in neither list.
    func lookup(_ keys: [PullRequestKey], accounts: [GitHubAccount], logins: Set<String>) async -> Lookup {
        struct Repository: Decodable { let pullRequest: PullRequestNodes.Node? }
        var remaining = keys
        var result = Lookup()
        var unanswered = Set<PullRequestKey>()
        for account in accounts where !remaining.isEmpty {
            var unresolved: [PullRequestKey] = []
            for batch in stride(from: 0, to: remaining.count, by: 20).map({ Array(remaining[$0..<min($0 + 20, remaining.count)]) }) {
                var declarations: [String] = []
                var selections: [String] = []
                var variables: [String: Any] = [:]
                for (index, key) in batch.enumerated() {
                    declarations.append("$o\(index): String!, $r\(index): String!, $n\(index): Int!")
                    selections.append("p\(index): repository(owner: $o\(index), name: $r\(index)) { pullRequest(number: $n\(index)) { ...PullRequestFields } }")
                    variables["o\(index)"] = key.owner
                    variables["r\(index)"] = key.repo
                    variables["n\(index)"] = key.number
                }
                let query = "query(\(declarations.joined(separator: ", "))) {\n\(selections.joined(separator: "\n"))\n}\n\(PullRequestNodes.fields)"
                guard let response = try? await graphQL.run(query, variables: variables, token: account.token, as: [String: Repository?].self),
                      let data = response.data else {
                    unanswered.formUnion(batch)
                    unresolved += batch
                    continue
                }
                for (index, key) in batch.enumerated() {
                    guard let node = data["p\(index)"]??.pullRequest else {
                        unresolved.append(key)
                        continue
                    }
                    guard let author = node.author?.login?.lowercased(), logins.contains(author),
                          let snapshot = node.snapshot(viewerLogins: logins) else { continue }
                    let counted = await countingEarlierThreads(snapshot, token: account.token, viewerLogins: logins)
                    result.found.append((counted, account.token))
                }
            }
            remaining = unresolved
        }
        let found = Set(result.found.map(\.0.key))
        result.missing = Set(keys).subtracting(found).subtracting(unanswered)
        return result
    }

    /// Adds merge state, and which failing checks are required.
    func enrich(_ pullRequests: [PullRequestSnapshot], tokens: [PullRequestKey: String]) async -> [PullRequestSnapshot] {
        await withTaskGroup(of: (Int, PullRequestSnapshot).self) { group in
            var next = 0
            func addNext() {
                guard next < pullRequests.count else { return }
                let index = next
                next += 1
                let pr = pullRequests[index]
                let token = tokens[pr.key]
                group.addTask {
                    guard let token else { return (index, pr) }
                    return (index, await enrich(pr, token: token))
                }
            }
            for _ in 0..<6 { addNext() }
            var result = pullRequests
            for await (index, pr) in group {
                result[index] = pr
                addNext()
            }
            return result
        }
    }

    private func enrich(_ pr: PullRequestSnapshot, token: String) async -> PullRequestSnapshot {
        struct Payload: Decodable {
            struct Node: Decodable { let mergeable: String?; let mergeStateStatus: String? }
            let node: Node?
        }
        var pr = pr
        let query = "query($id: ID!) { node(id: $id) { ... on PullRequest { mergeable mergeStateStatus } } }"
        if let node = try? await graphQL.run(query, variables: ["id": pr.nodeId], token: token, as: Payload.self).data?.node {
            pr.mergeable = node.mergeable.flatMap(PullRequestSnapshot.Mergeable.init(rawValue:)) ?? .unknown
            pr.mergeState = node.mergeStateStatus.flatMap(PullRequestSnapshot.MergeState.init(rawValue:)) ?? .unknown
        } else {
            pr.mergeStateFailed = true
        }
        if pr.checksFailing {
            pr.failingRequiredChecks = await failingRequiredChecks(pr, token: token)
        }
        return pr
    }

    /// Counts the review threads older than the first page, so a long review
    /// can't hide an open thread. Leaves `uncountedThreadsCursor` set when it can't.
    func countingEarlierThreads(
        _ pr: PullRequestSnapshot, token: String, viewerLogins: Set<String>
    ) async -> PullRequestSnapshot {
        struct Payload: Decodable {
            struct Node: Decodable { let reviewThreads: PullRequestNodes.Threads? }
            let node: Node?
        }
        let query = """
        query($id: ID!, $cursor: String!) {
          node(id: $id) { ... on PullRequest {
            reviewThreads(last: 100, before: $cursor) {
              pageInfo { hasPreviousPage startCursor }
              nodes { ...ReviewThreadFields }
            }
          } }
        }
        \(PullRequestNodes.threadFields)
        """
        var pr = pr
        for _ in 0..<10 {
            guard let cursor = pr.uncountedThreadsCursor, !cursor.isEmpty,
                  let response = try? await graphQL.run(
                      query, variables: ["id": pr.nodeId, "cursor": cursor], token: token, as: Payload.self
                  ),
                  let threads = response.data?.node?.reviewThreads else { return pr }
            let counts = PullRequestNodes.count(threads.nodes ?? [], viewerLogins: viewerLogins)
            pr.unresolvedThreads += counts.unresolved
            pr.unresolvedCopilotThreads += counts.copilot
            pr.uncountedThreadsCursor = threads.earlierCursor
        }
        return pr
    }

    static let failingConclusions: Set<String> = [
        "FAILURE", "ERROR", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE",
    ]

    /// Names of failing checks the base branch requires; nil when they can't be read.
    private func failingRequiredChecks(_ pr: PullRequestSnapshot, token: String) async -> [String]? {
        struct Payload: Decodable {
            struct Context: Decodable {
                let name: String?
                let context: String?
                let conclusion: String?
                let state: String?
                let isRequired: Bool?
            }
            struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
            struct Contexts: Decodable { let pageInfo: PageInfo; let nodes: [Context?] }
            struct Rollup: Decodable { let contexts: Contexts }
            struct Commit: Decodable { let statusCheckRollup: Rollup? }
            struct CommitNode: Decodable { let commit: Commit }
            struct Commits: Decodable { let nodes: [CommitNode?] }
            struct Node: Decodable { let commits: Commits? }
            let node: Node?
        }
        let query = """
        query($id: ID!, $n: Int!, $cursor: String) {
          node(id: $id) { ... on PullRequest { commits(last: 1) { nodes { commit { statusCheckRollup {
            contexts(first: 100, after: $cursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                ... on CheckRun { name conclusion isRequired(pullRequestNumber: $n) }
                ... on StatusContext { context state isRequired(pullRequestNumber: $n) }
              }
            }
          } } } } } }
        }
        """
        var failing: [String] = []
        var cursor: String?
        for _ in 0..<10 {
            var variables: [String: Any] = ["id": pr.nodeId, "n": pr.key.number]
            if let cursor { variables["cursor"] = cursor }
            guard let response = try? await graphQL.run(query, variables: variables, token: token, as: Payload.self),
                  let contexts = response.data?.node?.commits?.nodes.last??.commit.statusCheckRollup?.contexts else {
                return nil
            }
            for context in contexts.nodes.compactMap({ $0 }) where context.isRequired == true {
                let outcome = context.conclusion ?? context.state ?? ""
                if Self.failingConclusions.contains(outcome) {
                    failing.append(context.name ?? context.context ?? "Check")
                }
            }
            guard contexts.pageInfo.hasNextPage, let next = contexts.pageInfo.endCursor else { return failing }
            cursor = next
        }
        return failing
    }
}
