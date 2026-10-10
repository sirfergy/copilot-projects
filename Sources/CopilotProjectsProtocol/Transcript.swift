import Foundation

public struct TranscriptSnapshot: Codable, Equatable, Sendable {
    /// Largest window a remote client may request in one `/transcript` response.
    /// Matches the CLI writer's own per-session turn cap, so a client can never
    /// ask for more than a full snapshot could contain.
    public static let maximumRemoteTurnLimit = 200

    public let schemaVersion: Int
    public let updatedAt: Date
    public let copilotSessionId: String
    public let turns: [TranscriptTurn]
    /// How many turns exist in the full transcript when `turns` carries only a
    /// window of it. Absent (`nil`) means `turns` *is* the whole transcript —
    /// the exact legacy response shape, which clients that never send a window
    /// request (iOS, older web clients) keep receiving. Optional with a `nil`
    /// default so every existing constructor and decoder keeps working, and so
    /// encoding omits the key entirely rather than emitting `null`.
    public let totalTurns: Int?
    /// Turns the CLI writer recently evicted to stay under its turn cap, kept
    /// (bounded) in the transcript file so a client whose cursor is newer than
    /// an eviction can still receive a turn it never saw. Host-internal: it is
    /// merged into cursor responses by `remoteWindow` and never sent to a
    /// client as its own field. Optional with a `nil` default, like
    /// `totalTurns`, so older snapshots decode and encoding omits the key.
    public let droppedTurns: [TranscriptTurn]?

    public init(
        schemaVersion: Int,
        updatedAt: Date,
        copilotSessionId: String,
        turns: [TranscriptTurn],
        totalTurns: Int? = nil,
        droppedTurns: [TranscriptTurn]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.copilotSessionId = copilotSessionId
        self.turns = turns
        self.totalTurns = totalTurns
        self.droppedTurns = droppedTurns
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        copilotSessionId = try container.decode(String.self, forKey: .copilotSessionId)
        turns = try container.decode([TranscriptTurn].self, forKey: .turns)
        totalTurns = try container.decodeIfPresent(Int.self, forKey: .totalTurns)
        // A malformed recovery buffer must never cost the transcript itself.
        droppedTurns = try? container.decodeIfPresent([TranscriptTurn].self, forKey: .droppedTurns)
    }

    /// The most recent `limit` turns, tagged with the full turn count so a
    /// client knows how many older turns it can still ask for. Always reports
    /// `totalTurns` — even when nothing was dropped — so a client that asked for
    /// a window can distinguish "this is everything" from "an older host ignored
    /// my request and sent the whole transcript" (which omits the field).
    public func limitedToMostRecentTurns(_ limit: Int) -> TranscriptSnapshot {
        let bounded = max(0, limit)
        let dropped = max(0, turns.count - bounded)
        return TranscriptSnapshot(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            copilotSessionId: copilotSessionId,
            turns: dropped > 0 ? Array(turns.suffix(bounded)) : turns,
            totalTurns: turns.count
        )
    }

    /// The part of the transcript a remote client asked for: every turn from
    /// the first one that started at or after `cursor`, then at most the most
    /// recent `limit` of those. A cursor for a different conversation (the tab
    /// moved on with `/new` or `/resume`) is ignored, so the client gets a
    /// complete response for the conversation it now has to show.
    ///
    /// The cursor selects a positional suffix rather than filtering by
    /// timestamp, so a turn positioned after the match is returned even if its
    /// own `startedAt` were earlier. The recoverable dropped turns that started
    /// at or after the cursor are woven into that suffix by start time (see
    /// `interleaving(dropped:into:)`), so a turn the writer evicted between two
    /// of the client's fetches still reaches it; `limit` applies after that
    /// merge. Whenever a cursor or limit applies, `totalTurns` reports the
    /// whole live transcript, exactly as `limitedToMostRecentTurns` does; with
    /// neither, this is the unchanged legacy response. `droppedTurns` itself
    /// is never part of a response.
    public func remoteWindow(limit: Int?, after cursor: TranscriptCursor?) -> TranscriptSnapshot {
        let applicableCursor = cursor.flatMap {
            $0.copilotSessionId == copilotSessionId ? $0 : nil
        }
        guard limit != nil || applicableCursor != nil else {
            return TranscriptSnapshot(
                schemaVersion: schemaVersion,
                updatedAt: updatedAt,
                copilotSessionId: copilotSessionId,
                turns: turns,
                totalTurns: totalTurns
            )
        }
        var selected = turns
        if let applicableCursor {
            let start = applicableCursor.startedAt
            let suffix = turns.firstIndex { $0.startedAt >= start }
                .map { turns[$0...] } ?? []
            selected = Self.interleaving(
                dropped: recoverableDroppedTurns.filter { $0.startedAt >= start },
                into: suffix
            ).map(\.turn)
        }
        if let limit {
            selected = Array(selected.suffix(max(0, limit)))
        }
        return TranscriptSnapshot(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            copilotSessionId: copilotSessionId,
            turns: selected,
            totalTurns: turns.count
        )
    }

