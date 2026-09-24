import Foundation

/// An ordered list of HTTP header fields with case-insensitive lookup.
///
/// Field names keep the spelling they were added with (for faithful
/// serialization) but compare case-insensitively, as HTTP requires.
public struct HTTPHeaders: Sendable, Hashable, Sequence, ExpressibleByDictionaryLiteral {
    public typealias Element = (name: String, value: String)

    private var fields: [Field] = []

    private struct Field: Sendable, Hashable {
        var name: String
        var value: String
        var key: String  // lowercased name
    }

    /// Creates empty headers.
    public init() {}

    /// Creates headers from name–value pairs, in order.
    public init(_ fields: [(String, String)]) {
        for (name, value) in fields { add(name: name, value: value) }
    }

    public init(dictionaryLiteral elements: (String, String)...) {
        self.init(elements)
    }

    /// The first value for `name`, or `nil`. Setting replaces all values for
    /// `name` (or removes them when set to `nil`).
    public subscript(name: String) -> String? {
        get {
            let key = name.lowercased()
            return fields.first { $0.key == key }?.value
        }
        set {
            let key = name.lowercased()
            if let newValue {
                if let index = fields.firstIndex(where: { $0.key == key }) {
                    fields[index].value = newValue
                    fields[index].name = name
                    var seen = false
                    fields.removeAll { field in
                        guard field.key == key else { return false }
                        defer { seen = true }
                        return seen
                    }
                } else {
                    fields.append(Field(name: name, value: newValue, key: key))
                }
            } else {
                fields.removeAll { $0.key == key }
            }
        }
    }

    /// All values for `name`, in order.
    public func values(for name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.key == key }.map(\.value)
    }

    /// Appends a field, keeping any existing fields with the same name.
    public mutating func add(name: String, value: String) {
        fields.append(Field(name: name, value: value, key: name.lowercased()))
    }

    /// Whether a field named `name` is present.
    public func contains(_ name: String) -> Bool { self[name] != nil }

    /// Whether a comma-separated header (such as `Connection`) contains `token`,
    /// compared case-insensitively.
    public func containsToken(_ token: String, in name: String) -> Bool {
        let wanted = token.lowercased()
        return values(for: name).contains { value in
            value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == wanted }
        }
    }

    /// Number of fields (repeated names count separately).
    public var count: Int { fields.count }

    public func makeIterator() -> AnyIterator<Element> {
        var iterator = fields.makeIterator()
        return AnyIterator { iterator.next().map { ($0.name, $0.value) } }
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.fields.map { [$0.key, $0.value] } == rhs.fields.map { [$0.key, $0.value] }
    }

    public func hash(into hasher: inout Hasher) {
        for field in fields {
            hasher.combine(field.key)
            hasher.combine(field.value)
        }
    }
}
