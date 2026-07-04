import Foundation

/// Output-language setting normalization.
public enum OutputLanguage {
    public static let defaultLanguage = "English"
    public static let maxLength = 60

    /// Clean a user-provided output-language label.
    ///
    /// Collapses whitespace/newlines, trims, caps the length, and falls back
    /// to the default when empty. The value is inserted verbatim into the
    /// prompt, so keep it to a short single line.
    public static func normalize(_ value: String?) -> String {
        guard let value else { return defaultLanguage }
        var cleaned = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if cleaned.isEmpty {
            return defaultLanguage
        }
        if cleaned.count > maxLength {
            cleaned = String(cleaned.prefix(maxLength)).trimmingTrailing(charactersIn: " \t\n\r")
        }
        return cleaned
    }
}
