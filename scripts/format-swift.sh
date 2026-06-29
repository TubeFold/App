#!/usr/bin/env bash
#
# Format (or lint) the SwiftUI app sources with SwiftFormat.
#
#   ./scripts/format-swift.sh          # format in place
#   ./scripts/format-swift.sh --lint   # check only, non-zero exit if unformatted
#
# Config lives in the repo-root .swiftformat file. Install the tool with
# `brew install swiftformat`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_SOURCES="$REPO_ROOT/TubeFold App"

if ! command -v swiftformat >/dev/null 2>&1; then
    echo "error: swiftformat not found. Install it with: brew install swiftformat" >&2
    exit 1
fi

# Pass --lint (or any other flags) straight through to swiftformat.
exec swiftformat "$SWIFT_SOURCES" --config "$REPO_ROOT/.swiftformat" "$@"
