var exec = require('cordova/exec');

var TsNativePlayer = {
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