import SwiftUI
import Combine
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsPullRequests
import Darwin

private struct WorkspacePersistenceError: LocalizedError {
    let errorDescription: String?
}

enum PermissionNotificationDecision: Equatable {
    case cancel
    case post
    case suppress
}

/// Single source of truth. Holds value-type projects/sessions (observed) and live
/// terminal controllers (NOT observed, kept out of the SwiftUI graph).
typealias GracefulSessionDestroyer = (
    _ sessionIds: [String],
    _ kittyImageDiskStore: RemoteKittyImageDiskStore
) -> Task<Void, Never>
typealias ForcedSessionDestroyer = (_ sessionIds: [String]) -> Void

@MainActor
final class AppModel: ObservableObject {
    var projectStorage: [Project] = []
    private var projectPublicationBatchDepth = 0
    private var projectPublicationPending = false
    var projects: [Project] {
        get { projectStorage }
        set {
            guard projectStorage != newValue else { return }
            if projectPublicationBatchDepth == 0 {
                objectWillChange.send()
            } else if !projectPublicationPending {
                objectWillChange.send()
                projectPublicationPending = true
            }
            projectStorage = newValue
        }
    }

    func withCoalescedProjectPublications<T>(_ body: () throws -> T) rethrows -> T {
        projectPublicationBatchDepth += 1
        defer {
            projectPublicationBatchDepth -= 1
            if projectPublicationBatchDepth == 0 {
                projectPublicationPending = false
            }
        }
        return try body()
    }
    @Published var selectedProjectId: String?
    @Published var numberHint: NumberHint = .none
    @Published private(set) var transcriptOpenSessions: Set<String> = []
    var requestMainWindow: (() -> Void)?

    var controllers: [String: TerminalController] = [:]
    var sessionPromptComposers: [String: DesktopSessionPromptComposer] = [:]
    private var selectedTranscriptController: TranscriptController?
    private let stateRepository: StateRepository
    /// User settings this model reads. Tests inject a suite so a saved review
    /// prompt cannot leak into another test through `UserDefaults.standard`.
    private let defaults: UserDefaults
    /// The durable Kitty-image disk store every session's terminal is wired
    /// to. Defaults to the real process-wide singleton; tests inject an
    /// isolated instance (a fresh temp-directory-backed store) so a test
    /// session's images can never touch — or be perturbed by — the real
    /// user's persisted state.
    private let kittyImageDiskStore: RemoteKittyImageDiskStore
    private lazy var controlRouter = ControlCommandRouter(actions: .init(
        listProjects: { [unowned self] in self.renderProjects() },
        listStatus: { [unowned self] in self.renderStatus() },
        setStatus: { [unowned self] status, text, request in
            guard let target = self.resolve(request) else { return .failure("no target session") }
            self.setStatus(
                sessionId: target.sessionId,
                status: status,
                text: text,
                timestamp: request.timestamp,
                source: request.source,
                copilotSessionId: request.copilotSessionId,
                notification: request.notification
            )
            return .success()
        },
        notify: { [unowned self] title, body, request in
            if let target = self.resolve(request) {
                self.postNotification(
                    projectId: target.projectId, sessionId: target.sessionId,
                    title: title, body: body)
            } else {
                self.notifications?.post(NotificationEvent(
                    kind: nil,
                    title: title, subtitle: nil, body: body,
                    projectId: request.projectId, sessionId: request.sessionId
                ))
            }
            return .success()
        },
        newProject: { [unowned self] request in
            let cwd = request.cwd ?? Paths.defaultStartupDir
            let name = request.name
                ?? request.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "Project \(self.projects.count + 1)"
            if let rawHost = request.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawHost.isEmpty,
               self.resolvedRemoteHost(hostId: rawHost) == nil {
                return .failure("unknown host: \(rawHost)", code: "bad-request")
            }
            let resolvedDefaultHost = request.hostId.flatMap { self.resolvedRemoteHost(hostId: $0) }
            let defaultHostId = (resolvedDefaultHost?.isLocal == false) ? resolvedDefaultHost?.id : nil
            let project = self.makeProject(
                name: name,
                cwd: request.cwd ?? resolvedDefaultHost?.defaultCwd ?? cwd,
                defaultHostId: defaultHostId,
                withSession: true
            )
            self.projects.append(project)
            self.selectProject(project.id)
            return .success(project.id)
        },
        newSession: { [unowned self] request in
            guard let pid = self.resolveProject(request) else { return .failure("no project") }
            if let rawHost = request.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawHost.isEmpty,
               self.resolvedRemoteHost(hostId: rawHost) == nil {
                return .failure("unknown host: \(rawHost)", code: "bad-request")
            }
            guard let sid = self.addSession(
                toProjectId: pid,
                cwd: request.cwd,
                hostId: request.hostId
            ) else {
                return .failure("unknown project: \(pid)")
            }
            return .success(sid)
        },
        newCopilotSession: { [unowned self] request in
            guard let projectId = request.projectId,
                  let rawRequestId = request.requestId,
                  let requestId = UUID(uuidString: rawRequestId),
                  let prompt = request.prompt else {
                return .failure("new-copilot-session requires a project, request id, and prompt",
                                code: "bad-request")
            }
            return Self.controlResponse(for: self.createLocalCopilotSession(
                requestId: requestId,
                projectId: projectId,
                title: request.title ?? "Copilot",
                prompt: prompt,
                hostId: request.hostId
            ))
        },
        closeSession: { [unowned self] request in
            Self.controlResponse(for: self.closeAutomationSession(
                sessionId: request.sessionId ?? "",
                projectId: request.projectId
            ))
        },
        renameProject: { [unowned self] name, request in
            guard let pid = self.resolveProject(request) else { return .failure("no project") }
            self.renameProject(pid, name: name)
            return .success()
        },
        focus: { [unowned self] request in
            self.focus(projectId: request.projectId, sessionId: request.sessionId)
            return .success()
        },
        listSessions: { [unowned self] in
            Self.listSessionsResponse(self.workspaceSnapshot())
        },
        revealSession: { [unowned self] request in
            self.revealSession(projectId: request.projectId, sessionId: request.sessionId ?? "")
        },
        startCopilotSession: { [unowned self] request in
            guard let projectId = request.projectId,
                  let rawRequestId = request.requestId,
                  let requestId = UUID(uuidString: rawRequestId),
                  let prompt = request.prompt else {
                return .failure("start-copilot-session requires a project, request id, and prompt",
                                code: "bad-request")
            }
            return self.startPullRequestsSession(requestId: requestId, projectId: projectId, prompt: prompt)
        },
        resumeCopilotSession: { [unowned self] request in
            guard let projectId = request.projectId,
                  let rawRequestId = request.requestId,
                  let requestId = UUID(uuidString: rawRequestId),
                  let copilotSessionId = request.copilotSessionId,
                  CopilotSessionStore.isValidSessionId(copilotSessionId) else {
                return .failure("resume-copilot-session requires a project, request id, and Copilot session id",
                                code: "bad-request")
            }
            return self.resumePullRequestsSession(
                requestId: requestId, projectId: projectId, copilotSessionId: copilotSessionId
            )
        },
        reviewPullRequest: { [unowned self] request in
            guard let projectId = request.projectId, !projectId.isEmpty,
                  let rawRequestId = request.requestId,
                  let requestId = UUID(uuidString: rawRequestId),
                  let pullRequestURL = request.path ?? request.text, !pullRequestURL.isEmpty else {
                return .failure(
                    "review-pull-request requires a project, a UUID request id, and a pull request URL",
                    code: "bad-request")
            }
            return self.startPullRequestReviewSession(
                requestId: requestId,
                projectId: projectId,
                pullRequestURL: pullRequestURL,
                hostId: request.hostId
            )
        },
        sendSessionPrompt: { [unowned self] request in
            guard let sessionId = request.sessionId, !sessionId.isEmpty,
                  request.projectId.map({ !$0.isEmpty }) ?? true,
                  let rawRequestId = request.requestId,
                  let requestId = UUID(uuidString: rawRequestId),
                  let prompt = request.prompt else {
                return .failure(
                    "send-session-prompt requires a session id, a UUID request id, and a prompt",
                    code: "bad-request")
            }
            return self.sendPullRequestsSessionPrompt(
                requestId: requestId,
                projectId: request.projectId,
                sessionId: sessionId,
                prompt: prompt
            )
        },
        listHosts: { [unowned self] in self.renderHosts() },
        setDefaultHost: { [unowned self] request in
            guard let pid = self.resolveProject(request) else { return .failure("no project") }
            guard self.projectIndex(pid) != nil else {
                return .failure("unknown project: \(pid)", code: "unknown-project")
            }
            let rawHost = request.hostId?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let rawHost, !rawHost.isEmpty, self.resolvedRemoteHost(hostId: rawHost) == nil {
                return .failure("unknown host: \(rawHost)", code: "bad-request")
            }
            let resolved = rawHost.flatMap { self.resolvedRemoteHost(hostId: $0) }
            self.setProjectDefaultHost(pid, hostId: resolved?.id)
            return .success(resolved?.id ?? RemoteHostInfo.localId)
        },
        screenshot: { _ in
            .failure("screenshot must be handled by the control server")
        },
        diagnostics: { [unowned self] in self.renderDiagnostics() },
        remote: { [unowned self] action in
            self.integration?.command(action)
                ?? .failure("This build does not include a remote integration.")
        }
    ))
    /// The tab each Copilot session was last resumed in for Copilot Pull Requests,
    /// by Copilot session id (lowercased), and when: until its shell has started
    /// the command that resumes it, nothing else shows that it is coming back.
    var pullRequestsResumeLaunches: [String: (sessionId: String, launchedAt: Date)] = [:]
    static let pullRequestsResumeStartupGrace: TimeInterval = 5
    enum PullRequestsPromptRoute: Equatable {
        case terminal
        case native(conversationEpoch: String)
    }
    struct SentPullRequestsPrompt {
        let sessionId: String
        let payloadFingerprint: String
        let route: PullRequestsPromptRoute
        var state: PullRequestsPromptRecord.DeliveryState
        let createdAt: Date
    }
    var sentPullRequestsPrompts: [UUID: SentPullRequestsPrompt] = [:]
    /// The Copilot session each captured launch resumes, by tab. Launches are
    /// captured only when `remoteSessionLauncher` is set, in tests.
    private(set) var capturedResumeLaunches: [String: String] = [:]
    var stateLoadFailure: String?
    var didFailToLoadWorkspaceState = false
    /// Only a cleanly loaded state file lists every tab that may still own files;
    /// a missing or backup-recovered workspace can't prove a tab is gone.
    private var didLoadWorkspaceState = false
    private var stateRecoveryMessage: String?
    private var didPresentStateMessage = false
    private var server: ControlServer?
    private var integration: (any HostIntegration)?
    private final class ScheduledSaveBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: PersistedState?
        private var workerEnqueued = false

