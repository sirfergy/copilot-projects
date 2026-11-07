import Foundation
import CopilotProjectsProtocol

// MARK: - Interactive pending questions (`ask_user` & `elicitation`)

struct DesktopElicitationField: Identifiable, Equatable {
    enum Kind: Equatable {
        case stringEnum([String])
        case stringOneOf([Choice])
        case stringMultiSelect(choices: [Choice], maxItems: Int?)
        case bool
        case number
        case string(minLength: Int?, maxLength: Int?)
    }

    struct Choice: Equatable {
        let value: String
        let title: String
    }

    let key: String
    let title: String
    let description: String?
    let kind: Kind
    let required: Bool
    let defaultValue: RemoteJSONValue?
    let schema: RemoteJSONValue

    var id: String { key }

    func accepts(
        _ value: RemoteJSONValue,
        allowFreeformChoice: Bool = false
    ) -> Bool {
        guard AppModel.isValidElicitationContent([key: value]),
              AppModel.elicitationValue(
                  value,
                  satisfies: schema,
                  allowFreeformStringChoice: allowFreeformChoice
              ) else {
            return false
        }
        if case .stringMultiSelect = kind, case let .array(items) = value {
            var seen = Set<String>()
            return items.allSatisfy {
                if case let .string(string) = $0 { return seen.insert(string).inserted }
                return false
            }
        }
        return true
    }

    func normalizedStringInput(_ text: String) -> RemoteJSONValue? {
        guard case .string = kind else { return nil }
        let value = RemoteJSONValue.string(text)
        if !required, text.isEmpty, !accepts(value) {
            return nil
        }
        return value
    }

    var singleChoiceOptions: [Choice] {
        switch kind {
        case .stringEnum(let options):
            options.map { Choice(value: $0, title: $0.isEmpty ? "Empty string" : $0) }
        case .stringOneOf(let choices), .stringMultiSelect(let choices, _):
            choices
        case .bool, .number, .string:
            []
        }
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
        guard case let .stringMultiSelect(choices, _) = kind else { return ([], nil) }
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
        return (all.isEmpty && !required && !accepts(selection)) ? nil : selection
    }

