import Foundation
import OpenAppleModels

/// Prepares JSON Schemas read from files.
enum SchemaInput {
    /// Applies `x-order` (written by `fm schema object` and by
    /// FoundationModels' own schema encoding) to `properties`, so the model
    /// generates properties in the declared order. Other JSON writers emit
    /// `properties` in arbitrary order, and order matters: the model writes
    /// properties first to last (put reasoning before a decision, for example).
    static func normalized(_ value: JSONValue, depth: Int = 0) -> JSONValue {
        guard depth < 64 else { return value }
        switch value {
        case .array(let items):
            return .array(items.map { normalized($0, depth: depth + 1) })
        case .object(let object):
            var result = JSONObject()
            for (key, child) in object {
                result[key] = normalized(child, depth: depth + 1)
            }
            if let order = object["x-order"]?.arrayValue?.compactMap(\.stringValue),
               let properties = result["properties"]?.objectValue {
                var ordered = JSONObject()
                for key in order { if let property = properties[key] { ordered[key] = property } }
                for (key, property) in properties where ordered[key] == nil { ordered[key] = property }
                result["properties"] = .object(ordered)
            }
            return .object(result)
        default:
            return value
        }
    }

    /// Reads a schema file and normalizes it.
    static func load(_ path: String) throws(CLIError) -> JSONValue {
        let value = try InputFiles.readJSON(path, what: "schema")
        guard value.objectValue != nil else { throw .invalidInput("\(path): a schema must be a JSON object.") }
        return normalized(value)
    }
}
