import Foundation

/// Which channel tab a bulk listing reads.
///
/// `browseParams` are the stable base64 protobuf blobs YouTube's own web
/// client sends for the tab links; the tab a response actually selected is
/// verified against `pathSlug` (see `ChannelBrowseParser.selectedTabSlug`)
/// because YouTube silently falls back to Home for a tab a channel lacks.
public enum ChannelTab: String, Sendable, CaseIterable {
    case videos
    case shorts
    case streams

    public var browseParams: String {
        switch self {
        case .videos: "EgZ2aWRlb3PyBgQKAjoA"
        case .shorts: "EgZzaG9ydHPyBgUKA5oBAA=="
        case .streams: "EgdzdHJlYW1z8gYECgJ6AA=="
        }
    }

    /// Trailing path segment YouTube echoes back for the selected tab.
    public var pathSlug: String {
        rawValue
    }
}

/// A channel the bulk exporter can list, before it is resolved to a browse id.
public struct YouTubeChannelReference: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Canonical `UC…` channel id — usable with `browse` directly.
        case browseID(String)
        /// Handle / legacy vanity URL — needs a `navigation/resolve_url` round trip.
        case vanityURL(String)
    }

    public let target: Target
    /// Tab named by the URL path (`/@handle/streams`), if any.
    public let tab: ChannelTab?
    /// Human-readable label used in logs before the real channel title is known.
    public let label: String

    public init(target: Target, tab: ChannelTab?, label: String) {
        self.target = target
        self.tab = tab
        self.label = label
    }
}

public enum YouTubeChannelURLError: LocalizedError, Equatable {
    case unsupportedURL

    public var errorDescription: String? {
        """
        Unsupported YouTube channel URL. Expected youtube.com/@handle, \
        youtube.com/channel/UC…, youtube.com/c/Name, youtube.com/user/Name \
        (optionally with /videos, /shorts or /streams) or a bare @handle.
        """
    }
}

/// Channel-URL parsing, the counterpart of `YouTubeURL` for whole channels.
public enum YouTubeChannelURL {
    private nonisolated(unsafe) static let channelIDPattern = /UC[A-Za-z0-9_-]{22}/
    private nonisolated(unsafe) static let handlePattern = /@[^\/\s]+/

    private static let hosts: Set<String> = ["youtube.com", "m.youtube.com"]
    private static let vanityPrefixes: Set<String> = ["c", "user"]

    /// `true` when the input looks like a channel rather than a single video.
    public static func isChannelInput(_ value: String) -> Bool {
        (try? parse(value)) != nil
    }

    /// Accepts `@handle`, a `UC…` channel id, or any of the channel URL shapes
    /// (with or without a scheme), optionally suffixed with a tab segment.
    public static func parse(_ value: String) throws -> YouTubeChannelReference {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw YouTubeChannelURLError.unsupportedURL
        }

        if candidate.wholeMatch(of: channelIDPattern) != nil {
            return YouTubeChannelReference(target: .browseID(candidate), tab: nil, label: candidate)
        }
        if candidate.wholeMatch(of: handlePattern) != nil {
            return YouTubeChannelReference(
                target: .vanityURL("https://www.youtube.com/\(candidate)"),
                tab: nil,
                label: candidate
            )
        }

        if !candidate.contains("://") {
            let lowered = candidate.lowercased()
            if lowered.hasPrefix("youtube.com") || lowered.hasPrefix("www.youtube.com")
                || lowered.hasPrefix("m.youtube.com")
            {
                candidate = "https://" + candidate
            }
        }
        guard let components = URLComponents(string: candidate) else {
            throw YouTubeChannelURLError.unsupportedURL
        }
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        guard hosts.contains(host) else {
            throw YouTubeChannelURLError.unsupportedURL
        }

        let path = components.percentEncodedPath.removingPercentEncoding ?? components.path
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first else {
            throw YouTubeChannelURLError.unsupportedURL
        }

        func tab(after index: Int) -> ChannelTab? {
            guard parts.count > index else { return nil }
            return ChannelTab(rawValue: parts[index].lowercased())
        }

        if first == "channel" {
            guard parts.count >= 2, parts[1].wholeMatch(of: channelIDPattern) != nil else {
                throw YouTubeChannelURLError.unsupportedURL
            }
            return YouTubeChannelReference(target: .browseID(parts[1]), tab: tab(after: 2), label: parts[1])
        }
        if first.hasPrefix("@"), first.count > 1 {
            return YouTubeChannelReference(
                target: .vanityURL("https://www.youtube.com/\(first)"),
                tab: tab(after: 1),
                label: first
            )
        }
        if vanityPrefixes.contains(first), parts.count >= 2 {
            return YouTubeChannelReference(
                target: .vanityURL("https://www.youtube.com/\(first)/\(parts[1])"),
                tab: tab(after: 2),
                label: parts[1]
            )
        }
        throw YouTubeChannelURLError.unsupportedURL
    }
}
