import Foundation
import Testing

@testable import TubeFoldKit

private func request(_ videoID: String = "dQw4w9WgXcQ", title: String? = "A Video") -> SummaryRequest {
    SummaryRequest(
        videoID: videoID,
        url: "https://www.youtube.com/watch?v=\(videoID)",
        title: title,
        channelName: "Channel",
        durationSeconds: 213
    )
}

// Store semantics: dedupe, status transitions, reclaim, watch activity, usage.
@Suite struct VideoStoreTests {
    @Test func createQueuesNewVideoAndJob() async throws {
        let store = try VideoStore.inMemory()
        let (outcome, videoID, jobID) = try await store.createOrReuse(request())
        #expect(outcome == .queued)
        #expect(jobID != nil)

        let video = try await store.getVideo(id: videoID)
        #expect(video?.status == .queued)
        #expect(video?.title == "A Video")
        #expect(video?.latestJob?.id == jobID)

        let queued = try await store.listQueuedJobs()
        #expect(queued.map(\.id) == [jobID])
    }

    @Test func dedupeSameYouTubeVideo() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, jobID) = try await store.createOrReuse(request())

        // Still processing → already_processing with the active job id.
        let second = try await store.createOrReuse(request())
        #expect(second.outcome == .alreadyProcessing)
        #expect(second.videoID == videoID)
        #expect(second.jobID == jobID)

        // Ready → already_exists, no new job.
        try await store.markReady(
            videoID: videoID, jobID: jobID!,
            transcriptPath: "/t.txt", summaryPath: "/s.md", summaryMarkdown: "# S"
        )
        let third = try await store.createOrReuse(request())
        #expect(third.outcome == .alreadyExists)
        #expect(third.jobID == nil)

        // force_regenerate overrides the dedupe.
        let fourth = try await store.createOrReuse(request(), forceRegenerate: true)
        #expect(fourth.outcome == .queued)
        #expect(fourth.videoID == videoID)
        #expect(fourth.jobID != jobID)
    }

    @Test func failedVideoIsRequeuedWithoutForce() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, jobID) = try await store.createOrReuse(request())
        try await store.markFailed(videoID: videoID, jobID: jobID!, code: "boom", message: "It broke")

        let retry = try await store.createOrReuse(request())
        #expect(retry.outcome == .queued)
        #expect(retry.videoID == videoID)

        let video = try await store.getVideo(id: videoID)
        #expect(video?.status == .queued)
        #expect(video?.errorCode == nil)
        #expect(video?.errorMessage == nil)
    }

    @Test func statusTransitionsStampJobTimes() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, jobID) = try await store.createOrReuse(request())

        try await store.markStatus(videoID: videoID, jobID: jobID!, status: .fetchingMetadata)
        var job = try await store.getJob(id: jobID!)
        #expect(job?.startedAt != nil)
        #expect(job?.finishedAt == nil)

        try await store.markStatus(videoID: videoID, jobID: jobID!, status: .ready)
        job = try await store.getJob(id: jobID!)
        #expect(job?.finishedAt != nil)

        let video = try await store.getVideo(id: videoID)
        #expect(video?.status == .ready)
    }

    @Test func reclaimOrphanedJobsFailsMidRunOnly() async throws {
        let store = try VideoStore.inMemory()
        let (_, v1, j1) = try await store.createOrReuse(request("aaaaaaaaaa1"))
        let (_, _, j2) = try await store.createOrReuse(request("aaaaaaaaaa2"))
        try await store.markStatus(videoID: v1, jobID: j1!, status: .generatingSummary)
        // j2 stays queued.

        let reclaimed = try await store.reclaimOrphanedJobs(code: "interrupted", message: "Interrupted.")
        #expect(reclaimed == [j1])

        let video = try await store.getVideo(id: v1)
        #expect(video?.status == .failed)
        #expect(video?.errorCode == "interrupted")

        let queued = try await store.listQueuedJobs()
        #expect(queued.map(\.id) == [j2])
    }

    @Test func updateMetadataNeverClobbersClientValues() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, _) = try await store.createOrReuse(SummaryRequest(
            videoID: "bbbbbbbbbb1",
            url: "https://www.youtube.com/watch?v=bbbbbbbbbb1",
            title: "Client Title",
            thumbnailURL: "https://client/cover.jpg"
        ))

        try await store.updateMetadata(
            videoID: videoID,
            title: "Fetched Title",
            channelName: "",
            durationSeconds: 99,
            thumbnailURL: "https://fetched/cover.jpg"
        )
        let video = try await store.getVideo(id: videoID)
        #expect(video?.title == "Fetched Title")
        #expect(video?.channelName == "Channel" || video?.channelName == nil) // blank fetch never clobbers
        #expect(video?.durationSeconds == 99)
        // Client cover wins — fetch only fills a missing thumbnail.
        #expect(video?.thumbnailURL == "https://client/cover.jpg")
    }

    @Test func deleteVideoReturnsYouTubeIDAndCascades() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, _) = try await store.createOrReuse(request())
        let youtubeID = try await store.deleteVideo(id: videoID)
        #expect(youtubeID == "dQw4w9WgXcQ")
        #expect(try await store.getVideo(id: videoID) == nil)
        #expect(try await store.listQueuedJobs().isEmpty)
        #expect(try await store.deleteVideo(id: "missing") == nil)
    }

    @Test func resetWipesRowsButKeepsMeta() async throws {
        let store = try VideoStore.inMemory()
        _ = try await store.createOrReuse(request())
        try await store.recordWatchActivity(youtubeVideoID: "cccccccccc1", canonicalURL: "https://y/c1")
        try await store.markExtensionSeen()

        let counts = try await store.reset()
        #expect(counts["videos"] == 1)
        #expect(counts["jobs"] == 1)
        #expect(counts["watch_activity"] == 1)
        #expect(try await store.listVideos().isEmpty)
        // Extension presence survives the reset.
        #expect(try await store.extensionLastSeen() != nil)
    }

    @Test func resetCanAlsoWipeMetaForFreshInstallTesting() async throws {
        let store = try VideoStore.inMemory()
        try await store.markExtensionSeen()

        let counts = try await store.reset(includeAppMeta: true)
        #expect(counts["app_meta"] == 1)
        #expect(try await store.extensionLastSeen() == nil)
    }

    @Test func watchSuggestionSkipsLibraryAndKeepsDismissal() async throws {
        let store = try VideoStore.inMemory()

        // Watched two videos; the newer one is already in the library.
        try await store.recordWatchActivity(youtubeVideoID: "olderwatch1", canonicalURL: "https://y/older")
        try await store.recordWatchActivity(youtubeVideoID: "newerwatch1", canonicalURL: "https://y/newer")
        _ = try await store.createOrReuse(request("newerwatch1", title: nil))

        let suggestion = try await store.latestWatchSuggestion()
        #expect(suggestion?.youtubeVideoID == "olderwatch1")

        // Dismissal hides it…
        try await store.dismissWatchActivity(youtubeVideoID: "olderwatch1")
        #expect(try await store.latestWatchSuggestion() == nil)

        // …and re-watching does NOT resurrect it.
        try await store.recordWatchActivity(youtubeVideoID: "olderwatch1", canonicalURL: "https://y/older")
        #expect(try await store.latestWatchSuggestion() == nil)
    }

    @Test func usageSummaryAggregatesPerProvider() async throws {
        let store = try VideoStore.inMemory()
        let (_, _, j1) = try await store.createOrReuse(request("ddddddddd11"))
        let (_, _, j2) = try await store.createOrReuse(request("ddddddddd12"))
        let (_, _, j3) = try await store.createOrReuse(request("ddddddddd13"))

        try await store.setJobUsage(jobID: j1!, usage: ProviderUsage(
            provider: "codex", inputTokens: 100, outputTokens: 20, totalTokens: 120
        ))
        try await store.setJobUsage(jobID: j2!, usage: ProviderUsage(
            provider: "codex", inputTokens: 50, outputTokens: 10, totalTokens: 60
        ))
        try await store.setJobUsage(jobID: j3!, usage: ProviderUsage(
            provider: "claude", inputTokens: 30, outputTokens: 5, totalTokens: 35, costUSD: 0.02
        ))

        let summary = try await store.usageSummary()
        #expect(summary.totalTokens == 215)
        #expect(summary.byProvider["codex"]?.jobs == 2)
        #expect(summary.byProvider["codex"]?.totalTokens == 180)
        #expect(summary.byProvider["codex"]?.costUSD == nil)
        #expect(summary.byProvider["claude"]?.costUSD == 0.02)
    }

    @Test func telegraphPageCaching() async throws {
        let store = try VideoStore.inMemory()
        let (_, videoID, _) = try await store.createOrReuse(request())
        try await store.setTelegraphPage(videoID: videoID, url: "https://telegra.ph/x", path: "x", summaryHash: "h1")
        let video = try await store.getVideo(id: videoID)
        #expect(video?.telegraphURL == "https://telegra.ph/x")
        #expect(video?.telegraphSummaryHash == "h1")
    }
}
