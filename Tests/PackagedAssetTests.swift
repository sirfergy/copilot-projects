import XCTest
@testable import CopilotProjectsHost
import CopilotProjectsCore

extension CopilotExtension {
    /// The tracker's SDK import, which tests replace with a fake session.
    static let sdkImport =
        #"const { joinSession } = await import("@microsoft/copilot-sdk/extension").catch(() => import("@github/copilot-sdk/extension"));"#
}

/// The standalone tracker must load from packaged resources and install
/// byte-identical content without a developer-directory fallback.
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
        XCTAssertFalse(script.hasSuffix("\n"))
        XCTAssertFalse(script.contains("#\"\"\""))
        XCTAssertFalse(script.contains("\"\"\"#"))
        XCTAssertFalse(script.contains("\\#("))
        XCTAssertTrue(script.contains(CopilotExtension.sdkImport))
        XCTAssertEqual(CopilotExtension.scriptURL.lastPathComponent, "extension.mjs")
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

    func testTrackerLoadsIndependentlyOfTheCurrentDirectory() throws {
        let fileManager = FileManager.default
        let original = fileManager.currentDirectoryPath
        defer { fileManager.changeCurrentDirectoryPath(original) }
        XCTAssertTrue(fileManager.changeCurrentDirectoryPath("/"))
        let bundle = try XCTUnwrap(PackagedResource.locate(
            named: "copilot-projects_CopilotProjectsCore",
            anchor: Bundle(for: Self.self)
        ))
        XCTAssertEqual(
            PackagedResource.text("extension", extension: "mjs", subdirectory: "tracker", in: bundle),
            CopilotExtension.script
        )
    }
}
