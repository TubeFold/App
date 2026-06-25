#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
link_path="${HOME}/.local/bin/youtube-summary"

if [[ -L "$link_path" && "$(readlink "$link_path")" == "$project_root/bin/youtube-summary" ]]; then
  rm "$link_path"
  echo "Removed symlink: $link_path"
else
  echo "No youtube-summary symlink owned by this checkout was found at: $link_path"
fi

if [[ "${1:-}" == "--remove-config" ]]; then
  rm -f "${HOME}/.config/youtube-summary/config.env"
  echo "Removed config: ${HOME}/.config/youtube-summary/config.env"
else
  echo "User config left unchanged. Pass --remove-config to delete it."
fi
