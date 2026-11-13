import XCTest
import AppKit
import CopilotProjectsCore
@testable import CopilotProjectsHost

/// Temporary, with StatusShadow.swift: both go when the other status sources do.
@MainActor
final class StatusShadowTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        _ = NSApplication.shared
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func logged(_ shadow: StatusShadow) throws -> [[String: Any]] {
        shadow.queue.sync {}
        return try String(contentsOf: shadow.url, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testASleepEndsADisagreementAtTheLastPassBeforeIt() throws {
        let session = Session(title: "sleep", cwd: root.path)
        let sid = session.id
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(name: "sleep", cwd: root.path, sessions: [session])],
            selectedProjectId: nil))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remotePromptLiveSessions: { _ in [sid] }
        )
        let start = Date()
        let awake = ProcessInfo.processInfo.systemUptime
        func pass(_ wall: TimeInterval, _ uptime: TimeInterval) {
            model.recordStatusShadow(now: start.addingTimeInterval(wall), uptime: awake + uptime)
        }
        // There is no tracker, so tracker-only holds the idle it first saw. Then
        // the status shown says running.
        pass(0, 0)
        model.setStatus(.running, sessionId: sid)
        // Two passes a second apart, ten minutes with no pass while the Mac is
        // awake, then a ten-minute sleep: only the uptime clock tells them apart.
        pass(1, 1)
        pass(2, 2)
        pass(602, 602)
        pass(1_202, 603)
        let status = try logged(model.statusShadow).filter { $0["what"] as? String == "status" }
        XCTAssertEqual(status.map { $0["over"] as? Bool == true }, [false, true, false])
        XCTAssertEqual(
            status.map { $0["t"] as? Int64 },
            [1, 602, 1_202].map { Int64(start.addingTimeInterval($0).timeIntervalSince1970 * 1_000) },
            "the disagreement ends at the last pass before the sleep and starts again after it")
    }

    func testAClosedSessionEndsItsDisagreementAndTheLogStaysBounded() throws {
        var shadow = StatusShadow(directory: root, maximumBytes: 2_000)
        let session = Session(title: "bounded", cwd: root.path)
        for index in 0...40 {
            shadow.note(
                "status", session: session, shown: index.isMultiple(of: 2) ? "Running" : "Idle",
                tracker: "Idle", state: .held, live: true, now: Date())
        }
        shadow.end(except: [], now: Date())
        shadow.end(except: [], now: Date())

        let last = try XCTUnwrap(logged(shadow).last)
        XCTAssertEqual(last["over"] as? Bool, true)
        XCTAssertEqual(last["sid"] as? String, session.id)
        XCTAssertNil(last["shown"])
        for url in [shadow.url, shadow.url.appendingPathExtension("1")] {
            let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
            XCTAssertGreaterThan(size, 0)
            XCTAssertLessThanOrEqual(size, 2_000)
        }
        let all = try [shadow.url.appendingPathExtension("1"), shadow.url]
            .map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertEqual(all.components(separatedBy: "\"over\":true").count - 1, 1, "an ended session logs once")
    }
}
