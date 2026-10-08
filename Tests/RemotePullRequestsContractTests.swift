import Foundation
import XCTest
import CopilotProjectsProtocol
import CopilotProjectsProtocolFixtures

final class RemotePullRequestsContractTests: XCTestCase {
    func testOverviewFixturePinsSubsetAndMillisecondDates() throws {
        let data = try ProtocolFixtures.data(named: "pull-requests-overview")
        let overview = try JSONDecoder().decode(RemotePullRequestsOverview.self, from: data)
        XCTAssertEqual(overview.version, 1)
        XCTAssertEqual(overview.updatedAtMilliseconds, 1_791_446_400_000)
        XCTAssertEqual(overview.goals.first?.resumable?.pullRequestKeys, ["example/api#12"])
        XCTAssertEqual(overview.goals.first?.items.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(RemotePullRequestsOverview.self, from: JSONEncoder().encode(overview)), overview)
    }

    func testExistingResponseCanNameAnotherProjectsTab() throws {
        let request = try JSONDecoder().decode(RemotePullRequestSessionRequest.self, from:
            ProtocolFixtures.data(named: "pull-requests-resume-request"))
        let response = try JSONDecoder().decode(RemotePullRequestSessionResponse.self, from:
            ProtocolFixtures.data(named: "pull-requests-existing-response"))
        XCTAssertEqual(response.requestId, request.requestId)
        XCTAssertNotEqual(response.projectId, request.projectId)
        XCTAssertNotEqual(response.sessionId, request.requestId.uuidString)
    }

    func testNormalizationBindsCompleteIntentAndRejectsInvalidKindsAndKeys() {
        let id = UUID()
        let request = RemotePullRequestSessionRequest(
            requestId: id, kind: "start", projectId: "p",
            pullRequestKeys: ["Example/API#012", "example/api#12"]
        )
        XCTAssertEqual(request.normalized()?.pullRequestKeys, ["example/api#12"])
        XCTAssertTrue(request.hasSameIntent(as: .init(requestId: UUID(), kind: "start",
                      projectId: "p", pullRequestKeys: ["example/api#12"])))
        XCTAssertFalse(request.hasSameIntent(as: .init(requestId: id, kind: "start",
                       projectId: "p", pullRequestKeys: ["example/api#13"])))
        for kind in ["", "shell", "future-kind"] {
            XCTAssertNil(RemotePullRequestSessionRequest(
                requestId: id, kind: kind, projectId: "p", pullRequestKeys: ["example/api#12"]
            ).normalized())
        }
        for key in ["../api#1", "example/api#-1", "example/api#1/files", "example/api/path#1", "example/api%2fother#1"] {
            XCTAssertNil(RemotePullRequestsContract.canonicalKey(key), key)
        }
        XCTAssertNil(RemotePullRequestSessionRequest(
            requestId: id, kind: "resume", projectId: "p", pullRequestKeys: ["example/api#12"],
            copilotSessionId: "../../other"
        ).normalized())
    }

    func testLinksCannotChangeOriginOrPullRequestIdentity() {
        let key = "example/api#12"
        XCTAssertEqual(RemotePullRequestsContract.validatedURL(
            "https://github.com/Example/API/pull/12/files", key: key
        )?.absoluteString, "https://github.com/example/api/pull/12")
        for url in ["javascript:alert(1)", "https://evil.example/example/api/pull/12",
                    "https://github.com/example/api/pull/13", "https://user@github.com/example/api/pull/12"] {
            XCTAssertNil(RemotePullRequestsContract.validatedURL(url, key: key))
        }
    }

    func testUnfamiliarStatusValuesDoNotDiscardOtherwiseValidItems() throws {
        let data = try ProtocolFixtures.data(named: "pull-requests-overview")
        let json = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\"checks\"", with: "\"future-stage\"")
        let overview = try JSONDecoder().decode(RemotePullRequestsOverview.self, from: Data(json.utf8))
        XCTAssertEqual(overview.goals.first?.items.first?.stage, "future-stage")
    }
}
