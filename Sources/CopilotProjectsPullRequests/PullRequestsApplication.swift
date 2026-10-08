import AppKit
import Darwin
import SwiftUI
import CopilotProjectsCore

/// Copilot Pull Requests: the Pull Requests window as its own app, so ⌘Tab and
/// the Dock reach it like any other.
@MainActor
public enum PullRequestsApplication {
    /// Held for the process's lifetime by the one copy that writes the state.
    static var lock: PullRequestsAppLock?
    /// Why the lock couldn't be taken when no other copy holds it. This copy
    /// still opens, but saves nothing.
    static var lockFailure: String?

    static var isPrimary: Bool { lock != nil }
    /// Another copy holds the lock, so this one only brings it forward.
    static var handsOff: Bool { lock == nil && lockFailure == nil }

    public static func run() {
        signal(SIGPIPE, SIG_IGN)
        let candidate = PullRequestsAppLock()
        switch candidate.acquire() {
        case .acquired:
            lock = candidate
        case .heldElsewhere:
            break
        case .failed(let code):
            NSLog("copilot-pull-requests: could not lock \(candidate.lockPath), errno \(code); saving nothing")
            lockFailure = PullRequestsAppLock.failureNote(errno: code)
        }
        CopilotPullRequestsApp.main()
    }
}

/// One Copilot Pull Requests per state directory: only the copy holding this
/// lock writes goals.json and transcript-index.json. Its pid is in `app.pid`
/// so Copilot Projects and later copies can bring it forward.
final class PullRequestsAppLock {
    enum Acquisition: Equatable {
        case acquired
        /// Another copy holds it.
        case heldElsewhere
        /// The lock file couldn't be opened or locked, so no copy may hold it.
        case failed(errno: Int32)
    }

    let lockPath: String
    let pidPath: String
    private var fd: Int32 = -1

    init(lockPath: String = Paths.pullRequestsAppLockPath, pidPath: String = Paths.pullRequestsAppPIDPath) {
        self.lockPath = lockPath
        self.pidPath = pidPath
    }

    var isHeld: Bool { fd >= 0 }

    static func failureNote(errno code: Int32) -> String {
        "Goals aren’t saved in this copy: its state folder can’t be locked (\(String(cString: strerror(code))))"
    }

    func acquire() -> Acquisition {
        guard fd < 0 else { return .acquired }
        let directory = (lockPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let candidate = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard candidate >= 0 else { return .failed(errno: errno) }
        var locked = flock(candidate, LOCK_EX | LOCK_NB)
        while locked != 0, errno == EINTR { locked = flock(candidate, LOCK_EX | LOCK_NB) }
        guard locked == 0 else {
            let code = errno
            close(candidate)
            return code == EWOULDBLOCK ? .heldElsewhere : .failed(errno: code)
        }
        fd = candidate
        let pid = Data("\(getpid())\n".utf8)
        do {
            try pid.write(to: URL(fileURLWithPath: pidPath), options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidPath)
        } catch {
            NSLog("copilot-pull-requests: could not record its pid: \(error)")
        }
        return .acquired
    }

    /// The pid of the copy holding the lock, as it recorded it.
    static func recordedProcessIdentifier(at path: String = Paths.pullRequestsAppPIDPath) -> pid_t? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        return pid
    }

    func release() {
        guard fd >= 0 else { return }
        if Self.recordedProcessIdentifier(at: pidPath) == getpid() { unlink(pidPath) }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    deinit { release() }
}

/// Where the Owners setting lives.
enum PullRequestsSettings {
    static let unsharedNote = "Owners aren’t shared with Copilot Projects in this copy"

    /// Copilot Projects' own defaults, so Owners chosen there carry over. A
    /// development build run outside an app bundle uses its own.
    static func defaults(
        bundleURL: URL, bundleIdentifier: String?, hostBundleIdentifier: String?
    ) -> (defaults: UserDefaults, note: String?) {
        guard bundleURL.pathExtension == "app", bundleIdentifier != nil else { return (.standard, nil) }
        guard let host = hostBundleIdentifier, !host.isEmpty, host != bundleIdentifier,
              let shared = UserDefaults(suiteName: host) else {
            NSLog("copilot-pull-requests: \(PullRequestsAppBundle.hostBundleIdentifierKey) is missing; Owners stay in this app")
            return (.standard, unsharedNote)
        }
        return (shared, nil)
    }

