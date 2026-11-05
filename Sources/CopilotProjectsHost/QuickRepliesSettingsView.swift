import SwiftUI
import AppKit
import CopilotProjectsProtocol

@MainActor
final class QuickRepliesSettingsModel: ObservableObject {
    @Published private(set) var items: [QuickReplyItem]
    @Published private(set) var isCustomized: Bool
    @Published private(set) var editingIndex: Int?
    @Published var draftLabel = "" {
        didSet {
            if draftLabel != oldValue {
                validationError = nil
            }
        }
    }
    @Published var draftPrompt = "" {
        didSet {
            if draftPrompt != oldValue {
                validationError = nil
            }
        }
    }
    @Published private(set) var validationError: QuickReplyValidationError?

    private let defaults: UserDefaults
    private var defaultsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let configuration = QuickReplyConfiguration.load(from: defaults)
        self.items = configuration.activeReplies
        self.isCustomized = configuration.isCustomized
        self.defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.reloadFromDefaults()
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.reloadFromDefaults()
                }
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func reloadFromDefaults() {
        let configuration = QuickReplyConfiguration.load(from: defaults)
        let repliesMatch = items.elementsEqual(configuration.activeReplies) { current, stored in
            current.label.utf8.elementsEqual(stored.label.utf8)
                && current.prompt.utf8.elementsEqual(stored.prompt.utf8)
        }
        guard !repliesMatch || isCustomized != configuration.isCustomized else {
            return
        }
        items = configuration.activeReplies
        isCustomized = configuration.isCustomized
        if editingIndex != nil {
            cancelEditing()
        } else {
            validationError = nil
        }
    }

    var trimmedDraftLabelCount: Int {
        draftLabel.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    var trimmedDraftPromptCount: Int {
        draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).count
    }

    var canEditDraft: Bool {
        editingIndex != nil || items.count < QuickReplyItem.maxCount
    }

    var canResetToDefaults: Bool {
        isCustomized || defaults.object(forKey: QuickReplyConfiguration.storageKey) != nil
    }

    func beginEditing(at index: Int) {
        guard items.indices.contains(index) else { return }
        editingIndex = index
        draftLabel = items[index].label
        draftPrompt = items[index].prompt
        validationError = nil
    }

    func cancelEditing() {
        editingIndex = nil
        draftLabel = ""
        draftPrompt = ""
        validationError = nil
    }

    @discardableResult
    func commitDraft() -> Bool {
        let item = QuickReplyItem(label: draftLabel, prompt: draftPrompt)
        if let index = editingIndex {
            guard items.indices.contains(index) else { return false }
            var candidate = items
            candidate[index] = item
            return persist(candidate, clearingDraft: true)
        }
        return persist(items + [item], clearingDraft: true)
    }

    func delete(at index: Int) {
        guard items.indices.contains(index) else { return }
        var candidate = items
        candidate.remove(at: index)
        if let currentEdit = editingIndex {
            if currentEdit == index {
                cancelEditing()
            } else if currentEdit > index {
                editingIndex = currentEdit - 1
            }
        }
        _ = persist(candidate, clearingDraft: false)
    }

    func moveUp(at index: Int) {
        guard index > 0, items.indices.contains(index) else { return }
        swapItems(at: index, and: index - 1)
    }

    func moveDown(at index: Int) {
        guard items.indices.contains(index), index + 1 < items.count else { return }
        swapItems(at: index, and: index + 1)
    }

    func resetToDefaults() {
        items = QuickReplyConfiguration.defaultItems
        isCustomized = false
        cancelEditing()
        QuickReplyConfiguration.reset(in: defaults)
    }

    private func swapItems(at first: Int, and second: Int) {
        var candidate = items
        candidate.swapAt(first, second)
        if editingIndex == first {
            editingIndex = second
        } else if editingIndex == second {
            editingIndex = first
        }
        _ = persist(candidate, clearingDraft: false)
    }

    private func persist(_ candidate: [QuickReplyItem], clearingDraft: Bool) -> Bool {
        switch QuickReplyConfiguration.validateList(candidate) {
        case .failure(let error):
            validationError = error
            return false
        case .success(let validated):
            items = validated
            isCustomized = true
            if clearingDraft {
                cancelEditing()
            } else {
                validationError = nil
            }
            guard case .success = QuickReplyConfiguration.save(validated, to: defaults) else {
                return false
            }
            return true
        }
    }
}

struct QuickRepliesSettingsView: View {
    @StateObject private var model: QuickRepliesSettingsModel
    let onDismiss: () -> Void
    @AppStorage(TranscriptPromptComposerView.showQuickReplyChipsKey) private var showQuickReplyChips = true

