#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadCoordinator.h"
#import "../Downloads/DownloadLog.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSHashTable<UIView *> *YTzoomReelViews;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomShortsOriginals;
static NSMutableSet<NSString *> *YTzoomShortsInstalledHooks;
static const void *YTzoomShortsTrackAssociation = &YTzoomShortsTrackAssociation;
static const void *YTzoomShortsFillAssociation = &YTzoomShortsFillAssociation;
static const void *YTzoomShortsSkipAssociation = &YTzoomShortsSkipAssociation;
static const void *YTzoomShortsDownloadAssociation = &YTzoomShortsDownloadAssociation;
static const void *YTzoomShortsHiddenAssociation = &YTzoomShortsHiddenAssociation;
static const void *YTzoomShortsDownloadConstraintsAssociation =
    &YTzoomShortsDownloadConstraintsAssociation;
static const void *YTzoomShortsDownloadAnchoredAssociation =
    &YTzoomShortsDownloadAnchoredAssociation;
static const void *YTzoomShortsRailTransformAssociation =
    &YTzoomShortsRailTransformAssociation;
static const void *YTzoomShortsInitialRefreshAssociation =
    &YTzoomShortsInitialRefreshAssociation;
static NSInteger const YTzoomShortsDownloadTag = 0x59544B44;
static double YTzoomLastShortsTime;
static double YTzoomLastShortsDuration;
static id YTzoomLatestShortsPlayerResponse;

static void YTzoomReelLayout(UIView *receiver, SEL selector);
static void YTzoomReelOverlayLayout(UIView *receiver, SEL selector);
static void YTzoomShortsControllerLayout(UIViewController *receiver,
                                         SEL selector);
static void YTzoomPausedLayout(UIView *receiver, SEL selector);
static void YTzoomInteractiveStickerLayout(UIView *receiver, SEL selector);
static NSArray<NSArray<NSString *> *> *YTzoomShortsRules(void);

