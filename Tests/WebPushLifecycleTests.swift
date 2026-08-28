import XCTest
@testable import copilot_projects
import WebPush

final class WebPushLifecycleTests: XCTestCase {
    func testOwnedWebPushPoolHandlesImmediateAndRepeatedShutdown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WebPushService.live(
            vapidConfiguration: VAPID.Configuration(
                key: VAPID.Key(), contactInformation: .email("test@example.com")
            ),
            store: WebPushSubscriptionStore(url: root.appendingPathComponent("subscriptions.json"))
        )
        service.shutdown()
        await service.shutdownAndWait()
        await service.shutdownAndWait()
        XCTAssertEqual(service.status().subscriptions, 0)
    }

    func testShutdownWaitsForManagerCleanup() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanedUp = expectation(description: "manager cleanup completed")
        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch is CancellationError {
                cleanedUp.fulfill()
            } catch {
                XCTFail("Unexpected sleep error: \(error)")
            }
        }
        let service = WebPushService(
            publicKey: VAPID.Key().id.description,
            store: WebPushSubscriptionStore(url: root.appendingPathComponent("subscriptions.json")),
            sender: UnusedPushSender(),
            managerTask: task
        )
        await service.shutdownAndWait()
        XCTAssertTrue(task.isCancelled)
        await fulfillment(of: [cleanedUp], timeout: 1)
    }
}

private struct UnusedPushSender: WebPushSending {
    func send(data: Data, to subscriber: Subscriber, eventID: UUID) async throws {
        XCTFail("Lifecycle test must not send notifications")
    }
}
