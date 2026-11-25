# 项目经验

来自一个真实项目：给 OPPO Watch 2 做的 CS2 赛事赛程 App（5 个页面 + 3 类详情页，4856 行 Java，apk 74 KB）。下面是可以直接复用的工程结论。

## 1. 架构：自绘 View 胜过一切框架

手表 App 最稳的形态是 **一个 Activity + 一个自绘 View**：

```
Main (Activity)          窗口、亮度、生命周期、防烧屏
 └─ WatchView (View)     全部绘制与触摸：分页、卡片、滚动、点击热区
     Store               全局状态（当前页、详情栈、筛选条件）
     DataLoader          异步加载 + 缓存 + 分页 + 轮询
     Fiveplay / Api      网络与解析（纯静态函数，可离线单测）
     Models              纯数据类，无 Android 依赖
     Cache               原始响应落盘
     Ui                  dp/sp/颜色/绘制小工具
```

理由：

- 手表上没有 RecyclerView 的用武之地——一屏只放 3 张卡，回收机制反而是负担。
- Canvas 全自绘对圆角屏、字号、间距的控制是像素级的，`TextView` 一堆 `setPadding` 反而调不准。
- 触摸自己做（`onTouchEvent` + 矩形命中），可以精确实现"横滑翻页 + 竖滑列表 + 点击"三套手势不打架。

`templates/WatchView.java` 就是这个形态的骨架。

## 2. 数据层：解析函数必须是纯静态、可离线测试

关键决定：**所有 JSON → Model 的解析抽成 `static` 方法，不碰网络**。

```java
static List<Match> parseList(JSONObject d, boolean liveList)
static MatchDetail parseDetail(JSONObject d)
static Analysis parseAnalysis(JSONObject d)
```

好处是可以在主机上用真实抓下来的 JSON 跑几秒一轮的回归：

```bash
curl -s '<api>' > /tmp/sample.json
javac -cp json.jar -d out Models.java Api.java
java  -cp "out;json.jar" com.example.ParseTest    # 打印 ALL OK
```

本项目靠这个手段在**手表完全没连**的情况下把 5 个页面和 3 类详情页的解析全部验证过，等真机连上时只剩样式问题。这比"改完代码等表来了再试"快一个数量级。

配套：`org.json` 的 jar 要从本机某处捞（`android.jar` 里只有 stub），丢进 `tmptest/json.jar` 即可，不要引 Gradle 依赖。

## 3. 缓存：三层，TTL 各不相同

| 层 | 生命周期 | 用途 |
| --- | --- | --- |
| 内存 `HashMap` | 进程内，限 12–16 条 | 详情页来回点不重复请求 |
| 页面数据 + TTL | 90s（比赛）/ 20min（赛事）/ 30min（排名） | 切页不重复拉 |
| 磁盘原始响应 | 3 MB 上限，按最旧淘汰 | 冷启动无网也能出内容 |

磁盘层（`templates/Cache.java`）的要点：

- 存在 `getCacheDir()`，**不需要任何权限**。
- key 用 SHA-1 哈希成文件名，避免 URL 里的 `/ ? &` 出问题。
- 请求成功就写；请求失败先回落到磁盘，再标"离线"。
- 每 25 次写入异步剪枝，别在 UI 线程算目录大小。
- 首屏无网时的顺序：`内存 → 磁盘 → 网络`，任何一步拿到数据就先画。

有了这层，"网络一抖就整屏报错"的问题直接消失，冷启动体验也完全不同。

## 4. 分页：接口的排序方向可能是反的

踩过的真实情况：某接口"未开始比赛"按时间**倒序**返回（最新 → 最旧），而列表第一页根本不包含今天。于是：

- 不能假设"page 1 = 今天"。
- 需要"最多翻 N 页，一旦发现整页都早于今天起点就 break"的循环收集。
- 每页 `limit` 要试出体积拐点：本项目 `limit=200` → 350 KB / 1.2 s，`limit=500` → 1 MB / 17.7 s。手表只能取前者。

经验：**先量体积和耗时，再定 limit**。同一接口 `limit=50` 可能 65 KB，`limit=200` 可能 350 KB，不是线性的。

列表页 `hasMore` 一定要显式赋值。本项目曾经 `hasMore` 从头到尾没被写过，滑到底永远不加载下一页、底部"上滑加载更多"提示永不出现——一个漏赋值，用户看到的是"功能缺失"。

