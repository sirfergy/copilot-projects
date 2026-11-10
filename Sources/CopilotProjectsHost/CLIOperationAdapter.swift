import Foundation
import CryptoKit
import Darwin
import CopilotProjectsProtocol

enum CLISDKOperationKind: String, Codable {
    case answerUserInput = "answer-user-input"
    case answerElicitation = "answer-elicitation"
    case setModel = "set-model"
    case sessionSend = "session-send"
    case sessionAbort = "session-abort"
    case sessionBounce = "session-bounce"
    case setSessionBudget = "set-session-budget"
    case answerSessionBudget = "answer-session-budget"
    /// Asked by the host before parking; never offered to remote clients.
    case sessionParkCheck = "session-park-check"
}

public struct CLIOperationRequest: Equatable, Sendable {
    public let operationId: String
    public let conversationEpoch: String

    public static func parse(
        operationId: String?,
        conversationEpoch: String?
    ) -> CLIOperationRequestParse {
        switch (operationId, conversationEpoch) {
        case (nil, nil):
            return .legacy
        case (.some(let operationId), .some(let conversationEpoch)):
            guard validToken(operationId, maximumBytes: 128),
                  validToken(conversationEpoch, maximumBytes: 512) else {
                return .invalid
            }
            return .correlated(CLIOperationRequest(
                operationId: operationId,
                conversationEpoch: conversationEpoch
            ))
        default:
            return .invalid
        }
    }

    private static func validToken(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7e
            }
    }
}

public enum CLIOperationRequestParse: Equatable, Sendable {
    case legacy
    case correlated(CLIOperationRequest)
    case invalid
}

enum CLISubmittedOperationOutcome: Equatable {
    case notFound
    case pendingHandoff
    case accepted
    case applied
    case rejected
    case indeterminate
    case conflict
}

struct CLIOperationHandoffMetadata {
    let copilotSessionId: String
    let operationId: String
    let conversationEpoch: String
    let kind: String
    let payloadFingerprint: String
}

struct CLIOperationAdapter {
    private static let handoffSuffixes = [
        "user-input-response.json",
        "elicitation-response.json",
        "set-model-request.json",
        "session-send.json",
        "session-abort.json",
        "session-bounce.json",
        "set-session-budget.json",
        "answer-session-budget.json",
        "session-park-check.json",
    ]

    /// Whether a host request is still waiting for the tracker to take it.
    func hasPendingHandoff(sessionId: String) -> Bool {
        Self.handoffSuffixes.contains { suffix in
            FileManager.default.fileExists(atPath: SessionArtifacts.cliOperationHandoffURL(
                sessionId: sessionId, suffix: suffix, sessionsDirectory: activityDirectory
            ).path)
        }
    }

    private struct FingerprintEnvelope<Payload: Encodable>: Encodable {
        let kind: String
        let payload: Payload
    }

    private struct ExistingOperationHandoff: Decodable {
        let operationId: String?
        let conversationEpoch: String?
        let kind: String?
        let payloadFingerprint: String?
    }

    private struct BoundSnapshot {
        let snapshot: AgentActivitySnapshot
        let copilotSessionId: String
    }

    private enum BoundSnapshotResult {
        case ready(BoundSnapshot)
        case notReady
        case epochMismatch
    }

    private enum AtomicPublishResult {
        case published
        case conflict
        case failed
    }

    let activityDirectory: URL
    let resumeMarkerDirectory: URL

    /// The snapshot if it is fresh when read. `now` is consulted only after the
    /// read, so a snapshot published after the caller first took the time
    /// isn't judged future-dated.
    func loadFreshSnapshot(
        sessionId: String,
        now: () -> Date
    ) -> AgentActivitySnapshot? {
        loadFresh(sessionId: sessionId, now: now)?.snapshot
    }

    private func loadFresh(
        sessionId: String,
        now: () -> Date
    ) -> (snapshot: AgentActivitySnapshot, readAt: Date)? {
        guard let snapshot = load(sessionId: sessionId) else { return nil }
        let readAt = now()
        guard snapshot.isFresh(at: readAt) else { return nil }
        return (snapshot, readAt)
    }

