package com.dsh.cs2watch.round;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Calendar;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.zip.GZIPInputStream;
import java.util.zip.InflaterInputStream;

/**
 * 5eplay (5E 对战平台) data source.
 *
 * Every endpoint below is keyless and returns {success, errcode, message, data}.
 * The service never gzips its responses, so request sizes are kept small.
 */
final class Fiveplay {

    static final String DATA = "https://esports-data.5eplaycdn.com";
    static final String APP = "https://app.5eplay.com";

    static final String UA = "Mozilla/5.0 (Linux; Android 8.1; OPPO Watch 2) CS2Watch/1.0";

    private static long sLastRequest;

    private Fiveplay() {}

    // ------------------------------------------------------------------ http

    /**
     * Fetch with an on-disk fallback: a successful body is cached, and a failed
     * request serves the last good body instead of an error screen. This keeps the
     * watch usable in lifts and on flaky Wi-Fi.
     */
    private static String request(String url, String body) throws IOException {
        String key = body == null ? url : url + "|" + body;
        try {
            String raw = fetch(url, body);
            Cache.put(key, raw);
            STALE.get()[0] = 0;
            return raw;
        } catch (IOException e) {
            String cached = Cache.get(key);
            if (cached != null) {
                int[] v = STALE.get();
                v[0] = 1;
                v[1]++;
                return cached;
            }
            STALE.get()[0] = 0;
            throw e;
        }
    }

    /**
     * Per-thread cache state: [0] = the last request was served from disk,
     * [1] = how many requests this thread has served from disk since the last drain.
     */
    private static final ThreadLocal<int[]> STALE = new ThreadLocal<int[]>() {
        @Override protected int[] initialValue() { return new int[2]; }
    };

    /** True when the last request on this thread fell back to the on-disk copy. */
    static boolean lastStale() { return STALE.get()[0] != 0; }

    /** True when any request on this thread fell back to disk; also resets the counter. */
    static boolean drainStale() {
        int[] v = STALE.get();
        boolean any = v[1] > 0;
        v[1] = 0;
        return any;
    }

