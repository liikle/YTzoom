#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/message.h>

static double YTzoomPlayerDouble(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![receiver respondsToSelector:selector]) return 0.0;
    double value = ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
    return isfinite(value) ? value : 0.0;
}

static NSString *YTzoomPadUnit(void) {
    unichar space = 0x2007;
    return [NSString stringWithCharacters:&space length:1];
}

static NSString *YTzoomPaddedTitle(NSString *title) {
    NSMutableString *padded = [title mutableCopy];
    for (NSUInteger index = 0; index < 6; index++) {
        [padded appendString:YTzoomPadUnit()];
    }
    return padded;
}

static NSString *YTzoomSelectedRowTitle;
static const NSInteger YTzoomCheckmarkTag = 0x5943484B;

static void YTzoomShowSleepTimerEndedAlert(void) {
    Class alertClass = NSClassFromString(@"YTAlertView");
    if (alertClass == Nil) return;
    id alert = [[alertClass alloc] init];
    SEL show = NSSelectorFromString(@"show");
    SEL setTitle = NSSelectorFromString(@"setTitle:");
    SEL setMessage = NSSelectorFromString(@"setMessage:");
    SEL addTitle = NSSelectorFromString(
        @"addTitle:iconImage:withStyle:automationIdentifier:action:");
    if (![alert respondsToSelector:show] ||
        ![alert respondsToSelector:setMessage]) {
        return;
    }
    if ([alert respondsToSelector:setTitle]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            alert, setTitle, YTzoomLocalized(@"Sleep timer"));
    }
    ((void (*)(id, SEL, id))objc_msgSend)(
        alert, setMessage,
        YTzoomLocalized(@"Sleep timer ended. Playback has been paused."));
    if ([alert respondsToSelector:addTitle]) {
        ((void (*)(id, SEL, id, id, int, id, dispatch_block_t))objc_msgSend)(
            alert, addTitle, YTzoomLocalized(@"OK"), nil, 0, nil, ^{});
    }
    ((void (*)(id, SEL))objc_msgSend)(alert, show);
}

static NSString *YTzoomClockText(double seconds) {
    NSInteger total = (NSInteger)round(seconds);
    if (total < 0) total = 0;
    if (total >= 3600) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
            (long)(total / 3600), (long)((total % 3600) / 60), (long)(total % 60)];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)(total / 60), (long)(total % 60)];
}

@interface YTzoomSleepTimerCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, weak) id playerController;
@property(nonatomic, weak) id statusBarController;
@property(nonatomic, assign) BOOL stopAtEndOfVideo;
@property(nonatomic, assign) NSTimeInterval remaining;
@property(nonatomic, strong) NSTimer *tick;
- (BOOL)isActive;
- (NSString *)statusText;
- (void)refreshStatusBar;
- (void)presentSleepTimer;
- (void)updateButton;
@end

@implementation YTzoomSleepTimerCoordinator

+ (instancetype)sharedCoordinator {
    static YTzoomSleepTimerCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTzoomSleepTimerCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(playbackTimeChanged:)
                   name:@"YTzoomPlaybackTimeDidChange"
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(videoDidEnd:)
                   name:AVPlayerItemDidPlayToEndTimeNotification
                 object:nil];
    }
    return self;
}

- (BOOL)isActive {
    return self.remaining > 0.0 || self.stopAtEndOfVideo;
}

- (double)videoTimeRemaining {
    id controller = self.playerController;
    double total = YTzoomPlayerDouble(controller, @"currentVideoTotalMediaTime");
    double current = YTzoomPlayerDouble(controller, @"currentVideoMediaTime");
    return total > 0.0 ? total - current : 0.0;
}

- (NSString *)statusText {
    if (self.stopAtEndOfVideo) {
        double left = [self videoTimeRemaining];
        return left > 0.0
            ? YTzoomClockText(left)
            : YTzoomLocalized(@"End of video");
    }
    if (self.remaining <= 0.0) return nil;
    return YTzoomClockText(self.remaining);
}

- (void)refreshStatusBar {
    id controller = self.statusBarController;
    if (controller == nil) return;
    SEL update = NSSelectorFromString(@"updateWithSleepTimerActiveStatus:");
    if ([controller respondsToSelector:update]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(controller, update, [self isActive]);
    }
    SEL latest = NSSelectorFromString(@"updateSleepTimerSlimStatusBarLatestText");
    if ([controller respondsToSelector:latest]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, latest);
    }
}

