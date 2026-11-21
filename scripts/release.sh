#!/bin/bash
# Builds a universal Release, signs it, packages a drag-to-Applications DMG, and notarizes it
# when a Developer ID certificate and a notarytool profile are available.
#
#   scripts/release.sh [output-dir]
#
# Environment:
#   GREECE_SIGNING_IDENTITY  signing identity (default: first "Developer ID Application", else "Apple Development")
#   GREECE_NOTARY_PROFILE    `xcrun notarytool store-credentials` profile name, required to notarize
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$repo/build/release}"
mkdir -p "$out"
command -v xcodegen >/dev/null || { echo "Install XcodeGen: brew install xcodegen" >&2; exit 1; }
command -v create-dmg >/dev/null || { echo "Install create-dmg: brew install create-dmg" >&2; exit 1; }

identity="${GREECE_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)"
fi
developer_id=1
if [[ -z "$identity" ]]; then
  identity="Apple Development"
  developer_id=0
fi
echo "Signing with: $identity"

cd "$repo"
xcodegen generate --quiet
xcodebuild -project Greece.xcodeproj -scheme Greece -configuration Release \
  -derivedDataPath "$out/dd" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$identity" OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
app="$out/dd/Build/Products/Release/Greece.app"
codesign --verify --deep --strict "$app"
# Building registers the product's extensions with macOS; don't let a packaging build take over
# Quick Look from the installed copy.
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
for appex in "$app"/Contents/PlugIns/*.appex; do pluginkit -r "$appex" 2>/dev/null || true; done
"$lsregister" -u "$app" 2>/dev/null || true
version="$(defaults read "$app/Contents/Info" CFBundleShortVersionString)"
dmg="$out/Greece-$version.dmg"

staging="$(mktemp -d -t greece-dmg)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$staging/payload"
ditto "$app" "$staging/payload/Greece.app"
swift "$repo/scripts/dmg-background.swift" "$staging/background.png"
create-dmg --overwrite --volname Greece \
  --window-pos 200 140 --window-size 680 440 \
  --background "$staging/background.png" \
  --icon-size 112 --text-size 14 \
  --icon Greece.app 180 220 --hide-extension Greece.app \
  --app-drop-link 500 220 --filesystem APFS --format ULFO \
  --no-internet-enable "$dmg" "$staging/payload" >/dev/null
hdiutil verify "$dmg" >/dev/null
codesign --sign "$identity" --timestamp "$dmg"

if [[ $developer_id -eq 1 && -n "${GREECE_NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$dmg" --keychain-profile "$GREECE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dmg"
  spctl --assess --type open --context context:primary-signature -v "$dmg"
  echo "Notarized: $dmg"
else
  echo "Built: $dmg"
  echo "Not notarized. Other Macs will block it until it is signed with a Developer ID Application"
  echo "certificate and notarized (set GREECE_NOTARY_PROFILE after: xcrun notarytool store-credentials)."
fi
