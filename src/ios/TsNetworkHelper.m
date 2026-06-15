#import "TsNetworkHelper.h"
#import <Network/Network.h>
#import <SystemConfiguration/CaptiveNetwork.h>
#import <net/if.h>
#import <ifaddrs.h>
#import <arpa/inet.h>

@interface TsNetworkHelper ()

@property (nonatomic, assign) BOOL localNetworkGranted;
@property (nonatomic, strong, nullable) dispatch_queue_t networkQueue;

@end

@implementation TsNetworkHelper

+ (instancetype)sharedHelper {
    static TsNetworkHelper *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[TsNetworkHelper alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _localNetworkGranted = NO;
        _networkQueue = dispatch_queue_create("com.tsnativeplayer.network", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Local Network Permission Warmup

- (void)warmupLocalNetworkPermissionWithHost:(NSString *)host
                                        port:(uint16_t)port
                                    callback:(nullable TsNetworkPermissionCallback)callback {
    /*
     * На iOS 14+ первое TCP-соединение к локальному IP вызывает
     * системный диалог "allow local network access".
     *
     * Если вызвать это при запуске аппы (а не при первом play),
     * пользователь увидит диалог заранее, и к моменту playback
     * разрешение уже будет.
     *
     * Используем Network.framework (NWConnection) — это самый
     * надёжный способ триггернуть диалог.
     */

    if (@available(iOS 14.0, *)) {
        [self triggerPermissionViaNWConnectionToHost:host port:port callback:callback];
    } else {
        // iOS <14 не имеет Local Network permission
        self.localNetworkGranted = YES;
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(YES);
            });
        }
    }
}

- (void)triggerPermissionViaNWConnectionToHost:(NSString *)host
                                         port:(uint16_t)port
                                     callback:(nullable TsNetworkPermissionCallback)callback API_AVAILABLE(ios(14.0)) {
    nw_endpoint_t endpoint = nw_endpoint_create_host(
        [host UTF8String],
        [[NSString stringWithFormat:@"%d", port] UTF8String]
    );

    // Создаём TCP-параметры с привязкой к WiFi
    nw_parameters_t params = nw_parameters_create_secure_tcp(
        NW_PARAMETERS_DISABLE_PROTOCOL,  // без TLS
        NW_PARAMETERS_DEFAULT_CONFIGURATION  // TCP defaults
    );

    // Запрещаем cellular — только WiFi
    nw_parameters_set_prohibit_expensive(params, true);

    // Требуем direct path (WiFi, не relay)
    nw_parameters_set_prefer_no_proxy(params, true);

    nw_connection_t connection = nw_connection_create(endpoint, params);
    nw_connection_set_queue(connection, self.networkQueue);

    __weak TsNetworkHelper *weakSelf = self;
    __block BOOL didComplete = NO;
    __block nw_connection_t strongConnection = connection;  // prevent premature release

    nw_connection_set_state_changed_handler(connection, ^(nw_connection_state_t state, nw_error_t _Nullable error) {
        if (didComplete) return;

        switch (state) {
            case nw_connection_state_ready: {
                // Соединение установлено — permission granted, сеть доступна
                didComplete = YES;
                weakSelf.localNetworkGranted = YES;

                NSLog(@"[TsNetworkHelper] Local network permission granted, host reachable: %@", host);

                nw_connection_cancel(strongConnection);
                strongConnection = nil;

                if (callback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        callback(YES);
                    });
                }
                break;
            }

            case nw_connection_state_waiting: {
                // Ждём — диалог permission может быть на экране, или нет WiFi
                NSLog(@"[TsNetworkHelper] Waiting for local network access (permission dialog may be showing)");
                break;
            }

            case nw_connection_state_failed: {
                didComplete = YES;

                // Может быть: permission denied, нет WiFi, камера не подключена
                int errorCode = error ? nw_error_get_error_code(error) : 0;
                NSLog(@"[TsNetworkHelper] Local network check failed: code=%d", errorCode);

                weakSelf.localNetworkGranted = NO;
                nw_connection_cancel(strongConnection);
                strongConnection = nil;

                if (callback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        callback(NO);
                    });
                }
                break;
            }

            case nw_connection_state_cancelled: {
                strongConnection = nil;
                break;
            }

            default:
                break;
        }
    });

    nw_connection_start(connection);

    // Таймаут 10с — если за это время нет ответа, считаем что не доступно.
    // (Даёт пользователю время нажать Allow в системном диалоге)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), self.networkQueue, ^{
        if (didComplete) return;
        didComplete = YES;

        NSLog(@"[TsNetworkHelper] Local network warmup timed out");
        weakSelf.localNetworkGranted = NO;
        nw_connection_cancel(strongConnection);
        strongConnection = nil;

        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(NO);
            });
        }
    });
}

#pragma mark - WiFi-only Session Configuration

+ (NSURLSessionConfiguration *)wifiOnlyEphemeralConfiguration {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];

    // ──────────────────────────────────────────
    // КЛЮЧЕВОЕ: запрещаем cellular / 5G / LTE
    // Это заставляет NSURLSession роутить через WiFi
    // ──────────────────────────────────────────
    config.allowsCellularAccess = NO;

    if (@available(iOS 13.0, *)) {
        config.allowsExpensiveNetworkAccess = NO;      // блокирует cellular + personal hotspot
        config.allowsConstrainedNetworkAccess = YES;   // разрешаем даже в Low Data Mode
    }

    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 600.0;
    config.connectionProxyDictionary = @{};  // без прокси

    if (@available(iOS 11.0, *)) {
        config.waitsForConnectivity = NO;
    }

    return config;
}

#pragma mark - WiFi Info (diagnostic)

+ (nullable NSString *)currentWiFiSSID {
    NSString *ssid = nil;

    if (@available(iOS 14.0, *)) {
        // На iOS 14+ нужен entitlement com.apple.developer.networking.wifi-info
        // Без него CNCopyCurrentNetworkInfo возвращает nil
    }

    NSArray *interfaces = (__bridge_transfer NSArray *)CNCopySupportedInterfaces();
    for (NSString *interface in interfaces) {
        NSDictionary *info = (__bridge_transfer NSDictionary *)CNCopyCurrentNetworkInfo((__bridge CFStringRef)interface);
        if (info[@"SSID"]) {
            ssid = info[@"SSID"];
            break;
        }
    }

    return ssid;
}

+ (nullable NSString *)wifiIPAddress {
    struct ifaddrs *interfaces = NULL;
    struct ifaddrs *addr = NULL;
    NSString *wifiIP = nil;

    if (getifaddrs(&interfaces) == 0) {
        addr = interfaces;
        while (addr != NULL) {
            if (addr->ifa_addr->sa_family == AF_INET) {
                NSString *ifName = [NSString stringWithUTF8String:addr->ifa_name];
                if ([ifName isEqualToString:@"en0"]) {
                    // en0 = WiFi interface
                    char addrBuf[INET_ADDRSTRLEN];
                    struct sockaddr_in *sockAddr = (struct sockaddr_in *)addr->ifa_addr;
                    inet_ntop(AF_INET, &sockAddr->sin_addr, addrBuf, INET_ADDRSTRLEN);
                    wifiIP = [NSString stringWithUTF8String:addrBuf];
                    break;
                }
            }
            addr = addr->ifa_next;
        }
        freeifaddrs(interfaces);
    }

    return wifiIP;
}

@end