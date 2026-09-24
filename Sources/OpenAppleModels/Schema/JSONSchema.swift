import Foundation
import FoundationModels

/// A JSON Schema document describing tool arguments or structured output.
///
/// Supports the subset used by OpenAI-style tool definitions and structured
/// outputs: `object`, `array`, `string` (with `enum`, `const`, `pattern`),
/// `integer`/`number` (with `minimum`/`maximum`), `boolean`, `anyOf`/`oneOf`,
/// nullable types, `allOf` merging, and local `$ref` into `$defs`/`definitions`.
/// Anything the on-device model cannot enforce is folded into the description
/// so the model still sees it; see ``SchemaConverter``.
public struct JSONSchema: Sendable, Hashable, CustomStringConvertible {
    public var json: JSONValue

    public init(_ json: JSONValue) { self.json = json }

    public init(parsing text: String) throws(JSONParseError) { json = try JSONValue(parsing: text) }

    public var description: String { json.serialized([.prettyPrinted]) }

    /// Converts to a FoundationModels `GenerationSchema`.
    /// - Parameter name: Name for the root type when the schema has no `title`.
    public func generationSchema(name: String) throws(SchemaConversionError) -> GenerationSchema {
        try SchemaConverter.convert(self, rootName: name).schema
    }
}

// MARK: - Builders

extension JSONSchema {
    /// An object schema. Properties are generated in the order given.
    /// - Parameter required: Required property names; `nil` means all properties are required.
    public static func object(
        _ properties: KeyValuePairs<String, JSONSchema>,
        required: [String]? = nil,
        title: String? = nil,
        description: String? = nil
    ) -> JSONSchema {
        var object: JSONObject = ["type": "object"]
        if let title { object["title"] = .string(title) }
        if let description { object["description"] = .string(description) }
        object["properties"] = .object(JSONObject(properties.map { ($0.key, $0.value.json) }))
        object["required"] = .array((required ?? properties.map(\.key)).map(JSONValue.string))
        object["additionalProperties"] = false
        return JSONSchema(.object(object))
    }

    public static func string(description: String? = nil, enum values: [String]? = nil, pattern: String? = nil) -> JSONSchema {
        var object: JSONObject = ["type": "string"]
        if let description { object["description"] = .string(description) }
        if let values { object["enum"] = .array(values.map(JSONValue.string)) }
        if let pattern { object["pattern"] = .string(pattern) }
        return JSONSchema(.object(object))
    }

    public static func integer(description: String? = nil, minimum: Int? = nil, maximum: Int? = nil) -> JSONSchema {
        var object: JSONObject = ["type": "integer"]
        if let description { object["description"] = .string(description) }
        if let minimum { object["minimum"] = .number(Double(minimum)) }
        if let maximum { object["maximum"] = .number(Double(maximum)) }
        return JSONSchema(.object(object))
    }

    public static func number(description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONSchema {
        var object: JSONObject = ["type": "number"]
        if let description { object["description"] = .string(description) }
        if let minimum { object["minimum"] = .number(minimum) }
        if let maximum { object["maximum"] = .number(maximum) }
        return JSONSchema(.object(object))
    }

    public static func boolean(description: String? = nil) -> JSONSchema {
        var object: JSONObject = ["type": "boolean"]
        if let description { object["description"] = .string(description) }
        return JSONSchema(.object(object))
    }

    public static func array(of items: JSONSchema, description: String? = nil, minItems: Int? = nil, maxItems: Int? = nil) -> JSONSchema {
        var object: JSONObject = ["type": "array", "items": items.json]
        if let description { object["description"] = .string(description) }
        if let minItems { object["minItems"] = .number(Double(minItems)) }
        if let maxItems { object["maxItems"] = .number(Double(maxItems)) }
        return JSONSchema(.object(object))
    }

    /// A tagged union: the model generates exactly one of the given schemas.
    public static func anyOf(_ choices: [JSONSchema], description: String? = nil) -> JSONSchema {
        var object: JSONObject = ["anyOf": .array(choices.map(\.json))]
        if let description { object["description"] = .string(description) }
        return JSONSchema(.object(object))
    }

    /// An object with no arguments, for tools that take none.
    public static var empty: JSONSchema { .object([:]) }

    /// Returns a copy with `description` set.
    public func described(_ description: String) -> JSONSchema {
        var copy = json
        copy["description"] = .string(description)
        return JSONSchema(copy)
    }
}

extension JSONSchema {
    /// Converts a FoundationModels `GenerationSchema` (for example from a
    /// `@Generable` type) back into plain JSON Schema, e.g. to advertise a
    /// Swift-defined tool to an HTTP client.
    public init(_ schema: GenerationSchema) throws {
        let data = try JSONEncoder().encode(schema)
        var json = try JSONValue(parsing: data)
        Self.stripVendorKeys(&json)
        self.init(json)
    }

    private static func stripVendorKeys(_ value: inout JSONValue) {
        switch value {
        case .object(var object):
            for key in object.keys where key.hasPrefix("x-") { object[key] = nil }
            for key in object.keys {
                var child = object[key]!
                stripVendorKeys(&child)
                object[key] = child
            }
            value = .object(object)
        case .array(var array):
            for index in array.indices { stripVendorKeys(&array[index]) }
            value = .array(array)
        default:
            break
        }
    }
}
