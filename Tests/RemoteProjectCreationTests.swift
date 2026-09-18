import Foundation
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

@MainActor
final class RemoteProjectCreationTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    private func model(_ root: URL, ledgerURL: URL? = nil) -> AppModel {
        AppModel(
            stateRepository: StateRepository(path: root.appendingPathComponent("state.json")),
            isAppActive: { false },
            agentActivityDirectory: root,
            resumeMarkerDirectory: root,
            remoteCopilotExecutable: { nil },
            remoteReposDirectory: { nil },
            remoteSessionBackendAvailable: { false },
            remoteSessionLauncher: { _, _, _, _ in XCTFail("Creating a project must not launch a session") },
            projectCreationLedger: ProjectCreationLedger(
                url: ledgerURL ?? root.appendingPathComponent("projects.json")
            )
        )
    }

    func testNameValidationAndWireRoundTrip() throws {
        XCTAssertEqual(RemoteProjectContract.normalizedName(" \nMobile project\t "), "Mobile project")
        XCTAssertNotNil(RemoteProjectContract.normalizedName(String(repeating: "x", count: 200)))
        XCTAssertNotNil(RemoteProjectContract.normalizedName("Work / experiments"))
        for name in ["", " \n", "a\nb", "a\tb", "a\u{0}", "a\u{7f}", "a\u{85}b",
                     String(repeating: "x", count: 201), String(repeating: "é", count: 101)] {
            XCTAssertNil(RemoteProjectContract.normalizedName(name), name)
        }
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCreateProjectRequest.self, from: JSONEncoder().encode(request)),
            request
        )
        let response = RemoteCreateProjectResponse(
            requestId: request.requestId, projectId: request.requestId.uuidString
        )
        XCTAssertEqual(
            try JSONDecoder().decode(RemoteCreateProjectResponse.self, from: JSONEncoder().encode(response)),
            response
        )
    }

    func testEmptyWorkspaceCreatesGroupWithoutSessionOrBackendAndPersists() throws {
        let root = try root()
        let model = model(root)
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: " Mobile ")
        let response = RemoteCreateProjectResponse(
            requestId: request.requestId, projectId: request.requestId.uuidString
        )
        XCTAssertEqual(model.createRemoteProject(request), .created(response))
        let project = try XCTUnwrap(model.project(response.projectId))
        XCTAssertEqual(project.name, "Mobile")
        XCTAssertEqual(project.cwd, Paths.defaultStartupDir)
        XCTAssertTrue(project.sessions.isEmpty)
        XCTAssertNil(project.selectedSessionId)
        XCTAssertEqual(model.selectedProjectId, response.projectId)
        XCTAssertEqual(self.model(root).project(response.projectId), project)
        let ledgerURL = root.appendingPathComponent("projects.json")
        XCTAssertNotNil(try ProjectCreationLedger(url: ledgerURL).record(for: request.requestId))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testCreationPreservesExistingMacSelection() throws {
        let root = try root()
        try StateRepository(path: root.appendingPathComponent("state.json")).save(PersistedState(
            projects: [Project(id: "existing", name: "Existing", cwd: "/tmp")],
            selectedProjectId: "existing"
        ))
        let model = model(root)
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        guard case .created = model.createRemoteProject(request) else {
            return XCTFail("Expected a new project")
        }
        XCTAssertEqual(model.selectedProjectId, "existing")
        XCTAssertEqual(model.projects.count, 2)
        XCTAssertTrue(model.projects.allSatisfy { $0.sessions.isEmpty })
    }

    func testRetryAfterRenameAndRestartUsesStoredIntent() throws {
        let root = try root()
        let model = model(root)
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        let response = RemoteCreateProjectResponse(
            requestId: request.requestId, projectId: request.requestId.uuidString
        )
        XCTAssertEqual(model.createRemoteProject(request), .created(response))
        model.renameProject(response.projectId, name: "Renamed on Mac")
        let restarted = self.model(root)
        XCTAssertEqual(restarted.createRemoteProject(request), .existing(response))
        XCTAssertEqual(restarted.project(response.projectId)?.name, "Renamed on Mac")
        XCTAssertEqual(restarted.projects.count, 1)
        XCTAssertEqual(restarted.createRemoteProject(RemoteCreateProjectRequest(
            requestId: request.requestId, name: "Different intent"
        )), .conflict)
    }

    func testDeletedProjectAndWorkspaceBackupRollbackDoNotResurrect() throws {
        let root = try root()
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        guard case .created = model(root).createRemoteProject(request) else {
            return XCTFail("Expected a new project")
        }
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        let empty = PersistedState(projects: [], selectedProjectId: nil)
        try repository.save(empty)
        XCTAssertEqual(model(root).createRemoteProject(request), .gone)
        try JSONEncoder().encode(empty).write(to: repository.backupPath)
        try Data("broken workspace".utf8).write(to: repository.path)
        let recovered = model(root)
        XCTAssertEqual(recovered.createRemoteProject(request), .gone)
        XCTAssertTrue(recovered.projects.isEmpty)
    }

    func testWorkspaceWriteFailureKeepsLiveIntentForExactRepair() throws {
        let root = try root()
        let model = model(root)
        let stateURL = root.appendingPathComponent("state.json")
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        XCTAssertEqual(model.createRemoteProject(request), .persistenceUnavailable)
        XCTAssertEqual(model.projects.count, 1)
        try FileManager.default.removeItem(at: stateURL)
        XCTAssertEqual(model.createRemoteProject(request), .existing(RemoteCreateProjectResponse(
            requestId: request.requestId, projectId: request.requestId.uuidString
        )))
        XCTAssertEqual(self.model(root).projects.count, 1)
    }

    func testLedgerWriteFailureCanBeRepairedAfterRestart() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses directory permissions")
        let root = try root()
        let directory = root.appendingPathComponent("ledger")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ledgerURL = directory.appendingPathComponent("projects.json")
        let model = model(root, ledgerURL: ledgerURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        XCTAssertEqual(model.createRemoteProject(request), .persistenceUnavailable)
        XCTAssertEqual(model.projects.count, 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let restarted = self.model(root, ledgerURL: ledgerURL)
        XCTAssertEqual(restarted.createRemoteProject(request), .existing(RemoteCreateProjectResponse(
            requestId: request.requestId, projectId: request.requestId.uuidString
        )))
        XCTAssertEqual(restarted.projects.count, 1)
        XCTAssertNotNil(try ProjectCreationLedger(url: ledgerURL).record(for: request.requestId))
    }

    func testMalformedLedgerAndFailedWorkspaceLoadFailClosed() throws {
        for corruptWorkspace in [false, true] {
            let root = try root()
            let corrupted = root.appendingPathComponent(corruptWorkspace ? "state.json" : "projects.json")
            let data = Data("not JSON".utf8)
            try data.write(to: corrupted)
            let model = model(root)
            XCTAssertEqual(model.createRemoteProject(RemoteCreateProjectRequest(
                requestId: UUID(), name: "Mobile"
            )), .persistenceUnavailable)
            XCTAssertTrue(model.projects.isEmpty)
            XCTAssertEqual(try Data(contentsOf: corrupted), data)
        }
    }

    func testNativeProjectIDCannotBeClaimedAndLegacyStateStillDecodes() throws {
        let root = try root()
        let id = UUID()
        let project = try JSONDecoder().decode(Project.self, from: Data(
            "{\"id\":\"\(id.uuidString)\",\"name\":\"Native\",\"cwd\":\"/tmp\",\"sessions\":[]}".utf8
        ))
        XCTAssertNil(project.creationFingerprint)
        try StateRepository(path: root.appendingPathComponent("state.json")).save(PersistedState(
            projects: [project], selectedProjectId: project.id
        ))
        let model = model(root)
        XCTAssertEqual(model.createRemoteProject(RemoteCreateProjectRequest(
            requestId: id, name: "Native"
        )), .conflict)
        XCTAssertEqual(model.projects, [project])
    }

    func testProjectLedgerBoundsTTLAndPersistence() throws {
        let root = try root()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        let record = ProjectCreationRecord(
            requestId: id.uuidString, createdAt: now,
            creationFingerprint: ProjectCreationRecord.fingerprint(name: "Mobile")
        )
        let ledgerURL = root.appendingPathComponent("ledger.json")
        try ProjectCreationLedger(url: ledgerURL).remember(record, now: now)
        XCTAssertEqual(try ProjectCreationLedger(url: ledgerURL).record(for: id, now: now), record)
        XCTAssertNil(try ProjectCreationLedger(url: ledgerURL).record(
            for: id, now: now.addingTimeInterval(ProjectCreationLedger.ttl + 1)
        ))
        let records = (0..<(ProjectCreationLedger.maxRecords + 3)).map { index in
            ProjectCreationRecord(
                requestId: "\(index)", createdAt: now.addingTimeInterval(Double(index)),
                creationFingerprint: record.creationFingerprint
            )
        }
        let pruned = ProjectCreationLedger.prune(records, now: now.addingTimeInterval(1_000))
        XCTAssertEqual(pruned.count, ProjectCreationLedger.maxRecords)
        XCTAssertEqual(pruned.first?.requestId, "3")
    }

    func testBridgeForwardsCreationAndReportsReleasedModel() throws {
        let root = try root()
        var model: AppModel? = self.model(root)
        let bridge: any SessionHost = RemoteModelBridge(model: try XCTUnwrap(model))
        let request = RemoteCreateProjectRequest(requestId: UUID(), name: "Mobile")
        guard case .created = bridge.createProject(request) else {
            return XCTFail("Expected the bridge to create an empty project")
        }
        model = nil
        XCTAssertEqual(bridge.createProject(request), .unavailable)
    }
}
