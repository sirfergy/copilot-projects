import AppKit
import WorkspaceCaptureSupport

#if DEBUG
@MainActor
final class CaptureDelegate: NSObject, NSApplicationDelegate {
    var exitStatus: Int32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            do {
                try await WorkspaceCaptureFixture().run()
                exitStatus = 0
            } catch {
                NSLog("Native workspace capture failed: %@", String(describing: error))
            }
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(
                with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
            ) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
    }
}
#endif

@main
enum WorkspaceCaptureHost {
    @MainActor
    static func main() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_TRACKING_ID"] != nil,
              environment["WORKSPACE_CAPTURE_ROOT"] != nil else {
            fputs("Workspace capture host requires the isolated Actions driver.\n", stderr)
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = CaptureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(delegate.exitStatus)
        #else
        fputs("Workspace capture host is available only in debug builds.\n", stderr)
        exit(1)
        #endif
    }
}
