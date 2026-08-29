#!/usr/bin/env bash
#
# Start oMLX in the foreground with its prefix cache enabled. Run this before
# ./run-local-backend.sh. Settings come from local-backend.conf.
#
# For a background server that auto-restarts on crash, use brew instead:
#
#     brew services start omlx     # logs: $(brew --prefix)/var/log/omlx.log
#     brew services info omlx
#     omlx start | stop | restart
#
# That runs a bare `omlx serve`, which reads ~/.omlx/settings.json -- seeded by
# ./setup-llm-server.sh -- so the prefix cache is on there too. This script is
# the foreground equivalent, easier to watch and Ctrl-C.
#
set -euo pipefail
cd "$(dirname "$0")"

# Defaults; override in local-backend.conf.
OMLX_MODEL_DIR="$HOME/.lmstudio/models"   # reuse LM Studio's downloads
OMLX_HOST="127.0.0.1"
OMLX_PORT="8123"                          # not 8000: that is the Reachy daemon
OMLX_SSD_CACHE_DIR="$HOME/.omlx/cache"
OMLX_SSD_CACHE_MAX="20GB"
OMLX_HOT_CACHE_MAX="8GB"                  # absolute size; '20%' is rejected
# shellcheck disable=SC1091
[ -f local-backend.conf ] && . ./local-backend.conf
# shellcheck disable=SC1091
[ -f proxy.env ] && . ./proxy.env

OMLX=$(command -v omlx 2>/dev/null || echo /opt/homebrew/opt/omlx/bin/omlx)
[ -x "$OMLX" ] || {
    echo "error: omlx not installed. Run ./setup-llm-server.sh first." >&2; exit 1; }

mkdir -p "$OMLX_SSD_CACHE_DIR"

echo "==> omlx  : $OMLX_HOST:$OMLX_PORT  models=$OMLX_MODEL_DIR"
echo "==> cache : ssd=$OMLX_SSD_CACHE_DIR ($OMLX_SSD_CACHE_MAX)  hot=$OMLX_HOT_CACHE_MAX"
echo "    The prefix cache is what makes this fast at the app's ~9k-token turns."
echo "    These flags also persist into ~/.omlx/settings.json, so a later bare"
echo "    'omlx serve' (what brew services runs) keeps the same cache config."

exec "$OMLX" serve \
    --model-dir "$OMLX_MODEL_DIR" \
    --host "$OMLX_HOST" --port "$OMLX_PORT" \
    --paged-ssd-cache-dir "$OMLX_SSD_CACHE_DIR" \
    --paged-ssd-cache-max-size "$OMLX_SSD_CACHE_MAX" \
    --hot-cache-max-size "$OMLX_HOT_CACHE_MAX"
