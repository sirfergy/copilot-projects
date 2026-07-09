import Foundation

struct AgentActivitySnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: String
    var foregroundTurnActive: Bool
    var scheduledTurnActive: Bool
    var activeSubagents: [TrackedSubagent]
    var schedules: [TrackedSchedule]
    var idleGeneration: Int
    var lastIdleAborted: Bool
    var lastIdleTurnKind: String?
    var error: String?

    func isFresh(at now: Date = Date(), ttl: TimeInterval = 15) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              let updated = Self.date(from: updatedAt) else { return false }
        return now.timeIntervalSince(updated) <= ttl
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

struct TrackedSubagent: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var description: String
    var model: String?
}

struct TrackedSchedule: Codable, Equatable, Identifiable {
    var id: Int
    var intervalMs: Double?
    var cron: String?
    var tz: String?
    var at: Double?
    var prompt: String
    var recurring: Bool
    var displayPrompt: String?
    var nextRunAt: String

    var label: String {
        let value = displayPrompt ?? prompt
        let line = value.split(whereSeparator: \.isNewline).first.map(String.init) ?? value
        return line.count > 80 ? String(line.prefix(77)) + "..." : line
    }

    var cadenceDescription: String {
        if let intervalMs {
            let seconds = Int(intervalMs / 1_000)
            if seconds % 3_600 == 0 { return "every \(seconds / 3_600)h" }
            if seconds % 60 == 0 { return "every \(seconds / 60)m" }
            return "every \(seconds)s"
        }
        if let cron {
            let fields = cron.split(separator: " ")
            if fields.count == 5, fields[0].hasPrefix("*/"),
               let minutes = Int(fields[0].dropFirst(2)) {
                return "every \(minutes)m"
            }
            return "cron \(cron)"
        }
        return recurring ? "recurring" : "one time"
    }

    var nextRunDescription: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: nextRunAt)
                ?? ISO8601DateFormatter().date(from: nextRunAt) else {
            return nextRunAt
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    var helpText: String {
        let cadence = cadenceDescription
        let displayCadence = String(cadence.prefix(1)).uppercased()
            + String(cadence.dropFirst())
        return "Scheduled prompt #\(id)\n"
            + "Runs next at \(nextRunDescription)\n"
            + "\(displayCadence)\n"
            + label
    }
}
