#!/usr/bin/env bash
# usage: tools/shot.sh name [tap x y]...   -> shots/name.png (+ rim check)
# Debug helper for the round watch: optional taps, then screencap via exec-out.
ADB="timeout 20 /d/Users/Daniel/code/DSH/watch/env/android-sdk/platform-tools/adb.exe"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
name="$1"; shift
while [ $# -ge 3 ] && [ "$1" = tap ]; do $ADB shell input tap "$2" "$3"; sleep 2.5; shift 3; done
$ADB exec-out screencap -p > "$ROOT/shots/$name.png"
echo "$name.png $(stat -c %s "$ROOT/shots/$name.png") bytes; $($ADB shell dumpsys window | grep mCurrentFocus | sed 's/.*u0 //')"
"${PY:-python}" "$ROOT/tools/rimcheck.py" "$ROOT/shots/$name.png"
