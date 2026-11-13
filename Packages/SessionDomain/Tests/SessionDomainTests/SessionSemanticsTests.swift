import XCTest
@testable import SessionDomain

final class SessionSemanticsTests: XCTestCase {
    func testSessionStatusRoundTrips() throws {
        for status in SessionStatus.allCases {
            let data = try JSONEncoder().encode(status)
            XCTAssertEqual(try JSONDecoder().decode(SessionStatus.self, from: data), status)
        }
    }
}
