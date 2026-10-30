import Foundation
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsPullRequests
import Darwin

public enum RemotePromptResult: Equatable, Sendable {
    case sent
    case forbidden
    case invalid
    case busy
    case noLiveCopilot
}

public enum RemoteCommandResult: Equatable, Sendable {
    case sent
    case busy
    case invalid
    case missing
}

public enum RemoteTerminalInputResult: Equatable, Sendable {
    case sent
    case missing
    case invalid
}

struct RemoteCommandRequestLedger {
    private var accepted: Set<String> = []
    private var order: [String] = []

    mutating func contains(_ requestId: String) -> Bool {
        accepted.contains(requestId)
    }

    mutating func record(_ requestId: String, cap: Int = 512) {
        guard accepted.insert(requestId).inserted else { return }
        order.append(requestId)
        while order.count > cap {
            accepted.remove(order.removeFirst())
        }
    }
}

/// Outcome of accepting a remote answer to a structured `ask_user` question.
public enum RemoteUserInputResult: Equatable, Sendable {
    /// The request was published, or an identical correlated operation was replayed.
    case accepted
    /// A response for this tab is already awaiting the extension, or the question
    /// context changed underneath the answer.
    case conflict
    /// No matching live question, or the answer failed the choice/freeform/size rules.
    case invalid
}

/// On-disk shape of the host-written user-input response file. The extension
/// validates every field again before replying over RPC.
private struct UserInputResponseFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let operationId: String?
    let conversationEpoch: String?
    let kind: String?
    let payloadFingerprint: String?
    let requestId: String
    let answer: String
    let wasFreeform: Bool
}

/// On-disk shape of the host-written elicitation response file. The extension
/// re-validates against the live pending elicitation before replying over RPC.
private struct ElicitationResponseFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let operationId: String?
    let conversationEpoch: String?
    let kind: String?
    let payloadFingerprint: String?
    let requestId: String
    let action: String
    let content: [String: RemoteJSONValue]?
}

/// On-disk shape of the host-written set-model request file. The extension
/// re-validates the target against its live catalog before switching over RPC.
private struct SetModelRequestFile: Codable {
    let schemaVersion: Int
    let copilotSessionId: String
    let operationId: String?
    let conversationEpoch: String?
    let kind: String?
    let payloadFingerprint: String?
    let modelId: String
    let reasoningEffort: String?
    let contextTier: String?
}

struct RemotePromptTarget {
    let activity: FooterActivity
    let send: (String) -> Bool
}

struct RemoteElicitationTerminalTarget {
    let isAtLiveBottom: Bool
    let screen: RemoteTerminalScreen?
    let sendEnter: () -> Bool
}

public enum RemoteProjectCreationOutcome: Equatable, Sendable {
    case created(RemoteCreateProjectResponse)
    case existing(RemoteCreateProjectResponse)
    case conflict
    case gone
    case badRequest
    case unsupported
    case unavailable
    case persistenceUnavailable
}

/// Outcome of a remote `POST /sessions/create`. Each case maps to a distinct HTTP
/// status at the gateway so the client can react precisely (select, retry, or show
/// an unsupported/unavailable message).
public enum RemoteSessionCreationOutcome: Equatable, Sendable {
    /// A brand-new session was created and its controller launched. (201)
    case created(RemoteCreateSessionResponse)
    /// The deterministic session already exists in the requested project — the
    /// idempotent replay of an earlier successful create. Nothing was created. (200)
    case existing(RemoteCreateSessionResponse)
    /// The requested project id is not known to the host. (422)
    case unknownProject
    /// The request is well-formed but its working directory is missing or invalid.
    /// Nothing was created. (422)
    case invalid
    /// The request contains invalid or conflicting launch options or an invalid PR URL. (400)
    case badRequest
    /// The request id is already bound to a different project or launch intent. (409)
    case conflict
    /// The ledger shows this request was already processed but the session is gone;
    /// it is deliberately not recreated. (410)
    case gone
    /// A required executable or backend is unavailable, so no session was created. (503)
    case unavailable
    /// The workspace or creation ledger could not be read or durably written.
    /// The client must retry with the same request id. (503)
    case persistenceUnavailable
}

public enum RemoteSessionMoveResult: Equatable, Sendable {
    case moved
    case unchanged
    case missing
}

public enum RemoteSessionCloseResult: Equatable, Sendable {
    case closed, missing, failed
}

/// Outcome of `close-session`, mapped onto the CLI's stable response codes.
public enum AutomationSessionCloseResult: Equatable, Sendable {
    case closed, gone, conflict, busy, unavailable
}

extension AppModel {
    func createRemoteProject(
        _ request: RemoteCreateProjectRequest,
        now: Date = Date()
    ) -> RemoteProjectCreationOutcome {
        guard !isTerminating else { return .unavailable }
        guard !didFailToLoadWorkspaceState else { return .persistenceUnavailable }
        guard let name = RemoteProjectContract.normalizedName(request.name) else { return .badRequest }
        let projectId = request.requestId.uuidString
        let fingerprint = ProjectCreationRecord.fingerprint(name: name)
        let response = RemoteCreateProjectResponse(requestId: request.requestId, projectId: projectId)
        do {
            let record = try projectCreationLedger.record(for: request.requestId, now: now)
            if let record, record.creationFingerprint != fingerprint { return .conflict }
            let outcome: RemoteProjectCreationOutcome
            if let index = projectIndex(projectId) {
                let bound = record?.creationFingerprint ?? projects[index].creationFingerprint
                guard bound == fingerprint else { return .conflict }
                projects[index].creationFingerprint = fingerprint
                outcome = .existing(response)
            } else {
                guard record == nil else { return .gone }
                projects.append(Project(
                    id: projectId, name: name, cwd: Paths.defaultStartupDir,
                    creationFingerprint: fingerprint
                ))
                if selectedProjectId == nil { selectedProjectId = projectId }
                outcome = .created(response)
            }
            // Retain the live intent if persistence fails so the same request can repair it.
            try persistWorkspace()
            try projectCreationLedger.remember(
                record ?? ProjectCreationRecord(
                    requestId: projectId, createdAt: now, creationFingerprint: fingerprint
                ),
                now: now
            )
            return outcome
        } catch {
            NSLog("copilot-projects: could not persist remote project request "
                + "\(projectId); retry with the same request id: \(error.localizedDescription)")
            return .persistenceUnavailable
        }
    }

    /// Create (or idempotently resolve) a session for a remote `POST /sessions/create`.
    /// Runs synchronously on the MainActor and mutates state directly.
    ///
    /// The session id is deterministically the request's canonical UUID string, so a
    /// crash between appending the session and writing the ledger still lets a retry
    /// find the existing session (returning `.existing`) rather than double-creating.
    /// The ledger acts as a tombstone: once a request produced a session, a later
    /// request whose session has since been closed returns `.gone` and never recreates.
    /// The Mac's current selection is preserved — a new session only becomes the
    /// project's selected tab when the project had no selection.
    func createRemoteSession(
        _ request: RemoteCreateSessionRequest,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        guard request.kind == nil, request.initialPrompt == nil, request.pullRequestURL == nil else {
            return .badRequest
        }
        return createRemoteSession(
            request,
            isPlainCreate: true,
            kind: .copilot,
            title: "Copilot",
            initialPrompt: nil,
            now: now
        )
    }

    func createRemoteConfiguredSession(
        _ request: RemoteCreateSessionRequest,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        guard request.pullRequestURL == nil else { return .badRequest }
        let kind = request.kind ?? .copilot
        if let prompt = request.initialPrompt {
            guard kind == .copilot, SessionInputValidation.isValidPrompt(prompt) else {
                return .badRequest
            }
        }
        let prompt = request.initialPrompt?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return createRemoteSession(
            request,
            isPlainCreate: false,
            kind: kind,
            title: kind == .terminal ? "shell" : "Copilot",
            initialPrompt: prompt,
            now: now
        )
    }

    /// Local automation (control socket): a Copilot session with a starting prompt
    /// and caller-chosen title. Shares the remote creation ledger, so a retried
    /// request id returns `.existing`, `.conflict`, or `.gone` instead of launching
    /// a second session.
    func createLocalCopilotSession(
        requestId: UUID,
        projectId: String,
        title: String,
        prompt: String,
        hostId: String? = nil,
        parentSessionId: String? = nil,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidSessionTitle(title),
              SessionInputValidation.isValidPrompt(prompt) else {
            return .badRequest
        }
        let prompt = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return createRemoteSession(
            RemoteCreateSessionRequest(
                requestId: requestId,
                projectId: projectId,
                kind: .copilot,
                initialPrompt: prompt,
                hostId: hostId
            ),
            isPlainCreate: false,
            kind: .copilot,
            title: title,
            initialPrompt: prompt,
            parentSessionId: parentSessionId,
            now: now
        )
    }

    nonisolated static let maximumSessionTitleLength = 120

    nonisolated static func isValidSessionTitle(_ title: String) -> Bool {
        guard !title.isEmpty, title.count <= maximumSessionTitleLength else { return false }
        return !title.unicodeScalars.contains {
            $0.value < 0x20 || $0.value == 0x7f || (0x80 ... 0x9f).contains($0.value)
        }
    }

    nonisolated static func controlResponse(
        for outcome: RemoteSessionCreationOutcome
    ) -> ControlResponse {
        switch outcome {
        case .created(let response):
            return .success(response.sessionId, code: "created")
        case .existing(let response):
            return .success(response.sessionId, code: "existing")
        case .unknownProject:
            return .failure("unknown project", code: "unknown-project")
        case .invalid:
            return .failure("the working directory is missing or invalid", code: "invalid")
        case .badRequest:
            return .failure("invalid title or prompt", code: "bad-request")
        case .conflict:
            return .failure("request id is bound to a different session", code: "conflict")
        case .gone:
            return .failure("request id already created a session that has since ended",
                            code: "gone")
        case .unavailable:
            return .failure("Copilot or the session backend is unavailable", code: "unavailable")
        case .persistenceUnavailable:
            return .failure("could not persist the session; retry with the same request id",
                            code: "persistence-unavailable")
        }
    }

    func createRemoteAdversarialReviewSession(
        _ request: RemoteCreateSessionRequest,
        now: Date = Date()
    ) -> RemoteSessionCreationOutcome {
        guard request.kind == nil, request.initialPrompt == nil,
              let rawURL = request.pullRequestURL,
              let target = PullRequestReviewTarget.parse(rawURL),
              rawURL == target.url else {
            return .badRequest
        }
        return createRemoteSession(
            request,
            isPlainCreate: false,
            kind: .copilot,
            title: target.title,
            initialPrompt: pullRequestReviewPrompt(for: target),
            now: now
        )
    }

    /// Where a created session starts, and whether it takes its project's selection.
    private enum CreatedSessionPlacement {
        /// Remote clients: in the configured startup folder, without stealing Mac selection.
        case remote
        /// Copilot Pull Requests: like Start Session in the app, in the project's
        /// current folder and selected in its project.
        case local
        /// Remote PR Start uses the same current folder, without changing Mac selection.
        case project
    }

