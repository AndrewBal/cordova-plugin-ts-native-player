#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <MobileVLCKit/MobileVLCKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TsPlaybackStatusBlock)(NSDictionary *result, BOOL keepCallback);
typedef void (^TsPlaybackErrorBlock)(NSString *message);

@interface TsPlaybackManager : NSObject <VLCMediaPlayerDelegate>

+ (instancetype)sharedManager;

- (void)startPlaybackWithURLString:(NSString *)urlString
                           options:(NSDictionary *)options
                         presenter:(UIViewController *)presenter
                            status:(TsPlaybackStatusBlock)status
                             error:(TsPlaybackErrorBlock)error;

- (void)startInlinePlaybackWithURLString:(NSString *)urlString
                                 options:(NSDictionary *)options
                               presenter:(UIViewController *)presenter
                                  webView:(UIView *)webView
                                   frame:(CGRect)domFrame
                                  status:(TsPlaybackStatusBlock)status
                                   error:(TsPlaybackErrorBlock)error;

- (void)updateInlineFrame:(CGRect)domFrame webView:(UIView *)webView;
- (void)stopPlayback;
- (void)cleanupAllFiles;

- (void)stop;
- (void)cleanup;

@end

NS_ASSUME_NONNULL_END