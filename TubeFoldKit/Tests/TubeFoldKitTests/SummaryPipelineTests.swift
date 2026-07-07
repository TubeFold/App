import Foundation
import Testing

@testable import TubeFoldKit

// MARK: - Fixtures

private let playerFixture = """
{
  "playabilityStatus": {"status": "OK"},
  "videoDetails": {
    "videoId": "dQw4w9WgXcQ",
    "title": "Hello / World: Demo",
    "author": "Demo Channel",
    "lengthSeconds": "213"
  },
  "microformat": {"playerMicroformatRenderer": {"publishDate": "2024-05-01T00:00:00-07:00"}},
  "captions": {
    "playerCaptionsTracklistRenderer": {
      "captionTracks": [
        {
          "baseUrl": "https://timedtext.example/track",
          "name": {"simpleText": "English (auto-generated)"},
          "languageCode": "en",
          "kind": "asr"
        }
      ]
    }
  }
}
"""

private let transcriptFixture = """
{"events": [{"segs": [{"utf8": "This is a transcript with more than twenty characters of content."}]}]}
"""

private func pipelineTransport() -> InnerTubeClient.Transport {
    { request in
        let url = request.url!
        let body = url.absoluteString.contains("youtubei/v1/player") ? playerFixture : transcriptFixture
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private struct PipelineHarness {
    let store: VideoStore
    let pipeline: SummaryPipeline
    let dataDir: URL

    static func make(provider: (any SummaryProvider)? = FakeProvider()) throws -> PipelineHarness {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubefoldkit-pipeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let store = try VideoStore.inMemory()
        let config = PipelineConfiguration(dataDirectory: dataDir, provider: "fake")
        let pipeline = SummaryPipeline(
            store: store,
            config: config,
            innerTube: InnerTubeClient(transport: pipelineTransport()),
            providerOverride: provider
        )
        return PipelineHarness(store: store, pipeline: pipeline, dataDir: dataDir)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: dataDir)
    }

    func enqueue(_ videoID: String = "dQw4w9WgXcQ") async throws -> (videoID: String, jobID: String) {
        let (_, id, jobID) = try await store.createOrReuse(SummaryRequest(
            videoID: videoID,
            url: "https://www.youtube.com/watch?v=\(videoID)"
        ))
        return (id, jobID!)
    }
}

private struct ExplodingProvider: SummaryProvider {
    let id = "codex"
    func generateSummary(prompt _: String, settings _: ProviderRunSettings) async throws -> ProviderRunResult {
        throw ProviderRunError.processFailed(exitCode: 1, detail: "rate limit or quota problem", stderr: "boom")
    }
}

// End-to-end pipeline runs against a stubbed InnerTube transport.
@Suite struct SummaryPipelineTests {
    @Test func fakeProviderProcessingWritesVideoArtifacts() async throws {
        let harness = try PipelineHarness.make()
        defer { harness.cleanUp() }
        let (videoID, jobID) = try await harness.enqueue()
        let videoRecord = try await harness.store.getVideo(id: videoID)!

        try await harness.pipeline.processJob(video: videoRecord, jobID: jobID)

        let video = try await harness.store.getVideo(id: videoID)
        #expect(video?.status == .ready)
        #expect(video?.title == "Hello / World: Demo")
        #expect(video?.channelName == "Demo Channel")
        #expect(video?.durationSeconds == 213)

        let summaryPath = try #require(video?.summaryPath)
        let transcriptPath = try #require(video?.transcriptPath)
        #expect(FileManager.default.fileExists(atPath: summaryPath))
        #expect(FileManager.default.fileExists(atPath: transcriptPath))
        #expect(URL(fileURLWithPath: summaryPath).lastPathComponent == "[TubeFold] Hello - World- Demo.md")

        let summary = try String(contentsOfFile: summaryPath, encoding: .utf8)
        #expect(summary.contains("model: \"fake\""))
        #expect(summary.contains("# Fake Summary"))
        #expect(summary.hasPrefix("---\ntype: \"tubefold\"\nsource: \"youtube\"\n"))
        #expect(summary.contains("published_at: \"2024-05-01\""))
        #expect(summary.contains("transcript_is_generated: true"))
        #expect(summary.contains("_Generated with [TubeFold](https://tubefold.github.io/)_"))
        #expect(video?.summaryMarkdown == summary)

        // Per-job artifacts exist too.
        let jobDir = harness.dataDir.appendingPathComponent("jobs/\(jobID)")
        for name in ["input.json", "metadata.json", "transcript.txt", "transcript-info.json", "prompt.md", "provider-output.md", "summary.md", "job.log"] {
            #expect(
                FileManager.default.fileExists(atPath: jobDir.appendingPathComponent(name).path),
                "missing \(name)"
            )
        }

        // Prompt was rendered from the bundled template with substitutions.
        let prompt = try String(contentsOf: jobDir.appendingPathComponent("prompt.md"), encoding: .utf8)
        #expect(prompt.contains("# Hello / World: Demo"))
        #expect(prompt.contains("English (auto-generated) (en, auto)"))
        #expect(prompt.contains("English"))
        #expect(!prompt.contains("{{TITLE}}"))
        #expect(!prompt.contains("{{TRANSCRIPT}}"))
    }

    @Test func providerFailureMarksVideoFailed() async throws {
        let harness = try PipelineHarness.make(provider: ExplodingProvider())
        defer { harness.cleanUp() }
        let (videoID, jobID) = try await harness.enqueue()
        let videoRecord = try await harness.store.getVideo(id: videoID)!

        await #expect(throws: ProcessingError.self) {
            try await harness.pipeline.processJob(video: videoRecord, jobID: jobID)
        }
    }

    @Test func queueDrainsJobsEndToEnd() async throws {
        let harness = try PipelineHarness.make()
        defer { harness.cleanUp() }
        let (videoID, _) = try await harness.enqueue()

        await harness.pipeline.start()

        var video: VideoRecord?
        for _ in 0 ..< 100 {
            video = try await harness.store.getVideo(id: videoID)
            if video?.status == .ready || video?.status == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(video?.status == .ready)
        #expect(try await harness.store.listQueuedJobs().isEmpty)
    }

    @Test func failedProviderJobRecordsErrorCode() async throws {
        let harness = try PipelineHarness.make(provider: ExplodingProvider())
        defer { harness.cleanUp() }
        let (videoID, _) = try await harness.enqueue()

        await harness.pipeline.start()

        var video: VideoRecord?
        for _ in 0 ..< 100 {
            video = try await harness.store.getVideo(id: videoID)
            if video?.status == .failed {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(video?.status == .failed)
        #expect(video?.errorCode == "codex_process_failed")
        #expect(video?.errorMessage == "Could not generate summary.")
    }

    @Test func modelLabelUsesDisplayNameWithoutEffort() async throws {
        // Port of test_codex_markdown_includes_model_metadata /
        // test_claude_selection_drives_markdown_metadata: the front matter
        // model prefers the display label and never surfaces "auto" effort.
        let harness = try PipelineHarness.make()
        defer { harness.cleanUp() }

        let metadata = VideoMetadata(
            videoID: "dQw4w9WgXcQ", title: "T", channel: "C",
            durationSeconds: 60, publishedAt: "2024-01-01",
            url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        )
        let transcript = TranscriptResult(text: "text", language: "English", languageCode: "en", isGenerated: true)

        let codexMarkdown = await harness.pipeline.buildMarkdown(
            metadata: metadata, transcript: transcript, response: "# Body",
            providerID: "codex",
            settings: ProviderRunSettings(model: "gpt-5.5", reasoningEffort: "auto", timeout: 1),
            outputLanguage: "English"
        )
        #expect(codexMarkdown.contains("model: \"Codex GPT-5.5\""))
        #expect(!codexMarkdown.contains("effort:"))

        let claudeMarkdown = await harness.pipeline.buildMarkdown(
            metadata: metadata, transcript: transcript, response: "# Body",
            providerID: "claude",
            settings: ProviderRunSettings(model: "opus", reasoningEffort: "auto", timeout: 1),
            outputLanguage: "English"
        )
        #expect(claudeMarkdown.contains("model: \"Claude Opus 4.8\""))
        #expect(!claudeMarkdown.contains("effort:"))
    }

    @Test func transcriptLanguageLabelFormats() {
        #expect(transcriptLanguageLabel(language: "English", languageCode: "en", isGenerated: true) == "English (en, auto)")
        #expect(transcriptLanguageLabel(language: "en", languageCode: "en", isGenerated: false) == "en (manual)")
        #expect(transcriptLanguageLabel(language: "", languageCode: "", isGenerated: false) == "unknown (manual)")
    }
}
