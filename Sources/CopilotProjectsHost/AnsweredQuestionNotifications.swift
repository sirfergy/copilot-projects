import Foundation
import CopilotProjectsCore

/// A question alert the host posted, remembered until there is positive
/// evidence that its question no longer needs an answer.
struct PostedQuestionNotification: Equatable {
    let id: UUID
    /// The tracked `ask_user`/elicitation request the alert asked about, when
    /// the tracker had published it before the alert was posted.
    let requestId: String?
    /// The Copilot conversation the question belonged to, when known.
    let rootSessionId: String?
    var conversationEpoch: String?
    /// Only a snapshot written after this can vouch for the question: the
    /// snapshot that listed `requestId`, otherwise the time the alert was posted.
    var evidenceAfterMilliseconds: Int64
    /// Set once a snapshot of its conversation had a full question list: the
    /// tracker may then have dropped this question while it was still
    /// pending, so the question going missing no longer proves an answer.
    var mayBeUnlisted = false
    /// The tracker listed the question only under an ID it can't follow (a
    /// synthetic durable `ask_user` entry), which it can drop while the
    /// question is still pending, so only an ended turn proves an answer.
    var listedWithoutRequestId = false
}

/// Decides which posted question alerts can be withdrawn because their
/// questions were answered somewhere else (terminal, app, web, or watch).
///
/// Only positive evidence counts. Status hooks can report activity while a
/// question is still pending, a snapshot can predate the alert, and a
/// restarted tracker re-lists recovered questions under a new epoch, so none
/// of those alone withdraws an alert.
enum AnsweredQuestionNotifications {
    /// The tracker lists at most this many pending questions of each kind and
    /// silently drops the oldest beyond that (`MAX_USER_INPUTS` and
    /// `MAX_ELICITATIONS`).
    static let trackerQuestionLimit = 50

    static func mayOmitQuestions(_ snapshot: AgentActivitySnapshot) -> Bool {
        (snapshot.trackedUserInputs?.count ?? 0) >= trackerQuestionLimit
            || (snapshot.trackedElicitations?.count ?? 0) >= trackerQuestionLimit
    }

    static func partition(
        _ posted: [PostedQuestionNotification],
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        ownerSessionId: @autoclosure () -> String?,
        now: Date = Date()
    ) -> (answered: [UUID], pending: [PostedQuestionNotification]) {
        // A disconnected tracker keeps republishing its last lists but can no
        // longer see questions complete, so it counts as no tracker at all.
        let fresh = snapshot.flatMap {
            $0.isFresh(at: now) && !$0.reportsTerminalDisconnect ? $0 : nil
        }
        let tracksQuestions = fresh?.trackedUserInputs != nil
            && fresh?.trackedElicitations != nil
        let full = fresh.map(mayOmitQuestions) ?? false
        let listed = Set(
            (fresh?.trackedUserInputs ?? []).map(\.requestId)
                + (fresh?.trackedElicitations ?? []).map(\.requestId)
        )
        let root = fresh?.copilotSessionId?.lowercased()
        let updatedAt = fresh?.updatedAtMilliseconds
        var cachedOwner: String??
        func tabOwns(_ root: String) -> Bool {
            if let cachedOwner { return cachedOwner == root }
            let owner = ownerSessionId()?.lowercased()
            cachedOwner = .some(owner)
            return owner == root
        }

        var answered: [UUID] = []
        var pending: [PostedQuestionNotification] = []
        for var record in posted {
            let newer = updatedAt.map { $0 > record.evidenceAfterMilliseconds } ?? false
            let sameRoot = root != nil && root == record.rootSessionId?.lowercased()
            if sameRoot, full { record.mayBeUnlisted = true }
            let vouched = record.requestId != nil || record.listedWithoutRequestId
            let resolved: Bool
            // Request IDs are only meaningful within their own conversation.
            if let requestId = record.requestId, sameRoot, listed.contains(requestId) {
                // A restarted tracker recovers the question under a new epoch.
                if newer, let epoch = fresh?.conversationEpoch,
                   epoch != record.conversationEpoch, let updatedAt {
                    record.conversationEpoch = epoch
                    record.evidenceAfterMilliseconds = updatedAt
                }
                resolved = false
            } else if fresh == nil {
                // Without a live tracker, a session that left the wait is the
                // evidence. A tracker that once vouched for the question going
                // quiet is weaker (a transient read can miss it), so it needs
                // the turn to have ended.
                resolved = vouched ? status == .idle : status != .waiting
            } else if !newer {
                resolved = false
            } else if let root, record.rootSessionId != nil, !sameRoot, tabOwns(root) {
                // The tab moved on to another Copilot conversation.
                resolved = true
            } else if record.requestId != nil {
                // Within one tracker epoch a request only leaves the snapshot
                // once it is answered, cancelled, or completed, unless the
                // list was ever full enough for the tracker to drop it.
                resolved = sameRoot && tracksQuestions && !record.mayBeUnlisted
                    && fresh?.conversationEpoch == record.conversationEpoch
            } else {
                // Nothing tracks this question. A synthetic entry can vanish,
                // a tracker still recovering a missed question can publish an
                // empty list, and a parallel hook can report activity while it
                // is still pending, but the turn can't end until it's answered.
                resolved = listed.isEmpty && status == .idle
            }
            if resolved {
                answered.append(record.id)
            } else {
                pending.append(record)
            }
        }
        return (answered, pending)
    }
}
