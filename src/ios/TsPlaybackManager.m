#import "TsPlaybackManager.h"
#import "TsPlayerViewController.h"

#import <MobileVLCKit/MobileVLCKit.h>
#import <UIKit/UIKit.h>

@interface TsPlaybackManager () <VLCMediaPlayerDelegate>

@property (nonatomic, strong, nullable) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *downloadTask;
@property (nonatomic, strong, nullable) TsPlayerViewController *playerViewController;
@property (nonatomic, strong, nullable) VLCMediaPlayer *mediaPlayer;

@property (nonatomic, copy, nullable) NSString *currentFilePath;
@property (nonatomic, copy, nullable) NSString *currentTitle;
@property (nonatomic, assign) BOOL deleteAfterPlayback;
@property (nonatomic, assign) BOOL didSendClosed;
@property (nonatomic, assign) BOOL isStopping;
@property (nonatomic, assign) BOOL hasStartedPlayback;
@property (nonatomic, assign) BOOL isUserSeeking;
@property (nonatomic, assign) BOOL wasPlayingBeforeSeek;

@property (nonatomic, copy, nullable) TsPlaybackStatusBlock statusBlock;
@property (nonatomic, copy, nullable) TsPlaybackErrorBlock errorBlock;

@property (nonatomic, copy, nullable) NSString *currentRemoteURLString;
@property (nonatomic, assign) BOOL didFallbackToDownload;
@property (nonatomic, assign) BOOL useDirectRemotePlayback;
@property (nonatomic, strong, nullable) NSTimer *startupFallbackTimer;
@property (nonatomic, assign) BOOL isInlineMode;
@property (nonatomic, weak, nullable) UIViewController *inlinePresenter;
@property (nonatomic, weak, nullable) UIView *inlineWebView;

@end

@implementation TsPlaybackManager

+ (instancetype)sharedManager {
    static TsPlaybackManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[TsPlaybackManager alloc] init];
    });
    return sharedInstance;
}

- (void)startInlinePlaybackWithURLString:(NSString *)urlString
                                 options:(NSDictionary *)options
                               presenter:(UIViewController *)presenter
                                 webView:(UIView *)webView
                                   frame:(CGRect)domFrame
                                  status:(TsPlaybackStatusBlock)status
                                   error:(TsPlaybackErrorBlock)error {
    [self resetActivePlaybackStatePreservingBlocks:NO];

    self.statusBlock = status;
    self.errorBlock = error;
    self.currentTitle = [options objectForKey:@"title"] ?: @"Playback";
    self.currentRemoteURLString = urlString;
    self.didSendClosed = NO;
    self.isStopping = NO;
    self.hasStartedPlayback = NO;
    self.isUserSeeking = NO;
    self.wasPlayingBeforeSeek = NO;
    self.didFallbackToDownload = NO;
    self.useDirectRemotePlayback = YES;

    self.isInlineMode = YES;
    self.inlinePresenter = presenter;
    self.inlineWebView = webView;

    NSURL *remoteURL = [NSURL URLWithString:urlString ?: @""];
    if (!remoteURL || !remoteURL.scheme || !remoteURL.host) {
        [self sendError:@"Invalid URL"];
        return;
    }

    [self sendStatus:@{
        @"status": @"OPENING_REMOTE",
        @"url": urlString ?: @"",
        @"inline": @YES
    } keepCallback:YES];

    [self attachInlinePlayerForRemoteURL:remoteURL presenter:presenter webView:webView domFrame:domFrame];
}

