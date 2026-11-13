import Foundation

public struct StatusEventClock: Sendable {
    private var latestTimestamp: [String: Int64] = [:]

    public init() {}

    public mutating func shouldApply(
        sessionId: String,
        timestamp: Int64?
    ) -> Bool {
        guard let timestamp else { return true }
        if let latest = latestTimestamp[sessionId], timestamp < latest {
            return false
        }
        latestTimestamp[sessionId] = timestamp
        return true
    }

    public mutating func seed(sessionId: String, timestamp: Int64?) {
        guard let timestamp else { return }
        latestTimestamp[sessionId] = max(
            latestTimestamp[sessionId] ?? timestamp,
            timestamp
        )
    }

    public func timestamp(for sessionId: String) -> Int64? {
        latestTimestamp[sessionId]
    }

    public mutating func reset(sessionId: String) {
        latestTimestamp[sessionId] = nil
    }
}

public struct SessionSemanticsState: Sendable {
    public var statusClock: StatusEventClock
    public var promptSafetyClock: StatusEventClock

    public init(
        statusClock: StatusEventClock = StatusEventClock(),
        promptSafetyClock: StatusEventClock = StatusEventClock()
    ) {
        self.statusClock = statusClock
        self.promptSafetyClock = promptSafetyClock
    }

    public mutating func shouldApplyStatusEvent(
        sessionId: String,
        timestamp: Int64?,
        source: String?
    ) -> Bool {
        guard statusClock.shouldApply(
            sessionId: sessionId,
            timestamp: timestamp
        ) else {
            return false
        }
        if SessionSemantics.advancesPromptSafetyClock(source: source) {
            promptSafetyClock.seed(sessionId: sessionId, timestamp: timestamp)
        }
        return true
    }

    public mutating func recordLocalStatusEvent(
        sessionId: String,
        nowMilliseconds: Int64,
        source: String?
    ) -> (status: Int64, promptSafety: Int64) {
        let effective = max(
            nowMilliseconds,
            statusClock.timestamp(for: sessionId) ?? nowMilliseconds
        )
        statusClock.seed(sessionId: sessionId, timestamp: effective)
        if SessionSemantics.advancesPromptSafetyClock(source: source) {
            promptSafetyClock.seed(sessionId: sessionId, timestamp: effective)
        }
        return (
            effective,
            promptSafetyClock.timestamp(for: sessionId) ?? effective
        )
    }

    public mutating func reset(sessionId: String) {
        statusClock.reset(sessionId: sessionId)
        promptSafetyClock.reset(sessionId: sessionId)
    }
}
