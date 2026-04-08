#import "TsPlayerViewController.h"

@interface TsPlayerViewController ()

@property (nonatomic, strong) UIView *videoContainer;
@property (nonatomic, strong) UIButton *tapOverlayButton;

@property (nonatomic, strong) UIView *topBar;
@property (nonatomic, strong) UIView *bottomBar;

@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *playPauseButton;

@property (nonatomic, strong) UISlider *seekSlider;
@property (nonatomic, strong) UILabel *currentTimeLabel;
@property (nonatomic, strong) UILabel *durationLabel;

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;

@property (nonatomic, assign) BOOL controlsHidden;
@property (nonatomic, assign) BOOL isDraggingSlider;
@property (nonatomic, strong, nullable) NSTimer *autoHideTimer;

@end

@implementation TsPlayerViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor blackColor];
    self.controlsHidden = NO;
    self.isDraggingSlider = NO;

    self.videoContainer = [[UIView alloc] initWithFrame:self.view.bounds];
    self.videoContainer.backgroundColor = [UIColor blackColor];
    self.videoContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.videoContainer];

    self.tapOverlayButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.tapOverlayButton.frame = self.view.bounds;
    self.tapOverlayButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tapOverlayButton.backgroundColor = [UIColor clearColor];
    [self.tapOverlayButton addTarget:self
                              action:@selector(handleOverlayTap)
                    forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.tapOverlayButton];

    self.topBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.topBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    [self.view addSubview:self.topBar];

    self.bottomBar = [[UIView alloc] initWithFrame:CGRectZero];
    self.bottomBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    [self.view addSubview:self.bottomBar];

    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"Close" forState:UIControlStateNormal];
    [self.closeButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    [self.closeButton addTarget:self
                         action:@selector(handleCloseTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.topBar addSubview:self.closeButton];


    self.topBar.hidden = YES;
    self.closeButton.hidden = YES;

    self.playPauseButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.playPauseButton setTitle:@"Pause" forState:UIControlStateNormal];
    [self.playPauseButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.playPauseButton.titleLabel.font = [UIFont boldSystemFontOfSize:16.0];
    [self.playPauseButton addTarget:self
                             action:@selector(handlePlayPauseTapped)
                   forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBar addSubview:self.playPauseButton];

    self.currentTimeLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.currentTimeLabel.textColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        self.currentTimeLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    } else {
        self.currentTimeLabel.font = [UIFont systemFontOfSize:12.0];
    }
    self.currentTimeLabel.textAlignment = NSTextAlignmentCenter;
    self.currentTimeLabel.text = @"00:00";
    [self.bottomBar addSubview:self.currentTimeLabel];

    self.durationLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.durationLabel.textColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        self.durationLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
    } else {
        self.durationLabel.font = [UIFont systemFontOfSize:12.0];
    }
    self.durationLabel.textAlignment = NSTextAlignmentCenter;
    self.durationLabel.text = @"00:00";
    [self.bottomBar addSubview:self.durationLabel];

    self.seekSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    self.seekSlider.minimumValue = 0.0f;
    self.seekSlider.maximumValue = 1.0f;
    self.seekSlider.value = 0.0f;
    [self.seekSlider addTarget:self
                        action:@selector(handleSeekTouchDown:)
              forControlEvents:UIControlEventTouchDown];
    [self.seekSlider addTarget:self
                        action:@selector(handleSeekValueChanged:)
              forControlEvents:UIControlEventValueChanged];
    [self.seekSlider addTarget:self
                        action:@selector(handleSeekTouchUp:)
              forControlEvents:UIControlEventTouchUpInside];
    [self.seekSlider addTarget:self
                        action:@selector(handleSeekTouchUp:)
              forControlEvents:UIControlEventTouchUpOutside];
    [self.seekSlider addTarget:self
                        action:@selector(handleSeekTouchUp:)
              forControlEvents:UIControlEventTouchCancel];
    [self.bottomBar addSubview:self.seekSlider];

    if (@available(iOS 13.0, *)) {
        self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    } else {
        self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    }
    self.activityIndicator.color = [UIColor whiteColor];
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    [self layoutPlayerUI];
    [self setControlsHidden:NO animated:NO];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPlayerUI];
}