static void YTzoomSetShortsHidden(UIView *view, BOOL hidden) {
    NSNumber *owned = objc_getAssociatedObject(
        view, YTzoomShortsHiddenAssociation);
    if (hidden) {
        if (owned == nil) {
            objc_setAssociatedObject(view, YTzoomShortsHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (owned != nil) {
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, YTzoomShortsHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTzoomAnyShortsActionHidden(void) {
    for (NSArray<NSString *> *rule in YTzoomShortsRules()) {
        if (YTzoomFeatureEnabled(rule.firstObject)) return YES;
    }
    return NO;
}

static NSArray<NSArray<NSString *> *> *YTzoomShortsRules(void) {
    static NSArray<NSArray<NSString *> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        rules = @[
            @[@"YTzoom.Preference.Shorts.RemixHidden", @"id.reel_remix_button"],
            @[@"YTzoom.Preference.Shorts.SoundHidden", @"id.reel_pivot_button"],
            @[@"YTzoom.Preference.Shorts.ShareHidden", @"id.reel_share_button"],
            @[@"YTzoom.Preference.Shorts.CommentsHidden", @"id.reel_comment_button"],
            @[@"YTzoom.Preference.Shorts.LikeHidden", @"id.reel_like_button"],
            @[@"YTzoom.Preference.Shorts.SaveHidden"]
        ];
    });
    return rules;
}

typedef struct {
    CGFloat minX;
    CGFloat width;
    CGFloat height;
    BOOL valid;
} YTzoomRailMetrics;

static BOOL YTzoomIsIdentifiedRailButton(NSString *identifier) {
    return [identifier hasPrefix:@"id.reel_"] &&
        [identifier hasSuffix:@"_button"];
}

static void YTzoomCollectRailMetrics(UIView *view,
                                     UIView *root,
                                     YTzoomRailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (YTzoomIsIdentifiedRailButton(identifier)) {
        CGRect frame = [view convertRect:view.bounds toView:root];
        if (CGRectGetWidth(frame) > 32.0 && CGRectGetHeight(frame) > 32.0) {
            metrics->minX = CGRectGetMinX(frame);
            metrics->width = CGRectGetWidth(frame);
            metrics->height = CGRectGetHeight(frame);
            metrics->valid = YES;
        }
    }
    for (UIView *child in view.subviews) {
        YTzoomCollectRailMetrics(child, root, metrics);
    }
}

static BOOL YTzoomShortsIsSaveButton(UIView *view,
                                     UIView *root,
                                     const YTzoomRailMetrics *metrics) {
    if (metrics == NULL || !metrics->valid) return NO;
    if (view.accessibilityIdentifier.length != 0) return NO;
    if (view.accessibilityLabel.length == 0) return NO;
    if (view.tag == YTzoomShortsDownloadTag) return NO;
    CGRect frame = [view convertRect:view.bounds toView:root];
    return fabs(CGRectGetMinX(frame) - metrics->minX) < 6.0 &&
        fabs(CGRectGetWidth(frame) - metrics->width) < 8.0 &&
        fabs(CGRectGetHeight(frame) - metrics->height) < 14.0;
}

static BOOL YTzoomShortsActionHidden(UIView *view,
                                     UIView *root,
                                     const YTzoomRailMetrics *metrics) {
    if (view.tag == YTzoomShortsDownloadTag ||
        [view.accessibilityIdentifier hasPrefix:@"YTzoom"]) {
        return NO;
    }
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    BOOL actionable = [view isKindOfClass:UIControl.class] ||
        view.accessibilityIdentifier.length != 0 ||
        view.accessibilityLabel.length != 0;
    if (!actionable) return NO;
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.SaveHidden") &&
        YTzoomShortsIsSaveButton(view, root, metrics)) {
        return YES;
    }
    for (NSArray<NSString *> *rule in YTzoomShortsRules()) {
        if (!YTzoomFeatureEnabled(rule.firstObject)) continue;
        for (NSUInteger index = 1; index < rule.count; index++) {
            NSString *needle = rule[index];
            if (identifier.length != 0 && [identifier containsString:needle]) {
                return YES;
            }
        }
    }
    return NO;
}

static void YTzoomApplyShortsVisibilityWalk(UIView *view,
                                            UIView *root,
                                            const YTzoomRailMetrics *metrics) {
    YTzoomSetShortsHidden(view, YTzoomShortsActionHidden(view, root, metrics));
    for (UIView *subview in view.subviews) {
        YTzoomApplyShortsVisibilityWalk(subview, root, metrics);
    }
}

static void YTzoomApplyShortsActionVisibility(UIView *view) {
    YTzoomRailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTzoomCollectRailMetrics(view, view, &metrics);
    YTzoomApplyShortsVisibilityWalk(view, view, &metrics);
}

static BOOL YTzoomIsShortsActionIdentifier(NSString *identifier) {
    return [identifier isEqualToString:@"id.reel_like_button"] ||
        [identifier isEqualToString:@"id.reel_comment_button"] ||
        [identifier isEqualToString:@"id.reel_share_button"] ||
        [identifier isEqualToString:@"id.reel_remix_button"] ||
        [identifier isEqualToString:@"id.reel_pivot_button"];
}

static BOOL YTzoomIsShortsActionView(UIView *view, UIView *root,
                                     const YTzoomRailMetrics *metrics) {
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    if (identifier.length != 0) {
        return YTzoomIsShortsActionIdentifier(identifier);
    }
    return YTzoomShortsIsSaveButton(view, root, metrics);
}

static BOOL YTzoomActionIsFullyVisible(UIView *view, UIView *root) {
    CGRect frame = [view convertRect:view.bounds toView:root];
    return CGRectGetWidth(frame) > 20.0 &&
        CGRectGetHeight(frame) > 20.0 &&
        CGRectGetMidX(frame) > CGRectGetWidth(root.bounds) * 0.55 &&
        CGRectGetMinY(frame) >= 0.0 &&
        CGRectGetMaxY(frame) <= CGRectGetHeight(root.bounds);
}

static UIView *YTzoomShortsPlaybackOverlay(UIView *view, UIView *root) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        if ([NSStringFromClass(candidate.class)
                containsString:@"ReelWatchPlaybackOverlayView"]) {
            return candidate;
        }
        if (candidate == root) break;
    }
    CGSize full = root.bounds.size;
    for (UIView *candidate = view.superview; candidate != nil && candidate != root;
         candidate = candidate.superview) {
        CGSize size = candidate.bounds.size;
        if (size.width >= full.width * 0.9 && size.height >= full.height * 0.6) return candidate;
    }
    return nil;
}

static void YTzoomCollectShortsActionsWalk(UIView *view,
                                           UIView *root,
                                           BOOL includeHidden,
                                           const YTzoomRailMetrics *metrics,
                                           NSMutableArray<UIView *> *views) {
    if (view.tag != YTzoomShortsDownloadTag &&
        (includeHidden || (!view.hidden && view.alpha > 0.05)) &&
        YTzoomIsShortsActionView(view, root, metrics) &&
        YTzoomActionIsFullyVisible(view, root)) {
        [views addObject:view];
    }
    for (UIView *subview in view.subviews) {
        YTzoomCollectShortsActionsWalk(subview, root, includeHidden, metrics, views);
    }
}

static void YTzoomCollectShortsActions(UIView *view,
                                       UIView *root,
                                       BOOL includeHidden,
                                       NSMutableArray<UIView *> *views) {
    YTzoomRailMetrics metrics = {0.0, 0.0, 0.0, NO};
    YTzoomCollectRailMetrics(root, root, &metrics);
    YTzoomCollectShortsActionsWalk(view, root, includeHidden, &metrics, views);
}

