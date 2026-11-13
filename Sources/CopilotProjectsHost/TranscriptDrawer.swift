import SwiftUI
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI

enum TranscriptWorkingIndicator: Equatable, Sendable {
    case working(String? = nil)
    case backgroundWork(String? = nil)

    var text: String {
        switch self {
        case .working(let activityText):
            return activityText ?? "Copilot is working…"
        case .backgroundWork(let activityText):
            return activityText ?? "Background work active"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .working(let activityText):
            return activityText ?? "Copilot is working"
        case .backgroundWork(let activityText):
            return activityText ?? "Background work active"
        }
    }

    static func resolve(
        status: SessionStatus,
        hasBackgroundWork: Bool = false,
        activityText: String? = nil
    ) -> TranscriptWorkingIndicator? {
        guard status != .waiting else { return nil }
        let trimmed = activityText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let nonEmptyText = (trimmed?.isEmpty == false) ? trimmed : nil
        switch status {
        case .running:
            return hasBackgroundWork && nonEmptyText == nil
                ? .backgroundWork(nil)
                : .working(nonEmptyText)
        case .idle:
            return hasBackgroundWork ? .backgroundWork(nonEmptyText) : nil
        case .waiting:
            return nil
        }
    }
}

@MainActor
final class TranscriptWorkingModel: ObservableObject {
    @Published private(set) var indicator: TranscriptWorkingIndicator?

    init(indicator: TranscriptWorkingIndicator? = nil) {
        self.indicator = indicator
    }

    func update(_ next: TranscriptWorkingIndicator?) {
        guard indicator != next else { return }
        indicator = next
    }
}

