import Foundation
import OpenAppleModels

// MARK: - Model-facing tools

extension WorldState {
    /// Name of the read tool created by ``tools(readable:writable:maxOutputCharacters:)``.
    public static let readToolName = "read_world_state"
    /// Name of the write tool created by ``tools(readable:writable:maxOutputCharacters:)``.
    public static let updateToolName = "update_world_state"

    /// Tools that let the model read (and optionally change) this world.
    ///
    /// - `read_world_state(path)` returns the JSON at `path`, limited to the
    ///   `readable` prefixes. Reading an ancestor of a readable prefix returns
    ///   only the readable parts. Large values are shortened to a key listing.
    /// - `update_world_state(path, value)` (only when `writable` is non-empty)
    ///   writes a value under one of the `writable` prefixes. The value keeps
    ///   the type already stored at the path (a number stays a number).
    ///
    /// Mistakes (unknown paths, forbidden paths, wrong types) come back to the
    /// model as error outputs that name the valid alternatives, so it can
    /// retry. Keys are matched case-insensitively, and `party[0].name` or
    /// `player/gold` are accepted as well as `party.0.name`.
    ///
    /// - Parameters:
    ///   - readable: Path prefixes the model may read (`""` = everything).
    ///     Pass `[]` to omit the read tool.
    ///   - writable: Path prefixes the model may write. Empty (the default)
    ///     omits the write tool.
    ///   - maxOutputCharacters: Longest JSON returned before a value is shortened.
    public func tools(readable: [String] = [""], writable: [String] = [], maxOutputCharacters: Int = 1500) -> [AgentTool] {
        let readPaths = readable.compactMap { try? WorldPath($0) }
        let writePaths = writable.compactMap { try? WorldPath($0) }
        var tools: [AgentTool] = []
        if !readPaths.isEmpty {
            tools.append(makeReadTool(readable: readPaths, limit: maxOutputCharacters))
        }
        if !writePaths.isEmpty {
            tools.append(makeUpdateTool(writable: writePaths))
        }
        return tools
    }

    private func makeReadTool(readable: [WorldPath], limit: Int) -> AgentTool {
        let everything = readable.contains(where: \.isRoot)
        var description = "Read the current game state (JSON). Use it to check facts before you answer."
        if everything {
            let keys = snapshot().objectValue?.keys ?? []
            if !keys.isEmpty { description += " Top-level keys: \(keys.prefix(12).joined(separator: ", "))." }
        } else {
            description += " Readable paths: \(readable.map(\.description).joined(separator: ", "))."
        }
        let parameters = JSONSchema.object([
            "path": .string(description: "Dot path such as 'player.gold'. Empty string for everything you may read."),
        ])
        // The schema is static and valid; conversion cannot fail.
        return try! AgentTool(name: Self.readToolName, description: description, parameters: parameters) { call in
            let raw = call.arguments["path"]?.stringValue ?? ""
            return self.readForModel(raw, readable: readable, limit: limit)
        }
    }

    private func makeUpdateTool(writable: [WorldPath]) -> AgentTool {
        let description = "Change a value in the game state. Writable paths: \(writable.map { $0.isRoot ? "(everything)" : $0.description }.joined(separator: ", "))."
        let parameters = JSONSchema.object([
            "path": .string(description: "Dot path to change, such as 'quests.lost_ring.status'."),
            "value": .string(description: "The new value, e.g. 42, true, done, or {\"a\": 1}."),
        ])
        return try! AgentTool(name: Self.updateToolName, description: description, parameters: parameters) { call in
            let raw = try call.string("path")
            let value = call.arguments["value"] ?? .null
            return self.writeForModel(raw, value: value, writable: writable)
        }
    }

    func readForModel(_ raw: String, readable: [WorldPath], limit: Int) -> ToolOutput {
        let requested: WorldPath
        do { requested = try WorldPath(raw) } catch { return .error(error.message) }
        let root = snapshot()
        let path = WorldDocument.resolvingCase(requested, in: root)

        if readable.contains(where: { path.isWithin($0) }) {
            guard let value = WorldDocument.value(at: path, in: root) else {
                return .error(Self.missingMessage(path, in: root))
            }
            return .json(Self.shortened(value, limit: limit))
        }
        // An ancestor of readable paths: show only the readable parts.
        let visible = readable.filter { $0.isWithin(path) }
        guard !visible.isEmpty else {
            return .error("You cannot read '\(path)'. Readable paths: \(readable.map(\.description).joined(separator: ", ")).")
        }
        return .json(Self.shortened(WorldDocument.filtered(root, to: visible, below: path), limit: limit))
    }

    func writeForModel(_ raw: String, value: JSONValue, writable: [WorldPath]) -> ToolOutput {
        let requested: WorldPath
        do { requested = try WorldPath(raw) } catch { return .error(error.message) }
        let path = WorldDocument.resolvingCase(requested, in: snapshot())
        guard writable.contains(where: { path.isWithin($0) }) else {
            let allowed = writable.map { $0.isRoot ? "(everything)" : $0.description }.joined(separator: ", ")
            return .error("'\(path)' is read-only. You may change: \(allowed).")
        }
        var result: ToolOutput = .text("")
        do {
            try modify(path.description) { current in
                switch Self.coerce(value, toTypeOf: current) {
                case .success(let coerced):
                    let before = current
                    current = coerced
                    result = .text("Set \(path) to \(coerced.serialized())" + (before.map { " (was \($0.serialized()))." } ?? "."))
                case .failure(let message):
                    result = .error("Cannot set '\(path)': \(message)")
                }
            }
        } catch {
            return .error(ToolOutputText.describe(error))
        }
        return result
    }

