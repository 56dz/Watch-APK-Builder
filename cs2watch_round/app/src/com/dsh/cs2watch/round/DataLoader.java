package com.dsh.cs2watch.round;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Loads 5eplay data and pushes it into Store.
 *
 * One sync fills 今日 / 直播 / 赛果 together: the live, upcoming and finished
 * lists are cheap enough to fetch as a set. Detail data (veto, per-map player
 * stats) is fetched lazily when a card is opened.
 */
public final class DataLoader {

    private static final Handler H = new Handler(Looper.getMainLooper());
    private static final ExecutorService POOL = Executors.newFixedThreadPool(3);

    private static final long MATCH_TTL = 90_000L;
    private static final long EVENT_TTL = 20 * 60_000L;
    private static final long RANK_TTL = 30 * 60_000L;

    private static List<Models.Match> sLive = new ArrayList<>();
    private static List<Models.Match> sToday = new ArrayList<>();
    private static List<Models.Match> sFin = new ArrayList<>();
    private static long sMatchesAt;
    private static boolean sMatchesBusy;
    private static String sMatchesError;
    private static int sFinPage = 1;
    private static boolean sFinExhausted;

    private DataLoader() {}

    // ------------------------------------------------------------------ public

    public static void refreshIfNeeded(Context c, Store s, Store.Tab t) {
        Store.Page p = s.page(t);
        if (p.loading) return;
        if (p.loaded && !stale(t, p)) return;
        refresh(c, s, t, false);
    }

    private static boolean stale(Store.Tab t, Store.Page p) {
        long ttl;
        switch (t) {
            case EVENTS: ttl = EVENT_TTL; break;
            case RANK: ttl = RANK_TTL; break;
            default: ttl = MATCH_TTL; break;
        }
        return System.currentTimeMillis() - p.fetchedAt > ttl;
    }

    public static void refresh(Context c, final Store s, final Store.Tab t, boolean force) {
        switch (t) {
            case EVENTS: refreshEvents(c, s, force); break;
            case RANK: refreshRank(c, s, force); break;
            default: refreshMatches(c, s, force); break;
        }
    }

    // ------------------------------------------------------------------ matches

