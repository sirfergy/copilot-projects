import XCTest
@testable import copilot_projects
import CopilotProjectsCore

/// Covers the packaged-resource facades that replaced the embedded Swift string
/// literals: the assets have to load out of the bundle, and they have to load
/// with exactly the bytes the literals used to produce.
final class PackagedAssetTests: XCTestCase {
    func testAssetCommandIsReadOnlyAndRequiresSuccessfulLoading() {
        XCTAssertTrue(CLIMain.isCommand("check-assets"))
        var loaded = false
        XCTAssertEqual(CLIMain.run(["check-assets"], checkAssets: {
            loaded = true
            return true
        }), 0)
        XCTAssertTrue(loaded)
        XCTAssertEqual(CLIMain.run(["check-assets"], checkAssets: { false }), 1)
        XCTAssertEqual(CLIMain.run(["check-assets"]), 1)
        XCTAssertEqual(CLIMain.run(["check-assets", "extra"], checkAssets: { true }), 1)
    }

    // MARK: - tracker extension

    func testExtensionScriptLoadsFromItsPackagedResource() {
        let script = CopilotExtension.script
        XCTAssertFalse(script.isEmpty)
        XCTAssertTrue(script.contains(#"from "@github/copilot-sdk/extension""#))
        XCTAssertEqual(CopilotExtension.scriptURL.lastPathComponent, "extension.mjs")
    }

    /// A Swift multi-line literal excludes the newline before its closing
    /// delimiter, so the loader drops the resource file's trailing newline. If
    /// that ever stops happening, `install()` writes different bytes than every
    /// prior release did, and the concatenated `/app.js` gains stray newlines.
    func testPackagedTextAssetsCarryNoTrailingNewline() {
        for (name, value) in [
            ("extension.mjs", CopilotExtension.script),
            ("index.html", RemoteWebAssets.html),
            ("app.css", RemoteWebAssets.css),
            ("app.webmanifest", RemoteWebAssets.manifest),
            ("service-worker.js", RemoteWebAssets.serviceWorker),
            ("markdown.js", RemoteWebAssets.markdownJavascript),
            ("draft.js", RemoteWebAssets.draftJavascript),
            ("operations.js", RemoteWebAssets.operationsJavascript),
            ("control-delivery.js", RemoteWebAssets.controlDeliveryJavascript),
            ("session-creation.js", RemoteWebAssets.sessionCreationJavascript),
            ("terminal-image.js", RemoteWebAssets.terminalImageJavascript),
            ("transcript.js", RemoteWebAssets.transcriptJavascript),
            ("main.js", RemoteWebAssets.mainJavascript),
        ] {
            XCTAssertFalse(value.isEmpty, "\(name) loaded empty")
            XCTAssertFalse(value.hasSuffix("\n"), "\(name) kept its file trailing newline")
        }
    }

    // MARK: - web client

    func testJavaScriptIsTheFragmentsJoinedInOrder() {
        let expected = [
            RemoteWebAssets.markdownJavascript,
            RemoteWebAssets.draftJavascript,
            RemoteWebAssets.operationsJavascript,
            RemoteWebAssets.controlDeliveryJavascript,
            RemoteWebAssets.sessionCreationJavascript,
            RemoteWebAssets.terminalImageJavascript,
            RemoteWebAssets.transcriptJavascript,
            RemoteWebAssets.mainJavascript,
        ].joined(separator: "\n")
        XCTAssertTrue(
            RemoteWebAssets.javascript == expected,
            "the assembled app.js must preserve the declared fragment order"
        )
        XCTAssertTrue(RemoteWebAssets.javascript.hasPrefix(RemoteWebAssets.markdownJavascript))
        XCTAssertTrue(
            RemoteWebAssets.javascript.hasSuffix(RemoteWebAssets.mainJavascript),
            "a newly added fragment must also be appended to `javascript`"
        )
    }

    func testHTMLAndManifestLoadIntact() {
        XCTAssertTrue(RemoteWebAssets.html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(RemoteWebAssets.html.hasSuffix("</html>"))
        XCTAssertTrue(RemoteWebAssets.css.contains(":root"))
        XCTAssertTrue(RemoteWebAssets.serviceWorker.contains("addEventListener"))

        let manifest = try? JSONSerialization.jsonObject(
            with: Data(RemoteWebAssets.manifest.utf8)
        )
        XCTAssertNotNil(manifest, "the web manifest must still be valid JSON")
    }

    /// No asset may carry the raw-literal delimiters the extraction removed —
    /// that would mean a fragment was re-embedded rather than packaged.
    func testAssetsContainNoSwiftLiteralScaffolding() {
        for value in [
            CopilotExtension.script,
            RemoteWebAssets.html,
            RemoteWebAssets.css,
            RemoteWebAssets.javascript,
            RemoteWebAssets.serviceWorker,
        ] {
            XCTAssertFalse(value.contains("#\"\"\""))
            XCTAssertFalse(value.contains("\"\"\"#"))
            XCTAssertFalse(value.contains("\\#("))
        }
    }

    // MARK: - install

    /// Exercises the real install path against an injected destination. The
    /// global `~/.copilot` location is only ever read as a *path string* here —
    /// nothing in this suite writes to the user's Copilot CLI installation.
    func testInstallWritesThePackagedScriptToAnInjectedDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("tracker", isDirectory: true)

        XCTAssertFalse(CopilotExtension.upToDate(in: destination))
        let message = try CopilotExtension.install(in: destination)
        XCTAssertTrue(message.contains(destination.path))

        let written = try Data(contentsOf: CopilotExtension.scriptURL(in: destination))
        XCTAssertEqual(
            written,
            Data(CopilotExtension.script.utf8),
            "the installed file must be the packaged resource byte for byte"
        )
        XCTAssertTrue(CopilotExtension.upToDate(in: destination))
    }

    /// The tracker ships as one top-level entry point precisely so installing is
    /// a single atomic file write: a directory swap would race a live session
    /// and discard anything else the user keeps alongside it.
    func testInstallReplacesOnlyItsOwnFileAndIsIdempotent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let destination = root.appendingPathComponent("tracker", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let userFile = destination.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: userFile)
        let stale = CopilotExtension.scriptURL(in: destination)
        try Data("// stale build\n".utf8).write(to: stale)
        XCTAssertFalse(CopilotExtension.upToDate(in: destination))

        try CopilotExtension.install(in: destination)
        try CopilotExtension.install(in: destination)

        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "keep me")
        XCTAssertEqual(
            try Data(contentsOf: stale),
            Data(CopilotExtension.script.utf8),
            "a stale script is overwritten in place"
        )
        XCTAssertEqual(
            Set(try fileManager.contentsOfDirectory(atPath: destination.path)),
            ["extension.mjs", "notes.txt"],
            "installing must not add or remove anything else in the directory"
        )
    }

