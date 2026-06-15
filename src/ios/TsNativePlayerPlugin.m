#import "TsNativePlayerPlugin.h"
#import "TsPlaybackManager.h"
#import "TsNetworkHelper.h"

@interface TsNativePlayerPlugin ()

@property (nonatomic, copy, nullable) NSString *activeCallbackId;

@end

@implementation TsNativePlayerPlugin

// ──────────────────────────────────────────────
// FIX: Use [TsPlaybackManager sharedManager] everywhere.
// ──────────────────────────────────────────────

- (TsPlaybackManager *)playbackManager {
    return [TsPlaybackManager sharedManager];
}

- (void)pluginInitialize {
    [super pluginInitialize];
}

- (void)onReset {
    [self.playbackManager stopPlayback];
    self.activeCallbackId = nil;
}

- (void)dispose {
    [self.playbackManager stopPlayback];
    self.activeCallbackId = nil;
}

#pragma mark - Warmup (Local Network Permission)

- (void)warmup:(CDVInvokedUrlCommand *)command {
    /*
     * Вызывается из JS при старте аппы.
     * Триггерит системный диалог Local Network Permission
     * ДО того, как пользователь попробует смотреть видео.
     *
     * JS:  TSNativePlayer.warmup({ host: '192.168.0.1', port: 80 }, cb, err)
     */

    NSDictionary *options = nil;
    if (command.arguments.count > 0 && [[command.arguments firstObject] isKindOfClass:[NSDictionary class]]) {
        options = [command.arguments firstObject];
    }

    NSString *host = [options objectForKey:@"host"] ?: @"192.168.0.1";
    NSInteger port = [[options objectForKey:@"port"] integerValue];
    if (port <= 0) port = 80;

    [[TsNetworkHelper sharedHelper] warmupLocalNetworkPermissionWithHost:host
                                                                   port:(uint16_t)port
                                                               callback:^(BOOL granted) {
        NSDictionary *payload = @{
            @"status": granted ? @"GRANTED" : @"DENIED",
            @"localNetworkGranted": @(granted)
        };
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
    }];
}

#pragma mark - Play (Fullscreen)

- (void)play:(CDVInvokedUrlCommand *)command {
    NSDictionary *options = nil;
    if (command.arguments.count > 0 && [[command.arguments firstObject] isKindOfClass:[NSDictionary class]]) {
        options = [command.arguments firstObject];
    }

    NSString *url = [options objectForKey:@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid URL"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    self.activeCallbackId = command.callbackId;

    __weak TsNativePlayerPlugin *weakSelf = self;
    [self.playbackManager startPlaybackWithURLString:url
                                             options:options ?: @{}
                                           presenter:self.viewController
                                              status:^(NSDictionary *payload, BOOL keepCallback) {
        TsNativePlayerPlugin *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeCallbackId) return;

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [result setKeepCallbackAsBool:keepCallback];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:strongSelf.activeCallbackId];

        if (!keepCallback) {
            strongSelf.activeCallbackId = nil;
        }
    } error:^(NSString *message) {
        TsNativePlayerPlugin *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeCallbackId) return;

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Unknown error"];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:strongSelf.activeCallbackId];
        strongSelf.activeCallbackId = nil;
    }];
}

#pragma mark - Play Inline

- (void)playInline:(CDVInvokedUrlCommand *)command {
    NSDictionary *options = command.arguments.count ? command.arguments[0] : @{};
    NSString *urlString = options[@"url"];
    NSDictionary *frameDict = options[@"frame"];

    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0 || ![frameDict isKindOfClass:[NSDictionary class]]) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid inline options"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    CGFloat x = [frameDict[@"x"] doubleValue];
    CGFloat y = [frameDict[@"y"] doubleValue];
    CGFloat width = [frameDict[@"width"] doubleValue];
    CGFloat height = [frameDict[@"height"] doubleValue];
    CGRect domFrame = CGRectMake(x, y, width, height);

    self.activeCallbackId = command.callbackId;

    __weak TsNativePlayerPlugin *weakSelf = self;
    [self.playbackManager startInlinePlaybackWithURLString:urlString
                                                   options:options
                                                 presenter:self.viewController
                                                   webView:self.webView
                                                     frame:domFrame
                                                    status:^(NSDictionary *payload, BOOL keepCallback) {
        TsNativePlayerPlugin *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeCallbackId) return;

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [pluginResult setKeepCallbackAsBool:keepCallback];
        [strongSelf.commandDelegate sendPluginResult:pluginResult callbackId:strongSelf.activeCallbackId];

        if (!keepCallback) {
            strongSelf.activeCallbackId = nil;
        }
    } error:^(NSString *message) {
        TsNativePlayerPlugin *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeCallbackId) return;

        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Unknown error"];
        [strongSelf.commandDelegate sendPluginResult:pluginResult callbackId:strongSelf.activeCallbackId];
        strongSelf.activeCallbackId = nil;
    }];
}

#pragma mark - Update Frame

- (void)updateInlineFrame:(CDVInvokedUrlCommand *)command {
    NSDictionary *frameDict = command.arguments.count ? command.arguments[0] : nil;
    if (![frameDict isKindOfClass:[NSDictionary class]]) {
        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:@"Invalid frame"];
        [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
        return;
    }

    CGFloat x = [frameDict[@"x"] doubleValue];
    CGFloat y = [frameDict[@"y"] doubleValue];
    CGFloat width = [frameDict[@"width"] doubleValue];
    CGFloat height = [frameDict[@"height"] doubleValue];
    CGRect domFrame = CGRectMake(x, y, width, height);

    [self.playbackManager updateInlineFrame:domFrame webView:self.webView];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

#pragma mark - Stop / Cleanup

- (void)stop:(CDVInvokedUrlCommand *)command {
    [self.playbackManager stopPlayback];
    self.activeCallbackId = nil;

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{ @"status": @"STOPPED" }];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)cleanup:(CDVInvokedUrlCommand *)command {
    [self.playbackManager cleanupAllFiles];
    self.activeCallbackId = nil;

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{ @"status": @"CLEANED" }];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end