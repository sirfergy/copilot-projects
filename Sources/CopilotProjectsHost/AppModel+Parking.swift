import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol

/// Parking stops an idle session's Copilot to free its memory. The row, the
/// transcript and the resume marker stay, and Copilot starts again in the same
/// row when the session is opened. Opt-in, and off by default.
enum SessionParking {
    /// `UserDefaults` key holding `off` (the default) or `manual`.
    static let settingKey = "parkIdleSessions"
    static let explainedKey = "parkIdleSessionsExplained"
    static let off = "off"
    static let manual = "manual"
    static let checkKind = CLISDKOperationKind.sessionParkCheck.rawValue
    static let stopTimeout: Duration = .seconds(20)
    static let resumeTimeoutMilliseconds: Int64 = 90_000
    /// A remote client has a session open for this long after its last refresh.
    static let remoteOpenWindow: TimeInterval = 5
}

/// What parking reads from and does to processes, so tests can stand in for it.
struct ParkingRuntime {
    var liveProcesses: (String) -> Set<TranscriptController.CloseProcessIdentity> = {
        TranscriptController.liveCLIProcesses(sessionId: $0)
    }
    var isAlive: @Sendable (TranscriptController.CloseProcessIdentity) -> Bool = {
        TranscriptController.closeProcessIsAlive($0)
    }
    var terminate: ([String]) -> Void = { SessionArtifacts.terminateDtach(sessionIds: $0) }
    var hasMaster: (String) -> Bool = { sessionId in
        ProcessTree.dtachMaster(
            forSocket: Paths.dtachSocketPath(sessionId: sessionId),
            in: ProcessTree.snapshot(maxAge: .zero)
        ) != nil
    }
    var sessionStore: @Sendable () -> CopilotSessionStore = { CopilotSessionStore() }
    /// Creates the session's terminal, whose new dtach master runs `copilot --resume`.
    var startTerminal: @MainActor (AppModel, String) -> Void = { $0.controller(for: $1) }
}

extension AppModel {
    var parkingEnabled: Bool {
        (defaults.string(forKey: SessionParking.settingKey) ?? SessionParking.off) != SessionParking.off
    }

    func parkedState(_ sessionId: String) -> ParkedSession.State? {
        locateIndex(sessionId).flatMap { projects[$0.p].sessions[$0.s].parked?.state }
    }

    /// True while a session's input is closed for parking, so the caller answers
    /// "busy". Input addressed to a parked session starts its resume.
    func parkingBlocksInput(_ sessionId: String) -> Bool {
        guard let state = parkedState(sessionId) else { return false }
        if state == .parked { resumeParkedSession(sessionId) }
        return true
    }

    /// Moves a session to `state` (nil clears the record) and returns the time
    /// that identifies this attempt.
    @discardableResult
    private func setParked(
        _ sessionId: String,
        _ state: ParkedSession.State?,
        processes: Set<TranscriptController.CloseProcessIdentity> = []
    ) -> Int64 {
        let now = SessionArtifacts.currentStatusTimestamp()
        guard let loc = locateIndex(sessionId) else { return now }
        projects[loc.p].sessions[loc.s].parked = state.map {
            ParkedSession(state: $0, sinceMilliseconds: now, processes: Array(processes))
        }
        // Nothing of the session is running; don't show its last sample until the next one.
        if state == .parked { projects[loc.p].sessions[loc.s].memoryUsageBytes = nil }
        syncMenuState(includeRuntimeAttention: true)
        return now
    }

    private func isAttempt(_ sessionId: String, _ state: ParkedSession.State, _ since: Int64) -> Bool {
        guard let loc = locateIndex(sessionId),
              let parked = projects[loc.p].sessions[loc.s].parked else { return false }
        return parked.state == state && parked.sinceMilliseconds == since
    }

    // MARK: - what may be parked

    private var parkingAdapter: CLIOperationAdapter {
        CLIOperationAdapter(activityDirectory: agentActivityDirectory, resumeMarkerDirectory: resumeMarkerDirectory)
    }

