import Foundation
import Testing

@testable import TubeFoldKit

private let serverPlayerFixture = """
{
  "playabilityStatus": {"status": "OK"},
  "videoDetails": {"videoId": "dQw4w9WgXcQ", "title": "Server Demo", "author": "Chan", "lengthSeconds": "60"},
  "captions": {
    "playerCaptionsTracklistRenderer": {
      "captionTracks": [
        {"baseUrl": "https://timedtext.example/t", "name": {"simpleText": "English"}, "languageCode": "en", "kind": "asr"}
      ]
    }
  }
}
"""

private let serverTranscriptFixture = """
{"events": [{"segs": [{"utf8": "A transcript that is definitely long enough for validation."}]}]}
"""

private func makeBackend() throws -> (TubeFoldBackend, URL) {
    let dataDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tubefoldkit-server-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
    let transport: InnerTubeClient.Transport = { request in
        let url = request.url!
        let body = url.absoluteString.contains("youtubei/v1/player") ? serverPlayerFixture : serverTranscriptFixture
        return (Data(body.utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    let backend = TubeFoldBackend(
        config: PipelineConfiguration(dataDirectory: dataDir, provider: "fake"),
        store: try VideoStore.inMemory(),
        innerTube: InnerTubeClient(transport: transport),
        providerOverride: FakeProvider()
    )
    return (backend, dataDir)
}

/// HTTP client helper against the live NWListener.
private func httpRequest(
    port: UInt16,
    method: String,
    path: String,
    jsonBody: [String: Any]? = nil,
    origin: String? = nil
) async throws -> (status: Int, body: [String: Any]) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
    request.httpMethod = method
    request.timeoutInterval = 10
    if let origin {
        request.setValue(origin, forHTTPHeaderField: "Origin")
    }
    if let jsonBody {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    return (status, parsed)
}

@Suite(.serialized) struct ExtensionServerTests {
    // One shared port per run; NWListener with reuse makes sequential starts safe.
    private static let port: UInt16 = 43898

    private func withServer<T>(_ body: (TubeFoldBackend, UInt16) async throws -> T) async throws -> T {
        let (backend, dataDir) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let server = ExtensionServer(backend: backend, port: Self.port, apiToken: nil)
        try await server.start()
        defer { Task { await server.stop() } }
        do {
            let result = try await body(backend, Self.port)
            await server.stop()
            return result
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func healthAdvertisesAPIVersionAndFeatures() async throws {
        try await withServer { _, port in
            let (status, body) = try await httpRequest(port: port, method: "GET", path: "/health")
            #expect(status == 200)
            #expect(body["apiVersion"] as? Int == 1)
            let features = body["backendFeatures"] as? [String: Bool]
            #expect(features?["telegraphPublish"] == true)
            #expect(features?["watchActivity"] == true)
        }
    }

    @Test func summariesFlowEndToEnd() async throws {
        try await withServer { backend, port in
            let (status, body) = try await httpRequest(
                port: port, method: "POST", path: "/api/v1/summaries",
                jsonBody: ["url": "https://youtu.be/dQw4w9WgXcQ", "source": "chrome-extension"],
                origin: "chrome-extension://abcdef"
            )
            #expect(status == 202)
            #expect(body["status"] as? String == "queued")
            let videoID = body["videoId"] as? String
            #expect(videoID != nil)

            // Wait for the pipeline to finish the job.
            var ready = false
            for _ in 0 ..< 100 {
                let lookup = try await backend.videoLookupPayload(youtubeVideoID: "dQw4w9WgXcQ")
                if lookup["status"] as? String == "ready" {
                    ready = true
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(ready)

            // by-youtube-id lookup over HTTP (what the popup calls).
            let (lookupStatus, lookupBody) = try await httpRequest(
                port: port, method: "GET", path: "/api/v1/videos/by-youtube-id/dQw4w9WgXcQ"
            )
            #expect(lookupStatus == 200)
            #expect(lookupBody["exists"] as? Bool == true)
            #expect(lookupBody["status"] as? String == "ready")

            // Videos listing carries readingTimeMinutes.
            let (videosStatus, videosBody) = try await httpRequest(port: port, method: "GET", path: "/api/v1/videos")
            #expect(videosStatus == 200)
            let videos = videosBody["videos"] as? [[String: Any]]
            #expect(videos?.count == 1)
            #expect(videos?.first?["readingTimeMinutes"] as? Int ?? 0 >= 1)

            // The chrome-extension Origin marked the extension as connected.
            let (extStatus, extBody) = try await httpRequest(port: port, method: "GET", path: "/api/v1/extension-status")
            #expect(extStatus == 200)
            #expect(extBody["connected"] as? Bool == true)
        }
    }

    @Test func invalidURLReturnsAPIErrorShape() async throws {
        try await withServer { _, port in
            let (status, body) = try await httpRequest(
                port: port, method: "POST", path: "/api/v1/summaries",
                jsonBody: ["url": "https://vimeo.com/123"]
            )
            #expect(status == 400)
            let error = body["error"] as? [String: Any]
            #expect(error?["code"] as? String == "invalid_youtube_url")
            #expect(error?["message"] as? String == "The URL is not a supported YouTube video.")
        }
    }

    @Test func watchActivityRoundTrip() async throws {
        try await withServer { _, port in
            let (recordStatus, recordBody) = try await httpRequest(
                port: port, method: "POST", path: "/api/v1/watch-activity",
                jsonBody: ["url": "https://youtu.be/9bZkp7q19f0", "title": "Gangnam Style"]
            )
            #expect(recordStatus == 200)
            #expect(recordBody["status"] as? String == "recorded")

            let (getStatus, getBody) = try await httpRequest(port: port, method: "GET", path: "/api/v1/watch-activity")
            #expect(getStatus == 200)
            let suggestion = getBody["suggestion"] as? [String: Any]
            #expect(suggestion?["youtubeVideoID"] as? String == "9bZkp7q19f0")
            #expect(suggestion?["inLibrary"] as? Bool == false)

            let (dismissStatus, _) = try await httpRequest(
                port: port, method: "POST", path: "/api/v1/watch-activity/dismiss",
                jsonBody: ["youtubeVideoID": "9bZkp7q19f0"]
            )
            #expect(dismissStatus == 200)

            let (afterStatus, afterBody) = try await httpRequest(port: port, method: "GET", path: "/api/v1/watch-activity")
            #expect(afterStatus == 200)
            #expect(afterBody["suggestion"] is NSNull || afterBody["suggestion"] == nil)
        }
    }

    @Test func unknownEndpointIs404() async throws {
        try await withServer { _, port in
            let (status, body) = try await httpRequest(port: port, method: "GET", path: "/api/v1/nope")
            #expect(status == 404)
            #expect((body["error"] as? [String: Any])?["code"] as? String == "not_found")
        }
    }

    @Test func bearerTokenIsEnforcedWhenConfigured() async throws {
        let (backend, dataDir) = try makeBackend()
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let server = ExtensionServer(backend: backend, port: Self.port, apiToken: "sekret")
        try await server.start()
        defer { Task { await server.stop() } }

        let (unauthorized, _) = try await httpRequest(port: Self.port, method: "GET", path: "/api/v1/videos")
        #expect(unauthorized == 401)

        // /health stays open for liveness checks.
        let (health, _) = try await httpRequest(port: Self.port, method: "GET", path: "/health")
        #expect(health == 200)
        await server.stop()
    }
}
