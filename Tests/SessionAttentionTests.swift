import AppKit
import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsProtocol

@MainActor
final class SessionAttentionTests: XCTestCase {
    private func activity(
        failure: String? = nil,
        question: Bool = false,
        budget: Bool = false
    ) -> AgentActivitySnapshot {
        let now = ISO8601DateFormatter().string(from: Date())
        var snapshot = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: now, foregroundTurnActive: false, scheduledTurnActive: false,
            activeSubagents: [], schedules: [], idleGeneration: 1, lastIdleAborted: false,
            lastIdleTurnKind: nil, error: nil
        )
        snapshot.lastTurnError = failure.map { TrackedTurnError(message: $0) }
        if question {
            snapshot.trackedUserInputs = [TrackedUserInput(
                requestId: "q", question: "Proceed?", choices: ["Yes"], allowFreeform: false,
                requestedAt: now, agentId: nil
            )]
        }
        if budget {
            snapshot.workflow = RemoteSessionWorkflow(
                observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000),
                capabilities: ["answer-session-budget"], sendReady: false,
                budgetRequest: RemoteBudgetRequest(requestId: "b", maxAiCredits: 30, usedAiCredits: 31)
            )
        }
        return snapshot
    }

    private typealias Case = (
        name: String, apply: (inout Session) -> Void, kind: RemoteSessionAttention.Kind?, label: String
    )

    func testEachStatePublishesTheDecisionTheSidebarShows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [Case] = [
            ("idle", { _ in }, nil, "Idle"),
            ("running", { $0.status = .running }, nil, "Running"),
            ("terminal wait", { $0.status = .waiting }, .waiting, "Waiting for input"),
            ("question", { $0.agentActivity = self.activity(question: true) }, .waiting, "Waiting for input"),
            // A budget request waits for the user.
            ("budget", { $0.agentActivity = self.activity(budget: true) }, .waiting, "Waiting for input"),
            // A failure stays once seen, and a manual mark doesn't hide it.
            ("seen failure", { $0.agentActivity = self.activity(failure: "429") }, .failed, "Request failed"),
            ("marked failure", {
                $0.agentActivity = self.activity(failure: "429")
                $0.markedUnread = true
            }, .failed, "Request failed"),
            ("ready", { $0.finishedUnseen = true }, .ready, "Finished"),
            // Ready needs the session idle.
            ("finished, running again", {
                $0.finishedUnseen = true
                $0.status = .running
            }, nil, "Running"),
            ("notification", { $0.hasUnread = true }, .unread, "Idle"),
            ("marked", { $0.markedUnread = true }, .unread, "Idle"),
        ]
        let project = Project(
            name: "Attention", cwd: root.path,
            sessions: cases.map { Session(title: $0.name, cwd: root.path) }
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        for (index, entry) in cases.enumerated() {
            entry.apply(&model.projects[0].sessions[index])
        }

        let published = model.remoteWorkspaceSnapshot().projects[0].sessions
        for (index, entry) in cases.enumerated() {
            let local = model.projects[0].sessions[index]
            XCTAssertEqual(local.attention, entry.kind, entry.name)
            XCTAssertEqual(local.attentionLabel, entry.label, entry.name)
            XCTAssertEqual(published[index].attention, entry.kind.map(RemoteSessionAttention.init), entry.name)
            XCTAssertEqual(published[index].needsEndConfirmation, local.requiresEndConfirmation, entry.name)
        }
    }

    func testNextVisitsByRankThenWorkspaceOrderAndCarriesOnAfterAClearedSession() {
        var sessions: [(id: String, rank: Int?)] = [
            ("unread", 2), ("waiting 1", 0), ("idle", nil), ("failed", 1), ("ready", 2), ("waiting 2", 0),
        ]
        func next(from current: String?, previous: RemoteAttentionCursor? = nil) -> String? {
            RemoteAttentionCursor.next(in: sessions, from: current, previous: previous)?.sessionId
        }

        var visited: [String] = []
        var cursor: RemoteAttentionCursor?
        for _ in 0..<6 {
            cursor = RemoteAttentionCursor.next(in: sessions, from: cursor?.sessionId, previous: cursor)
            visited.append(cursor?.sessionId ?? "none")
        }
        XCTAssertEqual(visited, ["waiting 1", "waiting 2", "failed", "unread", "ready", "waiting 1"])
        XCTAssertEqual(next(from: "idle"), "waiting 1", "A session Next didn't go to starts from the top")

        // Viewing "unread" cleared it; Next carries on to the session after it.
        sessions[0].rank = nil
        let cleared = RemoteAttentionCursor(sessionId: "unread", rank: 2)
        XCTAssertEqual(next(from: "unread", previous: cleared), "ready")
        XCTAssertEqual(next(from: "unread"), "waiting 1")
        sessions[4].rank = nil
        XCTAssertEqual(
            next(from: "ready", previous: RemoteAttentionCursor(sessionId: "ready", rank: 2)), "waiting 1",
            "After the last session it wraps around"
        )
        sessions[1].rank = nil
        XCTAssertEqual(
            next(from: "waiting 1", previous: RemoteAttentionCursor(sessionId: "waiting 1", rank: 0)), "waiting 2"
        )

        XCTAssertNil(RemoteAttentionCursor.next(in: [("idle", nil)], from: "idle", previous: nil))
    }
}
