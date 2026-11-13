import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol
import Darwin

/// Where a session's tracker-only status came from.
enum TrackerState: String, Encodable {
    /// The tracker's own reading.
    case alive
    /// The reading was stale or unusable, or the snapshot was not the tab
    /// owner's, so the last status stands.
    case held
    /// The agent process exited, the tracker lost its connection to the CLI, or
    /// the app's 45 s missing-tracker warning is up: idle, and no send.
    case gone
}

extension AppModel {
    /// What a session shows, and whether it takes a prompt, when only its tracker
    /// decides. A reading that is stale or unusable holds `held` and takes no
    /// send. `gone`: the agent process exited, or the 45 s missing-tracker
    /// warning is up.
    nonisolated static func trackerOnly(
        _ snapshot: AgentActivitySnapshot?, held: SessionStatus, gone: Bool, now: Date
    ) -> (state: TrackerState, status: SessionStatus, sendReady: Bool) {
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
            // tracker withdrew it when a turn began. In the Nov 11 shadow run turn
            // events stood in here and called a session ready as its turn was
            // starting.
            case .unknown: working = nil
            }
            if let working {
                // A scheduled turn shows as idle, as it always has. A pending
                // question shows as waiting through `Session.displayStatus`.
                return (
                    .alive, working && !snapshot.scheduledTurnActive ? .running : .idle,
                    !working && !snapshot.hasPendingInput
                )
            }
        }
        return gone || snapshot?.reportsTerminalDisconnect == true
            ? (.gone, .idle, false) : (.held, held, false)
    }

    /// The snapshot that speaks for a tab. A nested or replaced Copilot can still
    /// be writing the tab's snapshot file, so only the tracker that owned the
    /// tab's marker at the last scan counts.
    func ownedActivity(_ session: Session) -> AgentActivitySnapshot? {
        guard let snapshot = session.agentActivity else { return nil }
        if let owner = snapshot.copilotSessionId,
           verifiedCopilotOwners[session.id] != owner.lowercased() {
            return nil
        }
        return snapshot
    }

    func runtimeForegroundActivity(
        for session: Session,
        now: Date,
        resolvedOwner: String?? = nil
    ) -> ForegroundActivity? {
        let owner = resolvedOwner ?? resumeMarkerValue(sessionId: session.id, suffix: "copilot-session")
        guard let snapshot = session.agentActivity else {
            return runtimeTrackedOwners[session.id] == owner?.lowercased()
                && owner != nil ? .unknown : nil
        }
        return snapshot.runtimeForegroundActivity(
            expectedSessionId: owner,
            now: now,
            minimumObservationMilliseconds:
                sessionSemantics.promptSafetyClock.timestamp(for: session.id)
        )
    }

    func inputWaitWasResolved(
        for session: Session,
        foreground: ForegroundActivity?,
        now: Date,
        resolvedOwner: String?? = nil
    ) -> Bool {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard foreground != .unknown,
              let wait = inputWaits[session.id],
              let snapshot = session.agentActivity,
              snapshot.isFresh(at: now),
              snapshot.copilotSessionId?.lowercased() == wait.context.rootSessionId.lowercased(),
              snapshot.copilotSessionId?.lowercased()
                == (resolvedOwner ?? resumeMarkerValue(sessionId: session.id, suffix: "copilot-session"))?.lowercased(),
              let epoch = snapshot.conversationEpoch, !epoch.isEmpty,
              snapshot.trackedUserInputs?.isEmpty == true,
              snapshot.trackedElicitations?.isEmpty == true,
              snapshot.pendingPermissionRequestIds?.isEmpty == true,
              let observed = foreground == nil
                ? snapshot.updatedAtMilliseconds
                : snapshot.runtimeActivity?.observedAtMilliseconds,
              observed > wait.timestamp,
              observed <= nowMs else {
            return false
        }
        let sameEpoch = epoch == wait.context.conversationEpoch
        if sameEpoch,
           snapshot.runtimeActivity == nil, snapshot.inputCompletions == nil,
           snapshot.sessionIdleAtMilliseconds == nil {
            return true
        }
        if sameEpoch,
           let completed = snapshot.inputCompletions?[wait.context.senderSessionId.lowercased()],
           completed >= wait.timestamp, completed <= nowMs, completed <= observed {
            return true
        }
        // Whole-session idle is stronger than a child completion and also covers
        // cancellation or a post-crash CLI resume into a new conversationEpoch,
        // where an individual input-completed event in the old epoch is absent.
        if let idleAt = snapshot.sessionIdleAtMilliseconds,
           idleAt > wait.timestamp, idleAt <= nowMs, idleAt <= observed,
           sameEpoch || ((foreground == .idle || foreground == nil)
               && !snapshot.foregroundTurnActive
               && !snapshot.scheduledTurnActive
               && snapshot.activeSubagents.isEmpty) {
            return true
        }
        return false
    }

    func projectedStatus(
        for session: Session,
        foreground: ForegroundActivity?,
        now: Date,
        resolvedOwner: String?? = nil
    ) -> SessionStatus {
        if session.hasPendingInput { return .waiting }
        if session.status == .waiting, !session.statusIsRuntimeDerived {
            guard inputWaitWasResolved(
                for: session,
                foreground: foreground,
                now: now,
                resolvedOwner: resolvedOwner
            ) else {
                return .waiting
            }
            if foreground == nil {
                return session.agentActivity?.foregroundTurnActive == true
                    && !session.scheduledTurnActive ? .running : .idle
            }
        }
        switch foreground {
        case .working:
            return session.scheduledTurnActive ? .idle : .running
        case .idle:
            return .idle
        case .unknown, nil:
            return session.status
        }
    }

    private func reconcileRuntimeActivity(now: Date) {
        withCoalescedProjectPublications {
            restoreCompletedPermissionWaits(now: now)
            var changed = false
            for pi in projects.indices {
                for si in projects[pi].sessions.indices {
                    let session = projects[pi].sessions[si]
                    let foreground = runtimeForegroundActivity(for: session, now: now)
                    guard foreground == .working || foreground == .idle
                        || (session.status == .waiting
                            && inputWaitWasResolved(for: session, foreground: foreground, now: now))
                    else { continue }
                    let status = projectedStatus(for: session, foreground: foreground, now: now)
                    if status != session.status {
                        if session.status == .waiting, !session.statusIsRuntimeDerived,
                           status != .waiting, permissionStatusRestores[session.id] == nil,
                           let timestamp = sessionSemantics.statusClock.timestamp(for: session.id),
                           let promptTimestamp = sessionSemantics.promptSafetyClock.timestamp(for: session.id) {
                            // Certified resolution must survive restart even when no
                            // pre-wait permission snapshot survived with it.
                            persistPermissionStatus(session.id, status, timestamp, promptTimestamp)
                        }
                        var updated = projects[pi].sessions[si]
                        updated.status = status
                        updated.statusIsRuntimeDerived = true
                        updated.statusText = nil
                        if status == .running {
                            updated.runningStartedAtMilliseconds = updated.runningStartedAtMilliseconds
                                ?? trustedForegroundTransitionMilliseconds(
                                    sessionId: session.id,
                                    snapshot: updated.agentActivity
                                )
                                ?? Int64(now.timeIntervalSince1970 * 1_000)
                        } else if status == .idle {
                            updated.runningStartedAtMilliseconds = nil
                            updated.runningStatusTimestampMilliseconds = nil
                            updated.runningRequestIdentity = nil
                        }
                        if status == .running {
                            updated.finishedUnseen = false
                            updated.turnCompleted = false
                            completionPending.remove(session.id)
                            completionSummaryContexts[session.id] = nil
                        }
                        projects[pi].sessions[si] = updated
                        if status != .waiting {
                            elicitationNotificationTokens[session.id] = nil
                            if permissionStatusRestores[session.id] == nil {
                                cancelWaitingNotifications(sessionId: session.id)
                            }
                        }
                        changed = true
                    }
                    if let idleAt = session.agentActivity?.sessionIdleAtMilliseconds,
                       idleAt <= Int64(now.timeIntervalSince1970 * 1_000),
                       idleAt >= (sessionSemantics.statusClock.timestamp(for: session.id) ?? .min),
                       session.agentActivity?.foregroundTurnActive == false,
                       session.agentActivity?.activeSubagents.isEmpty == true {
                        setBackgroundAgentsActive(sessionId: session.id, active: false)
                    }
                    if status == .idle {
                        postCompletionIfReady(sessionId: session.id)
                    }
                }
            }
            dismissAnsweredQuestionNotifications(now: now)
            syncSessionWorkingModels(now: now)
            if changed { updateDockBadge() }
        }
    }

    /// Backstop for flaky agent stop / sessionEnd hooks: a session can only stay
    /// `running`/`waiting` while its shell actually hosts a live agent process.
    /// This never clears status while the agent is genuinely working (unlike a
    /// time-based decay), and clears promptly when the agent exits or crashes.
    func startLivenessReconciler() {
        livenessTimer?.invalidate()
        statusTimer?.invalidate()

        if livenessEnabled {
            reconcileLiveness(markFinished: false)
        } else {
            liveAgentSessions = []
            liveCopilotSessions = []
        }

        reconcileStatus()
        let status = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileStatus() }
        }
        RunLoop.main.add(status, forMode: .common)
        statusTimer = status

        guard livenessEnabled else { return }
        let timer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileLiveness() }
        }
        RunLoop.main.add(timer, forMode: .common)
        livenessTimer = timer
    }

    func startAgentActivityTracking() {
        agentActivityTimer?.invalidate()
        agentActivitySource?.cancel()
        agentActivitySource = nil
        agentActivityRefreshGeneration += 1
        agentActivityRefreshCoolingDown = false
        agentActivityRefreshPending = false

        try? FileManager.default.createDirectory(
            at: agentActivityDirectory,
            withIntermediateDirectories: true
        )
        scanAgentActivityInBackground()

        let fd = open(agentActivityDirectory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                self?.throttledRefreshAgentActivitySnapshots()
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            agentActivitySource = source
        }

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scanAgentActivityInBackground() }
        }
        RunLoop.main.add(timer, forMode: .common)
        agentActivityTimer = timer
    }

    /// Coalesce the watcher's bursty directory events into at most one snapshot
    /// scan per throttle window. Leading-edge (the first event of a burst applies
    /// immediately) with a guaranteed trailing flush, so a sustained write storm
    /// whose inter-event gap is below the window is still reflected promptly —
    /// unlike a resettable trailing debounce, which would keep deferring and only
    /// fire once the storm paused. Bounds the *event-driven* scans to one pass per
    /// `agentActivityRefreshThrottle`; the 10s backstop timer scans independently.
    func throttledRefreshAgentActivitySnapshots() {
        guard !agentActivityRefreshCoolingDown else {
            agentActivityRefreshPending = true
            return
        }
        agentActivityRefreshCoolingDown = true
        scanAgentActivityInBackground()
        scheduleAgentActivityCooldown(generation: agentActivityRefreshGeneration)
    }

    private func scheduleAgentActivityCooldown(generation: Int) {
        agentActivityCooldownScheduler(agentActivityRefreshThrottle) { [weak self] in
            guard let self, generation == self.agentActivityRefreshGeneration else { return }
            if self.agentActivityRefreshPending {
                self.agentActivityRefreshPending = false
                self.scanAgentActivityInBackground()
                self.scheduleAgentActivityCooldown(generation: generation)
            } else {
                self.agentActivityRefreshCoolingDown = false
            }
        }
    }

    /// Scans every session's snapshot, reading the files off the main actor.
    /// A scan asked for while one is reading runs once that one finishes.
    func scanAgentActivityInBackground() {
        agentActivityScanObserver?()
        guard !agentActivityReadInFlight else {
            agentActivityReadQueued = true
            return
        }
        startAgentActivityRead()
    }

    private func startAgentActivityRead() {
        guard !isTerminating else { return }
        agentActivityReadInFlight = true
        let generation = agentActivityRefreshGeneration
        let sessionIds = projects.flatMap { $0.sessions.map(\.id) }
        let cached = agentActivitySnapshotCache.mapValues(\.signature)
        let observations = agentActivityObservations
        let directory = agentActivityDirectory
        let reader = agentActivityReader
        let warningCheck = copilotTrackerWarningMessage
        agentActivityReadQueue.async { [weak self] in
            let reads = reader(sessionIds, directory, cached, { Date() })
            let warningMessage = warningCheck()
            Task { @MainActor [weak self] in
                self?.finishAgentActivityRead(
                    reads, warningMessage: warningMessage, observations: observations, generation: generation
                )
            }
        }
    }

    private func finishAgentActivityRead(
        _ reads: [String: AgentActivityRead],
        warningMessage: String,
        observations: [String: Int],
        generation: Int
    ) {
        agentActivityReadInFlight = false
        var again = agentActivityReadQueued
        agentActivityReadQueued = false
        // Tracking restarted or stopped since this read began.
        if generation == agentActivityRefreshGeneration,
           !applyAgentActivityReads(
               reads, warningMessage: warningMessage, observations: observations, clock: { Date() }
           ) {
            again = true
        }
        if again { startAgentActivityRead() }
    }

    /// Scans every session's snapshot synchronously on the main actor for
    /// deterministic unit tests that assert immediately after.
    func refreshAgentActivitySnapshots(now: Date = Date()) {
        // Trackers keep publishing while the scan runs, so each snapshot is
        // judged when it's applied, after its file was read, rather than when
        // the scan started.
        let readTime = advancingClock(from: now)
        agentActivityScanObserver?()
        let reads = agentActivityReader(
            projects.flatMap { $0.sessions.map(\.id) }, agentActivityDirectory,
            agentActivitySnapshotCache.mapValues(\.signature), readTime
        )
        applyAgentActivityReads(
            reads, warningMessage: copilotTrackerWarningMessage(),
            observations: agentActivityObservations, clock: readTime
        )
    }

    /// Applies a scan's reads to the current sessions. A session the scan didn't
    /// read, or that was observed or changed by a hook after the read began (a
    /// later scan, a single-session load, or a scheduling hook), keeps its state;
    /// returns false when any did, so the caller can scan again.
    @discardableResult
    private func applyAgentActivityReads(
        _ reads: [String: AgentActivityRead],
        warningMessage: String,
        observations: [String: Int],
        clock readTime: () -> Date
    ) -> Bool {
        let fm = FileManager.default
        var nextProjects = projects
        var activityChanged = false
        var startingPromptChanged = false
        var complete = true
        var seenSessionIds: Set<String> = []
        var budgetNotifications: [(projectId: String, sessionId: String)] = []
        for pi in nextProjects.indices {
            for si in nextProjects[pi].sessions.indices {
                let sessionId = nextProjects[pi].sessions[si].id
                seenSessionIds.insert(sessionId)
                guard let read = reads[sessionId],
                      agentActivityObservations[sessionId] == observations[sessionId] else {
                    complete = false
                    continue
                }
                agentActivityObservations[sessionId, default: 0] += 1
                let snapshot: AgentActivitySnapshot?
                switch read.outcome {
                case .missing:
                    agentActivitySnapshotCache.removeValue(forKey: sessionId)
                    snapshot = nil
                case .unchanged:
                    snapshot = agentActivitySnapshotCache[sessionId]?.snapshot
                case .unreadable:
                    // Fail closed without advancing the cached signature, so the
                    // next scan retries rather than serving a stale snapshot.
                    snapshot = nil
                case .read(let signature, let decoded):
                    agentActivitySnapshotCache[sessionId] = (signature, decoded)
                    snapshot = decoded
                }
                // A background read can wait on later files and the main actor, so
                // judge freshness now rather than when the file was read.
                let judgedAt = max(read.readAt, readTime())
                let fresh = snapshot?.isFresh(at: judgedAt) == true ? snapshot : nil
                if let workflow = fresh?.workflow, workflow.isFresh(at: judgedAt),
                   let request = workflow.budgetRequest,
                   let epoch = fresh?.conversationEpoch {
                    let key = "\(epoch):\(request.requestId)"
                    if budgetNotificationKeys[sessionId] != key {
                        budgetNotificationKeys[sessionId] = key
                        budgetNotifications.append((nextProjects[pi].id, sessionId))
                    }
                }
                if let owner = snapshot?.copilotSessionId?.lowercased() {
                    let matchesMarker = owner == resumeMarkerValue(
                        sessionId: sessionId, suffix: "copilot-session"
                    )?.lowercased()
                    verifiedCopilotOwners[sessionId] = matchesMarker ? owner : nil
                    if matchesMarker, snapshot?.runtimeActivity != nil {
                        runtimeTrackedOwners[sessionId] = owner
                    }
                }
                if nextProjects[pi].sessions[si].startingPrompt == nil,
                   let rawPrompt = validatedActivityStartingPrompt(
                       sessionId: sessionId,
                       snapshot: snapshot
                   ) {
                    nextProjects[pi].sessions[si].startingPrompt = rawPrompt
                    activityChanged = true
                    startingPromptChanged = true
                }
                var effectiveFresh = fresh
                if let snapshotKeys = snapshot?.pullRequestKeys, !snapshotKeys.isEmpty {
                    if snapshot?.schemaVersion == AgentActivitySnapshot.currentSchemaVersion,
                       snapshotKeys.contains(Session.activityPullRequestPolicyToken),
                       isActivitySnapshotTrustedForSessionMetadata(
                           sessionId: sessionId,
                           snapshot: snapshot
                       ) {
                        let canonicalFresh = Session.canonicalPullRequestKeys(snapshotKeys, limit: 5)
                        effectiveFresh?.pullRequestKeys = canonicalFresh
                        let existing = Session.canonicalPullRequestKeys(
                            nextProjects[pi].sessions[si].pullRequestKeys, limit: 5
                        )
                        let merged = Session.canonicalPullRequestKeys(
                            (existing ?? []) + (canonicalFresh ?? []), limit: 5
                        )
                        if merged != existing {
                            nextProjects[pi].sessions[si].pullRequestKeys = merged
                            activityChanged = true
                            startingPromptChanged = true
                        }
                    } else {
                        effectiveFresh?.pullRequestKeys = nil
                    }
                }
                if nextProjects[pi].sessions[si].agentActivity != effectiveFresh {
                    var previous = nextProjects[pi].sessions[si].agentActivity
                    if let effectiveFresh {
                        previous?.updatedAt = effectiveFresh.updatedAt
                        previous?.runtimeActivity?.observedAtMilliseconds =
                            effectiveFresh.runtimeActivity?.observedAtMilliseconds
                        previous?.workflow?.observedAtMilliseconds =
                            effectiveFresh.workflow?.observedAtMilliseconds ?? 0
                        previous?.currentIntent = effectiveFresh.currentIntent
                    }
                    activityChanged = activityChanged || previous != effectiveFresh
                    nextProjects[pi].sessions[si].agentActivity = effectiveFresh
                }
                let warning = resolvedTrackerWarning(
                    for: nextProjects[pi].sessions[si],
                    warningMessage: warningMessage,
                    now: judgedAt
                )
                if nextProjects[pi].sessions[si].trackerWarning != warning {
                    nextProjects[pi].sessions[si].trackerWarning = warning
                    activityChanged = true
                }
                if nextProjects[pi].sessions[si].status != .idle,
                   let transitionMs = trustedForegroundTransitionMilliseconds(
                       sessionId: sessionId,
                       snapshot: effectiveFresh
                   ) {
                    let identity = trustedRunningRequestIdentity(sessionId: sessionId, snapshot: effectiveFresh)
                    let existingIdentity = nextProjects[pi].sessions[si].runningRequestIdentity
                    let isNewRequest = existingIdentity != nil
                        && identity != nil
                        && existingIdentity != identity
                        && transitionMs >= (nextProjects[pi].sessions[si].runningStartedAtMilliseconds ?? .min)
                    if nextProjects[pi].sessions[si].runningStartedAtMilliseconds == nil || isNewRequest {
                        nextProjects[pi].sessions[si].runningStartedAtMilliseconds = transitionMs
                        activityChanged = true
                    }
                    if let identity,
                       existingIdentity == nil || isNewRequest,
                       transitionMs >= (nextProjects[pi].sessions[si].runningStartedAtMilliseconds ?? .min) {
                        nextProjects[pi].sessions[si].runningRequestIdentity = identity
                    }
                }

                let scheduledMarkerURL = agentActivityDirectory
                    .appendingPathComponent("\(sessionId).scheduled-turn", isDirectory: false)
                let scheduledMarker = fm.fileExists(atPath: scheduledMarkerURL.path)
                if fresh?.scheduledTurnActive == false {
                    scheduledSnapshotsSuppressed.remove(sessionId)
                }
                let snapshotScheduled = fresh?.scheduledTurnActive == true
                    && !scheduledSnapshotsSuppressed.contains(sessionId)
                let scheduledActive = scheduledMarker || snapshotScheduled
                if nextProjects[pi].sessions[si].scheduledTurnActive != scheduledActive {
                    nextProjects[pi].sessions[si].scheduledTurnActive = scheduledActive
                    activityChanged = true
                }
            }
        }
        return withCoalescedProjectPublications {
            if activityChanged {
                projects = nextProjects
            } else if projectStorage != nextProjects {
                // Keep one authoritative snapshot, including its latest freshness and
                // disconnect timestamps, without redrawing for heartbeat-only changes.
                projectStorage = nextProjects
            }
            if startingPromptChanged {
                save()
            }
            // Drop cache entries for sessions no longer present so the cache can't grow
            // across a long-lived app run that opens and closes many sessions. Filtering
            // ~30 entries is microsecond-cheap, so run it unconditionally — a count-based
            // guard misses the case where one session is closed while another (whose file
            // isn't written yet) is opened, leaving the count unchanged but a stale entry.
            agentActivitySnapshotCache = agentActivitySnapshotCache
                .filter { seenSessionIds.contains($0.key) }
            agentActivityObservations = agentActivityObservations.filter { seenSessionIds.contains($0.key) }
            runtimeTrackedOwners = runtimeTrackedOwners.filter { seenSessionIds.contains($0.key) }
            verifiedCopilotOwners = verifiedCopilotOwners.filter { seenSessionIds.contains($0.key) }
            trackerMissingSince = trackerMissingSince.filter { seenSessionIds.contains($0.key) }
            budgetNotificationKeys = budgetNotificationKeys.filter { seenSessionIds.contains($0.key) }
            reconcileRuntimeActivity(now: readTime())
            reconcileParkedSessions(now: readTime())
            for target in budgetNotifications {
                postNotification(
                    projectId: target.projectId, sessionId: target.sessionId, kind: .permission,
                    title: "Copilot reached its session budget",
                    body: "Open this session to add AI credits or stop the blocked request."
                )
            }
            return complete
        }
    }

    /// Load one session's agent-activity snapshot on the main actor, skipping the
    /// `Data(contentsOf:)` read + JSON decode when the file's signature
    /// (inode+size+mtime) matches the cached one. The caller re-applies the
    /// freshness TTL, so skipping the read never stalls a stale→nil transition.
    /// Scans read through `AgentActivityReader` instead; a scan whose read began
    /// before this load leaves that session for the next scan.
    func loadAgentActivitySnapshot(
        sessionId: String,
        path: String,
        decoder: JSONDecoder,
        fm: FileManager
    ) -> AgentActivitySnapshot? {
        agentActivityObservations[sessionId, default: 0] += 1
        let cached = agentActivitySnapshotCache[sessionId]
        guard let attributes = try? fm.attributesOfItem(atPath: path) else {
            if cached != nil { agentActivitySnapshotCache.removeValue(forKey: sessionId) }
            return nil
        }
        let signature = FileSignature(attributes: attributes)
        if let cached, cached.signature == signature {
            return cached.snapshot
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            // The file exists but the read failed (a transient `open()` denial or a
            // racing writer). Fail closed and DON'T advance the cached signature: the
            // signature mismatch guarantees a retry next scan, so this neither sticks
            // a `nil` against a live signature nor serves a stale snapshot to
            // freshness/promptability decisions in the meantime.
            return nil
        }
        // A present-but-malformed file caches `(signature, nil)` so it isn't
        // re-decoded every scan — only its next real change (new signature) re-reads.
        let snapshot = try? decoder.decode(AgentActivitySnapshot.self, from: data)
        agentActivitySnapshotCache[sessionId] = (signature, snapshot)
        return snapshot
    }

    /// The once-a-second pass, which the status shadow compares on.
    func reconcileStatus() {
        withCoalescedProjectPublications {
            reconcileRuntimeActivity(now: Date())
            // A completion held for background work is posted from a snapshot scan
            // once the tracker's reading is usable. A tracker with no reading (an
            // unsupported or remote CLI runtime) never gets one, so it is retried
            // here, once the stop hook's wait for the background-agent title is over.
            let settled = SessionArtifacts.currentStatusTimestamp()
                - Int64(completionNotificationDelayNanoseconds / 1_000_000)
            for sessionId in completionPending
                where (sessionSemantics.statusClock.timestamp(for: sessionId) ?? .max) <= settled {
                postCompletionIfReady(sessionId: sessionId)
            }
            recordStatusShadow(now: Date())
        }
    }

    /// Drops a session whose agent process has gone to idle and persists that.
    /// With `markFinished`, a top-level session that is not on screen is flagged
    /// finished and unseen.
    private func clearStatusToIdle(pi: Int, si: Int, markFinished: Bool) {
        withCoalescedProjectPublications {
            let sid = projects[pi].sessions[si].id
            cancelWaitingNotifications(sessionId: sid)
            var updated = projects[pi].sessions[si]
            updated.status = .idle
            updated.statusText = nil
            updated.runningStartedAtMilliseconds = nil
            updated.runningStatusTimestampMilliseconds = nil
            updated.runningRequestIdentity = nil
            if markFinished,
               projects[pi].effectiveParentSessionId(for: sid) == nil,
               !isVisible(projectIndex: pi, sessionIndex: si) {
                updated.finishedUnseen = true
            }
            projects[pi].sessions[si] = updated
            let now = SessionArtifacts.currentStatusTimestamp()
            let timestamp = max(now, sessionSemantics.statusClock.timestamp(for: sid) ?? now)
            sessionSemantics.statusClock.seed(sessionId: sid, timestamp: timestamp)
            sessionSemantics.promptSafetyClock.seed(
                sessionId: sid,
                timestamp: timestamp
            )
            SessionArtifacts.persistStatus(
                sessionId: sid,
                status: .idle,
                timestamp: timestamp,
                promptStatusTimestamp: timestamp
            )
            dismissAnsweredQuestionNotifications(sessionId: sid)
        }
    }

    func resolvedTrackerWarning(
        for session: Session,
        warningMessage: String,
        now: Date
    ) -> String? {
        let hasHealthyActivity = session.agentActivity.map { !$0.reportsTerminalDisconnect } ?? false
        guard session.hostId == nil,
              session.parked == nil,
              liveCopilotSessions.contains(session.id),
              !hasHealthyActivity else {
            trackerMissingSince[session.id] = nil
            return nil
        }
        let missingSince = trackerMissingSince[session.id] ?? {
            trackerMissingSince[session.id] = now
            return now
        }()
        return now.timeIntervalSince(missingSince) >= 45 ? warningMessage : nil
    }

    private func reconcileLiveness(markFinished: Bool = true) {
        withCoalescedProjectPublications {
            let snapshot = ProcessTree.snapshot()
            // Sessions whose shell currently hosts a live agent (copilot) process.
            // Also used by scroll-forwarding: a resumed session's terminal is desynced
            // (SwiftTerm restarted in the normal buffer, copilot never re-emits its
            // mouse mode), but copilot's input parser still expects mouse events — so
            // the wheel is force-forwarded as mouse when the session has a live agent.
            let names = agentProcessNames
            liveAgentSessions = ProcessTree.agentSessions(agentNames: names, in: snapshot)
            liveCopilotSessions = names == ["copilot"]
                ? liveAgentSessions
                : ProcessTree.agentSessions(agentNames: ["copilot"], in: snapshot)

            for pi in projects.indices {
                for si in projects[pi].sessions.indices {
                    let sid = projects[pi].sessions[si].id
                    if !liveCopilotSessions.contains(sid) {
                        if projects[pi].sessions[si].trackerWarning != nil {
                            projects[pi].sessions[si].trackerWarning = nil
                        }
                        trackerMissingSince[sid] = nil
                    }
                    if projects[pi].sessions[si].backgroundAgentsActive,
                       !liveAgentSessions.contains(sid) {
                        setBackgroundAgentsActive(sessionId: sid, active: false)
                        backgroundAgentsSuppressed.insert(sid)
                    }
                }
            }

            let hasActive = projects.contains { project in
                project.sessions.contains { $0.status == .running || $0.status == .waiting }
            }
            guard hasActive else { return }

            let liveSessions = liveAgentSessions
            for pi in projects.indices {
                for si in projects[pi].sessions.indices {
                    let status = projects[pi].sessions[si].status
                    guard status == .running || status == .waiting else { continue }
                    if SessionSemantics.livenessShouldDemote(
                        status: status,
                        hasLiveAgent: liveSessions.contains(projects[pi].sessions[si].id)
                    ) {
                        // The agent exited/crashed (active → idle). Flag it as finished &
                        // unseen unless you're looking at it right now.
                        clearStatusToIdle(pi: pi, si: si, markFinished: markFinished)
                    }
                }
            }
        }
    }

    @discardableResult
    func postNotification(
        projectId: String,
        sessionId: String,
        kind: StatusNotificationKind? = nil,
        title: String,
        body: String?,
        reply: RemoteNotificationReply? = nil,
        completionSummaryContext: CompletionSummaryContext? = nil
    ) -> UUID {
        var subtitle: String?
        var isTargetVisible = false
        if let loc = locateIndex(sessionId) {
            isTargetVisible = projects[loc.p].id == projectId
                && isVisible(projectIndex: loc.p, sessionIndex: loc.s)
            if !isTargetVisible {
                projects[loc.p].sessions[loc.s].hasUnread = true
            }
            subtitle = Self.notificationSubtitle(
                projectName: projects[loc.p].name,
                sessionTitle: projects[loc.p].sessions[loc.s].title
            )
        }
        let event = NotificationEvent(
            kind: kind,
            title: title,
            subtitle: subtitle,
            body: body,
            projectId: projectId,
            sessionId: sessionId,
            isTargetVisible: isTargetVisible,
            reply: kind == .completed && completionSummaryContext == nil
                ? completionReply(sessionId: sessionId)
                : reply
        )
        updateDockBadge()
        guard let context = completionSummaryContext else {
            notifications?.post(event)
            return event.id
        }
        let completionClock = sessionSemantics.statusClock.timestamp(for: sessionId)
        // The status clock can't see a conversation rotating, so the reply
        // read after the load must still belong to the finished turn's epoch.
        let completionEpoch = receiptBoundSnapshot(sessionId: sessionId, now: { Date() })?
            .conversationEpoch
        let loadSnapshot = completionTranscriptLoader
        Task { @MainActor [weak self] in
            let summary = await Task.detached {
                await NotificationSummary.loadCompletion(
                    sessionId: sessionId,
                    context: context,
                    loadSnapshot: loadSnapshot
                )
            }.value
            guard let self else { return }
            // Another hook may start a new turn while the transcript is loading.
            // Keep the original alert, but never attach that turn's content to it.
            let stillCurrent = sessionSemantics.statusClock.timestamp(for: sessionId)
                == completionClock
            let reply = stillCurrent ? completionReply(sessionId: sessionId) : nil
            notifications?.post(NotificationEvent(
                id: event.id,
                kind: event.kind,
                title: event.title,
                subtitle: event.subtitle,
                body: stillCurrent ? summary : nil,
                projectId: event.projectId,
                sessionId: event.sessionId,
                isTargetVisible: event.isTargetVisible,
                sentAt: event.sentAt,
                reply: reply?.conversationEpoch == completionEpoch ? reply : nil
            ))
        }
        return event.id
    }

    /// Read from disk at post time: the cached snapshot can lag the turn that
    /// just finished by a heartbeat.
    private func completionReply(sessionId: String) -> RemoteNotificationReply? {
        let clock = advancingClock(from: Date())
        guard let snapshot = receiptBoundSnapshot(sessionId: sessionId, now: clock) else {
            return nil
        }
        return NotificationReplyResolver.completionReply(snapshot: snapshot, now: clock())
    }

    private func receiptBoundSnapshot(sessionId: String, now: () -> Date) -> AgentActivitySnapshot? {
        CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        ).loadReceiptBoundSnapshot(sessionId: sessionId, now: now)
    }

    func postCompletionIfReady(sessionId: String) {
        guard completionPending.contains(sessionId) else { return }
        guard let loc = locateIndex(sessionId) else {
            completionPending.remove(sessionId)
            completionSummaryContexts[sessionId] = nil
            return
        }
        let snapshotActivity = projects[loc.p].sessions[loc.s].agentActivity
        let baseline = foregroundIdleGenerationBaselines[sessionId]
        let scheduledIdleIsCurrent = snapshotActivity?.lastIdleTurnKind == "scheduled"
            && (baseline == nil || (snapshotActivity?.idleGeneration ?? -1) > baseline!)
        if projects[loc.p].sessions[loc.s].scheduledTurnActive || scheduledIdleIsCurrent
        {
            completionPending.remove(sessionId)
            completionSummaryContexts[sessionId] = nil
            projectStorage[loc.p].sessions[loc.s].turnCompleted = true
            foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)
            return
        }
        guard projects[loc.p].sessions[loc.s].status == .idle else { return }
        guard !projects[loc.p].sessions[loc.s].hasBackgroundWork else { return }
        completionPending.remove(sessionId)
        let summaryContext = completionSummaryContexts.removeValue(forKey: sessionId)

        guard !projects[loc.p].sessions[loc.s].turnCompleted else { return }
        projectStorage[loc.p].sessions[loc.s].turnCompleted = true
        foregroundIdleGenerationBaselines.removeValue(forKey: sessionId)

        guard projects[loc.p].effectiveParentSessionId(for: sessionId) == nil else { return }
        guard !isVisible(projectIndex: loc.p, sessionIndex: loc.s) else { return }
        // Light the finished-and-unseen dot here too. When a session was already
        // demoted to idle early (stale-working recovery, while background subagents
        // were still running), the final agent-stop arrives with
        // `previous == .idle`, so the active→idle edge in `setStatus` won't set this.
        // Setting it at the completion chokepoint keeps the sidebar/tab dot in parity
        // for both the direct-finish and the pre-demoted paths.
        withCoalescedProjectPublications {
            projects[loc.p].sessions[loc.s].finishedUnseen = true
            postNotification(
                projectId: projects[loc.p].id,
                sessionId: sessionId,
                kind: .completed,
                title: StatusNotificationKind.completed.title,
                body: nil,
                completionSummaryContext: summaryContext
            )
        }
    }

    func setBackgroundAgentsActive(sessionId: String, active: Bool) {
        guard let loc = locateIndex(sessionId) else { return }
        guard projects[loc.p].sessions[loc.s].backgroundAgentsActive != active else { return }
        projects[loc.p].sessions[loc.s].backgroundAgentsActive = active
        SessionArtifacts.setBackgroundAgentsActive(sessionId: sessionId, active: active)
        if !active {
            postCompletionIfReady(sessionId: sessionId)
        }
    }

    nonisolated static func notificationSubtitle(
        projectName: String,
        sessionTitle: String
    ) -> String {
        "\(projectName) · \(sessionTitle)"
    }

    nonisolated static func isSessionVisible(
        appIsActive: Bool,
        selectedProjectId: String?,
        projectId: String,
        selectedSessionId: String?,
        sessionId: String
    ) -> Bool {
        appIsActive
            && selectedProjectId == projectId
            && selectedSessionId == sessionId
    }

}
