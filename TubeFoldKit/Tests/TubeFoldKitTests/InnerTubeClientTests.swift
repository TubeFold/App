import Foundation
import Testing

@testable import TubeFoldKit

// MARK: - Fixtures

private let androidPlayerJSON = """
{
  "playabilityStatus": {"status": "OK"},
  "videoDetails": {
    "videoId": "dQw4w9WgXcQ",
    "title": "Never Gonna Give You Up",
    "author": "Rick Astley",
    "lengthSeconds": "213"
  },
  "microformat": {
    "playerMicroformatRenderer": {
      "publishDate": "2009-10-24T00:00:00-07:00",
      "uploadDate": "2009-10-24T00:00:00-07:00"
    }
  },
  "captions": {
    "playerCaptionsTracklistRenderer": {
      "captionTracks": [
        {
          "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en&kind=asr",
          "name": {"runs": [{"text": "English (auto-generated)"}]},
          "languageCode": "en",
          "kind": "asr"
        },
        {
          "baseUrl": "https://www.youtube.com/api/timedtext?v=dQw4w9WgXcQ&lang=en",
          "name": {"simpleText": "English"},
          "languageCode": "en"
        }
      ]
    }
  }
}
"""

private let loginRequiredJSON = """
{"playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"}}
"""

private let noCaptionsPlayerJSON = """
{
  "playabilityStatus": {"status": "OK"},
  "videoDetails": {"videoId": "dQw4w9WgXcQ", "title": "Captionless", "author": "Someone", "lengthSeconds": "10"}
}
"""

private let json3Fixture = """
{
  "events": [
    {"segs": [{"utf8": "Never gonna "}, {"utf8": "give you up"}]},
    {"segs": [{"utf8": "\\n"}]},
    {"segs": [{"utf8": "  never gonna let you down  "}]},
    {}
  ]
}
"""

