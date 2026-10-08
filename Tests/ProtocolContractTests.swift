import XCTest
import CopilotProjectsProtocol
import CopilotProjectsProtocolFixtures

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
}
