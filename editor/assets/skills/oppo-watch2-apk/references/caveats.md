# 注意事项

按"构建 → 清单/资源 → 运行时 → 真机行为"的顺序列出。每一条都在本项目里被验证过，不是通用提醒。

## 构建链

**工具链组合（无 Gradle，全部本地）**

```
aapt2 compile  --dir app/res -o build/res/app.zip --no-crunch
aapt2 link     -o build/base.apk -I android.jar --manifest AndroidManifest.xml
               --java build/gen --min-sdk-version 26 --target-sdk-version 27
               --version-code 1 --version-name 1.0 build/res/app.zip
javac          -source 8 -target 8 -encoding UTF-8 -classpath android.jar -d build/classes ...
d8             --min-api 26 --lib android.jar --output build/dex <all .class>
(adddex.py)    把 classes.dex 塞进 base.apk
zipalign       -f -p 4
apksigner      sign --ks debug.keystore
```

- `--java build/gen` 必须给：aapt2 会生成 `R.java`，源码里 `R.string.app_name` 靠它编译。
- 平台用 `platforms/android-33/android.jar` 即可（`compileSdkVersion` 高一点无所谓），真正生效的是 `--min-sdk-version 26` 和 `--target-sdk-version 27`。**targetSdk 定 27** 是为了绕开 Android 8.0+ 的动态权限和行为变更，手表 ROM 也按 27 适配。
- `javac -source 8 -target 8`：手表 runtime 是 ART 8.1，不要用 11+ 语法（`var`、`List.of` 等都不行）。
- `d8 --min-api 26` 要和 manifest 的 minSdk 一致，否则生成的 dex 可能带手表不支持的指令。
- `zipalign -p 4` 的 `-p` 让 `.so` 按页对齐，没有 so 也无害；顺序必须在签名**之前**。
- `apksigner.bat` 是 Windows 批处理，必须 `JAVA_HOME=<jdk>` 前缀调用，否则直接 `JAVA_HOME is not set`。
- 重编前 `rm -rf build`。增量编译会因为 `R.java` 残留出怪问题。

**`org.json` 从哪来**：`android.jar` 里只有 stub（调用即抛 `RuntimeException("Stub!")`）。主机侧单测要找一个真 `json.jar`（Android SDK 里没有，从本地 m2/PyCharm 缓存里捞一个），编译产物时**不要**把它打进 apk——手表上自带 `org.json`。

## 清单与资源

```xml
<uses-sdk android:minSdkVersion="26" android:targetSdkVersion="27" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-feature android:name="android.hardware.type.watch" android:required="false" />
<application android:theme="@android:style/Theme.Material.NoActionBar" ...>
  <activity android:name=".Main" android:exported="true"
            android:launchMode="singleTop"
            android:screenOrientation="portrait"
            android:configChanges="orientation|screenSize|keyboardHidden" />
```

- `android.hardware.type.watch` 一定要 `required="false"`，否则某些安装路径会拒绝。
- `screenOrientation="portrait"` 固定竖屏；手表旋转后会直接崩。
- `configChanges` 三个都要写，否则某些系统更新会重建 Activity 丢状态。
- 主题用 `@android:style/Theme.Material.NoActionBar`，别引 AppCompat（要额外依赖，apk 会翻倍）。
- 图标：`mipmap-anydpi-v26/ic_launcher.xml` + 两个 drawable（前景/背景），矢量足够，不要放 png。
- `android:allowBackup="false"`：手表上备份没意义，还会在 `pm clear` 时产生意外行为。

## 运行时

- **不要用任何第三方库**。apk 70 KB 的预算里塞不进 Gson/OkHttp；`org.json` + `HttpURLConnection` + 手写 `GZIPInputStream` 足够。
- **网络请求必须离开主线程**。用一个 2–4 线程的 `ExecutorService`，结果 `Handler.post` 回主线程。
- **UI 线程只做绘制**。解析几十 KB JSON 放后台，否则手表会明显卡顿。
- `onBackPressed` 要自己处理：手表没有实体返回键，只有滑动返回。自绘 UI 时 `handleBack()` 要判"当前在详情页 → 回列表"，"在列表 → 交给系统"。
- 全屏：`FLAG_FULLSCREEN` + `setBackgroundDrawable(ColorDrawable(0xFF05070A))`。不设背景的话，Activity 切换时会闪白。
- 亮度控制用窗口属性 `lp.screenBrightness`，不是 `Settings.System`（后者要权限且手表上多半无效）。
- 电量：`FLAG_KEEP_SCREEN_ON` 在息屏保护时要主动清掉，否则黑屏但屏幕仍"亮"着耗电。
- `Cache.init(getCacheDir())` 要放在 `setContentView` 之后、首次网络请求之前。
- 进程被杀后 `Store` 单例就没了，所有状态都在内存里——这是有意的，手表上没必要持久化业务状态（缓存层负责"有内容可看"）。

## 真机行为

- **屏幕会很快息屏**（默认 15–30 s），调试期间必须 `settings put system screen_off_timeout 1800000`。
- **充电时会弹出全屏充电动画**，抢占焦点，App 在下面正常跑但截图全是它。`dumpsys battery unplug` 解决。
- **插着充电器关机后会自动开机**。要真正断电必须先拔线。
- **横向滑动容易触发系统手势**，把 App 甩回桌面。测试时从屏幕中部起手、每次滑动后截图确认。
- **AMOLED 会烧屏**。静态亮界面长时间显示必烧，所以 60 s 变暗不是可选项。
- 手表 CPU 较慢，冷启动 1–3 s 是正常值；首次 `screencap` 也可能要 1–2 s。
- **`input` 事件有延迟**：`input tap` 之后至少 `sleep 1.5`，`am start` 之后 `sleep 5–8` 再截图。