struct TranscriptButton: View {
    @ObservedObject var controller: TranscriptController
    let isOpen: Bool
    var workflow: RemoteSessionWorkflow? = nil
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    var modelInfo: RemoteModelInfo? = nil
    var availableModels: [RemoteAvailableModel] = []
    var operation: AgentOperationProjection = .unavailable
    var receipts: [RemoteOperationReceipt] = []
    var conversationEpoch: String? = nil
    var hasPendingQuestions: Bool = false
    var trackerWarning: String? = nil
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult = { _ in
        RemoteWorkflowActionResult(state: .rejected)
    }
    var onSwitchModel: (@MainActor (RemoteModelSelection) async -> RemoteWorkflowActionResult)? = nil
    @AppStorage(TranscriptDrawer.fullWidthTranscriptKey) private var isFullWidth = false

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        if let trackerWarning {
            Text(trackerWarning)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .help(trackerWarning)
                .accessibilityIdentifier("session-tracker-warning")
        }
        if controller.snapshot != nil || currentWorkflow != nil || hasPendingQuestions
            || modelInfo != nil || !availableModels.isEmpty {
            if isOpen {
                HStack(spacing: 4) {
                    if modelInfo != nil || !availableModels.isEmpty {
                        TranscriptModelButton(
                            modelInfo: modelInfo,
                            availableModels: availableModels,
                            workflow: currentWorkflow,
                            workflowProvider: workflowProvider,
                            operation: operation,
                            onSwitchModel: onSwitchModel
                        )
                        .id(conversationEpoch)
                    }
                    if currentWorkflow != nil || modelInfo != nil || !availableModels.isEmpty {
                        TranscriptUsageButton(
                            workflow: currentWorkflow,
                            workflowProvider: workflowProvider,
                            modelInfo: modelInfo,
                            availableModels: availableModels,
                            operation: operation,
                            receipts: receipts,
                            onAction: onAction,
                            onSwitchModel: onSwitchModel
                        )
                        .id(conversationEpoch)
                    }
                    Button {
                        isFullWidth.toggle()
                    } label: {
                        Image(systemName: isFullWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .help(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                    .accessibilityLabel(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                    .accessibilityIdentifier("toggle-transcript-full-width")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .help("Hide session details")
                    .accessibilityLabel("Hide session details")
                    .accessibilityIdentifier("hide-session-details")
                }
                .foregroundStyle(StudioStyle.secondaryText)
                .fixedSize()
            } else {
                Button(action: onOpen) {
                    Label("Show session details", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .fixedSize()
                .help("Show session details")
                .accessibilityIdentifier("show-session-details")
            }
        }
    }
}

struct TranscriptOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: TranscriptController
    let imageCapture: () -> RemoteKittyImageCapture?
    let isOpen: Bool
    let onClose: () -> Void
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    var pendingUserInputs: [RemoteUserInputRequest] = []
    var pendingElicitations: [RemoteElicitationRequest] = []
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    var operationProvider: (() -> AgentOperationProjection)? = nil
    var workingModelProvider: (() -> TranscriptWorkingModel)? = nil
    var promptComposer: DesktopSessionPromptComposer? = nil
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    var onAnswerUserInput: (@MainActor (RemoteUserInputAnswer) async -> RemoteWorkflowActionResult)? = nil
    var onAnswerElicitation: (@MainActor (RemoteElicitationAnswer) async -> RemoteWorkflowActionResult)? = nil
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if controller.snapshot != nil || workflow != nil
                || !pendingUserInputs.isEmpty || !pendingElicitations.isEmpty {
                if isOpen {
                    let resolvedWorkingModel = workingModelProvider?()
                    Group {
                        if let capture = imageCapture() {
                            ImageAssociatedTranscriptDrawer(
                                capture: capture, snapshot: controller.snapshot,
                                sessionId: controller.sessionId,
                                promptAttachments: controller.promptAttachments,
                                workflow: workflow, operation: operation,
                                pendingUserInputs: pendingUserInputs,
                                pendingElicitations: pendingElicitations,
                                workflowProvider: workflowProvider,
                                operationProvider: operationProvider,
                                workingModel: resolvedWorkingModel,
                                promptComposer: promptComposer,
                                onClose: onClose,
                                onAction: onAction,
                                onAnswerUserInput: onAnswerUserInput,
                                onAnswerElicitation: onAnswerElicitation,
                                onPreview: onPreview
                            )
                        } else {
                            TranscriptDrawer(
                                turns: controller.snapshot.map {
                                    TranscriptImageAssociation.attach(images: [], to: $0).turns
                                } ?? [],
                                imageCapture: nil,
                                sessionId: controller.sessionId,
                                promptAttachments: controller.promptAttachments,
                                copilotSessionId: controller.snapshot?.copilotSessionId,
                                workflow: workflow, operation: operation,
                                pendingUserInputs: pendingUserInputs,
                                pendingElicitations: pendingElicitations,
                                workflowProvider: workflowProvider,
                                operationProvider: operationProvider,
                                workingModel: resolvedWorkingModel,
                                promptComposer: promptComposer,
                                onClose: onClose,
                                onAction: onAction,
                                onAnswerUserInput: onAnswerUserInput,
                                onAnswerElicitation: onAnswerElicitation,
                                onPreview: onPreview
                            )
                        }
                    }
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

private struct TranscriptUsageButton: View {
    let workflow: RemoteSessionWorkflow?
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    var modelInfo: RemoteModelInfo? = nil
    var availableModels: [RemoteAvailableModel] = []
    var operation: AgentOperationProjection = .unavailable
    let receipts: [RemoteOperationReceipt]
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    var onSwitchModel: (@MainActor (RemoteModelSelection) async -> RemoteWorkflowActionResult)? = nil
    @State private var showsPopover = false
    @State private var showingModelPicker = false
    @State private var workflowState = SessionWorkflowState()

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        let hasBudgetRequest = currentWorkflow?.budgetRequest != nil
        let accessibilityText = currentWorkflow.map {
            TranscriptDrawer.usageAccessibilityLabel(for: $0)
        } ?? "Session details"
        Button {
            showsPopover.toggle()
        } label: {
            Image(systemName: hasBudgetRequest ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(hasBudgetRequest ? Color.orange : StudioStyle.secondaryText)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("session-usage-button")
        .onChange(of: currentWorkflow?.budgetRequest?.requestId) { _, _ in
            workflowState.resetBudgetAnswer()
        }
        .onChange(of: receipts) { _, values in
            workflowState.reconcile(receipts: values)
        }
        .onChange(of: showsPopover) { _, isPresented in
            if !isPresented {
                showingModelPicker = false
            }
        }
        .background(
            Color.clear.popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                if showingModelPicker {
                    DesktopModelPickerView(
                        currentModel: modelInfo,
                        availableModels: availableModels,
                        workflow: currentWorkflow,
                        operation: operation,
                        onBack: { showingModelPicker = false },
                        onApplied: { showingModelPicker = false },
                        onSwitchModel: onSwitchModel
                    )
                    .frame(width: 380)
                    .frame(maxHeight: 440)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            SessionDetailsModelSection(
                                currentModel: modelInfo,
                                availableModels: availableModels,
                                onSelectModel: { showingModelPicker = true }
                            )
                            if (modelInfo != nil || !availableModels.isEmpty)
                                && currentWorkflow != nil {
                                Divider()
                            }
                            if let currentWorkflow {
                                SessionWorkflowContentView(
                                    workflow: currentWorkflow,
                                    canWrite: true,
                                    receipts: receipts,
                                    state: $workflowState,
                                    onAction: onAction
                                )
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 380)
                    .frame(maxHeight: 440)
                }
            }
        )
    }
}

private struct ImageAssociatedTranscriptDrawer: View {
    @ObservedObject var capture: RemoteKittyImageCapture
    let snapshot: TranscriptSnapshot?
    let sessionId: String
    let promptAttachments: TranscriptPromptAttachments
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let pendingUserInputs: [RemoteUserInputRequest]
    let pendingElicitations: [RemoteElicitationRequest]
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let workingModel: TranscriptWorkingModel?
    let promptComposer: DesktopSessionPromptComposer?
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onAnswerUserInput: (@MainActor (RemoteUserInputAnswer) async -> RemoteWorkflowActionResult)?
    let onAnswerElicitation: (@MainActor (RemoteElicitationAnswer) async -> RemoteWorkflowActionResult)?
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        TranscriptDrawer(
            turns: snapshot.map {
                TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(), to: $0).turns
            } ?? [],
            imageCapture: capture,
            sessionId: sessionId,
            promptAttachments: promptAttachments,
            copilotSessionId: snapshot?.copilotSessionId,
            workflow: workflow, operation: operation,
            pendingUserInputs: pendingUserInputs,
            pendingElicitations: pendingElicitations,
            workflowProvider: workflowProvider,
            operationProvider: operationProvider,
            workingModel: workingModel,
            promptComposer: promptComposer,
            onClose: onClose,
            onAction: onAction,
            onAnswerUserInput: onAnswerUserInput,
            onAnswerElicitation: onAnswerElicitation,
            onPreview: onPreview
        )
    }
}

struct TranscriptDrawer: View {
    static let fullWidthTranscriptKey = "desktopFullWidthTranscript"
    static let defaultViewKey = "desktopDefaultView"

    enum DefaultView: String {
        case terminal
        case transcript
    }

    let turns: [TranscriptTurn]
    let imageCapture: RemoteKittyImageCapture?
    var sessionId: String = ""
    var promptAttachments = TranscriptPromptAttachments()
    var copilotSessionId: String? = nil
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    var pendingUserInputs: [RemoteUserInputRequest] = []
    var pendingElicitations: [RemoteElicitationRequest] = []
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    var workingModel: TranscriptWorkingModel? = nil
    let promptComposer: DesktopSessionPromptComposer?
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    var onAnswerUserInput: (@MainActor (RemoteUserInputAnswer) async -> RemoteWorkflowActionResult)? = nil
    var onAnswerElicitation: (@MainActor (RemoteElicitationAnswer) async -> RemoteWorkflowActionResult)? = nil
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @AppStorage(Self.fullWidthTranscriptKey) private var isFullWidth = false
    @State private var isAtBottom = true

    static func usageSummary(for workflow: RemoteSessionWorkflow, now: Date = Date()) -> String {
        if workflow.budgetRequest != nil {
            return "Budget decision needed"
        }
        var parts: [String] = []
        if let credits = workflow.totalAiCredits, credits.isFinite, credits >= 0 {
            parts.append("\(credits.formatted(.number.precision(.fractionLength(0...3)))) AI credits")
        }
        if !workflow.agents.isEmpty {
            parts.append("\(workflow.agents.count) active \(workflow.agents.count == 1 ? "agent" : "agents")")
        }
        if !workflow.schedules.isEmpty {
            parts.append("\(workflow.schedules.count) \(workflow.schedules.count == 1 ? "schedule" : "schedules")")
        }
        if !workflow.isFresh(at: now) {
            parts.append("Stale")
        } else if workflow.error != nil, parts.isEmpty {
            parts.append("Error")
        }
        return parts.isEmpty ? "Usage" : parts.joined(separator: " · ")
    }

    static func usageAccessibilityLabel(for workflow: RemoteSessionWorkflow, now: Date = Date()) -> String {
        let summary = usageSummary(for: workflow, now: now)
        if let request = workflow.budgetRequest {
            return "Budget decision needed: \(request.usedAiCredits.formatted()) of \(request.maxAiCredits.formatted()) AI credits. Usage and background work"
        }
        return summary == "Usage"
            ? "Usage and background work"
            : "Usage and background work: \(summary)"
    }

    private var displayedTurns: [TranscriptTurn] {
        Self.turnsWithoutQuestionEchoes(
            turns,
            pendingUserInputs: pendingUserInputs,
            pendingElicitations: pendingElicitations
        )
    }

    static func turnsWithoutQuestionEchoes(
        _ turns: [TranscriptTurn],
        pendingUserInputs: [RemoteUserInputRequest],
        pendingElicitations: [RemoteElicitationRequest]
    ) -> [TranscriptTurn] {
        guard !turns.isEmpty else { return turns }
        var pendingEchoes: [String: Int] = [:]
        for text in pendingUserInputs.map(\.question) + pendingElicitations.map(\.message) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                pendingEchoes[trimmed, default: 0] += 1
            }
        }
        guard !pendingEchoes.isEmpty else { return turns }
        var updated = turns
        let lastIndex = updated.count - 1
        updated[lastIndex] = withoutQuestionEchoes(
            updated[lastIndex],
            pendingEchoes: pendingEchoes
        )
        return updated
    }

    private static func withoutQuestionEchoes(
        _ turn: TranscriptTurn,
        pendingEchoes: [String: Int]
    ) -> TranscriptTurn {
        var remaining = pendingEchoes
        var hidden = Set<Int>()
        for index in turn.assistantMessages.indices.reversed() {
            let text = turn.assistantMessages[index].content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            guard let count = remaining[text], count > 0 else { break }
            remaining[text] = count - 1
            hidden.insert(index)
        }
        guard !hidden.isEmpty else { return turn }
        let kept = turn.assistantMessages.enumerated()
            .filter { !hidden.contains($0.offset) }
            .map(\.element)
        return TranscriptTurn(
            id: turn.id,
            startedAt: turn.startedAt,
            endedAt: turn.endedAt,
            kind: turn.kind,
            userContent: turn.userContent,
            assistantMessages: kept,
            tools: turn.tools,
            isAborted: turn.isAborted,
            images: turn.images,
            error: turn.error,
            reasoningSteps: turn.reasoningSteps
        )
    }

    /// Turns rendered on open, and added per page of earlier history. Only these are laid out, with
    /// real heights: a lazy stack of the older turns re-estimated its height on most layout passes,
    /// which moved the turns below it and drew its last card over them. Four of the heaviest turns
    /// seen (one with 328 tool calls) open in under 100 ms.
    private static let turnPageSize = 4

    private struct ScrollMetrics: Equatable {
        let offsetY: CGFloat
        let containerWidth: CGFloat
        let isNearBottom: Bool
    }

    /// The oldest rendered turn, set once the reader scrolls up or pages in history so turns arriving
    /// below don't push it out. Until then the newest page is rendered. It holds a start time rather
    /// than an id because the tracker's 200-turn cap drops the oldest scheduled turn first, which
    /// can be this one. It holds the conversation because `/new` and `/resume` put another one in
    /// the same drawer, and every turn of a newer conversation starts after the old pin: a test
    /// rendered all 80 turns of one at once.
    private struct FirstRendered: Equatable {
        let start: Date
        let conversation: String?
    }

    @State private var firstRendered: FirstRendered?

    private var firstRenderedStart: Date? {
        firstRendered?.conversation == copilotSessionId ? firstRendered?.start : nil
    }

    private func firstRenderedIndex(in turns: [TranscriptTurn]) -> Int {
        let newestPage = max(0, turns.count - Self.turnPageSize)
        guard let firstRenderedStart else { return newestPage }
        return turns.firstIndex { $0.startedAt >= firstRenderedStart } ?? newestPage
    }

    private func render(from turn: TranscriptTurn?) {
        firstRendered = turn.map { FirstRendered(start: $0.startedAt, conversation: copilotSessionId) }
    }

    /// Renders one more page of earlier turns. Returns false, and writes nothing, when every turn
    /// is rendered: a write here re-evaluates the whole drawer. Following the bottom, the reader is
    /// at the bottom, so a page loads only while the bottom is within a viewport of the top. SwiftUI
    /// sometimes moves the view 543 pt up for one main-queue pass after a page fills in, which
    /// loaded a page on 3 of about 1,800 opens.
    private func loadEarlierPage(bottomIsNearTop: Bool) -> Bool {
        let turns = displayedTurns
        let first = firstRenderedIndex(in: turns)
        guard first > 0, bottomIsNearTop || !isAtBottom else { return false }
        render(from: turns[max(0, first - Self.turnPageSize)])
        return true
    }

    private func turnCard(_ turn: TranscriptTurn) -> some View {
        TranscriptTurnCard(
            turn: turn,
            imageCapture: imageCapture,
            promptAttachments: promptAttachments.items(
                forTurnId: turn.id,
                sessionId: sessionId,
                copilotSessionId: copilotSessionId ?? ""
            ),
            toolImages: promptAttachments.items(
                forTurnId: turn.id,
                sessionId: sessionId,
                copilotSessionId: copilotSessionId ?? "",
                fromTools: true
            ),
            onPreview: onPreview
        )
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        isAtBottom = true
        proxy.scrollTo("transcript-bottom", anchor: .bottom)
        DispatchQueue.main.async {
            guard isAtBottom else { return }
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
            DispatchQueue.main.async {
                guard isAtBottom else { return }
                proxy.scrollTo("transcript-bottom", anchor: .bottom)
            }
        }
    }

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                let turns = displayedTurns
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(turns[firstRenderedIndex(in: turns)...], content: turnCard)
                        ForEach(pendingUserInputs, id: \.requestId) { request in
                            DesktopUserInputCard(
                                request: request,
                                onAnswer: onAnswerUserInput,
                                onFocusTerminal: onClose
                            )
                        }
                        ForEach(pendingElicitations, id: \.requestId) { request in
                            DesktopElicitationCard(
                                request: request,
                                onAnswer: onAnswerElicitation,
                                onFocusTerminal: onClose
                            )
                        }
                        if let workingModel {
                            ObservedTranscriptWorkingRow(
                                workingModel: workingModel,
                                hasPendingInput: !pendingUserInputs.isEmpty
                                    || !pendingElicitations.isEmpty
                                    || currentWorkflow?.budgetRequest != nil
                            )
                        }
                        ForEach(currentWorkflow?.pendingMessages ?? []) { pending in
                            TranscriptTurnCard(
                                turn: TranscriptTurn(
                                    id: pending.messageId,
                                    startedAt: Date(
                                        timeIntervalSince1970: Double(currentWorkflow?.observedAtMilliseconds ?? 0) / 1_000
                                    ),
                                    endedAt: nil,
                                    kind: "foreground",
                                    userContent: pending.text,
                                    assistantMessages: [],
                                    tools: [],
                                    isAborted: false
                                ),
                                imageCapture: nil,
                                isPending: true,
                                pendingMode: pending.mode,
                                onPreview: onPreview
                            )
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                    }
                    .background(TranscriptHistoryPager(loadEarlierPage: loadEarlierPage))
                    .padding(.horizontal, 18)
                    .padding(.top, 5)
                    .padding(.bottom, 6)
                }
                .padding(.top, 1)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        offsetY: geometry.contentOffset.y,
                        containerWidth: geometry.containerSize.width,
                        isNearBottom: geometry.contentSize.height <= geometry.containerSize.height + 1
                            || geometry.visibleRect.maxY >= geometry.contentSize.height - 24
                    )
                } action: { oldValue, newValue in
                    if newValue.containerWidth != oldValue.containerWidth {
                        if isAtBottom {
                            scrollToBottom(proxy)
                        }
                    }
                    if newValue.isNearBottom {
                        isAtBottom = true
                    } else if newValue.containerWidth == oldValue.containerWidth
                        && newValue.offsetY < oldValue.offsetY {
                        isAtBottom = false
                        if firstRenderedStart == nil {
                            render(from: turns.dropFirst(firstRenderedIndex(in: turns)).first)
                        }
                    }
                }
                .background {
                    if let workingModel {
                        ObservedTranscriptWorkingScrollObserver(
                            workingModel: workingModel,
                            hasPendingInput: !pendingUserInputs.isEmpty
                                || !pendingElicitations.isEmpty
                                || currentWorkflow?.budgetRequest != nil,
                            onVisibilityChange: {
                                guard isAtBottom else { return }
                                scrollToBottom(proxy)
                            }
                        )
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    isAtBottom = true
                    scrollToBottom(proxy)
                }
                .onChange(of: isFullWidth) { _, _ in
                    if isAtBottom {
                        scrollToBottom(proxy)
                    }
                }
                .onChange(of: turns) { _, _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
                }
                // A short newest page fills in an earlier one while still following the bottom.
                // Without this the drawer opened 602 pt above the bottom on a session of short turns.
                .onChange(of: firstRenderedStart) { _, _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
                }
                // Coming back to a conversation starts from its newest turns. A test that paged up,
                // switched conversation and switched back rendered 20 turns at once instead of 12.
                .onChange(of: copilotSessionId) { _, _ in
                    firstRendered = nil
                }
                .onChange(of: currentWorkflow?.pendingMessages) { _, _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: pendingUserInputs) { _, _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: pendingElicitations) { _, _ in
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
                }
            }

