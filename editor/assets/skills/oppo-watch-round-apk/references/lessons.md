# LESSONS：方屏 CS2 手表 App → 圆屏 OPPO OWW251

标记：**已验证** = 本次在 OWW251 真机上实测过；**推测** = 依据文档或推理，未单独验证。

## 1. 设备与差异总览

| 项 | 方屏 OPPO Watch 2 (OW20W2) | 圆屏 OPPO OWW251 |
| --- | --- | --- |
| 系统 | Android 8.1 / API 27 | Android 11 / API 30（已验证，getprop） |
| 分辨率 / 密度 | 372×430，圆角矩形 | 466×466，density 320 → 233×233 dp，`dumpsys display` 有 FLAG_ROUND（已验证） |
| 特性 | android.hardware.type.watch | 另有 oplus.wear.screen.round、oplus.wear.screen.round.big（已验证） |
| ABI | — | armeabi-v7a（已验证）；本 App 纯 Java，无影响 |
| 息屏截图 | 1610 B 纯黑 PNG | 1866 B 纯黑 PNG（已验证） |
| 亮屏截图 | — | 表盘 190–280 KB；App 页面 24–42 KB（已验证） |
| 桌面焦点 | — | com.heytap.wearable.launcher/.Launcher（已验证） |
| 安装输出 | Success | 先打印 "Performing Incremental Install"/"Streamed Install" 再 Success（已验证） |

## 2. adb 行为（OWW251）

- **唤醒**（已验证）：`input keyevent 224`（WAKEUP）和 `26`（POWER）都不能唤醒，`dumpsys power` 仍是 mWakefulness=Asleep，截图仍是 1866 B 黑图。与方屏相同，可靠配方仍是
  `dumpsys battery set ac 1` → 亮屏（Awake）→ `dumpsys battery unplug` 仍保持 Awake → `settings put system screen_off_timeout 1800000`。结束必须 `dumpsys battery reset`。
- **判断黑屏**（已验证）：截图字节数 < 3 KB 就是息屏，不用看图。阈值和方屏不同（1866 vs 1610），别硬编码 1610。
- **截图**（已验证）：`adb exec-out screencap -p > x.png` 在 Windows MSYS 下得到正常 PNG，无 CRLF 损坏。
- **手势**（已验证）：
  - 从屏幕中心起手的左右滑动（300,233→150,233）在 App 内切页。
  - 从左边缘 x=3 起手向右滑，本机**没有**触发系统返回，App 照常收到事件切页（方屏 skill 说边缘滑会触发系统返回；本机未复现，但仍建议从中心起手）。
  - `input keyevent 4`（BACK）在详情页返回列表。
  - 一次 `am start` 对已运行的实例只会投递 intent（"Activity not started, intent has been delivered..."），不会重建。
- **防烧屏与测试**（已验证）：60 秒无操作后屏幕被压暗，此时第一下点击只用于恢复亮度，不触发按钮。自动化脚本隔久了点圆点“没反应”就是这个原因，先点一下中心再操作。
- **adb 版本**：只用软件自带的 adb（环境变量 ADB），命令加 `timeout 20`，不要 kill-server：电脑上另一份版本不同的 adb 会和它互相踢掉 server。

## 3. Android 11 vs 8.1

- **明文 HTTP**（已验证）：所有接口都是 https（esports-data.5eplaycdn.com、app.5eplay.com、oss.5eplay.com），targetSdk 30 下无需 network_security_config。若将来加 http 源，API 28+ 默认禁止明文（推测，未实测）。
- **包可见性**（已验证不涉及）：代码里没有 PackageManager 查询其它包，Android 11 的 `<queries>` 限制不影响本 App。
- **targetSdk 30**（已验证）：改 30 后安装、联网、缓存目录读写正常；minSdk 保持 26。
- **网络**（已验证）：接手时手表 Wi-Fi 关闭（wifi_on=0），App 显示「无法连接」+ `Unable to resolve host "esports-data.5eplaycdn.com"`（shots/base_today.png）。`svc wifi enable` 只开开关、不会自动连上；由用户在手表上连接 Wi-Fi「Guest」后恢复。这是环境问题，不是代码问题。中途网络掉过一次，今日页标题下出现橙色「离线」并显示缓存数据，离线兜底在圆屏版正常（已验证）。

## 4. 构建参数变化（已验证）

