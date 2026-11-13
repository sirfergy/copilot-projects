import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class SessionRowInteractionTests: XCTestCase {
    @MainActor
    private final class Actions: ObservableObject {
        @Published var isActive = false
        @Published var isExpanded = false
        var selections = 0
        var closes = 0
        var toggles = 0
        var events: [String] = []
    }

    private struct RowFixture: View {
        @ObservedObject var actions: Actions
        var childSummary: SessionChildSummary? = nil
        let session = Session(title: "Example", cwd: "/tmp")

        var body: some View {
            SessionRow(
                session: session,
                isActive: actions.isActive,
                childSummary: childSummary,
                isExpanded: actions.isExpanded,
                onToggleExpand: childSummary != nil ? {
                    actions.events.append("toggle")
                    actions.toggles += 1
                    actions.isExpanded.toggle()
                } : nil,
                onSelect: {
                    actions.events.append("select")
                    actions.selections += 1
                    actions.isActive = true
                },
                onClose: {
                    actions.events.append("close")
                    actions.closes += 1
                    actions.isActive = false
                })
        }
    }

    @MainActor
    private func withRow(
        childSummary: SessionChildSummary? = nil,
        _ body: (NSWindow, Actions) async throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let actions = Actions()
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 280, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RowFixture(actions: actions, childSummary: childSummary))
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        try await body(window, actions)
    }

    @MainActor
    func testDoubleClickClosesTheSelectorWithoutDelayingSingleClick() async throws {
        try await withRow { window, actions in
            try click(window, at: NSPoint(x: 100, y: 40), count: 1)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(actions.selections, 1)
            XCTAssertEqual(actions.closes, 0)
            try click(window, at: NSPoint(x: 100, y: 40), count: 2)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(actions.closes, 1)
            XCTAssertEqual(actions.events.last, "close")
            XCTAssertFalse(actions.isActive)
        }
    }

    @MainActor
    func testDisclosureChevronTogglesExpansionWithoutSelectingOrClosingParentRow() async throws {
        let child = Session(id: "c1", title: "Worker", cwd: "/tmp", parentSessionId: "s1")
        let summary = SessionChildSummary(children: [child])
        try await withRow(childSummary: summary) { window, actions in
            let bounds = try XCTUnwrap(window.contentView?.bounds)
            try click(window, at: NSPoint(x: bounds.maxX - 46, y: bounds.midY), count: 1)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(actions.toggles, 1)
            XCTAssertTrue(actions.isExpanded)
            XCTAssertEqual(actions.selections, 0)
            XCTAssertEqual(actions.closes, 0)
        }
    }

    @MainActor
    func testSessionRowEquatableAndAccessibilityIncludeParentAndChildState() {
        let session = Session(id: "s1", title: "Orchestrator", cwd: "/tmp")
        let child = Session(id: "c1", title: "Worker", cwd: "/tmp", parentSessionId: "s1")
        let summary = SessionChildSummary(children: [child])

        let plain = SessionRow(
            session: session, isActive: false, onSelect: {}, onClose: {}
        )
        let dropTargetRow = SessionRow(
            session: session, isActive: false, isDropTarget: true, onSelect: {}, onClose: {}
        )
        let parentCollapsed = SessionRow(
            session: session, isActive: false, childSummary: summary, isExpanded: false,
            onSelect: {}, onClose: {}
        )
        let parentExpanded = SessionRow(
            session: session, isActive: false, childSummary: summary, isExpanded: true,
            onSelect: {}, onClose: {}
        )
        let childRow = SessionRow(
            session: child, isActive: false, isChild: true, onSelect: {}, onClose: {}
        )

        XCTAssertNotEqual(plain, dropTargetRow)
        XCTAssertNotEqual(plain, parentCollapsed)
        XCTAssertNotEqual(parentCollapsed, parentExpanded)
        XCTAssertTrue(parentCollapsed.accessibilityStatus.contains("1 child"))
        XCTAssertTrue(parentCollapsed.accessibilityStatus.contains("Collapsed"))
        XCTAssertTrue(parentExpanded.accessibilityStatus.contains("Expanded"))
        XCTAssertTrue(childRow.accessibilityStatus.contains("Child session"))
    }

    @MainActor
    func testSessionDropDelegateZonesAndGroupingRules() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let parent1 = Session(id: "p1", title: "Parent 1", cwd: root.path)
        let child1 = Session(id: "c1", title: "Child 1", cwd: root.path, parentSessionId: "p1")
        let child2 = Session(id: "c2", title: "Child 2", cwd: root.path, parentSessionId: "p1")
        let parent2 = Session(id: "p2", title: "Parent 2", cwd: root.path)
        let standalone = Session(id: "s1", title: "Standalone", cwd: root.path)
        let project = Project(
            id: "proj",
            name: "Main",
            cwd: root.path,
            sessions: [parent1, child1, child2, parent2, standalone],
            selectedSessionId: parent1.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )

        let topY = SessionDropDelegate.reorderZoneHeight - 1
        let midY = SessionDropDelegate.reorderZoneHeight + 8

        // Top-level childless session onto another top-level session: top edge reorders, middle groups.
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "s1", targetId: "p2", locationY: topY
            ),
            .reorder("p2")
        )
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "s1", targetId: "p2", locationY: midY
            ),
            .group("p2")
        )

        // Parent with children onto another top-level session: cannot group, so middle falls back to reorder.
        XCTAssertFalse(model.projects[0].canGroupSession("p1", underParent: "p2"))
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "p1", targetId: "p2", locationY: topY
            ),
            .reorder("p2")
        )
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "p1", targetId: "p2", locationY: midY
            ),
            .reorder("p2")
        )

        // Child onto sibling child: cannot group under a child, so middle falls back to sibling reorder.
        XCTAssertFalse(model.projects[0].canGroupSession("c2", underParent: "c1"))
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c2", targetId: "c1", locationY: topY
            ),
            .reorder("c1")
        )
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c2", targetId: "c1", locationY: midY
            ),
            .reorder("c1")
        )

        // Child onto its current parent or top-level onto a child: neither group nor reorder is allowed.
        XCTAssertFalse(model.projects[0].canGroupSession("c1", underParent: "p1"))
        XCTAssertNil(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c1", targetId: "p1", locationY: topY
            )
        )
        XCTAssertNil(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c1", targetId: "p1", locationY: midY
            )
        )
        XCTAssertNil(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "s1", targetId: "c1", locationY: midY
            )
        )
        XCTAssertNil(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "s1", targetId: "s1", locationY: midY
            )
        )

        // Child onto a different top-level parent: top edge cannot reorder across levels, middle groups.
        XCTAssertTrue(model.projects[0].canGroupSession("c1", underParent: "p2"))
        XCTAssertNil(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c1", targetId: "p2", locationY: topY
            )
        )
        let reparentTarget = try XCTUnwrap(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "c1", targetId: "p2", locationY: midY
            )
        )
        XCTAssertEqual(reparentTarget, .group("p2"))

        // End-of-list spacer always appends.
        XCTAssertEqual(
            SessionDropDelegate.resolveTarget(
                project: model.projects[0], draggedId: "s1", targetId: "", locationY: midY
            ),
            .reorder("")
        )

        // Performing the resolved group action reparents c1 and c2 under p2, expands p2, and cleans up p1.
        model.toggleParentSessionExpanded("p1")
        XCTAssertTrue(model.isParentSessionExpanded("p1"))
        SessionDropDelegate.perform(reparentTarget, draggedId: "c1", projectId: project.id, model: model)
        XCTAssertTrue(model.isParentSessionExpanded("p2"))
        XCTAssertTrue(model.isParentSessionExpanded("p1"), "p1 still has c2")
        SessionDropDelegate.perform(.group("p2"), draggedId: "c2", projectId: project.id, model: model)
        XCTAssertFalse(model.isParentSessionExpanded("p1"), "p1 is cleaned up once its last child moves")
        XCTAssertEqual(
            model.projects[0].sessions.filter { $0.parentSessionId == "p2" }.map(\.id),
            ["c1", "c2"]
        )
    }

    @MainActor
    private func click(_ window: NSWindow, at point: NSPoint, count: Int) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (type, delta): (NSEvent.EventType, TimeInterval) in [(.leftMouseDown, 0), (.leftMouseUp, 0.01)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: timestamp + delta,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: count, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }
}
