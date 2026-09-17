import SwiftUI
import AppKit
import CopilotProjectsProtocol
import CopilotProjectsUI

struct TranscriptOverlay: View {
    @ObservedObject var controller: TranscriptController
    let isOpen: Bool
    let onClose: () -> Void
    let onOpen: () -> Void
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult

    var body: some View {
        if controller.snapshot != nil || workflow != nil {
            if isOpen {
                TranscriptDrawer(
                    turns: controller.snapshot?.turns ?? [],
                    workflow: workflow,
                    operation: operation,
                    onClose: onClose,
                    onAction: onAction
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                Button(action: onOpen) {
                    Label("Show session details", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .help("Show session details")
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
    }
}

private struct TranscriptDrawer: View {
    let turns: [TranscriptTurn]
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    let onClose: () -> Void
    let onAction: @MainActor (RemoteSessionAction) async -> RemoteWorkflowActionResult
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
                .help("Hide completed turns")
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
                            TranscriptTurnCard(turn: turn)
                        }
                        Color.clear
                            .frame(height: 1)
                            .id("transcript-bottom")
                            .onAppear { isAtBottom = true }
                            .onDisappear { isAtBottom = false }
                    }
                    .padding(14)
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
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .leading) { Divider() }
        .shadow(color: .black.opacity(0.2), radius: 12, x: -4)
    }
}

private struct TranscriptTurnCard: View {
    let turn: TranscriptTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(turn.kind == "scheduled" ? "Scheduled" :
                    turn.kind == "automated" ? "Automated" : "You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.tertiary)
            }

            if !turn.userContent.isEmpty {
                transcriptText(turn.userContent)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.accentColor.opacity(0.1))
                    )
            }

            ForEach(turn.assistantMessages) { message in
                VStack(alignment: .leading, spacing: 5) {
                    Text("Copilot")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    transcriptText(message.content)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            if !turn.tools.isEmpty {
                TranscriptTools(tools: turn.tools)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.primary.opacity(0.1))
        )
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
