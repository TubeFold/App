import Foundation

// MARK: - Public pipeline-facing models

/// Video metadata in the shape the pipeline's front matter needs — the Swift
/// replacement for the yt-dlp "compact metadata" dict.
public struct VideoMetadata: Sendable, Equatable {
    public let videoID: String
    public let title: String
    public let channel: String
    public let durationSeconds: Int?
    /// `yyyy-MM-dd` publish date, or `""` when unknown.
    public let publishedAt: String
    /// Canonical `https://www.youtube.com/watch?v=<id>` URL.
    public let url: String

    public init(
        videoID: String,
        title: String,
        channel: String,
        durationSeconds: Int?,
        publishedAt: String,
        url: String
    ) {
        self.videoID = videoID
        self.title = title
        self.channel = channel
        self.durationSeconds = durationSeconds
        self.publishedAt = publishedAt
        self.url = url
    }

    /// Video-id-only stub used when metadata can't be fetched — metadata is
    /// best-effort, never fatal.
    public static func stub(videoID: String, url: String) -> VideoMetadata {
        VideoMetadata(videoID: videoID, title: videoID, channel: "", durationSeconds: nil, publishedAt: "", url: url)
    }
}

/// One caption track from the player response.
public struct CaptionTrack: Sendable, Equatable {
    public let baseURL: String
    public let languageCode: String
    /// Human-readable language name (e.g. "English (auto-generated)").
    public let languageName: String
    /// `true` for YouTube's auto-generated ("asr") track.
    public let isGenerated: Bool

    public init(baseURL: String, languageCode: String, languageName: String, isGenerated: Bool) {
        self.baseURL = baseURL
        self.languageCode = languageCode
        self.languageName = languageName
        self.isGenerated = isGenerated
    }
}

/// Final transcript result.
public struct TranscriptResult: Sendable, Equatable {
    public let text: String
    public let language: String
    public let languageCode: String
    public let isGenerated: Bool

    public init(text: String, language: String, languageCode: String, isGenerated: Bool) {
        self.text = text
        self.language = language
        self.languageCode = languageCode
        self.isGenerated = isGenerated
    }
}

public enum InnerTubeError: Error, Equatable {
    case invalidVideoID(String)
    case httpStatus(Int, client: String)
    case malformedResponse(client: String)
    case unplayable(status: String, reason: String?)
    case transcriptsDisabled
    case noTranscript
    case originalLanguageUnknown
    case emptyTranscript

    public var userMessage: String {
        switch self {
        case .invalidVideoID: "Unsupported YouTube URL or video id."
        case .httpStatus, .malformedResponse: "Could not reach YouTube."
        case let .unplayable(_, reason): reason ?? "Video is unavailable"
        case .transcriptsDisabled: "Transcripts are disabled for this video"
        case .noTranscript: "No transcript found for this video"
        case .originalLanguageUnknown: "Could not determine the video's original transcript language"
        case .emptyTranscript: "Transcript is empty"
        }
    }
}

// MARK: - Wire format (the `youtubei/v1/player` response subset we read)

struct PlayerResponse: Decodable {
    struct PlayabilityStatus: Decodable {
        let status: String?
        let reason: String?
    }

    struct VideoDetails: Decodable {
        let videoId: String?
        let title: String?
        let author: String?
        let lengthSeconds: String?
    }

    struct Microformat: Decodable {
        let playerMicroformatRenderer: MicroformatRenderer?
    }

    struct MicroformatRenderer: Decodable {
        let publishDate: String?
        let uploadDate: String?
    }

    struct Captions: Decodable {
        let playerCaptionsTracklistRenderer: TracklistRenderer?
    }

    struct TracklistRenderer: Decodable {
        let captionTracks: [WireCaptionTrack]?
    }

    /// Track name arrives as `{"simpleText": ...}` from web-style clients and
    /// as `{"runs": [{"text": ...}]}` from the ANDROID client — accept both.
    struct TrackName: Decodable {
        let simpleText: String?
        let runs: [Run]?

        struct Run: Decodable {
            let text: String?
        }

        var text: String {
            if let simpleText { return simpleText }
            return runs?.compactMap(\.text).joined() ?? ""
        }
    }

    struct WireCaptionTrack: Decodable {
        let baseUrl: String?
        let name: TrackName?
        let languageCode: String?
        let kind: String?
    }

    let playabilityStatus: PlayabilityStatus?
    let videoDetails: VideoDetails?
    let microformat: Microformat?
    let captions: Captions?

    var captionTracks: [CaptionTrack] {
        (captions?.playerCaptionsTracklistRenderer?.captionTracks ?? []).compactMap { track in
            guard let baseURL = track.baseUrl, let code = track.languageCode else { return nil }
            return CaptionTrack(
                baseURL: baseURL,
                languageCode: code,
                languageName: track.name?.text ?? code,
                isGenerated: track.kind == "asr"
            )
        }
    }

    func metadata(videoID: String) -> VideoMetadata {
        let details = videoDetails
        let micro = microformat?.playerMicroformatRenderer
        let rawDate = micro?.publishDate ?? micro?.uploadDate ?? ""
        return VideoMetadata(
            videoID: details?.videoId ?? videoID,
            title: (details?.title).flatMap { $0.isEmpty ? nil : $0 } ?? videoID,
            channel: details?.author ?? "",
            durationSeconds: (details?.lengthSeconds).flatMap(Int.init),
            publishedAt: Self.dateOnly(rawDate),
            url: "https://www.youtube.com/watch?v=\(details?.videoId ?? videoID)"
        )
    }

    /// Truncate `2024-05-01T00:00:00-07:00` (or pass `2024-05-01` through) to
    /// the date part; anything not shaped like a date becomes `""`.
    static func dateOnly(_ raw: String) -> String {
        let head = String(raw.prefix(10))
        return head.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil ? head : ""
    }
}
