import Foundation
import OpenAppleModels

/// Typed access to a request's by-name `params` object.
///
/// Every accessor throws ``BridgeError/invalidParams(_:)`` with a message
/// naming the offending parameter, so handlers can simply `try` them.
/// Explicit `null` is treated like an absent parameter.
public struct BridgeParams: Sendable {
    public let object: JSONObject
    /// Prefix used in error messages (e.g. `options.` for nested objects).
    public let path: String

    /// Wraps a `params` member. Absent or `null` params are an empty object;
    /// by-position (array) params are rejected.
    public init(_ value: JSONValue?, path: String = "") throws(BridgeError) {
        switch value {
        case nil, .null?: object = [:]
        case .object(let object)?: self.object = object
        default: throw .invalidParams(path.isEmpty ? "params must be an object." : "'\(path.dropLast())' must be an object.")
        }
        self.path = path
    }

    public init(_ object: JSONObject, path: String = "") {
        self.object = object
        self.path = path
    }

    /// The value for `key`, or `nil` when absent or `null`.
    public subscript(key: String) -> JSONValue? {
        guard let value = object[key], !value.isNull else { return nil }
        return value
    }

    public func contains(_ key: String) -> Bool { self[key] != nil }

    func name(_ key: String) -> String { path + key }

    // MARK: Required

    public func value(_ key: String) throws(BridgeError) -> JSONValue {
        guard let value = self[key] else { throw .invalidParams("Missing required parameter '\(name(key))'.") }
        return value
    }

    public func string(_ key: String) throws(BridgeError) -> String {
        guard let value = try optionalString(key) else { throw .invalidParams("Missing required parameter '\(name(key))'.") }
        return value
    }

    public func int(_ key: String) throws(BridgeError) -> Int {
        guard let value = try optionalInt(key) else { throw .invalidParams("Missing required parameter '\(name(key))'.") }
        return value
    }

    public func nested(_ key: String) throws(BridgeError) -> BridgeParams {
        try BridgeParams(value(key), path: name(key) + ".")
    }

    // MARK: Optional

    public func optionalString(_ key: String) throws(BridgeError) -> String? {
        guard let value = self[key] else { return nil }
        guard let string = value.stringValue else { throw mistyped(key, "a string", value) }
        return string
    }

    public func optionalInt(_ key: String, minimum: Int? = nil) throws(BridgeError) -> Int? {
        guard let value = self[key] else { return nil }
        guard let int = value.intValue else { throw mistyped(key, "an integer", value) }
        if let minimum, int < minimum { throw .invalidParams("Parameter '\(name(key))' must be at least \(minimum).") }
        return int
    }

    public func optionalDouble(_ key: String, minimum: Double? = nil) throws(BridgeError) -> Double? {
        guard let value = self[key] else { return nil }
        guard let double = value.doubleValue else { throw mistyped(key, "a number", value) }
        if let minimum, double < minimum { throw .invalidParams("Parameter '\(name(key))' must be at least \(minimum).") }
        return double
    }

    public func optionalBool(_ key: String) throws(BridgeError) -> Bool? {
        guard let value = self[key] else { return nil }
        guard let bool = value.boolValue else { throw mistyped(key, "a boolean", value) }
        return bool
    }

    public func optionalArray(_ key: String) throws(BridgeError) -> [JSONValue]? {
        guard let value = self[key] else { return nil }
        guard let array = value.arrayValue else { throw mistyped(key, "an array", value) }
        return array
    }

    public func optionalObject(_ key: String) throws(BridgeError) -> JSONObject? {
        guard let value = self[key] else { return nil }
        guard let object = value.objectValue else { throw mistyped(key, "an object", value) }
        return object
    }

    public func optionalNested(_ key: String) throws(BridgeError) -> BridgeParams? {
        guard let object = try optionalObject(key) else { return nil }
        return BridgeParams(object, path: name(key) + ".")
    }

    public func optionalStrings(_ key: String) throws(BridgeError) -> [String]? {
        guard let array = try optionalArray(key) else { return nil }
        var strings: [String] = []
        for (index, element) in array.enumerated() {
            guard let string = element.stringValue else { throw mistyped("\(key)[\(index)]", "a string", element) }
            strings.append(string)
        }
        return strings
    }

    private func mistyped(_ key: String, _ kind: String, _ value: JSONValue) -> BridgeError {
        let shown = value.serialized()
        return .invalidParams("Parameter '\(name(key))' must be \(kind); got \(shown.count > 80 ? shown.prefix(77) + "..." : shown).")
    }
}
