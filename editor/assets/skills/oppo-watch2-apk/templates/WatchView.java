package com.example.watchapp;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.graphics.RectF;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.TextPaint;
import android.view.MotionEvent;
import android.view.View;

import java.util.ArrayList;
import java.util.List;

/**
 * Minimal self-drawn watch UI: N pages, a vertical card list per page, footer dots.
 *
 * Everything is drawn by hand because the screen is only 186x215 dp and the
 * system widgets waste most of it. Copy this file and replace `Page.items` with
 * real data; the gesture handling, fling physics, hit testing and burn-in guard
 * are the parts worth keeping verbatim.
 */
public class WatchView extends View {

    /** Replace with your own rows. */
    public static final class Row {
        public String title = "";
        public String subtitle = "";
        public String right = "";
        public int accent = 0;
    }

    public static final class Page {
        public final String title;
        public final List<Row> items = new ArrayList<>();
        public int scrollY;
        public Page(String t) { title = t; }
    }

    // ------------------------------------------------------------------ layout

    private static final float CARD_H = 60f;      // dp
    private static final float CARD_GAP = 6f;     // dp
    private static final float CONTENT_TOP = 36f; // dp
    private static final float CONTENT_BOTTOM = 18f;

    private static final int C_BG_TOP = 0xFF0B0E13;
    private static final int C_BG_BOTTOM = 0xFF05070A;
    private static final int C_CARD = 0xFF13171F;
    private static final int C_STROKE = 0xFF1F2632;
    private static final int C_TEXT = 0xFFF3F6FA;
    private static final int C_DIM = 0xFF8B95A5;
    private static final int C_FAINT = 0xFF5B6472;
    private static final int C_ACCENT = 0xFFFF7A1A;
    private static final int C_LIVE = 0xFFFF4D5E;

    private final float w, h, padX;
    private final float contentTop, contentBottom;
    private final float cardH, cardGap;

    private final List<Page> pages = new ArrayList<>();
    private int tab;
    private float pos;                 // pager position, fractional while dragging
    private float downX, downY, downPos, downScroll;
    private float scroll, vScroll;
    private boolean draggingH, draggingV, moved;
    private float lastY;
    private long lastMoveTime;

    private final Paint pCard = fill(C_CARD);
    private final Paint pStroke = stroke(C_STROKE, 1f);
    private final Paint pAccent = fill(C_ACCENT);
    private final Paint pDot = fill(C_ACCENT);
    private final Paint pBlack = fill(0xFF000000);
    /** Background gradient; built once in the constructor, never per frame. */
    private final Paint pBg = fill(C_BG_TOP);
    private final RectF rCard = new RectF();
    private final RectF rRefresh = new RectF();
    private final RectF rBack = new RectF();

    private final TextPaint tTitle, tRow, tSub, tFaint;

    // hit testing: parallel lists, index-aligned
    private final List<Object> hits = new ArrayList<>();
    private final List<float[]> hitRects = new ArrayList<>();

    private boolean detailOpen;
    private int detailScroll;
    private float detailContentH;
    private int detailIndex = -1;

    // burn-in guard
    public interface IdleListener { void onIdle(boolean idle); }
    private IdleListener idleListener;
    private static final long IDLE_DIM_MS = 60_000L;
    private long lastTouchAt = SystemClock.uptimeMillis();
    private boolean dimmed;
    private final Handler H = new Handler(Looper.getMainLooper());
    private final Runnable idleCheck = new Runnable() {
        @Override public void run() {
            if (!dimmed && SystemClock.uptimeMillis() - lastTouchAt > IDLE_DIM_MS) {
                dimmed = true;
                if (idleListener != null) idleListener.onIdle(true);
                invalidate();
            }
            H.postDelayed(this, dimmed ? 30_000L : 10_000L);
        }
    };

