import Foundation
import SwiftData

/// All persistence behind one `@ModelActor`.
/// The pipeline actor and UI never share contexts;
/// every public method returns Sendable snapshots.
@ModelActor
public actor VideoStore {
    // MARK: - Container setup

    /// On-disk store in the app data dir. Also deletes a stale
    /// `database.sqlite` left behind by old builds.
    public static func onDisk(dataDirectory: URL) throws -> VideoStore {
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        for legacy in ["database.sqlite", "database.sqlite-wal", "database.sqlite-shm"] {
            try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent(legacy))
        }
        let configuration = ModelConfiguration(url: dataDirectory.appendingPathComponent("library.store"))
        let container = try ModelContainer(
            for: Video.self, Job.self, WatchActivity.self, AppMeta.self,
            configurations: configuration
        )
        return VideoStore(modelContainer: container)
    }

    /// In-memory store for tests.
    public static func inMemory() throws -> VideoStore {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Video.self, Job.self, WatchActivity.self, AppMeta.self,
            configurations: configuration
        )
        return VideoStore(modelContainer: container)
    }

    // MARK: - Lookups

    private func videoModel(id: String) throws -> Video? {
        var descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func videoModel(youtubeVideoID: String) throws -> Video? {
        var descriptor = FetchDescriptor<Video>(predicate: #Predicate { $0.youtubeVideoID == youtubeVideoID })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func jobModel(id: String) throws -> Job? {
        var descriptor = FetchDescriptor<Job>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private static func latestJob(of video: Video) -> Job? {
        video.jobs.max(by: { $0.createdAt < $1.createdAt })
    }

    public func getVideo(id: String) throws -> VideoRecord? {
        try videoModel(id: id).map { VideoRecord($0, latestJob: Self.latestJob(of: $0)) }
    }

    public func getVideo(youtubeVideoID: String) throws -> VideoRecord? {
        try videoModel(youtubeVideoID: youtubeVideoID).map { VideoRecord($0, latestJob: Self.latestJob(of: $0)) }
    }

    public func getJob(id: String) throws -> JobRecord? {
        try jobModel(id: id).map(JobRecord.init)
    }

    /// Library listing, newest-updated first, each with its latest job.
    public func listVideos(limit: Int = 200) throws -> [VideoRecord] {
        var descriptor = FetchDescriptor<Video>(sortBy: [
            SortDescriptor(\.updatedAt, order: .reverse),
            SortDescriptor(\.createdAt, order: .reverse),
        ])
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor).map { VideoRecord($0, latestJob: Self.latestJob(of: $0)) }
    }

    // MARK: - Create / dedupe

    private func latestActiveJob(of video: Video) -> Job? {
        video.jobs
            .filter { $0.status.isActive }
            .max(by: { $0.createdAt < $1.createdAt })
    }

    /// Dedupe-aware enqueue. The same YouTube
    /// video isn't re-summarized unless `forceRegenerate` or the previous
    /// attempt failed.
    public func createOrReuse(
        _ request: SummaryRequest,
        forceRegenerate: Bool = false
    ) throws -> (outcome: CreateOrReuseOutcome, videoID: String, jobID: String?) {
        let now = Date()
        let existing = try videoModel(youtubeVideoID: request.videoID)

        if let existing, !forceRegenerate {
            if existing.status == .ready {
                return (.alreadyExists, existing.id, nil)
            }
            if let activeJob = latestActiveJob(of: existing) {
                return (.alreadyProcessing, existing.id, activeJob.id)
            }
            if existing.status != .failed {
                return (.alreadyExists, existing.id, nil)
            }
        }

        let video: Video
        if let existing {
            existing.canonicalURL = request.url
            existing.title = request.title ?? existing.title
            existing.channelName = request.channelName ?? existing.channelName
            existing.thumbnailURL = request.thumbnailURL ?? existing.thumbnailURL
            existing.durationSeconds = request.durationSeconds ?? existing.durationSeconds
            existing.currentTimeAtRequest = request.currentTimeSeconds ?? existing.currentTimeAtRequest
            existing.updatedAt = now
            existing.status = .queued
            existing.errorCode = nil
            existing.errorMessage = nil
            video = existing
        } else {
            video = Video(
                youtubeVideoID: request.videoID,
                canonicalURL: request.url,
                title: request.title,
                channelName: request.channelName,
                thumbnailURL: request.thumbnailURL,
                durationSeconds: request.durationSeconds,
                currentTimeAtRequest: request.currentTimeSeconds,
                createdAt: now,
                updatedAt: now,
                status: .queued
            )
            modelContext.insert(video)
        }

        let job = Job(status: .queued, createdAt: now, video: video)
        modelContext.insert(job)
        try modelContext.save()
        return (.queued, video.id, job.id)
    }

    // MARK: - Delete / reset

    /// Delete a video and all of its jobs (cascade). Returns the video's
    /// `youtubeVideoID` so callers can clean up on-disk artifacts, or `nil`
    /// if it didn't exist.
    public func deleteVideo(id: String) throws -> String? {
        guard let video = try videoModel(id: id) else {
            return nil
        }
        let youtubeVideoID = video.youtubeVideoID
        modelContext.delete(video)
        try modelContext.save()
        return youtubeVideoID
    }

    /// Wipe every data row (videos, jobs, watch activity); the schema and
    /// `AppMeta` (extension presence) are preserved. Returns rows removed per
    /// table (`videos`/`jobs`/`watch_activity`).
    public func reset() throws -> [String: Int] {
        // Object-by-object (not a batch delete): the Job→Video inverse makes
        // executeBatchDeleteRequest trip over its own relationship trigger.
        let jobs = try modelContext.fetch(FetchDescriptor<Job>())
        let videos = try modelContext.fetch(FetchDescriptor<Video>())
        let watchRows = try modelContext.fetch(FetchDescriptor<WatchActivity>())
        jobs.forEach(modelContext.delete)
        videos.forEach(modelContext.delete)
        watchRows.forEach(modelContext.delete)
        try modelContext.save()
        return ["jobs": jobs.count, "videos": videos.count, "watch_activity": watchRows.count]
    }

    // MARK: - Watch activity

    /// Remember the most recently opened YouTube video so the app can suggest
    /// it. Re-watching refreshes `watchedAt` but **preserves any prior
    /// dismissal**: once closed with the X it stays hidden for good.
    public func recordWatchActivity(
        youtubeVideoID: String,
        canonicalURL: String,
        title: String? = nil,
        channelName: String? = nil,
        thumbnailURL: String? = nil,
        durationSeconds: Double? = nil
    ) throws {
        var descriptor = FetchDescriptor<WatchActivity>(
            predicate: #Predicate { $0.youtubeVideoID == youtubeVideoID }
        )
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.canonicalURL = canonicalURL
            existing.title = title ?? existing.title
            if let channelName, !channelName.isEmpty {
                existing.channelName = channelName
            }
            existing.thumbnailURL = thumbnailURL ?? existing.thumbnailURL
            existing.durationSeconds = durationSeconds ?? existing.durationSeconds
            existing.watchedAt = Date()
        } else {
            modelContext.insert(WatchActivity(
                youtubeVideoID: youtubeVideoID,
                canonicalURL: canonicalURL,
                title: title,
                channelName: channelName,
                thumbnailURL: thumbnailURL,
                durationSeconds: durationSeconds,
                watchedAt: Date()
            ))
        }
        try modelContext.save()
    }

    /// Newest non-dismissed watched video that is **not already in the
    /// library** (queued/processing/ready/failed all count as "already
    /// there").
    public func latestWatchSuggestion() throws -> WatchActivityRecord? {
        let descriptor = FetchDescriptor<WatchActivity>(
            predicate: #Predicate { $0.dismissedAt == nil },
            sortBy: [SortDescriptor(\.watchedAt, order: .reverse)]
        )
        for candidate in try modelContext.fetch(descriptor) {
            if try videoModel(youtubeVideoID: candidate.youtubeVideoID) == nil {
                return WatchActivityRecord(candidate)
            }
        }
        return nil
    }

    public func dismissWatchActivity(youtubeVideoID: String) throws {
        var descriptor = FetchDescriptor<WatchActivity>(
            predicate: #Predicate { $0.youtubeVideoID == youtubeVideoID }
        )
        descriptor.fetchLimit = 1
        guard let activity = try modelContext.fetch(descriptor).first else { return }
        activity.dismissedAt = Date()
        try modelContext.save()
    }

    // MARK: - App meta

    public func setMeta(key: String, value: String) throws {
        var descriptor = FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.value = value
        } else {
            modelContext.insert(AppMeta(key: key, value: value))
        }
        try modelContext.save()
    }

    public func getMeta(key: String) throws -> String? {
        var descriptor = FetchDescriptor<AppMeta>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.value
    }

    /// Remember that the Chrome extension just talked to us. Deliberately
    /// kept across a data reset — it's about the extension being present,
    /// not library content.
    public func markExtensionSeen() throws {
        try setMeta(key: "extension_last_seen", value: ISO8601DateFormatter().string(from: Date()))
    }

    public func extensionLastSeen() throws -> String? {
        try getMeta(key: "extension_last_seen")
    }

    // MARK: - Job queue

    public func listQueuedJobs() throws -> [JobRecord] {
        let queued = ProcessingStatus.queued.rawValue
        let descriptor = FetchDescriptor<Job>(
            predicate: #Predicate { $0.statusRaw == queued },
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).map(JobRecord.init)
    }

    /// Fail any job left mid-run by a previous process and reset its video.
    /// Queued jobs are left alone. Returns
    /// the reclaimed job ids.
    public func reclaimOrphanedJobs(code: String, message: String) throws -> [String] {
        let inProgress = ProcessingStatus.inProgressStatuses.map(\.rawValue)
        let descriptor = FetchDescriptor<Job>(predicate: #Predicate { inProgress.contains($0.statusRaw) })
        let now = Date()
        var reclaimed: [String] = []
        for job in try modelContext.fetch(descriptor) {
            job.status = .failed
            job.finishedAt = job.finishedAt ?? now
            job.errorMessage = message
            if let video = job.video {
                video.status = .failed
                video.updatedAt = now
                video.errorCode = code
                video.errorMessage = message
            }
            reclaimed.append(job.id)
        }
        if !reclaimed.isEmpty {
            try modelContext.save()
        }
        return reclaimed
    }

    // MARK: - Status transitions

    public func markStatus(videoID: String, jobID: String, status: ProcessingStatus) throws {
        let now = Date()
        guard let video = try videoModel(id: videoID), let job = try jobModel(id: jobID) else { return }
        video.status = status
        video.updatedAt = now
        switch status {
        case .queued:
            job.status = status
        case .ready, .failed, .cancelled:
            job.status = status
            job.finishedAt = job.finishedAt ?? now
        default:
            job.status = status
            job.startedAt = job.startedAt ?? now
        }
        try modelContext.save()
    }

    /// Fill in metadata as soon as it is fetched, without clobbering anything
    /// a client already supplied: title/channel/duration only replace nils
    /// (or blanks), the thumbnail is only set when the row has none yet.
    public func updateMetadata(
        videoID: String,
        title: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil,
        thumbnailURL: String? = nil
    ) throws {
        guard let video = try videoModel(id: videoID) else { return }
        if let title {
            video.title = title
        }
        if let channelName, !channelName.isEmpty {
            video.channelName = channelName
        }
        if let durationSeconds {
            video.durationSeconds = durationSeconds
        }
        if video.thumbnailURL == nil || video.thumbnailURL?.isEmpty == true,
           let thumbnailURL, !thumbnailURL.isEmpty {
            video.thumbnailURL = thumbnailURL
        }
        video.updatedAt = Date()
        try modelContext.save()
    }

    public func markReady(
        videoID: String,
        jobID: String,
        transcriptPath: String,
        summaryPath: String,
        summaryMarkdown: String,
        title: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil
    ) throws {
        let now = Date()
        guard let video = try videoModel(id: videoID) else { return }
        video.status = .ready
        video.updatedAt = now
        video.transcriptPath = transcriptPath
        video.summaryPath = summaryPath
        video.summaryMarkdown = summaryMarkdown
        video.title = title ?? video.title
        video.channelName = channelName ?? video.channelName
        video.durationSeconds = durationSeconds ?? video.durationSeconds
        video.errorCode = nil
        video.errorMessage = nil
        if let job = try jobModel(id: jobID) {
            job.status = .ready
            job.finishedAt = job.finishedAt ?? now
        }
        try modelContext.save()
    }

    public func markFailed(videoID: String, jobID: String, code: String, message: String) throws {
        let now = Date()
        if let video = try videoModel(id: videoID) {
            video.status = .failed
            video.updatedAt = now
            video.errorCode = code
            video.errorMessage = message
        }
        if let job = try jobModel(id: jobID) {
            job.status = .failed
            job.finishedAt = job.finishedAt ?? now
            job.errorMessage = message
        }
        try modelContext.save()
    }

    // MARK: - Telegraph + usage

    public func setTelegraphPage(videoID: String, url: String, path: String, summaryHash: String = "") throws {
        guard let video = try videoModel(id: videoID) else { return }
        video.telegraphURL = url
        video.telegraphPath = path
        video.telegraphSummaryHash = summaryHash
        try modelContext.save()
    }

    /// Persist the token usage captured from a provider run.
    public func setJobUsage(jobID: String, usage: ProviderUsage) throws {
        guard let job = try jobModel(id: jobID) else { return }
        job.provider = usage.provider
        job.inputTokens = usage.inputTokens
        job.outputTokens = usage.outputTokens
        job.totalTokens = usage.totalTokens
        job.costUSD = usage.costUSD
        try modelContext.save()
    }

    /// Aggregate token usage across all jobs that recorded any. Counts cover
    /// TubeFold's own runs only.
    public func usageSummary() throws -> UsageSummary {
        let descriptor = FetchDescriptor<Job>(predicate: #Predicate { $0.totalTokens != nil })
        var byProvider: [String: (jobs: Int, input: Int, output: Int, total: Int, cost: Double)] = [:]
        var totalTokens = 0
        for job in try modelContext.fetch(descriptor) {
            let provider = job.provider ?? "unknown"
            var entry = byProvider[provider] ?? (0, 0, 0, 0, 0)
            entry.jobs += 1
            entry.input += job.inputTokens ?? 0
            entry.output += job.outputTokens ?? 0
            entry.total += job.totalTokens ?? 0
            entry.cost += job.costUSD ?? 0
            byProvider[provider] = entry
            totalTokens += job.totalTokens ?? 0
        }
        return UsageSummary(
            totalTokens: totalTokens,
            byProvider: byProvider.mapValues {
                UsageSummary.ProviderTotals(
                    jobs: $0.jobs,
                    inputTokens: $0.input,
                    outputTokens: $0.output,
                    totalTokens: $0.total,
                    costUSD: $0.cost > 0 ? $0.cost : nil
                )
            }
        )
    }
}
