import Foundation

/// Identifies an ordered host injection, not an SDK operation or proof that a
/// command finished executing. Retries retain both the request ID and delivery.
public struct RemoteControlDelivery: Codable, Equatable, Sendable {
    public static let maximumSequence: Int64 = 9_007_199_254_740_991

    public let epoch: String
    public let sequence: Int64

    public init(epoch: String, sequence: Int64) {
        self.epoch = epoch
        self.sequence = sequence
    }

    public var isValid: Bool {
        UUID(uuidString: epoch) != nil
            && sequence > 0
            && sequence <= Self.maximumSequence
    }
}

public enum RemoteControlDeliverySupport: Equatable, Sendable {
    case legacy
    case replaySafe(epoch: String)
    case unavailable
}

public extension RemoteProtocolInfo {
    static let replaySafeControl = "replay-safe-control"

    var controlDeliverySupport: RemoteControlDeliverySupport {
        guard supports(Self.replaySafeControl) else { return .legacy }
        guard let rawEpoch = controlDeliveryEpoch,
              let epoch = UUID(uuidString: rawEpoch) else {
            return .unavailable
        }
        return .replaySafe(epoch: epoch.uuidString)
    }

    /// The live host supplies its replay ledger's lifetime; static protocol
    /// metadata alone must not promise replay protection without that ledger.
    func supportingReplaySafeControl(epoch: String) -> RemoteProtocolInfo {
        let supported = supports(Self.replaySafeControl)
            ? capabilities
            : capabilities + [Self.replaySafeControl]
        return RemoteProtocolInfo(
            revision: revision,
            capabilities: supported,
            controlDeliveryEpoch: epoch
        )
    }
}
