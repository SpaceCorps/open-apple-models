import FoundationModels

extension JSONValue {
    /// Converts model-generated content into JSON, keeping property order.
    public init(_ content: GeneratedContent) {
        switch content.kind {
        case .null: self = .null
        case .bool(let value): self = .bool(value)
        case .number(let value): self = .number(value)
        case .string(let value): self = .string(value)
        case .array(let elements): self = .array(elements.map(JSONValue.init))
        case .structure(let properties, let orderedKeys):
            var object = JSONObject()
            for key in orderedKeys { if let value = properties[key] { object[key] = JSONValue(value) } }
            // Defensive: include any keys missing from `orderedKeys`.
            for key in properties.keys.sorted() where object[key] == nil { object[key] = JSONValue(properties[key]!) }
            self = .object(object)
        @unknown default:
            // Future kinds: fall back to the JSON text the framework produces.
            self = (try? JSONValue(parsing: content.jsonString)) ?? .string(content.jsonString)
        }
    }

    /// Converts JSON into `GeneratedContent`, e.g. to seed a transcript with
    /// tool-call arguments produced elsewhere.
    public var generatedContent: GeneratedContent {
        switch self {
        case .null: GeneratedContent(kind: .null)
        case .bool(let value): GeneratedContent(kind: .bool(value))
        case .number(let value): GeneratedContent(kind: .number(value))
        case .string(let value): GeneratedContent(kind: .string(value))
        case .array(let values): GeneratedContent(kind: .array(values.map(\.generatedContent)))
        case .object(let object):
            GeneratedContent(kind: .structure(
                properties: Dictionary(uniqueKeysWithValues: object.pairs.map { ($0.key, $0.value.generatedContent) }),
                orderedKeys: object.keys))
        }
    }
}