    private static void refreshMatches(final Context c, final Store s, boolean force) {
        long now = System.currentTimeMillis();
        boolean fresh = sMatchesAt > 0 && now - sMatchesAt < MATCH_TTL;
        if (fresh && !force) {
            fillMatchPages(s);
            s.notifyChanged();
            return;
        }
        if (sMatchesBusy) return;
        sMatchesBusy = true;
        for (Store.Tab t : new Store.Tab[] { Store.Tab.TODAY, Store.Tab.LIVE, Store.Tab.RESULTS }) {
            Store.Page p = s.page(t);
            p.loading = true;
            if (!p.loaded) p.error = null;
        }
        s.notifyChanged();

        final Context app = c.getApplicationContext();
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.Match> live = null, fin = null, today = null;
                String error = null;
                Fiveplay.drainStale();
                try {
                    live = Fiveplay.list(Fiveplay.LIVING, 1, 20);
                    fin = Fiveplay.list(Fiveplay.DONE, 1, 40);
                    today = loadTodayUpcoming();
                } catch (Exception e) {
                    error = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                final boolean offline = Fiveplay.drainStale();
                final List<Models.Match> fLive = live;
                final List<Models.Match> fFin = fin;
                final List<Models.Match> fToday = today;
                final String fErr = error;
                H.post(new Runnable() {
                    @Override public void run() {
                        sMatchesBusy = false;
                        boolean ok = false;
                        if (fLive != null && fFin != null && fToday != null) {
                            sLive = fLive;
                            sFin = new ArrayList<>(fFin);
                            sToday = fToday;
                            sFinPage = 1;
                            sFinExhausted = false;
                            sMatchesAt = System.currentTimeMillis();
                            sMatchesError = null;
                            ok = true;
                        } else {
                            sMatchesError = fErr == null ? "取不到数据" : fErr;
                        }
                        for (Store.Tab t : new Store.Tab[] { Store.Tab.TODAY, Store.Tab.LIVE, Store.Tab.RESULTS }) {
                            Store.Page p = s.page(t);
                            p.loading = false;
                            p.loaded = true;
                            p.fromCache = offline;
                            if (ok) { p.error = null; fillMatchPages(s); }
                            else if (p.matches.isEmpty()) p.error = sMatchesError;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    /**
     * The upcoming endpoint is ordered newest-first and starts in the far future,
     * so "today" sits somewhere in the middle of the stream. Walk pages (desc) until
     * the stream has passed midnight, keeping everything that falls on today.
     */
    private static List<Models.Match> loadTodayUpcoming() throws Exception {
        long now = System.currentTimeMillis();
        long dayStart = startOfDay(now);
        long dayEnd = dayStart + 24 * 3600_000L;
        List<Models.Match> today = new ArrayList<>();
        List<Models.Match> soonest = new ArrayList<>();
        for (int page = 1; page <= 10; page++) {
            List<Models.Match> pg = Fiveplay.list(Fiveplay.UP, page, 50);
            if (pg.isEmpty()) break;
            for (Models.Match m : pg) {
                if (m.start >= dayStart && m.start < dayEnd) today.add(m);
            }
            soonest.addAll(pg);
            long last = pg.get(pg.size() - 1).start;
            if (last > 0 && last < dayStart) break;
        }
        if (today.isEmpty() && !soonest.isEmpty()) {
            // Nothing on today's card: fall back to the next few scheduled matches.
            Collections.sort(soonest, new Comparator<Models.Match>() {
                @Override public int compare(Models.Match a, Models.Match b) {
                    return Long.compare(a.start, b.start);
                }
            });
            int n = 0;
            for (Models.Match m : soonest) {
                if (m.start >= now && n < 12) { today.add(m); n++; }
            }
        }
        return today;
    }

    private static void fillMatchPages(Store s) {
        long now = System.currentTimeMillis();
        long ts = sMatchesAt;

        // 直播
        Store.Page live = s.page(Store.Tab.LIVE);
        live.loaded = true;
        live.fetchedAt = ts;
        live.matches.clear();
        live.matches.addAll(sLive);

        // 今日 = 直播 + 今天还没开赛的；已结束的只进赛果。
        List<Models.Match> today = new ArrayList<>(sLive);
        for (Models.Match m : sToday) if (!m.done() && !containsId(today, m.id)) today.add(m);
        sortForToday(today);
        Store.Page tp = s.page(Store.Tab.TODAY);
        tp.loaded = true;
        tp.fetchedAt = ts;
        tp.matches.clear();
        tp.matches.addAll(today);

        // 赛果
        List<Models.Match> fin = new ArrayList<>(sFin);
        Collections.sort(fin, new Comparator<Models.Match>() {
            @Override public int compare(Models.Match a, Models.Match b) {
                return Long.compare(b.start, a.start);
            }
        });
        Store.Page rp = s.page(Store.Tab.RESULTS);
        rp.loaded = true;
        rp.fetchedAt = ts;
        rp.matches.clear();
        rp.matches.addAll(fin);
        // 40 is the first page size, so a full page means older results exist.
        rp.hasMore = !sFinExhausted && fin.size() >= 40 && fin.size() < 200;
    }

    private static boolean containsId(List<Models.Match> l, String id) {
        for (Models.Match m : l) if (m.id.equals(id)) return true;
        return false;
    }

    private static void sortForToday(List<Models.Match> l) {
        Collections.sort(l, new Comparator<Models.Match>() {
            @Override public int compare(Models.Match a, Models.Match b) {
                if (a.live() != b.live()) return a.live() ? -1 : 1;
                return Long.compare(a.start, b.start);
            }
        });
    }

    /** 赛果 page: append the next page of finished matches. */
    public static void loadMore(final Context c, final Store s, final Store.Tab t) {
        if (t != Store.Tab.RESULTS) {
            if (t == Store.Tab.EVENTS) loadMoreEvents(c, s);
            else if (t == Store.Tab.RANK) loadMoreRank(c, s);
            return;
        }
        final Store.Page p = s.page(t);
        if (p.loading || p.matches.size() >= 200) return;
        p.loading = true;
        s.notifyChanged();
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.Match> more = null;
                try {
                    more = Fiveplay.list(Fiveplay.DONE, sFinPage + 1, 40);
                } catch (Exception ignored) {}
                final List<Models.Match> fm = more;
                H.post(new Runnable() {
                    @Override public void run() {
                        p.loading = false;
                        if (fm != null && !fm.isEmpty()) {
                            sFinPage++;
                            for (Models.Match m : fm) if (!containsId(sFin, m.id)) sFin.add(m);
                            fillMatchPages(s);
                        } else {
                            sFinExhausted = true;
                            fillMatchPages(s);
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------ detail

    private static final java.util.HashMap<String, Models.MatchDetail> DETAIL_CACHE =
            new java.util.HashMap<>();

    /** Fetches veto + per-map + player stats for one match. */
    public static void openMatchDetail(final Context c, final Store s, final Models.Match m) {
        Models.MatchDetail cached = DETAIL_CACHE.get(m.id);
        s.detail = m;
        s.detailEvent = null;
        s.detailTeam = null;
        s.detailPlayer = null;
        s.detailIsEvent = false;
        s.detailKind = Store.KIND_MATCH;
        s.detailId = m.id;
        s.detailError = null;
        if (cached != null) {
            s.detailData = cached;
            s.detailLoading = false;
            s.detailFetchedAt = System.currentTimeMillis();
            s.notifyChanged();
            return;
        }
        s.detailData = null;
        s.detailLoading = true;
        s.notifyChanged();
        POOL.execute(new Runnable() {
            @Override public void run() {
                Models.MatchDetail d = null;
                String err = null;
                try {
                    d = Fiveplay.detail(m.id);
                } catch (Exception e) {
                    err = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                // A match that has not started yet has an empty /data shell, so the
                // pre-match comparison is fetched instead (players, map win rates,
                // recent form, head to head).
                if (d == null || d.match == null || d.match.maps.isEmpty()
                        || "upcoming".equals(d.match.status)) {
                    try {
                        Models.Analysis a = Fiveplay.analysis(m.id);
                        if (d == null) {
                            d = new Models.MatchDetail();
                            d.match = m;
                            d.fetchedAt = System.currentTimeMillis();
                        }
                        d.pre = a;
                        d.preTried = true;
                    } catch (Exception e) {
                        if (d == null && err == null) {
                            err = e.getMessage() == null ? "网络异常" : e.getMessage();
                        }
                    }
                }
                final Models.MatchDetail fd = d;
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        if (s.detail != m) return;      // user already left
                        s.detailLoading = false;
                        if (fd != null) {
                            if (DETAIL_CACHE.size() > 12) DETAIL_CACHE.clear();
                            DETAIL_CACHE.put(m.id, fd);
                            s.detailData = fd;
                            s.detailFetchedAt = System.currentTimeMillis();
                            s.detailError = null;
                        } else {
                            s.detailError = fe;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    public static void openEventDetail(final Context c, final Store s, final Models.Tournament t) {
        s.detailEvent = t;
        s.detail = null;
        s.detailData = null;
        s.detailTeam = null;
        s.detailPlayer = null;
        s.detailIsEvent = true;
        s.detailKind = Store.KIND_EVENT;
        s.detailId = t.id;
        s.detailError = null;
        if (t.detailLoaded) {
            s.detailLoading = false;
            s.notifyChanged();
            return;
        }
        s.detailLoading = true;
        s.notifyChanged();
        POOL.execute(new Runnable() {
            @Override public void run() {
                String err = null;
                if (!t.detailLoaded) {
                    try {
                        Fiveplay.eventDetail(t);
                    } catch (Exception e) {
                        err = e.getMessage() == null ? "网络异常" : e.getMessage();
                    }
                }
                if (err == null && !t.matchesLoaded) {
                    try {
                        Fiveplay.eventMatches(t);
                    } catch (Exception ignored) {
                        // 赛程拉不到不算失败，简介照常显示
                    }
                }
                if (err == null && !t.statsLoaded) {
                    try {
                        Fiveplay.eventStats(t);
                    } catch (Exception ignored) {
                        // 赛事统计拉不到不算失败
                    }
                }
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        s.detailLoading = false;
                        if (s.detailEvent != t) return;
                        if (fe != null) s.detailError = fe;
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    public static void refreshDetail(Context c, Store s, boolean force) {
        if (s.detailIsEvent) {
            if (s.detailEvent != null) {
                s.detailEvent.detailLoaded = false;
                s.detailEvent.matchesLoaded = false;
                openEventDetail(c, s, s.detailEvent);
            }
        } else if (s.detailKind == Store.KIND_TEAM) {
            TEAM_CACHE.remove(s.detailId);
            openTeamDetail(c, s, s.detailId, null);
        } else if (s.detailKind == Store.KIND_PLAYER) {
            PLAYER_CACHE.remove(s.detailId);
            openPlayerDetail(c, s, s.detailId, null);
        } else if (s.detail != null) {
            DETAIL_CACHE.remove(s.detail.id);
            openMatchDetail(c, s, s.detail);
        }
    }

    // ------------------------------------------------------------------ team / player

    private static final java.util.HashMap<String, Models.TeamDetail> TEAM_CACHE =
            new java.util.HashMap<>();
    private static final java.util.HashMap<String, Models.PlayerDetail> PLAYER_CACHE =
            new java.util.HashMap<>();

    /**
     * Team page: roster, HLTV/VRS rank, lifetime record and recent results.
     *
     * @param knownName team name already on screen, so the header can show it
     *                  while the roster is still loading.
     */
    public static void openTeamDetail(final Context c, final Store s,
                                      final String teamId, String knownName) {
        if (teamId == null || teamId.length() == 0) return;
        Models.TeamDetail cached = TEAM_CACHE.get(teamId);
        s.detail = null;
        s.detailEvent = null;
        s.detailData = null;
        s.detailPlayer = null;
        s.detailIsEvent = false;
        s.detailKind = Store.KIND_TEAM;
        s.detailId = teamId;
        s.detailError = null;
        if (cached != null) {
            s.detailTeam = cached;
            s.detailLoading = false;
            s.detailFetchedAt = System.currentTimeMillis();
            s.notifyChanged();
            return;
        }
        Models.TeamDetail placeholder = new Models.TeamDetail();
        placeholder.id = teamId;
        placeholder.name = knownName == null ? "" : knownName;
        s.detailTeam = placeholder;
        s.detailLoading = true;
        s.notifyChanged();
        POOL.execute(new Runnable() {
            @Override public void run() {
                Models.TeamDetail t = null;
                String err = null;
                try {
                    t = Fiveplay.team(teamId);
                } catch (Exception e) {
                    err = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                final Models.TeamDetail ft = t;
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        if (s.detailKind != Store.KIND_TEAM || !teamId.equals(s.detailId)) return;
                        s.detailLoading = false;
                        if (ft != null && !ft.empty()) {
                            if (TEAM_CACHE.size() > 12) TEAM_CACHE.clear();
                            TEAM_CACHE.put(teamId, ft);
                            s.detailTeam = ft;
                            s.detailFetchedAt = System.currentTimeMillis();
                            s.detailError = null;
                        } else {
                            s.detailError = fe == null ? "没有队伍数据" : fe;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    public static void openPlayerDetail(final Context c, final Store s,
                                        final String playerId, String knownName) {
        if (playerId == null || playerId.length() == 0) return;
        Models.PlayerDetail cached = PLAYER_CACHE.get(playerId);
        s.detail = null;
        s.detailEvent = null;
        s.detailData = null;
        s.detailTeam = null;
        s.detailIsEvent = false;
        s.detailKind = Store.KIND_PLAYER;
        s.detailId = playerId;
        s.detailError = null;
        if (cached != null) {
            s.detailPlayer = cached;
            s.detailLoading = false;
            s.detailFetchedAt = System.currentTimeMillis();
            s.notifyChanged();
            return;
        }
        Models.PlayerDetail placeholder = new Models.PlayerDetail();
        placeholder.id = playerId;
        placeholder.name = knownName == null ? "" : knownName;
        s.detailPlayer = placeholder;
        s.detailLoading = true;
        s.notifyChanged();
        POOL.execute(new Runnable() {
            @Override public void run() {
                Models.PlayerDetail p = null;
                String err = null;
                try {
                    p = Fiveplay.player(playerId);
                } catch (Exception e) {
                    err = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                final Models.PlayerDetail fp = p;
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        if (s.detailKind != Store.KIND_PLAYER || !playerId.equals(s.detailId)) return;
                        s.detailLoading = false;
                        if (fp != null && !fp.empty()) {
                            if (PLAYER_CACHE.size() > 16) PLAYER_CACHE.clear();
                            PLAYER_CACHE.put(playerId, fp);
                            s.detailPlayer = fp;
                            s.detailFetchedAt = System.currentTimeMillis();
                            s.detailError = null;
                        } else {
                            s.detailError = fe == null ? "没有选手数据" : fe;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    /** Push the open detail onto the back stack before drilling into another page. */
    public static void pushFrame(Store s) {
        if (s.detailKind == Store.KIND_MATCH && s.detail == null) return;
        if (s.detailKind == Store.KIND_EVENT && s.detailEvent == null) return;
        s.navStack.add(s.currentFrame());
    }

    /** Pop one frame; returns false when the stack is already empty. */
    public static boolean popFrame(final Context c, final Store s) {
        if (s.navStack.isEmpty()) return false;
        Store.Frame f = s.navStack.remove(s.navStack.size() - 1);
        switch (f.kind) {
            case Store.KIND_MATCH:
                if (f.match != null) openMatchDetail(c, s, f.match);
                break;
            case Store.KIND_EVENT:
                if (f.event != null) openEventDetail(c, s, f.event);
                break;
            case Store.KIND_TEAM:
                openTeamDetail(c, s, f.id, f.title);
                break;
            case Store.KIND_PLAYER:
                openPlayerDetail(c, s, f.id, f.title);
                break;
            default:
                break;
        }
        return true;
    }

    // ------------------------------------------------------------------ events

    private static void refreshEvents(final Context c, final Store s, boolean force) {
        final Store.Page p = s.page(Store.Tab.EVENTS);
        if (p.loading) return;
        if (!force && p.loaded && !stale(Store.Tab.EVENTS, p)) return;
        p.loading = true;
        p.error = null;
        s.notifyChanged();

        PLATFORM_POOL_TRACK(true);
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.Tournament> list = null;
                String err = null;
                Fiveplay.drainStale();
                try {
                    list = Fiveplay.tournaments("", "");
                } catch (Exception e) {
                    err = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                final boolean offline = Fiveplay.drainStale();
                final List<Models.Tournament> fl = list;
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        p.loading = false;
                        p.loaded = true;
                        p.fromCache = offline;
                        if (fl != null) {
                            p.events.clear();
                            p.events.addAll(fl);
                            p.fetchedAt = System.currentTimeMillis();
                            p.error = fl.isEmpty() ? "没有赛事数据" : null;
                            s.eventHasMore = fl.size() >= 20;
                            s.eventToken = fl.isEmpty() ? "" : eventTokenOf(fl.get(fl.size() - 1));
                        } else if (p.events.isEmpty()) {
                            p.error = fe;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    private static void PLATFORM_POOL_TRACK(boolean ignored) {}

    private static String eventTokenOf(Models.Tournament t) {
        return t.token == null ? "" : t.token;
    }

    public static void loadMoreEvents(final Context c, final Store s) {
        final Store.Page p = s.page(Store.Tab.EVENTS);
        if (p.loading || !s.eventHasMore) return;
        p.loading = true;
        s.notifyChanged();
        final String token = s.eventToken;
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.Tournament> more = null;
                try {
                    more = Fiveplay.tournaments("next", token);
                } catch (Exception ignored) {}
                final List<Models.Tournament> fm = more;
                H.post(new Runnable() {
                    @Override public void run() {
                        p.loading = false;
                        if (fm != null && !fm.isEmpty()) {
                            List<String> have = new ArrayList<>();
                            for (Models.Tournament t : p.events) have.add(t.id);
                            for (Models.Tournament t : fm) if (!have.contains(t.id)) p.events.add(t);
                            s.eventToken = eventTokenOf(fm.get(fm.size() - 1));
                            s.eventHasMore = fm.size() >= 20;
                        } else {
                            s.eventHasMore = false;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    // ------------------------------------------------------------------ rank

    private static void refreshRank(final Context c, final Store s, boolean force) {
        final Store.Page p = s.page(Store.Tab.RANK);
        if (p.loading) return;
        if (!force && p.loaded && !stale(Store.Tab.RANK, p)) return;
        p.loading = true;
        p.error = null;
        s.notifyChanged();
        final int rt = s.rankType;
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.RankRow> rows = null;
                String err = null;
                Fiveplay.drainStale();
                try {
                    rows = rankRows(rt, 1);
                } catch (Exception e) {
                    err = e.getMessage() == null ? "网络异常" : e.getMessage();
                }
                final boolean offline = Fiveplay.drainStale();
                final List<Models.RankRow> fr = rows;
                final String fe = err;
                H.post(new Runnable() {
                    @Override public void run() {
                        p.loading = false;
                        p.loaded = true;
                        p.fromCache = offline;
                        if (s.rankType != rt) { s.notifyChanged(); return; }
                        if (fr != null) {
                            p.ranks.clear();
                            p.ranks.addAll(fr);
                            p.fetchedAt = System.currentTimeMillis();
                            p.error = fr.isEmpty() ? "没有排名数据" : null;
                            s.rankPage = 1;
                        } else if (p.ranks.isEmpty()) {
                            p.error = fe;
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    /**
     * rankType: 0 = HLTV 世界排名, 1 = Valve VRS, 2 = 选手 Rating 榜, 3 = 选手奖金榜。
     * 前两个是队伍榜（返回 team_id），后两个是选手榜（返回 player_id）。
     */
    static List<Models.RankRow> rankRows(int rankType, int page) throws Exception {
        if (rankType == 2) return Fiveplay.playerRanking("top", "rating", page);
        if (rankType == 3) return Fiveplay.playerRanking("earning", "total_earnings", page);
        return Fiveplay.ranking(rankType == 0 ? "rank" : "valve_rank", page);
    }

    public static void loadMoreRank(final Context c, final Store s) {
        final Store.Page p = s.page(Store.Tab.RANK);
        if (p.loading || p.ranks.size() >= 400) return;
        p.loading = true;
        s.notifyChanged();
        final int rt = s.rankType;
        POOL.execute(new Runnable() {
            @Override public void run() {
                List<Models.RankRow> rows = null;
                try {
                    rows = rankRows(rt, s.rankPage + 1);
                } catch (Exception ignored) {}
                final List<Models.RankRow> fr = rows;
                H.post(new Runnable() {
                    @Override public void run() {
                        p.loading = false;
                        if (fr != null && !fr.isEmpty() && s.rankType == rt) {
                            s.rankPage++;
                            p.ranks.addAll(fr);
                        }
                        s.notifyChanged();
                    }
                });
            }
        });
    }

    /** Switches between 5E world ranking and Valve VRS then reloads. */
    public static void setRankType(Context c, Store s, int type) {
        if (s.rankType == type) return;
        s.rankType = type;
        Store.Page p = s.page(Store.Tab.RANK);
        p.ranks.clear();
        p.loaded = false;
        p.scrollY = 0;
        refreshRank(c, s, true);
    }

    // ------------------------------------------------------------------ polling

    /**
     * Two independent reasons to stop polling: the activity is not visible and the
     * panel is dimmed for burn-in protection. Either one is enough; polling resumes
     * only when both have cleared, and then refreshed once immediately.
     */
    private static boolean sPausedHidden, sPausedDim;
    private static Context sAppCtx;

    public static void setHidden(boolean hidden) {
        if (sPausedHidden == hidden) return;
        sPausedHidden = hidden;
        onPauseChanged();
    }

    public static void setDim(boolean dim) {
        if (sPausedDim == dim) return;
        sPausedDim = dim;
        onPauseChanged();
    }

    private static void onPauseChanged() {
        if (sPausedHidden || sPausedDim) return;
        final Context c = sAppCtx;
        if (c == null) return;
        // Score is stale by definition after this long; grab it before the user looks.
        H.post(new Runnable() {
            @Override public void run() {
                if (sPausedHidden || sPausedDim) return;
                refreshIfNeeded(c, Store.get(), Store.Tab.TODAY);
                Store.get().notifyChanged();
            }
        });
    }

    public static void startLivePolling(final Context c, final Store s, final Runnable onTick) {
        sAppCtx = c.getApplicationContext();
        H.postDelayed(new Runnable() {
            @Override public void run() {
                if (sPausedHidden || sPausedDim) {
                    // Nobody is looking: no request, no battery, no traffic.
                    H.postDelayed(this, 60_000L);
                    return;
                }
                Store.Page live = s.page(Store.Tab.LIVE);
                if (live.matches.size() > 0 || System.currentTimeMillis() - sMatchesAt > 120_000L) {
                    refresh(c, s, Store.Tab.LIVE, true);
                }
                if (onTick != null) onTick.run();
                H.postDelayed(this, 60_000L);
            }
        }, 60_000L);
    }

    // ------------------------------------------------------------------ util

    static long startOfDay(long ts) {
        java.util.Calendar cal = java.util.Calendar.getInstance();
        cal.setTimeInMillis(ts);
        cal.set(java.util.Calendar.HOUR_OF_DAY, 0);
        cal.set(java.util.Calendar.MINUTE, 0);
        cal.set(java.util.Calendar.SECOND, 0);
        cal.set(java.util.Calendar.MILLISECOND, 0);
        return cal.getTimeInMillis();
    }
}
