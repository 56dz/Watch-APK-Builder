package com.example.watchapp;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;

/**
 * Tiny on-disk cache for raw API responses.
 *
 * The watch is usually on a slow or flaky link, and a cold start used to fail
 * outright when the network was not ready yet. Every successful GET is written
 * here, and a failed request falls back to the last known body, so the app always
 * has something to draw. Files live in the app cache dir (no permission needed)
 * and the whole cache is capped at a few megabytes.
 */
final class Cache {

    private static final long MAX_BYTES = 3L * 1024 * 1024;
    /** Prune every N writes: cheap enough on a watch, keeps the dir bounded. */
    private static final int PRUNE_EVERY = 25;

    private static File sDir;
    private static int sWrites;

    private Cache() {}

    static void init(File dir) {
        sDir = dir;
        Thread t = new Thread(new Runnable() {
            @Override public void run() {
                try { prune(); } catch (Exception ignored) {}
            }
        }, "cache-prune");
        t.setDaemon(true);
        t.start();
    }

    static synchronized String get(String key) {
        if (sDir == null) return null;
        File f = file(key);
        if (f == null || !f.exists() || f.length() == 0) return null;
        InputStream in = null;
        try {
            in = new FileInputStream(f);
            ByteArrayOutputStream bo = new ByteArrayOutputStream((int) f.length());
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) bo.write(buf, 0, n);
            return new String(bo.toByteArray(), "UTF-8");
        } catch (Exception e) {
            return null;
        } finally {
            close(in);
        }
    }

    static synchronized void put(String key, String value) {
        if (sDir == null || value == null || value.length() < 2) return;
        OutputStream out = null;
        File f = file(key);
        if (f == null) return;
        try {
            out = new FileOutputStream(f);
            out.write(value.getBytes("UTF-8"));
        } catch (Exception ignored) {
        } finally {
            close(out);
        }
        if (++sWrites % PRUNE_EVERY == 0) {
            Thread t = new Thread(new Runnable() {
                @Override public void run() {
                    try { prune(); } catch (Exception ignored) {}
                }
            }, "cache-prune");
            t.setDaemon(true);
            t.start();
        }
    }

    /** Keeps the newest files and drops the rest once the cap is exceeded. */
    static synchronized void prune() {
        if (sDir == null || !sDir.isDirectory()) return;
        File[] all = sDir.listFiles();
        if (all == null || all.length == 0) return;
        List<File> files = new ArrayList<>();
        long total = 0;
        for (File f : all) {
            if (f.isFile() && f.getName().endsWith(".json")) {
                files.add(f);
                total += f.length();
            }
        }
        if (total <= MAX_BYTES) return;
        Collections.sort(files, new Comparator<File>() {
            @Override public int compare(File a, File b) {
                return Long.compare(a.lastModified(), b.lastModified());
            }
        });
        for (File f : files) {
            if (total <= MAX_BYTES) break;
            total -= f.length();
            //noinspection ResultOfMethodCallIgnored
            f.delete();
        }
    }

    private static File file(String key) {
        if (sDir == null || key == null) return null;
        return new File(sDir, name(key) + ".json");
    }

    private static String name(String key) {
        try {
            MessageDigest md = MessageDigest.getInstance("SHA-1");
            byte[] h = md.digest(key.getBytes("UTF-8"));
            StringBuilder sb = new StringBuilder(h.length * 2);
            for (byte b : h) {
                int v = b & 0xFF;
                if (v < 16) sb.append('0');
                sb.append(Integer.toHexString(v));
            }
            return sb.toString();
        } catch (Exception e) {
            return Integer.toHexString(key.hashCode());
        }
    }

    private static void close(java.io.Closeable c) {
        if (c == null) return;
        try { c.close(); } catch (Exception ignored) {}
    }
}
