#!/usr/bin/env bash
#
# Create the speech-to-speech environment used for the fully local conversation
# backend (no cloud). Idempotent. See README, "Fully local backend (no cloud)".
#
#   ./setup-local-backend.sh            # pinned direct dependency
#   ./setup-local-backend.sh --locked   # exact transitive versions
#
set -euo pipefail

VENV="s2s_venv"
PY_VERSION="3.12"
cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

LOCKED=0
[ "${1:-}" = "--locked" ] && LOCKED=1

command -v uv >/dev/null 2>&1 || fail "uv not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"

if [ -d "$VENV" ]; then
    info "Reusing existing $VENV"
else
    info "Creating $VENV (Python $PY_VERSION)"
    uv venv "$VENV" --python "$PY_VERSION" --seed
fi

if [ "$LOCKED" = "1" ]; then
    info "Installing exact locked versions (~1.7 GB)"
    "./$VENV/bin/pip" install --quiet -r requirements-s2s.lock.txt
else
    info "Installing speech-to-speech (~1.7 GB)"
    "./$VENV/bin/pip" install --quiet -r requirements-s2s.txt
fi

info "Verifying"
"./$VENV/bin/python" -c "import importlib.metadata as m; print('    speech-to-speech', m.version('speech-to-speech'))"

cat <<'MSG'

Done. Start the realtime server BEFORE the daemon and app:

    ./run-local-backend.sh

Model weights (~2.5 GB: Smart Turn VAD, Parakeet TDT, Qwen3-TTS) download on
first run into ~/.cache/huggingface.

MSG