- (void)attachInlinePlayerForRemoteURL:(NSURL *)remoteURL
                             presenter:(UIViewController *)presenter
                               webView:(UIView *)webView
                              domFrame:(CGRect)domFrame {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = [self topMostPresenterFrom:presenter];
        if (!host || !webView) {
            [self sendError:@"Cannot mount inline player"];
            return;
        }

        self.playerViewController = [[TsPlayerViewController alloc] init];
        [self.playerViewController loadViewIfNeeded];
        [self.playerViewController setLoadingVisible:YES];
        [self.playerViewController setPlaying:YES];
        [self.playerViewController updatePlaybackTime:@"00:00" duration:@"--:--"];
        [self.playerViewController updateSeekPosition:0.0f];
        [self.playerViewController setControlsHidden:NO animated:NO];

        CGRect nativeFrame = [self nativeFrameFromDOMFrame:domFrame webView:webView inHost:host];
        self.playerViewController.view.frame = nativeFrame;
        self.playerViewController.view.clipsToBounds = YES;
        self.playerViewController.view.layer.cornerRadius = 12.0;

        [host addChildViewController:self.playerViewController];
        [host.view addSubview:self.playerViewController.view];
        [self.playerViewController didMoveToParentViewController:host];

        __weak TsPlaybackManager *weakSelf = self;

        self.playerViewController.onClose = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf stopPlayback];
        };

        self.playerViewController.onPlayPauseTapped = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            if (strongSelf.mediaPlayer.isPlaying) {
                [strongSelf.mediaPlayer pause];
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController setControlsHidden:NO animated:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PAUSED", @"inline": @YES } keepCallback:YES];
            } else {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PLAYING", @"inline": @YES } keepCallback:YES];
            }
        };

        self.playerViewController.onSeekStarted = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;
            strongSelf.isUserSeeking = YES;
            strongSelf.wasPlayingBeforeSeek = strongSelf.mediaPlayer.isPlaying;
        };

        self.playerViewController.onSeekChanged = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            NSString *current = [strongSelf stringForApproximateTimeAtPosition:position];
            NSString *duration = [strongSelf stringForMediaLength];
            [strongSelf.playerViewController updatePlaybackTime:current duration:duration];
        };

        self.playerViewController.onSeekEnded = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            strongSelf.mediaPlayer.position = position;
            strongSelf.isUserSeeking = NO;
            [strongSelf.playerViewController updateSeekPosition:position];

            if (strongSelf.wasPlayingBeforeSeek) {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
            } else {
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
            }
        };

        self.mediaPlayer = [[VLCMediaPlayer alloc] init];
        self.mediaPlayer.delegate = self;
        self.mediaPlayer.drawable = [self.playerViewController videoContainerView];

        VLCMedia *media = [VLCMedia mediaWithURL:remoteURL];
        [media addOption:@":network-caching=500"];
        [media addOption:@":clock-jitter=0"];
        [media addOption:@":clock-synchro=0"];
        self.mediaPlayer.media = media;

        [self sendStatus:@{
            @"status": @"OPENING",
            @"inline": @YES,
            @"url": remoteURL.absoluteString ?: @""
        } keepCallback:YES];

        [self startRemoteStartupFallbackTimerWithPresenter:presenter remoteURL:remoteURL];
        [self.mediaPlayer play];
    });
}

- (CGRect)nativeFrameFromDOMFrame:(CGRect)domFrame
                          webView:(UIView *)webView
                           inHost:(UIViewController *)host {
    return [webView convertRect:domFrame toView:host.view];
}

- (void)updateInlineFrame:(CGRect)domFrame webView:(UIView *)webView {
    if (!self.isInlineMode || !self.playerViewController || !webView) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *host = self.playerViewController.parentViewController;
        if (!host) {
            return;
        }

        CGRect nativeFrame = [self nativeFrameFromDOMFrame:domFrame webView:webView inHost:host];
        self.playerViewController.view.frame = nativeFrame;
    });
}

- (void)dealloc {
    [self invalidateSession];
    [self teardownMediaPlayer];
}

