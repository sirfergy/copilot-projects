import SwiftUI
import CopilotProjectsProtocol

enum ModelReasoningEffortDefault {
    /// Returns the level to preselect, or `nil` to leave `reasoningEffort`
    /// unset so Copilot applies the model's own default.
    ///
    /// Never falls back to the first advertised level: several models list
    /// `none` first, which would silently disable reasoning.
    static func initialEffort(
        supported: [String],
        sessionCurrent: String?,
        modelDefault: String?
    ) -> String? {
        [sessionCurrent, modelDefault]
            .compactMap { $0 }
            .first { supported.contains($0) }
    }
}

struct DesktopModelSection: Identifiable, Equatable {
    let id: String
    let title: String
    let models: [RemoteAvailableModel]
}

enum DesktopModelPicker {
    private static let categoryOrder = ["powerful", "versatile", "lightweight"]
    private static let categoryTitles = [
        "powerful": "Powerful",
        "versatile": "Versatile",
        "lightweight": "Lightweight",
    ]

    static func sections(for models: [RemoteAvailableModel]) -> [DesktopModelSection] {
        var grouped: [String: [RemoteAvailableModel]] = [:]
        var seen: [String] = []
        for model in models {
            let key = model.category.map { categoryOrder.contains($0) ? $0 : "other" } ?? "other"
            if grouped[key] == nil { seen.append(key) }
            grouped[key, default: []].append(model)
        }
        if seen == ["other"] {
            return [DesktopModelSection(id: "all", title: "", models: grouped["other"] ?? [])]
        }
        let ordered = categoryOrder.filter { grouped[$0] != nil }
            + seen.filter { !categoryOrder.contains($0) }
        return ordered.map { key in
            DesktopModelSection(
                id: key,
                title: categoryTitles[key] ?? "Other",
                models: grouped[key] ?? []
            )
        }
    }

    static func isCurrent(_ model: RemoteAvailableModel, current: RemoteModelInfo?) -> Bool {
        guard let name = current?.name, !name.isEmpty else { return false }
        return name == model.id || name == model.name
    }

    static func modelSummary(_ model: RemoteModelInfo?) -> String? {
        guard let model, !model.name.isEmpty else { return nil }
        var parts = [model.name]
        if let effort = model.reasoningEffort, !effort.isEmpty {
            parts.append(effort)
        }
        if model.contextTier == "long_context" {
            parts.append("long context")
        }
        return parts.joined(separator: " · ")
    }

    static func effortLabel(_ model: RemoteModelInfo?) -> String {
        guard let effort = model?.reasoningEffort, !effort.isEmpty else { return "Default" }
        return effort.capitalized
    }

    static func contextLabel(_ model: RemoteModelInfo?) -> String {
        model?.contextTier == "long_context" ? "Long context" : "Default"
    }

    static func canSwitch(
        availableModels: [RemoteAvailableModel],
        operation: AgentOperationProjection,
        workflow: RemoteSessionWorkflow?,
        isSubmitting: Bool = false
    ) -> Bool {
        !availableModels.isEmpty
            && !isSubmitting
            && operation.support == .receipts
            && workflow?.bounceRequested != true
    }

    static func blockedReason(
        availableModels: [RemoteAvailableModel],
        operation: AgentOperationProjection,
        workflow: RemoteSessionWorkflow?
    ) -> String? {
        guard !availableModels.isEmpty else { return "Model list not available yet." }
        if workflow?.bounceRequested == true {
            return "Wait for Copilot to finish restarting before switching models."
        }
        guard operation.support == .receipts else {
            return "Native session controls are unavailable."
        }
        return nil
    }
}

struct TranscriptModelButton: View {
    let modelInfo: RemoteModelInfo?
    let availableModels: [RemoteAvailableModel]
    let workflow: RemoteSessionWorkflow?
    var workflowProvider: (() -> RemoteSessionWorkflow?)? = nil
    let operation: AgentOperationProjection
    let onSwitchModel: (@MainActor (RemoteModelSelection) async -> RemoteWorkflowActionResult)?
    @State private var showsPopover = false

