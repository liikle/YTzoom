#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static IMP YTzoomZoomOrigBegin;
static IMP YTzoomZoomOrigZoom;
static IMP YTzoomZoomOrigEnd;
static IMP YTzoomZoomOrigMaxState;
static IMP YTzoomZoomOrigLayout;
static BOOL YTzoomZoomReleasing;
static BOOL YTzoomZoomResyncPending;
static const double YTzoomZoomUnlimitedMax = 50.0;

static NSInteger YTzoomZoomMode(void) {
    id stored = YTzoomPreferenceObject(@"YTzoom.Preference.Playback.VideoZoom");
    return [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
}

static double YTzoomZoomDouble(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return NAN;
    return ((double (*)(id, SEL))objc_msgSend)(object, selector);
}

static void YTzoomZoomSetDouble(id object, NSString *name, double value) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, double))objc_msgSend)(object, selector, value);
}

static void YTzoomZoomCall(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL))objc_msgSend)(object, selector);
}

static double YTzoomZoomFillFactor(id controller) {
    static Ivar ivar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Ivar found = class_getInstanceVariable(object_getClass(controller), "_snappedZoomFactor");
        const char *type = found != NULL ? ivar_getTypeEncoding(found) : NULL;
        if (type != NULL && strcmp(type, "d") == 0) ivar = found;
    });
    if (ivar == NULL) return NAN;
    return *(double *)((uint8_t *)(__bridge void *)controller + ivar_getOffset(ivar));
}

static void YTzoomZoomBegin(id self, SEL _cmd, CGPoint point) {
    if (YTzoomZoomMode() == 2) {
        YTzoomZoomSetDouble(self, @"setMaxFreeZoomFactor:", YTzoomZoomUnlimitedMax);
        YTzoomZoomSetDouble(self, @"setMaxFreeZoomLimit:", YTzoomZoomUnlimitedMax * 1.2);
    }
    ((void (*)(id, SEL, CGPoint))YTzoomZoomOrigBegin)(self, _cmd, point);
}

static void YTzoomZoomDidZoom(id self, SEL _cmd, double zoom, BOOL twoFinger) {
    if (zoom > 1.0 && YTzoomZoomMode() == 1) {
        const double fill = YTzoomZoomFillFactor(self);
        const double current = YTzoomZoomDouble(self, @"videoZoomFactor");
        if (fill >= 1.0 && current > 0.0) {
            if (current >= fill) {
                zoom = 1.0;
            } else if (current * zoom > fill) {
                zoom = fill / current;
            }
        }
    }
    ((void (*)(id, SEL, double, BOOL))YTzoomZoomOrigZoom)(self, _cmd, zoom, twoFinger);
}

static void YTzoomZoomEnd(id self, SEL _cmd) {
    YTzoomZoomReleasing = YES;
    ((void (*)(id, SEL))YTzoomZoomOrigEnd)(self, _cmd);
    YTzoomZoomReleasing = NO;
}

static void YTzoomZoomMaxState(id self, SEL _cmd) {
    if (YTzoomZoomMode() != 2 || !YTzoomZoomReleasing) {
        ((void (*)(id, SEL))YTzoomZoomOrigMaxState)(self, _cmd);
        return;
    }
    const double current = YTzoomZoomDouble(self, @"videoZoomFactor");
    if (current <= YTzoomZoomUnlimitedMax) return;
    YTzoomZoomSetDouble(self, @"setVideoZoomFactor:", YTzoomZoomUnlimitedMax);
    YTzoomZoomSetDouble(self, @"updateRenderingViewFrameWithAnimationDuration:", 0.25);
}

static void YTzoomZoomLayout(id self, SEL _cmd, int layout) {
    ((void (*)(id, SEL, int))YTzoomZoomOrigLayout)(self, _cmd, layout);
    if (YTzoomZoomDouble(self, @"videoZoomFactor") <= 1.001 || YTzoomZoomResyncPending) return;
    YTzoomZoomResyncPending = YES;
    __weak id weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomZoomResyncPending = NO;
        id strongSelf = weakSelf;
        if (strongSelf == nil) return;
        YTzoomZoomCall(strongSelf, @"resetVideoFrameToOriginalState");
    });
}

void YTzoomInstallVideoZoomHooks(void) {
    NSString *zoomClass = @"YTVideoFreeZoomOverlayController";
    YTzoomInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidBeginAtPoint:",
                              (IMP)YTzoomZoomBegin, &YTzoomZoomOrigBegin);
    YTzoomInstallInstanceHook(zoomClass, @"freeZoomViewDidZoom:isTwoFingerZoom:",
                              (IMP)YTzoomZoomDidZoom, &YTzoomZoomOrigZoom);
    YTzoomInstallInstanceHook(zoomClass, @"freeZoomViewPinchDidEnd",
                              (IMP)YTzoomZoomEnd, &YTzoomZoomOrigEnd);
    YTzoomInstallInstanceHook(zoomClass, @"resetVideoFrameToMaxFreeState",
                              (IMP)YTzoomZoomMaxState, &YTzoomZoomOrigMaxState);
    YTzoomInstallInstanceHook(zoomClass, @"freeZoomViewDidSetPlayerViewLayout:",
                              (IMP)YTzoomZoomLayout, &YTzoomZoomOrigLayout);
}
