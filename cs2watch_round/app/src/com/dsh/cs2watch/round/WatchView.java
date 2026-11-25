package com.dsh.cs2watch.round;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.os.SystemClock;
import android.text.TextPaint;
import android.util.Log;
import android.view.MotionEvent;
import android.view.View;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

/** The whole watch UI: five swipeable pages plus match / tournament detail pages. */
public class WatchView extends View implements Store.Listener {

    private static final Store.Tab[] TABS = Store.Tab.values();
    private static final String[] TITLES = { "今日", "直播", "赛果", "赛事", "排名" };

    private final Store store = Store.get();
    private float w, h;
    private float padX;
    private float contentTop, contentBottom, cardGap;
    private final float cardH, cardHNoMap;

    // ---- round-dial geometry, recomputed from the real view size in layoutFor()
    private static final String TAG = "CS2Round";
    /** Upper end of the upper-left ring pill (canvas degrees: 0 = +x, 90 = down, 270 = up).
     *  The pill grows from here towards the lower left, so the end next to the
     *  centred title never moves and long labels never run into it. */
    private static final float ARC_END = 254f;
    /** Upper-right position of the round refresh button. */
    private static final float REFRESH_ANGLE = -60f;
    private float cx0, cy0, R, safe;
    /** Detail pages: fixed 154dp column and the band where its corners stay inside the dial. */
    private float colL, colR, detailTop, detailBottom;
    /** Extra scroll room so the first and last list item can reach the wide middle. */
    private float listPadTop, listPadBottom;
    private float arcIn, arcOut, arcMid;
    /** Angular extent of the ring pill as last drawn; 0 sweep = no pill on this page. */
    private float arcA0, arcSweep;
    private float dotR;
    private static final float DOT_STEP_DEG = 7f;
    private final java.util.HashSet<String> warned = new java.util.HashSet<>();

    private final TextPaint tTitle, tTime, tTeam, tScore, tMeta, tFaint, tBig, tTag, tSub, tRow;
    private final Paint pFill, pStroke, pArc, pDot;
    private final RectF rCard = new RectF();
    private final RectF rScratch = new RectF();

    // pager
    private float pos;
    private int tab;
    private boolean draggingH, draggingV;
    private float downX, downY, lastY, downScroll, vScroll;
    private long lastMoveTime;
    private float downPos;
    private boolean moved;

    // detail
    private boolean detailOpen;
    private float detailT;
    private int detailScroll;
    private float detailContentH;
    /** Which map row is unfolded (-1 = none); per-map player tables live there. */
    private int mapExpand = -1;

    // hit testing
    private final List<Object> hits = new ArrayList<>();

    /** Tap target for a team name inside the event page (name may differ from the id). */
    private static final class TeamTap {
        final String id, name;
        TeamTap(String id, String name) { this.id = id; this.name = name; }
    }
    private final List<float[]> hitRects = new ArrayList<>();
    private final RectF rRefresh = new RectF();
    private final RectF rBack = new RectF();
    private final RectF rTypeToggle = new RectF();
    private final RectF rTierToggle = new RectF();
    private final RectF rPill = new RectF();

    private long lastAnimFrame;
    private int flingSeq;

    /** Called with true when the panel dims for burn-in protection, false on wake. */
    public interface IdleListener { void onIdle(boolean idle); }

    private IdleListener idleListener;

    public void setIdleListener(IdleListener l) { idleListener = l; }

    /** Burn-in guard: after this much idle time the panel goes near-black. */
    private static final long IDLE_DIM_MS = 60_000L;
    private long lastTouchAt = SystemClock.uptimeMillis();
    private boolean dimmed;
    private final Runnable idleCheck = new Runnable() {
        @Override public void run() {
            if (!dimmed && SystemClock.uptimeMillis() - lastTouchAt > IDLE_DIM_MS) {
                dimmed = true;
                if (idleListener != null) idleListener.onIdle(true);
                invalidate();
            }
            // Already dimmed: no need to wake up often just to confirm it.
            H.postDelayed(this, dimmed ? 30_000L : 10_000L);
        }
    };
    private final android.os.Handler H = new android.os.Handler(android.os.Looper.getMainLooper());

    public WatchView(Context c) {
        super(c);
        setLayerType(LAYER_TYPE_HARDWARE, null);
        cardH = Ui.dp(c, 60);
        cardHNoMap = Ui.dp(c, 50);
        // Provisional size until onSizeChanged() reports the real one.
        layoutFor(c.getResources().getDisplayMetrics().widthPixels,
                c.getResources().getDisplayMetrics().heightPixels);

        tTitle = Ui.text(c, 13.5f, Ui.TEXT, Ui.BOLD);
        tTime = Ui.text(c, 9f, Ui.DIM, Ui.MED);
        tTeam = Ui.text(c, 11.5f, Ui.TEXT, Ui.REG);
        tScore = Ui.text(c, 12.5f, Ui.TEXT, Ui.MED);
        tMeta = Ui.text(c, 8.5f, Ui.FAINT, Ui.REG);
        tFaint = Ui.text(c, 8f, Ui.FAINT, Ui.REG);
        tBig = Ui.text(c, 22f, Ui.TEXT, Ui.MED);
        tTag = Ui.text(c, 9f, Ui.ACCENT, Ui.BOLD);
        tSub = Ui.text(c, 10f, Ui.DIM, Ui.REG);
        tRow = Ui.text(c, 8.8f, 0xFFCED5E0, Ui.REG);

        pFill = Ui.fill(Ui.CARD);
        pStroke = Ui.stroke(Ui.STROKE, Math.max(1f, Ui.dp(c, 0.7f)));
        pArc = Ui.stroke(Ui.ACCENT, Ui.dp(c, 1.6f));
        pDot = Ui.fill(Ui.ACCENT);


        store.listen(this);
        H.postDelayed(idleCheck, 5_000L);
    }

    @Override protected void onSizeChanged(int nw, int nh, int ow, int oh) {
        super.onSizeChanged(nw, nh, ow, oh);
        if (nw > 0 && nh > 0) layoutFor(nw, nh);
    }

    /**
     * Every layout constant comes from the real view size and density. The dial is
     * the circle inscribed in the view; nothing may be drawn closer than {@code safe}
     * to its rim, because the panel edge is physically cut there.
     */
    private void layoutFor(int vw, int vh) {
        Context c = getContext();
        w = vw;
        h = vh;
        cx0 = w / 2f;
        cy0 = h / 2f;
        R = Math.min(w, h) / 2f;
        safe = Ui.dp(c, 6);
        padX = Ui.dp(c, 8);
        cardGap = Ui.dp(c, 6);
        contentTop = cy0 - R + Ui.dp(c, 54);
        contentBottom = cy0 + R - Ui.dp(c, 34);

        arcOut = R - safe;
        arcIn = arcOut - Ui.dp(c, 15);
        arcMid = (arcIn + arcOut) / 2f;
        dotR = R - safe - Ui.dp(c, 10);

        // round refresh button on the upper-right rim
        float ring = R - safe - Ui.dp(c, 12);
        float rad = Ui.dp(c, 11);
        double a = Math.toRadians(REFRESH_ANGLE);
        float rcx = (float) (cx0 + ring * Math.cos(a));
        float rcy = (float) (cy0 + ring * Math.sin(a));
        rRefresh.set(rcx - rad, rcy - rad, rcx + rad, rcy + rad);

        // detail pages: a fixed column whose four corners stay inside the dial
        float lim = R - safe;
        float colHalf = Math.min(Ui.dp(c, 77), lim - Ui.dp(c, 8));
        float dyMax = (float) Math.sqrt(lim * lim - colHalf * colHalf);
        colL = cx0 - colHalf;
        colR = cx0 + colHalf;
        detailTop = Math.max(cy0 - dyMax, rRefresh.bottom + Ui.dp(c, 2));
        detailBottom = cy0 + dyMax;
    }

    // ------------------------------------------------------------------ dial geometry

    private float dist(float x, float y) {
        return (float) Math.hypot(x - cx0, y - cy0);
    }

    /** Canvas angle of a point in degrees, 0..360 (0 = right, 90 = down). */
    private float angleOf(float x, float y) {
        float a = (float) Math.toDegrees(Math.atan2(y - cy0, x - cx0));
        return a < 0 ? a + 360f : a;
    }

    /** Clockwise distance in degrees from {@code from} to {@code a}, 0..360. */
    private static float angFrom(float a, float from) {
        float d = (a - from) % 360f;
        return d < 0 ? d + 360f : d;
    }

    /**
     * Horizontal inset for a row spanning yA..yB: the half chord of the safe circle at
     * the row edge farthest from the centre, so all four corners of the row fit.
     * inset = max(padX, cx - sqrt((R - safe)^2 - dy^2)).
     */
    private float chordInset(float yA, float yB) {
        float dy = Math.max(Math.abs(yA - cy0), Math.abs(yB - cy0));
        float lim = R - safe;
        if (dy >= lim) return w / 2f;
        return Math.max(padX, cx0 - (float) Math.sqrt(lim * lim - dy * dy));
    }

    /** Debug guard: every corner of r must be inside the safe circle. Logs once per control. */
    private boolean fitsInCircle(RectF r, String what) {
        float lim = R - safe + 0.5f;
        boolean ok = dist(r.left, r.top) <= lim && dist(r.right, r.top) <= lim
                && dist(r.left, r.bottom) <= lim && dist(r.right, r.bottom) <= lim;
        if (!ok && warned.add(what)) Log.w(TAG, "outside dial: " + what + " " + r.toShortString());
        return ok;
    }

    /** Same guard for round controls: centre distance + radius. */
    private boolean fitsCircle(float x, float y, float rad, String what) {
        boolean ok = dist(x, y) + rad <= R - safe + 0.5f;
        if (!ok && warned.add(what)) Log.w(TAG, "outside dial: " + what);
        return ok;
    }

    private boolean hitRefresh(float x, float y) {
        return (float) Math.hypot(x - rRefresh.centerX(), y - rRefresh.centerY())
                <= rRefresh.width() / 2f + Ui.dp(getContext(), 6);
    }

    /** Polar hit test that matches the drawn ring segment (caps included). */
    private boolean hitPill(float x, float y) {
        if (arcSweep <= 0) return false;
        float d = dist(x, y);
        if (d < arcIn - Ui.dp(getContext(), 6) || d > R + 1) return false;
        float cap = (float) Math.toDegrees(((arcOut - arcIn) / 2f) / arcMid) + 3f;
        return angFrom(angleOf(x, y), arcA0 - cap) <= arcSweep + cap * 2;
    }

    private float dotAngle(int i) {
        // tab 0 on the left: on the bottom arc a larger canvas angle is further left
        return 90f + ((TABS.length - 1) / 2f - i) * DOT_STEP_DEG;
    }

    /** Index of the page dot under (x, y), or -1. Polar, half a step either side. */
    private int hitDot(float x, float y) {
        float d = dist(x, y);
        if (d < dotR - Ui.dp(getContext(), 16) || d > R + 1) return -1;
        float a = angleOf(x, y);
        for (int i = 0; i < TABS.length; i++) {
            if (angFrom(a, dotAngle(i) - DOT_STEP_DEG / 2f) < DOT_STEP_DEG) return i;
        }
        return -1;
    }

    @Override public void onStoreChanged() {
        postInvalidateOnAnimation();
    }

    // ------------------------------------------------------------------ animation

    private void tick() {
        if (dimmed) return;      // nothing to animate on a black panel
        long now = SystemClock.uptimeMillis();
        boolean need = false;
        float target = detailOpen ? 1f : 0f;
        if (Math.abs(detailT - target) > 0.001f) {
            detailT += (target - detailT) * 0.28f;
            if (Math.abs(detailT - target) < 0.004f) detailT = target;
            need = true;
        }
        if (!draggingH && Math.abs(pos - tab) > 0.001f) {
            pos += (tab - pos) * 0.3f;
            if (Math.abs(pos - tab) < 0.004f) pos = tab;
            need = true;
        }
        if (need || page(TABS[tab]).loading || hasLiveNearby()) {
            lastAnimFrame = now;
            postInvalidateOnAnimation();
        }
    }

    private boolean hasLiveNearby() {
        for (Models.Match m : page(TABS[tab]).matches) if (m.live()) return true;
        return false;
    }

    private Store.Page page(Store.Tab t) {
        return store.page(t);
    }

    private void kick() {
        if (SystemClock.uptimeMillis() - lastAnimFrame > 16) postInvalidateOnAnimation();
    }

