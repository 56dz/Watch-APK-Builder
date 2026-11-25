# OPPO Watch 2 原生 APK 开发

给 **OPPO Watch 2（OW20W2）** 写原生 Android App 的可复用经验包。全部数字来自真机实测，
不来自文档推测；换机型时请重新采样，不要照抄。

> 这套东西是从一个真实项目里抽出来的：给这块表做的 CS2 赛事赛程 App，5 个页面 + 3 类详情页、
> 4856 行 Java、apk 74 KB、无 Gradle、无第三方库。下面每一条都在那块表上验证过。

## 四块内容

| 主题 | 文件 | 里面有什么 |
| --- | --- | --- |
| **1. adb 使用方法** | [`references/adb.md`](references/adb.md) | 连接、唤醒息屏表、关掉充电屏、截图（含 1610 字节黑图排查）、点击滑动、日志、安装/卸载、关机 |
| **2. 项目经验** | [`references/project-notes.md`](references/project-notes.md) | 自绘 View 的分层架构、解析函数静态化 + 离线 JSON 自测、三层缓存、分页陷阱、186×215 dp 的排版数学、惯性滚动、防烧屏、性能预算 |
| **3. 注意事项** | [`references/caveats.md`](references/caveats.md) | 构建链每一环的参数与顺序、清单/资源要求、运行时规则、真机行为怪癖 |
| **4. 避坑点** | [`references/pitfalls.md`](references/pitfalls.md) | 20 条 **症状 → 原因 → 解法**，每条都真实踩过 |
| 可编译模板 | [`templates/`](templates/) | 一个 25 KB 的最小工程：`build.sh` + 清单 + 资源 + Activity + 自绘 View 骨架 + 磁盘缓存 |

Agent 接入点见 [`SKILL.md`](SKILL.md)（含 frontmatter，可直接作为 skill 目录使用：放进软件根目录的 skills/ 下即可）。
不想读 Markdown 的话，[`report.html`](report.html) 是同样内容的单页汇报稿（离线可开，无外部依赖）。

## 30 秒上手

```bash
adb devices -l                      # c1ab7fb4  device product:OW20W2
adb shell wm size && adb shell wm density   # 372x430, 320 dpi -> 186x215 dp
cd templates && bash build.sh       # ==> signed OK, app.apk
adb install -r app.apk && adb shell am start -n com.example.watchapp/.Main
adb exec-out screencap -p > shot.png  # 1610 字节 = 黑图，看 references/adb.md 第 1 节
```

## 六条最贵的结论

1. **息屏的表叫不醒**：`input keyevent 224/26` 无效，必须 `dumpsys battery set ac 1` + 任意 input 事件，用完 `dumpsys battery reset`。
2. **d8 会 NPE**：build-tools 33.0.2 自带的 R8 3.3.20 解析不了现代 javac 产物，换 `tools/r8.jar`。
3. **`apksigner.bat` 要 Windows 原生 `JAVA_HOME`**：`cygpath -w` 一下，否则 `/d/...` 报 invalid directory；`build.sh` 存 CRLF 也会炸。
4. **截图 1610 字节就是纯黑**，不是 App 崩了——先确认屏幕亮着，再看 logcat。
5. **惯性滚动的符号错一个就是"弹力回弹"**：`scroll += v` 写成 `scroll -= v`，上滑会突然弹一下；这个 bug 靠看代码发现的，不是靠猜。
6. **分页假设会骗人**：这类赛事 API 的第一页往往不包含"今天"，服务端还常常静默忽略排序/时间参数（返回体字节数一模一样就是证据）。

## 许可

GPL-3.0，见 [`LICENSE`](LICENSE)。
