#!/usr/bin/env bash
# Builds cs2watch_round.apk with the plain SDK toolchain (no Gradle).
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

KEYSTORE="$ROOT/debug.keystore"
KS_PASS="android"

rm -rf "$OUT"
mkdir -p "$OUT/gen" "$OUT/classes" "$OUT/dex" "$OUT/res"

echo "==> aapt2 compile"
"$BT/aapt2.exe" compile --dir "$APP/res" -o "$OUT/res/app.zip" --no-crunch

echo "==> aapt2 link"
"$BT/aapt2.exe" link \
  -o "$OUT/base.apk" \
  -I "$PLATFORM" \
  --manifest "$APP/AndroidManifest.xml" \
  --java "$OUT/gen" \
  --min-sdk-version 26 --target-sdk-version 30 \
  --version-code 1 --version-name 1.0 \
  "$OUT/res/app.zip"

echo "==> javac"
SOURCES=$(find "$APP/src" "$OUT/gen" -name '*.java')
"$JDK/bin/javac" -source 8 -target 8 -nowarn -encoding UTF-8 \
  -classpath "$PLATFORM" -d "$OUT/classes" $SOURCES

echo "==> d8"
CLASSES=$(find "$OUT/classes" -name '*.class')
# The d8 shipped in build-tools 33.0.2 (R8 3.3.20) crashes with an NPE on classes
# compiled by modern javac, so prefer the newer tools/r8.jar when it is present.
D8JAR="$BT/lib/d8.jar"
[ -f "$ROOT/tools/r8.jar" ] && D8JAR="$ROOT/tools/r8.jar"
"$JDK/bin/java" -cp "$D8JAR" com.android.tools.r8.D8 \
  --min-api 26 --lib "$PLATFORM" --output "$OUT/dex" $CLASSES

echo "==> package"
cp "$OUT/base.apk" "$OUT/unsigned.apk"
# The bundled JBR has no `jar` tool, so add classes.dex with python's zipfile.
"$PYTHON" "$ROOT/tools/adddex.py" "$OUT/unsigned.apk" "$OUT/dex/classes.dex"

echo "==> zipalign"
"$BT/zipalign.exe" -f -p 4 "$OUT/unsigned.apk" "$OUT/aligned.apk"

echo "==> sign"
if [ ! -f "$KEYSTORE" ]; then
  "$JDK/bin/keytool" -genkeypair -v -keystore "$KEYSTORE" -alias cs2watch \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -storepass "$KS_PASS" -keypass "$KS_PASS" \
    -dname "CN=CS2 Watch, OU=dev, O=dsh, L=-, S=-, C=CN" >/dev/null 2>&1
fi
JAVA_HOME="$JWIN" "$BT/apksigner.bat" sign --ks "$KEYSTORE" --ks-key-alias cs2watch \
  --ks-pass "pass:$KS_PASS" --key-pass "pass:$KS_PASS" \
  --out "$ROOT/cs2watch_round.apk" "$OUT/aligned.apk"

JAVA_HOME="$JWIN" "$BT/apksigner.bat" verify "$ROOT/cs2watch_round.apk" && echo "==> signed OK"
ls -la "$ROOT/cs2watch_round.apk"
