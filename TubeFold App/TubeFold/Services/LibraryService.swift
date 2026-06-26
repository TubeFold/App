import Foundation

struct LibraryService {
    private let baseURL = URL(string: "http://127.0.0.1:43821")!
    private let backend = BackendProcessController.shared

    func listVideos() async throws -> [LibraryVideo] {
        let response: VideoLibraryResponse = try await request(path: "/api/v1/videos")
        return response.videos
    }

    func createSummary(url: String) async throws -> CreateSummaryResponse {
        try await request(
            path: "/api/v1/summaries",
            method: "POST",
            body: CreateSummaryRequest(url: url, source: "macos-app")
        )
    }

    func latestWatchSuggestion() async throws -> WatchSuggestion? {
        let response: WatchSuggestionResponse = try await request(path: "/api/v1/watch-activity")
        return response.suggestion
    }

    func dismissWatchSuggestion(youtubeID: String) async throws {
        let _: StatusResponse = try await request(
            path: "/api/v1/watch-activity/dismiss",
            method: "POST",
            body: DismissWatchRequest(youtubeVideoID: youtubeID)
        )
    }

    func regenerate(videoID: String) async throws {
        let _: RegenerateVideoResponse = try await request(path: "/api/v1/videos/\(videoID)/regenerate", method: "POST")
    }

    func publishTelegraph(videoID: String) async throws -> PublishTelegraphResponse {
        try await request(path: "/api/v1/videos/\(videoID)/publish-telegraph", method: "POST")
    }

    func delete(videoID: String) async throws {
        let _: DeleteVideoResponse = try await request(path: "/api/v1/videos/\(videoID)", method: "DELETE")
    }

    private func request<Response: Decodable>(path: String, method: String = "GET") async throws -> Response {
        try await request(path: path, method: method, body: Optional<CreateSummaryRequest>.none)
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        try await backend.ensureRunning()

        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProviderSetupAPIError(message: "Invalid local API path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderSetupAPIError(message: "TubeFold returned an invalid response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ProviderSetupAPIError(message: Self.errorMessage(from: data, status: httpResponse.statusCode))
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as ProviderSetupAPIError {
            throw error
        } catch {
            throw ProviderSetupAPIError(message: "Could not reach the TubeFold helper.")
        }
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return String(data: data, encoding: .utf8) ?? "HTTP \(status)"
    }
}

private struct APIErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
        let message: String
    }
    let error: Body
}
