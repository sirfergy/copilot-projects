import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI
@testable import CopilotProjectsHost

final class TranscriptReloadTests: XCTestCase {
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

    @MainActor
    private func settleDisplayCycle(_ window: NSWindow) async {
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
                    stepMainRunLoopBeforeWaiting()
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
                harness.copilotSessionId = "conversation-3"
                harness.turns = (3_000..<3_003).map { makeShortTurn(index: $0, variant: 8) }
                await settleTranscript(window)
                harness.copilotSessionId = "conversation-2"
                harness.turns = conversation2
                await settleTranscript(window)
                XCTAssertLessThanOrEqual(
                    renderedTurnCount(),
                    renderedInNewConversation,
                    "Returning to a conversation should render only its newest turns"
                )
            }
        }
    }

    /// SwiftUI measures text at widths it doesn't place it at. Afterwards the text has to be laid
    /// out at its frame's width again, or it wraps narrower or wider than its frame.
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

    /// A long question in the full-width transcript was cut off part-way through. SwiftUI measures
    /// the transcript at widths it doesn't place it at, and the full-width transcript follows each
    /// one: its text stayed laid out at the last of them, narrower than its card, so its last lines
    /// fell below its frame. The side drawer is always 420 pt wide, so every measurement there is at
    /// the width it is placed at.
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
        let question = RemoteElicitationRequest(
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
            requestedAt: start.addingTimeInterval(600)
        )
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
