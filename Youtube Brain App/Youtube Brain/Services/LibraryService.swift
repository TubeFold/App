import Foundation

struct LibraryService {
    private let baseURL = URL(string: "http://127.0.0.1:43821")!
    private let backend = BackendProcessController.shared

    func listVideos() async throws -> [LibraryVideo] {
        let response: VideoLibraryResponse = try await request(path: "/api/v1/videos")
        return response.videos
    }

    func regenerate(videoID: String) async throws {
        let _: RegenerateVideoResponse = try await request(path: "/api/v1/videos/\(videoID)/regenerate", method: "POST")
    }

    private func request<Response: Decodable>(path: String, method: String = "GET") async throws -> Response {
        try await backend.ensureRunning()

        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProviderSetupAPIError(message: "Invalid local API path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderSetupAPIError(message: "YouTube Brain returned an invalid response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw ProviderSetupAPIError(message: text)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as ProviderSetupAPIError {
            throw error
        } catch {
            throw ProviderSetupAPIError(message: "Could not load Library from YouTube Brain helper.")
        }
    }
}