static UIView *YTzoomVisibleShortsAction(UIView *root) {
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTzoomCollectShortsActions(root, root, NO, actions);
    NSString *expected = nil;
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.LikeHidden")) {
        expected = @"id.reel_like_button";
    } else if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.CommentsHidden")) {
        expected = @"id.reel_comment_button";
    } else if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.ShareHidden")) {
        expected = @"id.reel_share_button";
    } else if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.RemixHidden")) {
        expected = @"id.reel_remix_button";
    } else if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.SoundHidden")) {
        expected = @"id.reel_pivot_button";
    }
    if (expected == nil) return nil;
    for (UIView *action in actions) {
        if (YTzoomShortsPlaybackOverlay(action, root) == nil) continue;
        if ([action.accessibilityIdentifier.lowercaseString
                isEqualToString:expected]) {
            return action;
        }
    }
    return nil;
}

static UIView *YTzoomVisibleShortsPlaybackOverlay(UIView *root) {
    NSString *className = NSStringFromClass(root.class);
    if ([className containsString:@"ReelWatchPlaybackOverlayView"] &&
        root.window != nil && !root.hidden && root.alpha > 0.05 &&
        CGRectGetWidth(root.bounds) > 200.0 &&
        CGRectGetHeight(root.bounds) > 300.0) {
        return root;
    }
    for (UIView *subview in root.subviews) {
        UIView *overlay = YTzoomVisibleShortsPlaybackOverlay(subview);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static UIView *YTzoomCurrentShortsPlaybackOverlay(UIView *root) {
    UIView *visibleOverlay = YTzoomVisibleShortsPlaybackOverlay(root);
    if (visibleOverlay != nil) return visibleOverlay;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTzoomCollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        UIView *overlay = YTzoomShortsPlaybackOverlay(action, root);
        if (overlay != nil) return overlay;
    }
    return nil;
}

static void YTzoomCompactShortsRail(UIView *root) {
    if (!YTzoomAnyShortsActionHidden()) return;
    NSMutableArray<UIView *> *actions = [NSMutableArray array];
    YTzoomCollectShortsActions(root, root, YES, actions);
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTzoomShortsRailTransformAssociation);
        if (baselineValue == nil) {
            baselineValue = [NSValue valueWithCGAffineTransform:action.transform];
            objc_setAssociatedObject(action,
                YTzoomShortsRailTransformAssociation, baselineValue,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        action.transform = baselineValue.CGAffineTransformValue;
    }
    for (UIView *action in actions) {
        NSValue *baselineValue = objc_getAssociatedObject(
            action, YTzoomShortsRailTransformAssociation);
        CGFloat offset = 0.0;
        if (!action.hidden) {
            CGFloat actionY = CGRectGetMinY(
                [action convertRect:action.bounds toView:root]);
            for (UIView *candidate in actions) {
                if (!candidate.hidden) continue;
                CGFloat hiddenY = CGRectGetMinY(
                    [candidate convertRect:candidate.bounds toView:root]);
                if (hiddenY > actionY) {
                    offset += 64.0;
                }
            }
        }
        action.transform = CGAffineTransformTranslate(
            baselineValue.CGAffineTransformValue, 0.0, offset);
    }
}

static void YTzoomPositionShortsDownload(UIView *host,
                                         UIView *action,
                                         UIButton *download) {
    NSArray<NSLayoutConstraint *> *constraints = objc_getAssociatedObject(
        download, YTzoomShortsDownloadConstraintsAssociation);
    NSInteger position = [NSUserDefaults.standardUserDefaults
        integerForKey:@"YTzoom.Preference.Shorts.DownloadPosition"];
    BOOL legacyHost = [NSStringFromClass(host.class) containsString:@"ReelWatchPlaybackOverlayView"];
    if (position == 0 && !legacyHost) {
        if (constraints.count != 0) [NSLayoutConstraint deactivateConstraints:constraints];
        download.translatesAutoresizingMaskIntoConstraints = YES;
        UIEdgeInsets safe = host.safeAreaInsets;
        download.frame = CGRectMake(round(CGRectGetWidth(host.bounds) - safe.right - 12.0 - 36.0),
                                    round(safe.top + 65.0), 36.0, 36.0);
        download.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
        return;
    }
    if (position == 0) {
        if (download.translatesAutoresizingMaskIntoConstraints) {
            download.translatesAutoresizingMaskIntoConstraints = NO;
        }
        if (constraints == nil) {
            constraints = @[
                [download.widthAnchor constraintEqualToConstant:36.0],
                [download.heightAnchor constraintEqualToConstant:36.0],
                [download.trailingAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
                [download.topAnchor constraintEqualToAnchor:
                    host.safeAreaLayoutGuide.topAnchor constant:65.0]
            ];
            objc_setAssociatedObject(download,
                YTzoomShortsDownloadConstraintsAssociation,
                constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [NSLayoutConstraint activateConstraints:constraints];
        [host layoutIfNeeded];
        return;
    }

    if (constraints.count != 0) {
        [NSLayoutConstraint deactivateConstraints:constraints];
    }
    download.translatesAutoresizingMaskIntoConstraints = YES;
    CGFloat centerX = CGRectGetWidth(host.bounds) - 32.0;
    CGFloat top = host.safeAreaInsets.top + 65.0;
    if (action == nil && !CGRectIsEmpty(download.frame) &&
        CGRectGetWidth(download.frame) >= 35.0) {
        return;
    }
    if (action != nil) {
        CGRect frame = [action convertRect:action.bounds toView:host];
        centerX = CGRectGetMidX(frame);
        top = CGRectGetMinY(frame) - 48.0;
    }
    top = MAX(host.safeAreaInsets.top + 52.0, top);
    download.frame = CGRectMake(round(centerX - 18.0), round(top), 36.0, 36.0);
    download.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
}

static NSString *YTzoomShortsHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTzoomShortsOriginal(id receiver, SEL selector,
                                NSUInteger ordinal) {
    NSUInteger candidate = 0;
    for (Class cls = object_getClass(receiver); cls != Nil;
         cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTzoomShortsOriginals[
            YTzoomShortsHookKey(cls, selector)] pointerValue];
        if (original != NULL &&
            original != (IMP)YTzoomReelLayout &&
            original != (IMP)YTzoomReelOverlayLayout &&
            original != (IMP)YTzoomShortsControllerLayout &&
            original != (IMP)YTzoomPausedLayout &&
            original != (IMP)YTzoomInteractiveStickerLayout) {
            if (candidate == ordinal) {
                return original;
            }
            candidate++;
        }
    }
    return NULL;
}

static void YTzoomInvokeShortsOriginal(id receiver, SEL selector) {
    NSMutableDictionary *threadState = NSThread.currentThread.threadDictionary;
    NSString *depthKey = [NSString stringWithFormat:
        @"YTzoom.Shorts.%p.%@", receiver, NSStringFromSelector(selector)];
    NSUInteger depth = [threadState[depthKey] unsignedIntegerValue];
    IMP original = YTzoomShortsOriginal(receiver, selector, depth);
    if (original == NULL) return;

    threadState[depthKey] = @(depth + 1);
    @try {
        ((void (*)(id, SEL))original)(receiver, selector);
    } @finally {
        if (depth == 0) {
            [threadState removeObjectForKey:depthKey];
        } else {
            threadState[depthKey] = @(depth);
        }
    }
}

static Method YTzoomShortsDirectMethod(Class cls, SEL selector) {
    if (cls == Nil) return NULL;
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method result = NULL;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            result = methods[index];
            break;
        }
    }
    free(methods);
    return result;
}

static BOOL YTzoomShortsIsReplacement(IMP implementation) {
    return implementation == (IMP)YTzoomReelLayout ||
        implementation == (IMP)YTzoomReelOverlayLayout ||
        implementation == (IMP)YTzoomShortsControllerLayout ||
        implementation == (IMP)YTzoomPausedLayout ||
        implementation == (IMP)YTzoomInteractiveStickerLayout;
}

static id YTzoomShortsObject(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static id YTzoomShortsResponseFromObject(id object,
                                         NSHashTable *visited,
                                         NSUInteger depth) {
    if (object == nil || depth > 7 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id response = YTzoomShortsObject(object, @"contentPlayerResponse") ?:
        YTzoomShortsObject(object, @"playerResponse");
    if (response != nil) {
        return response;
    }
    for (NSString *name in @[@"_youtubeiOSPlayerViewController", @"parentResponder",
                              @"parentViewController", @"eventsDelegate",
                              @"playbackController", @"activeVideoPlayerOverlay"]) {
        id related = YTzoomShortsObject(object, name);
        response = YTzoomShortsResponseFromObject(related, visited, depth + 1);
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return YTzoomShortsResponseFromObject(
            ((UIResponder *)object).nextResponder, visited, depth + 1);
    }
    return nil;
}

static NSMutableDictionary<NSString *, NSNumber *> *YTzoomShortsBarrenClasses;

static id YTzoomShortsPlayerResponseFromObject(id object) {
    if (object == nil) return nil;
    NSString *name = NSStringFromClass([object class]);
    if (YTzoomShortsBarrenClasses == nil) {
        YTzoomShortsBarrenClasses = [NSMutableDictionary dictionary];
    }
    if (YTzoomShortsBarrenClasses[name].integerValue >= 3) return nil;

    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    id result = YTzoomShortsResponseFromObject(object, visited, 0);
    if (result != nil) {
        [YTzoomShortsBarrenClasses removeObjectForKey:name];
    } else {
        YTzoomShortsBarrenClasses[name] =
            @(YTzoomShortsBarrenClasses[name].integerValue + 1);
    }
    return result;
}

@interface YTzoomShortsDownloadTarget : NSObject
+ (instancetype)sharedTarget;
- (void)downloadTapped:(UIButton *)sender;
@end

@implementation YTzoomShortsDownloadTarget
+ (instancetype)sharedTarget {
    static YTzoomShortsDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomShortsDownloadTarget new]; });
    return target;
}
- (void)downloadTapped:(UIButton *)sender {
    [YTzoomShortsBarrenClasses removeAllObjects];
    id fromView = YTzoomShortsPlayerResponseFromObject(sender);
    id response = fromView ?: YTzoomLatestShortsPlayerResponse;
    YTzoomDownloadCoordinator.sharedCoordinator.playerResponse = response;
    [YTzoomDownloadCoordinator.sharedCoordinator
        showShortsDownloadMenuFromView:sender];
}
@end

