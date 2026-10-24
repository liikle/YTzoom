#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTzoomOpenPausedKey =
    @"YTzoom.Preference.Playback.OpenPaused";
static NSString *const YTzoomAutoplayOffKey =
    @"YTzoom.Preference.Playback.AutoplayDisabled";

static IMP OriginalPlayAutoplay;
static IMP OriginalTriggerPendingAutoplay;
static IMP OriginalAdvanceToNext;
static IMP OriginalShouldAutonav;
static IMP OriginalSetWatchTransitionStartup;
static IMP OriginalInsertOrUpdateSingle;
static IMP OriginalSetSingleWatchTransition;


static NSString *YTzoomLastPausedVideo;

static NSTimeInterval YTzoomLastTouchTime;
static NSTimeInterval YTzoomUserNextTime;
static NSString *YTzoomUserNextOrigin;
static IMP OriginalSendEvent;


static int YTzoomTransitionInt(id transition, NSString *name);

static void YTzoomPauseNow(id player) {
    if (player == nil) return;
    SEL pause = NSSelectorFromString(@"pause");
    if (![player respondsToSelector:pause]) return;
    ((void (*)(id, SEL))objc_msgSend)(player, pause);
}

void YTzoomOpenPausedVideoActivated(id player) {
    YTzoomApplyPreferredCaptionLanguage(player);
    if (!YTzoomFeatureEnabled(YTzoomOpenPausedKey)) return;
    NSString *videoID = nil;
    SEL getter = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:getter]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, getter);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    if (videoID.length != 0 &&
        [videoID isEqualToString:YTzoomLastPausedVideo]) {
        return;
    }
    YTzoomLastPausedVideo = [videoID copy];

    __weak id weakPlayer = player;
    YTzoomPauseNow(player);
    const double delays[] = { 0.0, 0.15, 0.4, 0.8, 1.4 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTzoomPauseNow(weakPlayer);
        });
    }
}

static BOOL YTzoomAutoplaySuppressed(void) {
    return YTzoomFeatureEnabled(YTzoomAutoplayOffKey);
}

static void YTzoomPlayAutoplay(id receiver, SEL selector) {
    if (YTzoomAutoplaySuppressed()) return;
    if (OriginalPlayAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalPlayAutoplay)(receiver, selector);
    }
}

static void YTzoomTriggerPendingAutoplay(id receiver, SEL selector) {
    if (YTzoomAutoplaySuppressed()) return;
    if (OriginalTriggerPendingAutoplay != NULL) {
        ((void (*)(id, SEL))OriginalTriggerPendingAutoplay)(receiver, selector);
    }
}

static void YTzoomAdvanceToNext(id receiver, SEL selector, BOOL autoplay,
                                BOOL internalTransition, id unplayableVideoID) {
    if (YTzoomAutoplaySuppressed() && autoplay) return;
    if (OriginalAdvanceToNext != NULL) {
        ((void (*)(id, SEL, BOOL, BOOL, id))OriginalAdvanceToNext)(
            receiver, selector, autoplay, internalTransition, unplayableVideoID);
    }
}








static BOOL YTzoomShouldAutonav(id receiver, SEL selector) {
    if (YTzoomAutoplaySuppressed()) return NO;
    return OriginalShouldAutonav != NULL
        ? ((BOOL (*)(id, SEL))OriginalShouldAutonav)(receiver, selector) : NO;
}


static int YTzoomTransitionInt(id transition, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![transition respondsToSelector:selector]) return -999;
    return ((int (*)(id, SEL))objc_msgSend)(transition, selector);
}





static void YTzoomSendEvent(id receiver, SEL selector, UIEvent *event) {
    if (event.type == UIEventTypeTouches) {
        YTzoomLastTouchTime = CACurrentMediaTime();
    }
    if (OriginalSendEvent != NULL) {
        ((void (*)(id, SEL, id))OriginalSendEvent)(receiver, selector, event);
    }
}

static const int YTzoomAutoAdvanceSource = 6;
static const NSTimeInterval YTzoomUserNextWindow = 2.0;
static const NSTimeInterval YTzoomTouchGraceWindow = 0.6;

