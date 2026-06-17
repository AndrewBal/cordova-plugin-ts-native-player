package com.quikvizn.tsplayer;

import android.app.Activity;
import android.os.Bundle;
import android.view.ViewGroup;

/**
 * Fullscreen host for {@link TsPlayerView}. Used by TSNativePlayer.play().
 * Inline playback (TSNativePlayer.playInline) hosts the same view directly
 * over the WebView from {@link TsNativePlayerPlugin} instead of an Activity.
 */
public class TsPlayerActivity extends Activity {

    private TsPlayerView mPlayer;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        String url                = getIntent().getStringExtra("url");
        String title              = getIntent().getStringExtra("title");
        boolean deleteAfter       = getIntent().getBooleanExtra("deleteAfterPlayback", true);
        long networkCaching       = getIntent().getLongExtra("networkCaching", 1500);
        boolean forceDownloadFirst = getIntent().getBooleanExtra("forceDownloadFirst", false);

        TsNativePlayerPlugin.registerActivity(this);

        if (url == null || url.length() == 0) {
            TsNativePlayerPlugin.emitError("Invalid URL");
            finish();
            return;
        }

        mPlayer = new TsPlayerView(this, false /* SurfaceView for fullscreen */, title,
                new TsPlayerView.Callback() {
                    @Override public void onStatus(String status) {
                        TsNativePlayerPlugin.emitStatus(status, null);
                    }
                    @Override public void onError(String message) {
                        TsNativePlayerPlugin.emitError(message);
                        finish();
                    }
                    @Override public void onClose() {
                        finish();
                    }
                });

        setContentView(mPlayer, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        mPlayer.start(url, networkCaching, deleteAfter, forceDownloadFirst);
    }

    /** Called by the plugin (stop()/cleanup()/new play()) to dismiss this player. */
    void finishFromPlugin() {
        runOnUiThread(new Runnable() {
            @Override public void run() { finish(); }
        });
    }

    @Override
    public void onBackPressed() {
        finish();
    }

    @Override
    protected void onDestroy() {
        if (mPlayer != null) {
            mPlayer.release();
            mPlayer = null;
        }
        TsNativePlayerPlugin.unregisterActivity(this);
        TsNativePlayerPlugin.emitStatus("CLOSED", null);
        super.onDestroy();
    }
}
