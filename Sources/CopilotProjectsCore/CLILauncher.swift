import Foundation
import Darwin

public enum CLILauncher {
    @discardableResult
    public static func install(in directory: URL) throws -> String {
        guard let executable = RunningExecutable.url else {
            throw InstallError.unresolvedExecutable
        }
        return try install(executable: executable, in: directory)
    }

    @discardableResult
    static func install(
        executable: URL,
        in directory: URL,
        rename: (String, String, UInt32) throws -> Int32 = { renamex_np($0, $1, $2) }
    ) throws -> String {
        let fm = FileManager.default
        guard let executable = RunningExecutable.canonicalURL(for: executable.path),
              let source = try status(at: executable),
              source.st_mode & S_IFMT == S_IFREG,
              fm.isExecutableFile(atPath: executable.path) else {
            throw InstallError.unresolvedExecutable
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("copilot-projects")
        if let existing = try status(at: link) {
            if isCurrentExecutable(existing, at: link, executable: executable, source: source) {
                return "CLI already available at \(link.path)"
            }
            guard existing.st_mode & S_IFMT == S_IFLNK else {
                throw InstallError.destinationExists(link.path)
            }
        }

        // Stage beside the destination so readers see either the old launcher
        // or the complete new one, never a missing or partially written link.
        let staged = directory.appendingPathComponent(".copilot-projects.\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: staged.path, withDestinationPath: executable.path)
        defer {
            if unlink(staged.path) != 0 && errno != ENOENT {
                NSLog("copilot-projects: could not remove staged CLI symlink at %@: %s", staged.path, strerror(errno))
            }
        }

        // Check again after staging, and don't overwrite a newly created file
        // when the destination was absent.
        let latest = try status(at: link)
        if let latest {
            if isCurrentExecutable(latest, at: link, executable: executable, source: source) {
                return "CLI already available at \(link.path)"
            }
            guard latest.st_mode & S_IFMT == S_IFLNK else {
                throw InstallError.destinationExists(link.path)
            }
        }
        let result = try rename(staged.path, link.path, latest == nil ? UInt32(RENAME_EXCL) : 0)
        guard result == 0 else {
            let code = errno
            if latest == nil && code == EEXIST {
                if let existing = try status(at: link),
                   isCurrentExecutable(existing, at: link, executable: executable, source: source) {
                    return "CLI already available at \(link.path)"
                }
                throw InstallError.destinationChanged(link.path)
            }
            throw InstallError.io("replace CLI launcher at \(link.path)", code)
        }
        return "Linked \(link.path) -> \(executable.path)"
    }

    private static func isCurrentExecutable(_ info: stat, at link: URL, executable: URL, source: stat) -> Bool {
        if info.st_mode & S_IFMT == S_IFLNK {
            return RunningExecutable.canonicalURL(for: link.path) == executable
        }
        return info.st_dev == source.st_dev && info.st_ino == source.st_ino
    }

    private static func status(at url: URL) throws -> stat? {
        var info = stat()
        if lstat(url.path, &info) == 0 { return info }
        if errno == ENOENT { return nil }
        throw InstallError.io("inspect \(url.path)", errno)
    }

    private enum InstallError: Error, CustomStringConvertible {
        case unresolvedExecutable
        case destinationExists(String)
        case destinationChanged(String)
        case io(String, Int32)

        var description: String {
            switch self {
            case .unresolvedExecutable:
                return "could not resolve the running executable; run install-cli from the app's executable"
            case .destinationExists(let path):
                return "refusing to replace non-symlink at \(path); move it aside or choose another --dir"
            case .destinationChanged(let path):
                return "CLI destination changed during installation at \(path); inspect it before retrying or choose another --dir"
            case .io(let operation, let code):
                return "could not \(operation): \(String(cString: strerror(code))) (errno \(code))"
            }
        }
    }
}