    init(
        defaults: UserDefaults = .standard,
        onDismiss: @escaping () -> Void
    ) {
        _model = StateObject(wrappedValue: QuickRepliesSettingsModel(defaults: defaults))
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            contentList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            editorPanel
        }
        .frame(width: 600, height: 480)
        .background(StudioStyle.chrome)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Quick Replies")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(model.items.count)/\(QuickReplyItem.maxCount)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioStyle.secondaryText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(StudioStyle.raised))
                        .accessibilityLabel("\(model.items.count) of \(QuickReplyItem.maxCount) quick replies")
                }
                Text(model.isCustomized
                     ? "Custom list · Shown in your order whenever the session is ready for a reply."
                     : "Default list · Customize the chips shown above the session prompt composer.")
                    .font(.caption)
                    .foregroundStyle(StudioStyle.secondaryText)
            }
            Spacer()
            Button("Reset to defaults") {
                model.resetToDefaults()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!model.canResetToDefaults)
            .accessibilityIdentifier("quick-replies-reset-defaults")

            Button("Done", action: onDismiss)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("quick-replies-done")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var contentList: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !showQuickReplyChips {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(StudioStyle.secondaryText)
                    Text("Quick-reply suggestions are currently hidden in the app menu.")
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                    Spacer()
                    Button("Show Suggestions") {
                        showQuickReplyChips = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(StudioStyle.raised)
                )
            }

            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(StudioStyle.secondaryText)
                        .accessibilityHidden(true)
                    Text("No quick replies configured")
                        .font(.headline)
                    Text("An empty custom list shows no quick-reply strip in the session drawer. Add a quick reply below or click Reset to defaults to restore the built-in suggestions.")
                        .font(.callout)
                        .foregroundStyle(StudioStyle.secondaryText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(StudioStyle.raised)
                )
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("quick-replies-empty-state")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                            QuickReplyRowView(
                                index: index,
                                totalCount: model.items.count,
                                item: item,
                                isEditing: model.editingIndex == index,
                                onMoveUp: { model.moveUp(at: index) },
                                onMoveDown: { model.moveDown(at: index) },
                                onEdit: { model.beginEditing(at: index) },
                                onDelete: { model.delete(at: index) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
                .accessibilityIdentifier("quick-replies-list")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var editorPanel: some View {
        let isEditing = model.editingIndex != nil
        let labelOverLimit = model.trimmedDraftLabelCount > QuickReplyItem.maxLabelLength
        let promptOverLimit = model.trimmedDraftPromptCount > QuickReplyItem.maxPromptLength

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(isEditing ? "Edit Quick Reply" : "Add Quick Reply")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isEditing {
                    Button("Cancel Edit") {
                        model.cancelEditing()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .accessibilityIdentifier("quick-replies-cancel-edit")
                }
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Label")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(model.trimmedDraftLabelCount)/\(QuickReplyItem.maxLabelLength)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(labelOverLimit ? Color.red : StudioStyle.secondaryText)
                    }
                    TextField("Chip label (1–24 chars)", text: $model.draftLabel)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEditDraft)
                        .accessibilityLabel("Quick reply label")
                        .accessibilityIdentifier("quick-replies-label-field")
                }
                .frame(width: 190)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Prompt")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("\(model.trimmedDraftPromptCount)/\(QuickReplyItem.maxPromptLength)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(promptOverLimit ? Color.red : StudioStyle.secondaryText)
                    }
                    TextField("Prompt text sent when clicked", text: $model.draftPrompt, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!model.canEditDraft)
                        .accessibilityLabel("Quick reply prompt")
                        .accessibilityIdentifier("quick-replies-prompt-field")
                }
                .frame(maxWidth: .infinity)
            }

            HStack(alignment: .center, spacing: 10) {
                if let error = model.validationError {
                    Label(error.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("quick-replies-validation-error")
                } else if !model.canEditDraft {
                    Text("Maximum of \(QuickReplyItem.maxCount) quick replies reached. Edit or delete a reply to add another.")
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                } else {
                    Text("Labels must be unique (case-insensitive). Clicking a chip sends its prompt verbatim.")
                        .font(.caption)
                        .foregroundStyle(StudioStyle.secondaryText)
                }
                Spacer(minLength: 0)
                Button(isEditing ? "Save Changes" : "Add Quick Reply") {
                    _ = model.commitDraft()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canEditDraft)
                .accessibilityIdentifier("quick-replies-save-button")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(StudioStyle.sidebar)
    }
}

private struct QuickReplyRowView: View {
    let index: Int
    let totalCount: Int
    let item: QuickReplyItem
    let isEditing: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(StudioStyle.secondaryText)
                .frame(width: 18, alignment: .trailing)

            Text(item.label)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(StudioStyle.message)
                )

            Text(item.prompt)
                .font(.callout)
                .foregroundStyle(StudioStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(item.prompt)

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("Move up")
                .accessibilityLabel("Move \(item.label) up")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(index + 1 >= totalCount)
                .help("Move down")
                .accessibilityLabel("Move \(item.label) down")

                Button(isEditing ? "Editing" : "Edit", action: onEdit)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isEditing)
                    .accessibilityLabel("Edit \(item.label)")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Delete \(item.label)")
                .accessibilityLabel("Delete \(item.label)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isEditing ? StudioStyle.selection : StudioStyle.raised)
        )
        .overlay {
            if isEditing {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(StudioStyle.selectionEdge, lineWidth: 1)
            }
        }
    }
}