/// Transport stub: answers player POSTs per-client and timedtext GETs with json3.
private func stubTransport(
    playerBodies: [String: String],
    transcriptBody: String = json3Fixture,
    status: Int = 200
) -> InnerTubeClient.Transport {
    { request in
        let url = request.url!
        let body: String
        if url.absoluteString.contains("youtubei/v1/player") {
            let payload = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
            let context = payload?["context"] as? [String: Any]
            let client = context?["client"] as? [String: Any]
            let name = client?["clientName"] as? String ?? "?"
            guard let configured = playerBodies[name] else {
                throw URLError(.cannotFindHost)
            }
            body = configured
        } else {
            body = transcriptBody
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

// MARK: - Tests

@Suite struct InnerTubeClientTests {
    @Test func playerResponseDecoding() async throws {
        let client = InnerTubeClient(transport: stubTransport(playerBodies: ["ANDROID": androidPlayerJSON]))
        let (metadata, tracks) = try await client.fetchVideoInfo(videoID: "dQw4w9WgXcQ")

        #expect(metadata.videoID == "dQw4w9WgXcQ")
        #expect(metadata.title == "Never Gonna Give You Up")
        #expect(metadata.channel == "Rick Astley")
        #expect(metadata.durationSeconds == 213)
        #expect(metadata.publishedAt == "2009-10-24")
        #expect(metadata.url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")

        #expect(tracks.count == 2)
        #expect(tracks[0].isGenerated)
        #expect(tracks[0].languageName == "English (auto-generated)")
        #expect(!tracks[1].isGenerated)
        #expect(tracks[1].languageName == "English")
    }

    @Test func fullTranscriptFlowSelectsManualTrack() async throws {
        let client = InnerTubeClient(transport: stubTransport(playerBodies: ["ANDROID": androidPlayerJSON]))
        let transcript = try await client.fetchTranscript(videoID: "dQw4w9WgXcQ")

        #expect(transcript.text == "Never gonna give you up never gonna let you down")
        #expect(transcript.languageCode == "en")
        #expect(transcript.language == "English")
        #expect(!transcript.isGenerated)
    }

    @Test func fallsBackToNextClientWhenBlocked() async throws {
        // ANDROID is refused; IOS delivers — the exp=xpe mitigation.
        let client = InnerTubeClient(transport: stubTransport(playerBodies: [
            "ANDROID": loginRequiredJSON,
            "IOS": androidPlayerJSON,
        ]))
        let (metadata, tracks) = try await client.fetchVideoInfo(videoID: "dQw4w9WgXcQ")
        #expect(metadata.title == "Never Gonna Give You Up")
        #expect(!tracks.isEmpty)
    }

    @Test func fallsBackWhenClientServedNoCaptions() async throws {
        // ANDROID answers but without captions; IOS still has them.
        let client = InnerTubeClient(transport: stubTransport(playerBodies: [
            "ANDROID": noCaptionsPlayerJSON,
            "IOS": androidPlayerJSON,
        ]))
        let (_, tracks) = try await client.fetchVideoInfo(videoID: "dQw4w9WgXcQ")
        #expect(tracks.count == 2)
    }

    @Test func captionlessEverywhereStillYieldsMetadata() async throws {
        let client = InnerTubeClient(transport: stubTransport(playerBodies: [
            "ANDROID": noCaptionsPlayerJSON,
            "IOS": noCaptionsPlayerJSON,
            "TVHTML5": noCaptionsPlayerJSON,
        ]))
        let (metadata, tracks) = try await client.fetchVideoInfo(videoID: "dQw4w9WgXcQ")
        #expect(metadata.title == "Captionless")
        #expect(tracks.isEmpty)

        await #expect(throws: InnerTubeError.transcriptsDisabled) {
            try await client.fetchTranscript(videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func allClientsBlockedSurfacesFirstError() async {
        let client = InnerTubeClient(transport: stubTransport(playerBodies: [
            "ANDROID": loginRequiredJSON,
            "IOS": loginRequiredJSON,
            "TVHTML5": loginRequiredJSON,
        ]))
        await #expect(throws: InnerTubeError.unplayable(
            status: "LOGIN_REQUIRED",
            reason: "Sign in to confirm you're not a bot"
        )) {
            try await client.fetchVideoInfo(videoID: "dQw4w9WgXcQ")
        }
    }

    @Test func invalidVideoIDIsRejectedBeforeAnyRequest() async {
        let client = InnerTubeClient(transport: { _ in throw URLError(.badURL) })
        await #expect(throws: InnerTubeError.invalidVideoID("VIDEO_ID")) {
            try await client.fetchVideoInfo(videoID: "VIDEO_ID")
        }
    }

    @Test func json3Parsing() throws {
        let text = try InnerTubeClient.json3ToText(Data(json3Fixture.utf8))
        #expect(text == "Never gonna give you up never gonna let you down")
    }

    @Test func timedTextSniffsJSONAndXML() throws {
        // json3 payloads still parse.
        #expect(try InnerTubeClient.timedTextToText(Data(json3Fixture.utf8))
            == "Never gonna give you up never gonna let you down")

        // srv3 XML (what the signed baseUrl actually serves) with entities.
        let srv3 = """
        <?xml version="1.0" encoding="utf-8" ?><timedtext format="3">
        <body>
        <p t="1360" d="1680">We&#39;re no strangers\nto love</p>
        <p t="18640" d="3240">You know the rules</p>
        </body>
        </timedtext>
        """
        #expect(try InnerTubeClient.timedTextToText(Data(srv3.utf8))
            == "We're no strangers to love You know the rules")

        // srv1 XML with <text> elements.
        let srv1 = """
        <?xml version="1.0" encoding="utf-8" ?><transcript>
        <text start="1.36" dur="1.68">Hello &amp; welcome</text>
        <text start="3.1" dur="2.0">to the show</text>
        </transcript>
        """
        #expect(try InnerTubeClient.timedTextToText(Data(srv1.utf8)) == "Hello & welcome to the show")

        #expect(throws: InnerTubeError.noTranscript) {
            try InnerTubeClient.timedTextToText(Data("not xml or json".utf8))
        }
    }

    @Test func dateOnlyNormalization() {
        #expect(PlayerResponse.dateOnly("2024-05-01") == "2024-05-01")
        #expect(PlayerResponse.dateOnly("2024-05-01T00:00:00-07:00") == "2024-05-01")
        #expect(PlayerResponse.dateOnly("") == "")
        #expect(PlayerResponse.dateOnly("garbage") == "")
    }

    @Test func metadataStub() {
        let stub = VideoMetadata.stub(videoID: "abc123def45", url: "https://www.youtube.com/watch?v=abc123def45")
        #expect(stub.title == "abc123def45")
        #expect(stub.channel == "")
        #expect(stub.durationSeconds == nil)
    }
}
