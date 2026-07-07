import Foundation
import TubeFoldKit

// Debug harness for the InnerTube path. Prints the metadata, caption tracks
// and (optionally) the transcript as JSON so live runs can be inspected:
//
//   swift run tubefold-harness <url-or-video-id> [--transcript] [--allow-any true|false]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let target = arguments.first else {
    fail("usage: tubefold-harness <url-or-video-id> [--transcript] [--allow-any true|false]")
}

// Debug: inspect the live extension-status payload against the real data dir.
if target == "--extension-status" {
    let backend = try TubeFoldBackend.live()
    let payload = try await backend.extensionStatusPayload()
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    exit(0)
}
let includeTranscript = arguments.contains("--transcript")
var allowAny = true
if let flagIndex = arguments.firstIndex(of: "--allow-any"), flagIndex + 1 < arguments.count {
    allowAny = EnvFile.parseBool(arguments[flagIndex + 1], default: true)
}

let videoID: String
do {
    videoID = try YouTubeURL.parseVideoID(target)
} catch {
    fail("error: \(error.localizedDescription)")
}

let client = InnerTubeClient()
do {
    let (metadata, tracks) = try await client.fetchVideoInfo(videoID: videoID)
    var output: [String: Any] = [
        "metadata": [
            "id": metadata.videoID,
            "title": metadata.title,
            "channel": metadata.channel,
            "duration": metadata.durationSeconds as Any,
            "upload_date": metadata.publishedAt.replacingOccurrences(of: "-", with: ""),
            "webpage_url": metadata.url,
        ],
        "tracks": tracks.map { [
            "language": $0.languageName,
            "language_code": $0.languageCode,
            "is_generated": $0.isGenerated,
        ] },
    ]
    if includeTranscript {
        let transcript = try await client.fetchTranscript(videoID: videoID, allowAny: allowAny)
        output["transcript_info"] = [
            "language": transcript.language,
            "language_code": transcript.languageCode,
            "is_generated": transcript.isGenerated,
            "chars": transcript.text.count,
        ]
        output["transcript_text"] = transcript.text
    }
    let data = try JSONSerialization.data(
        withJSONObject: output,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    print(String(decoding: data, as: UTF8.self))
} catch let error as InnerTubeError {
    fail("error: \(error) — \(error.userMessage)")
} catch {
    fail("error: \(error.localizedDescription)")
}
