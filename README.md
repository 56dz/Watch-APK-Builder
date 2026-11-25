# Watch APK Builder（安卓手表软件编辑器）

用 AI Agent 生成安卓手表 App 的 Windows 桌面工具，Flutter 编写。

- 连接手表并记录型号；首次连接某型号时用 adb 采集屏幕形状（方屏 / 圆屏）和分辨率
- 对话式输入需求，Agent 自动写代码、构建 APK（aapt2 + javac + d8 + apksigner，无需 Gradle）、安装到手表并截图验证
- 支持 skill 调用、上传与“总结经验”沉淀为新 skill
- 支持多轮 Bug 排查与功能添加
- 模型接口：DeepSeek / OpenAI 兼容格式 / Anthropic 格式，可设超时与重试
- 免费联网搜索与网页读取（移植自 dsh-free-search）

## 目录

| 目录 | 内容 |
| --- | --- |
| `editor/` | 编辑器源码（`lib/`、`test/`、系统提示词与内置 skill 在 `assets/`） |
| `editor/scripts/package_portable.sh` | 打包便携版（更新时保留已有的 `config/`、`workspace/`） |
| `editor/build/pack.sh` | 构建 + 打包一条龙 |
| `cs2watch_round/` | 示例：圆屏版 CS2 赛事数据手表 App 及踩坑记录 `LESSONS.md` |

## 开发

```bash
cd editor
flutter pub get
flutter test
flutter build windows --release
```
