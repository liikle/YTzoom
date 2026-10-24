#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTzoomPreventShortsOpenKey =
    @"YTzoom.Preference.Shorts.PreventAutoOpen";

static IMP OriginalEligibilityModern;
static IMP OriginalEligibilityLegacy;
static IMP OriginalExecuteModern;
static IMP OriginalExecuteLegacy;
static IMP OriginalResumeToShorts;
static IMP OriginalShortsTargeted;
static IMP OriginalLaunchToShorts;

static BOOL YTzoomStartupTabIsOther(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTzoom.Preference.Tabs.Startup"];
    if ([stored isKindOfClass:NSString.class]) {
        NSString *token = stored;
        return token.length != 0 && ![token isEqualToString:@"shorts"];
    }
    NSInteger index = [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
    return index > 0 && index != 3;
}

static BOOL YTzoomPreventShortsOpen(void) {
    return YTzoomFeatureEnabled(YTzoomPreventShortsOpenKey) || YTzoomStartupTabIsOther();
}

static BOOL YTzoomEligibilityModern(id receiver,
                                    SEL selector,
                                    id launchOptions,
                                    id sceneOptions) {
    if (YTzoomPreventShortsOpen()) {
        YTzoomDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id))OriginalEligibilityModern)(
            receiver, selector, launchOptions, sceneOptions);
}

static BOOL YTzoomEligibilityLegacy(id receiver,
                                    SEL selector,
                                    long long applicationState,
                                    id launchOptions) {
    if (YTzoomPreventShortsOpen()) {
        YTzoomDownloadLog(@"shorts", @"eligibility suppressed");
        return NO;
    }
    return OriginalEligibilityLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, long long, id))OriginalEligibilityLegacy)(
            receiver, selector, applicationState, launchOptions);
}

static BOOL YTzoomExecuteModern(id receiver,
                                SEL selector,
                                id responder,
                                id launchOptions,
                                id sceneOptions) {
    if (YTzoomPreventShortsOpen()) {
        YTzoomDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteModern == NULL ? NO
        : ((BOOL (*)(id, SEL, id, id, id))OriginalExecuteModern)(
            receiver, selector, responder, launchOptions, sceneOptions);
}

static BOOL YTzoomExecuteLegacy(id receiver,
                                SEL selector,
                                id responder,
                                long long applicationState,
                                id launchOptions) {
    if (YTzoomPreventShortsOpen()) {
        YTzoomDownloadLog(@"shorts", @"execution suppressed");
        return NO;
    }
    return OriginalExecuteLegacy == NULL ? NO
        : ((BOOL (*)(id, SEL, id, long long, id))OriginalExecuteLegacy)(
            receiver, selector, responder, applicationState, launchOptions);
}

static id YTzoomResumeToShorts(id receiver, SEL selector) {
    if (YTzoomPreventShortsOpen()) return nil;
    return OriginalResumeToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalResumeToShorts)(receiver, selector);
}

static id YTzoomShortsTargeted(id receiver, SEL selector) {
    if (YTzoomPreventShortsOpen()) return nil;
    return OriginalShortsTargeted == NULL ? nil
        : ((id (*)(id, SEL))OriginalShortsTargeted)(receiver, selector);
}

static id YTzoomLaunchToShorts(id receiver, SEL selector) {
    if (YTzoomPreventShortsOpen()) return nil;
    return OriginalLaunchToShorts == NULL ? nil
        : ((id (*)(id, SEL))OriginalLaunchToShorts)(receiver, selector);
}

void YTzoomInstallShortsStartupHooks(void) {
    NSString *coordinator = nil;
    for (NSString *name in @[@"YTShortsStartupCoordinatorImpl",
                             @"YTShortsStartupCoordinator"]) {
        if (NSClassFromString(name) != Nil) {
            coordinator = name;
            break;
        }
    }
    if (coordinator == nil) {
        YTzoomDownloadLog(@"shorts", @"startup coordinator not found");
        return;
    }

    const BOOL eligibilityModern = YTzoomInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithLaunchOptions:sceneConnectionOptions:",
        (IMP)YTzoomEligibilityModern, &OriginalEligibilityModern);
    const BOOL eligibilityLegacy = YTzoomInstallInstanceHook(
        coordinator,
        @"evaluateShortsStartupEligibilityWithApplicationState:launchOptions:",
        (IMP)YTzoomEligibilityLegacy, &OriginalEligibilityLegacy);
    const BOOL executeModern = YTzoomInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:launchOptions:sceneConnectionOptions:",
        (IMP)YTzoomExecuteModern, &OriginalExecuteModern);
    const BOOL executeLegacy = YTzoomInstallInstanceHook(
        coordinator,
        @"executeStartupWithResponder:applicationState:launchOptions:",
        (IMP)YTzoomExecuteLegacy, &OriginalExecuteLegacy);
    const BOOL resume = YTzoomInstallInstanceHook(
        coordinator, @"evaluateResumeToShorts",
        (IMP)YTzoomResumeToShorts, &OriginalResumeToShorts);
    const BOOL targeted = YTzoomInstallInstanceHook(
        coordinator, @"evaluateShortsTargeted",
        (IMP)YTzoomShortsTargeted, &OriginalShortsTargeted);
    const BOOL launch = YTzoomInstallInstanceHook(
        coordinator, @"launchToShorts",
        (IMP)YTzoomLaunchToShorts, &OriginalLaunchToShorts);

    YTzoomDownloadLog(@"shorts",
                      @"startup hooks on %@ em=%d el=%d xm=%d xl=%d r=%d t=%d l=%d enabled=%d",
                      coordinator, eligibilityModern, eligibilityLegacy,
                      executeModern, executeLegacy, resume, targeted, launch,
                      YTzoomPreventShortsOpen());
}
