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

public struct ActivityTracker: Sendable {
    private var footerIdleTicks: [String: Int] = [:]
    private var footerWorkingTicks: [String: Int] = [:]
    private var footerSawWorking: Set<String> = []
    private var foregroundIdleTicks: [String: Int] = [:]
    private var disconnectIdleTicks: [String: Int] = [:]

    public init() {}

    public mutating func observeForegroundIdle(
        sessionId: String,
        currentStatus: SessionStatus,
        foregroundTurnActive: Bool
    ) -> Bool {
        guard currentStatus == .running, !foregroundTurnActive else {
            foregroundIdleTicks[sessionId] = nil
            return false
        }
        let ticks = (foregroundIdleTicks[sessionId] ?? 0) + 1
        foregroundIdleTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        foregroundIdleTicks[sessionId] = nil
        return true
    }

    public mutating func observeDisconnectIdle(
        sessionId: String,
        currentStatus: SessionStatus
    ) -> Bool {
        guard currentStatus == .running else {
            disconnectIdleTicks[sessionId] = nil
            return false
        }
        let ticks = (disconnectIdleTicks[sessionId] ?? 0) + 1
        disconnectIdleTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        disconnectIdleTicks[sessionId] = nil
        return true
    }

    public mutating func shouldPromoteFromFooter(
        sessionId: String,
        currentStatus: SessionStatus,
        activity: FooterActivity
    ) -> Bool {
        guard currentStatus == .idle, activity == .working else {
            footerWorkingTicks[sessionId] = nil
            return false
        }
        let ticks = (footerWorkingTicks[sessionId] ?? 0) + 1
        footerWorkingTicks[sessionId] = ticks
        guard ticks >= 2 else { return false }
        footerWorkingTicks[sessionId] = nil
        footerSawWorking.insert(sessionId)
        footerIdleTicks[sessionId] = 0
        return true
    }

    public mutating func observeFooter(
        sessionId: String,
        currentStatus: SessionStatus,
        activity: FooterActivity
    ) -> Bool {
        guard currentStatus == .running || currentStatus == .waiting else {
            reset(sessionId: sessionId)
            return false
        }

        switch activity {
        case .working:
            footerSawWorking.insert(sessionId)
            footerIdleTicks[sessionId] = 0
        case .unknown:
            footerIdleTicks[sessionId] = 0
        case .idle:
            guard footerSawWorking.contains(sessionId) else { return false }
            let ticks = (footerIdleTicks[sessionId] ?? 0) + 1
            footerIdleTicks[sessionId] = ticks
            if ticks >= 2 {
                reset(sessionId: sessionId)
                return true
            }
        }
        return false
    }

    public mutating func retain(activeSessionIds: Set<String>) {
        footerIdleTicks = footerIdleTicks.filter { activeSessionIds.contains($0.key) }
        footerWorkingTicks = footerWorkingTicks.filter { activeSessionIds.contains($0.key) }
        footerSawWorking = footerSawWorking.intersection(activeSessionIds)
        foregroundIdleTicks = foregroundIdleTicks.filter { activeSessionIds.contains($0.key) }
        disconnectIdleTicks = disconnectIdleTicks.filter { activeSessionIds.contains($0.key) }
    }

    public mutating func reset(sessionId: String) {
        footerIdleTicks[sessionId] = nil
        footerWorkingTicks[sessionId] = nil
        footerSawWorking.remove(sessionId)
        foregroundIdleTicks[sessionId] = nil
        disconnectIdleTicks[sessionId] = nil
    }

    public mutating func resetForegroundIdle(sessionId: String) {
        foregroundIdleTicks[sessionId] = nil
    }

    public mutating func resetDisconnectIdle(sessionId: String) {
        disconnectIdleTicks[sessionId] = nil
    }

    public static func livenessShouldDemote(
        currentStatus: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        SessionSemantics.livenessShouldDemote(
            status: currentStatus,
            hasLiveAgent: hasLiveAgent
        )
    }

    public static func canPromoteIdleFromFooter(
        backgroundAgentsActive: Bool,
        hasLiveAgent: Bool,
        supportsSessionIdleHook: Bool
    ) -> Bool {
        SessionSemantics.canPromoteIdleFromFooter(
            backgroundAgentsActive: backgroundAgentsActive,
            hasLiveAgent: hasLiveAgent,
            supportsSessionIdleHook: supportsSessionIdleHook
        )
    }
}

public struct SessionSemanticsState: Sendable {
    public var activityTracker: ActivityTracker
    public var statusClock: StatusEventClock
    public var promptSafetyClock: StatusEventClock

    public init(
        activityTracker: ActivityTracker = ActivityTracker(),
        statusClock: StatusEventClock = StatusEventClock(),
        promptSafetyClock: StatusEventClock = StatusEventClock()
    ) {
        self.activityTracker = activityTracker
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
        activityTracker.reset(sessionId: sessionId)
        statusClock.reset(sessionId: sessionId)
        promptSafetyClock.reset(sessionId: sessionId)
    }
}
