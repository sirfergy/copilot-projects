import AppKit
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost
@testable import SwiftTerm

/// Launch failures reach TerminalController through a real LocalProcess and
/// the view's own process delegate; only the write-descriptor duplicate is scripted.
@MainActor
final class TerminalLaunchRetryTests: XCTestCase {
    private var controllers: [TerminalController] = []
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("launch-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        controllers.forEach { $0.terminate() }
        controllers.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    /// Starts a controller whose first duplicates fail with `failures`, in order.
    private func controller(failing failures: [Int32], retryDelay: Duration) -> TerminalController {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let remaining = Locked(failures)
        view.replaceProcess { delegate in
            LocalProcess(delegate: delegate, dispatchQueue: .main) { descriptor in
                if let code = remaining.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                    errno = code
                    return -1
                }
                return fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            }
        }
        let controller = TerminalController(
            sessionId: UUID().uuidString,
            cwd: root.path,
            extraEnvironment: [:],
            dtachExecutable: nil,
            dtachSocket: nil,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            view: view
        )
        // The failure callback is delivered on a later main-queue turn.
        controller.retryDelay = { _ in retryDelay }
        controllers.append(controller)
        return controller
    }

    private func screenText(_ controller: TerminalController) -> String {
        controller.terminalView.terminalStateSnapshot().visibleRows.map(\.text).joined(separator: "\n")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testTransientLaunchFailuresRelaunchTheSameTabWithoutExiting() async throws {
        let controller = controller(failing: [EMFILE, ENXIO], retryDelay: .milliseconds(20))
        var exits = 0
        controller.onExit = { _ in exits += 1 }
        XCTAssertFalse(controller.terminalView.process.running)
        let generation = controller.terminalView.remoteContentGeneration

        try await waitUntil { controller.terminalView.process.running }
        XCTAssertTrue(controller.terminalView.process.running)
        XCTAssertGreaterThan(controller.shellPID, 0)
        XCTAssertEqual(controller.launchAttempts, 3)
        XCTAssertEqual(exits, 0)
        XCTAssertFalse(controller.exited)
        let text = screenText(controller)
        XCTAssertTrue(text.contains("Process launch failed: writeChannelFailed(\(EMFILE))"), text)
        XCTAssertTrue(text.contains("Process launch failed: writeChannelFailed(\(ENXIO))"), text)
        XCTAssertEqual(text.components(separatedBy: "Retrying automatically.").count, 2, text)
        // Remote clients refresh screens by generation; host-printed text counts.
        XCTAssertGreaterThan(controller.terminalView.remoteContentGeneration, generation)
    }

    func testPermanentLaunchFailureIsNotRetried() async throws {
        let controller = controller(failing: [EPERM], retryDelay: .milliseconds(20))
        try await waitUntil { self.screenText(controller).contains("Process launch failed") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.launchAttempts, 1)
        XCTAssertFalse(controller.terminalView.process.running)
        XCTAssertFalse(screenText(controller).contains("Retrying"))
    }

    func testRetiredControllersDoNotRelaunchAfterBackoff() async throws {
        let retirements: [(String, (TerminalController) -> Void)] = [
            ("terminate", { $0.terminate() }),
            ("drain", { $0.beginTerminationDrain() }),
            ("closed tab", { $0.shouldRetryLaunch = { false } }),
        ]
        for (name, retire) in retirements {
            let controller = controller(failing: [EMFILE], retryDelay: .milliseconds(150))
            try await waitUntil { self.screenText(controller).contains("Retrying automatically.") }
            retire(controller)
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertEqual(controller.launchAttempts, 1, name)
            XCTAssertFalse(controller.terminalView.process.running, name)
        }
    }

    func testTerminatingBeforeTheFailureArrivesPreventsTheRetry() async throws {
        let controller = controller(failing: [EMFILE], retryDelay: .milliseconds(20))
        controller.terminate()
        try await waitUntil { self.screenText(controller).contains("Process launch failed") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(controller.launchAttempts, 1)
        XCTAssertFalse(controller.terminalView.process.running)
        XCTAssertFalse(screenText(controller).contains("Retrying"))
    }

    func testOnlyResourceExhaustionIsTransient() {
        let codes = [EAGAIN, ENOMEM, EMFILE, ENFILE, ENXIO, EPERM, EACCES, ENOENT]
        let transient = [true, true, true, true, true, false, false, false]
        XCTAssertEqual(codes.map { TerminalController.isTransientLaunchFailure(.forkFailed($0)) }, transient)
        XCTAssertEqual(
            codes.map { TerminalController.isTransientLaunchFailure(.writeChannelFailed($0)) }, transient)
        XCTAssertFalse(TerminalController.isTransientLaunchFailure(.alreadyRunning))
    }

    func testBackoffDoublesToAMinute() {
        XCTAssertEqual(
            (1...8).map { TerminalController.launchRetryDelay(afterFailures: $0) },
            [1, 2, 4, 8, 16, 32, 60, 60].map { Duration.seconds($0) }
        )
    }
}