    // ------------------------------------------------------------------ drawing

    @Override protected void onDraw(Canvas c) {
        // Burn-in guard: once idle for a while the screen drops to near black
        // instead of showing a static bright UI. Any touch brings it back.
        if (dimmed) {
            c.drawColor(0xFF000000);
            return;
        }
        Ui.bg(c, (int) w, (int) h);
        for (int i = 0; i < TABS.length; i++) {
            float dx = (i - pos) * w;
            if (dx <= -w || dx >= w) continue;
            c.save();
            c.translate(dx, 0);
            drawPage(c, TABS[i]);
            c.restore();
        }
        if (detailT > 0.001f) {
            c.save();
            float dx = w * (1f - detailT);
            c.translate(dx, 0);
            c.clipRect(0, 0, w - dx, h);
            Ui.bg(c, (int) w, (int) h);
            drawDetail(c);
            c.restore();
        }
        drawFooter(c);
        tick();
    }

    /** Page chrome: centred title, "离线" under it, ring pill upper-left, refresh upper-right. */
    private void drawHeader(Canvas c, Store.Tab t) {
        hits.clear();
        hitRects.clear();
        Context ctx = getContext();
        Store.Page p = page(t);
        arcSweep = 0;
        String title = TITLES[t.ordinal()];
        float base = cy0 - R + Ui.dp(ctx, 30);
        float tw = tTitle.measureText(title);
        Ui.textCenter(c, title, cx0, base, tTitle);
        rScratch.set(cx0 - tw / 2f, base - tTitle.getTextSize(), cx0 + tw / 2f, base + Ui.dp(ctx, 3));
        fitsInCircle(rScratch, "title");
        if (p.fromCache && !p.loading) {
            // Serving the last good copy from disk: say so instead of letting
            // stale scores pass for live ones. Centred under the title: beside it
            // there is no room on a round dial once the ring pill is shown.
            tTag.setColor(0xFFC98A2E);
            tTag.setTextSize(Ui.sp(ctx, 7.5f));
            float ty = base + Ui.dp(ctx, 11);
            Ui.textCenter(c, "离线", cx0, ty, tTag);
            float ow = tTag.measureText("离线");
            rScratch.set(cx0 - ow / 2f, ty - tTag.getTextSize(), cx0 + ow / 2f, ty + Ui.dp(ctx, 2));
            fitsInCircle(rScratch, "offline");
            tTag.setTextSize(Ui.sp(ctx, 9f));
        }
        drawRefresh(c, p.loading);

        if (t == Store.Tab.RANK) {
            drawArcPill(c, rankLabel(), store.rankType != 0);
        } else if (t == Store.Tab.EVENTS) {
            // ring pill: tap to cycle 全部 / A级以上 / 仅S级
            drawArcPill(c, store.eventTierLabel(), store.eventTier != 0);
        } else if (store.tierTab(t)) {
            drawArcPill(c, store.matchTierLabel(), store.matchTier != 0);
        }
    }

    private void drawRefresh(Canvas c, boolean busy) {
        float rcx = rRefresh.centerX(), rcy = rRefresh.centerY(), rad = rRefresh.width() / 2f;
        pFill.setColor(refreshPressed ? 0x33FFFFFF : 0x14FFFFFF);
        c.drawCircle(rcx, rcy, rad, pFill);
        float rot = busy ? (SystemClock.uptimeMillis() % 1000) / 1000f * 360f : 0f;
        Ui.refreshGlyph(c, rcx, rcy, Ui.dp(getContext(), 5.5f), busy ? Ui.DIM : 0xFF7A8494, rot);
        fitsCircle(rcx, rcy, rad, "refresh");
    }

    /** Detail chrome: "‹ 返回 · 队伍" centred at the top of the dial (tap = back). */
    private void drawBackHeader(Canvas c, String kind) {
        Context ctx = getContext();
        float base = cy0 - R + Ui.dp(ctx, 28);
        tTeam.setTextSize(Ui.sp(ctx, 11f));
        tTeam.setColor(Ui.TEXT);
        String back = "返回";
        String sub = " · " + kind;
        float chev = Ui.dp(ctx, 9);
        float bw = tTeam.measureText(back), sw = tMeta.measureText(sub);
        float total = chev + bw + sw;
        // shifted left of centre: the round refresh button owns the upper-right rim
        float x0 = Math.min(cx0 - total / 2f, rRefresh.left - Ui.dp(ctx, 10) - total);
        Ui.chevronLeft(c, x0 + Ui.dp(ctx, 3), base - Ui.dp(ctx, 4), Ui.dp(ctx, 4.2f), Ui.TEXT, Ui.dp(ctx, 1.6f));
        Ui.text(c, back, x0 + chev, base, tTeam);
        tMeta.setColor(Ui.DIM);
        Ui.text(c, sub, x0 + chev + bw, base, tMeta);
        tTeam.setTextSize(Ui.sp(ctx, 11.5f));
        rBack.set(x0 - Ui.dp(ctx, 8), base - Ui.dp(ctx, 13), x0 + total + Ui.dp(ctx, 8), base + Ui.dp(ctx, 6));
        fitsInCircle(rBack, "back");
        drawRefresh(c, store.detailLoading);
    }

    private String rankLabel() {
        switch (store.rankType) {
            case 1: return "VRS";
            case 2: return "Rating";
            case 3: return "奖金";
            default: return "HLTV";
        }
    }

    /**
     * Filter button as a ring segment hugging the upper-left rim: a round-capped stroke
     * of width (arcOut - arcIn) on radius arcMid, label laid along the arc with
     * drawTextOnPath. Its upper end is pinned at ARC_END; the sweep follows the label.
     */
    private void drawArcPill(Canvas c, String label, boolean on) {
        Context ctx = getContext();
        tTag.setTextSize(Ui.sp(ctx, 8.5f));
        float tw = tTag.measureText(label);
        float band = arcOut - arcIn;
        float len = tw + Ui.dp(ctx, 6);                     // straight part; caps add band/2 per end
        float sweep = (float) Math.toDegrees(len / arcMid);
        float cap = (float) Math.toDegrees((band / 2f) / arcMid);
        float a0 = ARC_END - cap - sweep;
        arcA0 = a0;
        arcSweep = sweep;
        rScratch.set(cx0 - arcMid, cy0 - arcMid, cx0 + arcMid, cy0 + arcMid);
        Paint p = Ui.stroke(on ? 0x40FF7A1A : 0x22FFFFFF, band);
        c.drawArc(rScratch, a0, sweep, false, p);
        Path path = new Path();
        path.addArc(rScratch, a0, sweep);
        tTag.setColor(on ? Ui.ACCENT : 0xFFB8C0CC);
        // clockwise path across the top: +vOffset pushes the baseline inward,
        // 0.35 * size centres the glyphs in the band
        c.drawTextOnPath(label, path, (len - tw) / 2f, tTag.getTextSize() * 0.35f, tTag);
        tTag.setTextSize(Ui.sp(ctx, 9f));
        if (arcOut > R - safe + 0.5f && warned.add("pill")) Log.w(TAG, "outside dial: pill");
        // the lower end must stay above the list, or cards slide under the pill
        double lo = Math.toRadians(a0 - cap);
        if (cy0 + arcIn * Math.sin(lo) > contentTop && warned.add("pillLow")) Log.w(TAG, "pill reaches list");
    }

    /** Page dots on the bottom arc, DOT_STEP_DEG apart, tab 0 on the left. */
    private void drawFooter(Canvas c) {
        for (int i = 0; i < TABS.length; i++) {
            boolean on = Math.abs(pos - i) < 0.5f;
            double a = Math.toRadians(dotAngle(i));
            float x = (float) (cx0 + dotR * Math.cos(a));
            float y = (float) (cy0 + dotR * Math.sin(a));
            float rad = on ? Ui.dp(getContext(), 2.6f) : Ui.dp(getContext(), 1.8f);
            pDot.setColor(on ? Ui.ACCENT : 0xFF3A4352);
            c.drawCircle(x, y, rad, pDot);
            fitsCircle(x, y, rad, "dot" + i);
        }
    }

    private void drawPage(Canvas c, Store.Tab t) {
        Store.Page p = page(t);
        drawHeader(c, t);
        if (t == Store.Tab.EVENTS) drawEventPage(c, p);
        else if (t == Store.Tab.RANK) drawRankPage(c, p);
        else drawMatchPage(c, p);
    }

    // ------------------------------------------------------------------ matches

    private void drawMatchPage(Canvas c, Store.Page p) {
        float top = contentTop, bottom = contentBottom;
        List<Models.Match> list = store.matchesOf(p.tab);

        if (p.loading && !p.loaded) { drawSpinner(c, top + (bottom - top) / 2); return; }
        if (p.error != null && p.matches.isEmpty()) { drawMessage(c, p, top, bottom); return; }
        if (list.isEmpty()) {
            String msg;
            if (store.matchTier != 0) msg = "无该等级比赛";
            else if (p.tab == Store.Tab.LIVE) msg = "当前没有直播";
            else if (p.tab == Store.Tab.RESULTS) msg = "暂无赛果";
            else msg = "今天没有比赛";
            drawEmpty(c, p, top, bottom, msg);
            return;
        }

        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - p.scrollY;
        for (Models.Match m : list) {
            float ch = (m.maps.isEmpty() && !m.hasScore()) ? cardHNoMap : cardH;
            if (y + ch > top - 4 && y < bottom + 4) {
                // inset from the chord of the visible slice: a card narrows as it
                // slides towards the rim and never pokes past it
                float in = chordInset(Math.max(y, top), Math.min(y + ch, bottom));
                if (w - in * 2 > Ui.dp(getContext(), 60)) drawMatchCard(c, m, in, y, w - in * 2, ch);
            }
            y += ch + cardGap;
            if (y > bottom + 240) break;
        }
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
        if (p.scrollY > 0 && p.scrollY >= maxScroll() - 2 && p.hasMore) {
            tFaint.setColor(Ui.FAINT);
            Ui.textCenter(c, "上滑加载更多", w / 2, bottom - Ui.dp(getContext(), 4), tFaint);
        }
    }

    private void drawMatchCard(Canvas c, Models.Match m, float x, float y, float cw, float ch) {
        float r = Ui.dp(getContext(), 11);
        rCard.set(x, y, x + cw, y + ch);
        pFill.setColor(pressed == m ? Ui.CARD_HI : Ui.CARD);
        c.drawRoundRect(rCard, r, r, pFill);

        int stripe = m.live() ? Ui.LIVE : (m.done() ? 0xFF232B38 : Ui.ACCENT);
        pFill.setColor(stripe);
        float sw = Ui.dp(getContext(), 2.6f);
        RectF sr = new RectF(x, y + Ui.dp(getContext(), 8), x + sw + r, y + ch - Ui.dp(getContext(), 9));
        c.save();
        c.clipRect(x, y, x + sw, y + ch);
        c.drawRoundRect(sr, r, r, pFill);
        c.restore();

        float lx = x + Ui.dp(getContext(), 10);
        float rx = x + cw - Ui.dp(getContext(), 9);

        // line 1: status/time
        float y1 = y + Ui.dp(getContext(), 13.5f);
        String meta;
        if (m.live()) {
            float pulse = 0.55f + 0.45f * (float) Math.abs(Math.sin(System.currentTimeMillis() / 700.0));
            pDot.setColor(Ui.alpha(Ui.LIVE, (int) (255 * pulse)));
            c.drawCircle(lx + Ui.dp(getContext(), 2.2f), y1 - Ui.dp(getContext(), 2.3f), Ui.dp(getContext(), 2.2f), pDot);
            meta = "LIVE";
            tMeta.setColor(Ui.LIVE);
        } else if (m.done()) {
            meta = "已结束";
            tMeta.setColor(Ui.FAINT);
        } else {
            meta = timeLabel(m.start);
            tMeta.setColor(Ui.DIM);
        }
        float metaX = m.live() ? lx + Ui.dp(getContext(), 7) : lx;
        Ui.text(c, meta, metaX, y1, tMeta);

        // tournament + tier on the right
        float used = metaX + tMeta.measureText(meta) + Ui.dp(getContext(), 6);
        String ev = (m.tier.length() > 0 ? m.tier + " · " : "") + (m.event == null ? "" : m.event);
        float evSpace = rx - used;
        if (evSpace > Ui.dp(getContext(), 24)) {
            tFaint.setColor(Ui.FAINT);
            Ui.textRight(c, Ui.fit(tFaint, ev, evSpace), rx, y1, tFaint);
        }

        // teams
        float y2 = y + Ui.dp(getContext(), 29);
        float y3 = y + Ui.dp(getContext(), 43);
        boolean showScore = m.hasScore();
        float scoreSpace = showScore ? Ui.dp(getContext(), 24) : 0;

        tTeam.setColor(m.done() && m.winner == 2 ? Ui.DIM : Ui.TEXT);
        Ui.text(c, Ui.fit(tTeam, m.t1, rx - lx - scoreSpace), lx, y2, tTeam);
        tTeam.setColor(m.done() && m.winner == 1 ? Ui.DIM : Ui.TEXT);
        Ui.text(c, Ui.fit(tTeam, m.t2, rx - lx - scoreSpace), lx, y3, tTeam);

        if (showScore) {
            tScore.setColor(m.winner == 2 ? Ui.DIM : Ui.TEXT);
            Ui.textRight(c, String.valueOf(m.s1), rx, y2, tScore);
            tScore.setColor(m.winner == 1 ? Ui.DIM : Ui.TEXT);
            Ui.textRight(c, String.valueOf(m.s2), rx, y3, tScore);
        } else {
            tMeta.setColor(Ui.FAINT);
            Ui.textRight(c, "BO" + m.bo, rx, (y2 + y3) / 2f - Ui.dp(getContext(), 1), tMeta);
        }

        // per-map small scores
        String ml = m.mapLine();
        if (ml.length() > 0 && ch > cardHNoMap) {
            tFaint.setColor(0xFF7A8494);
            Ui.text(c, Ui.fit(tFaint, ml, rx - lx), lx, y + ch - Ui.dp(getContext(), 6.5f), tFaint);
        }

        hits.add(m);
        hitRects.add(new float[] { x, y, x + cw, y + ch });
    }

