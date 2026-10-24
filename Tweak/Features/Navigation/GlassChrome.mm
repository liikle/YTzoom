#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalTopMoveToWindow;
static IMP OriginalTopMoveToSuperview;
static IMP OriginalHeaderLayout;
static IMP OriginalMultiSearchLayout;
static IMP OriginalSettingsLayout;
static IMP OriginalSetHidesShared;
static IMP OriginalSetLeftItems;
static IMP OriginalSetRightItems;
static IMP OriginalSetLeftItem;
static IMP OriginalSetRightItem;
static IMP OriginalMultiSearchMoveToWindow;
static IMP OriginalHeaderMoveToWindow;

static const void *YTzoomTopGlassAssociation = &YTzoomTopGlassAssociation;
static const void *YTzoomSearchBoxGlassAssociation = &YTzoomSearchBoxGlassAssociation;
static const void *YTzoomSearchBarGlassAssociation = &YTzoomSearchBarGlassAssociation;
static const void *YTzoomSearchBackGlassAssociation = &YTzoomSearchBackGlassAssociation;
static const void *YTzoomHeaderGlassAssociation = &YTzoomHeaderGlassAssociation;
static const void *YTzoomHeaderTouchedAssociation = &YTzoomHeaderTouchedAssociation;
static const void *YTzoomSettingsTouchedAssociation = &YTzoomSettingsTouchedAssociation;
static const void *YTzoomPillGlassAssociation = &YTzoomPillGlassAssociation;
static const void *YTzoomLeftGlassAssociation = &YTzoomLeftGlassAssociation;
static const void *YTzoomWrapGlassAssociation = &YTzoomWrapGlassAssociation;
static const void *YTzoomSideGlassAssociation = &YTzoomSideGlassAssociation;
static const void *YTzoomSideButtonsAssociation = &YTzoomSideButtonsAssociation;




static BOOL YTzoomGlassChromeEnabled(void) {
    return YTzoomLiquidGlassAvailable() && YTzoomFeatureEnabled(@"YTzoom.Preference.Glass.TopBar");
}

static UIVisualEffectView *YTzoomChromeGlass(UIView *owner, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    if (glass != nil) return glass;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
    glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.backgroundColor = UIColor.clearColor;
    glass.clipsToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    objc_setAssociatedObject(owner, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return glass;
}

static const void *YTzoomTouchesMovedAssociation = &YTzoomTouchesMovedAssociation;


static void YTzoomRemoveChromeGlass(UIView *owner, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(owner, key);
    [glass removeFromSuperview];
}

static void YTzoomPlaceBehind(UIVisualEffectView *glass, UIView *view, CGRect frame) {
    UIView *host = view.superview;
    if (host == nil) return;
    if (glass.superview != host) {
        [glass removeFromSuperview];
        [host insertSubview:glass belowSubview:view];
    } else {
        NSUInteger glassIndex = [host.subviews indexOfObjectIdenticalTo:glass];
        NSUInteger viewIndex = [host.subviews indexOfObjectIdenticalTo:view];
        if (glassIndex == NSNotFound || viewIndex == NSNotFound || glassIndex + 1 != viewIndex) {
            [host insertSubview:glass belowSubview:view];
        }
    }
    glass.frame = frame;
    glass.layer.cornerRadius = MIN(CGRectGetHeight(frame) * 0.5, 24.0);
}

static void YTzoomCollectControls(UIView *view, NSMutableArray<UIView *> *controls) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIControl.class]) {
            [controls addObject:subview];
            continue;
        }
        YTzoomCollectControls(subview, controls);
    }
}

@interface YTzoomTapProbe : NSObject
+ (instancetype)shared;
@end

@implementation YTzoomTapProbe
+ (instancetype)shared {
    static YTzoomTapProbe *probe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ probe = [YTzoomTapProbe new]; });
    return probe;
}
- (void)forward:(UITapGestureRecognizer *)recognizer {
    UIView *glass = recognizer.view;
    UIControl *control = (UIControl *)glass.superview;
    if (![control isKindOfClass:UIControl.class] || !control.enabled) {
        return;
    }
    [control sendActionsForControlEvents:UIControlEventTouchUpInside];
}

@end

static BOOL YTzoomNativeButtons(void) {
    id value = YTzoomPreferenceObject(@"YTzoom.Preference.Glass.NativeButtons");
    return value == nil || [value boolValue];
}

static void YTzoomRestoreButtonsForKey(UIView *container, const void *key) {
    UIVisualEffectView *glass = objc_getAssociatedObject(container, key);
    if (glass.superview != container) return;
    for (UIView *subview in glass.contentView.subviews.copy) [container addSubview:subview];
}