    /// The session's tracker snapshot, read now, when it shows a settled idle
    /// session bound to this tab's own resumable Copilot session.
    private func idleSnapshot(_ sessionId: String, clock: () -> Date) -> AgentActivitySnapshot? {
        guard let loc = locateIndex(sessionId),
              let snapshot = parkingAdapter.loadFreshSnapshot(sessionId: sessionId, now: clock),
              let workflow = snapshot.workflow, workflow.isFresh(at: clock()),
              let copilotId = validatedCopilotSessionMarker(for: sessionId),
              snapshot.copilotSessionId?.caseInsensitiveCompare(copilotId) == .orderedSame,
              !projects[loc.p].sessions[loc.s].requiresEndConfirmation,
              workflow.pendingMessages?.isEmpty != false,
              sessionIsSettledIdle(sessionId: sessionId, snapshot: snapshot, workflow: workflow, now: clock())
        else { return nil }
        return snapshot
    }

    /// Why a session cannot be parked right now, or nil when it can. Anything
    /// unknown is a reason. `unattended` is a park nobody chose this session for.
    /// `attempt` is the park under way, whose own record and question don't count.
    func parkBlocker(
        for sessionId: String, unattended: Bool = false, attempt: Int64? = nil,
        dtach: [ProcessTree.DtachProcess]? = nil, now: Date = Date()
    ) -> String? {
        let clock = advancingClock(from: now)
        guard parkingEnabled else { return "Park Idle Sessions is off." }
        guard !isTerminating, stateLoadFailure == nil, let loc = locateIndex(sessionId) else {
            return "The workspace is not available."
        }
        let project = projects[loc.p]
        let session = project.sessions[loc.s]
        if let parked = session.parked, parked.state != .parking || parked.sinceMilliseconds != attempt {
            return "It is already \(parked.label.lowercased())."
        }
        guard session.hostId == nil, remoteSessionBackendAvailable() else {
            return "Only local Copilot sessions can be parked."
        }
        let parents = project.effectiveParentSessionIdsBySessionId()
        guard parents[sessionId] == nil, !parents.values.contains(sessionId) else {
            return "Sessions with a parent or child session can't be parked yet."
        }
        // The liveness pass has seen its Copilot, so judging it idle reads no processes.
        guard liveCopilotSessions.contains(sessionId),
              let snapshot = idleSnapshot(sessionId, clock: clock) else {
            return "Copilot is working, waiting for you, scheduled, running background work, "
                + "or its state isn't known."
        }
        guard snapshot.workflow?.capabilities.contains(SessionParking.checkKind) == true else {
            return "Copilot in this session started before parking was available. Run /restart in it first."
        }
        guard attempt != nil || !parkingAdapter.hasPendingHandoff(sessionId: sessionId),
              snapshot.operationReceipts?.contains(where: { $0.state == .accepted }) != true,
              controllers[sessionId]?.terminalView.isSubmittingRemotePrompt != true else {
            return "A request to Copilot is still in progress."
        }
        guard let copilotId = snapshot.copilotSessionId,
              let events = parkingRuntime.sessionStore().transcriptPath(for: copilotId),
              FileManager.default.fileExists(atPath: events) else {
            return "This session has nothing saved to resume from yet."
        }
        guard !session.isUnread, !session.finishedUnseen, session.failedRequest == nil else {
            return "It has something you haven't seen yet."
        }
        guard sessionPromptComposers[sessionId]?.isAttaching != true,
              sessionPromptComposers[sessionId]?.attachments.isEmpty != false else {
            return "Its unsent message has attachments, which would have to be attached again."
        }
        guard !remoteClientHasOpen(sessionId, now: clock()) else {
            return "It is open in the web or iOS app."
        }
        if unattended, sessionId == globalSelectedSessionId { return "It is the session on screen." }
        // `copilot-projects attach` types straight into the CLI, past the host.
        let socket = Paths.dtachSocketPath(sessionId: sessionId)
        let own = controllers[sessionId]?.shellPID
        guard !(dtach ?? ProcessTree.dtachProcesses(in: ProcessTree.snapshot(maxAge: .zero))).contains(where: {
            $0.socketPath == socket && !$0.isMaster && $0.pid != own
        }) else { return "Another terminal is attached to it." }
        return nil
    }

