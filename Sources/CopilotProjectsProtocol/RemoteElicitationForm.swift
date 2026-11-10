import Foundation

/// The form the Mac offers for a question's schema. The Mac parses the schema
/// once: its own question card shows this form, and remote snapshots publish it
/// on the request so every client renders the same fields. Only a bounded, flat
/// subset of JSON Schema becomes a form; a request without one is answered in
/// the terminal.
public struct RemoteElicitationForm: Codable, Equatable, Sendable {
    public struct Choice: Codable, Equatable, Sendable {
        public let value: String
        public let title: String
    }

    public struct Field: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable {
            /// One of `choices`.
            case choice
            /// Any of `choices`, from `minItems` to `maxItems` of them.
            case multiChoice
            case boolean
            /// A number, whole when `integer` is true.
            case number
            /// Text of `minLength` to `maxLength` code points.
            case string
        }

        public let key: String
        /// The schema's title, or the key when it has none.
        public let title: String
        public let description: String?
        public let required: Bool
        /// The schema's `default`, as the agent wrote it.
        public let defaultValue: RemoteJSONValue?
        public let kind: Kind
        public let choices: [Choice]?
        public fileprivate(set) var minItems: Int?
        public fileprivate(set) var maxItems: Int?
        public fileprivate(set) var integer: Bool?
        public fileprivate(set) var minLength: Int?
        public fileprivate(set) var maxLength: Int?

        public var id: String { key }

        private enum CodingKeys: String, CodingKey {
            case key, title, description, required, defaultValue = "default", kind, choices
            case minItems, maxItems, integer, minLength, maxLength
        }
    }

    public let fields: [Field]
    /// Whether a choice, multi-choice or boolean field also takes typed text. The
    /// Mac accepts that only for a question without an `elicitationSource`.
    public let allowsFreeformChoices: Bool
}

extension RemoteElicitationForm {
    /// The tracker records the agent's property order here because decoding the
    /// schema into a dictionary loses it.
    public static let propertyOrderKey = "x-copilot-projects-property-order"
    private static let maxFields = 32
    private static let maxChoices = 50
    private static let supportedRootKeys: Set<String> = [
        "$schema", "type", "title", "description", "properties", "required",
        "additionalProperties", propertyOrderKey,
    ]
    private static let unsupportedKeywords: Set<String> = [
        "$ref", "anyOf", "allOf", "not", "if", "then", "else", "const", "pattern",
        "exclusiveMinimum", "exclusiveMaximum", "multipleOf",
    ]
    /// The constraints each type takes. One on a field of another type, or on a
    /// choice, contradicts the schema. The Mac checks a number's range and a
    /// string's format when it is answered; the form doesn't carry them.
    private static let constraints: [String: Set<String>] = [
        "string": ["minLength", "maxLength", "format"],
        "number": ["minimum", "maximum"],
        "integer": ["minimum", "maximum"],
        "array": ["minItems", "maxItems", "items"],
    ]

    /// The form for `schema`, or nil when it is outside the supported subset and
    /// the question is answered in the terminal.
    public static func parse(
        _ schema: RemoteJSONValue?,
        allowFreeformChoices: Bool = false
    ) -> RemoteElicitationForm? {
        guard case let .object(root)? = schema,
              root.keys.allSatisfy(supportedRootKeys.contains) else { return nil }
        if let type = root["type"] {
            guard case .string("object") = type else { return nil }
        }
        guard case let .object(properties)? = root["properties"],
              !properties.isEmpty, properties.count <= maxFields else { return nil }
        var required = Set<String>()
        if let requiredValue = root["required"] {
            guard case let .array(items) = requiredValue else { return nil }
            for item in items {
                guard case let .string(name) = item else { return nil }
                required.insert(name)
            }
        }
        guard required.isSubset(of: properties.keys) else { return nil }

        var fields: [Field] = []
        for key in fieldOrder(root[propertyOrderKey], properties: properties) {
            guard case let .object(prop)? = properties[key],
                  let field = makeField(key, prop, required: required.contains(key)) else {
                return nil
            }
            fields.append(field)
        }
        return RemoteElicitationForm(fields: fields, allowsFreeformChoices: allowFreeformChoices)
    }

    /// The agent's property order when the tracker supplied a complete one;
    /// otherwise sorted keys, so the order is at least stable.
    private static func fieldOrder(
        _ value: RemoteJSONValue?,
        properties: [String: RemoteJSONValue]
    ) -> [String] {
        if case let .array(entries)? = value {
            let keys = entries.compactMap(string)
            if keys.count == entries.count, keys.count == properties.count,
               Set(keys) == Set(properties.keys) {
                return keys
            }
        }
        return properties.keys.sorted()
    }

