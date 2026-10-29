import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal read-only view of the process tree, used to decide whether a coding
/// agent is still alive inside a session's shell.
public enum ProcessTree {
    public struct Snapshot: Equatable, Sendable {
        public var childrenOf: [pid_t: [pid_t]] = [:]
        public var parentOf: [pid_t: pid_t] = [:]
        public var nameOf: [pid_t: String] = [:]

        public init() {}
    }

    public static let defaultSnapshotMaxAge: Duration = .milliseconds(150)

    final class SnapshotCache: @unchecked Sendable {
        private let lock = NSLock()
        private let now: @Sendable () -> ContinuousClock.Instant
        private let read: @Sendable () -> Snapshot
        private var cached: (snapshot: Snapshot, capturedAt: ContinuousClock.Instant)?

        init(
            now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
            read: @escaping @Sendable () -> Snapshot = { ProcessTree.readSnapshot() }
        ) {
            self.now = now
            self.read = read
        }

        func snapshot(maxAge: Duration = ProcessTree.defaultSnapshotMaxAge) -> Snapshot {
            lock.lock()
            defer { lock.unlock() }
            let current = now()
            if maxAge > .zero,
               let cached,
               cached.capturedAt <= current,
               cached.capturedAt.duration(to: current) < maxAge {
                return cached.snapshot
            }
            let fresh = read()
            if !fresh.nameOf.isEmpty {
                cached = (fresh, current)
            }
            return fresh
        }

        func invalidate() {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }

    private static let snapshotCache = SnapshotCache()

    /// One pass over all processes: parent links + short process names.
    /// Reuses a cached snapshot when younger than `maxAge` (pass `.zero` for an
    /// uncached kernel read).
    public static func snapshot(maxAge: Duration = defaultSnapshotMaxAge) -> Snapshot {
        snapshotCache.snapshot(maxAge: maxAge)
    }

    public static func invalidateSnapshotCache() {
        snapshotCache.invalidate()
    }

    static func readSnapshot() -> Snapshot {
        var snap = Snapshot()
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return snap }
        let capacity = Int(needed) / MemoryLayout<pid_t>.stride + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        let returned = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                     Int32(capacity * MemoryLayout<pid_t>.stride))
        guard returned > 0 else { return snap }
        let count = min(Int(returned) / MemoryLayout<pid_t>.stride, pids.count)

        for i in 0..<count {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let got = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size)
            guard got == size else { continue }
            let ppid = pid_t(bitPattern: info.pbsi_ppid)
            let name = withUnsafeBytes(of: info.pbsi_comm) { raw -> String in
                guard let base = raw.baseAddress else { return "" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            snap.childrenOf[ppid, default: []].append(pid)
            snap.parentOf[pid] = ppid
            snap.nameOf[pid] = name
        }
        return snap
    }

