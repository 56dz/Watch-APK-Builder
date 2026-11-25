# 避坑点

每条都是真实踩过的，格式统一为 **症状 → 原因 → 解法**。按踩到的频率排序。

---

## 1. 截图 1610 字节，全黑

**症状**：`adb exec-out screencap -p > s.png` 得到 1610 字节的图，打开是纯黑。App 明明在跑。

**原因**：屏幕已经息屏（`dumpsys power | grep mWakefulness=` → `Asleep`）。1610 字节正好是一张全黑 372×430 PNG 的大小。

**解法**：

```bash
$ADB shell dumpsys battery set ac 1 && sleep 2
$ADB shell dumpsys battery unplug  && sleep 2
$ADB shell settings put system screen_off_timeout 1800000
```

`input keyevent 224`（WAKEUP）和 `26`（POWER）在 OPPO Watch 2 的息屏状态下**都不生效**，不要在这上面浪费时间。用完记得 `dumpsys battery reset`。

---

## 2. 截图只有充电表盘

**症状**：截图能看到表盘/动画，但 `dumpsys window | grep mCurrentFocus` → `Window{... u0 SysUI.Charging}`。点、滑、`am start` 全都没用。

**原因**：插着充电器时系统用全屏充电 UI 接管了显示，App 在下面正常跑。

**解法**：`adb shell dumpsys battery unplug`（一条就够），再 `am start` 拉回前台。**不要**去点那个充电界面。

---

## 3. `apksigner` 报 `JAVA_HOME is not set`

**症状**：`apksigner.bat verify xxx.apk` → `ERROR: JAVA_HOME is not set and no 'java' command could be found in your PATH`。而 `javac` 明明跑得好好的。

**原因**：`apksigner.bat` 是个批处理包装，自己去找 `JAVA_HOME`，不认 PATH 里临时加的 java。

**解法**：每次调用都带前缀，并且 `JAVA_HOME` 必须是 **Windows 原生路径**，不能是 MSYS 的 `/d/...`：

```bash
JAVA_HOME="$(cygpath -w "$JDK")" "$BT/apksigner.bat" verify "$APK"
```

只写 `JAVA_HOME=/d/Users/.../jdk` 会得到另一个报错 `JAVA_HOME is set to an invalid directory`——批处理拿不到 MSYS 虚拟盘符。`build.sh` 里签名的两行和 verify 那一行都要带。**另一个同源坑**：`build.sh` 若存成 CRLF 换行，bash 会把 `\r` 当成参数的一部分，`aapt2 link` 会报一串 “unknown option”。

---

## 4. `d8` 直接 NPE

**症状**：`java -cp lib/d8.jar com.android.tools.r8.D8 ...` 抛 `NullPointerException`，堆栈指向匿名内部类 `A$1` 之类。

**原因**：build-tools 33.0.2 自带的 R8 3.3.20 对现代 javac（JDK 17+）产出的 class 文件解析不了。

**解法**：换更新的 `r8.jar`（本项目用 `tools/r8.jar`），`build.sh` 里做优先级判断：

```bash
D8JAR="$BT/lib/d8.jar"
[ -f "$ROOT/tools/r8.jar" ] && D8JAR="$ROOT/tools/r8.jar"
"$JDK/bin/java" -cp "$D8JAR" com.android.tools.r8.D8 --min-api 26 --lib "$PLATFORM" --output "$OUT/dex" $CLASSES
```

---

## 5. 无法用 `jar` 把 classes.dex 塞进 apk

**症状**：想 `jar uf base.apk classes.dex`，发现 `jar` 命令不存在。

**原因**：随 IDE 附带的 JBR（JetBrains Runtime）没有打包 `jar` 工具，只有 `javac`/`keytool` 之类。

**解法**：用 python 的 `zipfile` 重写 apk（见 `templates/tools/adddex.py`）。注意：

- 已存在的 `classes.dex` 要跳过，否则会重复条目。
- 保留原条目的 `compress_type` 和 `external_attr`，否则 `zipalign` / 安装可能出问题。
- 写完再 `zipalign`，然后签名。

---

## 6. `adb shell screencap -p /sdcard/x.png` 报路径不存在

**症状**：命令看起来没问题，但设备上找不到 `/sdcard/x.png`，或者提示 `C:/Users/...`。

**原因**：MSYS Bash 会把 `/sdcard/...` 当成本机路径做转换。

**解法**：加 `MSYS_NO_PATHCONV=1`，或干脆用 `exec-out` 走管道（推荐）：

```bash
$ADB exec-out screencap -p > shot.png
```

---

## 7. 上滑时"弹簧一样往上弹"

**症状**：手指上滑松手，列表先正常惯性滚动，然后突然往反方向弹一下。

**原因**：惯性计算里符号写反：`int next = (int)(sc - st[0]);`，速度方向被取反。

**解法**：改成 `sc + st[0]`。教训：惯性与边界钳制这类"手感代码"必须真机滑动验证，静态读代码很难发现符号问题。写完顺手检查一遍：

```java
v *= Math.pow(0.93, dt / 16.0);
if (Math.abs(v) < 0.6f) v = 0;
scroll = clamp(scroll + v, 0, maxScroll);   // 注意是 +v
```

---

## 8. 底部小圆点点不动

**症状**：点底部分页圆点没反应，反而打开了某张卡片。

**原因**：卡片的热区矩形向上延伸到了内容区之外，`hitMatch` 先命中，分页判定排在后面。

