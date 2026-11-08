import Foundation
import Combine
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

@MainActor
final class TranscriptController: ObservableObject {
    nonisolated private static let quarantineLock = NSLock()

    private struct TranscriptOwner: Decodable {
        let appSessionId: String?
        let copilotSessionId: String?
        let pid: pid_t
        let parentPid: pid_t?
        let bootTime: String?
    }

    private struct TranscriptQuarantine: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let foreignCopilotSessionIds: Set<String>
    }

    private struct LoadSignature: Equatable, Sendable {
        let transcript: FileSignature
        let owner: FileSignature?
        let quarantine: FileSignature?
        let live: FileSignature?

        /// Whether a read under `other` saw the same transcript provenance.
        /// The live file only adds the turn in progress to the sealed file it
        /// extends (`TranscriptFiles` checks that), so it never changes whose
        /// transcript a read saw, and streaming does not make reads stale.
        func hasSameProvenance(as other: LoadSignature?) -> Bool {
            guard let other else { return false }
            return transcript == other.transcript
                && owner == other.owner
                && quarantine == other.quarantine
        }
    }

    private struct LoadResult: Sendable {
        let signature: LoadSignature?
        let snapshot: TranscriptSnapshot?
    }

    @Published private(set) var snapshot: TranscriptSnapshot?
    @Published private(set) var promptAttachments = TranscriptPromptAttachments()

    let sessionId: String

    private var directorySource: DispatchSourceFileSystemObject?
    private var fallbackTimer: Timer?
    private var signature: LoadSignature?
    private var reloadGeneration = 0
    private var started = false
    private let copilotHome: String?
    private let snapshotLoadObserver: (() -> Void)?

    init(
        sessionId: String,
        copilotHome: String? = nil,
        snapshotLoadObserver: (() -> Void)? = nil
    ) {
        self.sessionId = sessionId
        self.copilotHome = copilotHome
        self.snapshotLoadObserver = snapshotLoadObserver
    }

    deinit {
        directorySource?.cancel()
        fallbackTimer?.invalidate()
    }

    func start() {
        guard !started else { return }
        started = true
        watchSessionsDirectory()
        reload()
    }

    private func watchSessionsDirectory() {
        Paths.ensureStateDir()
        let descriptor = open(Paths.sessionsDir.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename, .delete],
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.reload(after: 0.03) }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            directorySource = source
        }

        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pollTranscriptIfNeeded() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    func pollTranscriptIfNeeded() {
        let sampledGeneration = reloadGeneration
        let previousSignature = signature
        let previousAttachments = promptAttachments
        let currentSessionId = sessionId
        let path = Paths.transcriptSnapshotPath(sessionId: currentSessionId)
        Task.detached { [weak self] in
            let currentSignature = Self.loadSignature(
                sessionId: currentSessionId,
                transcriptPath: path
            )
            guard currentSignature != previousSignature || previousAttachments.hasWatchedFileChanges() else {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      self.reloadGeneration == sampledGeneration,
                      self.signature == previousSignature else { return }
                self.reload()
            }
        }
    }

    func reload(after delay: TimeInterval = 0) {
        reloadGeneration += 1
        let generation = reloadGeneration
        let previousSignature = signature
        let currentSessionId = sessionId
        let currentCopilotHome = copilotHome
        let path = Paths.transcriptSnapshotPath(sessionId: currentSessionId)
        Task.detached { [weak self] in
            if delay > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
            }
            let state = await MainActor.run { [weak self] () -> (isCurrent: Bool, snapshot: TranscriptSnapshot?, attachments: TranscriptPromptAttachments) in
                guard let self, generation == reloadGeneration else {
                    return (false, nil, TranscriptPromptAttachments())
                }
                snapshotLoadObserver?()
                return (true, snapshot, promptAttachments)
            }
            guard state.isCurrent else { return }
            let result = Self.load(
                sessionId: currentSessionId,
                path: path,
                previousSignature: previousSignature
            )
            if result == nil, !state.attachments.hasWatchedFileChanges() {
                return
            }
            let targetSnapshot = result?.snapshot ?? (result == nil ? state.snapshot : nil)
            if let result {
                let isCurrent = await MainActor.run { [weak self] () -> Bool in
                    guard let self, generation == reloadGeneration else { return false }
                    snapshot = result.snapshot
                    if result.snapshot == nil {
                        signature = result.signature
                        promptAttachments = TranscriptPromptAttachments()
                    } else if result.snapshot?.copilotSessionId != promptAttachments.copilotSessionId {
                        promptAttachments = TranscriptPromptAttachments()
                    }
                    return result.snapshot != nil
                }
                guard isCurrent else { return }
            }
            guard let targetSnapshot else { return }
            let resolvedAttachments = TranscriptPromptAttachments.load(
                sessionId: currentSessionId,
                snapshot: targetSnapshot,
                previous: state.attachments,
                copilotHome: currentCopilotHome
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                if generation == reloadGeneration, let result {
                    signature = result.signature
                    snapshot = result.snapshot
                }
                if (generation == reloadGeneration || resolvedAttachments.scannedEventsBytes > promptAttachments.scannedEventsBytes),
                   snapshot?.copilotSessionId == resolvedAttachments.copilotSessionId,
                   promptAttachments != resolvedAttachments {
                    promptAttachments = resolvedAttachments
                }
            }
        }
    }

    nonisolated private static func load(
        sessionId: String,
        path: String,
        previousSignature: LoadSignature?
    ) -> LoadResult? {
        guard let signature = loadSignature(
            sessionId: sessionId,
            transcriptPath: path
        ) else {
            guard previousSignature != nil else { return nil }
            return LoadResult(signature: nil, snapshot: nil)
        }
        guard signature != previousSignature else { return nil }
        guard transcriptOwnerAllowsRead(sessionId: sessionId) else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        // The live file first: the tracker replaces the sealed file before the
        // live one, so a live file read first is never ahead of the sealed file
        // read after it, and `TranscriptFiles` decides whether it extends it.
        let liveData = try? Data(
            contentsOf: URL(fileURLWithPath: Paths.transcriptLivePath(sessionId: sessionId))
        )
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        guard let snapshot = TranscriptFiles.snapshot(
            sealed: data,
            live: liveData,
            decoder: transcriptDecoder()
        ) else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        guard transcriptOwnerAllowsSnapshot(
            sessionId: sessionId,
            copilotSessionId: snapshot.copilotSessionId,
            expectedSignature: signature
        ) else {
            return LoadResult(signature: signature, snapshot: nil)
        }
        guard transcriptQuarantineAllowsRead(
            sessionId: sessionId,
            snapshot: snapshot,
            expectedSignature: signature
        ) else {
            let current = loadSignature(sessionId: sessionId, transcriptPath: path)
            return LoadResult(
                signature: current == signature ? signature : nil,
                snapshot: nil
            )
        }
        return LoadResult(
            signature: signature,
            snapshot: snapshot
        )
    }

    nonisolated static func remoteRevision(sessionId: String) -> RemoteTranscriptRevision {
        return RemoteTranscriptRevision(
            sessionId: sessionId,
            generation: [
                fileGeneration(Paths.transcriptSnapshotPath(sessionId: sessionId)),
                fileGeneration(Paths.transcriptOwnerPath(sessionId: sessionId)),
                fileGeneration(Paths.transcriptQuarantinePath(sessionId: sessionId)),
                fileGeneration(Paths.transcriptLivePath(sessionId: sessionId)),
            ].joined(separator: "|")
        )
    }

    /// How many times a remote read rereads a transcript that keeps changing
    /// underneath it before giving up.
    nonisolated static let maximumRemoteSnapshotReadAttempts = 3

    /// The transcript as remote clients see it, or an empty snapshot (no
    /// conversation id) when there is none to show; `nil` only when the read
    /// could not settle. Clients treat the empty response as authoritative and
    /// clear what they had, so a read that came back empty only because the
    /// files moved underneath it (the tracker rewrote or rotated the transcript
    /// mid-read) is retried, up to `maximumRemoteSnapshotReadAttempts` reads in
    /// all. An empty result whose files did not change is final. When every
    /// read came back empty and the files changed after the last one too, the
    /// answer is unknown rather than empty, so this returns `nil` and the
    /// `/transcript` endpoint fails transiently instead.
    ///
    /// `duringRead` runs inside each attempt, after the transcript bytes are
    /// read and before they are validated, with the 1-based attempt number;
    /// `betweenFiles` runs after the live file is read and before the sealed
    /// one. Tests use them to land a rewrite mid-read. Both are `nil` in
    /// production.
    nonisolated static func loadRemoteSnapshotIfSettled(
        sessionId: String,
        duringRead: ((_ attempt: Int) -> Void)? = nil,
        betweenFiles: ((_ attempt: Int) -> Void)? = nil
    ) -> TranscriptSnapshot? {
        let path = Paths.transcriptSnapshotPath(sessionId: sessionId)
        for attempt in 1...maximumRemoteSnapshotReadAttempts {
            let signature = loadSignature(sessionId: sessionId, transcriptPath: path)
            let snapshot = readRemoteSnapshot(
                sessionId: sessionId,
                path: path,
                signature: signature,
                duringRead: duringRead.map { hook in { hook(attempt) } },
                betweenFiles: betweenFiles.map { hook in { hook(attempt) } }
            )
            if let snapshot, !snapshot.copilotSessionId.isEmpty {
                return snapshot
            }
            guard loadSignature(sessionId: sessionId, transcriptPath: path) != signature else {
                return snapshot ?? emptyRemoteSnapshot()
            }
        }
        return nil
    }

    /// `loadRemoteSnapshotIfSettled`, with a read that never settled reported
    /// as the empty snapshot, for local readers (notifications, the session
    /// finder, search) that have no transient failure to report.
    nonisolated static func loadRemoteSnapshot(
        sessionId: String,
        duringRead: ((_ attempt: Int) -> Void)? = nil
    ) -> TranscriptSnapshot {
        loadRemoteSnapshotIfSettled(sessionId: sessionId, duringRead: duringRead)
            ?? emptyRemoteSnapshot()
    }

    /// One read of the transcript against the signature sampled just before
    /// it, or `nil` when there is nothing a remote client may see.
    nonisolated private static func readRemoteSnapshot(
        sessionId: String,
        path: String,
        signature: LoadSignature?,
        duringRead: (() -> Void)?,
        betweenFiles: (() -> Void)?
    ) -> TranscriptSnapshot? {
        guard let signature else { return nil }
        guard transcriptOwnerAllowsRead(sessionId: sessionId) else {
            return nil
        }
        // The live file first, as in `load`.
        let liveData = try? Data(
            contentsOf: URL(fileURLWithPath: Paths.transcriptLivePath(sessionId: sessionId))
        )
        betweenFiles?()
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        duringRead?()
        let maximumBytes = 6 * 1_024 * 1_024
        guard let data, data.count <= maximumBytes else {
            return nil
        }
        guard let snapshot = TranscriptFiles.snapshot(
            sealed: data,
            live: liveData.flatMap { $0.count <= maximumBytes ? $0 : nil },
            decoder: transcriptDecoder()
        ) else {
            return nil
        }
        guard transcriptOwnerAllowsSnapshot(
            sessionId: sessionId,
            copilotSessionId: snapshot.copilotSessionId,
            expectedSignature: signature
        ) else {
            return nil
        }
        guard transcriptQuarantineAllowsRead(
            sessionId: sessionId,
            snapshot: snapshot,
            expectedSignature: signature
        ) else {
            return nil
        }
        return snapshot
    }

    /// Synchronously validates whether the process recorded in
    /// `transcript-owner.json` for `sessionId` is actually this session (rather
    /// than a foreign tab that inherited its environment/path). Quarantine is
    /// otherwise only populated lazily as a side effect of reading the
    /// transcript via `loadRemoteSnapshot`, which background tabs never do (no
    /// `TranscriptController` is ever started for them) and the selected tab
    /// may not have done yet at app bootstrap — so callers that are about to
    /// trust a resume marker (e.g. `AppModel.controller(for:)`) must call this
    /// directly instead of relying solely on `isCopilotSessionQuarantined`.
    /// Records the mismatch as a quarantine (matching `loadRemoteSnapshot`'s
    /// behavior) so subsequent reads stay consistent.
    nonisolated static func transcriptOwnerAllowsRead(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> Bool {
        let path = directory
            .appendingPathComponent("\(sessionId).transcript-owner.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let owner = try? JSONDecoder().decode(TranscriptOwner.self, from: data),
              owner.pid > 0 else {
            return true
        }
        if let ownerSessionId = owner.appSessionId {
            let allows = ownerSessionId.caseInsensitiveCompare(sessionId) == .orderedSame
            if !allows {
                recordForeignTranscriptQuarantine(
                    sessionId: sessionId,
                    copilotSessionId: owner.copilotSessionId,
                    directory: directory
                )
            }
            return allows
        }
        let snapshot = ProcessTree.snapshot()
        guard snapshot.nameOf[owner.pid] != nil else { return true }
        let environment = ProcessTree.inspect(owner.pid).env
        let allows = transcriptOwnerMatchesSession(
            sessionId: sessionId,
            ownerPID: owner.pid,
            snapshot: snapshot,
            environment: environment,
            dtachProcesses: ProcessTree.dtachProcesses(in: snapshot),
            sessionsDirectory: directory
        ) ?? true
        if !allows {
            recordForeignTranscriptQuarantine(
                sessionId: sessionId,
                copilotSessionId: owner.copilotSessionId,
                directory: directory
            )
        }
        return allows
    }

    /// Cross-checks a just-decoded transcript snapshot against the *current*
    /// owner marker's recorded Copilot session id. `transcriptOwnerAllowsRead`
    /// only validates ownership (appSessionId/pid) at the instant it's called;
    /// it can't detect the narrower race where a dead owner is reclaimed (a
    /// new, valid `transcript-owner.json` is written) before that new owner's
    /// first `publishTranscript()` overwrites `transcript.json` — so the bytes
    /// just decoded can still be the *previous* (possibly foreign) owner's
    /// content even though the owner file itself now looks legitimate. Reject
    /// (and quarantine) whenever the owner records a different Copilot session
    /// id than the transcript we actually read.
    ///
    /// `expectedSignature` is the signature sampled *before* the transcript
    /// bytes were read. When it no longer matches, the mismatch says nothing
    /// about provenance — the files simply moved underneath the read (a Copilot
    /// `/new` / `/resume` rotation replaces this tab's own marker and rewrites
    /// `transcript.json`) — so the read is rejected without persisting a
    /// quarantine that would permanently hide a session `/resume` can return to.
    nonisolated private static func transcriptOwnerAllowsSnapshot(
        sessionId: String,
        copilotSessionId: String,
        expectedSignature: LoadSignature?,
        directory: URL = Paths.sessionsDir
    ) -> Bool {
        guard let owner = readOwnerMarker(sessionId: sessionId, directory: directory),
              let ownerCopilotSessionId = owner.copilotSessionId else {
            // No owner recorded (or the owner predates copilotSessionId being
            // tracked) — nothing further to cross-check against.
            return true
        }
        if ownerCopilotSessionId == copilotSessionId { return true }

        // Stale read: the owner marker (and/or the transcript) changed after the
        // bytes we decoded were sampled. Reject, but never quarantine.
        if let expectedSignature,
           loadSignature(
               sessionId: sessionId,
               transcriptPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
           )?.hasSameProvenance(as: expectedSignature) != true {
            return false
        }

        // The owner's recorded Copilot session differs from the transcript we
        // read. Whether that is a genuine reclamation race (quarantine) or a
        // stale marker left by an orphaned/foreign copilot (must NOT permanently
        // quarantine this tab's own transcript) depends on whether the owner can
        // be corroborated as belonging to this tab.
        switch ownerCorroboration(
            owner: owner,
            sessionId: sessionId
        ) {
        case .aliveElsewhere:
            // A live process that does not belong to this tab holds the marker
            // (e.g. it claimed ownership via a stale COPILOT_PROJECTS_SESSION and
            // was later reparented to launchd). Reject this read so nothing is
            // surfaced under an untrusted owner, but do NOT persist a quarantine
            // that would outlive the stale owner and permanently hide this tab's
            // own transcript.
            return false
        case .confirmedThisTab, .dead:
            recordForeignTranscriptQuarantine(
                sessionId: sessionId,
                copilotSessionId: copilotSessionId,
                directory: directory
            )
            return false
        }
    }

    /// Runs the owner cross-check exactly the way a transcript read does:
    /// sample the file signature first, then validate the decoded snapshot's
    /// Copilot session id against the owner marker. `duringRead` runs between
    /// those two steps so callers (tests) can reproduce a Copilot `/new` /
    /// `/resume` rotation that lands mid-read.
    nonisolated static func snapshotPassesOwnerCrossCheck(
        sessionId: String,
        copilotSessionId: String,
        duringRead: () -> Void = {}
    ) -> Bool {
        let signature = loadSignature(
            sessionId: sessionId,
            transcriptPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )
        duringRead()
        return transcriptOwnerAllowsSnapshot(
            sessionId: sessionId,
            copilotSessionId: copilotSessionId,
            expectedSignature: signature
        )
    }

    private enum OwnerCorroboration {
        /// The owner's recorded process is gone.
        case dead
        /// The owner belongs to this tab (declared a matching native
        /// `appSessionId`, or its live pid resolves to this tab).
        case confirmedThisTab
        /// The owner is alive but does not belong to this tab — it resolves to a
        /// different tab, or cannot be resolved at all (an orphan).
        case aliveElsewhere
    }

    nonisolated private static func readOwnerMarker(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> TranscriptOwner? {
        let path = directory
            .appendingPathComponent("\(sessionId).transcript-owner.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let owner = try? JSONDecoder().decode(TranscriptOwner.self, from: data)
        else {
            return nil
        }
        return owner
    }

    /// Classifies a recorded owner marker relative to this tab. Only a marker that
    /// declares a matching native `appSessionId` is treated as this tab's confirmed
    /// owner — that field is written solely by a process that resolved its own tab
    /// through dtach ancestry, so it is spoof- and pid-reuse-resistant. A legacy
    /// marker without `appSessionId` cannot be positively bound to a tab (a live
    /// pid is not an identity, and a reused pid could resolve anywhere), so it is
    /// only ever `dead` (its recorded process is gone) or `aliveElsewhere`
    /// (present but unproven) — never `confirmedThisTab`. Quarantine PERSISTENCE
    /// and self-heal both hinge on `confirmedThisTab`, keeping them tied to the
    /// one trustworthy signal.
    nonisolated private static func ownerCorroboration(
        owner: TranscriptOwner,
        sessionId: String
    ) -> OwnerCorroboration {
        if let appSessionId = owner.appSessionId {
            return appSessionId.caseInsensitiveCompare(sessionId) == .orderedSame
                ? .confirmedThisTab
                : .aliveElsewhere
        }
        guard owner.pid > 0, processIsAlive(owner.pid) else { return .dead }
        return .aliveElsewhere
    }

    /// Best-effort liveness for a pid (no identity guarantee). Mirrors the
    /// extension hook's `process.kill(pid, 0)` probe: alive if the signal is
    /// deliverable, or if it exists but is owned by another user (EPERM).
    nonisolated static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    nonisolated static func currentBootTimeSeconds() -> Int? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(bootTime.tv_sec)
    }

    nonisolated private static func bootTimeSeconds(_ value: String?) -> Int? {
        guard let value,
              let secondsStart = value.range(of: "sec = ")?.upperBound else {
            return nil
        }
        let suffix = value[secondsStart...]
        let digits = suffix.prefix { $0.isNumber }
        return Int(digits)
    }

    struct CloseProcessIdentity: Hashable, Sendable, Codable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    nonisolated private static func closeProcessInfo(
        _ pid: pid_t
    ) -> (identity: CloseProcessIdentity, parentPID: pid_t)? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (
            CloseProcessIdentity(
                pid: pid,
                startSeconds: info.pbi_start_tvsec,
                startMicroseconds: info.pbi_start_tvusec
            ),
            pid_t(bitPattern: info.pbi_ppid)
        )
    }

    nonisolated static func closeProcessIsAlive(_ identity: CloseProcessIdentity) -> Bool {
        closeProcessInfo(identity.pid)?.identity == identity
    }

    /// Observe both the extension and its actual CLI parent. Keep their process
    /// birth identities across owner replacement: tracker restart is not CLI
    /// exit, and CLI exit is not evidence that child cleanup has finished.
    nonisolated static func liveCLIProcesses(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> Set<CloseProcessIdentity> {
        guard let owner = readOwnerMarker(sessionId: sessionId, directory: directory),
              ownerCorroboration(
                  owner: owner,
                  sessionId: sessionId
              ) == .confirmedThisTab,
              let tracker = closeProcessInfo(owner.pid) else {
            return []
        }
        if let recordedBootTime = bootTimeSeconds(owner.bootTime),
           let currentBootTime = currentBootTimeSeconds(),
           abs(recordedBootTime - currentBootTime) > 5 {
            return []
        }
        var processes: Set<CloseProcessIdentity> = [tracker.identity]
        // Legacy owners omit parentPid; kernel parentage still identifies the
        // CLI. A conflicting marker is never a reason to trust an arbitrary PID.
        if owner.parentPid == nil || owner.parentPid == tracker.parentPID,
           let parent = closeProcessInfo(tracker.parentPID) {
            processes.insert(parent.identity)
        }
        return processes
    }

    nonisolated static func transcriptOwnerMatchesSession(
        sessionId: String,
        ownerPID: pid_t,
        snapshot: ProcessTree.Snapshot,
        environment: [String: String],
        dtachProcesses: [ProcessTree.DtachProcess],
        sessionsDirectory: URL
    ) -> Bool? {
        guard let resolved = ProcessTree.managedSessionId(
            for: ownerPID,
            fallbackSessionId: Env.sessionId(environment),
            sessionsDirectory: sessionsDirectory,
            in: snapshot,
            dtachProcesses: dtachProcesses
        ) else {
            return nil
        }
        return resolved.caseInsensitiveCompare(sessionId) == .orderedSame
    }

    nonisolated static func isCopilotSessionQuarantined(
        sessionId: String,
        copilotSessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        guard let quarantine = loadQuarantine(
            sessionId: sessionId,
            directory: directory
        ) else {
            return false
        }
        return quarantine.foreignCopilotSessionIds.contains(copilotSessionId)
    }

    nonisolated private static func recordForeignTranscriptQuarantine(
        sessionId: String,
        copilotSessionId: String?,
        directory: URL = Paths.sessionsDir
    ) {
        if let copilotSessionId, UUID(uuidString: copilotSessionId) != nil {
            quarantineLock.lock()
            defer { quarantineLock.unlock() }
            let path = directory
                .appendingPathComponent("\(sessionId).transcript-quarantine.json").path
            let existing = loadQuarantine(sessionId: sessionId, directory: directory)?
                .foreignCopilotSessionIds ?? []
            guard !existing.contains(copilotSessionId) else { return }
            let quarantine = TranscriptQuarantine(
                schemaVersion: TranscriptQuarantine.currentSchemaVersion,
                foreignCopilotSessionIds: existing.union([copilotSessionId])
            )
            if let data = try? JSONEncoder().encode(quarantine) {
                try? data.write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
            }
        }
    }

    nonisolated private static func transcriptQuarantineAllowsRead(
        sessionId: String,
        snapshot: TranscriptSnapshot,
        expectedSignature: LoadSignature
    ) -> Bool {
        quarantineLock.lock()
        defer { quarantineLock.unlock() }
        guard loadSignature(
            sessionId: sessionId,
            transcriptPath: Paths.transcriptSnapshotPath(sessionId: sessionId)
        )?.hasSameProvenance(as: expectedSignature) == true else {
            return false
        }
        let path = Paths.transcriptQuarantinePath(sessionId: sessionId)
        guard let quarantine = loadQuarantine(sessionId: sessionId) else {
            return true
        }
        guard quarantine.foreignCopilotSessionIds.contains(
            snapshot.copilotSessionId
        ) else {
            try? FileManager.default.removeItem(atPath: path)
            return true
        }
        // Self-heal: a quarantined id that is ALSO the Copilot session of the
        // confirmed current owner of this tab cannot be foreign to its own tab —
        // it was recorded from a since-displaced stale owner. Drop only that entry,
        // and only on positive same-tab provenance (never merely because a live
        // owner is absent, which could un-hide genuinely foreign content). We
        // already hold quarantineLock, so mutate the file directly rather than
        // routing through the (also-locking) record/remove helpers.
        if let owner = readOwnerMarker(sessionId: sessionId),
           owner.copilotSessionId == snapshot.copilotSessionId,
           case .confirmedThisTab = ownerCorroboration(
               owner: owner,
               sessionId: sessionId
           ) {
            let remaining = quarantine.foreignCopilotSessionIds
                .subtracting([snapshot.copilotSessionId])
            if remaining.isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            } else if let data = try? JSONEncoder().encode(TranscriptQuarantine(
                schemaVersion: TranscriptQuarantine.currentSchemaVersion,
                foreignCopilotSessionIds: remaining
            )) {
                try? data.write(
                    to: URL(fileURLWithPath: path),
                    options: .atomic
                )
            }
            return true
        }
        return false
    }

    nonisolated private static func fileGeneration(_ path: String) -> String {
        guard let signature = fileSignature(path) else { return "missing" }
        return "\(signature.fileNumber):\(signature.size):\(signature.modifiedAt)"
    }

    nonisolated private static func loadSignature(
        sessionId: String,
        transcriptPath: String
    ) -> LoadSignature? {
        guard let transcript = fileSignature(transcriptPath) else { return nil }
        return LoadSignature(
            transcript: transcript,
            owner: fileSignature(Paths.transcriptOwnerPath(sessionId: sessionId)),
            quarantine: fileSignature(Paths.transcriptQuarantinePath(sessionId: sessionId)),
            live: fileSignature(Paths.transcriptLivePath(sessionId: sessionId))
        )
    }

    nonisolated private static func fileSignature(_ path: String) -> FileSignature? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else {
            return nil
        }
        return FileSignature(attributes: attributes)
    }

    nonisolated private static func loadQuarantine(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> TranscriptQuarantine? {
        let path = directory
            .appendingPathComponent("\(sessionId).transcript-quarantine.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let quarantine = try? JSONDecoder().decode(
                  TranscriptQuarantine.self,
                  from: data
              ),
              quarantine.schemaVersion == TranscriptQuarantine.currentSchemaVersion else {
            return nil
        }
        return quarantine
    }

    nonisolated private static func emptyRemoteSnapshot() -> TranscriptSnapshot {
        TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: Date(),
            copilotSessionId: "",
            turns: []
        )
    }

    nonisolated private static func transcriptDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = try? fractional.parse(value) {
                return date
            }

            if let date = try? plain.parse(value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timestamp: \(value)"
            )
        }
        return decoder
    }
}
