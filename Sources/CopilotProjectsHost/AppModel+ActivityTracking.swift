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
                expectedSessionId: snapshot.copilotSessionId, now: now
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
                // A scheduled turn shows as idle, as it always has. Pending input
                // shows as waiting: `reconcileStatus` lays that over this status.
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

    /// Applies each session's tracker-only status. This is the one place
    /// `Session.status` is written, and it runs after every snapshot scan and after
    /// the process check.
    func reconcileStatus(now: Date) {
        withCoalescedProjectPublications {
            // With the process check switched off (COPILOT_PROJECTS_LIVENESS=0) no
            // process list is kept, so a tracker is never taken as gone for being
            // absent from it.
            let live = livenessEnabled
                ? remotePromptLiveSessions?(agentProcessNames) ?? liveAgentSessions : nil
            var changed = false
            for pi in projects.indices {
                for si in projects[pi].sessions.indices
                    where reconcileStatus(projectIndex: pi, sessionIndex: si, live: live, now: now) {
                    changed = true
                }
            }
            dismissAnsweredQuestionNotifications(now: now)
            syncSessionWorkingModels(now: now)
            if changed { updateDockBadge() }
        }
    }

    private func reconcileStatus(
        projectIndex pi: Int, sessionIndex si: Int, live: Set<String>?, now: Date
    ) -> Bool {
        var session = projects[pi].sessions[si]
        let sid = session.id
        let previous = session.status
        let snapshot = ownedActivity(session)
        let tracker = Self.trackerOnly(
            snapshot, held: previous,
            gone: live?.contains(sid) == false || session.trackerWarning != nil, now: now)
        // A fresh snapshot of the tab's owner that lists pending input is waiting
        // whatever its reading. A gone tracker's list counts for nothing: a
        // disconnected one keeps republishing a question it can no longer see answered.
        let waiting = tracker.state != .gone
            && snapshot?.isFresh(at: now) == true && snapshot?.hasPendingInput == true
        session.status = waiting ? .waiting : tracker.status

        // The elapsed timer's start marks a foreground turn in progress: the
        // tracker's own, not a working reading alone. On Nov 13 a schedule's turn
        // read working for a heartbeat before its tracker marked it scheduled.
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        var turnEnded = false
        if tracker.state == .alive, tracker.status == .running,
           snapshot?.foregroundTurnActive == true {
            let transition = snapshot?.foregroundTransitionMilliseconds
            let identity = Self.runningRequestIdentity(snapshot)
            if let started = session.runningStartedAtMilliseconds {
                // A queued message can start the next request with no idle seen between.
                if let transition, let identity, let existing = session.runningRequestIdentity,
                   existing != identity, transition >= started {
                    session.runningStartedAtMilliseconds = transition
                    session.runningRequestIdentity = identity
                    foregroundIdleGenerationBaselines[sid] = snapshot?.idleGeneration ?? -1
                } else if session.runningRequestIdentity == nil {
                    session.runningRequestIdentity = identity
                }
                // A timer kept across a relaunch has no baseline yet.
                if foregroundIdleGenerationBaselines[sid] == nil {
                    foregroundIdleGenerationBaselines[sid] = snapshot?.idleGeneration ?? -1
                }
            } else {
                session.runningStartedAtMilliseconds = transition ?? nowMs
                session.runningRequestIdentity = identity
                session.finishedUnseen = false
                session.turnCompleted = false
                foregroundIdleGenerationBaselines[sid] = snapshot?.idleGeneration ?? -1
                completionPending.remove(sid)
                completionSummaryContexts[sid] = nil
                backgroundAgentsSuppressed.remove(sid)
            }
        } else if let started = session.runningStartedAtMilliseconds, tracker.state != .held {
            if tracker.state == .gone {
                // The agent exited or its tracker went, so nothing will say the turn finished.
                if projects[pi].effectiveParentSessionId(for: sid) == nil,
                   !isVisible(projectIndex: pi, sessionIndex: si) {
                    session.finishedUnseen = true
                }
                foregroundIdleGenerationBaselines[sid] = nil
            } else if snapshot?.scheduledTurnActive == true {
                // A schedule's message took the turn over; a scheduled turn completes quietly.
                foregroundIdleGenerationBaselines[sid] = nil
            } else if snapshot?.foregroundTurnActive == false {
                // The tracker ended the turn: at its idle event, or at its second idle
                // reading running. One idle reading with the turn still active is not
                // an end: on Nov 12 five fell inside a request, for up to 2.5 s.
                turnEnded = true
                completionSummaryContexts[sid] = CompletionSummaryContext(
                    copilotSessionId: snapshot?.copilotSessionId,
                    activeTimestamp: started,
                    completionTimestamp: snapshot?.updatedAtMilliseconds
                )
                completionPending.insert(sid)
            }
            if tracker.state == .gone || snapshot?.scheduledTurnActive == true || turnEnded {
                session.runningStartedAtMilliseconds = nil
                session.runningRequestIdentity = nil
            }
        }

        let changed = session != projects[pi].sessions[si]
        if changed { projects[pi].sessions[si] = session }
        if previous == .waiting, session.status != .waiting {
            cancelWaitingNotifications(sessionId: sid)
        } else if previous != .waiting, session.status == .waiting, let snapshot {
            // The first prompt of a wait alerts; more within the same wait do not.
            if snapshot.trackedUserInputs?.isEmpty == false
                || snapshot.trackedElicitations?.isEmpty == false {
                scheduleElicitationNotification(sessionId: sid)
            } else if snapshot.pendingPermissionRequestIds?.isEmpty == false {
                schedulePermissionNotification(sessionId: sid)
            }
        }
        // The tracker clears its whole-session idle time at every root or agent turn
        // start, so one that is set means the background agents are done too.
        if let idleAt = snapshot?.sessionIdleAtMilliseconds, idleAt <= nowMs,
           snapshot?.foregroundTurnActive == false,
           snapshot?.activeSubagents.isEmpty == true {
            setBackgroundAgentsActive(sessionId: sid, active: false)
        }
        if turnEnded {
            let delay = completionNotificationDelayNanoseconds
            Task { @MainActor [weak self] in
                // Allow a moment for the background-agent OSC title to arrive.
                try? await Task.sleep(nanoseconds: delay)
                self?.reconcileStatus(now: Date())
            }
        } else if session.status == .idle, snapshot != nil || tracker.state == .gone {
            // Without its snapshot a session's background agents cannot be seen. In a
            // replay of Nov 13 snapshots, a pass that had dropped one posted Finished
            // with an agent still running.
            postCompletionIfReady(sessionId: sid)
        }
        return changed
    }

    /// Starts the process check, which tells the status rule when a session's
    /// agent process has gone, and the status shadow's once-a-second pass.
    func startLivenessReconciler() {
        livenessTimer?.invalidate()
        statusTimer?.invalidate()

        if livenessEnabled {
            reconcileLiveness()
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
    /// read, or that a later scan observed after the read began, keeps its state;
    /// returns false when any did, so the caller can scan again.
    @discardableResult
    private func applyAgentActivityReads(
        _ reads: [String: AgentActivityRead],
        warningMessage: String,
        observations: [String: Int],
        clock readTime: () -> Date
    ) -> Bool {
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
                let scheduledActive = fresh?.scheduledTurnActive == true
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
            verifiedCopilotOwners = verifiedCopilotOwners.filter { seenSessionIds.contains($0.key) }
            trackerMissingSince = trackerMissingSince.filter { seenSessionIds.contains($0.key) }
            budgetNotificationKeys = budgetNotificationKeys.filter { seenSessionIds.contains($0.key) }
            reconcileStatus(now: readTime())
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

    /// The once-a-second pass, which the status shadow compares on.
    func reconcileStatus() {
        withCoalescedProjectPublications {
            reconcileStatus(now: Date())
            recordStatusShadow(now: Date())
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

    private func reconcileLiveness() {
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

            reconcileStatus(now: Date())
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
        // A new turn can't be seen as a conversation rotating, so the reply
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
            // A new turn may start while the transcript is loading. Keep the
            // original alert, but never attach that turn's content to it.
            let stillCurrent = locateIndex(sessionId).map {
                projects[$0.p].sessions[$0.s].turnCompleted
            } == true
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
        // The tracker's last idle event describes this turn only if it came after the turn began.
        let idleIsCurrent = baseline == nil || (snapshotActivity?.idleGeneration ?? -1) > baseline!
        let scheduledIdleIsCurrent = snapshotActivity?.lastIdleTurnKind == "scheduled" && idleIsCurrent
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
        withCoalescedProjectPublications {
            projects[loc.p].sessions[loc.s].finishedUnseen = true
            // An aborted turn keeps the dot and posts no alert.
            guard !(snapshotActivity?.lastIdleAborted == true && idleIsCurrent) else { return }
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