**解法**：**分页圆点的判定必须排在卡片命中之前**：

```java
if (y > contentBottom) { /* 先判圆点 */ }
Models.Match m = hitMatch(x, y);   // 再判卡片
```

同理，任何"永远可见的导航控件"都应该在 `tap()` 里优先于列表项命中。

---

## 9. 横向滑动把 App 甩回桌面

**症状**：想切 tab，`input swipe 60 200 320 200 180`，结果 App 不见了，回到表盘。

**原因**：从屏幕边缘起手的横向滑动被系统识别成返回手势。

**解法**：从屏幕中部起手（`x` 从 100 到 270），并且两次滑动之间截图确认还在 App 里。UI 设计上，重要导航尽量别只依赖横滑——底部圆点也做一份。

---

## 10. 列表滑到底不再加载

**症状**：滑到列表底部，没有新数据，底部"上滑加载更多"的提示也从来不出现。

**原因**：`Page.hasMore` 字段定义了但从来没被赋值（默认 `false`），加载逻辑读它永远是假。

**解法**：在组装列表的收尾处显式赋值：

```java
rp.hasMore = !exhausted && list.size() >= PAGE && list.size() < CAP;
```

并以"拉回空页"作为 `exhausted = true` 的依据。这种"字段有、赋值漏"的 bug 只能靠把整条路径走一遍发现。

---

## 11. 接口分页第一页不含今天

**症状**：拉"未开始比赛"第一页，数据全是 3 天以后的，今天的比赛不在里面。

**原因**：该接口固定按时间倒序（最新 → 最旧），`limit` 小的时候前几页都在未来。

**解法**：按"最多翻 N 页，一旦本页最后一条早于今天的起点就 break"收集；或者把 `limit` 提到能覆盖全量的档位（本项目 `limit=200` → 350 KB / 1.2 s）。**不要**假设 page 1 = 今天。

另外要用字节数判断"参数是否被服务端忽略"：换参数后返回体大小一模一样 = 被忽略，别再试。

---

## 12. 未开赛比赛的详情接口返回空壳

**症状**：`.../matches/{id}/data` 对未开赛比赛只返回 8 KB，`bouts_state` 是空数组，地图全没有。

**原因**：比赛还没打，逐图数据不存在。

**解法**：改调赛前分析接口（本项目是 `.../analysis_v1`，未开赛也返回完整数据：双方选手、地图胜率、交手记录、近期战绩）。代码里做降级：

```java
if (d == null || d.match == null || d.match.maps.isEmpty() || "upcoming".equals(d.match.status)) {
    d.pre = Api.analysis(m.id);   // 赛前对比
}
```

---

## 13. 逐图数据的空串把界面搞崩

**症状**：`NumberFormatException` 或界面显示 `0.0`。

**原因**：接口里 `kdratio` / `impact` 这类字段可以是空串 `""`，还有一些百分比是 `"-1%"` 这种无意义值。

**解法**：所有数值解析都走容错的 `intOr(str, def)` / `pct(str)`，空串返回默认值；显示层对 `<= 0` 的百分比一律显示 `--`。

---

## 14. 冷启动白屏，弱网直接整屏报错

**症状**：网络慢或刚开机时，App 打开就是"无法连接"，明明昨天还能看。

**原因**：没有任何持久化，每次启动都必须联网成功才能画。

**解法**：加磁盘缓存层（`templates/Cache.java`），顺序 `内存 → 磁盘 → 网络`，失败时用上次的好数据并标"离线"。这个改动对体验的提升远大于任何 UI 打磨。

---

## 15. 中文在 186dp 宽度里换行、重叠

**症状**：队名太长把比分挤掉，或者两段文字叠在一起。

**原因**：按 px 硬编码坐标，换一个更长的队名就崩。

**解法**：全部走 `Ui.fit(paint, text, maxWidth)`，按列分配固定宽度：

```
左标签 58dp | 中间值 剩余 | 右侧数字 40dp
```

中文 9.5sp ≈ 9.5dp/字，一行 170dp 可用宽度 ≈ 17 个汉字。**先算再画**，不要"画出来看看"。

---

## 16. 装上了但点图标没反应 / 启动即崩

**排查顺序**（省时间）：

```bash
$ADB shell pm list packages | grep mypkg          # 装上了吗
$ADB shell am start -n mypkg/.Main                # 能起来吗
$ADB logcat -d -s AndroidRuntime:E *:S | tail -40 # 崩在哪一行
$ADB shell dumpsys window | grep mCurrentFocus     # 当前焦点是谁
```

`mCurrentFocus` 指向 `SysUI.Charging` → 电池/充电屏问题（见 #2），不是代码问题。指向 launcher → 被手势甩掉或 `onCreate` 里崩了。

---

## 17. `reboot -p` 发了手表没关机

**症状**：`adb shell reboot -p` 之后 `adb devices` 还能看到设备。

**解法**：再发一次。两次之间 `sleep 3`。另外确认没插充电器——**插着线关机会自动开机**。

---

## 18. 并行改代码把自己的改动冲掉

**症状**：`build.sh` 报某个方法不存在，或者刚写的代码不见了。

**原因**：多 agent / 多工具并行写同一批文件，后写的覆盖先写的。

**解法**：同一时刻只让一个 agent 写源码；另一方只读、只出结论。分文件分工（例如 A 改 `Models.java`，B 改 `WatchView.java`）比"两个人改同一个文件"安全得多。合并后**必须**重新 `bash build.sh` 确认能编过，再谈功能。