    private func load(sessionId: String) -> AgentActivitySnapshot? {
        let url = SessionArtifacts.cliAgentActivityURL(
            sessionId: sessionId,
            sessionsDirectory: activityDirectory
        )
        guard let data = try? Data(contentsOf: url),
              data.count <= 2 * 1_024 * 1_024 else {
            return nil
        }
        return try? JSONDecoder().decode(AgentActivitySnapshot.self, from: data)
    }

    /// Publishes the operation's handoff, or answers a retry of one already taken.
    /// `blocksInput` and `isReady` refusals answer `.conflict` (try again);
    /// `validate` refusals answer `.invalid` (final).
    func submit<Payload: Encodable, Handoff: Encodable>(
        sessionId: String,
        kind: CLISDKOperationKind,
        operation: CLIOperationRequest?,
        fingerprintPayload: Payload,
        handoffSuffix: String,
        now: () -> Date,
        blocksInput: () -> Bool = { false },
        isReady: (AgentActivitySnapshot) -> Bool = { _ in true },
        validate: (AgentActivitySnapshot) -> Bool,
        makeHandoff: (CLIOperationHandoffMetadata) -> Handoff
    ) -> RemoteUserInputResult {
        // Every handoff carries an operation identity so the tracker can publish its receipt.
        guard let operation,
              let fingerprint = Self.payloadFingerprint(kind: kind, payload: fingerprintPayload) else {
            return .invalid
        }
        // A retry whose first reply was lost gets the first answer whatever the
        // session's state is now: a receipt proves the tracker took it, even in a
        // snapshot too old to judge readiness by, and a matching handoff is still
        // waiting for the tracker.
        let snapshot = load(sessionId: sessionId)
        if let snapshot, let replay = replayResult(
            snapshot: snapshot,
            operation: operation,
            kind: kind,
            payloadFingerprint: fingerprint
        ) {
            return replay
        }

        let handoffURL = SessionArtifacts.cliOperationHandoffURL(
            sessionId: sessionId,
            suffix: handoffSuffix,
            sessionsDirectory: activityDirectory
        )
        if let existing = existingHandoffResult(
            sessionId: sessionId,
            targetURL: handoffURL,
            operation: operation,
            kind: kind,
            payloadFingerprint: fingerprint
        ) {
            return existing
        }
        if blocksInput() { return .conflict }

        let readAt = now()
        guard let snapshot, snapshot.isFresh(at: readAt) else { return .conflict }
        let bound: BoundSnapshot
        switch bind(
            snapshot,
            sessionId: sessionId,
            correlatedEpoch: operation.conversationEpoch,
            now: readAt
        ) {
        case .ready(let value):
            bound = value
        case .notReady:
            return .conflict
        case .epochMismatch:
            return .epochMismatch
        }
        guard isReady(bound.snapshot) else { return .conflict }
        guard validate(bound.snapshot) else { return .invalid }

        let metadata = CLIOperationHandoffMetadata(
            copilotSessionId: bound.copilotSessionId,
            operationId: operation.operationId,
            conversationEpoch: operation.conversationEpoch,
            kind: kind.rawValue,
            payloadFingerprint: fingerprint
        )
        guard let encoded = try? JSONEncoder().encode(makeHandoff(metadata)) else {
            return .invalid
        }
        switch Self.atomicallyPublish0600(encoded, to: handoffURL) {
        case .published:
            return .accepted
        case .conflict:
            return .conflict
        case .failed:
            return .invalid
        }
    }

    /// The fresh snapshot a receipt-correlated operation would bind to right
    /// now, or nil when one would be refused before its payload is validated.
    func loadReceiptBoundSnapshot(
        sessionId: String,
        now: () -> Date
    ) -> AgentActivitySnapshot? {
        guard let loaded = loadFresh(sessionId: sessionId, now: now),
              let epoch = loaded.snapshot.remoteOperationProjection(at: loaded.readAt)
                .conversationEpoch,
              case .ready(let bound) = bind(
                loaded.snapshot,
                sessionId: sessionId,
                correlatedEpoch: epoch,
                now: loaded.readAt
              ) else {
            return nil
        }
        return bound.snapshot
    }

