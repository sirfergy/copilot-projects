import SwiftUI
import AppKit
import CopilotProjectsCore
import CopilotProjectsProtocol

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
    static let maxQuickReplyStripHeight: CGFloat = 116
    static let quickReplyFirstRowHeight: CGFloat = 30

    @ObservedObject var composer: DesktopSessionPromptComposer
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @AppStorage(Self.showQuickReplyChipsKey) private var showQuickReplyChips = true
    @AppStorage(QuickReplyConfiguration.storageKey) private var quickReplyListJSON: String?
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

    private func blockedMessage(now: Date) -> String? {
        composer.statusMessage
            ?? composer.attachmentsBlockedReason(workflow: liveWorkflow, operation: liveOperation, now: now)
    }

    @ViewBuilder
    private func quickReplyStrip(replies: [QuickReplyItem]) -> some View {
        QuickReplyFlowLayout {
            ForEach(replies) { item in
                Button(item.label) {
                    guard Self.canShowQuickReplies(
                        showQuickReplyChips: showQuickReplyChips,
                        composer: composer,
                        workflow: liveWorkflow,
                        operation: liveOperation,
                        now: Date()
                    ) else { return }
                    composer.prompt = item.prompt
                    submitPrompt()
                }
                .lineLimit(1)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

                let configuredReplies = showQuickReplyChips
                    ? QuickReplyConfiguration.resolved(fromJSON: quickReplyListJSON).activeReplies
                    : []
                let chipsVisible = Self.canShowQuickReplies(
                    showQuickReplyChips: showQuickReplyChips,
                    composer: composer,
                    workflow: currentWorkflow,
                    operation: currentOperation,
                    now: now
                )
                HStack(alignment: .top, spacing: 8) {
                    if !configuredReplies.isEmpty {
                        QuickReplyStripCapLayout {
                            ViewThatFits(in: .vertical) {
                                quickReplyStrip(replies: configuredReplies)
                                ScrollView(.vertical) {
                                    quickReplyStrip(replies: configuredReplies)
                                }
                                .scrollIndicators(.visible)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .opacity(chipsVisible ? 1 : 0)
                        .disabled(!chipsVisible)
                        .allowsHitTesting(chipsVisible)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("desktop-quick-reply-strip")
                        .accessibilityHidden(!chipsVisible)
                    } else {
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 8) {
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
                    .frame(height: Self.quickReplyFirstRowHeight)
                    .fixedSize()
                }

                let canSend = composer.canSend(workflow: currentWorkflow, operation: currentOperation, now: now)
                let modeDisabled = isDeliveryModeDisabled
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Copilot", text: $composer.prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                        .disabled(composer.pendingOperationId != nil)
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
            let currentOp = liveOperation
            composer.reconcileReceipts(currentOp.receipts, conversationEpoch: currentOp.conversationEpoch)
            focusPromptIfNeeded()
            composer.isPromptFieldFocused = promptFocused
        }
        .onDisappear {
            composer.isPromptFieldFocused = false
        }
        .onChange(of: composer.shouldFocusOnAppear) { _, _ in
            focusPromptIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
            focusPromptIfNeeded()
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

    private func focusPromptIfNeeded() {
        guard composer.shouldFocusOnAppear else { return }
        if NSApp?.windows.contains(where: { $0.attachedSheet != nil }) == true { return }
        composer.shouldFocusOnAppear = false
        guard AppModel.canMoveSelectionFocus(isPromptFieldFocused: composer.isPromptFieldFocused) else {
            return
        }
        promptFocused = true
        composer.isPromptFieldFocused = true
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

private struct QuickReplyStripCapLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let maxHeight = TranscriptPromptComposerView.maxQuickReplyStripHeight
        let size = subview.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: maxHeight)
        )
        return CGSize(width: size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(bounds.size)
        )
    }
}

private struct QuickReplyFlowLayout: Layout {
    private static let horizontalSpacing: CGFloat = 6
    private static let verticalSpacing: CGFloat = 4
    private static let firstRowAlignmentHeight = TranscriptPromptComposerView.quickReplyFirstRowHeight

    func makeCache(subviews: Subviews) -> CGFloat? { nil }

    private func layout(
        limitWidth: CGFloat,
        subviews: Subviews
    ) -> (size: CGSize, frames: [CGRect]) {
        guard !subviews.isEmpty else { return (.zero, []) }
        let clampedLimit = max(0, limitWidth)
        var rows: [[(index: Int, size: CGSize)]] = [[]]
        var rowWidth: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let raw = subview.sizeThatFits(ProposedViewSize(width: clampedLimit, height: nil))
            let size = CGSize(width: min(raw.width, clampedLimit), height: raw.height)
            if !rows[rows.count - 1].isEmpty, rowWidth + Self.horizontalSpacing + size.width > clampedLimit {
                rows.append([(index, size)])
                rowWidth = size.width
            } else {
                if !rows[rows.count - 1].isEmpty { rowWidth += Self.horizontalSpacing }
                rows[rows.count - 1].append((index, size))
                rowWidth += size.width
            }
        }

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        var widestRow: CGFloat = 0

        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = row.map(\.size.height).max() ?? 0
            if rowIndex == 0 {
                y = max(0, (Self.firstRowAlignmentHeight - rowHeight) / 2)
            }
            var x: CGFloat = 0
            for (itemIndex, item) in row.enumerated() {
                if itemIndex > 0 { x += Self.horizontalSpacing }
                let chipY = y + (rowHeight - item.size.height) / 2
                frames[item.index] = CGRect(x: x, y: chipY, width: item.size.width, height: item.size.height)
                x += item.size.width
            }
            widestRow = max(widestRow, x)
            y += rowHeight + (rowIndex < rows.count - 1 ? Self.verticalSpacing : 0)
        }

        return (CGSize(width: widestRow, height: max(y, Self.firstRowAlignmentHeight)), frames)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CGFloat?
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        if let width = proposal.width, width > 0, width.isFinite {
            cache = width
            return layout(limitWidth: width, subviews: subviews).size
        }
        let reference = layout(limitWidth: cache ?? .infinity, subviews: subviews).size
        if proposal.width == nil { return reference }
        let width = proposal.width == .infinity
            ? layout(limitWidth: .infinity, subviews: subviews).size.width
            : 0
        return CGSize(width: width, height: reference.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout CGFloat?
    ) {
        if bounds.width > 0, bounds.width.isFinite { cache = bounds.width }
        let frames = layout(limitWidth: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
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
