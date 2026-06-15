var exec = require('cordova/exec');

var TsNativePlayer = {
    /**
     * Trigger Local Network permission dialog early.
     * Call on app launch so the user sees the dialog BEFORE trying to play video.
     *
     * @param {Object}   options   - { host: '192.168.0.1', port: 80 }
     * @param {Function} success   - receives { status: 'GRANTED'|'DENIED', localNetworkGranted: bool }
     * @param {Function} error     - error string
     */
    warmup: function(options, success, error) {
        exec(success, error, 'TsNativePlayer', 'warmup', [options || {}]);
    },

    play: function(options, success, error) {
        exec(success, error, 'TsNativePlayer', 'play', [options]);
    },

    playInline: function(options, success, error) {
        exec(success, error, 'TsNativePlayer', 'playInline', [options]);
    },

    updateInlineFrame: function(frame, success, error) {
        exec(success, error, 'TsNativePlayer', 'updateInlineFrame', [frame]);
    },

    stop: function(success, error) {
        exec(success, error, 'TsNativePlayer', 'stop', []);
    },

    cleanup: function(success, error) {
        exec(success, error, 'TsNativePlayer', 'cleanup', []);
    }
};

module.exports = TsNativePlayer;