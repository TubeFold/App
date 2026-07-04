import Foundation
import SwiftData

/// Lifecycle of a library video / job — raw values are the extension-facing
/// API strings.
public enum ProcessingStatus: String, Sendable, Codable, CaseIterable {
    case queued
    case fetchingMetadata
    case fetchingTranscript
    case generatingSummary
    case ready
    case failed
    case cancelled

    public static let activeStatuses: Set<ProcessingStatus> = [
        .queued, .fetchingMetadata, .fetchingTranscript, .generatingSummary,
    ]

    public static let inProgressStatuses: [ProcessingStatus] = [
        .fetchingMetadata, .fetchingTranscript, .generatingSummary,
    ]

    public var isActive: Bool { Self.activeStatuses.contains(self) }
}

/// One summarize request (extension POST or in-app add).
public struct SummaryRequest: Sendable, Equatable {
    public let videoID: String
    public let url: String
    public let title: String?
    public let channelName: String?
    public let durationSeconds: Double?
    public let currentTimeSeconds: Double?
    public let thumbnailURL: String?
    public let source: String

    public init(
        videoID: String,
        url: String,
        title: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil,
        currentTimeSeconds: Double? = nil,
        thumbnailURL: String? = nil,
        source: String = "chrome-extension"
    ) {
        self.videoID = videoID
        self.url = url
        self.title = title
        self.channelName = channelName
        self.durationSeconds = durationSeconds
        self.currentTimeSeconds = currentTimeSeconds
        self.thumbnailURL = thumbnailURL
        self.source = source
    }
}

/// A pipeline failure with a stable machine code, a user-facing message and
/// the technical detail.
public struct ProcessingError: Error, Sendable, Equatable {
    public let code: String
    public let userMessage: String
    public let technicalMessage: String

    public init(code: String, userMessage: String, technicalMessage: String) {
        self.code = code
        self.userMessage = userMessage
        self.technicalMessage = technicalMessage
    }
}

// MARK: - SwiftData models (mirror the videos / jobs / watch_activity tables)

@Model
public final class Video {
    @Attribute(.unique) public var id: String
    @Attribute(.unique) public var youtubeVideoID: String
    public var canonicalURL: String
    public var title: String?
    public var channelName: String?
    public var thumbnailURL: String?
    public var durationSeconds: Double?
    public var currentTimeAtRequest: Double?
    public var createdAt: Date
    public var updatedAt: Date
    /// Raw `ProcessingStatus` string (stored raw so #Predicate can match it).
    public var statusRaw: String
    public var transcriptPath: String?
    public var summaryPath: String?
    public var summaryMarkdown: String?
    public var errorCode: String?
    public var errorMessage: String?
    public var telegraphURL: String?
    public var telegraphPath: String?
    public var telegraphSummaryHash: String?
    @Relationship(deleteRule: .cascade, inverse: \Job.video) public var jobs: [Job]

    public var status: ProcessingStatus {
        get { ProcessingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        id: String = UUID().uuidString,
        youtubeVideoID: String,
        canonicalURL: String,
        title: String? = nil,
        channelName: String? = nil,
        thumbnailURL: String? = nil,
        durationSeconds: Double? = nil,
        currentTimeAtRequest: Double? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: ProcessingStatus = .queued
    ) {
        self.id = id
        self.youtubeVideoID = youtubeVideoID
        self.canonicalURL = canonicalURL
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.currentTimeAtRequest = currentTimeAtRequest
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        statusRaw = status.rawValue
        jobs = []
    }
}

@Model
public final class Job {
    @Attribute(.unique) public var id: String
    public var statusRaw: String
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
    public var retryCount: Int
    public var errorMessage: String?
    public var provider: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?
    public var costUSD: Double?
    public var video: Video?

    public var status: ProcessingStatus {
        get { ProcessingStatus(rawValue: statusRaw) ?? .failed }
        set { statusRaw = newValue.rawValue }
    }

    public init(
        id: String = UUID().uuidString,
        status: ProcessingStatus = .queued,
        createdAt: Date = Date(),
        video: Video? = nil
    ) {
        self.id = id
        statusRaw = status.rawValue
        self.createdAt = createdAt
        retryCount = 0
        self.video = video
    }
}

@Model
public final class WatchActivity {
    @Attribute(.unique) public var youtubeVideoID: String
    public var canonicalURL: String
    public var title: String?
    public var channelName: String?
    public var thumbnailURL: String?
    public var durationSeconds: Double?
    public var watchedAt: Date
    public var dismissedAt: Date?

