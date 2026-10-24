#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSheetLayout;
static IMP OriginalSheetAppear;
static IMP OriginalContextualAppear;
static IMP OriginalSheetWillAppear;
static IMP OriginalModalShow;
static IMP OriginalModalReposition;
static IMP OriginalContextualWillAppear;
static IMP OriginalContextualLayout;

static const void *YTzoomSheetGlassAssociation = &YTzoomSheetGlassAssociation;

static BOOL YTzoomSheetGlassEnabled(void) {
    return YTzoomLiquidGlassAvailable() && YTzoomFeatureEnabled(@"YTzoom.Preference.Glass.Menus");
}

static UIView *YTzoomFindViewOfClass(UIView *root, NSString *name) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    while (queue.count != 0) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
        [queue addObjectsFromArray:view.subviews];
    }
    return nil;
}

static BOOL YTzoomColorIsSolid(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    return color != nil && [color getRed:&red green:&green blue:&blue alpha:&alpha] && alpha > 0.3;
}

static BOOL YTzoomIsSheetContainer(UIView *view) {
    static NSSet<NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = [NSSet setWithArray:@[@"YTDraggableView", @"YTDialogContainerScrollView", @"GOODialogView",
                                      @"YTContextualWrapView", @"YTActionSheetHeaderView", @"UIScrollView",
                                      @"GOODialogContentView", @"YTMinimumWidthDialogView"]];
    });
    return [names containsObject:NSStringFromClass(view.class)];
}

static BOOL YTzoomIsELMRoot(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"ELMView"];
}

static BOOL YTzoomIsELMView(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return YTzoomIsELMRoot(view) || [name hasPrefix:@"_AS"] || [name hasPrefix:@"AS"];
}

static void YTzoomClearELMBackground(UIView *view, UIView *sheet, NSInteger depth) {
    if (depth > 4) return;
    for (UIView *subview in view.subviews) {
        if (![NSStringFromClass(subview.class) isEqualToString:@"_ASDisplayView"]) continue;
        if (YTzoomColorIsSolid(subview.backgroundColor) &&
            CGRectGetWidth(subview.bounds) >= CGRectGetWidth(sheet.bounds) * 0.9 &&
            CGRectGetHeight(subview.bounds) >= 40.0) {
            id node = nil;
            @try { node = [subview valueForKey:@"asyncdisplaykit_node"]; } @catch (__unused NSException *exception) {}
            if ([node respondsToSelector:@selector(setBackgroundColor:)]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, @selector(setBackgroundColor:), UIColor.clearColor);
            } else {
                subview.backgroundColor = UIColor.clearColor;
            }
        }
        YTzoomClearELMBackground(subview, sheet, depth + 1);
    }
}

static void YTzoomClearSheetBackgrounds(UIView *view, UIView *sheet, UIView *glass, NSInteger depth) {
    if (depth > 10) return;
    for (UIView *subview in view.subviews) {
        if (subview == glass) continue;
        if (YTzoomIsELMRoot(subview)) {
            YTzoomClearELMBackground(subview, sheet, 0);
            continue;
        }
        if (YTzoomIsELMView(subview)) continue;
        if (YTzoomIsSheetContainer(subview) && YTzoomColorIsSolid(subview.backgroundColor)) {
            subview.backgroundColor = UIColor.clearColor;
        }
        YTzoomClearSheetBackgrounds(subview, sheet, glass, depth + 1);
    }
}

static UIVisualEffect *YTzoomSheetGlassEffect(void) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    return [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, 0)
        : [effectClass new];
}

static void YTzoomClearShadows(UIView *view, UIView *stop) {
    for (UIView *current = view; current != nil && current != stop; current = current.superview) {
        if (current.layer.shadowOpacity > 0.0) current.layer.shadowOpacity = 0.0;
    }
}

static void YTzoomApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius);

static void YTzoomApplySheetGlass(UIViewController *controller) {
    if (!YTzoomSheetGlassEnabled() || !controller.isViewLoaded) return;
    UIView *sheet = YTzoomFindViewOfClass(controller.view, @"YTDraggableView");
    if (sheet == nil) {
        sheet = YTzoomFindViewOfClass(controller.view, @"YTContextualWrapView");
        if (sheet != nil) {
            YTzoomClearShadows(sheet, controller.view.window);
            for (UIView *current = sheet; current != nil; current = current.superview) {
                SEL shadow = NSSelectorFromString(@"shadowLayer");
                if ([NSStringFromClass(current.class) isEqualToString:@"YTContextualSheetView"] &&
                    [current respondsToSelector:shadow]) {
                    CALayer *layer = ((id (*)(id, SEL))objc_msgSend)(current, shadow);
                    layer.shadowOpacity = 0.0;
                    layer.shadowPath = NULL;
                    current.layer.shadowOpacity = 0.0;
                    break;
                }
            }
        }
    }
    if (sheet == nil || CGRectIsEmpty(sheet.bounds)) return;
    YTzoomApplyPanelGlass(sheet, 24.0);
}

