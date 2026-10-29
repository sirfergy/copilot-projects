import Darwin
import Foundation
import CopilotProjectsProtocol

/// Auto-discovers SSH hosts from `~/.ssh/config` (and optional `hosts.json` overrides)
/// so sessions and projects can target either This Mac or any configured remote machine.
public enum SSHHostCatalog {
    private static let ignoredHostSuffixes: [String] = [
        "github.com",
        ".github.com",
        ".ghe.com",
        "gitlab.com",
        ".gitlab.com",
        "bitbucket.org",
        ".bitbucket.org",
        "vs-ssh.visualstudio.com",
        "ssh.dev.azure.com",
    ]

    private static let ignoredExactHosts: Set<String> = [
        "localhost",
        "127.0.0.1",
        "::1",
    ]

    /// Default discovery used by `AppModel`: only reads the user's real `~/.ssh/config`
    /// when running against the primary state path, so unit tests with isolated temp
    /// `StateRepository` paths remain deterministic unless they place `ssh_config` or
    /// `hosts.json` in their isolated state directory.
    public static func defaultAvailableHosts(
        statePath: URL = Paths.statePath,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [RemoteHostInfo] {
        let stateDir = statePath.deletingLastPathComponent()
        let isolatedSSHConfig = stateDir.appendingPathComponent("ssh_config")
        if FileManager.default.fileExists(atPath: isolatedSSHConfig.path)
            || statePath.standardizedFileURL != Paths.statePath.standardizedFileURL {
            return discoverHosts(
                sshConfigURL: FileManager.default.fileExists(atPath: isolatedSSHConfig.path)
                    ? isolatedSSHConfig : nil
            )
        }
        let userSSHConfig = homeDirectory
            .appendingPathComponent(".ssh", isDirectory: true)
            .appendingPathComponent("config")
        return discoverHosts(sshConfigURL: userSSHConfig)
    }

    public static func discoverHosts(sshConfigURL: URL?) -> [RemoteHostInfo] {
        var result: [RemoteHostInfo] = [.local]
        var seenIds: Set<String> = [RemoteHostInfo.localId]

        if let sshConfigURL {
            let baseDir = sshConfigURL.deletingLastPathComponent()
            for candidate in parseSSHConfigFile(at: sshConfigURL, baseSSHDir: baseDir)
                where seenIds.insert(candidate.id).inserted {
                result.append(candidate)
            }
        }

        return result
    }

    /// Resolves an explicit `hostId` (or falls back to `projectDefaultHostId` when `hostId`
    /// is nil/empty) against `hosts`. Returns `.local` when neither is set or when `"local"`
    /// is requested. Returns `nil` when an explicit/default host is not found in `hosts`.
    public static func resolve(
        hostId: String?,
        projectDefaultHostId: String? = nil,
        in hosts: [RemoteHostInfo]
    ) -> RemoteHostInfo? {
        let trimmedExplicit = hostId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefault = projectDefaultHostId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effective: String?
        if let trimmedExplicit, !trimmedExplicit.isEmpty {
            effective = trimmedExplicit
        } else if let trimmedDefault, !trimmedDefault.isEmpty {
            effective = trimmedDefault
        } else {
            return .local
        }
        guard let query = effective else { return .local }
        if query.caseInsensitiveCompare(RemoteHostInfo.localId) == .orderedSame {
            return .local
        }
        if let exact = hosts.first(where: { !$0.isLocal && $0.id.caseInsensitiveCompare(query) == .orderedSame }) {
            return exact
        }
        if let byTarget = hosts.first(where: {
            guard !$0.isLocal, let target = $0.sshTarget else { return false }
            if target.caseInsensitiveCompare(query) == .orderedSame { return true }
            if !query.contains("@"),
               let hostPart = target.split(separator: "@").last,
               String(hostPart).caseInsensitiveCompare(query) == .orderedSame {
                return true
            }
            return false
        }) {
            return byTarget
        }
        if !query.contains("."), !query.contains("@") {
            let shortMatches = hosts.filter { host in
                guard !host.isLocal else { return false }
                let targetHost = (host.sshTarget ?? host.id).split(separator: "@").last.map(String.init) ?? host.id
                guard let firstLabel = targetHost.split(separator: ".").first else { return false }
                return String(firstLabel).caseInsensitiveCompare(query) == .orderedSame
            }
            if shortMatches.count == 1 {
                return shortMatches[0]
            }
        }
        return nil
    }

    // MARK: - SSH Config Parser

    private struct SSHHostBlock {
        var patterns: [String]
        var scopePatterns: [[String]] = []
        var hostName: String?
        var customDisplayName: String?
        var defaultCwd: String?
        var ignored: Bool = false

        func matches(_ alias: String) -> Bool {
            matchesHostPatterns(alias, patterns: patterns)
                && scopePatterns.allSatisfy { matchesHostPatterns(alias, patterns: $0) }
        }
    }

    private static func parseSSHConfigFile(
        at rootURL: URL,
        baseSSHDir: URL
    ) -> [RemoteHostInfo] {
        var blocks: [SSHHostBlock] = [SSHHostBlock(patterns: ["*"], ignored: true)]

        func parseFile(
            at url: URL,
            visited: Set<URL>,
            depth: Int,
            activeBlockIndex: Int,
            scopePatterns: [[String]]
        ) {
            guard depth <= 16 else { return }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard !visited.contains(canonical),
                  let content = try? String(contentsOf: canonical, encoding: .utf8) else {
                return
            }
            var nextVisited = visited
            nextVisited.insert(canonical)
            var currentBlockIndex = activeBlockIndex
            var inMatchBlock = false
            var pendingDisplayName: String?
            var pendingDefaultCwd: String?
            var pendingIgnored = false

            for rawLine in content.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                if trimmed.hasPrefix("#") {
                    if let directive = parseDirectiveComment(trimmed) {
                        if directive.ignore { pendingIgnored = true }
                        if let name = directive.name { pendingDisplayName = name }
                        if let cwd = directive.cwd { pendingDefaultCwd = cwd }
                    }
                    continue
                }

                let lineWithoutComment = stripInlineComment(from: trimmed)
                guard let (keyword, value) = splitKeywordAndValue(lineWithoutComment) else {
                    continue
                }
                switch keyword.lowercased() {
                case "host":
                    inMatchBlock = false
                    blocks.append(SSHHostBlock(
                        patterns: splitPatterns(value),
                        scopePatterns: scopePatterns,
                        customDisplayName: pendingDisplayName,
                        defaultCwd: pendingDefaultCwd,
                        ignored: pendingIgnored
                    ))
                    currentBlockIndex = blocks.count - 1
                    pendingDisplayName = nil
                    pendingDefaultCwd = nil
                    pendingIgnored = false
                case "match":
                    inMatchBlock = true
                    pendingDisplayName = nil
                    pendingDefaultCwd = nil
                    pendingIgnored = false
                case "include":
                    guard !inMatchBlock else { break }
                    let childScope = currentBlockIndex == 0
                        ? scopePatterns
                        : scopePatterns + [blocks[currentBlockIndex].patterns]
                    for pattern in splitPatterns(value) {
                        for includedURL in resolveIncludePattern(pattern, relativeTo: baseSSHDir) {
                            parseFile(
                                at: includedURL,
                                visited: nextVisited,
                                depth: depth + 1,
                                activeBlockIndex: currentBlockIndex,
                                scopePatterns: childScope
                            )
                        }
                    }
                case "hostname":
                    if !inMatchBlock, blocks[currentBlockIndex].hostName == nil {
                        blocks[currentBlockIndex].hostName = unquote(value)
                    }
                default:
                    break
                }
            }
        }

        parseFile(at: rootURL, visited: [], depth: 0, activeBlockIndex: 0, scopePatterns: [])
        return blocks.filter { !$0.ignored }.flatMap { block in
            block.patterns.compactMap { alias -> RemoteHostInfo? in
                guard isEligibleHostAlias(alias), block.matches(alias) else { return nil }
                let effectiveHostName = blocks.first {
                    $0.hostName != nil && $0.matches(alias)
                }?.hostName
                if let effectiveHostName, !isEligibleHostAlias(effectiveHostName) {
                    return nil
                }
                return RemoteHostInfo(
                    id: alias.lowercased(),
                    displayName: block.customDisplayName ?? shortIdentifier(for: alias).lowercased(),
                    sshTarget: alias,
                    defaultCwd: block.defaultCwd,
                    isLocal: false
                )
            }
        }
    }

