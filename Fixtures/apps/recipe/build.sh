#!/bin/zsh
# Builds Greece's app/binary fixtures. Usage: build.sh <repo>
set -e
REPO="$1"
SRC="${0:A:h}"
WORK="$SRC/work"
rm -rf "$WORK"; mkdir -p "$WORK"
F="$REPO/Fixtures/apps"
mkdir -p "$F/macho" "$F/bundles" "$F/ios" "$F/profiles" "$F/torrent"

# --- Sources -----------------------------------------------------------------
cat > "$WORK/hello.c" <<'C'
#include <stdio.h>
int main(void) { puts("Greece"); return 0; }
C
cat > "$WORK/lib.c" <<'C'
int greece_answer(void) { return 42; }
C
cat > "$WORK/app.m" <<'C'
#import <AppKit/AppKit.h>
int main(int argc, const char **argv) { return NSApplicationMain(argc, argv); }
C
cat > "$SRC/tool-info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.scorchy.greece.fixture.tool</string>
<key>CFBundleName</key><string>greece-tool</string>
<key>CFBundleShortVersionString</key><string>1.4</string>
<key>CFBundleVersion</key><string>14</string>
</dict></plist>
P
cat > "$SRC/tool.entitlements" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.cs.allow-jit</key><true/>
<key>com.apple.security.cs.disable-library-validation</key><true/>
</dict></plist>
P

# --- Mach-O ------------------------------------------------------------------
clang -Os -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 -sectcreate __TEXT __info_plist "$SRC/tool-info.plist" "$WORK/hello.c" -o "$F/macho/greece-tool"
strip -x "$F/macho/greece-tool"
codesign -f -s - -o runtime --entitlements "$SRC/tool.entitlements" "$F/macho/greece-tool"
clang -Os -arch x86_64 -mmacosx-version-min=10.15 "$WORK/hello.c" -o "$F/macho/intel-tool"
strip -x "$F/macho/intel-tool"
clang -Os -arch arm64 -dynamiclib -mmacosx-version-min=13.0 -install_name @rpath/libgreece.dylib \
  -current_version 1.2.3 -compatibility_version 1.0 "$WORK/lib.c" -o "$F/macho/libgreece.dylib"
clang -Os -arch arm64 -c "$WORK/lib.c" -o "$F/macho/lib.o"

# --- Tiny.app ----------------------------------------------------------------
APP="$F/bundles/Tiny.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/en.lproj" "$APP/Contents/Resources/fr.lproj" "$APP/Contents/Resources/de.lproj" \
         "$APP/Contents/PlugIns/TinyPreview.appex/Contents/MacOS" "$APP/Contents/Library/LoginItems/TinyHelper.app/Contents/MacOS"
clang -Os -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework AppKit "$WORK/app.m" -o "$APP/Contents/MacOS/Tiny"
strip -x "$APP/Contents/MacOS/Tiny"
cp "$SRC/Tiny-Info.plist" "$APP/Contents/Info.plist"
cp "$SRC/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
for l in en fr de; do print -r -- '"CFBundleDisplayName" = "Tiny";' > "$APP/Contents/Resources/$l.lproj/InfoPlist.strings"; done
head -c 24000 /dev/urandom > "$APP/Contents/Resources/Assets.car"
clang -Os -arch arm64 -mmacosx-version-min=14.0 "$WORK/hello.c" -o "$APP/Contents/PlugIns/TinyPreview.appex/Contents/MacOS/TinyPreview"
strip -x "$APP/Contents/PlugIns/TinyPreview.appex/Contents/MacOS/TinyPreview"
cp "$SRC/Appex-Info.plist" "$APP/Contents/PlugIns/TinyPreview.appex/Contents/Info.plist"
cp "$APP/Contents/PlugIns/TinyPreview.appex/Contents/MacOS/TinyPreview" "$APP/Contents/Library/LoginItems/TinyHelper.app/Contents/MacOS/TinyHelper"
cp "$SRC/Helper-Info.plist" "$APP/Contents/Library/LoginItems/TinyHelper.app/Contents/Info.plist"
codesign -f -s - "$APP/Contents/PlugIns/TinyPreview.appex"
codesign -f -s - "$APP/Contents/Library/LoginItems/TinyHelper.app"
codesign -f -s - -o runtime --entitlements "$SRC/Tiny.entitlements" "$APP"
# A copy changed after signing.
rm -rf "$F/bundles/Tampered.app"
cp -R "$APP" "$F/bundles/Tampered.app"
print -r -- '"CFBundleDisplayName" = "Tampered";' > "$F/bundles/Tampered.app/Contents/Resources/fr.lproj/InfoPlist.strings"

