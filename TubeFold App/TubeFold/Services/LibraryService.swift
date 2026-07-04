import Foundation
import TubeFoldKit

/// Library operations — direct calls into the in-process backend (the old
/// localhost HTTP round-trips are gone; the payload shapes are unchanged).
struct LibraryService {
    private var backend: TubeFoldBackend {
        TubeFoldBackend.shared
    }

    func listVideos() async throws -> [LibraryVideo] {
        try await mapErrors {
            let payloads = try await backend.listVideoPayloads()
            return try TubeFoldBackend.decode(["videos": payloads]) as VideoLibraryResponse
        }.videos
    }

    func createSummary(url: String) async throws -> CreateSummaryResponse {
        try await mapErrors {
            let outcome = try await backend.createSummary(rawURL: url, source: "macos-app")
            return CreateSummaryResponse(jobId: outcome.jobID, videoId: outcome.videoID, status: outcome.status)
        }
    }

    func latestWatchSuggestion() async throws -> WatchSuggestion? {
        try await mapErrors {
            guard let payload = try await backend.watchSuggestionPayload() else { return nil }
            return try TubeFoldBackend.decode(payload) as WatchSuggestion
        }
    }

    func extensionStatus() async throws -> ExtensionStatus {
        try await mapErrors {
            try await TubeFoldBackend.decode(backend.extensionStatusPayload())
        }
    }

    func dismissWatchSuggestion(youtubeID: String) async throws {
        try await mapErrors {
            try await backend.dismissWatchActivity(rawVideoID: youtubeID)
        }
    }

    func regenerate(videoID: String) async throws {
        try await mapErrors {
            _ = try await backend.regenerate(videoID: videoID)
        }
    }

    func publishTelegraph(videoID: String) async throws -> PublishTelegraphResponse {
        try await mapErrors {
            let result = try await backend.publishTelegraph(videoID: videoID)
            return PublishTelegraphResponse(url: result.url, status: result.status)
        }
    }

    func delete(videoID: String) async throws {
        try await mapErrors {
            try await backend.deleteVideo(videoID: videoID)
        }
    }

    private func mapErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as BackendAPIError {
            throw ProviderSetupAPIError(message: error.message)
        } catch let error as ProviderSetupAPIError {
            throw error
        } catch {
            throw ProviderSetupAPIError(message: error.localizedDescription)
        }
    }
}
