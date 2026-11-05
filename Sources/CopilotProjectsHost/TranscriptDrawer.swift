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
    let hasWorkflow: Bool
    var hasPendingQuestions: Bool = false
    let onOpen: () -> Void

    var body: some View {
        if !isOpen, controller.snapshot != nil || hasWorkflow || hasPendingQuestions {
            Button(action: onOpen) {
                Label("Show session details", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .help("Show session details")
            .accessibilityIdentifier("show-session-details")
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

private struct TranscriptUsageButton: View {
    let workflow: RemoteSessionWorkflow
    let receipts: [RemoteOperationReceipt]
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    @State private var showsPopover = false
    @State private var workflowState = SessionWorkflowState()

    var body: some View {
        let hasBudgetRequest = workflow.budgetRequest != nil
        let summary = TranscriptDrawer.usageSummary(for: workflow)
        let accessibilityText = TranscriptDrawer.usageAccessibilityLabel(for: workflow)
        Button {
            showsPopover.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: hasBudgetRequest ? "exclamationmark.circle" : "gauge.with.dots.needle.50percent")
                    .foregroundStyle(hasBudgetRequest ? Color.orange : StudioStyle.secondaryText)
                    .fixedSize()
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(hasBudgetRequest ? Color.primary : StudioStyle.secondaryText)
            }
            .font(.caption.weight(hasBudgetRequest ? .semibold : .medium))
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(StudioStyle.raised)
                    .overlay(
                        Capsule(style: .continuous)
                            .fill(hasBudgetRequest ? Color.orange.opacity(0.16) : Color.clear)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(
                        hasBudgetRequest ? Color.orange.opacity(0.65) : Color.primary.opacity(0.14),
                        lineWidth: hasBudgetRequest ? 1 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .help(accessibilityText)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("session-usage-button")
        .onChange(of: workflow.budgetRequest?.requestId) { _, _ in
            workflowState.resetBudgetAnswer()
        }
        .onChange(of: receipts) { _, values in
            workflowState.reconcile(receipts: values)
        }
        .background(
            Color.clear.popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                ScrollView {
                    SessionWorkflowContentView(
                        workflow: workflow,
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

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo("transcript-bottom", anchor: .bottom)
        DispatchQueue.main.async {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        let currentOperation = operationProvider?() ?? operation
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Session details", systemImage: "text.bubble")
                    .font(.headline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                if let currentWorkflow {
                    TranscriptUsageButton(
                        workflow: currentWorkflow,
                        receipts: currentOperation.receipts ?? [],
                        onAction: onAction
                    )
                    .id(currentOperation.conversationEpoch)
                }
                Spacer(minLength: 4)
                Button {
                    isFullWidth.toggle()
                } label: {
                    Image(systemName: isFullWidth ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                .accessibilityLabel(isFullWidth ? "Restore side drawer" : "Expand to full terminal area")
                .accessibilityIdentifier("toggle-transcript-full-width")
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Hide session details")
                .accessibilityLabel("Hide session details")
                .accessibilityIdentifier("hide-session-details")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(displayedTurns) { turn in
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
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
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
                    onFullWidthChange?(newValue)
                }
                .onChange(of: turns) { _, _ in
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
