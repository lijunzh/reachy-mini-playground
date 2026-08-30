#!/usr/bin/env bash
#
# Double-clickable launcher for Finder or the Dock.
#
# macOS opens a .command file in Terminal and runs it, so this is the
# click-to-start entry point: it brings the whole stack up, opens the
# conversation UI, and leaves the window showing how to stop.
#
# The repo directory is resolved from this file's own location, so the file can
# be dragged to the Dock or aliased anywhere.
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# Only when attached to a terminal; avoids noise if run non-interactively.
[ -t 1 ] && clear
./start.sh --headless
status=$?

if [ "$status" -ne 0 ]; then
    echo
    echo "Startup failed. The logs are in $(pwd)/logs/"
    echo "Press return to close this window."
    read -r _
    exit "$status"
fi

# Give the UI a moment, then open it.
if curl -s -m 5 -o /dev/null http://127.0.0.1:7860/ 2>/dev/null; then
    open http://127.0.0.1:7860
fi

cat <<EOF

------------------------------------------------------------------
Reachy Mini is running. The conversation UI should have opened.

  stop it      : double-click "Stop Reachy Mini.command"
                 or run ./stop.sh in this directory
  logs         : $(pwd)/logs/

Closing this window does NOT stop Reachy -- the servers keep running
in the background. Use the stop command above.
------------------------------------------------------------------

Press return to close this window.
EOF
read -r _
