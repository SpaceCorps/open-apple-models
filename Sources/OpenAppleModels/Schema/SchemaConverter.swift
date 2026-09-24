import Foundation
import FoundationModels

/// Thrown when a JSON Schema cannot be expressed as a `GenerationSchema`.
public struct SchemaConversionError: Error, Sendable, CustomStringConvertible {
    public var path: String
    public var message: String
    public var description: String { "Schema error at \(path): \(message)" }
}

/// Converts JSON Schema into FoundationModels `GenerationSchema` via
/// `DynamicGenerationSchema`, so tools and structured outputs can be defined
/// at runtime (from JSON, a server request, or a game's data files).
///
/// Mapping:
/// - `object` → properties in document order; properties missing from
///   `required`, or nullable, become optional.
/// - `string` + `enum` → `anyOf` string choices (the model can only emit listed values).
/// - `string` + `const` → constant guide; `pattern` is described (the
///   on-device model rejects most regex guides).
/// - `integer`/`number` + `minimum`/`maximum` → range guides.
/// - `array` + `items`/`minItems`/`maxItems` → element-count guides.
/// - `anyOf`/`oneOf` → a union the model picks one branch of; `null` branches mark the value optional.
/// - `allOf` of objects → merged object.
/// - `$ref` to `#/$defs/…`, `#/definitions/…` or `#` → named references (recursion works).
///
/// Unsupported constraints (`format`, `minLength`, `multipleOf`, …) are
/// appended to the description and reported in ``Result/warnings``.
public struct SchemaConverter {
    public struct Result: Sendable {
        public var schema: GenerationSchema
        public var warnings: [String]
    }

    public static func convert(_ schema: JSONSchema, rootName: String) throws(SchemaConversionError) -> Result {
        var converter = SchemaConverter(root: schema.json)
        let name = converter.uniqueName(schema.json["title"]?.stringValue ?? rootName)
        converter.rootTypeName = name
        let root = try converter.build(schema.json, name: name, path: "#").schema
        do {
            let generation = try GenerationSchema(root: root, dependencies: converter.dependencies)
            return Result(schema: generation, warnings: converter.warnings)
        } catch {
            throw SchemaConversionError(path: "#", message: "FoundationModels rejected the schema: \(error)")
        }
    }

    private let root: JSONValue
    private var rootTypeName = ""
    private var dependencies: [DynamicGenerationSchema] = []
    private var referenceNames: [String: String] = [:]
    private var usedNames: Set<String> = []
    private(set) var warnings: [String] = []

    private init(root: JSONValue) { self.root = root }

    private struct Built {
        var schema: DynamicGenerationSchema
        var nullable = false
        /// Description to place on the enclosing property (primitives and
        /// arrays cannot carry their own description).
        var description: String?
    }

    // MARK: Dispatch

    private mutating func build(_ node: JSONValue, name: String, path: String) throws(SchemaConversionError) -> Built {
        guard case .object(let schema) = node else {
            if node == .bool(true) {
                warn(path, "unconstrained schema `true` is generated as a string")
                return Built(schema: DynamicGenerationSchema(type: String.self))
            }
            throw SchemaConversionError(path: path, message: "expected a schema object")
        }
        let description = schema["description"]?.stringValue

        if let ref = schema["$ref"]?.stringValue {
            return try buildReference(ref, description: description, path: path)
        }
        if let allOf = schema["allOf"]?.arrayValue {
            return try build(mergeAllOf(schema, allOf, path: path), name: name, path: path)
        }
        if let choices = (schema["anyOf"] ?? schema["oneOf"])?.arrayValue {
            return try buildUnion(choices, schema: schema, name: name, path: path)
        }
        if let values = schema["enum"]?.arrayValue {
            return try buildEnum(values, schema: schema, name: name, path: path)
        }
        if let constant = schema["const"] {
            guard let string = constant.stringValue else {
                warn(path, "non-string const \(constant) is described instead of enforced")
                var copy = schema
                copy["const"] = nil
                copy["description"] = .string(join(description, "Must be exactly \(constant)."))
                return try build(.object(copy), name: name, path: path)
            }
            return Built(schema: DynamicGenerationSchema(type: String.self, guides: [.constant(string)]), description: description)
        }

        var (type, nullable) = try resolveType(schema, path: path)
        var built: Built
        switch type {
        case "object": built = try buildObject(schema, name: name, path: path)
        case "array": built = try buildArray(schema, name: name, path: path)
        case "string": built = try buildString(schema, path: path)
        case "integer": built = buildInteger(schema, path: path)
        case "number": built = buildNumber(schema, path: path)
        case "boolean": built = Built(schema: DynamicGenerationSchema(type: Bool.self), description: description)
        case "null":
            nullable = true
            built = Built(schema: .null, description: description)
        default:
            throw SchemaConversionError(path: path, message: "unsupported type '\(type)'")
        }
        built.nullable = built.nullable || nullable
        return built
    }

