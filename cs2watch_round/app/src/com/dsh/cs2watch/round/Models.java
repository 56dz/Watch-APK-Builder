package com.dsh.cs2watch.round;

import java.util.ArrayList;
import java.util.List;

/** Plain data models filled in by the 5eplay parsers. */
public class Models {

    /** One map inside a series. */
    public static class MapScore {
        public String name = "";
        public int s1, s2;
        public int status = -1;        // -1 未开始 / 1 进行中 / 2 已结束
        public String result = "";     // t1 | t2 | ""
        public String pick = "";       // t1_pick | t2_pick | left | ""
        public int round;              // 当前回合
        public boolean hasHalf;        // 有上下半场数据
        public int fh1, fh2, sh1, sh2, ot1, ot2;
        public boolean hasOt;
        /** 该图的选手数据（bouts_state.t1_pr_stats / t2_pr_stats），点开地图才显示。 */
        public final List<Player> p1 = new ArrayList<>();
        public final List<Player> p2 = new ArrayList<>();

        public boolean live() { return status == 1; }
        public boolean done() { return status == 2; }

        public String pickLabel() {
            if ("t1_pick".equals(pick)) return "1选";
            if ("t2_pick".equals(pick)) return "2选";
            if ("left".equals(pick)) return "决胜";
            return "";
        }

        /** "7:5 / 6:5" 半场比分，没有数据时返回空串。 */
        public String halfLine() {
            if (!hasHalf) return "";
            StringBuilder sb = new StringBuilder();
            sb.append(fh1).append(':').append(fh2);
            sb.append(" / ").append(sh1).append(':').append(sh2);
            if (hasOt) sb.append(" OT").append(ot1).append(':').append(ot2);
            return sb.toString();
        }
    }

    /** A single match shown on the 今日 / 直播 / 赛果 pages. */
    public static class Match {
        public String id = "";
        public String event = "";       // tournament display name
        public String ttId = "";
        public String stage = "";       // e.g. 半决赛
        public String city = "";
        public String t1 = "", t2 = "";
        public String t1Id = "", t2Id = "";     // team ids, for the team page
        public String t1Logo = "", t2Logo = "";
        public int s1, s2;              // series score (maps won)
        public int bo = 3;
        public int winner;              // 1 = team1 won, 2 = team2 won, 0 = unknown
        public long start;              // epoch millis
        public String status = "upcoming";   // upcoming | live | completed
        public String tier = "";        // S / A / B / C
        public String tierLabel = "";
        public String odds1 = "", odds2 = "";   // percent, e.g. "69"
        public final List<MapScore> maps = new ArrayList<>();

        public boolean live() { return "live".equals(status); }
        public boolean done() { return "completed".equals(status); }
        public boolean hasScore() { return live() || done(); }

        /** "Nuke 13:3 · Ancient 13:6" for the compact map line. */
        public String mapLine() {
            StringBuilder sb = new StringBuilder();
            for (MapScore m : maps) {
                if (m.status < 1) continue;
                if (sb.length() > 0) sb.append(" · ");
                sb.append(m.name).append(' ').append(m.s1).append(':').append(m.s2);
            }
            return sb.toString();
        }
    }

    /** A player row inside the match detail page. */
    public static class Player {
        public String id = "";          // csgo_pl_xxx, opens the player page
        public String name = "";
        public String kill = "", death = "", assist = "";
        public String rating = "", adr = "", kast = "";
        public String kdRate = "";      // 赛前对比只有 KD 比率，没有击杀数
        public String country = "";
        public String position = "";    // 突破手 / 狙击手 …（队伍页的名单用到）
        public int side;                // 1 or 2
        public boolean mvp;

        public String kd() {
            String k = kill.length() == 0 ? "0" : kill;
            String d = death.length() == 0 ? "0" : death;
            return k + "-" + d;
        }

