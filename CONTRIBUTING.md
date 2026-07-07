# Contributing to TubeFold

Thanks for considering it. TubeFold is a small, deliberately-scoped project — contributions that fit the scope get merged fast.

## Ground rules

- **Scope:** YouTube → Markdown on macOS, via provider CLIs the user already has. Features that add TubeFold-operated servers, telemetry, or bundled API keys won't be accepted (see [docs/marketing/DECISIONS.md](docs/marketing/DECISIONS.md)).
- **Privacy claims are code-backed.** Any change that adds an outbound network call must update the "What leaves your Mac" table in README.md and `privacy.html` on the website, and will get extra review.
- Open an issue before large changes; small fixes can go straight to PR.

## Development setup

```sh
git clone https://github.com/TubeFold/App tubefold && cd tubefold
cd TubeFoldKit && swift test                 # ~130 tests, must stay green
swift run tubefold "https://youtu.be/dQw4w9WgXcQ" --provider fake --no-open   # full pipeline, no model call
```

macOS app: open `TubeFold App/TubeFold.xcodeproj`, scheme `TubeFold`. Architecture notes live in [CLAUDE.md](CLAUDE.md) — read it first; it's the real developer manual (provider contract, extension API, release process).

## Easy, valuable contributions

- **Prompt templates** (`TubeFoldKit/Sources/TubeFoldKit/Resources/prompts/*.md`) — new note structures (brief, chapter outline, flashcards…).
- **Providers** — `SummaryProvider` implementations in `TubeFoldKit/Sources/TubeFoldKit/Providers/`; the classic `provider <prompt_file> <output_file>` executable contract still works via `ScriptProvider`. Local-model providers welcome with documented caveats.
- **Localization** — the app UI ships in 10 languages via `Localizable.xcstrings`; corrections and new languages welcome.
- Docs, troubleshooting notes, and test coverage.

## Pull requests

- Run the full test suite; add tests for behavior changes in TubeFoldKit.
- Swift code is linted (SwiftLint) and formatted (SwiftFormat) in the build.
- Keep PRs single-purpose; reference the issue.
- User-visible changes: add a line under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md).

## Releases

Maintainer-driven; the process is documented in CLAUDE.md ("Releasing an update"). Contributors never need signing keys.