- (void)layoutPlayerUI {
    CGRect bounds = self.view.bounds;
    CGFloat safeTop = 0.0;
    CGFloat safeBottom = 0.0;

    if (@available(iOS 11.0, *)) {
        safeTop = self.view.safeAreaInsets.top;
        safeBottom = self.view.safeAreaInsets.bottom;
    }

    self.videoContainer.frame = bounds;
    self.tapOverlayButton.frame = bounds;

    self.topBar.frame = CGRectMake(0.0, 0.0, bounds.size.width, safeTop + 56.0);
    self.closeButton.frame = CGRectMake(16.0, safeTop + 8.0, 70.0, 36.0);

    CGFloat bottomHeight = 72.0 + safeBottom;
    self.bottomBar.frame = CGRectMake(0.0,
                                      bounds.size.height - bottomHeight,
                                      bounds.size.width,
                                      bottomHeight);

    self.playPauseButton.frame = CGRectMake(12.0, 10.0, 70.0, 34.0);
    self.currentTimeLabel.frame = CGRectMake(86.0, 12.0, 52.0, 20.0);
    self.durationLabel.frame = CGRectMake(bounds.size.width - 64.0, 12.0, 52.0, 20.0);
    self.seekSlider.frame = CGRectMake(138.0, 8.0, bounds.size.width - 138.0 - 68.0, 30.0);

    self.activityIndicator.center = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}

- (UIView *)videoContainerView {
    return self.videoContainer;
}

- (void)handleOverlayTap {
    BOOL shouldHide = !self.controlsHidden;
    [self setControlsHidden:shouldHide animated:YES];

    if (!shouldHide) {
        [self restartAutoHideTimer];
    } else {
        [self invalidateAutoHideTimer];
    }
}

- (void)handleCloseTapped {
    [self invalidateAutoHideTimer];
    if (self.onClose) {
        self.onClose();
    }
}

- (void)handlePlayPauseTapped {
    if (self.onPlayPauseTapped) {
        self.onPlayPauseTapped();
    }
    [self restartAutoHideTimer];
}

- (void)handleSeekTouchDown:(UISlider *)slider {
    self.isDraggingSlider = YES;
    [self invalidateAutoHideTimer];

    if (self.onSeekStarted) {
        self.onSeekStarted();
    }
}

- (void)handleSeekValueChanged:(UISlider *)slider {
    if (self.onSeekChanged) {
        self.onSeekChanged(slider.value);
    }
}

- (void)handleSeekTouchUp:(UISlider *)slider {
    self.isDraggingSlider = NO;

    if (self.onSeekEnded) {
        self.onSeekEnded(slider.value);
    }

    [self restartAutoHideTimer];
}

- (void)setLoadingVisible:(BOOL)visible {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (visible) {
            [self.activityIndicator startAnimating];
        } else {
            [self.activityIndicator stopAnimating];
        }
    });
}

- (void)setPlaying:(BOOL)isPlaying {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *title = isPlaying ? @"Pause" : @"Play";
        [self.playPauseButton setTitle:title forState:UIControlStateNormal];
    });
}

- (void)updatePlaybackTime:(NSString *)currentTime duration:(NSString *)duration {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.currentTimeLabel.text = currentTime ?: @"00:00";
        self.durationLabel.text = duration ?: @"00:00";
    });
}

- (void)updateSeekPosition:(float)position {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isDraggingSlider) {
            self.seekSlider.value = position;
        }
    });
}

- (void)setControlsHidden:(BOOL)hidden animated:(BOOL)animated {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.controlsHidden = hidden;

        CGFloat alpha = hidden ? 0.0 : 1.0;

        void (^changes)(void) = ^{
            self.topBar.alpha = alpha;
            self.bottomBar.alpha = alpha;
        };

        if (animated) {
            [UIView animateWithDuration:0.25 animations:changes];
        } else {
            changes();
        }

        self.tapOverlayButton.hidden = NO;
        self.tapOverlayButton.userInteractionEnabled = YES;
    });
}

- (void)restartAutoHideTimer {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self invalidateAutoHideTimer];
        self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:3.0
                                                              target:self
                                                            selector:@selector(handleAutoHideTimer)
                                                            userInfo:nil
                                                             repeats:NO];
    });
}

- (void)invalidateAutoHideTimer {
    [self.autoHideTimer invalidate];
    self.autoHideTimer = nil;
}

- (void)handleAutoHideTimer {
    [self setControlsHidden:YES animated:YES];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)dealloc {
    [self invalidateAutoHideTimer];
}

@end