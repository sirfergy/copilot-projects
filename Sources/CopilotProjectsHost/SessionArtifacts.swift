import Foundation
import Darwin
import CopilotProjectsCore
import CopilotProjectsProtocol

struct InputWaitContext: Codable, Equatable {
    let senderSessionId: String
    let rootSessionId: String
    let conversationEpoch: String
}

struct SessionStatusRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let status: SessionStatus
    let statusTimestamp: Int64
    let promptStatusTimestamp: Int64
    let inputWait: InputWaitContext?

    init(
        status: SessionStatus,
        statusTimestamp: Int64,
        promptStatusTimestamp: Int64,
        inputWait: InputWaitContext? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.statusTimestamp = statusTimestamp
        self.promptStatusTimestamp = promptStatusTimestamp
        self.inputWait = inputWait
    }
}

enum SessionStatusRecordLoad: Equatable {
    case missing
    case loaded(SessionStatusRecord)
    case invalid
}

enum SessionArtifacts {
    private static let closeRequestSuffix = ".close-session-request"
    private static let gracefulCloseTimeout: Duration = .seconds(20)

    static func currentStatusTimestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    @discardableResult
    static func persistStatus(
        sessionId: String,
        status: SessionStatus,
        timestamp: Int64,
        promptStatusTimestamp: Int64,
        sessionsDirectory: URL = Paths.sessionsDir
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let record = SessionStatusRecord(
                status: status,
                statusTimestamp: timestamp,
                promptStatusTimestamp: promptStatusTimestamp
            )
            try JSONEncoder().encode(record).write(
                to: sessionsDirectory.appendingPathComponent("\(sessionId).status-record.json"),
                options: .atomic
            )
            return true
        } catch {
            NSLog("copilot-projects: could not persist status for \(sessionId): \(error)")
            return false
        }
    }

    static func loadStatusRecord(
        sessionId: String,
        sessionsDirectory: URL = Paths.sessionsDir
    ) -> SessionStatusRecordLoad {
        let url = sessionsDirectory.appendingPathComponent("\(sessionId).status-record.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(SessionStatusRecord.self, from: data),
              record.schemaVersion == SessionStatusRecord.currentSchemaVersion
        else { return .invalid }
        return .loaded(record)
    }

    @discardableResult
    static func setBackgroundAgentsActive(
        sessionId: String,
        active: Bool,
        sessionsDirectory: URL = Paths.sessionsDir
    ) -> Bool {
        let marker = sessionsDirectory.appendingPathComponent("\(sessionId).background-agents")
        do {
            if active {
                try FileManager.default.createDirectory(
                    at: sessionsDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try Data().write(to: marker, options: .atomic)
            } else if FileManager.default.fileExists(atPath: marker.path) {
                try FileManager.default.removeItem(at: marker)
            }
            return true
        } catch {
            NSLog("copilot-projects: could not update background-agent marker for \(sessionId): \(error)")
            return false
        }
    }

    static func forceDestroy(sessionId: String) {
        forceDestroy(sessionIds: [sessionId])
    }

    static func forceDestroy(sessionIds: [String]) {
        guard !sessionIds.isEmpty else { return }
        if Paths.dtachExecutable != nil {
            let processes = ProcessTree.snapshot()
            let sockets = Set(sessionIds.map {
                Paths.dtachSocketPath(sessionId: $0)
            })
            // Kill both the attached client and master. This also closes the tiny
            // creation race where only the client is visible before it forks the
            // master; killing just a selected master could miss that case.
            for process in ProcessTree.dtachProcesses(in: processes)
                where process.socketPath.map(sockets.contains) == true {
                kill(process.pid, SIGTERM)
            }
        }
        for sessionId in sessionIds {
            removeFiles(sessionId: sessionId)
        }
    }

    /// Ask the live tracker extension to route this close through the CLI's
    /// in-app exit path, then force the existing dtach teardown after the tracker
    /// exits or a bounded grace period. The image tombstone remains synchronous.
    static func destroyGracefully(
        sessionId: String,
        kittyImageDiskStore: RemoteKittyImageDiskStore = .shared
    ) -> Task<Void, Never> {
        destroyGracefully(
            sessionIds: [sessionId],
            kittyImageDiskStore: kittyImageDiskStore
        )
    }

    /// Batch variant used when one user action closes multiple sessions. The
    /// requests are recorded synchronously, their grace waits run concurrently,
    /// and one fresh process snapshot covers the fallback after they finish.
    static func destroyGracefully(
        sessionIds: [String],
        kittyImageDiskStore: RemoteKittyImageDiskStore = .shared
    ) -> Task<Void, Never> {
        let deadline = ContinuousClock.now.advanced(by: gracefulCloseTimeout)
        let discoveryDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        let requests = sessionIds.map { sessionId in
            _ = kittyImageDiskStore.tombstone(sessionId: sessionId)
            return (
                sessionId: sessionId,
                processes: TranscriptController.liveCLIProcesses(sessionId: sessionId),
                requested: writeCloseSessionRequest(sessionId: sessionId)
            )
        }

        return Task.detached(priority: .utility) {
            // One background snapshot for the batch distinguishes a CLI still
            // starting its tracker from a shell. Include this work in the grace
            // deadline without blocking the main actor's tab removal.
            let processes = ProcessTree.snapshot()
            let dtach = ProcessTree.dtachProcesses(in: processes)
            let agentNames = Env.agentProcessNames()
            await withTaskGroup(of: Void.self) { group in
                for request in requests {
                    guard request.requested else { continue }
                    let master = ProcessTree.dtachMaster(
                        forSocket: Paths.dtachSocketPath(sessionId: request.sessionId),
                        among: dtach
                    )
                    let cliStarting = master.map {
                        ProcessTree.hasDescendant(under: $0, named: agentNames, in: processes)
                    } ?? false
                    group.addTask {
                        _ = await Self.waitForLiveCLIExit(
                            sessionId: request.sessionId,
                            initialProcesses: request.processes,
                            deadline: deadline,
                            discoveryDeadline: cliStarting ? deadline : discoveryDeadline
                        )
                    }
                }
            }
            if Task.isCancelled { return }
            Self.forceDestroy(sessionIds: sessionIds)
        }
    }

    static func waitForLiveCLIExit(
        sessionId: String,
        initialProcesses: Set<TranscriptController.CloseProcessIdentity>,
        deadline: ContinuousClock.Instant,
        discoveryDeadline: ContinuousClock.Instant,
        liveCLIProcesses: @escaping @Sendable (String) -> Set<TranscriptController.CloseProcessIdentity> = {
            TranscriptController.liveCLIProcesses(sessionId: $0)
        },
        processIsAlive: @escaping @Sendable (TranscriptController.CloseProcessIdentity) -> Bool = {
            TranscriptController.closeProcessIsAlive($0)
        },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
        sleep: @escaping @Sendable (Duration) async -> Void = {
            // Avoid the release-only cross-module duration-sleep specialization
            // crash (swiftlang/swift#86204) when the remote integration is linked.
            try? await ContinuousClock().sleep(until: .now.advanced(by: $0))
        }
    ) async -> Bool {
        var observed = initialProcesses
        while now() < deadline {
            if Task.isCancelled { return false }
            observed.formUnion(liveCLIProcesses(sessionId))
            guard now() < deadline else { return false }
            if !observed.isEmpty, !observed.contains(where: processIsAlive) { return true }
            if observed.isEmpty, now() >= discoveryDeadline { return false }
            let nextDeadline = observed.isEmpty ? min(deadline, discoveryDeadline) : deadline
            await sleep(max(.zero, min(.milliseconds(100), now().duration(to: nextDeadline))))
        }
        return false
    }

    @discardableResult
    static func writeCloseSessionRequest(
        sessionId: String,
        sessionsDirectory: URL = Paths.sessionsDir
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let url = sessionsDirectory
                .appendingPathComponent("\(sessionId)\(closeRequestSuffix)")
            if FileManager.default.fileExists(atPath: url.path) { return true }
            guard FileManager.default.createFile(
                atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]
            ) else {
                NSLog("copilot-projects: could not create close request at \(url.path)")
                return false
            }
            return true
        } catch {
            NSLog("copilot-projects: could not request graceful close for \(sessionId): \(error)")
            return false
        }
    }

    /// Per-session files earlier releases wrote but nothing reads any more. Removed
    /// with the session so leftovers from sessions that predate their retirement
    /// don't linger.
    private static let retiredFileSuffixes = [
        "status", "status-timestamp", "prompt-status-timestamp", "copilot-allow-all",
    ]

    /// Turn markers only the hook script names (`CopilotHooks.script`). The hook
    /// clears them on sessionEnd, which a close that has to kill the CLI never runs.
    private static let hookMarkerSuffixes = ["active-turn", "agent-stop-completion", "remote-host"]

    /// Files replaced by writing a pid-named sibling and renaming it over the
    /// original: `<name>.<pid>` by the hook, `<name>.<pid>.tmp` by the tracker. A
    /// writer killed between the two steps leaves the sibling behind.
    private static let hookTemporaryFileBases = ["status-record.json"]
    private static let trackerTemporaryFileBases = [
        "copilot-session", "agent-activity.json", "transcript.json",
        "transcript-live.json", "transcript-owner.json",
    ]

    /// `name` is a session file name without its `<sessionId>.` prefix.
    private static func isAbandonedTemporaryFile(_ name: String) -> Bool {
        func isPID(_ value: Substring) -> Bool {
            !value.isEmpty && value.allSatisfy { $0.isASCII && $0.isNumber }
        }
        for base in hookTemporaryFileBases where name.hasPrefix("\(base).") {
            if isPID(name.dropFirst(base.count + 1)) { return true }
        }
        for base in trackerTemporaryFileBases
            where name.hasPrefix("\(base).") && name.hasSuffix(".tmp") {
            if isPID(name.dropFirst(base.count + 1).dropLast(4)) { return true }
        }
        return false
    }

    private static func isLeakedFile(_ name: String) -> Bool {
        hookMarkerSuffixes.contains(name) || isAbandonedTemporaryFile(name)
    }

    static func removeFiles(sessionId: String) {
        let fm = FileManager.default
        for suffix in RemoteSessionActionKind.allCases.map({ "\($0.rawValue).json" }) {
            let path = Paths.sessionsDir.appendingPathComponent("\(sessionId).\(suffix)").path
            if fm.fileExists(atPath: path) {
                do { try fm.removeItem(atPath: path) }
                catch { NSLog("copilot-projects: could not remove session workflow file: \(error)") }
            }
        }
        let suffixed = (retiredFileSuffixes + hookMarkerSuffixes).map {
            Paths.sessionsDir.appendingPathComponent("\(sessionId).\($0)").path
        }
        for path in [
            Paths.dtachSocketPath(sessionId: sessionId),
            Paths.statusRecordPath(sessionId: sessionId),
            Paths.backgroundAgentsMarkerPath(sessionId: sessionId),
            Paths.sessionIdleHookMarkerPath(sessionId: sessionId),
            Paths.copilotSessionMarkerPath(sessionId: sessionId),
            Paths.scheduledTurnMarkerPath(sessionId: sessionId),
            Paths.agentActivitySnapshotPath(sessionId: sessionId),
            Paths.userInputResponsePath(sessionId: sessionId),
            Paths.elicitationResponsePath(sessionId: sessionId),
            Paths.setModelRequestPath(sessionId: sessionId),
            Paths.closeSessionRequestPath(sessionId: sessionId),
            Paths.transcriptSnapshotPath(sessionId: sessionId),
            Paths.transcriptLivePath(sessionId: sessionId),
            Paths.transcriptOwnerPath(sessionId: sessionId),
            Paths.transcriptQuarantinePath(sessionId: sessionId),
        ] + suffixed {
            try? fm.removeItem(atPath: path)
        }
        let prefix = "\(sessionId)."
        for name in (try? fm.contentsOfDirectory(atPath: Paths.sessionsDir.path)) ?? []
            where name.hasPrefix(prefix)
                && isAbandonedTemporaryFile(String(name.dropFirst(prefix.count))) {
            try? fm.removeItem(at: Paths.sessionsDir.appendingPathComponent(name))
        }
        removeTranscriptOwnerLock(sessionId: sessionId)
    }

    /// Deletes the files `removeFiles` used to leave behind (hook turn markers and
    /// abandoned temp files) for tabs that no longer exist. Only UUID-named tabs
    /// outside `keeping` with no dtach socket are considered, so a live session or
    /// a close still in progress is never touched; every other file is kept.
    static func removeLeakedFiles(
        keeping sessionIds: Set<String>,
        sessionsDirectory: URL = Paths.sessionsDir
    ) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: sessionsDirectory.path) else {
            return
        }
        let kept = Set(sessionIds.compactMap(UUID.init(uuidString:)))
        var attached = Set<UUID>()
        var leaked: [(sessionId: UUID, name: String)] = []
        for name in names {
            let parts = name.split(separator: ".", maxSplits: 1)
            guard parts.count == 2, let sessionId = UUID(uuidString: String(parts[0])) else {
                continue
            }
            if parts[1] == "sock" {
                attached.insert(sessionId)
            } else if isLeakedFile(String(parts[1])) {
                leaked.append((sessionId, name))
            }
        }
        for file in leaked
            where !kept.contains(file.sessionId) && !attached.contains(file.sessionId) {
            try? fm.removeItem(at: sessionsDirectory.appendingPathComponent(file.name))
        }
    }

    /// Trackers exclude each other with a kernel lock on this file, so it is
    /// removed only while the host holds that lock itself. A tracker still in
    /// its critical section keeps the file, which can't block a later claim.
    private static func removeTranscriptOwnerLock(sessionId: String) {
        let path = Paths.transcriptOwnerLockPath(sessionId: sessionId)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_EXLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        unlink(path)
        close(fd)
    }
}
