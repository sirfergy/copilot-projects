import Foundation
import CryptoKit
import Darwin

enum CLISDKOperationKind: String, Codable {
    case answerUserInput = "answer-user-input"
    case answerElicitation = "answer-elicitation"
    case setModel = "set-model"
}

struct CLIOperationRequest: Equatable {
    let operationId: String
    let conversationEpoch: String

    static func parse(
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

enum CLIOperationRequestParse: Equatable {
    case legacy
    case correlated(CLIOperationRequest)
    case invalid
}

struct CLIOperationHandoffMetadata {
    let copilotSessionId: String
    let operationId: String?
    let conversationEpoch: String?
    let kind: String?
    let payloadFingerprint: String?
}

struct CLIOperationAdapter {
    private static let handoffSuffixes = [
        "user-input-response.json",
        "elicitation-response.json",
        "set-model-request.json",
    ]

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
        case invalid
        case conflict
    }

    private enum AtomicPublishResult {
        case published
        case conflict
        case failed
    }

    let activityDirectory: URL
    let resumeMarkerDirectory: URL

    func loadFreshSnapshot(
        sessionId: String,
        now: Date
    ) -> AgentActivitySnapshot? {
        let url = SessionArtifacts.cliAgentActivityURL(
            sessionId: sessionId,
            sessionsDirectory: activityDirectory
        )
        guard let data = try? Data(contentsOf: url),
              data.count <= 2 * 1_024 * 1_024,
              let snapshot = try? JSONDecoder().decode(
                AgentActivitySnapshot.self,
                from: data
              ),
              snapshot.isFresh(at: now) else {
            return nil
        }
        return snapshot
    }

    func submit<Payload: Encodable, Handoff: Encodable>(
        sessionId: String,
        kind: CLISDKOperationKind,
        operation: CLIOperationRequest?,
        fingerprintPayload: Payload,
        handoffSuffix: String,
        now: Date,
        validate: (AgentActivitySnapshot) -> Bool,
        makeHandoff: (CLIOperationHandoffMetadata) -> Handoff
    ) -> RemoteUserInputResult {
        let bound: BoundSnapshot
        switch loadBoundSnapshot(
            sessionId: sessionId,
            operation: operation,
            now: now
        ) {
        case .ready(let value):
            bound = value
        case .invalid:
            return .invalid
        case .conflict:
            return .conflict
        }

        let fingerprint: String?
        if operation != nil {
            guard let value = Self.payloadFingerprint(
                kind: kind,
                payload: fingerprintPayload
            ) else {
                return .invalid
            }
            fingerprint = value
        } else {
            fingerprint = nil
        }

        if let operation, let fingerprint {
            if let replay = replayResult(
                snapshot: bound.snapshot,
                operation: operation,
                kind: kind,
                payloadFingerprint: fingerprint
            ) {
                return replay
            }
        }

        let handoffURL = SessionArtifacts.cliOperationHandoffURL(
            sessionId: sessionId,
            suffix: handoffSuffix,
            sessionsDirectory: activityDirectory
        )
        if let operation, let fingerprint {
            if let existing = existingHandoffResult(
                sessionId: sessionId,
                targetURL: handoffURL,
                operation: operation,
                kind: kind,
                payloadFingerprint: fingerprint
            ) {
                return existing
            }
        } else if FileManager.default.fileExists(atPath: handoffURL.path) {
            return .conflict
        }

        guard validate(bound.snapshot) else { return .invalid }

        let metadata = CLIOperationHandoffMetadata(
            copilotSessionId: bound.copilotSessionId,
            operationId: operation?.operationId,
            conversationEpoch: operation?.conversationEpoch,
            kind: operation == nil ? nil : kind.rawValue,
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

    private func loadBoundSnapshot(
        sessionId: String,
        operation: CLIOperationRequest?,
        now: Date
    ) -> BoundSnapshotResult {
        guard let snapshot = loadFreshSnapshot(sessionId: sessionId, now: now),
              !snapshot.reportsTerminalDisconnect,
              TranscriptController.transcriptOwnerAllowsRead(
                sessionId: sessionId,
                directory: resumeMarkerDirectory
              ),
              let copilotSessionId = readCopilotSessionId(sessionId: sessionId) else {
            return .invalid
        }
        guard !TranscriptController.isCopilotSessionQuarantined(
            sessionId: sessionId,
            copilotSessionId: copilotSessionId,
            directory: resumeMarkerDirectory
        ) else {
            return .conflict
        }

        let projection = snapshot.remoteOperationProjection(at: now)
        if let operation {
            guard projection.support == .receipts else { return .invalid }
            guard projection.conversationEpoch == operation.conversationEpoch,
                  snapshot.copilotSessionId == copilotSessionId else {
                return .conflict
            }
        } else {
            guard projection.support != .unavailable else { return .invalid }
            if projection.support == .receipts,
               snapshot.copilotSessionId != copilotSessionId {
                return .conflict
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