static void YTzoomRestoreButtons(UIView *container) {
    YTzoomRestoreButtonsForKey(container, YTzoomTopGlassAssociation);
}

static void YTzoomQuietButtonsIn(UIView *view);

static CGFloat YTzoomResultsSearchHeight(UIView *container) {
    UIView *header = container.superview;
    while (header != nil && ![NSStringFromClass(header.class) isEqualToString:@"YTHeaderView"]) header = header.superview;
    if (header == nil) return 0.0;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
    NSUInteger visited = 0;
    while (queue.count != 0 && visited < 200) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        visited++;
        if ([NSStringFromClass(node.class) isEqualToString:@"YTSearchBarView"]) {
            return node.hidden || node.window == nil ? 0.0 : CGRectGetHeight(node.bounds);
        }
        [queue addObjectsFromArray:node.subviews];
    }
    return 0.0;
}

static void YTzoomApplyNativeGlass(UIView *container, const void *key) {
    UIVisualEffectView *glass = YTzoomChromeGlass(container, key);
    if (glass.superview != container) {
        [glass removeFromSuperview];
        UIVisualEffect *effect = glass.effect;
        SEL interactive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:interactive]) {
            UIVisualEffect *copy = [effect copy];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, interactive, YES);
            glass.effect = copy;
        }
        [container insertSubview:glass atIndex:0];
    }
    glass.userInteractionEnabled = YES;
    glass.clipsToBounds = NO;
    CGRect target = container.bounds;
    CGFloat compact = YTzoomResultsSearchHeight(container);
    if (compact > 20.0 && compact < CGRectGetHeight(target) - 1.0) {
        CGFloat inset = (CGRectGetHeight(target) - compact) * 0.5;
        target = CGRectInset(target, inset, inset);
    }
    for (UIView *subview in container.subviews.copy) {
        if (subview == glass) continue;
        CGRect frame = subview.frame;
        [glass.contentView addSubview:subview];
        subview.frame = frame;
    }
    glass.frame = target;
    glass.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    CGRect content = glass.contentView.bounds;
    if (!CGPointEqualToPoint(content.origin, target.origin)) {
        content.origin = target.origin;
        glass.contentView.bounds = content;
    }
    CGFloat rowHeight = CGRectGetHeight(container.bounds);
    for (UIView *subview in glass.contentView.subviews) {
        CGRect frame = subview.frame;
        CGFloat centeredY = (rowHeight - CGRectGetHeight(frame)) * 0.5;
        if (CGRectGetHeight(frame) < rowHeight && fabs(CGRectGetMinY(frame) - centeredY) > 0.5) {
            frame.origin.y = centeredY;
            subview.frame = frame;
        }
    }
    container.backgroundColor = UIColor.clearColor;
    YTzoomQuietButtonsIn(glass.contentView);
}

static void YTzoomApplyNativeTopGlass(UIView *container) {
    YTzoomApplyNativeGlass(container, YTzoomTopGlassAssociation);
}

