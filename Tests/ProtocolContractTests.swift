import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsProtocolFixtures
@testable import CopilotProjectsHost

final class ProtocolContractTests: XCTestCase {
    private func workspace(_ fixture: String) throws -> RemoteWorkspaceSnapshot {
        try JSONDecoder().decode(
            RemoteWorkspaceSnapshot.self,
            from: ProtocolFixtures.data(named: fixture)
        )
    }

    private func session(_ id: String, models: [RemoteAvailableModel]?) -> RemoteSessionSnapshot {
        RemoteSessionSnapshot(
            id: id, title: "Session \(id)", status: "idle", statusText: nil,
            unread: false, ready: true, background: false, scheduled: false,
            promptable: true,
            model: RemoteModelInfo(name: "Model \(id)", reasoningEffort: "high"),
            availableModels: models,
            conversationEpoch: "epoch-\(id)",
            operationSupport: .receipts,
            operationReceipts: []
        )
    }

    private func catalogWorkspace(stamp: Int64? = 1_700_000_000_000) -> RemoteWorkspaceSnapshot {
        let catalog = [
            RemoteAvailableModel(id: "auto", name: "Auto"),
            RemoteAvailableModel(
                id: "gpt", name: "GPT", supportedReasoningEfforts: ["low", "high"],
                defaultReasoningEffort: "high", category: "powerful"
            ),
        ]
        return RemoteWorkspaceSnapshot(
            projects: [
                RemoteProjectSnapshot(
                    id: "p1", name: "One", selectedSessionId: "a",
                    sessions: [session("a", models: catalog), session("b", models: catalog)]
                ),
                RemoteProjectSnapshot(
                    id: "p2", name: "Two", selectedSessionId: nil,
                    sessions: [session("c", models: Array(catalog.prefix(1))), session("d", models: nil)]
                ),
            ],
            selectedProjectId: "p1",
            protocolInfo: .current,
            servedAtMilliseconds: stamp
        )
    }

    func testKeepingAvailableModelsKeepsOnlyTheStreamedSessionsCatalog() {
        let full = catalogWorkspace()
        let kept = full.keepingAvailableModels(for: "c")
        let expected = RemoteWorkspaceSnapshot(
            projects: [
                RemoteProjectSnapshot(
                    id: "p1", name: "One", selectedSessionId: "a",
                    sessions: [session("a", models: nil), session("b", models: nil)]
                ),
                RemoteProjectSnapshot(
                    id: "p2", name: "Two", selectedSessionId: nil,
                    sessions: [
                        session("c", models: full.projects[1].sessions[0].availableModels),
                        session("d", models: nil),
                    ]
                ),
            ],
            selectedProjectId: "p1",
            protocolInfo: .current,
            servedAtMilliseconds: full.servedAtMilliseconds
        )
        XCTAssertEqual(kept, expected)
        XCTAssertEqual(kept.projects[1].sessions[0].availableModels?.map(\.id), ["auto"])
    }

    func testKeepingAvailableModelsWithoutAKnownSessionKeepsNone() {
        let full = catalogWorkspace(stamp: nil)
        for sessionId in [nil, "missing"] {
            let kept = full.keepingAvailableModels(for: sessionId)
            XCTAssertTrue(kept.projects.flatMap(\.sessions).allSatisfy { $0.availableModels == nil })
            XCTAssertEqual(kept.projects.flatMap(\.sessions).map(\.id), ["a", "b", "c", "d"])
            XCTAssertEqual(kept.projects.flatMap(\.sessions).map(\.model), full.projects.flatMap(\.sessions).map(\.model))
            XCTAssertNil(kept.servedAtMilliseconds)
        }
    }