    func submittedOperationOutcome(
        sessionId: String,
        kind: CLISDKOperationKind,
        operation: CLIOperationRequest,
        payloadFingerprint: String,
        handoffSuffix: String,
        now: () -> Date
    ) -> CLISubmittedOperationOutcome {
        let loaded = loadFresh(sessionId: sessionId, now: now)
        let currentEpochBound: Bool
        if let loaded {
            switch bind(
                loaded.snapshot,
                sessionId: sessionId,
                correlatedEpoch: nil,
                now: loaded.readAt
            ) {
            case .ready:
                let matchingId = (loaded.snapshot.operationReceipts ?? []).filter {
                    $0.operationId == operation.operationId
                        && $0.conversationEpoch == operation.conversationEpoch
                }
                if !matchingId.isEmpty {
                    guard matchingId.allSatisfy({
                        $0.kind == kind.rawValue
                            && $0.payloadFingerprint == payloadFingerprint
                            && $0.state != nil
                            && $0.updatedAtMilliseconds != nil
                    }) else {
                        return .conflict
                    }
                    let newest = matchingId.max { lhs, rhs in
                        let lhsTerminal = lhs.state != .accepted
                        let rhsTerminal = rhs.state != .accepted
                        if lhsTerminal != rhsTerminal {
                            return !lhsTerminal && rhsTerminal
                        }
                        return (lhs.updatedAtMilliseconds ?? 0) < (rhs.updatedAtMilliseconds ?? 0)
                    }
                    let projection = loaded.snapshot.remoteOperationProjection(at: loaded.readAt)
                    switch newest?.state {
                    case .applied:
                        return .applied
                    case .rejected:
                        return .rejected
                    case .indeterminate, .none:
                        return .indeterminate
                    case .accepted:
                        return projection.support == .receipts
                            && projection.conversationEpoch == operation.conversationEpoch
                            ? .accepted
                            : .indeterminate
                    }
                }
                let projection = loaded.snapshot.remoteOperationProjection(at: loaded.readAt)
                currentEpochBound = projection.support == .receipts
                    && projection.conversationEpoch == operation.conversationEpoch
            case .notReady, .epochMismatch:
                currentEpochBound = false
            }
        } else {
            currentEpochBound = false
        }

        let handoffURL = SessionArtifacts.cliOperationHandoffURL(
            sessionId: sessionId,
            suffix: handoffSuffix,
            sessionsDirectory: activityDirectory
        )
        for suffix in Self.handoffSuffixes {
            let url = SessionArtifacts.cliOperationHandoffURL(
                sessionId: sessionId,
                suffix: suffix,
                sessionsDirectory: activityDirectory
            )
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let existing = try? JSONDecoder().decode(
                    ExistingOperationHandoff.self,
                    from: data
                  ),
                  existing.operationId == operation.operationId else {
                continue
            }
            guard url == handoffURL,
                  existing.conversationEpoch == operation.conversationEpoch,
                  existing.kind == kind.rawValue,
                  existing.payloadFingerprint == payloadFingerprint else {
                return .conflict
            }
            if currentEpochBound,
               let loaded,
               let actionKind = RemoteSessionActionKind(rawValue: kind.rawValue),
               loaded.snapshot.workflow?.supports(actionKind, at: loaded.readAt) == true {
                return .pendingHandoff
            }
            return .indeterminate
        }
        return .notFound
    }

    private func bind(
        _ snapshot: AgentActivitySnapshot,
        sessionId: String,
        correlatedEpoch: String?,
        now: Date
    ) -> BoundSnapshotResult {
        guard !snapshot.reportsTerminalDisconnect,
              let copilotSessionId = readCopilotSessionId(sessionId: sessionId) else {
            return .notReady
        }

        let projection = snapshot.remoteOperationProjection(at: now)
        if let correlatedEpoch {
            guard projection.support == .receipts else { return .notReady }
            guard projection.conversationEpoch == correlatedEpoch,
                  snapshot.copilotSessionId == copilotSessionId else {
                return .epochMismatch
            }
        } else {
            guard projection.support != .unavailable else { return .notReady }
            if projection.support == .receipts,
               snapshot.copilotSessionId != copilotSessionId {
                return .notReady
            }
        }

        return .ready(BoundSnapshot(
            snapshot: snapshot,
            copilotSessionId: copilotSessionId
        ))
    }

