import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import copilot_projects

final class TranscriptReloadTests: XCTestCase {
    private func writeSnapshot(sessionId: String, updatedAt: Date) throws {
        Paths.ensureStateDir()
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: updatedAt,
            copilotSessionId: "fixture-conversation",
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
    }

    @MainActor
    func testBurstSkipsSupersededLoadsAndReadsNewestSnapshot() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let firstDate = Date(timeIntervalSince1970: 1_788_633_600)
        let latestDate = firstDate.addingTimeInterval(60)
        try writeSnapshot(sessionId: sessionId, updatedAt: firstDate)
        var loads = 0
        let controller = TranscriptController(
            sessionId: sessionId,
            snapshotLoadObserver: { loads += 1 }
        )
        for _ in 0 ..< 40 {
            controller.reload(after: 0.05)
        }
        try writeSnapshot(sessionId: sessionId, updatedAt: latestDate)
        for _ in 0 ..< 100 {
            if controller.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.snapshot?.updatedAt, latestDate)
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testImmediateReloadSupersedesAnOlderDelayedLoad() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let date = Date(timeIntervalSince1970: 1_788_633_600)
        try writeSnapshot(sessionId: sessionId, updatedAt: date)
        var loads = 0
        let controller = TranscriptController(
            sessionId: sessionId,
            snapshotLoadObserver: { loads += 1 }
        )
        controller.reload(after: 0.1)
        controller.reload()
        for _ in 0 ..< 100 {
            if controller.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.snapshot?.updatedAt, date)
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testReleasedControllerDoesNotStartADelayedLoad() async throws {
        var loads = 0
        var controller: TranscriptController? = TranscriptController(
            sessionId: UUID().uuidString,
            snapshotLoadObserver: { loads += 1 }
        )
        weak var released = controller
        controller?.reload(after: 0.05)
        controller = nil
        XCTAssertNil(released)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(loads, 0)
    }
}