    var body: some View {
        let currentWorkflow = workflowProvider?() ?? workflow
        let summary = DesktopModelPicker.modelSummary(modelInfo)
        if !availableModels.isEmpty {
            let label = summary ?? "Choose model"
            let interactive = DesktopModelPicker.canSwitch(
                availableModels: availableModels,
                operation: operation,
                workflow: currentWorkflow
            ) && onSwitchModel != nil
            Button {
                showsPopover.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .disabled(!interactive)
            .help(
                interactive
                    ? "Model: \(label). Click to switch model"
                    : (DesktopModelPicker.blockedReason(
                        availableModels: availableModels,
                        operation: operation,
                        workflow: currentWorkflow
                    ) ?? "Model: \(label)")
            )
            .accessibilityLabel("Model \(label). Change model")
            .accessibilityIdentifier("transcript-model-button")
            .background(
                Color.clear.popover(isPresented: $showsPopover, arrowEdge: .bottom) {
                    DesktopModelPickerView(
                        currentModel: modelInfo,
                        availableModels: availableModels,
                        workflow: currentWorkflow,
                        operation: operation,
                        onApplied: { showsPopover = false },
                        onSwitchModel: onSwitchModel
                    )
                    .frame(width: 340)
                    .frame(maxHeight: 440)
                }
            )
        } else if let summary {
            Text(summary)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .leading)
                .padding(.horizontal, 6)
                .help("Model: \(summary)")
                .accessibilityLabel("Model \(summary)")
                .accessibilityIdentifier("transcript-model-label")
        }
    }
}

struct SessionDetailsModelSection: View {
    let currentModel: RemoteModelInfo?
    let availableModels: [RemoteAvailableModel]
    let onSelectModel: () -> Void

    var body: some View {
        let summary = DesktopModelPicker.modelSummary(currentModel)
        if !availableModels.isEmpty {
            Button(action: onSelectModel) {
                HStack {
                    LabeledContent("Model", value: summary ?? "Choose model")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Model \(summary ?? ""). Change model")
            .accessibilityIdentifier("session-details-model-button")
        } else if let summary {
            LabeledContent("Model", value: summary)
                .accessibilityIdentifier("session-details-model-label")
        }
    }
}

struct DesktopModelPickerView: View {
    let currentModel: RemoteModelInfo?
    let availableModels: [RemoteAvailableModel]
    let workflow: RemoteSessionWorkflow?
    let operation: AgentOperationProjection
    var onBack: (() -> Void)? = nil
    let onApplied: () -> Void
    let onSwitchModel: (@MainActor (RemoteModelSelection) async -> RemoteWorkflowActionResult)?

    @State private var selectedModel: RemoteAvailableModel?
    @State private var effort: String?
    @State private var longContext = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var canSwitch: Bool {
        DesktopModelPicker.canSwitch(
            availableModels: availableModels,
            operation: operation,
            workflow: workflow,
            isSubmitting: isSubmitting
        ) && onSwitchModel != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let selected = selectedModel,
                   let liveModel = availableModels.first(where: { $0.id == selected.id }) {
                    optionsContent(for: liveModel)
                } else {
                    listContent
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }

    @ViewBuilder
    private var listContent: some View {
        HStack {
            if let onBack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Text("Model")
                .font(.headline)
            Spacer()
        }

        if let current = currentModel, !current.name.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Current")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
                LabeledContent("Model", value: current.name)
                LabeledContent("Reasoning effort", value: DesktopModelPicker.effortLabel(current))
                LabeledContent("Context", value: DesktopModelPicker.contextLabel(current))
            }
            Divider()
        }

        if let reason = DesktopModelPicker.blockedReason(
            availableModels: availableModels,
            operation: operation,
            workflow: workflow
        ) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-picker-error")
        }

        ForEach(DesktopModelPicker.sections(for: availableModels)) { section in
            VStack(alignment: .leading, spacing: 4) {
                if !section.title.isEmpty {
                    Text(section.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioStyle.secondaryText)
                        .padding(.top, 2)
                }
                ForEach(section.models) { model in
                    modelRow(for: model)
                }
            }
        }
    }

