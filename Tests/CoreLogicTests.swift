import XCTest
@testable import CopilotProjectsCore
import CopilotProjectsProtocol
#if canImport(Darwin)
import Darwin
#endif

func requireNodeForJavaScriptTests() throws {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["node", "--version"]
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 127 {
        throw XCTSkip("Node.js is not installed")
    }
    let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
    XCTAssertEqual(
        process.terminationStatus,
        0,
        String(data: errorOutput, encoding: .utf8) ?? "node --version failed"
    )
}

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

    func testCopilotExtensionTracksSchedulesAndSubagentsWithoutTools() throws {
        XCTAssertTrue(CopilotExtension.script.contains("session.rpc.schedule.list()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("subagent.started""#))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("session.idle""#))
        XCTAssertTrue(CopilotExtension.script.contains("session.rpc.permissions.getAllowAll()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("session.permissions_changed""#))
        XCTAssertTrue(CopilotExtension.script.contains("writeMarker(copilotSessionPath, copilotSessionId)"))
        XCTAssertTrue(CopilotExtension.script.contains("writeMarker(allowAllPath, copilotSessionId)"))
        XCTAssertTrue(CopilotExtension.script.contains("await session.getEvents()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "assistant.message":"#))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "tool.execution_complete":"#))
        XCTAssertTrue(CopilotExtension.script.contains("isAborted"))
        XCTAssertTrue(CopilotExtension.script.contains(".transcript.json"))
        XCTAssertTrue(CopilotExtension.script.contains("classifyUserMessage"))
        XCTAssertTrue(CopilotExtension.script.contains("ownsSharedFiles"))
        XCTAssertTrue(CopilotExtension.script.contains("transcript-owner.json"))
        XCTAssertTrue(CopilotExtension.script.contains("transcriptOwnerLockPath"))
        XCTAssertTrue(CopilotExtension.script.contains("owner.pid === process.pid"))
        XCTAssertTrue(CopilotExtension.script.contains("const copilotSessionId = typeof session.sessionId"))
        XCTAssertTrue(CopilotExtension.script.contains("schemaVersion: 3"))
        XCTAssertTrue(CopilotExtension.script.contains("publishTranscript();"))
        XCTAssertTrue(CopilotExtension.script.contains("removeFile(temporaryPath)"))
        XCTAssertTrue(CopilotExtension.script.contains("setScheduledTurnMarker(false)"))
        XCTAssertTrue(CopilotExtension.script.contains(
            #"session.on("user_input.requested""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            #"session.on("user_input.completed""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "session.rpc.ui.handlePendingUserInput"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "trackedUserInputs: [...pendingUserInputs.values()]"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(".user-input-response.json"))
        XCTAssertTrue(CopilotExtension.script.contains("watch(sessionsDir"))
        // The heartbeat now carries question text, so it must be written 0600.
        XCTAssertTrue(CopilotExtension.script.contains(
            "JSON.stringify(snapshot), { mode: 0o600 }"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "removeFile(userInputResponsePath)"
        ))
        let cleanupRange = try XCTUnwrap(CopilotExtension.script.range(
            of: "Clear stale answer state before any new question can be published"
        ))
        let watcherRange = try XCTUnwrap(CopilotExtension.script.range(
            of: "watch(sessionsDir"
        ))
        let listenerRange = try XCTUnwrap(CopilotExtension.script.range(
            of: #"session.on("user_input.requested""#
        ))
        XCTAssertLessThan(cleanupRange.lowerBound, listenerRange.lowerBound)
        XCTAssertLessThan(watcherRange.lowerBound, listenerRange.lowerBound)
        // The transcript turn must span a whole request, not stop at the first
        // agentic-loop turn end, and must not key suppression off parentAgentTaskId
        // (that field is present on genuine human input too).
        XCTAssertFalse(CopilotExtension.script.contains("suppressedInteractionIds"))
        XCTAssertFalse(CopilotExtension.script.contains("suppressedTurnIds"))
        XCTAssertFalse(CopilotExtension.script.contains("scheduleTranscriptTurnEndFallback"))
        XCTAssertFalse(CopilotExtension.script.contains("schemaVersion: 2"))
        XCTAssertFalse(CopilotExtension.script.contains("joinSession({"))
        XCTAssertFalse(CopilotExtension.script.contains("process.env.SESSION_ID"))
        XCTAssertFalse(CopilotExtension.script.contains("removeFile(transcriptPath)"))
    }

    func testCopilotExtensionJavaScriptSyntax() throws {
        try requireNodeForJavaScriptTests()
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
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prelude = #"""
        let transcriptListener = null;
        const history = [];
        const ts = (offset) => new Date(1700000000000 + offset).toISOString();
        // Foreground-preserving retention: 3 human turns must survive even though
        // 250 scheduled turns (well over the 200 cap) arrive afterwards.
        for (let index = 0; index < 3; index += 1) {
          history.push({
            id:`human-${index}`,type:"user.message",timestamp:ts(index * 2),
            data:{source:null,content:`human ${index}`,parentAgentTaskId:"root-task"}
          });
          history.push({
            id:`human-idle-${index}`,type:"session.idle",timestamp:ts(index * 2 + 1),
            data:{aborted:false}
          });
        }
        for (let index = 0; index < 250; index += 1) {
          history.push({
            id:`sched-${index}`,type:"user.message",timestamp:ts(1000 + index * 2),
            data:{source:"schedule-nightly",content:`sched ${index}`,parentAgentTaskId:"root-task"}
          });
          history.push({
            id:`sched-idle-${index}`,type:"session.idle",timestamp:ts(1000 + index * 2 + 1),
            data:{aborted:false}
          });
        }
        // One request that runs several agentic loop iterations. It must collapse
        // into ONE foreground turn, not fragment into automated turns.
        history.push(
          {id:"multi",type:"user.message",timestamp:ts(9000),
           data:{source:null,content:"multi request",parentAgentTaskId:"root-task"}},
          {id:"multi-ts-1",type:"assistant.turn_start",timestamp:ts(9001),
           data:{interactionId:"multi-i",turnId:"multi-t1"}},
          {id:"multi-a1",type:"assistant.message",timestamp:ts(9002),
           data:{messageId:"multi-m1",content:"first"}},
          {id:"multi-tool1-start",type:"tool.execution_start",timestamp:ts(9003),
           data:{turnId:"multi-t1",toolCallId:"multi-tool1",toolName:"bash"}},
          {id:"multi-tool1-done",type:"tool.execution_complete",timestamp:ts(9004),
           data:{turnId:"multi-t1",toolCallId:"multi-tool1",success:true}},
          {id:"multi-te-1",type:"assistant.turn_end",timestamp:ts(9005),data:{turnId:"multi-t1"}},
          {id:"multi-ts-2",type:"assistant.turn_start",timestamp:ts(9006),
           data:{interactionId:"multi-i",turnId:"multi-t2"}},
          {id:"multi-a2",type:"assistant.message",timestamp:ts(9007),
           data:{messageId:"multi-m2",content:"second"}},
          {id:"multi-tool2-start",type:"tool.execution_start",timestamp:ts(9008),
           data:{turnId:"multi-t2",toolCallId:"multi-tool2",toolName:"grep"}},
          {id:"multi-tool2-done",type:"tool.execution_complete",timestamp:ts(9009),
           data:{turnId:"multi-t2",toolCallId:"multi-tool2",success:false}},
          {id:"multi-te-2",type:"assistant.turn_end",timestamp:ts(9010),data:{turnId:"multi-t2"}},
          {id:"multi-idle",type:"session.idle",timestamp:ts(9011),data:{aborted:false}}
        );
        // A human request whose skill context is injected as a user.message must
        // not become its own turn; its work folds into the human turn.
        history.push(
          {id:"with-skill",type:"user.message",timestamp:ts(9100),
           data:{source:null,content:"invoke skill",parentAgentTaskId:"root-task"}},
          {id:"skill-ctx",type:"user.message",timestamp:ts(9101),
           data:{source:"skill-create-pr",content:"SKILL CONTEXT BLOCK"}},
          {id:"skill-a1",type:"assistant.message",timestamp:ts(9102),
           data:{messageId:"skill-m1",content:"did the skill work"}},
          {id:"skill-te",type:"assistant.turn_end",timestamp:ts(9103),data:{turnId:"skill-t"}},
          {id:"with-skill-idle",type:"session.idle",timestamp:ts(9104),data:{aborted:false}}
        );
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
          },
          async getEvents() { return history; }
        };
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        await new Promise((resolve) => setImmediate(resolve));
        const transcriptPath = `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
          + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`;
        const read = () => JSON.parse(readFileSync(transcriptPath, "utf8"));

        // A live human message must publish immediately, before the turn ends,
        // so the sender sees their input right away.
        const giantMetadata = "m".repeat(2_000_000);
        transcriptListener({
          id:"live-user",type:"user.message",timestamp:"2026-07-12T03:01:00.123Z",
          data:{source:null,content:"x".repeat(49999) + "😀",parentAgentTaskId:"root-task"}
        });
        const afterLiveUser = read();
        const livePending = afterLiveUser.turns.find((turn) => turn.id === "live-user");

        transcriptListener({
          id:"live-assistant",type:"assistant.message",
          timestamp:"2026-07-12T03:01:01.456Z",
          data:{messageId:"live-message",content:"live output"}
        });
        transcriptListener({
          id:"live-tool-start",type:"tool.execution_start",
          timestamp:"2026-07-12T03:01:01.500Z",
          data:{toolCallId:giantMetadata,toolName:giantMetadata,
            toolDescription:{name:giantMetadata}}
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

        const encodedSnapshot = readFileSync(transcriptPath, "utf8");
        const snapshot = JSON.parse(encodedSnapshot);
        const find = (id) => snapshot.turns.find((turn) => turn.id === id);
        const byKind = (kind) => snapshot.turns.filter((turn) => turn.kind === kind);
        const multi = find("multi");
        const withSkill = find("with-skill");
        const skillCtxLeaked = snapshot.turns.some((turn) =>
          turn.userContent === "SKILL CONTEXT BLOCK"
        );
        const live = find("live-user");
        console.log(JSON.stringify({
          schemaVersion: snapshot.schemaVersion,
          ownerPidIsNumber: typeof snapshot.ownerPid === "number",
          turnCount: snapshot.turns.length,
          foregroundCount: byKind("foreground").length,
          scheduledCount: byKind("scheduled").length,
          automatedCount: byKind("automated").length,
          humansPreserved: ["human-0","human-1","human-2"].every(find),
          multiKind: multi?.kind,
          multiAssistantCount: multi?.assistantMessages.length,
          multiToolCount: multi?.tools.length,
          multiToolSecondSuccess: multi?.tools[1]?.success,
          withSkillKind: withSkill?.kind,
          withSkillAssistantCount: withSkill?.assistantMessages.length,
          skillCtxLeaked,
          livePendingPresent: Boolean(livePending),
          livePendingOpen: livePending ? livePending.endedAt === null : false,
          livePendingTurnCount: afterLiveUser.turns.length,
          liveUserLength: live?.userContent.length,
          liveTruncated: live?.userContent.endsWith("… truncated …"),
          liveHasTrailingHighSurrogate: /[\uD800-\uDBFF]$/.test(
            live?.userContent.split("\n")[0] || ""
          ),
          liveToolMetadataLength: live?.tools.reduce(
            (total, tool) => total + tool.id.length + tool.name.length + tool.title.length,
            0
          ),
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
        XCTAssertEqual(summary?["schemaVersion"] as? Int, 3)
        XCTAssertEqual(summary?["ownerPidIsNumber"] as? Bool, true)
        // Retention caps the total but never evicts the human conversation.
        XCTAssertEqual(summary?["turnCount"] as? Int, 200)
        XCTAssertEqual(summary?["humansPreserved"] as? Bool, true)
        XCTAssertEqual(summary?["foregroundCount"] as? Int, 6)
        XCTAssertEqual(summary?["automatedCount"] as? Int, 0)
        // The multi-iteration request is a single foreground turn.
        XCTAssertEqual(summary?["multiKind"] as? String, "foreground")
        XCTAssertEqual(summary?["multiAssistantCount"] as? Int, 2)
        XCTAssertEqual(summary?["multiToolCount"] as? Int, 2)
        XCTAssertEqual(summary?["multiToolSecondSuccess"] as? Bool, false)
        // Injected skill context folds into the human turn, never its own turn.
        XCTAssertEqual(summary?["withSkillKind"] as? String, "foreground")
        XCTAssertEqual(summary?["withSkillAssistantCount"] as? Int, 1)
        XCTAssertEqual(summary?["skillCtxLeaked"] as? Bool, false)
        // A live human message shows immediately as an open (pending) turn.
        XCTAssertEqual(summary?["livePendingPresent"] as? Bool, true)
        XCTAssertEqual(summary?["livePendingOpen"] as? Bool, true)
        XCTAssertLessThanOrEqual(summary?["livePendingTurnCount"] as? Int ?? .max, 200)
        XCTAssertLessThanOrEqual(summary?["liveUserLength"] as? Int ?? .max, 50_020)
        XCTAssertEqual(summary?["liveTruncated"] as? Bool, true)
        XCTAssertEqual(summary?["liveHasTrailingHighSurrogate"] as? Bool, false)
        XCTAssertLessThanOrEqual(summary?["liveToolMetadataLength"] as? Int ?? .max, 1_536)
        XCTAssertLessThanOrEqual(
            summary?["snapshotBytes"] as? Int ?? .max,
            5 * 1_024 * 1_024
        )
    }

    func testCopilotExtensionTranscriptOwnershipGuard() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-owner-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        // A live owner (pid 1 is always present; process.kill(1, 0) throws EPERM,
        // which the guard treats as "alive") in a different process, even with
        // the same Copilot session id.
        try Data(#"{"copilotSessionId":"guest-session","pid":1}"#.utf8).write(
            to: sessions.appendingPathComponent("\(appSessionId).transcript-owner.json")
        )
        let transcriptURL = sessions.appendingPathComponent("\(appSessionId).transcript.json")
        try Data(#"""
        {"schemaVersion":3,"copilotSessionId":"guest-session","ownerPid":1,"turns":[{
          "id":"owned","startedAt":"2026-07-12T00:00:00.000Z","endedAt":null,
          "kind":"foreground","userContent":"OWNED","assistantMessages":[],
          "tools":[],"isAborted":false}]}
        """#.utf8).write(to: transcriptURL)

        let prelude = #"""
        let transcriptListener = null;
        const fakeSession = {
          sessionId: "guest-session",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
          },
          async getEvents() { return [
            {id:"g1",type:"user.message",timestamp:"2026-07-12T01:00:00.000Z",
             data:{source:null,content:"guest classifier output",parentAgentTaskId:"pt"}},
            {id:"g2",type:"assistant.message",timestamp:"2026-07-12T01:00:01.000Z",
             data:{messageId:"gm",content:"json"}},
            {id:"g3",type:"session.idle",timestamp:"2026-07-12T01:00:02.000Z",data:{aborted:false}}
          ]; }
        };
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        await new Promise((resolve) => setImmediate(resolve));
        const snapshot = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        ));
        console.log(JSON.stringify({
          copilotSessionId: snapshot.copilotSessionId,
          firstUserContent: snapshot.turns[0]?.userContent
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("owner.mjs")
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
            "COPILOT_PROJECTS_SESSION": appSessionId,
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
        // The guest must not clobber the live owner's transcript.
        XCTAssertEqual(summary?["copilotSessionId"] as? String, "guest-session")
        XCTAssertEqual(summary?["firstUserContent"] as? String, "OWNED")
    }

    func testCopilotExtensionRefreshesSessionMarkersWhenReclaimingOwnership() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-reclaim-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let copilotSessionId = "11111111-1111-4111-8111-111111111111"

        let prelude = #"""
        const namedListeners = new Map();
        let allowAllChecks = 0;
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: {
              getAllowAll: async () => {
                allowAllChecks += 1;
                return { enabled: true };
              }
            }
          },
          on(name, handler) {
            if (typeof name !== "function") namedListeners.set(name, handler);
          },
          async getEvents() { return []; }
        };
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        const sessionsDir = `${process.env.COPILOT_PROJECTS_ROOT}/sessions`;
        const base = `${sessionsDir}/${process.env.COPILOT_PROJECTS_SESSION}`;
        const ownerPath = `${base}.transcript-owner.json`;
        const copilotSessionPath = `${base}.copilot-session`;
        const allowAllPath = `${base}.copilot-allow-all`;
        await new Promise((resolve) => setImmediate(resolve));

        writeFileSync(copilotSessionPath, "old-session");
        writeFileSync(allowAllPath, "old-session");
        writeFileSync(ownerPath, JSON.stringify({
          copilotSessionId: "old-session",
          pid: 0
        }));

        namedListeners.get("assistant.turn_start")({
          id: "turn",
          type: "assistant.turn_start",
          timestamp: "2026-07-12T04:00:00.000Z",
          data: {}
        });

        let waited = 0;
        while (waited < 4000) {
          let sessionMarker = "";
          let allowAllMarker = "";
          try { sessionMarker = readFileSync(copilotSessionPath, "utf8"); } catch {}
          try { allowAllMarker = readFileSync(allowAllPath, "utf8"); } catch {}
          if (sessionMarker === "__COPILOT_SESSION_ID__"
              && allowAllMarker === "__COPILOT_SESSION_ID__") break;
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        const owner = JSON.parse(readFileSync(ownerPath, "utf8"));
        console.log(JSON.stringify({
          ownerSessionId: owner.copilotSessionId,
          ownerPidIsCurrent: owner.pid === process.pid,
          copilotSessionMarker: readFileSync(copilotSessionPath, "utf8"),
          allowAllMarker: readFileSync(allowAllPath, "utf8"),
          allowAllChecks
        }));
        process.exit(0);
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let scriptURL = root.appendingPathComponent("reclaim.mjs")
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
            "COPILOT_PROJECTS_SESSION": appSessionId,
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
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        XCTAssertEqual(summary["ownerSessionId"] as? String, copilotSessionId)
        XCTAssertEqual(summary["ownerPidIsCurrent"] as? Bool, true)
        XCTAssertEqual(summary["copilotSessionMarker"] as? String, copilotSessionId)
        XCTAssertEqual(summary["allowAllMarker"] as? String, copilotSessionId)
        XCTAssertGreaterThan(summary["allowAllChecks"] as? Int ?? 0, 0)
    }

    func testCopilotExtensionTranscriptByteBudgetPreservesForeground() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-bytes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let prelude = #"""
        let transcriptListener = null;
        const history = [];
        const chunk = "z".repeat(50000);
        let clock = 0;
        const ts = () => new Date(1700000000000 + (clock++) * 1000).toISOString();
        // Interleave heavy foreground and scheduled turns so the total exceeds the
        // 5MB budget; the byte trim must drop scheduled turns before foreground.
        for (let index = 0; index < 40; index += 1) {
          const scheduled = index % 2 === 1;
          history.push({
            id: `${scheduled ? "sched" : "fg"}-${index}`, type: "user.message",
            timestamp: ts(),
            data: { source: scheduled ? "schedule-x" : null, content: `turn ${index}` }
          });
          for (let m = 0; m < 4; m += 1) {
            history.push({
              id: `a-${index}-${m}`, type: "assistant.message", timestamp: ts(),
              data: { messageId: `m-${index}-${m}`, content: chunk }
            });
          }
          history.push({ id: `idle-${index}`, type: "session.idle", timestamp: ts(), data: {} });
        }
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on(name, handler) { if (typeof name === "function") transcriptListener = name; },
          async getEvents() { return history; }
        };
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        await new Promise((resolve) => setImmediate(resolve));
        const encoded = readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        );
        const snapshot = JSON.parse(encoded);
        const byKind = (kind) => snapshot.turns.filter((t) => t.kind === kind).length;
        console.log(JSON.stringify({
          bytes: Buffer.byteLength(encoded),
          foreground: byKind("foreground"),
          scheduled: byKind("scheduled")
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("bytes.mjs")
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
        XCTAssertLessThanOrEqual(summary?["bytes"] as? Int ?? .max, 5 * 1_024 * 1_024)
        // Foreground turns are preserved; scheduled turns absorb the byte pressure.
        XCTAssertEqual(summary?["foreground"] as? Int, 20)
        XCTAssertLessThan(summary?["scheduled"] as? Int ?? .max, 20)
    }

    func testCopilotExtensionPreservesMatchingSnapshotWhenHistoryFails() throws {
        let summary = try copilotExtensionHistoryFailureSummary(schemaVersion: 3)

        XCTAssertEqual(summary["schemaVersion"] as? Int, 3)
        XCTAssertEqual(summary["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(summary["turnIds"] as? [String], ["preserved-turn"])
    }

    func testCopilotExtensionRejectsLegacySnapshotWhenHistoryFails() throws {
        // A v2 snapshot predates the turn-boundary fix and may be contaminated;
        // it must be discarded, not restored.
        let summary = try copilotExtensionHistoryFailureSummary(schemaVersion: 2)

        XCTAssertEqual(summary["schemaVersion"] as? Int, 3)
        XCTAssertEqual(summary["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(summary["turnIds"] as? [String], [])
    }

    private func copilotExtensionHistoryFailureSummary(
        schemaVersion: Int
    ) throws -> [String: Any] {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-history-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let snapshotURL = sessions.appendingPathComponent("\(appSessionId).transcript.json")
        try Data("""
        {
          "schemaVersion": \(schemaVersion),
          "updatedAt": "2026-07-12T03:00:00.000Z",
          "copilotSessionId": "copilot-session",
          "turns": [{
            "id": "preserved-turn",
            "startedAt": "2026-07-12T02:59:00.000Z",
            "endedAt": "2026-07-12T02:59:01.000Z",
            "kind": "foreground",
            "userContent": "keep me",
            "assistantMessages": [],
            "tools": [],
            "isAborted": false
          }]
        }
        """.utf8).write(to: snapshotURL)

        let prelude = #"""
        let transcriptListener = null;
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
          },
          async getEvents() {
            throw new Error("transient history failure");
          }
        };
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        const snapshot = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        ));
        console.log(JSON.stringify({
          schemaVersion: snapshot.schemaVersion,
          copilotSessionId: snapshot.copilotSessionId,
          turnIds: snapshot.turns.map((turn) => turn.id)
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("history-failure.mjs")
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
            "COPILOT_PROJECTS_SESSION": appSessionId,
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
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
    }

    func testCopilotExtensionTracksBoundsAndAnswersUserInput() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-userinput-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"

        let prelude = #"""
        let transcriptListener = null;
        const namedListeners = new Map();
        const handledUserInputCalls = [];
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({enabled:false}) },
            ui: {
              handlePendingUserInput: async (payload) => {
                handledUserInputCalls.push(payload);
                return { success: true };
              },
            },
          },
          on(name, handler) {
            if (typeof name === "function") { transcriptListener = name; return; }
            namedListeners.set(name, handler);
          },
          emit(event) {
            const named = namedListeners.get(event.type);
            if (named) named(event);
            if (transcriptListener) transcriptListener(event);
          },
          async getEvents() { return []; }
        };
        globalThis.__fakeSession = fakeSession;
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: "const joinSession = async () => fakeSession;"
        )
        let epilogue = #"""

        const { existsSync, statSync } = await import("node:fs");
        const sessionsDir = `${process.env.COPILOT_PROJECTS_ROOT}/sessions`;
        const base = `${sessionsDir}/${process.env.COPILOT_PROJECTS_SESSION}`;
        const snapshotPath = `${base}.agent-activity.json`;
        const responsePath = `${base}.user-input-response.json`;
        await new Promise((resolve) => setImmediate(resolve));

        __fakeSession.emit({
          id:"ui-root",type:"user_input.requested",
          timestamp:"2026-07-12T03:00:01.000Z",
          data:{requestId:"req-root",question:"Proceed with deploy?",
            choices:["Yes, deploy","No, cancel"],allowFreeform:false}
        });
        __fakeSession.emit({
          id:"ui-sub",type:"user_input.requested",agentId:"agent-7",
          timestamp:"2026-07-12T03:00:02.000Z",
          data:{requestId:"req-sub",question:"Name it",choices:[],allowFreeform:true}
        });
        // Oversized choice: rejected entirely, never truncated or exposed.
        __fakeSession.emit({
          id:"ui-big",type:"user_input.requested",
          timestamp:"2026-07-12T03:00:03.000Z",
          data:{requestId:"req-big",question:"x",choices:["y".repeat(9000)]}
        });
        await new Promise((resolve) => setImmediate(resolve));

        const firstSnapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
        const pendingBefore = firstSnapshot.trackedUserInputs.map((u) => u.requestId);
        const rootRequest = firstSnapshot.trackedUserInputs.find(
          (u) => u.requestId === "req-root"
        );
        const subRequest = firstSnapshot.trackedUserInputs.find(
          (u) => u.requestId === "req-sub"
        );
        const snapshotMode = (statSync(snapshotPath).mode & 0o777).toString(8);

        // A stale/foreign-session response is dropped without answering.
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1,copilotSessionId:"other-session",
          requestId:"req-root",answer:"Yes, deploy",wasFreeform:false
        }));
        let waited = 0;
        while (waited < 6000 && existsSync(responsePath)) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        const staleHandled = handledUserInputCalls.length;
        const staleStillPending = JSON.parse(readFileSync(snapshotPath, "utf8"))
          .trackedUserInputs.some((u) => u.requestId === "req-root");

        // A valid verbatim-choice response is delivered over RPC and clears the
        // question from the heartbeat.
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1,copilotSessionId:"copilot-session",
          requestId:"req-root",answer:"Yes, deploy",wasFreeform:false
        }));
        waited = 0;
        while (waited < 6000 && handledUserInputCalls.length === 0) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        // Give the extension a moment to remove the response and republish.
        waited = 0;
        while (waited < 3000 && existsSync(responsePath)) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        // A question answered through the terminal clears via the SDK's
        // user_input.completed event shape.
        __fakeSession.emit({
          id:"ui-sub-complete",type:"user_input.completed",agentId:"agent-7",
          timestamp:"2026-07-12T03:00:04.000Z",
          data:{requestId:"req-sub",answer:"A name",wasFreeform:true}
        });
        await new Promise((resolve) => setImmediate(resolve));
        const afterSnapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));

        console.log(JSON.stringify({
          pendingBefore,
          rejectedBigChoice: pendingBefore.includes("req-big"),
          rootChoices: rootRequest?.choices,
          rootAllowFreeform: rootRequest?.allowFreeform,
          subAgentId: subRequest?.agentId,
          snapshotMode,
          staleHandled,
          staleStillPending,
          handledPayload: handledUserInputCalls[0],
          pendingAfter: afterSnapshot.trackedUserInputs.map((u) => u.requestId),
          responseRemoved: existsSync(responsePath) === false
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("user-input.mjs")
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
            "COPILOT_PROJECTS_SESSION": appSessionId,
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
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        XCTAssertEqual(
            (summary["pendingBefore"] as? [String])?.sorted(),
            ["req-root", "req-sub"]
        )
        XCTAssertEqual(summary["rejectedBigChoice"] as? Bool, false)
        XCTAssertEqual(summary["rootChoices"] as? [String], ["Yes, deploy", "No, cancel"])
        XCTAssertEqual(summary["rootAllowFreeform"] as? Bool, false)
        XCTAssertEqual(summary["subAgentId"] as? String, "agent-7")
        XCTAssertEqual(summary["snapshotMode"] as? String, "600")
        XCTAssertEqual(summary["staleHandled"] as? Int, 0)
        XCTAssertEqual(summary["staleStillPending"] as? Bool, true)
        let handledPayload = summary["handledPayload"] as? [String: Any]
        XCTAssertEqual(handledPayload?["requestId"] as? String, "req-root")
        let handledResponse = handledPayload?["response"] as? [String: Any]
        XCTAssertEqual(handledResponse?["answer"] as? String, "Yes, deploy")
        XCTAssertEqual(handledResponse?["wasFreeform"] as? Bool, false)
        XCTAssertEqual(summary["pendingAfter"] as? [String], [])
        XCTAssertEqual(summary["responseRemoved"] as? Bool, true)
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
