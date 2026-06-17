package com.quikvizn.tsplayer;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.lang.ref.WeakReference;

/**
 * Android bridge for cordova-plugin-ts-native-player.
 *
 * Mirrors the iOS JS contract (play / playInline / updateInlineFrame / stop /
 * cleanup / warmup). Playback runs in {@link TsPlayerView} (libVLC), which
 * streams a remote .TS URL directly — no ffmpeg remux — so it starts as fast
 * as the iOS MobileVLCKit path.
 *
 *  - play():        fullscreen, via {@link TsPlayerActivity}.
 *  - playInline():  the same player view overlaid on the WebView at a DOM rect,
 *                   repositioned by updateInlineFrame() as the page scrolls.
 */
public class TsNativePlayerPlugin extends CordovaPlugin {

    // Current play()/playInline() callback. Kept alive (keepCallback) for the
    // stream of status updates (OPENING / BUFFERING / PLAYING / ...).
    private static CallbackContext sStatusCallback;

    // Weak handle to the fullscreen player Activity so stop()/cleanup() can dismiss it.
    private static WeakReference<TsPlayerActivity> sActivityRef;

    // Inline overlay state (always touched on the UI thread).
    private TsPlayerView mInlineView;
    private ViewGroup mInlineContainer;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        switch (action) {
            case "warmup":
                // Android has no iOS-14-style Local Network permission gate.
                JSONObject granted = new JSONObject();
                granted.put("status", "GRANTED");
                granted.put("localNetworkGranted", true);
                callbackContext.success(granted);
                return true;

            case "play":
                play(args.optJSONObject(0), callbackContext);
                return true;

            case "playInline":
                playInline(args.optJSONObject(0), callbackContext);
                return true;

            case "updateInlineFrame":
                updateInlineFrame(args.optJSONObject(0), callbackContext);
                return true;

            case "stop":
                stop(callbackContext);
                return true;

            case "cleanup":
                cleanup(callbackContext);
                return true;

            default:
                return false;
        }
    }

    // ── Fullscreen ───────────────────────────────────────────────────────────

    private void play(JSONObject options, CallbackContext callbackContext) {
        if (options == null) { callbackContext.error("Invalid options"); return; }
        final String url = options.optString("url", "");
        if (url.length() == 0) { callbackContext.error("Invalid URL"); return; }

        teardownAll();
        sStatusCallback = callbackContext;

        final String title = options.optString("title", "Playback");
        final boolean deleteAfter = options.optBoolean("deleteAfterPlayback", true);
        final long networkCaching = options.optLong("networkCaching", 1500);
        final boolean forceDownloadFirst = options.optBoolean("forceDownloadFirst", false);

        // Launch in the app's own task (Activity context, no NEW_TASK) so the
        // hardware back button returns straight to the WebView.
        Intent intent = new Intent(cordova.getActivity(), TsPlayerActivity.class);
        intent.putExtra("url", url);
        intent.putExtra("title", title);
        intent.putExtra("deleteAfterPlayback", deleteAfter);
        intent.putExtra("networkCaching", networkCaching);
        intent.putExtra("forceDownloadFirst", forceDownloadFirst);
        cordova.getActivity().startActivity(intent);

        emitStatus("OPENING_REMOTE", null);
    }

    // ── Inline overlay ─────────────────────────────────────────────────────────

    private void playInline(JSONObject options, CallbackContext callbackContext) {
        if (options == null) { callbackContext.error("Invalid options"); return; }
        final String url = options.optString("url", "");
        if (url.length() == 0) { callbackContext.error("Invalid URL"); return; }
        final JSONObject frame = options.optJSONObject("frame");
        if (frame == null) { callbackContext.error("Invalid inline frame"); return; }

        teardownAll();
        sStatusCallback = callbackContext;

        final String title = options.optString("title", "Playback");
        final boolean deleteAfter = options.optBoolean("deleteAfterPlayback", true);
        final long networkCaching = options.optLong("networkCaching", 1500);
        final boolean forceDownloadFirst = options.optBoolean("forceDownloadFirst", false);

        final Activity activity = cordova.getActivity();
        activity.runOnUiThread(new Runnable() {
            @Override public void run() {
                ViewGroup content = activity.findViewById(android.R.id.content);
                if (content == null) {
                    emitError("Cannot mount inline player");
                    return;
                }

                TsPlayerView view = new TsPlayerView(activity, true /* TextureView over WebView */,
                        title, new TsPlayerView.Callback() {
                    @Override public void onStatus(String status) {
                        emitStatus(status, null);
                    }
                    @Override public void onError(String message) {
                        emitError(message);
                        removeInlineView();
                    }
                    @Override public void onClose() {
                        removeInlineView();
                        emitStatus("CLOSED", null);
                    }
                });

                FrameLayout.LayoutParams lp = computeInlineLp(frame, content);
                content.addView(view, lp);
                view.bringToFront();

                mInlineView = view;
                mInlineContainer = content;

                view.start(url, networkCaching, deleteAfter, forceDownloadFirst);
            }
        });

        emitStatus("OPENING_REMOTE", null);
    }

    private void updateInlineFrame(final JSONObject frame, CallbackContext callbackContext) {
        if (frame == null) { callbackContext.error("Invalid frame"); return; }
        final Activity activity = cordova.getActivity();
        activity.runOnUiThread(new Runnable() {
            @Override public void run() {
                if (mInlineView != null && mInlineContainer != null) {
                    mInlineView.setLayoutParams(computeInlineLp(frame, mInlineContainer));
                }
            }
        });
        callbackContext.success();
    }

    /**
     * Map a DOM rect (CSS px, viewport-relative) to a frame in the content view.
     * CSS px → device px = value * displayDensity; then offset by where the
     * WebView sits inside the content frame (handles the status bar, etc.).
     */
    private FrameLayout.LayoutParams computeInlineLp(JSONObject frame, ViewGroup content) {
        float density = cordova.getActivity().getResources().getDisplayMetrics().density;
        double fx = frame.optDouble("x", 0);
        double fy = frame.optDouble("y", 0);
        double fw = frame.optDouble("width", 0);
        double fh = frame.optDouble("height", 0);

        int offX = 0, offY = 0;
        View web = (webView != null) ? webView.getView() : null;
        if (web != null) {
            int[] cLoc = new int[2];
            int[] wLoc = new int[2];
            content.getLocationOnScreen(cLoc);
            web.getLocationOnScreen(wLoc);
            offX = wLoc[0] - cLoc[0];
            offY = wLoc[1] - cLoc[1];
        }

        int w = Math.max(1, Math.round((float) (fw * density)));
        int h = Math.max(1, Math.round((float) (fh * density)));
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(w, h);
        lp.gravity = Gravity.TOP | Gravity.START;
        lp.leftMargin = offX + Math.round((float) (fx * density));
        lp.topMargin  = offY + Math.round((float) (fy * density));
        return lp;
    }

    // ── Stop / cleanup ──────────────────────────────────────────────────────

    private void stop(CallbackContext callbackContext) {
        teardownAll();
        // Notify the play()/playInline() callback its session is over.
        emitStatus("CLOSED", null);
        JSONObject payload = new JSONObject();
        try { payload.put("status", "STOPPED"); } catch (JSONException ignored) {}
        callbackContext.success(payload);
    }

    private void cleanup(CallbackContext callbackContext) {
        teardownAll();
        emitStatus("CLOSED", null);
        deleteTempFiles(cordova.getActivity().getApplicationContext());
        JSONObject payload = new JSONObject();
        try { payload.put("status", "CLEANED"); } catch (JSONException ignored) {}
        callbackContext.success(payload);
    }

    @Override
    public void onDestroy() {
        teardownAll();
        sStatusCallback = null;
        super.onDestroy();
    }

    private void teardownAll() {
        finishActiveActivity();
        removeInlineView();
    }

    // ── Inline view lifecycle (UI-thread safe) ────────────────────────────────

    private void removeInlineView() {
        final Runnable r = new Runnable() {
            @Override public void run() {
                if (mInlineView != null) {
                    TsPlayerView v = mInlineView;
                    mInlineView = null;
                    v.release();
                    if (mInlineContainer != null) {
                        mInlineContainer.removeView(v);
                    }
                    mInlineContainer = null;
                }
            }
        };
        if (Looper.myLooper() == Looper.getMainLooper()) {
            r.run();
        } else {
            cordova.getActivity().runOnUiThread(r);
        }
    }

    // ── Fullscreen Activity bridge ─────────────────────────────────────────────

    static void registerActivity(TsPlayerActivity activity) {
        sActivityRef = new WeakReference<>(activity);
    }

    static void unregisterActivity(TsPlayerActivity activity) {
        if (sActivityRef != null && sActivityRef.get() == activity) {
            sActivityRef = null;
        }
    }

    private void finishActiveActivity() {
        if (sActivityRef != null) {
            TsPlayerActivity a = sActivityRef.get();
            if (a != null) {
                a.finishFromPlugin();
            }
            sActivityRef = null;
        }
    }

    // ── JS callback helpers ──────────────────────────────────────────────────

    /** Push a status update ({"status": ...}) to the active JS callback. */
    static void emitStatus(String status, JSONObject extra) {
        CallbackContext cb = sStatusCallback;
        if (cb == null) return;
        try {
            JSONObject payload = (extra != null) ? extra : new JSONObject();
            payload.put("status", status);
            PluginResult result = new PluginResult(PluginResult.Status.OK, payload);
            boolean keep = !"CLOSED".equals(status); // CLOSED is terminal
            result.setKeepCallback(keep);
            cb.sendPluginResult(result);
            if (!keep) {
                sStatusCallback = null;
            }
        } catch (JSONException ignored) {}
    }

    /** Terminal error — routes to the JS error callback. */
    static void emitError(String message) {
        CallbackContext cb = sStatusCallback;
        if (cb == null) return;
        PluginResult result = new PluginResult(PluginResult.Status.ERROR,
                message != null ? message : "Unknown error");
        result.setKeepCallback(false);
        cb.sendPluginResult(result);
        sStatusCallback = null;
    }

    // ── Temp-file helpers (shared with the download fallback) ────────────────

    static File tempDir(Context ctx) {
        File dir = new File(ctx.getCacheDir(), "TsNativePlayer");
        if (!dir.exists()) {
            //noinspection ResultOfMethodCallIgnored
            dir.mkdirs();
        }
        return dir;
    }

    static void deleteTempFiles(Context ctx) {
        File dir = new File(ctx.getCacheDir(), "TsNativePlayer");
        if (dir.exists() && dir.isDirectory()) {
            File[] files = dir.listFiles();
            if (files != null) {
                for (File f : files) {
                    //noinspection ResultOfMethodCallIgnored
                    f.delete();
                }
            }
        }
    }
}
