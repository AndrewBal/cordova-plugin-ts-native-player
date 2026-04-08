# cordova-plugin-ts-native-player

Cordova iOS plugin for native playback of remote dashcam `.TS` files.

This version uses:
- native iOS download via `NSURLSession`
- temporary local file storage
- native fullscreen playback controller
- `MobileVLCKit` for MPEG-TS playback on iOS

## Why VLC

This plugin is intended for `.TS` files that fail in `AVPlayer` / `AVFoundation`.
For dashcam playback, the flow is:

`remote TS url -> native download -> local temp file -> MobileVLCKit playback`

## Installation

```bash
cordova plugin add ./cordova-plugin-ts-native-player
cd platforms/ios && pod install
```

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

## Notes

- `deleteAfterPlayback` defaults to `true`
- `cleanup()` removes temp files from `NSTemporaryDirectory()/TsNativePlayer`
- for QuikVizn viewer integration, make sure viewer cleanup calls `TSNativePlayer.stop()` instead of the old `LocalFileServer`
