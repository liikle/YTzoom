#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Interface/NavigationVisibility.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSMutableDictionary<NSString *, NSValue *> *YTzoomOLEDOriginals;
static IMP OriginalQualitySheetDidAppear;
static IMP OriginalAppTraitChanged;
static IMP OriginalAppStatusBarStyle;

static NSValue *YTzoomOLEDValue(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP YTzoomOLEDImplementation(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static NSString *YTzoomOLEDOriginalKey(id receiver, SEL selector) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? receiver : [receiver class];
    return [NSString stringWithFormat:@"%@|%@|%@",
            classMethod ? @"+" : @"-",
            NSStringFromClass(cls),
            NSStringFromSelector(selector)];
}

static UIColor *YTzoomOLEDColor(id receiver, SEL selector) {
    IMP original = YTzoomOLEDImplementation(
        YTzoomOLEDOriginals[YTzoomOLEDOriginalKey(receiver, selector)]
    );
    UIColor *base = original == NULL
        ? nil
        : ((id (*)(id, SEL))original)(receiver, selector);
    if (!YTzoomFeatureEnabled(YTzoomOLEDKey)) return base;
    __weak id weakReceiver = receiver;
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        if (YTzoomOLEDActive(traits)) return UIColor.blackColor;
        id target = weakReceiver;
        UIColor *current = target == nil || original == NULL
            ? base
            : ((id (*)(id, SEL))original)(target, selector);
        return current == nil ? [UIColor.systemBackgroundColor
            resolvedColorWithTraitCollection:traits]
            : [current resolvedColorWithTraitCollection:traits];
    }];
}

static void YTzoomRefreshStatusBars(UIViewController *controller) {
    if (controller == nil) return;
    [controller setNeedsStatusBarAppearanceUpdate];
    if ([controller isKindOfClass:UINavigationController.class]) {
        YTzoomRefreshStatusBars(((UINavigationController *)controller).visibleViewController);
    } else if ([controller isKindOfClass:UITabBarController.class]) {
        YTzoomRefreshStatusBars(((UITabBarController *)controller).selectedViewController);
    }
    YTzoomRefreshStatusBars(controller.presentedViewController);
}

static NSInteger YTzoomAppStatusBarStyle(UIViewController *receiver,
                                         SEL selector) {
    NSInteger original = OriginalAppStatusBarStyle == NULL
        ? UIStatusBarStyleDefault
        : ((NSInteger (*)(id, SEL))OriginalAppStatusBarStyle)(receiver, selector);
    if (!YTzoomFeatureEnabled(YTzoomOLEDKey)) return original;
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    NSInteger result = style == UIUserInterfaceStyleDark
        ? UIStatusBarStyleLightContent
        : UIStatusBarStyleDarkContent;
    return result;
}

static void YTzoomAppTraitChanged(UIViewController *receiver,
                                  SEL selector,
                                  UITraitCollection *previous) {
    if (OriginalAppTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalAppTraitChanged)(receiver, selector, previous);
    }
    if (previous != nil &&
        ![receiver.traitCollection
            hasDifferentColorAppearanceComparedToTraitCollection:previous]) return;
    if (!YTzoomFeatureEnabled(YTzoomOLEDKey)) return;
    [receiver setNeedsStatusBarAppearanceUpdate];
    [receiver.view setNeedsLayout];
    YTzoomRefreshNavigationAppearance();
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                YTzoomRefreshStatusBars(window.rootViewController);
                [window setNeedsLayout];
            }
        }
        YTzoomRefreshNavigationAppearance();
    });
}

static void YTzoomInstallColorHook(NSString *className,
                                   NSString *selectorName,
                                   BOOL classMethod) {
    IMP original = NULL;
    BOOL installed = classMethod
        ? YTzoomInstallClassHook(className,
                                selectorName,
                                (IMP)YTzoomOLEDColor,
                                &original)
        : YTzoomInstallInstanceHook(className,
                                   selectorName,
                                   (IMP)YTzoomOLEDColor,
                                   &original);
    if (!installed || original == NULL) {
        return;
    }
    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     classMethod ? @"+" : @"-",
                     className,
                     selectorName];
    if (YTzoomOLEDOriginals[key] == nil) {
        YTzoomOLEDOriginals[key] = YTzoomOLEDValue(original);
    }
}

static void YTzoomCollectQualityLabels(UIView *view,
                                       NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *text = label.text ?: @"";
        NSRegularExpression *pattern = [NSRegularExpression
            regularExpressionWithPattern:@"^\\s*\\d{3,4}p(?:60)?" options:0 error:nil];
        if ([text localizedCaseInsensitiveContainsString:@"quality"] ||
            [pattern firstMatchInString:text options:0
                range:NSMakeRange(0, text.length)] != nil) {
            [labels addObject:label];
        }
    }
    for (UIView *child in view.subviews) {
        YTzoomCollectQualityLabels(child, labels);
    }
}

