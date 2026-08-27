import SwiftUI
import AppKit
import ScreenCaptureKit
import CopilotProjectsCore
import CopilotProjectsProtocol
import Darwin

private final class ScreenshotCaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<CGImage, Error>?

    func store(_ result: Result<CGImage, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func load() -> Result<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
    }
}

private struct ScreenshotCaptureRequest: Sendable {
    let windowID: CGWindowID
    let width: Int
    let height: Int
    let path: String
}

private enum ScreenshotPreparation {
    case ready(ScreenshotCaptureRequest)
    case failure(String)
}

enum RemotePromptResult: Equatable {
    case sent
    case forbidden
    case invalid
    case busy
    case noLiveCopilot
}

enum RemoteCommandResult: Equatable {
    case sent
    case busy
    case invalid
}

struct RemoteCommandRequestLedger {
    private var accepted: Set<String> = []
    private var order: [String] = []

    mutating func contains(_ requestId: String) -> Bool {
        accepted.contains(requestId)
    }

    mutating func record(_ requestId: String, cap: Int = 512) {
        guard accepted.insert(requestId).inserted else { return }
        order.append(requestId)
        while order.count > cap {
            accepted.remove(order.removeFirst())
        }
    }
}

/// Outcome of accepting a remote answer to a structured `ask_user` question.
enum RemoteUserInputResult: Equatable {
    /// The answer passed validation and a response file was written for the extension.
    case accepted
    /// A response for this tab is already awaiting the extension, or the question
    /// context changed underneath the answer.
    case conflict
    /// No matching live question, or the answer failed the choice/freeform/size rules.
    case invalid
}

/// On-disk shape of the host-written user-input response file. The extension
/// validates every field again before replying over RPC.
private struct UserInputResponseFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let requestId: String
    let answer: String
    let wasFreeform: Bool
}

/// On-disk shape of the host-written elicitation response file. The extension
/// re-validates against the live pending elicitation before replying over RPC.
private struct ElicitationResponseFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let requestId: String
    let action: String
    let content: [String: RemoteJSONValue]?
}

/// On-disk shape of the host-written set-model request file. The extension
/// re-validates the target against its live catalog before switching over RPC.
private struct SetModelRequestFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let modelId: String
    let reasoningEffort: String?
    let contextTier: String?
}

struct RemotePromptTarget {
    let activity: FooterActivity
    let send: (String) -> Bool
}

struct RemoteElicitationTerminalTarget {
    let isAtLiveBottom: Bool
    let screen: RemoteTerminalScreen?
    let sendEnter: () -> Bool
}

/// Outcome of a remote `POST /sessions/create`. Each case maps to a distinct HTTP
/// status at the gateway so the client can react precisely (select, retry, or show
/// an unsupported/unavailable message).
enum RemoteSessionCreationOutcome: Equatable {
    /// A brand-new session was created and its controller launched. (201)
    case created(RemoteCreateSessionResponse)
    /// The deterministic session already exists in the requested project — the
    /// idempotent replay of an earlier successful create. Nothing was created. (200)
    case existing(RemoteCreateSessionResponse)
    /// The requested project id is not known to the host. (422)
    case unknownProject
    /// The request is well-formed but cannot be honored — the required `$HOME/Repos`
    /// working directory is missing. Nothing was created. (422)
    case invalid
    /// The request does not match the endpoint or contains an invalid PR URL. (400)
    case badRequest
    /// The deterministic session id already exists in a DIFFERENT project. (409)
    case conflict
    /// The ledger shows this request was already processed but the session is gone;
    /// it is deliberately not recreated. (410)
    case gone
    /// The Copilot executable could not be resolved, so no session was created. (503)
    case unavailable
}

private enum WindowScreenshot {
    static func capture(_ request: ScreenshotCaptureRequest) -> ControlResponse {
        let result = ScreenshotCaptureBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            defer { semaphore.signal() }
            do {
                let content = try await SCShareableContent.currentProcess
                guard let shareableWindow = content.windows.first(where: {
                    $0.windowID == request.windowID
                }) else {
                    throw NSError(
                        domain: "CopilotProjectsScreenshot",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "window is not shareable"]
                    )
                }
                let filter = SCContentFilter(desktopIndependentWindow: shareableWindow)
                let configuration = SCStreamConfiguration()
                configuration.width = request.width
                configuration.height = request.height
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                result.store(.success(image))
            } catch {
                result.store(.failure(error))
            }
        }
        guard semaphore.wait(timeout: .now() + 5) == .success,
              let captureResult = result.load() else {
            return .failure("window capture timed out")
        }
        let image: CGImage
        switch captureResult {
        case .success(let captured): image = captured
        case .failure(let error):
            return .failure("could not capture window: \(error.localizedDescription)")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return .failure("could not encode PNG")
        }

        let destination = URL(fileURLWithPath: request.path)
        var st = stat()
        if lstat(request.path, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            return .failure("refusing to write screenshot to a non-regular file")
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
            return .success(request.path)
        } catch {
            return .failure("write failed: \(error.localizedDescription)")
        }
    }
}

enum RemoteSessionMoveResult: Equatable {
    case moved
    case unchanged
    case missing
}

enum PermissionNotificationDecision: Equatable {
    case cancel
    case post
    case suppress
}

