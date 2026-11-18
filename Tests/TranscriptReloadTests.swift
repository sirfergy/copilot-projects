import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI
@testable import CopilotProjectsHost

// TEMPORARY MEASUREMENT, removed again before this branch is ready: where the drawer rests, how
// often SwiftUI's own block moves it, and how many turns it renders, under each form of the
// test's display cycles.
fileprivate enum ProbeHelper: String {
    /// Layout and a run-loop step inside a main-queue pass, as on main.
    case old
    /// Layout in a run-loop block, ahead of the display cycle: this branch's helper.
    case block
}

@MainActor fileprivate var probeHelper = ProbeHelper.block
/// Set while a cell is traced line by line.
@MainActor fileprivate var probeCell: String?
/// The cell the test is running under; read where XCTest records a failure.
fileprivate var probeIssueLabel = ""

@MainActor
fileprivate final class DrawerTrace {
    static let shared = DrawerTrace()
    private var start = Date()
    private var signatures: [String: Int] = [:]
    private weak var window: NSWindow?
    private var clipToken: NSObjectProtocol?
    private var lastY: CGFloat?
    private weak var lastClip: NSClipView?
    private(set) var movedUp: CGFloat = 0
    private(set) var pastEnd: CGFloat = 0
    /// The moves SwiftUI's own block made since the last action: points up, negative for down.
    private(set) var ownMoves: [Int] = []

    func line(_ text: String) {
        guard let cell = probeCell else { return }
        print(String(format: "DRAWERMEASURE %@ %8.1f %@", cell, Date().timeIntervalSince(start) * 1000, text))
    }

    /// Counts the clip's moves; they are printed only while a cell is traced.
    func begin(_ window: NSWindow, _ what: String = "") {
        self.window = window
        lastY = nil
        start = Date()
        clipToken = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: nil, queue: nil
        ) { note in
            let stack = Thread.callStackSymbols
            MainActor.assumeIsolated { DrawerTrace.shared.clipMoved(note.object as? NSClipView, stack) }
        }
        let system = ProcessInfo.processInfo.operatingSystemVersionString
        let swiftUI = Bundle(identifier: "com.apple.SwiftUI")?.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        line("BEGIN \(what): macOS \(system) SwiftUI \(swiftUI) displayAsleep=\(CGDisplayIsAsleep(CGMainDisplayID()) != 0) occlusionVisible=\(window.occlusionState.contains(.visible)) helper=\(probeHelper.rawValue)")
    }

    func end() {
        if let clipToken { NotificationCenter.default.removeObserver(clipToken) }
        clipToken = nil
    }

    /// Logs what the test does next, and starts measuring moves from here.
    func action(_ text: String) {
        movedUp = 0
        pastEnd = 0
        ownMoves = []
        line("ACTION " + text)
    }

    private func scrollView() -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView, scrollView.frame.height > 200 { found.append(scrollView) }
            view.subviews.forEach(walk)
        }
        window?.contentView.map(walk)
        return found.max { $0.frame.height < $1.frame.height }
    }

    private func state(_ scrollView: NSScrollView) -> String {
        let clip = scrollView.contentView.bounds
        let docHeight = scrollView.documentView?.frame.height ?? 0
        return "clipY=\(Int(clip.minY)) docH=\(Int(docHeight)) clipH=\(Int(clip.height))"
    }

    func result(_ label: String, snippet: String? = nil) {
        guard probeCell != nil, let window, let scrollView = scrollView(), let doc = scrollView.documentView else { return }
        var texts: [NSTextView] = []
        func walk(_ view: NSView) {
            if let text = view as? NSTextView, !text.string.isEmpty { texts.append(text) }
            view.subviews.forEach(walk)
        }
        walk(doc)
        let visible = scrollView.documentVisibleRect
        let aboveEnd = Int(doc.bounds.height - visible.maxY)
        let marks = ["User prompt for turn", "Short prompt", "Long user prompt for turn"]
        let turns = texts.filter { text in marks.contains { text.string.contains($0) } }.count
        let sees = snippet.map { wanted in
            texts.contains { $0.string.contains(wanted) && doc.convert($0.bounds, from: $0).intersects(visible) }
        }
        // Where the first and the last text sit on screen: points below the top of the window's
        // content, and the last text's bottom above the bottom of the viewport.
        let height = window.contentView?.bounds.height ?? 0
        let rects = texts.map { $0.convert($0.bounds, to: nil) }
        let firstTop = rects.map { Int(height - $0.maxY) }.min()
        let lastBottom = rects.map { Int(height - $0.minY) }.max()
        let lastGap = texts.map { Int(visible.maxY - doc.convert($0.bounds, from: $0).maxY) }.min()
        line("RESULT \(label): rests=\(aboveEnd <= 24 ? "at the end" : "\(aboveEnd) pt above the end") \(state(scrollView)) turnsRendered=\(turns) bottomTurnVisible=\(sees.map(String.init) ?? "-") swiftUIOwnMoves=\(ownMoves) movedUp=\(Int(movedUp)) pastEnd=\(Int(pastEnd)) firstTextTop=\(firstTop.map(String.init) ?? "-") lastTextBottom=\(lastBottom.map(String.init) ?? "-") lastTextAboveViewportBottom=\(lastGap.map(String.init) ?? "-")")
    }

    /// What moved the clip: SwiftUI's own block is told by its frame on the stack.
    private func clipMoved(_ clip: NSClipView?, _ stack: [String]) {
        guard let clip, let scrollView = scrollView(), clip === scrollView.contentView else { return }
        let own = stack.contains { $0.contains("updateAnimationTarget") }
        let inLayout = stack.contains { $0.contains("NSHostingViewC6layout") || $0.contains("layoutSubtreeIfNeeded") }
        let y = clip.bounds.minY
        let docHeight = scrollView.documentView?.frame.height ?? 0
        if lastClip !== clip { lastY = nil }
        lastClip = clip
        if let lastY {
            movedUp = max(movedUp, lastY - y)
            if own { ownMoves.append(Int((lastY - y).rounded())) }
        }
        pastEnd = max(pastEnd, y - max(0, docHeight - clip.bounds.height))
        line("CLIP \(lastY.map { String(Int($0)) } ?? "?")->\(Int(y)) \(state(scrollView)) \(own ? "by SWIFTUI'S OWN BLOCK" : inLayout ? "in a layout" : "by something else")")
        lastY = y
    }
}

final class TranscriptReloadTests: XCTestCase {
    /// TEMPORARY MEASUREMENT: names the cell a failure of the test belongs to.
    override func record(_ issue: XCTIssue) {
        if !probeIssueLabel.isEmpty {
            print("DRAWERMEASURE ISSUE cell=\(probeIssueLabel) line=\(issue.sourceCodeContext.location?.lineNumber ?? 0) \(issue.compactDescription.prefix(220))")
        }
        super.record(issue)
    }

