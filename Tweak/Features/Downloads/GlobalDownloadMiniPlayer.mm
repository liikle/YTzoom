#import "GlobalDownloadMiniPlayer.h"
#import "../../YTzoom.h"
#import "MediaArtwork.h"
#import "YTzoomAudioPlayerController.h"
#import "YTzoomDownloadPlayerController.h"
#import "../../Runtime/Preferences.h"
#import "../SponsorBlock/SponsorPreferences.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

static NSString * const YTzoomMiniSizeKey = @"YTzoom.Library.MiniPlayerSize";
static NSString * const YTzoomMiniCornerKey = @"YTzoom.Library.MiniPlayerCorner";


@interface YTzoomMiniProgressView : UIView
@property(nonatomic, assign) CGFloat progress;
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *segments;
@property(nonatomic, assign) NSTimeInterval duration;
@end

@implementation YTzoomMiniProgressView

- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    [[UIColor colorWithWhite:1.0 alpha:0.3] setFill];
    UIRectFill(self.bounds);
    CGFloat playedWidth = width * MAX(0.0, MIN(1.0, self.progress));
    if (playedWidth > 0.0) {
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextSaveGState(context);
        UIRectClip(CGRectMake(0.0, 0.0, playedWidth, height));
        [YTzoomProgressFillImage(width, height) drawInRect:CGRectMake(0.0, 0.0, width, height)];
        CGContextRestoreGState(context);
    }
    if (!isfinite(self.duration) || self.duration <= 0.0 || !YTzoomSponsorBlockEnabled()) {
        return;
    }
    for (NSDictionary<NSString *, id> *segment in self.segments) {
        NSString *category = segment[@"category"];
        if (YTzoomSponsorCategoryBehavior(category) == 2) continue;
        CGFloat start = (CGFloat)([segment[@"start"] doubleValue] / self.duration) * width;
        CGFloat end = (CGFloat)([segment[@"end"] doubleValue] / self.duration) * width;
        start = MAX(0.0, MIN(width, start));
        end = MAX(start + 1.0, MIN(width, end));
        [YTzoomSponsorCategoryColor(category) setFill];
        UIRectFill(CGRectMake(start, 0.0, end - start, height));
    }
}

@end

static UIWindow *YTzoomGlobalWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0.0) return window;
        }
    }
    return nil;
}

