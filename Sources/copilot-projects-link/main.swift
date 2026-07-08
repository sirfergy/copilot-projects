import AppKit
import CopilotProjectsCore
import Foundation

@MainActor
final class LinkHandlerDelegate: NSObject, NSApplicationDelegate {
    private var pendingDeepLink: AppDeepLink?
    private var didFinishLaunching = false
    private var isRouting = false
    private var noURLTimeout: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        let timeout = DispatchWorkItem {
            guard self.pendingDeepLink == nil, !self.isRouting else { return }
            NSLog("copilot-projects-link: no URL received")
            self.terminate()
        }
        noURLTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        routeIfReady()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let deepLink = urls.compactMap(AppDeepLink.init(url:)).last else {
            application.reply(toOpenOrPrint: .failure)
            terminate()
            return
        }
        pendingDeepLink = deepLink
        application.reply(toOpenOrPrint: .success)
        routeIfReady()
    }

    private func routeIfReady() {
        guard didFinishLaunching, !isRouting, let deepLink = pendingDeepLink else { return }
        isRouting = true
        noURLTimeout?.cancel()
        route(deepLink, attempt: 0)
    }

    private func route(_ deepLink: AppDeepLink, attempt: Int) {
        do {
            let response = try ControlClient().send(deepLink.focusRequest)
            if !response.ok {
                NSLog("copilot-projects-link: focus failed: \(response.error ?? "unknown error")")
            }
            terminate()
            return
        } catch {
            if attempt == 0 {
                NSLog("copilot-projects-link: app is not reachable yet: \(error)")
            }
        }

        if attempt == 0,
           let parentURL = AppDeepLink.parentApplicationURL(
               forHelperBundleURL: Bundle.main.bundleURL
           ) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(
                at: parentURL,
                configuration: configuration
            ) { _, error in
                if let error {
                    NSLog("copilot-projects-link: could not launch app: \(error)")
                }
            }
        }

        guard attempt < 80 else {
            NSLog("copilot-projects-link: focus timed out")
            terminate()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.route(deepLink, attempt: attempt + 1)
        }
    }

    private func terminate() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = LinkHandlerDelegate()
    application.setActivationPolicy(.prohibited)
    application.delegate = delegate
    application.run()
}
