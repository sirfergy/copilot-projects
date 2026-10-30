import SwiftUI
import AppKit
import CopilotProjectsProtocol
import CopilotProjectsUI

struct TranscriptButton: View {
    @ObservedObject var controller: TranscriptController
    let isOpen: Bool
    let hasWorkflow: Bool
    let onOpen: () -> Void

    var body: some View {
        if !isOpen, controller.snapshot != nil || hasWorkflow {
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
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    var operationProvider: (() -> AgentOperationProjection)? = nil
    var promptComposer: DesktopSessionPromptComposer? = nil
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        if controller.snapshot != nil || workflow != nil {
            if isOpen {
                Group {
                    if let capture = imageCapture() {
                        ImageAssociatedTranscriptDrawer(
                            capture: capture, snapshot: controller.snapshot,
                            workflow: workflow, operation: operation,
                            workflowProvider: workflowProvider,
                            operationProvider: operationProvider,
                            promptComposer: promptComposer,
                            onClose: onClose, onAction: onAction, onPreview: onPreview
                        )
                    } else {
                        TranscriptDrawer(
                            turns: controller.snapshot.map {
                                TranscriptImageAssociation.attach(images: [], to: $0).turns
                            } ?? [],
                            imageCapture: nil,
                            workflow: workflow, operation: operation,
                            workflowProvider: workflowProvider,
                            operationProvider: operationProvider,
                            promptComposer: promptComposer,
                            onClose: onClose, onAction: onAction, onPreview: onPreview
                        )
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}

private struct ImageAssociatedTranscriptDrawer: View {
    @ObservedObject var capture: RemoteKittyImageCapture
    let snapshot: TranscriptSnapshot?
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let promptComposer: DesktopSessionPromptComposer?
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        TranscriptDrawer(
            turns: snapshot.map {
                TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(), to: $0).turns
            } ?? [],
            imageCapture: capture,
            workflow: workflow, operation: operation,
            workflowProvider: workflowProvider,
            operationProvider: operationProvider,
            promptComposer: promptComposer,
            onClose: onClose, onAction: onAction, onPreview: onPreview
        )
    }
}

private struct TranscriptDrawer: View {
    let turns: [TranscriptTurn]
    let imageCapture: RemoteKittyImageCapture?
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let promptComposer: DesktopSessionPromptComposer?
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @State private var isAtBottom = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Session details", systemImage: "text.bubble")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Hide session details")
                .accessibilityLabel("Hide session details")
                .accessibilityIdentifier("hide-session-details")
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            Divider()
            if let workflow {
                SessionWorkflowView(
                    workflow: workflow, canWrite: true,
                    receipts: operation.receipts ?? [], onAction: onAction
                )
                    .id(operation.conversationEpoch)
                    .padding(12)
                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(turns) { turn in
                            TranscriptTurnCard(turn: turn, imageCapture: imageCapture, onPreview: onPreview)
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
                .onAppear {
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
                }
                .onChange(of: turns) { _, _ in
                    guard isAtBottom else { return }
                    proxy.scrollTo("transcript-bottom", anchor: .bottom)
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
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(StudioStyle.chrome)
        .overlay(alignment: .leading) {
            Color(nsColor: .separatorColor).frame(width: 1).allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.2), radius: 12, x: -4)
    }
}

private struct TranscriptPromptComposerView: View {
    @ObservedObject var composer: DesktopSessionPromptComposer
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let workflowProvider: (() -> RemoteSessionWorkflow?)?
    let operationProvider: (() -> AgentOperationProjection)?
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    let onPreview: (TranscriptImagePreviewItem) -> Void
    @FocusState private var promptFocused: Bool

    private var liveWorkflow: RemoteSessionWorkflow? {
        workflowProvider?() ?? workflow
    }

    private var liveOperation: AgentOperationProjection {
        operationProvider?() ?? operation
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

                HStack(spacing: 8) {
                    Picker("Delivery", selection: $composer.mode) {
                        ForEach(RemotePromptMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(composer.isSending || composer.pendingOperationId != nil)
                    .accessibilityLabel("Message delivery mode")

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

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message Copilot", text: $composer.prompt, axis: .vertical)
                        .lineLimit(1...5)
                        .textFieldStyle(.roundedBorder)
                        .focused($promptFocused)
                        .disabled(composer.isSending || composer.pendingOperationId != nil)
                        .accessibilityLabel("Message Copilot")
                        .accessibilityIdentifier("desktop-prompt-field")
                        .onSubmit(submitPrompt)

                    Button("Send", action: submitPrompt)
                        .buttonStyle(.borderedProminent)
                        .disabled(!composer.canSend(workflow: currentWorkflow, operation: currentOperation, now: now))
                        .accessibilityIdentifier("desktop-send-prompt")
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