    /// The default destination is unchanged by the injected-destination seam.
    func testGlobalInstallPathsAreUnchanged() {
        XCTAssertEqual(CopilotExtension.extensionDir.lastPathComponent, "copilot-projects-tracker")
        XCTAssertEqual(
            CopilotExtension.extensionDir.deletingLastPathComponent().path,
            CopilotExtension.extensionsDir.path
        )
        XCTAssertTrue(CopilotExtension.extensionsDir.path.hasSuffix(".copilot/extensions"))
        XCTAssertEqual(CopilotExtension.scriptURL.lastPathComponent, "extension.mjs")
        XCTAssertEqual(
            CopilotExtension.scriptURL.path,
            CopilotExtension.scriptURL(in: CopilotExtension.extensionDir).path
        )
    }

    // MARK: - resolution

    /// `PackagedResource` resolves from packaging-relative locations only.
    /// Loading while the process sits in an unrelated directory proves there is
    /// no current-directory probe behind the facade.
    func testAssetsResolveIndependentlyOfTheCurrentDirectory() throws {
        let fileManager = FileManager.default
        let original = fileManager.currentDirectoryPath
        defer { fileManager.changeCurrentDirectoryPath(original) }
        XCTAssertTrue(fileManager.changeCurrentDirectoryPath("/"))

        XCTAssertFalse(CopilotExtension.script.isEmpty)
        XCTAssertFalse(RemoteWebAssets.javascript.isEmpty)

        let bundle = try XCTUnwrap(
            PackagedResource.locate(
                named: "copilot-projects_CopilotProjectsCore",
                anchor: Bundle(for: PackagedAssetTests.self)
            ),
            "the Core resource bundle must be discoverable beside the test bundle"
        )
        XCTAssertEqual(URL(fileURLWithPath: bundle.bundlePath).pathExtension, "bundle")
        XCTAssertEqual(
            PackagedResource.text(
                "extension",
                extension: "mjs",
                subdirectory: "tracker",
                in: bundle
            ),
            CopilotExtension.script,
            "a fresh load must produce the same bytes the cached facade serves"
        )
    }
}
