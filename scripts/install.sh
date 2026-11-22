#!/bin/bash
# Installs a built Greece.app into /Applications and verifies that Quick Look uses that copy.
#   scripts/install.sh [path/to/Greece.app]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
src="${1:-$repo/build/dd/Build/Products/Release/Greece.app}"
dest=/Applications/Greece.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
ids=(com.scorchy.greece.quicklook com.scorchy.greece.thumbnails)

# Stop the build product's extensions competing with the installed copy. (Never `lsregister -u`
# a copy: it can drop the shared bundle identifiers, and with them the installed registration.)
for appex in "$src"/Contents/PlugIns/*.appex; do pluginkit -r "$appex" 2>/dev/null || true; done

ditto "$src" "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"
"$lsregister" -f -R "$dest"

# Right after a copy, Launch Services may not have indexed the new bundle yet and the plugin
# registry silently ignores the add, so keep adding until the registry reports the copy.
for appex in "$dest"/Contents/PlugIns/*.appex; do
  id="$(defaults read "$appex/Contents/Info" CFBundleIdentifier)"
  for _ in $(seq 1 40); do
    pluginkit -a "$appex"
    pluginkit -m -A -D -v -i "$id" | grep -q "$dest" && break
    sleep 0.5
  done
  pluginkit -e use -i "$id"
done
qlmanage -r >/dev/null 2>&1 || true

# Any other copy (old downloads, build folders) competes with this one: remove them.
# (Launching a build's app, e.g. for a render, registers that copy again.)
for id in "${ids[@]}"; do
  others=$(pluginkit -m -A -D -v -i "$id" | awk -F'\t' '{print $NF}' | grep '^/' | grep -v "^$dest/" || true)
  while read -r other; do
    [[ -n "$other" ]] && { pluginkit -r "$other" 2>/dev/null || true; }
  done <<< "$others"
done

# The registry can lag when the Mac is busy; keep adding and enabling for up to 30 more seconds.
for appex in "$dest"/Contents/PlugIns/*.appex; do
  id="$(defaults read "$appex/Contents/Info" CFBundleIdentifier)"
  for attempt in $(seq 1 60); do
    pluginkit -m -A -D -v -i "$id" | grep -q "^+.*$dest" && break
    if [[ $attempt == 60 ]]; then
      echo "Quick Look did not register $id from $dest" >&2
      exit 1
    fi
    pluginkit -a "$appex" 2>/dev/null
    pluginkit -e use -i "$id" 2>/dev/null
    sleep 0.5
  done
done
echo "Installed $dest. Quick Look previews use it now."
echo "Finder thumbnails switch over when macOS restarts its thumbnail service (at the latest after you log out)."
