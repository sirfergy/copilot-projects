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

    public init(
        schemaVersion: Int,
        updatedAt: Date,
        copilotSessionId: String,
        turns: [TranscriptTurn],
        totalTurns: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.copilotSessionId = copilotSessionId
        self.turns = turns
        self.totalTurns = totalTurns
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
    /// own `startedAt` were earlier. Whenever a cursor or limit applies,
    /// `totalTurns` reports the whole transcript, exactly as
    /// `limitedToMostRecentTurns` does; with neither, this is the unchanged
    /// legacy response.
    public func remoteWindow(limit: Int?, after cursor: TranscriptCursor?) -> TranscriptSnapshot {
        let applicableCursor = cursor.flatMap {
            $0.copilotSessionId == copilotSessionId ? $0 : nil
        }
        guard limit != nil || applicableCursor != nil else { return self }
        var selected = turns[...]
        if let applicableCursor {
            let start = applicableCursor.startedAt
            selected = turns.firstIndex { $0.startedAt >= start }
                .map { turns[$0...] } ?? []
        }
        if let limit {
            selected = selected.suffix(max(0, limit))
        }
        return TranscriptSnapshot(
            schemaVersion: schemaVersion,
            updatedAt: updatedAt,
            copilotSessionId: copilotSessionId,
            turns: Array(selected),
            totalTurns: turns.count
        )
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
