import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol
import Darwin

extension AppModel {
    func runtimeForegroundActivity(
        for session: Session,
        now: Date
    ) -> ForegroundActivity? {
        let owner = resumeMarkerValue(sessionId: session.id, suffix: "copilot-session")
        guard let snapshot = session.agentActivity else {
            return runtimeTrackedOwners[session.id] == owner?.lowercased()
                && owner != nil ? .unknown : nil
        }
        let activity = snapshot.runtimeForegroundActivity(
            expectedSessionId: owner,
            now: now,
            minimumObservationMilliseconds:
                sessionSemantics.promptSafetyClock.timestamp(for: session.id)
        )
        guard let fence = remotePromptFences[session.id] else { return activity }
        if let currentRoot = snapshot.copilotSessionId,
           let epoch = snapshot.conversationEpoch,
           currentRoot.lowercased() == owner?.lowercased(),
           (currentRoot != fence.rootSessionId || epoch != fence.conversationEpoch) {
            remotePromptFences[session.id] = nil
            return activity
        }
        if SessionSemantics.acknowledgesSubmittedPrompt(
            foreground: activity,
            observedAt: snapshot.runtimeActivity?.observedAtMilliseconds,
            idleAt: snapshot.runtimeActivity?.idleAtMilliseconds,
            submittedAt: fence.submittedAt
        ) {
            remotePromptFences[session.id] = nil
            return activity
        }
        return .unknown
    }

    func inputWaitWasResolved(
        for session: Session,
        foreground: ForegroundActivity?,
        now: Date
    ) -> Bool {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        guard foreground != .unknown,
              let wait = inputWaits[session.id],
              let snapshot = session.agentActivity,
              snapshot.isFresh(at: now),
              snapshot.copilotSessionId?.lowercased() == wait.context.rootSessionId.lowercased(),
              snapshot.copilotSessionId?.lowercased() == resumeMarkerValue(
                sessionId: session.id, suffix: "copilot-session"
              )?.lowercased(),
              snapshot.conversationEpoch == wait.context.conversationEpoch,
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
        if snapshot.runtimeActivity == nil, snapshot.inputCompletions == nil,
           snapshot.sessionIdleAtMilliseconds == nil {
            return true
        }
        if let completed = snapshot.inputCompletions?[wait.context.senderSessionId.lowercased()],
           completed >= wait.timestamp, completed <= nowMs, completed <= observed {
            return true
        }
        // Whole-session idle is stronger than a child completion and also covers
        // cancellation, where an individual input-completed event can be absent.
        if let idleAt = snapshot.sessionIdleAtMilliseconds,
           idleAt > wait.timestamp, idleAt <= nowMs, idleAt <= observed {
            return true
        }
        return false
    }

