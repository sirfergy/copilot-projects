import Foundation
import CopilotProjectsCore

struct StateRepository {
    enum LoadResult {
        case missing
        case loaded(PersistedState)
        case recovered(PersistedState, String)
        case failed(String)
    }

    let path: URL
    let backupPath: URL
    var closeIntentPath: URL { path.appendingPathExtension("closing") }

    struct CloseIntent: Codable {
        var sessionIds: Set<String> = []
        var projectIds: Set<String> = []

        func applying(to state: PersistedState) -> PersistedState {
            var state = state
            state.projects.removeAll { projectIds.contains($0.id) }
            for index in state.projects.indices {
                state.projects[index].sessions.removeAll { sessionIds.contains($0.id) }
            }
            return state
        }
    }

    init(path: URL = Paths.statePath) {
        self.path = path
        self.backupPath = path.appendingPathExtension("backup")
    }

    func load() -> LoadResult {
        do {
            let intent = try pendingCloses()
            switch loadWorkspace() {
            case .loaded(let state):
                return .loaded(try normalized(intent.applying(to: state)))
            case .recovered(let state, let message):
                return .recovered(try normalized(intent.applying(to: state)), message)
            case .missing:
                return .missing
            case .failed(let message):
                return .failed(message)
            }
        } catch {
            return .failed("Could not recover accepted session closes at \(closeIntentPath.path): \(error)")
        }
    }

    private func loadWorkspace() -> LoadResult {
        guard FileManager.default.fileExists(atPath: path.path) else {
            guard FileManager.default.fileExists(atPath: backupPath.path) else { return .missing }
            do {
                return .recovered(
                    try decode(Data(contentsOf: backupPath)),
                    "Recovered workspace state from \(backupPath.path) because \(path.path) was missing."
                )
            } catch {
                return .failed(
                    "Workspace state was missing at \(path.path), and its backup was invalid: \(error)"
                )
            }
        }
        do {
            return .loaded(try decode(Data(contentsOf: path)))
        } catch StateError.unsupportedSchema(let version) {
            return .failed(
                "Workspace state schema \(version) is newer than this app supports "
                + "(\(PersistedState.currentSchemaVersion)). The file was left untouched."
            )
        } catch {
            do {
                let state = try decode(Data(contentsOf: backupPath))
                return .recovered(
                    state,
                    "Recovered workspace state from \(backupPath.path) because \(path.path) was unreadable: \(error)"
                )
            } catch let backupError {
                return .failed(
                    "Could not load workspace state at \(path.path), and its backup was unavailable or invalid. "
                    + "Original error: \(error). Backup error: \(backupError)"
                )
            }
        }
    }

    func pendingCloses() throws -> CloseIntent {
        guard FileManager.default.fileExists(atPath: closeIntentPath.path) else {
            return CloseIntent()
        }
        return try JSONDecoder().decode(CloseIntent.self, from: Data(contentsOf: closeIntentPath))
    }

    /// One atomic acceptance point for an entire close action, before images,
    /// tracker commands or workspace rows change. The command markers are not
    /// the journal: a tracker can consume them while a project batch is written.
    func acceptCloses(sessionIds: [String], projectIds: [String] = []) throws {
        var intent = try pendingCloses()
        intent.sessionIds.formUnion(sessionIds)
        intent.projectIds.formUnion(projectIds)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(intent).write(to: closeIntentPath, options: .atomic)
    }

    /// Called only after all accepted teardown tasks finish. Both recovery
    /// copies must exclude the closed rows before the intent can be forgotten.
    func finishCloses(_ state: PersistedState) throws {
        guard FileManager.default.fileExists(atPath: closeIntentPath.path) else { return }
        let closedState = try normalized(pendingCloses().applying(to: state))
        try save(closedState)
        try JSONEncoder().encode(closedState).write(to: backupPath, options: .atomic)
        try FileManager.default.removeItem(at: closeIntentPath)
    }

    func save(_ state: PersistedState) throws {
        try validate(state)
        let encoded = try JSONEncoder().encode(state)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // Preserve only a known-good prior file. A corrupt primary must never replace
        // the last usable backup.
        if let existing = try? Data(contentsOf: path),
           (try? decode(existing)) != nil {
            do {
                try existing.write(to: backupPath, options: .atomic)
            } catch {
                NSLog("copilot-projects: could not update state backup: \(error)")
            }
        }
        try encoded.write(to: path, options: .atomic)
    }

    func normalized(_ state: PersistedState) throws -> PersistedState {
        try validate(state)
        var copy = state
        for index in copy.projects.indices {
            let sessions = copy.projects[index].sessions
            if !sessions.contains(where: { $0.id == copy.projects[index].selectedSessionId }) {
                copy.projects[index].selectedSessionId = sessions.first?.id
            }
        }
        if !copy.projects.contains(where: { $0.id == copy.selectedProjectId }) {
            copy.selectedProjectId = copy.projects.first?.id
        }
        copy.schemaVersion = PersistedState.currentSchemaVersion
        return copy
    }

    private func decode(_ data: Data) throws -> PersistedState {
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        guard decoded.schemaVersion <= PersistedState.currentSchemaVersion else {
            throw StateError.unsupportedSchema(decoded.schemaVersion)
        }
        return try normalized(decoded)
    }

    private func validate(_ state: PersistedState) throws {
        let projectIds = state.projects.map(\.id)
        guard Set(projectIds).count == projectIds.count else {
            throw StateError.duplicateProjectId
        }
        let sessionIds = state.projects.flatMap(\.sessions).map(\.id)
        guard Set(sessionIds).count == sessionIds.count else {
            throw StateError.duplicateSessionId
        }
    }

    enum StateError: LocalizedError {
        case unsupportedSchema(Int)
        case duplicateProjectId
        case duplicateSessionId

        var errorDescription: String? {
            switch self {
            case .unsupportedSchema(let version):
                return "State schema \(version) is newer than supported schema \(PersistedState.currentSchemaVersion)."
            case .duplicateProjectId:
                return "Workspace state contains duplicate project ids."
            case .duplicateSessionId:
                return "Workspace state contains duplicate session ids."
            }
        }
    }
}