UIView *YTzoomMakeSettingsGlass(void) {
    if (!YTzoomLiquidGlassAvailable() || !YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.Glass")) return nil;
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    glass.clipsToBounds = YES;
    glass.layer.cornerCurve = kCACornerCurveContinuous;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    return glass;
}

void YTzoomApplyTopNavigationGlass(UIView *container) {
    if (!YTzoomGlassChromeEnabled() || container.window == nil || container.superview == nil ||
        CGRectIsEmpty(container.bounds)) {
        YTzoomRestoreButtons(container);
        YTzoomRemoveChromeGlass(container, YTzoomTopGlassAssociation);
        return;
    }
    NSMutableArray<UIView *> *controls = [NSMutableArray array];
    YTzoomCollectControls(container, controls);
    CGRect area = controls.count != 0 ? container.bounds : CGRectNull;
    if (CGRectIsNull(area)) {
        YTzoomRemoveChromeGlass(container, YTzoomTopGlassAssociation);
        return;
    }
    if (YTzoomNativeButtons()) {
        YTzoomApplyNativeTopGlass(container);
        return;
    }
    area = CGRectInset(area, -6.0, -4.0);
    area = CGRectIntersection(area, container.bounds);
    CGFloat height = MAX(44.0, CGRectGetHeight(area));
    CGFloat width = MAX(height, CGRectGetWidth(area));
    CGRect local = CGRectMake(CGRectGetMidX(area) - width * 0.5, CGRectGetMidY(area) - height * 0.5,
                              width, height);
    UIVisualEffectView *glass = YTzoomChromeGlass(container, YTzoomTopGlassAssociation);
    if (CGAffineTransformIsIdentity(glass.transform)) {
        YTzoomPlaceBehind(glass, container, [container convertRect:local toView:container.superview]);
    }
    UIView *screen = container.superview;
    while (screen != nil && ![screen.nextResponder isKindOfClass:UIViewController.class]) screen = screen.superview;
    container.backgroundColor = UIColor.clearColor;
}












static void YTzoomPlaceCircle(UIView *owner, const void *key, UIView *button, UIView *host) {
    UIVisualEffectView *glass = YTzoomChromeGlass(owner, key);
    if (glass.superview != host) {
        [glass removeFromSuperview];
        UIView *branch = button;
        while (branch.superview != nil && branch.superview != host) branch = branch.superview;
        if (branch.superview == host) [host insertSubview:glass belowSubview:branch];
        else [host insertSubview:glass atIndex:0];
    }
    CGRect buttonFrame = [button convertRect:button.bounds toView:host];
    CGFloat side = 36.0;
    CGRect frame = CGRectMake(CGRectGetMidX(buttonFrame) - side * 0.5,
                              CGRectGetMidY(buttonFrame) - side * 0.5, side, side);
    if (host == owner) {
        CGRect safe = UIEdgeInsetsInsetRect(host.bounds, host.safeAreaInsets);
        if (!CGRectIsEmpty(safe) && CGRectGetMinY(frame) < CGRectGetMinY(safe)) {
            frame.origin.y = CGRectGetMinY(safe);
        }
    }
    glass.hidden = NO;
    if (CGAffineTransformIsIdentity(glass.transform)) {
        glass.frame = frame;
        glass.layer.cornerRadius = side * 0.5;
    }
    if (button.superview == host) [host insertSubview:glass belowSubview:button];
}




static BOOL YTzoomButtonHasContent(UIButton *button) {
    if (button.hidden || button.alpha <= 0.01) return NO;
    if (button.currentImage != nil || button.currentTitle.length != 0 || button.currentBackgroundImage != nil) {
        return YES;
    }
    for (UIView *subview in button.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIImageView.class]) {
            if (((UIImageView *)subview).image != nil) return YES;
            continue;
        }
        if ([subview isKindOfClass:UILabel.class]) {
            if (((UILabel *)subview).text.length != 0) return YES;
            continue;
        }
        return YES;
    }
    return NO;
}

static void YTzoomCollectHeaderButtons(UIView *view, NSMutableArray<UIButton *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        CGSize size = subview.bounds.size;
        if ([subview isKindOfClass:UIButton.class] && size.width <= 64.0 && size.height <= 64.0 &&
            YTzoomButtonHasContent((UIButton *)subview)) {
            [buttons addObject:(UIButton *)subview];
            continue;
        }
        YTzoomCollectHeaderButtons(subview, buttons);
    }
}

static void YTzoomUpdateHeader(UIView *header) {
    UIVisualEffectView *existing = objc_getAssociatedObject(header, YTzoomHeaderGlassAssociation);
    if (!YTzoomGlassChromeEnabled() || header.window == nil || CGRectIsEmpty(header.bounds)) {
        if (objc_getAssociatedObject(header, YTzoomHeaderTouchedAssociation) == nil) return;
        objc_setAssociatedObject(header, YTzoomHeaderTouchedAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [existing removeFromSuperview];
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:header];
        while (queue.count != 0) {
            UIView *node = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(node.class) isEqualToString:@"YTLeftNavigationButtons"]) [rows addObject:node];
            else [queue addObjectsFromArray:node.subviews];
        }
        for (UIView *row in rows) {
            YTzoomRestoreButtonsForKey(row, YTzoomLeftGlassAssociation);
            YTzoomRemoveChromeGlass(row, YTzoomLeftGlassAssociation);
        }
        return;
    }
    objc_setAssociatedObject(header, YTzoomHeaderTouchedAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    YTzoomCollectHeaderButtons(header, buttons);
    CGFloat width = CGRectGetWidth(header.bounds);
    UIButton *best = nil;
    CGFloat bestMinX = CGFLOAT_MAX;
    for (UIButton *button in buttons) {
        CGRect frame = [header convertRect:button.bounds fromView:button];
        if (CGRectGetMidX(frame) >= width * 0.5 || CGRectGetMinX(frame) > width * 0.28) continue;
        if (CGRectGetMinX(frame) < bestMinX) {
            bestMinX = CGRectGetMinX(frame);
            best = button;
        }
    }
    if (best == nil) {
        existing.hidden = YES;
        return;
    }
    UIView *row = best.superview;
    while (row != nil && row != header && ![NSStringFromClass(row.class) isEqualToString:@"YTLeftNavigationButtons"]) {
        row = row.superview;
    }
    if (YTzoomNativeButtons() && row != nil && row != header) {
        [existing removeFromSuperview];
        YTzoomApplyNativeGlass(row, YTzoomLeftGlassAssociation);
        return;
    }
    YTzoomPlaceCircle(header, YTzoomHeaderGlassAssociation, best, header);
}

