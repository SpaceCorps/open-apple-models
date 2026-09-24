import Foundation
import FoundationModels

extension JSONValue {
    /// Returns a copy whose object keys follow the property order declared by
    /// `schema` (recursively), so structured output is deterministic even when
    /// the framework hands back unordered content.
    public func ordered(by schema: GenerationSchema) -> JSONValue {
        guard let data = try? JSONEncoder().encode(schema), let root = try? JSONValue(parsing: data) else { return self }
        return SchemaOrdering(root: root).apply(self, schema: root, depth: 0)
    }

    /// Returns a copy whose object keys follow the order declared by a JSON Schema.
    public func ordered(by schema: JSONSchema) -> JSONValue {
        SchemaOrdering(root: schema.json).apply(self, schema: schema.json, depth: 0)
    }
}

private struct SchemaOrdering {
    let root: JSONValue

    func apply(_ value: JSONValue, schema: JSONValue, depth: Int) -> JSONValue {
        guard depth < 64 else { return value }
        let schema = resolve(schema)
        switch value {
        case .object(let object):
            if let choices = (schema["anyOf"] ?? schema["oneOf"])?.arrayValue {
                let keys = Set(object.keys)
                let best = choices.map(resolve).max { lhs, rhs in
                    overlap(lhs, keys) < overlap(rhs, keys)
                }
                return best.map { apply(value, schema: $0, depth: depth + 1) } ?? value
            }
            let properties = schema["properties"]?.objectValue ?? JSONObject()
            let order = schema["x-order"]?.arrayValue?.compactMap(\.stringValue) ?? properties.keys
            var result = JSONObject()
            for key in order where object[key] != nil {
                result[key] = apply(object[key]!, schema: properties[key] ?? [:], depth: depth + 1)
            }
            for (key, child) in object where result[key] == nil {
                result[key] = apply(child, schema: properties[key] ?? [:], depth: depth + 1)
            }
            return .object(result)
        case .array(let items):
            let itemSchema = schema["items"] ?? [:]
            return .array(items.map { apply($0, schema: itemSchema, depth: depth + 1) })
        default:
            return value
        }
    }

    private func overlap(_ schema: JSONValue, _ keys: Set<String>) -> Int {
        let names = Set(schema["properties"]?.objectValue?.keys ?? [])
        return names.intersection(keys).count * 2 - names.subtracting(keys).count
    }

    private func resolve(_ schema: JSONValue) -> JSONValue {
        var current = schema
        for _ in 0..<16 {
            guard let ref = current["$ref"]?.stringValue else { return current }
            if ref == "#" { return root }
            guard ref.hasPrefix("#/") else { return current }
            var node = root
            for token in ref.dropFirst(2).split(separator: "/") {
                guard let next = node[String(token)] else { return current }
                node = next
            }
            current = node
        }
        return current
    }
}
