#import <Cordova/CDV.h>

@interface TsNativePlayerPlugin : CDVPlugin

- (void)play:(CDVInvokedUrlCommand *)command;
- (void)playInline:(CDVInvokedUrlCommand *)command;
- (void)updateInlineFrame:(CDVInvokedUrlCommand *)command;
- (void)stop:(CDVInvokedUrlCommand *)command;
- (void)cleanup:(CDVInvokedUrlCommand *)command;
- (void)warmup:(CDVInvokedUrlCommand *)command;

@end