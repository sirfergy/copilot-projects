import SwiftUI
import CopilotProjectsProtocol
import CopilotProjectsUI

struct DesktopUserInputCard: View {
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

    private var canSubmitFreeform: Bool {
        !isDisabled
            && !freeformTooLarge
            && !freeform.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                            guard canSubmitFreeform else { return }
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
                        .disabled(!canSubmitFreeform)
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

struct DesktopElicitationCard: View {
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
        DesktopTerminalDefaultBooleanElicitation.parse(
            requestId: request.requestId,
            mode: request.mode,
            schema: request.schema
        )
    }

    private var isURLMode: Bool {
        request.mode == "url" || request.url != nil
    }

    private var isDisabled: Bool {
        isSubmitting || isApplied || onAnswer == nil
    }

    private var canSubmitForm: Bool {
        !isDisabled
            && form?.validatedContent(
                values: values,
                touched: touched,
                customChoiceFields: customChoiceFields
            ) != nil
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
                .onSubmit {
                    guard canSubmitForm else { return }
                    submit(.accept)
                }
                HStack {
                    Button("Decline") { submit(.decline) }
                        .buttonStyle(.bordered)
                        .disabled(isDisabled)
                    Spacer()
                    Button("Send Answer") { submit(.accept) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmitForm)
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
                    sendAnswer(
                        RemoteElicitationAnswer(
                            requestId: request.requestId,
                            action: .accept,
                            content: [terminalDefault.key: .bool(terminalDefault.value)]
                        )
                    )
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
            case .stringEnum, .stringOneOf, .stringMultiSelect:
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

    private func freeformStringBinding(_ field: DesktopElicitationField) -> Binding<String> {
        Binding(
            get: {
                if case let .string(value)? = values[field.key] { return value }
                return ""
            },
            set: {
                values[field.key] = field.normalizedStringInput($0)
                touched.insert(field.key)
            }
        )
    }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: {
                if case let .bool(value)? = values[key] { return value }
                return false
            },
            set: { values[key] = .bool($0); touched.insert(key) }
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
                touched.insert(key)
            }
        )
    }

    private func numberBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                numberDrafts[key] ?? DesktopElicitationNumberText.text(for: values[key])
            },
            set: { text in
                touched.insert(key)
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
            if case .stringMultiSelect = field.kind {
                let isCustom = choiceSelection == .other
                let selectedChoices = field.multiSelectParts(
                    values[field.key],
                    allowsFreeform: allowsFreeform,
                    isCustom: isCustom
                ).listed
                ForEach(choices, id: \.value) { choice in
                    checkboxRow(title: choice.title, selected: selectedChoices.contains(choice.value)) {
                        guard let updated = field.toggledSelectionValue(
                            choice.value,
                            in: values[field.key],
                            allowsFreeform: allowsFreeform,
                            isCustom: isCustom
                        ) else { return }
                        values[field.key] = updated
                        touched.insert(field.key)
                    }
                }
                if allowsFreeform {
                    checkboxRow(title: "Other", selected: isCustom) {
                        guard let nowCustom = field.toggledCustomSelection(
                            allowsFreeform: allowsFreeform,
                            values: &values,
                            customChoiceFields: &customChoiceFields
                        ) else { return }
                        focusCustomChoice(isCustom: nowCustom)
                        touched.insert(field.key)
                    }
                }
            } else {
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
            }

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

    private func checkboxRow(
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                Text(title)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityLabel(title)
    }

    private func focusCustomChoice(isCustom: Bool) {
        if isCustom {
            Task { @MainActor in
                if customChoiceFields.contains(field.key) {
                    focusedCustomChoice = field.key
                }
            }
        } else if focusedCustomChoice == field.key {
            focusedCustomChoice = nil
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
                focusCustomChoice(isCustom: selection == .other)
                touched.insert(field.key)
            }
        )
    }

    private var customChoiceBinding: Binding<String> {
        Binding(
            get: {
                field.customChoiceText(from: values[field.key])
            },
            set: {
                guard let updated = field.updatedCustomChoiceValue(
                    $0,
                    in: values[field.key],
                    customChoiceFields: &customChoiceFields
                ) else { return }
                values[field.key] = updated
                touched.insert(field.key)
            }
        )
    }
}
