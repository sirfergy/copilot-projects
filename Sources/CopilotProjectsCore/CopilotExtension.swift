import Foundation

public enum CopilotExtension {
    public static var extensionsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/extensions", isDirectory: true)
    }

    public static var extensionDir: URL {
        extensionsDir.appendingPathComponent("copilot-projects-tracker", isDirectory: true)
    }

    public static var scriptURL: URL {
        scriptURL(in: extensionDir)
    }

    /// The tracker is a single top-level entry point, so installing it is one
    /// atomic file write into an existing directory — never a directory swap
    /// that could race an active session or discard files the user put there.
    public static func scriptURL(in directory: URL) -> URL {
        directory.appendingPathComponent("extension.mjs")
    }

    /// The tracker extension's source, loaded once from the packaged resource
    /// bundle and cached for the lifetime of the process. These are the exact
    /// bytes `install()` writes to `scriptURL`.
    public static let script = PackagedResource.text(
        "extension",
        extension: "mjs",
        subdirectory: "tracker",
        in: resourceBundle
    )

    public static func packagedAssetAvailable(anchor: Bundle = .main) -> Bool {
        guard let bundle = PackagedResource.locate(
            named: "copilot-projects_CopilotProjectsCore",
            anchor: anchor
        ), let url = bundle.url(
            forResource: "extension",
            withExtension: "mjs",
            subdirectory: "tracker"
        ), let data = try? Data(contentsOf: url),
           !data.isEmpty,
           String(data: data, encoding: .utf8) != nil else {
            return false
        }
        return true
    }

    private final class BundleToken {}

    /// Resolved once per process. Requires
    /// `resources: [.copy("Resources/tracker")]` on the `CopilotProjectsCore`
    /// target.
    private static let resourceBundle = PackagedResource.bundle(
        named: "copilot-projects_CopilotProjectsCore",
        anchor: Bundle(for: BundleToken.self),
        developmentBundle: Bundle.module
    )

    @discardableResult
    public static func install() throws -> String {
        try install(in: extensionDir)
    }

    /// Installs into an explicit directory. `install()` is exactly this call
    /// against the global `~/.copilot/extensions/copilot-projects-tracker`
    /// location, so tooling and tests can exercise the real write path without
    /// touching the user's Copilot CLI installation.
    @discardableResult
    public static func install(in directory: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(script.utf8).write(to: scriptURL(in: directory), options: .atomic)
        return "Installed Copilot Projects extension in \(directory.path). "
            + "Restart existing Copilot CLI sessions to activate it."
    }

    public static func uninstall() {
        try? FileManager.default.removeItem(at: extensionDir)
    }

    public static func installIfPossible() {
        guard CopilotHooks.copilotPresent, !upToDate() else { return }
        _ = try? install()
    }

    private static func upToDate() -> Bool {
        upToDate(in: extensionDir)
    }

    /// Whether `directory` already holds exactly the packaged script, i.e.
    /// whether `install(in:)` would be a no-op rewrite.
    public static func upToDate(in directory: URL) -> Bool {
        (try? String(contentsOf: scriptURL(in: directory), encoding: .utf8)) == script
    }
}