static void YTzoomNoteUserNextRequiringTouch(NSString *origin,
                                            BOOL requiresTouch) {
    const NSTimeInterval now = CACurrentMediaTime();
    if (requiresTouch &&
        (YTzoomLastTouchTime == 0 || now - YTzoomLastTouchTime > 1.5)) {
        return;
    }
    YTzoomUserNextTime = now;
    YTzoomUserNextOrigin = origin;
}

static void YTzoomNoteUserNext(NSString *origin) {
    YTzoomNoteUserNextRequiringTouch(origin, NO);
}

static BOOL YTzoomShouldDropTransition(id transition) {
    if (transition == nil) return NO;
    const int source = YTzoomTransitionInt(transition, @"watchEndpointSource");
    const NSTimeInterval now = CACurrentMediaTime();
    const NSTimeInterval sinceTouch =
        YTzoomLastTouchTime != 0 ? now - YTzoomLastTouchTime : -1;
    const NSTimeInterval sinceUserNext =
        YTzoomUserNextTime != 0 ? now - YTzoomUserNextTime : -1;

    const BOOL userAsked =
        (sinceUserNext >= 0 && sinceUserNext <= YTzoomUserNextWindow) ||
        (sinceTouch >= 0 && sinceTouch <= YTzoomTouchGraceWindow);
    return YTzoomAutoplaySuppressed() &&
        source == YTzoomAutoAdvanceSource && !userAsked;
}

static void YTzoomSetWatchTransitionStartup(id receiver, SEL selector,
                                            id transition, BOOL onAppStartup) {
    if (!onAppStartup &&
        YTzoomShouldDropTransition(transition)) {
        return;
    }
    if (OriginalSetWatchTransitionStartup != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalSetWatchTransitionStartup)(
            receiver, selector, transition, onAppStartup);
    }
}

static void YTzoomInsertOrUpdateSingle(id receiver, SEL selector,
                                       id transition) {
    if (YTzoomShouldDropTransition(transition)) return;
    if (OriginalInsertOrUpdateSingle != NULL) {
        ((void (*)(id, SEL, id))OriginalInsertOrUpdateSingle)(
            receiver, selector, transition);
    }
}

static void YTzoomSetSingleWatchTransition(id receiver, SEL selector,
                                           id transition) {
    if (YTzoomShouldDropTransition(transition)) return;
    if (OriginalSetSingleWatchTransition != NULL) {
        ((void (*)(id, SEL, id))OriginalSetSingleWatchTransition)(
            receiver, selector, transition);
    }
}

static IMP OriginalUserNext[8];

static long long YTzoomUserNextRemote(id receiver, SEL selector, id command) {
    YTzoomNoteUserNext(@"remoteNextTrack");
    return OriginalUserNext[7] != NULL
        ? ((long long (*)(id, SEL, id))OriginalUserNext[7])(receiver, selector,
                                                            command)
        : 0;
}

static void YTzoomUserNextSender0(id receiver, SEL selector, id sender) {
    YTzoomNoteUserNext(@"overlayNext");
    if (OriginalUserNext[0] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[0])(receiver, selector, sender);
    }
}

static void YTzoomUserNextSender1(id receiver, SEL selector, id sender) {
    YTzoomNoteUserNext(@"controlsNext");
    if (OriginalUserNext[1] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[1])(receiver, selector, sender);
    }
}

static void YTzoomUserNextVoid5(id receiver, SEL selector) {
    YTzoomNoteUserNext(@"playerBarNext");
    if (OriginalUserNext[5] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[5])(receiver, selector);
    }
}

static void YTzoomUserNextVoid6(id receiver, SEL selector) {
    YTzoomNoteUserNext(@"lockscreenNext");
    if (OriginalUserNext[6] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[6])(receiver, selector);
    }
}

static void YTzoomUserNextVoid2(id receiver, SEL selector) {
    YTzoomNoteUserNext(@"miniplayerNext");
    if (OriginalUserNext[2] != NULL) {
        ((void (*)(id, SEL))OriginalUserNext[2])(receiver, selector);
    }
}

