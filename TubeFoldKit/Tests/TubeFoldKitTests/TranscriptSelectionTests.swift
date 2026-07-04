import Testing

@testable import TubeFoldKit

private func track(_ name: String, _ code: String, generated: Bool) -> CaptionTrack {
    CaptionTrack(baseURL: "https://example.com/timedtext", languageCode: code, languageName: name, isGenerated: generated)
}

// Original-language track selection and snippet joining.
@Suite struct TranscriptSelectionTests {
    @Test func manualOriginalPreferredOverAuto() throws {
        // Original language = English (the ASR track); the manual English track wins.
        let selected = try TranscriptSelection.selectTrack([
            track("English auto", "en", generated: true),
            track("English manual", "en", generated: false),
        ])
        #expect(selected.languageCode == "en")
        #expect(!selected.isGenerated)
    }

    @Test func fallsBackToAutoInOriginalLanguage() throws {
        // No manual track in the original (English) language, so the ASR one is
        // used, never the German manual translation.
        let selected = try TranscriptSelection.selectTrack([
            track("German manual", "de", generated: false),
            track("English auto", "en", generated: true),
        ])
        #expect(selected.languageCode == "en")
        #expect(selected.isGenerated)
    }

    @Test func originalLanguageBeatsManualTranslation() throws {
        // The video is Russian (ASR=ru); an English manual translation must NOT win.
        let selected = try TranscriptSelection.selectTrack([
            track("Russian auto", "ru", generated: true),
            track("English manual", "en", generated: false),
        ])
        #expect(selected.languageCode == "ru")
        #expect(selected.isGenerated)
    }

    @Test func regionalManualMatchesOriginalBaseLanguage() throws {
        // ASR "en" + manual "en-US": base languages match, manual wins.
        let selected = try TranscriptSelection.selectTrack([
            track("English auto", "en", generated: true),
            track("English US", "en-US", generated: false),
        ])
        #expect(selected.languageCode == "en-US")
        #expect(!selected.isGenerated)
    }

    @Test func noASRFallsBackToFirstManual() throws {
        // Original language unknown (no ASR track): take the manual track.
        let selected = try TranscriptSelection.selectTrack(
            [track("Portuguese", "pt-BR", generated: false)],
            allowAny: true
        )
        #expect(selected.languageCode == "pt-BR")
    }

    @Test func noASRWithoutFallbackThrows() {
        #expect(throws: InnerTubeError.originalLanguageUnknown) {
            try TranscriptSelection.selectTrack([track("Portuguese", "pt-BR", generated: false)], allowAny: false)
        }
    }

    @Test func emptyTrackListThrows() {
        #expect(throws: InnerTubeError.noTranscript) {
            try TranscriptSelection.selectTrack([])
        }
    }

    @Test func snippetsToTextNormalizesWhitespaceAndKeepsUnicode() {
        let text = TranscriptSelection.snippetsToText([
            "Hello\nworld",
            "  Привет   мир  ",
            "zażółć   gęślą",
        ])
        #expect(text == "Hello world Привет мир zażółć gęślą")
    }

    @Test func baseLanguage() {
        #expect(TranscriptSelection.baseLanguage("en-US") == "en")
        #expect(TranscriptSelection.baseLanguage("EN") == "en")
        #expect(TranscriptSelection.baseLanguage("") == "")
    }
}