static UIViewController *YTzoomGlobalPresenter(void) {
    UIViewController *controller = YTzoomGlobalWindow().rootViewController;
    while (controller != nil) {
        if (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            controller = ((UINavigationController *)controller).visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return controller;
}

static BOOL YTzoomIsFullPlayer(UIViewController *controller) {
    return [controller isKindOfClass:YTzoomDownloadPlayerController.class] ||
        [controller isKindOfClass:YTzoomAudioPlayerController.class];
}

static BOOL YTzoomGlobalFullPlayerVisible(void) {
    UIViewController *controller = YTzoomGlobalWindow().rootViewController;
    while (controller != nil) {
        if (YTzoomIsFullPlayer(controller)) return YES;
        if (controller.presentedViewController != nil) {
            controller = controller.presentedViewController;
        } else if ([controller isKindOfClass:UINavigationController.class]) {
            UINavigationController *navigation = (UINavigationController *)controller;
            for (UIViewController *child in navigation.viewControllers) {
                if (YTzoomIsFullPlayer(child)) return YES;
            }
            controller = navigation.visibleViewController;
        } else if ([controller isKindOfClass:UITabBarController.class]) {
            controller = ((UITabBarController *)controller).selectedViewController;
        } else {
            break;
        }
    }
    return NO;
}

static CGFloat YTzoomGlobalTabTop(UIWindow *window) {
    __block CGFloat top = CGRectGetHeight(window.bounds) -
        window.safeAreaInsets.bottom;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden || view.alpha < 0.05) continue;
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        BOOL tab = [view isKindOfClass:UITabBar.class] ||
            [name containsString:@"pivotbar"];
        if (tab && CGRectGetHeight(view.bounds) >= 35.0) {
            CGRect frame = [view convertRect:view.bounds toView:window];
            if (CGRectGetMinY(frame) > CGRectGetHeight(window.bounds) * 0.55) {
                top = MIN(top, CGRectGetMinY(frame));
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return top;
}

static UIButton *YTzoomMiniButton(NSString *symbol, CGFloat size, id target, SEL action) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:size
                                                        weight:UIImageSymbolWeightBold];
    [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.45;
    button.layer.shadowRadius = 3.0;
    button.layer.shadowOffset = CGSizeZero;
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@interface YTzoomGlobalDownloadMiniPlayer : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIView *card;
@property(nonatomic, strong) UIView *content;
@property(nonatomic, strong) UIImageView *artworkView;
@property(nonatomic, strong) CAGradientLayer *shade;
@property(nonatomic, strong) UIButton *playButton;
@property(nonatomic, strong) UIButton *closeButton;
@property(nonatomic, strong) YTzoomMiniProgressView *progressView;
@property(nonatomic, strong) NSTimer *positionTimer;
@property(nonatomic, assign) BOOL interacting;
@property(nonatomic, assign) BOOL dismissing;
@property(nonatomic, assign) BOOL audio;
@property(nonatomic, assign) BOOL videoAttached;
@property(nonatomic, assign) BOOL fullPlayerHiding;
@property(nonatomic, assign) CGFloat baseSize;
@property(nonatomic, assign) CGFloat pinchStartSize;
@property(nonatomic, assign) NSInteger corner;
@property(nonatomic, assign) CGPoint panStartCenter;
@end

@implementation YTzoomGlobalDownloadMiniPlayer

+ (instancetype)sharedPlayer {
    static YTzoomGlobalDownloadMiniPlayer *player;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ player = [YTzoomGlobalDownloadMiniPlayer new]; });
    return player;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) return nil;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    self.baseSize = [defaults doubleForKey:YTzoomMiniSizeKey];
    self.corner = [defaults objectForKey:YTzoomMiniCornerKey] != nil
        ? MAX(0, MIN([defaults integerForKey:YTzoomMiniCornerKey], 3)) : 3;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTzoomDownloadPlaybackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTzoomDownloadPlaybackDidStopNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(playbackChanged:)
        name:YTzoomLibraryPiPDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(applicationBecameActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(fullPlayerWillShow:)
        name:YTzoomLibraryFullPlayerWillShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(fullPlayerWillHide:)
        name:YTzoomLibraryFullPlayerWillHideNotification object:nil];
    __weak YTzoomGlobalDownloadMiniPlayer *weakSelf = self;
    [YTzoomLibraryPiP sharedPiP].restoreHandler = ^(UIView *owner) {
        YTzoomGlobalDownloadMiniPlayer *strongSelf = weakSelf;
        if (strongSelf == nil) return;
        (void)owner;
        if (YTzoomLibraryVideoView().superview == strongSelf.content) {
            dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf refresh]; });
            return;
        }
        [strongSelf openPlayer];
    };
    return self;
}

- (void)buildUI {
    if (self.card != nil) return;
    self.card = [UIView new];
    self.card.layer.shadowColor = UIColor.blackColor.CGColor;
    self.card.layer.shadowOpacity = 0.35;
    self.card.layer.shadowRadius = 12.0;
    self.card.layer.shadowOffset = CGSizeMake(0.0, 4.0);

    self.content = [UIView new];
    self.content.backgroundColor = UIColor.blackColor;
    self.content.layer.cornerRadius = 12.0;
    self.content.clipsToBounds = YES;
    self.content.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.card addSubview:self.content];


    self.artworkView = [UIImageView new];
    self.artworkView.contentMode = UIViewContentModeScaleAspectFill;
    self.artworkView.clipsToBounds = YES;
    self.artworkView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [self.content addSubview:self.artworkView];

    self.shade = [CAGradientLayer layer];
    self.shade.colors = @[
        (id)[UIColor colorWithWhite:0.0 alpha:0.45].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.0].CGColor,
        (id)[UIColor colorWithWhite:0.0 alpha:0.55].CGColor
    ];
    self.shade.locations = @[@0.0, @0.35, @0.6, @1.0];
    [self.content.layer addSublayer:self.shade];

    self.playButton = YTzoomMiniButton(@"pause.fill", 15.0, self, @selector(togglePlayback));
    [self.content addSubview:self.playButton];
    self.closeButton = YTzoomMiniButton(@"xmark", 14.0, self, @selector(closePlayback));
    [self.content addSubview:self.closeButton];

    self.progressView = [YTzoomMiniProgressView new];
    self.progressView.backgroundColor = UIColor.clearColor;
    self.progressView.userInteractionEnabled = NO;
    [self.content addSubview:self.progressView];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openPlayer)];
    tap.delegate = self;
    [self.card addGestureRecognizer:tap];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [self.card addGestureRecognizer:pan];
    UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePinch:)];
    pinch.delegate = self;
    [self.card addGestureRecognizer:pinch];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return ![touch.view isKindOfClass:UIControl.class];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return [gestureRecognizer isKindOfClass:UIPinchGestureRecognizer.class] ||
        [other isKindOfClass:UIPinchGestureRecognizer.class];
}

