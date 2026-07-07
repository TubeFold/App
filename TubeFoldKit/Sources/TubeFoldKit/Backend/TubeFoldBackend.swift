import Foundation
import os
import Synchronization

/// The one native backend facade: owns the store, the pipeline, the provider
/// setup store and Telegraph, and exposes the exact operations the old HTTP
/// API offered. The SwiftUI app calls these methods directly (no HTTP); the
/// `ExtensionServer` shim serializes the same payloads for the Chrome
/// extension — so the JSON contract lives in one place.
///
/// Payload dictionaries are the stable JSON shapes of the extension API.
/// A `Sendable` class (not an actor): all state is immutable references to
/// actors/stores, so methods stay nonisolated and their `[String: Any]`
/// payloads can cross isolation domains freely.
public final class TubeFoldBackend: Sendable {
    public static let apiVersion = 1

    public let config: PipelineConfiguration
    public let store: VideoStore
    public let setupStore: ProviderSetupStore
    public let pipeline: SummaryPipeline
    let telegraphClient: TelegraphClient

    /// Throttles `extension_last_seen` writes (one per 5 minutes).
    private let extensionSeenAt = Mutex<ContinuousClock.Instant?>(nil)
    /// The localhost shim owned by `startServing`/`stopServing`.
    private let extensionServer = Mutex<ExtensionServer?>(nil)

    /// Process-wide backend rooted at the default app data dir. The app talks
    /// to this instance directly; `startServing()` also brings up the Chrome
    /// extension shim.
    public static let shared: TubeFoldBackend = {
        do {
            return try TubeFoldBackend.live()
        } catch {
            fatalError("TubeFold could not open its data store: \(error)")
        }
    }()

    public init(
        config: PipelineConfiguration,
        store: VideoStore,
        innerTube: InnerTubeClient = InnerTubeClient(),
        telegraphClient: TelegraphClient = TelegraphClient(),
        providerOverride: (any SummaryProvider)? = nil
    ) {
        self.config = config
        self.store = store
        setupStore = ProviderSetupStore(dataDirectory: config.dataDirectory)
        self.telegraphClient = telegraphClient
        pipeline = SummaryPipeline(
            store: store,
            config: config,
            setupStore: setupStore,
            innerTube: innerTube,
            providerOverride: providerOverride
        )
    }

