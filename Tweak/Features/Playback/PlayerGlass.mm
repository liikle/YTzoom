#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalFrostedLayout;
static IMP OriginalFrostedMoveToWindow;
static const void *YTzoomPlayerGlassAssociation = &YTzoomPlayerGlassAssociation;

static BOOL YTzoomInPlayerControls(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *current = view.superview; current != nil && depth < 10; current = current.superview, depth++) {
        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"Overlay"] || [name containsString:@"Player"] ||
            [name containsString:@"Fullscreen"] || [name containsString:@"Watch"]) return YES;
    }
    return NO;
}

static NSArray<UIView *> *YTzoomFrostedLayers(UIView *frosted) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (NSString *key in @[@"_blurEffectView", @"_overlayView"]) {
        id view = nil;
        @try { view = [frosted valueForKey:key]; } @catch (__unused NSException *exception) {}
        if ([view isKindOfClass:UIView.class]) [views addObject:view];
    }
    return views;
}

static void YTzoomApplyFrostedGlass(UIView *receiver) {
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, YTzoomPlayerGlassAssociation);
    BOOL enabled = YTzoomLiquidGlassAvailable() && YTzoomFeatureEnabled(@"YTzoom.Preference.Glass.Player");
    BOOL wanted = enabled && YTzoomInPlayerControls(receiver);
    if (!wanted) {
        if (glass != nil) {
            [glass removeFromSuperview];
            for (UIView *layer in YTzoomFrostedLayers(receiver)) layer.alpha = 1.0;
        }
        return;
    }
    if (glass == nil) {
        Class effectClass = NSClassFromString(@"UIGlassEffect");
        SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
        UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
            ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
            : [effectClass new];
        if (effect == nil) return;
        glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        glass.userInteractionEnabled = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
        objc_setAssociatedObject(receiver, YTzoomPlayerGlassAssociation, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    for (UIView *layer in YTzoomFrostedLayers(receiver)) layer.alpha = 0.0;
    if (glass.superview != receiver) [receiver insertSubview:glass atIndex:0];
    glass.frame = receiver.bounds;
    CGFloat radius = receiver.layer.cornerRadius;
    CGFloat capsule = MIN(CGRectGetWidth(receiver.bounds), CGRectGetHeight(receiver.bounds)) * 0.5;
    glass.layer.cornerRadius = radius > 0.0 ? MIN(radius, capsule) : capsule;
    receiver.backgroundColor = UIColor.clearColor;
}

static void YTzoomFrostedLayout(UIView *receiver, SEL selector) {
    if (OriginalFrostedLayout != NULL) ((void (*)(id, SEL))OriginalFrostedLayout)(receiver, selector);
    YTzoomApplyFrostedGlass(receiver);
}

static void YTzoomFrostedMoveToWindow(UIView *receiver, SEL selector) {
    if (OriginalFrostedMoveToWindow != NULL) ((void (*)(id, SEL))OriginalFrostedMoveToWindow)(receiver, selector);
    if (receiver.window != nil) [receiver setNeedsLayout];
}

__attribute__((constructor)) static void YTzoomInstallPlayerGlass(void) {
    if (!YTzoomLiquidGlassAvailable()) return;
    YTzoomInstallInstanceHook(@"YTFrostedGlassView", @"layoutSubviews",
                              (IMP)YTzoomFrostedLayout, &OriginalFrostedLayout);
    YTzoomInstallInstanceHook(@"YTFrostedGlassView", @"didMoveToWindow",
                              (IMP)YTzoomFrostedMoveToWindow, &OriginalFrostedMoveToWindow);
}
