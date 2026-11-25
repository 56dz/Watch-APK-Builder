package com.dsh.cs2watch.round;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.RectF;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.text.TextPaint;
import android.text.TextUtils;
import android.util.TypedValue;

/** Drawing helpers plus the visual language of the app (dark, one accent). */
public final class Ui {

    public static final int BG_TOP = 0xFF0B0E13;
    public static final int BG_BOTTOM = 0xFF05070A;
    public static final int CARD = 0xFF13171F;
    public static final int CARD_HI = 0xFF1A1F29;
    public static final int STROKE = 0xFF1F2632;
    public static final int TEXT = 0xFFF3F6FA;
    public static final int DIM = 0xFF8B95A5;
    public static final int FAINT = 0xFF5B6472;
    public static final int ACCENT = 0xFFFF7A1A;
    public static final int LIVE = 0xFFFF4D5E;
    public static final int WIN = 0xFF3DDC97;

    public static final Typeface REG = Typeface.create("sans-serif", Typeface.NORMAL);
    public static final Typeface MED = Typeface.create("sans-serif-medium", Typeface.NORMAL);
    public static final Typeface BOLD = Typeface.create("sans-serif", Typeface.BOLD);

    private Ui() {}

    public static float dp(Context c, float v) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v,
                c.getResources().getDisplayMetrics());
    }

    public static float sp(Context c, float v) {
        return TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, v,
                c.getResources().getDisplayMetrics());
    }

    public static TextPaint text(Context c, float size, int color, Typeface tf) {
        TextPaint p = new TextPaint(Paint.ANTI_ALIAS_FLAG);
        p.setTextSize(sp(c, size));
        p.setColor(color);
        p.setTypeface(tf);
        p.setSubpixelText(true);
        return p;
    }

    public static Paint fill(int color) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setStyle(Paint.Style.FILL);
        p.setColor(color);
        return p;
    }

    public static Paint stroke(int color, float w) {
        Paint p = new Paint(Paint.ANTI_ALIAS_FLAG);
        p.setStyle(Paint.Style.STROKE);
        p.setStrokeWidth(w);
        p.setColor(color);
        p.setStrokeCap(Paint.Cap.ROUND);
        p.setStrokeJoin(Paint.Join.ROUND);
        return p;
    }

    /** Trim with an ellipsis so the string always fits maxWidth px. */
    public static String fit(TextPaint p, String s, float maxWidth) {
        if (s == null || s.length() == 0) return "";
        if (p.measureText(s) <= maxWidth) return s;
        return TextUtils.ellipsize(s, p, maxWidth, TextUtils.TruncateAt.END).toString();
    }

    public static void text(Canvas c, String s, float x, float y, TextPaint p) {
        if (s != null && s.length() > 0) c.drawText(s, x, y, p);
    }

    public static void textRight(Canvas c, String s, float right, float y, TextPaint p) {
        if (s != null && s.length() > 0) c.drawText(s, right - p.measureText(s), y, p);
    }

    public static void textCenter(Canvas c, String s, float cx, float y, TextPaint p) {
        if (s != null && s.length() > 0) c.drawText(s, cx - p.measureText(s) / 2f, y, p);
    }

    public static void bg(Canvas c, int w, int h) {
        Paint p = new Paint();
        p.setShader(new LinearGradient(0, 0, 0, h, BG_TOP, BG_BOTTOM, Shader.TileMode.CLAMP));
        c.drawRect(0, 0, w, h, p);
    }

    /** Fade the scrolling content into the background at its top / bottom edge. */
    public static void fadeEdges(Canvas c, float l, float t, float r, float b, float py) {
        Paint p = new Paint();
        p.setShader(new LinearGradient(0, t, 0, t + py, BG_TOP, 0x00000000, Shader.TileMode.CLAMP));
        c.drawRect(l, t, r, t + py, p);
        p = new Paint();
        p.setShader(new LinearGradient(0, b - py, 0, b, 0x00000000, 0xFF05070A, Shader.TileMode.CLAMP));
        c.drawRect(l, b - py, r, b, p);
    }

    public static void refreshGlyph(Canvas c, float cx, float cy, float r, int color, float rot) {
        Paint p = stroke(color, Math.max(1.6f, r * 0.24f));
        c.drawArc(new RectF(cx - r, cy - r, cx + r, cy + r), rot, 280, false, p);
        double a = Math.toRadians(rot + 290);
        float ax = (float) (cx + r * Math.cos(a));
        float ay = (float) (cy + r * Math.sin(a));
        Path path = new Path();
        float s = r * 0.66f;
        path.moveTo(ax, ay - s);
        path.lineTo(ax + s, ay + s * 0.12f);
        path.lineTo(ax - s * 0.55f, ay + s * 0.42f);
        path.close();
        p.setStyle(Paint.Style.FILL);
        c.drawPath(path, p);
    }

    public static void chevronLeft(Canvas c, float cx, float cy, float s, int color, float w) {
        Paint p = stroke(color, w);
        Path path = new Path();
        path.moveTo(cx + s * 0.32f, cy - s);
        path.lineTo(cx - s * 0.45f, cy);
        path.lineTo(cx + s * 0.32f, cy + s);
        c.drawPath(path, p);
    }

    /** ">" style hint; mirror of {@link #chevronLeft} for drill-down rows. */
    public static void chevronRight(Canvas c, float cx, float cy, float s, int color, float w) {
        Paint p = stroke(color, w);
        Path path = new Path();
        path.moveTo(cx - s * 0.32f, cy - s);
        path.lineTo(cx + s * 0.45f, cy);
        path.lineTo(cx - s * 0.32f, cy + s);
        c.drawPath(path, p);
    }

    public static int alpha(int color, int a) {
        return Color.argb(a, Color.red(color), Color.green(color), Color.blue(color));
    }
}
