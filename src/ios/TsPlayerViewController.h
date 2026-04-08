#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TsPlayerViewController : UIViewController

@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onPlayPauseTapped)(void);
@property (nonatomic, copy, nullable) void (^onSeekStarted)(void);
@property (nonatomic, copy, nullable) void (^onSeekChanged)(float position);
@property (nonatomic, copy, nullable) void (^onSeekEnded)(float position);

- (UIView *)videoContainerView;
- (void)setLoadingVisible:(BOOL)visible;
- (void)setPlaying:(BOOL)isPlaying;
- (void)updatePlaybackTime:(NSString *)currentTime duration:(NSString *)duration;
- (void)updateSeekPosition:(float)position;
- (void)setControlsHidden:(BOOL)hidden animated:(BOOL)animated;
- (void)restartAutoHideTimer;
- (void)invalidateAutoHideTimer;

@end

NS_ASSUME_NONNULL_END