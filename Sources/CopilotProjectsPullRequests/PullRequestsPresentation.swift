import Foundation

enum PullRequestsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case needsYou = "Needs you"

    var id: Self { self }

    func goals(in goals: [PullRequestGoal]) -> [PullRequestGoal] {
        self == .all ? goals : goals.filter { $0.needsYouCount > 0 }
    }
}

enum PullRequestsPresentation {
    struct SelectionInputs: Equatable {
        let filter: PullRequestsFilter
        let keys: [PullRequestKey]
    }

    static func hasPartialStatus(_ pr: PullRequestSnapshot) -> Bool {
        pr.isIncomplete || pr.uncountedThreadsCursor != nil
            || (pr.checksFailing && pr.failingRequiredChecks == nil)
    }

    static func sessionlessText(
        isConnected: Bool, sessionsKnown: Bool, isMatchingSessions: Bool, isManualGoal: Bool
    ) -> String {
        guard isConnected else { return "Session unknown" }
        guard sessionsKnown else { return isMatchingSessions ? "Matching sessions…" : "Sessions not matched" }
        return isManualGoal ? "Your goal · no session" : "No session on this goal"
    }

    /// A summary describes the whole goal only when sessionless items agree too.
    static func sharesSessionState(_ goal: PullRequestGoal) -> Bool {
        Set(goal.items.map { $0.session?.id }).count == 1
    }

    static func reasons(
        for item: PullRequestItem, sessionStateInSummary: Bool
    ) -> [PullRequestAttention] {
        item.assessment.reasons.filter {
            !sessionStateInSummary || ($0 != .sessionWaiting && $0 != .noSession)
        }
    }

    static func candidateName(_ name: String, goalName: String) -> String? {
        let name = PullRequestGrouping.goalName(sessionTitle: name)
        guard !name.isEmpty,
              name.caseInsensitiveCompare("Copilot session") != .orderedSame,
              name.caseInsensitiveCompare(goalName) != .orderedSame else { return nil }
        return name
    }

    static func selection(
        _ selected: PullRequestKey?, visible: [PullRequestKey], userChangedFilter: Bool
    ) -> PullRequestKey? {
        if let selected, visible.contains(selected) { return selected }
        return userChangedFilter ? visible.first : nil
    }
}
