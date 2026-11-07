import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI
@testable import CopilotProjectsHost

final class WorkspaceLayoutTests: XCTestCase {
    @MainActor
    private final class WorkspaceWindow: NSWindow {
        var responderChanges = 0

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let previous = firstResponder
            let accepted = super.makeFirstResponder(responder)
            if accepted && firstResponder !== previous { responderChanges += 1 }
            return accepted
        }
    }

    @MainActor
    private final class Navigation: ObservableObject {
        @Published var showsProjects = true
    }

    private struct Workspace: View {
        let model: AppModel
        let input: WorkspaceInputController
        @ObservedObject var navigation: Navigation

        var body: some View {
            RootView(model: model, input: input, showsProjects: $navigation.showsProjects)
        }
    }

    @MainActor
    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    private func split(named name: String?, in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView, split.autosaveName == name { return split }
        return view.subviews.lazy.compactMap { self.split(named: name, in: $0) }.first
    }

    @MainActor
    private func projectTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.projectTable(in: $0) }.first
    }

    @MainActor
    private func withWorkspace(
        _ body: @MainActor (AppModel, Navigation, WorkspaceWindow) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH"]
        let environment = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        let splitKeys = ["projects", "sessions"].map { "NSSplitView Subview Frames copilot-projects.\($0)" }
        let preferences = splitKeys.map { UserDefaults.standard.object(forKey: $0) }
        let activationPolicy = NSApp.activationPolicy()
        defer {
            for (key, value) in environment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            for (key, value) in zip(splitKeys, preferences) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            NSApp.setActivationPolicy(activationPolicy)
        }
        NSApp.setActivationPolicy(.prohibited)
        for key in splitKeys { UserDefaults.standard.removeObject(forKey: key) }
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        guard Paths.dtachExecutable == nil else {
            XCTFail("Layout fixtures must not create persistent dtach sessions")
            return
        }
        let session = Session(title: "Layout fixture", cwd: root.path)
        let project = Project(name: "Projects", cwd: root.path, sessions: [session], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project, Project(name: "Empty", cwd: root.path)], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")))
        defer { model.detachAllClients() }
        _ = try XCTUnwrap(model.controller(for: session.id))
        let navigation = Navigation()
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: Workspace(
            model: model, input: WorkspaceInputController(model: model), navigation: navigation
        ))
        defer {
            _ = window.makeFirstResponder(nil)
            window.contentView = nil
        }
        try await settle(window)
        try await body(model, navigation, window)
    }

    @MainActor
    func testBothNavigationPanesResizeAndRespectCompactWindow() async throws {
        try await withWorkspace { model, _, window in
            let root = try XCTUnwrap(window.contentView)
            let projects = try XCTUnwrap(split(named: "copilot-projects.projects", in: root))
            let sessions = try XCTUnwrap(split(named: "copilot-projects.sessions", in: root))
            let terminal = try XCTUnwrap(model.activeController?.terminalView)
            let originalProjectsWidth = projects.subviews[0].frame.width
            XCTAssertEqual(originalProjectsWidth, 176, accuracy: 1)
            projects.setPosition(300, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)
            XCTAssertNotEqual(projects.subviews[0].frame.width, originalProjectsWidth)
            XCTAssertEqual(projects.subviews[0].frame.width, 300, accuracy: 1)
            XCTAssertEqual(sessions.subviews[0].frame.width, 250, accuracy: 1)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)

            projects.setPosition(100, ofDividerAt: 0)
            try await settle(window)
            XCTAssertEqual(projects.subviews[0].frame.width, 176, accuracy: 1)
            projects.setPosition(500, ofDividerAt: 0)
            try await settle(window)
            XCTAssertEqual(projects.subviews[0].frame.width, 360, accuracy: 1)

            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            XCTAssertEqual(root.bounds.width, 820, accuracy: 1)
            XCTAssertGreaterThanOrEqual(projects.subviews[0].frame.width, 176)
            XCTAssertGreaterThanOrEqual(sessions.subviews[0].frame.width, 200)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)
        }
    }

    @MainActor
    func testCollapseRestoresWidthAndPreservesLiveTerminal() async throws {
        try await withWorkspace { model, navigation, window in
            let root = try XCTUnwrap(window.contentView)
            let projects = try XCTUnwrap(split(named: "copilot-projects.projects", in: root))
            let sessions = try XCTUnwrap(split(named: "copilot-projects.sessions", in: root))
            let controller = try XCTUnwrap(model.activeController)
            let terminal = controller.terminalView
            let container = terminal.superview
            let pid = controller.shellPID
            projects.setPosition(260, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)
            let terminalWidth = terminal.bounds.width
            XCTAssertTrue(window.makeFirstResponder(terminal))
            let responderChanges = window.responderChanges

            navigation.showsProjects = false
            try await settle(window)
            XCTAssertTrue(projects.isSubviewCollapsed(projects.subviews[0]))
            XCTAssertGreaterThan(terminal.bounds.width, terminalWidth)
            XCTAssertTrue(window.firstResponder === terminal)
            XCTAssertEqual(window.responderChanges, responderChanges)
            XCTAssertTrue(terminal.superview === container)

            navigation.showsProjects = true
            try await settle(window)
            XCTAssertFalse(projects.isSubviewCollapsed(projects.subviews[0]))
            XCTAssertEqual(projects.subviews[0].frame.width, 260, accuracy: 1)
            XCTAssertEqual(sessions.subviews[0].frame.width, 250, accuracy: 1)
            XCTAssertTrue(model.activeController?.terminalView === terminal)
            XCTAssertTrue(terminal.superview === container)
            XCTAssertEqual(model.activeController?.shellPID, pid)
            XCTAssertTrue(window.firstResponder === terminal)
            XCTAssertEqual(window.responderChanges, responderChanges)

            navigation.showsProjects = false
            try await settle(window)
            window.setContentSize(NSSize(width: 820, height: 520))
            try await settle(window)
            navigation.showsProjects = true
            try await settle(window)
            XCTAssertEqual(root.bounds.width, 820, accuracy: 1)
            XCTAssertGreaterThanOrEqual(terminal.bounds.width, 420)
            XCTAssertGreaterThanOrEqual(projects.subviews[0].frame.width, 176)
            XCTAssertTrue(terminal.superview === container)
            XCTAssertEqual(model.activeController?.shellPID, pid)
        }
    }

    @MainActor
    func testReopeningRestoresWidthsButNotCollapsedVisibility() async throws {
        try await withWorkspace { model, navigation, window in
            let projects = try XCTUnwrap(split(
                named: "copilot-projects.projects", in: try XCTUnwrap(window.contentView)))
            let sessions = try XCTUnwrap(split(
                named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
            projects.setPosition(270, ofDividerAt: 0)
            sessions.setPosition(250, ofDividerAt: 0)
            try await settle(window)

            for closedWhileHidden in [false, true] {
                navigation.showsProjects = !closedWhileHidden
                try await settle(window)
                XCTAssertNotNil(UserDefaults.standard.object(
                    forKey: "NSSplitView Subview Frames copilot-projects.projects"))
                window.contentView = nil
                navigation.showsProjects = true
                window.contentView = NSHostingView(rootView: Workspace(
                    model: model, input: WorkspaceInputController(model: model), navigation: navigation
                ))
                try await settle(window)
                let restoredProjects = try XCTUnwrap(split(
                    named: "copilot-projects.projects", in: try XCTUnwrap(window.contentView)))
                let restoredSessions = try XCTUnwrap(split(
                    named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
                XCTAssertFalse(restoredProjects.isSubviewCollapsed(restoredProjects.subviews[0]))
                XCTAssertEqual(restoredProjects.subviews[0].frame.width, 270, accuracy: 1,
                               "Closed while hidden: \(closedWhileHidden)")
                XCTAssertEqual(restoredSessions.subviews[0].frame.width, 250, accuracy: 1,
                               "Closed while hidden: \(closedWhileHidden)")
            }

            navigation.showsProjects = false
            try await settle(window)
            window.contentView = nil
            window.contentView = NSHostingView(rootView: Workspace(
                model: model, input: WorkspaceInputController(model: model), navigation: navigation
            ))
            try await settle(window)
            let hiddenProjects = try XCTUnwrap(split(
                named: nil, in: try XCTUnwrap(window.contentView)))
            let splitController = try XCTUnwrap(hiddenProjects.delegate as? NSSplitViewController)
            XCTAssertTrue(splitController.splitViewItems[0].isCollapsed)
            navigation.showsProjects = true
            try await settle(window)
            XCTAssertFalse(splitController.splitViewItems[0].isCollapsed)
            XCTAssertEqual(hiddenProjects.subviews[0].frame.width, 270, accuracy: 1)
            let restoredSessions = try XCTUnwrap(split(
                named: "copilot-projects.sessions", in: try XCTUnwrap(window.contentView)))
            XCTAssertEqual(restoredSessions.subviews[0].frame.width, 250, accuracy: 1)
        }
    }

    @MainActor
    func testHidingFocusedProjectsMovesFocusOutOfTheHiddenTable() async throws {
        try await withWorkspace { model, navigation, window in
            for emptyProject in [false, true] {
                if emptyProject {
                    model.selectProject(try XCTUnwrap(model.projects.first { $0.sessions.isEmpty }).id)
                }
                navigation.showsProjects = true
                try await settle(window)
                let table = try XCTUnwrap(projectTable(in: try XCTUnwrap(window.contentView)))
                XCTAssertTrue(window.makeFirstResponder(table))
                navigation.showsProjects = false
                try await settle(window)
                XCTAssertFalse((window.firstResponder as? NSView)?.isDescendant(of: table) ?? false)
                if !emptyProject {
                    XCTAssertTrue(window.firstResponder === model.activeController?.terminalView)
                }
            }

            // In full-width transcript mode, hiding Projects clears focus from the Projects table
            // without focusing the hidden terminal, while preserving an active drawer editor.
            let previousFullWidth = UserDefaults.standard.object(forKey: TranscriptDrawer.fullWidthTranscriptKey)
            defer {
                if let previousFullWidth {
                    UserDefaults.standard.set(previousFullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
                }
            }
            UserDefaults.standard.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            let populatedProject = try XCTUnwrap(model.projects.first { !$0.sessions.isEmpty })
            model.selectProject(populatedProject.id)
            let sid = try XCTUnwrap(model.globalSelectedSessionId)
            let now = Date()
            model.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: now),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 1,
                lastIdleAborted: false,
                lastIdleTurnKind: "user",
                error: nil,
                conversationEpoch: "epoch-1",
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                    capabilities: ["session-send"],
                    sendReady: true
                )
            )
            model.openTranscriptDrawer(sessionId: sid)
            navigation.showsProjects = true
            try await settle(window)
            let terminal = try XCTUnwrap(model.activeController?.terminalView)
            XCTAssertTrue(terminal.isHidden)
            let table = try XCTUnwrap(projectTable(in: try XCTUnwrap(window.contentView)))
            XCTAssertTrue(window.makeFirstResponder(table))
            navigation.showsProjects = false
            try await settle(window)
            XCTAssertFalse((window.firstResponder as? NSView)?.isDescendant(of: table) ?? false)
            XCTAssertFalse(window.firstResponder === terminal)

            navigation.showsProjects = true
            try await settle(window)
            @MainActor func findTextFields(in view: NSView) -> [NSTextField] {
                ((view as? NSTextField).map { [$0] } ?? []) + view.subviews.flatMap(findTextFields(in:))
            }
            let promptField = try XCTUnwrap(findTextFields(in: try XCTUnwrap(window.contentView)).first { $0.isEditable })
            XCTAssertTrue(window.makeFirstResponder(promptField))
            XCTAssertNotNil(promptField.currentEditor())
            navigation.showsProjects = false
            try await settle(window)
            XCTAssertNotNil(promptField.currentEditor())
            XCTAssertFalse(window.firstResponder === terminal)
        }
    }

    @MainActor
    func testCursorResetsOverControls() async throws {
        try await withWorkspace { model, _, window in
            let sid = try XCTUnwrap(model.globalSelectedSessionId)
            let controller = try XCTUnwrap(model.activeController)
            let terminalView = controller.terminalView
            let previousFullWidth = UserDefaults.standard.object(forKey: TranscriptDrawer.fullWidthTranscriptKey)
            defer {
                if let previousFullWidth {
                    UserDefaults.standard.set(previousFullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
                }
                NSCursor.arrow.set()
            }
            UserDefaults.standard.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)

            let now = Date()
            Paths.ensureStateDir()
            let snap = TranscriptSnapshot(
                schemaVersion: 3,
                updatedAt: now,
                copilotSessionId: "cid-1",
                turns: [
                    TranscriptTurn(
                        id: "t1",
                        startedAt: now.addingTimeInterval(-10),
                        endedAt: now.addingTimeInterval(-5),
                        kind: "user",
                        userContent: "Hello world user text",
                        assistantMessages: [
                            TranscriptAssistantMessage(
                                id: "m1",
                                timestamp: now,
                                content: "Assistant markdown reply [link](https://example.com)"
                            )
                        ],
                        tools: [TranscriptTool(id: "tool1", name: "bash", title: "ls -la", success: true)],
                        isAborted: false,
                        error: TranscriptTurnError(message: "Error text", timestamp: now),
                        reasoningSteps: ["Step 1 thinking"]
                    )
                ]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(snap).write(to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sid)))

            model.refreshSelectedTranscriptController()
            let tc = try XCTUnwrap(model.activeTranscriptController)
            tc.reload()
            model.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: now),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 1,
                lastIdleAborted: false,
                lastIdleTurnKind: "user",
                error: nil,
                conversationEpoch: "epoch-1",
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1000),
                    capabilities: ["session-send"],
                    sendReady: true
                )
            )
            model.openTranscriptDrawer(sessionId: sid)
            try await settle(window)

            let root = try XCTUnwrap(window.contentView)
            window.displayIfNeeded()
            window.resetCursorRects()
            try await settle(window)
            window.displayIfNeeded()

            @MainActor func findViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
                ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { findViews(type, in: $0) }
            }
            let textFields = findViews(NSTextField.self, in: root)
            let mdViews = findViews(MarkdownSelectableTextView.self, in: root)
            XCTAssertFalse(mdViews.isEmpty)
            for md in mdViews {
                XCTAssertTrue(md.clipsToBounds)
                XCTAssertEqual(md.visibleRect, md.bounds)
            }

            @MainActor func movePointer(to point: NSPoint, in targetWindow: NSWindow = window) {
                guard let event = NSEvent.mouseEvent(
                    with: .mouseMoved,
                    location: point,
                    modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: targetWindow.windowNumber,
                    context: nil,
                    eventNumber: 0,
                    clickCount: 0,
                    pressure: 0
                ) else {
                    XCTFail("Could not construct mouseMoved event")
                    return
                }
                NSApp.sendEvent(event)
            }

            let promptPoint = try XCTUnwrap(textFields.first(where: { $0.isEditable })).convert(NSPoint(x: 20, y: 10), to: nil)
            let assistantMarkdown = mdViews[1]
            let assistantMarkdownRect = assistantMarkdown.convert(assistantMarkdown.bounds, to: nil)
            let markdownPoint = NSPoint(x: assistantMarkdownRect.minX + 10, y: assistantMarkdownRect.midY)
            let markdownLinkLocal = try XCTUnwrap(
                stride(from: CGFloat(4), to: assistantMarkdown.bounds.width, by: 4)
                    .map { NSPoint(x: $0, y: assistantMarkdown.bounds.midY) }
                    .first { assistantMarkdown.hasLink(at: $0) }
            )
            let markdownLinkPoint = assistantMarkdown.convert(markdownLinkLocal, to: nil)
            let projectsSplit = try XCTUnwrap(split(named: "copilot-projects.projects", in: root))
            let dividerX = projectsSplit.subviews[0].frame.maxX + (projectsSplit.dividerThickness / 2)
            let splitDividerPoint = projectsSplit.convert(NSPoint(x: dividerX, y: 300), to: nil)

            let points: [(String, NSPoint, NSCursor)] = [
                ("terminal-uncovered", NSPoint(x: 420, y: 300), .iBeam),
                ("markdown-text", markdownPoint, .iBeam),
                ("markdown-link", markdownLinkPoint, .pointingHand),
                ("prompt-textfield", promptPoint, .iBeam),
                ("quick-reply-chip-1", NSPoint(x: 900, y: 102), .arrow),
                ("quick-reply-chip-2", NSPoint(x: 960, y: 102), .arrow),
                ("paperclip-button", NSPoint(x: 1190, y: 102), .arrow),
                ("paste-button", NSPoint(x: 1240, y: 102), .arrow),
                ("send-button", NSPoint(x: 1210, y: 24), .arrow),
                ("mode-menu-button", NSPoint(x: 1255, y: 24), .arrow),
                ("titlebar-back", NSPoint(x: 90, y: 780), .arrow),
            ]

            for (focusLabel, responder) in [
                ("unfocused", nil as NSResponder?),
                ("promptTF", textFields.first(where: { $0.isEditable })),
                ("markdown", mdViews.first),
                ("terminal", terminalView),
            ] {
                _ = window.makeFirstResponder(responder)
                try await settle(window)
                window.displayIfNeeded()
                for (name, pt, expected) in points {
                    NSCursor.arrow.set()
                    movePointer(to: pt)
                    XCTAssertEqual(NSCursor.current, expected, "[\(focusLabel)] \(name) from arrow")
                    NSCursor.iBeam.set()
                    movePointer(to: pt)
                    XCTAssertEqual(NSCursor.current, expected, "[\(focusLabel)] \(name) from iBeam")
                }
            }

            // Leaving a Markdown link onto a quick-reply chip resets the pointing hand to arrow,
            // while native split-view resize cursors are preserved.
            movePointer(to: markdownLinkPoint)
            XCTAssertEqual(NSCursor.current, .pointingHand)
            movePointer(to: NSPoint(x: 900, y: 102))
            XCTAssertEqual(NSCursor.current, .arrow)
            NSCursor.resizeLeftRight.set()
            movePointer(to: splitDividerPoint)
            XCTAssertEqual(NSCursor.current, .resizeLeftRight)

            // In full-width transcript mode, the covered terminal area uses the arrow cursor.
            UserDefaults.standard.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            try await settle(window)
            window.displayIfNeeded()
            NSCursor.iBeam.set()
            movePointer(to: NSPoint(x: 420, y: 300))
            XCTAssertEqual(NSCursor.current, .arrow)
        }
    }
}
