import SwiftUI
import AppKit
import AVFoundation
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI

struct CopilotProjectsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(HostLifetimePolicy.settingKey) private var keepRunning = false
    @AppStorage(NotificationsAppLauncher.startsWithHostKey) private var startsNotifications = false
    @AppStorage(TranscriptPromptComposerView.showQuickReplyChipsKey) private var showQuickReplyChips = true
    @AppStorage(TranscriptDrawer.defaultViewKey) private var defaultView: TranscriptDrawer.DefaultView = .terminal
    @AppStorage(TranscriptDrawer.fullWidthTranscriptKey) private var fullWidthTranscript = false
    @AppStorage(SessionParking.settingKey) private var parkIdleSessions = SessionParking.off
    @State private var showsProjects = true
    @State private var showsQuickRepliesSettings = false

    var body: some Scene {
        Window("Copilot Projects", id: "main") {
            MainWindowContent(appDelegate: appDelegate, showsProjects: $showsProjects)
                .frame(minWidth: 820, minHeight: 520)
                .sheet(isPresented: $showsQuickRepliesSettings) {
                    QuickRepliesSettingsView(defaults: appDelegate.model.defaults) {
                        showsQuickRepliesSettings = false
                    }
                }
                .onDisappear {
                    showsQuickRepliesSettings = false
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            WorkspaceCommands(model: appDelegate.model, input: appDelegate.input,
                              menu: appDelegate.model.menuState,
                              keepRunning: $keepRunning, startsNotifications: $startsNotifications,
                              showQuickReplyChips: $showQuickReplyChips,
                              showsQuickRepliesSettings: $showsQuickRepliesSettings,
                              defaultView: $defaultView,
                              fullWidthTranscript: $fullWidthTranscript,
                              parkIdleSessions: $parkIdleSessions,
                              showsProjects: $showsProjects)
        }
        MenuBarExtra("Copilot Projects", systemImage: "terminal", isInserted: $keepRunning) {
            HostStatusMenu(keepRunning: $keepRunning)
        }
    }
}

/// Opens (or brings forward) Copilot Pull Requests.
struct OpenPullRequestsButton: View {
    var body: some View {
        Button("Pull Requests") { PullRequestsAppLauncher.open() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
    }
}

/// Narrow menu-bar state so active session publishes don't rebuild open submenus.
@MainActor
final class WorkspaceMenuState: ObservableObject {
    struct Snapshot: Equatable {
        var hasWorkspaceSheet = false
        var selectedSessionOffersMarkAsRead = false
        var hasAttentionSessions = false
        var canNavigateSessionBack = false
        var canNavigateSessionForward = false
        /// Set when the selected session is parked, or being parked or resumed.
        var selectedSessionParked: ParkedSession.State?
        /// Whether `/restart` can run in the selected session, judged when the menu bar opens.
        var selectedSessionCanRestart = false
        var recentlyClosedSessionItems: [RemoteRecentlyClosedSession] = []
        var autoDiscoverSSHHosts = true
        var manualSSHHosts: [RemoteHostInfo] = []
    }

    @Published private(set) var snapshot = Snapshot()
    var selectionUnreadKey: [String] = []

    var canReopenClosedSession: Bool { !snapshot.recentlyClosedSessionItems.isEmpty }

    func update(_ next: Snapshot) {
        guard snapshot != next else { return }
        snapshot = next
    }
}

struct SSHHostsSettingsMenu: View {
    let model: AppModel
    @ObservedObject private var menu: WorkspaceMenuState
    var isSheetPresented: Bool = false

    init(model: AppModel, isSheetPresented: Bool = false) {
        self.model = model
        self.menu = model.menuState
        self.isSheetPresented = isSheetPresented
    }

