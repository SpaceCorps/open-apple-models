import Foundation
import FoundationModels
import OpenAppleModels
import Testing

@Suite struct JSONValueTests {
    @Test func parsesAndPreservesKeyOrder() throws {
        let value = try JSONValue(parsing: #"{"zeta": 1, "alpha": [true, null, "x"], "mid": {"b": 2.5, "a": -3e2}}"#)
        #expect(value.objectValue?.keys == ["zeta", "alpha", "mid"])
        #expect(value["mid"]?.objectValue?.keys == ["b", "a"])
        #expect(value["alpha"]?[0] == true)
        #expect(value["alpha"]?[1] == .null)
        #expect(value["mid"]?["a"]?.doubleValue == -300)
        #expect(value.serialized() == #"{"zeta":1,"alpha":[true,null,"x"],"mid":{"b":2.5,"a":-300}}"#)
    }

    @Test func roundTripsEscapesAndUnicode() throws {
        let text = #"{"s":"line\nbreak \"quoted\" tab\t slash\/ \u00e9 \ud83d\ude00 \u0001"}"#
        let value = try JSONValue(parsing: text)
        #expect(value["s"]?.stringValue == "line\nbreak \"quoted\" tab\t slash/ é 😀 \u{01}")
        let reparsed = try JSONValue(parsing: value.serialized())
        #expect(reparsed == value)
    }

    @Test(arguments: [
        "", "{", "[1,]", "{\"a\" 1}", "tru", "01", "1.", "-", "\"unterminated", "{\"a\":1}x",
        "\"\\ud83d\"", "\"bad \\q escape\"", "[\"\u{01}\"]",
    ])
    func rejectsMalformedJSON(_ text: String) {
        #expect(throws: JSONParseError.self) { _ = try JSONValue(parsing: text) }
    }

    @Test func rejectsExcessiveNesting() {
        let deep = String(repeating: "[", count: 150) + String(repeating: "]", count: 150)
        #expect(throws: JSONParseError.self) { _ = try JSONValue(parsing: deep) }
    }

    @Test func numbersFormatIntegrally() {
        #expect(JSONValue.number(42).serialized() == "42")
        #expect(JSONValue.number(-0.5).serialized() == "-0.5")
        #expect(JSONValue.number(.infinity).serialized() == "null")
        #expect(JSONValue.number(3).intValue == 3)
        #expect(JSONValue.number(3.2).intValue == nil)
    }

    @Test func prettyAndSortedOutput() throws {
        let value: JSONValue = ["b": 1, "a": ["x": [1, 2]]]
        #expect(value.serialized([.sortedKeys]) == #"{"a":{"x":[1,2]},"b":1}"#)
        #expect(value.serialized([.prettyPrinted]).contains("\n  \"b\": 1"))
    }

    @Test func objectMutationKeepsOrder() {
        var object: JSONObject = ["a": 1, "b": 2]
        object["c"] = 3
        object["a"] = 10
        object["b"] = nil
        #expect(object.keys == ["a", "c"])
        #expect(object["a"] == 10)
    }

    @Test func codableBridging() throws {
        struct Item: Codable, Equatable { var name: String; var count: Int }
        let json = try JSONValue(encoding: Item(name: "sword", count: 2))
        #expect(json["name"] == "sword")
        #expect(try json.decode(Item.self) == Item(name: "sword", count: 2))
        let original: JSONValue = ["k": [1, "two", nil]]
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(JSONValue.self, from: data) == original)
    }

    @Test func generatedContentRoundTrip() throws {
        let value: JSONValue = ["name": "Gorm", "stats": ["hp": 12, "tags": ["grumpy", "smith"]], "alive": true, "pet": nil]
        let content = value.generatedContent
        #expect(JSONValue(content) == value)
        #expect(JSONValue(content).objectValue?.keys == ["name", "stats", "alive", "pet"])
    }
}