    private func writeSnapshot(sessionId: String, updatedAt: Date) throws {
        Paths.ensureStateDir()
        let snapshot = TranscriptSnapshot(
            schemaVersion: 3,
            updatedAt: updatedAt,
            copilotSessionId: "fixture-conversation",
            turns: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(
            to: URL(fileURLWithPath: Paths.transcriptSnapshotPath(sessionId: sessionId)),
            options: .atomic
        )
    }

    @MainActor
    private func stepMainRunLoopBeforeWaiting() {
        let rl = CFRunLoopGetMain()
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.beforeWaiting.rawValue,
            false,
            CFIndex.max
        ) { _, _ in
            CFRunLoopStop(CFRunLoopGetMain())
        }
        CFRunLoopAddObserver(rl, observer, .defaultMode)
        CFRunLoopRunInMode(.defaultMode, 1.0, false)
        CFRunLoopRemoveObserver(rl, observer, .defaultMode)
    }

    /// Runs `body` in a run-loop block: after the main-queue pass that asks for it, and ahead of
    /// the run loop's display cycle. An app lays out between main-queue passes too. A layout run
    /// inside a pass, between two scrolls the drawer had queued, made SwiftUI apply a scroll one
    /// pass late: the transcript sat 543 pt above the bottom for a pass on 223 of 1,200 returns to
    /// a conversation, and now and then rendered a page nobody scrolled to.
    @MainActor
    private func betweenMainQueuePasses(_ body: @escaping () -> Void = {}) async {
        await withCheckedContinuation { continuation in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                body()
                continuation.resume()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// TEMPORARY MEASUREMENT: the wait between a session switch and its snapshot, in each form.
    @MainActor
    private func probeStepAfterSwitch(_ window: NSWindow) async {
        switch probeHelper {
        case .old:
            stepMainRunLoopBeforeWaiting()
        case .block:
            await betweenMainQueuePasses { window.contentView?.layoutSubtreeIfNeeded() }
        }
    }

    @MainActor
    private func settleDisplayCycle(_ window: NSWindow) async {
        switch probeHelper {
        case .old:
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        continuation.resume()
                    }
                }
                window.contentView?.layoutSubtreeIfNeeded()
                stepMainRunLoopBeforeWaiting()
            }
            window.contentView?.layoutSubtreeIfNeeded()
        case .block:
            for _ in 0..<3 {
                await betweenMainQueuePasses { window.contentView?.layoutSubtreeIfNeeded() }
            }
        }
    }

    @MainActor
    func testBurstSkipsSupersededLoadsAndReadsNewestSnapshot() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let firstDate = Date(timeIntervalSince1970: 1_788_633_600)
        let latestDate = firstDate.addingTimeInterval(60)
        try writeSnapshot(sessionId: sessionId, updatedAt: firstDate)
        var loads = 0
        let controller = TranscriptController(
            sessionId: sessionId,
            snapshotLoadObserver: { loads += 1 }
        )
        for _ in 0 ..< 40 {
            controller.reload(after: 0.05)
        }
        try writeSnapshot(sessionId: sessionId, updatedAt: latestDate)
        for _ in 0 ..< 100 {
            if controller.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(controller.snapshot?.updatedAt, latestDate)
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testImmediateReloadSupersedesAnOlderDelayedLoad() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let date = Date(timeIntervalSince1970: 1_788_633_600)
        try writeSnapshot(sessionId: sessionId, updatedAt: date)
        var loads = 0
        let controller = TranscriptController(
            sessionId: sessionId,
            snapshotLoadObserver: { loads += 1 }
        )
        controller.reload(after: 0.1)
        controller.reload()
        for _ in 0 ..< 100 {
            if controller.snapshot != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.snapshot?.updatedAt, date)
        XCTAssertEqual(loads, 1)
    }

    @MainActor
    func testReleasedControllerDoesNotStartADelayedLoad() async throws {
        var loads = 0
        var controller: TranscriptController? = TranscriptController(
            sessionId: UUID().uuidString,
            snapshotLoadObserver: { loads += 1 }
        )
        weak var released = controller
        controller?.reload(after: 0.05)
        controller = nil
        XCTAssertNil(released)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(loads, 0)
    }

    @MainActor
    func testPollTranscriptIfNeededSkipsUnchangedFilesAndReloadsOnDiskChange() async throws {
        let sessionId = UUID().uuidString
        defer { SessionArtifacts.removeFiles(sessionId: sessionId) }
        let firstDate = Date(timeIntervalSince1970: 1_788_633_600)
        let secondDate = firstDate.addingTimeInterval(120)
        try writeSnapshot(sessionId: sessionId, updatedAt: firstDate)
        var loads = 0
        let controller = TranscriptController(
            sessionId: sessionId,
            snapshotLoadObserver: { loads += 1 }
        )
        controller.reload()
        for _ in 0 ..< 100 {
            if controller.snapshot?.updatedAt == firstDate { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.snapshot?.updatedAt, firstDate)
        XCTAssertEqual(loads, 1)

        controller.pollTranscriptIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(loads, 1)

        try writeSnapshot(sessionId: sessionId, updatedAt: secondDate)
        controller.pollTranscriptIfNeeded()
        for _ in 0 ..< 100 {
            if controller.snapshot?.updatedAt == secondDate { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(controller.snapshot?.updatedAt, secondDate)
        XCTAssertEqual(loads, 2)
    }

    @MainActor
    func testTranscriptDrawerRendersBottomTurnsOnSessionSwitchAndPreservesScrollPosition() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let savedFullWidth = UserDefaults.standard.object(forKey: TranscriptDrawer.fullWidthTranscriptKey)
        defer {
            if let savedFullWidth {
                UserDefaults.standard.set(savedFullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
            }
        }

        func makeTurn(index: Int, variant: Int) -> TranscriptTurn {
            let start = Date(timeIntervalSince1970: 1_788_633_600 + Double(index * 60))
            let paragraphCount = 1 + ((index * 7 + variant * 3) % 12)
            let paragraphs = (0..<paragraphCount).map { p in
                if p % 4 == 1 {
                    return """
                    ```swift
                    func example_\(index)_\(p)() -> Int {
                        let values = Array(0..<\(10 + p * 5))
                        return values.reduce(0, +)
                    }
                    ```
                    """
                } else if p % 5 == 2 {
                    return """
                    | Column A | Column B | Column C |
                    | --- | --- | --- |
                    | row \(index)-\(p)-1 | detail text with **bold** and `code` | 12345 |
                    | row \(index)-\(p)-2 | more varied height markdown content | 67890 |
                    """
                } else {
                    return String(
                        repeating: "Turn \(index) paragraph \(p) with varied length markdown text and `inline code` so line wrapping changes height significantly. ",
                        count: 1 + ((index + p + variant) % 5)
                    )
                }
            }.joined(separator: "\n\n")
            let msgCount = 1 + ((index + variant) % 3)
            let messages = (0..<msgCount).map { m in
                TranscriptAssistantMessage(
                    id: "msg-\(index)-\(m)",
                    timestamp: start.addingTimeInterval(Double(m + 1)),
                    content: "### Heading \(index).\(m)\n\n" + paragraphs
                )
            }
            let tools = (0..<(index % 5)).map { t in
                TranscriptTool(
                    id: "tool-\(index)-\(t)",
                    name: ["bash", "view", "grep", "edit"][t % 4],
                    title: "Tool summary \(t)",
                    success: true
                )
            }
            return TranscriptTurn(
                id: "turn-\(variant)-\(index)",
                startedAt: start,
                endedAt: start.addingTimeInterval(20),
                kind: "foreground",
                userContent: "User prompt for turn \(index): " + String(repeating: "question details ", count: 1 + (index % 6)),
                assistantMessages: messages,
                tools: tools,
                isAborted: false,
                reasoningSteps: index % 2 == 0 ? ["Step 1 thinking for turn \(index)", "Step 2 thinking for turn \(index)"] : []
            )
        }

        func makeShortTurn(index: Int, variant: Int) -> TranscriptTurn {
            let start = Date(timeIntervalSince1970: 1_788_633_600 + Double(index * 60))
            return TranscriptTurn(
                id: "turn-\(variant)-\(index)",
                startedAt: start,
                endedAt: start.addingTimeInterval(5),
                kind: "foreground",
                userContent: "Short prompt \(index)",
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(variant)-\(index)",
                        timestamp: start.addingTimeInterval(1),
                        content: "Short reply \(index)"
                    )
                ],
                tools: [],
                isAborted: false
            )
        }

        func makeHugeTurn(index: Int, variant: Int) -> TranscriptTurn {
            let start = Date(timeIntervalSince1970: 1_788_633_600 + Double(index * 60))
            let body = (0..<18).map { p in
                "### Section \(index).\(p)\n\n" + String(
                    repeating: "Detailed markdown explanation for section \(index).\(p) with `inline code` and **bold text** that wraps across many lines in both drawer and full-width layouts. ",
                    count: 6
                )
            }.joined(separator: "\n\n")
            return TranscriptTurn(
                id: "turn-\(variant)-\(index)",
                startedAt: start,
                endedAt: start.addingTimeInterval(20),
                kind: "foreground",
                userContent: String(repeating: "Long user prompt for turn \(index) with plenty of context. ", count: 8),
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(variant)-\(index)-0",
                        timestamp: start.addingTimeInterval(1),
                        content: body
                    )
                ],
                tools: [
                    TranscriptTool(id: "t-\(variant)-\(index)", name: "bash", title: "Run suite", success: true)
                ],
                isAborted: false,
                reasoningSteps: ["Step 1", "Step 2", "Step 3"]
            )
        }

        func findTranscriptScrollView(in view: NSView) -> NSScrollView? {
            var candidates: [NSScrollView] = []
            func walk(_ v: NSView) {
                if let sv = v as? NSScrollView, sv.frame.height > 200 {
                    candidates.append(sv)
                }
                for sub in v.subviews { walk(sub) }
            }
            walk(view)
            return candidates.max(by: { $0.frame.height < $1.frame.height })
        }

        func findVisibleTextViews(in doc: NSView, visibleRect: NSRect) -> [NSTextView] {
            var all: [NSTextView] = []
            func walk(_ v: NSView) {
                guard !v.isHidden && v.alphaValue > 0.01 else { return }
                if let tv = v as? NSTextView, !tv.string.isEmpty {
                    let rectInDoc = doc.convert(tv.bounds, from: tv)
                    if rectInDoc.intersects(visibleRect) && rectInDoc.height > 0 {
                        all.append(tv)
                    }
                }
                for sub in v.subviews { walk(sub) }
            }
            walk(doc)
            return all
        }

        let fixtures: [(id: String, turns: [TranscriptTurn], expectedBottomSnippet: String)] = [
            ("s1", (0..<45).map { makeTurn(index: $0, variant: 1) }, "Turn 44"),
            ("s2", (0..<40).map { makeHugeTurn(index: $0, variant: 4) } + (40..<46).map { makeShortTurn(index: $0, variant: 4) }, "Short reply 45"),
            ("s3", (0..<80).map { makeTurn(index: $0, variant: 2) }, "row 79-"),
            ("s4", (0..<40).map { makeShortTurn(index: $0, variant: 5) } + (40..<43).map { makeHugeTurn(index: $0, variant: 5) }, "Section 42."),
            ("s5", (0..<25).map { makeTurn(index: $0, variant: 3) }, "example_24_"),
            ("s6", (0..<60).map { $0 % 2 == 0 ? makeHugeTurn(index: $0, variant: 6) : makeShortTurn(index: $0, variant: 6) }, "Short reply 59"),
        ]

        @MainActor
        final class SwitchHarness: ObservableObject {
            @Published var sessionId: String
            @Published var turns: [TranscriptTurn]
            @Published var questions: [RemoteUserInputRequest] = []
            @Published var copilotSessionId = "conversation-1"

            init(sessionId: String, turns: [TranscriptTurn]) {
                self.sessionId = sessionId
                self.turns = turns
            }
        }

        struct SwitchHarnessView: View {
            @ObservedObject var harness: SwitchHarness
            let workflow: RemoteSessionWorkflow

            var body: some View {
                let _ = DrawerTrace.shared.line("SWIFTUI update takes the change: session=\(harness.sessionId) conversation=\(harness.copilotSessionId) turns=\(harness.turns.count)")
                ZStack(alignment: .trailing) {
                    Color.black
                    TranscriptDrawer(
                        turns: harness.turns,
                        imageCapture: nil,
                        sessionId: harness.sessionId,
                        copilotSessionId: harness.copilotSessionId,
                        workflow: workflow,
                        operation: AgentOperationProjection(conversationEpoch: "e1", support: .receipts, receipts: []),
                        pendingUserInputs: harness.questions,
                        workflowProvider: nil,
                        operationProvider: nil,
                        promptComposer: nil,
                        onClose: {},
                        onAction: { _ in RemoteWorkflowActionResult(state: .applied) },
                        onPreview: { _ in }
                    )
                    .id(harness.sessionId)
                }
                // Framed like the workspace pane in RootView, so the window's minimum width is the
                // pane's. Unframed it was the transcript's: the width the transcript was last laid
                // out at, plus a scroll bar's 17 pt once one showed. On a Mac that always shows
                // scroll bars, each session switch widened the window by that, and sizing it back
                // to 1100 pt below rewrapped the transcript, so its bottom never came into view.
                .frame(minWidth: 420, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        /// Runs display cycles until the transcript stops moving. A short newest page fills in
        /// earlier turns over several passes.
        func settleTranscript(_ window: NSWindow) async {
            var last: [CGFloat] = []
            for _ in 0..<20 {
                await settleDisplayCycle(window)
                guard let root = window.contentView, let scrollView = findTranscriptScrollView(in: root) else { continue }
                let now = [scrollView.documentView?.frame.height ?? 0, scrollView.documentVisibleRect.minY]
                if now == last { return }
                last = now
            }
        }

        func scroll(_ scrollView: NSScrollView, toY y: CGFloat, in window: NSWindow) {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            stepMainRunLoopBeforeWaiting()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        let question = RemoteUserInputRequest(
            requestId: "question-1",
            question: "Which branch should the fix target? Pick one, or type another.",
            choices: ["main", "release", "Both"],
            allowFreeform: true,
            requestedAt: Date(timeIntervalSince1970: 1_788_700_000)
        )

        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            capabilities: ["session-send"],
            sendReady: true,
            pendingMessages: [RemotePendingMessage(messageId: "pending-1", text: "Queued follow-up for later")]
        )

        // TEMPORARY MEASUREMENT. A cell is helper[:returns per pass of the test[:trace]].
        setlinebuf(stdout)
        let environment = ProcessInfo.processInfo.environment
        let probeCells: [(helper: ProbeHelper, reps: Int, trace: Bool)] = (
            environment["DRAWER_PROBE_CELLS"] ?? "block:40,block:40,block:40,old:10"
        ).split(separator: ",").compactMap { cell in
            let parts = cell.split(separator: ":").map(String.init)
            guard let helper = ProbeHelper(rawValue: parts[0]) else { return nil }
            return (helper, parts.count > 1 ? Int(parts[1]) ?? 10 : 10, parts.count > 2)
        }
        let probeShift = environment["DRAWER_PROBE_SHIFT"] != nil
        var probeReps = 0
        var probeTraceReps = false
        // Part 1: opens, a new conversation, returns, short content and a resized window, traced
        // line by line. After every settled wait it waits four more times, to tell a scroll that
        // is applied late from one that is never applied.
        var scenarioCells: Set<String> = []
        for cell in probeCells where environment["DRAWER_PROBE_SKIP_SCENARIO"] == nil {
            guard scenarioCells.insert(cell.helper.rawValue).inserted else { continue }
            probeHelper = cell.helper
            probeCell = cell.helper.rawValue
            let trace = DrawerTrace.shared
            UserDefaults.standard.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            let harness = SwitchHarness(sessionId: fixtures[0].id, turns: [])
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                styleMask: [.titled, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: SwitchHarnessView(harness: harness, workflow: workflow))
            window.orderBack(nil)
            trace.begin(window, "a window 760 pt tall")
            func settled(_ window: NSWindow, _ label: String, snippet: String? = nil) async {
                await settleTranscript(window)
                trace.result("\(label), settled", snippet: snippet)
                for _ in 1...4 { await settleDisplayCycle(window) }
                trace.result("\(label), after 4 more waits", snippet: snippet)
            }
            let opens: [(fixture: Int, late: Bool)] = [(0, true), (1, true), (0, false), (1, false)]
            for (step, open) in opens.enumerated() {
                let target = fixtures[open.fixture]
                let name = "open \(step + 1) (\(target.id), snapshot \(open.late ? "after" : "with") the switch)"
                trace.action("\(name): the session changes")
                if step > 0 {
                    harness.sessionId = "\(target.id)-step-\(step)"
                    harness.turns = open.late ? [] : target.turns
                }
                await probeStepAfterSwitch(window)
                if open.late {
                    trace.result("\(name), the empty drawer")
                    trace.action("\(name): the snapshot arrives, \(target.turns.count) turns")
                    harness.turns = target.turns
                }
                await settled(window, name, snippet: target.expectedBottomSnippet)
            }
            trace.action("a new conversation of 80 short turns")
            harness.copilotSessionId = "conversation-2"
            harness.turns = (2_000..<2_080).map { makeShortTurn(index: $0, variant: 7) }
            await settled(window, "new conversation", snippet: "Short reply 2079")
            let shortTurns = harness.turns
            for shift in [false, true] {
                trace.action("leave for a conversation of 3 turns")
                harness.copilotSessionId = "conversation-3"
                harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
                await settled(window, "leave (3 turns)")
                trace.action("return to the conversation\(shift ? ", and the test runs one display cycle itself inside its pass" : "")")
                harness.copilotSessionId = "conversation-2"
                harness.turns = shortTurns
                if shift { stepMainRunLoopBeforeWaiting() }
                await settled(window, "return\(shift ? " with the shift" : "")", snippet: "Short reply 2079")
            }
            // Short content under a window that grows and then shrinks below the content's height.
            trace.action("leave for a conversation of 3 turns, before resizing the window")
            harness.copilotSessionId = "conversation-3"
            harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
            await settled(window, "resize: 3 turns, window 760 pt")
            for height: CGFloat in [1000, 500, 760, 1000] {
                trace.action("the window is resized to \(Int(height)) pt")
                window.setContentSize(NSSize(width: 1100, height: height))
                await settled(window, "resize: 3 turns, window \(Int(height)) pt")
            }
            // The content outgrows a viewport that was resized over short content.
            trace.action("return to the conversation in the window grown to 1000 pt")
            harness.copilotSessionId = "conversation-2"
            harness.turns = shortTurns
            await settled(window, "resize: return in the grown window", snippet: "Short reply 2079")
            trace.action("leave for a conversation of 3 turns in the grown window")
            harness.copilotSessionId = "conversation-3"
            harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
            await settled(window, "resize: leave in the grown window")
            trace.action("the window shrinks to 760 pt and the conversation returns in the same pass")
            window.setContentSize(NSSize(width: 1100, height: 760))
            harness.copilotSessionId = "conversation-2"
            harness.turns = shortTurns
            await settled(window, "resize: return while shrinking to 760 pt", snippet: "Short reply 2079")
            trace.action("leave for a conversation of 1 turn, then a question card arrives")
            harness.copilotSessionId = "conversation-4"
            harness.turns = (4_000..<4_001).map { makeShortTurn(index: $0, variant: 8) }
            await settleTranscript(window)
            harness.questions = [question]
            await settled(window, "1 turn and a question card")
            trace.end()
            window.orderOut(nil)
            window.contentView = nil

            // Two pages of short turns fit in a viewport this tall; the snapshot arrives after the switch.
            let lateHarness = SwitchHarness(sessionId: "tall-late", turns: [])
            let lateWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1700),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            lateWindow.contentView = NSHostingView(rootView: SwitchHarnessView(harness: lateHarness, workflow: workflow))
            lateWindow.orderBack(nil)
            trace.begin(lateWindow, "a window 1700 pt tall")
            trace.action("tall window: the session changes")
            await probeStepAfterSwitch(lateWindow)
            trace.action("tall window: the snapshot arrives, 80 short turns")
            lateHarness.turns = shortTurns
            await settled(lateWindow, "tall window, 80 short turns", snippet: "Short reply 2079")
            trace.end()
            lateWindow.orderOut(nil)
            lateWindow.contentView = nil
        }
        probeCell = nil

        // Part 2: the test itself, once under each cell.
        func probeBody() async throws {
        let sequence = [0, 1, 2, 3, 4, 5, 1, 3, 5, 2]
        for fullWidth in [false, true] {
            UserDefaults.standard.set(fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            for asyncSnapshotArrival in [true, false] {
                let harness = SwitchHarness(
                    sessionId: fixtures[0].id,
                    turns: asyncSnapshotArrival ? [] : fixtures[0].turns
                )
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
                    styleMask: [.titled, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.contentView = NSHostingView(rootView: SwitchHarnessView(harness: harness, workflow: workflow))
                window.orderBack(nil)
                defer {
                    window.orderOut(nil)
                    window.contentView = nil
                }

                for (step, idx) in sequence.enumerated() {
                    let target = fixtures[idx]
                    if step > 0 {
                        harness.sessionId = "\(target.id)-step-\(step)"
                        harness.turns = asyncSnapshotArrival ? [] : target.turns
                    }
                    // Laid out here, so the empty drawer's pager has asked for its page before the
                    // snapshot arrives. Asked afterwards, it rendered a second page at once.
                    await probeStepAfterSwitch(window)
                    if asyncSnapshotArrival {
                        harness.turns = target.turns
                    }
                    await settleTranscript(window)

                    let root = try XCTUnwrap(window.contentView)
                    let sv = try XCTUnwrap(findTranscriptScrollView(in: root))
                    let doc = try XCTUnwrap(sv.documentView)
                    let vis = sv.documentVisibleRect
                    let docBounds = doc.bounds
                    let visibleTVs = findVisibleTextViews(in: doc, visibleRect: vis)

                    XCTAssertFalse(
                        visibleTVs.isEmpty,
                        "Expected realized turn text views in visible rect for fullWidth=\(fullWidth) async=\(asyncSnapshotArrival) step=\(step), got vis=\(vis) docBounds=\(docBounds)"
                    )
                    XCTAssertGreaterThanOrEqual(
                        vis.maxY,
                        docBounds.height - 24,
                        "Expected scroll view anchored at bottom for fullWidth=\(fullWidth) async=\(asyncSnapshotArrival) step=\(step)"
                    )
                    XCTAssertTrue(
                        visibleTVs.contains { $0.string.contains(target.expectedBottomSnippet) },
                        "Expected bottom turn snippet '\(target.expectedBottomSnippet)' visible at step=\(step), saw: \(visibleTVs.map { String($0.string.prefix(40)) })"
                    )
                    let minVisibleTextY = visibleTVs.map { doc.convert($0.bounds, from: $0).minY }.min() ?? .greatestFiniteMagnitude
                    XCTAssertLessThanOrEqual(
                        minVisibleTextY,
                        vis.minY + 180,
                        "Expected top of viewport to contain realized turn content without a blank band for fullWidth=\(fullWidth) async=\(asyncSnapshotArrival) step=\(step)"
                    )
                }

                // Verify slow 1pt upward scrolling past the bottom zone disengages stick-to-bottom,
                // appending 8 turns while scrolled up keeps the scroll offset and visible content put,
                // and scrolling back to the bottom re-engages stick-to-bottom.
                harness.turns.append(makeShortTurn(index: 990, variant: 9))
                await settleTranscript(window)
                let root = try XCTUnwrap(window.contentView)
                let sv = try XCTUnwrap(findTranscriptScrollView(in: root))
                let doc = try XCTUnwrap(sv.documentView)
                sv.contentView.postsBoundsChangedNotifications = true
                var bottomY: CGFloat { max(0, doc.bounds.height - sv.documentVisibleRect.height) }
                for _ in 0..<3 {
                    for stepOffset in 1...40 {
                        scroll(sv, toY: max(0, bottomY - CGFloat(stepOffset)), in: window)
                    }
                    await settleDisplayCycle(window)
                    scroll(sv, toY: max(0, sv.documentVisibleRect.origin.y - 10), in: window)
                    await settleDisplayCycle(window)
                    if sv.documentVisibleRect.origin.y < bottomY - 30 {
                        break
                    }
                }
                let settledScrolledUpY = sv.documentVisibleRect.origin.y
                XCTAssertLessThan(settledScrolledUpY, bottomY - 25)

                /// Where each turn's text in the viewport sits, measured from the top of the viewport.
                /// The question card and the queued message stay under the newest turn, so they move
                /// when a turn arrives and are left out.
                func textTops() -> [NSTextView: CGFloat] {
                    let visible = sv.documentVisibleRect
                    return Dictionary(
                        findVisibleTextViews(in: doc, visibleRect: visible)
                            .filter { !$0.string.contains("Queued follow-up") && !$0.string.contains("Which branch") }
                            .map { ($0, doc.convert($0.bounds, from: $0).minY - visible.minY) },
                        uniquingKeysWith: { first, _ in first }
                    )
                }
                /// Fails unless text that was on screen is still there, `distance` points lower: a
                /// blank viewport, rebuilt cards and a jump all fail.
                func assertTextMoved(
                    _ distance: CGFloat, from before: [NSTextView: CGFloat], _ what: String, line: UInt = #line
                ) {
                    // Measure every view that was on screen, including one that has since left it.
                    let visibleTop = sv.documentVisibleRect.minY
                    let errors = before.map { view, top -> CGFloat in
                        guard view.window != nil else { return .infinity }
                        return abs(doc.convert(view.bounds, from: view).minY - visibleTop - top - distance)
                    }
                    XCTAssertFalse(textTops().isEmpty, "\(what) should not leave a blank viewport", line: line)
                    XCTAssertLessThanOrEqual(
                        errors.max() ?? .infinity,
                        2,
                        "\(what) should leave the text on screen where it was (fullWidth=\(fullWidth) async=\(asyncSnapshotArrival))",
                        line: line
                    )
                }
                func allText() -> [NSTextView] { findVisibleTextViews(in: doc, visibleRect: doc.bounds) }
                /// Text laid out on top of the text below it.
                func overlappingText() -> [String] {
                    let texts = allText()
                        .map { (rect: doc.convert($0.bounds, from: $0), start: String($0.string.prefix(30))) }
                        .sorted { $0.rect.minY < $1.rect.minY }
                    return zip(texts, texts.dropFirst()).compactMap { upper, lower in
                        upper.rect.maxY - lower.rect.minY > 1.5 && upper.rect.intersects(lower.rect)
                            ? "\(upper.start) over \(lower.start)"
                            : nil
                    }
                }

                var before = textTops()
                for appendIdx in 991..<999 {
                    harness.turns.append(makeShortTurn(index: appendIdx, variant: 9))
                    await settleDisplayCycle(window)
                }
                XCTAssertEqual(
                    sv.documentVisibleRect.origin.y,
                    settledScrolledUpY,
                    accuracy: 2,
                    "Scrolling up should prevent new turns from yanking the scroll position to the bottom"
                )
                assertTextMoved(0, from: before, "Appending 8 turns while scrolled up")
                XCTAssertLessThan(
                    sv.documentVisibleRect.maxY,
                    doc.bounds.height - 200,
                    "Appending 8 turns while scrolled up should leave the viewport above the new bottom"
                )

                // A question card arriving while scrolled up goes under the newest turn, above the
                // queued message, and moves nothing on screen.
                before = textTops()
                harness.questions = [question]
                await settleDisplayCycle(window)
                assertTextMoved(0, from: before, "A question card arriving while scrolled up")
                func documentRect(ofTextContaining text: String) throws -> NSRect {
                    let view = try XCTUnwrap(allText().first { $0.string.contains(text) }, "No text view contains '\(text)'")
                    return doc.convert(view.bounds, from: view)
                }
                let questionRect = try documentRect(ofTextContaining: "Which branch should the fix target")
                XCTAssertGreaterThan(questionRect.minY, try documentRect(ofTextContaining: "Short reply 998").maxY)
                XCTAssertLessThan(questionRect.maxY, try documentRect(ofTextContaining: "Queued follow-up").minY)

                // State inside a rendered card (a selection here, an open thinking or tools section in
                // the app) has to survive the paging and turn updates below, which it does only while
                // the card is not rebuilt.
                let turn78Prompt = try XCTUnwrap(allText().first { $0.string.contains("User prompt for turn 78:") })
                turn78Prompt.setSelectedRange(NSRange(location: 0, length: 11))

                // Scroll up through earlier history with the card showing, far enough to page in
                // earlier turns three times. Each step may move the text on screen only by the
                // distance scrolled and must leave turn text in the viewport: no jump and no blank
                // viewport, including while a page is laid out above.
                func renderedTurnCount() -> Int {
                    allText().filter {
                        $0.string.contains("User prompt for turn") || $0.string.contains("Short prompt")
                    }.count
                }
                // The newest turn streams meanwhile. Its change is queued ahead of the page request
                // the scroll triggers, so it grows or shrinks below the viewport in the same pass
                // that lays a page out above. Measuring the page by the content height moved the
                // text by that growth.
                let renderedBeforePaging = renderedTurnCount()
                let streaming = harness.turns.count - 1
                var steps = 0
                while renderedTurnCount() < renderedBeforePaging + 12, steps < 200 {
                    steps += 1
                    let offset = sv.documentVisibleRect.origin.y
                    let target = max(0, offset - 300)
                    before = textTops()
                    let streamed = steps % 2 == 1
                        ? makeHugeTurn(index: 998, variant: 9)
                        : makeShortTurn(index: 998, variant: 9)
                    DispatchQueue.main.async { harness.turns[streaming] = streamed }
                    scroll(sv, toY: target, in: window)
                    await settleDisplayCycle(window)
                    assertTextMoved(offset - target, from: before, "Scrolling up through history (step \(steps))")
                }
                harness.turns[streaming] = makeShortTurn(index: 998, variant: 9)
                await settleDisplayCycle(window)
                XCTAssertGreaterThanOrEqual(
                    renderedTurnCount(),
                    renderedBeforePaging + 12,
                    "Scrolling up should page in earlier turns"
                )

                // The tracker's cap drops the oldest turn as a new one arrives. Scrolled up, the text
                // on screen stays put.
                before = textTops()
                var cappedTurns = harness.turns
                cappedTurns.removeFirst()
                cappedTurns.append(makeShortTurn(index: 9990, variant: 9))
                harness.turns = cappedTurns
                await settleDisplayCycle(window)
                assertTextMoved(0, from: before, "Evicting the oldest turn while scrolled up")
                XCTAssertTrue(
                    allText().first { $0.string.contains("User prompt for turn 78:") } === turn78Prompt,
                    "Paging and turn updates should keep a rendered card, and the turn it shows"
                )
                XCTAssertEqual(
                    turn78Prompt.selectedRange(),
                    NSRange(location: 0, length: 11),
                    "Paging and turn updates should preserve state inside a rendered card"
                )

                // The cap can also drop the oldest rendered turn, the one rendering starts from.
                // The turns after it stay rendered, rather than only the newest page.
                let renderedBeforeEviction = renderedTurnCount()
                let oldestRendered = try XCTUnwrap(
                    harness.turns.first { turn in
                        let prompt = turn.userContent.trimmingCharacters(in: .whitespaces)
                        return allText().contains { $0.string.hasPrefix(prompt) }
                    }
                )
                harness.turns.removeAll { $0.id == oldestRendered.id }
                await settleDisplayCycle(window)
                XCTAssertGreaterThanOrEqual(
                    renderedTurnCount(),
                    renderedBeforeEviction - 1,
                    "Evicting the oldest rendered turn should keep the turns after it rendered"
                )
                XCTAssertLessThan(
                    renderedTurnCount(),
                    harness.turns.count,
                    "Evicting the oldest rendered turn should not render the whole transcript"
                )

                for _ in 0..<3 {
                    scroll(sv, toY: bottomY, in: window)
                }
                await settleDisplayCycle(window)

                harness.turns.append(makeShortTurn(index: 999, variant: 9))
                await settleDisplayCycle(window)
                let finalVisibleTVs = findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                XCTAssertTrue(
                    finalVisibleTVs.contains { $0.string.contains("Short reply 999") },
                    "Returning to the bottom should stick to newly appended turns"
                )

                // With a question card up, scrolling up from the bottom used to bounce back: every
                // few points of scroll re-estimated the height of the turns above and left the view
                // at the bottom again. Scroll up 400 pt in wheel-sized steps while the session
                // re-renders, then let a turn arrive.
                let restingDistance = bottomY - sv.documentVisibleRect.origin.y
                for _ in 0..<20 {
                    scroll(sv, toY: sv.documentVisibleRect.origin.y - 20, in: window)
                    harness.objectWillChange.send()
                }
                await settleDisplayCycle(window)
                XCTAssertEqual(
                    bottomY - sv.documentVisibleRect.origin.y - restingDistance,
                    400,
                    accuracy: 2,
                    "Scrolling up with a question card showing should move the transcript and hold"
                )
                before = textTops()
                let readingY = sv.documentVisibleRect.origin.y
                harness.turns.append(makeShortTurn(index: 9991, variant: 9))
                await settleDisplayCycle(window)
                assertTextMoved(0, from: before, "A turn arriving while reading above a question card")
                XCTAssertEqual(sv.documentVisibleRect.origin.y, readingY, accuracy: 2)

                // Scrolling up slightly and enlarging the container height until the bottom is visible
                // re-engages bottom following for subsequent turn updates.
                scroll(sv, toY: max(0, bottomY - 80), in: window)
                await settleDisplayCycle(window)
                window.setContentSize(NSSize(width: 1100, height: 900))
                window.contentView?.layoutSubtreeIfNeeded()
                await settleDisplayCycle(window)
                harness.turns.append(makeShortTurn(index: 1000, variant: 9))
                await settleDisplayCycle(window)
                let resizedVisibleTVs = findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                XCTAssertTrue(
                    resizedVisibleTVs.contains { $0.string.contains("Short reply 1000") },
                    "Enlarging container height so the bottom enters view should re-engage bottom following"
                )

                // Toggling full-width while pinned at the bottom keeps the bottom turn visible, and
                // measures every message at the new width: narrowing the drawer used to leave each
                // message its full-width height, so it drew over the text below.
                UserDefaults.standard.set(!fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                await settleDisplayCycle(window)
                let toggledVisibleTVs = findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                XCTAssertTrue(
                    toggledVisibleTVs.contains { $0.string.contains("Short reply 1000") },
                    "Toggling full-width while at the bottom should keep the bottom turn visible"
                )
                XCTAssertEqual(overlappingText(), [], "Toggling full-width (to \(!fullWidth)) should not overlap text")
                UserDefaults.standard.set(fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                await settleDisplayCycle(window)
                XCTAssertEqual(overlappingText(), [], "Toggling full-width back (to \(fullWidth)) should not overlap text")

                // `/new` and `/resume` put another conversation in the same drawer. Every turn of a
                // newer conversation starts after the turn the reader was pinned to in the old one,
                // so all of them used to render at once.
                harness.copilotSessionId = "conversation-2"
                harness.turns = (2_000..<2_080).map { makeShortTurn(index: $0, variant: 7) }
                await settleTranscript(window)
                let renderedInNewConversation = renderedTurnCount()
                XCTAssertLessThan(renderedInNewConversation, 40, "A new conversation should render only its newest turns")
                XCTAssertTrue(
                    findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                        .contains { $0.string.contains("Short reply 2079") },
                    "A new conversation should open at the bottom"
                )

                // Short turns leave the next page less than a viewport above the bottom. Scrolling
                // up through it in wheel-sized steps moves the text by each step and nothing else.
                for step in 1...60 {
                    before = textTops()
                    scroll(sv, toY: sv.documentVisibleRect.origin.y - 20, in: window)
                    await settleDisplayCycle(window)
                    assertTextMoved(20, from: before, "Scrolling up from the bottom of short turns (step \(step))")
                }
                XCTAssertGreaterThan(
                    renderedTurnCount(),
                    renderedInNewConversation,
                    "Scrolling up from the bottom of short turns should page in earlier turns"
                )

                // Going to another conversation and back starts from the newest turns again, not
                // from where the reader had paged to before.
                let conversation2 = harness.turns
                // TEMPORARY MEASUREMENT: leave and return many times, counting SwiftUI's own moves
                // up and pages nobody scrolled to.
                if probeReps > 0 {
                    let counter = DrawerTrace.shared
                    if probeTraceReps { probeCell = probeIssueLabel }
                    counter.begin(window, "returns, fullWidth=\(fullWidth) snapshotWithTheSwitch=\(!asyncSnapshotArrival)")
                    var rendered: [Int: Int] = [:]
                    var distances: [Int: Int] = [:]
                    var withOwnMoveUp = 0
                    var movedUpAtAll = 0
                    var morePages = 0
                    var notAtEnd = 0
                    for rep in 0..<probeReps {
                        counter.line("ACTION leave \(rep)")
                        harness.copilotSessionId = "conversation-3"
                        harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
                        await settleTranscript(window)
                        counter.action("return \(rep)")
                        harness.copilotSessionId = "conversation-2"
                        harness.turns = conversation2
                        if probeShift { stepMainRunLoopBeforeWaiting() }
                        await settleTranscript(window)
                        counter.result("return \(rep)")
                        let count = renderedTurnCount()
                        rendered[count, default: 0] += 1
                        if count > renderedInNewConversation { morePages += 1 }
                        let ups = counter.ownMoves.filter { $0 > 0 }
                        if !ups.isEmpty { withOwnMoveUp += 1 }
                        for up in ups { distances[up, default: 0] += 1 }
                        if counter.movedUp >= 1 { movedUpAtAll += 1 }
                        if sv.documentVisibleRect.maxY < doc.bounds.height - 24 { notAtEnd += 1 }
                    }
                    counter.end()
                    probeCell = nil
                    print("DRAWERMEASURE RETURNS cell=\(probeIssueLabel) shift=\(probeShift) fullWidth=\(fullWidth) async=\(asyncSnapshotArrival) returns=\(probeReps) withSwiftUIOwnMoveUp=\(withOwnMoveUp) ownMoveUpDistances=\(distances.sorted { $0.key < $1.key }) movedUpAtAll=\(movedUpAtAll) notAtTheEnd=\(notAtEnd) morePagesThanFirstOpen=\(morePages) turnsRendered=\(rendered.sorted { $0.key < $1.key }) firstOpen=\(renderedInNewConversation)")
                }
                harness.copilotSessionId = "conversation-3"
                harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
                await settleTranscript(window)
                // A short conversation rests at its end while the window grows, and when the window
                // shrinks below its height. Before the transcript was padded, it then showed its top.
                for height: CGFloat in [1000, 500, 900] {
                    window.setContentSize(NSSize(width: 1100, height: height))
                    await settleTranscript(window)
                    XCTAssertEqual(sv.documentVisibleRect.maxY, doc.bounds.height, accuracy: 1, "A short conversation should rest at its end in a window \(Int(height)) pt tall")
                }
                // Filling in pages at the bottom put the view a page past the end. Pulled back from
                // there, it now and then landed high enough to load one more page. So did a scroll
                // SwiftUI applied a pass late, which moved the view 543 pt up.
                var pastEnd: CGFloat = 0
                var movedUp: CGFloat = 0
                var lastY = sv.contentView.bounds.minY
                let watchEnd = NotificationCenter.default
                    .publisher(for: NSView.boundsDidChangeNotification, object: sv.contentView)
                    .sink { _ in
                        let clip = sv.contentView.bounds
                        pastEnd = max(pastEnd, clip.minY - max(0, doc.frame.height - clip.height))
                        movedUp = max(movedUp, lastY - clip.minY)
                        lastY = clip.minY
                    }
                harness.copilotSessionId = "conversation-2"
                harness.turns = conversation2
                await settleTranscript(window)
                watchEnd.cancel()
                XCTAssertLessThan(pastEnd, 1, "Filling in pages at the bottom should not scroll past the end")
                XCTAssertLessThan(movedUp, 1, "Filling in pages at the bottom should not move the view up")
                XCTAssertLessThanOrEqual(
                    renderedTurnCount(),
                    renderedInNewConversation,
                    "Returning to a conversation should render only its newest turns"
                )
            }
        }

        // Two pages of short turns fit in a viewport this tall. The transcript is padded to the
        // viewport's height, so its document does not grow as they are laid out. A pager that
        // waited for it to grow stopped at 8 turns, with nothing to scroll to reach the rest.
        UserDefaults.standard.set(false, forKey: TranscriptDrawer.fullWidthTranscriptKey)
        let tallHarness = SwitchHarness(sessionId: "tall", turns: (0..<80).map { makeShortTurn(index: $0, variant: 7) })
        let tallWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 1700), styleMask: [.borderless], backing: .buffered, defer: false
        )
        tallWindow.contentView = NSHostingView(rootView: SwitchHarnessView(harness: tallHarness, workflow: workflow))
        tallWindow.orderBack(nil)
        defer {
            tallWindow.orderOut(nil)
            tallWindow.contentView = nil
        }
        await settleTranscript(tallWindow)
        let tallDocument = try XCTUnwrap(findTranscriptScrollView(in: try XCTUnwrap(tallWindow.contentView))?.documentView)
        XCTAssertEqual(
            findVisibleTextViews(in: tallDocument, visibleRect: tallDocument.bounds).filter { $0.string.contains("Short prompt") }.count,
            24, "A viewport that fits two pages of short turns should fill in earlier pages until it overflows"
        )
        }
        for cell in probeCells where environment["DRAWER_PROBE_SKIP_REAL"] == nil {
            probeHelper = cell.helper
            probeReps = cell.reps
            probeTraceReps = cell.trace
            probeIssueLabel = cell.helper.rawValue
            let before = testRun?.totalFailureCount ?? 0
            print("DRAWERMEASURE REAL-TEST BEGIN cell=\(probeIssueLabel)")
            do {
                try await probeBody()
            } catch {
                XCTFail("The measured cell threw: \(error)")
            }
            print("DRAWERMEASURE REAL-TEST END cell=\(probeIssueLabel) failures=\((testRun?.totalFailureCount ?? 0) - before)")
        }
        probeIssueLabel = ""
        probeHelper = .block
    }

    /// AppKit measures text through intrinsicContentSize at the last width SwiftUI proposed, which
    /// needn't be the width it placed the text at. Afterwards the text has to be laid out at its
    /// frame's width again, or it wraps narrower or wider than its frame.
    @MainActor
    func testMeasuringMarkdownTextAtAnotherWidthLeavesItLaidOutAtItsFrame() throws {
        let textView = MarkdownSelectableTextView(frame: .zero)
        textView.attributedText = NSAttributedString(
            string: String(repeating: "A sentence that wraps over several lines at each of these widths. ", count: 30)
        )
        textView.preferredMaxLayoutWidth = 600
        textView.setFrameSize(textView.intrinsicContentSize)
        let placed = textView.frame.size
        let container = try XCTUnwrap(textView.textContainer)
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        for width: CGFloat in [450, 900] {
            textView.preferredMaxLayoutWidth = width
            XCTAssertNotEqual(textView.intrinsicContentSize.height, placed.height)
            XCTAssertEqual(textView.frame.size, placed, "Measuring at \(width) pt should leave the frame as it was placed")
            layoutManager.ensureLayout(for: container)
            XCTAssertEqual(container.size.width, placed.width, "Measuring at \(width) pt should leave the text laid out at its frame's width")
            XCTAssertEqual(layoutManager.usedRect(for: container).height, placed.height, accuracy: 0.5)
        }
    }

    /// A long question in the full-width transcript was cut off part-way through. Its text was
    /// measured at a width it wasn't placed at, and stayed laid out at that width: narrower than its
    /// card, so its last lines fell below its frame. The full-width transcript takes every width
    /// it's proposed; the side drawer is always 420 pt wide, so every measurement there is at the
    /// width it is placed at.
    @MainActor
    func testTranscriptTextFitsItsFrameAfterBeingMeasuredAtOtherWidths() async throws {
        _ = NSApplication.shared
        let activationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(activationPolicy) }
        let savedFullWidth = UserDefaults.standard.object(forKey: TranscriptDrawer.fullWidthTranscriptKey)
        defer {
            if let savedFullWidth {
                UserDefaults.standard.set(savedFullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            } else {
                UserDefaults.standard.removeObject(forKey: TranscriptDrawer.fullWidthTranscriptKey)
            }
        }

        let start = Date(timeIntervalSince1970: 1_788_633_600)
        let turns = (0..<3).map { (index: Int) -> TranscriptTurn in
            TranscriptTurn(
                id: "turn-\(index)",
                startedAt: start.addingTimeInterval(Double(index * 60)),
                endedAt: start.addingTimeInterval(Double(index * 60 + 5)),
                kind: "foreground",
                userContent: "Prompt \(index) " + String(repeating: "with a long body of context ", count: 12),
                assistantMessages: [
                    TranscriptAssistantMessage(
                        id: "msg-\(index)",
                        timestamp: start.addingTimeInterval(Double(index * 60 + 1)),
                        content: String(repeating: "Reply \(index) wraps over a few lines in the transcript. ", count: 14)
                    )
                ],
                tools: [],
                isAborted: false
            )
        }
        let question = TrackedElicitation(
            requestId: "question-1",
            message: "## Pick a plan\n\n" + (1...6).map {
                "**Option \($0)**: " + String(repeating: "a long explanation that wraps across lines ", count: 31)
            }.joined(separator: "\n\n"),
            schema: .object([
                "type": .string("object"),
                "properties": .object([
                    "choice": .object(["type": .string("string"), "title": .string("Choice")]),
                ]),
            ]),
            requestedAt: start.addingTimeInterval(600).ISO8601Format()
        ).remoteRequest()
        // Framed like the workspace pane in RootView.
        let host = NSHostingController(
            rootView: TranscriptDrawer(
                turns: turns,
                imageCapture: nil,
                sessionId: "s1",
                copilotSessionId: "conversation-1",
                workflow: nil,
                operation: AgentOperationProjection(conversationEpoch: "e1", support: .receipts, receipts: []),
                pendingElicitations: [question],
                workflowProvider: nil,
                operationProvider: nil,
                promptComposer: nil,
                onClose: {},
                onAction: { _ in RemoteWorkflowActionResult(state: .applied) },
                onPreview: { _ in }
            )
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 900),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1100, height: 900))
        defer {
            window.contentViewController = nil
            window.close()
        }

        func markdownText(in view: NSView) -> [MarkdownSelectableTextView] {
            (view as? MarkdownSelectableTextView).map { [$0] } ?? view.subviews.flatMap(markdownText)
        }
        /// Text laid out at another width than its frame's, or taller than its frame.
        func textOutsideItsFrame() -> [String] {
            markdownText(in: host.view).filter(\.wrapsText).compactMap { view in
                guard let container = view.textContainer, let layoutManager = view.layoutManager else { return nil }
                let placedSize = view.bounds.size
                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container).size
                guard abs(container.size.width - placedSize.width) > 0.5 || used.height > placedSize.height + 0.5 else {
                    return nil
                }
                return "'\(view.string.prefix(20))' laid out \(used) in \(placedSize)"
            }
        }

        for fullWidth in [true, false] {
            UserDefaults.standard.set(fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
            await settleDisplayCycle(window)
            let questionText = try XCTUnwrap(markdownText(in: host.view).first { $0.string.contains("Option 1") })
            XCTAssertEqual(questionText.bounds.width > 935, fullWidth, "The question should span the transcript")
            XCTAssertEqual(textOutsideItsFrame(), [], "Text should fit its frame (fullWidth=\(fullWidth))")
            for width: CGFloat in [900, 1300] {
                _ = host.sizeThatFits(in: CGSize(width: width, height: 10_000))
                await settleDisplayCycle(window)
                XCTAssertEqual(
                    textOutsideItsFrame(),
                    [],
                    "Measuring the transcript at \(width) pt should leave its text fitting its frame (fullWidth=\(fullWidth))"
                )
            }
        }
    }
}