    private static String fetch(String url, String body) throws IOException {
        // 1 req / 400 ms keeps us far under the CDN's patience without hurting UX.
        synchronized (Fiveplay.class) {
            long wait = 420 - (System.currentTimeMillis() - sLastRequest);
            if (wait > 0) {
                try { Thread.sleep(wait); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            }
            sLastRequest = System.currentTimeMillis();
        }
        HttpURLConnection c = (HttpURLConnection) new URL(url).openConnection();
        c.setConnectTimeout(12000);
        c.setReadTimeout(20000);
        c.setRequestProperty("User-Agent", UA);
        c.setRequestProperty("Accept", "application/json");
        c.setRequestProperty("Accept-Encoding", "identity");
        c.setInstanceFollowRedirects(true);
        if (body != null) {
            c.setRequestMethod("POST");
            c.setDoOutput(true);
            c.setRequestProperty("Content-Type", "application/json");
            c.getOutputStream().write(body.getBytes("UTF-8"));
        }
        int code = c.getResponseCode();
        if (code != 200) {
            c.disconnect();
            throw new IOException("HTTP " + code);
        }
        InputStream in = c.getInputStream();
        String enc = c.getContentEncoding();
        if ("gzip".equalsIgnoreCase(enc)) in = new GZIPInputStream(in, 8192);
        else if ("deflate".equalsIgnoreCase(enc)) in = new InflaterInputStream(in);
        ByteArrayOutputStream bo = new ByteArrayOutputStream(32768);
        byte[] buf = new byte[8192];
        int n;
        while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
        in.close();
        c.disconnect();
        return new String(bo.toByteArray(), "UTF-8");
    }

    /** Unwraps the {success,data} envelope, throwing a readable message on failure. */
    private static JSONObject data(String url, String body) throws Exception {
        String raw = request(url, body);
        JSONObject root = new JSONObject(raw);
        if (!root.optBoolean("success", false)) {
            // A cached body can be from an older API shape; only trust the failure
            // flag when the response actually came off the network.
            if (lastStale()) {
                JSONObject d = root.optJSONObject("data");
                if (d != null) return d;
            }
            String msg = root.optString("message", "");
            throw new IOException(msg.length() > 0 ? msg : "接口返回失败");
        }
        JSONObject d = root.optJSONObject("data");
        if (d == null) throw new IOException("空数据");
        return d;
    }

    private static String str(JSONObject o, String k) {
        if (o == null) return "";
        String v = o.optString(k, "");
        return "null".equals(v) ? "" : v;
    }

    private static long num(JSONObject o, String k) {
        if (o == null) return 0;
        String v = o.optString(k, "");
        if (v.length() == 0) return 0;
        try { return Long.parseLong(v.trim()); } catch (Exception e) { return 0; }
    }

    // ------------------------------------------------------------------ list

    static final int UP = 0, LIVING = 1, DONE = 2;

    /**
     * One page of matches. limit is bounded by what the watch can parse quickly;
     * a page of 40 is roughly 50–90 KB.
     */
    static List<Models.Match> list(int status, int page, int limit) throws Exception {
        String url = DATA + "/v1/api/csgo/matches?page=" + page + "&limit=" + limit
                + "&game_status=" + status;
        return parseList(data(url, null), status == LIVING);
    }

    /** Extracted from list() so the parsing can be exercised offline. */
    static List<Models.Match> parseList(JSONObject d, boolean liveList) {
        JSONArray a = liveList ? d.optJSONArray("live_matches") : d.optJSONArray("matches");
        List<Models.Match> out = new ArrayList<>();
        if (a == null) return out;
        for (int i = 0; i < a.length(); i++) {
            JSONObject o = a.optJSONObject(i);
            if (o != null) out.add(parseMatch(o));
        }
        return out;
    }

    static Models.Match parseMatch(JSONObject o) {
        Models.Match m = new Models.Match();
        JSONObject mc = o.optJSONObject("mc_info");
        JSONObject st = o.optJSONObject("state");
        JSONObject tt = o.optJSONObject("tt_info");

        m.id = str(mc, "id");
        m.stage = str(mc, "tt_stage_desc");
        if (m.stage.length() == 0) m.stage = str(mc, "tt_stage");
        m.bo = (int) num(mc, "format");
        if (m.bo < 1) m.bo = 3;

        JSONObject t1 = mc == null ? null : mc.optJSONObject("t1_info");
        JSONObject t2 = mc == null ? null : mc.optJSONObject("t2_info");
        m.t1 = str(t1, "disp_name");
        m.t2 = str(t2, "disp_name");
        m.t1Id = str(t1, "id");
        m.t2Id = str(t2, "id");

        long plan = num(mc, "plan_ts");
        m.start = plan > 0 ? plan * 1000L : 0;

        if (tt != null) {
            m.ttId = str(tt, "id");
            m.event = str(tt, "disp_name");
            if (m.event.length() == 0) m.event = str(tt, "abbr_zh");
            m.city = str(tt, "city_name");
            m.tier = gradeLetter(str(tt, "grade"));
            m.tierLabel = str(tt, "grade_label");
        }
        if (m.tier.length() == 0) m.tier = gradeLetter(str(mc, "grade"));

        int status = (int) num(st, "status");
        m.s1 = (int) num(st, "t1_score");
        m.s2 = (int) num(st, "t2_score");
        m.odds1 = str(st, "t1_odds_percent");
        m.odds2 = str(st, "t2_odds_percent");

        if (status == 1) m.status = "live";
        else if (status == 2) m.status = "completed";
        else m.status = "upcoming";

        if (m.status.equals("completed") || m.status.equals("live")) {
            if (m.s1 > m.s2) m.winner = 1;
            else if (m.s2 > m.s1) m.winner = 2;
        }

        JSONArray bs = st == null ? null : st.optJSONArray("bout_states");
        if (bs != null) {
            for (int i = 0; i < bs.length(); i++) {
                JSONObject b = bs.optJSONObject(i);
                if (b == null) continue;
                Models.MapScore ms = new Models.MapScore();
                ms.name = str(b, "map_name");
                ms.status = (int) num(b, "status");
                ms.result = str(b, "result");
                ms.round = (int) num(b, "round_num");
                ms.s1 = (int) num(b, "t1_quick_score");
                ms.s2 = (int) num(b, "t2_quick_score");
                m.maps.add(ms);
            }
        }
        return m;
    }

    /** 5eplay grade 2..5 -> S / A / B / C. */
    static String gradeLetter(String g) {
        if ("1".equals(g) || "2".equals(g)) return "S";
        if ("3".equals(g)) return "A";
        if ("4".equals(g)) return "B";
        if ("5".equals(g)) return "C";
        return "";
    }

    // ------------------------------------------------------------------ detail

    static Models.MatchDetail detail(String mcId) throws Exception {
        return parseDetail(data(DATA + "/v1/api/csgo/matches/" + mcId + "/data", null));
    }

    /** Extracted from detail() so the parsing can be exercised offline. */
    static Models.MatchDetail parseDetail(JSONObject d) throws Exception {
        JSONObject match = d.optJSONObject("match");
        if (match == null) throw new IOException("没有详情数据");

        Models.MatchDetail out = new Models.MatchDetail();
        out.fetchedAt = System.currentTimeMillis();

        Models.Match m = parseMatch(match);
        // Series score is authoritative in global_state for finished / live games.
        JSONObject g = match.optJSONObject("global_state");
        if (g != null) {
            int s1 = (int) num(g, "t1_score"), s2 = (int) num(g, "t2_score");
            if (s1 > 0 || s2 > 0) { m.s1 = s1; m.s2 = s2; }
            int st = (int) num(g, "status");
            if (st == 1) m.status = "live";
            else if (st == 2) m.status = "completed";
            if (m.s1 > m.s2) m.winner = 1;
            else if (m.s2 > m.s1) m.winner = 2;

            JSONArray bp = g.optJSONArray("bp_map_item");
            if (bp != null) {
                for (int i = 0; i < bp.length(); i++) {
                    JSONObject b = bp.optJSONObject(i);
                    if (b == null) continue;
                    Models.BanPick p = new Models.BanPick();
                    p.type = str(b, "bp_type");
                    p.map = str(b, "map_name");
                    p.side = str(b, "team_side");
                    out.bp.add(p);
                }
            }

            JSONObject mvp = g.optJSONObject("mvp_player_stats");
            if (mvp != null) {
                out.mvpName = str(mvp, "name");
                out.mvpRating = str(mvp, "rating");
            }

            readSeriesPlayers(out, g.optJSONArray("t1_player_stats"), 1);
            readSeriesPlayers(out, g.optJSONArray("t2_player_stats"), 2);

            // Per-map scores + half scores come from bouts_state, which is richer
            // than the bout_states inside the list payload.
            JSONArray bouts = match.optJSONArray("bouts_state");
            if (bouts != null) {
                m.maps.clear();
                for (int i = 0; i < bouts.length(); i++) {
                    JSONObject b = bouts.optJSONObject(i);
                    if (b == null) continue;
                    Models.MapScore ms = new Models.MapScore();
                    ms.name = str(b, "map_name");
                    ms.status = (int) num(b, "status");
                    ms.result = str(b, "result");
                    ms.round = (int) num(b, "curr_round_num");
                    ms.pick = mapPick(out.bp, ms.name);
                    JSONObject js1 = b.optJSONObject("t1_stats");
                    JSONObject js2 = b.optJSONObject("t2_stats");
                    ms.s1 = (int) num(js1, "quick_score");
                    ms.s2 = (int) num(js2, "quick_score");
                    if (js1 != null) {
                        int fh = (int) num(js1, "fh_score");
                        if (fh > 0) {
                            ms.hasHalf = true;
                            ms.fh1 = fh;
                            ms.fh2 = (int) num(js2, "fh_score");
                            ms.sh1 = (int) num(js1, "sh_score");
                            ms.sh2 = (int) num(js2, "sh_score");
                            int ot = (int) num(js1, "ot_score");
                            if (ot > 0) { ms.hasOt = true; ms.ot1 = ot; ms.ot2 = (int) num(js2, "ot_score"); }
                        }
                    }
                    // Per-map player stats: the only place to get map-by-map K-D.
                    readMapPlayers(ms.p1, b.optJSONArray("t1_pr_stats"), 1);
                    readMapPlayers(ms.p2, b.optJSONArray("t2_pr_stats"), 2);
                    m.maps.add(ms);
                }
            }
        }

        out.match = m;
        return out;
    }

    private static String mapPick(List<Models.BanPick> bp, String name) {
        for (Models.BanPick p : bp) {
            if (p.map.equals(name) && !"ban".equals(p.type)) {
                if ("pick".equals(p.type)) return p.side.equals("t1") ? "t1_pick" : "t2_pick";
                if ("left".equals(p.type)) return "left";
                return "";
            }
        }
        return "";
    }

    private static void readSeriesPlayers(Models.MatchDetail out, JSONArray arr, int side) {
        if (arr == null) return;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            Models.Player p = new Models.Player();
            p.id = str(o, "id");
            p.name = str(o, "name");
            p.kill = str(o, "kill");
            p.death = str(o, "death");
            p.assist = str(o, "assist");
            p.rating = str(o, "rating");
            p.adr = str(o, "adr");
            p.kast = str(o, "kast");
            p.side = side;
            out.series.add(p);
        }
        if (out.mvpName.length() > 0) {
            for (Models.Player p : out.series) if (p.name.equals(out.mvpName)) p.mvp = true;
        }
    }

