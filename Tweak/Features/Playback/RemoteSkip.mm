#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <MediaPlayer/MediaPlayer.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const YTzoomRemoteSkipKey = @"YTzoom.Preference.Playback.RemoteSkip";
static IMP OriginalRemoteSetEnabled;
static BOOL YTzoomRemoteTargetsAdded;

static NSInteger YTzoomRemoteSkipInterval(void) {
    if (!YTzoomMasterEnabled()) return 0;
    NSInteger value = [YTzoomPreferenceObject(YTzoomRemoteSkipKey) integerValue];
    return value > 0 ? value : 0;
}

static id YTzoomRemotePlayer(UIViewController *controller, NSUInteger depth) {
    if (controller == nil || depth > 14) return nil;
    if ([NSStringFromClass(controller.class) isEqualToString:@"YTPlayerViewController"]) {
        SEL current = NSSelectorFromString(@"currentVideoID");
        id value = [controller respondsToSelector:current]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, current) : nil;
        if ([value isKindOfClass:NSString.class] && [value length] != 0) return controller;
    }
    for (UIViewController *child in controller.childViewControllers) {
        id found = YTzoomRemotePlayer(child, depth + 1);
        if (found != nil) return found;
    }
    return YTzoomRemotePlayer(controller.presentedViewController, depth + 1);
}

static MPRemoteCommandHandlerStatus YTzoomRemoteSkip(double direction) {
    NSInteger interval = YTzoomRemoteSkipInterval();
    if (interval <= 0) return MPRemoteCommandHandlerStatusCommandFailed;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id player = YTzoomRemotePlayer(window.rootViewController, 0);
            SEL timeSel = NSSelectorFromString(@"currentVideoMediaTime");
            SEL totalSel = NSSelectorFromString(@"currentVideoTotalMediaTime");
            SEL seekSel = NSSelectorFromString(@"seekToTime:");
            if (player == nil || ![player respondsToSelector:timeSel] || ![player respondsToSelector:seekSel]) continue;
            double time = ((double (*)(id, SEL))objc_msgSend)(player, timeSel) + direction * (double)interval;
            double total = [player respondsToSelector:totalSel]
                ? ((double (*)(id, SEL))objc_msgSend)(player, totalSel) : 0.0;
            if (total > 1.0) time = MIN(time, total - 0.5);
            ((void (*)(id, SEL, double))objc_msgSend)(player, seekSel, MAX(0.0, time));
            return MPRemoteCommandHandlerStatusSuccess;
        }
    }
    return MPRemoteCommandHandlerStatusNoActionableNowPlayingItem;
}

static BOOL YTzoomIsTrackCommand(id command) {
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    return command == center.nextTrackCommand || command == center.previousTrackCommand;
}

static void YTzoomRemoteSetEnabled(id receiver, SEL selector, BOOL enabled) {
    if (YTzoomRemoteSkipInterval() > 0) {
        MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
        if (YTzoomIsTrackCommand(receiver)) enabled = NO;
        else if (receiver == center.skipForwardCommand || receiver == center.skipBackwardCommand) enabled = YES;
    }
    ((void (*)(id, SEL, BOOL))OriginalRemoteSetEnabled)(receiver, selector, enabled);
}

static void YTzoomConfigureRemoteSkip(void) {
    NSInteger interval = YTzoomRemoteSkipInterval();
    MPRemoteCommandCenter *center = MPRemoteCommandCenter.sharedCommandCenter;
    if (interval > 0 && !YTzoomRemoteTargetsAdded) {
        YTzoomRemoteTargetsAdded = YES;
        [center.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return YTzoomRemoteSkip(1.0);
        }];
        [center.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(__unused MPRemoteCommandEvent *event) {
            return YTzoomRemoteSkip(-1.0);
        }];
    }
    if (!YTzoomRemoteTargetsAdded) return;
    center.skipForwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipBackwardCommand.preferredIntervals = @[@(MAX(interval, 1))];
    center.skipForwardCommand.enabled = interval > 0;
    center.skipBackwardCommand.enabled = interval > 0;
    if (interval > 0) {
        center.nextTrackCommand.enabled = NO;
        center.previousTrackCommand.enabled = NO;
    }
}

__attribute__((constructor)) static void YTzoomInstallRemoteSkip(void) {
    __block BOOL installed = NO;
    void (^install)(void) = ^{
        if (installed) {
            YTzoomConfigureRemoteSkip();
            return;
        }
        if (YTzoomRemoteSkipInterval() <= 0) return;
        installed = YES;
        YTzoomInstallInstanceHook(@"MPRemoteCommand", @"setEnabled:",
                                  (IMP)YTzoomRemoteSetEnabled, &OriginalRemoteSetEnabled);
        YTzoomConfigureRemoteSkip();
    };
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), install);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:YTzoomPreferencesDidChangeNotification object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *note) {
        install();
    }];
}
