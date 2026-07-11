import Foundation
import CopilotProjectsProtocol

struct TerminalLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

struct TerminalBuffer: Equatable {
    private(set) var mode: RemoteScrollMode = .terminal
    private(set) var cols = 0
    private(set) var rows = 0
    private(set) var liveTopLine = 0
    private(set) var lines: [TerminalLine] = []

    mutating func reset() {
        mode = .terminal
        cols = 0
        rows = 0
        liveTopLine = 0
        lines = []
    }

    mutating func apply(_ screen: RemoteTerminalScreen) {
        rows = screen.rows
        cols = screen.cols
        liveTopLine = screen.liveTopLine
        if screen.scrollMode == .terminal
            || screen.reset
            || mode != screen.scrollMode {
            mode = screen.scrollMode
            lines = screen.lines.enumerated().map {
                TerminalLine(id: screen.firstLine + $0.offset, text: $0.element)
            }
            return
        }

        mode = screen.scrollMode
        lines.removeAll { $0.id < screen.historyStartLine }
        var byID = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        for (offset, text) in screen.lines.enumerated() {
            byID[screen.firstLine + offset] = text
        }
        let maximum = screen.liveTopLine + screen.rows
        lines = byID
            .filter { $0.key < maximum }
            .map { TerminalLine(id: $0.key, text: $0.value) }
            .sorted { $0.id < $1.id }
    }
}
