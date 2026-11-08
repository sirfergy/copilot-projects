import AppKit
import Foundation
import CopilotProjectsCore

/// What the Pull Requests app knows about the Copilot Projects workspace.
enum WorkspaceState: Equatable, Sendable {
    /// Before Copilot Projects first answers.
    case connecting
    case connected(WorkspaceSnapshot)
    /// Copilot Projects isn't answering. Its last snapshot, if it ever sent one,
    /// still groups pull requests, but session states are unknown.
    case disconnected(lastGood: WorkspaceSnapshot?)
}

enum WorkspaceFetch: Equatable, Sendable {
    case snapshot(WorkspaceSnapshot)
    case unreachable
}

/// How Copilot Projects answered a command.
enum WorkspaceCommandResult: Equatable, Sendable {
    case done(code: String?, text: String?)
    case refused(code: String?, message: String)
    case unreachable
}

/// The workspace the Pull Requests app reads sessions from and acts on.
protocol PullRequestsWorkspace: Sendable {
    /// The host state directory (`state.json` and `sessions/`) whose changes
    /// trigger workspace refreshes; nil when not backed by a local state directory.
    var stateDirectory: URL? { get }
    func snapshot() async -> WorkspaceFetch
    /// Selects a session in the workspace window without activating the app.
    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult
    /// Starts a Copilot session with `prompt`; replaying `requestId` never starts a second one.
    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult
    /// Opens an ended Copilot session in a new tab; replaying `requestId` never opens a second one.
    func resumeCopilotSession(projectId: String, requestId: UUID, copilotSessionId: String) async -> WorkspaceCommandResult
    /// Starts a local adversarial review session for `pullRequestURL` in `projectId`; replaying `requestId` never starts a second one.
    func reviewPullRequest(projectId: String, requestId: UUID, pullRequestURL: String) async -> WorkspaceCommandResult
    /// Sends or queues `prompt` in an existing session; replaying `requestId` never sends it twice.
    func sendSessionPrompt(
        projectId: String?, sessionId: String, requestId: UUID, prompt: String
    ) async -> WorkspaceCommandResult
}

extension PullRequestsWorkspace {
    var stateDirectory: URL? { nil }

    func reviewPullRequest(projectId: String, requestId: UUID, pullRequestURL: String) async -> WorkspaceCommandResult {
        .refused(code: "unsupported", message: "Reviewing pull requests is not supported by this workspace.")
    }
}

/// Modification fingerprint of the host's workspace state (`state.json` and
/// `sessions/`), used by the helper apps to skip redundant `list-sessions`
/// socket polls when nothing on disk has changed since the last successful poll.
struct WorkspaceDirectorySignature: Equatable, Sendable {
    struct DirectoryIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    struct FileFingerprint: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let statusChangedSeconds: Int
        let statusChangedNanoseconds: Int

