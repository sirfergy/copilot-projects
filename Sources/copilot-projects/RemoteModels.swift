import Foundation

struct RemoteWorkspaceSnapshot: Codable, Equatable {
    let projects: [RemoteProjectSnapshot]
    let selectedProjectId: String?
}

struct RemoteProjectSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let selectedSessionId: String?
    let sessions: [RemoteSessionSnapshot]
}

struct RemoteSessionSnapshot: Codable, Equatable {
    let id: String
    let title: String
    let status: String
    let statusText: String?
    let unread: Bool
    let ready: Bool
    let background: Bool
    let scheduled: Bool
}

enum RemoteScrollMode: String, Codable, Equatable {
    case history
    case terminal
}

struct RemoteTerminalScreen: Codable, Equatable {
    let sessionId: String
    let cols: Int
    let rows: Int
    let scrollMode: RemoteScrollMode
    /// Oldest absolute line still retained by the server's bounded history window.
    let historyStartLine: Int
    /// Absolute line represented by `lines[0]`.
    let firstLine: Int
    /// Absolute top row of the live terminal viewport.
    let liveTopLine: Int
    /// Replace local history instead of merging this segment.
    let reset: Bool
    let lines: [String]

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

    /// Captures a bounded, absolute-indexed history segment without changing the
    /// terminal's desktop viewport. The initial segment includes the full retained
    /// window; later segments overlap one viewport so clients can merge updates.
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
        // Valid buffer rows are contiguous, so find the first invalid row with
        // O(log n) probes instead of walking a potentially large scrollback.
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

struct RemoteClientMessage: Codable {
    let type: String
    let clientId: String?
    let sessionId: String?
    let data: String?
    let delta: Int?

    init(
        type: String,
        clientId: String? = nil,
        sessionId: String? = nil,
        data: String? = nil,
        delta: Int? = nil
    ) {
        self.type = type
        self.clientId = clientId
        self.sessionId = sessionId
        self.data = data
        self.delta = delta
    }
}

struct RemoteServerMessage<T: Codable>: Codable {
    let type: String
    let data: T
}