            if let promptComposer, workflow != nil {
                Divider()
                TranscriptPromptComposerView(
                    composer: promptComposer,
                    workflow: workflow,
                    operation: operation,
                    workflowProvider: workflowProvider,
                    operationProvider: operationProvider,
                    onAction: onAction,
                    onPreview: onPreview
                )
            }
        }
        .frame(width: isFullWidth ? nil : 420)
        .frame(maxWidth: isFullWidth ? .infinity : nil, maxHeight: .infinity)
        .background(StudioStyle.chrome)
        .overlay(alignment: .leading) {
            if !isFullWidth {
                Color(nsColor: .separatorColor).frame(width: 1).allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(isFullWidth ? 0 : 0.2), radius: isFullWidth ? 0 : 12, x: isFullWidth ? 0 : -4)
    }
}

/// Renders an earlier page of the transcript when the reader comes within a viewport of the oldest
/// rendered turn, and keeps the turns on screen where they were when that page is laid out above.
///
/// The offset moves in AppKit, in the layout pass that places the page. SwiftUI's `ScrollPosition`
/// applies a scroll one pass later, and a scroll event landing in between replaced it: in the jump
/// harness, 9 of 49 page loads moved the transcript by the height of the page.
private struct TranscriptHistoryPager: NSViewRepresentable {
    /// Renders an earlier page, given whether the bottom is within a viewport of the top. Returns
    /// false once the whole transcript is rendered.
    let loadEarlierPage: (_ bottomIsNearTop: Bool) -> Bool