- (void)playbackTimeChanged:(NSNotification *)notification {
    self.playerController = notification.object;
    if (!self.stopAtEndOfVideo) return;
    if ([self videoTimeRemaining] <= 0.75) {
        [self finish];
        return;
    }
    [self refreshStatusBar];
}

- (void)tickFired {
    if (self.remaining <= 0.0) return;
    self.remaining -= 1.0;
    if (self.remaining <= 0.0) {
        [self finish];
        return;
    }
    [self refreshStatusBar];
}

- (void)updateButton {
    self.button.tintColor = [self isActive]
        ? YTzoomAccentColor()
        : UIColor.whiteColor;
}

- (AVPlayer *)playerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player != nil) return player;
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = [self playerInLayer:child];
        if (player != nil) return player;
    }
    return nil;
}

- (void)pausePlayback {
    id controller = self.playerController;
    SEL pause = NSSelectorFromString(@"pause");
    if ([controller respondsToSelector:pause]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, pause);
        return;
    }
    UIView *root = self.overlay;
    while (root.superview != nil) root = root.superview;
    [[self playerInLayer:root.layer] pause];
}

- (void)finish {
    [self pausePlayback];
    [self cancelTimer];
    YTzoomShowSleepTimerEndedAlert();
}

- (void)cancelTimer {
    self.remaining = 0.0;
    [self.tick invalidate];
    self.tick = nil;
    self.stopAtEndOfVideo = NO;
    [self updateButton];
    [self refreshStatusBar];
}

- (void)videoDidEnd:(NSNotification *)notification {
    (void)notification;
    if (!self.stopAtEndOfVideo) return;
    [self finish];
}

- (void)startForSeconds:(NSTimeInterval)seconds {
    [self cancelTimer];
    self.remaining = seconds;
    self.tick = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                 target:self
                                               selector:@selector(tickFired)
                                               userInfo:nil
                                                repeats:YES];
    [self updateButton];
    [self refreshStatusBar];
}

- (void)startForEndOfVideo {
    [self cancelTimer];
    self.stopAtEndOfVideo = YES;
    [self updateButton];
    [self refreshStatusBar];
}

- (NSArray<NSDictionary *> *)optionEntries {
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
    __weak YTzoomSleepTimerCoordinator *weakSelf = self;
    YTzoomSelectedRowTitle = nil;
    NSInteger activeMinutes = self.stopAtEndOfVideo
        ? -1 : (NSInteger)ceil(self.remaining / 60.0);
    NSMutableDictionary *off = [@{
        @"title": YTzoomPaddedTitle(YTzoomLocalized(@"Off")),
        @"selected": @(![self isActive]),
        @"handler": [^{ [weakSelf cancelTimer]; } copy]
    } mutableCopy];
    [entries addObject:off];
    for (NSNumber *value in @[@10, @15, @20, @30, @45, @60]) {
        NSInteger count = value.integerValue;
        NSString *title = count == 60
            ? YTzoomLocalized(@"1 hour")
            : [NSString stringWithFormat:@"%ld %@", (long)count,
               YTzoomLocalized(@"minutes")];
        NSMutableDictionary *entry = [@{
            @"title": YTzoomPaddedTitle(title),
            @"selected": @(activeMinutes == count),
            @"handler": [^{ [weakSelf startForSeconds:count * 60.0]; } copy]
        } mutableCopy];
        [entries addObject:entry];
    }
    NSMutableDictionary *endOfVideo = [@{
        @"title": YTzoomPaddedTitle(YTzoomLocalized(@"End of video")),
        @"selected": @(self.stopAtEndOfVideo),
        @"handler": [^{ [weakSelf startForEndOfVideo]; } copy]
    } mutableCopy];
    double left = [self videoTimeRemaining];
    if (left > 0.0) endOfVideo[@"subtitle"] = YTzoomClockText(left);
    [entries addObject:endOfVideo];
    for (NSDictionary *entry in entries) {
        if ([entry[@"selected"] boolValue]) {
            YTzoomSelectedRowTitle = entry[@"title"];
            break;
        }
    }
    return entries;
}

- (void)presentSleepTimer {
    YTzoomPresentNativeSheet(YTzoomLocalized(@"Sleep Timer"), nil,
                             self.button, [self optionEntries]);
}

