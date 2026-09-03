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
    private static let gracefulClosePolls = 200

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
        let socket = Paths.dtachSocketPath(sessionId: sessionId)
        if Paths.dtachExecutable != nil {
            let processes = ProcessTree.snapshot()
            // Kill both the attached client and master. This also closes the tiny
            // creation race where only the client is visible before it forks the
            // master; killing just a selected master could miss that case.
            for process in ProcessTree.dtachProcesses(in: processes)
                where process.socketPath == socket {
                kill(process.pid, SIGTERM)
            }
        }
        removeFiles(sessionId: sessionId)
    }

    /// Ask the live tracker extension to route this close through the CLI's
    /// in-app exit path, then force the existing dtach teardown after the tracker
    /// exits or a bounded grace period. The image tombstone remains synchronous.
    static func destroyGracefully(
        sessionId: String,
        kittyImageDiskStore: RemoteKittyImageDiskStore = .shared
    ) -> Task<Void, Never> {
        // Synchronously tombstone this session's durable Kitty images before
        // requesting exit, so late persistence can never resurrect closed data.
        _ = kittyImageDiskStore.tombstone(sessionId: sessionId)
        let cliPID = TranscriptController.liveCLIProcessPID(sessionId: sessionId)
        let requested = writeCloseSessionRequest(sessionId: sessionId)

        return Task.detached(priority: .utility) {
            if requested, let cliPID {
                _ = await Self.waitForProcessExit(cliPID)
            }
            Self.forceDestroy(sessionId: sessionId)
        }
    }

    static func waitForProcessExit(
        _ pid: pid_t,
        maximumPolls: Int = gracefulClosePolls,
        processIsAlive: @escaping @Sendable (pid_t) -> Bool = {
            TranscriptController.processIsAlive($0)
        },
        sleep: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: .milliseconds(100))
        }
    ) async -> Bool {
        for _ in 0 ..< maximumPolls {
            if Task.isCancelled { return false }
            guard processIsAlive(pid) else { return true }
            await sleep()
        }
        return !processIsAlive(pid)
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
            return FileManager.default.createFile(
                atPath: url.path,
                contents: Data(),
                attributes: [.posixPermissions: 0o600]
            )
        } catch {
            NSLog("copilot-projects: could not request graceful close for \(sessionId): \(error)")
            return false
        }
    }

    static func forceDestroyStaleCloseSessionRequests(
        sessionsDirectory: URL = Paths.sessionsDir,
        preserving sessionIds: Set<String> = [],
        destroy: (String) -> Void = { SessionArtifacts.forceDestroy(sessionId: $0) }
    ) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in entries where url.lastPathComponent.hasSuffix(closeRequestSuffix) {
            let name = url.lastPathComponent
            let sessionId = String(name.dropLast(closeRequestSuffix.count))
            guard UUID(uuidString: sessionId) != nil else { continue }
            if sessionIds.contains(sessionId) {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            destroy(sessionId)
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
