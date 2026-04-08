#import <Cordova/CDV.h>

@interface TsNativePlayerPlugin : CDVPlugin

- (void)play:(CDVInvokedUrlCommand *)command;
- (void)stop:(CDVInvokedUrlCommand *)command;
- (void)cleanup:(CDVInvokedUrlCommand *)command;

@end