@end

static IMP OriginalShouldShowSleepStatus;
static IMP OriginalSleepStatusText;
static IMP OriginalSubtitledLayout;

static void YTzoomSubtitledRowLayout(UIView *receiver, SEL selector) {
    if (OriginalSubtitledLayout != NULL) {
        ((void (*)(id, SEL))OriginalSubtitledLayout)(receiver, selector);
    }
    UILabel *title = nil;
    UIImageView *check = nil;
    for (UIView *subview in receiver.subviews) {
        if (subview.tag == YTzoomCheckmarkTag &&
            [subview isKindOfClass:UIImageView.class]) {
            check = (UIImageView *)subview;
        } else if ([subview isKindOfClass:UILabel.class] &&
                   [((UILabel *)subview).text containsString:YTzoomPadUnit()]) {
            title = (UILabel *)subview;
        }
    }
    if (title == nil) return;
    BOOL selected = YTzoomSelectedRowTitle.length != 0 &&
        [title.text isEqualToString:YTzoomSelectedRowTitle];
    if (check == nil) {
        if (!selected) return;
        UIImage *glyph = YTzoomYouTubeImage(@[@"yt_outline_check_24pt"],
                                            @"checkmark");
        check = [[UIImageView alloc] initWithImage:
            [glyph imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
        check.tag = YTzoomCheckmarkTag;
        check.contentMode = UIViewContentModeScaleAspectFit;
        [receiver addSubview:check];
    }
    check.hidden = !selected;
    check.tintColor = title.textColor;
    CGFloat side = 24.0;
    check.frame = CGRectMake(CGRectGetWidth(receiver.bounds) - 16.0 - side,
                             (CGRectGetHeight(receiver.bounds) - side) / 2.0,
                             side, side);
}

static BOOL YTzoomShouldShowSleepStatus(id receiver, SEL selector) {
    YTzoomSleepTimerCoordinator *coordinator =
        YTzoomSleepTimerCoordinator.sharedCoordinator;
    coordinator.statusBarController = receiver;
    if ([coordinator isActive]) return YES;
    return OriginalShouldShowSleepStatus == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalShouldShowSleepStatus)(receiver, selector);
}

static id YTzoomSleepStatusText(id receiver, SEL selector) {
    NSString *text = [YTzoomSleepTimerCoordinator.sharedCoordinator statusText];
    if (text.length != 0) return text;
    return OriginalSleepStatusText == NULL
        ? nil
        : ((id (*)(id, SEL))OriginalSleepStatusText)(receiver, selector);
}

void YTzoomInstallSleepTimerHooks(void) {
    YTzoomInstallInstanceHook(@"YTSlimStatusBarControllerImpl",
                              @"shouldShowSleepTimerActiveStatus",
                              (IMP)YTzoomShouldShowSleepStatus,
                              &OriginalShouldShowSleepStatus);
    YTzoomInstallInstanceHook(@"YTWatchSleepTimerController",
                              @"sleepTimerStatusText",
                              (IMP)YTzoomSleepStatusText,
                              &OriginalSleepStatusText);
    YTzoomInstallInstanceHook(@"YTSubtitledDialogActionButton",
                              @"layoutSubviews",
                              (IMP)YTzoomSubtitledRowLayout,
                              &OriginalSubtitledLayout);
    YTzoomRegisterOverlayConfigurator(@"sleeptimer",
        ^(UIView *overlay, UIStackView *stack) {
        YTzoomSleepTimerCoordinator *coordinator =
            YTzoomSleepTimerCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;
        UIButton *button = YTzoomOverlayButton(
            stack,
            @"YTzoom Sleep Timer",
            @"moon.zzz",
            coordinator,
            @selector(presentSleepTimer)
        );
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        UIImage *glyph = YTzoomYouTubeImage(@[
            @"yt_outline_experimental_sleep_timer_vd_theme_24",
            @"yt_outline_experimental_sleep_timer_black_24",
            @"yt_outline_sleep_timer_24pt",
            @"yt_outline_moon_24pt"
        ], @"moon.zzz");
        [button setImage:[[glyph imageByApplyingSymbolConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                forState:UIControlStateNormal];
        coordinator.button = button;
        button.hidden = !YTzoomFeatureEnabled(YTzoomSleepTimerKey);
        [coordinator updateButton];
    });
}
