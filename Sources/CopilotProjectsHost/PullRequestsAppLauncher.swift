import AppKit
import CopilotProjectsCore

/// Opens Copilot Pull Requests, the Pull Requests window's own app, from inside
/// this app's bundle, or brings the running copy forward.
@MainActor
enum PullRequestsAppLauncher {
    /// How the helper is opened, decided from this app's environment.
    struct Launch: Equatable {
        let activates: Bool
        let allowsRunningApplicationSubstitution: Bool
        let createsNewApplicationInstance: Bool
        let environment: [String: String]
    }

    nonisolated static func launch(environment: [String: String]) -> Launch {
        Launch(
            activates: true,
            // Exactly the helper inside this app, never another copy Launch Services knows.
            allowsRunningApplicationSubstitution: false,
            // An isolated instance gets its own helper, reading its own socket and state.
            createsNewApplicationInstance: PullRequestsAppBundle.isIsolated(environment),
            environment: PullRequestsAppBundle.forwardedEnvironment(environment)
        )
    }

    static func open(
        hostBundle: Bundle? = RunningExecutable.applicationBundle,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let hostURL = hostBundle?.bundleURL,
              case let helperURL = PullRequestsAppBundle.helperURL(inHostBundle: hostURL),
              FileManager.default.fileExists(atPath: helperURL.path) else {
            presentMissingHelper()
            return
        }
        let helperIdentifier = Bundle(url: helperURL)?.bundleIdentifier
            ?? hostBundle?.bundleIdentifier.map(PullRequestsAppBundle.helperBundleIdentifier(hostBundleIdentifier:))
        // This app is active when ⇧⌘P is pressed, so it can hand activation over.
        // From the menu bar extra it may not be; Launch Services then brings the
        // running copy forward instead.
        if let running = runningHelper(bundleIdentifier: helperIdentifier),
           running.activate(from: .current, options: []) {
            return
        }
        let launch = launch(environment: environment)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = launch.activates
        configuration.allowsRunningApplicationSubstitution = launch.allowsRunningApplicationSubstitution
        configuration.createsNewApplicationInstance = launch.createsNewApplicationInstance
        configuration.environment = launch.environment
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if let error { NSLog("copilot-projects: could not open Copilot Pull Requests: \(error)") }
        }
    }

    /// The copy that recorded its pid for this state directory, if it is still
    /// running and still the helper.
    static func runningHelper(
        bundleIdentifier: String?, pidPath: String = Paths.pullRequestsAppPIDPath
    ) -> NSRunningApplication? {
        guard let bundleIdentifier,
              let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
              let running = NSRunningApplication(processIdentifier: pid),
              !running.isTerminated, running.bundleIdentifier == bundleIdentifier else { return nil }
        return running
    }

    private static func presentMissingHelper() {
        let alert = NSAlert()
        alert.messageText = "Pull requests open in a separate app"
        alert.informativeText = """
            Copilot Pull Requests ships inside Copilot Projects.app, and this copy doesn’t include it. \
            Build the app with scripts/build-app.sh and open Pull Requests from there.
            """
        alert.runModal()
    }
}
