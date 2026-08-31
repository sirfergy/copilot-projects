import XCTest
import Darwin
@testable import CopilotProjectsCore

final class CLILauncherTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default
    private let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    override func setUpWithError() throws {
        root = project.appendingPathComponent(".build/launcher-tests/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try fm.removeItem(at: root)
    }

    func testInstallerCanonicalizesSymlinkChains() throws {
        let executable = try makeExecutable("app/real")
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        try fm.createSymbolicLink(atPath: first.path, withDestinationPath: "app/real")
        try fm.createSymbolicLink(atPath: second.path, withDestinationPath: "first")
        let directory = root.appendingPathComponent("bin")

        try CLILauncher.install(executable: second, in: directory)

        let link = directory.appendingPathComponent("copilot-projects")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), executable.path)
        XCTAssertEqual(RunningExecutable.canonicalURL(for: link.path), executable)
        XCTAssertTrue(fm.isExecutableFile(atPath: executable.path))
    }

    func testRepeatedSelfInstallLeavesCorrectLauncherUntouched() throws {
        let executable = try makeExecutable("app/real")
        let directory = root.appendingPathComponent("bin")
        let link = directory.appendingPathComponent("copilot-projects")
        try CLILauncher.install(executable: executable, in: directory)
        let original = try identity(link)

        for _ in 0..<3 {
            try CLILauncher.install(executable: link, in: directory)
            XCTAssertEqual(try identity(link), original)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), executable.path)
        }
    }

    func testAlreadyCorrectRelativeSymlinkIsPreserved() throws {
        let executable = try makeExecutable("app/real")
        let directory = root.appendingPathComponent("bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("copilot-projects")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../app/real")
        let original = try identity(link)

        try CLILauncher.install(executable: executable, in: directory)

        XCTAssertEqual(try identity(link), original)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "../app/real")
    }

    func testRealExecutableDestinationIsANoOpEvenThroughDirectoryAlias() throws {
        let executable = try makeExecutable("bin/copilot-projects")
        let original = try identity(executable)
        let originalData = try Data(contentsOf: executable)
        let alias = root.appendingPathComponent("alias")
        try fm.createSymbolicLink(atPath: alias.path, withDestinationPath: "bin")

        for directory in [executable.deletingLastPathComponent(), alias] {
            try CLILauncher.install(executable: executable, in: directory)
            XCTAssertEqual(try identity(executable), original)
            XCTAssertEqual(try Data(contentsOf: executable), originalData)
        }
    }

    func testWrongBrokenAndLoopingSymlinksAreReplacedWithoutTouchingTargets() throws {
        let executable = try makeExecutable("app/real")
        let other = try makeExecutable("other")
        let otherData = try Data(contentsOf: other)
        for (name, target) in [("wrong", other.path), ("broken", "missing"), ("loop", "copilot-projects")] {
            let directory = root.appendingPathComponent(name)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let link = directory.appendingPathComponent("copilot-projects")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)

            try CLILauncher.install(executable: executable, in: directory)

            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), executable.path)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["copilot-projects"])
        }
        XCTAssertEqual(try Data(contentsOf: other), otherData)
    }

    func testNonSymlinkFilesAndDirectoriesArePreserved() throws {
        let executable = try makeExecutable("app/real")
        let customScript = try makeExecutable("script/copilot-projects")
        let directory = root.appendingPathComponent("directory/copilot-projects")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("keep me".utf8).write(to: notes)
        let scriptData = try Data(contentsOf: customScript)

        for destination in [customScript, directory] {
            let original = try identity(destination)
            XCTAssertThrowsError(try CLILauncher.install(
                executable: executable, in: destination.deletingLastPathComponent()
            )) { error in
                XCTAssertTrue(String(describing: error).contains("refusing to replace non-symlink"))
                XCTAssertTrue(String(describing: error).contains(destination.path))
                XCTAssertTrue(String(describing: error).contains("--dir"))
            }
            XCTAssertEqual(try identity(destination), original)
            XCTAssertEqual(
                try fm.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path),
                ["copilot-projects"]
            )
        }
        XCTAssertEqual(try Data(contentsOf: customScript), scriptData)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "keep me")
    }

    func testConcurrentFirstInstallAcceptsAnAlreadyCorrectDestination() throws {
        let executable = try makeExecutable("app/real")
        for kind in ["symlink", "hardlink"] {
            let directory = root.appendingPathComponent(kind)
            let destination = directory.appendingPathComponent("copilot-projects")
            var concurrentIdentity: String?
            let message = try CLILauncher.install(executable: executable, in: directory) { staged, path, flags in
                XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                if kind == "symlink" {
                    try self.fm.createSymbolicLink(atPath: path, withDestinationPath: executable.path)
                } else {
                    try self.fm.linkItem(at: executable, to: destination)
                }
                concurrentIdentity = try self.identity(destination)
                return renamex_np(staged, path, flags)
            }
            XCTAssertTrue(message.contains("CLI already available"))
            XCTAssertEqual(try identity(destination), concurrentIdentity)
            XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: executable))
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["copilot-projects"])
        }
    }

    func testConcurrentFirstInstallRefusesAnUnexpectedDestination() throws {
        let executable = try makeExecutable("app/real")
        for kind in ["file", "directory", "wrong-symlink"] {
            let directory = root.appendingPathComponent(kind)
            let destination = directory.appendingPathComponent("copilot-projects")
            var concurrentIdentity: String?
            XCTAssertThrowsError(try CLILauncher.install(executable: executable, in: directory) { staged, path, flags in
                XCTAssertEqual(flags, UInt32(RENAME_EXCL))
                switch kind {
                case "file":
                    try Data("user data".utf8).write(to: destination)
                case "directory":
                    try self.fm.createDirectory(at: destination, withIntermediateDirectories: false)
                default:
                    try self.fm.createSymbolicLink(atPath: path, withDestinationPath: "missing")
                }
                concurrentIdentity = try self.identity(destination)
                return renamex_np(staged, path, flags)
            }) { error in
                XCTAssertTrue(String(describing: error).contains("destination changed during installation"))
            }
            XCTAssertEqual(try identity(destination), concurrentIdentity)
            if kind == "file" {
                XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "user data")
            }
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["copilot-projects"])
        }
    }

    func testUnresolvableExecutableDoesNotCreateADestination() throws {
        let source = root.appendingPathComponent("source")
        try fm.createSymbolicLink(atPath: source.path, withDestinationPath: "missing")
        let directory = root.appendingPathComponent("bin")

        XCTAssertThrowsError(try CLILauncher.install(executable: source, in: directory))
        XCTAssertFalse(fm.fileExists(atPath: directory.path))
    }

    func testExecutableResolutionRequiresAnAbsoluteRuntimePath() throws {
        let executable = try makeExecutable("copilot-projects")
        XCTAssertNil(RunningExecutable.canonicalURL(for: "copilot-projects"))
        XCTAssertNil(RunningExecutable.canonicalURL(for: "./copilot-projects"))
        XCTAssertEqual(RunningExecutable.canonicalURL(for: executable.path), executable)
        let running = try XCTUnwrap(RunningExecutable.url)
        XCTAssertTrue(running.path.hasPrefix("/"))
        XCTAssertEqual(running, RunningExecutable.canonicalURL(for: running.path))
    }

    func testApplicationBundleRequiresTheMacOSContentsLayout() {
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        XCTAssertEqual(
            RunningExecutable.applicationBundleURL(for: app.appendingPathComponent("Contents/MacOS/tool")),
            app
        )
        XCTAssertNil(RunningExecutable.applicationBundleURL(for: root.appendingPathComponent("bin/tool")))
        XCTAssertNil(RunningExecutable.applicationBundleURL(for: app.appendingPathComponent("Other/MacOS/tool")))
    }

    func testPackagedCommandsAndSelfInstallViaAbsoluteRelativeAndPATHLaunchers() throws {
        let executable = try makeAppFixture()
        let directory = root.appendingPathComponent("bin")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let chain = directory.appendingPathComponent("chain")
        let link = directory.appendingPathComponent("copilot-projects")
        try fm.createSymbolicLink(atPath: chain.path, withDestinationPath: executable.path)
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "chain")
        let originalLink = try identity(link)
        let originalExecutable = try identity(executable)
        let originalData = try Data(contentsOf: executable)
        let cwd = root.appendingPathComponent("unrelated")
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        _ = try makeExecutable("unrelated/copilot-projects", contents: "#!/bin/sh\nexit 88\n")
        let environment = ["PATH": directory.path + ":/usr/bin:/bin"]
        let sessions = root.appendingPathComponent("state/sessions")
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data().write(to: sessions.appendingPathComponent("fixture.sock"))
        let helper = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Helpers/dtach")

        for invocation in [executable.path, link.path, "../bin/copilot-projects", "copilot-projects"] {
            let version = try run(invocation, ["version"], cwd: cwd, environment: environment)
            XCTAssertEqual(version.status, 0, version.output)
            XCTAssertEqual(version.output.trimmingCharacters(in: .whitespacesAndNewlines), "Copilot Projects 9.8.7")
            let assets = try run(invocation, ["check-assets"], cwd: cwd, environment: environment)
            XCTAssertEqual(assets.status, 0, assets.output)
            XCTAssertTrue(assets.output.contains("Packaged assets available"))
            let attach = try run(invocation, ["attach", "fixture"], cwd: cwd, environment: environment)
            XCTAssertEqual(attach.status, 0, attach.output)
            XCTAssertEqual(attach.output.trimmingCharacters(in: .whitespacesAndNewlines), "fixture dtach: \(helper.path)")
            let install = try run(invocation, ["install-cli", "--dir", directory.path], cwd: cwd, environment: environment)
            XCTAssertEqual(install.status, 0, install.output)
            XCTAssertEqual(try identity(link), originalLink)
            XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), "chain")
        }
        let realDestination = try run(link.path, ["install-cli", "--dir", executable.deletingLastPathComponent().path])
        XCTAssertEqual(realDestination.status, 0, realDestination.output)
        XCTAssertEqual(try identity(executable), originalExecutable)
        XCTAssertEqual(try Data(contentsOf: executable), originalData)
        let newDirectory = root.appendingPathComponent("new-bin")
        let newInstall = try run("copilot-projects", ["install-cli", "--dir", newDirectory.path], cwd: cwd, environment: environment)
        XCTAssertEqual(newInstall.status, 0, newInstall.output)
        XCTAssertEqual(
            try fm.destinationOfSymbolicLink(atPath: newDirectory.appendingPathComponent("copilot-projects").path),
            executable.path
        )
        try fm.removeItem(at: helper)
        _ = try makeExecutable("bin/Contents/Helpers/dtach", contents: "#!/bin/sh\nexit 88\n")
        let missingHelper = try run("copilot-projects", ["attach", "fixture"], cwd: cwd, environment: environment)
        XCTAssertEqual(missingHelper.status, 1, missingHelper.output)
        XCTAssertTrue(missingHelper.output.contains("dtach helper not found"))
    }

    func testPackagedAssetsDoNotFallBackToBuildResourcesThroughALauncher() throws {
        let executable = try makeAppFixture()
        let link = root.appendingPathComponent("copilot-projects")
        try fm.createSymbolicLink(atPath: link.path, withDestinationPath: executable.path)
        let resources = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let packagedCore = resources.appendingPathComponent("copilot-projects_CopilotProjectsCore.bundle")
        let decoyCore = root.appendingPathComponent("copilot-projects_CopilotProjectsCore.bundle")
        try fm.moveItem(at: packagedCore, to: decoyCore)

        for invocation in [executable.path, link.path, "copilot-projects"] {
            let result = try run(invocation, ["check-assets"], environment: ["PATH": root.path + ":/usr/bin:/bin"])
            XCTAssertEqual(result.status, 1, result.output)
        }
        try fm.moveItem(at: decoyCore, to: packagedCore)
        let decoyResources = root.appendingPathComponent("Resources")
        try fm.createDirectory(at: decoyResources, withIntermediateDirectories: true)
        try fm.moveItem(
            at: resources.appendingPathComponent("PWAIcon-192.png"),
            to: decoyResources.appendingPathComponent("PWAIcon-192.png")
        )
        for invocation in [executable.path, link.path, "copilot-projects"] {
            let result = try run(invocation, ["check-assets"], environment: ["PATH": root.path + ":/usr/bin:/bin"])
            XCTAssertEqual(result.status, 1, result.output)
        }
    }

    func testCLIReportsRefusalWithoutReplacingUserData() throws {
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("copilot-projects")
        let script = try makeExecutable("script/copilot-projects")
        let original = try identity(script)
        let result = try run(executable.path, ["install-cli", "--dir", script.deletingLastPathComponent().path])
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("refusing to replace non-symlink at \(script.path)"))
        XCTAssertTrue(result.output.contains("--dir"))
        XCTAssertEqual(try identity(script), original)
    }

    private func makeExecutable(_ path: String, contents: String = "#!/bin/sh\nexit 0\n") throws -> URL {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func identity(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return "\(info.st_dev):\(info.st_ino):\(info.st_mode)"
    }

    private func makeAppFixture() throws -> URL {
        let build = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let app = root.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let executable = macOS.appendingPathComponent("copilot-projects")
        try fm.copyItem(at: build.appendingPathComponent("copilot-projects"), to: executable)
        for name in ["copilot-projects_CopilotProjectsCore.bundle", "copilot-projects_copilot-projects.bundle"] {
            try fm.copyItem(at: build.appendingPathComponent(name), to: resources.appendingPathComponent(name))
        }
        for size in [192, 512] {
            let name = "PWAIcon-\(size).png"
            try fm.copyItem(at: project.appendingPathComponent("Resources/\(name)"), to: resources.appendingPathComponent(name))
        }
        let info = [
            "CFBundleExecutable": "copilot-projects",
            "CFBundleIdentifier": "com.example.copilot-projects.launcher-test",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "9.8.7",
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let helper = try makeExecutable(
            "Fixture.app/Contents/Helpers/dtach",
            contents: "#!/bin/sh\nprintf 'fixture dtach: %s\\n' \"$0\"\n"
        )
        let signHelper = try run("/usr/bin/codesign", ["--force", "--sign", "-", helper.path])
        XCTAssertEqual(signHelper.status, 0, signHelper.output)
        let sign = try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        XCTAssertEqual(sign.status, 0, sign.output)
        return executable
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        // env preserves a bare argv[0] when exercising a PATH invocation.
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = cwd ?? root
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        env["HOME"] = root.path
        env["CFFIXED_USER_HOME"] = root.path
        env["TMPDIR"] = root.path
        env["COPILOT_PROJECTS_STATE_DIR"] = root.appendingPathComponent("state").path
        env["COPILOT_PROJECTS_SOCKET"] = root.appendingPathComponent("state/control.sock").path
        env["COPILOT_PROJECTS_NO_INSTALL"] = "1"
        env["COPILOT_PROJECTS_DTACH"] = ""
        process.environment = env
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationReason, .exit)
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