    /** Per-map player rows. Same keys as the series table, plus headshot rate. */
    private static void readMapPlayers(List<Models.Player> dst, JSONArray arr, int side) {
        if (arr == null) return;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            Models.Player p = new Models.Player();
            p.id = str(o, "id");
            p.name = str(o, "name");
            p.kill = str(o, "kill");
            p.death = str(o, "death");
            p.assist = str(o, "assist");
            p.rating = str(o, "rating");
            p.adr = str(o, "adr");
            p.kast = str(o, "kast");
            p.side = side;
            dst.add(p);
        }
    }

    // ------------------------------------------------------------------ analysis
    /**
     * Pre-match comparison. This is the ONLY endpoint with content for a match
     * that has not started yet: /data returns an empty shell for those (8 KB vs
     * 95 KB), so the upcoming detail page is built from this alone.
     */
    static Models.Analysis analysis(String mcId) throws Exception {
        return parseAnalysis(data(DATA + "/v1/api/csgo/matches/" + mcId + "/analysis_v1", null));
    }

    /** Extracted from analysis() so the parsing can be exercised offline. */
    static Models.Analysis parseAnalysis(JSONObject d) throws Exception {
        JSONObject r = d.optJSONObject("result");
        if (r == null) throw new IOException("没有赛前数据");
        Models.Analysis a = new Models.Analysis();

        JSONObject cmp = r.optJSONObject("comparison");
        if (cmp != null) {
            JSONObject s1 = cmp.optJSONObject("t1_stats");
            JSONObject s2 = cmp.optJSONObject("t2_stats");
            a.winRate1 = pct(str(s1, "win_rate"));
            a.winRate2 = pct(str(s2, "win_rate"));
            a.kd1 = str(s1, "kd");
            a.kd2 = str(s2, "kd");
            a.rating1 = str(s1, "rating");
            a.rating2 = str(s2, "rating");
            a.fk1 = pct(str(s1, "f_rate"));
            a.fk2 = pct(str(s2, "f_rate"));

            readPrePlayers(a.players1, cmp.optJSONArray("t1_player_stats"));
            readPrePlayers(a.players2, cmp.optJSONArray("t2_player_stats"));

            JSONArray maps = cmp.optJSONArray("team_map_stats");
            if (maps != null) {
                for (int i = 0; i < maps.length(); i++) {
                    JSONObject o = maps.optJSONObject(i);
                    if (o == null) continue;
                    Models.MapRate mr = new Models.MapRate();
                    mr.name = str(o, "name");
                    String zh = str(o, "name_zh");
                    if (zh.length() > 0) mr.name = zh;
                    mr.r1 = intOr(str(o, "t1_rate"), -1);
                    mr.r2 = intOr(str(o, "t2_rate"), -1);
                    mr.bp = str(o, "bp_type");
                    if (mr.r1 < 0 && mr.r2 < 0) continue;
                    a.maps.add(mr);
                }
            }
        }

        // head to head
        JSONObject vs = r.optJSONObject("rec_vs_matches");
        a.h2hWin1 = pct(str(vs, "t1_win_rate"));
        a.h2hWin2 = pct(str(vs, "t2_win_rate"));
        JSONArray vsm = vs == null ? null : vs.optJSONArray("matches");
        if (vsm != null) {
            for (int i = 0; i < vsm.length() && a.h2h.size() < 6; i++) {
                JSONObject it = vsm.optJSONObject(i);
                if (it == null) continue;
                JSONObject m = it.optJSONObject("match");
                JSONObject tt = it.optJSONObject("tt_info");
                if (m == null) continue;
                Models.PastMatch pm = new Models.PastMatch();
                pm.date = monthDay(num(m, "ts") * 1000L);
                pm.score = str(m, "t1_score") + ":" + str(m, "t2_score");
                pm.event = shortName(str(tt, "disp_name"));
                pm.winner = "t1".equals(str(m, "result")) ? 1
                        : ("t2".equals(str(m, "result")) ? 2 : 0);
                a.h2h.add(pm);
            }
        }

        readRecent(a.recent1, r.optJSONObject("t1_rec_matches"));
        readRecent(a.recent2, r.optJSONObject("t2_rec_matches"));
        return a;
    }

    private static void readPrePlayers(List<Models.Player> out, JSONArray arr) {
        if (arr == null) return;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject o = arr.optJSONObject(i);
            if (o == null) continue;
            Models.Player p = new Models.Player();
            p.id = str(o, "id");
            p.name = str(o, "name");
            // The comparison payload capitalises this key, unlike /data.
            p.rating = str(o, "Rating");
            if (p.rating.length() == 0) p.rating = str(o, "rating");
            p.kdRate = str(o, "kd");
            p.adr = str(o, "adr");
            p.kast = str(o, "kast");
            p.country = str(o, "country_name");
            out.add(p);
        }
    }

    private static void readRecent(List<Models.PastMatch> out, JSONObject grp) {
        JSONArray groups = grp == null ? null : grp.optJSONArray("matches");
        if (groups == null) return;
        for (int i = 0; i < groups.length() && out.size() < 10; i++) {
            JSONObject g = groups.optJSONObject(i);
            if (g == null) continue;
            JSONObject tt = g.optJSONObject("tt_info");
            String event = shortName(str(tt, "disp_name"));
            JSONArray ms = g.optJSONArray("matches");
            if (ms == null) continue;
            for (int j = 0; j < ms.length() && out.size() < 10; j++) {
                JSONObject m = ms.optJSONObject(j);
                if (m == null) continue;
                JSONObject op = m.optJSONObject("opponent_info");
                Models.PastMatch pm = new Models.PastMatch();
                pm.date = monthDay(num(m, "ts") * 1000L);
                pm.t1 = str(op, "disp_name");
                int hs = intOr(str(m, "home_score"), 0);
                int os = intOr(str(m, "opponent_score"), 0);
                pm.score = hs + ":" + os;
                pm.winner = hs > os ? 1 : (os > hs ? 2 : 0);
                pm.event = event;
                out.add(pm);
            }
        }
    }

    /** "43" -> "43%" (the comparison payload sends bare numbers). */
    private static String pct(String s) {
        if (s == null || s.length() == 0) return "";
        return s.endsWith("%") ? s : s + "%";
    }

    private static int intOr(String s, int def) {
        if (s == null) return def;
        s = s.trim();
        if (s.length() == 0 || "--".equals(s)) return def;
        try { return Integer.parseInt(s); } catch (Exception e) { return def; }
    }

    /** 1778389200 s -> "5.10". */
    private static String monthDay(long ts) {
        if (ts <= 0) return "";
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(ts);
        return (c.get(Calendar.MONTH) + 1) + "." + c.get(Calendar.DAY_OF_MONTH);
    }

    /** Long tournament names are cut for the narrow watch screen. */
    private static String shortName(String s) {
        if (s == null) return "";
        return s.length() <= 16 ? s : s.substring(0, 15) + "…";
    }

    // ------------------------------------------------------------------ events

    static List<Models.Tournament> tournaments(String cursor, String token) throws Exception {
        String body = "{\"tournaments_options\":{\"cursor\":\"" + cursor + "\",\"page_token\":\"" + token
                + "\",\"time_type\":null,\"time_value\":null,\"grade\":[],\"tt_series\":[],"
                + "\"tt_bonus\":[],\"team_id\":\"\",\"player_id\":\"\"}}";
        return parseTournaments(data(APP + "/api/csgo/tournament/csgo_event_list_v1", body));
    }

    /** Extracted from tournaments() so the parsing can be exercised offline. */
    static List<Models.Tournament> parseTournaments(JSONObject d) {
        JSONArray a = d.optJSONArray("items");
        List<Models.Tournament> out = new ArrayList<>();
        if (a == null) return out;
        for (int i = 0; i < a.length(); i++) {
            JSONObject it = a.optJSONObject(i);
            if (it == null) continue;
            JSONObject b = it.optJSONObject("basic_info");
            if (b == null) continue;
            Models.Tournament t = new Models.Tournament();
            t.id = str(b, "id");
            t.token = str(it, "page_token");
            t.name = str(b, "disp_name");
            t.tier = gradeLetter(str(b, "grade"));
            t.tierLabel = str(b, "grade_label");
            t.prize = str(b, "bonus");
            t.location = str(b, "city_name");
            t.status = str(b, "status");
            t.start = parseTime(str(b, "start_time"));
            t.end = parseTime(str(b, "end_time"));
            t.dateText = cnRange(t.start, t.end);
            t.dateShort = cnRangeShort(t.start, t.end);
            JSONObject win = it.optJSONObject("win_team");
            t.winner = str(win, "name");
            JSONArray teams = it.optJSONArray("teams");
            if (teams != null) {
                for (int j = 0; j < teams.length(); j++) {
                    JSONObject tm = teams.optJSONObject(j);
                    if (tm != null) {
                        t.teamNames.add(str(tm, "name"));
                        t.teamIds.add(str(tm, "id"));
                    }
                }
                t.teamCount = teams.length();
            }
            out.add(t);
        }
        Collections.sort(out, new Comparator<Models.Tournament>() {
            @Override public int compare(Models.Tournament a, Models.Tournament b) {
                boolean al = a.ongoing(), bl = b.ongoing();
                if (al != bl) return al ? -1 : 1;
                boolean au = a.upcoming(), bu = b.upcoming();
                if (au != bu) return au ? -1 : 1;
                if (au) return Long.compare(a.start, b.start);
                if (a.ongoing()) return Long.compare(a.start, b.start);
                return Long.compare(b.start, a.start);
            }
        });
        return out;
    }

    /** Fills the parts of a tournament that only the introduction endpoint knows. */
    static void eventDetail(Models.Tournament t) throws Exception {        JSONObject d = data(DATA + "/v1/api/csgo/tournaments/" + t.id + "/introduction", null);
        JSONObject b = d.optJSONObject("basic");
        if (b != null) {
            String zh = str(b, "name_zh");
            if (zh.length() > 0) t.name = zh;
            t.character = str(b, "character");
            String bonus = str(b, "bonus");
            if (bonus.length() > 0) t.prize = bonus;
            String city = str(b, "city_name");
            if (city.length() > 0) t.location = city;
        }
        JSONArray ranks = d.optJSONArray("team_rank");
        t.prizeRows.clear();
        if (ranks != null) {
            for (int i = 0; i < ranks.length() && t.prizeRows.size() < 8; i++) {
                JSONObject r = ranks.optJSONObject(i);
                if (r == null) continue;
                String rank = str(r, "rank");
                String bonus = str(r, "bonus");
                if (bonus.length() == 0) continue;
                JSONObject team = r.optJSONObject("team");
                String name = str(team, "name_zh");
                if (name.length() == 0) name = str(team, "name_en");
                if (name.length() == 0) name = str(team, "abbr");
                t.prizeRows.add(new String[] { rank, name, bonus });
            }
        }
        JSONArray teams = d.optJSONArray("teams");
        if (teams != null) {
            t.teamNames.clear();
            t.teamIds.clear();
            for (int i = 0; i < teams.length(); i++) {
                JSONObject tm = teams.optJSONObject(i);
                if (tm == null) continue;
                t.teamNames.add(str(tm, "name"));
                t.teamIds.add(str(tm, "id"));
            }
            t.teamCount = t.teamNames.size();
        }
        JSONArray maps = d.optJSONArray("maps");
        t.maps.clear();
        if (maps != null) {
            for (int i = 0; i < maps.length(); i++) {
                JSONObject mp = maps.optJSONObject(i);
                if (mp == null) continue;
                String nm = str(mp, "name");
                if (nm.length() > 0) t.maps.add(nm);
            }
        }
        t.detailLoaded = true;
        try {
            fillStages(t, data(DATA + "/v1/api/csgo/tournaments/" + t.id + "/stages", null));
        } catch (Exception ignored) {
            // 赛段是补充信息，失败不影响简介
        }
    }

    /** 赛段（小组赛/淘汰赛）与赛制，取自 stages 接口的 stageInfo。 */
    static void fillStages(Models.Tournament t, JSONObject d) {
        t.stages.clear();
        JSONArray arr = d.optJSONArray("data");
        if (arr == null) return;
        for (int i = 0; i < arr.length() && t.stages.size() < 6; i++) {
            JSONObject s = arr.optJSONObject(i);
            if (s == null) continue;
            JSONObject si = s.optJSONObject("stageInfo");
            if (si == null) continue;
            String name = str(si, "name");
            String desc = str(si, "desc").replace("\r", "").trim();
            if (name.length() == 0 && desc.length() == 0) continue;
            t.stages.add(new String[] { name, desc });
        }
    }

    /**
     * 赛事维度统计：队伍与地图两张表，都是 POST 且内层键必须是 {@code tt_ids} 数组。
     * 体积约 17KB / 4KB，很轻。
     */
    static void eventStats(Models.Tournament t) throws Exception {
        JSONObject td = data(DATA + "/v1/api/csgo/tournaments/team_data",
                "{\"team_options\":{\"tt_ids\":[\"" + t.id + "\"],\"page\":1}}");
        t.teamStats.clear();
        JSONArray ta = td.optJSONArray("items");
        if (ta != null) {
            for (int i = 0; i < ta.length() && t.teamStats.size() < 16; i++) {
                JSONObject o = ta.optJSONObject(i);
                if (o == null) continue;
                JSONObject f = o.optJSONObject("field_values");
                String nm = str(f, "team_name");
                if (nm.length() == 0) nm = str(o, "team_name");
                if (nm.length() == 0) continue;
                t.teamStats.add(new String[] { nm, str(f, "match_win_rate"),
                        str(f, "kd"), str(f, "rating") });
            }
        }
        try {
            JSONObject md = data(DATA + "/v1/api/csgo/tournaments/map_data",
                    "{\"map_options\":{\"tt_ids\":[\"" + t.id + "\"],\"page\":1}}");
            t.mapStats.clear();
            JSONArray ma = md.optJSONArray("items");
            if (ma != null) {
                for (int i = 0; i < ma.length() && t.mapStats.size() < 9; i++) {
                    JSONObject o = ma.optJSONObject(i);
                    if (o == null) continue;
                    JSONObject f = o.optJSONObject("field_values");
                    String nm = str(o, "map_name");
                    if (nm.length() == 0) continue;
                    t.mapStats.add(new String[] { nm, str(f, "pick_rate"),
                            str(f, "ct_win_rate"), str(f, "t_win_rate") });
                }
            }
        } catch (Exception ignored) {
            // 地图统计是补充信息
        }
        t.statsLoaded = true;
    }

    /**
     * 赛事赛程：该赛事下的比赛列表（按时间升序）。
     * 走 `/tournaments/match_list?tt_ids=`，每页 20 场，体积很小。
     */
    static void eventMatches(Models.Tournament t) throws Exception {
        t.matches.clear();
        for (int page = 1; page <= 3; page++) {
            JSONObject d = data(DATA + "/v1/api/csgo/tournaments/match_list?tt_ids="
                    + t.id + "&page=" + page + "&limit=20", null);
            JSONArray ms = d.optJSONArray("matches");
            if (ms == null || ms.length() == 0) break;
            for (int i = 0; i < ms.length(); i++) {
                JSONObject o = ms.optJSONObject(i);
                if (o == null) continue;
                t.matches.add(parseMatch(o));
            }
            if (ms.length() < 20) break;
        }
        Collections.sort(t.matches, new Comparator<Models.Match>() {
            @Override public int compare(Models.Match a, Models.Match b) {
                return Long.compare(a.start, b.start);
            }
        });
        t.matchesLoaded = true;
    }

    // ------------------------------------------------------------------ team page

    /**
     * Team page: roster, HLTV/VRS position, lifetime win rate and recent results.
     * The overview and matches endpoints are two calls, both keyless.
     */
    static Models.TeamDetail team(final String teamId) throws Exception {
        Models.TeamDetail t = parseTeamOverview(
                data(DATA + "/v1/api/csgo/teams/" + teamId + "/overview?time_type=1", null));
        t.id = teamId;
        try {
            fillTeamRecent(t, data(DATA + "/v1/api/csgo/team/matches_v1/" + teamId
                    + "?page=1&limit=10&status=past", null));
        } catch (Exception ignored) {
            // A brand-new team has no past matches; the page still shows the roster.
        }
        try {
            fillTeamMaps(t, data(DATA + "/v1/api/csgo/mfilter/team/data/map/all",
                    teamMapBody(teamId)));
        } catch (Exception ignored) {
            // Map stats are optional; the roster and record still show.
        }
        t.fetchedAt = System.currentTimeMillis();
        return t;
    }

    /** Body for §6.9 team map overview — last three months, whole map pool. */
    static String teamMapBody(String teamId) {
        long now = System.currentTimeMillis();
        return "{\"team_options\":{\"time_value\":\"" + cnStamp(now - 92L * 24 * 3600 * 1000L)
                + " 00:00:00_" + cnStamp(now) + " 23:59:59\",\"team_id\":\"" + teamId
                + "\",\"time_type\":\"recent\",\"tt_series\":[],\"tt_ids\":[],\"maps\":[],"
                + "\"grade\":[],\"page\":1},\"sort_key\":\"\"}";
    }

    /**
     * Merges the three blocks of §6.9 by map name — their row order differs, so
     * zipping by index would attach Mirage stats to Nuke.
     */
    static void fillTeamMaps(Models.TeamDetail t, JSONObject d) {
        JSONArray rate = d.optJSONArray("win_rate_data");
        JSONArray win = d.optJSONArray("win_data");
        if (rate == null && win == null) return;
        java.util.LinkedHashMap<String, String[]> byName = new java.util.LinkedHashMap<>();
        if (rate != null) {
            for (int i = 0; i < rate.length(); i++) {
                JSONObject o = rate.optJSONObject(i);
                if (o == null) continue;
                String nm = str(o, "map_name");
                if (nm.length() == 0) continue;
                byName.put(nm, new String[] { nm, str(o, "map_win_rate"),
                        str(o, "ct_win_rate"), str(o, "t_win_rate"), "", "" });
            }
        }
        if (win != null) {
            for (int i = 0; i < win.length(); i++) {
                JSONObject o = win.optJSONObject(i);
                if (o == null) continue;
                String nm = str(o, "map_name");
                if (nm.length() == 0) continue;
                String[] row = byName.get(nm);
                if (row == null) {
                    row = new String[] { nm, "", "", "", "", "" };
                    byName.put(nm, row);
                }
                row[4] = str(o, "pistol_round_win_rate");
                row[5] = str(o, "first_kill_win_rate");
            }
        }
        t.maps.addAll(byName.values());
    }

    /** Extracted from team() so the parsing can be exercised offline. */
    static Models.TeamDetail parseTeamOverview(JSONObject d) {
        Models.TeamDetail t = new Models.TeamDetail();
        JSONObject ti = d.optJSONObject("team_info");
        JSONObject ov = d.optJSONObject("overview");
        if (ti != null) {
            t.id = str(ti, "id");
            t.name = str(ti, "disp_name");
            t.logo = str(ti, "logo");
            t.country = str(ti, "country_name");
            t.region = str(ti, "region_name");
            t.rank = str(ti, "rank");
            t.vrank = str(ti, "v_club_rank");
            t.points = str(ti, "points");
            t.bonus = str(ti, "bonus");
            t.coach = str(ti, "coach");
            t.ageAvg = str(ti, "average_player_age");
        }
        if (ov != null) {
            t.wins = str(ov, "wins");
            t.losses = str(ov, "losses");
            t.draws = str(ov, "draws");
            t.winRate = str(ov, "win_rate");
            t.kdRatio = str(ov, "kd_ratio");
            t.mapCount = str(ov, "map_count");
            t.kills = str(ov, "kill");
            t.deaths = str(ov, "death");
            JSONArray ps = ov.optJSONArray("players");
            if (ps != null) {
                for (int i = 0; i < ps.length(); i++) {
                    JSONObject o = ps.optJSONObject(i);
                    if (o == null) continue;
                    Models.Player p = new Models.Player();
                    p.id = str(o, "id");
                    p.name = str(o, "name");
                    p.position = str(o, "position");
                    if (p.position.length() == 0) {
                        JSONArray pos = o.optJSONArray("positions");
                        if (pos != null && pos.length() > 0) p.position = pos.optString(0, "");
                    }
                    p.side = 1;
                    t.players.add(p);
                }
            }
            // Milestones double as the honour list ("冠军 / 强势带飞 …").
            JSONArray ms = ov.optJSONArray("milestones");
            if (ms != null) {
                for (int i = 0; i < ms.length() && t.honors.size() < 8; i++) {
                    JSONObject o = ms.optJSONObject(i);
                    if (o == null) continue;
                    String detail = str(o, "detail");
                    if (detail.length() == 0) detail = str(o, "honor_text");
                    if (detail.length() == 0) continue;
                    t.honors.add(new String[] { str(o, "achieve_time"), str(o, "dimension_text"), detail });
                }
            }
        }
        return t;
    }

    /** Recent results from matches_v1; stored in {@code t.recent}. */
    static void fillTeamRecent(Models.TeamDetail t, JSONObject d) {
        JSONObject items = d.optJSONObject("items");
        JSONArray ms = items == null ? null : items.optJSONArray("matches");
        if (ms == null) return;
        for (int i = 0; i < ms.length() && t.recent.size() < 10; i++) {
            JSONObject o = ms.optJSONObject(i);
            if (o == null) continue;
            JSONObject mc = o.optJSONObject("mc_info");
            JSONObject tt = o.optJSONObject("tt_info");
            if (mc == null) continue;
            JSONObject home = mc.optJSONObject("home_info");
            JSONObject opp = mc.optJSONObject("opponent_info");
            Models.TeamMatch tm = new Models.TeamMatch();
            tm.id = str(mc, "id");
            tm.date = monthDay(num(mc, "ts") * 1000L);
            tm.t1 = str(home, "disp_name");
            tm.t2 = str(opp, "disp_name");
            tm.score = str(mc, "home_score") + ":" + str(mc, "opponent_score");
            tm.event = shortName(str(tt, "disp_name"));
            tm.stage = str(mc, "tt_stage_desc");
            String res = str(mc, "result");
            tm.winner = "home_win".equals(res) ? 1 : ("opponent_win".equals(res) ? 2 : 0);
            t.recent.add(tm);
        }
    }

    // ------------------------------------------------------------------ player page

    static Models.PlayerDetail player(String playerId) throws Exception {
        Models.PlayerDetail p = parsePlayer(data(DATA + "/v1/api/csgo/players/" + playerId, null));
        p.id = playerId;
        try {
            fillPlayerRecent(p, data(DATA + "/v1/api/csgo/mfilter/player/match/list",
                    playerRecentBody(playerId)));
        } catch (Exception ignored) {
            // Players without a match history still get their stats page.
        }
        p.fetchedAt = System.currentTimeMillis();
        return p;
    }

    /** Body for §7.9 player match history: last three months, page 1 (10 rows). */
    static String playerRecentBody(String playerId) {
        long now = System.currentTimeMillis();
        String to = cnStamp(now);
        String from = cnStamp(now - 92L * 24 * 3600 * 1000L);
        return "{\"player_options\":{\"player_id\":\"" + playerId + "\","
                + "\"time_type\":\"recent\",\"time_value\":\"" + from + " 00:00:00_"
                + to + " 23:59:59\","
                + "\"tt_ids\":[],\"maps\":[],\"grade\":[],\"page\":1}}";
    }

    private static String cnStamp(long ts) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(ts);
        return String.format("%04d-%02d-%02d", c.get(Calendar.YEAR),
                c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH));
    }

    static void fillPlayerRecent(Models.PlayerDetail p, JSONObject d) {
        JSONObject items = d.optJSONObject("items");
        JSONArray ms = items == null ? null : items.optJSONArray("matches");
        if (ms == null) return;
        for (int i = 0; i < ms.length() && p.recent.size() < 10; i++) {
            JSONObject o = ms.optJSONObject(i);
            if (o == null) continue;
            JSONObject mc = o.optJSONObject("mc_info");
            JSONObject tt = o.optJSONObject("tt_info");
            if (mc == null) continue;
            JSONObject home = mc.optJSONObject("home_info");
            JSONObject opp = mc.optJSONObject("opponent_info");
            Models.TeamMatch tm = new Models.TeamMatch();
            tm.id = str(mc, "id");
            tm.date = monthDay(num(mc, "ts") * 1000L);
            tm.t1 = str(home, "disp_name");
            tm.t2 = str(opp, "disp_name");
            tm.score = str(mc, "home_score") + ":" + str(mc, "opponent_score");
            tm.event = shortName(str(tt, "disp_name"));
            tm.stage = str(mc, "tt_stage_desc");
            String res = str(mc, "result");
            tm.winner = "home_win".equals(res) ? 1 : ("opponent_win".equals(res) ? 2 : 0);
            p.recent.add(tm);
        }
    }

    /** Extracted from player() so the parsing can be exercised offline. */
    static Models.PlayerDetail parsePlayer(JSONObject d) {
        Models.PlayerDetail p = new Models.PlayerDetail();
        JSONObject b = d.optJSONObject("basic_info");
        if (b != null) {
            p.id = str(b, "id");
            p.name = str(b, "name");
            p.team = str(b, "team_name");
            p.teamId = str(b, "team_id");
            p.country = str(b, "country_zh");
            if (p.country.length() == 0) p.country = str(b, "country_en");
            p.birthday = str(b, "birthday");
            p.top20 = str(b, "top20_num");
            p.bonus = str(b, "bonus");
            JSONArray pos = b.optJSONArray("positions");
            p.position = str(b, "position");
            if (pos != null && pos.length() > 0) p.position = pos.optString(0, "");
        }
        JSONObject pd = d.optJSONObject("player_data");
        if (pd != null) {
            p.rating = str(pd, "rating");
            p.kd = str(pd, "kd");
            p.adr = str(pd, "adr");
            p.kast = str(pd, "kast");
            p.impact = str(pd, "impact");
            p.dpr = str(pd, "dpr");
            p.kpr = str(pd, "kpr");
            p.headshot = str(pd, "head_shot");
            p.kill = str(pd, "kill");
            p.death = str(pd, "death");
            p.mapsPlayed = str(pd, "maps_played");
            p.roundsPlayed = str(pd, "rounds_played");
            JSONArray maps = pd.optJSONArray("maps");
            if (maps != null) {
                for (int i = 0; i < maps.length() && p.maps.size() < 10; i++) {
                    JSONObject o = maps.optJSONObject(i);
                    if (o == null) continue;
                    String nm = str(o, "name");
                    if (nm.length() == 0) continue;
                    p.maps.add(new String[] { nm, str(o, "rating"), str(o, "kd"), str(o, "use_num") });
                }
            }
            JSONArray mates = pd.optJSONArray("players");
            if (mates != null) p.teammateCount = String.valueOf(mates.length());

            // 武器偏好：类别（步枪/狙击/手枪…）+ 单枪械占比
            JSONArray cats = pd.optJSONArray("weapon_cate");
            if (cats != null) {
                for (int i = 0; i < cats.length() && p.weaponCate.size() < 4; i++) {
                    JSONObject o = cats.optJSONObject(i);
                    if (o == null) continue;
                    String nm = str(o, "weapon_cate");
                    if (nm.length() == 0) continue;
                    p.weaponCate.add(new String[] { nm, str(o, "rate"), str(o, "total_kills") });
                }
            }
            JSONArray ws = pd.optJSONArray("weapons");
            if (ws != null) {
                for (int i = 0; i < ws.length() && p.weapons.size() < 4; i++) {
                    JSONObject o = ws.optJSONObject(i);
                    if (o == null) continue;
                    String nm = str(o, "name");
                    if (nm.length() == 0) continue;
                    p.weapons.add(new String[] { nm, str(o, "rate") });
                }
            }
            // 残局 / 击杀回合分布
            JSONArray fp = pd.optJSONArray("final_phase_data");
            if (fp != null) {
                for (int i = 0; i < fp.length() && p.clutches.size() < 5; i++) {
                    JSONObject o = fp.optJSONObject(i);
                    if (o == null) continue;
                    String nm = str(o, "data_type");
                    if (nm.length() == 0) continue;
                    p.clutches.add(new String[] { nm, str(o, "num") });
                }
            }
            JSONArray rd = pd.optJSONArray("round_data");
            if (rd != null) {
                for (int i = 0; i < rd.length() && p.killTypes.size() < 6; i++) {
                    JSONObject o = rd.optJSONObject(i);
                    if (o == null) continue;
                    String nm = str(o, "kill_type");
                    if (nm.length() == 0) continue;
                    p.killTypes.add(new String[] { nm, str(o, "num") });
                }
            }
        }
        JSONObject pf = d.optJSONObject("player_profile");
        JSONArray hh = pf == null ? null : pf.optJSONArray("history_honor");
        if (hh != null) {
            for (int i = 0; i < hh.length() && p.honors.size() < 10; i++) {
                JSONObject o = hh.optJSONObject(i);
                if (o == null) continue;
                JSONObject tt = o.optJSONObject("history_tt");
                String ev = str(tt, "name");
                if (ev.length() == 0) continue;
                String date = str(tt, "start_time");
                if (date.length() > 10) date = date.substring(0, 10);
                p.honors.add(new String[] { date, shortName(ev), str(o, "rank_desc") });
            }
        }
        p.fetchedAt = System.currentTimeMillis();
        return p;
    }

    // ------------------------------------------------------------------ ranking

    /**
     * 选手榜（POST /mfilter/player/list）。{@code dimension} 与 {@code sort_key}
     * 必须成对：top+rating 或 earning+total_earnings，否则报「参数排序错误」。
     * 返回体里没有名次字段，名次由页码推算。
     */
    static List<Models.RankRow> playerRanking(String dimension, String sortKey, int page) throws Exception {
        String body = "{\"dimension\":\"" + dimension + "\",\"sort_value\":\"desc\",\"sort_key\":\""
                + sortKey + "\",\"player_options\":{\"tt_ids\":[],\"time_value\":\"\",\"grade\":[],"
                + "\"player_id\":\"\",\"time_type\":\"\",\"tt_series\":[],\"maps\":[],\"page\":" + page + "}}";
        return parsePlayerRanking(data(DATA + "/v1/api/csgo/mfilter/player/list", body),
                "total_earnings".equals(sortKey), page);
    }

    static List<Models.RankRow> parsePlayerRanking(JSONObject d, boolean earning, int page) {
        JSONArray a = d.optJSONArray("items");
        List<Models.RankRow> out = new ArrayList<>();
        if (a == null) return out;
        int base = (page - 1) * 20;
        for (int i = 0; i < a.length(); i++) {
            JSONObject it = a.optJSONObject(i);
            if (it == null) continue;
            JSONObject f = it.optJSONObject("field_values");
            Models.RankRow r = new Models.RankRow();
            r.id = str(it, "player_id");
            r.name = str(it, "player_name");
            r.rank = String.valueOf(base + i + 1);
            r.point = earning ? str(f, "total_earnings") : str(f, "rating");
            String tn = str(it, "team_name");
            r.region = tn;
            out.add(r);
        }
        return out;
    }

    static List<Models.RankRow> ranking(String type, int page) throws Exception {
        String body = "{\"sort_value\":\"desc\",\"rank_type\":\"" + type + "\",\"sort_key\":\"" + type
                + "\",\"region\":\"\",\"team_options\":{\"tt_ids\":[],\"time_value\":\"\",\"grade\":[],"
                + "\"team_id\":\"\",\"time_type\":\"\",\"tt_series\":[],\"maps\":[],\"page\":" + page + "}}";
        return parseRanking(data(DATA + "/v1/api/csgo/new/rank/team_list", body), "valve_rank".equals(type));
    }

    /**
     * Extracted from ranking() so the parsing can be exercised offline.
     *
     * The payload carries BOTH rankings for every team: `rank`/`point` is the HLTV
     * world ranking and `valve_rank`/`valve_point` is Valve's VRS. The server sorts
     * by whichever `sort_key` was sent, so the displayed number must come from the
     * matching pair, otherwise the VRS list shows HLTV numbers out of order.
     */
    static List<Models.RankRow> parseRanking(JSONObject d, boolean vrs) {
        JSONArray a = d.optJSONArray("items");
        List<Models.RankRow> out = new ArrayList<>();
        if (a == null) return out;
        for (int i = 0; i < a.length(); i++) {
            JSONObject it = a.optJSONObject(i);
            if (it == null) continue;
            JSONObject f = it.optJSONObject("field_values");
            Models.RankRow r = new Models.RankRow();
            r.id = str(it, "team_id");
            r.name = str(it, "team_name");
            r.rank = vrs ? str(f, "valve_rank") : str(f, "rank");
            r.point = vrs ? str(f, "valve_point") : str(f, "point");
            if (r.rank.length() == 0) r.rank = str(f, "rank");
            if (r.point.length() == 0) r.point = str(f, "point");
            r.region = str(f, "region_name");
            String ch = str(f, "rank_diff");
            r.change = "-".equals(ch) ? "" : ch;
            out.add(r);
        }
        return out;
    }

    // ------------------------------------------------------------------ dates

    /** "2026-10-24 00:00:00" -> epoch millis, 0 on failure. */
    static long parseTime(String s) {
        if (s == null || s.length() < 10) return 0;
        try {
            int y = Integer.parseInt(s.substring(0, 4));
            int mo = Integer.parseInt(s.substring(5, 7));
            int d = Integer.parseInt(s.substring(8, 10));
            Calendar c = Calendar.getInstance();
            c.clear();
            c.set(y, mo - 1, d, 0, 0, 0);
            return c.getTimeInMillis();
        } catch (Exception e) {
            return 0;
        }
    }

    private static final String[] MONTHS = {
            "Jan", "Feb", "Mar", "Apr", "May", "Jun",
            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    };

    /** Compact list label: "10.24–31" / "10.24–11.2", "待定" when unknown. */
    static String cnRangeShort(long start, long end) {
        if (start <= 0) return "待定";
        Calendar a = Calendar.getInstance();
        a.setTimeInMillis(start);
        String s = (a.get(Calendar.MONTH) + 1) + "." + a.get(Calendar.DAY_OF_MONTH);
        if (end <= 0) return s;
        Calendar b = Calendar.getInstance();
        b.setTimeInMillis(end);
        if (b.get(Calendar.YEAR) == a.get(Calendar.YEAR)
                && b.get(Calendar.MONTH) == a.get(Calendar.MONTH)) {
            if (b.get(Calendar.DAY_OF_MONTH) == a.get(Calendar.DAY_OF_MONTH)) return s;
            return s + "–" + b.get(Calendar.DAY_OF_MONTH);
        }
        return s + "–" + (b.get(Calendar.MONTH) + 1) + "." + b.get(Calendar.DAY_OF_MONTH);
    }

    /** "2026-10-24 00:00:00" + end -> "10月24–31日" / "10月24日–11月2日". */
    static String cnRange(long start, long end) {
        if (start <= 0) return "";
        Calendar a = Calendar.getInstance();
        a.setTimeInMillis(start);
        String s = (a.get(Calendar.MONTH) + 1) + "月" + a.get(Calendar.DAY_OF_MONTH) + "日";
        if (end <= 0) return s;
        Calendar b = Calendar.getInstance();
        b.setTimeInMillis(end);
        if (b.get(Calendar.YEAR) == a.get(Calendar.YEAR)
                && b.get(Calendar.MONTH) == a.get(Calendar.MONTH)
                && b.get(Calendar.DAY_OF_MONTH) == a.get(Calendar.DAY_OF_MONTH)) {
            return s;                                 // single-day event
        }
        if (b.get(Calendar.YEAR) == a.get(Calendar.YEAR)
                && b.get(Calendar.MONTH) == a.get(Calendar.MONTH)) {
            return s + "–" + b.get(Calendar.DAY_OF_MONTH) + "日";
        }
        return s + "–" + (b.get(Calendar.MONTH) + 1) + "月" + b.get(Calendar.DAY_OF_MONTH) + "日";
    }
}
