import CopilotProjectsCore
import Darwin
import Foundation

// Temporary: the shadow run for making the tracker the only source of session status.
//
// Each footer poll, this works out what every session would show if only its tracker
// decided and logs where that differs from what is shown. A reading the tracker cannot
// vouch for holds what tracker-only last showed, and no footer stands in for it. It
// changes nothing a user sees and has no switch.
//
// The PR that removes the other status sources deletes all of it: this file,
// `AppModel.statusShadow`, the `polled` lines in `reconcileAgentFooters`,
// Tests/StatusShadowTests.swift and scripts/status-shadow-report.py.
struct StatusShadow {
    /// One line of `status-shadow.jsonl`. A line is written when a comparison changes:
    /// `shown` differing from `tracker` starts a disagreement, and the next line for
    /// the same `sid` and `what` ends it. Absent fields were nil.
    struct Line: Encodable {
        var t: Int64
        /// When this app launch began. A new value means the app restarted.
        var run: Int64
        var sid: String
        /// `status`: the attention label. `send`: whether a remote prompt would be sent.
        var what: String
        var shown: String?
        var tracker: String?
        var state: State?
        /// The comparison stopped: the session closed, the Mac slept, or (for `send`)
        /// the tracker's own reading decides again, so the poll no longer reads the
        /// footer.
        var over: Bool?

        // What decided `shown`.
        var status: SessionStatus?
        var runtimeDerived: Bool?
        var statusAt: Int64?
        var pending: Bool?
        var live: Bool?
        var footer: String?
        /// Today's reading of the tracker on a poll that read the footer: `unknown`
        /// when prompt state or ownership holds it back, `none` when there is none.
        var gate: String?

        // What decided `tracker`.
        var updatedAt: String?
        var turn: Bool?
        var scheduled: Bool?
        var error: String?
        var runtime: RuntimeActivitySnapshot?
    }

    /// Where a tracker-only value came from.
    enum State: String, Encodable {
        /// The tracker's own reading.
        case alive
        /// The reading was stale or unusable, or the snapshot was not the tab
        /// owner's, so the status tracker-only last showed stands.
        case held
        /// The agent process exited, the tracker lost its connection to the CLI, or
        /// the app's 45 s missing-tracker warning is up: idle, and no send.
        case gone
    }

    private struct Key: Hashable {
        var what: String
        var sid: String
    }

    /// The log rotates once to `status-shadow.jsonl.1`, so it holds at most twice this.
    static let maximumBytes = 16 * 1_024 * 1_024

    let url: URL
    let queue = DispatchQueue(label: "copilot-projects.status-shadow", qos: .utility)
    private let run = Int64(Date().timeIntervalSince1970 * 1_000)
    private let maximumBytes: Int
    /// The comparisons that currently disagree, and how.
    private var open: [Key: String] = [:]
    /// The status tracker-only last showed for each session.
    fileprivate var held: [String: SessionStatus] = [:]
    /// The last pass, on the wall clock and on the uptime clock, which stops
    /// while the Mac sleeps.
    private var lastPass: (date: Date, uptime: TimeInterval)?

    init(directory: URL, maximumBytes: Int = StatusShadow.maximumBytes) {
        url = directory.appendingPathComponent("status-shadow.jsonl", isDirectory: false)
        self.maximumBytes = maximumBytes
    }

