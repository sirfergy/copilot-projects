import AppKit
import Metal
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
import CopilotProjectsCore
@testable import CopilotProjectsHost

final class WorkspaceCaptureTests: XCTestCase {
    private struct ImageProof: Codable {
        let file: String
        let requestedWidth: Int
        let requestedHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let backingScale: Double
        let renderer: String
        let terminalMarkerVisible: Bool
    }

    private struct Report: Codable {
        let sourceSHA: String
        let osVersion: String
        var completed = false
        var diagnostics: [String: String] = [:]
        var images: [ImageProof] = []
        var error: String?
    }

    @MainActor
    func testNativeWorkspaceCapture() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let outputPath = env["WORKSPACE_CAPTURE_ROOT"] else {
            throw XCTSkip("Native capture is opt-in through the Actions workflow.")
        }
        try require(env["GITHUB_ACTIONS"] == "true" && env["RUNNER_TRACKING_ID"] != nil,
                    "Capture requires the Actions runner.")
        let output = URL(fileURLWithPath: outputPath).resolvingSymlinksInPath()
        let runnerTemp = URL(fileURLWithPath: try XCTUnwrap(env["RUNNER_TEMP"])).resolvingSymlinksInPath()
        try require(output.deletingLastPathComponent().path == runnerTemp.path
                    && output.lastPathComponent.hasPrefix("workspace-capture."),
                    "Capture output is outside its private runner directory.")
        let sandbox = output.appendingPathComponent("sandbox")
        let state = sandbox.appendingPathComponent("state")
        try require(env["HOME"] == sandbox.appendingPathComponent("home").path
                    && env["TMPDIR"] == sandbox.appendingPathComponent("tmp").path
                    && env["SHELL"] == "/bin/cat", "Capture environment is not isolated.")
        let sourceSHA = try XCTUnwrap(env["CAPTURE_SOURCE_SHA"])
        var report = Report(
            sourceSHA: sourceSHA,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
        func saveReport() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: output.appendingPathComponent("metadata.json"), options: .atomic)
        }
        try saveReport()
        do {
            let keys = ["COPILOT_PROJECTS_STATE_DIR", "COPILOT_PROJECTS_SOCKET",
                        "COPILOT_PROJECTS_DEFAULT_DIR", "COPILOT_PROJECTS_DTACH"]
            let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, env[$0]) })
            defer {
                for (key, value) in previous {
                    if let value { setenv(key, value, 1) } else { unsetenv(key) }
                }
            }
            setenv("COPILOT_PROJECTS_STATE_DIR", state.path, 1)
            setenv("COPILOT_PROJECTS_SOCKET", state.appendingPathComponent("control.sock").path, 1)
            setenv("COPILOT_PROJECTS_DEFAULT_DIR", state.path, 1)
            unsetenv("COPILOT_PROJECTS_DTACH")
            try require(Paths.stateDir.resolvingSymlinksInPath().path == state.path
                        && Paths.dtachExecutable == nil, "State or terminal backend is not isolated.")
            report.diagnostics["metalDevice"] = MTLCreateSystemDefaultDevice()?.name ?? "unavailable"
            report.diagnostics["screenCapturePreflight"] = String(CGPreflightScreenCaptureAccess())
            report.diagnostics["increasedContrast"] = String(NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
            report.diagnostics["reducedTransparency"] = String(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
            try saveReport()

            _ = NSApplication.shared
            let previousPolicy = NSApp.activationPolicy()
            let previousApp = NSWorkspace.shared.frontmostApplication
            let splitKey = "NSSplitView Subview Frames copilot-projects.sidebar"
            let previousSplit = UserDefaults.standard.object(forKey: splitKey)
            UserDefaults.standard.removeObject(forKey: splitKey)
            defer {
                if let previousSplit { UserDefaults.standard.set(previousSplit, forKey: splitKey) }
                else { UserDefaults.standard.removeObject(forKey: splitKey) }
                if NSApp.isActive, previousApp?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                    previousApp?.activate(options: [])
                }
                NSApp.setActivationPolicy(previousPolicy)
            }
            NSApp.setActivationPolicy(.regular)
            NSApp.finishLaunching()
            report.diagnostics["activationPolicy"] = String(NSApp.activationPolicy().rawValue)
            report.diagnostics["screenCount"] = String(NSScreen.screens.count)
            try saveReport()
            try require(!NSScreen.screens.isEmpty, "The runner has no graphical display session.")

            let sessions = [
                Session(title: "Keyboard navigation", cwd: state.path),
                Session(title: "Review the changes", cwd: state.path),
                Session(title: "Documentation", cwd: state.path),
            ]
            let project = Project(name: "Atlas", cwd: state.path, sessions: sessions,
                                  selectedSessionId: sessions[0].id)
            let repository = StateRepository(path: state.appendingPathComponent("state.json"))
            try repository.save(PersistedState(
                projects: [project, Project(name: "API service", cwd: state.path)],
                selectedProjectId: project.id
            ))
            let model = AppModel(
                stateRepository: repository, persistPermissionStatus: { _, _, _, _ in },
                isAppActive: { true }, agentActivityDirectory: state, resumeMarkerDirectory: state,
                kittyImageDiskStore: RemoteKittyImageDiskStore(root: state.appendingPathComponent("images")),
                alertPresenter: { alert in
                    XCTFail("The isolated fixture attempted an alert: \(alert.messageText)")
                    return .alertFirstButtonReturn
                }
            )
            defer { model.detachAllClients() }
            model.setStatus(sessionId: sessions[1].id, status: .waiting, text: nil, timestamp: 100)
            let window = NSWindow(
                contentRect: NSRect(x: 40, y: 40, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Copilot Projects - synthetic workspace"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: RootView(model: model))
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(500))
            let terminal = try XCTUnwrap(model.terminalView(for: sessions[0].id))
            let marker = "NATIVE TERMINAL PIXELS"

            for (name, appearance, width, height): (String, NSAppearance.Name, Int, Int) in [
                ("macos-dark", .darkAqua, 1280, 800),
                ("macos-light", .aqua, 1280, 800),
                ("macos-compact", .darkAqua, 820, 520),
            ] {
                window.appearance = try XCTUnwrap(NSAppearance(named: appearance))
                window.setContentSize(NSSize(width: CGFloat(width), height: CGFloat(height)))
                window.contentView?.layoutSubtreeIfNeeded()
                terminal.feed(text: "\u{1b}[2J\u{1b}[H"
                    + "\(marker)\r\n\r\n"
                    + "Synthetic workspace for visual review.\r\n"
                    + "No live sessions or project files are used.\r\n\r\n"
                    + "Atlas / Keyboard navigation\r\n\r\n"
                    + "> Keep project and session switching clear.\r\n\r\n"
                    + "  Selection and ending remain separate actions.\r\n"
                    + "  Existing terminal input behavior is preserved.\r\n\r\n$ ")
                var captured = false
                for attempt in 1...3 {
                    try await Task.sleep(for: .milliseconds(500))
                    window.contentView?.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    let content = try await SCShareableContent.currentProcess
                    report.diagnostics["ownWindowCount"] = String(content.windows.count)
                    report.diagnostics["windowVisible"] = String(window.isVisible)
                    report.diagnostics["windowIsKey"] = String(window.isKeyWindow)
                    report.diagnostics["windowOcclusion"] = String(window.occlusionState.rawValue)
                    report.diagnostics["renderer"] = terminal.rendererName
                    try saveReport()
                    guard let shared = content.windows.first(where: {
                        $0.windowID == CGWindowID(window.windowNumber)
                    }) else {
                        if attempt < 3 { continue }
                        throw captureError("The fixture window is not shareable.")
                    }
                    let scale = window.backingScaleFactor
                    let config = SCStreamConfiguration()
                    config.width = Int(window.frame.width * scale)
                    config.height = Int(window.frame.height * scale)
                    config.showsCursor = false
                    let image = try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: shared),
                        configuration: config
                    )
                    let file = "\(name).png"
                    let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image)
                        .representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("images/\(file)"), options: .atomic)
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.recognitionLanguages = ["en-US"]
                    request.usesLanguageCorrection = false
                    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .joined(separator: " ").uppercased().split(whereSeparator: \.isWhitespace)
                        .joined(separator: " ")
                    report.diagnostics["lastOCR"] = text
                    try saveReport()
                    if terminal.rendererName == "metal" && text.contains(marker) {
                        report.images.append(ImageProof(
                            file: file, requestedWidth: width, requestedHeight: height,
                            pixelWidth: image.width, pixelHeight: image.height,
                            backingScale: Double(scale), renderer: terminal.rendererName,
                            terminalMarkerVisible: true
                        ))
                        captured = true
                        break
                    }
                }
                try require(captured, "\(name) did not contain the rendered Metal terminal marker.")
            }
            report.completed = true
            try saveReport()
        } catch {
            let error = error as NSError
            report.error = "\(error.domain) \(error.code): \(error.localizedDescription)"
            try saveReport()
            throw error
        }
    }

    private func captureError(_ message: String) -> NSError {
        NSError(domain: "WorkspaceCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw captureError(message) }
    }
}
