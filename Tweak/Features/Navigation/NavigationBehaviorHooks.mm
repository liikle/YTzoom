#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalControlSendAction;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomStatusOriginals;
static BOOL YTzoomCastBypass;

static BOOL YTzoomIsCastControl(UIControl *control, SEL action, id target) {
    (void)target;
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@ %@",
        NSStringFromClass(control.class),
        control.accessibilityIdentifier ?: @"",
        control.accessibilityLabel ?: @"",
        NSStringFromSelector(action)]
        lowercaseString];
    return [token containsString:@"cast"] ||
        [token containsString:@"airplay"] ||
        [token containsString:@"routebutton"] ||
        [token containsString:@"mdx"];
}

static void YTzoomControlSendAction(UIControl *receiver,
                                    SEL selector,
                                    SEL action,
                                    id target,
                                    UIEvent *event) {
    if (OriginalControlSendAction == NULL) {
        return;
    }
    BOOL castControl = YTzoomIsCastControl(receiver, action, target);
    if (castControl) {
        YTzoomStartCastDiscovery();
    }
    if (YTzoomCastBypass ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.CastConfirmation") ||
        !castControl) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
        return;
    }
    __weak UIControl *weakReceiver = receiver;
    __weak id weakTarget = target;
    BOOL shown = YTzoomShowYouTubeConfirmation(
        YTzoomLocalized(@"Connect to a device?"),
        YTzoomLocalized(@"YouTube is about to open the Cast menu."),
        YTzoomLocalized(@"Continue"),
        ^{
            UIControl *strongReceiver = weakReceiver;
            if (strongReceiver == nil) {
                return;
            }
            YTzoomCastBypass = YES;
            ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
                strongReceiver, selector, action, weakTarget, event
            );
            YTzoomCastBypass = NO;
        }
    );
    if (!shown) {
        ((void (*)(id, SEL, SEL, id, id))OriginalControlSendAction)(
            receiver, selector, action, target, event
        );
    }
}

static NSString *YTzoomStatusKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTzoomStatusOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTzoomStatusOriginals[
            YTzoomStatusKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL YTzoomPrefersStatusHidden(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.StatusBarHidden")) {
        return YES;
    }
    NSString *name = NSStringFromClass([receiver class]).lowercaseString;
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.StatusBarVisible") &&
        ([name containsString:@"player"] || [name containsString:@"watch"])) {
        return NO;
    }
    IMP original = YTzoomStatusOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

void YTzoomInstallNavigationBehaviorHooks(void) {
    if (YTzoomStatusOriginals == nil) {
        YTzoomStatusOriginals = [NSMutableDictionary dictionary];
    }
    YTzoomInstallInstanceHook(@"UIControl",
                              @"sendAction:to:forEvent:",
                              (IMP)YTzoomControlSendAction,
                              &OriginalControlSendAction);
    for (NSString *className in @[
        @"YTAppViewController",
        @"YTWatchViewController",
        @"YTPlayerViewController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTShortsPlayerViewController"
    ]) {
        IMP original = NULL;
        if (YTzoomInstallInstanceHook(className,
                                      @"prefersStatusBarHidden",
                                      (IMP)YTzoomPrefersStatusHidden,
                                      &original) && original != NULL) {
            Class cls = NSClassFromString(className);
            YTzoomStatusOriginals[YTzoomStatusKey(
                cls,
                NSSelectorFromString(@"prefersStatusBarHidden")
            )] = [NSValue valueWithPointer:(const void *)original];
        }
    }
}