    /// The dropped turns a client could still be missing, in start order: one
    /// per id (the latest eviction wins) and none that the live transcript
    /// also carries, because the live copy is authoritative.
    public var recoverableDroppedTurns: [TranscriptTurn] {
        guard let droppedTurns, !droppedTurns.isEmpty else { return [] }
        let liveIds = Set(turns.map(\.id))
        var seen = Set<String>()
        let unique = droppedTurns.reversed().filter {
            !liveIds.contains($0.id) && seen.insert($0.id).inserted
        }.reversed()
        return unique.enumerated()
            .sorted { ($0.element.startedAt, $0.offset) < ($1.element.startedAt, $1.offset) }
            .map(\.element)
    }

    /// Weaves `dropped` (already in start order) into `live` without
    /// reordering `live`: each dropped turn goes just before the first live
    /// turn that started after it, so it precedes a live turn it ties with.
    /// Each entry records which list its turn came from.
    public static func interleaving<Live: Sequence>(
        dropped: [TranscriptTurn],
        into live: Live
    ) -> [(turn: TranscriptTurn, isDropped: Bool)] where Live.Element == TranscriptTurn {
        var timeline: [(turn: TranscriptTurn, isDropped: Bool)] = []
        timeline.reserveCapacity(dropped.count + live.underestimatedCount)
        var next = dropped.startIndex
        for turn in live {
            while next < dropped.endIndex, dropped[next].startedAt <= turn.startedAt {
                timeline.append((dropped[next], true))
                next += 1
            }
            timeline.append((turn, false))
        }
        timeline.append(contentsOf: dropped[next...].map { ($0, true) })
        return timeline
    }
}

/// Where a remote client's transcript stands, sent as
/// `/transcript?after=<epoch milliseconds>&copilotSessionId=<id>` so the host
/// returns only the turns that started at or after that point instead of the
/// whole transcript on every revision.
///
/// Clients keep the turns they already have and merge each response in by
/// turn id, so a host or gateway that ignores the cursor (and sends
/// everything) stays correct: the cursor only saves bandwidth. Clients derive
/// it from the start of their newest completed turn, rounded down to the
/// millisecond, so the host's comparison always includes that turn.
public struct TranscriptCursor: Equatable, Sendable {
    public static let afterQueryItem = "after"
    public static let copilotSessionIdQueryItem = "copilotSessionId"
    /// Matches the CLI writer's bound on transcript metadata text, which
    /// includes the snapshot's `copilotSessionId`.
    public static let maximumCopilotSessionIdBytes = 512

    public enum Parsed: Equatable, Sendable {
        /// Neither query item was sent: a full or windowed request.
        case absent
        case cursor(TranscriptCursor)
        /// Malformed, or only one of the two items was sent.
        case invalid
    }

    public let afterMilliseconds: Int64
    public let copilotSessionId: String

