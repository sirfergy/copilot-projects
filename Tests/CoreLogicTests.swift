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

    func testCopilotExtensionTranscriptHarness() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let overlapUser = """
        {id:"overlap-user",type:"user.message",timestamp:"2026-07-12T03:00:01.123Z",
         data:{source:null,content:"overlap prompt"}}
        """
        let overlapAssistant = """
        {id:"overlap-assistant",type:"assistant.message",
         timestamp:"2026-07-12T03:00:02.456Z",
         data:{messageId:"overlap-message",content:"one response"}}
        """
        let prelude = #"""
        import { readFileSync } from "node:fs";

        let transcriptListener = null;
        const overlapUser = \#(overlapUser);
        const overlapAssistant = \#(overlapAssistant);
        const overlapIdle = {
          id:"overlap-idle",type:"session.idle",
          timestamp:"2026-07-12T03:00:03.789Z",data:{aborted:true}
        };
        const history = [];
        const timestamp = (offset) => new Date(1700000000000 + offset).toISOString();
        for (let index = 0; index < 98; index += 1) {
          history.push({
            id:`filler-user-${index}`,type:"user.message",timestamp:timestamp(index * 2),
            data:{source:null,content:`filler-${index}`}
          });
          history.push({
            id:`filler-idle-${index}`,type:"session.idle",timestamp:timestamp(index * 2 + 1),
            data:{aborted:false}
          });
        }
        history.push(
          {
            id:"hidden-user",type:"user.message",timestamp:"2026-07-12T02:59:00.111Z",
            data:{source:"internal-follow-up",content:"do not display"}
          },
          {
            id:"hidden-assistant",type:"assistant.message",
            timestamp:"2026-07-12T02:59:01.222Z",
            data:{messageId:"hidden-message",content:"automated output"}
          },
          {
            id:"hidden-idle",type:"session.idle",timestamp:"2026-07-12T02:59:02.333Z",
            data:{aborted:false}
          },
          {
            id:"scheduled-user",type:"user.message",timestamp:"2026-07-12T02:59:03.444Z",
            data:{source:"schedule-nightly",content:"scheduled prompt"}
          },
          {
            id:"scheduled-assistant",type:"assistant.message",
            timestamp:"2026-07-12T02:59:04.555Z",
            data:{messageId:"scheduled-message",content:"scheduled output"}
          },
          {
            id:"scheduled-turn-end",type:"assistant.turn_end",
            timestamp:"2026-07-12T02:59:05.666Z",data:{}
          },
          {
            id:"scheduled-idle",type:"session.idle",timestamp:"2026-07-12T02:59:06.777Z",
            data:{aborted:true}
          },
          overlapUser,
          overlapAssistant,
          {
            id:"overlap-tool-start",type:"tool.execution_start",
            timestamp:"2026-07-12T03:00:02.500Z",
            data:{toolCallId:"tool-1",toolName:"bash",toolDescription:{name:"Run tests"}}
          },
          {
            id:"overlap-tool-complete",type:"tool.execution_complete",
            timestamp:"2026-07-12T03:00:02.600Z",
            data:{toolCallId:"tool-1",success:true}
          },
          {
            id:"overlap-turn-end",type:"assistant.turn_end",
            timestamp:"2026-07-12T03:00:02.700Z",data:{}
          }
        );
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
          },
          async getEvents() {
            transcriptListener(overlapUser);
            transcriptListener(overlapAssistant);
            setImmediate(() => transcriptListener(overlapIdle));
            return history;
          }
        };
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        await new Promise((resolve) => setImmediate(resolve));
        const giantMetadata = "m".repeat(2_000_000);
        transcriptListener({
          id:"live-user",type:"user.message",timestamp:"2026-07-12T03:01:00.123Z",
          data:{source:null,content:"x".repeat(49999) + "😀"}
        });
        transcriptListener({
          id:"live-assistant",type:"assistant.message",
          timestamp:"2026-07-12T03:01:01.456Z",
          data:{messageId:"live-message",content:"live output"}
        });
        transcriptListener({
          id:"live-tool-start",type:"tool.execution_start",
          timestamp:"2026-07-12T03:01:01.500Z",
          data:{
            toolCallId:giantMetadata,
            toolName:giantMetadata,
            toolDescription:{name:giantMetadata}
          }
        });
        transcriptListener({
          id:"live-tool-complete",type:"tool.execution_complete",
          timestamp:"2026-07-12T03:01:01.600Z",
          data:{toolCallId:giantMetadata,success:true}
        });
        transcriptListener({
          id:"live-idle",type:"session.idle",timestamp:"2026-07-12T03:01:02.789Z",
          data:{aborted:false}
        });

        const encodedSnapshot = readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        );
        const snapshot = JSON.parse(encodedSnapshot);
        const find = (id) => snapshot.turns.find((turn) => turn.id === id);
        const hidden = find("hidden-user");
        const scheduled = find("scheduled-user");
        const overlap = find("overlap-user");
        const live = find("live-user");
        console.log(JSON.stringify({
          turnCount: snapshot.turns.length,
          firstId: snapshot.turns[0]?.id,
          hiddenKind: hidden?.kind,
          hiddenUserContent: hidden?.userContent,
          scheduledKind: scheduled?.kind,
          scheduledAborted: scheduled?.isAborted,
          overlapAssistantCount: overlap?.assistantMessages.length,
          overlapToolSuccess: overlap?.tools[0]?.success,
          overlapAborted: overlap?.isAborted,
          overlapEndedAt: overlap?.endedAt,
          liveUserLength: live?.userContent.length,
          liveTruncated: live?.userContent.endsWith("… truncated …"),
          liveHasTrailingHighSurrogate: /[\uD800-\uDBFF]$/.test(
            live?.userContent.split("\n")[0] || ""
          ),
          liveToolMetadataLength: live?.tools.reduce(
            (total, tool) => total + tool.id.length + tool.name.length + tool.title.length,
            0
          ),
          liveStartedAt: live?.startedAt,
          liveAssistantAt: live?.assistantMessages[0]?.timestamp,
          updatedAt: snapshot.updatedAt,
          snapshotBytes: Buffer.byteLength(encodedSnapshot)
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("harness.mjs")
        try (prelude + extensionScript + epilogue).write(
            to: scriptURL,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "COPILOT_PROJECTS_SESSION": "12345678-1234-1234-1234-123456789abc",
            "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("app.sock").path,
            "COPILOT_PROJECTS_ROOT": root.path,
        ]) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorOutput, encoding: .utf8) ?? "node harness failed"
        )
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let summary = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        XCTAssertEqual(summary?["turnCount"] as? Int, 100)
        XCTAssertEqual(summary?["firstId"] as? String, "filler-user-2")
        XCTAssertEqual(summary?["hiddenKind"] as? String, "automated")
        XCTAssertEqual(summary?["hiddenUserContent"] as? String, "")
        XCTAssertEqual(summary?["scheduledKind"] as? String, "scheduled")
        XCTAssertEqual(summary?["scheduledAborted"] as? Bool, true)
        XCTAssertEqual(summary?["overlapAssistantCount"] as? Int, 1)
        XCTAssertEqual(summary?["overlapToolSuccess"] as? Bool, true)
        XCTAssertEqual(summary?["overlapAborted"] as? Bool, true)
        XCTAssertEqual(summary?["overlapEndedAt"] as? String, "2026-07-12T03:00:03.789Z")
        XCTAssertLessThanOrEqual(summary?["liveUserLength"] as? Int ?? .max, 50_020)
        XCTAssertEqual(summary?["liveTruncated"] as? Bool, true)
        XCTAssertEqual(summary?["liveHasTrailingHighSurrogate"] as? Bool, false)
        XCTAssertLessThanOrEqual(summary?["liveToolMetadataLength"] as? Int ?? .max, 1_536)
        XCTAssertLessThanOrEqual(
            summary?["snapshotBytes"] as? Int ?? .max,
            5 * 1_024 * 1_024
        )
        XCTAssertEqual(summary?["liveStartedAt"] as? String, "2026-07-12T03:01:00.123Z")
        XCTAssertEqual(summary?["liveAssistantAt"] as? String, "2026-07-12T03:01:01.456Z")
        XCTAssertNotNil((summary?["updatedAt"] as? String)?.range(
            of: #"\.\d{3}Z$"#,
            options: .regularExpression
        ))
        XCTAssertTrue(CopilotExtension.script.contains("transcriptEventIds.clear();"))
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
