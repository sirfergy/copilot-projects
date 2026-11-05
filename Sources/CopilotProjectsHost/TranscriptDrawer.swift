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
    @AppStorage(Self.fullWidthTranscriptKey) private var isFullWidth = Self.usesFullTerminalArea(storedValue: nil)
    @State private var isAtBottom = true

    static func usesFullTerminalArea(storedValue: Bool?) -> Bool {
        storedValue ?? false
    }

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

struct QuickReplyItem: Codable, Equatable, Identifiable, Sendable {
    static let maxCount = 12
    static let maxLabelLength = 24
    static let maxPromptLength = 2_000

    let label: String
    let prompt: String

    var id: String { label.folding(options: .caseInsensitive, locale: nil) }

    enum CodingKeys: String, CodingKey {
        case label
        case prompt
    }
}

enum QuickReplyValidationError: Equatable, LocalizedError, Sendable {
    case emptyLabel
    case labelTooLong(max: Int)
    case emptyPrompt
    case promptTooLong(max: Int)
    case duplicateLabel(String)
    case tooManyReplies(max: Int)

    var message: String {
        switch self {
        case .emptyLabel:
            return "Label cannot be empty."
        case .labelTooLong(let max):
            return "Label must be \(max) characters or fewer."
        case .emptyPrompt:
            return "Prompt cannot be empty."
        case .promptTooLong(let max):
            return "Prompt must be \(max) characters or fewer."
        case .duplicateLabel(let label):
            return "A quick reply labeled “\(label)” already exists."
        case .tooManyReplies(let max):
            return "You can configure at most \(max) quick replies."
        }
    }

    var errorDescription: String? { message }
}

enum QuickReplyConfiguration: Equatable, Sendable {
    static let storageKey = "quickReplyList"

    static let defaultItems: [QuickReplyItem] = [
        QuickReplyItem(label: "Approve", prompt: "Approve"),
        QuickReplyItem(label: "Post", prompt: "Post"),
        QuickReplyItem(label: "Merge when ready", prompt: "Merge when ready"),
        QuickReplyItem(label: "Request CCR", prompt: "Request CCR and when green mark ready"),
        QuickReplyItem(label: "Max review", prompt: "Do a max review"),
        QuickReplyItem(label: "Keep going", prompt: "Keep going!"),
        QuickReplyItem(label: "No bloat?", prompt: "No bloat or over-engineering?"),
    ]

    case defaultReplies
    case custom([QuickReplyItem])

    var isCustomized: Bool {
        if case .custom = self { return true }
        return false
    }

    var activeReplies: [QuickReplyItem] {
        switch self {
        case .defaultReplies:
            return Self.defaultItems
        case .custom(let items):
            return items
        }
    }

    static func validateItem(label: String, prompt: String) -> Result<QuickReplyItem, QuickReplyValidationError> {
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            return .failure(.emptyLabel)
        }
        guard trimmedLabel.count <= QuickReplyItem.maxLabelLength else {
            return .failure(.labelTooLong(max: QuickReplyItem.maxLabelLength))
        }
        guard !trimmedPrompt.isEmpty else {
            return .failure(.emptyPrompt)
        }
        guard trimmedPrompt.count <= QuickReplyItem.maxPromptLength else {
            return .failure(.promptTooLong(max: QuickReplyItem.maxPromptLength))
        }
        return .success(QuickReplyItem(label: trimmedLabel, prompt: trimmedPrompt))
    }

    static func validateList(_ items: [QuickReplyItem]) -> Result<[QuickReplyItem], QuickReplyValidationError> {
        guard items.count <= QuickReplyItem.maxCount else {
            return .failure(.tooManyReplies(max: QuickReplyItem.maxCount))
        }
        var normalized: [QuickReplyItem] = []
        normalized.reserveCapacity(items.count)
        var seenLabels = Set<String>()
        for item in items {
            switch validateItem(label: item.label, prompt: item.prompt) {
            case .failure(let error):
                return .failure(error)
            case .success(let validItem):
                guard seenLabels.insert(validItem.id).inserted else {
                    return .failure(.duplicateLabel(validItem.label))
                }
                normalized.append(validItem)
            }
        }
        return .success(normalized)
    }

    static func resolved(fromJSON jsonString: String?) -> QuickReplyConfiguration {
        guard let jsonString,
              let data = jsonString.data(using: .utf8),
              let valid = decodeCustomList(from: data) else {
            return .defaultReplies
        }
        return .custom(valid)
    }

    static func load(from defaults: UserDefaults = .standard) -> QuickReplyConfiguration {
        resolved(fromJSON: defaults.string(forKey: storageKey))
    }

    @discardableResult
    static func save(
        _ items: [QuickReplyItem],
        to defaults: UserDefaults = .standard
    ) -> Result<[QuickReplyItem], QuickReplyValidationError> {
        switch validateList(items) {
        case .failure(let error):
            return .failure(error)
        case .success(let validated):
            guard let data = try? JSONEncoder().encode(validated),
                  let json = String(data: data, encoding: .utf8) else {
                return .failure(.emptyLabel)
            }
            defaults.set(json, forKey: storageKey)
            return .success(validated)
        }
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    private static func decodeCustomList(from data: Data) -> [QuickReplyItem]? {
        guard let decoded = try? JSONDecoder().decode([QuickReplyItem].self, from: data),
              case .success(let valid) = validateList(decoded) else {
            return nil
        }
        return valid
    }
}

extension RemotePromptMode {
    var sendButtonTitle: String {
        switch self {
        case .immediate: "Steer"
        case .enqueue: "Queue"
        }
    }

    var sendAccessibilityLabel: String {
        "\(sendButtonTitle) (\(title))"
    }
}

struct TranscriptPromptComposerView: View {
    static let showQuickReplyChipsKey = "showQuickReplyChips"
    static let quickReplyListKey = QuickReplyConfiguration.storageKey

    @ObservedObject var composer: DesktopSessionPromptComposer
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @AppStorage(Self.showQuickReplyChipsKey) private var showQuickReplyChips = true
    @AppStorage(Self.quickReplyListKey) private var quickReplyListJSON: String?
    @FocusState private var promptFocused: Bool

    var isDeliveryModeDisabled: Bool {
        composer.isSending || composer.pendingOperationId != nil
    }

    private var liveWorkflow: RemoteSessionWorkflow? {
        workflowProvider?() ?? workflow
    }

    private var liveOperation: AgentOperationProjection {
        operationProvider?() ?? operation
    }

    @MainActor
    static func canShowQuickReplies(
        showQuickReplyChips: Bool,
        composer: DesktopSessionPromptComposer,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date
    ) -> Bool {
        guard showQuickReplyChips,
              composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              composer.attachments.isEmpty,
              !composer.isSending,
              !composer.isAttaching,
              composer.pendingOperationId == nil,
              operation.support == .receipts,
              let epoch = operation.conversationEpoch,
              !epoch.isEmpty,
              let workflow,
              workflow.supports(.send, at: now),
              workflow.sendReady else {
            return false
        }
        return true
    }

