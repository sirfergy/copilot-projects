import XCTest
import CopilotProjectsProtocol
@testable import Copilot_Projects

final class CopilotProjectsTests: XCTestCase {
    func testTerminalBufferMergesIncrementalHistory() {
        var buffer = TerminalBuffer()
        buffer.apply(RemoteTerminalScreen(
            sessionId: "session",
            cols: 80,
            rows: 3,
            scrollMode: .history,
            historyStartLine: 100,
            firstLine: 100,
            liveTopLine: 105,
            reset: true,
            lines: (100 ..< 108).map { "line-\($0)" }
        ))
        buffer.apply(RemoteTerminalScreen(
            sessionId: "session",
            cols: 80,
            rows: 3,
            scrollMode: .history,
            historyStartLine: 102,
            firstLine: 105,
            liveTopLine: 107,
            reset: false,
            lines: (105 ..< 110).map { "line-\($0)" }
        ))
        XCTAssertEqual(buffer.lines.first?.id, 102)
        XCTAssertEqual(buffer.lines.last?.id, 109)
        XCTAssertEqual(buffer.lines.last?.text, "line-109")
    }

    func testTerminalModeReplacesHistory() {
        var buffer = TerminalBuffer()
        buffer.apply(RemoteTerminalScreen(
            sessionId: "session",
            cols: 80,
            rows: 2,
            scrollMode: .history,
            historyStartLine: 10,
            firstLine: 10,
            liveTopLine: 10,
            reset: true,
            lines: ["old", "history"]
        ))
        buffer.apply(RemoteTerminalScreen(
            sessionId: "session",
            cols: 80,
            rows: 2,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: ["live", "screen"]
        ))
        XCTAssertEqual(buffer.mode, .terminal)
        XCTAssertEqual(buffer.lines.map(\.text), ["live", "screen"])
    }

    func testSharedDeepLinkParsesNotificationTarget() {
        XCTAssertEqual(
            AppDeepLink(url: URL(
                string: "copilot-projects://focus?project=p&session=s"
            )!),
            AppDeepLink(projectId: "p", sessionId: "s")
        )
    }
}
