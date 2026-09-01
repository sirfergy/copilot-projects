import Foundation
import CopilotProjectsProtocol

struct CompletionSummaryContext: Sendable {
    let copilotSessionId: String
    let activeAt: Date
    let completedAt: Date

    init?(copilotSessionId: String?, activeTimestamp: Int64?, completionTimestamp: Int64?) {
        guard let copilotSessionId, !copilotSessionId.isEmpty,
              let activeTimestamp, let completionTimestamp,
              activeTimestamp < completionTimestamp else { return nil }
        self.copilotSessionId = copilotSessionId
        activeAt = Date(timeIntervalSince1970: Double(activeTimestamp) / 1_000)
        completedAt = Date(timeIntervalSince1970: Double(completionTimestamp) / 1_000)
    }
}

enum NotificationSummary {
    static func completion(
        from snapshot: TranscriptSnapshot,
        context: CompletionSummaryContext
    ) -> String? {
        // Do not search backwards: an empty, interrupted or newer turn must never
        // cause an earlier task's answer to be presented as this completion.
        guard snapshot.schemaVersion == 3,
              snapshot.copilotSessionId == context.copilotSessionId,
              let turn = snapshot.turns.last,
              turn.kind == "foreground" || turn.kind == "automated",
              !turn.isAborted,
              turn.startedAt <= context.completedAt,
              let endedAt = turn.endedAt,
              endedAt >= turn.startedAt,
              endedAt > context.activeAt,
              let message = turn.assistantMessages.last,
              message.timestamp >= turn.startedAt,
              message.timestamp <= context.completedAt else { return nil }
        return preview(message.content)
    }

    static func preview(_ markdown: String) -> String? {
        // Bound parser work as well as the eventual notification payload.
        let input = String(markdown.prefix(8_192))
        guard MarkdownParser.isWithinRenderingLimits(input),
              let attributed = try? AttributedString(markdown: input) else { return nil }
        var plain = ""
        var previousIntent: PresentationIntent?
        for run in attributed.runs {
            let intent = run.presentationIntent
            if intent?.components.contains(where: {
                if case .codeBlock = $0.kind { return true }
                return false
            }) == true { continue }
            if intent != previousIntent { plain += " " }
            plain += String(attributed[run.range].characters)
            previousIntent = intent
        }
        let text = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let maximumCharacters = 320
        let maximumBytes = 1_000
        if text.count <= maximumCharacters, text.utf8.count <= maximumBytes,
           input == markdown { return text }

        let ellipsis = "\u{2026}"
        var prefix = ""
        var bytes = 0
        for character in text.prefix(maximumCharacters - 1) {
            let size = String(character).utf8.count
            guard bytes + size <= maximumBytes - ellipsis.utf8.count else { break }
            prefix.append(character)
            bytes += size
        }
        if let boundary = prefix.lastIndex(of: " "),
           prefix.distance(from: prefix.startIndex, to: boundary) >= prefix.count / 2 {
            prefix = String(prefix[..<boundary])
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines) + ellipsis
    }

    static func loadCompletion(
        sessionId: String,
        context: CompletionSummaryContext,
        loadSnapshot: @Sendable (String) -> TranscriptSnapshot
    ) async -> String? {
        for attempt in 0..<3 {
            if attempt > 0 {
                do { try await Task.sleep(nanoseconds: 100_000_000) }
                catch { return nil }
            }
            if let summary = completion(from: loadSnapshot(sessionId), context: context) {
                return summary
            }
        }
        return nil
    }
}
