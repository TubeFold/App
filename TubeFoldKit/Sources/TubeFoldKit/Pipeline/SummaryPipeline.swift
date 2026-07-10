import Foundation
import os

/// The in-process summarization pipeline. One actor, single-flight: queued
/// jobs drain one at a time through the stages:
///
///     metadata → transcript → render prompt → provider → validate/compose
///     → artifacts
///
/// Key invariant preserved: the YAML front matter is generated here, never by
/// the model; the provider only ever produces the Markdown body.
public actor SummaryPipeline {
    private let store: VideoStore
    private let config: PipelineConfiguration
    private let setupStore: ProviderSetupStore
    private let innerTube: InnerTubeClient
    /// Test hook: overrides provider resolution entirely.
    private let providerOverride: (any SummaryProvider)?

    private let logger = Logger(subsystem: "app.tubefold", category: "pipeline")
    private var isDraining = false
    private var needsAnotherPass = false
    private var stopped = false

    public init(
        store: VideoStore,
        config: PipelineConfiguration,
        setupStore: ProviderSetupStore? = nil,
        innerTube: InnerTubeClient = InnerTubeClient(),
        providerOverride: (any SummaryProvider)? = nil
    ) {
        self.store = store
        self.config = config
        self.setupStore = setupStore ?? ProviderSetupStore(dataDirectory: config.dataDirectory)
        self.innerTube = innerTube
        self.providerOverride = providerOverride
    }

    // MARK: - Queue lifecycle

    /// Reclaim orphaned jobs from a previous crash/quit, then drain anything
    /// already queued.
    public func start() async {
        logger.info("Starting pipeline provider=\(self.config.provider, privacy: .public)")
        let reclaimed = (try? await store.reclaimOrphanedJobs(
            code: "interrupted",
            message: "Summary generation was interrupted before it finished. Try again."
        )) ?? []
        if !reclaimed.isEmpty {
            logger.warning("Reclaimed \(reclaimed.count) orphaned job(s) left mid-run")
        }
        notify()
    }

    public func stop() {
        stopped = true
    }

    /// Wake the worker; new jobs are picked up immediately.
    public func notify() {
        guard !stopped else { return }
        if isDraining {
            needsAnotherPass = true
            return
        }
        isDraining = true
        Task { await drain() }
    }

    private func drain() async {
        defer {
            isDraining = false
            if needsAnotherPass {
                needsAnotherPass = false
                notify()
            }
        }
        while !stopped {
            guard let job = try? await store.listQueuedJobs().first else {
                return
            }
            guard let video = try? await store.getVideo(id: job.videoID) else {
                logger.error("Skipping job=\(job.id, privacy: .public): video record is missing")
                try? await store.markFailed(
                    videoID: job.videoID, jobID: job.id,
                    code: "video_missing", message: "Video record is missing."
                )
                continue
            }
            do {
                try await processJob(video: video, jobID: job.id)
            } catch let error as ProcessingError {
                logger.error("""
                Job failed job=\(job.id, privacy: .public) code=\(error.code, privacy: .public) \
                message=\(error.userMessage, privacy: .public)
                """)
                try? await store.markFailed(
                    videoID: video.id, jobID: job.id,
                    code: error.code, message: error.userMessage
                )
            } catch {
                logger.error("Unexpected job failure job=\(job.id, privacy: .public): \(error)")
                try? await store.markFailed(
                    videoID: video.id, jobID: job.id,
                    code: "process_failed", message: "\(error)"
                )
            }
        }
    }

    // MARK: - One job

    func processJob(video: VideoRecord, jobID: String) async throws {
        let fileManager = FileManager.default
        let jobDir = config.jobsDirectory.appendingPathComponent(jobID)
        let videoDir = config.videosDirectory.appendingPathComponent(video.youtubeVideoID)
        try fileManager.createDirectory(at: jobDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: videoDir, withIntermediateDirectories: true)
        let jobLog = JobLog(directory: jobDir)
        jobLog.append("start job=\(jobID) local_video_id=\(video.id) youtube_id=\(video.youtubeVideoID)")

        try writeJSON(jobDir.appendingPathComponent("input.json"), [
            "videoId": video.youtubeVideoID,
            "url": video.canonicalURL,
            "title": video.title as Any,
            "channelName": video.channelName as Any,
            "thumbnailURL": video.thumbnailURL as Any,
            "durationSeconds": video.durationSeconds as Any,
            "currentTimeAtRequest": video.currentTimeAtRequest as Any,
        ])
        jobLog.append("input.json written")

        // ------------------------------------------------------- metadata --
        jobLog.append("status \(ProcessingStatus.fetchingMetadata.rawValue)")
        try await store.markStatus(videoID: video.id, jobID: jobID, status: .fetchingMetadata)

        var cachedTracks: [CaptionTrack]?
        let metadata: VideoMetadata
        do {
            let (fetched, tracks) = try await innerTube.fetchVideoInfo(videoID: video.youtubeVideoID)
            metadata = fetched
            cachedTracks = tracks
            jobLog.append(
                "metadata fetched title=\(fetched.title) channel=\(fetched.channel) "
                    + "duration_seconds=\(fetched.durationSeconds.map(String.init) ?? "nil")"
            )
        } catch {
            // Metadata is best-effort, never fatal — fall back to the
            // video-id-only stub.
            metadata = .stub(videoID: video.youtubeVideoID, url: video.canonicalURL)
            jobLog.append("metadata fallback because InnerTube fetch failed: \(error)")
        }
        let metadataJSON = jobDir.appendingPathComponent("metadata.json")
        try writeJSON(metadataJSON, [
            "id": metadata.videoID,
            "title": metadata.title,
            "channel": metadata.channel,
            "duration": metadata.durationSeconds as Any,
            "upload_date": metadata.publishedAt.replacingOccurrences(of: "-", with: ""),
            "webpage_url": metadata.url,
        ])

        // Surface fetched metadata immediately so manually-added videos stop
        // showing placeholders while the summary is still generating.
        try await store.updateMetadata(
            videoID: video.id,
            title: metadata.title != video.youtubeVideoID ? metadata.title : nil,
            channelName: metadata.channel,
            durationSeconds: metadata.durationSeconds.map(Double.init),
            thumbnailURL: YouTubeURL.thumbnailURL(videoID: video.youtubeVideoID)
        )

        // ----------------------------------------------------- transcript --
        jobLog.append("status \(ProcessingStatus.fetchingTranscript.rawValue)")
        try await store.markStatus(videoID: video.id, jobID: jobID, status: .fetchingTranscript)
        let transcript = try await fetchTranscript(
            youtubeVideoID: video.youtubeVideoID,
            cachedTracks: cachedTracks
        )
        try transcript.text.write(
            to: jobDir.appendingPathComponent("transcript.txt"),
            atomically: true, encoding: .utf8
        )
        try writeJSON(jobDir.appendingPathComponent("transcript-info.json"), [
            "language": transcript.language,
            "language_code": transcript.languageCode,
            "is_generated": transcript.isGenerated,
        ])
        jobLog.append(
            "transcript fetched language=\(transcript.languageCode) "
                + "generated=\(transcript.isGenerated) chars=\(transcript.text.count)"
        )

        // -------------------------------------------------------- summary --
        jobLog.append("status \(ProcessingStatus.generatingSummary.rawValue)")
        try await store.markStatus(videoID: video.id, jobID: jobID, status: .generatingSummary)

        let outputLanguage = self.outputLanguage()
        let prompt = try renderPrompt(metadata: metadata, transcript: transcript, outputLanguage: outputLanguage)
        try prompt.write(to: jobDir.appendingPathComponent("prompt.md"), atomically: true, encoding: .utf8)
        jobLog.append("prompt rendered chars=\(prompt.count) output_language=\(outputLanguage)")

        let (providerID, provider, settings) = try resolveProvider()
        if !settings.model.isEmpty {
            jobLog.append(
                "provider settings provider=\(providerID) model=\(settings.model) "
                    + "reasoning_effort=\(settings.reasoningEffort)"
            )
        }
        let runResult: ProviderRunResult
        do {
            runResult = try await provider.generateSummary(prompt: prompt, settings: settings)
        } catch let error as ProviderRunError {
            jobLog.append("provider failed provider=\(providerID): \(error)")
            throw Self.processingError(from: error, providerID: providerID)
        }
        try runResult.markdownBody.write(
            to: jobDir.appendingPathComponent("provider-output.md"),
            atomically: true, encoding: .utf8
        )
        jobLog.append("provider completed provider=\(providerID) output_chars=\(runResult.markdownBody.count)")

        let response = SummaryText.stripOuterMarkdownFence(runResult.markdownBody)
        do {
            try SummaryText.validateProviderResponse(response)
        } catch {
            throw ProcessingError(
                code: "summary_empty",
                userMessage: "Summary output is empty.",
                technicalMessage: "\(error)"
            )
        }

        let markdown = buildMarkdown(
            metadata: metadata,
            transcript: transcript,
            response: response,
            providerID: providerID,
            settings: settings,
            outputLanguage: outputLanguage
        )
        let summaryFile = jobDir.appendingPathComponent("summary.md")
        try markdown.write(to: summaryFile, atomically: true, encoding: .utf8)
        jobLog.append("summary.md written chars=\(markdown.count)")

        // ------------------------------------------------------ artifacts --
        let finalTranscript = videoDir.appendingPathComponent("transcript.txt")
        let finalMetadata = videoDir.appendingPathComponent("metadata.json")
        let finalSummary = videoDir.appendingPathComponent(
            Filenames.artifactFilename(title: metadata.title, fileExtension: "md")
        )
        try replaceFile(at: finalTranscript, withItemAt: jobDir.appendingPathComponent("transcript.txt"))
        try replaceFile(at: finalMetadata, withItemAt: metadataJSON)
        try replaceFile(at: finalSummary, withItemAt: summaryFile)

        try await store.markReady(
            videoID: video.id,
            jobID: jobID,
            transcriptPath: finalTranscript.path,
            summaryPath: finalSummary.path,
            summaryMarkdown: markdown,
            title: metadata.title,
            channelName: metadata.channel.isEmpty ? nil : metadata.channel,
            durationSeconds: metadata.durationSeconds.map(Double.init)
        )
        if let usage = runResult.usage {
            // Best-effort — usage capture must never fail the job.
            try? await store.setJobUsage(jobID: jobID, usage: usage)
            jobLog.append("usage recorded provider=\(usage.provider) total_tokens=\(usage.totalTokens)")
        }
        jobLog.append("ready summary_path=\(finalSummary.path)")
        logger.info("Job ready job=\(jobID, privacy: .public) youtube_id=\(video.youtubeVideoID, privacy: .public)")
    }

    // MARK: - Stages

    private func fetchTranscript(
        youtubeVideoID: String,
        cachedTracks: [CaptionTrack]?
    ) async throws -> TranscriptResult {
        let allowAny = EnvFile.parseBool(
            ProcessInfo.processInfo.environment["ALLOW_ANY_TRANSCRIPT_LANGUAGE"],
            default: true
        )
        do {
            if let tracks = cachedTracks {
                guard !tracks.isEmpty else {
                    throw InnerTubeError.transcriptsDisabled
                }
                let track = try TranscriptSelection.selectTrack(tracks, allowAny: allowAny)
                let text = try await innerTube.downloadTranscriptText(track: track)
                guard text.count >= 20 else {
                    throw InnerTubeError.emptyTranscript
                }
                return TranscriptResult(
                    text: text,
                    language: track.languageName,
                    languageCode: track.languageCode,
                    isGenerated: track.isGenerated
                )
            }
            return try await innerTube.fetchTranscript(videoID: youtubeVideoID, allowAny: allowAny)
        } catch let error as InnerTubeError {
            let code = error == .emptyTranscript ? "transcript_empty" : "transcript_unavailable"
            throw ProcessingError(
                code: code,
                userMessage: error == .emptyTranscript
                    ? "Transcript is empty."
                    : "Transcript is unavailable for this video.",
                technicalMessage: "\(error)"
            )
        }
    }

    private func renderPrompt(
        metadata: VideoMetadata,
        transcript: TranscriptResult,
        outputLanguage: String
    ) throws -> String {
        let template = try config.promptTemplate()
        let language = transcriptLanguageLabel(
            language: transcript.language,
            languageCode: transcript.languageCode,
            isGenerated: transcript.isGenerated
        )
        let prompt = SummaryText.renderTemplate(template, values: [
            "TITLE": metadata.title,
            "URL": metadata.url,
            "CHANNEL": metadata.channel,
            "DURATION": SummaryText.durationHMS(metadata.durationSeconds),
            "SUBTITLE_LANGUAGE": language,
            "TRANSCRIPT_LANGUAGE": language,
            "OUTPUT_LANGUAGE": outputLanguage,
            "TRANSCRIPT": transcript.text.trimmingTrailing(charactersIn: " \t\n\r"),
        ])
        return prompt.trimmingTrailing(charactersIn: " \t\n\r") + "\n"
    }

    /// Which provider actually runs: the UI selection drives codex/claude
    /// without a relaunch; anything else (e.g. `fake`) runs as configured.
    func resolveProvider() throws -> (id: String, provider: any SummaryProvider, settings: ProviderRunSettings) {
        if let providerOverride {
            return (
                providerOverride.id,
                providerOverride,
                ProviderRunSettings(timeout: config.providerTimeout)
            )
        }

        var providerID = config.provider
        if ProviderDescriptors.descriptor(for: providerID) != nil {
            let selected = setupStore.selectedProviderID()
            if ProviderDescriptors.descriptor(for: selected) != nil {
                providerID = selected
            }
        }

        guard let descriptor = ProviderDescriptors.descriptor(for: providerID) else {
            // Escape hatch: custom providers/<name>.sh keeps working.
            if let providersDirectory = config.providersDirectory {
                let script = providersDirectory.appendingPathComponent("\(providerID).sh")
                if FileManager.default.isExecutableFile(atPath: script.path) {
                    return (
                        providerID,
                        ScriptProvider(id: providerID, scriptURL: script),
                        ProviderRunSettings(timeout: config.providerTimeout)
                    )
                }
            }
            if providerID == "fake" {
                return (providerID, FakeProvider(), ProviderRunSettings(timeout: config.providerTimeout))
            }
            throw ProcessingError(
                code: "provider_not_found",
                userMessage: "Summary provider was not found.",
                technicalMessage: providerID
            )
        }

        let state = setupStore.load()
        guard let executablePath = resolveExecutablePath(descriptor: descriptor, state: state) else {
            throw ProcessingError(
                code: "provider_not_found",
                userMessage: "Summary provider was not found.",
                technicalMessage: "\(descriptor.binaryName) executable not found"
            )
        }
        let model = descriptor.validModel(state[descriptor.modelKey] as? String)
        // Effort is no longer user-configurable. Always run with "auto" so
        // the provider omits the effort flag and the CLI uses each model's
        // default, regardless of any value left in older stored setup state.
        let settings = ProviderRunSettings(model: model, reasoningEffort: "auto", timeout: config.providerTimeout)
        let provider: any SummaryProvider = descriptor.id == "claude"
            ? ClaudeProvider(executablePath: executablePath)
            : CodexProvider(executablePath: executablePath)
        return (descriptor.id, provider, settings)
    }

    private func resolveExecutablePath(descriptor: ProviderDescriptor, state: [String: Any]) -> String? {
        if let stored = state[descriptor.pathKey] as? String,
           FileManager.default.isExecutableFile(atPath: stored) {
            return stored
        }
        if let shellPath = ProviderDiagnostics.detectViaLoginShell(binaryName: descriptor.binaryName),
           FileManager.default.isExecutableFile(atPath: shellPath) {
            return shellPath
        }
        return descriptor.homebrewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func outputLanguage() -> String {
        let stored = setupStore.load()["outputLanguage"] as? String
        return OutputLanguage.normalize(
            (stored?.isEmpty == false ? stored : nil) ?? config.outputLanguage
        )
    }

    /// Front matter + body + credit footer. The field order is part of the
    /// saved-file format — keep it stable.
    func buildMarkdown(
        metadata: VideoMetadata,
        transcript: TranscriptResult,
        response: String,
        providerID: String,
        settings: ProviderRunSettings,
        outputLanguage: String
    ) -> String {
        let model: String
        if let descriptor = ProviderDescriptors.descriptor(for: providerID), !settings.model.isEmpty {
            // Prefer the option's display label (e.g. "Haiku 4.5") over the
            // raw CLI model id so the version is visible.
            let display = descriptor.modelDisplayLabel(settings.model)
            model = SummaryText.modelLabel(
                provider: providerID.prefix(1).uppercased() + providerID.dropFirst(),
                model: display,
                reasoningEffort: settings.reasoningEffort
            )
        } else {
            model = providerID
        }

        let frontMatter = SummaryText.yamlFrontMatter([
            ("type", .string("tubefold")),
            ("source", .string("youtube")),
            ("video_id", .string(metadata.videoID)),
            ("url", .string(metadata.url)),
            ("title", .string(metadata.title)),
            ("channel", .string(metadata.channel)),
            ("duration_seconds", metadata.durationSeconds.map(SummaryText.YAMLScalar.int) ?? .null),
            ("published_at", .string(metadata.publishedAt)),
            ("processed_at", .string(SummaryText.processedAtNow())),
            ("subtitle_language", .string(transcript.languageCode)),
            ("transcript_language", .string(transcript.language)),
            ("transcript_language_code", .string(transcript.languageCode)),
            ("transcript_is_generated", .bool(transcript.isGenerated)),
            ("output_language", .string(outputLanguage)),
            ("model", .string(model)),
            ("prompt_template", .string("detailed-summary")),
        ])
        return frontMatter
            + response.trimmingCharacters(in: .whitespacesAndNewlines)
            + "\n"
            + SummaryText.footerMarkdown()
    }

    // MARK: - Helpers

    static func processingError(from error: ProviderRunError, providerID: String) -> ProcessingError {
        switch error {
        case .executableNotFound:
            ProcessingError(
                code: "provider_not_found",
                userMessage: "Summary provider was not found.",
                technicalMessage: error.userMessage
            )
        case .timedOut:
            ProcessingError(
                code: "process_timeout",
                userMessage: "Processing timed out.",
                technicalMessage: error.userMessage
            )
        case let .processFailed(exitCode, detail, stderr):
            ProcessingError(
                code: ProviderDescriptors.descriptor(for: providerID) != nil
                    ? "\(providerID)_process_failed"
                    : "summary_process_failed",
                userMessage: ProviderFailure.userMessage(providerID: providerID, stderr: stderr),
                technicalMessage: "exit \(exitCode): \(detail)\n\(stderr)"
            )
        case .emptyOutput:
            ProcessingError(
                code: "summary_empty",
                userMessage: "Summary output is empty.",
                technicalMessage: error.userMessage
            )
        }
    }

    private func writeJSON(_ url: URL, _ object: [String: Any]) throws {
        // NSNull-ify Any-wrapped nils so JSONSerialization accepts them.
        let sanitized = object.mapValues { value -> Any in
            let mirror = Mirror(reflecting: value)
            if mirror.displayStyle == .optional, mirror.children.isEmpty {
                return NSNull()
            }
            if mirror.displayStyle == .optional, let child = mirror.children.first {
                return child.value
            }
            return value
        }
        let data = try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    private func replaceFile(at destination: URL, withItemAt source: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

/// Append-only per-job log file (`jobs/<id>/job.log`) — user-inspectable,
/// kept as artifact files like today.
struct JobLog {
    let url: URL

    init(directory: URL) {
        url = directory.appendingPathComponent("job.log")
    }

    func append(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
