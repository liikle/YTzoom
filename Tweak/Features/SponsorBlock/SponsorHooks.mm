#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../Downloads/DownloadLog.h"
#import "../../UI/Assets.h"

#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <math.h>

static IMP OriginalDidActivateVideo;
static IMP OriginalSingleVideoTimeChanged;
static IMP OriginalMutatedVideoTimeChanged;
static IMP OriginalPlayerBarLayout;
static IMP OriginalMiniplayerBarLayout;

static const void *YTzoomSponsorSegmentsAssociation = &YTzoomSponsorSegmentsAssociation;
static const void *YTzoomSponsorVideoAssociation = &YTzoomSponsorVideoAssociation;
static const void *YTzoomSponsorSkippedAssociation = &YTzoomSponsorSkippedAssociation;
static const void *YTzoomSponsorMarkerAssociation = &YTzoomSponsorMarkerAssociation;
static const void *YTzoomSponsorRenderedSegmentsAssociation = &YTzoomSponsorRenderedSegmentsAssociation;
static const void *YTzoomSponsorMarkerBoundsAssociation = &YTzoomSponsorMarkerBoundsAssociation;
static const void *YTzoomSponsorMarkerDurationAssociation = &YTzoomSponsorMarkerDurationAssociation;
static __weak id YTzoomCurrentSponsorController;
static NSHashTable<UIView *> *YTzoomSponsorBars;
static BOOL YTzoomSponsorTimeUpdatesEnabled;
static BOOL YTzoomPlaybackTimeNotificationsNeeded;
static id YTzoomPlaybackPreferenceObserver;

static void YTzoomRefreshPlaybackTimePreferenceState(void) {
    YTzoomSponsorTimeUpdatesEnabled =
        YTzoomFeatureEnabled(YTzoomSponsorBlockKey);
    YTzoomPlaybackTimeNotificationsNeeded =
        YTzoomFeatureEnabled(@"shortsProgress") ||
        YTzoomFeatureEnabled(@"autoSkipShorts") ||
        YTzoomFeatureEnabled(YTzoomSpeedKey) ||
        YTzoomFeatureEnabled(YTzoomSleepTimerKey) ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.LocalQueue");
}

static void YTzoomPublishPlaybackTime(id receiver, double time) {
    if (!YTzoomPlaybackTimeNotificationsNeeded) return;
    [NSNotificationCenter.defaultCenter
        postNotificationName:@"YTzoomPlaybackTimeDidChange"
        object:receiver
        userInfo:@{@"time": @(time)}];
}

static id YTzoomObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver == nil || ![receiver respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static double YTzoomDoubleMessage(id receiver, NSArray<NSString *> *selectorNames) {
    for (NSString *selectorName in selectorNames) {
        SEL selector = NSSelectorFromString(selectorName);
        if ([receiver respondsToSelector:selector]) {
            return ((double (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0.0;
}

static NSString *YTzoomVideoIDFromObject(id object) {
    if ([object isKindOfClass:NSString.class]) {
        return object;
    }
    for (NSString *selector in @[@"videoID", @"videoId", @"currentVideoID", @"identifier"]) {
        id value = YTzoomObjectMessage(object, selector);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id details = YTzoomObjectMessage(object, @"videoDetails");
    if (details != nil && details != object) {
        return YTzoomVideoIDFromObject(details);
    }
    return nil;
}

static BOOL YTzoomSponsorFeedbackEnabled(void) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.SponsorBlock.AudioFeedback");
}

static NSString *YTzoomSponsorCategoryTitle(NSString *category) {
    for (NSDictionary *definition in YTzoomSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition[@"title"];
    }
    return YTzoomLocalized(@"Sponsor");
}

static UIViewController *YTzoomTopController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

static void YTzoomSeekToTime(id controller, double time) {
    SEL selector = NSSelectorFromString(@"seekToTime:");
    if ([controller respondsToSelector:selector]) {
        ((void (*)(id, SEL, double))objc_msgSend)(controller, selector, time);
    }
}

static void YTzoomFadeOutSponsorBanner(UIView *banner) {
    if (banner == nil || banner.superview == nil) return;
    [UIView animateWithDuration:0.25 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseIn
                     animations:^{
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(__unused BOOL finished) {
        [banner removeFromSuperview];
    }];
}

@interface YTzoomSponsorUndoTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, weak) UIView *banner;
- (void)unskip;
@end

@implementation YTzoomSponsorUndoTarget
+ (instancetype)sharedTarget {
    static YTzoomSponsorUndoTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomSponsorUndoTarget new]; });
    return target;
}
- (void)unskip {
    id controller = self.controller;
    if (controller != nil) {
        YTzoomSeekToTime(controller, self.startTime);
    }
    YTzoomFadeOutSponsorBanner(self.banner);
}
@end

static void YTzoomShowSponsorSkippedHUD(id controller, double start, NSString *category) {
    NSInteger notificationMode = YTzoomSponsorNotificationMode();
    if (notificationMode == 2) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTzoomTopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTzoomSponsorUndoTarget *target = YTzoomSponsorUndoTarget.sharedTarget;
        YTzoomFadeOutSponsorBanner(target.banner);
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ %@",
                      YTzoomSponsorCategoryTitle(category),
                      YTzoomLocalized(@"segment skipped")];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *undo = [UIButton buttonWithType:UIButtonTypeSystem];
        [undo setTitle:YTzoomLocalized(@"Unskip") forState:UIControlStateNormal];
        [undo setTitleColor:YTzoomAccentColor() forState:UIControlStateNormal];
        undo.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [undo addTarget:target action:@selector(unskip)
            forControlEvents:UIControlEventTouchUpInside];
        NSArray *views = notificationMode == 0 ? @[label, undo] : @[label];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:views];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTzoomApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.banner = banner;
        banner.alpha = 0.0;
        banner.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.25 delay:0.0
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            banner.alpha = 1.0;
            banner.transform = CGAffineTransformIdentity;
        } completion:nil];
        NSTimeInterval duration = notificationMode == 0
            ? YTzoomSponsorUnskipAlertDuration()
            : YTzoomSponsorSkipAlertDuration();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(duration * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    YTzoomFadeOutSponsorBanner(banner);
                }
            });
    });
}

