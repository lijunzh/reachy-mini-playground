#!/usr/bin/env bash
#
# Optional: install oMLX, the recommended local LLM server for the conversation
# app. Idempotent. See README, "Which LLM server".
#
# Not part of ./setup.sh on purpose: this pulls ~3.6 GB (omlx, llvm@22, rust,
# python@3.11) from a third-party tap and compiles Rust, which takes a while.
# The simulator itself does not need it, and LM Studio with a GGUF model is a
# workable alternative.
#
set -euo pipefail
cd "$(dirname "$0")"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "macOS only."
[ "$(uname -m)" = "arm64" ] || fail "Apple Silicon required."
command -v brew >/dev/null 2>&1 || fail "Homebrew not found: https://brew.sh"

if command -v omlx >/dev/null 2>&1 || [ -x /opt/homebrew/opt/omlx/bin/omlx ]; then
    info "omlx already installed"
else
    info "Installing omlx from the jundot/omlx tap (~3.6 GB, compiles Rust)"
    # The mlx-audio resource is a git clone that can stall; make git give up and
    # retry rather than hang forever.
    git config --global http.lowSpeedLimit 1000
    git config --global http.lowSpeedTime 60
    brew install jundot/omlx/omlx
fi

OMLX=$(command -v omlx || echo /opt/homebrew/opt/omlx/bin/omlx)
info "Verifying"
echo "    omlx $("$OMLX" --version 2>&1 | head -1)"

cat <<'MSG'

Done. Start it with:

    ./run-llm-server.sh

Then point the realtime backend at it by copying local-backend.conf.example to
local-backend.conf (it already defaults to omlx).

MSG
