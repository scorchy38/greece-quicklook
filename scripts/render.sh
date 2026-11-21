#!/bin/zsh
# Renders previews to PNG through the same code path Quick Look uses.
#   scripts/render.sh <app> <out-dir> [--appearance dark] [--theme one] files...
set -e
APP="$1"; OUT="$2"; shift 2
EXTRA=()
while [[ "$1" == --* ]]; do EXTRA+=("$1" "$2"); shift 2; done
mkdir -p "$OUT"
for f in "$@"; do
  name=$(basename "$f")
  "$APP/Contents/MacOS/Greece" --render "$f" "$OUT/${name}.png" "${EXTRA[@]}" || echo "failed: $f"
done
