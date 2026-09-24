import Foundation
import OpenAppleModels

/// Typed access to a JSON object's members that reports the failing
/// parameter path (for example `messages[2].content`) in OpenAI errors.
struct JSONParams {
    let object: JSONObject
    let path: String

    init(_ object: JSONObject, path: String = "") {
        self.object = object
        self.path = path
    }

    /// Wraps `value` if it is an object.
    init(_ value: JSONValue, path: String) throws(OpenAIError) {
        guard case .object(let object) = value else {
            throw .invalidRequest("\(path.isEmpty ? "The request body" : "'\(path)'") must be an object.", param: path.isEmpty ? nil : path)
        }
        self.init(object, path: path)
    }

    func param(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }

    /// The raw value; `nil` when absent or JSON `null`.
    func value(_ key: String) -> JSONValue? {
        guard let value = object[key], !value.isNull else { return nil }
        return value
    }

    func has(_ key: String) -> Bool { value(key) != nil }

    func string(_ key: String) throws(OpenAIError) -> String? {
        guard let value = value(key) else { return nil }
        guard let string = value.stringValue else { throw typeError(key, "a string") }
        return string
    }

    func requiredString(_ key: String) throws(OpenAIError) -> String {
        guard let string = try string(key) else { throw missing(key) }
        return string
    }

    func bool(_ key: String) throws(OpenAIError) -> Bool? {
        guard let value = value(key) else { return nil }
        guard let bool = value.boolValue else { throw typeError(key, "a boolean") }
        return bool
    }

    func double(_ key: String) throws(OpenAIError) -> Double? {
        guard let value = value(key) else { return nil }
        guard let number = value.doubleValue else { throw typeError(key, "a number") }
        return number
    }

    func int(_ key: String) throws(OpenAIError) -> Int? {
        guard let value = value(key) else { return nil }
        guard let number = value.intValue else { throw typeError(key, "an integer") }
        return number
    }

    func array(_ key: String) throws(OpenAIError) -> [JSONValue]? {
        guard let value = value(key) else { return nil }
        guard let array = value.arrayValue else { throw typeError(key, "an array") }
        return array
    }

    func object(_ key: String) throws(OpenAIError) -> JSONParams? {
        guard let value = value(key) else { return nil }
        guard case .object(let object) = value else { throw typeError(key, "an object") }
        return JSONParams(object, path: param(key))
    }

    func requiredObject(_ key: String) throws(OpenAIError) -> JSONParams {
        guard let object = try object(key) else { throw missing(key) }
        return object
    }

    func missing(_ key: String) -> OpenAIError {
        .invalidRequest("Missing required parameter: '\(param(key))'.", param: param(key), code: "missing_required_parameter")
    }

    func typeError(_ key: String, _ expected: String) -> OpenAIError {
        .invalidRequest("Invalid type for '\(param(key))': expected \(expected).", param: param(key), code: "invalid_type")
    }

    func invalid(_ key: String, _ message: String) -> OpenAIError {
        .invalidRequest(message, param: param(key), code: "invalid_value")
    }
}