# --- dSYM and xcarchive --------------------------------------------------------
clang -g -O0 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -c "$WORK/hello.c" -o "$WORK/hello-dbg.o"
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 "$WORK/hello-dbg.o" -o "$WORK/Tiny"
rm -rf "$F/bundles/Tiny.app.dSYM"
dsymutil "$WORK/Tiny" -o "$F/bundles/Tiny.app.dSYM"
ARCHIVE="$F/bundles/Tiny.xcarchive"
rm -rf "$ARCHIVE"
mkdir -p "$ARCHIVE/Products/Applications" "$ARCHIVE/dSYMs"
cp -R "$APP" "$ARCHIVE/Products/Applications/Tiny.app"
cp -R "$F/bundles/Tiny.app.dSYM" "$ARCHIVE/dSYMs/Tiny.app.dSYM"
cp "$SRC/Archive-Info.plist" "$ARCHIVE/Info.plist"

# --- Profiles: a self-signed "developer" identity signs everything -------------
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 \
  -subj "/CN=Apple Development: Greece Fixture (FIXTURE01)/OU=FIXTURE01/O=Greece Fixtures/C=US" 2>/dev/null
openssl x509 -in "$WORK/cert.pem" -outform DER -out "$WORK/cert.der"
python3 -I "$SRC/profiles.py" "$WORK/cert.der" "$WORK"
openssl cms -sign -binary -nodetach -outform DER -in "$WORK/profile.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" -out "$F/profiles/Tiny_Development.mobileprovision"
openssl cms -sign -binary -nodetach -outform DER -in "$WORK/expired.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" -out "$F/profiles/Expired_AdHoc.mobileprovision"
cp "$WORK/config.plist" "$F/profiles/Greece.mobileconfig"
openssl cms -sign -binary -nodetach -outform DER -in "$WORK/config.plist" -signer "$WORK/cert.pem" -inkey "$WORK/key.pem" -out "$F/profiles/Greece-Signed.mobileconfig"

# --- Tiny.ipa ------------------------------------------------------------------
IOS="$WORK/Payload/Tiny.app"
mkdir -p "$IOS"
xcrun --sdk iphoneos clang -Os -arch arm64 -miphoneos-version-min=16.0 "$WORK/hello.c" -o "$IOS/Tiny"
strip -x "$IOS/Tiny"
plutil -convert binary1 -o "$IOS/Info.plist" "$SRC/iOS-Info.plist"
cp "$F/profiles/Tiny_Development.mobileprovision" "$IOS/embedded.mobileprovision"
python3 -I "$SRC/icon.py" "$WORK/icon.png"
xcrun --sdk iphoneos pngcrush -q -iphone "$WORK/icon.png" "$IOS/AppIcon60x60@2x.png"
codesign -f -s - --entitlements "$SRC/iOS.entitlements" "$IOS"
rm -f "$F/ios/Tiny.ipa"
( cd "$WORK" && zip -qr -X "$F/ios/Tiny.ipa" Payload )

# --- Torrents --------------------------------------------------------------------
python3 -I "$SRC/torrent.py" "$F/torrent"
du -sh "$F"/*