    public init?(afterMilliseconds: Int64, copilotSessionId: String) {
        guard afterMilliseconds >= 0,
              !copilotSessionId.isEmpty,
              copilotSessionId.utf8.count <= Self.maximumCopilotSessionIdBytes else {
            return nil
        }
        self.afterMilliseconds = afterMilliseconds
        self.copilotSessionId = copilotSessionId
    }

    /// The cursor for a turn that started at `startedAt`, rounded down so the
    /// host's `>=` comparison can never skip that turn.
    public init?(startedAt: Date, copilotSessionId: String) {
        let milliseconds = (startedAt.timeIntervalSince1970 * 1_000).rounded(.down)
        guard milliseconds.isFinite,
              milliseconds >= 0,
              milliseconds < Double(Int64.max) else {
            return nil
        }
        self.init(afterMilliseconds: Int64(milliseconds), copilotSessionId: copilotSessionId)
    }

    public var startedAt: Date {
        Date(timeIntervalSince1970: Double(afterMilliseconds) / 1_000)
    }

    /// Parses the raw (already percent-decoded) query values. Strict like the
    /// `limit` window: a malformed cursor is a client bug, not something to
    /// silently widen into a full response.
    public static func parse(after: String?, copilotSessionId: String?) -> Parsed {
        switch (after, copilotSessionId) {
        case (nil, nil):
            return .absent
        case let (after?, copilotSessionId?):
            guard !after.isEmpty,
                  after.utf8.count <= 16,
                  after.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let milliseconds = Int64(after),
                  let cursor = TranscriptCursor(
                      afterMilliseconds: milliseconds,
                      copilotSessionId: copilotSessionId
                  ) else {
                return .invalid
            }
            return .cursor(cursor)
        default:
            return .invalid
        }
    }
}

public struct TranscriptTurn: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let kind: String
    public let userContent: String
    public let assistantMessages: [TranscriptAssistantMessage]
    public let tools: [TranscriptTool]
    public let isAborted: Bool
    /// Inline Kitty images the host associated with this turn (the currently
    /// retained captures whose display time fell within this turn). Absent in
    /// the CLI-written snapshot and populated only by the host before serving
    /// remote clients; optional so older clients (and the CLI writer) ignore it.
    public let images: [TranscriptImageRef]?

    public init(
        id: String,
        startedAt: Date,
        endedAt: Date?,
        kind: String,
        userContent: String,
        assistantMessages: [TranscriptAssistantMessage],
        tools: [TranscriptTool],
        isAborted: Bool,
        images: [TranscriptImageRef]? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.kind = kind
        self.userContent = userContent
        self.assistantMessages = assistantMessages
        self.tools = tools
        self.isAborted = isAborted
        self.images = images
    }
}

/// A reference to one currently-retained inline Kitty image, as associated with
/// a transcript turn. Carries the exact `(imageId, contentVersion)` needed to
/// fetch the bytes via `RemoteTerminalImageContract.path`
/// (`/terminal-image?s=&i=&v=`). `contentVersionText` is the decimal string form
/// of `contentVersion` for JavaScript clients, which cannot represent the full
/// `UInt64` range exactly (it carries a random 32-bit epoch in its high bits);
/// mirrors `RemoteTerminalImagePlacement`'s own JS-safe version handling.
public struct TranscriptImageRef: Codable, Equatable, Sendable {
    public let imageId: UInt32
    public let contentVersion: UInt64
    public let contentVersionText: String

    public init(imageId: UInt32, contentVersion: UInt64) {
        self.imageId = imageId
        self.contentVersion = contentVersion
        self.contentVersionText = String(contentVersion)
    }
}

public struct TranscriptAssistantMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let timestamp: Date
    public let content: String

    public init(id: String, timestamp: Date, content: String) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
    }
}

public struct TranscriptTool: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let title: String
    public let success: Bool?

    public init(id: String, name: String, title: String, success: Bool?) {
        self.id = id
        self.name = name
        self.title = title
        self.success = success
    }
}

public struct RemoteTranscriptRevision: Codable, Equatable, Sendable {
    public let sessionId: String
    public let generation: String

    public init(sessionId: String, generation: String) {
        self.sessionId = sessionId
        self.generation = generation
    }
}
