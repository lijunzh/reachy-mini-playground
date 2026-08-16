#!/usr/bin/env bash
#
# Recreate the Reachy Mini simulator environment on a macOS machine.
# Idempotent: safe to re-run against an existing environment.
#
#   ./setup.sh
#
set -euo pipefail

VENV="reachy_mini_env"
PY_VERSION="3.12"
cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- 1. prerequisites -------------------------------------------------------
info "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] || fail "This script targets macOS. On Linux, skip the dylib fixes below and install GStreamer via your package manager."

command -v uv >/dev/null 2>&1 || fail "uv not found. Install it with:
    curl -LsSf https://astral.sh/uv/install.sh | sh"

command -v git >/dev/null 2>&1 || fail "git not found. Install with: brew install git"

if command -v git-lfs >/dev/null 2>&1; then
    git lfs install --skip-repo >/dev/null 2>&1 || true
else
    warn "git-lfs not found (needed to download model assets). Install with: brew install git-lfs"
fi

# uv downloads the interpreter if it is missing.
uv python install "$PY_VERSION" >/dev/null 2>&1 || true
echo "    uv        $(uv --version | awk '{print $2}')"
echo "    git       $(git --version | awk '{print $3}')"

# --- 2. virtual environment -------------------------------------------------
if [ -d "$VENV" ]; then
    info "Reusing existing $VENV"
else
    info "Creating $VENV (Python $PY_VERSION)"
    uv venv "$VENV" --python "$PY_VERSION" --seed
fi

# --- 3. packages ------------------------------------------------------------
# Use pip inside the venv rather than `uv pip`: the upstream docs warn that uv
# has compatibility issues with MuJoCo on macOS.
info "Installing packages from requirements.txt (this pulls ~1.4 GB the first time)"
"./$VENV/bin/pip" install --quiet --upgrade pip
"./$VENV/bin/pip" install --quiet -r requirements.txt

# --- 4. macOS fix: shared libpython for mjpython -----------------------------
# mjpython dlopens @rpath/libpython3.12.dylib. uv's standalone CPython ships the
# dylib but not anywhere mjpython's rpath searches, so it fails to start at all
# with: Library not loaded: @rpath/libpython3.12.dylib
info "Linking libpython$PY_VERSION.dylib into the venv root (required by mjpython)"
LIBPYTHON=$("./$VENV/bin/python" -c \
    "import sysconfig, pathlib; print(pathlib.Path(sysconfig.get_config_var('installed_base')) / 'lib' / 'libpython${PY_VERSION}.dylib')")

[ -f "$LIBPYTHON" ] || fail "Could not find libpython${PY_VERSION}.dylib at: $LIBPYTHON"
ln -sfn "$LIBPYTHON" "$VENV/libpython${PY_VERSION}.dylib"
echo "    -> $LIBPYTHON"

# --- 5. macOS fix: disable the broken gstpython plugin ----------------------
# Documented upstream. The bundled plugin cannot resolve @rpath/libpython and
# fails to load; renaming stops GStreamer from trying. No loss of functionality.
GST_PLUGIN="$VENV/lib/python${PY_VERSION}/site-packages/gstreamer_python/lib/gstreamer-1.0/libgstpython.dylib"
if [ -f "$GST_PLUGIN" ]; then
    info "Disabling libgstpython.dylib (known upstream load failure)"
    mv "$GST_PLUGIN" "${GST_PLUGIN%.dylib}_.dylib"
else
    info "libgstpython.dylib already disabled or absent"
fi

# --- 6. verify --------------------------------------------------------------
info "Verifying"
"./$VENV/bin/python" - <<'PY'
import importlib.metadata as md
import mujoco, reachy_mini  # noqa: F401
print(f"    reachy-mini  {md.version('reachy-mini')}")
print(f"    mujoco       {mujoco.__version__}")
PY
"./$VENV/bin/mjpython" -c "print('    mjpython     launches OK')"

cat <<'EOF'

Done. Start the simulator with:

    source reachy_mini_env/bin/activate
    mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon

First start takes 50-90s (GStreamer rescans its plugin registry). Wait for
"Uvicorn running on http://127.0.0.1:8000", then verify with:

    python hello_sim.py

EOF
