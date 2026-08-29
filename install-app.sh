#!/usr/bin/env bash
#
# Install a Reachy Mini app into apps_venv via the running daemon, then apply
# the dependency pins that app needs. Idempotent.
#
#   ./install-app.sh                                  # conversation app
#   ./install-app.sh reachy_mini_radio                # any listed app
#
# The daemon must already be running with --desktop-app-daemon so apps install
# into a sibling apps_venv instead of mutating reachy_mini_env.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-reachy_mini_conversation_app}"
DAEMON="http://127.0.0.1:8000"
PY="./reachy_mini_env/bin/python"

info() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

curl -sf -m 5 "$DAEMON/" >/dev/null 2>&1 || fail "daemon not reachable at $DAEMON.
Start it first:
    ./reachy_mini_env/bin/mjpython -m reachy_mini.daemon.app.main --sim --desktop-app-daemon"

info "Looking up '$APP' in the catalogue"
curl -s -m 60 "$DAEMON/api/apps/list-available" > /tmp/rm_apps.json
$PY - "$APP" <<'PY' > /tmp/rm_app_payload.json
import json, sys
apps = json.load(open("/tmp/rm_apps.json"), strict=False)
match = [a for a in apps if a["name"] == sys.argv[1]]
if not match:
    sys.exit(f"app '{sys.argv[1]}' not found in catalogue")
json.dump(match[0], sys.stdout)
PY

info "Installing (this can take several minutes; apps_venv is ~1.3 GB)"
JOB=$(curl -s -m 120 -X POST "$DAEMON/api/apps/install" \
        -H "Content-Type: application/json" \
        -d @/tmp/rm_app_payload.json | $PY -c "import json,sys; print(json.load(sys.stdin)['job_id'])")

while :; do
    STATUS=$(curl -s -m 15 "$DAEMON/api/apps/job-status/$JOB" \
             | $PY -c "import json,sys; print(json.load(sys.stdin, strict=False).get('status',''))")
    case "$STATUS" in
        done)   info "Install finished"; break ;;
        failed|error) fail "install job reported: $STATUS" ;;
        *)      sleep 10 ;;
    esac
done

# The conversation app declares mcp>=1.27.1 with no upper bound, so a fresh
# install pulls mcp 2.x, whose streamable_http_client yields a 2-tuple while the
# app unpacks 3. Every remote tool (search/time/weather) then fails with
# "unhandled errors in a TaskGroup" hiding
# "ValueError: not enough values to unpack (expected 3, got 2)".
if [ -f apps_venv/bin/pip ]; then
    CURRENT=$(./apps_venv/bin/python -c "import importlib.metadata as m; print(m.version('mcp'))" 2>/dev/null || echo none)
    case "$CURRENT" in
        2.*|none) info "Constraining to mcp<2 (currently $CURRENT) — required for remote tools"
                  # Constrain the major, not a patch: the incompatibility is with
                  # 2.x, and pinning an exact patch just goes stale. pip takes the
                  # newest 1.x.
                  ./apps_venv/bin/pip install --quiet "mcp<2" ;;
        *)        info "mcp $CURRENT already <2, leaving it alone" ;;
    esac
    ./apps_venv/bin/python -c "import importlib.metadata as m; print('    mcp', m.version('mcp'))"
fi

cat <<MSG

Installed '$APP'. Start it with:

    curl -X POST $DAEMON/api/apps/start-app/$APP

MSG