- (void)startPlaybackWithURLString:(NSString *)urlString
                           options:(NSDictionary *)options
                         presenter:(UIViewController *)presenter
                            status:(TsPlaybackStatusBlock)statusBlock
                             error:(TsPlaybackErrorBlock)errorBlock {
    [self resetActivePlaybackStatePreservingBlocks:NO];

    self.statusBlock = statusBlock;
    self.errorBlock = errorBlock;
    self.deleteAfterPlayback = ![options objectForKey:@"deleteAfterPlayback"] || [[options objectForKey:@"deleteAfterPlayback"] boolValue];
    self.currentTitle = [options objectForKey:@"title"] ?: @"Playback";
    self.currentRemoteURLString = urlString;
    self.didSendClosed = NO;
    self.isStopping = NO;
    self.hasStartedPlayback = NO;
    self.isUserSeeking = NO;
    self.wasPlayingBeforeSeek = NO;
    self.didFallbackToDownload = NO;

    // по умолчанию пробуем direct remote playback
    self.useDirectRemotePlayback = ![options objectForKey:@"forceDownloadFirst"];
    
    NSURL *remoteURL = [NSURL URLWithString:urlString ?: @""];
    if (!remoteURL || !remoteURL.scheme || !remoteURL.host) {
        [self sendError:@"Invalid URL"];
        return;
    }

    // только для http/https
    BOOL isHTTP = [[remoteURL.scheme lowercaseString] isEqualToString:@"http"] ||
                  [[remoteURL.scheme lowercaseString] isEqualToString:@"https"];

    if (self.useDirectRemotePlayback && isHTTP) {
        [self sendStatus:@{
            @"status": @"OPENING_REMOTE",
            @"url": urlString ?: @""
        } keepCallback:YES];

        [self presentPlayerForRemoteURL:remoteURL presenter:presenter];
        return;
    }

    [self startDownloadPlaybackFromRemoteURL:remoteURL presenter:presenter originalURLString:urlString];
}

- (void)presentPlayerForRemoteURL:(NSURL *)remoteURL presenter:(UIViewController *)presenter {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topPresenter = [self topMostPresenterFrom:presenter];
        if (!topPresenter) {
            [self sendError:@"Cannot open player: presenter unavailable"];
            return;
        }

        self.playerViewController = [[TsPlayerViewController alloc] init];
        self.playerViewController.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.playerViewController setLoadingVisible:YES];
        [self.playerViewController setPlaying:YES];
        [self.playerViewController updatePlaybackTime:@"00:00" duration:@"--:--"];
        [self.playerViewController updateSeekPosition:0.0f];
        [self.playerViewController setControlsHidden:NO animated:NO];

        __weak TsPlaybackManager *weakSelf = self;

        self.playerViewController.onClose = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf stopPlayback];
        };

        self.playerViewController.onPlayPauseTapped = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            if (strongSelf.mediaPlayer.isPlaying) {
                [strongSelf.mediaPlayer pause];
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController setControlsHidden:NO animated:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PAUSED" } keepCallback:YES];
            } else {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PLAYING" } keepCallback:YES];
            }
        };

        self.playerViewController.onSeekStarted = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;
            strongSelf.isUserSeeking = YES;
            strongSelf.wasPlayingBeforeSeek = strongSelf.mediaPlayer.isPlaying;
        };

        self.playerViewController.onSeekChanged = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            NSString *current = [strongSelf stringForApproximateTimeAtPosition:position];
            NSString *duration = [strongSelf stringForMediaLength];
            [strongSelf.playerViewController updatePlaybackTime:current duration:duration];
        };

        self.playerViewController.onSeekEnded = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) return;

            strongSelf.mediaPlayer.position = position;
            strongSelf.isUserSeeking = NO;
            [strongSelf.playerViewController updateSeekPosition:position];

            if (strongSelf.wasPlayingBeforeSeek) {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
            } else {
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
            }
        };

        [topPresenter presentViewController:self.playerViewController animated:YES completion:^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) return;

            strongSelf.mediaPlayer = [[VLCMediaPlayer alloc] init];
            strongSelf.mediaPlayer.delegate = strongSelf;
            strongSelf.mediaPlayer.drawable = [strongSelf.playerViewController videoContainerView];

            VLCMedia *media = [VLCMedia mediaWithURL:remoteURL];

            // Пробуем уменьшить стартовую буферизацию.
            // Для сетевого ресурса используем network-caching в миллисекундах.
            [media addOption:@":network-caching=500"];
            [media addOption:@":clock-jitter=0"];
            [media addOption:@":clock-synchro=0"];

            strongSelf.mediaPlayer.media = media;

            [strongSelf sendStatus:@{
                @"status": @"OPENING",
                @"remote": @YES,
                @"url": remoteURL.absoluteString ?: @""
            } keepCallback:YES];

            [strongSelf startRemoteStartupFallbackTimerWithPresenter:presenter remoteURL:remoteURL];
            [strongSelf.mediaPlayer play];
        }];
    });
}
- (void)startRemoteStartupFallbackTimerWithPresenter:(UIViewController *)presenter remoteURL:(NSURL *)remoteURL {
    [self invalidateStartupFallbackTimer];

    __weak TsPlaybackManager *weakSelf = self;
    self.startupFallbackTimer = [NSTimer scheduledTimerWithTimeInterval:4.0
                                                                repeats:NO
                                                                  block:^(NSTimer * _Nonnull timer) {
        TsPlaybackManager *strongSelf = weakSelf;
        if (!strongSelf || strongSelf.isStopping) {
            return;
        }

        if (strongSelf.hasStartedPlayback) {
            return;
        }

        if (strongSelf.didFallbackToDownload) {
            return;
        }

        strongSelf.didFallbackToDownload = YES;

        [strongSelf teardownMediaPlayer];
        [strongSelf.playerViewController setLoadingVisible:YES];

        [strongSelf sendStatus:@{
            @"status": @"FALLBACK_TO_DOWNLOAD"
        } keepCallback:YES];

        [strongSelf startDownloadPlaybackFromRemoteURL:remoteURL
                                             presenter:presenter
                                     originalURLString:strongSelf.currentRemoteURLString ?: remoteURL.absoluteString];
    }];
}