        func enqueue(_ state: PersistedState) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            pending = state
            guard !workerEnqueued else { return false }
            workerEnqueued = true
            return true
        }

        func takeNext() -> PersistedState? {
            lock.lock()
            defer { lock.unlock() }
            guard let next = pending else {
                workerEnqueued = false
                return nil
            }
            pending = nil
            return next
        }

        func clearPending() {
            lock.lock()
            pending = nil
            lock.unlock()
        }
    }

    weak var notifications: (any NotificationPosting)?
    private var saveWork: DispatchWorkItem?
    private let scheduledSaveBuffer = ScheduledSaveBuffer()
    private let stateSaveQueue = DispatchQueue(
        label: "com.copilot-projects.state-save",
        qos: .utility
    )
    private(set) var isTerminating = false
    /// Remembers the `(tier, workspaceIndex)` of an `.unread` session whose unread
    /// flag was cleared by `selectNextAttentionSession()`, so pressing `⇧⌘A` again
    /// from that session continues advancing through the cycle instead of restarting.
    private var lastClearedAttentionCursor: (sessionId: String, tier: SessionAttentionTier, workspaceIndex: Int)?
    @Published private(set) var sessionNavigationHistory = SessionNavigationHistory()
    private var isNavigatingSessionHistory = false

    var livenessTimer: Timer?
    var footerTimer: Timer?
    var agentActivityTimer: Timer?
    var agentActivitySource: DispatchSourceFileSystemObject?
    // Throttle state for the sessions-directory watcher: the directory holds a
    // file per session (activity/status/marker/transcript) and receives frequent
    // writes across all sessions, so an unthrottled watcher re-scans every session
    // on the main thread many times a second and starves keystroke handling.
    var agentActivityRefreshCoolingDown = false
    var agentActivityRefreshPending = false
    // Bumped whenever tracking (re)starts or terminates so an already-scheduled
    // cooldown from a prior chain — which `asyncAfter` cannot cancel — no-ops
    // instead of corrupting the current chain's throttle state.
    var agentActivityRefreshGeneration = 0
    let agentActivityRefreshThrottle: TimeInterval
    let agentActivityCooldownScheduler:
        (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void
    let agentActivityScanObserver: (() -> Void)?
    // Watcher and backstop scans read snapshot files on this queue and apply the
    // results on the main actor: one read in flight, one follow-up queued behind it.
    let agentActivityReader: AgentActivityReader.Read
    let agentActivityReadQueue = DispatchQueue(
        label: "copilot-projects.agent-activity-reads", qos: .userInitiated
    )
    var agentActivityReadInFlight = false
    var agentActivityReadQueued = false
    // Counts each session's main-actor observations of its snapshot file (applied
    // scan reads and single-session loads, whatever they found) and the status
    // hooks that change its scheduling, so a background read applies only to
    // sessions nothing observed or changed after it began. The cached signature
    // can't tell: a later scan that finds the file gone leaves an empty cache empty.
    var agentActivityObservations: [String: Int] = [:]
    // Per-session decoded-snapshot cache keyed by a file signature (inode+size+
    // mtime). Every live session heartbeats a write to its
    // `<id>.agent-activity.json` roughly every 5s, and both the directory watcher
    // and the 10s backstop re-scan *all* sessions — so re-reading and JSON-decoding
    // every file on each scan dominated the main thread (blocking `open()` is
    // especially costly when a security agent intercepts file events). Skip the
    // read+decode when a file's signature is unchanged; the caller still re-applies
    // the freshness TTL to the cached snapshot each scan, so a skipped read never
    // stalls a stale→nil transition.
    var agentActivitySnapshotCache:
        [String: (signature: FileSignature, snapshot: AgentActivitySnapshot?)] = [:]

    var sessionSemantics = SessionSemanticsState()
    var backgroundAgentsSuppressed: Set<String> = []
    var completionPending: Set<String> = []
    var completionSummaryContexts: [String: CompletionSummaryContext] = [:]
    let completionTranscriptLoader: @Sendable (String) -> TranscriptSnapshot
    var scheduledSnapshotsSuppressed: Set<String> = []
    var foregroundIdleGenerationBaselines: [String: Int] = [:]
    private let completionNotificationDelayNanoseconds: UInt64
    private let permissionNotificationDelayNanoseconds: UInt64
    private let elicitationReplyRetryDelaysNanoseconds: [UInt64]
    let persistPermissionStatus:
        (_ sessionId: String, _ status: SessionStatus, _ timestamp: Int64,
         _ promptStatusTimestamp: Int64) -> Void
    struct InputWaitState {
        let context: InputWaitContext
        let timestamp: Int64
    }
    private struct ElicitationConversation: Equatable {
        let rootSessionId: String
        let conversationEpoch: String
    }
    struct RemotePromptFence: Equatable {
        let submittedAt: Int64
        let rootSessionId: String
        let conversationEpoch: String
    }
    var inputWaits: [String: InputWaitState] = [:]
    var remotePromptFences: [String: RemotePromptFence] = [:]
    var runtimeTrackedOwners: [String: String] = [:]
    struct PermissionStatusRestore {
        let status: SessionStatus
        let statusText: String?
        let scheduledTurnActive: Bool
        let finishedUnseen: Bool
        let turnCompleted: Bool
        let backgroundAgentsSuppressed: Bool
        let completionPending: Bool
        let foregroundIdleGenerationBaseline: Int?
        var statusTimestamp: Int64
        var promptStatusTimestamp: Int64
        var observedRootSessionId: String? = nil
        var observedConversationEpoch: String? = nil
        var observedPendingRequestIds: Set<String> = []
    }
    private struct PendingSessionDestroy {
        let task: Task<Void, Never>
        let controller: TerminalController?
    }
    private var permissionNotificationTokens: [String: UUID] = [:]
    var elicitationNotificationTokens: [String: UUID] = [:]
    /// Question alerts that may still be showing, per session, so they can be
    /// withdrawn once their question is answered anywhere.
    private var questionNotifications: [String: [PostedQuestionNotification]] = [:]
    var budgetNotificationKeys: [String: String] = [:]
    var permissionStatusRestores: [String: PermissionStatusRestore] = [:]
    private let isAppActive: @MainActor () -> Bool
    let agentActivityDirectory: URL
    nonisolated let resumeMarkerDirectory: URL
    nonisolated let controlMainQueueTimeout: TimeInterval
    nonisolated let controlMainQueue: ControlServer.MainQueueScheduler
    let screenshotPreparer: (@MainActor () -> ScreenshotPreparation)?
    nonisolated let screenshotImageCapturer: WindowScreenshot.ImageCapturer
    private var powerOffProtectionGeneration = 0
    private(set) var isPoweringOff = false
    let remotePromptLiveSessions: ((Set<String>) -> Set<String>)?
    /// Tabs still bringing back a Copilot session (tests stand in for the process tree).
    let copilotResumeSessions: ((String) -> Set<String>)?
    let remotePromptTarget: ((String) -> RemotePromptTarget?)?
    let remoteElicitationTarget:
        ((String) -> RemoteElicitationTerminalTarget?)?
    var remoteCommandRequestLedger = RemoteCommandRequestLedger()
    var remoteElicitationRequestLedger = RemoteCommandRequestLedger()
    let remoteControlDeliveryLedger = RemoteControlDeliveryLedger()
    private let gracefulSessionDestroyer: GracefulSessionDestroyer
    private let forcedSessionDestroyer: ForcedSessionDestroyer
    private let alertPresenter: (NSAlert) -> NSApplication.ModalResponse
    private var pendingSessionDestroys: [String: PendingSessionDestroy] = [:]

    var remoteControlDeliveryEpoch: String { remoteControlDeliveryLedger.epoch }

    /// Resolves the absolute Copilot executable for a remotely-created session, and
    /// the absolute `$HOME/Repos` working directory. Injected so tests can drive the
    /// unavailable/invalid outcomes without touching the real filesystem.
    let remoteCopilotExecutable: () -> String?
    let remoteWrapperExecutable: () -> String?
    let remoteReposDirectory: () -> String?
    let remoteSessionBackendAvailable: () -> Bool
    let availableHostsProvider: () -> [RemoteHostInfo]
    /// Overrides the controller launch for a freshly-created Copilot session (tests
    /// record it instead of spawning a real terminal). Nil in production, where the
    /// real cached terminal controller is created with a one-shot Copilot launch.
    let remoteSessionLauncher:
        ((_ sessionId: String, _ copilotExecutable: String?,
          _ initialPrompt: String?) -> Void)?
    /// Persistent idempotency/tombstone store behind remote session creation.
    let sessionCreationLedger: SessionCreationLedger
    let projectCreationLedger: ProjectCreationLedger
    /// Remote session search; tests swap in a fake ranker or transcript reader.
    var remoteSessionSearch = RemoteSessionSearch(copilotSessionStore: { CopilotSessionStore() })
    var pullRequestsOverviewProvider: PullRequestsOverviewProvider?
    var pendingPullRequestBindings: [UUID: SessionCreationRecord] = [:]

    /// Sessions hosting a live agent (refreshed by the liveness reconciler). Used
    /// by scroll-wheel forwarding to keep working on resumed (desynced) sessions.
    var liveAgentSessions: Set<String> = []

    func setLiveAgentSessionsForTesting(_ sessions: Set<String>) {
        liveAgentSessions = sessions
    }

    /// Process names treated as a live coding agent for the liveness backstop.
    /// Override with COPILOT_PROJECTS_AGENT_PROCESSES (comma-separated); disable the
    /// whole check with COPILOT_PROJECTS_LIVENESS=0.
    var agentProcessNames: Set<String> {
        Env.agentProcessNames()
    }

    var livenessEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["COPILOT_PROJECTS_LIVENESS"] != "0"
    }

    init(
        stateRepository: StateRepository = StateRepository(),
        completionNotificationDelayNanoseconds: UInt64 = 1_000_000_000,
        completionTranscriptLoader: @escaping @Sendable (String) -> TranscriptSnapshot = {
            TranscriptController.loadRemoteSnapshot(sessionId: $0)
        },
        permissionNotificationDelayNanoseconds: UInt64 = 1_000_000_000,
        elicitationReplyRetryDelaysNanoseconds: [UInt64] = [
            250_000_000, 500_000_000, 1_000_000_000, 2_000_000_000,
        ],
        persistPermissionStatus: @escaping (
            _ sessionId: String, _ status: SessionStatus, _ timestamp: Int64,
            _ promptStatusTimestamp: Int64
        ) -> Void = { sessionId, status, timestamp, promptStatusTimestamp in
            SessionArtifacts.persistStatus(
                sessionId: sessionId,
                status: status,
                timestamp: timestamp,
                promptStatusTimestamp: promptStatusTimestamp
            )
        },
        isAppActive: @escaping @MainActor () -> Bool = { NSApp?.isActive ?? false },
        agentActivityDirectory: URL = Paths.sessionsDir,
        resumeMarkerDirectory: URL = Paths.sessionsDir,
        remotePromptLiveSessions: ((Set<String>) -> Set<String>)? = nil,
        copilotResumeSessions: ((String) -> Set<String>)? = nil,
        remotePromptTarget: ((String) -> RemotePromptTarget?)? = nil,
        remoteElicitationTarget:
            ((String) -> RemoteElicitationTerminalTarget?)? = nil,
        remoteCopilotExecutable: @escaping () -> String? = { Paths.copilotExecutable },
        remoteWrapperExecutable: @escaping () -> String? = { Paths.remoteCopilotWrapperExecutable },
        remoteReposDirectory: @escaping () -> String? = { Paths.reposDirectory },
        remoteSessionBackendAvailable: @escaping () -> Bool = {
            Paths.dtachExecutable != nil
        },
        availableHostsProvider: (() -> [RemoteHostInfo])? = nil,
        remoteSessionLauncher: ((String, String?, String?) -> Void)? = nil,
        sessionCreationLedger: SessionCreationLedger = SessionCreationLedger(),
        projectCreationLedger: ProjectCreationLedger = ProjectCreationLedger(),
        agentActivityRefreshThrottle: TimeInterval = 0.5,
        agentActivityCooldownScheduler: @escaping (
            _ delay: TimeInterval,
            _ action: @escaping @MainActor () -> Void
        ) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Task { @MainActor in action() }
            }
        },
        agentActivityScanObserver: (() -> Void)? = nil,
        agentActivityReader: @escaping AgentActivityReader.Read = AgentActivityReader.read,
        kittyImageDiskStore: RemoteKittyImageDiskStore = .shared,
        gracefulSessionDestroyer: @escaping GracefulSessionDestroyer = {
            sessionIds, store in
            SessionArtifacts.destroyGracefully(
                sessionIds: sessionIds,
                kittyImageDiskStore: store
            )
        },
        forcedSessionDestroyer: @escaping ForcedSessionDestroyer = {
            SessionArtifacts.forceDestroy(sessionIds: $0)
        },
        alertPresenter: @escaping (NSAlert) -> NSApplication.ModalResponse = {
            $0.runModal()
        },
        controlMainQueueTimeout: TimeInterval = ControlServer.defaultMainActorTimeout,
        controlMainQueue: @escaping ControlServer.MainQueueScheduler =
            ControlServer.defaultMainQueueScheduler,
        screenshotPreparer: (@MainActor () -> ScreenshotPreparation)? = nil,
        screenshotImageCapturer: @escaping WindowScreenshot.ImageCapturer =
            WindowScreenshot.captureWindowImage,
        defaults: UserDefaults = .standard
    ) {
        self.stateRepository = stateRepository
        self.completionNotificationDelayNanoseconds = completionNotificationDelayNanoseconds
        self.completionTranscriptLoader = completionTranscriptLoader
        self.permissionNotificationDelayNanoseconds = permissionNotificationDelayNanoseconds
        self.elicitationReplyRetryDelaysNanoseconds = elicitationReplyRetryDelaysNanoseconds
        self.persistPermissionStatus = persistPermissionStatus
        self.isAppActive = isAppActive
        self.agentActivityDirectory = agentActivityDirectory
        self.resumeMarkerDirectory = resumeMarkerDirectory
        self.controlMainQueueTimeout = controlMainQueueTimeout
        self.controlMainQueue = controlMainQueue
        self.screenshotPreparer = screenshotPreparer
        self.screenshotImageCapturer = screenshotImageCapturer
        self.remotePromptLiveSessions = remotePromptLiveSessions
        self.copilotResumeSessions = copilotResumeSessions
        self.remotePromptTarget = remotePromptTarget
        self.remoteElicitationTarget = remoteElicitationTarget
        self.remoteCopilotExecutable = remoteCopilotExecutable
        self.remoteWrapperExecutable = remoteWrapperExecutable
        self.remoteReposDirectory = remoteReposDirectory
        self.remoteSessionBackendAvailable = remoteSessionBackendAvailable
        self.availableHostsProvider = availableHostsProvider ?? {
            SSHHostCatalog.defaultAvailableHosts(statePath: stateRepository.path)
        }
        self.remoteSessionLauncher = remoteSessionLauncher
        self.sessionCreationLedger = sessionCreationLedger
        self.projectCreationLedger = projectCreationLedger
        self.agentActivityRefreshThrottle = agentActivityRefreshThrottle
        self.agentActivityCooldownScheduler = agentActivityCooldownScheduler
        self.agentActivityScanObserver = agentActivityScanObserver
        self.agentActivityReader = agentActivityReader
        self.kittyImageDiskStore = kittyImageDiskStore
        self.gracefulSessionDestroyer = gracefulSessionDestroyer
        self.forcedSessionDestroyer = forcedSessionDestroyer
        self.alertPresenter = alertPresenter
        self.defaults = defaults
        load()
    }

    // MARK: - lifecycle wiring

    func attach(notifications: any NotificationPosting) {
        self.notifications = notifications
    }

    func attach(integration: (any HostIntegration)?) {
        self.integration = integration
    }

    func activateKittyImagePersistence() {
        kittyImageDiskStore.activate()
    }

    func bootstrapIfNeeded() {
        if !didPresentStateMessage, let message = stateLoadFailure ?? stateRecoveryMessage {
            didPresentStateMessage = true
            let alert = NSAlert()
            alert.messageText = stateLoadFailure == nil
                ? "Workspace State Recovered"
                : "Workspace State Could Not Be Loaded"
            alert.informativeText = message
            alert.alertStyle = stateLoadFailure == nil ? .informational : .critical
            alert.runModal()
        }
        guard stateLoadFailure == nil else { return }
        if projects.isEmpty {
            let project = makeProject(name: "home", cwd: Paths.defaultStartupDir, withSession: true)
            projects.append(project)
            selectedProjectId = project.id
            save()
        } else if selectedProjectId == nil {
            selectedProjectId = projects.first?.id
        }
        // Start the whole selected project's sessions on launch (matches the prior
        // per-project eager start), not just the visible tab.
        ensureSelectedProjectControllers()
        refreshSelectedTranscriptController()
        // Manual unread marks persist, so restore their Dock count on launch.
        updateDockBadge()
    }

    @discardableResult
    func startServer(socketPath: String = Paths.socketPath) -> Bool {
        let server = ControlServer(socketPath: socketPath) { [weak self] req in
            guard let self else { return .failure("app shutting down") }
            return self.handleControlServerRequest(req)
        }
        guard server.start() else { return false }
        self.server = server
        return true
    }

    nonisolated func handleControlServerRequest(_ req: ControlRequest) -> ControlResponse {
        if req.command == "ping" {
            return .success("pong")
        }
        if req.command == "list-sessions" {
            // Resume markers are read here, off the main thread: the Pull
            // Requests app asks every two seconds.
            guard let snapshotResult = ControlServer.runOnMainActor(
                timeout: controlMainQueueTimeout,
                scheduler: controlMainQueue,
                { [weak self] () -> WorkspaceSnapshot? in
                    guard let self else { return nil }
                    return self.workspaceSnapshotWithoutCopilotSessions()
                }
            ) else {
                return ControlServer.busyResponse
            }
            guard let snapshot = snapshotResult else {
                return .failure("app shutting down")
            }
            return Self.listSessionsResponse(
                Self.recordingCopilotSessions(
                    in: snapshot,
                    markerDirectory: resumeMarkerDirectory
                )
            )
        }
        if req.command == "screenshot" {
            let path = req.path ?? WindowScreenshot.defaultDestinationPath()
            if let validationError = WindowScreenshot.validateDestination(atPath: path) {
                return .failure(validationError)
            }
            guard let preparation = ControlServer.runOnMainActor(
                timeout: controlMainQueueTimeout,
                scheduler: controlMainQueue,
                { [weak self] () -> ScreenshotPreparation in
                    guard let self else { return .failure("app shutting down") }
                    return self.prepareScreenshot()
                }
            ) else {
                return ControlServer.busyResponse
            }
            switch preparation {
            case .failure(let error):
                return .failure(error)
            case .ready(let request):
                return WindowScreenshot.capture(
                    request,
                    to: path,
                    captureImage: screenshotImageCapturer
                )
            }
        }
        guard let response = ControlServer.runOnMainActor(
            timeout: controlMainQueueTimeout,
            scheduler: controlMainQueue,
            { [weak self] () -> ControlResponse in
                guard let self else { return .failure("app shutting down") }
                return self.handle(req)
            }
        ) else {
            return ControlServer.busyResponse
        }
        return response
    }

    func stopServer() {
        server?.stop()
    }

    /// Best-effort: symlink the bundled binary onto the user's PATH so terminal
    /// hooks can call `copilot-projects`.
    func installCLISymlinkIfPossible() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        do {
            try CLILauncher.install(in: dir)
        } catch {
            NSLog("copilot-projects: could not install CLI launcher: %@", String(describing: error))
        }
    }

    // MARK: - derived

    var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first { $0.id == id }
    }

    func project(_ id: String) -> Project? {
        projects.first { $0.id == id }
    }

    private var cachedAvailableHosts: (hosts: [RemoteHostInfo], loadedAt: TimeInterval)?

    var availableHosts: [RemoteHostInfo] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached = cachedAvailableHosts, now - cached.loadedAt < 2.0 {
            return cached.hosts
        }
        let hosts = availableHostsProvider()
        cachedAvailableHosts = (hosts, now)
        return hosts
    }

    func resolvedRemoteHost(
        hostId: String?,
        projectDefaultHostId: String? = nil
    ) -> RemoteHostInfo? {
        SSHHostCatalog.resolve(
            hostId: hostId,
            projectDefaultHostId: projectDefaultHostId,
            in: availableHosts
        )
    }

    func resolvedRemoteHost(for session: Session, in hosts: [RemoteHostInfo]? = nil) -> RemoteHostInfo? {
        let candidate = [session.hostId, resumeMarkerValue(sessionId: session.id, suffix: "remote-host")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let candidate,
              candidate.caseInsensitiveCompare(RemoteHostInfo.localId) != .orderedSame else {
            return nil
        }
        return SSHHostCatalog.resolve(hostId: candidate, in: hosts ?? availableHosts)
            ?? RemoteHostInfo(id: candidate, displayName: candidate, sshTarget: candidate, isLocal: false)
    }

    func effectiveHostId(forProjectId pid: String) -> String {
        guard let project = project(pid),
              let defaultHostId = project.defaultHostId,
              !defaultHostId.isEmpty else {
            return RemoteHostInfo.localId
        }
        return defaultHostId
    }

    func setProjectDefaultHost(_ pid: String, hostId: String?) {
        guard let pi = projectIndex(pid) else { return }
        let resolved = hostId.flatMap { raw -> RemoteHostInfo? in
            guard !raw.isEmpty, raw.lowercased() != RemoteHostInfo.localId else { return nil }
            return resolvedRemoteHost(hostId: raw)
                ?? RemoteHostInfo(id: raw, displayName: raw, sshTarget: raw, isLocal: false)
        }
        guard projects[pi].defaultHostId != resolved?.id else { return }
        projects[pi].defaultHostId = resolved?.id
        projects[pi].cwd = resolved?.defaultCwd ?? Paths.defaultStartupDir
        save()
    }

    private var currentSelectedSessionId: String? {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return nil }
        return projects[pi].selectedSessionId
    }

    // MARK: - terminal controllers (lazy, cached, not observed)

    /// Returns (creating if needed) the live terminal for a session. A cached
    /// controller is always returned as-is, so a duplicate create request can never
    /// relaunch an existing session. `copilotExecutable` is honored ONLY when a
    /// controller is created here (a fresh remote session).
    /// Ordinary restoration keeps recorded resume behavior; configured remote
    /// launches ignore stale markers left behind for a recycled session id.
    /// `resumeCopilotSessionId` resumes that Copilot session instead of any recorded one.
    @discardableResult
    func controller(
        for sessionId: String,
        resumeRecordedSession: Bool = true,
        copilotExecutable: String? = nil,
        launchCopilotInitialPrompt: String? = nil,
        resumeCopilotSessionId: String? = nil
    ) -> TerminalController? {
        if let c = controllers[sessionId] { return c }
        guard !isTerminating else { return nil }
        guard let loc = locateIndex(sessionId) else { return nil }
        let project = projects[loc.p]
        let session = project.sessions[loc.s]
        Paths.ensureStateDir()
        let dtach = Paths.dtachExecutable
        let socket = dtach != nil ? Paths.dtachSocketPath(sessionId: sessionId) : nil
        // Last Copilot session id seen in this tab (written by the hook). If the
        // shell is created fresh after a reboot, the controller resumes this exact
        // agent session; on a normal relaunch dtach reattaches and ignores it.
        let rawRecordedCopilot = (try? String(contentsOf:
            resumeMarkerDirectory.appendingPathComponent("\(sessionId).copilot-session"),
            encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // isCopilotSessionQuarantined only sees a foreign owner that some
        // TranscriptController has already read and recorded — but background
        // tabs never get a TranscriptController, and at bootstrap the selected
        // tab's hasn't started yet. Validate the owner marker directly here too
        // (this also records the quarantine as a side effect) so a foreign
        // owner can't be resumed before anything else has observed it.
        let ownerAllowsResume = TranscriptController.transcriptOwnerAllowsRead(
            sessionId: sessionId,
            directory: resumeMarkerDirectory
        )
        let recordedCopilot = rawRecordedCopilot.flatMap { candidate -> String? in
            guard resumeRecordedSession, ownerAllowsResume else { return nil }
            return TranscriptController.isCopilotSessionQuarantined(
                sessionId: sessionId,
                copilotSessionId: candidate,
                directory: resumeMarkerDirectory
            ) ? nil : candidate
        }
        let c = TerminalController(
            sessionId: sessionId,
            cwd: session.cwd,
            extraEnvironment: environment(projectId: project.id, sessionId: sessionId),
            dtachExecutable: dtach,
            dtachSocket: socket,
            copilotSessionId: resumeCopilotSessionId.flatMap { TerminalController.isSafeSessionId($0) ? $0 : nil }
                ?? ((recordedCopilot?.isEmpty == false) ? recordedCopilot : nil),
            launchCopilotExecutable: copilotExecutable,
            launchCopilotInitialPrompt: launchCopilotInitialPrompt,
            remoteHost: resolvedRemoteHost(for: session),
            remoteWrapperExecutable: remoteWrapperExecutable(),
            kittyImageDiskStore: kittyImageDiskStore
        )
        c.onTitle = { [weak self] title in self?.updateTitle(sessionId: sessionId, title: title) }
        c.onDirectory = { [weak self] dir in self?.updateCwd(sessionId: sessionId, dir: dir) }
        c.onExit = { [weak self] _ in self?.handleExit(sessionId: sessionId) }
        c.shouldRetryLaunch = { [weak self, weak c] in
            guard let self, let c else { return false }
            return !self.isTerminating && self.controllers[sessionId] === c
        }
        controllers[sessionId] = c
        return c
    }

    /// The live terminal for the currently visible session (without creating one)
    /// — used by the scroll-wheel monitor.
    var activeController: TerminalController? {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return nil }
        guard let sid = projects[pi].selectedSessionId ?? projects[pi].sessions.first?.id
        else { return nil }
        return controllers[sid]
    }

    // MARK: - persistent terminal container

    /// Ensure the selected project's sessions all have live controllers — preserves
    /// the prior behavior where opening a project starts its sessions. Driven from
    /// the terminal container's update pass.
    func ensureSelectedProjectControllers() {
        guard let project = selectedProject else { return }
        for session in project.sessions { controller(for: session.id) }
    }

    /// Every live terminal view keyed by session id — the full set the persistent
    /// AppKit container hosts, so terminals are never unmounted on a project/tab
    /// switch (only their z-order changes).
    var hostedTerminals: [(id: String, view: ProjectsTerminalView)] {
        controllers.map { (id: $0.key, view: $0.value.terminalView) }
    }

    func terminalView(for sessionId: String) -> ProjectsTerminalView? {
        controllers[sessionId]?.terminalView
    }

    /// The globally selected session (selected project's selected tab, falling back
    /// to its first tab) — the one the container brings to the front.
    var globalSelectedSessionId: String? {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return nil }
        return projects[pi].selectedSessionId ?? projects[pi].sessions.first?.id
    }

    var activeTranscriptController: TranscriptController? {
        guard let sessionId = globalSelectedSessionId else { return nil }
        guard selectedTranscriptController?.sessionId == sessionId else { return nil }
        return selectedTranscriptController
    }

    func refreshSelectedTranscriptController() {
        syncSessionNavigationHistory()
        guard let sessionId = globalSelectedSessionId else {
            selectedTranscriptController = nil
            return
        }
        guard selectedTranscriptController?.sessionId != sessionId else { return }
        let controller = TranscriptController(sessionId: sessionId)
        selectedTranscriptController = controller
        controller.start()
    }

    private func syncSessionNavigationHistory() {
        let validIds = Set(projects.flatMap { $0.sessions.map(\.id) })
        if isNavigatingSessionHistory {
            sessionNavigationHistory.prune(validSessionIds: validIds)
        } else {
            sessionNavigationHistory.reconcile(
                validSessionIds: validIds,
                currentSessionId: globalSelectedSessionId
            )
        }
    }

    var canNavigateSessionBack: Bool { sessionNavigationHistory.canGoBack }
    var canNavigateSessionForward: Bool { sessionNavigationHistory.canGoForward }

    var previousHistorySessionTitle: String? {
        guard let id = sessionNavigationHistory.backTarget,
              let loc = locateIndex(id) else { return nil }
        return projects[loc.p].sessions[loc.s].title
    }

    var nextHistorySessionTitle: String? {
        guard let id = sessionNavigationHistory.forwardTarget,
              let loc = locateIndex(id) else { return nil }
        return projects[loc.p].sessions[loc.s].title
    }

    var backHistoryMenuItems: [SessionHistoryMenuItem] {
        historyMenuItems(for: sessionNavigationHistory.backEntries())
    }

    var forwardHistoryMenuItems: [SessionHistoryMenuItem] {
        historyMenuItems(for: sessionNavigationHistory.forwardEntries())
    }

    private func historyMenuItems(
        for entries: [(index: Int, sessionId: String)]
    ) -> [SessionHistoryMenuItem] {
        entries.compactMap { entry in
            guard let loc = locateIndex(entry.sessionId) else { return nil }
            let project = projects[loc.p]
            let session = project.sessions[loc.s]
            return SessionHistoryMenuItem(
                index: entry.index,
                projectId: project.id,
                projectName: project.name,
                sessionId: session.id,
                sessionTitle: session.title
            )
        }
    }

    @discardableResult
    func navigateToSessionHistory(index: Int) -> (projectId: String, sessionId: String)? {
        let validIds = Set(projects.flatMap { $0.sessions.map(\.id) })
        guard let targetId = sessionNavigationHistory.goTo(index: index, validSessionIds: validIds),
              let loc = locateIndex(targetId) else { return nil }
        let projectId = projects[loc.p].id
        isNavigatingSessionHistory = true
        defer { isNavigatingSessionHistory = false }
        show(projectId: projectId, sessionId: targetId)
        save()
        focusActiveTerminal()
        return (projectId, targetId)
    }

    @discardableResult
    func navigateSessionBack() -> (projectId: String, sessionId: String)? {
        let validIds = Set(projects.flatMap { $0.sessions.map(\.id) })
        guard let targetId = sessionNavigationHistory.goBack(validSessionIds: validIds),
              let loc = locateIndex(targetId) else { return nil }
        let projectId = projects[loc.p].id
        isNavigatingSessionHistory = true
        defer { isNavigatingSessionHistory = false }
        show(projectId: projectId, sessionId: targetId)
        save()
        focusActiveTerminal()
        return (projectId, targetId)
    }

    @discardableResult
    func navigateSessionForward() -> (projectId: String, sessionId: String)? {
        let validIds = Set(projects.flatMap { $0.sessions.map(\.id) })
        guard let targetId = sessionNavigationHistory.goForward(validSessionIds: validIds),
              let loc = locateIndex(targetId) else { return nil }
        let projectId = projects[loc.p].id
        isNavigatingSessionHistory = true
        defer { isNavigatingSessionHistory = false }
        show(projectId: projectId, sessionId: targetId)
        save()
        focusActiveTerminal()
        return (projectId, targetId)
    }

    func isTranscriptDrawerOpen(sessionId: String) -> Bool {
        transcriptOpenSessions.contains(sessionId)
    }

    func closeTranscriptDrawer(sessionId: String) {
        transcriptOpenSessions.remove(sessionId)
    }

    func openTranscriptDrawer(sessionId: String) {
        transcriptOpenSessions.insert(sessionId)
    }

    /// Message + button title shown by the container when nothing is selected.
    var emptyContextHint: (message: String, button: String) {
        if let project = selectedProject {
            return ("No sessions in “\(project.name)”", "New Copilot Session")
        }
        return ("No project selected", "New Project…")
    }

    /// Backs the empty-state button: add a session to the selected project, or
    /// create a project if there is none.
    func newInActiveContext() {
        if let pid = selectedProjectId {
            addCopilotSessionInteractive(toProjectId: pid)
        } else {
            addProjectInteractive()
        }
    }

    private func environment(projectId: String, sessionId: String) -> [String: String] {
        [
            "COPILOT_PROJECTS": "1",
            "COPILOT_PROJECTS_SOCKET": Paths.socketPath,
            "COPILOT_PROJECTS_PROJECT": projectId,
            "COPILOT_PROJECTS_SESSION": sessionId,
        ]
    }

    // MARK: - project / session mutations

    private func makeProject(
        name: String,
        cwd: String,
        defaultHostId: String? = nil,
        withSession: Bool
    ) -> Project {
        var project = Project(name: name, cwd: cwd, defaultHostId: defaultHostId)
        if withSession {
            let session = Session(title: "shell", cwd: cwd, hostId: defaultHostId)
            project.sessions = [session]
            project.selectedSessionId = session.id
        }
        return project
    }

    /// Create a project from just a name (no folder required).
    func addProjectInteractive() {
        let defaultName = "Project \(projects.count + 1)"
        guard let name = promptForText(
            title: "New Project",
            message: "Name this project. Sessions can run anywhere — a project is just a group.",
            confirmTitle: "Create",
            initialText: defaultName
        ) else { return }
        guard !isTerminating else { return }
        let project = makeProject(name: name, cwd: Paths.defaultStartupDir, withSession: false)
        projects.append(project)
        selectProject(project.id)
        addCopilotSessionInteractive(toProjectId: project.id)
    }

    /// Shared single-field prompt. Returns trimmed text, or nil if empty/cancelled.
    private func promptForText(title: String, message: String,
                               confirmTitle: String, initialText: String,
                               transform: ((String) -> String)? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = transform?(initialText) ?? initialText
        var previousValue = field.stringValue
        let observer = transform.map { _ in
            NotificationCenter.default.addObserver(
                forName: NSControl.textDidChangeNotification,
                object: field,
                queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    let current = field.stringValue
                    let updated = PullRequestReviewTarget.trimmingPastedFragment(
                        from: previousValue,
                        to: current
                    )
                    if updated != current {
                        field.stringValue = updated
                    }
                    previousValue = field.stringValue
                }
            }
        }
        defer {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alertPresenter(alert) == .alertFirstButtonReturn else { return nil }
        let raw = transform?(field.stringValue) ?? field.stringValue
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    func addSession(toProjectId pid: String, cwd: String? = nil, hostId: String? = nil) -> String? {
        guard let pi = projectIndex(pid),
              let resolvedHost = resolvedRemoteHost(
                  hostId: hostId,
                  projectDefaultHostId: projects[pi].defaultHostId
              ) else { return nil }
        let dir = cwd ?? defaultCwd(forProjectIndex: pi, targetHost: resolvedHost)
        let sessionHostId = resolvedHost.isLocal ? nil : resolvedHost.id
        let session = Session(title: "shell", cwd: dir, hostId: sessionHostId)
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        controller(for: session.id)
        refreshSelectedTranscriptController()
        save()
        return session.id
    }

    enum CopilotSessionStartError: LocalizedError {
        case shuttingDown, projectUnavailable, backendUnavailable, copilotUnavailable
        case remoteWrapperUnavailable(String)
        case invalidPrompt, terminalUnavailable
        case workingDirectoryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .shuttingDown:
                return "The app is quitting. Reopen it before starting a session."
            case .projectUnavailable:
                return "This project is no longer available. Select a project and try again."
            case .backendUnavailable:
                return "The bundled terminal backend is unavailable. Reinstall the app, or use New Terminal."
            case .copilotUnavailable:
                return "Install the Copilot CLI or set COPILOT_PROJECTS_COPILOT to its executable, or use New Terminal."
            case .remoteWrapperUnavailable(let host):
                return "Configure the remote Copilot wrapper for \(host) or set COPILOT_PROJECTS_REMOTE_WRAPPER, or use New Terminal."
            case .invalidPrompt:
                return "Enter a prompt of at most 8,192 UTF-8 bytes, without terminal control characters."
            case .workingDirectoryUnavailable(let path):
                return "The working directory no longer exists: \(path). Choose a session with an existing directory."
            case .terminalUnavailable:
                return "The terminal could not be started. Your prompt has not been submitted."
            }
        }
    }

    func copilotSessionExecutable(toProjectId pid: String, hostId: String? = nil) throws -> String {
        guard !isTerminating else { throw CopilotSessionStartError.shuttingDown }
        guard let pi = projectIndex(pid) else { throw CopilotSessionStartError.projectUnavailable }
        guard remoteSessionBackendAvailable() else { throw CopilotSessionStartError.backendUnavailable }
        guard let resolvedHost = resolvedRemoteHost(
            hostId: hostId,
            projectDefaultHostId: projects[pi].defaultHostId
        ) else {
            throw CopilotSessionStartError.backendUnavailable
        }
        if resolvedHost.isLocal {
            guard let executable = remoteCopilotExecutable() else {
                throw CopilotSessionStartError.copilotUnavailable
            }
            return executable
        }
        guard let wrapper = remoteWrapperExecutable() else {
            throw CopilotSessionStartError.remoteWrapperUnavailable(resolvedHost.displayName)
        }
        return wrapper
    }

    func addCopilotSessionInteractive(
        toProjectId pid: String,
        withPrompt: Bool = false,
        hostId: String? = nil
    ) {
        do {
            if withPrompt {
                guard !isTerminating else { throw CopilotSessionStartError.shuttingDown }
                guard projectIndex(pid) != nil else { throw CopilotSessionStartError.projectUnavailable }
                guard remoteSessionBackendAvailable() else { throw CopilotSessionStartError.backendUnavailable }
                let hosts = availableHosts
                let initialHostId = hostId ?? effectiveHostId(forProjectId: pid)
                if hosts.count <= 1, initialHostId.caseInsensitiveCompare(RemoteHostInfo.localId) == .orderedSame {
                    _ = try copilotSessionExecutable(toProjectId: pid, hostId: hostId)
                }
                let composer = CopilotPromptComposer(
                    availableHosts: hosts,
                    selectedHostId: initialHostId
                )
                let outcome = composer.run { prompt in
                    try self.addCopilotSession(
                        toProjectId: pid,
                        initialPrompt: prompt,
                        hostId: composer.selectedHostId
                    )
                }
                if outcome == .newTerminal, !isTerminating {
                    addSession(toProjectId: pid, hostId: composer.selectedHostId)
                }
            } else {
                try addCopilotSession(toProjectId: pid, hostId: hostId)
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could Not Start Copilot"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            if let startError = error as? CopilotSessionStartError {
                switch startError {
                case .copilotUnavailable, .remoteWrapperUnavailable, .backendUnavailable:
                    alert.addButton(withTitle: "New Terminal")
                default:
                    break
                }
            }
            if alert.runModal() == .alertSecondButtonReturn, !isTerminating {
                addSession(toProjectId: pid, hostId: hostId)
            }
        }
    }

    @discardableResult
    func addCopilotSession(
        toProjectId pid: String,
        initialPrompt: String? = nil,
        hostId: String? = nil
    ) throws -> String {
        // Revalidate after the composer: its modal run loop permits project changes.
        let executable = try copilotSessionExecutable(toProjectId: pid, hostId: hostId)
        guard let pi = projectIndex(pid),
              let resolvedHost = resolvedRemoteHost(
                  hostId: hostId,
                  projectDefaultHostId: projects[pi].defaultHostId
              ) else {
            throw CopilotSessionStartError.projectUnavailable
        }
        if let initialPrompt, !SessionInputValidation.isValidPrompt(initialPrompt) {
            throw CopilotSessionStartError.invalidPrompt
        }
        let cwd = Paths.normalizedDirectory(defaultCwd(forProjectIndex: pi, targetHost: resolvedHost))
        if resolvedHost.isLocal {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CopilotSessionStartError.workingDirectoryUnavailable(cwd)
            }
        }
        let prompt = initialPrompt?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let sessionHostId = resolvedHost.isLocal ? nil : resolvedHost.id
        let session = Session(title: "Copilot", cwd: cwd, hostId: sessionHostId)
        let previousSelection = projects[pi].selectedSessionId
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        // No modal or suspension between appending and creating the launch controller:
        // a view update must not lazily create a plain shell for this tab.
        launchSession(session.id, executable: executable, initialPrompt: prompt)
        if remoteSessionLauncher == nil, controllers[session.id]?.terminalView.process?.running != true {
            controllers[session.id] = nil
            projects[pi].sessions.removeAll { $0.id == session.id }
            projects[pi].selectedSessionId = previousSelection
            throw CopilotSessionStartError.terminalUnavailable
        }
        refreshSelectedTranscriptController()
        save()
        return session.id
    }

    func startingPrompt(for sessionId: String) -> String? {
        controllers[sessionId]?.startingPrompt
    }

    func copyStartingPrompt(for sessionId: String) {
        guard let prompt = startingPrompt(for: sessionId) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    func addAdversarialReviewSessionInteractive(
        toProjectId pid: String,
        hostId: String? = nil
    ) {
        do {
            _ = try copilotSessionExecutable(toProjectId: pid, hostId: hostId)
        } catch {
            presentAlert(
                title: "Copilot Is Unavailable",
                message: error.localizedDescription
            )
            return
        }
        var initialText = ""
        while let input = promptForText(
            title: "Review Pull Request",
            message: "Paste a GitHub pull request URL. Copilot will start a local adversarial review.",
            confirmTitle: "Review",
            initialText: initialText,
            transform: PullRequestReviewTarget.withoutFragment
        ) {
            if addAdversarialReviewSession(
                toProjectId: pid,
                pullRequestURL: input,
                hostId: hostId
            ) != nil {
                return
            }
            initialText = input
            presentAlert(
                title: "Invalid Pull Request URL",
                message: "Use an HTTPS github.com URL such as https://github.com/owner/repo/pull/123."
            )
        }
    }

    @discardableResult
    func addAdversarialReviewSession(
        toProjectId pid: String,
        pullRequestURL: String,
        hostId: String? = nil
    ) -> String? {
        guard let pi = projectIndex(pid),
              let target = PullRequestReviewTarget.parse(pullRequestURL),
              let resolvedHost = resolvedRemoteHost(
                  hostId: hostId,
                  projectDefaultHostId: projects[pi].defaultHostId
              ),
              let copilotExecutable = try? copilotSessionExecutable(toProjectId: pid, hostId: resolvedHost.id) else {
            return nil
        }

        let cwd = defaultCwd(forProjectIndex: pi, targetHost: resolvedHost)
        let sessionHostId = resolvedHost.isLocal ? nil : resolvedHost.id
        let session = Session(title: target.title, cwd: cwd, hostId: sessionHostId)
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        let prompt = pullRequestReviewPrompt(for: target)
        launchSession(
            session.id,
            executable: copilotExecutable,
            initialPrompt: prompt
        )
        refreshSelectedTranscriptController()
        save()
        return session.id
    }

    func launchSession(
        _ sessionId: String,
        executable: String?,
        initialPrompt: String?,
        resumeRecordedSession: Bool = true,
        resumeCopilotSessionId: String? = nil
    ) {
        if let remoteSessionLauncher {
            remoteSessionLauncher(sessionId, executable, initialPrompt)
            if let resumeCopilotSessionId { capturedResumeLaunches[sessionId] = resumeCopilotSessionId }
        } else {
            controller(
                for: sessionId,
                resumeRecordedSession: resumeRecordedSession,
                copilotExecutable: executable,
                launchCopilotInitialPrompt: initialPrompt,
                resumeCopilotSessionId: resumeCopilotSessionId
            )
        }
    }

    nonisolated static func adversarialReviewPrompt(for target: PullRequestReviewTarget) -> String {
        PullRequestReviewPrompt.builtIn.prompt(for: target)
    }

    func pullRequestReviewPrompt(for target: PullRequestReviewTarget) -> String {
        PullRequestReviewPrompt.stored(in: defaults).prompt(for: target)
    }

    func configurePullRequestReviewPromptInteractive(
        present: @MainActor (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) {
        guard let updated = PullRequestReviewPromptEditor.runModal(
            initialPrompt: PullRequestReviewPrompt.stored(in: defaults),
            present: present
        ) else {
            return
        }
        updated.save(to: defaults)
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        _ = alertPresenter(alert)
    }

    /// Where a new session should start: inherit the active pane's directory
    /// (kept fresh by OSC 7 when the shell emits it), else the project default,
    /// else the default startup folder (~/Repos).
    func defaultCwd(forProjectIndex pi: Int, targetHost: RemoteHostInfo? = nil) -> String {
        let project = projects[pi]
        let targetHostId = (targetHost?.isLocal == false) ? targetHost?.id : nil
        if let sid = project.selectedSessionId,
           let session = project.sessions.first(where: { $0.id == sid }),
           resolvedRemoteHost(for: session)?.id == targetHostId,
           !session.cwd.isEmpty {
            return session.cwd
        }
        if project.defaultHostId == targetHostId, !project.cwd.isEmpty {
            return project.cwd
        }
        if targetHostId != nil, let remoteDefault = targetHost?.defaultCwd, !remoteDefault.isEmpty {
            return remoteDefault
        }
        return Paths.defaultStartupDir
    }

    func addSessionToSelected() {
        guard let pid = selectedProjectId else { return }
        addCopilotSessionInteractive(toProjectId: pid)
    }

    func addPromptedSessionToSelected() {
        guard let pid = selectedProjectId else { return }
        addCopilotSessionInteractive(toProjectId: pid, withPrompt: true)
    }

    func addTerminalToSelected() {
        guard let pid = selectedProjectId else { return }
        addSession(toProjectId: pid)
    }

    func closeSession(projectId pid: String, sessionId sid: String) {
        closeSession(projectId: pid, sessionId: sid, terminateController: true)
    }

    private func closeSession(
        projectId pid: String,
        sessionId sid: String,
        terminateController: Bool
    ) {
        guard let pi = projectIndex(pid) else { return }
        let previousGlobalSelection = globalSelectedSessionId
        if terminateController {
            controllers[sid]?.terminate()
        }
        controllers[sid] = nil
        sessionPromptComposers.removeValue(forKey: sid)?.clearAttachments(force: true)
        if selectedTranscriptController?.sessionId == sid {
            selectedTranscriptController = nil
        }
        transcriptOpenSessions.remove(sid)
        sessionSemantics.reset(sessionId: sid)
        backgroundAgentsSuppressed.remove(sid)
        completionPending.remove(sid)
        completionSummaryContexts[sid] = nil
        permissionNotificationTokens[sid] = nil
        elicitationNotificationTokens[sid] = nil
        permissionStatusRestores[sid] = nil
        inputWaits[sid] = nil
        remotePromptFences[sid] = nil
        runtimeTrackedOwners[sid] = nil
        scheduledSnapshotsSuppressed.remove(sid)
        foregroundIdleGenerationBaselines.removeValue(forKey: sid)
        let closedIndex = projects[pi].sessions.firstIndex { $0.id == sid }
        let wasSelected = projects[pi].selectedSessionId == sid
        projects[pi].sessions.removeAll { $0.id == sid }
        if locateIndex(sid) == nil {
            remoteControlDeliveryLedger.removeClosedSession(sid)
            dismissQuestionNotifications(sessionId: sid)
        }
        if wasSelected {
            if projects[pi].sessions.isEmpty {
                projects[pi].selectedSessionId = nil
            } else {
                // Select the tab to the left of the one just closed (or the new
                // leftmost if the closed tab was first), rather than jumping to
                // the first tab.
                let newIndex = max(0, (closedIndex ?? 0) - 1)
                projects[pi].selectedSessionId = projects[pi].sessions[newIndex].id
            }
        }
        clearManualMarkIfShown(replacing: previousGlobalSelection)
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
    }

    func closeSelectedSession() {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              let sid = projects[pi].selectedSessionId else { return }
        requestCloseSession(projectId: pid, sessionId: sid)
    }

    /// User-facing ending uses reported activity; automation retains the raw close path.
    func requestCloseSession(projectId pid: String, sessionId sid: String) {
        guard let pi = projectIndex(pid),
              let session = projects[pi].sessions.first(where: { $0.id == sid }) else { return }
        if session.requiresEndConfirmation {
            guard confirmEnding(
                title: "End session \"\(session.title)\"?",
                message: "This session has active or pending work. Ending it stops its processes and removes its tab. It will not resume when the app restarts. Project files are not deleted.",
                action: "End Session"
            ) else { return }
        }
        if !destroySession(projectId: pid, sessionId: sid) {
            presentAlert(
                title: "Could Not End Session",
                message: "The session may have changed or its state could not be saved. Review it before trying again."
            )
        }
    }

    private func confirmEnding(title: String, message: String, action: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let cancel = alert.addButton(withTitle: "Cancel")
        let end = alert.addButton(withTitle: action)
        cancel.keyEquivalent = "\u{1b}"
        end.keyEquivalent = ""
        end.hasDestructiveAction = true
        alert.window.initialFirstResponder = cancel
        return alertPresenter(alert) == .alertSecondButtonReturn
    }

    /// Permanently end a session: ask Copilot to exit through its own TUI, retain
    /// the existing forced dtach teardown as a bounded fallback, and remove the
    /// tab from the model immediately.
    func destroySession(projectId pid: String, sessionId sid: String) -> Bool {
        guard let pi = projectIndex(pid),
              projects[pi].sessions.contains(where: { $0.id == sid }),
              acceptSessionCloses(sessionIds: [sid]) else { return false }
        let controller = controllers[sid]
        controller?.terminalView.kittyImageCapture.disablePersistence()
        scheduleSessionDestroy(
            sessions: [(id: sid, controller: controller)]
        )
        closeSession(
            projectId: pid,
            sessionId: sid,
            terminateController: Paths.dtachExecutable != nil
        )
        return true
    }

    private func acceptSessionCloses(sessionIds: [String], projectIds: [String] = []) -> Bool {
        guard stateLoadFailure == nil else { return false }
        do {
            try stateSaveQueue.sync {
                try stateRepository.acceptCloses(sessionIds: sessionIds, projectIds: projectIds)
            }
            return true
        } catch {
            NSLog("copilot-projects: could not accept session close: \(error)")
            return false
        }
    }

    private func finishPersistedSessionCloses() {
        guard pendingSessionDestroys.isEmpty, stateLoadFailure == nil else { return }
        let state = PersistedState(projects: projects, selectedProjectId: selectedProjectId)
        do {
            let didSave = try stateSaveQueue.sync {
                try stateRepository.finishCloses(state)
            }
            if didSave {
                saveWork?.cancel()
                saveWork = nil
            }
        } catch {
            NSLog("copilot-projects: retaining interrupted session closes: \(error)")
        }
    }

    private func scheduleSessionDestroy(
        sessions: [(id: String, controller: TerminalController?)]
    ) {
        guard !sessions.isEmpty else { return }
        let sessionIds = sessions.map(\.id)
        let cleanup = gracefulSessionDestroyer(
            sessionIds,
            kittyImageDiskStore
        )
        for session in sessions {
            pendingSessionDestroys[session.id] = PendingSessionDestroy(
                task: cleanup,
                controller: Paths.dtachExecutable == nil
                    ? session.controller
                    : nil
            )
        }
        Task { @MainActor [weak self] in
            await cleanup.value
            for sessionId in sessionIds {
                self?.completeSessionDestroy(sessionId)
            }
        }
    }

    private func completeSessionDestroy(_ sessionId: String) {
        guard let pending = pendingSessionDestroys.removeValue(
            forKey: sessionId
        ) else {
            return
        }
        if Paths.dtachExecutable == nil {
            pending.controller?.terminate()
        }
        finishPersistedSessionCloses()
    }

    /// Detach (don't destroy) every live terminal — used on app quit so dtach
    /// masters survive and sessions resume on next launch.
    func detachAllClients() {
        for controller in controllers.values {
            controller.terminate()
        }
        controllers.removeAll()
    }

    func detachAllClientsAndDrain(closeTimeout: Duration = .seconds(2)) async {
        // Independent of the destroy tasks: cancellation does not guarantee an
        // awaited task/continuation will finish. Poll the main-actor ledger, not
        // the tasks themselves, so quit can enforce its own deadline.
        let closeDeadline = ContinuousClock.now.advanced(by: closeTimeout)
        let activeControllers = Array(controllers.values)
        for controller in activeControllers {
            controller.beginTerminationDrain()
        }
        for controller in activeControllers {
            await controller.finishTerminationDrain()
        }
        controllers.removeAll()
        if isPoweringOff {
            forcePendingSessionDestroys()
        } else {
            while !pendingSessionDestroys.isEmpty, ContinuousClock.now < closeDeadline {
                try? await ContinuousClock().sleep(
                    until: min(.now.advanced(by: .milliseconds(25)), closeDeadline))
            }
            forcePendingSessionDestroys()
        }
    }

    func flushKittyImagePersistence() async {
        await kittyImageDiskStore.flush()
    }

    func beginTermination() {
        guard !isTerminating else { return }
        isTerminating = true
        powerOffProtectionGeneration += 1
        footerTimer?.invalidate()
        livenessTimer?.invalidate()
        agentActivityTimer?.invalidate()
        agentActivitySource?.cancel()
        agentActivitySource = nil
        agentActivityRefreshGeneration += 1
        integration?.stop()
    }

    func forcePendingSessionDestroys() {
        let pending = pendingSessionDestroys
        pendingSessionDestroys.removeAll()
        for destroy in pending.values {
            destroy.task.cancel()
        }
        forcedSessionDestroyer(Array(pending.keys))
        if Paths.dtachExecutable == nil {
            for destroy in pending.values {
                destroy.controller?.terminate()
            }
        }
        finishPersistedSessionCloses()
    }

    func finishInterruptedSessionDestroys() {
        guard stateLoadFailure == nil else { return }
        do {
            let intent = try stateRepository.pendingCloses()
            let state = try stateRepository.normalized(intent.applying(
                to: PersistedState(projects: projects, selectedProjectId: selectedProjectId)
            ))
            projects = state.projects
            selectedProjectId = state.selectedProjectId
            for sessionId in intent.sessionIds {
                _ = kittyImageDiskStore.tombstone(sessionId: sessionId)
            }
            forcedSessionDestroyer(Array(intent.sessionIds))
            finishPersistedSessionCloses()
            syncSessionNavigationHistory()
            if didLoadWorkspaceState {
                SessionArtifacts.removeLeakedFiles(
                    keeping: Set(projects.flatMap { $0.sessions.map(\.id) })
                        .union(intent.sessionIds),
                    sessionsDirectory: agentActivityDirectory
                )
            }
        } catch {
            let message = "Could not recover session closes (intent: \(stateRepository.closeIntentPath.path)): \(error)"
            stateLoadFailure = message
            NSLog("copilot-projects: \(message)")
        }
    }

    func prepareForSystemPowerOff(protectionInterval: TimeInterval = 300) {
        isPoweringOff = true
        powerOffProtectionGeneration += 1
        let generation = powerOffProtectionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + protectionInterval) { [weak self] in
            guard let self,
                  !self.isTerminating,
                  self.powerOffProtectionGeneration == generation else { return }
            self.isPoweringOff = false
        }
    }

    func startIntegration() {
        integration?.start()
    }

    /// Fleet roll-ups across every project, for the title-bar status line.
    var totalRunning: Int { projects.reduce(0) { $0 + $1.runningCount } }
    var totalWaiting: Int { projects.reduce(0) { $0 + $1.waitingCount } }
    var totalFailed: Int { projects.reduce(0) { $0 + $1.failedCount } }
    var totalBackgroundWork: Int {
        projects.reduce(0) { $0 + $1.backgroundWorkCount }
    }
    var totalScheduled: Int {
        projects.reduce(0) { $0 + $1.scheduledCount }
    }
    var totalReady: Int {
        projects.reduce(0) { $0 + $1.sessions.filter { $0.finishedUnseen }.count }
    }

    var hasAttentionSessions: Bool {
        projects.contains { $0.sessions.contains { $0.attentionTier != nil } }
    }

    func requestCloseProject(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        let project = projects[pi]
        let approvedIDs = Set(project.sessions.map(\.id))
        let activeCount = project.sessions.filter(\.requiresEndConfirmation).count
        if project.sessions.count > 1 || activeCount > 0 {
            let names = project.sessions.prefix(5).map(\.title).joined(separator: ", ")
            let remainder = project.sessions.count > 5
                ? " and \(project.sessions.count - 5) more" : ""
            let scope = project.sessions.count == 1
                ? "This ends 1 session" : "This ends all \(project.sessions.count) sessions"
            let activity = activeCount == 1
                ? " One session has active or pending work."
                : activeCount > 1 ? " \(activeCount) sessions have active or pending work." : ""
            guard confirmEnding(
                title: "End project \"\(project.name)\"?",
                message: "\(scope): \(names)\(remainder).\(activity)\n\nAll affected processes stop and the project is removed from the sidebar. Ended sessions will not resume when the app restarts. Project files are not deleted.",
                action: "End Project"
            ) else { return }
            guard let current = projectIndex(pid) else { return }
            guard Set(projects[current].sessions.map(\.id)).isSubset(of: approvedIDs) else {
                presentAlert(
                    title: "Project Sessions Changed",
                    message: "A session was added to this project while confirmation was open. Nothing was ended. Review the project before trying again."
                )
                return
            }
        }
        closeProject(pid)
    }

    func closeProject(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        let previousGlobalSelection = globalSelectedSessionId
        guard acceptSessionCloses(
            sessionIds: projects[pi].sessions.map(\.id),
            projectIds: [pid]
        ) else {
            presentAlert(
                title: "Could Not End Project",
                message: "The end request could not be saved. The project has been left open."
            )
            return
        }
        let usesDtach = Paths.dtachExecutable != nil
        let sessions = projects[pi].sessions.map { session in
            (id: session.id, controller: controllers[session.id])
        }
        for session in sessions {
            session.controller?.terminalView.kittyImageCapture.disablePersistence()
        }
        scheduleSessionDestroy(sessions: sessions)
        for session in sessions {
            if usesDtach {
                session.controller?.terminate()
            }
            controllers[session.id] = nil
            sessionPromptComposers.removeValue(forKey: session.id)?.clearAttachments(force: true)
            if selectedTranscriptController?.sessionId == session.id {
                selectedTranscriptController = nil
            }
            transcriptOpenSessions.remove(session.id)
            backgroundAgentsSuppressed.remove(session.id)
            completionPending.remove(session.id)
            completionSummaryContexts[session.id] = nil
            scheduledSnapshotsSuppressed.remove(session.id)
            foregroundIdleGenerationBaselines.removeValue(forKey: session.id)
        }
        let closedSessionIds = projects[pi].sessions.map(\.id)
        projects.remove(at: pi)
        for sessionId in closedSessionIds where locateIndex(sessionId) == nil {
            remoteControlDeliveryLedger.removeClosedSession(sessionId)
            dismissQuestionNotifications(sessionId: sessionId)
        }
        if selectedProjectId == pid {
            selectedProjectId = projects.first?.id
            if let sid = currentSelectedSessionId { controller(for: sid) }
        }
        clearManualMarkIfShown(replacing: previousGlobalSelection)
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
        finishPersistedSessionCloses()
    }

    func renameProject(_ pid: String, name: String) {
        guard let pi = projectIndex(pid) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[pi].name = trimmed
        save()
    }

    func renameProjectInteractive(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        guard let name = promptForText(
            title: "Rename Project",
            message: "Enter a new name for this project.",
            confirmTitle: "Rename",
            initialText: projects[pi].name
        ) else { return }
        renameProject(pid, name: name)
    }

    func selectProject(_ id: String?) {
        selectedProjectId = id
        if let id, let pi = projectIndex(id) {
            for i in projects[pi].sessions.indices {
                projects[pi].sessions[i].hasUnread = false
            }
            // Only the project's visible (selected) tab counts as "seen" — leave the
            // other tabs' finished flags so the dot still nudges you to them.
            if let sid = projects[pi].selectedSessionId,
               let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) {
                projects[pi].sessions[si].finishedUnseen = false
                projects[pi].sessions[si].markedUnread = false
            }
            for session in projects[pi].sessions {
                controller(for: session.id)
            }
        }
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
    }

    func selectSession(projectId pid: String, sessionId sid: String) {
        guard let pi = projectIndex(pid) else { return }
        if let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) {
            projects[pi].sessions[si].hasUnread = false
            projects[pi].sessions[si].finishedUnseen = false
            projects[pi].sessions[si].markedUnread = false
        }
        projects[pi].selectedSessionId = sid
        controller(for: sid)
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
    }

    func selectSessionByIndex(_ index: Int) {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              index >= 0, index < projects[pi].sessions.count else { return }
        selectSession(projectId: pid, sessionId: projects[pi].sessions[index].id)
    }

    func selectProjectByIndex(_ index: Int) {
        guard index >= 0, index < projects.count else { return }
        selectProject(projects[index].id)
    }

    /// Reorder projects (drag-and-drop in the sidebar).
    func moveProjects(fromOffsets source: IndexSet, toOffset destination: Int) {
        projects.move(fromOffsets: source, toOffset: destination)
        save()
    }

    /// Reorder session tabs within a project (drag-and-drop in the tab bar).
    /// Inserts the dragged session immediately before `beforeId`, or at the end
    /// when `beforeId` is nil.
    func moveSession(projectId: String, draggedId: String, beforeId: String?) {
        guard let pi = projectIndex(projectId) else { return }
        var sessions = projects[pi].sessions
        guard let from = sessions.firstIndex(where: { $0.id == draggedId }) else { return }
        let item = sessions.remove(at: from)
        if let beforeId, let to = sessions.firstIndex(where: { $0.id == beforeId }) {
            sessions.insert(item, at: to)
        } else {
            sessions.append(item)
        }
        projects[pi].sessions = sessions
        save()
    }

    /// Move a session into another project by dragging its tab onto a project row
    /// in the sidebar. The live terminal is preserved — controllers are keyed by
    /// session id, so the agent keeps running and only the owning project changes
    /// (status/notification/focus routing all resolve by session id). No-op when
    /// dropped on the project the session already belongs to.
    @discardableResult
    func moveSession(
        toProjectId targetPid: String,
        draggedId sid: String,
        selectInTarget: Bool = true
    ) -> Bool {
        guard let tpi = projectIndex(targetPid), let from = locateIndex(sid),
              projects[from.p].id != targetPid else { return false }

        let previousGlobalSelection = globalSelectedSessionId
        let targetWasEmpty = projects[tpi].sessions.isEmpty
        let session = projects[from.p].sessions.remove(at: from.s)
        // Keep the source project's selection sane (mirrors closeSession): fall back
        // to the tab left of the one that moved, or clear if it's now empty.
        if projects[from.p].selectedSessionId == sid {
            projects[from.p].selectedSessionId =
                projects[from.p].sessions.isEmpty
                    ? nil
                    : projects[from.p].sessions[max(0, from.s - 1)].id
        }
        projects[tpi].sessions.append(session)
        if selectInTarget || targetWasEmpty {
            projects[tpi].selectedSessionId = session.id
        }
        clearManualMarkIfShown(replacing: previousGlobalSelection)
        if globalSelectedSessionId != previousGlobalSelection {
            refreshSelectedTranscriptController()
        }
        updateDockBadge()
        save()
        return true
    }

    func setNumberHint(_ hint: NumberHint) {
        if numberHint != hint { numberHint = hint }
    }

    func selectAdjacentSession(_ delta: Int) {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return }
        let sessions = projects[pi].sessions
        guard !sessions.isEmpty else { return }
        let current = sessions.firstIndex { $0.id == projects[pi].selectedSessionId } ?? 0
        let next = (current + delta + sessions.count) % sessions.count
        selectSession(projectId: pid, sessionId: sessions[next].id)
    }

    /// Jumps to the next session across all projects matching `kind`, starting
    /// after the currently selected session in workspace order and wrapping around.
    @discardableResult
    func selectNextSession(matching kind: FleetActivityKind) -> (projectId: String, sessionId: String)? {
        let all = projects.flatMap { project in
            project.sessions.map { (projectId: project.id, session: $0) }
        }
        guard !all.isEmpty else { return nil }
        let startIndex = all.firstIndex(where: { $0.session.id == globalSelectedSessionId })
            .map { ($0 + 1) % all.count } ?? 0
        for offset in 0..<all.count {
            let candidate = all[(startIndex + offset) % all.count]
            guard kind.matches(candidate.session) else { continue }
            show(projectId: candidate.projectId, sessionId: candidate.session.id)
            save()
            focusActiveTerminal()
            return (candidate.projectId, candidate.session.id)
        }
        return nil
    }

    /// Jumps to the next session across all projects that needs attention,
    /// cycling through a stable `(urgency tier, workspace order)` list
    /// (`waiting` → `failed` → `unread/finished`).
    @discardableResult
    func selectNextAttentionSession() -> (projectId: String, sessionId: String)? {
        let all = projects.flatMap { project in
            project.sessions.map { (projectId: project.id, session: $0) }
        }
        guard !all.isEmpty else { return nil }
        let ordered = all.enumerated().compactMap { index, entry -> (tier: SessionAttentionTier, workspaceIndex: Int, projectId: String, sessionId: String)? in
            guard let tier = entry.session.attentionTier else { return nil }
            return (tier, index, entry.projectId, entry.session.id)
        }.sorted { lhs, rhs in
            lhs.tier != rhs.tier ? lhs.tier < rhs.tier : lhs.workspaceIndex < rhs.workspaceIndex
        }
        guard !ordered.isEmpty else { return nil }

        let currentId = globalSelectedSessionId
        let target: (tier: SessionAttentionTier, workspaceIndex: Int, projectId: String, sessionId: String)
        if let currentIndex = ordered.firstIndex(where: { $0.sessionId == currentId }) {
            target = ordered[(currentIndex + 1) % ordered.count]
        } else if let cursor = lastClearedAttentionCursor, cursor.sessionId == currentId {
            target = ordered.first {
                ($0.tier, $0.workspaceIndex) > (cursor.tier, cursor.workspaceIndex)
            } ?? ordered[0]
        } else {
            target = ordered[0]
        }

        if target.tier == .unread {
            lastClearedAttentionCursor = (target.sessionId, target.tier, target.workspaceIndex)
        } else {
            lastClearedAttentionCursor = nil
        }
        show(projectId: target.projectId, sessionId: target.sessionId)
        save()
        focusActiveTerminal()
        return (target.projectId, target.sessionId)
    }

    // MARK: - status / notifications (driven by the CLI)

    func setStatus(
        sessionId: String,
        status: SessionStatus,
        text: String?,
        timestamp: Int64? = nil,
        source: String? = nil,
        copilotSessionId: String? = nil,
        notification: StatusNotificationKind? = nil
    ) {
        guard let loc = locateIndex(sessionId) else { return }
        // Runs after any status change below, including early exits that
        // leave the status as it was.
        defer { dismissAnsweredQuestionNotifications(sessionId: sessionId) }
        let previousTimestamp = sessionSemantics.statusClock.timestamp(for: sessionId)
        guard sessionSemantics.shouldApplyStatusEvent(
            sessionId: sessionId,
            timestamp: timestamp,
            source: source
        ) else { return }
        projectStorage[loc.p].sessions[loc.s].statusIsRuntimeDerived = false
        withCoalescedProjectPublications {
        if status == .waiting {
            if case .loaded(let record) = SessionArtifacts.loadStatusRecord(
                sessionId: sessionId, sessionsDirectory: agentActivityDirectory
            ), record.status == .waiting, record.statusTimestamp == timestamp,
               let context = record.inputWait {
                inputWaits[sessionId] = InputWaitState(
                    context: context, timestamp: record.statusTimestamp
                )
            } else if let copilotSessionId, let timestamp,
                      let snapshot = projects[loc.p].sessions[loc.s].agentActivity,
                      let root = snapshot.copilotSessionId,
                      let epoch = snapshot.conversationEpoch,
                      root.lowercased() == resumeMarkerValue(
                        sessionId: sessionId, suffix: "copilot-session"
                      )?.lowercased() {
                inputWaits[sessionId] = InputWaitState(
                    context: InputWaitContext(
                        senderSessionId: copilotSessionId,
                        rootSessionId: root,
                        conversationEpoch: epoch
                    ),
                    timestamp: timestamp
                )
            } else {
                inputWaits[sessionId] = nil
            }
        } else {
            inputWaits[sessionId] = nil
        }
        // sessionEnd is also emitted during graceful macOS shutdown. Only a live,
        // non-terminating app can treat it as an explicit user exit.
        if source == "session-end", !isTerminating, !isPoweringOff,
           shouldClearResumeMarkers(sessionId: sessionId, copilotSessionId: copilotSessionId) {
            try? FileManager.default.removeItem(
                at: resumeMarkerDirectory.appendingPathComponent("\(sessionId).copilot-session")
            )
        }
        let previous = projects[loc.p].sessions[loc.s].status
        if status == .waiting, previous == .waiting, notification == nil {
            refreshRetainedPermissionClocks(sessionId: sessionId, previousTimestamp: previousTimestamp)
        }
        var permissionRestoreState: (
            status: SessionStatus,
            statusText: String?,
            scheduledTurnActive: Bool,
            finishedUnseen: Bool,
            turnCompleted: Bool,
            backgroundAgentsSuppressed: Bool,
            completionPending: Bool,
            foregroundIdleGenerationBaseline: Int?
        )? = notification == .permission
            ? (
                previous,
                projects[loc.p].sessions[loc.s].statusText,
                projects[loc.p].sessions[loc.s].scheduledTurnActive,
                projects[loc.p].sessions[loc.s].finishedUnseen,
                projects[loc.p].sessions[loc.s].turnCompleted,
                backgroundAgentsSuppressed.contains(sessionId),
                completionPending.contains(sessionId),
                foregroundIdleGenerationBaselines[sessionId]
            )
            : nil
        if permissionRestoreState != nil,
           previous == .waiting,
           let retained = permissionStatusRestores[sessionId],
           retained.statusTimestamp == previousTimestamp,
           retained.status != .waiting {
            permissionRestoreState = (
                retained.status, retained.statusText, retained.scheduledTurnActive,
                retained.finishedUnseen, retained.turnCompleted,
                retained.backgroundAgentsSuppressed, retained.completionPending,
                retained.foregroundIdleGenerationBaseline
            )
        }
        let startsScheduledTurn = source == "scheduled-start" || source == "scheduled-active"
        let endsScheduledTurn = source == "scheduled-idle"
        let scheduledStateChanges = startsScheduledTurn
            ? !projects[loc.p].sessions[loc.s].scheduledTurnActive
            : endsScheduledTurn && projects[loc.p].sessions[loc.s].scheduledTurnActive
        if startsScheduledTurn {
            projects[loc.p].sessions[loc.s].scheduledTurnActive = true
            scheduledSnapshotsSuppressed.remove(sessionId)
            foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)
        } else if endsScheduledTurn {
            projects[loc.p].sessions[loc.s].scheduledTurnActive = false
            scheduledSnapshotsSuppressed.insert(sessionId)
        }
        if startsScheduledTurn || endsScheduledTurn {
            // A scan read that began before this hook would undo it.
            agentActivityObservations[sessionId, default: 0] += 1
        }
        let clearsBackgroundAgents = status == .idle && source == "session-idle"
        let hasCompletionSignal = SessionSemantics.isCompletionSignal(
            status: status,
            source: source,
            notificationIsCompleted: notification == .completed,
            scheduledTurnActive: projects[loc.p].sessions[loc.s].scheduledTurnActive
        )
        let clearsFinishedUnseen = (status == .running || status == .waiting)
            && projects[loc.p].sessions[loc.s].finishedUnseen
        let resumesBackgroundTracking = (status == .running || status == .waiting)
            && backgroundAgentsSuppressed.contains(sessionId)
        guard previous != status
                || projects[loc.p].sessions[loc.s].statusText != text
                || clearsBackgroundAgents
                || clearsFinishedUnseen
                || resumesBackgroundTracking
                || notification != nil
                || hasCompletionSignal
                || scheduledStateChanges
        else { return }
        if status != .waiting {
            cancelWaitingNotifications(sessionId: sessionId)
        } else if let notification, notification != .elicitation {
            elicitationNotificationTokens[sessionId] = nil
        }
        projects[loc.p].sessions[loc.s].status = status
        projects[loc.p].sessions[loc.s].statusText = text
        if status == .running || status == .waiting {
            if status == .running {
                projects[loc.p].sessions[loc.s].scheduledTurnActive = false
                agentActivityObservations[sessionId, default: 0] += 1
                foregroundIdleGenerationBaselines[sessionId] =
                    projects[loc.p].sessions[loc.s].agentActivity?.idleGeneration ?? -1
            }
            projects[loc.p].sessions[loc.s].finishedUnseen = false
            projects[loc.p].sessions[loc.s].turnCompleted = false
            backgroundAgentsSuppressed.remove(sessionId)
            if Self.shouldClearPendingCompletion(status: status, source: source) {
                completionPending.remove(sessionId)
            }
        }
        if hasCompletionSignal {
            if !completionPending.contains(sessionId) {
                completionSummaryContexts[sessionId] = CompletionSummaryContext(
                    copilotSessionId: copilotSessionId,
                    activeTimestamp: previousTimestamp,
                    completionTimestamp: timestamp
                )
            }
            completionPending.insert(sessionId)
        }
        if status == .idle && source == "session-idle" && notification != .completed {
            completionPending.remove(sessionId)
        }
        if timestamp == nil {
            let now = SessionArtifacts.currentStatusTimestamp()
            let clocks = sessionSemantics.recordLocalStatusEvent(
                sessionId: sessionId,
                nowMilliseconds: now,
                source: source
            )
            SessionArtifacts.persistStatus(
                sessionId: sessionId,
                status: status,
                timestamp: clocks.status,
                promptStatusTimestamp: clocks.promptSafety
            )
            if status == .waiting, previous == .waiting, notification == nil {
                refreshRetainedPermissionClocks(sessionId: sessionId, previousTimestamp: previousTimestamp)
            }
        }

        if status == .idle {
            sessionSemantics.activityTracker.reset(sessionId: sessionId)
            if source == "session-idle" {
                setBackgroundAgentsActive(sessionId: sessionId, active: false)
                backgroundAgentsSuppressed.insert(sessionId)
            }
        }
        // Completion signals mark ready through postCompletionIfReady, after background
        // work drains. Idle events without one (aborts, session end) need attention now.
        if status == .idle, previous == .running || previous == .waiting,
           !hasCompletionSignal, !startsScheduledTurn, !endsScheduledTurn,
           !isVisible(projectIndex: loc.p, sessionIndex: loc.s) {
            projects[loc.p].sessions[loc.s].finishedUnseen = true
        }
        if hasCompletionSignal {
            if source == "agent-stop" {
                let delay = completionNotificationDelayNanoseconds
                Task { @MainActor [weak self] in
                    // Allow one footer scan for the background-agent OSC title to arrive.
                    try? await Task.sleep(nanoseconds: delay)
                    self?.postCompletionIfReady(sessionId: sessionId)
                }
            } else {
                postCompletionIfReady(sessionId: sessionId)
            }
        } else if notification == .permission {
            if let permissionRestoreState {
                let now = SessionArtifacts.currentStatusTimestamp()
                let statusTimestamp = timestamp
                    ?? sessionSemantics.statusClock.timestamp(for: sessionId)
                    ?? now
                let promptTimestamp = sessionSemantics.promptSafetyClock.timestamp(
                    for: sessionId
                )
                    ?? statusTimestamp
                schedulePermissionNotification(
                    sessionId: sessionId,
                    restore: PermissionStatusRestore(
                        status: permissionRestoreState.status,
                        statusText: permissionRestoreState.statusText,
                        scheduledTurnActive: permissionRestoreState.scheduledTurnActive,
                        finishedUnseen: permissionRestoreState.finishedUnseen,
                        turnCompleted: permissionRestoreState.turnCompleted,
                        backgroundAgentsSuppressed:
                            permissionRestoreState.backgroundAgentsSuppressed,
                        completionPending: permissionRestoreState.completionPending,
                        foregroundIdleGenerationBaseline:
                            permissionRestoreState.foregroundIdleGenerationBaseline,
                        statusTimestamp: statusTimestamp,
                        promptStatusTimestamp: promptTimestamp
                    )
                )
            }
        } else if notification == .elicitation {
            scheduleElicitationNotification(sessionId: sessionId)
        }
        }
    }

    nonisolated static func permissionNotificationDecision(
        status: SessionStatus,
        hasPendingQuestions: Bool,
        pendingPermissionRequestIds: [String]?
    ) -> PermissionNotificationDecision {
        SessionSemanticsAdapter.permissionDecision(
            status: status,
            hasPendingQuestions: hasPendingQuestions,
            hasPendingPermissionRequests: pendingPermissionRequestIds.map { !$0.isEmpty }
        )
    }

    private func refreshRetainedPermissionClocks(sessionId: String, previousTimestamp: Int64?) {
        guard var restore = permissionStatusRestores[sessionId],
              restore.statusTimestamp == previousTimestamp,
              let statusTimestamp = sessionSemantics.statusClock.timestamp(for: sessionId),
              let promptTimestamp = sessionSemantics.promptSafetyClock.timestamp(for: sessionId) else {
            return
        }
        restore.statusTimestamp = statusTimestamp
        restore.promptStatusTimestamp = promptTimestamp
        permissionStatusRestores[sessionId] = restore
    }

    private func schedulePermissionNotification(
        sessionId: String,
        restore: PermissionStatusRestore
    ) {
        permissionStatusRestores[sessionId] = restore
        guard permissionNotificationTokens[sessionId] == nil else { return }
        let token = UUID()
        permissionNotificationTokens[sessionId] = token
        let delay = permissionNotificationDelayNanoseconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.resolvePermissionNotification(sessionId: sessionId, token: token)
        }
    }

    /// The session stopped waiting, so neither a permission nor a question
    /// alert scheduled for that wait may still post.
    func cancelWaitingNotifications(sessionId: String) {
        permissionNotificationTokens[sessionId] = nil
        permissionStatusRestores[sessionId] = nil
        elicitationNotificationTokens[sessionId] = nil
    }

    private func resolvePermissionNotification(sessionId: String, token: UUID) {
        guard permissionNotificationTokens[sessionId] == token else { return }
        permissionNotificationTokens[sessionId] = nil
        guard let restore = permissionStatusRestores[sessionId] else { return }
        guard let loc = locateIndex(sessionId) else { return }

        let fm = FileManager.default
        let decoder = JSONDecoder()
        let path = agentActivityDirectory
            .appendingPathComponent("\(sessionId).agent-activity.json").path
        let loaded = loadAgentActivitySnapshot(
            sessionId: sessionId,
            path: path,
            decoder: decoder,
            fm: fm
        )
        var snapshot = loaded?.isFresh() == true ? loaded : nil
        if let wait = inputWaits[sessionId],
           (snapshot?.copilotSessionId?.lowercased() != wait.context.rootSessionId.lowercased()
            || snapshot?.conversationEpoch != wait.context.conversationEpoch
            || (snapshot?.updatedAtMilliseconds ?? .min) < wait.timestamp) {
            snapshot = nil
        }
        let session = projects[loc.p].sessions[loc.s]
        let hasPendingQuestions = snapshot.map {
            $0.trackedUserInputs?.isEmpty == false
                || $0.trackedElicitations?.isEmpty == false
        } ?? session.hasPendingQuestions
        switch Self.permissionNotificationDecision(
            status: session.status,
            hasPendingQuestions: hasPendingQuestions,
            pendingPermissionRequestIds: snapshot?.pendingPermissionRequestIds
        ) {
        case .cancel:
            permissionStatusRestores[sessionId] = nil
            return
        case .post:
            if let snapshot,
               let root = snapshot.copilotSessionId,
               let epoch = snapshot.conversationEpoch,
               let pending = snapshot.pendingPermissionRequestIds, !pending.isEmpty {
                var retained = restore
                retained.observedRootSessionId = root
                retained.observedConversationEpoch = epoch
                retained.observedPendingRequestIds = Set(pending)
                permissionStatusRestores[sessionId] = retained
            }
            postNotification(
                projectId: projects[loc.p].id,
                sessionId: sessionId,
                kind: .permission,
                title: StatusNotificationKind.permission.title,
                body: nil
            )
        case .suppress:
            restoreStatusAfterTransientPermission(
                sessionId: sessionId,
                location: loc,
                restore: restore,
                now: Date()
            )
        }
    }

    /// Posts a question notification for one elicitation hook. The hook can
    /// beat the tracker's snapshot of the question, so a session whose tracker
    /// could accept a reply is re-read with backoff before posting without one.
    private func scheduleElicitationNotification(sessionId: String) {
        let token = UUID()
        elicitationNotificationTokens[sessionId] = token
        let delays = elicitationReplyRetryDelaysNanoseconds
        var conversation = inputWaits[sessionId].map {
            ElicitationConversation(
                rootSessionId: $0.context.rootSessionId,
                conversationEpoch: $0.context.conversationEpoch
            )
        }
        guard !resolveElicitationNotification(
            sessionId: sessionId,
            token: token,
            conversation: &conversation,
            isFinalAttempt: delays.isEmpty
        ) else { return }
        let observed = conversation
        Task { @MainActor [weak self] in
            var conversation = observed
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard let self else { return }
                if self.resolveElicitationNotification(
                    sessionId: sessionId,
                    token: token,
                    conversation: &conversation,
                    isFinalAttempt: index == delays.count - 1
                ) {
                    return
                }
            }
        }
    }

    /// Returns false only while a retry could still find a replyable question.
    private func resolveElicitationNotification(
        sessionId: String,
        token: UUID,
        conversation: inout ElicitationConversation?,
        isFinalAttempt: Bool,
        now: Date = Date()
    ) -> Bool {
        let clock = advancingClock(from: now)
        guard elicitationNotificationTokens[sessionId] == token else { return true }
        guard let loc = locateIndex(sessionId),
              projects[loc.p].sessions[loc.s].status == .waiting else {
            elicitationNotificationTokens[sessionId] = nil
            return true
        }
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        var question: NotificationReplyResolver.PendingQuestion?
        var questionObservedAt: Int64?
        var questionListWasFull = false
        if let snapshot = adapter.loadReceiptBoundSnapshot(sessionId: sessionId, now: clock),
           let root = snapshot.copilotSessionId,
           let epoch = snapshot.conversationEpoch {
            let observed = conversation ?? ElicitationConversation(
                rootSessionId: root,
                conversationEpoch: epoch
            )
            conversation = observed
            // A different conversation can't own this hook's question; post
            // without a reply rather than keep waiting for it.
            if observed.rootSessionId.lowercased() == root.lowercased(),
               observed.conversationEpoch == epoch {
                question = NotificationReplyResolver.pendingQuestion(in: snapshot, now: clock())
                questionObservedAt = snapshot.updatedAtMilliseconds
                questionListWasFull = AnsweredQuestionNotifications.mayOmitQuestions(snapshot)
                // Only an empty snapshot can still be missing this hook's
                // question; one that can't be answered here won't improve.
                if question == nil, !isFinalAttempt { return false }
            }
        }
        elicitationNotificationTokens[sessionId] = nil
        let id = postNotification(
            projectId: projects[loc.p].id,
            sessionId: sessionId,
            kind: .elicitation,
            title: StatusNotificationKind.elicitation.title,
            body: question?.notificationBody,
            reply: question?.reply
        )
        let requestId = question?.requestId
        let postedAt = Int64(now.timeIntervalSince1970 * 1_000)
        rememberQuestionNotification(
            PostedQuestionNotification(
                id: id,
                requestId: requestId,
                rootSessionId: conversation?.rootSessionId,
                conversationEpoch: conversation?.conversationEpoch,
                evidenceAfterMilliseconds: requestId == nil
                    ? postedAt
                    : questionObservedAt ?? postedAt,
                mayBeUnlisted: questionListWasFull,
                listedWithoutRequestId: question != nil && requestId == nil
            ),
            sessionId: sessionId
        )
        return true
    }

    private func rememberQuestionNotification(
        _ notification: PostedQuestionNotification,
        sessionId: String
    ) {
        // Never bounded: a forgotten alert could never be withdrawn.
        questionNotifications[sessionId, default: []].append(notification)
    }

    /// Withdraws a session's question alerts whose questions are provably
    /// resolved, wherever they were answered.
    func dismissAnsweredQuestionNotifications(sessionId: String, now: Date = Date()) {
        guard let posted = questionNotifications[sessionId] else { return }
        guard let loc = locateIndex(sessionId) else {
            dismissQuestionNotifications(sessionId: sessionId)
            return
        }
        let session = projects[loc.p].sessions[loc.s]
        let result = AnsweredQuestionNotifications.partition(
            posted,
            status: session.status,
            snapshot: session.agentActivity,
            ownerSessionId: resumeMarkerValue(sessionId: sessionId, suffix: "copilot-session"),
            now: now
        )
        questionNotifications[sessionId] = result.pending.isEmpty ? nil : result.pending
        for id in result.answered {
            notifications?.dismiss(id: id)
        }
    }

    func dismissAnsweredQuestionNotifications(now: Date) {
        for sessionId in Array(questionNotifications.keys) {
            dismissAnsweredQuestionNotifications(sessionId: sessionId, now: now)
        }
    }

    /// The session is gone, so none of its questions can still be answered.
    private func dismissQuestionNotifications(sessionId: String) {
        guard let posted = questionNotifications.removeValue(forKey: sessionId) else { return }
        for notification in posted {
            notifications?.dismiss(id: notification.id)
        }
    }

    func restoreCompletedPermissionWaits(now: Date) {
        for (sessionId, restore) in permissionStatusRestores {
            guard let loc = locateIndex(sessionId),
                  projects[loc.p].sessions[loc.s].status == .waiting,
                  sessionSemantics.statusClock.timestamp(for: sessionId) == restore.statusTimestamp else {
                continue
            }
            if inputWaits[sessionId] == nil {
                guard permissionNotificationTokens[sessionId] == nil,
                      restore.status != .waiting,
                      !restore.observedPendingRequestIds.isEmpty,
                      let snapshot = projects[loc.p].sessions[loc.s].agentActivity,
                      snapshot.isFresh(at: now),
                      snapshot.copilotSessionId?.lowercased() == restore.observedRootSessionId?.lowercased(),
                      snapshot.conversationEpoch == restore.observedConversationEpoch,
                      snapshot.copilotSessionId?.lowercased() == resumeMarkerValue(
                        sessionId: sessionId, suffix: "copilot-session"
                      )?.lowercased(),
                      (snapshot.updatedAtMilliseconds ?? .min) > restore.statusTimestamp,
                      snapshot.pendingPermissionRequestIds?.isEmpty == true,
                      snapshot.trackedUserInputs?.isEmpty == true,
                      snapshot.trackedElicitations?.isEmpty == true else {
                    continue
                }
            }
            restoreStatusAfterTransientPermission(
                sessionId: sessionId, location: loc, restore: restore, now: now
            )
        }
    }

    private func restoreStatusAfterTransientPermission(
        sessionId: String,
        location: (p: Int, s: Int),
        restore: PermissionStatusRestore,
        now: Date
    ) {
        guard sessionSemantics.statusClock.timestamp(for: sessionId) == restore.statusTimestamp else {
            return
        }
        var session = projects[location.p].sessions[location.s]
        let foreground = runtimeForegroundActivity(for: session, now: now)
        if inputWaits[sessionId] != nil {
            guard inputWaitWasResolved(
                for: session,
                foreground: foreground,
                now: now
            ) else { return }
        }
        let restoredStatus = restore.status == .waiting
            ? projectedStatus(for: session, foreground: foreground, now: now)
            : restore.status
        guard restoredStatus != .waiting else { return }
        session.status = restoredStatus
        session.statusIsRuntimeDerived = restore.status == .waiting
        session.statusText = restore.statusText
        session.scheduledTurnActive = restore.scheduledTurnActive
        session.finishedUnseen = restore.finishedUnseen
        session.turnCompleted = restore.turnCompleted
        projects[location.p].sessions[location.s] = session

        if restore.backgroundAgentsSuppressed {
            backgroundAgentsSuppressed.insert(sessionId)
        } else {
            backgroundAgentsSuppressed.remove(sessionId)
        }
        if restore.completionPending {
            completionPending.insert(sessionId)
        } else {
            completionPending.remove(sessionId)
        }
        if let baseline = restore.foregroundIdleGenerationBaseline {
            foregroundIdleGenerationBaselines[sessionId] = baseline
        } else {
            foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)
        }

        sessionSemantics.statusClock.seed(
            sessionId: sessionId,
            timestamp: restore.statusTimestamp
        )
        sessionSemantics.promptSafetyClock.seed(
            sessionId: sessionId,
            timestamp: restore.promptStatusTimestamp
        )
        persistPermissionStatus(
            sessionId,
            restoredStatus,
            restore.statusTimestamp,
            restore.promptStatusTimestamp
        )
        cancelWaitingNotifications(sessionId: sessionId)
        dismissAnsweredQuestionNotifications(sessionId: sessionId, now: now)
        updateDockBadge()
        if restore.completionPending {
            postCompletionIfReady(sessionId: sessionId)
        }
    }

    /// Scheduled pre/post hooks reaffirm background activity but do not describe
    /// foreground ownership. Keep them out of the prompt-safety clock so they cannot
    /// invalidate an already-settled foreground snapshot.
    nonisolated static func advancesPromptSafetyClock(source: String?) -> Bool {
        SessionSemantics.advancesPromptSafetyClock(source: source)
    }

    private func shouldClearResumeMarkers(
        sessionId: String,
        copilotSessionId: String?
    ) -> Bool {
        guard let copilotSessionId, !copilotSessionId.isEmpty else { return false }
        return resumeMarkerValue(sessionId: sessionId, suffix: "copilot-session") == copilotSessionId
    }

    func resumeMarkerValue(sessionId: String, suffix: String) -> String? {
        (try? String(
            contentsOf: resumeMarkerDirectory.appendingPathComponent("\(sessionId).\(suffix)"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a session is the one on screen right now (app active + its project and
    /// tab selected). Used to decide if a just-finished session needs an attention dot.
    func isVisible(projectIndex pi: Int, sessionIndex si: Int) -> Bool {
        Self.isSessionVisible(
            appIsActive: isAppActive(),
            selectedProjectId: selectedProjectId,
            projectId: projects[pi].id,
            selectedSessionId: projects[pi].selectedSessionId,
            sessionId: projects[pi].sessions[si].id
        )
    }

    func focus(projectId: String?, sessionId: String?) {
        show(projectId: projectId, sessionId: sessionId)
        requestMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
        // An already-visible session may not trigger activation or reveal callbacks.
        focusActiveTerminal()
    }

    /// Selects a session, or a project's shown session, and marks it read.
    func show(projectId: String?, sessionId: String?) {
        var clearedMark = false
        if let sessionId, let loc = locateIndex(sessionId) {
            selectedProjectId = projects[loc.p].id
            projects[loc.p].selectedSessionId = sessionId
            projects[loc.p].sessions[loc.s].hasUnread = false
            projects[loc.p].sessions[loc.s].finishedUnseen = false
            clearedMark = projects[loc.p].sessions[loc.s].markedUnread
            projects[loc.p].sessions[loc.s].markedUnread = false
        } else if let projectId, let pi = projectIndex(projectId) {
            selectedProjectId = projectId
            for i in projects[pi].sessions.indices {
                projects[pi].sessions[i].hasUnread = false
            }
            if let sid = projects[pi].selectedSessionId,
               let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) {
                projects[pi].sessions[si].finishedUnseen = false
                clearedMark = projects[pi].sessions[si].markedUnread
                projects[pi].sessions[si].markedUnread = false
            }
        }
        if let sid = currentSelectedSessionId { controller(for: sid) }
        refreshSelectedTranscriptController()
        updateDockBadge()
        if clearedMark { save() }
    }

    /// Mark a session read on behalf of a remote client that is now viewing it (iOS
    /// session screen on-screen), or from the Mac's "Mark as Read". Clears the same
    /// flags local focus does — `hasUnread` and a manual `markedUnread` (mirrored to
    /// remotes as `unread`) and the Mac-local `finishedUnseen` dot — so a read on the
    /// phone clears the indicator everywhere via the workspace-snapshot diff.
    /// Unlike `focus`, it does NOT change the Mac's selection or activate the app: a
    /// phone read must not yank the desktop UI. Only `markedUnread` is persisted, so
    /// that's the only change that needs a `save()`.
    func markSessionRead(sessionId: String) {
        clearUnread(sessionId: sessionId, includingManualMark: true)
    }

    /// "Mark as Unread": flag a session so you remember to come back to it after
    /// working elsewhere. It stays marked until you navigate to it or mark it read.
    func markSessionUnread(sessionId: String) {
        guard let loc = locateIndex(sessionId),
              !projects[loc.p].sessions[loc.s].markedUnread else { return }
        projects[loc.p].sessions[loc.s].markedUnread = true
        updateDockBadge()
        save()
    }

    /// Whether the Session menu offers Mark as Read, rather than Mark as Unread,
    /// for the current session.
    var selectedSessionOffersMarkAsRead: Bool {
        guard let sid = currentSelectedSessionId, let loc = locateIndex(sid) else { return false }
        return projects[loc.p].sessions[loc.s].offersMarkAsRead
    }

    /// Session ▸ Mark as Unread / Mark as Read (⇧⌘U), matching the context menu.
    func toggleSelectedSessionRead() {
        guard let sid = currentSelectedSessionId else { return }
        if selectedSessionOffersMarkAsRead {
            markSessionRead(sessionId: sid)
        } else {
            markSessionUnread(sessionId: sid)
        }
    }

    /// Closing or moving the visible tab, or ending the selected project, puts a
    /// fallback session on screen. That brings you back to it just like selecting
    /// it, so its manual mark clears. Callers update the Dock badge and save.
    private func clearManualMarkIfShown(replacing previous: String?) {
        guard let sid = globalSelectedSessionId, sid != previous,
              let loc = locateIndex(sid) else { return }
        projects[loc.p].sessions[loc.s].markedUnread = false
    }

    /// Clear the visible session's attention flags when the app is brought forward.
    /// Other tabs stay unread until you view them. A manual mark survives: you set
    /// it while looking at the session, so coming back to the app isn't a return to it.
    func markActiveSessionSeen() {
        guard let sid = currentSelectedSessionId else { return }
        clearUnread(sessionId: sid, includingManualMark: false)
    }

    private func clearUnread(sessionId: String, includingManualMark: Bool) {
        guard let loc = locateIndex(sessionId) else { return }
        let session = projects[loc.p].sessions[loc.s]
        let clearsMark = includingManualMark && session.markedUnread
        guard session.hasUnread || session.finishedUnseen || clearsMark else { return }
        projects[loc.p].sessions[loc.s].hasUnread = false
        projects[loc.p].sessions[loc.s].finishedUnseen = false
        if clearsMark { projects[loc.p].sessions[loc.s].markedUnread = false }
        updateDockBadge()
        if clearsMark { save() }
    }

    /// Make the visible session's terminal the first responder on activation or
    /// an explicit focus request. Hidden/unattached targets are focused on reveal.
    func focusActiveTerminal() {
        guard let view = activeController?.terminalView, !view.isHidden,
              let window = view.window, window.firstResponder !== view else { return }
        window.makeFirstResponder(view)
    }

    func updateDockBadge() {
        let count = projects.reduce(0) { acc, p in
            acc + p.sessions.filter { $0.isUnread }.count
        }
        NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - terminal callbacks

    func updateTitle(sessionId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let loc = locateIndex(sessionId) else { return }
        // copilot sets its terminal title to "Copilot: Waiting for background agents"
        // while its background agents run. That's a transient state, not a name, so
        // flag it for the tab/sidebar indicator and keep the tab's real title rather
        // than letting it clobber it.
        let backgroundAgents = trimmed.range(of: "waiting for background agent", options: .caseInsensitive) != nil
        if backgroundAgents, backgroundAgentsSuppressed.contains(sessionId) {
            return
        }
        setBackgroundAgentsActive(sessionId: sessionId, active: backgroundAgents)
        guard !backgroundAgents else { return }
        if projects[loc.p].sessions[loc.s].title != trimmed {
            projects[loc.p].sessions[loc.s].title = trimmed
            scheduleSave()
        }
    }

    func updateCwd(sessionId: String, dir: String?) {
        guard let dir, !dir.isEmpty, let loc = locateIndex(sessionId) else { return }
        // Shells report OSC 7 as a `file://host/path` URL; store the plain path so
        // a session that later inherits this cwd can actually chdir into it.
        let normalized = Paths.normalizedDirectory(dir)
        if projects[loc.p].sessions[loc.s].cwd != normalized {
            projects[loc.p].sessions[loc.s].cwd = normalized
            scheduleSave()
        }
    }

    private func handleExit(sessionId: String) {
        controllers[sessionId] = nil
        guard !Self.shouldPreserveSessionAfterTerminalExit(
            isTerminating: isTerminating,
            isPoweringOff: isPoweringOff
        ) else { return }

        let socket = Paths.dtachSocketPath(sessionId: sessionId)
        // If a live dtach master still owns the socket, the shell is alive and
        // this was just a detached client — keep the session.
        if Paths.dtachExecutable != nil, FileManager.default.fileExists(atPath: socket),
           ProcessTree.dtachMaster(forSocket: socket, in: ProcessTree.snapshot()) != nil {
            return
        }

        guard let loc = locateIndex(sessionId),
              acceptSessionCloses(sessionIds: [sessionId]) else { return }
        projects[loc.p].sessions[loc.s].backgroundAgentsActive = false
        backgroundAgentsSuppressed.remove(sessionId)
        let projectId = projects[loc.p].id
        _ = kittyImageDiskStore.tombstone(sessionId: sessionId)
        SessionArtifacts.removeFiles(sessionId: sessionId)
        closeSession(projectId: projectId, sessionId: sessionId)
        finishPersistedSessionCloses()
    }

    nonisolated static func shouldPreserveSessionAfterTerminalExit(
        isTerminating: Bool,
        isPoweringOff: Bool
    ) -> Bool {
        isTerminating || isPoweringOff
    }

    // MARK: - control socket handler

    func handle(_ req: ControlRequest) -> ControlResponse {
        controlRouter.handle(req)
    }

    private func renderDiagnostics() -> String {
        let renderers = Dictionary(grouping: controllers.values) {
            $0.terminalView.rendererName
        }.mapValues(\.count)
        let rendererText = renderers.keys.sorted().map { "\($0)=\(renderers[$0] ?? 0)" }
            .joined(separator: ", ")
        return [
            "app control socket: reachable",
            "live terminal controllers: \(controllers.count)",
            "renderers: \(rendererText.isEmpty ? "none" : rendererText)",
            "selected session: \(globalSelectedSessionId ?? "none")",
        ].joined(separator: "\n")
    }

    private func resolve(_ req: ControlRequest) -> (projectId: String, sessionId: String)? {
        if let sid = req.sessionId, let loc = locateIndex(sid) {
            return (projects[loc.p].id, sid)
        }
        if let pid = req.projectId, let pi = projectIndex(pid) {
            if let sid = projects[pi].selectedSessionId ?? projects[pi].sessions.first?.id {
                return (pid, sid)
            }
        }
        return nil
    }

    /// The project a project-scoped command (new-session / rename-project) acts on.
    /// An explicit `--project` wins; otherwise derive it from the session id, which —
    /// unlike the COPILOT_PROJECTS_PROJECT env — stays correct after a tab is dragged
    /// to another project; finally fall back to the on-screen project.
    private func resolveProject(_ req: ControlRequest) -> String? {
        if let pid = req.projectId { return pid }
        if let sid = req.sessionId, let loc = locateIndex(sid) { return projects[loc.p].id }
        return selectedProjectId
    }

    private func renderProjects() -> String {
        if projects.isEmpty { return "(no projects)" }
        return projects.map { p in
            let marker = p.id == selectedProjectId ? "*" : " "
            let counts = "\(p.sessions.count) session\(p.sessions.count == 1 ? "" : "s")"
            return "\(marker) [\(p.aggregateStatus.rawValue)] \(p.name)  (\(counts))  \(p.id)"
        }.joined(separator: "\n")
    }

    private func renderHosts() -> String {
        let hosts = availableHosts
        if hosts.isEmpty { return "(no hosts)" }
        return hosts.map { host in
            let target = host.sshTarget.map { " (\($0))" } ?? ""
            let kind = host.isLocal ? "local" : "ssh"
            return "\(host.id)  [\(kind)]  \(host.displayName)\(target)"
        }.joined(separator: "\n")
    }

    private func renderStatus() -> String {
        var lines: [String] = []
        for p in projects {
            for s in p.sessions {
                let extra = s.statusText.map { " — \($0)" } ?? ""
                let unread = s.isUnread ? " [unread]" : ""
                lines.append("\(p.name)/\(s.title)  \(s.displayStatus.rawValue)\(unread)\(extra)  \(s.id)")
            }
        }
        return lines.isEmpty ? "(no sessions)" : lines.joined(separator: "\n")
    }

    // MARK: - indexing

    func projectIndex(_ id: String) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    func locateIndex(_ sessionId: String) -> (p: Int, s: Int)? {
        for (pi, p) in projects.enumerated() {
            if let si = p.sessions.firstIndex(where: { $0.id == sessionId }) {
                return (pi, si)
            }
        }
        return nil
    }

    // MARK: - persistence

    private func load() {
        let state: PersistedState
        switch stateRepository.load() {
        case .missing:
            return
        case .loaded(let loaded):
            state = loaded
            didLoadWorkspaceState = true
        case .recovered(let recovered, let message):
            state = recovered
            stateRecoveryMessage = message
            NSLog("copilot-projects: \(message)")
        case .failed(let message):
            didFailToLoadWorkspaceState = true
            stateLoadFailure = message
            NSLog("copilot-projects: \(message)")
            return
        }
        projects = state.projects
        selectedProjectId = state.selectedProjectId ?? state.projects.first?.id
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let sid = projects[pi].sessions[si].id
                let restored = restoredStatusState(forSession: sid)
                let status = restored.status
                let statusTimestamp = restored.statusTimestamp
                projects[pi].sessions[si].status = status
                if let context = restored.inputWait, let timestamp = statusTimestamp,
                   status == .waiting {
                    inputWaits[sid] = InputWaitState(context: context, timestamp: timestamp)
                }
                sessionSemantics.statusClock.seed(
                    sessionId: sid,
                    timestamp: statusTimestamp
                )
                sessionSemantics.promptSafetyClock.seed(
                    sessionId: sid,
                    timestamp: restored.promptStatusTimestamp ?? statusTimestamp
                )
                projects[pi].sessions[si].statusText = nil
                projects[pi].sessions[si].hasUnread = false
                let hasBackgroundAgents = FileManager.default.fileExists(
                    atPath: Paths.backgroundAgentsMarkerPath(sessionId: sid)
                )
                projects[pi].sessions[si].backgroundAgentsActive = hasBackgroundAgents
                if !hasBackgroundAgents, projects[pi].sessions[si].status == .idle,
                   FileManager.default.fileExists(
                    atPath: Paths.sessionIdleHookMarkerPath(sessionId: sid)
                ) {
                    backgroundAgentsSuppressed.insert(sid)
                }
            }
        }
        syncSessionNavigationHistory()
    }

    private func restoredStatusState(
        forSession sessionId: String
    ) -> (
        status: SessionStatus, statusTimestamp: Int64?,
        promptStatusTimestamp: Int64?, inputWait: InputWaitContext?
    ) {
        switch SessionArtifacts.loadStatusRecord(
            sessionId: sessionId, sessionsDirectory: agentActivityDirectory
        ) {
        case .loaded(let record):
            return (
                record.status, record.statusTimestamp,
                record.promptStatusTimestamp, record.inputWait
            )
        case .invalid:
            // Restore busy and put the prompt clock at app startup time, so only fresh
            // post-recovery background evidence can bypass an unreadable record.
            NSLog("copilot-projects: invalid status record for \(sessionId); restoring busy")
            return (.running, nil, SessionArtifacts.currentStatusTimestamp(), nil)
        case .missing:
            return (.idle, nil, nil, nil)
        }
    }

    func scheduleSave() {
        guard stateLoadFailure == nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.performScheduledSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func performScheduledSave() {
        saveWork = nil
        guard stateLoadFailure == nil else { return }
        let state = PersistedState(projects: projects, selectedProjectId: selectedProjectId)
        guard scheduledSaveBuffer.enqueue(state) else { return }
        let buffer = scheduledSaveBuffer
        let repository = stateRepository
        stateSaveQueue.async {
            while let next = buffer.takeNext() {
                do {
                    try repository.save(next)
                } catch {
                    NSLog("copilot-projects: failed to save workspace state: \(error)")
                }
            }
        }
    }

    func enqueueScheduledSaveForTesting() {
        guard let work = saveWork else { return }
        work.cancel()
        performScheduledSave()
    }

    func flushScheduledSaveForTesting() {
        enqueueScheduledSaveForTesting()
        stateSaveQueue.sync {}
    }

    func persistWorkspace() throws {
        if let stateLoadFailure {
            throw WorkspacePersistenceError(errorDescription: stateLoadFailure)
        }
        let state = PersistedState(projects: projects, selectedProjectId: selectedProjectId)
        scheduledSaveBuffer.clearPending()
        try stateSaveQueue.sync {
            try stateRepository.save(state)
        }
        saveWork?.cancel()
        saveWork = nil
    }

    func save() {
        do {
            try persistWorkspace()
        } catch {
            NSLog("copilot-projects: failed to save workspace state: \(error)")
        }
    }
}