    /// True if any descendant of `root` has a process name in `names`.
    public static func hasDescendant(under root: pid_t, named names: Set<String>, in snap: Snapshot) -> Bool {
        guard root > 0, !names.isEmpty else { return false }
        var stack = snap.childrenOf[root] ?? []
        var visited = Set<pid_t>()
        while let pid = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if let name = snap.nameOf[pid], names.contains(name) { return true }
            if let kids = snap.childrenOf[pid] { stack.append(contentsOf: kids) }
        }
        return false
    }

    /// A process as it was when seen. The start time tells it apart from a later
    /// process that reuses its pid, so a delayed signal never reaches the wrong one.
    public struct Identity: Hashable, Sendable {
        public let pid: pid_t
        public let started: UInt64

        public init?(_ pid: pid_t) {
            guard let started = Self.startTime(of: pid) else { return nil }
            self.pid = pid
            self.started = started
        }

        public var isCurrent: Bool { Self.startTime(of: pid) == started }

        public func signal(_ signal: Int32) {
            if isCurrent { kill(pid, signal) }
        }

        private static func startTime(of pid: pid_t) -> UInt64? {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
        }
    }

    /// Every process descended from `root`, read before it is signalled because
    /// orphans are re-parented and can no longer be traced back to it.
    public static func descendants(of root: pid_t) -> [Identity] {
        let tree = snapshot(maxAge: .zero)
        var seen = Set<pid_t>()
        var found: [Identity] = []
        var pending = tree.childrenOf[root] ?? []
        while let pid = pending.popLast() {
            guard seen.insert(pid).inserted else { continue }
            if let identity = Identity(pid) { found.append(identity) }
            pending.append(contentsOf: tree.childrenOf[pid] ?? [])
        }
        return found
    }

    /// argv + environment of a process via KERN_PROCARGS2 (same-uid only).
    public static func inspect(_ pid: pid_t) -> (args: [String], env: [String: String]) {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        if sysctl(&mib, 3, nil, &size, nil, 0) != 0 || size < MemoryLayout<Int32>.size {
            return ([], [:])
        }
        var buffer = [UInt8](repeating: 0, count: size)
        if sysctl(&mib, 3, &buffer, &size, nil, 0) != 0 { return ([], [:]) }

        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { dst in
            buffer.withUnsafeBytes { src in
                dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: src[0..<4]))
            }
        }

        var i = MemoryLayout<Int32>.size
        while i < size && buffer[i] != 0 { i += 1 }      // skip exec_path
        while i < size && buffer[i] == 0 { i += 1 }      // skip alignment nulls

        func nextCString() -> String {
            let start = i
            while i < size && buffer[i] != 0 { i += 1 }
            let s = String(decoding: buffer[start..<i], as: UTF8.self)
            if i < size { i += 1 }
            return s
        }

        var args: [String] = []
        var n = 0
        while n < Int(max(0, argc)) && i < size {
            args.append(nextCString())
            n += 1
        }

        var env: [String: String] = [:]
        while i < size {
            let kv = nextCString()
            if let eq = kv.firstIndex(of: "=") {
                env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
            }
        }
        return (args, env)
    }

    /// Sessions (by COPILOT_PROJECTS_SESSION env) that currently host a live agent
    /// process. A real dtach ancestor is authoritative over inherited environment
    /// because nested or long-lived shells can carry another tab's stale session id.
    public static func agentSessions(agentNames: Set<String>, in snap: Snapshot) -> Set<String> {
        let dtach = dtachProcesses(in: snap)
        return agentSessions(
            agentNames: agentNames,
            in: snap,
            environmentOf: { inspect($0).env },
            dtachProcesses: dtach,
            sessionsDirectory: Paths.sessionsDir
        )
    }

    static func agentSessions(
        agentNames: Set<String>,
        in snap: Snapshot,
        environmentOf: (pid_t) -> [String: String],
        dtachProcesses: [DtachProcess],
        sessionsDirectory: URL
    ) -> Set<String> {
        var sessions = Set<String>()
        for (pid, name) in snap.nameOf where agentNames.contains(name) {
            let environment = environmentOf(pid)
            if let sid = managedSessionId(
                for: pid,
                fallbackSessionId: Env.sessionId(environment),
                sessionsDirectory: sessionsDirectory,
                in: snap,
                dtachProcesses: dtachProcesses
            ) {
                sessions.insert(sid)
            }
        }
        return sessions
    }

    /// Tabs still bringing back Copilot session `copilotSessionId`: the command
    /// that resumes it, or the Copilot CLI it started, runs in them. Once that CLI
    /// exits, the tab's shell replaces the command and the tab no longer counts.
    /// dtach keeps the command among its arguments for the tab's life, so it never
    /// counts; another tab's dtach started from inside this one belongs to that tab.
    public static func sessionsResuming(copilotSessionId: String, in snap: Snapshot) -> Set<String> {
        sessionsResuming(
            copilotSessionId: copilotSessionId,
            in: snap,
            argumentsOf: { inspect($0).args },
            dtachProcesses: dtachProcesses(in: snap),
            sessionsDirectory: Paths.sessionsDir
        )
    }

    static func sessionsResuming(
        copilotSessionId: String,
        in snap: Snapshot,
        argumentsOf: (pid_t) -> [String],
        dtachProcesses: [DtachProcess],
        sessionsDirectory: URL
    ) -> Set<String> {
        var sessions = Set<String>()
        for dtach in dtachProcesses {
            guard let socket = dtach.socketPath,
                  let sessionId = sessionId(fromDtachSocket: socket, sessionsDirectory: sessionsDirectory),
                  !sessions.contains(sessionId) else { continue }
            var pending = snap.childrenOf[dtach.pid] ?? []
            var seen = Set<pid_t>()
            while let pid = pending.popLast() {
                guard seen.insert(pid).inserted, snap.nameOf[pid] != "dtach" else { continue }
                if resumes(argumentsOf(pid), copilotSessionId: copilotSessionId) {
                    sessions.insert(sessionId)
                    break
                }
                pending.append(contentsOf: snap.childrenOf[pid] ?? [])
            }
        }
        return sessions
    }

    /// Arguments that resume Copilot session `copilotSessionId`: the Copilot
    /// CLI's `--resume=<id>` or `--resume <id>` options, or the shell command
    /// Copilot Projects runs to resume it (`TerminalController.startupProgram`),
    /// known by the fallback only it prints. Only Copilot's own options count:
    /// not a prompt, a command that merely quotes one, or another program's
    /// arguments, as when it searches for the flag.
    public static func resumes(_ arguments: [String], copilotSessionId: String) -> Bool {
        let id = copilotSessionId.lowercased()
        // Quoting a prompt escapes each `'`, so a prompt can never spell this.
        let fallback = "|| printf '\\n[copilot projects] could not resume copilot session \(id)\\n'"
        let arguments = arguments.map { $0.lowercased() }
        func name(_ path: String) -> String { (path as NSString).lastPathComponent }
        guard let program = arguments.first else { return false }
        // Where Copilot's own options start: after the CLI, after the `$0` a
        // shell wrapper runs it as, or after the script its loader runs.
        var options: Int?
        if name(program) == "copilot" {
            options = 1
        } else if ["sh", "bash", "zsh", "dash", "ksh", "fish"].contains(name(program).trimmingCharacters(in: ["-"])),
                  let shell = arguments.prefix(3).firstIndex(of: "-c"), shell + 1 < arguments.count {
            if arguments[shell + 1].contains(fallback) { return true }
            if shell + 2 < arguments.count, name(arguments[shell + 2]) == "copilot" { options = shell + 3 }
        } else if name(program) == "node",
                  let script = arguments.dropFirst().firstIndex(where: { !$0.hasPrefix("-") }),
                  name(arguments[script]) == "copilot" || arguments[script].contains("/@github/copilot/") {
            options = script + 1
        }
        guard var index = options else { return false }
        let promptOptions: Set<String> = ["--interactive", "-i", "--prompt", "-p"]
        while index < arguments.count, arguments[index] != "--" {
            let argument = arguments[index]
            if promptOptions.contains(argument) {
                index += 2
            } else if argument == "--resume=" + id
                        || (argument == "--resume" && index + 1 < arguments.count && arguments[index + 1] == id) {
                return true
            } else {
                index += 1
            }
        }
        return false
    }

    /// Resolve the Copilot Projects tab that owns `pid`.
    ///
    /// Managed terminals run below a dtach process whose socket filename is the
    /// authoritative app-session id. Prefer that over inherited environment. A
    /// direct (non-dtach) terminal may fall back to its environment only when the
    /// ancestry reaches the Copilot Projects app; a broken/reparented ancestry fails
    /// closed rather than guessing from the known-stale value.
    public static func managedSessionId(
        for pid: pid_t,
        fallbackSessionId: String?,
        sessionsDirectory: URL,
        in snap: Snapshot,
        dtachProcesses: [DtachProcess]? = nil
    ) -> String? {
        guard pid > 0 else { return nil }
        let dtachByPID = Dictionary(
            uniqueKeysWithValues: (dtachProcesses ?? self.dtachProcesses(in: snap))
                .map { ($0.pid, $0) }
        )
        let fallback = validSessionId(fallbackSessionId)
        var current = pid
        var visited = Set<pid_t>()

        while current > 1, visited.insert(current).inserted {
            if let process = dtachByPID[current],
               let socketPath = process.socketPath,
               let sessionId = sessionId(
                   fromDtachSocket: socketPath,
                   sessionsDirectory: sessionsDirectory
               ) {
                return sessionId
            }
            if let name = snap.nameOf[current],
               name == "copilot-project"
                    || name == "copilot-projects" {
                return fallback
            }
            guard let parent = snap.parentOf[current], parent > 0 else {
                return nil
            }
            current = parent
        }
        return nil
    }

    /// The dtach master owning a given session socket (for kill). A newly-created
    /// master is initially a child of the creating/attached dtach client; after that
    /// client exits it is reparented to launchd (PID 1). A later reattach creates an
    /// unrelated client. In every state the client and master share the socket argv.
    public static func dtachMaster(forSocket socket: String, in snap: Snapshot) -> pid_t? {
        dtachMaster(forSocket: socket, among: dtachProcesses(in: snap))
    }

    public struct DtachProcess {
        public let pid: pid_t
        public let parentPID: pid_t
        public let socketPath: String?
        public let isMaster: Bool

        public init(pid: pid_t, parentPID: pid_t, socketPath: String?, isMaster: Bool) {
            self.pid = pid
            self.parentPID = parentPID
            self.socketPath = socketPath
            self.isMaster = isMaster
        }
    }

    public static func dtachProcesses(
        in snap: Snapshot,
        sessionsDirectory: URL? = nil
    ) -> [DtachProcess] {
        let customDirPrefix = sessionsDirectory.map {
            $0.standardizedFileURL.path.hasSuffix("/")
                ? $0.standardizedFileURL.path
                : $0.standardizedFileURL.path + "/"
        }
        let raw: [DtachProcess] = snap.nameOf.compactMap { pid, name in
            guard name == "dtach" else { return nil }
            let args = inspect(pid).args
            let socket = args.first { arg in
                guard arg.hasSuffix(".sock") else { return false }
                if arg.contains("/sessions/") { return true }
                if let customDirPrefix {
                    let standardized = URL(fileURLWithPath: arg).standardizedFileURL.path
                    return standardized.hasPrefix(customDirPrefix)
                }
                return false
            }
            let parent = snap.parentOf[pid] ?? 0
            return DtachProcess(
                pid: pid,
                parentPID: parent,
                socketPath: socket,
                isMaster: false
            )
        }
        return raw.map { process in
            DtachProcess(
                pid: process.pid,
                parentPID: process.parentPID,
                socketPath: process.socketPath,
                isMaster: isDtachMaster(process, among: raw)
            )
        }
    }

    public static func dtachMaster(
        forSocket socket: String,
        among processes: [DtachProcess]
    ) -> pid_t? {
        let matching = processes.filter { $0.socketPath == socket }
        return matching.first { isDtachMaster($0, among: matching) }?.pid
    }

    private static func isDtachMaster(
        _ process: DtachProcess,
        among processes: [DtachProcess]
    ) -> Bool {
        process.parentPID == 1
            || processes.contains {
                $0.pid == process.parentPID && $0.socketPath == process.socketPath
            }
    }

    private static func sessionId(
        fromDtachSocket socketPath: String,
        sessionsDirectory: URL
    ) -> String? {
        let socket = URL(fileURLWithPath: socketPath).standardizedFileURL
        let expectedDirectory = sessionsDirectory.standardizedFileURL
        guard socket.deletingLastPathComponent().path == expectedDirectory.path,
              socket.pathExtension == "sock" else {
            return nil
        }
        return validSessionId(socket.deletingPathExtension().lastPathComponent)
    }

    private static func validSessionId(_ value: String?) -> String? {
        guard let value, value.utf8.count == 36, UUID(uuidString: value) != nil else {
            return nil
        }
        return value
    }

    // MARK: - Per-session memory footprint

    public static let sessionMemoryQuantizationBytes: Int64 = 10_000_000

    public static func quantizeSessionMemoryBytes(_ bytes: Int64?) -> Int64? {
        guard let bytes, bytes > 0 else { return nil }
        return max(
            sessionMemoryQuantizationBytes,
            (bytes / sessionMemoryQuantizationBytes) * sessionMemoryQuantizationBytes
        )
    }

    public static func processMemoryFootprintBytes(pid: pid_t) -> Int64? {
        guard pid > 0 else { return nil }
        var rusage = rusage_info_v4()
        let rusageResult = withUnsafeMutablePointer(to: &rusage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        if rusageResult == 0, rusage.ri_phys_footprint > 0 {
            return Int64(min(rusage.ri_phys_footprint, UInt64(Int64.max)))
        }
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size) == size,
           taskInfo.pti_resident_size > 0 {
            return Int64(min(taskInfo.pti_resident_size, UInt64(Int64.max)))
        }
        return nil
    }

    /// Computes each active session's process-tree memory footprint in bytes from its
    /// `dtach` server (plus any direct non-dtach shell root PIDs) and all non-nested-`dtach`
    /// descendant PIDs, quantized to 10 MB increments.
    public static func sessionMemoryUsageBytes(
        in snap: Snapshot,
        dtachProcesses: [DtachProcess]? = nil,
        additionalRootPIDsBySession: [String: pid_t] = [:],
        sessionsDirectory: URL = Paths.sessionsDir,
        memoryOfPID: (pid_t) -> Int64? = { processMemoryFootprintBytes(pid: $0) }
    ) -> [String: Int64] {
        let dtachList = dtachProcesses ?? self.dtachProcesses(
            in: snap,
            sessionsDirectory: sessionsDirectory
        )
        let expectedDirectory = sessionsDirectory.standardizedFileURL.path
        var rootsBySession: [String: [pid_t]] = [:]
        var sessionOfDtachPID: [pid_t: String] = [:]

        for dtach in dtachList {
            guard let socketPath = dtach.socketPath else { continue }
            let socketURL = URL(fileURLWithPath: socketPath).standardizedFileURL
            guard socketURL.deletingLastPathComponent().path == expectedDirectory,
                  socketURL.pathExtension == "sock" else {
                continue
            }
            let sessionId = socketURL.deletingPathExtension().lastPathComponent
            guard !sessionId.isEmpty else { continue }
            sessionOfDtachPID[dtach.pid] = sessionId
            rootsBySession[sessionId, default: []].append(dtach.pid)
        }

        for (sessionId, rootPID) in additionalRootPIDsBySession where rootPID > 0 {
            rootsBySession[sessionId, default: []].append(rootPID)
        }

        var result: [String: Int64] = [:]
        for (sessionId, roots) in rootsBySession {
            var seen = Set<pid_t>()
            var stack: [pid_t] = []
            for root in roots where root > 0 && seen.insert(root).inserted {
                stack.append(root)
            }
            var totalBytes: Int64 = 0
            while let pid = stack.popLast() {
                if let bytes = memoryOfPID(pid), bytes > 0 {
                    let (sum, overflow) = totalBytes.addingReportingOverflow(bytes)
                    totalBytes = overflow ? Int64.max : sum
                }
                for child in snap.childrenOf[pid] ?? [] {
                    if snap.nameOf[child] == "dtach",
                       sessionOfDtachPID[child] != sessionId {
                        continue
                    }
                    if seen.insert(child).inserted {
                        stack.append(child)
                    }
                }
            }
            if let quantized = quantizeSessionMemoryBytes(totalBytes) {
                result[sessionId] = quantized
            }
        }
        return result
    }
}