    /// `isPlainCreate` is the unconfigured `sessions/create` route, which re-adopts an
    /// orphaned terminal for its request and resumes that tab's recorded Copilot session.
    private func createRemoteSession(
        _ request: RemoteCreateSessionRequest,
        isPlainCreate: Bool,
        kind: RemoteSessionKind,
        title: String,
        initialPrompt: String?,
        placement: CreatedSessionPlacement = .remote,
        fingerprintOverride: String? = nil,
        pullRequestKeys: [String]? = nil,
        parentSessionId: String? = nil,
        now: Date
    ) -> RemoteSessionCreationOutcome {
        // A failed startup load leaves the in-memory workspace empty, so neither
        // missing projects nor absent sessions are authoritative.
        if didFailToLoadWorkspaceState {
            return .persistenceUnavailable
        }
        let trimmedRequestedHostId = request.hostId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRequestedHostId = (trimmedRequestedHostId?.isEmpty == false)
            ? trimmedRequestedHostId?.lowercased()
            : nil
        let sessionId = request.requestId.uuidString
        let fingerprint = fingerprintOverride ?? SessionCreationRecord.fingerprint(
            projectId: request.projectId,
            kind: kind,
            // Review retries stay keyed by the pull request URL. The review prompt
            // is a user setting and can change between a client's retries.
            initialPrompt: request.pullRequestURL == nil ? initialPrompt : nil,
            pullRequestURL: request.pullRequestURL,
            hostId: normalizedRequestedHostId
        )
        let creationRecord: SessionCreationRecord?
        do {
            creationRecord = try sessionCreationLedger.record(
                for: request.requestId,
                now: now
            )
        } catch {
            NSLog(
                "copilot-projects: could not read remote session creation ledger "
                    + "for request \(sessionId); retry with the same request id: "
                    + error.localizedDescription
            )
            return .persistenceUnavailable
        }
        if let bound = creationRecord?.creationFingerprint, bound != fingerprint {
            return .conflict
        }

        // A live deterministic session answers replays directly and covers the
        // failure window where the session launched but workspace or ledger
        // persistence did not finish. Repair both durable records before reporting
        // success, without launching the already-live session again.
        if let loc = locateIndex(sessionId) {
            let owningProjectId = projects[loc.p].id
            let sessionFingerprint = projects[loc.p].sessions[loc.s].creationFingerprint
            if let sessionFingerprint, sessionFingerprint != fingerprint {
                return .conflict
            }
            guard let boundFingerprint = creationRecord?.creationFingerprint ?? sessionFingerprint else {
                return .conflict
            }
            let response = RemoteCreateSessionResponse(
                requestId: request.requestId,
                projectId: owningProjectId,
                sessionId: sessionId
            )
            if let record = creationRecord {
                guard record.projectId == request.projectId,
                      record.sessionId == sessionId else {
                    return .conflict
                }
            }
            projects[loc.p].sessions[loc.s].creationFingerprint = boundFingerprint
            guard persistRemoteCreation(
                request: request,
                creationFingerprint: boundFingerprint,
                existingRecord: creationRecord,
                now: now
            ) else {
                return .persistenceUnavailable
            }
            return .existing(response)
        }

        // Processed before, but the session is gone: it is a tombstone, never resurrect it.
        if let creationRecord {
            return creationRecord.creationFingerprint == nil ? .conflict : .gone
        }

        // An orphaned terminal has no trustworthy intent binding to replay.
        if !isPlainCreate,
           FileManager.default.fileExists(atPath: Paths.dtachSocketPath(sessionId: sessionId)) {
            return .conflict
        }

        guard let pi = projectIndex(request.projectId) else { return .unknownProject }
        if let normalizedRequestedHostId,
           resolvedRemoteHost(hostId: normalizedRequestedHostId) == nil {
            return .badRequest
        }
        guard let resolvedHost = resolvedRemoteHost(
            hostId: normalizedRequestedHostId,
            projectDefaultHostId: projects[pi].defaultHostId
        ) else {
            return .unavailable
        }
        if isPlainCreate,
           FileManager.default.fileExists(atPath: Paths.dtachSocketPath(sessionId: sessionId))
               || resumeMarkerValue(sessionId: sessionId, suffix: "copilot-session") != nil
               || resumeMarkerValue(sessionId: sessionId, suffix: "remote-host") != nil {
            let recordedHost = resumeMarkerValue(sessionId: sessionId, suffix: "remote-host")
                .flatMap { raw -> String? in
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty,
                          trimmed.caseInsensitiveCompare(RemoteHostInfo.localId) != .orderedSame else {
                        return nil
                    }
                    return resolvedRemoteHost(hostId: trimmed)?.id ?? trimmed
                }
            let targetHost = resolvedHost.isLocal ? nil : resolvedHost.id
            if recordedHost?.lowercased() != targetHost?.lowercased() {
                return .conflict
            }
        }
        guard remoteSessionBackendAvailable() else { return .unavailable }
        let copilotExecutable: String?
        if kind == .copilot {
            guard let executable = resolvedHost.isLocal
                ? remoteCopilotExecutable()
                : remoteWrapperExecutable() else { return .unavailable }
            copilotExecutable = executable
        } else {
            copilotExecutable = nil
        }
        let cwd: String
        switch placement {
        case .remote:
            if resolvedHost.isLocal {
                guard let repos = remoteReposDirectory() else { return .invalid }
                cwd = repos
            } else if let folder = resolvedHost.defaultCwd {
                cwd = folder
            } else {
                let folder = remoteReposDirectory() ?? Paths.defaultStartupDir
                guard folder.hasPrefix("/") else { return .invalid }
                cwd = folder
            }
        case .local, .project:
            let folder = Paths.normalizedDirectory(defaultCwd(forProjectIndex: pi, targetHost: resolvedHost))
            if resolvedHost.isLocal {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return .invalid }
            }
            cwd = folder
        }

        if !isPlainCreate {
            let marker = resumeMarkerDirectory.appendingPathComponent("\(sessionId).copilot-session")
            if unlink(marker.path) != 0 && errno != ENOENT {
                return .persistenceUnavailable
            }
        }
        let hostMarker = resumeMarkerDirectory.appendingPathComponent("\(sessionId).remote-host")
        if resolvedHost.isLocal {
            if unlink(hostMarker.path) != 0 && errno != ENOENT {
                return .persistenceUnavailable
            }
        } else if (try? Data(resolvedHost.id.utf8).write(to: hostMarker, options: .atomic)) == nil {
            return .persistenceUnavailable
        }

        let resolvedParentSessionId = projects[pi].resolvedParentSessionId(
            for: parentSessionId,
            excluding: sessionId
        )
        let sessionHostId = resolvedHost.isLocal ? nil : resolvedHost.id
        let session = Session(
            id: sessionId,
            title: title,
            cwd: cwd,
            hostId: sessionHostId,
            creationFingerprint: fingerprint,
            pullRequestKeys: pullRequestKeys,
            parentSessionId: resolvedParentSessionId
        )
        let previousSelection = projects[pi].selectedSessionId
        projects[pi].sessions.append(session)
        // A remote client must NOT steal the Mac's selected tab: only adopt the new
        // session when the project currently has no selection.
        if placement == .local || (placement == .remote && (projects[pi].selectedSessionId ?? "").isEmpty) {
            projects[pi].selectedSessionId = sessionId
        }

        launchSession(
            sessionId,
            executable: copilotExecutable,
            initialPrompt: initialPrompt,
            resumeRecordedSession: isPlainCreate
        )
        // Like Start Session in the app, never keep a tab whose terminal didn't
        // start; nothing is recorded, so nothing was created.
        if placement != .remote, remoteSessionLauncher == nil,
           controllers[sessionId]?.terminalView.process?.running != true {
            controllers[sessionId] = nil
            projects[pi].sessions.removeAll { $0.id == sessionId }
            projects[pi].selectedSessionId = previousSelection
            return .unavailable
        }
        refreshSelectedTranscriptController()

        // Launch remains before persistence so a saved session cannot be stranded
        // without its one-shot initial prompt. A persistence failure is surfaced as
        // retryable; the live deterministic session is retained so the retry can
        // repair state without relaunching it.
        guard persistRemoteCreation(
            request: request,
            creationFingerprint: fingerprint,
            now: now
        ) else {
            return .persistenceUnavailable
        }