        init?(path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = info.st_dev
            inode = info.st_ino
            mode = info.st_mode
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            statusChangedSeconds = info.st_ctimespec.tv_sec
            statusChangedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    /// Snapshot-relevant fields of `<id>.agent-activity.json`, excluding heartbeat
    /// timestamps (`updatedAt`, `observedAtMilliseconds`) that rewrite every 5s.
    struct ActivitySummary: Equatable, Sendable {
        struct RuntimeSummary: Decodable, Equatable, Sendable {
            let processing: Bool?
            let idleAtMilliseconds: Int64?
            let error: String?
        }

        struct SubagentSummary: Decodable, Equatable, Sendable {
            let id: String?
        }

        struct QuestionSummary: Decodable, Equatable, Sendable {
            let requestId: String?
        }

        struct WorkflowSummary: Decodable, Equatable, Sendable {
            let budgetRequest: QuestionSummary?
        }

        let copilotSessionId: String?
        let conversationEpoch: String?
        let foregroundTurnActive: Bool?
        let foregroundTransitionAt: String?
        let scheduledTurnActive: Bool?
        let idleGeneration: Int?
        let activeSubagentIds: [String]
        let userInputIds: [String]
        let elicitationIds: [String]
        let permissionIds: [String]
        let hasBudgetRequest: Bool
        let budgetRequestId: String?
        let runtimeProcessing: Bool?
        let runtimeIdleAtMilliseconds: Int64?
        let runtimeError: String?
        let sessionIdleAtMilliseconds: Int64?
        let inputCompletions: [String: Int64]?
        let error: String?

        init?(path: String) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let decoded = try? JSONDecoder().decode(DecodedPayload.self, from: data) else {
                return nil
            }
            copilotSessionId = decoded.copilotSessionId
            conversationEpoch = decoded.conversationEpoch
            foregroundTurnActive = decoded.foregroundTurnActive
            foregroundTransitionAt = decoded.foregroundTransitionAt
            scheduledTurnActive = decoded.scheduledTurnActive
            idleGeneration = decoded.idleGeneration
            activeSubagentIds = (decoded.activeSubagents ?? []).compactMap(\.id).sorted()
            userInputIds = (decoded.trackedUserInputs ?? []).compactMap(\.requestId).sorted()
            elicitationIds = (decoded.trackedElicitations ?? []).compactMap(\.requestId).sorted()
            permissionIds = (decoded.pendingPermissionRequestIds ?? []).sorted()
            hasBudgetRequest = decoded.workflow?.budgetRequest != nil
            budgetRequestId = decoded.workflow?.budgetRequest?.requestId
            runtimeProcessing = decoded.runtimeActivity?.processing
            runtimeIdleAtMilliseconds = decoded.runtimeActivity?.idleAtMilliseconds
            runtimeError = decoded.runtimeActivity?.error
            sessionIdleAtMilliseconds = decoded.sessionIdleAtMilliseconds
            inputCompletions = decoded.inputCompletions
            error = decoded.error
        }

        private struct DecodedPayload: Decodable {
            let copilotSessionId: String?
            let conversationEpoch: String?
            let foregroundTurnActive: Bool?
            let foregroundTransitionAt: String?
            let scheduledTurnActive: Bool?
            let idleGeneration: Int?
            let activeSubagents: [SubagentSummary]?
            let trackedUserInputs: [QuestionSummary]?
            let trackedElicitations: [QuestionSummary]?
            let pendingPermissionRequestIds: [String]?
            let workflow: WorkflowSummary?
            let runtimeActivity: RuntimeSummary?
            let sessionIdleAtMilliseconds: Int64?
            let inputCompletions: [String: Int64]?
            let error: String?
        }
    }

    enum EntrySignature: Equatable, Sendable {
        case file(FileFingerprint?)
        case activity(ActivitySummary)
    }

    struct NamedEntry: Equatable, Sendable {
        let name: String
        let signature: EntrySignature
    }

    let stateEntries: [NamedEntry]
    let sessionEntries: [NamedEntry]

    private static let activityCacheLock = NSLock()
    nonisolated(unsafe) private static var activityCache:
        [String: (fingerprint: FileFingerprint, summary: ActivitySummary)] = [:]

    private static let trackedStateFiles = [
        "app.lock",
        "control.sock",
        "project-creation-ledger.json",
        "state.json",
        "state.json.backup",
        "state.json.closing",
    ]

    private static let ignoredSessionSuffixes = [
        ".tmp",
        ".transcript.json",
        ".transcript-live.json",
        ".transcript-owner.json",
        ".transcript-owner.json.flock",
    ]

    static func isTrackedSessionEntry(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix(".") else { return false }
        if name.contains(".status-record.json.") { return false }
        return !ignoredSessionSuffixes.contains { name.hasSuffix($0) }
    }

    private static func sessionEntrySignature(name: String, path: String) -> EntrySignature {
        let fileFingerprint = FileFingerprint(path: path)
        guard name.hasSuffix(".agent-activity.json"), let fileFingerprint else {
            return .file(fileFingerprint)
        }
        if let cached = activityCacheLock.withLock({ activityCache[path] }),
           cached.fingerprint == fileFingerprint {
            return .activity(cached.summary)
        }
        guard let summary = ActivitySummary(path: path) else {
            return .file(fileFingerprint)
        }
        activityCacheLock.withLock {
            if activityCache.count > 256 { activityCache.removeAll(keepingCapacity: true) }
            activityCache[path] = (fileFingerprint, summary)
        }
        return .activity(summary)
    }