static double YTzoomShortsDouble(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static id YTzoomShortsParent(id receiver) {
    SEL selector = NSSelectorFromString(@"parentViewController");
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static id YTzoomFindShortsController(id receiver) {
    id current = receiver;
    for (NSInteger index = 0; current != nil && index < 10; index++) {
        NSString *name = NSStringFromClass([current class]).lowercaseString;
        if ([name containsString:@"shorts"] || [name containsString:@"reel"]) {
            return current;
        }
        id parent = YTzoomShortsParent(current);
        if (parent != nil && parent != current) {
            current = parent;
        } else if ([current isKindOfClass:UIResponder.class]) {
            current = ((UIResponder *)current).nextResponder;
        } else {
            break;
        }
    }
    return nil;
}

static BOOL YTzoomAdvanceShort(id controller, id sender) {
    for (NSString *name in @[
        @"reelContentViewRequestsAdvanceToNextVideo:",
        @"advanceToNextVideo:",
        @"advanceToNextVideo",
        @"scrollToNextVideo"
    ]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([controller class], selector);
        if (method == NULL) {
            continue;
        }
        if (method_getNumberOfArguments(method) == 3) {
            ((void (*)(id, SEL, id))objc_msgSend)(controller, selector, sender);
        } else {
            ((void (*)(id, SEL))objc_msgSend)(controller, selector);
        }
        return YES;
    }
    return NO;
}

static void YTzoomUpdateShortsProgress(void) {
    BOOL enabled = YTzoomFeatureEnabled(@"shortsProgress");
    CGFloat ratio = YTzoomLastShortsDuration > 0.0
        ? (CGFloat)MIN(1.0, MAX(0.0, YTzoomLastShortsTime / YTzoomLastShortsDuration))
        : 0.0;
    for (UIView *view in YTzoomReelViews.allObjects) {
        CALayer *track = objc_getAssociatedObject(view, YTzoomShortsTrackAssociation);
        CALayer *fill = objc_getAssociatedObject(view, YTzoomShortsFillAssociation);
        track.hidden = !enabled;
        fill.hidden = !enabled;
        if (enabled) {
            CGFloat height = 3.0;
            track.frame = CGRectMake(0.0,
                                     MAX(0.0, CGRectGetHeight(view.bounds) - height),
                                     CGRectGetWidth(view.bounds),
                                     height);
            fill.frame = CGRectMake(0.0, 0.0,
                                    CGRectGetWidth(track.bounds) * ratio,
                                    height);
            YTzoomStyleProgressLayer(fill, CGRectGetWidth(track.bounds));
        }
    }
}

@interface YTzoomShortsPinchTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation YTzoomShortsPinchTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    if ([other isKindOfClass:UIPinchGestureRecognizer.class]) return NO;
    if ([other.view isKindOfClass:UIScrollView.class] &&
        other == ((UIScrollView *)other.view).panGestureRecognizer) return NO;
    return YES;
}

- (void)stopPagerUnder:(UIView *)view {
    UIScrollView *pager = nil;
    for (UIView *candidate = view.superview; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UIScrollView.class]) {
            pager = (UIScrollView *)candidate;
            break;
        }
    }
    if (pager == nil) return;
    CGFloat page = CGRectGetHeight(pager.bounds);
    CGPoint offset = pager.contentOffset;
    pager.panGestureRecognizer.enabled = NO;
    pager.panGestureRecognizer.enabled = YES;
    if (page > 1.0) {
        CGFloat snapped = round(offset.y / page) * page;
        if (fabs(snapped - offset.y) > 0.5) [pager setContentOffset:CGPointMake(offset.x, snapped) animated:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {
    if (![other isKindOfClass:UIPinchGestureRecognizer.class] || other == gesture) return NO;
    return YES;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.PinchFullscreen");
}

- (void)pinched:(UIPinchGestureRecognizer *)pinch {
    if (pinch.state == UIGestureRecognizerStateBegan) {
        [self stopPagerUnder:pinch.view];
        return;
    }
    if (pinch.state != UIGestureRecognizerStateEnded) return;
    BOOL active = YTzoomShortsNewFullscreenActive();
    if (pinch.scale > 1.0 && !active) {
        YTzoomSetShortsNewFullscreen(pinch.view, YES);
    } else if (pinch.scale < 1.0 && active) {
        YTzoomSetShortsNewFullscreen(pinch.view, NO);
    }
}
@end

static const void *YTzoomShortsPinchAssociation = &YTzoomShortsPinchAssociation;
static IMP OriginalReelElementLayout;

static void YTzoomReelElementLayout(UIView *receiver, SEL selector) {
    if (OriginalReelElementLayout != NULL) ((void (*)(id, SEL))OriginalReelElementLayout)(receiver, selector);
    if (!YTzoomShortsNewFullscreenActive() || receiver.alpha <= 0.01 || receiver.window == nil) return;
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    UIView *container = receiver.superview;
    for (NSUInteger depth = 0; container != nil && depth < 8 && ![container isKindOfClass:containerClass]; depth++) {
        container = container.superview;
    }
    if (![container isKindOfClass:containerClass]) return;
    YTzoomRegisterFadedShortsContainer(container);
    YTzoomFadeShortsElement(receiver);
}

static void YTzoomPrepareNewShortsContainer(UIView *receiver) {
    if (![NSStringFromClass(receiver.class) isEqualToString:@"YTReelContainerView"]) return;
    if (objc_getAssociatedObject(receiver, YTzoomShortsPinchAssociation) == nil) {
        static YTzoomShortsPinchTarget *target;
        if (target == nil) target = [YTzoomShortsPinchTarget new];
        UIPinchGestureRecognizer *pinch = [[UIPinchGestureRecognizer alloc] initWithTarget:target
                                                                                    action:@selector(pinched:)];
        pinch.delegate = target;
        pinch.cancelsTouchesInView = NO;
        [receiver addGestureRecognizer:pinch];
        objc_setAssociatedObject(receiver, YTzoomShortsPinchAssociation, pinch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTzoomConfigureReelView(UIView *receiver, BOOL showDownload) {
    [YTzoomReelViews addObject:receiver];
    YTzoomPrepareNewShortsContainer(receiver);
    CALayer *track = objc_getAssociatedObject(receiver, YTzoomShortsTrackAssociation);
    CALayer *fill = objc_getAssociatedObject(receiver, YTzoomShortsFillAssociation);
    if (track == nil) {
        track = [CALayer layer];
        track.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.55].CGColor;
        track.zPosition = 10000.0;
        fill = [CALayer layer];
        fill.backgroundColor = UIColor.redColor.CGColor;
        objc_setAssociatedObject(receiver, YTzoomShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [track addSublayer:fill];
        [receiver.layer addSublayer:track];
        objc_setAssociatedObject(receiver, YTzoomShortsTrackAssociation,
                                 track, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(receiver, YTzoomShortsFillAssociation,
                                 fill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (showDownload) {
        YTzoomApplyShortsActionVisibility(receiver);
        YTzoomCompactShortsRail(receiver);
    }
    BOOL visibleHost = receiver.window != nil && !receiver.hidden &&
        receiver.alpha > 0.05 && CGRectGetWidth(receiver.bounds) > 200.0 &&
        CGRectGetHeight(receiver.bounds) > 300.0;
    UIView *action = showDownload && visibleHost
        ? YTzoomVisibleShortsAction(receiver)
        : nil;
    UIView *downloadHost = action == nil
        ? YTzoomCurrentShortsPlaybackOverlay(receiver)
        : YTzoomShortsPlaybackOverlay(action, receiver);
    if (![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) {
        Class containerClass = NSClassFromString(@"YTReelContainerView");
        UIView *container = nil;
        for (UIView *candidate = action ?: receiver; candidate != nil; candidate = candidate.superview) {
            if (containerClass != Nil && [candidate isKindOfClass:containerClass]) {
                container = candidate;
                break;
            }
        }
        if (container == nil && containerClass != Nil && [receiver isKindOfClass:containerClass]) container = receiver;
        if (container != nil && showDownload && visibleHost) downloadHost = container;
        else if (container == nil && downloadHost != nil &&
                 ![NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"]) downloadHost = nil;
    }
    UIButton *download = objc_getAssociatedObject(
        downloadHost, YTzoomShortsDownloadAssociation);
    if (showDownload && visibleHost && downloadHost != nil &&
        download == nil) {
        download = [UIButton buttonWithType:UIButtonTypeSystem];
        download.tag = YTzoomShortsDownloadTag;
        download.accessibilityIdentifier = @"YTzoom Shorts Download";
        download.accessibilityLabel = YTzoomLocalized(@"Download Short");
        download.tintColor = UIColor.whiteColor;
        [download setImage:YTzoomDownloadGlyphImage()
                  forState:UIControlStateNormal];
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                            weight:UIImageSymbolWeightMedium];
        [download setPreferredSymbolConfiguration:configuration
                                  forImageInState:UIControlStateNormal];
        download.layer.shadowColor = UIColor.blackColor.CGColor;
        download.layer.shadowOpacity = 0.55;
        download.layer.shadowRadius = 4.0;
        download.layer.shadowOffset = CGSizeMake(0.0, 2.0);
        download.translatesAutoresizingMaskIntoConstraints = NO;
        [download addTarget:YTzoomShortsDownloadTarget.sharedTarget
                     action:@selector(downloadTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [downloadHost addSubview:download];
        objc_setAssociatedObject(downloadHost, YTzoomShortsDownloadAssociation,
            download, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (download != nil && download.superview == downloadHost) {
        if (action != nil) {
            objc_setAssociatedObject(download,
                YTzoomShortsDownloadAnchoredAssociation, @YES,
                OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        BOOL railMode = [NSUserDefaults.standardUserDefaults
            integerForKey:@"YTzoom.Preference.Shorts.DownloadPosition"] != 0;
        BOOL anchored = [objc_getAssociatedObject(download,
            YTzoomShortsDownloadAnchoredAssociation) boolValue];
        BOOL legacyHost = [NSStringFromClass(downloadHost.class) containsString:@"ReelWatchPlaybackOverlayView"];
        download.hidden = !YTzoomDownloadsEnabled() ||
            (railMode && !anchored && (legacyHost || !YTzoomShortsNewFullscreenActive()));
        YTzoomPositionShortsDownload(downloadHost, action, download);
        [downloadHost bringSubviewToFront:download];
        NSMutableArray<UIView *> *stack =
            [NSMutableArray arrayWithObject:downloadHost];
        NSUInteger duplicates = 0;
        while (stack.count != 0) {
            UIView *candidate = stack.lastObject;
            [stack removeLastObject];
            for (UIView *subview in candidate.subviews) {
                if (subview.tag == YTzoomShortsDownloadTag &&
                    subview != download) {
                    duplicates++;
                    [subview removeFromSuperview];
                } else {
                    [stack addObject:subview];
                }
            }
        }
        (void)duplicates;
    }
    static NSTimeInterval lastResolve = 0.0;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (YTzoomLatestShortsPlayerResponse == nil || now - lastResolve > 0.5) {
        lastResolve = now;
        id response = YTzoomShortsPlayerResponseFromObject(receiver);
        if (response != nil) {
            YTzoomLatestShortsPlayerResponse = response;
        }
    }
    YTzoomUpdateShortsProgress();
}

static void YTzoomReelLayout(UIView *receiver, SEL selector) {
    YTzoomInvokeShortsOriginal(receiver, selector);
    YTzoomConfigureReelView(receiver, NO);
}

static void YTzoomReelOverlayLayout(UIView *receiver, SEL selector) {
    YTzoomInvokeShortsOriginal(receiver, selector);
    YTzoomConfigureReelView(receiver, YES);
}

static void YTzoomShortsControllerLayout(UIViewController *receiver,
                                         SEL selector) {
    YTzoomInvokeShortsOriginal(receiver, selector);
    YTzoomConfigureReelView(receiver.view, YES);
    if (![objc_getAssociatedObject(receiver,
            YTzoomShortsInitialRefreshAssociation) boolValue]) {
        objc_setAssociatedObject(receiver,
            YTzoomShortsInitialRefreshAssociation, @YES,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        __weak UIViewController *weakReceiver = receiver;
        for (NSNumber *delay in @[@0.08, @0.30]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    UIViewController *controller = weakReceiver;
                    if (controller.view.window != nil) {
                        YTzoomConfigureReelView(controller.view, YES);
                    }
                });
        }
    }
}

static void YTzoomPausedLayout(UIView *receiver, SEL selector) {
    YTzoomInvokeShortsOriginal(receiver, selector);
    BOOL hidden = YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.PauseCardHidden");
    YTzoomSetShortsHidden(receiver, hidden);
}

static void YTzoomInteractiveStickerLayout(UIView *receiver, SEL selector) {
    YTzoomInvokeShortsOriginal(receiver, selector);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class).lowercaseString,
        receiver.accessibilityIdentifier.lowercaseString ?: @"",
        receiver.description.lowercaseString ?: @""];
    BOOL product = YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        ([token containsString:@"product"] ||
         [token containsString:@"shopping"]);
    BOOL stickerAd = YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.StickerAdsHidden") &&
        (([token containsString:@"sticker"] &&
          ([token containsString:@"sponsor"] ||
           [token containsString:@"promot"] ||
           [token containsString:@"brand"] ||
           [token containsString:@"product"])) ||
         [token containsString:@"shorts_ads_shopping"]);
    YTzoomSetShortsHidden(receiver, product || stickerAd);
}

static void YTzoomInstallShortsLayout(NSString *className, IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = @selector(layoutSubviews);
    if (YTzoomShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTzoomShortsHookKey(cls, selector);
    if ([YTzoomShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTzoomShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className, @"layoutSubviews",
                                  replacement, &original) &&
        original != NULL && !YTzoomShortsIsReplacement(original)) {
        YTzoomShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTzoomShortsInstalledHooks addObject:key];
    }
}

static void YTzoomInstallShortsController(NSString *className) {
    SEL selector = @selector(viewDidLayoutSubviews);
    Class cls = NSClassFromString(className);
    if (YTzoomShortsDirectMethod(cls, selector) == NULL) return;
    NSString *key = YTzoomShortsHookKey(cls, selector);
    if ([YTzoomShortsInstalledHooks containsObject:key]) return;
    IMP current = method_getImplementation(class_getInstanceMethod(cls, selector));
    if (YTzoomShortsIsReplacement(current)) return;
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className,
                                  NSStringFromSelector(selector),
                                  (IMP)YTzoomShortsControllerLayout,
                                  &original) && original != NULL &&
        !YTzoomShortsIsReplacement(original)) {
        YTzoomShortsOriginals[key] =
            [NSValue valueWithPointer:(const void *)original];
        [YTzoomShortsInstalledHooks addObject:key];
    }
}

static const void *YTzoomShortsLoopAssociation = &YTzoomShortsLoopAssociation;

static void YTzoomShortsTimeChanged(NSNotification *notification) {
    id player = notification.object;
    id shorts = YTzoomFindShortsController(player);
    if (shorts == nil) {
        return;
    }
    static CFTimeInterval lastLookup = 0.0;
    if (YTzoomLatestShortsPlayerResponse == nil ||
        CACurrentMediaTime() - lastLookup > 1.0) {
        lastLookup = CACurrentMediaTime();
        id response = YTzoomShortsPlayerResponseFromObject(player) ?:
            YTzoomShortsPlayerResponseFromObject(shorts);
        if (response != nil) {
            YTzoomLatestShortsPlayerResponse = response;
        }
    }
    double time = [notification.userInfo[@"time"] doubleValue];
    double duration = YTzoomShortsDouble(player, @[
        @"currentVideoTotalMediaTime",
        @"currentVideoTotalTime",
        @"currentVideoDuration",
        @"totalMediaTime"
    ]);
    YTzoomLastShortsTime = time;
    YTzoomLastShortsDuration = duration;
    YTzoomUpdateShortsProgress();

    if (YTzoomShortsLimitReached()) {
        return;
    }
    if (!YTzoomFeatureEnabled(@"autoSkipShorts") && YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.LoopDisabled") &&
        duration > 1.0) {
        if (time < duration * 0.5) {
            objc_setAssociatedObject(shorts, YTzoomShortsLoopAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (time >= duration - 0.3 &&
                   ![objc_getAssociatedObject(shorts, YTzoomShortsLoopAssociation) boolValue]) {
            objc_setAssociatedObject(shorts, YTzoomShortsLoopAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            SEL pause = NSSelectorFromString(@"pause");
            if ([player respondsToSelector:pause]) ((void (*)(id, SEL))objc_msgSend)(player, pause);
        }
        return;
    }
    if (!YTzoomFeatureEnabled(@"autoSkipShorts") || duration <= 1.0) {
        return;
    }
    if (time < duration * 0.5) {
        objc_setAssociatedObject(shorts, YTzoomShortsSkipAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (time >= duration - 0.35 &&
        ![objc_getAssociatedObject(shorts, YTzoomShortsSkipAssociation) boolValue]) {
        if (YTzoomAdvanceShort(shorts, player)) {
            objc_setAssociatedObject(shorts, YTzoomShortsSkipAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

void YTzoomInstallShortsHooks(void) {
    if (YTzoomReelViews == nil) {
        YTzoomReelViews = [NSHashTable weakObjectsHashTable];
        YTzoomShortsOriginals = [NSMutableDictionary dictionary];
        YTzoomShortsInstalledHooks = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter
            addObserverForName:@"YTzoomPlaybackTimeDidChange"
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *notification) {
                YTzoomShortsTimeChanged(notification);
            }];
    }
    for (NSString *className in @[
        @"YTReelContentView",
        @"YTReelPlayerView",
        @"YTShortsPlayerView",
        @"YTShortsPlayerViewControllerView",
        @"YTShortsPlayerViewSwift"
    ]) {
        YTzoomInstallShortsLayout(className, (IMP)YTzoomReelLayout);
    }
    YTzoomInstallInstanceHook(@"YTReelElementAsyncComponentView", @"layoutSubviews",
                              (IMP)YTzoomReelElementLayout, &OriginalReelElementLayout);
    YTzoomInstallShortsLayout(@"YTReelWatchPlaybackOverlayView",
                              (IMP)YTzoomReelOverlayLayout);
    for (NSString *className in @[
        @"YTAppReelWatchRootViewController",
        @"YTReelWatchRootViewController",
        @"YTReelContainerViewController",
        @"YTReelPlaybackViewController",
        @"YTReelPlayerViewController",
        @"YTShortsPlayerViewController"
    ]) {
        YTzoomInstallShortsController(className);
    }
    for (NSString *className in @[
        @"YTReelPausedStateCarouselView",
        @"YTReelPlayerPausedStateView"
    ]) {
        YTzoomInstallShortsLayout(className, (IMP)YTzoomPausedLayout);
    }
    for (NSString *className in @[
        @"YTReelInteractiveStickerView",
        @"YTShortsStickersView",
        @"YTShortsStickersViewSwift"
    ]) {
        YTzoomInstallShortsLayout(className,
                                  (IMP)YTzoomInteractiveStickerLayout);
    }
}
