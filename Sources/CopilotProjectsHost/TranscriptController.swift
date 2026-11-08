import Foundation
import Combine
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

@MainActor
final class TranscriptController: ObservableObject {
    private struct TranscriptOwner: Decodable {
        let appSessionId: String?
        let copilotSessionId: String?
        let pid: pid_t
        let parentPid: pid_t?
        let bootTime: String?
    }

    private struct LoadSignature: Equatable, Sendable {
        let transcript: FileSignature
        let owner: FileSignature?
        let live: FileSignature?
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
        ), ownerNames(snapshot, sessionId: sessionId) else {
            return LoadResult(signature: signature, snapshot: nil)
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
        ), ownerNames(snapshot, sessionId: sessionId) else {
            return nil
        }
        // A sealed file or owner marker replaced during the read makes it
        // stale. The live file only adds the turn in progress to the sealed
        // file it extends (`TranscriptFiles` checks that), so streaming does not.
        let current = loadSignature(sessionId: sessionId, transcriptPath: path)
        guard current?.transcript == signature.transcript, current?.owner == signature.owner else {
            return nil
        }
        return snapshot
    }

    /// Whether `snapshot` is the conversation the tab's owner marker names. The
    /// tracker points the marker at a new conversation before it publishes that
    /// conversation's transcript, so until the two agree the file still holds
    /// the conversation the tab left, and nothing is shown. No marker, or one
    /// that names no conversation, leaves nothing to compare.
    nonisolated private static func ownerNames(
        _ snapshot: TranscriptSnapshot,
        sessionId: String
    ) -> Bool {
        guard let named = readOwnerMarker(sessionId: sessionId)?.copilotSessionId else {
            return true
        }
        return named == snapshot.copilotSessionId
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
    /// Only a marker that names this tab counts: one without `appSessionId`
    /// offers just a pid, which is not an identity.
    nonisolated static func liveCLIProcesses(
        sessionId: String,
        directory: URL = Paths.sessionsDir
    ) -> Set<CloseProcessIdentity> {
        guard let owner = readOwnerMarker(sessionId: sessionId, directory: directory),
              owner.appSessionId?.caseInsensitiveCompare(sessionId) == .orderedSame,
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