    static func capture(at directory: URL) -> WorkspaceDirectorySignature {
        let stateEntries: [NamedEntry] = trackedStateFiles.compactMap { name in
            let path = directory.appendingPathComponent(name).path
            guard let fingerprint = FileFingerprint(path: path) else { return nil }
            return NamedEntry(name: name, signature: .file(fingerprint))
        }
        let sessionsURL = directory.appendingPathComponent("sessions", isDirectory: true)
        let sessionsPath = sessionsURL.path
        let sessionNames = ((try? FileManager.default.contentsOfDirectory(atPath: sessionsPath)) ?? [])
            .filter(isTrackedSessionEntry)
            .sorted()
        let sessionEntries = sessionNames.map { name in
            let path = sessionsURL.appendingPathComponent(name).path
            return NamedEntry(
                name: name,
                signature: sessionEntrySignature(name: name, path: path)
            )
        }
        return WorkspaceDirectorySignature(
            stateEntries: stateEntries,
            sessionEntries: sessionEntries
        )
    }

    static func captureAsync(at directory: URL) async -> WorkspaceDirectorySignature {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: capture(at: directory))
            }
        }
    }
}

/// Tracks the last polled workspace state-directory signature, allowing one
/// delayed follow-up poll after a disk change before skipping unchanged polls
/// up to the staleness backstop interval.
struct WorkspacePollGate: Sendable {
    static let defaultSettleFollowUpDelay: TimeInterval = 1.1

    private(set) var lastSignature: WorkspaceDirectorySignature?
    private(set) var unsettledDiskChangeAt: Date?
    private(set) var lastPollAt: Date?
    private(set) var lastPollSucceeded = false

    func shouldSkipPoll(
        currentSignature: WorkspaceDirectorySignature,
        now: Date,
        unchangedPollInterval: TimeInterval,
        settleFollowUpDelay: TimeInterval = WorkspacePollGate.defaultSettleFollowUpDelay
    ) -> Bool {
        guard let lastPollAt,
              now.timeIntervalSince(lastPollAt) < unchangedPollInterval,
              currentSignature == lastSignature else {
            return false
        }
        guard let unsettledDiskChangeAt else {
            return true
        }
        return now.timeIntervalSince(unsettledDiskChangeAt) < settleFollowUpDelay
    }

    mutating func record(
        fetch: WorkspaceFetch,
        sampledSignature: WorkspaceDirectorySignature?,
        now: Date,
        settleFollowUpDelay: TimeInterval = WorkspacePollGate.defaultSettleFollowUpDelay
    ) {
        lastPollAt = now
        guard let sampledSignature else {
            lastSignature = nil
            unsettledDiskChangeAt = nil
            lastPollSucceeded = false
            return
        }
        guard case .snapshot = fetch else {
            lastSignature = sampledSignature
            unsettledDiskChangeAt = nil
            lastPollSucceeded = false
            return
        }
        if lastPollSucceeded, sampledSignature == lastSignature {
            if unsettledDiskChangeAt.map({ now.timeIntervalSince($0) >= settleFollowUpDelay }) ?? true {
                unsettledDiskChangeAt = nil
            }
        } else {
            unsettledDiskChangeAt = now
        }
        lastSignature = sampledSignature
        lastPollSucceeded = true
    }
}

/// Watches the host workspace's state and sessions directories with
/// `DispatchSourceFileSystemObject` and coalesces bursts into debounced wakeups.
@MainActor
final class WorkspaceDirectoryWatcher {
    static let defaultDebounceInterval: TimeInterval = 0.05

    private enum Target: Hashable {
        case parentDirectory
        case stateDirectory
        case sessionsDirectory
        case stateFile
    }

    private struct WatchedSource {
        let identity: WorkspaceDirectorySignature.DirectoryIdentity
        let source: DispatchSourceFileSystemObject
    }

    let stateDirectory: URL
    let debounceInterval: TimeInterval
    private var sources: [Target: WatchedSource] = [:]
    private var debounceWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var waiter: (id: UUID, continuation: CheckedContinuation<Void, Never>)?
    private var hasPendingEvent = false
    private var isStopped = false

    init(stateDirectory: URL, debounceInterval: TimeInterval = WorkspaceDirectoryWatcher.defaultDebounceInterval) {
        self.stateDirectory = stateDirectory
        self.debounceInterval = max(0, debounceInterval)
        refreshSources()
    }

    deinit {
        debounceWork?.cancel()
        timeoutWork?.cancel()
        for entry in sources.values {
            entry.source.cancel()
        }
    }

    func stop() {
        isStopped = true
        debounceWork?.cancel()
        debounceWork = nil
        hasPendingEvent = false
        if let continuation = takeWaiter() {
            continuation.resume()
        }
        for key in Array(sources.keys) {
            invalidateSource(for: key)
        }
    }

