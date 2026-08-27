import AppKit
import SwiftTerm
import CopilotProjectsCore

/// Owns a single SwiftTerm terminal + its child shell, and republishes the
/// process-delegate callbacks as plain closures. Deliberately NOT an
/// ObservableObject: the live NSView is kept out of the SwiftUI observation graph.
final class TerminalController: NSObject, LocalProcessTerminalViewDelegate {
    let sessionId: String
    let terminalView: ProjectsTerminalView

    /// PID of the shell this terminal is running (0 until spawned). Used for the
    /// process-liveness check.
    var shellPID: pid_t {
        terminalView.process?.shellPid ?? 0
    }

    var onTitle: ((String) -> Void)?
    var onDirectory: ((String?) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private(set) var exited = false
    private var isDrainingForTermination = false

    /// What the Copilot CLI's own footer says it's doing. While a turn runs the
    /// footer shows "… Working   esc cancel"; back at the prompt it shows
    /// "/ commands · ? help · tab next tab". This is a hook-independent backstop:
    /// a turn cancelled with Esc fires NO stop hook and leaves the agent process
    /// alive (so neither the stop hook nor the process-liveness check can clear the
    /// tab spinner), yet the footer still returns to its idle signature — and keeps
    /// updating even while the tab is backgrounded, because the CLI keeps rendering
    /// on focus-out.
    ///
    /// Only the bottom-most non-empty row is inspected: the CLI's footer is fixed
    /// chrome at the bottom of the screen, so streamed output never lands there — no
    /// risk of the agent's own text spoofing a signature. Deliberately does NOT gate
    /// on the alternate buffer: a session resumed via dtach renders its TUI in
    /// SwiftTerm's normal buffer (the CLI never re-emits 1049h on reattach), so an
    /// alt-buffer check would blind this to every resumed agent. The caller scopes
    /// this to live `running` agents, so a plain shell is never read.
    @MainActor var agentActivity: FooterActivity {
        guard !exited else { return .idle }
        guard let terminal = terminalView.terminal else { return .unknown }
        let rows = terminal.rows, cols = terminal.cols
        guard rows > 0, cols > 0 else { return .unknown }
        // Scan only the bottom band from the bottom up and return the lowest row that
        // reads as a real footer. The footer is the bottom-most chrome; bounding the
        // scan (rather than walking the whole screen) avoids matching an old idle
        // footer or the agent's own output higher up — while still tolerating a
        // resumed session's resized buffer, which can leave the footer a few rows up.
        for r in stride(from: rows - 1, through: max(0, rows - 8), by: -1) {
            var line = ""
            for c in 0 ..< cols {
                if let ch = terminal.getCharacter(col: c, row: r) { line.append(ch) }
            }
            let activity = Self.classifyFooter(line)
            if activity != .unknown {
                Self.debugLog("activity sid=\(sessionId.prefix(8)) alt=\(terminal.isCurrentBufferAlternate) row=\(r)/\(rows) -> \(activity)  [\(line.trimmingCharacters(in: .whitespaces).suffix(90))]")
                return activity
            }
        }
        Self.dumpLayoutOnce(sessionId: sessionId, terminal: terminal)
        return .unknown
    }

    /// One-shot diagnostic dump of the bottom rows when no footer was recognized.
    @MainActor static var dumpedSessions: Set<String> = []
    @MainActor static func dumpLayoutOnce(sessionId: String, terminal: Terminal) {
        guard FileManager.default.fileExists(atPath: "/tmp/copilot-projects-debug"),
              !dumpedSessions.contains(sessionId) else { return }
        dumpedSessions.insert(sessionId)
        let rows = terminal.rows, cols = terminal.cols
        debugLog("NO FOOTER sid=\(sessionId.prefix(8)) rows=\(rows) cols=\(cols); bottom non-empty rows:")
        for r in max(0, rows - 40) ..< rows {
            var line = ""
            for c in 0 ..< cols { if let ch = terminal.getCharacter(col: c, row: r) { line.append(ch) } }
            let trimmed = line.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                let safe = String(trimmed.unicodeScalars.map { $0.value < 32 ? "?" : Character($0) })
                debugLog("  r\(r)| \(safe.suffix(112))")
            }
        }
    }

    /// Classify copilot's footer line into coarse activity. Pure/static so it can be
    /// unit-tested against captured fixtures.
    nonisolated static func classifyFooter(_ footerLine: String) -> FooterActivity {
        let f = footerLine.lowercased()
        guard !f.trimmingCharacters(in: .whitespaces).isEmpty else { return .unknown }
        if f.contains("esc cancel") || f.contains("esc to cancel")
            || f.contains("esc interrupt") || f.contains("esc to interrupt")
            || f.contains("working") {
            return .working
        }
        if f.contains("tab next tab") || (f.contains("? help") && f.contains("/ commands")) {
            return .idle
        }
        return .unknown
    }

