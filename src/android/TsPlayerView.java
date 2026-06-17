package com.quikvizn.tsplayer;

import android.content.Context;
import android.graphics.Color;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageButton;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.SeekBar;
import android.widget.TextView;

import org.videolan.libvlc.LibVLC;
import org.videolan.libvlc.Media;
import org.videolan.libvlc.MediaPlayer;
import org.videolan.libvlc.util.VLCVideoLayout;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;

/**
 * Reusable libVLC player view: video surface + transport controls (play/pause,
 * current/duration time, seek slider, close), buffering spinner, and a
 * download fallback. Hosted full-screen by {@link TsPlayerActivity}, or as an
 * inline overlay over the WebView via {@link TsNativePlayerPlugin}'s playInline.
 *
 * All playback state is reported through {@link Callback}; the view never
 * touches the plugin's static callback, so each host routes events its own way.
 */
public class TsPlayerView extends FrameLayout {

    public interface Callback {
        void onStatus(String status);
        void onError(String message);
        void onClose();
    }

    private static final long STARTUP_FALLBACK_MS = 15000;
    private static final int  AUTO_HIDE_MS        = 4000;
    private static final int  SEEK_RESOLUTION     = 1000;

    private final boolean mUseTextureView;
    private final Callback mCallback;

    private LibVLC mLibVLC;
    private MediaPlayer mMediaPlayer;
    private VLCVideoLayout mVideoLayout;

    private ProgressBar mSpinner;
    private FrameLayout mControls;
    private ImageButton mPlayPause;
    private SeekBar mSeekBar;
    private TextView mCurrentTime;
    private TextView mDuration;

    private String mUrl;
    private long mNetworkCaching = 1500;
    private boolean mDeleteAfter = true;

    private boolean mHasStartedPlayback = false;
    private boolean mIsUserSeeking = false;
    private boolean mDidFallbackToDownload = false;
    private boolean mReleased = false;
    private String mDownloadedFilePath;
    private Thread mDownloadThread;

    private final Handler mUi = new Handler(Looper.getMainLooper());
    private final Runnable mHideControlsTask = new Runnable() {
        @Override public void run() { setControlsVisible(false); }
    };
    private final Runnable mStartupTimeoutTask = new Runnable() {
        @Override public void run() { onStartupTimeout(); }
    };

    public TsPlayerView(Context context, boolean useTextureView, String title, Callback callback) {
        super(context);
        mUseTextureView = useTextureView;
        mCallback = callback;
        setBackgroundColor(Color.BLACK);
        setKeepScreenOn(true);
        buildUI(title);
    }

    private int dp(int v) {
        return (int) TypedValue.applyDimension(
                TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics());
    }