    func makeNSView(context: Context) -> PagerView { PagerView() }

    func updateNSView(_ view: PagerView, context: Context) {
        view.loadEarlierPage = loadEarlierPage
    }

    final class PagerView: NSView {
        var loadEarlierPage: (_ bottomIsNearTop: Bool) -> Bool = { _ in false }
        /// Set when a page is requested, until it is laid out: the content height, and a text view
        /// on screen with its position in the content.
        private var pendingPage: (height: CGFloat, anchor: NSView?, anchorY: CGFloat)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let clip = enclosingScrollView?.contentView else { return }
            clip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(loadPageIfNearTop),
                name: NSView.boundsDidChangeNotification, object: clip
            )
        }

        /// This view is the background of the turns, so it is laid out whenever they change size,
        /// after the hosting view has placed them. The content's frame-change notification arrives
        /// before they move, and did not arrive at all for a drawer laid out before it was shown.
        override func layout() {
            super.layout()
            loadPageIfNearTop()
            guard let page = pendingPage, let scrollView = enclosingScrollView,
                  let content = scrollView.documentView, content.frame.height != page.height else { return }
            pendingPage = nil
            let clip = scrollView.contentView
            // Within 24 pt of the end the drawer follows the bottom, and has already scrolled to the
            // new bottom in this pass. Moving the page again put the view 606 pt past the end on
            // every page filled in at the bottom.
            guard clip.bounds.maxY < content.frame.height - 24 else { return }
            // The turns moved down by the height of the page. Measure that on a text view that was
            // on screen rather than on the content height: a streaming turn growing below the
            // viewport in the same pass moved the transcript 22 pt on 1 of 49 page loads in the
            // jump harness.
            let moved = page.anchor.map { $0.convert(NSPoint.zero, to: content).y - page.anchorY }
                ?? content.frame.height - page.height
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: clip.bounds.minY + moved))
            scrollView.reflectScrolledClipView(clip)
        }

        @objc private func loadPageIfNearTop() {
            // Rendering more turns isn't allowed inside a layout pass or a scroll notification.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingPage == nil, let scrollView = self.enclosingScrollView,
                      let content = scrollView.documentView else { return }
                let clip = scrollView.contentView.bounds
                guard clip.minY < clip.height,
                      self.loadEarlierPage(content.frame.height - clip.height < clip.height) else { return }
                let anchor = Self.textView(in: content, intersecting: scrollView.documentVisibleRect, of: content)
                self.pendingPage = (content.frame.height, anchor, anchor?.convert(NSPoint.zero, to: content).y ?? 0)
            }
        }

        private static func textView(in view: NSView, intersecting visible: NSRect, of content: NSView) -> NSView? {
            if view is NSTextView {
                return view.convert(view.bounds, to: content).intersects(visible) ? view : nil
            }
            for subview in view.subviews {
                if let found = textView(in: subview, intersecting: visible, of: content) { return found }
            }
            return nil
        }
    }
}

private struct ObservedTranscriptWorkingRow: View {
    @ObservedObject var workingModel: TranscriptWorkingModel
    let hasPendingInput: Bool

    var body: some View {
        if !hasPendingInput, let indicator = workingModel.indicator {
            TranscriptWorkingRow(indicator: indicator)
                .equatable()
        }
    }
}

private struct ObservedTranscriptWorkingScrollObserver: View {
    @ObservedObject var workingModel: TranscriptWorkingModel
    let hasPendingInput: Bool
    let onVisibilityChange: () -> Void

    var body: some View {
        let isVisible = !hasPendingInput && workingModel.indicator != nil
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isVisible) { _, _ in
                onVisibilityChange()
            }
    }
}

private struct TranscriptWorkingRow: View, Equatable {
    let indicator: TranscriptWorkingIndicator

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(indicator.text)
                .font(.callout)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(indicator.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("transcript-working-indicator")
    }
}
