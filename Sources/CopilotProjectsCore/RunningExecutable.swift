import Foundation
import Darwin

/// The executable selected by dyld, not argv[0] (which can be a bare PATH name).
public enum RunningExecutable {
    public static var url: URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return canonicalURL(for: String(cString: buffer))
    }

    public static var applicationBundle: Bundle? {
        guard let executable = url,
              let appURL = applicationBundleURL(for: executable) else { return nil }
        return Bundle(url: appURL)
    }

    static func canonicalURL(for path: String) -> URL? {
        // Runtime paths must be absolute. Never interpret a bare argv[0] as a
        // file in the current directory, even if an executable exists there.
        guard path.hasPrefix("/"), let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved))
    }

    static func applicationBundleURL(for executable: URL) -> URL? {
        let binaryDirectory = executable.deletingLastPathComponent()
        let contents = binaryDirectory.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard binaryDirectory.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              app.pathExtension == "app" else { return nil }
        return app
    }
}
