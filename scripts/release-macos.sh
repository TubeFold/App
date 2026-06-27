#!/usr/bin/env bash
#
# Build, sign, notarize, and staple the TubeFold macOS app for direct
# (Developer ID) distribution. Produces a notarized, stapled .app and a
# ready-to-ship .zip under build/release/.
#
# This wraps the whole release chain so it's one command locally and the body
# of a GitHub Actions job on a tag. The embedded Python is signed by the Xcode
# build phase (scripts/embed-macos-backend.sh); this script signs the outer app
# via the project's Release settings and handles notarize + staple.
#
# Required environment:
#   TUBEFOLD_TEAM_ID            Apple Developer Team ID (10 chars), e.g. AB12CD34EF
#
# Notarization auth — provide ONE of:
#   TUBEFOLD_NOTARY_PROFILE     keychain profile name created once via
#                               `xcrun notarytool store-credentials` (best locally)
#   -- or the App Store Connect API key trio (best for CI) --
#   TUBEFOLD_NOTARY_KEY         path to the .p8 key file
#   TUBEFOLD_NOTARY_KEY_ID      key id
#   TUBEFOLD_NOTARY_ISSUER      issuer uuid
#
# Optional:
#   TUBEFOLD_SCHEME             default: TubeFold
#   TUBEFOLD_CONFIGURATION      default: Release
#   TUBEFOLD_APP_NAME           default: TubeFold
#   TUBEFOLD_CODESIGN_IDENTITY  override the signing identity (otherwise the
#                               project's Release setting is used)
#
set -euo pipefail

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
project="$repo_root/TubeFold App/TubeFold.xcodeproj"
scheme="${TUBEFOLD_SCHEME:-TubeFold}"
configuration="${TUBEFOLD_CONFIGURATION:-Release}"
app_name="${TUBEFOLD_APP_NAME:-TubeFold}"

build_dir="$repo_root/build/release"
archive_path="$build_dir/$app_name.xcarchive"
export_dir="$build_dir/export"
app_path="$export_dir/$app_name.app"
notary_zip="$build_dir/$app_name-notary.zip"   # sent to the notary service
dist_zip="$build_dir/$app_name.zip"            # final stapled artifact to ship

# --- Preflight -------------------------------------------------------------
command -v xcodebuild >/dev/null || die "xcodebuild not found (install Xcode)."
xcrun --find notarytool >/dev/null 2>&1 || die "notarytool not found (needs Xcode 13+)."
[[ -n "${TUBEFOLD_TEAM_ID:-}" ]] || die "Set TUBEFOLD_TEAM_ID to your Apple Developer Team ID."

# Resolve notarization auth into an argument array.
notary_auth=()
if [[ -n "${TUBEFOLD_NOTARY_PROFILE:-}" ]]; then
  notary_auth=(--keychain-profile "$TUBEFOLD_NOTARY_PROFILE")
elif [[ -n "${TUBEFOLD_NOTARY_KEY:-}" && -n "${TUBEFOLD_NOTARY_KEY_ID:-}" && -n "${TUBEFOLD_NOTARY_ISSUER:-}" ]]; then
  notary_auth=(--key "$TUBEFOLD_NOTARY_KEY" --key-id "$TUBEFOLD_NOTARY_KEY_ID" --issuer "$TUBEFOLD_NOTARY_ISSUER")
else
  die "Provide notary auth: TUBEFOLD_NOTARY_PROFILE, or the TUBEFOLD_NOTARY_KEY/KEY_ID/ISSUER trio."
fi

# Resolve the Developer ID Application identity. The embed build phase signs the
# embedded Python with this — it MUST be the Developer ID, not Xcode's archive
# identity (which is "Apple Development" under automatic signing and would never
# notarize, since -exportArchive does not re-sign Contents/Resources).
if [[ -z "${TUBEFOLD_CODESIGN_IDENTITY:-}" ]]; then
  TUBEFOLD_CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
fi
[[ -n "$TUBEFOLD_CODESIGN_IDENTITY" ]] || die "No 'Developer ID Application' identity found. Create one in Xcode → Settings → Accounts → Manage Certificates, or set TUBEFOLD_CODESIGN_IDENTITY."
export TUBEFOLD_CODESIGN_IDENTITY
log "Signing identity: $TUBEFOLD_CODESIGN_IDENTITY"

rm -rf "$build_dir"
mkdir -p "$build_dir"

# --- 1. Archive ------------------------------------------------------------
# Sign the outer app with the Developer ID too, so the whole bundle is
# distribution-signed in one pass. TUBEFOLD_CODESIGN_IDENTITY is exported above,
# so the Embed Python Backend phase signs the backend with the same identity.
log "Archiving ($configuration)…"
xcodebuild \
  -project "$project" \
  -scheme "$scheme" \
  -configuration "$configuration" \
  -destination "generic/platform=macOS" \
  -archivePath "$archive_path" \
  CODE_SIGN_IDENTITY="$TUBEFOLD_CODESIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  archive

# --- 2. Export with Developer ID -------------------------------------------
log "Exporting Developer ID app…"
export_options="$build_dir/ExportOptions.plist"
cat > "$export_options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TUBEFOLD_TEAM_ID}</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$export_options"

[[ -d "$app_path" ]] || die "Expected app not found after export: $app_path"

# --- 3. Notarize -----------------------------------------------------------
# ditto (not zip) preserves symlinks and the framework's bundle structure;
# a plain `zip` corrupts the Python.framework and notarization fails.
log "Zipping for notarization…"
/usr/bin/ditto -c -k --keepParent "$app_path" "$notary_zip"

log "Submitting to the notary service (this can take a few minutes)…"
if ! xcrun notarytool submit "$notary_zip" "${notary_auth[@]}" --wait; then
  warn "Notarization failed. Fetch the detailed log with:"
  warn "  xcrun notarytool log <submission-id> ${notary_auth[*]}"
  die "Notarization rejected — see the log above for the offending binary."
fi

# --- 4. Staple + verify ----------------------------------------------------
log "Stapling the ticket…"
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"

log "Verifying Gatekeeper acceptance…"
spctl -a -vvv --type exec "$app_path"

# --- 5. Final shippable artifact -------------------------------------------
# Re-zip the STAPLED app so the download works offline (the ticket travels
# inside the bundle).
log "Packaging final artifact…"
/usr/bin/ditto -c -k --keepParent "$app_path" "$dist_zip"

log "Done."
printf '\n  App: %s\n  Zip: %s\n' "$app_path" "$dist_zip"
printf '\n  Next — generate the Sparkle appcast, then upload both to the release:\n    ./scripts/generate-appcast.sh\n'
