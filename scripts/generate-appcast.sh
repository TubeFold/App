#!/usr/bin/env bash
#
# Generate (or update) the Sparkle EdDSA-signed appcast for a release.
#
# Run this AFTER release-macos.sh has produced the notarized, stapled zip in
# build/release/. It signs the zip with the Sparkle private key and writes
# build/release/appcast.xml, whose <enclosure url> points at the GitHub release
# asset. Upload BOTH TubeFold.zip and appcast.xml to the same release; the app's
# SUFeedURL (releases/latest/download/appcast.xml) then serves the latest update.
#
# Signing key:
#   - Locally: the EdDSA private key created by `generate_keys` lives in your
#     login keychain and is used automatically — no env needed.
#   - CI: set SPARKLE_ED_PRIVATE_KEY to the private key string (a GitHub secret);
#     this script writes it to a temp file and passes --ed-key-file.
#
# Environment:
#   TUBEFOLD_VERSION             version tag segment for the URL (default: the
#                                project's MARKETING_VERSION). Used as v<version>.
#   TUBEFOLD_DOWNLOAD_URL_PREFIX  override the full enclosure URL prefix.
#   SPARKLE_TOOLS_DIR            dir containing generate_appcast (default: found
#                                under Xcode DerivedData SourcePackages artifacts).
#   SPARKLE_ED_PRIVATE_KEY       (CI) the EdDSA private key string.
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/TubeFold App/TubeFold.xcodeproj"
build_dir="$repo_root/build/release"
[[ -f "$build_dir/TubeFold.zip" ]] || die "No build/release/TubeFold.zip — run scripts/release-macos.sh first."

# --- Locate generate_appcast ----------------------------------------------
tools_dir="${SPARKLE_TOOLS_DIR:-}"
if [[ -z "$tools_dir" ]]; then
  # Resolve packages so the artifact exists, then find the binary.
  xcodebuild -project "$project" -resolvePackageDependencies >/dev/null 2>&1 || true
  tools_dir="$(dirname "$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*artifacts/sparkle/Sparkle/bin/generate_appcast' 2>/dev/null | head -n1)")"
fi
[[ -n "$tools_dir" && -x "$tools_dir/generate_appcast" ]] \
  || die "generate_appcast not found. Set SPARKLE_TOOLS_DIR, or run xcodebuild -resolvePackageDependencies."
log "Sparkle tools: $tools_dir"

# --- Resolve the download URL prefix --------------------------------------
if [[ -z "${TUBEFOLD_DOWNLOAD_URL_PREFIX:-}" ]]; then
  version="${TUBEFOLD_VERSION:-$(xcodebuild -project "$project" -scheme TubeFold -showBuildSettings 2>/dev/null \
    | awk -F'= ' '/ MARKETING_VERSION =/{print $2; exit}')}"
  [[ -n "$version" ]] || die "Could not determine version; set TUBEFOLD_VERSION."
  TUBEFOLD_DOWNLOAD_URL_PREFIX="https://github.com/TubeFold/App/releases/download/v${version}/"
fi
log "Enclosure URL prefix: $TUBEFOLD_DOWNLOAD_URL_PREFIX"

# --- Signing key argument --------------------------------------------------
key_args=()
key_file=""
cleanup() { [[ -n "$key_file" ]] && rm -f "$key_file"; }
trap cleanup EXIT
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
  key_file="$(mktemp)"
  printf '%s' "$SPARKLE_ED_PRIVATE_KEY" > "$key_file"
  key_args=(--ed-key-file "$key_file")
  log "Signing with SPARKLE_ED_PRIVATE_KEY (CI mode)."
else
  log "Signing with the private key in your login keychain."
fi

# --- Generate --------------------------------------------------------------
"$tools_dir/generate_appcast" \
  --download-url-prefix "$TUBEFOLD_DOWNLOAD_URL_PREFIX" \
  "${key_args[@]}" \
  "$build_dir"

log "Wrote $build_dir/appcast.xml"
printf '\n  Upload to the release:\n    %s\n    %s\n' "$build_dir/TubeFold.zip" "$build_dir/appcast.xml"
