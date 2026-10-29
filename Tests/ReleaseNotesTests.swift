import Foundation
import XCTest
import CopilotProjectsUI

final class ReleaseNotesTests: XCTestCase {
    private func data(_ overrides: [String: Any] = [:]) throws -> Data {
        var fields: [String: Any] = [
            "schemaVersion": 1, "repository": "example/app",
            "version": "2026.10.25", "build": "42",
            "sourceRevision": String(repeating: "a", count: 40),
            "markdown": "## Fixes\n\n- A fix", "plainText": "Fixes\n\n- A fix",
        ]
        fields.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: fields)
    }

    func testExactBuildMatchesAndFormatsVersion() throws {
        let snapshot = try JSONDecoder().decode(ReleaseNotesSnapshot.self, from: data())
        try snapshot.validate(version: "2026.10.25", build: "42")
        XCTAssertEqual(snapshot.displayVersion, "2026.10.25 (42)")
        XCTAssertEqual(snapshot.releasesURL, URL(string: "https://github.com/example/app/releases"))
        XCTAssertThrowsError(try snapshot.validate(version: "2026.10.25", build: "43"))
        XCTAssertThrowsError(try snapshot.validate(version: "2026.10.26", build: "42"))
    }

    func testInvalidDocumentsFailRatherThanDisplayNotes() throws {
        for overrides: [String: Any] in [
            ["schemaVersion": 2], ["sourceRevision": "main"], ["markdown": " \n"],
            ["plainText": String(repeating: "x", count: 4001)], ["repository": "../private"],
        ] {
            let snapshot = try JSONDecoder().decode(ReleaseNotesSnapshot.self, from: data(overrides))
            XCTAssertThrowsError(try snapshot.validate(version: "2026.10.25", build: "42"))
        }
    }

    func testBundleLoadingAndDevelopmentAbsence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.notes.\(UUID().uuidString)",
            "CFBundleShortVersionString": "2026.10.25", "CFBundleVersion": "42",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let empty = root.appendingPathComponent("Empty.bundle")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(try ReleaseNotesSnapshot.load(bundle: XCTUnwrap(Bundle(url: empty))))
        try data().write(to: root.appendingPathComponent("release-notes.json"))
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertEqual(try ReleaseNotesSnapshot.load(bundle: bundle)?.build, "42")
        try data(["build": "41"]).write(to: root.appendingPathComponent("release-notes.json"))
        XCTAssertThrowsError(try ReleaseNotesSnapshot.load(bundle: bundle))
    }
}
