import Foundation
import OpenAppleModels

/// A parsed location inside a ``WorldState`` document.
///
/// Paths are dot-separated keys, with array elements addressed by index:
/// `"player.gold"`, `"npcs.gorm.mood"`, `"party.0.name"`. Bracket indices
/// (`"party[0].name"`) and slash separators (`"player/gold"`) are accepted
/// too, because small models produce them. The empty path (`""`) is the
/// root. Keys that themselves contain `.`, `/` or `[` cannot be addressed by
/// path; use ``WorldState/merge(_:at:)`` or ``WorldState/replace(with:)`` for them.
public struct WorldPath: Sendable, Hashable, CustomStringConvertible {
    /// Keys and indices from the root, e.g. `["party", "0", "name"]`.
    public var segments: [String]

    /// The root of the document.
    public static let root = WorldPath(segments: [])

    public init(segments: [String]) {
        self.segments = segments
    }

    /// Parses a path string.
    public init(_ string: String) throws(WorldStateError) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        // Tolerate JSONPath-ish and pointer-ish prefixes.
        if text == "$" || text == "/" || text == "." { text = "" }
        if text.hasPrefix("$.") { text.removeFirst(2) }
        if text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty else {
            self.segments = []
            return
        }
        // "party[0].name" -> "party.0.name"; "player/gold" -> "player.gold"
        var normalized = ""
        normalized.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "[": normalized.append(".")
            case "]": continue
            case "/": normalized.append(".")
            default: normalized.append(character)
            }
        }
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        // A bracket right after a key ("a[0]") produces "a.0"; a leading
        // bracket ("[0].x") produces an empty first segment, which we drop.
        var segments = parts
        if segments.first == "", string.trimmingCharacters(in: .whitespaces).hasPrefix("[") { segments.removeFirst() }
        guard !segments.contains(where: \.isEmpty) else {
            throw WorldStateError(path: string, message: "'\(string)' is not a valid path. Use dot-separated keys such as 'player.gold'.")
        }
        self.segments = segments
    }

    /// The canonical dot-separated form (`""` for the root).
    public var description: String { segments.joined(separator: ".") }

    public var isRoot: Bool { segments.isEmpty }

    /// Whether `self` equals `other` or lies inside it.
    public func isWithin(_ other: WorldPath) -> Bool {
        segments.starts(with: other.segments)
    }

    /// Whether the two paths are on the same branch (one contains the other).
    public func overlaps(_ other: WorldPath) -> Bool {
        isWithin(other) || other.isWithin(self)
    }

    public var parent: WorldPath? {
        guard !segments.isEmpty else { return nil }
        return WorldPath(segments: Array(segments.dropLast()))
    }

    public func appending(_ segment: String) -> WorldPath {
        WorldPath(segments: segments + [segment])
    }
}

/// An error reading or writing a ``WorldState``.
public struct WorldStateError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The path involved, as given.
    public var path: String
    public var message: String

    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - Document operations

/// Pure operations on JSON documents addressed by ``WorldPath``.
enum WorldDocument {
    static func value(at path: WorldPath, in root: JSONValue) -> JSONValue? {
        var current = root
        for segment in path.segments {
            switch current {
            case .object(let object):
                guard let next = object[segment] else { return nil }
                current = next
            case .array(let array):
                guard let index = Int(segment), array.indices.contains(index) else { return nil }
                current = array[index]
            default:
                return nil
            }
        }
        return current
    }

    /// Returns the path with each key matched case-insensitively against the
    /// document when there is no exact match (small models capitalize keys).
    static func resolvingCase(_ path: WorldPath, in root: JSONValue) -> WorldPath {
        var current = root
        var resolved: [String] = []
        for (offset, segment) in path.segments.enumerated() {
            guard case .object(let object) = current else {
                if case .array(let array) = current, let index = Int(segment), array.indices.contains(index) {
                    current = array[index]
                    resolved.append(segment)
                    continue
                }
                return WorldPath(segments: resolved + path.segments[offset...])
            }
            if let next = object[segment] {
                current = next
                resolved.append(segment)
            } else if let key = object.keys.first(where: { $0.caseInsensitiveCompare(segment) == .orderedSame }) {
                current = object[key]!
                resolved.append(key)
            } else {
                return WorldPath(segments: resolved + path.segments[offset...])
            }
        }
        return WorldPath(segments: resolved)
    }

