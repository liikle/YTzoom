#import "../../YTzoom.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Notice.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTzoomShortsLimitKey = @"YTzoom.Preference.Shorts.LimitEnabled";
static NSString * const YTzoomShortsLimitCountKey = @"YTzoom.Preference.Shorts.LimitCount";

static NSMutableOrderedSet<NSString *> *YTzoomShortsSeen;
static BOOL YTzoomShortsBlocked;
static id YTzoomShortsLimitObserver;

static NSInteger YTzoomShortsLimitValue(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults
        integerForKey:YTzoomShortsLimitCountKey];
    if (value < 1) value = 20;
    return MIN(value, 500);
}

BOOL YTzoomShortsLimitReached(void) {
    return YTzoomShortsBlocked;
}

static UIViewController *YTzoomReelRootController(UIViewController *controller,
                                                  NSUInteger depth) {
    if (controller == nil || depth > 6) return nil;
    SEL active = NSSelectorFromString(@"activeReelPlaybackVideoID");
    if ([controller respondsToSelector:active]) return controller;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = YTzoomReelRootController(child, depth + 1);
        if (found != nil) return found;
    }
    return YTzoomReelRootController(controller.presentedViewController, depth + 1);
}

static UIViewController *YTzoomActiveReelController(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isHidden) continue;
            UIViewController *found = YTzoomReelRootController(window.rootViewController, 0);
            if (found != nil) return found;
        }
    }
    return nil;
}

static UIScrollView *YTzoomReelPager(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 8) return nil;
    for (UIView *child in view.subviews) {
        if ([child isKindOfClass:UIScrollView.class]) {
            UIScrollView *candidate = (UIScrollView *)child;
            if (CGRectGetHeight(candidate.bounds) > 200.0 &&
                candidate.contentSize.height > CGRectGetHeight(candidate.bounds)) {
                return candidate;
            }
        }
        UIScrollView *found = YTzoomReelPager(child, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void YTzoomApplyShortsBlock(UIViewController *reel) {
    UIScrollView *pager = YTzoomReelPager(reel.view, 0);
    if (pager == nil) return;
    if (!pager.scrollEnabled) return;
    pager.scrollEnabled = NO;
}

static void YTzoomNoteShort(NSString *videoID, UIViewController *reel) {
    if (videoID.length == 0) return;
    if (YTzoomShortsSeen == nil) YTzoomShortsSeen = [NSMutableOrderedSet orderedSet];
    const NSUInteger before = YTzoomShortsSeen.count;
    [YTzoomShortsSeen addObject:videoID];
    if (YTzoomShortsSeen.count == before) return;

    const NSInteger limit = YTzoomShortsLimitValue();
    if ((NSInteger)YTzoomShortsSeen.count < limit) return;

    const BOOL announce = !YTzoomShortsBlocked;
    YTzoomShortsBlocked = YES;
    YTzoomApplyShortsBlock(reel);
    if (announce) {
        YTzoomShowNotice([NSString stringWithFormat:
            YTzoomLocalized(@"Shorts limit reached (%ld). Restart YouTube to reset."),
            (long)limit]);
    }
}

static void YTzoomShortsLimitTick(void) {
    if (!YTzoomFeatureEnabled(YTzoomShortsLimitKey)) return;
    static NSTimeInterval last = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - last < 0.4) return;
    last = now;

    UIViewController *reel = YTzoomActiveReelController();
    if (reel == nil) return;
    SEL active = NSSelectorFromString(@"activeReelPlaybackVideoID");
    id value = ((id (*)(id, SEL))objc_msgSend)(reel, active);
    if (![value isKindOfClass:NSString.class] || [value length] == 0) return;

    if (YTzoomShortsBlocked) {
        YTzoomApplyShortsBlock(reel);
        return;
    }
    YTzoomNoteShort(value, reel);
}

void YTzoomInstallShortsLimitHooks(void) {
    if (YTzoomShortsLimitObserver != nil) return;
    YTzoomShortsLimitObserver = [NSNotificationCenter.defaultCenter
        addObserverForName:@"YTzoomPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(__unused NSNotification *notification) {
                    YTzoomShortsLimitTick();
                }];
}
