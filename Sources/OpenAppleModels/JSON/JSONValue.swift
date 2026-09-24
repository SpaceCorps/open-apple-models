import Foundation

/// A JSON value that preserves object key order.
///
/// Key order matters when talking to a language model: the model generates
/// structured output property-by-property in schema order, so a `reasoning`
/// field placed before a `choice` field acts as a small chain of thought.
/// Foundation's `JSONSerialization` and `JSONDecoder` discard that order,
/// so this package ships its own parser and serializer.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

// MARK: - Ordered object

/// An insertion-ordered JSON object.
public struct JSONObject: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    public init(_ pairs: [(String, JSONValue)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public var pairs: [(key: String, value: JSONValue)] {
        keys.map { ($0, storage[$0]!) }
    }

    public func makeIterator() -> IndexingIterator<[(key: String, value: JSONValue)]> {
        pairs.makeIterator()
    }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        // Objects compare by content; key order is presentation, not identity.
        lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements)) }
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool { if case .null = self { true } else { false } }

    public var boolValue: Bool? { if case .bool(let v) = self { v } else { nil } }

    public var doubleValue: Double? { if case .number(let v) = self { v } else { nil } }

    /// The number as an `Int`, if it is integral and in range.
    public var intValue: Int? {
        guard case .number(let v) = self, v.rounded() == v, abs(v) < 9.007_199_254_740_992e15 else { return nil }
        return Int(v)
    }

    public var stringValue: String? { if case .string(let v) = self { v } else { nil } }

    public var arrayValue: [JSONValue]? { if case .array(let v) = self { v } else { nil } }

    public var objectValue: JSONObject? { if case .object(let v) = self { v } else { nil } }

    /// Object member lookup; `nil` for non-objects and missing keys.
    public subscript(key: String) -> JSONValue? {
        get { objectValue?[key] }
        set {
            guard case .object(var object) = self else { return }
            object[key] = newValue
            self = .object(object)
        }
    }

    /// Array element lookup; `nil` for non-arrays and out-of-range indices.
    public subscript(index: Int) -> JSONValue? {
        guard case .array(let array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Parsing

extension JSONValue {
    /// Parses JSON text, preserving object key order.
    public init(parsing text: String) throws(JSONParseError) {
        var parser = JSONParser(bytes: Array(text.utf8))
        self = try parser.parseDocument()
    }

    /// Parses JSON bytes, preserving object key order.
    public init(parsing data: Data) throws(JSONParseError) {
        var parser = JSONParser(bytes: Array(data))
        self = try parser.parseDocument()
    }
}

public struct JSONParseError: LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public var message: String
    public var offset: Int

    public var description: String { "Invalid JSON at byte \(offset): \(message)" }
    public var errorDescription: String? { description }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0
    static let maxDepth = 100

    init(bytes: [UInt8]) { self.bytes = bytes }

    mutating func parseDocument() throws(JSONParseError) -> JSONValue {
        // Tolerate a UTF-8 byte order mark.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { index = 3 }
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw error("Unexpected trailing characters") }
        return value
    }

    func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func parseValue() throws(JSONParseError) -> JSONValue {
        guard index < bytes.count else { throw error("Unexpected end of input") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("Unexpected character '\(Character(UnicodeScalar(bytes[index])))'")
        }
    }

    mutating func expectLiteral(_ literal: String) throws(JSONParseError) {
        let utf8 = Array(literal.utf8)
        guard index + utf8.count <= bytes.count, bytes[index..<index + utf8.count].elementsEqual(utf8) else {
            throw error("Invalid literal")
        }
        index += utf8.count
    }

    mutating func enter() throws(JSONParseError) {
        depth += 1
        if depth > Self.maxDepth { throw error("Nesting deeper than \(Self.maxDepth) levels") }
    }

    mutating func parseObject() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var object = JSONObject()
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("Expected object key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("Expected ':'") }
            index += 1
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated object") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(object) }
            throw error("Expected ',' or '}'")
        }
    }

    mutating func parseArray() throws(JSONParseError) -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("Unterminated array") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(array) }
            throw error("Expected ',' or ']'")
        }
    }

    mutating func parseString() throws(JSONParseError) -> String {
        index += 1  // opening quote
        var buffer: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard index < bytes.count else { throw error("Unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(0x22)
                case UInt8(ascii: "\\"): buffer.append(0x5C)
                case UInt8(ascii: "/"): buffer.append(0x2F)
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        // High surrogate: must be followed by \uDC00-DFFF.
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else {
                            throw error("Unpaired surrogate")
                        }
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("Invalid low surrogate") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw error("Unpaired surrogate")
                    }
                    guard let unicode = Unicode.Scalar(scalar) else { throw error("Invalid unicode scalar") }
                    buffer.append(contentsOf: Array(String(Character(unicode)).utf8))
                default:
                    throw error("Invalid escape character")
                }
            case 0x00...0x1F:
                throw error("Unescaped control character in string")
            default:
                buffer.append(byte)
                index += 1
            }
        }
        throw error("Unterminated string")
    }

    mutating func parseHex4() throws(JSONParseError) -> UInt32 {
        guard index + 4 <= bytes.count else { throw error("Truncated \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw error("Invalid hex digit in \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    mutating func parseNumber() throws(JSONParseError) -> JSONValue {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count else { throw error("Truncated number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
        } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(bytes[index]) {
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
        } else {
            throw error("Invalid number")
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            let fractionStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > fractionStart else { throw error("Invalid fraction") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            let exponentStart = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
            guard index > exponentStart else { throw error("Invalid exponent") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(text) else { throw error("Invalid number") }
        return .number(value)
    }
}

// MARK: - Serialization

extension JSONValue {
    public struct SerializationOptions: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let prettyPrinted = SerializationOptions(rawValue: 1 << 0)
        public static let sortedKeys = SerializationOptions(rawValue: 1 << 1)
    }

    /// Serializes to JSON text. Integral numbers are written without a fraction.
    public func serialized(_ options: SerializationOptions = []) -> String {
        var output = ""
        write(to: &output, options: options, indent: 0)
        return output
    }

    /// Compact JSON text.
    public var jsonString: String { serialized() }

    private func write(to output: inout String, options: SerializationOptions, indent: Int) {
        let pretty = options.contains(.prettyPrinted)
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let value): output += Self.format(number: value)
        case .string(let value): Self.writeEscaped(value, to: &output)
        case .array(let values):
            if values.isEmpty { output += "[]"; return }
            output += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                value.write(to: &output, options: options, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "]"
        case .object(let object):
            if object.isEmpty { output += "{}"; return }
            output += "{"
            let keys = options.contains(.sortedKeys) ? object.keys.sorted() : object.keys
            for (offset, key) in keys.enumerated() {
                if offset > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
                Self.writeEscaped(key, to: &output)
                output += pretty ? ": " : ":"
                object[key]!.write(to: &output, options: options, indent: indent + 1)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: indent) }
            output += "}"
        }
    }

    static func format(number: Double) -> String {
        guard number.isFinite else { return "null" }
        // Integral values print as integers (exact up to 2^53, and as the
        // exact double value beyond that) instead of exponent notation.
        if number.rounded() == number, abs(number) < 9.2e18 {
            return String(Int64(number))
        }
        return "\(number)"
    }

    static func writeEscaped(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case "\u{2028}": output += "\\u2028"
            case "\u{2029}": output += "\\u2029"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String { serialized() }
}

// MARK: - Codable

extension JSONValue: Codable {
    /// Decoding through `Decoder` cannot guarantee key order; prefer
    /// ``init(parsing:)`` when order matters (schemas, structured output).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(JSONObject(value.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        if case .object(let object) = self {
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in object { try keyed.encode(value, forKey: DynamicKey(key)) }
            return
        }
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if let int = intValue { try container.encode(int) } else { try container.encode(value) }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object: break
        }
    }

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Bridging from Foundation / Encodable

extension JSONValue {
    /// Converts any `Encodable` value into a `JSONValue`.
    public init(encoding value: some Encodable, encoder: JSONEncoder = JSONEncoder()) throws {
        let data = try encoder.encode(value)
        self = try JSONValue(parsing: data)
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        try decoder.decode(type, from: Data(serialized().utf8))
    }
}
