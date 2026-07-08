import SwiftUI
import AppKit
import ScreenCaptureKit
import CopilotProjectsCore

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

/// Single source of truth. Holds value-type projects/sessions (observed) and live
/// terminal controllers (NOT observed, kept out of the SwiftUI graph).
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var selectedProjectId: String?
    @Published var numberHint: NumberHint = .none

    private var controllers: [String: TerminalController] = [:]
    private let stateRepository: StateRepository
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
                source: request.source
            )
            return .success()
        },
        notify: { [unowned self] title, body, request in
            if let target = self.resolve(request) {
                self.postNotification(
                    projectId: target.projectId, sessionId: target.sessionId,
                    title: title, body: body)
            } else {
                self.notifications?.post(
                    title: title, body: body,
                    projectId: request.projectId, sessionId: request.sessionId)
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
        diagnostics: { [unowned self] in self.renderDiagnostics() }
    ))
    private var stateLoadFailure: String?
    private var stateRecoveryMessage: String?
    private var didPresentStateMessage = false
    private var server: ControlServer?
    private weak var notifications: NotificationManager?
    private var saveWork: DispatchWorkItem?
    private(set) var isTerminating = false

    private var livenessTimer: Timer?
    private var footerTimer: Timer?

    private var activityTracker = ActivityTracker()
    private var statusEventClock = StatusEventClock()
    private var backgroundAgentsSuppressed: Set<String> = []

    /// Sessions hosting a live agent (refreshed by the liveness reconciler). Used
    /// by scroll-wheel forwarding to keep working on resumed (desynced) sessions.
    private(set) var liveAgentSessions: Set<String> = []

    /// Process names treated as a live coding agent for the liveness backstop.
    /// Override with COPILOT_PROJECTS_AGENT_PROCESSES (comma-separated); disable the
    /// whole check with COPILOT_PROJECTS_LIVENESS=0.
    private var agentProcessNames: Set<String> {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["COPILOT_PROJECTS_AGENT_PROCESSES"] ?? env["COPILOT_MUX_AGENT_PROCESSES"],
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
        return (env["COPILOT_PROJECTS_LIVENESS"] ?? env["COPILOT_MUX_LIVENESS"]) != "0"
    }

    init(stateRepository: StateRepository = StateRepository()) {
        self.stateRepository = stateRepository
        load()
    }

    // MARK: - lifecycle wiring

    func attach(notifications: NotificationManager) {
        self.notifications = notifications
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

        // Retire the pre-rebrand `copilot-mux` alias: the hook resolves
        // copilot-projects first, so it's dead weight. Only remove it when it's a
        // symlink we created (points at a Copilot Projects executable), never a real
        // file the user may have placed there.
        let legacy = dir.appendingPathComponent("copilot-mux")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: legacy.path),
           dest.hasSuffix("/copilot-projects") || dest.hasSuffix("/copilot-mux") {
            try? fm.removeItem(at: legacy)
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

    /// Returns (creating if needed) the live terminal for a session.
    @discardableResult
    func controller(for sessionId: String) -> TerminalController? {
        if let c = controllers[sessionId] { return c }
        guard let loc = locateIndex(sessionId) else { return nil }
        let project = projects[loc.p]
        let session = project.sessions[loc.s]
        Paths.ensureStateDir()
        let dtach = Paths.dtachExecutable
        let socket = dtach != nil ? Paths.dtachSocketPath(sessionId: sessionId) : nil
        // Last Copilot session id seen in this tab (written by the hook). If the
        // shell is created fresh after a reboot, the controller resumes this exact
        // agent session; on a normal relaunch dtach reattaches and ignores it.
        let recordedCopilot = (try? String(contentsOfFile:
            Paths.copilotSessionMarkerPath(sessionId: sessionId), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let c = TerminalController(
            sessionId: sessionId,
            cwd: session.cwd,
            extraEnvironment: environment(projectId: project.id, sessionId: sessionId),
            dtachExecutable: dtach,
            dtachSocket: socket,
            copilotSessionId: (recordedCopilot?.isEmpty == false) ? recordedCopilot : nil
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
        save()
        return session.id
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
        statusEventClock.reset(sessionId: sid)
        backgroundAgentsSuppressed.remove(sid)
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
        updateDockBadge()
        save()
    }

    func closeSelectedSession() {
        guard let pid = selectedProjectId, let pi = projectIndex(pid),
              let sid = projects[pi].selectedSessionId else { return }
        requestCloseSession(projectId: pid, sessionId: sid)
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
        SessionArtifacts.destroy(sessionId: sid)
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

    func beginTermination() {
        isTerminating = true
        footerTimer?.invalidate()
        livenessTimer?.invalidate()
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
    var totalBackgroundAgents: Int {
        projects.reduce(0) { $0 + $1.backgroundAgentCount }
    }
    var totalReady: Int {
        projects.reduce(0) { $0 + $1.sessions.filter { $0.finishedUnseen }.count }
    }

    func closeProject(_ pid: String) {
        guard let pi = projectIndex(pid) else { return }
        let snapshot = Paths.dtachExecutable != nil ? ProcessTree.snapshot() : nil
        for session in projects[pi].sessions {
            SessionArtifacts.destroy(sessionId: session.id, snapshot: snapshot)
            controllers[session.id]?.terminate()
            controllers[session.id] = nil
            backgroundAgentsSuppressed.remove(session.id)
        }
        projects.remove(at: pi)
        if selectedProjectId == pid {
            selectedProjectId = projects.first?.id
            if let sid = currentSelectedSessionId { controller(for: sid) }
        }
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
    func moveSession(toProjectId targetPid: String, draggedId sid: String) -> Bool {
        guard let tpi = projectIndex(targetPid), let from = locateIndex(sid),
              projects[from.p].id != targetPid else { return false }

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
        projects[tpi].selectedSessionId = session.id
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

    // MARK: - status / notifications (driven by the CLI)

    func setStatus(
        sessionId: String,
        status: SessionStatus,
        text: String?,
        timestamp: Int64? = nil,
        source: String? = nil
    ) {
        guard let loc = locateIndex(sessionId) else { return }
        guard statusEventClock.shouldApply(sessionId: sessionId, timestamp: timestamp) else { return }
        let previous = projects[loc.p].sessions[loc.s].status
        let clearsBackgroundAgents = status == .idle && source == "session-idle"
        let resumesBackgroundTracking = (status == .running || status == .waiting)
            && backgroundAgentsSuppressed.contains(sessionId)
        guard previous != status
                || projects[loc.p].sessions[loc.s].statusText != text
                || clearsBackgroundAgents
                || resumesBackgroundTracking
        else { return }
        projects[loc.p].sessions[loc.s].status = status
        projects[loc.p].sessions[loc.s].statusText = text
        if status == .running || status == .waiting {
            backgroundAgentsSuppressed.remove(sessionId)
        }
        if timestamp == nil {
            let now = SessionArtifacts.currentStatusTimestamp()
            let effectiveTimestamp = max(now, statusEventClock.timestamp(for: sessionId) ?? now)
            statusEventClock.seed(sessionId: sessionId, timestamp: effectiveTimestamp)
            SessionArtifacts.persistStatus(
                sessionId: sessionId,
                status: status,
                timestamp: effectiveTimestamp
            )
        }
        if status == .idle {
            activityTracker.reset(sessionId: sessionId)
            if source == "session-idle" {
                projects[loc.p].sessions[loc.s].backgroundAgentsActive = false
                backgroundAgentsSuppressed.insert(sessionId)
                SessionArtifacts.setBackgroundAgentsActive(
                    sessionId: sessionId,
                    active: false
                )
            }
        }
        // The agent just went active → idle. If you're not currently looking at this
        // session, flag it as finished-and-unseen (drives the blue sidebar/tab dot).
        if status == .idle, previous == .running || previous == .waiting,
           !isVisible(projectIndex: loc.p, sessionIndex: loc.s) {
            projects[loc.p].sessions[loc.s].finishedUnseen = true
        }
    }

    /// Whether a session is the one on screen right now (app active + its project and
    /// tab selected). Used to decide if a just-finished session needs an attention dot.
    private func isVisible(projectIndex pi: Int, sessionIndex si: Int) -> Bool {
        NSApp.isActive
            && selectedProjectId == projects[pi].id
            && projects[pi].selectedSessionId == projects[pi].sessions[si].id
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
                if status == .idle {
                    guard liveAgentSessions.contains(sid) else {
                        activityTracker.reset(sessionId: sid)
                        continue
                    }
                    tracked.insert(sid)
                    if activityTracker.shouldPromoteFromFooter(
                        sessionId: sid,
                        currentStatus: status,
                        activity: controller.agentActivity
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
                if FileManager.default.fileExists(
                    atPath: Paths.sessionIdleHookMarkerPath(sessionId: sid)
                ) {
                    activityTracker.reset(sessionId: sid)
                    continue
                }
                tracked.insert(sid)
                if activityTracker.observeFooter(
                    sessionId: sid,
                    currentStatus: status,
                    activity: controller.agentActivity
                ) {
                    clearStatusToIdle(pi: pi, si: si, markFinished: true)
                }
            }
        }
        activityTracker.retain(activeSessionIds: tracked)
    }

    /// Drop a session to idle and (unless it's on screen) flag it finished & unseen,
    /// then persist the corrected status. Shared by the liveness and footer reconcilers.
    private func clearStatusToIdle(pi: Int, si: Int, markFinished: Bool) {
        let sid = projects[pi].sessions[si].id
        activityTracker.reset(sessionId: sid)
        projects[pi].sessions[si].status = .idle
        projects[pi].sessions[si].statusText = nil
        if markFinished, !isVisible(projectIndex: pi, sessionIndex: si) {
            projects[pi].sessions[si].finishedUnseen = true
        }
        let now = SessionArtifacts.currentStatusTimestamp()
        let timestamp = max(now, statusEventClock.timestamp(for: sid) ?? now)
        statusEventClock.seed(sessionId: sid, timestamp: timestamp)
        SessionArtifacts.persistStatus(
            sessionId: sid,
            status: .idle,
            timestamp: timestamp
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
                    projects[pi].sessions[si].backgroundAgentsActive = false
                    backgroundAgentsSuppressed.insert(sid)
                    SessionArtifacts.setBackgroundAgentsActive(
                        sessionId: sid,
                        active: false
                    )
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

    func postNotification(projectId: String, sessionId: String, title: String, body: String?) {
        if let loc = locateIndex(sessionId) {
            let visible = NSApp.isActive
                && selectedProjectId == projectId
                && projects[loc.p].selectedSessionId == sessionId
            if !visible {
                projects[loc.p].sessions[loc.s].hasUnread = true
            }
        }
        notifications?.post(title: title, body: body, projectId: projectId, sessionId: sessionId)
        updateDockBadge()
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
        updateDockBadge()
        NSApp.activate(ignoringOtherApps: true)
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
        if projects[loc.p].sessions[loc.s].backgroundAgentsActive != backgroundAgents {
            projects[loc.p].sessions[loc.s].backgroundAgentsActive = backgroundAgents
            SessionArtifacts.setBackgroundAgentsActive(
                sessionId: sessionId,
                active: backgroundAgents
            )
        }
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
        guard !isTerminating else { return }   // app quitting → keep for resume

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
        SessionArtifacts.removeFiles(sessionId: sessionId)
        closeSession(projectId: projectId, sessionId: sessionId)
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
                // Migrate any legacy `file://host/path` cwds (stored before OSC 7 was
                // normalized) to plain paths so inherited/new sessions don't chdir-fail to /.
                projects[pi].sessions[si].cwd = Paths.normalizedDirectory(projects[pi].sessions[si].cwd)
                projects[pi].sessions[si].status = restoredStatus(forSession: projects[pi].sessions[si].id)
                statusEventClock.seed(
                    sessionId: projects[pi].sessions[si].id,
                    timestamp: restoredStatusTimestamp(forSession: projects[pi].sessions[si].id)
                )
                projects[pi].sessions[si].statusText = nil
                projects[pi].sessions[si].hasUnread = false
                let sid = projects[pi].sessions[si].id
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

    /// Restore a session's status from its marker file (written by the Copilot
    /// hook). The liveness reconciler then clears any whose agent is no longer alive.
    private func restoredStatus(forSession sessionId: String) -> SessionStatus {
        let path = Paths.statusMarkerPath(sessionId: sessionId)
        if let raw = try? String(contentsOfFile: path, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if let status = SessionStatus(rawValue: trimmed) { return status }
        }
        return .idle
    }

    private func restoredStatusTimestamp(forSession sessionId: String) -> Int64? {
        let path = Paths.statusTimestampMarkerPath(sessionId: sessionId)
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
