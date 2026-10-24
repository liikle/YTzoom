#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

static IMP OriginalSetLoopMode;
static IMP OriginalAutonavInit;

static BOOL YTzoomLoopActive(void) {
    return YTzoomFeatureEnabled(YTzoomLoopKey) &&
        [NSUserDefaults.standardUserDefaults boolForKey:@"defaultLoop_enabled"];
}

@interface YTzoomLoopCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
@property(nonatomic, weak) AVPlayer *player;
- (void)toggleLoop;
- (void)updateButton;
@end

@implementation YTzoomLoopCoordinator

+ (instancetype)sharedCoordinator {
    static YTzoomLoopCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTzoomLoopCoordinator new];
        [NSNotificationCenter.defaultCenter
            addObserver:coordinator
               selector:@selector(playerFinished:)
                   name:AVPlayerItemDidPlayToEndTimeNotification
                 object:nil];
    });
    return coordinator;
}

- (void)updateButton {
    self.button.tintColor = YTzoomLoopActive()
        ? UIColor.systemRedColor
        : UIColor.whiteColor;
}

- (AVPlayer *)playerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player != nil) {
            return player;
        }
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = [self playerInLayer:child];
        if (player != nil) {
            return player;
        }
    }
    return nil;
}

- (AVPlayer *)activePlayer {
    UIView *root = self.overlay;
    while (root.superview != nil) {
        root = root.superview;
    }
    return [self playerInLayer:root.layer];
}

- (id)autonavController {
    SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
    id delegate = [self.overlay respondsToSelector:eventsSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(self.overlay, eventsSelector)
        : nil;
    SEL parentSelector = NSSelectorFromString(@"parentViewController");
    id parent = [delegate respondsToSelector:parentSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(delegate, parentSelector)
        : nil;
    SEL overlaySelector = NSSelectorFromString(@"activeVideoPlayerOverlay");
    id playerOverlay = [parent respondsToSelector:overlaySelector]
        ? ((id (*)(id, SEL))objc_msgSend)(parent, overlaySelector)
        : nil;
    @try {
        return [playerOverlay valueForKey:@"_autonavController"];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

- (void)playerFinished:(NSNotification *)notification {
    if (!YTzoomLoopActive() || notification.object != self.player.currentItem) {
        return;
    }
    [self.player seekToTime:kCMTimeZero
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(__unused BOOL finished) {
              [self.player play];
          }];
}

- (void)toggleLoop {
    BOOL enabled = ![NSUserDefaults.standardUserDefaults
        boolForKey:@"defaultLoop_enabled"];
    [NSUserDefaults.standardUserDefaults setBool:enabled
                                          forKey:@"defaultLoop_enabled"];
    id controller = [self autonavController];
    SEL loopSelector = NSSelectorFromString(@"setLoopMode:");
    if ([controller respondsToSelector:loopSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(
            controller, loopSelector, enabled ? 2 : 0
        );
    }
    self.player = [self activePlayer];
    self.player.actionAtItemEnd = enabled
        ? AVPlayerActionAtItemEndNone
        : AVPlayerActionAtItemEndPause;
    [self updateButton];
}

@end

static void YTzoomSetLoopMode(id receiver, SEL selector, NSInteger mode) {
    NSInteger effective = YTzoomLoopActive() ? 2 : mode;
    if (OriginalSetLoopMode != NULL) {
        ((void (*)(id, SEL, NSInteger))OriginalSetLoopMode)(
            receiver, selector, effective
        );
    }
}

static id YTzoomAutonavInit(id receiver, SEL selector, id parentResponder) {
    id result = OriginalAutonavInit == NULL
        ? receiver
        : ((id (*)(id, SEL, id))OriginalAutonavInit)(
            receiver, selector, parentResponder
        );
    if (YTzoomLoopActive()) {
        SEL loopSelector = NSSelectorFromString(@"setLoopMode:");
        if ([result respondsToSelector:loopSelector]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(
                result, loopSelector, 2
            );
        }
    }
    return result;
}

void YTzoomInstallLoopHooks(void) {
    YTzoomInstallInstanceHook(@"YTAutoplayAutonavController",
                              @"setLoopMode:",
                              (IMP)YTzoomSetLoopMode,
                              &OriginalSetLoopMode);
    YTzoomInstallInstanceHook(@"YTAutoplayAutonavController",
                              @"initWithParentResponder:",
                              (IMP)YTzoomAutonavInit,
                              &OriginalAutonavInit);

    YTzoomRegisterOverlayConfigurator(@"loop", ^(UIView *overlay, UIStackView *stack) {
        YTzoomLoopCoordinator *coordinator = YTzoomLoopCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;
        UIButton *button = YTzoomOverlayButton(
            stack,
            @"YTzoom Loop",
            @"repeat",
            coordinator,
            @selector(toggleLoop)
        );
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                            weight:UIImageSymbolWeightMedium];
        [button setImage:[[YTzoomAssetImage(@"repeat_24pt_3x_Normal", @"repeat")
            imageByApplyingSymbolConfiguration:configuration]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                  forState:UIControlStateNormal];
        coordinator.button = button;
        button.hidden = !YTzoomFeatureEnabled(YTzoomLoopKey);
        [coordinator updateButton];
    });
}