    /// Whether the session's CLI holds a lock on any other Copilot session. The
    /// tracker only sees the session in front, so a park nobody chose checks.
    private func hostsAnotherSession(_ sessionId: String) async -> Bool {
        let pids = parkingRuntime.liveProcesses(sessionId).map(\.pid)
        guard !pids.isEmpty, let own = validatedCopilotSessionMarker(for: sessionId) else { return true }
        let store = parkingRuntime.sessionStore
        return await Task.detached { store().holdsOtherSession(pids: pids, than: own) }.value
    }

    // MARK: - park

    /// Parks one session. Returns nil once Copilot has been told to stop, or why
    /// the session was left alone. A refusal leaves the session untouched.
    @discardableResult
    func parkSession(_ sessionId: String, unattended: Bool = false) async -> String? {
        if unattended, await hostsAnotherSession(sessionId) {
            return "Its Copilot may be running another session too."
        }
        if let blocker = parkBlocker(for: sessionId, unattended: unattended) { return blocker }
        // Close the doors before asking: from here every input path answers busy.
        var attempt = setParked(sessionId, .parking)
        controllers[sessionId]?.terminalView.isHidden = true
        guard (try? persistWorkspace()) != nil else {
            return standDown(sessionId, attempt, "The workspace could not be saved.")
        }
        let idle = await trackerConfirmsIdle(sessionId)
        // Its Copilot may have taken up another session while it was being asked.
        if unattended, await hostsAnotherSession(sessionId) {
            return standDown(sessionId, attempt, "Its Copilot may be running another session too.")
        }
        // From here to the stop is one main-actor turn.
        let processes = parkingRuntime.liveProcesses(sessionId)
        guard isAttempt(sessionId, .parking, attempt) else { return "The session changed." }
        // The whole rule again: the session may have been opened, grouped or attached to,
        // or parking switched off, while Copilot was being asked.
        if let reason = idle && !processes.isEmpty
            ? parkBlocker(for: sessionId, unattended: unattended, attempt: attempt)
            : "Copilot is busy, or didn't answer." {
            return standDown(sessionId, attempt, reason)
        }
        // Saved before the stop, so a restart can tell when the old CLI is gone.
        attempt = setParked(sessionId, .parking, processes: processes)
        guard (try? persistWorkspace()) != nil else {
            return standDown(sessionId, attempt, "The workspace could not be saved.")
        }
        controllers.removeValue(forKey: sessionId)?.terminate()
        parkingRuntime.terminate([sessionId])
        let deadline = ContinuousClock.now.advanced(by: SessionParking.stopTimeout)
        let gone = await SessionArtifacts.waitForLiveCLIExit(
            sessionId: sessionId, initialProcesses: processes,
            deadline: deadline, discoveryDeadline: deadline,
            liveCLIProcesses: { _ in [] }, processIsAlive: parkingRuntime.isAlive
        )
        guard isAttempt(sessionId, .parking, attempt) else { return nil }
        if gone {
            setParked(sessionId, .parked)
            save()
        } else {
            // Stays "Parking…" and can't be resumed until the old CLI is gone;
            // `reconcileParkedSessions` keeps checking.
            NSLog("copilot-projects: Copilot in \(sessionId) is still running after a park")
        }
        return nil
    }

    private func standDown(_ sessionId: String, _ attempt: Int64, _ reason: String) -> String {
        if isAttempt(sessionId, .parking, attempt) {
            setParked(sessionId, nil)
            save()
        }
        return reason
    }

    /// Asks the session's tracker whether it is idle right now. The question
    /// changes nothing in the session, and no answer counts as no.
    private func trackerConfirmsIdle(_ sessionId: String) async -> Bool {
        struct Question: Encodable {
            let schemaVersion = 1
            let copilotSessionId: String
            let operationId, conversationEpoch, kind, payloadFingerprint: String?
            let action = ["kind": SessionParking.checkKind]
        }
        guard let epoch = parkingAdapter.loadFreshSnapshot(sessionId: sessionId, now: { Date() })?
            .remoteOperationProjection().conversationEpoch else { return false }
        let operation = CLIOperationRequest(operationId: UUID().uuidString, conversationEpoch: epoch)
        guard parkingAdapter.submit(
            sessionId: sessionId, kind: .sessionParkCheck, operation: operation,
            fingerprintPayload: [SessionParking.checkKind], handoffSuffix: "\(SessionParking.checkKind).json",
            now: { Date() },
            validate: { $0.workflow?.capabilities.contains(SessionParking.checkKind) == true },
            makeHandoff: {
                Question(
                    copilotSessionId: $0.copilotSessionId, operationId: $0.operationId,
                    conversationEpoch: $0.conversationEpoch, kind: $0.kind,
                    payloadFingerprint: $0.payloadFingerprint
                )
            }
        ) == .accepted else { return false }
        let state = await terminalReceiptState(
            sessionId: sessionId, operation: operation, kind: SessionParking.checkKind,
            pollInterval: .milliseconds(100), adapter: parkingAdapter
        )
        return state == .applied
    }