- 包名 com.example.cs2watch → com.example.cs2watch.round：清单 package、所有 java 的 package 行、源码目录 app/src/com/example/cs2watch/round/ 三处一起改（圆屏版与方屏版包名不同，可同时装在两块表上互不覆盖）。
- 应用名 strings.xml app_name = CS2赛事圆屏。
- build.sh：aapt2 link `--min-sdk-version 26 --target-sdk-version 30`，输出 cs2watch_round.apk。
- 工程复制到别处后 build.sh 的默认 `$ROOT/../env` 不存在，必须用环境变量指定工具：编辑器的 run_command 已经设好 SDK / JDK / PYTHON / R8_JAR（指向软件根目录 tools/），build.sh 优先读这些变量，不要写死本机路径。
- 复制来的 WatchView.java、Store.java 是 CRLF，统一转成 LF，避免 edit 时行尾混杂（javac 本身不在乎）。
- 结果：`==> signed OK`，apk 约 74 KB，`adb install -r` Success。

## 5. 圆屏控件布局（给编辑器的规则）

坐标约定：cx = w/2，cy = h/2，R = min(w,h)/2；所有长度用 dp 换算，不写像素常量。Canvas 角度：0° = 右，90° = 下，顺时针为正。

### 5.1 安全圆与检查
- 安全半径 lim = R − safe，safe = 6dp。任何控件的**四个角**都必须满足 hypot(x−cx, y−cy) ≤ lim。
- 每个边缘控件绘制前调用调试检查，越界打 Log.w("CS2Round", "outside dial: …")，真机跑一遍后看 logcat：
```java
boolean fitsInCircle(RectF r, String what) {
    float lim = R - safe + 0.5f;
    boolean ok = dist(r.left, r.top) <= lim && dist(r.right, r.top) <= lim
              && dist(r.left, r.bottom) <= lim && dist(r.right, r.bottom) <= lim;
    if (!ok && warned.add(what)) Log.w(TAG, "outside dial: " + what + " " + r.toShortString());
    return ok;
}
// 圆形按钮：dist(center) + radius <= R - safe
```
- 截图自检：tools/rimcheck.py 统计半径 > R−12px 处亮度 > 60 的像素，必须为 0（本次所有截图都是 0，已验证）。

### 5.2 列表卡片（弦宽内缩）
```java
// yA..yB 是卡片当前可见的上下沿；取离圆心更远的那条边算弦
float chordInset(float yA, float yB) {
    float dy = Math.max(Math.abs(yA - cy), Math.abs(yB - cy));
    float lim = R - safe;
    if (dy >= lim) return w / 2f;            // 整行在圆外：不画
    return Math.max(padX, cx - (float) Math.sqrt(lim * lim - dy * dy));
}
```
- 左右内边距 = chordInset(可见上沿, 可见下沿)，padX = 8dp；内缩后宽度 < 60dp 的行直接跳过。所有文字按剩余宽度 Ui.fit() 截断加 "…"。
- 效果：越靠近上下的卡片越窄，中间最宽（p1_today.png、p4_events.png、p5_rank.png）。

### 5.3 列表上下留白
- contentTop = cy − R + 54dp（标题区），contentBottom = cy + R − 34dp（分页点区）。
- minScroll = −(cy − itemH/2 − contentTop)（负值，允许把首项拉到中间）；maxScroll 额外加 contentBottom − (cy + itemH/2)，末项能停到中间。itemH：比赛卡 60dp、赛事 46dp、排名 30dp。已验证：t_today_top.png、t_today_end.png。
- 上下沿渐隐保留原逻辑。

### 5.4 标题与返回
- 页标题居中，基线 y = cy − R + 30dp；「离线」标记居中放在标题下 11dp。
- 详情页不用左上角箭头（在圆外），改为顶部居中的「‹ 返回 · 比赛/队伍/选手/赛事」，基线 cy − R + 28dp；x0 = min(居中位置, 刷新按钮左沿 − 10dp − 文字总宽)，避免压到刷新按钮（第一版就压到了）。点击区 rBack 是这段文字的外接矩形，同样过 fitsInCircle。

### 5.5 刷新按钮（圆形，放在边缘环上）
- 圆心在半径 ring = R − safe − 12dp、角度 −60°（右上）：x = cx + ring·cos, y = cy + ring·sin；半径 11dp。
- 命中：dist(点, 圆心) ≤ 11dp + 6dp。