    public WatchView(Context c) {
        super(c);
        w = c.getResources().getDisplayMetrics().widthPixels;
        h = c.getResources().getDisplayMetrics().heightPixels;
        padX = dp(14);
        contentTop = dp(CONTENT_TOP);
        contentBottom = h - dp(CONTENT_BOTTOM);
        cardH = dp(CARD_H);
        cardGap = dp(CARD_GAP);

        tTitle = text(13.5f, C_TEXT, Paint.ANTI_ALIAS_FLAG);
        tRow = text(11.5f, C_TEXT, Paint.ANTI_ALIAS_FLAG);
        tSub = text(9f, C_DIM, Paint.ANTI_ALIAS_FLAG);
        tFaint = text(8f, C_FAINT, Paint.ANTI_ALIAS_FLAG);

        pBg.setShader(new android.graphics.LinearGradient(0, 0, 0, h,
                C_BG_TOP, C_BG_BOTTOM, android.graphics.Shader.TileMode.CLAMP));

        H.postDelayed(idleCheck, 5_000L);
    }

    public void setIdleListener(IdleListener l) { idleListener = l; }

    public void addPage(Page p) { pages.add(p); invalidate(); }

    public void setRows(int pageIndex, List<Row> rows) {
        pages.get(pageIndex).items.clear();
        pages.get(pageIndex).items.addAll(rows);
        pages.get(pageIndex).scrollY = 0;
        invalidate();
    }

    // ------------------------------------------------------------------ drawing

    @Override protected void onDraw(Canvas c) {
        c.drawRect(0, 0, w, h, pBg);
        hits.clear();
        hitRects.clear();
        if (pages.isEmpty()) return;

        if (detailOpen) drawDetail(c);
        else {
            drawHeader(c, pages.get(Math.round(pos)).title);
            drawList(c, pages.get(Math.round(pos)));
            drawFooter(c);
        }
        if (dimmed) {
            // Dimming the window attribute is not enough on every ROM: paint black too.
            c.drawRect(0, 0, w, h, pBlack);
        }
        postInvalidateOnAnimation();
    }

    private void drawHeader(Canvas c, String title) {
        tTitle.setColor(C_TEXT);
        c.drawText(title, padX, dp(24), tTitle);

        // refresh glyph, top-right
        float cx = w - padX - dp(6), cy = dp(19), s = dp(5);
        pStroke.setColor(C_DIM);
        c.drawCircle(cx, cy, s, pStroke);
        rRefresh.set(cx - dp(12), cy - dp(12), cx + dp(12), cy + dp(12));
        hits.add("refresh");
        hitRects.add(new float[] { rRefresh.left, rRefresh.top, rRefresh.right, rRefresh.bottom });
    }

    private void drawList(Canvas c, Page p) {
        c.save();
        c.clipRect(0, contentTop, w, contentBottom);
        float y = contentTop - p.scrollY;
        float cw = w - padX * 2;
        for (Row r : p.items) {
            if (y + cardH > contentTop - 4 && y < contentBottom + 4) {
                drawCard(c, r, padX, y, cw, cardH);
                hits.add(r);
                hitRects.add(new float[] { padX, y, padX + cw, y + cardH });
            }
            y += cardH + cardGap;
            if (y > contentBottom + 240) break;
        }
        c.restore();
    }

    private void drawCard(Canvas c, Row r, float x, float y, float cw, float ch) {
        rCard.set(x, y, x + cw, y + ch);
        c.drawRoundRect(rCard, dp(11), dp(11), pCard);
        c.drawRoundRect(rCard, dp(11), dp(11), pStroke);
        if (r.accent != 0) {
            pAccent.setColor(r.accent);
            c.drawRoundRect(new RectF(x, y + dp(6), x + dp(2.6f), y + ch - dp(6)),
                    dp(1.3f), dp(1.3f), pAccent);
        }
        tFaint.setColor(C_FAINT);
        c.drawText(fit(tFaint, r.subtitle, cw - dp(24)), x + dp(9), y + dp(16), tFaint);
        tFaint.setColor(C_DIM);
        c.drawText(r.right, x + cw - dp(9) - tFaint.measureText(r.right), y + dp(16), tFaint);

        tRow.setColor(C_TEXT);
        c.drawText(fit(tRow, r.title, cw - dp(20)), x + dp(9), y + dp(34), tRow);
    }

