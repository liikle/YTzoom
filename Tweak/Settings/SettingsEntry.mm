#import "../YTzoom.h"
#import "../Runtime/Hooking.h"
#import "../Features/Interface/NavigationVisibility.h"
#import "../UI/Assets.h"
#import "YTzoomRootOptionsController.h"

#import <objc/runtime.h>

static IMP OriginalPivotViewDidAppear;
static IMP OriginalRightButtonsLayoutSubviews;
static const void *YTzoomSettingsButtonAssociation = &YTzoomSettingsButtonAssociation;

static UIViewController *YTzoomTopViewController(UIViewController *controller) {
    if (controller.presentedViewController != nil) {
        return YTzoomTopViewController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return YTzoomTopViewController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return YTzoomTopViewController(((UITabBarController *)controller).selectedViewController);
    }
    return controller;
}

@interface YTzoomSettingsPresenter : NSObject
+ (instancetype)sharedPresenter;
- (void)openSettings;
@end

@implementation YTzoomSettingsPresenter

+ (instancetype)sharedPresenter {
    static YTzoomSettingsPresenter *presenter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        presenter = [YTzoomSettingsPresenter new];
    });
    return presenter;
}

- (void)openSettings {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (window == nil &&
                scene.activationState == UISceneActivationStateForegroundActive) {
                window = candidate;
            }
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window != nil) {
            break;
        }
    }
    UIViewController *presenter = YTzoomTopViewController(window.rootViewController);
    if ([presenter.presentedViewController isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)presenter.presentedViewController).viewControllers.firstObject
            isKindOfClass:YTzoomRootOptionsController.class]) {
        return;
    }
    [presenter presentViewController:YTzoomMakeSettingsNavigationController()
                            animated:YES
                          completion:nil];
}

@end

static UIBarButtonItem *YTzoomSettingsBarButton(void) {
    UIImage *image = [YTzoomGearImage()
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return [[UIBarButtonItem alloc] initWithImage:image
                                           style:UIBarButtonItemStylePlain
                                          target:YTzoomSettingsPresenter.sharedPresenter
                                          action:@selector(openSettings)];
}

static void YTzoomPivotViewDidAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalPivotViewDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotViewDidAppear)(receiver, selector, animated);
    }

    if (![receiver isKindOfClass:UIViewController.class]) {
        return;
    }
    UIViewController *controller = receiver;
    if (objc_getAssociatedObject(controller, YTzoomSettingsButtonAssociation) != nil) {
        return;
    }

    NSMutableArray<UIBarButtonItem *> *items =
        [controller.navigationItem.rightBarButtonItems mutableCopy] ?: [NSMutableArray array];
    [items insertObject:YTzoomSettingsBarButton() atIndex:0];
    controller.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(controller,
                             YTzoomSettingsButtonAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomRightButtonsLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalRightButtonsLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalRightButtonsLayoutSubviews)(receiver, selector);
    }
    if (objc_getAssociatedObject(receiver, YTzoomSettingsButtonAssociation) != nil) {
        YTzoomApplyRightNavigationVisibility(receiver);
        YTzoomApplyTopNavigationGlass(receiver);
        return;
    }

    UIStackView *stack = nil;
    for (UIView *subview in receiver.subviews) {
        if ([subview isKindOfClass:UIStackView.class]) {
            stack = (UIStackView *)subview;
            break;
        }
    }
    if (stack == nil) {
        YTzoomApplyTopNavigationGlass(receiver);
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[YTzoomGearImage()
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
             forState:UIControlStateNormal];
    button.accessibilityLabel = @"YTzoom Settings";
    [button addTarget:YTzoomSettingsPresenter.sharedPresenter
               action:@selector(openSettings)
     forControlEvents:UIControlEventTouchUpInside];
    [button.widthAnchor constraintEqualToConstant:32.0].active = YES;
    [button.heightAnchor constraintEqualToConstant:32.0].active = YES;
    [stack insertArrangedSubview:button atIndex:0];

    objc_setAssociatedObject(receiver,
                             YTzoomSettingsButtonAssociation,
                             button,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomApplyRightNavigationVisibility(receiver);
    YTzoomApplyTopNavigationGlass(receiver);
}

void YTzoomInstallSettingsEntryHooks(void) {
    YTzoomInstallInstanceHook(@"YTPivotBarViewController",
                              @"viewDidAppear:",
                              (IMP)YTzoomPivotViewDidAppear,
                              &OriginalPivotViewDidAppear);
    YTzoomInstallInstanceHook(@"YTRightNavigationButtons",
                              @"layoutSubviews",
                              (IMP)YTzoomRightButtonsLayoutSubviews,
                              &OriginalRightButtonsLayoutSubviews);
}
