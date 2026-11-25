# adb 使用方法（OPPO Watch 2 实测）

所有命令在 Windows MSYS Bash 下验证通过。`ADB` 指 `platform-tools/adb.exe` 的路径，`W` 指工作目录。

## 0. 连接

```bash
$ADB devices -l
# c1ab7fb4  device product:OW20W2 model:OW20W2     ← USB 连接正常
# 10.0.2.15:5555  offline                          ← 上一次的残留，忽略
```

- USB 首次连接要在表上点"允许 USB 调试"。
- 无线：`adb connect <手表IP>:5555`；表换了 Wi-Fi 之后旧会话会变成 `offline`，`adb disconnect` 清一下再连。
- 出现 `offline` 且重连无效时拔插一次 USB；`adb kill-server && adb start-server` 也可。

## 1. 唤醒（本项目最大的坑）

手表息屏后，`input keyevent 224`（WAKEUP）和 `26`（POWER）**都叫不醒**，`dumpsys power | grep mWakefulness=` 一直是 `Asleep`，此时截图恒为 1610 字节纯黑。

可靠配方：

```bash
# 1) 假的"插上充电"会让系统主动亮屏
$ADB shell dumpsys battery set ac 1
sleep 2
# 2) 立刻撤销充电状态，避开充电全屏动画抢焦点
$ADB shell dumpsys battery unplug
sleep 2
# 3) 关掉自动息屏，调试期间别让它再睡
$ADB shell settings put system screen_off_timeout 1800000

# 校验
$ADB shell dumpsys power | grep mWakefulness=       # 期望 Awake
$ADB shell dumpsys window | grep mCurrentFocus      # 期望是自己的 Activity
```

调试结束**必须**还原，否则手表的电量显示会一直是"充电中"：

```bash
$ADB shell dumpsys battery reset
$ADB shell settings put system screen_off_timeout 30000   # 或原值
```

> 顺序很重要：先 `set ac 1` 让它醒，再 `unplug` 把充电屏撤掉。反过来做不会醒。

## 2. 解锁充电全屏 / 抢焦点

如果截图只有充电表盘、`mCurrentFocus=Window{... u0 SysUI.Charging}`：

```bash
$ADB shell dumpsys battery unplug    # 通常是这一条就够了
$ADB shell am start -n com.example.app/.Main
```

`input tap` / `input swipe` 在充电屏上都无效（屏被 UI 全屏接管）。不要试图点它，直接改电池状态。

## 3. 截图

首选（无路径问题、无临时文件）：

```bash
$ADB exec-out screencap -p > shot.png
ls -l shot.png     # 正常 90–110 KB；1610 字节 = 纯黑
```

备选（走 /sdcard，**必须**关掉 MSYS 路径转换）：

```bash
MSYS_NO_PATHCONV=1 $ADB shell screencap -p /sdcard/s.png
MSYS_NO_PATHCONV=1 $ADB pull /sdcard/s.png C:/tmp/s.png
```

判断截图是否有效：`372x430` 且文件 > 20 KB。1610 字节一律按"屏幕没亮"处理，不要去翻 App 代码。

## 4. 模拟触摸

```bash
$ADB shell input tap 186 215            # 中心点
$ADB shell input swipe 186 300 186 80 200   # 竖向滑动（x 不变）
```

- **横向滑动要从中部起手**：`input swipe 60 200 320 200 180` 这种从屏幕边缘起手的横滑会被系统当成返回/主页手势，直接把 App 甩到桌面。两次滑动之间先截一张图确认还在 App 里。
- 手势有延迟，`input` 之后 `sleep 2` 再截图。
- 分页/翻页类的 UI，优先点底部分页圆点，不要依赖系统手势。

## 5. 日志

```bash
$ADB logcat -d -s AndroidRuntime:E *:S 2>&1 | tail -40    # 崩溃栈
$ADB logcat -d -t 200 2>&1 | grep -iE "mypkg|AndroidRuntime" | tail -40
$ADB shell dumpsys window | grep mCurrentFocus            # 当前焦点窗口
$ADB shell pm list packages | grep mypkg                  # 是否装上
```

`dumpsys window` 里 `mCurrentFocus` 是最省时间的诊断：指向自己 → UI 在跑；指向 `SysUI.Charging` → 电池状态问题；指向 launcher → App 被手势甩掉了或启动即崩。

## 6. 安装 / 卸载 / 启动

```bash
$ADB install -r app.apk
$ADB shell am force-stop com.example.app
$ADB shell am start -n com.example.app/.Main
$ADB shell pm clear com.example.app      # 清数据（含缓存）
$ADB uninstall com.example.app
```

`install -r` 覆盖安装会保留数据；调试 UI 时经常需要 `pm clear` 才能看到真正的冷启动路径。

## 7. 关机 / 重启

```bash
$ADB shell reboot -p     # 关机（-p = power off）
$ADB shell reboot        # 重启
```

`reboot -p` 有时要发两次才真正断电（第一次后 `adb devices` 可能仍短暂可见）。之后 `adb devices` 为空即成功。注意：**手表插着充电器会自动开机**，想真正关机必须先拔线。

## 8. 常用系统属性（本项目实测值）

```bash
$ADB shell wm size          # Physical size: 372x430
$ADB shell wm density       # Physical density: 320
$ADB shell getprop ro.build.version.sdk     # 27
$ADB shell getprop ro.build.version.release # 8.1.0
$ADB shell getprop ro.product.model         # OW20W2
```

372×430 @ 320dpi → 可用逻辑画布 **186×215 dp**。布局按 dp 设计，`dp(x) = x * density / 160`，实际就是 ×2。
