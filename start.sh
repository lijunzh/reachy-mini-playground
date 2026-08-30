#!/usr/bin/env bash
#
# Bring up the whole Reachy Mini stack in one command.
#
#   ./start.sh              # simulator with the MuJoCo viewer
#   ./start.sh --headless   # no viewer (saves ~200% CPU: the camera feed)
#   ./start.sh --cloud      # skip the local LLM/realtime servers, use the
#                           # hosted Hugging Face backend instead
#
# Start order is load-bearing -- the realtime server refuses to start without
# an LLM behind it, and the app needs the daemon -- so each step waits for the
# previous one to answer rather than sleeping and hoping.
#
# Idempotent: anything already running is left alone. Logs go to logs/.
#
set -uo pipefail
cd "$(dirname "$0")"

APP_NAME="reachy_mini_conversation_app"
SIM_WINDOW_TITLE="Reachy Mini Simulator"
LOGS="logs"
DAEMON_ARGS="--sim --desktop-app-daemon"
CLOUD=0
HEADLESS=0

for arg in "$@"; do
    case "$arg" in
        --headless) DAEMON_ARGS="$DAEMON_ARGS --headless"; HEADLESS=1 ;;
        --cloud)    CLOUD=1 ;;
        -h|--help)  sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

mkdir -p "$LOGS"

bold()  { printf '\033[1m%s\033[0m\n' "$1"; }
step()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
ok()    { printf '    \033[32mok\033[0m  %s\n' "$1"; }
warn()  { printf '    \033[33mwarn\033[0m %s\n' "$1"; }
die()   { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# up <port> -- is something listening?
up() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# wait_for <port> <seconds> <label> <logfile>
wait_for() {
    local port=$1 limit=$2 label=$3 log=$4 waited=0
    while ! up "$port"; do
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge "$limit" ]; then
            echo
            die "$label did not come up on :$port within ${limit}s.
Last lines of $log:
$(tail -5 "$log" 2>/dev/null | sed 's/^/    /')"
        fi
        [ $((waited % 10)) -eq 0 ] && printf '    ... %ss\n' "$waited"
    done
    ok "$label on :$port (${waited}s)"
}

bold "Reachy Mini"
[ "$CLOUD" = "1" ] && echo "  backend: hosted Hugging Face (--cloud)" \
                   || echo "  backend: local (oMLX + speech-to-speech)"

# --- 1. LLM server ----------------------------------------------------------
if [ "$CLOUD" = "0" ]; then
    step "LLM server (oMLX)"
    if up 8123; then
        ok "already running on :8123"
    else
        [ -x ./run-llm-server.sh ] || die "run-llm-server.sh missing"
        nohup ./run-llm-server.sh > "$LOGS/omlx.log" 2>&1 &
        wait_for 8123 180 "oMLX" "$LOGS/omlx.log"
    fi

    # --- 2. realtime server -------------------------------------------------
    step "Realtime server (speech-to-speech)"
    if up 8765; then
        ok "already running on :8765"
    else
        [ -x ./run-local-backend.sh ] || die "run-local-backend.sh missing"
        nohup ./run-local-backend.sh > "$LOGS/s2s.log" 2>&1 &
        # First run downloads ~2.5 GB of STT/TTS weights.
        wait_for 8765 900 "speech-to-speech" "$LOGS/s2s.log"
    fi
fi

# --- 3. daemon --------------------------------------------------------------
step "Daemon (simulator)"
if up 8000; then
    ok "already running on :8000"
else
    [ -x ./reachy_mini_env/bin/mjpython ] || die "reachy_mini_env missing. Run ./setup.sh first."
    if [ "$HEADLESS" = "1" ]; then
        # shellcheck disable=SC2086
        nohup ./reachy_mini_env/bin/mjpython -m reachy_mini.daemon.app.main $DAEMON_ARGS \
            > "$LOGS/daemon.log" 2>&1 &
    else
        # mjpython needs the main thread of a real session to own the MuJoCo
        # window. Backgrounded with `nohup ... &` the daemon still serves, but
        # no viewer ever appears -- and it dies when the launching window
        # closes. Give it its own Terminal window so the viewer works and it
        # outlives this script.
        echo "    opening a Terminal window for the viewer"
        # Tag the window so stop.sh can close exactly this one later, rather
        # than guessing at Terminal windows -- one of which is running stop.sh.
        osascript >/dev/null 2>&1 <<OSA