    @MainActor
    static func visibleQuickReplies(
        showQuickReplyChips: Bool,
        storedJSON: String?,
        composer: DesktopSessionPromptComposer,
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date = Date()
    ) -> [QuickReplyItem] {
        guard canShowQuickReplies(
            showQuickReplyChips: showQuickReplyChips,
            composer: composer,
            workflow: workflow,
            operation: operation,
            now: now
        ) else {
            return []
        }
        return QuickReplyConfiguration.resolved(fromJSON: storedJSON).activeReplies
    }

    private func canSendQuickReply(
        workflow: RemoteSessionWorkflow?,
        operation: AgentOperationProjection,
        now: Date
    ) -> Bool {
        Self.canShowQuickReplies(
            showQuickReplyChips: showQuickReplyChips,
            composer: composer,
            workflow: workflow,
            operation: operation,
            now: now
        )
    }

    private func blockedMessage(now: Date) -> String? {
        composer.statusMessage
            ?? composer.attachmentsBlockedReason(workflow: liveWorkflow, operation: liveOperation, now: now)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let currentWorkflow = liveWorkflow
            let currentOperation = liveOperation
            let now = context.date
            VStack(alignment: .leading, spacing: 8) {
                if !composer.attachments.isEmpty {
                    HStack {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(composer.attachments) { item in
                                    StagedAttachmentCard(
                                        item: item,
                                        removeDisabled: composer.isSending || composer.pendingOperationId != nil,
                                        onPreview: { onPreview(composer.previewItem(for: item)) },
                                        onRemove: { composer.removeAttachment(id: item.id) }
                                    )
                                }
                            }
                        }
                        Button("Clear all") {
                            composer.clearAttachments()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .disabled(composer.isSending || composer.pendingOperationId != nil)
                        .accessibilityIdentifier("desktop-clear-screenshots")
                    }
                    .accessibilityIdentifier("desktop-screenshot-previews")
                }

                if let message = blockedMessage(now: now) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("desktop-screenshot-status")
                        Spacer(minLength: 0)
                        if composer.statusMessage != nil {
                            Button {
                                composer.dismissStatusMessage()
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Dismiss attachment status")
                        }
                    }
                }

                let replies = Self.visibleQuickReplies(
                    showQuickReplyChips: showQuickReplyChips,
                    storedJSON: quickReplyListJSON,
                    composer: composer,
                    workflow: currentWorkflow,
                    operation: currentOperation,
                    now: now
                )
                if !replies.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(replies) { item in
                                Button(item.label) {
                                    guard canSendQuickReply(
                                        workflow: liveWorkflow,
                                        operation: liveOperation,
                                        now: Date()
                                    ) else { return }
                                    composer.prompt = item.prompt
                                    submitPrompt()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                    .accessibilityIdentifier("desktop-quick-reply-strip")
                }

                HStack(spacing: 8) {
                    Spacer(minLength: 0)

                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!composer.canAttach(workflow: currentWorkflow, operation: currentOperation, now: now))
                    .help(composer.attachHelpText(workflow: currentWorkflow, operation: currentOperation, now: now))
                    .accessibilityLabel("Attach files")
                    .accessibilityIdentifier("desktop-attach-screenshot")

                    Button(action: pasteScreenshots) {
                        Image(systemName: "doc.on.clipboard")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!composer.canAttach(workflow: currentWorkflow, operation: currentOperation, now: now))
                    .help(composer.attachHelpText(workflow: currentWorkflow, operation: currentOperation, now: now))
                    .accessibilityLabel("Paste attachment")
                    .accessibilityIdentifier("desktop-paste-screenshot")
                }

                let canSend = composer.canSend(workflow: currentWorkflow, operation: currentOperation, now: now)
                let modeDisabled = isDeliveryModeDisabled
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Copilot", text: $composer.prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                        .disabled(modeDisabled)
                        .accessibilityLabel("Message Copilot")
                        .accessibilityIdentifier("desktop-prompt-field")
                        .onSubmit(submitPrompt)

                    HStack(spacing: 1) {
                        Button(action: submitPrompt) {
                            Text(composer.mode.sendButtonTitle)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend)
                        .background(Color.accentColor.opacity(canSend ? 1 : 0.5))
                        .help(composer.mode.title)
                        .accessibilityLabel(composer.mode.sendAccessibilityLabel)
                        .accessibilityIdentifier("desktop-send-prompt")

                        Menu {
                            Picker("Message delivery mode", selection: $composer.mode) {
                                ForEach(RemotePromptMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.button)
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                        .disabled(modeDisabled)
                        .background(Color.accentColor.opacity(modeDisabled ? 0.5 : 1))
                        .help("Message delivery mode: \(composer.mode.title)")
                        .accessibilityLabel("Message delivery mode")
                        .accessibilityValue(composer.mode.title)
                        .accessibilityIdentifier("desktop-send-mode")
                    }
                    .fixedSize()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
            }
            .padding(12)
        }
        .onPasteCommand(of: [.image, .fileURL]) { _ in
            pasteScreenshots()
        }
        .onAppear {
            composer.isPromptFieldFocused = promptFocused
            let currentOp = liveOperation
            composer.reconcileReceipts(currentOp.receipts, conversationEpoch: currentOp.conversationEpoch)
        }
        .onDisappear {
            composer.isPromptFieldFocused = false
        }
        .onChange(of: promptFocused) { _, focused in
            composer.isPromptFieldFocused = focused
        }
        .onChange(of: operation.conversationEpoch) { _, newEpoch in
            composer.syncConversationEpoch(newEpoch)
        }
        .onChange(of: operation.receipts) { _, newReceipts in
            composer.reconcileReceipts(newReceipts, conversationEpoch: liveOperation.conversationEpoch)
        }
        .onChange(of: composer.pendingOperationId) { _, _ in
            let currentOp = liveOperation
            composer.reconcileReceipts(currentOp.receipts, conversationEpoch: currentOp.conversationEpoch)
        }
    }

    private func pasteScreenshots() {
        Task { @MainActor in
            _ = await composer.pasteFromPasteboard(workflow: liveWorkflow, operation: liveOperation)
        }
    }

    private func submitPrompt() {
        let currentWorkflow = liveWorkflow
        let currentOperation = liveOperation
        guard composer.canSend(workflow: currentWorkflow, operation: currentOperation) else { return }
        Task { @MainActor in
            await composer.send(workflow: currentWorkflow, operation: currentOperation, onAction: onAction)
        }
    }

    private func chooseFiles() {
        let currentWorkflow = liveWorkflow
        let currentOperation = liveOperation
        guard composer.canAttach(workflow: currentWorkflow, operation: currentOperation) else { return }
        let limits = composer.imageLimits(workflow: currentWorkflow, operation: currentOperation)
        let allowText = composer.supportsFileAttachments(workflow: currentWorkflow, operation: currentOperation)
        let maxCount = composer.maxAttachmentCount(workflow: currentWorkflow, operation: currentOperation)
        let panel = NSOpenPanel()
        panel.title = allowText ? "Attach Files" : "Attach Screenshots"
        panel.prompt = "Attach"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = maxCount - composer.attachments.count > 1
        panel.allowedContentTypes = DesktopScreenshotAttachmentImage.allowedPickerContentTypes(
            allowImages: limits != nil,
            allowTextFiles: allowText
        )
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        Task { @MainActor in
            await composer.attachFiles(urls, workflow: liveWorkflow, operation: liveOperation)
        }
    }
}