- (CGRect)allowedAreaInWindow:(UIWindow *)window {
    UIEdgeInsets safe = window.safeAreaInsets;
    CGFloat margin = 10.0;
    CGFloat top = safe.top + margin;
    CGFloat bottom = MIN(CGRectGetHeight(window.bounds) - safe.bottom,
                         YTzoomGlobalTabTop(window)) - margin;
    CGFloat left = safe.left + margin;
    CGFloat right = CGRectGetWidth(window.bounds) - safe.right - margin;
    return CGRectMake(left, top, MAX(0.0, right - left), MAX(0.0, bottom - top));
}

- (CGFloat)aspectRatio {
    if (self.audio) return 1.0;
    CGSize size = YTzoomDownloadPlaybackSession.sharedSession.player.currentItem.presentationSize;
    CGFloat aspect = size.width > 0.0 && size.height > 0.0
        ? size.width / size.height : 16.0 / 9.0;
    return MAX(9.0 / 16.0, MIN(aspect, 16.0 / 9.0));
}

- (CGFloat)clampedSize:(CGFloat)size inArea:(CGRect)area {
    CGFloat aspect = [self aspectRatio];
    CGFloat maxWidth = CGRectGetWidth(area);
    CGFloat maxHeight = CGRectGetHeight(area) * 0.6;
    CGFloat limit = aspect >= 1.0 ? MIN(maxWidth, maxHeight * aspect)
                                  : MIN(maxHeight, maxWidth / aspect);
    CGFloat minimum = MIN(150.0, limit);
    return MAX(minimum, MIN(size, limit));
}

- (CGSize)cardSizeInArea:(CGRect)area {
    CGFloat base = self.baseSize > 0.0 ? self.baseSize :
        (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 340.0 : 220.0);
    base = [self clampedSize:base inArea:area];
    CGFloat aspect = [self aspectRatio];
    if (aspect >= 1.0) return CGSizeMake(round(base), round(base / aspect));
    return CGSizeMake(round(base * aspect), round(base));
}

- (CGRect)frameForCorner:(NSInteger)corner size:(CGSize)size area:(CGRect)area {
    CGFloat x = (corner == 0 || corner == 2) ? CGRectGetMinX(area)
                                             : CGRectGetMaxX(area) - size.width;
    CGFloat y = (corner == 0 || corner == 1) ? CGRectGetMinY(area)
                                             : CGRectGetMaxY(area) - size.height;
    return CGRectMake(x, y, size.width, size.height);
}

- (void)applyFrame:(CGRect)frame {
    self.card.bounds = CGRectMake(0.0, 0.0, frame.size.width, frame.size.height);
    self.card.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    self.content.frame = self.card.bounds;
    self.card.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.card.bounds
                                                            cornerRadius:12.0].CGPath;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.shade.frame = self.content.bounds;
    [CATransaction commit];
    CGFloat width = frame.size.width;
    CGFloat height = frame.size.height;
    self.closeButton.frame = CGRectMake(width - 38.0, 2.0, 36.0, 36.0);
    self.playButton.frame = CGRectMake(2.0, height - 40.0, 38.0, 36.0);
    self.progressView.frame = CGRectMake(0.0, height - 3.0, width, 3.0);
    [self updateProgress];
}

- (void)updateProgress {
    AVPlayer *player = YTzoomDownloadPlaybackSession.sharedSession.player;
    NSTimeInterval elapsed = CMTimeGetSeconds(player.currentTime);
    NSTimeInterval duration = CMTimeGetSeconds(player.currentItem.duration);
    CGFloat ratio = isfinite(elapsed) && isfinite(duration) && duration > 0.0
        ? (CGFloat)MAX(0.0, MIN(1.0, elapsed / duration)) : 0.0;
    self.progressView.progress = ratio;
    self.progressView.duration = duration;
    self.progressView.segments = YTzoomDownloadPlaybackSession.sharedSession.sponsorSegments;
    [self.progressView setNeedsDisplay];
}

- (BOOL)shouldHideCard {
    return (YTzoomGlobalFullPlayerVisible() && !self.fullPlayerHiding) ||
        [YTzoomLibraryPiP sharedPiP].active;
}

