import Darwin
import Foundation
import XCTest
@testable import CopilotProjectsCore

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

    func testATabIsBringingASessionBackOnlyWhileItsCommandOrCopilotRuns() {
        let tab = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let done = "6780CCA3-92AF-4506-95F2-F018A195A1A1"
        let id = "0f1e2d3c-4b5a-4000-8000-0000000000aa"
        let sessions = URL(fileURLWithPath: "/tmp/state/sessions", isDirectory: true)
        let command = "/bin/sh -c 'exec \"$0\" \"$@\"' '/opt/copilot' '--no-remote' '--resume=\(id)'"
            + " || printf 'could not resume'; exec '/bin/zsh' -l"
        func dtach(_ session: String, _ pid: pid_t) -> [String] {
            ["dtach", "-A", sessions.appendingPathComponent("\(session).sock").path, "-r", "winch", "-z", "-E",
             "/bin/zsh", "-l", "-c", command]
        }
        var snapshot = ProcessTree.Snapshot()
        snapshot.childrenOf = [30: [20], 20: [10], 31: [21]]
        snapshot.nameOf = [30: "dtach", 20: "zsh", 10: "copilot", 31: "dtach", 21: "zsh"]
        var arguments: [pid_t: [String]] = [
            30: dtach(tab, 30), 20: ["/bin/zsh", "-l", "-c", command], 10: ["/opt/copilot", "--no-remote", "--resume=\(id)"],
            // Its Copilot exited without resuming: the shell replaced the command.
            31: dtach(done, 31), 21: ["/bin/zsh", "-l"],
        ]
        let processes = [
            ProcessTree.DtachProcess(pid: 30, parentPID: 1, socketPath: dtach(tab, 30)[2], isMaster: true),
            ProcessTree.DtachProcess(pid: 31, parentPID: 1, socketPath: dtach(done, 31)[2], isMaster: true),
        ]
        func resuming() -> Set<String> {
            ProcessTree.sessionsResuming(
                copilotSessionId: id.uppercased(), in: snapshot, argumentsOf: { arguments[$0] ?? [] },
                dtachProcesses: processes, sessionsDirectory: sessions
            )
        }
        XCTAssertEqual(resuming(), [tab], "dtach's own copy of the command never counts")

        snapshot.childrenOf[20] = nil
        arguments[10] = nil
        XCTAssertEqual(resuming(), [tab], "before the shell has started Copilot")

        arguments[20] = ["/bin/zsh", "-l"]
        XCTAssertEqual(resuming(), [])

        arguments[20] = ["copilot", "--resume", id]
        XCTAssertEqual(resuming(), [tab], "typed by hand")
        XCTAssertFalse(ProcessTree.resumes(["copilot", "--resume=0f1e2d3c-4b5a-4000-8000-0000000000ab"],
                                           copilotSessionId: id))
        XCTAssertFalse(ProcessTree.resumes(["copilot", "--resume"], copilotSessionId: id))
    }
}
