import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class HostIntegrationTests: XCTestCase {
    private final class NativeSpy: NotificationPosting {
        var events: [NotificationEvent] = []
        var dismissed: [UUID] = []
        func post(_ event: NotificationEvent) { events.append(event) }
        func dismiss(id: UUID) { dismissed.append(id) }
    }

    private final class IntegrationSpy: HostIntegration {
        var clearLocalNotification: ((UUID) -> Void)?
        var events: [NotificationEvent] = []
        var dismissed: [UUID] = []
        var calls: [String] = []
        func start() { calls.append("start") }
        func stop() { calls.append("stop") }
        func command(_ action: String) -> ControlResponse {
            calls.append(action)
            return .success("integration response")
        }
        func postNotification(_ event: NotificationEvent) { events.append(event) }
        func dismissNotification(_ id: UUID) {
            dismissed.append(id)
            clearLocalNotification?(id)
        }
        func shutdown() { calls.append("shutdown") }
        func shutdownAndWait() async { calls.append("drain") }
    }

    private func event(visible: Bool) -> NotificationEvent {
        NotificationEvent(
            kind: .completed, title: "Complete", subtitle: nil, body: nil,
            projectId: "project", sessionId: "session", isTargetVisible: visible
        )
    }

    func testStandaloneNotificationVisibilityPolicyNeedsNoIntegration() {
        let native = NativeSpy()
        let poster = HostNotificationPoster(native: native, integration: nil)
        poster.post(event(visible: true))
        poster.post(event(visible: false))
        XCTAssertEqual(native.events.count, 1)
        XCTAssertFalse(native.events[0].isTargetVisible)
    }

    func testOptionalIntegrationReceivesEventsWithoutChangingNativePolicy() {
        let native = NativeSpy()
        let integration = IntegrationSpy()
        let poster = HostNotificationPoster(native: native, integration: integration)
        poster.post(event(visible: true))
        poster.post(event(visible: false))
        XCTAssertEqual(native.events.count, 1)
        XCTAssertEqual(integration.events.count, 2)
        XCTAssertEqual(native.events[0].id, integration.events[1].id)
    }

    func testDismissRemovesTheMacBannerAndClearsIntegrationDevices() {
        let standaloneNative = NativeSpy()
        let standalone = HostNotificationPoster(native: standaloneNative, integration: nil)
        let first = UUID()
        standalone.dismiss(id: first)
        XCTAssertEqual(standaloneNative.dismissed, [first])

        let native = NativeSpy()
        let integration = IntegrationSpy()
        let poster = HostNotificationPoster(native: native, integration: integration)
        let second = UUID()
        poster.dismiss(id: second)
        XCTAssertEqual(native.dismissed, [second])
        XCTAssertEqual(integration.dismissed, [second])

        let composite = CompositeNotificationPoster([standalone, poster])
        let third = UUID()
        composite.dismiss(id: third)
        XCTAssertEqual(standaloneNative.dismissed, [first, third])
        XCTAssertEqual(native.dismissed, [second, third])
        XCTAssertEqual(integration.dismissed, [second, third])
    }

    func testUnsupportedCommandsPreserveSettingsAndInjectedLifecycleStopsOnce() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(stateRepository: StateRepository(path: root.appendingPathComponent("state.json")))
        let enabled = UserDefaults.standard.object(forKey: "remoteAccessEnabled") as? Bool
        for action in ["enable", "disable", "status"] {
            var request = ControlRequest(command: "remote")
            request.action = action
            let response = model.handle(request)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.error, "This build does not include a remote integration.")
        }
        XCTAssertEqual(UserDefaults.standard.object(forKey: "remoteAccessEnabled") as? Bool, enabled)

        let integration = IntegrationSpy()
        model.attach(integration: integration)
        model.startIntegration()
        var statusRequest = ControlRequest(command: "remote")
        statusRequest.action = "status"
        XCTAssertTrue(model.handle(statusRequest).ok)
        model.beginTermination()
        model.beginTermination()
        XCTAssertEqual(integration.calls, ["start", "status", "stop"])
    }
}
