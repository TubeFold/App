#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "${SRCROOT:-$(pwd)}/.." && pwd)"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/YouTubeBrainBackend"
runtime_dir="$dest/Runtime"

build_python="${YOUTUBE_BRAIN_BUILD_PYTHON:-}"
if [[ -z "$build_python" ]]; then
  if [[ -x "$repo_root/.venv/bin/python" ]]; then
    build_python="$repo_root/.venv/bin/python"
  elif [[ -x "/opt/homebrew/bin/python3" ]]; then
    build_python="/opt/homebrew/bin/python3"
  elif [[ -x "/usr/local/bin/python3" ]]; then
    build_python="/usr/local/bin/python3"
  else
    build_python="$(command -v python3)"
  fi
fi

if [[ ! -x "$build_python" ]]; then
  echo "Build Python is not executable: $build_python" >&2
  exit 127
fi

python_info="$("$build_python" - <<'PY'
import os
import sys
import sysconfig

version = sysconfig.get_config_var("VERSION") or f"{sys.version_info.major}.{sys.version_info.minor}"
framework_name = sysconfig.get_config_var("PYTHONFRAMEWORK")
framework_prefix = sysconfig.get_config_var("PYTHONFRAMEWORKPREFIX")

if not framework_name or not framework_prefix:
    raise SystemExit("Build Python must be a framework build on macOS.")

framework_root = os.path.join(framework_prefix, f"{framework_name}.framework")
print(sys.executable)
print(version)
print(framework_root)
PY
)"

python_executable="$(printf '%s\n' "$python_info" | sed -n '1p')"
python_version="$(printf '%s\n' "$python_info" | sed -n '2p')"
framework_root="$(printf '%s\n' "$python_info" | sed -n '3p')"
site_packages_source="$repo_root/.venv/lib/python${python_version}/site-packages"
site_packages_dest="$runtime_dir/lib/python${python_version}/site-packages"
runtime_python="$runtime_dir/bin/python${python_version}"
runtime_framework="$runtime_dir/Python.framework"

if [[ ! -d "$framework_root" ]]; then
  echo "Python framework was not found: $framework_root" >&2
  exit 127
fi

rm -rf "$dest"
mkdir -p "$dest" "$runtime_dir/bin" "$site_packages_dest"

for item in bin config prompts providers scripts youtube_brain requirements.txt; do
  /usr/bin/rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "$repo_root/$item" "$dest/"
done

/usr/bin/rsync -a --delete "$framework_root" "$runtime_dir/"
cp "$python_executable" "$runtime_python"

linked_framework="$(otool -L "$runtime_python" | awk 'index($1, "Python.framework/Versions") {print $1; exit}')"
if [[ -n "$linked_framework" ]]; then
  install_name_tool \
    -change "$linked_framework" \
    "@executable_path/../Python.framework/Versions/${python_version}/Python" \
    "$runtime_python"
fi

if [[ -d "$site_packages_source" ]]; then
  /usr/bin/rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "$site_packages_source/" "$site_packages_dest/"
else
  "$build_python" -m pip install --target "$site_packages_dest" -r "$repo_root/requirements.txt"
fi

ln -sf "python${python_version}" "$runtime_dir/bin/python3"
ln -sf "python${python_version}" "$runtime_dir/bin/python"

cat > "$dest/youtube-brain-server" <<'LAUNCHER'
#!/usr/bin/env bash
set -euo pipefail

backend_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runtime_dir="$backend_root/Runtime"
python_framework_version="$(find "$runtime_dir/Python.framework/Versions" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort -Vr | head -n 1)"
python_bin="$runtime_dir/bin/python${python_framework_version}"

if [[ ! -x "$python_bin" ]]; then
  echo "Embedded Python runtime is missing: $python_bin" >&2
  exit 127
fi

export PYTHONHOME="$runtime_dir/Python.framework/Versions/$python_framework_version"
export PYTHONPATH="$backend_root:$runtime_dir/lib/python${python_framework_version}/site-packages${PYTHONPATH:+:$PYTHONPATH}"
export YOUTUBE_BRAIN_PYTHON="$python_bin"

exec "$python_bin" "$backend_root/bin/youtube-brain-server" "$@"
LAUNCHER

chmod +x "$dest/youtube-brain-server"
chmod +x "$dest/bin/youtube-brain-server" "$dest/bin/youtube-summary"
chmod +x "$dest/providers/"*.sh "$dest/scripts/"*.sh "$dest/scripts/"*.py
chmod +x "$runtime_python"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$runtime_framework" >/dev/null
  codesign --force --sign - "$runtime_python" >/dev/null
fi

PYTHONHOME="$runtime_dir/Python.framework/Versions/$python_version" \
PYTHONPATH="$dest:$site_packages_dest" \
"$runtime_python" - <<'PY'
import youtube_brain.server
import youtube_transcript_api

print("Embedded YouTube Brain backend validated.")
PY
