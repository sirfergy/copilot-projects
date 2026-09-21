import AppKit
import Metal
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
@testable import CopilotProjectsHost

final class WorkspaceCaptureTests: XCTestCase {
    @MainActor
    private final class CaptureWindow: NSWindow {
        var responderChanges = 0

        override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
            let previous = firstResponder
            let accepted = super.makeFirstResponder(responder)
            if accepted && firstResponder !== previous { responderChanges += 1 }
            return accepted
        }
    }

    @MainActor
    private final class Navigation: ObservableObject {
        @Published var showsProjects = true
    }

    private struct CaptureRoot: View {
        let model: AppModel
        @ObservedObject var navigation: Navigation

        var body: some View {
            RootView(model: model, showsProjects: $navigation.showsProjects)
        }
    }

    private struct ImageProof: Codable {
        let file: String
        let requestedWidth: Int
        let requestedHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let backingScale: Double
        let appearance: String
        let renderer: String
        let terminalMarkerVisible: Bool
        let projectsVisible: Bool
        let terminalWidth: Double
    }

    private struct Report: Codable {
        let sourceSHA: String
        let osVersion: String
        var completed = false
        var collapseVerified = false
        var emptyProjectCollapseVerified = false
        var focusedTerminalCollapseVerified = false
        var detailsHeaderVerified = false
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
            let splitKey = "NSSplitView Subview Frames copilot-projects.sessions"
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
            let controller = try XCTUnwrap(model.controller(for: sessions[0].id))
            let terminal = controller.terminalView
            let terminalPID = controller.shellPID
            model.setStatus(sessionId: sessions[1].id, status: .waiting, text: nil, timestamp: 100)
            let window = CaptureWindow(
                contentRect: NSRect(x: 40, y: 40, width: 1280, height: 800),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = "Copilot Projects - synthetic workspace"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            let navigation = Navigation()
            window.contentView = NSHostingView(rootView: CaptureRoot(model: model, navigation: navigation))
            defer {
                window.orderOut(nil)
                window.contentView = nil
                window.close()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let marker = "NATIVE TERMINAL PIXELS"

            try await waitFor("The fixture did not lay out its terminal.") { terminal.bounds.width >= 420 }
            let rootView = try XCTUnwrap(window.contentView)
            try require(findControl("show-session-details", in: rootView) == nil,
                        "Session details appeared without a transcript or workflow.")
            let transcript = try XCTUnwrap(model.activeTranscriptController)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let snapshot = TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Date(),
                copilotSessionId: "capture-conversation", turns: []
            )
            try encoder.encode(snapshot).write(
                to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessions[0].id)),
                options: .atomic
            )
            transcript.reload()
            try await waitFor("A late transcript did not reveal the header control.") {
                self.findControl("show-session-details", in: rootView) != nil
            }
            let opener = try XCTUnwrap(findControl("show-session-details", in: rootView))
            try require(opener.accessibilityPerformPress(), "The header control could not be pressed.")
            try await waitFor("The header control did not open this session's details.") {
                model.isTranscriptDrawerOpen(sessionId: sessions[0].id)
                    && self.findControl("hide-session-details", in: rootView) != nil
                    && self.findControl("show-session-details", in: rootView) == nil
            }
            model.selectSession(projectId: project.id, sessionId: sessions[1].id)
            try await waitFor("The details control leaked into a session without details.") {
                self.findControl("show-session-details", in: rootView) == nil
                    && self.findControl("hide-session-details", in: rootView) == nil
            }
            try require(!model.isTranscriptDrawerOpen(sessionId: sessions[1].id),
                        "Opening details changed another session's drawer state.")
            model.selectSession(projectId: project.id, sessionId: sessions[0].id)
            try await waitFor("Switching sessions lost the open drawer.") {
                self.findControl("hide-session-details", in: rootView) != nil
            }
            let closer = try XCTUnwrap(findControl("hide-session-details", in: rootView))
            try require(closer.accessibilityPerformPress(), "The drawer close control could not be pressed.")
            try await waitFor("Closing the drawer did not restore the header control.") {
                !model.isTranscriptDrawerOpen(sessionId: sessions[0].id)
                    && self.findControl("show-session-details", in: rootView) != nil
            }
            try require(model.terminalView(for: sessions[0].id) === terminal
                        && controller.shellPID == terminalPID, "Details replaced or restarted the terminal.")
            report.detailsHeaderVerified = true

            var originalContainer: TerminalsContainerView?
            var compactTerminalWidth: CGFloat?
            for (name, appearance, width, height, projectsVisible): (String, NSAppearance.Name, Int, Int, Bool) in [
                ("macos-dark", .darkAqua, 1280, 800, true),
                ("macos-light", .aqua, 1280, 800, true),
                ("macos-compact", .darkAqua, 820, 520, true),
                ("macos-compact-projects-hidden", .darkAqua, 820, 520, false),
            ] {
                if !projectsVisible {
                    let rootView = try XCTUnwrap(window.contentView)
                    let projects = try XCTUnwrap(findView(NSTableView.self, in: rootView))
                    XCTAssertTrue(window.makeFirstResponder(projects))
                }
                navigation.showsProjects = projectsVisible
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
                    let container = try XCTUnwrap(findView(
                        TerminalsContainerView.self, in: try XCTUnwrap(window.contentView)
                    ))
                    if let originalContainer {
                        try require(container === originalContainer, "Navigation remounted the terminal container.")
                    } else {
                        originalContainer = container
                    }
                    try require(model.terminalView(for: sessions[0].id) === terminal
                                && controller.shellPID == terminalPID,
                                "Navigation replaced or restarted the terminal.")
                    try require(terminal.bounds.width >= 420, "Navigation squeezed the terminal below its width contract.")
                    let detailsButton = try XCTUnwrap(findControl(
                        "show-session-details", in: try XCTUnwrap(window.contentView)
                    ))
                    let detailsFrame = detailsButton.accessibilityFrame()
                    let terminalFrame = window.convertToScreen(terminal.convert(terminal.bounds, to: nil))
                    try require(detailsFrame.width > 0 && detailsFrame.minY >= terminalFrame.maxY
                                && detailsFrame.maxY <= terminalFrame.maxY + 56,
                                "The details control is not inside the session heading above the terminal.")
                    try require(detailsFrame.maxX <= terminalFrame.maxX
                                && detailsFrame.maxX >= terminalFrame.maxX - 70,
                                "The details control is not at the trailing end of the session heading.")
                    if !projectsVisible {
                        let previousWidth = try XCTUnwrap(compactTerminalWidth)
                        try require(terminal.bounds.width > previousWidth + 80,
                                    "Hiding Projects did not reclaim terminal width.")
                        try require(window.firstResponder === terminal,
                                    "Hiding Projects left keyboard focus in the hidden browser.")
                        report.collapseVerified = true
                    }
                    terminal.forceRedraw()
                    report.diagnostics["terminalModelContainsMarker"] = String(
                        terminal.terminalStateSnapshot().visibleRows.contains { $0.text.contains(marker) }
                    )
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
                            backingScale: Double(scale),
                            appearance: window.effectiveAppearance.name.rawValue,
                            renderer: terminal.rendererName,
                            terminalMarkerVisible: true,
                            projectsVisible: projectsVisible,
                            terminalWidth: Double(terminal.bounds.width)
                        ))
                        if name == "macos-compact" { compactTerminalWidth = terminal.bounds.width }
                        captured = true
                        break
                    }
                }
                try require(captured, "\(name) did not contain the rendered Metal terminal marker.")
            }
            navigation.showsProjects = true
            try await Task.sleep(for: .milliseconds(500))
            model.focusActiveTerminal()
            try require(window.firstResponder === terminal, "The terminal did not accept focus before collapse.")
            let responderChanges = window.responderChanges
            navigation.showsProjects = false
            try await Task.sleep(for: .milliseconds(500))
            try require(window.firstResponder === terminal && window.responderChanges == responderChanges,
                        "Hiding Projects blurred and refocused the active terminal.")
            report.focusedTerminalCollapseVerified = true

            navigation.showsProjects = true
            let emptyProject = try XCTUnwrap(model.projects.first { $0.sessions.isEmpty })
            model.selectProject(emptyProject.id)
            try await Task.sleep(for: .milliseconds(500))
            window.contentView?.layoutSubtreeIfNeeded()
            let projects = try XCTUnwrap(findView(NSTableView.self, in: try XCTUnwrap(window.contentView)))
            XCTAssertTrue(window.makeFirstResponder(projects))
            navigation.showsProjects = false
            try await Task.sleep(for: .milliseconds(500))
            window.contentView?.layoutSubtreeIfNeeded()
            let hiddenTableHasFocus = (window.firstResponder as? NSView)?.isDescendant(of: projects) ?? false
            try require(!hiddenTableHasFocus, "Empty-project collapse left focus in the hidden browser.")
            report.emptyProjectCollapseVerified = true
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

    @MainActor
    private func findControl(_ identifier: String, in element: Any) -> (any NSAccessibilityProtocol)? {
        guard let node = element as? any NSAccessibilityProtocol else { return nil }
        if node.accessibilityIdentifier() == identifier, node.accessibilityRole() == .button { return node }
        for child in node.accessibilityChildren() ?? [] {
            if let match = findControl(identifier, in: child) { return match }
        }
        return nil
    }

    @MainActor
    private func waitFor(_ message: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw captureError(message)
    }

    @MainActor
    private func findView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = findView(type, in: child) { return match }
        }
        return nil
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw captureError(message) }
    }
}
