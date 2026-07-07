import Foundation

/// Caption-track selection.
///
/// Selection always targets the video's **original spoken language**, inferred
/// from the auto-generated ("asr") track's language; within that language a
/// manual transcript is preferred over the auto-generated one. There is no
/// preferred-language list — the summary's output language is independent of
/// the transcript language. `allowAny` only governs the fallback when no ASR
/// track exists (original can't be inferred): take the best available track
/// vs. fail.
public enum TranscriptSelection {
    /// Base subtag of a language code, lowercased (`en-US` → `en`).
    public static func baseLanguage(_ code: String) -> String {
        code.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
    }

    /// The video's original spoken language, inferred from the ASR track.
    ///
    /// YouTube auto-generates ("asr") captions from the video's audio, so the
    /// auto-generated track's language is the language actually spoken in the
    /// video. There is normally exactly one such track. Returns `nil` when no
    /// auto-generated track is present (original language can't be inferred).
    public static func originalLanguageCode(_ tracks: [CaptionTrack]) -> String? {
        for track in tracks where track.isGenerated {
            let code = baseLanguage(track.languageCode)
            if !code.isEmpty {
                return code
            }
        }
        return nil
    }

    /// Pick the transcript in the video's original language.
    public static func selectTrack(_ tracks: [CaptionTrack], allowAny: Bool = true) throws -> CaptionTrack {
        guard !tracks.isEmpty else {
            throw InnerTubeError.noTranscript
        }

        if let original = originalLanguageCode(tracks) {
            for generated in [false, true] { // manual first, then auto-generated
                if let track = tracks.first(where: {
                    $0.isGenerated == generated && baseLanguage($0.languageCode) == original
                }) {
                    return track
                }
            }
        }

        if allowAny {
            // Original language unknown (no ASR track): prefer a manual track,
            // then take whatever is available.
            return tracks.first(where: { !$0.isGenerated }) ?? tracks[0]
        }

        throw InnerTubeError.originalLanguageUnknown
    }

    /// Join snippet texts into one line, normalizing whitespace.
    public static func snippetsToText(_ snippets: [String]) -> String {
        let parts = snippets
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " ")
            .replacing(/\s+/, with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
