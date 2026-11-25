# 任务交接：补全 5eplay CS2 接口逆向

> ⚠️ **已过时**：这份交接书是当时派发给另一个 agent 的任务单，任务已完成并产出独立仓库
> [56dz/5eplay-api](https://github.com/56dz/5eplay-api)。本文件仅作历史留存。


## 你的角色

你是一个**接口逆向工程师**。你的唯一产出是**接口结论 + 可直接 curl 复现的命令**，写进 `D:\Users\Daniel\code\DSH\watch\cs2watch\docs\5eplay-api.md`。
**不要改 App 的 Java 代码**（另一个人在并行改 UI，会冲突）。

## 背景

我们要给 OPPO Watch 2 做一个 CS2 赛事 App。原来的 Cito API 每月只有 500 次免费额度，不够用，所以要换成 5eplay（5E 对战平台）的数据接口。

`https://event.5eplay.com/csgo/matches` 是它的网页版。它前端是 React/Next，JS chunk 已经从网页上扒下来放在：

```
C:\tmp\c5e\*.js
```

里面能看到所有接口路径的拼装逻辑，例如：

```js
// 5428.js
url:"/v1/api/csgo/match/".concat(t,"/event/log?update_version=0&limit=500")
url:"/v1/api/csgo/matches/".concat(a,"/data")
url:"/v1/api/csgo/matches/".concat(t,"/analysis_v1")
// 3902.js
url:"/v1/api/csgo/matches".concat((0,m.eA)(l))   // l = {tt_ids, game_status, limit, page}
// 177.js
url:"/v1/api/csgo/tournaments/".concat(id,"/stages")
url:"/v1/api/csgo/tournaments/".concat(id,"/introduction")
url:"/v1/api/csgo/focus/tournaments".concat(qs)
url:"/v1/api/csgo/team_players/batch?team_ids="
// 4351.js
url:"/v1/api/csgo/teams/".concat(...)
url:"/v1/api/csgo/team/tt/".concat(...)
url:"/v1/api/csgo/mfilter/team/options?team_id="
// 5428.js 里 app.5eplay.com 的
url:"/api/score/match_score_tab?match_id=".concat(t,"&game_type=1")
url:"/api/score/match_score_list?match_id=".concat(t,"&tab=").concat(a,"&game_type=1&team_id=").concat(l)
```

**这些 chunk 是你最重要的线索来源**，先把它们读一遍，比瞎试参数快 10 倍。用 `grep` / Python 正则去搜 `url:"`、`apiUrl:`、`concat(` 等模式。

## 硬性环境约束

1. **本机（Windows）访问外网必须走代理**：
   ```bash
   curl --socks5-hostname 127.0.0.1:10808 -A "Mozilla/5.0" "<url>"
   ```
   不加代理会直接超时。
2. 不要开浏览器、不要装包、不要 npm install。只用 `curl` + `python`。
3. 输出 JSON 用 `python -c "import json,sys; d=json.load(sys.stdin); ..."` 来格式化，别 `cat` 一大坨。
4. 写文件用 write 工具；改文件用 edit。工作目录 `D:\Users\Daniel\code\DSH\watch`。
5. 遇到 404 / `参数错误` 记下来写进"死路"章节，不要反复试同一个。

## 已验证可用的接口（不用重测，直接看文档）

见 `docs/5eplay-api.md` 的 1~6 节。核心是这 4 个：

```
/v1/api/csgo/matches?page=1&limit=20&game_status={0|1|2}[&tt_ids=...]   # 列表
/v1/api/csgo/matches/{mc_id}/data                                        # 详情：每图比分+选手数据
/v1/api/csgo/match/{mc_id}/event/log?update_version=0&limit=500          # 回合流水
app.5eplay.com/api/score/match_score_list?match_id=&tab=match_player&game_type=1&team_id=  # 整场选手汇总
```

## 你要补齐的 8 件事（按优先级）

### P0-1 赛事列表的正确参数 ★最影响 App

`/v1/api/csgo/tournaments?page=1&limit=3` 永远返回 `data.items: []`。但网页 `event.5eplay.com/csgo/matches` 上是有赛事列表的。

做法：
- 在 `C:\tmp\c5e\*.js` 里找 `tournaments` 相关的调用，看它到底传了什么 query（`m.eA(l)` 这种是序列化函数，要看调用方传的 `l` 对象长什么样）
- 注意可能有 `grade`（赛事等级：1=Major / 7=S+ / 2=S级 / 3=A级…，见 `/v1/api/csgo/mfilter/tournaments/options` 的返回）、`status`、`time_range`、`game_status` 等
- 也可能是 `/v1/api/csgo/mfilter/tournament/search`（这个能用，但只给 name + tt_id，没有封面/时间/奖金）
- 目标：**拿到带 logo / bonus / start_time / end_time / grade / status 的赛事列表**

### P0-2 赛事详情里"参赛队伍"和"赛程"

- `tournaments/{tt}/introduction` 已能拿到 `basic` + `cur_team_rank` + `team_rank`，把 **`team_rank` 的真实结构**（队伍名/logo/排名/奖金）写清楚
- `tournaments/{tt}/stages` 的 `graph` 是个**超长 JSON 字符串**（赛程树），里面有 `matches[]`（t1/t2/start_ts/end_ts）。把它 parse 出来，确认能否直接当"赛程/对阵图"用

### P0-3 队伍近期比赛

`/v1/api/csgo/team/matches_v1/{team_id}?page=1&limit=20&status={0..4}` 永远 `matches: []`。
- 先从 chunk 里找正确的参数名和 status 枚举
- 试 `status` 传空、传 `all`、或者改用 `/v1/api/csgo/teams/{id}/matches?page=1&limit=20`（5428.js 里有这个）

### P1-4 世界排名 / VRS 积分

- `/v1/api/csgo/new/rank/team_list` → 404。从 chunk 里找排名页的接口（可能带 `type`、`region`、`page` 参数）
- 网页上应该有个"世界排名" tab

### P1-5 ban/pick 选图过程

- `bouts_state[].bp_act` 只有 `"t2_pick"` 这种单值。找完整的 ban/pick 序列在哪个字段（可能在 `/data` 的 `global_state`，或在 `stages` 的 `graph` 里）
- 目标：能显示"图1 Ancient（T2 pick）→ 图2 Dust2（T1 pick）→ 图3 Inferno（decider）"

### P2-6 加时赛结构

- `t1_stats.ot_data` / `ot_score` 需要有加时的比赛才能验证。先翻已结束的比赛列表，找一场出现加时的（比分 16:14 / 19:16 之类），拉 `/data` 看结构
- 如果实在找不到，就在文档里明确写"未验证，字段位置在 t1_stats.ot_data/ot_score"

### P2-7 直播实时性

- `state.status=1` 的比赛，`/data` 里 `bouts_state[].status=1` 表示进行中，`curr_round_num` 是当前回合
- 确认轮询间隔建议（网页端是多少秒一次？看 chunk 里的 `setInterval` / `setTimeout`）
- `eplus_realtime_topic` 字段暗示有推送，但手表端用轮询即可，**只需要给出建议间隔**

### P2-8 `/data` 的增量参数

- 试 `?update_version=0`、`?local_ver=0`、`?state_ver=` 等，看有没有增量返回（手表流量敏感）

## 输出要求

改 `docs/5eplay-api.md`：
- 每个新结论都要写成**可直接复制运行的 curl 命令 + 真实返回片段（截断到 200 字以内）**
- 追加在对应章节下，不要删掉已有内容
- 最后更新第 7 节"死路"和第 8 节"待办"（做掉的打勾，没做掉的写明原因）

另外新建 `docs/5eplay-fields.md`，把**最终给 App 用的字段清单**整理成表：

| 用途 | 接口 | 字段路径 | 示例值 |
| --- | --- | --- | --- |
| 比赛列表-队名 | /matches | `data.matches[].mc_info.t1_info.disp_name` | `MOUZ` |
| … | | | |

## 完成标准

给主 agent 回一条消息，包含：
1. 补齐了哪几项（P0/P1/P2 逐项打勾）
2. 仍然没搞定的，和原因
3. `docs/5eplay-fields.md` 的路径
4. 一条"最容易踩坑的 3 个点"
