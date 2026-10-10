import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore
import CopilotProjectsProtocol
/// Host-owned transcript windows preserve image association and legacy JSON.
final class RemoteTranscriptOptimizationTests: XCTestCase {

    // MARK: - Fixtures

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixtureTurn(index: Int) -> TranscriptTurn {
        TranscriptTurn(
            id: "turn-\(index)",
            startedAt: Self.epoch.addingTimeInterval(Double(index) * 100),
            endedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 50),
            kind: "foreground",
            userContent: "ask \(index)",
            assistantMessages: [
                TranscriptAssistantMessage(
                    id: "message-\(index)",
                    timestamp: Self.epoch.addingTimeInterval(Double(index) * 100 + 10),
                    content: "reply \(index)"
                )
            ],
            tools: [],
            isAborted: false
        )
    }

    private func fixtureSnapshot(turnCount: Int) -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Self.epoch,
            copilotSessionId: "copilot-session",
            turns: (0..<turnCount).map(fixtureTurn(index:))
        )
    }

    /// One retained image per turn index, displayed just after that turn began.
    private func fixtureImages(forTurnIndexes indexes: [Int]) -> [RemoteKittyImageCapture.RetainedImageInfo] {
        indexes.map { index in
            RemoteKittyImageCapture.RetainedImageInfo(
                imageId: UInt32(index + 1),
                version: UInt64(index + 1) << 32 | 7,
                displayedAt: Self.epoch.addingTimeInterval(Double(index) * 100 + 5)
            )
        }
    }

    private func decode(_ data: Data) throws -> TranscriptSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TranscriptSnapshot.self, from: data)
    }

    // MARK: - Response payload

    func testTranscriptResponseAppliesWindowAfterImageAssociation() throws {
        let snapshot = fixtureSnapshot(turnCount: 6)
        // Images displayed during turns 1 and 4 — one inside the window a
        // `limit=2` response returns, one only in the dropped prefix.
        let images = fixtureImages(forTurnIndexes: [1, 4])

        let fullData = try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil
        ))
        let full = try decode(fullData)
        // The legacy shape is preserved byte-for-byte: no window, no metadata.
        XCTAssertNil(full.totalTurns)
        XCTAssertFalse(
            String(decoding: fullData, as: UTF8.self).contains("totalTurns"),
            "an unlimited response must not carry window metadata"
        )
        XCTAssertEqual(full.turns.count, 6)
        XCTAssertEqual(full.turns[1].images?.map(\.imageId), [2])
        XCTAssertEqual(full.turns[4].images?.map(\.imageId), [5])

        let limited = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: 2
        )))
        XCTAssertEqual(limited.totalTurns, 6)
        XCTAssertEqual(limited.turns.map(\.id), ["turn-4", "turn-5"])
        // Association ran against the full transcript, so a windowed turn's
        // images are exactly the ones the unlimited response reports…
        XCTAssertEqual(limited.turns[0].images, full.turns[4].images)
        XCTAssertEqual(limited.turns[1].images, full.turns[5].images)
        // …and the image displayed during a dropped turn is not re-anchored onto
        // whatever turn happens to be oldest in the window.
        let windowedImageIds = limited.turns.flatMap { $0.images?.map(\.imageId) ?? [] }
        XCTAssertEqual(windowedImageIds, [5])

        // Every window agrees with the unlimited response, turn for turn.
        for limit in 1...6 {
            let windowed = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
                snapshot: snapshot, images: images, limit: limit
            )))
            XCTAssertEqual(windowed.turns.count, limit)
            XCTAssertEqual(windowed.totalTurns, 6)
            for turn in windowed.turns {
                let original = try XCTUnwrap(full.turns.first { $0.id == turn.id })
                XCTAssertEqual(turn, original)
            }
        }

        // A window wider than the transcript returns everything, still tagged so
        // the client can tell "this is all of it" from "the host ignored me".
        let wide = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: 200
        )))
        XCTAssertEqual(wide.turns.map(\.id), full.turns.map(\.id))
        XCTAssertEqual(wide.totalTurns, 6)

        // The pure slice keeps the legacy default when constructed directly.
        XCTAssertNil(fixtureSnapshot(turnCount: 3).totalTurns)
        XCTAssertEqual(fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).totalTurns, 3)
        XCTAssertEqual(
            fixtureSnapshot(turnCount: 3).limitedToMostRecentTurns(1).turns.map(\.id),
            ["turn-2"]
        )
    }

    // MARK: - Incremental cursor

    private func cursor(
        at date: Date,
        copilotSessionId: String = "copilot-session"
    ) throws -> TranscriptCursor {
        try XCTUnwrap(TranscriptCursor(startedAt: date, copilotSessionId: copilotSessionId))
    }

    func testTranscriptResponseReturnsTurnsFromTheCursorWithFullCount() throws {
        let snapshot = fixtureSnapshot(turnCount: 6)
        let images = fixtureImages(forTurnIndexes: [1, 4])
        let full = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil
        )))

        let delta = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil,
            after: try cursor(at: snapshot.turns[3].startedAt)
        )))
        // The cursor's own turn is resent (it may still be changing) with
        // everything after it, tagged with the whole transcript's size.
        XCTAssertEqual(delta.turns.map(\.id), ["turn-3", "turn-4", "turn-5"])
        XCTAssertEqual(delta.totalTurns, 6)
        // Images were associated against the full transcript first.
        for turn in delta.turns {
            XCTAssertEqual(turn, try XCTUnwrap(full.turns.first { $0.id == turn.id }))
        }

        // A cursor whose turn the host has since evicted still lands on the
        // next turn that started after it.
        let evicted = snapshot.turns[3].startedAt.addingTimeInterval(-1)
        let afterEviction = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: snapshot.updatedAt,
            copilotSessionId: snapshot.copilotSessionId,
            turns: snapshot.turns.filter { $0.id != "turn-3" }
        ).remoteWindow(limit: nil, after: try cursor(at: evicted))
        XCTAssertEqual(afterEviction.turns.map(\.id), ["turn-4", "turn-5"])
        XCTAssertEqual(afterEviction.totalTurns, 5)

        // Past the newest turn, nothing is new — but the response is still
        // tagged, so "nothing new" is distinguishable from "no transcript".
        let caughtUp = snapshot.remoteWindow(
            limit: nil,
            after: try cursor(at: snapshot.turns[5].startedAt.addingTimeInterval(1))
        )
        XCTAssertEqual(caughtUp.turns, [])
        XCTAssertEqual(caughtUp.totalTurns, 6)
    }

    func testTranscriptCursorSurvivesTheWiresWholeSecondDates() throws {
        // The CLI writes millisecond timestamps, but `/transcript` encodes dates
        // with `.iso8601`, so clients only ever see whole seconds. A cursor built
        // from that truncated date must still include the turn it came from.
        let precise = Self.epoch.addingTimeInterval(300.293)
        let turn = TranscriptTurn(
            id: "precise", startedAt: precise, endedAt: precise, kind: "scheduled",
            userContent: "", assistantMessages: [], tools: [], isAborted: false
        )
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Self.epoch, copilotSessionId: "copilot-session",
            turns: fixtureSnapshot(turnCount: 3).turns + [turn]
        )
        let wire = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: [], limit: nil
        )))
        let truncated = try XCTUnwrap(wire.turns.last).startedAt
        XCTAssertLessThan(truncated, precise)

        let delta = snapshot.remoteWindow(limit: nil, after: try cursor(at: truncated))
        XCTAssertEqual(delta.turns.map(\.id), ["precise"])
        // Rounding down also covers a fractional date that isn't exactly
        // representable in binary.
        XCTAssertEqual(
            snapshot.remoteWindow(limit: nil, after: try cursor(at: precise)).turns.map(\.id),
            ["precise"]
        )
    }

    func testTranscriptCursorIsASuffixThenAWindow() throws {
        let snapshot = fixtureSnapshot(turnCount: 6)
        let fromTurnOne = try cursor(at: snapshot.turns[1].startedAt)

        let windowed = snapshot.remoteWindow(limit: 2, after: fromTurnOne)
        XCTAssertEqual(windowed.turns.map(\.id), ["turn-4", "turn-5"])
        // The window doesn't replace the whole-transcript count with the
        // suffix's size.
        XCTAssertEqual(windowed.totalTurns, 6)

        // A turn positioned after the match is returned even if its own start
        // were earlier: positions, not timestamps, define "after".
        var turns = snapshot.turns
        let late = turns.remove(at: 0)
        turns.append(late)
        let reordered = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Self.epoch, copilotSessionId: "copilot-session",
            turns: turns
        ).remoteWindow(limit: nil, after: try cursor(at: snapshot.turns[4].startedAt))
        XCTAssertEqual(reordered.turns.map(\.id), ["turn-4", "turn-5", "turn-0"])
    }

    func testTranscriptCursorForAnotherConversationGetsTheUsualResponse() throws {
        let snapshot = fixtureSnapshot(turnCount: 4)
        // After `/new` or `/resume` (even of an older conversation whose turns
        // all predate the cursor) the client needs everything.
        let other = try cursor(at: snapshot.turns[3].startedAt, copilotSessionId: "previous")
        let fullData = try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: [], limit: nil, after: other
        ))
        XCTAssertEqual(try decode(fullData).turns.map(\.id), snapshot.turns.map(\.id))
        XCTAssertFalse(String(decoding: fullData, as: UTF8.self).contains("totalTurns"))
        XCTAssertEqual(try decode(fullData), try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: [], limit: nil
        ))))
        // With a window, it's the usual window.
        XCTAssertEqual(
            snapshot.remoteWindow(limit: 2, after: other),
            snapshot.limitedToMostRecentTurns(2)
        )

        // An unreadable transcript is served as an empty snapshot with no
        // conversation id; a cursor never matches it.
        let unavailable = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Self.epoch, copilotSessionId: "", turns: []
        )
        XCTAssertEqual(
            unavailable.remoteWindow(limit: nil, after: try cursor(at: Self.epoch)),
            unavailable
        )
    }

    func testTranscriptCursorQueryParsingIsStrict() throws {
        XCTAssertEqual(TranscriptCursor.parse(after: nil, copilotSessionId: nil), .absent)
        XCTAssertEqual(
            TranscriptCursor.parse(after: "1700000000293", copilotSessionId: "abc"),
            .cursor(try XCTUnwrap(TranscriptCursor(afterMilliseconds: 1_700_000_000_293, copilotSessionId: "abc")))
        )
        XCTAssertEqual(
            TranscriptCursor.parse(after: "0", copilotSessionId: "abc"),
            .cursor(try XCTUnwrap(TranscriptCursor(afterMilliseconds: 0, copilotSessionId: "abc")))
        )
        XCTAssertEqual(
            TranscriptCursor.parse(after: "9999999999999999", copilotSessionId: "abc"),
            .cursor(try XCTUnwrap(TranscriptCursor(afterMilliseconds: 9_999_999_999_999_999, copilotSessionId: "abc")))
        )
        let longest = String(repeating: "s", count: TranscriptCursor.maximumCopilotSessionIdBytes)
        XCTAssertNotEqual(TranscriptCursor.parse(after: "1", copilotSessionId: longest), .invalid)

        let invalid: [(String?, String?)] = [
            ("1", nil),
            (nil, "abc"),
            ("", "abc"),
            ("1", ""),
            ("-1", "abc"),
            ("+1", "abc"),
            ("1.5", "abc"),
            ("1e3", "abc"),
            (" 1", "abc"),
            ("١٢", "abc"),
            ("10000000000000000", "abc"),
            ("1", longest + "s"),
        ]
        for (after, copilotSessionId) in invalid {
            XCTAssertEqual(
                TranscriptCursor.parse(after: after, copilotSessionId: copilotSessionId),
                .invalid,
                "after=\(after ?? "nil") copilotSessionId=\(copilotSessionId ?? "nil")"
            )
        }
        XCTAssertNil(TranscriptCursor(startedAt: Date(timeIntervalSince1970: -1), copilotSessionId: "abc"))
    }

    // MARK: - Recently dropped turns

    /// Live turns 0, 2, 4, 6 and 7; the writer evicted 1, 3 and 5 (recorded in
    /// eviction order, not start order), plus a stale copy of live turn 4 and a
    /// turn that started at exactly the same moment as turn 4.
    private func snapshotWithDroppedTurns() -> TranscriptSnapshot {
        let all = fixtureSnapshot(turnCount: 8).turns
        let staleCopy = TranscriptTurn(
            id: "turn-4", startedAt: all[4].startedAt, endedAt: nil, kind: "foreground",
            userContent: "stale", assistantMessages: [], tools: [], isAborted: false
        )
        let tie = TranscriptTurn(
            id: "tie", startedAt: all[4].startedAt, endedAt: all[4].startedAt, kind: "scheduled",
            userContent: "", assistantMessages: [], tools: [], isAborted: false
        )
        return TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Self.epoch,
            copilotSessionId: "copilot-session",
            turns: [all[0], all[2], all[4], all[6], all[7]],
            droppedTurns: [all[5], all[1], staleCopy, all[3], tie]
        )
    }

    func testCursorResponseRecoversDroppedTurnsAtOrAfterTheCursor() throws {
        let snapshot = snapshotWithDroppedTurns()
        let all = fixtureSnapshot(turnCount: 8).turns
        let fromTurnThree = try cursor(at: all[3].startedAt)

        let delta = snapshot.remoteWindow(limit: nil, after: fromTurnThree)
        // Dropped turns at or after the cursor are woven in by start time — a
        // dropped turn ahead of a live one it ties with — and turn 1, older
        // than the cursor, stays out.
        XCTAssertEqual(
            delta.turns.map(\.id),
            ["turn-3", "tie", "turn-4", "turn-5", "turn-6", "turn-7"]
        )
        // The live copy of a turn wins over a dropped one with the same id.
        XCTAssertEqual(delta.turns.first { $0.id == "turn-4" }, all[4])
        // The count still describes the live transcript.
        XCTAssertEqual(delta.totalTurns, 5)
        XCTAssertNil(delta.droppedTurns)

        // The limit applies after the merge.
        XCTAssertEqual(
            snapshot.remoteWindow(limit: 3, after: fromTurnThree).turns.map(\.id),
            ["turn-5", "turn-6", "turn-7"]
        )
        XCTAssertEqual(
            snapshot.remoteWindow(limit: 0, after: fromTurnThree).turns,
            []
        )

        // Past every dropped turn, only live turns remain.
        XCTAssertEqual(
            snapshot.remoteWindow(limit: nil, after: try cursor(at: all[6].startedAt)).turns.map(\.id),
            ["turn-6", "turn-7"]
        )

        // A response is never padded with dropped turns without a cursor, and
        // nothing older than the cursor sneaks in through the buffer.
        XCTAssertEqual(snapshot.remoteWindow(limit: 2, after: nil).turns.map(\.id), ["turn-6", "turn-7"])
        XCTAssertEqual(
            snapshot.remoteWindow(limit: nil, after: try cursor(at: all[0].startedAt)).turns.map(\.id),
            ["turn-0", "turn-1", "turn-2", "turn-3", "tie", "turn-4", "turn-5", "turn-6", "turn-7"]
        )
    }

    func testDroppedTurnsNeverLeaveTheHost() throws {
        let snapshot = snapshotWithDroppedTurns()
        let all = fixtureSnapshot(turnCount: 8).turns
        let fromTurnThree = try cursor(at: all[3].startedAt)
        let otherConversation = try cursor(at: all[3].startedAt, copilotSessionId: "previous")
        let requests: [(String, Int?, TranscriptCursor?)] = [
            ("legacy", nil, nil),
            ("window", 2, nil),
            ("cursor", nil, fromTurnThree),
            ("cursor and window", 2, fromTurnThree),
            ("another conversation", nil, otherConversation),
        ]
        for (name, limit, after) in requests {
            XCTAssertNil(snapshot.remoteWindow(limit: limit, after: after).droppedTurns, name)
            let data = try XCTUnwrap(TranscriptResponse.encodedResponse(
                snapshot: snapshot,
                images: fixtureImages(forTurnIndexes: [5]),
                limit: limit,
                after: after
            ), name)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("droppedTurns"), name)
        }

        // Without a cursor or window the response is otherwise the unchanged
        // legacy shape: the live turns, no window metadata.
        let legacy = snapshot.remoteWindow(limit: nil, after: nil)
        XCTAssertEqual(legacy.turns, snapshot.turns)
        XCTAssertNil(legacy.totalTurns)
        XCTAssertEqual(
            legacy,
            TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Self.epoch, copilotSessionId: "copilot-session",
                turns: snapshot.turns
            )
        )
    }

    func testDroppedTurnsKeepTheImagesDisplayedDuringThem() throws {
        let all = fixtureSnapshot(turnCount: 8).turns
        let forged = TranscriptTurn(
            id: "turn-1", startedAt: all[1].startedAt, endedAt: all[1].endedAt, kind: "foreground",
            userContent: "ask 1", assistantMessages: all[1].assistantMessages, tools: [],
            isAborted: false, images: [TranscriptImageRef(imageId: 99, contentVersion: 1)]
        )
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Self.epoch, copilotSessionId: "copilot-session",
            turns: [all[0], all[2], all[4], all[6], all[7]],
            droppedTurns: [all[5], forged, all[3]]
        )
        // Images displayed during live turn 4 and dropped turn 5.
        let images = fixtureImages(forTurnIndexes: [4, 5])

        let attached = TranscriptImageAssociation.attach(images: images, to: snapshot)
        XCTAssertEqual(attached.turns.map(\.id), snapshot.turns.map(\.id))
        XCTAssertEqual(attached.droppedTurns?.map(\.id), ["turn-1", "turn-3", "turn-5"])
        // The writer's own refs are never trusted, on dropped turns either.
        XCTAssertNil(attached.droppedTurns?.first?.images)

        let delta = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil,
            after: try cursor(at: all[3].startedAt)
        )))
        XCTAssertEqual(delta.turns.map(\.id), ["turn-3", "turn-4", "turn-5", "turn-6", "turn-7"])
        let refs = Dictionary(uniqueKeysWithValues: delta.turns.map { ($0.id, $0.images?.map(\.imageId)) })
        XCTAssertEqual(refs["turn-4"], [5])
        XCTAssertEqual(refs["turn-5"], [6])

        // A response without the dropped turn doesn't re-anchor its image onto
        // the live turn before it.
        let legacy = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            snapshot: snapshot, images: images, limit: nil
        )))
        XCTAssertEqual(legacy.turns.flatMap { $0.images?.map(\.imageId) ?? [] }, [5])
    }

    // MARK: - Reads that race a rewrite

    private func writeTranscript(_ data: Data, sessionId: String) throws {
        try data.write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
    }

    private func encoded(_ snapshot: TranscriptSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    /// Clients treat a response with no conversation id as authoritative and
    /// clear what they have, so an empty read caused only by the tracker
    /// rewriting the transcript mid-read must be retried.
    func testRemoteSnapshotRetriesAnEmptyReadThatRacedARewrite() throws {
        Paths.ensureStateDir()
        let published = fixtureSnapshot(turnCount: 3)
        let scenarios: [(String, Data)] = [
            // The bytes read are the previous, valid snapshot, but the files
            // moved before they were validated.
            ("stale", try encoded(fixtureSnapshot(turnCount: 2))),
            // The bytes read do not decode at all.
            ("torn", Data(#"{"schemaVersion":3,"#.utf8)),
        ]
        for (name, initial) in scenarios {
            let sessionId = UUID().uuidString
            defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
            try writeTranscript(initial, sessionId: sessionId)

            var attempts: [Int] = []
            let loaded = TranscriptController.loadRemoteSnapshot(sessionId: sessionId) { attempt in
                attempts.append(attempt)
                if attempt == 1 {
                    try? self.writeTranscript(try self.encoded(published), sessionId: sessionId)
                }
            }
            XCTAssertEqual(attempts, [1, 2], name)
            XCTAssertEqual(loaded, published, name)
        }
    }

    func testRemoteSnapshotReturnsAStableEmptyReadAtOnce() throws {
        Paths.ensureStateDir()
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }

        // The endpoint answers a settled "no transcript" with the authoritative
        // empty snapshot.
        let served = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            sessionId: sessionId, images: [], limit: nil, after: nil
        )))
        XCTAssertEqual(served.copilotSessionId, "")
        XCTAssertEqual(served.turns, [])

        // No transcript at all: nothing to read, nothing to retry.
        var attempts: [Int] = []
        let missing = TranscriptController.loadRemoteSnapshot(sessionId: sessionId) {
            attempts.append($0)
        }
        XCTAssertEqual(attempts, [])
        XCTAssertEqual(missing.copilotSessionId, "")
        XCTAssertEqual(missing.turns, [])

        // An unreadable transcript that nobody is rewriting is read once.
        try writeTranscript(Data("not json".utf8), sessionId: sessionId)
        let unreadable = TranscriptController.loadRemoteSnapshot(sessionId: sessionId) {
            attempts.append($0)
        }
        XCTAssertEqual(attempts, [1])
        XCTAssertEqual(unreadable.copilotSessionId, "")
        XCTAssertEqual(unreadable.turns, [])
    }

    /// When every read raced another rewrite, the answer is unknown rather than
    /// "no transcript": the endpoint fails (the gateway answers with an error
    /// status) so clients keep their history, while local readers still get
    /// the empty snapshot.
    func testRemoteSnapshotThatNeverSettlesIsATransientFailure() throws {
        Paths.ensureStateDir()
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        try writeTranscript(Data("torn".utf8), sessionId: sessionId)

        var attempts: [Int] = []
        var rewrites = 0
        // Every read races yet another torn rewrite.
        let racingRewrite: (Int) -> Void = { attempt in
            attempts.append(attempt)
            rewrites += 1
            try? self.writeTranscript(
                Data(("torn" + String(repeating: "!", count: rewrites)).utf8),
                sessionId: sessionId
            )
        }

        XCTAssertEqual(TranscriptController.maximumRemoteSnapshotReadAttempts, 3)
        XCTAssertNil(TranscriptController.loadRemoteSnapshotIfSettled(
            sessionId: sessionId, duringRead: racingRewrite
        ))
        XCTAssertEqual(attempts, [1, 2, 3])

        attempts = []
        XCTAssertNil(TranscriptResponse.encodedResponse(
            sessionId: sessionId, images: [], limit: nil, after: nil, duringRead: racingRewrite
        ))
        XCTAssertEqual(attempts, [1, 2, 3])

        attempts = []
        let local = TranscriptController.loadRemoteSnapshot(sessionId: sessionId, duringRead: racingRewrite)
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(local.copilotSessionId, "")
        XCTAssertEqual(local.turns, [])

        // A race that settles by the last read is served normally.
        let published = fixtureSnapshot(turnCount: 2)
        attempts = []
        let settled = try decode(try XCTUnwrap(TranscriptResponse.encodedResponse(
            sessionId: sessionId, images: [], limit: nil, after: nil
        ) { attempt in
            attempts.append(attempt)
            if attempt == 1 {
                try? self.writeTranscript(Data("torn again".utf8), sessionId: sessionId)
            } else if attempt == 2 {
                try? self.writeTranscript(try self.encoded(published), sessionId: sessionId)
            }
        }))
        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertEqual(settled, published)
    }

}
