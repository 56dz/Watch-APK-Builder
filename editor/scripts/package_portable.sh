#!/usr/bin/env bash
# 打包“安卓手表软件编辑器”便携版：exe + 全部依赖（adb、SDK 精简版、JDK、Python、Git Bash、r8.jar）。
# 解压即用，不依赖目标电脑上的任何安装。
#
# 用法：bash scripts/package_portable.sh
# 必须指定来源：ENV_DIR（含 android-sdk/ jdk/）、R8_SRC（r8.jar）；可选 GIT_DIR、PY_ZIP、OUT_DIR
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # editor/
REPO="$(cd "$HERE/.." && pwd)"
: "${ENV_DIR:?请设置 ENV_DIR=含 android-sdk/ 和 jdk/ 的目录}"
GIT_DIR="${GIT_DIR:-/c/Program Files/Git}"
PY_ZIP="${PY_ZIP:-$REPO/dist/_cache/python-embed.zip}"
PY_URL="https://www.python.org/ftp/python/3.14.7/python-3.14.7-embed-amd64.zip"
: "${R8_SRC:?请设置 R8_SRC=r8.jar 路径}"
NAME="安卓手表软件编辑器"
OUT_DIR="${OUT_DIR:-$REPO/dist}"
# 先在暂存目录里组装干净的包（不含任何用户数据）再压缩；
# 然后只把程序文件同步到 $LIVE，保留用户的 config/（设置、API Key）、workspace/（项目和对话历史）
# 以及 skills/ 里用户自己加的 skill。
LIVE="$OUT_DIR/$NAME"
APP="$OUT_DIR/_staging/$NAME"
T="$APP/tools"
BT=33.0.2

echo "==> 清理暂存目录 $APP"
rm -rf "$OUT_DIR/_staging"
mkdir -p "$T"

echo "==> 程序本体"
cp -r "$HERE/build/windows/x64/runner/Release/." "$APP/"

echo "==> adb（platform-tools）"
mkdir -p "$T/android-sdk/platform-tools"
for f in adb.exe AdbWinApi.dll AdbWinUsbApi.dll libwinpthread-1.dll source.properties package.xml NOTICE.txt; do
  cp "$ENV_DIR/android-sdk/platform-tools/$f" "$T/android-sdk/platform-tools/"
done

echo "==> build-tools $BT（只保留 aapt2 / zipalign / apksigner / d8 需要的文件）"
S="$ENV_DIR/android-sdk/build-tools/$BT"; D="$T/android-sdk/build-tools/$BT"
mkdir -p "$D"
for f in aapt.exe aapt2.exe zipalign.exe apksigner.bat d8.bat dexdump.exe libwinpthread-1.dll \
         core-lambda-stubs.jar package.xml source.properties runtime.properties NOTICE.txt; do
  [ -e "$S/$f" ] && cp "$S/$f" "$D/"
done
cp -r "$S/lib" "$D/"

echo "==> platforms/android-33（android.jar 等，去掉源码和皮肤）"
S="$ENV_DIR/android-sdk/platforms/android-33"; D="$T/android-sdk/platforms/android-33"
mkdir -p "$D"
for f in android.jar core-for-system-modules.jar framework.aidl build.prop package.xml source.properties sdk.properties uiautomator.jar; do
  [ -e "$S/$f" ] && cp "$S/$f" "$D/"
done
cp -r "$S/optional" "$D/" 2>/dev/null || true
cp -r "$ENV_DIR/android-sdk/licenses" "$T/android-sdk/" 2>/dev/null || true

echo "==> JDK"
cp -r "$ENV_DIR/jdk" "$T/jdk"

echo "==> Python（官方嵌入版，含 zipfile 等标准库）"
if [ ! -f "$PY_ZIP" ]; then
  mkdir -p "$(dirname "$PY_ZIP")"
  curl -fL --retry 3 -o "$PY_ZIP" "$PY_URL"
fi
mkdir -p "$T/python"
powershell -NoProfile -Command "Expand-Archive -LiteralPath '$(cygpath -w "$PY_ZIP")' -DestinationPath '$(cygpath -w "$T/python")' -Force"