    var body: some View {
        Menu("SSH Hosts") {
            Toggle(
                "Auto-Discover from ~/.ssh/config",
                isOn: Binding(
                    get: { menu.snapshot.autoDiscoverSSHHosts },
                    set: { model.setAutoDiscoverSSHHosts($0) }
                )
            )
            Button("Add SSH Host…") {
                model.addManualSSHHostInteractive()
            }
            .disabled(isSheetPresented)
            if !menu.snapshot.manualSSHHosts.isEmpty {
                Divider()
                ForEach(menu.snapshot.manualSSHHosts) { host in
                    Button("Remove \(host.displayName) (\(host.sshTarget ?? host.id))") {
                        model.removeManualSSHHost(id: host.id)
                    }
                }
            }
        }
    }
}

private struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel
    let input: WorkspaceInputController
    @ObservedObject var menu: WorkspaceMenuState
    @Binding var keepRunning: Bool
    @Binding var startsNotifications: Bool
    @Binding var showQuickReplyChips: Bool
    @Binding var showsQuickRepliesSettings: Bool
    @Binding var defaultView: TranscriptDrawer.DefaultView
    @Binding var fullWidthTranscript: Bool
    @Binding var parkIdleSessions: String
    @Binding var showsProjects: Bool

    private var hasSheet: Bool {
        menu.snapshot.hasWorkspaceSheet || showsQuickRepliesSettings
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Project…") { model.addProjectInteractive() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(hasSheet)
        }
        CommandGroup(after: .appSettings) {
            Toggle("Keep Running When Window Closes", isOn: $keepRunning)
            Toggle("Start Notifications with Copilot Projects", isOn: $startsNotifications)
            Toggle("Show Quick-Reply Suggestions", isOn: $showQuickReplyChips)
            Button("Customize Quick Replies…") {
                guard !hasSheet, NSApp.modalWindow == nil else { return }
                openWindow(id: "main")
                model.setNumberHint(.none)
                showsQuickRepliesSettings = true
            }
            .disabled(hasSheet)
            Picker("Default View", selection: $defaultView) {
                Text("Terminal").tag(TranscriptDrawer.DefaultView.terminal)
                Text("Transcript").tag(TranscriptDrawer.DefaultView.transcript)
            }
            Toggle("Full-Width Transcript View", isOn: $fullWidthTranscript)
            Picker("Park Idle Sessions", selection: Binding(
                get: { parkIdleSessions },
                set: { choice in
                    // Leaving Off explains parking once, and can be cancelled.
                    guard choice == SessionParking.off || model.confirmParkingOptIn() else { return }
                    parkIdleSessions = choice
                }
            )) {
                Text("Off").tag(SessionParking.off)
                Text("Only When I Choose").tag(SessionParking.manual)
            }
            Divider()
            SSHHostsSettingsMenu(model: model, isSheetPresented: hasSheet)
            Button("Pull Request Review Prompt…") {
                model.configurePullRequestReviewPromptInteractive()
            }
            .disabled(hasSheet)
        }
        CommandGroup(after: .help) {
            Button("What's New") {
                openWindow(id: "main")
                input.presentReleaseNotes()
            }
            .disabled(hasSheet)
        }
        CommandGroup(before: .sidebar) {
            Toggle("Show Projects", isOn: $showsProjects)
                .keyboardShortcut("0", modifiers: .command)
                .disabled(hasSheet)
        }
        CommandGroup(before: .windowList) {
            OpenPullRequestsButton()
            OpenNotificationsButton()
            Divider()
        }
        CommandMenu("Session") {
            Group {
                Button("New Copilot Session") { model.addSessionToSelected() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Start with Prompt…") { model.addPromptedSessionToSelected() }
                Button("New Terminal") { model.addTerminalToSelected() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Divider()
                Button(menu.snapshot.selectedSessionOffersMarkAsRead ? "Mark as Read" : "Mark as Unread") {
                    model.toggleSelectedSessionRead()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Restart Session") { model.globalSelectedSessionId.map(model.restartSession) }
                    .disabled(!menu.snapshot.selectedSessionCanRestart)
                Button("End Session") { model.closeSelectedSession() }
                    .keyboardShortcut("w", modifiers: .command)
                Button("Reopen Closed Session") {
                    _ = model.reopenClosedSession()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!menu.canReopenClosedSession)
                Menu("Recently Closed Sessions") {
                    ForEach(menu.snapshot.recentlyClosedSessionItems) { item in
                        Button("\(item.title) — \(item.projectName)") {
                            _ = model.reopenClosedSession(id: item.id)
                        }
                    }
                }
                .disabled(!menu.canReopenClosedSession)
                // Parking is opt-in. Resume stays while a parked session exists,
                // so turning the setting off never strands one.
                if parkIdleSessions != SessionParking.off {
                    Button("Park Session") { _ = model.globalSelectedSession.map(model.requestParkSession) }
                        .disabled(menu.snapshot.selectedSessionParked != nil)
                    Button("Park All Idle Sessions…") { model.parkAllIdleSessions() }
                }
                if let parked = menu.snapshot.selectedSessionParked, parked == .parked || parked == .failed {
                    Button("Resume Session") {
                        model.globalSelectedSessionId.map(model.resumeParkedSession)
                    }
                }
                Divider()
                Button("Find Session…") { input.presentSessionFinder() }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Next Session Needing Attention") {
                    model.selectNextAttentionSession()
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!menu.snapshot.hasAttentionSessions)
                Divider()
                Button("Back") {
                    model.navigateSessionBack()
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!menu.snapshot.canNavigateSessionBack)
                Button("Forward") {
                    model.navigateSessionForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!menu.snapshot.canNavigateSessionForward)
                Button("Next Session") { model.selectAdjacentSession(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { model.selectAdjacentSession(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
            .disabled(hasSheet)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    let input: WorkspaceInputController
    private let nativeNotifications: NotificationManager
    private let integration: (any HostIntegration)?
    private let notifications: HostNotificationPoster
    private let instanceLock = AppInstanceLock()
    private var isPrimaryInstance = false
    private var eventMonitor: Any?
    private var hintWork: DispatchWorkItem?
    private var terminationDrainStarted = false

    override init() {
        let native = NotificationManager()
        let model = AppModel()
        let integration = HostIntegrationRegistry.factory(RemoteModelBridge(model: model))
        nativeNotifications = native
        self.integration = integration
        notifications = HostNotificationPoster(native: native, integration: integration)
        self.model = model
        input = WorkspaceInputController(model: model)
        model.attach(integration: integration)
        MarkdownSelectableTextView.defaultDeepLinkHandler = { [weak model] deepLink in
            guard let model else { return false }
            model.focus(projectId: deepLink.projectId, sessionId: deepLink.sessionId)
            return true
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false

        guard instanceLock.acquire() else {
            integration?.shutdown()
            focusExistingInstance()
            NSApp.terminate(nil)
            return
        }
        model.finishInterruptedSessionDestroys()
        model.activateKittyImagePersistence()

        nativeNotifications.onActivate = { [weak self] projectId, sessionId in
            self?.model.focus(projectId: projectId, sessionId: sessionId)
        }
        let integration = self.integration
        nativeNotifications.onResolve = { [weak integration] id in
            integration?.dismissNotification(id)
        }
        integration?.clearLocalNotification = { [weak self] id in
            self?.nativeNotifications.remove(id: id)
        }
        nativeNotifications.requestAuth()

        model.attach(notifications: notifications)
        guard model.startServer() else {
            focusExistingInstance()
            NSApp.terminate(nil)
            return
        }
        isPrimaryInstance = true
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceWillPowerOff(_:)),
            name: NSWorkspace.willPowerOffNotification,
            object: nil
        )
        model.bootstrapIfNeeded()
        model.startLivenessReconciler()
        model.startAgentActivityTracking()
        model.startIntegration()
        requestMicrophoneAccessIfNeeded()
        let env = ProcessInfo.processInfo.environment
        if Env.shouldInstallGlobalIntegration(env) {
            model.installCLISymlinkIfPossible()
            CopilotHooks.installIfPossible()
            CopilotExtension.installIfPossible()
        }
        registerDeepLinkHelper()
        NotificationsSummaryWatcher.shared.start()
        NotificationsAppLauncher.startInBackgroundIfWanted()

        NSApp.activate(ignoringOtherApps: true)

        // ⌘/⌃ + number navigation, the modifier-hold number overlay, double-click
        // title-bar zoom, link-vs-selection disambiguation, mouse Back/Forward,
        // and scroll-wheel forwarding into mouse-reporting TUIs.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .scrollWheel, .leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }

        // If focus leaves the app while a modifier is held (e.g. ⌘-Tab away), the
        // local monitor stops receiving the matching key-up, so the number overlay
        // would stay stuck. Clear it whenever we resign active.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hintWork?.cancel()
                self?.model.setNumberHint(.none)
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? NSMenu) === NSApp.mainMenu else { return }
                self.model.syncMenuState(reloadSSHHosts: true, includeRuntimeAttention: true)
            }
        }

        // When the app is activated (clicked / ⌘-Tab'd back), put keyboard focus
        // on the visible terminal instead of the sidebar list, unless a text view
        // in the open session details drawer already holds focus.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.markActiveSessionSeen()
                let drawerEditing = self.model.globalSelectedSessionId.map {
                    self.model.isTranscriptDrawerOpen(sessionId: $0)
                } == true && (NSApp.keyWindow?.firstResponder is NSTextView)
                let attachedSheet = NSApp.windows.contains {
                    $0.attachedSheet != nil || $0.sheetParent != nil
                }
                if !self.input.hasWorkspaceSheet && !attachedSheet && !drawerEditing {
                    self.model.focusActiveTerminal()
                }
            }
        }
    }

    private func registerDeepLinkHelper() {
        guard let helperURL = RunningExecutable.applicationBundle?.bundleURL
            .appendingPathComponent("Contents/Helpers/Copilot Projects Link.app"),
              FileManager.default.fileExists(atPath: helperURL.path) else {
            NSLog("copilot-projects: deep-link helper is missing")
            return
        }
        NSWorkspace.shared.setDefaultApplication(
            at: helperURL,
            toOpenURLsWithScheme: "copilot-projects"
        ) { error in
            if let error {
                NSLog("copilot-projects: could not register deep-link helper: \(error)")
            }
        }
    }

    private func focusExistingInstance() {
        // The control socket is scoped to this exact state directory, so it targets
        // the right instance even when an isolated dev/test instance with the same
        // bundle id is also running.
        let request = ControlRequest(command: "focus")
        if let response = try? ControlClient().send(request), response.ok { return }

        guard let bundleID = (RunningExecutable.applicationBundle ?? .main).bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if let existing = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != currentPID }) {
            existing.activate(options: [.activateAllWindows])
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        if event.type == .keyDown {
            return input.handleKeyDown(event) { hintWork?.cancel() }
        }
        guard input.allowsWorkspaceEvents(event) else {
            hintWork?.cancel()
            model.setNumberHint(.none)
            return event
        }
        switch event.type {
        case .scrollWheel:
            // Forward the wheel into the active terminal (mouse-reporting TUI,
            // alt-screen pager, or normal scrollback); otherwise pass it through.
            if let c = model.activeController,
               c.terminalView.containsPointer(for: event),
               c.terminalView.forwardScroll(event, agentLive: model.liveAgentSessions.contains(c.sessionId)) {
                return nil
            }
            return event
        case .flagsChanged:
            updateNumberHint(event.modifierFlags)
            return event
        case .rightMouseDown:
            // SwiftUI builds a context menu from the item views it last evaluated,
            // and evaluates one again only once the model has published. Without
            // this, a row's Restart Session was still disabled on a right-click
            // after its terminal went back to the idle footer, and still enabled
            // on a Control-click after it opened the slash picker: only the
            // footer had changed, which is not published.
            model.objectWillChange.send()
            return event
        case .leftMouseDown:
            // A Control-click opens the same menu.
            if event.modifierFlags.contains(.control) { model.objectWillChange.send() }
            // Double-click the top title strip (but not the traffic lights or interactive
            // FleetStatusBar pills) to run the user's title-bar double-click action;
            // .hiddenTitleBar + our SwiftUI strip otherwise swallows the native gesture.
            if event.clickCount == 2,
               let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               isInTitleStrip(event, window: window),
               !FleetStatusBarMarkerView.contains(event.locationInWindow, in: window.contentView) {
                performTitleBarDoubleClick(window)
                return nil
            }
            return event
        case .leftMouseUp:
            // SwiftTerm opens the link under the release point on its own mouseUp
            // (in `.hover`, explicit OSC 8 OR autodetected bare URL). Its mouse
            // methods are `public`, not `open`, so we steer from this monitor (which
            // runs first) by briefly flipping `linkHighlightMode` to
            // `.hoverWithModifier` — so SwiftTerm finds no link without ⌘ — then
            // restoring it.
            if let c = model.activeController, !event.modifierFlags.contains(.command) {
                let tv = c.terminalView
                let plainAgentClick = !tv.selectionActive
                    && model.liveAgentSessions.contains(c.sessionId)
                    && tv.containsPointer(for: event)
                if plainAgentClick {
                    // Live-agent TUI: forward the click so the CLI's own handler runs.
                    // The Copilot CLI opens links (markdown AND autolinked bare URLs)
                    // by tracking link rects and acting on the click — it emits no
                    // OSC 8 — so this is the only way they open.
                    tv.forwardClick(event)
                }
                if tv.selectionActive || plainAgentClick {
                    // Suppress SwiftTerm's own link-open:
                    //  • selection (drag / multi-click) → don't open a URL you're
                    //    selecting to copy.
                    //  • live-agent plain click → the CLI already opens it; without
                    //    this a bare URL would open twice (CLI + SwiftTerm).
                    tv.linkHighlightMode = .hoverWithModifier
                    DispatchQueue.main.async { tv.linkHighlightMode = .hover }
                }
            }
            return event
        case .otherMouseDown, .otherMouseUp:
            return input.handleOtherMouse(event)
        default:
            return event
        }
    }

    /// True when the pointer is in the top title strip (matching RootView's 38pt
    /// titleStripHeight), past the traffic lights. Measures from the window frame's
    /// top: under .hiddenTitleBar the contentView doesn't span the full frame, so
    /// converting through it mismeasures (yields a negative offset for top clicks).
    private func isInTitleStrip(_ event: NSEvent, window: NSWindow) -> Bool {
        let loc = event.locationInWindow
        let yFromTop = window.frame.height - loc.y
        return yFromTop >= 0 && yFromTop <= 38 && loc.x > 80
    }

    /// Mirror the system "double-click a window's title bar to" preference
    /// (System Settings ▸ Desktop & Dock); defaults to zoom when unset/unknown.
    private func performTitleBarDoubleClick(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }

    private func updateNumberHint(_ flags: NSEvent.ModifierFlags) {
        let mods = flags.intersection([.command, .control, .option, .shift])
        let target: NumberHint = mods == .command ? .projects : (mods == .control ? .tabs : .none)
        hintWork?.cancel()
        guard target != .none else {
            model.setNumberHint(.none)
            return
        }
        // Brief delay so quick combos (⌘C, ⌘T…) don't flash the overlay.
        let work = DispatchWorkItem { [weak self] in self?.model.setNumberHint(target) }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// Prompt for microphone access once, up front. Copilot sessions run as child
    /// processes of this app, so macOS attributes their mic TCC prompt to this
    /// responsible app; granting it here (rather than mid-session) means a session's
    /// voice input isn't silently denied before the app has ever been authorized.
    /// Only triggers the system prompt when the status is still undetermined.
    private func requestMicrophoneAccessIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard isPrimaryInstance else { return }
        model.beginTermination()
        model.forcePendingSessionDestroys()
        integration?.shutdown()
        model.detachAllClients()   // keep dtach masters alive for resume
        model.stopServer()
        model.save()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isPrimaryInstance else { return .terminateNow }
        guard !terminationDrainStarted else { return .terminateLater }
        terminationDrainStarted = true
        model.beginTermination()
        model.stopServer()
        Task { @MainActor [weak self] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await self.model.detachAllClientsAndDrain()
            await self.model.flushKittyImagePersistence()
            await self.integration?.shutdownAndWait()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func workspaceWillPowerOff(_ notification: Notification) {
        model.prepareForSystemPowerOff()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            if let requestMainWindow = model.requestMainWindow {
                requestMainWindow()
            } else {
                NSLog("copilot-projects: main window reopen action is not available yet")
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        HostLifetimePolicy.shouldTerminateAfterLastWindowClosed()
    }
}
