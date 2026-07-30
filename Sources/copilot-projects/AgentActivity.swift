import Foundation
import CopilotProjectsProtocol

struct AgentActivitySnapshot: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var updatedAt: String
    var foregroundTurnActive: Bool
    /// Wall-clock time (ISO8601) of the most recent `foregroundTurnActive`
    /// transition — set by the extension only at root turn_start/turn_end/
    /// session.idle, unlike `updatedAt` which every publish() rewrites. Carries
    /// the CLI event's causal timestamp (`normalizedTimestamp(event.timestamp)`),
    /// the same time base the status hooks use, so it's directly comparable to
    /// the status-event clock. Optional (nil default) so snapshots written before
    /// this field still decode.
    var foregroundTransitionAt: String? = nil
    var scheduledTurnActive: Bool
    var activeSubagents: [TrackedSubagent]
    var schedules: [TrackedSchedule]
    var idleGeneration: Int
    var lastIdleAborted: Bool
    var lastIdleTurnKind: String?
    var error: String?
    /// Structured `ask_user` questions currently awaiting an answer. Optional (with a
    /// nil default) so older heartbeat snapshots that predate this field still decode.
    var trackedUserInputs: [TrackedUserInput]? = nil
    /// Schema-form `elicitation.requested` questions awaiting an answer. Optional
    /// (nil default) for backward-compatible decoding of older heartbeats.
    var trackedElicitations: [TrackedElicitation]? = nil
    /// The session's effective model (name + reasoning effort + context tier).
    /// Optional (nil default) so older heartbeats without it still decode.
    var model: TrackedModel? = nil
    /// The models this session can switch to, mirrored from the CLI's own catalog
    /// (`session.rpc.model.list()`), ordered preferred-default-first. Optional (nil
    /// default) so older heartbeats without it still decode and so a session that
    /// hasn't reported its catalog yet simply exposes no picker.
    var availableModels: [TrackedAvailableModel]? = nil

    func isFresh(at now: Date = Date(), ttl: TimeInterval = 15) -> Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              let updated = Self.date(from: updatedAt) else { return false }
        return now.timeIntervalSince(updated) <= ttl
    }

    /// True when the last heartbeat carried a terminal RPC-connection error
    /// (closed/disposed). A disconnected extension can no longer observe
    /// `assistant.turn_end`/`session.idle`, so its `foregroundTurnActive` (and
    /// other in-flight) claims are stale and must not be treated as authoritative
    /// evidence that a foreground turn is still running — otherwise the 5s
    /// heartbeat republishes the stuck snapshot fresh and the tab reads "working"
    /// forever. Matches the vscode-jsonrpc terminal wordings.
    var reportsTerminalDisconnect: Bool {
        guard let error else { return false }
        let lowered = error.lowercased()
        return lowered.contains("connection is closed")
            || lowered.contains("connection is disposed")
    }

    /// `foregroundTransitionAt` as epoch milliseconds, matching the status-event
    /// clock's units. This is the causal time of the current foreground state
    /// (turn_start → active, turn_end/session.idle → inactive), so recovery and
    /// demotion seed the status clock from it rather than `updatedAt` — otherwise
    /// an unrelated republish (heartbeat, question, model/subagent event) could
    /// advance the clock past a delayed status hook and silently drop it. Older
    /// snapshots predating the field return nil and cannot drive reconciliation.
    var foregroundTransitionMilliseconds: Int64? {
        guard let value = foregroundTransitionAt,
              let transition = Self.date(from: value) else { return nil }
        return Int64(transition.timeIntervalSince1970 * 1_000)
    }

    /// `updatedAt` as epoch milliseconds. Every `publish()` rewrites `updatedAt`,
    /// so for a disconnected session the 5s heartbeat keeps this ~current; it is
    /// the freshest evidence time available when a snapshot only carries a
    /// terminal-disconnect error (no clean turn transition), used to order the
    /// disconnect demotion against the status-event clock.
    var updatedAtMilliseconds: Int64? {
        guard let updated = Self.date(from: updatedAt) else { return nil }
        return Int64(updated.timeIntervalSince1970 * 1_000)
    }

    /// Convert the tracked questions into the shared remote model for workspace
    /// snapshots. Returns nil when there are none so the field is omitted entirely.
    func remoteUserInputRequests() -> [RemoteUserInputRequest]? {
        guard let trackedUserInputs, !trackedUserInputs.isEmpty else { return nil }
        return trackedUserInputs.map { $0.remoteRequest() }
    }

    /// Convert the tracked elicitations into the shared remote model. Returns nil
    /// when there are none so the field is omitted entirely.
    func remoteElicitationRequests() -> [RemoteElicitationRequest]? {
        guard let trackedElicitations, !trackedElicitations.isEmpty else { return nil }
        return trackedElicitations.map { $0.remoteRequest() }
    }

    /// Convert the tracked model into the shared remote model. Returns nil when
    /// no model has been reported so the field is omitted entirely.
    func remoteModelInfo() -> RemoteModelInfo? {
        guard let model, !model.name.isEmpty else { return nil }
        return RemoteModelInfo(
            name: model.name,
            reasoningEffort: model.reasoningEffort,
            contextTier: model.contextTier
        )
    }

    /// Convert the tracked model catalog into the shared remote list. Returns nil
    /// when the catalog is absent or empty so the field is omitted entirely (and
    /// the client shows the read-only model line rather than an empty picker).
    func remoteAvailableModels() -> [RemoteAvailableModel]? {
        guard let availableModels, !availableModels.isEmpty else { return nil }
        let mapped = availableModels.compactMap { $0.remoteAvailableModel() }
        return mapped.isEmpty ? nil : mapped
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// One outstanding structured question, mirrored from the extension's heartbeat.
/// `choices` are stored verbatim so a selectable answer can be matched exactly.
struct TrackedUserInput: Codable, Equatable, Identifiable {
    var requestId: String
    var question: String
    var choices: [String]
    var allowFreeform: Bool
    var requestedAt: String
    var agentId: String?

    var id: String { requestId }

    func remoteRequest() -> RemoteUserInputRequest {
        RemoteUserInputRequest(
            requestId: requestId,
            question: question,
            choices: choices,
            allowFreeform: allowFreeform,
            requestedAt: Self.date(from: requestedAt) ?? Date(),
            agentId: agentId
        )
    }

    private static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

/// One outstanding elicitation, mirrored from the extension's heartbeat. `schema`
/// is carried verbatim so the client renders the exact form the agent requested.
struct TrackedElicitation: Codable, Equatable, Identifiable {
    var requestId: String
    var message: String
    var mode: String?
    var url: String?
    var schema: RemoteJSONValue?
    var elicitationSource: String?
    var requestedAt: String
    var agentId: String?

    var id: String { requestId }

    func remoteRequest() -> RemoteElicitationRequest {
        RemoteElicitationRequest(
            requestId: requestId,
            message: message,
            mode: mode,
            url: url,
            schema: schema,
            elicitationSource: elicitationSource,
            requestedAt: Self.date(from: requestedAt) ?? Date(),
            agentId: agentId
        )
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

/// The session's effective model, mirrored from the extension heartbeat.
struct TrackedModel: Codable, Equatable {
    var name: String
    var reasoningEffort: String?
    var contextTier: String?
}

/// One switchable model, mirrored from the extension heartbeat's catalog. Maps to
/// the shared `RemoteAvailableModel`. `id`/`name` are decoded as optional so a
/// single malformed entry is dropped rather than failing the whole heartbeat
/// decode; the extension always emits both for real entries.
struct TrackedAvailableModel: Codable, Equatable {
    var id: String?
    var name: String?
    var supportedReasoningEfforts: [String]?
    var defaultReasoningEffort: String?
    var longContextAvailable: Bool?
    var disabled: Bool?
    var category: String?

    func remoteAvailableModel() -> RemoteAvailableModel? {
        guard let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
        return RemoteAvailableModel(
            id: id,
            name: name,
            supportedReasoningEfforts: supportedReasoningEfforts,
            defaultReasoningEffort: defaultReasoningEffort,
            longContextAvailable: longContextAvailable,
            disabled: disabled,
            category: category
        )
    }
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
