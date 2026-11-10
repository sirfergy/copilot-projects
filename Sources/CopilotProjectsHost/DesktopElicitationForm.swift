import Foundation
import CopilotProjectsProtocol

// MARK: - Interactive pending questions (`ask_user` & `elicitation`)

@dynamicMemberLookup
struct DesktopElicitationField: Identifiable, Equatable {
    typealias Choice = RemoteElicitationForm.Choice

    /// The field as the Mac parsed it, which is what remote clients are sent.
    let published: RemoteElicitationForm.Field
    /// The agent's schema for this field. Answers are checked against it.
    let schema: RemoteJSONValue

    var id: String { published.key }

    subscript<Value>(
        dynamicMember keyPath: KeyPath<RemoteElicitationForm.Field, Value>
    ) -> Value {
        published[keyPath: keyPath]
    }

    func accepts(
        _ value: RemoteJSONValue,
        allowFreeformChoice: Bool = false
    ) -> Bool {
        guard AppModel.isValidElicitationContent([published.key: value]),
              AppModel.elicitationValue(
                  value,
                  satisfies: schema,
                  allowFreeformStringChoice: allowFreeformChoice
              ) else {
            return false
        }
        if published.kind == .multiChoice, case let .array(items) = value {
            var seen = Set<String>()
            return items.allSatisfy {
                if case let .string(string) = $0 { return seen.insert(string).inserted }
                return false
            }
        }
        return true
    }

    func normalizedStringInput(_ text: String) -> RemoteJSONValue? {
        guard published.kind == .string else { return nil }
        let value = RemoteJSONValue.string(text)
        if !published.required, text.isEmpty, !accepts(value) {
            return nil
        }
        return value
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

    func multiSelectParts(
        _ current: RemoteJSONValue?,
        allowsFreeform: Bool = false,
        isCustom: Bool = false
    ) -> (listed: [String], custom: String?) {
        guard published.kind == .multiChoice, let choices = published.choices else {
            return ([], nil)
        }
        var strings = Self.selectedStrings(current)
        let choiceValues = Set(choices.map(\.value))
        let unlistedIndex = strings.lastIndex(where: { !choiceValues.contains($0) })
        guard isCustom || (allowsFreeform && unlistedIndex != nil) else {
            return (choices.map(\.value).filter(strings.contains), nil)
        }
        let custom = (unlistedIndex ?? strings.indices.last).map { strings.remove(at: $0) } ?? ""
        return (choices.map(\.value).filter(strings.contains), custom)
    }

    private func multiSelectValue(listed: [String], custom: String?) -> RemoteJSONValue? {
        let all = listed + (custom.map { [$0] } ?? [])
        let selection = RemoteJSONValue.array(all.map(RemoteJSONValue.string))
        return (all.isEmpty && !published.required && !accepts(selection)) ? nil : selection
    }

    func toggledSelectionValue(
        _ value: String,
        in current: RemoteJSONValue?,
        allowsFreeform: Bool = false,
        isCustom: Bool = false
    ) -> RemoteJSONValue?? {
        guard published.kind == .multiChoice, let choices = published.choices else { return nil }
        let parts = multiSelectParts(current, allowsFreeform: allowsFreeform, isCustom: isCustom)
        let maxItems = published.maxItems
        let limit = parts.custom == nil ? maxItems : maxItems.map { max(0, $0 - 1) }
        guard let ordered = Self.toggledSelection(
            value,
            in: parts.listed,
            choices: choices,
            maxItems: limit
        ) else { return nil }
        return .some(multiSelectValue(listed: ordered, custom: parts.custom))
    }

    func toggledCustomSelection(
        allowsFreeform: Bool = true,
        values: inout [String: RemoteJSONValue],
        customChoiceFields: inout Set<String>
    ) -> Bool? {
        guard allowsFreeform, published.kind == .multiChoice else { return nil }
        let key = published.key
        let parts = multiSelectParts(
            values[key],
            allowsFreeform: true,
            isCustom: customChoiceFields.contains(key)
        )
        if parts.custom != nil {
            customChoiceFields.remove(key)
            values[key] = multiSelectValue(listed: parts.listed, custom: nil)
            return false
        }
        if let maxItems = published.maxItems, parts.listed.count >= maxItems { return nil }
        customChoiceFields.insert(key)
        values[key] = multiSelectValue(listed: parts.listed, custom: "")
        return true
    }

    func customChoiceText(from value: RemoteJSONValue?) -> String {
        multiSelectParts(value, allowsFreeform: true, isCustom: true).custom
            ?? DesktopElicitationChoiceSelection.customText(from: value)
    }

    func updatedCustomChoiceValue(
        _ text: String,
        in current: RemoteJSONValue?,
        customChoiceFields: inout Set<String>
    ) -> RemoteJSONValue? {
        guard customChoiceFields.contains(published.key)
            || multiSelectParts(current, allowsFreeform: true).custom != nil else { return nil }
        if published.kind == .multiChoice {
            customChoiceFields.insert(published.key)
            let listed = multiSelectParts(current, allowsFreeform: true, isCustom: true).listed
            return multiSelectValue(listed: listed, custom: text)
        }
        return .string(text)
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

    /// Pairs the form the Mac parsed and publishes for a question with the agent's
    /// schema, which the Mac checks answers against.
    init?(_ form: RemoteElicitationForm?, schema: RemoteJSONValue?) {
        guard let form, let schema,
              case .object(let root) = schema,
              case .object(let properties)? = root["properties"] else { return nil }
        var fields: [DesktopElicitationField] = []
        for field in form.fields {
            guard let fieldSchema = properties[field.key] else { return nil }
            fields.append(DesktopElicitationField(published: field, schema: fieldSchema))
        }
        self.fields = fields
        allowsFreeformChoices = form.allowsFreeformChoices
        self.schema = schema
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
               field.customChoiceText(from: value)
                   .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                case .choice:
                    if let first = field.choices?.first {
                        values[field.key] = .string(first.value)
                    }
                case .boolean:
                    values[field.key] = .bool(false)
                case .string:
                    values[field.key] = .string("")
                case .multiChoice:
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
        if field.kind == .multiChoice {
            return field.multiSelectParts(
                value,
                allowsFreeform: allowsFreeform,
                isCustom: allowsFreeform && isCustom
            ).custom != nil ? .other : .unset
        }
        if field.kind == .boolean, value == nil {
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

    static func text(for value: RemoteJSONValue?) -> String {
        if case let .number(number)? = value, number.isFinite {
            return format(number)
        }
        if case let .string(text)? = value { return text }
        return ""
    }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            return String(format: "%.0f", value)
        }
        if let localized = makeFormatter(locale: .current).string(from: NSNumber(value: value)),
           parse(localized, locale: .current) == value {
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
