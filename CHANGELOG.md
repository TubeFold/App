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

### Changed

- The whole summarization engine now runs inside the app, with no helper
  process or bundled runtime — the app is ~10× smaller and starts summarizing
  immediately.
- Transcripts and video metadata are fetched directly from YouTube's player
  API with a multi-client fallback, making fetches faster and more reliable.
- The `tubefold` command-line tool runs on the same engine as the app
  (`install.sh` builds it with the Swift toolchain).

### Fixed

- Settings now re-checks whether the Chrome extension is connected every time
  the Settings tab is opened, instead of only once at launch.

## [0.8] - 2026-07-01
### Added
- Sonnet 5 is now available as a Claude model option.

### Changed
- Removed the reasoning-effort picker — TubeFold now always uses each model's own
  default effort, so there's one less thing to configure.
- Exported PDFs are saved next to their Markdown summary (reachable via "Show
  Files") instead of a temporary folder, and are reused when still up to date.

### Fixed
- Fixed a race that could leave the Dock icon visible when "Hide Dock icon" was on.

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
- macOS app with a local summarization backend and Sparkle auto-update.
- Library with delete, token-usage stats, Telegraph publishing, reading-time
  estimates, an output-language setting, and watch-activity suggestions.
