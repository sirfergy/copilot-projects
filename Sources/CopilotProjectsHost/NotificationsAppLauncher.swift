import AppKit
import Combine
import SwiftUI
import CopilotProjectsCore

/// Opens Copilot Notifications, the GitHub inbox's own app, from inside this
/// app's bundle, brings the running copy forward, or starts it to watch.
@MainActor
enum NotificationsAppLauncher {
    /// Whether Copilot Projects starts Copilot Notifications when it launches.
    /// Opening Notifications once turns it on; the app menu turns it off.
    /// No dots: the App scene reads it through @AppStorage, and a dotted key
    /// makes SwiftUI rebuild the scene on every defaults write.
    static let startsWithHostKey = "notificationsStartWithHost"

    static func open(
        hostBundle: Bundle? = RunningExecutable.applicationBundle,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        if defaults.object(forKey: startsWithHostKey) == nil { defaults.set(true, forKey: startsWithHostKey) }
        launch(hostBundle: hostBundle, environment: environment, inBackground: false)
    }

    /// Starts it without a window so its Dock badge and banners are live,
    /// unless the user turned that off or it already runs.
    static func startInBackgroundIfWanted(
        hostBundle: Bundle? = RunningExecutable.applicationBundle,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        guard defaults.bool(forKey: startsWithHostKey) else { return }
        launch(hostBundle: hostBundle, environment: environment, inBackground: true)
    }

    private static func launch(hostBundle: Bundle?, environment: [String: String], inBackground: Bool) {
        guard let hostURL = hostBundle?.bundleURL,
              case let helperURL = NotificationsAppBundle.helperURL(inHostBundle: hostURL),
              FileManager.default.fileExists(atPath: helperURL.path) else {
            if !inBackground { presentMissingHelper() }
            return
        }
        let helperIdentifier = Bundle(url: helperURL)?.bundleIdentifier
            ?? hostBundle?.bundleIdentifier.map(NotificationsAppBundle.helperBundleIdentifier(hostBundleIdentifier:))
        if let running = PullRequestsAppLauncher.runningHelper(
            bundleIdentifier: helperIdentifier, pidPath: Paths.notificationsAppPIDPath
        ) {
            guard !inBackground else { return }
            NotificationsAppBundle.requestWindow()
            // ⇧⌘N comes while this app is active, so it can hand activation over.
            // From the menu bar extra it may not be; Launch Services then brings
            // the running copy forward instead.
            if running.activate(from: .current, options: []) { return }
        }
        let launch = PullRequestsAppLauncher.launch(environment: environment)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !inBackground
        configuration.allowsRunningApplicationSubstitution = launch.allowsRunningApplicationSubstitution
        configuration.createsNewApplicationInstance = launch.createsNewApplicationInstance
        configuration.environment = launch.environment
        if inBackground { configuration.arguments = [NotificationsAppBundle.backgroundArgument] }
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error {
                NSLog("copilot-projects: could not open Copilot Notifications: \(error)")
            } else if !inBackground {
                // Already running, Launch Services only brought it forward; ask
                // for the window once a just-launched copy is listening.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NotificationsAppBundle.requestWindow() }
            }
        }
    }

    private static func presentMissingHelper() {
        let alert = NSAlert()
        alert.messageText = "Notifications open in a separate app"
        alert.informativeText = """
            Copilot Notifications ships inside Copilot Projects.app, and this copy doesn’t include it. \
            Build the app with scripts/build-app.sh and open Notifications from there.
            """
        alert.runModal()
    }
}

/// What Copilot Notifications last published, for the menu bar item.
@MainActor
final class NotificationsSummaryWatcher: ObservableObject {
    static let shared = NotificationsSummaryWatcher()

    /// Unread threads that need the user; nil when Notifications isn't watching.
    @Published private(set) var needsYou: Int?
    private var timer: AnyCancellable?
    private let url: URL
    private let clock: () -> Date

    init(url: URL = Paths.notificationsSummaryURL, clock: @escaping () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    func start(interval: TimeInterval = 20) {
        guard timer == nil else { return }
        read()
        // An open menu is tracked in the event-tracking run-loop mode, where a timer in
        // the default mode does not fire: a new count would rebuild the menu bar and close
        // an open submenu. The count is read again once the menu closes.
        timer = Timer.publish(every: interval, tolerance: 5, on: .main, in: .default)
            .autoconnect()
            .sink { [weak self] _ in self?.read() }
    }

    func read() {
        let summary = NotificationsSummary.read(from: url)
        let fresh = summary.flatMap { clock().timeIntervalSince($0.updatedAt) <= NotificationsSummary.freshness ? $0 : nil }
        if needsYou != fresh?.needsYou { needsYou = fresh?.needsYou }
    }
}

/// Opens (or brings forward) Copilot Notifications.
struct OpenNotificationsButton: View {
    @ObservedObject var summary = NotificationsSummaryWatcher.shared

    var body: some View {
        Button(title) { NotificationsAppLauncher.open() }
            .keyboardShortcut("n", modifiers: [.command, .shift])
    }

    private var title: String {
        guard let count = summary.needsYou, count > 0 else { return "Notifications" }
        return "Notifications — \(count.formatted()) need\(count == 1 ? "s" : "") you"
    }
}
