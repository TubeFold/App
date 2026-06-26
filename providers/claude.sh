#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: claude.sh <prompt-file> <output-file>" >&2
  exit 2
fi

prompt_file="$1"
output_file="$2"

if [[ ! -f "$prompt_file" ]]; then
  echo "[ERROR] Prompt file does not exist: $prompt_file" >&2
  exit 1
fi

if [[ ! -s "$prompt_file" ]]; then
  echo "[ERROR] Prompt file is empty: $prompt_file" >&2
  exit 1
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "[ERROR] Missing dependency: claude" >&2
  exit 127
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[ERROR] Missing dependency: python3" >&2
  exit 127
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
workdir="$(mktemp -d "${TMPDIR:-/tmp}/tubefold-claude.XXXXXX")"

cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

mkdir -p "$(dirname "$output_file")"

python3 "$project_root/scripts/run-claude-provider.py" \
  "$prompt_file" \
  "$output_file" \
  "$workdir" \
  --timeout "${CLAUDE_TIMEOUT_SECONDS:-900}"
