import Foundation
import CopilotProjectsProtocol

extension RemoteTerminalScreen {
    static func captureVisible(
        sessionId: String,
        cols: Int,
        rows: Int,
        lineAt: (Int) -> String?
    ) -> RemoteTerminalScreen {
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0 ..< rows {
            lines.append(
                (lineAt(row) ?? "").replacingOccurrences(of: "\u{0}", with: " ")
            )
        }
        return RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: .terminal,
            historyStartLine: 0,
            firstLine: 0,
            liveTopLine: 0,
            reset: true,
            lines: lines
        )
    }

    static func captureHistory(
        sessionId: String,
        cols: Int,
        rows: Int,
        absoluteStart: Int,
        scanRows: Int,
        maximumRows: Int,
        afterLine: Int?,
        lineExists: (Int) -> Bool,
        lineAt: (Int) -> String?
    ) -> RemoteTerminalScreen {
        var lowerBound = absoluteStart
        var upperBound = absoluteStart + max(scanRows, rows)
        while lowerBound < upperBound {
            let midpoint = lowerBound + (upperBound - lowerBound) / 2
            if lineExists(midpoint) {
                lowerBound = midpoint + 1
            } else {
                upperBound = midpoint
            }
        }
        let absoluteEnd = lowerBound
        let historyStart = max(absoluteStart, absoluteEnd - maximumRows)
        let firstLine: Int
        let reset: Bool
        if let afterLine, afterLine >= historyStart, afterLine <= absoluteEnd {
            firstLine = max(historyStart, afterLine - rows)
            reset = false
        } else {
            firstLine = historyStart
            reset = true
        }

        var lines: [String] = []
        lines.reserveCapacity(max(0, absoluteEnd - firstLine))
        for line in firstLine ..< absoluteEnd {
            guard let value = lineAt(line) else { break }
            lines.append(value.replacingOccurrences(of: "\u{0}", with: " "))
        }
        return RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: .history,
            historyStartLine: historyStart,
            firstLine: firstLine,
            liveTopLine: max(historyStart, absoluteEnd - rows),
            reset: reset,
            lines: lines
        )
    }
}