- (void)invalidateStartupFallbackTimer {
    [self.startupFallbackTimer invalidate];
    self.startupFallbackTimer = nil;
}
- (void)startDownloadPlaybackFromRemoteURL:(NSURL *)remoteURL
                                 presenter:(UIViewController *)presenter
                         originalURLString:(NSString *)urlString {
    [self sendStatus:@{
        @"status": @"DOWNLOADING",
        @"url": urlString ?: @""
    } keepCallback:YES];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.URLCache = nil;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 600.0;
    config.connectionProxyDictionary = @{};
    if (@available(iOS 11.0, *)) {
        config.waitsForConnectivity = NO;
    }
    if (@available(iOS 13.0, *)) {
        config.allowsExpensiveNetworkAccess = YES;
        config.allowsConstrainedNetworkAccess = YES;
    }

    self.session = [NSURLSession sessionWithConfiguration:config
                                                 delegate:nil
                                            delegateQueue:[NSOperationQueue mainQueue]];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:remoteURL];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    request.timeoutInterval = 30.0;

    __weak TsPlaybackManager *weakSelf = self;
    self.downloadTask = [self.session downloadTaskWithRequest:request
                                            completionHandler:^(NSURL * _Nullable location,
                                                                NSURLResponse * _Nullable response,
                                                                NSError * _Nullable error) {
        TsPlaybackManager *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }

        if (strongSelf.isStopping) {
            return;
        }

        if (error) {
            if (error.code == NSURLErrorCancelled) {
                [strongSelf sendClosedIfNeeded];
                return;
            }
            [strongSelf sendError:[NSString stringWithFormat:@"Download failed: %@", error.localizedDescription ?: @"Unknown error"]];
            return;
        }

        if (!location) {
            [strongSelf sendError:@"Download failed: temporary file missing"];
            return;
        }

        NSError *fileError = nil;
        NSString *targetPath = [strongSelf moveDownloadedFileFromLocation:location
                                                                 response:response
                                                                remoteURL:remoteURL
                                                                    error:&fileError];
        if (!targetPath || fileError) {
            [strongSelf sendError:[NSString stringWithFormat:@"Failed to save file: %@", fileError.localizedDescription ?: @"Unknown error"]];
            return;
        }

        strongSelf.currentFilePath = targetPath;

        [strongSelf sendStatus:@{
            @"status": @"DOWNLOAD_COMPLETE",
            @"localPath": targetPath
        } keepCallback:YES];

        [strongSelf sendStatus:@{
            @"status": @"READY",
            @"localPath": targetPath
        } keepCallback:YES];

        [strongSelf presentPlayerForLocalFilePath:targetPath presenter:presenter];
    }];

    [self.downloadTask resume];
}
- (void)stopPlayback {
    if (self.isStopping) {
        return;
    }

    self.isStopping = YES;
    [self invalidateStartupFallbackTimer];

    if (self.downloadTask) {
        [self.downloadTask cancel];
        self.downloadTask = nil;
    }

    if (self.mediaPlayer) {
        self.mediaPlayer.delegate = nil;
        self.mediaPlayer.drawable = nil;
        [self.mediaPlayer stop];
        self.mediaPlayer = nil;
    }

    if (self.isInlineMode) {
        [self removeInlinePlayerViewIfNeeded];
        [self sendClosedIfNeeded];
        [self resetActivePlaybackStatePreservingBlocks:NO];
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.playerViewController.presentingViewController) {
            [self.playerViewController dismissViewControllerAnimated:YES completion:^{
                [self sendClosedIfNeeded];
                [self resetActivePlaybackStatePreservingBlocks:NO];
            }];
        } else {
            [self sendClosedIfNeeded];
            [self resetActivePlaybackStatePreservingBlocks:NO];
        }
    });
}