static void YTzoomHeaderLayout(UIView *receiver, SEL selector) {
    if (OriginalHeaderLayout != NULL) ((void (*)(id, SEL))OriginalHeaderLayout)(receiver, selector);
    YTzoomUpdateHeader(receiver);
}

static void YTzoomHeaderMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalHeaderMoveToWindow != NULL) ((void (*)(id, SEL))OriginalHeaderMoveToWindow)(receiver, selector);
    if (receiver.window != nil) {
        dispatch_async(dispatch_get_main_queue(), ^{ YTzoomUpdateHeader(receiver); });
    }
}

static const void *YTzoomInsideGlassAssociation = &YTzoomInsideGlassAssociation;
static const void *YTzoomMirrorAssociation = &YTzoomMirrorAssociation;
static const void *YTzoomMirroredIconAssociation = &YTzoomMirroredIconAssociation;

static UIImageView *YTzoomFindIcon(UIView *view, UIView *skip) {
    for (UIView *subview in view.subviews) {
        if (subview == skip || subview.hidden) continue;
        if ([subview isKindOfClass:UIImageView.class] && ((UIImageView *)subview).image != nil &&
            !CGRectIsEmpty(subview.bounds)) {
            return (UIImageView *)subview;
        }
        UIImageView *found = YTzoomFindIcon(subview, skip);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL YTzoomMirrorIcon(UIView *button, UIVisualEffectView *glass) {
    UIImageView *icon = objc_getAssociatedObject(button, YTzoomMirroredIconAssociation);
    if (icon == nil || icon.superview == nil || ![icon isDescendantOfView:button]) {
        icon = YTzoomFindIcon(button, glass);
        objc_setAssociatedObject(button, YTzoomMirroredIconAssociation, icon, OBJC_ASSOCIATION_ASSIGN);
    }
    UIImageView *mirror = objc_getAssociatedObject(button, YTzoomMirrorAssociation);
    if (icon == nil) {
        [mirror removeFromSuperview];
        return NO;
    }
    if (mirror == nil) {
        mirror = [UIImageView new];
        mirror.userInteractionEnabled = NO;
        objc_setAssociatedObject(button, YTzoomMirrorAssociation, mirror, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (mirror.superview != glass.contentView) [glass.contentView addSubview:mirror];
    mirror.image = icon.image;
    mirror.tintColor = icon.tintColor;
    mirror.contentMode = icon.contentMode;
    mirror.frame = [icon convertRect:icon.bounds toView:glass.contentView];
    icon.alpha = 0.0;
    return YES;
}

static const void *YTzoomQuietButtonAssociation = &YTzoomQuietButtonAssociation;
static IMP OriginalQTMSetBackground;
static IMP OriginalQTMTouchesBegan;

static BOOL YTzoomButtonIsQuiet(UIView *button) {
    return YTzoomGlassChromeEnabled() && objc_getAssociatedObject(button, YTzoomQuietButtonAssociation) != nil;
}

static void YTzoomHideButtonFeedback(UIView *button) {
    for (NSString *key in @[@"_touchFeedbackView", @"_inkView", @"_hitTargetBorderView"]) {
        id view = nil;
        @try { view = [button valueForKey:key]; } @catch (__unused NSException *exception) {}
        if ([view isKindOfClass:UIView.class]) {
            ((UIView *)view).hidden = YES;
            ((UIView *)view).alpha = 0.0;
        }
    }
}

static void YTzoomQuietSystemButton(UIView *button) {
    if (![button isKindOfClass:UIButton.class]) return;
    for (UIView *subview in button.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"_UISystemBackgroundView"]) continue;
        subview.hidden = NO;
        subview.alpha = 1.0;
        for (UIView *fill in subview.subviews) {
            CGFloat alpha = fill.backgroundColor != nil ? CGColorGetAlpha(fill.backgroundColor.CGColor) : 0.0;
            if (alpha > 0.0 || fill.layer.borderWidth > 0.0) fill.alpha = 0.0;
        }
    }
}

static void YTzoomQuietButton(UIView *button) {
    static Class qtmClass;
    if (qtmClass == Nil) qtmClass = NSClassFromString(@"YTLightweightQTMButton");
    YTzoomQuietSystemButton(button);
    if (qtmClass == Nil || ![button isKindOfClass:qtmClass]) return;
    objc_setAssociatedObject(button, YTzoomQuietButtonAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomHideButtonFeedback(button);
    SEL enabled = NSSelectorFromString(@"setEnabledBackgroundColor:");
    if ([button respondsToSelector:enabled]) {
        ((void (*)(id, SEL, id))objc_msgSend)(button, enabled, UIColor.clearColor);
    }
    button.backgroundColor = UIColor.clearColor;
    button.layer.backgroundColor = UIColor.clearColor.CGColor;
}

static void YTzoomQuietButtonsIn(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIButton.class]) YTzoomQuietButton(subview);
        YTzoomQuietButtonsIn(subview);
    }
}