    func toggledSelectionValue(
        _ value: String,
        in current: RemoteJSONValue?,
        allowsFreeform: Bool = false,
        isCustom: Bool = false
    ) -> RemoteJSONValue?? {
        guard case let .stringMultiSelect(choices, maxItems) = kind else { return nil }
        let parts = multiSelectParts(current, allowsFreeform: allowsFreeform, isCustom: isCustom)
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
        guard allowsFreeform, case let .stringMultiSelect(_, maxItems) = kind else { return nil }
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
        if let maxItems, parts.listed.count >= maxItems { return nil }
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
        guard customChoiceFields.contains(key)
            || multiSelectParts(current, allowsFreeform: true).custom != nil else { return nil }
        if case .stringMultiSelect = kind {
            customChoiceFields.insert(key)
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
    private static let maxFields = 32
    private static let maxChoices = 50
    static let propertyOrderKey = "x-copilot-projects-property-order"

    static func parse(
        _ schema: RemoteJSONValue?,
        allowFreeformChoices: Bool = false
    ) -> DesktopElicitationForm? {
        guard let schema, case let .object(root) = schema else { return nil }
        let supportedRootKeys: Set<String> = [
            "$schema", "type", "title", "description", "properties", "required",
            "additionalProperties", propertyOrderKey,
        ]
        guard root.keys.allSatisfy({ supportedRootKeys.contains($0) }) else { return nil }
        if let type = root["type"] {
            guard case .string("object") = type else { return nil }
        }
        guard case let .object(properties)? = root["properties"], !properties.isEmpty else {
            return nil
        }
        guard properties.count <= maxFields else { return nil }
        var required = Set<String>()
        if let requiredValue = root["required"] {
            guard case let .array(items) = requiredValue else { return nil }
            for item in items {
                guard case let .string(name) = item else { return nil }
                required.insert(name)
            }
        }
        guard required.isSubset(of: Set(properties.keys)) else { return nil }

        var fields: [DesktopElicitationField] = []
        for key in fieldOrder(root[propertyOrderKey], properties: properties) {
            guard let fieldSchema = properties[key],
                  case let .object(prop) = fieldSchema else { return nil }
            guard let kind = fieldKind(prop) else { return nil }
            let title: String
            if case let .string(value)? = prop["title"] { title = value } else { title = key }
            let description: String?
            if case let .string(value)? = prop["description"] {
                description = value
            } else {
                description = nil
            }
            fields.append(
                DesktopElicitationField(
                    key: key,
                    title: title,
                    description: description,
                    kind: kind,
                    required: required.contains(key),
                    defaultValue: prop["default"],
                    schema: fieldSchema
                )
            )
        }

        guard !fields.isEmpty else { return nil }
        return DesktopElicitationForm(
            fields: fields,
            allowsFreeformChoices: allowFreeformChoices,
            schema: schema
        )
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
                case .stringEnum(let options):
                    if let first = options.first {
                        values[field.key] = .string(first)
                    }
                case .stringOneOf(let choices):
                    if let first = choices.first {
                        values[field.key] = .string(first.value)
                    }
                case .bool:
                    values[field.key] = .bool(false)
                case .string:
                    values[field.key] = .string("")
                case .stringMultiSelect:
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

    private static func fieldOrder(
        _ value: RemoteJSONValue?,
        properties: [String: RemoteJSONValue]
    ) -> [String] {
        if case let .array(entries)? = value {
            let keys = entries.compactMap { entry -> String? in
                if case let .string(key) = entry { return key }
                return nil
            }
            if keys.count == entries.count, keys.count == properties.count,
               Set(keys) == Set(properties.keys) {
                return keys
            }
        }
        return properties.keys.sorted()
    }

    private static func fieldKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        if prop["$ref"] != nil { return nil }
        if prop["anyOf"] != nil || prop["allOf"] != nil || prop["not"] != nil
            || prop["if"] != nil || prop["then"] != nil || prop["else"] != nil
            || prop["const"] != nil || prop["pattern"] != nil
            || prop["exclusiveMinimum"] != nil || prop["exclusiveMaximum"] != nil
            || prop["multipleOf"] != nil {
            return nil
        }
        if case let .array(oneOf)? = prop["oneOf"] {
            guard prop["enum"] == nil, prop["format"] == nil,
                  prop["minimum"] == nil, prop["maximum"] == nil,
                  prop["minItems"] == nil, prop["maxItems"] == nil, prop["items"] == nil,
                  prop["minLength"] == nil, prop["maxLength"] == nil else { return nil }
            guard case .string("string")? = prop["type"] else { return nil }
            guard let choices = labeledChoices(oneOf) else { return nil }
            return .stringOneOf(choices)
        }
        if case let .array(values)? = prop["enum"] {
            guard prop["format"] == nil,
                  prop["minimum"] == nil, prop["maximum"] == nil,
                  prop["minItems"] == nil, prop["maxItems"] == nil, prop["items"] == nil,
                  prop["minLength"] == nil, prop["maxLength"] == nil else { return nil }
            guard case .string("string")? = prop["type"] else { return nil }
            guard values.count <= maxChoices else { return nil }
            var choices: [String] = []
            for entry in values {
                guard case let .string(value) = entry else { return nil }
                choices.append(value)
            }
            guard Set(choices).count == choices.count else { return nil }
            return choices.isEmpty ? nil : .stringEnum(choices)
        }
        guard case let .string(type)? = prop["type"] else { return nil }
        if type != "string",
           prop["minLength"] != nil || prop["maxLength"] != nil || prop["format"] != nil {
            return nil
        }
        if type != "number" && type != "integer",
           prop["minimum"] != nil || prop["maximum"] != nil {
            return nil
        }
        if type != "array",
           prop["minItems"] != nil || prop["maxItems"] != nil || prop["items"] != nil {
            return nil
        }
        switch type {
        case "boolean": return .bool
        case "integer", "number": return numberKind(prop)
        case "string": return stringKind(prop)
        case "array": return arrayKind(prop)
        default: return nil
        }
    }

    private static func numberKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        let minimum: Double?
        if let raw = prop["minimum"] {
            guard case let .number(value) = raw, value.isFinite else { return nil }
            minimum = value
        } else {
            minimum = nil
        }
        let maximum: Double?
        if let raw = prop["maximum"] {
            guard case let .number(value) = raw, value.isFinite else { return nil }
            maximum = value
        } else {
            maximum = nil
        }
        if let minimum, let maximum, minimum > maximum { return nil }
        return .number
    }

    private static func stringKind(
        _ prop: [String: RemoteJSONValue]
    ) -> DesktopElicitationField.Kind? {
        if let rawFormat = prop["format"] {
            guard case .string = rawFormat else { return nil }
        }
        let minLength: Int?
        if let raw = prop["minLength"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            minLength = value
        } else {
            minLength = nil
        }
        let maxLength: Int?
        if let raw = prop["maxLength"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            maxLength = value
        } else {
            maxLength = nil
        }
        if let minLength, let maxLength, minLength > maxLength { return nil }
        return .string(minLength: minLength, maxLength: maxLength)
    }

    private static func arrayKind(_ prop: [String: RemoteJSONValue]) -> DesktopElicitationField.Kind? {
        guard case let .object(items)? = prop["items"] else { return nil }
        guard let choices = choiceSet(items) else { return nil }
        let minItems: Int?
        if let raw = prop["minItems"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            minItems = value
        } else {
            minItems = nil
        }
        let maxItems: Int?
        if let raw = prop["maxItems"] {
            guard let value = nonNegativeInt(raw) else { return nil }
            maxItems = value
        } else {
            maxItems = nil
        }
        if let minItems, let maxItems, minItems > maxItems { return nil }
        return .stringMultiSelect(choices: choices, maxItems: maxItems)
    }

    private static func choiceSet(_ items: [String: RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        let supportedItemKeys: Set<String> = [
            "anyOf", "oneOf", "enum", "type", "title", "description",
        ]
        guard items.keys.allSatisfy({ supportedItemKeys.contains($0) }) else { return nil }
        if let itemType = items["type"] {
            guard case .string("string") = itemType else { return nil }
        }
        if (items["oneOf"] == nil) != (items["anyOf"] == nil),
           case let .array(alternatives)? = items["oneOf"] ?? items["anyOf"] {
            guard items["enum"] == nil else { return nil }
            return labeledChoices(alternatives)
        }
        if case let .array(values)? = items["enum"],
           items["oneOf"] == nil,
           items["anyOf"] == nil {
            return bareChoices(values)
        }
        return nil
    }

    private static func labeledChoices(_ entries: [RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        guard entries.count <= maxChoices else { return nil }
        var choices: [DesktopElicitationField.Choice] = []
        var seen = Set<String>()
        for entry in entries {
            guard case let .object(option) = entry,
                  option.keys.allSatisfy({ $0 == "const" || $0 == "title" || $0 == "description" }),
                  case let .string(value)? = option["const"],
                  seen.insert(value).inserted else { return nil }
            let title: String
            if let titleValue = option["title"] {
                guard case let .string(label) = titleValue else { return nil }
                title = label
            } else {
                title = value
            }
            choices.append(.init(value: value, title: title))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func bareChoices(_ values: [RemoteJSONValue]) -> [DesktopElicitationField.Choice]? {
        guard values.count <= maxChoices else { return nil }
        var choices: [DesktopElicitationField.Choice] = []
        var seen = Set<String>()
        for entry in values {
            guard case let .string(value) = entry, seen.insert(value).inserted else { return nil }
            choices.append(.init(value: value, title: value))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func nonNegativeInt(_ value: RemoteJSONValue) -> Int? {
        guard case let .number(number) = value,
              number.isFinite, number >= 0,
              let integer = Int(exactly: number) else { return nil }
        return integer
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
        if case .stringMultiSelect = field.kind {
            return field.multiSelectParts(
                value,
                allowsFreeform: allowsFreeform,
                isCustom: allowsFreeform && isCustom
            ).custom != nil ? .other : .unset
        }
        if field.kind == .bool, value == nil {
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