- (void)cleanupAllFiles {
    [self stopPlayback];

    NSString *rootPath = [self tempRootPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:rootPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:rootPath error:nil];
    }
}

- (void)stop {
    [self stopPlayback];
}

- (void)cleanup {
    [self cleanupAllFiles];
}

#pragma mark - Download helpers

- (NSString *)moveDownloadedFileFromLocation:(NSURL *)location
                                    response:(NSURLResponse * _Nullable)response
                                   remoteURL:(NSURL *)remoteURL
                                       error:(NSError **)error {
    NSString *rootPath = [self tempRootPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:rootPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    NSString *filename = response.suggestedFilename.length ? response.suggestedFilename : remoteURL.lastPathComponent;
    if (filename.length == 0) {
        filename = [NSString stringWithFormat:@"video_%@.TS", @((long long)([[NSDate date] timeIntervalSince1970] * 1000))];
    }

    if (![[filename lowercaseString] hasSuffix:@".ts"]) {
        filename = [[filename stringByDeletingPathExtension] stringByAppendingPathExtension:@"TS"];
    }

    NSString *uniqueName = [NSString stringWithFormat:@"%@_%@",
                            @((long long)([[NSDate date] timeIntervalSince1970] * 1000)),
                            filename];
    NSString *targetPath = [rootPath stringByAppendingPathComponent:uniqueName];

    if ([[NSFileManager defaultManager] fileExistsAtPath:targetPath]) {
        [[NSFileManager defaultManager] removeItemAtPath:targetPath error:nil];
    }

    BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:location
                                                         toURL:[NSURL fileURLWithPath:targetPath]
                                                         error:error];
    return moved ? targetPath : nil;
}

- (NSString *)tempRootPath {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:@"TsNativePlayer"];
}

#pragma mark - Player