static void YTzoomQTMSetBackground(UIView *receiver, SEL selector, UIColor *color) {
    if (YTzoomButtonIsQuiet(receiver)) color = UIColor.clearColor;
    if (OriginalQTMSetBackground != NULL) ((void (*)(id, SEL, id))OriginalQTMSetBackground)(receiver, selector, color);
}

static void YTzoomQTMTouchesBegan(UIView *receiver, SEL selector, NSSet *touches, UIEvent *event) {
    if (OriginalQTMTouchesBegan != NULL) {
        ((void (*)(id, SEL, id, id))OriginalQTMTouchesBegan)(receiver, selector, touches, event);
    }
    if (YTzoomButtonIsQuiet(receiver)) YTzoomHideButtonFeedback(receiver);
}

static BOOL YTzoomInsideGlassView(UIView *view, UIView *stop) {
    for (UIView *current = view.superview; current != nil && current != stop; current = current.superview) {
        if ([current isKindOfClass:UIVisualEffectView.class]) return YES;
    }
    return NO;
}

static void YTzoomGlassInsideButton(UIView *button, CGFloat side) {
    YTzoomQuietButton(button);
    if ([button.superview isKindOfClass:NSClassFromString(@"_UIVisualEffectContentView")]) {
        return;
    }
    UIVisualEffectView *glass = objc_getAssociatedObject(button, YTzoomInsideGlassAssociation);
    if (glass == nil) {
        glass = YTzoomChromeGlass(button, YTzoomInsideGlassAssociation);
        UIVisualEffect *effect = glass.effect;
        SEL interactive = NSSelectorFromString(@"setInteractive:");
        if ([effect respondsToSelector:interactive]) {
            UIVisualEffect *copy = [effect copy];
            ((void (*)(id, SEL, BOOL))objc_msgSend)(copy, interactive, YES);
            glass.effect = copy;
        }
        glass.userInteractionEnabled = YES;
        glass.clipsToBounds = YES;
        if ([button isKindOfClass:UIControl.class]) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:YTzoomTapProbe.shared
                                                                                  action:@selector(forward:)];
            tap.cancelsTouchesInView = NO;
            [glass addGestureRecognizer:tap];
        }
    }
    if (glass.superview != button) [button insertSubview:glass atIndex:0];
    else [button sendSubviewToBack:glass];
    CGRect bounds = button.bounds;
    glass.frame = CGRectMake(CGRectGetMidX(bounds) - side * 0.5, CGRectGetMidY(bounds) - side * 0.5, side, side);
    glass.layer.cornerRadius = side * 0.5;
    glass.hidden = NO;
    button.clipsToBounds = NO;
    YTzoomMirrorIcon(button, glass);
}

static void YTzoomClearInsideGlass(UIView *button) {
    UIView *glass = objc_getAssociatedObject(button, YTzoomInsideGlassAssociation);
    [glass removeFromSuperview];
    UIImageView *icon = objc_getAssociatedObject(button, YTzoomMirroredIconAssociation);
    icon.alpha = 1.0;
}

static void YTzoomCollectButtons(UIView *view, NSMutableArray<UIView *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        if ([subview isKindOfClass:UIButton.class]) {
            [buttons addObject:subview];
            continue;
        }
        YTzoomCollectButtons(subview, buttons);
    }
}