    @ViewBuilder
    private func modelRow(for model: RemoteAvailableModel) -> some View {
        let disabled = model.disabled == true || !canSwitch
        Button {
            selectModel(model)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                    if model.disabled == true {
                        Text("Unavailable on your plan")
                            .font(.caption2)
                            .foregroundStyle(StudioStyle.secondaryText)
                    }
                }
                Spacer(minLength: 4)
                if DesktopModelPicker.isCurrent(model, current: currentModel) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Current model")
                }
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .disabled(disabled)
        .accessibilityIdentifier("model-picker-row-\(model.id)")
    }

    @ViewBuilder
    private func optionsContent(for model: RemoteAvailableModel) -> some View {
        let efforts = model.supportedReasoningEfforts ?? []
        let supportsEffort = !efforts.isEmpty
        let supportsLongContext = model.longContextAvailable == true

        HStack {
            Button {
                selectedModel = nil
                errorMessage = nil
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isSubmitting)

            Text(model.name)
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }

        if supportsEffort {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Reasoning effort", selection: $effort) {
                    Text("Default").tag(String?.none)
                    ForEach(efforts, id: \.self) { level in
                        Text(level.capitalized).tag(Optional(level))
                    }
                }
                Text("Default lets Copilot pick the model's usual level.")
                    .font(.caption2)
                    .foregroundStyle(StudioStyle.secondaryText)
            }
        }

        if supportsLongContext {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Long context", isOn: $longContext)
                Text("Accept larger inputs at long-context pricing.")
                    .font(.caption2)
                    .foregroundStyle(StudioStyle.secondaryText)
            }
        }

        if let reason = DesktopModelPicker.blockedReason(
            availableModels: availableModels,
            operation: operation,
            workflow: workflow
        ) {
            Text(reason)
                .font(.caption)
                .foregroundStyle(StudioStyle.secondaryText)
        }

        Button {
            Task { await apply(model) }
        } label: {
            HStack(spacing: 8) {
                Text("Switch to \(model.name)")
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(isSubmitting || model.disabled == true || !canSwitch)
        .accessibilityIdentifier("model-picker-apply")

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("model-picker-error")
        }
    }

    private func selectModel(_ model: RemoteAvailableModel) {
        let isCurrent = DesktopModelPicker.isCurrent(model, current: currentModel)
        effort = ModelReasoningEffortDefault.initialEffort(
            supported: model.supportedReasoningEfforts ?? [],
            sessionCurrent: isCurrent ? currentModel?.reasoningEffort : nil,
            modelDefault: model.defaultReasoningEffort
        )
        longContext = model.longContextAvailable == true
            && currentModel?.contextTier == "long_context"
        errorMessage = nil
        selectedModel = model
    }

    private func apply(_ model: RemoteAvailableModel) async {
        guard let onSwitchModel, !isSubmitting, model.disabled != true, canSwitch else { return }
        let supportsEffort = !(model.supportedReasoningEfforts ?? []).isEmpty
        let supportsLongContext = model.longContextAvailable == true
        let selection = RemoteModelSelection(
            modelId: model.id,
            reasoningEffort: supportsEffort ? effort : nil,
            contextTier: supportsLongContext
                ? (longContext ? "long_context" : "default")
                : nil
        )
        isSubmitting = true
        errorMessage = nil
        let result = await onSwitchModel(selection)
        isSubmitting = false
        if result.state == .applied {
            onApplied()
        } else {
            errorMessage = result.message ?? "Model switch was not accepted."
        }
    }
}