- (void)presentPlayerForLocalFilePath:(NSString *)filePath presenter:(UIViewController *)presenter {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *topPresenter = [self topMostPresenterFrom:presenter];
        if (!topPresenter) {
            [self sendError:@"Cannot open player: presenter unavailable"];
            return;
        }

        self.playerViewController = [[TsPlayerViewController alloc] init];
        self.playerViewController.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.playerViewController setLoadingVisible:YES];
        [self.playerViewController setPlaying:YES];
        [self.playerViewController updatePlaybackTime:@"00:00" duration:@"--:--"];
        [self.playerViewController updateSeekPosition:0.0f];
        [self.playerViewController setControlsHidden:NO animated:NO];

        __weak TsPlaybackManager *weakSelf = self;

        self.playerViewController.onClose = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf stopPlayback];
        };

        self.playerViewController.onPlayPauseTapped = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) {
                return;
            }

            if (strongSelf.mediaPlayer.isPlaying) {
                [strongSelf.mediaPlayer pause];
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController setControlsHidden:NO animated:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PAUSED" } keepCallback:YES];
            } else {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
                [strongSelf sendStatus:@{ @"status": @"PLAYING" } keepCallback:YES];
            }
        };

        self.playerViewController.onSeekStarted = ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) {
                return;
            }
            strongSelf.isUserSeeking = YES;
            strongSelf.wasPlayingBeforeSeek = strongSelf.mediaPlayer.isPlaying;
        };

        self.playerViewController.onSeekChanged = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) {
                return;
            }

            NSString *current = [strongSelf stringForApproximateTimeAtPosition:position];
            NSString *duration = [strongSelf stringForMediaLength];
            [strongSelf.playerViewController updatePlaybackTime:current duration:duration];
        };

        self.playerViewController.onSeekEnded = ^(float position) {
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.mediaPlayer) {
                return;
            }

            strongSelf.mediaPlayer.position = position;
            strongSelf.isUserSeeking = NO;
            [strongSelf.playerViewController updateSeekPosition:position];

            if (strongSelf.wasPlayingBeforeSeek) {
                [strongSelf.mediaPlayer play];
                [strongSelf.playerViewController setPlaying:YES];
                [strongSelf.playerViewController restartAutoHideTimer];
            } else {
                [strongSelf.playerViewController setPlaying:NO];
                [strongSelf.playerViewController invalidateAutoHideTimer];
            }
        };

        [topPresenter presentViewController:self.playerViewController animated:YES completion:^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }

            strongSelf.mediaPlayer = [[VLCMediaPlayer alloc] init];
            strongSelf.mediaPlayer.delegate = strongSelf;
            strongSelf.mediaPlayer.drawable = [strongSelf.playerViewController videoContainerView];

            NSURL *localURL = [NSURL fileURLWithPath:filePath];
            VLCMedia *media = [VLCMedia mediaWithURL:localURL];
            strongSelf.mediaPlayer.media = media;

            [strongSelf sendStatus:@{
                @"status": @"OPENING",
                @"localPath": filePath
            } keepCallback:YES];

            [strongSelf.mediaPlayer play];
        }];
    });
}

- (UIViewController *)topMostPresenterFrom:(UIViewController *)presenter {
    UIViewController *top = presenter;

    if (!top) {
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive &&
                    [scene isKindOfClass:[UIWindowScene class]]) {
                    for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                }
                if (keyWindow) {
                    break;
                }
            }
        } else {
            keyWindow = [UIApplication sharedApplication].keyWindow;
        }
        top = keyWindow.rootViewController;
    }

    while (top.presentedViewController) {
        top = top.presentedViewController;
    }

    return top;
}

- (void)dismissPlayerAndFinalize {
    if (self.playerViewController.presentingViewController) {
        self.isStopping = YES;
        __weak TsPlaybackManager *weakSelf = self;
        [self.playerViewController dismissViewControllerAnimated:YES completion:^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            [strongSelf sendClosedIfNeeded];
            [strongSelf resetActivePlaybackStatePreservingBlocks:NO];
        }];
    } else {
        [self sendClosedIfNeeded];
        [self resetActivePlaybackStatePreservingBlocks:NO];
    }
}

- (void)teardownMediaPlayer {
    if (self.mediaPlayer) {
        self.mediaPlayer.delegate = nil;
        self.mediaPlayer.drawable = nil;
        [self.mediaPlayer stop];
        self.mediaPlayer = nil;
    }
}

#pragma mark - VLCMediaPlayerDelegate

