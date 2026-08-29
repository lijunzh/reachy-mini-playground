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

# Seed ~/.omlx/settings.json. oMLX reads its config from there, so a bare
# `omlx serve` -- which is exactly what `brew services` runs -- picks up the
# prefix cache without any CLI flags. Without this the service would run with
# the cache off, which is the whole reason to prefer oMLX.
# Merge rather than overwrite: the file also holds the admin API key.
OMLX_PORT="${OMLX_PORT:-8123}"
OMLX_MODEL_DIR="${OMLX_MODEL_DIR:-$HOME/.lmstudio/models}"
OMLX_SSD_CACHE_DIR="${OMLX_SSD_CACHE_DIR:-$HOME/.omlx/cache}"
OMLX_SSD_CACHE_MAX="${OMLX_SSD_CACHE_MAX:-20GB}"
OMLX_HOT_CACHE_MAX="${OMLX_HOT_CACHE_MAX:-8GB}"
# shellcheck disable=SC1091
[ -f local-backend.conf ] && . ./local-backend.conf

info "Seeding ~/.omlx/settings.json (cache on, port $OMLX_PORT)"
mkdir -p "$HOME/.omlx" "$OMLX_SSD_CACHE_DIR"
OMLX_PORT="$OMLX_PORT" OMLX_MODEL_DIR="$OMLX_MODEL_DIR" \
OMLX_SSD_CACHE_DIR="$OMLX_SSD_CACHE_DIR" \
OMLX_SSD_CACHE_MAX="$OMLX_SSD_CACHE_MAX" \
OMLX_HOT_CACHE_MAX="$OMLX_HOT_CACHE_MAX" \
python3 - <<'PYEOF'
import json, os, pathlib
p = pathlib.Path.home() / ".omlx/settings.json"
d = json.loads(p.read_text()) if p.exists() else {}
srv = d.setdefault("server", {})
srv["port"] = int(os.environ["OMLX_PORT"])
srv["host"] = "127.0.0.1"
mdl = d.setdefault("model", {})
mdl["model_dir"] = os.environ["OMLX_MODEL_DIR"]
mdl["model_dirs"] = [os.environ["OMLX_MODEL_DIR"]]
c = d.setdefault("cache", {})
c["ssd_cache_dir"] = os.environ["OMLX_SSD_CACHE_DIR"]
c["ssd_cache_max_size"] = os.environ["OMLX_SSD_CACHE_MAX"]
c["hot_cache_max_size"] = os.environ["OMLX_HOT_CACHE_MAX"]
p.write_text(json.dumps(d, indent=2))
print(f"    port={srv['port']} cache={c['ssd_cache_dir']} "
      f"ssd={c['ssd_cache_max_size']} hot={c['hot_cache_max_size']}")
PYEOF

cat <<'MSG'

Done. Start it either way:

    ./run-llm-server.sh          # foreground, easiest to watch and Ctrl-C
    brew services start omlx     # background, auto-restarts on crash,
                                 # logs to $(brew --prefix)/var/log/omlx.log

Both use the same ~/.omlx/settings.json just written, so the prefix cache is on
in both. Admin console: http://127.0.0.1:8123/admin

Then copy local-backend.conf.example to local-backend.conf (it defaults to oMLX).

MSG