tell application "Terminal"
    set t to do script "cd $(pwd | sed 's/"/\\"/g') && ./reachy_mini_env/bin/mjpython -m reachy_mini.daemon.app.main $DAEMON_ARGS 2>&1 | tee $LOGS/daemon.log"
    try
        set custom title of (first window whose tabs contains t) to "$SIM_WINDOW_TITLE"
    end try
    activate
end tell
OSA
        [ $? -ne 0 ] && die "could not open a Terminal window for the daemon.
Run it yourself in a terminal:
    ./reachy_mini_env/bin/mjpython -m reachy_mini.daemon.app.main $DAEMON_ARGS"
    fi
    # GStreamer rescans its plugin registry in-process on every launch.
    wait_for 8000 240 "daemon" "$LOGS/daemon.log"
fi

# --- 4. conversation app ----------------------------------------------------
step "Conversation app"

# Install on first run rather than making the user notice a missing app and go
# read the setup docs. install-app.sh needs the daemon, which is now up.
installed() {
    curl -s -m 15 "http://127.0.0.1:8000/api/apps/list-available/installed" 2>/dev/null \
        | grep -q "\"name\":\"$APP_NAME\""
}
if ! installed; then
    warn "$APP_NAME is not installed yet"
    [ -x ./install-app.sh ] || die "install-app.sh missing"
    echo "    installing (several minutes; apps_venv is ~1.3 GB)"
    if ! ./install-app.sh > "$LOGS/install-app.log" 2>&1; then
        die "install failed. See $LOGS/install-app.log"
    fi
    installed || die "install reported success but the app is not listed. See $LOGS/install-app.log"
    ok "installed"
fi

state() {
    curl -s -m 5 http://127.0.0.1:8000/api/apps/current-app-status 2>/dev/null \
        | sed -n 's/.*"state":"\([a-z]*\)".*/\1/p'
}
current=$(state)
if [ "$current" = "running" ]; then
    ok "already running"
else
    curl -s -m 60 -X POST "http://127.0.0.1:8000/api/apps/start-app/$APP_NAME" >/dev/null 2>&1
    waited=0
    while :; do
        s=$(state)
        case "$s" in
            running) ok "started (${waited}s)"; break ;;
            error)   die "app failed to start. See $LOGS/daemon.log" ;;
        esac
        sleep 3; waited=$((waited + 3))
        [ "$waited" -ge 180 ] && die "app did not reach running within 180s. See $LOGS/daemon.log"
        [ $((waited % 15)) -eq 0 ] && printf '    ... %ss\n' "$waited"
    done
fi

# --- health -----------------------------------------------------------------
# "running" only means the app process is alive; it does not mean the app
# reached its realtime backend. Check the socket rather than trusting the state.
if [ "$CLOUD" = "0" ]; then
    # The app reports "running" as soon as its process is alive, then connects
    # to the realtime backend a few seconds later, so this has to be given a
    # window rather than checked once.
    waited=0
    while ! lsof -nP -iTCP:8765 -sTCP:ESTABLISHED 2>/dev/null | grep -q 8765; do
        sleep 2; waited=$((waited + 2))
        if [ "$waited" -ge 60 ]; then
            warn "app is running but never connected to :8765 -- check $LOGS/daemon.log"
            break
        fi
    done
    [ "$waited" -lt 60 ] && ok "app connected to the realtime backend (${waited}s)"
fi

echo
bold "Ready"
echo "  conversation UI : http://127.0.0.1:7860"
echo "  daemon API      : http://127.0.0.1:8000"
[ "$CLOUD" = "0" ] && echo "  oMLX admin      : http://127.0.0.1:8123/admin"
echo "  logs            : $LOGS/"
echo "  stop with       : ./stop.sh"
