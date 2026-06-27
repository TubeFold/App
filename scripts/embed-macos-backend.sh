#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "${SRCROOT:-$(pwd)}/.." && pwd)"
dest="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/TubeFoldBackend"
runtime_dir="$dest/Runtime"

build_python="${TUBEFOLD_BUILD_PYTHON:-}"
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

for item in bin config prompts providers scripts tubefold requirements.txt; do
  /usr/bin/rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "$repo_root/$item" "$dest/"
done

/usr/bin/rsync -a --delete "$framework_root" "$runtime_dir/"
cp "$python_executable" "$runtime_python"

# A framework build hard-codes its own absolute path (the Homebrew Cellar) as
# the install name of the Python shared library, and every Mach-O that links it
# inherits that absolute reference. We must rewrite ALL of them to a relocatable
# path or the embedded interpreter will (a) fail to find Python on a machine
# without that Cellar and (b) — once signed with a real identity — get blocked
# by library validation for loading a different-Team-ID binary.
relocate_python_ref() {
  # $1 = Mach-O to patch, $2 = relocatable replacement path
  local binary="$1" replacement="$2" old
  old="$(otool -L "$binary" | awk '/Python\.framework\/Versions\/.*\/Python$/ {print $1; exit}')"
  if [[ -n "$old" ]]; then
    install_name_tool -change "$old" "$replacement" "$binary"
  fi
}

# The launcher runs bin/pythonX.Y, so @executable_path resolves next to it.
relocate_python_ref "$runtime_python" \
  "@executable_path/../Python.framework/Versions/${python_version}/Python"

# The framework's own bundled stub (Resources/Python.app/Contents/MacOS/Python)
# is the one that crashed the archive. @loader_path is relative to the stub
# itself: MacOS → Contents → Python.app → Resources → Versions/X.Y/Python.
inner_python_stub="$runtime_framework/Versions/${python_version}/Resources/Python.app/Contents/MacOS/Python"
if [[ -f "$inner_python_stub" ]]; then
  relocate_python_ref "$inner_python_stub" "@loader_path/../../../../Python"
fi

# Homebrew's framework ships a site-packages symlink that points into the brew
# prefix (outside our copied layout); once embedded it dangles. Gatekeeper
# rejects any bundle containing a broken symlink ("invalid destination for
# symbolic link"), so neutralize every broken link in the runtime — recreating
# site-packages as a real (empty) directory since the interpreter expects one
# there (our actual dependencies live on PYTHONPATH, elsewhere).
while IFS= read -r broken; do
  rm -f "$broken"
  case "$broken" in
    */site-packages) mkdir -p "$broken" ;;
  esac
done < <(find "$runtime_dir" -type l ! -exec test -e {} \; -print)

if [[ -d "$site_packages_source" ]]; then
  /usr/bin/rsync -a --delete --exclude "__pycache__" --exclude "*.pyc" "$site_packages_source/" "$site_packages_dest/"
else
  "$build_python" -m pip install --target "$site_packages_dest" -r "$repo_root/requirements.txt"
fi

ln -sf "python${python_version}" "$runtime_dir/bin/python3"
ln -sf "python${python_version}" "$runtime_dir/bin/python"

cat > "$dest/tubefold-server" <<'LAUNCHER'
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
export TUBEFOLD_PYTHON="$python_bin"

exec "$python_bin" "$backend_root/bin/tubefold-server" "$@"
LAUNCHER

chmod +x "$dest/tubefold-server"
chmod +x "$dest/bin/tubefold-server" "$dest/bin/tubefold"
chmod +x "$dest/providers/"*.sh "$dest/scripts/"*.sh "$dest/scripts/"*.py
chmod +x "$runtime_python"

# --- Validate the assembled tree BEFORE signing ----------------------------
# Run the import smoke test while the binaries are still unsigned: a hardened
# signature would subject this to library validation, and the point here is to
# check that the embedded interpreter and its packages import — not its signing.
PYTHONHOME="$runtime_dir/Python.framework/Versions/$python_version" \
PYTHONPATH="$dest:$site_packages_dest" \
"$runtime_python" - <<'PY'
import tubefold.server
import youtube_transcript_api

print("Embedded TubeFold backend validated.")
PY

# --- Code signing ----------------------------------------------------------
# Identity precedence: explicit override (the release script / CI passes the
# Developer ID here) → ad-hoc. We deliberately do NOT fall back to Xcode's
# EXPANDED_CODE_SIGN_IDENTITY: at archive time automatic signing resolves to
# "Apple Development", and `xcodebuild -exportArchive` does not re-sign
# Contents/Resources — so signing the backend with that identity would ship a
# Development signature that can never notarize. Distribution must pass the
# Developer ID explicitly; plain dev builds stay ad-hoc.
sign_identity="${TUBEFOLD_CODESIGN_IDENTITY:--}"
python_entitlements="$repo_root/TubeFold App/TubeFold/EmbeddedPython.entitlements"

codesign_args=(--force --sign "$sign_identity")
if [[ "$sign_identity" != "-" ]]; then
  # Hardened runtime and a secure timestamp are both mandatory for notarization.
  codesign_args+=(--options runtime --timestamp)
fi

if command -v codesign >/dev/null 2>&1; then
  # Sign every nested Mach-O inside-out. `find -depth` emits children before
  # their parents, which is exactly the inner-before-outer order codesign needs
  # (this replaces the unreliable `--deep`). We test each file with `file`
  # because the binaries that matter aren't only *.so/*.dylib — the framework's
  # `Python` library and `bin/pythonX.Y` have no telling extension.
  while IFS= read -r -d '' macho; do
    [[ "$macho" == "$runtime_python" ]] && continue   # signed below, with entitlements
    if file -b "$macho" | grep -q 'Mach-O'; then
      codesign "${codesign_args[@]}" "$macho" >/dev/null
    fi
  done < <(find "$runtime_dir" "$site_packages_dest" -depth -type f -print0)

  # The interpreter carries the embedded-Python entitlements (library validation
  # off, so it can load the third-party .so above). Entitlements are meaningless
  # under an ad-hoc signature, so only attach them for a real identity.
  if [[ "$sign_identity" != "-" && -f "$python_entitlements" ]]; then
    codesign "${codesign_args[@]}" --entitlements "$python_entitlements" "$runtime_python" >/dev/null
  else
    codesign "${codesign_args[@]}" "$runtime_python" >/dev/null
  fi

  # Seal the framework bundle itself last, now that its contents are signed.
  codesign "${codesign_args[@]}" "$runtime_framework" >/dev/null
fi
