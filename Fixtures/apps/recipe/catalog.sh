#!/bin/zsh
# Builds Fixtures/apps/ios/Catalog.ipa: an iOS app whose icon exists only in a compiled asset
# catalog (Assets.car), the way current Xcode ships icons. Usage: catalog.sh <repo>
set -e
REPO="$1"
SRC="${0:A:h}"
WORK="$(mktemp -d)"
ICONSET="$WORK/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$ICONSET" "$WORK/Payload/Catalog.app"
python3 -I "$SRC/icon.py" "$ICONSET/icon-1024.png" 1024
cat > "$WORK/Assets.xcassets/Contents.json" <<'J'
{ "info" : { "author" : "xcode", "version" : 1 } }
J
cat > "$ICONSET/Contents.json" <<'J'
{ "images" : [ { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
J
xcrun actool "$WORK/Assets.xcassets" --compile "$WORK/Payload/Catalog.app" --platform iphoneos --minimum-deployment-target 18.0 \
  --app-icon AppIcon --output-partial-info-plist "$WORK/partial.plist" --output-format human-readable-text > /dev/null
# Like apps built for recent iOS versions, keep the icon only in Assets.car.
rm -f "$WORK/Payload/Catalog.app"/AppIcon*.png
plutil -convert binary1 -o "$WORK/Payload/Catalog.app/Info.plist" "$SRC/Catalog-Info.plist"
rm -f "$REPO/Fixtures/apps/ios/Catalog.ipa"
( cd "$WORK" && zip -qr -X "$REPO/Fixtures/apps/ios/Catalog.ipa" Payload )
rm -rf "$WORK"
ls -la "$REPO/Fixtures/apps/ios/Catalog.ipa"
