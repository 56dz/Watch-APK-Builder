package com.dsh.cs2watch.round;

import java.util.ArrayList;
import java.util.List;

/** In-memory application state shared by the views. */
public class Store {

    public enum Tab { TODAY, LIVE, RESULTS, EVENTS, RANK }

    public static final class Page {
        public final Tab tab;
        public boolean loading;
        public boolean loaded;
        public boolean fromCache;
        public String error;
        public final List<Models.Match> matches = new ArrayList<>();
        public final List<Models.Tournament> events = new ArrayList<>();
        public final List<Models.RankRow> ranks = new ArrayList<>();
        public int scrollY;
        public long fetchedAt;
        public boolean hasMore;

        Page(Tab t) { this.tab = t; }
    }

    private static Store sInstance;

    public static Store get() {
        if (sInstance == null) sInstance = new Store();
        return sInstance;
    }

    public final Page today = new Page(Tab.TODAY);
    public final Page live = new Page(Tab.LIVE);
    public final Page results = new Page(Tab.RESULTS);
    public final Page events = new Page(Tab.EVENTS);
    public final Page rank = new Page(Tab.RANK);

    public Page page(Tab t) {
        switch (t) {
            case LIVE: return live;
            case RESULTS: return results;
            case EVENTS: return events;
            case RANK: return rank;
            default: return today;
        }
    }

    public final Page[] pages = new Page[] { today, live, results, events, rank };

    // ---- detail: a match, a tournament, a team or a player
    public static final int KIND_MATCH = 0, KIND_EVENT = 1, KIND_TEAM = 2, KIND_PLAYER = 3;

    public int detailKind;
    public Models.Match detail;
    public Models.MatchDetail detailData;
    public Models.Tournament detailEvent;
    public Models.TeamDetail detailTeam;
    public Models.PlayerDetail detailPlayer;
    public boolean detailIsEvent;
    public boolean detailLoading;
    public String detailError;
    public String detailId;
    public long detailFetchedAt;

    /** One entry of the detail back stack (match → team → player → …). */
    public static final class Frame {
        public int kind;
        public Models.Match match;
        public Models.Tournament event;
        public String id = "";
        public String title = "";
    }

    public final List<Frame> navStack = new ArrayList<>();

    /** Snapshot of what is open right now, for pushing onto {@link #navStack}. */
    public Frame currentFrame() {
        Frame f = new Frame();
        f.kind = detailKind;
        f.match = detail;
        f.event = detailEvent;
        f.id = detailId == null ? "" : detailId;
        if (detailKind == KIND_TEAM && detailTeam != null) f.title = detailTeam.name;
        else if (detailKind == KIND_PLAYER && detailPlayer != null) f.title = detailPlayer.name;
        else if (detailKind == KIND_MATCH && detail != null) f.title = detail.t1 + " vs " + detail.t2;
        else if (detailKind == KIND_EVENT && detailEvent != null) f.title = detailEvent.name;
        return f;
    }

    /** Veto + per-map + player stats of the open match (null until loaded). */
    public Models.MatchDetail data() { return detailData; }

    // ---- ranking flavour: 0 = HLTV 世界排名, 1 = Valve VRS (5E 不发布自己的排名)
    //     2 = 选手 Rating 榜, 3 = 选手奖金榜
    public int rankType;

    // ---- 赛事等级筛选: 0 = 全部, 1 = A级以上(S/A), 2 = 仅S级
    public int eventTier;

    /** 今日 / 赛果 的等级筛选，取值同 {@link #eventTier}。 */
    public int matchTier;

    /** Filtered view of the event list according to {@link #eventTier}. */
    public List<Models.Tournament> eventsFiltered() {
        List<Models.Tournament> all = events.events;
        if (eventTier == 0) return all;
        List<Models.Tournament> out = new ArrayList<>();
        for (Models.Tournament t : all) {
            if ("S".equals(t.tier)) out.add(t);
            else if (eventTier == 1 && "A".equals(t.tier)) out.add(t);
        }
        return out;
    }

    public String eventTierLabel() {
        return eventTier == 2 ? "仅S级" : eventTier == 1 ? "A级以上" : "全部";
    }

    public String matchTierLabel() {
        return matchTier == 2 ? "仅S级" : matchTier == 1 ? "A级以上" : "全部";
    }

    /** 今日 / 赛果 应用的等级筛选。 */
    public List<Models.Match> matchesOf(Tab t) {
        List<Models.Match> all = page(t).matches;
        if (matchTier == 0) return all;
        List<Models.Match> out = new ArrayList<>();
        for (Models.Match m : all) {
            if ("S".equals(m.tier)) out.add(m);
            else if (matchTier == 1 && "A".equals(m.tier)) out.add(m);
        }
        return out;
    }

    public boolean tierTab(Tab t) {
        return t == Tab.TODAY || t == Tab.RESULTS || t == Tab.LIVE;
    }

    // ---- paging cursors
    public String eventToken = "";
    public boolean eventHasMore;
    public int rankPage = 1;

    /** Listeners are notified whenever state changes in a way the view must redraw. */
    public interface Listener { void onStoreChanged(); }

    private final List<Listener> listeners = new ArrayList<>();

    public void listen(Listener l) {
        if (!listeners.contains(l)) listeners.add(l);
    }

    public void notifyChanged() {
        for (Listener l : new ArrayList<>(listeners)) l.onStoreChanged();
    }
}