    private func readCopilotSessionId(sessionId: String) -> String? {
        let url = SessionArtifacts.cliCopilotSessionMarkerURL(
            sessionId: sessionId,
            sessionsDirectory: resumeMarkerDirectory
        )
        guard let value = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func replayResult(
        snapshot: AgentActivitySnapshot,
        operation: CLIOperationRequest,
        kind: CLISDKOperationKind,
        payloadFingerprint: String
    ) -> RemoteUserInputResult? {
        let matchingId = (snapshot.operationReceipts ?? []).filter {
            $0.operationId == operation.operationId
                && $0.conversationEpoch == operation.conversationEpoch
        }
        guard !matchingId.isEmpty else { return nil }
        guard matchingId.allSatisfy({
            $0.kind == kind.rawValue
                && $0.payloadFingerprint == payloadFingerprint
                && $0.state != nil
                && $0.updatedAtMilliseconds != nil
        }) else {
            return .conflict
        }
        return .accepted
    }

    private func existingHandoffResult(
        sessionId: String,
        targetURL: URL,
        operation: CLIOperationRequest,
        kind: CLISDKOperationKind,
        payloadFingerprint: String
    ) -> RemoteUserInputResult? {
        for suffix in Self.handoffSuffixes {
            let url = SessionArtifacts.cliOperationHandoffURL(
                sessionId: sessionId,
                suffix: suffix,
                sessionsDirectory: activityDirectory
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            guard let data = try? Data(contentsOf: url),
                  let existing = try? JSONDecoder().decode(
                    ExistingOperationHandoff.self,
                    from: data
                  ) else {
                if url == targetURL { return .conflict }
                continue
            }
            if url == targetURL {
                guard existing.operationId == operation.operationId,
                      existing.conversationEpoch == operation.conversationEpoch else {
                    return .conflict
                }
            }
            guard existing.operationId == operation.operationId,
                  existing.conversationEpoch == operation.conversationEpoch else {
                continue
            }
            guard url == targetURL,
                  existing.kind == kind.rawValue,
                  existing.payloadFingerprint == payloadFingerprint else {
                return .conflict
            }
            return .accepted
        }
        return nil
    }

    static func payloadFingerprint<Payload: Encodable>(
        kind: CLISDKOperationKind,
        payload: Payload
    ) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(FingerprintEnvelope(
            kind: kind.rawValue,
            payload: payload
        )) else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func atomicallyPublish0600(
        _ data: Data,
        to url: URL
    ) -> AtomicPublishResult {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(
            ".\(UUID().uuidString).operation.tmp"
        )
        guard FileManager.default.createFile(
            atPath: temporary.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            return .failed
        }
        guard link(temporary.path, url.path) == 0 else {
            let result: AtomicPublishResult = errno == EEXIST ? .conflict : .failed
            try? FileManager.default.removeItem(at: temporary)
            return result
        }
        try? FileManager.default.removeItem(at: temporary)
        return .published
    }
}

extension SessionArtifacts {
    static func cliAgentActivityURL(
        sessionId: String,
        sessionsDirectory: URL
    ) -> URL {
        sessionsDirectory.appendingPathComponent(
            "\(sessionId).agent-activity.json"
        )
    }

    static func cliCopilotSessionMarkerURL(
        sessionId: String,
        sessionsDirectory: URL
    ) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionId).copilot-session")
    }

    static func cliOperationHandoffURL(
        sessionId: String,
        suffix: String,
        sessionsDirectory: URL
    ) -> URL {
        sessionsDirectory.appendingPathComponent("\(sessionId).\(suffix)")
    }
}
