import Foundation
import CopilotProjectsCore

enum FooterActivity: Equatable {
    case working
    case idle
    case unknown
}

/// Reducer for advisory status evidence. Hooks remain authoritative; a sustained
/// working footer may recover missed running state, while liveness and an observed
/// return to the idle footer may demote stale activity.
struct ActivityTracker {
    private var footerIdleTicks: [String: Int] = [:]
    private var footerWorkingTicks: [String: Int] = [:]
    private var footerSawWorking: Set<String> = []

    mutating func shouldPromoteFromFooter(
        sessionId: String,
        currentStatus: SessionStatus,
        activity: FooterActivity
    ) -> Bool {
        guard currentStatus == .idle else {
            footerWorkingTicks[sessionId] = nil
            return false
        }
        guard activity == .working else {
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

    mutating func observeFooter(
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

    mutating func retain(activeSessionIds: Set<String>) {
        footerIdleTicks = footerIdleTicks.filter { activeSessionIds.contains($0.key) }
        footerWorkingTicks = footerWorkingTicks.filter { activeSessionIds.contains($0.key) }
        footerSawWorking = footerSawWorking.intersection(activeSessionIds)
    }

    mutating func reset(sessionId: String) {
        footerIdleTicks[sessionId] = nil
        footerWorkingTicks[sessionId] = nil
        footerSawWorking.remove(sessionId)
    }

    static func livenessShouldDemote(
        currentStatus: SessionStatus,
        hasLiveAgent: Bool
    ) -> Bool {
        (currentStatus == .running || currentStatus == .waiting) && !hasLiveAgent
    }

    static func canPromoteIdleFromFooter(
        backgroundAgentsActive: Bool,
        hasLiveAgent: Bool,
        supportsSessionIdleHook: Bool
    ) -> Bool {
        !backgroundAgentsActive && hasLiveAgent && !supportsSessionIdleHook
    }
}

struct StatusEventClock {
    private var latestTimestamp: [String: Int64] = [:]

    mutating func shouldApply(sessionId: String, timestamp: Int64?) -> Bool {
        guard let timestamp else { return true }
        if let latest = latestTimestamp[sessionId], timestamp < latest {
            return false
        }
        latestTimestamp[sessionId] = timestamp
        return true
    }

    mutating func seed(sessionId: String, timestamp: Int64?) {
        guard let timestamp else { return }
        latestTimestamp[sessionId] = max(latestTimestamp[sessionId] ?? timestamp, timestamp)
    }

    func timestamp(for sessionId: String) -> Int64? {
        latestTimestamp[sessionId]
    }

    mutating func reset(sessionId: String) {
        latestTimestamp[sessionId] = nil
    }
}