    // MARK: Types

    private mutating func resolveType(_ schema: JSONObject, path: String) throws(SchemaConversionError) -> (String, Bool) {
        var types: [String] = []
        switch schema["type"] {
        case .string(let type)?: types = [type]
        case .array(let values)?: types = values.compactMap(\.stringValue)
        case nil:
            if schema["properties"] != nil { types = ["object"] }
            else if schema["items"] != nil { types = ["array"] }
            else if schema["pattern"] != nil || schema["format"] != nil { types = ["string"] }
            else if schema["minimum"] != nil || schema["maximum"] != nil { types = ["number"] }
            else {
                warn(path, "schema without a type is generated as a string")
                types = ["string"]
            }
        default:
            throw SchemaConversionError(path: path, message: "invalid 'type'")
        }
        let nullable = types.contains("null")
        let concrete = types.filter { $0 != "null" }
        if concrete.count > 1 {
            warn(path, "multiple types \(concrete) are not supported; using '\(concrete[0])'")
        }
        return (concrete.first ?? "null", nullable)
    }

    private mutating func buildObject(_ schema: JSONObject, name: String, path: String) throws(SchemaConversionError) -> Built {
        let properties = schema["properties"]?.objectValue ?? JSONObject()
        let required = Set(schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        if properties.isEmpty, let additional = schema["additionalProperties"], additional != .bool(false) {
            warn(path, "free-form objects (additionalProperties without properties) cannot be generated; producing an empty object")
        }
        // Property order follows `x-order` when present (as written by
        // `fm schema object` and FoundationModels' own encoder), otherwise
        // document order.
        var order = schema["x-order"]?.arrayValue?.compactMap(\.stringValue).filter { properties[$0] != nil } ?? []
        order += properties.keys.filter { !order.contains($0) }
        var converted: [DynamicGenerationSchema.Property] = []
        for key in order {
            let value = properties[key]!
            let childName = uniqueName(value["title"]?.stringValue ?? name + "_" + key)
            let child = try build(value, name: childName, path: path + "/properties/" + key)
            let description = child.description ?? value["description"]?.stringValue
            converted.append(DynamicGenerationSchema.Property(
                name: key,
                description: description,
                schema: child.schema,
                isOptional: child.nullable || !required.contains(key)))
        }
        let description = describe(schema, base: schema["description"]?.stringValue, path: path,
                                   ignoring: ["minProperties", "maxProperties", "patternProperties", "dependentRequired"])
        return Built(schema: DynamicGenerationSchema(name: name, description: description, properties: converted))
    }

    private mutating func buildArray(_ schema: JSONObject, name: String, path: String) throws(SchemaConversionError) -> Built {
        var itemsNode = schema["items"]
        if itemsNode == nil, let prefix = schema["prefixItems"]?.arrayValue?.first {
            warn(path, "tuple arrays (prefixItems) are generated as arrays of the first item type")
            itemsNode = prefix
        }
        let items: Built
        if let itemsNode {
            items = try build(itemsNode, name: uniqueName(itemsNode["title"]?.stringValue ?? name + "_item"), path: path + "/items")
        } else {
            warn(path, "array without 'items' is generated as an array of strings")
            items = Built(schema: DynamicGenerationSchema(type: String.self))
        }
        var description = describe(schema, base: schema["description"]?.stringValue, path: path, ignoring: ["uniqueItems", "contains"])
        if let itemDescription = items.description {
            description = join(description, "Each item: \(itemDescription)")
        }
        let array = DynamicGenerationSchema(
            arrayOf: items.schema,
            minimumElements: schema["minItems"]?.intValue,
            maximumElements: schema["maxItems"]?.intValue)
        return Built(schema: array, description: description)
    }

    private mutating func buildString(_ schema: JSONObject, path: String) throws(SchemaConversionError) -> Built {
        var description = describe(schema, base: schema["description"]?.stringValue, path: path,
                                   ignoring: ["format", "minLength", "maxLength", "contentEncoding", "contentMediaType"])
        if let pattern = schema["pattern"]?.stringValue {
            // The on-device model rejects most regex guides ("unsupported
            // generation guide"), so patterns are described, not enforced.
            warn(path, "pattern '\(pattern)' is described to the model but not enforced")
            description = join(description, "Must match the regular expression \(pattern).")
        }
        return Built(schema: DynamicGenerationSchema(type: String.self), description: description)
    }

    private mutating func buildInteger(_ schema: JSONObject, path: String) -> Built {
        var lower = schema["minimum"]?.doubleValue.map { Self.clampedInt($0.rounded(.up)) }
        var upper = schema["maximum"]?.doubleValue.map { Self.clampedInt($0.rounded(.down)) }
        if let exclusive = schema["exclusiveMinimum"]?.doubleValue {
            let bound = Self.clampedInt(exclusive.rounded(.down))
            lower = max(lower ?? .min, bound == .max ? .max : bound + 1)
        }
        if let exclusive = schema["exclusiveMaximum"]?.doubleValue {
            let bound = Self.clampedInt(exclusive.rounded(.up))
            upper = min(upper ?? .max, bound == .min ? .min : bound - 1)
        }
        var guides: [GenerationGuide<Int>] = []
        switch (lower, upper) {
        case let (lower?, upper?) where lower <= upper: guides.append(.range(lower...upper))
        case let (lower?, nil): guides.append(.minimum(lower))
        case let (nil, upper?): guides.append(.maximum(upper))
        case (_?, _?): warn(path, "empty integer range is ignored")
        default: break
        }
        let description = describe(schema, base: schema["description"]?.stringValue, path: path, ignoring: ["multipleOf"])
        return Built(schema: DynamicGenerationSchema(type: Int.self, guides: guides), description: description)
    }

    private mutating func buildNumber(_ schema: JSONObject, path: String) -> Built {
        let lower = schema["minimum"]?.doubleValue ?? schema["exclusiveMinimum"]?.doubleValue
        let upper = schema["maximum"]?.doubleValue ?? schema["exclusiveMaximum"]?.doubleValue
        if schema["exclusiveMinimum"] != nil || schema["exclusiveMaximum"] != nil {
            warn(path, "exclusive number bounds are enforced as inclusive")
        }
        var guides: [GenerationGuide<Double>] = []
        switch (lower, upper) {
        case let (lower?, upper?) where lower <= upper: guides.append(.range(lower...upper))
        case let (lower?, nil): guides.append(.minimum(lower))
        case let (nil, upper?): guides.append(.maximum(upper))
        case (_?, _?): warn(path, "empty number range is ignored")
        default: break
        }
        let description = describe(schema, base: schema["description"]?.stringValue, path: path, ignoring: ["multipleOf"])
        return Built(schema: DynamicGenerationSchema(type: Double.self, guides: guides), description: description)
    }

    // MARK: Enums and unions

    private mutating func buildEnum(_ values: [JSONValue], schema: JSONObject, name: String, path: String) throws(SchemaConversionError) -> Built {
        let nullable = values.contains(.null)
        let concrete = values.filter { !$0.isNull }
        let description = schema["description"]?.stringValue
        if concrete.isEmpty {
            return Built(schema: .null, nullable: true, description: description)
        }
        if concrete.allSatisfy({ $0.stringValue != nil }) {
            let strings = concrete.compactMap(\.stringValue)
            return Built(schema: DynamicGenerationSchema(name: name, description: description, anyOf: strings),
                         nullable: nullable, description: description)
        }
        if concrete.allSatisfy({ $0.intValue != nil }) {
            let ints = concrete.compactMap(\.intValue)
            warn(path, "integer enum is enforced as a range \(ints.min()!)...\(ints.max()!); exact values are described")
            let listed = join(description, "One of: \(ints.map(String.init).joined(separator: ", ")).")
            return Built(schema: DynamicGenerationSchema(type: Int.self, guides: [.range(ints.min()!...ints.max()!)]),
                         nullable: nullable, description: listed)
        }
        warn(path, "mixed-type enum is generated as strings")
        let strings = concrete.map { $0.stringValue ?? $0.serialized() }
        return Built(schema: DynamicGenerationSchema(name: name, description: description, anyOf: strings),
                     nullable: nullable, description: description)
    }

    private mutating func buildUnion(_ choices: [JSONValue], schema: JSONObject, name: String, path: String) throws(SchemaConversionError) -> Built {
        let nullable = choices.contains { $0["type"]?.stringValue == "null" || $0["const"] == .null }
        let concrete = choices.filter { !($0["type"]?.stringValue == "null" || $0["const"] == .null) }
        let description = schema["description"]?.stringValue
        guard !concrete.isEmpty else { return Built(schema: .null, nullable: true, description: description) }

        if concrete.count == 1 {
            var single = concrete[0]
            if single["description"] == nil, let description { single["description"] = .string(description) }
            var built = try build(single, name: name, path: path + "/anyOf/0")
            built.nullable = built.nullable || nullable
            return built
        }

        // A union of string literals collapses into a single string enum.
        let literals = concrete.compactMap { choice -> [String]? in
            if let constant = choice["const"]?.stringValue { return [constant] }
            if let values = choice["enum"]?.arrayValue, values.allSatisfy({ $0.stringValue != nil }) {
                return values.compactMap(\.stringValue)
            }
            return nil
        }
        if literals.count == concrete.count {
            return Built(schema: DynamicGenerationSchema(name: name, description: description, anyOf: literals.flatMap { $0 }),
                         nullable: nullable, description: description)
        }

        var branches: [DynamicGenerationSchema] = []
        for (offset, choice) in concrete.enumerated() {
            let branchName = uniqueName(choice["title"]?.stringValue ?? "\(name)_option\(offset + 1)")
            branches.append(try build(choice, name: branchName, path: "\(path)/anyOf/\(offset)").schema)
        }
        return Built(schema: DynamicGenerationSchema(name: name, description: description, anyOf: branches),
                     nullable: nullable, description: description)
    }

    private mutating func mergeAllOf(_ schema: JSONObject, _ parts: [JSONValue], path: String) throws(SchemaConversionError) -> JSONValue {
        var merged = schema
        merged["allOf"] = nil
        var properties = merged["properties"]?.objectValue ?? JSONObject()
        var required = merged["required"]?.arrayValue ?? []
        for (offset, part) in parts.enumerated() {
            var resolved = part
            if let ref = part["$ref"]?.stringValue { resolved = try resolvePointer(ref, path: path) }
            guard case .object(let object) = resolved else {
                throw SchemaConversionError(path: "\(path)/allOf/\(offset)", message: "expected a schema object")
            }
            for (key, value) in object["properties"]?.objectValue ?? JSONObject() { properties[key] = value }
            required.append(contentsOf: object["required"]?.arrayValue ?? [])
            for (key, value) in object where !["properties", "required"].contains(key) && merged[key] == nil {
                merged[key] = value
            }
        }
        if !properties.isEmpty {
            merged["type"] = "object"
            merged["properties"] = .object(properties)
        }
        if !required.isEmpty { merged["required"] = .array(required) }
        return .object(merged)
    }

    // MARK: References

    private mutating func buildReference(_ ref: String, description: String?, path: String) throws(SchemaConversionError) -> Built {
        if ref == "#" {
            return Built(schema: DynamicGenerationSchema(referenceTo: rootTypeName), description: description)
        }
        let target = try resolvePointer(ref, path: path)
        // Only named kinds (objects and unions) can be referenced; inline the rest.
        let isNamed = target["properties"] != nil || target["type"]?.stringValue == "object"
            || target["anyOf"] != nil || target["oneOf"] != nil
        guard isNamed else {
            let fallbackName = uniqueName(target["title"]?.stringValue ?? Self.lastComponent(of: ref))
            var built = try build(target, name: fallbackName, path: ref)
            if built.description == nil { built.description = description }
            return built
        }
        if let existing = referenceNames[ref] {
            return Built(schema: DynamicGenerationSchema(referenceTo: existing), description: description)
        }
        let typeName = uniqueName(target["title"]?.stringValue ?? Self.lastComponent(of: ref))
        referenceNames[ref] = typeName  // registered before building so recursion terminates
        let built = try build(target, name: typeName, path: ref)
        dependencies.append(built.schema)
        return Built(schema: DynamicGenerationSchema(referenceTo: typeName), nullable: built.nullable,
                     description: description ?? target["description"]?.stringValue)
    }

    private func resolvePointer(_ ref: String, path: String) throws(SchemaConversionError) -> JSONValue {
        guard ref.hasPrefix("#/") else {
            throw SchemaConversionError(path: path, message: "only local $ref values are supported, got '\(ref)'")
        }
        var node = root
        for raw in ref.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false) {
            let token = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let next = node[token] {
                node = next
            } else if let index = Int(token), let next = node[index] {
                node = next
            } else {
                throw SchemaConversionError(path: path, message: "unresolvable $ref '\(ref)'")
            }
        }
        return node
    }

