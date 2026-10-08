import Darwin
import Foundation

/// The Copilot CLI's own record of its sessions under `$COPILOT_HOME` (by default
/// `~/.copilot`): a folder per session with its event log and `workspace.yaml`,
/// and the `session-store.db` index. These are the CLI's internal formats, so
/// anything that can't be read is treated as absent.
public struct CopilotSessionStore: Sendable {
    public let copilotHome: String

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) {
        if let configured = environment["COPILOT_HOME"], !configured.isEmpty {
            copilotHome = Self.expandingTilde(configured, home: home)
        } else {
            copilotHome = (home as NSString).appendingPathComponent(".copilot")
        }
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return (home as NSString).appendingPathComponent(String(path.dropFirst(2))) }
        return path
    }

    public var sessionStateDirectory: String {
        (copilotHome as NSString).appendingPathComponent("session-state")
    }

    public var databasePath: String {
        (copilotHome as NSString).appendingPathComponent("session-store.db")
    }

    /// A session id the CLI writes and `copilot --resume` accepts: a strict UUID.
    public static func isValidSessionId(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// Nil for an id that could step outside the session folder.
    public func directory(for copilotSessionId: String) -> String? {
        guard copilotSessionId.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return (sessionStateDirectory as NSString).appendingPathComponent(copilotSessionId)
    }

    /// The session's event log.
    public func transcriptPath(for copilotSessionId: String) -> String? {
        directory(for: copilotSessionId).map { ($0 as NSString).appendingPathComponent("events.jsonl") }
    }

    /// The session's `workspace.yaml`; nil when it has none.
    public func record(for copilotSessionId: String) -> CopilotSessionRecord? {
        guard let directory = directory(for: copilotSessionId),
              let text = try? String(
                contentsOfFile: (directory as NSString).appendingPathComponent("workspace.yaml"), encoding: .utf8
              ) else { return nil }
        return CopilotSessionRecord(yaml: text)
    }

    /// Whether a running Copilot CLI holds the session. A CLI that has it open
    /// leaves `inuse.<pid>.lock`, and the file stays behind if it crashes, so a
    /// lock counts only while its process lives and started before the lock was
    /// written; a later start is a reused pid. The lock files are only listed and
    /// stat'ed, never opened: a probe could make a starting CLI think the session
    /// is in use.
    public func isInUse(_ copilotSessionId: String) -> Bool {
        guard let directory = directory(for: copilotSessionId),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return false }
        for name in names where name.hasPrefix("inuse.") && name.hasSuffix(".lock") {
            let digits = name.dropFirst("inuse.".count).dropLast(".lock".count)
            guard let pid = pid_t(digits), pid > 0, Self.isAlive(pid) else { continue }
            var info = stat()
            guard stat((directory as NSString).appendingPathComponent(name), &info) == 0 else { continue }
            let locked = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
            if let started = Self.startTime(of: pid), started > locked + 2 { continue }
            return true
        }
        return false
    }

    private static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func startTime(of pid: pid_t) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6
    }
}

/// What a Copilot CLI session's `workspace.yaml` says about it.
public struct CopilotSessionRecord: Equatable, Sendable {
    public var id: String?
    /// The folder the session worked in.
    public var cwd: String?
    public var clientName: String?
    public var name: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String? = nil, cwd: String? = nil, clientName: String? = nil, name: String? = nil,
        createdAt: Date? = nil, updatedAt: Date? = nil
    ) {
        self.id = id
        self.cwd = cwd
        self.clientName = clientName
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Reads top-level `key: value` lines, quoted or not, and `|`/`>` block
    /// values; anything else is skipped.
    public init(yaml: String) {
        self.init()
        let lines = yaml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let first = line.first, first != " ", first != "\t", first != "#",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if let style = value.first, style == "|" || style == ">" {
                var block: [String] = []
                while index < lines.count, lines[index].isEmpty || lines[index].first == " " {
                    block.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                while block.last?.isEmpty == true { block.removeLast() }
                value = block.joined(separator: style == "|" ? "\n" : " ")
            } else {
                value = Self.unquoted(value)
            }
            switch key {
            case "id": id = value
            case "cwd": cwd = value
            case "client_name": clientName = value
            case "name": name = value
            case "created_at": createdAt = Self.date(value)
            case "updated_at": updatedAt = Self.date(value)
            default: break
            }
        }
    }

    /// The name to show: its first line, or nil when it has none.
    public var displayName: String? {
        name?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else {
            return value
        }
        let inner = String(value.dropFirst().dropLast())
        if first == "'" { return inner.replacingOccurrences(of: "''", with: "'") }
        var result = ""
        var escaped = false
        for character in inner {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: result.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