static UIView *YTzoomCommonAncestor(NSArray<UIView *> *views, UIView *limit) {
    UIView *candidate = views.firstObject;
    while (candidate != nil && candidate != limit.superview) {
        BOOL containsAll = YES;
        for (UIView *view in views) {
            if (view != candidate && ![view isDescendantOfView:candidate]) {
                containsAll = NO;
                break;
            }
        }
        if (containsAll) return candidate;
        candidate = candidate.superview;
    }
    return nil;
}

static void YTzoomBlackenQualitySurface(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *effect = (UIVisualEffectView *)view;
        effect.effect = nil;
        effect.contentView.backgroundColor = UIColor.blackColor;
    }
    UIColor *background = view.backgroundColor;
    CGFloat alpha = background == nil ? 0.0 : CGColorGetAlpha(background.CGColor);
    if (alpha > 0.01 || [view isKindOfClass:UITableView.class] ||
        [view isKindOfClass:UICollectionView.class]) {
        view.backgroundColor = UIColor.blackColor;
    }
    if ([view isKindOfClass:UILabel.class]) {
        ((UILabel *)view).textColor = UIColor.whiteColor;
    }
    for (UIView *child in view.subviews) {
        YTzoomBlackenQualitySurface(child);
    }
}

static void YTzoomQualitySheetDidAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalQualitySheetDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalQualitySheetDidAppear)(
            receiver, selector, animated);
    }
    if (![receiver isKindOfClass:UIViewController.class] ||
        !YTzoomOLEDActive(((UIViewController *)receiver).traitCollection)) return;
    if (YTzoomLiquidGlassAvailable() && YTzoomFeatureEnabled(@"YTzoom.Preference.Glass.Menus")) return;
    UIView *root = ((UIViewController *)receiver).view;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        YTzoomCollectQualityLabels(root, labels);
        NSUInteger qualityRows = 0;
        for (UILabel *label in labels) {
            if ([label.text rangeOfString:@"p"].location != NSNotFound) qualityRows++;
        }
        if (qualityRows < 2) return;
        UIView *surface = YTzoomCommonAncestor(labels, root);
        if (surface == nil || surface == root) {
            for (UIView *child in root.subviews) {
                NSUInteger count = 0;
                for (UILabel *label in labels) {
                    if ([label isDescendantOfView:child]) count++;
                }
                if (count == labels.count) {
                    surface = child;
                    break;
                }
            }
        }
        if (surface != nil && surface != root) {
            surface.backgroundColor = UIColor.blackColor;
            YTzoomBlackenQualitySurface(surface);
        }
    });
}

void YTzoomInstallOLEDHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomOLEDOriginals = [NSMutableDictionary dictionary];
    });

    for (NSString *selector in @[@"black0", @"black1", @"black2", @"black3", @"black4"]) {
        YTzoomInstallColorHook(@"YTColor", selector, YES);
    }

    NSArray<NSString *> *paletteSelectors = @[
        @"baseBackground",
        @"brandBackgroundPrimary",
        @"brandBackgroundSecondary",
        @"brandBackgroundSolid",
        @"brandSurfaceContainer",
        @"brandSurfaceContainerHigh",
        @"brandSurfaceContainerHighest",
        @"raisedBackground",
        @"staticBrandBlack",
        @"generalBackgroundA",
        @"generalBackgroundB",
        @"generalBackgroundC",
        @"menuBackground",
        @"dialogBackgroundColor",
        @"elevatedBackgroundColor"
    ];
    for (NSString *selector in paletteSelectors) {
        YTzoomInstallColorHook(@"YTCommonColorPalette", selector, NO);
        YTzoomInstallColorHook(@"YTCommonColorPalette", selector, YES);
    }

    YTzoomInstallInstanceHook(@"YTActionSheetDialogViewController",
                              @"viewDidAppear:",
                              (IMP)YTzoomQualitySheetDidAppear,
                              &OriginalQualitySheetDidAppear);
    YTzoomInstallInstanceHook(@"YTAppViewController",
                              @"traitCollectionDidChange:",
                              (IMP)YTzoomAppTraitChanged,
                              &OriginalAppTraitChanged);
    YTzoomInstallInstanceHook(@"YTAppViewController",
                              @"preferredStatusBarStyle",
                              (IMP)YTzoomAppStatusBarStyle,
                              &OriginalAppStatusBarStyle);

}
