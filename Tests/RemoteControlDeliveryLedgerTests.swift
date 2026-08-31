import XCTest
import CopilotProjectsProtocol
@testable import copilot_projects

final class RemoteControlDeliveryLedgerTests: XCTestCase {
    @MainActor
    private func message(
        _ ledger: RemoteControlDeliveryLedger,
        kind: String = "input",
        clientId: String = "client",
        sessionId: String = "session",
        requestId: String? = "request",
        sequence: Int64 = 1,
        data: String? = "hello",
        conversationEpoch: String? = nil,
        epoch: String? = nil
    ) -> RemoteClientMessage {
        RemoteClientMessage(
            type: kind,
            clientId: clientId,
            sessionId: sessionId,
            requestId: requestId,
            data: data,
            conversationEpoch: conversationEpoch,
            delivery: RemoteControlDelivery(epoch: epoch ?? ledger.epoch, sequence: sequence)
        )
    }

    @MainActor
    func testExactReplayInjectsEachControlKindOnce() {
        for kind in RemoteControlKind.allCases {
            let ledger = RemoteControlDeliveryLedger()
            let request = message(ledger, kind: kind.rawValue, data: kind == .key ? "enter" : "hello")
            var injections = 0
            XCTAssertEqual(ledger.perform(request, sessionExists: true) {
                injections += 1
                return .sent
            }, .sent)
            for _ in 0 ..< 3 {
                XCTAssertEqual(ledger.perform(request, sessionExists: true) {
                    injections += 1
                    return .busy
                }, .sent)
            }
            XCTAssertEqual(injections, 1, kind.rawValue)
            XCTAssertEqual(ledger.scopeCount, 1)
        }
    }

    @MainActor
    func testBusyRetryAdvancesOnlyAfterAcceptanceAndPermitsGaps() {
        let ledger = RemoteControlDeliveryLedger()
        let first = message(ledger)
        let next = message(ledger, requestId: "next", sequence: 10)
        var injections = 0
        XCTAssertEqual(ledger.perform(first, sessionExists: true) {
            injections += 1
            return .sent
        }, .sent)
        XCTAssertEqual(ledger.perform(next, sessionExists: true) { .busy }, .busy)
        XCTAssertEqual(ledger.perform(first, sessionExists: true) {
            XCTFail("Busy requests must not evict the last accepted fingerprint")
            return .invalid
        }, .sent)
        XCTAssertEqual(ledger.perform(next, sessionExists: true) {
            injections += 1
            return .sent
        }, .sent)
        XCTAssertEqual(ledger.perform(first, sessionExists: true) {
            XCTFail("An older sequence cannot be reinjected")
            return .sent
        }, .superseded)
        XCTAssertEqual(injections, 2)
    }

    @MainActor
    func testRefusalsDoNotCreateOrAdvanceWatermarks() {
        let refusals: [RemoteControlResult] = [.busy, .invalid, .missing, .forbidden, .noLiveCopilot]
        for refusal in refusals {
            let ledger = RemoteControlDeliveryLedger()
            let rejected = message(ledger, sequence: 10)
            XCTAssertEqual(ledger.perform(rejected, sessionExists: true) { refusal }, refusal)
            XCTAssertEqual(ledger.scopeCount, 0)
            XCTAssertEqual(ledger.perform(message(ledger), sessionExists: true) { .sent }, .sent)
            XCTAssertEqual(ledger.perform(rejected, sessionExists: true) { refusal }, refusal)
            XCTAssertEqual(ledger.perform(message(ledger), sessionExists: true) {
                XCTFail("A refusal must not replace an existing acceptance")
                return .invalid
            }, .sent)
        }
    }

    @MainActor
    func testSameSequenceBindsRequestKindPayloadAndOptionalConversationEpoch() {
        let ledger = RemoteControlDeliveryLedger()
        let original = message(ledger, conversationEpoch: "conversation")
        XCTAssertEqual(ledger.perform(original, sessionExists: true) { .sent }, .sent)
        let conflicts = [
            message(ledger, requestId: "different", conversationEpoch: "conversation"),
            message(ledger, kind: "command", conversationEpoch: "conversation"),
            message(ledger, data: "different", conversationEpoch: "conversation"),
            message(ledger, conversationEpoch: "different"),
            message(ledger),
        ]
        for conflict in conflicts {
            XCTAssertEqual(ledger.perform(conflict, sessionExists: true) {
                XCTFail("Changed content must not inject")
                return .sent
            }, .fingerprintConflict)
        }
        XCTAssertEqual(ledger.perform(original, sessionExists: true) { .invalid }, .sent)
    }