    private void buildUI(String title) {
        // Video surface — VLCVideoLayout keeps the picture centered/letterboxed.
        mVideoLayout = new VLCVideoLayout(getContext());
        addView(mVideoLayout, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Buffering spinner.
        mSpinner = new ProgressBar(getContext());
        addView(mSpinner, new FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER));

        // Controls overlay (toggled by tapping the video).
        mControls = new FrameLayout(getContext());
        mControls.setLayoutParams(new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Top bar: close + title.
        LinearLayout topBar = new LinearLayout(getContext());
        topBar.setOrientation(LinearLayout.HORIZONTAL);
        topBar.setGravity(Gravity.CENTER_VERTICAL);
        topBar.setPadding(dp(8), dp(8), dp(8), dp(8));
        topBar.setBackgroundColor(0x66000000);

        TextView closeBtn = new TextView(getContext());
        closeBtn.setText("✕");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        closeBtn.setPadding(dp(10), dp(4), dp(16), dp(4));
        closeBtn.setOnClickListener(new OnClickListener() {
            @Override public void onClick(View v) { requestClose(); }
        });
        topBar.addView(closeBtn);

        TextView titleView = new TextView(getContext());
        titleView.setText(title != null ? title : "Playback");
        titleView.setTextColor(Color.WHITE);
        titleView.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        titleView.setSingleLine(true);
        topBar.addView(titleView, new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        mControls.addView(topBar, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.TOP));

        // Center play/pause.
        mPlayPause = new ImageButton(getContext());
        mPlayPause.setBackgroundColor(Color.TRANSPARENT);
        mPlayPause.setImageResource(android.R.drawable.ic_media_pause);
        mPlayPause.setColorFilter(Color.WHITE);
        mPlayPause.setScaleType(ImageView.ScaleType.FIT_CENTER);
        mPlayPause.setOnClickListener(new OnClickListener() {
            @Override public void onClick(View v) { togglePlayPause(); }
        });
        mControls.addView(mPlayPause, new FrameLayout.LayoutParams(dp(56), dp(56), Gravity.CENTER));

        // Bottom bar: current time, seek slider, duration.
        LinearLayout bottomBar = new LinearLayout(getContext());
        bottomBar.setOrientation(LinearLayout.HORIZONTAL);
        bottomBar.setGravity(Gravity.CENTER_VERTICAL);
        bottomBar.setPadding(dp(12), dp(6), dp(12), dp(8));
        bottomBar.setBackgroundColor(0x66000000);

        mCurrentTime = new TextView(getContext());
        mCurrentTime.setText("00:00");
        mCurrentTime.setTextColor(Color.WHITE);
        mCurrentTime.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        bottomBar.addView(mCurrentTime);

        mSeekBar = new SeekBar(getContext());
        mSeekBar.setMax(SEEK_RESOLUTION);
        mSeekBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar sb, int progress, boolean fromUser) {
                if (fromUser && mMediaPlayer != null) {
                    long len = mMediaPlayer.getLength();
                    if (len > 0) {
                        mCurrentTime.setText(formatMs((long) (len * (progress / (float) SEEK_RESOLUTION))));
                    }
                }
            }
            @Override public void onStartTrackingTouch(SeekBar sb) {
                mIsUserSeeking = true;
                cancelAutoHide();
            }
            @Override public void onStopTrackingTouch(SeekBar sb) {
                if (mMediaPlayer != null) {
                    mMediaPlayer.setPosition(sb.getProgress() / (float) SEEK_RESOLUTION);
                }
                mIsUserSeeking = false;
                scheduleAutoHide();
            }
        });
        LinearLayout.LayoutParams seekLp = new LinearLayout.LayoutParams(
                0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        seekLp.leftMargin = dp(10);
        seekLp.rightMargin = dp(10);
        bottomBar.addView(mSeekBar, seekLp);

        mDuration = new TextView(getContext());
        mDuration.setText("--:--");
        mDuration.setTextColor(Color.WHITE);
        mDuration.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        bottomBar.addView(mDuration);

        mControls.addView(bottomBar, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT, Gravity.BOTTOM));

        addView(mControls);

        // Tap on the video toggles the controls overlay.
        setOnClickListener(new OnClickListener() {
            @Override public void onClick(View v) {
                setControlsVisible(mControls.getVisibility() != VISIBLE);
            }
        });
        setControlsVisible(true);
    }

    // ── Public API ─────────────────────────────────────────────────────────────

    public void start(String url, long networkCaching, boolean deleteAfter, boolean forceDownloadFirst) {
        mUrl = url;
        mNetworkCaching = networkCaching;
        mDeleteAfter = deleteAfter;

        ArrayList<String> options = new ArrayList<>();
        options.add("--no-drop-late-frames");
        options.add("--no-skip-frames");
        mLibVLC = new LibVLC(getContext(), options);

        mMediaPlayer = new MediaPlayer(mLibVLC);
        // useTextureView=true for the inline overlay so it composites above the
        // WebView; false (SurfaceView) for fullscreen where it is more efficient.
        mMediaPlayer.attachViews(mVideoLayout, null, false, mUseTextureView);
        mMediaPlayer.setEventListener(mVlcListener);

        if (forceDownloadFirst) {
            startDownloadFallback();
        } else {
            playMedia(Uri.parse(url), false);
            // Safety net mirroring iOS: if the stream never starts, download instead.
            mUi.postDelayed(mStartupTimeoutTask, STARTUP_FALLBACK_MS);
        }
    }

    /** Idempotent teardown. Safe to call from the UI thread. */
    public void release() {
        if (mReleased) return;
        mReleased = true;
        mUi.removeCallbacksAndMessages(null);

        if (mDownloadThread != null) {
            mDownloadThread.interrupt();
            mDownloadThread = null;
        }
        if (mMediaPlayer != null) {
            mMediaPlayer.setEventListener(null);
            mMediaPlayer.stop();
            mMediaPlayer.detachViews();
            mMediaPlayer.release();
            mMediaPlayer = null;
        }
        if (mLibVLC != null) {
            mLibVLC.release();
            mLibVLC = null;
        }
        if (mDeleteAfter && mDownloadedFilePath != null) {
            File f = new File(mDownloadedFilePath);
            if (f.exists()) {
                //noinspection ResultOfMethodCallIgnored
                f.delete();
            }
        }
    }

    // ── Controls ─────────────────────────────────────────────────────────────

    private void requestClose() {
        if (mCallback != null) mCallback.onClose();
    }
    private void emitStatus(String s) {
        if (mCallback != null) mCallback.onStatus(s);
    }
    private void emitError(String m) {
        if (mCallback != null) mCallback.onError(m);
    }

    private void setControlsVisible(boolean visible) {
        mControls.setVisibility(visible ? VISIBLE : GONE);
        if (visible) scheduleAutoHide();
    }
    private void scheduleAutoHide() {
        cancelAutoHide();
        if (mMediaPlayer != null && mMediaPlayer.isPlaying()) {
            mUi.postDelayed(mHideControlsTask, AUTO_HIDE_MS);
        }
    }
    private void cancelAutoHide() {
        mUi.removeCallbacks(mHideControlsTask);
    }
    private void togglePlayPause() {
        if (mMediaPlayer == null) return;
        if (mMediaPlayer.isPlaying()) mMediaPlayer.pause();
        else mMediaPlayer.play();
    }

    // ── libVLC ─────────────────────────────────────────────────────────────────

    private void playMedia(Uri uri, boolean isLocal) {
        if (mMediaPlayer == null) return;
        Media media = new Media(mLibVLC, uri);
        media.addOption(":network-caching=" + mNetworkCaching);
        media.addOption(":clock-jitter=0");
        media.addOption(":clock-synchro=0");
        if (isLocal) media.addOption(":file-caching=" + mNetworkCaching);
        mMediaPlayer.setMedia(media);
        media.release();
        showSpinner(true);
        mMediaPlayer.play();
    }

    private final MediaPlayer.EventListener mVlcListener = new MediaPlayer.EventListener() {
        @Override public void onEvent(final MediaPlayer.Event event) {
            mUi.post(new Runnable() {
                @Override public void run() { handleVlcEvent(event); }
            });
        }
    };

    private void handleVlcEvent(MediaPlayer.Event event) {
        if (mReleased || mMediaPlayer == null) return;
        switch (event.type) {
            case MediaPlayer.Event.Opening:
                emitStatus("OPENING");
                break;
            case MediaPlayer.Event.Buffering:
                mUi.removeCallbacks(mStartupTimeoutTask);
                if (!mHasStartedPlayback) showSpinner(true);
                emitStatus("BUFFERING");
                break;
            case MediaPlayer.Event.Playing:
                mHasStartedPlayback = true;
                mUi.removeCallbacks(mStartupTimeoutTask);
                showSpinner(false);
                mPlayPause.setImageResource(android.R.drawable.ic_media_pause);
                scheduleAutoHide();
                emitStatus("PLAYING");
                break;
            case MediaPlayer.Event.Paused:
                mPlayPause.setImageResource(android.R.drawable.ic_media_play);
                cancelAutoHide();
                setControlsVisible(true);
                emitStatus("PAUSED");
                break;
            case MediaPlayer.Event.EndReached:
                emitStatus("FINISHED");
                requestClose();
                break;
            case MediaPlayer.Event.EncounteredError:
                onPlaybackError();
                break;
            case MediaPlayer.Event.TimeChanged:
                if (!mIsUserSeeking) mCurrentTime.setText(formatMs(mMediaPlayer.getTime()));
                break;
            case MediaPlayer.Event.LengthChanged:
                mDuration.setText(formatMs(mMediaPlayer.getLength()));
                break;
            case MediaPlayer.Event.PositionChanged:
                if (!mIsUserSeeking) mSeekBar.setProgress((int) (event.getPositionChanged() * SEEK_RESOLUTION));
                break;
            default:
                break;
        }
    }

    private void showSpinner(boolean visible) {
        mSpinner.setVisibility(visible ? VISIBLE : GONE);
    }

    // ── Fallback: error / startup timeout → download then play local ──────────

    private void onPlaybackError() {
        if (!mHasStartedPlayback && !mDidFallbackToDownload) {
            startDownloadFallback();
        } else {
            emitError("VLC playback failed");
        }
    }
    private void onStartupTimeout() {
        if (mReleased || mHasStartedPlayback || mDidFallbackToDownload) return;
        startDownloadFallback();
    }
    private void startDownloadFallback() {
        if (mDidFallbackToDownload) return;
        mDidFallbackToDownload = true;
        mUi.removeCallbacks(mStartupTimeoutTask);
        if (mMediaPlayer != null) mMediaPlayer.stop();
        showSpinner(true);
        emitStatus("FALLBACK_TO_DOWNLOAD");
        emitStatus("DOWNLOADING");
        mDownloadThread = new Thread(new Runnable() {
            @Override public void run() { downloadAndPlay(); }
        });
        mDownloadThread.start();
    }
    private void downloadAndPlay() {
        HttpURLConnection conn = null;
        InputStream in = null;
        FileOutputStream out = null;
        File target = null;
        try {
            File dir = TsNativePlayerPlugin.tempDir(getContext().getApplicationContext());
            target = new File(dir, System.currentTimeMillis() + "_video.ts");

            URL url = new URL(mUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(30000);
            conn.setReadTimeout(30000);
            conn.connect();

            int code = conn.getResponseCode();
            if (code < 200 || code >= 300) throw new Exception("HTTP " + code);

            in = conn.getInputStream();
            out = new FileOutputStream(target);
            byte[] buf = new byte[64 * 1024];
            int read;
            while ((read = in.read(buf)) != -1) {
                if (mReleased) return;
                out.write(buf, 0, read);
            }
            out.flush();

            mDownloadedFilePath = target.getAbsolutePath();
            final Uri localUri = Uri.fromFile(target);
            mUi.post(new Runnable() {
                @Override public void run() {
                    if (mReleased) return;
                    emitStatus("DOWNLOAD_COMPLETE");
                    emitStatus("READY");
                    playMedia(localUri, true);
                }
            });
        } catch (final Exception e) {
            final File failed = target;
            mUi.post(new Runnable() {
                @Override public void run() {
                    if (mReleased) return;
                    if (failed != null && failed.exists()) {
                        //noinspection ResultOfMethodCallIgnored
                        failed.delete();
                    }
                    emitError("Download failed: " + e.getMessage());
                }
            });
        } finally {
            closeQuietly(out);
            closeQuietly(in);
            if (conn != null) conn.disconnect();
        }
    }
    private static void closeQuietly(java.io.Closeable c) {
        if (c != null) { try { c.close(); } catch (Exception ignored) {} }
    }

    private String formatMs(long ms) {
        if (ms < 0) ms = 0;
        int totalSec = (int) (ms / 1000);
        int h = totalSec / 3600;
        int m = (totalSec % 3600) / 60;
        int s = totalSec % 60;
        if (h > 0) return String.format(java.util.Locale.US, "%d:%02d:%02d", h, m, s);
        return String.format(java.util.Locale.US, "%02d:%02d", m, s);
    }
}
