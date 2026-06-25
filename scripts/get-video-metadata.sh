#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: get-video-metadata.sh <youtube-url> <output-json>" >&2
  exit 2
fi

url="$1"
output_json="$2"

if ! command -v yt-dlp >/dev/null 2>&1; then
  echo "[ERROR] Missing dependency: yt-dlp" >&2
  exit 127
fi

tmp_json="${output_json}.tmp"
yt-dlp --dump-single-json --skip-download --no-warnings "$url" > "$tmp_json"

if [[ ! -s "$tmp_json" ]]; then
  rm -f "$tmp_json"
  echo "[ERROR] yt-dlp did not return metadata" >&2
  exit 1
fi

mv "$tmp_json" "$output_json"