    @MainActor
    func testFingerprintFramesFieldsAndDistinguishesAbsentEpoch() {
        let ledger = RemoteControlDeliveryLedger()
        XCTAssertEqual(ledger.perform(
            message(ledger, requestId: "ab", data: "c"), sessionExists: true
        ) { .sent }, .sent)
        XCTAssertEqual(ledger.perform(
            message(ledger, requestId: "a", data: "bc"), sessionExists: true
        ) { .sent }, .fingerprintConflict)
        XCTAssertEqual(ledger.perform(
            message(ledger, requestId: "ab", data: "c", conversationEpoch: ""), sessionExists: true
        ) { .sent }, .fingerprintConflict)
    }

    @MainActor
    func testLowerSequenceIsIndeterminateEvenWithDifferentFingerprint() {
        let ledger = RemoteControlDeliveryLedger()
        XCTAssertEqual(ledger.perform(message(ledger, sequence: 42), sessionExists: true) { .sent }, .sent)
        XCTAssertEqual(ledger.perform(
            message(ledger, requestId: "never-accepted", sequence: 41, data: "different"),
            sessionExists: true
        ) {
            XCTFail("Only higher sequences are eligible for injection")
            return .sent
        }, .superseded)
    }

    @MainActor
    func testRestartEpochRejectsPreviouslySubmittedDelivery() {
        let originalHost = RemoteControlDeliveryLedger()
        let request = message(originalHost)
        XCTAssertEqual(originalHost.perform(request, sessionExists: true) { .sent }, .sent)
        let restartedHost = RemoteControlDeliveryLedger()
        XCTAssertNotEqual(restartedHost.epoch, originalHost.epoch)
        XCTAssertEqual(restartedHost.perform(request, sessionExists: true) {
            XCTFail("Losing the old ledger must not permit the old delivery")
            return .sent
        }, .epochMismatch)
        XCTAssertEqual(restartedHost.scopeCount, 0)
        XCTAssertEqual(restartedHost.perform(message(restartedHost), sessionExists: true) { .sent }, .sent)
    }

    @MainActor
    func testMalformedIdentitiesAndBoundsNeverReachInjection() {
        let ledger = RemoteControlDeliveryLedger()
        let invalid = [
            message(ledger, requestId: nil),
            message(ledger, requestId: ""),
            message(ledger, requestId: String(repeating: "r", count: 65)),
            message(ledger, requestId: String(repeating: "é", count: 33)),
            message(ledger, clientId: ""),
            message(ledger, clientId: String(repeating: "c", count: 65)),
            message(ledger, sessionId: ""),
            message(ledger, sessionId: String(repeating: "s", count: 65)),
            message(ledger, sequence: -1),
            message(ledger, sequence: 0),
            message(ledger, sequence: RemoteControlDelivery.maximumSequence + 1),
            message(ledger, epoch: "not-a-uuid"),
            message(ledger, data: nil),
            message(ledger, data: String(repeating: "x", count: 8_193)),
            message(ledger, kind: "scroll"),
            RemoteClientMessage(type: "input", clientId: "client", sessionId: "session", data: "hi"),
        ]
        for request in invalid {
            XCTAssertEqual(ledger.perform(request, sessionExists: true) {
                XCTFail("Invalid identities must fail closed")
                return .sent
            }, .invalid)
        }
        XCTAssertEqual(ledger.scopeCount, 0)
    }

    @MainActor
    func testInclusiveRequestAndSequenceBoundsAreAccepted() {
        let ledger = RemoteControlDeliveryLedger()
        let request = message(
            ledger,
            clientId: String(repeating: "c", count: 64),
            sessionId: String(repeating: "s", count: 64),
            requestId: String(repeating: "r", count: 64),
            sequence: RemoteControlDelivery.maximumSequence,
            data: String(repeating: "x", count: 8_192)
        )
        XCTAssertEqual(ledger.perform(request, sessionExists: true) { .sent }, .sent)
        XCTAssertEqual(ledger.perform(request, sessionExists: true) { .invalid }, .sent)
        XCTAssertEqual(ledger.scopeCount, 1)
    }

