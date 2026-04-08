#import "TsNativePlayerPlugin.h"
#import "TsPlaybackManager.h"

@interface TsNativePlayerPlugin ()

@property (nonatomic, strong) TsPlaybackManager *playbackManager;
@property (nonatomic, copy, nullable) NSString *activeCallbackId;

@end

@implementation TsNativePlayerPlugin

- (void)pluginInitialize {
    [super pluginInitialize];
    self.playbackManager = [[TsPlaybackManager alloc] init];
}

- (void)onReset {
    [self.playbackManager stopPlayback];
    self.activeCallbackId = nil;
}

- (void)dispose {
    [self.playbackManager stopPlayback];
    self.activeCallbackId = nil;
}

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
        if (!strongSelf || !strongSelf.activeCallbackId) {
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [result setKeepCallbackAsBool:keepCallback];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:strongSelf.activeCallbackId];

        if (!keepCallback) {
            strongSelf.activeCallbackId = nil;
        }
    } error:^(NSString *message) {
        TsNativePlayerPlugin *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.activeCallbackId) {
            return;
        }

        CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Unknown error"];
        [strongSelf.commandDelegate sendPluginResult:result callbackId:strongSelf.activeCallbackId];
        strongSelf.activeCallbackId = nil;
    }];
}

- (void)stop:(CDVInvokedUrlCommand *)command {
    [self.playbackManager stopPlayback];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{ @"status": @"STOPPED" }];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)cleanup:(CDVInvokedUrlCommand *)command {
    [self.playbackManager cleanupAllFiles];
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:@{ @"status": @"CLEANED" }];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}
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

    __weak TsNativePlayerPlugin *weakSelf = self;
    [[TsPlaybackManager sharedManager] startInlinePlaybackWithURLString:urlString
                                                               options:options
                                                             presenter:self.viewController
                                                               webView:self.webView
                                                                 frame:domFrame
                                                                status:^(NSDictionary *payload, BOOL keepCallback) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK messageAsDictionary:payload];
        [pluginResult setKeepCallbackAsBool:keepCallback];
        [weakSelf.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    } error:^(NSString *message) {
        CDVPluginResult *pluginResult = [CDVPluginResult resultWithStatus:CDVCommandStatus_ERROR messageAsString:message ?: @"Unknown error"];
        [weakSelf.commandDelegate sendPluginResult:pluginResult callbackId:command.callbackId];
    }];
}

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

    [[TsPlaybackManager sharedManager] updateInlineFrame:domFrame webView:self.webView];

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

@end