    private void drawFooter(Canvas c) {
        float cy = h - dp(9), gap = dp(9);
        float x = w / 2f - gap * (pages.size() - 1) / 2f;
        for (int i = 0; i < pages.size(); i++) {
            boolean on = Math.abs(pos - i) < 0.5f;
            pDot.setColor(on ? C_ACCENT : 0xFF2A3140);
            c.drawCircle(x + i * gap, cy, on ? dp(2.3f) : dp(1.6f), pDot);
        }
    }

    private void drawDetail(Canvas c) {
        // Back chevron, top-left.
        float cx = padX + dp(3), cy = dp(19);
        pStroke.setColor(C_DIM);
        c.drawLine(cx + dp(3), cy - dp(5), cx - dp(2), cy, pStroke);
        c.drawLine(cx - dp(2), cy, cx + dp(3), cy + dp(5), pStroke);
        pStroke.setColor(C_STROKE);
        rBack.set(0, 0, padX + dp(22), dp(34));
        hits.add("back");
        hitRects.add(new float[] { rBack.left, rBack.top, rBack.right, rBack.bottom });

        c.save();
        c.clipRect(0, contentTop, w, contentBottom);
        float y = contentTop - detailScroll;
        float startY = y;
        Row r = detailIndex >= 0 && detailIndex < pages.get(Math.round(pos)).items.size()
                ? pages.get(Math.round(pos)).items.get(detailIndex) : null;
        if (r != null) {
            tTitle.setColor(C_TEXT);
            c.drawText(fit(tTitle, r.title, w - padX * 2), padX, y + dp(10), tTitle);
            y += dp(26);
            tSub.setColor(C_DIM);
            c.drawText(r.subtitle, padX, y, tSub);
            y += dp(16);
            tSub.setColor(C_TEXT);
            c.drawText(r.right, padX, y, tSub);
            y += dp(16);
        }
        detailContentH = y - startY;
        c.restore();
    }

    // ------------------------------------------------------------------ input

    @Override public boolean onTouchEvent(MotionEvent e) {
        lastTouchAt = SystemClock.uptimeMillis();
        if (dimmed) {
            dimmed = false;
            if (idleListener != null) idleListener.onIdle(false);
            invalidate();
            return true;
        }
        float x = e.getX(), y = e.getY();
        switch (e.getActionMasked()) {
            case MotionEvent.ACTION_DOWN:
                downX = x; downY = y; lastY = y;
                downPos = pos;
                downScroll = detailOpen ? detailScroll : pages.get(Math.round(pos)).scrollY;
                vScroll = 0;
                lastMoveTime = e.getEventTime();
                moved = false; draggingH = false; draggingV = false;
                return true;
            case MotionEvent.ACTION_MOVE: {
                float dx = x - downX, dy = y - downY;
                if (!moved && Math.abs(dx) > dp(8) && Math.abs(dx) > Math.abs(dy)) {
                    draggingH = true; moved = true;
                } else if (!moved && Math.abs(dy) > dp(8)) {
                    draggingV = true; moved = true;
                }
                if (draggingH) {
                    pos = clamp(downPos - dx / w, 0, pages.size() - 1);
                } else if (draggingV) {
                    long dt = Math.max(1, e.getEventTime() - lastMoveTime);
                    vScroll = (y - lastY) / dt * 16f;
                    lastY = y;
                    lastMoveTime = e.getEventTime();
                    setScroll(downScroll + (downY - y));
                }
                postInvalidateOnAnimation();
                return true;
            }
            case MotionEvent.ACTION_UP:
                if (draggingH) {
                    tab = clampInt(Math.round(pos + (pos - downPos > 0.2f ? 1 : pos - downPos < -0.2f ? -1 : 0)),
                            0, pages.size() - 1);
                    pos = tab;
                } else if (draggingV) {
                    fling(vScroll);
                } else if (!moved) {
                    tap(x, y);
                }
                draggingH = false; draggingV = false;
                return true;
        }
        return super.onTouchEvent(e);
    }