echo "==> Git Bash（去掉文档、vim、perl 文档、gui 等用不到的部分）"
mkdir -p "$T/git"
( cd "$GIT_DIR" && tar -cf - \
    --exclude='./unins*' --exclude='./tmp' --exclude='./git-bash.exe' --exclude='./git-cmd.exe' \
    --exclude='./ReleaseNotes.html' \
    --exclude='./mingw64/share/doc' --exclude='./mingw64/share/git-gui' --exclude='./mingw64/share/gitk' \
    --exclude='./mingw64/share/git-doc' --exclude='./mingw64/share/locale' --exclude='./mingw64/libexec/git-core/git-gui*' \
    --exclude='./usr/share/vim' --exclude='./usr/share/doc' --exclude='./usr/share/man' --exclude='./usr/share/info' \
    --exclude='./usr/share/locale' --exclude='./usr/share/perl5/core_perl/pod' \
    --exclude='./usr/bin/vim.exe' --exclude='./usr/bin/vimdiff.exe' --exclude='./usr/bin/view.exe' \
    --exclude='./usr/bin/rview.exe' --exclude='./usr/bin/rvim.exe' --exclude='./usr/bin/ex.exe' \
    . ) | ( cd "$T/git" && tar -xf - )

echo "==> r8.jar（build-tools 自带的 d8 对现代 javac 产物会 NPE）"
cp "$R8_SRC" "$T/r8.jar"

echo "==> skills（软件根目录 skills/，可自行增删）"
mkdir -p "$APP/skills" "$APP/config" "$APP/workspace"
cp -r "$HERE/assets/skills/." "$APP/skills/"

cat > "$APP/使用说明.txt" <<'EOF'
安卓手表软件编辑器 便携版

1. 解压整个文件夹到任意位置（路径里最好不要有空格），双击 android_watch_editor.exe。
   所有东西都在这个文件夹里，不写注册表、不往用户目录放文件；整个文件夹拷走即可迁移。
2. 点右上角齿轮选择模型接口：
   - OpenAI 格式：DeepSeek、OpenAI 以及其它兼容 /chat/completions 的服务
   - Anthropic 格式：Claude（/v1/messages）
   填接口地址、API Key、模型名。模型支持看图时打开“支持图片输入”。
3. 对话权限：“每次询问”会在 AI 写文件、执行命令、安装 APK 前弹窗确认；“完全权限”不再询问。
4. 手表打开 ADB 调试，用 USB 连接电脑。软件每 3 秒自动检测一次，手表上弹出授权时点“允许”。
   如果设备管理器里手表没有驱动，需要先装手表厂商或 Google 的 USB 驱动。

目录说明：
   tools/android-sdk  adb、aapt2、zipalign、apksigner、android-33 平台
   tools/jdk          javac / java / keytool
   tools/python       Python（构建时往 apk 里写 classes.dex）
   tools/git          bash（AI 执行命令用）
   tools/r8.jar       新版 d8
   skills/            skill，每个子文件夹一个（含 SKILL.md），可以自己加
   config/            设置（含 API Key）和手表型号档案
   data/              Flutter 运行库资源（勿动）
   workspace/         默认工作区；新建项目时也可以选择别的文件夹
EOF

echo "==> 压缩"
ZIP="$OUT_DIR/$NAME-便携版-win-x64.zip"
rm -f "$ZIP"
powershell -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$APP")' -DestinationPath '$(cygpath -w "$ZIP")' -CompressionLevel Optimal"
du -sh "$ZIP"

echo "==> 更新 $LIVE（保留 config/ workspace/ 和用户自己的 skill）"
mkdir -p "$LIVE"
for item in "$APP"/* ; do
  b="$(basename "$item")"
  case "$b" in
    config|workspace) mkdir -p "$LIVE/$b" ;;          # 用户数据，不动
    skills) mkdir -p "$LIVE/skills"; cp -r "$item/." "$LIVE/skills/" ;;  # 只覆盖内置 skill
    *) rm -rf "$LIVE/$b"; cp -r "$item" "$LIVE/$b" ;;
  esac
done
rm -rf "$OUT_DIR/_staging"
du -sh "$LIVE"
