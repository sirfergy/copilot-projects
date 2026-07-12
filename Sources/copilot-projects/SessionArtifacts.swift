import Foundation
import Darwin
import CopilotProjectsCore

enum SessionArtifacts {
    static func currentStatusTimestamp() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    @discardableResult
    static func persistStatus(
        sessionId: String,
        status: SessionStatus,
        timestamp: Int64,
        sessionsDirectory: URL = Paths.sessionsDir
    ) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: sessionsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(status.rawValue.utf8).write(
                to: sessionsDirectory.appendingPathComponent("\(sessionId).status"),
                options: .atomic
            )
            try Data(String(timestamp).utf8).write(
                to: sessionsDirectory.appendingPathComponent("\(sessionId).status-timestamp"),
                options: .atomic
            )
            return true
        } catch {
            NSLog("copilot-projects: could not persist status for \(sessionId): \(error)")
            return false
        }
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

    static func destroy(sessionId: String, snapshot: ProcessTree.Snapshot? = nil) {
        let socket = Paths.dtachSocketPath(sessionId: sessionId)
        if Paths.dtachExecutable != nil {
            let processes = snapshot ?? ProcessTree.snapshot()
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

    static func removeFiles(sessionId: String) {
        let fm = FileManager.default
        for path in [
            Paths.dtachSocketPath(sessionId: sessionId),
            Paths.statusMarkerPath(sessionId: sessionId),
            Paths.statusTimestampMarkerPath(sessionId: sessionId),
            Paths.backgroundAgentsMarkerPath(sessionId: sessionId),
            Paths.sessionIdleHookMarkerPath(sessionId: sessionId),
            Paths.copilotSessionMarkerPath(sessionId: sessionId),
            Paths.copilotAllowAllMarkerPath(sessionId: sessionId),
            Paths.scheduledTurnMarkerPath(sessionId: sessionId),
            Paths.agentActivitySnapshotPath(sessionId: sessionId),
            Paths.transcriptSnapshotPath(sessionId: sessionId),
        ] {
            try? fm.removeItem(atPath: path)
        }
    }
}
