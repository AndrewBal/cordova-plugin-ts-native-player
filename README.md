# cordova-plugin-ts-native-player

Cordova plugin for native playback of remote dashcam `.TS` files on **iOS and Android**.

Both platforms use a VLC engine so that MPEG-TS streams (which fail in `AVPlayer`
on iOS and the WebView `<video>` tag on Android) play **directly from the remote
URL with no transcoding wait**:

- **iOS:** `MobileVLCKit`, native download via `NSURLSession`, native fullscreen controller.
- **Android:** `libVLC` (`org.videolan.android:libvlc-all`), fullscreen `TsPlayerActivity`
  rendering into `VLCVideoLayout`.

## Why VLC

This plugin is intended for `.TS` files that fail in `AVPlayer` / `AVFoundation`
(iOS) and in the Android WebView `<video>` element. The preferred flow on both
platforms is **direct streaming**:

`remote TS url -> VLC streams it directly (no remux)`

If direct streaming fails or never starts within ~15 s, it falls back to:

`remote TS url -> native download -> local temp file -> VLC playback`

## Installation

```bash
cordova plugin add ./cordova-plugin-ts-native-player
# iOS only:
cd platforms/ios && pod install
```

Android pulls `org.videolan.android:libvlc-all:3.6.0` automatically via the
bundled `ts-player.gradle`.

## JS API

```javascript
TSNativePlayer.play(url, { title: 'Playback' }, success, error);
TSNativePlayer.stop(success, error);
TSNativePlayer.cleanup(success, error);
```

or:

```javascript
TSNativePlayer.play({
  url: 'http://192.168.0.1/sd//norm/file.TS',
  title: 'Playback',
  deleteAfterPlayback: true
}, success, error);
```

## Status callbacks

Possible success payloads:

```javascript
{ status: 'DOWNLOADING', url: '...' }
{ status: 'DOWNLOAD_COMPLETE', localPath: '...' }
{ status: 'READY', localPath: '...' }
{ status: 'OPENING', localPath: '...' }
{ status: 'BUFFERING' }
{ status: 'PLAYING' }
{ status: 'PAUSED' }
{ status: 'FINISHED' }
{ status: 'CLOSED' }
```

Error callback examples:

```javascript
'Invalid URL'
'Download failed: ...'
'VLC playback failed: Error'
```

## Status callbacks (Android additions)

In addition to the iOS statuses, the direct-stream path emits `OPENING_REMOTE`
first, and the download fallback emits `FALLBACK_TO_DOWNLOAD` before `DOWNLOADING`.
The same `play()` callback contract (keepCallback stream of `{ status: ... }`
objects, terminal `CLOSED`) is used on both platforms.

## Platform notes

- `warmup()` is a no-op on Android (there is no iOS-14-style Local Network
  permission gate) and returns `{ status: 'GRANTED' }`.
- `playInline({ url, title, frame })` is supported on **both** platforms: the
  native player is overlaid on the WebView at the DOM rect (`frame` =
  `getBoundingClientRect()` in CSS px). Call `updateInlineFrame(frame)` on
  scroll/resize to keep it aligned. On Android the inline video uses a
  TextureView so it composites above the WebView.
- Android requires cleartext HTTP to the camera — the host app already enables
  `usesCleartextTraffic` / a network-security-config; the plugin only adds the
  `INTERNET` permission and registers `TsPlayerActivity`.

## Notes

- `deleteAfterPlayback` defaults to `true`
- `cleanup()` removes temp files from `NSTemporaryDirectory()/TsNativePlayer` (iOS)
  / `cacheDir/TsNativePlayer` (Android)
- for QuikVizn viewer integration, make sure viewer cleanup calls `TSNativePlayer.stop()` instead of the old `LocalFileServer`
