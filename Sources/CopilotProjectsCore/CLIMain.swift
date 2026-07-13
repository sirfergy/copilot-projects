import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Command-line front end. When the `copilot-projects` binary is invoked with a known
/// subcommand it acts as a thin client to the running app's control socket.
public enum CLIMain {
    /// Subcommands that should be handled by the CLI (vs. launching the GUI).
    public static let commands: Set<String> = [
        "set-status", "status",
        "notify",
        "list-projects", "projects",
        "list-status", "ls",
        "new-project",
        "new-session",
        "rename-project",
        "focus",
        "attach",
        "ping",
        "screenshot",
        "remote",
        "doctor",
        "version", "--version", "-v",
        "install-cli",
        "install-hooks", "uninstall-hooks",
        "help", "--help", "-h",
    ]

    public static func isCommand(_ s: String) -> Bool {
        commands.contains(s)
    }

    public static func isCocoaLaunchArguments(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("-psn_") {
                index += 1
                continue
            }
            if argument.hasPrefix("-NS") || argument.hasPrefix("-Apple") {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }
            return false
        }
        return true
    }

    public static func run(
        _ args: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int32 {
        guard let raw = args.first else {
            printUsage()
            return 1
        }
        let command = canonical(raw)
        let rest = Array(args.dropFirst())

        switch command {
        case "version":
            print(versionString)
            return 0
        case "doctor":
            return doctor()
        case "help":
            printUsage()
            return 0
        case "install-cli":
            return installCLI(rest)
        case "install-hooks":
            do {
                print(try CopilotHooks.install())
                print(try CopilotExtension.install())
                return 0
            } catch {
                fail("\(error)")
                return 1
            }
        case "uninstall-hooks":
            CopilotHooks.uninstall()
            CopilotExtension.uninstall()
            print("Removed copilot-projects Copilot CLI hooks and extension.")
            return 0
        case "attach":
            return attachSession(rest)
        default:
            break
        }

        let parsed = parseFlags(rest)
        var req = ControlRequest(command: command)
        // Only an explicit --project sets the target project. The implicit project is
        // derived server-side from the session id: COPILOT_PROJECTS_PROJECT goes stale
        // when a tab is dragged to another project, but the session id never does.
        req.projectId = parsed.flags["project"]
        req.sessionId = parsed.flags["session"] ?? Env.sessionId(environment)

        switch command {
        case "set-status":
            guard let status = parsed.flags["status"] ?? parsed.positionals.first else {
                fail("set-status requires a status: idle | running | waiting")
                return 1
            }
            req.status = status
            req.text = parsed.flags["text"]
            if let rawTimestamp = parsed.flags["timestamp"] {
                guard let timestamp = Int64(rawTimestamp) else {
                    fail("--timestamp must be an integer")
                    return 1
                }
                req.timestamp = timestamp
            }
            req.source = parsed.flags["source"]
            req.copilotSessionId = parsed.flags["copilot-session"]
            if let rawNotification = parsed.flags["notification"] {
                guard let notification = StatusNotificationKind(rawValue: rawNotification) else {
                    fail("--notification must be elicitation, permission, or completed")
                    return 1
                }
                req.notification = notification
            }
        case "notify":
            req.title = parsed.flags["title"] ?? parsed.positionals.first
            req.body = parsed.flags["body"]
                ?? (parsed.positionals.count > 1 ? parsed.positionals[1] : nil)
            if req.title == nil {
                fail("notify requires a title")
                return 1
            }
        case "new-project":
            req.name = parsed.flags["name"] ?? parsed.positionals.first
            req.cwd = parsed.flags["cwd"]
        case "new-session":
            req.cwd = parsed.flags["cwd"]
        case "rename-project":
            req.name = parsed.flags["name"] ?? parsed.positionals.first
            if req.name == nil {
                fail("rename-project requires a name")
                return 1
            }
        case "screenshot":
            var p = parsed.flags["path"] ?? parsed.positionals.first ?? "copilot-projects.png"
            if !p.hasPrefix("/") { p = FileManager.default.currentDirectoryPath + "/" + p }
            req.path = p
        case "remote":
            req.action = parsed.positionals.first ?? "status"
        case "focus", "list-projects", "list-status", "ping":
            break
        default:
            fail("unknown command: \(command)")
            return 1
        }

        do {
            let socketPath = Env.socket(environment) ?? Paths.socketPath
            let resp = try ControlClient(socketPath: socketPath).send(req)
            if let text = resp.text, !text.isEmpty {
                print(text)
            }
            if !resp.ok {
                fail(resp.error ?? "unknown error")
                return 1
            }
            return 0
        } catch {
            fail("\(error)")
            return 1
        }
    }

    // MARK: - aliases

    private static func canonical(_ command: String) -> String {
        switch command {
        case "status": return "set-status"
        case "projects": return "list-projects"
        case "ls": return "list-status"
        case "--help", "-h": return "help"
        case "--version", "-v": return "version"
        default: return command
        }
    }

    public static var versionNumber: String {
        let direct = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let appURL = executable
            .deletingLastPathComponent()   // executable -> MacOS
            .deletingLastPathComponent()   // MacOS -> Contents
            .deletingLastPathComponent()   // Contents -> app bundle
        let enclosing = Bundle(url: appURL)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return direct ?? enclosing ?? "development"
    }

    public static var versionString: String {
        "Copilot Projects \(versionNumber)"
    }

    // MARK: - diagnostics

    private static func doctor() -> Int32 {
        let fm = FileManager.default
        let snapshot = ProcessTree.snapshot()
        let stateSessionsPrefix = Paths.sessionsDir.path + "/"
        let dtach = ProcessTree.dtachProcesses(in: snapshot).filter {
            $0.socketPath?.hasPrefix(stateSessionsPrefix) == true
        }
        let stateSessionIds = persistedSessionIds()
        let socketFiles = ((try? fm.contentsOfDirectory(atPath: Paths.sessionsDir.path)) ?? [])
            .filter { $0.hasSuffix(".sock") }
        let masters = dtach.filter(\.isMaster)
        let clients = dtach.filter { !$0.isMaster }
        let liveMasterSockets = Set(masters.compactMap(\.socketPath))
        let orphanMasters = stateSessionIds.map { sessionIds in
            masters.filter { process in
                guard let socket = process.socketPath else { return true }
                return !sessionIds.contains(
                    URL(fileURLWithPath: socket).deletingPathExtension().lastPathComponent)
            }
        }
        let staleSockets = socketFiles.filter {
            !liveMasterSockets.contains(Paths.sessionsDir.appendingPathComponent($0).path)
        }

        print(versionString)
        print("state dir: \(Paths.stateDir.path)")
        print("state file: \(fm.fileExists(atPath: Paths.statePath.path) ? "present" : "missing")")
        print("sessions in state: \(stateSessionIds.map { String($0.count) } ?? "unreadable")")
        print("dtach masters: \(masters.count)")
        print("dtach attached clients: \(clients.count)")
        print("orphan masters (not in state): \(orphanMasters.map { String($0.count) } ?? "unknown")")
        print("stale socket files (no master): \(staleSockets.count)")
        let lock = instanceLockStatus()
        print("instance lock: \(lock.held ? "held" : "not held")"
            + (lock.pid.map { " (recorded pid \($0))" } ?? ""))
        if let response = try? ControlClient().send(ControlRequest(command: "diagnostics")),
           response.ok, let text = response.text {
            print(text)
        } else {
            print("app control socket: unavailable")
        }
        if let orphanMasters, !orphanMasters.isEmpty {
            print("warning: orphan master pids: \(orphanMasters.map { String($0.pid) }.joined(separator: ", "))")
        }
        if !staleSockets.isEmpty {
            print("warning: stale sockets: \(staleSockets.joined(separator: ", "))")
        }
        return 0
    }

    private static func persistedSessionIds() -> Set<String>? {
        guard FileManager.default.fileExists(atPath: Paths.statePath.path) else { return [] }
        guard let data = try? Data(contentsOf: Paths.statePath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [[String: Any]] else { return nil }
        return Set(projects.flatMap { project -> [String] in
            guard let sessions = project["sessions"] as? [[String: Any]] else { return [] }
            return sessions.compactMap { $0["id"] as? String }
        })
    }

    private static func instanceLockStatus() -> (pid: Int?, held: Bool) {
        let pid = (try? String(contentsOfFile: Paths.instanceLockPath, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let fd = open(Paths.instanceLockPath, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { return (pid, false) }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(fd, LOCK_UN)
            return (pid, false)
        }
        return (pid, errno == EWOULDBLOCK || errno == EAGAIN)
    }

    // MARK: - attach (resume a session, incl. over SSH)

    private static func attachSession(_ args: [String]) -> Int32 {
        guard let dtach = Paths.dtachExecutable else {
            fail("dtach helper not found (resumability backend missing)")
            return 1
        }

        let parsed = parseFlags(args)
        let fm = FileManager.default
        let dir = Paths.sessionsDir
        let socks = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".sock") }
        let env = ProcessInfo.processInfo.environment
        let wanted = parsed.positionals.first
            ?? parsed.flags["session"]
            ?? Env.sessionId(env)

        let socketPath: String
        if let wanted = wanted, !wanted.isEmpty {
            if socks.contains("\(wanted).sock") {
                socketPath = Paths.dtachSocketPath(sessionId: wanted)
            } else {
                let matches = socks.filter { $0.hasPrefix(wanted) }
                if matches.count == 1 {
                    socketPath = dir.appendingPathComponent(matches[0]).path
                } else if matches.isEmpty {
                    fail("no session matching “\(wanted)” (try: copilot-projects ls)")
                    return 1
                } else {
                    fail("ambiguous “\(wanted)” — matches \(matches.count) sessions")
                    return 1
                }
            }
        } else if socks.count == 1 {
            socketPath = dir.appendingPathComponent(socks[0]).path
        } else {
            fail("specify a session id (copilot-projects ls to list)")
            return 1
        }

        guard fm.fileExists(atPath: socketPath) else {
            fail("session socket not found: \(socketPath)")
            return 1
        }

        // Replace this process with a dtach attach client (no -E, so Ctrl-\
        // detaches when used over SSH).
        let argv = [dtach, "-a", socketPath, "-r", "winch"]
        var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        cargs.append(nil)
        execv(dtach, &cargs)
        fail("failed to launch dtach: \(String(cString: strerror(errno)))")
        return 1
    }

    // MARK: - flag parsing

    struct Parsed {
        var positionals: [String] = []
        var flags: [String: String] = [:]
    }

    static func parseFlags(_ args: [String]) -> Parsed {
        var out = Parsed()
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                out.positionals.append(contentsOf: args[(i + 1)...])
                break
            }
            if a.hasPrefix("--") {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    out.flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    out.flags[body] = args[i + 1]
                    i += 1
                } else {
                    out.flags[body] = ""   // boolean-ish flag
                }
            } else {
                out.positionals.append(a)
            }
            i += 1
        }
        return out
    }

    // MARK: - install-cli

    private static func installCLI(_ args: [String]) -> Int32 {
        let parsed = parseFlags(args)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = parsed.flags["dir"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".local/bin", isDirectory: true)
        guard let exe = currentExecutablePath() else {
            fail("could not resolve the running executable path")
            return 1
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let link = dir.appendingPathComponent("copilot-projects")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: exe)
            // Keep the old name working for shells/scripts created before the rename.
            let legacyLink = dir.appendingPathComponent("copilot-mux")
            try? fm.removeItem(at: legacyLink)
            try? fm.createSymbolicLink(atPath: legacyLink.path, withDestinationPath: exe)
            print("Linked \(link.path) -> \(exe)")
            let pathEnv = ProcessInfo.processInfo.environment["PATH"] ?? ""
            if !pathEnv.split(separator: ":").contains(Substring(dir.path)) {
                print("note: \(dir.path) is not on your PATH; add it to use `copilot-projects`.")
            }
            return 0
        } catch {
            fail("\(error)")
            return 1
        }
    }

    private static func currentExecutablePath() -> String? {
        if let p = Bundle.main.executablePath { return p }
        let arg0 = CommandLine.arguments.first ?? ""
        if arg0.hasPrefix("/") { return arg0 }
        return nil
    }

    // MARK: - output

    private static func fail(_ message: String) {
        FileHandle.standardError.write(Data("copilot-projects: \(message)\n".utf8))
    }

    private static func printUsage() {
        let usage = """
        copilot-projects — project-organized terminal sessions

        Usage:
          copilot-projects                         Launch the app
          copilot-projects set-status <state>      Set status of the current session
                                              state: idle | running | waiting
              [--text "..."] [--timestamp MS] [--source NAME]
              [--notification elicitation|permission|completed] [--session ID] [--project ID]
          copilot-projects notify <title> [body]   Post a macOS notification
              [--title T] [--body B] [--session ID] [--project ID]
          copilot-projects list-projects           List projects and their status
          copilot-projects list-status (ls)        List per-session status + ids
          copilot-projects attach [session]        Attach/resume a session (also works over SSH)
          copilot-projects new-project [name]      Create a project [--cwd DIR]
          copilot-projects new-session             Add a session to a project [--cwd DIR] [--project ID]
          copilot-projects rename-project <name>   Rename a project [--project ID]
          copilot-projects focus                   Focus a project/session [--project ID] [--session ID]
          copilot-projects ping                    Check the app is reachable
          copilot-projects screenshot [path]       Save a PNG of the app window
          copilot-projects remote [action]         Remote access: enable | disable | status (default)
          copilot-projects doctor                  Diagnose app/session/runtime state
          copilot-projects version                 Print the installed version
          copilot-projects install-cli [--dir D]   Symlink this binary onto your PATH
          copilot-projects install-hooks           Install Copilot CLI status hooks (~/.copilot/hooks)
          copilot-projects uninstall-hooks         Remove the Copilot CLI status hooks
          copilot-projects help                    Show this help

        Inside a copilot-projects terminal, COPILOT_PROJECTS_PROJECT / COPILOT_PROJECTS_SESSION are set,
        so set-status / notify target the current session automatically.
        """
        print(usage)
    }
}