    /// Converts without trapping: NaN becomes 0, out-of-range values clamp.
    static func clampedInt(_ value: Double) -> Int {
        guard !value.isNaN else { return 0 }
        if value >= Double(Int.max) { return .max }
        if value <= Double(Int.min) { return .min }
        return Int(value)
    }

    private static func lastComponent(of ref: String) -> String {
        String(ref.split(separator: "/").last ?? "Ref")
    }

    // MARK: Helpers

    private mutating func uniqueName(_ proposed: String) -> String {
        var base = String(proposed.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" ? Character($0) : "_" })
        if base.isEmpty { base = "Schema" }
        if let first = base.unicodeScalars.first, CharacterSet.decimalDigits.contains(first) { base = "_" + base }
        var candidate = base
        var counter = 2
        while usedNames.contains(candidate) {
            candidate = "\(base)\(counter)"
            counter += 1
        }
        usedNames.insert(candidate)
        return candidate
    }

    /// Appends constraints the model cannot enforce to the description.
    private mutating func describe(_ schema: JSONObject, base: String?, path: String, ignoring keys: [String]) -> String? {
        var notes: [String] = []
        for key in keys {
            guard let value = schema[key] else { continue }
            notes.append("\(key): \(value.stringValue ?? value.serialized())")
            warn(path, "'\(key)' is described to the model but not enforced")
        }
        if let examples = schema["examples"]?.arrayValue, !examples.isEmpty {
            notes.append("examples: " + examples.prefix(3).map { $0.stringValue ?? $0.serialized() }.joined(separator: ", "))
        }
        if let defaultValue = schema["default"] {
            notes.append("default: \(defaultValue.stringValue ?? defaultValue.serialized())")
        }
        guard !notes.isEmpty else { return base }
        return join(base, "(" + notes.joined(separator: "; ") + ")")
    }

    private func join(_ first: String?, _ second: String) -> String {
        guard let first, !first.isEmpty else { return second }
        return first + " " + second
    }

    private mutating func warn(_ path: String, _ message: String) {
        warnings.append("\(path): \(message)")
    }
}
