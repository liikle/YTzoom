#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/OverlayButtonHost.h"

#import <objc/message.h>
#import "../Downloads/DownloadLog.h"
#import <objc/runtime.h>
#import <math.h>

static const void *YTzoomOverlayHiddenAssociation = &YTzoomOverlayHiddenAssociation;
static const void *YTzoomOverlayForcedAssociation = &YTzoomOverlayForcedAssociation;
static const void *YTzoomOverlayEnabledAssociation = &YTzoomOverlayEnabledAssociation;
static const void *YTzoomOverlayTransformAssociation = &YTzoomOverlayTransformAssociation;
static const void *YTzoomDoubleTapAssociation = &YTzoomDoubleTapAssociation;
static const void *YTzoomPrevNextParentAssociation = &YTzoomPrevNextParentAssociation;
static const void *YTzoomProductHiddenAssociation = &YTzoomProductHiddenAssociation;
static IMP OriginalVideoOverlayLayout;
static IMP OriginalForceHidePreviousNext;
static IMP OriginalPreviousButtonShouldHide;
static IMP OriginalNextButtonShouldHide;
static IMP OriginalRemoveNextPaddle;
static IMP OriginalRemovePreviousPaddle;
static IMP OriginalDidUpdatePlayerOverlayContent;
static IMP OriginalHasProductsInVideoOverlay;
static IMP OriginalProductsInVideoOverlay;
static IMP OriginalProductPillOverlayDidAddSubview;
static IMP OriginalProductPillControlsDidAddSubview;
static IMP OriginalTimelyShelfDidInsert;
static IMP OriginalTimelyShelfDidUpdate;
static IMP OriginalUpdateTimelyShelfOverlay;
static IMP OriginalUpdateTimelyShelfState;
static IMP OriginalUpdateTimelyShelfStateWith;
static IMP OriginalTimelyShelfFrame;
static IMP OriginalTimelyShelfHeightVC;
static IMP OriginalTimelyShelfHeightBar;
static IMP OriginalTimelyShelfHeightInput;

static NSUInteger YTzoomProductHiddenCount = 0;

static void YTzoomSweepProductViews(UIView *root, BOOL hide);
static void YTzoomApplyProductVisibility(UIView *root);

static BOOL YTzoomOverlayPreference(NSString *key) {
    return YTzoomFeatureEnabled(key);
}

static NSString *YTzoomOverlayToken(UIView *view) {
    return [[NSString stringWithFormat:@"%@ %@ %@",
             NSStringFromClass(view.class),
             view.accessibilityIdentifier ?: @"",
             view.accessibilityLabel ?: @""] lowercaseString];
}