    // MARK: - resume

    /// Starts Copilot again in a parked session's own row.
    func resumeParkedSession(_ sessionId: String) {
        guard let state = parkedState(sessionId), state == .parked || state == .failed else { return }
        guard parkingRuntime.hasMaster(sessionId) else {
            // A terminal that never started is still cached, and would be handed back as is.
            controllers.removeValue(forKey: sessionId)?.terminate()
            setParked(sessionId, .resuming)
            save()
            parkingRuntime.startTerminal(self, sessionId)
            return
        }
        // A Copilot already running there makes the record stale: show it, never stop it.
        guard !liveCopilotSessions.contains(sessionId), parkingRuntime.liveProcesses(sessionId).isEmpty else {
            setParked(sessionId, nil)
            save()
            return
        }
        // A failed resume leaves a shell under a live master, and attaching to
        // that would not try again. Stop it, then start over once it is gone.
        controllers.removeValue(forKey: sessionId)?.terminate()
        parkingRuntime.terminate([sessionId])
        let attempt = setParked(sessionId, .parked)
        Task { @MainActor [weak self] in
            var checks = 0
            while checks < 50, self?.parkingRuntime.hasMaster(sessionId) == true {
                checks += 1
                try? await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(100)))
            }
            guard let self, self.isAttempt(sessionId, .parked, attempt) else { return }
            if self.parkingRuntime.hasMaster(sessionId) {
                self.setParked(sessionId, .failed)
                self.save()
            } else {
                self.resumeParkedSession(sessionId)
            }
        }
    }

    /// Stops treating a session whose resume failed as parked, so its tab shows
    /// whatever the terminal holds.
    func openParkedTerminal(_ sessionId: String) {
        guard parkedState(sessionId) == .failed else { return }
        setParked(sessionId, nil)
        save()
    }

    // MARK: - settling

    /// Moves parked sessions on as their processes come and go. Runs with every
    /// tracker scan.
    func reconcileParkedSessions(now: Date) {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        for session in projects.flatMap(\.sessions) {
            guard let parked = session.parked else { continue }
            switch parked.state {
            case .parking:
                if !parked.processes.isEmpty, !parked.processes.contains(where: parkingRuntime.isAlive) {
                    setParked(session.id, .parked)
                    save()
                }
            case .resuming, .failed:
                // A failed resume whose Copilot reports in after all is live again.
                let live = session.agentActivity.map {
                    !$0.reportsTerminalDisconnect
                        && ($0.updatedAtMilliseconds ?? 0) > parked.sinceMilliseconds
                        && $0.copilotSessionId?.lowercased()
                            == resumeMarkerValue(sessionId: session.id, suffix: "copilot-session")?.lowercased()
                } ?? false
                if live {
                    setParked(session.id, nil)
                    save()
                } else if parked.state == .resuming,
                          nowMs - parked.sinceMilliseconds > SessionParking.resumeTimeoutMilliseconds {
                    // With a CLI running the session is live again, and the
                    // ordinary tracker warning says what is wrong with it.
                    setParked(session.id, liveCopilotSessions.contains(session.id) ? nil : .failed)
                    save()
                }
            case .parked:
                break
            }
        }
    }

    /// Settles records left by the last run, before any terminal is created.
    func reconcileParkedSessionsAtLaunch() {
        var changed = false
        for session in projects.flatMap(\.sessions) {
            guard let parked = session.parked else { continue }
            let next: ParkedSession.State?
            switch parked.state {
            case .parking:
                // A live master, or no recorded stop, means the stop never happened.
                if parked.processes.isEmpty || parkingRuntime.hasMaster(session.id) { next = nil }
                else if parked.processes.contains(where: parkingRuntime.isAlive) { continue }
                else { next = .parked }
            case .resuming:
                // The timeout was only in memory, so a resume under way gets a new one.
                next = parkingRuntime.hasMaster(session.id) ? .resuming : .parked
            case .parked, .failed:
                // A failed resume is tried again only when asked, restart or not.
                continue
            }
            setParked(session.id, next)
            changed = true
        }
        if changed { save() }
    }

    // MARK: - remote clients

    /// The gateway asks for the transcript revision of each connected client's
    /// open session on every refresh. Two in a row resume a parked session.
    func noteRemoteClientHasOpen(_ sessionId: String, now: Date = Date()) {
        let first = remoteOpenSessions[sessionId].flatMap {
            now.timeIntervalSince($0.last) <= SessionParking.remoteOpenWindow ? $0.first : nil
        }
        remoteOpenSessions[sessionId] = (first: first ?? now, last: now)
        if first != nil, parkedState(sessionId) == .parked { resumeParkedSession(sessionId) }
    }

    func remoteClientHasOpen(_ sessionId: String, now: Date = Date()) -> Bool {
        remoteOpenSessions[sessionId].map {
            now.timeIntervalSince($0.last) <= SessionParking.remoteOpenWindow
        } ?? false
    }

    // MARK: - commands

    /// Sessions "Park All Idle Sessions" would try, judged without asking Copilot.
    var parkableSessionIds: [String] {
        // One read of the dtach processes for the whole pass.
        let dtach = ProcessTree.dtachProcesses(in: ProcessTree.snapshot())
        return projects.flatMap(\.sessions).map(\.id).filter {
            parkBlocker(for: $0, unattended: true, dtach: dtach) == nil
        }
    }

    func parkSelectedSession() {
        guard let sessionId = globalSelectedSessionId else { return }
        Task { @MainActor [weak self] in
            guard let self, let reason = await self.parkSession(sessionId) else { return }
            self.presentAlert(title: "Couldn't Park This Session", message: reason)
        }
    }

    func parkAllIdleSessions() {
        let sessionIds = parkableSessionIds
        guard !sessionIds.isEmpty else {
            presentAlert(
                title: "No Sessions to Park",
                message: "Only sessions that are idle, read, and not on screen can be parked."
            )
            return
        }
        let bytes = projects.flatMap(\.sessions)
            .filter { sessionIds.contains($0.id) }
            .reduce(Int64(0)) { $0 + ($1.memoryUsageBytes ?? 0) }
        let alert = NSAlert()
        alert.messageText = sessionIds.count == 1 ? "Park 1 idle session?" : "Park \(sessionIds.count) idle sessions?"
        alert.informativeText = "Copilot quits in each one"
            + (bytes > 0 ? ", which frees about \(SessionMemoryBadge.formattedBytes(bytes))" : "")
            + ". It starts again when you open the session. A session that turns out to be busy is left alone."
        alert.addButton(withTitle: "Park")
        alert.addButton(withTitle: "Cancel")
        guard runAlert(alert) == .alertFirstButtonReturn else { return }
        Task { @MainActor [weak self] in
            // One at a time: each is one question and one stop.
            for sessionId in sessionIds { await self?.parkSession(sessionId, unattended: true) }
        }
    }

    /// Asked the first time parking is turned on. Returns whether to turn it on.
    func confirmParkingOptIn() -> Bool {
        guard !defaults.bool(forKey: SessionParking.explainedKey) else { return true }
        let alert = NSAlert()
        alert.messageText = "Park idle sessions?"
        alert.informativeText = "Parking quits Copilot in a session that isn't doing anything, which frees "
            + "its memory. The session stays in your list with its transcript. Copilot starts again when "
            + "you open the session, which takes a few seconds. Text you typed in a session's terminal "
            + "but didn't send is not kept. Sessions that are working, waiting for you, scheduled, or "
            + "running background work are never parked."
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard runAlert(alert) == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: SessionParking.explainedKey)
        return true
    }
}
