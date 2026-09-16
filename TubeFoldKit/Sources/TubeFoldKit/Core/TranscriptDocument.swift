import Foundation

/// The saved-file format for a raw transcript (no model involved).
///
/// Same invariant as the summary format: the YAML front matter is generated
/// here, and the publish date leads both the front matter and the visible
/// header so a folder of transcripts reads chronologically.
public enum TranscriptDocument {
    public static let undatedPrefix = "undated"

    /// Full `.md` contents for one video's transcript.
    public static func markdown(
        metadata: VideoMetadata,
        transcript: TranscriptResult,
        fetchedAt: Date = Date()
    ) -> String {
        let frontMatter = SummaryText.yamlFrontMatter([
            ("type", .string("tubefold-transcript")),
            ("source", .string("youtube")),
            ("video_id", .string(metadata.videoID)),
            ("url", .string(metadata.url)),
            ("title", .string(metadata.title)),
            ("channel", .string(metadata.channel)),
            ("duration_seconds", metadata.durationSeconds.map(SummaryText.YAMLScalar.int) ?? .null),
            ("published_at", .string(metadata.publishedAt)),
            ("fetched_at", .string(SummaryText.processedAtNow(fetchedAt))),
            ("transcript_language", .string(transcript.language)),
            ("transcript_language_code", .string(transcript.languageCode)),
            ("transcript_is_generated", .bool(transcript.isGenerated)),
        ])

        var facts: [String] = []
        facts.append("**Published:** \(metadata.publishedAt.isEmpty ? "unknown" : metadata.publishedAt)")
        let duration = SummaryText.durationHMS(metadata.durationSeconds)
        if !duration.isEmpty {
            facts.append("**Duration:** \(duration)")
        }
        if !metadata.channel.isEmpty {
            facts.append("**Channel:** \(metadata.channel)")
        }
        facts.append("**Language:** " + transcriptLanguageLabel(
            language: transcript.language,
            languageCode: transcript.languageCode,
            isGenerated: transcript.isGenerated
        ))
        facts.append("[Watch on YouTube](\(metadata.url))")

        return frontMatter
            + "# \(metadata.title)\n\n"
            + facts.joined(separator: " · ") + "\n\n"
            + "## Transcript\n\n"
            + transcript.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            + SummaryText.footerMarkdown()
    }

    /// `2024-05-01 — Title` filename stem; undated videos sort together under
    /// `undated — Title`.
    public static func filenameStem(publishedAt: String, title: String) -> String {
        let date = publishedAt.isEmpty ? undatedPrefix : publishedAt
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? date : "\(date) — \(name)"
    }

    /// Video ids already exported into `directory`, read back from the saved
    /// front matter (the filename alone does not carry the id).
    public static func existingVideoIDs(in directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        var ids: Set<String> = []
        for file in files where file.pathExtension.lowercased() == "md" {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 2048)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if let match = head.firstMatch(of: /video_id: "([A-Za-z0-9_-]{11})"/) {
                ids.insert(String(match.1))
            }
        }
        return ids
    }
}
