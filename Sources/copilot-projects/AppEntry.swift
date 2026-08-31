import SwiftUI
import AppKit
import AVFoundation
import CopilotProjectsCore
import CopilotProjectsProtocol

struct CopilotProjectsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(HostLifetimePolicy.settingKey) private var keepRunning = false

    var body: some Scene {
        Window("Copilot Projects", id: "main") {
            MainWindowContent(appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") { appDelegate.model.addProjectInteractive() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .appSettings) {
                Toggle("Keep Running When Window Closes", isOn: $keepRunning)
            }
            CommandMenu("Session") {
                Button("New Session") { appDelegate.model.addSessionToSelected() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Close Session") { appDelegate.model.closeSelectedSession() }
                    .keyboardShortcut("w", modifiers: .command)
                Divider()
                Button("Next Session") { appDelegate.model.selectAdjacentSession(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Session") { appDelegate.model.selectAdjacentSession(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
        MenuBarExtra("Copilot Projects", systemImage: "terminal", isInserted: $keepRunning) {
            HostStatusMenu(keepRunning: $keepRunning)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    private let nativeNotifications: NotificationManager
    private let webPushService: WebPushService?
    private let apnsService: APNsService?
    private let notificationSync: NotificationSyncService
    private let notifications: RoutedNotificationPoster
    private let instanceLock = AppInstanceLock()
    private var isPrimaryInstance = false
    private var eventMonitor: Any?
    private var hintWork: DispatchWorkItem?
    private var terminationDrainStarted = false

    override init() {
        let native = NotificationManager()
        let email = UserDefaults.standard.string(
            forKey: RemoteAccessConfiguration.allowedEmailKey
        )
        let webPush: WebPushService?
        if let email {
            do {
                webPush = try WebPushService.production(contactEmail: email)
            } catch {
                webPush = nil
                NSLog("copilot-projects: web push unavailable: %@", "\(error)")
            }
        } else {
            webPush = nil
        }
        let apns: APNsService?
        do {
            apns = try APNsService.production()
        } catch {
            apns = nil
            NSLog("copilot-projects: APNs unavailable: %@", "\(error)")
        }
        nativeNotifications = native
        webPushService = webPush
        apnsService = apns
        let sync = NotificationSyncService(
            webPushService: webPush,
            apnsService: apns
        )
        notificationSync = sync
        notifications = RoutedNotificationPoster(native: native, sync: sync)
        model = AppModel(
            webPushService: webPush,
            apnsService: apns,
            notificationSync: sync
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false

        guard instanceLock.acquire() else {
            webPushService?.shutdown()
            focusExistingInstance()
            NSApp.terminate(nil)
            return
        }
        model.activateKittyImagePersistence()

        nativeNotifications.onActivate = { [weak self] projectId, sessionId in
            self?.model.focus(projectId: projectId, sessionId: sessionId)
        }
        let sync = notificationSync
        nativeNotifications.onResolve = { [weak sync] id in
            sync?.dismiss(NotificationDismissRequest(id: id))
        }
        notificationSync.clearLocalNotification = { [weak self] id in
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
        model.startRemoteAccessIfEnabled()
        requestMicrophoneAccessIfNeeded()
        let env = ProcessInfo.processInfo.environment
        if Env.shouldInstallGlobalIntegration(env) {
            model.installCLISymlinkIfPossible()
            CopilotHooks.installIfPossible()
            CopilotExtension.installIfPossible()
        }
        registerDeepLinkHelper()

        NSApp.activate(ignoringOtherApps: true)

        // ⌘/⌃ + number navigation, the modifier-hold number overlay, double-click
        // title-bar zoom, link-vs-selection disambiguation, and scroll-wheel
        // forwarding into mouse-reporting TUIs.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .scrollWheel, .leftMouseDown, .leftMouseUp]) { [weak self] event in
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

        // When the app is activated (clicked / ⌘-Tab'd back), put keyboard focus
        // on the visible terminal instead of the sidebar list.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.model.markActiveSessionSeen()
                self?.model.focusActiveTerminal()
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
        case .keyDown:
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            // ⌘W closes the current tab. (macOS's default ⌘W closes the *window*,
            // which quits the app — that's the accidental-quit footgun.)
            if mods == .command, event.charactersIgnoringModifiers == "w" {
                model.closeSelectedSession()
                return nil
            }
            // Control+Tab / Control+Shift+Tab cycle tabs (browser-style). Keep the
            // overlay up if it's showing so you can keep cycling while holding ⌃.
            if event.keyCode == 48 {  // Tab
                if mods == .control { model.selectAdjacentSession(1); return nil }
                if mods == [.control, .shift] { model.selectAdjacentSession(-1); return nil }
            }
            // ⌘ / ⌃ + number jumps to a project / tab.
            if let digit = Self.digit(from: event) {
                if mods == .command {
                    hintWork?.cancel(); model.setNumberHint(.none)
                    model.selectProjectByIndex(digit - 1); return nil
                }
                if mods == .control {
                    hintWork?.cancel(); model.setNumberHint(.none)
                    model.selectSessionByIndex(digit - 1); return nil
                }
            }
            // Any other key dismisses the overlay.
            hintWork?.cancel()
            model.setNumberHint(.none)
            return event
        case .leftMouseDown:
            // Double-click the top title strip (but not the traffic lights) to run
            // the user's title-bar double-click action; .hiddenTitleBar + our
            // SwiftUI strip otherwise swallows the native gesture.
            if event.clickCount == 2,
               let window = event.window ?? NSApp.keyWindow ?? NSApp.mainWindow,
               isInTitleStrip(event, window: window) {
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

    private static func digit(from event: NSEvent) -> Int? {
        guard let s = event.charactersIgnoringModifiers, s.count == 1,
              let n = Int(s), (1...9).contains(n) else { return nil }
        return n
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
        webPushService?.shutdown()
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
            await self.webPushService?.shutdownAndWait()
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
