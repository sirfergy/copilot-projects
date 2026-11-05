import SwiftUI
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI

struct TranscriptTurnCard: View {
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
                        MarkdownText(text: step)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