static void YTzoomPerformSponsorSkip(id controller, double start, double end,
                                     NSString *category) {
    YTzoomSeekToTime(controller, end);
    YTzoomShowSponsorSkippedHUD(controller, start, category);
    if (YTzoomSponsorFeedbackEnabled()) {
        AudioServicesPlaySystemSound(1057);
        UINotificationFeedbackGenerator *feedback =
            [UINotificationFeedbackGenerator new];
        [feedback notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

@interface YTzoomSponsorSkipTarget : NSObject
+ (instancetype)sharedTarget;
@property(nonatomic, weak) id controller;
@property(nonatomic, assign) double startTime;
@property(nonatomic, assign) double endTime;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, weak) UIView *banner;
- (void)skip;
@end

@implementation YTzoomSponsorSkipTarget
+ (instancetype)sharedTarget {
    static YTzoomSponsorSkipTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomSponsorSkipTarget new]; });
    return target;
}
- (void)skip {
    id controller = self.controller;
    [self.banner removeFromSuperview];
    if (controller != nil) {
        YTzoomPerformSponsorSkip(controller, self.startTime, self.endTime, self.category);
    }
}
@end

static void YTzoomAskToSkipSponsor(id controller, double start, double end,
                                   NSString *category) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = YTzoomTopController();
        if (presenter.view.window == nil) {
            return;
        }
        YTzoomSponsorSkipTarget *target = YTzoomSponsorSkipTarget.sharedTarget;
        [target.banner removeFromSuperview];
        UIView *banner = [UIView new];
        banner.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.94];
        banner.layer.cornerRadius = 12.0;
        banner.translatesAutoresizingMaskIntoConstraints = NO;
        UILabel *label = [UILabel new];
        label.text = [NSString stringWithFormat:@"%@ segment detected",
                      YTzoomSponsorCategoryTitle(category)];
        label.textColor = UIColor.whiteColor;
        label.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        UIButton *skip = [UIButton buttonWithType:UIButtonTypeSystem];
        [skip setTitle:YTzoomLocalized(@"Skip") forState:UIControlStateNormal];
        [skip setTitleColor:YTzoomAccentColor() forState:UIControlStateNormal];
        skip.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        [skip addTarget:target action:@selector(skip)
            forControlEvents:UIControlEventTouchUpInside];
        UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
            label, skip
        ]];
        content.axis = UILayoutConstraintAxisHorizontal;
        content.alignment = UIStackViewAlignmentCenter;
        content.spacing = 18.0;
        content.translatesAutoresizingMaskIntoConstraints = NO;
        [banner addSubview:content];
        YTzoomApplyGlassBackground(banner, YES);
        [presenter.view addSubview:banner];
        UILayoutGuide *safe = presenter.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [banner.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
            [banner.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-54.0],
            [banner.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-28.0],
            [content.topAnchor constraintEqualToAnchor:banner.topAnchor constant:11.0],
            [content.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:16.0],
            [content.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
            [content.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-11.0]
        ]];
        target.controller = controller;
        target.startTime = start;
        target.endTime = end;
        target.category = category;
        target.banner = banner;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
            (int64_t)(YTzoomSponsorSkipAlertDuration() * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (target.banner == banner) {
                    [banner removeFromSuperview];
                }
            });
    });
}

