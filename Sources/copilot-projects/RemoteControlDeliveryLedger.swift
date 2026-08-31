import Foundation
import CryptoKit
import CopilotProjectsProtocol

enum RemoteControlKind: String, CaseIterable {
    case prompt
    case input
    case key
    case command

    enum Lane: Hashable {
        case prompt
        case terminal
    }

    var lane: Lane { self == .prompt ? .prompt : .terminal }
}

enum RemoteControlResult: Equatable {
    case sent
    case missing
    case invalid
    case busy
    case forbidden
    case noLiveCopilot
    case epochMismatch
    case superseded
    case fingerprintConflict
    case capacityExceeded

    init(_ result: RemoteTerminalInputResult) {
        switch result {
        case .sent: self = .sent
        case .missing: self = .missing
        case .invalid: self = .invalid
        }
    }

    init(_ result: RemoteCommandResult) {
        switch result {
        case .sent: self = .sent
        case .missing: self = .missing
        case .busy: self = .busy
        case .invalid: self = .invalid
        }
    }

    init(_ result: RemotePromptResult) {
        switch result {
        case .sent: self = .sent
        case .forbidden: self = .forbidden
        case .invalid: self = .invalid
        case .busy: self = .busy
        case .noLiveCopilot: self = .noLiveCopilot
        }
    }
}

/// Keeps one accepted watermark per client/session/lane for this host lifetime.
/// A restart changes the epoch rather than risking replay after losing memory.
/// Live watermarks are never evicted: capacity exhaustion rejects new scopes.
@MainActor
final class RemoteControlDeliveryLedger {
    nonisolated static let maximumScopes = 8_192

    private struct Scope: Hashable {
        let clientId: String
        let sessionId: String
        let lane: RemoteControlKind.Lane
    }

    private struct Accepted {
        let sequence: Int64
        let fingerprint: SHA256.Digest
    }

    let epoch = UUID().uuidString
    private let capacity: Int
    private var accepted: [Scope: Accepted] = [:]

    var scopeCount: Int { accepted.count }

    init(capacity: Int = maximumScopes) {
        precondition((1 ... Self.maximumScopes).contains(capacity))
        self.capacity = capacity
    }

    /// Synchronous on the main actor: lookup precedes the caller's lease/throttle
    /// gate, and only genuine injection acceptance advances a watermark.
    func perform(
        _ message: RemoteClientMessage,
        sessionExists: Bool,
        perform: () -> RemoteControlResult
    ) -> RemoteControlResult {
        guard let kind = RemoteControlKind(rawValue: message.type),
              let clientId = message.clientId,
              !clientId.isEmpty, clientId.utf8.count <= 64,
              let sessionId = message.sessionId,
              !sessionId.isEmpty, sessionId.utf8.count <= 64,
              let requestId = message.requestId,
              !requestId.isEmpty, requestId.utf8.count <= 64,
              let payload = message.data, payload.utf8.count <= 8_192,
              let delivery = message.delivery, delivery.isValid else {
            return .invalid
        }
        guard UUID(uuidString: delivery.epoch) == UUID(uuidString: epoch) else {
            return .epochMismatch
        }
        guard sessionExists else { return .missing }

        let scope = Scope(clientId: clientId, sessionId: sessionId, lane: kind.lane)
        let fingerprint = Self.fingerprint(
            requestId: requestId,
            kind: kind,
            payload: payload,
            conversationEpoch: message.conversationEpoch
        )
        if let previous = accepted[scope] {
            if delivery.sequence < previous.sequence { return .superseded }
            if delivery.sequence == previous.sequence {
                return fingerprint == previous.fingerprint ? .sent : .fingerprintConflict
            }
        } else if accepted.count >= capacity {
            return .capacityExceeded
        }

        let result = perform()
        if result == .sent {
            accepted[scope] = Accepted(sequence: delivery.sequence, fingerprint: fingerprint)
        }
        return result
    }

    /// Called only after a session has been removed from the workspace.
    func removeClosedSession(_ sessionId: String) {
        accepted = accepted.filter { $0.key.sessionId != sessionId }
    }

    private static func fingerprint(
        requestId: String,
        kind: RemoteControlKind,
        payload: String,
        conversationEpoch: String?
    ) -> SHA256.Digest {
        var hash = SHA256()
        for field in [requestId, kind.rawValue, payload, conversationEpoch] {
            guard let field else {
                hash.update(data: Data([0]))
                continue
            }
            hash.update(data: Data([1]))
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return hash.finalize()
    }
}
