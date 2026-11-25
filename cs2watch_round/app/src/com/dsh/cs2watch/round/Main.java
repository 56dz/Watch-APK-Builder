package com.dsh.cs2watch.round;

import android.app.Activity;
import android.os.Bundle;
import android.view.View;
import android.view.Window;
import android.view.WindowManager;

public class Main extends Activity {

    private WatchView view;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        getWindow().setFlags(WindowManager.LayoutParams.FLAG_FULLSCREEN,
                WindowManager.LayoutParams.FLAG_FULLSCREEN);
        try {
            getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            android.view.WindowManager.LayoutParams lp = getWindow().getAttributes();
            lp.screenBrightness = 0.85f;
            getWindow().setAttributes(lp);
        } catch (Exception ignored) {}

        view = new WatchView(this);
        setContentView(view);
        getWindow().setBackgroundDrawable(new android.graphics.drawable.ColorDrawable(0xFF05070A));

        // Last-good responses on disk: the watch stays useful without a network.
        try {
            Cache.init(getCacheDir());
        } catch (Exception ignored) {}

        // Burn-in guard: when the view goes idle it paints all black and we drop the
        // backlight to almost zero, so a static bright UI can never be burnt in.
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
                // No point polling the API for a panel nobody is looking at.
                DataLoader.setDim(idle);
            }
        });

        DataLoader.refreshIfNeeded(this, Store.get(), Store.Tab.TODAY);
        DataLoader.startLivePolling(this, Store.get(), new Runnable() {
            @Override public void run() { if (view != null) view.postInvalidateOnAnimation(); }
        });
    }

    @Override protected void onResume() {
        super.onResume();
        DataLoader.setHidden(false);
        if (view != null) view.postInvalidateOnAnimation();
    }

    @Override protected void onPause() {
        super.onPause();
        DataLoader.setHidden(true);
    }

    @Override public void onBackPressed() {
        if (view != null && view.handleBack()) return;
        super.onBackPressed();
    }
}
