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
        }
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
        let remoteRow = SessionRow(
            session: try XCTUnwrap(model.projects[0].sessions.first),
            isActive: true,
            onSelect: {},
            onClose: {}
        )
        XCTAssertEqual(remoteRow.accessibilityStatus, "Selected, Idle, Running on woodhaven")
    }
}
