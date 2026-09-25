import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
import AppKit
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

    func testRemotePromptPasteBytesAreSanitized() throws {
        let paste = try XCTUnwrap(
            ProjectsTerminalView.remotePromptPasteBytes("first line\nsecond line")
        )
        XCTAssertEqual(Array(paste.prefix(2)), [0x1b, 0x1b])
        XCTAssertTrue(paste.starts(with: [0x1b, 0x1b] + Array("\u{1b}[200~".utf8)))
        XCTAssertEqual(
            String(decoding: paste, as: UTF8.self),
            "\u{1b}\u{1b}\u{1b}[200~first line\nsecond line\u{1b}[201~"
        )
        XCTAssertFalse(paste.contains(0x0d))
        XCTAssertNil(ProjectsTerminalView.remotePromptPasteBytes("unsafe\u{1b}[201~input"))
        XCTAssertNil(ProjectsTerminalView.remotePromptPasteBytes("unsafe\u{009b}31m"))
        XCTAssertNil(ProjectsTerminalView.remotePromptPasteBytes("unsafe\u{0}input"))
        XCTAssertNil(ProjectsTerminalView.remotePromptPasteBytes("   \n"))
    }

    func testRemotePromptFocusBytesBracketTheSubmission() throws {
        let paste = try XCTUnwrap(
            ProjectsTerminalView.remotePromptPasteBytes(
                "hello",
                scopedFocus: true
            )
        )
        XCTAssertTrue(paste.starts(with:
            ProjectsTerminalView.remoteFocusInBytes + [0x1b, 0x1b]
        ))
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

    func testPromptSubmitTimingScalesWithSizeAndIsBounded() {
        // Small prompts get the base floor; large ones wait longer, but bounded.
        XCTAssertEqual(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0), 10)
        XCTAssertEqual(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_024), 10)
        XCTAssertGreaterThan(
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 8_192),
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_024)
        )
        XCTAssertLessThanOrEqual(
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 1_000_000),
            20
        )
        // The floor must comfortably exceed the old 150ms fixed delay (5 ticks).
        XCTAssertGreaterThan(ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0), 5)
        // The cap always leaves room for the settle extension past the floor.
        for bytes in [0, 1_024, 8_192, 1_000_000] {
            XCTAssertGreaterThan(
                ProjectsTerminalView.promptSubmitMaxTicks(byteCount: bytes),
                ProjectsTerminalView.promptSubmitFloorTicks(byteCount: bytes)
            )
        }
        // A submit can fire at the floor when output is already quiet.
        XCTAssertLessThan(
            ProjectsTerminalView.promptSubmitSettleTicks,
            ProjectsTerminalView.promptSubmitFloorTicks(byteCount: 0)
        )
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
        XCTAssertEqual(
            AppModel.backgroundOnlyEvidenceMs(
                snapshot: disconnected,
                backgroundAgentsActive: false,
                now: now,
                nowMs: nowMs
            ),
            transitionMs
        )
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
    func testRemotePromptOrchestrationRechecksAndSendsExactlyOnce() throws {
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
        var sendSucceeds = true
        var sentValues: [String] = []
        let model = AppModel(
            stateRepository: repository,
            agentActivityDirectory: root,
            remotePromptLiveSessions: { _ in liveSessions },
            remotePromptTarget: { requestedSessionId in
                guard requestedSessionId == session.id else { return nil }
                return RemotePromptTarget(
                    activity: activity,
                    send: { value in
                        sentValues.append(value)
                        return sendSucceeds
                    }
                )
            }
        )

        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "hello"), .sent)
        XCTAssertEqual(sentValues, ["hello"])

        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: "missing", value: "ignored"),
            .invalid
        )
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "bad\u{0}value"),
            .invalid
        )
        XCTAssertEqual(sentValues, ["hello"])

        // Foreground genuinely working (footer working) → busy, nothing sent.
        activity = .working
        XCTAssertEqual(model.sendRemotePrompt(sessionId: session.id, value: "busy"), .busy)
        XCTAssertEqual(sentValues, ["hello"])
        activity = .idle

        // Background agents active must NOT block a settled foreground at a prompt:
        // the message sends even while background work runs.
        model.setBackgroundAgentsActive(sessionId: session.id, active: true)
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "background"),
            .sent
        )
        XCTAssertEqual(sentValues, ["hello", "background"])
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
        // A live background subagent + idle footer must still send (the reported bug).
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "subagent"),
            .sent
        )
        XCTAssertEqual(sentValues, ["hello", "background", "subagent"])
        model.setStatus(
            sessionId: session.id,
            status: .running,
            text: nil,
            timestamp: 1,
            source: "background-only"
        )
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "running-background"),
            .sent
        )
        XCTAssertEqual(sentValues, ["hello", "background", "subagent", "running-background"])

        // A raw permission prompt sets `status == .waiting` (no structured question)
        // while the footer can still read idle behind the dialog — must NOT inject.
        model.setStatus(
            sessionId: session.id,
            status: .waiting,
            text: nil,
            timestamp: 2,
            source: "permission-prompt"
        )
        XCTAssertEqual(activity, .idle)
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "over-permission"),
            .busy
        )
        XCTAssertEqual(sentValues, ["hello", "background", "subagent", "running-background"])
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
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "scheduled"),
            .sent
        )
        XCTAssertEqual(
            sentValues,
            ["hello", "background", "subagent", "running-background", "scheduled"]
        )
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: scheduledTransitionMs + 1,
            source: "scheduled-idle"
        )

        liveSessions = []
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "no process"),
            .noLiveCopilot
        )
        XCTAssertEqual(
            sentValues,
            ["hello", "background", "subagent", "running-background", "scheduled"]
        )
        liveSessions = [session.id]

        // Footer not idle → busy (queue + retry), never injected mid-work.
        activity = .working
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "working"),
            .busy
        )
        XCTAssertEqual(
            sentValues,
            ["hello", "background", "subagent", "running-background", "scheduled"]
        )
        activity = .idle

        sendSucceeds = false
        XCTAssertEqual(
            model.sendRemotePrompt(sessionId: session.id, value: "not sent"),
            .invalid
        )
        XCTAssertEqual(
            sentValues,
            ["hello", "background", "subagent", "running-background", "scheduled", "not sent"]
        )
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

        XCTAssertEqual(
            Set(try SessionArtifacts.closeSessionRequests(sessionsDirectory: root)),
            Set([sessionId, secondSessionId, preservedSessionId])
        )
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
        XCTAssertTrue(TranscriptController.liveCLIProcesses(
            sessionId: UUID().uuidString,
            directory: root
        ).isEmpty)
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
            hasLiveAgent: true,
            supportsSessionIdleHook: false
        ))
        XCTAssertTrue(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: true,
            supportsSessionIdleHook: false
        ))
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: false,
            supportsSessionIdleHook: false
        ))
        XCTAssertFalse(ActivityTracker.canPromoteIdleFromFooter(
            backgroundAgentsActive: false,
            hasLiveAgent: true,
            supportsSessionIdleHook: true
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
        let markers = ["copilot-session", "copilot-allow-all"].map {
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
            remotePromptTarget: { _ in RemotePromptTarget(activity: .idle, send: { _ in false }) }
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
        model.setStatus(
            sessionId: session.id, status: .idle, text: nil,
            timestamp: 300, source: "session-idle", notification: .completed
        )
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
            source: "session-idle",
            notification: .completed
        )
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
    func testCompletionSignalsSurviveEitherTimestampArrivalOrder() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentStopFirst = Session(title: "agent-stop-first", cwd: "/tmp")
        let sessionIdleFirst = Session(title: "session-idle-first", cwd: "/tmp")
        let targetProject = Project(
            name: "target",
            cwd: "/tmp",
            sessions: [agentStopFirst, sessionIdleFirst]
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
        model.attach(notifications: notifications)
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .running,
            text: nil,
            timestamp: 100
        )
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .idle,
            text: nil,
            timestamp: 110,
            source: "agent-stop"
        )
        model.setStatus(
            sessionId: agentStopFirst.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "session-idle",
            notification: .completed
        )

        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .running,
            text: nil,
            timestamp: 200
        )
        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .idle,
            text: nil,
            timestamp: 211,
            source: "session-idle",
            notification: .completed
        )
        model.setStatus(
            sessionId: sessionIdleFirst.id,
            status: .idle,
            text: nil,
            timestamp: 210,
            source: "agent-stop"
        )

        XCTAssertTrue(model.projects[0].sessions[0].hasUnread)
        XCTAssertTrue(model.projects[0].sessions[1].hasUnread)
        XCTAssertEqual(notifications.calls, [
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · agent-stop-first",
                body: nil,
                projectId: targetProject.id,
                sessionId: agentStopFirst.id
            ),
            NotificationSpy.Call(
                title: StatusNotificationKind.completed.title,
                subtitle: "target · session-idle-first",
                body: nil,
                projectId: targetProject.id,
                sessionId: sessionIdleFirst.id
            )
        ])
    }

    @MainActor
    func testVisibleCompletionPostsNoNotificationAcrossAgentStopAndSessionIdle() async throws {
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
            completionNotificationDelayNanoseconds: 10_000_000,
            isAppActive: { true }
        )
        let notifications = NotificationSpy()
        let unexpectedCompletion = expectation(description: "visible completion remains suppressed")
        unexpectedCompletion.isInverted = true
        notifications.onPost = { _ in unexpectedCompletion.fulfill() }
        model.attach(notifications: notifications)
        model.setStatus(sessionId: session.id, status: .running, text: nil, timestamp: 100)
        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 110,
            source: "agent-stop"
        )

        await fulfillment(of: [unexpectedCompletion], timeout: 0.1)
        notifications.onPost = nil
        XCTAssertTrue(model.projects[0].sessions[0].turnCompleted)
        XCTAssertFalse(model.projects[0].sessions[0].hasUnread)
        XCTAssertFalse(model.projects[0].sessions[0].finishedUnseen)
        XCTAssertTrue(notifications.calls.isEmpty)

        model.setStatus(
            sessionId: session.id,
            status: .idle,
            text: nil,
            timestamp: 111,
            source: "session-idle",
            notification: .completed
        )
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

    func testCopilotHookHandlesSessionIdleAndCapabilityLifecycle() throws {
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
        let capability = sessions.appendingPathComponent("\(tabId).session-idle-hook")
        let backgroundAgents = sessions.appendingPathComponent("\(tabId).background-agents")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: backgroundAgents)

        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":200,"notification_type":"session_idle","aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: capability.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundAgents.path))
        XCTAssertEqual(
            try String(contentsOf: sessions.appendingPathComponent("\(tabId).status"), encoding: .utf8),
            "idle"
        )
        XCTAssertEqual(
            try String(
                contentsOf: sessions.appendingPathComponent("\(tabId).status-timestamp"),
                encoding: .utf8
            ),
            "200"
        )
        XCTAssertTrue(
            try String(contentsOf: capture, encoding: .utf8)
                .contains(
                    "set-status idle --session \(tabId) --timestamp 200 --source session-idle"
                )
        )

        try Data().write(to: backgroundAgents)
        try runHook(
            hookURL: hookURL,
            action: "start",
            payload: #"{"timestamp":300}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: capability.path))
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
            atPath: sessions.appendingPathComponent("\(resolved).status").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(stale).status").path
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
            ("notify", ",\"notification_type\":\"session_idle\",\"aborted\":false"),
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
        XCTAssertTrue(calls[2].contains("--notification completed"))
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
        let promptTimestamp = root
            .appendingPathComponent("sessions/\(tabId).prompt-status-timestamp")
        XCTAssertEqual(
            try String(contentsOf: promptTimestamp, encoding: .utf8),
            "100"
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":110,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
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
            "set-status idle --session \(tabId) --timestamp 110 --source session-idle",
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
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":140,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --session \(tabId) --timestamp 140 --source session-idle --notification completed"
        )
        XCTAssertEqual(completionSignals(in: cliCalls), 2)

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":150}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":160,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --session \(tabId) --timestamp 160 --source session-idle --notification completed"
        )
        let completionSignalCount = completionSignals(in: cliCalls)
        XCTAssertEqual(completionSignalCount, 3)

        try runHook(
            hookURL: hookURL,
            action: "running",
            payload: #"{"timestamp":170}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":180,"notification_type":"session_idle","unaborted":true,"aborted":true}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(completionSignals(in: cliCalls), completionSignalCount)
        XCTAssertEqual(
            cliCalls.last,
            "set-status idle --session \(tabId) --timestamp 180 --source session-idle"
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
        XCTAssertEqual(completionSignals(in: cliCalls), completionSignalCount)
        XCTAssertEqual(cliCalls.suffix(2), [
            "set-status running --session \(tabId) --timestamp 190",
            "set-status idle --session \(tabId) --timestamp 195",
        ])
        XCTAssertEqual(cliCalls.count, 13)
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
        let promptTimestamp = root
            .appendingPathComponent("sessions/\(tabId).prompt-status-timestamp")
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
        XCTAssertEqual(
            try String(contentsOf: promptTimestamp, encoding: .utf8),
            "100"
        )
        let record = try JSONDecoder().decode(
            SessionStatusRecord.self,
            from: Data(contentsOf: root
                .appendingPathComponent("sessions/\(tabId).status-record.json"))
        )
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
        try runHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":120,"notification_type":"session_idle","aborted":false}"#,
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
        XCTAssertTrue(calls.contains(
            "set-status idle --session \(tabId) --timestamp 120 --source session-idle"
        ))
        XCTAssertEqual(
            try String(contentsOf: promptTimestamp, encoding: .utf8),
            "120"
        )
        XCTAssertFalse(calls.contains { $0.contains("--notification completed") })
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
                ]
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
            .invalid
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

        // A stale heartbeat can no longer be answered.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
        )

        // Without a live Copilot session marker the answer cannot be bound to context.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerUserInput(
                sessionId: session.id,
                answer: RemoteUserInputAnswer(
                    requestId: "req-choice", answer: "Yes, deploy", wasFreeform: false
                )
            ),
            .invalid
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
                ]
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

        // Without a live Copilot session marker the switch cannot be bound.
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4")
            ),
            .invalid
        )

        // A stale heartbeat can no longer be switched.
        try Data("copilot-session".utf8).write(to: markerURL)
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.setModel(
                sessionId: session.id,
                selection: RemoteModelSelection(modelId: "gpt-5.4")
            ),
            .invalid
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
                ]
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
            .invalid
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
            ["fruit": .string("apple"), "colors": .array([.string("blue")])],
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

        // A stale heartbeat can no longer be answered.
        try writeSnapshot(updatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .invalid
        )

        // Without a live Copilot session marker the answer cannot be bound.
        try writeSnapshot(updatedAt: Date())
        try FileManager.default.removeItem(at: markerURL)
        XCTAssertEqual(
            model.answerElicitation(
                sessionId: session.id,
                answer: RemoteElicitationAnswer(requestId: "req-form", action: .cancel)
            ),
            .invalid
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

    func testAgentStopAndSessionIdleAtomicallyClaimCompletion() throws {
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
            payload: #"{"timestamp":100}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )

        let agentStop = try startHook(
            hookURL: hookURL,
            action: "idle",
            payload: #"{"timestamp":110}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        let sessionIdle = try startHook(
            hookURL: hookURL,
            action: "notify",
            payload: #"{"timestamp":111,"notification_type":"session_idle","aborted":false}"#,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        agentStop.waitUntilExit()
        sessionIdle.waitUntilExit()
        XCTAssertEqual(agentStop.terminationStatus, 0)
        XCTAssertEqual(sessionIdle.terminationStatus, 0)

        let cliCalls = try cliCallLines(in: capture)
        XCTAssertEqual(cliCalls.count, 3)
        XCTAssertTrue(cliCalls.contains(
            "set-status running --session \(tabId) --timestamp 100"
        ))
        XCTAssertEqual(cliCalls.filter { $0.contains("--timestamp 110") }.count, 1)
        XCTAssertEqual(cliCalls.filter { $0.contains("--timestamp 111") }.count, 1)
        XCTAssertTrue((1...2).contains(completionSignals(in: cliCalls)))
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(tabId).active-turn").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessions.appendingPathComponent("\(tabId).agent-stop-completion").path
        ))
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
            TerminalController.resumeCommand(sessionId: sessionId, allowAll: false),
            TerminalController.profiledCopilotCommand(
                "copilot",
                arguments: ["--no-remote", "--no-remote-export", "--resume=\(sessionId)"]
            )
        )
        XCTAssertEqual(
            TerminalController.resumeCommand(sessionId: sessionId, allowAll: true),
            TerminalController.profiledCopilotCommand(
                "copilot",
                arguments: [
                    "--no-remote",
                    "--no-remote-export",
                    "--allow-all",
                    "--resume=\(sessionId)",
                ]
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
        XCTAssertTrue(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: sessionId,
            allowAllSessionId: sessionId
        ))
        XCTAssertFalse(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: sessionId,
            allowAllSessionId: UUID().uuidString
        ))
        XCTAssertFalse(AppModel.shouldResumeWithAllowAll(
            copilotSessionId: nil,
            allowAllSessionId: sessionId
        ))
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
                copilotSessionAllowAll: false,
                launchCopilotExecutable: nil
            ),
            [shell, "-l"]
        )
        // A freshly-created remote session launches the quoted absolute executable once.
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                copilotSessionAllowAll: false,
                launchCopilotExecutable: executable
            ),
            [shell, "-l", "-c",
             TerminalController.launchCommand(executable: executable, shell: shell)]
        )
        XCTAssertEqual(
            TerminalController.launchCommand(executable: executable, shell: shell),
            TerminalController.profiledCopilotCommand(
                executable,
                arguments: ["--no-remote", "--no-remote-export"]
            )
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        // A remote (phone) session launches with allow-all so it runs unattended.
        XCTAssertEqual(
            TerminalController.launchCommand(
                executable: executable, shell: shell, allowAll: true
            ),
            TerminalController.profiledCopilotCommand(
                executable,
                arguments: ["--no-remote", "--no-remote-export", "--allow-all"]
            )
                + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
                + " exec '/bin/zsh' -l"
        )
        XCTAssertEqual(
            TerminalController.startupProgram(
                shell: shell,
                copilotSessionId: nil,
                copilotSessionAllowAll: true,
                launchCopilotExecutable: executable
            ),
            [shell, "-l", "-c",
             TerminalController.launchCommand(
                executable: executable, shell: shell, allowAll: true
             )]
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
                    "--no-remote",
                    "--no-remote-export",
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
            copilotSessionAllowAll: true,
            launchCopilotExecutable: executable,
            launchCopilotInitialPrompt: initialPrompt
        )
        XCTAssertEqual(
            promptedProgram,
            [shell, "-l", "-c",
             TerminalController.launchCommand(
                executable: executable,
                shell: shell,
                allowAll: true,
                initialPrompt: initialPrompt
             )]
        )
        // A recorded resume session ALWAYS wins over a one-shot launch executable.
        let sessionId = UUID().uuidString
        let resumeExecutable = "/opt/resume copilot/copilot"
        let resumeProgram = TerminalController.startupProgram(
            shell: shell,
            copilotSessionId: sessionId,
            copilotSessionAllowAll: false,
            resumeCopilotExecutable: resumeExecutable,
            launchCopilotExecutable: executable,
            launchCopilotInitialPrompt: initialPrompt
        )
        let joined = resumeProgram.joined(separator: " ")
        XCTAssertTrue(joined.contains("resume copilot"))
        XCTAssertFalse(joined.contains("my copilot/copilot"))
        XCTAssertFalse(joined.contains(initialPrompt))
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
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("\(sessionId).status"),
                encoding: .utf8
            ),
            "running"
        )
        XCTAssertEqual(
            try String(
                contentsOf: root.appendingPathComponent("\(sessionId).status-timestamp"),
                encoding: .utf8
            ),
            "123456"
        )
        XCTAssertEqual(
            try String(
                contentsOf: root
                    .appendingPathComponent("\(sessionId).prompt-status-timestamp"),
                encoding: .utf8
            ),
            "123400"
        )
    }

    func testInvalidAtomicStatusRecordDoesNotFallBackToLegacyMarkers() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("running".utf8).write(
            to: root.appendingPathComponent("\(sessionId).status"))
        try Data("200".utf8).write(
            to: root.appendingPathComponent("\(sessionId).status-timestamp"))
        try Data("100".utf8).write(
            to: root.appendingPathComponent("\(sessionId).prompt-status-timestamp"))
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

    @MainActor
    func testTranscriptControllerClearsWhenOwnerBecomesForeign() async throws {
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

        let controller = TranscriptController(sessionId: sessionId)
        controller.start()
        for _ in 0 ..< 50 {
            if controller.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(controller.snapshot)

        try JSONSerialization.data(withJSONObject: [
            "appSessionId": UUID().uuidString,
            "copilotSessionId": snapshot.copilotSessionId,
            "pid": Int(getpid()),
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )
        for _ in 0 ..< 50 {
            if controller.snapshot == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(controller.snapshot)
    }

    func testTranscriptOwnerQuarantinesForeignDtachSession() {
        let owningSession = "D7A1C176-B80F-4E6A-B0B5-378A70ACE162"
        let selectedSession = "6780CCA3-92AF-4506-95F2-F018A195A1A1"
        let sessions = URL(fileURLWithPath: "/tmp/state/sessions", isDirectory: true)
        var snapshot = ProcessTree.Snapshot()
        snapshot.parentOf = [10: 20, 20: 30, 30: 1]
        snapshot.nameOf = [10: "copilot", 20: "zsh", 30: "dtach"]
        let dtach = [
            ProcessTree.DtachProcess(
                pid: 30,
                parentPID: 1,
                socketPath: sessions
                    .appendingPathComponent("\(owningSession).sock").path,
                isMaster: true
            ),
        ]
        let environment = ["COPILOT_PROJECTS_SESSION": selectedSession]

        XCTAssertEqual(
            TranscriptController.transcriptOwnerMatchesSession(
                sessionId: selectedSession,
                ownerPID: 10,
                snapshot: snapshot,
                environment: environment,
                dtachProcesses: dtach,
                sessionsDirectory: sessions
            ),
            false
        )
        XCTAssertEqual(
            TranscriptController.transcriptOwnerMatchesSession(
                sessionId: owningSession,
                ownerPID: 10,
                snapshot: snapshot,
                environment: environment,
                dtachProcesses: dtach,
                sessionsDirectory: sessions
            ),
            true
        )
    }

    @MainActor
    func testControllerBlocksResumeForForeignOwnerBeforeAnyQuarantineIsRecorded() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = Session(title: "background", cwd: "/tmp")
        let project = Project(name: "target", cwd: "/tmp", sessions: [session])
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))

        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        // A foreign owner (a different appSessionId) left this transcript-owner
        // marker behind. Nothing has ever read the transcript for this session —
        // it's a background tab, so bootstrap never starts a TranscriptController
        // for it — so no quarantine file exists yet.
        let foreignCopilotSession = UUID().uuidString
        try JSONSerialization.data(withJSONObject: [
            "appSessionId": UUID().uuidString,
            "copilotSessionId": foreignCopilotSession,
            "pid": Int(getpid()),
        ]).write(
            to: sessions.appendingPathComponent("\(session.id).transcript-owner.json")
        )
        try Data(foreignCopilotSession.utf8).write(
            to: sessions.appendingPathComponent("\(session.id).copilot-session")
        )
        let quarantinePath = sessions
            .appendingPathComponent("\(session.id).transcript-quarantine.json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantinePath))

        let model = AppModel(
            stateRepository: repository,
            resumeMarkerDirectory: sessions
        )
        // Creating the controller (as bootstrapIfNeeded does for every session in
        // the selected project, well before any TranscriptController exists) must
        // validate the owner marker itself instead of relying on a quarantine file
        // that only a not-yet-started TranscriptController would otherwise populate.
        _ = model.controller(for: session.id)

        XCTAssertTrue(TranscriptController.isCopilotSessionQuarantined(
            sessionId: session.id,
            copilotSessionId: foreignCopilotSession,
            directory: sessions
        ))
    }

    func testRemoteTranscriptPersistentlyQuarantinesForeignOwnerSnapshot() throws {
        let sessionId = UUID().uuidString
        let foreignSessionId = UUID().uuidString
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
        let snapshotURL = URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        let revisionBeforeOwner = TranscriptController.remoteRevision(
            sessionId: sessionId
        )
        try JSONSerialization.data(withJSONObject: [
            "appSessionId": foreignSessionId,
            "copilotSessionId": snapshot.copilotSessionId,
            "pid": Int(getpid()),
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )
        XCTAssertNotEqual(
            TranscriptController.remoteRevision(sessionId: sessionId),
            revisionBeforeOwner
        )

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertTrue(remote.turns.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Paths.transcriptQuarantinePath(sessionId: sessionId)
        ))
        XCTAssertTrue(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: snapshot.copilotSessionId
        ))

        try JSONSerialization.data(withJSONObject: [
            "appSessionId": UUID().uuidString,
            "copilotSessionId": UUID().uuidString,
            "pid": Int(getpid()),
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )
        XCTAssertTrue(
            TranscriptController.loadRemoteSnapshot(sessionId: sessionId).turns.isEmpty
        )
        try FileManager.default.removeItem(
            atPath: Paths.transcriptOwnerPath(sessionId: sessionId)
        )
        try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
        let afterOwnerExit = TranscriptController.loadRemoteSnapshot(
            sessionId: sessionId
        )
        XCTAssertTrue(afterOwnerExit.turns.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        let replacement = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: UUID().uuidString,
            turns: []
        )
        try encoder.encode(replacement).write(to: snapshotURL, options: .atomic)
        let recovered = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(recovered.copilotSessionId, replacement.copilotSessionId)
        XCTAssertFalse(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: replacement.copilotSessionId
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Paths.transcriptQuarantinePath(sessionId: sessionId)
        ))
    }

    func testRemoteSnapshotRejectsStaleTranscriptDuringOwnerReclamation() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        // Simulate the tail end of dead-owner reclamation: the extension has
        // already atomically replaced transcript-owner.json with a new,
        // legitimate owner (matching appSessionId, new copilotSessionId), but
        // that new owner's async publishTranscript() hasn't overwritten
        // transcript.json yet — so the bytes on disk are still the *previous*
        // (possibly foreign) owner's stale content.
        let staleSnapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: UUID().uuidString,
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshotURL = URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        try encoder.encode(staleSnapshot).write(to: snapshotURL, options: .atomic)

        let newOwnerCopilotSessionId = UUID().uuidString
        XCTAssertNotEqual(newOwnerCopilotSessionId, staleSnapshot.copilotSessionId)
        try JSONSerialization.data(withJSONObject: [
            "appSessionId": sessionId,
            "copilotSessionId": newOwnerCopilotSessionId,
            "pid": Int(getpid()),
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )

        // The owner marker's appSessionId matches this session, so
        // transcriptOwnerAllowsRead alone would pass — the stale-transcript
        // cross-check must be what rejects the read.
        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertTrue(remote.turns.isEmpty)
        XCTAssertNotEqual(remote.copilotSessionId, staleSnapshot.copilotSessionId)
        XCTAssertTrue(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: staleSnapshot.copilotSessionId
        ))

        // Once the new owner's publishTranscript() catches up and overwrites
        // transcript.json with matching content, reads should succeed again.
        let freshSnapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: newOwnerCopilotSessionId,
            turns: []
        )
        try encoder.encode(freshSnapshot).write(to: snapshotURL, options: .atomic)
        let recovered = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(recovered.copilotSessionId, newOwnerCopilotSessionId)
    }

    /// A Copilot `/new` / `/resume` rotation replaces this tab's *own* owner
    /// marker (same pid, same appSessionId) and rewrites `transcript.json`. A
    /// read that sampled the previous conversation's bytes and only validated
    /// afterwards would see a legitimate, confirmed-this-tab owner naming a
    /// different Copilot session — and, before this fix, permanently quarantine
    /// the previous conversation, so `/resume` could never surface it again.
    /// A signature that moved underneath the read must reject without recording.
    func testSnapshotOwnerCrossCheckDoesNotQuarantineAcrossOwnerRotation() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let previousCopilotSessionId = UUID().uuidString
        let rotatedCopilotSessionId = UUID().uuidString
        let snapshotURL = URL(
            fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        let ownerURL = URL(
            fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)
        )
        func writeOwner(_ copilotSessionId: String) throws {
            try JSONSerialization.data(withJSONObject: [
                "appSessionId": sessionId,
                "copilotSessionId": copilotSessionId,
                "pid": Int(getpid()),
            ]).write(to: ownerURL, options: .atomic)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: previousCopilotSessionId,
            turns: []
        )).write(to: snapshotURL, options: .atomic)
        try writeOwner(previousCopilotSessionId)

        let allowed = TranscriptController.snapshotPassesOwnerCrossCheck(
            sessionId: sessionId,
            copilotSessionId: previousCopilotSessionId,
            duringRead: {
                // The extension rotates: owner marker forward, shared transcript
                // removed inside the same critical section.
                try? FileManager.default.removeItem(at: snapshotURL)
                try? writeOwner(rotatedCopilotSessionId)
            }
        )
        XCTAssertFalse(allowed)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Paths.transcriptQuarantinePath(sessionId: sessionId)
        ))
        XCTAssertFalse(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: previousCopilotSessionId
        ))

        // Once the rotated conversation publishes its own transcript, reads
        // succeed again under the new identity.
        try encoder.encode(TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: rotatedCopilotSessionId,
            turns: []
        )).write(to: snapshotURL, options: .atomic)
        XCTAssertEqual(
            TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
                .copilotSessionId,
            rotatedCopilotSessionId
        )

        // Rotating back (`/resume`) must find nothing quarantined.
        try encoder.encode(TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: previousCopilotSessionId,
            turns: []
        )).write(to: snapshotURL, options: .atomic)
        try writeOwner(previousCopilotSessionId)
        XCTAssertEqual(
            TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
                .copilotSessionId,
            previousCopilotSessionId
        )
    }

    // An alive but foreign/orphaned owner (a legacy marker with no appSessionId
    // whose pid does not resolve to this tab) must not permanently quarantine
    // this tab's own transcript. The read is rejected (nothing surfaced under an
    // untrusted owner) but no quarantine is persisted, so once the real session
    // reclaims ownership the transcript can appear again.
    func testRemoteSnapshotHidesButDoesNotQuarantineAliveUnresolvableOwner() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let ownTranscriptSession = UUID().uuidString
        let foreignOwnerSession = UUID().uuidString
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: ownTranscriptSession,
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
        // Legacy marker: no appSessionId, live pid (launchd, pid 1, always alive)
        // that the process tree cannot resolve to any tab -> `.aliveElsewhere`.
        try JSONSerialization.data(withJSONObject: [
            "copilotSessionId": foreignOwnerSession,
            "pid": 1,
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertTrue(remote.turns.isEmpty)
        XCTAssertNotEqual(remote.copilotSessionId, ownTranscriptSession)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Paths.transcriptQuarantinePath(sessionId: sessionId)
        ))
        XCTAssertFalse(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: ownTranscriptSession
        ))
    }

    // Once the confirmed current owner of a tab (a marker declaring this tab's
    // appSessionId) is exactly the transcript's Copilot session, a stale
    // quarantine entry for that session must self-heal so the real conversation
    // reappears.
    func testRemoteSnapshotSelfHealsQuarantineForConfirmedOwner() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let copilotSession = UUID().uuidString
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: copilotSession,
            turns: [
                TranscriptTurn(
                    id: "t0",
                    startedAt: Date(),
                    endedAt: Date(),
                    kind: "user",
                    userContent: "hello",
                    assistantMessages: [],
                    tools: [],
                    isAborted: false
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
        // A previously-recorded (now stale) quarantine for this tab's own session.
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "foreignCopilotSessionIds": [copilotSession],
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptQuarantinePath(sessionId: sessionId)),
            options: .atomic
        )
        // The confirmed current owner is exactly this session (declares this tab).
        try JSONSerialization.data(withJSONObject: [
            "appSessionId": sessionId,
            "copilotSessionId": copilotSession,
            "pid": Int(getpid()),
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertEqual(remote.copilotSessionId, copilotSession)
        XCTAssertEqual(remote.turns.count, 1)
        XCTAssertFalse(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: copilotSession
        ))
    }

    // Self-heal must require POSITIVE same-tab provenance: an unconfirmed
    // (alive-but-unresolvable) owner recording this session must NOT clear a
    // persisted quarantine, or genuinely foreign content could be un-hidden.
    func testRemoteSnapshotDoesNotSelfHealQuarantineForUnconfirmedOwner() throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        Paths.ensureStateDir()

        let copilotSession = UUID().uuidString
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: copilotSession,
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
        try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "foreignCopilotSessionIds": [copilotSession],
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptQuarantinePath(sessionId: sessionId)),
            options: .atomic
        )
        // Owner records this session but carries no appSessionId and its pid
        // (launchd) does not resolve to this tab -> unconfirmed. Must not self-heal.
        try JSONSerialization.data(withJSONObject: [
            "copilotSessionId": copilotSession,
            "pid": 1,
        ]).write(
            to: URL(fileURLWithPath: Paths.transcriptOwnerPath(sessionId: sessionId)),
            options: .atomic
        )

        let remote = TranscriptController.loadRemoteSnapshot(sessionId: sessionId)
        XCTAssertTrue(remote.turns.isEmpty)
        XCTAssertNotEqual(remote.copilotSessionId, copilotSession)
        XCTAssertTrue(TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: copilotSession
        ))
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
            Paths.legacyTranscriptOwnerLockPath(sessionId: sessionId),
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

    func testSessionArtifactCleanupRemovesPromptStatusTimestamp() throws {
        let sessionId = UUID().uuidString
        Paths.ensureStateDir()
        let path = Paths.promptStatusTimestampMarkerPath(sessionId: sessionId)
        try Data("123".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        SessionArtifacts.removeFiles(sessionId: sessionId)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
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
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
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

    func testControlCommandRouterValidatesBeforeDispatch() {
        var didSetStatus = false
        var copilotRequests: [ControlRequest] = []
        let router = ControlCommandRouter(actions: .init(
            listProjects: { "" },
            listStatus: { "" },
            setStatus: { _, _, _ in didSetStatus = true; return .success() },
            notify: { _, _, _ in .success() },
            newProject: { _ in .success() },
            newSession: { _ in .success() },
            newCopilotSession: { copilotRequests.append($0); return .success("id", code: "created") },
            renameProject: { _, _ in .success() },
            focus: { _ in .success() },
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
    }

    // MARK: - Desktop Copilot session creation

    @MainActor
    func testDesktopCopilotSessionLaunchesWithAllowAllAndInheritedDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = Session(id: "existing", title: "shell", cwd: root.path)
        let project = Project(
            id: "p1", name: "First", cwd: "/tmp",
            sessions: [existing], selectedSessionId: existing.id)
        var launches: [(String, String?, String?, Bool)] = []
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { nil },
            ledger: SessionCreationLedger(url: root.appendingPathComponent("ledger.json")),
            onLaunch: { launches.append(($0, $1, $2, $3)) }
        )
        let prompt = "  Review Sean's changes; $(touch SHOULD_NOT_EXIST)\r\n100% literal\n  "
        let id = try model.addCopilotSession(toProjectId: project.id, initialPrompt: prompt)
        XCTAssertEqual(launches.count, 1)
        XCTAssertEqual(launches[0].0, id)
        XCTAssertEqual(launches[0].1, "/opt/copilot/bin/copilot")
        XCTAssertEqual(launches[0].2, prompt.replacingOccurrences(of: "\r\n", with: "\n"))
        XCTAssertTrue(launches[0].3)
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
        XCTAssertTrue(launches.dropFirst().allSatisfy { $0.2 == nil && $0.3 })
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            XCTAssertEqual(Array(fields.prefix(4)), [
                "--no-remote", "--no-remote-export", "--interactive", prompt,
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
    private func makeRemoteCreateModel(
        root: URL,
        projects: [Project],
        selectedProjectId: String?,
        copilotExecutable: @escaping () -> String? = { "/opt/copilot/bin/copilot" },
        reposDirectory: @escaping () -> String?,
        backendAvailable: @escaping () -> Bool = { true },
        ledger: SessionCreationLedger,
        onLaunch: @escaping (String, String?, String?, Bool) -> Void
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
            sessionCreationLedger: ledger
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
        var launches: [(sessionId: String, executable: String?, prompt: String?, allowAll: Bool)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
        XCTAssertEqual(launches.first?.allowAll, true)
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            remoteSessionLauncher: { _, _, _, _ in launches += 1 },
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            remoteSessionLauncher: { _, _, _, _ in restartLaunches += 1 },
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
            remoteSessionLauncher: { _, _, _, _ in restartLaunches += 1 },
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
        var launches: [(sessionId: String, executable: String?, prompt: String?, allowAll: Bool)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
        XCTAssertEqual(launches.first?.allowAll, true)
        XCTAssertEqual(
            launches.first?.prompt,
            AppModel.adversarialReviewPrompt(
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
        var launches: [(sessionId: String, executable: String?, prompt: String?, allowAll: Bool)] = []
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [project],
            selectedProjectId: "p1",
            reposDirectory: { nil },
            ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
        XCTAssertEqual(launches.first?.allowAll, true)
        XCTAssertEqual(
            launches.first?.prompt,
            AppModel.adversarialReviewPrompt(
                for: try XCTUnwrap(PullRequestReviewTarget.parse(pullRequestURL))
            )
        )

        XCTAssertNil(model.addAdversarialReviewSession(
            toProjectId: "p1",
            pullRequestURL: "https://example.com/not-a-pr"
        ))
        XCTAssertEqual(launches.count, 1)
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
            reposDirectory: { repos.path }, ledger: ledger, onLaunch: { _, _, _, _ in })

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
            onLaunch: { _, _, _, _ in })

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
            onLaunch: { _, _, _, _ in }
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
            sessionId: requestId.uuidString, createdAt: Date()))

        var launches = 0
        let model = try makeRemoteCreateModel(
            root: root,
            projects: [Project(id: "p1", name: "First", cwd: "/tmp", sessions: [])],
            selectedProjectId: "p1",
            reposDirectory: { repos.path },
            ledger: ledger,
            onLaunch: { _, _, _, _ in launches += 1 })

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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            onLaunch: { _, _, _, _ in launches += 1 })

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
            onLaunch: { _, _, _, _ in }
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
        var launches: [(id: String, executable: String?, prompt: String?, allowAll: Bool)] = []
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            copilotExecutable: { executable }, reposDirectory: { repos.path }, ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
            XCTAssertEqual(launches.last?.allowAll, kind != .terminal)
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
        var launches: [(id: String, executable: String?, prompt: String?, allowAll: Bool)] = []
        let ledger = SessionCreationLedger(url: root.appendingPathComponent("ledger.json"))
        let model = try makeRemoteCreateModel(
            root: root, projects: [project], selectedProjectId: project.id,
            reposDirectory: { repos.path }, ledger: ledger,
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
        XCTAssertTrue(launches[0].allowAll)
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
            onLaunch: { launches.append(($0, $1, $2, $3)) }
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            for suffix in ["copilot-session", "copilot-allow-all"] {
                try UUID().uuidString.write(
                    to: root.appendingPathComponent("\(request.requestId.uuidString).\(suffix)"),
                    atomically: true, encoding: .utf8)
            }
            backendAvailable = false
            XCTAssertEqual(create(), .unavailable)
            backendAvailable = true
            cwd = nil
            XCTAssertEqual(create(), .invalid)
            cwd = root.path
            XCTAssertEqual(launches, before)
            for suffix in ["copilot-session", "copilot-allow-all"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath:
                    root.appendingPathComponent("\(request.requestId.uuidString).\(suffix)").path))
            }
            XCTAssertEqual(create(), .created(RemoteCreateSessionResponse(
                requestId: request.requestId, projectId: "p1", sessionId: request.requestId.uuidString)))
            XCTAssertEqual(launches, before + 1)
            for suffix in ["copilot-session", "copilot-allow-all"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath:
                    root.appendingPathComponent("\(request.requestId.uuidString).\(suffix)").path))
            }
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
        for suffix in ["copilot-session", "copilot-allow-all"] {
            try UUID().uuidString.write(
                to: root.appendingPathComponent("\(request.requestId.uuidString).\(suffix)"),
                atomically: true, encoding: .utf8)
        }
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
        for suffix in ["copilot-session", "copilot-allow-all"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                root.appendingPathComponent("\(request.requestId.uuidString).\(suffix)").path))
        }
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
            copilotSessionAllowAll: false, resumeCopilotExecutable: copilot.path,
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
            copilotSessionAllowAll: true, resumeCopilotExecutable: copilot.path,
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
            ledger: ledger, onLaunch: { _, _, _, _ in launches += 1 }
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
            onLaunch: { _, _, _, _ in launches += 1 }
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
            onLaunch: { _, _, _, _ in
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
            remoteSessionLauncher: { _, _, _, _ in launches += 1 },
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
            onLaunch: { _, _, _, _ in launches += 1 }
        )
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", kind: .terminal)), .gone)
        XCTAssertEqual(model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: id, projectId: "p1", kind: .copilot)), .conflict)
        XCTAssertEqual(launches, 0)
    }

    @MainActor
    func testCreateRemoteSessionPreservesUnboundLegacyReplayWithoutTrustingNewOptions() throws {
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
            onLaunch: { _, _, _, _ in launches += 1 }
        )
        let legacy = RemoteCreateSessionRequest(requestId: id, projectId: "p1")
        XCTAssertEqual(model.createRemoteSession(legacy), .existing(
            RemoteCreateSessionResponse(requestId: id, projectId: "p2", sessionId: id.uuidString)))
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
                            operationSupport: .unavailable
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
                            operationSupport: .unavailable
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

    private func runHook(
        hookURL: URL,
        action: String,
        payload: String,
        tabId: String,
        root: URL,
        bin: URL,
        capture: URL
    ) throws {
        let process = try startHook(
            hookURL: hookURL,
            action: action,
            payload: payload,
            tabId: tabId,
            root: root,
            bin: bin,
            capture: capture
        )
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func startHook(
        hookURL: URL,
        action: String,
        payload: String,
        tabId: String,
        root: URL,
        bin: URL,
        capture: URL
    ) throws -> Process {
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
        return process
    }

    private func cliCallLines(in capture: URL) throws -> [String] {
        try String(contentsOf: capture, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private func completionSignals(in calls: [String]) -> Int {
        calls.filter {
            $0.contains("--source agent-stop") || $0.contains("--notification completed")
        }.count
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
