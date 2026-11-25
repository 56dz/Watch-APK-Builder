#!/usr/bin/env bash
# Five-step APK build with the plain SDK toolchain (no Gradle, no Android Studio).
#
# Layout expected:
#   <root>/build.sh              this file
#   <root>/app/AndroidManifest.xml
#   <root>/app/res/...           res/ dir that aapt2 compiles
#   <root>/app/src/...           java sources (any package layout)
#   <root>/tools/r8.jar          newer R8, preferred over build-tools' d8 (see pitfall)
#   <root>/tools/adddex.py       puts classes.dex into the apk
#   <root>/../env/android-sdk    or pass SDK=...
#   <root>/../env/jdk            or pass JDK=...
#
# Usage: bash build.sh    → builds <root>/app.apk and verifies the signature.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="${SDK:-$ROOT/../env/android-sdk}"
BT="$SDK/build-tools/33.0.2"
PLATFORM="$SDK/platforms/android-33/android.jar"
JDK="${JDK:-$ROOT/../env/jdk}"
# apksigner.bat is a Windows batch file: JAVA_HOME must be a native path, not /d/...
JWIN="$(cygpath -w "$JDK" 2>/dev/null || echo "$JDK")"
PYTHON="${PYTHON:-$ROOT/../env/venv/Scripts/python.exe}"
OUT="$ROOT/build"
APP="$ROOT/app"
APK="$ROOT/app.apk"

KEYSTORE="$ROOT/debug.keystore"
KS_PASS="android"
KS_ALIAS="watchdebug"

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex" "$OUT/res"

echo "==> aapt2 compile"
# --no-crunch keeps PNGs as-is: faster, and screenshots/vectors need no crunching.
"$BT/aapt2.exe" compile --dir "$APP/res" -o "$OUT/res/app.zip" --no-crunch

echo "==> aapt2 link"
# --java generates R.java into $OUT/gen, which javac compiles together with app/src.
"$BT/aapt2.exe" link \
  -o "$OUT/base.apk" \
  -I "$PLATFORM" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version 26 --target-sdk-version 27 \
  --version-code 1 --version-name 1.0 \
  "$OUT/res/app.zip"

echo "==> javac"
# -source/-target 8: the watch runs ART on API 27, and d8 is happiest with 8.
# org.json is NOT in the apk: android.jar has stubs only, and the real classes come
# from the framework at runtime. Never add json.jar to the classpath of the apk.
SOURCES=$(find "$APP/src" "$OUT/gen" -name '*.java')
"$JDK/bin/javac" -source 8 -target 8 -nowarn -encoding UTF-8 \
  -classpath "$PLATFORM" -d "$OUT/classes" $SOURCES

echo "==> d8"
CLASSES=$(find "$OUT/classes" -name '*.class')
# The d8 inside build-tools 33.0.2 (R8 3.3.20) throws an NPE on classes produced by
# a modern javac, so use the newer tools/r8.jar whenever it exists.
D8JAR="$BT/lib/d8.jar"
[ -f "$ROOT/tools/r8.jar" ] && D8JAR="$ROOT/tools/r8.jar"
# The editor ships r8.jar with its bundled toolchain and exports R8_JAR.
[ -n "${R8_JAR:-}" ] && [ -f "${R8_JAR:-}" ] && D8JAR="$R8_JAR"
"$JDK/bin/java" -cp "$D8JAR" com.android.tools.r8.D8 \
  --min-api 26 --lib "$PLATFORM" --output "$OUT/dex" $CLASSES

echo "==> package"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
# The bundled JBR ships no `jar` tool, so classes.dex is added with python's zipfile.
"$PYTHON" "$ROOT/tools/adddex.py" "$OUT/unsigned.apk" "$OUT/dex/classes.dex"

echo "==> zipalign"
# -p 4 must run BEFORE signing; apksigner refuses a misaligned archive otherwise.
"$BT/zipalign.exe" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "==> sign"
if [ ! -f "$KEYSTORE" ]; then
  "$JDK/bin/keytool" -genkeypair -v -keystore "$KEYSTORE" -alias "$KS_ALIAS" \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=Watch Debug, OU=dev, O=watch, L=-, S=-, C=CN" >/dev/null 2>&1
fi
# JAVA_HOME is mandatory for apksigner.bat; without it the wrapper cannot find java.
JAVA_HOME="$JWIN" "$BT/apksigner.bat" sign --ks "$KEYSTORE" --ks-key-alias "$KS_ALIAS" \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out "$APK" "$OUT/aligned.apk"

JAVA_HOME="$JWIN" "$BT/apksigner.bat" verify "$APK" && echo "==> signed OK"
ls -la "$APK"
