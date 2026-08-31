import Foundation
import CopilotProjectsProtocol
import CopilotProjectsCore

/// Facade over the packaged web client. Every asset is a real file under
/// `Sources/copilot-projects/Resources/web` (packaged into
/// `copilot-projects_copilot-projects.bundle`); the properties here only load
/// and cache them, so the served bytes are exactly the reviewed source bytes.
enum RemoteWebAssets {
    static let html = text("index", "html")

    static let manifest = text("app", "webmanifest")

    static let serviceWorker = text("service-worker", "js")

    static func iconPNG(size: Int) -> Data? {
        let name: String
        switch size {
        case 192: name = "PWAIcon-192"
        case 512: name = "PWAIcon-512"
        default: return nil
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name).png")
        return try? Data(contentsOf: source)
    }

    static let css = text("app", "css")

    // The client is deliberately bundler-free: each fragment below is a plain
    // script (not a module) and `javascript` concatenates them in this fixed
    // order into the single `/app.js` response, exactly as the previously
    // embedded literals did. Splitting them keeps the pure, DOM-free slices
    // loadable on their own under `node --test` (see `JSTests/`).
    static let markdownJavascript = script("markdown")

    static let draftJavascript = script("draft")

    static let operationsJavascript = script("operations")

    static let controlDeliveryJavascript = script("control-delivery")

    static let sessionCreationJavascript = script("session-creation")

    // Terminal image rendering (Kitty inline image placements advertised via
    // `RemoteTerminalScreen.images`). Kept isolated from DOM-touching code
    // below so the validation/dedup/PNG/byte-cap logic can be exercised
    // directly under Node without a DOM, mirroring `markdownJavascript`.
    static let terminalImageJavascript = script("terminal-image")

    // Conversation transcript rendering: the fetch window, the per-turn card
    // cache, and the stale-response gating. Kept in its own slice (like
    // `markdownJavascript`) so it can be exercised directly under Node with a
    // small DOM shim instead of only asserted as source text. It reads the
    // shared client state declared below (`selected`, `viewMode`, `transcript`,
    // the conversation image helpers) — every entry point runs long after those
    // are initialized.
    static let transcriptJavascript = script("transcript")

    /// Everything that touches the DOM and the live connection. Depends on all
    /// of the fragments above being evaluated first.
    static let mainJavascript = script("main")

    static let javascript = [
        markdownJavascript,
        draftJavascript,
        operationsJavascript,
        controlDeliveryJavascript,
        sessionCreationJavascript,
        terminalImageJavascript,
        transcriptJavascript,
        mainJavascript,
    ].joined(separator: "\n")

    static func packagedAssetsAvailable(anchor: Bundle = .main) -> Bool {
        guard let bundle = PackagedResource.locate(
            named: "copilot-projects_copilot-projects",
            anchor: anchor
        ) else {
            return false
        }
        let textAssets = [
            ("index", "html", "web"),
            ("app", "css", "web"),
            ("app", "webmanifest", "web"),
            ("service-worker", "js", "web"),
            ("markdown", "js", "web/js"),
            ("draft", "js", "web/js"),
            ("operations", "js", "web/js"),
            ("control-delivery", "js", "web/js"),
            ("session-creation", "js", "web/js"),
            ("terminal-image", "js", "web/js"),
            ("transcript", "js", "web/js"),
            ("main", "js", "web/js"),
        ]
        for (name, fileExtension, subdirectory) in textAssets {
            guard let url = bundle.url(
                forResource: name,
                withExtension: fileExtension,
                subdirectory: subdirectory
            ), let data = try? Data(contentsOf: url),
               !data.isEmpty,
               String(data: data, encoding: .utf8) != nil else {
                return false
            }
        }
        return [192, 512].allSatisfy { size in
            guard let url = anchor.url(
                forResource: "PWAIcon-\(size)",
                withExtension: "png"
            ), let data = try? Data(contentsOf: url) else {
                return false
            }
            return !data.isEmpty
        }
    }

    // MARK: - loading

    private final class BundleToken {}

    /// Resolved once per process. Requires
    /// `resources: [.copy("Resources/web")]` on the `copilot-projects` target.
    private static let resourceBundle = PackagedResource.bundle(
        named: "copilot-projects_copilot-projects",
        anchor: Bundle(for: BundleToken.self),
        developmentBundle: Bundle.module
    )

    private static func text(_ name: String, _ fileExtension: String) -> String {
        PackagedResource.text(
            name,
            extension: fileExtension,
            subdirectory: "web",
            in: resourceBundle
        )
    }

    private static func script(_ name: String) -> String {
        PackagedResource.text(
            name,
            extension: "js",
            subdirectory: "web/js",
            in: resourceBundle
        )
    }
}
