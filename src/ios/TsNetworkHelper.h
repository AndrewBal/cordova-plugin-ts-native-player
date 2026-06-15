#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TsNetworkPermissionCallback)(BOOL granted);

@interface TsNetworkHelper : NSObject

+ (instancetype)sharedHelper;

/**
 * Trigger Local Network permission dialog by connecting to the dashcam.
 * Call this on app launch so the dialog appears early,
 * not when the user first tries to play a video.
 *
 * @param host  Dashcam IP, e.g. @"192.168.0.1"
 * @param port  HTTP port, typically 80
 * @param callback  Called with YES if local network is reachable, NO otherwise
 */
- (void)warmupLocalNetworkPermissionWithHost:(NSString *)host
                                        port:(uint16_t)port
                                    callback:(nullable TsNetworkPermissionCallback)callback;

/**
 * Returns YES if local network permission was previously granted
 * (based on last warmup result).
 */
@property (nonatomic, readonly) BOOL localNetworkGranted;

/**
 * Create an NSURLSessionConfiguration that forces WiFi-only routing.
 * Prevents iOS from sending requests to 192.168.x.x over 5G/LTE.
 */
+ (NSURLSessionConfiguration *)wifiOnlyEphemeralConfiguration;

@end

NS_ASSUME_NONNULL_END