- (void)layoutCard {
    UIWindow *window = YTzoomGlobalWindow();
    if (window == nil || self.card.superview != window || self.dismissing) return;
    BOOL hidden = [self shouldHideCard];
    if (!YTzoomGlobalFullPlayerVisible()) self.fullPlayerHiding = NO;
    self.card.hidden = hidden;
    [self updateVideoAttachment:!hidden || self.fullPlayerHiding];
    if (hidden || self.interacting) return;
    CGRect area = [self allowedAreaInWindow:window];
    [self applyFrame:[self frameForCorner:self.corner
                                     size:[self cardSizeInArea:area] area:area]];
}

- (void)updateVideoAttachment:(BOOL)visible {
    UIView *video = YTzoomLibraryVideoView();
    if (self.audio) {
        if (video.superview == self.content) [video removeFromSuperview];
        self.videoAttached = NO;
        return;
    }
    self.videoAttached = video.superview == self.content;
    if (!visible || self.videoAttached || self.content == nil) return;
    [video removeFromSuperview];
    video.translatesAutoresizingMaskIntoConstraints = YES;
    video.frame = self.content.bounds;
    video.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    ((AVPlayerLayer *)video.layer).videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.content insertSubview:video atIndex:0];
    self.videoAttached = YES;
    [[YTzoomLibraryPiP sharedPiP] useLayer:(AVPlayerLayer *)video.layer owner:video];
}

- (CGRect)targetFrame {
    UIWindow *window = YTzoomGlobalWindow();
    NSURL *URL = YTzoomDownloadPlaybackSession.sharedSession.currentURL;
    if (window == nil || URL == nil) return CGRectNull;
    self.audio = [URL.path containsString:@"/Downloads/Audio/"];
    CGRect area = [self allowedAreaInWindow:window];
    return [self frameForCorner:self.corner size:[self cardSizeInArea:area] area:area];
}

- (void)handlePan:(UIPanGestureRecognizer *)gesture {
    UIWindow *window = self.card.window;
    if (window == nil) return;
    CGPoint translation = [gesture translationInView:window];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.interacting = YES;
        self.panStartCenter = self.card.center;
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.card.center = CGPointMake(self.panStartCenter.x + translation.x,
                                       self.panStartCenter.y + translation.y);
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    CGPoint velocity = [gesture velocityInView:window];
    CGRect area = [self allowedAreaInWindow:window];
    CGPoint projected = CGPointMake(self.card.center.x + velocity.x * 0.18,
                                    self.card.center.y + velocity.y * 0.18);
    CGFloat halfWidth = CGRectGetWidth(self.card.bounds) * 0.5;
    BOOL flungLeft = projected.x + halfWidth * 0.4 < CGRectGetMinX(area) &&
        velocity.x < -500.0;
    BOOL flungRight = projected.x - halfWidth * 0.4 > CGRectGetMaxX(area) &&
        velocity.x > 500.0;
    if (flungLeft || flungRight) {
        [self dismissTowards:flungLeft ? -1.0 : 1.0 velocity:velocity];
        return;
    }
    BOOL left = projected.x < CGRectGetMidX(area);
    BOOL top = projected.y < CGRectGetMidY(area);
    self.corner = (top ? 0 : 2) + (left ? 0 : 1);
    [NSUserDefaults.standardUserDefaults setInteger:self.corner forKey:YTzoomMiniCornerKey];
    CGRect target = [self frameForCorner:self.corner size:self.card.bounds.size area:area];
    [UIView animateWithDuration:0.45 delay:0.0 usingSpringWithDamping:0.82
          initialSpringVelocity:0.4 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.card.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    } completion:^(__unused BOOL finished) {
        self.interacting = NO;
    }];
}

- (void)handlePinch:(UIPinchGestureRecognizer *)gesture {
    UIWindow *window = self.card.window;
    if (window == nil) return;
    CGRect area = [self allowedAreaInWindow:window];
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.interacting = YES;
        CGSize size = self.card.bounds.size;
        self.pinchStartSize = MAX(size.width, size.height);
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        self.baseSize = [self clampedSize:self.pinchStartSize * gesture.scale inArea:area];
        [self applyFrame:[self frameForCorner:self.corner
                                         size:[self cardSizeInArea:area] area:area]];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled) {
        [NSUserDefaults.standardUserDefaults setDouble:self.baseSize forKey:YTzoomMiniSizeKey];
        self.interacting = NO;
        [self layoutCard];
    }
}

