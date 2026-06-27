#!/usr/bin/env bash
#
# Rewrite a Homebrew cask's version + sha256 in place. Used by the release
# workflow to bump TubeFold/homebrew-tap after a new build is published, but
# safe to run by hand:
#
#   scripts/update-cask.sh path/to/Casks/tubefold.rb 0.3 <sha256>
#
set -euo pipefail

cask="${1:?usage: update-cask.sh <cask.rb> <version> <sha256>}"
version="${2:?missing version}"
sha="${3:?missing sha256}"

[[ -f "$cask" ]] || { echo "cask not found: $cask" >&2; exit 1; }
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { echo "sha256 must be 64 hex chars, got: $sha" >&2; exit 1; }

# BSD sed (macOS runners). Anchor on the leading two-space indent so we only
# touch the top-level stanzas, never anything inside nested blocks.
/usr/bin/sed -i '' -E "s/^  version \".*\"/  version \"${version}\"/" "$cask"
/usr/bin/sed -i '' -E "s/^  sha256 \".*\"/  sha256 \"${sha}\"/" "$cask"

grep -qE "^  version \"${version}\"" "$cask" || { echo "version bump failed" >&2; exit 1; }
grep -qE "^  sha256 \"${sha}\"" "$cask" || { echo "sha256 bump failed" >&2; exit 1; }
echo "Updated $cask -> version ${version}, sha256 ${sha}"