static void YTzoomApplyPanelGlass(UIView *sheet, CGFloat fallbackRadius) {
    UIVisualEffectView *glass = objc_getAssociatedObject(sheet, YTzoomSheetGlassAssociation);
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTzoomSheetGlassEffect()];
        glass.userInteractionEnabled = NO;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(sheet, YTzoomSheetGlassAssociation, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != sheet) [sheet insertSubview:glass atIndex:0];
    else if (sheet.subviews.firstObject != glass) [sheet sendSubviewToBack:glass];
    glass.frame = sheet.bounds;
    CGFloat radius = sheet.layer.cornerRadius > 0.0 ? sheet.layer.cornerRadius : fallbackRadius;
    glass.layer.cornerRadius = radius;
    glass.layer.maskedCorners = sheet.layer.cornerRadius > 0.0 ? sheet.layer.maskedCorners
        : (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner);
    sheet.backgroundColor = UIColor.clearColor;
    YTzoomClearSheetBackgrounds(sheet, sheet, glass, 0);
}

static void YTzoomApplySheetGlassLater(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    for (NSNumber *delay in @[@0.05, @0.15, @0.3, @0.5, @0.8, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIViewController *strong = weakController;
            if (strong == nil || strong.view.window == nil) return;
            YTzoomApplySheetGlass(strong);
        });
    }
}

static void YTzoomSheetLayout(UIViewController *receiver, SEL selector) {
    if (OriginalSheetLayout != NULL) ((void (*)(id, SEL))OriginalSheetLayout)(receiver, selector);
    if (!YTzoomSheetGlassEnabled()) return;
    __weak UIViewController *weakController = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller != nil) YTzoomApplySheetGlass(controller);
    });
}

static void YTzoomSheetWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetWillAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetWillAppear)(receiver, selector, animated);
    if (!YTzoomSheetGlassEnabled()) return;
    [receiver.view layoutIfNeeded];
    YTzoomApplySheetGlass(receiver);
}

static void YTzoomApplyModalGlass(UIView *modal) {
    if (!YTzoomSheetGlassEnabled() || modal.window == nil) return;
    UIView *dialog = nil;
    @try { dialog = [modal valueForKey:@"_dialogView"]; } @catch (__unused NSException *exception) {}
    if (![dialog isKindOfClass:UIView.class] || CGRectIsEmpty(dialog.bounds)) return;
    YTzoomClearShadows(dialog, modal.superview);
    dialog.layer.shadowOpacity = 0.0;
    YTzoomApplyPanelGlass(dialog, 28.0);
    UIVisualEffectView *glass = objc_getAssociatedObject(dialog, YTzoomSheetGlassAssociation);
    glass.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner |
        kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
    if (dialog.layer.cornerRadius < 12.0) {
        dialog.layer.cornerRadius = 28.0;
        dialog.layer.cornerCurve = kCACornerCurveContinuous;
    }
    dialog.clipsToBounds = YES;
}

static IMP OriginalAlertLayout;
static IMP OriginalAlertReveal;
static IMP OriginalYTAlertLayout;
static IMP OriginalReportLayout;
static IMP OriginalReportReveal;
static IMP OriginalContextualBegin;
static IMP OriginalContextualContainerLayout;