    func testKeptCatalogEncodesOnlyOnceAndOmitsTheOthers() throws {
        let kept = catalogWorkspace().keepingAvailableModels(for: "b")
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(kept), encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: "\"availableModels\"").count - 1, 1)
        let decoded = try JSONDecoder().decode(RemoteWorkspaceSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, kept)
    }

    func testLegacyWorkspaceRetainsItsAbsentFieldsAndBehavior() throws {
        let snapshot = try workspace("legacy-workspace")
        let session = try XCTUnwrap(snapshot.projects.first?.sessions.first)
        XCTAssertNil(snapshot.protocolInfo)
        XCTAssertNil(session.conversationEpoch)
        XCTAssertNil(session.operationReceipts)
        XCTAssertEqual(session.negotiatedOperationSupport(protocolInfo: nil), .legacy)
        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        XCTAssertNil(encoded["protocolInfo"])
    }

    func testReceiptWorkspaceRoundTripsAllOutcomes() throws {
        let snapshot = try workspace("receipt-workspace")
        let session = try XCTUnwrap(snapshot.projects.first?.sessions.first)
        XCTAssertEqual(session.negotiatedOperationSupport(protocolInfo: snapshot.protocolInfo), .receipts)
        XCTAssertEqual(session.operationReceipts?.map(\.state), [.accepted, .applied, .rejected, .indeterminate])
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)),
            snapshot
        )
        XCTAssertEqual(session.negotiatedOperationSupport(protocolInfo: nil), .unavailable)
    }

    func testConfiguredCreationRequiresExplicitCapability() throws {
        XCTAssertNil(try workspace("legacy-workspace").protocolInfo)
        XCTAssertFalse(try XCTUnwrap(workspace("receipt-workspace").protocolInfo)
            .supports(RemoteProtocolInfo.configuredSessionCreation))
        XCTAssertEqual(RemoteProtocolInfo.configuredSessionCreation, "configured-session-creation")
        XCTAssertTrue(RemoteProtocolInfo.current.supports(RemoteProtocolInfo.configuredSessionCreation))
        let decoded = try JSONDecoder().decode(
            RemoteProtocolInfo.self, from: JSONEncoder().encode(RemoteProtocolInfo.current))
        XCTAssertTrue(decoded.supports(RemoteProtocolInfo.configuredSessionCreation))
    }

    func testUnavailableAndUnknownSupportNeverDowngradeToLegacy() throws {
        let unavailable = try workspace("unavailable-workspace")
        let session = try XCTUnwrap(unavailable.projects.first?.sessions.first)
        XCTAssertEqual(session.negotiatedOperationSupport(protocolInfo: unavailable.protocolInfo), .unavailable)
        let legacy = try XCTUnwrap(workspace("legacy-workspace").projects.first?.sessions.first)
        XCTAssertEqual(legacy.negotiatedOperationSupport(protocolInfo: .current), .unavailable)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteOperationSupport.self, from: Data("\"future-mode\"".utf8)),
            .unavailable
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteOperationState.self, from: Data("\"future-state\"".utf8)),
            .indeterminate
        )
    }

    func testImageVersionHasAnExactCrossLanguageString() throws {
        let placement = try JSONDecoder().decode(
            RemoteTerminalImagePlacement.self,
            from: ProtocolFixtures.data(named: "image-version")
        )
        XCTAssertEqual(placement.contentVersion, UInt64.max - 1)
        XCTAssertEqual(placement.contentVersionText, String(placement.contentVersion))
    }

    // MARK: - Workspace serve time and workflow freshness

    func testServedWorkspaceCarriesItsServeTimeThroughARoundTrip() throws {
        let snapshot = try workspace("served-workspace")
        XCTAssertEqual(snapshot.servedAtMilliseconds, 1_787_788_802_500)
        let workflow = try XCTUnwrap(snapshot.projects.first?.sessions.first?.workflow)
        XCTAssertEqual(workflow.observedAtMilliseconds, 1_787_788_800_000)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)),
            snapshot
        )
        XCTAssertEqual(try jsonObject(snapshot)["servedAtMilliseconds"] as? Int64, 1_787_788_802_500)

        // A client built before the field existed decodes the same payload.
        struct OlderWorkspace: Decodable {
            let projects: [RemoteProjectSnapshot]
            let selectedProjectId: String?
            let protocolInfo: RemoteProtocolInfo?
        }
        let older = try JSONDecoder().decode(
            OlderWorkspace.self, from: ProtocolFixtures.data(named: "served-workspace")
        )
        XCTAssertEqual(older.projects, snapshot.projects)
        XCTAssertEqual(older.selectedProjectId, "project")
    }

    func testWorkspacesWithoutServeTimeDecodeAndEncodeWithoutIt() throws {
        for fixture in ["legacy-workspace", "receipt-workspace", "unavailable-workspace"] {
            let snapshot = try workspace(fixture)
            XCTAssertNil(snapshot.servedAtMilliseconds, fixture)
            XCTAssertFalse(try jsonObject(snapshot).keys.contains("servedAtMilliseconds"), fixture)
        }
        let unserved = RemoteWorkspaceSnapshot(projects: [], selectedProjectId: nil)
        XCTAssertNil(unserved.servedAtMilliseconds)
        XCTAssertFalse(try jsonObject(unserved).keys.contains("servedAtMilliseconds"))
        var served = unserved
        served.servedAtMilliseconds = 42
        XCTAssertEqual(
            served,
            RemoteWorkspaceSnapshot(projects: [], selectedProjectId: nil, servedAtMilliseconds: 42)
        )
        XCTAssertNotEqual(served, unserved)
    }

    private struct FreshnessCases: Decodable {
        struct Case: Decodable {
            let name: String
            let version: Int
            let observedAtMilliseconds: Int64
            let servedAtMilliseconds: Int64?
            let elapsedSinceReceiptMilliseconds: Int64
            let clientNowMilliseconds: Int64
            let expectedAgeMilliseconds: Double?
            let expectedFresh: Bool
        }
        let freshnessLimitMilliseconds: Int64
        let servedClockToleranceMilliseconds: Int64
        let cases: [Case]
    }

    func testWorkflowFreshnessMatchesTheSharedCases() throws {
        let fixture = try JSONDecoder().decode(
            FreshnessCases.self, from: ProtocolFixtures.data(named: "workflow-freshness-cases")
        )
        XCTAssertEqual(fixture.freshnessLimitMilliseconds, RemoteSessionWorkflow.freshnessLimitMilliseconds)
        XCTAssertEqual(
            fixture.servedClockToleranceMilliseconds,
            RemoteSessionWorkflow.servedClockToleranceMilliseconds
        )
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 20)
        let receivedAt = ContinuousClock.now
        for entry in fixture.cases {
            let workflow = RemoteSessionWorkflow(
                version: entry.version,
                observedAtMilliseconds: entry.observedAtMilliseconds,
                capabilities: [RemoteSessionActionKind.send.rawValue],
                sendReady: true
            )
            let now = receivedAt.advanced(by: .milliseconds(entry.elapsedSinceReceiptMilliseconds))
            let clientNow = Date(timeIntervalSince1970: Double(entry.clientNowMilliseconds) / 1_000)
            let age = workflow.ageMilliseconds(
                servedAtMilliseconds: entry.servedAtMilliseconds,
                receivedAt: receivedAt, now: now, at: clientNow
            )
            if let expected = entry.expectedAgeMilliseconds {
                // Only the wall-clock fallback goes through `Date`'s seconds.
                XCTAssertEqual(try XCTUnwrap(age, entry.name), expected, accuracy: 0.01, entry.name)
            } else {
                XCTAssertNil(age, entry.name)
            }
            let fresh = workflow.isFresh(
                servedAtMilliseconds: entry.servedAtMilliseconds,
                receivedAt: receivedAt, now: now, at: clientNow
            )
            XCTAssertEqual(fresh, entry.expectedFresh, entry.name)
            XCTAssertEqual(
                workflow.supports(
                    .send, servedAtMilliseconds: entry.servedAtMilliseconds,
                    receivedAt: receivedAt, now: now, at: clientNow
                ),
                entry.expectedFresh,
                entry.name
            )
            XCTAssertFalse(workflow.supports(
                .abort, servedAtMilliseconds: entry.servedAtMilliseconds,
                receivedAt: receivedAt, now: now, at: clientNow
            ), entry.name)
            if entry.servedAtMilliseconds == nil {
                XCTAssertEqual(fresh, workflow.isFresh(at: clientNow), "\(entry.name): fallback")
            }
        }
    }

    func testWindowedTranscriptKeepsEmptyImageSnapshotAndTotalCount() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            TranscriptSnapshot.self,
            from: ProtocolFixtures.data(named: "windowed-transcript")
        )
        XCTAssertEqual(snapshot.totalTurns, 4)
        XCTAssertEqual(snapshot.turns.count, 1)
        XCTAssertEqual(snapshot.turns[0].images, [])
        // Snapshots from before the dropped-turn buffer decode without one.
        XCTAssertNil(snapshot.droppedTurns)
    }

    func testTranscriptDroppedTurnsAreOptionalAndNeverBreakTheTranscript() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let turn = TranscriptTurn(
            id: "turn-1", startedAt: Date(timeIntervalSince1970: 1_700_000_000), endedAt: nil,
            kind: "foreground", userContent: "Example", assistantMessages: [], tools: [],
            isAborted: false
        )
        let plain = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            copilotSessionId: "conversation", turns: [turn]
        )
        XCTAssertNil(plain.droppedTurns)
        let plainObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(plain)) as? [String: Any]
        )
        XCTAssertNil(plainObject["droppedTurns"], "a nil buffer omits the key")

        let buffered = TranscriptSnapshot(
            schemaVersion: 3, updatedAt: plain.updatedAt, copilotSessionId: "conversation",
            turns: [], droppedTurns: [turn]
        )
        XCTAssertEqual(try decoder.decode(TranscriptSnapshot.self, from: encoder.encode(buffered)), buffered)

        // A malformed buffer costs only the buffer, never the transcript.
        let malformed = try decoder.decode(TranscriptSnapshot.self, from: Data("""
        {
          "schemaVersion": 3,
          "updatedAt": "2026-08-27T00:00:00Z",
          "copilotSessionId": "conversation",
          "turns": [{
            "id": "turn-1", "startedAt": "2026-08-27T00:00:00Z",
            "kind": "foreground", "userContent": "Example",
            "assistantMessages": [], "tools": [], "isAborted": false
          }],
          "droppedTurns": [{ "id": 1 }]
        }
        """.utf8))
        XCTAssertEqual(malformed.turns.map(\.id), ["turn-1"])
        XCTAssertNil(malformed.droppedTurns)
    }

    func testLegacyControlOmitsEpochAndNewControlKeepsOperationIdentitySeparate() throws {
        let legacy = RemoteClientMessage(type: "answer-user-input", sessionId: "tab", data: "{}")
        let legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        XCTAssertNil(legacyObject["conversationEpoch"])
        XCTAssertNil(legacyObject["requestId"])
        let modern = RemoteClientMessage(
            type: "answer-user-input", sessionId: "tab", requestId: "operation",
            data: "{\"requestId\":\"question\"}", conversationEpoch: "epoch"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteClientMessage.self, from: JSONEncoder().encode(modern)),
            modern
        )
    }

    // MARK: - Session search

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testMarkUnreadContractIsNotAdvertisedByTheHostProtocol() throws {
        XCTAssertEqual(RemoteMarkUnreadContract.capability, "mark-unread-v1")
        XCTAssertEqual(RemoteMarkUnreadContract.controlType, "mark-unread")
        // Only a gateway that routes the control advertises it.
        XCTAssertFalse(RemoteProtocolInfo.current.supports(RemoteMarkUnreadContract.capability))

        let unmarked = RemoteSessionSnapshot(
            id: "s", title: "t", status: "idle", statusText: nil,
            unread: false, ready: false, background: false, scheduled: false
        )
        XCTAssertNil(unmarked.markedUnread)
        XCTAssertFalse(try jsonObject(unmarked).keys.contains("markedUnread"))
        let marked = RemoteSessionSnapshot(
            id: "s", title: "t", status: "idle", statusText: nil,
            unread: true, ready: false, background: false, scheduled: false, markedUnread: true
        )
        XCTAssertEqual(try jsonObject(marked)["markedUnread"] as? Bool, true)
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSessionSnapshot.self, from: JSONEncoder().encode(marked)),
            marked
        )
        for fixture in ["served-workspace", "legacy-workspace"] {
            XCTAssertNil(try workspace(fixture).projects.first?.sessions.first?.markedUnread, fixture)
            XCTAssertNil(try workspace(fixture).projects.first?.sessions.first?.parentSessionId, fixture)
        }
    }

    func testRemoteSessionSnapshotOmitsNilParentSessionIdAndRoundTripsWhenPresent() throws {
        let topLevel = RemoteSessionSnapshot(
            id: "root", title: "Root", status: "idle", statusText: nil,
            unread: false, ready: false, background: false, scheduled: false
        )
        XCTAssertNil(topLevel.parentSessionId)
        XCTAssertFalse(try jsonObject(topLevel).keys.contains("parentSessionId"))

        let child = RemoteSessionSnapshot(
            id: "child", title: "Child", status: "running", statusText: nil,
            unread: false, ready: false, background: false, scheduled: false,
            parentSessionId: "root"
        )
        XCTAssertEqual(child.parentSessionId, "root")
        XCTAssertEqual(try jsonObject(child)["parentSessionId"] as? String, "root")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteSessionSnapshot.self, from: JSONEncoder().encode(child)),
            child
        )
    }

    func testSessionSearchContractIsNotAdvertisedByTheHostProtocol() {
        XCTAssertEqual(RemoteSessionSearchContract.capability, "session-search-v1")
        XCTAssertEqual(RemoteSessionSearchContract.recentCapability, "session-search-recent-v1")
        XCTAssertEqual(RemoteSessionSearchContract.path, "/search")
        XCTAssertEqual(RemoteSessionSearchContract.maximumQueryLength, 300)
        XCTAssertEqual(RemoteSessionSearchContract.maximumMatches, 50)
        // Only a gateway that serves the route advertises it.
        XCTAssertFalse(RemoteProtocolInfo.current.supports(RemoteSessionSearchContract.capability))
        XCTAssertFalse(RemoteProtocolInfo.current.supports(RemoteSessionSearchContract.recentCapability))
    }

    func testSessionSearchRequestWireShape() throws {
        let request = try JSONDecoder().decode(
            RemoteSessionSearchRequest.self,
            from: ProtocolFixtures.data(named: "session-search-request")
        )
        XCTAssertEqual(request, RemoteSessionSearchRequest(query: "billing webhook", mode: .instant))
        let luna = try jsonObject(RemoteSessionSearchRequest(query: "q", mode: .luna))
        XCTAssertEqual(Set(luna.keys), ["query", "mode"])
        XCTAssertEqual(luna["mode"] as? String, "luna")
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionSearchRequest.self, from: Data(#"{"query":"q","mode":"semantic"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionSearchRequest.self, from: Data(#"{"query":"q"}"#.utf8)
        ))
    }

    func testSessionSearchResponsesOmitAbsentSnippetsAndReasons() throws {
        let instant = try JSONDecoder().decode(
            RemoteSessionSearchResponse.self,
            from: ProtocolFixtures.data(named: "session-search-instant-response")
        )
        XCTAssertEqual(instant, RemoteSessionSearchResponse(mode: .instant, matches: [
            RemoteSessionSearchMatch(sessionId: "tab-named", projectId: "project"),
            RemoteSessionSearchMatch(
                sessionId: "tab-conversation", projectId: "project",
                snippet: "…why the billing webhook keeps timing out…"
            ),
        ]))
        let luna = try JSONDecoder().decode(
            RemoteSessionSearchResponse.self,
            from: ProtocolFixtures.data(named: "session-search-luna-response")
        )
        XCTAssertEqual(luna.mode, .luna)
        XCTAssertEqual(luna.matches.map(\.reason), ["Debugged webhook retry timeouts", nil])
        XCTAssertEqual(luna.matches.map(\.projectId), ["project", "other-project"])

        for response in [instant, luna] {
            XCTAssertEqual(
                try JSONDecoder().decode(RemoteSessionSearchResponse.self, from: JSONEncoder().encode(response)),
                response
            )
        }
        let encoded = try jsonObject(instant)
        XCTAssertEqual(Set(encoded.keys), ["mode", "matches"])
        let matches = try XCTUnwrap(encoded["matches"] as? [[String: Any]])
        XCTAssertEqual(Set(matches[0].keys), ["sessionId", "projectId"])
        XCTAssertEqual(Set(matches[1].keys), ["sessionId", "projectId", "snippet"])
        let reasoned = try jsonObject(RemoteSessionSearchMatch(sessionId: "s", projectId: "p", reason: "r"))
        XCTAssertEqual(Set(reasoned.keys), ["sessionId", "projectId", "reason"])

        let explicitNulls = try JSONDecoder().decode(
            RemoteSessionSearchMatch.self,
            from: Data(#"{"sessionId":"s","projectId":"p","snippet":null,"reason":null}"#.utf8)
        )
        XCTAssertEqual(explicitNulls, RemoteSessionSearchMatch(sessionId: "s", projectId: "p"))
        // Responses from hosts that predate activity times decode without them.
        XCTAssertEqual((instant.matches + luna.matches).map(\.lastActivityAt), [nil, nil, nil, nil])
    }

    func testRecentSearchRequestWireShape() throws {
        let request = try JSONDecoder().decode(
            RemoteSessionSearchRequest.self,
            from: ProtocolFixtures.data(named: "session-search-recent-request")
        )
        XCTAssertEqual(request, RemoteSessionSearchRequest(query: "", mode: .recent))
        XCTAssertEqual(try jsonObject(request)["mode"] as? String, "recent")
    }

    func testRecentResponseCarriesActivityTimesAsUnixMilliseconds() throws {
        let recent = try JSONDecoder().decode(
            RemoteSessionSearchResponse.self,
            from: ProtocolFixtures.data(named: "session-search-recent-response")
        )
        XCTAssertEqual(recent.mode, .recent)
        XCTAssertEqual(recent.matches.map(\.sessionId), ["tab-conversation", "tab-named", "tab-terminal"])
        XCTAssertEqual(recent.matches.map(\.lastActivityAtMilliseconds), [1_791_297_000_123, 1_791_293_400_000, nil])
        XCTAssertEqual(
            recent.matches[0],
            RemoteSessionSearchMatch(
                sessionId: "tab-conversation", projectId: "project",
                lastActivityAt: Date(timeIntervalSince1970: 1_791_297_000.123)
            )
        )
        XCTAssertEqual(recent.matches[1].lastActivityAt, Date(timeIntervalSince1970: 1_791_293_400))
        XCTAssertNil(recent.matches[2].lastActivityAt)

        // The wire form doesn't depend on the encoder's date strategy.
        let iso = JSONEncoder()
        iso.dateEncodingStrategy = .iso8601
        for encoder in [JSONEncoder(), iso] {
            XCTAssertEqual(try JSONDecoder().decode(RemoteSessionSearchResponse.self, from: encoder.encode(recent)), recent)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(recent)) as? [String: Any])
            let matches = try XCTUnwrap(object["matches"] as? [[String: Any]])
            XCTAssertEqual(Set(matches[0].keys), ["sessionId", "projectId", "lastActivityAtMilliseconds"])
            XCTAssertEqual((matches[0]["lastActivityAtMilliseconds"] as? NSNumber)?.int64Value, 1_791_297_000_123)
            XCTAssertEqual(Set(matches[2].keys), ["sessionId", "projectId"])
        }

        let explicitNull = try JSONDecoder().decode(
            RemoteSessionSearchMatch.self,
            from: Data(#"{"sessionId":"s","projectId":"p","lastActivityAtMilliseconds":null}"#.utf8)
        )
        XCTAssertEqual(explicitNull, RemoteSessionSearchMatch(sessionId: "s", projectId: "p"))
        XCTAssertThrowsError(try JSONDecoder().decode(
            RemoteSessionSearchMatch.self,
            from: Data(#"{"sessionId":"s","projectId":"p","lastActivityAtMilliseconds":"soon"}"#.utf8)
        ))
    }

    func testSessionSearchQueriesAreTrimmedAndBoundedInCharacters() {
        let limit = RemoteSessionSearchContract.maximumQueryLength
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery("  \n billing\twebhook \r\n"), "billing\twebhook")
        XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(""))
        XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(" \n\t "))
        let longest = String(repeating: "a", count: limit)
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery("  \(longest)  "), longest)
        XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(longest + "a"))
        // Each is one character but several UTF-16 code units, so a client
        // bounding UTF-16 length never sends more than the host accepts.
        let emoji = String(repeating: "👍🏽", count: limit)
        XCTAssertEqual(emoji.utf16.count, limit * 4)
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery(emoji), emoji)
        XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(emoji + "👍🏽"))
    }

    func testOnlyRecentSearchesAcceptAnEmptyQuery() {
        let limit = RemoteSessionSearchContract.maximumQueryLength
        let oversized = String(repeating: "a", count: limit + 1)
        for mode in [RemoteSessionSearchMode.instant, .luna] {
            XCTAssertNil(RemoteSessionSearchContract.normalizedQuery("", mode: mode))
            XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(" \n\t ", mode: mode))
            XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery(" webhook ", mode: mode), "webhook")
            XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(oversized, mode: mode))
        }
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery("", mode: .recent), "")
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery(" \n\t ", mode: .recent), "")
        XCTAssertEqual(RemoteSessionSearchContract.normalizedQuery(" webhook ", mode: .recent), "webhook")
        XCTAssertNil(RemoteSessionSearchContract.normalizedQuery(oversized, mode: .recent))
    }

    // MARK: - Multi-host discovery and session creation

    func testSSHHostCatalogDiscoversHostsFromSSHConfigAndIgnoresWildcardsAndForges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let forgeIncludeURL = dir.appendingPathComponent("forge_common")
        try "Host *\n  HostName github.com\nHost nested-only\n  HostName 10.0.0.99\n".write(
            to: forgeIncludeURL,
            atomically: true,
            encoding: .utf8
        )
        let optionsIncludeURL = dir.appendingPathComponent("user_common")
        try "User git\n".write(to: optionsIncludeURL, atomically: true, encoding: .utf8)

        let configURL = dir.appendingPathComponent("config")
        try """
        Match exec "true"
          IdentityAgent "~/.local/state/copilot-projects/ssh-agent.sock"

        # copilot-projects: name="Surface WSL" cwd="/root/Repos"
        Host woodhaven.thefergies.com
          User root
          ProxyCommand /opt/homebrew/bin/cloudflared access ssh --hostname %h

        Host devbox
          HostName 10.0.0.42
          User ubuntu

        Host forge-via-include
          Include forge_common

        Host forge-after-include
          Include user_common
          HostName gitlab.com

        Host forge-via-wildcard
          User git

        Host forge-*
          HostName github.com

        # copilot-projects: ignore
        Host bastion.internal.example.com
          User admin

        Host github.com ssh.github.com *.ghe.com *
          AddKeysToAgent yes
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let hosts = SSHHostCatalog.discoverHosts(sshConfigURL: configURL)
        XCTAssertEqual(hosts, [
            .local,
            RemoteHostInfo(
                id: "woodhaven.thefergies.com",
                displayName: "Surface WSL",
                sshTarget: "woodhaven.thefergies.com",
                defaultCwd: "/root/Repos",
                isLocal: false
            ),
            RemoteHostInfo(
                id: "devbox",
                displayName: "devbox",
                sshTarget: "devbox",
                defaultCwd: nil,
                isLocal: false
            ),
        ])

        XCTAssertEqual(
            SSHHostCatalog.resolve(hostId: "woodhaven", in: hosts)?.sshTarget,
            "woodhaven.thefergies.com"
        )
        XCTAssertEqual(
            SSHHostCatalog.resolve(hostId: "woodhaven.thefergies.com", in: hosts)?.id,
            "woodhaven.thefergies.com"
        )
        XCTAssertNil(
            SSHHostCatalog.resolve(hostId: "woodhaven.other.example.com", in: hosts)
        )
        XCTAssertEqual(
            SSHHostCatalog.resolve(hostId: nil, projectDefaultHostId: "devbox", in: hosts)?.id,
            "devbox"
        )
        XCTAssertEqual(
            SSHHostCatalog.resolve(hostId: "local", projectDefaultHostId: "devbox", in: hosts),
            .local
        )
        XCTAssertNil(SSHHostCatalog.resolve(hostId: "unknown-host", in: hosts))
    }

    @MainActor
    func testRemoteSessionCreationSupportsExplicitHostAndProjectDefaultHost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reposDir = dir.appendingPathComponent("Repos")
        try FileManager.default.createDirectory(at: reposDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let woodhaven = RemoteHostInfo(
            id: "woodhaven",
            displayName: "woodhaven",
            sshTarget: "root@woodhaven.thefergies.com",
            isLocal: false
        )
        let devbox = RemoteHostInfo(
            id: "devbox",
            displayName: "devbox",
            sshTarget: "devbox",
            isLocal: false
        )
        var wrapperExecutable: String? = "/usr/bin/true"
        let model = AppModel(
            stateRepository: StateRepository(path: dir.appendingPathComponent("state.json")),
            agentActivityDirectory: dir,
            resumeMarkerDirectory: dir,
            remoteCopilotExecutable: { "/usr/bin/true" },
            remoteWrapperExecutable: { wrapperExecutable },
            remoteReposDirectory: { reposDir.path },
            remoteSessionBackendAvailable: { true },
            availableHostsProvider: { [.local, woodhaven, devbox] },
            remoteSessionLauncher: { _, _, _ in },
            sessionCreationLedger: SessionCreationLedger(url: dir.appendingPathComponent("ledger.json")),
            projectCreationLedger: ProjectCreationLedger(url: dir.appendingPathComponent("proj-ledger.json"))
        )
        model.projects = [
            Project(id: "p1", name: "PR Reviews", cwd: reposDir.path, defaultHostId: "woodhaven"),
            Project(id: "p2", name: "Local Work", cwd: reposDir.path),
        ]

        // 1. Omitting hostId inherits project's defaultHostId ("woodhaven")
        let req1 = UUID()
        let out1 = model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: req1, projectId: "p1", kind: .copilot, initialPrompt: "Review PR"
        ))
        guard case .created = out1 else { return XCTFail("Expected created, got \(out1)") }
        XCTAssertEqual(model.projects[0].sessions.last?.hostId, "woodhaven")

        // 2. Explicit "local" overrides project's defaultHostId and clears stale .remote-host marker
        let req2 = UUID()
        let staleHostMarker = dir.appendingPathComponent("\(req2.uuidString).remote-host")
        try "woodhaven".write(to: staleHostMarker, atomically: true, encoding: .utf8)
        let out2 = model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: req2, projectId: "p1", kind: .copilot, initialPrompt: "Local check", hostId: "local"
        ))
        guard case .created = out2 else { return XCTFail("Expected created, got \(out2)") }
        XCTAssertNil(model.projects[0].sessions.last?.hostId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleHostMarker.path))

        // 3. Explicit "woodhaven" on a local-default project runs on woodhaven
        let req3 = UUID()
        let out3 = model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: req3, projectId: "p2", kind: .terminal, hostId: "woodhaven"
        ))
        guard case .created = out3 else { return XCTFail("Expected created, got \(out3)") }
        XCTAssertEqual(model.projects[1].sessions.last?.hostId, "woodhaven")

        // 4. Unknown hostId fails closed with .badRequest
        let out4 = model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
            requestId: UUID(), projectId: "p2", kind: .copilot, hostId: "nonexistent"
        ))
        XCTAssertEqual(out4, .badRequest)

        // 5. Missing remote wrapper fails closed for remote Copilot launches with wrapper-specific error
        wrapperExecutable = nil
        XCTAssertEqual(
            model.createRemoteConfiguredSession(RemoteCreateSessionRequest(
                requestId: UUID(), projectId: "p1", kind: .copilot
            )),
            .unavailable
        )
        XCTAssertThrowsError(try model.copilotSessionExecutable(toProjectId: "p1")) { error in
            XCTAssertTrue(error.localizedDescription.contains("COPILOT_PROJECTS_REMOTE_WRAPPER"))
            XCTAssertTrue(error.localizedDescription.contains("woodhaven"))
        }
        wrapperExecutable = "/usr/bin/true"

        // 6. Plain create with an orphaned dtach socket or resume marker requires matching host
        let orphanReq = UUID()
        let orphanSocket = URL(fileURLWithPath: Paths.dtachSocketPath(sessionId: orphanReq.uuidString))
        try FileManager.default.createDirectory(
            at: orphanSocket.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: orphanSocket)
        defer { try? FileManager.default.removeItem(at: orphanSocket) }
        let orphanHostMarker = dir.appendingPathComponent("\(orphanReq.uuidString).remote-host")
        try "woodhaven".write(to: orphanHostMarker, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            model.createRemoteSession(RemoteCreateSessionRequest(
                requestId: orphanReq, projectId: "p2", hostId: "local"
            )),
            .conflict
        )
        XCTAssertEqual(
            model.createRemoteSession(RemoteCreateSessionRequest(
                requestId: orphanReq, projectId: "p2", hostId: "devbox"
            )),
            .conflict
        )
        XCTAssertEqual(
            model.createRemoteSession(RemoteCreateSessionRequest(
                requestId: orphanReq, projectId: "p1"
            )),
            .created(RemoteCreateSessionResponse(
                requestId: orphanReq, projectId: "p1", sessionId: orphanReq.uuidString
            ))
        )

        let noSocketReq = UUID()
        try UUID().uuidString.write(
            to: dir.appendingPathComponent("\(noSocketReq.uuidString).copilot-session"),
            atomically: true,
            encoding: .utf8
        )
        try "woodhaven".write(
            to: dir.appendingPathComponent("\(noSocketReq.uuidString).remote-host"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(
            model.createRemoteSession(RemoteCreateSessionRequest(
                requestId: noSocketReq, projectId: "p2", hostId: "local"
            )),
            .conflict
        )

        // 7. Remote project with an explicit cwd preserves it on its default host, falls back to local startup dir for local sessions, and switching default host updates cwd
        model.projects.append(Project(id: "p3", name: "Custom Remote", cwd: "/srv/my-project", defaultHostId: "woodhaven"))
        XCTAssertEqual(model.defaultCwd(forProjectIndex: 2, targetHost: woodhaven), "/srv/my-project")
        XCTAssertEqual(model.defaultCwd(forProjectIndex: 2, targetHost: .local), Paths.defaultStartupDir)
        model.setProjectDefaultHost("p3", hostId: "local")
        XCTAssertEqual(model.projects[2].cwd, Paths.defaultStartupDir)
        SessionArtifacts.removeLeakedFiles(keeping: [], sessionsDirectory: dir)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("\(noSocketReq.uuidString).remote-host").path
            )
        )
        let composer = CopilotPromptComposer(availableHosts: [.local, woodhaven], selectedHostId: "retired-host")
        XCTAssertEqual(composer.selectedHostId, "retired-host")

        // 8. Snapshot and SessionRow accessibilityStatus surface host information
        let snap = model.remoteWorkspaceSnapshot()
        XCTAssertEqual(snap.availableHosts, [.local, woodhaven, devbox])
        XCTAssertEqual(snap.projects[0].defaultHostId, "woodhaven")
        XCTAssertEqual(snap.projects[0].sessions.first?.hostId, "woodhaven")
        XCTAssertEqual(snap.projects[0].sessions.first?.hostDisplayName, "woodhaven")
        let remoteSession = try XCTUnwrap(model.projects[0].sessions.first)
        let remoteRow = SessionRow(
            session: remoteSession,
            hostDisplayName: "Surface WSL",
            isActive: true,
            onSelect: {},
            onClose: {}
        )
        XCTAssertEqual(remoteRow.accessibilityStatus, "Selected, Idle, Running on Surface WSL")
        XCTAssertNotEqual(
            remoteRow,
            SessionRow(session: remoteSession, hostDisplayName: "woodhaven", isActive: true, onSelect: {}, onClose: {})
        )
        XCTAssertNotEqual(
            ProjectRow(project: model.projects[0], hostDisplayName: "Surface WSL"),
            ProjectRow(project: model.projects[0], hostDisplayName: "woodhaven")
        )
    }

    // MARK: - Host Health Indicators

    func testRemoteHostHealthContractAndEvaluationThresholds() throws {
        XCTAssertTrue(RemoteHostHealthLevel.healthy < .warning)
        XCTAssertTrue(RemoteHostHealthLevel.warning < .critical)
        XCTAssertFalse(RemoteHostHealthLevel.critical < .healthy)

        let unreachable = HostHealthEvaluator.makeHealth(
            host: RemoteHostInfo(id: "woodhaven", displayName: "Surface WSL", isLocal: false),
            reachable: false,
            cpuUsagePercent: 10,
            memoryUsagePercent: 20,
            diskAvailableBytes: 50_000_000_000,
            diskTotalBytes: 100_000_000_000,
            latencyMilliseconds: 30
        )
        XCTAssertEqual(unreachable.level, .critical)
        XCTAssertEqual(unreachable.statusSummary, "Unreachable")
        XCTAssertFalse(unreachable.reachable)
        XCTAssertNil(unreachable.cpuUsagePercent)
        XCTAssertNil(unreachable.diskAvailableBytes)

        let criticalCPU = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 92, memoryUsagePercent: 45, diskAvailableBytes: 80_000_000_000
        )
        XCTAssertEqual(criticalCPU.level, .critical)
        XCTAssertEqual(criticalCPU.statusSummary, "High CPU (92%)")

        let criticalMem = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 40, memoryUsagePercent: 91, diskAvailableBytes: 80_000_000_000
        )
        XCTAssertEqual(criticalMem.level, .critical)
        XCTAssertEqual(criticalMem.statusSummary, "High memory (91%)")

        let criticalDisk = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 20, memoryUsagePercent: 30, diskAvailableBytes: 4_900_000_000
        )
        XCTAssertEqual(criticalDisk.level, .critical)
        XCTAssertEqual(criticalDisk.statusSummary, "Low disk")

        let warningCPU = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 78, memoryUsagePercent: 50, diskAvailableBytes: 80_000_000_000
        )
        XCTAssertEqual(warningCPU.level, .warning)
        XCTAssertEqual(warningCPU.statusSummary, "High CPU (78%)")

        let warningMem = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 30, memoryUsagePercent: 84, diskAvailableBytes: 80_000_000_000
        )
        XCTAssertEqual(warningMem.level, .warning)
        XCTAssertEqual(warningMem.statusSummary, "High memory (84%)")

        let warningDisk = HostHealthEvaluator.evaluate(
            reachable: true, cpuUsagePercent: 20, memoryUsagePercent: 40, diskAvailableBytes: 12_000_000_000
        )
        XCTAssertEqual(warningDisk.level, .warning)
        XCTAssertEqual(warningDisk.statusSummary, "Low disk")

        let warningLatency = HostHealthEvaluator.evaluate(
            reachable: true,
            cpuUsagePercent: 20,
            memoryUsagePercent: 40,
            diskAvailableBytes: 80_000_000_000,
            latencyMilliseconds: 520
        )
        XCTAssertEqual(warningLatency.level, .warning)
        XCTAssertEqual(warningLatency.statusSummary, "High latency (520 ms)")

        // Exact threshold boundaries
        XCTAssertEqual(HostHealthEvaluator.evaluate(cpuUsagePercent: 90).level, .critical)
        XCTAssertEqual(HostHealthEvaluator.evaluate(cpuUsagePercent: 89).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(cpuUsagePercent: 75).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(cpuUsagePercent: 74).level, .healthy)
        XCTAssertEqual(HostHealthEvaluator.evaluate(memoryUsagePercent: 90).level, .critical)
        XCTAssertEqual(HostHealthEvaluator.evaluate(memoryUsagePercent: 89).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(memoryUsagePercent: 80).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(memoryUsagePercent: 79).level, .healthy)
        XCTAssertEqual(HostHealthEvaluator.evaluate(diskAvailableBytes: 4_999_999_999).level, .critical)
        XCTAssertEqual(HostHealthEvaluator.evaluate(diskAvailableBytes: 5_000_000_000).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(diskAvailableBytes: 14_999_999_999).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(diskAvailableBytes: 15_000_000_000).level, .healthy)
        XCTAssertEqual(HostHealthEvaluator.evaluate(latencyMilliseconds: 500).level, .warning)
        XCTAssertEqual(HostHealthEvaluator.evaluate(latencyMilliseconds: 499).level, .healthy)

        let healthy = HostHealthEvaluator.makeHealth(
            host: .local,
            reachable: true,
            cpuUsagePercent: 24,
            memoryUsagePercent: 58,
            diskAvailableBytes: 142_345_678_901,
            diskTotalBytes: 499_987_654_321,
            latencyMilliseconds: 14
        )
        XCTAssertEqual(healthy.level, .healthy)
        XCTAssertNil(healthy.statusSummary)
        XCTAssertEqual(healthy.diskAvailableBytes, 142_300_000_000)
        XCTAssertEqual(healthy.diskTotalBytes, 499_900_000_000)
        XCTAssertEqual(healthy.latencyMilliseconds, 10)

        let withoutHealth = RemoteWorkspaceSnapshot(projects: [], selectedProjectId: nil)
        XCTAssertNil(withoutHealth.hostHealth)
        XCTAssertFalse(try jsonObject(withoutHealth).keys.contains("hostHealth"))

        let withHealth = RemoteWorkspaceSnapshot(
            projects: [],
            selectedProjectId: nil,
            hostHealth: [healthy, unreachable]
        )
        let decoded = try JSONDecoder().decode(
            RemoteWorkspaceSnapshot.self,
            from: JSONEncoder().encode(withHealth)
        )
        XCTAssertEqual(decoded.hostHealth, [healthy, unreachable])
    }

    @MainActor
    func testHostHealthMonitorSamplingAndAppModelSnapshotIntegration() async throws {
        XCTAssertEqual(
            HostHealthMonitor.cpuUsagePercent(
                previous: CPULoadTicks(user: 100, system: 50, idle: 850, nice: 0),
                current: CPULoadTicks(user: 160, system: 90, idle: 950, nice: 0)
            ),
            50
        )

        let parsed = HostHealthMonitor.parseSSHProbeOutput("""
        /dev/sda1 104857600 52428800 41943040 56% /
        MEM 64
        CPU_TICKS 100 1000
        """)
        XCTAssertEqual(parsed.diskTotalBytes, 104_857_600 * 1_024)
        XCTAssertEqual(parsed.diskAvailableBytes, 41_943_040 * 1_024)
        XCTAssertEqual(parsed.memoryUsagePercent, 64)
        XCTAssertEqual(parsed.cpuUsagePercent, 10)

        let deltaMonitor = HostHealthMonitor()
        XCTAssertEqual(deltaMonitor.resolveRemoteCPUPercent(hostId: "woodhaven", parsed: parsed), 10)
        let saturatedNext = HostHealthMonitor.parseSSHProbeOutput("""
        /dev/sda1 104857600 52428800 41943040 56% /
        MEM 64
        CPU_TICKS 195 1100
        """)
        // Delta over the interval is (195 - 100) / (1100 - 1000) = 95%, even though cumulative is ~18%.
        XCTAssertEqual(deltaMonitor.resolveRemoteCPUPercent(hostId: "woodhaven", parsed: saturatedNext), 95)

        // Edge cases: negative available blocks (reserved space exhausted) and overflow block counts
        let negativeAvail = HostHealthMonitor.parseSSHProbeOutput("/dev/sda1 104857600 104857600 -512 100% /")
        XCTAssertEqual(negativeAvail.diskTotalBytes, 104_857_600 * 1_024)
        XCTAssertEqual(negativeAvail.diskAvailableBytes, 0)
        let overflowBlocks = HostHealthMonitor.parseSSHProbeOutput("/dev/sda1 9223372036854775807 0 1 1% /")
        XCTAssertNil(overflowBlocks.diskTotalBytes)
        XCTAssertNil(overflowBlocks.diskAvailableBytes)

        // Reboot reset (decreasing total ticks) falls back to the new sample's ratio rather than stale high load
        let rebootedSample = HostHealthMonitor.parseSSHProbeOutput("""
        /dev/sda1 104857600 52428800 41943040 56% /
        MEM 20
        CPU_TICKS 5 100
        """)
        XCTAssertEqual(deltaMonitor.resolveRemoteCPUPercent(hostId: "woodhaven", parsed: rebootedSample), 5)

        // Malformed delta where activeDelta > totalDelta falls back safely without trapping
        let weirdBase = HostHealthMonitor.parseSSHProbeOutput("CPU_TICKS 0 1000000000000000000")
        let weirdNext = HostHealthMonitor.parseSSHProbeOutput("CPU_TICKS 1000000000000000001 1000000000000000001")
        _ = deltaMonitor.resolveRemoteCPUPercent(hostId: "weird", parsed: weirdBase)
        XCTAssertEqual(deltaMonitor.resolveRemoteCPUPercent(hostId: "weird", parsed: weirdNext), 100)

        // Direct subprocess runner test (success, non-zero exit, and timeout)
        let scriptDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptDir) }

        let okScript = scriptDir.appendingPathComponent("fake-ssh-ok.sh")
        try """
        #!/bin/sh
        printf '/dev/sda1 209715200 104857600 83886080 55%% /\\nMEM 48\\nCPU_TICKS 30 100\\n'
        """.write(to: okScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: okScript.path)

        let failScript = scriptDir.appendingPathComponent("fake-ssh-fail.sh")
        try "#!/bin/sh\nexit 255\n".write(to: failScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failScript.path)

        let timeoutScript = scriptDir.appendingPathComponent("fake-ssh-timeout.sh")
        try "#!/bin/sh\nsleep 5\n".write(to: timeoutScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: timeoutScript.path)

        let woodhavenHost = RemoteHostInfo(
            id: "woodhaven",
            displayName: "Surface WSL",
            sshTarget: "woodhaven.thefergies.com",
            isLocal: false
        )
        let okResult = await HostHealthMonitor.probeSSHHost(
            woodhavenHost,
            sshExecutablePath: okScript.path,
            timeoutSeconds: 2.0
        )
        XCTAssertTrue(okResult.reachable)
        XCTAssertNotEqual(okResult.level, .critical)
        XCTAssertEqual(okResult.cpuUsagePercent, 30)
        XCTAssertEqual(okResult.memoryUsagePercent, 48)
        XCTAssertEqual(okResult.diskAvailableBytes, 85_800_000_000)

        let failResult = await HostHealthMonitor.probeSSHHost(
            woodhavenHost,
            sshExecutablePath: failScript.path,
            timeoutSeconds: 2.0
        )
        XCTAssertFalse(failResult.reachable)
        XCTAssertEqual(failResult.level, .critical)
        XCTAssertEqual(failResult.statusSummary, "Unreachable")

        let timeoutResult = await HostHealthMonitor.probeSSHHost(
            woodhavenHost,
            sshExecutablePath: timeoutScript.path,
            timeoutSeconds: 0.15
        )
        XCTAssertFalse(timeoutResult.reachable)
        XCTAssertEqual(timeoutResult.level, .critical)
        XCTAssertEqual(timeoutResult.statusSummary, "Unreachable")

        let woodhaven = RemoteHostInfo(
            id: "woodhaven",
            displayName: "Surface WSL",
            sshTarget: "woodhaven.thefergies.com",
            isLocal: false
        )
        let monitor = HostHealthMonitor { host in
            HostHealthEvaluator.makeHealth(
                host: host,
                reachable: true,
                cpuUsagePercent: 35,
                memoryUsagePercent: 62,
                diskAvailableBytes: 85_000_000_000,
                diskTotalBytes: 250_000_000_000,
                latencyMilliseconds: 43
            )
        }
        let sampled = await monitor.sampleAll(hosts: [.local, woodhaven])
        XCTAssertEqual(sampled.map(\.hostId), ["local", "woodhaven"])
        XCTAssertTrue(sampled[0].isLocal)
        XCTAssertNotNil(sampled[0].cpuUsagePercent)
        XCTAssertNotNil(sampled[0].memoryUsagePercent)
        XCTAssertNotNil(sampled[0].diskAvailableBytes)
        XCTAssertEqual(sampled[1].latencyMilliseconds, 40)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Production refresh path (without hostHealthProvider override)
        let productionModel = AppModel(
            stateRepository: StateRepository(path: dir.appendingPathComponent("state.json")),
            agentActivityDirectory: dir,
            resumeMarkerDirectory: dir,
            availableHostsProvider: { [.local, woodhaven] },
            hostHealthMonitor: monitor,
            sessionCreationLedger: SessionCreationLedger(url: dir.appendingPathComponent("ledger.json")),
            projectCreationLedger: ProjectCreationLedger(url: dir.appendingPathComponent("proj-ledger.json"))
        )
        XCTAssertNil(productionModel.remoteWorkspaceSnapshot().hostHealth)
        await productionModel.refreshHostHealthNow()
        XCTAssertEqual(productionModel.hostHealth.map(\.hostId), ["local", "woodhaven"])
        XCTAssertEqual(productionModel.remoteWorkspaceSnapshot().hostHealth?.map(\.hostId), ["local", "woodhaven"])
        XCTAssertEqual(productionModel.hostHealth[1].latencyMilliseconds, 40)
        productionModel.beginTermination()

        // Coalescing and in-flight termination guarantees
        actor ProbeGate {
            var calls = 0
            private var continuations: [CheckedContinuation<Void, Never>] = []
            func enter() async -> Int {
                calls += 1
                let index = calls
                await withCheckedContinuation { continuations.append($0) }
                return index
            }
            func releaseNext() {
                guard !continuations.isEmpty else { return }
                continuations.removeFirst().resume()
            }
            func currentCalls() -> Int { calls }
        }
        let gate = ProbeGate()
        let gatedMonitor = HostHealthMonitor { host in
            let callIndex = await gate.enter()
            return HostHealthEvaluator.makeHealth(
                host: host,
                reachable: true,
                cpuUsagePercent: 20 + callIndex,
                memoryUsagePercent: 50,
                diskAvailableBytes: 80_000_000_000,
                diskTotalBytes: 200_000_000_000,
                latencyMilliseconds: 25
            )
        }
        let coalescedModel = AppModel(
            stateRepository: StateRepository(path: dir.appendingPathComponent("state-coalesced.json")),
            agentActivityDirectory: dir,
            resumeMarkerDirectory: dir,
            availableHostsProvider: { [.local, woodhaven] },
            hostHealthMonitor: gatedMonitor,
            sessionCreationLedger: SessionCreationLedger(url: dir.appendingPathComponent("ledger-c.json")),
            projectCreationLedger: ProjectCreationLedger(url: dir.appendingPathComponent("proj-ledger-c.json"))
        )
        coalescedModel.refreshHostHealth()
        coalescedModel.refreshHostHealth()
        coalescedModel.refreshHostHealth()
        for _ in 0 ..< 40 {
            if await gate.currentCalls() == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let firstCallCount = await gate.currentCalls()
        XCTAssertEqual(firstCallCount, 1)
        await gate.releaseNext()
        for _ in 0 ..< 40 {
            if await gate.currentCalls() == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondCallCount = await gate.currentCalls()
        XCTAssertEqual(secondCallCount, 2)
        coalescedModel.beginTermination()
        await gate.releaseNext()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(coalescedModel.hostHealth.first(where: { $0.hostId == "woodhaven" })?.cpuUsagePercent, 21)

        // Provider override path
        var injectedHealth: [RemoteHostHealth] = []
        let model = AppModel(
            stateRepository: StateRepository(path: dir.appendingPathComponent("state-2.json")),
            agentActivityDirectory: dir,
            resumeMarkerDirectory: dir,
            availableHostsProvider: { [.local, woodhaven] },
            hostHealthProvider: { injectedHealth },
            hostHealthMonitor: monitor,
            sessionCreationLedger: SessionCreationLedger(url: dir.appendingPathComponent("ledger-2.json")),
            projectCreationLedger: ProjectCreationLedger(url: dir.appendingPathComponent("proj-ledger-2.json"))
        )
        XCTAssertNil(model.remoteWorkspaceSnapshot().hostHealth)

        injectedHealth = sampled
        model.refreshHostHealth()
        XCTAssertEqual(model.hostHealth, sampled)
        XCTAssertEqual(model.remoteWorkspaceSnapshot().hostHealth, sampled)
        XCTAssertEqual(HostHealthPill.overallLevel(for: sampled), sampled.map(\.level).max())
        XCTAssertTrue(HostHealthPill.metricsDescription(for: sampled[1]).contains("40 ms"))
    }

    @MainActor
    func testPerSessionMemoryFootprintAggregationAndSnapshotContract() throws {
        // 1. Live process memory footprint is positive for current PID
        let selfBytes = ProcessTree.processMemoryFootprintBytes(pid: getpid())
        XCTAssertNotNil(selfBytes)
        XCTAssertGreaterThan(selfBytes ?? 0, 0)

        // 2. ProcessTree aggregates dtach + non-nested-dtach descendants and quantizes to 10 MB
        let sessionsDir = URL(fileURLWithPath: "/tmp/test-sessions")
        var snap = ProcessTree.Snapshot()
        // s1: dtach (100) -> zsh (101) -> copilot (102), plus a nested dtach (200) for s2 -> node (201)
        snap.nameOf = [
            100: "dtach",
            101: "zsh",
            102: "copilot",
            200: "dtach",
            201: "node",
        ]
        snap.parentOf = [
            100: 1,
            101: 100,
            102: 101,
            200: 101,
            201: 200,
        ]
        snap.childrenOf = [
            100: [101],
            101: [102, 200],
            200: [201],
        ]
        let dtachProcesses = [
            ProcessTree.DtachProcess(
                pid: 100,
                parentPID: 1,
                socketPath: "/tmp/test-sessions/s1.sock",
                isMaster: true
            ),
            ProcessTree.DtachProcess(
                pid: 200,
                parentPID: 101,
                socketPath: "/tmp/test-sessions/s2.sock",
                isMaster: true
            ),
        ]
        let fakeMemory: [pid_t: Int64] = [
            100: 2_000_000,
            101: 18_000_000,
            102: 407_000_000,
            200: 2_000_000,
            201: 1_195_000_000,
        ]
        let aggregated = ProcessTree.sessionMemoryUsageBytes(
            in: snap,
            dtachProcesses: dtachProcesses,
            additionalRootPIDsBySession: ["s1": 101, "s3": 300],
            sessionsDirectory: sessionsDir,
            memoryOfPID: { pid in
                if pid == 300 { return 54_000_000 }
                return fakeMemory[pid]
            }
        )
        // s1: 2 + 18 + 407 = 427 MB -> quantized to 420 MB (excludes nested s2 dtach + node, and doesn't double-count overlapping root 101)
        XCTAssertEqual(aggregated["s1"], 420_000_000)
        // s2: 2 + 1195 = 1197 MB -> quantized to 1,190 MB
        XCTAssertEqual(aggregated["s2"], 1_190_000_000)
        // s3: direct non-dtach shell root 300 -> 54 MB quantized to 50 MB
        XCTAssertEqual(aggregated["s3"], 50_000_000)

        // 3. Formatting and SessionRow equality
        XCTAssertEqual(SessionMemoryBadge.formattedBytes(420_000_000), "420 MB")
        XCTAssertEqual(SessionMemoryBadge.formattedBytes(1_200_000_000), "1.2 GB")
        XCTAssertEqual(SessionMemoryBadge.formattedBytes(2_000_000_000), "2 GB")

        let baseSession = Session(id: "s1", title: "Session 1", cwd: "/tmp")
        var withMemSession = baseSession
        withMemSession.memoryUsageBytes = 420_000_000
        let rowA = SessionRow(session: baseSession, isActive: true, onSelect: {}, onClose: {})
        let rowB = SessionRow(session: withMemSession, isActive: true, onSelect: {}, onClose: {})
        XCTAssertNotEqual(rowA, rowB)
        XCTAssertTrue(rowB.accessibilityStatus.contains("Memory 420 MB"))

        // 4. RemoteSessionSnapshot wire contract & AppModel projection
        let withoutMem = RemoteSessionSnapshot(
            id: "s1", title: "S1", status: "idle", statusText: nil,
            unread: false, ready: false, background: false, scheduled: false
        )
        XCTAssertNil(withoutMem.memoryUsageBytes)
        XCTAssertFalse(try jsonObject(withoutMem).keys.contains("memoryUsageBytes"))

        let withMem = RemoteSessionSnapshot(
            id: "s1", title: "S1", status: "idle", statusText: nil,
            unread: false, ready: false, background: false, scheduled: false,
            memoryUsageBytes: 420_000_000
        )
        let roundTripped = try JSONDecoder().decode(
            RemoteSessionSnapshot.self,
            from: JSONEncoder().encode(withMem)
        )
        XCTAssertEqual(roundTripped.memoryUsageBytes, 420_000_000)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let providedMemory: [String: Int64] = ["s1": 427_000_000]
        let model = AppModel(
            stateRepository: StateRepository(path: dir.appendingPathComponent("state.json")),
            agentActivityDirectory: dir,
            resumeMarkerDirectory: dir,
            availableHostsProvider: { [.local] },
            hostHealthProvider: { [] },
            sessionMemoryProvider: { providedMemory },
            sessionCreationLedger: SessionCreationLedger(url: dir.appendingPathComponent("ledger.json")),
            projectCreationLedger: ProjectCreationLedger(url: dir.appendingPathComponent("proj-ledger.json"))
        )
        model.projects = [
            Project(
                id: "p1",
                name: "One",
                cwd: "/tmp",
                sessions: [
                    Session(id: "s1", title: "First", cwd: "/tmp"),
                    Session(id: "s2", title: "Second", cwd: "/tmp"),
                ]
            ),
        ]
        model.refreshHostHealth()
        XCTAssertEqual(model.projects[0].sessions[0].memoryUsageBytes, 420_000_000)
        XCTAssertNil(model.projects[0].sessions[1].memoryUsageBytes)
        let snapshot = model.remoteWorkspaceSnapshot()
        XCTAssertEqual(snapshot.projects[0].sessions[0].memoryUsageBytes, 420_000_000)
        XCTAssertNil(snapshot.projects[0].sessions[1].memoryUsageBytes)
    }
}