static BOOL YTzoomOverlayTokenMatches(NSString *token,
                                      NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *YTzoomPreviousNextTokens(void) {
    return @[
        @"id.player.previous.button", @"id.player.next.button",
        @"previous.button", @"next.button",
        @"previousbutton", @"nextbutton", @"previous_button", @"next_button",
        @"previous button", @"next button", @"skipprevious", @"skipnext",
        @"replaynextbutton", @"replay_next_button"
    ];
}

static void YTzoomSetPreviousNextContainerEnabled(UIView *view, BOOL enabled) {
    if (view == nil) return;
    NSDictionary *baseline = objc_getAssociatedObject(view,
                                                       YTzoomPrevNextParentAssociation);
    if (!enabled) {
        if (baseline == nil) {
            baseline = @{@"interaction": @(view.userInteractionEnabled),
                         @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view, YTzoomPrevNextParentAssociation,
                                     baseline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.userInteractionEnabled = NO;
        view.alpha = 0.35;
    } else if (baseline != nil) {
        view.userInteractionEnabled = [baseline[@"interaction"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view, YTzoomPrevNextParentAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTzoomSetControlTreeEnabled(UIView *view, BOOL enabled) {
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        control.enabled = enabled;
        control.userInteractionEnabled = enabled;
        control.alpha = enabled ? 1.0 : 0.35;
    }
    for (UIView *subview in view.subviews) {
        YTzoomSetControlTreeEnabled(subview, enabled);
    }
}

static void YTzoomSetOverlayHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"YTzoom"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        YTzoomOverlayHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     YTzoomOverlayHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 YTzoomOverlayHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTzoomIsDarkOverlayView(UIView *view) {
    UIView *root = view.superview;
    if (view.class != UIView.class ||
        ![NSStringFromClass(root.class)
            isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
        fabs(CGRectGetWidth(view.bounds) - CGRectGetWidth(root.bounds)) >= 2.0 ||
        fabs(CGRectGetHeight(view.bounds) - CGRectGetHeight(root.bounds)) >= 2.0) {
        return NO;
    }
    NSUInteger index = [root.subviews indexOfObjectIdenticalTo:view];
    if (index == NSNotFound || index + 1 >= root.subviews.count) return NO;
    return [NSStringFromClass(root.subviews[index + 1].class)
        isEqualToString:@"YTMainAppVideoOverlayAccessibilityGlassContainerView"];
}

static BOOL YTzoomMatchesAncestorButton(UIView *view, NSString *accessor) {
    SEL selector = NSSelectorFromString(accessor);
    for (UIView *ancestor = view.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if (![ancestor respondsToSelector:selector]) continue;
        UIView *button = ((id (*)(id, SEL))objc_msgSend)(ancestor, selector);
        if (![button isKindOfClass:UIView.class]) return NO;
        return button == view || [view isDescendantOfView:button];
    }
    return NO;
}

static BOOL YTzoomOverlayShouldHide(UIView *view) {
    NSString *token = YTzoomOverlayToken(view);
    if (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.DimmingRemoved") &&
        YTzoomIsDarkOverlayView(view)) {
        return YES;
    }
    if (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.QuickActionsHidden") &&
        YTzoomOverlayTokenMatches(token, @[
            @"quickaction", @"quick_action", @"actionbar", @"action_bar"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ContinueWatchingDisabled") &&
        YTzoomOverlayTokenMatches(token, @[
            @"continuewatching", @"continue_watching"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.RelatedVideosHidden") &&
        YTzoomOverlayTokenMatches(token, @[
            @"relatedvideo", @"related_video", @"morevideos", @"more_videos"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.AutoplayHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"autoplay", @"autonav"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CaptionsButtonHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"caption", @"subtitle", @"closedcaption"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CastHidden") &&
        (YTzoomOverlayTokenMatches(token, @[@"cast", @"airplay", @"routebutton"]) ||
         YTzoomMatchesAncestorButton(view, @"playbackRouteButton"))) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.WatermarkHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"watermark", @"branding"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.InfoCardsHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"infocard", @"info_card", @"cardsbutton"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.EndScreenHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"endscreen", @"end_screen"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PlayPauseHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"playpause", @"play_pause"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.MoreButtonHidden") &&
        YTzoomOverlayTokenMatches(token, @[@"overflowbutton", @"settingsbutton", @"morebutton"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden") &&
        YTzoomOverlayTokenMatches(token, YTzoomPreviousNextTokens())) {
        return YES;
    }
    return NO;
}

static id YTzoomProductOverlayModelValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTzoomProductOverlayBoolValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return NO;
    @try {
        return [[object valueForKey:key] boolValue];
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL YTzoomIsProductOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_product_in_video"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"product"]) {
        return YES;
    }
    return NO;
}

static BOOL YTzoomIsTimelyShelfOverlayIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *token = [identifier lowercaseString];
    if ([token isEqualToString:@"player_overlay_timely_shelf"]) return YES;
    if ([token containsString:@"player_overlay"] &&
        [token containsString:@"timely_shelf"]) {
        return YES;
    }
    return NO;
}

static BOOL YTzoomProductPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    for (NSString *key in @[@"productsInVideoOverlayRenderer",
                            @"productsInVideoEntity",
                            @"productsInVideoEntityModel",
                            @"productCard",
                            @"shoppingAdInfoCardContentRenderer",
                            @"infoCardProduct"]) {
        if (YTzoomProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (YTzoomProductOverlayBoolValue(object, @"hasProductCard")) {
        return YES;
    }
    if (YTzoomProductOverlayBoolValue(
            object, @"hasShoppingAdInfoCardContentRenderer")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"productsinvideo"] ||
         [classToken containsString:@"productinvideo"] ||
         [classToken containsString:@"infocardproduct"] ||
         [classToken containsString:@"shoppingadinfocard"])) {
        return YES;
    }
    return NO;
}

static BOOL YTzoomTimelyShelfShoppingPayloadMatches(id object) {
    if (object == nil || [object isKindOfClass:UIView.class]) return NO;
    if (YTzoomProductPayloadMatches(object)) return YES;
    for (NSString *key in @[@"taggedProducts",
                            @"creatorProduct",
                            @"shoppingData"]) {
        if (YTzoomProductOverlayModelValue(object, key) != nil) return YES;
    }
    if (YTzoomProductOverlayBoolValue(object, @"hasTaggedProducts")) {
        return YES;
    }
    NSString *classToken = [NSStringFromClass([object class]) lowercaseString];
    if (classToken.length != 0 &&
        ([classToken containsString:@"shopping"] ||
         [classToken containsString:@"taggedproduct"] ||
         [classToken containsString:@"creatorproduct"] ||
         [classToken containsString:@"merchandise"])) {
        return YES;
    }
    for (NSString *key in @[@"overlayIdentifier", @"elementIdentifier"]) {
        id raw = YTzoomProductOverlayModelValue(object, key);
        if ([raw isKindOfClass:NSString.class] &&
            [[raw lowercaseString] containsString:@"shopping"]) {
            return YES;
        }
    }
    return NO;
}

BOOL YTzoomProductOverlayMatches(id overlay) {
    if (overlay == nil) return NO;
    NSString *identifier =
        YTzoomProductOverlayModelValue(overlay, @"overlayIdentifier");
    if ([identifier isKindOfClass:NSString.class] &&
        YTzoomIsProductOverlayIdentifier(identifier)) {
        return YES;
    }
    if (YTzoomProductPayloadMatches(overlay)) return YES;
    id renderer = YTzoomProductOverlayModelValue(overlay, @"renderer");
    if (renderer == overlay) renderer = nil;
    NSString *rendererIdentifier = nil;
    if (renderer != nil) {
        rendererIdentifier =
            YTzoomProductOverlayModelValue(renderer, @"overlayIdentifier");
        if ([rendererIdentifier isKindOfClass:NSString.class] &&
            YTzoomIsProductOverlayIdentifier(rendererIdentifier)) {
            return YES;
        }
        if (YTzoomProductPayloadMatches(renderer)) return YES;
    }
    BOOL timely =
        ([identifier isKindOfClass:NSString.class] &&
         YTzoomIsTimelyShelfOverlayIdentifier(identifier)) ||
        ([rendererIdentifier isKindOfClass:NSString.class] &&
         YTzoomIsTimelyShelfOverlayIdentifier(rendererIdentifier));
    if (timely &&
        (YTzoomTimelyShelfShoppingPayloadMatches(overlay) ||
         (renderer != nil && YTzoomTimelyShelfShoppingPayloadMatches(renderer)))) {
        return YES;
    }
    return NO;
}

static BOOL YTzoomShouldDropProductOverlay(id overlay) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        YTzoomProductOverlayMatches(overlay);
}

static void YTzoomForwardProductOverlay(id receiver, SEL selector,
                                         id provider, id overlay,
                                         IMP original) {
    if (YTzoomShouldDropProductOverlay(overlay)) return;
    if (original != NULL) {
        ((void (*)(id, SEL, id, id))original)(
            receiver, selector, provider, overlay);
    }
}

static void YTzoomProductPillDidAddSubviewHook(UIView *receiver, SEL selector,
                                                UIView *subview) {
    static Class controlsClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controlsClass = NSClassFromString(@"YTMainAppControlsOverlayView");
    });
    IMP original = (controlsClass != Nil &&
                    [receiver isKindOfClass:controlsClass])
        ? OriginalProductPillControlsDidAddSubview
        : OriginalProductPillOverlayDidAddSubview;
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, subview);
    }
    YTzoomApplyProductVisibility(subview);
}

static NSArray<NSString *> *YTzoomProductPillTokens(void) {
    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[
            @"product_in_video", @"products_in_video",
            @"tagged_product", @"creator_product",
            @"shopping", @"merchandise",
            @"products", @"tagged"
        ];
    });
    return tokens;
}

static BOOL YTzoomProductTokenHasBareProduct(NSString *token) {
    if ([token containsString:@"product"] == NO) return NO;
    for (NSString *exclusion in @[@"production", @"producer",
                                  @"productivity"]) {
        if ([token containsString:exclusion]) return NO;
    }
    return YES;
}

static BOOL YTzoomViewLooksLikeProductPill(UIView *view) {
    if (view == nil) return NO;
    NSString *token = YTzoomOverlayToken(view);
    return YTzoomOverlayTokenMatches(token, YTzoomProductPillTokens()) ||
        YTzoomProductTokenHasBareProduct(token);
}

static void YTzoomProductHiddenCounted(UIView *view, BOOL willHide) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, YTzoomProductHiddenAssociation);
    if (willHide) {
        if (baseline == nil && !view.hidden) YTzoomProductHiddenCount++;
    } else if (baseline != nil) {
        if (YTzoomProductHiddenCount > 0) YTzoomProductHiddenCount--;
    }
}

static BOOL YTzoomProductTokenInString(NSString *string) {
    if (string.length == 0) return NO;
    NSString *token = [string lowercaseString];
    return YTzoomOverlayTokenMatches(token, YTzoomProductPillTokens()) ||
        YTzoomProductTokenHasBareProduct(token);
}

static void YTzoomProductSetHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityIdentifier hasPrefix:@"YTzoom"]) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        view,
        YTzoomProductHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     YTzoomProductHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 YTzoomProductHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static UIView *YTzoomFindForeignTextExcept(UIView *view, UIView *skip,
                                               NSUInteger depth) {
    if (view == nil || view == skip || depth > 4) return nil;
    if (view.hidden) return nil;
    if (depth == 0) {
        if (!YTzoomProductTokenInString(view.accessibilityLabel) &&
            view.accessibilityLabel.length > 1) {
            return view;
        }
    } else {
        if (YTzoomProductTokenInString(view.accessibilityLabel)) {
            return nil;
        }
        if (view.accessibilityLabel.length > 1) return view;
    }
    if (depth > 0) {
        if ([view isKindOfClass:UILabel.class]) {
            if (!YTzoomProductTokenInString(((UILabel *)view).text) &&
                ((UILabel *)view).text.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIButton.class]) {
            UIButton *button = (UIButton *)view;
            if (!YTzoomProductTokenInString(button.currentTitle) &&
                button.currentTitle.length > 1) {
                return view;
            }
            if (!YTzoomProductTokenInString(button.accessibilityIdentifier) &&
                button.accessibilityIdentifier.length > 1) {
                return view;
            }
        } else if ([view isKindOfClass:UIControl.class]) {
            if (!YTzoomProductTokenInString(view.accessibilityIdentifier) &&
                view.accessibilityIdentifier.length > 1) {
                return view;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        UIView *found = YTzoomFindForeignTextExcept(subview, skip, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static void YTzoomHideProductPill(UIView *pill, BOOL hide) {
    YTzoomProductHiddenCounted(pill, hide);
    YTzoomProductSetHidden(pill, hide);
    if (!hide) return;
    UIView *child = pill;
    for (NSUInteger level = 0; level < 4; level++) {
        UIView *parent = child.superview;
        if (parent == nil || parent == child) break;
        NSString *parentClass = NSStringFromClass(parent.class);
        if ([parentClass containsString:@"VideoPlayerOverlay"] ||
            [parentClass containsString:@"ControlsOverlay"]) {
            break;
        }
        CGFloat h = CGRectGetHeight(parent.bounds);
        if (h <= 0.5 || h > 320.0) {
            if (!YTzoomViewLooksLikeProductPill(parent)) break;
        }
        if (YTzoomFindForeignTextExcept(parent, child, 0) != nil) break;
        YTzoomProductHiddenCounted(parent, YES);
        YTzoomProductSetHidden(parent, YES);
        child = parent;
    }
    if (child.superview != nil) {
        [child.superview setNeedsLayout];
    }
}

static void YTzoomSetOverlayForcedVisible(UIView *view, BOOL forced) {
    NSDictionary *baseline = objc_getAssociatedObject(
        view,
        YTzoomOverlayForcedAssociation
    );
    if (forced) {
        if (baseline == nil) {
            baseline = @{@"hidden": @(view.hidden), @"alpha": @(view.alpha)};
            objc_setAssociatedObject(view,
                                     YTzoomOverlayForcedAssociation,
                                     baseline,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = NO;
        view.alpha = 1.0;
    } else if (baseline != nil) {
        view.hidden = [baseline[@"hidden"] boolValue];
        view.alpha = [baseline[@"alpha"] doubleValue];
        objc_setAssociatedObject(view,
                                 YTzoomOverlayForcedAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTzoomApplyOverlayBehavior(UIView *view) {
    NSString *token = YTzoomOverlayToken(view);
    BOOL playPause = YTzoomOverlayTokenMatches(token, @[
        @"playpause", @"play_pause", @"playbackbutton"
    ]);
    BOOL progress = YTzoomOverlayTokenMatches(token, @[
        @"progress", @"scrubber", @"playerbar", @"player_bar"
    ]);
    BOOL control = [view isKindOfClass:UIControl.class] ||
        YTzoomOverlayTokenMatches(token, @[@"control", @"button"]);
    BOOL force = (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.AlwaysShowPlayPause") && playPause) ||
        (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.AlwaysShowControls") && control) ||
        (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProgressAlwaysVisible") && progress);
    YTzoomSetOverlayForcedVisible(view, force);

    BOOL previousNext = YTzoomOverlayTokenMatches(
        token, YTzoomPreviousNextTokens());
    BOOL disablePreviousNext = YTzoomOverlayPreference(
        @"YTzoom.Preference.Overlay.PreviousNextDisabled");
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *controlView = (UIControl *)view;
        NSNumber *baseline = objc_getAssociatedObject(
            view,
            YTzoomOverlayEnabledAssociation
        );
        if (disablePreviousNext && previousNext) {
            if (baseline == nil) {
                objc_setAssociatedObject(view,
                                         YTzoomOverlayEnabledAssociation,
                                         @(controlView.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            controlView.enabled = NO;
            controlView.alpha = 0.35;
        } else if (baseline != nil) {
            controlView.enabled = baseline.boolValue;
            controlView.alpha = 1.0;
            objc_setAssociatedObject(view,
                                     YTzoomOverlayEnabledAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (previousNext) {
        UIView *container = view.superview;
        if ([NSStringFromClass(container.class)
                containsString:@"TransportControlsButtonView"]) {
            YTzoomSetPreviousNextContainerEnabled(container,
                                                   !disablePreviousNext);
        }
    }

    NSValue *transform = objc_getAssociatedObject(
        view,
        YTzoomOverlayTransformAssociation
    );
    if (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.CompactPreviousNext") && previousNext) {
        if (transform == nil) {
            objc_setAssociatedObject(view,
                                     YTzoomOverlayTransformAssociation,
                                     [NSValue valueWithCGAffineTransform:view.transform],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.transform = CGAffineTransformScale(
            transform != nil ? transform.CGAffineTransformValue : view.transform,
            0.78,
            0.78
        );
    } else if (transform != nil) {
        view.transform = transform.CGAffineTransformValue;
        objc_setAssociatedObject(view,
                                 YTzoomOverlayTransformAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        if (![recognizer isKindOfClass:UITapGestureRecognizer.class] ||
            ((UITapGestureRecognizer *)recognizer).numberOfTapsRequired < 2) {
            continue;
        }
        NSNumber *baseline = objc_getAssociatedObject(
            recognizer,
            YTzoomDoubleTapAssociation
        );
        if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.DoubleTapDisabled")) {
            if (baseline == nil) {
                objc_setAssociatedObject(recognizer,
                                         YTzoomDoubleTapAssociation,
                                         @(recognizer.enabled),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            recognizer.enabled = NO;
        } else if (baseline != nil) {
            recognizer.enabled = baseline.boolValue;
            objc_setAssociatedObject(recognizer,
                                     YTzoomDoubleTapAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void YTzoomApplyOverlayTree(UIView *view) {
    YTzoomApplyOverlayBehavior(view);
    YTzoomSetOverlayHidden(view, YTzoomOverlayShouldHide(view));
    for (UIView *subview in view.subviews) {
        YTzoomApplyOverlayTree(subview);
    }
}

static void YTzoomApplyOverlaySelectors(id overlay) {
    NSDictionary<NSString *, NSString *> *selectors = @{
        @"autoplaySwitch": @"YTzoom.Preference.Overlay.AutoplayHidden",
        @"autoplayButton": @"YTzoom.Preference.Overlay.AutoplayHidden",
        @"captionsButton": @"YTzoom.Preference.Overlay.CaptionsButtonHidden",
        @"closedCaptionsButton": @"YTzoom.Preference.Overlay.CaptionsButtonHidden",
        @"castButton": @"YTzoom.Preference.Overlay.CastHidden",
        @"playbackRouteButton": @"YTzoom.Preference.Overlay.CastHidden",
        @"closedCaptionsOrSubtitlesButton": @"YTzoom.Preference.Overlay.CaptionsButtonHidden",
        @"infoCardButton": @"YTzoom.Preference.Overlay.InfoCardsHidden",
        @"watermarkView": @"YTzoom.Preference.Overlay.WatermarkHidden",
        @"endscreenView": @"YTzoom.Preference.Overlay.EndScreenHidden",
        @"playPauseButton": @"YTzoom.Preference.Overlay.PlayPauseHidden",
        @"previousButton": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"nextButton": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"previousButtonView": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"nextButtonView": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"minimizedPanelPreviousButton": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"minimizedPanelNextButton": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"replayNextButton": @"YTzoom.Preference.Overlay.PreviousNextHidden",
        @"overflowButton": @"YTzoom.Preference.Overlay.MoreButtonHidden",
        @"settingsButton": @"YTzoom.Preference.Overlay.MoreButtonHidden"
    };
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if (![overlay respondsToSelector:selector]) {
            continue;
        }
        id value = ((id (*)(id, SEL))objc_msgSend)(overlay, selector);
        if ([value isKindOfClass:UIView.class]) {
            YTzoomSetOverlayHidden(value,
                                   YTzoomFeatureEnabled(selectors[name]));
            if ([name.lowercaseString containsString:@"previous"] ||
                [name.lowercaseString containsString:@"next"]) {
                BOOL disabled = YTzoomOverlayPreference(
                    @"YTzoom.Preference.Overlay.PreviousNextDisabled");
                YTzoomSetControlTreeEnabled(value, !disabled);
            }
        }
    }
}

static void YTzoomSweepProductViews(UIView *root, BOOL hide) {
    if (root == nil) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count != 0) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.hidden &&
            objc_getAssociatedObject(view,
                                     YTzoomProductHiddenAssociation) != nil) {
            if (!hide) {
                YTzoomProductHiddenCounted(view, NO);
                YTzoomProductSetHidden(view, NO);
            } else {
                continue;
            }
        }
        if (hide && YTzoomViewLooksLikeProductPill(view)) {
            YTzoomHideProductPill(view, YES);
            continue;
        }
        if (!hide &&
            objc_getAssociatedObject(view,
                                     YTzoomProductHiddenAssociation) != nil) {
            YTzoomProductHiddenCounted(view, NO);
            YTzoomProductSetHidden(view, NO);
        }
        [stack addObjectsFromArray:view.subviews];
    }
}

static void YTzoomApplyProductVisibility(UIView *root) {
    if (root == nil) return;
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) {
        YTzoomSweepProductViews(root, YES);
    } else if (YTzoomProductHiddenCount > 0) {
        YTzoomSweepProductViews(root, NO);
        if (YTzoomProductHiddenCount > 0) {
            YTzoomProductHiddenCount = 0;
        }
    }
}

BOOL YTzoomProductIdentifierMatches(NSString *identifier) {
    if (identifier.length == 0) return NO;
    return YTzoomProductTokenInString(identifier);
}

BOOL YTzoomViewIsInsidePlayerOverlay(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *node = view; node != nil && depth < 12;
         node = node.superview, depth++) {
        NSString *className = NSStringFromClass(node.class);
        if ([className isEqualToString:@"YTMainAppVideoPlayerOverlayView"] ||
            [className isEqualToString:@"YTMainAppControlsOverlayView"]) {
            return YES;
        }
    }
    return NO;
}

void YTzoomHideProductSubtree(UIView *root) {
    if (root == nil || !YTzoomViewIsInsidePlayerOverlay(root)) return;
    YTzoomSweepProductViews(root, YES);
}

static void YTzoomVideoOverlayLayout(UIView *receiver, SEL selector) {
    if (OriginalVideoOverlayLayout != NULL) {
        ((void (*)(id, SEL))OriginalVideoOverlayLayout)(receiver, selector);
    }
    YTzoomApplyOverlaySelectors(receiver);
    YTzoomApplyProductVisibility(receiver);
    if (YTzoomOverlayPreference(@"YTzoom.Preference.Overlay.DimmingRemoved")) {
        for (UIView *subview in receiver.subviews) {
            if (YTzoomIsDarkOverlayView(subview)) {
                YTzoomSetOverlayHidden(subview, YES);
            }
        }
    }
}

static void YTzoomDidUpdatePlayerOverlayContent(id receiver, SEL selector,
                                                 id provider, id overlay) {
    YTzoomForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalDidUpdatePlayerOverlayContent);
}

static BOOL YTzoomHasProductsInVideoOverlay(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) return NO;
    return OriginalHasProductsInVideoOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasProductsInVideoOverlay)(receiver, selector);
}

static id YTzoomProductsInVideoOverlay(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) return nil;
    return OriginalProductsInVideoOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalProductsInVideoOverlay)(receiver, selector);
}

static void YTzoomTimelyShelfDidInsert(id receiver, SEL selector,
                                         id provider, id overlay) {
    YTzoomForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidInsert);
}

static void YTzoomTimelyShelfDidUpdate(id receiver, SEL selector,
                                        id provider, id overlay) {
    YTzoomForwardProductOverlay(receiver, selector, provider, overlay,
                                 OriginalTimelyShelfDidUpdate);
}

static void YTzoomUpdateTimelyShelfOverlay(id receiver, SEL selector,
                                            id overlay) {
    if (YTzoomShouldDropProductOverlay(overlay)) {
        return;
    }
    if (OriginalUpdateTimelyShelfOverlay != NULL) {
        ((void (*)(id, SEL, id))OriginalUpdateTimelyShelfOverlay)(
            receiver, selector, overlay);
    }
}

static void YTzoomUpdateTimelyShelfState(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) {
        return;
    }
    if (OriginalUpdateTimelyShelfState != NULL) {
        ((void (*)(id, SEL))OriginalUpdateTimelyShelfState)(
            receiver, selector);
    }
}

static void YTzoomUpdateTimelyShelfStateWith(id receiver, SEL selector,
                                              NSInteger state) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) {
        return;
    }
    if (OriginalUpdateTimelyShelfStateWith != NULL) {
        ((void (*)(id, SEL, NSInteger))OriginalUpdateTimelyShelfStateWith)(
            receiver, selector, state);
    }
}

static void YTzoomTimelyShelfFrame(id receiver, SEL selector,
                                    id shelf, CGRect overlayBounds) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) {
        if ([shelf isKindOfClass:UIView.class]) {
            UIView *shelfView = (UIView *)shelf;
            YTzoomProductHiddenCounted(shelfView, YES);
            YTzoomProductSetHidden(shelfView, YES);
            shelfView.frame = CGRectZero;
            [shelfView.superview setNeedsLayout];
        }
        return;
    }
    if (OriginalTimelyShelfFrame != NULL) {
        ((void (*)(id, SEL, id, CGRect))OriginalTimelyShelfFrame)(
            receiver, selector, shelf, overlayBounds);
    }
}

static CGFloat YTzoomTimelyShelfHeightHook(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden")) {
        return 0.0;
    }
    static Class barClass;
    static Class inputClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        barClass = NSClassFromString(@"YTPlayerBarController");
        inputClass = NSClassFromString(@"YTPlayerBarLayoutInput");
    });
    IMP original = OriginalTimelyShelfHeightVC;
    if (barClass != Nil && [receiver isKindOfClass:barClass]) {
        original = OriginalTimelyShelfHeightBar;
    } else if (inputClass != Nil && [receiver isKindOfClass:inputClass]) {
        original = OriginalTimelyShelfHeightInput;
    }
    return original == NULL ? 0.0 :
        ((CGFloat (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTzoomForceHidePreviousNext(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalForceHidePreviousNext == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalForceHidePreviousNext)(
            receiver, selector);
}

static BOOL YTzoomPreviousButtonShouldHide(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalPreviousButtonShouldHide == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalPreviousButtonShouldHide)(
            receiver, selector);
}

static BOOL YTzoomNextButtonShouldHide(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalNextButtonShouldHide == NULL
        ? NO
        : ((BOOL (*)(id, SEL))OriginalNextButtonShouldHide)(
            receiver, selector);
}

static BOOL YTzoomRemoveNextPaddle(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalRemoveNextPaddle != NULL &&
        ((BOOL (*)(id, SEL))OriginalRemoveNextPaddle)(receiver, selector);
}

static BOOL YTzoomRemovePreviousPaddle(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PreviousNextHidden")) return YES;
    return OriginalRemovePreviousPaddle != NULL &&
        ((BOOL (*)(id, SEL))OriginalRemovePreviousPaddle)(receiver, selector);
}

static NSString *const YTzoomFullscreenActionsKey =
    @"YTzoom.Preference.Overlay.FullscreenActionsHidden";

static IMP OriginalFullscreenActionsLayout;
static IMP OriginalFullscreenEngagementLayout;
static void YTzoomApplyHidden(UIView *view, NSString *key) {
    const BOOL hidden = YTzoomFeatureEnabled(key);
    if (view.hidden != hidden) view.hidden = hidden;
}

static void YTzoomFullscreenActionsLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenActionsLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenActionsLayout)(receiver, selector);
    }
    YTzoomApplyHidden(receiver, YTzoomFullscreenActionsKey);
}

static void YTzoomFullscreenEngagementLayout(UIView *receiver, SEL selector) {
    if (OriginalFullscreenEngagementLayout != NULL) {
        ((void (*)(id, SEL))OriginalFullscreenEngagementLayout)(receiver, selector);
    }
    YTzoomApplyHidden(receiver, YTzoomFullscreenActionsKey);
}

void YTzoomInstallOverlayVisibilityHooks(void) {
    YTzoomInstallInstanceHook(@"YTFullscreenActionsView", @"layoutSubviews",
                              (IMP)YTzoomFullscreenActionsLayout,
                              &OriginalFullscreenActionsLayout);
    YTzoomInstallInstanceHook(@"YTFullscreenEngagementActionBarView",
                              @"layoutSubviews",
                              (IMP)YTzoomFullscreenEngagementLayout,
                              &OriginalFullscreenEngagementLayout);
    YTzoomRegisterOverlayConfigurator(@"visibility", ^(UIView *overlay,
                                                        UIStackView *stack) {
        for (UIView *subview in overlay.subviews) {
            if (subview != stack) {
                YTzoomApplyOverlayTree(subview);
            }
        }
        YTzoomApplyOverlaySelectors(overlay);
        YTzoomApplyProductVisibility(overlay);
    });
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"layoutSubviews",
                              (IMP)YTzoomVideoOverlayLayout,
                              &OriginalVideoOverlayLayout);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)YTzoomDidUpdatePlayerOverlayContent,
                              &OriginalDidUpdatePlayerOverlayContent);
    YTzoomInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"hasProductsInVideoOverlayRenderer",
                              (IMP)YTzoomHasProductsInVideoOverlay,
                              &OriginalHasProductsInVideoOverlay);
    YTzoomInstallInstanceHook(@"YTIPlayerOverlayRenderer",
                              @"productsInVideoOverlayRenderer",
                              (IMP)YTzoomProductsInVideoOverlay,
                              &OriginalProductsInVideoOverlay);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"didAddSubview:",
                              (IMP)YTzoomProductPillDidAddSubviewHook,
                              &OriginalProductPillOverlayDidAddSubview);
    YTzoomInstallInstanceHook(@"YTMainAppControlsOverlayView",
                              @"didAddSubview:",
                              (IMP)YTzoomProductPillDidAddSubviewHook,
                              &OriginalProductPillControlsDidAddSubview);
    YTzoomInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)YTzoomTimelyShelfDidInsert,
                              &OriginalTimelyShelfDidInsert);
    YTzoomInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"playerOverlayProvider:didUpdateContentForPlayerOverlay:",
                              (IMP)YTzoomTimelyShelfDidUpdate,
                              &OriginalTimelyShelfDidUpdate);
    YTzoomInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfOverlay:",
                              (IMP)YTzoomUpdateTimelyShelfOverlay,
                              &OriginalUpdateTimelyShelfOverlay);
    YTzoomInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfState",
                              (IMP)YTzoomUpdateTimelyShelfState,
                              &OriginalUpdateTimelyShelfState);
    YTzoomInstallInstanceHook(@"YTTimelyShelfStateManager",
                              @"updateTimelyShelfState:",
                              (IMP)YTzoomUpdateTimelyShelfStateWith,
                              &OriginalUpdateTimelyShelfStateWith);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayView",
                              @"setTimelyShelfFrame:fromOverlayBounds:",
                              (IMP)YTzoomTimelyShelfFrame,
                              &OriginalTimelyShelfFrame);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"timelyShelfHeight",
                              (IMP)YTzoomTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightVC);
    YTzoomInstallInstanceHook(@"YTPlayerBarController",
                              @"timelyShelfHeight",
                              (IMP)YTzoomTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightBar);
    YTzoomInstallInstanceHook(@"YTPlayerBarLayoutInput",
                              @"timelyShelfHeight",
                              (IMP)YTzoomTimelyShelfHeightHook,
                              &OriginalTimelyShelfHeightInput);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"forceHidePreviousAndNextButtons",
                              (IMP)YTzoomForceHidePreviousNext,
                              &OriginalForceHidePreviousNext);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"previousButtonShouldHide",
                              (IMP)YTzoomPreviousButtonShouldHide,
                              &OriginalPreviousButtonShouldHide);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"nextButtonShouldHide",
                              (IMP)YTzoomNextButtonShouldHide,
                              &OriginalNextButtonShouldHide);
    YTzoomInstallInstanceHook(@"YTColdConfig",
                              @"removeNextPaddleForSingletonVideos",
                              (IMP)YTzoomRemoveNextPaddle,
                              &OriginalRemoveNextPaddle);
    YTzoomInstallInstanceHook(@"YTColdConfig",
                              @"removePreviousPaddleForSingletonVideos",
                              (IMP)YTzoomRemovePreviousPaddle,
                              &OriginalRemovePreviousPaddle);
}