        return .created(RemoteCreateSessionResponse(
            requestId: request.requestId,
            projectId: request.projectId,
            sessionId: sessionId
        ))
    }

    private func persistRemoteCreation(
        request: RemoteCreateSessionRequest,
        creationFingerprint: String?,
        existingRecord: SessionCreationRecord? = nil,
        now: Date
    ) -> Bool {
        do {
            // Older builds could write the ledger after a failed workspace save.
            // An existing record alone therefore cannot prove this session is saved.
            try persistWorkspace()
        } catch {
            NSLog(
                "copilot-projects: could not persist workspace for remote session "
                    + "request \(request.requestId.uuidString); retry with the same request id: "
                    + error.localizedDescription
            )
            return false
        }
        if let existingRecord, existingRecord.creationFingerprint == creationFingerprint {
            return true
        }
        do {
            try sessionCreationLedger.remember(
                SessionCreationRecord(
                    requestId: request.requestId.uuidString,
                    projectId: request.projectId,
                    sessionId: request.requestId.uuidString,
                    createdAt: existingRecord?.createdAt ?? now,
                    creationFingerprint: creationFingerprint
                ),
                now: now
            )
            return true
        } catch {
            NSLog(
                "copilot-projects: could not persist remote session creation ledger "
                    + "for request \(request.requestId.uuidString); retry with the same request id: "
                    + error.localizedDescription
            )
            return false
        }
    }

    func closeRemoteSession(sessionId: String) -> RemoteSessionCloseResult {
        guard let location = locateIndex(sessionId) else { return .missing }
        return destroySession(
            projectId: projects[location.p].id,
            sessionId: sessionId
        ) ? .closed : .failed
    }

    /// Scripted ending (`close-session`). Unlike the remote path, no person confirmed
    /// the close, so it refuses a session that has reported work or is the selected
    /// tab of the selected project (what the window shows, even while another app is
    /// in front). `projectId` refuses a session the user has since moved elsewhere.
    func closeAutomationSession(
        sessionId: String,
        projectId: String?
    ) -> AutomationSessionCloseResult {
        // A failed startup load leaves the in-memory workspace empty, so an absent
        // session is not evidence that it ended.
        guard !isTerminating, !didFailToLoadWorkspaceState, stateLoadFailure == nil else {
            return .unavailable
        }
        guard let location = locateIndex(sessionId) else { return .gone }
        let project = projects[location.p]
        if let projectId, project.id != projectId { return .conflict }
        if project.sessions[location.s].requiresEndConfirmation
            || (selectedProjectId == project.id && project.selectedSessionId == sessionId) {
            return .busy
        }
        return destroySession(projectId: project.id, sessionId: sessionId) ? .closed : .unavailable
    }

    nonisolated static func controlResponse(
        for outcome: AutomationSessionCloseResult
    ) -> ControlResponse {
        switch outcome {
        case .closed:
            return .success(code: "closed")
        case .gone:
            return .failure("no such session", code: "gone")
        case .conflict:
            return .failure("the session belongs to a different project", code: "conflict")
        case .busy:
            return .failure("the session is the selected tab or has active or pending work; "
                + "retry later", code: "busy")
        case .unavailable:
            return .failure("the workspace state is unavailable; retry later", code: "unavailable")
        }
    }

    func remoteWorkspaceSnapshot() -> RemoteWorkspaceSnapshot {
        let promptNow = Date()
        let promptNowMs = SessionArtifacts.currentStatusTimestamp()
        let promptLiveSessions = remotePromptLiveSessions?(agentProcessNames) ?? liveAgentSessions
        let hosts = availableHosts
        let resolvedHostHealth = hostHealthProvider?() ?? hostHealth
        let providedSessionMemory = sessionMemoryProvider?()
        return RemoteWorkspaceSnapshot(
            projects: projects.map { project in
                let effectiveParents = project.effectiveParentSessionIdsBySessionId()
                return RemoteProjectSnapshot(
                    id: project.id,
                    name: project.name,
                    selectedSessionId: project.selectedSessionId,
                    defaultHostId: project.defaultHostId,
                    sessions: project.sessions.map { session in
                        let operation = session.agentActivity?
                            .remoteOperationProjection(at: promptNow)
                            ?? .unavailable
                        let foreground = runtimeForegroundActivity(
                            for: session, now: promptNow
                        )
                        let status = projectedStatus(
                            for: session, foreground: foreground, now: promptNow
                        )
                        let remoteHost = resolvedRemoteHost(for: session, in: hosts)
                        return RemoteSessionSnapshot(
                            id: session.id,
                            title: session.title,
                            status: status.rawValue,
                            statusText: status != .waiting && (status == .running || session.hasBackgroundWork)
                                ? session.agentActivity?.remoteActivityText(
                                    expectedSessionId: resumeMarkerValue(
                                        sessionId: session.id, suffix: "copilot-session"
                                    ),
                                    at: promptNow
                                )
                                : session.statusText,
                            unread: session.isUnread,
                            ready: session.finishedUnseen,
                            background: session.hasBackgroundWork,
                            scheduled: !session.schedules.isEmpty,
                            promptable: Self.remotePromptEligibility(
                                status: status,
                                scheduledTurnActive: session.scheduledTurnActive,
                                hasPendingQuestions: session.hasPendingInput,
                                hasLiveAgent: promptLiveSessions.contains(session.id),
                                backgroundOnly: Self.backgroundOnlyPromptEvidence(
                                    status: session.status,
                                    snapshot: session.agentActivity,
                                    backgroundAgentsActive: session.backgroundAgentsActive,
                                    now: promptNow,
                                    nowMs: promptNowMs,
                                    clockMs: sessionSemantics.promptSafetyClock.timestamp(
                                        for: session.id
                                    )
                                ),
                                footerActivity: remotePromptTarget?(session.id)?.activity
                                    ?? controllers[session.id]?.agentActivity
                                    ?? .unknown,
                                foregroundActivity: foreground
                            ) == .sent,
                            pendingUserInputs: session.agentActivity?
                                .remoteUserInputRequests(),
                            pendingElicitations: session.agentActivity?
                                .remoteElicitationRequests(),
                            model: session.agentActivity?.remoteModelInfo(),
                            availableModels: session.agentActivity?
                                .remoteAvailableModels(),
                            conversationEpoch: operation.conversationEpoch,
                            operationSupport: operation.support,
                            operationReceipts: operation.receipts,
                            workflow: session.agentActivity?.workflow,
                            lastError: status == .idle
                                ? session.agentActivity?.remoteLastError()
                                : nil,
                            markedUnread: session.markedUnread ? true : nil,
                            hostId: remoteHost?.id,
                            hostDisplayName: remoteHost?.displayName,
                            parentSessionId: effectiveParents[session.id],
                            memoryUsageBytes: providedSessionMemory.map {
                                ProcessTree.quantizeSessionMemoryBytes($0[session.id])
                            } ?? session.memoryUsageBytes
                        )
                    }
                )
            },
            selectedProjectId: selectedProjectId,
            protocolInfo: .current.supportingReplaySafeControl(epoch: remoteControlDeliveryEpoch),
            availableHosts: hosts.count > 1 ? hosts : nil,
            hostHealth: resolvedHostHealth.isEmpty ? nil : resolvedHostHealth
        )
    }

    func remoteScreen(
        sessionId: String,
        afterLine: Int? = nil
    ) -> RemoteTerminalScreen? {
        guard locateIndex(sessionId) != nil,
              let view = controller(for: sessionId)?.terminalView,
              !view.isRestoringImages,
              let input = view.terminalInputStateSnapshot() else { return nil }
        let terminalScroll = input.isAlternateBuffer || liveAgentSessions.contains(sessionId)
        guard let snapshot = view.terminalContentSnapshot(
            region: terminalScroll ? .viewport : .history(maximumScrollbackRows: 500)),
              snapshot.inputState.isAlternateBuffer == input.isAlternateBuffer
        else { return nil }
        let screen = RemoteTerminalScreen.capture(
            sessionId: sessionId, snapshot: snapshot,
            terminalScroll: terminalScroll, afterLine: afterLine)
        // Scan the entire copied window, not just the afterLine-narrowed text.
        // Images crossing the incremental boundary retain their full geometry.
        let placements = RemoteKittyPlacementScanner.scan(
            cells: RemoteKittyPlacementScanner.gridCells(
                from: snapshot.rows,
                relativeTo: terminalScroll ? snapshot.capturedRange.lowerBound : 0),
            firstLine: screen.firstLine,
            priorityLineRange: screen.firstLine ..< (screen.firstLine + screen.lines.count),
            currentVersion: { imageId, placementId in
                view.kittyImageCapture.currentVersion(for: imageId, placementId: placementId)
            })
        // A present empty array authoritatively clears previous placements.
        return screen.withImages(placements)
    }

    /// The replay lookup must be outside the lease lock: an exact retry only
    /// acknowledges accepted work, whereas a new delivery must recheck its lease.
    func performRemoteControl(
        _ message: RemoteClientMessage,
        perform: () -> RemoteControlResult
    ) -> RemoteControlResult {
        let location = message.sessionId.flatMap { locateIndex($0) }
        return remoteControlDeliveryLedger.perform(
            message,
            sessionExists: location != nil
        ) {
            if message.type == "prompt" {
                guard let location,
                      projects[location.p].sessions[location.s].agentActivity?
                        .remoteOperationProjection().conversationEpoch == message.conversationEpoch else {
                    return .invalid
                }
            }
            return perform()
        }
    }

    @discardableResult
    func sendRemoteInput(sessionId: String, value: String) -> RemoteTerminalInputResult {
        guard value.utf8.count <= 8_192 else { return .invalid }
        guard let view = remoteInputTerminal(sessionId: sessionId) else { return .missing }
        view.sendRemoteInput(value)
        return .sent
    }

    @discardableResult
    func sendRemoteKey(sessionId: String, key: String) -> RemoteTerminalInputResult {
        guard ["enter", "escape", "backspace", "tab", "up", "down", "left", "right"]
            .contains(key) else { return .invalid }
        guard let view = remoteInputTerminal(sessionId: sessionId) else { return .missing }
        return view.sendRemoteKey(
            key,
            forceFocusReporting: key == "enter"
                && remoteSessionHasLiveAgent(sessionId)
        ) ? .sent : .invalid
    }

    private func remoteInputTerminal(sessionId: String) -> ProjectsTerminalView? {
        guard locateIndex(sessionId) != nil,
              !isTerminating,
              let controller = controller(for: sessionId),
              !controller.exited,
              controller.shellPID > 0,
              controller.terminalView.terminalInputStateSnapshot() != nil else { return nil }
        return controller.terminalView
    }

    func sendRemoteCommand(
        sessionId: String,
        requestId: String,
        value: String
    ) -> RemoteCommandResult {
        let ledgerId = "\(sessionId):\(requestId)"
        if remoteCommandRequestLedger.contains(ledgerId) {
            return .sent
        }
        guard ProjectsTerminalView.remoteCommandTextBytes(value) != nil else {
            return .invalid
        }
        guard let view = remoteInputTerminal(sessionId: sessionId) else { return .missing }
        guard view.sendRemoteCommand(
            value,
            forceFocusReporting: remoteSessionHasLiveAgent(sessionId)
        ) else {
            return .busy
        }
        remoteCommandRequestLedger.record(ledgerId)
        return .sent
    }

    private func remoteSessionHasLiveAgent(_ sessionId: String) -> Bool {
        if liveAgentSessions.contains(sessionId) {
            return true
        }
        let liveSessions = remotePromptLiveSessions?(agentProcessNames)
            ?? ProcessTree.agentSessions(
                agentNames: agentProcessNames,
                in: ProcessTree.snapshot()
            )
        return liveSessions.contains(sessionId)
    }

    func sendRemoteScroll(sessionId: String, delta: Int) {
        guard (-20...20).contains(delta) else { return }
        controller(for: sessionId)?.terminalView.sendRemoteScroll(
            delta: delta,
            agentLive: liveAgentSessions.contains(sessionId)
        )
    }

    func sendRemotePrompt(sessionId: String, value: String) -> RemotePromptResult {
        guard ProjectsTerminalView.remotePromptPasteBytes(value) != nil,
              let location = locateIndex(sessionId) else { return .invalid }
        let session = projects[location.p].sessions[location.s]
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        if adapter.bounceBlocksAutomaticPrompts(
            sessionId: sessionId, cachedSnapshot: session.agentActivity, now: { Date() }
        ) {
            return .busy
        }
        let liveSessions = remotePromptLiveSessions?(agentProcessNames)
            ?? ProcessTree.agentSessions(
                agentNames: agentProcessNames,
                in: ProcessTree.snapshot()
            )
        let target: RemotePromptTarget?
        if let remotePromptTarget {
            target = remotePromptTarget(sessionId)
        } else if let controller = controllers[sessionId],
                  let view = remoteInputTerminal(sessionId: sessionId) {
            target = RemotePromptTarget(
                activity: controller.agentActivity,
                send: { view.sendRemotePrompt($0) }
            )
        } else {
            target = nil
        }
        let promptNow = Date()
        let promptNowMs = SessionArtifacts.currentStatusTimestamp()
        let foreground = runtimeForegroundActivity(for: session, now: promptNow)
        let eligibility = Self.remotePromptEligibility(
            status: projectedStatus(for: session, foreground: foreground, now: promptNow),
            scheduledTurnActive: session.scheduledTurnActive,
            hasPendingQuestions: session.hasPendingInput,
            hasLiveAgent: liveSessions.contains(sessionId),
            backgroundOnly: Self.backgroundOnlyPromptEvidence(
                status: session.status,
                snapshot: session.agentActivity,
                backgroundAgentsActive: session.backgroundAgentsActive,
                now: promptNow,
                nowMs: promptNowMs,
                clockMs: sessionSemantics.promptSafetyClock.timestamp(for: sessionId)
            ),
            footerActivity: target?.activity ?? .unknown,
            foregroundActivity: foreground
        )
        if eligibility == .busy { return .busy }
        guard liveSessions.contains(sessionId),
              let target else {
            return .noLiveCopilot
        }
        let fence: RemotePromptFence?
        if foreground == .idle,
           let root = session.agentActivity?.copilotSessionId,
           let epoch = session.agentActivity?.conversationEpoch {
            fence = RemotePromptFence(
                submittedAt: promptNowMs,
                rootSessionId: root,
                conversationEpoch: epoch
            )
            remotePromptFences[sessionId] = fence
        } else {
            fence = nil
        }
        guard target.send(value) else {
            if remotePromptFences[sessionId] == fence {
                remotePromptFences[sessionId] = nil
            }
            return .invalid
        }
        return .sent
    }

    /// Whether a remote message may be sent to a session right now. Readiness of the
    /// *foreground* is the gate — primarily the terminal footer, NOT whether the
    /// session is globally `.running`. Scheduled work and subagents can keep the
    /// session globally active after the foreground has returned to an idle prompt,
    /// so gating on that background state stranded the composer's queued messages.
    ///
    /// `status == .waiting` is still blocked: it marks a foreground question the user
    /// must answer inline — an `ask_user`/`elicitation` dialog OR a raw tool
    /// permission prompt. Permission prompts surface *only* via the CLI status hook
    /// (they populate no structured-question entry, so `hasPendingQuestions` is
    /// `false` for them) and the footer can read `.idle` behind the dialog, so the
    /// `.waiting` check is the one signal that reliably guards them.
    /// `hasPendingQuestions` is the extension's authoritative signal for structured
    /// questions. Scheduled work is allowed only with fresh, clock-ordered evidence
    /// that the interactive foreground is inactive.
    /// `sendRemotePrompt` re-checks the footer immediately before the actual send.
    nonisolated static func remotePromptEligibility(
        status: SessionStatus,
        scheduledTurnActive: Bool = false,
        hasPendingQuestions: Bool = false,
        hasLiveAgent: Bool,
        backgroundOnly: Bool = false,
        footerActivity: FooterActivity,
        foregroundActivity: ForegroundActivity? = nil
    ) -> RemotePromptResult {
        SessionSemanticsAdapter.remotePromptResult(
            status: status,
            scheduledTurnActive: scheduledTurnActive,
            hasPendingQuestions: hasPendingQuestions,
            hasLiveAgent: hasLiveAgent,
            backgroundOnly: backgroundOnly,
            footerActivity: footerActivity,
            foregroundActivity: foregroundActivity
        )
    }

    /// Evidence that a session is only busy because scheduled, subagent, or CLI
    /// background-agent work remains after the interactive foreground ended. This
    /// mirrors the causal guards in `reconcileAgentFooters`: stale footer text alone
    /// is never enough to inject a remote prompt over a possibly-active foreground
    /// turn.
    ///
    /// `backgroundAgentsActive` carries the session's CLI background-agent state
    /// (scraped from the terminal title: "Copilot: Waiting for background agents").
    /// Those agents have no representation in the heartbeat's `activeSubagents`
    /// array, yet they keep `session.idle` from firing exactly like scheduled and
    /// subagent work — so a `.running` session whose foreground has gone idle while
    /// they run must count as background-only too, or it reads "working" forever.
    nonisolated static func backgroundOnlyPromptEvidence(
        status: SessionStatus,
        snapshot: AgentActivitySnapshot?,
        backgroundAgentsActive: Bool,
        now: Date,
        nowMs: Int64,
        clockMs: Int64?
    ) -> Bool {
        SessionSemanticsAdapter.hasBackgroundOnlyPromptEvidence(
            status: status,
            snapshot: snapshot,
            backgroundAgentsActive: backgroundAgentsActive,
            now: now,
            nowMilliseconds: nowMs,
            promptClockMilliseconds: clockMs
        )
    }

    /// Accept a remote answer to a structured `ask_user` question and hand it to the
    /// extension via an atomically-written response file. Validation re-reads the
    /// fresh heartbeat snapshot from disk (never trusting in-memory state) so a stale
    /// or superseded question can't be answered, and the exact choice/freeform/size
    /// rules are enforced host-side before anything is written.
    func answerUserInput(
        sessionId: String,
        answer: RemoteUserInputAnswer,
        operation: CLIOperationRequest? = nil,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        let clock = advancingClock(from: now)
        guard locateIndex(sessionId) != nil else { return .invalid }
        guard !answer.requestId.isEmpty,
              answer.requestId.utf8.count <= 200,
              answer.answer.utf8.count <= 8_192 else {
            return .invalid
        }
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        return adapter.submit(
            sessionId: sessionId,
            kind: .answerUserInput,
            operation: operation,
            fingerprintPayload: answer,
            handoffSuffix: "user-input-response.json",
            now: clock,
            validate: { snapshot in
                guard let request = snapshot.trackedUserInputs?
                    .first(where: { $0.requestId == answer.requestId }) else {
                    return false
                }
                if answer.wasFreeform {
                    return request.allowFreeform
                }
                return request.choices.contains(answer.answer)
            },
            makeHandoff: { metadata in
                UserInputResponseFile(
                    schemaVersion: 1,
                    copilotSessionId: metadata.copilotSessionId,
                    operationId: metadata.operationId,
                    conversationEpoch: metadata.conversationEpoch,
                    kind: metadata.kind,
                    payloadFingerprint: metadata.payloadFingerprint,
                    requestId: answer.requestId,
                    answer: answer.answer,
                    wasFreeform: answer.wasFreeform
                )
            }
        )
    }

    /// Submit a remote answer to a pending elicitation. Mirrors `answerUserInput`:
    /// re-reads the fresh heartbeat snapshot from disk, validates the request is
    /// still live, binds to the tab's Copilot session, and writes an atomic
    /// single-outstanding response file the extension consumes over RPC.
    func answerElicitation(
        sessionId: String,
        answer: RemoteElicitationAnswer,
        operation: CLIOperationRequest? = nil,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        let clock = advancingClock(from: now)
        guard let location = locateIndex(sessionId) else { return .invalid }
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        guard !answer.requestId.isEmpty,
              answer.requestId.utf8.count <= 200 else {
            return .invalid
        }
        switch answer.action {
        case .accept:
            if let content = answer.content {
                guard Self.isValidElicitationContent(content),
                      let encoded = try? JSONEncoder().encode(content),
                      encoded.count <= 32_768 else {
                    return .invalid
                }
            }
        case .decline, .cancel:
            guard answer.content == nil else { return .invalid }
        }

        func validates(_ request: TrackedElicitation) -> Bool {
            switch answer.action {
            case .accept:
                if answer.requestId.hasPrefix("synthetic::durable-ask-user::") {
                    return Self.durableDefaultBooleanSelection(
                        request: request,
                        answer: answer
                    ) != nil
                }
                if request.mode == "url" || request.url != nil {
                    return answer.content == nil
                }
                guard let content = answer.content,
                      Self.isValidElicitationContent(content),
                      Self.elicitationContent(
                          content,
                          satisfies: request.schema,
                          allowFreeformStringChoices: request.elicitationSource == nil
                      ),
                      let encoded = try? JSONEncoder().encode(content),
                      encoded.count <= 32_768 else {
                    return false
                }
                return true
            case .decline, .cancel:
                return answer.content == nil
            }
        }

        let initialSnapshot = adapter.loadFreshSnapshot(
            sessionId: sessionId,
            now: clock
        )
        let initialRequest = initialSnapshot?.trackedElicitations?
            .first(where: { $0.requestId == answer.requestId })
        if answer.requestId.hasPrefix("synthetic::durable-ask-user::") {
            guard operation == nil else { return .conflict }
            guard let request = initialRequest,
                  let snapshot = initialSnapshot,
                  validates(request) else {
                return .invalid
            }
            let ledgerId = "\(sessionId):elicitation:\(answer.requestId)"
            if remoteElicitationRequestLedger.contains(ledgerId) {
                return .conflict
            }
            let terminalTarget: RemoteElicitationTerminalTarget?
            if let remoteElicitationTarget {
                terminalTarget = remoteElicitationTarget(sessionId)
            } else if let terminalView = terminalView(for: sessionId) {
                terminalTarget = RemoteElicitationTerminalTarget(
                    isAtLiveBottom: Self.durableElicitationIsAtLiveBottom(
                        canScroll: terminalView.canScroll,
                        scrollPosition: terminalView.scrollPosition
                    ),
                    screen: remoteScreen(sessionId: sessionId),
                    sendEnter: {
                        terminalView.sendRemoteKey(
                            "enter",
                            forceFocusReporting: true
                        )
                    }
                )
            } else {
                terminalTarget = nil
            }
            guard snapshot.isFresh(at: clock(), ttl: 10),
                  snapshot.pendingPermissionRequestIds?.isEmpty == true,
                  projects[location.p].sessions[location.s].status == .waiting,
                  let terminalTarget,
                  remoteSessionHasLiveAgent(sessionId),
                  terminalTarget.isAtLiveBottom,
                  let selected = Self.durableDefaultBooleanSelection(
                    request: request,
                    answer: answer
                  ),
                  let screen = terminalTarget.screen,
                  screen.scrollMode == .terminal,
                  Self.durableBooleanPromptIsVisible(
                    lines: screen.lines,
                    request: request,
                    selected: selected
                  )
            else { return .invalid }
            guard terminalTarget.sendEnter() else { return .invalid }
            remoteElicitationRequestLedger.record(ledgerId)
            return .accepted
        }
        return adapter.submit(
            sessionId: sessionId,
            kind: .answerElicitation,
            operation: operation,
            fingerprintPayload: answer,
            handoffSuffix: "elicitation-response.json",
            now: clock,
            validate: { freshSnapshot in
                guard let freshRequest = freshSnapshot.trackedElicitations?
                    .first(where: { $0.requestId == answer.requestId }) else {
                    return false
                }
                return validates(freshRequest)
            },
            makeHandoff: { metadata in
                ElicitationResponseFile(
                    schemaVersion: 1,
                    copilotSessionId: metadata.copilotSessionId,
                    operationId: metadata.operationId,
                    conversationEpoch: metadata.conversationEpoch,
                    kind: metadata.kind,
                    payloadFingerprint: metadata.payloadFingerprint,
                    requestId: answer.requestId,
                    action: answer.action.rawValue,
                    content: answer.action == .accept ? answer.content : nil
                )
            }
        )
    }

    nonisolated static func durableDefaultBooleanSelection(
        request: TrackedElicitation,
        answer: RemoteElicitationAnswer
    ) -> Bool? {
        guard request.requestId.hasPrefix("synthetic::durable-ask-user::"),
              request.mode == "terminal-default",
              answer.action == .accept,
              let content = answer.content,
              content.count == 1,
              case .object(let root)? = request.schema,
              Set(root.keys) == [
                "properties", "x-copilot-projects-terminal-default"
              ],
              root["x-copilot-projects-terminal-default"] == .bool(true),
              case .object(let properties)? = root["properties"],
              properties.count == 1,
              let fieldName = properties.keys.first,
              case .object(let field)? = properties[fieldName],
              field["type"] == .string("boolean"),
              case .bool(let defaultValue)? = field["default"],
              case .bool(let selected)? = content[fieldName],
              selected == defaultValue
        else { return nil }
        return selected
    }

    nonisolated static func durableBooleanPromptIsVisible(
        lines: [String],
        request: TrackedElicitation,
        selected: Bool
    ) -> Bool {
        let normalizedLines = lines.map(normalizedTerminalText)
        let message = normalizedTerminalText(request.message)
        let selectedRow = selected ? "❯ Yes" : "❯ No"
        guard !message.isEmpty,
              let headerIndex = normalizedLines.lastIndex(
                of: "Copilot needs information."
              )
        else { return false }

        let promptLines = Array(normalizedLines.dropFirst(headerIndex + 1))
        let highlightedRows = promptLines.filter { $0.hasPrefix("❯ ") }
        guard highlightedRows == [selectedRow],
              let selectionIndex = promptLines.firstIndex(of: selectedRow)
        else { return false }

        let trailingLines = promptLines.dropFirst(selectionIndex + 1)
            .filter { !$0.isEmpty }
        guard trailingLines.allSatisfy({ $0 == "Yes" || $0 == "No" }) else {
            return false
        }
        let promptText = promptLines[..<selectionIndex].joined(separator: " ")
        return promptText == message || promptText.hasPrefix(message + " ")
    }

    nonisolated static func durableElicitationIsAtLiveBottom(
        canScroll: Bool,
        scrollPosition: Double
    ) -> Bool {
        !canScroll || scrollPosition >= 1
    }

    private nonisolated static func normalizedTerminalText(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Submit a remote model switch. Mirrors `answerUserInput`/`answerElicitation`:
    /// re-reads the fresh heartbeat snapshot, validates the target against the
    /// session's live catalog, binds to the tab's Copilot session, and writes an
    /// atomic single-outstanding request file the extension consumes over RPC.
    func setModel(
        sessionId: String,
        selection: RemoteModelSelection,
        operation: CLIOperationRequest? = nil,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        let clock = advancingClock(from: now)
        guard locateIndex(sessionId) != nil else { return .invalid }
        guard !selection.modelId.isEmpty,
              selection.modelId.utf8.count <= 200,
              (selection.reasoningEffort?.utf8.count ?? 0) <= 64,
              (selection.contextTier?.utf8.count ?? 0) <= 64 else {
            return .invalid
        }
        if let tier = selection.contextTier,
           tier != "default" && tier != "long_context" {
            return .invalid
        }

        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        return adapter.submit(
            sessionId: sessionId,
            kind: .setModel,
            operation: operation,
            fingerprintPayload: selection,
            handoffSuffix: "set-model-request.json",
            now: clock,
            validate: { snapshot in
                guard snapshot.workflow?.bounceRequested != true,
                      let target = snapshot.availableModels?
                    .first(where: { $0.id == selection.modelId }),
                      target.disabled != true else {
                    return false
                }
                if let effort = selection.reasoningEffort {
                    guard let supported = target.supportedReasoningEfforts,
                          supported.contains(effort) else {
                        return false
                    }
                }
                if selection.contextTier == "long_context",
                   target.longContextAvailable == false {
                    return false
                }
                return true
            },
            makeHandoff: { metadata in
                SetModelRequestFile(
                    schemaVersion: 1,
                    copilotSessionId: metadata.copilotSessionId,
                    operationId: metadata.operationId,
                    conversationEpoch: metadata.conversationEpoch,
                    kind: metadata.kind,
                    payloadFingerprint: metadata.payloadFingerprint,
                    modelId: selection.modelId,
                    reasoningEffort: selection.reasoningEffort,
                    contextTier: selection.contextTier
                )
            }
        )
    }

    func performSessionAction(
        sessionId: String,
        action: RemoteSessionAction,
        operation: CLIOperationRequest,
        now: Date = Date()
    ) -> RemoteUserInputResult {
        let clock = advancingClock(from: now)
        guard locateIndex(sessionId) != nil, action.isValid,
              let kind = CLISDKOperationKind(rawValue: action.kind.rawValue) else {
            return .invalid
        }
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        return adapter.submit(
            sessionId: sessionId,
            kind: kind,
            operation: operation,
            fingerprintPayload: action,
            handoffSuffix: "\(kind.rawValue).json",
            now: clock,
            validate: { snapshot in
                guard let workflow = snapshot.workflow,
                      workflow.supports(action.kind, at: clock()) else { return false }
                switch action.kind {
                case .send:
                    if let attachmentIds = action.attachmentIds {
                        let now = clock()
                        guard let epoch = snapshot.conversationEpoch,
                              let attachments = try? attachmentIds.map({ id in
                                  try self.attachmentStore.metadata(
                                      id: id,
                                      sessionId: sessionId,
                                      conversationEpoch: epoch,
                                      now: now
                                  )
                              }),
                              RemoteAttachmentContract.accepts(
                                  attachments,
                                  capabilities: workflow.capabilities,
                                  imageLimits: workflow.imageAttachments,
                                  at: now
                              ) else { return false }
                    }
                    return workflow.sendReady && !snapshot.hasPendingInput
                case .abort:
                    return true
                case .bounce:
                    guard let location = self.locateIndex(sessionId) else { return false }
                    let session = self.projects[location.p].sessions[location.s]
                    let foreground = self.runtimeForegroundActivity(for: session, now: clock())
                    return workflow.sendReady && !snapshot.hasPendingInput
                        && !session.hasBackgroundWork && self.remoteSessionHasLiveAgent(sessionId)
                        && self.projectedStatus(for: session, foreground: foreground, now: clock()) == .idle
                        && self.remotePromptFences[sessionId] == nil
                        && !snapshot.foregroundTurnActive && !snapshot.scheduledTurnActive
                        && snapshot.activeSubagents.isEmpty && snapshot.schedules.isEmpty
                        && snapshot.runtimeForegroundActivity(
                            expectedSessionId: snapshot.copilotSessionId,
                            now: clock(), minimumObservationMilliseconds: nil
                        ) == .idle
                case .setBudget:
                    return workflow.limitsKnown && workflow.budgetRequest == nil
                case .answerBudget:
                    return workflow.budgetRequest?.requestId == action.requestId
                }
            },
            makeHandoff: { metadata in
                SessionActionHandoff(
                    schemaVersion: 1,
                    copilotSessionId: metadata.copilotSessionId,
                    operationId: metadata.operationId,
                    conversationEpoch: metadata.conversationEpoch,
                    kind: metadata.kind,
                    payloadFingerprint: metadata.payloadFingerprint,
                    action: action
                )
            }
        )
    }

    private struct SessionActionHandoff: Encodable {
        let schemaVersion: Int
        let copilotSessionId: String
        let operationId: String?
        let conversationEpoch: String?
        let kind: String?
        let payloadFingerprint: String?
        let action: RemoteSessionAction
    }

    var attachmentStore: RemoteAttachmentStore {
        RemoteAttachmentStore(sessionsDirectory: agentActivityDirectory)
    }

    func sessionPromptComposer(sessionId: String) -> DesktopSessionPromptComposer {
        if let existing = sessionPromptComposers[sessionId] {
            return existing
        }
        let composer = DesktopSessionPromptComposer(
            sessionId: sessionId,
            attachmentStore: attachmentStore
        )
        if locateIndex(sessionId) != nil {
            sessionPromptComposers[sessionId] = composer
        }
        return composer
    }

    func sessionWorkflow(sessionId: String) -> RemoteSessionWorkflow? {
        guard let location = locateIndex(sessionId) else { return nil }
        return projects[location.p].sessions[location.s].agentActivity?.workflow
    }

    func sessionOperationProjection(sessionId: String) -> AgentOperationProjection {
        guard let location = locateIndex(sessionId) else { return .unavailable }
        return projects[location.p].sessions[location.s].agentActivity?
            .remoteOperationProjection() ?? .unavailable
    }

    func performLocalSessionAction(
        sessionId: String,
        action: RemoteSessionAction,
        expectedConversationEpoch: String? = nil
    ) async -> RemoteWorkflowActionResult {
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        guard let snapshot = adapter.loadFreshSnapshot(sessionId: sessionId, now: { Date() }),
              let epoch = snapshot.remoteOperationProjection().conversationEpoch else {
            return RemoteWorkflowActionResult(state: .rejected, message: "Native session controls are unavailable.")
        }
        if let expectedConversationEpoch, epoch != expectedConversationEpoch {
            return RemoteWorkflowActionResult(
                state: .rejected,
                message: "The conversation changed. Review your message before sending again."
            )
        }
        let operation = CLIOperationRequest(operationId: UUID().uuidString, conversationEpoch: epoch)
        guard performSessionAction(sessionId: sessionId, action: action, operation: operation) == .accepted else {
            return RemoteWorkflowActionResult(state: .rejected, message: "The session action was not accepted.")
        }
        for _ in 0..<40 {
            do { try await ContinuousClock().sleep(until: .now.advanced(by: .milliseconds(500))) }
            catch { break }
            guard let fresh = adapter.loadFreshSnapshot(sessionId: sessionId, now: { Date() }),
                  fresh.conversationEpoch == epoch else { break }
            if let receipt = fresh.remoteOperationProjection().receipts?.first(where: {
                $0.operationId == operation.operationId && $0.kind == action.kind.rawValue
            }), receipt.state.isTerminal {
                return RemoteWorkflowActionResult(
                    state: receipt.state,
                    message: receipt.state == .applied ? nil : receipt.state == .rejected
                        ? "Copilot did not apply this action."
                        : "Outcome unknown. Inspect the terminal before trying again.",
                    operationId: operation.operationId
                )
            }
        }
        return RemoteWorkflowActionResult(
            state: .indeterminate,
            message: "Couldn't confirm the outcome. Inspect the terminal before trying again.",
            operationId: operation.operationId
        )
    }

    nonisolated static func isValidElicitationContent(_ content: [String: RemoteJSONValue]) -> Bool {
        content.values.allSatisfy { value in
            switch value {
            case .bool, .string:
                return true
            case .number(let number):
                return number.isFinite
            case .array(let values):
                return values.allSatisfy {
                    if case .string = $0 { return true }
                    return false
                }
            case .null, .object:
                return false
            }
        }
    }

    nonisolated static func elicitationContent(
        _ content: [String: RemoteJSONValue],
        satisfies schema: RemoteJSONValue?,
        allowFreeformStringChoices: Bool
    ) -> Bool {
        guard let schema else { return true }
        guard case .object(let root) = schema else { return false }
        if let type = jsonString(root["type"]), type != "object" { return false }
        guard let propertiesValue = root["properties"],
              case .object(let properties) = propertiesValue else { return content.isEmpty }
        let required = jsonStringArray(root["required"]) ?? []
        guard required.allSatisfy({ content[$0] != nil }) else { return false }
        for (key, value) in content {
            guard let fieldSchema = properties[key],
                  elicitationValue(
                      value,
                      satisfies: fieldSchema,
                      allowFreeformStringChoice: allowFreeformStringChoices
                  ) else {
                return false
            }
        }
        return true
    }

    private nonisolated static func elicitationValue(
        _ value: RemoteJSONValue,
        satisfies schema: RemoteJSONValue,
        allowFreeformStringChoice: Bool = false
    ) -> Bool {
        guard case .object(let schema) = schema else { return true }
        let oneOfValues = jsonArray(schema["oneOf"])
        let enumValues = jsonArray(schema["enum"])
        let hasOneOfChoices = oneOfValues?.isEmpty == false
        let hasEnumChoices = enumValues?.isEmpty == false
        let hasFreeformChoiceSet: Bool
        if schema["anyOf"] == nil, hasOneOfChoices != hasEnumChoices {
            if let oneOfValues, hasOneOfChoices {
                hasFreeformChoiceSet = oneOfValues.allSatisfy { alternative in
                    guard case .object(let option) = alternative,
                          case .string = option["const"] else {
                        return false
                    }
                    return true
                }
            } else if let enumValues, hasEnumChoices {
                hasFreeformChoiceSet = enumValues.allSatisfy {
                    if case .string = $0 { return true }
                    return false
                }
            } else {
                hasFreeformChoiceSet = false
            }
        } else {
            hasFreeformChoiceSet = false
        }
        let isNonEmptyFreeformString: Bool
        if allowFreeformStringChoice,
           hasFreeformChoiceSet,
           jsonString(schema["type"]) == "string",
           case .string(let string) = value {
            isNonEmptyFreeformString = !string.isEmpty
        } else {
            isNonEmptyFreeformString = false
        }
        if !isNonEmptyFreeformString,
           let alternatives = oneOfValues ?? jsonArray(schema["anyOf"]) {
            guard alternatives.contains(where: { alternative in
                guard case .object(let option) = alternative,
                      let expected = option["const"] else { return false }
                return expected == value
            }) else { return false }
        }
        if let enumValues,
           !enumValues.contains(value),
           !isNonEmptyFreeformString {
            return false
        }
        guard let type = jsonString(schema["type"]) else { return true }
        switch type {
        case "string":
            guard case .string(let string) = value else { return false }
            if let minimum = jsonNumber(schema["minLength"]),
               Double(string.unicodeScalars.count) < minimum { return false }
            if let maximum = jsonNumber(schema["maxLength"]),
               Double(string.unicodeScalars.count) > maximum { return false }
            if let format = jsonString(schema["format"]),
               !stringMatchesFormat(string, format: format) { return false }
            return true
        case "number":
            guard case .number(let number) = value else { return false }
            return numberSatisfiesBounds(number, schema: schema)
        case "integer":
            guard case .number(let number) = value,
                  number.rounded() == number else { return false }
            return numberSatisfiesBounds(number, schema: schema)
        case "boolean":
            if case .bool = value { return true }
            if allowFreeformStringChoice, case .string(let text) = value {
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        case "array":
            guard case .array(let values) = value else { return false }
            if let minimum = jsonNumber(schema["minItems"]),
               Double(values.count) < minimum { return false }
            if let maximum = jsonNumber(schema["maxItems"]),
               Double(values.count) > maximum { return false }
            if let items = schema["items"] {
                return values.allSatisfy {
                    elicitationValue(
                        $0,
                        satisfies: items,
                        allowFreeformStringChoice: false
                    )
                }
            }
            return true
        default:
            return false
        }
    }

    private nonisolated static func numberSatisfiesBounds(
        _ number: Double,
        schema: [String: RemoteJSONValue]
    ) -> Bool {
        if let minimum = jsonNumber(schema["minimum"]), number < minimum { return false }
        if let maximum = jsonNumber(schema["maximum"]), number > maximum { return false }
        return true
    }

    private nonisolated static func stringMatchesFormat(_ string: String, format: String) -> Bool {
        switch format {
        case "email":
            return string.range(
                of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#,
                options: .regularExpression
            ) != nil
        case "uri":
            guard let components = URLComponents(string: string),
                  let scheme = components.scheme,
                  !scheme.isEmpty else { return false }
            return true
        case "date":
            let formatter = DateFormatter()
            formatter.calendar = Calendar(identifier: .iso8601)
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            return formatter.date(from: string) != nil
        case "date-time":
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: string) != nil
                || ISO8601DateFormatter().date(from: string) != nil
        default:
            return true
        }
    }

    private nonisolated static func jsonString(_ value: RemoteJSONValue?) -> String? {
        guard let value else { return nil }
        if case .string(let string) = value { return string }
        return nil
    }

    private nonisolated static func jsonNumber(_ value: RemoteJSONValue?) -> Double? {
        guard let value else { return nil }
        if case .number(let number) = value { return number }
        return nil
    }

    private nonisolated static func jsonArray(_ value: RemoteJSONValue?) -> [RemoteJSONValue]? {
        guard let value else { return nil }
        if case .array(let values) = value { return values }
        return nil
    }

    private nonisolated static func jsonStringArray(_ value: RemoteJSONValue?) -> [String]? {
        guard let value, case .array(let values) = value else { return nil }
        var strings: [String] = []
        for value in values {
            guard case .string(let string) = value else { return nil }
            strings.append(string)
        }
        return strings
    }

    func moveRemoteSession(
        sessionId: String,
        toProjectId targetProjectId: String
    ) -> RemoteSessionMoveResult {
        guard projectIndex(targetProjectId) != nil,
              let source = locateIndex(sessionId) else {
            return .missing
        }
        guard projects[source.p].id != targetProjectId else {
            return .unchanged
        }
        return moveSession(
            toProjectId: targetProjectId,
            draggedId: sessionId,
            selectInTarget: false
        ) ? .moved : .missing
    }

    // MARK: - Copilot Pull Requests

    /// Shows a session for Copilot Pull Requests. Strict, unlike `focus`: a
    /// session that ended is `gone`, one that moved to another project is a
    /// `conflict`. It never activates the app; the caller already yielded
    /// activation to it.
    func revealSession(projectId: String?, sessionId: String) -> ControlResponse {
        guard let loc = locateIndex(sessionId) else {
            return .failure("the session has ended", code: "gone")
        }
        let owner = projects[loc.p].id
        if let projectId, projectId != owner {
            return .failure("the session is in another project", code: "conflict")
        }
        show(projectId: owner, sessionId: sessionId)
        requestMainWindow?()
        focusActiveTerminal()
        return .success(sessionId, code: "revealed")
    }

    private func remotePullRequestsProvider() -> PullRequestsOverviewProvider {
        if let pullRequestsOverviewProvider { return pullRequestsOverviewProvider }
        let provider = PullRequestsOverviewProvider(
            cacheDirectory: Paths.pullRequestsStateDir.appendingPathComponent("host-cache"),
            readOnlyGoalsURL: Paths.pullRequestsStateDir.appendingPathComponent("goals.json"),
            workspace: { [weak self] in self?.workspaceSnapshot() }
        )
        pullRequestsOverviewProvider = provider
        return provider
    }

    var supportsPullRequests: Bool { true }

    func pullRequestsOverview(refresh: Bool) async -> RemotePullRequestsOverviewOutcome {
        guard !isTerminating else { return .unavailable("Copilot Projects is closing.") }
        guard !didFailToLoadWorkspaceState else { return .unavailable("The workspace could not be loaded.") }
        let overview = remotePullRequestsProvider().snapshot(refresh: refresh)
        guard let data = try? JSONEncoder().encode(overview),
              data.count <= RemotePullRequestsContract.maximumResponseBytes else {
            return .unavailable("The pull request overview exceeds the response limit.")
        }
        return .overview(overview)
    }

    func performPullRequestSession(_ request: RemotePullRequestSessionRequest) async -> RemotePullRequestSessionOutcome {
        performRemotePullRequestSession(request)
    }

    /// No suspension between fresh eligibility, association, append and launch:
    /// two independent client UUIDs cannot both start work for the same PR.
    func performRemotePullRequestSession(
        _ input: RemotePullRequestSessionRequest, now: Date = Date()
    ) -> RemotePullRequestSessionOutcome {
        guard let request = input.normalized() else { return .invalid("Invalid pull request session request.") }
        guard !isTerminating else { return .unavailable("Copilot Projects is closing.") }
        guard !didFailToLoadWorkspaceState else { return .persistenceUnavailable }
        let fingerprint = SessionCreationRecord.pullRequestFingerprint(request)
        let record: SessionCreationRecord?
        do {
            record = try sessionCreationLedger.record(for: request.requestId, now: now)
                ?? pendingPullRequestBindings[request.requestId]
        } catch {
            return .persistenceUnavailable
        }
        // Replay before current scope, merged PRs, expired historical search, or a
        // moved tab. The immutable requested project is part of the fingerprint.
        if let record {
            guard record.creationFingerprint == fingerprint else { return .conflict }
            return finishPullRequestSession(request, sessionId: record.sessionId,
                                            created: false, record: record, now: now)
        }
        let tabId = request.requestId.uuidString
        if let loc = locateIndex(tabId) {
            guard projects[loc.p].sessions[loc.s].creationFingerprint == fingerprint else { return .conflict }
            return finishPullRequestSession(request, sessionId: tabId, created: false, now: now)
        }
        let existing = request.copilotSessionId.flatMap { tabHoldingCopilotSession($0, now: now) }
        if let failure = remotePullRequestsProvider().validate(
            request, workspace: workspaceSnapshot(), existingSessionId: existing
        ) { return failure }
        if let existing {
            return finishPullRequestSession(request, sessionId: existing, created: false, now: now)
        }
        let result: ControlResponse
        if request.kind == "start" {
            guard let prompt = PullRequestsOverviewProvider.startingPrompt(for: request.pullRequestKeys),
                  SessionInputValidation.isValidPrompt(prompt) else {
                return .invalid("The pull request batch is too large for a starting prompt.")
            }
            result = startPullRequestsSession(
                requestId: request.requestId, projectId: request.projectId, prompt: prompt, selectOnMac: false,
                fingerprintOverride: fingerprint, pullRequestKeys: request.pullRequestKeys, now: now
            )
        } else {
            result = resumePullRequestsSession(
                requestId: request.requestId, projectId: request.projectId,
                copilotSessionId: request.copilotSessionId!, selectOnMac: false,
                fingerprintOverride: fingerprint, pullRequestKeys: request.pullRequestKeys, now: now
            )
        }
        if result.ok, let sessionId = result.text, !sessionId.isEmpty {
            return finishPullRequestSession(request, sessionId: sessionId, created: result.code == "created", now: now)
        }
        switch result.code {
        case "conflict": return .conflict
        case "gone": return .gone
        case "in-use": return .inUse
        case "unknown-project": return .unknownProject
        case "persistence-unavailable": return .persistenceUnavailable
        case "invalid": return .invalid("The session's working directory is no longer available.")
        case "bad-request": return .invalid("Invalid starting prompt.")
        default: return .unavailable("Copilot or the session backend is unavailable.")
        }
    }

    /// Every successful path repairs persisted associations. A secondary Resume
    /// binds the ledger, never overwrites the tab's original creation fingerprint.
    private func finishPullRequestSession(
        _ request: RemotePullRequestSessionRequest, sessionId: String, created: Bool,
        record: SessionCreationRecord? = nil, now: Date
    ) -> RemotePullRequestSessionOutcome {
        guard let loc = locateIndex(sessionId) else { return .gone }
        let keys = Set((projects[loc.p].sessions[loc.s].pullRequestKeys ?? [])
            .compactMap(RemotePullRequestsContract.canonicalKey)).union(request.pullRequestKeys).sorted()
        guard keys.count <= RemotePullRequestsContract.maximumKeys else {
            return .invalid("This session already has the maximum number of associated pull requests.")
        }
        let binding = record ?? SessionCreationRecord(
            requestId: request.requestId.uuidString, projectId: request.projectId, sessionId: sessionId,
            createdAt: now, creationFingerprint: SessionCreationRecord.pullRequestFingerprint(request)
        )
        pendingPullRequestBindings[request.requestId] = binding
        projects[loc.p].sessions[loc.s].pullRequestKeys = keys
        do {
            // For an existing tab, writing its binding first also makes a failed
            // workspace save repairable after restart without changing its intent.
            try sessionCreationLedger.remember(binding, now: now)
            try persistWorkspace()
            pendingPullRequestBindings[request.requestId] = nil
        } catch {
            return .persistenceUnavailable
        }
        let response = RemotePullRequestSessionResponse(
            requestId: request.requestId, projectId: projects[loc.p].id, sessionId: sessionId
        )
        return created ? .created(response) : .existing(response)
    }

    /// Starts a Copilot session for Copilot Pull Requests exactly as Start
    /// Session did inside the app: in the project's current folder, selected in
    /// its project. It shares the creation ledger, so a request id replayed even
    /// after a restart returns the same session (`existing`), `gone` once it
    /// ended, or `conflict` when the project or prompt differ.
    func startPullRequestsSession(
        requestId: UUID, projectId: String, prompt: String, selectOnMac: Bool = true,
        fingerprintOverride: String? = nil, pullRequestKeys: [String]? = nil, now: Date = Date()
    ) -> ControlResponse {
        guard SessionInputValidation.isValidPrompt(prompt) else {
            return .failure(CopilotSessionStartError.invalidPrompt.localizedDescription, code: "bad-request")
        }
        guard !isTerminating else {
            return .failure(CopilotSessionStartError.shuttingDown.localizedDescription, code: "unavailable")
        }
        let prompt = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let outcome = createRemoteSession(
            RemoteCreateSessionRequest(
                requestId: requestId, projectId: projectId, kind: .copilot, initialPrompt: prompt),
            isPlainCreate: false,
            kind: .copilot,
            title: "Copilot",
            initialPrompt: prompt,
            placement: selectOnMac ? .local : .project,
            fingerprintOverride: fingerprintOverride,
            pullRequestKeys: pullRequestKeys,
            now: now
        )
        switch outcome {
        case .unknownProject:
            return .failure(CopilotSessionStartError.projectUnavailable.localizedDescription, code: "unknown-project")
        case .invalid:
            return .failure("This project’s working directory no longer exists.", code: "invalid")
        case .persistenceUnavailable:
            return .failure("Copilot Projects couldn’t save the session. Try again; it won’t start twice.",
                            code: "persistence-unavailable")
        default:
            return Self.controlResponse(for: outcome)
        }
    }

    /// Starts a local adversarial review session for a pull request from Copilot
    /// Notifications or CLI control callers, linking the created tab to that PR
    /// and recording `requestId` in the creation ledger for idempotent retries.
    func startPullRequestReviewSession(
        requestId: UUID,
        projectId: String,
        pullRequestURL: String,
        hostId: String? = nil,
        selectOnMac: Bool = true,
        now: Date = Date()
    ) -> ControlResponse {
        guard let target = PullRequestReviewTarget.parse(pullRequestURL) else {
            return .failure(
                "Use an HTTPS github.com URL such as https://github.com/owner/repo/pull/123.",
                code: "bad-request")
        }
        guard !isTerminating else {
            return .failure(CopilotSessionStartError.shuttingDown.localizedDescription, code: "unavailable")
        }
        let canonicalKey = "\(target.owner.lowercased())/\(target.repository.lowercased())#\(target.number)"
        let outcome = createRemoteSession(
            RemoteCreateSessionRequest(
                requestId: requestId,
                projectId: projectId,
                pullRequestURL: target.url,
                hostId: hostId
            ),
            isPlainCreate: false,
            kind: .copilot,
            title: target.title,
            initialPrompt: pullRequestReviewPrompt(for: target),
            placement: selectOnMac ? .local : .project,
            pullRequestKeys: [canonicalKey],
            now: now
        )
        switch outcome {
        case .unknownProject:
            return .failure(CopilotSessionStartError.projectUnavailable.localizedDescription, code: "unknown-project")
        case .invalid:
            return .failure("This project’s working directory no longer exists.", code: "invalid")
        case .persistenceUnavailable:
            return .failure("Copilot Projects couldn’t save the session. Try again; it won’t start twice.",
                            code: "persistence-unavailable")
        default:
            return Self.controlResponse(for: outcome)
        }
    }

    private static func pullRequestsFailure(_ error: Error) -> ControlResponse {
        guard let error = error as? CopilotSessionStartError else {
            return .failure(error.localizedDescription, code: "unavailable")
        }
        let code: String
        switch error {
        case .projectUnavailable: code = "unknown-project"
        case .invalidPrompt: code = "bad-request"
        case .workingDirectoryUnavailable: code = "invalid"
        case .shuttingDown, .backendUnavailable, .copilotUnavailable, .remoteWrapperUnavailable, .terminalUnavailable:
            code = "unavailable"
        }
        return .failure(error.localizedDescription, code: code)
    }

    /// Opens an ended Copilot CLI session for Copilot Pull Requests in a new tab
    /// of `projectId`, in the folder it worked in, selected in its project. A tab
    /// that already has it, or is still bringing it back, is returned (`existing`).
    /// Like Start Session it shares the creation ledger, so a request id replayed
    /// even after a restart returns the same tab (`existing`), `gone` once it
    /// ended, or `conflict` for another project or session. `gone` when the CLI no
    /// longer has the session, `in-use` when a running CLI holds it, `invalid`
    /// when its folder is gone.
    func resumePullRequestsSession(
        requestId: UUID, projectId: String, copilotSessionId: String, selectOnMac: Bool = true,
        initialTitle: String = "Copilot",
        fingerprintOverride: String? = nil, pullRequestKeys: [String]? = nil,
        store: CopilotSessionStore = CopilotSessionStore(),
        now: Date = Date()
    ) -> ControlResponse {
        guard !isTerminating else {
            return .failure(CopilotSessionStartError.shuttingDown.localizedDescription, code: "unavailable")
        }
        let unsaved = ControlResponse.failure(
            "Copilot Projects couldn’t save the session. Try again; it won’t open twice.",
            code: "persistence-unavailable"
        )
        guard !didFailToLoadWorkspaceState else { return unsaved }
        let copilotId = copilotSessionId.lowercased()
        let fingerprint = fingerprintOverride
            ?? SessionCreationRecord.resumeFingerprint(projectId: projectId, copilotSessionId: copilotId)
        let tabId = requestId.uuidString
        let record: SessionCreationRecord?
        do {
            record = try sessionCreationLedger.record(for: requestId, now: now)
        } catch {
            NSLog("copilot-projects: could not read the session creation ledger for resume request \(tabId): "
                + error.localizedDescription)
            return unsaved
        }
        if let record {
            guard record.creationFingerprint == fingerprint, record.projectId == projectId else {
                return .failure("request id is bound to a different session", code: "conflict")
            }
            guard locateIndex(record.sessionId) != nil else {
                return .failure("request id already resumed a session that has since ended", code: "gone")
            }
            return .success(record.sessionId, code: "existing")
        }
        // Opened for this request before its record was saved.
        if let loc = locateIndex(tabId) {
            guard projects[loc.p].id == projectId,
                  projects[loc.p].sessions[loc.s].creationFingerprint == fingerprint else {
                return .failure("request id is bound to a different session", code: "conflict")
            }
            guard rememberPullRequestsResume(requestId, projectId: projectId, sessionId: tabId,
                                             fingerprint: fingerprint, now: now) else { return unsaved }
            return .success(tabId, code: "existing")
        }
        if let sessionId = tabHoldingCopilotSession(copilotId, now: now) {
            guard rememberPullRequestsResume(requestId, projectId: projectId, sessionId: sessionId,
                                             fingerprint: fingerprint, now: now) else { return unsaved }
            return .success(sessionId, code: "existing")
        }
        // A terminal left behind for this request has no record of what it runs.
        if FileManager.default.fileExists(atPath: Paths.dtachSocketPath(sessionId: tabId)) {
            return .failure("request id is bound to a different session", code: "conflict")
        }
        guard let copilotRecord = store.record(for: copilotId) else {
            return .failure("That Copilot session no longer exists.", code: "gone")
        }
        guard !store.isInUse(copilotId) else {
            return .failure("That Copilot session is open somewhere else.", code: "in-use")
        }
        let cwd = Paths.normalizedDirectory(copilotRecord.cwd ?? "")
        var isDirectory: ObjCBool = false
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure("The folder it worked in, \(cwd), no longer exists.", code: "invalid")
        }
        let executable: String
        do {
            executable = try copilotSessionExecutable(
                toProjectId: projectId,
                hostId: RemoteHostInfo.localId
            )
        } catch {
            return Self.pullRequestsFailure(error)
        }
        guard let pi = projectIndex(projectId) else {
            return .failure(CopilotSessionStartError.projectUnavailable.localizedDescription, code: "unknown-project")
        }
        let hostMarker = resumeMarkerDirectory.appendingPathComponent("\(tabId).remote-host")
        if unlink(hostMarker.path) != 0 && errno != ENOENT { return unsaved }
        let resolvedTitle = initialTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = Session(
            id: tabId,
            title: resolvedTitle.isEmpty ? "Copilot" : resolvedTitle,
            cwd: cwd,
            creationFingerprint: fingerprint,
            pullRequestKeys: pullRequestKeys
        )
        let previousSelection = projects[pi].selectedSessionId
        projects[pi].sessions.append(session)
        if selectOnMac { projects[pi].selectedSessionId = session.id }
        // No suspension between appending and creating the launch controller: a
        // view update must not lazily create a plain shell for this tab. The
        // marker isn't written here; Copilot writes it once it has resumed.
        launchSession(session.id, executable: executable, initialPrompt: nil, resumeCopilotSessionId: copilotId)
        if remoteSessionLauncher == nil, controllers[session.id]?.terminalView.process?.running != true {
            controllers[session.id] = nil
            projects[pi].sessions.removeAll { $0.id == session.id }
            projects[pi].selectedSessionId = previousSelection
            return .failure("The terminal could not be started.", code: "unavailable")
        }
        pullRequestsResumeLaunches[copilotId] = (session.id, now)
        refreshSelectedTranscriptController()
        // The tab stays if saving fails, so the retry finds it instead of opening another.
        guard rememberPullRequestsResume(requestId, projectId: projectId, sessionId: session.id,
                                         fingerprint: fingerprint, now: now) else { return unsaved }
        return .success(session.id, code: "created")
    }

    /// Saves the workspace, then which tab `requestId` resumed its session in.
    private func rememberPullRequestsResume(
        _ requestId: UUID, projectId: String, sessionId: String, fingerprint: String, now: Date
    ) -> Bool {
        do {
            try persistWorkspace()
            try sessionCreationLedger.remember(
                SessionCreationRecord(
                    requestId: requestId.uuidString, projectId: projectId, sessionId: sessionId,
                    createdAt: now, creationFingerprint: fingerprint
                ),
                now: now
            )
            return true
        } catch {
            NSLog("copilot-projects: could not save resume request \(requestId.uuidString); "
                + "retry with the same request id: " + error.localizedDescription)
            return false
        }
    }

    /// A tab that has Copilot session `copilotId`: its resume marker names it, or
    /// it is still bringing it back, without a marker until Copilot has resumed.
    /// Once that Copilot exits without resuming, the tab is a plain shell and no
    /// longer has it.
    private func tabHoldingCopilotSession(_ copilotId: String, now: Date) -> String? {
        let sessions = projects.flatMap(\.sessions).map(\.id)
        // Only a marker the tab's own Copilot wrote, as a relaunch requires before resuming it.
        if let marked = sessions.first(where: { sessionId in
            guard let marker = resumeMarkerValue(sessionId: sessionId, suffix: "copilot-session"),
                  marker.lowercased() == copilotId else { return false }
            return TranscriptController.transcriptOwnerAllowsRead(sessionId: sessionId, directory: resumeMarkerDirectory)
                && !TranscriptController.isCopilotSessionQuarantined(
                    sessionId: sessionId, copilotSessionId: marker, directory: resumeMarkerDirectory
                )
        }) {
            return marked
        }
        let resuming = copilotResumeSessions?(copilotId)
            ?? ProcessTree.sessionsResuming(copilotSessionId: copilotId, in: ProcessTree.snapshot())
        if let starting = sessions.first(where: resuming.contains) { return starting }
        if let launch = pullRequestsResumeLaunches[copilotId], locateIndex(launch.sessionId) != nil,
           now.timeIntervalSince(launch.launchedAt) < Self.pullRequestsResumeStartupGrace {
            return launch.sessionId
        }
        return nil
    }

    /// In-memory Copilot CLI session IDs owned or currently being resumed by live tabs.
    /// Does not perform filesystem or process-tree work.
    func inMemoryActiveCopilotSessionIds(now: Date = Date()) -> Set<String> {
        var ids = Set<String>()
        for project in projects {
            for session in project.sessions {
                if let activeId = session.agentActivity?.copilotSessionId, !activeId.isEmpty {
                    ids.insert(activeId.lowercased())
                }
            }
        }
        for (copilotId, launch) in pullRequestsResumeLaunches
            where locateIndex(launch.sessionId) != nil
                && now.timeIntervalSince(launch.launchedAt) < Self.pullRequestsResumeStartupGrace {
            ids.insert(copilotId.lowercased())
        }
        return ids
    }

    /// Reads and validates resume markers for `sessionIds` off the main actor.
    nonisolated static func validatedMarkerCopilotSessionIds(
        sessionIds: [String], directory: URL
    ) -> Set<String> {
        var ids = Set<String>()
        for sessionId in sessionIds {
            guard let raw = try? String(
                contentsOf: directory.appendingPathComponent("\(sessionId).copilot-session"),
                encoding: .utf8
            ) else { continue }
            let marker = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !marker.isEmpty else { continue }
            if TranscriptController.transcriptOwnerAllowsRead(sessionId: sessionId, directory: directory),
               !TranscriptController.isCopilotSessionQuarantined(
                   sessionId: sessionId, copilotSessionId: marker, directory: directory
               ) {
                ids.insert(marker.lowercased())
            }
        }
        return ids
    }

    /// Lowercased Copilot CLI session IDs owned or currently being resumed by live tabs.
    func activeAndResumingCopilotSessionIds(now: Date = Date()) -> Set<String> {
        let sessionIds = projects.flatMap { $0.sessions.map(\.id) }
        return inMemoryActiveCopilotSessionIds(now: now)
            .union(Self.validatedMarkerCopilotSessionIds(sessionIds: sessionIds, directory: resumeMarkerDirectory))
    }

    enum ResumeFinderOutcome: Equatable {
        case opened(projectId: String, sessionId: String)
        case permanentlyUnavailable(String)
        case temporarilyUnavailable(String)
    }

    /// Reopens an ended Copilot session chosen in Find Session (`⌘K`).
    func resumeFromSessionFinder(
        copilotSessionId: String,
        preferredProjectId: String,
        cwd: String,
        repository: String? = nil,
        title: String,
        store: CopilotSessionStore = CopilotSessionStore(),
        now: Date = Date()
    ) -> ResumeFinderOutcome {
        let projectId: String?
        if projects.contains(where: { $0.id == preferredProjectId }) {
            projectId = preferredProjectId
        } else {
            projectId = SessionFinderSearch.targetProject(
                forCwd: cwd,
                repository: repository,
                projects: sessionFinderProjectTargets,
                selectedProjectId: selectedProjectId
            )?.id
        }
        guard let projectId else {
            return .temporarilyUnavailable(CopilotSessionStartError.projectUnavailable.localizedDescription)
        }
        let requestId = UUID()
        let response = resumePullRequestsSession(
            requestId: requestId,
            projectId: projectId,
            copilotSessionId: copilotSessionId,
            selectOnMac: true,
            initialTitle: title,
            store: store,
            now: now
        )
        let candidateSessionId = response.text ?? requestId.uuidString
        if let loc = locateIndex(candidateSessionId) {
            return .opened(projectId: projects[loc.p].id, sessionId: candidateSessionId)
        }
        let message = response.error ?? "That Copilot session could not be resumed."
        switch response.code {
        case "gone", "in-use", "invalid":
            return .permanentlyUnavailable(message)
        default:
            return .temporarilyUnavailable(message)
        }
    }

    /// Resumes an ended Copilot CLI session selected in remote session search (Web / iOS)
    /// without changing the Mac's selected project or tab.
    func resumeRemoteSearchSession(
        _ input: RemoteResumeSearchSessionRequest,
        store: CopilotSessionStore = CopilotSessionStore(),
        now: Date = Date()
    ) -> RemoteResumeSearchSessionOutcome {
        guard let request = input.normalized() else {
            return .invalid("Invalid session resume request.")
        }
        guard !isTerminating else {
            return .unavailable(CopilotSessionStartError.shuttingDown.localizedDescription)
        }
        guard !didFailToLoadWorkspaceState else {
            return .persistenceUnavailable
        }
        let fingerprint = SessionCreationRecord.resumeFingerprint(
            projectId: request.projectId,
            copilotSessionId: request.copilotSessionId
        )
        do {
            if let existingRecord = try sessionCreationLedger.record(for: request.requestId, now: now) {
                guard existingRecord.creationFingerprint == fingerprint else {
                    return .conflict
                }
                guard let loc = locateIndex(existingRecord.sessionId) else {
                    return .gone("That resumed session has since ended.")
                }
                return .existing(RemoteResumeSearchSessionResponse(
                    requestId: request.requestId,
                    projectId: projects[loc.p].id,
                    sessionId: existingRecord.sessionId
                ))
            }
        } catch {
            return .persistenceUnavailable
        }
        let tabId = request.requestId.uuidString
        if let loc = locateIndex(tabId) {
            guard projects[loc.p].sessions[loc.s].creationFingerprint == fingerprint else {
                return .conflict
            }
            guard rememberPullRequestsResume(
                request.requestId,
                projectId: projects[loc.p].id,
                sessionId: tabId,
                fingerprint: fingerprint,
                now: now
            ) else {
                return .persistenceUnavailable
            }
            return .existing(RemoteResumeSearchSessionResponse(
                requestId: request.requestId,
                projectId: projects[loc.p].id,
                sessionId: tabId
            ))
        }

        let record = store.record(for: request.copilotSessionId)
        let projectId: String
        if projects.contains(where: { $0.id == request.projectId }) {
            projectId = request.projectId
        } else if let cwd = record?.cwd,
                  let fallback = SessionFinderSearch.targetProject(
                      forCwd: cwd,
                      projects: sessionFinderProjectTargets,
                      selectedProjectId: selectedProjectId,
                      defaultStartupDir: remoteReposDirectory() ?? Paths.defaultStartupDir
                  )?.id {
            projectId = fallback
        } else {
            return .unknownProject
        }
        let resolvedTitle = request.title
            ?? RemoteSessionSearchContract.sanitizedTitle(record?.displayName)
            ?? "Copilot"
        let result = resumePullRequestsSession(
            requestId: request.requestId,
            projectId: projectId,
            copilotSessionId: request.copilotSessionId,
            selectOnMac: false,
            initialTitle: resolvedTitle,
            fingerprintOverride: fingerprint,
            store: store,
            now: now
        )
        if result.ok, let sessionId = result.text, let loc = locateIndex(sessionId) {
            let response = RemoteResumeSearchSessionResponse(
                requestId: request.requestId,
                projectId: projects[loc.p].id,
                sessionId: sessionId
            )
            return result.code == "created" ? .created(response) : .existing(response)
        }
        let message = result.error ?? "That Copilot session could not be resumed."
        switch result.code {
        case "conflict":
            return .conflict
        case "gone":
            return .gone(message)
        case "in-use":
            return .inUse(message)
        case "unknown-project":
            return .unknownProject
        case "persistence-unavailable":
            return .persistenceUnavailable
        case "invalid", "bad-request":
            return .invalid(message)
        default:
            return .unavailable(message)
        }
    }

    /// Sends or queues a prompt into an existing live session for Copilot Pull Requests.
    /// Replaying the same `requestId` for the same session and prompt resolves its prior
    /// terminal or native outcome without delivering the prompt twice.
    func sendPullRequestsSessionPrompt(
        requestId: UUID,
        projectId: String?,
        sessionId: String,
        prompt: String,
        now: Date = Date()
    ) -> ControlResponse {
        let clock = advancingClock(from: now)
        guard SessionInputValidation.isValidPrompt(prompt) else {
            return .failure(CopilotSessionStartError.invalidPrompt.localizedDescription, code: "bad-request")
        }
        guard !isTerminating else {
            return .failure(CopilotSessionStartError.shuttingDown.localizedDescription, code: "unavailable")
        }
        let normalizedPrompt = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let action = RemoteSessionAction(kind: .send, prompt: normalizedPrompt, mode: .enqueue)
        guard let payloadFingerprint = CLIOperationAdapter.payloadFingerprint(
            kind: .sessionSend,
            payload: action
        ) else {
            return .failure("Could not send the prompt to that session.", code: "invalid")
        }
        let adapter = CLIOperationAdapter(
            activityDirectory: agentActivityDirectory,
            resumeMarkerDirectory: resumeMarkerDirectory
        )
        let previous: SentPullRequestsPrompt?
        if let cached = sentPullRequestsPrompts[requestId] {
            previous = cached
        } else {
            do {
                if let persisted = try sessionCreationLedger.promptRecord(for: requestId, now: clock()) {
                    let route: PullRequestsPromptRoute
                    switch persisted.route {
                    case .terminal:
                        route = .terminal
                    case .native:
                        guard let epoch = persisted.conversationEpoch, !epoch.isEmpty else {
                            return .failure(
                                "Could not confirm whether Copilot received the prompt. Inspect the terminal before trying again.",
                                code: "indeterminate"
                            )
                        }
                        route = .native(conversationEpoch: epoch)
                    }
                    let restored = SentPullRequestsPrompt(
                        sessionId: persisted.sessionId,
                        payloadFingerprint: persisted.payloadFingerprint,
                        route: route,
                        state: persisted.state,
                        createdAt: persisted.createdAt
                    )
                    sentPullRequestsPrompts[requestId] = restored
                    previous = restored
                } else {
                    previous = nil
                }
            } catch {
                return .failure(
                    "Could not confirm whether Copilot received the prompt. Inspect the terminal before trying again.",
                    code: "indeterminate"
                )
            }
        }
        if let previous {
            guard previous.sessionId == sessionId,
                  previous.payloadFingerprint == payloadFingerprint else {
                return .failure("request id is bound to a different session or prompt", code: "conflict")
            }
            guard let loc = locateIndex(sessionId) else {
                return .failure("The session has ended.", code: "gone")
            }
            if let projectId, projects[loc.p].id != projectId {
                return .failure("The session moved to another project.", code: "conflict")
            }
            switch previous.route {
            case .terminal:
                switch previous.state {
                case .delivered:
                    return .success(sessionId, code: "existing")
                case .pending, .queued:
                    return .failure(
                        "Could not confirm whether Copilot received the prompt. Inspect the terminal before trying again.",
                        code: "indeterminate"
                    )
                case .rejected:
                    return .failure("Copilot did not accept the prompt.", code: "rejected")
                }
            case .native(let epoch):
                switch previous.state {
                case .delivered:
                    return .success(sessionId, code: "applied")
                case .rejected:
                    return .failure("Copilot did not accept the prompt.", code: "rejected")
                case .pending, .queued:
                    return resolveNativePullRequestsPrompt(
                        sessionId: sessionId,
                        requestId: requestId,
                        conversationEpoch: epoch,
                        payloadFingerprint: payloadFingerprint,
                        createdAt: previous.createdAt,
                        adapter: adapter,
                        clock: clock
                    )
                }
            }
        }
        guard let loc = locateIndex(sessionId) else {
            return .failure("The session has ended.", code: "gone")
        }
        if let projectId, projects[loc.p].id != projectId {
            return .failure("The session moved to another project.", code: "conflict")
        }

        let freshSnapshot = adapter.loadFreshSnapshot(sessionId: sessionId, now: clock)
        if let snapshot = freshSnapshot,
           let epoch = snapshot.remoteOperationProjection(at: clock()).conversationEpoch {
            let operation = CLIOperationRequest(operationId: requestId.uuidString, conversationEpoch: epoch)
            let existingOutcome = adapter.submittedOperationOutcome(
                sessionId: sessionId,
                kind: .sessionSend,
                operation: operation,
                payloadFingerprint: payloadFingerprint,
                handoffSuffix: "\(CLISDKOperationKind.sessionSend.rawValue).json",
                now: clock
            )
            if existingOutcome != .notFound {
                return recordAndRespondToNativePullRequestsPrompt(
                    outcome: existingOutcome,
                    requestId: requestId,
                    sessionId: sessionId,
                    payloadFingerprint: payloadFingerprint,
                    conversationEpoch: epoch,
                    createdAt: clock()
                )
            }
        }

        let session = projects[loc.p].sessions[loc.s]
        if freshSnapshot?.workflow?.bounceRequested == true
            || session.agentActivity?.workflow?.bounceRequested == true {
            return .failure("The session is restarting. Check the terminal before sending more work.", code: "busy")
        }
        if session.displayStatus == .waiting || session.hasPendingInput {
            return .failure("The session is waiting for your input in the terminal.", code: "busy")
        }

        // Authoritative fresh tracker snapshot: refuse if input is pending on disk even before
        // the asynchronous activity watcher updates the in-memory session model.
        if freshSnapshot?.hasPendingInput == true {
            return .failure("The session is waiting for your input in the terminal.", code: "busy")
        }

        // Prefer native SDK queueing when the session has a fresh tracker workflow snapshot.
        if let snapshot = freshSnapshot,
           let epoch = snapshot.remoteOperationProjection(at: clock()).conversationEpoch,
           let workflow = snapshot.workflow,
           workflow.supports(.send, at: clock()) {
            guard workflow.sendReady else {
                return .failure("The session is busy or waiting for input in the terminal.", code: "busy")
            }
            let intentAt = clock()
            guard rememberSentPullRequestsPrompt(
                requestId: requestId,
                sessionId: sessionId,
                payloadFingerprint: payloadFingerprint,
                route: .native(conversationEpoch: epoch),
                state: .pending,
                now: intentAt
            ) else {
                return .failure(
                    "Copilot Projects couldn’t save the prompt request. Try again; it won’t send twice.",
                    code: "indeterminate"
                )
            }
            let operation = CLIOperationRequest(operationId: requestId.uuidString, conversationEpoch: epoch)
            switch performSessionAction(sessionId: sessionId, action: action, operation: operation, now: clock()) {
            case .accepted:
                _ = rememberSentPullRequestsPrompt(
                    requestId: requestId,
                    sessionId: sessionId,
                    payloadFingerprint: payloadFingerprint,
                    route: .native(conversationEpoch: epoch),
                    state: .queued,
                    now: intentAt
                )
                return resolveNativePullRequestsPrompt(
                    sessionId: sessionId,
                    requestId: requestId,
                    conversationEpoch: epoch,
                    payloadFingerprint: payloadFingerprint,
                    createdAt: intentAt,
                    adapter: adapter,
                    clock: clock
                )
            case .conflict:
                forgetPendingPullRequestsPrompt(requestId: requestId, now: clock())
                return .failure("Another session action is already awaiting Copilot.", code: "busy")
            case .invalid:
                forgetPendingPullRequestsPrompt(requestId: requestId, now: clock())
                if let latest = adapter.loadFreshSnapshot(sessionId: sessionId, now: clock),
                   latest.hasPendingInput || latest.workflow?.sendReady == false {
                    return .failure(
                        latest.hasPendingInput
                            ? "The session is waiting for your input in the terminal."
                            : "The session is busy or waiting for input in the terminal.",
                        code: "busy"
                    )
                }
                return .failure("Could not send the prompt to that session.", code: "invalid")
            }
        }

        let intentAt = clock()
        guard rememberSentPullRequestsPrompt(
            requestId: requestId,
            sessionId: sessionId,
            payloadFingerprint: payloadFingerprint,
            route: .terminal,
            state: .pending,
            now: intentAt
        ) else {
            return .failure(
                "Copilot Projects couldn’t save the prompt request. Try again; it won’t send twice.",
                code: "indeterminate"
            )
        }
        switch sendRemotePrompt(sessionId: sessionId, value: normalizedPrompt) {
        case .sent:
            _ = rememberSentPullRequestsPrompt(
                requestId: requestId,
                sessionId: sessionId,
                payloadFingerprint: payloadFingerprint,
                route: .terminal,
                state: .delivered,
                now: intentAt
            )
            return .success(sessionId, code: "sent")
        case .busy:
            forgetPendingPullRequestsPrompt(requestId: requestId, now: clock())
            return .failure("The session is busy or waiting for input in the terminal.", code: "busy")
        case .noLiveCopilot:
            forgetPendingPullRequestsPrompt(requestId: requestId, now: clock())
            return .failure("Copilot isn’t running in that session.", code: "no-copilot")
        case .invalid, .forbidden:
            forgetPendingPullRequestsPrompt(requestId: requestId, now: clock())
            return .failure("Could not send the prompt to that session.", code: "invalid")
        }
    }

    private func resolveNativePullRequestsPrompt(
        sessionId: String,
        requestId: UUID,
        conversationEpoch: String,
        payloadFingerprint: String,
        createdAt: Date,
        adapter: CLIOperationAdapter,
        clock: () -> Date
    ) -> ControlResponse {
        let operation = CLIOperationRequest(
            operationId: requestId.uuidString,
            conversationEpoch: conversationEpoch
        )
        let outcome = adapter.submittedOperationOutcome(
            sessionId: sessionId,
            kind: .sessionSend,
            operation: operation,
            payloadFingerprint: payloadFingerprint,
            handoffSuffix: "\(CLISDKOperationKind.sessionSend.rawValue).json",
            now: clock
        )
        return recordAndRespondToNativePullRequestsPrompt(
            outcome: outcome,
            requestId: requestId,
            sessionId: sessionId,
            payloadFingerprint: payloadFingerprint,
            conversationEpoch: conversationEpoch,
            createdAt: createdAt
        )
    }

    private func recordAndRespondToNativePullRequestsPrompt(
        outcome: CLISubmittedOperationOutcome,
        requestId: UUID,
        sessionId: String,
        payloadFingerprint: String,
        conversationEpoch: String,
        createdAt: Date
    ) -> ControlResponse {
        switch outcome {
        case .pendingHandoff, .accepted:
            _ = rememberSentPullRequestsPrompt(
                requestId: requestId,
                sessionId: sessionId,
                payloadFingerprint: payloadFingerprint,
                route: .native(conversationEpoch: conversationEpoch),
                state: .queued,
                now: createdAt
            )
            return .success(sessionId, code: "queued")
        case .applied:
            _ = rememberSentPullRequestsPrompt(
                requestId: requestId,
                sessionId: sessionId,
                payloadFingerprint: payloadFingerprint,
                route: .native(conversationEpoch: conversationEpoch),
                state: .delivered,
                now: createdAt
            )
            return .success(sessionId, code: "applied")
        case .rejected:
            _ = rememberSentPullRequestsPrompt(
                requestId: requestId,
                sessionId: sessionId,
                payloadFingerprint: payloadFingerprint,
                route: .native(conversationEpoch: conversationEpoch),
                state: .rejected,
                now: createdAt
            )
            return .failure("Copilot did not accept the prompt.", code: "rejected")
        case .indeterminate, .notFound:
            return .failure(
                "Could not confirm whether Copilot received the prompt. Inspect the terminal before trying again.",
                code: "indeterminate"
            )
        case .conflict:
            return .failure("request id is bound to a different session or prompt", code: "conflict")
        }
    }

    @discardableResult
    private func rememberSentPullRequestsPrompt(
        requestId: UUID,
        sessionId: String,
        payloadFingerprint: String,
        route: PullRequestsPromptRoute,
        state: PullRequestsPromptRecord.DeliveryState,
        now: Date
    ) -> Bool {
        let recordRoute: PullRequestsPromptRecord.Route
        let conversationEpoch: String?
        switch route {
        case .terminal:
            recordRoute = .terminal
            conversationEpoch = nil
        case .native(let epoch):
            recordRoute = .native
            conversationEpoch = epoch
        }
        let persisted = PullRequestsPromptRecord(
            requestId: requestId.uuidString,
            sessionId: sessionId,
            payloadFingerprint: payloadFingerprint,
            route: recordRoute,
            conversationEpoch: conversationEpoch,
            state: state,
            createdAt: now
        )
        let entry = SentPullRequestsPrompt(
            sessionId: sessionId,
            payloadFingerprint: payloadFingerprint,
            route: route,
            state: state,
            createdAt: now
        )
        if state != .pending {
            sentPullRequestsPrompts[requestId] = entry
        }
        do {
            try sessionCreationLedger.rememberPrompt(persisted, now: now)
            sentPullRequestsPrompts[requestId] = entry
            return true
        } catch {
            return state != .pending
        }
    }

    private func forgetPendingPullRequestsPrompt(requestId: UUID, now: Date) {
        sentPullRequestsPrompts[requestId] = nil
        try? sessionCreationLedger.removePrompt(for: requestId, now: now)
    }

    /// Every project and live session with the state the workspace shows, for `list-sessions`.
    func workspaceSnapshot() -> WorkspaceSnapshot {
        Self.recordingCopilotSessions(
            in: workspaceSnapshotWithoutCopilotSessions(), markerDirectory: resumeMarkerDirectory
        )
    }

    func workspaceSnapshotWithoutCopilotSessions() -> WorkspaceSnapshot {
        WorkspaceSnapshot(
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            selectedProjectId: selectedProjectId,
            projects: projects.map { project in
                WorkspaceSnapshot.Project(id: project.id, name: project.name, sessions: project.sessions.map {
                    WorkspaceSnapshot.Session(
                        id: $0.id, title: $0.title, status: $0.displayStatus, finishedUnseen: $0.finishedUnseen,
                        hasPendingInput: $0.hasPendingInput, pullRequestKeys: $0.pullRequestKeys
                    )
                })
            }
        )
    }

    /// Fills in each session's Copilot CLI session from its resume marker.
    nonisolated static func recordingCopilotSessions(
        in snapshot: WorkspaceSnapshot, markerDirectory: URL
    ) -> WorkspaceSnapshot {
        var snapshot = snapshot
        for p in snapshot.projects.indices {
            for s in snapshot.projects[p].sessions.indices {
                let id = snapshot.projects[p].sessions[s].id
                let marker = (try? String(
                    contentsOf: markerDirectory.appendingPathComponent("\(id).copilot-session"), encoding: .utf8
                ))?.trimmingCharacters(in: .whitespacesAndNewlines)
                snapshot.projects[p].sessions[s].copilotSessionId = marker?.isEmpty == false ? marker : nil
            }
        }
        return snapshot
    }

    nonisolated static func listSessionsResponse(_ snapshot: WorkspaceSnapshot) -> ControlResponse {
        guard let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) else {
            return .failure("could not encode the workspace")
        }
        return .success(text)
    }
}
