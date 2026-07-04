import Foundation

/// `config.env`-style parsing helpers.
public enum EnvFile {
    private static let trueValues: Set<String> = ["1", "true", "yes", "on"]
    private static let falseValues: Set<String> = ["0", "false", "no", "off"]

    public static func parseBool(_ value: String?, default defaultValue: Bool = false) -> Bool {
        guard let value else { return defaultValue }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trueValues.contains(normalized) { return true }
        if falseValues.contains(normalized) { return false }
        return defaultValue
    }

    public enum ParseError: LocalizedError, Equatable {
        case missingEquals(line: Int, path: String)
        case invalidKey(key: String, line: Int, path: String)

        public var errorDescription: String? {
            switch self {
            case let .missingEquals(line, path):
                "Invalid config line \(line) in \(path): missing '='"
            case let .invalidKey(key, line, path):
                "Invalid config key '\(key)' in \(path):\(line)"
            }
        }
    }

    /// Parse a `KEY=value` env file; `#` comments and blank lines are skipped,
    /// values may be single- or double-quoted, and an `export ` prefix inside
    /// the value is dropped.
    public static func parse(at url: URL) throws -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        return try parse(text: text, path: url.path)
    }

    public static func parse(text: String, path: String = "<memory>") throws -> [String: String] {
        var config: [String: String] = [:]
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw ParseError.missingEquals(line: lineNumber, path: path)
            }
            let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                throw ParseError.invalidKey(key: key, line: lineNumber, path: path)
            }
            config[key] = unquote(value)
        }
        return config
    }

    static func unquote(_ value: String) -> String {
        var value = value
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        if value.hasPrefix("export ") {
            value = String(value.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
