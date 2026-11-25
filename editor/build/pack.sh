set -e
cd /d/Users/Daniel/code/Kiro/Android-Watch-APK-Build/editor
powershell -NoProfile -ExecutionPolicy Bypass -File build/stop_editor.ps1
sleep 1
export PATH=/d/tools/flutter/flutter/bin:$PATH
flutter build windows --release 2>&1 | tail -3
echo "build has searchEngine: $(grep -c -a searchEngine build/windows/x64/runner/Release/data/app.so)"
ENV_DIR=/d/Users/Daniel/code/DSH/watch/env R8_SRC=/d/Users/Daniel/code/DSH/watch/cs2watch/tools/r8.jar bash scripts/package_portable.sh 2>&1 | tail -3
X="../dist/安卓手表软件编辑器-便携版-win-x64/安卓手表软件编辑器"
if [ -d "$X" ]; then cp -r build/windows/x64/runner/Release/. "$X/"; echo "extracted copy updated: $(grep -c -a searchEngine "$X/data/app.so")"; fi
