import Foundation
import CopilotProjectsCore
@testable import CopilotProjectsHost

extension AgentActivitySnapshot {
    /// The Copilot session these snapshots, and the tab's marker, name as the owner.
    static let trackerOwner = "11111111-2222-3333-4444-555555555555"

    /// What a tracker publishes: a heartbeat `age` old, with the `isProcessing`
    /// reading taken with it. `turn` is its foreground-turn flag, which follows
    /// the reading unless a test says otherwise.
    static func tracker(
        processing: Bool?, turn: Bool? = nil, scheduled: Bool = false, age: TimeInterval = 1,
        error: String? = nil, question: String? = nil, permissions: [String] = [],
        idleGeneration: Int = 1, owner: String = trackerOwner, at now: Date = Date()
    ) -> AgentActivitySnapshot {
        let updated = now.addingTimeInterval(-age)
        let stamp = updated.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return AgentActivitySnapshot(
            schemaVersion: 1,
            updatedAt: stamp,
            foregroundTurnActive: turn ?? (processing == true && !scheduled),
            scheduledTurnActive: scheduled, activeSubagents: [],
            schedules: [], idleGeneration: idleGeneration, lastIdleAborted: false, error: error,
            trackedUserInputs: question.map {
                [TrackedUserInput(
                    requestId: "question", question: $0, choices: [], allowFreeform: true,
                    requestedAt: stamp)]
            } ?? [],
            trackedElicitations: [],
            pendingPermissionRequestIds: permissions, copilotSessionId: owner,
            conversationEpoch: "epoch",
            runtimeActivity: processing.map {
                RuntimeActivitySnapshot(
                    processing: $0,
                    observedAtMilliseconds: Int64(updated.timeIntervalSince1970 * 1_000),
                    idleAtMilliseconds: nil, error: nil)
            }
        )
    }
}

extension AppModel {
    /// Writes a tracker's snapshot and the tab's owner marker, then scans. The marker
    /// names the snapshot's own Copilot session unless `tabOwner` puts another in the tab.
    func publishTracker(
        _ snapshot: AgentActivitySnapshot, sessionId: String, tabOwner: String? = nil,
        now: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(
            at: agentActivityDirectory, withIntermediateDirectories: true)
        if let owner = tabOwner ?? snapshot.copilotSessionId {
            try Data(owner.utf8).write(
                to: resumeMarkerDirectory.appendingPathComponent("\(sessionId).copilot-session"))
        }
        try JSONEncoder().encode(snapshot).write(
            to: agentActivityDirectory.appendingPathComponent("\(sessionId).agent-activity.json"),
            options: .atomic)
        refreshAgentActivitySnapshots(now: now)
    }

    /// The tracker's snapshot goes, as it does when its process exits.
    func removeTracker(sessionId: String, now: Date = Date()) throws {
        try FileManager.default.removeItem(
            at: agentActivityDirectory.appendingPathComponent("\(sessionId).agent-activity.json"))
        refreshAgentActivitySnapshots(now: now)
    }

    /// Runs a foreground turn from its start to its end, as the session's tracker
    /// reports it. Both snapshots carry one heartbeat time, so the turn has no span
    /// to summarize and its alert posts at once.
    func finishTurn(
        sessionId: String, owner: String = AgentActivitySnapshot.trackerOwner
    ) throws {
        let now = Date()
        try publishTracker(
            .tracker(processing: true, owner: owner, at: now), sessionId: sessionId, now: now)
        try publishTracker(
            .tracker(processing: false, owner: owner, at: now), sessionId: sessionId, now: now)
        postCompletionIfReady(sessionId: sessionId)
    }

    /// Puts a session in a status directly, for a test of something that reads it.
    func setStatus(_ status: SessionStatus, sessionId: String) {
        guard let loc = locateIndex(sessionId) else { return }
        projects[loc.p].sessions[loc.s].status = status
    }

    /// Leaves the finished dot a turn leaves when it ends off screen.
    func setFinishedUnseen(sessionId: String) {
        guard let loc = locateIndex(sessionId) else { return }
        projects[loc.p].sessions[loc.s].finishedUnseen = true
    }
}