static void YTzoomEvaluateSponsorTime(id controller, double time) {
    if (!YTzoomSponsorBlockEnabled()) {
        return;
    }

    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTzoomSponsorSegmentsAssociation);
    NSMutableSet<NSNumber *> *skipped =
        objc_getAssociatedObject(controller, YTzoomSponsorSkippedAssociation);
    if (skipped == nil) {
        skipped = [NSMutableSet set];
        objc_setAssociatedObject(controller,
                                 YTzoomSponsorSkippedAssociation,
                                 skipped,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, BOOL *stop) {
            double start = [segment[@"start"] doubleValue];
            double end = [segment[@"end"] doubleValue];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            NSInteger behavior = YTzoomSponsorCategoryBehavior(category);
            if (behavior == 2 || behavior == 3) return;
            NSNumber *token = @(index);
            if (time < start - 1.0) {
                [skipped removeObject:token];
            }
            if (time >= start && time < end - 0.25 && ![skipped containsObject:token]) {
                [skipped addObject:token];
                if (behavior == 1) {
                    YTzoomAskToSkipSponsor(controller, start, end, category);
                } else {
                    YTzoomPerformSponsorSkip(controller, start, end, category);
                }
                *stop = YES;
            }
        }];
}

static __weak id YTzoomLastPlayerController;

void YTzoomPauseYouTubePlayer(void) {
    id controller = YTzoomLastPlayerController;
    SEL pause = NSSelectorFromString(@"pause");
    if ([controller respondsToSelector:pause]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, pause);
    }
}

