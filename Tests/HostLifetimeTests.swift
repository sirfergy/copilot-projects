import XCTest
import AppKit
@testable import copilot_projects

final class HostLifetimeTests: XCTestCase {
    @MainActor
    func testExplicitFocusRequestsTheMainWindow() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [], selectedProjectId: nil))
        let model = AppModel(stateRepository: repository)
        var opened = 0
        model.requestMainWindow = { opened += 1 }
        model.focus(projectId: nil, sessionId: nil)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(model.projects.isEmpty)
    }

    @MainActor
    func testKeepingHostAliveRequiresExplicitOptIn() throws {
        let suite = "HostLifetimeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(HostLifetimePolicy.shouldTerminateAfterLastWindowClosed(defaults: defaults))
        defaults.set(true, forKey: HostLifetimePolicy.settingKey)
        XCTAssertFalse(HostLifetimePolicy.shouldTerminateAfterLastWindowClosed(defaults: defaults))
        defaults.set(false, forKey: HostLifetimePolicy.settingKey)
        XCTAssertTrue(HostLifetimePolicy.shouldTerminateAfterLastWindowClosed(defaults: defaults))
    }
}