    @MainActor
    func testCapacityFailsClosedWithoutEvictingLiveScopes() {
        let ledger = RemoteControlDeliveryLedger()
        XCTAssertEqual(RemoteControlDeliveryLedger.maximumScopes, 8_192)
        for index in 0 ..< RemoteControlDeliveryLedger.maximumScopes {
            XCTAssertEqual(ledger.perform(
                message(ledger, clientId: "client-\(index)"), sessionExists: true
            ) { .sent }, .sent)
        }
        let oldest = message(ledger, clientId: "client-0")
        XCTAssertEqual(ledger.scopeCount, 8_192)
        XCTAssertEqual(ledger.perform(message(ledger, clientId: "overflow"), sessionExists: true) {
            XCTFail("Capacity must refuse a new scope before performing")
            return .sent
        }, .capacityExceeded)
        XCTAssertEqual(ledger.perform(oldest, sessionExists: true) { .invalid }, .sent)
        XCTAssertEqual(ledger.perform(
            message(ledger, clientId: "client-0", requestId: "next", sequence: 2), sessionExists: true
        ) { .sent }, .sent)
        XCTAssertEqual(ledger.perform(oldest, sessionExists: true) { .sent }, .superseded)
        XCTAssertEqual(ledger.scopeCount, 8_192)
    }

    @MainActor
    func testOnlyClosedSessionScopesArePruned() {
        let ledger = RemoteControlDeliveryLedger(capacity: 3)
        let closedPrompt = message(ledger, kind: "prompt", sessionId: "closing")
        let closedTerminal = message(ledger, clientId: "other-client", sessionId: "closing")
        let live = message(ledger, sessionId: "live")
        for request in [closedPrompt, closedTerminal, live] {
            XCTAssertEqual(ledger.perform(request, sessionExists: true) { .sent }, .sent)
        }
        ledger.removeClosedSession("closing")
        XCTAssertEqual(ledger.scopeCount, 1)
        XCTAssertEqual(ledger.perform(live, sessionExists: true) { .invalid }, .sent)
        XCTAssertEqual(ledger.perform(closedPrompt, sessionExists: false) { .sent }, .missing)
        XCTAssertEqual(ledger.perform(message(ledger, sessionId: "new"), sessionExists: true) { .sent }, .sent)
        XCTAssertEqual(ledger.scopeCount, 2)
    }

    @MainActor
    func testMissingSessionCannotAllocateState() {
        let ledger = RemoteControlDeliveryLedger(capacity: 1)
        for index in 0 ..< 10 {
            XCTAssertEqual(ledger.perform(
                message(ledger, sessionId: "missing-\(index)"), sessionExists: false
            ) {
                XCTFail("Arbitrary nonexistent sessions must not create ledger state")
                return .sent
            }, .missing)
        }
        XCTAssertEqual(ledger.scopeCount, 0)
        XCTAssertEqual(ledger.perform(message(ledger), sessionExists: true) { .sent }, .sent)
    }

    @MainActor
    func testClientSessionAndPromptLaneIsolationWithOneSharedTerminalLane() {
        let ledger = RemoteControlDeliveryLedger()
        XCTAssertEqual(ledger.perform(
            message(ledger, kind: "command", sequence: 20), sessionExists: true
        ) { .sent }, .sent)
        let independent = [
            message(ledger, kind: "prompt"),
            message(ledger, clientId: "another-client"),
            message(ledger, sessionId: "another-session"),
        ]
        for request in independent {
            XCTAssertEqual(ledger.perform(request, sessionExists: true) { .sent }, .sent)
        }
        for kind in ["key", "input"] {
            XCTAssertEqual(ledger.perform(
                message(ledger, kind: kind, sequence: 19), sessionExists: true
            ) { .sent }, .superseded)
        }
        XCTAssertEqual(ledger.scopeCount, 4)
    }
}
