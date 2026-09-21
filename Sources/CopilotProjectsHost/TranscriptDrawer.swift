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
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult

    var body: some View {
        if controller.snapshot != nil || workflow != nil {
            if isOpen {
                Group {
                    if let capture = imageCapture() {
                        ImageAssociatedTranscriptDrawer(
                            capture: capture, snapshot: controller.snapshot,
                            workflow: workflow, operation: operation,
                            onClose: onClose, onAction: onAction
                        )
                    } else {
                        TranscriptDrawer(
                            turns: controller.snapshot.map {
                                TranscriptImageAssociation.attach(images: [], to: $0).turns
                            } ?? [],
                            imageCapture: nil,
                            workflow: workflow, operation: operation,
                            onClose: onClose, onAction: onAction
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
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult

    var body: some View {
        TranscriptDrawer(
            turns: snapshot.map {
                TranscriptImageAssociation.attach(images: capture.retainedImageMetadata(), to: $0).turns
            } ?? [],
            imageCapture: capture,
            workflow: workflow, operation: operation,
            onClose: onClose, onAction: onAction
        )
    }
}

private struct TranscriptDrawer: View {
    let turns: [TranscriptTurn]
    let imageCapture: RemoteKittyImageCapture?
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
    @State private var isAtBottom = true
    @State private var preview: TranscriptImagePreviewItem?

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
                            TranscriptTurnCard(turn: turn, imageCapture: imageCapture) { preview = $0 }
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
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity)
        .background(StudioStyle.chrome)
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: .black.opacity(0.2), radius: 12, x: -4)
        .sheet(item: $preview) { item in
            TranscriptImagePreview(item: item)
        }
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

            ForEach(turn.assistantMessages) { message in
                VStack(alignment: .leading, spacing: 5) {
                    Text("Copilot")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioStyle.secondaryText)
                    transcriptText(message.content)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            if !turn.tools.isEmpty {
                TranscriptTools(tools: turn.tools)
            }
            if let imageCapture, let images = turn.images {
                ForEach(images, id: \.imageId) { image in
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
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func transcriptText(_ text: String) -> some View {
        MarkdownText(text: text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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