/// Single source of truth. Holds value-type projects/sessions (observed) and live
/// terminal controllers (NOT observed, kept out of the SwiftUI graph).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var selectedProjectId: String?
    @Published var numberHint: NumberHint = .none
    @Published private(set) var transcriptOpenSessions: Set<String> = []

    private var controllers: [String: TerminalController] = [:]
    private var selectedTranscriptController: TranscriptController?
    private let stateRepository: StateRepository
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
            let project = self.makeProject(name: name, cwd: cwd, withSession: true)
            self.projects.append(project)
            self.selectProject(project.id)
            return .success(project.id)
        },
        newSession: { [unowned self] request in
            guard let pid = self.resolveProject(request) else { return .failure("no project") }
            guard let sid = self.addSession(toProjectId: pid, cwd: request.cwd) else {
                return .failure("unknown project: \(pid)")
            }
            return .success(sid)
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
        screenshot: { _ in
            .failure("screenshot must be handled by the control server")
        },
        diagnostics: { [unowned self] in self.renderDiagnostics() },
        remote: { [unowned self] action in
            self.remoteAccess.command(action, model: self)
        }
    ))
    private var stateLoadFailure: String?
    private var stateRecoveryMessage: String?
    private var didPresentStateMessage = false
    private var server: ControlServer?
    private let remoteAccess: RemoteAccessController
    private weak var notifications: (any NotificationPosting)?
    private var saveWork: DispatchWorkItem?
    private(set) var isTerminating = false

    private var livenessTimer: Timer?
    private var footerTimer: Timer?
    private var agentActivityTimer: Timer?
    private var agentActivitySource: DispatchSourceFileSystemObject?
    // Throttle state for the sessions-directory watcher: the directory holds a
    // file per session (activity/status/marker/transcript) and receives frequent
    // writes across all sessions, so an unthrottled watcher re-scans every session
    // on the main thread many times a second and starves keystroke handling.
    private var agentActivityRefreshCoolingDown = false
    private var agentActivityRefreshPending = false
    // Bumped whenever tracking (re)starts or terminates so an already-scheduled
    // cooldown from a prior chain — which `asyncAfter` cannot cancel — no-ops
    // instead of corrupting the current chain's throttle state.
    private var agentActivityRefreshGeneration = 0
    private let agentActivityRefreshThrottle: TimeInterval
    private let agentActivityCooldownScheduler:
        (_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> Void
    private let agentActivityScanObserver: (() -> Void)?
    // Per-session decoded-snapshot cache keyed by a file signature (inode+size+
    // mtime). Every live session heartbeats a write to its
    // `<id>.agent-activity.json` roughly every 5s, and both the directory watcher
    // and the 10s backstop re-scan *all* sessions — so re-reading and JSON-decoding
    // every file on each scan dominated the main thread (blocking `open()` is
    // especially costly when a security agent intercepts file events). Skip the
    // read+decode when a file's signature is unchanged; the caller still re-applies
    // the freshness TTL to the cached snapshot each scan, so a skipped read never
    // stalls a stale→nil transition.
    private var agentActivitySnapshotCache:
        [String: (signature: FileSignature, snapshot: AgentActivitySnapshot?)] = [:]

    private var activityTracker = ActivityTracker()
    private var statusEventClock = StatusEventClock()
    private var promptStatusEventClock = StatusEventClock()
    private var backgroundAgentsSuppressed: Set<String> = []
    private var completionPending: Set<String> = []
    private var scheduledSnapshotsSuppressed: Set<String> = []
    private var foregroundIdleGenerationBaselines: [String: Int] = [:]
    private let completionNotificationDelayNanoseconds: UInt64
    private let permissionNotificationDelayNanoseconds: UInt64
    private let persistPermissionStatus:
        (_ sessionId: String, _ status: SessionStatus, _ timestamp: Int64,
         _ promptStatusTimestamp: Int64) -> Void
    private struct PermissionStatusRestore {
        let status: SessionStatus
        let statusText: String?
        let scheduledTurnActive: Bool
        let finishedUnseen: Bool
        let turnCompleted: Bool
        let backgroundAgentsSuppressed: Bool
        let completionPending: Bool
        let foregroundIdleGenerationBaseline: Int?
        let statusTimestamp: Int64
        let promptStatusTimestamp: Int64
    }
    private var permissionNotificationTokens: [String: UUID] = [:]
    private var permissionStatusRestores: [String: PermissionStatusRestore] = [:]
    private let isAppActive: @MainActor () -> Bool
    private let agentActivityDirectory: URL
    private let resumeMarkerDirectory: URL
    private var powerOffProtectionGeneration = 0
    private(set) var isPoweringOff = false
    private let remotePromptLiveSessions: ((Set<String>) -> Set<String>)?
    private let remotePromptTarget: ((String) -> RemotePromptTarget?)?
    private let remoteElicitationTarget:
        ((String) -> RemoteElicitationTerminalTarget?)?
    private var remoteCommandRequestLedger = RemoteCommandRequestLedger()
    private var remoteElicitationRequestLedger = RemoteCommandRequestLedger()

    /// Resolves the absolute Copilot executable for a remotely-created session, and
    /// the absolute `$HOME/Repos` working directory. Injected so tests can drive the
    /// unavailable/invalid outcomes without touching the real filesystem.
    private let remoteCopilotExecutable: () -> String?
    private let remoteReposDirectory: () -> String?
    private let remoteSessionBackendAvailable: () -> Bool
    /// Overrides the controller launch for a freshly-created remote session (tests
    /// record it instead of spawning a real terminal). Nil in production, where the
    /// real cached terminal controller is created with a one-shot Copilot launch.
    private let remoteSessionLauncher:
        ((_ sessionId: String, _ copilotExecutable: String, _ initialPrompt: String?) -> Void)?
    /// Persistent idempotency/tombstone store behind remote session creation.
    private let sessionCreationLedger: SessionCreationLedger

    /// Sessions hosting a live agent (refreshed by the liveness reconciler). Used
    /// by scroll-wheel forwarding to keep working on resumed (desynced) sessions.
    private(set) var liveAgentSessions: Set<String> = []

    /// Process names treated as a live coding agent for the liveness backstop.
    /// Override with COPILOT_PROJECTS_AGENT_PROCESSES (comma-separated); disable the
    /// whole check with COPILOT_PROJECTS_LIVENESS=0.
    private var agentProcessNames: Set<String> {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["COPILOT_PROJECTS_AGENT_PROCESSES"],
           !raw.isEmpty {
            let names = raw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !names.isEmpty { return Set(names) }
        }
        return ["copilot"]
    }

    private var livenessEnabled: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["COPILOT_PROJECTS_LIVENESS"] != "0"
    }

    init(
        stateRepository: StateRepository = StateRepository(),
        completionNotificationDelayNanoseconds: UInt64 = 1_000_000_000,
        permissionNotificationDelayNanoseconds: UInt64 = 1_000_000_000,
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
        isAppActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        agentActivityDirectory: URL = Paths.sessionsDir,
        resumeMarkerDirectory: URL = Paths.sessionsDir,
        remotePromptLiveSessions: ((Set<String>) -> Set<String>)? = nil,
        remotePromptTarget: ((String) -> RemotePromptTarget?)? = nil,
        remoteElicitationTarget:
            ((String) -> RemoteElicitationTerminalTarget?)? = nil,
        remoteCopilotExecutable: @escaping () -> String? = { Paths.copilotExecutable },
        remoteReposDirectory: @escaping () -> String? = { Paths.reposDirectory },
        remoteSessionBackendAvailable: @escaping () -> Bool = {
            Paths.dtachExecutable != nil
        },
        remoteSessionLauncher: ((String, String, String?) -> Void)? = nil,
        sessionCreationLedger: SessionCreationLedger = SessionCreationLedger(),
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
        webPushService: WebPushService? = nil,
        apnsService: APNsService? = nil,
        notificationSync: NotificationSyncService? = nil,
        kittyImageDiskStore: RemoteKittyImageDiskStore = .shared
    ) {
        self.stateRepository = stateRepository
        self.completionNotificationDelayNanoseconds = completionNotificationDelayNanoseconds
        self.permissionNotificationDelayNanoseconds = permissionNotificationDelayNanoseconds
        self.persistPermissionStatus = persistPermissionStatus
        self.isAppActive = isAppActive
        self.agentActivityDirectory = agentActivityDirectory
        self.resumeMarkerDirectory = resumeMarkerDirectory
        self.remotePromptLiveSessions = remotePromptLiveSessions
        self.remotePromptTarget = remotePromptTarget
        self.remoteElicitationTarget = remoteElicitationTarget
        self.remoteCopilotExecutable = remoteCopilotExecutable
        self.remoteReposDirectory = remoteReposDirectory
        self.remoteSessionBackendAvailable = remoteSessionBackendAvailable
        self.remoteSessionLauncher = remoteSessionLauncher
        self.sessionCreationLedger = sessionCreationLedger
        self.agentActivityRefreshThrottle = agentActivityRefreshThrottle
        self.agentActivityCooldownScheduler = agentActivityCooldownScheduler
        self.agentActivityScanObserver = agentActivityScanObserver
        self.kittyImageDiskStore = kittyImageDiskStore
        remoteAccess = RemoteAccessController(
            webPushService: webPushService,
            apnsService: apnsService,
            notificationSync: notificationSync
        )
        load()
    }

    // MARK: - lifecycle wiring

    func attach(notifications: any NotificationPosting) {
        self.notifications = notifications
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
    }

    @discardableResult
    func startServer() -> Bool {
        let server = ControlServer { [weak self] req in
            guard let self else { return .failure("app shutting down") }
            if req.command == "screenshot" {
                let path = req.path ?? FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/copilot-projects.png").path
                let preparation = DispatchQueue.main.sync {
                    MainActor.assumeIsolated {
                        self.prepareScreenshot(to: path)
                    }
                }
                switch preparation {
                case .ready(let request):
                    return WindowScreenshot.capture(request)
                case .failure(let error):
                    return .failure(error)
                }
            }
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { self.handle(req) }
            }
        }
        guard server.start() else { return false }
        self.server = server
        return true
    }

    func stopServer() {
        server?.stop()
    }

    /// Best-effort: symlink the bundled binary onto the user's PATH so terminal
    /// hooks can call `copilot-projects`.
    func installCLISymlinkIfPossible() {
        guard let exe = Bundle.main.executablePath else { return }
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        // Keep the copilot-projects CLI symlink pointed at the running bundle.
        let link = dir.appendingPathComponent("copilot-projects")
        if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != exe {
            try? fm.removeItem(at: link)
            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: exe)
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

    private var currentSelectedSessionId: String? {
        guard let pid = selectedProjectId, let pi = projectIndex(pid) else { return nil }
        return projects[pi].selectedSessionId
    }

    // MARK: - terminal controllers (lazy, cached, not observed)

    /// Returns (creating if needed) the live terminal for a session. A cached
    /// controller is always returned as-is, so a duplicate create request can never
    /// relaunch an existing session. `launchCopilotIfCreated` + `copilotExecutable`
    /// are honored ONLY when a controller is created here (a fresh remote session);
    /// a recorded resume marker still takes precedence inside the controller.
    @discardableResult
    func controller(
        for sessionId: String,
        launchCopilotIfCreated: Bool = false,
        copilotExecutable: String? = nil,
        launchWithAllowAll: Bool = false,
        launchCopilotInitialPrompt: String? = nil
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
            guard ownerAllowsResume else { return nil }
            return TranscriptController.isCopilotSessionQuarantined(
                sessionId: sessionId,
                copilotSessionId: candidate,
                directory: resumeMarkerDirectory
            ) ? nil : candidate
        }
        let allowAllCopilot = (try? String(contentsOf:
            resumeMarkerDirectory.appendingPathComponent("\(sessionId).copilot-allow-all"),
            encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resumeWithAllowAll = Self.shouldResumeWithAllowAll(
            copilotSessionId: recordedCopilot,
            allowAllSessionId: allowAllCopilot
        )
        let c = TerminalController(
            sessionId: sessionId,
            cwd: session.cwd,
            extraEnvironment: environment(projectId: project.id, sessionId: sessionId),
            dtachExecutable: dtach,
            dtachSocket: socket,
            copilotSessionId: (recordedCopilot?.isEmpty == false) ? recordedCopilot : nil,
            copilotSessionAllowAll: resumeWithAllowAll || launchWithAllowAll,
            launchCopilotExecutable: launchCopilotIfCreated ? copilotExecutable : nil,
            launchCopilotInitialPrompt: launchCopilotInitialPrompt,
            kittyImageDiskStore: kittyImageDiskStore
        )
        c.onTitle = { [weak self] title in self?.updateTitle(sessionId: sessionId, title: title) }
        c.onDirectory = { [weak self] dir in self?.updateCwd(sessionId: sessionId, dir: dir) }
        c.onExit = { [weak self] _ in self?.handleExit(sessionId: sessionId) }
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

    private func refreshSelectedTranscriptController() {
        guard let sessionId = globalSelectedSessionId else {
            selectedTranscriptController = nil
            return
        }
        guard selectedTranscriptController?.sessionId != sessionId else { return }
        let controller = TranscriptController(sessionId: sessionId)
        selectedTranscriptController = controller
        controller.start()
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
            return ("No sessions in “\(project.name)”", "New Session")
        }
        return ("No project selected", "New Project…")
    }

    /// Backs the empty-state button: add a session to the selected project, or
    /// create a project if there is none.
    func newInActiveContext() {
        if let pid = selectedProjectId {
            addSession(toProjectId: pid)
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

    private func makeProject(name: String, cwd: String, withSession: Bool) -> Project {
        var project = Project(name: name, cwd: cwd)
        if withSession {
            let session = Session(title: "shell", cwd: cwd)
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
        let project = makeProject(name: name, cwd: Paths.defaultStartupDir, withSession: true)
        projects.append(project)
        selectProject(project.id)
    }

    /// Shared single-field prompt. Returns trimmed text, or nil if empty/cancelled.
    private func promptForText(title: String, message: String,
                               confirmTitle: String, initialText: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initialText
        alert.accessoryView = field
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    @discardableResult
    func addSession(toProjectId pid: String, cwd: String? = nil) -> String? {
        guard let pi = projectIndex(pid) else { return nil }
        let dir = cwd ?? defaultCwd(forProjectIndex: pi)
        let session = Session(title: "shell", cwd: dir)
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        controller(for: session.id)
        refreshSelectedTranscriptController()
        save()
        return session.id
    }

    func addAdversarialReviewSessionInteractive(toProjectId pid: String) {
        guard remoteSessionBackendAvailable(),
              remoteCopilotExecutable() != nil else {
            presentAlert(
                title: "Copilot Is Unavailable",
                message: "Install or configure the Copilot CLI before starting a pull request review."
            )
            return
        }
        guard remoteReposDirectory() != nil else {
            presentAlert(
                title: "Repos Folder Is Unavailable",
                message: "Create ~/Repos before starting a local pull request review."
            )
            return
        }

        var initialText = ""
        while let input = promptForText(
            title: "Review Pull Request",
            message: "Paste a GitHub pull request URL. Copilot will start a read-only local adversarial review.",
            confirmTitle: "Review",
            initialText: initialText
        ) {
            if addAdversarialReviewSession(
                toProjectId: pid,
                pullRequestURL: input
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
        pullRequestURL: String
    ) -> String? {
        guard let pi = projectIndex(pid),
              let target = PullRequestReviewTarget.parse(pullRequestURL),
              remoteSessionBackendAvailable(),
              let copilotExecutable = remoteCopilotExecutable(),
              let cwd = remoteReposDirectory() else {
            return nil
        }

        let session = Session(title: target.title, cwd: cwd)
        projects[pi].sessions.append(session)
        projects[pi].selectedSessionId = session.id
        let prompt = Self.adversarialReviewPrompt(for: target)
        if let remoteSessionLauncher {
            remoteSessionLauncher(session.id, copilotExecutable, prompt)
        } else {
            controller(
                for: session.id,
                launchCopilotIfCreated: true,
                copilotExecutable: copilotExecutable,
                launchCopilotInitialPrompt: prompt
            )
        }
        refreshSelectedTranscriptController()
        save()
        return session.id
    }

    nonisolated static func adversarialReviewPrompt(
        for target: PullRequestReviewTarget
    ) -> String {
        "Perform a read-only local adversarial review of \(target.url). "
            + "Use the adversarial-review skill. Inspect the pull request from a local checkout "
            + "or isolated worktree. Do not edit files, push changes, or post anything to GitHub. "
            + "Report the findings in this session."
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Create (or idempotently resolve) a session for a remote `POST /sessions/create`.
    /// Runs synchronously on the MainActor and mutates state directly.
    ///
    /// The session id is deterministically the request's canonical UUID string, so a
    /// crash between appending the session and writing the ledger still lets a retry
    /// find the existing session (returning `.existing`) rather than double-creating.
    /// The ledger acts as a tombstone: once a request produced a session, a later
    /// request whose session has since been closed returns `.gone` and never recreates.
    /// The Mac's current selection is preserved — a new session only becomes the
    /// project's selected tab when the project had no selection.
    func createRemoteSession(
        _ request: RemoteCreateSessionRequest,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        guard request.pullRequestURL == nil else { return .badRequest }
        return createRemoteSession(
            request,
            title: "Copilot",
            initialPrompt: nil,
            now: now
        )
    }

    func createRemoteAdversarialReviewSession(
        _ request: RemoteCreateSessionRequest,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        guard let rawURL = request.pullRequestURL,
              let target = PullRequestReviewTarget.parse(rawURL),
              rawURL == target.url else {
            return .badRequest
        }
        return createRemoteSession(
            request,
            title: target.title,
            initialPrompt: Self.adversarialReviewPrompt(for: target),
            now: now
        )
    }

    private func createRemoteSession(
        _ request: RemoteCreateSessionRequest,
        title: String,
        initialPrompt: String?,
        now: Date
    ) -> RemoteSessionCreationOutcome {
        let sessionId = request.requestId.uuidString

        // A live deterministic session answers replays directly and covers the
        // crash window where the session was saved but the ledger wasn't yet written.
        if let loc = locateIndex(sessionId) {
            let owningProjectId = projects[loc.p].id
            let response = RemoteCreateSessionResponse(
                requestId: request.requestId,
                projectId: owningProjectId,
                sessionId: sessionId
            )
            if let record = sessionCreationLedger.record(
                for: request.requestId,
                now: now
            ) {
                guard record.projectId == request.projectId,
                      record.sessionId == sessionId else {
                    return .conflict
                }
                return .existing(response)
            }
            return owningProjectId == request.projectId
                ? .existing(response)
                : .conflict
        }

        // Processed before, but the session is gone: it is a tombstone, never resurrect it.
        if sessionCreationLedger.record(for: request.requestId, now: now) != nil {
            return .gone
        }

        guard let pi = projectIndex(request.projectId) else { return .unknownProject }
        guard remoteSessionBackendAvailable() else { return .unavailable }
        guard let copilotExecutable = remoteCopilotExecutable() else { return .unavailable }
        guard let cwd = remoteReposDirectory() else { return .invalid }

        let session = Session(id: sessionId, title: title, cwd: cwd)
        projects[pi].sessions.append(session)
        // Do NOT steal the Mac's selected tab: only adopt the new session when the
        // project currently has no selection.
        if (projects[pi].selectedSessionId ?? "").isEmpty {
            projects[pi].selectedSessionId = sessionId
        }

        // Bring up the terminal with a one-shot Copilot launch on its fresh master.
        // Remote (phone/web) sessions start in allow-all so they run unattended
        // without tool-approval prompts nobody is at the Mac to answer.
        if let remoteSessionLauncher {
            remoteSessionLauncher(sessionId, copilotExecutable, initialPrompt)
        } else {
            controller(
                for: sessionId,
                launchCopilotIfCreated: true,
                copilotExecutable: copilotExecutable,
                launchWithAllowAll: true,
                launchCopilotInitialPrompt: initialPrompt
            )
        }
        refreshSelectedTranscriptController()
        save()

        // Record the tombstone only AFTER the session is appended and persisted, so a
        // crash can never leave a ledger entry for a session that was never created.
        sessionCreationLedger.remember(
            SessionCreationRecord(
                requestId: sessionId,
                projectId: request.projectId,
                sessionId: sessionId,
                createdAt: now
            ),
            now: now
        )

        return .created(RemoteCreateSessionResponse(
            requestId: request.requestId,
            projectId: request.projectId,
            sessionId: sessionId
        ))
    }

    /// Where a new session should start: inherit the active pane's directory
    /// (kept fresh by OSC 7 when the shell emits it), else the project default,
    /// else the default startup folder (~/Repos).
    private func defaultCwd(forProjectIndex pi: Int) -> String {
        let project = projects[pi]
        if let sid = project.selectedSessionId,
           let session = project.sessions.first(where: { $0.id == sid }),
           !session.cwd.isEmpty {
            return session.cwd
        }
        if !project.cwd.isEmpty { return project.cwd }
        return Paths.defaultStartupDir
    }

    func addSessionToSelected() {
        guard let pid = selectedProjectId else { return }
        addSession(toProjectId: pid)
    }

    func closeSession(projectId pid: String, sessionId sid: String) {
        guard let pi = projectIndex(pid) else { return }
        controllers[sid]?.terminate()
        controllers[sid] = nil
        if selectedTranscriptController?.sessionId == sid {
            selectedTranscriptController = nil
        }
        transcriptOpenSessions.remove(sid)
        statusEventClock.reset(sessionId: sid)
        promptStatusEventClock.reset(sessionId: sid)
        backgroundAgentsSuppressed.remove(sid)
        completionPending.remove(sid)
        permissionNotificationTokens[sid] = nil
        permissionStatusRestores[sid] = nil
        scheduledSnapshotsSuppressed.remove(sid)
        foregroundIdleGenerationBaselines.removeValue(forKey: sid)
        let closedIndex = projects[pi].sessions.firstIndex { $0.id == sid }
        let wasSelected = projects[pi].selectedSessionId == sid
        projects[pi].sessions.removeAll { $0.id == sid }
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
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
    }

    func closeSelectedSession() {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              let sid = projects[pi].selectedSessionId else { return }
        requestCloseSession(projectId: pid, sessionId: sid)
    }

    func closeRemoteSession(sessionId: String) -> Bool {
        guard let location = locateIndex(sessionId) else { return false }
        requestCloseSession(
            projectId: projects[location.p].id,
            sessionId: sessionId
        )
        return true
    }

    /// User-initiated close (⌘W / tab ✕). Ends the session immediately with no
    /// confirmation — an explicit close is intentional, and app restarts resume
    /// sessions, so there's nothing to protect against here.
    func requestCloseSession(projectId pid: String, sessionId sid: String) {
        destroySession(projectId: pid, sessionId: sid)
    }

    /// Permanently end a session: kill its dtach master (so it does not resume),
    /// remove its socket, and drop it from the model.
    private func destroySession(projectId pid: String, sessionId sid: String) {
        controllers[sid]?.terminalView.kittyImageCapture.disablePersistence()
        _ = SessionArtifacts.destroy(
            sessionId: sid,
            kittyImageDiskStore: kittyImageDiskStore
        )
        closeSession(projectId: pid, sessionId: sid)
    }

    /// Detach (don't destroy) every live terminal — used on app quit so dtach
    /// masters survive and sessions resume on next launch.
    func detachAllClients() {
        for controller in controllers.values {
            controller.terminate()
        }
        controllers.removeAll()
    }

    func detachAllClientsAndDrain() async {
        let activeControllers = Array(controllers.values)
        for controller in activeControllers {
            controller.beginTerminationDrain()
        }
        for controller in activeControllers {
            await controller.finishTerminationDrain()
        }
        controllers.removeAll()
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
        remoteAccess.stopGateway()
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

    func startRemoteAccessIfEnabled() {
        remoteAccess.startIfEnabled(model: self)
    }

    /// Count of sessions with an in-flight agent (running or waiting).
    var activeSessionCount: Int {
        projects.reduce(0) { acc, project in
            acc + project.sessions.filter { $0.status == .running || $0.status == .waiting }.count
        }
    }

    /// Fleet roll-ups across every project, for the title-bar status line.
    var totalRunning: Int { projects.reduce(0) { $0 + $1.runningCount } }
    var totalWaiting: Int { projects.reduce(0) { $0 + $1.waitingCount } }
    var totalBackgroundWork: Int {
        projects.reduce(0) { $0 + $1.backgroundWorkCount }
    }
    var totalScheduled: Int {
        projects.reduce(0) { $0 + $1.scheduledCount }
    }
    var totalReady: Int {
        projects.reduce(0) { $0 + $1.sessions.filter { $0.finishedUnseen }.count }
    }

    func remoteWorkspaceSnapshot() -> RemoteWorkspaceSnapshot {
        let promptNow = Date()
        let promptNowMs = SessionArtifacts.currentStatusTimestamp()
        return RemoteWorkspaceSnapshot(
            projects: projects.map { project in
                RemoteProjectSnapshot(
                    id: project.id,
                    name: project.name,
                    selectedSessionId: project.selectedSessionId,
                    sessions: project.sessions.map { session in
                        RemoteSessionSnapshot(
                            id: session.id,
                            title: session.title,
                            status: session.status.rawValue,
                            statusText: session.statusText,
                            unread: session.hasUnread,
                            ready: session.finishedUnseen,
                            background: session.hasBackgroundWork,
                            scheduled: !session.schedules.isEmpty,
                            promptable: Self.remotePromptEligibility(
                                status: session.status,
                                scheduledTurnActive: session.scheduledTurnActive,
                                hasPendingQuestions: session.hasPendingQuestions,
                                hasLiveAgent: liveAgentSessions.contains(session.id),
                                backgroundOnly: Self.backgroundOnlyPromptEvidence(
                                    status: session.status,
                                    snapshot: session.agentActivity,
                                    backgroundAgentsActive: session.backgroundAgentsActive,
                                    now: promptNow,
                                    nowMs: promptNowMs,
                                    clockMs: promptStatusEventClock.timestamp(for: session.id)
                                ),
                                footerActivity: controllers[session.id]?.agentActivity
                                    ?? .unknown
                            ) == .sent,
                            pendingUserInputs: session.agentActivity?
                                .remoteUserInputRequests(),
                            pendingElicitations: session.agentActivity?
                                .remoteElicitationRequests(),
                            model: session.agentActivity?.remoteModelInfo(),
                            availableModels: session.agentActivity?
                                .remoteAvailableModels()
                        )
                    }
                )
            },
            selectedProjectId: selectedProjectId
        )
    }

    func remoteScreen(
        sessionId: String,
        afterLine: Int? = nil
    ) -> RemoteTerminalScreen? {
        guard locateIndex(sessionId) != nil,
              let view = controller(for: sessionId)?.terminalView,
              !view.isRestoringImages,
              let terminal = view.terminal else {
            return nil
        }
        let translate: (Int) -> String? = { row in
            terminal.getScrollInvariantLine(row: row)?.translateToString(
                trimRight: true,
                skipNullCellsFollowingWide: false,
                characterProvider: { terminal.getCharacter(for: $0) }
            )
        }
        let terminalScroll = terminal.isCurrentBufferAlternate
            || liveAgentSessions.contains(sessionId)
        let currentVersion = { (imageId: UInt32, placementId: UInt32) in
            view.kittyImageCapture.currentVersion(for: imageId, placementId: placementId)
        }
        if terminalScroll {
            let screen = RemoteTerminalScreen.captureVisible(
                sessionId: sessionId,
                cols: terminal.cols,
                rows: terminal.rows,
                lineAt: { row in
                    terminal.getLine(row: row)?.translateToString(
                        trimRight: true,
                        skipNullCellsFollowingWide: false,
                        characterProvider: { terminal.getCharacter(for: $0) }
                    )
                }
            )
            // Live/alternate-screen mode: `getLine(row:)` is keyed by viewport
            // row, matching `firstLine == 0` in the emitted screen.
            let gridLines = (0 ..< terminal.rows).compactMap { row in
                terminal.getLine(row: row).map { (lineId: row, line: $0) }
            }
            // Live/alternate-screen mode: the entire viewport is "the current
            // screen window", so every discovered placement is priority.
            let placements = RemoteKittyPlacementScanner.scan(
                cells: RemoteKittyPlacementScanner.gridCells(from: gridLines, terminal: terminal),
                firstLine: 0,
                priorityLineRange: 0 ..< terminal.rows,
                currentVersion: currentVersion
            )
            // Always attach a present array (even `[]`), never `nil`: this
            // host scans the *full* retained history on every screen, so an
            // empty result is a definitive "nothing retained anywhere" —
            // letting a client distinguish that from an older host that
            // omits the field entirely (and safely drop any placement it
            // was previously showing instead of assuming it's still there).
            return screen.withImages(placements)
        }
        let screen = RemoteTerminalScreen.captureHistory(
            sessionId: sessionId,
            cols: terminal.cols,
            rows: terminal.rows,
            absoluteStart: terminal.buffer.totalLinesTrimmed,
            scanRows: terminal.options.scrollback + terminal.rows,
            maximumRows: min(terminal.options.scrollback, 500) + terminal.rows,
            afterLine: afterLine,
            lineExists: { terminal.getScrollInvariantLine(row: $0) != nil },
            lineAt: translate
        )
        // History mode: recompute against the screen's own `firstLine` (never a
        // stale value from a prior live/history capture) using scroll-invariant
        // absolute row ids, matching how its lines were captured above. The scan
        // window covers the *entire* retained history range
        // `[historyStartLine, liveTopLine + rows)` — not just the emitted text
        // window padded by a fixed number of rows — so any image retained
        // anywhere in that window (including one taller than the viewport, or
        // one that straddles an incremental `afterLine`-narrowed window
        // boundary) is discovered in full: only its *emitted* `line` stays
        // relative to `screen.firstLine` (so it can go negative for rows above
        // the emitted window), never the scan itself.
        let scanLowerBound = screen.historyStartLine
        let scanUpperBound = screen.liveTopLine + screen.rows
        let gridLines = (scanLowerBound ..< max(scanLowerBound, scanUpperBound)).compactMap { row in
            terminal.getScrollInvariantLine(row: row).map { (lineId: row, line: $0) }
        }
        // The current/emitted incremental text window (`screen.firstLine ..<
        // screen.firstLine + screen.lines.count`) is the priority tier: a
        // placement a client can actually see right now must never be
        // starved out of the cap by older, merely-still-retained history.
        let placements = RemoteKittyPlacementScanner.scan(
            cells: RemoteKittyPlacementScanner.gridCells(from: gridLines, terminal: terminal),
            firstLine: screen.firstLine,
            priorityLineRange: screen.firstLine ..< (screen.firstLine + screen.lines.count),
            currentVersion: currentVersion
        )
        // Always attach a present array (even `[]`), never `nil` — see the
        // matching comment in the live branch above.
        return screen.withImages(placements)
    }

    func sendRemoteInput(sessionId: String, value: String) {
        guard value.utf8.count <= 8_192 else { return }
        controller(for: sessionId)?.terminalView.sendRemoteInput(value)
    }

    @discardableResult
    func sendRemoteKey(sessionId: String, key: String) -> Bool {
        guard let terminalView = controller(for: sessionId)?.terminalView else {
            return false
        }
        return terminalView.sendRemoteKey(
            key,
            forceFocusReporting: key == "enter"
                && remoteSessionHasLiveAgent(sessionId)
        )
    }

    func sendRemoteCommand(
        sessionId: String,
        requestId: String,
        value: String
    ) -> RemoteCommandResult {
        let ledgerId = "\(sessionId):\(requestId)"
        if remoteCommandRequestLedger.contains(ledgerId) {
            return .sent
        }
        guard ProjectsTerminalView.remoteCommandTextBytes(value) != nil,
              let view = controller(for: sessionId)?.terminalView else {
            return .invalid
        }
        guard view.sendRemoteCommand(
            value,
            forceFocusReporting: remoteSessionHasLiveAgent(sessionId)
        ) else {
            return .busy
        }
        remoteCommandRequestLedger.record(ledgerId)
        return .sent
    }

    private func remoteSessionHasLiveAgent(_ sessionId: String) -> Bool {
        if liveAgentSessions.contains(sessionId) {
            return true
        }
        let liveSessions = remotePromptLiveSessions?(agentProcessNames)
            ?? ProcessTree.agentSessions(
                agentNames: agentProcessNames,
                in: ProcessTree.snapshot()
            )
        return liveSessions.contains(sessionId)
    }

    func sendRemoteScroll(sessionId: String, delta: Int) {
        guard abs(delta) <= 20 else { return }
        controller(for: sessionId)?.terminalView.sendRemoteScroll(
            delta: delta,
            agentLive: liveAgentSessions.contains(sessionId)
        )
    }

    func sendRemotePrompt(sessionId: String, value: String) -> RemotePromptResult {
        guard ProjectsTerminalView.remotePromptPasteBytes(value) != nil,
              let location = locateIndex(sessionId) else { return .invalid }
        let session = projects[location.p].sessions[location.s]
        let liveSessions = remotePromptLiveSessions?(agentProcessNames)
            ?? ProcessTree.agentSessions(
                agentNames: agentProcessNames,
                in: ProcessTree.snapshot()
            )
        let target: RemotePromptTarget?
        if let remotePromptTarget {
            target = remotePromptTarget(sessionId)
        } else if let controller = controllers[sessionId] {
            target = RemotePromptTarget(
                activity: controller.agentActivity,
                send: { controller.terminalView.sendRemotePrompt($0) }
            )
        } else {
            target = nil
        }
        let promptNow = Date()
        let promptNowMs = SessionArtifacts.currentStatusTimestamp()
        let eligibility = Self.remotePromptEligibility(
            status: session.status,
            scheduledTurnActive: session.scheduledTurnActive,
            hasPendingQuestions: session.hasPendingQuestions,
            hasLiveAgent: liveSessions.contains(sessionId),
            backgroundOnly: Self.backgroundOnlyPromptEvidence(
                status: session.status,
                snapshot: session.agentActivity,
                backgroundAgentsActive: session.backgroundAgentsActive,
                now: promptNow,
                nowMs: promptNowMs,
                clockMs: promptStatusEventClock.timestamp(for: sessionId)
            ),
            footerActivity: target?.activity ?? .unknown
        )
        if eligibility == .busy { return .busy }
        guard liveSessions.contains(sessionId),
              let target,
              target.activity == .idle else {
            return .noLiveCopilot
        }
        return target.send(value) ? .sent : .invalid
    }

    /// Whether a remote message may be sent to a session right now. Readiness of the
    /// *foreground* is the gate — primarily the terminal footer, NOT whether the
    /// session is globally `.running`. Scheduled work and subagents can keep the
    /// session globally active after the foreground has returned to an idle prompt,
    /// so gating on that background state stranded the composer's queued messages.
    ///
    /// `status == .waiting` is still blocked: it marks a foreground question the user
    /// must answer inline — an `ask_user`/`elicitation` dialog OR a raw tool
    /// permission prompt. Permission prompts surface *only* via the CLI status hook
    /// (they populate no structured-question entry, so `hasPendingQuestions` is
    /// `false` for them) and the footer can read `.idle` behind the dialog, so the
    /// `.waiting` check is the one signal that reliably guards them.
    /// `hasPendingQuestions` is the extension's authoritative signal for structured
    /// questions. Scheduled work is allowed only with fresh, clock-ordered evidence
    /// that the interactive foreground is inactive.
    /// `sendRemotePrompt` re-checks the footer immediately before the actual send.
    nonisolated static func remotePromptEligibility(
        status: SessionStatus,
        scheduledTurnActive: Bool = false,
        hasPendingQuestions: Bool = false,
        hasLiveAgent: Bool,
        backgroundOnly: Bool = false,
        footerActivity: FooterActivity
    ) -> RemotePromptResult {
        guard hasLiveAgent else { return .noLiveCopilot }
        // Never inject a free-form message over a foreground user prompt: a structured
        // ask_user/elicitation must be answered via its card; and `status == .waiting`
        // covers raw permission
        // prompts that no structured-question signal sees — even when the footer
        // momentarily reads idle behind the dialog.
        guard !hasPendingQuestions, status != .waiting else {
            return .busy
        }
        guard !scheduledTurnActive || backgroundOnly else { return .busy }
        guard status != .running || backgroundOnly else { return .busy }
        // For the remaining states the terminal footer is the authoritative "Copilot
        // is at a prompt" signal. Bypassing scheduled/running state requires a fresh,
        // clock-ordered heartbeat proving the foreground is inactive while background
        // work remains.
        // `sendRemotePrompt` re-checks this footer immediately before sending.
        guard footerActivity == .idle else { return .busy }
        return .sent
    }

    /// Evidence that a session is only busy because scheduled, subagent, or CLI
    /// background-agent work remains after the interactive foreground ended. This
    /// mirrors the causal guards in `reconcileAgentFooters`: stale footer text alone
    /// is never enough to inject a remote prompt over a possibly-active foreground
    /// turn.
    ///
    /// `backgroundAgentsActive` carries the session's CLI background-agent state
    /// (scraped from the terminal title: "Copilot: Waiting for background agents").
    /// Those agents have no representation in the heartbeat's `activeSubagents`
    /// array, yet they keep `session.idle` from firing exactly like scheduled and
    /// subagent work — so a `.running` session whose foreground has gone idle while
    /// they run must count as background-only too, or it reads "working" forever.
    nonisolated static func backgroundOnlyEvidenceMs(
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMs: Int64
    ) -> Int64? {
        guard let snapshot,
              snapshot.isFresh(at: now),
              snapshot.foregroundTurnActive == false,
              snapshot.scheduledTurnActive
                || !snapshot.activeSubagents.isEmpty
                || backgroundAgentsActive,
              let snapshotMs = snapshot.foregroundTransitionMilliseconds,
              snapshotMs <= nowMs else { return nil }
        return snapshotMs
    }

    nonisolated static func backgroundOnlyPromptEvidence(
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMs: Int64,
        clockMs: Int64?
    ) -> Bool {
        guard snapshot?.reportsTerminalDisconnect != true else { return false }
        guard let snapshotMs = backgroundOnlyEvidenceMs(
            snapshot: snapshot,
            backgroundAgentsActive: backgroundAgentsActive,
            now: now,
            nowMs: nowMs
        ) else { return false }
        if let clockMs {
            return status == .idle ? snapshotMs >= clockMs : snapshotMs > clockMs
        }
        return true
    }

    /// Accept a remote answer to a structured `ask_user` question and hand it to the
    /// extension via an atomically-written response file. Validation re-reads the
    /// fresh heartbeat snapshot from disk (never trusting in-memory state) so a stale
    /// or superseded question can't be answered, and the exact choice/freeform/size
    /// rules are enforced host-side before anything is written.
    func answerUserInput(
        sessionId: String,
        answer: RemoteUserInputAnswer,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        guard locateIndex(sessionId) != nil else { return .invalid }

        let snapshotURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).agent-activity.json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(
                AgentActivitySnapshot.self, from: data
              ),
              snapshot.isFresh(at: now),
              let request = snapshot.trackedUserInputs?
                .first(where: { $0.requestId == answer.requestId })
        else { return .invalid }
        guard !snapshot.reportsTerminalDisconnect else { return .invalid }

        guard answer.answer.utf8.count <= 8_192 else { return .invalid }
        if answer.wasFreeform {
            guard request.allowFreeform else { return .invalid }
        } else {
            guard request.choices.contains(answer.answer) else { return .invalid }
        }

        // Bind the answer to the tab's live Copilot session so a response written for
        // an old (pre-resume) agent session is rejected by the extension.
        let markerURL = resumeMarkerDirectory
            .appendingPathComponent("\(sessionId).copilot-session")
        guard let copilotSessionId = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !copilotSessionId.isEmpty else { return .invalid }

        // One outstanding response per tab: refuse while a prior answer is still being
        // consumed by the extension, which serializes retries.
        let responseURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).user-input-response.json")
        if FileManager.default.fileExists(atPath: responseURL.path) { return .conflict }

        let payload = UserInputResponseFile(
            schemaVersion: 1,
            copilotSessionId: copilotSessionId,
            requestId: request.requestId,
            answer: answer.answer,
            wasFreeform: answer.wasFreeform
        )
        guard let encoded = try? JSONEncoder().encode(payload),
              Self.atomicallyWrite0600(encoded, to: responseURL) else {
            return .invalid
        }
        return .accepted
    }

    /// Submit a remote answer to a pending elicitation. Mirrors `answerUserInput`:
    /// re-reads the fresh heartbeat snapshot from disk, validates the request is
    /// still live, binds to the tab's Copilot session, and writes an atomic
    /// single-outstanding response file the extension consumes over RPC.
    func answerElicitation(
        sessionId: String,
        answer: RemoteElicitationAnswer,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        guard let location = locateIndex(sessionId) else { return .invalid }

        let snapshotURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).agent-activity.json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(
                AgentActivitySnapshot.self, from: data
              ),
              snapshot.isFresh(at: now),
              let request = snapshot.trackedElicitations?
                .first(where: { $0.requestId == answer.requestId })
        else { return .invalid }
        // Accept must carry content; decline/cancel must not.
        switch answer.action {
        case .accept:
            if answer.requestId.hasPrefix("synthetic::durable-ask-user::") {
                guard Self.durableDefaultBooleanSelection(
                    request: request,
                    answer: answer
                ) != nil else { return .invalid }
            } else if request.mode == "url" || request.url != nil {
                guard answer.content == nil else { return .invalid }
            } else {
                guard let content = answer.content,
                      Self.isValidElicitationContent(content),
                      Self.elicitationContent(content, satisfies: request.schema),
                      let encoded = try? JSONEncoder().encode(content),
                      encoded.count <= 32_768 else { return .invalid }
            }
        case .decline, .cancel:
            guard answer.content == nil else { return .invalid }
        }

        if answer.requestId.hasPrefix("synthetic::durable-ask-user::") {
            let ledgerId = "\(sessionId):elicitation:\(answer.requestId)"
            if remoteElicitationRequestLedger.contains(ledgerId) {
                return .conflict
            }
            let terminalTarget: RemoteElicitationTerminalTarget?
            if let remoteElicitationTarget {
                terminalTarget = remoteElicitationTarget(sessionId)
            } else if let terminalView = terminalView(for: sessionId) {
                terminalTarget = RemoteElicitationTerminalTarget(
                    isAtLiveBottom: Self.durableElicitationIsAtLiveBottom(
                        canScroll: terminalView.canScroll,
                        scrollPosition: terminalView.scrollPosition
                    ),
                    screen: remoteScreen(sessionId: sessionId),
                    sendEnter: {
                        terminalView.sendRemoteKey(
                            "enter",
                            forceFocusReporting: true
                        )
                    }
                )
            } else {
                terminalTarget = nil
            }
            guard snapshot.isFresh(at: now, ttl: 10),
                  snapshot.pendingPermissionRequestIds?.isEmpty == true,
                  projects[location.p].sessions[location.s].status == .waiting,
                  let terminalTarget,
                  remoteSessionHasLiveAgent(sessionId),
                  terminalTarget.isAtLiveBottom,
                  let selected = Self.durableDefaultBooleanSelection(
                    request: request,
                    answer: answer
                  ),
                  let screen = terminalTarget.screen,
                  screen.scrollMode == .terminal,
                  Self.durableBooleanPromptIsVisible(
                    lines: screen.lines,
                    request: request,
                    selected: selected
                  )
            else { return .invalid }
            guard terminalTarget.sendEnter() else { return .invalid }
            remoteElicitationRequestLedger.record(ledgerId)
            return .accepted
        }
        guard !snapshot.reportsTerminalDisconnect else { return .invalid }

        let markerURL = resumeMarkerDirectory
            .appendingPathComponent("\(sessionId).copilot-session")
        guard let copilotSessionId = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !copilotSessionId.isEmpty else { return .invalid }

        let responseURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).elicitation-response.json")
        if FileManager.default.fileExists(atPath: responseURL.path) { return .conflict }

        let payload = ElicitationResponseFile(
            schemaVersion: 1,
            copilotSessionId: copilotSessionId,
            requestId: answer.requestId,
            action: answer.action.rawValue,
            content: answer.action == .accept ? answer.content : nil
        )
        guard let encoded = try? JSONEncoder().encode(payload),
              Self.atomicallyWrite0600(encoded, to: responseURL) else {
            return .invalid
        }
        return .accepted
    }

    nonisolated static func durableDefaultBooleanSelection(
        request: TrackedElicitation,
        answer: RemoteElicitationAnswer
    ) -> Bool? {
        guard request.requestId.hasPrefix("synthetic::durable-ask-user::"),
              request.mode == "terminal-default",
              answer.action == .accept,
              let content = answer.content,
              content.count == 1,
              case .object(let root)? = request.schema,
              Set(root.keys) == [
                "properties", "x-copilot-projects-terminal-default"
              ],
              root["x-copilot-projects-terminal-default"] == .bool(true),
              case .object(let properties)? = root["properties"],
              properties.count == 1,
              let fieldName = properties.keys.first,
              case .object(let field)? = properties[fieldName],
              field["type"] == .string("boolean"),
              case .bool(let defaultValue)? = field["default"],
              case .bool(let selected)? = content[fieldName],
              selected == defaultValue
        else { return nil }
        return selected
    }

    nonisolated static func durableBooleanPromptIsVisible(
        lines: [String],
        request: TrackedElicitation,
        selected: Bool
    ) -> Bool {
        let normalizedLines = lines.map(normalizedTerminalText)
        let message = normalizedTerminalText(request.message)
        let selectedRow = selected ? "❯ Yes" : "❯ No"
        guard !message.isEmpty,
              let headerIndex = normalizedLines.lastIndex(
                of: "Copilot needs information."
              )
        else { return false }

        let promptLines = Array(normalizedLines.dropFirst(headerIndex + 1))
        let highlightedRows = promptLines.filter { $0.hasPrefix("❯ ") }
        guard highlightedRows == [selectedRow],
              let selectionIndex = promptLines.firstIndex(of: selectedRow)
        else { return false }

        let trailingLines = promptLines.dropFirst(selectionIndex + 1)
            .filter { !$0.isEmpty }
        guard trailingLines.allSatisfy({ $0 == "Yes" || $0 == "No" }) else {
            return false
        }
        let promptText = promptLines[..<selectionIndex].joined(separator: " ")
        return promptText == message || promptText.hasPrefix(message + " ")
    }

    nonisolated static func durableElicitationIsAtLiveBottom(
        canScroll: Bool,
        scrollPosition: Double
    ) -> Bool {
        !canScroll || scrollPosition >= 1
    }

    private nonisolated static func normalizedTerminalText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Submit a remote model switch. Mirrors `answerUserInput`/`answerElicitation`:
    /// re-reads the fresh heartbeat snapshot, validates the target against the
    /// session's live catalog, binds to the tab's Copilot session, and writes an
    /// atomic single-outstanding request file the extension consumes over RPC.
    func setModel(
        sessionId: String,
        selection: RemoteModelSelection,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        guard locateIndex(sessionId) != nil else { return .invalid }

        let snapshotURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).agent-activity.json")
        guard let data = try? Data(contentsOf: snapshotURL),
              let snapshot = try? JSONDecoder().decode(
                AgentActivitySnapshot.self, from: data
              ),
              snapshot.isFresh(at: now),
              let target = snapshot.availableModels?
                .first(where: { $0.id == selection.modelId })
        else { return .invalid }

        // Never switch to a policy-disabled model, even if a stale client offered it.
        guard target.disabled != true else { return .invalid }

        if let effort = selection.reasoningEffort {
            // Only accept a level this model actually advertises.
            guard let supported = target.supportedReasoningEfforts,
                  supported.contains(effort) else { return .invalid }
        }
        if let tier = selection.contextTier {
            guard tier == "default" || tier == "long_context" else { return .invalid }
            if tier == "long_context" {
                guard target.longContextAvailable != false else { return .invalid }
            }
        }

        // Bind the switch to the tab's live Copilot session so a request written for
        // an old (pre-resume) agent session is rejected by the extension.
        let markerURL = resumeMarkerDirectory
            .appendingPathComponent("\(sessionId).copilot-session")
        guard let copilotSessionId = (try? String(contentsOf: markerURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !copilotSessionId.isEmpty else { return .invalid }

        // One outstanding switch per tab: refuse while a prior request is still being
        // consumed by the extension, which serializes retries.
        let requestURL = agentActivityDirectory
            .appendingPathComponent("\(sessionId).set-model-request.json")
        if FileManager.default.fileExists(atPath: requestURL.path) { return .conflict }

        let payload = SetModelRequestFile(
            schemaVersion: 1,
            copilotSessionId: copilotSessionId,
            modelId: selection.modelId,
            reasoningEffort: selection.reasoningEffort,
            contextTier: selection.contextTier
        )
        guard let encoded = try? JSONEncoder().encode(payload),
              Self.atomicallyWrite0600(encoded, to: requestURL) else {
            return .invalid
        }
        return .accepted
    }

    private static func isValidElicitationContent(_ content: [String: RemoteJSONValue]) -> Bool {
        content.values.allSatisfy { value in
            switch value {
            case .bool, .string:
                return true
            case .number(let number):
                return number.isFinite
            case .array(let values):
                return values.allSatisfy {
                    if case .string = $0 { return true }
                    return false
                }
            case .null, .object:
                return false
            }
        }
    }

    private static func elicitationContent(
        _ content: [String: RemoteJSONValue],
        satisfies schema: RemoteJSONValue?
    ) -> Bool {
        guard let schema else { return true }
        guard case .object(let root) = schema else { return false }
        if let type = jsonString(root["type"]), type != "object" { return false }
        guard let propertiesValue = root["properties"],
              case .object(let properties) = propertiesValue else { return content.isEmpty }
        let required = jsonStringArray(root["required"]) ?? []
        guard required.allSatisfy({ content[$0] != nil }) else { return false }
        for (key, value) in content {
            guard let fieldSchema = properties[key],
                  elicitationValue(value, satisfies: fieldSchema) else {
                return false
            }
        }
        return true
    }

    private static func elicitationValue(
        _ value: RemoteJSONValue,
        satisfies schema: RemoteJSONValue
    ) -> Bool {
        guard case .object(let schema) = schema else { return true }
        if let alternatives = jsonArray(schema["oneOf"]) ?? jsonArray(schema["anyOf"]) {
            guard alternatives.contains(where: { alternative in
                guard case .object(let option) = alternative,
                      let expected = option["const"] else { return false }
                return expected == value
            }) else { return false }
        }
        if let enumValues = jsonArray(schema["enum"]),
           !enumValues.contains(value) {
            return false
        }
        guard let type = jsonString(schema["type"]) else { return true }
        switch type {
        case "string":
            guard case .string(let string) = value else { return false }
            if let minimum = jsonNumber(schema["minLength"]),
               Double(string.unicodeScalars.count) < minimum { return false }
            if let maximum = jsonNumber(schema["maxLength"]),
               Double(string.unicodeScalars.count) > maximum { return false }
            if let format = jsonString(schema["format"]),
               !stringMatchesFormat(string, format: format) { return false }
            return true
        case "number":
            guard case .number(let number) = value else { return false }
            return numberSatisfiesBounds(number, schema: schema)
        case "integer":
            guard case .number(let number) = value,
                  number.rounded() == number else { return false }
            return numberSatisfiesBounds(number, schema: schema)
        case "boolean":
            guard case .bool = value else { return false }
            return true
        case "array":
            guard case .array(let values) = value else { return false }
            if let minimum = jsonNumber(schema["minItems"]),
               Double(values.count) < minimum { return false }
            if let maximum = jsonNumber(schema["maxItems"]),
               Double(values.count) > maximum { return false }
            if let items = schema["items"] {
                return values.allSatisfy { elicitationValue($0, satisfies: items) }
            }
            return true
        default:
            return false
        }
    }

    private static func numberSatisfiesBounds(
        _ number: Double,
        schema: [String: RemoteJSONValue]
    ) -> Bool {
        if let minimum = jsonNumber(schema["minimum"]), number < minimum { return false }
        if let maximum = jsonNumber(schema["maximum"]), number > maximum { return false }
        return true
    }

    private static func stringMatchesFormat(_ string: String, format: String) -> Bool {
        switch format {
        case "email":
            return string.range(
                of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
                options: .regularExpression
            ) != nil
        case "uri":
            guard let components = URLComponents(string: string),
                  let scheme = components.scheme,
                  !scheme.isEmpty else { return false }
            return true
        case "date":
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: string) != nil
        case "date-time":
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) != nil
                || ISO8601DateFormatter().date(from: string) != nil
        default:
            return true
        }
    }

    private static func jsonString(_ value: RemoteJSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }

    private static func jsonNumber(_ value: RemoteJSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let number) = value { return number }
        return nil
    }

    private static func jsonArray(_ value: RemoteJSONValue?) -> [RemoteJSONValue]? {
        guard let value else { return nil }
        if case .array(let values) = value { return values }
        return nil
    }

    private static func jsonStringArray(_ value: RemoteJSONValue?) -> [String]? {
        guard let value, case .array(let values) = value else { return nil }
        var strings: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            strings.append(string)
        }
        return strings
    }

    /// temp file and renaming it into place.
    private static func atomicallyWrite0600(_ data: Data, to url: URL) -> Bool {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory
            .appendingPathComponent(".\(UUID().uuidString).user-input.tmp")
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else { return false }
        if rename(temporary.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }

    func closeProject(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        for session in projects[pi].sessions {
            _ = kittyImageDiskStore.tombstone(sessionId: session.id)
        }
        let snapshot = Paths.dtachExecutable != nil ? ProcessTree.snapshot() : nil
        for session in projects[pi].sessions {
            controllers[session.id]?.terminalView.kittyImageCapture.disablePersistence()
            SessionArtifacts.destroy(
                sessionId: session.id,
                snapshot: snapshot,
                kittyImageDiskStore: kittyImageDiskStore,
                alreadyTombstoned: true
            )
            controllers[session.id]?.terminate()
            controllers[session.id] = nil
            if selectedTranscriptController?.sessionId == session.id {
                selectedTranscriptController = nil
            }
            transcriptOpenSessions.remove(session.id)
            backgroundAgentsSuppressed.remove(session.id)
            completionPending.remove(session.id)
            scheduledSnapshotsSuppressed.remove(session.id)
            foregroundIdleGenerationBaselines.removeValue(forKey: session.id)
        }
        projects.remove(at: pi)
        if selectedProjectId == pid {
            selectedProjectId = projects.first?.id
            if let sid = currentSelectedSessionId { controller(for: sid) }
        }
        refreshSelectedTranscriptController()
        updateDockBadge()
        save()
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
        if globalSelectedSessionId != previousGlobalSelection {
            refreshSelectedTranscriptController()
        }
        updateDockBadge()
        save()
        return true
    }

    func moveRemoteSession(
        sessionId: String,
        toProjectId targetProjectId: String
    ) -> RemoteSessionMoveResult {
        guard projectIndex(targetProjectId) != nil,
              let source = locateIndex(sessionId) else {
            return .missing
        }
        guard projects[source.p].id != targetProjectId else {
            return .unchanged
        }
        return moveSession(
            toProjectId: targetProjectId,
            draggedId: sessionId,
            selectInTarget: false
        ) ? .moved : .missing
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
        guard statusEventClock.shouldApply(sessionId: sessionId, timestamp: timestamp) else { return }
        if Self.advancesPromptSafetyClock(source: source) {
            promptStatusEventClock.seed(sessionId: sessionId, timestamp: timestamp)
        }
        // sessionEnd is also emitted during graceful macOS shutdown. Only a live,
        // non-terminating app can treat it as an explicit user exit.
        if source == "session-end", !isTerminating, !isPoweringOff,
           shouldClearResumeMarkers(sessionId: sessionId, copilotSessionId: copilotSessionId) {
            for suffix in ["copilot-session", "copilot-allow-all"] {
                try? FileManager.default.removeItem(
                    at: resumeMarkerDirectory.appendingPathComponent("\(sessionId).\(suffix)")
                )
            }
        }
        let previous = projects[loc.p].sessions[loc.s].status
        let permissionRestoreState: (
            status: SessionStatus,
            statusText: String?,
            scheduledTurnActive: Bool,
            finishedUnseen: Bool,
            turnCompleted: Bool,
            backgroundAgentsSuppressed: Bool,
            completionPending: Bool,
            foregroundIdleGenerationBaseline: Int?
        )? = notification == .permission
            && permissionNotificationTokens[sessionId] == nil
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
        let clearsBackgroundAgents = status == .idle && source == "session-idle"
        let hasCompletionSignal = status == .idle
            && (source == "agent-stop" || notification == .completed)
            && !projects[loc.p].sessions[loc.s].scheduledTurnActive
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
            cancelPermissionNotification(sessionId: sessionId)
        }
        projects[loc.p].sessions[loc.s].status = status
        projects[loc.p].sessions[loc.s].statusText = text
        if status == .running || status == .waiting {
            if status == .running {
                projects[loc.p].sessions[loc.s].scheduledTurnActive = false
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
            completionPending.insert(sessionId)
        }
        if status == .idle && source == "session-idle" && notification != .completed {
            completionPending.remove(sessionId)
        }
        if timestamp == nil {
            let now = SessionArtifacts.currentStatusTimestamp()
            let effectiveTimestamp = max(now, statusEventClock.timestamp(for: sessionId) ?? now)
            statusEventClock.seed(sessionId: sessionId, timestamp: effectiveTimestamp)
            if Self.advancesPromptSafetyClock(source: source) {
                promptStatusEventClock.seed(
                    sessionId: sessionId,
                    timestamp: effectiveTimestamp
                )
            }
            SessionArtifacts.persistStatus(
                sessionId: sessionId,
                status: status,
                timestamp: effectiveTimestamp,
                promptStatusTimestamp: promptStatusEventClock.timestamp(for: sessionId)
                    ?? effectiveTimestamp
            )
        }

        if status == .idle {
            activityTracker.reset(sessionId: sessionId)
            if source == "session-idle" {
                setBackgroundAgentsActive(sessionId: sessionId, active: false)
                backgroundAgentsSuppressed.insert(sessionId)
            }
        }
        // The agent just went active → idle. If you're not currently looking at this
        // session, flag it as finished-and-unseen (drives the blue sidebar/tab dot).
        if status == .idle, previous == .running || previous == .waiting,
           !startsScheduledTurn, !endsScheduledTurn,
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
                    ?? statusEventClock.timestamp(for: sessionId)
                    ?? now
                let promptTimestamp = promptStatusEventClock.timestamp(for: sessionId)
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
        } else if let notification, notification != .completed {
            postNotification(
                projectId: projects[loc.p].id,
                sessionId: sessionId,
                kind: notification,
                title: notification.title,
                body: nil
            )
        }
    }

    nonisolated static func permissionNotificationDecision(
        status: SessionStatus,
        hasPendingQuestions: Bool,
        pendingPermissionRequestIds: [String]?
    ) -> PermissionNotificationDecision {
        guard status == .waiting else { return .cancel }
        if pendingPermissionRequestIds?.isEmpty == false { return .post }
        guard !hasPendingQuestions else { return .cancel }
        guard let pendingPermissionRequestIds else {
            // Older/stale extensions cannot prove that the prompt is gone.
            return .post
        }
        return pendingPermissionRequestIds.isEmpty ? .suppress : .post
    }

    private func schedulePermissionNotification(
        sessionId: String,
        restore: PermissionStatusRestore
    ) {
        guard permissionNotificationTokens[sessionId] == nil else { return }
        let token = UUID()
        permissionNotificationTokens[sessionId] = token
        permissionStatusRestores[sessionId] = restore
        let delay = permissionNotificationDelayNanoseconds
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.resolvePermissionNotification(sessionId: sessionId, token: token)
        }
    }

    private func cancelPermissionNotification(sessionId: String) {
        permissionNotificationTokens[sessionId] = nil
        permissionStatusRestores[sessionId] = nil
    }

    private func resolvePermissionNotification(sessionId: String, token: UUID) {
        guard permissionNotificationTokens[sessionId] == token,
              let restore = permissionStatusRestores[sessionId] else {
            return
        }
        permissionNotificationTokens[sessionId] = nil
        permissionStatusRestores[sessionId] = nil
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
        let snapshot = loaded?.isFresh() == true ? loaded : nil
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
            return
        case .post:
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
                restore: restore
            )
        }
    }

    private func restoreStatusAfterTransientPermission(
        sessionId: String,
        location: (p: Int, s: Int),
        restore: PermissionStatusRestore
    ) {
        var session = projects[location.p].sessions[location.s]
        session.status = restore.status
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

        statusEventClock.seed(sessionId: sessionId, timestamp: restore.statusTimestamp)
        promptStatusEventClock.seed(
            sessionId: sessionId,
            timestamp: restore.promptStatusTimestamp
        )
        persistPermissionStatus(
            sessionId,
            restore.status,
            restore.statusTimestamp,
            restore.promptStatusTimestamp
        )
        updateDockBadge()
        if restore.completionPending {
            postCompletionIfReady(sessionId: sessionId)
        }
    }

    /// Scheduled pre/post hooks reaffirm background activity but do not describe
    /// foreground ownership. Keep them out of the prompt-safety clock so they cannot
    /// invalidate an already-settled foreground snapshot.
    nonisolated static func advancesPromptSafetyClock(source: String?) -> Bool {
        source != "scheduled-active"
    }

    private func shouldClearResumeMarkers(
        sessionId: String,
        copilotSessionId: String?
    ) -> Bool {
        guard let copilotSessionId, !copilotSessionId.isEmpty else { return false }
        let recorded = resumeMarkerValue(sessionId: sessionId, suffix: "copilot-session")
        let allowAll = resumeMarkerValue(sessionId: sessionId, suffix: "copilot-allow-all")
        return recorded == copilotSessionId
            || (recorded == nil && allowAll == copilotSessionId)
    }

    private func resumeMarkerValue(sessionId: String, suffix: String) -> String? {
        (try? String(
            contentsOf: resumeMarkerDirectory.appendingPathComponent("\(sessionId).\(suffix)"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a session is the one on screen right now (app active + its project and
    /// tab selected). Used to decide if a just-finished session needs an attention dot.
    private func isVisible(projectIndex pi: Int, sessionIndex si: Int) -> Bool {
        Self.isSessionVisible(
            appIsActive: isAppActive(),
            selectedProjectId: selectedProjectId,
            projectId: projects[pi].id,
            selectedSessionId: projects[pi].selectedSessionId,
            sessionId: projects[pi].sessions[si].id
        )
    }

    /// Backstop for flaky agent stop / sessionEnd hooks: a session can only stay
    /// `running`/`waiting` while its shell actually hosts a live agent process.
    /// This never clears status while the agent is genuinely working (unlike a
    /// time-based decay), and clears promptly when the agent exits or crashes.
    func startLivenessReconciler() {
        livenessTimer?.invalidate()
        footerTimer?.invalidate()

        if livenessEnabled {
            reconcileLiveness(markFinished: false)
        } else {
            liveAgentSessions = []
        }

        // Footer backstop: recovers an actively-working attached session after an app
        // restart, and catches Esc-cancel when the stop hook never fires.
        reconcileAgentFooters()
        let footer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileAgentFooters() }
        }
        RunLoop.main.add(footer, forMode: .common)
        footerTimer = footer

        guard livenessEnabled else { return }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileLiveness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func startAgentActivityTracking() {
        agentActivityTimer?.invalidate()
        agentActivitySource?.cancel()
        agentActivitySource = nil
        agentActivityRefreshGeneration += 1
        agentActivityRefreshCoolingDown = false
        agentActivityRefreshPending = false

        try? FileManager.default.createDirectory(
            at: agentActivityDirectory,
            withIntermediateDirectories: true
        )
        refreshAgentActivitySnapshots()

        let fd = open(agentActivityDirectory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.throttledRefreshAgentActivitySnapshots()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            agentActivitySource = source
        }

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshAgentActivitySnapshots() }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentActivityTimer = timer
    }

    /// Coalesce the watcher's bursty directory events into at most one snapshot
    /// scan per throttle window. Leading-edge (the first event of a burst applies
    /// immediately) with a guaranteed trailing flush, so a sustained write storm
    /// whose inter-event gap is below the window is still reflected promptly —
    /// unlike a resettable trailing debounce, which would keep deferring and only
    /// fire once the storm paused. Bounds the *event-driven* scans to one pass per
    /// `agentActivityRefreshThrottle`; the 10s backstop timer scans independently.
    func throttledRefreshAgentActivitySnapshots() {
        guard !agentActivityRefreshCoolingDown else {
            agentActivityRefreshPending = true
            return
        }
        agentActivityRefreshCoolingDown = true
        refreshAgentActivitySnapshots()
        scheduleAgentActivityCooldown(generation: agentActivityRefreshGeneration)
    }

    private func scheduleAgentActivityCooldown(generation: Int) {
        agentActivityCooldownScheduler(agentActivityRefreshThrottle) { [weak self] in
            guard let self, generation == self.agentActivityRefreshGeneration else { return }
            if self.agentActivityRefreshPending {
                self.agentActivityRefreshPending = false
                self.refreshAgentActivitySnapshots()
                self.scheduleAgentActivityCooldown(generation: generation)
            } else {
                self.agentActivityRefreshCoolingDown = false
            }
        }
    }

    func refreshAgentActivitySnapshots(now: Date = Date()) {
        agentActivityScanObserver?()
        let decoder = JSONDecoder()
        let fm = FileManager.default
        var seenSessionIds: Set<String> = []
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let sessionId = projects[pi].sessions[si].id
                seenSessionIds.insert(sessionId)
                let path = agentActivityDirectory
                    .appendingPathComponent("\(sessionId).agent-activity.json").path
                let snapshot = loadAgentActivitySnapshot(
                    sessionId: sessionId, path: path, decoder: decoder, fm: fm
                )
                let fresh = snapshot?.isFresh(at: now) == true ? snapshot : nil
                if projects[pi].sessions[si].agentActivity != fresh {
                    projects[pi].sessions[si].agentActivity = fresh
                }

                let scheduledMarkerURL = agentActivityDirectory
                    .appendingPathComponent("\(sessionId).scheduled-turn")
                let scheduledMarker = fm.fileExists(atPath: scheduledMarkerURL.path)
                if fresh?.scheduledTurnActive == false {
                    scheduledSnapshotsSuppressed.remove(sessionId)
                }
                let snapshotScheduled = fresh?.scheduledTurnActive == true
                    && !scheduledSnapshotsSuppressed.contains(sessionId)
                let scheduledActive = scheduledMarker || snapshotScheduled
                if projects[pi].sessions[si].scheduledTurnActive != scheduledActive {
                    projects[pi].sessions[si].scheduledTurnActive = scheduledActive
                }

            }
        }
        // Drop cache entries for sessions no longer present so the cache can't grow
        // across a long-lived app run that opens and closes many sessions. Filtering
        // ~30 entries is microsecond-cheap, so run it unconditionally — a count-based
        // guard misses the case where one session is closed while another (whose file
        // isn't written yet) is opened, leaving the count unchanged but a stale entry.
        agentActivitySnapshotCache = agentActivitySnapshotCache
            .filter { seenSessionIds.contains($0.key) }
    }

    /// Load a session's agent-activity snapshot, skipping the `Data(contentsOf:)`
    /// read + JSON decode when the file's signature (inode+size+mtime) matches the
    /// cached one — the common case, since only 1–2 of N session files change per
    /// scan. The caller re-applies the freshness TTL, so skipping the read never
    /// stalls a stale→nil transition. Kept synchronous on the main actor so scans
    /// stay serialized and single-writer — no races against `setStatus` or the
    /// reconcilers that also mutate/read this state on main.
    private func loadAgentActivitySnapshot(
        sessionId: String,
        path: String,
        decoder: JSONDecoder,
        fm: FileManager
    ) -> AgentActivitySnapshot? {
        let cached = agentActivitySnapshotCache[sessionId]
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            if cached != nil { agentActivitySnapshotCache.removeValue(forKey: sessionId) }
            return nil
        }
        let signature = FileSignature(attributes: attributes)
        if let cached, cached.signature == signature {
            return cached.snapshot
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // The file exists but the read failed (a transient `open()` denial or a
            // racing writer). Fail closed and DON'T advance the cached signature: the
            // signature mismatch guarantees a retry next scan, so this neither sticks
            // a `nil` against a live signature nor serves a stale snapshot to
            // freshness/promptability decisions in the meantime.
            return nil
        }
        // A present-but-malformed file caches `(signature, nil)` so it isn't
        // re-decoded every scan — only its next real change (new signature) re-reads.
        let snapshot = try? decoder.decode(AgentActivitySnapshot.self, from: data)
        agentActivitySnapshotCache[sessionId] = (signature, snapshot)
        return snapshot
    }

    /// Decide whether a `.running` session should be demoted to idle because its
    /// extension's RPC connection is gone. Pure and side-effect-free so it can be
    /// unit-tested without the reconciler's controller/timer machinery. Returns the
    /// evidence timestamp (ms) to seed the status clock, or nil when no demotion is
    /// warranted. Conditions: the session is `.running`; the terminal footer is
    /// idle (a disconnect proves RPC loss, not turn completion — the footer is the
    /// authoritative foreground signal, so a genuinely-working session is never
    /// demoted); the snapshot is fresh and reports a terminal disconnect (healthy
    /// sessions have `error == nil` and never qualify); and the snapshot's evidence
    /// time is within `[clockMs, nowMs]` so a newer status hook can't be overridden
    /// and a future-dated snapshot (clock rollback) can't poison the clock.
    nonisolated static func disconnectDemotionEvidenceMs(
        status: SessionStatus,
        footerActivity: FooterActivity,
        snapshot: AgentActivitySnapshot?,
        now: Date,
        nowMs: Int64,
        clockMs: Int64
    ) -> Int64? {
        guard status == .running,
              footerActivity == .idle,
              let snapshot,
              snapshot.isFresh(at: now),
              snapshot.reportsTerminalDisconnect,
              let evidenceMs = snapshot.updatedAtMilliseconds,
              evidenceMs <= nowMs,
              evidenceMs >= clockMs else { return nil }
        return evidenceMs
    }

    /// Backstop for cancelled turns. An Esc-cancel fires no stop hook and leaves the
    /// agent alive, so neither the stop hook nor `reconcileLiveness` clears the tab
    /// spinner — but the agent's own footer returns to its idle signature. Clear a
    /// stale running/waiting status once the footer has read idle for a couple of
    /// consecutive scans, but ONLY after we've actually observed the footer go
    /// `working` in this epoch. That guard means footer lag right after the hook
    /// flips us to running, an old idle footer scrolled into view, or a confirmation
    /// prompt (which reads as `working`) can never clear a genuinely-active session.
    /// Includes `waiting`, so an Esc-cancel of an ask_user/permission wait — which
    /// also fires no stop hook — is caught too.
    private func reconcileAgentFooters() {
        var tracked: Set<String> = []
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let status = projects[pi].sessions[si].status
                let sid = projects[pi].sessions[si].id
                guard let controller = controllers[sid] else { continue }
                let activity = controller.agentActivity
                let supportsSessionIdleHook = FileManager.default.fileExists(
                    atPath: Paths.sessionIdleHookMarkerPath(sessionId: sid)
                )
                // Self-recovery for the snapshot-driven demotion below: if the
                // foreground turn has resumed (a fresh `assistant.turn_start` flipped
                // `foregroundTurnActive` back to true), restore `.running`. This
                // reverses a demotion that fired during an unusually long
                // inter-iteration gap, so the fix no longer depends on that gap being
                // shorter than the two-scan dwell window. `foregroundTurnActive` is set
                // true ONLY at the root's `assistant.turn_start` and cleared at
                // `turn_end`/`session.idle`, so the freshest snapshot reporting it true
                // means the root is genuinely mid-turn ⇒ running (this holds regardless
                // of subagent count, which is why there's no `activeSubagents` gate here
                // — a subagent finishing between demotion and the foreground resuming
                // must not strand the tab as idle). A genuinely-finished session can't
                // trip this: `session.idle`/`turn_end` leave `foregroundTurnActive ==
                // false`, and the clock guard rejects a stale snapshot at or before the
                // latest status hook. Reject a future-dated snapshot (clock rollback)
                // too. Run this BEFORE the completion check so a session that's about to
                // be promoted back to running never fires a spurious completion.
                if status == .idle {
                    let recoveryNowMs = SessionArtifacts.currentStatusTimestamp()
                    if let snapshot = projects[pi].sessions[si].agentActivity,
                       snapshot.isFresh(),
                       snapshot.foregroundTurnActive == true,
                       !snapshot.reportsTerminalDisconnect,
                       let snapshotMs = snapshot.foregroundTransitionMilliseconds,
                       snapshotMs <= recoveryNowMs,
                       snapshotMs > (statusEventClock.timestamp(for: sid) ?? Int64.min) {
                        activityTracker.resetForegroundIdle(sessionId: sid)
                        activityTracker.resetDisconnectIdle(sessionId: sid)
                        // Promote IN MEMORY ONLY, using the foreground-transition
                        // timestamp (the root turn_start time — NOT `updatedAt`,
                        // which unrelated republishes rewrite): `setStatus` advances
                        // the clock via `shouldApply` to `snapshotMs` so a genuinely
                        // newer idle/waiting hook is still accepted, and — because a
                        // timestamp is supplied —
                        // it does NOT persist to disk. We deliberately don't persist
                        // here either: recovery compensates for a MISSING running hook,
                        // so no hook wrote `running` to disk; writing it ourselves could
                        // clobber a newer hook-written `idle` whose IPC is merely delayed
                        // behind reconciliation, and a later timestamped idle IPC would
                        // repair memory but not disk — leaving a stale `running` that
                        // survives restart (the very bug this fixes). Leaving the disk
                        // status to the hooks keeps recovery's only failure mode benign
                        // and self-healing (disk reads `idle` for a running session →
                        // footer promotion re-corrects within ~2s), never stuck-running.
                        setStatus(
                            sessionId: sid,
                            status: .running,
                            text: nil,
                            timestamp: snapshotMs,
                            source: "background-recovery"
                        )
                        continue
                    }
                }
                if status == .idle, activity == .idle {
                    postCompletionIfReady(sessionId: sid)
                }
                if status == .idle {
                    activityTracker.resetDisconnectIdle(sessionId: sid)
                    guard ActivityTracker.canPromoteIdleFromFooter(
                        backgroundAgentsActive: projects[pi].sessions[si].hasBackgroundWork,
                        hasLiveAgent: liveAgentSessions.contains(sid),
                        supportsSessionIdleHook: supportsSessionIdleHook
                    ) else {
                        activityTracker.reset(sessionId: sid)
                        continue
                    }
                    tracked.insert(sid)
                    if activityTracker.shouldPromoteFromFooter(
                        sessionId: sid,
                        currentStatus: status,
                        activity: activity
                    ) {
                        setStatus(
                            sessionId: sid,
                            status: .running,
                            text: nil,
                            source: "footer"
                        )
                    }
                    continue
                }
                // Disconnected-extension recovery: a fresh snapshot reporting a
                // terminal RPC disconnect can no longer observe
                // `turn_end`/`session.idle`, so its stuck `foregroundTurnActive`
                // would otherwise keep the tab "working" forever (the 5s heartbeat
                // republishes it fresh, defeating the isFresh TTL). Demote to idle
                // once the disconnect persists across two scans — but ONLY when the
                // terminal footer is idle (a disconnect proves RPC loss, not turn
                // completion; the footer is the authoritative foreground signal, so
                // a genuinely-working session is never demoted). Scoped to
                // `reportsTerminalDisconnect`, so a healthy session (error == nil)
                // never enters here. The evidence timestamp orders the demotion
                // against the status clock so a reconnect turn_start isn't dropped.
                if let evidenceMs = Self.disconnectDemotionEvidenceMs(
                    status: status,
                    footerActivity: activity,
                    snapshot: projects[pi].sessions[si].agentActivity,
                    now: Date(),
                    nowMs: SessionArtifacts.currentStatusTimestamp(),
                    clockMs: statusEventClock.timestamp(for: sid) ?? Int64.min
                ) {
                    tracked.insert(sid)
                    activityTracker.resetForegroundIdle(sessionId: sid)
                    if activityTracker.observeDisconnectIdle(
                        sessionId: sid,
                        currentStatus: status
                    ) {
                        clearStatusToIdle(pi: pi, si: si, markFinished: false, effectiveTime: evidenceMs)
                    }
                    continue
                } else {
                    activityTracker.resetDisconnectIdle(sessionId: sid)
                }
                // Stale "working" recovery: the foreground turn has ended, but
                // scheduled, subagent, or CLI background-agent work keeps
                // `session.idle` from firing, so the hook path below (guarded by
                // `supportsSessionIdleHook`) never demotes the tab and it reads
                // "working" while the terminal is actually idle and interactive.
                // Scope this strictly to fresh background-only evidence so ordinary
                // sessions keep falling through. Demote to idle
                // once the ended-turn condition persists across two scans (a normal
                // inter-iteration gap flips `foregroundTurnActive` false only briefly:
                // `turn_end` fires per loop iteration and tool calls run *inside* a
                // turn, so foreground stays active through them). Leave scheduled,
                // subagent, and background-agent state intact so the background
                // indicator persists.
                // The clock-ordering guard rejects a snapshot that predates the latest
                // status hook, so a just-submitted prompt (whose running hook advanced
                // the clock before its own fresh snapshot lands) can't be demoted; and
                // seeding the clock from the foreground-transition timestamp (the
                // turn_end time) — not `updatedAt` (which unrelated republishes bump)
                // and not `now` — keeps a subsequent user-prompt hook from being
                // swallowed. A future-dated transition (system-clock rollback) is
                // rejected outright so it can't drive a demotion or poison the clock.
                let backgroundNow = Date()
                let backgroundNowMs = SessionArtifacts.currentStatusTimestamp()
                if status == .running,
                   let snapshotMs = Self.backgroundOnlyEvidenceMs(
                       snapshot: projects[pi].sessions[si].agentActivity,
                       backgroundAgentsActive: projects[pi].sessions[si].backgroundAgentsActive,
                       now: backgroundNow,
                       nowMs: backgroundNowMs
                   ),
                   snapshotMs >= (statusEventClock.timestamp(for: sid) ?? snapshotMs) {
                    tracked.insert(sid)
                    if activityTracker.observeForegroundIdle(
                        sessionId: sid,
                        currentStatus: status,
                        foregroundTurnActive: false
                    ) {
                        clearStatusToIdle(
                            pi: pi,
                            si: si,
                            markFinished: false,
                            effectiveTime: snapshotMs
                        )
                        // Don't post completion here: background work is still active.
                        // Its final stop/session-idle signal owns completion.
                    }
                    continue
                } else {
                    activityTracker.resetForegroundIdle(sessionId: sid)
                }
                if supportsSessionIdleHook {
                    activityTracker.reset(sessionId: sid)
                    continue
                }
                tracked.insert(sid)
                if activityTracker.observeFooter(
                    sessionId: sid,
                    currentStatus: status,
                    activity: activity
                ) {
                    clearStatusToIdle(pi: pi, si: si, markFinished: true)
                    postCompletionIfReady(sessionId: sid)
                }
            }
        }
        activityTracker.retain(activeSessionIds: tracked)
    }

    /// Drop a session to idle and (unless it's on screen) flag it finished & unseen,
    /// then persist the corrected status. Shared by the liveness and footer reconcilers.
    private func clearStatusToIdle(pi: Int, si: Int, markFinished: Bool, effectiveTime: Int64? = nil) {
        let sid = projects[pi].sessions[si].id
        activityTracker.reset(sessionId: sid)
        projects[pi].sessions[si].status = .idle
        projects[pi].sessions[si].statusText = nil
        if markFinished, !isVisible(projectIndex: pi, sessionIndex: si) {
            projects[pi].sessions[si].finishedUnseen = true
        }
        // Seed the clock from the evidence that triggered the demotion, not `now`.
        // For a snapshot-driven demotion `effectiveTime` is the snapshot's own
        // timestamp; advancing the clock to `now` would let it swallow a fresh
        // user-prompt running hook whose timestamp is slightly earlier than `now`,
        // freezing the tab in idle. Clamp to `now` so a future-dated snapshot (e.g.
        // after a system-clock rollback) can't poison the clock and reject later
        // legitimate hooks. Liveness/footer callers pass nil and keep the prior
        // `now`-based behavior.
        let now = SessionArtifacts.currentStatusTimestamp()
        let base = min(effectiveTime ?? now, now)
        let timestamp = max(base, statusEventClock.timestamp(for: sid) ?? base)
        statusEventClock.seed(sessionId: sid, timestamp: timestamp)
        promptStatusEventClock.seed(sessionId: sid, timestamp: timestamp)
        SessionArtifacts.persistStatus(
            sessionId: sid,
            status: .idle,
            timestamp: timestamp,
            promptStatusTimestamp: timestamp
        )
    }

    private func reconcileLiveness(markFinished: Bool = true) {
        let snapshot = ProcessTree.snapshot()
        // Sessions whose shell currently hosts a live agent (copilot) process.
        // Also used by scroll-forwarding: a resumed session's terminal is desynced
        // (SwiftTerm restarted in the normal buffer, copilot never re-emits its
        // mouse mode), but copilot's input parser still expects mouse events — so
        // the wheel is force-forwarded as mouse when the session has a live agent.
        liveAgentSessions = ProcessTree.agentSessions(agentNames: agentProcessNames, in: snapshot)

        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let sid = projects[pi].sessions[si].id
                if projects[pi].sessions[si].backgroundAgentsActive,
                   !liveAgentSessions.contains(sid) {
                    setBackgroundAgentsActive(sessionId: sid, active: false)
                    backgroundAgentsSuppressed.insert(sid)
                }
            }
        }

        let hasActive = projects.contains { project in
            project.sessions.contains { $0.status == .running || $0.status == .waiting }
        }
        guard hasActive else { return }

        let liveSessions = liveAgentSessions
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let status = projects[pi].sessions[si].status
                guard status == .running || status == .waiting else { continue }
                if ActivityTracker.livenessShouldDemote(
                    currentStatus: status,
                    hasLiveAgent: liveSessions.contains(projects[pi].sessions[si].id)
                ) {
                    // The agent exited/crashed (active → idle). Flag it as finished &
                    // unseen unless you're looking at it right now.
                    clearStatusToIdle(pi: pi, si: si, markFinished: markFinished)
                }
            }
        }
    }

    func postNotification(
        projectId: String,
        sessionId: String,
        kind: StatusNotificationKind? = nil,
        title: String,
        body: String?
    ) {
        var subtitle: String?
        var isTargetVisible = false
        if let loc = locateIndex(sessionId) {
            isTargetVisible = projects[loc.p].id == projectId
                && isVisible(projectIndex: loc.p, sessionIndex: loc.s)
            if !isTargetVisible {
                projects[loc.p].sessions[loc.s].hasUnread = true
            }
            subtitle = Self.notificationSubtitle(
                projectName: projects[loc.p].name,
                sessionTitle: projects[loc.p].sessions[loc.s].title
            )
        }
        notifications?.post(NotificationEvent(
            kind: kind,
            title: title,
            subtitle: subtitle,
            body: body,
            projectId: projectId,
            sessionId: sessionId,
            isTargetVisible: isTargetVisible
        ))
        updateDockBadge()
    }

    private func postCompletionIfReady(sessionId: String) {
        guard completionPending.contains(sessionId) else { return }
        guard let loc = locateIndex(sessionId) else {
            completionPending.remove(sessionId)
            return
        }
        let snapshotActivity = projects[loc.p].sessions[loc.s].agentActivity
        let baseline = foregroundIdleGenerationBaselines[sessionId]
        let scheduledIdleIsCurrent = snapshotActivity?.lastIdleTurnKind == "scheduled"
            && (baseline == nil || (snapshotActivity?.idleGeneration ?? -1) > baseline!)
        if projects[loc.p].sessions[loc.s].scheduledTurnActive || scheduledIdleIsCurrent
        {
            completionPending.remove(sessionId)
            projects[loc.p].sessions[loc.s].turnCompleted = true
            foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)
            return
        }
        let activity = controllers[sessionId]?.agentActivity
        guard Self.canPostCompletion(
            status: projects[loc.p].sessions[loc.s].status,
            activity: activity
        ) else { return }
        guard !projects[loc.p].sessions[loc.s].hasBackgroundWork else { return }
        completionPending.remove(sessionId)

        guard !projects[loc.p].sessions[loc.s].turnCompleted else { return }
        projects[loc.p].sessions[loc.s].turnCompleted = true
        foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)

        guard !isVisible(projectIndex: loc.p, sessionIndex: loc.s) else { return }
        // Light the finished-and-unseen dot here too. When a session was already
        // demoted to idle early (stale-working recovery, while background subagents
        // were still running), the final agent-stop/session-idle arrives with
        // `previous == .idle`, so the active→idle edge in `setStatus` won't set this.
        // Setting it at the completion chokepoint keeps the sidebar/tab dot in parity
        // for both the direct-finish and the pre-demoted paths.
        projects[loc.p].sessions[loc.s].finishedUnseen = true
        postNotification(
            projectId: projects[loc.p].id,
            sessionId: sessionId,
            kind: .completed,
            title: StatusNotificationKind.completed.title,
            body: nil
        )
    }

    func setBackgroundAgentsActive(sessionId: String, active: Bool) {
        guard let loc = locateIndex(sessionId) else { return }
        guard projects[loc.p].sessions[loc.s].backgroundAgentsActive != active else { return }
        projects[loc.p].sessions[loc.s].backgroundAgentsActive = active
        SessionArtifacts.setBackgroundAgentsActive(sessionId: sessionId, active: active)
        if !active {
            postCompletionIfReady(sessionId: sessionId)
        }
    }

    nonisolated static func notificationSubtitle(
        projectName: String,
        sessionTitle: String
    ) -> String {
        "\(projectName) · \(sessionTitle)"
    }

    nonisolated static func isSessionVisible(
        appIsActive: Bool,
        selectedProjectId: String?,
        projectId: String,
        selectedSessionId: String?,
        sessionId: String
    ) -> Bool {
        appIsActive
            && selectedProjectId == projectId
            && selectedSessionId == sessionId
    }

    nonisolated static func canPostCompletion(
        status: SessionStatus,
        activity: FooterActivity?
    ) -> Bool {
        // Footer scraping is advisory: only affirmative working evidence blocks an
        // otherwise-authoritative idle hook. Unknown/unattached footers must not
        // strand completion forever.
        status == .idle && activity != .working
    }

    nonisolated static func shouldClearPendingCompletion(
        status: SessionStatus,
        source: String?
    ) -> Bool {
        (status == .running || status == .waiting) && source != "footer"
    }

    func focus(projectId: String?, sessionId: String?) {
        if let sessionId, let loc = locateIndex(sessionId) {
            selectedProjectId = projects[loc.p].id
            projects[loc.p].selectedSessionId = sessionId
            projects[loc.p].sessions[loc.s].hasUnread = false
            projects[loc.p].sessions[loc.s].finishedUnseen = false
        } else if let projectId, let pi = projectIndex(projectId) {
            selectedProjectId = projectId
            for i in projects[pi].sessions.indices {
                projects[pi].sessions[i].hasUnread = false
            }
            if let sid = projects[pi].selectedSessionId,
               let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) {
                projects[pi].sessions[si].finishedUnseen = false
            }
        }
        if let sid = currentSelectedSessionId { controller(for: sid) }
        refreshSelectedTranscriptController()
        updateDockBadge()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Mark a session read on behalf of a remote client that is now viewing it (iOS
    /// session screen on-screen). Clears the same flags local focus does — `hasUnread`
    /// (mirrored to remotes as `unread`) and the Mac-local `finishedUnseen` dot — so a
    /// read on the phone clears the indicator everywhere via the workspace-snapshot diff.
    /// Unlike `focus`, it does NOT change the Mac's selection or activate the app: a
    /// phone read must not yank the desktop UI. `hasUnread`/`finishedUnseen` are
    /// transient (not persisted), so there's nothing to `save()`.
    func markSessionRead(sessionId: String) {
        guard let loc = locateIndex(sessionId) else { return }
        guard projects[loc.p].sessions[loc.s].hasUnread
            || projects[loc.p].sessions[loc.s].finishedUnseen else { return }
        projects[loc.p].sessions[loc.s].hasUnread = false
        projects[loc.p].sessions[loc.s].finishedUnseen = false
        updateDockBadge()
    }

    /// Clear the on-screen session's "finished" flag when the app is brought forward
    /// (you're now looking at it). Other tabs keep their flag until you switch to them.
    func markActiveSessionSeen() {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              let sid = projects[pi].selectedSessionId,
              let si = projects[pi].sessions.firstIndex(where: { $0.id == sid }) else { return }
        if projects[pi].sessions[si].finishedUnseen {
            projects[pi].sessions[si].finishedUnseen = false
        }
    }

    /// Make the visible session's terminal the first responder. Used when the app
    /// is activated (clicked / ⌘-Tab'd back) so focus lands on the terminal rather
    /// than the sidebar project list.
    func focusActiveTerminal() {
        guard let view = activeController?.terminalView, let window = view.window else { return }
        window.makeFirstResponder(view)
    }

    func redrawActiveTerminal() {
        guard let view = activeController?.terminalView else { return }
        view.forceRedraw()
        DispatchQueue.main.async { [weak self] in
            self?.focusActiveTerminal()
        }
    }

    private func updateDockBadge() {
        let count = projects.reduce(0) { acc, p in
            acc + p.sessions.filter { $0.hasUnread }.count
        }
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: - terminal callbacks

    private func updateTitle(sessionId: String, title: String) {
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

    private func updateCwd(sessionId: String, dir: String?) {
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

        guard let loc = locateIndex(sessionId) else { return }
        projects[loc.p].sessions[loc.s].backgroundAgentsActive = false
        backgroundAgentsSuppressed.remove(sessionId)
        let projectId = projects[loc.p].id
        _ = kittyImageDiskStore.tombstone(sessionId: sessionId)
        SessionArtifacts.removeFiles(sessionId: sessionId)
        closeSession(projectId: projectId, sessionId: sessionId)
    }

    nonisolated static func shouldPreserveSessionAfterTerminalExit(
        isTerminating: Bool,
        isPoweringOff: Bool
    ) -> Bool {
        isTerminating || isPoweringOff
    }

    nonisolated static func shouldResumeWithAllowAll(
        copilotSessionId: String?,
        allowAllSessionId: String?
    ) -> Bool {
        guard let copilotSessionId, !copilotSessionId.isEmpty else { return false }
        return allowAllSessionId == copilotSessionId
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

    /// Collects main-thread window metadata; capture and file I/O run on the
    /// control-server thread so ScreenCaptureKit never blocks UI interaction.
    private func prepareScreenshot(to path: String) -> ScreenshotPreparation {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
                ?? NSApp.mainWindow ?? NSApp.windows.first,
              let view = window.contentView else {
            return .failure("no window to capture")
        }
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return .failure("window has no drawable bounds")
        }
        let scale = window.backingScaleFactor
        return .ready(ScreenshotCaptureRequest(
            windowID: CGWindowID(window.windowNumber),
            width: Int(bounds.width * scale),
            height: Int(bounds.height * scale),
            path: path
        ))
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

    private func renderStatus() -> String {
        var lines: [String] = []
        for p in projects {
            for s in p.sessions {
                let extra = s.statusText.map { " — \($0)" } ?? ""
                let unread = s.hasUnread ? " [unread]" : ""
                lines.append("\(p.name)/\(s.title)  \(s.status.rawValue)\(unread)\(extra)  \(s.id)")
            }
        }
        return lines.isEmpty ? "(no sessions)" : lines.joined(separator: "\n")
    }

    // MARK: - indexing

    private func projectIndex(_ id: String) -> Int? {
        projects.firstIndex { $0.id == id }
    }

    private func locateIndex(_ sessionId: String) -> (p: Int, s: Int)? {
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
        case .recovered(let recovered, let message):
            state = recovered
            stateRecoveryMessage = message
            NSLog("copilot-projects: \(message)")
        case .failed(let message):
            stateLoadFailure = message
            NSLog("copilot-projects: \(message)")
            return
        }
        projects = state.projects
        selectedProjectId = state.selectedProjectId ?? state.projects.first?.id
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let sid = projects[pi].sessions[si].id
                // Migrate any legacy `file://host/path` cwds (stored before OSC 7 was
                // normalized) to plain paths so inherited/new sessions don't chdir-fail to /.
                projects[pi].sessions[si].cwd = Paths.normalizedDirectory(projects[pi].sessions[si].cwd)
                let restored = restoredStatusState(forSession: sid)
                let status = restored.status
                let statusTimestamp = restored.statusTimestamp
                projects[pi].sessions[si].status = status
                statusEventClock.seed(
                    sessionId: sid,
                    timestamp: statusTimestamp
                )
                promptStatusEventClock.seed(
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
    }

    private func restoredStatusState(
        forSession sessionId: String
    ) -> (status: SessionStatus, statusTimestamp: Int64?, promptStatusTimestamp: Int64?) {
        switch SessionArtifacts.loadStatusRecord(sessionId: sessionId) {
        case .loaded(let record):
            return (record.status, record.statusTimestamp, record.promptStatusTimestamp)
        case .invalid:
            // A present but unreadable atomic record must never fall back to a possibly
            // torn set of legacy files. Restore busy and put the prompt clock at app
            // startup time, so only fresh post-recovery background evidence can bypass it.
            NSLog("copilot-projects: invalid status record for \(sessionId); restoring busy")
            return (.running, nil, SessionArtifacts.currentStatusTimestamp())
        case .missing:
            return (
                restoredLegacyStatus(forSession: sessionId),
                restoredLegacyStatusTimestamp(forSession: sessionId),
                restoredLegacyPromptStatusTimestamp(forSession: sessionId)
            )
        }
    }

    /// Restore pre-record app versions from their compatibility markers.
    private func restoredLegacyStatus(forSession sessionId: String) -> SessionStatus {
        let path = Paths.statusMarkerPath(sessionId: sessionId)
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let status = SessionStatus(rawValue: trimmed) { return status }
        }
        return .idle
    }

    private func restoredLegacyStatusTimestamp(forSession sessionId: String) -> Int64? {
        let path = Paths.statusTimestampMarkerPath(sessionId: sessionId)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func restoredLegacyPromptStatusTimestamp(forSession sessionId: String) -> Int64? {
        let path = Paths.promptStatusTimestampMarkerPath(sessionId: sessionId)
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func scheduleSave() {
        guard stateLoadFailure == nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func save() {
        guard stateLoadFailure == nil else { return }
        let state = PersistedState(projects: projects, selectedProjectId: selectedProjectId)
        do {
            try stateRepository.save(state)
        } catch {
            NSLog("copilot-projects: failed to save workspace state: \(error)")
        }
    }
}
