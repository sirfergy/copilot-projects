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

        XCTAssertNotEqual(plain, parentCollapsed)
        XCTAssertNotEqual(parentCollapsed, parentExpanded)
        XCTAssertTrue(parentCollapsed.accessibilityStatus.contains("1 child"))
        XCTAssertTrue(parentCollapsed.accessibilityStatus.contains("Collapsed"))
        XCTAssertTrue(parentExpanded.accessibilityStatus.contains("Expanded"))
        XCTAssertTrue(childRow.accessibilityStatus.contains("Child session"))
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
