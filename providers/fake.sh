#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: fake.sh <prompt-file> <output-file>" >&2
  exit 2
fi

prompt_file="$1"
output_file="$2"

if [[ ! -s "$prompt_file" ]]; then
  echo "[ERROR] Prompt file does not exist or is empty: $prompt_file" >&2
  exit 1
fi

mkdir -p "$(dirname "$output_file")"

if [[ -n "${FAKE_PROVIDER_OUTPUT:-}" ]]; then
  printf '%s\n' "$FAKE_PROVIDER_OUTPUT" > "$output_file"
else
  cat > "$output_file" <<'MARKDOWN'
# Fake Summary

## Кратко

Это тестовый Markdown-ответ fake provider. Он используется для проверки pipeline без запуска Codex.

## Подробное саммари

CLI успешно сформировал промпт, вызвал provider по общему контракту и сохранил финальный ответ.
MARKDOWN
fi

if [[ ! -s "$output_file" ]]; then
  echo "[ERROR] Fake provider output is empty" >&2
  exit 1
fi
