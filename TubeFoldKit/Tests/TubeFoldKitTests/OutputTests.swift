import Foundation
import Testing

@testable import TubeFoldKit

// Filenames, front matter, fence stripping and the other text helpers.
@Suite struct OutputTests {
    @Test func safeFilename() {
        #expect(Filenames.safeFilename("Hello / World: Part 1") == "Hello - World - Part 1")
        #expect(Filenames.safeFilename("   Many    spaces   ") == "Many spaces")
        #expect(Filenames.safeFilename(".") == "Untitled YouTube Video")
        #expect(Filenames.safeFilename("Emoji 🎮 Test") == "Emoji 🎮 Test")
        #expect(Filenames.safeFilename("Bad <chars>? \"here\"* |x|") == "Bad chars here x")
        #expect(Filenames.safeFilename(String(repeating: "a", count: 200)).count == 120)
    }

    @Test func uniqueMarkdownPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tubefoldkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try "existing".write(to: directory.appendingPathComponent("Video.md"), atomically: true, encoding: .utf8)
        let path = try Filenames.uniqueMarkdownPath(outputDir: directory, title: "Video")
        #expect(path.lastPathComponent == "Video (2).md")
    }

    @Test func yamlFrontMatter() {
        let rendered = SummaryText.yamlFrontMatter([
            ("title", .string("A \"quoted\" — title")),
            ("duration_seconds", .int(90)),
            ("missing", .null),
        ])
        #expect(rendered == "---\ntitle: \"A \\\"quoted\\\" — title\"\nduration_seconds: 90\nmissing: \"\"\n---\n\n")
    }

    @Test func modelLabel() {
        #expect(SummaryText.modelLabel(provider: "codex", model: "gpt-5.4-mini", reasoningEffort: "medium")
            == "codex gpt-5.4-mini (effort: medium)")
        #expect(SummaryText.modelLabel(provider: "codex", model: "", reasoningEffort: "high") == "codex (effort: high)")
        #expect(SummaryText.modelLabel(provider: "claude", model: "opus", reasoningEffort: "auto") == "claude opus")
    }

    @Test func stripOuterMarkdownFence() {
        #expect(SummaryText.stripOuterMarkdownFence("```markdown\n# Title\n\nBody\n```") == "# Title\n\nBody\n")
        #expect(SummaryText.stripOuterMarkdownFence("```\nplain\n```") == "plain\n")
        #expect(SummaryText.stripOuterMarkdownFence("no fence here") == "no fence here\n")
        // An inner fence only: not an outer wrapper, kept verbatim.
        #expect(SummaryText.stripOuterMarkdownFence("text\n```\ncode\n```\nmore") == "text\n```\ncode\n```\nmore\n")
    }

    @Test func validateProviderResponse() {
        #expect(throws: TubeFoldError.emptyProviderOutput) {
            try SummaryText.validateProviderResponse("   \n ")
        }
        #expect(throws: TubeFoldError.providerOutputTooShort) {
            try SummaryText.validateProviderResponse("too short")
        }
        try? SummaryText.validateProviderResponse("This is a long enough summary body.")
    }

    @Test func footerRoundTrip() {
        let body = "# Title\n\nBody text."
        let withFooter = body + SummaryText.footerMarkdown()
        #expect(SummaryText.stripTubeFoldFooter(withFooter) == body)
        #expect(SummaryText.stripTubeFoldFooter(body) == body)
    }

    @Test func durationHMS() {
        #expect(SummaryText.durationHMS(nil) == "")
        #expect(SummaryText.durationHMS(-5) == "")
        #expect(SummaryText.durationHMS(59) == "0:59")
        #expect(SummaryText.durationHMS(90) == "1:30")
        #expect(SummaryText.durationHMS(3721) == "1:02:01")
    }

    @Test func renderTemplate() {
        let rendered = SummaryText.renderTemplate(
            "Summarize {{TITLE}} in {{OUTPUT_LANGUAGE}}.",
            values: ["TITLE": "X", "OUTPUT_LANGUAGE": "English"]
        )
        #expect(rendered == "Summarize X in English.")
    }

    @Test func outputLanguageNormalization() {
        #expect(OutputLanguage.normalize(nil) == "English")
        #expect(OutputLanguage.normalize("  ") == "English")
        #expect(OutputLanguage.normalize(" Русский \n язык ") == "Русский язык")
        #expect(OutputLanguage.normalize(String(repeating: "x", count: 100)).count == 60)
    }

    @Test func envFileParsing() throws {
        let parsed = try EnvFile.parse(text: """
        # comment
        PLAIN=value
        QUOTED="hello world"
        SINGLE='single'
        EXPORTED=export inner
        """)
        #expect(parsed == [
            "PLAIN": "value",
            "QUOTED": "hello world",
            "SINGLE": "single",
            "EXPORTED": "inner",
        ])
        #expect(throws: EnvFile.ParseError.self) {
            try EnvFile.parse(text: "NO_EQUALS_HERE")
        }
        #expect(throws: EnvFile.ParseError.self) {
            try EnvFile.parse(text: "9BAD=value")
        }
    }

    @Test func parseBool() {
        #expect(EnvFile.parseBool("YES"))
        #expect(EnvFile.parseBool(" on "))
        #expect(!EnvFile.parseBool("off", default: true))
        #expect(EnvFile.parseBool(nil, default: true))
        #expect(!EnvFile.parseBool("maybe"))
    }
}
