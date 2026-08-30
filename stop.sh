#!/usr/bin/env bash
#
# Shut the Reachy Mini stack down.
#
#   ./stop.sh          # stop the app, daemon and realtime server
#   ./stop.sh --all    # also stop the oMLX LLM server
#
# oMLX is left running by default: it is a general LLM server that holds a
# large model in memory and is slow to reload, and it is useful independently
# of Reachy. Use --all when you want the memory back.
#
set -uo pipefail
cd "$(dirname "$0")"

ALL=0
for arg in "$@"; do
    case "$arg" in
        --all)     ALL=1 ;;
        -h|--help) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)         echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done

step() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$1"; }

up() { lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; }

# stop_port <port> <label>: kill whatever holds the port. More reliable than
# matching on the command line -- oMLX renames itself to "omlx-server", so a
# pattern built from its launch path matches nothing and silently reports
# success.
stop_port() {
    local port=$1 label=$2 pid
    pid=$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | head -1)
    if [ -z "$pid" ]; then
        ok "$label already stopped"
        return
    fi
    kill "$pid" 2>/dev/null
    for _ in 1 2 3 4 5; do
        up "$port" || break
        sleep 1
    done
    up "$port" && kill -9 "$pid" 2>/dev/null
    sleep 1
    up "$port" && printf '    \033[31mstill listening\033[0m %s on :%s\n' "$label" "$port" \
               || ok "$label stopped"
}

# stop_pattern <pattern> <label>: ask nicely, then insist.
stop_pattern() {
    local pat=$1 label=$2
    if ! pgrep -f "$pat" >/dev/null 2>&1; then
        ok "$label already stopped"
        return
    fi
    pkill -f "$pat" 2>/dev/null
    for _ in 1 2 3 4 5; do
        pgrep -f "$pat" >/dev/null 2>&1 || break
        sleep 1
    done
    pgrep -f "$pat" >/dev/null 2>&1 && pkill -9 -f "$pat" 2>/dev/null
    sleep 1
    pgrep -f "$pat" >/dev/null 2>&1 && printf '    \033[31mstill running\033[0m %s\n' "$label" \
                                    || ok "$label stopped"
}

# Ask the daemon to stop the app first so it releases the robot lock cleanly,
# rather than being killed mid-turn.
step "Conversation app"
if up 8000; then
    curl -s -m 30 -X POST http://127.0.0.1:8000/api/apps/stop-current-app >/dev/null 2>&1
    sleep 2
fi
stop_pattern "apps_venv/bin/python" "app"

step "Daemon"
stop_pattern "reachy_mini.daemon.app.main" "daemon"

step "Realtime server"
stop_pattern "s2s_venv/bin/speech-to-speech" "speech-to-speech"

if [ "$ALL" = "1" ]; then
    step "LLM server"
    stop_port 8123 "oMLX"
fi

echo
printf '\033[1m%s\033[0m\n' "Ports"
for spec in "8000:daemon" "7860:app UI" "8765:realtime" "8123:oMLX"; do
    p=${spec%%:*}; n=${spec##*:}
    if up "$p"; then printf '  :%-5s %-10s still listening\n' "$p" "$n"
    else            printf '  :%-5s %-10s free\n' "$p" "$n"; fi
done
[ "$ALL" = "0" ] && up 8123 && echo "  (oMLX left running; ./stop.sh --all to stop it too)"
exit 0