    public init(
        youtubeVideoID: String,
        canonicalURL: String,
        title: String? = nil,
        channelName: String? = nil,
        thumbnailURL: String? = nil,
        durationSeconds: Double? = nil,
        watchedAt: Date = Date()
    ) {
        self.youtubeVideoID = youtubeVideoID
        self.canonicalURL = canonicalURL
        self.title = title
        self.channelName = channelName
        self.thumbnailURL = thumbnailURL
        self.durationSeconds = durationSeconds
        self.watchedAt = watchedAt
    }
}

/// Small key/value store (mirrors the `app_meta` table; keeps
/// `extension_last_seen` across data resets).
@Model
public final class AppMeta {
    @Attribute(.unique) public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

// MARK: - Sendable snapshots (model objects never cross the actor boundary)

public struct JobRecord: Sendable, Equatable {
    public let id: String
    public let videoID: String
    public let status: ProcessingStatus
    public let createdAt: Date
    public let startedAt: Date?
    public let finishedAt: Date?
    public let retryCount: Int
    public let errorMessage: String?
    public let provider: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let totalTokens: Int?
    public let costUSD: Double?

    init(_ job: Job) {
        id = job.id
        videoID = job.video?.id ?? ""
        status = job.status
        createdAt = job.createdAt
        startedAt = job.startedAt
        finishedAt = job.finishedAt
        retryCount = job.retryCount
        errorMessage = job.errorMessage
        provider = job.provider
        inputTokens = job.inputTokens
        outputTokens = job.outputTokens
        totalTokens = job.totalTokens
        costUSD = job.costUSD
    }
}

public struct VideoRecord: Sendable, Equatable {
    public let id: String
    public let youtubeVideoID: String
    public let canonicalURL: String
    public let title: String?
    public let channelName: String?
    public let thumbnailURL: String?
    public let durationSeconds: Double?
    public let currentTimeAtRequest: Double?
    public let createdAt: Date
    public let updatedAt: Date
    public let status: ProcessingStatus
    public let transcriptPath: String?
    public let summaryPath: String?
    public let summaryMarkdown: String?
    public let errorCode: String?
    public let errorMessage: String?
    public let telegraphURL: String?
    public let telegraphPath: String?
    public let telegraphSummaryHash: String?
    public let latestJob: JobRecord?

    init(_ video: Video, latestJob: Job?) {
        id = video.id
        youtubeVideoID = video.youtubeVideoID
        canonicalURL = video.canonicalURL
        title = video.title
        channelName = video.channelName
        thumbnailURL = video.thumbnailURL
        durationSeconds = video.durationSeconds
        currentTimeAtRequest = video.currentTimeAtRequest
        createdAt = video.createdAt
        updatedAt = video.updatedAt
        status = video.status
        transcriptPath = video.transcriptPath
        summaryPath = video.summaryPath
        summaryMarkdown = video.summaryMarkdown
        errorCode = video.errorCode
        errorMessage = video.errorMessage
        telegraphURL = video.telegraphURL
        telegraphPath = video.telegraphPath
        telegraphSummaryHash = video.telegraphSummaryHash
        self.latestJob = latestJob.map(JobRecord.init)
    }
}

public struct WatchActivityRecord: Sendable, Equatable {
    public let youtubeVideoID: String
    public let canonicalURL: String
    public let title: String?
    public let channelName: String?
    public let thumbnailURL: String?
    public let durationSeconds: Double?
    public let watchedAt: Date
    public let dismissedAt: Date?

    init(_ activity: WatchActivity) {
        youtubeVideoID = activity.youtubeVideoID
        canonicalURL = activity.canonicalURL
        title = activity.title
        channelName = activity.channelName
        thumbnailURL = activity.thumbnailURL
        durationSeconds = activity.durationSeconds
        watchedAt = activity.watchedAt
        dismissedAt = activity.dismissedAt
    }
}

/// `usage_summary()` result: total tokens + per-provider breakdown.
public struct UsageSummary: Sendable, Equatable {
    public struct ProviderTotals: Sendable, Equatable {
        public let jobs: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let totalTokens: Int
        public let costUSD: Double?
    }

    public let totalTokens: Int
    public let byProvider: [String: ProviderTotals]
}

/// Outcome of `createOrReuse` — raw values are the API status strings.
public enum CreateOrReuseOutcome: String, Sendable {
    case queued
    case alreadyExists = "already_exists"
    case alreadyProcessing = "already_processing"
}
