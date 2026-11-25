package com.example.watchapp;

import android.app.Activity;
import android.os.Bundle;
import android.view.Window;
import android.view.WindowManager;

/**
 * Activity skeleton for the watch.
 *
 * Three things here are non-obvious on this device and worth copying verbatim:
 *  - FLAG_FULLSCREEN plus a dark window background (the theme is NoActionBar and
 *    the window flashes white on launch otherwise, which is ugly at 0.85 brightness),
 *  - FLAG_KEEP_SCREEN_ON while the user is looking, cleared when the panel dims,
 *  - the burn-in guard: after 60 s without touch the view paints black and the
 *    window backlight drops to 0.004f, so a static UI can never be burnt in.
 */
public class Main extends Activity {

    private WatchView view;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);
        try {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            WindowManager.LayoutParams lp = getWindow().getAttributes();
            lp.screenBrightness = 0.85f;
            getWindow().setAttributes(lp);
        } catch (Exception ignored) {}

        view = new WatchView(this);
        setContentView(view);
        getWindow().setBackgroundDrawable(
                new android.graphics.drawable.ColorDrawable(0xFF05070A));

        // Last-good responses on disk: the watch stays useful without a network.
        // Cache.init() needs only getCacheDir(), no permission.
        try {
            Cache.init(getCacheDir());
        } catch (Exception ignored) {}

        view.setIdleListener(new WatchView.IdleListener() {
            @Override public void onIdle(boolean idle) {
                try {
                    WindowManager.LayoutParams lp = getWindow().getAttributes();
                    lp.screenBrightness = idle ? 0.004f : 0.85f;
                    getWindow().setAttributes(lp);
                    if (idle) {
                        getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    } else {
                        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
                    }
                } catch (Exception ignored) {}
                // Stop polling the API for a panel nobody is looking at.
                // e.g. DataLoader.setDim(idle);
            }
        });

        // Populate the first page here, off the main thread, then:
        //   view.addPage(new WatchView.Page("今日"));
        //   view.setRows(0, rows);
    }

    @Override protected void onResume() {
        super.onResume();
        if (view != null) view.postInvalidateOnAnimation();
    }

    @Override public void onBackPressed() {
        // The watch has no back key gesture of its own: the app must consume it,
        // otherwise the system closes the activity from a detail page.
        if (view != null && view.handleBack()) return;
        super.onBackPressed();
    }
}