## 5. UI：先算宽度，再画字

186×215 dp 的屏幕上，一行的宽度预算是固定的：

```
lx = 8dp, rx = 178dp → 可用 170dp
中文 9.5sp ≈ 9.5dp/字 → 一行最多 17 个汉字
"队伍名 · 赛事名" 两个字段并排时，各留 80dp 才不打架
```

规则：

- 所有文字都过一遍 `Ui.fit(paint, text, maxWidth)`（超出就 `ellipsize` 或缩字号），**永远不要**假设某个名字放得下。
- 字号只有三档有意义：11–13sp（标题/队名）、9–10sp（正文）、8sp（标签/时间）。再小就看不清，再大就溢出。
- 左侧 2.6dp 竖色条 + 圆角卡片 是手表上最省地方的状态表达：橙=未开始、红=直播、灰=已结束。
- 底部用 5 个小圆点做分页指示，比 tab 文字省一半高度。
- 深色背景（`0xFF0B0E13 → 0xFF05070A` 渐变）+ 卡片 `0xFF13171F` + 一个高饱和强调色（橙 `0xFFFF7A1A`），在 AMOLED 上省电且好看。

## 6. 滚动手感：惯性要自己写，而且要防回弹

`ScrollView` 在手表上没有合适的替换，本项目自写：

```java
// 抬手时取速度，然后每帧衰减
v = v * Math.pow(0.93, dt / 16.0);
if (Math.abs(v) < 0.6f) v = 0;
scroll += v;
scroll = clamp(scroll, 0, maxScroll);     // 到边界立刻停，不做 overscroll
```

**踩过的 bug**：符号写反成 `next = (int)(sc - st[0])`，表现为"上滑时突然有个弹力往上弹"。惯性系统里符号错一位，用户看到的就是一个非常具体的怪现象——所以这类 bug 一定要真机滑动验证，模拟器（如果装得到）也未必复现。

另外：松手瞬间速度采样窗口要 `<= 100ms`，太久会把之前的慢速也算进去，滑动会"粘"。

## 7. 防烧屏：手表 App 的社会责任

手表长期显示静态亮界面 → AMOLED 烧屏。低成本方案（`templates/Main.java`）：

```java
// 60 秒无触摸
lp.screenBrightness = 0.004f;                       // 近乎全黑
getWindow().clearFlags(FLAG_KEEP_SCREEN_ON);
DataLoader.setDim(true);                            // 顺带停掉后台轮询
// 任意触摸：还原 0.85f 并立即刷新一次
```

注意 `screenBrightness` 的窗口属性在部分 ROM 上要配合 `KEEP_SCREEN_ON` 一起用才生效。轮询暂停也是必要的——表在桌上黑着屏，没必要每分钟耗电联网。

## 8. 逆向第三方 API：先看前端 chunk，再试参数

需要某网站数据时，顺序应该是：

1. 抓它的 JS chunk，`grep` `url:"` / `apiUrl` / `concat(`，能拿到**全部**路径和参数名。
2. 用 `curl` 直接打，`python -c "import json,sys;..."` 格式化看结构，别 `cat` 一坨。
3. 参数名试错优先于猜路径：`tt_ids` vs `tt_id` vs `tournament_id` 只差一个字母，报错信息会告诉你（"赛事id不能为空"）。
4. 记录"死路"：哪些参数被服务端静默忽略（返回体字节数完全相同即为忽略），避免反复试。
5. 把结论写成 `docs/*.md` + 可复现的 curl，比记在脑子里强。

这些结论值得单独开一个仓库（本项目的 5eplay 逆向就独立成了 `56dz/5eplay-api`），App 仓库只留"怎么用"。

## 9. 性能预算（真机实测）

| 项 | 数值 |
| --- | --- |
| apk 体积 | 50–80 KB（纯 Java + 无三方库） |
| 冷启动到首屏 | 1–3 s（有缓存 < 1 s） |
| 单次列表请求 | 40–130 KB，控制在 200 KB 内 |
| 详情请求 | 60–130 KB；超过 300 KB 的接口（如逐回合事件流 800 KB）直接不做 |
| 全量重编译 | `bash build.sh` 约 5–8 s |

超过这些数就要重新设计，手表上没有"用户等一会儿"这回事。
