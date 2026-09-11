import XCTest
import AppKit
import CopilotProjectsCore
@testable import copilot_projects

final class HostLifetimeTests: XCTestCase {
    @MainActor
    private func sync(_ container: TerminalsContainerView, model: AppModel) {
        container.sync(
            order: model.hostedTerminals.map(\.id), active: model.globalSelectedSessionId,
            emptyHint: ("", ""), onNew: {}, provider: { model.terminalView(for: $0) })
    }

    @MainActor
    private func withFocusFixture(
        _ body: (AppModel, NSWindow, TerminalsContainerView, [Project]) throws -> Void
    ) throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH"]
        let environment: [String: String?] = Dictionary(
            uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        let activationPolicy = NSApp.activationPolicy()
        defer {
            for (key, value) in environment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            NSApp.setActivationPolicy(activationPolicy)
        }
        NSApp.setActivationPolicy(.prohibited)
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        guard Paths.dtachExecutable == nil else {
            XCTFail("Focus fixtures must not create persistent dtach sessions")
            return
        }
        let projects = ["A", "B"].map { name in
            let session = Session(title: name, cwd: root.path)
            return Project(name: name, cwd: root.path, sessions: [session], selectedSessionId: session.id)
        }
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: projects, selectedProjectId: projects[0].id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")))
        defer { model.detachAllClients() }
        _ = try XCTUnwrap(model.controller(for: projects[0].sessions[0].id))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 750),
            styleMask: [.titled], backing: .buffered, defer: false)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 750))
        let container = TerminalsContainerView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        content.addSubview(container)
        window.contentView = content
        defer { window.makeFirstResponder(nil); window.contentView = nil }
        sync(container, model: model)
        try body(model, window, container, projects)
    }

    @MainActor
    func testExplicitFocusRestoresAlreadyDisplayedTerminalResponder() throws {
        try withFocusFixture { model, window, container, projects in
            let session = projects[0].sessions[0]
            let terminal = try XCTUnwrap(model.terminalView(for: session.id))
            let field = NSTextField(frame: NSRect(x: 10, y: 710, width: 300, height: 24))
            window.contentView?.addSubview(field)
            let targets: [NSResponder?] = [nil, field]
            for target in targets {
                XCTAssertTrue(window.makeFirstResponder(target))
                let displacedResponder = window.firstResponder
                XCTAssertFalse(displacedResponder === terminal)
                if target == nil {
                    XCTAssertTrue(displacedResponder === window)
                } else {
                    XCTAssertTrue(displacedResponder is NSTextView)
                }
                sync(container, model: model)
                XCTAssertTrue(window.firstResponder === displacedResponder,
                              "Ordinary updates must not steal editing focus")

                model.focus(projectId: projects[0].id, sessionId: session.id)
                XCTAssertEqual(model.globalSelectedSessionId, session.id)
                XCTAssertFalse(terminal.isHidden)
                XCTAssertTrue(window.firstResponder === terminal,
                              "Explicit focus must not depend on a session-change or activation callback")
            }
        }
    }

    @MainActor
    func testExplicitFocusLeavesHiddenAndUnattachedTargetsForTheirReveal() throws {
        for prewarm in [false, true] {
            try withFocusFixture { model, window, container, projects in
                let previous = try XCTUnwrap(model.activeController?.terminalView)
                let targetId = projects[1].sessions[0].id
                if prewarm {
                    _ = try XCTUnwrap(model.controller(for: targetId))
                    sync(container, model: model)
                }
                model.focus(projectId: projects[0].id, sessionId: targetId)
                let target = try XCTUnwrap(model.activeController?.terminalView)
                XCTAssertEqual(model.selectedProjectId, projects[1].id)
                XCTAssertEqual(model.globalSelectedSessionId, targetId)
                XCTAssertTrue(window.firstResponder === previous,
                              "Do not focus an off-screen terminal before it is revealed")
                if prewarm { XCTAssertTrue(target.isHidden) } else { XCTAssertNil(target.window) }

                sync(container, model: model)
                XCTAssertTrue(previous.isHidden)
                XCTAssertFalse(target.isHidden)
                XCTAssertTrue(window.firstResponder === target)
            }
        }
    }

    @MainActor
    func testExplicitFocusBeforeWindowReattachmentIsRestoredOnAttach() throws {
        try withFocusFixture { model, window, _, projects in
            let content = try XCTUnwrap(window.contentView)
            let terminal = try XCTUnwrap(model.activeController?.terminalView)
            window.makeFirstResponder(nil)
            window.contentView = nil
            XCTAssertNil(terminal.window)
            model.focus(projectId: projects[0].id, sessionId: projects[0].sessions[0].id)
            XCTAssertNil(terminal.window)

            window.contentView = content
            XCTAssertTrue(window.firstResponder === terminal)
        }
    }

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
