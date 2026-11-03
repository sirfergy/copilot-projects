import Foundation
import CopilotProjectsProtocol

/// Pure association of currently-retained inline images to transcript turns.
///
/// An image is attached to the turn active at its retained content's origin —
/// the turn with the greatest `startedAt` that is still `<= displayedAt`.
/// Unchanged, still-advertised retransmissions preserve that origin timestamp.
/// This deliberately uses only `startedAt` (never `endedAt`), so the still-open
/// streaming turn's ever-growing `[startedAt, now]` window can't reshuffle
/// associations between requests: once a turn exists with a `startedAt` at or
/// before an image's display time, that image's turn assignment is stable.
///
/// Images displayed before the first turn began are dropped (nothing to attach
/// them to). Only currently-retained images are ever passed in, so an attached
/// ref's exact `(imageId, version)` is always fetchable — no 404 tombstones.
///
/// The snapshot's recoverable dropped turns take part on the same timeline (see
/// `TranscriptSnapshot.interleaving(dropped:into:)`) and keep their own refs, so
/// an image displayed during a turn the writer since evicted stays with that
/// turn — which remote responses still serve — rather than moving to whichever
/// live turn preceded it.
enum TranscriptImageAssociation {
    static func attach(
        images: [RemoteKittyImageCapture.RetainedImageInfo],
        to snapshot: TranscriptSnapshot
    ) -> TranscriptSnapshot {
        if images.isEmpty,
           snapshot.turns.allSatisfy({ $0.images == nil }),
           (snapshot.droppedTurns ?? []).allSatisfy({ $0.images == nil }) {
            return snapshot
        }
        let timeline = TranscriptSnapshot.interleaving(
            dropped: snapshot.recoverableDroppedTurns,
            into: snapshot.turns
        )
        let turns = timeline.map(\.turn)
        // turnIndex -> imageId -> chosen (newest) info for that turn.
        var byTurn: [Int: [UInt32: RemoteKittyImageCapture.RetainedImageInfo]] = [:]
        if !turns.isEmpty {
            for image in images {
                guard let turnIndex = Self.activeTurnIndex(turns, at: image.displayedAt)
                else { continue }
                var perImage = byTurn[turnIndex] ?? [:]
                if let existing = perImage[image.imageId] {
                    if image.version > existing.version { perImage[image.imageId] = image }
                } else {
                    perImage[image.imageId] = image
                }
                byTurn[turnIndex] = perImage
            }
        }
        // Rebuild EVERY turn from host-computed refs (or nil), never preserving
        // any `images` that were on the decoded snapshot: the CLI writer owns
        // the transcript file but must not be trusted to supply image refs, so
        // the host is the sole authority for this field.
        var liveTurns: [TranscriptTurn] = []
        var droppedTurns: [TranscriptTurn] = []
        for (index, entry) in timeline.enumerated() {
            let turn = entry.turn
            let refs: [TranscriptImageRef]? = byTurn[index].map { perImage in
                perImage.values
                    .sorted {
                        if $0.displayedAt != $1.displayedAt { return $0.displayedAt < $1.displayedAt }
                        return $0.imageId < $1.imageId
                    }
                    .map {
                        let afterMessageId = Self.precedingAssistantMessageId($0.displayedAt, in: turn)
                        return TranscriptImageRef(
                            imageId: $0.imageId,
                            contentVersion: $0.version,
                            displayedAt: Self.wireSafeDisplayedAt(
                                $0.displayedAt,
                                afterAssistantMessageId: afterMessageId,
                                in: turn
                            ),
                            afterAssistantMessageId: afterMessageId,
                            pixelWidth: $0.pixelWidth,
                            pixelHeight: $0.pixelHeight
                        )
                    }
            }
            let rebuilt = TranscriptTurn(
                id: turn.id,
                startedAt: turn.startedAt,
                endedAt: turn.endedAt,
                kind: turn.kind,
                userContent: turn.userContent,
                assistantMessages: turn.assistantMessages,
                tools: turn.tools,
                isAborted: turn.isAborted,
                images: refs,
                error: turn.error,
                reasoningSteps: turn.reasoningSteps
            )
            if entry.isDropped {
                droppedTurns.append(rebuilt)
            } else {
                liveTurns.append(rebuilt)
            }
        }
        return TranscriptSnapshot(
            schemaVersion: snapshot.schemaVersion,
            updatedAt: snapshot.updatedAt,
            copilotSessionId: snapshot.copilotSessionId,
            turns: liveTurns,
            totalTurns: snapshot.totalTurns,
            droppedTurns: droppedTurns.isEmpty ? nil : droppedTurns
        )
    }

    private static func precedingAssistantMessageId(
        _ displayedAt: Date,
        in turn: TranscriptTurn
    ) -> String? {
        turn.assistantMessages.last { message in
            !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && message.timestamp <= displayedAt
        }?.id
    }

    /// Preserves sub-second ordering (`displayedAt < message.timestamp`) across
    /// whole-second ISO-8601 wire encoding when an image precedes every
    /// non-blank assistant message in the turn (`afterAssistantMessageId == nil`),
    /// while leaving mid-turn images untouched so they never step back past a
    /// preceding message.
    private static func wireSafeDisplayedAt(
        _ displayedAt: Date,
        afterAssistantMessageId: String?,
        in turn: TranscriptTurn
    ) -> Date {
        guard afterAssistantMessageId == nil else { return displayedAt }
        let wholeSecond = displayedAt.timeIntervalSince1970.rounded(.down)
        let precedesSameSecondMessage = turn.assistantMessages.contains { message in
            displayedAt < message.timestamp
                && message.timestamp.timeIntervalSince1970.rounded(.down) == wholeSecond
        }
        guard precedesSameSecondMessage else { return displayedAt }
        return Date(timeIntervalSince1970: wholeSecond - 1)
    }

    /// Grace window after a turn's `endedAt` during which a multi-chunk Kitty
    /// PNG still flushing through the PTY at `session.idle` time (or whole-second
    /// ISO-8601 rounding) still counts as belonging to that turn.
    private static let postTurnEndGraceSeconds: TimeInterval = 2

    /// Index of the turn active at `time` — the last (chronologically latest)
    /// turn whose `startedAt <= time`, provided that turn is not a synthetic
    /// `session-resume-` marker and had not already ended before `time`.
    static func activeTurnIndex(_ turns: [TranscriptTurn], at time: Date) -> Int? {
        guard let index = turns.lastIndex(where: { $0.startedAt <= time }) else {
            return nil
        }
        let turn = turns[index]
        guard !turn.id.hasPrefix("session-resume-") else {
            return nil
        }
        if let endedAt = turn.endedAt,
           time > endedAt.addingTimeInterval(Self.postTurnEndGraceSeconds) {
            return nil
        }
        return index
    }
}