- (void)dismissTowards:(CGFloat)direction velocity:(CGPoint)velocity {
    self.dismissing = YES;
    CGFloat distance = CGRectGetWidth(self.card.window.bounds);
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.card.center = CGPointMake(self.card.center.x + direction * distance,
                                       self.card.center.y + velocity.y * 0.08);
        self.card.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self.card.alpha = 1.0;
        self.interacting = NO;
        self.dismissing = NO;
        [self closePlayback];
    }];
}

- (void)fullPlayerWillHide:(NSNotification *)notification {
    (void)notification;
    if (YTzoomDownloadPlaybackSession.sharedSession.currentURL == nil) return;
    self.fullPlayerHiding = YES;
    [self refresh];
}

- (void)fullPlayerWillShow:(NSNotification *)notification {
    (void)notification;
    self.fullPlayerHiding = NO;
    self.card.hidden = YES;
    [self updateVideoAttachment:NO];
}

- (void)playbackChanged:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)applicationBecameActive:(NSNotification *)notification {
    (void)notification;
    if (self.card == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}

- (void)refresh {
    [self buildUI];
    YTzoomDownloadPlaybackSession *session =
        YTzoomDownloadPlaybackSession.sharedSession;
    NSURL *URL = session.currentURL;
    if (URL == nil) {
        [self.card removeFromSuperview];
        [self.positionTimer invalidate];
        self.positionTimer = nil;
        [self updateVideoAttachment:NO];
        return;
    }
    UIWindow *window = YTzoomGlobalWindow();
    if (window == nil) return;
    if (self.card.superview != window) {
        [self.card removeFromSuperview];
        [window addSubview:self.card];
    }
    [window bringSubviewToFront:self.card];
    self.audio = [URL.path containsString:@"/Downloads/Audio/"];
    self.artworkView.hidden = !self.audio;
    self.artworkView.image = self.audio ? YTzoomMediaArtworkImage(URL) : nil;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0
                                                        weight:UIImageSymbolWeightBold];
    NSString *symbol = session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.playButton setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
                     forState:UIControlStateNormal];
    [self layoutCard];
    if (self.positionTimer == nil) {
        __weak YTzoomGlobalDownloadMiniPlayer *weakSelf = self;
        self.positionTimer = [NSTimer scheduledTimerWithTimeInterval:0.35
            repeats:YES block:^(__unused NSTimer *timer) {
                YTzoomGlobalDownloadMiniPlayer *strongSelf = weakSelf;
                [strongSelf layoutCard];
                [strongSelf updateProgress];
                UIWindow *activeWindow = YTzoomGlobalWindow();
                if (strongSelf.card.superview != activeWindow) [strongSelf refresh];
                [activeWindow bringSubviewToFront:strongSelf.card];
            }];
    }
}

- (void)togglePlayback {
    [YTzoomDownloadPlaybackSession.sharedSession togglePlayback];
}

- (void)closePlayback {
    [[YTzoomLibraryPiP sharedPiP] stop];
    [YTzoomDownloadPlaybackSession.sharedSession stop];
}

- (void)openPlayer {
    YTzoomDownloadPlaybackSession *session =
        YTzoomDownloadPlaybackSession.sharedSession;
    if (session.currentURL == nil) return;
    UIViewController *presenter = YTzoomGlobalPresenter();
    if (presenter == nil || YTzoomGlobalFullPlayerVisible()) {
        return;
    }
    BOOL audio = [session.currentURL.path containsString:@"/Downloads/Audio/"];
    UIViewController *player = audio
        ? [[YTzoomAudioPlayerController alloc] initWithSession:session]
        : [[YTzoomDownloadPlayerController alloc] initWithSession:session];
    __weak YTzoomGlobalDownloadMiniPlayer *weakSelf = self;
    dispatch_block_t minimized = ^{ [weakSelf refresh]; };
    if (audio) {
        ((YTzoomAudioPlayerController *)player).minimizeHandler = minimized;
    } else {
        ((YTzoomDownloadPlayerController *)player).minimizeHandler = minimized;
    }
    if (!audio && self.card.superview != nil && !self.card.hidden) {
        ((YTzoomDownloadPlayerController *)player).sourceFrame =
            [self.card convertRect:self.card.bounds toView:nil];
    }
    self.card.hidden = YES;
    [self updateVideoAttachment:NO];
    [presenter presentViewController:player animated:YES completion:nil];
}

@end

void YTzoomInstallGlobalDownloadMiniPlayer(void) {
    [YTzoomGlobalDownloadMiniPlayer sharedPlayer];
}

CGRect YTzoomMiniPlayerTargetFrame(void) {
    return [[YTzoomGlobalDownloadMiniPlayer sharedPlayer] targetFrame];
}