static void YTzoomAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalAlertLayout != NULL) ((void (*)(id, SEL))OriginalAlertLayout)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomAlertReveal(UIView *receiver, SEL selector) {
    if (OriginalAlertReveal != NULL) ((void (*)(id, SEL))OriginalAlertReveal)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomYTAlertLayout(UIView *receiver, SEL selector) {
    if (OriginalYTAlertLayout != NULL) ((void (*)(id, SEL))OriginalYTAlertLayout)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomReportLayout(UIView *receiver, SEL selector) {
    if (OriginalReportLayout != NULL) ((void (*)(id, SEL))OriginalReportLayout)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomReportReveal(UIView *receiver, SEL selector) {
    if (OriginalReportReveal != NULL) ((void (*)(id, SEL))OriginalReportReveal)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomContextualBegin(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualBegin != NULL) ((void (*)(id, SEL))OriginalContextualBegin)(receiver, selector);
    UIViewController *presented = receiver.presentedViewController;
    [presented.view layoutIfNeeded];
    YTzoomApplySheetGlass(presented);
}

static void YTzoomContextualContainerLayout(UIPresentationController *receiver, SEL selector) {
    if (OriginalContextualContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalContextualContainerLayout)(receiver, selector);
    }
    YTzoomApplySheetGlass(receiver.presentedViewController);
}

static void YTzoomModalShow(UIView *receiver, SEL selector) {
    if (OriginalModalShow != NULL) ((void (*)(id, SEL))OriginalModalShow)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomModalReposition(UIView *receiver, SEL selector) {
    if (OriginalModalReposition != NULL) ((void (*)(id, SEL))OriginalModalReposition)(receiver, selector);
    YTzoomApplyModalGlass(receiver);
}

static void YTzoomSheetAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalSheetAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalSheetAppear)(receiver, selector, animated);
    YTzoomApplySheetGlass(receiver);
    YTzoomApplySheetGlassLater(receiver);
}

static void YTzoomContextualAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualAppear != NULL) ((void (*)(id, SEL, BOOL))OriginalContextualAppear)(receiver, selector, animated);
    YTzoomApplySheetGlass(receiver);
    YTzoomApplySheetGlassLater(receiver);
}

static void YTzoomContextualWillAppear(UIViewController *receiver, SEL selector, BOOL animated) {
    if (OriginalContextualWillAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalContextualWillAppear)(receiver, selector, animated);
    }
    [receiver.view layoutIfNeeded];
    YTzoomApplySheetGlass(receiver);
}

static void YTzoomContextualLayout(UIViewController *receiver, SEL selector) {
    if (OriginalContextualLayout != NULL) ((void (*)(id, SEL))OriginalContextualLayout)(receiver, selector);
    if (!YTzoomSheetGlassEnabled()) return;
    __weak UIViewController *weakController = receiver;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = weakController;
        if (controller != nil) YTzoomApplySheetGlass(controller);
    });
}

__attribute__((constructor)) static void YTzoomInstallGlassSheets(void) {
    if (!YTzoomLiquidGlassAvailable()) return;
    YTzoomInstallInstanceHook(@"YTBottomSheetController", @"viewWillLayoutSubviews",
                              (IMP)YTzoomSheetLayout, &OriginalSheetLayout);
    YTzoomInstallInstanceHook(@"YTBottomSheetController", @"viewDidAppear:",
                              (IMP)YTzoomSheetAppear, &OriginalSheetAppear);
    YTzoomInstallInstanceHook(@"YTBottomSheetController", @"viewWillAppear:",
                              (IMP)YTzoomSheetWillAppear, &OriginalSheetWillAppear);
    YTzoomInstallInstanceHook(@"GOOAlertView", @"layoutSubviews",
                              (IMP)YTzoomAlertLayout, &OriginalAlertLayout);
    YTzoomInstallInstanceHook(@"GOOAlertView", @"revealDialog",
                              (IMP)YTzoomAlertReveal, &OriginalAlertReveal);
    YTzoomInstallInstanceHook(@"YTAlertView", @"layoutSubviews",
                              (IMP)YTzoomYTAlertLayout, &OriginalYTAlertLayout);
    YTzoomInstallInstanceHook(@"YTReportFormModalAlertView", @"layoutSubviews",
                              (IMP)YTzoomReportLayout, &OriginalReportLayout);
    YTzoomInstallInstanceHook(@"YTReportFormModalAlertView", @"revealDialog",
                              (IMP)YTzoomReportReveal, &OriginalReportReveal);
    YTzoomInstallInstanceHook(@"YTContextualSheetPresentationController", @"presentationTransitionWillBegin",
                              (IMP)YTzoomContextualBegin, &OriginalContextualBegin);
    YTzoomInstallInstanceHook(@"YTContextualSheetPresentationController", @"containerViewDidLayoutSubviews",
                              (IMP)YTzoomContextualContainerLayout, &OriginalContextualContainerLayout);
    YTzoomInstallInstanceHook(@"GOOModalView", @"show",
                              (IMP)YTzoomModalShow, &OriginalModalShow);
    YTzoomInstallInstanceHook(@"GOOModalView", @"reposition",
                              (IMP)YTzoomModalReposition, &OriginalModalReposition);
    YTzoomInstallInstanceHook(@"YTContextualSheetViewController", @"viewDidAppear:",
                              (IMP)YTzoomContextualAppear, &OriginalContextualAppear);
    YTzoomInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillAppear:",
                              (IMP)YTzoomContextualWillAppear, &OriginalContextualWillAppear);
    YTzoomInstallInstanceHook(@"YTContextualSheetViewController", @"viewWillLayoutSubviews",
                              (IMP)YTzoomContextualLayout, &OriginalContextualLayout);
}
