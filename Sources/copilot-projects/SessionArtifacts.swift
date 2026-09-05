import Foundation
import Darwin
import CopilotProjectsCore

struct SessionStatusRecord: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let status: SessionStatus
    let statusTimestamp: Int64
    let promptStatusTimestamp: Int64

    init(status: SessionStatus, statusTimestamp: Int64, promptStatusTimestamp: Int64) {
        schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.statusTimestamp = statusTimestamp
        self.promptStatusTimestamp = promptStatusTimestamp
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
            try Data(String(timestamp).utf8).write(
                to: sessionsDirectory.appendingPathComponent("\(sessionId).status-timestamp"),
                options: .atomic
            )
            try Data(String(promptStatusTimestamp).utf8).write(
                to: sessionsDirectory
                    .appendingPathComponent("\(sessionId).prompt-status-timestamp"),
                options: .atomic
            )
            // Compatibility markers are written only after the complete record, with
            // status last so older app versions cannot combine it with stale clocks.
            try Data(status.rawValue.utf8).write(
                to: sessionsDirectory.appendingPathComponent("\(sessionId).status"),
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
            try? await Task.sleep(for: $0)
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

    static func closeSessionRequests(
        sessionsDirectory: URL = Paths.sessionsDir
    ) throws -> [String] {
        guard FileManager.default.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        )
        return entries.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(closeRequestSuffix) else { return nil }
            let sessionId = String(name.dropLast(closeRequestSuffix.count))
            return UUID(uuidString: sessionId) != nil ? sessionId : nil
        }
    }

    static func removeFiles(sessionId: String) {
        let fm = FileManager.default
        for path in [
            Paths.dtachSocketPath(sessionId: sessionId),
            Paths.statusMarkerPath(sessionId: sessionId),
            Paths.statusTimestampMarkerPath(sessionId: sessionId),
            Paths.promptStatusTimestampMarkerPath(sessionId: sessionId),
            Paths.statusRecordPath(sessionId: sessionId),
            Paths.backgroundAgentsMarkerPath(sessionId: sessionId),
            Paths.sessionIdleHookMarkerPath(sessionId: sessionId),
            Paths.copilotSessionMarkerPath(sessionId: sessionId),
            Paths.copilotAllowAllMarkerPath(sessionId: sessionId),
            Paths.scheduledTurnMarkerPath(sessionId: sessionId),
            Paths.agentActivitySnapshotPath(sessionId: sessionId),
            Paths.userInputResponsePath(sessionId: sessionId),
            Paths.elicitationResponsePath(sessionId: sessionId),
            Paths.closeSessionRequestPath(sessionId: sessionId),
            Paths.transcriptSnapshotPath(sessionId: sessionId),
            Paths.transcriptOwnerPath(sessionId: sessionId),
            Paths.transcriptOwnerLockPath(sessionId: sessionId),
            Paths.transcriptQuarantinePath(sessionId: sessionId),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }
}
