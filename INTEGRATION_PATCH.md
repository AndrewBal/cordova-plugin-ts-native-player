# viewer.html integration patch

## 1. Keep TS playback routed into TSNativePlayer

```javascript
if (isIOS && fnLower.endsWith('.ts') && window.TSNativePlayer) {
    self.$app.preloader.show();

    TSNativePlayer.play(
        inputUrl,
        { title: self.filename },
        function(status, payload) {
            console.log('[Viewer] TSNativePlayer status:', status, payload);

            if (
                status === 'DOWNLOAD_COMPLETE' ||
                status === 'READY' ||
                status === 'OPENING' ||
                status === 'BUFFERING' ||
                status === 'PLAYING'
            ) {
                self.$app.preloader.hide();
            }

            if (status === 'FINISHED' || status === 'CLOSED') {
                self.$app.preloader.hide();
            }
        },
        function(error) {
            self.$app.preloader.hide();
            self.$app.toast.show({
                text: 'Cannot play video: ' + (error || 'Unknown error'),
                position: 'center',
                closeTimeout: 3000
            });
        }
    );
    return;
}
```

## 2. Replace old cleanup

```javascript
cleanup: function() {
    var video = document.getElementById('videoPlayer');
    if (video) {
        video.pause();
        video.removeAttribute('src');
        video.load();
    }

    if (window.TSNativePlayer) {
        TSNativePlayer.stop(function(){}, function(){});
    }
}
```
