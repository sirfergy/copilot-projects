import XCTest
@testable import CopilotProjectsCore
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
        XCTAssertTrue(CopilotExtension.script.contains("rmSync(scheduledTurnPath, { force: true })"))
        XCTAssertFalse(CopilotExtension.script.contains("tools:"))
    }

    func testStatusNotificationKindRoundTripsOverControlProtocol() throws {
        var request = ControlRequest(command: "set-status")
        request.notification = .completed

        let encoded = try Wire.encodeLine(request)
        let decoded = try Wire.decode(ControlRequest.self, from: encoded)
        XCTAssertEqual(decoded.notification, .completed)
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
