import Foundation

/// Filename sanitization helpers.
public enum Filenames {
    public static let untitledFallback = "Untitled YouTube Video"

    /// Sanitize a video title into a macOS-safe filename stem.
    public static func safeFilename(_ title: String, maxLength: Int = 120) -> String {
        var value = title.precomposedStringWithCanonicalMapping
        value = String(String.UnicodeScalarView(value.unicodeScalars.filter { !$0.isOtherCategory }))
        value = value.replacing(/[\/\\:]+/, with: " - ")
        value = value.replacing(/[<>|"*?]+/, with: "")
        value = value.replacing(/\s+/, with: " ")
        value = value.trimming(charactersIn: " .")
        if value.isEmpty || value == "." || value == ".." {
            value = untitledFallback
        }
        if value.unicodeScalars.count > maxLength {
            value = String(String.UnicodeScalarView(value.unicodeScalars.prefix(maxLength)))
            value = value.trimmingTrailing(charactersIn: " .")
        }
        return value.isEmpty ? untitledFallback : value
    }

    /// `[TubeFold] <title>.<ext>` name used for per-video artifact copies.
    public static func artifactFilename(title: String, fileExtension: String) -> String {
        var sanitized = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.isEmpty {
            sanitized = "YouTube video"
        }
        sanitized = sanitized
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
        let base = "[TubeFold] \(sanitized)"
        return "\(String(base.unicodeScalars.prefix(200).map(Character.init))).\(fileExtension)"
    }

    /// First free `<title>.md` path in `outputDir`; collisions get " (2)", " (3)", …
    public static func uniqueMarkdownPath(outputDir: URL, title: String) throws -> URL {
        let base = safeFilename(title)
        let fileManager = FileManager.default
        var candidate = outputDir.appendingPathComponent("\(base).md")
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        for index in 2 ..< 1000 {
            candidate = outputDir.appendingPathComponent("\(base) (\(index)).md")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw TubeFoldError.noFreeFilename(base)
    }
}

public enum TubeFoldError: LocalizedError, Equatable {
    case noFreeFilename(String)
    case emptyProviderOutput
    case providerOutputTooShort

    public var errorDescription: String? {
        switch self {
        case let .noFreeFilename(base):
            "Unable to find a free filename for '\(base)'"
        case .emptyProviderOutput:
            "Provider output is empty"
        case .providerOutputTooShort:
            "Provider output is too short to be a useful summary"
        }
    }
}

extension Unicode.Scalar {
    /// True for the Unicode "Other" (C*) general categories
    /// (control/format/surrogate/private-use/unassigned).
    var isOtherCategory: Bool {
        switch properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned:
            true
        default:
            false
        }
    }
}

extension String {
    /// Trims the given characters from both ends.
    func trimming(charactersIn characters: String) -> String {
        trimmingCharacters(in: CharacterSet(charactersIn: characters))
    }

    /// Trims the given characters from the end only.
    func trimmingTrailing(charactersIn characters: String) -> String {
        let set = CharacterSet(charactersIn: characters)
        var scalars = Array(unicodeScalars)
        while let last = scalars.last, set.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