static void YTzoomUserNextPanel(id receiver, SEL selector,
                                unsigned long long index) {
    YTzoomNoteUserNextRequiringTouch(@"panelSelect", YES);
    if (OriginalUserNext[3] != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalUserNext[3])(
            receiver, selector, index);
    }
}

static void YTzoomUserNextEndpoint(id receiver, SEL selector, id endpoint) {
    YTzoomNoteUserNext(@"nextFromEndpoint");
    if (OriginalUserNext[4] != NULL) {
        ((void (*)(id, SEL, id))OriginalUserNext[4])(receiver, selector,
                                                     endpoint);
    }
}

void YTzoomInstallAutoplayHooks(void) {
    YTzoomInstallInstanceHook(@"YTWatchFlowController", @"playAutoplay",
                              (IMP)YTzoomPlayAutoplay, &OriginalPlayAutoplay);
    YTzoomInstallInstanceHook(@"YTQueueController", @"triggerPendingAutoplay",
                              (IMP)YTzoomTriggerPendingAutoplay,
                              &OriginalTriggerPendingAutoplay);
    YTzoomInstallInstanceHook(
        @"YTQueueController",
        @"advanceToNextWithAutoplay:isPlaybackControllerInternalTransition:"
         "unplayableVideoID:",
        (IMP)YTzoomAdvanceToNext, &OriginalAdvanceToNext);
    YTzoomInstallInstanceHook(@"YTWatchPlaybackController",
                              @"shouldAutonavToNextVideo",
                              (IMP)YTzoomShouldAutonav, &OriginalShouldAutonav);

    NSString *const layer = @"YTWatchLayerViewController";
    YTzoomInstallInstanceHook(layer, @"setWatchTransition:onAppStartup:",
                              (IMP)YTzoomSetWatchTransitionStartup,
                              &OriginalSetWatchTransitionStartup);
    YTzoomInstallInstanceHook(layer, @"insertOrUpdateSingleWatchTransition:",
                              (IMP)YTzoomInsertOrUpdateSingle,
                              &OriginalInsertOrUpdateSingle);
    YTzoomInstallInstanceHook(layer, @"setSingleWatchTransition:",
                              (IMP)YTzoomSetSingleWatchTransition,
                              &OriginalSetSingleWatchTransition);
    YTzoomInstallInstanceHook(@"UIApplication", @"sendEvent:",
                              (IMP)YTzoomSendEvent, &OriginalSendEvent);

    YTzoomInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressNext:",
        (IMP)YTzoomUserNextSender0, &OriginalUserNext[0]);
    YTzoomInstallInstanceHook(
        @"YTMainAppControlsOverlayView", @"didPressNext:",
        (IMP)YTzoomUserNextSender1, &OriginalUserNext[1]);
    YTzoomInstallInstanceHook(
        @"YTWatchFloatingMiniplayerViewController", @"didTapNext",
        (IMP)YTzoomUserNextVoid2, &OriginalUserNext[2]);
    YTzoomInstallInstanceHook(
        @"YTPlaylistPanelController", @"didSelectEntryAtIndex:",
        (IMP)YTzoomUserNextPanel, &OriginalUserNext[3]);
    YTzoomInstallInstanceHook(
        @"YTWatchPreviousController",
        @"handleNextButtonWithFromNavigationEndpoint:",
        (IMP)YTzoomUserNextEndpoint, &OriginalUserNext[4]);
    YTzoomInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"didPressPlayerBarNext",
        (IMP)YTzoomUserNextVoid5, &OriginalUserNext[5]);
    YTzoomInstallInstanceHook(
        @"YTWatchController", @"didPressNextTrackLockscreenButton",
        (IMP)YTzoomUserNextVoid6, &OriginalUserNext[6]);
    YTzoomInstallInstanceHook(
        @"YTRemoteCommandHandler", @"handleNextTrackCommand:",
        (IMP)YTzoomUserNextRemote, &OriginalUserNext[7]);
}