static void YTzoomUpdateMultiSearch(UIView *field) {
    UIView *pill = field.superview;
    UIView *strip = pill.superview;
    if (pill == nil || strip == nil) return;
    if (!YTzoomGlassChromeEnabled() || field.window == nil || CGRectIsEmpty(pill.bounds)) {
        YTzoomRemoveChromeGlass(pill, YTzoomPillGlassAssociation);
        return;
    }
    UIVisualEffectView *glass = YTzoomChromeGlass(pill, YTzoomPillGlassAssociation);
    if (glass.superview != pill) [pill insertSubview:glass atIndex:0];
    else [pill sendSubviewToBack:glass];
    glass.frame = pill.bounds;
    glass.layer.cornerRadius = pill.layer.cornerRadius > 0.0 ? pill.layer.cornerRadius : CGRectGetHeight(pill.bounds) * 0.5;
    pill.backgroundColor = UIColor.clearColor;
    pill.layer.backgroundColor = UIColor.clearColor.CGColor;
    CGRect pillFrame = [pill convertRect:pill.bounds toView:strip];
    NSHashTable<UIView *> *known = objc_getAssociatedObject(strip, YTzoomSideButtonsAssociation);
    for (UIView *button in known) {
        UIView *wrap = objc_getAssociatedObject(button, YTzoomWrapGlassAssociation);
        if (wrap != nil && !button.hidden && button.alpha > 0.01) wrap.hidden = NO;
    }
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *subview in strip.subviews) {
        if (subview == pill || subview.hidden || subview.alpha <= 0.01) continue;
        if ([subview isKindOfClass:UIButton.class]) [buttons addObject:subview];
        else YTzoomCollectButtons(subview, buttons);
    }
    NSUInteger rightSide = 0;
    for (UIView *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:strip];
        if (CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0 && CGRectGetWidth(frame) <= 64.0) rightSide++;
    }
    NSHashTable<UIView *> *previous = objc_getAssociatedObject(strip, YTzoomSideButtonsAssociation);
    NSHashTable<UIView *> *current = [NSHashTable weakObjectsHashTable];
    for (UIView *button in buttons) {
        CGRect frame = [button convertRect:button.bounds toView:strip];
        BOOL beside = CGRectGetMaxX(frame) <= CGRectGetMinX(pillFrame) + 2.0 ||
            CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0;
        BOOL small = CGRectGetWidth(frame) <= 64.0 && CGRectGetHeight(frame) <= 64.0;
        if (!beside || !small) continue;
        BOOL grouped = CGRectGetMinX(frame) >= CGRectGetMaxX(pillFrame) - 2.0 && rightSide > 1;
        if (grouped || YTzoomInsideGlassView(button, strip)) {
            YTzoomClearInsideGlass(button);
            YTzoomQuietButton(button);
            continue;
        }
        YTzoomGlassInsideButton(button, CGRectGetHeight(pillFrame));
        YTzoomRemoveChromeGlass(button, YTzoomSideGlassAssociation);
        [current addObject:button];
    }
    for (UIView *button in previous) {
        if ([current containsObject:button]) continue;
        YTzoomRemoveChromeGlass(button, YTzoomSideGlassAssociation);
        UIView *wrap = objc_getAssociatedObject(button, YTzoomWrapGlassAssociation);
        wrap.hidden = YES;
    }
    objc_setAssociatedObject(strip, YTzoomSideButtonsAssociation, current, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static IMP OriginalSearchBarLayout;

static void YTzoomSearchBarLayout(UIView *receiver, SEL selector) {
    if (OriginalSearchBarLayout != NULL) ((void (*)(id, SEL))OriginalSearchBarLayout)(receiver, selector);
    if (!YTzoomGlassChromeEnabled() || CGRectIsEmpty(receiver.bounds)) {
        YTzoomRemoveChromeGlass(receiver, YTzoomSearchBarGlassAssociation);
        return;
    }
    UIVisualEffectView *glass = YTzoomChromeGlass(receiver, YTzoomSearchBarGlassAssociation);
    if (glass.superview != receiver) [receiver insertSubview:glass atIndex:0];
    else if (receiver.subviews.firstObject != glass) [receiver sendSubviewToBack:glass];
    glass.frame = receiver.bounds;
    glass.layer.cornerRadius = CGRectGetHeight(receiver.bounds) * 0.5;
    receiver.backgroundColor = UIColor.clearColor;
}

static void YTzoomMultiSearchLayout(UIView *receiver, SEL selector) {
    if (OriginalMultiSearchLayout != NULL) ((void (*)(id, SEL))OriginalMultiSearchLayout)(receiver, selector);
    YTzoomUpdateMultiSearch(receiver);
}

static void YTzoomMultiSearchMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalMultiSearchMoveToWindow != NULL) {
        ((void (*)(id, SEL))OriginalMultiSearchMoveToWindow)(receiver, selector);
    }
    dispatch_async(dispatch_get_main_queue(), ^{ YTzoomUpdateMultiSearch(receiver); });
}

