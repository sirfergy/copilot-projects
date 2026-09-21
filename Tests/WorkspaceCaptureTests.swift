import XCTest
import WorkspaceCaptureSupport

final class WorkspaceCaptureTests: XCTestCase {
    @MainActor
    func testNativeWorkspaceCapture() async throws {
        guard ProcessInfo.processInfo.environment["WORKSPACE_CAPTURE_ROOT"] != nil else {
            throw XCTSkip("Native capture is opt-in through the Actions workflow.")
        }
        #if DEBUG
        try await WorkspaceCaptureFixture().run()
        #else
        throw XCTSkip("Native capture requires the debug-only GUI test host.")
        #endif
    }
}
