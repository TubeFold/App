<p align="left">
  <img src=".github/assets/logo.png" width="120" alt="TubeFold">
</p>

# TubeFold

[![Platform macOS](https://img.shields.io/badge/platform-macOS-000000)](https://github.com/TubeFold/App/releases/latest)
[![Version](https://img.shields.io/github/v/release/TubeFold/App?label=version)](https://github.com/TubeFold/App/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/TubeFold/App/total?label=downloads)](https://github.com/TubeFold/App/releases)

**Turn YouTube videos into Markdown notes — with the AI subscription you already pay for.**

TubeFold is a native macOS app. Paste a YouTube link (or click once in the Chrome extension) and it fetches the transcript, runs it through **your own Claude Code or Codex CLI**, and saves a structured Markdown note — key ideas, arguments, takeaways, sources — into a local library on your Mac.

No API keys. No TubeFold account. No TubeFold servers. No telemetry.

![TubeFold library window with queued, summarizing, and ready YouTube summaries](.github/assets/library.png)

---

## Why TubeFold? Why another YouTube summarizer?

Most YouTube summarizers want a *second* subscription on top of the AI you already pay for, and keep your library on their servers, in their format.

TubeFold inverts both:

- **Your subscription does the work.** It drives the `claude` or `codex` CLI already authenticated on your Mac — the official tools, using their own keychain/OAuth. TubeFold never sees your credentials, and summaries cost you nothing beyond the plan you have.
- **Your notes are files.** Plain Markdown with YAML front matter, on your disk. They open in Obsidian, they're greppable, and they'd survive TubeFold being deleted.
- **No middleman.** There is no TubeFold backend service. Your transcript goes to exactly one AI company: the one you already trust with your subscription.

If you paste transcripts into Claude by hand today — this is that workflow, finished: automatic transcript fetch with original-language selection, a tested prompt, consistent structure, deduplicated library, one-click capture from the browser, PDF export, auto-updates.

## Features

<table>
  <tr>
    <td><strong>Your own AI</strong></td>
    <td>Codex CLI or Claude Code, chosen in a setup wizard that detects and tests your CLI. Switch anytime.</td>
  </tr>
  <tr>
    <td><strong>Structured notes</strong></td>
    <td>Overview, detailed summary, key ideas, practical takeaways, people &amp; sources.</td>
  </tr>
  <tr>
    <td><strong>Chrome extension</strong></td>
    <td>Send the video you're watching with one click; get gentle "summarize this?" suggestions for videos you watched. <a href="https://chromewebstore.google.com/detail/tubefold-mac-app-companio/hjfcdpioihmgoccmfkcicofjgbkjidbh">Web Store</a></td>
  </tr>
  <tr>
    <td><strong>PDF export</strong></td>
    <td>Any note, saved next to its Markdown.</td>
  </tr>
  <tr>
    <td><strong>Telegraph publishing</strong></td>
    <td>One click turns a note into a shareable public article.</td>
  </tr>
  <tr>
    <td><strong>Any output language</strong></td>
    <td>Summaries in your language regardless of the video's language.</td>
  </tr>
</table>

## Install

```sh
brew install --cask tubefold/tap/tubefold
```

Or [download TubeFold.zip](https://github.com/TubeFold/App/releases/latest/download/TubeFold.zip) from the latest release.

## How it works

```text
YouTube URL
  → video metadata
  → transcript
  → prompt template
  → your CLI
  → validated Markdown body
  → done — open the result as a Markdown file, Telegraph web page, or PDF
```

## FAQ

<details><summary><b>Why not just paste the transcript into Claude?</b></summary>

That's this pipeline, done manually. TubeFold adds: automatic transcript fetch with language selection, a consistent tested prompt, YAML front matter, a deduplicated library with filenames that make sense, browser one-click capture, PDF export — and it keeps everything.
</details>

<details><summary><b>Do I need a paid AI subscription?</b></summary>

You need a working `claude` or `codex` CLI signed into your account. Summaries run on your plan's quota; TubeFold shows per-provider token usage in Settings.
</details>

## Roadmap

- [ ] Multiple prompt templates, including flashcards/Anki
- [ ] Obsidian integration (save notes directly into a vault folder)
- [ ] In-library search

Longer-term candidates and rationale: [docs/marketing/ROADMAP_RECOMMENDATIONS.md](docs/marketing/ROADMAP_RECOMMENDATIONS.md). Want something? [Open an issue](https://github.com/TubeFold/App/issues).

## Contributing

Bug reports and PRs welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Bogdan Bystritskiy
