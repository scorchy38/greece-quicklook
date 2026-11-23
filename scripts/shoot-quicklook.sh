#!/bin/zsh
# Captures the real Quick Look panel for a file (only that window), via the Greece app.
#   scripts/shoot-quicklook.sh <Greece.app> <file> <out.png> [--size 1000x720]
APP="$1"; FILE="$2"; OUT="$3"; shift 3
ID_FILE=$(mktemp)
"$APP/Contents/MacOS/Greece" --quicklook "$FILE" --hold 6 "$@" > "$ID_FILE" &
for i in {1..80}; do [[ -s "$ID_FILE" ]] && break; sleep 0.1; done
sleep 2.5
screencapture -x -o -l"$(head -1 "$ID_FILE")" "$OUT"
wait
rm -f "$ID_FILE"