        /** 有击杀数就用 K-D，否则退回 KD 比率。 */
        public String kdText() {
            if (kill.length() > 0 || death.length() > 0) return kd();
            return kdRate.length() > 0 ? kdRate : "";
        }
    }

    /** 一张地图上双方的历史胜率（赛前对比）。 */
    public static class MapRate {
        public String name = "";
        public int r1 = -1, r2 = -1;    // 胜率百分比，-1 = 无数据
        public String bp = "";          // t1_pick | t2_pick | t1_ban | t2_ban

        public String bpLabel() {
            if ("t1_pick".equals(bp)) return "1选";
            if ("t2_pick".equals(bp)) return "2选";
            if ("t1_ban".equals(bp)) return "1禁";
            if ("t2_ban".equals(bp)) return "2禁";
            return "";
        }

        public boolean picked() {
            return "t1_pick".equals(bp) || "t2_pick".equals(bp);
        }
    }

    /** 一条历史交手 / 近期战绩（相对当前比赛的两支队伍）。 */
    public static class PastMatch {
        public String date = "";
        public String t1 = "", t2 = "";
        public String score = "";       // "2:0"
        public String event = "";
        public int winner;              // 1 = 当前 t1 赢, 2 = 当前 t2 赢, 0 = 未知
    }

    /** 赛前对比数据（analysis_v1）：未开赛的比赛只有它有内容。 */
    public static class Analysis {
        public String winRate1 = "", winRate2 = "";
        public String kd1 = "", kd2 = "";
        public String rating1 = "", rating2 = "";
        public String fk1 = "", fk2 = "";        // 首杀率
        public String h2hWin1 = "", h2hWin2 = ""; // 交手胜率
        public final List<MapRate> maps = new ArrayList<>();
        public final List<Player> players1 = new ArrayList<>();
        public final List<Player> players2 = new ArrayList<>();
        public final List<PastMatch> recent1 = new ArrayList<>();
        public final List<PastMatch> recent2 = new ArrayList<>();
        public final List<PastMatch> h2h = new ArrayList<>();

        public boolean empty() {
            return maps.isEmpty() && players1.isEmpty() && players2.isEmpty()
                    && winRate1.length() == 0 && winRate2.length() == 0;
        }

        /** "胜率 64% / 49%" 这种一行对比。 */
        public static String pair(String a, String b) {
            String x = a == null ? "" : a;
            String y = b == null ? "" : b;
            if (x.length() == 0 && y.length() == 0) return "";
            return x + "  /  " + y;
        }
    }

    /** One ban / pick step of the veto. */
    public static class BanPick {
        public String type = "";        // ban | pick | left
        public String map = "";
        public String side = "";        // t1 | t2
    }

    /** Everything the detail page needs for one match. */
    public static class MatchDetail {
        public Match match;
        public final List<BanPick> bp = new ArrayList<>();
        public final List<Player> series = new ArrayList<>();      // 整场汇总，side 1/2
        public final List<List<Player>> perMap = new ArrayList<>(); // 每张图的选手数据
        public String mvpName = "", mvpRating = "";
        public long fetchedAt;

        /** 赛前对比；未开赛的比赛它是唯一的数据来源。 */
        public Analysis pre;
        /** 赛前对比是否已尝试加载（避免失败后无限重试）。 */
        public boolean preTried;

        public List<Player> side(int s) {
            List<Player> out = new ArrayList<>();
            for (Player p : series) if (p.side == s) out.add(p);
            return out;
        }
    }

