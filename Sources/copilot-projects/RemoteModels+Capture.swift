import Foundation
import CopilotProjectsProtocol
import SwiftTerm

extension TerminalContentRowSnapshot {
    /// Keep the existing wire's one-Swift-Character-per-cell projection. A v2
    /// cell can hold more than one Swift Character (for example GB9c clusters);
    /// its full text remains available separately for cell-aware consumers.
    var remoteText: String {
        guard let last = cells.lastIndex(where: { $0.text != "\u{0}" }) else { return "" }
        let end = last + min(max(0, cells[last].width), cells.count - last)
        return cells[..<end].map { String($0.text.first ?? " ") }.joined()
    }
}

extension RemoteTerminalScreen {
    static func capture(
        sessionId: String,
        snapshot: TerminalContentSnapshot,
        terminalScroll: Bool,
        afterLine: Int?
    ) -> RemoteTerminalScreen {
        let dimensions = snapshot.inputState.dimensions
        if terminalScroll {
            return captureVisible(sessionId: sessionId, cols: dimensions.cols, rows: dimensions.rows) { row in
                snapshot.rows.indices.contains(row) ? snapshot.rows[row].remoteText : nil
            }
        }
        return captureHistory(
            sessionId: sessionId, cols: dimensions.cols, rows: dimensions.rows,
            absoluteStart: snapshot.capturedRange.lowerBound,
            scanRows: snapshot.capturedRange.count,
            maximumRows: snapshot.capturedRange.count,
            afterLine: afterLine,
            lineExists: snapshot.capturedRange.contains,
            lineAt: { absoluteRow in
                guard snapshot.capturedRange.contains(absoluteRow) else { return nil }
                return snapshot.rows[absoluteRow - snapshot.capturedRange.lowerBound].remoteText
            })
    }

    static func captureVisible(
        sessionId: String,
        cols: Int,
        rows: Int,
        lineAt: (Int) -> String?
    ) -> RemoteTerminalScreen {
        var lines: [String] = []
        lines.reserveCapacity(rows)
        for row in 0 ..< rows {
            lines.append(RemoteKittyGraphics.sanitizeLine(
                (lineAt(row) ?? "").replacingOccurrences(of: "\u{0}", with: " ")
            ))
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
            lines.append(RemoteKittyGraphics.sanitizeLine(
                value.replacingOccurrences(of: "\u{0}", with: " ")
            ))
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

    /// Attaches `images` (or clears them) without altering any other field —
    /// used to attach freshly recomputed Kitty placements to an already-captured
    /// screen so live/history text and scroll semantics are untouched. Callers
    /// scanning the full retained history should always pass a present array
    /// (`[]` included when nothing was found), never `nil` — see
    /// `RemoteTerminalScreen.images`'s doc comment for why that distinction
    /// matters to a client.
    func withImages(_ images: [RemoteTerminalImagePlacement]?) -> RemoteTerminalScreen {
        RemoteTerminalScreen(
            sessionId: sessionId,
            cols: cols,
            rows: rows,
            scrollMode: scrollMode,
            historyStartLine: historyStartLine,
            firstLine: firstLine,
            liveTopLine: liveTopLine,
            reset: reset,
            lines: lines,
            images: images
        )
    }
}
