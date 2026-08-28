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
}