    private static func matchesHostPatterns(_ alias: String, patterns: [String]) -> Bool {
        let lowerAlias = alias.lowercased()
        var matchedPositive = false
        for raw in patterns {
            let lower = raw.lowercased()
            if lower.hasPrefix("!") {
                if fnmatch(String(lower.dropFirst()), lowerAlias, 0) == 0 { return false }
            } else if fnmatch(lower, lowerAlias, 0) == 0 {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    private static func isEligibleHostAlias(_ alias: String) -> Bool {
        let lower = alias.lowercased()
        guard !lower.isEmpty, !lower.contains("*"), !lower.contains("?"), !lower.hasPrefix("!"),
              !ignoredExactHosts.contains(lower) else { return false }
        return !ignoredHostSuffixes.contains {
            $0.hasPrefix(".") ? lower.hasSuffix($0) : lower == $0
        }
    }

    private static func shortIdentifier(for alias: String) -> String {
        let hostPart = alias.split(separator: "@").last.map(String.init) ?? alias
        // Keep IPv4 addresses intact instead of taking the first octet.
        if hostPart.split(separator: ".").allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return hostPart
        }
        if let first = hostPart.split(separator: ".").first, !first.isEmpty {
            return String(first)
        }
        return hostPart
    }

    private static func parseDirectiveComment(
        _ comment: String
    ) -> (name: String?, cwd: String?, ignore: Bool)? {
        let body = comment.dropFirst().trimmingCharacters(in: .whitespaces)
        let prefix = "copilot-projects:"
        guard body.lowercased().hasPrefix(prefix) else { return nil }
        let rest = String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        if rest.lowercased() == "ignore" { return (nil, nil, true) }
        var name: String?, cwd: String?, ignore = false
        let scanner = Scanner(string: rest)
        scanner.charactersToBeSkipped = .whitespaces
        while !scanner.isAtEnd {
            guard let key = scanner.scanUpToString("=") else {
                if scanner.scanUpToCharacters(from: .whitespaces)?.lowercased() == "ignore" {
                    ignore = true
                }
                break
            }
            _ = scanner.scanString("=")
            let value = scanner.scanString("\"") != nil
                ? { let v = scanner.scanUpToString("\""); _ = scanner.scanString("\""); return v }()
                : scanner.scanUpToCharacters(from: .whitespaces)
            switch key.trimmingCharacters(in: .whitespaces).lowercased() {
            case "name": name = value
            case "cwd": cwd = value
            case "ignore": ignore = (value?.lowercased() == "true" || value == "1")
            default: break
            }
        }
        return (name, cwd, ignore)
    }

    private static func stripInlineComment(from line: String) -> String {
        var inQuotes = false
        var result = ""
        for char in line {
            if char == "\"" {
                inQuotes.toggle()
                result.append(char)
            } else if char == "#", !inQuotes {
                break
            } else {
                result.append(char)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private static func splitKeywordAndValue(_ line: String) -> (String, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let ch = trimmed[index]
            if ch == " " || ch == "\t" || ch == "=" { break }
            index = trimmed.index(after: index)
        }
        let keyword = String(trimmed[..<index])
        guard !keyword.isEmpty, index < trimmed.endIndex else { return nil }
        var rest = trimmed[index...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("=") {
            rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.isEmpty else { return nil }
        return (keyword, rest)
    }

    private static func splitPatterns(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in raw {
            if char == "\"" {
                inQuotes.toggle()
            } else if (char == " " || char == "\t"), !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func resolveIncludePattern(_ pattern: String, relativeTo sshDir: URL) -> [URL] {
        let expanded = (pattern as NSString).expandingTildeInPath
        let fullPattern = expanded.hasPrefix("/")
            ? expanded
            : sshDir.appendingPathComponent(expanded).path
        var globResult = glob_t()
        defer { globfree(&globResult) }
        guard glob(fullPattern, GLOB_TILDE | GLOB_BRACE, nil, &globResult) == 0 else {
            return []
        }
        var urls: [URL] = []
        for i in 0 ..< Int(globResult.gl_pathc) {
            if let cStr = globResult.gl_pathv[i] {
                urls.append(URL(fileURLWithPath: String(cString: cStr)))
            }
        }
        return urls
    }
}