    func projectedStatus(
        for session: Session,
        foreground: ForegroundActivity?,
        now: Date
    ) -> SessionStatus {
        if session.hasPendingInput { return .waiting }
        if session.status == .waiting, !session.statusIsRuntimeDerived {
            guard inputWaitWasResolved(for: session, foreground: foreground, now: now) else {
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
                        sessionSemantics.activityTracker.reset(sessionId: session.id)
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
            if changed {
                save()
                updateDockBadge()
            }
        }
    }

    /// Backstop for flaky agent stop / sessionEnd hooks: a session can only stay
    /// `running`/`waiting` while its shell actually hosts a live agent process.
    /// This never clears status while the agent is genuinely working (unlike a
    /// time-based decay), and clears promptly when the agent exits or crashes.
    func startLivenessReconciler() {
        livenessTimer?.invalidate()
        footerTimer?.invalidate()

        if livenessEnabled {
            reconcileLiveness(markFinished: false)
        } else {
            liveAgentSessions = []
        }

        // Footer backstop: recovers an actively-working attached session after an app
        // restart, and catches Esc-cancel when the stop hook never fires.
        reconcileAgentFooters()
        let footer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcileAgentFooters() }
        }
        RunLoop.main.add(footer, forMode: .common)
        footerTimer = footer

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
        agentActivityReadQueue.async { [weak self] in
            let reads = reader(sessionIds, directory, cached, { Date() })
            Task { @MainActor [weak self] in
                self?.finishAgentActivityRead(reads, observations: observations, generation: generation)
            }
        }
    }

    private func finishAgentActivityRead(
        _ reads: [String: AgentActivityRead],
        observations: [String: Int],
        generation: Int
    ) {
        agentActivityReadInFlight = false
        var again = agentActivityReadQueued
        agentActivityReadQueued = false
        // Tracking restarted or stopped since this read began.
        if generation == agentActivityRefreshGeneration,
           !applyAgentActivityReads(reads, observations: observations, clock: { Date() }) {
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
        applyAgentActivityReads(reads, observations: agentActivityObservations, clock: readTime)
    }

    /// Applies a scan's reads to the current sessions. A session the scan didn't
    /// read, or that was observed or changed by a hook after the read began (a
    /// later scan, a single-session load, or a scheduling hook), keeps its state;
    /// returns false when any did, so the caller can scan again.
    @discardableResult
    private func applyAgentActivityReads(
        _ reads: [String: AgentActivityRead],
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
                if snapshot?.runtimeActivity != nil, let owner = snapshot?.copilotSessionId,
                   owner.lowercased() == resumeMarkerValue(
                    sessionId: sessionId, suffix: "copilot-session"
                   )?.lowercased() {
                    runtimeTrackedOwners[sessionId] = owner.lowercased()
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
                    var merged = (nextProjects[pi].sessions[si].pullRequestKeys ?? [])
                        .compactMap(RemotePullRequestsContract.canonicalKey)
                    let hasNewCandidate = merged.count < 5 && snapshotKeys.contains { raw in
                        guard let canonical = RemotePullRequestsContract.canonicalKey(raw) else { return false }
                        return !merged.contains(canonical)
                    }
                    if hasNewCandidate {
                        if isActivitySnapshotTrustedForSessionMetadata(
                            sessionId: sessionId,
                            snapshot: snapshot
                        ) {
                            var mergedChanged = false
                            for raw in snapshotKeys {
                                guard merged.count < 5,
                                      let canonical = RemotePullRequestsContract.canonicalKey(raw),
                                      !merged.contains(canonical) else { continue }
                                merged.append(canonical)
                                mergedChanged = true
                            }
                            if mergedChanged {
                                nextProjects[pi].sessions[si].pullRequestKeys = merged
                                activityChanged = true
                                startingPromptChanged = true
                            }
                        } else {
                            effectiveFresh?.pullRequestKeys = nil
                        }
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
                    }
                    activityChanged = activityChanged || previous != effectiveFresh
                    nextProjects[pi].sessions[si].agentActivity = effectiveFresh
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
                        startingPromptChanged = true
                    }
                    if let identity,
                       existingIdentity == nil || isNewRequest,
                       transitionMs >= (nextProjects[pi].sessions[si].runningStartedAtMilliseconds ?? .min) {
                        nextProjects[pi].sessions[si].runningRequestIdentity = identity
                        startingPromptChanged = true
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
            budgetNotificationKeys = budgetNotificationKeys.filter { seenSessionIds.contains($0.key) }
            reconcileRuntimeActivity(now: readTime())
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

    /// Decide whether a `.running` session should be demoted to idle because its
    /// extension's RPC connection is gone. Pure and side-effect-free so it can be
    /// unit-tested without the reconciler's controller/timer machinery. Returns the
    /// evidence timestamp (ms) to seed the status clock, or nil when no demotion is
    /// warranted. Conditions: the session is `.running`; the terminal footer is
    /// idle (a disconnect proves RPC loss, not turn completion — the footer is the
    /// authoritative foreground signal, so a genuinely-working session is never
    /// demoted); the snapshot is fresh and reports a terminal disconnect (healthy
    /// sessions have `error == nil` and never qualify); and the snapshot's evidence
    /// time is within `[clockMs, nowMs]` so a newer status hook can't be overridden
    /// and a future-dated snapshot (clock rollback) can't poison the clock.
    nonisolated static func disconnectDemotionEvidenceMs(
        status: SessionStatus,
        footerActivity: FooterActivity,
        snapshot: AgentActivitySnapshot?,
        now: Date,
        nowMs: Int64,
        clockMs: Int64
    ) -> Int64? {
        SessionSemanticsAdapter.disconnectDemotionEvidenceMilliseconds(
            status: status,
            footerActivity: footerActivity,
            snapshot: snapshot,
            now: now,
            nowMilliseconds: nowMs,
            statusClockMilliseconds: clockMs
        )
    }

    /// Backstop for cancelled turns. An Esc-cancel fires no stop hook and leaves the
    /// agent alive, so neither the stop hook nor `reconcileLiveness` clears the tab
    /// spinner — but the agent's own footer returns to its idle signature. Clear a
    /// stale running/waiting status once the footer has read idle for a couple of
    /// consecutive scans, but ONLY after we've actually observed the footer go
    /// `working` in this epoch. That guard means footer lag right after the hook
    /// flips us to running, an old idle footer scrolled into view, or a confirmation
    /// prompt (which reads as `working`) can never clear a genuinely-active session.
    /// Includes `waiting`, so an Esc-cancel of an ask_user/permission wait — which
    /// also fires no stop hook — is caught too.
    func reconcileAgentFooters() {
        withCoalescedProjectPublications {
        reconcileRuntimeActivity(now: Date())
        var tracked: Set<String> = []
        for pi in projects.indices {
            for si in projects[pi].sessions.indices {
                let status = projects[pi].sessions[si].status
                let sid = projects[pi].sessions[si].id
                let runtime = runtimeForegroundActivity(
                    for: projects[pi].sessions[si], now: Date()
                )
                if runtime == .working || runtime == .idle {
                    continue
                }
                guard let activity = remotePromptTarget?(sid)?.activity
                    ?? controllers[sid]?.agentActivity else { continue }
                let supportsSessionIdleHook = FileManager.default.fileExists(
                    atPath: Paths.sessionIdleHookMarkerPath(sessionId: sid)
                )
                // Self-recovery for the snapshot-driven demotion below: if the
                // foreground turn has resumed (a fresh `assistant.turn_start` flipped
                // `foregroundTurnActive` back to true), restore `.running`. This
                // reverses a demotion that fired during an unusually long
                // inter-iteration gap, so the fix no longer depends on that gap being
                // shorter than the two-scan dwell window. `foregroundTurnActive` is set
                // true ONLY at the root's `assistant.turn_start` and cleared at
                // `turn_end`/`session.idle`, so the freshest snapshot reporting it true
                // means the root is genuinely mid-turn ⇒ running (this holds regardless
                // of subagent count, which is why there's no `activeSubagents` gate here
                // — a subagent finishing between demotion and the foreground resuming
                // must not strand the tab as idle). A genuinely-finished session can't
                // trip this: `session.idle`/`turn_end` leave `foregroundTurnActive ==
                // false`, and the clock guard rejects a stale snapshot at or before the
                // latest status hook. Reject a future-dated snapshot (clock rollback)
                // too. Run this BEFORE the completion check so a session that's about to
                // be promoted back to running never fires a spurious completion.
                if status == .idle {
                    let recoveryNowMs = SessionArtifacts.currentStatusTimestamp()
                    if let snapshotMs =
                        SessionSemanticsAdapter.foregroundRecoveryEvidenceMilliseconds(
                            status: status,
                            snapshot: projects[pi].sessions[si].agentActivity,
                            now: Date(),
                            nowMilliseconds: recoveryNowMs,
                            statusClockMilliseconds:
                                sessionSemantics.statusClock.timestamp(for: sid)
                                ?? Int64.min
                        ) {
                        sessionSemantics.activityTracker.resetForegroundIdle(
                            sessionId: sid
                        )
                        sessionSemantics.activityTracker.resetDisconnectIdle(
                            sessionId: sid
                        )
                        // Promote IN MEMORY ONLY, using the foreground-transition
                        // timestamp (the root turn_start time — NOT `updatedAt`,
                        // which unrelated republishes rewrite): `setStatus` advances
                        // the clock via `shouldApply` to `snapshotMs` so a genuinely
                        // newer idle/waiting hook is still accepted, and — because a
                        // timestamp is supplied —
                        // it does NOT persist to disk. We deliberately don't persist
                        // here either: recovery compensates for a MISSING running hook,
                        // so no hook wrote `running` to disk; writing it ourselves could
                        // clobber a newer hook-written `idle` whose IPC is merely delayed
                        // behind reconciliation, and a later timestamped idle IPC would
                        // repair memory but not disk — leaving a stale `running` that
                        // survives restart (the very bug this fixes). Leaving the disk
                        // status to the hooks keeps recovery's only failure mode benign
                        // and self-healing (disk reads `idle` for a running session →
                        // footer promotion re-corrects within ~2s), never stuck-running.
                        setStatus(
                            sessionId: sid,
                            status: .running,
                            text: nil,
                            timestamp: snapshotMs,
                            source: "background-recovery"
                        )
                        continue
                    }
                }
                if status == .idle, activity == .idle {
                    postCompletionIfReady(sessionId: sid)
                }
                if status == .idle {
                    sessionSemantics.activityTracker.resetDisconnectIdle(sessionId: sid)
                    guard ActivityTracker.canPromoteIdleFromFooter(
                        backgroundAgentsActive: projects[pi].sessions[si].hasBackgroundWork,
                        hasLiveAgent: liveAgentSessions.contains(sid),
                        supportsSessionIdleHook: supportsSessionIdleHook
                    ) else {
                        sessionSemantics.activityTracker.reset(sessionId: sid)
                        continue
                    }
                    tracked.insert(sid)
                    if sessionSemantics.activityTracker.shouldPromoteFromFooter(
                        sessionId: sid,
                        currentStatus: status,
                        activity: activity
                    ) {
                        setStatus(
                            sessionId: sid,
                            status: .running,
                            text: nil,
                            source: "footer"
                        )
                    }
                    continue
                }
                // Disconnected-extension recovery: a fresh snapshot reporting a
                // terminal RPC disconnect can no longer observe
                // `turn_end`/`session.idle`, so its stuck `foregroundTurnActive`
                // would otherwise keep the tab "working" forever (the 5s heartbeat
                // republishes it fresh, defeating the isFresh TTL). Demote to idle
                // once the disconnect persists across two scans — but ONLY when the
                // terminal footer is idle (a disconnect proves RPC loss, not turn
                // completion; the footer is the authoritative foreground signal, so
                // a genuinely-working session is never demoted). Scoped to
                // `reportsTerminalDisconnect`, so a healthy session (error == nil)
                // never enters here. The evidence timestamp orders the demotion
                // against the status clock so a reconnect turn_start isn't dropped.
                if let evidenceMs = Self.disconnectDemotionEvidenceMs(
                    status: status,
                    footerActivity: activity,
                    snapshot: projects[pi].sessions[si].agentActivity,
                    now: Date(),
                    nowMs: SessionArtifacts.currentStatusTimestamp(),
                    clockMs: sessionSemantics.statusClock.timestamp(for: sid)
                        ?? Int64.min
                ) {
                    tracked.insert(sid)
                    sessionSemantics.activityTracker.resetForegroundIdle(sessionId: sid)
                    if sessionSemantics.activityTracker.observeDisconnectIdle(
                        sessionId: sid,
                        currentStatus: status
                    ) {
                        clearStatusToIdle(pi: pi, si: si, markFinished: false, effectiveTime: evidenceMs)
                    }
                    continue
                } else {
                    sessionSemantics.activityTracker.resetDisconnectIdle(sessionId: sid)
                }
                // Stale "working" recovery: the foreground turn has ended, but
                // scheduled, subagent, or CLI background-agent work keeps
                // `session.idle` from firing, so the hook path below (guarded by
                // `supportsSessionIdleHook`) never demotes the tab and it reads
                // "working" while the terminal is actually idle and interactive.
                // Scope this strictly to fresh background-only evidence so ordinary
                // sessions keep falling through. Demote to idle
                // once the ended-turn condition persists across two scans (a normal
                // inter-iteration gap flips `foregroundTurnActive` false only briefly:
                // `turn_end` fires per loop iteration and tool calls run *inside* a
                // turn, so foreground stays active through them). Leave scheduled,
                // subagent, and background-agent state intact so the background
                // indicator persists.
                // The clock-ordering guard rejects a snapshot that predates the latest
                // status hook, so a just-submitted prompt (whose running hook advanced
                // the clock before its own fresh snapshot lands) can't be demoted; and
                // seeding the clock from the foreground-transition timestamp (the
                // turn_end time) — not `updatedAt` (which unrelated republishes bump)
                // and not `now` — keeps a subsequent user-prompt hook from being
                // swallowed. A future-dated transition (system-clock rollback) is
                // rejected outright so it can't drive a demotion or poison the clock.
                let backgroundNow = Date()
                let backgroundNowMs = SessionArtifacts.currentStatusTimestamp()
                if let snapshotMs =
                    SessionSemanticsAdapter.backgroundDemotionEvidenceMilliseconds(
                        status: status,
                        snapshot: projects[pi].sessions[si].agentActivity,
                        backgroundAgentsActive:
                            projects[pi].sessions[si].backgroundAgentsActive,
                        now: backgroundNow,
                        nowMilliseconds: backgroundNowMs,
                        statusClockMilliseconds:
                            sessionSemantics.statusClock.timestamp(for: sid)
                    ) {
                    tracked.insert(sid)
                    if sessionSemantics.activityTracker.observeForegroundIdle(
                        sessionId: sid,
                        currentStatus: status,
                        foregroundTurnActive: false
                    ) {
                        clearStatusToIdle(
                            pi: pi,
                            si: si,
                            markFinished: false,
                            effectiveTime: snapshotMs
                        )
                        // Don't post completion here: background work is still active.
                        // Its final stop/session-idle signal owns completion.
                    }
                    continue
                } else {
                    sessionSemantics.activityTracker.resetForegroundIdle(sessionId: sid)
                }
                if supportsSessionIdleHook {
                    sessionSemantics.activityTracker.reset(sessionId: sid)
                    continue
                }
                tracked.insert(sid)
                if sessionSemantics.activityTracker.observeFooter(
                    sessionId: sid,
                    currentStatus: status,
                    activity: activity
                ) {
                    clearStatusToIdle(pi: pi, si: si, markFinished: true)
                    postCompletionIfReady(sessionId: sid)
                }
            }
        }
        sessionSemantics.activityTracker.retain(activeSessionIds: tracked)
        }
    }

    /// Drop a session to idle and (unless it's on screen) flag it finished & unseen,
    /// then persist the corrected status. Shared by the liveness and footer reconcilers.
    private func clearStatusToIdle(pi: Int, si: Int, markFinished: Bool, effectiveTime: Int64? = nil) {
        withCoalescedProjectPublications {
            let sid = projects[pi].sessions[si].id
            sessionSemantics.activityTracker.reset(sessionId: sid)
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
            // Seed the clock from the evidence that triggered the demotion, not `now`.
            // For a snapshot-driven demotion `effectiveTime` is the snapshot's own
            // timestamp; advancing the clock to `now` would let it swallow a fresh
            // user-prompt running hook whose timestamp is slightly earlier than `now`,
            // freezing the tab in idle. Clamp to `now` so a future-dated snapshot (e.g.
            // after a system-clock rollback) can't poison the clock and reject later
            // legitimate hooks. Liveness/footer callers pass nil and keep the prior
            // `now`-based behavior.
            let now = SessionArtifacts.currentStatusTimestamp()
            let base = min(effectiveTime ?? now, now)
            let timestamp = max(
                base,
                sessionSemantics.statusClock.timestamp(for: sid) ?? base
            )
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

    private func reconcileLiveness(markFinished: Bool = true) {
        withCoalescedProjectPublications {
            let snapshot = ProcessTree.snapshot()
            // Sessions whose shell currently hosts a live agent (copilot) process.
            // Also used by scroll-forwarding: a resumed session's terminal is desynced
            // (SwiftTerm restarted in the normal buffer, copilot never re-emits its
            // mouse mode), but copilot's input parser still expects mouse events — so
            // the wheel is force-forwarded as mouse when the session has a live agent.
            liveAgentSessions = ProcessTree.agentSessions(agentNames: agentProcessNames, in: snapshot)

            for pi in projects.indices {
                for si in projects[pi].sessions.indices {
                    let sid = projects[pi].sessions[si].id
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
                    if ActivityTracker.livenessShouldDemote(
                        currentStatus: status,
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
        let activity = controllers[sessionId]?.agentActivity
        guard Self.canPostCompletion(
            status: projects[loc.p].sessions[loc.s].status,
            activity: activity
        ) else { return }
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
        // were still running), the final agent-stop/session-idle arrives with
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

    nonisolated static func canPostCompletion(
        status: SessionStatus,
        activity: FooterActivity?
    ) -> Bool {
        SessionSemantics.canPostCompletion(
            status: status,
            footerActivity: activity
        )
    }

    nonisolated static func shouldClearPendingCompletion(
        status: SessionStatus,
        source: String?
    ) -> Bool {
        SessionSemantics.shouldClearPendingCompletion(
            status: status,
            source: source
        )
    }
}
