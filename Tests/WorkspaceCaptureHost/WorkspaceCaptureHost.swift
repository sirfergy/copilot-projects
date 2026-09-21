import AppKit
import WorkspaceCaptureSupport

#if DEBUG
@MainActor
final class CaptureDelegate: NSObject, NSApplicationDelegate {
    var exitStatus: Int32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
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
              let outputPath = environment["WORKSPACE_CAPTURE_ROOT"] else {
            fputs("Workspace capture host requires the isolated Actions driver.\n", stderr)
            exit(1)
        }
        let root = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath()
        guard Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .resolvingSymlinksInPath().path == root.path else {
            fputs("Workspace capture application is outside its isolated output directory.\n", stderr)
            exit(1)
        }
        do {
            try Data("\(getpid())\n".utf8).write(to: root.appendingPathComponent("host-pid"), options: .atomic)
        } catch {
            fputs("Could not record capture application identity: \(error)\n", stderr)
            exit(1)
        }
        let app = NSApplication.shared
        let delegate = CaptureDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        do {
            try "\(delegate.exitStatus)\n".write(
                to: root.appendingPathComponent("host-exit-status"), atomically: true, encoding: .utf8
            )
        } catch {
            fputs("Could not record GUI host shutdown: \(error)\n", stderr)
            exit(1)
        }
        exit(delegate.exitStatus)
        #else
        fputs("Workspace capture host is available only in debug builds.\n", stderr)
        exit(1)
        #endif
    }
}
