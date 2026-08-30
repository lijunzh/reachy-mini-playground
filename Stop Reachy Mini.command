#!/usr/bin/env bash
#
# Double-clickable companion to "Reachy Mini.command": shuts the stack down.
#
# Stops the app, daemon and realtime server. oMLX is left running because it
# holds a large model in memory and is slow to reload; pass --all below if you
# want that stopped too.
#
set -uo pipefail
cd "$(dirname "$0")" || exit 1

# Only when attached to a terminal; avoids noise if run non-interactively.
[ -t 1 ] && clear
./stop.sh

cat <<'EOF'

------------------------------------------------------------------
Stopped. oMLX was left running (it is slow to reload and useful on
its own). To stop that as well, run:

  ./stop.sh --all
------------------------------------------------------------------

Press return to close this window.
EOF
read -r _