    /// What a session would show if only its tracker decided. A reading that is stale
    /// or unusable holds `held` and takes no send, which is what the app does today
    /// with such a reading: `projectedStatus` keeps the status and `promptEligibility`
    /// is busy. The Nov 11 run let the terminal footer stand in, and each "tracker
    /// dead" class came from that: an unreadable footer read as idle, and a footer
    /// that reads working while the CLI waits on a background agent read as running.
    /// `gone`: the agent process exited, or the 45 s missing-tracker warning is up.
    static func trackerOnly(
        _ snapshot: AgentActivitySnapshot?, held: SessionStatus, gone: Bool, now: Date
    ) -> (state: State, status: SessionStatus, sendReady: Bool) {
        if let snapshot, snapshot.isFresh(at: now), !snapshot.reportsTerminalDisconnect {
            let working: Bool?
            switch snapshot.runtimeForegroundActivity(
                expectedSessionId: snapshot.copilotSessionId, now: now,
                minimumObservationMilliseconds: nil
            ) {
            case .working: working = true
            case .idle: working = false
            // This CLI has no `isProcessing` (an older one, or a remote session), so
            // the tracker's turn events are its reading.
            case nil: working = snapshot.foregroundTurnActive || snapshot.scheduledTurnActive
            // No usable reading: it is older than 15 s, its query failed, or the
            // tracker withdrew it when a turn began. In the Nov 11 run turn events
            // stood in here and called a session ready as its turn was starting.
            case .unknown: working = nil
            }
            if let working {
                // A scheduled turn shows as idle, as it does today. A pending question
                // shows as waiting through `Session.displayStatus`.
                return (
                    .alive, working && !snapshot.scheduledTurnActive ? .running : .idle,
                    !working && !snapshot.hasPendingInput
                )
            }
        }
        return gone || snapshot?.reportsTerminalDisconnect == true
            ? (.gone, .idle, false) : (.held, held, false)
    }

    /// Logs a line when this comparison differs from the last one for the session.
    /// `read` is the footer the poll read, with today's reading of the tracker.
    mutating func note(
        _ what: String, session: Session, shown: String, tracker: String, state: State,
        read: (runtime: ForegroundActivity?, footer: FooterActivity)?, live: Bool,
        statusAt: Int64?, now: Date
    ) {
        let key = Key(what: what, sid: session.id)
        let kind = shown == tracker ? nil : "\(shown)|\(tracker)|\(state)"
        guard open[key] != kind else { return }
        open[key] = kind
        let snapshot = session.agentActivity
        write(Line(
            t: Self.milliseconds(now), run: run, sid: session.id, what: what,
            shown: shown, tracker: tracker, state: state,
            status: session.status, runtimeDerived: session.statusIsRuntimeDerived,
            statusAt: statusAt, pending: session.hasPendingInput, live: live,
            footer: read.map { "\($0.footer)" },
            gate: read.map { $0.runtime.map { "\($0)" } ?? "none" },
            updatedAt: snapshot?.updatedAt, turn: snapshot?.foregroundTurnActive,
            scheduled: snapshot?.scheduledTurnActive, error: snapshot?.error,
            runtime: snapshot?.runtimeActivity
        ))
    }

    /// Ends a disagreement whose comparison no longer applies.
    mutating func end(_ what: String, sid: String, now: Date) {
        guard open.removeValue(forKey: Key(what: what, sid: sid)) != nil else { return }
        write(Line(t: Self.milliseconds(now), run: run, sid: sid, what: what, over: true))
    }

    /// Ends the disagreements of sessions that have closed.
    mutating func end(except sessionIds: Set<String>, now: Date) {
        for key in open.keys.filter({ !sessionIds.contains($0.sid) }) {
            end(key.what, sid: key.sid, now: now)
        }
    }

    /// Ends every disagreement at the last pass before the Mac slept. No pass runs
    /// during a sleep, so one left open was measured across it: in the Nov 11 run
    /// 229 of the 231 lasting disagreements spanned a sleep, which was 60 h of
    /// their 60 h 12 m. One that still holds after the wake starts again there.
    mutating func endAcrossSleep(now: Date, uptime: TimeInterval) {
        defer { lastPass = (now, uptime) }
        guard let lastPass,
              now.timeIntervalSince(lastPass.date) - (uptime - lastPass.uptime) > 1 else { return }
        end(except: [], now: lastPass.date)
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970 * 1_000)
    }

    /// Appends off the main actor: an endpoint-security agent can hold an `open()`
    /// for tens of milliseconds.
    private func write(_ line: Line) {
        queue.async { [url, maximumBytes] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var data = try? encoder.encode(line) else { return }
            data.append(0x0A)
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int,
               size + data.count > maximumBytes {
                let previous = url.appendingPathExtension("1")
                try? fm.removeItem(at: previous)
                try? fm.moveItem(at: url, to: previous)
            }
            // A failed open leaves -1, which the write and close then reject.
            let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }
    }
}