static void YTzoomDidActivateVideo(id receiver,
                                   SEL selector,
                                   id playbackController,
                                   id video,
                                   id playbackData) {
    if (OriginalDidActivateVideo != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalDidActivateVideo)(
            receiver, selector, playbackController, video, playbackData
        );
    }

    YTzoomOpenPausedVideoActivated(receiver);
    YTzoomLastPlayerController = receiver;

    if (!YTzoomSponsorBlockEnabled()) {
        objc_setAssociatedObject(receiver,
                                 YTzoomSponsorSegmentsAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    NSString *videoID =
        YTzoomVideoIDFromObject(receiver) ?:
        YTzoomVideoIDFromObject(video) ?:
        YTzoomVideoIDFromObject(playbackData);
    if (videoID.length == 0) {
        return;
    }

    objc_setAssociatedObject(receiver,
                             YTzoomSponsorVideoAssociation,
                             videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTzoomSponsorSegmentsAssociation,
                             @[],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTzoomSponsorSkippedAssociation,
                             [NSMutableSet set],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomCurrentSponsorController = receiver;

    __weak id weakReceiver = receiver;
    [YTzoomSponsorClient.sharedClient segmentsForVideoID:videoID
                                             completion:^(NSArray *segments) {
        id strongReceiver = weakReceiver;
        NSString *current =
            objc_getAssociatedObject(strongReceiver, YTzoomSponsorVideoAssociation);
        if (strongReceiver == nil || ![current isEqualToString:videoID]) {
            return;
        }
        objc_setAssociatedObject(strongReceiver,
                                 YTzoomSponsorSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        for (UIView *bar in YTzoomSponsorBars.allObjects) {
            [bar setNeedsLayout];
            [bar layoutIfNeeded];
        }
    }];
}

static void YTzoomSingleVideoTimeChanged(id receiver,
                                         SEL selector,
                                         id video,
                                         double time) {
    if (OriginalSingleVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalSingleVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = YTzoomDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (YTzoomSponsorTimeUpdatesEnabled) {
        YTzoomEvaluateSponsorTime(receiver, resolved);
    }
    YTzoomPublishPlaybackTime(receiver, resolved);
}

static void YTzoomMutatedVideoTimeChanged(id receiver,
                                          SEL selector,
                                          id video,
                                          double time) {
    if (OriginalMutatedVideoTimeChanged != NULL) {
        ((void (*)(id, SEL, id, double))OriginalMutatedVideoTimeChanged)(
            receiver, selector, video, time
        );
    }
    double current = YTzoomDoubleMessage(receiver, @[@"currentVideoMediaTime"]);
    double resolved = current > 0.0 ? current : time;
    if (YTzoomSponsorTimeUpdatesEnabled) {
        YTzoomEvaluateSponsorTime(receiver, resolved);
    }
    YTzoomPublishPlaybackTime(receiver, resolved);
}

static BOOL YTzoomTrackGeometry(UIView *target, CGFloat *thickness,
                                CGFloat *offset) {
    CGFloat width = CGRectGetWidth(target.bounds);
    if (width <= 0.0) return NO;
    CGFloat bestWidth = 0.0;
    CGFloat bestHeight = 0.0;
    CGFloat bestY = 0.0;
    BOOL found = NO;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:target];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 60) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (node != target && !node.hidden && node.alpha > 0.05) {
            CGRect frame = [node convertRect:node.bounds toView:target];
            CGFloat nodeWidth = CGRectGetWidth(frame);
            CGFloat nodeHeight = CGRectGetHeight(frame);
            if (nodeWidth >= width * 0.55 && nodeHeight > 0.5 && nodeHeight <= 16.0) {
                BOOL better = !found;
                if (!better && nodeWidth > bestWidth + 2.0) better = YES;
                else if (!better && nodeWidth >= bestWidth - 2.0) {
                    if (CGRectGetMinY(frame) > bestY + 0.5) better = YES;
                    else if (fabs(CGRectGetMinY(frame) - bestY) <= 0.5 &&
                             nodeHeight > bestHeight) better = YES;
                }
                if (better) {
                    bestWidth = nodeWidth;
                    bestHeight = nodeHeight;
                    bestY = CGRectGetMinY(frame);
                    found = YES;
                }
            }
        }
        [pending addObjectsFromArray:node.subviews];
    }
    if (!found) return NO;
    *thickness = bestHeight;
    *offset = bestY;
    return YES;
}

static void YTzoomRenderSponsorMarkers(UIView *receiver, UIView *target,
                                       BOOL fullHeight) {
    CAShapeLayer *container =
        objc_getAssociatedObject(receiver, YTzoomSponsorMarkerAssociation);
    if (container == nil) {
        container = [CAShapeLayer layer];
        container.name = @"YTzoomSponsorMarkers";
        objc_setAssociatedObject(receiver,
                                 YTzoomSponsorMarkerAssociation,
                                 container,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL reattached = NO;
    if (container.superlayer != target.layer) {
        [container removeFromSuperlayer];
        [target.layer addSublayer:container];
        reattached = YES;
    }
    container.frame = target.bounds;
    container.zPosition = 10000.0;

    id controller = YTzoomCurrentSponsorController;
    NSArray<NSDictionary<NSString *, id> *> *segments =
        objc_getAssociatedObject(controller, YTzoomSponsorSegmentsAssociation);
    double duration = YTzoomDoubleMessage(
        controller,
        @[@"currentVideoTotalMediaTime", @"currentVideoTotalTime",
          @"currentVideoDuration", @"totalMediaTime"]
    );
    BOOL enabled = YTzoomSponsorBlockEnabled() && duration > 0.0 && segments.count != 0;
    container.hidden = !enabled;
    if (!enabled) return;

    CGFloat width = CGRectGetWidth(target.bounds);
    CGFloat height = CGRectGetHeight(target.bounds);
    NSArray *renderedSegments = objc_getAssociatedObject(
        receiver, YTzoomSponsorRenderedSegmentsAssociation);
    BOOL rebuild = renderedSegments != segments || container.sublayers.count != segments.count;
    if (rebuild) {
        [container.sublayers makeObjectsPerformSelector:@selector(removeFromSuperlayer)];
        for (NSDictionary<NSString *, id> *segment in segments) {
            CALayer *marker = [CALayer layer];
            NSString *category = [segment[@"category"] isKindOfClass:NSString.class]
                ? segment[@"category"] : @"sponsor";
            marker.backgroundColor = YTzoomSponsorCategoryColor(category).CGColor;
            marker.zPosition = 1.0;
            [container addSublayer:marker];
        }
        objc_setAssociatedObject(receiver,
                                 YTzoomSponsorRenderedSegmentsAssociation,
                                 segments,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat trackThickness = 2.0;
    CGFloat trackOffset = MAX(0.0, height - 2.0);
    if (!fullHeight) {
        CGFloat measured = 0.0;
        CGFloat measuredOffset = 0.0;
        if (YTzoomTrackGeometry(target, &measured, &measuredOffset)) {
            trackThickness = measured;
            trackOffset = measuredOffset;
        }
    }
    CGRect previousBounds = [objc_getAssociatedObject(
        receiver, YTzoomSponsorMarkerBoundsAssociation) CGRectValue];
    double previousDuration = [objc_getAssociatedObject(
        receiver, YTzoomSponsorMarkerDurationAssociation) doubleValue];
    CGRect signature = CGRectMake(CGRectGetWidth(target.bounds),
                                  CGRectGetHeight(target.bounds),
                                  trackThickness, trackOffset);
    if (!rebuild && !reattached && CGRectEqualToRect(previousBounds, signature) &&
        fabs(previousDuration - duration) < 0.001) return;
    objc_setAssociatedObject(receiver,
                             YTzoomSponsorMarkerBoundsAssociation,
                             [NSValue valueWithCGRect:signature],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(receiver,
                             YTzoomSponsorMarkerDurationAssociation,
                             @(duration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [segments enumerateObjectsUsingBlock:
        ^(NSDictionary<NSString *, id> *segment, NSUInteger index, __unused BOOL *stop) {
        double start = [segment[@"start"] doubleValue];
        double end = MIN([segment[@"end"] doubleValue], duration);
        CALayer *marker = container.sublayers[index];
        marker.hidden = end <= start;
        if (marker.hidden) return;
        CGFloat markerHeight = fullHeight ? MAX(height, 1.0) : trackThickness;
        marker.frame = CGRectMake((CGFloat)(start / duration) * width,
                                  fullHeight ? 0.0 : trackOffset,
                                  MAX(1.0, (CGFloat)((end - start) / duration) * width),
                                  markerHeight);
    }];
    [CATransaction commit];
}

static void YTzoomPlayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPlayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPlayerBarLayout)(receiver, selector);
    }

    YTzoomConfigureTapToSeek(receiver);

    [YTzoomSponsorBars addObject:receiver];
    UIView *target = receiver;
    for (UIView *subview in receiver.subviews) {
        if ([NSStringFromClass(subview.class) isEqualToString:@"YTModularPlayerBarView"]) {
            target = subview;
            break;
        }
    }
    YTzoomRenderSponsorMarkers(receiver, target, NO);
}

static void YTzoomMiniplayerBarLayout(UIView *receiver, SEL selector) {
    if (OriginalMiniplayerBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalMiniplayerBarLayout)(receiver, selector);
    }
    [YTzoomSponsorBars addObject:receiver];
    YTzoomApplyProgressStyleToBar(receiver);
    YTzoomRenderSponsorMarkers(receiver, receiver, YES);
}

void YTzoomInstallSponsorBlockHooks(void) {
    if (YTzoomSponsorBars == nil) {
        YTzoomSponsorBars = [NSHashTable weakObjectsHashTable];
    }
    YTzoomRefreshPlaybackTimePreferenceState();
    if (YTzoomPlaybackPreferenceObserver == nil) {
        YTzoomPlaybackPreferenceObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:YTzoomPreferencesDidChangeNotification
            object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                YTzoomRefreshPlaybackTimePreferenceState();
            }];
    }
    YTzoomInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didActivateVideo:withPlaybackData:",
                              (IMP)YTzoomDidActivateVideo,
                              &OriginalDidActivateVideo);
    YTzoomInstallInstanceHook(@"YTPlayerViewController",
                              @"singleVideo:currentVideoTimeDidChange:",
                              (IMP)YTzoomSingleVideoTimeChanged,
                              &OriginalSingleVideoTimeChanged);
    YTzoomInstallInstanceHook(@"YTPlayerViewController",
                              @"potentiallyMutatedSingleVideo:currentVideoTimeDidChange:",
                              (IMP)YTzoomMutatedVideoTimeChanged,
                              &OriginalMutatedVideoTimeChanged);
    YTzoomInstallInstanceHook(@"YTInlinePlayerBarContainerView",
                              @"layoutSubviews",
                              (IMP)YTzoomPlayerBarLayout,
                              &OriginalPlayerBarLayout);
    YTzoomInstallInstanceHook(@"YTWatchFloatingMiniplayerProgressBarView",
                              @"layoutSubviews",
                              (IMP)YTzoomMiniplayerBarLayout,
                              &OriginalMiniplayerBarLayout);
}
