# Changelog

All notable user-facing changes to TubeFold are recorded here. When a version is
released, the section matching that version is shown to users in the **Sparkle
update dialog** and used verbatim as the **GitHub Release notes** — see
[`scripts/changelog.py`](scripts/changelog.py) and
[`scripts/generate-appcast.sh`](scripts/generate-appcast.sh). The appcast marks
the inline `<description>` as `sparkle:format="markdown"` so Sparkle 2.9+ renders
the Markdown directly; no HTML conversion is needed.

Format follows [Keep a Changelog](https://keepachangelog.com/).

**Releasing:** move the relevant items from `## [Unreleased]` into a new
`## [X.Y] - YYYY-MM-DD` section **before** tagging `vX.Y`. CI fails the release
if no section matches the version being tagged, so the appcast can never ship
without notes.

## [Unreleased]

## [0.7] - 2026-06-30
### Added
- Run TubeFold without a Dock icon — a new "Hide Dock icon" setting turns it into
  a menu-bar-only app, with the main window still reachable from the menu bar.

### Changed
- The menu bar now opens the latest summary directly in Markdown, PDF, or Web
  (Telegraph) form, replacing the old "Open Latest Video" and "Refresh" items.

## [0.6] - 2026-06-29
### Added
- Export any summary to PDF.

### Changed
- Transcripts now prefer the video's original spoken language.
- Refreshed the macOS UI: titlebar separator, clearer section headers, and
  friendlier error reporting.
- The Chrome extension now lives in its own repo and on the Chrome Web Store; the
  app shows its connection status and a gentle nudge to install it.

## [0.5] - 2026-06-28
### Added
- Automatic background update checks, with menu-bar polish.

## [0.4] - 2026-06-27
### Added
- "Reset Data" to wipe your library from Settings.
- Reveal a summary's output folder in Finder.

### Fixed
- Telegraph publishing and assorted UI fixes.

## [0.3] - 2026-06-27
### Changed
- Library polish: aligned rows, title-based filenames, extension icons.
- Simpler, modernized README and About screen.

## [0.2] - 2026-06-27
### Added
- First public release: turn a YouTube URL into a Markdown summary using your own
  Codex or Claude CLI subscription — no API keys, no cloud.
- macOS app with an embedded Python backend and Sparkle auto-update.
- Library with delete, token-usage stats, Telegraph publishing, reading-time
  estimates, an output-language setting, and watch-activity suggestions.