static void YTzoomCollectTopButtons(UIView *view, UIView *window, NSMutableArray<UIView *> *buttons) {
    for (UIView *subview in view.subviews) {
        if (subview.hidden || subview.alpha <= 0.01 || CGRectIsEmpty(subview.bounds)) continue;
        CGRect frame = [subview convertRect:subview.bounds toView:window];
        if (CGRectGetMinY(frame) > 140.0) continue;
        BOOL isButton = [subview isKindOfClass:UIButton.class]
            ? YTzoomButtonHasContent((UIButton *)subview)
            : ([subview isKindOfClass:UIControl.class] && ![subview isKindOfClass:UITextField.class] &&
               ![subview isKindOfClass:UISearchBar.class] && subview.subviews.count != 0);
        if (isButton && CGRectGetWidth(frame) <= 64.0 && CGRectGetHeight(frame) <= 64.0 &&
            CGRectGetWidth(frame) >= 20.0) {
            [buttons addObject:subview];
            continue;
        }
        YTzoomCollectTopButtons(subview, window, buttons);
    }
}

static void YTzoomShareBarItems(UINavigationItem *item) {
    if (item == nil) return;
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray array];
    [items addObjectsFromArray:item.leftBarButtonItems ?: @[]];
    [items addObjectsFromArray:item.rightBarButtonItems ?: @[]];
    if (item.backBarButtonItem != nil) [items addObject:item.backBarButtonItem];
    SEL getter = NSSelectorFromString(@"hidesSharedBackground");
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    BOOL wanted = !YTzoomGlassChromeEnabled();
    for (UIBarButtonItem *barItem in items) {
        if (![barItem respondsToSelector:getter] || ![barItem respondsToSelector:setter]) continue;
        BOOL before = ((BOOL (*)(id, SEL))objc_msgSend)(barItem, getter);
        if (before != wanted) ((void (*)(id, SEL, BOOL))objc_msgSend)(barItem, setter, wanted);
    }
}

static void YTzoomUpdateSettingsButtons(UIViewController *controller) {
    UIView *window = controller.view.window;
    if (window == nil) return;
    BOOL enabled = YTzoomGlassChromeEnabled();
    if (!enabled && objc_getAssociatedObject(controller, YTzoomSettingsTouchedAssociation) == nil) return;
    objc_setAssociatedObject(controller, YTzoomSettingsTouchedAssociation, enabled ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomShareBarItems(controller.navigationItem);
    UIViewController *top = controller.navigationController.topViewController;
    if (top != nil && top != controller) YTzoomShareBarItems(top.navigationItem);
    NSMutableArray<UIView *> *roots = [NSMutableArray arrayWithObject:controller.view];
    UINavigationBar *bar = controller.navigationController.navigationBar;
    if (bar != nil && !bar.hidden) [roots addObject:bar];
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *root in roots) YTzoomCollectTopButtons(root, window, buttons);
    for (UIView *button in buttons) {
        BOOL inBar = bar != nil && [button isDescendantOfView:bar];
        if (enabled && inBar) {
            YTzoomClearInsideGlass(button);
            YTzoomQuietButton(button);
        } else if (enabled) {
            YTzoomGlassInsideButton(button, 36.0);
        } else {
            YTzoomClearInsideGlass(button);
        }
    }
}

static void YTzoomSettingsLayout(UIViewController *receiver, SEL selector) {
    if (OriginalSettingsLayout != NULL) ((void (*)(id, SEL))OriginalSettingsLayout)(receiver, selector);
    YTzoomUpdateSettingsButtons(receiver);
}

static void YTzoomBarItemSetHidesShared(UIBarButtonItem *receiver, SEL selector, BOOL hides) {
    BOOL applied = YTzoomGlassChromeEnabled() ? NO : hides;
    if (hides && !applied) {
    }
    if (OriginalSetHidesShared != NULL) ((void (*)(id, SEL, BOOL))OriginalSetHidesShared)(receiver, selector, applied);
}

static void YTzoomShareItems(NSArray<UIBarButtonItem *> *items) {
    if (!YTzoomGlassChromeEnabled()) return;
    SEL setter = NSSelectorFromString(@"setHidesSharedBackground:");
    for (UIBarButtonItem *item in items) {
        if ([item respondsToSelector:setter]) ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, NO);
    }
}

static void YTzoomSetLeftItems(UINavigationItem *receiver, SEL selector, NSArray *items, BOOL animated) {
    YTzoomShareItems(items);
    if (OriginalSetLeftItems != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetLeftItems)(receiver, selector, items, animated);
}

static void YTzoomSetRightItems(UINavigationItem *receiver, SEL selector, NSArray *items, BOOL animated) {
    YTzoomShareItems(items);
    if (OriginalSetRightItems != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetRightItems)(receiver, selector, items, animated);
}