/// Locates SwiftPM resource bundles and loads packaged text assets from them.
///
/// Resolution is deliberately packaging-relative only: there is no
/// current-directory probe and no developer-absolute fallback, so a build that
/// forgets to copy a resource bundle into the app fails here the same way on
/// the machine that produced it as it would on a user's machine. Inside a
/// shipped `.app` the packaged copy is mandatory and SwiftPM's own
/// `Bundle.module` — whose last resort is the absolute path of the build
/// directory that produced the binary — is never consulted.
///
/// A missing packaged asset is a packaging defect, not a runtime condition, so
/// it traps with the searched paths rather than degrading to a blank surface.
public enum PackagedResource {
    /// Finds `<name>.bundle` next to the running binary's packaged resources.
    ///
    /// - Parameters:
    ///   - name: SwiftPM's generated bundle name, `<package>_<target>`.
    ///   - anchor: `Bundle(for:)` of a class in the owning target, which
    ///     resolves to the `.xctest` bundle under `swift test`.
    ///   - developmentBundle: SwiftPM's `Bundle.module` for the owning target,
    ///     consulted only outside an application bundle (tests and `swift run`).
    public static func bundle(
        named name: String,
        anchor: Bundle,
        developmentBundle: @autoclosure () -> Bundle?
    ) -> Bundle {
        let layout = layout(anchor: anchor)
        if let bundle = locate(named: name, in: layout) {
            return bundle
        }
        if !layout.isApplicationBundle, let bundle = developmentBundle() {
            return bundle
        }
        let searched = layout.bases
            .map { $0.appendingPathComponent("\(name).bundle", isDirectory: true).path }
        fatalError(
            "copilot-projects: packaged resource bundle \(name).bundle is missing. Searched: "
                + (searched.isEmpty ? "<no candidate locations>" : searched.joined(separator: ", "))
        )
    }

    /// The non-trapping form of `bundle(named:anchor:developmentBundle:)`, for
    /// callers (tests, packaging checks) that want to report a miss themselves.
    public static func locate(named name: String, anchor: Bundle) -> Bundle? {
        locate(named: name, in: layout(anchor: anchor))
    }

    private static func locate(named name: String, in layout: Layout) -> Bundle? {
        let fileName = "\(name).bundle"
        for base in layout.bases {
            let url = base.appendingPathComponent(fileName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let bundle = Bundle(url: url)
            else { continue }
            return bundle
        }
        return nil
    }

    /// Loads a packaged UTF-8 text resource.
    ///
    /// The trailing newline every well-formed text file ends with is dropped so
    /// the returned value matches the multi-line Swift literal these assets were
    /// extracted from byte for byte — which also matters because the web
    /// fragments are joined into one script with explicit newline boundaries.
    public static func text(
        _ name: String,
        extension fileExtension: String,
        subdirectory: String? = nil,
        in bundle: Bundle
    ) -> String {
        let described = [subdirectory, "\(name).\(fileExtension)"]
            .compactMap { $0 }
            .joined(separator: "/")
        guard let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            fatalError(
                "copilot-projects: packaged resource \(described) is missing from "
                    + bundle.bundlePath
            )
        }
        guard let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8)
        else {
            fatalError("copilot-projects: packaged resource \(url.path) is not readable UTF-8")
        }
        return contents.hasSuffix("\n") ? String(contents.dropLast()) : contents
    }

    private struct Layout {
        var bases: [URL]
        var isApplicationBundle: Bool
    }

    private static func layout(anchor: Bundle) -> Layout {
        var bases: [URL] = []
        func add(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            guard !bases.contains(where: { $0.standardizedFileURL == standardized }) else { return }
            bases.append(url)
        }

        // The CLI is installed as a symlink (~/.local/bin/copilot-projects ->
        // <app>/Contents/MacOS/copilot-projects), so the running binary is
        // resolved through symlinks before deciding whether this is an app.
        var isApplicationBundle = false
        if let executable = RunningExecutable.url {
            if let appURL = RunningExecutable.applicationBundleURL(for: executable) {
                isApplicationBundle = true
                add(appURL.appendingPathComponent("Contents/Resources", isDirectory: true))
            } else {
                add(executable.deletingLastPathComponent())
            }
        }

        // Through a launcher, Bundle.main and the anchor may describe the
        // launcher's directory. Never use them as fallbacks for a packaged app.
        if !isApplicationBundle {
            add(Bundle.main.resourceURL)
            add(Bundle.main.bundleURL)
            add(anchor.resourceURL)
            add(anchor.bundleURL)
            // Under `swift test` the anchor is the .xctest bundle and SwiftPM
            // leaves resource bundles beside it in the build directory.
            add(anchor.bundleURL.deletingLastPathComponent())
        }
        return Layout(bases: bases, isApplicationBundle: isApplicationBundle)
    }
}
