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
                    .map { TranscriptImageRef(imageId: $0.imageId, contentVersion: $0.version) }
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
                images: refs
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

    /// Index of the turn active at `time` — the last (chronologically latest)
    /// turn whose `startedAt <= time`, or `nil` if no turn had started yet.
    /// Transcript turns are appended in start order, so `lastIndex` yields the
    /// greatest `startedAt <= time` and resolves identical `startedAt` ties to
    /// the later turn.
    static func activeTurnIndex(_ turns: [TranscriptTurn], at time: Date) -> Int? {
        turns.lastIndex { $0.startedAt <= time }
    }
}
