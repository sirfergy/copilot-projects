import SwiftUI
import CopilotProjectsCore
import CopilotProjectsProtocol
import CopilotProjectsUI

struct TranscriptTurnCard: View {
    let turn: TranscriptTurn
    let imageCapture: RemoteKittyImageCapture?
    var promptAttachments: [TranscriptPromptAttachments.Item] = []
    var toolImages: [TranscriptPromptAttachments.Item] = []
    var isPending = false
    var pendingMode: RemotePromptMode? = nil
    let onPreview: (TranscriptImagePreviewItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(turn.kind == "scheduled" ? "Scheduled" :
                    turn.kind == "automated" ? "Automated" : "You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
                if isPending {
                    Text(pendingMode == .enqueue ? "Queued" : "Pending")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(StudioStyle.secondaryText)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(StudioStyle.secondaryText.opacity(0.14)))
                }
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
                if !isPending {
                    Text(turn.startedAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(StudioStyle.secondaryText)
                }
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

            ForEach(
                TranscriptImageAssociation.timelineItems(
                    for: turn,
                    imageCapture: imageCapture,
                    promptAttachments: promptAttachments
                )
            ) { item in
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
                TranscriptTools(
                    tools: turn.tools,
                    isTurnInProgress: turn.endedAt == nil && !turn.isAborted,
                    images: toolImages,
                    onPreview: onPreview
                )
            }
            if let error = turn.error {
                TranscriptTurnFailure(error: error)
            }
        }
        .opacity(isPending ? 0.68 : 1)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func transcriptText(_ text: String) -> some View {
        MarkdownText(text: text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TranscriptDisclosureSection<Badge: View, Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String?
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    @State private var isExpanded = false
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: icon)
                        .font(.caption)
                    Text(title)
                        .font(.caption.weight(.medium))
                        .layoutPriority(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text("· \(subtitle)")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    badge()
                    Spacer(minLength: 0)
                }
                .foregroundStyle(StudioStyle.secondaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier(accessibilityIdentifier)

            if isExpanded {
                content()
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(StudioStyle.raised))
            }
        }
    }
}

private struct TranscriptReasoningView: View {
    let steps: [String]
    let summaryLabel: String
    let latestHeading: String?

    var body: some View {
        TranscriptDisclosureSection(
            icon: "brain",
            title: steps.count > 1 ? "Thinking (\(steps.count) steps)" : "Thinking",
            subtitle: latestHeading,
            accessibilityLabel: summaryLabel,
            accessibilityIdentifier: "transcript-thinking-toggle"
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    if index > 0 { Divider() }
                    MarkdownText(text: step)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.callout)
                        .foregroundStyle(StudioStyle.secondaryText)
                }
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

struct TranscriptTools: View {
    private static let pathToolNames: Set<String> = ["view", "edit", "create"]

    let tools: [TranscriptTool]
    var isTurnInProgress = true
    /// Images the tools returned, each shown under the row whose id is its `toolCallId`.
    let images: [TranscriptPromptAttachments.Item]
    let onPreview: (TranscriptImagePreviewItem) -> Void

    static func previewText(for tools: [TranscriptTool]) -> String {
        var counts: [String: Int] = [:]
        var names: [String] = []
        for tool in tools {
            let name = tool.name.isEmpty ? "tool" : tool.name
            if counts[name] == nil { names.append(name) }
            counts[name, default: 0] += 1
        }
        return names.map { name in
            let count = counts[name, default: 1]
            return count > 1 ? "\(name) ×\(count)" : name
        }.joined(separator: ", ")
    }

    static func summaryLabel(
        for tools: [TranscriptTool],
        isTurnInProgress: Bool = true,
        imageCount: Int = 0
    ) -> String {
        var parts = ["Tools (\(tools.count) \(tools.count == 1 ? "tool" : "tools"))"]
        let preview = previewText(for: tools)
        if !preview.isEmpty { parts.append(preview) }
        let failed = tools.filter { $0.success == false }.count
        if failed > 0 { parts.append("\(failed) failed") }
        if isTurnInProgress {
            let running = tools.filter { $0.success == nil }.count
            if running > 0 { parts.append("\(running) running") }
        }
        if imageCount > 0 { parts.append(Self.imageCountText(imageCount)) }
        return parts.joined(separator: " · ")
    }

    private static func imageCountText(_ count: Int) -> String {
        count == 1 ? "1 image" : "\(count) images"
    }

    var body: some View {
        let failedCount = tools.filter { $0.success == false }.count
        TranscriptDisclosureSection(
            icon: "wrench.and.screwdriver",
            title: "Tools",
            subtitle: Self.previewText(for: tools),
            accessibilityLabel: Self.summaryLabel(
                for: tools,
                isTurnInProgress: isTurnInProgress,
                imageCount: images.count
            ),
            accessibilityIdentifier: "transcript-tools-toggle"
        ) {
            if failedCount > 0 {
                Text("· \(failedCount) failed")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .layoutPriority(1)
            }
            // A badge, not part of the subtitle: the subtitle is one line and truncates.
            if !images.isEmpty {
                Text("· \(Self.imageCountText(images.count))")
                    .font(.caption.weight(.medium))
                    .layoutPriority(1)
            }
            if isTurnInProgress, tools.contains(where: { $0.success == nil }) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            }
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tools) { tool in
                    let status = status(for: tool)
                    HStack(spacing: 7) {
                        Image(systemName: status.icon)
                            .foregroundStyle(status.color)
                            .accessibilityLabel(status.label)
                        if !tool.name.isEmpty, tool.title != tool.name {
                            Text(tool.name)
                                .fontWeight(.light)
                                .foregroundStyle(StudioStyle.secondaryText.opacity(0.75))
                                .lineLimit(1)
                                .layoutPriority(1)
                        }
                        Text(tool.title)
                            .foregroundStyle(StudioStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(Self.pathToolNames.contains(tool.name) ? .middle : .tail)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .accessibilityElement(children: .combine)
                    ForEach(images.filter { $0.toolCallId == tool.id }) { item in
                        TranscriptImageView(identity: item.identity, data: item.data, onPreview: onPreview)
                    }
                }
            }
            .textSelection(.enabled)
        }
    }

    private func status(for tool: TranscriptTool) -> (icon: String, color: Color, label: String) {
        switch tool.success {
        case true: ("checkmark.circle.fill", .green, "Succeeded")
        case false: ("xmark.circle.fill", .red, "Failed")
        case nil: ("circle.dotted", StudioStyle.secondaryText, isTurnInProgress ? "Running" : "Stopped")
        }
    }
}
