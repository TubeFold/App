import Foundation
import TubeFoldKit

// The one-shot `tubefold` CLI: URL in, saved `.md` path on stdout,
// diagnostics on stderr. Config layering, lowest to highest:
// defaults → ~/.config/tubefold/config.env (or --config / $TUBEFOLD_CONFIG)
// → environment variables → CLI flags.

struct CLILogger {
    let verbose: Bool

    func info(_ message: String) {
        FileHandle.standardError.write(Data("[INFO] \(message)\n".utf8))
    }

    func debug(_ message: String) {
        if verbose {
            FileHandle.standardError.write(Data("[DEBUG] \(message)\n".utf8))
        }
    }
}

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("[ERROR] \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    let text = """
    usage: tubefold <youtube-url> [options]

    Options:
      --provider <name>        codex (default), claude, or fake
      --model <id>             provider model id
      --language <label>       summary output language (default English)
      --output-dir <path>      where the .md is saved
      --config <path>          config.env to load
      --timeout <seconds>      provider timeout (default 900)
      --allow-any <bool>       transcript fallback when original language unknown
      --open / --no-open       reveal the saved file after writing
      --verbose                debug logging
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

// ---------------------------------------------------------------- arguments

var urlArgument: String?
var flags: [String: String] = [:]
var booleanFlags: Set<String> = []

var iterator = CommandLine.arguments.dropFirst().makeIterator()
while let argument = iterator.next() {
    switch argument {
    case "--help", "-h":
        usage()
    case "--verbose", "--open", "--no-open":
        booleanFlags.insert(argument)
    case let flag where flag.hasPrefix("--"):
        guard let value = iterator.next() else {
            die("Missing value for \(flag)", code: 2)
        }
        flags[String(flag.dropFirst(2))] = value
    default:
        if urlArgument == nil {
            urlArgument = argument
        } else {
            die("Unexpected argument: \(argument)", code: 2)
        }
    }
}

guard let urlArgument else { usage() }
let logger = CLILogger(verbose: booleanFlags.contains("--verbose"))

// ------------------------------------------------------------------ config

let environment = ProcessInfo.processInfo.environment
var config: [String: String] = [
    "PROVIDER": "codex",
    "OUTPUT_DIR": "$HOME/Documents/YouTube Summaries",
    "OUTPUT_LANGUAGE": "English",
    "ALLOW_ANY_TRANSCRIPT_LANGUAGE": "true",
    "OPEN_AFTER_SAVE": "false",
    "CODEX_TIMEOUT_SECONDS": "900",
    "CODEX_MODEL": ProviderDescriptors.defaultCodexModel,
    "CLAUDE_TIMEOUT_SECONDS": "900",
    "CLAUDE_MODEL": ProviderDescriptors.defaultClaudeModel,
]

let configPath = flags["config"]
    ?? environment["TUBEFOLD_CONFIG"]
    ?? NSString(string: "~/.config/tubefold/config.env").expandingTildeInPath
do {
    let fileValues = try EnvFile.parse(at: URL(fileURLWithPath: NSString(string: configPath).expandingTildeInPath))
    for (key, value) in fileValues {
        config[key] = value
    }
} catch {
    die("Invalid config file: \(error.localizedDescription)")
}
for (key, value) in environment where config[key] != nil {
    config[key] = value
}
// Backward-compatible config-key aliases.
if let legacy = config["ALLOW_ANY_SUBTITLE_LANGUAGE"] {
    config["ALLOW_ANY_TRANSCRIPT_LANGUAGE"] = legacy
}
if let legacy = config["SUMMARY_LANGUAGE"] {
    config["OUTPUT_LANGUAGE"] = legacy
}

let providerID = flags["provider"] ?? config["PROVIDER"] ?? "codex"
let outputLanguage = OutputLanguage.normalize(flags["language"] ?? config["OUTPUT_LANGUAGE"])
let allowAny = EnvFile.parseBool(flags["allow-any"] ?? config["ALLOW_ANY_TRANSCRIPT_LANGUAGE"], default: true)
let timeoutKey = providerID == "claude" ? "CLAUDE_TIMEOUT_SECONDS" : "CODEX_TIMEOUT_SECONDS"
let timeout = TimeInterval(flags["timeout"] ?? config[timeoutKey] ?? "900") ?? 900
let openAfterSave = booleanFlags.contains("--open")
    || (!booleanFlags.contains("--no-open") && EnvFile.parseBool(config["OPEN_AFTER_SAVE"], default: false))

func expandPath(_ value: String) -> URL {
    var expanded = NSString(string: value).expandingTildeInPath
    if expanded.contains("$HOME") {
        expanded = expanded.replacingOccurrences(
            of: "$HOME",
            with: FileManager.default.homeDirectoryForCurrentUser.path
        )
    }
    return URL(fileURLWithPath: expanded)
}

let outputDir = expandPath(flags["output-dir"] ?? config["OUTPUT_DIR"] ?? "~/Documents/YouTube Summaries")

// ---------------------------------------------------------------- pipeline

let videoID: String
do {
    videoID = try YouTubeURL.parseVideoID(urlArgument)
} catch {
    die((error as? YouTubeURLError)?.errorDescription ?? "\(error)", code: 2)
}
logger.info("Video id: \(videoID)")

@MainActor
func resolveProvider() -> (any SummaryProvider, ProviderRunSettings) {
    if providerID == "fake" {
        let output = environment["FAKE_PROVIDER_OUTPUT"]
        return (
            output.map(FakeProvider.init(output:)) ?? FakeProvider(),
            ProviderRunSettings(timeout: timeout)
        )
    }
    guard let descriptor = ProviderDescriptors.descriptor(for: providerID) else {
        die("Unknown provider: \(providerID)", code: 2)
    }
    let executable = ProviderDiagnostics.detectViaLoginShell(binaryName: descriptor.binaryName)
        ?? descriptor.homebrewPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
        die("Missing dependency: \(descriptor.binaryName)", code: 127)
    }
    let modelKey = providerID == "claude" ? "CLAUDE_MODEL" : "CODEX_MODEL"
    let model = descriptor.validModel(flags["model"] ?? config[modelKey])
    let settings = ProviderRunSettings(model: model, reasoningEffort: "auto", timeout: timeout)
    let provider: any SummaryProvider = providerID == "claude"
        ? ClaudeProvider(executablePath: executable)
        : CodexProvider(executablePath: executable)
    return (provider, settings)
}

