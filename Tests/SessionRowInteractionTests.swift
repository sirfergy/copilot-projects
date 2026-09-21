import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class SessionRowInteractionTests: XCTestCase {
    @MainActor
    private final class Actions: ObservableObject {
        @Published var isActive = false
        var selections = 0
        var closes = 0
        var events: [String] = []
    }

    private struct RowFixture: View {
        @ObservedObject var actions: Actions
        let session = Session(title: "Example", cwd: "/tmp")

        var body: some View {
            SessionRow(
                session: session, isActive: actions.isActive,
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
    private func withRow(_ body: (NSWindow, Actions) async throws -> Void) async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let actions = Actions()
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 280, height: 80),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RowFixture(actions: actions))
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
