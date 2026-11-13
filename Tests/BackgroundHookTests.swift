import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class BackgroundHookTests: XCTestCase {
    final class Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let tabId = UUID().uuidString
        let ownerId = UUID().uuidString.lowercased()
        let childId = UUID().uuidString.lowercased()

        var sessions: URL { root.appendingPathComponent("sessions") }
        var capture: URL { root.appendingPathComponent("calls.txt") }
        var hook: URL { root.appendingPathComponent("hook.sh") }

        init() throws {
            let fm = FileManager.default
            for directory in ["sessions", "bin", ".local/bin", "tmp"] {
                try fm.createDirectory(
                    at: root.appendingPathComponent(directory),
                    withIntermediateDirectories: true)
            }
            try CopilotHooks.script.write(to: hook, atomically: true, encoding: .utf8)
            try executable(".local/bin/copilot-projects", """
            #!/bin/sh
            [ "$1" = "resolve-session" ] || exit 1
            printf '%s\\n' "$COPILOT_PROJECTS_SESSION"
            """)
            try executable("bin/copilot-projects", """
            #!/bin/sh
            printf '%s\\n' "$*" >> "$CAPTURE_FILE"
            """)
            try Data().write(to: capture)
            try ownerId.write(
                to: file("copilot-session"), atomically: true, encoding: .utf8)
        }

        func file(_ suffix: String) -> URL {
            sessions.appendingPathComponent("\(tabId).\(suffix)")
        }

        func executable(_ name: String, _ contents: String) throws {
            let url = root.appendingPathComponent(name)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func run(_ action: String, payload: String) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [hook.path, action]
            process.environment = [
                "HOME": root.path,
                "CFFIXED_USER_HOME": root.path,
                "TMPDIR": root.appendingPathComponent("tmp").path,
                "PATH": "\(root.appendingPathComponent("bin").path):/usr/bin:/bin",
                "COPILOT_PROJECTS_SESSION": tabId,
                "COPILOT_PROJECTS_SOCKET": root.appendingPathComponent("control.sock").path,
                "CAPTURE_FILE": capture.path,
            ]
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            XCTAssertEqual(
                String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "{}\n")
            XCTAssertEqual(
                String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                "")
        }

        func markerContents() throws -> [String: Data] {
            let files = try FileManager.default.contentsOfDirectory(
                at: sessions, includingPropertiesForKeys: nil)
            return try Dictionary(uniqueKeysWithValues: files.map {
                ($0.lastPathComponent, try Data(contentsOf: $0))
            })
        }
    }

    /// What the hook told the app, one `copilot-projects` call per line.
    private func calls(_ fixture: Fixture) throws -> [String] {
        try String(contentsOf: fixture.capture, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    private func ownerRecord(
        _ fixture: Fixture, appSessionId: String? = nil, tracker: Process, bootTime: String,
        parentPid: Int32
    ) throws {
        let json = """
        {"appSessionId":"\(appSessionId ?? fixture.tabId)","copilotSessionId":"\(fixture.ownerId)",\
        "pid":\(tracker.processIdentifier),"bootTime":"\(bootTime)","parentPid":\(parentPid),"claimedAt":100}
        """
        try Data(json.utf8).write(to: fixture.file("transcript-owner.json"))
    }

    func testOnlyTheOwnersSessionEndReachesTheApp() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try fixture.markerContents()
        let owner = #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#

        // A Copilot session started before this script was installed still calls it
        // for every event it registered then.
        for action in ["start", "running", "pre", "post", "notify", "idle"] {
            try fixture.run(action, payload: owner)
        }
        // A child's exit is not the tab's.
        try fixture.run("end", payload: #"{"sessionId":"\#(fixture.childId)","timestamp":101}"#)
        XCTAssertEqual(try calls(fixture), [])

        try fixture.run("end", payload: owner)
        XCTAssertEqual(
            try calls(fixture),
            ["session-ended --session \(fixture.tabId) --copilot-session \(fixture.ownerId)"])
        // An exit that names no Copilot session carries none, and the app clears nothing for it.
        try fixture.run("end", payload: "{}")
        XCTAssertEqual(try calls(fixture).last, "session-ended --session \(fixture.tabId)")
        XCTAssertEqual(try fixture.markerContents(), before, "the hook writes no session file")
    }

    private func spawnSleepProcess() throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    private func currentKernelBootTime() throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sysctl")
        process.arguments = ["-n", "kern.boottime"]
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testOtherLiveOwnerProcessBlocksANestedSessionEnd() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerCLI = try spawnSleepProcess()
        let ownerTracker = try spawnSleepProcess()
        defer {
            ownerCLI.terminate()
            ownerTracker.terminate()
        }
        // kern.boottime's usec moves within one boot, so the owner's reading can
        // differ from the hook's.
        let bootTime = try currentKernelBootTime().replacingOccurrences(
            of: #"usec = \d+"#, with: "usec = 1", options: .regularExpression
        )
        try ownerRecord(
            fixture, tracker: ownerTracker, bootTime: bootTime,
            parentPid: ownerCLI.processIdentifier)
        // A nested Copilot that reports the owner's own session id.
        let nested = #"{"sessionId":"\#(fixture.ownerId)","timestamp":200}"#

        try fixture.run("end", payload: nested)
        XCTAssertEqual(try calls(fixture), [])

        // The tracker PID has exited or restarted while `parentPid` is alive on the same boot.
        ownerTracker.terminate()
        ownerTracker.waitUntilExit()
        try fixture.run("end", payload: nested)
        XCTAssertEqual(try calls(fixture), [], "dead tracker")

        // A nested non-wrapper process (`xctest`, standing in for `exec copilot -p`)
        // that is a direct child of `parentPid` is still blocked.
        let parentOfThisProcess = getppid()
        if parentOfThisProcess > 1 && Darwin.kill(parentOfThisProcess, 0) == 0 {
            try ownerRecord(
                fixture, tracker: ownerTracker, bootTime: bootTime, parentPid: parentOfThisProcess)
            try fixture.run("end", payload: nested)
            XCTAssertEqual(try calls(fixture), [], "direct child")
        }
    }

    func testRecordedOwnerProcessSendsADirectOrWrappedSessionEnd() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerTracker = try spawnSleepProcess()
        defer { ownerTracker.terminate() }
        try ownerRecord(
            fixture, tracker: ownerTracker, bootTime: try currentKernelBootTime(),
            parentPid: ProcessInfo.processInfo.processIdentifier)
        let owner = #"{"sessionId":"\#(fixture.ownerId)","timestamp":100}"#
        let sent = "session-ended --session \(fixture.tabId) --copilot-session \(fixture.ownerId)"

        try fixture.run("end", payload: owner)
        XCTAssertEqual(try calls(fixture), [sent])

        // Wrap through `/bin/sh -c` (with `&& :` so `/bin/sh` cannot `exec` the child)
        // to exercise the shell-wrapper ancestor walk.
        let wrapped = Process()
        wrapped.executableURL = URL(fileURLWithPath: "/bin/sh")
        wrapped.arguments = ["-c", "/bin/bash \"\(fixture.hook.path)\" end && :"]
        wrapped.environment = [
            "HOME": fixture.root.path,
            "CFFIXED_USER_HOME": fixture.root.path,
            "TMPDIR": fixture.root.appendingPathComponent("tmp").path,
            "PATH": "\(fixture.root.appendingPathComponent("bin").path):/usr/bin:/bin",
            "COPILOT_PROJECTS_SESSION": fixture.tabId,
            "COPILOT_PROJECTS_SOCKET": fixture.root.appendingPathComponent("control.sock").path,
            "CAPTURE_FILE": fixture.capture.path,
        ]
        let input = Pipe()
        wrapped.standardInput = input
        wrapped.standardOutput = Pipe()
        wrapped.standardError = Pipe()
        try wrapped.run()
        input.fileHandleForWriting.write(Data(owner.utf8))
        try input.fileHandleForWriting.close()
        wrapped.waitUntilExit()
        XCTAssertEqual(wrapped.terminationStatus, 0)
        XCTAssertEqual(try calls(fixture), [sent, sent])
    }

    func testDeadOrStaleBootOwnerProcessDoesNotBlockSessionEnd() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ownerCLI = try spawnSleepProcess()
        let ownerTracker = try spawnSleepProcess()
        defer {
            ownerCLI.terminate()
            ownerTracker.terminate()
        }
        let owner = #"{"sessionId":"\#(fixture.ownerId)","timestamp":200}"#

        // Mismatched bootTime is treated as a stale owner from a previous boot.
        try ownerRecord(
            fixture, tracker: ownerTracker, bootTime: "{ sec = 1, usec = 0 }",
            parentPid: ownerCLI.processIdentifier)
        try fixture.run("end", payload: owner)
        XCTAssertEqual(try calls(fixture).count, 1)

        // Mismatched appSessionId is treated as a foreign owner record and does not block.
        let bootTime = try currentKernelBootTime()
        try ownerRecord(
            fixture, appSessionId: UUID().uuidString, tracker: ownerTracker, bootTime: bootTime,
            parentPid: ownerCLI.processIdentifier)
        try fixture.run("end", payload: owner)
        XCTAssertEqual(try calls(fixture).count, 2)

        // Dead owner PIDs also fall back to allowing hooks.
        ownerCLI.terminate()
        ownerCLI.waitUntilExit()
        try ownerRecord(
            fixture, tracker: ownerTracker, bootTime: bootTime,
            parentPid: ownerCLI.processIdentifier)
        try fixture.run("end", payload: owner)
        XCTAssertEqual(try calls(fixture).count, 3)
    }
}