    /// Waits until either a coalesced filesystem event fires or `timeout` elapses.
    func waitForNextPoll(timeout: TimeInterval) async {
        guard !isStopped, !Task.isCancelled else { return }
        refreshSources()
        if hasPendingEvent {
            hasPendingEvent = false
            return
        }
        let waiterId = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isStopped || Task.isCancelled || hasPendingEvent {
                    hasPendingEvent = false
                    continuation.resume()
                    return
                }
                replaceWaiter(id: waiterId, continuation: continuation, timeout: timeout)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter(id: waiterId)
            }
        }
    }

    private func refreshSources() {
        guard !isStopped else { return }
        let statePath = stateDirectory.path
        if WorkspaceDirectorySignature.DirectoryIdentity(path: statePath) != nil {
            invalidateSource(for: .parentDirectory)
            ensureSource(for: .stateDirectory, path: statePath)
            ensureSource(
                for: .sessionsDirectory,
                path: stateDirectory.appendingPathComponent("sessions", isDirectory: true).path
            )
            ensureSource(
                for: .stateFile,
                path: stateDirectory.appendingPathComponent("state.json").path
            )
        } else {
            invalidateSource(for: .stateDirectory)
            invalidateSource(for: .sessionsDirectory)
            invalidateSource(for: .stateFile)
            ensureSource(
                for: .parentDirectory,
                path: stateDirectory.deletingLastPathComponent().path
            )
        }
    }

    private func ensureSource(for target: Target, path: String) {
        guard let currentIdentity = WorkspaceDirectorySignature.DirectoryIdentity(path: path) else {
            invalidateSource(for: target)
            return
        }
        if let existing = sources[target], existing.identity == currentIdentity {
            return
        }
        invalidateSource(for: target)
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      let entry = self.sources[target],
                      entry.identity == currentIdentity else { return }
                self.handleEvent(for: target, flags: entry.source.data)
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        sources[target] = WatchedSource(identity: currentIdentity, source: source)
    }

    private func invalidateSource(for target: Target) {
        guard let removed = sources.removeValue(forKey: target) else { return }
        removed.source.cancel()
    }

    private func handleEvent(for target: Target, flags: DispatchSource.FileSystemEvent) {
        guard !isStopped else { return }
        if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
            invalidateSource(for: target)
        }
        refreshSources()
        scheduleDebouncedWake()
    }

    private func scheduleDebouncedWake() {
        guard debounceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isStopped else { return }
                self.debounceWork = nil
                self.refreshSources()
                if let continuation = self.takeWaiter() {
                    continuation.resume()
                } else {
                    self.hasPendingEvent = true
                }
            }
        }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func replaceWaiter(
        id: UUID,
        continuation: CheckedContinuation<Void, Never>,
        timeout: TimeInterval
    ) {
        if let previous = takeWaiter() {
            previous.resume()
        }
        waiter = (id, continuation)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.waiter?.id == id, let continuation = self.takeWaiter() else { return }
                continuation.resume()
            }
        }
        timeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, timeout), execute: work)
    }

    private func cancelWaiter(id: UUID) {
        guard waiter?.id == id, let continuation = takeWaiter() else { return }
        continuation.resume()
    }

    private func takeWaiter() -> CheckedContinuation<Void, Never>? {
        timeoutWork?.cancel()
        timeoutWork = nil
        defer { waiter = nil }
        return waiter?.continuation
    }
}