static void YTzoomSetLeftItem(UINavigationItem *receiver, SEL selector, UIBarButtonItem *item, BOOL animated) {
    if (item != nil) YTzoomShareItems(@[item]);
    if (OriginalSetLeftItem != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetLeftItem)(receiver, selector, item, animated);
}

static void YTzoomSetRightItem(UINavigationItem *receiver, SEL selector, UIBarButtonItem *item, BOOL animated) {
    if (item != nil) YTzoomShareItems(@[item]);
    if (OriginalSetRightItem != NULL) ((void (*)(id, SEL, id, BOOL))OriginalSetRightItem)(receiver, selector, item, animated);
}

static void YTzoomTopRefreshSoon(UIView *container) {
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomApplyTopNavigationGlass(container);
    });
}

static void YTzoomTopMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalTopMoveToWindow != NULL) ((void (*)(id, SEL))OriginalTopMoveToWindow)(receiver, selector);
    YTzoomTopRefreshSoon(receiver);
}

static void YTzoomTopMoveToSuperview(UIView *receiver, SEL selector) {
    if (OriginalTopMoveToSuperview != NULL) ((void (*)(id, SEL))OriginalTopMoveToSuperview)(receiver, selector);
    YTzoomTopRefreshSoon(receiver);
}

__attribute__((constructor)) static void YTzoomInstallGlassChrome(void) {
    if (!YTzoomLiquidGlassAvailable()) return;
    YTzoomInstallInstanceHook(@"YTLightweightQTMButton", @"setBackgroundColor:",
                              (IMP)YTzoomQTMSetBackground, &OriginalQTMSetBackground);
    YTzoomInstallInstanceHook(@"YTLightweightQTMButton", @"touchesBegan:withEvent:",
                              (IMP)YTzoomQTMTouchesBegan, &OriginalQTMTouchesBegan);
    YTzoomInstallInstanceHook(@"YTRightNavigationButtons", @"didMoveToWindow",
                              (IMP)YTzoomTopMoveToWindow, &OriginalTopMoveToWindow);
    YTzoomInstallInstanceHook(@"YTRightNavigationButtons", @"didMoveToSuperview",
                              (IMP)YTzoomTopMoveToSuperview, &OriginalTopMoveToSuperview);
    if (!YTzoomGlassChromeEnabled()) return;
    YTzoomInstallInstanceHook(@"YTMultiLineSearchBarView", @"layoutSubviews",
                                           (IMP)YTzoomMultiSearchLayout, &OriginalMultiSearchLayout);
    YTzoomInstallInstanceHook(@"YTSearchBarView", @"layoutSubviews",
                              (IMP)YTzoomSearchBarLayout, &OriginalSearchBarLayout);
    YTzoomInstallInstanceHook(@"YTMultiLineSearchBarView", @"didMoveToWindow",
                              (IMP)YTzoomMultiSearchMoveToWindow, &OriginalMultiSearchMoveToWindow);
    YTzoomInstallInstanceHook(@"UIBarButtonItem", @"setHidesSharedBackground:",
                                            (IMP)YTzoomBarItemSetHidesShared, &OriginalSetHidesShared);
    YTzoomInstallInstanceHook(@"UINavigationItem", @"setLeftBarButtonItems:animated:",
                                               (IMP)YTzoomSetLeftItems, &OriginalSetLeftItems);
    YTzoomInstallInstanceHook(@"UINavigationItem", @"setRightBarButtonItems:animated:",
                                                (IMP)YTzoomSetRightItems, &OriginalSetRightItems);
    YTzoomInstallInstanceHook(@"UINavigationItem", @"setLeftBarButtonItem:animated:",
                                              (IMP)YTzoomSetLeftItem, &OriginalSetLeftItem);
    YTzoomInstallInstanceHook(@"UINavigationItem", @"setRightBarButtonItem:animated:",
                                               (IMP)YTzoomSetRightItem, &OriginalSetRightItem);
    YTzoomInstallInstanceHook(@"YTSettingsViewController", @"viewDidLayoutSubviews",
                                              (IMP)YTzoomSettingsLayout, &OriginalSettingsLayout);
    YTzoomInstallInstanceHook(@"YTHeaderView", @"layoutSubviews",
                                            (IMP)YTzoomHeaderLayout, &OriginalHeaderLayout);
    YTzoomInstallInstanceHook(@"YTHeaderView", @"didMoveToWindow",
                              (IMP)YTzoomHeaderMoveToWindow, &OriginalHeaderMoveToWindow);
}