    /// On-disk production backend rooted at the app data dir.
    public static func live(
        dataDirectory: URL = PipelineConfiguration.defaultDataDirectory(),
        provider: String = ProcessInfo.processInfo.environment["TUBEFOLD_PROVIDER"] ?? "codex"
    ) throws -> TubeFoldBackend {
        let config = PipelineConfiguration(dataDirectory: dataDirectory, provider: provider)
        for directory in [config.videosDirectory, config.jobsDirectory, config.logsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let store = try VideoStore.onDisk(dataDirectory: dataDirectory)
        return TubeFoldBackend(config: config, store: store)
    }

    public func start() async {
        await pipeline.start()
    }

    public func stop() async {
        await pipeline.stop()
    }

    /// Start the pipeline (reclaims orphaned jobs, drains the queue) and the
    /// extension shim on 127.0.0.1:43821. Fire-and-forget for app launch.
    public func startServing(port: UInt16 = ExtensionServer.defaultPort) {
        Task {
            await pipeline.start()
            let server = ExtensionServer(backend: self, port: port)
            do {
                try await server.start()
                extensionServer.withLock { $0 = server }
            } catch {
                Logger(subsystem: "app.tubefold", category: "backend")
                    .error("Extension server failed to start: \(error)")
            }
        }
    }

    public func stopServing() {
        let server = extensionServer.withLock { server -> ExtensionServer? in
            defer { server = nil }
            return server
        }
        Task {
            await server?.stop()
            await pipeline.stop()
        }
    }

    /// Decode one of the facade's JSON-shaped payload dictionaries into a
    /// typed model (the same shapes the old HTTP API served).
    public static func decode<Response: Decodable>(_ payload: [String: Any]) throws -> Response {
        let data = try JSONSerialization.data(withJSONObject: payload)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Health

    public func healthPayload() -> [String: Any] {
        [
            "status": "ok",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "apiVersion": Self.apiVersion,
            // Kept as a plain capability map for the extension only — the
            // app itself no longer gates on this.
            "backendFeatures": [
                "codexModelSettings": true,
                "libraryRegenerate": true,
                "unlimitedTranscripts": true,
                "telegraphPublish": true,
                "outputLanguageSetting": true,
                "readingTime": true,
                "claudeProvider": true,
                "usageStats": true,
                "watchActivity": true,
                "libraryDelete": true,
                "resetData": true,
                "resetFirstRunState": true,
            ],
        ]
    }

    // MARK: - Summaries

    public struct SummaryOutcome: Sendable, Equatable {
        public let status: String
        public let videoID: String
        public let jobID: String?
    }

    /// `POST /api/v1/summaries` — parse/normalize the URL, dedupe, enqueue.
    public func createSummary(
        rawURL: String,
        rawVideoID: String? = nil,
        title: String? = nil,
        channelName: String? = nil,
        durationSeconds: Double? = nil,
        currentTimeSeconds: Double? = nil,
        thumbnailURL: String? = nil,
        source: String = "chrome-extension",
        forceRegenerate: Bool = false
    ) async throws -> SummaryOutcome {
        let videoID: String
        let canonicalURL: String
        do {
            videoID = try YouTubeURL.parseVideoID(
                (rawVideoID?.isEmpty == false ? rawVideoID! : rawURL)
            )
            canonicalURL = try YouTubeURL.normalize(rawURL.isEmpty ? videoID : rawURL)
        } catch {
            throw BackendAPIError.invalidYouTubeURL
        }

        let request = SummaryRequest(
            videoID: videoID,
            url: canonicalURL,
            title: optionalString(title),
            channelName: optionalString(channelName),
            durationSeconds: durationSeconds,
            currentTimeSeconds: currentTimeSeconds,
            thumbnailURL: optionalString(thumbnailURL),
            source: optionalString(source) ?? "chrome-extension"
        )
        let (outcome, videoRecordID, jobID) = try await store.createOrReuse(
            request,
            forceRegenerate: forceRegenerate
        )
        if outcome == .queued {
            await pipeline.notify()
        }
        return SummaryOutcome(status: outcome.rawValue, videoID: videoRecordID, jobID: jobID)
    }

    /// `POST /api/v1/videos/{id}/regenerate`.
    public func regenerate(videoID: String) async throws -> SummaryOutcome {
        guard let video = try await store.getVideo(id: videoID) else {
            throw BackendAPIError.notFound("Video was not found.")
        }
        let request = SummaryRequest(
            videoID: video.youtubeVideoID,
            url: video.canonicalURL,
            title: video.title,
            channelName: video.channelName,
            durationSeconds: video.durationSeconds,
            thumbnailURL: video.thumbnailURL
        )
        let (_, videoRecordID, jobID) = try await store.createOrReuse(request, forceRegenerate: true)
        await pipeline.notify()
        return SummaryOutcome(status: "queued", videoID: videoRecordID, jobID: jobID)
    }

    /// `DELETE /api/v1/videos/{id}` — removes the row and its on-disk artifacts.
    public func deleteVideo(videoID: String) async throws {
        guard let youtubeID = try await store.deleteVideo(id: videoID) else {
            throw BackendAPIError.notFound("Video was not found.")
        }
        // Best-effort artifact cleanup; a missing dir is fine. The worker
        // tolerates a vanished video row, so deleting mid-processing is safe.
        try? FileManager.default.removeItem(at: config.videosDirectory.appendingPathComponent(youtubeID))
    }

    /// `POST /api/v1/reset` — wipe rows + `videos/`/`jobs/`/`logs/` dirs;
    /// provider sign-in/settings and the Telegraph account are kept (it's a
    /// library/usage wipe, not a full re-onboard).
    public func resetAllData() async throws -> [String: Int] {
        let removed = try await store.reset()
        for directory in [config.videosDirectory, config.jobsDirectory, config.logsDirectory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return removed
    }

    /// Testing/dev reset: simulate a fresh install as closely as possible
    /// without touching external accounts such as Telegraph.
    public func resetFirstRunState() async throws -> [String: Int] {
        var removed = try await store.reset(includeAppMeta: true)
        for directory in [config.videosDirectory, config.jobsDirectory, config.logsDirectory] {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        removed["provider_setup"] = try setupStore.reset() ? 1 : 0
        return removed
    }

    // MARK: - Library payloads

    public func listVideoPayloads() async throws -> [[String: Any]] {
        try await store.listVideos().map { videoPayload($0) }
    }

    public func videoPayload(_ video: VideoRecord) -> [String: Any] {
        let readingTime: Int? = if let markdown = video.summaryMarkdown,
                                   !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ReadingTime.readingMinutes(forMarkdown: markdown)
        } else {
            nil
        }
        // Path to the latest job's per-stage logs, so the app can offer
        // "Show Logs" on failure. Only set when the dir exists.
        var jobLogPath: String?
        if let latestJobID = video.latestJob?.id {
            let candidate = config.jobsDirectory.appendingPathComponent(latestJobID)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                jobLogPath = candidate.path
            }
        }
        return [
            "id": video.id,
            "youtubeVideoID": video.youtubeVideoID,
            "canonicalURL": video.canonicalURL,
            "title": video.title as Any,
            "channelName": video.channelName as Any,
            "thumbnailURL": (video.thumbnailURL?.isEmpty == false
                ? video.thumbnailURL!
                : YouTubeURL.thumbnailURL(videoID: video.youtubeVideoID)),
            "durationSeconds": video.durationSeconds as Any,
            "currentTimeAtRequest": video.currentTimeAtRequest as Any,
            "createdAt": isoString(video.createdAt),
            "updatedAt": isoString(video.updatedAt),
            "status": video.status.rawValue,
            "transcriptPath": video.transcriptPath as Any,
            "summaryPath": video.summaryPath as Any,
            "errorCode": video.errorCode as Any,
            "errorMessage": video.errorMessage as Any,
            "latestJobID": video.latestJob?.id as Any,
            "latestJobStatus": video.latestJob?.status.rawValue as Any,
            "latestJobCreatedAt": video.latestJob.map { isoString($0.createdAt) } as Any,
            "latestJobFinishedAt": video.latestJob?.finishedAt.map { isoString($0) } as Any,
            "telegraphURL": video.telegraphURL as Any,
            "readingTimeMinutes": readingTime as Any,
            "jobLogPath": jobLogPath as Any,
        ]
    }

    public func videoLookupPayload(youtubeVideoID: String) async throws -> [String: Any] {
        guard let video = try await store.getVideo(youtubeVideoID: youtubeVideoID) else {
            return ["exists": false]
        }
        return ["exists": true, "videoId": video.id, "status": video.status.rawValue]
    }

    public func jobPayload(jobID: String) async throws -> [String: Any] {
        guard let job = try await store.getJob(id: jobID) else {
            throw BackendAPIError.notFound("Job was not found.")
        }
        return [
            "jobId": job.id,
            "status": job.status.rawValue,
            "progress": NSNull(),
            "error": job.errorMessage as Any,
        ]
    }

    // MARK: - Watch activity

    public func recordWatchActivity(
        rawURL: String,
        rawVideoID: String? = nil,
        title: String? = nil,
        channelName: String? = nil,
        thumbnailURL: String? = nil,
        durationSeconds: Double? = nil
    ) async throws {
        let videoID: String
        let canonicalURL: String
        do {
            videoID = try YouTubeURL.parseVideoID(rawVideoID?.isEmpty == false ? rawVideoID! : rawURL)
            canonicalURL = try YouTubeURL.normalize(rawURL.isEmpty ? videoID : rawURL)
        } catch {
            throw BackendAPIError.invalidYouTubeURL
        }
        try await store.recordWatchActivity(
            youtubeVideoID: videoID,
            canonicalURL: canonicalURL,
            title: optionalString(title),
            channelName: optionalString(channelName),
            thumbnailURL: optionalString(thumbnailURL),
            durationSeconds: durationSeconds
        )
    }

    public func dismissWatchActivity(rawVideoID: String) async throws {
        guard let videoID = try? YouTubeURL.parseVideoID(rawVideoID) else {
            throw BackendAPIError.invalidYouTubeURL
        }
        try await store.dismissWatchActivity(youtubeVideoID: videoID)
    }

    public func watchSuggestionPayload() async throws -> [String: Any]? {
        guard let suggestion = try await store.latestWatchSuggestion() else {
            return nil
        }
        return [
            "youtubeVideoID": suggestion.youtubeVideoID,
            "canonicalURL": suggestion.canonicalURL,
            "title": suggestion.title as Any,
            "channelName": suggestion.channelName as Any,
            "thumbnailURL": (suggestion.thumbnailURL?.isEmpty == false
                ? suggestion.thumbnailURL!
                : YouTubeURL.thumbnailURL(videoID: suggestion.youtubeVideoID)),
            "durationSeconds": suggestion.durationSeconds as Any,
            "watchedAt": isoString(suggestion.watchedAt),
            // The suggestion query already skips library videos; the columns
            // stay in the payload for a stable shape.
            "inLibrary": false,
            "libraryVideoID": NSNull(),
            "libraryStatus": NSNull(),
        ]
    }

    // MARK: - Extension presence

    /// Remember that the Chrome extension just talked to us (throttled).
    public func noteExtensionSeen() async {
        let now = ContinuousClock.now
        let shouldWrite = extensionSeenAt.withLock { last -> Bool in
            if let last, last.duration(to: now) < .seconds(300) {
                return false
            }
            last = now
            return true
        }
        guard shouldWrite else { return }
        try? await store.markExtensionSeen()
    }

    public func extensionStatusPayload() async throws -> [String: Any] {
        let lastSeen = try await store.extensionLastSeen()
        return [
            "connected": Self.extensionConnected(lastSeen: lastSeen),
            "lastSeenAt": lastSeen as Any,
        ]
    }

    /// True if the extension has talked to the backend within `maxAgeDays`;
    /// missing or stale reads as "not installed" so the app keeps nudging.
    static func extensionConnected(lastSeen: String?, maxAgeDays: Int = 30) -> Bool {
        guard let lastSeen, !lastSeen.isEmpty else { return false }
        let parser = ISO8601DateFormatter()
        guard let seen = parser.date(from: lastSeen) ?? Self.fallbackISODate(lastSeen) else {
            return false
        }
        return Date().timeIntervalSince(seen) <= Double(maxAgeDays) * 86_400
    }

    private static func fallbackISODate(_ value: String) -> Date? {
        // Be lenient about timestamps without a timezone (assume UTC).
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value)
    }

    // MARK: - Usage

    public func usagePayload() async throws -> [String: Any] {
        let summary = try await store.usageSummary()
        var byProvider: [String: Any] = [:]
        for (provider, totals) in summary.byProvider {
            byProvider[provider] = [
                "jobs": totals.jobs,
                "inputTokens": totals.inputTokens,
                "outputTokens": totals.outputTokens,
                "totalTokens": totals.totalTokens,
                "costUsd": totals.costUSD as Any,
            ]
        }
        return ["totalTokens": summary.totalTokens, "byProvider": byProvider]
    }

    // MARK: - Telegraph

    public func publishTelegraph(videoID: String) async throws -> TelegraphPublishResult {
        guard let video = try await store.getVideo(id: videoID) else {
            throw BackendAPIError.notFound("Video was not found.")
        }
        guard video.status == .ready else {
            throw BackendAPIError.conflict("The summary is not ready to publish yet.")
        }
        let publisher = TelegraphPublisher(
            dataDirectory: config.dataDirectory,
            videoStore: store,
            client: telegraphClient
        )
        do {
            return try await publisher.publish(videoID: videoID)
        } catch let error as TelegraphError {
            throw BackendAPIError.telegraphFailed(error.userMessage)
        }
    }

    // MARK: - Provider setup

    public func diagnostics(for providerID: String?) -> ProviderDiagnostics {
        let descriptor = ProviderDescriptors.descriptor(for: providerID) ?? ProviderDescriptors.codex
        return ProviderDiagnostics(descriptor: descriptor, store: setupStore)
    }

    public func selectedDiagnostics() -> ProviderDiagnostics {
        diagnostics(for: setupStore.selectedProviderID())
    }

    private func modelOptionsPayload(_ descriptor: ProviderDescriptor) -> [String: Any] {
        [
            "modelOptions": descriptor.modelOptions.map { ["id": $0.id, "label": $0.label, "description": $0.description] },
            "reasoningEffortOptions": descriptor.effortOptions.map { ["id": $0.id, "label": $0.label, "description": $0.description] },
        ]
    }

    private func providerSummariesPayload() -> [[String: Any]] {
        providerSummaries(store: setupStore).map { summary in
            [
                "id": summary.id,
                "displayName": summary.displayName,
                "configured": summary.configured,
                "executablePath": summary.executablePath as Any,
                "version": summary.version as Any,
            ]
        }
    }

    /// `GET /api/v1/provider-setup`.
    public func providerSetupPayload() -> [String: Any] {
        let diagnostics = selectedDiagnostics()
        var payload: [String: Any] = [
            "provider": diagnostics.providerID,
            "state": setupStore.load(),
            "providers": providerSummariesPayload(),
        ]
        for (key, value) in modelOptionsPayload(diagnostics.descriptor) {
            payload[key] = value
        }
        return payload
    }

    /// `POST /api/v1/provider-setup/select`.
    public func selectProvider(_ providerID: String) throws -> [String: Any] {
        guard let descriptor = ProviderDescriptors.descriptor(for: providerID) else {
            throw BackendAPIError.badRequest(code: "invalid_provider", message: "Unknown provider.")
        }
        let state = try setupStore.select(providerID: providerID)
        var payload: [String: Any] = [
            "status": "selected",
            "provider": providerID,
            "state": state,
            "providers": providerSummariesPayload(),
        ]
        for (key, value) in modelOptionsPayload(descriptor) {
            payload[key] = value
        }
        return payload
    }

    /// `POST /api/v1/provider-setup/{provider}/model`.
    public func saveModelSettings(providerID: String, model: String?, reasoningEffort: String?) throws -> [String: Any] {
        let diagnostics = diagnostics(for: providerID)
        let state = try diagnostics.saveModelSettings(model: model, reasoningEffort: reasoningEffort)
        var payload: [String: Any] = [
            "status": "saved",
            "provider": diagnostics.providerID,
            "state": state,
        ]
        for (key, value) in modelOptionsPayload(diagnostics.descriptor) {
            payload[key] = value
        }
        return payload
    }

    /// `POST /api/v1/provider-setup/output-language`.
    public func saveOutputLanguage(_ value: String?) throws -> [String: Any] {
        let diagnostics = selectedDiagnostics()
        let state = try setupStore.update(["outputLanguage": OutputLanguage.normalize(value)])
        var payload: [String: Any] = [
            "status": "saved",
            "provider": diagnostics.providerID,
            "state": state,
        ]
        for (key, value) in modelOptionsPayload(diagnostics.descriptor) {
            payload[key] = value
        }
        return payload
    }

    /// `POST /api/v1/provider-setup/complete`.
    public func completeProviderSetup() throws -> [String: Any] {
        let diagnostics = selectedDiagnostics()
        let state = try diagnostics.completeSetup()
        return ["status": "completed", "provider": diagnostics.providerID, "state": state]
    }

    /// `POST /api/v1/provider-setup/{provider}/detect` — detection result
    /// as an API-shaped payload.
    public func detectProviderInstallation(providerID: String, path: String? = nil) async -> [String: Any] {
        let diagnostics = diagnostics(for: providerID)
        let result = await diagnostics.detectInstallation(requestedPath: path)
        return [
            "status": result.status.rawValue,
            "provider": result.provider,
            "displayName": result.displayName,
            "path": result.path as Any,
            "version": result.version as Any,
            "checkedPaths": result.checkedPaths,
            "userMessage": result.userMessage,
            "details": [
                "executablePath": result.path as Any,
                "version": result.version as Any,
                "timestamp": isoString(Date()),
                "errorCategory": result.status == .installed
                    ? "none"
                    : (result.status == .notInstalled ? "installationMissing" : "installationInvalid"),
            ] as [String: Any],
        ]
    }

    /// `POST /api/v1/provider-setup/{provider}/test` — connection-test result
    /// as an API-shaped payload.
    public func testProviderConnection(providerID: String, path: String? = nil) async -> [String: Any] {
        let diagnostics = diagnostics(for: providerID)
        let result = await diagnostics.testConnection(executablePath: path)
        var details: [String: Any] = [
            "errorCategory": Self.errorCategory(for: result.status),
            "timestamp": isoString(Date()),
            "stderrExcerpt": result.stderrExcerpt,
            "stdoutExcerpt": result.stdoutExcerpt,
        ]
        if let executablePath = result.executablePath {
            details["executablePath"] = executablePath
        }
        if let model = result.model {
            details["model"] = model
        }
        if let exitCode = result.exitCode {
            details["exitCode"] = Int(exitCode)
        }
        if let duration = result.durationSeconds {
            details["durationSeconds"] = (duration * 100).rounded() / 100
        }
        return [
            "status": result.status.rawValue,
            "provider": result.provider,
            "userMessage": result.userMessage,
            "details": details,
        ]
    }

    /// Category names surfaced in the `details.errorCategory` field the app
    /// renders.
    static func errorCategory(for status: ConnectionTestStatus) -> String {
        switch status {
        case .success: "success"
        case .networkError: "networkUnavailable"
        case .invalidResponse: "invalidOutput"
        case .installationMissing: "installationMissing"
        case .installationInvalid: "installationInvalid"
        default: status.rawValue
        }
    }

    // MARK: - Helpers

    func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func optionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// API-shaped errors (`{code, message}` + HTTP status) shared by the app
/// facade and the extension shim.
public enum BackendAPIError: Error, Sendable, Equatable {
    case invalidYouTubeURL
    case notFound(String)
    case conflict(String)
    case telegraphFailed(String)
    case badRequest(code: String, message: String)

    public var code: String {
        switch self {
        case .invalidYouTubeURL: "invalid_youtube_url"
        case .notFound: "not_found"
        case .conflict: "not_ready"
        case .telegraphFailed: "telegraph_failed"
        case let .badRequest(code, _): code
        }
    }

    public var message: String {
        switch self {
        case .invalidYouTubeURL: "The URL is not a supported YouTube video."
        case let .notFound(message): message
        case let .conflict(message): message
        case let .telegraphFailed(message): message
        case let .badRequest(_, message): message
        }
    }

    public var httpStatus: Int {
        switch self {
        case .invalidYouTubeURL, .badRequest: 400
        case .notFound: 404
        case .conflict: 409
        case .telegraphFailed: 502
        }
    }
}
