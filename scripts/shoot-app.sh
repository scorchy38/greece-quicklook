#!/bin/zsh
# Captures one page of the Greece app window (and nothing else on screen).
#   scripts/shoot-app.sh <Greece.app> <page> <out.png> [--appearance dark]
APP="$1"; PAGE="$2"; OUT="$3"; shift 3
"$APP/Contents/MacOS/Greece" --render-app "$PAGE" /dev/null --print-window "$@" > /tmp/greece-window-id &
for i in {1..60}; do [[ -s /tmp/greece-window-id ]] && break; sleep 0.1; done
sleep 0.3
screencapture -x -o -l"$(head -1 /tmp/greece-window-id)" "$OUT"
wait
rm -f /tmp/greece-window-id
