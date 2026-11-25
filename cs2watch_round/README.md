# CS2 手表赛程（圆屏版）

OPPO OWW251 圆屏手表（466×466 px，Android 11 / API 30）的 CS2 赛事应用，移植自 OPPO Watch 2（372×430，Android 8.1）方屏版，纯 Canvas 手绘 UI，无第三方依赖。

## 五个页面

| 页 | 内容 |
| --- | --- |
| 今日 | 当天**未开赛 + 正在直播**的比赛，卡片直接显示**每图小比分**（`Anubis 11:13 · Inferno 13:11`）；已结束的只进「赛果」 |
| 直播 | 正在进行的比赛，5 分钟自动轮询刷新 |
| 赛果 | 已结束比赛，滑到底自动加载下一页 |
| 赛事 | 赛事列表，左上弧形胶囊按钮循环切换 **全部 / A级以上 / 仅S级** |
| 排名 | **HLTV 世界排名 / Valve VRS / 选手 Rating / 选手奖金** 四榜，滑到底自动翻页 |

今日页与赛果页都有等级筛选胶囊：`全部 → A级以上 → 仅S级` 循环，切换后回到顶部。

## 比赛详情

点比赛卡片 → 大比分、赛事 / 阶段、开赛时间、**完整 ban/pick 序列**（禁/选 + 哪队操作，被禁地图画删除线）、**逐图比分含半场**（`6:6 / 5:7`）、两队整场选手数据（K-D / ADR / Rating，Rating ≥1.15 绿色、<0.85 红色）、全场 MVP。

**点某一行地图**可以展开该图的选手数据表（两队各 5 人的逐图 K-D / ADR / Rating），再点一次收起。

**未开赛**的比赛改走赛前对比接口：双方胜率 / KD / Rating / 首杀率 / 交手胜率、7 张地图胜率、双方选手近期状态、历史交手（最多 5 场）、两队近期战绩。

队伍名与赛事名都可点进对应详情页。

## 队伍页

点队伍名 → HLTV / VRS 排名、积分、国家 / 地区 / 平均年龄、教练；战绩（胜 / 负 / 平、胜率、KD、地图数）；**地图池**（每图胜率 + CT / T 分边胜率）；现役选手（含位置，可点进选手页）；近期比赛（可点进比赛详情）；荣誉（最多 8 条）。

## 选手页

点选手名 → 队伍（可跳回队伍页）、位置 / 国籍 / 生日 / TOP20；Rating / KD / ADR / KAST / Impact / DPR / KPR / 爆头率 / 地图数 / 回合数 / 击杀死亡 / 奖金；逐图表现；武器偏好；残局次数（1V1…1V5）与多杀回合分布；生涯荣誉（冠军橙色）；**近期比赛**（可点进比赛详情）。

## 赛事详情

等级、名称、时间、奖金、地点、队伍数、赛制、冠军 / 亚军、奖金分配、参赛队伍（可点）、**赛段**、**队伍数据**（场次 / 胜率 / KD / 地图数）、**地图数据**（出场 / 胜率 / CT / T）、**赛程**（按日期分组，最多 40 场，可直接点进比赛详情）。

## 交互

- 上下滑动：惯性滚动，到边界即停（无回弹）
- 点底部弧上的小点 / 左右滑动：切页
- 点顶部「‹ 返回」或按返回：详情页逐级后退（支持 比赛 → 队伍 → 选手 多级）
- **防烧屏**：60 秒无操作把屏幕亮度降到最低并停止后台轮询，触摸任意处恢复亮度并立即刷新一次
- **省电**：App 退到后台或屏幕已压暗时停止一切轮询，回到前台或点亮时立刻补一次刷新

## 数据来源

[5E 对战平台](https://event.5eplay.com/csgo/matches) 的公开赛事接口，**无需 API key、无需登录、无需代理**：

- 数据：`https://esports-data.5eplaycdn.com`
- 补充：`https://app.5eplay.com`
- 图片：`https://oss.5eplay.com`

接口逆向整理见 [56dz/5eplay-api](https://github.com/56dz/5eplay-api)。

> 排名页的 `rank` 是 **HLTV 世界排名积分**，`valve_rank` 是 **Valve VRS**。5E 平台自己不发布排名，
> 同一响应里两套榜的字段并列，客户端按当前榜单取对应字段。

## 编译

```bash
bash build.sh        # 需要 ../env 下的 android-sdk 与 jdk；无 Gradle
```

输出 `cs2watch.apk`（debug 签名，`debug.keystore`）。

## 安装

```bash
../env/android-sdk/platform-tools/adb.exe install -r cs2watch.apk
../env/android-sdk/platform-tools/adb.exe shell am start -n com.dsh.cs2watch/.Main
```

## 说明

- 手表需联网（Wi-Fi）。首次启动拉取数据约 2–4 秒。
- 5eplay 服务端不返回 gzip，列表请求已控制 limit 以照顾手表流量。
- 比赛数据缓存 90 秒，赛事缓存 20 分钟，排名缓存 30 分钟，队伍 / 选手详情缓存 12 / 16 条。
- **离线兜底**：所有成功响应都会落到 `getCacheDir()`（整个目录限 3 MB，超出按最旧淘汰）。断网或请求失败时自动改用上次的好数据，标题旁会显示橙色「离线」标记，网络恢复后自动消失。
- 手表息屏后 `input keyevent` 唤不醒，调试时可临时 `adb shell dumpsys battery set ac 1 && adb shell dumpsys battery unplug`，结束务必 `adb shell dumpsys battery reset`。

---

## 圆屏版（cs2watch_round）

本目录是移植到 **OPPO OWW251 圆屏手表**（466×466 px，density 320，Android 11 / API 30）的版本：

- 包名 `com.dsh.cs2watch.round`，应用名「CS2赛事圆屏」，输出 `cs2watch_round.apk`，targetSdk 30 / minSdk 26。
- 布局全部按屏幕半径和 dp 计算：列表卡片按弦宽内缩；首项、末项都能滚到屏幕中间；标题居中；筛选胶囊改为左上弧形环段（文字沿弧排列）；刷新改为右上圆形按钮；分页小点排在底部圆弧上；详情页顶部居中「‹ 返回 · 页名」。
- 防烧屏、缓存、离线标记逻辑不变。

构建（工程不在原位置，必须显式指定工具链）：

```bash
export SDK=/d/Users/Daniel/code/DSH/watch/env/android-sdk
export JDK=/d/Users/Daniel/code/DSH/watch/env/jdk
export PYTHON=/d/Users/Daniel/code/DSH/watch/env/venv/Scripts/python.exe
bash build.sh                       # 末尾 ==> signed OK
adb install -r cs2watch_round.apk
adb shell am start -n com.dsh.cs2watch.round/.Main
```

调试脚本：`tools/shot.sh 名字 [tap x y]...` 点击后截图到 `shots/` 并做边缘越界检查（`tools/rimcheck.py`，需带 Pillow 的 Python，用 PY 变量指定）。
圆屏的坑和布局公式见 [LESSONS.md](LESSONS.md)。