### 5.6 筛选胶囊 → 弧形环段
- 环带：arcOut = R − safe，arcIn = arcOut − 15dp，arcMid = (arcIn+arcOut)/2，用 round-cap stroke（宽 = arcOut − arcIn）沿 arcMid 画弧。
- 上端固定在 ARC_END = 254°（左上偏顶），长度按文字宽度：sweep = deg((textW + 6dp) / arcMid)，cap = deg((band/2)/arcMid)，a0 = ARC_END − cap − sweep。
- 文字：drawTextOnPath(label, arcPath, (len − textW)/2, 0.35·textSize)。顶部弧路径是顺时针的，正 vOffset 把基线推向圆心，0.35×字号让字在环带里垂直居中。
- 检查下端 y = cy + arcIn·sin(a0 − cap) 不能低于 contentTop，否则卡片会滑到胶囊下面（Log "pill reaches list"）。
- 命中（极坐标）：
```java
boolean hitPill(float x, float y) {
    float d = dist(x, y);
    if (d < arcIn - dp(6) || d > R + 1) return false;
    float cap = deg(((arcOut - arcIn) / 2f) / arcMid) + 3f;
    return angFrom(angleOf(x, y), arcA0 - cap) <= arcSweep + cap * 2;   // angFrom 处理 0/360 回绕
}
```
- 点击坐标约 (142,50)。已验证：t_today_pill.png（全部→A级以上）、t_events_pill.png、t_rank_pill.png（HLTV→VRS）。

### 5.7 分页小点 → 底部弧
- 半径 dotR = R − safe − 10dp，角度 dotAngle(i) = 90° + ((N−1)/2 − i)·7°（i=0 在左，角度越大越靠左）。
- 466px 屏上 5 个点坐标：(184,428) (209,433) (233,434) (257,433) (282,428)。
- 命中：d ∈ [dotR − 16dp, R+1] 且角度落在 dotAngle(i) ± 3.5° 内。

### 5.8 详情页（固定列）
- 列半宽 colHalf = min(77dp, lim − 8dp)，dyMax = √(lim² − colHalf²)，列 = [cx ± colHalf] × [max(cy − dyMax, 刷新按钮下沿 + 2dp), cy + dyMax]，四角在圆内。466px 上列宽 ≈ 154dp。
- 列比方屏窄，原来按固定偏移排的多列行会撞车，必须**按测量宽度**分配（见坑 3）。

### 5.9 点击顺序
- ACTION_DOWN 和 tap() 都先测边缘控件（刷新 → 胶囊 → 圆点 → 返回），命中后不再给列表卡片按下态，再测列表。和方屏一样，圆点/胶囊必须先于卡片。

## 6. 踩过的坑（症状 → 原因 → 解法）

1. 返回文字压住刷新按钮（已验证）→ 顶部居中的「‹ 返回 · 队伍」宽度超过刷新按钮左侧空间 → x0 取 min(居中, 刷新左沿 − 10dp − 总宽)。
2. 比赛详情 FaZe 队名碰到赛事行（已验证）→ 列顶下移后队伍行间距 54dp 不够 → 改 60dp。
3. 队伍页地图池 "CT 58.3% · T 49.3%" 和右侧胜率重叠（已验证，旧图里 "49.361.1%"）→ 原代码名称 66dp、分边文字固定在 lx+72dp 宽 80dp，按方屏列宽设计，圆屏列只有 154dp → 名称 50dp；分边起点 lx+52dp，宽度 = rx − 胜率实测宽 − 5dp − 起点；格式压缩成 "CT58.3% T49.3%"。修后 p7_team_scroll.png。
4. 点圆点没切页（已验证）→ 60 秒无操作进入防烧屏压暗，第一下点击只唤亮 → 不是 bug；测试脚本先点一下或连续操作。
5. 截图全黑 1866 B（已验证）→ 手表息屏，keyevent 唤不醒 → battery set ac 1 配方。
6. 页面显示「无法连接」（已验证）→ 手表 Wi-Fi 关闭 → 手表上连接 Wi-Fi；`svc wifi enable` 不够。
7. 构建找不到 SDK（推测会发生，已提前规避）→ 复制工程后 ../env 不存在 → 显式 export SDK/JDK/PYTHON。

## 7. 本次没做 / 未验证

- 圆形表冠旋转（RotaryInput / MotionEvent.AXIS_SCROLL）未接入（推测这台表有旋钮事件，未测）。
- 更小的圆屏（如 390px）上没跑过；布局都按 R 和 dp 推导，理论可用（推测）。