    private static func makeField(
        _ key: String,
        _ prop: [String: RemoteJSONValue],
        required: Bool
    ) -> Field? {
        guard unsupportedKeywords.isDisjoint(with: prop.keys) else { return nil }
        func answered(_ kind: Field.Kind, choices: [Choice]? = nil) -> Field {
            Field(
                key: key,
                title: string(prop["title"]) ?? key,
                description: string(prop["description"]),
                required: required,
                defaultValue: prop["default"],
                kind: kind,
                choices: choices
            )
        }
        if case let .array(options)? = prop["oneOf"] {
            guard prop["enum"] == nil, isChoice(prop),
                  let choices = labeledChoices(options) else { return nil }
            return answered(.choice, choices: choices)
        }
        if case let .array(values)? = prop["enum"] {
            guard isChoice(prop), let choices = bareChoices(values) else { return nil }
            return answered(.choice, choices: choices.map {
                Choice(value: $0.value, title: $0.value.isEmpty ? "Empty string" : $0.value)
            })
        }
        guard let type = string(prop["type"]), carriesOnlyConstraints(prop, of: type) else {
            return nil
        }
        switch type {
        case "boolean":
            return answered(.boolean)
        case "integer", "number":
            guard bounds(prop, "minimum", "maximum", finiteNumber) != nil else { return nil }
            var field = answered(.number)
            field.integer = type == "integer" ? true : nil
            return field
        case "string":
            if let format = prop["format"] {
                guard case .string = format else { return nil }
            }
            guard let length = bounds(prop, "minLength", "maxLength", nonNegativeInt) else { return nil }
            var field = answered(.string)
            (field.minLength, field.maxLength) = length
            return field
        case "array":
            guard case let .object(items)? = prop["items"],
                  let choices = choiceSet(items),
                  let size = bounds(prop, "minItems", "maxItems", nonNegativeInt) else { return nil }
            var field = answered(.multiChoice, choices: choices)
            (field.minItems, field.maxItems) = size
            return field
        default:
            return nil
        }
    }

    private static func isChoice(_ prop: [String: RemoteJSONValue]) -> Bool {
        prop["type"] == .string("string") && carriesOnlyConstraints(prop, of: nil)
    }

    private static func carriesOnlyConstraints(
        _ prop: [String: RemoteJSONValue],
        of type: String?
    ) -> Bool {
        let own = type.flatMap { constraints[$0] } ?? []
        return constraints.values.allSatisfy { $0.subtracting(own).isDisjoint(with: prop.keys) }
    }

    /// The `lower` and `upper` bounds `prop` gives, or nil when one is malformed
    /// or they cross.
    private static func bounds<Bound: Comparable>(
        _ prop: [String: RemoteJSONValue],
        _ lower: String,
        _ upper: String,
        _ read: (RemoteJSONValue) -> Bound?
    ) -> (lower: Bound?, upper: Bound?)? {
        var found: (lower: Bound?, upper: Bound?) = (nil, nil)
        if let raw = prop[lower] {
            guard let bound = read(raw) else { return nil }
            found.lower = bound
        }
        if let raw = prop[upper] {
            guard let bound = read(raw) else { return nil }
            found.upper = bound
        }
        if let lower = found.lower, let upper = found.upper, lower > upper { return nil }
        return found
    }

    /// The closed set of strings a multi-select's `items` allow.
    private static func choiceSet(_ items: [String: RemoteJSONValue]) -> [Choice]? {
        let supportedItemKeys: Set<String> = [
            "anyOf", "oneOf", "enum", "type", "title", "description",
        ]
        guard items.keys.allSatisfy(supportedItemKeys.contains) else { return nil }
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

    private static func labeledChoices(_ entries: [RemoteJSONValue]) -> [Choice]? {
        guard entries.count <= maxChoices else { return nil }
        var choices: [Choice] = []
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
            choices.append(Choice(value: value, title: title))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func bareChoices(_ values: [RemoteJSONValue]) -> [Choice]? {
        guard values.count <= maxChoices else { return nil }
        var choices: [Choice] = []
        var seen = Set<String>()
        for entry in values {
            guard case let .string(value) = entry, seen.insert(value).inserted else { return nil }
            choices.append(Choice(value: value, title: value))
        }
        return choices.isEmpty ? nil : choices
    }

    private static func string(_ value: RemoteJSONValue?) -> String? {
        if case let .string(string)? = value { return string }
        return nil
    }

    private static func finiteNumber(_ value: RemoteJSONValue) -> Double? {
        guard case let .number(number) = value, number.isFinite else { return nil }
        return number
    }

    private static func nonNegativeInt(_ value: RemoteJSONValue) -> Int? {
        guard let number = finiteNumber(value), number >= 0 else { return nil }
        return Int(exactly: number)
    }
}