let client = InnerTubeClient()

do {
    logger.info("Fetching metadata + caption tracks…")
    var metadata: VideoMetadata
    var tracks: [CaptionTrack] = []
    do {
        (metadata, tracks) = try await client.fetchVideoInfo(videoID: videoID)
    } catch {
        // Metadata is best-effort, never fatal.
        metadata = .stub(videoID: videoID, url: try YouTubeURL.normalize(videoID))
        logger.debug("Metadata fallback: \(error)")
    }
    logger.info("Title: \(metadata.title)")

    logger.info("Fetching transcript…")
    let track = try TranscriptSelection.selectTrack(tracks, allowAny: allowAny)
    let text = try await client.downloadTranscriptText(track: track)
    guard text.count >= 20 else {
        throw InnerTubeError.emptyTranscript
    }
    let transcript = TranscriptResult(
        text: text,
        language: track.languageName,
        languageCode: track.languageCode,
        isGenerated: track.isGenerated
    )
    logger.info("Transcript: \(transcript.languageCode) (\(transcript.isGenerated ? "auto" : "manual")), \(transcript.text.count) chars")

    let languageLabel = transcriptLanguageLabel(
        language: transcript.language,
        languageCode: transcript.languageCode,
        isGenerated: transcript.isGenerated
    )
    let template = try PipelineConfiguration(dataDirectory: outputDir).promptTemplate()
    let prompt = SummaryText.renderTemplate(template, values: [
        "TITLE": metadata.title,
        "URL": metadata.url,
        "CHANNEL": metadata.channel,
        "DURATION": SummaryText.durationHMS(metadata.durationSeconds),
        "SUBTITLE_LANGUAGE": languageLabel,
        "TRANSCRIPT_LANGUAGE": languageLabel,
        "OUTPUT_LANGUAGE": outputLanguage,
        "TRANSCRIPT": transcript.text,
    ])

    let (provider, settings) = resolveProvider()
    logger.info("Provider: \(providerID)\(settings.model.isEmpty ? "" : " (\(settings.model))") — generating summary…")
    let runResult = try await provider.generateSummary(prompt: prompt, settings: settings)
    let response = SummaryText.stripOuterMarkdownFence(runResult.markdownBody)
    try SummaryText.validateProviderResponse(response)

    let model: String = if let descriptor = ProviderDescriptors.descriptor(for: providerID) {
        SummaryText.modelLabel(
            provider: providerID.prefix(1).uppercased() + providerID.dropFirst(),
            model: descriptor.modelDisplayLabel(settings.model),
            reasoningEffort: settings.reasoningEffort
        )
    } else {
        providerID
    }
    let frontMatter = SummaryText.yamlFrontMatter([
        ("type", .string("tubefold")),
        ("source", .string("youtube")),
        ("video_id", .string(metadata.videoID)),
        ("url", .string(metadata.url)),
        ("title", .string(metadata.title)),
        ("channel", .string(metadata.channel)),
        ("duration_seconds", metadata.durationSeconds.map(SummaryText.YAMLScalar.int) ?? .null),
        ("published_at", .string(metadata.publishedAt)),
        ("processed_at", .string(SummaryText.processedAtNow())),
        ("subtitle_language", .string(transcript.languageCode)),
        ("transcript_language", .string(transcript.language)),
        ("transcript_language_code", .string(transcript.languageCode)),
        ("transcript_is_generated", .bool(transcript.isGenerated)),
        ("output_language", .string(outputLanguage)),
        ("model", .string(model)),
        ("prompt_template", .string("detailed-summary")),
    ])
    let markdown = frontMatter
        + response.trimmingCharacters(in: .whitespacesAndNewlines)
        + "\n"
        + SummaryText.footerMarkdown()

    try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let outputPath = try Filenames.uniqueMarkdownPath(outputDir: outputDir, title: metadata.title)
    try markdown.write(to: outputPath, atomically: true, encoding: .utf8)
    logger.info("Saved: \(outputPath.path)")
    print(outputPath.path)

    if openAfterSave {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [outputPath.path]
        try? open.run()
    }
} catch let error as InnerTubeError {
    die(error.userMessage)
} catch let error as ProviderRunError {
    die(error.userMessage, code: error.userMessage.contains("Missing dependency") ? 127 : 1)
} catch let error as TubeFoldError {
    die(error.errorDescription ?? "\(error)")
} catch {
    die("\(error)")
}