private struct StagedAttachmentCard: View {
    let item: DesktopSessionPromptComposer.StagedAttachment
    let removeDisabled: Bool
    let onPreview: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if item.isImage {
                Button(action: onPreview) {
                    if let image = NSImage(data: item.previewPNGData) ?? NSImage(data: item.data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Label(item.displayName, systemImage: "photo")
                            .font(.caption2)
                            .frame(width: 56, height: 42)
                    }
                }
                .buttonStyle(.plain)
                .help("Open screenshot preview")
                .accessibilityLabel("Open screenshot preview")
            } else {
                Label(item.displayName, systemImage: "doc.text")
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 160, minHeight: 28)
                    .padding(.horizontal, 6)
                    .help(item.displayName)
                    .accessibilityLabel("Attached file \(item.displayName)")
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            .buttonStyle(.borderless)
            .disabled(removeDisabled)
            .help("Remove attachment")
            .accessibilityLabel("Remove attachment")
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(StudioStyle.raised)
        )
    }
}

private struct TranscriptTurnCard: View {
    let turn: TranscriptTurn
    let imageCapture: RemoteKittyImageCapture?
    var promptAttachments: [TranscriptPromptAttachments.Item] = []
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(turn.kind == "scheduled" ? "Scheduled" :
                    turn.kind == "automated" ? "Automated" : "You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
                if turn.isAborted {
                    Text("Stopped")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.12)))
                }
                if turn.error != nil {
                    Text("Failed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red.opacity(0.12)))
                }
                Spacer()
                Text(turn.startedAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(StudioStyle.secondaryText)
            }

            if !turn.userContent.isEmpty {
                transcriptText(turn.userContent)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(StudioStyle.message)
                    )
            }

            ForEach(promptAttachments) { item in
                TranscriptImageView(
                    identity: item.identity,
                    data: item.data,
                    onPreview: onPreview
                )
            }

            if !turn.nonEmptyReasoningSteps.isEmpty {
                TranscriptReasoningView(
                    steps: turn.nonEmptyReasoningSteps,
                    summaryLabel: turn.reasoningSummaryLabel,
                    latestHeading: turn.latestReasoningHeading
                )
            }

            ForEach(turn.timelineItems(includingBlankAssistantMessages: true)) { item in
                switch item {
                case .assistant(let message):
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Copilot")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(StudioStyle.secondaryText)
                        transcriptText(message.content)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                case .image(let image):
                    if let imageCapture {
                        TranscriptImageView(
                            identity: TranscriptImageIdentity(
                                sessionId: imageCapture.sessionId,
                                imageId: image.imageId,
                                version: image.contentVersion
                            ),
                            data: imageCapture.imageData(imageId: image.imageId, version: image.contentVersion),
                            onPreview: onPreview
                        )
                    }
                }
            }

            if !turn.tools.isEmpty {
                TranscriptTools(tools: turn.tools)
            }
            if let error = turn.error {
                TranscriptTurnFailure(error: error)
            }
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func transcriptText(_ text: String) -> some View {
        MarkdownText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptReasoningView: View {
    let steps: [String]
    let summaryLabel: String
    let latestHeading: String?
    @State private var isExpanded = false

    private var titleLabel: String {
        steps.count > 1 ? "Thinking (\(steps.count) steps)" : "Thinking"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "brain")
                        .font(.caption)
                    Text(titleLabel)
                        .font(.caption.weight(.medium))
                        .layoutPriority(1)
                    if let latestHeading, !latestHeading.isEmpty {
                        Text("· \(latestHeading)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioStyle.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryLabel)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("transcript-thinking-toggle")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        if index > 0 {
                            Divider()
                        }
                        transcriptText(step)
                            .font(.callout)
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(StudioStyle.raised)
                )
            }
        }
    }

    private func transcriptText(_ text: String) -> some View {
        MarkdownText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The CLI's own failure text, kept selectable so its request ID can be copied.
private struct TranscriptTurnFailure: View {
    let error: TranscriptTurnError

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Request failed")
                    .font(.callout.weight(.semibold))
                Text(error.message)
                    .font(.callout)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct TranscriptTools: View {
    let tools: [TranscriptTool]
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(
            "\(tools.count) tool\(tools.count == 1 ? "" : "s")",
            isExpanded: $expanded
        ) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tools) { tool in
                    HStack(spacing: 7) {
                        Image(systemName: icon(for: tool))
                            .foregroundStyle(color(for: tool))
                        Text(tool.title)
                            .lineLimit(1)
                        Spacer()
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private func icon(for tool: TranscriptTool) -> String {
        switch tool.success {
        case true: return "checkmark.circle.fill"
        case false: return "xmark.circle.fill"
        case nil: return "circle.dotted"
        }
    }

    private func color(for tool: TranscriptTool) -> Color {
        switch tool.success {
        case true: return .green
        case false: return .red
        case nil: return .secondary
        }
    }
}

// MARK: - Interactive pending questions (`ask_user` & `elicitation`)

struct DesktopElicitationField: Identifiable, Equatable {
    enum Kind: Equatable {
        case stringEnum([String])
        case stringOneOf([Choice])
        case stringMultiSelect(choices: [Choice], maxItems: Int?)
        case bool
        case number
        case string(minLength: Int?, maxLength: Int?)
    }

    struct Choice: Equatable {
        let value: String
        let title: String
    }

    let key: String
    let title: String
    let description: String?
    let kind: Kind
    let required: Bool
    let defaultValue: RemoteJSONValue?
    let schema: RemoteJSONValue

    var id: String { key }

    func accepts(
        _ value: RemoteJSONValue,
        allowFreeformChoice: Bool = false
    ) -> Bool {
        guard AppModel.isValidElicitationContent([key: value]),
              AppModel.elicitationValue(
                  value,
                  satisfies: schema,
                  allowFreeformStringChoice: allowFreeformChoice
              ) else {
            return false
        }
        if case .stringMultiSelect = kind, case let .array(items) = value {
            var seen = Set<String>()
            return items.allSatisfy {
                if case let .string(string) = $0 { return seen.insert(string).inserted }
                return false
            }
        }
        return true
    }

    func normalizedStringInput(_ text: String) -> RemoteJSONValue? {
        guard case .string = kind else { return nil }
        let value = RemoteJSONValue.string(text)
        if !required, text.isEmpty, !accepts(value) {
            return nil
        }
        return value
    }

    var singleChoiceOptions: [Choice] {
        switch kind {
        case .stringEnum(let options):
            options.map { Choice(value: $0, title: $0.isEmpty ? "Empty string" : $0) }
        case .stringOneOf(let choices):
            choices
        case .bool, .number, .string, .stringMultiSelect:
            []
        }
    }

    static func toggledSelection(
        _ value: String,
        in selected: [String],
        choices: [Choice],
        maxItems: Int?
    ) -> [String]? {
        var selection = Set(selected)
        if selection.contains(value) {
            selection.remove(value)
        } else {
            if let maxItems, selection.count >= maxItems { return nil }
            selection.insert(value)
        }
        return choices.map(\.value).filter { selection.contains($0) }
    }

    static func selectedStrings(_ value: RemoteJSONValue?) -> [String] {
        guard case let .array(items)? = value else { return [] }
        return items.compactMap {
            if case let .string(string) = $0 { return string }
            return nil
        }
    }

    func toggledSelectionValue(_ value: String, in current: RemoteJSONValue?) -> RemoteJSONValue?? {
        guard case let .stringMultiSelect(choices, maxItems) = kind,
              let ordered = Self.toggledSelection(
                  value,
                  in: Self.selectedStrings(current),
                  choices: choices,
                  maxItems: maxItems
              ) else { return nil }
        let selection = RemoteJSONValue.array(ordered.map(RemoteJSONValue.string))
        if ordered.isEmpty, !required, !accepts(selection) {
            return .some(nil)
        }
        return .some(selection)
    }
}

struct DesktopElicitationForm: Equatable {
    struct InitialState: Equatable {
        let values: [String: RemoteJSONValue]
        let customChoiceFields: Set<String>
    }

    let fields: [DesktopElicitationField]
    let allowsFreeformChoices: Bool
    let schema: RemoteJSONValue
    private static let maxFields = 32
    private static let maxChoices = 50
    static let propertyOrderKey = "x-copilot-projects-property-order"

    static func parse(
        _ schema: RemoteJSONValue?,
        allowFreeformChoices: Bool = false
    ) -> DesktopElicitationForm? {
        guard let schema, case let .object(root) = schema else { return nil }
        let supportedRootKeys: Set<String> = [
            "$schema", "type", "title", "description", "properties", "required",
            "additionalProperties", propertyOrderKey,
        ]
        guard root.keys.allSatisfy({ supportedRootKeys.contains($0) }) else { return nil }
        if let type = root["type"] {
            guard case .string("object") = type else { return nil }
        }
        guard case let .object(properties)? = root["properties"], !properties.isEmpty else {
            return nil
        }
        guard properties.count <= maxFields else { return nil }
        var required = Set<String>()
        if let requiredValue = root["required"] {
            guard case let .array(items) = requiredValue else { return nil }
            for item in items {
                guard case let .string(name) = item else { return nil }
                required.insert(name)
            }
        }
        guard required.isSubset(of: Set(properties.keys)) else { return nil }

        var fields: [DesktopElicitationField] = []
        for key in fieldOrder(root[propertyOrderKey], properties: properties) {
            guard let fieldSchema = properties[key],
                  case let .object(prop) = fieldSchema else { return nil }
            guard let kind = fieldKind(prop) else { return nil }
            let title: String
            if case let .string(value)? = prop["title"] { title = value } else { title = key }
            let description: String?
            if case let .string(value)? = prop["description"] {
                description = value
            } else {
                description = nil
            }
            fields.append(
                DesktopElicitationField(
                    key: key,
                    title: title,
                    description: description,
                    kind: kind,
                    required: required.contains(key),
                    defaultValue: prop["default"],
                    schema: fieldSchema
                )
            )
        }

        guard !fields.isEmpty else { return nil }
        return DesktopElicitationForm(
            fields: fields,
            allowsFreeformChoices: allowFreeformChoices,
            schema: schema
        )
    }

    func validatedContent(
        values: [String: RemoteJSONValue],
        touched: Set<String>,
        customChoiceFields: Set<String> = []
    ) -> [String: RemoteJSONValue]? {
        var payload: [String: RemoteJSONValue] = [:]
        for field in fields {
            guard let value = values[field.key] else {
                if field.required { return nil }
                continue
            }
            if customChoiceFields.contains(field.key),
               case let .string(text) = value,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            guard field.accepts(
                value,
                allowFreeformChoice: allowsFreeformChoices
            ) else { return nil }
            if field.required || touched.contains(field.key) || field.defaultValue != nil {
                payload[field.key] = value
            }
        }
        guard AppModel.isAcceptableElicitationContent(
            payload,
            satisfies: schema,
            allowFreeformStringChoices: allowsFreeformChoices
        ) else {
            return nil
        }
        return payload
    }

    func initialState() -> InitialState {
        var values: [String: RemoteJSONValue] = [:]
        var customChoiceFields: Set<String> = []
        for field in fields {
            if let defaultValue = field.defaultValue,
               field.accepts(
                   defaultValue,
                   allowFreeformChoice: allowsFreeformChoices
               ) {
                values[field.key] = defaultValue
                if allowsFreeformChoices,
                   !field.accepts(defaultValue) {
                    customChoiceFields.insert(field.key)
                }
            } else if field.required {
                switch field.kind {
                case .stringEnum(let options):
                    if let first = options.first {
                        values[field.key] = .string(first)
                    }
                case .stringOneOf(let choices):
                    if let first = choices.first {
                        values[field.key] = .string(first.value)
                    }
                case .bool:
                    values[field.key] = .bool(false)
                case .string:
                    values[field.key] = .string("")
                case .stringMultiSelect:
                    values[field.key] = .array([])
                case .number:
                    break
                }
            }
        }
        return InitialState(
            values: values,
            customChoiceFields: customChoiceFields
        )
    }

    private static func fieldOrder(
        _ value: RemoteJSONValue?,
        properties: [String: RemoteJSONValue]
    ) -> [String] {
        if case let .array(entries)? = value {
            let keys = entries.compactMap { entry -> String? in
                if case let .string(key) = entry { return key }
                return nil
            }
            if keys.count == entries.count, keys.count == properties.count,
               Set(keys) == Set(properties.keys) {
                return keys
            }
        }
        return properties.keys.sorted()
    }

    private static func fieldKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        if prop["$ref"] != nil { return nil }
        if prop["anyOf"] != nil || prop["allOf"] != nil || prop["not"] != nil
            || prop["if"] != nil || prop["then"] != nil || prop["else"] != nil
            || prop["const"] != nil || prop["pattern"] != nil
            || prop["exclusiveMinimum"] != nil || prop["exclusiveMaximum"] != nil
            || prop["multipleOf"] != nil {
            return nil
        }
        if case let .array(oneOf)? = prop["oneOf"] {
            guard prop["enum"] == nil, prop["format"] == nil,
                  prop["minimum"] == nil, prop["maximum"] == nil,
                  prop["minItems"] == nil, prop["maxItems"] == nil, prop["items"] == nil,
                  prop["minLength"] == nil, prop["maxLength"] == nil else { return nil }
            guard case .string("string")? = prop["type"] else { return nil }
            guard let choices = labeledChoices(oneOf) else { return nil }
            return .stringOneOf(choices)
        }
        if case let .array(values)? = prop["enum"] {
            guard prop["format"] == nil,
                  prop["minimum"] == nil, prop["maximum"] == nil,
                  prop["minItems"] == nil, prop["maxItems"] == nil, prop["items"] == nil,
                  prop["minLength"] == nil, prop["maxLength"] == nil else { return nil }
            guard case .string("string")? = prop["type"] else { return nil }
            guard values.count <= maxChoices else { return nil }
            var choices: [String] = []
            for entry in values {
                guard case let .string(value) = entry else { return nil }
                choices.append(value)
            }
            guard Set(choices).count == choices.count else { return nil }
            return choices.isEmpty ? nil : .stringEnum(choices)
        }
        guard case let .string(type)? = prop["type"] else { return nil }
        if type != "string",
           prop["minLength"] != nil || prop["maxLength"] != nil || prop["format"] != nil {
            return nil
        }
        if type != "number" && type != "integer",
           prop["minimum"] != nil || prop["maximum"] != nil {
            return nil
        }
        if type != "array",
           prop["minItems"] != nil || prop["maxItems"] != nil || prop["items"] != nil {
            return nil
        }
        switch type {
        case "boolean": return .bool
        case "integer", "number": return numberKind(prop)
        case "string": return stringKind(prop)
        case "array": return arrayKind(prop)
        default: return nil
        }
    }

    private static func numberKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        let minimum: Double?
        if let raw = prop["minimum"] {
            guard case let .number(value) = raw, value.isFinite else { return nil }
            minimum = value
        } else {
            minimum = nil
        }
        let maximum: Double?
        if let raw = prop["maximum"] {
            guard case let .number(value) = raw, value.isFinite else { return nil }
            maximum = value
        } else {
            maximum = nil
        }
        if let minimum, let maximum, minimum > maximum { return nil }
        return .number
    }

    private static func stringKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        if let rawFormat = prop["format"] {
            guard case .string = rawFormat else { return nil }
        }
        let minLength: Int?
        if let raw = prop["minLength"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            minLength = value
        } else {
            minLength = nil
        }
        let maxLength: Int?
        if let raw = prop["maxLength"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            maxLength = value
        } else {
            maxLength = nil
        }
        if let minLength, let maxLength, minLength > maxLength { return nil }
        return .string(minLength: minLength, maxLength: maxLength)
    }

    private static func arrayKind(_ prop: [String: RemoteJSONValue]) -> DesktopElicitationField.Kind? {
        guard case let .object(items)? = prop["items"] else { return nil }
        guard let choices = choiceSet(items) else { return nil }
        let minItems: Int?
        if let raw = prop["minItems"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            minItems = value
        } else {
            minItems = nil
        }
        let maxItems: Int?
        if let raw = prop["maxItems"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            maxItems = value
        } else {
            maxItems = nil
        }
        if let minItems, let maxItems, minItems > maxItems { return nil }
        return .stringMultiSelect(choices: choices, maxItems: maxItems)
    }

    private static func choiceSet(_ items: [String: RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        let supportedItemKeys: Set<String> = [
            "anyOf", "oneOf", "enum", "type", "title", "description",
        ]
        guard items.keys.allSatisfy({ supportedItemKeys.contains($0) }) else { return nil }
        if let itemType = items["type"] {
            guard case .string("string") = itemType else { return nil }
        }
        if let alternatives = arrayEntries(items["oneOf"]) ?? arrayEntries(items["anyOf"]),
           (items["oneOf"] == nil) != (items["anyOf"] == nil) {
            guard items["enum"] == nil else { return nil }
            return labeledChoices(alternatives)
        }
        if case let .array(values)? = items["enum"],
           items["oneOf"] == nil,
           items["anyOf"] == nil {
            return bareChoices(values)
        }
        return nil
    }

    private static func labeledChoices(_ entries: [RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        guard entries.count <= maxChoices else { return nil }
        var choices: [DesktopElicitationField.Choice] = []
        var seen = Set<String>()
        for entry in entries {
            guard case let .object(option) = entry,
                  option.keys.allSatisfy({ $0 == "const" || $0 == "title" || $0 == "description" }),
                  case let .string(value)? = option["const"],
                  seen.insert(value).inserted else { return nil }
            let title: String
            if let titleValue = option["title"] {
                guard case let .string(label) = titleValue else { return nil }
                title = label
            } else {
                title = value
            }
            choices.append(.init(value: value, title: title))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func bareChoices(_ values: [RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        guard values.count <= maxChoices else { return nil }
        var choices: [DesktopElicitationField.Choice] = []
        var seen = Set<String>()
        for entry in values {
            guard case let .string(value) = entry, seen.insert(value).inserted else { return nil }
            choices.append(.init(value: value, title: value))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func arrayEntries(_ value: RemoteJSONValue?) -> [RemoteJSONValue]? {
        if case let .array(entries)? = value { return entries }
        return nil
    }

    private static func nonNegativeInt(_ value: RemoteJSONValue) -> Int? {
        guard case let .number(number) = value,
              number.isFinite, number >= 0,
              let integer = Int(exactly: number) else { return nil }
        return integer
    }
}

enum DesktopElicitationChoiceSelection: Hashable {
    case unset
    case option(String)
    case boolean(Bool)
    case other

    static func current(
        field: DesktopElicitationField,
        value: RemoteJSONValue?,
        choices: [DesktopElicitationField.Choice],
        allowsFreeform: Bool,
        isCustom: Bool
    ) -> Self {
        if field.kind == .bool, value == nil {
            return field.required ? .boolean(false) : .unset
        }
        if isCustom {
            return .other
        }
        if case let .bool(flag)? = value {
            return .boolean(flag)
        }
        if case let .string(text)? = value {
            if choices.contains(where: { $0.value == text }) {
                return .option(text)
            }
            if allowsFreeform {
                return .other
            }
        }
        if !field.required {
            return .unset
        }
        if let first = choices.first {
            return .option(first.value)
        }
        return allowsFreeform ? .other : .unset
    }

    static func customText(from value: RemoteJSONValue?) -> String {
        if case let .string(text)? = value { return text }
        return ""
    }

    func apply(
        fieldKey: String,
        choices: [DesktopElicitationField.Choice],
        allowsFreeform: Bool,
        values: inout [String: RemoteJSONValue],
        customChoiceFields: inout Set<String>
    ) {
        switch self {
        case .unset:
            customChoiceFields.remove(fieldKey)
            values[fieldKey] = nil
        case .option(let value):
            customChoiceFields.remove(fieldKey)
            values[fieldKey] = .string(value)
        case .boolean(let value):
            customChoiceFields.remove(fieldKey)
            values[fieldKey] = .bool(value)
        case .other:
            guard allowsFreeform else { return }
            let currentIsCustom: Bool
            if customChoiceFields.contains(fieldKey) {
                currentIsCustom = true
            } else if case let .string(value)? = values[fieldKey] {
                currentIsCustom = !choices.contains(where: { $0.value == value })
            } else {
                currentIsCustom = false
            }
            customChoiceFields.insert(fieldKey)
            if !currentIsCustom {
                values[fieldKey] = .string("")
            }
        }
    }
}

enum DesktopElicitationNumberText {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    static func value(for text: String, locale: Locale = .current) -> RemoteJSONValue? {
        if let number = parse(text, locale: locale) {
            return .number(number)
        }
        if text.isEmpty {
            return nil
        }
        return .string(text)
    }

    static func text(for value: RemoteJSONValue?, locale: Locale = .current) -> String {
        if case let .number(number)? = value, number.isFinite {
            return format(number, locale: locale)
        }
        if case let .string(text)? = value { return text }
        return ""
    }

    static func format(_ value: Double, locale: Locale = .current) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        if let localized = makeFormatter(locale: locale).string(from: NSNumber(value: value)),
           parse(localized, locale: locale) == value {
            return localized
        }
        return String(value)
    }

    static func parse(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let value = parseFormattedNumber(trimmed, locale: locale),
           numericText(trimmed, locale: locale, roundTripsTo: value) {
            return value
        }
        if let value = Double(trimmed), value.isFinite,
           numericText(trimmed, locale: posixLocale, roundTripsTo: value) {
            return value
        }
        return nil
    }

    private static func parseFormattedNumber(_ text: String, locale: Locale) -> Double? {
        let formatter = makeFormatter(locale: locale)
        var object: AnyObject?
        var range = NSRange(location: 0, length: (text as NSString).length)
        do {
            try formatter.getObjectValue(&object, for: text, range: &range)
        } catch {
            return nil
        }
        guard range.location == 0,
              range.length == (text as NSString).length,
              let number = object as? NSNumber else {
            return nil
        }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private static func makeFormatter(locale: Locale) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 16
        formatter.isLenient = false
        return formatter
    }

    private static func numericText(
        _ text: String,
        locale: Locale,
        roundTripsTo value: Double
    ) -> Bool {
        guard let entered = decimalValue(text, locale: locale),
              let canonical = decimalValue(String(value), locale: posixLocale) else {
            if makeFormatter(locale: locale).string(from: NSNumber(value: value)) == text {
                return true
            }
            let normalized = text.replacingOccurrences(
                of: locale.decimalSeparator ?? ".",
                with: "."
            )
            guard let parsed = Double(normalized), parsed.isFinite else { return false }
            return parsed == value
        }
        return NSDecimalNumber(decimal: entered)
            .compare(NSDecimalNumber(decimal: canonical)) == .orderedSame
    }

    private static func decimalValue(_ text: String, locale: Locale) -> Decimal? {
        let scanner = Scanner(string: text)
        scanner.locale = locale
        scanner.charactersToBeSkipped = nil
        guard let decimal = scanner.scanDecimal(),
              scanner.isAtEnd,
              !decimal.isNaN,
              NSDecimalNumber(decimal: decimal).doubleValue.isFinite else {
            return nil
        }
        return decimal
    }
}

struct DesktopTerminalDefaultBooleanElicitation: Equatable {
    let key: String
    let value: Bool

    static func parse(_ request: RemoteElicitationRequest) -> Self? {
        parse(
            requestId: request.requestId,
            mode: request.mode,
            schema: request.schema
        )
    }

    static func parse(
        requestId: String,
        mode: String?,
        schema: RemoteJSONValue?
    ) -> Self? {
        guard requestId.hasPrefix("synthetic::durable-ask-user::"),
              mode == "terminal-default",
              case .object(let root)? = schema,
              Set(root.keys) == [
                "properties", "x-copilot-projects-terminal-default",
              ],
              root["x-copilot-projects-terminal-default"] == .bool(true),
              case .object(let properties)? = root["properties"],
              properties.count == 1,
              let key = properties.keys.first,
              case .object(let field)? = properties[key],
              field["type"] == .string("boolean"),
              case .bool(let value)? = field["default"]
        else { return nil }
        return Self(key: key, value: value)
    }
}

private struct DesktopUserInputCard: View {
    let request: RemoteUserInputRequest
    let onAnswer: (@MainActor (RemoteUserInputAnswer) async -> RemoteWorkflowActionResult)?
    let onFocusTerminal: () -> Void

    @State private var freeform = ""
    @State private var isSubmitting = false
    @State private var isApplied = false
    @State private var statusMessage: String?
    @State private var isError = false

    private var isDisabled: Bool {
        isSubmitting || isApplied || onAnswer == nil
    }

    private var freeformTooLarge: Bool {
        let trimmed = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return freeform.utf8.count > 8_192
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Copilot needs your input", systemImage: "questionmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
                Spacer()
                if request.agentId != nil {
                    Text("Subagent question")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Question from a subagent")
                }
            }

            MarkdownText(text: request.question)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !request.choices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(Array(request.choices.enumerated()), id: \.offset) { _, choice in
                        Button {
                            submit(choice, wasFreeform: false)
                        } label: {
                            Text(choice)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled)
                        .accessibilityLabel("Answer: \(choice)")
                    }
                }
            }

            if request.allowFreeform {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Type an answer…", text: $freeform, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isDisabled)
                        .accessibilityLabel("Type an answer")
                        .onSubmit {
                            let trimmed = freeform.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !isDisabled, !freeformTooLarge, !trimmed.isEmpty else { return }
                            submit(freeform, wasFreeform: true)
                        }

                    HStack {
                        if freeformTooLarge {
                            Text("Answer is too large to send")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Spacer()
                        Button("Send Answer") {
                            submit(freeform, wasFreeform: true)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isDisabled
                                || freeformTooLarge
                                || freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                    }
                }
            }

            if !request.choices.isEmpty || !request.allowFreeform {
                HStack {
                    Button("Answer in terminal", action: onFocusTerminal)
                        .buttonStyle(.borderless)
                        .font(.caption)
                    Spacer()
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : StudioStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(StudioStyle.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.4))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Copilot question")
    }

    private func submit(_ answer: String, wasFreeform: Bool) {
        guard let onAnswer, !isDisabled else { return }
        isSubmitting = true
        isError = false
        statusMessage = "Sending…"
        Task { @MainActor in
            let result = await onAnswer(
                RemoteUserInputAnswer(
                    requestId: request.requestId,
                    answer: answer,
                    wasFreeform: wasFreeform
                )
            )
            isSubmitting = false
            switch result.state {
            case .applied, .accepted:
                isApplied = true
                isError = false
                statusMessage = "Sent to Copilot."
            case .indeterminate:
                isApplied = true
                isError = true
                statusMessage = result.message ?? "Couldn't confirm the outcome. Inspect the terminal before trying again."
            case .rejected:
                isError = true
                statusMessage = result.message ?? "The answer could not be sent."
            }
        }
    }
}

private struct DesktopElicitationCard: View {
    let request: RemoteElicitationRequest
    let onAnswer: (@MainActor (RemoteElicitationAnswer) async -> RemoteWorkflowActionResult)?
    let onFocusTerminal: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var values: [String: RemoteJSONValue] = [:]
    @State private var numberDrafts: [String: String] = [:]
    @State private var touched: Set<String> = []
    @State private var customChoiceFields: Set<String> = []
    @State private var isSubmitting = false
    @State private var isApplied = false
    @State private var statusMessage: String?
    @State private var isError = false
    @FocusState private var focusedCustomChoice: String?

    private var form: DesktopElicitationForm? {
        guard !isURLMode,
              !request.requestId.hasPrefix("synthetic::durable-ask-user::"),
              request.mode == nil || request.mode == "form" else {
            return nil
        }
        return DesktopElicitationForm.parse(
            request.schema,
            allowFreeformChoices: request.elicitationSource == nil
        )
    }

    private var terminalDefault: DesktopTerminalDefaultBooleanElicitation? {
        DesktopTerminalDefaultBooleanElicitation.parse(request)
    }

    private var isURLMode: Bool {
        request.mode == "url" || request.url != nil
    }

    private var isDisabled: Bool {
        isSubmitting || isApplied || onAnswer == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Copilot needs your input", systemImage: "questionmark.bubble.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
                Spacer()
                if request.agentId != nil {
                    Text("Subagent question")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Question from a subagent")
                }
            }

            MarkdownText(text: request.message)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isURLMode {
                urlControls(request.url)
            } else if let terminalDefault {
                terminalDefaultControls(terminalDefault)
            } else if let form {
                ForEach(form.fields) { field in
                    fieldControl(field)
                }
                HStack {
                    Button("Decline") { submit(.decline) }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled)
                    Spacer()
                    Button("Send Answer") { submit(.accept) }
                        .buttonStyle(.borderedProminent)
                        .disabled(isDisabled || !canSubmit(form))
                }
            } else {
                Text("Answer this question in the Copilot terminal.")
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                Button("Focus terminal", action: onFocusTerminal)
                    .buttonStyle(.bordered)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : StudioStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(StudioStyle.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.accentColor.opacity(0.4))
        )
        .onAppear { seedDefaults() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Copilot form question")
    }

    private func terminalDefaultControls(
        _ terminalDefault: DesktopTerminalDefaultBooleanElicitation
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(
                "This question is being handled in the terminal. You can safely "
                    + "accept the highlighted default here or focus the terminal "
                    + "for another answer."
            )
            .font(.caption)
            .foregroundStyle(StudioStyle.secondaryText)
            HStack {
                Button("Focus terminal", action: onFocusTerminal)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Use default: \(terminalDefault.value ? "Yes" : "No")") {
                    submitTerminalDefault(terminalDefault)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDisabled)
            }
        }
    }

    @ViewBuilder
    private func urlControls(_ rawURL: String?) -> some View {
        if let rawURL, let link = Self.safeWebURL(rawURL) {
            Text(link.absoluteString)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .textSelection(.enabled)
                .lineLimit(3)
            Button {
                openURL(link)
            } label: {
                Label("Open in Browser", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting)
            HStack {
                Button("Decline") { submit(.decline) }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled)
                Spacer()
                Button("Done") { submit(.accept) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
            }
        } else {
            Text("Open this link in the Copilot terminal.")
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
            if let rawURL {
                Text(rawURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            HStack {
                Button("Decline") { submit(.decline) }
                    .buttonStyle(.bordered)
                    .disabled(isDisabled)
                Button("Focus terminal", action: onFocusTerminal)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Done") { submit(.accept) }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDisabled)
            }
        }
    }

    @ViewBuilder
    private func fieldControl(_ field: DesktopElicitationField) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(StudioStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let description = field.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch field.kind {
            case .stringEnum, .stringOneOf:
                DesktopElicitationChoiceControl(
                    field: field,
                    choices: field.singleChoiceOptions,
                    allowsFreeform: form?.allowsFreeformChoices == true,
                    isDisabled: isDisabled,
                    values: $values,
                    customChoiceFields: $customChoiceFields,
                    touched: $touched,
                    focusedCustomChoice: $focusedCustomChoice
                )
            case .bool:
                if form?.allowsFreeformChoices == true {
                    DesktopElicitationChoiceControl(
                        field: field,
                        choices: [],
                        allowsFreeform: true,
                        isDisabled: isDisabled,
                        values: $values,
                        customChoiceFields: $customChoiceFields,
                        touched: $touched,
                        focusedCustomChoice: $focusedCustomChoice
                    )
                } else if field.required {
                    Toggle(field.title, isOn: boolBinding(field.key))
                        .labelsHidden()
                        .disabled(isDisabled)
                } else {
                    Picker(field.title, selection: optionalBoolBinding(field.key)) {
                        Text("Not set").tag("unset")
                        Text("True").tag("true")
                        Text("False").tag("false")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(isDisabled)
                }
            case .number:
                TextField(field.title, text: numberBinding(field.key))
                    .textFieldStyle(.roundedBorder)
                    .disabled(isDisabled)
            case .string:
                TextField(
                    field.title,
                    text: freeformStringBinding(field),
                    axis: .vertical
                )
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .disabled(isDisabled)
                if let requirement = stringLengthRequirement(field.kind) {
                    Text(requirement)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            case .stringMultiSelect(let choices, _):
                ForEach(choices, id: \.value) { choice in
                    let selected = isChoiceSelected(field.key, choice.value)
                    Button {
                        toggleChoice(field, choice.value)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selected ? "checkmark.square.fill" : "square")
                            Text(choice.title)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.5 : 1)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                    .accessibilityLabel(choice.title)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func safeWebURL(_ rawURL: String?) -> URL? {
        guard let rawURL,
              let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.host != nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    private func seedDefaults() {
        guard values.isEmpty, touched.isEmpty, let form else { return }
        let initialState = form.initialState()
        values = initialState.values
        customChoiceFields = initialState.customChoiceFields
    }

    private func canSubmit(_ form: DesktopElicitationForm) -> Bool {
        form.validatedContent(
            values: values,
            touched: touched,
            customChoiceFields: customChoiceFields
        ) != nil
    }

    private func stringLengthRequirement(_ kind: DesktopElicitationField.Kind) -> String? {
        guard case let .string(minLength, maxLength) = kind else { return nil }
        switch (minLength, maxLength) {
        case let (min?, max?):
            return "Use \(min)–\(max) code points."
        case let (min?, nil):
            return "Use at least \(min) \(min == 1 ? "code point" : "code points")."
        case let (nil, max?):
            return "Use at most \(max) \(max == 1 ? "code point" : "code points")."
        case (nil, nil):
            return nil
        }
    }

    private func markTouched(_ key: String) { touched.insert(key) }

    private func selectedStrings(_ key: String) -> [String] {
        DesktopElicitationField.selectedStrings(values[key])
    }

    private func isChoiceSelected(_ key: String, _ value: String) -> Bool {
        selectedStrings(key).contains(value)
    }

    private func toggleChoice(_ field: DesktopElicitationField, _ value: String) {
        guard let updated = field.toggledSelectionValue(value, in: values[field.key]) else { return }
        values[field.key] = updated
        markTouched(field.key)
    }

    private func freeformStringBinding(_ field: DesktopElicitationField) -> Binding<String> {
        Binding(
            get: {
                if case let .string(value)? = values[field.key] { return value }
                return ""
            },
            set: {
                values[field.key] = field.normalizedStringInput($0)
                markTouched(field.key)
            }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case let .bool(value)? = values[key] { return value }
                return false
            },
            set: { values[key] = .bool($0); markTouched(key) }
        )
    }

    private func optionalBoolBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                if case let .bool(value)? = values[key] {
                    return value ? "true" : "false"
                }
                return "unset"
            },
            set: {
                switch $0 {
                case "true":
                    values[key] = .bool(true)
                case "false":
                    values[key] = .bool(false)
                default:
                    values[key] = nil
                }
                markTouched(key)
            }
        )
    }

    private func numberBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                numberDrafts[key] ?? DesktopElicitationNumberText.text(for: values[key])
            },
            set: { text in
                markTouched(key)
                numberDrafts[key] = text
                values[key] = DesktopElicitationNumberText.value(for: text)
            }
        )
    }

    private func submit(_ action: RemoteElicitationAction) {
        var content: [String: RemoteJSONValue]?
        if action == .accept, let form {
            guard let payload = form.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customChoiceFields
            ) else { return }
            content = payload
        }
        sendAnswer(
            RemoteElicitationAnswer(
                requestId: request.requestId,
                action: action,
                content: content
            )
        )
    }

    private func submitTerminalDefault(
        _ terminalDefault: DesktopTerminalDefaultBooleanElicitation
    ) {
        sendAnswer(
            RemoteElicitationAnswer(
                requestId: request.requestId,
                action: .accept,
                content: [terminalDefault.key: .bool(terminalDefault.value)]
            )
        )
    }

    private func sendAnswer(_ answer: RemoteElicitationAnswer) {
        guard let onAnswer, !isDisabled else { return }
        isSubmitting = true
        isError = false
        statusMessage = "Sending…"
        Task { @MainActor in
            let result = await onAnswer(answer)
            isSubmitting = false
            switch result.state {
            case .applied, .accepted:
                isApplied = true
                isError = false
                statusMessage = "Sent to Copilot."
            case .indeterminate:
                isApplied = true
                isError = true
                statusMessage = result.message ?? "Couldn't confirm the outcome. Inspect the terminal before trying again."
            case .rejected:
                isError = true
                statusMessage = result.message ?? "The answer could not be sent."
            }
        }
    }
}

private struct DesktopElicitationChoiceControl: View {
    let field: DesktopElicitationField
    let choices: [DesktopElicitationField.Choice]
    let allowsFreeform: Bool
    let isDisabled: Bool
    @Binding var values: [String: RemoteJSONValue]
    @Binding var customChoiceFields: Set<String>
    @Binding var touched: Set<String>
    @FocusState.Binding var focusedCustomChoice: String?

    var body: some View {
        Group {
            Picker(field.title, selection: choiceSelectionBinding) {
                if !field.required {
                    Text("Not set").tag(DesktopElicitationChoiceSelection.unset)
                }
                if field.kind == .bool {
                    Text("True").tag(DesktopElicitationChoiceSelection.boolean(true))
                    Text("False").tag(DesktopElicitationChoiceSelection.boolean(false))
                } else {
                    ForEach(choices, id: \.value) { choice in
                        Text(choice.title)
                            .tag(DesktopElicitationChoiceSelection.option(choice.value))
                    }
                }
                if allowsFreeform {
                    Text("Other").tag(DesktopElicitationChoiceSelection.other)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .disabled(isDisabled)
            .accessibilityIdentifier("desktop-elicitation-choice-\(field.key)")

            if allowsFreeform, choiceSelection == .other {
                TextField(
                    "Other (type your answer)",
                    text: customChoiceBinding,
                    axis: .vertical
                )
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .disabled(isDisabled)
                .accessibilityLabel("\(field.title), other answer")
                .accessibilityIdentifier("desktop-elicitation-other-\(field.key)")
                .focused($focusedCustomChoice, equals: field.key)
            }
        }
    }

    private var choiceSelection: DesktopElicitationChoiceSelection {
        DesktopElicitationChoiceSelection.current(
            field: field,
            value: values[field.key],
            choices: choices,
            allowsFreeform: allowsFreeform,
            isCustom: customChoiceFields.contains(field.key)
        )
    }

    private var choiceSelectionBinding: Binding<DesktopElicitationChoiceSelection> {
        Binding(
            get: { choiceSelection },
            set: { selection in
                selection.apply(
                    fieldKey: field.key,
                    choices: choices,
                    allowsFreeform: allowsFreeform,
                    values: &values,
                    customChoiceFields: &customChoiceFields
                )
                if selection == .other {
                    Task { @MainActor in
                        if customChoiceFields.contains(field.key) {
                            focusedCustomChoice = field.key
                        }
                    }
                } else if focusedCustomChoice == field.key {
                    focusedCustomChoice = nil
                }
                touched.insert(field.key)
            }
        )
    }

    private var customChoiceBinding: Binding<String> {
        Binding(
            get: {
                DesktopElicitationChoiceSelection.customText(from: values[field.key])
            },
            set: {
                guard customChoiceFields.contains(field.key) else { return }
                values[field.key] = .string($0)
                touched.insert(field.key)
            }
        )
    }
}