    /// Converts a model-supplied value to the type already stored at the path.
    /// The model sends values as strings; `"42"` for a number field becomes `42`.
    static func coerce(_ value: JSONValue, toTypeOf current: JSONValue?) -> CoercionResult {
        guard case .string(let text) = value else { return .success(value) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch current {
        case .string?:
            // Unwrap a JSON string literal the model quoted itself.
            if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\""),
               case .string(let inner)? = try? JSONValue(parsing: trimmed) {
                return .success(.string(inner))
            }
            return .success(.string(text))
        case .number?:
            let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
            guard let number = Double(cleaned), number.isFinite else {
                return .failure("it holds a number; '\(text)' is not a number.")
            }
            return .success(.number(number))
        case .bool?:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .success(.bool(true))
            case "false", "no", "0": return .success(.bool(false))
            default: return .failure("it holds true or false; got '\(text)'.")
            }
        case .array?, .object?:
            guard let parsed = try? JSONValue(parsing: trimmed) else {
                return .failure("it holds \(WorldDocument.typeName(of: current!)); send valid JSON.")
            }
            return .success(parsed)
        case .null?, nil:
            // New value: interpret JSON literals, otherwise keep the text.
            if let parsed = try? JSONValue(parsing: trimmed) { return .success(parsed) }
            return .success(.string(text))
        }
    }

    enum CoercionResult {
        case success(JSONValue)
        case failure(String)
    }

    static func missingMessage(_ path: WorldPath, in root: JSONValue) -> String {
        var ancestor = path
        while let parent = ancestor.parent {
            ancestor = parent
            if let value = WorldDocument.value(at: ancestor, in: root) {
                let name = ancestor.isRoot ? "The state" : "'\(ancestor)'"
                switch value {
                case .object(let object):
                    return "No value at '\(path)'. \(name) has keys: \(object.keys.prefix(20).joined(separator: ", "))."
                case .array(let array):
                    return "No value at '\(path)'. \(name) is a list of \(array.count) items (indices 0...\(max(0, array.count - 1)))."
                default:
                    return "No value at '\(path)'. \(name) is \(WorldDocument.typeName(of: value)): \(value.serialized())."
                }
            }
        }
        return "No value at '\(path)'."
    }

    /// Returns `value`, or a key listing when its JSON exceeds `limit` characters.
    static func shortened(_ value: JSONValue, limit: Int) -> JSONValue {
        guard value.serialized().count > limit else { return value }
        switch value {
        case .object(let object):
            var preview = JSONObject()
            for (key, child) in object {
                switch child {
                case .object(let inner): preview[key] = .string("{object with \(inner.count) keys}")
                case .array(let items): preview[key] = .string("[list of \(items.count) items]")
                case .string(let text) where text.count > 80: preview[key] = .string(String(text.prefix(77)) + "...")
                default: preview[key] = child
                }
            }
            preview["_note"] = "Shortened. Read a narrower path for details."
            return .object(preview)
        case .array(let items):
            var kept: [JSONValue] = []
            var used = 2
            for item in items {
                let size = item.serialized().count + 1
                if used + size > limit { break }
                kept.append(item)
                used += size
            }
            return ["items": .array(kept), "_note": .string("Showing \(kept.count) of \(items.count) items.")]
        case .string(let text):
            return .string(String(text.prefix(limit)) + "...")
        default:
            return value
        }
    }
}

// MARK: - Prompt summaries

extension WorldState {
    /// Renders the values at `paths` as compact `path: value` lines, for
    /// injecting game state directly into a prompt (cheaper than a tool
    /// round-trip for small, always-relevant facts).
    ///
    /// Objects are flattened to their leaves; strings are written without
    /// quotes; lists are written as compact JSON. Missing paths are skipped.
    ///
    /// ```
    /// player.name: Aria
    /// player.gold: 12
    /// time_of_day: night
    /// ```
    public func summary(of paths: [String], maxLines: Int = 30) -> String {
        let root = snapshot()
        var lines: [String] = []
        for raw in paths {
            guard let path = try? WorldPath(raw) else { continue }
            guard let value = WorldDocument.value(at: path, in: root) else { continue }
            Self.flatten(value, path: path.description, into: &lines, depth: 0)
        }
        if lines.count > maxLines {
            let omitted = lines.count - maxLines
            lines = Array(lines.prefix(maxLines)) + ["(\(omitted) more not shown)"]
        }
        return lines.joined(separator: "\n")
    }

    private static func flatten(_ value: JSONValue, path: String, into lines: inout [String], depth: Int) {
        switch value {
        case .object(let object) where depth < 4 && !object.isEmpty:
            for (key, child) in object {
                flatten(child, path: path.isEmpty ? key : "\(path).\(key)", into: &lines, depth: depth + 1)
            }
        case .string(let text):
            lines.append("\(path.isEmpty ? "state" : path): \(text.count > 200 ? String(text.prefix(197)) + "..." : text)")
        default:
            let json = value.serialized()
            lines.append("\(path.isEmpty ? "state" : path): \(json.count > 200 ? String(json.prefix(197)) + "..." : json)")
        }
    }
}

enum ToolOutputText {
    static func describe(_ error: any Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return String(describing: error)
    }
}
