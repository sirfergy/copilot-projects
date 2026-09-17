import XCTest
import AppKit
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class SessionCloseIntegrationTests: XCTestCase {
    func testHostAvoidsCrossModuleDurationSleepSpecializations() throws {
        // The runtime failure depends on the toolchain and linked modules.
        // Keep the unsafe specialization out even on compilers that don't crash.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let entries = try XCTUnwrap(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))
        let files = entries.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertNil(
                source.range(of: #"\.sleep\s*\(\s*for\s*:"#,
                             options: .regularExpression),
                "\(file.lastPathComponent): use ContinuousClock.sleep(until:) instead (swiftlang/swift#86204)")
        }
    }

    @MainActor
    func testSelectedTerminalCloseFinishesWithoutDestroyingOtherSessions() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH", "SHELL"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map {
            ($0, ProcessInfo.processInfo.environment[$0])
        })
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        setenv("SHELL", "/bin/cat", 1)
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        guard Paths.dtachExecutable == nil else {
            return XCTFail("The fixture must not launch persistent sessions")
        }
        let sessions = [
            Session(title: "keep", cwd: root.path),
            Session(title: "close", cwd: root.path),
            Session(title: "right", cwd: root.path),
        ]
        let project = Project(
            name: "close integration", cwd: root.path,
            sessions: sessions, selectedSessionId: sessions[1].id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let store = RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: Paths.sessionsDir,
            resumeMarkerDirectory: Paths.sessionsDir,
            kittyImageDiskStore: store)
        defer {
            model.forcePendingSessionDestroys()
            model.detachAllClients()
        }
        let kept = try XCTUnwrap(model.controller(for: sessions[0].id))
        let closed = try XCTUnwrap(model.controller(for: sessions[1].id))
        let right = try XCTUnwrap(model.controller(for: sessions[2].id))
        XCTAssertGreaterThan(kept.shellPID, 0)
        XCTAssertGreaterThan(closed.shellPID, 0)
        XCTAssertGreaterThan(right.shellPID, 0)

        // This is the action used by both the Command-W monitor and Session menu.
        // Keep the real PTY, destroyer, sleeper, and persistence wired together.
        let closeOrder: [(TerminalController, String?)] = [
            (closed, kept.sessionId), (kept, right.sessionId), (right, nil),
        ]
        for (controller, expectedSelection) in closeOrder {
            let sessionId = controller.sessionId
            model.closeSelectedSession()
            XCTAssertTrue(store.isTombstonedForTesting(sessionId: sessionId))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: Paths.closeSessionRequestPath(sessionId: sessionId)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))

            let deadline = ContinuousClock.now + .seconds(8)
            while (FileManager.default.fileExists(atPath: repository.closeIntentPath.path)
                    || !controller.exited), ContinuousClock.now < deadline {
                try await ContinuousClock().sleep(until: .now + .milliseconds(25))
            }
            XCTAssertTrue(controller.exited, "The closed terminal's process must exit")
            XCTAssertFalse(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: Paths.closeSessionRequestPath(sessionId: sessionId)))
            XCTAssertFalse(model.projects[0].sessions.contains { $0.id == sessionId })
            XCTAssertEqual(model.projects[0].selectedSessionId, expectedSelection)
            for survivor in [kept, right] where model.projects[0].sessions.contains(where: {
                $0.id == survivor.sessionId
            }) {
                XCTAssertFalse(survivor.exited, "Closing one terminal must not terminate its neighbors")
                XCTAssertEqual(kill(survivor.shellPID, 0), 0)
            }
            guard case .loaded(let restored) = repository.load() else {
                return XCTFail("Closed sessions must remain closed after reloading state")
            }
            XCTAssertEqual(restored.projects[0].sessions.map(\.id), model.projects[0].sessions.map(\.id))
        }
        XCTAssertTrue(model.projects[0].sessions.isEmpty)
        model.closeSelectedSession()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.closeIntentPath.path))
        await store.flush()
    }
}
