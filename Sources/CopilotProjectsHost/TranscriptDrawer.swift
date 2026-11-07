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
    var receipts: [RemoteOperationReceipt] = []
    var conversationEpoch: String? = nil
    var hasPendingQuestions: Bool = false
    var trackerWarning: String? = nil
    var onOpen: () -> Void = {}
    var onClose: () -> Void = {}
    var onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult = { _ in
        RemoteWorkflowActionResult(state: .rejected)
    }
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
        if controller.snapshot != nil || currentWorkflow != nil || hasPendingQuestions {
            if isOpen {
                HStack(spacing: 4) {
                    if let currentWorkflow {
                        TranscriptUsageButton(
                            workflow: currentWorkflow,
                            workflowProvider: workflowProvider,
                            receipts: receipts,
                            onAction: onAction
                        )
                        .id(conversationEpoch)
                    }
                    Button {
                        isFullWidth.toggle()
                    } label: {
                        Image(systemName: isFullWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .hoverHighlight()
                    .help(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                    .accessibilityLabel(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                    .accessibilityIdentifier("toggle-transcript-full-width")
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .frame(width: 28, height: 28)
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
    var onFullWidthChange: ((Bool) -> Void)? = nil
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
                                onFullWidthChange: onFullWidthChange,
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
                                onFullWidthChange: onFullWidthChange,
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
    let workflow: RemoteSessionWorkflow
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    let receipts: [RemoteOperationReceipt]
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    @State private var showsPopover = false
    @State private var workflowState = SessionWorkflowState()

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        let hasBudgetRequest = currentWorkflow.budgetRequest != nil
        let accessibilityText = TranscriptDrawer.usageAccessibilityLabel(for: currentWorkflow)
        Button {
            showsPopover.toggle()
        } label: {
            Image(systemName: hasBudgetRequest ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(hasBudgetRequest ? Color.orange : StudioStyle.secondaryText)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("session-usage-button")
        .onChange(of: currentWorkflow.budgetRequest?.requestId) { _, _ in
            workflowState.resetBudgetAnswer()
        }
        .onChange(of: receipts) { _, values in
            workflowState.reconcile(receipts: values)
        }
        .background(
            Color.clear.popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                ScrollView {
                    SessionWorkflowContentView(
                        workflow: currentWorkflow,
                        canWrite: true,
                        receipts: receipts,
                        state: $workflowState,
                        onAction: onAction
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 380)
                .frame(maxHeight: 440)
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
    let onFullWidthChange: ((Bool) -> Void)?
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
            onFullWidthChange: onFullWidthChange,
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
    var onFullWidthChange: ((Bool) -> Void)? = nil
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

    private static let maxEagerBottomTurnCount = 8

    private static func defaultEagerTurnCount(for turns: [TranscriptTurn]) -> Int {
        var count = 0
        var estimatedHeight = 0
        for turn in turns.reversed() {
            count += 1
            let chars = turn.userContent.count + turn.assistantMessages.reduce(0) { $0 + $1.content.count }
            estimatedHeight += 130 + chars / 3
            if count >= 2 && (estimatedHeight >= 800 || count >= 6) {
                break
            }
        }
        return count
    }

    private struct ScrollMetrics: Equatable {
        let offsetY: CGFloat
        let containerWidth: CGFloat
        let isNearBottom: Bool
    }

    @State private var firstEagerTurnId: String?

    private var resolvedLazyTurnCount: Int {
        let turns = displayedTurns
        let total = turns.count
        let maxLazy = max(0, total - Self.defaultEagerTurnCount(for: turns))
        let pinnedIndex = firstEagerTurnId.flatMap { id in
            turns.firstIndex(where: { $0.id == id }) ?? (isAtBottom ? nil : 0)
        }
        guard isAtBottom else {
            return min(pinnedIndex ?? maxLazy, total)
        }
        let minLazy = max(0, total - Self.maxEagerBottomTurnCount)
        return min(max(pinnedIndex ?? maxLazy, minLazy), maxLazy)
    }

    private func syncLazyTurnCount() {
        let turns = displayedTurns
        let index = resolvedLazyTurnCount
        firstEagerTurnId = index < turns.count ? turns[index].id : nil
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
                let lazyCount = resolvedLazyTurnCount
                let eagerEnd = min(turns.count, lazyCount + Self.maxEagerBottomTurnCount)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if lazyCount > 0 {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(turns.prefix(lazyCount), content: turnCard)
                            }
                        }
                        ForEach(turns[lazyCount..<eagerEnd], content: turnCard)
                        // Keep turns appended beyond maxEagerBottomTurnCount while scrolled up in a
                        // trailing LazyVStack so the eager window stays bounded without shifting lazyCount.
                        if eagerEnd < turns.count {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(turns.dropFirst(eagerEnd), content: turnCard)
                            }
                        }
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
                        syncLazyTurnCount()
                    } else if newValue.containerWidth == oldValue.containerWidth
                        && newValue.offsetY < oldValue.offsetY {
                        isAtBottom = false
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
                    syncLazyTurnCount()
                    isAtBottom = true
                    scrollToBottom(proxy)
                    if isFullWidth {
                        onFullWidthChange?(true)
                    }
                }
                .onDisappear {
                    if isFullWidth {
                        onFullWidthChange?(false)
                    }
                }
                .onChange(of: isFullWidth) { _, newValue in
                    if isAtBottom {
                        scrollToBottom(proxy)
                    }
                    onFullWidthChange?(newValue)
                }
                .onChange(of: turns) { _, _ in
                    syncLazyTurnCount()
                    guard isAtBottom else { return }
                    scrollToBottom(proxy)
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
