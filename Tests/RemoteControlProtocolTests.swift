import Foundation
import XCTest
import CopilotProjectsProtocol

final class RemoteControlProtocolTests: XCTestCase {
    private let epoch = "00000000-0000-4000-8000-000000000001"

    func testControlDeliveryNegotiationPreservesLegacyAndFailsClosed() throws {
        let legacy = try JSONDecoder().decode(
            RemoteProtocolInfo.self,
            from: Data(#"{"revision":1,"capabilities":["sdk-operation-receipts"]}"#.utf8)
        )
        XCTAssertEqual(legacy.controlDeliverySupport, .legacy)
        XCTAssertNil(legacy.controlDeliveryEpoch)

        let invalidEpochs: [String?] = [nil, "", "not-an-epoch"]
        for invalidEpoch in invalidEpochs {
            let info = RemoteProtocolInfo(
                revision: 1,
                capabilities: [RemoteProtocolInfo.replaySafeControl],
                controlDeliveryEpoch: invalidEpoch
            )
            XCTAssertEqual(info.controlDeliverySupport, .unavailable)
        }
    }

    func testLiveHostAddsReplayCapabilityWithoutReplacingOtherCapabilities() {
        let info = RemoteProtocolInfo.current.supportingReplaySafeControl(epoch: epoch)
        XCTAssertEqual(info.controlDeliverySupport, .replaySafe(epoch: epoch))
        XCTAssertEqual(info.revision, RemoteProtocolInfo.current.revision)
        for capability in RemoteProtocolInfo.current.capabilities {
            XCTAssertTrue(info.supports(capability))
        }
        XCTAssertEqual(
            info.supportingReplaySafeControl(epoch: epoch).capabilities,
            info.capabilities
        )
    }

    func testControlDeliveryRoundTripKeepsRequestIdentityAndMetadata() throws {
        let request = RemoteClientMessage(
            type: "input",
            clientId: "phone",
            sessionId: "session",
            requestId: "request",
            data: "hello",
            delivery: RemoteControlDelivery(epoch: epoch, sequence: 2)
        )
        let data = try JSONEncoder().encode(request)
        XCTAssertEqual(try JSONDecoder().decode(RemoteClientMessage.self, from: data), request)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let delivery = try XCTUnwrap(json["delivery"] as? [String: Any])
        XCTAssertEqual(delivery["epoch"] as? String, epoch)
        XCTAssertEqual(delivery["sequence"] as? Int, 2)
        XCTAssertEqual(json["requestId"] as? String, "request")

        let old = try JSONDecoder().decode(
            RemoteClientMessage.self,
            from: Data(#"{"type":"input","clientId":"phone","sessionId":"session","data":"hello"}"#.utf8)
        )
        XCTAssertNil(old.delivery)
        let oldJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any]
        )
        XCTAssertNil(oldJSON["delivery"])
    }

    func testControlDeliverySequenceStaysWithinJavaScriptIntegerRange() {
        XCTAssertTrue(RemoteControlDelivery(epoch: epoch, sequence: 1).isValid)
        XCTAssertTrue(RemoteControlDelivery(
            epoch: epoch, sequence: RemoteControlDelivery.maximumSequence
        ).isValid)
        for sequence in [Int64(-1), 0, RemoteControlDelivery.maximumSequence + 1] {
            XCTAssertFalse(RemoteControlDelivery(epoch: epoch, sequence: sequence).isValid)
        }
        XCTAssertFalse(RemoteControlDelivery(epoch: "invalid", sequence: 1).isValid)
    }
}