    // ------------------------------------------------------------------ events

    private void drawEventPage(Canvas c, Store.Page p) {
        float top = contentTop, bottom = contentBottom;
        if (p.loading && !p.loaded) { drawSpinner(c, top + (bottom - top) / 2); return; }
        if (p.error != null && p.events.isEmpty()) { drawMessage(c, p, top, bottom); return; }
        List<Models.Tournament> list = store.eventsFiltered();
        if (list.isEmpty()) {
            drawEmpty(c, p, top, bottom, store.eventTier == 0 ? "暂无赛事" : "无该等级赛事");
            return;
        }

        float rowH = Ui.dp(getContext(), 46);
        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - p.scrollY;
        for (Models.Tournament t : list) {
            if (y + rowH > top && y < bottom) {
                float in = chordInset(Math.max(y, top), Math.min(y + rowH - Ui.dp(getContext(), 4), bottom));
                if (w - in * 2 > Ui.dp(getContext(), 60)) drawEventRow(c, t, in, y, w - in * 2, rowH);
            }
            y += rowH;
            if (y > bottom + 100) break;
        }
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    private void drawEventRow(Canvas c, Models.Tournament t, float x, float y, float cw, float rowH) {
        float r = Ui.dp(getContext(), 10);
        rCard.set(x, y, x + cw, y + rowH - Ui.dp(getContext(), 4));
        pFill.setColor(pressed == t ? Ui.CARD_HI : Ui.CARD);
        c.drawRoundRect(rCard, r, r, pFill);

        float lx = x + Ui.dp(getContext(), 11);
        float rx = x + cw - Ui.dp(getContext(), 10);

        tTag.setColor("S".equals(t.tier) ? Ui.ACCENT : Ui.DIM);
        Ui.text(c, t.tier, lx, y + Ui.dp(getContext(), 15), tTag);
        float nameX = lx + Ui.dp(getContext(), 11);

        // Reserve room for the live pill before fitting the name so they never overlap.
        float dateRight = rx;
        if (t.ongoing()) dateRight = rx - Ui.dp(getContext(), 34);
        tTeam.setColor(Ui.TEXT);
        tTeam.setTextSize(Ui.sp(getContext(), 11f));
        Ui.text(c, Ui.fit(tTeam, t.name, dateRight - nameX - Ui.dp(getContext(), 4)),
                nameX, y + Ui.dp(getContext(), 15), tTeam);
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));
        if (t.ongoing()) {
            tMeta.setColor(Ui.LIVE);
            Ui.textRight(c, "进行中", rx, y + Ui.dp(getContext(), 15), tMeta);
        }

        tMeta.setColor(Ui.DIM);
        float prizeW = t.prize == null ? 0 : tFaint.measureText(t.prize) + Ui.dp(getContext(), 8);
        Ui.text(c, Ui.fit(tMeta, t.dateShort.length() > 0 ? t.dateShort : t.dateText,
                dateRight - nameX - prizeW), nameX, y + Ui.dp(getContext(), 29), tMeta);
        if (t.prize != null && t.prize.length() > 0) {
            tFaint.setColor(Ui.FAINT);
            Ui.textRight(c, t.prize, rx, y + Ui.dp(getContext(), 29), tFaint);
        }

