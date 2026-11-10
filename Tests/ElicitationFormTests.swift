import AppKit
import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsProtocol
import CopilotProjectsProtocolFixtures

@MainActor
final class ElicitationFormTests: XCTestCase {
    private func form(_ schema: String) throws -> RemoteElicitationForm? {
        RemoteElicitationForm.parse(
            try JSONDecoder().decode(RemoteJSONValue.self, from: Data(schema.utf8))
        )
    }

    /// The fixture is what a gateway serves for four pending questions: a form with
    /// every kind of field, an MCP server's form, a schema outside the subset, and a
    /// link. Each `form` is what the Mac's question card showed for that schema
    /// before the parser moved here.
    func testTheMacPublishesTheFormItsQuestionCardShows() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ProtocolFixtures.data(named: "elicitation-forms")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let served = try decoder.decode([RemoteElicitationRequest].self, from: fixture)

        let project = Project(
            name: "Forms", cwd: root.path, sessions: [Session(title: "Forms", cwd: root.path)]
        )
        let repository = StateRepository(path: root.appendingPathComponent("state.json"))
        try repository.save(PersistedState(projects: [project], selectedProjectId: project.id))
        let model = AppModel(stateRepository: repository, agentActivityDirectory: root)
        var activity = AgentActivitySnapshot(
            schemaVersion: 1, updatedAt: Date().ISO8601Format(), foregroundTurnActive: false,
            scheduledTurnActive: false, activeSubagents: [], schedules: [], idleGeneration: 1,
            lastIdleAborted: false, lastIdleTurnKind: nil, error: nil
        )
        activity.trackedElicitations = served.map {
            TrackedElicitation(
                requestId: $0.requestId, message: $0.message, mode: $0.mode, url: $0.url,
                schema: $0.schema, elicitationSource: $0.elicitationSource,
                requestedAt: $0.requestedAt.ISO8601Format()
            )
        }
        model.projects[0].sessions[0].agentActivity = activity

        let published = try XCTUnwrap(
            model.remoteWorkspaceSnapshot().projects[0].sessions[0].pendingElicitations
        )
        XCTAssertEqual(published, served)
        XCTAssertEqual(published.map { $0.form?.fields.count }, [9, 2, nil, nil])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: encoder.encode(published)) as? NSArray,
            try JSONSerialization.jsonObject(with: fixture) as? NSArray
        )

        // The Mac's own card shows the same fields, checked against the agent's schema.
        let shown = model.sessionPendingElicitations(sessionId: model.projects[0].sessions[0].id)
        XCTAssertEqual(
            shown.map { DesktopElicitationForm($0.form, schema: $0.schema)?.fields.map(\.published) },
            served.map { $0.form?.fields }
        )
    }

    func testOnlyAFormQuestionGetsAForm() {
        let schema = RemoteJSONValue.object([
            "properties": .object(["answer": .object(["type": .string("string")])]),
        ])
        func form(
            id: String = "question",
            mode: String? = nil,
            url: String? = nil
        ) -> RemoteElicitationForm? {
            TrackedElicitation(
                requestId: id, message: "", mode: mode, url: url, schema: schema, requestedAt: ""
            ).remoteRequest().form
        }
        XCTAssertNotNil(form())
        XCTAssertNotNil(form(mode: "form"))
        XCTAssertNil(form(mode: "url"))
        XCTAssertNil(form(url: "https://example.com"))
        XCTAssertNil(form(mode: "terminal-default"))
        XCTAssertNil(form(id: "synthetic::durable-ask-user::tool-call"))
    }

    func testASchemaOutsideTheSubsetGetsNoForm() throws {
        func properties(_ count: Int) -> String {
            let fields = (1...count).map { #""f\#($0)":{"type":"string"}"# }.joined(separator: ",")
            return #"{"properties":{\#(fields)}}"#
        }
        func choices(_ count: Int) -> String {
            let values = (1...count).map { #""c\#($0)""# }.joined(separator: ",")
            return #"{"properties":{"f":{"type":"string","enum":[\#(values)]}}}"#
        }
        XCTAssertNotNil(try form(properties(32)))
        XCTAssertNotNil(try form(choices(50)))
        let roots = [
            #"[]"#,
            #"{"type":"array","properties":{"f":{"type":"string"}}}"#,
            #"{"minProperties":1,"properties":{"f":{"type":"string"}}}"#,
            #"{"type":"object","properties":{}}"#,
            #"{"properties":{"f":{"type":"string"}},"required":["g"]}"#,
            properties(33),
            choices(51),
        ]
        let fields = [
            #"{"type":"object"}"#,
            #"{"$ref":"other"}"#,
            #"{"type":"string","pattern":"a+"}"#,
            #"{"type":"string","anyOf":[{"const":"a"}]}"#,
            // A constraint for another type, or on a choice, contradicts the schema.
            #"{"type":"number","minLength":1}"#,
            #"{"type":"string","maxItems":2}"#,
            #"{"type":"boolean","minimum":0}"#,
            #"{"type":"string","enum":["a"],"format":"email"}"#,
            #"{"type":"number","enum":["a"]}"#,
            #"{"type":"string","enum":["a","a"]}"#,
            #"{"type":"string","enum":[]}"#,
            #"{"type":"string","oneOf":[{"const":"a","pattern":"a"}]}"#,
            #"{"type":"string","minLength":3,"maxLength":1}"#,
            #"{"type":"string","minLength":1.5}"#,
            #"{"type":"string","format":5}"#,
            #"{"type":"integer","minimum":"1"}"#,
            #"{"type":"number","minimum":5,"maximum":1}"#,
            #"{"type":"array","items":{"type":"string"}}"#,
            #"{"type":"array","items":{"type":"number","enum":["a"]}}"#,
            #"{"type":"array","items":{"anyOf":[{"const":"a"}],"oneOf":[{"const":"b"}]}}"#,
            #"{"type":"array","minItems":2,"maxItems":1,"items":{"enum":["a"]}}"#,
        ]
        for schema in roots + fields.map({ #"{"type":"object","properties":{"f":\#($0)}}"# }) {
            XCTAssertNil(try form(schema), schema)
        }
    }
}
