#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTzoomShortsPinchKey =
    @"YTzoom.Preference.Shorts.PinchFullscreen";

static IMP OriginalDidPinch;
static IMP OriginalReelWillDisappear;

static BOOL YTzoomShortsImmersive;

static id YTzoomPinchSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id YTzoomAppViewController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIViewController *root = window.rootViewController;
            if ([root respondsToSelector:NSSelectorFromString(@"hidePivotBar")]) {
                return root;
            }
        }
    }
    return nil;
}

static const void *YTzoomPinchAlphaKey = &YTzoomPinchAlphaKey;

static void YTzoomFadeOverlaySubviews(UIView *overlay, BOOL hidden) {
    for (UIView *subview in overlay.subviews) {
        if (hidden) {
            if (objc_getAssociatedObject(subview, YTzoomPinchAlphaKey) == nil) {
                objc_setAssociatedObject(subview, YTzoomPinchAlphaKey,
                                         @(subview.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            subview.alpha = 0.0;
        } else {
            NSNumber *saved = objc_getAssociatedObject(subview,
                                                       YTzoomPinchAlphaKey);
            if (saved != nil) {
                subview.alpha = saved.doubleValue;
                objc_setAssociatedObject(subview, YTzoomPinchAlphaKey, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void YTzoomSettleOverlay(UIView *overlay) {
    if (overlay == nil) return;
    __weak UIView *weakOverlay = overlay;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strong = weakOverlay;
        if (strong == nil) return;
        [strong setNeedsLayout];
        [strong layoutIfNeeded];
        for (UIView *subview in strong.subviews) {
            [subview setNeedsLayout];
            [subview layoutIfNeeded];
        }
    });
}

static UIView *YTzoomReelOverlay(UIViewController *shorts) {
    id content = YTzoomPinchSend(shorts, @"contentView") ?: shorts.view;
    id overlay = YTzoomPinchSend(content, @"playbackOverlay");
    return [overlay isKindOfClass:UIView.class] ? overlay : nil;
}

static void YTzoomSetShortsImmersive(BOOL immersive, UIViewController *shorts) {
    if (immersive == YTzoomShortsImmersive) return;
    YTzoomShortsImmersive = immersive;

    id app = YTzoomAppViewController();
    SEL toggle = NSSelectorFromString(immersive ? @"hidePivotBar" : @"showPivotBar");
    if ([app respondsToSelector:toggle]) {
        ((void (*)(id, SEL))objc_msgSend)(app, toggle);
    }
    UIView *overlay = YTzoomReelOverlay(shorts);
    if (overlay == nil) return;
    [UIView animateWithDuration:0.2 animations:^{
        YTzoomFadeOverlaySubviews(overlay, immersive);
    } completion:^(BOOL finished) {
        (void)finished;
        if (!immersive) YTzoomSettleOverlay(overlay);
    }];
}

static UIViewController *YTzoomShortsControllerForPlayerView(id playerView) {
    id delegate = YTzoomPinchSend(playerView, @"playerViewDelegate");
    id parent = YTzoomPinchSend(delegate, @"parentViewController");
    if (![parent isKindOfClass:UIViewController.class]) return nil;
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    Class reelClass = NSClassFromString(@"YTReelPlayerViewController");
    if ((shortsClass != Nil && [parent isKindOfClass:shortsClass]) ||
        (reelClass != Nil && [parent isKindOfClass:reelClass])) {
        return parent;
    }
    return nil;
}

static void YTzoomDidPinch(id receiver, SEL selector, id recognizer) {
    if (OriginalDidPinch != NULL) {
        ((void (*)(id, SEL, id))OriginalDidPinch)(receiver, selector, recognizer);
    }
    if (!YTzoomFeatureEnabled(YTzoomShortsPinchKey)) return;
    if (![recognizer isKindOfClass:UIPinchGestureRecognizer.class]) return;

    UIPinchGestureRecognizer *pinch = recognizer;
    if (pinch.state != UIGestureRecognizerStateChanged &&
        pinch.state != UIGestureRecognizerStateEnded) {
        return;
    }
    UIViewController *shorts = YTzoomShortsControllerForPlayerView(receiver);
    if (shorts == nil) return;

    if (pinch.scale > 1.05) {
        YTzoomSetShortsImmersive(YES, shorts);
    } else if (pinch.scale < 0.95) {
        YTzoomSetShortsImmersive(NO, shorts);
    }
}

static void YTzoomReelWillDisappear(id receiver, SEL selector, BOOL animated) {
    if (YTzoomShortsImmersive) {
        YTzoomShortsImmersive = NO;
        id app = YTzoomAppViewController();
        SEL show = NSSelectorFromString(@"showPivotBar");
        if ([app respondsToSelector:show]) {
            ((void (*)(id, SEL))objc_msgSend)(app, show);
        }
        UIView *overlay = YTzoomReelOverlay(receiver);
        if (overlay != nil) {
            YTzoomFadeOverlaySubviews(overlay, NO);
            YTzoomSettleOverlay(overlay);
        }
    }
    if (OriginalReelWillDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalReelWillDisappear)(
            receiver, selector, animated);
    }
}

static IMP OriginalShowPivotBar;

static void YTzoomShowPivotBar(id receiver, SEL selector) {
    if (YTzoomShortsPivotShowBlocked()) {
        UIWindow *window = [receiver respondsToSelector:@selector(view)] ? [(UIViewController *)receiver view].window : nil;
        if (YTzoomShortsContainerForView(window, window) != nil) {
            return;
        }
        YTzoomSetShortsNewFullscreen(nil, NO);
        return;
    }
    if (OriginalShowPivotBar != NULL) ((void (*)(id, SEL))OriginalShowPivotBar)(receiver, selector);
}

static IMP OriginalReelRootWillDisappear;

static void YTzoomReelRootWillDisappear(id receiver, SEL selector, BOOL animated) {
    if (YTzoomShortsNewFullscreenActive()) {
        YTzoomSetShortsNewFullscreen(nil, NO);
    }
    if (OriginalReelRootWillDisappear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalReelRootWillDisappear)(receiver, selector, animated);
    }
}

void YTzoomInstallShortsPinchHooks(void) {
    YTzoomInstallInstanceHook(@"YTAppViewController", @"showPivotBar",
                              (IMP)YTzoomShowPivotBar, &OriginalShowPivotBar);
    YTzoomInstallInstanceHook(@"YTReelWatchRootViewController", @"viewWillDisappear:",
                              (IMP)YTzoomReelRootWillDisappear, &OriginalReelRootWillDisappear);
    YTzoomInstallInstanceHook(@"YTPlayerView", @"didPinch:",
                              (IMP)YTzoomDidPinch, &OriginalDidPinch);
    YTzoomInstallInstanceHook(@"YTReelPlayerViewController",
                              @"viewWillDisappear:",
                              (IMP)YTzoomReelWillDisappear,
                              &OriginalReelWillDisappear);
}
