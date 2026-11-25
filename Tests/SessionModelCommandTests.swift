import AppKit
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class SessionModelCommandTests: XCTestCase {
    func testCLISendsTheModelFlagsAndRefusesMalformedOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: [ControlRequest] = []
        var nextResponse = ControlResponse.success(code: "applied")
        let server = ControlServer(socketPath: socketPath) { request in
            received.append(request)
            return nextResponse
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath
        environment["COPILOT_PROJECTS_SESSION"] = "calling-session"
        XCTAssertTrue(CLIMain.isCommand("list-session-models"))
        XCTAssertTrue(CLIMain.isCommand("set-session-model"))

        let list = ["list-session-models", "--session", "s1", "--project", "p1"]
        XCTAssertEqual(CLIMain.run(list, environment: environment), 0)
        XCTAssertEqual(received.last?.command, "list-session-models")
        XCTAssertEqual(received.last?.sessionId, "s1")
        XCTAssertEqual(received.last?.projectId, "p1")

        let set = ["set-session-model", "--session", "s1", "--model", "acme/model"]
        XCTAssertEqual(CLIMain.run(set, environment: environment), 0)
        XCTAssertEqual(received.last?.command, "set-session-model")
        XCTAssertEqual(received.last?.sessionId, "s1")
        XCTAssertEqual(received.last?.model, "acme/model")
        XCTAssertNil(received.last?.reasoningEffort)
        XCTAssertNil(received.last?.contextTier)
        XCTAssertEqual(CLIMain.run(
            set + ["--reasoning-effort", "high", "--context-tier", "long_context"], environment: environment
        ), 0)
        XCTAssertEqual(received.last?.reasoningEffort, "high")
        XCTAssertEqual(received.last?.contextTier, "long_context")

        // A refusal the session can act on has its own exit; a receipt's answer is 1.
        let exits: [(String, Int32)] = [
            ("invalid", 7), ("busy", 8), ("parked", 9), ("rejected", 1), ("indeterminate", 1),
        ]
        for (code, status) in exits {
            nextResponse = .failure("failed", code: code)
            XCTAssertEqual(CLIMain.run(set, environment: environment), status, code)
        }

        // new-copilot-session takes the same flags, and sends none when none is given.
        nextResponse = .success("session-1", code: "created")
        let promptFile = root.appendingPathComponent("prompt.md")
        try Data("Review it".utf8).write(to: promptFile)
        let create = [
            "new-copilot-session", "--project", "p1", "--request-id", UUID().uuidString,
            "--prompt-file", promptFile.path,
        ]
        XCTAssertEqual(CLIMain.run(create, environment: environment), 0)
        XCTAssertNil(received.last?.model)
        XCTAssertEqual(CLIMain.run(
            create + ["--model", "gpt-5.4", "--reasoning-effort=high"], environment: environment
        ), 0)
        XCTAssertEqual(received.last?.model, "gpt-5.4")
        XCTAssertEqual(received.last?.reasoningEffort, "high")
        XCTAssertNil(received.last?.contextTier)

        let sent = received.count
        let rejected: [[String]] = [
            ["set-session-model", "--session", "s1"],
            ["set-session-model", "--model", "gpt-5.4"],
            ["set-session-model", "--session", "s1", "--model"],
            set + ["--reasoning-effort"],
            set + ["--context-tier", "huge"],
            set + ["--effort", "high"],
            list + ["--model", "gpt-5.4"],
            create + ["--reasoning-effort", "high"],
            create + ["--context-tier", "long_context"],
            create + ["--model", "gpt-5.4", "--context-tier", "huge"],
        ]
        for args in rejected {
            XCTAssertEqual(CLIMain.run(args, environment: environment), 2, args.joined(separator: " "))
        }
        XCTAssertEqual(received.count, sent, "a malformed selection is never sent")
    }

    @MainActor
    func testSessionModelCommandListsAndSwitchesAndLeavesAParkedSessionParked() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "Models", cwd: root.path)
        let project = Project(name: "Model test", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false }, agentActivityDirectory: sessions, resumeMarkerDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        let sdkID = UUID().uuidString
        try Data(sdkID.utf8).write(to: sessions.appendingPathComponent("\(session.id).copilot-session"))
        let snapshotURL = sessions.appendingPathComponent("\(session.id).agent-activity.json")
        let handoffURL = sessions.appendingPathComponent("\(session.id).set-model-request.json")
        let catalog = [
            TrackedAvailableModel(
                id: "gpt-5.4", name: "GPT-5.4", supportedReasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "low", longContextAvailable: true, disabled: nil, category: "powerful"
            ),
            TrackedAvailableModel(
                id: "small-model", name: "Small", supportedReasoningEfforts: nil,
                defaultReasoningEffort: nil, longContextAvailable: false, disabled: nil, category: nil
            ),
        ]
        let now = Date()
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: now.ISO8601Format(.init(includingFractionalSeconds: true)),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 0, lastIdleAborted: false, lastIdleTurnKind: nil, error: nil,
            model: TrackedModel(name: "small-model", reasoningEffort: nil, contextTier: nil),
            availableModels: catalog,
            copilotSessionId: sdkID, conversationEpoch: "epoch-1",
            operationReceiptVersion: 1, operationReceipts: [],
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                capabilities: [RemoteSessionActionKind.send.rawValue], sendReady: true
            )
        )
        func publish() throws { try JSONEncoder().encode(snapshot).write(to: snapshotURL) }
        try publish()
        func command(
            _ name: String, model id: String? = nil, effort: String? = nil, tier: String? = nil,
            session target: String = session.id, project: String? = nil
        ) -> ControlRequest {
            var request = ControlRequest(command: name)
            request.sessionId = target
            request.projectId = project
            request.model = id
            request.reasoningEffort = effort
            request.contextTier = tier
            return request
        }
        let list = "list-session-models", set = "set-session-model"

        // The list is the tracker's catalog and the model Copilot is on, as scripts parse it.
        let listed = await model.sessionModelCommand(command(list))
        XCTAssertEqual(
            listed.text,
            #"{"availableModels":[{"category":"powerful","defaultReasoningEffort":"low","id":"gpt-5.4","#
                + #""longContextAvailable":true,"name":"GPT-5.4","supportedReasoningEfforts":["low","high"]},"#
                + #"{"id":"small-model","longContextAvailable":false,"name":"Small"}],"#
                + #""currentModel":{"name":"small-model"}}"#
        )

        // What the session does not offer is final, and the tracker is not asked.
        for refused in [
            command(set, model: "unknown-model"),
            command(set, model: "gpt-5.4", effort: "max"),
            command(set, model: "small-model", effort: "low"),
            command(set, model: "small-model", tier: "long_context"),
        ] {
            let response = await model.sessionModelCommand(refused)
            XCTAssertEqual(response.code, "invalid", refused.model ?? "")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))

        // A switch goes to the tracker as the picker's does, and the command answers with the receipt.
        let outcomes: [RemoteOperationState] = [.applied, .rejected, .indeterminate]
        for state in outcomes {
            let answer = Task {
                await model.sessionModelCommand(
                    command(set, model: "gpt-5.4", effort: "high", tier: "long_context"),
                    pollInterval: .milliseconds(5)
                )
            }
            for _ in 0..<20 where !FileManager.default.fileExists(atPath: handoffURL.path) { await Task.yield() }
            let handed = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: handoffURL)) as? [String: Any]
            )
            XCTAssertEqual(handed["modelId"] as? String, "gpt-5.4")
            XCTAssertEqual(handed["reasoningEffort"] as? String, "high")
            XCTAssertEqual(handed["contextTier"] as? String, "long_context")
            try FileManager.default.removeItem(at: handoffURL)
            snapshot.operationReceipts = [TrackedOperationReceipt(
                operationId: handed["operationId"] as? String, conversationEpoch: "epoch-1",
                kind: CLISDKOperationKind.setModel.rawValue, state: state,
                updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                payloadFingerprint: handed["payloadFingerprint"] as? String
            )]
            try publish()
            let response = await answer.value
            XCTAssertEqual(response.ok, state == .applied, state.rawValue)
            XCTAssertEqual(response.code, state.rawValue)
            // A refusal and an unknown outcome both exit 1, so the text tells them apart.
            let said = ["rejected": "Copilot refused the model switch.", "indeterminate": "Outcome unknown."]
            XCTAssertEqual(said[state.rawValue].map { response.error?.hasPrefix($0) }, state == .applied ? nil : true)
        }

        // Nothing reaches a tracker that still holds another switch, so the answer is "try again".
        let pending = Data(#"{"operationId":"another-switch","conversationEpoch":"epoch-1"}"#.utf8)
        try pending.write(to: handoffURL)
        let waiting = await model.sessionModelCommand(command(set, model: "gpt-5.4"))
        XCTAssertEqual(waiting.code, "busy")
        XCTAssertEqual(try Data(contentsOf: handoffURL), pending)
        try FileManager.default.removeItem(at: handoffURL)

        // A tracker that has not read Copilot's models publishes no list. That is not an empty one.
        snapshot.availableModels = nil
        try publish()
        for request in [command(list), command(set, model: "gpt-5.4")] {
            let blind = await model.sessionModelCommand(request)
            XCTAssertEqual(blind.code, "busy", request.command)
            XCTAssertNil(blind.text)
        }
        snapshot.availableModels = catalog
        try publish()

        model.projects[0].sessions[0].parked = ParkedSession(state: .parked, sinceMilliseconds: 1)
        for request in [command(list), command(set, model: "gpt-5.4")] {
            let parked = await model.sessionModelCommand(request)
            XCTAssertEqual(parked.code, "parked", request.command)
        }
        XCTAssertEqual(model.parkedState(session.id), .parked, "a refused request must not resume a parked session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: handoffURL.path))
        model.projects[0].sessions[0].parked = nil

        let unnamed = await model.sessionModelCommand(command(set))
        XCTAssertEqual(unnamed.code, "bad-request")
        let moved = await model.sessionModelCommand(command(list, project: "another-project"))
        XCTAssertEqual(moved.code, "conflict")
        let gone = await model.sessionModelCommand(command(set, model: "gpt-5.4", session: "missing"))
        XCTAssertEqual(gone.code, "gone")
    }

    @MainActor
    func testNewCopilotSessionStartsOnTheModelAndBindsItToTheRequestId() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Session(id: "existing", title: "shell", cwd: "/tmp")
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp", sessions: [existing], selectedSessionId: existing.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        var launches: [String] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { repos.path },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { id, _, _ in launches.append(id) },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        )
        let requestId = UUID()
        func request(model id: String? = "gpt-5.4", effort: String? = "high", tier: String? = nil) -> ControlRequest {
            var request = ControlRequest(command: "new-copilot-session")
            request.projectId = "p1"
            request.requestId = requestId.uuidString
            request.prompt = "Review it"
            request.model = id
            request.reasoningEffort = effort
            request.contextTier = tier
            return request
        }

        XCTAssertEqual(model.handle(request()).code, "created")
        XCTAssertEqual(
            model.capturedLaunchModels[requestId.uuidString],
            RemoteModelSelection(modelId: "gpt-5.4", reasoningEffort: "high")
        )
        // The request id is bound to the model too: the same request replays, another is refused.
        XCTAssertEqual(model.handle(request()).code, "existing")
        for other in [
            request(model: "small-model"), request(effort: "low"), request(effort: nil),
            request(tier: "long_context"), request(model: nil, effort: nil),
        ] {
            XCTAssertEqual(model.handle(other).code, "conflict")
        }
        XCTAssertEqual(launches, [requestId.uuidString])

        // A request that names no model is bound as it was before one could be named.
        XCTAssertEqual(
            SessionCreationRecord.fingerprint(
                projectId: "p1", kind: .copilot, initialPrompt: "Review it", pullRequestURL: nil),
            "7eac62a347d1a68d14f807e041f7daf6617c9774a47487907d441ed59fcbd3c0"
        )

        // Copilot gets its own launch flags, each as one argument ahead of the prompt.
        let prompt = "Review it; --model=other"
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: "/bin/zsh", copilotSessionId: nil, launchCopilotExecutable: "/opt/copilot",
                launchCopilotInitialPrompt: prompt,
                launchCopilotModel: RemoteModelSelection(
                    modelId: "acme/model", reasoningEffort: "high", contextTier: "long_context")
            ),
            ["/bin/zsh", "-l", "-c", TerminalController.profiledCopilotCommand("/opt/copilot", arguments: [
                "--model=acme/model", "--reasoning-effort=high", "--context=long_context", "--interactive", prompt,
            ])
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"]
        )
        XCTAssertEqual(
            TerminalController.modelArguments(RemoteModelSelection(modelId: "gpt-5.4")), ["--model=gpt-5.4"]
        )
        // The remote wrapper is handed the same flags, and a recorded session only its resume.
        let selection = RemoteModelSelection(modelId: "gpt-5.4", reasoningEffort: "high")
        XCTAssertEqual(
            TerminalController.remoteWrapperArguments(resumeSessionId: nil, initialPrompt: prompt, model: selection),
            ["--model=gpt-5.4", "--reasoning-effort=high", "--interactive", prompt]
        )
        XCTAssertEqual(
            TerminalController.remoteWrapperArguments(resumeSessionId: "sdk-1", initialPrompt: prompt, model: selection),
            ["--resume=sdk-1"]
        )
    }
}