/// Copilot Projects over its control socket. Each request runs on a dispatch
/// thread, never on the main actor, and the client's timeout bounds it.
actor ControlWorkspaceBridge: PullRequestsWorkspace {
    let socketPath: String
    let timeout: TimeInterval
    nonisolated let stateDirectory: URL?

    init(
        socketPath: String = Paths.socketPath,
        timeout: TimeInterval = 3,
        stateDirectory: URL? = nil
    ) {
        self.socketPath = socketPath
        self.timeout = timeout
        if let stateDirectory {
            self.stateDirectory = stateDirectory
        } else if socketPath == Paths.stateDir.appendingPathComponent("control.sock").path {
            self.stateDirectory = Paths.stateDir
        } else {
            self.stateDirectory = nil
        }
    }

    func snapshot() async -> WorkspaceFetch {
        guard case .success(let response) = await send(ControlRequest(command: "list-sessions")),
              response.ok,
              let text = response.text,
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: Data(text.utf8))
        else { return .unreachable }
        return .snapshot(snapshot)
    }

    func revealSession(projectId: String?, sessionId: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "reveal-session")
        request.projectId = projectId
        request.sessionId = sessionId
        return Self.result(await send(request))
    }

    func startCopilotSession(projectId: String, requestId: UUID, prompt: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "start-copilot-session")
        request.projectId = projectId
        request.requestId = requestId.uuidString
        request.prompt = prompt
        return Self.result(await send(request))
    }

    func resumeCopilotSession(projectId: String, requestId: UUID, copilotSessionId: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "resume-copilot-session")
        request.projectId = projectId
        request.requestId = requestId.uuidString
        request.copilotSessionId = copilotSessionId
        return Self.result(await send(request))
    }

    func reviewPullRequest(projectId: String, requestId: UUID, pullRequestURL: String) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "review-pull-request")
        request.projectId = projectId
        request.requestId = requestId.uuidString
        request.path = pullRequestURL
        return Self.result(await send(request))
    }

    func sendSessionPrompt(
        projectId: String?, sessionId: String, requestId: UUID, prompt: String
    ) async -> WorkspaceCommandResult {
        var request = ControlRequest(command: "send-session-prompt")
        request.projectId = projectId
        request.sessionId = sessionId
        request.requestId = requestId.uuidString
        request.prompt = prompt
        return Self.result(await send(request))
    }

    static func result(_ reply: Result<ControlResponse, Error>) -> WorkspaceCommandResult {
        guard case .success(let response) = reply else { return .unreachable }
        return response.ok
            ? .done(code: response.code, text: response.text)
            : .refused(code: response.code, message: response.error ?? "Copilot Projects refused the request.")
    }

    private func send(_ request: ControlRequest) async -> Result<ControlResponse, Error> {
        let client = ControlClient(socketPath: socketPath, timeout: timeout)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Result { try client.send(request) })
            }
        }
    }
}

/// Copilot Projects the app: bringing it forward and opening it.
struct PullRequestsHostApp {
    /// Brings the host forward, yielding this app's activation to it. Only works
    /// while this app is active, right after the user acted in it.
    var activate: @MainActor (_ processIdentifier: Int32) -> Void
    /// Opens Copilot Projects; nil when this copy isn't inside it.
    var open: (@MainActor () -> Void)?

    static let none = PullRequestsHostApp(activate: { _ in }, open: nil)

    /// The Copilot Projects.app this copy is bundled in.
    static func system(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> PullRequestsHostApp {
        let hostURL = AppDeepLink.parentApplicationURL(forHelperBundleURL: bundle.bundleURL)
        return PullRequestsHostApp(
            activate: { processIdentifier in
                guard let host = runningHost(processIdentifier, hostURL: hostURL) else {
                    NSLog("copilot-pull-requests: Copilot Projects isn't running to bring forward")
                    return
                }
                if !host.activate(from: .current, options: []) {
                    NSLog("copilot-pull-requests: Copilot Projects declined activation")
                }
            },
            open: hostURL.map { url in
                {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    configuration.allowsRunningApplicationSubstitution = false
                    configuration.createsNewApplicationInstance = PullRequestsAppBundle.isIsolated(environment)
                    configuration.environment = PullRequestsAppBundle.forwardedEnvironment(environment)
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                        if let error { NSLog("copilot-pull-requests: could not open Copilot Projects: \(error)") }
                    }
                }
            }
        )
    }

    /// The Copilot Projects at `processIdentifier`, or, when that process has
    /// gone because Copilot Projects restarted since the last snapshot, the
    /// only running copy of the app this one is bundled in. A reused pid is
    /// never taken for Copilot Projects.
    @MainActor
    static func runningHost(_ processIdentifier: Int32, hostURL: URL?) -> NSRunningApplication? {
        let identifier = hostURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        if let host = NSRunningApplication(processIdentifier: processIdentifier), !host.isTerminated,
           identifier == nil || host.bundleIdentifier == identifier {
            return host
        }
        guard let hostURL, let identifier else { return nil }
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { !$0.isTerminated && $0.bundleURL?.standardizedFileURL.path == hostURL.standardizedFileURL.path }
        return copies.count == 1 ? copies[0] : nil
    }
}
