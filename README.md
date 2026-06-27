# ▶︎ TubeFold

**Turn long YouTube videos into clean, structured Markdown notes.**

Paste a YouTube link and get the key ideas, arguments, and takeaways—ready for Obsidian, your notes, or a personal knowledge base.

**No TubeFold account. No API keys. No separate API billing.**

TubeFold uses the Codex CLI or Claude Code subscription already authenticated on your Mac.

[![Release](https://img.shields.io/github/v/release/TubeFold/App?color=ff3b30&label=release&style=flat-square)](https://github.com/TubeFold/App/releases/latest)
![macOS](https://img.shields.io/badge/macOS-26%2B-000?logo=apple&logoColor=white&style=flat-square)
![Swift](https://img.shields.io/badge/SwiftUI-f05138?logo=swift&logoColor=white&style=flat-square)
![Python](https://img.shields.io/badge/Python-3776ab?logo=python&logoColor=white&style=flat-square)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)

---

## Why another YouTube summarizer?

Most YouTube summarizers are built around the same model: send a transcript to an AI API, then charge users another monthly subscription on top of the AI services they may already pay for.

TubeFold takes a different approach.

It uses the Codex CLI or Claude Code subscription already authenticated on your Mac. There is no TubeFold account, no separate API key, no hosted TubeFold backend, and no additional AI subscription to maintain.

Your library, transcripts, and Markdown files stay on your Mac. TubeFold is open source, so you can inspect exactly how it works, change the prompts, or extend it for your own workflow.

## Features

| | |
| --- | --- |
| **Bring your own AI subscription** | Use your authenticated `codex` or `claude` CLI without configuring separate API keys. |
| **Native macOS app** | A notarized SwiftUI app with a bundled local backend. |
| **Structured Markdown notes** | Extract key ideas, arguments, and takeaways from YouTube transcripts. |
| **Chrome extension** | Send the current YouTube video to TubeFold directly from its page. |
| **Telegraph publishing** | Publish a summary as a public article with one click. |
| **Privacy-first** | No analytics, telemetry, tracking, or TubeFold account. Your library stays on your Mac. |

## Installation

Install with Homebrew:

```sh
brew install --cask tubefold/tap/tubefold
```

Or [download TubeFold.zip](https://github.com/TubeFold/App/releases/latest/download/TubeFold.zip).

## How it works

```text
YouTube URL
  → video metadata
  → transcript
  → prompt template
  → Codex CLI or Claude Code
  → Markdown summary
```

## Roadmap

- [ ] Multiple prompt templates, including a dedicated Anki template
- [ ] Obsidian integration

## License

[MIT](LICENSE)