extension AppModel {
    /// Compares what each session shows with its tracker-only status. `polled` holds
    /// the sessions whose footer this poll read, with today's reading of the tracker.
    func recordStatusShadow(
        polled: [String: (runtime: ForegroundActivity?, footer: FooterActivity)], now: Date,
        uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        statusShadow.endAcrossSleep(now: now, uptime: uptime)
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let live = remotePromptLiveSessions?(agentProcessNames) ?? liveAgentSessions
        var sessionIds: Set<String> = []
        for session in projects.lazy.flatMap(\.sessions) {
            sessionIds.insert(session.id)
            let read = polled[session.id]
            // A nested or replaced Copilot can still be writing this tab's snapshot.
            // Only the tracker that owns the tab's marker speaks for it, the same
            // rule today's reading applies (`runtimeForegroundActivity`).
            var snapshot = session.agentActivity
            if let owner = snapshot?.copilotSessionId,
               verifiedCopilotOwners[session.id] != owner.lowercased() {
                snapshot = nil
            }
            let isLive = live.contains(session.id)
            // The first pass has no tracker-only status to hold, so it starts from
            // the one shown.
            let tracker = StatusShadow.trackerOnly(
                snapshot, held: statusShadow.held[session.id] ?? session.displayStatus,
                gone: !isLive || session.trackerWarning != nil, now: now)
            let statusAt = sessionSemantics.statusClock.timestamp(for: session.id)
            // The same label code, with only the status source swapped. The finished
            // and unread flags are set by past transitions, so they are carried over.
            var trackerOnly = session
            trackerOnly.status = tracker.status
            trackerOnly.agentActivity = tracker.state == .gone ? nil : snapshot
            statusShadow.held[session.id] = trackerOnly.displayStatus
            statusShadow.note(
                "status", session: session, shown: session.attentionLabel,
                tracker: trackerOnly.attentionLabel, state: tracker.state,
                read: read, live: isLive, statusAt: statusAt, now: now
            )
            // Whether a remote prompt would be sent is compared only where the poll
            // read the footer, which today's rule needs. Where the tracker's own
            // reading decides, the poll reads no footer, so one difference goes
            // unmeasured: today a send there also needs an idle footer and a live
            // process, and the tracker-only rule does not.
            guard let read else {
                statusShadow.end("send", sid: session.id, now: now)
                continue
            }
            let shownReady = session.parked == nil && Self.remotePromptEligibility(
                status: session.displayStatus,
                scheduledTurnActive: session.scheduledTurnActive,
                hasPendingQuestions: session.hasPendingInput,
                hasLiveAgent: isLive,
                backgroundOnly: Self.backgroundOnlyPromptEvidence(
                    status: session.status, snapshot: session.agentActivity,
                    backgroundAgentsActive: session.backgroundAgentsActive,
                    now: now, nowMs: nowMs,
                    clockMs: sessionSemantics.promptSafetyClock.timestamp(for: session.id)
                ),
                footerActivity: read.footer,
                foregroundActivity: read.runtime
            ) == .sent
            statusShadow.note(
                "send", session: session, shown: shownReady ? "ready" : "busy",
                tracker: session.parked == nil && tracker.sendReady ? "ready" : "busy",
                state: tracker.state, read: read, live: isLive, statusAt: statusAt, now: now
            )
        }
        statusShadow.end(except: sessionIds, now: now)
    }
}