        hits.add(t);
        hitRects.add(new float[] { x, y, x + cw, y + rowH });
    }

    // ------------------------------------------------------------------ rank

    private void drawRankPage(Canvas c, Store.Page p) {
        float top = contentTop, bottom = contentBottom;
        if (p.loading && p.ranks.isEmpty()) { drawSpinner(c, top + (bottom - top) / 2); return; }
        if (p.error != null && p.ranks.isEmpty()) { drawMessage(c, p, top, bottom); return; }
        if (p.ranks.isEmpty()) { drawEmpty(c, p, top, bottom, "暂无排名"); return; }

        float rowH = Ui.dp(getContext(), 30);
        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - p.scrollY;
        int n = 0;
        for (Models.RankRow r : p.ranks) {
            if (y + rowH > top && y < bottom) {
                float in = chordInset(Math.max(y, top), Math.min(y + rowH, bottom));
                float lx = in + Ui.dp(getContext(), 2);
                float rx = w - in - Ui.dp(getContext(), 2);
                float cy = y + Ui.dp(getContext(), 20);
                boolean top3 = n < 3;
                tScore.setColor(top3 ? Ui.ACCENT : Ui.DIM);
                tScore.setTextSize(Ui.sp(getContext(), top3 ? 12f : 10f));
                Ui.text(c, r.rank, lx, cy, tScore);
                tScore.setTextSize(Ui.sp(getContext(), 12.5f));

                tTeam.setColor(Ui.TEXT);
                tTeam.setTextSize(Ui.sp(getContext(), 11f));
                float nameX = lx + Ui.dp(getContext(), 20);
                float ptW = store.rankType == 3 ? Ui.dp(getContext(), 64) : Ui.dp(getContext(), 30);
                float regW = r.region.length() > 0 ? Ui.dp(getContext(), 34) : 0;
                Ui.text(c, Ui.fit(tTeam, r.name, rx - nameX - ptW - regW), nameX, cy, tTeam);
                tTeam.setTextSize(Ui.sp(getContext(), 11.5f));

                tMeta.setColor(Ui.FAINT);
                tMeta.setTextSize(Ui.sp(getContext(), 8f));
                if (regW > 0) Ui.textRight(c, r.region, rx - ptW, cy - Ui.dp(getContext(), 1), tMeta);
                tMeta.setTextSize(Ui.sp(getContext(), 8.5f));
                tFaint.setColor(Ui.DIM);
                Ui.textRight(c, r.point, rx, cy - Ui.dp(getContext(), 1), tFaint);

                if (y + rowH < bottom) {
                    pFill.setColor(0xFF141821);
                    c.drawRect(lx, y + rowH - 1, rx, y + rowH, pFill);
                }
                if (r.id != null && r.id.length() > 0) {
                    hits.add(r);
                    hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y + Ui.dp(getContext(), 4),
                            rx, y + rowH - Ui.dp(getContext(), 2) });
                }
            }
            y += rowH;
            n++;
            if (y > bottom + 60) break;
        }
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    // ------------------------------------------------------------------ detail

    private void drawDetail(Canvas c) {
        float top = detailTop, bottom = detailBottom;
        hits.clear();
        hitRects.clear();
        arcSweep = 0;

        String head = store.detailKind == Store.KIND_TEAM ? "队伍"
                : store.detailKind == Store.KIND_PLAYER ? "选手"
                : store.detailKind == Store.KIND_EVENT ? "赛事" : "比赛";
        drawBackHeader(c, head);

        if (store.detailKind == Store.KIND_EVENT) { drawEventDetail(c, top, bottom); return; }
        if (store.detailKind == Store.KIND_TEAM) { drawTeamDetail(c, top, bottom); return; }
        if (store.detailKind == Store.KIND_PLAYER) { drawPlayerDetail(c, top, bottom); return; }

        if (store.detailLoading && store.detailData == null) {
            drawSpinner(c, top + (bottom - top) / 2);
            return;
        }
        Models.Match m = store.detail;
        if (m == null) { drawEmpty(c, store.today, top, bottom, "没有内容"); return; }

        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - detailScroll + Ui.dp(getContext(), 14);   // clear of the top fade
        float startY = y;
        float lx = colL;
        float rx = colR;

        // status line
        tMeta.setColor(Ui.FAINT);
        String when = m.live() ? "进行中" : (m.done() ? "已结束" : dateLabel(m.start) + " " + hm(m.start));
        Ui.text(c, when, lx, y + Ui.dp(getContext(), 8), tMeta);
        tFaint.setColor(Ui.FAINT);
        Ui.textRight(c, "BO" + m.bo, rx, y + Ui.dp(getContext(), 8), tFaint);
        y += Ui.dp(getContext(), 20);

        // teams + score
        float y1 = y + Ui.dp(getContext(), 15);
        float y2 = y + Ui.dp(getContext(), 42);
        tTeam.setTextSize(Ui.sp(getContext(), 12.5f));
        tTeam.setColor(m.done() && m.winner == 2 ? Ui.DIM : Ui.TEXT);
        String n1 = Ui.fit(tTeam, m.t1, rx - lx - Ui.dp(getContext(), 30));
        Ui.text(c, n1, lx, y1, tTeam);
        if (m.t1Id.length() > 0) {
            hits.add("t1team");
            hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y1 - Ui.dp(getContext(), 12),
                    lx + tTeam.measureText(n1) + Ui.dp(getContext(), 6), y1 + Ui.dp(getContext(), 5) });
        }
        tTeam.setColor(m.done() && m.winner == 1 ? Ui.DIM : Ui.TEXT);
        String n2 = Ui.fit(tTeam, m.t2, rx - lx - Ui.dp(getContext(), 30));
        Ui.text(c, n2, lx, y2, tTeam);
        if (m.t2Id.length() > 0) {
            hits.add("t2team");
            hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y2 - Ui.dp(getContext(), 12),
                    lx + tTeam.measureText(n2) + Ui.dp(getContext(), 6), y2 + Ui.dp(getContext(), 5) });
        }
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));

        if (m.hasScore()) {
            tBig.setColor(m.winner == 2 ? Ui.DIM : Ui.TEXT);
            Ui.textRight(c, String.valueOf(m.s1), rx, y1 + Ui.dp(getContext(), 2), tBig);
            tBig.setColor(m.winner == 1 ? Ui.DIM : Ui.TEXT);
            Ui.textRight(c, String.valueOf(m.s2), rx, y2 + Ui.dp(getContext(), 2), tBig);
        }
        y += Ui.dp(getContext(), 60);

        if (m.event != null && m.event.length() > 0) {
            tSub.setColor(0xFFCED5E0);
            String en = Ui.fit(tSub, m.event, rx - lx - Ui.dp(getContext(), 14));
            Ui.text(c, en, lx, y, tSub);
            if (m.ttId.length() > 0) {
                // the event name is a shortcut into the tournament page
                hits.add("event");
                hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                        lx + tSub.measureText(en) + Ui.dp(getContext(), 6), y + Ui.dp(getContext(), 4) });
                Ui.chevronRight(c, rx - Ui.dp(getContext(), 2), y - Ui.dp(getContext(), 4),
                        Ui.dp(getContext(), 3.2f), Ui.FAINT, Ui.dp(getContext(), 1.5f));
            }
            y += Ui.dp(getContext(), 15);
        }
        if (m.stage != null && m.stage.length() > 0) {
            tFaint.setColor(Ui.FAINT);
            Ui.text(c, Ui.fit(tFaint, m.stage, rx - lx), lx, y, tFaint);
        }
        y += Ui.dp(getContext(), 16);

        // 赛前赔率：5E 用百分比表示胜率预期，未开赛时是最有信息量的一行
        if (!m.hasScore() && (m.odds1.length() > 0 || m.odds2.length() > 0)) {
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "胜率预测", lx, y, tMeta);
            tRow.setColor(0xFFCED5E0);
            String o = (m.odds1.length() > 0 ? m.odds1 + "%" : "--")
                    + "  :  " + (m.odds2.length() > 0 ? m.odds2 + "%" : "--");
            Ui.textRight(c, o, rx, y, tRow);
            y += Ui.dp(getContext(), 15);
            y += Ui.dp(getContext(), 4);
        }

        Models.MatchDetail d = store.detailData;
        if (d != null) {
            // -------- veto
            if (!d.bp.isEmpty()) {
                y = sectionTitle(c, lx, rx, y, "Ban / Pick");
                float rowH = Ui.dp(getContext(), 17);
                for (Models.BanPick b : d.bp) {
                    if (y > bottom + 20) break;
                    boolean ban = "ban".equals(b.type);
                    tMeta.setColor(ban ? Ui.FAINT : Ui.ACCENT);
                    Ui.text(c, ban ? "禁" : ("pick".equals(b.type) ? "选" : "决"), lx, y, tMeta);
                    tRow.setColor(ban ? Ui.FAINT : Ui.TEXT);
                    String side = "t1".equals(b.side) ? m.t1 : ("t2".equals(b.side) ? m.t2 : "");
                    String line = b.map + (side.length() > 0 ? "  " + side : "");
                    Ui.text(c, line, lx + Ui.dp(getContext(), 18), y, tRow);
                    if (ban) {
                        // strike through banned maps
                        float tw = tRow.measureText(line);
                        pFill.setColor(Ui.FAINT);
                        c.drawRect(lx + Ui.dp(getContext(), 18), y - Ui.dp(getContext(), 3.4f),
                                lx + Ui.dp(getContext(), 18) + tw, y - Ui.dp(getContext(), 2.6f), pFill);
                    }
                    y += rowH;
                }
                y += Ui.dp(getContext(), 8);
            }

            // -------- per-map scores
            if (!d.match.maps.isEmpty()) {
                y = sectionTitle(c, lx, rx, y, "地图");
                for (int i = 0; i < d.match.maps.size(); i++) {
                    Models.MapScore ms = d.match.maps.get(i);
                    if (y > bottom + 40) break;
                    boolean expandable = !ms.p1.isEmpty() || !ms.p2.isEmpty();
                    if (expandable) {
                        // tap a map row to unfold its per-player table
                        hits.add("map:" + i);
                        hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                                rx, y + Ui.dp(getContext(), 4) });
                    }
                    tMeta.setColor(Ui.FAINT);
                    Ui.text(c, String.valueOf(i + 1), lx, y, tMeta);
                    tRow.setColor(ms.done() ? Ui.TEXT : (ms.live() ? Ui.LIVE : Ui.FAINT));
                    String nm = ms.name.length() == 0 ? "待定" : ms.name;
                    Ui.text(c, Ui.fit(tRow, nm, Ui.dp(getContext(), 52)), lx + Ui.dp(getContext(), 14), y, tRow);
                    if (ms.status >= 1 && (ms.s1 > 0 || ms.s2 > 0)) {
                        tSub.setColor(ms.live() ? Ui.LIVE : Ui.TEXT);
                        tSub.setTextSize(Ui.sp(getContext(), 11f));
                        Ui.text(c, ms.s1 + ":" + ms.s2, lx + Ui.dp(getContext(), 70), y, tSub);
                        tSub.setTextSize(Ui.sp(getContext(), 10f));
                    }
                    String pick = ms.pickLabel();
                    float rightEdge = rx;
                    if (expandable) {
                        // small caret hints that the row unfolds
                        Ui.chevronRight(c, rx - Ui.dp(getContext(), 2), y - Ui.dp(getContext(), 4),
                                Ui.dp(getContext(), 2.6f), Ui.FAINT, Ui.dp(getContext(), 1.4f));
                        rightEdge = rx - Ui.dp(getContext(), 10);
                    }
                    if (ms.live() && ms.round > 0) {
                        // live map: round counter is more useful than the pick tag
                        tMeta.setColor(Ui.LIVE);
                        Ui.textRight(c, "R" + ms.round, rightEdge, y, tMeta);
                    } else if (pick.length() > 0) {
                        tFaint.setColor(Ui.FAINT);
                        Ui.textRight(c, pick, rightEdge, y, tFaint);
                    }
                    String half = ms.halfLine();
                    if (half.length() > 0) {
                        y += Ui.dp(getContext(), 12);
                        tFaint.setColor(0xFF6B7482);
                        Ui.text(c, half, lx + Ui.dp(getContext(), 14), y, tFaint);
                    }
                    y += Ui.dp(getContext(), 17);
                    if (mapExpand == i && expandable) {
                        y = playerBlock(c, lx, rx, y, m.t1, ms.p1, bottom);
                        y += Ui.dp(getContext(), 5);
                        y = playerBlock(c, lx, rx, y, m.t2, ms.p2, bottom);
                        y += Ui.dp(getContext(), 4);
                    }
                }
                y += Ui.dp(getContext(), 6);
            }

            // -------- players
            if (!d.series.isEmpty()) {
                y = sectionTitle(c, lx, rx, y, "选手数据");
                y = playerBlock(c, lx, rx, y, m.t1, d, 1, bottom);
                y += Ui.dp(getContext(), 6);
                y = playerBlock(c, lx, rx, y, m.t2, d, 2, bottom);
            }

            if (d.mvpName.length() > 0) {
                tMeta.setColor(Ui.FAINT);
                Ui.text(c, "全场 MVP", lx, y + Ui.dp(getContext(), 4), tMeta);
                tTag.setColor(Ui.ACCENT);
                Ui.textRight(c, d.mvpName + (d.mvpRating.length() > 0 ? "  " + d.mvpRating : ""),
                        rx, y + Ui.dp(getContext(), 4), tTag);
                y += Ui.dp(getContext(), 16);
            }
            // 未开赛的比赛没有 /data，只有赛前对比。
            if (d.pre != null && !d.pre.empty()) {
                y = preBlock(c, lx, rx, y, m, d.pre, bottom);
            }
        } else if (store.detailLoading) {
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "载入数据…", lx, y, tMeta);
            y += Ui.dp(getContext(), 16);
        } else if (store.detailError != null) {
            tMeta.setColor(Ui.LIVE);
            Ui.text(c, Ui.fit(tMeta, store.detailError, rx - lx), lx, y, tMeta);
            y += Ui.dp(getContext(), 16);
        }

        tFaint.setColor(Ui.FAINT);
        Ui.text(c, "数据来源 5EPlay", lx, y + Ui.dp(getContext(), 10), tFaint);
        y += Ui.dp(getContext(), 18);

        detailContentH = y - startY;
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    private float sectionTitle(Canvas c, float lx, float rx, float y, String title) {
        tTag.setColor(Ui.FAINT);
        tTag.setTextSize(Ui.sp(getContext(), 8.5f));
        Ui.text(c, title, lx, y, tTag);
        tTag.setTextSize(Ui.sp(getContext(), 9f));
        pFill.setColor(0xFF1B2029);
        c.drawRect(lx, y + Ui.dp(getContext(), 4), rx, y + Ui.dp(getContext(), 5), pFill);
        return y + Ui.dp(getContext(), 16);
    }

    private float playerBlock(Canvas c, float lx, float rx, float y, String teamName,
                              Models.MatchDetail d, int side, float bottom) {
        return playerBlock(c, lx, rx, y, teamName, d.side(side), bottom);
    }

    private float playerBlock(Canvas c, float lx, float rx, float y, String teamName,
                              List<Models.Player> list, float bottom) {
        tSub.setColor(Ui.TEXT);
        tSub.setTextSize(Ui.sp(getContext(), 9.5f));
        Ui.text(c, Ui.fit(tSub, teamName, rx - lx), lx, y, tSub);
        y += Ui.dp(getContext(), 13);

        float colKD = rx - Ui.dp(getContext(), 104);
        float colAdr = rx - Ui.dp(getContext(), 56);
        tFaint.setColor(Ui.FAINT);
        tFaint.setTextSize(Ui.sp(getContext(), 7.4f));
        Ui.text(c, "K-D", colKD, y, tFaint);
        Ui.text(c, "ADR", colAdr, y, tFaint);
        Ui.textRight(c, "RATING", rx, y, tFaint);
        tFaint.setTextSize(Ui.sp(getContext(), 8f));
        y += Ui.dp(getContext(), 12);

        for (Models.Player p : list) {
            if (y > bottom + 60) break;
            tRow.setColor(p.mvp ? Ui.ACCENT : 0xFFD5DBE5);
            tRow.setTextSize(Ui.sp(getContext(), 8.8f));
            Ui.text(c, Ui.fit(tRow, p.name, colKD - lx - Ui.dp(getContext(), 4)), lx, y, tRow);
            tFaint.setColor(0xFF9AA4B2);
            Ui.text(c, p.kdText(), colKD, y, tFaint);
            Ui.text(c, p.adr, colAdr, y, tFaint);
            float rating = parseFloat(p.rating);
            tFaint.setColor(rating >= 1.15f ? Ui.WIN : (rating > 0 && rating < 0.85f ? Ui.LIVE : 0xFF9AA4B2));
            Ui.textRight(c, p.rating, rx, y, tFaint);
            if (p.id != null && p.id.length() > 0) {
                hits.add(p);
                hitRects.add(new float[] { lx - Ui.dp(getContext(), 3), y - Ui.dp(getContext(), 10),
                        colKD - Ui.dp(getContext(), 4), y + Ui.dp(getContext(), 4) });
            }
            y += Ui.dp(getContext(), 14);
        }
        tSub.setTextSize(Ui.sp(getContext(), 10f));
        return y;
    }

    // ------------------------------------------------------------------ pre-match

    /**
     * 未开赛比赛的详情：赛前对比。数据来自 analysis_v1，含双方选手近况、
     * 队伍整体指标、各图胜率、交手战绩。
     */
    private float preBlock(Canvas c, float lx, float rx, float y,
                           Models.Match m, Models.Analysis a, float bottom) {
        // 队伍整体对比
        y = sectionTitle(c, lx, rx, y, "赛前对比");
        String[][] rows = {
                { "胜率", Models.Analysis.pair(a.winRate1, a.winRate2) },
                { "KD", Models.Analysis.pair(a.kd1, a.kd2) },
                { "Rating", Models.Analysis.pair(a.rating1, a.rating2) },
                { "首杀率", Models.Analysis.pair(a.fk1, a.fk2) },
        };
        for (String[] r : rows) {
            if (r[1].length() == 0) continue;
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, r[0], lx, y, tMeta);
            tRow.setColor(0xFFD5DBE5);
            Ui.textRight(c, r[1], rx, y, tRow);
            y += Ui.dp(getContext(), 14);
        }
        y += Ui.dp(getContext(), 4);

        // 各图胜率
        if (!a.maps.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "地图胜率");
            for (Models.MapRate mr : a.maps) {
                if (y > bottom + 120) break;
                tRow.setColor(mr.picked() ? Ui.TEXT : 0xFFC2C9D4);
                Ui.text(c, Ui.fit(tRow, mr.name, Ui.dp(getContext(), 74)), lx, y, tRow);
                tFaint.setColor(Ui.FAINT);
                String r1 = mr.r1 < 0 ? "--" : mr.r1 + "%";
                String r2 = mr.r2 < 0 ? "--" : mr.r2 + "%";
                Ui.text(c, r1, lx + Ui.dp(getContext(), 86), y, tFaint);
                Ui.text(c, r2, lx + Ui.dp(getContext(), 122), y, tFaint);
                String bp = mr.bpLabel();
                if (bp.length() > 0) {
                    tTag.setColor(mr.picked() ? Ui.ACCENT : Ui.FAINT);
                    tTag.setTextSize(Ui.sp(getContext(), 8f));
                    Ui.textRight(c, bp, rx, y, tTag);
                    tTag.setTextSize(Ui.sp(getContext(), 9f));
                }
                y += Ui.dp(getContext(), 15);
            }
            y += Ui.dp(getContext(), 4);
        }

        // 双方选手
        if (!a.players1.isEmpty() || !a.players2.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "选手状态");
            if (!a.players1.isEmpty()) {
                y = playerBlock(c, lx, rx, y, m.t1, a.players1, bottom);
                y += Ui.dp(getContext(), 6);
            }
            if (!a.players2.isEmpty()) {
                y = playerBlock(c, lx, rx, y, m.t2, a.players2, bottom);
                y += Ui.dp(getContext(), 4);
            }
        }

        // 交手战绩
        if (!a.h2h.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "交手战绩");
            for (Models.PastMatch pm : a.h2h) {
                if (y > bottom + 160) break;
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, pm.date, lx, y, tFaint);
                tRow.setColor(pm.winner == 2 ? Ui.LIVE : Ui.WIN);
                Ui.text(c, pm.score, lx + Ui.dp(getContext(), 32), y, tRow);
                tFaint.setColor(0xFF8A93A1);
                Ui.text(c, Ui.fit(tFaint, pm.event == null ? "" : pm.event,
                        rx - lx - Ui.dp(getContext(), 54)), lx + Ui.dp(getContext(), 58), y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 4);
        }

        // 近期战绩
        y = recentBlock(c, lx, rx, y, m.t1, a.recent1, bottom);
        y = recentBlock(c, lx, rx, y, m.t2, a.recent2, bottom);
        return y;
    }

    private float recentBlock(Canvas c, float lx, float rx, float y, String teamName,
                              List<Models.PastMatch> list, float bottom) {
        if (list.isEmpty()) return y;
        y = sectionTitle(c, lx, rx, y, "近期战绩");
        tSub.setColor(Ui.TEXT);
        tSub.setTextSize(Ui.sp(getContext(), 9.5f));
        Ui.text(c, Ui.fit(tSub, teamName, rx - lx), lx, y, tSub);
        tSub.setTextSize(Ui.sp(getContext(), 10f));
        y += Ui.dp(getContext(), 13);
        for (Models.PastMatch pm : list) {
            if (y > bottom + 200) break;
            tFaint.setColor(Ui.FAINT);
            Ui.text(c, pm.date, lx, y, tFaint);
            tRow.setColor(pm.winner == 1 ? Ui.WIN : (pm.winner == 2 ? Ui.LIVE : 0xFF9AA4B2));
            Ui.text(c, pm.score, lx + Ui.dp(getContext(), 32), y, tRow);
            tFaint.setColor(0xFF8A93A1);
            String vs = pm.t1 == null || pm.t1.length() == 0 ? "" : pm.t1 + "  ";
            Ui.text(c, Ui.fit(tFaint, vs, Ui.dp(getContext(), 74)), lx + Ui.dp(getContext(), 58), y, tFaint);
            tFaint.setColor(Ui.FAINT);
            Ui.textRight(c, Ui.fit(tFaint, pm.event == null ? "" : pm.event,
                    rx - lx - Ui.dp(getContext(), 138)), rx, y, tFaint);
            y += Ui.dp(getContext(), 14);
        }
        return y + Ui.dp(getContext(), 4);
    }

    private static float parseFloat(String s) {
        try { return Float.parseFloat(s); } catch (Exception e) { return 0f; }
    }

    private void drawEventDetail(Canvas c, float top, float bottom) {
        Models.Tournament t = store.detailEvent;
        if (t == null) { drawEmpty(c, store.events, top, bottom, "没有内容"); return; }

        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - detailScroll + Ui.dp(getContext(), 14);   // clear of the top fade
        float startY = y;
        float lx = colL;
        float rx = colR;

        tTag.setColor("S".equals(t.tier) ? Ui.ACCENT : Ui.DIM);
        String tierText = t.tierLabel.length() > 0 ? t.tierLabel : (t.tier + "-Tier");
        Ui.text(c, tierText, lx, y + Ui.dp(getContext(), 8), tTag);
        y += Ui.dp(getContext(), 20);

        tTeam.setColor(Ui.TEXT);
        tTeam.setTextSize(Ui.sp(getContext(), 12.5f));
        String name = t.name;
        String rest = "";
        if (tTeam.measureText(name) > rx - lx) {
            int cut = name.length();
            while (cut > 0 && tTeam.measureText(name.substring(0, cut)) > rx - lx) cut--;
            int sp = name.lastIndexOf(' ', cut);
            if (sp > cut / 2) cut = sp;
            rest = name.substring(cut).trim();
            name = name.substring(0, cut).trim();
        }
        Ui.text(c, name, lx, y + Ui.dp(getContext(), 4), tTeam);
        y += Ui.dp(getContext(), 18);
        if (rest.length() > 0) {
            Ui.text(c, Ui.fit(tTeam, rest, rx - lx), lx, y, tTeam);
            y += Ui.dp(getContext(), 16);
        }
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));
        y += Ui.dp(getContext(), 4);

        y = row(c, lx, rx, y, "时间", t.dateText);
        y = row(c, lx, rx, y, "奖金", t.prize);
        y = row(c, lx, rx, y, "地点", t.location);
        if (t.teamCount > 0) y = row(c, lx, rx, y, "队伍", t.teamCount + " 支");
        if (t.winner.length() > 0) y = row(c, lx, rx, y, "冠军", t.winner);

        if (store.detailLoading && !t.detailLoaded) {
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "载入详情…", lx, y + Ui.dp(getContext(), 4), tMeta);
            y += Ui.dp(getContext(), 18);
        }

        if (t.character.length() > 0) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 4), "赛制");
            for (String line : t.character.split("\n")) {
                if (line.trim().length() == 0) continue;
                tRow.setColor(0xFFCED5E0);
                Ui.text(c, Ui.fit(tRow, line.trim(), rx - lx), lx, y, tRow);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 4);
        }

        if (!t.stages.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "赛段");
            for (String[] st : t.stages) {
                tRow.setColor(Ui.TEXT);
                Ui.text(c, Ui.fit(tRow, st[0], rx - lx), lx, y, tRow);
                y += Ui.dp(getContext(), 13);
                if (st[1].length() > 0) {
                    tFaint.setColor(0xFF7A8494);
                    for (String line : st[1].split("\n")) {
                        if (line.trim().length() == 0) continue;
                        Ui.text(c, Ui.fit(tFaint, line.trim(), rx - lx - Ui.dp(getContext(), 4)),
                                lx + Ui.dp(getContext(), 6), y, tFaint);
                        y += Ui.dp(getContext(), 12);
                    }
                }
                y += Ui.dp(getContext(), 2);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!t.prizeRows.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "奖金分配");
            for (String[] r : t.prizeRows) {
                tMeta.setColor(Ui.FAINT);
                Ui.text(c, r[0], lx, y, tMeta);
                tRow.setColor(0xFFCED5E0);
                Ui.text(c, Ui.fit(tRow, r[1], rx - lx - Ui.dp(getContext(), 62)),
                        lx + Ui.dp(getContext(), 14), y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                tFaint.setTextSize(Ui.sp(getContext(), 7.6f));
                Ui.textRight(c, r[2], rx, y, tFaint);
                tFaint.setTextSize(Ui.sp(getContext(), 8f));
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 4);
        }

        if (!t.teamNames.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "参赛队伍");
            // two per row so 8-16 teams stay compact; each name is tappable
            float colW = (rx - lx) / 2f;
            for (int i = 0; i < t.teamNames.size(); i++) {
                float cx = lx + (i % 2) * colW;
                if (i % 2 == 0 && i > 0) y += Ui.dp(getContext(), 14);
                tRow.setColor(0xFFCED5E0);
                String nm = Ui.fit(tRow, t.teamNames.get(i), colW - Ui.dp(getContext(), 6));
                Ui.text(c, nm, cx, y, tRow);
                if (i < t.teamIds.size() && t.teamIds.get(i).length() > 0) {
                    hits.add(new TeamTap(t.teamIds.get(i), t.teamNames.get(i)));
                    hitRects.add(new float[] { cx - Ui.dp(getContext(), 3), y - Ui.dp(getContext(), 11),
                            cx + tRow.measureText(nm) + Ui.dp(getContext(), 4), y + Ui.dp(getContext(), 4) });
                }
            }
            y += Ui.dp(getContext(), 16);
        }

        if (!t.maps.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "地图池");
            StringBuilder sb = new StringBuilder();
            for (String mp : t.maps) {
                if (sb.length() > 0) sb.append(" · ");
                sb.append(mp);
            }
            tRow.setColor(0xFFCED5E0);
            String line = sb.toString();
            if (tRow.measureText(line) <= rx - lx) {
                Ui.text(c, line, lx, y, tRow);
                y += Ui.dp(getContext(), 14);
            } else {
                for (String mp : t.maps) {
                    tRow.setColor(0xFFCED5E0);
                    Ui.text(c, Ui.fit(tRow, mp, rx - lx), lx, y, tRow);
                    y += Ui.dp(getContext(), 13);
                }
            }
            y += Ui.dp(getContext(), 4);
        }

        if (!t.teamStats.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "队伍数据");
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "队伍", lx, y, tMeta);
            Ui.textRight(c, "胜率", lx + (rx - lx) * 0.56f, y, tMeta);
            Ui.textRight(c, "KD", lx + (rx - lx) * 0.78f, y, tMeta);
            Ui.textRight(c, "Rating", rx, y, tMeta);
            y += Ui.dp(getContext(), 13);
            for (String[] ts : t.teamStats) {
                tRow.setColor(Ui.TEXT);
                Ui.text(c, Ui.fit(tRow, ts[0], (rx - lx) * 0.5f), lx, y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                Ui.textRight(c, ts[1], lx + (rx - lx) * 0.56f, y, tFaint);
                Ui.textRight(c, ts[2], lx + (rx - lx) * 0.78f, y, tFaint);
                tFaint.setColor(ratingColor(ts[3]));
                Ui.textRight(c, ts[3], rx, y, tFaint);
                y += Ui.dp(getContext(), 13);
            }
            y += Ui.dp(getContext(), 4);
        }

        if (!t.mapStats.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "地图数据");
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "地图", lx, y, tMeta);
            Ui.textRight(c, "出场", lx + (rx - lx) * 0.58f, y, tMeta);
            Ui.textRight(c, "CT", lx + (rx - lx) * 0.79f, y, tMeta);
            Ui.textRight(c, "T", rx, y, tMeta);
            y += Ui.dp(getContext(), 13);
            for (String[] ms : t.mapStats) {
                tRow.setColor(Ui.TEXT);
                Ui.text(c, Ui.fit(tRow, ms[0], (rx - lx) * 0.52f), lx, y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                Ui.textRight(c, ms[1], lx + (rx - lx) * 0.58f, y, tFaint);
                Ui.textRight(c, ms[2], lx + (rx - lx) * 0.79f, y, tFaint);
                Ui.textRight(c, ms[3], rx, y, tFaint);
                y += Ui.dp(getContext(), 13);
            }
            y += Ui.dp(getContext(), 4);
        }

        // 赛程：该赛事的比赛列表，可直接点进对应比赛
        if (store.detailLoading && !t.matchesLoaded) {
            tMeta.setColor(Ui.FAINT);
            Ui.text(c, "载入赛程…", lx, y + Ui.dp(getContext(), 4), tMeta);
            y += Ui.dp(getContext(), 16);
        } else if (!t.matches.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "赛程");
            String day = "";
            int shown = 0;
            for (Models.Match mm : t.matches) {
                if (shown++ > 40) break;
                String d = dateLabel(mm.start);
                if (!d.equals(day)) {
                    day = d;
                    tMeta.setColor(Ui.FAINT);
                    Ui.text(c, d, lx, y + Ui.dp(getContext(), 4), tMeta);
                    y += Ui.dp(getContext(), 14);
                }
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, hm(mm.start), lx, y, tFaint);
                tRow.setColor(mm.done() && mm.winner == 2 ? Ui.DIM : Ui.TEXT);
                String tn1 = Ui.fit(tRow, mm.t1, Ui.dp(getContext(), 74));
                Ui.text(c, tn1, lx + Ui.dp(getContext(), 28), y, tRow);
                tRow.setColor(mm.done() && mm.winner == 1 ? Ui.DIM : Ui.TEXT);
                String tn2 = Ui.fit(tRow, mm.t2, Ui.dp(getContext(), 74));
                Ui.text(c, tn2, lx + Ui.dp(getContext(), 108), y, tRow);
                if (mm.hasScore()) {
                    tFaint.setColor(mm.live() ? Ui.LIVE : 0xFF9AA4B2);
                    Ui.textRight(c, mm.s1 + ":" + mm.s2, rx, y, tFaint);
                }
                if (mm.id.length() > 0) {
                    hits.add(mm);
                    hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                            rx, y + Ui.dp(getContext(), 4) });
                }
                y += Ui.dp(getContext(), 15);
            }
            y += Ui.dp(getContext(), 2);
        }

        tFaint.setColor(Ui.FAINT);
        Ui.text(c, "数据来源 5EPlay", lx, y + Ui.dp(getContext(), 8), tFaint);
        y += Ui.dp(getContext(), 18);

        detailContentH = y - startY;
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    // ------------------------------------------------------------------ team page

    private void drawTeamDetail(Canvas c, float top, float bottom) {
        Models.TeamDetail t = store.detailTeam;
        if (t == null) { drawEmpty(c, store.today, top, bottom, "没有内容"); return; }
        if (t.name.length() == 0 && store.detailLoading) {
            drawSpinner(c, (top + bottom) / 2);
            return;
        }

        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - detailScroll + Ui.dp(getContext(), 14);   // clear of the top fade
        float startY = y;
        float lx = colL;
        float rx = colR;

        tTeam.setColor(Ui.TEXT);
        tTeam.setTextSize(Ui.sp(getContext(), 13f));
        Ui.text(c, Ui.fit(tTeam, t.name.length() == 0 ? "队伍" : t.name, rx - lx),
                lx, y + Ui.dp(getContext(), 10), tTeam);
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));
        y += Ui.dp(getContext(), 26);

        StringBuilder meta = new StringBuilder();
        if (t.rank.length() > 0) meta.append("HLTV #").append(t.rank);
        if (t.vrank.length() > 0) {
            if (meta.length() > 0) meta.append("   ");
            meta.append("VRS #").append(t.vrank);
        }
        if (meta.length() > 0) {
            tMeta.setColor(Ui.ACCENT);
            Ui.text(c, meta.toString(), lx, y, tMeta);
            y += Ui.dp(getContext(), 13);
        }
        StringBuilder sub = new StringBuilder();
        if (t.country.length() > 0) sub.append(t.country);
        if (t.region.length() > 0) {
            if (sub.length() > 0) sub.append(" · ");
            sub.append(t.region);
        }
        if (t.ageAvg.length() > 0) {
            if (sub.length() > 0) sub.append(" · ");
            sub.append("平均 ").append(t.ageAvg).append(" 岁");
        }
        if (sub.length() > 0) {
            tFaint.setColor(Ui.FAINT);
            Ui.text(c, Ui.fit(tFaint, sub.toString(), rx - lx), lx, y, tFaint);
            y += Ui.dp(getContext(), 13);
        }

        String rec = "";
        if (t.wins.length() > 0 || t.losses.length() > 0) {
            rec = t.wins + "胜 " + t.losses + "负";
            if (t.draws.length() > 0 && !"0".equals(t.draws)) rec += " " + t.draws + "平";
        }
        if (rec.length() > 0) y = row(c, lx, rx, y, "战绩", rec);
        if (t.winRate.length() > 0) y = row(c, lx, rx, y, "胜率", t.winRate);
        if (t.kdRatio.length() > 0) y = row(c, lx, rx, y, "KD", t.kdRatio);
        if (t.mapCount.length() > 0) y = row(c, lx, rx, y, "地图", t.mapCount + " 张");
        if (t.kills.length() > 0) {
            y = row(c, lx, rx, y, "击杀",
                    t.kills + (t.deaths.length() > 0 ? " / " + t.deaths + " 死" : ""));
        }
        if (t.coach.length() > 0) y = row(c, lx, rx, y, "教练", t.coach);
        if (t.bonus.length() > 0) y = row(c, lx, rx, y, "奖金", t.bonus);

        if (!t.maps.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 4), "地图池");
            for (String[] mp : t.maps) {
                if (y > bottom + 40) break;
                tRow.setColor(Ui.TEXT);
                tRow.setTextSize(Ui.sp(getContext(), 9.2f));
                Ui.text(c, Ui.fit(tRow, mp[0], Ui.dp(getContext(), 50)), lx, y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                String ct = mp[2].length() > 0 ? "CT" + mp[2] : "";
                String tt = mp[3].length() > 0 ? "T" + mp[3] : "";
                String side = (ct + (ct.length() > 0 && tt.length() > 0 ? " " : "") + tt);
                // the round dial gives a 154dp column: split it by measured widths,
                // not by fixed offsets, so the side split never runs into the win rate
                String wr = mp[1].length() == 0 ? "--" : mp[1];
                float sideX = lx + Ui.dp(getContext(), 52);
                float sideW = rx - tFaint.measureText(wr) - Ui.dp(getContext(), 5) - sideX;
                if (side.length() > 0 && sideW > 0) {
                    Ui.text(c, Ui.fit(tFaint, side, sideW), sideX, y, tFaint);
                }
                int col = mp[1].length() == 0 ? 0xFF9AA4B2 : winRateColor(mp[1]);
                tFaint.setColor(col);
                Ui.textRight(c, mp[1].length() == 0 ? "--" : mp[1], rx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!t.players.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 4), "阵容");
            for (Models.Player p : t.players) {
                if (y > bottom + 20) break;
                tRow.setColor(Ui.TEXT);
                tRow.setTextSize(Ui.sp(getContext(), 9.5f));
                float nameW = rx - lx - Ui.dp(getContext(), 62);
                Ui.text(c, Ui.fit(tRow, p.name, nameW), lx, y, tRow);
                tFaint.setColor(Ui.FAINT);
                Ui.textRight(c, p.position, rx, y, tFaint);
                if (p.id.length() > 0) {
                    hits.add(p);
                    hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                            rx, y + Ui.dp(getContext(), 4) });
                }
                y += Ui.dp(getContext(), 16);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!t.honors.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "荣誉");
            for (String[] h : t.honors) {
                if (y > bottom + 60) break;
                tFaint.setColor(Ui.FAINT);
                String when = h[0] == null ? "" : h[0];
                if (when.length() > 10) when = when.substring(0, 10);
                Ui.text(c, when, lx, y, tFaint);
                tRow.setColor(0xFFCED5E0);
                Ui.text(c, Ui.fit(tRow, h[2], rx - lx - Ui.dp(getContext(), 62)),
                        lx + Ui.dp(getContext(), 58), y, tRow);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!t.recent.isEmpty()) {
            y = sectionTitle(c, lx, rx, y + Ui.dp(getContext(), 2), "近期战绩");
            for (Models.TeamMatch tm : t.recent) {
                if (y > bottom + 80) break;
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, tm.date, lx, y, tFaint);
                tRow.setColor(tm.winner == 1 ? Ui.WIN : (tm.winner == 2 ? Ui.LIVE : 0xFF9AA4B2));
                Ui.text(c, tm.score, lx + Ui.dp(getContext(), 32), y, tRow);
                tFaint.setColor(0xFF8A93A1);
                String vs = tm.t2.length() == 0 ? "" : "vs " + tm.t2;
                Ui.text(c, Ui.fit(tFaint, vs, Ui.dp(getContext(), 82)), lx + Ui.dp(getContext(), 66), y, tFaint);
                tFaint.setColor(Ui.FAINT);
                Ui.textRight(c, Ui.fit(tFaint, tm.event, rx - lx - Ui.dp(getContext(), 152)), rx, y, tFaint);
                if (tm.id.length() > 0) {
                    hits.add(tm);
                    hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                            rx, y + Ui.dp(getContext(), 4) });
                }
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (store.detailError != null) {
            tMeta.setColor(Ui.LIVE);
            Ui.text(c, Ui.fit(tMeta, store.detailError, rx - lx), lx, y + Ui.dp(getContext(), 6), tMeta);
            y += Ui.dp(getContext(), 16);
        }

        tFaint.setColor(Ui.FAINT);
        Ui.text(c, "数据来源 5EPlay", lx, y + Ui.dp(getContext(), 10), tFaint);
        y += Ui.dp(getContext(), 18);

        detailContentH = y - startY;
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    // ------------------------------------------------------------------ player page

    private void drawPlayerDetail(Canvas c, float top, float bottom) {
        Models.PlayerDetail p = store.detailPlayer;
        if (p == null) { drawEmpty(c, store.today, top, bottom, "没有内容"); return; }
        if (p.name.length() == 0 && store.detailLoading) {
            drawSpinner(c, (top + bottom) / 2);
            return;
        }

        c.save();
        c.clipRect(0, top, w, bottom);
        float y = top - detailScroll + Ui.dp(getContext(), 14);   // clear of the top fade
        float startY = y;
        float lx = colL;
        float rx = colR;

        tTeam.setColor(Ui.TEXT);
        tTeam.setTextSize(Ui.sp(getContext(), 13f));
        Ui.text(c, Ui.fit(tTeam, p.name.length() == 0 ? "选手" : p.name, rx - lx),
                lx, y + Ui.dp(getContext(), 10), tTeam);
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));
        y += Ui.dp(getContext(), 25);

        if (p.team.length() > 0) {
            tSub.setColor(Ui.ACCENT);
            tSub.setTextSize(Ui.sp(getContext(), 10f));
            Ui.text(c, Ui.fit(tSub, p.team, rx - lx - Ui.dp(getContext(), 10)), lx, y, tSub);
            tSub.setTextSize(Ui.sp(getContext(), 10f));
            if (p.teamId.length() > 0) {
                hits.add("team");
                hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                        lx + tSub.measureText(p.team) + Ui.dp(getContext(), 8), y + Ui.dp(getContext(), 4) });
            }
            y += Ui.dp(getContext(), 13);
        }

        StringBuilder meta = new StringBuilder();
        if (p.position.length() > 0) meta.append(p.position);
        if (p.country.length() > 0) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append(p.country);
        }
        if (p.birthday.length() > 0) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append(p.birthday);
        }
        if (p.top20.length() > 0 && !"0".equals(p.top20)) {
            if (meta.length() > 0) meta.append(" · ");
            meta.append("TOP").append(p.top20);
        }
        if (meta.length() > 0) {
            tFaint.setColor(Ui.FAINT);
            Ui.text(c, Ui.fit(tFaint, meta.toString(), rx - lx), lx, y, tFaint);
            y += Ui.dp(getContext(), 13);
        }
        y += Ui.dp(getContext(), 2);

        // 核心数据两列
        y = sectionTitle(c, lx, rx, y, "数据");
        y = kv2(c, lx, rx, y, "RATING", p.rating, "KD", p.kd);
        y = kv2(c, lx, rx, y, "ADR", p.adr, "KAST", p.kast);
        y = kv2(c, lx, rx, y, "IMPACT", p.impact, "DPR", p.dpr);
        y = kv2(c, lx, rx, y, "KPR", p.kpr, "爆头", p.headshot);
        if (p.mapsPlayed.length() > 0 || p.roundsPlayed.length() > 0) {
            y = kv2(c, lx, rx, y, "地图", p.mapsPlayed, "回合", p.roundsPlayed);
        }
        if (p.kill.length() > 0 || p.death.length() > 0) {
            y = kv2(c, lx, rx, y, "击杀", p.kill, "死亡", p.death);
        }
        if (p.bonus.length() > 0) y = row(c, lx, rx, y, "奖金", p.bonus);
        y += Ui.dp(getContext(), 2);

        if (!p.maps.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "地图表现");
            for (String[] m : p.maps) {
                if (y > bottom + 60) break;
                tRow.setColor(Ui.TEXT);
                tRow.setTextSize(Ui.sp(getContext(), 9.2f));
                Ui.text(c, Ui.fit(tRow, m[0], Ui.dp(getContext(), 78)), lx, y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                String kd = m[2].length() > 0 ? m[2] : "--";
                Ui.text(c, "K-D " + kd, lx + Ui.dp(getContext(), 92), y, tFaint);
                float rating = parseFloat(m[1]);
                tFaint.setColor(rating >= 1.15f ? Ui.WIN : (rating > 0 && rating < 0.85f ? Ui.LIVE : 0xFF9AA4B2));
                Ui.textRight(c, m[1].length() == 0 ? "--" : m[1], rx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!p.weaponCate.isEmpty() || !p.weapons.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "武器偏好");
            for (String[] w : p.weaponCate) {
                if (y > bottom + 40) break;
                tRow.setColor(0xFFCED5E0);
                tRow.setTextSize(Ui.sp(getContext(), 9.2f));
                Ui.text(c, Ui.fit(tRow, w[0], Ui.dp(getContext(), 82)), lx, y, tRow);
                tFaint.setColor(0xFF9AA4B2);
                Ui.textRight(c, w[1], rx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            if (!p.weapons.isEmpty()) {
                StringBuilder sb = new StringBuilder();
                for (String[] w : p.weapons) {
                    if (sb.length() > 0) sb.append(" · ");
                    sb.append(w[0]);
                    if (w[1].length() > 0) sb.append(' ').append(w[1]);
                }
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, Ui.fit(tFaint, sb.toString(), rx - lx), lx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!p.clutches.isEmpty() || !p.killTypes.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "残局 / 回合");
            StringBuilder c1 = new StringBuilder(), c2 = new StringBuilder();
            for (String[] s : p.clutches) {
                if (c1.length() > 0) c1.append("  ");
                c1.append(s[0]).append(' ').append(s[1]);
            }
            for (String[] s : p.killTypes) {
                if (c2.length() > 0) c2.append("  ");
                c2.append(s[0]).append(' ').append(s[1]);
            }
            if (c1.length() > 0) {
                tRow.setColor(0xFFCED5E0);
                tRow.setTextSize(Ui.sp(getContext(), 8.8f));
                Ui.text(c, Ui.fit(tRow, c1.toString(), rx - lx), lx, y, tRow);
                y += Ui.dp(getContext(), 14);
            }
            if (c2.length() > 0) {
                tFaint.setColor(0xFF9AA4B2);
                Ui.text(c, Ui.fit(tFaint, c2.toString(), rx - lx), lx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!p.honors.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "生涯荣誉");
            for (String[] h : p.honors) {
                if (y > bottom + 140) break;
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, h[0], lx, y, tFaint);
                tRow.setColor("冠军".equals(h[2]) ? Ui.ACCENT : 0xFFCED5E0);
                Ui.text(c, Ui.fit(tRow, h[1], rx - lx - Ui.dp(getContext(), 116)),
                        lx + Ui.dp(getContext(), 54), y, tRow);
                tFaint.setColor(Ui.FAINT);
                Ui.textRight(c, h[2], rx, y, tFaint);
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (!p.recent.isEmpty()) {
            y = sectionTitle(c, lx, rx, y, "近期比赛");
            for (Models.TeamMatch tm : p.recent) {
                if (y > bottom + 80) break;
                tFaint.setColor(Ui.FAINT);
                Ui.text(c, tm.date, lx, y, tFaint);
                tRow.setColor(tm.winner == 1 ? Ui.WIN : (tm.winner == 2 ? Ui.LIVE : 0xFF9AA4B2));
                Ui.text(c, tm.score, lx + Ui.dp(getContext(), 32), y, tRow);
                tFaint.setColor(0xFF8A93A1);
                String vs = tm.t2.length() == 0 ? "" : "vs " + tm.t2;
                Ui.text(c, Ui.fit(tFaint, vs, Ui.dp(getContext(), 82)), lx + Ui.dp(getContext(), 66), y, tFaint);
                tFaint.setColor(Ui.FAINT);
                Ui.textRight(c, Ui.fit(tFaint, tm.event, rx - lx - Ui.dp(getContext(), 152)), rx, y, tFaint);
                if (tm.id.length() > 0) {
                    hits.add(tm);
                    hitRects.add(new float[] { lx - Ui.dp(getContext(), 4), y - Ui.dp(getContext(), 11),
                            rx, y + Ui.dp(getContext(), 4) });
                }
                y += Ui.dp(getContext(), 14);
            }
            y += Ui.dp(getContext(), 2);
        }

        if (store.detailError != null) {
            tMeta.setColor(Ui.LIVE);
            Ui.text(c, Ui.fit(tMeta, store.detailError, rx - lx), lx, y + Ui.dp(getContext(), 6), tMeta);
            y += Ui.dp(getContext(), 16);
        }

        tFaint.setColor(Ui.FAINT);
        Ui.text(c, "数据来源 5EPlay", lx, y + Ui.dp(getContext(), 10), tFaint);
        y += Ui.dp(getContext(), 18);

        detailContentH = y - startY;
        c.restore();
        Ui.fadeEdges(c, 0, top, w, bottom, Ui.dp(getContext(), 14));
    }

    /** label/value pair, two per line. */
    private float kv2(Canvas c, float lx, float rx, float y,
                      String k1, String v1, String k2, String v2) {
        float mid = lx + (rx - lx) * 0.5f;
        tFaint.setColor(Ui.FAINT);
        tFaint.setTextSize(Ui.sp(getContext(), 7.6f));
        Ui.text(c, k1, lx, y, tFaint);
        Ui.text(c, k2, mid, y, tFaint);
        tFaint.setTextSize(Ui.sp(getContext(), 8f));
        tRow.setColor(0xFFD5DBE5);
        tRow.setTextSize(Ui.sp(getContext(), 9.2f));
        Ui.text(c, v1.length() == 0 ? "--" : v1, lx, y + Ui.dp(getContext(), 11), tRow);
        Ui.text(c, v2.length() == 0 ? "--" : v2, mid, y + Ui.dp(getContext(), 11), tRow);
        return y + Ui.dp(getContext(), 24);
    }

    /** Rating band colour shared by every table: ≥1.15 green, <0.85 red, else neutral. */
    private int ratingColor(String s) {
        float r = parseFloat(s);
        return r >= 1.15f ? Ui.WIN : (r > 0 && r < 0.85f ? Ui.LIVE : 0xFF9AA4B2);
    }

    /** Win-rate colour: ≥55% green, ≤45% red, else neutral. */
    private int winRateColor(String s) {
        float r = parseFloat(s);
        return r >= 55f ? Ui.WIN : (r > 0 && r <= 45f ? Ui.LIVE : 0xFF9AA4B2);
    }

    private float row(Canvas c, float lx, float rx, float y, String label, String value) {
        tMeta.setColor(Ui.FAINT);
        Ui.text(c, label, lx, y, tMeta);
        tSub.setColor(0xFFCED5E0);
        String v = value == null ? "" : value;
        float avail = rx - lx - Ui.dp(getContext(), 32);
        tSub.setTextSize(Ui.sp(getContext(), 9.5f));
        Ui.text(c, Ui.fit(tSub, v, avail), lx + Ui.dp(getContext(), 28), y, tSub);
        return y + Ui.dp(getContext(), 16);
    }

    // ------------------------------------------------------------------ states

    private void drawSpinner(Canvas c, float cy) {
        float rot = (SystemClock.uptimeMillis() % 900) / 900f * 360f;
        float rr = Ui.dp(getContext(), 9);
        pArc.setColor(Ui.ACCENT);
        c.drawArc(new RectF(w / 2 - rr, cy - rr, w / 2 + rr, cy + rr), rot, 260, false, pArc);
        tMeta.setColor(Ui.FAINT);
        Ui.textCenter(c, "载入中", w / 2, cy + rr + Ui.dp(getContext(), 16), tMeta);
        postInvalidateOnAnimation();
    }

    private void drawEmpty(Canvas c, Store.Page p, float top, float bottom, String msg) {
        float cy = (top + bottom) / 2;
        tMeta.setColor(Ui.FAINT);
        Ui.textCenter(c, msg, w / 2, cy, tMeta);
    }

    private void drawMessage(Canvas c, Store.Page p, float top, float bottom) {
        float cy = (top + bottom) / 2;
        tTeam.setColor(Ui.DIM);
        tTeam.setTextSize(Ui.sp(getContext(), 10f));
        Ui.textCenter(c, "无法连接", w / 2, cy - Ui.dp(getContext(), 6), tTeam);
        tMeta.setColor(Ui.FAINT);
        float in = chordInset(cy, cy + Ui.dp(getContext(), 14));
        Ui.textCenter(c, Ui.fit(tMeta, p.error, w - in * 2), w / 2, cy + Ui.dp(getContext(), 10), tMeta);
        tTeam.setTextSize(Ui.sp(getContext(), 11.5f));
        hits.add("retry");
        hitRects.add(new float[] { 0, top, w, bottom });
    }

    // ------------------------------------------------------------------ labels

    static String hm(long ts) {
        if (ts <= 0) return "";
        return new SimpleDateFormat("HH:mm", Locale.getDefault()).format(new Date(ts));
    }

    static String dateLabel(long ts) {
        if (ts <= 0) return "";
        return new SimpleDateFormat("M月d日", Locale.getDefault()).format(new Date(ts));
    }

    static String timeLabel(long ts) {
        if (ts <= 0) return "";
        long now = System.currentTimeMillis();
        long d0 = DataLoader.startOfDay(now);
        long d1 = DataLoader.startOfDay(ts);
        String hhmm = hm(ts);
        if (d1 == d0) return hhmm;
        if (d1 == d0 + 24 * 3600_000L) return "明天 " + hhmm;
        if (d1 == d0 - 24 * 3600_000L) return "昨天 " + hhmm;
        return dateLabel(ts) + " " + hhmm;
    }

    // ------------------------------------------------------------------ input

    private Object pressed;
    private boolean refreshPressed;

    private Models.Match hitMatch(float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (o instanceof Models.Match) {
                float[] r = hitRects.get(i);
                if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (Models.Match) o;
            }
        }
        return null;
    }

    private Models.Tournament hitEvent(float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (o instanceof Models.Tournament) {
                float[] r = hitRects.get(i);
                if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (Models.Tournament) o;
            }
        }
        return null;
    }

    private Models.Player hitPlayer(float x, float y) {        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (!(o instanceof Models.Player)) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (Models.Player) o;
        }
        return null;
    }

    private Models.TeamMatch hitTeamMatch(float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (!(o instanceof Models.TeamMatch)) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (Models.TeamMatch) o;
        }
        return null;
    }

    private Models.RankRow hitRank(float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (!(o instanceof Models.RankRow)) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (Models.RankRow) o;
        }
        return null;
    }

    private TeamTap hitTeamTap(float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            Object o = hits.get(i);
            if (!(o instanceof TeamTap)) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return (TeamTap) o;
        }
        return null;
    }

    private boolean hitTag(float x, float y, String tag) {
        for (int i = 0; i < hits.size(); i++) {
            if (!tag.equals(hits.get(i))) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return true;
        }
        return false;
    }

    @Override public boolean onTouchEvent(MotionEvent e) {
        float x = e.getX(), y = e.getY();
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                lastTouchAt = SystemClock.uptimeMillis();
                if (dimmed) {         // first tap only wakes the panel
                    dimmed = false;
                    lastTouchAt = SystemClock.uptimeMillis();
                    if (idleListener != null) idleListener.onIdle(false);
                    invalidate();
                    return true;
                }
                flingSeq++;                 // stop any running fling before a new gesture
                downX = x; downY = y; lastY = y; moved = false;
                downScroll = currentScroll();
                vScroll = 0;
                downPos = pos;
                draggingH = false; draggingV = false;
                refreshPressed = hitRefresh(x, y);
                boolean chrome = refreshPressed || hitPill(x, y) || hitDot(x, y) >= 0
                        || (detailOpen && rBack.contains(x, y));
                if (!detailOpen && !chrome) pressed = hitMatch(x, y) != null ? hitMatch(x, y) : hitEvent(x, y);
                lastMoveTime = SystemClock.uptimeMillis();
                invalidate();
                return true;

            case MotionEvent.ACTION_MOVE: {
                lastTouchAt = SystemClock.uptimeMillis();
                float dx = x - downX, dy = y - downY;
                if (Math.abs(dx) > Ui.dp(getContext(), 5) || Math.abs(dy) > Ui.dp(getContext(), 5)) moved = true;
                if (!draggingH && !draggingV) {
                    if (Math.abs(dx) > Math.abs(dy) * 1.2f && Math.abs(dx) > Ui.dp(getContext(), 6) && !detailOpen) {
                        draggingH = true;
                        pressed = null;
                    } else if (Math.abs(dy) > Ui.dp(getContext(), 6)) {
                        draggingV = true;
                        pressed = null;
                    }
                }
                if (draggingH) {
                    pos = clamp(downPos - dx / w, 0, TABS.length - 1);
                } else if (draggingV) {
                    long now = SystemClock.uptimeMillis();
                    float d = lastY - y;
                    if (Math.abs(d) > 120) d = d > 0 ? 120 : -120;   // one janky frame must not jump
                    setScroll(currentScroll() + (int) d);
                    float dt = Math.max(1, now - lastMoveTime);
                    // smoothed velocity in px per 16 ms frame
                    vScroll = vScroll * 0.6f + (d / dt * 16f) * 0.4f;
                    lastY = y;
                    lastMoveTime = now;
                }
                invalidate();
                return true;
            }

            case MotionEvent.ACTION_UP:
            case MotionEvent.ACTION_CANCEL: {
                float totalDx = x - downX, totalDy = y - downY;
                // Fast flicks can arrive as a single MOVE (or none); fall back to the
                // total travel so a quick swipe is never mistaken for a tap.
                if (!draggingH && !draggingV && !detailOpen
                        && Math.abs(totalDx) > Ui.dp(getContext(), 6)
                        && Math.abs(totalDx) > Math.abs(totalDy)) {
                    draggingH = true;
                } else if (!draggingH && !draggingV
                        && Math.abs(totalDy) > Ui.dp(getContext(), 6)) {
                    draggingV = true;
                    setScroll((int) (downScroll - totalDy));
                    vScroll = 0;
                }
                if (draggingH) {
                    float dx = x - downX;
                    float th = w * 0.18f;
                    if (dx < -th) tab = Math.min(TABS.length - 1, tab + 1);
                    else if (dx > th) tab = Math.max(0, tab - 1);
                    else tab = Math.max(0, Math.min(TABS.length - 1, Math.round(pos)));
                    pos = tab;
                    postInvalidateOnAnimation();
                    DataLoader.refreshIfNeeded(getContext(), store, TABS[tab]);
                } else if (draggingV) {
                    fling(vScroll);
                    maybeLoadMore();
                } else if (!moved) {
                    tap(x, y);
                }
                draggingH = false; draggingV = false;
                pressed = null;
                refreshPressed = false;
                return true;
            }
        }
        return super.onTouchEvent(e);
    }

    private static float clamp(float v, float lo, float hi) {
        return v < lo ? lo : (v > hi ? hi : v);
    }

    private void tap(float x, float y) {
        if (detailOpen) {
            if (rBack.contains(x, y)) {
                if (!DataLoader.popFrame(getContext(), store)) closeDetail();
                else { detailScroll = 0; detailContentH = 0; invalidate(); }
                return;
            }
            if (hitRefresh(x, y)) {
                DataLoader.refreshDetail(getContext(), store, true);
                return;
            }
            // inside a detail page: team names, roster rows, recent matches
            for (int i = 0; i < 12; i++) {
                if (hitTag(x, y, "map:" + i)) {
                    mapExpand = mapExpand == i ? -1 : i;
                    detailContentH = 0;
                    invalidate();
                    return;
                }
            }
            Models.Match dm = hitMatch(x, y);
            if (dm != null && dm.id.length() > 0) { openMatchFromDetail(dm); return; }
            Models.Player pl = hitPlayer(x, y);
            if (pl != null) { openPlayer(pl.id, pl.name); return; }
            Models.TeamMatch tm = hitTeamMatch(x, y);
            if (tm != null && tm.id.length() > 0) { openMatchById(tm.id, tm.t1, tm.t2); return; }
            if (hitTag(x, y, "t1team")) { openTeamOf(store.detail, 1); return; }
            if (hitTag(x, y, "t2team")) { openTeamOf(store.detail, 2); return; }
            if (hitTag(x, y, "event")) { openEventOf(store.detail); return; }
            TeamTap tt = hitTeamTap(x, y);
            if (tt != null) { openTeam(tt.id, tt.name); return; }
            if (hitTag(x, y, "team")) {
                Models.PlayerDetail pd = store.detailPlayer;
                if (pd != null) openTeam(pd.teamId, pd.team);
                return;
            }
            return;
        }
        // Rim controls first: they sit over the ends of the list, and a card that is
        // only partly visible still owns a hit rect reaching under them.
        if (hitRefresh(x, y)) {
            DataLoader.refresh(getContext(), store, TABS[tab], true);
            kick();
            return;
        }
        if (hitPill(x, y)) {
            if (TABS[tab] == Store.Tab.RANK) {
                DataLoader.setRankType(getContext(), store, (store.rankType + 1) % 4);
            } else if (TABS[tab] == Store.Tab.EVENTS) {
                store.eventTier = (store.eventTier + 1) % 3;
                store.events.scrollY = 0;
                store.notifyChanged();
                invalidate();
            } else if (store.tierTab(TABS[tab])) {
                store.matchTier = (store.matchTier + 1) % 3;
                store.page(TABS[tab]).scrollY = 0;
                store.notifyChanged();
                invalidate();
            }
            return;
        }
        int dot = hitDot(x, y);
        if (dot >= 0) {
            tab = dot; pos = dot; invalidate();
            DataLoader.refreshIfNeeded(getContext(), store, TABS[dot]);
            return;
        }
        if (TABS[tab] == Store.Tab.RANK) {
            Models.RankRow rr = hitRank(x, y);
            if (rr != null) {
                if (store.rankType >= 2) openPlayer(rr.id, rr.name);
                else openTeam(rr.id, rr.name);
                return;
            }
        }
        Models.Match m = hitMatch(x, y);
        if (m != null) { openDetail(m); return; }
        Models.Tournament t = hitEvent(x, y);
        if (t != null) { openEvent(t); return; }
        if (hitTag(x, y, "retry")) {
            DataLoader.refresh(getContext(), store, TABS[tab], true);
            return;
        }
        DataLoader.refreshIfNeeded(getContext(), store, TABS[tab]);
    }

    /** Pull the next page once the user reaches the bottom of a long list. */
    private void maybeLoadMore() {
        if (detailOpen) return;
        Store.Page p = page(TABS[tab]);
        if (p.loading) return;
        int max = maxScroll();
        if (max <= 0) return;
        if (p.scrollY >= max - Ui.dp(getContext(), 24)) {
            if (p.tab == Store.Tab.RESULTS && p.hasMore) DataLoader.loadMore(getContext(), store, TABS[tab]);
            else if (p.tab == Store.Tab.EVENTS && store.eventHasMore) DataLoader.loadMoreEvents(getContext(), store);
            else if (p.tab == Store.Tab.RANK) DataLoader.loadMoreRank(getContext(), store);
        }
    }

    private void openDetail(Models.Match m) {
        mapExpand = -1;
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openMatchDetail(getContext(), store, m);
        invalidate();
    }

    private void openEvent(Models.Tournament t) {
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openEventDetail(getContext(), store, t);
        invalidate();
    }

    /** Drill into a team page from whatever detail is currently open. */
    private void openTeam(String teamId, String knownName) {
        if (teamId == null || teamId.length() == 0) return;
        DataLoader.pushFrame(store);
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openTeamDetail(getContext(), store, teamId, knownName);
        invalidate();
    }

    private void openTeamOf(Models.Match m, int side) {
        if (m == null) return;
        openTeam(side == 1 ? m.t1Id : m.t2Id, side == 1 ? m.t1 : m.t2);
    }

    private void openPlayer(String playerId, String knownName) {
        if (playerId == null || playerId.length() == 0) return;
        DataLoader.pushFrame(store);
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openPlayerDetail(getContext(), store, playerId, knownName);
        invalidate();
    }

    /** Jump from a match into the tournament that hosts it (event name in the detail page). */
    private void openEventOf(Models.Match m) {
        if (m == null || m.ttId.length() == 0) return;
        Models.Tournament t = new Models.Tournament();
        t.id = m.ttId;
        t.name = m.event == null ? "" : m.event;
        t.status = m.live() ? "live" : (m.done() ? "past" : "upcoming");
        t.start = m.start;
        t.tier = m.tier;
        DataLoader.pushFrame(store);
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openEventDetail(getContext(), store, t);
        invalidate();
    }

    /** A recent-result row only carries the id, so build a stub match for the page. */
    private void openMatchById(String matchId, String t1, String t2) {
        Models.Match m = new Models.Match();
        m.id = matchId;
        m.t1 = t1 == null ? "" : t1;
        m.t2 = t2 == null ? "" : t2;
        m.status = "completed";
        openDetail(m);
    }

    /** A finished match listed inside an event page keeps its real payload. */
    private void openMatchFromDetail(Models.Match m) {
        DataLoader.pushFrame(store);
        mapExpand = -1;
        detailScroll = 0;
        detailContentH = 0;
        detailOpen = true;
        DataLoader.openMatchDetail(getContext(), store, m);
        invalidate();
    }

    private void closeDetail() {
        mapExpand = -1;
        detailOpen = false;
        store.detail = null;
        store.detailData = null;
        store.detailEvent = null;
        store.detailTeam = null;
        store.detailPlayer = null;
        store.navStack.clear();
        invalidate();
    }

    public boolean handleBack() {
        if (detailOpen) {
            if (!DataLoader.popFrame(getContext(), store)) closeDetail();
            else { detailScroll = 0; detailContentH = 0; invalidate(); }
            return true;
        }
        if (tab != 0) { tab = 0; pos = 0; invalidate(); return true; }
        return false;
    }

    private int currentScroll() {
        return detailOpen ? detailScroll : page(TABS[tab]).scrollY;
    }

    private void setScroll(int v) {
        int max = maxScroll();
        int min = minScroll();
        if (v > max) v = max;
        if (v < min) v = min;
        if (detailOpen) detailScroll = v;
        else page(TABS[tab]).scrollY = v;
    }

    /** Row height used for the round-dial scroll padding of the current list. */
    private float itemH(Store.Tab t) {
        if (t == Store.Tab.EVENTS) return Ui.dp(getContext(), 46);
        if (t == Store.Tab.RANK) return Ui.dp(getContext(), 30);
        return cardH;
    }

    /**
     * Lists may scroll to a negative offset so the first item can be pulled down to
     * the wide middle of the dial; maxScroll() adds the mirror pad at the end.
     */
    private int minScroll() {
        if (detailOpen) return 0;
        float item = itemH(page(TABS[tab]).tab);
        return -(int) Math.max(0, (cy0 - item / 2f) - contentTop);
    }

    private int maxScroll() {
        if (detailOpen) return (int) Math.max(0, detailContentH + Ui.dp(getContext(), 28) - (detailBottom - detailTop));
        float view = contentBottom - contentTop;
        Store.Page p = page(TABS[tab]);
        float pad = Math.max(0, contentBottom - (cy0 + itemH(p.tab) / 2f));
        if (p.tab == Store.Tab.EVENTS) {
            return (int) (Math.max(0, store.eventsFiltered().size() * Ui.dp(getContext(), 46) - view) + pad);
        }
        if (p.tab == Store.Tab.RANK) {
            return (int) (Math.max(0, p.ranks.size() * Ui.dp(getContext(), 30) - view) + pad);
        }
        float total = 0;
        for (Models.Match m : store.matchesOf(p.tab)) {
            total += ((m.maps.isEmpty() && !m.hasScore()) ? cardHNoMap : cardH) + cardGap;
        }
        return (int) (Math.max(0, total - cardGap - view) + pad);
    }

    /**
     * A flick scrolls the content in the direction the finger moved: a swipe up
     * (positive vScroll) must INCREASE the scroll offset. Getting this sign wrong
     * is what made the list bounce back on its own.
     */
    private void fling(float vel) {
        if (vel > 60f) vel = 60f;
        if (vel < -60f) vel = -60f;
        if (Math.abs(vel) < 1f) return;
        final boolean wasDetail = detailOpen;
        final int seq = ++flingSeq;
        final float[] state = new float[] { vel, SystemClock.uptimeMillis() };
        H.postDelayed(new Runnable() {
            @Override public void run() { step(state, wasDetail, seq); }
        }, 16);
    }

    private void step(final float[] st, final boolean wasDetail, final int seq) {
        if (seq != flingSeq) return;
        long now = SystemClock.uptimeMillis();
        float dt = Math.max(1f, now - st[1]);
        st[1] = now;
        st[0] = (float) (st[0] * Math.pow(0.93, dt / 16.0));
        if (Math.abs(st[0]) < 0.6f) return;
        Store.Page p = page(TABS[tab]);
        int sc = wasDetail ? detailScroll : p.scrollY;
        int max = maxScroll();
        int min = minScroll();
        int next = (int) (sc + st[0]);
        boolean hitEdge = next < min || next > max;
        if (next < min) next = min;
        if (next > max) next = max;
        if (wasDetail) detailScroll = next; else p.scrollY = next;
        invalidate();
        if (!hitEdge) {
            H.postDelayed(new Runnable() {
                @Override public void run() { step(st, wasDetail, seq); }
            }, 16);
        }
    }
}
