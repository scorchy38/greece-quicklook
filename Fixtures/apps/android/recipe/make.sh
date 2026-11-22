#!/bin/zsh
# Rebuilds sample.apk, adaptive-unsigned.apk and sample.aab in the parent folder.
# Needs the Android SDK (build-tools 35 and platform 34) and a JDK for keytool, apksigner and jarsigner.
set -e
HERE=${0:A:h}
OUT=${HERE:h}
SDK=${ANDROID_HOME:-$HOME/Library/Android/sdk}
BT=$SDK/build-tools/35.0.0-rc4
JAR=$SDK/platforms/android-34/android.jar
W=$(mktemp -d)
trap 'rm -rf $W' EXIT

keytool -genkeypair -keystore $W/test.jks -storepass greece -keypass greece -alias greece -keyalg RSA -keysize 2048 \
  -validity 36500 -dname "CN=Greece Test, O=Greece, C=US" >/dev/null 2>&1

# sample.apk: binary manifest and resources.arsc, a DEX stub and a native library stub; v1, v2 and v3 signatures.
cp -R $HERE/sample $W/sample
mkdir -p $W/sample/res/mipmap-mdpi $W/sample/res/mipmap-xxxhdpi
python3 -I $HERE/makepng.py $W/sample/res
$BT/aapt2 compile --dir $W/sample/res -o $W/sample-res.zip
$BT/aapt2 link -o $W/sample-unsigned.apk -I $JAR --manifest $HERE/sample/AndroidManifest.xml $W/sample-res.zip
mkdir -p $W/extra/lib/arm64-v8a
printf 'dex\n035\0' > $W/extra/classes.dex
printf '\177ELF' > $W/extra/lib/arm64-v8a/libflutter.so
(cd $W/extra && zip -q $W/sample-unsigned.apk classes.dex lib/arm64-v8a/libflutter.so)
$BT/zipalign -f 4 $W/sample-unsigned.apk $W/sample-aligned.apk
$BT/apksigner sign --ks $W/test.jks --ks-pass pass:greece --min-sdk-version 26 \
  --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
  --out $OUT/sample.apk $W/sample-aligned.apk
rm -f $OUT/sample.apk.idsig

# adaptive-unsigned.apk: an adaptive icon (colour background, vector foreground), no bitmaps, no signature.
$BT/aapt2 compile --dir $HERE/adaptive/res -o $W/adaptive-res.zip
$BT/aapt2 link -o $OUT/adaptive-unsigned.apk -I $JAR --manifest $HERE/adaptive/AndroidManifest.xml $W/adaptive-res.zip

# sample.aab: the same app in App Bundle layout (protobuf manifest and resource table), signed with jarsigner.
$BT/aapt2 link --proto-format -o $W/proto.apk -I $JAR --manifest $HERE/sample/AndroidManifest.xml $W/sample-res.zip
mkdir -p $W/proto $W/aab/base/manifest $W/aab/base/dex $W/aab/base/lib/arm64-v8a
(cd $W/proto && unzip -q $W/proto.apk)
mv $W/proto/AndroidManifest.xml $W/aab/base/manifest/
mv $W/proto/resources.pb $W/aab/base/
mv $W/proto/res $W/aab/base/
cp $W/extra/classes.dex $W/aab/base/dex/
cp $W/extra/lib/arm64-v8a/libflutter.so $W/aab/base/lib/arm64-v8a/
printf '\x0a\x08\x12\x061.15.6' > $W/aab/BundleConfig.pb   # BundleConfig { bundletool { version: "1.15.6" } }
rm -f $OUT/sample.aab
(cd $W/aab && zip -q -r $OUT/sample.aab BundleConfig.pb base)
jarsigner -keystore $W/test.jks -storepass greece -keypass greece $OUT/sample.aab greece >/dev/null 2>&1
