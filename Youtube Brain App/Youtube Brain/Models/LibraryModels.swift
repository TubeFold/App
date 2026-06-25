import Foundation

struct VideoLibraryResponse: Decodable {
    let videos: [LibraryVideo]
}

struct RegenerateVideoResponse: Decodable {
    let jobId: String
    let videoId: String
    let status: String
}

struct LibraryVideo: Decodable, Identifiable {
    let id: String
    let youtubeVideoID: String
    let canonicalURL: String
    let title: String?
    let channelName: String?
    let thumbnailURL: String?
    let durationSeconds: Double?
    let currentTimeAtRequest: Double?
    let createdAt: String
    let updatedAt: String
    let status: String
    let transcriptPath: String?
    let summaryPath: String?
    let errorCode: String?
    let errorMessage: String?
    let latestJobID: String?
    let latestJobStatus: String?
    let latestJobCreatedAt: String?
    let latestJobFinishedAt: String?

    var displayTitle: String {
        title?.isEmpty == false ? title! : youtubeVideoID
    }

    var displayChannel: String {
        channelName?.isEmpty == false ? channelName! : "Unknown channel"
    }

    var isReady: Bool {
        status == "ready"
    }

    var isActive: Bool {
        ["queued", "fetchingMetadata", "fetchingTranscript", "generatingSummary"].contains(status)
    }

    var hasMarkdown: Bool {
        guard isReady, let summaryPath, !summaryPath.isEmpty else { return false }
        return true
    }

    var youtubeURL: URL? {
        URL(string: canonicalURL)
    }

    var thumbnailImageURL: URL? {
        guard let thumbnailURL else { return nil }
        return URL(string: thumbnailURL)
    }

    var markdownURL: URL? {
        guard let summaryPath, !summaryPath.isEmpty else { return nil }
        return URL(fileURLWithPath: summaryPath)
    }
}
