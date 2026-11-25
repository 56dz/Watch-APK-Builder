---
name: oppo-watch2-apk
description: Build, install and debug native Android APKs for the OPPO Watch 2 (OW20W2, Android 8.1/API 27, 372x430 px) without Gradle, using only aapt2 + javac + d8 + zipalign + apksigner. Use for creating a watch app from scratch, wiring adb to a real watch (wake, screenshot, tap, install, logcat), designing a minimal UI for a tiny round-cornered screen, or diagnosing a build that fails at d8/apksigner and a screenshot that comes back black.
---

# OPPO Watch 2 原生 APK 开发

面向"给 OPPO Watch 2 写一个能真正跑起来的原生 App"这类任务。所有数字（分辨率、density、adb 行为、构建参数）都来自真机实测，可直接使用；换机型时必须重新 `wm size` / `wm density` 采样，不要照抄。

## 适用范围

- 设备：OPPO Watch 2（型号 `OW20W2`），Android 8.1.0 / API 27，屏幕 **372×430 px**，density **320 dpi** → 逻辑 **186×215 dp**，四角圆角、无实体返回键。
- 构建：**不用 Gradle**。手上一份 `android-sdk` + JDK 就够，全流程 5 秒级，产物 50–150 KB。
- 调试：`adb` over USB（或 `adb connect ip:5555`），靠 `exec-out screencap` 看真实画面。
- 不适用：Wear OS 上需要 Google Play services 的能力（本机没有 GMS，`PlayServices` 一律不可用）。

## 核心流程

1. **先采样设备，别抄文档**：`adb shell wm size`、`wm density`、`getprop ro.build.version.sdk`、`getprop ro.product.model`。
2. **搭最小可跑骨架**：一个 `Activity` + 一个自绘 `View`，`build.sh` 五步出 apk，先装上表看一眼，再写业务。UI 在真机上看和脑补差别极大。
3. **先把 adb 调通**（这是本项目耗时最多的一环）：唤醒 → 解锁充电屏 → 截图确认不是 1610 字节黑图 → 再谈功能。见 `references/adb.md`。
4. **写业务**：网络 + 解析 + 缓存分层；手表内存和流量都紧张，一次请求控制在 100 KB 以内。
5. **每次改动都真机验证**：`build.sh && adb install -r && am start`，截图逐页看。没有截图证据的"应该没问题"基本都有问题。
6. **收尾**：`dumpsys battery reset`、恢复 `screen_off_timeout`、`adb shell reboot -p` 关机（如果用户要）。

## 四块必读内容

| 主题 | 文件 |
| --- | --- |
| adb 使用方法（连接 / 唤醒 / 截图 / 输入 / 日志 / 安装 / 关机） | `references/adb.md` |
| 项目经验（分层、缓存、分页、UI 手感、性能预算） | `references/project-notes.md` |
| 注意事项（构建链、清单、资源、真机行为） | `references/caveats.md` |
| 避坑点（每一条都真实踩过，附症状与解法） | `references/pitfalls.md` |

配套可复用文件（`templates/` 是**一个可直接编译的最小工程**，照它的目录结构放文件）：

```
templates/build.sh            五步构建脚本（Windows/MSYS，无 Gradle）
templates/AndroidManifest.xml 最小清单（watch feature、portrait、NoActionBar）
templates/res/                最小资源（strings / colors / 自适应图标）
templates/Main.java           Activity + 防烧屏 + 缓存初始化骨架
templates/WatchView.java      自绘 View 骨架：分页 + 卡片列表 + 惯性滚动 + 点击热区
templates/Cache.java          原始 HTTP 响应的磁盘缓存（离线兜底）
templates/tools/adddex.py     往 apk 里塞 classes.dex（JBR 没有 jar 工具）
```

用法：把这几个文件按 `app/src/<包名>/`、`app/res/`、`app/AndroidManifest.xml` 摆好，
再把 `tools/r8.jar`（或 build-tools 的 d8.jar，见避坑点）与 `adddex.py` 放进 `tools/`，
`bash build.sh` 就能出一个签名好的 `app.apk`。已实测：25 KB、`==> signed OK`。

模板默认包名 `com.example.watchapp`，改名时三处要一起改：`AndroidManifest.xml` 的
`package=` / `android:name=".Main"`、`Main.java` 与 `WatchView.java` 的 `package` 行、
`app/src/com/example/watchapp/` 目录名。

## 硬性结论（照做即可，理由见 references）

- **d8 用 `tools/r8.jar`**，不要用 build-tools 自带那份：33.0.2 里的 R8 3.3.20 对现代 javac 产物会 NPE。
- **`apksigner.bat` 必须带 `JAVA_HOME`**，否则报 `JAVA_HOME is not set`。
- **MSYS Bash 里所有 `/sdcard/...` 路径都要 `MSYS_NO_PATHCONV=1`**，否则被改写成 `C:/Users/...`；截图更推荐 `exec-out screencap -p > file.png`，绕开路径问题。
- **截图 1610 字节 = 纯黑 = 屏幕没亮或充电屏盖着**，不是 App 崩了。先按 `references/adb.md` 的唤醒配方处理，再看 `logcat`。
- **`input keyevent 224/26` 叫不醒息屏的表**；`dumpsys battery set ac 1` + 任意 input 事件才是可靠解，用完必须 `dumpsys battery reset`。
- **横向滑动会撞系统手势**，滑动测试要从屏幕中部起手，且两次之间先截图确认还在 App 里。
- **UI 常量按 dp 写、按 px 验证**：屏只有 186×215 dp，一行放不下两个 11sp 以上中文词，先算宽度再画。

## 验证清单（交付前逐条过）

- [ ] `bash build.sh` 全绿，末尾有 `==> signed OK`
- [ ] `apksigner verify --print-certs cs2watch.apk` 通过
- [ ] `adb install -r` 成功，`am start` 后 `mCurrentFocus` 是自己的 Activity
- [ ] 五个页面各截一张图，中文不换行、不重叠、不被圆角切掉
- [ ] 断网（或飞行模式）冷启动仍能出内容（走缓存），标题有"离线"标记
- [ ] 60 秒无操作自动变暗；触摸后恢复
- [ ] `logcat -d -s AndroidRuntime:E` 无异常
- [ ] 收尾：`dumpsys battery reset`
