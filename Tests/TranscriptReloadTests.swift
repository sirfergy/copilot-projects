import AppKit
import SwiftUI
import XCTest
import CopilotProjectsCore
import CopilotProjectsProtocol
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
                        workflow: workflow,
                        operation: AgentOperationProjection(conversationEpoch: "e1", support: .receipts, receipts: []),
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

        func stepMainRunLoopBeforeWaiting() {
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

        func settleDisplayCycle(_ window: NSWindow) async {
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

        let workflow = RemoteSessionWorkflow(
            observedAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1000),
            capabilities: ["session-send"],
            sendReady: true
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
                    await settleDisplayCycle(window)

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
                await settleDisplayCycle(window)
                let root = try XCTUnwrap(window.contentView)
                let sv = try XCTUnwrap(findTranscriptScrollView(in: root))
                let doc = try XCTUnwrap(sv.documentView)
                sv.contentView.postsBoundsChangedNotifications = true
                for _ in 0..<3 {
                    for stepOffset in 1...40 {
                        let bottomY = max(0, doc.bounds.height - sv.documentVisibleRect.height)
                        let nextY = max(0, bottomY - CGFloat(stepOffset))
                        sv.contentView.scroll(to: NSPoint(x: 0, y: nextY))
                        sv.reflectScrolledClipView(sv.contentView)
                        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sv.contentView)
                        stepMainRunLoopBeforeWaiting()
                        window.contentView?.layoutSubtreeIfNeeded()
                    }
                    await settleDisplayCycle(window)
                    let nudgeY = max(0, sv.documentVisibleRect.origin.y - 10)
                    sv.contentView.scroll(to: NSPoint(x: 0, y: nudgeY))
                    sv.reflectScrolledClipView(sv.contentView)
                    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sv.contentView)
                    stepMainRunLoopBeforeWaiting()
                    window.contentView?.layoutSubtreeIfNeeded()
                    await settleDisplayCycle(window)
                    if sv.documentVisibleRect.origin.y < doc.bounds.height - sv.documentVisibleRect.height - 30 {
                        break
                    }
                }
                let settledScrolledUpY = sv.documentVisibleRect.origin.y
                XCTAssertLessThan(settledScrolledUpY, doc.bounds.height - sv.documentVisibleRect.height - 25)

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
                XCTAssertFalse(
                    findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect).isEmpty,
                    "Appending 8 turns while scrolled up (crossing the 8-turn eager boundary) should keep visible turn content rendered"
                )
                XCTAssertLessThan(
                    sv.documentVisibleRect.maxY,
                    doc.bounds.height - 200,
                    "Appending 8 turns while scrolled up should leave the viewport above the new bottom"
                )

                // Simulate a capped-window eviction (removing the oldest turn while appending a new one)
                // while scrolled up and verify the first eager turn (turn 78) stays in the eager section
                // without moving into the older LazyVStack or losing its stateful view instance/selection.
                let cappedScrollY = max(0, sv.documentVisibleRect.origin.y - 4000)
                sv.contentView.scroll(to: NSPoint(x: 0, y: cappedScrollY))
                sv.reflectScrolledClipView(sv.contentView)
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sv.contentView)
                stepMainRunLoopBeforeWaiting()
                window.contentView?.layoutSubtreeIfNeeded()
                await settleDisplayCycle(window)
                let turn78PromptView = try XCTUnwrap(
                    findVisibleTextViews(in: doc, visibleRect: doc.bounds).first {
                        $0.string.contains("User prompt for turn 78:")
                    }
                )
                let turn78PromptId = ObjectIdentifier(turn78PromptView)
                turn78PromptView.setSelectedRange(NSRange(location: 0, length: 11))
                var cappedTurns = harness.turns
                cappedTurns.removeFirst()
                cappedTurns.append(makeShortTurn(index: 9990, variant: 9))
                harness.turns = cappedTurns
                await settleDisplayCycle(window)
                let turn78PromptAfter = try XCTUnwrap(
                    findVisibleTextViews(in: doc, visibleRect: doc.bounds).first {
                        $0.string.contains("User prompt for turn 78:")
                    }
                )
                XCTAssertEqual(
                    ObjectIdentifier(turn78PromptAfter),
                    turn78PromptId,
                    "Capped eviction while scrolled up should keep turn 78 in the eager section without recreating its card"
                )
                XCTAssertEqual(
                    turn78PromptAfter.selectedRange(),
                    NSRange(location: 0, length: 11),
                    "Capped eviction while scrolled up should preserve stateful subviews on the pinned eager turn"
                )

                for _ in 0..<3 {
                    let bottomY = max(0, doc.bounds.height - sv.documentVisibleRect.height)
                    sv.contentView.scroll(to: NSPoint(x: 0, y: bottomY))
                    sv.reflectScrolledClipView(sv.contentView)
                    NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sv.contentView)
                    stepMainRunLoopBeforeWaiting()
                    window.contentView?.layoutSubtreeIfNeeded()
                }
                await settleDisplayCycle(window)

                harness.turns.append(makeShortTurn(index: 999, variant: 9))
                await settleDisplayCycle(window)
                let finalVisibleTVs = findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                XCTAssertTrue(
                    finalVisibleTVs.contains { $0.string.contains("Short reply 999") },
                    "Returning to the bottom should stick to newly appended turns"
                )

                // Scrolling up slightly and enlarging the container height until the bottom is visible
                // re-engages bottom following for subsequent turn updates.
                let slightlyAboveBottomY = max(0, doc.bounds.height - sv.documentVisibleRect.height - 80)
                sv.contentView.scroll(to: NSPoint(x: 0, y: slightlyAboveBottomY))
                sv.reflectScrolledClipView(sv.contentView)
                NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: sv.contentView)
                stepMainRunLoopBeforeWaiting()
                window.contentView?.layoutSubtreeIfNeeded()
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

                // Toggling full-width while pinned at the bottom keeps the bottom turn visible.
                UserDefaults.standard.set(!fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                await settleDisplayCycle(window)
                let toggledVisibleTVs = findVisibleTextViews(in: doc, visibleRect: sv.documentVisibleRect)
                XCTAssertTrue(
                    toggledVisibleTVs.contains { $0.string.contains("Short reply 1000") },
                    "Toggling full-width while at the bottom should keep the bottom turn visible"
                )
                UserDefaults.standard.set(fullWidth, forKey: TranscriptDrawer.fullWidthTranscriptKey)
                await settleDisplayCycle(window)
            }
        }
    }
}
