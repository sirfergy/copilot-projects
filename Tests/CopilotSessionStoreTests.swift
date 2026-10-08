import Darwin
import Foundation
import XCTest
import CopilotProjectsCore

final class CopilotSessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCopilotHomeFollowsCopilotHomeWithItsTildeExpanded() {
        XCTAssertEqual(CopilotSessionStore(environment: [:], home: "/Users/me").copilotHome, "/Users/me/.copilot")
        XCTAssertEqual(CopilotSessionStore(environment: ["COPILOT_HOME": ""], home: "/Users/me").copilotHome,
                       "/Users/me/.copilot")
        XCTAssertEqual(CopilotSessionStore(environment: ["COPILOT_HOME": "~/alt"], home: "/Users/me").copilotHome,
                       "/Users/me/alt")
        XCTAssertEqual(CopilotSessionStore(environment: ["COPILOT_HOME": "~"], home: "/Users/me").copilotHome, "/Users/me")
        let store = CopilotSessionStore(environment: ["COPILOT_HOME": "/c"], home: "/h")
        XCTAssertEqual(store.databasePath, "/c/session-store.db")
        XCTAssertEqual(store.sessionStateDirectory, "/c/session-state")
        XCTAssertEqual(store.transcriptPath(for: "0f1e2d3c-4b5a-4000-8000-000000000001"),
                       "/c/session-state/0f1e2d3c-4b5a-4000-8000-000000000001/events.jsonl")
        XCTAssertNil(store.directory(for: "../../etc"))
        XCTAssertNil(store.directory(for: ""))
    }

    func testOnlyAStrictUUIDIsASessionIdToResume() {
        XCTAssertTrue(CopilotSessionStore.isValidSessionId("0f1e2d3c-4b5a-4000-8000-000000000001"))
        XCTAssertTrue(CopilotSessionStore.isValidSessionId("0F1E2D3C-4B5A-4000-8000-000000000001"))
        XCTAssertFalse(CopilotSessionStore.isValidSessionId("0f1e2d3c-4b5a"))
        XCTAssertFalse(CopilotSessionStore.isValidSessionId("0f1e2d3c-4b5a-4000-8000-000000000001; rm -rf ~"))
    }

    func testWorkspaceYamlReadsPlainQuotedAndBlockValuesAndSkipsTheRest() throws {
        let record = CopilotSessionRecord(yaml: """
        id: 0f1e2d3c-4b5a-4000-8000-000000000001
        cwd: "/Users/me/Repos/it's \\"here\\""
        client_name: 'github/cli'
        name: |-
          Resume the pull requests

          from the window
        user_named: false
        summary_count: 2
        created_at: 2026-10-07T19:39:50.897Z
        updated_at: 2026-10-08T03:43:10Z
        """)
        XCTAssertEqual(record.id, "0f1e2d3c-4b5a-4000-8000-000000000001")
        XCTAssertEqual(record.cwd, #"/Users/me/Repos/it's "here""#)
        XCTAssertEqual(record.clientName, "github/cli")
        XCTAssertEqual(record.name, "Resume the pull requests\n\nfrom the window")
        XCTAssertEqual(record.displayName, "Resume the pull requests")
        XCTAssertEqual(try XCTUnwrap(record.createdAt).timeIntervalSince1970, 1_791_401_990.897, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(record.updatedAt).timeIntervalSince1970, 1_791_430_990, accuracy: 0.001)

        let sparse = CopilotSessionRecord(yaml: "cwd: /tmp\nname: 'It''s mine'\nupdated_at: soon\n")
        XCTAssertNil(sparse.id)
        XCTAssertNil(sparse.clientName)
        XCTAssertNil(sparse.updatedAt, "an unreadable date is missing, not now")
        XCTAssertEqual(sparse.name, "It's mine")
        XCTAssertNil(CopilotSessionRecord(yaml: "name: ''").displayName)

        let store = CopilotSessionStore(environment: ["COPILOT_HOME": root.path])
        XCTAssertNil(store.record(for: "0f1e2d3c-4b5a-4000-8000-000000000001"), "no workspace.yaml, no record")
        let directory = try XCTUnwrap(store.directory(for: "0f1e2d3c-4b5a-4000-8000-000000000001"))
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try Data("cwd: /work\n".utf8).write(to: URL(fileURLWithPath: directory).appendingPathComponent("workspace.yaml"))
        XCTAssertEqual(store.record(for: "0f1e2d3c-4b5a-4000-8000-000000000001")?.cwd, "/work")
    }

    func testASessionIsInUseOnlyWhileTheProcessThatLockedItLives() throws {
        let store = CopilotSessionStore(environment: ["COPILOT_HOME": root.path])
        let id = "0f1e2d3c-4b5a-4000-8000-000000000001"
        let directory = URL(fileURLWithPath: try XCTUnwrap(store.directory(for: id)))
        XCTAssertFalse(store.isInUse(id), "no folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertFalse(store.isInUse(id), "no locks")

        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        let stale = directory.appendingPathComponent("inuse.\(ended.processIdentifier).lock")
        try Data().write(to: stale)
        try Data().write(to: directory.appendingPathComponent("inuse.not-a-pid.lock"))
        XCTAssertFalse(store.isInUse(id), "a lock left by a process that ended")

        let own = directory.appendingPathComponent("inuse.\(getpid()).lock")
        let hold = directory.appendingPathComponent("inuse.\(getpid()).hold")
        try Data().write(to: own)
        try Data().write(to: hold)
        XCTAssertTrue(store.isInUse(id), "locked by a live process after it started")

        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000)], ofItemAtPath: own.path
        )
        XCTAssertFalse(store.isInUse(id), "a live process that started after the lock reuses a dead one's pid")
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: own.path)[.modificationDate] as? Date,
            Date(timeIntervalSince1970: 1_000_000), "the lock is never touched"
        )
    }
}