    /** A tournament row from the 赛事 page. */
    public static class Tournament {
        public String id = "";
        public String name = "";
        public String tier = "";        // S / A / B / C
        public String tierLabel = "";
        public String dateText = "";    // e.g. "10月24–31日"
        public String dateShort = "";   // e.g. "10.24–31" (list rows)
        public String prize = "";
        public String location = "";
        public String status = "";      // upcoming | live | past
        public String winner = "", runnerUp = "";
        public String character = "";   // 赛制说明
        public final List<String> maps = new ArrayList<>();          // 赛事地图池
        public final List<String[]> stages = new ArrayList<>();      // {赛段名, 赛制说明}
        public long start, end;
        public int teamCount;
        public boolean detailLoaded;
        public boolean matchesLoaded;   // 该赛事的比赛列表是否已拉到
        public String token = "";       // page_token for the event list cursor
        public final List<String> teamNames = new ArrayList<>();
        public final List<String> teamIds = new ArrayList<>();       // parallel to teamNames
        public final List<String[]> prizeRows = new ArrayList<>();   // {rank, team, bonus}
        public final List<Match> matches = new ArrayList<>();        // 赛程（按时间升序）
        // 赛事维度统计（tournaments/team_data、map_data）
        public final List<String[]> teamStats = new ArrayList<>();   // {队名, 胜率, KD, Rating}
        public final List<String[]> mapStats = new ArrayList<>();    // {地图, 出场率, CT胜率, T胜率}
        public boolean statsLoaded;                                  // 统计是否已拉到

        public boolean ongoing() { return "live".equals(status); }
        public boolean upcoming() { return "upcoming".equals(status); }
    }

    /** A row of the world ranking. */
    public static class RankRow {
        public String rank = "", name = "", point = "", region = "", change = "", id = "";
    }

    /** 一支队伍近期的某场比赛（队伍页 / 选手页里的战绩行）。 */
    public static class TeamMatch {
        public String id = "";          // 比赛 id，可再点进详情
        public String date = "";        // "10.27"
        public String t1 = "", t2 = "";
        public String score = "";       // "2:1" / "13:9" 单图
        public String event = "";
        public String stage = "";
        public int winner;              // 1 = t1 赢, 2 = t2 赢, 0 = 未知
    }

    /** 队伍详情页（teams/{id}/overview）。 */
    public static class TeamDetail {
        public String id = "";
        public String name = "", logo = "";
        public String country = "", region = "";
        public String rank = "", vrank = "", points = "", bonus = "", coach = "", ageAvg = "";
        public String wins = "", losses = "", draws = "", winRate = "", kdRatio = "", mapCount = "";
        public String kills = "", deaths = "";
        public final List<Player> players = new ArrayList<>();
        /** {map, winRate, ctRate, tRate, pistolRate, firstKillRate} — merged from 6.9. */
        public final List<String[]> maps = new ArrayList<>();
        public final List<String[]> honors = new ArrayList<>();   // {time, text, detail}
        public final List<TeamMatch> recent = new ArrayList<>();
        public long fetchedAt;

        public boolean empty() { return name.length() == 0; }
    }

    /** 选手详情页（player/{id}/data）。 */
    public static class PlayerDetail {
        public String id = "";
        public String name = "", team = "", teamId = "", country = "", birthday = "";
        public String position = "", top20 = "", bonus = "";
        // 生涯/赛事统计
        public String rating = "", kd = "", adr = "", kast = "", impact = "";
        public String dpr = "", kpr = "", headshot = "", kill = "", death = "";
        public String mapsPlayed = "", roundsPlayed = "";
        public final List<String[]> maps = new ArrayList<>();     // {map, rating, kd, uses}
        public final List<String[]> honors = new ArrayList<>();   // {date, event, rank}
        public final List<String[]> weaponCate = new ArrayList<>(); // {类别, 击杀占比, 总击杀}
        public final List<String[]> weapons = new ArrayList<>();  // {枪械, 占比}
        public final List<String[]> clutches = new ArrayList<>(); // {1V1, 次数}
        public final List<String[]> killTypes = new ArrayList<>(); // {击杀回合, 次数}
        public final List<TeamMatch> recent = new ArrayList<>();  // 近期比赛
        public String teammateCount = "";   // 最近同队队友数（player_data.players）
        public long fetchedAt;

        public boolean empty() { return name.length() == 0; }
    }
}