    private void tap(float x, float y) {
        if (detailOpen) {
            if (hit("back", x, y)) { detailOpen = false; detailScroll = 0; invalidate(); return; }
            return;
        }
        if (hit("refresh", x, y)) { /* reload current page */ return; }

        // Footer dots win over card rects: a partly visible card still owns a rect
        // that reaches past the content area.
        if (y > contentBottom) {
            float gap = dp(9);
            float sx = w / 2f - gap * (pages.size() - 1) / 2f;
            for (int i = 0; i < pages.size(); i++) {
                if (Math.abs(x - (sx + i * gap)) < dp(8)) { tab = i; pos = i; invalidate(); return; }
            }
        }
        for (int i = 0; i < hits.size(); i++) {
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) {
                if (hits.get(i) instanceof Row) {
                    detailIndex = pages.get(Math.round(pos)).items.indexOf(hits.get(i));
                    detailOpen = true;
                    detailScroll = 0;
                    invalidate();
                    return;
                }
            }
        }
    }

    private boolean hit(String tag, float x, float y) {
        for (int i = 0; i < hits.size(); i++) {
            if (!tag.equals(hits.get(i))) continue;
            float[] r = hitRects.get(i);
            if (x >= r[0] && x <= r[2] && y >= r[1] && y <= r[3]) return true;
        }
        return false;
    }

    private void setScroll(float v) {
        if (detailOpen) {
            int max = Math.max(0, (int) (detailContentH - (contentBottom - contentTop)));
            detailScroll = clampInt(Math.round(v), 0, max);
        }
        else {
            Page p = pages.get(Math.round(pos));
            p.scrollY = clampInt(Math.round(v), 0, maxScroll(p));
        }
    }

    private int maxScroll(Page p) {
        float content = p.items.size() * (cardH + cardGap) - cardGap;
        return Math.max(0, Math.round(content - (contentBottom - contentTop)));
    }

    /** Inertia: decay per frame, stop at the borders without any overscroll bounce. */
    private void fling(final float v0) {
        vScroll = v0;
        H.post(new Runnable() {
            @Override public void run() {
                float v = vScroll;
                if (Math.abs(v) < 0.6f) { vScroll = 0; return; }
                vScroll = v * 0.93f;
                float cur = detailOpen ? detailScroll : pages.get(Math.round(pos)).scrollY;
                setScroll(cur + v);           // NOTE: "+", not "-": a sign flip here
                postInvalidateOnAnimation(); // shows up as a spring-like bounce.
                H.postDelayed(this, 16);
            }
        });
    }

    // ------------------------------------------------------------------ helpers

    private float dp(float v) { return v * getResources().getDisplayMetrics().density; }

    /**
     * Consume the system back key. Return true when the view handled it; the
     * activity then skips super.onBackPressed() instead of closing.
     */
    public boolean handleBack() {
        if (detailOpen) {
            detailOpen = false;
            detailScroll = 0;
            invalidate();
            return true;
        }
        return false;
    }

    private TextPaint text(float sp, int color, int flags) {
        TextPaint p = new TextPaint(flags);
        p.setTextSize(sp * getResources().getDisplayMetrics().scaledDensity);
        p.setColor(color);
        return p;
    }

    private static Paint fill(int color) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(color);
        p.setStyle(Paint.Style.FILL);
        return p;
    }

    private static Paint stroke(int color, float width) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setColor(color);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(width);
        return p;
    }

    /** Squeeze the text into maxW by ellipsizing, never by wrapping into the next column. */
    private static String fit(TextPaint p, String s, float maxW) {
        if (s == null) return "";
        if (p.measureText(s) <= maxW) return s;
        String ell = "…";
        int lo = 0, hi = s.length();
        while (lo < hi) {
            int mid = (lo + hi + 1) / 2;
            if (p.measureText(s.substring(0, mid) + ell) <= maxW) lo = mid; else hi = mid - 1;
        }
        return s.substring(0, Math.max(0, lo)) + ell;
    }

    private static float clamp(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
    private static int clampInt(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
}
