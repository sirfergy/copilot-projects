import AppKit
import ApplicationServices
import Metal
import ScreenCaptureKit
import SwiftUI
import Vision
import XCTest
import ImageIO
import UniformTypeIdentifiers
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
        var previewFocused = false
    }

    @MainActor
    private final class CommandProbe: NSObject {
        var endRequests = 0
        @objc func endSession(_ sender: Any?) { endRequests += 1 }
    }

    private struct CaptureRoot: View {
        let model: AppModel
        @ObservedObject var navigation: Navigation
        @FocusedValue(\.transcriptImagePreviewPresented) private var imagePreviewPresented

        var body: some View {
            RootView(model: model, showsProjects: $navigation.showsProjects)
                .onChange(of: imagePreviewPresented, initial: true) { _, value in
                    navigation.previewFocused = value == true
                }
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
        var transcriptImagesVerified = false
        var diagnostics: [String: String] = [:]
        var images: [ImageProof] = []
        var transcriptImages: [TranscriptImageProof] = []
        var error: String?
    }

    private struct TranscriptImageProof: Codable {
        let file: String
        let pixelWidth: Int
        let pixelHeight: Int
        let markerVisible: Bool
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
            let splitKeys = ["projects", "sessions"].map { "NSSplitView Subview Frames copilot-projects.\($0)" }
            let previousSplits = splitKeys.map { UserDefaults.standard.object(forKey: $0) }
            for key in splitKeys { UserDefaults.standard.removeObject(forKey: key) }
            defer {
                for (key, value) in zip(splitKeys, previousSplits) {
                    if let value { UserDefaults.standard.set(value, forKey: key) }
                    else { UserDefaults.standard.removeObject(forKey: key) }
                }
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
            model.selectSession(projectId: project.id, sessionId: sessions[0].id)
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
            window.contentViewController = NSHostingController(rootView: CaptureRoot(model: model, navigation: navigation))
            defer {
                window.orderOut(nil)
                window.contentViewController = nil
                window.contentView = nil
                window.close()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            let marker = "NATIVE TERMINAL PIXELS"

            try await waitFor("The fixture did not lay out its terminal.") { terminal.bounds.width >= 420 }
            let rootView = try XCTUnwrap(window.contentView)
            // A client query materializes SwiftUI's lazy accessibility tree.
            // Keep the main actor available for AppKit to answer this own-process request.
            let accessibilityResult = await Task.detached {
                let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                var windows: CFTypeRef?
                return AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
            }.value
            report.diagnostics["accessibilityRequest"] = String(accessibilityResult.rawValue)
            try saveReport()
            try require(accessibilityResult == .success,
                        "The fixture could not query its own accessibility tree: \(accessibilityResult.rawValue).")
            try require(findControl("show-session-details", in: rootView) == nil,
                        "Session details appeared without a transcript or workflow.")
            let transcript = try XCTUnwrap(model.activeTranscriptController)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let snapshot = TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Date(),
                copilotSessionId: "capture-conversation",
                turns: [TranscriptTurn(
                    id: "capture-image-turn", startedAt: Date().addingTimeInterval(-60), endedAt: nil,
                    kind: "user", userContent: "Show the captured design.",
                    assistantMessages: [TranscriptAssistantMessage(
                        id: "capture-image-reply", timestamp: Date(),
                        content: "The image below belongs to this turn."
                    )],
                    tools: [], isAborted: false
                )]
            )
            try encoder.encode(snapshot).write(
                to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessions[0].id)),
                options: .atomic
            )
            transcript.reload()
            do {
                try await waitFor("A late transcript did not reveal the header control.") {
                    rootView.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    return self.findControl("show-session-details", in: rootView) != nil
                }
            } catch {
                report.diagnostics["transcriptLoaded"] = String(transcript.snapshot != nil)
                report.diagnostics["rootAccessibility"] = accessibilitySummary(rootView)
                report.diagnostics["windowAccessibility"] = accessibilitySummary(window)
                if let bitmap = rootView.bitmapImageRepForCachingDisplay(in: rootView.bounds) {
                    rootView.cacheDisplay(in: rootView.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(to: output.appendingPathComponent("images/diagnostic-chrome-only.png"))
                    }
                }
                throw error
            }
            let opener = try XCTUnwrap(findControl("show-session-details", in: rootView))
            report.diagnostics["rootAccessibility"] = accessibilitySummary(rootView)
            try require(opener.accessibilityPerformPress?() == true, "The header control could not be pressed.")
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
            let otherTranscript = try XCTUnwrap(model.activeTranscriptController)
            let otherSnapshot = TranscriptSnapshot(
                schemaVersion: 3, updatedAt: Date(),
                copilotSessionId: "capture-other-conversation", turns: []
            )
            try encoder.encode(otherSnapshot).write(
                to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessions[1].id)),
                options: .atomic
            )
            otherTranscript.reload()
            try await waitFor("The second session's transcript did not reveal its opener.") {
                self.findControl("show-session-details", in: rootView) != nil
            }
            let otherOpener = try XCTUnwrap(findControl("show-session-details", in: rootView))
            try require(otherOpener.accessibilityPerformPress?() == true, "The second session's opener could not be pressed.")
            try await waitFor("The header control targeted the wrong session after selection changed.") {
                model.isTranscriptDrawerOpen(sessionId: sessions[0].id)
                    && model.isTranscriptDrawerOpen(sessionId: sessions[1].id)
                    && self.findControl("hide-session-details", in: rootView) != nil
            }
            let otherCloser = try XCTUnwrap(findControl("hide-session-details", in: rootView))
            try require(otherCloser.accessibilityPerformPress?() == true, "The second session's close control could not be pressed.")
            try await waitFor("Closing the second drawer did not restore its opener.") {
                !model.isTranscriptDrawerOpen(sessionId: sessions[1].id)
                    && self.findControl("hide-session-details", in: rootView) == nil
                    && self.findControl("show-session-details", in: rootView) != nil
            }
            model.selectSession(projectId: project.id, sessionId: sessions[0].id)
            try await waitFor("Switching sessions lost the open drawer.") {
                self.findControl("hide-session-details", in: rootView) != nil
            }
            let closer = try XCTUnwrap(findControl("hide-session-details", in: rootView))
            try require(closer.accessibilityPerformPress?() == true, "The drawer close control could not be pressed.")
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
                    guard let detailsButton = findControl("show-session-details", in: rootView) else {
                        throw captureError("\(name) is missing its closed-drawer header control.")
                    }
                    let detailsFrame = try XCTUnwrap(detailsButton.accessibilityFrame?())
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
            window.setContentSize(NSSize(width: 1280, height: 800))
            window.appearance = NSAppearance(named: .darkAqua)
            model.openTranscriptDrawer(sessionId: sessions[0].id)
            try await waitFor("The image fixture drawer did not open.") {
                rootView.layoutSubtreeIfNeeded()
                return self.findControl("hide-session-details", in: rootView) != nil
            }
            let unchangedTranscript = model.activeTranscriptController?.snapshot
            let png = try transcriptFixtureImage()
            terminal.consumeProcessOutput(RemoteKittyReplayEncoding.apcFrame(
                control: "a=T,q=2,U=1,f=100,t=d,i=42,r=8,c=40",
                payload: png.base64EncodedString()
            )[...])
            let imageRef = try XCTUnwrap(terminal.kittyImageCapture.retainedImageMetadata().first)
            let imageIdentifier = "transcript-image-42-\(imageRef.version)"
            try await waitFor("A captured image did not appear in the unchanged transcript.") {
                rootView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return self.findControl(imageIdentifier, in: rootView)?.accessibilityLabel?() == "Open transcript image"
            }
            try require(model.activeTranscriptController?.snapshot == unchangedTranscript,
                        "The fixture rewrote the transcript instead of reacting to image availability.")
            for (file, appearance): (String, NSAppearance.Name) in [
                ("macos-transcript-dark.png", .darkAqua),
                ("macos-transcript-light.png", .aqua),
            ] {
                window.appearance = NSAppearance(named: appearance)
                report.transcriptImages.append(try await captureTranscriptImage(
                    window: window, file: file, output: output
                ))
            }
            let commandProbe = CommandProbe()
            let previousMenu = NSApp.mainMenu
            let menu = previousMenu ?? NSMenu()
            let sessionMenuItem = NSMenuItem(title: "Session", action: nil, keyEquivalent: "")
            let sessionMenu = NSMenu(title: "Session")
            let endItem = NSMenuItem(
                title: "End Session", action: #selector(CommandProbe.endSession(_:)), keyEquivalent: "w"
            )
            endItem.target = commandProbe
            endItem.keyEquivalentModifierMask = .command
            sessionMenu.addItem(endItem)
            sessionMenuItem.submenu = sessionMenu
            menu.addItem(sessionMenuItem)
            NSApp.mainMenu = menu
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if AppDelegate.shouldHandleWorkspaceEvent(
                    window: event.window, keyWindow: NSApp.keyWindow, modalWindow: NSApp.modalWindow
                ), event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
                   event.charactersIgnoringModifiers == "w" {
                    commandProbe.endRequests += 1
                    return nil
                }
                return event
            }
            defer {
                if let monitor { NSEvent.removeMonitor(monitor) }
                menu.removeItem(sessionMenuItem)
                NSApp.mainMenu = previousMenu
            }
            func recordPreviewState(_ stage: String, sheet: NSWindow?) throws {
                let loaded = sheet.map {
                    findControl("transcript-image-preview", in: $0, role: nil) != nil
                } ?? false
                let state = "loaded=\(loaded) focusedValue=\(navigation.previewFocused)"
                    + " active=\(NSApp.isActive) key=\(NSApp.keyWindow?.windowNumber ?? -1)"
                    + " parent=\(window.windowNumber) sheet=\(sheet?.windowNumber ?? -1)"
                    + " responder=\(String(describing: sheet?.firstResponder))"
                report.diagnostics[stage] = state
                NSLog("Transcript preview %@: %@", stage, state)
                try saveReport()
            }

            let imageControl = try XCTUnwrap(findControl(imageIdentifier, in: rootView))
            try require(imageControl.accessibilityPerformPress?() == true, "The image preview action failed.")
            try await waitFor("The native image preview did not open.") {
                guard let sheet = window.attachedSheet else { return false }
                sheet.contentView?.layoutSubtreeIfNeeded()
                return self.findControl("close-transcript-image", in: sheet) != nil
                    && self.findControl("transcript-image-preview", in: sheet, role: nil) != nil
            }
            let previewWindow = try XCTUnwrap(window.attachedSheet)
            try await waitFor("Preview focus did not suppress workspace commands.") { navigation.previewFocused }
            try recordPreviewState("initial-preview", sheet: previewWindow)
            try require(!AppDelegate.shouldHandleWorkspaceEvent(
                window: previewWindow, keyWindow: previewWindow, modalWindow: nil
            ), "Preview shortcuts would reach workspace session actions.")
            try require(!AppDelegate.shouldHandleWorkspaceEvent(
                window: window, keyWindow: previewWindow, modalWindow: nil
            ), "The parent window would still intercept preview shortcuts.")
            report.transcriptImages.append(try await captureTranscriptImage(
                window: previewWindow, file: "macos-transcript-preview.png", output: output
            ))
            let previewClose = try XCTUnwrap(findControl("close-transcript-image", in: previewWindow))
            try require(previewClose.accessibilityPerformPress?() == true, "The image preview did not accept Done.")
            try await waitFor("The image preview did not dismiss.") { window.attachedSheet == nil }
            try recordPreviewState("after-done", sheet: window.attachedSheet)
            try await waitFor("Preview focus stayed active after Done.") { !navigation.previewFocused }
            let reopen = try XCTUnwrap(findControl(imageIdentifier, in: rootView))
            try require(reopen.accessibilityPerformPress?() == true, "The image preview could not be reopened.")
            try await waitFor("The reopened image preview did not open.") { window.attachedSheet != nil }
            let commandWindow = try XCTUnwrap(window.attachedSheet)
            try recordPreviewState("reopened-before-loading", sheet: commandWindow)
            try await waitFor("The reopened image preview did not finish loading.") {
                commandWindow.contentView?.layoutSubtreeIfNeeded()
                return self.findControl("transcript-image-preview", in: commandWindow, role: nil) != nil
            }
            try recordPreviewState("reopened-loaded", sheet: commandWindow)
            // AX presses can open a sheet while the runner's application is inactive.
            // Keyboard dispatch needs our own sheet, not the screenshot, to be key.
            commandWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitFor("The reopened image preview did not become the key window.") {
                NSApp.keyWindow === commandWindow
            }
            try recordPreviewState("before-command-w", sheet: commandWindow)
            let generationBeforeCommandW = terminal.remoteContentGeneration
            let closeKey = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: commandWindow.windowNumber, context: nil,
                characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
            ))
            NSApp.sendEvent(closeKey)
            try await waitFor("Command-W did not close the image preview.") { window.attachedSheet == nil }
            try require(commandProbe.endRequests == 0, "Command-W reached a workspace close handler.")
            try require(terminal.remoteContentGeneration == generationBeforeCommandW,
                        "Command-W was echoed into the fixture terminal.")
            try recordPreviewState("after-command-w", sheet: window.attachedSheet)
            try await waitFor("Preview focus stayed active after Command-W.") { !navigation.previewFocused }

            let openForEscape = try XCTUnwrap(findControl(imageIdentifier, in: rootView))
            try require(openForEscape.accessibilityPerformPress?() == true, "The Escape fixture preview could not open.")
            try await waitFor("The Escape fixture preview did not open.") { window.attachedSheet != nil }
            let escapeWindow = try XCTUnwrap(window.attachedSheet)
            try recordPreviewState("escape-before-focus", sheet: escapeWindow)
            escapeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await waitFor("The Escape fixture preview did not take keyboard focus.") {
                NSApp.keyWindow === escapeWindow && self.findControl("close-transcript-image", in: escapeWindow) != nil
            }
            try recordPreviewState("before-escape", sheet: escapeWindow)
            let escape = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: escapeWindow.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53
            ))
            let generationBeforeEscape = terminal.remoteContentGeneration
            NSApp.sendEvent(escape)
            try await waitFor("Escape did not close the image preview.") { window.attachedSheet == nil }
            try require(terminal.remoteContentGeneration == generationBeforeEscape,
                        "Escape was echoed into the fixture terminal instead of being contained by the preview.")
            try require(AppDelegate.shouldHandleWorkspaceEvent(window: window, keyWindow: window, modalWindow: nil),
                        "Closing the preview did not restore workspace shortcuts.")
            try await waitFor("Preview focus stayed active after dismissal.") { !navigation.previewFocused }
            try recordPreviewState("after-escape", sheet: window.attachedSheet)
            try require(model.globalSelectedSessionId == sessions[0].id
                        && model.terminalView(for: sessions[0].id) === terminal
                        && controller.shellPID == terminalPID,
                        "The image preview changed the selected terminal or its process.")
            let openBeforeDelete = try XCTUnwrap(findControl(imageIdentifier, in: rootView))
            try require(openBeforeDelete.accessibilityPerformPress?() == true,
                        "The image preview could not be opened before deletion.")
            try await waitFor("The deletion fixture preview did not open.") { window.attachedSheet != nil }
            terminal.consumeProcessOutput(RemoteKittyReplayEncoding.apcFrame(control: "a=d,d=I,i=42,q=2")[...])
            try await waitFor("Deleted image bytes remained in the inline transcript.") {
                self.findControl(imageIdentifier, in: rootView) == nil
            }
            try require(window.attachedSheet != nil, "Retiring an inline image interrupted its pinned preview.")
            model.selectSession(projectId: project.id, sessionId: sessions[1].id)
            try await waitFor("Changing session did not dismiss the image preview.") {
                window.attachedSheet == nil && self.findControl("hide-session-details", in: rootView) == nil
            }
            try await waitFor("Preview focus stayed active after changing sessions.") { !navigation.previewFocused }
            try recordPreviewState("after-session-change", sheet: window.attachedSheet)
            model.selectSession(projectId: project.id, sessionId: sessions[0].id)
            try await waitFor("The original drawer did not return after the preview test.") {
                self.findControl("hide-session-details", in: rootView) != nil
            }
            terminal.consumeProcessOutput(RemoteKittyReplayEncoding.apcFrame(
                control: "a=T,q=2,U=1,f=100,t=d,i=42,r=8,c=40",
                payload: png.base64EncodedString()
            )[...])
            let restoredRef = try XCTUnwrap(terminal.kittyImageCapture.retainedImageMetadata().first)
            let restoredIdentifier = "transcript-image-42-\(restoredRef.version)"
            try await waitFor("The drawer-close fixture image did not load.") {
                self.findControl(restoredIdentifier, in: rootView)?.accessibilityLabel?() == "Open transcript image"
            }
            let openBeforeDrawerClose = try XCTUnwrap(findControl(restoredIdentifier, in: rootView))
            try require(openBeforeDrawerClose.accessibilityPerformPress?() == true,
                        "The drawer-close fixture preview could not open.")
            try await waitFor("The drawer-close fixture preview did not open.") {
                window.attachedSheet != nil && navigation.previewFocused
            }
            model.closeTranscriptDrawer(sessionId: sessions[0].id)
            try await waitFor("Closing the drawer did not dismiss the image preview and clear focus.") {
                window.attachedSheet == nil && !navigation.previewFocused
                    && self.findControl("hide-session-details", in: rootView) == nil
            }
            try recordPreviewState("after-drawer-close", sheet: window.attachedSheet)
            report.transcriptImagesVerified = true

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
    private func transcriptFixtureImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(red: 0.12, green: 0.28, blue: 0.42, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(red: 0.5, green: 0.78, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 24, y: 250, width: 592, height: 60))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("TRANSCRIPT IMAGE" as NSString).draw(at: NSPoint(x: 24, y: 170), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 36), .foregroundColor: NSColor.white,
        ])
        ("Synthetic capture fixture" as NSString).draw(at: NSPoint(x: 24, y: 100), withAttributes: [
            .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        try require(CGImageDestinationFinalize(destination), "The synthetic PNG could not be encoded.")
        return data as Data
    }

    @MainActor
    private func captureTranscriptImage(window: NSWindow, file: String, output: URL) async throws -> TranscriptImageProof {
        try await Task.sleep(for: .milliseconds(500))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        let captureWindow = window.sheetParent ?? window
        let shared = try XCTUnwrap(content.windows.first { $0.windowID == CGWindowID(captureWindow.windowNumber) })
        let filter = SCContentFilter(desktopIndependentWindow: shared)
        let configuration = SCStreamConfiguration()
        configuration.includeChildWindows = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration
        )
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: output.appendingPathComponent("images/\(file)"), options: .atomic)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ").uppercased()
        try require(text.contains("TRANSCRIPT IMAGE"), "\(file) did not render the captured image pixels: \(text)")
        if window.sheetParent != nil {
            try require(text.contains("IMAGE PREVIEW") || text.contains("100%"),
                        "\(file) did not render the preview controls: \(text)")
        }
        return TranscriptImageProof(file: file, pixelWidth: image.width, pixelHeight: image.height, markerVisible: true)
    }

    @MainActor
    private func accessibilitySummary(_ element: Any, depth: Int = 0) -> String {
        guard depth < 12 else { return "depth limit\n" }
        let node = element as AnyObject
        let line = "\(type(of: element)): role=\(node.accessibilityRole?()?.rawValue ?? "-") "
            + "id=\(node.accessibilityIdentifier?() ?? "-") label=\(node.accessibilityLabel?() ?? "-") "
            + "formalProtocol=\(element is any NSAccessibilityProtocol)\n"
        return line + (node.accessibilityChildren?() ?? []).prefix(80).map {
            accessibilitySummary($0, depth: depth + 1)
        }.joined()
    }

    @MainActor
    private func findControl(
        _ identifier: String, in element: Any, role: NSAccessibility.Role? = .button
    ) -> AnyObject? {
        // SwiftUI virtual nodes expose public ObjC getters without full protocol conformance.
        let node = element as AnyObject
        if node.accessibilityIdentifier?() == identifier,
           role == nil || node.accessibilityRole?() == role { return node }
        for child in node.accessibilityChildren?() ?? [] {
            if let match = findControl(identifier, in: child, role: role) { return match }
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
