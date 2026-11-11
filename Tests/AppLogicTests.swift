import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI
import AppKit
import SwiftUI
import SwiftTerm
import Combine
import Security
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#endif


/// Each answer below is its own operation in the `epoch-1` conversation the fixtures publish.
private extension AppModel {
    private var testOperation: CLIOperationRequest {
        CLIOperationRequest(operationId: UUID().uuidString, conversationEpoch: "epoch-1")
    }

    func answerUserInput(
        sessionId: String,
        answer: RemoteUserInputAnswer
    ) -> RemoteUserInputResult {
        answerUserInput(sessionId: sessionId, answer: answer, operation: testOperation)
    }

    func setModel(sessionId: String, selection: RemoteModelSelection) -> RemoteUserInputResult {
        setModel(sessionId: sessionId, selection: selection, operation: testOperation)
    }

    /// A durable ask-user prompt is answered in the terminal and takes no operation.
    func answerElicitation(
        sessionId: String,
        answer: RemoteElicitationAnswer,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        let durable = answer.requestId.hasPrefix("synthetic::durable-ask-user::")
        return answerElicitation(
            sessionId: sessionId,
            answer: answer,
            operation: durable ? nil : testOperation,
            now: now
        )
    }
}

private final class AgentActivityCooldownHarness {
    private(set) var delays: [TimeInterval] = []
    private var actions: [@MainActor () -> Void] = []

    var scheduledCount: Int { actions.count }

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        delays.append(delay)
        actions.append(action)
    }

    @MainActor
    func runNext() {
        let action = popNext()
        action()
    }

    @MainActor
    func popNext() -> @MainActor () -> Void {
        delays.removeFirst()
        return actions.removeFirst()
    }
}

private final class ScanCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}


final class AppLogicTests: XCTestCase {
    func testRendererLRUKeepsThreeMostRecentLiveSessions() {
        let live: Set<String> = ["a", "b", "c", "d"]
        var lru = TerminalsContainerView.updatedRendererLRU(
            [],
            active: "a",
            live: live
        )
        lru = TerminalsContainerView.updatedRendererLRU(lru, active: "b", live: live)
        lru = TerminalsContainerView.updatedRendererLRU(lru, active: "c", live: live)
        XCTAssertEqual(lru, ["a", "b", "c"])

        lru = TerminalsContainerView.updatedRendererLRU(lru, active: "d", live: live)
        XCTAssertEqual(lru, ["b", "c", "d"])
        lru = TerminalsContainerView.updatedRendererLRU(lru, active: "b", live: live)
        XCTAssertEqual(lru, ["c", "d", "b"])
    }

    func testRendererLRUDropsRemovedAndClearsWithoutActiveSession() {
        XCTAssertEqual(
            TerminalsContainerView.updatedRendererLRU(
                ["removed", "a", "b"],
                active: "b",
                live: ["a", "b"]
            ),
            ["a", "b"]
        )
        XCTAssertEqual(
            TerminalsContainerView.updatedRendererLRU(
                ["a", "b"],
                active: nil,
                live: ["a", "b"]
            ),
            []
        )
    }

    @MainActor
    func testTerminalContainerParksOutsideWarmLRUAndReplacements() {
        let container = TerminalsContainerView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500)
        )
        var views = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map {
            ($0, ProjectsTerminalView(frame: container.bounds))
        })

        for active in ["a", "b", "c", "d"] {
            container.sync(
                order: ["a", "b", "c", "d"],
                active: active,
                emptyHint: ("", ""),
                onNew: {},
                provider: { views[$0] }
            )
        }

        XCTAssertEqual(views.values.filter(\.rendererShouldBeActiveForTesting).count, 3)
        XCTAssertFalse(views["a"]!.rendererShouldBeActiveForTesting)
        XCTAssertTrue(views["d"]!.rendererShouldBeActiveForTesting)

        let replaced = views["d"]!
        views["d"] = ProjectsTerminalView(frame: container.bounds)
        container.sync(
            order: ["a", "b", "c", "d"],
            active: "d",
            emptyHint: ("", ""),
            onNew: {},
            provider: { views[$0] }
        )

        XCTAssertFalse(replaced.rendererShouldBeActiveForTesting)
        XCTAssertTrue(views["d"]!.rendererShouldBeActiveForTesting)
        XCTAssertEqual(views.values.filter(\.rendererShouldBeActiveForTesting).count, 3)
    }

    @MainActor
    func testSwiftTermMetalFallbackRemainsOnCoreGraphics() {
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        defer { window.contentView = nil }

        view.handleMetalActivationFailure(MetalError.deviceUnavailable)
        view.setRendererActive(true)
        view.forceRedraw()

        XCTAssertEqual(view.rendererName, "coregraphics-fallback")
        XCTAssertFalse(view.isUsingMetalRenderer)
    }

    func testFooterClassification() {
        XCTAssertEqual(
            TerminalController.classifyFooter("◎ Working   esc cancel"),
            .working
        )
        XCTAssertEqual(
            TerminalController.classifyFooter("/ commands · ? help · tab next tab"),
            .idle
        )
        XCTAssertEqual(TerminalController.classifyFooter("ordinary output"), .unknown)
    }

    func testRemoteSubmitFocusBytesBracketTheSubmission() {
        XCTAssertEqual(
            ProjectsTerminalView.remoteSubmitBytes(
                keyboardEnhancementFlags: [.disambiguate],
                scopedFocus: true
            ),
            ProjectsTerminalView.remoteFocusInBytes
                + [0x0d]
                + ProjectsTerminalView.remoteFocusOutBytes
        )
    }

    func testRemoteEnterBytesHonorKittyReportAllKeys() {
        XCTAssertEqual(
            ProjectsTerminalView.remoteEnterBytes(keyboardEnhancementFlags: []),
            [0x0d]
        )
        XCTAssertEqual(
            ProjectsTerminalView.remoteEnterBytes(
                keyboardEnhancementFlags: [.disambiguate, .reportEvents]
            ),
            [0x0d]
        )
        XCTAssertEqual(
            ProjectsTerminalView.remoteEnterBytes(
                keyboardEnhancementFlags: [.reportAllKeys, .reportEvents, .reportText]
            ),
            Array("\u{1b}[13u".utf8)
        )
    }

    func testRemoteCommandIsOneFocusedWrite() throws {
        XCTAssertEqual(
            try XCTUnwrap(ProjectsTerminalView.remoteCommandBytes(
                "git status",
                keyboardEnhancementFlags: [.disambiguate],
                scopedFocus: true
            )),
            ProjectsTerminalView.remoteFocusInBytes
                + Array("git status".utf8)
                + [0x0d]
                + ProjectsTerminalView.remoteFocusOutBytes
        )
        XCTAssertEqual(
            ProjectsTerminalView.remoteCommandTextBytes("first\r\n\tsecond"),
            Array("first\n\tsecond".utf8)
        )
        XCTAssertNil(ProjectsTerminalView.remoteCommandTextBytes("unsafe\u{1b}[31m"))
        XCTAssertNil(ProjectsTerminalView.remoteCommandTextBytes("   "))
    }

    func testRemoteCommandRequestLedgerDeduplicatesAndBoundsEntries() {
        var ledger = RemoteCommandRequestLedger()
        XCTAssertFalse(ledger.contains("session:first"))

        ledger.record("session:first", cap: 2)
        ledger.record("session:first", cap: 2)
        ledger.record("session:second", cap: 2)
        XCTAssertTrue(ledger.contains("session:first"))
        XCTAssertTrue(ledger.contains("session:second"))

        ledger.record("session:third", cap: 2)
        XCTAssertFalse(ledger.contains("session:first"))
        XCTAssertTrue(ledger.contains("session:second"))
        XCTAssertTrue(ledger.contains("session:third"))
    }

    func testRemotePromptEligibilityRequiresSettledLiveCopilot() {
        // Idle terminal footer + live agent → sendable. Background subagents keep
        // `status` at `.running`, but fresh background-only evidence lets the
        // foreground prompt stay usable (the regression this fixes).
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                hasLiveAgent: true,
                backgroundOnly: true,
                footerActivity: .idle
            ),
            .sent
        )
        // A stale idle footer alone is not enough to bypass `.running`.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .busy
        )
        // Scheduled state alone is not enough to bypass foreground gating.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                scheduledTurnActive: true,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .busy
        )
        // Fresh background-only evidence allows a separate foreground prompt while
        // scheduled work continues behind it.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                scheduledTurnActive: true,
                hasLiveAgent: true,
                backgroundOnly: true,
                footerActivity: .idle
            ),
            .sent
        )
        // A pending structured ask_user/elicitation → block (answer via its card).
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                hasPendingQuestions: true,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .busy
        )
        // A raw permission prompt surfaces only as `status == .waiting` (no
        // structured-question entry), and the footer can read `.idle` behind the
        // dialog. `.waiting` must block so a free-form message is never typed over
        // the permission selection.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .waiting,
                hasPendingQuestions: false,
                hasLiveAgent: true,
                footerActivity: .idle
            ),
            .busy
        )
        // Foreground genuinely working (footer not idle) → block.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .running,
                hasLiveAgent: true,
                footerActivity: .working
            ),
            .busy
        )
        // Footer state unknown → don't send until it confirms idle.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasLiveAgent: true,
                footerActivity: .unknown
            ),
            .busy
        )
        // No live Copilot → not sendable.
        XCTAssertEqual(
            AppModel.remotePromptEligibility(
                status: .idle,
                hasLiveAgent: false,
                footerActivity: .idle
            ),
            .noLiveCopilot
        )
    }

    func testBackgroundOnlyPromptEvidenceRequiresOrderedSnapshot() throws {
        let formatter = ISO8601DateFormatter()
        let now = Date()
        let transition = now.addingTimeInterval(-1)
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: formatter.string(from: now),
            foregroundTurnActive: false,
            foregroundTransitionAt: formatter.string(from: transition),
            scheduledTurnActive: false,
            activeSubagents: [
                TrackedSubagent(
                    id: "agent-1",
                    name: "reviewer",
                    description: "Reviews the PR",
                    model: "gpt"
                ),
            ],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let transitionMs = try XCTUnwrap(snapshot.foregroundTransitionMilliseconds)

        XCTAssertTrue(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: snapshot,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs - 1
        ))
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: snapshot,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs
        ))
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: snapshot,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: nowMs
        ))

        var activeForeground = snapshot
        activeForeground.foregroundTurnActive = true
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: activeForeground,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: nil
        ))

        var noSubagents = snapshot
        noSubagents.activeSubagents = []
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: noSubagents,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: nil
        ))
        // CLI background agents (terminal-title state, no `activeSubagents`) count
        // as background-only evidence just like scheduled/subagent work.
        XCTAssertTrue(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: noSubagents,
            backgroundAgentsActive: true,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs - 1
        ))
        // ...but only once the foreground turn has actually gone idle.
        var noSubagentsActiveForeground = noSubagents
        noSubagentsActiveForeground.foregroundTurnActive = true
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: noSubagentsActiveForeground,
            backgroundAgentsActive: true,
            now: now,
            nowMs: nowMs,
            clockMs: nil
        ))

        var scheduled = noSubagents
        scheduled.scheduledTurnActive = true
        XCTAssertTrue(AppModel.backgroundOnlyPromptEvidence(
            status: .running,
            snapshot: scheduled,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs - 1
        ))
        XCTAssertTrue(AppModel.backgroundOnlyPromptEvidence(
            status: .idle,
            snapshot: scheduled,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs
        ))
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .idle,
            snapshot: scheduled,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: transitionMs + 1
        ))

        var disconnected = snapshot
        disconnected.error = "Connection is closed."
        XCTAssertFalse(AppModel.backgroundOnlyPromptEvidence(
            status: .idle,
            snapshot: disconnected,
            backgroundAgentsActive: false,
            now: now,
            nowMs: nowMs,
            clockMs: nil
        ))
    }

    func testSessionHasPendingQuestions() {
        var session = Session(title: "q", cwd: "/tmp")
        XCTAssertFalse(session.hasPendingQuestions)
        session.agentActivity = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: [
                TrackedUserInput(
                    requestId: "r1",
                    question: "pick one",
                    choices: ["a", "b"],
                    allowFreeform: false,
                    requestedAt: ISO8601DateFormatter().string(from: Date()),
                    agentId: nil
                ),
            ]
        )
        XCTAssertTrue(session.hasPendingQuestions)
    }

    @MainActor
    func testRemotePromptableFollowsTheLiveForegroundNotBackgroundWork() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/remote-prompt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "prompt", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        var liveSessions: Set<String> = [session.id]
        var activity = FooterActivity.idle
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            remotePromptLiveSessions: { _ in liveSessions },
            remotePromptTarget: { requestedSessionId in
                guard requestedSessionId == session.id else { return nil }
                return RemotePromptTarget(activity: activity)
            }
        )
        func promptable() -> Bool {
            model.remoteWorkspaceSnapshot().projects[0].sessions[0].promptable == true
        }

        XCTAssertTrue(promptable())

        // Foreground genuinely working (footer working) → not promptable.
        activity = .working
        XCTAssertFalse(promptable())
        activity = .idle

        // Background agents active must NOT block a settled foreground at a prompt.
        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        XCTAssertTrue(promptable())
        model.setBackgroundAgentsActive(sessionId: session.id, active: false)

        let subagentTransitionAt = ISO8601DateFormatter().string(from: Date())
        let subagentSnapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            foregroundTransitionAt: subagentTransitionAt,
            scheduledTurnActive: false,
            activeSubagents: [
                TrackedSubagent(
                    id: "agent-1",
                    name: "reviewer",
                    description: "Reviews the PR",
                    model: "gpt"
                ),
            ],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        try JSONEncoder().encode(subagentSnapshot).write(
            to: root.appendingPathComponent("\(session.id).agent-activity.json")
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.projects[0].sessions[0].activeSubagentCount, 1)
        XCTAssertTrue(model.projects[0].sessions[0].hasBackgroundWork)
        // A live background subagent + idle footer must stay promptable (the reported bug).
        XCTAssertTrue(promptable())
        model.setStatus(
            sessionId: session.id,
            status: .running,
            text: nil,
            timestamp: 1,
            source: "background-only"
        )
        XCTAssertTrue(promptable())

        // A raw permission prompt sets `status == .waiting` (no structured question)
        // while the footer can still read idle behind the dialog — not promptable.
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 2,
            source: "permission-prompt"
        )
        XCTAssertEqual(activity, .idle)
        XCTAssertFalse(promptable())
        model.setStatus(
            sessionId: session.id,
            status: .running,
            text: nil,
            timestamp: 3,
            source: "permission-resolved"
        )

        let scheduledTransitionMs = Int64(Date().timeIntervalSince1970) * 1_000
        let scheduledTransition = Date(
            timeIntervalSince1970: Double(scheduledTransitionMs) / 1_000
        )
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: scheduledTransitionMs,
            source: "scheduled-start"
        )
        let scheduledSnapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: scheduledTransition),
            foregroundTurnActive: false,
            foregroundTransitionAt: ISO8601DateFormatter().string(from: scheduledTransition),
            scheduledTurnActive: true,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        try JSONEncoder().encode(scheduledSnapshot).write(
            to: root.appendingPathComponent("\(session.id).agent-activity.json")
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertTrue(promptable())
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: scheduledTransitionMs + 1,
            source: "scheduled-idle"
        )

        liveSessions = []
        XCTAssertFalse(promptable())
        liveSessions = [session.id]

        // Footer not idle → not promptable mid-work.
        activity = .working
        XCTAssertFalse(promptable())
    }

    @MainActor
    func testRemoteCloseSessionRemovesTab() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "close", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        var destroyedSessionIds: [String] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true)),
            gracefulSessionDestroyer: { sessionIds, _ in
                destroyedSessionIds.append(contentsOf: sessionIds)
                return Task {}
            }
        )

        XCTAssertEqual(model.closeRemoteSession(sessionId: session.id), .closed)
        XCTAssertEqual(model.closeRemoteSession(sessionId: session.id), .missing)
        XCTAssertTrue(model.projects[0].sessions.isEmpty)
        XCTAssertNil(model.projects[0].selectedSessionId)
        XCTAssertEqual(destroyedSessionIds, [session.id])
    }

    func testGracefulCloseRequestLifecycle() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let request = root.appendingPathComponent("\(sessionId).close-session-request")
        let secondSessionId = UUID().uuidString
        let secondRequest = root.appendingPathComponent(
            "\(secondSessionId).close-session-request"
        )
        let preservedSessionId = UUID().uuidString
        let preservedRequest = root.appendingPathComponent(
            "\(preservedSessionId).close-session-request"
        )

        XCTAssertTrue(SessionArtifacts.writeCloseSessionRequest(
            sessionId: sessionId,
            sessionsDirectory: root
        ))
        XCTAssertTrue(SessionArtifacts.writeCloseSessionRequest(
            sessionId: secondSessionId,
            sessionsDirectory: root
        ))
        XCTAssertTrue(SessionArtifacts.writeCloseSessionRequest(
            sessionId: preservedSessionId,
            sessionsDirectory: root
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRequest.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: preservedRequest.path))
    }

    func testLiveCLIProcessesIncludesTrackerAndMatchingParent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let bootTime = try XCTUnwrap(TranscriptController.currentBootTimeSeconds())
        let ownerURL = root.appendingPathComponent("\(sessionId).transcript-owner.json")
        func writeOwner(bootTime: String?, parentPID: pid_t? = getppid()) throws {
            var owner: [String: Any] = [
                "appSessionId": sessionId,
                "copilotSessionId": UUID().uuidString,
                "pid": ProcessInfo.processInfo.processIdentifier,
            ]
            owner["parentPid"] = parentPID
            owner["bootTime"] = bootTime
            try JSONSerialization.data(withJSONObject: owner).write(to: ownerURL)
        }

        try writeOwner(bootTime: nil)
        XCTAssertEqual(
            Set(TranscriptController.liveCLIProcesses(
                sessionId: sessionId,
                directory: root
            ).map(\.pid)),
            Set([getpid(), getppid()])
        )
        try writeOwner(bootTime: "{ sec = \(bootTime - 3_600), usec = 0 }")
        XCTAssertTrue(TranscriptController.liveCLIProcesses(
            sessionId: sessionId,
            directory: root
        ).isEmpty)
        try writeOwner(bootTime: "{ sec = \(bootTime), usec = 0 }")
        XCTAssertEqual(
            Set(TranscriptController.liveCLIProcesses(
                sessionId: sessionId,
                directory: root
            ).map(\.pid)),
            Set([getpid(), getppid()])
        )
        try writeOwner(bootTime: nil, parentPID: nil)
        XCTAssertEqual(
            Set(TranscriptController.liveCLIProcesses(sessionId: sessionId, directory: root).map(\.pid)),
            Set([getpid(), getppid()])
        )
        try writeOwner(bootTime: nil, parentPID: 1)
        XCTAssertEqual(
            Set(TranscriptController.liveCLIProcesses(sessionId: sessionId, directory: root).map(\.pid)),
            [getpid()]
        )
        // Only a marker that names this tab counts, in either letter case.
        let cases: [(appSessionId: String?, processes: Set<pid_t>)] = [
            (UUID().uuidString, []),
            (nil, []),
            (sessionId.lowercased(), [getpid(), getppid()]),
        ]
        for (appSessionId, processes) in cases {
            var owner: [String: Any] = [
                "copilotSessionId": UUID().uuidString,
                "pid": ProcessInfo.processInfo.processIdentifier,
                "parentPid": getppid(),
            ]
            owner["appSessionId"] = appSessionId
            try JSONSerialization.data(withJSONObject: owner).write(to: ownerURL)
            XCTAssertEqual(
                Set(TranscriptController.liveCLIProcesses(sessionId: sessionId, directory: root).map(\.pid)),
                processes
            )
        }
        XCTAssertTrue(TranscriptController.liveCLIProcesses(
            sessionId: UUID().uuidString,
            directory: root
        ).isEmpty)
    }

    @MainActor
    func testTrackerWarningDetectsDeadOwnerAndExperimentalOffWithoutStartupFalsePositives() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        let copilotHome = root.appendingPathComponent("copilot-home", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copilotHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CopilotSessionStore(environment: ["COPILOT_HOME": copilotHome.path], home: root.path)
        XCTAssertEqual(store.trackerWarningMessage(), RemoteSessionSnapshot.experimentalOffWarning)
        let settingsURL = copilotHome.appendingPathComponent("settings.json")
        try Data("// comment\n{\"experimental\": true}\n".utf8).write(to: settingsURL)
        XCTAssertEqual(store.trackerWarningMessage(), RemoteSessionSnapshot.trackerStoppedWarning)
        try Data("{\"experimental\": false, \"enabledFeatureFlags\": {\"EXTENSIONS\": true}}\n".utf8)
            .write(to: settingsURL)
        XCTAssertEqual(store.trackerWarningMessage(), RemoteSessionSnapshot.trackerStoppedWarning)
        try Data("{\"experimental\": true, \"enabledFeatureFlags\": {\"EXTENSIONS\": false}}\n".utf8)
            .write(to: settingsURL)
        XCTAssertEqual(store.trackerWarningMessage(), RemoteSessionSnapshot.extensionsDisabledWarning)
        try Data("{\"experimental\": false}\n".utf8).write(to: settingsURL)
        XCTAssertEqual(store.trackerWarningMessage(), RemoteSessionSnapshot.experimentalOffWarning)

        let copilotSession = Session(title: "copilot", cwd: root.path)
        let shellSession = Session(title: "shell", cwd: root.path)
        let remoteSession = Session(title: "remote", cwd: root.path, hostId: "devbox")
        let otherAgentSession = Session(title: "other-agent", cwd: root.path)
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: [copilotSession, shellSession, remoteSession, otherAgentSession],
            selectedSessionId: copilotSession.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: sessionsDir,
            resumeMarkerDirectory: sessionsDir
        )
        model.copilotTrackerWarningMessage = { store.trackerWarningMessage() }
        model.setLiveAgentSessionsForTesting(
            [copilotSession.id, remoteSession.id, otherAgentSession.id],
            copilotSessions: [copilotSession.id, remoteSession.id]
        )

        // Before 45s of missing heartbeat: no warning. Plain shell, remote SSH, and
        // non-Copilot agent sessions never record `trackerMissingSince`.
        model.refreshAgentActivitySnapshots(now: start)
        XCTAssertNil(model.projects[0].sessions[0].trackerWarning)
        XCTAssertEqual(Set(model.trackerMissingSince.keys), [copilotSession.id])
        model.refreshAgentActivitySnapshots(now: start.addingTimeInterval(44))
        XCTAssertNil(model.projects[0].sessions[0].trackerWarning)
        XCTAssertNil(model.projects[0].sessions[1].trackerWarning)
        XCTAssertNil(model.projects[0].sessions[2].trackerWarning)
        XCTAssertNil(model.projects[0].sessions[3].trackerWarning)

        // After 45s of missing heartbeat: shows the appropriate warning from settings.json
        // and projects it into `RemoteSessionSnapshot`.
        model.refreshAgentActivitySnapshots(now: start.addingTimeInterval(46))
        XCTAssertEqual(
            model.projects[0].sessions[0].trackerWarning,
            RemoteSessionSnapshot.experimentalOffWarning
        )
        XCTAssertNil(model.projects[0].sessions[3].trackerWarning)
        XCTAssertEqual(
            model.remoteWorkspaceSnapshot().projects[0].sessions[0].trackerWarning,
            RemoteSessionSnapshot.experimentalOffWarning
        )

        try Data("{\"experimental\": true, \"enabledFeatureFlags\": {\"EXTENSIONS\": false}}\n".utf8)
            .write(to: settingsURL)
        model.refreshAgentActivitySnapshots(now: start.addingTimeInterval(47))
        XCTAssertEqual(
            model.projects[0].sessions[0].trackerWarning,
            RemoteSessionSnapshot.extensionsDisabledWarning
        )

        try Data("{\"experimental\": true}\n".utf8).write(to: settingsURL)
        model.refreshAgentActivitySnapshots(now: start.addingTimeInterval(48))
        XCTAssertEqual(
            model.projects[0].sessions[0].trackerWarning,
            RemoteSessionSnapshot.trackerStoppedWarning
        )

        // A healthy heartbeat clears the warning and resets `trackerMissingSince`.
        let freshAt = start.addingTimeInterval(49)
        let activityURL = sessionsDir.appendingPathComponent("\(copilotSession.id).agent-activity.json")
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: ISO8601DateFormatter().string(from: freshAt),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        try JSONEncoder().encode(snapshot).write(to: activityURL)
        model.refreshAgentActivitySnapshots(now: freshAt)
        XCTAssertNil(model.projects[0].sessions[0].trackerWarning)
        XCTAssertNil(model.trackerMissingSince[copilotSession.id])

        // A fresh heartbeat reporting a terminal RPC disconnect counts as unhealthy
        // and warns after 45s.
        let disconnectAt = freshAt.addingTimeInterval(5)
        var disconnectedSnapshot = snapshot
        disconnectedSnapshot.updatedAt = ISO8601DateFormatter().string(from: disconnectAt)
        disconnectedSnapshot.error = "Connection is closed."
        try JSONEncoder().encode(disconnectedSnapshot).write(to: activityURL)
        model.refreshAgentActivitySnapshots(now: disconnectAt)
        XCTAssertNil(model.projects[0].sessions[0].trackerWarning)
        XCTAssertNotNil(model.trackerMissingSince[copilotSession.id])

        let postGraceAt = disconnectAt.addingTimeInterval(46)
        disconnectedSnapshot.updatedAt = ISO8601DateFormatter().string(from: postGraceAt)
        try JSONEncoder().encode(disconnectedSnapshot).write(to: activityURL)
        model.refreshAgentActivitySnapshots(now: postGraceAt)
        XCTAssertEqual(
            model.projects[0].sessions[0].trackerWarning,
            RemoteSessionSnapshot.trackerStoppedWarning
        )

        // When the Copilot process exits, `trackerMissingSince` and `trackerWarning` clear.
        model.setLiveAgentSessionsForTesting([])
        model.refreshAgentActivitySnapshots(now: postGraceAt.addingTimeInterval(1))
        XCTAssertNil(model.projects[0].sessions[0].trackerWarning)
        XCTAssertNil(model.trackerMissingSince[copilotSession.id])
    }

    @MainActor
    func testCloseProjectSchedulesEverySessionForGracefulDestruction() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [
            Session(title: "one", cwd: root.path),
            Session(title: "two", cwd: root.path),
        ]
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: sessions,
            selectedSessionId: sessions[0].id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        var destroyedSessionBatches: [[String]] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            gracefulSessionDestroyer: { sessionIds, _ in
                destroyedSessionBatches.append(sessionIds)
                return Task {}
            }
        )

        model.closeProject(project.id)

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(destroyedSessionBatches.count, 1)
        XCTAssertEqual(
            Set(destroyedSessionBatches[0]),
            Set(sessions.map(\.id))
        )
    }

    @MainActor
    func testForcePendingSessionDestroysUsesOneFallbackBatch() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [
            Session(title: "one", cwd: root.path),
            Session(title: "two", cwd: root.path),
        ]
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: sessions,
            selectedSessionId: sessions[0].id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        var gracefulBatches: [[String]] = []
        var forcedBatches: [[String]] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            gracefulSessionDestroyer: { sessionIds, _ in
                gracefulBatches.append(sessionIds)
                return Task {
                    try? await Task.sleep(for: .seconds(60))
                }
            },
            forcedSessionDestroyer: { forcedBatches.append($0) }
        )

        model.closeProject(project.id)
        model.forcePendingSessionDestroys()

        XCTAssertEqual(gracefulBatches.count, 1)
        XCTAssertEqual(forcedBatches.count, 1)
        XCTAssertEqual(Set(forcedBatches[0]), Set(sessions.map(\.id)))
    }

    @MainActor
    func testPowerOffDrainUsesOneFallbackBatch() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = [
            Session(title: "one", cwd: root.path),
            Session(title: "two", cwd: root.path),
        ]
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: sessions,
            selectedSessionId: sessions[0].id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        var forcedBatches: [[String]] = []
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            gracefulSessionDestroyer: { _, _ in
                Task {
                    try? await Task.sleep(for: .seconds(60))
                }
            },
            forcedSessionDestroyer: { forcedBatches.append($0) }
        )

        model.closeProject(project.id)
        model.prepareForSystemPowerOff()
        await model.detachAllClientsAndDrain()

        XCTAssertEqual(forcedBatches.count, 1)
        XCTAssertEqual(Set(forcedBatches[0]), Set(sessions.map(\.id)))
    }

    @MainActor
    func testBeginTerminationAllowsPendingSessionDestroyToFinish() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "close", cwd: root.path)
        let project = Project(
            name: "project",
            cwd: root.path,
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        let started = expectation(description: "destroy started")
        let finished = expectation(description: "destroy finished")
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            gracefulSessionDestroyer: { _, _ in
                Task {
                    started.fulfill()
                    try? await Task.sleep(for: .milliseconds(25))
                    XCTAssertFalse(Task.isCancelled)
                    finished.fulfill()
                }
            }
        )
        XCTAssertEqual(model.closeRemoteSession(sessionId: session.id), .closed)
        await fulfillment(of: [started], timeout: 1)

        model.beginTermination()

        await fulfillment(of: [finished], timeout: 1)
    }

    @MainActor
    func testRemoteMoveSessionPreservesTargetSelectionAndIsIdempotent() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let moved = Session(title: "move", cwd: root.path)
        let sourceFallback = Session(title: "source fallback", cwd: root.path)
        let targetSelected = Session(title: "target selected", cwd: root.path)
        let source = Project(
            name: "source",
            cwd: root.path,
            sessions: [moved, sourceFallback],
            selectedSessionId: moved.id
        )
        let target = Project(
            name: "target",
            cwd: root.path,
            sessions: [targetSelected],
            selectedSessionId: targetSelected.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [source, target],
            selectedProjectId: target.id
        ))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )

        XCTAssertEqual(
            model.moveRemoteSession(
                sessionId: moved.id,
                toProjectId: target.id
            ),
            .moved
        )
        XCTAssertEqual(model.projects[0].sessions.map(\.id), [sourceFallback.id])
        XCTAssertEqual(model.projects[0].selectedSessionId, sourceFallback.id)
        XCTAssertEqual(
            model.projects[1].sessions.map(\.id),
            [targetSelected.id, moved.id]
        )
        XCTAssertEqual(model.projects[1].selectedSessionId, targetSelected.id)
        XCTAssertEqual(model.globalSelectedSessionId, targetSelected.id)
        XCTAssertEqual(
            model.moveRemoteSession(
                sessionId: moved.id,
                toProjectId: target.id
            ),
            .unchanged
        )
        XCTAssertEqual(
            model.moveRemoteSession(
                sessionId: "missing",
                toProjectId: target.id
            ),
            .missing
        )
    }

    func testActivityTrackerRequiresObservedWorkAndTwoIdleTicks() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .working))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertTrue(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
    }

    func testActivityTrackerRequiresTwoWorkingTicksToPromoteIdleSession() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .unknown))
        XCTAssertFalse(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .working))
        XCTAssertTrue(tracker.shouldPromoteFromFooter(
            sessionId: sessionId, currentStatus: .idle, activity: .working))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        XCTAssertTrue(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
    }

    func testFooterDoesNotPromoteWhileBackgroundAgentsAreActive() {
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: true,
            hasLiveAgent: true
        ))
        XCTAssertTrue(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: true
        ))
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: false
        ))
    }

    func testForegroundIdleDemotesOnlyAfterTwoInactiveScans() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        // A single inactive scan is a normal inter-iteration gap: don't demote.
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
        // Two consecutive inactive scans mean the foreground turn really ended.
        XCTAssertTrue(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
    }

    func testDisconnectIdleDwellDoesNotReuseForegroundIdleTicks() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
        XCTAssertFalse(tracker.observeDisconnectIdle(
            sessionId: sessionId, currentStatus: .running))
        XCTAssertTrue(tracker.observeDisconnectIdle(
            sessionId: sessionId, currentStatus: .running))
    }

    func testDisconnectIdleDwellResetsWhenPolicyStopsQualifying() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.observeDisconnectIdle(
            sessionId: sessionId, currentStatus: .running))
        tracker.resetDisconnectIdle(sessionId: sessionId)
        XCTAssertFalse(tracker.observeDisconnectIdle(
            sessionId: sessionId, currentStatus: .running))
        XCTAssertTrue(tracker.observeDisconnectIdle(
            sessionId: sessionId, currentStatus: .running))
    }

    func testForegroundIdleDwellResetsWhenTurnResumes() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
        // Next agentic iteration starts — foreground turn active again resets dwell.
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: true))
        // A later lone inactive scan must not demote on its own.
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
        XCTAssertTrue(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .running, foregroundTurnActive: false))
    }

    func testForegroundIdleOnlyAppliesToRunningStatus() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        // Not running (e.g. waiting/idle): never demote via this path.
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .waiting, foregroundTurnActive: false))
        XCTAssertFalse(tracker.observeForegroundIdle(
            sessionId: sessionId, currentStatus: .waiting, foregroundTurnActive: false))
    }

    func testResetForegroundIdlePreservesFooterDwellState() {
        let sessionId = UUID().uuidString
        var tracker = ActivityTracker()
        // Build up footer-demote dwell state (saw working, one idle tick).
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .working))
        XCTAssertFalse(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
        // Clearing only the foreground-idle counter must not wipe footer progress.
        tracker.resetForegroundIdle(sessionId: sessionId)
        XCTAssertTrue(tracker.observeFooter(
            sessionId: sessionId, currentStatus: .running, activity: .idle))
    }

    func testForegroundTransitionMillisecondsParsesIndependentlyOfUpdatedAt() {
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: "2024-01-01T21:48:52.500Z",
            foregroundTurnActive: true,
            foregroundTransitionAt: "2024-01-01T21:48:52.123Z",
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        // The transition timestamp is used for the status clock; `updatedAt` (which
        // unrelated republishes bump) must not be conflated with it.
        XCTAssertEqual(snapshot.foregroundTransitionMilliseconds, 1_704_145_732_123)
    }

    func testForegroundTransitionMillisecondsNilForOlderSnapshots() {
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: "2024-01-01T21:48:52.123Z",
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        XCTAssertNil(snapshot.foregroundTransitionMilliseconds)
    }

    func testStatusEventClockRejectsLateHookEvents() {
        let sessionId = UUID().uuidString
        var clock = StatusEventClock()
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 200))
        XCTAssertFalse(clock.shouldApply(sessionId: sessionId, timestamp: 100))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: 300))
        XCTAssertTrue(clock.shouldApply(sessionId: sessionId, timestamp: nil))
    }

    func testPromptSafetyClockIgnoresScheduledActivityReaffirmations() {
        XCTAssertFalse(AppModel.advancesPromptSafetyClock(source: "scheduled-active"))
        XCTAssertTrue(AppModel.advancesPromptSafetyClock(source: "scheduled-start"))
        XCTAssertTrue(AppModel.advancesPromptSafetyClock(source: "scheduled-idle"))
        XCTAssertTrue(AppModel.advancesPromptSafetyClock(source: nil))
    }

    @MainActor
    func testActiveStatusClearsStaleReadyMarker() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        model.setStatus(sessionId: targetSession.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(sessionId: targetSession.id, status: .idle, text: nil, timestamp: 200)

        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertEqual(model.totalReady, 1)

        model.setStatus(sessionId: targetSession.id, status: .running, text: nil, timestamp: 300)

        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)

        model.setStatus(sessionId: targetSession.id, status: .idle, text: nil, timestamp: 400)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)

        model.setStatus(sessionId: targetSession.id, status: .waiting, text: nil, timestamp: 500)

        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)
    }

    @MainActor
    func testSessionEndClearsResumeMarkerOnlyWhileAppIsRunning() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let marker = sessions.appendingPathComponent("\(session.id).copilot-session")
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        let model = AppModel(
            stateRepository: repository,
            resumeMarkerDirectory: sessions
        )
        let firstCopilotSession = UUID().uuidString
        try Data(firstCopilotSession.utf8).write(to: marker)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "session-end",
            copilotSessionId: firstCopilotSession
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        let powerOffCopilotSession = UUID().uuidString
        try Data(powerOffCopilotSession.utf8).write(to: marker)
        model.prepareForSystemPowerOff()
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 150,
            source: "session-end",
            copilotSessionId: powerOffCopilotSession
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        model.beginTermination()
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "session-end",
            copilotSessionId: powerOffCopilotSession
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testStaleSessionEndDoesNotClearResumeMarkers() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let markers = ["copilot-session"].map {
            sessions.appendingPathComponent("\(session.id).\($0)")
        }
        let ownerCopilotSession = UUID().uuidString
        for marker in markers {
            try Data(ownerCopilotSession.utf8).write(to: marker)
        }

        let model = AppModel(
            stateRepository: repository,
            resumeMarkerDirectory: sessions
        )
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 200)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "session-end",
            copilotSessionId: ownerCopilotSession
        )

        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }

        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 300,
            source: "session-end",
            copilotSessionId: UUID().uuidString
        )

        for marker in markers {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @MainActor
    func testPowerOffProtectionExpiresAfterCancelledShutdown() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let model = AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json"))
        )
        model.prepareForSystemPowerOff(protectionInterval: 0)
        XCTAssertTrue(model.isPoweringOff)
        XCTAssertTrue(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: false,
            isPoweringOff: true
        ))
        XCTAssertTrue(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: true,
            isPoweringOff: false
        ))
        XCTAssertFalse(AppModel.shouldPreserveSessionAfterTerminalExit(
            isTerminating: false,
            isPoweringOff: false
        ))

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(model.isPoweringOff)
    }

    @MainActor
    func testCompletionNotificationUsesAgentStopAndWaitsForBackgroundAgents() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let immediateSession = Session(title: "immediate", cwd: "/tmp")
        let backgroundSession = Session(title: "background", cwd: "/tmp")
        let targetProject = Project(
            name: "target",
            cwd: "/tmp",
            sessions: [immediateSession, backgroundSession]
        )
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        let notifications = NotificationSpy()
        let immediateCompletion = expectation(description: "agentStop posts completion")
        notifications.onPost = { call in
            if call.sessionId == immediateSession.id {
                immediateCompletion.fulfill()
            }
        }
        model.attach(notifications: notifications)
        model.setStatus(
            sessionId: immediateSession.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: immediateSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        await fulfillment(of: [immediateCompletion], timeout: 1)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · immediate",
                body: nil,
                projectId: targetProject.id,
                sessionId: immediateSession.id
            )
        ])
        XCTAssertEqual(notifications.events.first?.kind, .completed)
        XCTAssertNotNil(notifications.events.first?.sentAt)
        XCTAssertTrue(
            notifications.events.first?.displayedBody.contains("Sent at ") == true
        )

        let prematureCompletion = expectation(description: "background agents suppress completion")
        prematureCompletion.isInverted = true
        notifications.onPost = { call in
            if call.sessionId == backgroundSession.id {
                prematureCompletion.fulfill()
            }
        }
        model.setBackgroundAgentsActive(sessionId: backgroundSession.id, active: true)
        model.setStatus(
            sessionId: backgroundSession.id,
            status: .running,
            text: nil,
            timestamp: 300
        )
        model.setStatus(
            sessionId: backgroundSession.id,
            status: .idle,
            text: nil,
            timestamp: 400,
            source: "agent-stop"
        )
        await fulfillment(of: [prematureCompletion], timeout: 0.1)
        XCTAssertFalse(model.projects[0].sessions[1].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[1].finishedUnseen)
        XCTAssertFalse(model.remoteWorkspaceSnapshot().projects[0].sessions[1].ready)
        XCTAssertEqual(model.totalReady, 1)
        XCTAssertEqual(notifications.calls.count, 1)

        notifications.onPost = nil
        model.setBackgroundAgentsActive(sessionId: backgroundSession.id, active: false)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[1].finishedUnseen)
        XCTAssertTrue(model.remoteWorkspaceSnapshot().projects[0].sessions[1].ready)
        XCTAssertEqual(model.totalReady, 2)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · immediate",
                body: nil,
                projectId: targetProject.id,
                sessionId: immediateSession.id
            ),
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · background",
                body: nil,
                projectId: targetProject.id,
                sessionId: backgroundSession.id
            )
        ])
    }

    @MainActor
    func testCompletionIndicatorWaitsForLateSubagentSnapshot() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "review", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        let project = Project(name: "reviews", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: nil))
        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            isAppActive: { false },
            agentActivityDirectory: activityDirectory,
            remotePromptTarget: { _ in RemotePromptTarget(activity: .idle) }
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: session.id, status: .idle, text: nil,
            timestamp: 200, source: "agent-stop"
        )
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)
        XCTAssertFalse(model.remoteWorkspaceSnapshot().projects[0].sessions[0].ready)

        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [
                TrackedSubagent(id: "reviewer", name: "reviewer", description: "", model: nil),
            ],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let snapshotURL = activityDirectory
            .appendingPathComponent("\(session.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        model.refreshAgentActivitySnapshots()
        let prematureCompletion = expectation(description: "subagents suppress completion")
        prematureCompletion.isInverted = true
        notifications.onPost = { _ in prematureCompletion.fulfill() }
        await fulfillment(of: [prematureCompletion], timeout: 0.1)
        XCTAssertEqual(model.projects[0].sessions[0].activeSubagentCount, 1)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertEqual(model.totalReady, 0)
        XCTAssertFalse(model.remoteWorkspaceSnapshot().projects[0].sessions[0].ready)
        XCTAssertTrue(notifications.calls.isEmpty)

        notifications.onPost = nil
        snapshot.activeSubagents = []
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        model.refreshAgentActivitySnapshots()
        model.reconcileAgentFooters()
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertEqual(model.totalReady, 1)
        XCTAssertTrue(model.remoteWorkspaceSnapshot().projects[0].sessions[0].ready)
        XCTAssertEqual(notifications.calls.count, 1)

        model.reconcileAgentFooters()
        XCTAssertEqual(notifications.calls.count, 1)
    }

    @MainActor
    func testMarkSessionReadClearsUnreadWithoutMovingSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = Session(title: "target", cwd: "/tmp")
        let visible = Session(title: "visible", cwd: "/tmp")
        // The project is selected on `visible`, so `target` completes while it is
        // not the on-screen session and picks up unread/finished flags.
        let project = Project(
            name: "p",
            cwd: "/tmp",
            sessions: [target, visible],
            selectedSessionId: visible.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000
        )
        model.setStatus(sessionId: target.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: target.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "agent-stop"
        )
        model.postCompletionIfReady(sessionId: target.id)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[0].finishedUnseen)

        // A remote read (e.g. the iOS session screen appearing) clears the flags…
        model.markSessionRead(sessionId: target.id)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)

        // …without moving the Mac's selection or touching the other session.
        XCTAssertEqual(model.selectedProjectId, project.id)
        XCTAssertEqual(model.projects[0].selectedSessionId, visible.id)

        // Unknown ids are a no-op rather than a crash.
        model.markSessionRead(sessionId: "does-not-exist")
    }

    @MainActor
    func testVisibleCompletionPostsNoNotification() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "visible", cwd: "/tmp")
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { true }
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 110,
            source: "agent-stop"
        )
        model.postCompletionIfReady(sessionId: session.id)

        XCTAssertTrue(model.projects[0].sessions[0].turnCompleted)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertTrue(notifications.calls.isEmpty)
    }

    @MainActor
    func testPromptNotificationsTrackWhetherTargetTabIsVisible() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "visible", cwd: "/tmp")
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))

        var appIsActive = true
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { appIsActive }
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)

        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 100,
            notification: .elicitation
        )
        XCTAssertTrue(try XCTUnwrap(notifications.events.first).isTargetVisible)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)

        appIsActive = false
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 101,
            notification: .elicitation
        )
        XCTAssertFalse(try XCTUnwrap(notifications.events.last).isTargetVisible)
        XCTAssertEqual(notifications.events.count, 2)
        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
    }

    func testPermissionNotificationDecisionUsesAuthoritativePendingState() {
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .waiting,
                hasPendingQuestions: false,
                pendingPermissionRequestIds: ["request"]
            ),
            .post
        )
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .waiting,
                hasPendingQuestions: false,
                pendingPermissionRequestIds: []
            ),
            .suppress
        )
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .waiting,
                hasPendingQuestions: false,
                pendingPermissionRequestIds: nil
            ),
            .post
        )
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .running,
                hasPendingQuestions: false,
                pendingPermissionRequestIds: ["request"]
            ),
            .cancel
        )
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .waiting,
                hasPendingQuestions: true,
                pendingPermissionRequestIds: []
            ),
            .cancel
        )
        XCTAssertEqual(
            AppModel.permissionNotificationDecision(
                status: .waiting,
                hasPendingQuestions: true,
                pendingPermissionRequestIds: ["permission"]
            ),
            .post
        )
    }

    @MainActor
    func testAutoApprovedPermissionIsSuppressedAndRestoresScheduledStatus() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var session = Session(title: "scheduled", cwd: "/tmp")
        session.scheduledTurnActive = true
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        try writePermissionSnapshot(
            sessionId: session.id,
            pendingIds: [],
            directory: root
        )

        var persisted: [(SessionStatus, Int64, Int64)] = []
        let model = AppModel(
            stateRepository: repository,
            permissionNotificationDelayNanoseconds: 5_000_000,
            persistPermissionStatus: { _, status, timestamp, promptTimestamp in
                persisted.append((status, timestamp, promptTimestamp))
            },
            agentActivityDirectory: root
        )
        let notifications = NotificationSpy()
        let unexpected = expectation(description: "auto-approved prompt does not notify")
        unexpected.isInverted = true
        notifications.onPost = { _ in unexpected.fulfill() }
        model.attach(notifications: notifications)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 90,
            source: "scheduled-active"
        )

        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 100,
            notification: .permission
        )

        await fulfillment(of: [unexpected], timeout: 0.05)
        XCTAssertEqual(model.projects[0].sessions[0].status, .idle)
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive)
        XCTAssertTrue(notifications.events.isEmpty)
        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted.first?.0, .idle)
        XCTAssertEqual(persisted.first?.1, 100)
        XCTAssertEqual(persisted.first?.2, 100)
    }

    @MainActor
    func testReadReceiptHoldsAcrossAnAutoApprovedPermissionWait() async throws {
        _ = NSApplication.shared
        let originalDockBadge = NSApp.dockTile.badgeLabel
        defer { NSApp.dockTile.badgeLabel = originalDockBadge }
        try await assertReadReceiptHolds(sentDuringPermissionWait: true)
        try await assertReadReceiptHolds(sentDuringPermissionWait: false)
    }

    @MainActor
    private func assertReadReceiptHolds(sentDuringPermissionWait: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let shown = Session(title: "shown", cwd: "/tmp")
        let session = Session(title: "finished", cwd: "/tmp")
        let project = Project(
            name: "selected", cwd: "/tmp", sessions: [shown, session], selectedSessionId: shown.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try writePermissionSnapshot(sessionId: session.id, pendingIds: [], directory: root)
        let restored = expectation(description: "the auto-approved wait is undone")
        let model = AppModel(
            stateRepository: repository,
            permissionNotificationDelayNanoseconds: 0,
            persistPermissionStatus: { _, _, _, _ in restored.fulfill() },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root
        )
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(sessionId: session.id, status: .idle, text: nil, timestamp: 200, source: "session-end")
        model.postNotification(projectId: project.id, sessionId: session.id, title: "Update", body: nil)
        let seen = model.remoteWorkspaceSnapshot().projects[0].sessions[1]
        XCTAssertTrue(seen.unread && seen.ready)
        let marker = try XCTUnwrap(seen.unreadMarker)

        model.setStatus(
            sessionId: session.id, status: .waiting, text: nil, timestamp: 300, notification: .permission
        )
        XCTAssertFalse(model.projects[0].sessions[1].finishedUnseen, "The wait hides the finished dot")
        if sentDuringPermissionWait {
            model.markSessionRead(sessionId: session.id, unreadMarker: marker)
        }
        await fulfillment(of: [restored], timeout: 5)
        if !sentDuringPermissionWait {
            XCTAssertTrue(model.projects[0].sessions[1].finishedUnseen, "The dot is back once the wait ends")
            model.markSessionRead(sessionId: session.id, unreadMarker: marker)
        }

        let current = model.remoteWorkspaceSnapshot().projects[0].sessions[1]
        XCTAssertFalse(
            current.unread || current.ready,
            "Nothing newer happened, so the receipt applies (sent during the wait: \(sentDuringPermissionWait))"
        )
    }

    @MainActor
    func testPendingPermissionPostsOnceAndLaterStatusCancels() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "permission", cwd: "/tmp")
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        try writePermissionSnapshot(
            sessionId: session.id,
            pendingIds: ["request"],
            directory: root
        )

        let model = AppModel(
            stateRepository: repository,
            permissionNotificationDelayNanoseconds: 10_000_000,
            agentActivityDirectory: root
        )
        let notifications = NotificationSpy()
        let posted = expectation(description: "pending permission posts")
        notifications.onPost = { _ in posted.fulfill() }
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 90)
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 100,
            notification: .permission
        )
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 101,
            notification: .permission
        )
        await fulfillment(of: [posted], timeout: 0.2)
        XCTAssertEqual(notifications.events.count, 1)

        notifications.onPost = nil
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 102,
            notification: .permission
        )
        model.setStatus(
            sessionId: session.id,
            status: .running,
            text: nil,
            timestamp: 103
        )
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(notifications.events.count, 1)
    }

    @MainActor
    func testPermissionDecisionReadsSnapshotAtFireTime() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "late permission", cwd: "/tmp")
        let project = Project(
            name: "selected",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        try writePermissionSnapshot(
            sessionId: session.id,
            pendingIds: [],
            directory: root
        )

        let model = AppModel(
            stateRepository: repository,
            permissionNotificationDelayNanoseconds: 50_000_000,
            agentActivityDirectory: root
        )
        let notifications = NotificationSpy()
        let posted = expectation(description: "late permission snapshot posts")
        notifications.onPost = { _ in posted.fulfill() }
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 90)
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 100,
            notification: .permission
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        try writePermissionSnapshot(
            sessionId: session.id,
            pendingIds: ["late-request"],
            directory: root
        )

        await fulfillment(of: [posted], timeout: 0.2)
        XCTAssertEqual(notifications.events.count, 1)
        XCTAssertEqual(model.projects[0].sessions[0].status, .waiting)
    }

    private func writePermissionSnapshot(
        sessionId: String,
        pendingIds: [String]?,
        directory: URL
    ) throws {
        let snapshot = AgentActivitySnapshot(
            schemaVersion: AgentActivitySnapshot.currentSchemaVersion,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: true,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            pendingPermissionRequestIds: pendingIds
        )
        try JSONEncoder().encode(snapshot).write(
            to: directory.appendingPathComponent("\(sessionId).agent-activity.json"),
            options: .atomic
        )
    }

    @MainActor
    private final class NotificationSpy: NotificationPosting {
        struct Call: Equatable {
            let title: String
            let subtitle: String?
            let body: String?
            let projectId: String?
            let sessionId: String?
        }

        private(set) var calls: [Call] = []
        private(set) var events: [NotificationEvent] = []
        var onPost: ((Call) -> Void)?

        func post(_ event: NotificationEvent) {
            let call = Call(
                title: event.title,
                subtitle: event.subtitle,
                body: event.body,
                projectId: event.projectId,
                sessionId: event.sessionId
            )
            calls.append(call)
            events.append(event)
            onPost?(call)
        }
    }

    func testRemoteNotificationPayloadDecodesLegacyShowPayloads() throws {
        let id = UUID()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(RemoteNotificationPayload.self, from: Data("""
        {
          "id": "\(id.uuidString)",
          "kind": "completed",
          "title": "Complete",
          "body": "Done",
          "projectId": "project",
          "sessionId": "session",
          "sentAt": "2026-07-13T05:45:00Z"
        }
        """.utf8))

        XCTAssertEqual(payload.action, .show)
        XCTAssertEqual(payload.id, id)
    }

    func testFocusDeepLinkParsing() throws {
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?project=project-1"
            ))),
            AppDeepLink(projectId: "project-1", sessionId: nil)
        )
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?session=session%202"
            ))),
            AppDeepLink(projectId: nil, sessionId: "session 2")
        )
        XCTAssertEqual(
            AppDeepLink(url: try XCTUnwrap(URL(
                string: "copilot-projects://focus?project=&project=project-2&session=session-2"
            ))),
            AppDeepLink(projectId: "project-2", sessionId: "session-2")
        )
    }

    func testFocusDeepLinkRejectsUnsupportedOrEmptyURLs() throws {
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "https://focus?session=session-1"
        ))))
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "copilot-projects://notify?session=session-1"
        ))))
        XCTAssertNil(AppDeepLink(url: try XCTUnwrap(URL(
            string: "copilot-projects://focus?project=&session=%20"
        ))))
    }

    func testFocusDeepLinkBuildsRequestAndLocatesParentApplication() throws {
        let deepLink = AppDeepLink(projectId: "project-1", sessionId: "session-1")
        XCTAssertEqual(deepLink.focusRequest.command, "focus")
        XCTAssertEqual(deepLink.focusRequest.projectId, "project-1")
        XCTAssertEqual(deepLink.focusRequest.sessionId, "session-1")

        let helperURL = URL(fileURLWithPath:
            "/Applications/Copilot Projects.app/Contents/Helpers/Copilot Projects Link.app")
        XCTAssertEqual(
            AppDeepLink.parentApplicationURL(forHelperBundleURL: helperURL)?.path,
            "/Applications/Copilot Projects.app"
        )
        XCTAssertNil(AppDeepLink.parentApplicationURL(
            forHelperBundleURL: URL(fileURLWithPath: "/Applications/Other.app")
        ))
    }

    func testCopilotHookIgnoresNotificationsThatAreNotInputWaits() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let backgroundAgents = sessions.appendingPathComponent("\(tabId).background-agents")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: backgroundAgents)

        // What cli-1.0.107 sends besides the two input waits, then the `session_idle`
        // type the runtime never shipped.
        for type in [
            "agent_idle", "agent_completed", "shell_completed", "shell_detached_completed",
            "new_inbox_message", "session_idle",
        ] {
            try runHook(
                hookURL: hookURL,
                action: "notify",
                payload: #"{"timestamp":200,"notificationType":"\#(type)"}"#,
                tabId: tabId,
                root: root,
                bin: bin,
                capture: capture
            )
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: sessions.path),
            [backgroundAgents.lastPathComponent]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))

        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":300}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundAgents.path))
    }

    func testCopilotHookUsesResolvedSessionForFilesAndLiveStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let resolverDirectory = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: resolverDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookURL.path
        )

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLI.path
        )

        let stale = "6780CCA3-92AF-4506-95F2-F018A195A1A1"
        let resolved = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let resolver = resolverDirectory.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' '\(resolved)'
        """.write(to: resolver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: resolver.path
        )

        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":100}"#,
            tabId: stale,
            root: root,
            bin: bin,
            capture: capture
        )

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(resolved).status-record.json").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(stale).status-record.json").path
        ))
        XCTAssertEqual(
            try cliCallLines(in: capture),
            ["set-status idle --session \(resolved) --timestamp 100"]
        )
    }

    func testCopilotHookSkipsResolverOutsideManagedTerminal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolverDirectory = root.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resolverDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookURL.path
        )
        let called = root.appendingPathComponent("resolver-called")
        let resolver = resolverDirectory.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        : > "$RESOLVER_CALLED"
        exit 1
        """.write(to: resolver, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: resolver.path
        )

        let process = Process()
        let input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookURL.path, "start"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["RESOLVER_CALLED"] = called.path
        environment["COPILOT_PROJECTS_SESSION"] = nil
        environment["COPILOT_PROJECTS_SOCKET"] = nil
        process.environment = environment
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(#"{"timestamp":100}"#.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: called.path))
    }

    func testCopilotHookDelegatesSessionEndResumeCleanupToApp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: hookURL.path
        )

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLI.path
        )

        let tabId = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let marker = sessions.appendingPathComponent("\(tabId).copilot-session")
        try Data(UUID().uuidString.utf8).write(to: marker)

        try runHook(
            hookURL: hookURL,
            action: "end",
            payload: #"{"timestamp":200,"reason":"user_exit"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try cliCallLines(in: capture),
            ["set-status idle --session \(tabId) --timestamp 200 --source session-end"]
        )

        let copilotSessionId = UUID().uuidString
        try Data(copilotSessionId.utf8).write(to: marker)
        try runHook(
            hookURL: hookURL,
            action: "end",
            payload: #"{"timestamp":210,"reason":"user_exit","sessionId":"\#(copilotSessionId)"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try cliCallLines(in: capture).last,
            "set-status idle --session \(tabId) --timestamp 210 --source session-end --copilot-session \(copilotSessionId)"
        )
    }

    func testCopilotHookDoesNotOverwriteResumeMarkerFromInheritedHelper() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        let ownerCopilotSession = UUID().uuidString
        let helperCopilotSession = UUID().uuidString
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let marker = sessions.appendingPathComponent("\(tabId).copilot-session")
        try Data(ownerCopilotSession.utf8).write(to: marker)

        try runHook(
            hookURL: hookURL,
            action: "pre",
            payload: #"{"timestamp":200,"sessionId":"\#(helperCopilotSession)"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), ownerCopilotSession)
    }

    func testCopilotHookCarriesConversationIdentityThroughCompletion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let hookURL = root.appendingPathComponent("hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        let capture = root.appendingPathComponent("args.txt")
        let cli = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        let tabId = UUID().uuidString
        let conversationId = UUID().uuidString
        for (action, extra) in [
            ("running", ""),
            ("idle", ""),
            ("notify", ",\"notification_type\":\"elicitation_dialog\""),
        ] {
            try runHook(
                hookURL: hookURL,
                action: action,
                payload: "{\"sessionId\":\"\(conversationId)\",\"timestamp\":100\(extra)}",
                tabId: tabId, root: root, bin: bin, capture: capture
            )
        }
        let calls = try cliCallLines(in: capture)
        XCTAssertEqual(calls.count, 3)
        XCTAssertFalse(calls[0].contains("--copilot-session"))
        XCTAssertTrue(calls.dropFirst().allSatisfy { $0.contains("--copilot-session \(conversationId)") })
        XCTAssertTrue(calls[1].contains("--source agent-stop"))
        XCTAssertTrue(calls[2].contains("--notification elicitation"))
    }

    func testCopilotHookRoutesNativeNotificationsForWaitingAndCompletedTurns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":100}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertEqual(
            try hookStatusRecord(root: root, tabId: tabId).promptStatusTimestamp,
            100
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":120,"notification_type":"elicitation_dialog"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        var cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls, [
            "set-status idle --session \(tabId) --timestamp 100",
            "set-status waiting --session \(tabId) --timestamp 120 --notification elicitation",
        ])

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":125,"notification_type":"permission_prompt"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(
            cliCalls.last,
            "set-status waiting --session \(tabId) --timestamp 125"
        )

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":130}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":135}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.suffix(2), [
            "set-status running --session \(tabId) --timestamp 130",
            "set-status idle --session \(tabId) --timestamp 135 --source agent-stop",
        ])
        // A second stop finds no turn to claim, so it is not another completion.
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":140}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertEqual(
            try cliCallLines(in: capture).last,
            "set-status idle --session \(tabId) --timestamp 140"
        )

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":190}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":195,"aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.filter { $0.contains("--source agent-stop") }.count, 1)
        XCTAssertEqual(cliCalls.suffix(2), [
            "set-status running --session \(tabId) --timestamp 190",
            "set-status idle --session \(tabId) --timestamp 195",
        ])
        XCTAssertEqual(cliCalls.count, 8)
    }

    func testCopilotHookKeepsScheduledTurnsOutOfForegroundStatus() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let hookURL = root.appendingPathComponent("copilot-projects-hook.sh")
        try CopilotHooks.script.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookURL.path)

        let capture = root.appendingPathComponent("cli-args.txt")
        let fakeCLI = bin.appendingPathComponent("copilot-projects")
        try """
        #!/bin/sh
        printf '%s\n' "$*" >> "$CAPTURE_FILE"
        """.write(to: fakeCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCLI.path)

        let tabId = UUID().uuidString
        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":100,"prompt":"[Scheduled prompt #16] Check PRs"}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "pre",
            payload: #"{"timestamp":110}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        let record = try hookStatusRecord(root: root, tabId: tabId)
        XCTAssertEqual(record.status, .idle)
        XCTAssertEqual(record.statusTimestamp, 110)
        XCTAssertEqual(record.promptStatusTimestamp, 100)
        try runHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":115}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        let calls = try cliCallLines(in: capture)
        XCTAssertTrue(calls.contains(
            "set-status idle --session \(tabId) --timestamp 100 --source scheduled-start"
        ))
        XCTAssertTrue(calls.contains(
            "set-status idle --session \(tabId) --timestamp 110 --source scheduled-active"
        ))
        XCTAssertTrue(calls.contains(
            "set-status idle --session \(tabId) --timestamp 115 --source scheduled-idle"
        ))
        XCTAssertEqual(
            try hookStatusRecord(root: root, tabId: tabId).promptStatusTimestamp,
            115
        )
        XCTAssertFalse(calls.contains { $0.contains("--source agent-stop") })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("sessions/\(tabId).scheduled-turn").path
        ))
    }

    @MainActor
    func testAgentActivitySnapshotTracksSchedulesAndBackgroundWork() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: true,
            activeSubagents: [
                TrackedSubagent(
                    id: "agent-1",
                    name: "reviewer",
                    description: "Reviews the PR",
                    model: "gpt"
                ),
            ],
            schedules: [
                TrackedSchedule(
                    id: 16,
                    intervalMs: 600_000,
                    cron: nil,
                    tz: nil,
                    at: nil,
                    prompt: "Check PRs",
                    recurring: true,
                    displayPrompt: "/my-prs-status",
                    nextRunAt: ISO8601DateFormatter().string(
                        from: Date().addingTimeInterval(600)
                    )
                ),
            ],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots()

        XCTAssertEqual(model.projects[0].sessions[0].status, .idle)
        XCTAssertTrue(model.projects[0].sessions[0].scheduledTurnActive)
        XCTAssertEqual(model.projects[0].sessions[0].activeSubagentCount, 1)
        XCTAssertEqual(model.projects[0].sessions[0].schedules.first?.id, 16)
        XCTAssertTrue(model.projects[0].sessions[0].schedules[0].helpText.contains(
            "Every 10m"
        ))
        XCTAssertTrue(model.projects[0].sessions[0].schedules[0].helpText.contains(
            "Runs next at"
        ))
        XCTAssertEqual(model.totalScheduled, 1)

        var stale = snapshot
        stale.updatedAt = "2000-01-01T00:00:00Z"
        try JSONEncoder().encode(stale).write(to: path)
        model.refreshAgentActivitySnapshots()

        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertFalse(model.projects[0].sessions[0].scheduledTurnActive)
    }

    @MainActor
    func testAgentActivityRefreshIsIdempotentAndClearsOnDeletion() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject],
            selectedProjectId: targetProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: true,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertNotNil(model.projects[0].sessions[0].agentActivity)

        var projectPublications = 0
        let projectChanges = model.objectWillChange.sink { projectPublications += 1 }

        // A second scan with no file change must neither clear the snapshot nor
        // publish the same projects value again.
        model.refreshAgentActivitySnapshots()
        XCTAssertNotNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(projectPublications, 0)

        // Deleting the file (not just TTL expiry) must still nil the snapshot — the
        // guard must detect the value change from present to nil, not skip it.
        try FileManager.default.removeItem(at: path)
        model.refreshAgentActivitySnapshots()
        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
        XCTAssertEqual(projectPublications, 1)
        withExtendedLifetime(projectChanges) {}
    }

    @MainActor
    func testAgentActivityRefreshReappliesTTLOnUnchangedFile() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject], selectedProjectId: targetProject.id
        ))

        let base = Date()
        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: base),
            foregroundTurnActive: true,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository, agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots(now: base)
        XCTAssertNotNil(model.projects[0].sessions[0].agentActivity)

        // The file never changes, so the second scan takes the mtime-gated cache
        // path (no re-read). Freshness must still be re-applied against the newer
        // `now`, so a snapshot past its 15s TTL is cleared without any file write —
        // the correctness trap of skipping reads.
        model.refreshAgentActivitySnapshots(now: base.addingTimeInterval(20))
        XCTAssertNil(model.projects[0].sessions[0].agentActivity)
    }

    @MainActor
    func testAgentActivityRefreshSkipsRereadWhenFileSignatureUnchanged() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject], selectedProjectId: targetProject.id
        ))

        let updatedAt = ISO8601DateFormatter().string(from: Date())
        func snapshot(idleGeneration: Int) -> AgentActivitySnapshot {
            AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: updatedAt,
                foregroundTurnActive: true,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: idleGeneration,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil
            )
        }
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        let dataA = try JSONEncoder().encode(snapshot(idleGeneration: 0))
        let dataB = try JSONEncoder().encode(snapshot(idleGeneration: 9))
        // A single-digit change keeps the byte length identical, so an in-place
        // overwrite leaves size unchanged; a FileHandle write keeps the inode; and
        // pinning both writes to the SAME fixed mtime keeps the modification date
        // bit-identical (a natural write's mtime can't be restored exactly). Together
        // the (size, mtime, inode) signature is unchanged — the case the gate skips.
        XCTAssertEqual(dataA.count, dataB.count)
        let pinnedMtime = Date(timeIntervalSince1970: 1_600_000_000)
        try dataA.write(to: path)
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime], ofItemAtPath: path.path
        )

        let model = AppModel(
            stateRepository: repository, agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.projects[0].sessions[0].agentActivity?.idleGeneration, 0)

        // Overwrite the bytes in place via a FileHandle (keeps the same inode, unlike
        // Data.write which can allocate a new one), then re-pin the identical mtime so
        // the (size, mtime, inode) signature matches the cached one exactly.
        let handle = try FileHandle(forWritingTo: path)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: dataB)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: pinnedMtime], ofItemAtPath: path.path
        )

        // Signature unchanged → the gate returns the cached snapshot and never reads
        // the new bytes, so idleGeneration stays 0 (it would be 9 on a re-read).
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.projects[0].sessions[0].agentActivity?.idleGeneration, 0)
    }

    @MainActor
    func testAgentActivityRefreshFailsClosedAndRetriesAfterReadFailure() throws {
        // A 0o000 file denies reads only to non-root users; root bypasses it (the read
        // would succeed and the branch wouldn't be exercised).
        try XCTSkipIf(getuid() == 0, "root bypasses 0o000 permissions")
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: "/tmp")
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject], selectedProjectId: targetProject.id
        ))

        let updatedAt = ISO8601DateFormatter().string(from: Date())
        func snapshot(idleGeneration: Int) -> AgentActivitySnapshot {
            AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: updatedAt,
                foregroundTurnActive: true,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: idleGeneration,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil
            )
        }
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot(idleGeneration: 0)).write(to: path)

        let model = AppModel(
            stateRepository: repository, agentActivityDirectory: activityDirectory
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.projects[0].sessions[0].agentActivity?.idleGeneration, 0)

        // Rewrite the file (new signature → forces a read attempt) then make it
        // unreadable. The gate must FAIL CLOSED (nil), never serve the stale
        // last-known snapshot to promptability decisions, and must not cache a nil
        // against the signature.
        try JSONEncoder().encode(snapshot(idleGeneration: 9)).write(to: path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: path.path
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertNil(model.projects[0].sessions[0].agentActivity)

        // Restore readability. chmod leaves size/mtime/inode unchanged, so the
        // signature is identical to the failed read's — a poisoned cache would return
        // the stuck nil; the fix re-reads and picks up the new content.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: path.path
        )
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.projects[0].sessions[0].agentActivity?.idleGeneration, 9)
    }

    @MainActor
    func testAgentActivityWatcherThrottleCoalescesTrailingAndSustainedScans() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: root.path, sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject],
            selectedProjectId: targetProject.id
        ))

        let cooldown = AgentActivityCooldownHarness()
        let scans = ScanCounter()
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: activityDirectory,
            agentActivityRefreshThrottle: 1.25,
            agentActivityCooldownScheduler: { delay, action in
                cooldown.schedule(after: delay, action: action)
            },
            agentActivityScanObserver: scans.increment
        )

        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 1)
        XCTAssertEqual(cooldown.delays, [1.25])
        XCTAssertEqual(cooldown.scheduledCount, 1)

        model.throttledRefreshAgentActivitySnapshots()
        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 1)
        XCTAssertEqual(cooldown.scheduledCount, 1)

        cooldown.runNext()
        XCTAssertEqual(scans.value, 2)
        XCTAssertEqual(cooldown.scheduledCount, 1)

        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 2)

        cooldown.runNext()
        XCTAssertEqual(scans.value, 3)
        XCTAssertEqual(cooldown.scheduledCount, 1)

        cooldown.runNext()
        XCTAssertEqual(scans.value, 3)
        XCTAssertEqual(cooldown.scheduledCount, 0)

        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 4)
        XCTAssertEqual(cooldown.scheduledCount, 1)
    }

    @MainActor
    func testAgentActivityWatcherIgnoresStaleCooldownAfterTrackingRestart() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "target", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: targetSession.id) }
        let targetProject = Project(name: "target", cwd: root.path, sessions: [targetSession])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject],
            selectedProjectId: targetProject.id
        ))

        let cooldown = AgentActivityCooldownHarness()
        let scans = ScanCounter()
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: activityDirectory,
            agentActivityRefreshThrottle: 1.25,
            agentActivityCooldownScheduler: { delay, action in
                cooldown.schedule(after: delay, action: action)
            },
            agentActivityScanObserver: scans.increment
        )

        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 1)
        let staleCooldown = cooldown.popNext()

        model.startAgentActivityTracking()
        defer { model.beginTermination() }
        XCTAssertEqual(scans.value, 2)

        staleCooldown()
        XCTAssertEqual(scans.value, 2)
        XCTAssertEqual(cooldown.scheduledCount, 0)

        model.throttledRefreshAgentActivitySnapshots()
        XCTAssertEqual(scans.value, 3)
        XCTAssertEqual(cooldown.scheduledCount, 1)
    }

    @MainActor
    func testAnswerUserInputEnforcesChoiceFreeformSizeAndSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-ui", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        let responseURL = directory
            .appendingPathComponent("\(session.id).user-input-response.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")

        func writeSnapshot(updatedAt: Date, error: String? = nil) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: error,
                trackedUserInputs: [
                    TrackedUserInput(
                        requestId: "req-choice",
                        question: "Deploy?",
                        choices: ["Yes, deploy", "No"],
                        allowFreeform: false,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedUserInput(
                        requestId: "req-free",
                        question: "Name it",
                        choices: [],
                        allowFreeform: true,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: "agent-2"
                    ),
                ],
                copilotSessionId: "copilot-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        }
        try writeSnapshot(updatedAt: Date())
        try Data("copilot-session".utf8).write(to: markerURL)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        // Unknown request id → no valid question.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "missing", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )
        // A selectable answer must match a choice verbatim.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )
        // Freeform is rejected when the request does not allow it.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: true
                )
            ),
            .invalid
        )
        // Oversized answers are rejected.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free",
                    answer: String(repeating: "a", count: 8_193),
                    wasFreeform: true
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        try writeSnapshot(updatedAt: Date(), error: "Error: Connection is closed.")
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .conflict
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
        try writeSnapshot(updatedAt: Date())

        // A valid verbatim-choice answer is accepted and atomically written 0600.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .accepted
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(written["schemaVersion"] as? Int, 1)
        XCTAssertEqual(written["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(written["requestId"] as? String, "req-choice")
        XCTAssertEqual(written["answer"] as? String, "Yes, deploy")
        XCTAssertEqual(written["wasFreeform"] as? Bool, false)

        // A second answer conflicts while the prior response is still awaiting pickup.
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free", answer: "hello", wasFreeform: true
                )
            ),
            .conflict
        )

        // Once the extension consumes the response, a fresh freeform answer is accepted.
        try FileManager.default.removeItem(at: responseURL)
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-free", answer: "hello", wasFreeform: true
                )
            ),
            .accepted
        )
        try FileManager.default.removeItem(at: responseURL)

        // A stale heartbeat is too old to judge: try again.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .conflict
        )

        // Without a live Copilot session marker the answer cannot be bound yet: try again.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .conflict
        )
    }

    @MainActor
    func testSetModelValidatesAgainstCatalogAndSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-model", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let requestURL = directory
            .appendingPathComponent("\(session.id).set-model-request.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")

        func writeSnapshot(updatedAt: Date) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                availableModels: [
                    TrackedAvailableModel(
                        id: "gpt-5.4",
                        name: "GPT-5.4",
                        supportedReasoningEfforts: ["low", "high"],
                        defaultReasoningEffort: "high",
                        longContextAvailable: true,
                        disabled: nil,
                        category: "versatile"
                    ),
                    TrackedAvailableModel(
                        id: "locked-model",
                        name: "Locked",
                        supportedReasoningEfforts: nil,
                        defaultReasoningEffort: nil,
                        longContextAvailable: false,
                        disabled: true,
                        category: nil
                    ),
                ],
                copilotSessionId: "copilot-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1
            )
            try JSONEncoder().encode(snapshot).write(to: requestURL.deletingLastPathComponent()
                .appendingPathComponent("\(session.id).agent-activity.json"))
        }
        try writeSnapshot(updatedAt: Date())
        try Data("copilot-session".utf8).write(to: markerURL)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        // Unknown model id is rejected.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "does-not-exist")
            ),
            .invalid
        )
        // A policy-disabled model is never switchable.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "locked-model")
            ),
            .invalid
        )
        // An unsupported reasoning effort is rejected.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4", reasoningEffort: "max")
            ),
            .invalid
        )
        // long_context requires the model to advertise it.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(
                    modelId: "locked-model", contextTier: "long_context"
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestURL.path))

        // A valid selection is accepted and atomically written 0600.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(
                    modelId: "gpt-5.4", reasoningEffort: "high", contextTier: "long_context"
                )
            ),
            .accepted
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: requestURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: requestURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: requestURL))
                as? [String: Any]
        )
        XCTAssertEqual(written["schemaVersion"] as? Int, 1)
        XCTAssertEqual(written["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(written["modelId"] as? String, "gpt-5.4")
        XCTAssertEqual(written["reasoningEffort"] as? String, "high")
        XCTAssertEqual(written["contextTier"] as? String, "long_context")

        // A second switch conflicts while the prior request awaits pickup.
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4")
            ),
            .conflict
        )
        try FileManager.default.removeItem(at: requestURL)

        // Without a live Copilot session marker the switch cannot be bound yet: try again.
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4")
            ),
            .conflict
        )

        // A stale heartbeat is too old to judge: try again.
        try Data("copilot-session".utf8).write(to: markerURL)
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4")
            ),
            .conflict
        )
    }

    @MainActor
    func testAnswerElicitationValidatesActionContentAndSession() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-elicit", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        let responseURL = directory
            .appendingPathComponent("\(session.id).elicitation-response.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")

        let formSchema = RemoteJSONValue.object([
            "type": .string("object"),
            "required": .array([.string("fruit")]),
            "properties": .object([
                "fruit": .object([
                    "type": .string("string"),
                    "oneOf": .array([
                        .object([
                            "const": .string("apple"),
                            "title": .string("Apple"),
                        ]),
                        .object([
                            "const": .string("pear"),
                            "title": .string("Pear"),
                        ]),
                    ]),
                ]),
                "drink": .object([
                    "type": .string("string"),
                    "enum": .array([.string("water"), .string("coffee")]),
                ]),
                "ripe": .object(["type": .string("boolean")]),
                "count": .object([
                    "type": .string("number"),
                    "minimum": .number(1),
                    "maximum": .number(3),
                ]),
                "colors": .object([
                    "type": .string("array"),
                    "items": .object([
                        "anyOf": .array([
                            .object(["const": .string("red")]),
                            .object(["const": .string("green")]),
                        ]),
                    ]),
                ]),
                "nickname": .object([
                    "type": .string("string"),
                    "minLength": .number(1e300),
                ]),
                "emojiCodepoints": .object([
                    "type": .string("string"),
                    "minLength": .number(2),
                ]),
                "email": .object([
                    "type": .string("string"),
                    "format": .string("email"),
                ]),
                "uri": .object([
                    "type": .string("string"),
                    "format": .string("uri"),
                ]),
                "date": .object([
                    "type": .string("string"),
                    "format": .string("date"),
                ]),
                "dateTime": .object([
                    "type": .string("string"),
                    "format": .string("date-time"),
                ]),
                "tokens": .object([
                    "type": .string("array"),
                    "minItems": .number(1e300),
                ]),
            ]),
        ])

        func writeSnapshot(updatedAt: Date, error: String? = nil) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: error,
                trackedUserInputs: nil,
                trackedElicitations: [
                    TrackedElicitation(
                        requestId: "req-form",
                        message: "Pick a fruit",
                        mode: "form",
                        url: nil,
                        schema: formSchema,
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-mcp-form",
                        message: "Pick a fruit",
                        mode: "form",
                        url: nil,
                        schema: formSchema,
                        elicitationSource: "example-mcp",
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-non-choice-one-of",
                        message: "Enter a long answer",
                        mode: "form",
                        url: nil,
                        schema: .object([
                            "type": .string("object"),
                            "required": .array([.string("answer")]),
                            "properties": .object([
                                "answer": .object([
                                    "type": .string("string"),
                                    "oneOf": .array([
                                        .object(["minLength": .number(5)]),
                                    ]),
                                ]),
                            ]),
                        ]),
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-mixed-enum",
                        message: "Pick an answer",
                        mode: "form",
                        url: nil,
                        schema: .object([
                            "type": .string("object"),
                            "required": .array([.string("answer")]),
                            "properties": .object([
                                "answer": .object([
                                    "type": .string("string"),
                                    "enum": .array([.string("yes"), .number(1)]),
                                ]),
                            ]),
                        ]),
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "req-url",
                        message: "Open this URL?",
                        mode: nil,
                        url: "https://example.com/elicit",
                        schema: nil,
                        elicitationSource: nil,
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    ),
                    TrackedElicitation(
                        requestId: "synthetic::durable-ask-user::call-terminal",
                        message: "Answer in terminal",
                        mode: "terminal",
                        url: nil,
                        schema: nil,
                        elicitationSource: "durable-ask-user",
                        requestedAt: ISO8601DateFormatter().string(from: updatedAt),
                        agentId: nil
                    )
                ],
                copilotSessionId: "copilot-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL)
        }
        try writeSnapshot(updatedAt: Date())
        try Data("copilot-session".utf8).write(to: markerURL)

        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "synthetic::durable-ask-user::call-terminal",
                    action: .decline
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        try writeSnapshot(updatedAt: Date(), error: "Error: Connection is closed.")
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form", action: .accept,
                    content: [
                        "fruit": .string("apple"),
                        "ripe": .bool(true),
                        "count": .number(2),
                        "colors": .array([.string("red")]),
                        "emojiCodepoints": .string("ok"),
                        "email": .string("user@example.com"),
                        "uri": .string("https://example.com/elicit"),
                        "date": .string("2026-07-13"),
                        "dateTime": .string("2026-07-13T21:00:00Z"),
                    ]
                )
            ),
            .conflict
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
        try writeSnapshot(updatedAt: Date())

        // Unknown request id → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "missing", action: .accept,
                    content: ["fruit": .string("apple")]
                )
            ),
            .invalid
        )
        // accept without content → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .accept)
            ),
            .invalid
        )
        // decline WITH content → invalid.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form", action: .decline,
                    content: ["fruit": .string("apple")]
                )
            ),
            .invalid
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        let unsupportedContents: [[String: RemoteJSONValue]] = [
            ["fruit": .null],
            ["fruit": .number(2)],
            ["fruit": .string("")],
            ["fruit": .object(["name": .string("apple")])],
            ["fruit": .array([.number(1)])],
            ["fruit": .array([.array([.string("apple")])])],
            ["ripe": .bool(true)],
            ["fruit": .string("apple"), "count": .number(4)],
            ["fruit": .string("apple"), "colors": .array([.string("")])],
            ["fruit": .string("apple"), "colors": .array([.string(" \n\t")])],
            ["fruit": .string("apple"), "colors": .array([.string("blue"), .string("yellow")])],
            ["fruit": .string("apple"), "nickname": .string("a")],
            ["fruit": .string("apple"), "tokens": .array([])],
            ["fruit": .string("apple"), "email": .string("not an email")],
            ["fruit": .string("apple"), "uri": .string("not a uri")],
            ["fruit": .string("apple"), "date": .string("2026-99-99")],
            ["fruit": .string("apple"), "dateTime": .string("tomorrow")],
            ["fruit": .string("apple"), "extra": .string("x")],
            ["fruit": .string("apple"), "ripe": .string("")],
            ["fruit": .string("apple"), "ripe": .string(" \n\t")],
            ["fruit": .string("apple"), "ripe": .number(1)],
            ["fruit": .string("apple"), "ripe": .array([.string("yes")])],
        ]
        for unsupportedContent in unsupportedContents {
            XCTAssertEqual(
                model.answerElicitation(
                    sessionId: session.id,
                    answer: RemoteElicitationAnswer(
                        requestId: "req-form", action: .accept,
                        content: unsupportedContent
                    )
                ),
                .invalid
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        for requestId in ["req-non-choice-one-of", "req-mixed-enum"] {
            XCTAssertEqual(
                model.answerElicitation(
                    sessionId: session.id,
                    answer: RemoteElicitationAnswer(
                        requestId: requestId,
                        action: .accept,
                        content: ["answer": .string("other")]
                    )
                ),
                .invalid,
                "Only string const/enum choice sets may accept freeform answers"
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))

        for text in ["Keep the deferred threads open.", "true", "false", "  Explain first.\n"] {
            let content: [String: RemoteJSONValue] = [
                "fruit": .string("apple"),
                "ripe": .string(text),
            ]
            XCTAssertEqual(
                model.answerElicitation(
                    sessionId: session.id,
                    answer: RemoteElicitationAnswer(
                        requestId: "req-mcp-form", action: .accept, content: content
                    )
                ),
                .invalid,
                "MCP boolean schemas must never receive a string"
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
            XCTAssertEqual(
                model.answerElicitation(
                    sessionId: session.id,
                    answer: RemoteElicitationAnswer(
                        requestId: "req-form", action: .accept, content: content
                    )
                ),
                .accepted
            )
            let written = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: responseURL)) as? [String: Any]
            )
            XCTAssertEqual((written["content"] as? [String: Any])?["ripe"] as? String, text)
            try FileManager.default.removeItem(at: responseURL)
        }

        let customChoiceContent: [String: RemoteJSONValue] = [
            "fruit": .string("banana"),
            "drink": .string("tea"),
            "colors": .array([.string("red"), .string("blue")]),
        ]
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-mcp-form",
                    action: .accept,
                    content: customChoiceContent
                )
            ),
            .invalid,
            "MCP elicitations must stay bound to their declared choices"
        )
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form",
                    action: .accept,
                    content: customChoiceContent
                )
            ),
            .accepted,
            "Agent ask_user choices are suggestions and accept non-empty Other answers"
        )
        let writtenCustomChoice = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(
            (writtenCustomChoice["content"] as? [String: Any])?["fruit"] as? String,
            "banana"
        )
        XCTAssertEqual(
            (writtenCustomChoice["content"] as? [String: Any])?["drink"] as? String,
            "tea"
        )
        XCTAssertEqual(
            (writtenCustomChoice["content"] as? [String: Any])?["colors"] as? [String],
            ["red", "blue"]
        )
        try FileManager.default.removeItem(at: responseURL)

        // Valid accept with content is written 0600 with the expected payload.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-form", action: .accept,
                    content: [
                        "fruit": .string("apple"),
                        "ripe": .bool(true),
                        "count": .number(2),
                        "colors": .array([.string("red"), .string("green")]),
                        "emojiCodepoints": .string("👨‍👩‍👧‍👦"),
                        "email": .string("user@example.com"),
                        "uri": .string("https://example.com/elicit"),
                        "date": .string("2026-07-13"),
                        "dateTime": .string("2026-07-13T21:00:00.123Z"),
                    ]
                )
            ),
            .accepted
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: responseURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(written["schemaVersion"] as? Int, 1)
        XCTAssertEqual(written["copilotSessionId"] as? String, "copilot-session")
        XCTAssertEqual(written["requestId"] as? String, "req-form")
        XCTAssertEqual(written["action"] as? String, "accept")
        XCTAssertEqual((written["content"] as? [String: Any])?["fruit"] as? String, "apple")
        XCTAssertEqual((written["content"] as? [String: Any])?["ripe"] as? Bool, true)
        XCTAssertEqual((written["content"] as? [String: Any])?["count"] as? Double, 2)
        XCTAssertEqual(
            (written["content"] as? [String: Any])?["colors"] as? [String],
            ["red", "green"]
        )
        XCTAssertEqual(
            (written["content"] as? [String: Any])?["emojiCodepoints"] as? String,
            "👨‍👩‍👧‍👦"
        )
        XCTAssertEqual((written["content"] as? [String: Any])?["email"] as? String,
                       "user@example.com")
        XCTAssertEqual((written["content"] as? [String: Any])?["uri"] as? String,
                       "https://example.com/elicit")
        XCTAssertEqual((written["content"] as? [String: Any])?["date"] as? String,
                       "2026-07-13")
        XCTAssertEqual((written["content"] as? [String: Any])?["dateTime"] as? String,
                       "2026-07-13T21:00:00.123Z")

        // A second answer conflicts while the prior response awaits pickup.
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .conflict
        )

        // After the extension consumes it, a decline (no content) is accepted.
        try FileManager.default.removeItem(at: responseURL)
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .decline)
            ),
            .accepted
        )
        try FileManager.default.removeItem(at: responseURL)

        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(
                    requestId: "req-url", action: .accept,
                    content: ["ignored": .string("value")]
                )
            ),
            .invalid
        )
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-url", action: .accept)
            ),
            .accepted
        )
        let writtenURLAccept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: responseURL))
                as? [String: Any]
        )
        XCTAssertEqual(writtenURLAccept["requestId"] as? String, "req-url")
        XCTAssertEqual(writtenURLAccept["action"] as? String, "accept")
        XCTAssertNil(writtenURLAccept["content"])
        try FileManager.default.removeItem(at: responseURL)

        // A stale heartbeat is too old to judge: try again.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .conflict
        )

        // Without a live Copilot session marker the answer cannot be bound yet: try again.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .conflict
        )
    }

    func testDurableBooleanElicitationOnlyAcceptsVisibleDefault() {
        let request = TrackedElicitation(
            requestId: "synthetic::durable-ask-user::call-rerun",
            message: "Rerun failed jobs?",
            mode: "terminal-default",
            url: nil,
            schema: .object([
                "x-copilot-projects-terminal-default": .bool(true),
                "properties": .object([
                    "rerunFailedJobs": .object([
                        "type": .string("boolean"),
                        "title": .string("Rerun failed CI jobs"),
                        "default": .bool(true),
                    ]),
                ]),
            ]),
            elicitationSource: "durable-ask-user",
            requestedAt: "2026-08-27T00:17:32.945Z",
            agentId: nil
        )

        XCTAssertEqual(
            AppModel.durableDefaultBooleanSelection(
                request: request,
                answer: RemoteElicitationAnswer(
                    requestId: request.requestId,
                    action: .accept,
                    content: ["rerunFailedJobs": .bool(true)]
                )
            ),
            true
        )
        XCTAssertNil(
            AppModel.durableDefaultBooleanSelection(
                request: request,
                answer: RemoteElicitationAnswer(
                    requestId: request.requestId,
                    action: .accept,
                    content: ["rerunFailedJobs": .bool(false)]
                )
            )
        )
        XCTAssertNil(
            AppModel.durableDefaultBooleanSelection(
                request: request,
                answer: RemoteElicitationAnswer(
                    requestId: request.requestId,
                    action: .decline
                )
            )
        )
        XCTAssertTrue(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "Rerun failed jobs?",
                    "❯ Yes",
                    "  No",
                ],
                request: request,
                selected: true
            )
        )
        XCTAssertFalse(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "Another question",
                    "❯ Yes",
                ],
                request: request,
                selected: true
            )
        )
        XCTAssertFalse(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "This is destructive. Rerun failed jobs?",
                    "❯ Yes",
                    "  No",
                ],
                request: request,
                selected: true
            )
        )
        XCTAssertFalse(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Rerun failed jobs?",
                    "Copilot needs information.",
                    "Another question",
                    "❯ Yes",
                ],
                request: request,
                selected: true
            )
        )
        XCTAssertFalse(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "Rerun failed jobs?",
                    "❯ Yes, and don't ask again",
                    "  No",
                ],
                request: request,
                selected: true
            )
        )

        let falseRequest = TrackedElicitation(
            requestId: "synthetic::durable-ask-user::call-cancel",
            message: "Cancel deployment?",
            mode: "terminal-default",
            url: nil,
            schema: .object([
                "x-copilot-projects-terminal-default": .bool(true),
                "properties": .object([
                    "cancelDeployment": .object([
                        "type": .string("boolean"),
                        "default": .bool(false),
                    ]),
                ]),
            ]),
            elicitationSource: "durable-ask-user",
            requestedAt: "2026-08-27T00:17:32.945Z",
            agentId: nil
        )
        XCTAssertEqual(
            AppModel.durableDefaultBooleanSelection(
                request: falseRequest,
                answer: RemoteElicitationAnswer(
                    requestId: falseRequest.requestId,
                    action: .accept,
                    content: ["cancelDeployment": .bool(false)]
                )
            ),
            false
        )
        XCTAssertTrue(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "Cancel",
                    "deployment?",
                    "  Yes",
                    "❯ No",
                ],
                request: falseRequest,
                selected: false
            )
        )
        XCTAssertFalse(
            AppModel.durableBooleanPromptIsVisible(
                lines: [
                    "Copilot needs information.",
                    "Cancel deployment?",
                    "  Yes",
                    "❯ No",
                    "$ echo newer shell input",
                ],
                request: falseRequest,
                selected: false
            )
        )
    }

    @MainActor
    func testDurableBooleanElicitationComposesAllAuthorizationGates() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-durable-elicit", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let request = TrackedElicitation(
            requestId: "synthetic::durable-ask-user::call-rerun",
            message: "Rerun failed jobs?",
            mode: "terminal-default",
            url: nil,
            schema: .object([
                "x-copilot-projects-terminal-default": .bool(true),
                "properties": .object([
                    "rerunFailedJobs": .object([
                        "type": .string("boolean"),
                        "default": .bool(true),
                    ]),
                ]),
            ]),
            elicitationSource: "durable-ask-user",
            requestedAt: "2026-08-27T00:17:32.945Z",
            agentId: nil
        )
        let answer = RemoteElicitationAnswer(
            requestId: request.requestId,
            action: .accept,
            content: ["rerunFailedJobs": .bool(true)]
        )
        let validScreen = RemoteTerminalScreen(
            sessionId: session.id,
            cols: 80,
            rows: 4,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: [
                "Copilot needs information.",
                "Rerun failed jobs?",
                "❯ Yes",
                "  No",
            ]
        )

        let snapshotURL = directory
            .appendingPathComponent("\(session.id).agent-activity.json")
        let responseURL = directory
            .appendingPathComponent("\(session.id).elicitation-response.json")
        var snapshotWrite = 0
        func writeSnapshot(
            updatedAt: Date,
            pendingPermissionRequestIds: [String]?
        ) throws {
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: updatedAt),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: "Error: Connection is closed.",
                trackedUserInputs: nil,
                trackedElicitations: [request],
                pendingPermissionRequestIds: pendingPermissionRequestIds
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL)
            snapshotWrite += 1
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 2_000_000_000
                    + Double(snapshotWrite))],
                ofItemAtPath: snapshotURL.path
            )
        }

        var hasTarget = true
        var hasLiveAgent = true
        var isAtLiveBottom = true
        var screen: RemoteTerminalScreen? = validScreen
        var enterCount = 0
        var sendSucceeds = true
        let model = AppModel(
            stateRepository: repository,
            persistPermissionStatus: { _, _, _, _ in },
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory,
            remotePromptLiveSessions: { _ in
                hasLiveAgent ? [session.id] : []
            },
            remoteElicitationTarget: { requestedSessionId in
                guard requestedSessionId == session.id, hasTarget else { return nil }
                return RemoteElicitationTerminalTarget(
                    isAtLiveBottom: isAtLiveBottom,
                    screen: screen,
                    sendEnter: {
                        guard sendSucceeds else { return false }
                        enterCount += 1
                        return true
                    }
                )
            }
        )
        XCTAssertTrue(
            AppModel.durableElicitationIsAtLiveBottom(
                canScroll: false,
                scrollPosition: 0
            )
        )
        XCTAssertTrue(
            AppModel.durableElicitationIsAtLiveBottom(
                canScroll: true,
                scrollPosition: 1
            )
        )
        XCTAssertFalse(
            AppModel.durableElicitationIsAtLiveBottom(
                canScroll: true,
                scrollPosition: 0.99
            )
        )
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 1
        )
        let now = Date()

        try writeSnapshot(
            updatedAt: now.addingTimeInterval(-11),
            pendingPermissionRequestIds: []
        )
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        try writeSnapshot(updatedAt: now, pendingPermissionRequestIds: nil)
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        try writeSnapshot(updatedAt: now, pendingPermissionRequestIds: ["permission"])
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        try writeSnapshot(updatedAt: now, pendingPermissionRequestIds: [])
        model.setStatus(
            sessionId: session.id,
            status: .running,
            text: nil,
            timestamp: 2
        )
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 3
        )

        hasTarget = false
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )
        XCTAssertNil(model.terminalView(for: session.id))

        hasTarget = true
        hasLiveAgent = false
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        hasLiveAgent = true
        isAtLiveBottom = false
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        isAtLiveBottom = true
        screen = RemoteTerminalScreen(
            sessionId: session.id,
            cols: 80,
            rows: 4,
            scrollMode: .history,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: validScreen.lines
        )
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )

        screen = validScreen
        sendSucceeds = false
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .invalid
        )
        XCTAssertEqual(enterCount, 0)

        sendSucceeds = true
        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .accepted
        )
        XCTAssertEqual(enterCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
        XCTAssertNil(model.terminalView(for: session.id))

        XCTAssertEqual(
            model.answerElicitation(sessionId: session.id, answer: answer, now: now),
            .conflict
        )
        XCTAssertEqual(enterCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: responseURL.path))
    }

    @MainActor
    func testScheduledIdleTurnDoesNotPostCompletionNotification() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "scheduled", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: "scheduled",
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            agentActivityDirectory: activityDirectory
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.refreshAgentActivitySnapshots()
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 100,
            source: "scheduled-start"
        )
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(notifications.calls.isEmpty)
    }

    @MainActor
    func testStaleScheduledIdleDoesNotSuppressNextForegroundCompletion() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let activityDirectory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: activityDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let targetSession = Session(title: "foreground", cwd: "/tmp")
        let targetProject = Project(name: "target", cwd: "/tmp", sessions: [targetSession])
        let selectedProject = Project(name: "selected", cwd: "/tmp")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [targetProject, selectedProject],
            selectedProjectId: selectedProject.id
        ))

        let snapshot = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 1,
            lastIdleAborted: false,
            lastIdleTurnKind: "scheduled",
            error: nil
        )
        let path = activityDirectory
            .appendingPathComponent("\(targetSession.id).agent-activity.json")
        try JSONEncoder().encode(snapshot).write(to: path)

        let model = AppModel(
            stateRepository: repository,
            completionNotificationDelayNanoseconds: 10_000_000,
            agentActivityDirectory: activityDirectory
        )
        let notifications = NotificationSpy()
        model.attach(notifications: notifications)
        model.refreshAgentActivitySnapshots()
        model.setStatus(
            sessionId: targetSession.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: targetSession.id,
            status: .idle,
            text: nil,
            timestamp: 200,
            source: "agent-stop"
        )
        for _ in 0 ..< 50 {
            if notifications.calls.count == 1 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(notifications.calls.count, 1)
        XCTAssertEqual(
            notifications.calls.first?.title,
            StatusNotificationKind.completed.title
        )
    }

    func testStatusNotificationTitlesDescribeWhyCopilotNeedsAttention() {
        XCTAssertEqual(StatusNotificationKind.elicitation.title, "Copilot has a question")
        XCTAssertEqual(StatusNotificationKind.permission.title, "Copilot needs permission")
        XCTAssertEqual(StatusNotificationKind.completed.title, "Copilot finished a task")
        XCTAssertEqual(
            AppModel.notificationSubtitle(projectName: "Checkout", sessionTitle: "Fix taxes"),
            "Checkout · Fix taxes"
        )
        XCTAssertTrue(AppModel.isSessionVisible(
            appIsActive: true,
            selectedProjectId: "project",
            projectId: "project",
            selectedSessionId: "session",
            sessionId: "session"
        ))
        XCTAssertFalse(AppModel.isSessionVisible(
            appIsActive: false,
            selectedProjectId: "project",
            projectId: "project",
            selectedSessionId: "session",
            sessionId: "session"
        ))
        XCTAssertFalse(AppModel.canPostCompletion(status: .running, activity: .idle))
        XCTAssertFalse(AppModel.canPostCompletion(status: .idle, activity: .working))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: .idle))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: .unknown))
        XCTAssertTrue(AppModel.canPostCompletion(status: .idle, activity: nil))
        XCTAssertFalse(AppModel.shouldClearPendingCompletion(status: .running, source: "footer"))
        XCTAssertTrue(AppModel.shouldClearPendingCompletion(status: .running, source: nil))
        XCTAssertTrue(AppModel.shouldClearPendingCompletion(status: .waiting, source: "hook"))
    }

    func testScrollbarGutterStrippingKeepsAdjacentContent() {
        let bars: Set<Character> = ["┃"]
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("hello  ┃\nworld  ┃", bars: bars),
            "hello\nworld"
        )
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("table ┃", bars: bars),
            "table"
        )
        XCTAssertEqual(
            ProjectsTerminalView.strippingScrollbarGutter("table┃", bars: bars),
            "table┃"
        )
    }

    func testSessionIdAndShellQuoting() {
        let sessionId = UUID().uuidString
        XCTAssertTrue(TerminalController.isSafeSessionId(sessionId))
        XCTAssertFalse(TerminalController.isSafeSessionId("../../bad"))
        XCTAssertEqual(TerminalController.shellSingleQuote("a'b"), "'a'\\''b'")
        XCTAssertEqual(
            TerminalController.resumeCommand(sessionId: sessionId),
            TerminalController.profiledCopilotCommand(
                "copilot",
                arguments: ["--resume=\(sessionId)"]
            )
        )
        XCTAssertEqual(
            TerminalController.profiledCopilotCommand(
                "/opt/my copilot/copilot",
                arguments: ["--version"]
            ),
            "/bin/sh -c "
                + TerminalController.shellSingleQuote(
                    #"unset TERM_PROGRAM_VERSION; TERM_PROGRAM=ghostty exec "$0" "$@""#
                )
                + " '/opt/my copilot/copilot' '--version'"
        )
    }

    func testStartupProgramPrecedenceAndLaunchCommand() {
        let shell = "/bin/zsh"
        let executable = "/opt/my copilot/copilot"
        // Raw sessions (addSession, CLI new-session, New Terminal) pass no launch
        // executable, so their dtach program stays a plain login shell.
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                launchCopilotExecutable: nil
            ),
            [shell, "-l"]
        )
        // A freshly-created session launches the quoted absolute executable once,
        // without --allow-all.
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                launchCopilotExecutable: executable
            ),
            [shell, "-l", "-c",
             TerminalController.launchCommand(executable: executable, shell: shell)]
        )
        XCTAssertEqual(
            TerminalController.launchCommand(executable: executable, shell: shell),
            TerminalController.profiledCopilotCommand(
                executable,
                arguments: []
            )
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        let initialPrompt = "Review https://github.com/owner/repo/pull/12; don't edit"
        XCTAssertEqual(
            TerminalController.launchCommand(
                executable: executable,
                shell: shell,
                initialPrompt: initialPrompt
            ),
            TerminalController.profiledCopilotCommand(
                executable,
                arguments: [
                    "--interactive",
                    initialPrompt,
                ]
            )
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        let promptedProgram = TerminalController.startupProgram(
            shell: shell,
            copilotSessionId: nil,
            launchCopilotExecutable: executable,
            launchCopilotInitialPrompt: initialPrompt
        )
        XCTAssertEqual(
            promptedProgram,
            [shell, "-l", "-c",
             TerminalController.launchCommand(
                executable: executable,
                shell: shell,
                initialPrompt: initialPrompt
             )]
        )
        // A recorded resume session ALWAYS wins over a one-shot launch executable.
        let sessionId = UUID().uuidString
        let resumeExecutable = "/opt/resume copilot/copilot"
        let resumeProgram = TerminalController.startupProgram(
            shell: shell,
            copilotSessionId: sessionId,
            resumeCopilotExecutable: resumeExecutable,
            launchCopilotExecutable: executable,
            launchCopilotInitialPrompt: initialPrompt
        )
        let joined = resumeProgram.joined(separator: " ")
        XCTAssertTrue(joined.contains("resume copilot"))
        XCTAssertFalse(joined.contains("my copilot/copilot"))
        XCTAssertFalse(joined.contains(initialPrompt))
        XCTAssertFalse(joined.contains("--allow-all"))
    }

    func testSessionEnvironmentStripsLeakedCopilotVars() {
        // When the app is launched from a Copilot session these leak into its
        // environment; a spawned session's copilot must not inherit them or its
        // /restart shuts down (COPILOT_SUPERVISED) / defers to a gone loader.
        let base = [
            "COPILOT_SUPERVISED": "1",
            "COPILOT_LOADER_PID": "123",
            "COPILOT_AGENT_SESSION_ID": "abc",
            "COPILOT_CLI": "1",
            "PATH": "/usr/bin",
            "COPILOT_PROJECTS_SESSION": "keep-me",
        ]
        let cleaned = TerminalController.sessionEnvironment(from: base)
        XCTAssertNil(cleaned["COPILOT_SUPERVISED"])
        XCTAssertNil(cleaned["COPILOT_LOADER_PID"])
        XCTAssertNil(cleaned["COPILOT_AGENT_SESSION_ID"])
        XCTAssertNil(cleaned["COPILOT_CLI"])
        // Non-leaked vars (the app's own IPC handshake, PATH) must survive.
        XCTAssertEqual(cleaned["PATH"], "/usr/bin")
        XCTAssertEqual(cleaned["COPILOT_PROJECTS_SESSION"], "keep-me")
    }

    func testProfiledCopilotCommandScopesGhosttyEnvironment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeCopilot = root
            .appendingPathComponent("Sean's Tools;touch SHOULD_NOT_EXIST", isDirectory: true)
            .appendingPathComponent("copilot=custom")
        try FileManager.default.createDirectory(
            at: fakeCopilot.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        #!/bin/sh
        printf '%s\n' \
          "${TERM_PROGRAM:-unset}" \
          "${TERM_PROGRAM_VERSION:-unset}" \
          "$1"
        """.write(to: fakeCopilot, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCopilot.path
        )

        let shellPaths = ["/bin/csh", "/opt/homebrew/bin/fish"].filter {
            FileManager.default.isExecutableFile(atPath: $0)
        }
        for shellPath in shellPaths {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: shellPath)
            process.currentDirectoryURL = root
            process.arguments = [
                "-c",
                TerminalController.profiledCopilotCommand(
                    fakeCopilot.path,
                    arguments: ["argument with spaces"]
                ),
            ]
            process.environment = [
                "PATH": "/usr/bin:/bin",
                "TERM_PROGRAM": "Apple_Terminal",
                "TERM_PROGRAM_VERSION": "2.14",
            ]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()

            XCTAssertEqual(process.terminationStatus, 0, shellPath)
            XCTAssertEqual(
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "ghostty\nunset\nargument with spaces\n",
                shellPath
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path
                ),
                shellPath
            )
        }
    }

    func testSessionCreationLedgerIdempotencyTombstoneAndPersistence() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("nested/session-creation-ledger.json")

        let ledger = SessionCreationLedger(url: url)
        let requestId = UUID()
        XCTAssertNil(try ledger.record(for: requestId))

        let created = Date(timeIntervalSince1970: 1_900_000_000)
        try ledger.remember(SessionCreationRecord(
            requestId: requestId.uuidString,
            projectId: "project-1",
            sessionId: requestId.uuidString,
            createdAt: created
        ))

        // Tombstone survives a fresh ledger instance (persisted to disk).
        let reopened = SessionCreationLedger(url: url)
        let record = try XCTUnwrap(try reopened.record(for: requestId))
        XCTAssertEqual(record.projectId, "project-1")
        XCTAssertEqual(record.sessionId, requestId.uuidString)

        // Atomic persistence must land at 0600.
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[
            .posixPermissions
        ] as? NSNumber
        XCTAssertEqual(permissions?.int16Value, 0o600)
    }

    func testSessionCreationLedgerPrunesByTTLAndBound() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func record(_ id: String, _ createdAt: Date) -> SessionCreationRecord {
            SessionCreationRecord(
                requestId: id, projectId: "p", sessionId: id, createdAt: createdAt)
        }
        // TTL: anything older than a week is dropped, fresher entries kept.
        let fresh = record("fresh", now.addingTimeInterval(-60))
        let expired = record("expired", now.addingTimeInterval(-SessionCreationLedger.ttl - 60))
        XCTAssertEqual(
            SessionCreationLedger.prune([expired, fresh], now: now).map(\.requestId),
            ["fresh"]
        )
        // Bound: only the most recent maxRecords survive.
        let overflow = SessionCreationLedger.maxRecords + 10
        let many = (0 ..< overflow).map { index in
            record("r\(index)", now.addingTimeInterval(Double(index)))
        }
        let bounded = SessionCreationLedger.prune(many, now: now.addingTimeInterval(Double(overflow)))
        XCTAssertEqual(bounded.count, SessionCreationLedger.maxRecords)
        XCTAssertFalse(bounded.contains { $0.requestId == "r0" })
        XCTAssertTrue(bounded.contains { $0.requestId == "r\(overflow - 1)" })
    }

    func testSessionCreationFingerprintRoundTripsWithoutInventingLegacyIntent() throws {
        let legacySession = Data(#"{"id":"s1","title":"shell","cwd":"/tmp"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(Session.self, from: legacySession).creationFingerprint)
        let fingerprint = SessionCreationRecord.fingerprint(
            projectId: "p1", kind: .copilot, initialPrompt: "prompt", pullRequestURL: nil)
        XCTAssertEqual(fingerprint.count, 64)
        let session = Session(id: "s1", title: "Copilot", cwd: "/tmp", creationFingerprint: fingerprint)
        XCTAssertEqual(
            try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session)),
            session
        )

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyRecord = Data("""
            {"requestId":"s1","projectId":"p1","sessionId":"s1","createdAt":"2026-09-01T00:00:00Z"}
            """.utf8)
        XCTAssertNil(try decoder.decode(SessionCreationRecord.self, from: legacyRecord).creationFingerprint)
        let record = SessionCreationRecord(
            requestId: "s1", projectId: "p1", sessionId: "s1",
            createdAt: Date(timeIntervalSince1970: 1_900_000_000),
            creationFingerprint: fingerprint)
        XCTAssertEqual(
            try JSONDecoder().decode(SessionCreationRecord.self, from: JSONEncoder().encode(record)),
            record
        )
    }

    func testSessionCreationLedgerRejectsMalformedAndNonFileState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let requestId = UUID()

        let malformedURL = root.appendingPathComponent("malformed.json")
        try Data("{".utf8).write(to: malformedURL)
        XCTAssertThrowsError(
            try SessionCreationLedger(url: malformedURL).record(for: requestId)
        )

        let directoryURL = root.appendingPathComponent("ledger-as-directory")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        let directoryLedger = SessionCreationLedger(url: directoryURL)
        XCTAssertThrowsError(try directoryLedger.record(for: requestId))
        XCTAssertThrowsError(try directoryLedger.remember(SessionCreationRecord(
            requestId: requestId.uuidString,
            projectId: "project-1",
            sessionId: requestId.uuidString,
            createdAt: Date()
        )))
    }

    func testSessionCreationLedgerPropagatesReadAndWritePermissionFailures() throws {
        try XCTSkipIf(getuid() == 0, "root bypasses filesystem permissions")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let readRoot = root.appendingPathComponent("read", isDirectory: true)
        let writeRoot = root.appendingPathComponent("write", isDirectory: true)
        try FileManager.default.createDirectory(at: readRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: writeRoot, withIntermediateDirectories: true)
        defer {
            chmod(readRoot.path, 0o700)
            chmod(writeRoot.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let unreadableURL = readRoot.appendingPathComponent("ledger.json")
        try Data(#"{"records":[]}"#.utf8).write(to: unreadableURL)
        XCTAssertEqual(chmod(unreadableURL.path, 0o000), 0)
        defer { chmod(unreadableURL.path, 0o600) }
        XCTAssertThrowsError(
            try SessionCreationLedger(url: unreadableURL).record(for: UUID())
        )

        let unwritableURL = writeRoot.appendingPathComponent("ledger.json")
        let ledger = SessionCreationLedger(url: unwritableURL)
        let seedId = UUID()
        try ledger.remember(SessionCreationRecord(
            requestId: seedId.uuidString,
            projectId: "project-1",
            sessionId: seedId.uuidString,
            createdAt: Date()
        ))
        XCTAssertEqual(chmod(writeRoot.path, 0o500), 0)
        XCTAssertThrowsError(try ledger.remember(SessionCreationRecord(
            requestId: UUID().uuidString,
            projectId: "project-1",
            sessionId: UUID().uuidString,
            createdAt: Date()
        )))
    }

    func testSessionStatusMarkersPersistAsAtomicRecord() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString

        XCTAssertTrue(SessionArtifacts.persistStatus(
            sessionId: sessionId,
            status: .running,
            timestamp: 123_456,
            promptStatusTimestamp: 123_400,
            sessionsDirectory: root
        ))
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: root
                .appendingPathComponent("\(sessionId).status-record.json"))
        )
        XCTAssertEqual(
            record,
            SessionStatusRecord(
                status: .running,
                statusTimestamp: 123_456,
                promptStatusTimestamp: 123_400
            )
        )
    }

    func testInvalidAtomicStatusRecordLoadsAsInvalid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"status":"running"}"#.utf8).write(
            to: root.appendingPathComponent("\(sessionId).status-record.json"))

        XCTAssertEqual(
            SessionArtifacts.loadStatusRecord(
                sessionId: sessionId,
                sessionsDirectory: root
            ),
            .invalid
        )
    }

    func testBackgroundAgentMarkerLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        let marker = root.appendingPathComponent("\(sessionId).background-agents")

        XCTAssertTrue(SessionArtifacts.setBackgroundAgentsActive(
            sessionId: sessionId,
            active: true,
            sessionsDirectory: root
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(SessionArtifacts.setBackgroundAgentsActive(
            sessionId: sessionId,
            active: false,
            sessionsDirectory: root
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testTranscriptControllerLoadsJavaScriptTimestampsForDesktopAndRemote() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()
        let data = Data("""
        {
          "schemaVersion": 3,
          "updatedAt": "2026-07-12T03:09:00.123Z",
          "copilotSessionId": "copilot-session",
          "turns": [{
            "id": "turn-1",
            "startedAt": "2026-07-12T03:09:01Z",
            "endedAt": "2026-07-12T03:09:02.456Z",
            "kind": "foreground",
            "userContent": "Explain the failure",
            "assistantMessages": [{
              "id": "message-1",
              "timestamp": "2026-07-12T03:09:01.789Z",
              "content": "The failure is caused by the timeout."
            }],
            "tools": [{
              "id": "tool-1",
              "name": "bash",
              "title": "Run tests",
              "success": true
            }],
            "isAborted": true
          }]
        }
        """.utf8)
        try data.write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 50 {
            if controller.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let loaded = try XCTUnwrap(controller.snapshot)
        XCTAssertEqual(loaded.turns[0].userContent, "Explain the failure")
        XCTAssertEqual(loaded.turns[0].assistantMessages[0].content,
                       "The failure is caused by the timeout.")
        XCTAssertEqual(loaded.turns[0].tools[0].success, true)
        XCTAssertTrue(loaded.turns[0].isAborted)

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote, loaded)
    }

    /// The drawer shows nothing while the tab's owner marker names a different
    /// conversation than the transcript on disk, and shows it again once they agree.
    @MainActor
    func testTranscriptControllerShowsNothingWhileTheOwnerNamesAnotherConversation() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: UUID().uuidString,
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
        func writeOwner(naming copilotSessionId: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "appSessionId": sessionId,
                "copilotSessionId": copilotSessionId,
                "pid": Int(getpid()),
            ]).write(
                to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
                options: .atomic
            )
        }

        let controller = TranscriptController(sessionId: sessionId)
        func awaitSnapshot(shown: Bool) async {
            let reached = expectation(description: shown ? "transcript shown" : "transcript hidden")
            let watching = controller.$snapshot
                .first { ($0 != nil) == shown }
                .sink { _ in reached.fulfill() }
            await fulfillment(of: [reached], timeout: 10)
            watching.cancel()
        }
        controller.start()
        await awaitSnapshot(shown: true)

        try writeOwner(naming: UUID().uuidString)
        await awaitSnapshot(shown: false)
        XCTAssertNil(controller.snapshot)

        try writeOwner(naming: snapshot.copilotSessionId)
        await awaitSnapshot(shown: true)
        XCTAssertEqual(controller.snapshot?.copilotSessionId, snapshot.copilotSessionId)
    }

    /// What remote clients are served while the tab's owner marker names a
    /// different conversation than the transcript on disk: nothing, until the two
    /// agree. The tracker replaces the marker before the new conversation's
    /// transcript lands, so the file still holds the conversation the tab left.
    func testRemoteSnapshotShowsNothingUntilTheTranscriptMatchesItsOwner() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let previousCopilotSessionId = UUID().uuidString
        let nextCopilotSessionId = UUID().uuidString
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        func writeTranscript(_ copilotSessionId: String) throws {
            try encoder.encode(TranscriptSnapshot(
                schemaVersion: 3,
                updatedAt: Date(),
                copilotSessionId: copilotSessionId,
                turns: [TranscriptTurn(
                    id: "t0", startedAt: Date(), endedAt: Date(), kind: "user",
                    userContent: "hello", assistantMessages: [], tools: [], isAborted: false
                )]
            )).write(
                to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
                options: .atomic
            )
        }
        func writeOwner(_ copilotSessionId: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "appSessionId": sessionId,
                "copilotSessionId": copilotSessionId,
                "pid": Int(getpid()),
            ]).write(
                to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
                options: .atomic
            )
        }

        try writeTranscript(previousCopilotSessionId)
        try writeOwner(previousCopilotSessionId)
        XCTAssertEqual(TranscriptController.loadRemoteSnapshot(sessionId: sessionId).turns.count, 1)
        // Only the marker moves, and the revision clients refetch on moves with it.
        let revision = TranscriptController.remoteRevision(sessionId: sessionId)
        try writeOwner(nextCopilotSessionId)
        XCTAssertNotEqual(TranscriptController.remoteRevision(sessionId: sessionId), revision)
        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote.copilotSessionId, "")
        XCTAssertTrue(remote.turns.isEmpty)
        // The same answer through the `/transcript` endpoint the bridge serves.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let served = try decoder.decode(
            TranscriptSnapshot.self,
            from: try XCTUnwrap(TranscriptResponse.encodedResponse(
                sessionId: sessionId, images: [], limit: nil, after: nil
            ))
        )
        XCTAssertEqual(served.copilotSessionId, "")
        XCTAssertTrue(served.turns.isEmpty)

        try writeTranscript(nextCopilotSessionId)
        let recovered = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(recovered.copilotSessionId, nextCopilotSessionId)
        XCTAssertEqual(recovered.turns.map(\.userContent), ["hello"])

        // Going back to the earlier conversation (`/resume`) shows it again.
        try writeTranscript(previousCopilotSessionId)
        try writeOwner(previousCopilotSessionId)
        XCTAssertEqual(
            TranscriptController.loadRemoteSnapshot(sessionId: sessionId).copilotSessionId,
            previousCopilotSessionId
        )
    }

    @MainActor
    func testTranscriptControllerRejectsLegacySchemaForDesktopAndRemote() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()
        let snapshotURL = URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        let currentData = Data("""
        {
          "schemaVersion": 3,
          "updatedAt": "2026-07-12T03:09:00.123Z",
          "copilotSessionId": "copilot-session",
          "turns": []
        }
        """.utf8)
        try currentData.write(to: snapshotURL, options: .atomic)

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 50 {
            if controller.snapshot != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(controller.snapshot)

        let legacyData = Data("""
        {
          "schemaVersion": 2,
          "updatedAt": "2026-07-12T03:10:00.123Z",
          "copilotSessionId": "legacy-copilot-session",
          "turns": [{
            "id": "legacy-turn",
            "startedAt": "2026-07-12T03:10:01Z",
            "endedAt": "2026-07-12T03:10:02Z",
            "kind": "foreground",
            "userContent": "legacy transcript content",
            "assistantMessages": [],
            "tools": [],
            "isAborted": false
          }]
        }
        """.utf8)
        try legacyData.write(to: snapshotURL, options: .atomic)

        for _ in 0 ..< 120 {
            if controller.snapshot == nil { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNil(controller.snapshot)

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote.schemaVersion, 3)
        XCTAssertTrue(remote.copilotSessionId.isEmpty)
        XCTAssertTrue(remote.turns.isEmpty)
    }

    func testSessionArtifactCleanupRemovesTranscriptArtifacts() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let paths = [
            Paths.transcriptSnapshotPath(sessionId: sessionId),
            Paths.transcriptOwnerPath(sessionId: sessionId),
            Paths.transcriptOwnerLockPath(sessionId: sessionId),
        ]
        for path in paths {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testSessionArtifactCleanupKeepsAnOwnerLockATrackerHolds() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let lockPath = Paths.transcriptOwnerLockPath(sessionId: sessionId)
        let holder = open(lockPath, O_RDWR | O_CREAT | O_NONBLOCK | O_EXLOCK | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(holder, 0)

        SessionArtifacts.removeFiles(sessionId: sessionId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockPath))

        close(holder)
        SessionArtifacts.removeFiles(sessionId: sessionId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockPath))
    }

    func testSessionArtifactCleanupRemovesResponseArtifacts() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let paths = [
            Paths.userInputResponsePath(sessionId: sessionId),
            Paths.elicitationResponsePath(sessionId: sessionId),
        ]
        for path in paths {
            try Data("{}".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testSessionArtifactCleanupRemovesRetiredFiles() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let paths = [
            "status", "status-timestamp", "prompt-status-timestamp", "copilot-allow-all",
            "transcript-quarantine.json",
        ].map { Paths.sessionsDir.appendingPathComponent("\(sessionId).\($0)").path }
        for path in paths {
            try Data("123".utf8).write(to: URL(fileURLWithPath: path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        }
    }

    func testSessionArtifactCleanupRemovesHookMarkersAndAbandonedTemporaryFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let previous = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        defer {
            if let previous { setenv("COPILOT_PROJECTS_STATE_DIR", previous, 1) }
            else { unsetenv("COPILOT_PROJECTS_STATE_DIR") }
            try? FileManager.default.removeItem(at: root)
        }
        Paths.ensureStateDir()
        let sessionId = UUID().uuidString
        let otherId = UUID().uuidString
        let removed = [
            "active-turn", "agent-stop-completion", "set-model-request.json",
            "remote-host", "remote-initial-args", "remote-request-id",
            "status-record.json.4242", "copilot-session.17.tmp", "agent-activity.json.17.tmp",
            "transcript.json.17.tmp", "transcript-live.json.17.tmp",
            "transcript-owner.json.17.tmp",
        ].map { "\(sessionId).\($0)" }
        let kept = [
            "\(sessionId).status-record.json.old", "\(sessionId).transcript.json.tmp",
            "\(sessionId).transcript.json.17.tmp.bak", "\(sessionId).unrelated",
            "\(otherId).active-turn", "\(otherId).status-record.json.4242",
            "\(otherId).transcript.json.17.tmp",
        ]
        for name in removed + kept {
            try Data("x".utf8).write(to: Paths.sessionsDir.appendingPathComponent(name))
        }

        SessionArtifacts.removeFiles(sessionId: sessionId)

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: Paths.sessionsDir.path)),
            Set(kept)
        )
    }

    @MainActor
    func testStartupRemovesLeakedFilesOnlyForTabsThatAreGone() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let live = Session(title: "live", cwd: root.path)
        let project = Project(
            name: "project", cwd: root.path, sessions: [live], selectedSessionId: live.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let closing = UUID().uuidString
        try repository.acceptCloses(sessionIds: [closing])
        let gone = UUID().uuidString
        let attached = UUID().uuidString.lowercased()
        let removed = [
            "\(gone).active-turn", "\(gone).agent-stop-completion",
            "\(gone).remote-host", "\(gone).remote-initial-args", "\(gone).remote-request-id",
            "\(gone).status-record.json.4242", "\(gone).transcript.json.17.tmp",
            "\(gone.lowercased()).agent-stop-completion",
        ]
        let kept = [
            "\(gone).status-record.json", "\(gone).transcript.json", "\(gone).copilot-session",
            "\(live.id).active-turn", "\(live.id).status-record.json.4242",
            "\(live.id).remote-initial-args", "\(live.id).remote-request-id",
            "\(live.id.lowercased()).agent-stop-completion",
            "\(attached).sock", "\(attached).active-turn",
            "\(attached).remote-initial-args", "\(attached).remote-request-id",
            "\(closing).agent-stop-completion",
            "session-1.active-turn",
        ]
        for name in removed + kept {
            try Data("x".utf8).write(to: sessions.appendingPathComponent(name))
        }
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: sessions,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            forcedSessionDestroyer: { _ in }
        )

        model.finishInterruptedSessionDestroys()

        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: sessions.path)),
            Set(kept)
        )
    }

    @MainActor
    func testStartupKeepsLeakedFilesWhenWorkspaceWasNotLoadedCleanly() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = sessions.appendingPathComponent("\(UUID().uuidString).agent-stop-completion")
        try Data().write(to: marker)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let project = Project(name: "project", cwd: root.path)
        let state = PersistedState(projects: [project], selectedProjectId: project.id)

        func finishStartup() {
            AppModel(
                stateRepository: repository,
                isAppActive: { false },
                agentActivityDirectory: sessions,
                kittyImageDiskStore: RemoteKittyImageDiskStore(
                    root: root.appendingPathComponent("kitty-images", isDirectory: true)
                ),
                forcedSessionDestroyer: { _ in }
            ).finishInterruptedSessionDestroys()
        }

        // Missing state file.
        finishStartup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Unreadable state file recovered from its backup.
        try repository.save(PersistedState(projects: [project], selectedProjectId: nil))
        try repository.save(state)
        try Data("{".utf8).write(to: repository.path)
        finishStartup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))

        // Unreadable state file without a usable backup.
        try FileManager.default.removeItem(at: repository.backupPath)
        finishStartup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    @MainActor
    func testTranscriptDrawerRequiresExplicitOpen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = Session(title: "shell", cwd: "/tmp")
        let project = Project(
            name: "test",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [project],
            selectedProjectId: project.id
        ))
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root
        )

        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: session.id))
        model.openTranscriptDrawer(sessionId: session.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: session.id))
        model.closeTranscriptDrawer(sessionId: session.id)
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: session.id))
    }

    func testCompletionCoordinationStateIsNotPersisted() throws {
        let session = Session(title: "test", cwd: "/tmp")
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["id", "title", "cwd"])
    }

    func testStateRepositoryRecoversBackupAndNormalizesSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let session = Session(title: "shell", cwd: "/tmp")
        let project = Project(
            name: "test", cwd: "/tmp", sessions: [session], selectedSessionId: "missing")
        try repository.save(PersistedState(projects: [project], selectedProjectId: "missing"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try Data("not json".utf8).write(to: path)

        guard case .recovered(let recovered, _) = repository.load() else {
            return XCTFail("expected backup recovery")
        }
        XCTAssertEqual(recovered.selectedProjectId, project.id)
        XCTAssertEqual(recovered.projects[0].selectedSessionId, session.id)
    }

    func testStateRepositoryRecoversWhenPrimaryIsMissing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let project = Project(name: "test", cwd: "/tmp")
        try repository.save(PersistedState(projects: [project], selectedProjectId: nil))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        try FileManager.default.removeItem(at: path)

        guard case .recovered(let recovered, _) = repository.load() else {
            return XCTFail("expected missing-primary backup recovery")
        }
        XCTAssertEqual(recovered.selectedProjectId, project.id)
    }

    func testStateRepositoryRefusesFutureSchemaInsteadOfDowngrading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let project = Project(name: "test", cwd: "/tmp")
        var future = PersistedState(projects: [project], selectedProjectId: project.id)
        future.schemaVersion = PersistedState.currentSchemaVersion + 1
        try JSONEncoder().encode(future).write(to: path)
        try JSONEncoder().encode(
            PersistedState(projects: [project], selectedProjectId: project.id)
        ).write(to: repository.backupPath)

        guard case .failed = repository.load() else {
            return XCTFail("future schema must block writes rather than recover an older backup")
        }
    }

    func testStateRepositoryDetectsExternalAtomicRewriteBetweenSaves() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let first = Project(name: "first", cwd: "/tmp")
        let external = Project(name: "external", cwd: "/tmp")
        let second = Project(name: "second", cwd: "/tmp")

        try repository.save(PersistedState(projects: [first], selectedProjectId: first.id))
        try JSONEncoder().encode(
            PersistedState(projects: [external], selectedProjectId: external.id)
        ).write(to: path, options: .atomic)
        try repository.save(PersistedState(projects: [second], selectedProjectId: second.id))
        try FileManager.default.removeItem(at: path)

        guard case .recovered(let recovered, _) = repository.load() else {
            return XCTFail("expected backup recovery after external primary rewrite")
        }
        XCTAssertEqual(recovered.projects.map(\.name), ["external"])
    }

    /// macOS flagged the app for excessive disk writes on Nov 9: saves rewrote an unchanged
    /// state.json, and every save also copied the previous file into the backup.
    func testStateRepositorySkipsUnchangedSaveAndKeepsPriorFileAsBackup() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path)
        let session = Session(title: "shell", cwd: "/tmp", hostId: "local", startingPrompt: "hello")
        let project = Project(name: "test", cwd: "/tmp", sessions: [session], selectedSessionId: session.id)
        func fileNumber(_ url: URL) throws -> NSNumber? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        }

        try repository.save(PersistedState(projects: [project], selectedProjectId: nil))
        let first = try fileNumber(path)
        try repository.save(PersistedState(projects: [project], selectedProjectId: nil))
        XCTAssertEqual(try fileNumber(path), first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.backupPath.path))

        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        XCTAssertNotEqual(try fileNumber(path), first)
        XCTAssertEqual(try fileNumber(repository.backupPath), first)

        // An external rewrite changes the signature, so the same state is written again.
        let external = Project(name: "external", cwd: "/tmp")
        try JSONEncoder().encode(PersistedState(projects: [external], selectedProjectId: external.id))
            .write(to: path, options: .atomic)
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        guard case .loaded(let reloaded) = repository.load() else { return XCTFail("expected primary") }
        XCTAssertEqual(reloaded.projects.map(\.name), ["test"])
        try FileManager.default.removeItem(at: path)
        guard case .recovered(let recovered, _) = repository.load() else { return XCTFail("expected backup") }
        XCTAssertEqual(recovered.projects.map(\.name), ["external"])
    }

    @MainActor
    func testScheduledSavePersistsOffMainAndSerializesWithSynchronousSave() throws {
        final class SaveProbe: @unchecked Sendable {
            let lock = NSLock()
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            var blockNextOffMainSave = false
            var observedOffMainSave = false
        }
        let probe = SaveProbe()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("state.json")
        let repository = StateRepository(path: path) {
            if !Thread.isMainThread {
                probe.lock.lock()
                probe.observedOffMainSave = true
                let shouldBlock = probe.blockNextOffMainSave
                probe.blockNextOffMainSave = false
                probe.lock.unlock()
                if shouldBlock {
                    probe.started.signal()
                    probe.release.wait()
                }
            }
        }
        let session = Session(title: "initial", cwd: "/tmp")
        let project = Project(
            name: "first",
            cwd: "/tmp",
            sessions: [session],
            selectedSessionId: session.id
        )
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)

        model.updateTitle(sessionId: session.id, title: "scheduled")
        model.flushScheduledSaveForTesting()
        XCTAssertTrue(probe.observedOffMainSave)
        guard case .loaded(let afterScheduled) = repository.load() else {
            return XCTFail("expected scheduled save to persist state")
        }
        XCTAssertEqual(afterScheduled.projects[0].sessions[0].title, "scheduled")

        probe.lock.lock()
        probe.blockNextOffMainSave = true
        probe.lock.unlock()
        model.updateTitle(sessionId: session.id, title: "in-flight-scheduled")
        model.enqueueScheduledSaveForTesting()
        XCTAssertEqual(probe.started.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            probe.release.signal()
        }
        model.renameProject(project.id, name: "renamed-synchronously")
        guard case .loaded(let afterSync) = repository.load() else {
            return XCTFail("expected synchronous save to wait for in-flight scheduled save and win")
        }
        XCTAssertEqual(afterSync.projects[0].name, "renamed-synchronously")
        XCTAssertEqual(afterSync.projects[0].sessions[0].title, "in-flight-scheduled")
    }

    /// macOS flagged the app for excessive disk writes: every tool hook's new status
    /// timestamp rewrote all of state.json, and after that every turn start and end
    /// still did. A turn must not write it.
    @MainActor
    func testTurnTimerDoesNotRewriteWorkspaceState() throws {
        final class SaveCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            func increment() { lock.lock(); count += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        }
        let saves = SaveCounter()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = StateRepository(path: root.appendingPathComponent("state.json")) {
            saves.increment()
        }
        let sessions = (0..<4).map { Session(title: "session \($0)", cwd: "/tmp") }
        let project = Project(
            name: "busy",
            cwd: "/tmp",
            sessions: sessions,
            selectedSessionId: sessions[0].id
        )
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        let savesBeforeTurns = saves.value
        // One finished turn, then the start of the next.
        let turnStart: Int64 = 1_788_000_000_000
        for session in sessions {
            model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: turnStart - 2_000)
            model.setStatus(
                sessionId: session.id, status: .idle, text: nil,
                timestamp: turnStart - 1_000, source: "agent-stop"
            )
            model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: turnStart)
        }
        model.flushScheduledSaveForTesting()

        // Pre/post tool hooks, with one permission wait, each followed by the save debounce.
        let lastHook: Int64 = turnStart + 20_000
        for step in Int64(1)...20 {
            for session in sessions {
                if step == 10 {
                    model.setStatus(
                        sessionId: session.id, status: .waiting, text: nil,
                        timestamp: turnStart + step * 1_000, notification: .permission
                    )
                } else {
                    model.setStatus(
                        sessionId: session.id, status: .running, text: nil,
                        timestamp: turnStart + step * 1_000
                    )
                }
                model.flushScheduledSaveForTesting()
            }
        }
        XCTAssertEqual(saves.value, savesBeforeTurns)

        for session in sessions {
            SessionArtifacts.persistStatus(
                sessionId: session.id, status: .running, timestamp: lastHook,
                promptStatusTimestamp: lastHook, sessionsDirectory: root
            )
        }
        // A crash skips the quit save, so each turn's timer restarts at its last hook.
        let crashed = AppModel(stateRepository: repository, agentActivityDirectory: root)
        XCTAssertEqual(
            crashed.projects[0].sessions.map(\.runningStartedAtMilliseconds),
            Array(repeating: lastHook, count: sessions.count)
        )

        // Quitting saves the timer, so a relaunch keeps each turn's start.
        model.save()
        let relaunched = AppModel(stateRepository: repository, agentActivityDirectory: root)
        XCTAssertEqual(
            relaunched.projects[0].sessions.map(\.runningStartedAtMilliseconds),
            Array(repeating: turnStart, count: sessions.count)
        )
    }

    func testControlCommandRouterValidatesBeforeDispatch() {
        var didSetStatus = false
        var copilotRequests: [ControlRequest] = []
        var closeRequests: [ControlRequest] = []
        let router = ControlCommandRouter(actions: .init(
            listProjects: { "" },
            listStatus: { "" },
            setStatus: { _, _, _ in didSetStatus = true; return .success() },
            notify: { _, _, _ in .success() },
            newProject: { _ in .success() },
            newSession: { _ in .success() },
            newCopilotSession: { copilotRequests.append($0); return .success("id", code: "created") },
            closeSession: { closeRequests.append($0); return .success(code: "closed") },
            renameProject: { _, _ in .success() },
            focus: { _ in .success() },
            listSessions: { .success() },
            revealSession: { _ in .success() },
            startCopilotSession: { _ in .success() },
            resumeCopilotSession: { _ in .success() },
            screenshot: { _ in .success() },
            diagnostics: { "" },
            remote: { _ in .success() }
        ))
        XCTAssertFalse(router.handle(ControlRequest(command: "set-status")).ok)
        XCTAssertFalse(didSetStatus)
        XCTAssertFalse(router.handle(ControlRequest(command: "unknown")).ok)

        func copilotRequest(project: String?, requestId: String?, prompt: String?) -> ControlRequest {
            var request = ControlRequest(command: "new-copilot-session")
            request.projectId = project
            request.requestId = requestId
            request.prompt = prompt
            return request
        }
        let uuid = UUID().uuidString
        for invalid in [
            copilotRequest(project: nil, requestId: uuid, prompt: "p"),
            copilotRequest(project: "", requestId: uuid, prompt: "p"),
            copilotRequest(project: "p1", requestId: nil, prompt: "p"),
            copilotRequest(project: "p1", requestId: "not-a-uuid", prompt: "p"),
            copilotRequest(project: "p1", requestId: uuid, prompt: nil),
        ] {
            let response = router.handle(invalid)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.code, "bad-request")
        }
        XCTAssertTrue(copilotRequests.isEmpty)
        let response = router.handle(copilotRequest(project: "p1", requestId: uuid, prompt: "p"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.code, "created")
        XCTAssertEqual(copilotRequests.map(\.requestId), [uuid])

        func closeRequest(session: String?, project: String?) -> ControlRequest {
            var request = ControlRequest(command: "close-session")
            request.sessionId = session
            request.projectId = project
            return request
        }
        for invalid in [
            closeRequest(session: nil, project: "p1"),
            closeRequest(session: "", project: "p1"),
            closeRequest(session: "s1", project: ""),
        ] {
            let response = router.handle(invalid)
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.code, "bad-request")
        }
        XCTAssertTrue(closeRequests.isEmpty)
        XCTAssertTrue(router.handle(closeRequest(session: "s1", project: nil)).ok)
        XCTAssertTrue(router.handle(closeRequest(session: "s2", project: "p1")).ok)
        XCTAssertEqual(closeRequests.map(\.sessionId), ["s1", "s2"])

        for command in ["restart-session", "reload-session-mcp"] {
            var request = ControlRequest(command: command)
            XCTAssertEqual(router.handle(request).code, "bad-request")
            request.sessionId = "s3"
            XCTAssertEqual(router.handle(request).error, "\(command) is not configured", "routed to its own action")
        }
        XCTAssertEqual(closeRequests.count, 2)
    }

    // MARK: - Desktop Copilot session creation

    @MainActor
    func testDesktopCopilotSessionLaunchesInInheritedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Session(id: "existing", title: "shell", cwd: root.path)
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp",
            sessions: [existing], selectedSessionId: existing.id)
        var launches: [(String, String?, String?)] = []
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { nil },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { launches.append(($0, $1, $2)) }
        )
        let prompt = "  Review Sean's changes; $(touch SHOULD_NOT_EXIST)\r\n100% literal\n  "
        let id = try model.addCopilotSession(toProjectId: project.id, initialPrompt: prompt)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].0, id)
        XCTAssertEqual(launches[0].1, "/opt/copilot/bin/copilot")
        XCTAssertEqual(launches[0].2, prompt.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertEqual(model.project(project.id)?.sessions.last?.title, "Copilot")
        XCTAssertEqual(model.project(project.id)?.sessions.last?.cwd, root.path)
        XCTAssertEqual(model.project(project.id)?.selectedSessionId, id)
        guard case .loaded(let persisted) = StateRepository(path: root.appendingPathComponent("state.json")).load()
        else { return XCTFail("Created Copilot session was not persisted") }
        XCTAssertEqual(persisted.projects.first?.selectedSessionId, id)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
            .contains("SHOULD_NOT_EXIST"))

        model.addSessionToSelected()
        model.newInActiveContext()
        XCTAssertEqual(launches.count, 3)
        XCTAssertTrue(launches.dropFirst().allSatisfy { $0.2 == nil })
    }

    @MainActor
    func testDesktopCopilotSessionFailuresDoNotMutateOrLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: "p1", name: "First", cwd: root.path)
        var executable: String? = "/opt/copilot/bin/copilot"
        var backend = true
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            copilotExecutable: { executable }, reposDirectory: { nil },
            backendAvailable: { backend },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { _, _, _ in launches += 1 }
        )
        func assertFailure(_ expected: AppModel.CopilotSessionStartError, pid: String = "p1", prompt: String? = nil) {
            XCTAssertThrowsError(try model.addCopilotSession(toProjectId: pid, initialPrompt: prompt)) {
                XCTAssertEqual($0.localizedDescription, expected.localizedDescription)
            }
            XCTAssertEqual(model.projects, [project])
            XCTAssertEqual(model.selectedProjectId, project.id)
            XCTAssertEqual(launches, 0)
        }
        backend = false
        assertFailure(.backendUnavailable)
        backend = true
        executable = nil
        assertFailure(.copilotUnavailable)
        executable = "/opt/copilot/bin/copilot"
        assertFailure(.projectUnavailable, pid: "removed-during-composer")
        for prompt in ["", " \n\t", "\u{1b}]0;title\u{7}", "\u{0}", String(repeating: "x", count: 8_193)] {
            assertFailure(.invalidPrompt, prompt: prompt)
        }
        model.beginTermination()
        assertFailure(.shuttingDown)
    }

    @MainActor
    func testDesktopCopilotSessionRejectsMissingWorkingDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: "p1", name: "First", cwd: root.appendingPathComponent("deleted").path)
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { nil },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { _, _, _ in launches += 1 }
        )
        XCTAssertThrowsError(try model.addCopilotSession(toProjectId: project.id)) {
            XCTAssertEqual($0.localizedDescription,
                           AppModel.CopilotSessionStartError.workingDirectoryUnavailable(project.cwd).localizedDescription)
        }
        XCTAssertEqual(model.projects, [project])
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCopilotPromptComposerValidatesMultilineAndByteLimit() {
        let composer = CopilotPromptComposer()
        XCTAssertTrue(composer.alert.window.initialFirstResponder === composer.textView)
        XCTAssertFalse(composer.textView.isRichText)
        XCTAssertEqual(composer.alert.buttons[0].keyEquivalent, "\r")
        XCTAssertEqual(composer.alert.buttons[0].keyEquivalentModifierMask, .command)
        XCTAssertEqual(composer.alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertEqual(composer.alert.buttons[2].keyEquivalent, "")
        XCTAssertTrue(composer.alert.buttons[2].isHidden)
        for (text, enabled) in [
            ("", false), (" \n\t", false), ("line one\nline two", true),
            (String(repeating: "x", count: 8_192), true),
            (String(repeating: "x", count: 8_193), false),
            (String(repeating: "é", count: 4_096), true),
            (String(repeating: "é", count: 4_097), false),
            ("unsafe\u{1b}]0;title\u{7}", false),
        ] {
            composer.textView.string = text
            composer.textDidChange(Notification(name: NSText.didChangeNotification))
            XCTAssertEqual(composer.alert.buttons[0].isEnabled, enabled)
            XCTAssertEqual(composer.textView.string, text)
        }
    }

    @MainActor
    func testCopilotPromptComposerCancelAndFailurePreserveDraft() {
        let composer = CopilotPromptComposer()
        let draft = "  Don't lose this\nsecond line  "
        composer.textView.string = draft
        var attempts = 0
        let cancelled = composer.run(present: { _ in .alertSecondButtonReturn }) { _ in attempts += 1 }
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(composer.textView.string, draft)

        var presentations = 0
        let started = composer.run(present: { alert in
            presentations += 1
            XCTAssertTrue(alert.window.initialFirstResponder === composer.textView)
            XCTAssertEqual(composer.textView.string, draft)
            if presentations > 1 {
                XCTAssertEqual(alert.informativeText,
                               AppModel.CopilotSessionStartError.copilotUnavailable.localizedDescription)
            }
            return presentations <= 2 ? .alertFirstButtonReturn : .alertSecondButtonReturn
        }) { prompt in
            attempts += 1
            XCTAssertEqual(prompt, draft)
            if attempts == 1 { throw AppModel.CopilotSessionStartError.copilotUnavailable }
        }
        XCTAssertEqual(started, .started)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(presentations, 2)
        XCTAssertEqual(composer.textView.string, draft)
    }

    @MainActor
    func testCopilotPromptComposerOffersTerminalAfterUnavailableFailure() {
        for error in [AppModel.CopilotSessionStartError.copilotUnavailable, .backendUnavailable] {
            let composer = CopilotPromptComposer()
            let draft = "Keep this prompt\nsecond line"
            composer.textView.string = draft
            var presentations = 0
            var attempts = 0
            let outcome = composer.run(present: { alert in
                presentations += 1
                XCTAssertEqual(alert.buttons.count, 3)
                XCTAssertEqual(composer.textView.string, draft)
                if presentations == 1 {
                    XCTAssertTrue(alert.buttons[2].isHidden)
                    return .alertFirstButtonReturn
                }
                XCTAssertFalse(alert.buttons[2].isHidden)
                XCTAssertEqual(alert.informativeText, error.localizedDescription)
                composer.textView.string += "\nedited"
                composer.textDidChange(Notification(name: NSText.didChangeNotification))
                XCTAssertFalse(alert.buttons[2].isHidden)
                return .alertThirdButtonReturn
            }) { prompt in
                attempts += 1
                XCTAssertEqual(prompt, draft)
                throw error
            }
            XCTAssertEqual(outcome, .newTerminal)
            XCTAssertEqual(attempts, 1)
            XCTAssertEqual(presentations, 2)
            XCTAssertEqual(composer.textView.string, draft + "\nedited")
        }
    }

    @MainActor
    func testCopilotPromptComposerOnlyOffersTerminalForUnavailableFailures() {
        let composer = CopilotPromptComposer()
        XCTAssertEqual(composer.run(present: { _ in .alertThirdButtonReturn }) { _ in
            XCTFail("A hidden terminal action must not start Copilot")
        }, .cancelled)

        for error in [
            AppModel.CopilotSessionStartError.invalidPrompt, .projectUnavailable,
            .shuttingDown, .terminalUnavailable, .workingDirectoryUnavailable("/missing"),
        ] {
            composer.textView.string = "Retain this draft"
            var attempts = 0
            var presentations = 0
            let outcome = composer.run(present: { alert in
                presentations += 1
                XCTAssertEqual(composer.textView.string, "Retain this draft")
                XCTAssertEqual(alert.buttons[2].isHidden, presentations != 2)
                return presentations < 3 ? .alertFirstButtonReturn : .alertThirdButtonReturn
            }) { _ in
                attempts += 1
                if attempts == 1 { throw AppModel.CopilotSessionStartError.copilotUnavailable }
                throw error
            }
            XCTAssertEqual(outcome, .cancelled)
            XCTAssertEqual(attempts, 2)
            XCTAssertEqual(presentations, 3)
        }
    }

    func testPromptedCopilotCommandExecutesLiteralInteractiveArgumentAndFallsBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("Sean's copilot")
        let fallback = root.appendingPathComponent("fallback shell")
        try "#!/bin/sh\nprintf 'FALLBACK:%s\\n' \"$1\"\n"
            .write(to: fallback, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallback.path)
        let prompt = "Review 'quoted' text; $(touch SHOULD_NOT_EXIST)\n100% literal\\backslash"
        for status in [0, 1, 127, 130] {
            try "#!/bin/sh\nprintf '%s\\0' \"$@\"\nexit \(status)\n"
                .write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.currentDirectoryURL = root
            process.arguments = ["-c", TerminalController.launchCommand(
                executable: executable.path, shell: fallback.path, initialPrompt: prompt)]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let fields = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\0")
            XCTAssertEqual(Array(fields.prefix(2)), [
                "--interactive", prompt,
            ])
            XCTAssertTrue(fields.last?.contains("FALLBACK:-l") == true)
            XCTAssertEqual(fields.last?.contains("could not launch Copilot"), status != 0)
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SHOULD_NOT_EXIST").path))
        }
    }

    @MainActor
    func testDesktopCopilotPromptSurvivesFailedCLIInLiveFallbackTerminal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = root.appendingPathComponent("foreground-backend")
        let copilot = root.appendingPathComponent("failing-copilot")
        // Run the real startup argv in a PTY, but without a persistent dtach daemon.
        try "#!/bin/sh\nshift 6\nexec \"$@\"\n".write(to: backend, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 1\n".write(to: copilot, atomically: true, encoding: .utf8)
        for file in [backend, copilot] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let overrides = [
            "SHELL": "/bin/sh",
            "COPILOT_PROJECTS_STATE_DIR": root.path,
            "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("control.sock").path,
            "COPILOT_PROJECTS_DTACH": backend.path,
        ]
        let previous = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in overrides { setenv(key, value, 1) }
        let project = Project(id: "p1", name: "First", cwd: root.path)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remoteCopilotExecutable: { copilot.path },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer { model.detachAllClients() }
        let prompt = "Don't lose this prompt\n100% literal"
        let id = try model.addCopilotSession(toProjectId: project.id, initialPrompt: prompt)
        let terminal = try XCTUnwrap(model.terminalView(for: id))
        var sawFailure = false
        for _ in 0 ..< 200 {
            sawFailure = terminal.terminalStateSnapshot().visibleRows.contains {
                $0.text.contains("could not launch Copilot")
            }
            if sawFailure { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawFailure, "The actual PTY must render the launch failure")
        XCTAssertEqual(terminal.process?.running, true, "Failure must leave a usable shell")
        XCTAssertEqual(model.startingPrompt(for: id), prompt)
        XCTAssertEqual(model.project(project.id)?.sessions.map(\.id), [id])
        model.closeSession(projectId: project.id, sessionId: id)
        XCTAssertNil(model.startingPrompt(for: id), "Closing the tab must discard the in-memory prompt")
    }

    // MARK: - Remote session creation (AppModel)

    @MainActor
    func testCreateRemoteSessionUsesConfiguredStartupDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("code", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let key = "COPILOT_PROJECTS_DEFAULT_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        defer {
            if let previous { setenv(key, previous, 1) }
            else { unsetenv(key) }
        }
        setenv(key, directory.path, 1)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1"))
        let sshHost = RemoteHostInfo(
            id: "ssh", displayName: "SSH", sshTarget: "ssh", isLocal: false)
        let configuredHost = RemoteHostInfo(
            id: "configured", displayName: "Configured", sshTarget: "configured",
            defaultCwd: "/srv/project", isLocal: false)
        var launches = 0
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/usr/bin/true" },
            remoteSessionBackendAvailable: { true },
            availableHostsProvider: { [.local, sshHost, configuredHost] },
            remoteSessionLauncher: { _, _, _ in launches += 1 },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        )
        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
        XCTAssertEqual(model.createRemoteSession(request), .created(RemoteCreateSessionResponse(
            requestId: request.requestId, projectId: "p1", sessionId: request.requestId.uuidString)))
        XCTAssertEqual(model.project("p1")?.sessions.first?.cwd, directory.path)

        let sshRequest = RemoteCreateSessionRequest(
            requestId: UUID(), projectId: "p1", kind: .terminal, hostId: "ssh")
        XCTAssertEqual(model.createRemoteConfiguredSession(sshRequest), .created(RemoteCreateSessionResponse(
            requestId: sshRequest.requestId, projectId: "p1", sessionId: sshRequest.requestId.uuidString)))
        XCTAssertEqual(model.project("p1")?.sessions.last?.cwd, directory.path)

        setenv(key, "relative", 1)
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: "p1", kind: .terminal, hostId: "ssh")), .invalid)
        XCTAssertEqual(launches, 2)
        XCTAssertEqual(model.project("p1")?.sessions.count, 2)

        let configuredRequest = RemoteCreateSessionRequest(
            requestId: UUID(), projectId: "p1", kind: .terminal, hostId: "configured")
        XCTAssertEqual(model.createRemoteConfiguredSession(configuredRequest), .created(RemoteCreateSessionResponse(
            requestId: configuredRequest.requestId, projectId: "p1", sessionId: configuredRequest.requestId.uuidString)))
        XCTAssertEqual(model.project("p1")?.sessions.last?.cwd, "/srv/project")
    }

    @MainActor
    private func makeRemoteCreateModel(
        root: URL,
        projects: [Project],
        selectedProjectId: String?,
        copilotExecutable: @escaping () -> String? = { "/opt/copilot/bin/copilot" },
        reposDirectory: @escaping () -> String?,
        backendAvailable: @escaping () -> Bool = { true },
        ledger: SessionCreationLedger,
        onLaunch: @escaping (String, String?, String?) -> Void,
        defaults: UserDefaults = .standard
    ) throws -> AppModel {
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: projects, selectedProjectId: selectedProjectId))
        return AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: copilotExecutable,
            remoteReposDirectory: reposDirectory,
            remoteSessionBackendAvailable: backendAvailable,
            remoteSessionLauncher: onLaunch,
            sessionCreationLedger: ledger,
            defaults: defaults
        )
    }

    @MainActor
    func testCreateRemoteSessionCreatesLaunchesAndIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The Mac already has a selected tab in this project; it must be preserved.
        let existing = Session(id: "existing", title: "shell", cwd: "/tmp")
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp",
            sessions: [existing], selectedSessionId: "existing")
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )

        let requestId = UUID()
        let request = RemoteCreateSessionRequest(requestId: requestId, projectId: "p1")
        let outcome = model.createRemoteSession(request)

        let expected = RemoteCreateSessionResponse(
            requestId: requestId, projectId: "p1", sessionId: requestId.uuidString)
        XCTAssertEqual(outcome, .created(expected))

        let created = try XCTUnwrap(
            model.project("p1")?.sessions.first { $0.id == requestId.uuidString })
        XCTAssertEqual(created.title, "Copilot")
        XCTAssertEqual(created.cwd, repos.path)
        XCTAssertTrue(created.cwd.hasPrefix("/"))
        // Mac selection is not stolen.
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "existing")
        XCTAssertEqual(launches.map(\.sessionId), [requestId.uuidString])
        XCTAssertEqual(launches.first?.executable, "/opt/copilot/bin/copilot")
        XCTAssertNil(launches.first?.prompt)
        XCTAssertNotNil(try ledger.record(for: requestId))

        // Idempotent replay: existing, no new session, no relaunch.
        XCTAssertEqual(model.createRemoteSession(request), .existing(expected))
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: requestId, projectId: "p1", kind: .copilot)), .existing(expected))
        XCTAssertEqual(
            model.project("p1")?.sessions.filter { $0.id == requestId.uuidString }.count, 1)
        XCTAssertEqual(launches.count, 1)
    }

    @MainActor
    func testCreateRemoteSessionRepairsWorkspaceSaveFailureWithoutRelaunching() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("state.json")
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )
        try FileManager.default.removeItem(at: stateURL)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
        XCTAssertEqual(model.createRemoteSession(request, now: now), .persistenceUnavailable)
        XCTAssertEqual(launches, 1)
        XCTAssertNotNil(
            model.project("p1")?.sessions.first { $0.id == request.requestId.uuidString }
        )
        XCTAssertNil(try ledger.record(for: request.requestId, now: now))
        XCTAssertEqual(
            model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
                requestId: request.requestId, projectId: "p1", kind: .terminal), now: now),
            .conflict
        )
        XCTAssertEqual(launches, 1)

        try FileManager.default.removeItem(at: stateURL)
        let expected = RemoteCreateSessionResponse(
            requestId: request.requestId,
            projectId: "p1",
            sessionId: request.requestId.uuidString
        )
        XCTAssertEqual(
            model.createRemoteSession(request, now: now.addingTimeInterval(1)),
            .existing(expected)
        )
        XCTAssertEqual(launches, 1)
        XCTAssertNotNil(
            try ledger.record(for: request.requestId, now: now.addingTimeInterval(1))
        )
        guard case .loaded(let persisted) = StateRepository(path: stateURL).load() else {
            return XCTFail("repaired workspace state was not persisted")
        }
        XCTAssertEqual(
            persisted.projects.first?.sessions.map(\.id),
            [request.requestId.uuidString]
        )
    }

    @MainActor
    func testCreateRemoteSessionFailsClosedOnMalformedLedgerBeforeLaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledgerURL = root.appendingPathComponent("ledger.json")
        try Data("{".utf8).write(to: ledgerURL)
        let ledger = SessionCreationLedger(url: ledgerURL)
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )

        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
        XCTAssertEqual(model.createRemoteSession(request), .persistenceUnavailable)
        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(launches, 0)

        try FileManager.default.removeItem(at: ledgerURL)
        XCTAssertEqual(
            model.createRemoteSession(request),
            .created(RemoteCreateSessionResponse(
                requestId: request.requestId,
                projectId: "p1",
                sessionId: request.requestId.uuidString
            ))
        )
        XCTAssertEqual(launches, 1)
    }

    @MainActor
    func testCreateRemoteSessionFailsClosedWhenWorkspaceCouldNotLoad() throws {
        let scratchDirectory = ProcessInfo.processInfo.environment["COPILOT_PROJECTS_STATE_DIR"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent(".build/test-state", isDirectory: true)
        let root = scratchDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        let stateURL = root.appendingPathComponent("state.json")
        let ledgerURL = root.appendingPathComponent("ledger.json")
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: stateURL)
        defer { try? FileManager.default.removeItem(at: root) }

        let recordedId = UUID()
        let ledger = SessionCreationLedger(url: ledgerURL)
        try ledger.remember(SessionCreationRecord(
            requestId: recordedId.uuidString,
            projectId: "p1",
            sessionId: recordedId.uuidString,
            createdAt: Date()
        ))
        var launches = 0
        let model = AppModel(
            stateRepository: StateRepository(path: stateURL),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { repos.path },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { _, _, _ in launches += 1 },
            sessionCreationLedger: ledger
        )

        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: recordedId, projectId: "p1")
            ),
            .persistenceUnavailable
        )
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
            ),
            .persistenceUnavailable
        )
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteSessionRepairsLedgerFailureAcrossRestartThenStaysGoneAfterClose() throws {
        _ = NSApplication.shared
        try XCTSkipIf(getuid() == 0, "root bypasses filesystem permissions")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        let ledgerRoot = root.appendingPathComponent("ledger", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ledgerRoot, withIntermediateDirectories: true)
        defer {
            chmod(ledgerRoot.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }

        let stateURL = root.appendingPathComponent("state.json")
        let ledgerURL = ledgerRoot.appendingPathComponent("ledger.json")
        let ledger = SessionCreationLedger(url: ledgerURL)
        let seedId = UUID()
        try ledger.remember(SessionCreationRecord(
            requestId: seedId.uuidString,
            projectId: "p1",
            sessionId: seedId.uuidString,
            createdAt: Date(timeIntervalSince1970: 2_000_000_000)
        ))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )
        XCTAssertEqual(chmod(ledgerRoot.path, 0o500), 0)

        let now = Date(timeIntervalSince1970: 2_000_000_100)
        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
        XCTAssertEqual(model.createRemoteSession(request, now: now), .persistenceUnavailable)
        XCTAssertEqual(launches, 1)
        guard case .loaded(let persistedAfterFailure) =
            StateRepository(path: stateURL).load() else {
            return XCTFail("workspace was not durable before the ledger failure")
        }
        XCTAssertEqual(
            persistedAfterFailure.projects.first?.sessions.map(\.id),
            [request.requestId.uuidString]
        )

        XCTAssertEqual(chmod(ledgerRoot.path, 0o700), 0)
        let expected = RemoteCreateSessionResponse(
            requestId: request.requestId,
            projectId: "p1",
            sessionId: request.requestId.uuidString
        )
        XCTAssertEqual(
            model.createRemoteSession(request, now: now.addingTimeInterval(1)),
            .existing(expected)
        )
        XCTAssertEqual(launches, 1)
        XCTAssertNotNil(
            try ledger.record(for: request.requestId, now: now.addingTimeInterval(1))
        )

        var restartLaunches = 0
        let restarted = AppModel(
            stateRepository: StateRepository(path: stateURL),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { repos.path },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { _, _, _ in restartLaunches += 1 },
            sessionCreationLedger: SessionCreationLedger(url: ledgerURL),
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images", isDirectory: true)
            ),
            gracefulSessionDestroyer: { _, _ in Task {} },
            forcedSessionDestroyer: { _ in }
        )
        XCTAssertEqual(
            restarted.createRemoteSession(request, now: now.addingTimeInterval(2)),
            .existing(expected)
        )
        XCTAssertEqual(restartLaunches, 0)

        XCTAssertEqual(
            restarted.closeRemoteSession(sessionId: request.requestId.uuidString),
            .closed
        )
        restarted.forcePendingSessionDestroys()
        let afterClose = AppModel(
            stateRepository: StateRepository(path: stateURL),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { repos.path },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { _, _, _ in restartLaunches += 1 },
            sessionCreationLedger: SessionCreationLedger(url: ledgerURL),
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("kitty-images-after-close", isDirectory: true)
            )
        )
        XCTAssertEqual(
            afterClose.createRemoteSession(request, now: now.addingTimeInterval(3)),
            .gone
        )
        XCTAssertEqual(restartLaunches, 0)
    }

    @MainActor
    func testCreateRemoteAdversarialReviewSessionLaunchesFixedPrompt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(
            id: "p1",
            name: "Reviews",
            cwd: "/tmp",
            sessions: []
        )
        let ledger = SessionCreationLedger(
            url: root.appendingPathComponent("ledger.json")
        )
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )

        let requestId = UUID()
        let pullRequestURL = "https://github.com/github/github/pull/123"
        let request = RemoteCreateSessionRequest(
            requestId: requestId,
            projectId: "p1",
            pullRequestURL: pullRequestURL
        )
        let outcome = model.createRemoteAdversarialReviewSession(request)
        let expected = RemoteCreateSessionResponse(
            requestId: requestId,
            projectId: "p1",
            sessionId: requestId.uuidString
        )
        XCTAssertEqual(outcome, .created(expected))

        let created = try XCTUnwrap(
            model.project("p1")?.sessions.first { $0.id == requestId.uuidString }
        )
        XCTAssertEqual(created.title, "Review github/github#123")
        XCTAssertEqual(created.cwd, repos.path)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(
            launches.first?.prompt,
            PullRequestReviewPrompt.builtIn.prompt(
                for: try XCTUnwrap(PullRequestReviewTarget.parse(pullRequestURL))
            )
        )

        XCTAssertEqual(
            model.createRemoteAdversarialReviewSession(request),
            .existing(expected)
        )
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(model.createRemoteSession(request), .badRequest)
        XCTAssertEqual(
            model.createRemoteAdversarialReviewSession(
                RemoteCreateSessionRequest(
                    requestId: UUID(),
                    projectId: "p1",
                    pullRequestURL: "https://example.com/not-a-pr"
                )
            ),
            .badRequest
        )
    }

    @MainActor
    func testAddLocalAdversarialReviewSessionUsesProjectContext() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = Session(id: "existing", title: "shell", cwd: "/tmp/old")
        let project = Project(
            id: "p1",
            name: "Reviews",
            cwd: "/tmp/project-checkout",
            sessions: [existing],
            selectedSessionId: existing.id
        )
        let ledger = SessionCreationLedger(
            url: root.appendingPathComponent("ledger.json")
        )
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { nil },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )

        let pullRequestURL = "https://github.com/github/github/pull/123"
        let sessionId = try XCTUnwrap(model.addAdversarialReviewSession(
            toProjectId: "p1",
            pullRequestURL: pullRequestURL
        ))
        let session = try XCTUnwrap(
            model.project("p1")?.sessions.first { $0.id == sessionId }
        )
        XCTAssertEqual(session.title, "Review github/github#123")
        XCTAssertEqual(session.cwd, "/tmp/old")
        XCTAssertEqual(model.project("p1")?.selectedSessionId, sessionId)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(
            launches.first?.prompt,
            PullRequestReviewPrompt.builtIn.prompt(
                for: try XCTUnwrap(PullRequestReviewTarget.parse(pullRequestURL))
            )
        )

        XCTAssertNil(model.addAdversarialReviewSession(
            toProjectId: "p1",
            pullRequestURL: "https://example.com/not-a-pr"
        ))
        XCTAssertEqual(launches.count, 1)

        var typedHashInDialog: String?
        var trimmedInDialog: String?
        let interactive = AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json")),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { nil },
            remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { launches.append(($0, $1, $2)) },
            sessionCreationLedger: ledger,
            kittyImageDiskStore: RemoteKittyImageDiskStore(
                root: root.appendingPathComponent("interactive-images", isDirectory: true)
            ),
            alertPresenter: { alert in
                guard let field = alert.accessoryView as? NSTextField else {
                    return .alertSecondButtonReturn
                }
                field.stringValue = "https://github.com/github/github/pull/123"
                NotificationCenter.default.post(
                    name: NSControl.textDidChangeNotification,
                    object: field
                )
                field.stringValue = "https://github.com/github/github/pull/123#"
                NotificationCenter.default.post(
                    name: NSControl.textDidChangeNotification,
                    object: field
                )
                typedHashInDialog = field.stringValue
                field.stringValue = "https://github.com/github/github/pull/123#discussion_r99"
                NotificationCenter.default.post(
                    name: NSControl.textDidChangeNotification,
                    object: field
                )
                trimmedInDialog = field.stringValue
                return .alertFirstButtonReturn
            }
        )
        interactive.addAdversarialReviewSessionInteractive(toProjectId: "p1")
        XCTAssertEqual(typedHashInDialog, "https://github.com/github/github/pull/123#")
        XCTAssertEqual(trimmedInDialog, "https://github.com/github/github/pull/123")
        XCTAssertEqual(launches.count, 2)
    }

    @MainActor
    func testAddAdversarialReviewSessionUsesStoredPrompt() throws {
        let suite = "review-prompt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PullRequestReviewPrompt.validated("Review {url} for security only.").get().save(to: defaults)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "Reviews", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { nil },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { launches.append(($0, $1, $2)) },
            defaults: defaults
        )
        let pullRequestURL = "https://github.com/github/github/pull/123"
        XCTAssertNotNil(model.addAdversarialReviewSession(
            toProjectId: "p1",
            pullRequestURL: pullRequestURL
        ))
        XCTAssertEqual(launches.map(\.prompt), ["Review \(pullRequestURL) for security only."])
    }

    @MainActor
    func testCreateRemoteAdversarialReviewSessionUsesStoredPrompt() throws {
        let suite = "review-prompt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PullRequestReviewPrompt.validated("Review {url} for security only.").get().save(to: defaults)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "Reviews", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { launches.append(($0, $1, $2)) },
            defaults: defaults
        )
        let pullRequestURL = "https://github.com/github/github/pull/123"
        let outcome = model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: UUID(),
            projectId: "p1",
            pullRequestURL: pullRequestURL
        ))
        guard case .created = outcome else {
            return XCTFail("expected created, got \(outcome)")
        }
        XCTAssertEqual(launches.map(\.prompt), ["Review \(pullRequestURL) for security only."])
    }

    @MainActor
    func testRemoteReviewReplayAfterPromptChangeStaysExisting() throws {
        let suite = "review-prompt-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try PullRequestReviewPrompt.validated("Review {url} for security only.").get().save(to: defaults)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [(sessionId: String, executable: String?, prompt: String?)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "Reviews", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { launches.append(($0, $1, $2)) },
            defaults: defaults
        )
        let pullRequestURL = "https://github.com/github/github/pull/123"
        let request = RemoteCreateSessionRequest(
            requestId: UUID(),
            projectId: "p1",
            pullRequestURL: pullRequestURL
        )
        let created = model.createRemoteAdversarialReviewSession(request)
        guard case .created(let response) = created else {
            return XCTFail("expected created, got \(created)")
        }
        try PullRequestReviewPrompt.validated("Review {url} for regressions only.").get().save(to: defaults)
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(request), .existing(response))
        XCTAssertEqual(launches.map(\.prompt), ["Review \(pullRequestURL) for security only."])

        let changed = model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: UUID(),
            projectId: "p1",
            pullRequestURL: pullRequestURL
        ))
        guard case .created = changed else {
            return XCTFail("expected a new review to use the changed prompt, got \(changed)")
        }
        XCTAssertEqual(launches.map(\.prompt), [
            "Review \(pullRequestURL) for security only.",
            "Review \(pullRequestURL) for regressions only.",
        ])
    }

    @MainActor
    func testCreateRemoteSessionSelectsOnlyWhenProjectEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(id: "p1", name: "Empty", cwd: "/tmp", sessions: [])
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: "p1",
            reposDirectory: { repos.path }, ledger: ledger, onLaunch: { _, _, _ in })

        let requestId = UUID()
        _ = model.createRemoteSession(
            RemoteCreateSessionRequest(requestId: requestId, projectId: "p1"))
        // An empty project adopts the new session as its selection.
        XCTAssertEqual(model.project("p1")?.selectedSessionId, requestId.uuidString)
    }

    @MainActor
    func testCreateRemoteSessionCrossProjectConflict() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [
                Project(id: "p1", name: "First", cwd: "/tmp", sessions: []),
                Project(id: "p2", name: "Second", cwd: "/tmp", sessions: []),
            ],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in })

        let requestId = UUID()
        _ = model.createRemoteSession(
            RemoteCreateSessionRequest(requestId: requestId, projectId: "p1"))
        // The same deterministic id requested for a different project collides.
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p2")),
            .conflict
        )
        XCTAssertTrue(model.project("p2")?.sessions.isEmpty == true)
    }

    @MainActor
    func testCreateRemoteSessionReplayFollowsMovedOriginal() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [
                Project(id: "p1", name: "First", cwd: "/tmp", sessions: []),
                Project(id: "p2", name: "Second", cwd: "/tmp", sessions: []),
            ],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in }
        )
        let request = RemoteCreateSessionRequest(
            requestId: UUID(),
            projectId: "p1"
        )
        _ = model.createRemoteSession(request)
        XCTAssertEqual(
            model.moveRemoteSession(
                sessionId: request.requestId.uuidString,
                toProjectId: "p2"
            ),
            .moved
        )

        XCTAssertEqual(
            model.createRemoteSession(request),
            .existing(RemoteCreateSessionResponse(
                requestId: request.requestId,
                projectId: "p2",
                sessionId: request.requestId.uuidString
            ))
        )
        XCTAssertEqual(
            model.createRemoteSession(RemoteCreateSessionRequest(
                requestId: request.requestId,
                projectId: "p2"
            )),
            .conflict
        )
        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(
            model.project("p2")?.sessions.map(\.id),
            [request.requestId.uuidString]
        )
    }

    @MainActor
    func testCreateRemoteSessionGoneTombstoneNeverRecreates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let requestId = UUID()
        // A tombstone exists but the session is gone from the workspace.
        try ledger.remember(SessionCreationRecord(
            requestId: requestId.uuidString, projectId: "p1",
            sessionId: requestId.uuidString, createdAt: Date(),
            creationFingerprint: SessionCreationRecord.fingerprint(
                projectId: "p1", kind: .copilot, initialPrompt: nil, pullRequestURL: nil)))

        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 })

        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p1")),
            .gone
        )
        XCTAssertEqual(
            model.createRemoteConfiguredSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p1", kind: .terminal)),
            .conflict
        )
        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteSessionExpiredTombstoneCanCreateAgain() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let requestId = UUID()
        let createdAt = Date(timeIntervalSince1970: 2_000_000_000)
        try ledger.remember(
            SessionCreationRecord(
                requestId: requestId.uuidString,
                projectId: "p1",
                sessionId: requestId.uuidString,
                createdAt: createdAt
            ),
            now: createdAt
        )
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )
        let retryAt = createdAt.addingTimeInterval(SessionCreationLedger.ttl + 1)
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: requestId, projectId: "p1"),
                now: retryAt
            ),
            .created(RemoteCreateSessionResponse(
                requestId: requestId,
                projectId: "p1",
                sessionId: requestId.uuidString
            ))
        )
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(
            try ledger.record(for: requestId, now: retryAt)?.createdAt,
            retryAt
        )
    }

    @MainActor
    func testCreateRemoteSessionUnknownUnavailableAndInvalid() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var copilot: String? = "/opt/copilot/bin/copilot"
        var reposPath: String? = repos.path
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            copilotExecutable: { copilot },
            reposDirectory: { reposPath },
            ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 })

        // Unknown project → nothing created.
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: UUID(), projectId: "nope")),
            .unknownProject)

        // Copilot unresolved → service unavailable, nothing created, no tombstone.
        copilot = nil
        let unavailableId = UUID()
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: unavailableId, projectId: "p1")),
            .unavailable)
        XCTAssertNil(try ledger.record(for: unavailableId))

        // Missing dtach backend also fails closed instead of returning a shell-only
        // session that violated the automatic-Copilot contract.
        copilot = "/opt/copilot/bin/copilot"
        let noBackendId = UUID()
        let noBackendModel = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            copilotExecutable: { copilot },
            reposDirectory: { reposPath },
            backendAvailable: { false },
            ledger: ledger,
            onLaunch: { _, _, _ in }
        )
        XCTAssertEqual(
            noBackendModel.createRemoteSession(
                RemoteCreateSessionRequest(requestId: noBackendId, projectId: "p1")),
            .unavailable
        )
        XCTAssertEqual(
            noBackendModel.createRemoteConfiguredSession(
                RemoteCreateSessionRequest(requestId: noBackendId, projectId: "p1", kind: .terminal)),
            .unavailable
        )
        XCTAssertNil(try ledger.record(for: noBackendId))

        // Repos missing → unprocessable, nothing created.
        reposPath = nil
        let invalidId = UUID()
        XCTAssertEqual(
            model.createRemoteSession(
                RemoteCreateSessionRequest(requestId: invalidId, projectId: "p1")),
            .invalid)
        copilot = nil
        XCTAssertEqual(
            model.createRemoteConfiguredSession(
                RemoteCreateSessionRequest(requestId: invalidId, projectId: "p1", kind: .terminal)),
            .invalid)
        XCTAssertNil(try ledger.record(for: invalidId))

        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteConfiguredSessionUsesRequestedKindAndPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repos = root.appendingPathComponent("Repos")
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Session(id: "existing", title: "shell", cwd: root.path)
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp",
            sessions: [existing], selectedSessionId: existing.id)
        var executable: String? = "/opt/copilot/bin/copilot"
        var launches: [(id: String, executable: String?, prompt: String?)] = []
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            copilotExecutable: { executable }, reposDirectory: { repos.path }, ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )
        let bridge: any SessionHost = RemoteModelBridge(model: model)
        let cases: [(RemoteSessionKind?, String?)] = [
            (nil, nil),
            (nil, "  UNIQUE_STARTING_PROMPT; $(touch SHOULD_NOT_EXIST)\r\n100% literal  "),
            (.copilot, nil),
            (.terminal, nil),
            (.copilot, String(repeating: "é", count: 4_096)),
        ]
        for (index, value) in cases.enumerated() {
            let (kind, prompt) = value
            executable = kind == .terminal ? nil : "/opt/copilot/bin/copilot"
            let request = RemoteCreateSessionRequest(
                requestId: UUID(), projectId: project.id, kind: kind, initialPrompt: prompt)
            let response = RemoteCreateSessionResponse(
                requestId: request.requestId, projectId: project.id,
                sessionId: request.requestId.uuidString)
            XCTAssertEqual(bridge.createConfiguredSession(request), .created(response))
            XCTAssertEqual(launches.count, index + 1)
            XCTAssertEqual(launches.last?.id, response.sessionId)
            XCTAssertEqual(launches.last?.executable, executable)
            XCTAssertEqual(launches.last?.prompt, prompt?.replacingOccurrences(of: "\r\n", with: "\n"))
            let session = try XCTUnwrap(model.project(project.id)?.sessions.last)
            XCTAssertEqual(session.title, kind == .terminal ? "shell" : "Copilot")
            XCTAssertEqual(session.cwd, repos.path)
            XCTAssertEqual(session.creationFingerprint?.count, 64)
            XCTAssertEqual(model.project(project.id)?.selectedSessionId, existing.id)
            XCTAssertEqual(
                try ledger.record(for: request.requestId)?.creationFingerprint,
                session.creationFingerprint)
            XCTAssertEqual(model.createRemoteConfiguredSession(request), .existing(response))
            XCTAssertEqual(launches.count, index + 1)
        }
        for file in ["state.json", "ledger.json"] {
            XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .contains("UNIQUE_STARTING_PROMPT"))
        }
    }

    @MainActor
    func testLocalCopilotSessionControlCommandIsTitledIdempotentAndValidated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repos = root.appendingPathComponent("Repos")
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Session(id: "existing", title: "shell", cwd: root.path)
        let project = Project(
            id: "p1", name: "PR Reviews", cwd: "/tmp",
            sessions: [existing], selectedSessionId: existing.id)
        var launches: [(id: String, executable: String?, prompt: String?)] = []
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { repos.path }, ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )
        let requestId = UUID()
        let prompt = "Review https://github.com/o/r/pull/1\r\nat head abc; $(touch SHOULD_NOT_EXIST)"
        func request(
            id: UUID = requestId,
            project: String = "p1",
            title: String? = "  Review o/r#1  ",
            prompt: String = prompt
        ) -> ControlRequest {
            var request = ControlRequest(command: "new-copilot-session")
            request.projectId = project
            request.requestId = id.uuidString
            request.title = title
            request.prompt = prompt
            return request
        }

        let created = model.handle(request())
        XCTAssertTrue(created.ok)
        XCTAssertEqual(created.code, "created")
        XCTAssertEqual(created.text, requestId.uuidString)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].id, requestId.uuidString)
        XCTAssertEqual(launches[0].executable, "/opt/copilot/bin/copilot")
        XCTAssertEqual(launches[0].prompt, prompt.replacingOccurrences(of: "\r\n", with: "\n"))
        let session = try XCTUnwrap(model.project("p1")?.sessions.last)
        XCTAssertEqual(session.id, requestId.uuidString)
        XCTAssertEqual(session.title, "Review o/r#1")
        XCTAssertEqual(session.cwd, repos.path)
        XCTAssertEqual(model.project("p1")?.selectedSessionId, existing.id)
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
            .contains("SHOULD_NOT_EXIST"))

        let replay = model.handle(request(title: "A later title"))
        XCTAssertEqual(replay.code, "existing")
        XCTAssertEqual(replay.text, requestId.uuidString)
        XCTAssertEqual(model.handle(request(prompt: "a different prompt")).code, "conflict")
        XCTAssertEqual(model.handle(request(project: "missing")).code, "conflict")
        XCTAssertEqual(launches.count, 1)

        let untitled = model.handle(request(id: UUID(), title: nil))
        XCTAssertEqual(untitled.code, "created")
        XCTAssertEqual(model.project("p1")?.sessions.last?.title, "Copilot")
        XCTAssertEqual(launches.count, 2)

        let invalid: [(String?, String)] = [
            ("", "p"), ("   ", "p"), ("bad\u{1b}title", "p"), ("bad\u{85}title", "p"),
            (String(repeating: "t", count: AppModel.maximumSessionTitleLength + 1), "p"),
            ("ok", ""), ("ok", "\u{7}"), ("ok", String(repeating: "x", count: 8_193)),
        ]
        for (title, prompt) in invalid {
            let response = model.handle(request(id: UUID(), title: title, prompt: prompt))
            XCTAssertFalse(response.ok)
            XCTAssertEqual(response.code, "bad-request", "title \(title?.count ?? -1), prompt \(prompt.utf8.count)")
        }
        XCTAssertEqual(model.handle(request(id: UUID(), project: "missing")).code, "unknown-project")
        XCTAssertEqual(launches.count, 2)

        // After the session ends, the tombstone prevents a replay from launching again.
        let restarted = try makeRemoteCreateModel(
            root: root, projects: [Project(id: "p1", name: "PR Reviews", cwd: "/tmp")],
            selectedProjectId: "p1", reposDirectory: { repos.path }, ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2)) }
        )
        XCTAssertEqual(restarted.handle(request()).code, "gone")
        XCTAssertEqual(restarted.handle(request(prompt: "a different prompt")).code, "conflict")
        XCTAssertEqual(launches.count, 2)
    }

    @MainActor
    func testCreateRemoteDefaultConfiguredAndReviewRequestsNeverUseLegacyExemptions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let overrides = [
            "COPILOT_PROJECTS_STATE_DIR": root.path,
            "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("control.sock").path,
        ]
        let previous = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in overrides { setenv(key, value, 1) }
        var launches = 0
        var backendAvailable = true
        var executable: String? = "/opt/copilot/bin/copilot"
        var cwd: String? = root.path
        let model = try makeRemoteCreateModel(
            root: root, projects: [Project(id: "p1", name: "First", cwd: root.path)],
            selectedProjectId: "p1", copilotExecutable: { executable },
            reposDirectory: { cwd }, backendAvailable: { backendAvailable },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { _, _, _ in launches += 1 }
        )
        for reviewURL in [nil, "https://github.com/owner/repo/pull/12"] {
            let request = RemoteCreateSessionRequest(
                requestId: UUID(), projectId: "p1", pullRequestURL: reviewURL)
            func create(projectId: String = "p1") -> RemoteSessionCreationOutcome {
                let input = RemoteCreateSessionRequest(
                    requestId: request.requestId, projectId: projectId, pullRequestURL: reviewURL)
                return reviewURL == nil
                    ? model.createRemoteConfiguredSession(input)
                    : model.createRemoteAdversarialReviewSession(input)
            }
            let socket = URL(fileURLWithPath: Paths.dtachSocketPath(sessionId: request.requestId.uuidString))
            try FileManager.default.createDirectory(
                at: socket.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: socket)
            let before = launches
            XCTAssertEqual(create(), .conflict)
            XCTAssertEqual(create(projectId: "missing"), .conflict)
            backendAvailable = false
            XCTAssertEqual(create(), .conflict)
            backendAvailable = true
            executable = nil
            XCTAssertEqual(create(), .conflict)
            executable = "/opt/copilot/bin/copilot"
            cwd = nil
            XCTAssertEqual(create(), .conflict)
            cwd = root.path
            XCTAssertEqual(launches, before)
            try FileManager.default.removeItem(at: socket)
            let staleMarker = root.appendingPathComponent("\(request.requestId.uuidString).copilot-session")
            try UUID().uuidString.write(to: staleMarker, atomically: true, encoding: .utf8)
            backendAvailable = false
            XCTAssertEqual(create(), .unavailable)
            backendAvailable = true
            cwd = nil
            XCTAssertEqual(create(), .invalid)
            cwd = root.path
            XCTAssertEqual(launches, before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: staleMarker.path))
            XCTAssertEqual(create(), .created(RemoteCreateSessionResponse(
                requestId: request.requestId, projectId: "p1", sessionId: request.requestId.uuidString)))
            XCTAssertEqual(launches, before + 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarker.path))
        }
    }

    @MainActor
    func testCreateRemoteConfiguredSessionRejectsInvalidOptionsBeforeLedgerAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("ledger.json")
        let project = Project(id: "p1", name: "First", cwd: root.path)
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { root.path }, ledger: SessionCreationLedger(url: ledgerURL),
            onLaunch: { _, _, _ in launches += 1 }
        )
        try Data("{".utf8).write(to: ledgerURL)
        for prompt in [
            "", " \n\t", "\u{0}", "\u{1b}", "\u{7f}", "\u{85}",
            String(repeating: "x", count: 8_193), String(repeating: "é", count: 4_097),
        ] {
            XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
                requestId: UUID(), projectId: project.id, kind: .copilot, initialPrompt: prompt)),
                .badRequest)
        }
        for prompt in ["", "valid prompt"] {
            XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
                requestId: UUID(), projectId: project.id, kind: .terminal, initialPrompt: prompt)),
                .badRequest)
        }
        let reviewURL = "https://github.com/owner/repo/pull/12"
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: project.id, pullRequestURL: reviewURL)), .badRequest)
        XCTAssertEqual(model.createRemoteSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: project.id, kind: .copilot)), .badRequest)
        XCTAssertEqual(model.createRemoteSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: project.id, initialPrompt: "configured")), .badRequest)
        for kind in [RemoteSessionKind.copilot, .terminal] {
            XCTAssertEqual(model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
                requestId: UUID(), projectId: project.id, pullRequestURL: reviewURL, kind: kind)),
                .badRequest)
        }
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: project.id,
            pullRequestURL: reviewURL, initialPrompt: "replace the review")), .badRequest)
        XCTAssertEqual(model.projects, [project])
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteConfiguredTerminalIgnoresStaleResumeMarkerInPTY() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = root.appendingPathComponent("foreground-backend")
        let copilot = root.appendingPathComponent("fake-copilot")
        let capturedArguments = root.appendingPathComponent("startup-arguments")
        try ("#!/bin/sh\nshift 6\nprintf '%s\\0' \"$@\" > "
            + TerminalController.shellSingleQuote(capturedArguments.path) + "\nexec \"$@\"\n")
            .write(to: backend, atomically: true, encoding: .utf8)
        try "#!/bin/sh\nexit 0\n".write(to: copilot, atomically: true, encoding: .utf8)
        for file in [backend, copilot] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let overrides = [
            "SHELL": "/bin/sh",
            "COPILOT_PROJECTS_STATE_DIR": root.path,
            "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("control.sock").path,
            "COPILOT_PROJECTS_DTACH": backend.path,
            "COPILOT_PROJECTS_COPILOT": copilot.path,
        ]
        let previous = overrides.keys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        for (key, value) in overrides { setenv(key, value, 1) }
        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1", kind: .terminal)
        let staleMarker = root.appendingPathComponent("\(request.requestId.uuidString).copilot-session")
        try UUID().uuidString.write(to: staleMarker, atomically: true, encoding: .utf8)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [Project(id: "p1", name: "First", cwd: root.path)], selectedProjectId: "p1"))
        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remoteCopilotExecutable: { nil }, remoteReposDirectory: { root.path },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        defer { model.detachAllClients() }
        let orphanSocket = URL(fileURLWithPath: Paths.dtachSocketPath(sessionId: request.requestId.uuidString))
        try FileManager.default.createDirectory(
            at: orphanSocket.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: orphanSocket)
        XCTAssertEqual(model.createRemoteConfiguredSession(request), .conflict)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturedArguments.path))
        try FileManager.default.removeItem(at: orphanSocket)
        XCTAssertEqual(model.createRemoteConfiguredSession(request), .created(RemoteCreateSessionResponse(
            requestId: request.requestId, projectId: "p1", sessionId: request.requestId.uuidString)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMarker.path))
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: capturedArguments.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let arguments = try Data(contentsOf: capturedArguments).split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(arguments, ["/bin/sh", "-l"])
        XCTAssertNil(model.startingPrompt(for: request.requestId.uuidString))

        try FileManager.default.removeItem(at: capturedArguments)
        let restoredId = UUID().uuidString
        let recordedCopilot = UUID().uuidString
        try recordedCopilot.write(
            to: root.appendingPathComponent("\(restoredId).copilot-session"),
            atomically: true, encoding: .utf8)
        var projects = model.projects
        projects[0].sessions.append(Session(id: restoredId, title: "Copilot", cwd: root.path))
        try repository.save(PersistedState(projects: projects, selectedProjectId: "p1"))
        let restoredModel = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            remoteCopilotExecutable: { copilot.path }, remoteReposDirectory: { root.path },
            sessionCreationLedger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("restored-images"))
        )
        defer { restoredModel.detachAllClients() }
        XCTAssertNotNil(restoredModel.controller(for: request.requestId.uuidString))
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: capturedArguments.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let terminalAfterRestart = try Data(contentsOf: capturedArguments).split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(terminalAfterRestart, ["/bin/sh", "-l"])
        try FileManager.default.removeItem(at: capturedArguments)
        XCTAssertNotNil(restoredModel.controller(for: restoredId))
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: capturedArguments.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let restoredArguments = try Data(contentsOf: capturedArguments).split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(restoredArguments, TerminalController.startupProgram(
            shell: "/bin/sh", copilotSessionId: recordedCopilot,
            resumeCopilotExecutable: copilot.path,
            launchCopilotExecutable: nil))

        try FileManager.default.removeItem(at: capturedArguments)
        let legacyRequest = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1")
        let legacyCopilot = UUID().uuidString
        let legacyMarker = root.appendingPathComponent("\(legacyRequest.requestId.uuidString).copilot-session")
        try legacyCopilot.write(to: legacyMarker, atomically: true, encoding: .utf8)
        XCTAssertEqual(restoredModel.createRemoteSession(legacyRequest), .created(RemoteCreateSessionResponse(
            requestId: legacyRequest.requestId, projectId: "p1", sessionId: legacyRequest.requestId.uuidString)))
        for _ in 0 ..< 200 {
            if FileManager.default.fileExists(atPath: capturedArguments.path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let legacyArguments = try Data(contentsOf: capturedArguments).split(separator: 0)
            .map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(legacyArguments, TerminalController.startupProgram(
            shell: "/bin/sh", copilotSessionId: legacyCopilot,
            resumeCopilotExecutable: copilot.path,
            launchCopilotExecutable: copilot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyMarker.path))
    }

    @MainActor
    func testCreateRemoteConfiguredSessionFailsClosedWhenStaleMarkerIsNotAFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = RemoteCreateSessionRequest(requestId: UUID(), projectId: "p1", kind: .terminal)
        let marker = root.appendingPathComponent("\(request.requestId.uuidString).copilot-session")
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: false)
        let sentinel = marker.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        var launches = 0
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [Project(id: "p1", name: "First", cwd: root.path)],
            selectedProjectId: "p1", copilotExecutable: { nil }, reposDirectory: { root.path },
            ledger: ledger, onLaunch: { _, _, _ in launches += 1 }
        )
        XCTAssertEqual(model.createRemoteConfiguredSession(request), .persistenceUnavailable)
        XCTAssertEqual(launches, 0)
        XCTAssertTrue(model.project("p1")?.sessions.isEmpty == true)
        XCTAssertNil(try ledger.record(for: request.requestId))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    @MainActor
    func testCreateRemoteSessionRejectsChangedIntentWithoutRelaunching() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root, projects: [Project(id: "p1", name: "First", cwd: root.path)],
            selectedProjectId: "p1", reposDirectory: { root.path },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { _, _, _ in launches += 1 }
        )
        let id = UUID()
        let response = RemoteCreateSessionResponse(requestId: id, projectId: "p1", sessionId: id.uuidString)
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", initialPrompt: "first\r\nsecond")), .created(response))
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", kind: .copilot, initialPrompt: "first\nsecond")), .existing(response))
        for request in [
            RemoteCreateSessionRequest(requestId: id, projectId: "p1", kind: .terminal),
            RemoteCreateSessionRequest(requestId: id, projectId: "p1"),
            RemoteCreateSessionRequest(requestId: id, projectId: "p1", initialPrompt: "different"),
            RemoteCreateSessionRequest(requestId: id, projectId: "p2", initialPrompt: "first\nsecond"),
        ] {
            XCTAssertEqual(model.createRemoteConfiguredSession(request), .conflict)
        }
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", pullRequestURL: "https://github.com/owner/repo/pull/12")),
            .conflict)
        XCTAssertEqual(launches, 1)

        let reviewId = UUID()
        let review = RemoteCreateSessionRequest(
            requestId: reviewId, projectId: "p1", pullRequestURL: "https://github.com/owner/repo/pull/12")
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(review), .created(
            RemoteCreateSessionResponse(requestId: reviewId, projectId: "p1", sessionId: reviewId.uuidString)))
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: reviewId, projectId: "p1", pullRequestURL: "https://github.com/owner/repo/pull/13")),
            .conflict)
        XCTAssertEqual(model.createRemoteSession(RemoteCreateSessionRequest(
            requestId: reviewId, projectId: "p1")), .conflict)
        XCTAssertEqual(launches, 2)
    }

    @MainActor
    func testCreateRemoteSessionFingerprintSurvivesRestartWithoutLedgerAfterMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ledgerURL = root.appendingPathComponent("ledger.json")
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [
                Project(id: "p1", name: "First", cwd: root.path),
                Project(id: "p2", name: "Second", cwd: root.path),
            ],
            selectedProjectId: "p1", reposDirectory: { root.path },
            ledger: SessionCreationLedger(url: ledgerURL),
            onLaunch: { _, _, _ in
                launches += 1
                do {
                    try FileManager.default.createDirectory(at: ledgerURL, withIntermediateDirectories: false)
                } catch {
                    XCTFail("Could not inject the ledger write failure: \(error)")
                }
            }
        )
        let request = RemoteCreateSessionRequest(
            requestId: UUID(), projectId: "p1", kind: .copilot, initialPrompt: "UNIQUE_RESTART_PROMPT")
        XCTAssertEqual(model.createRemoteConfiguredSession(request), .persistenceUnavailable)
        XCTAssertEqual(launches, 1)
        XCTAssertEqual(model.moveRemoteSession(sessionId: request.requestId.uuidString, toProjectId: "p2"), .moved)
        try FileManager.default.removeItem(at: ledgerURL)

        let ledger = SessionCreationLedger(url: ledgerURL)
        let restarted = AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json")),
            isAppActive: { false }, agentActivityDirectory: root, resumeMarkerDirectory: root,
            remoteCopilotExecutable: { "/opt/copilot/bin/copilot" },
            remoteReposDirectory: { root.path }, remoteSessionBackendAvailable: { true },
            remoteSessionLauncher: { _, _, _ in launches += 1 },
            sessionCreationLedger: ledger,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images"))
        )
        for changed in [
            RemoteCreateSessionRequest(requestId: request.requestId, projectId: "p1", kind: .terminal),
            RemoteCreateSessionRequest(
                requestId: request.requestId, projectId: "p1", initialPrompt: "changed"),
            RemoteCreateSessionRequest(
                requestId: request.requestId, projectId: "p2", initialPrompt: request.initialPrompt),
        ] {
            XCTAssertEqual(restarted.createRemoteConfiguredSession(changed), .conflict)
        }
        XCTAssertEqual(restarted.createRemoteConfiguredSession(request), .existing(RemoteCreateSessionResponse(
            requestId: request.requestId, projectId: "p2", sessionId: request.requestId.uuidString)))
        XCTAssertEqual(launches, 1)
        XCTAssertNotNil(try ledger.record(for: request.requestId)?.creationFingerprint)
        for file in ["state.json", "ledger.json"] {
            XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .contains("UNIQUE_RESTART_PROMPT"))
        }
    }

    @MainActor
    func testCreateRemoteSessionTombstoneChecksIntentBeforeReturningGone() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        try ledger.remember(SessionCreationRecord(
            requestId: id.uuidString, projectId: "p1", sessionId: id.uuidString, createdAt: Date(),
            creationFingerprint: SessionCreationRecord.fingerprint(
                projectId: "p1", kind: .terminal, initialPrompt: nil, pullRequestURL: nil)))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root, projects: [Project(id: "p1", name: "First", cwd: root.path)],
            selectedProjectId: "p1", reposDirectory: { root.path }, ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", kind: .terminal)), .gone)
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", kind: .copilot)), .conflict)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteSessionRejectsReplaysWithoutAnIntentFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let oldSession = Session(id: id.uuidString, title: "old", cwd: root.path)
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        try ledger.remember(SessionCreationRecord(
            requestId: id.uuidString, projectId: "p1", sessionId: id.uuidString, createdAt: Date()))
        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p2", name: "Moved", cwd: root.path, sessions: [oldSession])],
            selectedProjectId: "p2", reposDirectory: { root.path }, ledger: ledger,
            onLaunch: { _, _, _ in launches += 1 }
        )
        XCTAssertEqual(model.createRemoteSession(
            RemoteCreateSessionRequest(requestId: id, projectId: "p1")), .conflict)
        for kind in [nil, RemoteSessionKind.copilot, .terminal] {
            XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
                requestId: id, projectId: "p1", kind: kind)), .conflict)
        }
        XCTAssertEqual(model.createRemoteAdversarialReviewSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", pullRequestURL: "https://github.com/owner/repo/pull/12")),
            .conflict)
        XCTAssertNil(model.project("p2")?.sessions.first?.creationFingerprint)
        XCTAssertNil(try ledger.record(for: id)?.creationFingerprint)
        XCTAssertEqual(launches, 0)
    }


    @MainActor
    func testRemoteWorkspaceSnapshotPreservesModelContract() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let waiting = Session(id: "session-1", title: "waiting", cwd: "/one")
        let completed = Session(id: "session-2", title: "completed", cwd: "/two")
        let selected = Project(
            id: "project-1",
            name: "selected",
            cwd: "/one",
            sessions: [waiting, completed],
            selectedSessionId: waiting.id
        )
        let other = Project(id: "project-2", name: "other", cwd: "/other")
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(
            projects: [selected, other],
            selectedProjectId: selected.id
        ))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root
        )
        model.setStatus(
            sessionId: waiting.id,
            status: .waiting,
            text: "needs input",
            timestamp: 100,
            source: "scheduled-start"
        )
        model.setStatus(
            sessionId: completed.id,
            status: .running,
            text: "working",
            timestamp: 100
        )
        model.setStatus(
            sessionId: completed.id,
            status: .idle,
            text: nil,
            timestamp: 200
        )

        XCTAssertEqual(model.remoteWorkspaceSnapshot(), RemoteWorkspaceSnapshot(
            projects: [
                RemoteProjectSnapshot(
                    id: selected.id,
                    name: selected.name,
                    selectedSessionId: waiting.id,
                    sessions: [
                        RemoteSessionSnapshot(
                            id: waiting.id,
                            title: waiting.title,
                            status: SessionStatus.waiting.rawValue,
                            statusText: "needs input",
                            unread: false,
                            ready: false,
                            background: true,
                            scheduled: false,
                            promptable: false,
                            operationSupport: .unavailable,
                            attention: RemoteSessionAttention(.waiting),
                            needsEndConfirmation: true
                        ),
                        RemoteSessionSnapshot(
                            id: completed.id,
                            title: completed.title,
                            status: SessionStatus.idle.rawValue,
                            statusText: nil,
                            unread: false,
                            ready: true,
                            background: false,
                            scheduled: false,
                            promptable: false,
                            operationSupport: .unavailable,
                            unreadMarker: model.projects[0].sessions[1].unreadMarker,
                            attention: RemoteSessionAttention(.ready),
                            needsEndConfirmation: false
                        ),
                    ]
                ),
                RemoteProjectSnapshot(
                    id: other.id,
                    name: other.name,
                    selectedSessionId: nil,
                    sessions: []
                ),
            ],
            selectedProjectId: selected.id,
            protocolInfo: .current.supportingReplaySafeControl(epoch: model.remoteControlDeliveryEpoch)
        ))
    }

    func testAgentActivitySnapshotDecodesModelInfo() throws {
        let base = "\"schemaVersion\":1,\"updatedAt\":\"2026-07-14T00:00:00Z\","
            + "\"foregroundTurnActive\":false,\"scheduledTurnActive\":false,"
            + "\"activeSubagents\":[],\"schedules\":[],\"idleGeneration\":0,"
            + "\"lastIdleAborted\":false"
        let full = Data(("{" + base + ",\"model\":{\"name\":\"gpt-5.5\","
            + "\"reasoningEffort\":\"high\",\"contextTier\":\"long_context\"}}").utf8)
        let info = try XCTUnwrap(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: full).remoteModelInfo()
        )
        XCTAssertEqual(info.name, "gpt-5.5")
        XCTAssertEqual(info.reasoningEffort, "high")
        XCTAssertEqual(info.contextTier, "long_context")

        let bare = Data(("{" + base + "}").utf8)
        XCTAssertNil(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: bare).remoteModelInfo()
        )
    }

    func testAgentActivitySnapshotDecodesAvailableModels() throws {
        let base = "\"schemaVersion\":1,\"updatedAt\":\"2026-07-14T00:00:00Z\","
            + "\"foregroundTurnActive\":false,\"scheduledTurnActive\":false,"
            + "\"activeSubagents\":[],\"schedules\":[],\"idleGeneration\":0,"
            + "\"lastIdleAborted\":false"
        // A well-formed entry, plus one missing its id which must be dropped.
        let full = Data(("{" + base + ",\"availableModels\":["
            + "{\"id\":\"gpt-5.4\",\"name\":\"GPT-5.4\","
            + "\"supportedReasoningEfforts\":[\"low\",\"high\"],"
            + "\"defaultReasoningEffort\":\"high\",\"longContextAvailable\":true,"
            + "\"disabled\":false,\"category\":\"versatile\"},"
            + "{\"name\":\"No Id\"}]}").utf8)
        let models = try XCTUnwrap(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: full)
                .remoteAvailableModels()
        )
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].id, "gpt-5.4")
        XCTAssertEqual(models[0].name, "GPT-5.4")
        XCTAssertEqual(models[0].supportedReasoningEfforts, ["low", "high"])
        XCTAssertEqual(models[0].defaultReasoningEffort, "high")
        XCTAssertEqual(models[0].longContextAvailable, true)
        XCTAssertEqual(models[0].disabled, false)
        XCTAssertEqual(models[0].category, "versatile")

        let bare = Data(("{" + base + "}").utf8)
        XCTAssertNil(
            try JSONDecoder().decode(AgentActivitySnapshot.self, from: bare)
                .remoteAvailableModels()
        )
    }

    func testAgentActivitySnapshotDetectsTerminalDisconnect() throws {
        let base = "\"schemaVersion\":1,\"updatedAt\":\"2026-07-14T00:00:00Z\","
            + "\"foregroundTurnActive\":true,\"scheduledTurnActive\":false,"
            + "\"activeSubagents\":[],\"schedules\":[],\"idleGeneration\":0,"
            + "\"lastIdleAborted\":false"
        func snapshot(errorJSON: String?) throws -> AgentActivitySnapshot {
            let body = errorJSON.map { "{" + base + ",\"error\":\($0)}" } ?? "{" + base + "}"
            return try JSONDecoder().decode(AgentActivitySnapshot.self, from: Data(body.utf8))
        }
        // No error, or an unrelated error, is not a terminal disconnect.
        XCTAssertFalse(try snapshot(errorJSON: nil).reportsTerminalDisconnect)
        XCTAssertFalse(try snapshot(errorJSON: "\"Error: schedule list failed\"").reportsTerminalDisconnect)
        // vscode-jsonrpc terminal wordings, case-insensitive.
        XCTAssertTrue(try snapshot(errorJSON: "\"Error: Connection is closed.\"").reportsTerminalDisconnect)
        XCTAssertTrue(try snapshot(errorJSON: "\"Connection is disposed.\"").reportsTerminalDisconnect)
        XCTAssertTrue(try snapshot(errorJSON: "\"CONNECTION IS CLOSED\"").reportsTerminalDisconnect)
    }

    func testDisconnectDemotionEvidencePolicy() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-14T00:00:00Z"))
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        func snap(error: String?, updatedAt: String = "2026-07-14T00:00:00Z") throws -> AgentActivitySnapshot {
            var body = "{\"schemaVersion\":1,\"updatedAt\":\"\(updatedAt)\","
                + "\"foregroundTurnActive\":true,\"scheduledTurnActive\":false,"
                + "\"activeSubagents\":[],\"schedules\":[],\"idleGeneration\":0,"
                + "\"lastIdleAborted\":false"
            if let error { body += ",\"error\":\"\(error)\"" }
            body += "}"
            return try JSONDecoder().decode(AgentActivitySnapshot.self, from: Data(body.utf8))
        }
        // Running + idle footer + fresh disconnect, newer than the clock → demote (returns evidence ms).
        XCTAssertEqual(
            AppModel.disconnectDemotionEvidenceMs(
                status: .running, footerActivity: .idle,
                snapshot: try snap(error: "Connection is closed."),
                now: now, nowMs: nowMs, clockMs: .min),
            nowMs
        )
        // Healthy snapshot (no terminal error) → never demote.
        XCTAssertNil(AppModel.disconnectDemotionEvidenceMs(
            status: .running, footerActivity: .idle,
            snapshot: try snap(error: nil), now: now, nowMs: nowMs, clockMs: .min))
        // Footer still working → don't demote a genuinely-working session.
        XCTAssertNil(AppModel.disconnectDemotionEvidenceMs(
            status: .running, footerActivity: .working,
            snapshot: try snap(error: "Connection is closed."), now: now, nowMs: nowMs, clockMs: .min))
        // Not running → not applicable.
        XCTAssertNil(AppModel.disconnectDemotionEvidenceMs(
            status: .idle, footerActivity: .idle,
            snapshot: try snap(error: "Connection is closed."), now: now, nowMs: nowMs, clockMs: .min))
        // Snapshot older than the status clock → don't override a newer hook.
        XCTAssertNil(AppModel.disconnectDemotionEvidenceMs(
            status: .running, footerActivity: .idle,
            snapshot: try snap(error: "Connection is closed."), now: now, nowMs: nowMs, clockMs: nowMs + 1))
        // Stale snapshot (updatedAt long past) → isFresh false → don't demote.
        XCTAssertNil(AppModel.disconnectDemotionEvidenceMs(
            status: .running, footerActivity: .idle,
            snapshot: try snap(error: "Connection is closed.", updatedAt: "2000-01-01T00:00:00Z"),
            now: now, nowMs: nowMs, clockMs: .min))
    }

    func testRemoteTerminalScreenCaptureNormalizesCells() {
        XCTAssertEqual(RemoteTerminalScreen.captureVisible(
            sessionId: "session",
            cols: 2,
            rows: 2,
            lineAt: { ["A\u{0}", "\u{0}B"][$0] }
        ), RemoteTerminalScreen(
            sessionId: "session",
            cols: 2,
            rows: 2,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: ["A ", " B"]
        ))
    }

    func testRemoteTerminalHistoryUsesAbsoluteIncrementalSegments() {
        let values = Dictionary(uniqueKeysWithValues: (100 ..< 108).map {
            ($0, "line-\($0)")
        })
        let initial = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 100,
            scanRows: 8,
            maximumRows: 6,
            afterLine: nil,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(initial.historyStartLine, 102)
        XCTAssertEqual(initial.firstLine, 102)
        XCTAssertEqual(initial.liveTopLine, 105)
        XCTAssertTrue(initial.reset)
        XCTAssertEqual(initial.lines, (102 ..< 108).map { "line-\($0)" })

        let delta = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 100,
            scanRows: 8,
            maximumRows: 6,
            afterLine: 106,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(delta.firstLine, 103)
        XCTAssertFalse(delta.reset)
        XCTAssertEqual(delta.lines, (103 ..< 108).map { "line-\($0)" })
    }

    func testRemoteTerminalHistoryScansPastDisplayedWindowToLiveRows() {
        let values = Dictionary(uniqueKeysWithValues: (0 ..< 12).map {
            ($0, "line-\($0)")
        })
        let screen = RemoteTerminalScreen.captureHistory(
            sessionId: "session",
            cols: 20,
            rows: 3,
            absoluteStart: 0,
            scanRows: 12,
            maximumRows: 6,
            afterLine: nil,
            lineExists: { values[$0] != nil },
            lineAt: { values[$0] }
        )
        XCTAssertEqual(screen.historyStartLine, 6)
        XCTAssertEqual(screen.liveTopLine, 9)
        XCTAssertEqual(screen.lines, (6 ..< 12).map { "line-\($0)" })
    }

    func testRemoteScrollMessageRoundTrips() throws {
        let message = RemoteClientMessage(
            type: "scroll",
            clientId: "phone",
            sessionId: "session",
            delta: -4
        )
        let decoded = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: JSONEncoder().encode(message)
        )
        XCTAssertEqual(decoded.type, "scroll")
        XCTAssertEqual(decoded.delta, -4)
    }

    func testRemoteSessionSnapshotDecodesWithoutPromptableField() throws {
        let data = Data("""
        {
          "id":"session",
          "title":"shell",
          "status":"idle",
          "unread":false,
          "ready":false,
          "background":false,
          "scheduled":false
        }
        """.utf8)
        let snapshot = try JSONDecoder().decode(RemoteSessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.promptable)
    }

    func testRemoteSessionSnapshotDecodesWithoutPendingUserInputs() throws {
        let data = Data("""
        {
          "id":"session",
          "title":"shell",
          "status":"idle",
          "unread":false,
          "ready":false,
          "background":false,
          "scheduled":false,
          "promptable":true
        }
        """.utf8)
        let snapshot = try JSONDecoder().decode(RemoteSessionSnapshot.self, from: data)
        XCTAssertNil(snapshot.pendingUserInputs)
    }

    func testRemoteUserInputRequestPreservesVerbatimChoices() throws {
        let request = RemoteUserInputRequest(
            requestId: "req-1",
            question: "Deploy to production?",
            choices: ["Yes, deploy", "No — keep the current build"],
            allowFreeform: true,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            agentId: "agent-3"
        )
        let decoded = try JSONDecoder().decode(
            RemoteUserInputRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.id, "req-1")
        XCTAssertEqual(decoded.choices, ["Yes, deploy", "No — keep the current build"])
    }

    func testMarkdownParserSplitsCommonBlockStructure() {
        let markdown = """
        # Heading

        A paragraph with **bold** text.

        3. third
        4. fourth
            - nested

        > a quote

        ```swift
        let x = 1
        ```

        | Name | Count |
        |:-----|------:|
        | apple | 3 |
        """

        XCTAssertEqual(MarkdownParser.blocks(from: markdown), [
            .heading(level: 1, text: "Heading"),
            .paragraph("A paragraph with **bold** text."),
            .list([
                MarkdownListItem(marker: "3.", text: "third", depth: 0),
                MarkdownListItem(marker: "4.", text: "fourth", depth: 0),
                MarkdownListItem(marker: "\u{2022}", text: "nested", depth: 2),
            ]),
            .quote("a quote"),
            .codeBlock("let x = 1"),
            .table(MarkdownTable(
                header: ["Name", "Count"],
                alignments: [.leading, .trailing],
                rows: [["apple", "3"]]
            )),
        ])
    }

    func testMarkdownParserKeepsAmbiguousTextReadable() {
        XCTAssertEqual(
            MarkdownParser.blocks(from: "some | text\n---"),
            [.paragraph("some | text\n---")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "#not a heading\n1.2 is a version"),
            [.paragraph("#not a heading\n1.2 is a version")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "```\nunterminated"),
            [.codeBlock("unterminated")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "```inline triple backtick```"),
            [.paragraph("```inline triple backtick```")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "***bold***"),
            [.paragraph("***bold***")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "```\n---\n```"),
            [.codeBlock("---")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "- item\n---\nNext"),
            [
                .list([MarkdownListItem(marker: "\u{2022}", text: "item", depth: 0)]),
                .paragraph("---"),
                .paragraph("Next"),
            ]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "Before\n***\n- item\n* * *\nAfter\n- - -"),
            [
                .paragraph("Before"),
                .paragraph("***"),
                .list([MarkdownListItem(marker: "\u{2022}", text: "item", depth: 0)]),
                .paragraph("* * *"),
                .paragraph("After"),
                .paragraph("- - -"),
            ]
        )
        XCTAssertFalse(MarkdownParser.isThematicBreak("__\n__"))
        XCTAssertEqual(
            MarkdownParser.blocks(from: "- item\n  | A | B |\n  | --- | ---: |\n  | x | 1 |"),
            [
                .list([MarkdownListItem(marker: "\u{2022}", text: "item", depth: 0)]),
                .table(MarkdownTable(
                    header: ["A", "B"],
                    alignments: [.leading, .trailing],
                    rows: [["x", "1"]]
                )),
            ]
        )
        let header900 = Array(repeating: "h", count: 900).joined(separator: " | ")
        let delim900 = Array(repeating: "---", count: 900).joined(separator: " | ")
        let row900 = Array(repeating: "v", count: 900).joined(separator: " | ")
        let hugeTable = ([header900, delim900] + Array(repeating: row900, count: 9)).joined(separator: "\n")
        let header400 = Array(repeating: "h", count: 400).joined(separator: " | ")
        let delim400 = Array(repeating: "---", count: 400).joined(separator: " | ")
        let row400 = Array(repeating: "v", count: 400).joined(separator: " | ")
        let table8000 = ([header400, delim400] + Array(repeating: row400, count: 19)).joined(separator: "\n")
        let markerHeader100 = Array(repeating: "h", count: 100).joined(separator: " | ")
        let markerDelim100 = Array(repeating: "---", count: 100).joined(separator: " | ")
        let markerRow100 = Array(repeating: "**x**", count: 100).joined(separator: " | ")
        let markerTable1000 = ([markerHeader100, markerDelim100] + Array(repeating: markerRow100, count: 9)).joined(separator: "\n")
        let eightMarkerTables = Array(repeating: markerTable1000, count: 8).joined(separator: "\n\n")
        let smallTable = "| K | V |\n| --- | --- |\n| a | b |"
        XCTAssertEqual(
            MarkdownParser.blocks(from: "\(hugeTable)\n\n\(table8000)\n\n\(eightMarkerTables)\n\n\(smallTable)").last,
            .table(MarkdownTable(header: ["K", "V"], alignments: [.leading, .leading], rows: [["a", "b"]]))
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "\(hugeTable)\n\n\(table8000)").map { block in
                if case .plainText = block { return true }
                return false
            },
            [true, true]
        )
        let escapedPipeRow = "| " + String(repeating: #"\|"#, count: 1_001) + " | z |"
        let oversizedRowTable = "| A | B |\n| --- | --- |\n| r1 | 1 |\n\(escapedPipeRow)\n| r3 | 3 |"
        let header1002 = (["**bold_1002**"] + Array(repeating: "h", count: 1_001)).joined(separator: " | ")
        let delim1002 = Array(repeating: "---", count: 1_002).joined(separator: " | ")
        let row1002 = Array(repeating: "v", count: 1_002).joined(separator: " | ")
        let table1002 = "\(header1002)\n\(delim1002)\n\(row1002)"
        XCTAssertEqual(
            MarkdownParser.blocks(from: "a | b\n\(delim1002)"),
            [.paragraph("a | b\n\(delim1002)")]
        )
        XCTAssertEqual(
            MarkdownParser.blocks(from: "- item\n\(escapedPipeRow)\n| --- | --- |\n| r1 | 1 |\n\n\(oversizedRowTable)\n\n\(table1002)\n\n\(smallTable)"),
            [
                .list([MarkdownListItem(marker: "\u{2022}", text: "item", depth: 0)]),
                .plainText("\(escapedPipeRow)\n| --- | --- |\n| r1 | 1 |"),
                .plainText(oversizedRowTable),
                .plainText(table1002),
                .table(MarkdownTable(header: ["K", "V"], alignments: [.leading, .leading], rows: [["a", "b"]])),
            ]
        )
    }

    func testMarkdownParserParsesDetailsAndSummaryBlocks() {
        let inlineSummaryMarkdown = """
        <details><summary>KQL Queries</summary>

        ```kql
        let _start = datetime(2026-01-01);
        ```
        </details>
        """
        XCTAssertEqual(
            MarkdownParser.blocks(from: inlineSummaryMarkdown),
            [
                .details(MarkdownDetails(
                    summary: "KQL Queries",
                    body: "```kql\nlet _start = datetime(2026-01-01);\n```",
                    isOpen: false
                )),
            ]
        )

        let openWithoutSummaryMarkdown = """
        <details open>
        Expanded body paragraph.
        </details>
        """
        XCTAssertEqual(
            MarkdownParser.blocks(from: openWithoutSummaryMarkdown),
            [
                .details(MarkdownDetails(
                    summary: "Details",
                    body: "Expanded body paragraph.",
                    isOpen: true
                )),
            ]
        )

        let fencedClosingTagMarkdown = """
        <details>
        <summary>Example HTML</summary>

        ```html
        <details>
        </details>
        ```

        Trailing note.
        </details>
        """
        XCTAssertEqual(
            MarkdownParser.blocks(from: fencedClosingTagMarkdown),
            [
                .details(MarkdownDetails(
                    summary: "Example HTML",
                    body: "```html\n<details>\n</details>\n```\n\nTrailing note.",
                    isOpen: false
                )),
            ]
        )

        let listFollowedByDetails = """
        - first item
        <details>
        <summary>More</summary>
        Hidden
        </details>
        """
        XCTAssertEqual(
            MarkdownParser.blocks(from: listFollowedByDetails),
            [
                .list([MarkdownListItem(marker: "\u{2022}", text: "first item", depth: 0)]),
                .details(MarkdownDetails(summary: "More", body: "Hidden", isOpen: false)),
            ]
        )
    }

    func testMarkdownRenderingLimitsPreventStructuralAmplification() {
        XCTAssertTrue(MarkdownParser.isWithinRenderingLimits("# Heading\n\nBody"))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            Array(repeating: "- item", count: 501).joined(separator: "\n")
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            Array(repeating: "- item", count: 501).joined(separator: "\r\n")
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            Array(repeating: "- item", count: 501).joined(separator: "\r")
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            String(repeating: "|", count: 1_001)
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            String(repeating: "a", count: 256 * 1_024 + 1)
        ))
        // A single-line, pipe-free input with tens of thousands of tiny
        // inline formatting spans stays under the byte/line/pipe caps but
        // must still be rejected so the native renderer falls back to plain
        // text instead of expanding into tens of thousands of
        // AttributedString formatting runs.
        XCTAssertTrue(MarkdownParser.isWithinRenderingLimits(
            "A paragraph with **bold**, *italic*, `code`, and _emphasis_ text."
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            Array(repeating: "**x** ", count: 40_000).joined()
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            String(repeating: "[x](u) ", count: 30_000)
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            String(repeating: "<https://x> ", count: 20_000)
        ))
        let wideHeader = Array(repeating: "h", count: 50).joined(separator: " | ")
        let wideDelimiter = Array(repeating: "---", count: 50).joined(separator: " | ")
        let sparseRows = Array(repeating: "a | b", count: 25).joined(separator: "\n")
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            "\(wideHeader)\n\(wideDelimiter)\n\(sparseRows)"
        ))
        let wrappedTableUnit = "| A | B |\n| --- | --- |\n| \(String(repeating: "wrapped ", count: 250)) | y |"
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            Array(repeating: wrappedTableUnit, count: 16).joined(separator: "\n\n")
        ))
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(
            "<details>\n<summary>Huge table</summary>\n\n\(wideHeader)\n\(wideDelimiter)\n\(sparseRows)\n</details>"
        ))
        let fiveDeepDetails = String(repeating: "<details>\n", count: 5)
            + "Inner"
            + String(repeating: "\n</details>", count: 5)
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(fiveDeepDetails))
        let wide300Header = Array(repeating: "h", count: 300).joined(separator: " | ")
        let wide300Delim = Array(repeating: "---", count: 300).joined(separator: " | ")
        let sparse11Rows = Array(repeating: "*a* | *b*", count: 11).joined(separator: "\n")
        let wideTable8KB = Array(repeating: "\(wide300Header)\n\(wide300Delim)\n\(sparse11Rows)", count: 2).joined(separator: "\n\n")
        XCTAssertNil(NotificationSummary.preview(wideTable8KB))
    }

    @MainActor
    private func findTextViews(in root: NSView) -> [MarkdownSelectableTextView] {
        var found: [MarkdownSelectableTextView] = []
        if let textView = root as? MarkdownSelectableTextView {
            found.append(textView)
        }
        for subview in root.subviews {
            found.append(contentsOf: findTextViews(in: subview))
        }
        return found
    }

    @MainActor
    func testMarkdownProseSharesOneTextViewAndKeepsSelectionWhileStreaming() throws {
        let markdown = """
        # Summary

        ASSISTANT_DELTA A separate follow-up with *`emphasized_code`*.

        1. Review the **selected** reply.
        2. Do not include its siblings.

        > Quoted note at the end.
        """
        let hostingView = NSHostingView(
            rootView: MarkdownText(text: markdown)
                .frame(width: 320, alignment: .leading)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 480)
        hostingView.layoutSubtreeIfNeeded()

        let textViews = findTextViews(in: hostingView)
        XCTAssertEqual(
            textViews.count, 1,
            "Consecutive headings, paragraphs, lists, and quotes should share one selectable text view"
        )
        let textView = try XCTUnwrap(textViews.first)
        XCTAssertFalse(textView.isEditable)
        XCTAssertTrue(textView.isSelectable)

        let fullString = textView.attributedText.string as NSString
        let headingRange = fullString.range(of: "Summary")
        XCTAssertNotEqual(headingRange.location, NSNotFound)
        XCTAssertEqual(
            textView.attributedText.attribute(
                MarkdownText.headingLevelAttribute,
                at: headingRange.location,
                effectiveRange: nil
            ) as? NSNumber,
            1
        )
        let boldRange = fullString.range(of: "selected")
        XCTAssertNotEqual(boldRange.location, NSNotFound)
        let boldFont = try XCTUnwrap(
            textView.attributedText.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(boldFont.fontDescriptor.symbolicTraits.contains(.bold))

        let codeRange = fullString.range(of: "emphasized_code")
        XCTAssertNotEqual(codeRange.location, NSNotFound)
        let codeFont = try XCTUnwrap(
            textView.attributedText.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertTrue(codeFont.fontDescriptor.symbolicTraits.contains(.italic))

        let spanTarget = "Summary\nASSISTANT_DELTA A separate follow-up with emphasized_code.\n1.\tReview the selected reply.\n2.\tDo not include its siblings.\nQuoted note at the end."
        let spanRange = fullString.range(of: spanTarget)
        XCTAssertNotEqual(spanRange.location, NSNotFound)
        textView.setSelectedRange(spanRange)
        XCTAssertEqual(fullString.substring(with: textView.selectedRange()), spanTarget)

        let preservedRange = fullString.range(of: "Review the selected reply.")
        textView.setSelectedRange(preservedRange)
        hostingView.rootView = MarkdownText(text: markdown + "\n\nMore streamed output.")
            .frame(width: 320, alignment: .leading)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertTrue(findTextViews(in: hostingView).first === textView)
        XCTAssertEqual(textView.selectedRange(), preservedRange)

        hostingView.rootView = MarkdownText(text: "Completely replaced message.")
            .frame(width: 320, alignment: .leading)
        hostingView.layoutSubtreeIfNeeded()
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 0, length: 0))

        let uncachedTextView = MarkdownSelectableTextView(frame: .zero)
        uncachedTextView.attributedText = NSAttributedString(string: "Short line")
        let intrinsic = uncachedTextView.intrinsicContentSize
        XCTAssertGreaterThan(intrinsic.width, 0)
        XCTAssertLessThan(intrinsic.width, 1_000)
    }

    @MainActor
    func testMarkdownCodeBlockWrapsToItsWidthAndCopiesVerbatim() throws {
        let longCode = """
            let endpoint = "https://api.example.invalid/v1/workspaces/65656978-e32a-431f-9253-bc781012803d/artifacts"

            let digest = "sha256:e449292e54992e2cbb7c771d8011b49e48b5a5d6e449292e54992e2cbb7c771d8011b49e48b5a5d6"
        """
        let codeHost = NSHostingView(
            rootView: MarkdownText(text: "```swift\n\(longCode)\n```")
                .frame(width: 320, alignment: .leading)
        )
        codeHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        codeHost.layoutSubtreeIfNeeded()
        let codeView = try XCTUnwrap(findTextViews(in: codeHost).first)
        XCTAssertTrue(codeView.wrapsText)
        XCTAssertNil(codeView.enclosingScrollView)
        let codeContainer = try XCTUnwrap(codeView.textContainer)
        let codeLayout = try XCTUnwrap(codeView.layoutManager)
        codeLayout.ensureLayout(for: codeContainer)
        let narrowUsed = codeLayout.usedRect(for: codeContainer)
        XCTAssertLessThanOrEqual(narrowUsed.width, 300.5)
        XCTAssertGreaterThan(narrowUsed.height, 60)
        XCTAssertEqual(codeView.attributedText.string, longCode)
        codeView.selectAll(nil)
        XCTAssertEqual(codeView.selectedCopiedText(), longCode)
        codeHost.rootView = MarkdownText(text: "```swift\n\(longCode)\n```")
            .frame(width: 640, alignment: .leading)
        codeHost.frame = NSRect(x: 0, y: 0, width: 640, height: 320)
        codeHost.layoutSubtreeIfNeeded()
        codeLayout.ensureLayout(for: codeContainer)
        let wideUsed = codeLayout.usedRect(for: codeContainer)
        XCTAssertLessThanOrEqual(wideUsed.width, 620.5)
        XCTAssertLessThan(wideUsed.height, narrowUsed.height)
        XCTAssertEqual(codeView.attributedText.string, longCode)
    }

    @MainActor
    func testMarkdownCodeBlockCopyButtonCopiesSnippetToPasteboard() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }

        let firstSnippet = "let greeting = \"hello\"\nprint(greeting)"
        let secondSnippet = "echo 'second block'"
        let markdown = """
        Here is some code:

        ```swift
        \(firstSnippet)
        ```

        And another:

        ```sh
        \(secondSnippet)
        ```
        """
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(
            rootView: MarkdownText(text: markdown)
                .frame(width: 480, alignment: .leading)
        )
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))

        let codeTextViews = findTextViews(in: host).filter {
            $0.attributedText.string == firstSnippet || $0.attributedText.string == secondSnippet
        }
        XCTAssertEqual(codeTextViews.count, 2)

        func clickCopyButton(near codeTextView: MarkdownSelectableTextView) throws {
            let codeFrameInWindow = codeTextView.convert(codeTextView.bounds, to: nil)
            // The code block container has .trailing padding of 34 and the 24x24 copy button sits
            // in the top-trailing corner with 5pt padding (center ~17pt left of container maxX,
            // ~7pt right of codeTextView.maxX, and near the top edge of codeTextView).
            let clickPoint = NSPoint(
                x: codeFrameInWindow.maxX + 17,
                y: codeFrameInWindow.maxY - 7
            )
            let timestamp = ProcessInfo.processInfo.systemUptime
            for (type, delta): (NSEvent.EventType, TimeInterval) in [(.leftMouseDown, 0), (.leftMouseUp, 0.01)] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: clickPoint, modifierFlags: [], timestamp: timestamp + delta,
                    windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
        }

        let pasteboard = NSPasteboard.general
        let savedPasteboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedPasteboard {
                pasteboard.setString(savedPasteboard, forType: .string)
            }
        }
        pasteboard.clearContents()

        try clickCopyButton(near: codeTextViews[0])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pasteboard.string(forType: .string), firstSnippet)

        try clickCopyButton(near: codeTextViews[1])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(pasteboard.string(forType: .string), secondSnippet)
    }

    @MainActor
    func testMarkdownTableSelectionCopiesLogicalCellsAcrossRowsAndWraps() throws {
        let alignments: [MarkdownColumnAlignment] = [.leading, .center, .trailing]
        XCTAssertEqual(
            MarkdownText.resolvedTableTextAlignment(
                alignments, column: 0, layoutDirection: .leftToRight
            ),
            .left
        )
        XCTAssertEqual(
            MarkdownText.resolvedTableTextAlignment(
                alignments, column: 2, layoutDirection: .rightToLeft
            ),
            .left
        )

        let tableMarkdown = """
        | Arm | Score |
        | --- | ---: |
        | 3x Alligator/Terra (high) | 85.4% / 33.2% |
        | 3x Terra 6.1 (xhigh) | 83.3% / 34.3% |
        | 4x Terra 6.1 (high) | 85.6% / 33.4% |
        """
        let tableHost = NSHostingView(
            rootView: MarkdownText(text: tableMarkdown)
                .frame(width: 320, alignment: .leading)
        )
        tableHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        tableHost.layoutSubtreeIfNeeded()
        let tableTextViews = findTextViews(in: tableHost)
        XCTAssertEqual(
            tableTextViews.count, 1,
            "An entire Markdown table should render in a single selectable text view so selection can span multiple rows"
        )
        let tableTextView = try XCTUnwrap(tableTextViews.first)
        let tableString = tableTextView.attributedText.string as NSString
        let multiRowTarget = "3x Alligator/Terra (high)\t85.4% / 33.2%\n3x Terra 6.1 (xhigh)\t83.3% / 34.3%"
        let multiRowRange = tableString.range(of: multiRowTarget)
        XCTAssertNotEqual(multiRowRange.location, NSNotFound)
        tableTextView.setSelectedRange(multiRowRange)
        XCTAssertEqual(tableTextView.selectedCopiedText(), multiRowTarget)

        // Selecting a substring inside a table cell copies that exact substring.
        let midCellRange = tableString.range(of: "Terra (high)")
        XCTAssertNotEqual(midCellRange.location, NSNotFound)
        tableTextView.setSelectedRange(midCellRange)
        XCTAssertEqual(tableTextView.selectedCopiedText(), "Terra (high)")

        // Empty cells and empty rows are preserved in copied table ranges.
        let sparseTableMarkdown = """
        | A | B | C |
        | --- | --- | --- |
        | left | | right |
        | | | |
        | x | y | z |
        """
        let sparseHost = NSHostingView(
            rootView: MarkdownText(text: sparseTableMarkdown)
                .frame(width: 320, alignment: .leading)
        )
        sparseHost.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        sparseHost.layoutSubtreeIfNeeded()
        let sparseTextView = try XCTUnwrap(findTextViews(in: sparseHost).first)
        let sparseString = sparseTextView.attributedText.string as NSString
        let sparseStart = sparseString.range(of: "left").location
        XCTAssertNotEqual(sparseStart, NSNotFound)
        sparseTextView.setSelectedRange(
            NSRange(location: sparseStart, length: sparseString.length - sparseStart)
        )
        XCTAssertEqual(
            sparseTextView.selectedCopiedText(),
            "left\t\tright\n\t\t\nx\ty\tz"
        )

        // Header divider sits strictly between the header glyphs and first body row.
        let dividerY = try XCTUnwrap(tableTextView.headerDividerY())
        let headerGlyphs = tableTextView.layoutManager!.glyphRange(
            forCharacterRange: tableString.range(of: "Arm"),
            actualCharacterRange: nil
        )
        let headerRect = tableTextView.layoutManager!.boundingRect(
            forGlyphRange: headerGlyphs,
            in: tableTextView.textContainer!
        )
        let firstBodyGlyphs = tableTextView.layoutManager!.glyphRange(
            forCharacterRange: tableString.range(of: "3x Alligator"),
            actualCharacterRange: nil
        )
        let firstBodyRect = tableTextView.layoutManager!.boundingRect(
            forGlyphRange: firstBodyGlyphs,
            in: tableTextView.textContainer!
        )
        XCTAssertGreaterThan(dividerY, headerRect.maxY)
        XCTAssertLessThan(dividerY, firstBodyRect.minY)

        // First-column right alignment positions column 0 glyphs to the right of x=0.
        let rightAlignedFirstCol = """
        | Count | Name |
        | ---: | :--- |
        | 1 | alpha |
        | 100000 | beta |
        """
        let rightHost = NSHostingView(
            rootView: MarkdownText(text: rightAlignedFirstCol)
                .frame(width: 320, alignment: .leading)
        )
        rightHost.frame = NSRect(x: 0, y: 0, width: 320, height: 200)
        rightHost.layoutSubtreeIfNeeded()
        let rightTableTextView = try XCTUnwrap(findTextViews(in: rightHost).first)
        let rightTableString = rightTableTextView.attributedText.string as NSString
        let shortNumGlyph = rightTableTextView.layoutManager!.glyphRange(
            forCharacterRange: rightTableString.range(of: "1\talpha"),
            actualCharacterRange: nil
        )
        let shortNumLocation = rightTableTextView.layoutManager!.location(
            forGlyphAt: shortNumGlyph.location
        )
        XCTAssertGreaterThan(shortNumLocation.x, 10)

        // Selecting across wrapped table cells reconstructs logical cell text without interleaved wrap fragments,
        // and preserves authored trailing spaces inside wrapped inline-code spans.
        let longCell = "Arm (1/2/2 voting + Astra medium agg with `wrapped trailing code  `)"
        let wrappedTableMarkdown = """
        | Arm | Score |
        | :--- | ---: |
        | \(longCell) | 85.4% / 33.2% |
        | 3x Terra 6.1 (xhigh) | 83.3% / 34.3% |
        """
        let wrappedTableHost = NSHostingView(
            rootView: MarkdownText(text: wrappedTableMarkdown)
                .frame(width: 320, alignment: .leading)
        )
        wrappedTableHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        wrappedTableHost.layoutSubtreeIfNeeded()
        let wrappedTableTextView = try XCTUnwrap(findTextViews(in: wrappedTableHost).first)
        let wrappedString = wrappedTableTextView.attributedText.string as NSString
        let bodyStart = wrappedString.range(of: "Arm (1/2/2").location
        XCTAssertNotEqual(bodyStart, NSNotFound)
        wrappedTableTextView.setSelectedRange(
            NSRange(location: bodyStart, length: wrappedString.length - bodyStart)
        )
        XCTAssertEqual(
            wrappedTableTextView.selectedCopiedText(),
            "Arm (1/2/2 voting + Astra medium agg with wrapped trailing code  )\t85.4% / 33.2%\n3x Terra 6.1 (xhigh)\t83.3% / 34.3%"
        )

        // Selecting a wrapped non-first-column cell alone does not synthesize leading or trailing tabs from exhausted or empty neighbor columns.
        for rowSpec in ["| host | primary | \(longCell) |", "| host | | \(longCell) |", "| host | \(longCell) | |"] {
            let thirdColWrappedMarkdown = """
            | Name | Role | Detail |
            | :--- | :--- | :--- |
            \(rowSpec)
            """
            let thirdColHost = NSHostingView(
                rootView: MarkdownText(text: thirdColWrappedMarkdown)
                    .frame(width: 320, alignment: .leading)
            )
            thirdColHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
            thirdColHost.layoutSubtreeIfNeeded()
            let thirdColTextView = try XCTUnwrap(findTextViews(in: thirdColHost).first)
            let thirdColString = thirdColTextView.attributedText.string as NSString
            let detailStart = thirdColString.range(of: "Arm (1/2/2").location
            let detailEnd = NSMaxRange(thirdColString.range(of: "code  )"))
            XCTAssertNotEqual(detailStart, NSNotFound)
            thirdColTextView.setSelectedRange(
                NSRange(location: detailStart, length: detailEnd - detailStart)
            )
            XCTAssertEqual(
                thirdColTextView.selectedCopiedText(),
                "Arm (1/2/2 voting + Astra medium agg with wrapped trailing code  )"
            )
        }

        // Multi-range selections on macOS are preserved across streamed updates and reconstructed on copy.
        let firstDisjoint = tableString.range(of: "3x Alligator/Terra (high)")
        let secondDisjoint = tableString.range(of: "4x Terra 6.1 (high)")
        tableTextView.selectedRanges = [
            NSValue(range: firstDisjoint),
            NSValue(range: secondDisjoint),
        ]
        XCTAssertEqual(
            tableTextView.selectedCopiedText(),
            "3x Alligator/Terra (high)\n4x Terra 6.1 (high)"
        )
        tableHost.rootView = MarkdownText(text: tableMarkdown + "\n| 5x Luna | 90.0% |")
            .frame(width: 320, alignment: .leading)
        tableHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            tableTextView.selectedRanges.map(\.rangeValue),
            [firstDisjoint, secondDisjoint]
        )

        // Selected leading and trailing logical row breaks are preserved during copy.
        let rowWithBreaks = "\n3x Alligator/Terra (high)\t85.4% / 33.2%\n"
        let rowWithBreaksRange = tableString.range(of: rowWithBreaks)
        XCTAssertNotEqual(rowWithBreaksRange.location, NSNotFound)
        tableTextView.setSelectedRange(rowWithBreaksRange)
        XCTAssertEqual(tableTextView.selectedCopiedText(), rowWithBreaks)

        // Selecting from a wrapped continuation line into the next row preserves empty trailing cells
        // (including across an exhausted middle column), and embedded cell tabs are expanded so they
        // do not collide with column separators.
        let wrappedEmptyTrailingMarkdown = """
        | Arm | Role | Score |
        | :--- | :--- | :--- |
        | \(longCell) | short | |
        | next\tpart | role | value |
        """
        let wrappedEmptyHost = NSHostingView(
            rootView: MarkdownText(text: wrappedEmptyTrailingMarkdown)
                .frame(width: 320, alignment: .leading)
        )
        wrappedEmptyHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        wrappedEmptyHost.layoutSubtreeIfNeeded()
        let wrappedEmptyTextView = try XCTUnwrap(findTextViews(in: wrappedEmptyHost).first)
        let wrappedEmptyString = wrappedEmptyTextView.attributedText.string as NSString
        let continuationRange = wrappedEmptyString.range(of: "code  )\t\t\nnext    part\trole\tvalue")
        XCTAssertNotEqual(continuationRange.location, NSNotFound)
        wrappedEmptyTextView.setSelectedRange(continuationRange)
        XCTAssertEqual(
            wrappedEmptyTextView.selectedCopiedText(),
            "code  )\t\t\nnext    part\trole\tvalue"
        )

        func renderedTableHeight(_ detail: String) -> CGFloat {
            let md = """
            | Name | Detail |
            | :--- | ---: |
            | host | \(detail) |
            """
            let view = NSHostingView(
                rootView: MarkdownText(text: md)
                    .frame(width: 300, alignment: .leading)
            )
            return view.fittingSize.height
        }
        let shortHeight = renderedTableHeight("short")
        let wrappedHeight = renderedTableHeight(
            String(repeating: "wrap this table cell ", count: 40)
        )
        let unbrokenHeight = renderedTableHeight(
            String(repeating: "unbroken", count: 100)
        )
        XCTAssertGreaterThan(wrappedHeight, shortHeight + 100)
        XCTAssertGreaterThan(unbrokenHeight, shortHeight + 100)
    }

    // Wide tables with heavily wrapped cells fall back to plain text once cumulative grid slots exceed the budget.
    @MainActor
    func testMarkdownWideTableWithLongCellFallsBackToPlainText() throws {
        let wideCols = 200
        let wideHeaderRow = Array(repeating: "h", count: wideCols).joined(separator: " | ")
        let wideDelimRow = Array(repeating: "---", count: wideCols).joined(separator: " | ")
        let wideProse = String(repeating: "W", count: 896)
        let wideBodyRow = ([wideProse] + Array(repeating: "x", count: wideCols - 1)).joined(separator: " | ")
        let wideMarkdown = "\(wideHeaderRow)\n\(wideDelimRow)\n\(wideBodyRow)"
        XCTAssertTrue(MarkdownParser.isWithinRenderingLimits(wideMarkdown))
        let wideWrappedHost = NSHostingView(
            rootView: MarkdownText(text: wideMarkdown)
                .frame(width: 320, alignment: .leading)
        )
        wideWrappedHost.frame = NSRect(x: 0, y: 0, width: 320, height: 320)
        wideWrappedHost.layoutSubtreeIfNeeded()
        let wideWrappedTextView = try XCTUnwrap(findTextViews(in: wideWrappedHost).first)
        XCTAssertNil(wideWrappedTextView.headerDividerY())
        XCTAssertEqual(
            wideWrappedTextView.attributedText.string,
            Array(repeating: "h", count: wideCols).joined(separator: "\t") + "\n"
                + ([wideProse] + Array(repeating: "x", count: wideCols - 1)).joined(separator: "\t")
        )
    }

    // Dragging across separate MarkdownText messages and segments in a transcript container
    // highlights every spanned text view and copies their combined text in top-to-bottom order.
    @MainActor
    func testMarkdownDragSelectionSpansTranscriptMessagesAndCopiesInOrder() throws {
        let transcriptRoot = VStack(alignment: .leading, spacing: 12) {
            Text("Copilot")
                .font(.caption.weight(.semibold))
            MarkdownText(
                text: "[Ponytail] finished clean (`0` findings). Waiting for `gpt-6.1-sol` and `claude-opus-5.5`."
            )
            Text("Copilot")
                .font(.caption.weight(.semibold))
            MarkdownText(
                text: """
                Opened [sirfergy/copilot-projects-ios#177](https://github.com/sirfergy/copilot-projects-ios/pull/177):
                - **Worktree**: `/Users/obvioussean/Repos/copilot-projects-ios-shared-markdown`
                - **Diff**: 7 files changed

                ```swift
                let status = "green"
                ```

                Background `manage-pr` agent is running to watch cloud CCR + CI (`validate`) and merge when green.
                """
            )
        }
        .frame(width: 360, alignment: .leading)

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let transcriptHost = NSHostingView(rootView: transcriptRoot)
        transcriptHost.sizingOptions = []
        transcriptHost.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        window.contentView = transcriptHost
        transcriptHost.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        transcriptHost.layoutSubtreeIfNeeded()
        while NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
            until: .distantPast,
            inMode: .default,
            dequeue: true
        ) != nil {}

        let peers = MarkdownSelectableTextView.peerSelectableTextViews(in: transcriptHost)
        XCTAssertEqual(
            peers.count, 4,
            "Expected top message prose, bottom message intro/list prose, code block, and trailing prose in visual order"
        )
        let topMessageView = peers[0]
        let bottomIntroView = peers[1]
        let codeBlockView = peers[2]
        let bottomTrailingView = peers[3]

        let topNSString = topMessageView.attributedText.string as NSString
        let trailingNSString = bottomTrailingView.attributedText.string as NSString
        let anchorIndex = NSMaxRange(trailingNSString.range(of: "when green"))
        let targetCharRange = topNSString.range(of: "Waiting for")
        XCTAssertNotEqual(anchorIndex, NSNotFound)
        XCTAssertNotEqual(targetCharRange.location, NSNotFound)

        let targetGlyphs = topMessageView.layoutManager!.glyphRange(
            forCharacterRange: NSRange(location: targetCharRange.location, length: 1),
            actualCharacterRange: nil
        )
        let targetGlyphRect = topMessageView.layoutManager!.boundingRect(
            forGlyphRange: targetGlyphs,
            in: topMessageView.textContainer!
        )
        let targetPoint = NSPoint(x: targetGlyphRect.minX + 1, y: targetGlyphRect.midY)

        func sendMouseGesture(
            on startView: MarkdownSelectableTextView,
            startLocalPoint: NSPoint,
            dragTo endView: MarkdownSelectableTextView? = nil,
            endLocalPoint: NSPoint? = nil,
            releaseOn releaseView: MarkdownSelectableTextView? = nil,
            releaseLocalPoint: NSPoint? = nil,
            clickCount: Int = 1,
            modifiers: NSEvent.ModifierFlags = []
        ) throws {
            while NSApp.nextEvent(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp],
                until: .distantPast,
                inMode: .eventTracking,
                dequeue: true
            ) != nil {}
            let startWindowPoint = startView.convert(startLocalPoint, to: nil)
            let downEvent = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown,
                    location: startWindowPoint,
                    modifierFlags: modifiers,
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: clickCount,
                    pressure: 1.0
                )
            )
            let dragWindowPoint: NSPoint? = if let endView, let endLocalPoint {
                endView.convert(endLocalPoint, to: nil)
            } else {
                nil
            }
            let upWindowPoint = if let releaseView, let releaseLocalPoint {
                releaseView.convert(releaseLocalPoint, to: nil)
            } else if let dragWindowPoint {
                dragWindowPoint
            } else {
                startWindowPoint
            }
            let upEvent = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseUp,
                    location: upWindowPoint,
                    modifierFlags: modifiers,
                    timestamp: 0.02,
                    windowNumber: window.windowNumber,
                    context: nil,
                    eventNumber: 1,
                    clickCount: clickCount,
                    pressure: 0.0
                )
            )
            NSApp.postEvent(upEvent, atStart: true)
            if let dragWindowPoint {
                let dragEvent = try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseDragged,
                        location: dragWindowPoint,
                        modifierFlags: modifiers,
                        timestamp: 0.01,
                        windowNumber: window.windowNumber,
                        context: nil,
                        eventNumber: 1,
                        clickCount: clickCount,
                        pressure: 1.0
                    )
                )
                NSApp.postEvent(dragEvent, atStart: true)
            }
            startView.mouseDown(with: downEvent)
        }

        let anchorLastGlyph = bottomTrailingView.layoutManager!.glyphRange(
            forCharacterRange: NSRange(location: anchorIndex - 1, length: 1),
            actualCharacterRange: nil
        )
        let anchorGlyphRect = bottomTrailingView.layoutManager!.boundingRect(
            forGlyphRange: anchorLastGlyph,
            in: bottomTrailingView.textContainer!
        )
        let startPoint = NSPoint(x: anchorGlyphRect.maxX - 0.5, y: anchorGlyphRect.midY)

        // Drag upward from "when green" in the bottom view into "Waiting for" in the top message view.
        try sendMouseGesture(
            on: bottomTrailingView,
            startLocalPoint: startPoint,
            dragTo: topMessageView,
            endLocalPoint: targetPoint
        )

        XCTAssertEqual(
            topNSString.substring(with: topMessageView.selectedRange()),
            "Waiting for gpt-6.1-sol and claude-opus-5.5."
        )
        XCTAssertEqual(
            bottomIntroView.selectedRange(),
            NSRange(location: 0, length: bottomIntroView.attributedText.length)
        )
        XCTAssertEqual(
            codeBlockView.selectedRange(),
            NSRange(location: 0, length: codeBlockView.attributedText.length)
        )
        XCTAssertEqual(
            trailingNSString.substring(with: bottomTrailingView.selectedRange()),
            "Background manage-pr agent is running to watch cloud CCR + CI (validate) and merge when green"
        )

        let expectedCombinedCopy = [
            "Waiting for gpt-6.1-sol and claude-opus-5.5.",
            bottomIntroView.attributedText.string,
            "let status = \"green\"",
            "Background manage-pr agent is running to watch cloud CCR + CI (validate) and merge when green",
        ].joined(separator: "\n\n")
        XCTAssertEqual(bottomTrailingView.selectedTranscriptCopiedText(), expectedCombinedCopy)
        XCTAssertEqual(topMessageView.selectedTranscriptCopiedText(), expectedCombinedCopy)

        let pasteboard = NSPasteboard.general
        let savedPasteboard = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let savedPasteboard {
                pasteboard.setString(savedPasteboard, forType: .string)
            }
        }
        bottomTrailingView.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), expectedCombinedCopy)

        // Resigning first responder clears the selection and saved anchor across all views in the transcript scope.
        XCTAssertTrue(window.makeFirstResponder(nil))
        for peer in peers {
            XCTAssertEqual(peer.selectedRange(), NSRange(location: 0, length: 0))
        }
        try sendMouseGesture(
            on: topMessageView,
            startLocalPoint: targetPoint,
            modifiers: [.shift]
        )
        XCTAssertEqual(topMessageView.selectedRange(), NSRange(location: targetCharRange.location, length: 0))
        XCTAssertEqual(bottomTrailingView.selectedRange(), NSRange(location: 0, length: 0))

        // Double-clicking inside a code block and Shift-clicking into the top
        // message view preserves the full double-clicked word boundary across the transcript scope.
        let codeNSString = codeBlockView.attributedText.string as NSString
        let codeMidWordAnchor = codeNSString.range(of: "status").location + 2
        XCTAssertNotEqual(codeMidWordAnchor, NSNotFound)
        let codeMidGlyph = codeBlockView.layoutManager!.glyphRange(
            forCharacterRange: NSRange(location: codeMidWordAnchor, length: 1),
            actualCharacterRange: nil
        )
        let codeMidRect = codeBlockView.layoutManager!.boundingRect(
            forGlyphRange: codeMidGlyph,
            in: codeBlockView.textContainer!
        )
        try sendMouseGesture(
            on: codeBlockView,
            startLocalPoint: NSPoint(x: codeMidRect.midX, y: codeMidRect.midY),
            clickCount: 2
        )
        XCTAssertEqual(codeNSString.substring(with: codeBlockView.selectedRange()), "status")
        codeBlockView.selectedRanges = [
            NSValue(range: NSRange(location: 0, length: 10)),
            NSValue(range: NSRange(location: 13, length: 5)),
        ]
        try sendMouseGesture(
            on: topMessageView,
            startLocalPoint: targetPoint,
            modifiers: [.shift]
        )
        XCTAssertEqual(codeBlockView.selectedRanges, [NSValue(range: NSRange(location: 0, length: 10))])
        XCTAssertEqual(
            codeBlockView.selectedTranscriptCopiedText(),
            [
                "Waiting for gpt-6.1-sol and claude-opus-5.5.",
                bottomIntroView.attributedText.string,
                "let status",
            ].joined(separator: "\n\n")
        )

        // When mouse-up arrives at a different location than the last drag event, the release location wins.
        try sendMouseGesture(
            on: bottomTrailingView,
            startLocalPoint: startPoint,
            dragTo: codeBlockView,
            endLocalPoint: NSPoint(x: codeMidRect.midX, y: codeMidRect.midY),
            releaseOn: topMessageView,
            releaseLocalPoint: targetPoint
        )
        XCTAssertEqual(bottomTrailingView.selectedTranscriptCopiedText(), expectedCombinedCopy)

        // Dragging upward from index 0 of the bottom view leaves its local selection at {0, 0},
        // and pressing Left still clears the peer selections.
        try sendMouseGesture(
            on: bottomTrailingView,
            startLocalPoint: NSPoint(x: 0.5, y: 2),
            dragTo: topMessageView,
            endLocalPoint: targetPoint
        )
        XCTAssertEqual(bottomTrailingView.selectedRange(), NSRange(location: 0, length: 0))
        XCTAssertGreaterThan(topMessageView.selectedRange().length, 0)
        bottomTrailingView.doCommand(by: #selector(NSStandardKeyBindingResponding.moveLeft(_:)))
        for peer in peers {
            XCTAssertEqual(peer.selectedRange(), NSRange(location: 0, length: 0))
        }
        codeBlockView.selectAll(nil)
        codeBlockView.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "let status = \"green\"")
    }

    @MainActor
    func testMarkdownOversizedBlocksFallBackWithoutFlatteningNeighbors() throws {
        // A multi-table report with 4 tables (matching the 25 + 60 + 95 + 98 raw-cell /
        // 514 per-cell visual-line shape) renders every heading, divider, table, and fenced code
        // block as formatted Markdown rather than raw text.
        func makeSyntheticTable(rows: Int, cols: Int, lastCellLength: Int) -> String {
            let header = "| " + (1...cols).map { "Col \($0)" }.joined(separator: " | ") + " |"
            let delim = "| " + (["---"] + Array(repeating: "---:", count: cols - 1)).joined(separator: " | ") + " |"
            let phrase = "batch pipeline sync ($14.2k), webhook worker ($8.5k), scheduled rollup ($4.1k), "
            let body = (1...rows).map { r in
                let prefix = (1..<cols).map { c in c == 1 ? "`service-\(r)`" : "**$\(r * 100).00**" }
                let padCount = max(1, lastCellLength - 16)
                let repeated = String(repeating: phrase, count: (padCount / phrase.count) + 2)
                let tail = "`metric_\(r)` " + String(repeated.prefix(padCount))
                return "| " + (prefix + [tail]).joined(separator: " | ") + " |"
            }.joined(separator: "\n")
            return "\(header)\n\(delim)\n\(body)"
        }
        let syntheticReport = """
        Overview paragraph with **bold** summary and `inline_metric`.

        ### 1. Summary Breakdown

        \(makeSyntheticTable(rows: 4, cols: 5, lastCellLength: 60))

        ---

        ### 2. Team Rollup

        \(makeSyntheticTable(rows: 11, cols: 5, lastCellLength: 280))

        ---

        ### 3. Detailed Breakdown

        \(makeSyntheticTable(rows: 18, cols: 5, lastCellLength: 280))

        ---

        ### 4. Totals by Integration

        | Integration (`cleaned_name`) | Full Total (`$200.0k`) | Direct (`$160.0k`) | Self (`$40.0k`) | Partners (`$180`) | Requests | Active Users |
        | --- | ---: | ---: | ---: | ---: | ---: | ---: |
        \((1...13).map { "| `integration-service-\($0)` | **$\(80_000 / $0).00** | $\(70_000 / $0).00 | $\(10_000 / $0).00 | $0.00 | \(100_000 / $0) | \(15 - ($0 % 10)) |" }.joined(separator: "\n"))

        ---

        ### 5. Query Reference

        ```kql
        UsageEvents
        | where Timestamp >= ago(30d)
        | summarize Total = sum(Count) by Integration
        ```
        """
        XCTAssertTrue(
            MarkdownParser.isWithinRenderingLimits(syntheticReport),
            "Per-cell visual line accounting keeps the 4-table report (514 visual cells) within the 1,000-cell limit"
        )
        let reportHost = NSHostingView(
            rootView: MarkdownText(text: syntheticReport)
                .frame(width: 380, alignment: .leading)
        )
        reportHost.frame = NSRect(x: 0, y: 0, width: 380, height: 2_400)
        reportHost.layoutSubtreeIfNeeded()
        let reportTextViews = findTextViews(in: reportHost)
        let renderedTables = reportTextViews.filter { $0.headerDividerY() != nil }
        XCTAssertEqual(renderedTables.count, 4, "All four tables in a multi-table report must render as formatted tables")
        XCTAssertFalse(
            reportTextViews.contains { $0.attributedText.string.contains("### 4. Totals by Integration") },
            "Headings must be formatted rather than raw ### text"
        )
        XCTAssertFalse(
            reportTextViews.contains { $0.attributedText.string == "---" },
            "Standalone thematic breaks must render as dividers rather than literal --- paragraphs"
        )

        // An oversized block (e.g., a 50x26 table, a >3,800-marker paragraph, or a 5th table exceeding
        // the document table budget) falls back only that block to plain text without flattening
        // neighboring headings, bold prose, or earlier tables, and without polluting inlineCache.
        let wideHeader50 = Array(repeating: "h", count: 50).joined(separator: " | ")
        let wideDelim50 = Array(repeating: "---", count: 50).joined(separator: " | ")
        let sparseRows25 = Array(repeating: "cell_a | cell_b", count: 25).joined(separator: "\n")
        let oversizedTable = "\(wideHeader50)\n\(wideDelim50)\n\(sparseRows25)"
        let header1002 = (["**bold_900**"] + Array(repeating: "h", count: 1_001)).joined(separator: " | ")
        let delim1002 = Array(repeating: "---", count: 1_002).joined(separator: " | ")
        let row1002 = Array(repeating: "v", count: 1_002).joined(separator: " | ")
        let parserRejectedTable = "\(header1002)\n\(delim1002)\n\(row1002)"
        let eligibleSmallTable = "| Key | Val |\n| --- | ---: |\n| ok_key | 42 |"
        let oversizedInlinePara = Array(repeating: "**span** ", count: 1_000).joined()
        let mixedMarkdown = """
        # Mixed Report

        \(oversizedTable)

        \(parserRejectedTable)

        \(eligibleSmallTable)

        \(oversizedInlinePara)

        <details open>
        <summary>\(Array(repeating: "*s* ", count: 1_901).joined())</summary>
        Inner **formatted** detail.
        </details>

        Trailing **bold** conclusion.
        """
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(mixedMarkdown))
        MarkdownParser.clearCache()
        let mixedHost = NSHostingView(
            rootView: MarkdownText(text: mixedMarkdown)
                .frame(width: 380, alignment: .leading)
        )
        mixedHost.frame = NSRect(x: 0, y: 0, width: 380, height: 1_200)
        mixedHost.layoutSubtreeIfNeeded()
        XCTAssertFalse(MarkdownParser.inlineCache.contains("cell_a"))
        XCTAssertFalse(MarkdownParser.inlineCache.contains(parserRejectedTable))
        XCTAssertFalse(MarkdownParser.inlineCache.contains(oversizedInlinePara))
        let mixedViews = findTextViews(in: mixedHost)
        XCTAssertGreaterThanOrEqual(mixedViews.count, 5)
        let mixedHeadingView = try XCTUnwrap(mixedViews.first { $0.attributedText.string.contains("Mixed Report") })
        XCTAssertEqual(
            mixedHeadingView.attributedText.attribute(
                MarkdownText.headingLevelAttribute,
                at: 0,
                effectiveRange: nil
            ) as? NSNumber,
            1
        )
        let mixedTableFallback = try XCTUnwrap(mixedViews.first { $0.attributedText.string.contains("cell_a\tcell_b") })
        XCTAssertNil(mixedTableFallback.headerDividerY())
        XCTAssertFalse(mixedTableFallback.attributedText.string.contains("cell_b\t"))
        let parserRejectedView = try XCTUnwrap(mixedViews.first { $0.attributedText.string.contains("**bold_900**") })
        XCTAssertNil(parserRejectedView.headerDividerY())
        let smallTableView = try XCTUnwrap(mixedViews.first { $0.attributedText.string.contains("ok_key") })
        XCTAssertNotNil(smallTableView.headerDividerY())
        let mixedTrailingView = try XCTUnwrap(mixedViews.first { $0.attributedText.string.contains("Trailing bold conclusion.") })
        let trailingBoldLoc = (mixedTrailingView.attributedText.string as NSString).range(of: "bold").location
        let trailingBoldFont = try XCTUnwrap(
            mixedTrailingView.attributedText.attribute(.font, at: trailingBoldLoc, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(trailingBoldFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // Growing an earlier table crosses the document budget without crossing its per-table limit.
    // Updating the same host must switch the unchanged trailing table to plain text and back.
    @MainActor
    func testMarkdownTableCellBudgetSwitchesTrailingTableToPlainTextAndBack() throws {
        // Every row counts 30 cells against the budget, and a body row counts one more because its
        // key is long enough to wrap. Without the wrapped keys all five large tables would fit.
        // Only the key has text to lay out.
        func sparseTable(rows: Int) -> String {
            let emptyCells = String(repeating: "  |", count: 29)
            let rowLines = (1...rows).map { "| row_\($0)_with_a_key_longer_than_one_table_line |\(emptyCells)" }
            return "| Key |\(emptyCells)\n|\(String(repeating: " --- |", count: 30))\n"
                + rowLines.joined(separator: "\n")
        }
        let table805 = sparseTable(rows: 25)
        let smallerFirstTable = sparseTable(rows: 1)
        let withinBudgetMarkdown = (1...5).map {
            "### Section \($0)\n\n\($0 == 1 ? smallerFirstTable : table805)"
        }.joined(separator: "\n\n")
        XCTAssertFalse(
            MarkdownParser.isWithinRenderingLimits(withinBudgetMarkdown),
            "Notification limits stay at 1,000 table cells while MarkdownText renders up to 4,000 document table cells"
        )
        let fiveTablesMarkdown = (1...5).map { "### Section \($0)\n\n\(table805)" }.joined(separator: "\n\n")
        let fiveTablesHost = NSHostingView(
            rootView: MarkdownText(text: withinBudgetMarkdown)
                .frame(width: 380, alignment: .leading)
        )
        fiveTablesHost.frame = NSRect(x: 0, y: 0, width: 380, height: 3_000)
        fiveTablesHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(findTextViews(in: fiveTablesHost).filter { $0.headerDividerY() != nil }.count, 5)

        fiveTablesHost.rootView = MarkdownText(text: fiveTablesMarkdown)
            .frame(width: 380, alignment: .leading)
        fiveTablesHost.layoutSubtreeIfNeeded()
        let fiveTablesViews = findTextViews(in: fiveTablesHost)
        XCTAssertEqual(fiveTablesViews.filter { $0.headerDividerY() != nil }.count, 4)

        fiveTablesHost.rootView = MarkdownText(text: withinBudgetMarkdown)
            .frame(width: 380, alignment: .leading)
        fiveTablesHost.layoutSubtreeIfNeeded()
        XCTAssertEqual(findTextViews(in: fiveTablesHost).filter { $0.headerDividerY() != nil }.count, 5)
    }

    @MainActor
    func testMarkdownInlineMarkerBudgetLeavesLaterBlocksUnformatted() throws {
        let inlineBlocks5 = (1...5).map { idx -> String in
            let p = "para_\(idx) " + Array(repeating: "**b** ", count: 850).joined()
            return idx == 2 ? "<details open>\n<summary>Detail</summary>\n\n\(p)\n</details>" : p
        }
        let fifthInlineBlock = "para_5 " + Array(repeating: "**b** ", count: 850).joined()
        MarkdownParser.clearCache()
        let inlineBudgetHost = NSHostingView(
            rootView: MarkdownText(text: inlineBlocks5.joined(separator: "\n\n"))
                .frame(width: 380, alignment: .leading)
        )
        inlineBudgetHost.frame = NSRect(x: 0, y: 0, width: 380, height: 1_800)
        inlineBudgetHost.layoutSubtreeIfNeeded()
        XCTAssertFalse(MarkdownParser.inlineCache.contains(fifthInlineBlock))
        let inlineBudgetViews = findTextViews(in: inlineBudgetHost)
        XCTAssertTrue(inlineBudgetViews.contains { $0.attributedText.string.contains("para_4 b ") })
        XCTAssertTrue(inlineBudgetViews.contains { $0.attributedText.string.contains("para_5 **b**") })
    }

    @MainActor
    func testMarkdownTextViewCountStaysWithinSegmentAndNestingLimits() throws {
        let codeBlocks60 = (1...60).map { "```\ncode_\($0)\n```" }.joined(separator: "\n")
        let manyDetailsMarkdown = (1...6).map {
            "<details open>\n<summary>Group \($0)</summary>\n\(codeBlocks60)\n</details>"
        }.joined(separator: "\n")
        let manyDetailsHost = NSHostingView(
            rootView: MarkdownText(text: manyDetailsMarkdown)
                .frame(width: 380, alignment: .leading)
        )
        manyDetailsHost.frame = NSRect(x: 0, y: 0, width: 380, height: 1_200)
        manyDetailsHost.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(
            findTextViews(in: manyDetailsHost).count,
            256
        )

        let code254DetailsAndTail = ((1...254).map { "```\ncode_\($0)\n```" }
            + ["<details open>\n<summary>D</summary>\nInner detail\n</details>", "# Outer tail"])
            .joined(separator: "\n\n")
        let detailsTailHost = NSHostingView(
            rootView: MarkdownText(text: code254DetailsAndTail)
                .frame(width: 380, alignment: .leading)
        )
        detailsTailHost.frame = NSRect(x: 0, y: 0, width: 380, height: 4_000)
        detailsTailHost.layoutSubtreeIfNeeded()
        let detailsTailViews = findTextViews(in: detailsTailHost)
        XCTAssertEqual(detailsTailViews.count, 256)
        XCTAssertTrue(detailsTailViews.contains { $0.attributedText.string == "D\nInner detail" })
        let outerTailView = try XCTUnwrap(detailsTailViews.last)
        XCTAssertEqual(
            outerTailView.attributedText.attribute(
                MarkdownText.headingLevelAttribute,
                at: 0,
                effectiveRange: nil
            ) as? NSNumber,
            1
        )

        let code255AndProse = ((1...255).map { "```\ncode_\($0)\n```" } + ["# Tail Heading", "Body **bold_tail**"]).joined(separator: "\n\n")
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(code255AndProse))
        let boundaryHost = NSHostingView(
            rootView: MarkdownText(text: code255AndProse)
                .frame(width: 380, alignment: .leading)
        )
        boundaryHost.frame = NSRect(x: 0, y: 0, width: 380, height: 4_000)
        boundaryHost.layoutSubtreeIfNeeded()
        let tailProseView = try XCTUnwrap(findTextViews(in: boundaryHost).last)
        XCTAssertEqual(
            tailProseView.attributedText.attribute(
                MarkdownText.headingLevelAttribute,
                at: 0,
                effectiveRange: nil
            ) as? NSNumber,
            1
        )
        let oversizedInlinePara = Array(repeating: "**span** ", count: 1_000).joined()
        let code255BufferedAndOversized = ((1...255).map { "```\ncode_\($0)\n```" }
            + ["# Tail Heading", oversizedInlinePara, "# Final Heading"]).joined(separator: "\n\n")
        boundaryHost.rootView = MarkdownText(text: code255BufferedAndOversized)
            .frame(width: 380, alignment: .leading)
        boundaryHost.layoutSubtreeIfNeeded()
        let bufferedViews = findTextViews(in: boundaryHost)
        XCTAssertEqual(bufferedViews.count, 256)
        XCTAssertTrue(bufferedViews.last?.attributedText.string.contains("Tail Heading") == true)
        XCTAssertTrue(bufferedViews.last?.attributedText.string.contains("Final Heading") == true)

        let fiveDeepOpen = (1...5).map { "<details open>\n<summary>L\($0)</summary>" }.joined(separator: "\n")
            + "\nInner **five**\n"
            + Array(repeating: "</details>", count: 5).joined(separator: "\n")
            + "\n\nTrailing **after** five."
        let fiveDeepHost = NSHostingView(
            rootView: MarkdownText(text: fiveDeepOpen)
                .frame(width: 380, alignment: .leading)
        )
        fiveDeepHost.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        fiveDeepHost.layoutSubtreeIfNeeded()
        let fiveDeepViews = findTextViews(in: fiveDeepHost)
        let fifthLevelView = try XCTUnwrap(fiveDeepViews.first { $0.attributedText.string.contains("L5\nInner **five**") })
        XCTAssertNil(fifthLevelView.headerDividerY())
        XCTAssertTrue(fiveDeepViews.contains { $0.attributedText.string.contains("Trailing after five.") })
    }

    @MainActor
    func testMarkdownDeepLinkClickRoutesToTheDefaultHandler() throws {
        let deepLinkHost = NSHostingView(
            rootView: MarkdownText(
                text: "[Feature](copilot-projects://focus?project=proj-9&session=sess-9)"
            )
            .frame(width: 320, alignment: .leading)
        )
        deepLinkHost.frame = NSRect(x: 0, y: 0, width: 320, height: 120)
        deepLinkHost.layoutSubtreeIfNeeded()
        let deepLinkTextView = try XCTUnwrap(findTextViews(in: deepLinkHost).first)
        let linkAttr = try XCTUnwrap(
            deepLinkTextView.attributedText.attribute(.link, at: 0, effectiveRange: nil)
        )
        var capturedDeepLinks: [AppDeepLink] = []
        let previousDefaultHandler = MarkdownSelectableTextView.defaultDeepLinkHandler
        MarkdownSelectableTextView.defaultDeepLinkHandler = { deepLink in
            capturedDeepLinks.append(deepLink)
            return true
        }
        defer { MarkdownSelectableTextView.defaultDeepLinkHandler = previousDefaultHandler }
        deepLinkTextView.clicked(onLink: linkAttr, at: 0)
        XCTAssertEqual(
            capturedDeepLinks,
            [AppDeepLink(projectId: "proj-9", sessionId: "sess-9")]
        )
        XCTAssertFalse(deepLinkTextView.routeDeepLinkIfPossible("https://github.com"))
    }

    // A 6-column table with a few dozen rows, 5 short cells (including bold), and one 300-600 char
    // last column with 10-20 inline code spans per cell stays within rendering limits, and its
    // shape renders as a formatted table at drawer and full widths, while a truly huge table
    // still falls back.
    @MainActor
    func testMarkdownLongLastColumnTableRendersUntilItExceedsTheCellLimit() throws {
        func makeLongLastColumnTable(rows: Int, codeSpansPerRow: Int = 20) -> String {
            let header = "| Member | Total | Direct | Shared | Requests | Service Breakdown |"
            let delim = "| :--- | ---: | ---: | ---: | ---: | :--- |"
            let body = (1...rows).map { r in
                let spans = (1...codeSpansPerRow).map { s in
                    "`svc_route_api_\(s)` ($\(r * 10 + s))"
                }.joined(separator: ", ")
                return "| Member \(r) | **$\(r * 125).00** | $\(r * 95).00 | $\(r * 30).00 | \(r * 14) | \(spans) |"
            }.joined(separator: "\n")
            return "\(header)\n\(delim)\n\(body)"
        }

        let breakdownTable36 = makeLongLastColumnTable(rows: 36, codeSpansPerRow: 20)
        if case .table(let parsedBreakdown)? = MarkdownParser.blocks(from: breakdownTable36).first {
            XCTAssertEqual(parsedBreakdown.header.count, 6)
            XCTAssertEqual(parsedBreakdown.rows.count, 36)
            XCTAssertGreaterThanOrEqual(parsedBreakdown.rows[0][5].count, 500)
        } else {
            XCTFail("Expected 36-row breakdown table to parse as a MarkdownTable block")
        }
        XCTAssertTrue(MarkdownParser.isWithinRenderingLimits(breakdownTable36))
        // The 36-row limit is checked on the parser above, and two rows of the same shape are
        // rendered. On the macOS 26 CI runner, measuring a table's width took about 7 ms per
        // line of the table, which was 7.5 s for the 36 rows.
        let renderedRows = makeLongLastColumnTable(rows: 2)
        for width: CGFloat in [380, 960] {
            let breakdownHost = NSHostingView(
                rootView: MarkdownText(text: "# Usage\n\n\(renderedRows)\n\nTrailing **summary**.")
                    .frame(width: width, alignment: .leading)
            )
            breakdownHost.frame = NSRect(x: 0, y: 0, width: width, height: 4_000)
            breakdownHost.layoutSubtreeIfNeeded()
            let breakdownViews = findTextViews(in: breakdownHost)
            let renderedBreakdown = try XCTUnwrap(breakdownViews.first { $0.headerDividerY() != nil })
            XCTAssertFalse(renderedBreakdown.attributedText.string.contains("`svc_route_api_1`"))
            XCTAssertFalse(renderedBreakdown.attributedText.string.contains("**$125.00**"))
        }

        let hugeBreakdownTable = makeLongLastColumnTable(rows: 50, codeSpansPerRow: 20)
        XCTAssertFalse(MarkdownParser.isWithinRenderingLimits(hugeBreakdownTable))
        let hugeHost = NSHostingView(
            rootView: MarkdownText(text: "# Header\n\n\(hugeBreakdownTable)\n\nTrailing **ok**.")
                .frame(width: 380, alignment: .leading)
        )
        hugeHost.frame = NSRect(x: 0, y: 0, width: 380, height: 4_000)
        hugeHost.layoutSubtreeIfNeeded()
        let hugeViews = findTextViews(in: hugeHost)
        XCTAssertTrue(hugeViews.allSatisfy { $0.headerDividerY() == nil })
        let hugeFallbackView = try XCTUnwrap(hugeViews.first { $0.attributedText.string.contains("Member 1\t**$125.00**") })
        XCTAssertNil(hugeFallbackView.headerDividerY())
    }

    // MARK: - Remote web terminal image rendering

    func testCLIParsesStatusNotificationFlagIntoControlRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: ControlRequest?
        let server = ControlServer(socketPath: socketPath) { request in
            received = request
            return .success()
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath

        XCTAssertEqual(CLIMain.run([
            "set-status", "waiting",
            "--notification", "permission",
            "--session", "session-1",
            "--copilot-session", "copilot-session-1",
        ], environment: environment), 0)
        XCTAssertEqual(received?.status, "waiting")
        XCTAssertEqual(received?.notification, .permission)
        XCTAssertEqual(received?.sessionId, "session-1")
        XCTAssertEqual(received?.copilotSessionId, "copilot-session-1")
    }

    func testCLINewCopilotSessionSendsPromptFileAndMapsResponseCodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: [ControlRequest] = []
        var nextResponse = ControlResponse.success("session-1", code: "created")
        let server = ControlServer(socketPath: socketPath) { request in
            received.append(request)
            return nextResponse
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath
        environment["COPILOT_PROJECTS_SESSION"] = "calling-session"
        let promptFile = root.appendingPathComponent("prompt.md")
        let prompt = "Review https://github.com/o/r/pull/1\n-- literal --flag text\n"
        try Data(prompt.utf8).write(to: promptFile)
        let requestId = UUID()
        let valid = [
            "new-copilot-session", "--project", "p1", "--request-id", requestId.uuidString,
            "--prompt-file", promptFile.path, "--title", "Review o/r#1",
        ]

        XCTAssertEqual(CLIMain.run(valid, environment: environment), 0)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.last?.command, "new-copilot-session")
        XCTAssertEqual(received.last?.projectId, "p1")
        XCTAssertEqual(received.last?.requestId, requestId.uuidString)
        XCTAssertEqual(received.last?.prompt, prompt)
        XCTAssertEqual(received.last?.title, "Review o/r#1")
        XCTAssertNil(received.last?.sessionId)
        XCTAssertEqual(received.last?.parentSessionId, "calling-session")

        XCTAssertEqual(
            CLIMain.run(valid + ["--parent-session", "  explicit-parent  "], environment: environment),
            0
        )
        XCTAssertEqual(received.last?.parentSessionId, "explicit-parent")

        XCTAssertEqual(
            CLIMain.run(valid + ["--parent-session", "   "], environment: environment),
            0
        )
        XCTAssertNil(received.last?.parentSessionId)

        XCTAssertEqual(
            CLIMain.run(valid + ["--no-parent"], environment: environment),
            0
        )
        XCTAssertNil(received.last?.parentSessionId)

        let expectedExits: [(String?, Int32)] = [
            ("bad-request", 2), ("conflict", 3), ("gone", 4), ("unavailable", 5),
            ("persistence-unavailable", 5), ("unknown-project", 6), ("invalid", 7), (nil, 1),
        ]
        for (code, status) in expectedExits {
            nextResponse = .failure("failed", code: code)
            XCTAssertEqual(CLIMain.run(valid, environment: environment), status, code ?? "no code")
        }
        nextResponse = .success("session-1", code: "existing")
        XCTAssertEqual(CLIMain.run(valid, environment: environment), 0)
        let sent = received.count

        let oversized = root.appendingPathComponent("oversized.md")
        try Data(repeating: 0x78, count: CLIMain.maximumPromptBytes + 1).write(to: oversized)
        let notUTF8 = root.appendingPathComponent("latin1.md")
        try Data([0xff, 0xfe, 0x41]).write(to: notUTF8)
        let rejected: [[String]] = [
            valid + ["--help"],
            valid + ["--cwd", "/tmp"],
            valid + ["positional"],
            valid + ["--no-parent", "--parent-session", "p"],
            valid + ["--no-parent", "unexpected"],
            valid.filter { $0 != "--title" && $0 != "Review o/r#1" } + ["--prompt", "inline"],
            ["new-copilot-session", "--project", "p1", "--prompt-file", promptFile.path],
            ["new-copilot-session", "--project", "p1", "--request-id", "nope",
             "--prompt-file", promptFile.path],
            ["new-copilot-session", "--request-id", requestId.uuidString,
             "--prompt-file", promptFile.path],
            ["new-copilot-session", "--project", "p1", "--request-id", requestId.uuidString],
            ["new-copilot-session", "--project", "p1", "--request-id", requestId.uuidString,
             "--prompt-file", root.appendingPathComponent("missing.md").path],
            ["new-copilot-session", "--project", "p1", "--request-id", requestId.uuidString,
             "--prompt-file", oversized.path],
            ["new-copilot-session", "--project", "p1", "--request-id", requestId.uuidString,
             "--prompt-file", notUTF8.path],
        ]
        for args in rejected {
            XCTAssertEqual(CLIMain.run(args, environment: environment), 2, args.joined(separator: " "))
        }
        XCTAssertEqual(received.count, sent)
    }

    func testCLICloseSessionRequiresExplicitTargetAndMapsResponseCodes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let socketPath = root.appendingPathComponent("control.sock").path
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var received: [ControlRequest] = []
        var nextResponse = ControlResponse.success(code: "closed")
        let server = ControlServer(socketPath: socketPath) { request in
            received.append(request)
            return nextResponse
        }
        XCTAssertTrue(server.start())
        defer { server.stop() }

        var environment = ProcessInfo.processInfo.environment
        environment["COPILOT_PROJECTS_SOCKET"] = socketPath
        environment["COPILOT_PROJECTS_SESSION"] = "calling-session"
        environment["COPILOT_PROJECTS_PROJECT"] = "calling-project"
        XCTAssertTrue(CLIMain.isCommand("close-session"))

        let valid = ["close-session", "--session", "s1", "--project", "p1"]
        XCTAssertEqual(CLIMain.run(valid, environment: environment), 0)
        XCTAssertEqual(received.last?.command, "close-session")
        XCTAssertEqual(received.last?.sessionId, "s1")
        XCTAssertEqual(received.last?.projectId, "p1")

        XCTAssertEqual(CLIMain.run(["close-session", "--session", "s2"], environment: environment), 0)
        XCTAssertEqual(received.last?.sessionId, "s2")
        XCTAssertNil(received.last?.projectId)

        let expectedExits: [(String?, Int32)] = [
            ("bad-request", 2), ("conflict", 3), ("gone", 4), ("unavailable", 5), ("busy", 8), (nil, 1),
        ]
        for (code, status) in expectedExits {
            nextResponse = .failure("failed", code: code)
            XCTAssertEqual(CLIMain.run(valid, environment: environment), status, code ?? "no code")
        }
        for command in ["restart-session", "reload-session-mcp"] {
            XCTAssertTrue(CLIMain.isCommand(command))
            nextResponse = .success(code: "requested")
            XCTAssertEqual(CLIMain.run([command, "--session", "s3"], environment: environment), 0)
            XCTAssertEqual(received.last?.command, command)
            XCTAssertEqual(received.last?.sessionId, "s3")
            nextResponse = .failure("failed", code: "busy")
            XCTAssertEqual(CLIMain.run([command, "--session", "s3"], environment: environment), 8)
        }
        let sent = received.count

        let rejected: [[String]] = [
            ["close-session"],
            ["close-session", "--project", "p1"],
            ["close-session", "--session"],
            ["close-session", "--session", "s1", "--project"],
            ["close-session", "--session", "s1", "--force"],
            ["close-session", "s1"],
            ["restart-session"],
            ["reload-session-mcp"],
            ["reload-session-mcp", "s3"],
            valid + ["--all"],
            valid + ["positional"],
        ]
        for args in rejected {
            XCTAssertEqual(CLIMain.run(args, environment: environment), 2, args.joined(separator: " "))
        }
        XCTAssertEqual(received.count, sent, "an implicit or malformed target is never sent")
    }

    func testControlServerSurvivesClientDisconnectBeforeResponse() throws {
        let socketPath = "/tmp/cp-\(UUID().uuidString.prefix(8)).sock"
        let server = ControlServer(socketPath: socketPath) { request in
            if request.command == "slow" { usleep(100_000) }
            return .success(request.command)
        }
        XCTAssertTrue(server.start())
        defer {
            server.stop()
            try? FileManager.default.removeItem(atPath: socketPath)
        }

        let fd = try connectUnixSocket(path: socketPath)
        let request = ControlRequest(command: "slow")
        let payload = try Wire.encodeLine(request)
        _ = payload.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress, $0.count)
        }
        close(fd)

        Thread.sleep(forTimeInterval: 0.5)
        let response = try ControlClient(socketPath: socketPath)
            .send(ControlRequest(command: "ping"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "ping")
    }

    @MainActor
    func testControlServerPingFastPathSkipsMainActorWhenMainQueueIsHeld() throws {
        XCTAssertLessThan(
            ControlServer.defaultMainActorTimeout,
            ControlClient().timeout,
            "server main-actor timeout must stay below the default client socket timeout"
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/cp-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let lock = NSLock()
        var enqueuedMainWork: [@Sendable () -> Void] = []
        let model = AppModel(
            stateRepository: StateRepository(
                path: root.appendingPathComponent("state.json")
            ),
            agentActivityDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            resumeMarkerDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            controlMainQueueTimeout: 0.05,
            controlMainQueue: { work in
                lock.lock()
                enqueuedMainWork.append(work)
                lock.unlock()
            }
        )
        XCTAssertTrue(model.startServer(socketPath: socketPath))
        defer { model.stopServer() }

        let response = try ControlClient(socketPath: socketPath)
            .send(ControlRequest(command: "ping"))
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.text, "pong")
        lock.lock()
        let scheduledCount = enqueuedMainWork.count
        lock.unlock()
        XCTAssertEqual(scheduledCount, 0, "ping must not hop to the main queue")
    }

    @MainActor
    func testControlServerBoundedMainQueueTimeoutReturnsBusyAndCancelsTimedOutWork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/cp-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let lock = NSLock()
        var holdMainQueue = true
        var heldBlocks: [@Sendable () -> Void] = []
        let model = AppModel(
            stateRepository: StateRepository(
                path: root.appendingPathComponent("state.json")
            ),
            agentActivityDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            resumeMarkerDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            controlMainQueueTimeout: 0.05,
            controlMainQueue: { work in
                lock.lock()
                let shouldHold = holdMainQueue
                if shouldHold {
                    heldBlocks.append(work)
                }
                lock.unlock()
                if !shouldHold {
                    DispatchQueue.main.async(execute: work)
                }
            }
        )
        let baselineProjectCount = model.projects.count
        XCTAssertTrue(model.startServer(socketPath: socketPath))
        defer { model.stopServer() }

        var newProjectReq = ControlRequest(command: "new-project")
        newProjectReq.name = "stalled-project"
        newProjectReq.cwd = root.path
        let newProjectResponse = try ControlClient(socketPath: socketPath).send(newProjectReq)
        XCTAssertFalse(newProjectResponse.ok)
        XCTAssertEqual(newProjectResponse.code, "busy")
        XCTAssertEqual(newProjectResponse.error, "the app is busy")

        let listSessionsResponse = try ControlClient(socketPath: socketPath)
            .send(ControlRequest(command: "list-sessions"))
        XCTAssertFalse(listSessionsResponse.ok)
        XCTAssertEqual(listSessionsResponse.code, "busy")
        XCTAssertEqual(listSessionsResponse.error, "the app is busy")

        var screenshotReq = ControlRequest(command: "screenshot")
        screenshotReq.path = root.appendingPathComponent("shot.png").path
        let screenshotResponse = try ControlClient(socketPath: socketPath).send(screenshotReq)
        XCTAssertFalse(screenshotResponse.ok)
        XCTAssertEqual(screenshotResponse.code, "busy")
        XCTAssertEqual(screenshotResponse.error, "the app is busy")

        // The control server serial queue must remain responsive for subsequent requests.
        let pingResponse = try ControlClient(socketPath: socketPath)
            .send(ControlRequest(command: "ping"))
        XCTAssertTrue(pingResponse.ok)
        XCTAssertEqual(pingResponse.text, "pong")

        // Late execution after the main queue unblocks must be a no-op for timed-out requests.
        lock.lock()
        let blocksToDrain = heldBlocks
        heldBlocks.removeAll()
        lock.unlock()
        XCTAssertEqual(blocksToDrain.count, 3)
        for block in blocksToDrain {
            block()
        }
        XCTAssertEqual(model.projects.count, baselineProjectCount)
        XCTAssertFalse(model.projects.contains { $0.name == "stalled-project" })

        // Deterministic state-machine checks: a block that misses the deadline before
        // claiming never starts, while a block that claims before the deadline keeps
        // running and delivers its completed value instead of reporting a false "busy".
        let expiredBox = MainActorDispatchBox<String>(deadline: .now() - .seconds(1))
        XCTAssertFalse(expiredBox.beginExecution())
        if case .timedOutBeforeStart = expiredBox.resolveAfterDeadlineWait() {
        } else {
            XCTFail("expected timedOutBeforeStart when deadline passed before beginExecution")
        }

        let inFlightBox = MainActorDispatchBox<String>(deadline: .now() + .seconds(60))
        XCTAssertTrue(inFlightBox.beginExecution())
        if case .running = inFlightBox.resolveAfterDeadlineWait() {
        } else {
            XCTFail("expected running when beginExecution claimed before the deadline")
        }
        inFlightBox.complete("completed-after-start")
        XCTAssertEqual(inFlightBox.completedValue(), "completed-after-start")
    }

    @MainActor
    func testControlServerScreenshotValidatesOffMainAndWritesPNGFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = "/tmp/cp-\(UUID().uuidString.prefix(8)).sock"
        defer { try? FileManager.default.removeItem(atPath: socketPath) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 4,
            height: 3,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let testImage = context.makeImage() else {
            XCTFail("failed to construct test CGImage")
            return
        }

        let lock = NSLock()
        var schedulerCalls = 0
        var preparerCalls = 0
        var preparerCalledOnMainThread: [Bool] = []
        var capturedRequests: [ScreenshotCaptureRequest] = []
        var capturerCalledOnMainThread: [Bool] = []
        let expectedRequest = ScreenshotCaptureRequest(windowID: 77, width: 4, height: 3)

        let model = AppModel(
            stateRepository: StateRepository(
                path: root.appendingPathComponent("state.json")
            ),
            agentActivityDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            resumeMarkerDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            controlMainQueueTimeout: 1,
            controlMainQueue: { work in
                lock.lock()
                schedulerCalls += 1
                lock.unlock()
                DispatchQueue.main.async(execute: work)
            },
            screenshotPreparer: {
                lock.lock()
                preparerCalls += 1
                preparerCalledOnMainThread.append(Thread.isMainThread)
                lock.unlock()
                return .ready(expectedRequest)
            },
            screenshotImageCapturer: { request in
                lock.lock()
                capturedRequests.append(request)
                capturerCalledOnMainThread.append(Thread.isMainThread)
                lock.unlock()
                return .success(testImage)
            }
        )
        XCTAssertTrue(model.startServer(socketPath: socketPath))
        defer { model.stopServer() }

        // 1. A non-regular file path (directory) fails before hopping to the main queue.
        let directoryPath = root.path
        let directoryResponse = try await Task.detached {
            var directoryReq = ControlRequest(command: "screenshot")
            directoryReq.path = directoryPath
            return try ControlClient(socketPath: socketPath).send(directoryReq)
        }.value
        XCTAssertFalse(directoryResponse.ok)
        XCTAssertEqual(
            directoryResponse.error,
            "refusing to write screenshot to a non-regular file"
        )
        lock.lock()
        XCTAssertEqual(schedulerCalls, 0)
        XCTAssertEqual(preparerCalls, 0)
        XCTAssertTrue(capturedRequests.isEmpty)
        lock.unlock()

        // 2. A valid nested path creates intermediate directories and writes a PNG off-main.
        let nestedOutput = root
            .appendingPathComponent("nested/screenshots/window.png")
        let nestedOutputPath = nestedOutput.path
        let validResponse = try await Task.detached {
            var validReq = ControlRequest(command: "screenshot")
            validReq.path = nestedOutputPath
            return try ControlClient(socketPath: socketPath).send(validReq)
        }.value
        XCTAssertTrue(validResponse.ok, validResponse.error ?? "unexpected failure")
        XCTAssertEqual(validResponse.text, nestedOutput.path)

        lock.lock()
        XCTAssertEqual(schedulerCalls, 1)
        XCTAssertEqual(preparerCalls, 1)
        XCTAssertEqual(preparerCalledOnMainThread, [true])
        XCTAssertEqual(capturedRequests, [expectedRequest])
        XCTAssertEqual(capturerCalledOnMainThread, [false])
        lock.unlock()

        let pngData = try Data(contentsOf: nestedOutput)
        XCTAssertTrue(pngData.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        XCTAssertEqual(rep.pixelsWide, 4)
        XCTAssertEqual(rep.pixelsHigh, 3)
    }

    private func runHook(
        hookURL: URL,
        action: String,
        payload: String,
        tabId: String,
        root: URL,
        bin: URL,
        capture: URL
    ) throws {
        let resolverDirectory = root.appendingPathComponent(
            ".local/bin",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: resolverDirectory,
            withIntermediateDirectories: true
        )
        let resolver = resolverDirectory.appendingPathComponent("copilot-projects")
        if !FileManager.default.fileExists(atPath: resolver.path) {
            try """
            #!/bin/sh
            [ "$1" = "resolve-session" ] || exit 1
            printf '%s\n' "$COPILOT_PROJECTS_SESSION"
            """.write(to: resolver, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: resolver.path
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookURL.path, action]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = root.path
        environment["COPILOT_PROJECTS_SESSION"] = tabId
        environment["COPILOT_PROJECTS_SOCKET"] = root.appendingPathComponent("control.sock").path
        environment["CAPTURE_FILE"] = capture.path
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func cliCallLines(in capture: URL) throws -> [String] {
        try String(contentsOf: capture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func hookStatusRecord(root: URL, tabId: String) throws -> SessionStatusRecord {
        try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: root
                .appendingPathComponent("sessions/\(tabId).status-record.json"))
        )
    }

    private func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() {
                    destination[index] = CChar(bitPattern: byte)
                }
                destination[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .ECONNREFUSED)
        }
        return fd
    }

    // MARK: - Remote terminal image protocol

    func testRemoteTerminalScreenDecodesOldJSONMissingImages() throws {
        let oldJSON = """
        {
            "sessionId": "session",
            "cols": 80,
            "rows": 24,
            "scrollMode": "terminal",
            "historyStartLine": 0,
            "firstLine": 0,
            "liveTopLine": 0,
            "reset": true,
            "lines": ["a", "b"]
        }
        """
        let decoded = try JSONDecoder().decode(
            RemoteTerminalScreen.self,
            from: Data(oldJSON.utf8)
        )
        XCTAssertNil(decoded.images)
        XCTAssertEqual(decoded.lines, ["a", "b"])
    }

    func testRemoteTerminalScreenEncodesAndDecodesImages() throws {
        let screen = RemoteTerminalScreen(
            sessionId: "session",
            cols: 10,
            rows: 5,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: ["a"],
            images: [RemoteTerminalImagePlacement(
                imageId: 7,
                contentVersion: 3,
                line: 0,
                column: 1,
                rows: 2,
                columns: 2
            )]
        )
        let data = try JSONEncoder().encode(screen)
        let decoded = try JSONDecoder().decode(RemoteTerminalScreen.self, from: data)
        XCTAssertEqual(decoded, screen)
        XCTAssertEqual(decoded.images?.first?.contentVersionText, "3")
    }

    func testRemoteTerminalImagePlacementDecodesOlderNumericOnlyJSON() throws {
        let json = """
        {
          "imageId": 7,
          "contentVersion": 3,
          "line": 0,
          "column": 1,
          "rows": 2,
          "columns": 2
        }
        """
        let decoded = try JSONDecoder().decode(
            RemoteTerminalImagePlacement.self,
            from: Data(json.utf8)
        )
        XCTAssertEqual(decoded.contentVersion, 3)
        XCTAssertNil(decoded.contentVersionText)
    }

    // MARK: - Remote Kitty placeholder decode + sanitize (pure)

    func testRemoteKittyPlaceholderDecodeImageIdValidatesInputs() {
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        XCTAssertEqual(
            RemoteKittyPlaceholderCell.decodeImageId(
                character: placeholder,
                foreground: (red: 66, green: 172, blue: 138)
            ),
            0x42AC8A
        )
        XCTAssertEqual(
            RemoteKittyPlaceholderCell.decodeImageId(
                character: placeholder,
                foreground: (red: 255, green: 255, blue: 255)
            ),
            0xFFFFFF
        )
        // Not a placeholder grapheme.
        XCTAssertNil(RemoteKittyPlaceholderCell.decodeImageId(
            character: "A",
            foreground: (red: 66, green: 172, blue: 138)
        ))
        // No truecolor foreground at all.
        XCTAssertNil(RemoteKittyPlaceholderCell.decodeImageId(
            character: placeholder,
            foreground: nil
        ))
        // Decoded id 0 is out of the 1...0xFFFFFF range our capture assigns.
        XCTAssertNil(RemoteKittyPlaceholderCell.decodeImageId(
            character: placeholder,
            foreground: (red: 0, green: 0, blue: 0)
        ))
        XCTAssertEqual(
            RemoteKittyPlaceholderCell.decodePlacementId(
                underline: (red: 17, green: 34, blue: 51)
            ),
            0x112233
        )
    }

    func testRemoteKittyGraphicsSanitizeLinePreservesLengthAndReplacesPlaceholders() {
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let line = "a\(placeholder)\(placeholder)b"
        let sanitized = RemoteKittyGraphics.sanitizeLine(line)
        XCTAssertEqual(sanitized, "a  b")
        XCTAssertEqual(sanitized.count, line.count)
        XCTAssertEqual(RemoteKittyGraphics.sanitizeLine("plain text"), "plain text")
    }

    // MARK: - Remote Kitty placement scanner (pure)

    func testRemoteKittyPlacementScannerSplitsDisjointComponents() {
        let clusterA = [(0, 0), (0, 1), (1, 0), (1, 1)]
        let clusterB = [(5, 10), (5, 11), (6, 10), (6, 11)]
        let cells = (clusterA + clusterB).map {
            RemoteKittyGridCell(lineId: $0.0, col: $0.1, imageId: 9)
        }
        let placements = RemoteKittyPlacementScanner.scan(
            cells: cells,
            firstLine: 0,
            priorityLineRange: remoteKittyAllLinesPriority,
            currentVersion: { imageId, _ in imageId == 9 ? 3 : nil }
        )
        XCTAssertEqual(placements.count, 2)
        XCTAssertEqual(placements[0], RemoteTerminalImagePlacement(
            imageId: 9, contentVersion: 3, line: 0, column: 0, rows: 2, columns: 2
        ))
        XCTAssertEqual(placements[1], RemoteTerminalImagePlacement(
            imageId: 9, contentVersion: 3, line: 5, column: 10, rows: 2, columns: 2
        ))
    }

    func testRemoteKittyPlacementScannerOnlyEmitsForRetainedVersions() {
        let cells = [RemoteKittyGridCell(lineId: 0, col: 0, imageId: 1)]
        XCTAssertEqual(
            RemoteKittyPlacementScanner.scan(
                cells: cells,
                firstLine: 0,
                priorityLineRange: remoteKittyAllLinesPriority,
                currentVersion: { _, _ in nil }
            ),
            []
        )
    }

    func testRemoteKittyPlacementScannerSortsDeterministicallyAndTranslatesFirstLine() {
        let cells = [
            RemoteKittyGridCell(lineId: 105, col: 4, imageId: 2),
            RemoteKittyGridCell(lineId: 100, col: 8, imageId: 1),
            RemoteKittyGridCell(lineId: 100, col: 2, imageId: 3),
        ]
        let versions: [UInt32: UInt64] = [1: 10, 2: 20, 3: 30]
        let placements = RemoteKittyPlacementScanner.scan(
            cells: cells,
            firstLine: 100,
            priorityLineRange: remoteKittyAllLinesPriority,
            currentVersion: { imageId, _ in versions[imageId] }
        )
        XCTAssertEqual(placements.map(\.imageId), [3, 1, 2])
        XCTAssertEqual(placements.map(\.line), [0, 0, 5])
        XCTAssertEqual(placements.map(\.column), [2, 8, 4])
    }

    /// Finding #3: a pathological grid with far more disjoint single-cell
    /// components than `remoteKittyMaxEmittedPlacements` (64) must still
    /// return exactly the cap, deterministically (the same 64 components
    /// every time — the first 64 in ascending (line, column) raster order —
    /// never an arbitrary/hash-order-dependent subset). Every cell here is
    /// inside `priorityLineRange`, so this exercises only the priority
    /// tier's own (ascending raster order) cap/truncation behavior.
    func testRemoteKittyPlacementScannerCapsEmittedPlacementsDeterministicallyOnCheckerboard() {
        // A 20x20 checkerboard where only "black" cells belong to the image:
        // every such cell's 4 orthogonal neighbors are always the opposite
        // color, so all ~200 marked cells are disjoint single-cell
        // components — comfortably more than the 64-placement cap.
        var cells: [RemoteKittyGridCell] = []
        var allCoordinates: [(line: Int, col: Int)] = []
        for line in 0 ..< 20 {
            for col in 0 ..< 20 where (line + col) % 2 == 0 {
                cells.append(RemoteKittyGridCell(lineId: line, col: col, imageId: 4))
                allCoordinates.append((line, col))
            }
        }
        XCTAssertGreaterThan(cells.count, 64, "test fixture must exceed the cap to be meaningful")

        let placements = RemoteKittyPlacementScanner.scan(
            cells: cells,
            firstLine: 0,
            priorityLineRange: remoteKittyAllLinesPriority,
            currentVersion: { imageId, _ in imageId == 4 ? 7 : nil }
        )
        XCTAssertEqual(placements.count, 64)

        // Every placement is a single cell (isolated component) still tagged
        // with the retained version, and the emitted set is exactly the
        // first 64 checkerboard coordinates in ascending (line, column)
        // raster order.
        let expected = allCoordinates.sorted { $0.line != $1.line ? $0.line < $1.line : $0.col < $1.col }.prefix(64)
        XCTAssertEqual(placements.map { ($0.line, $0.column) }.map(\.0), expected.map(\.line))
        XCTAssertEqual(placements.map { ($0.line, $0.column) }.map(\.1), expected.map(\.col))
        XCTAssertTrue(placements.allSatisfy { $0.rows == 1 && $0.columns == 1 && $0.contentVersion == 7 })

        // Re-scanning the identical input is byte-for-byte reproducible.
        let placementsAgain = RemoteKittyPlacementScanner.scan(
            cells: cells,
            firstLine: 0,
            priorityLineRange: remoteKittyAllLinesPriority,
            currentVersion: { imageId, _ in imageId == 4 ? 7 : nil }
        )
        XCTAssertEqual(placements, placementsAgain)
    }

    /// Release finding: `scan` used to reseed each connected component by
    /// scanning `remaining.min()` over the *entire remaining coordinate set*
    /// every single time — O(remaining count) per seed pick. For a
    /// checkerboard grid (every marked cell is its own disjoint single-cell
    /// component, since no two orthogonally-adjacent cells share the same
    /// "color"), that made total scan cost O(n^2) in the number of marked
    /// cells for that image id.
    ///
    /// Rather than asserting any absolute wall-clock duration (flaky across
    /// differently-provisioned CI machines), this measures the same scan at
    /// two grid sizes whose marked-cell counts differ by a fixed ~9x factor
    /// and asserts the *growth ratio* stays well under quadratic: tripling
    /// the grid's linear dimension triples its marked-cell count, so a
    /// linear/linearithmic algorithm's cost should grow only modestly more
    /// than 9x, while a quadratic algorithm's would grow roughly 81x. A
    /// generous absolute backstop is also asserted, purely as a secondary
    /// sanity check against a totally unrelated regression making the whole
    /// scan slow regardless of shape.
    func testRemoteKittyPlacementScannerCheckerboardScansNearLinearithmicallyNotQuadratically() {
        func checkerboardCells(side: Int) -> [RemoteKittyGridCell] {
            var cells: [RemoteKittyGridCell] = []
            cells.reserveCapacity(side * side / 2 + side)
            for line in 0 ..< side {
                for col in 0 ..< side where (line + col) % 2 == 0 {
                    cells.append(RemoteKittyGridCell(lineId: line, col: col, imageId: 1))
                }
            }
            return cells
        }

        @discardableResult
        func measure(side: Int) -> TimeInterval {
            let cells = checkerboardCells(side: side)
            let start = Date()
            let placements = RemoteKittyPlacementScanner.scan(
                cells: cells,
                firstLine: 0,
                priorityLineRange: remoteKittyAllLinesPriority,
                currentVersion: { imageId, _ in imageId == 1 ? 1 : nil }
            )
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertEqual(placements.count, min(64, cells.count), "emitted-placement cap must still hold")
            return elapsed
        }

        // Warm up (allocator/first-call overhead) before timing anything.
        measure(side: 40)

        let smallSide = 300 // ~45,000 marked cells
        let largeSide = 900 // ~405,000 marked cells (~9x `smallSide`'s count)
        let smallElapsed = max(measure(side: smallSide), 0.000_001)
        let largeElapsed = measure(side: largeSide)

        // A truly O(n^2) algorithm would take roughly 81x as long for a 9x
        // increase in marked cells; assert comfortably under that (well
        // above the ~9-11x a linear/linearithmic algorithm should show, to
        // absorb system noise) so this fails clearly for the old quadratic
        // implementation without being flaky for the fixed one.
        XCTAssertLessThan(
            largeElapsed, smallElapsed * 30,
            "scan must not regress to quadratic behavior on a large checkerboard grid " +
            "(small: \(smallElapsed)s, large: \(largeElapsed)s)"
        )
        // Generous absolute backstop, independent of the ratio above.
        XCTAssertLessThan(largeElapsed, 5.0, "scan of a large checkerboard grid took too long: \(largeElapsed)s")
    }

    /// Producer cap priority (new-host full-history scan hardening): when the
    /// current/emitted screen window contributes only one placement but the
    /// rest of retained history alone would already exceed the 64-placement
    /// cap, the current-window placement must still always be included —
    /// never starved out by old history — with the remaining cap budget
    /// spent on the *newest* (bottom-first) old-history components,
    /// deterministically dropping the single oldest one to make room.
    func testRemoteKittyPlacementScannerPrioritizesCurrentWindowOverOldHistory() {
        // 64 disjoint single-cell "old history" components, each its own
        // distinct image id (so none of them can ever merge into another's
        // component regardless of spatial adjacency), at lines 0...63 —
        // entirely outside the priority window below.
        var cells: [RemoteKittyGridCell] = (0 ..< 64).map { line in
            RemoteKittyGridCell(lineId: line, col: 0, imageId: UInt32(line + 1))
        }
        // One additional placement that *does* fall inside the current
        // screen window.
        let currentImageId: UInt32 = 999
        cells.append(RemoteKittyGridCell(lineId: 200, col: 0, imageId: currentImageId))

        let priorityLineRange = 200 ..< 201
        func run() -> [RemoteTerminalImagePlacement] {
            RemoteKittyPlacementScanner.scan(
                cells: cells,
                firstLine: 0,
                priorityLineRange: priorityLineRange,
                currentVersion: { _, _ in 1 }
            )
        }

        let placements = run()
        XCTAssertEqual(placements.count, 64, "total emitted must still respect the cap")
        XCTAssertTrue(
            placements.contains { $0.imageId == currentImageId },
            "the current-window placement must never be starved out by old history"
        )
        // Exactly one old-history placement was sacrificed to make room —
        // deterministically the very oldest one (smallest line / lowest
        // image id), never an arbitrary one.
        XCTAssertFalse(placements.contains { $0.imageId == 1 })
        XCTAssertTrue(placements.contains { $0.imageId == 64 })

        // Re-scanning the identical input is byte-for-byte reproducible.
        XCTAssertEqual(placements, run())
    }

    // MARK: - Transcript image association (pure)

    private func makeTurn(
        id: String,
        startedAt: TimeInterval,
        endedAt: TimeInterval? = nil
    ) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map { Date(timeIntervalSince1970: $0) },
            kind: "agent",
            userContent: "",
            assistantMessages: [],
            tools: [],
            isAborted: false
        )
    }

    private func makeSnapshot(_ turns: [TranscriptTurn]) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(timeIntervalSince1970: 10_000),
            copilotSessionId: "cs",
            turns: turns
        )
    }

    private func img(
        _ imageId: UInt32,
        _ version: UInt64,
        at displayedAt: TimeInterval
    ) -> RemoteKittyImageCapture.RetainedImageInfo {
        RemoteKittyImageCapture.RetainedImageInfo(
            imageId: imageId,
            version: version,
            displayedAt: Date(timeIntervalSince1970: displayedAt)
        )
    }

    func testTranscriptImageAssociationAttachesToActiveTurn() {
        let snapshot = makeSnapshot([
            makeTurn(id: "t1", startedAt: 100, endedAt: 200),
            makeTurn(id: "t2", startedAt: 200, endedAt: 300),
        ])
        // Displayed at 250 -> active turn is t2 (greatest startedAt <= 250).
        let result = TranscriptImageAssociation.attach(images: [img(5, 42, at: 250)], to: snapshot)
        XCTAssertNil(result.turns[0].images)
        XCTAssertEqual(result.turns[1].images?.count, 1)
        XCTAssertEqual(result.turns[1].images?.first?.imageId, 5)
        XCTAssertEqual(result.turns[1].images?.first?.contentVersion, 42)
        XCTAssertEqual(result.turns[1].images?.first?.contentVersionText, "42")
    }

    func testTranscriptImageAssociationUsesStartedAtNotEndedAt() {
        // Streaming turn with endedAt == nil; image displayed "after" its start
        // must still attach to it, and never leak into an earlier ended turn.
        let snapshot = makeSnapshot([
            makeTurn(id: "t1", startedAt: 100, endedAt: 150),
            makeTurn(id: "t2", startedAt: 200, endedAt: nil),
        ])
        let result = TranscriptImageAssociation.attach(images: [img(9, 1, at: 999)], to: snapshot)
        XCTAssertNil(result.turns[0].images)
        XCTAssertEqual(result.turns[1].images?.map(\.imageId), [9])
    }

    func testTranscriptImageAssociationDropsImageBeforeFirstTurn() {
        let snapshot = makeSnapshot([makeTurn(id: "t1", startedAt: 100)])
        let result = TranscriptImageAssociation.attach(images: [img(1, 1, at: 50)], to: snapshot)
        XCTAssertNil(result.turns[0].images)
    }

    func testTranscriptImageAssociationDedupesToNewestVersionPerImageId() {
        let snapshot = makeSnapshot([makeTurn(id: "t1", startedAt: 100)])
        let result = TranscriptImageAssociation.attach(
            images: [img(7, 10, at: 110), img(7, 20, at: 120)],
            to: snapshot
        )
        XCTAssertEqual(result.turns[0].images?.count, 1)
        XCTAssertEqual(result.turns[0].images?.first?.contentVersion, 20)
    }

    func testTranscriptImageAssociationKeepsMultipleDistinctImagesInOneTurn() {
        let snapshot = makeSnapshot([makeTurn(id: "t1", startedAt: 100)])
        let result = TranscriptImageAssociation.attach(
            images: [img(3, 1, at: 110), img(4, 1, at: 120)],
            to: snapshot
        )
        XCTAssertEqual(result.turns[0].images?.map(\.imageId), [3, 4])
    }

    func testTranscriptImageAssociationNoImagesLeavesSnapshotUnchanged() {
        let snapshot = makeSnapshot([makeTurn(id: "t1", startedAt: 100)])
        let result = TranscriptImageAssociation.attach(images: [], to: snapshot)
        XCTAssertEqual(result, snapshot)
        XCTAssertNil(result.turns[0].images)
    }

    func testTranscriptImageAssociationStripsPreexistingTurnImages() {
        // A snapshot that already carries `images` (a buggy/hostile CLI writer)
        // must have them replaced by host-computed refs — here none, so nil.
        let injected = TranscriptTurn(
            id: "t1", startedAt: Date(timeIntervalSince1970: 100), endedAt: nil,
            kind: "agent", userContent: "", assistantMessages: [], tools: [],
            isAborted: false,
            images: [TranscriptImageRef(imageId: 999, contentVersion: 1)]
        )
        let result = TranscriptImageAssociation.attach(images: [], to: makeSnapshot([injected]))
        XCTAssertNil(result.turns[0].images)
    }

    func testTranscriptImageAssociationReplacesInjectedImagesWithHostRefs() {
        let injected = TranscriptTurn(
            id: "t1", startedAt: Date(timeIntervalSince1970: 100), endedAt: nil,
            kind: "agent", userContent: "", assistantMessages: [], tools: [],
            isAborted: false,
            images: [TranscriptImageRef(imageId: 999, contentVersion: 1)]
        )
        let result = TranscriptImageAssociation.attach(
            images: [img(5, 42, at: 150)],
            to: makeSnapshot([injected])
        )
        XCTAssertEqual(result.turns[0].images?.map(\.imageId), [5])
    }

    func testTranscriptImageRefRoundTripsOptionalFieldThroughCodable() throws {
        // A CLI-written turn (no `images` key) decodes with images == nil, and a
        // host-augmented turn round-trips its refs (incl. the JS-safe text).
        let cliJSON = Data("""
        {"id":"t1","startedAt":"1970-01-01T00:01:40Z","endedAt":null,"kind":"agent",\
        "userContent":"hi","assistantMessages":[],"tools":[],"isAborted":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TranscriptTurn.self, from: cliJSON)
        XCTAssertNil(decoded.images)

        let augmented = TranscriptTurn(
            id: decoded.id, startedAt: decoded.startedAt, endedAt: decoded.endedAt,
            kind: decoded.kind, userContent: decoded.userContent,
            assistantMessages: decoded.assistantMessages, tools: decoded.tools,
            isAborted: decoded.isAborted,
            images: [TranscriptImageRef(imageId: 12_345, contentVersion: 18_000_000_000_000_000_001)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let reencoded = try decoder.decode(TranscriptTurn.self, from: encoder.encode(augmented))
        XCTAssertEqual(reencoded.images?.count, 1)
        XCTAssertEqual(reencoded.images?.first?.imageId, 12_345)
        XCTAssertEqual(reencoded.images?.first?.contentVersion, 18_000_000_000_000_000_001)
        XCTAssertEqual(reencoded.images?.first?.contentVersionText, "18000000000000000001")
    }

    func testTranscriptTurnExtractReasoningHeadingParsesAndTruncates() {
        XCTAssertEqual(
            TranscriptTurn.extractReasoningHeading(
                from: "\n  **Analyzing Copilot Project Opportunities**\n\nLook at files."
            ),
            "Analyzing Copilot Project Opportunities"
        )
        XCTAssertEqual(
            TranscriptTurn.extractReasoningHeading(from: "###   Checking   test   cases  \nMore text"),
            "Checking test cases"
        )
        XCTAssertEqual(
            TranscriptTurn.extractReasoningHeading(from: "- _Inspecting edge cases_\nDetails"),
            "Inspecting edge cases"
        )
        XCTAssertNil(TranscriptTurn.extractReasoningHeading(from: "   \n  \n "))
        XCTAssertNil(TranscriptTurn.extractReasoningHeading(from: "***"))

        let longLine = String(repeating: "a", count: 95)
        let truncated = TranscriptTurn.extractReasoningHeading(from: longLine)
        XCTAssertEqual(truncated, String(repeating: "a", count: 80) + "…")
    }

    func testTranscriptTurnReasoningSummaryLabelFormatsSingleAndMultipleSteps() {
        let singleWithHeading = TranscriptTurn(
            id: "t1",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            kind: "foreground",
            userContent: "hi",
            assistantMessages: [],
            tools: [],
            isAborted: false,
            reasoningSteps: ["**Planning Changes**\n\nStep 1 details"]
        )
        XCTAssertEqual(singleWithHeading.nonEmptyReasoningSteps, ["**Planning Changes**\n\nStep 1 details"])
        XCTAssertEqual(singleWithHeading.latestReasoningHeading, "Planning Changes")
        XCTAssertEqual(singleWithHeading.reasoningSummaryLabel, "Thinking · Planning Changes")

        let multiSteps = TranscriptTurn(
            id: "t2",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            kind: "foreground",
            userContent: "hi",
            assistantMessages: [],
            tools: [],
            isAborted: false,
            reasoningSteps: [
                "**Step One**\n\nFirst thought",
                "   ",
                "**Step Two**\n\nSecond thought",
            ]
        )
        XCTAssertEqual(multiSteps.nonEmptyReasoningSteps.count, 2)
        XCTAssertEqual(multiSteps.latestReasoningHeading, "Step Two")
        XCTAssertEqual(multiSteps.reasoningSummaryLabel, "Thinking (2 steps) · Step Two")

        let noHeading = TranscriptTurn(
            id: "t3",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            kind: "foreground",
            userContent: "hi",
            assistantMessages: [],
            tools: [],
            isAborted: false,
            reasoningSteps: ["***"]
        )
        XCTAssertNil(noHeading.latestReasoningHeading)
        XCTAssertEqual(noHeading.reasoningSummaryLabel, "Thinking")
    }

    @MainActor
    func testTranscriptToolsPreviewSummaryAndDisclosureRendering() throws {
        let tools = [
            TranscriptTool(id: "t1", name: "bash", title: "Run targeted tests", success: true),
            TranscriptTool(id: "t2", name: "bash", title: "Verify linter", success: false),
            TranscriptTool(
                id: "t3",
                name: "view",
                title: "Sources/CopilotProjectsPullRequests/Notifications/NotificationsApplication.swift",
                success: true
            ),
            TranscriptTool(id: "t4", name: "grep", title: "TranscriptTools", success: nil),
            TranscriptTool(id: "t5", name: "sql", title: "sql", success: true),
        ]
        XCTAssertEqual(TranscriptTools.previewText(for: tools), "bash ×2, view, grep, sql")
        XCTAssertEqual(
            TranscriptTools.summaryLabel(for: tools),
            "Tools (5 tools) · bash ×2, view, grep, sql · 1 failed · 1 running"
        )
        XCTAssertEqual(
            TranscriptTools.summaryLabel(for: tools, isTurnInProgress: false),
            "Tools (5 tools) · bash ×2, view, grep, sql · 1 failed"
        )
        let single = [TranscriptTool(id: "s1", name: "view", title: "README.md", success: true)]
        XCTAssertEqual(TranscriptTools.previewText(for: single), "view")
        XCTAssertEqual(TranscriptTools.summaryLabel(for: single), "Tools (1 tool) · view")

        let turn = TranscriptTurn(
            id: "turn-tools",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: nil,
            kind: "foreground",
            userContent: "Check tools",
            assistantMessages: [],
            tools: tools,
            isAborted: false,
            reasoningSteps: ["**Checking tools**\n\nInspecting layout."]
        )
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -18_000, y: -18_000, width: 420, height: 360),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: TranscriptTurnCard(
                turn: turn,
                imageCapture: nil,
                onPreview: { _ in }
            )
            .frame(width: 384)
            .environment(\.controlActiveState, .key)
        )
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        func pump() {
            for _ in 0..<8 {
                CFRunLoopRunInMode(.defaultMode, 0, false)
                host.layoutSubtreeIfNeeded()
            }
        }
        func findProgressIndicators(in view: NSView) -> [NSProgressIndicator] {
            ((view as? NSProgressIndicator).map { [$0] } ?? [])
                + view.subviews.flatMap(findProgressIndicators(in:))
        }

        pump()
        let indicator = try XCTUnwrap(findProgressIndicators(in: host).first)
        let collapsedHeight = host.fittingSize.height
        let togglePointInWindow = indicator.convert(NSPoint(x: -40, y: indicator.bounds.midY), to: nil)
        try sendClick(in: window, point: togglePointInWindow)
        pump()
        let expandedHeight = host.fittingSize.height
        XCTAssertGreaterThan(expandedHeight, collapsedHeight + 80)

        let togglePointAfterExpand = indicator.convert(NSPoint(x: -40, y: indicator.bounds.midY), to: nil)
        try sendClick(in: window, point: togglePointAfterExpand)
        pump()
        XCTAssertEqual(host.fittingSize.height, collapsedHeight, accuracy: 1)

        for inactiveTurn in [
            TranscriptTurn(
                id: "turn-ended",
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: Date(timeIntervalSince1970: 110),
                kind: "foreground",
                userContent: "Ended",
                assistantMessages: [],
                tools: tools,
                isAborted: false
            ),
            TranscriptTurn(
                id: "turn-aborted",
                startedAt: Date(timeIntervalSince1970: 100),
                endedAt: nil,
                kind: "foreground",
                userContent: "Aborted",
                assistantMessages: [],
                tools: tools,
                isAborted: true
            ),
        ] {
            let inactiveHost = NSHostingView(
                rootView: TranscriptTurnCard(turn: inactiveTurn, imageCapture: nil, onPreview: { _ in })
            )
            inactiveHost.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
            window.contentView = inactiveHost
            for _ in 0..<4 {
                CFRunLoopRunInMode(.defaultMode, 0, false)
                inactiveHost.layoutSubtreeIfNeeded()
            }
            XCTAssertTrue(findProgressIndicators(in: inactiveHost).isEmpty, inactiveTurn.id)
        }
    }

    func testTranscriptTurnReasoningStepsCodableRoundTripAndLegacyDecode() throws {
        let legacyJSON = Data("""
        {"id":"t1","startedAt":"1970-01-01T00:01:40Z","endedAt":null,"kind":"foreground",\
        "userContent":"hi","assistantMessages":[],"tools":[],"isAborted":false}
        """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decodedLegacy = try decoder.decode(TranscriptTurn.self, from: legacyJSON)
        XCTAssertNil(decodedLegacy.reasoningSteps)
        XCTAssertTrue(decodedLegacy.nonEmptyReasoningSteps.isEmpty)

        let withReasoning = TranscriptTurn(
            id: "t2",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 120),
            kind: "foreground",
            userContent: "hi",
            assistantMessages: [],
            tools: [],
            isAborted: false,
            reasoningSteps: ["**Checking Protocol**\n\nDetails", "**Updating View**\n\nMore"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(withReasoning)
        let roundTripped = try decoder.decode(TranscriptTurn.self, from: encoded)
        XCTAssertEqual(
            roundTripped.reasoningSteps,
            ["**Checking Protocol**\n\nDetails", "**Updating View**\n\nMore"]
        )
    }

    func testTranscriptImageAssociationPreservesReasoningSteps() {
        let turn = TranscriptTurn(
            id: "t1",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 200),
            kind: "foreground",
            userContent: "hi",
            assistantMessages: [],
            tools: [],
            isAborted: false,
            reasoningSteps: ["**Inspecting Image Association**\n\nPreserve reasoningSteps."]
        )
        let snapshot = makeSnapshot([turn])
        let resultWithImage = TranscriptImageAssociation.attach(
            images: [img(5, 42, at: 150)],
            to: snapshot
        )
        XCTAssertEqual(
            resultWithImage.turns.first?.reasoningSteps,
            ["**Inspecting Image Association**\n\nPreserve reasoningSteps."]
        )
        XCTAssertEqual(resultWithImage.turns.first?.images?.map(\.imageId), [5])
    }

    func testCopilotExtensionReplayAttributesExecutionErrorToReasoningOnlyUnansweredTurn() throws {
        try requireNodeForJavaScriptTests()
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/copilot-extension-reasoning-replay-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let appSessionId = "12345678-1234-1234-1234-123456789abc"

        let prelude = #"""
        const fakeSession = {
          sessionId: "11111111-1111-1111-1111-111111111111",
          rpc: { schedule: { list: async () => ({entries:[]}) } },
          on() {},
          async getEvents() {
            return [
              {
                id: "u1",
                type: "user.message",
                timestamp: "2026-07-12T03:00:00.000Z",
                data: { content: "run build" }
              },
              {
                id: "ts1",
                type: "assistant.turn_start",
                timestamp: "2026-07-12T03:00:01.000Z",
                data: {}
              },
              {
                id: "am1",
                type: "assistant.message",
                timestamp: "2026-07-12T03:00:02.000Z",
                data: {
                  messageId: "m1",
                  content: "",
                  reasoningText: "**Checking Build Setup**\n\nInspecting build scripts."
                }
              },
              {
                id: "te1",
                type: "assistant.turn_end",
                timestamp: "2026-07-12T03:00:03.000Z",
                data: {}
              },
              {
                id: "err1",
                type: "session.error",
                timestamp: "2026-07-12T03:00:04.000Z",
                data: {
                  errorType: "execution",
                  message: "Execution failed before producing an answer"
                }
              },
              {
                id: "idle1",
                type: "session.idle",
                timestamp: "2026-07-12T03:00:05.000Z",
                data: { aborted: false }
              }
            ];
          }
        };
        const joinSession = async () => fakeSession;
        """#
        let extensionScript = CopilotExtension.script.replacingOccurrences(
            of: #"import { joinSession } from "@github/copilot-sdk/extension";"#,
            with: prelude
        )
        let epilogue = #"""

        const sealed = JSON.parse(readFileSync(
          `${process.env.COPILOT_PROJECTS_ROOT}/sessions/`
            + `${process.env.COPILOT_PROJECTS_SESSION}.transcript.json`,
          "utf8"
        ));
        console.log(JSON.stringify({
          turns: sealed.turns
        }));
        process.exit(0);
        """#
        let scriptURL = root.appendingPathComponent("reasoning-replay.mjs")
        try (extensionScript + epilogue).write(
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
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output) as? [String: Any]
        )
        let turns = try XCTUnwrap(payload["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0]["id"] as? String, "u1")
        XCTAssertEqual(
            turns[0]["reasoningSteps"] as? [String],
            ["**Checking Build Setup**\n\nInspecting build scripts."]
        )
        let turnError = try XCTUnwrap(turns[0]["error"] as? [String: Any])
        XCTAssertEqual(turnError["errorType"] as? String, "execution")
        XCTAssertEqual(
            turnError["message"] as? String,
            "Execution failed before producing an answer"
        )
    }

    // MARK: - Remote Kitty APC capture (byte-level parser, bounded + fail-closed)

    @MainActor
    func testRemoteKittyImageCaptureParsesSingleFrameAcrossArbitraryBoundaries() {
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let frame = remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=42",
            base64Payload: png.base64EncodedString()
        )
        for chunkSize in [1, 2, 3, 7, 1_000] {
            let capture = remoteKittyTestCapture()
            remoteKittyIngest(capture, frame, chunkSize: chunkSize)
            XCTAssertEqual(capture.currentVersion(for: 42), 1, "chunkSize \(chunkSize)")
            XCTAssertEqual(capture.imageData(imageId: 42, version: 1), png, "chunkSize \(chunkSize)")
        }
    }

    @MainActor
    func testRemoteKittyImageCaptureParsesChunkedTransmissionAcrossArbitraryBoundaries() {
        let png = remoteKittyTestPNGBytes(width: 3, height: 3)
        let base64 = png.base64EncodedString()
        let midpoint = base64.index(base64.startIndex, offsetBy: base64.count / 2)
        let firstHalf = String(base64[..<midpoint])
        let secondHalf = String(base64[midpoint...])
        var frame = remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=7,m=1",
            base64Payload: firstHalf
        )
        frame += remoteKittyFrameBytes(control: "m=0", base64Payload: secondHalf)
        for chunkSize in [1, 2, 5, 11, 4_096] {
            let capture = remoteKittyTestCapture()
            remoteKittyIngest(capture, frame, chunkSize: chunkSize)
            XCTAssertEqual(capture.currentVersion(for: 7), 1, "chunkSize \(chunkSize)")
            XCTAssertEqual(capture.imageData(imageId: 7, version: 1), png, "chunkSize \(chunkSize)")
        }
    }

    @MainActor
    func testRemoteKittyImageCaptureIgnoresUnsupportedTransmissionSubset() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        // Unsupported: not direct transmission (t=f, file-based).
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=f,U=1,i=1", base64Payload: base64
        )[...])
        // Unsupported: not PNG (f=32, raw RGB).
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=32,t=d,U=1,i=2", base64Payload: base64
        )[...])
        // Unsupported: no unicode placeholder (U key missing).
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,i=3", base64Payload: base64
        )[...])
        // Unsupported: id out of the 1...0xFFFFFF range.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=0", base64Payload: base64
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=16777216", base64Payload: base64
        )[...])
        for imageId: UInt32 in [1, 2, 3, 0, 16_777_216] {
            XCTAssertNil(capture.currentVersion(for: imageId))
        }
        // A subsequent well-formed frame still parses correctly.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=9", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 9), 1)
        XCTAssertEqual(capture.imageData(imageId: 9, version: 1), png)
    }

    @MainActor
    func testRemoteKittyImageCaptureRecoversFromMalformedFraming() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // Wrong APC marker (not 'G'): the entire frame is skipped verbatim.
        var wrongMarker: [UInt8] = [0x1B, 0x5F, 0x58] // ESC _ X
        wrongMarker.append(contentsOf: Array("bogus".utf8))
        wrongMarker.append(contentsOf: [0x1B, 0x5C])
        capture.ingest(wrongMarker[...])

        // ESC inside an in-flight APC frame not followed by ST ('\'): aborts and
        // resynchronizes instead of getting stuck mid-frame.
        var aborted: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G
        aborted.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=11".utf8))
        aborted.append(contentsOf: [0x1B, 0x41]) // ESC 'A' (not ST)
        capture.ingest(aborted[...])

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=11", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 11), 1)
        XCTAssertEqual(capture.imageData(imageId: 11, version: 1), png)
    }

    /// Finding #4 (parser resync regression): when the byte that turns out
    /// *not* to be the aborted frame's ST is specifically `_` (0x5F) — i.e. a
    /// fresh APC's own start marker arriving immediately, with no separating
    /// ST/ESC-pair at all — the fix must recognize it as the start of a new
    /// frame right there rather than falling through to `.ground` and losing
    /// the already-consumed "ESC" (which would otherwise silently swallow the
    /// entire following valid frame, `G` marker, control data, and its own
    /// terminator, until some unrelated later byte happened to look like ST).
    @MainActor
    func testRemoteKittyImageCaptureResyncsIntoFreshAPCAfterAbortedAccumulatingFrameWithoutExplicitTerminator() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G — an APC begins...
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=60".utf8)) // ...but is never terminated...
        bytes.append(0x1B) // ...instead another ESC arrives (would-be ST lookahead)...
        // ...and the very next byte is '_': not a terminator, but a brand new
        // APC's start marker, arriving with NO intervening ST/ESC-pair of its
        // own (the leading ESC of the following frame is dropped here since
        // the ESC above already serves that role).
        let validFrame = remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=61", base64Payload: base64
        )
        precondition(validFrame.first == 0x1B)
        bytes.append(contentsOf: validFrame.dropFirst())
        capture.ingest(bytes[...])

        XCTAssertNil(capture.currentVersion(for: 60), "the malformed/unterminated frame must never be retained")
        XCTAssertEqual(capture.currentVersion(for: 61), 1, "the immediately-following valid frame must still parse")
        XCTAssertEqual(capture.imageData(imageId: 61, version: 1), png)
    }

    /// The same regression, but recovering from `.apcSkippingEsc` (the
    /// oversized/wrong-marker-frame recovery path) instead of
    /// `.apcAccumulatingEsc` — a fresh APC's `_` marker arriving mid-skip,
    /// with no ST ever seen for the abandoned frame, must still start a new
    /// frame immediately rather than resuming skip mode and swallowing the
    /// following valid frame's own terminator as if it belonged to the
    /// abandoned one.
    @MainActor
    func testRemoteKittyImageCaptureResyncsIntoFreshAPCAfterSkippingOversizedFrameWithoutExplicitTerminator() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G
        // Exceeds the 96 KiB raw-frame bound with no ESC inside, forcing a
        // transition into `.apcSkipping` (frame abandoned, no ST ever seen).
        bytes.append(contentsOf: [UInt8](repeating: 0x61, count: 96 * 1_024 + 4_096))
        bytes.append(0x1B) // -> .apcSkippingEsc (would-be ST lookahead)
        // Immediately followed by a fresh valid frame's own "_G...ESC\" with
        // no leading ESC of its own and no ST separating it from the
        // abandoned frame above.
        let validFrame = remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=71", base64Payload: base64
        )
        precondition(validFrame.first == 0x1B)
        bytes.append(contentsOf: validFrame.dropFirst())
        capture.ingest(bytes[...])

        XCTAssertNil(capture.currentVersion(for: 70))
        XCTAssertEqual(capture.currentVersion(for: 71), 1, "the immediately-following valid frame must still parse")
        XCTAssertEqual(capture.imageData(imageId: 71, version: 1), png)
    }

    /// Parser string-state drift: an OSC (`ESC ]`) string's own payload —
    /// never itself parsed, just scanned for its terminator — can contain
    /// byte sequences that merely *look like* the start of our own Kitty APC
    /// (`ESC _ G`). Because the scanner tracks that it's inside the OSC
    /// string (rather than forgetting and falling back to `.ground` the
    /// moment `ESC ]` is seen), those embedded bytes are never misparsed as
    /// a real APC start; only the OSC's own real terminator — BEL here, one
    /// of the two OSC accepts — ends it, after which a genuinely separate,
    /// valid Kitty frame still parses correctly.
    @MainActor
    func testRemoteKittyImageCaptureIgnoresFakeKittyBytesInsideOSCString() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x5D] // ESC ] — OSC start
        bytes.append(contentsOf: Array("0;fake-title-".utf8))
        // Fake Kitty APC bytes embedded *inside* the OSC payload — with no ST
        // of their own, so they never end the OSC prematurely — that an old,
        // string-state-unaware parser would have misread as a real APC start
        // the instant it (incorrectly) fell back to `.ground` after `ESC ]`.
        bytes.append(contentsOf: [0x1B, 0x5F, 0x47]) // ESC _ G
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=999;bogus-payload-data".utf8))
        bytes.append(0x07) // BEL — OSC's own real terminator

        // A genuinely separate, valid Kitty frame immediately follows.
        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=42", base64Payload: png.base64EncodedString()
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(
            capture.currentVersion(for: 999),
            "bytes embedded inside the OSC string must never be parsed as a Kitty APC"
        )
        XCTAssertEqual(capture.currentVersion(for: 42), 1, "the real frame after the OSC must still parse")
        XCTAssertEqual(capture.imageData(imageId: 42, version: 1), png)
    }

    /// The same drift, but for a DCS (`ESC P`) string, which — unlike OSC —
    /// is only ever terminated by a full ST (`ESC \`), never a bare BEL.
    @MainActor
    func testRemoteKittyImageCaptureIgnoresFakeKittyBytesInsideDCSString() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x50] // ESC P — DCS start
        bytes.append(contentsOf: Array("0;dcs-noise-".utf8))
        bytes.append(contentsOf: [0x1B, 0x5F, 0x47]) // fake ESC _ G embedded in the DCS payload
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=998;bogus-payload-data".utf8))
        bytes.append(contentsOf: [0x1B, 0x5C]) // ESC \ — DCS's own real ST terminator

        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=43", base64Payload: png.base64EncodedString()
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(
            capture.currentVersion(for: 998),
            "bytes embedded inside the DCS string must never be parsed as a Kitty APC"
        )
        XCTAssertEqual(capture.currentVersion(for: 43), 1, "the real frame after the DCS must still parse")
        XCTAssertEqual(capture.imageData(imageId: 43, version: 1), png)
    }

    /// PM (`ESC ^`) strings terminate like DCS (ST-only) — the same embedded
    /// -fake-APC-bytes drift must be ignored there too.
    @MainActor
    func testRemoteKittyImageCaptureIgnoresFakeKittyBytesInsidePMString() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x5E] // ESC ^ — PM start
        bytes.append(contentsOf: Array("pm-noise-".utf8))
        bytes.append(contentsOf: [0x1B, 0x5F, 0x47])
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=997;bogus-payload-data".utf8))
        bytes.append(contentsOf: [0x1B, 0x5C]) // ST

        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=44", base64Payload: png.base64EncodedString()
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(
            capture.currentVersion(for: 997),
            "bytes embedded inside the PM string must never be parsed as a Kitty APC"
        )
        XCTAssertEqual(capture.currentVersion(for: 44), 1, "the real frame after the PM string must still parse")
        XCTAssertEqual(capture.imageData(imageId: 44, version: 1), png)
    }

    /// Release finding #3 (parser control-string termination): CAN (0x18)
    /// unconditionally cancels an in-progress OSC string — mirroring
    /// SwiftTerm's own "anywhere" CAN/SUB rule — never requiring its usual
    /// BEL/ST terminator. A genuinely separate, valid Kitty frame
    /// immediately following must still parse correctly.
    @MainActor
    func testRemoteKittyImageCaptureCancelsOSCStringOnCANAndResyncsToValidFrame() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x5D] // ESC ] — OSC start
        bytes.append(contentsOf: Array("0;fake-title-".utf8))
        bytes.append(contentsOf: [0x1B, 0x5F, 0x47]) // fake APC start embedded in the OSC payload
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=996;bogus-payload-data".utf8))
        bytes.append(0x18) // CAN — cancels the OSC string outright, never its BEL/ST

        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=45", base64Payload: png.base64EncodedString()
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(
            capture.currentVersion(for: 996),
            "bytes embedded inside the CAN-cancelled OSC string must never be parsed as a Kitty APC"
        )
        XCTAssertEqual(capture.currentVersion(for: 45), 1, "the frame after a CAN-cancelled OSC must still parse")
        XCTAssertEqual(capture.imageData(imageId: 45, version: 1), png)
    }

    /// The same CAN/SUB "anywhere" cancellation, but for a DCS (`ESC P`)
    /// string cancelled by SUB (0x1A) instead — DCS otherwise only ever
    /// terminates on a full ST, never a bare BEL, so this proves CAN/SUB
    /// specifically bypass that ST-only requirement too.
    @MainActor
    func testRemoteKittyImageCaptureCancelsDCSStringOnSUBAndResyncsToValidFrame() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x50] // ESC P — DCS start
        bytes.append(contentsOf: Array("0;dcs-noise-".utf8))
        bytes.append(contentsOf: [0x1B, 0x5F, 0x47]) // fake APC start embedded in the DCS payload
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=995;bogus-payload-data".utf8))
        bytes.append(0x1A) // SUB — cancels the DCS string outright, never a real ST

        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=46", base64Payload: png.base64EncodedString()
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(
            capture.currentVersion(for: 995),
            "bytes embedded inside the SUB-cancelled DCS string must never be parsed as a Kitty APC"
        )
        XCTAssertEqual(capture.currentVersion(for: 46), 1, "the frame after a SUB-cancelled DCS must still parse")
        XCTAssertEqual(capture.imageData(imageId: 46, version: 1), png)
    }

    /// A bare C1 ST (0x9C) — with no leading 7-bit `ESC \` — must terminate
    /// and successfully *complete* a valid, in-progress Kitty APC frame,
    /// mirroring SwiftTerm's shared apc/osc terminator set. A subsequent
    /// frame still parses correctly afterward.
    @MainActor
    func testRemoteKittyImageCaptureCompletesValidAPCFrameOnBareC1STTerminator() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G — APC start
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=47".utf8))
        bytes.append(0x3B) // ';'
        bytes.append(contentsOf: Array(png.base64EncodedString().utf8))
        bytes.append(0x9C) // C1 ST — completes the frame directly, no `ESC \` needed
        capture.ingest(bytes[...])

        XCTAssertEqual(
            capture.currentVersion(for: 47), 1,
            "a bare C1 ST must terminate and complete a valid, otherwise-well-formed APC frame"
        )
        XCTAssertEqual(capture.imageData(imageId: 47, version: 1), png)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=48", base64Payload: png.base64EncodedString()
        )[...])
        // Version counters are monotonic per *capture instance* (not per
        // image id), so this instance's second-ever successful retain is
        // version 2, not 1.
        XCTAssertEqual(capture.currentVersion(for: 48), 2, "a subsequent frame must still parse correctly")
        XCTAssertEqual(capture.imageData(imageId: 48, version: 2), png)
    }

    /// The same as above, but terminated by a bare BEL (0x07) instead —
    /// SwiftTerm's transition table treats BEL as a valid APC terminator
    /// too, not just OSC's.
    @MainActor
    func testRemoteKittyImageCaptureCompletesValidAPCFrameOnBELTerminator() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G — APC start
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=49".utf8))
        bytes.append(0x3B) // ';'
        bytes.append(contentsOf: Array(png.base64EncodedString().utf8))
        bytes.append(0x07) // BEL — also a valid APC terminator, mirroring SwiftTerm
        capture.ingest(bytes[...])

        XCTAssertEqual(
            capture.currentVersion(for: 49), 1,
            "a bare BEL must terminate and complete a valid, otherwise-well-formed APC frame"
        )
        XCTAssertEqual(capture.imageData(imageId: 49, version: 1), png)

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=50", base64Payload: png.base64EncodedString()
        )[...])
        // Version counters are monotonic per *capture instance* (not per
        // image id), so this instance's second-ever successful retain is
        // version 2, not 1.
        XCTAssertEqual(capture.currentVersion(for: 50), 2, "a subsequent frame must still parse correctly")
        XCTAssertEqual(capture.imageData(imageId: 50, version: 2), png)
    }

    /// Unlike C1 ST/BEL (which *complete* an in-progress frame — see above),
    /// CAN must always *abort* one instead, discarding it, even mid our own
    /// Kitty APC accumulation — proving CAN/SUB's cancel behavior is
    /// distinct from (never conflated with) a real terminator's complete
    /// behavior. A genuinely separate, valid frame afterward still parses.
    @MainActor
    func testRemoteKittyImageCaptureAbortsInProgressAPCFrameOnCANAndResyncs() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G — APC start
        bytes.append(contentsOf: Array("a=T,f=100,t=d,U=1,i=51".utf8))
        bytes.append(0x3B)
        bytes.append(contentsOf: Array(base64.utf8))
        bytes.append(0x18) // CAN — aborts, never completes, the in-progress frame

        bytes.append(contentsOf: remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=52", base64Payload: base64
        ))
        capture.ingest(bytes[...])

        XCTAssertNil(capture.currentVersion(for: 51), "CAN must abort, never complete, an in-progress APC frame")
        XCTAssertEqual(capture.currentVersion(for: 52), 1, "the frame after CAN must still parse")
        XCTAssertEqual(capture.imageData(imageId: 52, version: 1), png)
    }

    @MainActor
    func testRemoteKittyImageCaptureOversizedRawFrameIsBoundedAndRecovers() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G
        // Exceeds the 96 KiB raw-frame bound with no ESC bytes inside, so the
        // parser must discard/resynchronize instead of growing unboundedly.
        bytes.append(contentsOf: [UInt8](repeating: 0x61, count: 96 * 1_024 + 4_096))
        bytes.append(contentsOf: [0x1B, 0x5C]) // resynchronize back to ground
        capture.ingest(bytes[...])

        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=13", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 13), 1)
        XCTAssertEqual(capture.imageData(imageId: 13, version: 1), png)
    }

    /// Finding #3: a test that's supposed to prove the *accumulated*-base64
    /// guard specifically must use continuation chunks each individually well
    /// under both the raw-frame (96 KiB) and decoded-image (5 MiB) bounds —
    /// otherwise a single oversized frame would trip one of those unrelated
    /// bounds first, and the test would keep "passing" even if the
    /// accumulated-bytes guard itself were deleted. The accumulated cap is
    /// injected far below its real production value so a genuinely small,
    /// fully valid PNG (well under every other bound) can still be proven to
    /// overflow it.
    @MainActor
    func testRemoteKittyImageCaptureOversizedAccumulatedBase64DiscardsAndRecovers() throws {
        let png = remoteKittyTestPNGBytes(width: 64, height: 64)
        let base64 = png.base64EncodedString()
        // Comfortably more than the injected 300-byte accumulated cap below,
        // and enough to span several 64-byte chunks.
        XCTAssertGreaterThan(
            base64.utf8.count, 300,
            "fixture must be large enough to span multiple small chunks"
        )
        let frames = remoteKittyChunkedTransmissionFrames(
            control: "a=T,f=100,t=d,U=1,i=20", base64Payload: base64, chunkBytes: 64
        )

        // A capture whose accumulated-base64 cap is injected far below this
        // transmission's real total (well over 256 bytes, per the assertion
        // above), while every individual chunk (64 bytes) stays comfortably
        // under both the raw-frame and decoded-image bounds — so only the
        // accumulated guard itself can explain a rejection. Set high enough
        // that a later, genuinely tiny single-frame recovery transmission
        // (a 2x2 PNG's base64 payload) still fits comfortably under it.
        let tightCapture = RemoteKittyImageCapture(
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            maxAccumulatedBase64Bytes: 300
        )
        tightCapture.ingest(frames[...])
        XCTAssertNil(tightCapture.currentVersion(for: 20))

        // The scanner recovers: a later, small transmission still parses.
        let recovery = remoteKittyTestPNGBytes(width: 2, height: 2)
        tightCapture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=21", base64Payload: recovery.base64EncodedString()
        )[...])
        XCTAssertEqual(tightCapture.currentVersion(for: 21), 1)
        XCTAssertEqual(tightCapture.imageData(imageId: 21, version: 1), recovery)

        // The exact same byte sequence, fed into a capture using the real
        // production accumulated-base64 cap, assembles and retains
        // successfully — proving the rejection above came specifically from
        // the injected small accumulated cap, never from a malformed
        // fixture, a raw-frame overflow, or the decoded-size/dimension
        // bounds (which this same data trivially satisfies).
        let productionCapture = remoteKittyTestCapture()
        productionCapture.ingest(frames[...])
        let productionVersion = try XCTUnwrap(productionCapture.currentVersion(for: 20))
        XCTAssertEqual(productionCapture.imageData(imageId: 20, version: productionVersion), png)
    }

    @MainActor
    func testRemoteKittyImageCaptureRejectsOversizedIHDR() {
        let capture = remoteKittyTestCapture()

        let tooWide = remoteKittyTestPNGBytes(width: 5_000, height: 10)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=30", base64Payload: tooWide.base64EncodedString()
        )[...])
        XCTAssertNil(capture.currentVersion(for: 30))

        // A real PNG this large exceeds a single raw APC frame's bound, so it
        // must be sent chunked (as a real client would) to exercise the
        // pixel-count rejection itself rather than an incidental frame-size one.
        let tooManyPixels = remoteKittyTestPNGBytes(width: 4_000, height: 4_001)
        capture.ingest(remoteKittyChunkedTransmissionFrames(
            control: "a=T,f=100,t=d,U=1,i=31", base64Payload: tooManyPixels.base64EncodedString()
        )[...])
        XCTAssertNil(capture.currentVersion(for: 31))

        // Right at the bound (4096 x 1024 = 4,194,304 <= 16M pixels) is
        // accepted; also sent chunked since its real encoded size exceeds a
        // single raw APC frame's bound.
        let ok = remoteKittyTestPNGBytes(width: 4_096, height: 1_024)
        capture.ingest(remoteKittyChunkedTransmissionFrames(
            control: "a=T,f=100,t=d,U=1,i=32", base64Payload: ok.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 32), 1)
    }

    /// Finding #5: a signature+IHDR-only fixture with no real IDAT/IEND (the
    /// *old* fake test fixture, before this pass switched every other test to
    /// real ImageIO-decodable PNGs) declares plausible dimensions but is not
    /// a structurally complete PNG — the old 24-byte-header-only check would
    /// have accepted it. The ImageIO-based validator must reject it outright.
    @MainActor
    func testRemoteKittyImageCaptureRejectsStructurallyTruncatedPNG() {
        let capture = remoteKittyTestCapture()
        let truncated = remoteKittyTruncatedPNGFixtureBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=33", base64Payload: truncated.base64EncodedString()
        )[...])
        XCTAssertNil(capture.currentVersion(for: 33))

        // A subsequent, real, structurally complete PNG still parses fine —
        // the rejection is specific to the malformed data, not a stuck parser.
        let real = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=34", base64Payload: real.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 34), 1)
        XCTAssertEqual(capture.imageData(imageId: 34, version: 1), real)
    }

    @MainActor
    func testRemoteKittyImageCaptureDeleteAllClearsData() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1", base64Payload: base64
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=2", base64Payload: base64
        )[...])
        // The version counter is global (monotonic across the whole capture
        // instance), so the second-ingested id gets the second version.
        XCTAssertEqual(capture.currentVersion(for: 1), 1)
        XCTAssertEqual(capture.currentVersion(for: 2), 2)

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=A")[...])
        XCTAssertNil(capture.currentVersion(for: 1))
        XCTAssertNil(capture.currentVersion(for: 2))
        XCTAssertNil(capture.imageData(imageId: 1, version: 1))
        XCTAssertNil(capture.imageData(imageId: 2, version: 2))
    }

    @MainActor
    func testRemoteKittyImageCaptureDeleteByIdRemovesOnlyThatImage() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=5", base64Payload: base64
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=6", base64Payload: base64
        )[...])

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=5")[...])
        XCTAssertNil(capture.currentVersion(for: 5))
        XCTAssertEqual(capture.currentVersion(for: 6), 2)
    }

    @MainActor
    func testRemoteKittyImageCaptureLowercaseIDeleteRemovesActivePlacementButRetainsData() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=8", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 8), 1)

        // Lowercase 'i': placement-only delete. Must remove the *active*
        // placement (fixing the ghost — a scan should no longer discover this
        // id) while leaving the retained PNG bytes fetchable, mirroring the
        // Kitty spec's own placement-vs-data distinction.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=8")[...])
        XCTAssertNil(capture.currentVersion(for: 8))
        XCTAssertEqual(capture.imageData(imageId: 8, version: 1), png)

        // A fresh transmission for the same id reactivates its placement.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=8", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 8), 2)
    }

    @MainActor
    func testRemoteKittyImageCaptureLowercaseADeleteClearsEveryActivePlacementButRetainsData() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=11", base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=12", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 11), 1)
        XCTAssertEqual(capture.currentVersion(for: 12), 2)

        // Lowercase 'a' (also the default when `d` is omitted entirely):
        // clears every id's active placement, never their retained data.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        XCTAssertNil(capture.currentVersion(for: 11))
        XCTAssertNil(capture.currentVersion(for: 12))
        XCTAssertEqual(capture.imageData(imageId: 11, version: 1), png)
        XCTAssertEqual(capture.imageData(imageId: 12, version: 2), png)

        // Retransmitting id 11 alone reactivates only that id.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=11", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 11), 3)
        XCTAssertNil(capture.currentVersion(for: 12))
    }

    /// Any lowercase delete mode this capture doesn't specifically scope
    /// (column/row/z-index/point/animation-frame targeted deletes — anything
    /// besides `a`/`i`) is handled fail-closed: since it can't reason about
    /// exactly which placements such a delete would target, it conservatively
    /// clears every active placement rather than risk leaving a ghost.
    @MainActor
    func testRemoteKittyImageCaptureUnrecognizedLowercaseDeleteModeConservativelyClearsActivePlacements() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=13", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 13), 1)

        // 'z' (delete by z-index) isn't a mode this id-keyed capture can
        // correctly scope — fail closed instead of risking a ghost.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=z")[...])
        XCTAssertNil(capture.currentVersion(for: 13))
        XCTAssertEqual(capture.imageData(imageId: 13, version: 1), png)
    }

    /// The uppercase counterpart of the fail-closed default above: an
    /// unrecognized *uppercase* delete mode also deletes underlying data per
    /// the Kitty spec, so the fail-closed fallback must clear retained bytes
    /// too, not just active placements.
    @MainActor
    func testRemoteKittyImageCaptureUnrecognizedUppercaseDeleteModeConservativelyClearsData() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=14", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 14), 1)

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=Z")[...])
        XCTAssertNil(capture.currentVersion(for: 14))
        XCTAssertNil(capture.imageData(imageId: 14, version: 1))
    }

    /// `imageAvailabilityGeneration` must bump exactly once for a change that
    /// actually alters what a scan would currently discover, and must NOT
    /// bump again for a subsequent operation that doesn't — e.g. deleting an
    /// already-inactive id's placement a second time, or letting its retained
    /// (but already un-advertised) data quietly age out of the grace cache.
    @MainActor
    func testRemoteKittyImageCaptureAvailabilityGenerationDoesNotDoubleBump() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=20", base64Payload: png.base64EncodedString()
        )[...])
        let afterRetain = capture.imageAvailabilityGeneration
        XCTAssertEqual(capture.currentVersion(for: 20), 1)

        // First lowercase 'i' delete: was active + retained, so this must
        // change the generation exactly once.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=20")[...])
        let afterFirstDelete = capture.imageAvailabilityGeneration
        XCTAssertNotEqual(afterFirstDelete, afterRetain)
        XCTAssertNil(capture.currentVersion(for: 20))

        // A second lowercase 'i' delete for the same, already-inactive id:
        // nothing a scan could discover changes, so the generation must not
        // bump again.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=20")[...])
        XCTAssertEqual(capture.imageAvailabilityGeneration, afterFirstDelete)

        // Likewise, a lowercase 'a' clear-all with no active ids left at all
        // must not bump either.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=a")[...])
        XCTAssertEqual(capture.imageAvailabilityGeneration, afterFirstDelete)

        // The retained (but already un-advertised, since inactive) data for
        // id 20 is still fetchable — evicting it via `d=I` (which does target
        // this id's data) must also not bump, since it wasn't advertised.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=20")[...])
        XCTAssertEqual(capture.imageAvailabilityGeneration, afterFirstDelete)
        XCTAssertNil(capture.imageData(imageId: 20, version: 1))
    }

    /// Transcript revisions carry the availability token, which a restarted
    /// capture (generation back at 0) never repeats even when it drew the
    /// same content-version epoch, while one capture's token changes exactly
    /// when its generation does.
    @MainActor
    func testRemoteKittyImageAvailabilityTokenIsUniquePerCapture() {
        let first = remoteKittyTestCapture(epoch: 1)
        let restarted = remoteKittyTestCapture(epoch: 1)
        XCTAssertEqual(first.epochForTesting, restarted.epochForTesting)
        XCTAssertEqual(first.imageAvailabilityGeneration, restarted.imageAvailabilityGeneration)
        XCTAssertNotEqual(first.imageAvailabilityToken, restarted.imageAvailabilityToken)

        let initialToken = first.imageAvailabilityToken
        let generationSuffix = "-\(first.imageAvailabilityGeneration)"
        XCTAssertTrue(initialToken.hasSuffix(generationSuffix))
        let identity = String(initialToken.dropLast(generationSuffix.count))

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        first.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=20", base64Payload: png.base64EncodedString()
        )[...])
        let before = first.imageAvailabilityToken
        XCTAssertNotEqual(before, initialToken)
        first.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=20")[...])
        XCTAssertNotEqual(first.imageAvailabilityToken, before)
        XCTAssertEqual(first.imageAvailabilityToken, "\(identity)-\(first.imageAvailabilityGeneration)")
    }

    @MainActor
    func testRemoteKittyImageCaptureRetainsGraceVersionsAfterRetransmit() {
        let capture = remoteKittyTestCapture()
        let first = remoteKittyTestPNGBytes(width: 2, height: 2)
        let second = remoteKittyTestPNGBytes(width: 3, height: 3)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=40", base64Payload: first.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 40), 1)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=40", base64Payload: second.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 40), 2)
        // The just-superseded version is still fetchable (grace retention), so a
        // client racing a retransmit doesn't 404 on the version it was just told
        // about.
        XCTAssertEqual(capture.imageData(imageId: 40, version: 1), first)
        XCTAssertEqual(capture.imageData(imageId: 40, version: 2), second)
    }

    /// Finding #1: an in-flight `m=1` chunked transmission must never be able
    /// to finalize *after* an intervening delete — every delete action resets
    /// the pending transmission before any lifecycle handling, so a slow or
    /// racy client's eventual final continuation chunk (arriving for a
    /// transmission the delete already abandoned) is a pure no-op, not a
    /// resurrection.
    @MainActor
    func testRemoteKittyImageCaptureDeleteAbortsPendingTransmissionPreventingLateFinalize() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        let splitIndex = base64.index(base64.startIndex, offsetBy: base64.count / 2)
        let firstHalf = String(base64[..<splitIndex])
        let secondHalf = String(base64[splitIndex...])

        // Begin an `m=1` chunked transmission but never send its final chunk.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=70,m=1", base64Payload: firstHalf
        )[...])
        XCTAssertNil(capture.currentVersion(for: 70))

        // A delete arrives mid-transmission — it must reset the pending
        // transmission before any lifecycle handling.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=A")[...])

        // The final `m=0` continuation chunk for the now-abandoned
        // transmission still arrives: it must be a no-op, never finalizing
        // and creating a version for id 70.
        capture.ingest(remoteKittyFrameBytes(control: "m=0", base64Payload: secondHalf)[...])
        XCTAssertNil(capture.currentVersion(for: 70))
        XCTAssertNil(capture.imageData(imageId: 70, version: 1))

        // Confirmed by version allocation too: the interrupted transmission
        // never consumed a version counter — a fresh, complete transmission
        // for a different id still gets version 1, not 2.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=71", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 71), 1)
    }

    /// Finding #2: `a=T` (transmit + display) always activates a placement;
    /// `a=t` (transmit only) stores new bytes/version but never activates a
    /// placement on its own — it only ever preserves whatever activation
    /// state already existed.
    @MainActor
    func testRemoteKittyImageCaptureTransmitOnlyNeverActivatesButPreservesExistingActivation() {
        let capture = remoteKittyTestCapture()
        let first = remoteKittyTestPNGBytes(width: 2, height: 2)
        let second = remoteKittyTestPNGBytes(width: 3, height: 3)

        // `a=T` activates immediately.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=80", base64Payload: first.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 80), 1)

        // Deactivate the placement; retained bytes are left untouched.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=80")[...])
        XCTAssertNil(capture.currentVersion(for: 80))

        // `a=t` (transmit-only) stores a *new* version but must never itself
        // (re)activate a placement that isn't already active.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=80", base64Payload: second.base64EncodedString()
        )[...])
        XCTAssertNil(capture.currentVersion(for: 80))
        // ...yet the new bytes were indeed stored, fetchable by direct version.
        XCTAssertEqual(capture.imageData(imageId: 80, version: 2), second)

        // Conversely, an id whose placement is already active: `a=t` on it
        // preserves that existing activity while updating to the new version.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=81", base64Payload: first.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 81), 3)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=81", base64Payload: second.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 81), 4)
    }

    /// Finding #3: `a=p,U=1,i=<id>` re-places using bytes already retained
    /// from a prior transmission — no new payload/version — reactivating the
    /// placement (and thus scan-discoverable screen metadata) for an id
    /// whose placement was previously deleted but whose data is still
    /// grace-retained.
    @MainActor
    func testRemoteKittyImageCapturePlacementReactivatesUsingRetainedBytes() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=90", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 90), 1)
        let afterT = capture.imageAvailabilityGeneration

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=90")[...])
        XCTAssertNil(capture.currentVersion(for: 90))
        let afterDelete = capture.imageAvailabilityGeneration
        XCTAssertNotEqual(afterDelete, afterT)

        // `a=p,U=1,i=90` re-places using the bytes already retained — no new
        // transmission/version, yet the placement (and thus scan metadata)
        // comes back.
        capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=90")[...])
        XCTAssertEqual(capture.currentVersion(for: 90), 1)
        XCTAssertNotEqual(capture.imageAvailabilityGeneration, afterDelete)

        // Re-placing an already-advertised id a second time changes nothing a
        // scan would discover, so the generation must not bump again (no
        // double-bump, finding #6).
        let afterReplace = capture.imageAvailabilityGeneration
        capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=90")[...])
        XCTAssertEqual(capture.imageAvailabilityGeneration, afterReplace)
    }

    /// Finding #4: a scoped `d=i,i=<id>,p=<placement>` delete must hide only
    /// that one placement of a shared image id — never over-delete sibling
    /// placements of the same id — and `d=i` without `p=` still removes every
    /// placement's activity for that id.
    @MainActor
    func testRemoteKittyImageCaptureScopedPlacementDeleteHidesOnlyThatPlacementNotSiblings() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        // Two distinct, explicitly-placed placements of the *same* image id.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=95,p=1", base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=95,p=2", base64Payload: png.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 95, placementId: 1), 2)
        XCTAssertEqual(capture.currentVersion(for: 95, placementId: 2), 2)

        // Deleting placement 1 alone must never disturb placement 2.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=95,p=1")[...])
        XCTAssertNil(capture.currentVersion(for: 95, placementId: 1))
        XCTAssertEqual(capture.currentVersion(for: 95, placementId: 2), 2)

        // `d=i` without `p=` removes *all* remaining activity for the id.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=95")[...])
        XCTAssertNil(capture.currentVersion(for: 95, placementId: 2))
    }

    /// Finding: an *uppercase* `d=I,i=<id>,p=<placement>` must mirror
    /// SwiftTerm's own placement scoping (`deletePlacementsByImageId` +
    /// `cleanupUnusedKittyImages`) — remove only the named placement's
    /// activity first, then free the underlying retained bytes/versions only
    /// if *no* sibling placement of the same image id is still active
    /// afterward. While a sibling survives, the data (and the sibling's own
    /// current version) must stay retained and advertised; only once the
    /// final sibling is also scoped-deleted does the data actually go away.
    @MainActor
    func testRemoteKittyImageCaptureUppercaseScopedPlacementDeleteFreesDataOnlyWhenNoSiblingPlacementsRemain() throws {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        // Two distinct, explicitly-placed placements of the same image id —
        // exactly like the lowercase-scoping test above, but exercising the
        // uppercase (data-freeing) delete mode instead.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=97,p=1", base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=97,p=2", base64Payload: png.base64EncodedString()
        )[...])
        let version = try XCTUnwrap(capture.currentVersion(for: 97, placementId: 2))
        XCTAssertEqual(capture.currentVersion(for: 97, placementId: 1), version)
        XCTAssertEqual(capture.imageData(imageId: 97, version: version), png)
        let generationAfterRetains = capture.imageAvailabilityGeneration

        // Deleting placement 1 via the uppercase, data-freeing mode must
        // still leave placement 2 (the sibling) — and the underlying
        // bytes/current version it depends on — completely untouched, since
        // freeing data must wait until *no* placement references it any
        // more. The generation must bump exactly once for this change
        // (placement 1 stopped being advertised).
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=97,p=1")[...])
        XCTAssertNil(capture.currentVersion(for: 97, placementId: 1))
        XCTAssertEqual(capture.currentVersion(for: 97, placementId: 2), version)
        XCTAssertEqual(capture.imageData(imageId: 97, version: version), png)
        let generationAfterFirstPlacementDelete = capture.imageAvailabilityGeneration
        XCTAssertNotEqual(generationAfterFirstPlacementDelete, generationAfterRetains)

        // Deleting the final surviving sibling (placement 2) must now also
        // free the retained bytes/version, since no active placement of
        // this image id remains afterward — exactly one more generation
        // bump for this second advertised change.
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=97,p=2")[...])
        XCTAssertNil(capture.currentVersion(for: 97, placementId: 2))
        XCTAssertNil(capture.imageData(imageId: 97, version: version))
        XCTAssertNotEqual(capture.imageAvailabilityGeneration, generationAfterFirstPlacementDelete)
    }

    /// The pending-transmission-reset guarantee (finding #1) must still hold
    /// for the newly-scoped uppercase `d=I,...,p=` path too: an in-flight
    /// `m=1` chunked transmission is abandoned by *any* delete, including
    /// one scoped to a single sibling placement of a different image id.
    @MainActor
    func testRemoteKittyImageCaptureUppercaseScopedPlacementDeleteAbortsPendingTransmission() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        let splitIndex = base64.index(base64.startIndex, offsetBy: base64.count / 2)
        let firstHalf = String(base64[..<splitIndex])
        let secondHalf = String(base64[splitIndex...])

        // A sibling placement so the scoped uppercase delete below doesn't
        // free any data (proving the pending-transmission reset happens
        // independent of whether data ends up freed).
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=98,p=1", base64Payload: base64
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=98,p=2", base64Payload: base64
        )[...])

        // Begin an unrelated `m=1` chunked transmission but never send its
        // final chunk.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=99,m=1", base64Payload: firstHalf
        )[...])
        XCTAssertNil(capture.currentVersion(for: 99))

        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=98,p=1")[...])

        // The abandoned transmission's late final chunk must be a no-op.
        capture.ingest(remoteKittyFrameBytes(control: "m=0", base64Payload: secondHalf)[...])
        XCTAssertNil(capture.currentVersion(for: 99))
        XCTAssertNil(capture.imageData(imageId: 99, version: 3))
    }

    /// Finding #5: wildcard/exact/deleted-placement lifecycle state must stay
    /// bounded — pruned in lockstep with retained-entry eviction — so a
    /// long-lived session that churns many distinct image ids through the
    /// grace cache never accumulates unbounded lifecycle-activity state for
    /// ids it can no longer even serve data for.
    @MainActor
    func testRemoteKittyImageCaptureLifecycleStateStaysBoundedAcrossManyEvictedIds() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // Churn far more distinct wildcard-active ids through than the local
        // retained-entry bound (16) so most of them are evicted from the
        // grace cache entirely.
        for id: UInt32 in 1 ... 200 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(id)", base64Payload: base64
            )[...])
        }
        XCTAssertLessThanOrEqual(capture.lifecycleActivityStateCountForTesting, 16)
        XCTAssertGreaterThan(capture.lifecycleActivityStateCountForTesting, 0)

        // Also churn many ids that additionally accumulate a scoped
        // per-placement deletion exception (populating `deletedPlacements`
        // alongside the wildcard entry) through eviction — up to two
        // lifecycle-state entries per id, still bounded to the entry cap.
        for id: UInt32 in 1_000 ... 1_200 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(id)", base64Payload: base64
            )[...])
            capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=\(id),p=1")[...])
        }
        XCTAssertLessThanOrEqual(capture.lifecycleActivityStateCountForTesting, 32)
    }

    @MainActor
    func testRemoteKittyImageCaptureEnforcesEntryCountBound() {
        let capture = remoteKittyTestCapture()
        for imageId: UInt32 in 1 ... 17 {
            let png = remoteKittyTestPNGBytes(width: 2, height: 2)
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId)",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        // Only the 16 most-recently-retained entries survive; the oldest (id 1)
        // was evicted to enforce the <=16-entry grace-cache bound.
        XCTAssertNil(capture.currentVersion(for: 1))
        for imageId: UInt32 in 2 ... 17 {
            XCTAssertNotNil(capture.currentVersion(for: imageId), "id \(imageId)")
        }
    }

    /// Finding: this instance's own *local* "prefer evicting superseded
    /// entries" victim selection (`enforceLocalBounds`/`pickEvictionVictim`)
    /// must also be placement-agnostic via `isCurrentlyAdvertised`, not a
    /// bare `latestVersion` comparison — otherwise a fully-inactive "ghost"
    /// entry (an id whose only retained version is still `latestVersion`,
    /// but whose placement was deleted so nothing can discover it any more)
    /// is indistinguishable from a genuinely current one, and the fallback
    /// (`order.first`) can end up sacrificing the oldest *actually visible*
    /// entry instead of the ghost that's actually obsolete.
    @MainActor
    func testRemoteKittyImageCapturePrefersEvictingGhostOverCurrentLocallyEvenWhenCurrentOnlyAtNonDefaultPlacement() throws {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // Oldest entry: genuinely current via the default placement. Must
        // survive — it's actually still discoverable by a scan.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1", base64Payload: base64
        )[...])
        let keepVersion = try XCTUnwrap(capture.currentVersion(for: 1))

        // Second-oldest entry: a "ghost" — its data is still retained (and
        // still `latestVersion`, since no second version was ever
        // transmitted), but its only placement was explicitly deleted, so
        // no scan can discover it any more. This is the entry that must
        // actually be evicted first, ahead of anything still visible.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=2", base64Payload: base64
        )[...])
        let ghostVersion = try XCTUnwrap(capture.currentVersion(for: 2))
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=2")[...])
        XCTAssertNil(capture.currentVersion(for: 2))
        XCTAssertEqual(capture.imageData(imageId: 2, version: ghostVersion), png)

        // Third entry: current, but *only* advertised via explicit
        // placement 5 — never the default placement. Must never be treated
        // as fair game for eviction just because it isn't shown via
        // placement 0.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=3,p=5", base64Payload: base64
        )[...])
        let nonDefaultVersion = try XCTUnwrap(capture.currentVersion(for: 3, placementId: 5))

        // Fill up to the 16-entry local bound with ordinary, currently
        // advertised filler ids (4 ... 16 inclusive is 13 more, for 16
        // total: ids 1, 2, 3, 4 ... 16).
        for imageId: UInt32 in 4 ... 16 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
            )[...])
        }

        // One more entry breaches the 16-entry bound, forcing exactly one
        // eviction.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=17", base64Payload: base64
        )[...])

        // The ghost (id 2) — not the oldest-but-genuinely-current id 1, nor
        // the current-only-at-placement-5 id 3 — must be the one reclaimed.
        XCTAssertNil(capture.imageData(imageId: 2, version: ghostVersion))
        XCTAssertEqual(capture.currentVersion(for: 1), keepVersion)
        XCTAssertEqual(capture.imageData(imageId: 1, version: keepVersion), png)
        XCTAssertEqual(capture.currentVersion(for: 3, placementId: 5), nonDefaultVersion)
        XCTAssertEqual(capture.imageData(imageId: 3, version: nonDefaultVersion), png)
    }

    /// A single *retained* image id can still drive `exactActivePlacements`
    /// unboundedly large on its own via many distinct placement ids, since
    /// none of that touches the number of distinct retained ids the
    /// grace-cache entry bound above guards. `a=t` (transmit-only) retains
    /// the bytes without activating anything, so every subsequent
    /// `a=p,p=<n>` below creates a genuinely new — never wildcard-redundant
    /// — exact-active entry, proving `makeRoomForPlacementActivityEntry`
    /// bounds the combined exact+deleted count even when every entry
    /// belongs to one id. Also proves the fail-closed pruning it triggers is
    /// deterministic (an identical replay reaches an identical final state)
    /// and never crashes, and that a later unscoped retransmit (`a=T`, no
    /// `p=`) still fully restores wildcard activity afterward regardless of
    /// how much pruning the preceding churn triggered.
    @MainActor
    func testRemoteKittyImageCaptureExactPlacementChurnForOneImageIdStaysBounded() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        let imageId: UInt32 = 500

        capture.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        XCTAssertNil(capture.currentVersion(for: imageId, placementId: 1))

        // Churn far more distinct placement ids for this *one* retained
        // image id than the activity cap via `a=p,p=<n>` — never touching
        // the grace-cache entry/byte bounds, which govern distinct retained
        // ids/bytes, not placement-activity entries. `lifecycleActivityStateCountForTesting`
        // combines the exact/deleted cap with `wildcardActiveImageIds`
        // (separately bounded by the retained-entry cap, 16 here); this id
        // never goes wildcard-active in this test, so 256 alone bounds it,
        // but asserting against the documented overall ceiling (cap +
        // bounded wildcards) keeps this robust to that detail.
        for placementId: UInt32 in 1 ... 600 {
            capture.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=\(imageId),p=\(placementId)")[...])
            XCTAssertLessThanOrEqual(capture.lifecycleActivityStateCountForTesting, 256 + 16, "placementId \(placementId)")
        }
        // The most recent activation must still have survived the churn —
        // fail-closed pruning drops *older* entries to make room, never the
        // one the caller is actively trying to add.
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 600), 1)

        // Deterministic: replaying the exact same churn from a fresh
        // capture reaches the exact same final advertised state and entry
        // count.
        let replay = remoteKittyTestCapture()
        replay.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        for placementId: UInt32 in 1 ... 600 {
            replay.ingest(remoteKittyFrameBytes(control: "a=p,U=1,i=\(imageId),p=\(placementId)")[...])
        }
        XCTAssertEqual(replay.currentVersion(for: imageId, placementId: 600), 1)
        XCTAssertEqual(replay.lifecycleActivityStateCountForTesting, capture.lifecycleActivityStateCountForTesting)

        // A later unscoped retransmit (`a=T`, no explicit `p=`) still fully
        // restores wildcard activity for every placement of this id — the
        // underlying retained data was never touched by any of the
        // activity-only churn above, only re-transmitted here to also bump
        // the version, so both a placement id the churn above visited and
        // one it never did are advertised again identically.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 1), 2)
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 12_345), 2)
    }

    /// The `deletedPlacements` counterpart of the churn above: many distinct
    /// scoped `d=i,i=<id>,p=<n>` deletes under one wildcard-active image id
    /// each create a fresh deletion-exception entry, so this alone must
    /// stay bounded too — independent of, and via the same fail-closed
    /// pruning as, the exact-active-entry churn covered above.
    @MainActor
    func testRemoteKittyImageCaptureScopedDeleteChurnForOneImageIdStaysBounded() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        let imageId: UInt32 = 600

        // `a=T` with no explicit `p=` makes every placement of this id
        // wildcard-active.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 1), 1)

        // Scoped-delete far more distinct placement ids under the same
        // wildcard-active image id than the activity cap — each is a fresh
        // `deletedPlacements` exception rather than a distinct retained
        // image id. `lifecycleActivityStateCountForTesting` also includes
        // this id's own single `wildcardActiveImageIds` entry (separately
        // bounded by the retained-entry cap, 16 here), so the overall
        // ceiling asserted here is the documented cap-plus-bounded-
        // wildcards total, never just the exact/deleted cap alone.
        for placementId: UInt32 in 1 ... 600 {
            capture.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=\(imageId),p=\(placementId)")[...])
            XCTAssertLessThanOrEqual(capture.lifecycleActivityStateCountForTesting, 256 + 16, "placementId \(placementId)")
        }
        // Every deleted placement id must remain non-advertised — the whole
        // point of the delete — even after fail-closed pruning reset this
        // id's wildcard activity entirely partway through the churn.
        XCTAssertNil(capture.currentVersion(for: imageId, placementId: 600))
        XCTAssertNil(capture.currentVersion(for: imageId, placementId: 1))

        // Deterministic: replaying the exact same churn reaches the exact
        // same final advertised state and entry count.
        let replay = remoteKittyTestCapture()
        replay.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        for placementId: UInt32 in 1 ... 600 {
            replay.ingest(remoteKittyFrameBytes(control: "a=d,d=i,i=\(imageId),p=\(placementId)")[...])
        }
        XCTAssertNil(replay.currentVersion(for: imageId, placementId: 600))
        XCTAssertEqual(replay.lifecycleActivityStateCountForTesting, capture.lifecycleActivityStateCountForTesting)

        // Retransmit (`a=T`, no explicit `p=`) still restores wildcard
        // activity for every placement, including ones this loop
        // scoped-deleted — a fresh unscoped activation supersedes every
        // prior deletion exception, and the underlying retained data was
        // never touched by any of the activity-only churn above.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
        )[...])
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 600), 2)
        XCTAssertEqual(capture.currentVersion(for: imageId, placementId: 1), 2)
    }

    // MARK: - Remote Kitty per-capture epoch (finding #2: version uniqueness across lifetimes)

    /// A session's terminal capture is recreated across the app's lifetime
    /// (e.g. a terminal is torn down and rebuilt), and each instance restarts
    /// its own monotonic counter at 1 — so without a per-instance epoch, a
    /// recreated capture would immediately reissue version 1 for whatever
    /// image id it captures first, exactly colliding with a stale cached
    /// fetch URL (`?i=<id>&v=1`) a client still holds from the *previous*
    /// instance. Distinct epochs in the version's high 32 bits make that
    /// impossible even when both instances retain the very same image id.
    @MainActor
    func testRemoteKittyImageCaptureDistinctEpochsNeverCollideAcrossRecreatedCaptures() throws {
        let sharedBudget = RemoteKittyImageCaptureBudget()
        let firstLifetime = RemoteKittyImageCapture(epoch: 0xAAAA_AAAA, budget: sharedBudget)
        let secondLifetime = RemoteKittyImageCapture(epoch: 0xBBBB_BBBB, budget: sharedBudget)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // The exact same conceptual session/id, captured twice across two
        // separate "lifetimes" (e.g. the terminal was closed and reopened).
        firstLifetime.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=50", base64Payload: base64
        )[...])
        secondLifetime.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=50", base64Payload: base64
        )[...])

        let firstVersion = try XCTUnwrap(firstLifetime.currentVersion(for: 50))
        let secondVersion = try XCTUnwrap(secondLifetime.currentVersion(for: 50))
        XCTAssertNotEqual(firstVersion, secondVersion)
        // The high 32 bits are exactly each instance's injected epoch...
        XCTAssertEqual(firstVersion >> 32, 0xAAAA_AAAA)
        XCTAssertEqual(secondVersion >> 32, 0xBBBB_BBBB)
        // ...and the low 32 bits (the monotonic counter) are identical across
        // both instances (both are each instance's very first retain) —
        // proving it's specifically the epoch, not some other incidental
        // difference, that prevents the collision.
        XCTAssertEqual(firstVersion & 0xFFFF_FFFF, secondVersion & 0xFFFF_FFFF)

        // Both instances' data for id 50 is independently addressable by its
        // own exact (id, version) pair — the exact-version endpoint contract
        // (finding #7) is unaffected by epoch injection.
        XCTAssertEqual(firstLifetime.imageData(imageId: 50, version: firstVersion), png)
        XCTAssertEqual(secondLifetime.imageData(imageId: 50, version: secondVersion), png)
        XCTAssertNil(firstLifetime.imageData(imageId: 50, version: secondVersion))
        XCTAssertNil(secondLifetime.imageData(imageId: 50, version: firstVersion))
    }

    /// Production never injects an explicit epoch (`RemoteKittyImageCapture()`
    /// defaults to a fresh random one per instance), so two independently
    /// constructed instances must not collide either, with overwhelming
    /// probability, exactly as real terminal-recreation would exercise it.
    @MainActor
    func testRemoteKittyImageCaptureDefaultRandomEpochsDifferAcrossInstances() {
        let firstEpoch = RemoteKittyImageCapture().epochForTesting
        let secondEpoch = RemoteKittyImageCapture().epochForTesting
        XCTAssertNotEqual(firstEpoch, secondEpoch)
    }

    // MARK: - Remote Kitty process-wide capture budget (finding #1: global memory bound)

    /// Many terminals (many `RemoteKittyImageCapture` instances) sharing one
    /// budget must never collectively retain more than the shared bound, even
    /// though each instance's own local cap (16 entries / 8 MiB) alone would
    /// allow far more once multiplied across enough open terminals.
    @MainActor
    func testRemoteKittyImageCaptureBudgetBoundsTotalEntriesAcrossManyCaptureInstances() {
        let budget = RemoteKittyImageCaptureBudget(maxTotalBytes: 32 * 1_024 * 1_024, maxTotalEntries: 32)
        let captures = (0 ..< 4).map { RemoteKittyImageCapture(epoch: UInt32($0), budget: budget) }
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // Round-robin 10 images into each of 4 captures: 40 retained entries
        // process-wide, well past the local per-capture cap's math (4 * 16 =
        // 64 would "fit" locally) but the *shared* 32-entry cap must still
        // hold globally.
        for imageId: UInt32 in 1 ... 10 {
            for capture in captures {
                capture.ingest(remoteKittyFrameBytes(
                    control: "a=T,f=100,t=d,U=1,i=\(imageId)", base64Payload: base64
                )[...])
            }
        }

        XCTAssertLessThanOrEqual(budget.totalEntries, budget.maxTotalEntries)
        XCTAssertLessThanOrEqual(budget.totalBytes, budget.maxTotalBytes)

        // Every capture's own most-recently-retained ("current", i.e. still
        // visible to a live scan) image for id 10 survived the global
        // eviction — the whole point of the bound is to reclaim old/obsolete
        // data, never the image a client is currently looking at.
        for capture in captures {
            XCTAssertNotNil(capture.currentVersion(for: 10))
        }
    }

    /// When the shared bound is exceeded, a still-current entry from an
    /// *older* capture must survive while a *newer* but already-superseded
    /// entry from a different capture is evicted first — global eviction
    /// prioritizes "is this obsolete anywhere" over raw insertion order.
    @MainActor
    func testRemoteKittyImageCaptureBudgetPrefersEvictingSupersededOverCurrentGlobally() throws {
        // A tiny budget (2 entries) makes the priority ordering exact and
        // trivial to assert against.
        let budget = RemoteKittyImageCaptureBudget(maxTotalBytes: 1024 * 1024, maxTotalEntries: 2)
        let captureA = RemoteKittyImageCapture(epoch: 0x1, budget: budget)
        let captureB = RemoteKittyImageCapture(epoch: 0x2, budget: budget)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        func retain(_ capture: RemoteKittyImageCapture, id: UInt32) {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(id)", base64Payload: base64
            )[...])
        }

        // Oldest, and still current for B: B/id=100 v1.
        retain(captureB, id: 100)
        let bVersion1 = try XCTUnwrap(captureB.currentVersion(for: 100))
        // A/id=200 v1: will be superseded a moment later by A/id=200 v2.
        retain(captureA, id: 200)
        let aVersion1 = try XCTUnwrap(captureA.currentVersion(for: 200))
        // A/id=200 v2 supersedes v1 above — now A/id=200 v1 is obsolete
        // (still globally registered until the bound forces eviction, but no
        // longer `currentVersion` for id 200).
        retain(captureA, id: 200)
        let aVersion2 = try XCTUnwrap(captureA.currentVersion(for: 200))
        XCTAssertNotEqual(aVersion1, aVersion2)

        // At this point 3 entries are registered against a 2-entry bound:
        // B/100 v1 (oldest, current), A/200 v1 (superseded), A/200 v2
        // (newest, current). The superseded A/200 v1 must be the one evicted
        // — not the older-but-still-current B/100 v1.
        XCTAssertLessThanOrEqual(budget.totalEntries, 2)
        XCTAssertEqual(captureB.currentVersion(for: 100), bVersion1)
        XCTAssertEqual(captureB.imageData(imageId: 100, version: bVersion1), png)
        XCTAssertEqual(captureA.currentVersion(for: 200), aVersion2)
        XCTAssertEqual(captureA.imageData(imageId: 200, version: aVersion2), png)
        // The superseded version was reclaimed specifically via the global
        // budget's eviction callback (`evictForBudget`), not merely absent.
        XCTAssertNil(captureA.imageData(imageId: 200, version: aVersion1))
    }

    /// Finding: `RemoteKittyImageCaptureBudget`'s "prefer evicting superseded
    /// entries" victim selection must be placement-agnostic. Before
    /// `isCurrentlyAdvertised`, it asked `owner.currentVersion(for:
    /// entry.imageId)` — which only ever checks the Kitty spec's implicit
    /// *default* placement (`0`) — so an id shown only via some other
    /// explicit placement (`a=T,p=5`) looked entirely non-current and got
    /// evicted ahead of a genuinely obsolete version elsewhere in the
    /// process, purely because its own placement wasn't the default one.
    @MainActor
    func testRemoteKittyImageCaptureBudgetPrefersEvictingSupersededOverCurrentGloballyWhenCurrentOnlyAtNonDefaultPlacement() throws {
        // Only one eviction is needed (4 registered entries against a
        // 3-entry bound) so the single victim chosen unambiguously proves
        // which entry the selection logic actually preferred.
        let budget = RemoteKittyImageCaptureBudget(maxTotalBytes: 1024 * 1024, maxTotalEntries: 3)
        let captureA = RemoteKittyImageCapture(epoch: 0x1, budget: budget)
        let captureB = RemoteKittyImageCapture(epoch: 0x2, budget: budget)
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()

        // Oldest: B/id=100, current via the default placement.
        captureB.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=100", base64Payload: base64
        )[...])
        let bVersion = try XCTUnwrap(captureB.currentVersion(for: 100))

        // A/id=200: current, but *only* advertised via explicit placement 5
        // — never the default placement. Must never be picked as the
        // eviction victim just because it isn't shown via placement 0.
        captureA.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=200,p=5", base64Payload: base64
        )[...])
        let aVersion200 = try XCTUnwrap(captureA.currentVersion(for: 200, placementId: 5))

        // A/id=300 v1, immediately superseded by v2 below — the *only*
        // genuinely obsolete entry, and the one that must actually be
        // evicted.
        captureA.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=300", base64Payload: base64
        )[...])
        let aVersion300v1 = try XCTUnwrap(captureA.currentVersion(for: 300))
        captureA.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=300", base64Payload: base64
        )[...])
        let aVersion300v2 = try XCTUnwrap(captureA.currentVersion(for: 300))
        XCTAssertNotEqual(aVersion300v1, aVersion300v2)

        // 4 entries registered against a 3-entry bound: B/100 (current,
        // default placement), A/200 (current, placement 5 only), A/300 v1
        // (obsolete), A/300 v2 (current). Only A/300 v1 may be evicted.
        XCTAssertLessThanOrEqual(budget.totalEntries, 3)
        XCTAssertEqual(captureB.currentVersion(for: 100), bVersion)
        XCTAssertEqual(captureB.imageData(imageId: 100, version: bVersion), png)
        XCTAssertEqual(captureA.currentVersion(for: 200, placementId: 5), aVersion200)
        XCTAssertEqual(captureA.imageData(imageId: 200, version: aVersion200), png)
        XCTAssertEqual(captureA.currentVersion(for: 300), aVersion300v2)
        XCTAssertEqual(captureA.imageData(imageId: 300, version: aVersion300v2), png)
        XCTAssertNil(captureA.imageData(imageId: 300, version: aVersion300v1))
    }

    // MARK: - Remote Kitty process-wide pending (in-flight) byte budget (finding #1)

    /// Unlike retained data, in-flight/undecoded base64 accumulating toward a
    /// not-yet-finalized transmission was previously bounded only *locally*
    /// (8 MiB per capture instance) — so N busy terminals each mid-transmission
    /// could collectively pin N * 8 MiB, entirely unaccounted by the
    /// process-wide budget. `RemoteKittyImageCaptureBudget`'s pending-byte cap
    /// must bound that total across every capture instance sharing it, and
    /// every instance must still be able to complete a fresh, valid
    /// transmission afterward.
    @MainActor
    func testRemoteKittyImageCaptureBudgetBoundsPendingBytesAcrossManyCaptureInstances() throws {
        let budget = RemoteKittyImageCaptureBudget(
            maxTotalBytes: 32 * 1_024 * 1_024,
            maxTotalEntries: 32,
            maxTotalPendingBytes: 256 * 1_024
        )
        let captures = (0 ..< 4).map { RemoteKittyImageCapture(epoch: UInt32($0), budget: budget) }

        // Each capture starts (but never finishes) a transmission with a
        // 90 KiB first continuation chunk — individually far under the
        // per-instance local accumulated-base64 cap (8 MiB) *and* under the
        // 96 KiB raw-frame cap (so the frame reaches `appendPayload` at all),
        // so only the *shared* 256 KiB pending cap can bound this across all
        // 4 instances (4 * 90 KiB = 360 KiB would otherwise "fit" locally in
        // every one).
        let chunk = String(repeating: "A", count: 90 * 1_024)
        for capture in captures {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=1,m=1", base64Payload: chunk
            )[...])
        }

        // The shared pending budget never grows past its bound, even though
        // 4 captures collectively attempted to buffer 360 KiB worth of
        // in-flight chunks against a 256 KiB cap.
        XCTAssertLessThanOrEqual(budget.totalPendingBytes, budget.maxTotalPendingBytes)
        XCTAssertGreaterThan(budget.totalPendingBytes, 0)

        // Every capture still recovers: a fresh, valid, single-frame
        // transmission on each one (which first abandons whatever dangling
        // chunk it had, releasing that reservation) still completes and is
        // retained, proving the shared pending cap being hit didn't wedge
        // any instance's scanner. Each capture uses a distinct epoch, so the
        // assigned version differs per instance — read it back rather than
        // assuming any fixed number.
        for (index, capture) in captures.enumerated() {
            let recoveryId = UInt32(100 + index)
            let recoveryPng = remoteKittyTestPNGBytes(width: 2, height: 2)
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(recoveryId)", base64Payload: recoveryPng.base64EncodedString()
            )[...])
            let actualVersion = try XCTUnwrap(
                capture.currentVersion(for: recoveryId), "capture \(index) must recover"
            )
            XCTAssertEqual(capture.imageData(imageId: recoveryId, version: actualVersion), recoveryPng)
        }

        // Every dangling chunk was abandoned (superseded by each capture's
        // own fresh transmission above) and every fresh transmission
        // finalized — so no pending reservation is left outstanding anywhere.
        XCTAssertEqual(budget.totalPendingBytes, 0)
    }


    /// Every place an in-flight transmission can end — a fresh `a=T` that
    /// abandons a previous one, a local accumulated-bytes overflow, a
    /// successful or failed finalize, an explicit per-id delete, and a full
    /// clear — must release *exactly* the pending bytes it had reserved:
    /// never none (a leak) and never more than it actually reserved (double
    /// -releasing a sibling's reservation).
    @MainActor
    func testRemoteKittyImageCapturePendingBudgetReleasesExactlyOnEveryTransmissionEnd() {
        let budget = RemoteKittyImageCaptureBudget()
        let capture = RemoteKittyImageCapture(epoch: 0, budget: budget)

        // Begin: a fresh `a=T` abandoning a previous in-flight chunk must
        // release that previous reservation in full, never leaving both
        // reserved at once.
        capture.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=1,m=1", base64Payload: "AAAA")[...])
        XCTAssertEqual(budget.totalPendingBytes, 4)
        capture.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=2,m=1", base64Payload: "BBBB")[...])
        XCTAssertEqual(budget.totalPendingBytes, 4, "id 1's reservation must be fully released, not added to")

        // Overflow (a different capture's own local accumulated-bytes cap):
        // also releases in full, never touching this capture's own unrelated
        // reservation.
        let tight = RemoteKittyImageCapture(epoch: 1, budget: budget, maxAccumulatedBase64Bytes: 8)
        tight.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=3,m=1", base64Payload: "AAAA")[...])
        XCTAssertEqual(budget.totalPendingBytes, 4 + 4)
        tight.ingest(remoteKittyFrameBytes(
            control: "m=1", base64Payload: String(repeating: "C", count: 12)
        )[...])
        XCTAssertEqual(budget.totalPendingBytes, 4, "the overflowing capture's reservation must be fully released")

        // Finalize (successful or not): releases in full too.
        capture.ingest(remoteKittyFrameBytes(control: "m=0", base64Payload: "")[...])
        XCTAssertEqual(budget.totalPendingBytes, 0)

        // Explicit per-id delete of the still-in-flight image: releases too.
        capture.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=4,m=1", base64Payload: "DDDD")[...])
        XCTAssertEqual(budget.totalPendingBytes, 4)
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=I,i=4")[...])
        XCTAssertEqual(budget.totalPendingBytes, 0)

        // A full clear while mid-transmission: releases too.
        capture.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=5,m=1", base64Payload: "EEEE")[...])
        XCTAssertEqual(budget.totalPendingBytes, 4)
        capture.ingest(remoteKittyFrameBytes(control: "a=d,d=A")[...])
        XCTAssertEqual(budget.totalPendingBytes, 0)

        // The scanner is left fully functional after all of the above.
        let recovery = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=6", base64Payload: recovery.base64EncodedString()
        )[...])
        XCTAssertEqual(capture.currentVersion(for: 6), 1)
        XCTAssertEqual(budget.totalPendingBytes, 0)
    }

    /// Pending fairness: unlike the "reject the new reservation" behavior
    /// above (which only ever discards the *new* attempt), one stalled/never
    /// -finalized transfer must never be able to permanently monopolize the
    /// shared pending budget and starve every other terminal from ever
    /// completing a transmission. When a new reservation would overflow the
    /// bound, the oldest *other* in-flight owner is aborted first — safe
    /// unconditionally, since unvalidated pending bytes aren't real data
    /// anyone could be relying on yet — and the new reservation proceeds.
    @MainActor
    func testRemoteKittyImageCaptureBudgetPendingFairnessAbortsOldestOtherOwnerForNewReservation() throws {
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        // Comfortably enough room for B's whole transmission on its own, but
        // not enough for B's alongside A's still-stalled 50-byte reservation.
        let cap = base64.utf8.count + 10
        let budget = RemoteKittyImageCaptureBudget(maxTotalPendingBytes: cap)
        let captureA = RemoteKittyImageCapture(epoch: 0xA, budget: budget)
        let captureB = RemoteKittyImageCapture(epoch: 0xB, budget: budget)

        // A starts (but never finishes) a stalled transmission — comfortably
        // under the shared cap on its own.
        let stalledChunk = String(repeating: "A", count: 50)
        captureA.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,m=1", base64Payload: stalledChunk
        )[...])
        XCTAssertEqual(budget.totalPendingBytes, 50)

        // B starts its own, single-frame, ultimately-valid transmission whose
        // full payload doesn't fit *alongside* A's still-stalled reservation
        // — so A (the oldest *other* in-flight owner) is aborted to make
        // room, and B's own reservation still succeeds.
        captureB.ingest(remoteKittyFrameBytes(control: "a=T,f=100,t=d,U=1,i=2", base64Payload: base64)[...])

        // B completed successfully — its stalled sibling never monopolized
        // the shared budget. Each capture uses a distinct epoch, so read
        // back the actual assigned version rather than assuming any fixed
        // number.
        let versionB = try XCTUnwrap(captureB.currentVersion(for: 2), "B must complete despite A's stalled sibling")
        XCTAssertEqual(captureB.imageData(imageId: 2, version: versionB), png)

        // A was aborted: it never registers anything, even if it later tries
        // to "complete" its now-discarded chunk.
        XCTAssertNil(captureA.currentVersion(for: 1))
        captureA.ingest(remoteKittyFrameBytes(control: "m=0", base64Payload: "")[...])
        XCTAssertNil(captureA.currentVersion(for: 1))

        // The shared bound was never exceeded, and nothing is left
        // outstanding once both transmissions have ended.
        XCTAssertLessThanOrEqual(budget.totalPendingBytes, budget.maxTotalPendingBytes)
        XCTAssertEqual(budget.totalPendingBytes, 0)
    }

    /// When no *other* owner is in flight to sacrifice — the reserving
    /// owner is the only one with anything pending — a reservation that
    /// still can't fit must simply fail, exactly as before fairness
    /// eviction was added: there's nothing safe left to abort besides the
    /// reservation itself.
    @MainActor
    func testRemoteKittyImageCaptureBudgetPendingReservationFailsWhenOnlyCurrentOwnerRemains() {
        let budget = RemoteKittyImageCaptureBudget(maxTotalPendingBytes: 4)
        let capture = RemoteKittyImageCapture(epoch: 0, budget: budget)

        // A single chunk larger than the entire shared pending cap, with no
        // other owner in flight to sacrifice: nothing can be evicted to make
        // room, so the reservation itself must fail and the transmission is
        // abandoned rather than letting unaccounted memory grow.
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,m=1", base64Payload: "AAAAAAAAAA"
        )[...])
        XCTAssertEqual(budget.totalPendingBytes, 0)
        XCTAssertNil(capture.currentVersion(for: 1))
    }

    /// Release finding #4 (pending fairness fast-path): when the *reserving*
    /// owner's own request alone — its existing reservation plus the new
    /// bytes — already exceeds the entire shared bound, no amount of
    /// aborting *other* in-flight owners could ever make it fit. This must
    /// be checked, and the reservation rejected, *before* any other owner's
    /// in-flight transmission is touched — so an unsatisfiable request from
    /// one owner never collaterally evicts an innocent, well-behaved
    /// reservation belonging to a completely different owner.
    @MainActor
    func testRemoteKittyImageCaptureBudgetPendingFairnessFastPathPreservesInnocentOwnerForImpossibleReservation() throws {
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let base64 = png.base64EncodedString()
        // Comfortably enough room for A's whole (both-chunk) transmission,
        // but deliberately far smaller than the single, impossible chunk B
        // is about to request.
        let cap = base64.utf8.count + 20
        let budget = RemoteKittyImageCaptureBudget(maxTotalPendingBytes: cap)
        let captureA = RemoteKittyImageCapture(epoch: 0xA, budget: budget)
        let captureB = RemoteKittyImageCapture(epoch: 0xB, budget: budget)

        // A starts (but doesn't yet finish) a small, well-behaved stalled
        // transmission — its first chunk comfortably under the shared cap
        // on its own.
        let firstHalf = String(base64.prefix(base64.count / 2))
        let secondHalf = String(base64.dropFirst(firstHalf.count))
        captureA.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,m=1", base64Payload: firstHalf
        )[...])
        XCTAssertEqual(budget.totalPendingBytes, firstHalf.utf8.count)

        // B's own single chunk alone — with no prior reservation of its own
        // — already exceeds the *entire* shared cap, so no amount of
        // aborting *other* owners (i.e. A) could ever make it fit. The fast
        // path must reject it immediately, before ever touching A's
        // innocent reservation.
        let impossibleChunk = String(repeating: "B", count: cap + 50)
        captureB.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=2,m=1", base64Payload: impossibleChunk
        )[...])
        XCTAssertNil(captureB.currentVersion(for: 2), "B's own-alone-impossible reservation must fail")

        // A's innocent, well-behaved reservation must be completely
        // untouched by B's failed, unsatisfiable request.
        XCTAssertEqual(
            budget.totalPendingBytes, firstHalf.utf8.count,
            "an impossible request from another owner must never collaterally evict an innocent pending owner"
        )

        // A can still complete normally afterward, proving its reservation
        // was never aborted by B's failed attempt.
        captureA.ingest(remoteKittyFrameBytes(control: "m=0", base64Payload: secondHalf)[...])
        let versionA = try XCTUnwrap(
            captureA.currentVersion(for: 1),
            "A must still complete normally — its reservation was never touched by B's impossible request"
        )
        XCTAssertEqual(captureA.imageData(imageId: 1, version: versionA), png)
        XCTAssertEqual(budget.totalPendingBytes, 0)
    }

    // MARK: - AppModel.remoteScreen image placement attachment (live + history)

    @MainActor
    func testAppModelRemoteScreenAttachesLiveImagePlacementFromKittyCapture() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=55", base64Payload: png.base64EncodedString()
        )[...])
        // Enter the alternate screen buffer (live/terminal-scroll mode), home
        // the cursor, move to row index 2, and draw the placeholder grapheme a
        // real Kitty client would emit itself (virtual/unicode placement never
        // has the terminal draw it for us).
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let liveBytes = Array((
            "\u{1B}[?1049h\u{1B}[H\u{1B}[3;1H"
                + "\u{1B}[38;2;0;0;55m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
        ).utf8)
        controller.terminalView.consumeProcessOutput(liveBytes[...])

        // The production capture assigns a random per-instance epoch (finding
        // #2), so the resulting version is opaque here — read the version the
        // real capture assigned rather than assuming the legacy "1".
        let actualVersion = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 55))

        let screen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(screen.scrollMode, .terminal)
        XCTAssertEqual(screen.images, [RemoteTerminalImagePlacement(
            imageId: 55, contentVersion: actualVersion, line: 2, column: 0, rows: 1, columns: 4
        )])
    }

    /// End-to-end regression for the ghost-image bug: a real APC transmit
    /// followed by a real placeholder grid write (the exact same byte stream
    /// `ProjectsTerminalView.dataReceived` feeds to *both* the real,
    /// SwiftTerm-backed terminal (what Mac's own local rendering sees) and
    /// this session's `RemoteKittyImageCapture` (remote metadata)), then a
    /// lowercase Kitty delete that only retires the *placement*, never the
    /// underlying retained bytes. Deliberately leaves the placeholder
    /// characters sitting in the grid untouched after the delete (mirroring
    /// a real client that relies on the delete op itself, not clearing grid
    /// text, to stop display) — proving the fix gates on the capture's own
    /// active-placement tracking, not merely on whatever characters still
    /// happen to be in the grid. A subsequent retransmit reactivates it.
    @MainActor
    func testAppModelRemoteScreenClearsGhostPlacementAfterLowercaseDeleteAndReactivatesOnRetransmit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=91", base64Payload: png.base64EncodedString()
        )[...])
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let liveBytes = Array((
            "\u{1B}[?1049h\u{1B}[H\u{1B}[3;1H"
                + "\u{1B}[38;2;0;0;91m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
        ).utf8)
        controller.terminalView.consumeProcessOutput(liveBytes[...])

        let firstVersion = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 91))
        let initialScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        // Mac SwiftTerm and remote metadata agree the placement is up and
        // showing: both drive off the exact same `dataReceived` byte stream.
        XCTAssertEqual(initialScreen.images, [RemoteTerminalImagePlacement(
            imageId: 91, contentVersion: firstVersion, line: 2, column: 0, rows: 1, columns: 4
        )])

        // Lowercase 'i' delete: real clients send this to retire a placement.
        // The placeholder characters themselves are deliberately left in the
        // grid (never overwritten/erased) to prove the fix, not grid content,
        // is what stops the ghost.
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(control: "a=d,d=i,i=91")[...])

        // The exact retained version is still fetchable...
        XCTAssertEqual(
            controller.terminalView.kittyImageCapture.imageData(imageId: 91, version: firstVersion), png
        )
        // ...but it's no longer active, so both the capture's own metadata
        // and the next remote screen scan agree there's nothing to show —
        // an empty (not `nil`) images array, since this host always scans the
        // live/terminal screen.
        XCTAssertNil(controller.terminalView.kittyImageCapture.currentVersion(for: 91))
        let afterDeleteScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(afterDeleteScreen.images, [])

        // Retransmitting the same id reactivates it with a fresh version —
        // Mac SwiftTerm and remote metadata agree again, now that both the
        // placeholder grid cells (never removed) and an active capture
        // placement exist together.
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=91", base64Payload: png.base64EncodedString()
        )[...])
        let secondVersion = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 91))
        XCTAssertNotEqual(secondVersion, firstVersion)
        let reactivatedScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(reactivatedScreen.images, [RemoteTerminalImagePlacement(
            imageId: 91, contentVersion: secondVersion, line: 2, column: 0, rows: 1, columns: 4
        )])
    }

    /// Finding #4/#7 end-to-end: two distinct placements (`p=1`, `p=2`) of the
    /// *same* image id, each drawn at its own screen location via the exact
    /// same real byte stream fed to both the Mac's own SwiftTerm-backed
    /// terminal (underline color carries the placement id, mirroring
    /// SwiftTerm's own private placeholder decoder) and this session's
    /// `RemoteKittyImageCapture` (remote metadata). Deleting one placement's
    /// activity (`d=i,i=<id>,p=<placement>`) must hide only that one
    /// placeholder while the other, sharing the same image id, keeps being
    /// advertised — Mac and remote metadata agree at every step.
    @MainActor
    func testAppModelRemoteScreenTwoPlacementsSameImageDeleteOneHidesOnlyThatPlacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        // Transmit the same image id twice, once per explicit placement id —
        // both placements reference whatever bytes/version the id most
        // recently retained.
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=96,p=1", base64Payload: png.base64EncodedString()
        )[...])
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=96,p=2", base64Payload: png.base64EncodedString()
        )[...])

        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        // Placement 1 at row index 2, placement 2 at row index 4 — each
        // cell's foreground carries the shared image id (96), its underline
        // color the distinct placement id.
        let liveBytes = Array((
            "\u{1B}[?1049h\u{1B}[H\u{1B}[3;1H"
                + "\u{1B}[38;2;0;0;96m\u{1B}[58;2;0;0;1m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
                + "\u{1B}[5;1H"
                + "\u{1B}[38;2;0;0;96m\u{1B}[58;2;0;0;2m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
        ).utf8)
        controller.terminalView.consumeProcessOutput(liveBytes[...])

        let version = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 96, placementId: 1))
        XCTAssertEqual(controller.terminalView.kittyImageCapture.currentVersion(for: 96, placementId: 2), version)

        let initialScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        // Mac SwiftTerm and remote metadata agree: both placements are up
        // and showing, at their own distinct locations. The scanner's
        // deterministic sort (line, column, imageId) puts placement 1
        // (line 2) before placement 2 (line 4).
        XCTAssertEqual(initialScreen.images, [
            RemoteTerminalImagePlacement(imageId: 96, contentVersion: version, line: 2, column: 0, rows: 1, columns: 4),
            RemoteTerminalImagePlacement(imageId: 96, contentVersion: version, line: 4, column: 0, rows: 1, columns: 4),
        ])

        // Scoped delete: only placement 1 is targeted.
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(control: "a=d,d=i,i=96,p=1")[...])

        XCTAssertNil(controller.terminalView.kittyImageCapture.currentVersion(for: 96, placementId: 1))
        XCTAssertEqual(controller.terminalView.kittyImageCapture.currentVersion(for: 96, placementId: 2), version)

        // The placeholder grid cells for *both* placements are deliberately
        // left untouched (never overwritten/erased) — proving the fix gates
        // on the capture's own per-placement activity tracking, not on
        // grid content. Only placement 1 disappears from the scan; the
        // sibling placement sharing the same image id keeps being
        // advertised untouched.
        let afterDeleteScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(afterDeleteScreen.images, [RemoteTerminalImagePlacement(
            imageId: 96, contentVersion: version, line: 4, column: 0, rows: 1, columns: 4
        )])
    }

    @MainActor
    func testAppModelRemoteScreenDoesNotReuseStalePlacementsAcrossModes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=66", base64Payload: png.base64EncodedString()
        )[...])
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let liveBytes = Array((
            "\u{1B}[?1049h\u{1B}[H"
                + "\u{1B}[38;2;0;0;66m"
                + String(repeating: String(placeholder), count: 3)
                + "\u{1B}[0m"
        ).utf8)
        controller.terminalView.consumeProcessOutput(liveBytes[...])

        let liveScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(liveScreen.scrollMode, .terminal)
        XCTAssertEqual(liveScreen.images?.first?.imageId, 66)
        XCTAssertEqual(liveScreen.images?.first?.line, 0)

        // Leave the alternate buffer: the normal buffer never had the
        // placeholder written into it, so a fresh scan must NOT carry over the
        // live screen's placement — proving coordinates are recomputed per
        // screen rather than cached/reused across the live -> history switch.
        // A present-but-empty array (never `nil`): this host always scans the
        // full retained history, so an empty result is a definitive "nothing
        // found", not an older host omitting the field.
        controller.terminalView.consumeProcessOutput(Array("\u{1B}[?1049l".utf8)[...])
        let historyScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(historyScreen.scrollMode, .history)
        XCTAssertEqual(historyScreen.images, [])
    }

    /// Finding #6: a real incremental (`afterLine`-narrowed) history fetch
    /// whose emitted text window starts strictly *inside* a multi-row image
    /// component must still discover and emit the component's full bounds —
    /// including the rows above the window, which surface as a negative
    /// relative `line` — rather than only the portion that happens to fall
    /// inside the naive `[firstLine, ...)` text window.
    @MainActor
    func testAppModelRemoteScreenHistoryScanCrossesIncrementalWindowBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))
        let input = try XCTUnwrap(controller.terminalView.terminalInputStateSnapshot())
        let rows = input.dimensions.rows

        // Register the image's bytes with the capture — independent of what
        // gets written into the terminal's own grid below.
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=80", base64Payload: png.base64EncodedString()
        )[...])
        let version = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 80))

        // Never enters the alternate buffer, so every line below lands in the
        // normal/history buffer scanned by `captureHistory`. A 4-row
        // placeholder component (imageId 80) sits at absolute rows
        // `imageStartRow ..< imageStartRow + imageRowCount`, comfortably
        // surrounded by enough plain filler before and after to keep
        // `historyStartLine` at 0 (well under the 500-line scrollback) and to
        // guarantee `absoluteEnd` reaches past the incremental `afterLine`
        // computed below regardless of the view's actual row count.
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let imageStartRow = 40
        let imageRowCount = 4
        var script = ""
        for i in 0 ..< imageStartRow {
            script += "filler-\(i)\r\n"
        }
        for _ in 0 ..< imageRowCount {
            script += "\u{1B}[38;2;0;0;80m" + String(repeating: String(placeholder), count: 4) + "\u{1B}[0m\r\n"
        }
        for i in 0 ..< (rows + 20) {
            script += "filler-after-\(i)\r\n"
        }
        controller.terminalView.consumeProcessOutput(Array(script.utf8)[...])

        let initialScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(initialScreen.scrollMode, .history)
        XCTAssertTrue(initialScreen.reset)
        XCTAssertEqual(initialScreen.historyStartLine, 0)

        // Pick an `afterLine` (as a real client would send back its last-seen
        // absolute line) whose resulting window (`firstLine = afterLine -
        // rows`) starts two rows into the image component — so rows
        // `imageStartRow` and `imageStartRow + 1` are *above* the emitted
        // text window and would be missed entirely without the widened scan.
        let firstLineInsideImage = imageStartRow + 2
        let afterLine = firstLineInsideImage + rows
        let screen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: afterLine))
        XCTAssertEqual(screen.scrollMode, .history)
        XCTAssertFalse(screen.reset, "must be a genuine incremental fetch, not a reset-triggered full refetch")
        XCTAssertEqual(screen.firstLine, firstLineInsideImage)

        // The full 4-row component is still discovered — its top two rows
        // surface as a negative relative `line` since they fall above the
        // emitted window's `firstLine`.
        XCTAssertEqual(screen.images, [RemoteTerminalImagePlacement(
            imageId: 80,
            contentVersion: version,
            line: imageStartRow - firstLineInsideImage,
            column: 0,
            rows: imageRowCount,
            columns: 4
        )])
    }

    /// Finding #4: the history scan window must cover the *entire* retained
    /// history (`[historyStartLine, liveTopLine + rows)`), not just
    /// `terminal.rows` beyond the emitted text window on each side. An image
    /// component *taller than the viewport itself* proves this: with the
    /// old ±`terminal.rows` padding, an incremental fetch whose window starts
    /// more than `rows` rows below the component's top would have its top
    /// rows clipped from the scan entirely, corrupting the discovered
    /// bounding box (or losing rows from it) even though the component is
    /// still fully retained in scrollback.
    @MainActor
    func testAppModelRemoteScreenHistoryScanFindsImageTallerThanViewportAcrossIncrementalWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))
        let input = try XCTUnwrap(controller.terminalView.terminalInputStateSnapshot())
        let rows = input.dimensions.rows

        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=81", base64Payload: png.base64EncodedString()
        )[...])
        let version = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 81))

        // The placeholder component is twice as tall as the viewport itself
        // (`imageRowCount == rows * 2`), so no single `terminal.rows`
        // -widened window could ever cover it in full from an incremental
        // fetch anchored partway down its height.
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        let imageStartRow = 20
        let imageRowCount = rows * 2
        var script = ""
        for i in 0 ..< imageStartRow {
            script += "filler-\(i)\r\n"
        }
        for _ in 0 ..< imageRowCount {
            script += "\u{1B}[38;2;0;0;81m" + String(repeating: String(placeholder), count: 4) + "\u{1B}[0m\r\n"
        }
        for i in 0 ..< (rows + 20) {
            script += "filler-after-\(i)\r\n"
        }
        controller.terminalView.consumeProcessOutput(Array(script.utf8)[...])

        let initialScreen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(initialScreen.scrollMode, .history)
        XCTAssertEqual(initialScreen.historyStartLine, 0)

        // Anchor the incremental window `rows + 5` rows into the component
        // (not merely 2, as the sibling test above does) — deep enough that
        // the old `firstLine - terminal.rows` lower bound would land
        // *strictly inside* the component (5 rows below its top), clipping
        // those top 5 rows from the scan and corrupting the discovered
        // component's height/top instead of merely shifting where it
        // surfaces.
        let firstLineInsideImage = imageStartRow + rows + 5
        XCTAssertLessThan(firstLineInsideImage, imageStartRow + imageRowCount)
        let afterLine = firstLineInsideImage + rows
        let screen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: afterLine))
        XCTAssertEqual(screen.scrollMode, .history)
        XCTAssertFalse(screen.reset, "must be a genuine incremental fetch, not a reset-triggered full refetch")
        XCTAssertEqual(screen.firstLine, firstLineInsideImage)

        // The full, uncorrupted component — every one of its `rows * 2` rows,
        // including the ones far above the emitted text window — is still
        // discovered.
        XCTAssertEqual(screen.images, [RemoteTerminalImagePlacement(
            imageId: 81,
            contentVersion: version,
            line: imageStartRow - firstLineInsideImage,
            column: 0,
            rows: imageRowCount,
            columns: 4
        )])
    }




    // MARK: - Durable Kitty image persistence (RemoteKittyImageDiskStore)

    /// A fresh, test-isolated `RemoteKittyImageDiskStore` rooted at a unique
    /// temp directory, so no test can ever perturb (or be perturbed by)
    /// another test's — or the real app's — persisted state.
    private func makeIsolatedKittyImageDiskStore() -> (store: RemoteKittyImageDiskStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return (RemoteKittyImageDiskStore(root: root), root)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreRoundTripsExactEntriesAndDistinguishesCurrentFromGraceSelections() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString

        let gracePng = remoteKittyTestPNGBytes(width: 2, height: 2)
        let currentPng = remoteKittyTestPNGBytes(width: 4, height: 3)
        store.persistRetain(sessionId: sessionId, imageId: 42, version: 100, data: gracePng)
        store.persistRetain(sessionId: sessionId, imageId: 42, version: 101, data: currentPng)
        store.replaceCurrentSelections(
            sessionId: sessionId, imageId: 42,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 101, placementId: nil, rows: 1, columns: 4, x: nil, y: nil, z: nil
            )]
        )
        await store.barrierForTesting()

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.entries.map(\.version)), [100, 101], "both the grace and current version must survive")
        XCTAssertEqual(restored.entries.first { $0.version == 100 }?.data, gracePng)
        XCTAssertEqual(restored.entries.first { $0.version == 101 }?.data, currentPng)
        XCTAssertEqual(restored.currentSelections, [RemoteKittyRestoredSelection(
            imageId: 42, version: 101, placementId: nil, rows: 1, columns: 4, x: nil, y: nil, z: nil
        )], "only the current version is selected, never the grace one")
    }

    @MainActor
    func testRemoteKittyImageDiskStoreRejectsCorruptDataAtPersistTime() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }
        store.persistRetain(sessionId: "s", imageId: 1, version: 1, data: Data([0x00, 0x01, 0x02, 0x03]))
        await store.barrierForTesting()
        let count = await store.totalEntryCountForTesting()
        XCTAssertEqual(count, 0, "non-PNG bytes must never be written/manifested")
    }

    /// Corrupt/truncated PNGs must be structurally revalidated before ever
    /// being restored — reusing the same `RemoteKittyPNGValidation` a live
    /// transmission's decode already requires, never a weaker check.
    @MainActor
    func testRemoteKittyImageDiskStoreFailsClosedOnCorruptedBytesAtRestoreTime() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "s"
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        store.persistRetain(sessionId: sessionId, imageId: 9, version: 1, data: png)
        store.replaceCurrentSelections(
            sessionId: sessionId, imageId: 9,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await store.barrierForTesting()

        // Corrupt the bytes directly on disk — untrusted, even though the
        // manifest still references them.
        let path = store.dataFileURLForTesting(sessionId: sessionId, imageId: 9, version: 1)
        try Data([0xFF, 0xFF, 0xFF]).write(to: path)

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.currentSelections.isEmpty)

        // The corrupt entry/selection/file is pruned from the manifest for
        // good, not merely skipped for this one restore call.
        let stillExists = await store.entryExistsForTesting(sessionId: sessionId, imageId: 9, version: 1)
        XCTAssertFalse(stillExists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    /// The global cap (finding: hard process-wide disk bound) is enforced
    /// across every session combined, always sacrificing a superseded
    /// (non-current) entry before any current one — even one far older by
    /// insertion order.
    @MainActor
    func testRemoteKittyImageDiskStoreEnforcesGlobalEntryCapPreferringSupersededEviction() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0 ..< 31 {
            let sessionId = "current-\(i)"
            let png = remoteKittyTestPNGBytes(width: 2, height: 2)
            store.persistRetain(sessionId: sessionId, imageId: 1, version: 1, data: png)
            store.replaceCurrentSelections(
                sessionId: sessionId, imageId: 1,
                selections: [RemoteKittyPersistedPlacementSelection(
                    version: 1, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
                )]
            )
        }
        // One more session with both a superseded (grace) and a current
        // version — 33 entries total now, 1 over the cap.
        let victimSessionId = "victim"
        store.persistRetain(
            sessionId: victimSessionId, imageId: 1, version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        store.persistRetain(
            sessionId: victimSessionId, imageId: 1, version: 2,
            data: remoteKittyTestPNGBytes(width: 3, height: 3)
        )
        store.replaceCurrentSelections(
            sessionId: victimSessionId, imageId: 1,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 2, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await store.barrierForTesting()

        let totalEntries = await store.totalEntryCountForTesting()
        XCTAssertEqual(totalEntries, RemoteKittyImageDiskStore.maxTotalEntries)

        let graceStillExists = await store.entryExistsForTesting(
            sessionId: victimSessionId, imageId: 1, version: 1
        )
        XCTAssertFalse(graceStillExists, "the one superseded entry anywhere must be sacrificed first")
        let currentStillExists = await store.entryExistsForTesting(
            sessionId: victimSessionId, imageId: 1, version: 2
        )
        XCTAssertTrue(currentStillExists)
        for i in 0 ..< 31 {
            let exists = await store.entryExistsForTesting(sessionId: "current-\(i)", imageId: 1, version: 1)
            XCTAssertTrue(exists, "current entry \(i) must never be evicted while a superseded entry existed")
        }
    }

    @MainActor
    func testRemoteKittyImageDiskStoreRetainsNewCurrentEntryWhenAllExistingEntriesAreCurrent() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        for index in 0 ..< RemoteKittyImageDiskStore.maxTotalEntries {
            let sessionId = "current-\(index)"
            store.persistRetain(
                sessionId: sessionId,
                imageId: 1,
                version: 1,
                data: png,
                currentSelections: [RemoteKittyPersistedPlacementSelection(
                    version: 1,
                    placementId: nil,
                    rows: 1,
                    columns: 1,
                    x: nil,
                    y: nil,
                    z: nil
                )]
            )
        }
        let newestSession = "new-current"
        store.persistRetain(
            sessionId: newestSession,
            imageId: 2,
            version: 2,
            data: png,
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 2,
                placementId: nil,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await store.barrierForTesting()

        let totalEntries = await store.totalEntryCountForTesting()
        let oldestExists = await store.entryExistsForTesting(
            sessionId: "current-0",
            imageId: 1,
            version: 1
        )
        let newestExists = await store.entryExistsForTesting(
            sessionId: newestSession,
            imageId: 2,
            version: 2
        )
        XCTAssertEqual(totalEntries, RemoteKittyImageDiskStore.maxTotalEntries)
        XCTAssertFalse(oldestExists)
        XCTAssertTrue(newestExists)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreFailedReplacementWriteKeepsExistingEntries() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("data").path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        for index in 0 ..< RemoteKittyImageDiskStore.maxTotalEntries {
            store.persistRetain(
                sessionId: "current-\(index)",
                imageId: 1,
                version: 1,
                data: png,
                currentSelections: [RemoteKittyPersistedPlacementSelection(
                    version: 1,
                    placementId: nil,
                    rows: 1,
                    columns: 1,
                    x: nil,
                    y: nil,
                    z: nil
                )]
            )
        }
        await store.flush()

        let dataDir = root.appendingPathComponent("data")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDir.path)
        store.persistRetain(
            sessionId: "replacement",
            imageId: 2,
            version: 2,
            data: png,
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 2,
                placementId: nil,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await store.flush()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)

        let totalEntries = await store.totalEntryCountForTesting()
        let oldestExists = await store.entryExistsForTesting(
            sessionId: "current-0",
            imageId: 1,
            version: 1
        )
        let replacementExists = await store.entryExistsForTesting(
            sessionId: "replacement",
            imageId: 2,
            version: 2
        )
        XCTAssertEqual(totalEntries, RemoteKittyImageDiskStore.maxTotalEntries)
        XCTAssertTrue(oldestExists)
        XCTAssertFalse(replacementExists)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreDropsGlobalPressureMutationWithoutDisablingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(
            root: root,
            maxQueuedRetainBytes: 1,
            maxQueuedMutations: 1
        )
        let sessionId = "overloaded"
        store.persistRetain(
            sessionId: sessionId,
            imageId: 1,
            version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        await store.flush()

        XCTAssertFalse(store.isPersistenceDisabledForTesting(sessionId: sessionId))
        XCTAssertEqual(store.queuedRetainBytesForTesting, 0)
        let totalEntries = await store.totalEntryCountForTesting()
        XCTAssertEqual(totalEntries, 0)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreGlobalPressureFailClosesDestructiveMutation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store1 = RemoteKittyImageDiskStore(root: root)
        let sessionId = "destructive-pressure"
        store1.persistRetain(
            sessionId: sessionId,
            imageId: 1,
            version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2),
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: 1,
                placementId: nil,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await store1.flush()

        let store2 = RemoteKittyImageDiskStore(
            root: root,
            maxQueuedRetainBytes: RemoteKittyImageDiskStore.maxQueuedRetainBytes,
            maxQueuedMutations: 0
        )
        store2.replaceCurrentSelections(sessionId: sessionId, imageId: 1, selections: [])
        await store2.flush()

        let entryExists = await store2.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 1,
            version: 1
        )
        XCTAssertFalse(entryExists)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreRejectsOversizedManifestBeforeDecoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: RemoteKittyImageDiskStore.maxManifestBytes + 1)
            .write(to: root.appendingPathComponent("manifest.json"))

        let store = RemoteKittyImageDiskStore(root: root)
        store.activate()
        await store.flush()
        let totalEntries = await store.totalEntryCountForTesting()
        XCTAssertEqual(totalEntries, 0)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreNormalizesPersistedZeroPlacementId() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = "legacy-zero-placement"
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        let pathStore = RemoteKittyImageDiskStore(root: root)
        let dataURL = pathStore.dataFileURLForTesting(
            sessionId: sessionId,
            imageId: 1,
            version: 1
        )
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: dataURL)
        let manifest = """
        {
          "schemaVersion": 1,
          "entries": [{
            "sessionId": "\(sessionId)",
            "imageId": 1,
            "version": 1,
            "byteCount": \(png.count)
          }],
          "selections": [{
            "sessionId": "\(sessionId)",
            "imageId": 1,
            "version": 1,
            "placementId": 0,
            "rows": 1,
            "columns": 2
          }]
        }
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("manifest.json"))

        let store = RemoteKittyImageDiskStore(root: root)
        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(restored.currentSelections, [RemoteKittyRestoredSelection(
            imageId: 1,
            version: 1,
            placementId: nil,
            rows: 1,
            columns: 2,
            x: nil,
            y: nil,
            z: nil
        )])
    }

    @MainActor
    func testRemoteKittyImageDiskStoreDoesNotCleanDiskBeforePrimaryActivation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let orphan = dataDir.appendingPathComponent("orphan.png")
        try remoteKittyTestPNGBytes(width: 2, height: 2).write(to: orphan)

        let store = RemoteKittyImageDiskStore(root: root)
        await store.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: orphan.path))

        store.activate()
        await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    /// Startup (and restart) cleanup must be fail-closed against every kind
    /// of on-disk inconsistency at once: a corrupted entry, an orphan data
    /// file no manifest entry references, and a staging leftover from a
    /// crash mid-write.
    @MainActor
    func testRemoteKittyImageDiskStoreStartupCleanupRemovesOrphanCorruptAndStagingFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store1 = RemoteKittyImageDiskStore(root: root)
        let sessionId = "s"
        let goodPng = remoteKittyTestPNGBytes(width: 2, height: 2)
        let toBeCorruptedPng = remoteKittyTestPNGBytes(width: 3, height: 3)
        store1.persistRetain(sessionId: sessionId, imageId: 1, version: 1, data: goodPng)
        store1.persistRetain(sessionId: sessionId, imageId: 2, version: 1, data: toBeCorruptedPng)
        await store1.barrierForTesting()

        let corruptPath = store1.dataFileURLForTesting(sessionId: sessionId, imageId: 2, version: 1)
        try Data("not a png".utf8).write(to: corruptPath)

        let dataDir = root.appendingPathComponent("data", isDirectory: true)
        let orphanPath = dataDir.appendingPathComponent("orphan-never-in-any-manifest-entry.png")
        try goodPng.write(to: orphanPath)
        let stagingPath = dataDir.appendingPathComponent(".tmp-leftover-from-a-crash")
        try Data("partial write".utf8).write(to: stagingPath)

        // A fresh activated instance over the same root simulates the primary
        // process acquiring its single-instance lock on the next launch.
        let store2 = RemoteKittyImageDiskStore(root: root)
        store2.activate()
        await store2.barrierForTesting()

        let entry1Exists = await store2.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertTrue(entry1Exists)
        let entry2Exists = await store2.entryExistsForTesting(sessionId: sessionId, imageId: 2, version: 1)
        XCTAssertFalse(entry2Exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingPath.path))
    }

    /// Deliberate session destruction must synchronously tombstone before
    /// any other teardown, and the destroyed session's images must never
    /// again be resurrected by any later restore.
    @MainActor
    func testSessionArtifactsDestroyTombstonesSynchronouslyAndPreventsResurrection() async throws {
        let (store, root) = makeIsolatedKittyImageDiskStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        store.persistRetain(sessionId: sessionId, imageId: 1, version: 1, data: png)
        store.replaceCurrentSelections(
            sessionId: sessionId, imageId: 1,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await store.barrierForTesting()
        let existsBeforeDestroy = await store.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertTrue(existsBeforeDestroy)

        let cleanup = SessionArtifacts.destroyGracefully(
            sessionId: sessionId,
            kittyImageDiskStore: store
        )
        // The marker is written *synchronously* — asserted here with no
        // `await` at all, immediately after `destroyGracefully` returns.
        XCTAssertTrue(store.isTombstonedForTesting(sessionId: sessionId))
        cleanup.cancel()
        await cleanup.value

        await store.barrierForTesting()
        let restored = await store.restore(sessionId: sessionId)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.currentSelections.isEmpty)
        let existsAfterDestroy = await store.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertFalse(existsAfterDestroy)
        XCTAssertTrue(
            store.isTombstonedForTesting(sessionId: sessionId),
            "the marker may be removed after cleanup, but this process must keep rejecting late writes"
        )

        store.persistRetain(
            sessionId: sessionId,
            imageId: 2,
            version: 2,
            data: remoteKittyTestPNGBytes(width: 3, height: 3)
        )
        store.replaceCurrentSelections(
            sessionId: sessionId,
            imageId: 2,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 2, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await store.barrierForTesting()
        let lateEntryExists = await store.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 2,
            version: 2
        )
        XCTAssertFalse(
            lateEntryExists,
            "writes queued after completed cleanup must not resurrect a destroyed session"
        )
    }

    /// The tombstone marker must survive even an *immediate* app exit right
    /// after the synchronous write, before its enqueued async cleanup ever
    /// gets a chance to run — so the next launch's startup cleanup still
    /// finishes the job and can never resurrect the destroyed session.
    @MainActor
    func testRemoteKittyImageDiskStoreTombstoneSurvivesImmediateRestartBeforeAsyncCleanupCompletes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store1 = RemoteKittyImageDiskStore(root: root)
        let sessionId = "victim"
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        store1.persistRetain(sessionId: sessionId, imageId: 1, version: 1, data: png)
        store1.replaceCurrentSelections(
            sessionId: sessionId, imageId: 1,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: 1, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await store1.barrierForTesting()

        // Tombstone, but deliberately never await store1's own enqueued
        // cleanup — simulating a quit immediately after the synchronous
        // marker write.
        store1.tombstone(sessionId: sessionId)
        XCTAssertTrue(store1.isTombstonedForTesting(sessionId: sessionId))

        // A fresh store over the same root simulates the next app launch.
        let store2 = RemoteKittyImageDiskStore(root: root)
        store2.activate()
        await store2.barrierForTesting()
        let restored = await store2.restore(sessionId: sessionId)
        XCTAssertTrue(restored.entries.isEmpty)
        let existsAfterRestart = await store2.entryExistsForTesting(sessionId: sessionId, imageId: 1, version: 1)
        XCTAssertFalse(existsAfterRestart)
        XCTAssertFalse(
            store2.isTombstonedForTesting(sessionId: sessionId),
            "after startup finishes the durable purge, no old producer exists to resurrect it"
        )
    }

    @MainActor
    func testRemoteKittyImageDiskStoreKeepsTombstoneUntilFailedDeletionCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("data").path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let store1 = RemoteKittyImageDiskStore(root: root)
        let sessionId = "delete-failure"
        store1.persistRetain(
            sessionId: sessionId,
            imageId: 1,
            version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        await store1.flush()

        let dataDir = root.appendingPathComponent("data")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDir.path)
        store1.tombstone(sessionId: sessionId)
        await store1.flush()

        XCTAssertTrue(store1.tombstoneMarkerExistsForTesting(sessionId: sessionId))
        let entryRemainsAfterFailure = await store1.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 1,
            version: 1
        )
        XCTAssertTrue(entryRemainsAfterFailure)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDir.path)
        let store2 = RemoteKittyImageDiskStore(root: root)
        store2.activate()
        await store2.flush()

        XCTAssertFalse(store2.tombstoneMarkerExistsForTesting(sessionId: sessionId))
        let entryRemainsAfterRetry = await store2.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 1,
            version: 1
        )
        XCTAssertFalse(entryRemainsAfterRetry)
    }

    @MainActor
    func testRemoteKittyImageDiskStoreOrdinaryClearNeverRestoresUndeletableBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root.appendingPathComponent("data").path
            )
            try? FileManager.default.removeItem(at: root)
        }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "ordinary-clear"
        store.persistRetain(
            sessionId: sessionId,
            imageId: 1,
            version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        await store.flush()

        let dataDir = root.appendingPathComponent("data")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dataDir.path)
        store.persistClearSession(sessionId: sessionId)
        await store.flush()

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertTrue(restored.currentSelections.isEmpty)
    }

    // MARK: - Durable Kitty image persistence (RemoteKittyImageCapture restore API)

    @MainActor
    func testRemoteKittyImageCaptureRestoreInstallsEntriesAndCurrentSelectionBumpingGenerationOnce() {
        let capture = remoteKittyTestCapture()
        let genBefore = capture.imageAvailabilityGeneration
        let gracePng = remoteKittyTestPNGBytes(width: 2, height: 2)
        let currentPng = remoteKittyTestPNGBytes(width: 3, height: 3)

        capture.beginRestoring()
        XCTAssertTrue(capture.restoreEntry(imageId: 5, version: 100, data: gracePng))
        XCTAssertTrue(capture.restoreEntry(imageId: 5, version: 101, data: currentPng))
        XCTAssertTrue(capture.restoreCurrentSelection(imageId: 5, version: 101, placementId: nil))
        capture.finishRestoring()

        XCTAssertEqual(capture.currentVersion(for: 5), 101)
        XCTAssertEqual(capture.imageData(imageId: 5, version: 100), gracePng, "grace version must remain fetchable")
        XCTAssertEqual(capture.imageData(imageId: 5, version: 101), currentPng)
        XCTAssertEqual(
            capture.imageAvailabilityGeneration, genBefore &+ 1,
            "generation bumps exactly once for the whole restored batch"
        )
    }

    @MainActor
    func testRemoteKittyImageCaptureRestoreRejectsInvalidPNGAndRequiresBeginRestoringWindow() {
        let capture = remoteKittyTestCapture()
        // Outside a `beginRestoring()`/`finishRestoring()` window, the
        // restore-only API is rejected outright.
        XCTAssertFalse(capture.restoreEntry(imageId: 1, version: 1, data: remoteKittyTestPNGBytes(width: 2, height: 2)))
        XCTAssertFalse(capture.restoreCurrentSelection(imageId: 1, version: 1, placementId: nil))

        capture.beginRestoring()
        // Corrupt/non-PNG bytes are rejected fail-closed, exactly like a
        // live transmission's own decode.
        XCTAssertFalse(capture.restoreEntry(imageId: 1, version: 1, data: Data([0x00, 0x01])))
        capture.finishRestoring()
        XCTAssertNil(capture.currentVersion(for: 1))
    }

    /// Restoring previously-persisted state must never recursively re-persist
    /// it back to the very store it came from.
    @MainActor
    func testRemoteKittyImageCaptureRestoreNeverPersistsRecursively() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = RemoteKittyImageCapture(
            sessionId: "s", epoch: 0, budget: RemoteKittyImageCaptureBudget(), diskStore: store
        )
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)

        capture.beginRestoring()
        XCTAssertTrue(capture.restoreEntry(imageId: 7, version: 1, data: png))
        XCTAssertTrue(capture.restoreCurrentSelection(imageId: 7, version: 1, placementId: nil))
        capture.finishRestoring()

        await store.barrierForTesting()
        let entryCount = await store.totalEntryCountForTesting()
        XCTAssertEqual(entryCount, 0, "restore must never re-persist state back to the store it was read from")
    }

    @MainActor
    func testRemoteKittyImageCaptureDisablePersistenceFencesLateTerminalCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let capture = RemoteKittyImageCapture(
            sessionId: "closing",
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        capture.disablePersistence()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=1,c=1,r=1",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        let totalEntries = await store.totalEntryCountForTesting()
        XCTAssertEqual(totalEntries, 0)
    }

    @MainActor
    func testRemoteKittyImageCapturePersistsPlacementGeometryFromPutNotTransmitOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "geometry"
        let capture = RemoteKittyImageCapture(
            sessionId: sessionId,
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=9,c=99,r=99",
            base64Payload: png.base64EncodedString()
        )[...])
        capture.ingest(remoteKittyFrameBytes(
            control: "a=p,U=1,i=9,p=4,c=4,r=2,X=3,Y=5,z=7"
        )[...])
        await store.flush()

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(restored.currentSelections, [RemoteKittyRestoredSelection(
            imageId: 9,
            version: 1,
            placementId: 4,
            rows: 2,
            columns: 4,
            x: 3,
            y: 5,
            z: 7
        )])
    }

    @MainActor
    func testRemoteKittyImageCaptureRestoredTransmitOnlyImageCanBePlacedLater() {
        let capture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.beginRestoring()
        XCTAssertTrue(capture.restoreEntry(imageId: 12, version: 99, data: png))
        capture.finishRestoring()

        capture.ingest(ArraySlice(remoteKittyFrameBytes(
            control: "a=p,U=1,i=12,p=5,c=2,r=1"
        )))

        XCTAssertEqual(capture.currentVersion(for: 12, placementId: 5), 99)
    }

    @MainActor
    func testRemoteKittyImageCapturePersistsExplicitPlacementCoveredByWildcard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "wildcard-explicit"
        let capture = RemoteKittyImageCapture(
            sessionId: sessionId,
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(ArraySlice(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=13,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )))
        capture.ingest(ArraySlice(remoteKittyFrameBytes(
            control: "a=p,U=1,i=13,p=4,c=4,r=3"
        )))
        await store.flush()

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(Set(restored.currentSelections.compactMap(\.placementId)), [4])
        XCTAssertTrue(restored.currentSelections.contains {
            $0.placementId == nil && $0.rows == 1 && $0.columns == 2
        })
        XCTAssertTrue(restored.currentSelections.contains {
            $0.placementId == 4 && $0.rows == 3 && $0.columns == 4
        })
    }

    @MainActor
    func testRemoteKittyImageCaptureNormalizesZeroPlacementIdToImplicit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "zero-placement"
        let capture = RemoteKittyImageCapture(
            sessionId: sessionId,
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        capture.ingest(ArraySlice(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=14,c=2,r=1",
            base64Payload: png.base64EncodedString()
        )))
        capture.ingest(ArraySlice(remoteKittyFrameBytes(
            control: "a=p,U=1,i=14,p=0,c=4,r=3"
        )))
        await store.flush()

        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(restored.currentSelections, [RemoteKittyRestoredSelection(
            imageId: 14,
            version: 1,
            placementId: nil,
            rows: 3,
            columns: 4,
            x: nil,
            y: nil,
            z: nil
        )])
    }

    @MainActor
    func testRemoteKittyImageCapturePersistsEvictionOfNewTransmitOnlyVictimAfterRetain() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "local-bound"
        let capture = RemoteKittyImageCapture(
            sessionId: sessionId,
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        for imageId: UInt32 in 1 ... 16 {
            capture.ingest(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=\(imageId),c=1,r=1",
                base64Payload: png.base64EncodedString()
            )[...])
        }
        capture.ingest(remoteKittyFrameBytes(
            control: "a=t,f=100,t=d,U=1,i=99",
            base64Payload: png.base64EncodedString()
        )[...])
        await store.flush()

        XCTAssertNil(capture.imageData(imageId: 99, version: 17))
        let diskEntryExists = await store.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 99,
            version: 17
        )
        XCTAssertFalse(diskEntryExists)
    }

    @MainActor
    func testRemoteKittyImageCapturePersistsEvictionsTriggeredWhileFinishingRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteKittyImageDiskStore(root: root)
        let sessionId = "restore-bound"
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        for imageId: UInt32 in 1 ... 17 {
            store.persistRetain(
                sessionId: sessionId,
                imageId: imageId,
                version: UInt64(imageId),
                data: png
            )
        }
        await store.flush()
        let restored = await store.restore(sessionId: sessionId)
        XCTAssertEqual(restored.entries.count, 17)

        let capture = RemoteKittyImageCapture(
            sessionId: sessionId,
            epoch: 0,
            budget: RemoteKittyImageCaptureBudget(),
            diskStore: store
        )
        capture.beginRestoring()
        for entry in restored.entries {
            XCTAssertTrue(capture.restoreEntry(
                imageId: entry.imageId,
                version: entry.version,
                data: entry.data
            ))
        }
        capture.finishRestoring()
        await store.flush()

        let totalEntries = await store.totalEntryCountForTesting()
        let oldestExists = await store.entryExistsForTesting(
            sessionId: sessionId,
            imageId: 1,
            version: 1
        )
        XCTAssertEqual(totalEntries, 16)
        XCTAssertFalse(oldestExists)
    }

    // MARK: - Restore replay encoding (pure)

    /// The exact bytes a restore replays into SwiftTerm must themselves be
    /// valid, parseable Kitty APC frames — proven here by feeding them into
    /// an independent, fresh `RemoteKittyImageCapture` (acting purely as a
    /// reference decoder) and confirming it reconstructs the same image and
    /// the exact explicit placement id, never an implicit/omitted one.
    @MainActor
    func testRemoteKittyReplayEncodingProducesFramesDecodableAsTransmitThenPlacement() throws {
        let referenceCapture = remoteKittyTestCapture()
        let png = remoteKittyTestPNGBytes(width: 3, height: 2)
        var bytes = RemoteKittyReplayEncoding.transmitOnlyFrames(imageId: 77, data: png)
        bytes += RemoteKittyReplayEncoding.placementFrame(
            imageId: 77, placementId: 1, rows: 2, columns: 3, x: 5, y: 6, z: 1
        )
        referenceCapture.ingest(bytes[...])
        let version = try XCTUnwrap(referenceCapture.currentVersion(for: 77, placementId: 1))
        XCTAssertEqual(referenceCapture.imageData(imageId: 77, version: version), png)
    }

    // MARK: - ProjectsTerminalView startup restore/buffering integration

    /// End-to-end proof that a disk-restored current selection is
    /// discoverable by the exact same remote-screen placeholder scan a live
    /// transmission would be — without ever live-retransmitting anything —
    /// and that doing so never mints a new version (which live replay
    /// through `dataReceived` would have) nor recursively re-persists.
    @MainActor
    func testAppModelRemoteScreenDiscoversRestoredPlacementWithoutLiveRetransmitOrNewVersion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))

        // Simulates a prior run's persisted state — a deliberately
        // distinctive version far outside any fresh instance's own
        // (epoch, counter) range, so if restore ever minted a *new* version
        // instead of installing this exact one, this assertion would catch it.
        let oldVersion: UInt64 = 0xABCDEF_00_00000001
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        diskStore.persistRetain(sessionId: sessionId, imageId: 77, version: oldVersion, data: png)
        diskStore.replaceCurrentSelections(
            sessionId: sessionId, imageId: 77,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: oldVersion, placementId: nil, rows: 1, columns: 4, x: nil, y: nil, z: nil
            )]
        )
        await diskStore.barrierForTesting()

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: diskStore
        )
        let controller = try XCTUnwrap(model.controller(for: sessionId))
        await controller.terminalView.waitForImageRestoreForTesting()

        XCTAssertEqual(controller.terminalView.kittyImageCapture.currentVersion(for: 77), oldVersion)

        // Only the placeholder glyphs a real client would have printed —
        // never any Kitty graphics command — so the placement can only be
        // discovered here because restore already installed the current
        // version, never because of any live retransmission.
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        controller.terminalView.consumeProcessOutput(Array((
            "\u{1B}[?1049h\u{1B}[H\u{1B}[3;1H"
                + "\u{1B}[38;2;0;0;77m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
        ).utf8)[...])

        let screen = try XCTUnwrap(model.remoteScreen(sessionId: sessionId, afterLine: nil))
        XCTAssertEqual(screen.images, [RemoteTerminalImagePlacement(
            imageId: 77, contentVersion: oldVersion, line: 2, column: 0, rows: 1, columns: 4
        )])
    }

    /// Startup ordering: live PTY bytes arriving while restoration is
    /// pending — including a delete and a fresh retransmit for the very same
    /// image id — must never interleave with the restore replay, and must
    /// apply, in original stream order, only *after* it completes. The live
    /// retransmit naturally wins (a fresh transmission always supersedes
    /// whatever restore installed), while the grace (superseded) version
    /// restore installed remains endpoint-fetchable — never a "delete before
    /// restore" zombie, and never silently dropped either.
    @MainActor
    func testProjectsTerminalViewBuffersLiveDeleteAndRetransmitDuringRestoreThenAppliesThemAfterInOrder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))

        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let session = Session(id: sessionId, title: "Test Session", cwd: root.path)
        let project = Project(id: "pid", name: "Project", cwd: root.path, sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))

        let oldVersion: UInt64 = 0x1111_0000_00000001
        let oldPng = remoteKittyTestPNGBytes(width: 2, height: 2)
        diskStore.persistRetain(sessionId: sessionId, imageId: 55, version: oldVersion, data: oldPng)
        diskStore.replaceCurrentSelections(
            sessionId: sessionId, imageId: 55,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: oldVersion, placementId: nil, rows: 1, columns: 4, x: nil, y: nil, z: nil
            )]
        )
        await diskStore.barrierForTesting()

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: diskStore
        )
        // `controller(for:)` synchronously starts this session's restore
        // `Task`, which — under Swift concurrency's cooperative, non
        // -preemptive scheduling — cannot possibly have run even its first
        // line yet: nothing here has awaited or yielded control back to the
        // scheduler. Every `dataReceived` call immediately below is
        // therefore deterministically guaranteed to observe restoration
        // still pending, never a timing-dependent race.
        let controller = try XCTUnwrap(model.controller(for: sessionId))
        XCTAssertTrue(controller.terminalView.isRestoringImages, "restore must still be pending here")
        XCTAssertNil(
            controller.terminalView.kittyImageCapture.currentVersion(for: 55),
            "nothing has been installed yet — restoration hasn't replayed"
        )

        // Buffered while pending: a delete of the (not-yet-installed)
        // placement, then a fresh live retransmit of the same image id.
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(control: "a=d,d=i,i=55")[...])
        let newPng = remoteKittyTestPNGBytes(width: 5, height: 5)
        controller.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=55", base64Payload: newPng.base64EncodedString()
        )[...])
        XCTAssertTrue(controller.terminalView.isRestoringImages, "still pending: nothing has been flushed yet")

        await controller.terminalView.waitForImageRestoreForTesting()
        XCTAssertFalse(controller.terminalView.isRestoringImages)

        let finalVersion = try XCTUnwrap(controller.terminalView.kittyImageCapture.currentVersion(for: 55))
        XCTAssertNotEqual(finalVersion, oldVersion, "the live retransmit must win, not the restored version")
        XCTAssertEqual(controller.terminalView.kittyImageCapture.imageData(imageId: 55, version: finalVersion), newPng)
        // The lowercase delete only ever retires the *placement*, never the
        // underlying bytes — the restored grace version stays fetchable.
        XCTAssertEqual(controller.terminalView.kittyImageCapture.imageData(imageId: 55, version: oldVersion), oldPng)
    }

    /// If buffering this session's share of live bytes during restore would
    /// overflow the shared hard cap, restoration is abandoned for *this*
    /// session only: the buffered-then-live stream flushes through the
    /// normal path immediately, and the eventual (late) disk-restore result
    /// is ignored rather than resurrecting/overwriting the live state.
    @MainActor
    func testProjectsTerminalViewAbandonsRestoreOnBufferOverflowAndIgnoresLateRestoreResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString

        let oldVersion: UInt64 = 0x2222_0000_00000001
        diskStore.persistRetain(
            sessionId: sessionId, imageId: 66, version: oldVersion,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        diskStore.replaceCurrentSelections(
            sessionId: sessionId, imageId: 66,
            selections: [RemoteKittyPersistedPlacementSelection(
                version: oldVersion, placementId: nil, rows: 1, columns: 1, x: nil, y: nil, z: nil
            )]
        )
        await diskStore.barrierForTesting()

        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        let tinyBudget = RemoteKittyRestoreBufferBudget(maxTotalBytes: 4)
        view.configureImagePersistence(sessionId: sessionId, diskStore: diskStore, restoreBufferBudget: tinyBudget)
        XCTAssertTrue(view.isRestoringImages)

        // A live retransmit far larger than the 4-byte buffer cap, fed
        // before the restore `Task` can possibly have run — deterministically
        // overflows and abandons restoration for this session synchronously.
        let livePng = remoteKittyTestPNGBytes(width: 5, height: 5)
        view.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=66", base64Payload: livePng.base64EncodedString()
        )[...])
        XCTAssertFalse(view.isRestoringImages, "overflow must abandon restoration synchronously")

        let liveVersion = try XCTUnwrap(view.kittyImageCapture.currentVersion(for: 66))
        XCTAssertNotEqual(liveVersion, oldVersion)
        XCTAssertEqual(view.kittyImageCapture.imageData(imageId: 66, version: liveVersion), livePng)

        // The late disk-restore result must never resurrect/overwrite the
        // live state once it eventually arrives.
        await view.waitForImageRestoreForTesting()
        XCTAssertEqual(view.kittyImageCapture.currentVersion(for: 66), liveVersion)
        XCTAssertEqual(tinyBudget.totalBytes, 0)
    }

    @MainActor
    func testProjectsTerminalViewReleasesInjectedBufferBudgetAfterSuccessfulRestore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString
        let version: UInt64 = 123
        diskStore.persistRetain(
            sessionId: sessionId,
            imageId: 7,
            version: version,
            data: remoteKittyTestPNGBytes(width: 2, height: 2),
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: version,
                placementId: nil,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await diskStore.barrierForTesting()

        let budget = RemoteKittyRestoreBufferBudget(maxTotalBytes: 1_024)
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configureImagePersistence(
            sessionId: sessionId,
            diskStore: diskStore,
            restoreBufferBudget: budget
        )
        view.consumeProcessOutput(Array("pending".utf8)[...])
        XCTAssertEqual(budget.totalBytes, 7)

        await view.waitForImageRestoreForTesting()
        XCTAssertEqual(budget.totalBytes, 0)
    }

    @MainActor
    func testProjectsTerminalViewReplaysRestoredPlacementIntoBufferedAlternateScreen() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString
        let version: UInt64 = 321
        diskStore.persistRetain(
            sessionId: sessionId,
            imageId: 8,
            version: version,
            data: remoteKittyTestPNGBytes(width: 2, height: 2),
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: version,
                placementId: nil,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await diskStore.flush()

        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configureImagePersistence(sessionId: sessionId, diskStore: diskStore)
        view.consumeProcessOutput(Array("\u{1B}[?1049h".utf8)[...])
        await view.waitForImageRestoreForTesting()
        view.replayRestoredPlacementsForTesting()

        XCTAssertEqual(view.terminalInputStateSnapshot()?.isAlternateBuffer, true)
        XCTAssertEqual(view.restoredPlacementBufferWasAlternateForTesting, true)
    }

    @MainActor
    func testProjectsTerminalViewUsesLivePlacementGeometryForDelayedRestoreReplay() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString
        let version: UInt64 = 654
        diskStore.persistRetain(
            sessionId: sessionId,
            imageId: 10,
            version: version,
            data: remoteKittyTestPNGBytes(width: 2, height: 2),
            currentSelections: [RemoteKittyPersistedPlacementSelection(
                version: version,
                placementId: 7,
                rows: 1,
                columns: 1,
                x: nil,
                y: nil,
                z: nil
            )]
        )
        await diskStore.flush()

        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configureImagePersistence(sessionId: sessionId, diskStore: diskStore)
        view.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=p,U=1,i=10,p=7,c=4,r=3"
        )[...])
        await view.waitForImageRestoreForTesting()
        view.replayRestoredPlacementsForTesting()

        XCTAssertEqual(
            view.kittyImageCapture.currentPersistedSelection(imageId: 10, placementId: 7),
            RemoteKittyPersistedPlacementSelection(
                version: version,
                placementId: 7,
                rows: 3,
                columns: 4,
                x: nil,
                y: nil,
                z: nil
            )
        )
    }

    @MainActor
    func testProjectsTerminalViewCancelRestoreReleasesBufferedBudget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let diskStore = RemoteKittyImageDiskStore(root: root)
        let sessionId = UUID().uuidString
        diskStore.persistRetain(
            sessionId: sessionId,
            imageId: 9,
            version: 1,
            data: remoteKittyTestPNGBytes(width: 2, height: 2)
        )
        await diskStore.flush()

        let budget = RemoteKittyRestoreBufferBudget(maxTotalBytes: 1_024)
        let view = ProjectsTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.configureImagePersistence(
            sessionId: sessionId,
            diskStore: diskStore,
            restoreBufferBudget: budget
        )
        view.consumeProcessOutput(Array("pending".utf8)[...])
        XCTAssertEqual(budget.totalBytes, 7)

        view.cancelImageRestore()
        XCTAssertEqual(budget.totalBytes, 0)
        XCTAssertFalse(view.isRestoringImages)
    }



    // MARK: - Cross-session global-budget eviction invalidates a session's cached screen (finding #2)

    /// Every remote session's `RemoteKittyImageCapture` instance defaults to
    /// the same process-wide `.shared` budget (there's no injection seam on
    /// `ProjectsTerminalView`). If enough *other* sessions each register one
    /// new image, forcing the shared budget to evict session A's still
    /// -current, still-advertised image, A's own `RemoteTerminalRevision`
    /// must change (via `imageAvailabilityGeneration`) purely from those
    /// other sessions' activity — even though nothing about A's own terminal
    /// content changed — so `RemoteModelBridge.screen` recomputes A's screen
    /// instead of replaying a stale cached one that would keep advertising a
    /// placement whose backing image now 404s.
    @MainActor
    func testRemoteGatewayCrossSessionGlobalEvictionInvalidatesOtherSessionCachedScreen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionIdA = UUID().uuidString
        // 40 distinct flood sessions — each session's own `RemoteKittyImageCapture`
        // instance is a distinct owner in the shared budget, and each registers
        // only *one* image, comfortably under that capture's own 16-entry local
        // bound — so (unlike piling every flood image onto a single session,
        // which would just repeatedly trip that one session's own local
        // eviction without ever pressuring the shared bound) every flood
        // registration here actually reaches and grows the shared, 32-entry
        // -bounded process-wide budget.
        let floodSessionIds = (0 ..< 40).map { _ in UUID().uuidString }
        defer {
            SessionArtifacts.removeFiles(sessionId: sessionIdA)
            for id in floodSessionIds { SessionArtifacts.removeFiles(sessionId: id) }
        }
        let sessionA = Session(id: sessionIdA, title: "Session A", cwd: root.path)
        let floodSessions = floodSessionIds.enumerated().map { index, id in
            Session(id: id, title: "Flood \(index)", cwd: root.path)
        }
        let project = Project(
            id: "pid", name: "Project", cwd: root.path, sessions: [sessionA] + floodSessions
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: "pid"))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("kitty-images", isDirectory: true))
        )
        let controllerA = try XCTUnwrap(model.controller(for: sessionIdA))

        // A registers and live-displays a Kitty image, using a distinctive
        // image id so it can't collide with the flood below. Placeholder
        // decoding round-trips the id through a truecolor foreground
        // (red | green << 8 | blue << 16), so this id must stay small enough
        // to fit in the color's red channel alone, matching every other
        // live-placement test's convention.
        let imageIdA: UInt32 = 91
        let png = remoteKittyTestPNGBytes(width: 2, height: 2)
        controllerA.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
            control: "a=T,f=100,t=d,U=1,i=\(imageIdA)", base64Payload: png.base64EncodedString()
        )[...])
        let placeholder = Character(UnicodeScalar(0x10EEEE)!)
        controllerA.terminalView.consumeProcessOutput(Array((
            "\u{1B}[?1049h\u{1B}[H\u{1B}[3;1H"
                + "\u{1B}[38;2;0;0;91m"
                + String(repeating: String(placeholder), count: 4)
                + "\u{1B}[0m"
        ).utf8)[...])
        let versionA = try XCTUnwrap(controllerA.terminalView.kittyImageCapture.currentVersion(for: imageIdA))

        let bridge = RemoteModelBridge(model: model)
        let initialRevisionA = try XCTUnwrap(bridge.screenRevision(sessionId: sessionIdA))
        let initialScreenA = try XCTUnwrap(bridge.screen(
            sessionId: sessionIdA, revision: initialRevisionA, afterLine: nil
        ))
        XCTAssertEqual(initialScreenA.images, [RemoteTerminalImagePlacement(
            imageId: imageIdA, contentVersion: versionA, line: 2, column: 0, rows: 1, columns: 4
        )])

        // Each of the 40 flood sessions registers exactly one distinct new
        // image — comfortably past the shared 32-entry bound, so A's single
        // (oldest, non-superseded) entry is guaranteed to be reclaimed via
        // `evictForBudget`, regardless of any stray leftover entries other
        // tests sharing `.shared` may have left behind (those get pruned as
        // dead-owner garbage the moment any registration happens).
        for floodSessionId in floodSessionIds {
            let floodController = try XCTUnwrap(model.controller(for: floodSessionId))
            let floodPng = remoteKittyTestPNGBytes(width: 2, height: 2)
            floodController.terminalView.consumeProcessOutput(remoteKittyFrameBytes(
                control: "a=T,f=100,t=d,U=1,i=1", base64Payload: floodPng.base64EncodedString()
            )[...])
        }

        // A's own image is gone from the shared budget, evicted purely by
        // the flood sessions' activity.
        XCTAssertNil(controllerA.terminalView.kittyImageCapture.imageData(imageId: imageIdA, version: versionA))

        // A's revision changed — specifically the image-availability
        // generation, not the (unrelated) content generation — purely from
        // cross-session eviction.
        let evictedRevisionA = try XCTUnwrap(bridge.screenRevision(sessionId: sessionIdA))
        XCTAssertNotEqual(evictedRevisionA, initialRevisionA)
        XCTAssertNotEqual(
            evictedRevisionA.imageAvailabilityGeneration, initialRevisionA.imageAvailabilityGeneration
        )
        XCTAssertEqual(evictedRevisionA.contentGeneration, initialRevisionA.contentGeneration)

        // Because the revision changed, `screen(...)` recomputes rather than
        // replaying the stale cached screen — and A's placement, whose
        // backing image is gone, is no longer advertised (so a client would
        // never be pointed at a 404).
        let evictedScreenA = try XCTUnwrap(bridge.screen(
            sessionId: sessionIdA, revision: evictedRevisionA, afterLine: nil
        ))
        XCTAssertNotEqual(evictedScreenA.images, initialScreenA.images)
        XCTAssertTrue(evictedScreenA.images?.contains { $0.imageId == imageIdA } != true)
    }

    // MARK: - Parent/child session grouping, auto-peek, and lifecycle

    @MainActor
    func testParentChildSessionGroupingHierarchyAutoPeekAndLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let repos = root.appendingPathComponent("Repos", isDirectory: true)
        try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Pure single-level hierarchy resolution (flattening multi-hop chains,
        // ignoring missing parents, and breaking cycles).
        let hierarchyProject = Project(
            id: "p",
            name: "Hierarchy",
            cwd: "/tmp",
            sessions: [
                Session(id: "root", title: "Root", cwd: "/tmp"),
                Session(id: "child", title: "Child", cwd: "/tmp", parentSessionId: "root"),
                Session(id: "grandchild", title: "Grandchild", cwd: "/tmp", parentSessionId: "child"),
                Session(id: "orphan", title: "Orphan", cwd: "/tmp", parentSessionId: "missing"),
                Session(id: "self", title: "Self", cwd: "/tmp", parentSessionId: "self"),
                Session(id: "cycle-a", title: "Cycle A", cwd: "/tmp", parentSessionId: "cycle-b"),
                Session(id: "cycle-b", title: "Cycle B", cwd: "/tmp", parentSessionId: "cycle-a"),
            ]
        )
        XCTAssertNil(hierarchyProject.effectiveParentSessionId(for: "root"))
        XCTAssertEqual(hierarchyProject.effectiveParentSessionId(for: "child"), "root")
        XCTAssertEqual(hierarchyProject.effectiveParentSessionId(for: "grandchild"), "root")
        XCTAssertNil(hierarchyProject.effectiveParentSessionId(for: "orphan"))
        XCTAssertNil(hierarchyProject.effectiveParentSessionId(for: "self"))
        XCTAssertNil(hierarchyProject.effectiveParentSessionId(for: "cycle-a"))
        XCTAssertNil(hierarchyProject.effectiveParentSessionId(for: "cycle-b"))
        XCTAssertNil(hierarchyProject.resolvedParentSessionId(for: "orphan", excluding: "missing"))
        let hierarchyItems = hierarchyProject.sessionDisplayItems(expandedParentIds: ["root"])
        XCTAssertEqual(
            hierarchyItems.filter { $0.effectiveParentSessionId == "root" }.map(\.id),
            ["child", "grandchild"]
        )

        // 2. End-to-end creation via `new-copilot-session`, single-level attachment,
        // remoteWorkspaceSnapshot projection, disclosure & auto-peek, ungroup, move, and close.
        let parent = Session(id: "parent-1", title: "Coordinator", cwd: repos.path)
        let otherTop = Session(id: "top-2", title: "Other Top", cwd: repos.path)
        let p1 = Project(
            id: "p1", name: "One", cwd: repos.path,
            sessions: [parent, otherTop], selectedSessionId: parent.id
        )
        let p2 = Project(id: "p2", name: "Two", cwd: repos.path)
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [p1, p2],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _ in }
        )
        defer { model.detachAllClients() }

        let child1Id = UUID()
        let child2Id = UUID()
        let orphanChildId = UUID()

        func spawn(id: UUID, title: String, parentSessionId: String?) -> ControlResponse {
            var req = ControlRequest(command: "new-copilot-session")
            req.projectId = "p1"
            req.requestId = id.uuidString
            req.title = title
            req.prompt = "Work on \(title)"
            req.parentSessionId = parentSessionId
            return model.handle(req)
        }

        // Direct child of parent-1.
        XCTAssertEqual(spawn(id: child1Id, title: "Track 1", parentSessionId: "parent-1").code, "created")
        // Spawned from child1: resolves up to root parent-1 so hierarchy stays 1 level deep.
        XCTAssertEqual(spawn(id: child2Id, title: "Track 2", parentSessionId: child1Id.uuidString).code, "created")
        // Unknown parent in project: created as top-level.
        XCTAssertEqual(spawn(id: orphanChildId, title: "Standalone", parentSessionId: "not-in-project").code, "created")

        let currentP1 = try XCTUnwrap(model.project("p1"))
        XCTAssertEqual(
            currentP1.sessions.first(where: { $0.id == child1Id.uuidString })?.parentSessionId,
            "parent-1"
        )
        XCTAssertEqual(
            currentP1.sessions.first(where: { $0.id == child2Id.uuidString })?.parentSessionId,
            "parent-1"
        )
        XCTAssertNil(currentP1.sessions.first(where: { $0.id == orphanChildId.uuidString })?.parentSessionId)

        // Persisted state round-trips `parentSessionId` when set, omits it when nil,
        // and decodes legacy sessions without `parentSessionId`.
        let rawState = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertTrue(rawState.contains("\"parentSessionId\""))
        if case .loaded(let loadedState) = StateRepository(path: root.appendingPathComponent("state.json")).load() {
            let loadedSessions = try XCTUnwrap(loadedState.projects.first { $0.id == "p1" }?.sessions)
            XCTAssertEqual(loadedSessions.map(\.parentSessionId), [nil, nil, "parent-1", "parent-1", nil])
        } else {
            XCTFail("expected persisted state to load")
        }
        let legacySession = try JSONDecoder().decode(
            Session.self,
            from: Data(#"{"id":"legacy","title":"Legacy","cwd":"/tmp"}"#.utf8)
        )
        XCTAssertNil(legacySession.parentSessionId)
        XCTAssertFalse(
            try XCTUnwrap(String(data: JSONEncoder().encode(legacySession), encoding: .utf8))
                .contains("parentSessionId")
        )

        // Remote snapshot carries effective parentSessionId for children and nil for top-level.
        let remoteSessions = model.remoteWorkspaceSnapshot().projects[0].sessions
        XCTAssertEqual(
            remoteSessions.map(\.id),
            ["parent-1", "top-2", child1Id.uuidString, child2Id.uuidString, orphanChildId.uuidString]
        )
        XCTAssertEqual(
            remoteSessions.map(\.parentSessionId),
            [nil, nil, "parent-1", "parent-1", nil]
        )

        // Collapsed by default: children are hidden unless selected or waiting.
        XCTAssertFalse(model.isParentSessionExpanded("parent-1"))
        let collapsedItems = try XCTUnwrap(model.project("p1")).sessionDisplayItems(
            expandedParentIds: model.expandedParentSessionIds
        )
        XCTAssertEqual(collapsedItems.map(\.id), ["parent-1", "top-2", orphanChildId.uuidString])
        XCTAssertEqual(collapsedItems[0].childSummary?.label, "2 children")
        XCTAssertFalse(collapsedItems[0].isExpanded)

        // Auto-peek when a child is waiting for input, and update childSummary counts.
        model.setStatus(sessionId: child1Id.uuidString, status: .running, text: nil, timestamp: 100)
        model.setStatus(sessionId: child2Id.uuidString, status: .waiting, text: "Approve?", timestamp: 200)
        let waitingPeekItems = try XCTUnwrap(model.project("p1")).sessionDisplayItems(
            expandedParentIds: model.expandedParentSessionIds
        )
        XCTAssertEqual(
            waitingPeekItems.map(\.id),
            ["parent-1", child2Id.uuidString, "top-2", orphanChildId.uuidString]
        )
        XCTAssertTrue(waitingPeekItems[1].isChild)
        XCTAssertEqual(waitingPeekItems[0].childSummary?.label, "2 children · 1 running, 1 waiting")

        // Auto-peek when a child is selected even if not waiting.
        model.setStatus(sessionId: child2Id.uuidString, status: .idle, text: nil, timestamp: 300)
        model.selectSession(projectId: "p1", sessionId: child1Id.uuidString)
        let selectedPeekItems = try XCTUnwrap(model.project("p1")).sessionDisplayItems(
            expandedParentIds: model.expandedParentSessionIds
        )
        XCTAssertEqual(
            selectedPeekItems.map(\.id),
            ["parent-1", child1Id.uuidString, "top-2", orphanChildId.uuidString]
        )

        // Expanding reveals all children immediately after parent in project order.
        model.selectSession(projectId: "p1", sessionId: "parent-1")
        model.toggleParentSessionExpanded("parent-1")
        XCTAssertTrue(model.isParentSessionExpanded("parent-1"))
        let expandedItems = try XCTUnwrap(model.project("p1")).sessionDisplayItems(
            expandedParentIds: model.expandedParentSessionIds
        )
        XCTAssertEqual(
            expandedItems.map(\.id),
            ["parent-1", child1Id.uuidString, child2Id.uuidString, "top-2", orphanChildId.uuidString]
        )
        XCTAssertTrue(expandedItems[0].isExpanded)
        XCTAssertTrue(expandedItems[1].isChild)
        XCTAssertTrue(expandedItems[2].isChild)

        // Adjacent and numeric navigation follow the grouped display order.
        model.selectAdjacentSession(1)
        XCTAssertEqual(model.project("p1")?.selectedSessionId, child1Id.uuidString)
        model.selectSessionByIndex(3)
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "top-2")

        // Group-aware reordering: child rows reorder among siblings; cross-level moves are no-ops.
        model.moveSession(projectId: "p1", draggedId: "top-2", beforeId: child1Id.uuidString)
        model.moveSession(projectId: "p1", draggedId: child2Id.uuidString, beforeId: "parent-1")
        XCTAssertEqual(
            try XCTUnwrap(model.project("p1")).sessionDisplayItems(
                expandedParentIds: model.expandedParentSessionIds
            ).map(\.id),
            ["parent-1", child1Id.uuidString, child2Id.uuidString, "top-2", orphanChildId.uuidString]
        )
        model.moveSession(projectId: "p1", draggedId: child2Id.uuidString, beforeId: child1Id.uuidString)
        XCTAssertEqual(
            try XCTUnwrap(model.project("p1")).sessionDisplayItems(
                expandedParentIds: model.expandedParentSessionIds
            ).map(\.id),
            ["parent-1", child2Id.uuidString, child1Id.uuidString, "top-2", orphanChildId.uuidString]
        )
        // Appending a child (`beforeId: nil`) moves it after its last sibling within the group.
        model.moveSession(projectId: "p1", draggedId: child2Id.uuidString, beforeId: nil)
        XCTAssertEqual(
            try XCTUnwrap(model.project("p1")).sessionDisplayItems(
                expandedParentIds: model.expandedParentSessionIds
            ).map(\.id),
            ["parent-1", child1Id.uuidString, child2Id.uuidString, "top-2", orphanChildId.uuidString]
        )

        // Multi-hop chains flatten on decode and preserve effective siblings across ungroup/move/close.
        let p1ChainIdx = try XCTUnwrap(model.projectIndex("p1"))
        let c2ChainIdx = try XCTUnwrap(model.projects[p1ChainIdx].sessions.firstIndex { $0.id == child2Id.uuidString })
        model.projects[p1ChainIdx].sessions[c2ChainIdx].parentSessionId = child1Id.uuidString
        let decodedChain = try JSONDecoder().decode(
            Project.self,
            from: JSONEncoder().encode(model.projects[p1ChainIdx])
        )
        XCTAssertEqual(
            decodedChain.sessions.first(where: { $0.id == child2Id.uuidString })?.parentSessionId,
            "parent-1"
        )

        // Ungrouping child1 promotes it to top-level while keeping child2 attached to parent-1.
        model.ungroupSession(projectId: "p1", sessionId: child1Id.uuidString)
        XCTAssertNil(model.project("p1")?.sessions.first(where: { $0.id == child1Id.uuidString })?.parentSessionId)
        XCTAssertEqual(
            model.project("p1")?.sessions.first(where: { $0.id == child2Id.uuidString })?.parentSessionId,
            "parent-1"
        )
        let afterUngroup = try XCTUnwrap(model.project("p1")).sessionDisplayItems(
            expandedParentIds: model.expandedParentSessionIds
        )
        XCTAssertEqual(afterUngroup[0].childSummary?.label, "1 child")

        // Re-attach child1 -> child2 chain to test moving a child and closing a parent.
        let p1Index = try XCTUnwrap(model.projectIndex("p1"))
        let c1Index = try XCTUnwrap(model.projects[p1Index].sessions.firstIndex { $0.id == child1Id.uuidString })
        let c2Index = try XCTUnwrap(model.projects[p1Index].sessions.firstIndex { $0.id == child2Id.uuidString })
        model.projects[p1Index].sessions[c1Index].parentSessionId = "parent-1"
        model.projects[p1Index].sessions[c2Index].parentSessionId = child1Id.uuidString

        // Moving selected child1 to another project clears its parentSessionId, preserves child2's
        // effective root (`parent-1`), and selects child1's visible left neighbor (`parent-1`).
        model.selectSession(projectId: "p1", sessionId: child1Id.uuidString)
        XCTAssertTrue(model.moveSession(toProjectId: "p2", draggedId: child1Id.uuidString))
        XCTAssertNil(model.project("p2")?.sessions.first(where: { $0.id == child1Id.uuidString })?.parentSessionId)
        XCTAssertEqual(
            model.project("p1")?.sessions.first(where: { $0.id == child2Id.uuidString })?.parentSessionId,
            "parent-1"
        )
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "parent-1")
        XCTAssertTrue(model.isParentSessionExpanded("parent-1"))

        // Moving the last remaining child (child2) to p2 clears parent-1's expanded state.
        XCTAssertTrue(model.moveSession(toProjectId: "p2", draggedId: child2Id.uuidString))
        XCTAssertFalse(model.isParentSessionExpanded("parent-1"))

        // Move child1 and child2 back into p1 under parent-1 (child1 before child2) to test moving a parent with children.
        XCTAssertTrue(model.moveSession(toProjectId: "p1", draggedId: child1Id.uuidString))
        XCTAssertTrue(model.moveSession(toProjectId: "p1", draggedId: child2Id.uuidString))
        XCTAssertEqual(
            model.setParentSession(projectId: "p1", sessionId: child1Id.uuidString, parentSessionId: "parent-1").code,
            "reparented"
        )
        XCTAssertEqual(
            model.setParentSession(projectId: "p1", sessionId: child2Id.uuidString, parentSessionId: "parent-1").code,
            "reparented"
        )
        let p1ChainIdx2 = try XCTUnwrap(model.projectIndex("p1"))
        let c2ChainIdx2 = try XCTUnwrap(model.projects[p1ChainIdx2].sessions.firstIndex { $0.id == child2Id.uuidString })
        model.projects[p1ChainIdx2].sessions[c2ChainIdx2].parentSessionId = child1Id.uuidString

        let parentController = try XCTUnwrap(model.controller(for: "parent-1"))
        let child1Controller = try XCTUnwrap(model.controller(for: child1Id.uuidString))
        let child2Controller = try XCTUnwrap(model.controller(for: child2Id.uuidString))

        // Select child2 in p1, then move parent-1 to p2: parent-1 and both children move in relative
        // order, stay single-level children of parent-1, keep expanded state and live controllers,
        // update p1/global/transcript selection to the remaining session (`top-2`), and select parent-1 in p2.
        model.selectSession(projectId: "p1", sessionId: child2Id.uuidString)
        XCTAssertEqual(model.globalSelectedSessionId, child2Id.uuidString)
        XCTAssertEqual(model.activeTranscriptController?.sessionId, child2Id.uuidString)
        XCTAssertTrue(model.moveSession(toProjectId: "p2", draggedId: "parent-1"))
        XCTAssertEqual(model.project("p1")?.sessions.map(\.id), ["top-2", orphanChildId.uuidString])
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "top-2")
        XCTAssertEqual(model.globalSelectedSessionId, "top-2")
        XCTAssertEqual(model.activeTranscriptController?.sessionId, "top-2")
        XCTAssertEqual(
            model.project("p2")?.sessions.map(\.id),
            ["parent-1", child1Id.uuidString, child2Id.uuidString]
        )
        XCTAssertEqual(
            model.project("p2")?.sessions.map(\.parentSessionId),
            [nil, "parent-1", "parent-1"]
        )
        XCTAssertEqual(model.project("p2")?.selectedSessionId, "parent-1")
        XCTAssertTrue(model.isParentSessionExpanded("parent-1"))
        XCTAssertTrue(model.controllers["parent-1"] === parentController)
        XCTAssertTrue(model.controllers[child1Id.uuidString] === child1Controller)
        XCTAssertTrue(model.controllers[child2Id.uuidString] === child2Controller)

        // Collapse parent-1 and move it back to p1 via moveRemoteSession (`selectInTarget: false`):
        // collapsed state is preserved, p2 becomes empty (`selectedSessionId == nil`), and p1 keeps `top-2` selected.
        model.toggleParentSessionExpanded("parent-1")
        XCTAssertFalse(model.isParentSessionExpanded("parent-1"))
        XCTAssertEqual(model.moveRemoteSession(sessionId: "parent-1", toProjectId: "p1"), .moved)
        XCTAssertFalse(model.isParentSessionExpanded("parent-1"))
        XCTAssertTrue(try XCTUnwrap(model.project("p2")).sessions.isEmpty)
        XCTAssertNil(model.project("p2")?.selectedSessionId)
        XCTAssertEqual(model.project("p1")?.selectedSessionId, "top-2")
        XCTAssertEqual(
            model.project("p1")?.sessions.map(\.id),
            ["top-2", orphanChildId.uuidString, "parent-1", child1Id.uuidString, child2Id.uuidString]
        )
        XCTAssertEqual(
            model.project("p1")?.sessions.map(\.parentSessionId),
            [nil, nil, nil, "parent-1", "parent-1"]
        )

        // When parent-1 is selected after `orphanChildId`, moving parent-1 to empty p2 selects the left
        // visible neighbor (`orphanChildId`) in p1, selects parent-1 in p2, and persists across reload.
        model.selectSession(projectId: "p1", sessionId: "parent-1")
        XCTAssertEqual(model.moveRemoteSession(sessionId: "parent-1", toProjectId: "p2"), .moved)
        XCTAssertEqual(model.project("p1")?.selectedSessionId, orphanChildId.uuidString)
        XCTAssertEqual(model.globalSelectedSessionId, orphanChildId.uuidString)
        XCTAssertEqual(model.activeTranscriptController?.sessionId, orphanChildId.uuidString)
        XCTAssertEqual(model.project("p2")?.selectedSessionId, "parent-1")
        if case .loaded(let reloadedAfterMove) = StateRepository(path: root.appendingPathComponent("state.json")).load() {
            let reloadedP1 = try XCTUnwrap(reloadedAfterMove.projects.first { $0.id == "p1" })
            let reloadedP2 = try XCTUnwrap(reloadedAfterMove.projects.first { $0.id == "p2" })
            XCTAssertEqual(reloadedP1.sessions.map(\.id), ["top-2", orphanChildId.uuidString])
            XCTAssertEqual(reloadedP2.sessions.map(\.id), ["parent-1", child1Id.uuidString, child2Id.uuidString])
            XCTAssertEqual(reloadedP2.sessions.map(\.parentSessionId), [nil, "parent-1", "parent-1"])
            XCTAssertEqual(reloadedP2.selectedSessionId, "parent-1")
        } else {
            XCTFail("expected persisted state to load after parent move")
        }

        // Move parent-1 back to p1 and close parent-1: promotes its children to top-level and clears expanded state.
        model.toggleParentSessionExpanded("parent-1")
        XCTAssertTrue(model.moveSession(toProjectId: "p1", draggedId: "parent-1"))
        model.closeSession(projectId: "p1", sessionId: "parent-1")
        XCTAssertFalse(model.isParentSessionExpanded("parent-1"))
        XCTAssertNil(model.project("p1")?.sessions.first(where: { $0.id == child1Id.uuidString })?.parentSessionId)
        XCTAssertNil(model.project("p1")?.sessions.first(where: { $0.id == child2Id.uuidString })?.parentSessionId)
    }

    // MARK: - Desktop transcript interactive pending questions

    func testTranscriptDrawerTurnsWithoutQuestionEchoesSuppressesLatestTurnEchoesAndPreservesReasoningSteps() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let earlierTurn = TranscriptTurn(
            id: "turn-1",
            startedAt: now,
            endedAt: now.addingTimeInterval(5),
            kind: "user",
            userContent: "First turn",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "m-early",
                    timestamp: now.addingTimeInterval(2),
                    content: "Deploy to production?"
                ),
            ],
            tools: [],
            isAborted: false,
            reasoningSteps: ["Step 1"]
        )
        let latestTurn = TranscriptTurn(
            id: "turn-2",
            startedAt: now.addingTimeInterval(10),
            endedAt: nil,
            kind: "user",
            userContent: "Second turn",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "m-keep-earlier-duplicate",
                    timestamp: now.addingTimeInterval(11),
                    content: "Deploy to production?"
                ),
                TranscriptAssistantMessage(
                    id: "m-keep-intro",
                    timestamp: now.addingTimeInterval(12),
                    content: "Checking deployment config."
                ),
                TranscriptAssistantMessage(
                    id: "m-hide-ask-user",
                    timestamp: now.addingTimeInterval(13),
                    content: "  Deploy to production?\n"
                ),
                TranscriptAssistantMessage(
                    id: "m-hide-elicitation",
                    timestamp: now.addingTimeInterval(14),
                    content: "Select target environment"
                ),
            ],
            tools: [TranscriptTool(id: "t-1", name: "ask_user", title: "ask_user", success: nil)],
            isAborted: false,
            reasoningSteps: ["**Evaluating options**\nConsidering prod vs staging."]
        )

        let pendingUserInputs = [
            RemoteUserInputRequest(
                requestId: "req-1",
                question: "Deploy to production?",
                choices: ["Yes", "No"],
                allowFreeform: true,
                requestedAt: now.addingTimeInterval(13)
            ),
        ]
        let pendingElicitations = [
            RemoteElicitationRequest(
                requestId: "elicit-1",
                message: "Select target environment",
                mode: "form",
                schema: nil,
                elicitationSource: nil,
                requestedAt: now.addingTimeInterval(14)
            ),
        ]

        let filtered = TranscriptDrawer.turnsWithoutQuestionEchoes(
            [earlierTurn, latestTurn],
            pendingUserInputs: pendingUserInputs,
            pendingElicitations: pendingElicitations
        )

        XCTAssertEqual(filtered.count, 2)
        // Earlier turn is untouched even when it has matching text.
        XCTAssertEqual(filtered[0], earlierTurn)
        // Latest turn hides only one trailing copy per pending question and preserves earlier messages + reasoningSteps.
        XCTAssertEqual(
            filtered[1].assistantMessages.map(\.id),
            ["m-keep-earlier-duplicate", "m-keep-intro"]
        )
        XCTAssertEqual(
            filtered[1].reasoningSteps,
            ["**Evaluating options**\nConsidering prod vs staging."]
        )
        XCTAssertEqual(filtered[1].tools, latestTurn.tools)
    }

    func testDesktopElicitationFormParsesOrderedFieldsSeedsDefaultsAndValidatesAgainstHostSchema() throws {
        let schema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([
                .string("environment"),
                .string("strategy"),
                .string("confirm"),
                .string("retries"),
                .string("note"),
                .string("regions"),
            ]),
            RemoteElicitationForm.propertyOrderKey: .array([
                .string("strategy"),
                .string("environment"),
                .string("confirm"),
                .string("retries"),
                .string("ratio"),
                .string("note"),
                .string("regions"),
            ]),
            "properties": .object([
                "environment": .object([
                    "type": .string("string"),
                    "title": .string("Environment"),
                    "enum": .array([.string("staging"), .string("prod")]),
                    "default": .string("prod"),
                ]),
                "strategy": .object([
                    "type": .string("string"),
                    "title": .string("Strategy"),
                    "oneOf": .array([
                        .object(["const": .string("canary"), "title": .string("Canary rollout")]),
                        .object(["const": .string("full"), "title": .string("Full rollout")]),
                    ]),
                ]),
                "confirm": .object([
                    "type": .string("boolean"),
                    "title": .string("Confirm"),
                    "default": .bool(true),
                ]),
                "retries": .object([
                    "type": .string("integer"),
                    "title": .string("Retries"),
                    "minimum": .number(1),
                    "maximum": .number(5),
                    "default": .number(3),
                ]),
                "ratio": .object([
                    "type": .string("number"),
                    "title": .string("Ratio"),
                    "minimum": .number(0),
                    "maximum": .number(1),
                ]),
                "note": .object([
                    "type": .string("string"),
                    "title": .string("Note"),
                    "minLength": .number(2),
                    "maxLength": .number(20),
                    "default": .string("ship it"),
                ]),
                "regions": .object([
                    "type": .string("array"),
                    "title": .string("Regions"),
                    "minItems": .number(1),
                    "maxItems": .number(2),
                    "items": .object([
                        "type": .string("string"),
                        "oneOf": .array([
                            .object(["const": .string("us-east"), "title": .string("US East")]),
                            .object(["const": .string("eu-west"), "title": .string("EU West")]),
                            .object(["const": .string("ap-south"), "title": .string("AP South")]),
                        ]),
                    ]),
                ]),
            ]),
        ])

        let form = try XCTUnwrap(
            DesktopElicitationForm(.parse(schema, allowFreeformChoices: true), schema: schema)
        )
        XCTAssertEqual(
            form.fields.map(\.key),
            ["strategy", "environment", "confirm", "retries", "ratio", "note", "regions"]
        )

        let initial = form.initialState()
        XCTAssertEqual(initial.values["strategy"], .string("canary"))
        XCTAssertEqual(initial.values["environment"], .string("prod"))
        XCTAssertEqual(initial.values["confirm"], .bool(true))
        XCTAssertEqual(initial.values["retries"], .number(3))
        XCTAssertNil(initial.values["ratio"])
        XCTAssertEqual(initial.values["note"], .string("ship it"))
        XCTAssertEqual(initial.values["regions"], .array([]))

        // Invalid while required `regions` has 0 items (< minItems 1).
        XCTAssertNil(form.validatedContent(values: initial.values, touched: []))

        var values = initial.values
        var touched: Set<String> = ["regions", "ratio"]
        let regionsField = try XCTUnwrap(form.fields.first { $0.key == "regions" })
        let regionChoices = try XCTUnwrap(regionsField.choices)
        let maxItems = regionsField.maxItems
        let firstToggle = try XCTUnwrap(
            DesktopElicitationField.toggledSelection(
                "eu-west",
                in: [],
                choices: regionChoices,
                maxItems: maxItems
            )
        )
        let secondToggle = try XCTUnwrap(
            DesktopElicitationField.toggledSelection(
                "us-east",
                in: firstToggle,
                choices: regionChoices,
                maxItems: maxItems
            )
        )
        // Stored in schema choice order and capped at maxItems = 2.
        XCTAssertEqual(secondToggle, ["us-east", "eu-west"])
        XCTAssertNil(
            DesktopElicitationField.toggledSelection(
                "ap-south",
                in: secondToggle,
                choices: regionChoices,
                maxItems: maxItems
            )
        )
        values["regions"] = .array(secondToggle.map(RemoteJSONValue.string))
        values["ratio"] = DesktopElicitationNumberText.value(
            for: "0,75",
            locale: Locale(identifier: "de_DE")
        )
        XCTAssertEqual(values["ratio"], .number(0.75))
        XCTAssertEqual(
            DesktopElicitationNumberText.parse("۳", locale: Locale(identifier: "fa_IR")),
            3
        )
        XCTAssertEqual(DesktopElicitationNumberText.parse("1e200"), 1e200)
        XCTAssertEqual(DesktopElicitationNumberText.parse("1e-200"), 1e-200)
        XCTAssertNil(DesktopElicitationNumberText.parse("12junk"))
        XCTAssertEqual(DesktopElicitationNumberText.value(for: "12junk"), .string("12junk"))

        // Out-of-bounds number values are rejected by both DesktopElicitationForm and AppModel.elicitationContent.
        var outOfBounds = values
        outOfBounds["retries"] = .number(0)
        XCTAssertNil(form.validatedContent(values: outOfBounds, touched: touched))
        XCTAssertFalse(
            AppModel.elicitationContent(
                outOfBounds,
                satisfies: schema,
                allowFreeformStringChoices: true
            )
        )
        outOfBounds["retries"] = .number(3)
        outOfBounds["ratio"] = .number(1.5)
        XCTAssertNil(form.validatedContent(values: outOfBounds, touched: touched))

        let payload = try XCTUnwrap(
            form.validatedContent(values: values, touched: touched)
        )
        XCTAssertTrue(AppModel.isValidElicitationContent(payload))
        XCTAssertTrue(
            AppModel.elicitationContent(
                payload,
                satisfies: schema,
                allowFreeformStringChoices: true
            )
        )

        // Payloads exceeding the host's 32,768-byte encoded JSON cap are rejected by the form validator.
        let unconstrainedSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("body")]),
            "properties": .object([
                "body": .object(["type": .string("string")]),
                "email": .object(["type": .string("string"), "format": .string("email")]),
            ]),
        ])
        let unconstrainedForm = try XCTUnwrap(
            DesktopElicitationForm(.parse(unconstrainedSchema), schema: unconstrainedSchema)
        )
        XCTAssertNil(
            unconstrainedForm.validatedContent(
                values: ["body": .string("ok"), "email": .string("not-an-email")],
                touched: ["body", "email"]
            )
        )
        XCTAssertNotNil(
            unconstrainedForm.validatedContent(
                values: ["body": .string("ok"), "email": .string("dev@example.com")],
                touched: ["body", "email"]
            )
        )
        let oversizedValues: [String: RemoteJSONValue] = [
            "body": .string(String(repeating: "x", count: 33_000)),
        ]
        XCTAssertNil(
            unconstrainedForm.validatedContent(values: oversizedValues, touched: ["body"])
        )

        // Optional multi-select with minItems: 1 clears back to nil when its last option is deselected,
        // while a required multi-select with minItems: 1 retains .array([]) and fails validation.
        let clearedRequired = try XCTUnwrap(
            regionsField.toggledSelectionValue("eu-west", in: .array([.string("eu-west")]))
        )
        XCTAssertEqual(clearedRequired, .array([]))
        var requiredClearedValues = values
        requiredClearedValues["regions"] = clearedRequired
        XCTAssertNil(form.validatedContent(values: requiredClearedValues, touched: touched))

        let optionalMultiSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "tags": .object([
                    "type": .string("array"),
                    "minItems": .number(1),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([.string("a"), .string("b")]),
                    ]),
                ]),
            ]),
        ])
        let optionalMultiForm = try XCTUnwrap(
            DesktopElicitationForm(.parse(optionalMultiSchema), schema: optionalMultiSchema)
        )
        let tagsField = try XCTUnwrap(optionalMultiForm.fields.first)
        var optionalValues: [String: RemoteJSONValue] = [:]
        optionalValues["tags"] = try XCTUnwrap(tagsField.toggledSelectionValue("a", in: optionalValues["tags"]))
        XCTAssertEqual(optionalValues["tags"], .array([.string("a")]))
        optionalValues["tags"] = try XCTUnwrap(tagsField.toggledSelectionValue("a", in: optionalValues["tags"]))
        XCTAssertNil(optionalValues["tags"])
        let clearedOptionalPayload = try XCTUnwrap(
            optionalMultiForm.validatedContent(values: optionalValues, touched: ["tags"])
        )
        XCTAssertTrue(clearedOptionalPayload.isEmpty)
        XCTAssertTrue(
            AppModel.elicitationContent(
                clearedOptionalPayload,
                satisfies: optionalMultiSchema,
                allowFreeformStringChoices: false
            )
        )

        // Freeform custom choice on `strategy` when allowFreeformChoices is true.
        var customFields: Set<String> = []
        DesktopElicitationChoiceSelection.other.apply(
            fieldKey: "strategy",
            choices: form.fields[0].choices ?? [],
            allowsFreeform: true,
            values: &values,
            customChoiceFields: &customFields
        )
        touched.insert("strategy")
        // Blank custom choice is rejected until text is entered.
        XCTAssertNil(
            form.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customFields
            )
        )
        values["strategy"] = .string("blue-green")
        let customPayload = try XCTUnwrap(
            form.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customFields
            )
        )
        XCTAssertTrue(
            AppModel.elicitationContent(
                customPayload,
                satisfies: schema,
                allowFreeformStringChoices: true
            )
        )
        XCTAssertFalse(
            AppModel.elicitationContent(
                customPayload,
                satisfies: schema,
                allowFreeformStringChoices: false
            )
        )

        // Multi-select "Other" counts toward minItems/maxItems, blocks when blank, preserves choice order,
        // and seeds unlisted defaults only when allowFreeformChoices is true.
        XCTAssertNil(
            regionsField.toggledCustomSelection(
                values: &values,
                customChoiceFields: &customFields
            ),
            "Cannot enable Other when maxItems (2) is already reached"
        )
        values["regions"] = try XCTUnwrap(
            regionsField.toggledSelectionValue("eu-west", in: values["regions"])
        )
        XCTAssertEqual(values["regions"], .array([.string("us-east")]))
        XCTAssertEqual(
            regionsField.toggledCustomSelection(
                values: &values,
                customChoiceFields: &customFields
            ),
            true
        )
        XCTAssertTrue(customFields.contains("regions"))
        XCTAssertEqual(values["regions"], .array([.string("us-east"), .string("")]))
        XCTAssertTrue(
            regionsField.toggledSelectionValue(
                "eu-west",
                in: values["regions"],
                allowsFreeform: true,
                isCustom: true
            ) == nil,
            "Checked Other counts toward maxItems (2)"
        )
        XCTAssertNil(
            form.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customFields
            ),
            "Empty Other blocks submission"
        )
        values["regions"] = try XCTUnwrap(
            regionsField.updatedCustomChoiceValue(
                "ca-central",
                in: values["regions"],
                customChoiceFields: &customFields
            )
        )
        values["regions"] = try XCTUnwrap(
            regionsField.toggledSelectionValue(
                "us-east",
                in: values["regions"],
                allowsFreeform: true,
                isCustom: true
            )
        )
        XCTAssertEqual(values["regions"], .array([.string("ca-central")]))
        values["regions"] = try XCTUnwrap(
            regionsField.toggledSelectionValue(
                "eu-west",
                in: values["regions"],
                allowsFreeform: true,
                isCustom: true
            )
        )
        XCTAssertEqual(values["regions"], .array([.string("eu-west"), .string("ca-central")]))
        let multiCustomPayload = try XCTUnwrap(
            form.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customFields
            )
        )
        XCTAssertEqual(
            multiCustomPayload["regions"],
            .array([.string("eu-west"), .string("ca-central")])
        )
        XCTAssertTrue(
            AppModel.elicitationContent(
                multiCustomPayload,
                satisfies: schema,
                allowFreeformStringChoices: true
            )
        )
        XCTAssertFalse(
            AppModel.elicitationContent(
                multiCustomPayload,
                satisfies: schema,
                allowFreeformStringChoices: false
            )
        )
        XCTAssertEqual(
            regionsField.toggledCustomSelection(
                values: &values,
                customChoiceFields: &customFields
            ),
            false
        )
        XCTAssertFalse(customFields.contains("regions"))
        XCTAssertEqual(values["regions"], .array([.string("eu-west")]))

        var optionalCustomFields: Set<String> = []
        XCTAssertEqual(
            tagsField.toggledCustomSelection(
                values: &optionalValues,
                customChoiceFields: &optionalCustomFields
            ),
            true
        )
        optionalValues["tags"] = try XCTUnwrap(
            tagsField.updatedCustomChoiceValue(
                "custom-tag",
                in: optionalValues["tags"],
                customChoiceFields: &optionalCustomFields
            )
        )
        XCTAssertEqual(
            tagsField.toggledCustomSelection(
                values: &optionalValues,
                customChoiceFields: &optionalCustomFields
            ),
            false
        )
        XCTAssertTrue(optionalCustomFields.isEmpty)
        XCTAssertNil(optionalValues["tags"])
        XCTAssertEqual(
            optionalMultiForm.validatedContent(
                values: optionalValues,
                touched: ["tags"],
                customChoiceFields: optionalCustomFields
            ),
            [:]
        )

        let multiDefaultSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("toppings")]),
            "properties": .object([
                "toppings": .object([
                    "type": .string("array"),
                    "minItems": .number(2),
                    "maxItems": .number(2),
                    "default": .array([.string("cheese"), .string("olives")]),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([.string("cheese"), .string("pepperoni")]),
                    ]),
                ]),
            ]),
        ])
        let agentMultiDefault = try XCTUnwrap(
            DesktopElicitationForm(
                .parse(multiDefaultSchema, allowFreeformChoices: true),
                schema: multiDefaultSchema
            )
        ).initialState()
        XCTAssertEqual(
            agentMultiDefault.values["toppings"],
            .array([.string("cheese"), .string("olives")])
        )
        XCTAssertEqual(agentMultiDefault.customChoiceFields, ["toppings"])
        let mcpMultiDefault = try XCTUnwrap(
            DesktopElicitationForm(.parse(multiDefaultSchema), schema: multiDefaultSchema)
        ).initialState()
        XCTAssertEqual(mcpMultiDefault.values["toppings"], .array([]))
        XCTAssertTrue(mcpMultiDefault.customChoiceFields.isEmpty)
    }

    @MainActor
    private func pumpRunLoop(_ host: NSView) {
        CFRunLoopRunInMode(.defaultMode, 0, false)
        host.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func pump(_ host: NSView) async {
        for _ in 0..<8 {
            pumpRunLoop(host)
            await Task.yield()
        }
    }

    @MainActor
    private func sendKey(
        to window: NSWindow,
        characters: String = "\r",
        modifiers: NSEvent.ModifierFlags = [],
        keyCode: UInt16 = 36
    ) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
        window.sendEvent(event)
    }

    @MainActor
    private func typeText(_ text: String, into field: NSTextField, in window: NSWindow, host: NSView) async throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
        await pump(host)
    }

    @MainActor
    func testDesktopQuestionCardsReturnSubmitsValidAnswersAndOptionReturnInsertsNewline() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 420, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }

        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)

        // 1. DesktopUserInputCard: Return does nothing on empty input, Option-Return inserts newline,
        //    Return submits without trailing newline and cannot submit twice.
        var submittedUserInputs: [RemoteUserInputAnswer] = []
        let userInputHost = NSHostingView(
            rootView: DesktopUserInputCard(
                request: RemoteUserInputRequest(
                    requestId: "req-user-input",
                    question: "What should we name it?",
                    choices: ["Default"],
                    allowFreeform: true,
                    requestedAt: requestedAt
                ),
                onAnswer: { answer in
                    submittedUserInputs.append(answer)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onFocusTerminal: {}
            )
        )
        userInputHost.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        window.contentView = userInputHost
        await pump(userInputHost)

        let userField = try XCTUnwrap(findEditableTextFields(in: userInputHost).first)
        XCTAssertTrue(window.makeFirstResponder(userField))
        try sendKey(to: window)
        await pump(userInputHost)
        XCTAssertTrue(submittedUserInputs.isEmpty)
        XCTAssertEqual(userField.stringValue, "")

        try await typeText("line 1", into: userField, in: window, host: userInputHost)
        try sendKey(to: window, modifiers: [.option])
        await pump(userInputHost)
        XCTAssertTrue(submittedUserInputs.isEmpty)
        let editorAfterOptionReturn = try XCTUnwrap(userField.currentEditor() as? NSTextView)
        editorAfterOptionReturn.insertText("line 2", replacementRange: editorAfterOptionReturn.selectedRange())
        await pump(userInputHost)
        XCTAssertEqual(userField.stringValue, "line 1\nline 2")

        try sendKey(to: window)
        try sendKey(to: window)
        await pump(userInputHost)
        XCTAssertEqual(
            submittedUserInputs,
            [
                RemoteUserInputAnswer(
                    requestId: "req-user-input",
                    answer: "line 1\nline 2",
                    wasFreeform: true
                ),
            ]
        )

        // 2. DesktopElicitationCard multi-field form (.string + .number) and custom choice ("Other").
        let multiFieldSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("summary"), .string("count"), .string("mode")]),
            RemoteElicitationForm.propertyOrderKey: .array([
                .string("summary"),
                .string("count"),
                .string("mode"),
            ]),
            "properties": .object([
                "summary": .object([
                    "type": .string("string"),
                    "title": .string("Summary"),
                    "minLength": .number(3),
                ]),
                "count": .object([
                    "type": .string("integer"),
                    "title": .string("Count"),
                    "minimum": .number(1),
                    "maximum": .number(10),
                ]),
                "mode": .object([
                    "type": .string("string"),
                    "title": .string("Mode"),
                    "enum": .array([.string("fast"), .string("safe")]),
                ]),
            ]),
        ])
        var submittedElicitations: [RemoteElicitationAnswer] = []
        let elicitationHost = NSHostingView(
            rootView: DesktopElicitationCard(
                request: TrackedElicitation(
                    requestId: "req-elicitation",
                    message: "Configure run",
                    schema: multiFieldSchema,
                    requestedAt: requestedAt.ISO8601Format()
                ).remoteRequest(),
                onAnswer: { answer in
                    submittedElicitations.append(answer)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onFocusTerminal: {}
            )
        )
        elicitationHost.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        window.contentView = elicitationHost
        await pump(elicitationHost)

        let elicitationFields = findEditableTextFields(in: elicitationHost)
        XCTAssertEqual(elicitationFields.count, 2)
        let summaryField = elicitationFields[0]
        let countField = elicitationFields[1]

        // Empty / invalid summary: Return neither submits nor inserts a newline.
        XCTAssertTrue(window.makeFirstResponder(summaryField))
        try sendKey(to: window)
        await pump(elicitationHost)
        XCTAssertTrue(submittedElicitations.isEmpty)
        XCTAssertEqual(summaryField.stringValue, "")

        // Valid multi-line summary via Option-Return, but required `count` is still missing: Return does not submit.
        try await typeText("alpha", into: summaryField, in: window, host: elicitationHost)
        try sendKey(to: window, modifiers: [.option])
        await pump(elicitationHost)
        let summaryEditor = try XCTUnwrap(summaryField.currentEditor() as? NSTextView)
        summaryEditor.insertText("beta", replacementRange: summaryEditor.selectedRange())
        await pump(elicitationHost)
        try sendKey(to: window)
        await pump(elicitationHost)
        XCTAssertTrue(submittedElicitations.isEmpty)
        XCTAssertEqual(summaryField.stringValue, "alpha\nbeta")

        // Out-of-range number: Return in the number field does not submit.
        try await typeText("99", into: countField, in: window, host: elicitationHost)
        try sendKey(to: window)
        await pump(elicitationHost)
        XCTAssertTrue(submittedElicitations.isEmpty)

        // Valid number makes the form valid: Tab / focus change does NOT submit, Return in the number field submits once.
        let countEditor = try XCTUnwrap(countField.currentEditor() as? NSTextView)
        countEditor.selectAll(nil)
        countEditor.insertText("4", replacementRange: countEditor.selectedRange())
        await pump(elicitationHost)
        try sendKey(to: window, characters: "\t", keyCode: 48)
        XCTAssertTrue(window.makeFirstResponder(summaryField))
        await pump(elicitationHost)
        XCTAssertTrue(submittedElicitations.isEmpty)
        XCTAssertTrue(window.makeFirstResponder(countField))
        await pump(elicitationHost)
        try sendKey(to: window)
        try sendKey(to: window)
        await pump(elicitationHost)
        XCTAssertEqual(
            submittedElicitations,
            [
                RemoteElicitationAnswer(
                    requestId: "req-elicitation",
                    action: .accept,
                    content: [
                        "summary": .string("alpha\nbeta"),
                        "count": .number(4),
                        "mode": .string("fast"),
                    ]
                ),
            ]
        )

        // 3. Custom choice ("Other") text field in DesktopElicitationChoiceControl, plus composer isolation in TranscriptDrawer.
        let customChoiceSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("strategy")]),
            "properties": .object([
                "strategy": .object([
                    "type": .string("string"),
                    "title": .string("Strategy"),
                    "enum": .array([.string("canary"), .string("full")]),
                    "default": .string("custom-seed"),
                ]),
            ]),
        ])
        var drawerActions: [RemoteSessionAction] = []
        var drawerElicitationAnswers: [RemoteElicitationAnswer] = []
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true
        )
        let operation = AgentOperationProjection(conversationEpoch: "epoch-q", support: .receipts, receipts: [])
        let composer = DesktopSessionPromptComposer(sessionId: "session-q")
        composer.prompt = "Composer draft"
        let drawerHost = NSHostingView(
            rootView: TranscriptDrawer(
                turns: [],
                imageCapture: nil,
                workflow: workflow,
                operation: operation,
                pendingElicitations: [
                    TrackedElicitation(
                        requestId: "req-other",
                        message: "Pick strategy",
                        schema: customChoiceSchema,
                        requestedAt: requestedAt.ISO8601Format()
                    ).remoteRequest(),
                ],
                workflowProvider: { workflow },
                operationProvider: { operation },
                promptComposer: composer,
                onClose: {},
                onAction: { action in
                    drawerActions.append(action)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onAnswerElicitation: { answer in
                    drawerElicitationAnswers.append(answer)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onPreview: { _ in }
            )
        )
        drawerHost.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        window.contentView = drawerHost
        await pump(drawerHost)

        let drawerFields = findEditableTextFields(in: drawerHost)
        XCTAssertEqual(drawerFields.count, 2)
        let otherField = try XCTUnwrap(drawerFields.first(where: { $0.stringValue == "custom-seed" }))
        let composerField = try XCTUnwrap(drawerFields.first(where: { $0.stringValue == "Composer draft" }))

        // While the elicitation card is valid ("custom-seed") and unanswered, Option-Return and Return in the
        // composer insert a newline and submit only the composer prompt without submitting the question card.
        XCTAssertTrue(window.makeFirstResponder(composerField))
        let composerEditor = try XCTUnwrap(composerField.currentEditor() as? NSTextView)
        composerEditor.setSelectedRange(NSRange(location: composerEditor.string.utf16.count, length: 0))
        try sendKey(to: window, modifiers: [.option])
        await pump(drawerHost)
        composerEditor.insertText("second line", replacementRange: composerEditor.selectedRange())
        await pump(drawerHost)
        XCTAssertTrue(drawerActions.isEmpty)
        XCTAssertTrue(drawerElicitationAnswers.isEmpty)
        XCTAssertEqual(composer.prompt, "Composer draft\nsecond line")

        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(
            drawerActions,
            [
                RemoteSessionAction(
                    kind: .send,
                    prompt: "Composer draft\nsecond line",
                    mode: .immediate
                ),
            ]
        )
        XCTAssertTrue(drawerElicitationAnswers.isEmpty)
        composer.prompt = "Unsent composer draft"
        await pump(drawerHost)

        // Clearing "Other" makes it invalid: Return neither submits nor inserts a newline.
        XCTAssertTrue(window.makeFirstResponder(otherField))
        let otherEditor = try XCTUnwrap(otherField.currentEditor() as? NSTextView)
        otherEditor.selectAll(nil)
        otherEditor.insertText("", replacementRange: otherEditor.selectedRange())
        await pump(drawerHost)
        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(drawerActions.count, 1)
        XCTAssertTrue(drawerElicitationAnswers.isEmpty)
        XCTAssertEqual(otherField.stringValue, "")

        // Multi-line custom choice via Option-Return, then Return in "Other" submits only the elicitation answer.
        try await typeText("blue", into: otherField, in: window, host: drawerHost)
        try sendKey(to: window, modifiers: [.option])
        await pump(drawerHost)
        let otherEditorAfterNewline = try XCTUnwrap(otherField.currentEditor() as? NSTextView)
        otherEditorAfterNewline.insertText("green", replacementRange: otherEditorAfterNewline.selectedRange())
        await pump(drawerHost)
        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(drawerActions.count, 1)
        XCTAssertEqual(
            drawerElicitationAnswers,
            [
                RemoteElicitationAnswer(
                    requestId: "req-other",
                    action: .accept,
                    content: ["strategy": .string("blue\ngreen")]
                ),
            ]
        )
        XCTAssertEqual(composer.prompt, "Unsent composer draft")

        // 4. Multi-select "Other": hidden for MCP elicitations, shown and preselected for agent defaults,
        //    blocks when empty or below minItems, and submits on Return when valid.
        let multiSelectSchema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("toppings")]),
            "properties": .object([
                "toppings": .object([
                    "type": .string("array"),
                    "title": .string("Toppings"),
                    "minItems": .number(1),
                    "maxItems": .number(2),
                    "default": .array([.string("cheese"), .string("olives")]),
                    "items": .object([
                        "type": .string("string"),
                        "enum": .array([.string("cheese"), .string("pepperoni")]),
                    ]),
                ]),
            ]),
        ])
        let mcpMultiHost = NSHostingView(
            rootView: DesktopElicitationCard(
                request: TrackedElicitation(
                    requestId: "req-mcp-multi",
                    message: "Pick toppings",
                    schema: multiSelectSchema,
                    elicitationSource: "mcp-server",
                    requestedAt: requestedAt.ISO8601Format()
                ).remoteRequest(),
                onAnswer: { _ in RemoteWorkflowActionResult(state: .applied) },
                onFocusTerminal: {}
            )
        )
        mcpMultiHost.frame = NSRect(x: 0, y: 0, width: 420, height: 320)
        window.contentView = mcpMultiHost
        await pump(mcpMultiHost)
        XCTAssertTrue(findEditableTextFields(in: mcpMultiHost).isEmpty)

        var submittedMultiAnswers: [RemoteElicitationAnswer] = []
        let agentMultiHost = NSHostingView(
            rootView: DesktopElicitationCard(
                request: TrackedElicitation(
                    requestId: "req-agent-multi",
                    message: "Pick up to two toppings",
                    schema: multiSelectSchema,
                    requestedAt: requestedAt.ISO8601Format()
                ).remoteRequest(),
                onAnswer: { answer in
                    submittedMultiAnswers.append(answer)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onFocusTerminal: {}
            )
        )
        agentMultiHost.frame = NSRect(x: 0, y: 0, width: 420, height: 360)
        window.contentView = agentMultiHost
        await pump(agentMultiHost)

        let multiOtherField = try XCTUnwrap(findEditableTextFields(in: agentMultiHost).first)
        XCTAssertEqual(multiOtherField.stringValue, "olives")
        XCTAssertTrue(window.makeFirstResponder(multiOtherField))
        let multiOtherEditor = try XCTUnwrap(multiOtherField.currentEditor() as? NSTextView)
        multiOtherEditor.selectAll(nil)
        multiOtherEditor.insertText("   ", replacementRange: multiOtherEditor.selectedRange())
        await pump(agentMultiHost)
        try sendKey(to: window)
        await pump(agentMultiHost)
        XCTAssertTrue(submittedMultiAnswers.isEmpty)

        multiOtherEditor.selectAll(nil)
        multiOtherEditor.insertText("capers", replacementRange: multiOtherEditor.selectedRange())
        await pump(agentMultiHost)
        try sendKey(to: window)
        await pump(agentMultiHost)
        XCTAssertEqual(
            submittedMultiAnswers,
            [
                RemoteElicitationAnswer(
                    requestId: "req-agent-multi",
                    action: .accept,
                    content: ["toppings": .array([.string("cheese"), .string("capers")])]
                ),
            ]
        )
    }

    @MainActor
    func testDesktopComposerKeepsFocusAcrossReturnAndSendClicksWithoutStealingFocus() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 420, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        let requestedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let storeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = RemoteAttachmentStore(sessionsDirectory: storeRoot)
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue) + [RemoteAttachmentContract.fileCapability],
            sendReady: true
        )
        var operation = AgentOperationProjection(
            conversationEpoch: "epoch-focus",
            support: .receipts,
            receipts: []
        )
        let composer = DesktopSessionPromptComposer(sessionId: UUID().uuidString, attachmentStore: store)
        var dispatched: [RemoteSessionAction] = []
        var pendingContinuations: [CheckedContinuation<RemoteWorkflowActionResult, Never>] = []

        let drawerHost = NSHostingView(
            rootView: TranscriptDrawer(
                turns: [],
                imageCapture: nil,
                workflow: workflow,
                operation: operation,
                pendingUserInputs: [
                    RemoteUserInputRequest(
                        requestId: "req-other-focus",
                        question: "Fallback focus target",
                        choices: [],
                        allowFreeform: true,
                        requestedAt: requestedAt
                    ),
                ],
                workflowProvider: { workflow },
                operationProvider: { operation },
                promptComposer: composer,
                onClose: {},
                onAction: { action in
                    dispatched.append(action)
                    return await withCheckedContinuation { continuation in
                        pendingContinuations.append(continuation)
                    }
                },
                onAnswerUserInput: { _ in RemoteWorkflowActionResult(state: .applied) },
                onPreview: { _ in }
            )
            .environment(\.controlActiveState, .key)
        )
        drawerHost.sizingOptions = []
        drawerHost.frame = NSRect(x: 0, y: 0, width: 420, height: 520)
        window.contentView = drawerHost
        window.orderBack(nil)
        await pump(drawerHost)

        let fields = findEditableTextFields(in: drawerHost)
        XCTAssertEqual(fields.count, 2)
        let answerField = fields[0]
        let composerField = fields[1]

        // 1. Return sends once, clears the box immediately, keeps focus during and after send, and preserves text typed mid-send.
        try await typeText("First message", into: composerField, in: window, host: drawerHost)
        XCTAssertNotNil(composerField.currentEditor())
        XCTAssertTrue(composer.isPromptFieldFocused)

        try sendKey(to: window)
        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(dispatched, [RemoteSessionAction(kind: .send, prompt: "First message", mode: .immediate)])
        XCTAssertEqual(pendingContinuations.count, 1)
        XCTAssertTrue(composer.isSending)
        XCTAssertEqual(composer.prompt, "")
        XCTAssertNotNil(composerField.currentEditor(), "Composer field must retain focus while send is in flight")
        XCTAssertTrue(composer.isPromptFieldFocused)

        for char in "Next draft" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)

        pendingContinuations.removeFirst().resume(returning: RemoteWorkflowActionResult(state: .applied))
        await pump(drawerHost)
        XCTAssertFalse(composer.isSending)
        XCTAssertEqual(composer.prompt, "Next draft")
        XCTAssertEqual(composerField.stringValue, "Next draft")
        XCTAssertNotNil(composerField.currentEditor(), "Composer field must retain focus after send completes")
        XCTAssertTrue(composer.isPromptFieldFocused)

        // 2. Queued send (.enqueue) via Return clears the field and keeps focus for immediate typing.
        composer.mode = .enqueue
        await pump(drawerHost)
        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(dispatched.last, RemoteSessionAction(kind: .send, prompt: "Next draft", mode: .enqueue))
        XCTAssertEqual(pendingContinuations.count, 1)
        pendingContinuations.removeFirst().resume(returning: RemoteWorkflowActionResult(state: .applied))
        await pump(drawerHost)
        XCTAssertEqual(composer.prompt, "")
        XCTAssertEqual(composerField.stringValue, "")
        XCTAssertNotNil(composerField.currentEditor())
        XCTAssertTrue(composer.isPromptFieldFocused)

        // 3. Rejected and indeterminate sends restore the submitted message alongside mid-send typing while keeping focus,
        //    and a later applied receipt removes only the confirmed message.
        for char in "Retry me" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)
        try sendKey(to: window)
        await pump(drawerHost)
        for char in "After retry" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)
        pendingContinuations.removeFirst().resume(returning: RemoteWorkflowActionResult(state: .rejected, message: "Rejected"))
        await pump(drawerHost)
        XCTAssertEqual(composer.prompt, "Retry me\nAfter retry")
        XCTAssertNotNil(composerField.currentEditor())
        XCTAssertTrue(composer.isPromptFieldFocused)
        composer.prompt = "Uncertain send\r"
        await pump(drawerHost)

        try sendKey(to: window)
        await pump(drawerHost)
        for char in "Follow-up after indeterminate" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)
        pendingContinuations.removeFirst().resume(
            returning: RemoteWorkflowActionResult(state: .indeterminate, message: "Pending", operationId: "op-focus")
        )
        await pump(drawerHost)
        XCTAssertEqual(composer.pendingOperationId, "op-focus")
        XCTAssertEqual(composer.prompt, "Uncertain send\r\nFollow-up after indeterminate")

        operation = AgentOperationProjection(
            conversationEpoch: "epoch-focus",
            support: .receipts,
            receipts: [
                RemoteOperationReceipt(
                    operationId: "op-focus",
                    conversationEpoch: "epoch-focus",
                    kind: RemoteSessionActionKind.send.rawValue,
                    state: .applied,
                    updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                ),
            ]
        )
        composer.reconcileReceipts(operation.receipts, conversationEpoch: operation.conversationEpoch)
        await pump(drawerHost)
        XCTAssertNil(composer.pendingOperationId)
        XCTAssertEqual(composer.prompt, "Follow-up after indeterminate")
        composer.prompt = ""
        XCTAssertTrue(window.makeFirstResponder(composerField))
        await pump(drawerHost)

        // 4. Clicking the Send button while focused sends and leaves focus in the message box.
        for char in "Clicked send" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)
        let sendSegmentPoint = NSPoint(x: drawerHost.bounds.maxX - 12 - 24 - 20, y: 24)
        try sendClick(in: window, point: sendSegmentPoint)
        await pump(drawerHost)
        XCTAssertEqual(dispatched.last, RemoteSessionAction(kind: .send, prompt: "Clicked send", mode: .enqueue))
        XCTAssertEqual(pendingContinuations.count, 1)
        pendingContinuations.removeFirst().resume(returning: RemoteWorkflowActionResult(state: .applied))
        await pump(drawerHost)
        XCTAssertEqual(composer.prompt, "")
        XCTAssertNotNil(composerField.currentEditor(), "Clicking Send must keep focus in the message box")
        XCTAssertTrue(composer.isPromptFieldFocused)

        // 5. Moving focus into another control during send must not steal focus back when the send finishes.
        for char in "Switch focus mid-send" {
            try sendKey(to: window, characters: String(char), keyCode: 0)
        }
        await pump(drawerHost)
        try sendKey(to: window)
        await pump(drawerHost)
        XCTAssertEqual(pendingContinuations.count, 1)
        XCTAssertTrue(window.makeFirstResponder(answerField))
        await pump(drawerHost)
        XCTAssertNotNil(answerField.currentEditor())
        XCTAssertNil(composerField.currentEditor())
        XCTAssertFalse(composer.isPromptFieldFocused)

        pendingContinuations.removeFirst().resume(returning: RemoteWorkflowActionResult(state: .applied))
        await pump(drawerHost)
        XCTAssertNotNil(answerField.currentEditor(), "Completing send must not steal focus from the answer box")
        XCTAssertNil(composerField.currentEditor())
        XCTAssertFalse(composer.isPromptFieldFocused)

        // 6. Missing attachment file during verification restores the submitted prompt without invoking onAction.
        let noteURL = storeRoot.appendingPathComponent("note.md")
        try Data("# Note\n".utf8).write(to: noteURL)
        await composer.attachFiles([noteURL], workflow: workflow, operation: operation)
        let stagedId = try XCTUnwrap(composer.attachments.first?.id)
        try FileManager.default.removeItem(at: store.root.appendingPathComponent("\(stagedId).image"))
        let dispatchedBeforeMissingAttachment = dispatched.count
        composer.prompt = "Send with missing attachment"
        await composer.send(
            workflow: workflow,
            operation: operation,
            onAction: { action in
                dispatched.append(action)
                return RemoteWorkflowActionResult(state: .applied)
            }
        )
        XCTAssertEqual(dispatched.count, dispatchedBeforeMissingAttachment)
        XCTAssertFalse(composer.isSending)
        XCTAssertEqual(composer.prompt, "Send with missing attachment")
        XCTAssertEqual(composer.attachments.count, 1)
    }

    @MainActor
    func testPerformLocalUserInputAndElicitationAnswersWriteHandoffAndResolveWhenQuestionClearsOrReceiptArrives() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(id: "session-local-q", title: "target", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        let userInputResponseURL = directory.appendingPathComponent("\(session.id).user-input-response.json")
        let elicitationResponseURL = directory.appendingPathComponent("\(session.id).elicitation-response.json")
        let markerURL = directory.appendingPathComponent("\(session.id).copilot-session")
        try Data("copilot-session".utf8).write(to: markerURL)

        let schema: RemoteJSONValue = .object([
            "type": .string("object"),
            "required": .array([.string("choice")]),
            "properties": .object([
                "choice": .object([
                    "type": .string("string"),
                    "enum": .array([.string("alpha"), .string("beta")]),
                ]),
            ]),
        ])

        func writeSnapshot(
            userInputs: [TrackedUserInput]?,
            elicitations: [TrackedElicitation]?,
            epoch: String? = "epoch-local-1",
            receipts: [TrackedOperationReceipt]? = nil
        ) throws {
            let nowString = ISO8601DateFormatter().string(from: Date())
            let snapshot = AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: nowString,
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: userInputs,
                trackedElicitations: elicitations,
                copilotSessionId: "copilot-session",
                conversationEpoch: epoch,
                operationReceiptVersion: epoch == nil ? nil : 1,
                operationReceipts: receipts
            )
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        }

        let initialUserInput = TrackedUserInput(
            requestId: "req-u1",
            question: "Proceed?",
            choices: ["Yes", "No"],
            allowFreeform: true,
            requestedAt: ISO8601DateFormatter().string(from: Date()),
            agentId: nil
        )
        let initialElicitation = TrackedElicitation(
            requestId: "req-e1",
            message: "Pick option",
            mode: "form",
            url: nil,
            schema: schema,
            elicitationSource: nil,
            requestedAt: ISO8601DateFormatter().string(from: Date()),
            agentId: nil
        )
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory
        )

        // 0. Receiptless snapshot (epoch == nil) is rejected without writing a handoff file.
        try writeSnapshot(userInputs: [initialUserInput], elicitations: [initialElicitation], epoch: nil)
        let receiptlessUserInput = await model.performLocalUserInputAnswer(
            sessionId: session.id,
            answer: RemoteUserInputAnswer(requestId: "req-u1", answer: "Yes", wasFreeform: false),
            maxAttempts: 1,
            pollInterval: .milliseconds(5)
        )
        XCTAssertEqual(receiptlessUserInput.state, .rejected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: userInputResponseURL.path))

        try writeSnapshot(userInputs: [initialUserInput], elicitations: [initialElicitation])
        model.refreshAgentActivitySnapshots()
        XCTAssertEqual(model.sessionPendingUserInputs(sessionId: session.id).map(\.requestId), ["req-u1"])
        XCTAssertEqual(model.sessionPendingElicitations(sessionId: session.id).map(\.requestId), ["req-e1"])

        // 1. User input answer writes user-input-response.json and resolves to .applied via terminal receipt.
        Task {
            try? await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(25)))
            if let data = try? Data(contentsOf: userInputResponseURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let opId = obj["operationId"] as? String {
                XCTAssertEqual(obj["requestId"] as? String, "req-u1")
                XCTAssertEqual(obj["answer"] as? String, "Yes")
                try? FileManager.default.removeItem(at: userInputResponseURL)
                try? writeSnapshot(
                    userInputs: [],
                    elicitations: [initialElicitation],
                    receipts: [
                        TrackedOperationReceipt(
                            operationId: opId,
                            conversationEpoch: "epoch-local-1",
                            kind: CLISDKOperationKind.answerUserInput.rawValue,
                            state: .applied,
                            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                            errorCode: nil,
                            payloadFingerprint: nil
                        ),
                    ]
                )
            }
        }
        let appliedUserInput = await model.performLocalUserInputAnswer(
            sessionId: session.id,
            answer: RemoteUserInputAnswer(requestId: "req-u1", answer: "Yes", wasFreeform: false),
            maxAttempts: 10,
            pollInterval: .milliseconds(15)
        )
        XCTAssertEqual(appliedUserInput.state, .applied)

        // 2. Question disappearance followed by a .rejected receipt must NOT report .applied.
        let secondUserInput = TrackedUserInput(
            requestId: "req-u2",
            question: "Deploy?",
            choices: ["Yes", "No"],
            allowFreeform: true,
            requestedAt: ISO8601DateFormatter().string(from: Date()),
            agentId: nil
        )
        try writeSnapshot(userInputs: [secondUserInput], elicitations: [initialElicitation])
        Task {
            try? await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(25)))
            if let data = try? Data(contentsOf: userInputResponseURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let opId = obj["operationId"] as? String {
                try? FileManager.default.removeItem(at: userInputResponseURL)
                // First publish a snapshot where the question disappeared without a receipt yet.
                try? writeSnapshot(userInputs: [], elicitations: [initialElicitation], receipts: [])
                try? await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(30)))
                // Then publish the losing operation's terminal .rejected receipt.
                try? writeSnapshot(
                    userInputs: [],
                    elicitations: [initialElicitation],
                    receipts: [
                        TrackedOperationReceipt(
                            operationId: opId,
                            conversationEpoch: "epoch-local-1",
                            kind: CLISDKOperationKind.answerUserInput.rawValue,
                            state: .rejected,
                            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                            errorCode: "not-pending",
                            payloadFingerprint: nil
                        ),
                    ]
                )
            }
        }
        let rejectedResult = await model.performLocalUserInputAnswer(
            sessionId: session.id,
            answer: RemoteUserInputAnswer(requestId: "req-u2", answer: "Yes", wasFreeform: false),
            maxAttempts: 10,
            pollInterval: .milliseconds(15)
        )
        XCTAssertEqual(rejectedResult.state, .rejected)
        XCTAssertEqual(rejectedResult.message, "Copilot did not apply this answer.")

        // 3. Conflict: when another handoff file is already on disk, returns .rejected with conflict message.
        try writeSnapshot(userInputs: [secondUserInput], elicitations: [initialElicitation])
        try Data(#"{"operationId":"other-op","conversationEpoch":"epoch-local-1","kind":"answer-user-input"}"#.utf8)
            .write(to: userInputResponseURL)
        let conflictResult = await model.performLocalUserInputAnswer(
            sessionId: session.id,
            answer: RemoteUserInputAnswer(requestId: "req-u2", answer: "Yes", wasFreeform: false),
            maxAttempts: 2,
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(conflictResult.state, .rejected)
        XCTAssertEqual(conflictResult.message, "Another answer is already in progress.")
        try? FileManager.default.removeItem(at: userInputResponseURL)

        // 4. Timeout (.indeterminate) + reopen idempotency: retains operationId across retry and reconciles delayed receipt.
        let timeoutResult = await model.performLocalElicitationAnswer(
            sessionId: session.id,
            answer: RemoteElicitationAnswer(
                requestId: "req-e1",
                action: .accept,
                content: ["choice": .string("alpha")]
            ),
            maxAttempts: 2,
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(timeoutResult.state, .indeterminate)
        let firstOpId = try XCTUnwrap(timeoutResult.operationId)
        try? FileManager.default.removeItem(at: elicitationResponseURL)

        // Retrying a different answer while the original operation is unconfirmed is rejected as a conflict.
        let retryMismatched = await model.performLocalElicitationAnswer(
            sessionId: session.id,
            answer: RemoteElicitationAnswer(
                requestId: "req-e1",
                action: .accept,
                content: ["choice": .string("beta")]
            ),
            maxAttempts: 2,
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(retryMismatched.state, .rejected)
        XCTAssertEqual(retryMismatched.message, "Another answer is already in progress.")
        XCTAssertEqual(retryMismatched.operationId, firstOpId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elicitationResponseURL.path))

        // Retrying the identical answer while still unconfirmed returns .indeterminate with the same operationId.
        let retryStillUnconfirmed = await model.performLocalElicitationAnswer(
            sessionId: session.id,
            answer: RemoteElicitationAnswer(
                requestId: "req-e1",
                action: .accept,
                content: ["choice": .string("alpha")]
            ),
            maxAttempts: 2,
            pollInterval: .milliseconds(10)
        )
        XCTAssertEqual(retryStillUnconfirmed.state, .indeterminate)
        XCTAssertEqual(retryStillUnconfirmed.operationId, firstOpId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: elicitationResponseURL.path))

        // Once a delayed .rejected receipt arrives, retrying with a different answer clears the cached operation,
        // writes a new handoff with a fresh operationId, and resolves when its receipt arrives.
        try writeSnapshot(
            userInputs: [],
            elicitations: [initialElicitation],
            receipts: [
                TrackedOperationReceipt(
                    operationId: firstOpId,
                    conversationEpoch: "epoch-local-1",
                    kind: CLISDKOperationKind.answerElicitation.rawValue,
                    state: .rejected,
                    updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                    errorCode: "invalid",
                    payloadFingerprint: nil
                ),
            ]
        )
        Task {
            try? await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(25)))
            if let data = try? Data(contentsOf: elicitationResponseURL),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let retryOpId = obj["operationId"] as? String {
                XCTAssertNotEqual(retryOpId, firstOpId)
                try? FileManager.default.removeItem(at: elicitationResponseURL)
                try? writeSnapshot(
                    userInputs: [],
                    elicitations: [],
                    receipts: [
                        TrackedOperationReceipt(
                            operationId: retryOpId,
                            conversationEpoch: "epoch-local-1",
                            kind: CLISDKOperationKind.answerElicitation.rawValue,
                            state: .applied,
                            updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                            errorCode: nil,
                            payloadFingerprint: nil
                        ),
                    ]
                )
            }
        }
        let retriedAfterRejection = await model.performLocalElicitationAnswer(
            sessionId: session.id,
            answer: RemoteElicitationAnswer(
                requestId: "req-e1",
                action: .accept,
                content: ["choice": .string("beta")]
            ),
            maxAttempts: 10,
            pollInterval: .milliseconds(15)
        )
        XCTAssertEqual(retriedAfterRejection.state, .applied)
        XCTAssertNotEqual(retriedAfterRejection.operationId, firstOpId)
    }

    @MainActor
    func testTranscriptDrawerOpensAtBottomWithLongTranscriptAndFullWidthIsolatesTerminalFocus() async throws {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let turns: [TranscriptTurn] = (1...40).map { (index: Int) -> TranscriptTurn in
            let start = now.addingTimeInterval(Double(index * 10))
            let msgTime = now.addingTimeInterval(Double(index * 10 + 3))
            let end = now.addingTimeInterval(Double(index * 10 + 5))
            return TranscriptTurn(
                id: "turn-\(index)",
                startedAt: start,
                endedAt: end,
                kind: "user",
                userContent: "User prompt \(index)\nLine 2 of prompt \(index)",
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(index)",
                        timestamp: msgTime,
                        content: "Assistant response \(index)\nDetailed explanation line 2\nLine 3"
                    ),
                ],
                tools: [],
                isAborted: false
            )
        }

        let suiteName = "AppLogicTests.fullWidthFocus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let drawer = TranscriptDrawer(
            turns: turns,
            imageCapture: nil,
            workflow: nil,
            operation: .unavailable,
            workflowProvider: nil,
            operationProvider: nil,
            promptComposer: nil,
            onClose: {},
            onAction: { _ in RemoteWorkflowActionResult(state: .rejected) },
            onPreview: { _ in }
        )
        .defaultAppStorage(defaults)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: drawer)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
        }

        let scrollDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < scrollDeadline {
            await pump(host)
            if let sv = findTranscriptScrollView(in: host),
               let dv = sv.documentView,
               dv.bounds.height > 1_500 {
                break
            }
        }

        let scrollView = try XCTUnwrap(findTranscriptScrollView(in: host))
        let docView = try XCTUnwrap(scrollView.documentView)
        let docHeight = docView.bounds.height
        let visibleRect = scrollView.contentView.documentVisibleRect
        XCTAssertGreaterThan(docHeight, 1_500)
        if docView.isFlipped {
            XCTAssertGreaterThanOrEqual(visibleRect.maxY, docHeight - 60)
        } else {
            XCTAssertLessThanOrEqual(visibleRect.minY, 60)
        }

        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(host)
        defaults.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(host)

        // Verify terminal hiding and focus when full-width transcript drawer covers the terminal.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let envKeys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH"]
        let previousEnv = Dictionary(uniqueKeysWithValues: envKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previousEnv {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let session = Session(id: "s-focus", title: "focus", cwd: root.path)
        let project = Project(name: "P", cwd: root.path, sessions: [session], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        defer { model.detachAllClients() }
        let controller = try XCTUnwrap(model.controller(for: session.id))
        let terminal = controller.terminalView
        model.refreshSelectedTranscriptController()
        let detailHost = NSHostingView(
            rootView: DetailView(model: model, onPreview: { _ in })
                .defaultAppStorage(defaults)
        )
        detailHost.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = detailHost
        await pump(detailHost)
        XCTAssertFalse(terminal.isHidden)
        XCTAssertTrue(window.firstResponder === terminal)

        // Without drawer content, an open flag does not treat the terminal as covered.
        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        model.openTranscriptDrawer(sessionId: session.id)
        await pump(detailHost)
        XCTAssertFalse(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertFalse(terminal.isHidden)
        XCTAssertTrue(window.firstResponder === terminal)

        // Once the session has drawer content (e.g. a pending question), full-width mode hides the terminal and relinquishes focus.
        model.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: [
                TrackedUserInput(
                    requestId: "req-focus",
                    question: "Continue?",
                    choices: ["Yes", "No"],
                    allowFreeform: false,
                    requestedAt: ISO8601DateFormatter().string(from: Date()),
                    agentId: nil
                ),
            ]
        )
        await pump(detailHost)
        XCTAssertTrue(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertTrue(terminal.isHidden)
        XCTAssertFalse(window.firstResponder === terminal)

        model.focusActiveTerminal()
        XCTAssertFalse(window.firstResponder === terminal)

        // Toggling expand and collapse repeatedly through DetailView hides/unhides and focuses the terminal.
        for _ in 0..<2 {
            defaults.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            await pump(detailHost)
            XCTAssertFalse(terminal.isHidden)
            XCTAssertTrue(window.firstResponder === terminal)

            defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            await pump(detailHost)
            XCTAssertTrue(terminal.isHidden)
            XCTAssertFalse(window.firstResponder === terminal)
        }

        // Clearing the last drawer content while open unhides and focuses the terminal via reveal.
        model.projects[0].sessions[0].agentActivity = nil
        await pump(detailHost)
        XCTAssertFalse(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertFalse(terminal.isHidden)
        XCTAssertTrue(window.firstResponder === terminal)

        // Collapsing from full-width with an active question editor preserves editor focus,
        // while closing the drawer from full-width unhides and focuses the terminal.
        model.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: [
                TrackedUserInput(
                    requestId: "req-focus-2",
                    question: "Continue?",
                    choices: ["Yes"],
                    allowFreeform: true,
                    requestedAt: ISO8601DateFormatter().string(from: Date()),
                    agentId: nil
                ),
            ]
        )
        await pump(detailHost)
        XCTAssertTrue(terminal.isHidden)
        let answerField = try XCTUnwrap(findEditableTextFields(in: detailHost).first)
        XCTAssertTrue(window.makeFirstResponder(answerField))
        XCTAssertNotNil(answerField.currentEditor())

        defaults.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(detailHost)
        XCTAssertFalse(terminal.isHidden)
        XCTAssertNotNil(answerField.currentEditor())
        XCTAssertFalse(window.firstResponder === terminal)

        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(detailHost)
        XCTAssertTrue(terminal.isHidden)
        XCTAssertNotNil(answerField.currentEditor())

        model.closeTranscriptDrawer(sessionId: session.id)
        model.focusActiveTerminal()
        await pump(detailHost)
        XCTAssertFalse(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertFalse(terminal.isHidden)
        XCTAssertTrue(window.firstResponder === terminal)

        // With no agentActivity, opening in full-width keeps the terminal visible until a transcript snapshot loads.
        model.projects[0].sessions[0].agentActivity = nil
        model.openTranscriptDrawer(sessionId: session.id)
        await pump(detailHost)
        XCTAssertFalse(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertFalse(terminal.isHidden)

        Paths.ensureStateDir()
        let snapshotPath = URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: session.id))
        defer { try? FileManager.default.removeItem(at: snapshotPath) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(
            TranscriptSnapshot(
                schemaVersion: 3,
                updatedAt: now,
                copilotSessionId: "cid-focus",
                turns: [turns[0]]
            )
        ).write(to: snapshotPath, options: .atomic)
        model.activeTranscriptController?.reload()
        let reloadDeadline = ContinuousClock.now + .seconds(5)
        while model.activeTranscriptController?.snapshot == nil, ContinuousClock.now < reloadDeadline {
            await pump(detailHost)
        }
        await pump(detailHost)
        XCTAssertNotNil(model.activeTranscriptController?.snapshot)
        XCTAssertTrue(model.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertTrue(terminal.isHidden)
        XCTAssertFalse(window.firstResponder === terminal)
    }

    @MainActor
    func testDefaultViewSettingBehavior() throws {
        let suite = "default-view-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let s1 = Session(id: "s-1", title: "one", cwd: root.path)
        let s2 = Session(id: "s-2", title: "two", cwd: root.path)
        let s3 = Session(id: "s-3", title: "three", cwd: root.path)
        let project = Project(
            name: "P",
            cwd: root.path,
            sessions: [s1, s2, s3],
            selectedSessionId: s1.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        // 1. Default is Terminal: restored session opens in terminal.
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        defer { model.detachAllClients() }
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s1.id))
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s2.id))

        // 2. Changing to Transcript leaves already-seen s1 alone, but opens unseen s2 once.
        defaults.set(
            TranscriptDrawer.DefaultView.transcript.rawValue,
            forKey: TranscriptDrawer.defaultViewKey
        )
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s1.id))

        model.selectSession(projectId: project.id, sessionId: s2.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: s2.id))
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s3.id))

        // Switching back to already-seen s1 keeps it in terminal.
        model.selectSession(projectId: project.id, sessionId: s1.id)
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s1.id))

        // 3. Closing s2's transcript sticks when switching away and back.
        model.selectSession(projectId: project.id, sessionId: s2.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: s2.id))
        model.closeTranscriptDrawer(sessionId: s2.id)
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s2.id))

        model.selectSession(projectId: project.id, sessionId: s1.id)
        model.selectSession(projectId: project.id, sessionId: s2.id)
        XCTAssertFalse(model.isTranscriptDrawerOpen(sessionId: s2.id))

        // 4. Unseen s3 opens in Transcript; changing setting back to Terminal leaves s3 open.
        model.selectSession(projectId: project.id, sessionId: s3.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: s3.id))
        defaults.set(
            TranscriptDrawer.DefaultView.terminal.rawValue,
            forKey: TranscriptDrawer.defaultViewKey
        )
        model.selectSession(projectId: project.id, sessionId: s1.id)
        model.selectSession(projectId: project.id, sessionId: s3.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: s3.id))

        // 5. App launch with Transcript selected opens only the restored selected session,
        // and switching to an unseen session with drawer content in full-width mode relinquishes terminal focus.
        defaults.set(
            TranscriptDrawer.DefaultView.transcript.rawValue,
            forKey: TranscriptDrawer.defaultViewKey
        )
        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        let relaunched = AppModel(
            stateRepository: repository,
            isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images-2")),
            defaults: defaults
        )
        defer { relaunched.detachAllClients() }
        XCTAssertEqual(relaunched.globalSelectedSessionId, s3.id)
        XCTAssertTrue(relaunched.isTranscriptDrawerOpen(sessionId: s3.id))
        XCTAssertFalse(relaunched.isTranscriptDrawerOpen(sessionId: s1.id))
        XCTAssertFalse(relaunched.isTranscriptDrawerOpen(sessionId: s2.id))
        XCTAssertNil(relaunched.activeTranscriptController)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let container = TerminalsContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.contentView = container
        defer { window.contentView = nil }
        let s3Terminal = try XCTUnwrap(relaunched.controller(for: s3.id)?.terminalView)
        let s1Terminal = try XCTUnwrap(relaunched.controller(for: s1.id)?.terminalView)
        func syncContainer() {
            container.sync(
                order: [s1.id, s3.id],
                active: relaunched.globalSelectedSessionId,
                showsTerminal: !relaunched.isActiveTerminalCoveredByTranscriptDrawer(),
                emptyHint: ("", ""),
                onNew: {},
                provider: { relaunched.terminalView(for: $0) }
            )
        }
        syncContainer()
        XCTAssertFalse(s3Terminal.isHidden)
        XCTAssertTrue(window.firstResponder === s3Terminal)

        relaunched.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: ISO8601DateFormatter().string(from: Date()),
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: [
                TrackedUserInput(
                    requestId: "req-default-view",
                    question: "Proceed?",
                    choices: ["Yes"],
                    allowFreeform: false,
                    requestedAt: ISO8601DateFormatter().string(from: Date()),
                    agentId: nil
                ),
            ]
        )
        relaunched.selectSession(projectId: project.id, sessionId: s1.id)
        syncContainer()
        XCTAssertTrue(relaunched.isTranscriptDrawerOpen(sessionId: s1.id))
        XCTAssertTrue(relaunched.isActiveTerminalCoveredByTranscriptDrawer())
        XCTAssertTrue(s1Terminal.isHidden)
        XCTAssertTrue(s3Terminal.isHidden)
        XCTAssertFalse(window.firstResponder === s3Terminal)
        XCTAssertFalse(window.firstResponder === s1Terminal)

        // Switching away to uncovered s3 reveals and focuses s3Terminal; switching back to covered s1 hides both.
        relaunched.selectSession(projectId: project.id, sessionId: s3.id)
        syncContainer()
        XCTAssertFalse(s3Terminal.isHidden)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        relaunched.selectSession(projectId: project.id, sessionId: s1.id)
        syncContainer()
        XCTAssertTrue(s1Terminal.isHidden)
        XCTAssertTrue(s3Terminal.isHidden)
        XCTAssertFalse(window.firstResponder === s3Terminal)
        XCTAssertFalse(window.firstResponder === s1Terminal)
    }

    /// Typing in the full-width transcript's message box re-measured every message at the box's
    /// one-line text width, 534 pt after ten words and 3766 pt after seventy, because that was the
    /// workspace pane's ideal width and its split view measures the pane there. Until #341 the
    /// messages were left wrapped at that width, so the transcript changed width as you typed.
    @MainActor
    func testTypingInTheFullWidthTranscriptLeavesItsMessagesAtTheirWidth() async throws {
        _ = NSApplication.shared
        let suite = "full-width-typing-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET", "COPILOT_PROJECTS_DTACH"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let now = Date()
        let session = Session(title: "Typing", cwd: root.path)
        let project = Project(name: "Projects", cwd: root.path, sessions: [session], selectedSessionId: session.id)
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        Paths.ensureStateDir()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TranscriptSnapshot(
            schemaVersion: 3, updatedAt: now, copilotSessionId: "conversation-1",
            turns: [TranscriptTurn(
                id: "t1", startedAt: now.addingTimeInterval(-10), endedAt: now.addingTimeInterval(-5),
                kind: "user", userContent: "Hello",
                assistantMessages: [TranscriptAssistantMessage(
                    id: "m1", timestamp: now,
                    content: String(repeating: "A reply that wraps over a few lines. ", count: 20)
                )],
                tools: [], isAborted: false
            )]
        )).write(to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: session.id)))

        let model = AppModel(
            stateRepository: repository, isAppActive: { false },
            agentActivityDirectory: root, resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        defer { model.detachAllClients() }
        _ = try XCTUnwrap(model.controller(for: session.id))
        model.refreshSelectedTranscriptController()
        try XCTUnwrap(model.activeTranscriptController).reload()
        model.projects[0].sessions[0].agentActivity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: ISO8601DateFormatter().string(from: now),
            foregroundTurnActive: false, scheduledTurnActive: false, activeSubagents: [], schedules: [],
            idleGeneration: 1, lastIdleAborted: false, lastIdleTurnKind: "user", error: nil,
            workflow: RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
                capabilities: ["session-send"], sendReady: true
            )
        )
        model.openTranscriptDrawer(sessionId: session.id)

        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 1440, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: RootView(
            model: model, input: WorkspaceInputController(model: model), showsProjects: .constant(true)
        ).defaultAppStorage(defaults))
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
        }
        // Open in the side drawer, then expand it, as the reporter did.
        await pump(host)
        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(host)
        let messages = MarkdownSelectableTextView.peerSelectableTextViews(in: host)
        XCTAssertFalse(messages.isEmpty)
        XCTAssertTrue(messages.allSatisfy { $0.bounds.width > 420 }, "The transcript should be full width")
        let measuredWidths = messages.map(\.preferredMaxLayoutWidth)
        let field = try XCTUnwrap(findEditableTextFields(in: host).first { $0.placeholderString == "Message Copilot" })
        let oneLineHeight = field.frame.height

        try await typeText(String(repeating: "typing a longer message ", count: 12), into: field, in: window, host: host)
        XCTAssertGreaterThan(field.frame.height, oneLineHeight, "The message should wrap")
        XCTAssertEqual(messages.map(\.preferredMaxLayoutWidth), measuredWidths)
        for message in messages {
            XCTAssertEqual(message.textContainer?.size.width, message.bounds.width)
        }
    }

    @MainActor
    func testSelectingSessionFocusesComposerOrTerminalWithoutStealingFocus() async throws {
        _ = NSApplication.shared
        let suite = "focus-on-select-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["SHELL", "COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_DTACH"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, ProcessInfo.processInfo.environment[$0]) })
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        defer {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        func makeActivity(
            withWorkflow: Bool = true,
            questionId: String? = nil
        ) -> AgentActivitySnapshot {
            AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: ISO8601DateFormatter().string(from: Date()),
                foregroundTurnActive: false,
                scheduledTurnActive: false,
                activeSubagents: [],
                schedules: [],
                idleGeneration: 0,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: nil,
                trackedUserInputs: questionId.map {
                    [
                        TrackedUserInput(
                            requestId: $0,
                            question: "Question \($0)?",
                            choices: [],
                            allowFreeform: true,
                            requestedAt: ISO8601DateFormatter().string(from: Date()),
                            agentId: nil
                        ),
                    ]
                },
                copilotSessionId: "copilot-session",
                conversationEpoch: "epoch-1",
                operationReceiptVersion: 1,
                operationReceipts: [],
                workflow: withWorkflow
                    ? RemoteSessionWorkflow(
                        observedAtMilliseconds: nowMs,
                        capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
                        sendReady: true
                    )
                    : nil
            )
        }

        let s1 = Session(id: "s-open", title: "Open Drawer", cwd: root.path)
        let s2 = Session(id: "s-closed", title: "Closed Drawer", cwd: root.path)
        let s3 = Session(id: "s-delayed", title: "Delayed Workflow", cwd: root.path)
        let s4 = Session(id: "s-default-view", title: "Default View", cwd: root.path)
        let s5 = Session(id: "s-other-project", title: "Other Project Open", cwd: root.path)
        let project = Project(
            id: "p-focus",
            name: "Focus Project",
            cwd: root.path,
            sessions: [s1, s2, s3, s4],
            selectedSessionId: s2.id
        )
        let project2 = Project(
            id: "p-focus-2",
            name: "Second Project",
            cwd: root.path,
            sessions: [s5],
            selectedSessionId: s5.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project, project2], selectedProjectId: project.id))

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        defer { model.detachAllClients() }

        model.projects[0].sessions[0].agentActivity = makeActivity(withWorkflow: true, questionId: "q-1")
        model.projects[0].sessions[1].agentActivity = makeActivity(withWorkflow: true)
        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: false, questionId: "q-3")
        model.projects[0].sessions[3].agentActivity = makeActivity(withWorkflow: true)
        model.projects[1].sessions[0].agentActivity = makeActivity(withWorkflow: true)
        model.openTranscriptDrawer(sessionId: s1.id)
        model.openTranscriptDrawer(sessionId: s3.id)
        model.openTranscriptDrawer(sessionId: s5.id)
        model.bootstrapIfNeeded()

        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: DetailView(model: model, onPreview: { _ in })
                .defaultAppStorage(defaults)
                .environment(\.controlActiveState, .key)
        )
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.makeFirstResponder(nil)
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        await pump(host)
        XCTAssertFalse(window.isKeyWindow)
        let s1Terminal = try XCTUnwrap(model.terminalView(for: s1.id))
        let s2Terminal = try XCTUnwrap(model.terminalView(for: s2.id))
        let s3Terminal = try XCTUnwrap(model.terminalView(for: s3.id))
        XCTAssertTrue(window.firstResponder === s2Terminal)

        // 1. Switching to s1 (transcript open in side drawer) focuses the message box.
        model.selectSession(projectId: project.id, sessionId: s1.id)
        await pump(host)
        let s1Fields = findEditableTextFields(in: host)
        XCTAssertEqual(s1Fields.count, 2)
        let s1AnswerField = s1Fields[0]
        let s1ComposerField = s1Fields[1]
        XCTAssertNil(s1AnswerField.currentEditor())
        XCTAssertNotNil(s1ComposerField.currentEditor())
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        XCTAssertFalse(window.isKeyWindow)

        // 2. Switching to s2 (transcript closed) focuses the terminal.
        model.selectSessionByIndex(1)
        await pump(host)
        XCTAssertTrue(window.firstResponder === s2Terminal)

        // 3. Switching to s3 (transcript open, workflow nil initially) focuses terminal in side-drawer mode,
        //    and then focuses the composer as soon as workflow loads.
        model.selectSessionByIndex(2)
        await pump(host)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s3.id).shouldFocusOnAppear)

        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: true, questionId: "q-3")
        await pump(host)
        let s3ComposerField = try XCTUnwrap(
            findEditableTextFields(in: host).first { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(s3ComposerField.currentEditor())
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s3.id).isPromptFieldFocused)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s3.id).shouldFocusOnAppear)

        // 4. Switching directly between two open-transcript sessions (s3 -> s1) via Back history focuses s1's composer,
        //    and Forward history (s1 -> s2) focuses s2's terminal.
        model.navigateSessionBack()
        model.navigateSessionBack()
        await pump(host)
        XCTAssertEqual(model.globalSelectedSessionId, s1.id)
        let s1ComposerAfterBack = try XCTUnwrap(
            findEditableTextFields(in: host).last { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(s1ComposerAfterBack.currentEditor())
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)

        model.navigateSessionForward()
        await pump(host)
        XCTAssertEqual(model.globalSelectedSessionId, s2.id)
        XCTAssertTrue(window.firstResponder === s2Terminal)

        // 5. Default-view setting (#307) opening the transcript on first visit (and full-width mode) focuses the composer,
        //    and collapsing full-width to side-drawer preserves the focused composer while unhiding the terminal.
        defaults.set(
            TranscriptDrawer.DefaultView.transcript.rawValue,
            forKey: TranscriptDrawer.defaultViewKey
        )
        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        let input = WorkspaceInputController(model: model)
        input.openFromSessionFinder(s4.id)
        await pump(host)
        let s4Terminal = try XCTUnwrap(model.terminalView(for: s4.id))
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: s4.id))
        XCTAssertTrue(s4Terminal.isHidden)
        let s4ComposerField = try XCTUnwrap(
            findEditableTextFields(in: host).last { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(s4ComposerField.currentEditor())
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s4.id).isPromptFieldFocused)
        defaults.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        await pump(host)
        XCTAssertFalse(s4Terminal.isHidden)
        XCTAssertNotNil(s4ComposerField.currentEditor())
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s4.id).isPromptFieldFocused)
        XCTAssertFalse(window.firstResponder === s4Terminal)

        // 6. With the side drawer open and its composer or transcript text holding focus, clicking s1's terminal
        //    focuses it, typing reaches its shell, and background updates or re-selecting s1 do not move focus back.
        model.show(projectId: project.id, sessionId: s1.id)
        await pump(host)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        let terminalPoint = NSPoint(x: 100, y: 300)
        XCTAssertTrue(window.contentView?.hitTest(terminalPoint) === s1Terminal)
        // A window that isn't key drops the click, so put this one in the state the app's window is in when clicked.
        window.becomeKey()
        try sendClick(in: window, point: terminalPoint)
        await pump(host)
        XCTAssertTrue(window.firstResponder === s1Terminal)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        func s1TerminalShowsTypedKey() -> Bool {
            s1Terminal.terminalStateSnapshot().visibleRows.contains { $0.text.contains("z") }
        }
        XCTAssertFalse(s1TerminalShowsTypedKey())
        try sendKey(to: window, characters: "z", keyCode: 6)
        let echoDeadline = ContinuousClock.now + .seconds(5)
        while !s1TerminalShowsTypedKey(), ContinuousClock.now < echoDeadline {
            await pump(host)
        }
        XCTAssertTrue(s1TerminalShowsTypedKey())
        XCTAssertEqual(model.sessionPromptComposer(sessionId: s1.id).prompt, "")
        let transcriptText = try XCTUnwrap(MarkdownSelectableTextView.peerSelectableTextViews(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(transcriptText))
        try sendClick(in: window, point: terminalPoint)
        XCTAssertTrue(window.firstResponder === s1Terminal)
        window.resignKey()
        model.projects[0].sessions[0].agentActivity = makeActivity(withWorkflow: true, questionId: "q-1")
        model.setStatus(sessionId: s2.id, status: .running, text: "Working", timestamp: 10, source: "test")
        model.setStatus(sessionId: s2.id, status: .idle, text: nil, timestamp: 20, source: "test")
        model.selectSession(projectId: project.id, sessionId: s1.id)
        model.focusActiveTerminal()
        await pump(host)
        XCTAssertTrue(window.firstResponder === s1Terminal)

        // 7. Typing/clicking in the terminal or typing in a pending question box is never interrupted by re-selection, focusActiveTerminal, or a delayed workflow load.
        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: false, questionId: "q-3")
        model.selectSession(projectId: project.id, sessionId: s3.id)
        await pump(host)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        let terminalKeyEvent = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "l",
                charactersIgnoringModifiers: "l",
                isARepeat: false,
                keyCode: 37
            )
        )
        _ = input.handleKeyDown(terminalKeyEvent)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s3.id).shouldFocusOnAppear)
        model.selectSession(projectId: project.id, sessionId: s2.id)
        model.selectSession(projectId: project.id, sessionId: s3.id)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s3.id).shouldFocusOnAppear)
        s3Terminal.paste(self)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s3.id).shouldFocusOnAppear)
        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: true, questionId: "q-3")
        await pump(host)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s3.id).isPromptFieldFocused)

        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: false, questionId: "q-3")
        model.selectSession(projectId: project.id, sessionId: s2.id)
        model.selectSession(projectId: project.id, sessionId: s3.id)
        await pump(host)
        let s3QuestionField = try XCTUnwrap(
            findEditableTextFields(in: host).first { $0.placeholderString != "Message Copilot" }
        )
        try await typeText("Typing in question box", into: s3QuestionField, in: window, host: host)
        XCTAssertNotNil(s3QuestionField.currentEditor())
        model.projects[0].sessions[2].agentActivity = makeActivity(withWorkflow: true, questionId: "q-3")
        model.selectSession(projectId: project.id, sessionId: s3.id)
        model.focusActiveTerminal()
        await pump(host)
        XCTAssertNotNil(s3QuestionField.currentEditor())
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s3.id).isPromptFieldFocused)

        // 8. Closing the drawer while editing a question ("Answer in terminal") focuses the terminal,
        //    an attached sheet blocks focus movement until dismissed, and reopening from a presented Session Finder sheet focuses the composer.
        model.closeTranscriptDrawer(sessionId: s3.id)
        model.focusActiveTerminal()
        await pump(host)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        XCTAssertTrue(AppModel.canMoveSelectionFocus(in: window))

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheetWindow.isReleasedWhenClosed = false
        window.beginSheet(sheetWindow) { _ in }
        XCTAssertFalse(AppModel.canMoveSelectionFocus(in: window))
        input.presentSessionFinder()
        input.openFromSessionFinder(s5.id)
        await pump(host)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s5.id).shouldFocusOnAppear)
        window.endSheet(sheetWindow)
        sheetWindow.close()
        await pump(host)
        XCTAssertEqual(model.globalSelectedSessionId, s5.id)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s5.id).isPromptFieldFocused)
        let s5ComposerField = try XCTUnwrap(
            findEditableTextFields(in: host).last { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(s5ComposerField.currentEditor())

        model.selectProject(project.id)
        await pump(host)
        XCTAssertEqual(model.globalSelectedSessionId, s3.id)
        XCTAssertTrue(window.firstResponder === s3Terminal)
        model.selectSession(projectId: project.id, sessionId: s1.id)
        await pump(host)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)

        // Selecting sessions with an open NSPopover or a full-screen titlebar child window attached focuses composer/terminal,
        // while actively editing a text field inside a popover blocks background focus theft.
        let popoverField = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 22))
        popoverField.isEditable = true
        let popoverController = NSViewController()
        let popoverView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 60))
        popoverView.addSubview(popoverField)
        popoverController.view = popoverView
        let popover = NSPopover()
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.show(relativeTo: NSRect(x: 10, y: 10, width: 20, height: 20), of: host, preferredEdge: .maxY)
        let popoverWindow = try XCTUnwrap(window.childWindows?.first)
        XCTAssertTrue(popoverWindow.makeFirstResponder(popoverField))
        XCTAssertFalse(AppModel.canMoveSelectionFocus(in: window))
        XCTAssertTrue(popoverWindow.makeFirstResponder(nil))
        XCTAssertTrue(AppModel.canMoveSelectionFocus(in: window))

        let fullScreenChild = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        fullScreenChild.isReleasedWhenClosed = false
        window.addChildWindow(fullScreenChild, ordered: .above)
        fullScreenChild.orderFront(nil)
        model.selectSession(projectId: project.id, sessionId: s2.id)
        await pump(host)
        XCTAssertTrue(window.firstResponder === s2Terminal)
        model.selectSession(projectId: project.id, sessionId: s1.id)
        await pump(host)
        XCTAssertTrue(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        let s1ComposerWithPopover = try XCTUnwrap(
            findEditableTextFields(in: host).last { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(s1ComposerWithPopover.currentEditor())
        popover.close()
        window.removeChildWindow(fullScreenChild)
        fullScreenChild.close()

        // When composer is unfocused in side-drawer mode, an explicit focusActiveTerminal (e.g. hiding Projects) focuses the terminal.
        XCTAssertTrue(window.makeFirstResponder(nil))
        await pump(host)
        XCTAssertFalse(model.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        model.focusActiveTerminal()
        await pump(host)
        XCTAssertTrue(window.firstResponder === s1Terminal)

        // Restoring on launch with defaultView == .transcript focuses the composer.
        let relaunched = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images-relaunch")),
            defaults: defaults
        )
        defer { relaunched.detachAllClients() }
        relaunched.projects[0].sessions[0].agentActivity = makeActivity(withWorkflow: true)
        relaunched.bootstrapIfNeeded()
        XCTAssertEqual(relaunched.globalSelectedSessionId, s1.id)
        XCTAssertTrue(relaunched.isTranscriptDrawerOpen(sessionId: s1.id))
        host.rootView = DetailView(model: relaunched, onPreview: { _ in })
            .defaultAppStorage(defaults)
            .environment(\.controlActiveState, .key)
        await pump(host)
        let relaunchedComposerField = try XCTUnwrap(
            findEditableTextFields(in: host).last { $0.placeholderString == "Message Copilot" }
        )
        XCTAssertNotNil(relaunchedComposerField.currentEditor())
        XCTAssertTrue(relaunched.sessionPromptComposer(sessionId: s1.id).isPromptFieldFocused)
        XCTAssertFalse(window.isKeyWindow)
    }

    func testQuickReplyConfigurationDefaultsValidationAndCorruptFallback() throws {
        let suite = "quick-replies-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = QuickReplyConfiguration.load(from: defaults)
        XCTAssertFalse(initial.isCustomized)
        XCTAssertEqual(initial.activeReplies.map(\.label), [
            "Approve", "Post", "Merge when ready", "Request CCR",
            "Max review", "Keep going", "No bloat?",
        ])

        // Trim and boundary validation (label 1-24, prompt 1-2000, max 12, case-insensitive unique labels).
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: "   ", prompt: "ok"),
            .failure(.emptyLabel)
        )
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(
                label: String(repeating: "a", count: 25),
                prompt: "ok"
            ),
            .failure(.labelTooLong)
        )
        let emojiLabel = String(repeating: "👨‍👩‍👧‍👦", count: 11)
        XCTAssertEqual(emojiLabel.count, 11)
        XCTAssertGreaterThan(emojiLabel.utf8.count, 256)
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: emojiLabel, prompt: "ok"),
            .success(QuickReplyItem(label: emojiLabel, prompt: "ok"))
        )
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: "ok", prompt: " \n\t "),
            .failure(.emptyPrompt)
        )
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(
                label: "ok",
                prompt: String(repeating: "p", count: 2_001)
            ),
            .failure(.promptTooLong)
        )

        let maxLabel = String(repeating: "L", count: 24)
        let maxPrompt = String(repeating: "P", count: 2_000)
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: "  \(maxLabel)  ", prompt: "  \(maxPrompt)\n"),
            .success(QuickReplyItem(label: maxLabel, prompt: maxPrompt))
        )

        // 8 KB (8,192 UTF-8 bytes) prompt limit, even when character count <= 2,000.
        let exact8KBFlags = String(repeating: "🇺🇸", count: 1_024)
        XCTAssertEqual(exact8KBFlags.count, 1_024)
        XCTAssertEqual(exact8KBFlags.utf8.count, QuickReplyItem.maxPromptUTF8Bytes)
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: "Flags", prompt: exact8KBFlags),
            .success(QuickReplyItem(label: "Flags", prompt: exact8KBFlags))
        )
        let over8KBFlags = exact8KBFlags + "🇺🇸"
        XCTAssertEqual(over8KBFlags.count, 1_025)
        XCTAssertGreaterThan(over8KBFlags.utf8.count, QuickReplyItem.maxPromptUTF8Bytes)
        XCTAssertEqual(
            QuickReplyConfiguration.validateItem(label: "Flags", prompt: over8KBFlags),
            .failure(.promptTooLong)
        )

        XCTAssertEqual(
            QuickReplyConfiguration.validateList([
                QuickReplyItem(label: "Ship It", prompt: "Ship it"),
                QuickReplyItem(label: "  ship it ", prompt: "Another prompt"),
            ]),
            .failure(.duplicateLabel("ship it"))
        )
        XCTAssertEqual(
            QuickReplyConfiguration.validateList([
                QuickReplyItem(label: "Σ", prompt: "First"),
                QuickReplyItem(label: "ς", prompt: "Second"),
            ]),
            .failure(.duplicateLabel("ς"))
        )

        let twelveItems = (1...12).map {
            QuickReplyItem(label: "Item \($0)", prompt: "Prompt \($0)")
        }
        XCTAssertEqual(QuickReplyConfiguration.save(twelveItems, to: defaults), .success(twelveItems))
        XCTAssertEqual(QuickReplyConfiguration.load(from: defaults), .custom(twelveItems))

        let thirteenItems = (1...13).map {
            QuickReplyItem(label: "Item \($0)", prompt: "Prompt \($0)")
        }
        XCTAssertEqual(
            QuickReplyConfiguration.validateList(thirteenItems),
            .failure(.tooManyReplies)
        )

        // Empty custom list persists as [] and shows no chips.
        XCTAssertEqual(QuickReplyConfiguration.save([], to: defaults), .success([]))
        XCTAssertEqual(defaults.string(forKey: "quickReplyList"), "[]")
        let emptyConfig = QuickReplyConfiguration.load(from: defaults)
        XCTAssertTrue(emptyConfig.isCustomized)
        XCTAssertTrue(emptyConfig.activeReplies.isEmpty)

        // Reset removes the UserDefaults key rather than saving a copy of defaults.
        QuickReplyConfiguration.reset(in: defaults)
        XCTAssertNil(defaults.object(forKey: "quickReplyList"))
        XCTAssertFalse(QuickReplyConfiguration.load(from: defaults).isCustomized)

        // Corrupt or invalid stored JSON falls back to the non-customized state.
        let invalidPayloads: [Any] = [
            "not-json",
            "{}",
            "[{\"label\":\"only-label\"}]",
            "[{\"label\":\"\",\"prompt\":\"hi\"}]",
            "[{\"label\":\"A\",\"prompt\":\"1\"},{\"label\":\"a\",\"prompt\":\"2\"}]",
            "[{\"label\":\"Flags\",\"prompt\":\"\(over8KBFlags)\"}]",
            12345,
        ]
        for payload in invalidPayloads {
            defaults.set(payload, forKey: "quickReplyList")
            let loaded = QuickReplyConfiguration.load(from: defaults)
            XCTAssertFalse(loaded.isCustomized)
            XCTAssertEqual(loaded.activeReplies, QuickReplyConfiguration.defaultItems)
        }
    }

    @MainActor
    func testSharedQuickRepliesBridgeMigrationValidationAndLiveDesktopSync() throws {
        let suite = "shared-quick-replies-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = Project(
            id: "p1", name: "Main", cwd: root.path,
            sessions: [Session(id: "s1", title: "Session", cwd: root.path)],
            selectedSessionId: "s1"
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        // 1. Desktop migration: an existing UserDefaults quickReplyList (seeded as raw legacy JSON,
        //    including multi-scalar emoji labels) becomes the shared list on launch.
        let familyEmojiLabel = String(repeating: "👨‍👩‍👧‍👦", count: 11)
        let desktopExisting = [
            QuickReplyItem(label: "Approve", prompt: "Approve PR"),
            QuickReplyItem(label: familyEmojiLabel, prompt: "Merge when green"),
        ]
        defaults.set(
            #"[{"label":"Approve","prompt":"Approve PR"},{"label":"\#(familyEmojiLabel)","prompt":"Merge when green"}]"#,
            forKey: QuickReplyConfiguration.storageKey
        )

        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        let bridge: any SessionHost = RemoteModelBridge(model: model)
        XCTAssertTrue(bridge.supportsQuickReplies)
        let expectedInitialState = RemoteQuickRepliesState(items: desktopExisting)
        XCTAssertEqual(bridge.quickReplies(), expectedInitialState)
        XCTAssertEqual(bridge.workspace()?.quickRepliesDigest, expectedInitialState.digest)

        // Precomposed vs decomposed Unicode spelling changes invalidate the cached digest
        // and reload Desktop settings with the new UTF-8 bytes.
        let settingsBeforeUnicodeSwap = QuickRepliesSettingsModel(defaults: defaults)
        let precomposed = [QuickReplyItem(label: "Café", prompt: "é")]
        let decomposed = [QuickReplyItem(label: "Cafe\u{301}", prompt: "e\u{301}")]
        XCTAssertEqual(QuickReplyConfiguration.save(precomposed, to: defaults), .success(precomposed))
        settingsBeforeUnicodeSwap.beginEditing(at: 0)
        let precomposedDigest = try XCTUnwrap(bridge.workspace()?.quickRepliesDigest)
        XCTAssertEqual(
            bridge.updateQuickReplies(RemoteQuickRepliesUpdateRequest(items: decomposed)),
            .updated(RemoteQuickRepliesState(items: decomposed))
        )
        let decomposedDigest = try XCTUnwrap(bridge.workspace()?.quickRepliesDigest)
        XCTAssertNotEqual(precomposedDigest, decomposedDigest)
        XCTAssertEqual(decomposedDigest, bridge.quickReplies()?.digest)
        XCTAssertNil(settingsBeforeUnicodeSwap.editingIndex)
        XCTAssertTrue(
            settingsBeforeUnicodeSwap.items[0].prompt.utf8.elementsEqual(decomposed[0].prompt.utf8)
        )
        let maxPrompt = String(repeating: "🇺🇸", count: 1_024)
        let maxValidItems = (1...QuickReplyItem.maxCount).map {
            QuickReplyItem(label: "Item \($0)", prompt: maxPrompt)
        }
        let maxValidData = try JSONEncoder().encode(
            RemoteQuickRepliesUpdateRequest(items: maxValidItems)
        )
        XCTAssertEqual(
            bridge.updateQuickReplies(from: maxValidData),
            .updated(RemoteQuickRepliesState(items: maxValidItems))
        )
        XCTAssertEqual(QuickReplyConfiguration.save(desktopExisting, to: defaults), .success(desktopExisting))
        _ = bridge.workspace()

        // 2. Open Desktop settings model; verify one-time client migration (`onlyIfUnset: true`)
        //    does NOT overwrite the existing host list.
        let settingsModel = QuickRepliesSettingsModel(defaults: defaults)
        XCTAssertTrue(settingsModel.isCustomized)
        XCTAssertEqual(settingsModel.items, desktopExisting)
        settingsModel.beginEditing(at: 0)
        XCTAssertEqual(settingsModel.editingIndex, 0)

        let clientMigrationItems = [QuickReplyItem(label: "Phone", prompt: "From phone")]
        XCTAssertEqual(
            bridge.updateQuickReplies(
                RemoteQuickRepliesUpdateRequest(items: clientMigrationItems, onlyIfUnset: true)
            ),
            .updated(expectedInitialState)
        )
        XCTAssertEqual(settingsModel.items, desktopExisting)
        XCTAssertEqual(settingsModel.editingIndex, 0)

        // 3. Remote reset (`{"items":null}`) removes the stored list for all clients and updates Desktop settings live.
        let resetData = Data(#"{"items":null}"#.utf8)
        XCTAssertEqual(
            bridge.updateQuickReplies(from: resetData),
            .updated(RemoteQuickRepliesState(configuration: .defaultReplies))
        )
        XCTAssertNil(defaults.object(forKey: QuickReplyConfiguration.storageKey))
        XCTAssertNil(bridge.workspace()?.quickRepliesDigest)
        XCTAssertEqual(bridge.quickReplies(), RemoteQuickRepliesState(configuration: .defaultReplies))
        XCTAssertFalse(settingsModel.isCustomized)
        XCTAssertEqual(settingsModel.items, QuickReplyConfiguration.defaultItems)
        XCTAssertNil(settingsModel.editingIndex)

        // 4. Now that the host has no custom list, a client's one-time migration (`onlyIfUnset: true`)
        //    stores its custom list and updates Desktop settings live.
        let migratedData = try JSONEncoder().encode(
            RemoteQuickRepliesUpdateRequest(
                items: [QuickReplyItem(label: "  Phone  ", prompt: "  From phone\n")],
                onlyIfUnset: true
            )
        )
        let migratedExpected = RemoteQuickRepliesState(items: clientMigrationItems)
        XCTAssertEqual(bridge.updateQuickReplies(from: migratedData), .updated(migratedExpected))
        XCTAssertEqual(bridge.workspace()?.quickRepliesDigest, migratedExpected.digest)
        XCTAssertTrue(settingsModel.isCustomized)
        XCTAssertEqual(settingsModel.items, clientMigrationItems)

        // 5. Regular remote write replaces the whole list (latest write wins), including empty custom list `[]`.
        settingsModel.beginEditing(at: 0)
        let emptyCustomState = RemoteQuickRepliesState(items: [])
        XCTAssertEqual(
            bridge.updateQuickReplies(RemoteQuickRepliesUpdateRequest(items: [])),
            .updated(emptyCustomState)
        )
        XCTAssertEqual(bridge.workspace()?.quickRepliesDigest, emptyCustomState.digest)
        XCTAssertNotNil(emptyCustomState.digest)
        XCTAssertTrue(settingsModel.isCustomized)
        XCTAssertTrue(settingsModel.items.isEmpty)
        XCTAssertNil(settingsModel.editingIndex)

        // 6. Size check before decoding and host validation rules reject invalid writes without mutating state.
        let oversized = Data(repeating: UInt8(ascii: " "), count: RemoteQuickRepliesContract.maximumPayloadBytes + 1)
        XCTAssertEqual(bridge.updateQuickReplies(from: oversized), .payloadTooLarge)
        XCTAssertEqual(bridge.updateQuickReplies(from: Data("not-json".utf8)), .invalid("Invalid quick replies request."))
        XCTAssertEqual(bridge.updateQuickReplies(from: Data("{}".utf8)), .invalid("Invalid quick replies request."))
        XCTAssertEqual(
            bridge.updateQuickReplies(RemoteQuickRepliesUpdateRequest(items: nil, onlyIfUnset: true)),
            .invalid("Migration requires a custom quick-reply list.")
        )
        let over8KBPrompt = String(repeating: "🇺🇸", count: 1_025)
        for invalidItems in [
            [QuickReplyItem(label: " ", prompt: "ok")],
            [QuickReplyItem(label: String(repeating: "a", count: 25), prompt: "ok")],
            [QuickReplyItem(label: "ok", prompt: " ")],
            [QuickReplyItem(label: "ok", prompt: String(repeating: "p", count: 2_001))],
            [QuickReplyItem(label: "ok", prompt: over8KBPrompt)],
            [QuickReplyItem(label: "Dup", prompt: "1"), QuickReplyItem(label: "dup", prompt: "2")],
            (1...13).map { QuickReplyItem(label: "L\($0)", prompt: "P\($0)") },
        ] {
            guard case .invalid = bridge.updateQuickReplies(RemoteQuickRepliesUpdateRequest(items: invalidItems)) else {
                return XCTFail("Expected invalid outcome for \(invalidItems.count) items")
            }
        }
        XCTAssertEqual(bridge.quickReplies(), emptyCustomState)

        // 7. Survives relaunch, and refuses reads/writes once the host is terminating.
        let relaunched = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images-2")),
            defaults: defaults
        )
        XCTAssertEqual(relaunched.remoteQuickRepliesState(), emptyCustomState)
        relaunched.beginTermination()
        let terminatingBridge = RemoteModelBridge(model: relaunched)
        XCTAssertNil(terminatingBridge.quickReplies())
        XCTAssertEqual(
            terminatingBridge.updateQuickReplies(RemoteQuickRepliesUpdateRequest(items: desktopExisting)),
            .unavailable("Copilot Projects is closing.")
        )
        XCTAssertEqual(
            terminatingBridge.updateQuickReplies(
                from: try JSONEncoder().encode(RemoteQuickRepliesUpdateRequest(items: desktopExisting))
            ),
            .unavailable("Copilot Projects is closing.")
        )
        XCTAssertEqual(terminatingBridge.updateQuickReplies(from: oversized), .payloadTooLarge)
        XCTAssertEqual(QuickReplyConfiguration.load(from: defaults), .custom([]))
        model.beginTermination()
    }

    @MainActor
    func testQuickRepliesSettingsModelAddEditDeleteReorderAndReset() throws {
        let suite = "quick-replies-model-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = QuickRepliesSettingsModel(defaults: defaults)
        XCTAssertFalse(model.isCustomized)
        XCTAssertFalse(model.canResetToDefaults)
        XCTAssertEqual(model.items, QuickReplyConfiguration.defaultItems)

        // Duplicate label is rejected case-insensitively and cleared when draft edits.
        model.draftLabel = "  approve "
        model.draftPrompt = "Approve now"
        XCTAssertFalse(model.commitDraft())
        XCTAssertEqual(model.validationError, .duplicateLabel("approve"))
        model.draftLabel = "LGTM"
        XCTAssertNil(model.validationError)
        XCTAssertTrue(model.commitDraft())
        XCTAssertTrue(model.isCustomized)
        XCTAssertEqual(model.items.last, QuickReplyItem(label: "LGTM", prompt: "Approve now"))

        // Edit in place (including changing label casing of the same item) and reorder while editing.
        model.beginEditing(at: 0)
        XCTAssertEqual(model.editingIndex, 0)
        model.moveDown(at: 0)
        XCTAssertEqual(model.editingIndex, 1)
        XCTAssertEqual(model.items[0].label, "Post")
        XCTAssertEqual(model.items[1].label, "Approve")

        model.draftLabel = "APPROVE"
        model.draftPrompt = "Approve and merge"
        XCTAssertTrue(model.commitDraft())
        XCTAssertNil(model.editingIndex)
        XCTAssertEqual(model.items[1], QuickReplyItem(label: "APPROVE", prompt: "Approve and merge"))

        // Delete all items -> empty custom list.
        while !model.items.isEmpty {
            model.delete(at: 0)
        }
        XCTAssertTrue(model.isCustomized)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(QuickReplyConfiguration.load(from: defaults), .custom([]))

        // Reset returns to non-customized state.
        model.resetToDefaults()
        XCTAssertFalse(model.isCustomized)
        XCTAssertNil(defaults.object(forKey: "quickReplyList"))
        XCTAssertEqual(model.items, QuickReplyConfiguration.defaultItems)
    }

    @MainActor
    func testTranscriptPromptComposerQuickReplyVisibilityGates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RemoteAttachmentStore(sessionsDirectory: root)
        let composer = DesktopSessionPromptComposer(sessionId: UUID().uuidString, attachmentStore: store)
        let now = Date()
        let readyWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"],
            sendReady: true
        )
        let readyOperation = AgentOperationProjection(
            conversationEpoch: "epoch-1",
            support: .receipts,
            receipts: []
        )

        XCTAssertTrue(
            TranscriptPromptComposerView.canShowQuickReplies(
                showQuickReplyChips: true,
                composer: composer,
                workflow: readyWorkflow,
                operation: readyOperation,
                now: now
            )
        )
        XCTAssertFalse(
            TranscriptPromptComposerView.canShowQuickReplies(
                showQuickReplyChips: false,
                composer: composer,
                workflow: readyWorkflow,
                operation: readyOperation,
                now: now
            )
        )

        composer.prompt = "Already typing"
        XCTAssertFalse(
            TranscriptPromptComposerView.canShowQuickReplies(
                showQuickReplyChips: true,
                composer: composer,
                workflow: readyWorkflow,
                operation: readyOperation,
                now: now
            )
        )
    }

    @MainActor
    func testDesktopComposerSplitSendButtonModesDisabledStatesAndClicks() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }

        let savedQuickReplies = UserDefaults.standard.object(forKey: TranscriptPromptComposerView.showQuickReplyChipsKey)
        let savedQuickReplyList = UserDefaults.standard.object(forKey: QuickReplyConfiguration.storageKey)
        defer {
            UserDefaults.standard.set(savedQuickReplies, forKey: TranscriptPromptComposerView.showQuickReplyChipsKey)
            UserDefaults.standard.set(savedQuickReplyList, forKey: QuickReplyConfiguration.storageKey)
        }
        UserDefaults.standard.set(true, forKey: TranscriptPromptComposerView.showQuickReplyChipsKey)
        UserDefaults.standard.removeObject(forKey: QuickReplyConfiguration.storageKey)

        XCTAssertEqual(RemotePromptMode.immediate.sendButtonTitle, "Steer")
        XCTAssertEqual(RemotePromptMode.enqueue.sendButtonTitle, "Queue")
        XCTAssertEqual(RemotePromptMode.immediate.sendAccessibilityLabel, "Steer (Steer current task)")
        XCTAssertEqual(RemotePromptMode.enqueue.sendAccessibilityLabel, "Queue (Run after current task)")

        let now = Date()
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send"],
            sendReady: true
        )
        let operation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])
        let composer = DesktopSessionPromptComposer(sessionId: UUID().uuidString)
        XCTAssertEqual(composer.mode, .immediate)

        var dispatched: [RemoteSessionAction] = []
        let makeView = {
            TranscriptPromptComposerView(
                composer: composer,
                workflow: workflow,
                operation: operation,
                workflowProvider: { workflow },
                operationProvider: { operation },
                onAction: { action in
                    dispatched.append(action)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onPreview: { _ in }
            )
        }

        // Empty prompt: Send is disabled, but delivery mode menu remains enabled.
        XCTAssertFalse(composer.canSend(workflow: workflow, operation: operation, now: now))
        XCTAssertFalse(makeView().isDeliveryModeDisabled)

        // Switching mode with a half-written draft only changes mode and must not send.
        composer.prompt = "Half-written draft"
        XCTAssertTrue(composer.canSend(workflow: workflow, operation: operation, now: now))
        composer.mode = .enqueue
        XCTAssertTrue(dispatched.isEmpty)
        XCTAssertEqual(composer.prompt, "Half-written draft")

        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: makeView().environment(\.controlActiveState, .key))
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()

        let sendSegmentPoint = NSPoint(x: host.bounds.maxX - 12 - 24 - 20, y: 24)
        try sendClick(in: window, point: sendSegmentPoint)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            dispatched,
            [RemoteSessionAction(kind: .send, prompt: "Half-written draft", mode: .enqueue)]
        )
        XCTAssertEqual(composer.prompt, "")

        // While prompt is empty, clicking the main Send segment does nothing.
        try sendClick(in: window, point: sendSegmentPoint)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(dispatched.count, 1)

        // Quick-reply chip uses the currently selected composer.mode (.enqueue) when prompt is empty.
        composer.mode = .enqueue
        composer.prompt = ""
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        host.layoutSubtreeIfNeeded()
        try sendClick(in: window, point: NSPoint(x: 40, y: host.bounds.maxY - 24))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            dispatched.last,
            RemoteSessionAction(kind: .send, prompt: "Approve", mode: .enqueue)
        )

        // Switching back to .immediate and clicking main Send segment dispatches .immediate.
        composer.mode = .immediate
        composer.prompt = "Steer now"
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try sendClick(in: window, point: sendSegmentPoint)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            dispatched.last,
            RemoteSessionAction(kind: .send, prompt: "Steer now", mode: .immediate)
        )

        // Indeterminate send sets pendingOperationId, disabling both Send and the delivery mode menu.
        composer.prompt = "Hold until receipt"
        await composer.send(
            workflow: workflow,
            operation: operation,
            onAction: { _ in
                RemoteWorkflowActionResult(state: .indeterminate, message: "Pending", operationId: "op-pending")
            },
            now: now
        )
        XCTAssertEqual(composer.pendingOperationId, "op-pending")
        XCTAssertFalse(composer.canSend(workflow: workflow, operation: operation, now: now))
        XCTAssertTrue(makeView().isDeliveryModeDisabled)
    }

    @MainActor
    func testDesktopComposerQuickReplyWrappingSharedAttachRowAndStableHeight() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }

        let suite = "AppLogicTests.quickReplyWrap.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let turns: [TranscriptTurn] = (1...30).map { index in
            let start = now.addingTimeInterval(Double(index * 10))
            return TranscriptTurn(
                id: "turn-\(index)",
                startedAt: start,
                endedAt: start.addingTimeInterval(5),
                kind: "user",
                userContent: "User prompt \(index)\nSecond line of prompt \(index)",
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(index)",
                        timestamp: start.addingTimeInterval(3),
                        content: "Assistant reply \(index)\nDetailed explanation line 2\nLine 3"
                    ),
                ],
                tools: [],
                isAborted: false
            )
        }

        func makeFreshWorkflow(sendReady: Bool = true) -> RemoteSessionWorkflow {
            RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) - 2_000,
                capabilities: ["session-send"],
                sendReady: sendReady
            )
        }
        var isSendReady = true
        var workflow = makeFreshWorkflow()
        let operation = AgentOperationProjection(conversationEpoch: "epoch-wrap", support: .receipts, receipts: [])
        let composer = DesktopSessionPromptComposer(sessionId: UUID().uuidString)
        var dispatched: [RemoteSessionAction] = []

        let window = NSWindow(
            contentRect: NSRect(x: -18_000, y: -18_000, width: 420, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: TranscriptDrawer(
                turns: turns,
                imageCapture: nil,
                workflow: workflow,
                operation: operation,
                workflowProvider: { workflow },
                operationProvider: { operation },
                promptComposer: composer,
                onClose: {},
                onAction: { action in
                    dispatched.append(action)
                    return RemoteWorkflowActionResult(state: .applied)
                },
                onPreview: { _ in }
            )
            .defaultAppStorage(defaults)
            .environment(\.controlActiveState, .key)
        )
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        window.contentView = host
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }

        func findAllScrollViews(in view: NSView) -> [NSScrollView] {
            ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(findAllScrollViews(in:))
        }

        func pumpLayout(iterations: Int = 6) async throws {
            workflow = makeFreshWorkflow(sendReady: isSendReady)
            composer.objectWillChange.send()
            for _ in 0..<iterations {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(25))
            }
            host.layoutSubtreeIfNeeded()
        }

        func transcriptHeight(file: StaticString = #filePath, line: UInt = #line) throws -> CGFloat {
            try XCTUnwrap(findTranscriptScrollView(in: host), file: file, line: line).frame.height
        }

        try await pumpLayout()

        // 1. Default chips at 420pt: no horizontal chip ScrollView; composer height stays constant when typing
        //    or when sendability changes, and hidden chips are not clickable.
        XCTAssertEqual(findAllScrollViews(in: host).count, 1)
        let defaultScrollHeight = try transcriptHeight()
        let defaultRow3Y = CGFloat(12 + 24 + 8 + 10)
        let defaultRow2Y = defaultRow3Y + 24

        composer.prompt = "Drafting a follow-up"
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), defaultScrollHeight, accuracy: 1)
        try sendClick(in: window, point: NSPoint(x: 210, y: defaultRow2Y))
        try sendClick(in: window, point: NSPoint(x: 45, y: defaultRow3Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(dispatched.isEmpty)

        composer.prompt = ""
        isSendReady = false
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), defaultScrollHeight, accuracy: 1)
        workflow = makeFreshWorkflow(sendReady: true)
        try sendClick(in: window, point: NSPoint(x: 210, y: defaultRow2Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(dispatched.isEmpty)

        isSendReady = true
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), defaultScrollHeight, accuracy: 1)

        // 2. Wrapped row-2 ("Keep going") and row-3 ("No bloat?") chips dispatch; attach/paste column never hits a chip.
        try sendClick(in: window, point: NSPoint(x: 210, y: defaultRow2Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.map(\.prompt), ["Keep going!"])

        try sendClick(in: window, point: NSPoint(x: 45, y: defaultRow3Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.map(\.prompt), ["Keep going!", "No bloat or over-engineering?"])

        try sendClick(in: window, point: NSPoint(x: 360, y: defaultRow2Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.count, 2)

        // 3. Wide Unicode 24-character chip clamps to the left column without overlapping the attach/paste column.
        let wideUnicodeItems = [
            QuickReplyItem(label: String(repeating: "🚀", count: QuickReplyItem.maxLabelLength), prompt: "Wide emoji"),
            QuickReplyItem(label: "Follow-up", prompt: "Second chip"),
        ]
        XCTAssertEqual(QuickReplyConfiguration.save(wideUnicodeItems, to: defaults), .success(wideUnicodeItems))
        try await pumpLayout()
        try sendClick(in: window, point: NSPoint(x: 60, y: defaultRow2Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.last?.prompt, "Wide emoji")
        let countAfterWide = dispatched.count
        try sendClick(in: window, point: NSPoint(x: 360, y: defaultRow2Y))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.count, countAfterWide)

        // 4. 12 × 24-character chips at 420pt cap at 116pt with vertical scrolling and stable height when hidden.
        let twelveLongChips: [QuickReplyItem] = (1...12).map { idx in
            let label = String(format: "Custom quick reply #%02d!!", idx)
            XCTAssertEqual(label.count, QuickReplyItem.maxLabelLength)
            return QuickReplyItem(label: label, prompt: "Prompt \(idx)")
        }
        XCTAssertEqual(QuickReplyConfiguration.save(twelveLongChips, to: defaults), .success(twelveLongChips))
        try await pumpLayout()
        let scrollWithTwelveLong = try XCTUnwrap(findTranscriptScrollView(in: host))
        let twelveLongScrollHeight420 = scrollWithTwelveLong.frame.height
        XCTAssertLessThan(twelveLongScrollHeight420, defaultScrollHeight - 30)
        XCTAssertGreaterThan(twelveLongScrollHeight420, 400)
        XCTAssertEqual(findAllScrollViews(in: host).count, 2)

        let chipStripBottomY = CGFloat(12 + 24 + 8)
        let chipOneY = chipStripBottomY + TranscriptPromptComposerView.maxQuickReplyStripHeight - 15
        try sendClick(in: window, point: NSPoint(x: 60, y: chipOneY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.last?.prompt, "Prompt 1")

        let chipScrollView = try XCTUnwrap(findAllScrollViews(in: host).first { $0 !== scrollWithTwelveLong })
        let chipDocView = try XCTUnwrap(chipScrollView.documentView)
        let chipBottomOrigin = chipDocView.isFlipped
            ? NSPoint(x: 0, y: max(0, chipDocView.bounds.height - chipScrollView.contentView.bounds.height))
            : .zero
        chipScrollView.contentView.scroll(to: chipBottomOrigin)
        chipScrollView.reflectScrolledClipView(chipScrollView.contentView)
        try await pumpLayout(iterations: 4)

        let chipTwelveY = chipStripBottomY + 10
        try sendClick(in: window, point: NSPoint(x: 60, y: chipTwelveY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.last?.prompt, "Prompt 12")
        let countAfterChipTwelve = dispatched.count
        try sendClick(in: window, point: NSPoint(x: 360, y: chipTwelveY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.count, countAfterChipTwelve)

        composer.prompt = "Typing with 12 chips configured"
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), twelveLongScrollHeight420, accuracy: 1)
        try sendClick(in: window, point: NSPoint(x: 60, y: chipTwelveY))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(dispatched.count, countAfterChipTwelve)
        composer.prompt = ""
        try await pumpLayout()

        // 5. Turning chips off or saving an empty custom list collapses the row to just the 30pt attach/paste band.
        defaults.set(false, forKey: TranscriptPromptComposerView.showQuickReplyChipsKey)
        try await pumpLayout()
        let noChipsRowScrollHeight = try transcriptHeight()
        XCTAssertGreaterThan(noChipsRowScrollHeight, defaultScrollHeight + 30)
        XCTAssertEqual(findAllScrollViews(in: host).count, 1)

        defaults.set(true, forKey: TranscriptPromptComposerView.showQuickReplyChipsKey)
        XCTAssertEqual(QuickReplyConfiguration.save([], to: defaults), .success([]))
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), noChipsRowScrollHeight, accuracy: 1)

        XCTAssertEqual(QuickReplyConfiguration.save(twelveLongChips, to: defaults), .success(twelveLongChips))
        try await pumpLayout()
        XCTAssertEqual(try transcriptHeight(), twelveLongScrollHeight420, accuracy: 1)

        // 6. Minimum-height drawer (436pt) keeps >200pt transcript; full-width (900pt) wraps 12 long chips without a chip ScrollView.
        window.setContentSize(NSSize(width: 420, height: 436))
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 436)
        try await pumpLayout()
        XCTAssertGreaterThan(try transcriptHeight(), 200)

        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        window.setContentSize(NSSize(width: 900, height: 640))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        try await pumpLayout()
        XCTAssertEqual(findAllScrollViews(in: host).count, 1)
        XCTAssertGreaterThan(try transcriptHeight(), twelveLongScrollHeight420 + 30)
    }

    func testTranscriptDrawerUsageSummaryAndAccessibilityLabel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = Int64(now.timeIntervalSince1970 * 1_000)
        let stale = fresh - 60_000
        let credits = Double(12.5).formatted(.number.precision(.fractionLength(0...3)))

        let plural = RemoteSessionWorkflow(
            observedAtMilliseconds: stale, capabilities: [], sendReady: true, totalAiCredits: 12.5,
            agents: [RemoteWorkflowAgent(id: "a1", name: "One"), RemoteWorkflowAgent(id: "a2", name: "Two")],
            schedules: ["s1", "s2"]
        )
        XCTAssertEqual(
            TranscriptDrawer.usageSummary(for: plural, now: now),
            "\(credits) AI credits · 2 active agents · 2 schedules · Stale"
        )
        XCTAssertEqual(
            TranscriptDrawer.usageAccessibilityLabel(for: plural, now: now),
            "Usage and background work: \(credits) AI credits · 2 active agents · 2 schedules · Stale"
        )

        let fallback = RemoteSessionWorkflow(
            observedAtMilliseconds: fresh, capabilities: [], sendReady: true, totalAiCredits: -1
        )
        XCTAssertEqual(TranscriptDrawer.usageSummary(for: fallback, now: now), "Usage")
        XCTAssertEqual(TranscriptDrawer.usageAccessibilityLabel(for: fallback, now: now), "Usage and background work")

        let budget = RemoteSessionWorkflow(
            observedAtMilliseconds: stale, capabilities: [], sendReady: true, totalAiCredits: 32.5,
            budgetRequest: RemoteBudgetRequest(requestId: "req-1", maxAiCredits: 30, usedAiCredits: 32.5)
        )
        XCTAssertEqual(TranscriptDrawer.usageSummary(for: budget, now: now), "Budget decision needed")
        XCTAssertEqual(
            TranscriptDrawer.usageAccessibilityLabel(for: budget, now: now),
            "Budget decision needed: \(Double(32.5).formatted()) of \(Double(30).formatted()) AI credits. Usage and background work"
        )
    }

    /// The shared Session Details view offers the soft-limit field only while
    /// the workflow is fresh. A workflow the Mac published says so itself;
    /// the Mac's own copy is judged on the Mac's clock from when it was observed.
    @MainActor
    func testSessionDetailsTakesStalenessFromFreshOrTheMacsOwnClock() async throws {
        _ = NSApplication.shared
        let nowMs = Int64(Date().timeIntervalSince1970 * 1_000)
        func offersSoftLimit(observedAtMilliseconds: Int64, fresh: Bool?) async -> Bool {
            var state = SessionWorkflowState()
            let host = NSHostingView(rootView: SessionWorkflowContentView(
                workflow: RemoteSessionWorkflow(
                    observedAtMilliseconds: observedAtMilliseconds,
                    capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
                    sendReady: true, limitsKnown: true, fresh: fresh
                ),
                canWrite: true,
                state: Binding(get: { state }, set: { state = $0 }),
                onAction: { _ in RemoteWorkflowActionResult(state: .applied) }
            ))
            host.frame = NSRect(x: 0, y: 0, width: 380, height: 300)
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -16_000, y: -16_000), size: host.frame.size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            await pump(host)
            return !findEditableTextFields(in: host).isEmpty
        }

        // A workflow the Mac published: its verdict decides, whatever the observation time says.
        let published = await offersSoftLimit(observedAtMilliseconds: 0, fresh: true)
        XCTAssertTrue(published)
        let publishedStale = await offersSoftLimit(observedAtMilliseconds: nowMs, fresh: false)
        XCTAssertFalse(publishedStale)
        // As Desktop's own Session Details gets it: observed now, then 16 seconds ago.
        let local = await offersSoftLimit(observedAtMilliseconds: nowMs, fresh: nil)
        XCTAssertTrue(local)
        let localStale = await offersSoftLimit(observedAtMilliseconds: nowMs - 16_000, fresh: nil)
        XCTAssertFalse(localStale)
    }

    @MainActor
    private func findTranscriptScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView,
           let doc = scroll.documentView,
           doc.bounds.height > scroll.contentView.bounds.height + 100 {
            return scroll
        }
        return view.subviews.lazy.compactMap(findTranscriptScrollView(in:)).first
    }

    @MainActor
    private func findEditableTextFields(in root: NSView) -> [NSTextField] {
        var result: [NSTextField] = []
        if let textField = root as? NSTextField, textField.isEditable {
            result.append(textField)
        }
        for subview in root.subviews {
            result.append(contentsOf: findEditableTextFields(in: subview))
        }
        return result
    }

    @MainActor
    private func sendClick(in window: NSWindow, point: NSPoint) throws {
        let timestamp = ProcessInfo.processInfo.systemUptime
        for (type, delta): (NSEvent.EventType, TimeInterval) in [(.leftMouseDown, 0), (.leftMouseUp, 0.01)] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: timestamp + delta,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            ))
            window.sendEvent(event)
        }
    }

    @MainActor
    private func toggleUsagePopover(_ window: NSWindow, host: NSView) throws {
        let local = NSPoint(x: 14, y: 14)
        try sendClick(in: window, point: host.convert(local, to: nil))
        for _ in 0..<8 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
    }

    /// The x, expand and session details buttons highlighted a 28 pt square on hover but only
    /// clicked on their glyph, about 10 pt across, so a click near the square's edge did nothing.
    /// The model button lost its corners to the hover highlight's rounded hit shape.
    @MainActor
    func testTranscriptHeaderButtonsClickAnywhereInTheirSquare() async throws {
        _ = NSApplication.shared
        let suite = "transcript-header-buttons-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = TranscriptController(sessionId: "transcript-header-buttons")
        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true
        )

        /// Clicks a point, given from the controls' trailing edge, in a fresh window so each click
        /// starts with the drawer open and no popover shown.
        func click(trailing: CGFloat, y: CGFloat) async throws -> (closed: Bool, expanded: Bool, popover: Bool) {
            var closed = false
            let host = NSHostingView(rootView: TranscriptButton(
                controller: controller,
                isOpen: true,
                workflow: workflow,
                modelInfo: RemoteModelInfo(name: "GPT-5", reasoningEffort: "high"),
                availableModels: [RemoteAvailableModel(id: "gpt-5", name: "GPT-5")],
                operation: AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: []),
                onClose: { closed = true },
                onSwitchModel: { _ in RemoteWorkflowActionResult(state: .applied) }
            ).defaultAppStorage(defaults))
            host.frame.size = host.fittingSize
            let window = NSWindow(
                contentRect: NSRect(origin: NSPoint(x: -16_000, y: -16_000), size: host.frame.size),
                styleMask: [.borderless], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer {
                window.contentView = nil
                window.close()
            }
            await pump(host)
            try sendClick(in: window, point: host.convert(NSPoint(x: host.bounds.width - trailing, y: y), to: nil))
            await pump(host)
            return (closed, defaults.bool(forKey: TranscriptDrawer.fullWidthTranscriptKey), window.childWindows?.isEmpty == false)
        }

        // The controls, trailing first: x, expand, session details, each 28 pt with 4 pt between,
        // then the 24 pt tall model button. Each is clicked 1 pt inside its corners.
        let width = NSHostingView(rootView: TranscriptButton(
            controller: controller, isOpen: true, workflow: workflow,
            modelInfo: RemoteModelInfo(name: "GPT-5", reasoningEffort: "high"),
            availableModels: [RemoteAvailableModel(id: "gpt-5", name: "GPT-5")]
        )).fittingSize.width
        for (trailing, y) in [(1, 1), (27, 1), (1, 27), (27, 27)] as [(CGFloat, CGFloat)] {
            let close = try await click(trailing: trailing, y: y)
            XCTAssertTrue(close.closed && !close.expanded && !close.popover, "x at \(trailing), \(y)")
            let expand = try await click(trailing: 32 + trailing, y: y)
            XCTAssertTrue(expand.expanded && !expand.closed && !expand.popover, "expand at \(trailing), \(y)")
            defaults.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
            let details = try await click(trailing: 64 + trailing, y: y)
            XCTAssertTrue(details.popover && !details.closed && !details.expanded, "details at \(trailing), \(y)")
        }
        for (trailing, y) in [(97, 3), (width - 1, 3), (97, 25), (width - 1, 25)] as [(CGFloat, CGFloat)] {
            let model = try await click(trailing: trailing, y: y)
            XCTAssertTrue(model.popover && !model.closed && !model.expanded, "model at \(trailing), \(y)")
        }
    }

    @MainActor
    func testTranscriptDrawerUsagePopoverSurvivesRefreshAndBudgetTransition() throws {
        _ = NSApplication.shared
        var activeWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true,
            totalAiCredits: 12.5,
            limitsKnown: true,
            maxAiCredits: 40,
            agents: [RemoteWorkflowAgent(id: "a1", name: "Reviewer")],
            schedules: ["every 10m"]
        )
        let operation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])
        let controller = TranscriptController(sessionId: "usage-popover-refresh")
        var closeCount = 0
        let staleCapturedWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000) - 60_000,
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true,
            totalAiCredits: 12.5,
            limitsKnown: true,
            maxAiCredits: 40
        )
        func makeControls(isOpen: Bool = true, captured: RemoteSessionWorkflow = activeWorkflow) -> TranscriptButton {
            TranscriptButton(
                controller: controller,
                isOpen: isOpen,
                workflow: captured,
                workflowProvider: { activeWorkflow },
                receipts: operation.receipts ?? [],
                conversationEpoch: operation.conversationEpoch,
                onClose: { closeCount += 1 },
                onAction: { _ in RemoteWorkflowActionResult(state: .applied) }
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 92, height: 28),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        // Seed a stale captured workflow while workflowProvider returns fresh heartbeat state (simulating heartbeat-only projectStorage refresh without re-rendering WorkspaceHeading).
        let host = NSHostingView(rootView: makeControls(captured: staleCapturedWorkflow))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 92, height: 28)
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertTrue(findEditableTextFields(in: host).isEmpty)

        try toggleUsagePopover(window, host: host)
        let popover = try XCTUnwrap(window.childWindows?.first)
        let content = try XCTUnwrap(popover.contentView)
        let limitField = try XCTUnwrap(findEditableTextFields(in: content).first)
        XCTAssertEqual(limitField.placeholderString, "Soft limit (minimum 30)")
        limitField.stringValue = "55"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: limitField)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Live workflow refresh keeps popover open and retains typed limit.
        activeWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true, totalAiCredits: 15.0, limitsKnown: true, maxAiCredits: 40
        )
        host.rootView = makeControls()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        XCTAssertTrue(window.childWindows?.contains(popover) == true)
        XCTAssertEqual(try XCTUnwrap(findEditableTextFields(in: content).first).stringValue, "55")

        // Budget-pending state switches to Additional AI credits, survives refresh, and resets when requestId changes while closed.
        activeWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true, totalAiCredits: 32.5, limitsKnown: true, maxAiCredits: 30,
            budgetRequest: RemoteBudgetRequest(requestId: "req-1", maxAiCredits: 30, usedAiCredits: 32.5)
        )
        host.rootView = makeControls()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        let additionalField = try XCTUnwrap(findEditableTextFields(in: content).first)
        XCTAssertEqual(additionalField.placeholderString, "Additional AI credits")
        additionalField.stringValue = "15"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: additionalField)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        try toggleUsagePopover(window, host: host)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        activeWorkflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
            capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
            sendReady: true, totalAiCredits: 32.5, limitsKnown: true, maxAiCredits: 30,
            budgetRequest: RemoteBudgetRequest(requestId: "req-2", maxAiCredits: 30, usedAiCredits: 32.5)
        )
        host.rootView = makeControls()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try toggleUsagePopover(window, host: host)
        let reopenedContent = try XCTUnwrap(window.childWindows?.first?.contentView)
        XCTAssertEqual(try XCTUnwrap(findEditableTextFields(in: reopenedContent).first).stringValue, "")

        // Close button in title-bar controls invokes onClose.
        try toggleUsagePopover(window, host: host)
        try sendClick(in: window, point: host.convert(NSPoint(x: 78, y: 14), to: nil))
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(closeCount, 1)
    }

    @MainActor
    func testTranscriptDrawerUsagePopoverReconcilesReceiptsAndEpochWhileClosed() throws {
        _ = NSApplication.shared
        var recordedActions: [RemoteSessionAction] = []
        var nextResult = RemoteWorkflowActionResult(state: .indeterminate, operationId: "op-budget-stop")
        var activeOperation = AgentOperationProjection(conversationEpoch: "epoch-1", support: .receipts, receipts: [])
        let controller = TranscriptController(sessionId: "usage-popover-receipts")
        func budgetWorkflow() -> RemoteSessionWorkflow {
            RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                capabilities: RemoteSessionActionKind.allCases.map(\.rawValue),
                sendReady: true, totalAiCredits: 32.5, limitsKnown: true, maxAiCredits: 30,
                budgetRequest: RemoteBudgetRequest(requestId: "req-budget-1", maxAiCredits: 30, usedAiCredits: 32.5)
            )
        }
        func makeControls() -> TranscriptButton {
            TranscriptButton(
                controller: controller,
                isOpen: true,
                workflow: budgetWorkflow(),
                receipts: activeOperation.receipts ?? [],
                conversationEpoch: activeOperation.conversationEpoch,
                onAction: { action in
                    recordedActions.append(action)
                    return nextResult
                }
            )
        }

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 92, height: 28),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: makeControls())
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 92, height: 28)
        window.contentView = host
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            host.layoutSubtreeIfNeeded()
        }

        func clickStopInOpenPopover() throws {
            let popWin = try XCTUnwrap(window.childWindows?.first)
            let popContent = try XCTUnwrap(popWin.contentView)
            let field = try XCTUnwrap(findEditableTextFields(in: popContent).first)
            let stopPoint = NSPoint(
                x: popContent.bounds.maxX - 36,
                y: field.convert(field.bounds, to: nil).midY
            )
            try sendClick(in: popWin, point: stopPoint)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }

        try toggleUsagePopover(window, host: host)
        try clickStopInOpenPopover()
        XCTAssertEqual(recordedActions, [RemoteSessionAction(kind: .answerBudget, requestId: "req-budget-1")])

        // Close and reopen while op-budget-stop is uncertain; Stop stays disabled.
        try toggleUsagePopover(window, host: host)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        try toggleUsagePopover(window, host: host)
        try clickStopInOpenPopover()
        XCTAssertEqual(recordedActions.count, 1)

        // Close popover, deliver receipt while closed, reopen, and verify Stop is re-enabled.
        try toggleUsagePopover(window, host: host)
        XCTAssertTrue(window.childWindows?.isEmpty ?? true)
        activeOperation = AgentOperationProjection(
            conversationEpoch: "epoch-1",
            support: .receipts,
            receipts: [
                RemoteOperationReceipt(
                    operationId: "op-budget-stop",
                    conversationEpoch: "epoch-1",
                    kind: RemoteSessionActionKind.answerBudget.rawValue,
                    state: .applied,
                    updatedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
                ),
            ]
        )
        nextResult = RemoteWorkflowActionResult(state: .applied)
        host.rootView = makeControls()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        try toggleUsagePopover(window, host: host)
        try clickStopInOpenPopover()
        XCTAssertEqual(recordedActions.count, 2)

        // Leave draft text and an uncertain action in epoch-1, then advance to epoch-2 and verify both reset.
        let epoch1Content = try XCTUnwrap(window.childWindows?.first?.contentView)
        let epoch1Field = try XCTUnwrap(findEditableTextFields(in: epoch1Content).first)
        epoch1Field.stringValue = "25"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: epoch1Field)
        nextResult = RemoteWorkflowActionResult(state: .indeterminate, operationId: "op-epoch-1-stale")
        try clickStopInOpenPopover()
        XCTAssertEqual(recordedActions.count, 3)

        activeOperation = AgentOperationProjection(conversationEpoch: "epoch-2", support: .receipts, receipts: [])
        nextResult = RemoteWorkflowActionResult(state: .applied)
        host.rootView = makeControls()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        try toggleUsagePopover(window, host: host)
        let epoch2Content = try XCTUnwrap(window.childWindows?.first?.contentView)
        XCTAssertEqual(try XCTUnwrap(findEditableTextFields(in: epoch2Content).first).stringValue, "")
        try clickStopInOpenPopover()
        XCTAssertEqual(recordedActions.count, 4)
    }

    @MainActor
    func testTranscriptWorkingIndicatorResolutionAndAppModelLifecycle() throws {
        _ = NSApplication.shared
        for empty in [nil, "", "  \n\t "] {
            XCTAssertEqual(
                TranscriptWorkingIndicator.resolve(status: .running, activityText: empty),
                .working(nil)
            )
            XCTAssertEqual(
                TranscriptWorkingIndicator.resolve(status: .running, hasBackgroundWork: true, activityText: empty),
                .backgroundWork(nil)
            )
            XCTAssertEqual(
                TranscriptWorkingIndicator.resolve(status: .idle, hasBackgroundWork: true, activityText: empty),
                .backgroundWork(nil)
            )
        }
        XCTAssertEqual(TranscriptWorkingIndicator.working(nil).text, "Copilot is working…")
        XCTAssertEqual(TranscriptWorkingIndicator.working(nil).accessibilityLabel, "Copilot is working")
        XCTAssertEqual(TranscriptWorkingIndicator.backgroundWork(nil).text, "Background work active")
        XCTAssertEqual(TranscriptWorkingIndicator.backgroundWork(nil).accessibilityLabel, "Background work active")

        let workingText = try XCTUnwrap(
            TranscriptWorkingIndicator.resolve(
                status: .running,
                hasBackgroundWork: true,
                activityText: "  Running unit tests \n"
            )
        )
        XCTAssertEqual(workingText, .working("Running unit tests"))
        XCTAssertEqual(workingText.text, "Running unit tests")
        XCTAssertEqual(workingText.accessibilityLabel, "Running unit tests")

        let backgroundText = try XCTUnwrap(
            TranscriptWorkingIndicator.resolve(
                status: .idle,
                hasBackgroundWork: true,
                activityText: "  Waiting for background agents  "
            )
        )
        XCTAssertEqual(backgroundText, .backgroundWork("Waiting for background agents"))
        XCTAssertEqual(backgroundText.text, "Waiting for background agents")
        XCTAssertEqual(backgroundText.accessibilityLabel, "Waiting for background agents")

        XCTAssertNil(TranscriptWorkingIndicator.resolve(status: .idle))
        XCTAssertNil(TranscriptWorkingIndicator.resolve(
            status: .waiting,
            hasBackgroundWork: true,
            activityText: "Running unit tests"
        ))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let directory = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let owner = UUID().uuidString.lowercased()
        let session = Session(id: UUID().uuidString, title: "working", cwd: root.path)
        defer { SessionArtifacts.removeFiles(sessionId: session.id) }
        try Data(owner.utf8).write(to: directory.appendingPathComponent("\(session.id).copilot-session"))

        let project = Project(
            name: "Work",
            cwd: root.path,
            sessions: [session],
            selectedSessionId: session.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        var injectedPromptTarget: RemotePromptTarget?
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { false },
            agentActivityDirectory: directory,
            resumeMarkerDirectory: directory,
            remotePromptTarget: { _ in injectedPromptTarget }
        )

        let base = Date()
        let baseMs = Int64(base.timeIntervalSince1970 * 1_000)
        let snapshotURL = directory.appendingPathComponent("\(session.id).agent-activity.json")
        func makeSnapshot(
            at date: Date = base,
            processing: Bool = true,
            intent: String? = nil,
            subagents: [TrackedSubagent] = [],
            scheduled: Bool = false,
            error: String? = nil
        ) -> AgentActivitySnapshot {
            let ms = Int64(date.timeIntervalSince1970 * 1_000)
            return AgentActivitySnapshot(
                schemaVersion: 1,
                updatedAt: date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                foregroundTurnActive: processing,
                foregroundTransitionAt: base.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                scheduledTurnActive: scheduled,
                activeSubagents: subagents,
                schedules: [],
                idleGeneration: 1,
                lastIdleAborted: false,
                lastIdleTurnKind: nil,
                error: error,
                trackedUserInputs: [],
                trackedElicitations: [],
                pendingPermissionRequestIds: [],
                copilotSessionId: owner,
                conversationEpoch: "\(owner):0",
                runtimeActivity: RuntimeActivitySnapshot(
                    processing: processing,
                    observedAtMilliseconds: ms,
                    idleAtMilliseconds: processing ? nil : ms,
                    error: nil
                ),
                currentIntent: intent
            )
        }
        func publish(_ snapshot: AgentActivitySnapshot, at date: Date = base) throws {
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
            model.refreshAgentActivitySnapshots(now: date)
        }

        XCTAssertNil(model.sessionWorkingIndicator(sessionId: session.id, now: base))
        model.openTranscriptDrawer(sessionId: session.id)
        let workingModel = model.sessionWorkingModel(sessionId: session.id)
        XCTAssertNil(workingModel.indicator)

        // Working without text -> "Copilot is working…".
        try publish(makeSnapshot(processing: true, intent: nil))
        XCTAssertEqual(workingModel.indicator, .working(nil))

        // Activity text changes update the scoped workingModel without publishing AppModel.objectWillChange.
        var modelPublications = 0
        let cancellable = model.objectWillChange.sink { modelPublications += 1 }
        defer { withExtendedLifetime(cancellable) {} }

        try publish(
            makeSnapshot(at: base.addingTimeInterval(1), processing: true, intent: "Inspecting drawer"),
            at: base.addingTimeInterval(1)
        )
        XCTAssertEqual(workingModel.indicator, .working("Inspecting drawer"))
        XCTAssertEqual(modelPublications, 0)

        try publish(
            makeSnapshot(at: base.addingTimeInterval(2), processing: true, intent: "Running tests"),
            at: base.addingTimeInterval(2)
        )
        XCTAssertEqual(workingModel.indicator, .working("Running tests"))
        XCTAssertEqual(modelPublications, 0)

        // Foreign copilotSessionId (even if disconnected) rejects activity text without hiding a hook-running session.
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: baseMs)
        var foreign = makeSnapshot(
            at: base.addingTimeInterval(3),
            processing: true,
            intent: "Foreign intent",
            error: "Connection is closed."
        )
        foreign.copilotSessionId = UUID().uuidString.lowercased()
        try publish(foreign, at: base.addingTimeInterval(3))
        XCTAssertEqual(workingModel.indicator, .working(nil))

        // Pending user input, elicitation, permission, and budget requests hide the working indicator.
        var withQuestion = makeSnapshot(at: base.addingTimeInterval(4), processing: true, intent: "Running tests")
        withQuestion.trackedUserInputs = [
            TrackedUserInput(
                requestId: "q-1",
                question: "Continue?",
                choices: ["Yes", "No"],
                allowFreeform: false,
                requestedAt: withQuestion.updatedAt,
                agentId: nil
            ),
        ]
        try publish(withQuestion, at: base.addingTimeInterval(4))
        XCTAssertNil(workingModel.indicator)

        var withElicitation = makeSnapshot(at: base.addingTimeInterval(5), processing: true, intent: "Running tests")
        withElicitation.trackedElicitations = [
            TrackedElicitation(
                requestId: "e-1",
                message: "Select option",
                requestedAt: withElicitation.updatedAt
            ),
        ]
        try publish(withElicitation, at: base.addingTimeInterval(5))
        XCTAssertNil(workingModel.indicator)

        var withPermission = makeSnapshot(at: base.addingTimeInterval(6), processing: true, intent: "Running tests")
        withPermission.pendingPermissionRequestIds = ["perm-1"]
        try publish(withPermission, at: base.addingTimeInterval(6))
        XCTAssertNil(workingModel.indicator)
        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        XCTAssertNil(model.sessionWorkingIndicator(sessionId: session.id, now: base.addingTimeInterval(25)))
        model.setBackgroundAgentsActive(sessionId: session.id, active: false)

        var withBudget = makeSnapshot(at: base.addingTimeInterval(7), processing: true, intent: "Running tests")
        withBudget.workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: baseMs + 7_000,
            capabilities: [],
            sendReady: false,
            budgetRequest: RemoteBudgetRequest(requestId: "b-1", maxAiCredits: 30, usedAiCredits: 31)
        )
        try publish(withBudget, at: base.addingTimeInterval(7))
        XCTAssertNil(workingModel.indicator)

        // Background subagent work while foreground is idle shows subagent intent or "Background work active".
        let subagent = TrackedSubagent(id: "sub-1", name: "explore", description: "Searching repo", model: nil)
        try publish(
            makeSnapshot(
                at: base.addingTimeInterval(8),
                processing: false,
                intent: "Searching repo",
                subagents: [subagent]
            ),
            at: base.addingTimeInterval(8)
        )
        XCTAssertEqual(workingModel.indicator, .backgroundWork("Searching repo"))

        try publish(
            makeSnapshot(
                at: base.addingTimeInterval(9),
                processing: false,
                intent: nil,
                subagents: [subagent]
            ),
            at: base.addingTimeInterval(9)
        )
        XCTAssertEqual(workingModel.indicator, .backgroundWork(nil))

        // Terminal disconnect and snapshot expiry clear runtime-only, hook-driven (without working footer), background-agent, or scheduled indicators so dead sessions never spin forever.
        try publish(makeSnapshot(at: base.addingTimeInterval(9.2), processing: true, intent: "Before disconnect"), at: base.addingTimeInterval(9.2))
        try publish(
            makeSnapshot(
                at: base.addingTimeInterval(9.4),
                processing: true,
                intent: "Stuck intent",
                subagents: [subagent],
                error: "Connection is closed."
            ),
            at: base.addingTimeInterval(9.4)
        )
        XCTAssertNil(workingModel.indicator)
        injectedPromptTarget = RemotePromptTarget(activity: .working)
        XCTAssertEqual(model.sessionWorkingIndicator(sessionId: session.id, now: base.addingTimeInterval(9.4)), .working(nil))
        injectedPromptTarget = nil

        model.setStatus(sessionId: session.id, status: .running, text: "Stuck hook", timestamp: baseMs + 9_500)
        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        try publish(
            makeSnapshot(
                at: base.addingTimeInterval(10),
                processing: true,
                intent: "Stuck intent",
                subagents: [subagent],
                error: "Connection is closed."
            ),
            at: base.addingTimeInterval(10)
        )
        XCTAssertNil(workingModel.indicator)
        injectedPromptTarget = RemotePromptTarget(activity: .working)
        XCTAssertEqual(model.sessionWorkingIndicator(sessionId: session.id, now: base.addingTimeInterval(10)), .working("Stuck hook"))
        injectedPromptTarget = nil
        model.refreshAgentActivitySnapshots(now: base.addingTimeInterval(26))
        XCTAssertNil(workingModel.indicator)
        model.setBackgroundAgentsActive(sessionId: session.id, active: false)

        let scheduledMarkerURL = directory.appendingPathComponent("\(session.id).scheduled-turn")
        try Data("1".utf8).write(to: scheduledMarkerURL, options: .atomic)
        try publish(
            makeSnapshot(at: base.addingTimeInterval(10.5), processing: true, intent: "Scheduled tick", scheduled: true),
            at: base.addingTimeInterval(10.5)
        )
        XCTAssertEqual(workingModel.indicator, .backgroundWork("Scheduled tick"))
        model.refreshAgentActivitySnapshots(now: base.addingTimeInterval(30))
        XCTAssertNil(workingModel.indicator)
        try? FileManager.default.removeItem(at: scheduledMarkerURL)

        try publish(
            makeSnapshot(at: base.addingTimeInterval(31), processing: true, intent: "Active before expiry"),
            at: base.addingTimeInterval(31)
        )
        XCTAssertEqual(workingModel.indicator, .working("Active before expiry"))
        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        XCTAssertNil(model.sessionWorkingIndicator(sessionId: session.id, now: base.addingTimeInterval(50)))
        injectedPromptTarget = RemotePromptTarget(activity: .working)
        XCTAssertEqual(model.sessionWorkingIndicator(sessionId: session.id, now: base.addingTimeInterval(50)), .working(nil))
        injectedPromptTarget = nil
        model.setBackgroundAgentsActive(sessionId: session.id, active: false)

        // Turn end clears the indicator; closing the drawer removes the cached workingModel.
        try publish(
            makeSnapshot(at: base.addingTimeInterval(32), processing: false, intent: nil),
            at: base.addingTimeInterval(32)
        )
        XCTAssertNil(workingModel.indicator)

        // Legacy snapshots (without runtimeActivity) that resolve an input wait retain .running.
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: "Waiting",
            timestamp: baseMs + 33_000,
            source: "ask_user",
            copilotSessionId: owner,
            notification: .elicitation
        )
        var legacyResolved = makeSnapshot(at: base.addingTimeInterval(34), processing: true, intent: "Legacy working")
        legacyResolved.runtimeActivity = nil
        try publish(legacyResolved, at: base.addingTimeInterval(34))
        XCTAssertEqual(workingModel.indicator, .working("Legacy working"))

        model.setStatus(sessionId: session.id, status: .running, text: "Hook status", timestamp: baseMs + 35_000)
        try publish(makeSnapshot(at: base.addingTimeInterval(35), processing: true, intent: "   "), at: base.addingTimeInterval(35))
        XCTAssertEqual(workingModel.indicator, .working("Hook status"))
        try? FileManager.default.removeItem(at: snapshotURL)
        model.refreshAgentActivitySnapshots(now: base.addingTimeInterval(35.5))
        XCTAssertEqual(workingModel.indicator, .working("Hook status"))

        model.closeTranscriptDrawer(sessionId: session.id)
        XCTAssertNil(workingModel.indicator)
        XCTAssertNil(model.sessionWorkingModels[session.id])
    }

    @MainActor
    func testTranscriptDrawerWorkingRowScopingAccessibilityAndScrollPinning() throws {
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let turns: [TranscriptTurn] = (1...35).map { index in
            let start = now.addingTimeInterval(Double(index * 10))
            return TranscriptTurn(
                id: "turn-\(index)",
                startedAt: start,
                endedAt: start.addingTimeInterval(5),
                kind: "user",
                userContent: "Prompt \(index)\nSecond line \(index)",
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(index)",
                        timestamp: start.addingTimeInterval(2),
                        content: "Response \(index)\nDetail line A\nDetail line B"
                    ),
                ],
                tools: [],
                isAborted: false
            )
        }

        let workingModel = TranscriptWorkingModel(indicator: nil)
        var drawerBodyEvaluations = 0
        let drawer = TranscriptDrawer(
            turns: turns,
            imageCapture: nil,
            workflow: nil,
            operation: .unavailable,
            workflowProvider: {
                drawerBodyEvaluations += 1
                return nil
            },
            operationProvider: nil,
            workingModel: workingModel,
            promptComposer: nil,
            onClose: {},
            onAction: { _ in RemoteWorkflowActionResult(state: .rejected) },
            onPreview: { _ in }
        )

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 420, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: drawer)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        window.contentView = host
        defer { window.contentView = nil }

        func pumpLayout() {
            for _ in 0..<8 {
                CFRunLoopRunInMode(.defaultMode, 0, false)
                host.layoutSubtreeIfNeeded()
            }
        }
        func findProgressIndicators(in view: NSView) -> [NSProgressIndicator] {
            var result: [NSProgressIndicator] = []
            if let indicator = view as? NSProgressIndicator {
                result.append(indicator)
            }
            for subview in view.subviews {
                result.append(contentsOf: findProgressIndicators(in: subview))
            }
            return result
        }

        pumpLayout()
        let scrollView = try XCTUnwrap(findTranscriptScrollView(in: host))
        let docView = try XCTUnwrap(scrollView.documentView)
        func assertPinnedToBottom() {
            let docHeight = docView.bounds.height
            let visibleRect = scrollView.contentView.documentVisibleRect
            if docView.isFlipped {
                XCTAssertGreaterThanOrEqual(visibleRect.maxY, docHeight - 12)
            } else {
                XCTAssertLessThanOrEqual(visibleRect.minY, 12)
            }
            for indicator in findProgressIndicators(in: host) {
                let rectInClip = scrollView.contentView.convert(indicator.bounds, from: indicator)
                XCTAssertTrue(
                    scrollView.contentView.bounds.intersects(rectInClip),
                    "Expected working indicator \(rectInClip) to be visible in \(scrollView.contentView.bounds)"
                )
            }
        }

        assertPinnedToBottom()
        XCTAssertTrue(findProgressIndicators(in: host).isEmpty)

        // Showing the working indicator while pinned keeps the scroll view pinned and does not re-evaluate TranscriptDrawer.body.
        let evaluationsBeforeWorking = drawerBodyEvaluations
        workingModel.update(.working(nil))
        pumpLayout()
        XCTAssertEqual(drawerBodyEvaluations, evaluationsBeforeWorking)
        XCTAssertEqual(findProgressIndicators(in: host).count, 1)
        assertPinnedToBottom()

        // Updating activity text in-place keeps TranscriptDrawer.body untouched and stays pinned.
        workingModel.update(.working("Running targeted tests across the workspace"))
        pumpLayout()
        XCTAssertEqual(drawerBodyEvaluations, evaluationsBeforeWorking)
        XCTAssertEqual(findProgressIndicators(in: host).count, 1)
        assertPinnedToBottom()

        // Hiding the working indicator while pinned keeps the scroll view pinned to the bottom.
        workingModel.update(nil)
        pumpLayout()
        XCTAssertEqual(drawerBodyEvaluations, evaluationsBeforeWorking)
        XCTAssertTrue(findProgressIndicators(in: host).isEmpty)
        assertPinnedToBottom()

        // Scroll up so "transcript-bottom" leaves the viewport and isAtBottom becomes false;
        // showing/hiding the working indicator must not yank scroll position back to the bottom.
        for targetY in stride(from: docView.bounds.height, through: 0, by: -300) {
            NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, targetY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
            host.layoutSubtreeIfNeeded()
        }
        pumpLayout()
        let scrolledTopOriginY = scrollView.contentView.documentVisibleRect.origin.y
        XCTAssertLessThan(scrollView.contentView.documentVisibleRect.maxY, docView.bounds.height - 500)

        workingModel.update(.backgroundWork(nil))
        pumpLayout()
        XCTAssertEqual(scrollView.contentView.documentVisibleRect.origin.y, scrolledTopOriginY, accuracy: 1)

        workingModel.update(nil)
        pumpLayout()
        XCTAssertEqual(scrollView.contentView.documentVisibleRect.origin.y, scrolledTopOriginY, accuracy: 1)
    }

    @MainActor
    func testTranscriptOverlayAnimationOnSwitchVersusSameSessionToggle() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environmentKeys = [
            "SHELL",
            "COPILOT_PROJECTS_STATE_DIR",
            "COPILOT_PROJECTS_SOCKET",
            "COPILOT_PROJECTS_DTACH",
            "COPILOT_PROJECTS_RENDERER",
        ]
        let previousEnvironment = environmentKeys.map { ($0, ProcessInfo.processInfo.environment[$0]) }
        defer {
            for (key, value) in previousEnvironment {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        setenv("SHELL", "/bin/cat", 1)
        setenv("COPILOT_PROJECTS_STATE_DIR", root.path, 1)
        setenv("COPILOT_PROJECTS_SOCKET", root.appendingPathComponent("control.sock").path, 1)
        setenv("COPILOT_PROJECTS_RENDERER", "coregraphics", 1)
        unsetenv("COPILOT_PROJECTS_DTACH")
        guard Paths.dtachExecutable == nil else {
            XCTFail("Animation fixtures must not create persistent dtach sessions")
            return
        }

        let suite = "drawer-anim-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let nowIso = ISO8601DateFormatter().string(from: Date())
        let snapshotWithQuestion = AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: nowIso,
            foregroundTurnActive: false,
            scheduledTurnActive: false,
            activeSubagents: [],
            schedules: [],
            idleGeneration: 0,
            lastIdleAborted: false,
            lastIdleTurnKind: nil,
            error: nil,
            trackedUserInputs: [
                TrackedUserInput(
                    requestId: "req-1",
                    question: "Continue?",
                    choices: ["Yes", "No"],
                    allowFreeform: false,
                    requestedAt: nowIso,
                    agentId: nil
                ),
            ]
        )

        var sessionA = Session(title: "A", cwd: root.path)
        sessionA.agentActivity = snapshotWithQuestion
        var sessionB = Session(title: "B", cwd: root.path)
        sessionB.agentActivity = snapshotWithQuestion
        var sessionC = Session(title: "C", cwd: root.path)
        sessionC.agentActivity = snapshotWithQuestion

        let project = Project(
            name: "P",
            cwd: root.path,
            sessions: [sessionA, sessionB, sessionC],
            selectedSessionId: sessionA.id
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(
            stateRepository: repository,
            isAppActive: { true },
            kittyImageDiskStore: RemoteKittyImageDiskStore(root: root.appendingPathComponent("images")),
            defaults: defaults
        )
        defer { model.detachAllClients() }
        for index in model.projects[0].sessions.indices {
            model.projects[0].sessions[index].agentActivity = snapshotWithQuestion
        }
        model.ensureSelectedProjectControllers()
        model.refreshSelectedTranscriptController()

        // Pre-open B so switching to it lands on an already-open transcript; keep C unseen for Default View = Transcript.
        model.openTranscriptDrawer(sessionId: sessionB.id)

        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(
            rootView: DetailView(model: model, onPreview: { _ in })
                .defaultAppStorage(defaults)
        )
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = host
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
        }

        func findScrollViews(in view: NSView) -> [NSScrollView] {
            var out: [NSScrollView] = []
            if let s = view as? NSScrollView { out.append(s) }
            for sub in view.subviews { out.append(contentsOf: findScrollViews(in: sub)) }
            return out
        }
        func findTerminalsContainer(in view: NSView) -> TerminalsContainerView? {
            if let container = view as? TerminalsContainerView { return container }
            return view.subviews.lazy.compactMap(findTerminalsContainer(in:)).first
        }
        func drawerFramesInHost() -> [NSRect] {
            findScrollViews(in: host).map { host.convert($0.bounds, from: $0) }
        }
        func settleRunLoop() {
            CFRunLoopRunInMode(.defaultMode, 0, false)
            host.layoutSubtreeIfNeeded()
        }
        func layoutHost(expectingDrawer: Bool) {
            host.layoutSubtreeIfNeeded()
            for _ in 0..<4 where drawerFramesInHost().isEmpty == expectingDrawer {
                CFRunLoopRunInMode(.defaultMode, 0, false)
                if drawerFramesInHost().isEmpty == expectingDrawer {
                    host.layoutSubtreeIfNeeded()
                }
            }
        }
        func assertTerminalFrameUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            let container = try XCTUnwrap(findTerminalsContainer(in: host), file: file, line: line)
            let frame = host.convert(container.bounds, from: container)
            XCTAssertEqual(frame.origin.x, 0, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(frame.origin.y, 0, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(frame.width, 900, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(frame.height, 600, accuracy: 0.5, file: file, line: line)
        }

        func assertSingleDrawerFrame(
            minX: CGFloat,
            width: CGFloat,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            let frames = drawerFramesInHost()
            XCTAssertEqual(frames.count, 1, file: file, line: line)
            let frame = try XCTUnwrap(frames.first, file: file, line: line)
            XCTAssertEqual(frame.minX, minX, accuracy: 1, file: file, line: line)
            XCTAssertEqual(frame.width, width, accuracy: 1, file: file, line: line)
        }

        // 1. Side-drawer mode: switching between closed/open/open/closed sessions never slides.
        defaults.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        // Switch closed A -> already-open B: lands immediately at resting minX (900 - 420 = 480).
        model.selectSession(projectId: project.id, sessionId: sessionB.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 480, width: 420)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        // Switch open B -> closed A: immediately gone (no lingering exit transition).
        model.selectSession(projectId: project.id, sessionId: sessionA.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        // Auto-opening unseen C on first show via Default View = Transcript (from closed A) does not slide.
        defaults.set(TranscriptDrawer.DefaultView.transcript.rawValue, forKey: TranscriptDrawer.defaultViewKey)
        model.selectSession(projectId: project.id, sessionId: sessionC.id)
        XCTAssertTrue(model.isTranscriptDrawerOpen(sessionId: sessionC.id))
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 480, width: 420)
        try assertTerminalFrameUnchanged()
        defaults.set(TranscriptDrawer.DefaultView.terminal.rawValue, forKey: TranscriptDrawer.defaultViewKey)
        settleRunLoop()

        // Switch open C -> already-open B: lands immediately at resting minX = 480.
        model.selectSession(projectId: project.id, sessionId: sessionB.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 480, width: 420)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        // Switch open B -> closed A: immediately gone.
        model.selectSession(projectId: project.id, sessionId: sessionA.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        // Same-session manual open on A starts at the trailing edge (minX = 900) to slide in when Reduce Motion is off.
        let expectedManualOpenMinX: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 480 : 900
        model.openTranscriptDrawer(sessionId: sessionA.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: expectedManualOpenMinX, width: 420)
        model.closeTranscriptDrawer(sessionId: sessionA.id)
        settleRunLoop()

        // Same-session manual close on settled B keeps the departing drawer in the hierarchy during its slide-out transition,
        // whereas switching away to closed A removes it immediately.
        model.selectSession(projectId: project.id, sessionId: sessionB.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 480, width: 420)
        settleRunLoop()
        model.closeTranscriptDrawer(sessionId: sessionB.id)
        layoutHost(expectingDrawer: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertEqual(
            drawerFramesInHost().count,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
        )
        model.selectSession(projectId: project.id, sessionId: sessionA.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        settleRunLoop()

        // 2. Full-width mode: switching sessions never slides or resizes the terminal container, while manual open/close still slides.
        defaults.set(true, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        model.openTranscriptDrawer(sessionId: sessionB.id)
        model.openTranscriptDrawer(sessionId: sessionC.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        settleRunLoop()

        model.selectSession(projectId: project.id, sessionId: sessionB.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 0, width: 900)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        model.selectSession(projectId: project.id, sessionId: sessionC.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 0, width: 900)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        model.selectSession(projectId: project.id, sessionId: sessionA.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
        try assertTerminalFrameUnchanged()
        settleRunLoop()

        let expectedFullWidthManualOpenMinX: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 900
        model.openTranscriptDrawer(sessionId: sessionA.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: expectedFullWidthManualOpenMinX, width: 900)
        model.closeTranscriptDrawer(sessionId: sessionA.id)
        settleRunLoop()

        model.selectSession(projectId: project.id, sessionId: sessionB.id)
        layoutHost(expectingDrawer: true)
        try assertSingleDrawerFrame(minX: 0, width: 900)
        settleRunLoop()
        model.closeTranscriptDrawer(sessionId: sessionB.id)
        layoutHost(expectingDrawer: !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        XCTAssertEqual(
            drawerFramesInHost().count,
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 1
        )
        model.selectSession(projectId: project.id, sessionId: sessionA.id)
        layoutHost(expectingDrawer: false)
        XCTAssertTrue(drawerFramesInHost().isEmpty)
    }

    @MainActor
    func testDesktopTranscriptRendersWorkflowPendingMessages() async throws {
        _ = NSApplication.shared
        XCTAssertEqual(RemotePendingMessage.capability, "pending-messages-v1")

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: ["session-send", RemotePendingMessage.capability],
            sendReady: true
        )
        let turns = [
            TranscriptTurn(
                id: "turn-1",
                startedAt: now.addingTimeInterval(-30),
                endedAt: nil,
                kind: "foreground",
                userContent: "Run the regression suite",
                assistantMessages: [],
                tools: [],
                isAborted: false
            ),
        ]
        let window = NSWindow(
            contentRect: NSRect(x: -16_000, y: -16_000, width: 420, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        func makeDrawer() -> TranscriptDrawer {
            TranscriptDrawer(
                turns: turns,
                imageCapture: nil,
                workflow: workflow,
                operation: .unavailable,
                workflowProvider: { workflow },
                operationProvider: nil,
                promptComposer: nil,
                onClose: {},
                onAction: { _ in RemoteWorkflowActionResult(state: .rejected) },
                onPreview: { _ in }
            )
        }
        let host = NSHostingView(rootView: makeDrawer())
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 480)
        window.contentView = host
        window.orderBack(nil)
        await pump(host)

        func findScrollView(in view: NSView) -> NSScrollView? {
            (view as? NSScrollView) ?? view.subviews.lazy.compactMap(findScrollView(in:)).first
        }
        let docView = try XCTUnwrap(findScrollView(in: host)?.documentView)
        let baselineHeight = docView.bounds.height

        workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: workflow.capabilities,
            sendReady: true,
            pendingMessages: [
                RemotePendingMessage(messageId: "steering-0", text: "Steer now", mode: .immediate),
                RemotePendingMessage(messageId: "msg-q-1", text: "Queued next", mode: .enqueue),
            ]
        )
        host.rootView = makeDrawer()
        await pump(host)
        XCTAssertGreaterThan(docView.bounds.height, baselineHeight + 60)

        workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(now.timeIntervalSince1970 * 1_000),
            capabilities: workflow.capabilities,
            sendReady: true,
            pendingMessages: nil
        )
        host.rootView = makeDrawer()
        await pump(host)
        XCTAssertEqual(docView.bounds.height, baselineHeight, accuracy: 2)
    }
}

// MARK: - Remote Kitty test helpers

/// A `priorityLineRange` covering every possible line id, so every discovered
/// component is treated as "priority" — used by scanner tests that only care
/// about the pre-existing (ascending raster order) selection/cap behavior and
/// aren't specifically exercising the priority-vs-old-history split.
private let remoteKittyAllLinesPriority = Int.min ..< Int.max

/// Constructs a `RemoteKittyImageCapture` isolated from every other test: a
/// fixed epoch (0) keeps hardcoded expected version numbers (`1`, `2`, ...)
/// meaningful, and a *fresh* `RemoteKittyImageCaptureBudget` (never `.shared`)
/// means this test's bounds/eviction assertions can never be perturbed by any
/// other test's captures sharing the real process-wide singleton.
@MainActor
private func remoteKittyTestCapture(epoch: UInt32 = 0) -> RemoteKittyImageCapture {
    RemoteKittyImageCapture(epoch: epoch, budget: RemoteKittyImageCaptureBudget())
}

/// Renders a real, fully-decodable minimal PNG of exactly `width` x `height`
/// via CoreGraphics + ImageIO — never the old signature+IHDR-only fixture —
/// so it satisfies `RemoteKittyImageCapture.validatePNG`'s ImageIO-based
/// "structurally complete PNG" check (which a truncated fixture no longer
/// passes). A solid fill compresses to a tiny file regardless of dimensions.
func remoteKittyTestPNGBytes(width: Int, height: Int) -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("remoteKittyTestPNGBytes: failed to create bitmap context")
    }
    context.setFillColor(red: 0.4, green: 0.6, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let cgImage = context.makeImage() else {
        fatalError("remoteKittyTestPNGBytes: failed to create CGImage")
    }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, UTType.png.identifier as CFString, 1, nil
    ) else {
        fatalError("remoteKittyTestPNGBytes: failed to create CGImageDestination")
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        fatalError("remoteKittyTestPNGBytes: failed to finalize PNG")
    }
    return data as Data
}

/// The *old* signature+IHDR-only fixture, kept only for the dedicated test
/// proving such a truncated/structurally-incomplete PNG (no IDAT/IEND, no
/// real compressed data) is now rejected by the ImageIO-based validator —
/// every other test uses `remoteKittyTestPNGBytes` (a real, decodable PNG)
/// instead.
private func remoteKittyTruncatedPNGFixtureBytes(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    bytes.append(contentsOf: [0, 0, 0, 13]) // chunk length (never a real, complete PNG)
    bytes.append(contentsOf: Array("IHDR".utf8))
    bytes.append(UInt8((width >> 24) & 0xFF))
    bytes.append(UInt8((width >> 16) & 0xFF))
    bytes.append(UInt8((width >> 8) & 0xFF))
    bytes.append(UInt8(width & 0xFF))
    bytes.append(UInt8((height >> 24) & 0xFF))
    bytes.append(UInt8((height >> 16) & 0xFF))
    bytes.append(UInt8((height >> 8) & 0xFF))
    bytes.append(UInt8(height & 0xFF))
    return Data(bytes)
}

/// Builds one 7-bit APC Kitty graphics frame: `ESC _ G <control>[;<base64>] ESC \`.
func remoteKittyFrameBytes(control: String, base64Payload: String = "") -> [UInt8] {
    var bytes: [UInt8] = [0x1B, 0x5F, 0x47] // ESC _ G
    bytes.append(contentsOf: Array(control.utf8))
    if !base64Payload.isEmpty {
        bytes.append(0x3B) // ';'
        bytes.append(contentsOf: Array(base64Payload.utf8))
    }
    bytes.append(contentsOf: [0x1B, 0x5C]) // ESC \ (ST)
    return bytes
}

/// Builds a full Kitty transmission for a base64 payload too large to fit a
/// single raw APC frame (which is bounded well under 96 KiB), splitting it
/// across `m=1`/`m=0` continuation frames of at most `chunkBytes` base64
/// characters each — mirroring how a real Kitty client streams a large image
/// instead of sending it as one oversized escape sequence.
private func remoteKittyChunkedTransmissionFrames(
    control: String,
    base64Payload: String,
    chunkBytes: Int = 32 * 1_024
) -> [UInt8] {
    var pieces: [String] = []
    var remaining = Substring(base64Payload)
    while !remaining.isEmpty {
        let end = remaining.index(remaining.startIndex, offsetBy: chunkBytes, limitedBy: remaining.endIndex) ?? remaining.endIndex
        pieces.append(String(remaining[..<end]))
        remaining = remaining[end...]
    }
    if pieces.isEmpty { pieces = [""] }
    var bytes: [UInt8] = []
    for (index, piece) in pieces.enumerated() {
        let isLast = index == pieces.count - 1
        if index == 0 {
            bytes += remoteKittyFrameBytes(control: "\(control),m=\(isLast ? 0 : 1)", base64Payload: piece)
        } else {
            bytes += remoteKittyFrameBytes(control: "m=\(isLast ? 0 : 1)", base64Payload: piece)
        }
    }
    return bytes
}

/// Feeds `bytes` to `capture` split into arbitrary `chunkSize`-sized slices, so
/// tests can confirm parsing is independent of how the underlying byte stream
/// happens to be chunked by the pty/process pipe.
@MainActor
private func remoteKittyIngest(
    _ capture: RemoteKittyImageCapture,
    _ bytes: [UInt8],
    chunkSize: Int
) {
    var index = 0
    while index < bytes.count {
        let end = min(index + chunkSize, bytes.count)
        capture.ingest(bytes[index ..< end])
        index = end
    }
}
