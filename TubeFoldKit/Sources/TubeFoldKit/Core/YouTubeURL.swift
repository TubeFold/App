import Foundation

/// Errors thrown while extracting a video id from user input.
public enum YouTubeURLError: LocalizedError, Equatable {
    case unsupportedURL

    public var errorDescription: String? {
        """
        Unsupported YouTube URL. Expected youtube.com/watch?v=..., youtu.be/..., \
        youtube.com/embed/..., youtube.com/shorts/... or a plain video ID.
        """
    }
}

/// URL/video-id parsing helpers.
public enum YouTubeURL {
    nonisolated(unsafe) private static let videoIDPattern = /[A-Za-z0-9_-]{11}/

    private static let bareHostPrefixes = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"]
    private static let watchHosts: Set<String> = ["youtube.com", "m.youtube.com"]
    private static let pathPrefixes: Set<String> = ["embed", "shorts", "live"]

    /// Accepts a watch/short/embed/shorts/live URL (with or without a scheme)
    /// or a bare 11-character video id.
    public static func parseVideoID(_ value: String) throws -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.wholeMatch(of: videoIDPattern) != nil {
            return candidate
        }

        if !candidate.contains("://") {
            let lowered = candidate.lowercased()
            if bareHostPrefixes.contains(where: { lowered.hasPrefix($0) }) {
                candidate = "https://" + candidate
            }
        }

        guard let components = URLComponents(string: candidate) else {
            throw YouTubeURLError.unsupportedURL
        }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path

        var videoID = ""
        if host == "youtu.be" {
            videoID = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                .first.map(String.init) ?? ""
        } else if watchHosts.contains(host), path == "/watch" {
            videoID = components.queryItems?.first(where: { $0.name == "v" })?.value ?? ""
        } else if watchHosts.contains(host) {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 2, pathPrefixes.contains(parts[0]) {
                videoID = parts[1]
            }
        }

        videoID = String(videoID.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
        videoID = String(videoID.split(separator: "&", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !videoID.isEmpty, videoID.wholeMatch(of: videoIDPattern) != nil else {
            throw YouTubeURLError.unsupportedURL
        }
        return videoID
    }

    /// Canonical `https://www.youtube.com/watch?v=<id>` form.
    public static func normalize(_ url: String) throws -> String {
        let videoID = try parseVideoID(url)
        return "https://www.youtube.com/watch?v=\(videoID)"
    }

    /// Deterministic thumbnail URL derived from a YouTube video id.
    ///
    /// Manually-added videos arrive as a bare URL with no thumbnail; the id
    /// alone is enough to build a working cover image without a network call.
    public static func thumbnailURL(videoID: String) -> String {
        let trimmed = videoID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "https://i.ytimg.com/vi/\(trimmed)/hqdefault.jpg"
    }
}