- (void)mediaPlayerStateChanged:(NSNotification *)aNotification {
    if (!self.mediaPlayer || self.isStopping) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        switch (self.mediaPlayer.state) {
            case VLCMediaPlayerStateOpening:
                [self.playerViewController setLoadingVisible:!self.hasStartedPlayback];
                [self.playerViewController setPlaying:YES];
                [self sendStatus:@{ @"status": @"OPENING" } keepCallback:YES];
                break;

            case VLCMediaPlayerStateBuffering:
                [self.playerViewController setLoadingVisible:!self.hasStartedPlayback];
                [self sendStatus:@{ @"status": @"BUFFERING" } keepCallback:YES];
                break;

            case VLCMediaPlayerStatePlaying:
                self.hasStartedPlayback = YES;
                [self invalidateStartupFallbackTimer];
                [self.playerViewController setLoadingVisible:NO];
                [self.playerViewController setPlaying:YES];
                [self.playerViewController restartAutoHideTimer];
                [self sendStatus:@{ @"status": @"PLAYING" } keepCallback:YES];
                break;

            case VLCMediaPlayerStatePaused:
                [self.playerViewController setLoadingVisible:NO];
                [self.playerViewController setPlaying:NO];
                [self.playerViewController setControlsHidden:NO animated:YES];
                [self.playerViewController invalidateAutoHideTimer];
                [self sendStatus:@{ @"status": @"PAUSED" } keepCallback:YES];
                break;

            case VLCMediaPlayerStateEnded:
                [self.playerViewController setLoadingVisible:NO];
                [self sendStatus:@{ @"status": @"FINISHED" } keepCallback:YES];
                [self stopPlayback];
                break;

            case VLCMediaPlayerStateError: {
                [self playerFailedBeforeStartMaybeFallback];
                break;
            }

            case VLCMediaPlayerStateStopped:
                [self.playerViewController setLoadingVisible:NO];
                if (!self.isStopping) {
                    [self sendStatus:@{ @"status": @"STOPPED" } keepCallback:YES];
                }
                break;

            default:
                break;
        }
    });
}

- (void)playerFailedBeforeStartMaybeFallback {
    [self.playerViewController setLoadingVisible:NO];

    if (!self.hasStartedPlayback && !self.didFallbackToDownload && self.currentRemoteURLString.length) {
        self.didFallbackToDownload = YES;

        NSURL *remoteURL = [NSURL URLWithString:self.currentRemoteURLString];
        UIViewController *presenter = [self topMostPresenterFrom:nil];

        [self teardownMediaPlayer];

        [self sendStatus:@{ @"status": @"FALLBACK_TO_DOWNLOAD" } keepCallback:YES];
        [self startDownloadPlaybackFromRemoteURL:remoteURL
                                       presenter:presenter
                               originalURLString:self.currentRemoteURLString];
        return;
    }

    NSString *stateName = VLCMediaPlayerStateToString(self.mediaPlayer.state) ?: @"Error";
    [self sendError:[NSString stringWithFormat:@"VLC playback failed: %@", stateName]];
}

- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification {
    if (!self.mediaPlayer || self.isStopping) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *current = [self stringForCurrentPlaybackTime];
        NSString *duration = [self stringForMediaLength];
        [self.playerViewController updatePlaybackTime:current duration:duration];

        if (!self.isUserSeeking) {
            [self.playerViewController updateSeekPosition:self.mediaPlayer.position];
        }
    });
}

#pragma mark - Formatting helpers

- (NSString *)stringForCurrentPlaybackTime {
    VLCTime *time = self.mediaPlayer.time;
    if (time && time.intValue >= 0) {
        return [self formatSeconds:(int)(time.intValue / 1000)];
    }
    return @"00:00";
}

- (NSString *)stringForMediaLength {
    VLCTime *length = self.mediaPlayer.media.length;
    if (length && length.intValue > 0) {
        return [self formatSeconds:(int)(length.intValue / 1000)];
    }
    return @"--:--";
}

- (NSString *)stringForApproximateTimeAtPosition:(float)position {
    VLCTime *length = self.mediaPlayer.media.length;
    if (!length || length.intValue <= 0) {
        return [self stringForCurrentPlaybackTime];
    }

    int totalSeconds = MAX(0, (int)(length.intValue / 1000));
    int currentSeconds = MAX(0, (int)roundf(totalSeconds * position));
    return [self formatSeconds:currentSeconds];
}

- (NSString *)formatSeconds:(int)seconds {
    int hours = seconds / 3600;
    int minutes = (seconds % 3600) / 60;
    int secs = seconds % 60;

    if (hours > 0) {
        return [NSString stringWithFormat:@"%d:%02d:%02d", hours, minutes, secs];
    }
    return [NSString stringWithFormat:@"%02d:%02d", minutes, secs];
}

