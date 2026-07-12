import XCTest
@testable import CopilotProjectsCore
import CopilotProjectsProtocol
#if canImport(Darwin)
import Darwin
#endif

final class CoreLogicTests: XCTestCase {
    func testNormalizedDirectoryDecodesFileURL() {
        XCTAssertEqual(
            Paths.normalizedDirectory("file://localhost/Users/example/My%20Project"),
            "/Users/example/My Project"
        )
        XCTAssertEqual(Paths.normalizedDirectory("/tmp/plain"), "/tmp/plain")
    }

    func testSuppressSigPipeReturnsEPIPEAfterPeerCloses() {
        var sockets = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer {
            if sockets[0] >= 0 { close(sockets[0]) }
            if sockets[1] >= 0 { close(sockets[1]) }
        }
        XCTAssertTrue(SocketOptions.suppressSigPipe(on: sockets[0]))
        close(sockets[1])
        sockets[1] = -1

        var byte: UInt8 = 1
        let result = withUnsafeBytes(of: &byte) {
            Darwin.write(sockets[0], $0.baseAddress, $0.count)
        }
        XCTAssertEqual(result, -1)
        XCTAssertEqual(errno, EPIPE)
    }

    func testCLIFlagParsing() {
        let parsed = CLIMain.parseFlags([
            "--project=abc", "--session", "def", "first", "--", "--literal",
        ])
        XCTAssertEqual(parsed.flags["project"], "abc")
        XCTAssertEqual(parsed.flags["session"], "def")
        XCTAssertEqual(parsed.positionals, ["first", "--literal"])
    }

    func testCopilotExtensionTracksSchedulesAndSubagentsWithoutTools() {
        XCTAssertTrue(CopilotExtension.script.contains("session.rpc.schedule.list()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("subagent.started""#))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("session.idle""#))
        XCTAssertTrue(CopilotExtension.script.contains("await session.getEvents()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "assistant.message":"#))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "tool.execution_complete":"#))
        XCTAssertTrue(CopilotExtension.script.contains("isAborted"))
        XCTAssertTrue(CopilotExtension.script.contains(".transcript.json"))
        XCTAssertTrue(CopilotExtension.script.contains("publishTranscript();"))
        XCTAssertTrue(CopilotExtension.script.contains("removeFile(temporaryPath)"))
        XCTAssertTrue(CopilotExtension.script.contains("setScheduledTurnMarker(false)"))
        XCTAssertFalse(CopilotExtension.script.contains("joinSession({"))
        XCTAssertFalse(CopilotExtension.script.contains("removeFile(transcriptPath)"))
    }

    func testCopilotExtensionJavaScriptSyntax() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("extension.mjs")
        try CopilotExtension.script.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--check", script.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: output, encoding: .utf8) ?? "node --check failed"
        )
    }

    func testStatusNotificationKindRoundTripsOverControlProtocol() throws {
        var request = ControlRequest(command: "set-status")
        request.notification = .completed

        let encoded = try Wire.encodeLine(request)
        let decoded = try Wire.decode(ControlRequest.self, from: encoded)
        XCTAssertEqual(decoded.notification, .completed)
    }

    func testRemoteTranscriptRevisionRoundTrips() throws {
        let revision = RemoteTranscriptRevision(
            sessionId: "session",
            generation: "inode:size:modified"
        )
        let decoded = try JSONDecoder().decode(
            RemoteTranscriptRevision.self,
            from: JSONEncoder().encode(revision)
        )
        XCTAssertEqual(decoded, revision)
    }

    func testCocoaLaunchArgumentsAreAcceptedButUnknownCLIFlagsAreNot() {
        XCTAssertTrue(CLIMain.isCocoaLaunchArguments([
            "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345",
        ]))
        XCTAssertTrue(CLIMain.isCocoaLaunchArguments([
            "-ApplePersistenceIgnoreState", "YES",
        ]))
        XCTAssertFalse(CLIMain.isCocoaLaunchArguments(["--unknown"]))
        XCTAssertFalse(CLIMain.isCocoaLaunchArguments(["unknown-command"]))
    }

    func testIsolatedInstancesDoNotInstallGlobalIntegration() {
        XCTAssertTrue(Env.shouldInstallGlobalIntegration([:]))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration([
            "COPILOT_PROJECTS_NO_INSTALL": "1",
        ]))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration([
            "COPILOT_PROJECTS_STATE_DIR": "/isolated/state",
        ]))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration([
            "COPILOT_MUX_STATE_DIR": "/isolated/legacy-state",
        ]))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration([
            "COPILOT_PROJECTS_SOCKET": "/isolated/control.sock",
        ]))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration([
            "COPILOT_MUX_SOCKET": "/isolated/legacy-control.sock",
        ]))
    }

    func testDtachMasterSelectionIgnoresAttachedClient() {
        let socket = "/tmp/session.sock"
        let processes = [
            ProcessTree.DtachProcess(
                pid: 101, parentPID: 999, socketPath: socket, isMaster: false),
            ProcessTree.DtachProcess(
                pid: 202, parentPID: 101, socketPath: socket, isMaster: false),
        ]
        XCTAssertEqual(ProcessTree.dtachMaster(forSocket: socket, among: processes), 202)
    }

    func testDetachedDtachMasterSelectionUsesLaunchdParent() {
        let socket = "/tmp/session.sock"
        let processes = [
            ProcessTree.DtachProcess(
                pid: 101, parentPID: 999, socketPath: socket, isMaster: false),
            ProcessTree.DtachProcess(
                pid: 202, parentPID: 1, socketPath: socket, isMaster: false),
        ]
        XCTAssertEqual(ProcessTree.dtachMaster(forSocket: socket, among: processes), 202)
    }
}
