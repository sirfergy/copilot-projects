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

    /// Runs the extension's real catalog mapping against a fixture shaped like an
    /// actual `rpc.model.list()` response. The RPC types its entries as
    /// `unknown[]` and returns raw snake_case CAPI objects, so a camelCase-only
    /// mapping silently publishes a catalog with no reasoning efforts, no long
    /// context, and no categories — which is exactly what shipped before.
    func testCopilotExtensionNormalizesSnakeCaseModelCatalog() throws {
        try requireNodeForJavaScriptTests()
        guard let start = CopilotExtension.script.range(of: "function pickKey"),
              let end = CopilotExtension.script.range(of: "async function refreshModels")
        else {
            return XCTFail("catalog mapping helpers not found in extension script")
        }
        let mapping = String(CopilotExtension.script[start.lowerBound..<end.lowerBound])

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("mapping.mjs")
        try (mapping + Self.modelCatalogAssertions).write(
            to: script,
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: output, encoding: .utf8) ?? "catalog mapping assertions failed"
        )
    }

    private static let modelCatalogAssertions = #"""

    function check(condition, message) {
        if (!condition) {
            console.error("FAIL: " + message);
            process.exitCode = 1;
        }
    }

    // Shaped like a real `rpc.model.list()` entry: snake_case CAPI objects.
    const snakeCase = normalizeAvailableModels([
        {
            id: "gpt-5.6-sol",
            name: "GPT-5.6 Sol",
            model_picker_category: "powerful",
            model_picker_enabled: true,
            policy: { state: "enabled" },
            capabilities: { supports: { reasoning_effort: ["none", "low", "high"] } },
            billing: { token_prices: { long_context: { input_price: 300 } } },
        },
        {
            id: "claude-haiku-4.5",
            name: "Claude Haiku 4.5",
            model_picker_category: "lightweight",
            model_picker_enabled: true,
            capabilities: { supports: { vision: true } },
            billing: { token_prices: {} },
        },
        {
            id: "gated-model",
            name: "Gated Model",
            model_picker_enabled: false,
            capabilities: {},
            billing: {},
        },
        {
            id: "policy-gated",
            name: "Policy Gated",
            policy: { state: "disabled" },
            capabilities: {},
            billing: {},
        },
    ]);

    check(snakeCase.length === 4, "expected all four entries, got " + snakeCase.length);

    const sol = snakeCase[0];
    check(
        JSON.stringify(sol.supportedReasoningEfforts) === JSON.stringify(["none", "low", "high"]),
        "reasoning efforts must come from capabilities.supports.reasoning_effort, got "
            + JSON.stringify(sol.supportedReasoningEfforts)
    );
    check(sol.longContextAvailable === true, "long context must come from billing.token_prices.long_context");
    check(sol.category === "powerful", "category must come from model_picker_category");
    check(sol.disabled !== true, "an enabled model must not be marked disabled");

    const haiku = snakeCase[1];
    check(haiku.supportedReasoningEfforts === undefined, "a model without reasoning support must omit efforts");
    check(haiku.longContextAvailable === false, "a model without a long context tier must report false");
    check(haiku.category === "lightweight", "lightweight category must round-trip");

    check(snakeCase[2].disabled === true, "model_picker_enabled:false must mark the model disabled");
    check(snakeCase[3].disabled === true, "policy.state:disabled must mark the model disabled");

    // The documented camelCase `Model` shape must keep working if the CLI ever
    // normalizes the payload.
    const camelCase = normalizeAvailableModels([
        {
            id: "camel",
            name: "Camel",
            modelPickerCategory: "versatile",
            supportedReasoningEfforts: ["low", "high"],
            defaultReasoningEffort: "high",
            billing: { tokenPrices: { longContext: { inputPrice: 1 } } },
        },
    ]);
    check(camelCase[0].category === "versatile", "camelCase category must still map");
    check(
        JSON.stringify(camelCase[0].supportedReasoningEfforts) === JSON.stringify(["low", "high"]),
        "camelCase efforts must still map"
    );
    check(camelCase[0].defaultReasoningEffort === "high", "camelCase default effort must still map");
    check(camelCase[0].longContextAvailable === true, "camelCase long context must still map");

    // `supports.reasoningEffort` is typed as a boolean, so it must not become a list.
    const boolEffort = normalizeAvailableModels([
        { id: "b", name: "B", capabilities: { supports: { reasoningEffort: true } }, billing: {} },
    ]);
    check(
        boolEffort[0].supportedReasoningEfforts === undefined,
        "a boolean reasoningEffort capability must not produce an effort list"
    );

    """#

    func testCopilotExtensionTracksSchedulesAndSubagentsWithoutTools() throws {
        XCTAssertTrue(CopilotExtension.script.contains("session.rpc.schedule.list()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("subagent.started""#))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("session.idle""#))
        XCTAssertTrue(CopilotExtension.script.contains("session.rpc.permissions.getAllowAll()"))
        XCTAssertTrue(CopilotExtension.script.contains(#"session.on("session.permissions_changed""#))
        XCTAssertTrue(CopilotExtension.script.contains("writeMarker(copilotSessionPath, copilotSessionId)"))
        XCTAssertTrue(CopilotExtension.script.contains("writeMarker(allowAllPath, copilotSessionId)"))
        XCTAssertTrue(CopilotExtension.script.contains("await sdkHistoryWithTimeout()"))
        XCTAssertTrue(CopilotExtension.script.contains("scheduleDurableReconcile(0)"))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "assistant.message":"#))
        XCTAssertTrue(CopilotExtension.script.contains(#"case "tool.execution_complete":"#))
        XCTAssertTrue(CopilotExtension.script.contains("isAborted"))
        XCTAssertTrue(CopilotExtension.script.contains(".transcript.json"))
        XCTAssertTrue(CopilotExtension.script.contains("classifyUserMessage"))
        XCTAssertTrue(CopilotExtension.script.contains("ownsSharedFiles"))
        XCTAssertTrue(CopilotExtension.script.contains("transcript-owner.json"))
        XCTAssertTrue(CopilotExtension.script.contains("transcriptOwnerLockPath"))
        XCTAssertTrue(CopilotExtension.script.contains("owner.pid === process.pid"))
        XCTAssertTrue(CopilotExtension.script.contains(
            "appSessionResolution.native ? {appSessionId} : {}"
        ))
        XCTAssertTrue(CopilotExtension.script.contains("const copilotSessionId = typeof session.sessionId"))
        XCTAssertTrue(CopilotExtension.script.contains(#""resolve-session", "--pid""#))
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
        // Elicitation support: gated events need registerInterest, and the
        // extension must observe + expose + resolve elicitation.requested.
        XCTAssertTrue(CopilotExtension.script.contains(
            #"session.on("elicitation.requested""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            #"session.on("elicitation.completed""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "session.rpc.ui.handlePendingElicitation"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "synthetic::durable-ask-user::"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "registerInterest({ eventType })"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            #""user_input.requested", "elicitation.requested""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains("await releaseEventInterests()"))
        XCTAssertTrue(CopilotExtension.script.contains("result?.success === true"))
        XCTAssertTrue(CopilotExtension.script.contains(#"process.once("exit", cleanupSharedFiles)"#))
        XCTAssertTrue(CopilotExtension.script.contains(".elicitation-response.json"))
        XCTAssertTrue(CopilotExtension.script.contains(".user-input-response.json"))
        XCTAssertTrue(CopilotExtension.script.contains("watch(sessionsDir"))
        // The heartbeat now carries question text, so it must be written 0600.
        XCTAssertTrue(CopilotExtension.script.contains(
            "JSON.stringify(snapshot), { mode: 0o600 }"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "removeFile(userInputResponsePath)"
        ))
        // Model info: the heartbeat seeds the effective model from
        // start/resume/model_change — for both live events and replayed history,
        // so a session whose model was set before we joined is still captured.
        XCTAssertTrue(CopilotExtension.script.contains(
            #"session.on("session.model_change""#
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "model: currentModel"
        ))
        XCTAssertTrue(CopilotExtension.script.contains(
            "applyModelFromEvent(event)"
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
        let registrationRange = try XCTUnwrap(CopilotExtension.script.range(
            of: "await registerEventInterest(eventType)"
        ))
        let shutdownRange = try XCTUnwrap(CopilotExtension.script.range(
            of: #"process.once("SIGTERM""#
        ))
        XCTAssertLessThan(cleanupRange.lowerBound, listenerRange.lowerBound)
        XCTAssertLessThan(watcherRange.lowerBound, listenerRange.lowerBound)
        XCTAssertLessThan(listenerRange.lowerBound, registrationRange.lowerBound)
        XCTAssertLessThan(shutdownRange.lowerBound, registrationRange.lowerBound)
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

    func testCopilotExtensionUsesNativeSessionResolver() throws {
        try requireNodeForJavaScriptTests()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let expected = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let resolver = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' '\(expected)'
        """.write(to: resolver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: resolver.path
        )

        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: #"const joinSession = async () => ({sessionId:"copilot-session"});"#
        )
        let script = root.appendingPathComponent("resolver.mjs")
        try (extensionScript + #"""

        console.log(JSON.stringify({appSessionId, native: appSessionResolution.native}));
        """#).write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": root.path,
            "COPILOT_PROJECTS_SESSION": "6780CCA3-92AF-4506-95F2-F018A195A1A1",
            "COPILOT_PROJECTS_SOCKET": "",
        ]) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(data: errorOutput, encoding: .utf8) ?? "node resolver failed"
        )
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let result = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        XCTAssertEqual(result?["appSessionId"] as? String, expected)
        XCTAssertEqual(result?["native"] as? Bool, true)
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
        // Fill the transcript entirely with human turns, then overflow it with
        // scheduled turns. The later resume notice must survive the 200-turn cap
        // without allowing scheduled work to displace recent human conversation.
        for (let index = 0; index < 197; index += 1) {
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
          {id:"skill-complete-start",type:"tool.execution_start",timestamp:ts(9102.1),
           data:{toolCallId:"skill-complete",toolName:"task_complete",
             arguments:{summary:"Replay task completed."}}},
          {id:"skill-complete-done",type:"tool.execution_complete",timestamp:ts(9102.2),
           data:{toolCallId:"skill-complete",success:true,
             result:{content:[{type:"text",text:"non-string history result"}]}}},
          {id:"skill-session-complete",type:"session.task_complete",timestamp:ts(9102.25),
           data:{summary:"Replay task completed."}},
          {id:"skill-summary-duplicate",type:"assistant.message",timestamp:ts(9102.3),
           data:{messageId:"skill-summary-message",content:"Replay task completed."}},
          {id:"skill-te",type:"assistant.turn_end",timestamp:ts(9103),data:{turnId:"skill-t"}},
          {id:"with-skill-idle",type:"session.idle",timestamp:ts(9104),data:{aborted:false}}
        );
        // A killed process can resume with a dangling assistant turn and no
        // persisted shutdown/idle event. Replay must close it as stopped and
        // retain only the newest resume boundary.
        history.push(
          {id:"restart-user",type:"user.message",timestamp:ts(9200),
           data:{source:null,content:"before restart",parentAgentTaskId:"root-task"}},
          {id:"restart-turn-start",type:"assistant.turn_start",timestamp:ts(9201),
           data:{turnId:"restart-turn"}},
          {id:"restart-assistant",type:"assistant.message",timestamp:ts(9202),
           data:{messageId:"restart-message",content:"restart answer"}},
          {id:"resume-old",type:"session.resume",timestamp:ts(9203),data:{}},
          {id:"resume-latest",type:"session.resume",timestamp:ts(9204),data:{}},
          {id:"ignored-warning",type:"session.warning",timestamp:ts(9205),
           data:{warningType:"mcp",message:"MCP startup chatter"}},
          {id:"ignored-system",type:"system.message",timestamp:ts(9206),
           data:{role:"system",content:"SECRET SYSTEM INSTRUCTIONS"}}
        );
        history.push(
          {id:"permission-auto-request",type:"permission.requested",timestamp:ts(9300),
           data:{requestId:"permission-auto",permissionRequest:{kind:"read"}}},
          {id:"permission-auto-complete",type:"permission.completed",timestamp:ts(9301),
           data:{requestId:"permission-auto",result:{kind:"approved"}}},
          // A completion observed before a queued/replayed request must tombstone it.
          {id:"permission-late-complete",type:"permission.completed",timestamp:ts(9302),
           data:{requestId:"permission-late",result:{kind:"approved"}}},
          {id:"permission-late-request",type:"permission.requested",timestamp:ts(9303),
           data:{requestId:"permission-late",permissionRequest:{kind:"mcp"}}},
          {id:"permission-idle-request",type:"permission.requested",timestamp:ts(9304),
           data:{requestId:"permission-idle",permissionRequest:{kind:"write"}}},
          {id:"permission-idle",type:"session.idle",timestamp:ts(9305),
           data:{aborted:false}},
          {id:"permission-real-request",type:"permission.requested",timestamp:ts(9306),
           data:{requestId:"permission-real",permissionRequest:{kind:"custom-tool"}}},
          {id:"subagent-idle",type:"session.idle",timestamp:ts(9307),
           agentId:"subagent-1",data:{aborted:false}}
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
        const activityPath = `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
          + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`;
        const read = () => JSON.parse(readFileSync(transcriptPath, "utf8"));
        const readActivity = () => JSON.parse(readFileSync(activityPath, "utf8"));
        const afterReplay = read();
        const activityAfterReplay = readActivity();
        const replayFind = (id) =>
          afterReplay.turns.find((turn) => turn.id === id);
        const replayRestart = replayFind("restart-user");
        const replayResumeTurns = afterReplay.turns.filter(
          (turn) => turn.id.startsWith("session-resume-")
        );
        const replayLeakedInternalText = afterReplay.turns.some((turn) =>
          turn.assistantMessages.some((message) =>
            message.content.includes("MCP startup chatter")
              || message.content.includes("SECRET SYSTEM INSTRUCTIONS")
          )
        );
        transcriptListener({
          id:"permission-real-complete",type:"permission.completed",
          timestamp:"2026-07-12T03:00:00.000Z",
          data:{requestId:"permission-real",result:{kind:"approved"}}
        });
        const activityAfterPermissionComplete = readActivity();

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
        // Fill the disclosure array before task_complete. Its separate session
        // event must still surface the summary when no TranscriptTool can be added.
        for (let index = 0; index < 405; index += 1) {
          transcriptListener({
            id:`cap-tool-start-${index}`,type:"tool.execution_start",
            timestamp:"2026-07-12T03:01:01.700Z",
            data:{toolCallId:`cap-tool-${index}`,toolName:"bash"}
          });
          transcriptListener({
            id:`cap-tool-done-${index}`,type:"tool.execution_complete",
            timestamp:"2026-07-12T03:01:01.800Z",
            data:{toolCallId:`cap-tool-${index}`,success:true}
          });
        }
        transcriptListener({
          id:"live-complete-start",type:"tool.execution_start",
          timestamp:"2026-07-12T03:01:01.900Z",
          data:{toolCallId:"live-complete",toolName:"task_complete",
            arguments:{summary:"Live task completed."}}
        });
        transcriptListener({
          id:"live-complete-done",type:"tool.execution_complete",
          timestamp:"2026-07-12T03:01:02.000Z",
          data:{toolCallId:"live-complete",success:true,
            result:{content:"Live task completed.\n\nUNSAFE REVIEWER TEXT",
              detailedContent:"✓ Task completed: Live task completed.\n\nUNSAFE REVIEWER TEXT"}}
        });
        transcriptListener({
          id:"live-session-complete",type:"session.task_complete",
          timestamp:"2026-07-12T03:01:02.050Z",
          data:{summary:"Live task completed.",success:true}
        });
        transcriptListener({
          id:"live-summary-duplicate",type:"assistant.message",
          timestamp:"2026-07-12T03:01:02.100Z",
          data:{messageId:"live-summary-message",content:"Live task completed."}
        });
        transcriptListener({
          id:"failed-complete-start",type:"tool.execution_start",
          timestamp:"2026-07-12T03:01:02.200Z",
          data:{toolCallId:"failed-complete",toolName:"task_complete",
            arguments:{summary:"Failed task must not surface."}}
        });
        transcriptListener({
          id:"failed-complete-done",type:"tool.execution_complete",
          timestamp:"2026-07-12T03:01:02.300Z",
          data:{toolCallId:"failed-complete",success:false,
            result:{content:"Failed task must not surface."}}
        });
        transcriptListener({
          id:"failed-session-complete",type:"session.task_complete",
          timestamp:"2026-07-12T03:01:02.350Z",
          data:{summary:"Failed task must not surface.",success:false}
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
        const replaySummaryCount = withSkill?.assistantMessages.filter(
          (message) => message.content === "Replay task completed."
        ).length;
        const liveSummaryCount = live?.assistantMessages.filter(
          (message) => message.content === "Live task completed."
        ).length;
        const failedSummaryCount = live?.assistantMessages.filter(
          (message) => message.content === "Failed task must not surface."
        ).length;
        const reviewerTextLeaked = live?.assistantMessages.some(
          (message) => message.content.includes("UNSAFE REVIEWER TEXT")
        );
        const liveTaskCompleteTool = live?.tools.find(
          (tool) => tool.name === "task_complete"
        );
        const toolKeysAreExact = live?.tools.every(
          (tool) => Object.keys(tool).sort().join(",")
            === "id,name,success,title"
        );
        console.log(JSON.stringify({
          schemaVersion: snapshot.schemaVersion,
          ownerPidIsNumber: typeof snapshot.ownerPid === "number",
          turnCount: snapshot.turns.length,
          foregroundCount: byKind("foreground").length,
          scheduledCount: byKind("scheduled").length,
          automatedCount: byKind("automated").length,
          humansPreserved: ["human-1","human-100","human-195"].every(find),
          multiKind: multi?.kind,
          multiAssistantCount: multi?.assistantMessages.length,
          multiToolCount: multi?.tools.length,
          multiToolSecondSuccess: multi?.tools[1]?.success,
          withSkillKind: withSkill?.kind,
          withSkillAssistantCount: withSkill?.assistantMessages.length,
          replaySummaryCount,
          skillCtxLeaked,
          livePendingPresent: Boolean(livePending),
          livePendingOpen: livePending ? livePending.endedAt === null : false,
          livePendingTurnCount: afterLiveUser.turns.length,
          liveUserLength: live?.userContent.length,
          liveTruncated: live?.userContent.endsWith("… truncated …"),
          liveHasTrailingHighSurrogate: /[\uD800-\uDBFF]$/.test(
            live?.userContent.split("\n")[0] || ""
          ),
          liveMaxToolMetadataLength: Math.max(
            0,
            ...(live?.tools || []).map(
              (tool) => tool.id.length + tool.name.length + tool.title.length
            )
          ),
          liveSummaryCount,
          failedSummaryCount,
          reviewerTextLeaked,
          liveTaskCompleteToolPresent: Boolean(liveTaskCompleteTool),
          toolKeysAreExact,
          replayRestartEnded: replayRestart?.endedAt,
          replayRestartAborted: replayRestart?.isAborted,
          replayResumeTurnCount: replayResumeTurns.length,
          replayResumeTurnId: replayResumeTurns[0]?.id,
          replayResumeMessage: replayResumeTurns[0]?.assistantMessages[0]?.content,
          replayLeakedInternalText,
          replayPendingPermissionIds:
            activityAfterReplay.pendingPermissionRequestIds,
          completedPendingPermissionIds:
            activityAfterPermissionComplete.pendingPermissionRequestIds,
          permissionKeyPresentAfterReplay:
            Object.prototype.hasOwnProperty.call(
              activityAfterReplay,
              "pendingPermissionRequestIds"
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
            "HOME": root.path,
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
        XCTAssertEqual(summary?["foregroundCount"] as? Int, 200)
        XCTAssertEqual(summary?["automatedCount"] as? Int, 0)
        // The multi-iteration request is a single foreground turn.
        XCTAssertEqual(summary?["multiKind"] as? String, "foreground")
        XCTAssertEqual(summary?["multiAssistantCount"] as? Int, 2)
        XCTAssertEqual(summary?["multiToolCount"] as? Int, 2)
        XCTAssertEqual(summary?["multiToolSecondSuccess"] as? Bool, false)
        // Injected skill context folds into the human turn, never its own turn.
        XCTAssertEqual(summary?["withSkillKind"] as? String, "foreground")
        XCTAssertEqual(summary?["withSkillAssistantCount"] as? Int, 2)
        XCTAssertEqual(summary?["replaySummaryCount"] as? Int, 1)
        XCTAssertEqual(summary?["skillCtxLeaked"] as? Bool, false)
        // A live human message shows immediately as an open (pending) turn.
        XCTAssertEqual(summary?["livePendingPresent"] as? Bool, true)
        XCTAssertEqual(summary?["livePendingOpen"] as? Bool, true)
        XCTAssertLessThanOrEqual(summary?["livePendingTurnCount"] as? Int ?? .max, 200)
        XCTAssertLessThanOrEqual(summary?["liveUserLength"] as? Int ?? .max, 50_020)
        XCTAssertEqual(summary?["liveTruncated"] as? Bool, true)
        XCTAssertEqual(summary?["liveHasTrailingHighSurrogate"] as? Bool, false)
        XCTAssertLessThanOrEqual(
            summary?["liveMaxToolMetadataLength"] as? Int ?? .max,
            1_536
        )
        XCTAssertEqual(summary?["liveSummaryCount"] as? Int, 1)
        XCTAssertEqual(summary?["failedSummaryCount"] as? Int, 0)
        XCTAssertEqual(summary?["reviewerTextLeaked"] as? Bool, false)
        XCTAssertEqual(summary?["liveTaskCompleteToolPresent"] as? Bool, false)
        XCTAssertEqual(summary?["toolKeysAreExact"] as? Bool, true)
        XCTAssertNotNil(summary?["replayRestartEnded"] as? String)
        XCTAssertEqual(summary?["replayRestartAborted"] as? Bool, true)
        XCTAssertEqual(summary?["replayResumeTurnCount"] as? Int, 1)
        XCTAssertEqual(
            summary?["replayResumeTurnId"] as? String,
            "session-resume-resume-latest"
        )
        XCTAssertEqual(
            summary?["replayResumeMessage"] as? String,
            "Session resumed. Terminal startup details are available in Terminal."
        )
        XCTAssertEqual(summary?["replayLeakedInternalText"] as? Bool, false)
        XCTAssertEqual(
            summary?["replayPendingPermissionIds"] as? [String],
            ["permission-real"]
        )
        XCTAssertEqual(
            summary?["completedPendingPermissionIds"] as? [String],
            []
        )
        XCTAssertEqual(summary?["permissionKeyPresentAfterReplay"] as? Bool, true)
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
            "HOME": root.path,
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
            "HOME": root.path,
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

    // Reclaim must be able to swap the marker without any window where a
    // concurrent reader could observe no marker at all — verified indirectly
    // here by asserting the write-then-rename temp file never lingers.
    func testCopilotExtensionReclaimLeavesNoTemporaryOwnerMarkerBehind() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-reclaim-tmp-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let copilotSessionId = "22222222-2222-4222-8222-222222222222"

        let prelude = #"""
        const namedListeners = new Map();
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({ enabled: true }) }
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
        const ownerPath = `${sessionsDir}/${process.env.COPILOT_PROJECTS_SESSION}.transcript-owner.json`;
        await new Promise((resolve) => setImmediate(resolve));

        // A dead owner (pid 0 is never a real process) triggers the reclaim
        // path inside ownsSharedFiles()/reclaimDeadOwner() the next time this
        // process needs to write shared files.
        writeFileSync(ownerPath, JSON.stringify({ copilotSessionId: "old-session", pid: 0 }));

        namedListeners.get("assistant.turn_start")({
          id: "turn",
          type: "assistant.turn_start",
          timestamp: "2026-07-12T04:00:00.000Z",
          data: {}
        });

        let waited = 0;
        let owner = null;
        while (waited < 4000) {
          try { owner = JSON.parse(readFileSync(ownerPath, "utf8")); } catch {}
          if (owner && owner.copilotSessionId === "__COPILOT_SESSION_ID__") break;
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        const entries = readdirSync(sessionsDir);
        console.log(JSON.stringify({
          leftoverTempFiles: entries.filter((name) => name.endsWith(".tmp")),
          ownerCopilotSessionId: owner?.copilotSessionId,
          ownerHasBootTime: typeof owner?.bootTime === "string" && owner.bootTime.length > 0
        }));
        process.exit(0);
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let scriptURL = root.appendingPathComponent("reclaim-tmp.mjs")
        try (
            "import { readdirSync } from \"node:fs\";\n" + prelude + extensionScript + epilogue
        ).write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": root.path,
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
        XCTAssertEqual((summary["leftoverTempFiles"] as? [String])?.isEmpty, true)
        XCTAssertEqual(summary["ownerCopilotSessionId"] as? String, copilotSessionId)
        XCTAssertEqual(summary["ownerHasBootTime"] as? Bool, true)
    }

    // A live-looking pid alone must not permanently block reclamation: after a
    // reboot the recorded pid can be reassigned to an unrelated process, and
    // `processAlive` can't tell the difference. Simulate that by recording pid
    // 1 (always "alive" per process.kill EPERM) together with a boot time that
    // does not match the current system boot time.
    func testCopilotExtensionReclaimsOwnershipWhenRecordedPidSurvivesAcrossReboot() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-reboot-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let copilotSessionId = "33333333-3333-4333-8333-333333333333"

        let prelude = #"""
        const namedListeners = new Map();
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({ enabled: true }) }
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
        const ownerPath = `${sessionsDir}/${process.env.COPILOT_PROJECTS_SESSION}.transcript-owner.json`;
        await new Promise((resolve) => setImmediate(resolve));

        // pid 1 always looks alive to processAlive(); bootTime is deliberately
        // wrong so the fix must reclaim anyway instead of blocking forever.
        writeFileSync(ownerPath, JSON.stringify({
          copilotSessionId: "old-session",
          pid: 1,
          bootTime: "stale-boot-time-from-a-previous-boot"
        }));

        namedListeners.get("assistant.turn_start")({
          id: "turn",
          type: "assistant.turn_start",
          timestamp: "2026-07-12T04:00:00.000Z",
          data: {}
        });

        let waited = 0;
        let owner = null;
        while (waited < 4000) {
          try { owner = JSON.parse(readFileSync(ownerPath, "utf8")); } catch {}
          if (owner && owner.copilotSessionId === "__COPILOT_SESSION_ID__") break;
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        console.log(JSON.stringify({
          ownerCopilotSessionId: owner?.copilotSessionId,
          ownerPidIsCurrent: owner?.pid === process.pid
        }));
        process.exit(0);
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let scriptURL = root.appendingPathComponent("reboot.mjs")
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
            "HOME": root.path,
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
        // Without the boot-time cross-check, pid 1 looks permanently alive and
        // this new session would never be able to claim ownership.
        XCTAssertEqual(summary["ownerCopilotSessionId"] as? String, copilotSessionId)
        XCTAssertEqual(summary["ownerPidIsCurrent"] as? Bool, true)
    }

    // A live owner that belongs to a DIFFERENT tab (an orphaned/cross-tab copilot
    // whose pid does not resolve to this app session) must be displaceable, so
    // this tab's real interactive session can reclaim ownership and republish its
    // transcript. Uses a stub native resolver that maps only this process to the
    // tab; the recorded owner's pid resolves to nothing.
    func testCopilotExtensionReclaimsOwnershipFromLiveForeignOwner() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-foreign-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let bin = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let copilotSessionId = "44444444-4444-4444-8444-444444444444"

        // Stub `copilot-projects resolve-session --pid N`: the hook's own pid
        // (this stub's parent) resolves to the tab; every other pid resolves to
        // nothing, so the recorded owner (pid 1) is treated as foreign.
        let resolver = bin.appendingPathComponent("copilot-projects")
        try #"""
        #!/bin/sh
        PID=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "--pid" ]; then shift; PID="$1"; fi
          shift
        done
        if [ "$PID" = "$PPID" ]; then
          printf '%s' "$COPILOT_PROJECTS_SESSION"
        else
          exit 1
        fi
        """#.write(to: resolver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: resolver.path
        )

        let prelude = #"""
        const namedListeners = new Map();
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({ enabled: true }) }
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
        const ownerPath = `${sessionsDir}/${process.env.COPILOT_PROJECTS_SESSION}.transcript-owner.json`;
        await new Promise((resolve) => setImmediate(resolve));

        // A live foreign owner: pid 1 is always "alive", no appSessionId, and the
        // stub resolver maps pid 1 to no tab. The fix must displace it.
        writeFileSync(ownerPath, JSON.stringify({
          copilotSessionId: "old-session",
          pid: 1
        }));

        namedListeners.get("assistant.turn_start")({
          id: "turn",
          type: "assistant.turn_start",
          timestamp: "2026-07-12T04:00:00.000Z",
          data: {}
        });

        let waited = 0;
        let owner = null;
        while (waited < 4000) {
          try { owner = JSON.parse(readFileSync(ownerPath, "utf8")); } catch {}
          if (owner && owner.copilotSessionId === "__COPILOT_SESSION_ID__") break;
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        console.log(JSON.stringify({
          ownerCopilotSessionId: owner?.copilotSessionId,
          ownerAppSessionId: owner?.appSessionId,
          ownerPidIsCurrent: owner?.pid === process.pid
        }));
        process.exit(0);
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let scriptURL = root.appendingPathComponent("foreign.mjs")
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
            "HOME": root.path,
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
        XCTAssertEqual(summary["ownerCopilotSessionId"] as? String, copilotSessionId)
        XCTAssertEqual(summary["ownerAppSessionId"] as? String, appSessionId)
        XCTAssertEqual(summary["ownerPidIsCurrent"] as? Bool, true)
    }

    func testCopilotExtensionDiscardsStaleAllowAllRefreshResult() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-allowall-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"
        let copilotSessionId = "22222222-2222-4222-8222-222222222222"
        try Data("old-session".utf8).write(
            to: sessions.appendingPathComponent("\(appSessionId).copilot-allow-all")
        )

        let prelude = #"""
        const namedListeners = new Map();
        let allowAllChecks = 0;
        let permissionsEvents = 0;
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: {
              getAllowAll: async () => {
                allowAllChecks += 1;
                const listener = namedListeners.get("session.permissions_changed");
                if (listener) {
                  permissionsEvents += 1;
                  listener({
                    id: `permissions-off-${allowAllChecks}`,
                    type: "session.permissions_changed",
                    data: { allowAllPermissionMode: "off" }
                  });
                }
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

        const { existsSync } = await import("node:fs");
        const allowAllPath = `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
          + `${process.env.COPILOT_PROJECTS_SESSION}.copilot-allow-all`;
        await new Promise((resolve) => setTimeout(resolve, 100));
        console.log(JSON.stringify({
          allowAllExists: existsSync(allowAllPath),
          allowAllChecks,
          permissionsEvents
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("allowall.mjs")
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
            "HOME": root.path,
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
        XCTAssertEqual(summary["allowAllExists"] as? Bool, false)
        XCTAssertGreaterThan(summary["allowAllChecks"] as? Int ?? 0, 0)
        XCTAssertGreaterThan(summary["permissionsEvents"] as? Int ?? 0, 0)
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
            "HOME": root.path,
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

    func testCopilotExtensionTailsDurableHistoryWhenSDKEventsStop() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-history-timeout-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        let copilotSessionId = "11111111-1111-4111-8111-111111111111"
        let appSessionId = "22222222-2222-4222-8222-222222222222"
        let source = copilotHome
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data((#"""
        {"id":"durable-start","type":"session.start","timestamp":"2026-07-12T00:59:59.000Z","data":{"selectedModel":"old-model"}}
        {"id":"durable-user","type":"user.message","timestamp":"2026-07-12T01:00:00.000Z","data":{"content":"durable question","source":null}}
        {"id":"durable-answer","type":"assistant.message","timestamp":"2026-07-12T01:00:01.000Z","data":{"messageId":"durable-message","content":"durable answer"}}
        {"id":"durable-idle","type":"session.idle","timestamp":"2026-07-12T01:00:02.000Z","data":{"aborted":false}}
        {"id":"shape-drift","type":"user.message","timestamp":"2026-07-12T01:00:02.500Z"}
        null
        """# + "\n").utf8).write(to: source.appendingPathComponent("events.jsonl"))
        try Data(#"""
        {"schemaVersion":3,"updatedAt":"2026-07-12T00:00:00.000Z",
         "copilotSessionId":"99999999-9999-4999-8999-999999999999",
         "turns":[{"id":"foreign","startedAt":"2026-07-12T00:00:00.000Z",
         "endedAt":null,"kind":"foreground","userContent":"FOREIGN",
         "assistantMessages":[],"tools":[],"isAborted":false}]}
        """#.utf8).write(
            to: sessions.appendingPathComponent("\(appSessionId).transcript.json")
        )

        let prelude = #"""
        let transcriptListener = null;
        let foreignObservedAtInit = false;
        const namedListeners = new Map();
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({enabled:false}) },
            model: { list: async () => [] },
            eventLog: {
              registerInterest: async ({eventType}) => ({handle:eventType}),
              releaseInterest: async () => ({success:true})
            }
          },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
            else namedListeners.set(name, handler);
          },
          async getEvents() {
            await new Promise((resolve) => setTimeout(resolve, 50));
            return [{
              id:"permission-history",type:"permission.requested",
              timestamp:"2026-07-12T00:59:58.000Z",
              data:{requestId:"permission-1"}
            }];
          }
        };
        setTimeout(() => {
          try {
            const value = JSON.parse(readFileSync(
              `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
                + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
              "utf8"
            ));
            foreignObservedAtInit = value.turns.some(
              (turn) => turn.userContent === "FOREIGN"
            );
          } catch {}
        }, 10);
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let extensionScript = CopilotExtension.script
            .replacingOccurrences(
                of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
                with: "const joinSession = async () => fakeSession;"
            )
            .replacingOccurrences(
                of: "const DURABLE_RECONCILE_DEBOUNCE_MS = 200;",
                with: "const DURABLE_RECONCILE_DEBOUNCE_MS = 5;"
            )
            .replacingOccurrences(
                of: "const DURABLE_RECONCILE_POLL_MS = 5_000;",
                with: "const DURABLE_RECONCILE_POLL_MS = 25;"
            )
        let epilogue = #"""

        const durablePath = join(
          process.env.COPILOT_HOME,
          "session-state",
          copilotSessionId,
          "events.jsonl"
        );
        function appendEvent(event) {
          writeFileSync(durablePath, JSON.stringify(event) + "\n", {flag:"a"});
        }
        async function waitForUsers(count) {
          for (let attempt = 0; attempt < 200; attempt += 1) {
            try {
              const value = JSON.parse(readFileSync(
                `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
                  + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
                "utf8"
              ));
              if (value.turns.filter((turn) => turn.userContent).length >= count) {
                return value;
              }
            } catch {}
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
          throw new Error(`timed out waiting for ${count} transcript users`);
        }
        async function waitForModel(name) {
          for (let attempt = 0; attempt < 200; attempt += 1) {
            try {
              const value = JSON.parse(readFileSync(
                `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
                  + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`,
                "utf8"
              ));
              if (value.model?.name === name) return;
            } catch {}
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
          throw new Error(`timed out waiting for model ${name}`);
        }
        async function waitForUpdatedAt(previous) {
          for (let attempt = 0; attempt < 200; attempt += 1) {
            try {
              const value = JSON.parse(readFileSync(
                `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
                  + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
                "utf8"
              ));
              if (value.updatedAt !== previous) return value;
            } catch {}
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
          throw new Error("timed out waiting for transcript update");
        }

        await waitForUsers(1);
        const permissionsAfterInit = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`,
          "utf8"
        )).pendingPermissionRequestIds;
        appendEvent({
          id:"live-model",type:"session.model_change",
          timestamp:"2026-07-12T01:00:02.900Z",
          data:{newModel:"new-model"}
        });
        appendEvent({
          id:"live-user",type:"user.message",
          timestamp:"2026-07-12T01:00:03.000Z",
          data:{content:"live question",source:null}
        });
        appendEvent({
          id:"live-answer",type:"assistant.message",
          timestamp:"2026-07-12T01:00:04.000Z",
          data:{messageId:"live-message",content:"live answer"}
        });
        appendEvent({
          id:"live-idle",type:"session.idle",
          timestamp:"2026-07-12T01:00:05.000Z",data:{aborted:false}
        });
        await waitForUsers(2);
        await waitForModel("new-model");

        const partial = JSON.stringify({
          id:"partial-user",type:"user.message",
          timestamp:"2026-07-12T01:00:05.500Z",
          data:{content:"partial question",source:null}
        });
        const split = Math.floor(partial.length / 2);
        writeFileSync(durablePath, partial.slice(0, split), {flag:"a"});
        await new Promise((resolve) => setTimeout(resolve, 60));
        const beforeCompletion = await waitForUsers(2);
        writeFileSync(
          durablePath,
          partial.slice(split) + "\n",
          {flag:"a"}
        );
        appendEvent({
          id:"partial-answer",type:"assistant.message",
          timestamp:"2026-07-12T01:00:05.600Z",
          data:{messageId:"partial-message",content:"partial answer"}
        });
        appendEvent({
          id:"partial-idle",type:"session.idle",
          timestamp:"2026-07-12T01:00:05.700Z",data:{aborted:false}
        });
        await waitForUsers(3);

        appendEvent({
          id:"shape-drift",type:"user.message",
          timestamp:"2026-07-12T01:00:06.000Z",
          data:{content:"recovered question",source:null}
        });
        appendEvent({
          id:"shape-answer",type:"assistant.message",
          timestamp:"2026-07-12T01:00:07.000Z",
          data:{messageId:"shape-message",content:"recovered answer"}
        });
        appendEvent({
          id:"shape-idle",type:"session.idle",
          timestamp:"2026-07-12T01:00:08.000Z",data:{aborted:false}
        });
        const snapshot = await waitForUsers(4);
        const usersBeforeRotation = snapshot.turns.map((turn) => turn.userContent);
        const assistantsBeforeRotation = snapshot.turns.map((turn) =>
          turn.assistantMessages.map((message) => message.content)
        );
        const stableUpdatedAt = snapshot.updatedAt;
        await new Promise((resolve) => setTimeout(resolve, 75));
        const afterIdlePolls = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        ));

        const rotatedPath = durablePath + ".rotated";
        writeFileSync(rotatedPath, readFileSync(durablePath));
        renameSync(rotatedPath, durablePath);
        transcriptListener?.({
          id:"rotation-trigger",type:"session.info",
          timestamp:"2026-07-12T01:00:08.100Z",data:{}
        });
        const afterRotation = await waitForUpdatedAt(stableUpdatedAt);

        const truncated = [
          {
            id:"rotated-user",type:"user.message",
            timestamp:"2026-07-12T01:00:09.000Z",
            data:{content:"rotated question",source:null}
          },
          {
            id:"rotated-answer",type:"assistant.message",
            timestamp:"2026-07-12T01:00:10.000Z",
            data:{messageId:"rotated-message",content:"rotated answer"}
          },
          {
            id:"rotated-idle",type:"session.idle",
            timestamp:"2026-07-12T01:00:11.000Z",data:{aborted:false}
          }
        ].map(JSON.stringify).join("\n") + "\n";
        writeFileSync(durablePath, truncated);
        transcriptListener?.({
          id:"truncation-trigger",type:"session.info",
          timestamp:"2026-07-12T01:00:08.900Z",data:{}
        });
        let finalSnapshot;
        for (let attempt = 0; attempt < 200; attempt += 1) {
          finalSnapshot = JSON.parse(readFileSync(
            `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
              + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
            "utf8"
          ));
          if (finalSnapshot.turns.map((turn) => turn.userContent)
                .includes("rotated question")) break;
          await new Promise((resolve) => setTimeout(resolve, 5));
        }
        rmSync(durablePath);
        await new Promise((resolve) => setTimeout(resolve, 60));
        transcriptListener?.({
          id:"sdk-user",type:"user.message",
          timestamp:"2026-07-12T01:00:12.000Z",
          data:{content:"sdk fallback question",source:null}
        });
        transcriptListener?.({
          id:"sdk-answer",type:"assistant.message",
          timestamp:"2026-07-12T01:00:13.000Z",
          data:{messageId:"sdk-message",content:"sdk fallback answer"}
        });
        transcriptListener?.({
          id:"sdk-idle",type:"session.idle",
          timestamp:"2026-07-12T01:00:14.000Z",data:{aborted:false}
        });
        const afterAuthorityLoss = await waitForUsers(2);
        const activity = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`,
          "utf8"
        ));
        console.log(JSON.stringify({
          users: usersBeforeRotation,
          assistants: assistantsBeforeRotation,
          model: activity.model?.name,
          pendingPermissions: permissionsAfterInit,
          partialHiddenUntilComplete:
            beforeCompletion.turns.every(
              (turn) => turn.userContent !== "partial question"
            ),
          idlePollsDidNotRewrite: afterIdlePolls.updatedAt === stableUpdatedAt,
          rotationDidNotDuplicate:
            afterRotation.turns.map((turn) => turn.userContent).join("|")
              === usersBeforeRotation.join("|"),
          truncatedUsers: finalSnapshot.turns.map((turn) => turn.userContent),
          truncatedAssistants: finalSnapshot.turns.map((turn) =>
            turn.assistantMessages.map((message) => message.content)
          ),
          afterAuthorityLossUsers:
            afterAuthorityLoss.turns.map((turn) => turn.userContent),
          afterAuthorityLossAssistants:
            afterAuthorityLoss.turns.map((turn) =>
              turn.assistantMessages.map((message) => message.content)
            ),
          foreignObservedAtInit
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("history-timeout.mjs")
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
            "HOME": root.path,
            "COPILOT_HOME": copilotHome.path,
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
        XCTAssertEqual(
            summary?["users"] as? [String],
            [
                "durable question",
                "live question",
                "partial question",
                "recovered question",
            ]
        )
        XCTAssertEqual(
            summary?["assistants"] as? [[String]],
            [
                ["durable answer"],
                ["live answer"],
                ["partial answer"],
                ["recovered answer"],
            ]
        )
        XCTAssertEqual(summary?["model"] as? String, "new-model")
        XCTAssertEqual(
            summary?["pendingPermissions"] as? [String],
            ["permission-1"]
        )
        XCTAssertEqual(summary?["partialHiddenUntilComplete"] as? Bool, true)
        XCTAssertEqual(summary?["idlePollsDidNotRewrite"] as? Bool, true)
        XCTAssertEqual(summary?["rotationDidNotDuplicate"] as? Bool, true)
        XCTAssertEqual(
            summary?["truncatedUsers"] as? [String],
            ["rotated question"]
        )
        XCTAssertEqual(
            summary?["truncatedAssistants"] as? [[String]],
            [["rotated answer"]]
        )
        XCTAssertEqual(
            summary?["afterAuthorityLossUsers"] as? [String],
            ["rotated question", "sdk fallback question"]
        )
        XCTAssertEqual(
            summary?["afterAuthorityLossAssistants"] as? [[String]],
            [["rotated answer"], ["sdk fallback answer"]]
        )
        XCTAssertEqual(summary?["foreignObservedAtInit"] as? Bool, false)
    }

    func testCopilotExtensionReconstructsTerminalOnlyAskUserCard() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-durable-ask-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        let copilotSessionId = "11111111-1111-4111-8111-111111111111"
        let appSessionId = "22222222-2222-4222-8222-222222222222"
        let source = copilotHome
            .appendingPathComponent("session-state", isDirectory: true)
            .appendingPathComponent(copilotSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data((#"""
        {"id":"completed-start","type":"tool.execution_start","timestamp":"2026-08-25T01:00:00.000Z","data":{"toolCallId":"call-completed","toolName":"ask_user","arguments":{"message":"Completed question"}}}
        {"id":"completed-done","type":"tool.execution_complete","timestamp":"2026-08-25T01:00:01.000Z","data":{"toolCallId":"call-completed","success":true}}
        {"id":"cancelled-start","type":"tool.execution_start","timestamp":"2026-08-25T01:00:02.000Z","data":{"toolCallId":"call-cancelled","toolName":"ask_user","arguments":{"message":"Cancelled question"}}}
        {"id":"cancelled-abort","type":"abort","timestamp":"2026-08-25T01:00:03.000Z","data":{}}
        {"id":"cancelled-shutdown","type":"session.shutdown","timestamp":"2026-08-25T01:00:04.000Z","data":{}}
        {"id":"pending-start","type":"tool.execution_start","timestamp":"2026-08-25T01:00:05.000Z","data":{"toolCallId":"call-pending","toolName":"ask_user","arguments":{"message":"Pending terminal question","requestedSchema":{"properties":{"choice":{"type":"string"}}}}}}
        {"id":"pending-pre","type":"hook.start","timestamp":"2026-08-25T01:00:06.000Z","data":{"hookType":"preToolUse"}}
        {"id":"pending-notify","type":"hook.end","timestamp":"2026-08-25T01:00:07.000Z","data":{"hookType":"notification"}}
        """# + "\n").utf8).write(to: source.appendingPathComponent("events.jsonl"))

        let prelude = #"""
        let transcriptListener = null;
        let handledElicitations = 0;
        const namedListeners = new Map();
        const fakeSession = {
          sessionId: "__COPILOT_SESSION_ID__",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({enabled:false}) },
            model: { list: async () => [] },
            ui: {
              handlePendingElicitation: async () => {
                handledElicitations += 1;
                return {success:true};
              }
            },
            eventLog: {
              registerInterest: async ({eventType}) => ({handle:eventType}),
              releaseInterest: async () => ({success:true})
            }
          },
          on(name, handler) {
            if (typeof name === "function") transcriptListener = name;
            else namedListeners.set(name, handler);
          },
          async getEvents() { return []; }
        };
        """#.replacingOccurrences(of: "__COPILOT_SESSION_ID__", with: copilotSessionId)
        let extensionScript = CopilotExtension.script
            .replacingOccurrences(
                of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
                with: "const joinSession = async () => fakeSession;"
            )
            .replacingOccurrences(
                of: "const DURABLE_RECONCILE_DEBOUNCE_MS = 200;",
                with: "const DURABLE_RECONCILE_DEBOUNCE_MS = 5;"
            )
            .replacingOccurrences(
                of: "const DURABLE_RECONCILE_POLL_MS = 5_000;",
                with: "const DURABLE_RECONCILE_POLL_MS = 25;"
            )
        let epilogue = #"""

        const durablePath = join(
          process.env.COPILOT_HOME, "session-state",
          copilotSessionId, "events.jsonl"
        );
        const activityPath =
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.agent-activity.json`;
        const transcriptPath =
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`;
        const responsePath =
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.elicitation-response.json`;
        const observedElicitationIds = [];
        function append(event) {
          writeFileSync(durablePath, JSON.stringify(event) + "\n", {flag:"a"});
        }
        function recordObserved(ids) {
          const encoded = JSON.stringify(ids);
          if (observedElicitationIds.at(-1) !== encoded) {
            observedElicitationIds.push(encoded);
          }
        }
        async function waitFor(ids) {
          let last = [];
          for (let attempt = 0; attempt < 200; attempt += 1) {
            try {
              const value = JSON.parse(readFileSync(activityPath, "utf8"));
              const actual = (value.trackedElicitations || [])
                .map((entry) => entry.requestId);
              last = actual;
              recordObserved(actual);
              if (JSON.stringify(actual) === JSON.stringify(ids)) {
                return value.trackedElicitations || [];
              }
            } catch {}
            await new Promise((resolve) => setTimeout(resolve, 5));
          }
          throw new Error(`timed out waiting for ${ids}; last=${last}`);
        }

        const synthetic = (await waitFor([
          "synthetic::durable-ask-user::call-pending"
        ]))[0];

        namedListeners.get("elicitation.requested")?.({
          id:"real-request",type:"elicitation.requested",
          timestamp:"2026-08-25T01:00:05.500Z",
          data:{
            requestId:"real-request",
            message:"Pending terminal question",
            mode:"form",
            requestedSchema:{type:"object",properties:{choice:{type:"string"}}}
          }
        });
        const real = (await waitFor(["real-request"]))[0];
        const lateObservationStart = observedElicitationIds.length;
        append({
          id:"pending-start-late",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:05.000Z",
          data:{
            toolCallId:"call-pending",toolName:"ask_user",
            arguments:{message:"Pending terminal question"}
          }
        });
        await new Promise((resolve) => setTimeout(resolve, 50));
        const afterLateScan = await waitFor(["real-request"]);
        namedListeners.get("elicitation.completed")?.({
          id:"real-complete",type:"elicitation.completed",
          timestamp:"2026-08-25T01:00:08.000Z",
          data:{requestId:"real-request"}
        });
        await waitFor([]);

        namedListeners.get("user_input.requested")?.({
          id:"stale-live-request",type:"user_input.requested",
          timestamp:"2026-08-25T01:00:08.500Z",
          data:{
            requestId:"stale-live-request",
            question:"Previously answered root question",
            choices:["yes","no"]
          }
        });
        append({
          id:"second-start",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:09.000Z",
          data:{
            toolCallId:"call-second",toolName:"ask_user",
            arguments:{message:"Second durable question"}
          }
        });
        append({
          id:"second-agent-noise",type:"assistant.message",
          timestamp:"2026-08-25T01:00:10.000Z",
          agentId:"agent-1",data:{content:"background"}
        });
        const second = (await waitFor([
          "synthetic::durable-ask-user::call-second"
        ]))[0];
        const snapshotWithStaleRoot = JSON.parse(
          readFileSync(activityPath, "utf8")
        );
        namedListeners.get("elicitation.requested")?.({
          id:"subagent-request",type:"elicitation.requested",
          timestamp:"2026-08-25T01:00:10.500Z",agentId:"agent-1",
          data:{
            requestId:"subagent-request",message:"Subagent question",mode:"form",
            requestedSchema:{type:"object",properties:{choice:{type:"string"}}}
          }
        });
        const withSubagent = await waitFor([
          "subagent-request",
          "synthetic::durable-ask-user::call-second"
        ]);
        namedListeners.get("elicitation.completed")?.({
          id:"subagent-complete",type:"elicitation.completed",
          timestamp:"2026-08-25T01:00:10.750Z",agentId:"agent-1",
          data:{requestId:"subagent-request"}
        });
        await waitFor(["synthetic::durable-ask-user::call-second"]);
        append({
          id:"second-post-tool",type:"hook.start",
          timestamp:"2026-08-25T01:00:11.000Z",
          data:{hookType:"postToolUse"}
        });
        await waitFor([]);

        append({
          id:"third-start",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:12.000Z",
          data:{
            toolCallId:"call-third",toolName:"ask_user",
            arguments:{message:"Third durable question"}
          }
        });
        await waitFor(["synthetic::durable-ask-user::call-third"]);
        namedListeners.get("elicitation.completed")?.({
          id:"unmatched-root-complete",type:"elicitation.completed",
          timestamp:"2026-08-25T01:00:13.000Z",
          data:{requestId:"untracked-root-request"}
        });
        await waitFor([]);

        namedListeners.get("elicitation.completed")?.({
          id:"older-root-complete",type:"elicitation.completed",
          timestamp:"2026-08-25T01:00:11.500Z",
          data:{requestId:"older-untracked-root-request"}
        });
        append({
          id:"stale-start",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:12.500Z",
          data:{
            toolCallId:"call-stale",toolName:"ask_user",
            arguments:{message:"Stale durable question"}
          }
        });
        const staleObservationStart = observedElicitationIds.length;
        await new Promise((resolve) => setTimeout(resolve, 50));
        await waitFor([]);

        append({
          id:"fourth-start",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:14.000Z",
          data:{
            toolCallId:"call-fourth",toolName:"ask_user",
            arguments:{message:"Fourth durable question"}
          }
        });
        const fourth = (await waitFor([
          "synthetic::durable-ask-user::call-fourth"
        ]))[0];
        namedListeners.get("elicitation.completed")?.({
          id:"out-of-order-root-complete",type:"elicitation.completed",
          timestamp:"2026-08-25T01:00:13.500Z",
          data:{requestId:"out-of-order-root-request"}
        });
        const afterOutOfOrder = await waitFor([
          "synthetic::durable-ask-user::call-fourth"
        ]);
        const transcript = JSON.parse(readFileSync(transcriptPath, "utf8"));
        const askUserToolCount = (transcript.turns || [])
          .flatMap((turn) => turn.tools || [])
          .filter((tool) => tool.name === "ask_user").length;
        namedListeners.get("elicitation.requested")?.({
          id:"rejected-root-request",type:"elicitation.requested",
          timestamp:"2026-08-25T01:00:14.500Z",
          data:{
            requestId:"rejected-root-request",
            message:"Terminal-only live question",
            mode:"form"
          }
        });
        await waitFor([]);
        append({
          id:"fifth-start",type:"tool.execution_start",
          timestamp:"2026-08-25T01:00:15.000Z",
          data:{
            toolCallId:"call-fifth",toolName:"ask_user",
            arguments:{message:"Fifth durable question"}
          }
        });
        await waitFor(["synthetic::durable-ask-user::call-fifth"]);
        writeFileSync(durablePath, "");
        await waitFor([]);

        const guardedRequestId =
          "synthetic::durable-ask-user::spoofed-live-request";
        namedListeners.get("elicitation.requested")?.({
          id:"guarded-request",type:"elicitation.requested",
          timestamp:"2026-08-25T01:00:16.000Z",
          data:{
            requestId:guardedRequestId,message:"Spoofed live request",mode:"form",
            requestedSchema:{type:"object",properties:{choice:{type:"string"}}}
          }
        });
        await waitFor([guardedRequestId]);
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1, copilotSessionId,
          requestId:guardedRequestId, action:"decline"
        }));
        for (let attempt = 0; attempt < 200 && fileExistsSync(responsePath);
            attempt += 1) {
          await new Promise((resolve) => setTimeout(resolve, 5));
        }
        const guardedStillPending = await waitFor([guardedRequestId]);
        const lateObservations = observedElicitationIds.slice(
          lateObservationStart
        );
        const staleObservations = observedElicitationIds.slice(
          staleObservationStart
        );

        console.log(JSON.stringify({
          synthetic, real, second, fourth,
          afterLateScanCount: afterLateScan.length,
          withSubagentCount: withSubagent.length,
          staleRootUserInputCount:
            (snapshotWithStaleRoot.trackedUserInputs || []).length,
          afterOutOfOrderCount: afterOutOfOrder.length,
          guardedStillPendingCount: guardedStillPending.length,
          lateSyntheticSeen: lateObservations.some(
            (ids) => ids.includes(
              "synthetic::durable-ask-user::call-pending"
            )
          ),
          staleSyntheticSeen: staleObservations.some(
            (ids) => ids.includes(
              "synthetic::durable-ask-user::call-stale"
            )
          ),
          askUserToolCount,
          handledElicitations,
          responseRemoved: !fileExistsSync(responsePath)
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("durable-ask.mjs")
        try (prelude + extensionScript + epilogue).write(
            to: scriptURL, atomically: true, encoding: .utf8
        )

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", scriptURL.path]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "HOME": root.path,
            "COPILOT_HOME": copilotHome.path,
            "COPILOT_PROJECTS_SESSION": appSessionId,
            "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("app.sock").path,
            "COPILOT_PROJECTS_ROOT": root.path,
        ]) { _, new in new }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        XCTAssertEqual(
            process.terminationStatus, 0,
            String(data: errors, encoding: .utf8) ?? "node harness failed"
        )
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let result = try JSONSerialization.jsonObject(with: output) as? [String: Any]
        let synthetic = try XCTUnwrap(result?["synthetic"] as? [String: Any])
        XCTAssertEqual(
            synthetic["requestId"] as? String,
            "synthetic::durable-ask-user::call-pending"
        )
        XCTAssertEqual(synthetic["message"] as? String, "Pending terminal question")
        XCTAssertEqual(synthetic["mode"] as? String, "terminal")
        XCTAssertNil(synthetic["schema"])
        XCTAssertEqual(
            (result?["real"] as? [String: Any])?["requestId"] as? String,
            "real-request"
        )
        XCTAssertEqual(
            (result?["second"] as? [String: Any])?["message"] as? String,
            "Second durable question"
        )
        XCTAssertEqual(
            (result?["fourth"] as? [String: Any])?["message"] as? String,
            "Fourth durable question"
        )
        XCTAssertEqual(result?["afterLateScanCount"] as? Int, 1)
        XCTAssertEqual(result?["withSubagentCount"] as? Int, 2)
        XCTAssertEqual(result?["staleRootUserInputCount"] as? Int, 1)
        XCTAssertEqual(result?["afterOutOfOrderCount"] as? Int, 1)
        XCTAssertEqual(result?["guardedStillPendingCount"] as? Int, 1)
        XCTAssertEqual(result?["lateSyntheticSeen"] as? Bool, false)
        XCTAssertEqual(result?["staleSyntheticSeen"] as? Bool, false)
        XCTAssertGreaterThan(result?["askUserToolCount"] as? Int ?? 0, 0)
        XCTAssertEqual(result?["handledElicitations"] as? Int, 0)
        XCTAssertEqual(result?["responseRemoved"] as? Bool, true)
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
            "HOME": root.path,
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
        __fakeSession.emit({
          id:"ui-default-freeform",type:"user_input.requested",
          timestamp:"2026-07-12T03:00:02.500Z",
          data:{requestId:"req-default",question:"Omitted allowFreeform?",choices:[]}
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
        const defaultRequest = firstSnapshot.trackedUserInputs.find(
          (u) => u.requestId === "req-default"
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
        __fakeSession.emit({
          id:"ui-default-complete",type:"user_input.completed",
          timestamp:"2026-07-12T03:00:05.000Z",
          data:{requestId:"req-default",answer:"Done",wasFreeform:true}
        });
        await new Promise((resolve) => setImmediate(resolve));
        const afterSnapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));

        console.log(JSON.stringify({
          pendingBefore,
          rejectedBigChoice: pendingBefore.includes("req-big"),
          rootChoices: rootRequest?.choices,
          rootAllowFreeform: rootRequest?.allowFreeform,
          subAgentId: subRequest?.agentId,
          defaultAllowFreeform: defaultRequest?.allowFreeform,
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
            "HOME": root.path,
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
            ["req-default", "req-root", "req-sub"]
        )
        XCTAssertEqual(summary["rejectedBigChoice"] as? Bool, false)
        XCTAssertEqual(summary["rootChoices"] as? [String], ["Yes, deploy", "No, cancel"])
        XCTAssertEqual(summary["rootAllowFreeform"] as? Bool, false)
        XCTAssertEqual(summary["subAgentId"] as? String, "agent-7")
        XCTAssertEqual(summary["defaultAllowFreeform"] as? Bool, true)
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

    func testCopilotExtensionRegistersTracksCompletesAndAnswersElicitation() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-elicitation-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"

        let prelude = #"""
        let transcriptListener = null;
        const namedListeners = new Map();
        const eventInterestRegistrations = [];
        const eventInterestReleases = [];
        const eventInterestReleaseAttempts = new Map();
        const handledElicitationCalls = [];
        const originalProcessExit = process.exit.bind(process);
        let requestedExitCode = null;
        process.exit = (code) => {
          requestedExitCode = code;
        };
        const fakeSession = {
          sessionId: "copilot-session",
          rpc: {
            schedule: { list: async () => ({entries:[]}) },
            permissions: { getAllowAll: async () => ({enabled:false}) },
            eventLog: {
              registerInterest: async ({eventType}) => {
                eventInterestRegistrations.push(eventType);
                if (eventType === "elicitation.requested") {
                  fakeSession.emit({
                    id:"elicit-registration",type:"elicitation.requested",
                    timestamp:"2026-07-12T04:00:01.000Z",
                    data:{requestId:"req-form",message:"Pick a fruit",mode:"form",
                      requestedSchema:{type:"object",properties:{fruit:{type:"string"}}},
                      elicitationSource:"unit-test"}
                  });
                }
                return { handle: `handle-${eventType}` };
              },
              releaseInterest: async ({handle}) => {
                const attempt = (eventInterestReleaseAttempts.get(handle) || 0) + 1;
                eventInterestReleaseAttempts.set(handle, attempt);
                eventInterestReleases.push(`${handle}:${attempt}`);
                if (handle === "handle-elicitation.requested" && attempt === 1) {
                  return { success: false };
                }
                return { success: true };
              },
            },
            ui: {
              handlePendingElicitation: async (payload) => {
                handledElicitationCalls.push(payload);
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
        const responsePath = `${base}.elicitation-response.json`;
        await new Promise((resolve) => setImmediate(resolve));

        __fakeSession.emit({
          id:"elicit-url",type:"elicitation.requested",agentId:"agent-7",
          timestamp:"2026-07-12T04:00:02.000Z",
          data:{requestId:"req-url",message:"Open docs",url:"https://example.com/elicit"}
        });
        __fakeSession.emit({
          id:"elicit-terminal",type:"elicitation.requested",agentId:"agent-7",
          timestamp:"2026-07-12T04:00:02.500Z",
          data:{requestId:"req-terminal",message:"Answer elsewhere",mode:"form",
            requestedSchema:{type:"object",properties:{ok:{type:"string"}}}}
        });
        await new Promise((resolve) => setImmediate(resolve));

        const firstSnapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
        const pendingBefore = firstSnapshot.trackedElicitations.map((e) => e.requestId);
        const formRequest = firstSnapshot.trackedElicitations.find(
          (e) => e.requestId === "req-form"
        );
        const urlRequest = firstSnapshot.trackedElicitations.find(
          (e) => e.requestId === "req-url"
        );
        const snapshotMode = (statSync(snapshotPath).mode & 0o777).toString(8);

        // A stale/foreign-session response is dropped without answering.
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1,copilotSessionId:"other-session",requestId:"req-form",
          action:"accept",content:{fruit:"apple"}
        }));
        let waited = 0;
        while (waited < 6000 && existsSync(responsePath)) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        const staleHandled = handledElicitationCalls.length;
        const staleStillPending = JSON.parse(readFileSync(snapshotPath, "utf8"))
          .trackedElicitations.some((e) => e.requestId === "req-form");

        // A valid form response is delivered over RPC and clears the heartbeat card.
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1,copilotSessionId:"copilot-session",requestId:"req-form",
          action:"accept",content:{fruit:"apple"}
        }));
        waited = 0;
        while (waited < 6000 && handledElicitationCalls.length === 0) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        waited = 0;
        while (waited < 3000 && existsSync(responsePath)) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        // URL-mode accept has no form content, but still answers over RPC.
        writeFileSync(responsePath, JSON.stringify({
          schemaVersion:1,copilotSessionId:"copilot-session",requestId:"req-url",
          action:"accept"
        }));
        waited = 0;
        while (waited < 6000 && handledElicitationCalls.length < 2) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        waited = 0;
        while (waited < 3000 && existsSync(responsePath)) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }
        const handledAfterResponses = handledElicitationCalls.length;

        // A question answered through the terminal clears via the SDK completion event.
        __fakeSession.emit({
          id:"elicit-terminal-complete",type:"elicitation.completed",agentId:"agent-7",
          timestamp:"2026-07-12T04:00:03.000Z",
          data:{requestId:"req-terminal",action:"decline"}
        });
        await new Promise((resolve) => setImmediate(resolve));
        const afterSnapshot = JSON.parse(readFileSync(snapshotPath, "utf8"));
        process.emit("SIGINT");
        waited = 0;
        while (waited < 6000 && requestedExitCode == null) {
          await new Promise((resolve) => setTimeout(resolve, 80));
          waited += 80;
        }

        console.log(JSON.stringify({
          registrations: eventInterestRegistrations,
          releases: eventInterestReleases,
          requestedExitCode,
          pendingBefore,
          formMessage: formRequest?.message,
          formSchemaType: formRequest?.schema?.type,
          formSource: formRequest?.elicitationSource,
          urlMode: urlRequest?.mode,
          url: urlRequest?.url,
          urlAgentId: urlRequest?.agentId,
          snapshotMode,
          staleHandled,
          staleStillPending,
          handledPayload: handledElicitationCalls[0],
          urlHandledPayload: handledElicitationCalls[1],
          handledAfterResponses,
          pendingAfter: afterSnapshot.trackedElicitations.map((e) => e.requestId),
          responseRemoved: existsSync(responsePath) === false
        }));
        originalProcessExit(0);
        """#
        let scriptURL = root.appendingPathComponent("elicitation.mjs")
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
            "HOME": root.path,
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
            summary["registrations"] as? [String],
            ["user_input.requested", "elicitation.requested"]
        )
        XCTAssertEqual(
            summary["releases"] as? [String],
            [
                "handle-user_input.requested:1",
                "handle-elicitation.requested:1",
                "handle-elicitation.requested:2",
            ]
        )
        XCTAssertEqual(summary["requestedExitCode"] as? Int, 130)
        XCTAssertEqual(
            (summary["pendingBefore"] as? [String])?.sorted(),
            ["req-form", "req-terminal", "req-url"]
        )
        XCTAssertEqual(summary["formMessage"] as? String, "Pick a fruit")
        XCTAssertEqual(summary["formSchemaType"] as? String, "object")
        XCTAssertEqual(summary["formSource"] as? String, "unit-test")
        XCTAssertTrue(summary["urlMode"] == nil || summary["urlMode"] is NSNull)
        XCTAssertEqual(summary["url"] as? String, "https://example.com/elicit")
        XCTAssertEqual(summary["urlAgentId"] as? String, "agent-7")
        XCTAssertEqual(summary["snapshotMode"] as? String, "600")
        XCTAssertEqual(summary["staleHandled"] as? Int, 0)
        XCTAssertEqual(summary["staleStillPending"] as? Bool, true)
        let handledPayload = summary["handledPayload"] as? [String: Any]
        XCTAssertEqual(handledPayload?["requestId"] as? String, "req-form")
        let result = handledPayload?["result"] as? [String: Any]
        XCTAssertEqual(result?["action"] as? String, "accept")
        XCTAssertEqual((result?["content"] as? [String: Any])?["fruit"] as? String, "apple")
        let urlHandledPayload = summary["urlHandledPayload"] as? [String: Any]
        XCTAssertEqual(urlHandledPayload?["requestId"] as? String, "req-url")
        let urlResult = urlHandledPayload?["result"] as? [String: Any]
        XCTAssertEqual(urlResult?["action"] as? String, "accept")
        XCTAssertNil(urlResult?["content"])
        XCTAssertEqual(summary["handledAfterResponses"] as? Int, 2)
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

    func testRemoteCreateSessionContractRoundTrips() throws {
        XCTAssertEqual(RemoteSessionContract.createPath, "sessions/create")
        let requestId = UUID()
        let request = RemoteCreateSessionRequest(requestId: requestId, projectId: "project-1")
        let decodedRequest = try JSONDecoder().decode(
            RemoteCreateSessionRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decodedRequest, request)

        let response = RemoteCreateSessionResponse(
            requestId: requestId,
            projectId: "project-1",
            sessionId: requestId.uuidString
        )
        let decodedResponse = try JSONDecoder().decode(
            RemoteCreateSessionResponse.self,
            from: JSONEncoder().encode(response)
        )
        XCTAssertEqual(decodedResponse, response)
        XCTAssertEqual(decodedResponse.sessionId, requestId.uuidString)
    }

    func testResolveCopilotExecutablePrefersOverrideThenLocalThenPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let overrideDir = root.appendingPathComponent("override", isDirectory: true)
        let pathDir = root.appendingPathComponent("bin", isDirectory: true)
        let emptyDir = root.appendingPathComponent("empty", isDirectory: true)
        for directory in [localBin, overrideDir, pathDir, emptyDir] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        func makeExecutable(_ url: URL) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: 0o755]
            )
        }
        let override = overrideDir.appendingPathComponent("copilot")
        let local = localBin.appendingPathComponent("copilot")
        let onPath = pathDir.appendingPathComponent("copilot")
        makeExecutable(override)
        makeExecutable(local)
        makeExecutable(onPath)

        // Explicit override wins over everything else.
        XCTAssertEqual(
            Paths.resolveCopilotExecutable(
                environment: [
                    "COPILOT_PROJECTS_COPILOT": override.path,
                    "PATH": pathDir.path,
                ],
                home: home
            ),
            override.path
        )
        // No override → the documented ~/.local/bin/copilot.
        XCTAssertEqual(
            Paths.resolveCopilotExecutable(
                environment: ["PATH": pathDir.path],
                home: home
            ),
            local.path
        )
        // No override, no local → the first executable on PATH.
        try FileManager.default.removeItem(at: local)
        XCTAssertEqual(
            Paths.resolveCopilotExecutable(
                environment: ["PATH": "relative:\(pathDir.path)"],
                home: home
            ),
            onPath.path
        )
        // None reachable → nil (fail closed).
        XCTAssertNil(
            Paths.resolveCopilotExecutable(
                environment: ["PATH": emptyDir.path],
                home: home
            )
        )
    }

    func testResolveReposDirectoryRequiresExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Missing Repos → nil (never a home fallback).
        XCTAssertNil(Paths.resolveReposDirectory(home: home))

        let repos = home.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        XCTAssertEqual(Paths.resolveReposDirectory(home: home), repos.path)

        // A regular file named Repos must not satisfy the requirement.
        let fileHome = root.appendingPathComponent("filehome", isDirectory: true)
        try FileManager.default.createDirectory(at: fileHome, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fileHome.appendingPathComponent("Repos").path, contents: Data())
        XCTAssertNil(Paths.resolveReposDirectory(home: fileHome))
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
            "COPILOT_PROJECTS_SOCKET": "/isolated/control.sock",
        ]))
    }

    /// Launching the app from a terminal inside a session inherits that session's
    /// targeting variables, which name this instance's own default location. That
    /// is not isolation, and treating it as such silently skipped the hook and
    /// extension refresh on every such launch.
    func testInheritedSessionEnvStillInstallsGlobalIntegration() {
        let stateDir = "/Users/example/.local/state/copilot-projects"
        let socket = "\(stateDir)/control.sock"

        XCTAssertTrue(Env.shouldInstallGlobalIntegration(
            ["COPILOT_PROJECTS_SOCKET": socket],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
        XCTAssertTrue(Env.shouldInstallGlobalIntegration(
            [
                "COPILOT_PROJECTS_SOCKET": socket,
                "COPILOT_PROJECTS_STATE_DIR": stateDir,
                "COPILOT_PROJECTS_SESSION": "9CE858E3-60D3-47CF-A5E0-ACB8BDDBBEAD",
                "COPILOT_PROJECTS_PROJECT": "proj",
            ],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
        // Equivalent spellings of the default are still the default.
        XCTAssertTrue(Env.shouldInstallGlobalIntegration(
            [
                "COPILOT_PROJECTS_STATE_DIR": "\(stateDir)/",
                "COPILOT_PROJECTS_SOCKET": "\(stateDir)/./control.sock",
            ],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
        // An explicit opt-out still wins over an inherited default-valued socket.
        XCTAssertFalse(Env.shouldInstallGlobalIntegration(
            ["COPILOT_PROJECTS_SOCKET": socket, "COPILOT_PROJECTS_NO_INSTALL": "1"],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
        // A genuinely isolated instance is still suppressed.
        XCTAssertFalse(Env.shouldInstallGlobalIntegration(
            ["COPILOT_PROJECTS_SOCKET": "/isolated/control.sock"],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
        XCTAssertFalse(Env.shouldInstallGlobalIntegration(
            ["COPILOT_PROJECTS_STATE_DIR": "/isolated/state"],
            defaultStateDir: stateDir,
            defaultSocketPath: socket
        ))
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

    func testManagedSessionResolutionPrefersDtachAncestryOverEnvironment() {
        let expected = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let sessions = URL(fileURLWithPath: "/tmp/state/sessions", isDirectory: true)
        var snapshot = ProcessTree.Snapshot()
        snapshot.parentOf = [10: 20, 20: 30, 30: 1]
        snapshot.nameOf = [10: "copilot", 20: "zsh", 30: "dtach"]
        let dtach = [
            ProcessTree.DtachProcess(
                pid: 30,
                parentPID: 1,
                socketPath: sessions.appendingPathComponent("\(expected).sock").path,
                isMaster: true
            ),
        ]

        XCTAssertEqual(
            ProcessTree.managedSessionId(
                for: 10,
                fallbackSessionId: "6780CCA3-92AF-4506-95F2-F018A195A1A1",
                sessionsDirectory: sessions,
                in: snapshot,
                dtachProcesses: dtach
            ),
            expected
        )
    }

    func testManagedSessionResolutionFallsBackOnlyAtAppBoundary() {
        let fallback = "6780CCA3-92AF-4506-95F2-F018A195A1A1"
        let sessions = URL(fileURLWithPath: "/tmp/state/sessions", isDirectory: true)
        var direct = ProcessTree.Snapshot()
        direct.parentOf = [10: 20, 20: 30, 30: 1]
        direct.nameOf = [10: "copilot", 20: "zsh", 30: "copilot-project"]
        XCTAssertEqual(
            ProcessTree.managedSessionId(
                for: 10,
                fallbackSessionId: fallback,
                sessionsDirectory: sessions,
                in: direct,
                dtachProcesses: []
            ),
            fallback
        )

        var indeterminate = ProcessTree.Snapshot()
        indeterminate.parentOf = [10: 20]
        indeterminate.nameOf = [10: "copilot", 20: "zsh"]
        XCTAssertNil(ProcessTree.managedSessionId(
            for: 10,
            fallbackSessionId: fallback,
            sessionsDirectory: sessions,
            in: indeterminate,
            dtachProcesses: []
        ))
    }

    func testAgentSessionsUseResolvedDtachSession() {
        let expected = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let stale = "6780CCA3-92AF-4506-95F2-F018A195A1A1"
        let sessions = URL(fileURLWithPath: "/tmp/state/sessions", isDirectory: true)
        var snapshot = ProcessTree.Snapshot()
        snapshot.parentOf = [10: 20, 20: 30, 30: 1]
        snapshot.nameOf = [10: "copilot", 20: "zsh", 30: "dtach"]
        let dtach = [
            ProcessTree.DtachProcess(
                pid: 30,
                parentPID: 1,
                socketPath: sessions.appendingPathComponent("\(expected).sock").path,
                isMaster: true
            ),
        ]

        XCTAssertEqual(
            ProcessTree.agentSessions(
                agentNames: ["copilot"],
                in: snapshot,
                environmentOf: { _ in ["COPILOT_PROJECTS_SESSION": stale] },
                dtachProcesses: dtach,
                sessionsDirectory: sessions
            ),
            [expected]
        )
    }
}