#pragma mark - Cleanup helpers

- (void)invalidateSession {
    if (self.session) {
        [self.session invalidateAndCancel];
        self.session = nil;
    }
}

- (void)dismissPresentedPlayerIfNeededWithCompletion:(void (^)(void))completion {
    if (self.playerViewController.presentingViewController) {
        __weak TsPlaybackManager *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            TsPlaybackManager *strongSelf = weakSelf;
            if (!strongSelf) {
                if (completion) {
                    completion();
                }
                return;
            }

            strongSelf.isStopping = YES;
            [strongSelf.playerViewController dismissViewControllerAnimated:YES completion:^{
                if (completion) {
                    completion();
                }
            }];
        });
    } else {
        if (completion) {
            completion();
        }
    }
}

- (void)resetActivePlaybackStatePreservingBlocks:(BOOL)preserveBlocks {
    [self invalidateStartupFallbackTimer];

    if (self.downloadTask) {
        [self.downloadTask cancel];
        self.downloadTask = nil;
    }

    [self invalidateSession];

    if (self.mediaPlayer) {
        self.mediaPlayer.delegate = nil;
        self.mediaPlayer.drawable = nil;
        [self.mediaPlayer stop];
        self.mediaPlayer = nil;
    }

    if (self.playerViewController) {
        self.playerViewController.onClose = nil;
        self.playerViewController.onPlayPauseTapped = nil;
        self.playerViewController.onSeekStarted = nil;
        self.playerViewController.onSeekChanged = nil;
        self.playerViewController.onSeekEnded = nil;

        [self removeInlinePlayerViewIfNeeded];
        [self.playerViewController invalidateAutoHideTimer];
        self.playerViewController = nil;
    }

    if (self.deleteAfterPlayback && self.currentFilePath.length) {
        [[NSFileManager defaultManager] removeItemAtPath:self.currentFilePath error:nil];
    }

    self.currentFilePath = nil;
    self.currentTitle = nil;
    self.currentRemoteURLString = nil;

    self.isStopping = NO;
    self.hasStartedPlayback = NO;
    self.isUserSeeking = NO;
    self.wasPlayingBeforeSeek = NO;
    self.didFallbackToDownload = NO;
    self.useDirectRemotePlayback = NO;

    self.isInlineMode = NO;
    self.inlinePresenter = nil;
    self.inlineWebView = nil;

    if (!preserveBlocks) {
        self.statusBlock = nil;
        self.errorBlock = nil;
    }
}

#pragma mark - Callback helpers

- (void)sendStatus:(NSDictionary *)payload keepCallback:(BOOL)keepCallback {
    if (self.statusBlock) {
        self.statusBlock(payload, keepCallback);
    }
}

- (void)sendError:(NSString *)message {
    if (self.errorBlock) {
        self.errorBlock(message ?: @"Unknown error");
    }

    __weak TsPlaybackManager *weakSelf = self;
    [self dismissPresentedPlayerIfNeededWithCompletion:^{
        TsPlaybackManager *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        [strongSelf resetActivePlaybackStatePreservingBlocks:NO];
    }];
}

- (void)sendClosedIfNeeded {
    if (self.didSendClosed) {
        return;
    }

    self.didSendClosed = YES;
    [self sendStatus:@{ @"status": @"CLOSED" } keepCallback:NO];
}

- (void)removeInlinePlayerViewIfNeeded {
    TsPlayerViewController *playerVC = self.playerViewController;
    if (!playerVC) {
        return;
    }

    void (^removeBlock)(void) = ^{
        [playerVC invalidateAutoHideTimer];

        if (playerVC.parentViewController) {
            [playerVC willMoveToParentViewController:nil];
            [playerVC.view removeFromSuperview];
            [playerVC removeFromParentViewController];
        } else if (playerVC.view.superview) {
            [playerVC.view removeFromSuperview];
        }
    };

    if ([NSThread isMainThread]) {
        removeBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), removeBlock);
    }
}

@end