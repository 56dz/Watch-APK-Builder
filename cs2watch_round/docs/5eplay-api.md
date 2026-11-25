# 5eplay CS2 数据接口逆向笔记（已实测）

> ⚠️ **已过时**：这份笔记是逆向过程中的中间稿，完整、已校对且持续更新的接口文档在独立仓库
> [56dz/5eplay-api](https://github.com/56dz/5eplay-api)（本地 `D:/Users/Daniel/code/DSH/5eplay-api`）。
> 本文件仅作历史留存，与仓库冲突时以仓库为准。


> 目标：为 OPPO Watch 2 的 CS2 赛事 App 提供免费数据源，替换掉有 500 次/月额度的 Cito API。
> 本文件记录**已用 curl 实测通过**的接口与字段，以及**尚未确定**的部分（留给接手的人继续挖）。

## 0. 环境前提

- 本机（Windows）访问墙外需要代理：`curl --socks5-hostname 127.0.0.1:10808 ...`
- **手表**（OPPO Watch 2，Android 8.1）直连 5eplay 无需代理，实测：
  - `https://esports-data.5eplaycdn.com/...` → 200
  - `https://app.5eplay.com/...` → 200
  - `https://oss.5eplay.com/...`（队伍/赛事/地图/选手 logo）→ 200
- **完全不需要 key、cookie、referer、UA**（不带任何 header 也返回 200）。
- 返回统一信封：`{"success":bool,"errcode":int,"message":string,"data":...}`

## 1. 比赛列表（核心）

```
GET https://esports-data.5eplaycdn.com/v1/api/csgo/matches?page=1&limit=20&game_status=<0|1|2>
    [&tt_ids=csgo_tt_8251]     # 按赛事过滤
```

- `game_status=1` → `data.live_matches[]` 有值（进行中）
- `game_status=2` → `data.matches[]` 为已结束
- `game_status=0`（或不传）→ `data.matches[]` 为未开始/近期
- 分页有效：`page=3&limit=10` 正常返回不同数据；`limit=100` 可用
- `live_matches` 与 `matches` 两个数组**始终存在**，按需取

单个比赛元素：

```json
{
  "mc_info": {
    "id": "csgo_mc_2399854",          // 比赛 ID
    "plan_ts": "1794393000",           // 排期时间戳（秒，字符串）
    "format": "3",                     // BO3 = 3
    "round_name": "首轮",
    "tt_stage": "小组赛",
    "tt_stage_desc": "小组赛 胜者组 首轮",
    "grade": "2", "star": "3",
    "group_id": 5587,
    "t1_info": {"id":"csgo_tm_4494","disp_name":"MOUZ","logo":"https://oss.5eplay.com/...png","country":"","rank":"","v_rank":null},
    "t2_info": {"id":"csgo_tm_5995","disp_name":"G2","logo":"..."}
  },
  "state": {
    "status": "0",                     // 见下
    "t1_score": "2", "t2_score": "1",  // 大比分（局分）
    "t1_quick_score": "", "t2_quick_score": "",
    "round_num": "",                   // 当前第几回合（直播时）
    "bout_states": [],                 // 直播时有内容
    "t1_odds":"1.35","t2_odds":"3.11", "t1_odds_percent":"69","t2_odds_percent":"31",
    "video_status":"2", "live_status":"", "dark_horse":"2"
  },
  "tt_info": {
    "id": "csgo_tt_8251",
    "disp_name": "BLAST对抗赛 2026 S2",
    "abbr_zh": "BLAST对抗赛 2026 S2",
    "abbr_en": "BLAST Rivals 2026 S2",
    "logo": "https://oss.5eplay.com/sport/csgo/event/7556.png",
    "bonus": "$1,000,000",
    "city_name": "中国香港赤鱲角",
    "grade": "2", "grade_label": "S级赛事", "special_grade_label": "S级赛事",
    "color": "663dea", "special_color": "663dea",
    "mode": "2",
    "start_time": "2026-11-09 00:00:00",
    "end_time": "2026-11-15 23:59:59",
    "status": "upcoming"
  }
}
```

`state.status`：`0` 未开始 / `1` 进行中 / `2` 已结束（实测三档）。

## 2. 比赛详情（含每张地图小比分 + 选手数据）★关键

```
GET https://esports-data.5eplaycdn.com/v1/api/csgo/matches/{mc_id}/data
```

已结束的比赛约 125 KB，直播中约 60 KB。结构 `data.match`：

```
match.keys = bouts_state, global_state, mc_info, tt_info
```

`bouts_state[]` 每个元素 = 一张地图（Mag）：

| 字段 | 含义 |
| --- | --- |
| `bout_num` | 第几局 `"1"` `"2"` `"3"` |
| `map_name` | `"Ancient"` / `"Dust2"` / `"Inferno"` … |
| `map_icon` / `map_bgm` | 地图图标 URL |
| `status` | `2`=已打完，`1`=进行中，`-1`=未开始（关键！） |
| `result` | `"t1"` / `"t2"` / `""` 本图胜者 |
| `disp_name` | `"第一局"` |
| `bp_act` | `"t2_pick"` 等 —— 选图/ban 动作 |
| `round_num` | 本图打了多少回合 |
| `curr_round_num` / `curr_bout_stage` | 直播时当前回合 / 半场 |
| `t1_stats` / `t2_stats` | **本图比分**，见下 |
| `t1_pr_stats` / `t2_pr_stats` | **本图选手数据**，见下 |
| `t1_pr_stats_ct` / `t1_pr_stats_t` | 分 CT / T 两边的选手数据 |
| `pr_stats` | 本图亮点对比（首杀王等） |
| `milestones` | 里程碑 |
| `event_log` | 最后一个事件，如 `{"log":{...},"text":"比赛已结束"}` |
| `start_time` / `end_time` | 秒级时间戳 |

### 2.1 地图小比分（13:11 这种）

```json
"t1_stats": {
  "quick_score": "13",     // 本图最终比分（直接用它！）
  "all_score": "13",
  "sh_score": "5",  "sh_data": [0,2,2,2,2,2,0,0,0,0,0,0],  "sh_role": "T",   // 上半场
  "fh_score": "8",  "fh_data": [0,0,1,1,4,4,1,0,4,5,0,1],  "fh_role": "CT",  // 下半场
  "ot_data": [],   "ot_role": "", "ot_score": ""            // 加时
}
```
> `quick_score` = 该图我方得分；对手比分取 `t2_stats.quick_score`。
> 主客顺序与 `mc_info.t1_info/t2_info` 一致。

### 2.2 选手数据（K/D/A、Rating、ADR、KAST…）

`t1_pr_stats[]` / `t2_pr_stats[]`，每个元素字段：

```
id, name, kill, death, assist,
rating, impact, adr, kast, kpr, dpr, kdratio, kd_diff, fkdiff,
headshot, head_shot_rate, first_blood_num, first_blood_rate, first_death_num,
round_mvp, more_kill (多杀), k2 k3 k4 k5, traded_death,
weapon, weapon_logo, portrait, half_portrait, country_logo,
counter_kill_map, first_kill_map, counter_kills[], first_kills[],
v1..v5, money, hp, alive, helmet, kevlar, has_defusekit,
unpack_num, subpackage_num, cl_win_num, final_victory_num, swing, mk_rating
```

示例值：`rating:"1.07"`, `kill:"28"`, `death:"27"`, `kast:"75.0%"`, `adr:"81.3"`, `kdratio`, `head_shot_rate:"17.6%"`。

### 2.3 global_state

含 `ana_map_desc_flag`、`avg_player_stats`（全队平均）、以及地图/ban pick 描述等。未逐字段梳理完。

## 3. 回合流水（每回合谁赢、比分怎么走）

```
GET https://esports-data.5eplaycdn.com/v1/api/csgo/match/{mc_id}/event/log?update_version=0&limit=500
    [&bout_id={mc_id}_{n}]     # 只看第 n 张图
```

`data.list[]`，每个元素 `{bout_id, bout_num, map_name, log_info, update_version}`，
`log_info` 是**二次转义的 JSON 字符串**，需二次 parse：

```json
{"type":"2",
 "round_end":{"ct_score":"13","t_score":"9","winner":"CT","win_type":"Bomb_Defused","win_type_app":4},
 "round_start":{"round_num":"","map":"","bout_num":""}, ...固定空壳字段}
```

- `type=="2"` → 回合结束，`round_end.ct_score/t_score` 是该回合结束时的比分
- `type=="1"` → 回合开始，`round_start.round_num` 是回合序号
- 其它 type（`8` `4` `6` `3` `10`）是击杀/经济/中场等事件，击杀里带 `killer_nick/victim_nick/weapon`
- `data.from_ver` / `to_ver` / `not_more`：`not_more:"1"` 表示没有更多了；增量拉取靠 `update_version`
- 一局 BO3 约 500 条，**倒序返回**（最后一条是最新）

## 4. app.5eplay.com 的两个补充接口

```
GET https://app.5eplay.com/api/score/match_score_tab?match_id={mc_id}&game_type=1
→ data[] = [{tab:"match_player", id:"hltv_team_12646", name:"CW", logo:"...", is_selected:true}, ...]
   注意：未开赛的比赛返回 []；这里的 id 是**队伍 id**，要传给下面那个接口

GET https://app.5eplay.com/api/score/match_score_list?match_id={mc_id}&tab=match_player&game_type=1&team_id={team_id}
→ data[] = [{tab:"match_player", card_content_tab:"player", id:"csgo_pl_18638", name:"sk0R",
             rating:"1.07", kill:"28", death:"27", kast:"75.0%", adr:"81.3",
             positions:["步枪手"], is_mvp_player:false, is_coach_player:false,
             logo, country_logo, ...}]
```
> 注意：`tab` 只认 `match_player`，且**必须带 `team_id`**，否则报 `参数错误`。
> 这个接口给的是**整场汇总**的选手数据（跨图合计），`/data` 里的是**单图**数据。

## 5. 赛事（Tournament）

```
GET /v1/api/csgo/mfilter/tournament/search?page=1&limit=20
→ data.items[] = [{name:"MESA Pro 2026 万圣节杯", tt_id:"csgo_tt_9462"}]
   data.total_page / total_rows         # 只有名字和 id，没有封面/时间/奖金

GET /v1/api/csgo/tournaments/{tt_id}/introduction
→ data.basic = {tt_id, id, name_zh, name_en, abbr_zh, abbr_en, logo, bonus, city_name,
                start_time, end_time, grade, status, current_stage_id, tt_name_show, character}
  data.cur_team_rank[] = 队伍排名/奖金分配
  data.team_rank

GET /v1/api/csgo/tournaments/{tt_id}/stages
→ data[] = [{group 结构 + graph(JSON 字符串，是赛程树/对阵图的布局数据)}]

GET /v1/api/csgo/focus/tournaments?tt_ids={tt_id}
→ data.items[].basic_info = {id, disp_name, abbr_zh, logo, bonus, city_name, color,
                             grade, grade_label, start_time, end_time, status, mode}
```

## 6. 队伍 / 选手

```
GET /v1/api/csgo/teams?page=1&limit=20
→ data.items[] = [{id:"csgo_tm_7020", name:"Spirit", logo, kd:"1.07", kd_diff:"11214",
                   map_count:"2073", players:[...] }]

GET /v1/api/csgo/team_players/batch?team_ids=csgo_tm_4494,csgo_tm_5995
→ data.items[] = [{id, name, logo, players:[{name, player_id, portrait}]}]

GET /v1/api/csgo/team/matches_v1/{team_id}?page=1&limit=20&status={0|1|2|3|4}
→ data.items = {game_played, win_rate:"72.0", win_rate_desc:"近三个月胜率72.0%",
                wins_streak, matches:[]}      # ← matches 目前实测为空，status 枚举没试出来
```

## 7. 已知 404 / 死路（别浪费时间）

- `GET /v1/api/csgo/matches/{id}`（不带 `/data`）→ 404
- `GET /v1/api/csgo/match/{id}` → 404
- `GET /v1/api/csgo/tournaments?page=1&limit=3` → `data.items: []`（空，参数没猜对）
- `GET /v1/api/csgo/new/rank/team_list` → 404
- `GET /v1/api/csgo/teams/{team_id}` → 404
- `GET /v1/api/csgo/mfilter/team/list` → 404
- `GET /v1/api/csgo/tournaments/team_data|player_data`（无参数）→ 待试
- `app.5eplay.com/api/score/match_score_list` 的 `tab` 试过 `0/1/2/3/match_map/match_data/map/bout/match_score/match_detail` 全部 `参数错误`，只认 `match_player`

## 8. 待办（交给接手的 agent）

1. **`state.status` 与 `game_status` 的完整枚举**：确认 0/1/2 之外还有没有（延期/取消）。已知 `tt_info.status` 有 `upcoming`，可能还有 `ongoing`/`finished`/`postponed`。
2. **赛事列表正确参数**：`/v1/api/csgo/tournaments` 一直返回空。需要从 `event.5eplay.com` 页面实际抓包确认（页面上有"即将开始/进行中/已结束"分栏）。
3. **`team/matches_v1` 的 `status` 枚举**：为什么 `matches` 总是空。
4. **ban/pick 选图过程**：`bouts_state[].bp_act` 只有 `t2_pick`，需要确认完整的 pick/ban 序列在哪个字段（可能在 `global_state` 或 `stages` 的 graph 里）。
5. **队伍排名 / VRS 积分**：`/v1/api/csgo/new/rank/team_list` 404，找找正确的排名接口（页面有"世界排名"）。
6. **直播实时性**：列表轮询的合理间隔；是否有 WebSocket 推送（`eplus_realtime_topic` 字段暗示有，但手表端建议直接用轮询）。
7. **加时赛**：`ot_data` / `ot_score` 的结构没实测到（需要有加时的比赛）。
8. **`/data` 接口的增量参数**：是否支持 `update_version` 之类的增量拉取，减少流量。

## 9. 手表端约束（写代码时注意）

- 屏幕 372×430 px，density 320 → **186×215 dp**，圆角矩形屏
- Android 8.1 / API 27，只能用平台自带的 `HttpURLConnection` 风格写法（现有工程用 `HttpClient` + 自写 JSON 解析）
- 现有工程：`D:\Users\Daniel\code\DSH\watch\cs2watch`，用 `build.sh`（aapt2 + javac + d8 + apksigner，无 Gradle）
- 手表上装 App 用 `env\android-sdk\platform-tools\adb.exe install -r`
- **网络请求必须放子线程**，主线程只画 UI；现有 `DataLoader` 已有线程池
- 每次 `/matches/{id}/data` 有 60–125 KB，手表端要**缓存 + 按需加载**，不要一次拉全部