    static func defaults(for bundle: Bundle) -> (defaults: UserDefaults, note: String?) {
        defaults(
            bundleURL: bundle.bundleURL, bundleIdentifier: bundle.bundleIdentifier,
            hostBundleIdentifier: bundle.object(forInfoDictionaryKey: PullRequestsAppBundle.hostBundleIdentifierKey) as? String
        )
    }
}

struct CopilotPullRequestsApp: App {
    @NSApplicationDelegateAdaptor(PullRequestsAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(PullRequestsAppBundle.name, id: PullRequestsWindow.id) {
            PullRequestsView(pullRequests: appDelegate.model)
                .frame(minWidth: 880, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)
        // A second copy only hands off to the first, so it never shows a window.
        .defaultLaunchBehavior(PullRequestsApplication.handsOff ? .suppressed : .presented)
        .restorationBehavior(PullRequestsApplication.isPrimary ? .automatic : .disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class PullRequestsAppDelegate: NSObject, NSApplicationDelegate {
    let model: PullRequestsModel
    private var eventMonitor: Any?

    override init() {
        let settings = PullRequestsSettings.defaults(for: .main)
        model = PullRequestsModel(
            workspace: ControlWorkspaceBridge(),
            host: .system(),
            defaults: settings.defaults,
            settingsNote: settings.note,
            storageNote: PullRequestsApplication.lockFailure,
            // Only the lock holder writes goals and match counts.
            stateDirectory: PullRequestsApplication.isPrimary ? Paths.pullRequestsStateDir : nil
        )
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if PullRequestsApplication.handsOff {
            bringRunningCopyForward()
            NSApp.terminate(nil)
            return
        }
        // The hidden title bar leaves the drag strip to SwiftUI, which swallows
        // the native double-click; run the user's title-bar action from here.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            guard event.clickCount == 2, let window = event.window,
                  TitleStrip.contains(event.locationInWindow, windowHeight: window.frame.height) else { return event }
            TitleStrip.performDoubleClickAction(window)
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Activation alone (⇧⌘P in Copilot Projects, ⌘Tab, a second copy handing
    /// off) doesn't un-minimize a window, and this app has nothing else to show.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !PullRequestsApplication.handsOff else { return }
        Self.showWindowIfNoneVisible()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.showWindowIfNoneVisible() }
        return true
    }

    static func showWindowIfNoneVisible() {
        let windows = NSApp.windows.filter(\.canBecomeMain)
        guard !windows.contains(where: { $0.isVisible && !$0.isMiniaturized }),
              let window = windows.first(where: \.isMiniaturized) ?? windows.first else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        PullRequestsApplication.lock?.release()
    }

    private func bringRunningCopyForward() {
        guard let pid = PullRequestsAppLock.recordedProcessIdentifier(),
              pid != getpid(),
              let running = NSRunningApplication(processIdentifier: pid),
              running.bundleIdentifier == Bundle.main.bundleIdentifier else {
            NSLog("copilot-pull-requests: another copy holds the lock but couldn't be found")
            return
        }
        _ = running.activate(from: .current, options: [])
    }
}

/// The 38pt strip at the top of the window, past the traffic lights.
enum TitleStrip {
    /// Measured from the window frame's top: under the hidden title bar the
    /// content view doesn't span the full frame.
    static func contains(_ location: NSPoint, windowHeight: CGFloat) -> Bool {
        let fromTop = windowHeight - location.y
        return fromTop >= 0 && fromTop <= PullRequestsWindow.titleStripHeight
            && location.x > PullRequestsWindow.trafficLightInset
    }

    /// The System Settings ▸ Desktop & Dock title-bar double-click action; zoom when unset.
    static func performDoubleClickAction(_ window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}
