import Foundation
import FoundationModels
import OpenAppleModels
import Testing

@Suite struct SchemaConverterTests {
    /// Encodes a converted schema back to JSON for inspection.
    func encoded(_ schema: JSONSchema, name: String = "Root") throws -> (json: JSONValue, warnings: [String]) {
        let result = try SchemaConverter.convert(schema, rootName: name)
        let data = try JSONEncoder().encode(result.schema)
        return (try JSONValue(parsing: data), result.warnings)
    }

    @Test func objectPropertiesKeepOrderAndOptionality() throws {
        let schema = try JSONSchema(parsing: """
            {"type":"object","properties":{
              "reasoning":{"type":"string","description":"Think first"},
              "choice":{"type":"string","enum":["attack","flee"]},
              "note":{"type":["string","null"]},
              "extra":{"type":"integer"}
            },"required":["reasoning","choice","note"]}
            """)
        let (json, warnings) = try encoded(schema)
        #expect(warnings.isEmpty)
        #expect(json["x-order"] == ["reasoning", "choice", "note", "extra"])
        #expect(Set(json["required"]?.arrayValue?.compactMap(\.stringValue) ?? []) == ["reasoning", "choice"])
        #expect(json["properties"]?["reasoning"]?["description"] == "Think first")
    }

    @Test func stringEnumBecomesChoices() throws {
        let (json, _) = try encoded(.object(["mood": .string(enum: ["happy", "angry"])]))
        #expect(json.serialized().contains("happy"))
        #expect(json.serialized().contains("angry"))
    }

    @Test func numericRangesAndArrays() throws {
        let schema = JSONSchema.object([
            "confidence": .integer(minimum: 0, maximum: 100),
            "weight": .number(minimum: 0.5, maximum: 2),
            "targets": .array(of: .string(), minItems: 1, maxItems: 3),
        ])
        let (json, warnings) = try encoded(schema)
        #expect(warnings.isEmpty)
        let text = json.serialized()
        #expect(text.contains("100"))
        #expect(json["properties"]?["targets"]?["minItems"] == 1)
        #expect(json["properties"]?["targets"]?["maxItems"] == 3)
    }

    @Test func unionOfObjects() throws {
        let schema = JSONSchema.object([
            "action": .anyOf([
                .object(["target": .string()], title: "Attack"),
                .object(["item": .string()], title: "UseItem"),
            ]),
        ])
        let (json, _) = try encoded(schema)
        #expect(json.serialized().contains("Attack"))
        #expect(json.serialized().contains("UseItem"))
    }

    @Test func stringLiteralUnionCollapses() throws {
        let schema = try JSONSchema(parsing: #"{"type":"object","properties":{"dir":{"anyOf":[{"const":"north"},{"const":"south"},{"enum":["east","west"]}]}}}"#)
        let (json, _) = try encoded(schema)
        for direction in ["north", "south", "east", "west"] { #expect(json.serialized().contains(direction)) }
    }

    @Test func referencesAndRecursion() throws {
        let schema = try JSONSchema(parsing: """
            {"type":"object","properties":{"root":{"$ref":"#/$defs/Node"}},
             "$defs":{"Node":{"type":"object","properties":{
                "label":{"type":"string"},
                "children":{"type":"array","items":{"$ref":"#/$defs/Node"},"maxItems":3}}}}}
            """)
        let (json, _) = try encoded(schema)
        #expect(json.serialized().contains("Node"))
    }

    @Test func allOfMerges() throws {
        let schema = try JSONSchema(parsing: """
            {"allOf":[{"type":"object","properties":{"a":{"type":"string"}},"required":["a"]},
                      {"type":"object","properties":{"b":{"type":"boolean"}}}]}
            """)
        let (json, _) = try encoded(schema)
        #expect(json["x-order"] == ["a", "b"])
    }

    @Test func unsupportedConstraintsBecomeDescriptionsWithWarnings() throws {
        let schema = try JSONSchema(parsing: #"{"type":"object","properties":{"when":{"type":"string","format":"date-time","description":"Timestamp"}}}"#)
        let (json, warnings) = try encoded(schema)
        #expect(!warnings.isEmpty)
        #expect(json["properties"]?["when"]?["description"]?.stringValue?.contains("date-time") == true)
    }

    @Test func integerEnumDegradesToRange() throws {
        let schema = try JSONSchema(parsing: #"{"type":"object","properties":{"d":{"type":"integer","enum":[4,6,8,20]}}}"#)
        let (_, warnings) = try encoded(schema)
        #expect(warnings.contains { $0.contains("range") })
    }

    @Test func emptyParameters() throws {
        let (json, _) = try encoded(.empty)
        #expect(json["type"] == "object")
    }

    @Test func rejectsRemoteRefs() {
        #expect(throws: SchemaConversionError.self) {
            _ = try SchemaConverter.convert(try JSONSchema(parsing: #"{"$ref":"https://example.com/s.json"}"#), rootName: "X")
        }
    }

    @Test func roundTripsToJSONSchema() throws {
        let generation = try JSONSchema.object(["item": .string(description: "Item name")]).generationSchema(name: "Args")
        let plain = try JSONSchema(generation)
        #expect(plain.json["x-order"] == nil)
        #expect(plain.json["properties"]?["item"]?["type"] == "string")
    }
}