    /// Writes `value` at `segments`, creating intermediate objects.
    static func setting(
        _ value: JSONValue,
        at segments: ArraySlice<String>,
        in container: JSONValue?,
        path: WorldPath
    ) throws(WorldStateError) -> JSONValue {
        guard let key = segments.first else { return value }
        let rest = segments.dropFirst()
        switch container {
        case nil, .null?:
            var object = JSONObject()
            object[key] = try setting(value, at: rest, in: nil, path: path)
            return .object(object)
        case .object(var object)?:
            object[key] = try setting(value, at: rest, in: object[key], path: path)
            return .object(object)
        case .array(var array)?:
            let prefix = WorldPath(segments: Array(path.segments.prefix(path.segments.count - segments.count)))
            guard let index = Int(key), index >= 0, index <= array.count else {
                throw WorldStateError(
                    path: path.description,
                    message: "'\(prefix)' is a list of \(array.count) items; '\(key)' is not a valid index (use 0...\(array.count), where \(array.count) appends).")
            }
            if index == array.count {
                array.append(try setting(value, at: rest, in: nil, path: path))
            } else {
                array[index] = try setting(value, at: rest, in: array[index], path: path)
            }
            return .array(array)
        case let scalar?:
            let prefix = WorldPath(segments: Array(path.segments.prefix(path.segments.count - segments.count)))
            throw WorldStateError(
                path: path.description,
                message: "Cannot write '\(path)': '\(prefix)' is \(typeName(of: scalar)), not an object or list.")
        }
    }

    /// Removes the value at `segments`. Returns the new container and the removed value.
    static func removing(
        at segments: ArraySlice<String>,
        in container: JSONValue
    ) -> (JSONValue, removed: JSONValue?) {
        guard let key = segments.first else { return (container, nil) }
        let rest = segments.dropFirst()
        switch container {
        case .object(var object):
            guard let child = object[key] else { return (container, nil) }
            if rest.isEmpty {
                object[key] = nil
                return (.object(object), child)
            }
            let (updated, removed) = removing(at: rest, in: child)
            object[key] = updated
            return (.object(object), removed)
        case .array(var array):
            guard let index = Int(key), array.indices.contains(index) else { return (container, nil) }
            if rest.isEmpty {
                let removed = array.remove(at: index)
                return (.array(array), removed)
            }
            let (updated, removed) = removing(at: rest, in: array[index])
            array[index] = updated
            return (.array(array), removed)
        default:
            return (container, nil)
        }
    }

    /// Applies an RFC 7386 JSON Merge Patch, recording leaf-level changes.
    static func merging(
        _ patch: JSONValue,
        into target: JSONValue?,
        path: WorldPath,
        changes: inout [WorldStateChange],
        depth: Int = 0
    ) -> JSONValue {
        guard case .object(let patchObject) = patch, depth < 64 else {
            if target != patch { changes.append(WorldStateChange(path: path.description, oldValue: target, newValue: patch)) }
            return patch
        }
        guard case .object(var object)? = target else {
            // Replacing a non-object: report one change for the whole subtree.
            var ignored: [WorldStateChange] = []
            let merged = merging(patch, into: .object(JSONObject()), path: path, changes: &ignored, depth: depth + 1)
            changes.append(WorldStateChange(path: path.description, oldValue: target, newValue: merged))
            return merged
        }
        for (key, value) in patchObject {
            let childPath = path.appending(key)
            if value.isNull {
                if let old = object[key] {
                    object[key] = nil
                    changes.append(WorldStateChange(path: childPath.description, oldValue: old, newValue: nil))
                }
            } else {
                object[key] = merging(value, into: object[key], path: childPath, changes: &changes, depth: depth + 1)
            }
        }
        return .object(object)
    }

    /// A copy of `root` containing only the subtrees under `paths`.
    static func filtered(_ root: JSONValue, to paths: [WorldPath], below base: WorldPath) -> JSONValue {
        var result = JSONValue.object(JSONObject())
        for path in paths where path.isWithin(base) {
            guard let value = value(at: path, in: root) else { continue }
            let relative = WorldPath(segments: Array(path.segments.dropFirst(base.segments.count)))
            if relative.isRoot { return value }
            if let updated = try? setting(value, at: relative.segments[...], in: result, path: relative) {
                result = updated
            }
        }
        return result
    }

    static func typeName(of value: JSONValue) -> String {
        switch value {
        case .null: "null"
        case .bool: "a boolean"
        case .number: "a number"
        case .string: "a string"
        case .array: "a list"
        case .object: "an object"
        }
    }
}