    /// Append a diagnostic line, but only while `/tmp/copilot-projects-debug` exists
    /// (touch it to enable, rm to disable — no relaunch needed). Off by default; the
    /// message is `@autoclosure` so nothing is built when disabled.
    nonisolated static func debugLog(_ s: @autoclosure () -> String) {
        guard FileManager.default.fileExists(atPath: "/tmp/copilot-projects-debug") else { return }
        let line = "[\(Date())] \(s())\n"
        let path = "/tmp/copilot-projects-debug.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); h.closeFile()
        } else {
            try? line.write(toFile: path, atomically: false, encoding: .utf8)
        }
    }

    init(sessionId: String, cwd: String, extraEnvironment: [String: String],
         dtachExecutable: String?, dtachSocket: String?, copilotSessionId: String? = nil,
         copilotSessionAllowAll: Bool = false, launchCopilotExecutable: String? = nil,
         launchCopilotInitialPrompt: String? = nil,
         kittyImageDiskStore: RemoteKittyImageDiskStore = .shared) {
        self.sessionId = sessionId
        self.terminalView = ProjectsTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        super.init()
        terminalView.processDelegate = self
        // Make links clickable on a plain click. `.hover` makes BOTH explicit OSC 8
        // hyperlinks AND implicitly-detected bare URLs (http(s)://…) clickable: on
        // mouseUp SwiftTerm sets the hover range to the link under the cursor, then
        // opens it. `.always` only opens explicit OSC 8 links — but the Copilot CLI
        // mostly prints full bare URLs (PR links, etc.) which are implicit, so
        // `.always` left those dead. (Mouse reporting is off, so clicks aren't
        // swallowed by the agent TUI.) AppDelegate's mouseUp handler briefly flips
        // this to `.hoverWithModifier` when a selection is active, so dragging to
        // select a URL doesn't open it.
        terminalView.linkHighlightMode = .hover
        // Don't report mouse events to the program: a mouse-reporting TUI (a live
        // agent) would otherwise swallow click-drags, so you couldn't select text,
        // and SwiftTerm would clear any selection on each new line of output. With
        // reporting off, a plain drag selects and the selection survives streaming
        // output. The scroll wheel is still forwarded to the agent separately (see
        // ProjectsTerminalView.forwardScroll), so scrolling keeps working.
        terminalView.allowMouseReporting = false
        // The active session's terminal becomes first responder, which draws a blue
        // focus ring around it (a line along the top + right edges). The selected tab
        // already shows which session is active, so suppress the ring.
        terminalView.focusRingType = .none
        // Wires durable Kitty-image persistence for this exact session and
        // kicks off its async disk restore *before* `start(...)` below can
        // possibly spawn the shell/dtach process — so no live PTY byte can
        // ever reach `dataReceived` before restoration begins buffering it
        // (see `ProjectsTerminalView.configureImagePersistence`).
        terminalView.configureImagePersistence(sessionId: sessionId, diskStore: kittyImageDiskStore)
        start(cwd: cwd, extraEnvironment: extraEnvironment,
              dtachExecutable: dtachExecutable, dtachSocket: dtachSocket,
              copilotSessionId: copilotSessionId,
              copilotSessionAllowAll: copilotSessionAllowAll,
              launchCopilotExecutable: launchCopilotExecutable,
              launchCopilotInitialPrompt: launchCopilotInitialPrompt)
    }

    private func start(cwd: String, extraEnvironment: [String: String],
                       dtachExecutable: String?, dtachSocket: String?,
                       copilotSessionId: String? = nil,
                       copilotSessionAllowAll: Bool = false,
                       launchCopilotExecutable: String? = nil,
                       launchCopilotInitialPrompt: String? = nil) {
        let processEnv = ProcessInfo.processInfo.environment
        let shell = processEnv["SHELL"] ?? "/bin/zsh"
        let shellName = (shell as NSString).lastPathComponent

        // The Copilot CLI tags its process tree with per-session/loader/supervisor
        // env vars. If this app was launched from a copilot session (e.g.
        // `copilot ... --resume` that ran `open`), they leak in and get inherited by
        // every terminal — so a `copilot` started in a session believes it's a
        // managed/supervised child: its `/restart` shuts down (COPILOT_SUPERVISED)
        // or defers to the launcher's (wrong, often gone) loader instead of
        // re-spawning. Strip them so each session's copilot owns its own lifecycle.
        var env = Self.sessionEnvironment(from: processEnv)
        for (key, value) in extraEnvironment { env[key] = value }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let resumeCopilotExecutable = launchCopilotExecutable ?? Paths.copilotExecutable

        let envArray = env.map { "\($0.key)=\($0.value)" }
        let dir = cwd.isEmpty ? Paths.defaultStartupDir : Paths.normalizedDirectory(cwd)

        if let dtach = dtachExecutable, let socket = dtachSocket {
            // Resumable: dtach owns the shell PTY and survives app quit.
            //   -A attach-or-create, -r winch redraw-on-attach,
            //   -z no suspend key, -E no detach key (fully raw → keyboard passthrough).
            // The program after -E only runs when dtach CREATES a fresh master. On
            // reattach (app quit→relaunch with the master still alive) it's ignored,
            // so a normal relaunch never re-runs it. After a reboot kills the master,
            // dtach -A recreates it and the program runs — so an agent tab with a
            // recorded Copilot session id auto-resumes THAT exact session, and a
            // freshly-created remote session launches Copilot once, then both drop to
            // a normal login shell when the agent exits.
            let program = Self.startupProgram(
                shell: shell,
                copilotSessionId: copilotSessionId,
                copilotSessionAllowAll: copilotSessionAllowAll,
                resumeCopilotExecutable: resumeCopilotExecutable,
                launchCopilotExecutable: launchCopilotExecutable,
                launchCopilotInitialPrompt: launchCopilotInitialPrompt
            )
            terminalView.startProcess(
                executable: dtach,
                args: ["-A", socket, "-r", "winch", "-z", "-E"] + program,
                environment: envArray,
                execName: nil,
                currentDirectory: dir
            )
        } else {
            // Fallback (no dtach helper): direct login shell, not resumable.
            terminalView.startProcess(
                executable: shell,
                args: [],
                environment: envArray,
                execName: "-\(shellName)",
                currentDirectory: dir
            )
        }

        // Mark this terminal's pty master close-on-exec so the NEXT session's dtach
        // (a posix_spawn/fork+exec) doesn't inherit it. SwiftTerm doesn't set this,
        // so without it every dtach accumulates a copy of every prior session's pty
        // master — a descriptor leak that grows with each session/relaunch and was
        // pinning ptys open. The app keeps using the fd; CLOEXEC only affects children.
        if let childfd = terminalView.process?.childfd, childfd >= 0 {
            _ = fcntl(childfd, F_SETFD, FD_CLOEXEC)
        }
    }

    func terminate() {
        MainActor.assumeIsolated {
            terminalView.kittyImageCapture.disablePersistence()
            terminalView.cancelImageRestore()
            terminalView.terminate()
        }
    }

    @MainActor
    func beginTerminationDrain() {
        isDrainingForTermination = true
        terminalView.flushImageRestoreBufferForTermination()
    }

    @MainActor
    func finishTerminationDrain() async {
        await waitForTerminalOutputToQuiesce(maxTicks: 50)
        terminalView.terminate()
        await waitForTerminalOutputToQuiesce(maxTicks: 10)
        terminalView.kittyImageCapture.disablePersistence()
        terminalView.cancelImageRestore()
        isDrainingForTermination = false
    }

    @MainActor
    private func waitForTerminalOutputToQuiesce(maxTicks: Int) async {
        var lastGeneration = terminalView.remoteContentGeneration
        var quietTicks = 0
        for _ in 0 ..< maxTicks {
            try? await Task.sleep(for: .milliseconds(20))
            let generation = terminalView.remoteContentGeneration
            if generation == lastGeneration {
                quietTicks += 1
                if quietTicks >= 3 { break }
            } else {
                lastGeneration = generation
                quietTicks = 0
            }
        }
    }

    /// Whether a recorded Copilot session id is a strict UUID (the only form the
    /// hook writes and the form `copilot --resume` expects). Rejects anything else
    /// before it's interpolated into the shell command — defense-in-depth alongside
    /// the hook's own validation.
    nonisolated static func isSafeSessionId(_ s: String) -> Bool {
        UUID(uuidString: s) != nil
    }

    nonisolated static func resumeCommand(
        sessionId: String,
        allowAll: Bool,
        executable: String = "copilot"
    ) -> String {
        // Pass both flags because the CLI can otherwise inherit persisted remote
        // steering on resume even when event export was explicitly disabled.
        var arguments = ["--no-remote", "--no-remote-export"]
        if allowAll { arguments.append("--allow-all") }
        arguments.append("--resume=\(sessionId)")
        return profiledCopilotCommand(executable, arguments: arguments)
    }

    /// Copilot loader/supervisor env vars that leak in when this app was itself
    /// launched from a Copilot session. They must be stripped from every spawned
    /// session's environment: otherwise a `copilot` started inside one believes
    /// it's a managed/supervised child, so `COPILOT_SUPERVISED` makes its
    /// `/restart` shut down instead of re-spawn, and the loader vars make it defer
    /// to a launcher that's usually gone.
    nonisolated static let leakedCopilotEnvKeys: Set<String> = [
        "COPILOT_LOADER_PID", "COPILOT_RUN_APP", "COPILOT_DETACHED_SESSION",
        "COPILOT_DETACHED_PARENT_SESSION_ID", "COPILOT_DETACHED_PARENT_ENGAGEMENT_ID",
        "COPILOT_AGENT_SESSION_ID", "COPILOT_CONNECTION_TOKEN", "COPILOT_SHUTDOWN_FLUSH",
        "COPILOT_CLI", "COPILOT_CLI_BINARY_VERSION", "COPILOT_SUPERVISED",
    ]

    /// Returns `base` with the leaked Copilot loader/supervisor vars removed. Pure
    /// so the stripping can be unit-tested without spawning a process.
    nonisolated static func sessionEnvironment(
        from base: [String: String]
    ) -> [String: String] {
        var env = base
        for key in leakedCopilotEnvKeys { env.removeValue(forKey: key) }
        return env
    }

    /// Copilot currently enables inline images for Ghostty-compatible terminals.
    /// Scope that profile to Copilot itself so unrelated TUIs keep the real terminal
    /// identity, while Copilot and its `/restart` descendants inherit the profile.
    nonisolated static func profiledCopilotCommand(
        _ executable: String,
        arguments: [String]
    ) -> String {
        let script = #"unset TERM_PROGRAM_VERSION; TERM_PROGRAM=ghostty exec "$0" "$@""#
        let operands = ([executable] + arguments).map(shellSingleQuote).joined(separator: " ")
        return "/bin/sh -c \(shellSingleQuote(script)) \(operands)"
    }

    /// The dtach `-E` program: the argv run only when dtach creates a FRESH master.
    /// A recorded Copilot session id always wins (resume takes precedence over a
    /// one-shot launch), so a resumed tab never double-launches; otherwise a valid
    /// absolute launch executable starts Copilot once; otherwise a plain login shell.
    /// Pure/static so precedence can be unit-tested without spawning anything.
    nonisolated static func startupProgram(
        shell: String,
        copilotSessionId: String?,
        copilotSessionAllowAll: Bool,
        resumeCopilotExecutable: String? = nil,
        launchCopilotExecutable: String?,
        launchCopilotInitialPrompt: String? = nil
    ) -> [String] {
        if let cid = copilotSessionId, isSafeSessionId(cid) {
            // Quote the shell path (spaces/apostrophes) and warn — without blocking
            // the shell fallback — if the session can't be resumed (e.g. deleted).
            let resume = resumeCommand(
                sessionId: cid,
                allowAll: copilotSessionAllowAll,
                executable: resumeCopilotExecutable ?? "copilot"
            )
                + " || printf '\\n[Copilot Projects] could not resume Copilot session \(cid)\\n'"
            return [shell, "-l", "-c", "\(resume); exec \(shellSingleQuote(shell)) -l"]
        }
        if let executable = launchCopilotExecutable, !executable.isEmpty {
            return [shell, "-l", "-c", launchCommand(
                executable: executable,
                shell: shell,
                allowAll: copilotSessionAllowAll,
                initialPrompt: launchCopilotInitialPrompt
            )]
        }
        return [shell, "-l"]
    }

    /// One-shot launch of the absolute Copilot executable, then drop to a login
    /// shell. The executable is shell-single-quoted so spaces/apostrophes in the
    /// path can't break the command; a launch failure prints a message but still
    /// hands the tab a usable shell. Pure/static for command-building tests.
    nonisolated static func launchCommand(
        executable: String,
        shell: String,
        allowAll: Bool = false,
        initialPrompt: String? = nil
    ) -> String {
        var arguments = ["--no-remote", "--no-remote-export"]
        if allowAll { arguments.append("--allow-all") }
        if let initialPrompt, !initialPrompt.isEmpty {
            arguments.append(contentsOf: ["--interactive", initialPrompt])
        }
        return profiledCopilotCommand(executable, arguments: arguments)
            + " || printf '\\n[Copilot Projects] could not launch Copilot\\n';"
            + " exec \(shellSingleQuote(shell)) -l"
    }

    /// POSIX single-quote a string for safe interpolation into a shell command:
    /// wrap in single quotes, and emit any embedded quote as `'\''`. Used for the
    /// shell path in the resume command so spaces or apostrophes can't break it.
    nonisolated static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory?(directory)
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            if !isDrainingForTermination {
                terminalView.kittyImageCapture.disablePersistence()
                terminalView.cancelImageRestore()
            }
            exited = true
            onExit?(exitCode)
        }
    }
}
