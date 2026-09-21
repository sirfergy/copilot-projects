import AppKit
import XCTest

@MainActor
final class WorkspaceCaptureHost: NSObject, NSApplicationDelegate {
    var exitStatus: Int32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // XCTest owns the asynchronous test invocation; AppKit must keep its
        // main thread in the real application event loop throughout that run.
        DispatchQueue.global(qos: .userInitiated).async {
            let suite = XCTestSuite(forTestCaseWithName: "CopilotProjectsTests.WorkspaceCaptureTests")
            guard suite.testCaseCount == 1 else {
                NSLog("Expected exactly one workspace capture test, found %lu.", suite.testCaseCount)
                DispatchQueue.main.async { self.finish(status: 1) }
                return
            }
            suite.run()
            let succeeded = suite.testRun?.hasSucceeded == true && suite.testRun?.executionCount == 1
            DispatchQueue.main.async { self.finish(status: succeeded ? 0 : 1) }
        }
    }

    private func finish(status: Int32) {
        exitStatus = status
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0
        ) {
            NSApp.postEvent(wake, atStart: true)
        }
    }
}

@main
enum WorkspaceCaptureMain {
    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GITHUB_ACTIONS"] == "true",
              environment["RUNNER_TRACKING_ID"] != nil,
              environment["WORKSPACE_CAPTURE_ROOT"] != nil,
              CommandLine.arguments.count == 2 else {
            fputs("Workspace capture host requires the isolated Actions driver and its test bundle.\n", stderr)
            exit(1)
        }
        guard let bundle = Bundle(path: CommandLine.arguments[1]) else {
            fputs("The workspace capture test bundle is missing.\n", stderr)
            exit(1)
        }
        do {
            try bundle.loadAndReturnError()
        } catch {
            fputs("Could not load workspace capture tests: \(error)\n", stderr)
            exit(1)
        }

        let app = NSApplication.shared
        let delegate = WorkspaceCaptureHost()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
        exit(delegate.exitStatus)
    }
}
