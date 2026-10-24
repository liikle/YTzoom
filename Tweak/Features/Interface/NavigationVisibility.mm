#import "NavigationVisibility.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>

static IMP OriginalHeaderLogoLayout;
static IMP OriginalLogoViewLayout;
static IMP OriginalHeaderLogoSetHidden;
static IMP OriginalLogoViewSetHidden;
static IMP OriginalYTImageSetHidden;
static IMP OriginalQTMButtonLayout;
static IMP OriginalQTMButtonSetTint;
static IMP OriginalQTMButtonSetImage;
static IMP OriginalNavigationImageSetTint;
static IMP OriginalNavigationImageSetImage;
static IMP OriginalYTImageViewLayout;
static IMP OriginalMainWindowTraitChanged;
static IMP OriginalRightNavigationTraitChanged;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomNavigationOriginals;
static const void *YTzoomNavigationHiddenAssociation = &YTzoomNavigationHiddenAssociation;
static BOOL YTzoomNavigationObserverInstalled;
static NSHashTable<UIView *> *YTzoomNavigationOwners;
static UIUserInterfaceStyle YTzoomNavigationStyle = UIUserInterfaceStyleUnspecified;

static void YTzoomApplyNavigationWindows(void);
static void YTzoomApplyNavigationSelectors(id owner);
static BOOL YTzoomInsideRightNavigation(UIView *view);
static BOOL YTzoomIsNavigationIcon(UIView *view);

static NSValue *YTzoomNavigationIMPValue(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP YTzoomNavigationIMP(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static NSString *YTzoomNavigationHookKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@",
            NSStringFromClass(cls), NSStringFromSelector(selector)];
}

static IMP YTzoomNavigationOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        NSValue *value = YTzoomNavigationOriginals[
            YTzoomNavigationHookKey(cls, selector)
        ];
        if (value != nil) return YTzoomNavigationIMP(value);
    }
    return NULL;
}

static void YTzoomSetNavigationHidden(UIView *view, BOOL hidden) {
    if (view == nil ||
        [view.accessibilityLabel hasPrefix:@"YTzoom"] ||
        [view.accessibilityIdentifier hasPrefix:@"YTzoom"]) {
        return;
    }
    NSNumber *baseline = objc_getAssociatedObject(
        view,
        YTzoomNavigationHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(view,
                                     YTzoomNavigationHiddenAssociation,
                                     @(view.hidden),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.hidden = YES;
        view.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        view.hidden = baseline.boolValue;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view,
                                 YTzoomNavigationHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTzoomIsMessagesToken(NSString *token) {
    return [token containsString:@"id.connections.inbox.button"] ||
        [token containsString:@"connectionsinboxbutton"] ||
        [token containsString:@"connections_inbox"] ||
        [token containsString:@"messages_inbox"] ||
        [token containsString:@"messagebutton"] ||
        [token containsString:@"messages button"] ||
        [token containsString:@"chatbutton"] ||
        [token containsString:@"inboxbutton"];
}

static id YTzoomNavigationButton(id receiver, SEL selector) {
    IMP original = YTzoomNavigationOriginal(receiver, selector);
    id value = original == NULL
        ? nil
        : ((id (*)(id, SEL))original)(receiver, selector);
    if ([value isKindOfClass:UIView.class]) {
        NSString *selectorName = NSStringFromSelector(selector).lowercaseString;
        BOOL messages = YTzoomIsMessagesToken(selectorName) ||
            [selectorName isEqualToString:@"connectionsbutton"] ||
            [selectorName isEqualToString:@"messagesbutton"] ||
            [selectorName isEqualToString:@"messagebutton"] ||
            [selectorName isEqualToString:@"chatbutton"] ||
            [selectorName isEqualToString:@"inboxbutton"];
        YTzoomSetNavigationHidden(
            value,
            YTzoomFeatureEnabled(messages
                ? @"YTzoom.Preference.Navigation.MessagesHidden"
                : @"YTzoom.Preference.Navigation.NotificationsHidden")
        );
    }
    return value;
}

static void YTzoomInstallNavigationMethodHooks(void) {
    if (YTzoomNavigationOriginals == nil) {
        YTzoomNavigationOriginals = [NSMutableDictionary dictionary];
    }
    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *cacheKey =
        [@"YTzoomNavigationHookTargets." stringByAppendingString:version];
    NSDictionary<NSString *, NSValue *> *replacements = @{
        @"notificationButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"newNotificationButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"connectionsButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"messagesButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"messageButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"chatButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton),
        @"inboxButton":
            YTzoomNavigationIMPValue((IMP)YTzoomNavigationButton)
    };
    void (^applyTargets)(NSArray<NSString *> *) =
        ^(NSArray<NSString *> *targets) {
            for (NSString *target in targets) {
                NSArray<NSString *> *parts =
                    [target componentsSeparatedByString:@"|"];
                if (parts.count != 2) continue;
                Class cls = NSClassFromString(parts[0]);
                SEL selector = NSSelectorFromString(parts[1]);
                Method method = class_getInstanceMethod(cls, selector);
                NSValue *replacement = replacements[parts[1]];
                if (method == NULL || replacement == nil) continue;
                IMP hook = YTzoomNavigationIMP(replacement);
                IMP original = method_getImplementation(method);
                if (original == hook) continue;
                YTzoomNavigationOriginals[
                    YTzoomNavigationHookKey(cls, selector)
                ] = YTzoomNavigationIMPValue(original);
                method_setImplementation(method, hook);
            }
        };
    applyTargets([NSUserDefaults.standardUserDefaults arrayForKey:cacheKey]);
}

static void YTzoomDiscoverNavigationMethodHooks(void) {
    NSSet<NSString *> *selectors = [NSSet setWithArray:@[
        @"notificationButton",
        @"newNotificationButton",
        @"connectionsButton",
        @"messagesButton",
        @"messageButton",
        @"chatButton",
        @"inboxButton"
    ]];
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *scanName in YTzoomAppClassNames()) {
        Class cls = NSClassFromString(scanName);
        if (cls == Nil) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0; methodIndex < methodCount; methodIndex++) {
            Method method = methods[methodIndex];
            SEL selector = method_getName(method);
            NSString *selectorName = NSStringFromSelector(selector);
            if (![selectors containsObject:selectorName]) continue;
            [targets addObject:[NSString stringWithFormat:@"%@|%@",
                NSStringFromClass(cls), selectorName]];
        }
        free(methods);
    }

    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    NSString *cacheKey =
        [@"YTzoomNavigationHookTargets." stringByAppendingString:version];
    NSArray<NSString *> *result = targets.array;
    [NSUserDefaults.standardUserDefaults setObject:result forKey:cacheKey];
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomInstallNavigationMethodHooks();
        YTzoomApplyNavigationWindows();
    });
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

static BOOL YTzoomNavigationShouldHide(UIView *view) {
    if (!YTzoomIsNavigationIcon(view)) return NO;
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@",
                        NSStringFromClass(view.class),
                        view.accessibilityIdentifier ?: @"",
                        view.accessibilityLabel ?: @""] lowercaseString];
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.AccountHidden") &&
        ([token containsString:@"account"] ||
         [token containsString:@"avatar"] ||
         [token containsString:@"profile"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.SearchHidden") &&
        [token containsString:@"search"]) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.CastHidden") &&
        ([token containsString:@"cast"] ||
         [token containsString:@"airplay"] ||
         [token containsString:@"routebutton"] ||
         YTzoomMatchesAncestorButton(view, @"MDXButton"))) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.NotificationsHidden") &&
        ([token containsString:@"notification"] ||
         [token containsString:@"bell"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.MessagesHidden") &&
        YTzoomInsideRightNavigation(view) && YTzoomIsMessagesToken(token)) {
        return YES;
    }
    return NO;
}

static BOOL YTzoomIsNavigationIcon(UIView *view) {
    NSString *token = [[NSString stringWithFormat:@"%@ %@ %@",
                        NSStringFromClass(view.class),
                        view.accessibilityIdentifier ?: @"",
                        view.accessibilityLabel ?: @""] lowercaseString];
    if ([token containsString:@"account"] ||
        [token containsString:@"avatar"] ||
        [token containsString:@"profile"] ||
        [token containsString:@"logo"]) return NO;
    if ([token containsString:@"notification"] ||
        [token containsString:@"bell"] ||
        [token containsString:@"search"] ||
        [token containsString:@"cast"] ||
        [token containsString:@"airplay"] ||
        [token containsString:@"routebutton"] ||
        (YTzoomInsideRightNavigation(view) && YTzoomIsMessagesToken(token))) {
        return YES;
    }
    if (![view isKindOfClass:UIButton.class] &&
        ![view isKindOfClass:UIImageView.class]) return NO;
    for (UIView *ancestor = view.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        NSString *name = NSStringFromClass(ancestor.class).lowercaseString;
        if ([name containsString:@"rightnavigation"] ||
            [name containsString:@"headernavigation"] ||
            [name containsString:@"topbar"]) return YES;
    }
    return NO;
}

static UIColor *YTzoomNavigationForeground(UIView *view) {
    if (YTzoomInsideRightNavigation(view)) {
        UIUserInterfaceStyle style = YTzoomNavigationStyle;
        if (style == UIUserInterfaceStyleUnspecified) {
            style = view.window.traitCollection.userInterfaceStyle;
        }
        if (style == UIUserInterfaceStyleUnspecified) {
            style = view.traitCollection.userInterfaceStyle;
        }
        return style == UIUserInterfaceStyleDark
            ? UIColor.whiteColor : UIColor.blackColor;
    }
    for (UIView *current = view.superview; current != nil;
         current = current.superview) {
        UIColor *resolved = [current.backgroundColor
            resolvedColorWithTraitCollection:view.traitCollection];
        CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
        if ([resolved getRed:&red green:&green blue:&blue alpha:&alpha] &&
            alpha > 0.5) {
            CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            return luminance < 0.5 ? UIColor.whiteColor : UIColor.blackColor;
        }
    }
    return view.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
        ? UIColor.whiteColor : UIColor.blackColor;
}

static BOOL YTzoomInsideRightNavigation(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class)
                isEqualToString:@"YTRightNavigationButtons"]) return YES;
    }
    return NO;
}

static void YTzoomApplyNavigationTint(UIView *view, UIColor *color) {
    view.tintColor = color;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        for (NSNumber *stateValue in @[@(UIControlStateNormal),
                                        @(UIControlStateHighlighted),
                                        @(UIControlStateSelected)]) {
            UIControlState state = (UIControlState)stateValue.unsignedIntegerValue;
            UIImage *image = [button imageForState:state];
            if (image != nil) {
                [button setImage:[image imageWithRenderingMode:
                    UIImageRenderingModeAlwaysTemplate] forState:state];
            }
        }
    } else if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        if (imageView.image != nil) {
            imageView.image = [imageView.image imageWithRenderingMode:
                UIImageRenderingModeAlwaysTemplate];
        }
    }
    for (UIView *subview in view.subviews) {
        YTzoomApplyNavigationTint(subview, color);
    }
}

static void YTzoomApplyNavigationTree(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTRightNavigationButtons"]) {
        YTzoomApplyNavigationSelectors(view);
    }
    YTzoomSetNavigationHidden(view, YTzoomNavigationShouldHide(view));
    if (YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomIsNavigationIcon(view)) {
        YTzoomApplyNavigationTint(view, YTzoomNavigationForeground(view));
    }
    for (UIView *subview in view.subviews) {
        YTzoomApplyNavigationTree(subview);
    }
}

void YTzoomRefreshNavigationAppearance(void) {
    if (!YTzoomFeatureEnabled(YTzoomOLEDKey)) return;
    YTzoomApplyNavigationWindows();
    for (UIView *owner in YTzoomNavigationOwners.allObjects) {
        YTzoomApplyNavigationSelectors(owner);
    }
}

static void YTzoomApplyNavigationWindows(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] ||
            scene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) YTzoomApplyNavigationTree(window);
        }
    }
}

static UIView *YTzoomNavigationValue(id owner, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if ([owner respondsToSelector:selector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(owner, selector);
        if ([value isKindOfClass:UIView.class]) return value;
    }
    @try {
        id value = [owner valueForKey:name];
        return [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void YTzoomApplyNavigationSelectors(id owner) {
    NSDictionary<NSString *, NSArray<NSString *> *> *groups = @{
        @"YTzoom.Preference.Navigation.NotificationsHidden": @[
            @"notificationButton", @"newNotificationButton",
            @"notificationBellButton", @"notificationBellView"
        ],
        @"YTzoom.Preference.Navigation.MessagesHidden": @[
            @"connectionsButton", @"messagesButton", @"messageButton",
            @"chatButton", @"inboxButton"
        ],
        @"YTzoom.Preference.Navigation.SearchHidden": @[@"searchButton"],
        @"YTzoom.Preference.Navigation.CastHidden": @[@"castButton", @"MDXButton"],
        @"YTzoom.Preference.Navigation.AccountHidden": @[@"accountButton", @"avatarButton"]
    };
    for (NSString *key in groups) {
        BOOL hidden = YTzoomFeatureEnabled(key);
        for (NSString *name in groups[key]) {
            UIView *target = YTzoomNavigationValue(owner, name);
            YTzoomSetNavigationHidden(target, hidden);
            if (target != nil && !hidden &&
                YTzoomFeatureEnabled(YTzoomOLEDKey)) {
                YTzoomApplyNavigationTint(
                    target, YTzoomNavigationForeground(target));
            }
        }
    }
}

void YTzoomApplyRightNavigationVisibility(UIView *view) {
    if (YTzoomNavigationOwners == nil) {
        YTzoomNavigationOwners = [NSHashTable weakObjectsHashTable];
    }
    [YTzoomNavigationOwners addObject:view];
    YTzoomApplyNavigationSelectors(view);
    YTzoomApplyNavigationTree(view);
}

static void YTzoomHeaderLogoLayout(UIView *receiver, SEL selector) {
    if (OriginalHeaderLogoLayout != NULL) {
        ((void (*)(id, SEL))OriginalHeaderLogoLayout)(receiver, selector);
    }
    YTzoomSetNavigationHidden(
        receiver,
        YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.LogoHidden")
    );
}

static void YTzoomLogoViewLayout(UIView *receiver, SEL selector) {
    if (OriginalLogoViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalLogoViewLayout)(receiver, selector);
    }
    YTzoomSetNavigationHidden(
        receiver,
        YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.LogoHidden")
    );
}

static void YTzoomHeaderLogoSetHidden(UIView *receiver,
                                      SEL selector,
                                      BOOL hidden) {
    if (hidden || !YTzoomFeatureEnabled(
            @"YTzoom.Preference.Navigation.LogoHidden")) {
        if (OriginalHeaderLogoSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalHeaderLogoSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalHeaderLogoSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalHeaderLogoSetHidden)(
            receiver, selector, YES);
    }
}

static void YTzoomLogoViewSetHidden(UIView *receiver,
                                    SEL selector,
                                    BOOL hidden) {
    if (hidden || !YTzoomFeatureEnabled(
            @"YTzoom.Preference.Navigation.LogoHidden")) {
        if (OriginalLogoViewSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalLogoViewSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalLogoViewSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalLogoViewSetHidden)(
            receiver, selector, YES);
    }
}

static void YTzoomYTImageSetHidden(UIView *receiver,
                                   SEL selector,
                                   BOOL hidden) {
    NSString *label = receiver.accessibilityLabel;
    if (hidden ||
        (![receiver.accessibilityIdentifier isEqualToString:@"id.youtube.logo"] &&
         !(label.length != 0 &&
           [label caseInsensitiveCompare:@"YouTube"] == NSOrderedSame)) ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.LogoHidden")) {
        if (OriginalYTImageSetHidden != NULL) {
            ((void (*)(id, SEL, BOOL))OriginalYTImageSetHidden)(
                receiver, selector, hidden);
        }
        return;
    }
    if (OriginalYTImageSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalYTImageSetHidden)(
            receiver, selector, YES);
    }
}

static void YTzoomQTMButtonLayout(UIView *receiver, SEL selector) {
    if (OriginalQTMButtonLayout != NULL) {
        ((void (*)(id, SEL))OriginalQTMButtonLayout)(receiver, selector);
    }
    NSString *label = receiver.accessibilityLabel.lowercaseString;
    if ([label isEqualToString:@"notifications"] ||
        [label isEqualToString:@"notification"]) {
        YTzoomSetNavigationHidden(
            receiver,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.NotificationsHidden")
        );
    } else if ([label isEqualToString:@"messages"] ||
               [label isEqualToString:@"message"] ||
               [label isEqualToString:@"chat"] ||
               [label isEqualToString:@"inbox"] ||
               [receiver.accessibilityIdentifier.lowercaseString
                   isEqualToString:@"id.connections.inbox.button"]) {
        YTzoomSetNavigationHidden(
            receiver,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.MessagesHidden")
        );
    } else if ([label isEqualToString:@"search"] ||
               [receiver.accessibilityIdentifier
                   isEqualToString:@"id.ui.navigation.search.button"]) {
        YTzoomSetNavigationHidden(
            receiver,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.SearchHidden")
        );
    }
    if (YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomIsNavigationIcon(receiver)) {
        YTzoomApplyNavigationTint(receiver,
                                  YTzoomNavigationForeground(receiver));
    }
}

static void YTzoomQTMButtonSetTint(UIView *receiver,
                                   SEL selector,
                                   UIColor *color) {
    if (YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomInsideRightNavigation(receiver)) {
        color = YTzoomNavigationForeground(receiver);
    }
    if (OriginalQTMButtonSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalQTMButtonSetTint)(
            receiver, selector, color);
    }
}

static void YTzoomNavigationImageSetTint(UIView *receiver,
                                         SEL selector,
                                         UIColor *color) {
    if (YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomInsideRightNavigation(receiver)) {
        color = YTzoomNavigationForeground(receiver);
    }
    if (OriginalNavigationImageSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetTint)(
            receiver, selector, color);
    }
}

static void YTzoomQTMButtonSetImage(UIButton *receiver,
                                    SEL selector,
                                    UIImage *image,
                                    UIControlState state) {
    BOOL styled = YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomInsideRightNavigation(receiver);
    if (styled && image != nil) {
        image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    if (OriginalQTMButtonSetImage != NULL) {
        ((void (*)(id, SEL, id, UIControlState))OriginalQTMButtonSetImage)(
            receiver, selector, image, state);
    }
    if (styled && OriginalQTMButtonSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalQTMButtonSetTint)(
            receiver, @selector(setTintColor:),
            YTzoomNavigationForeground(receiver));
    }
}

static void YTzoomNavigationImageSetImage(UIImageView *receiver,
                                          SEL selector,
                                          UIImage *image) {
    BOOL styled = YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        YTzoomInsideRightNavigation(receiver);
    if (styled && image != nil) {
        image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    if (OriginalNavigationImageSetImage != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetImage)(
            receiver, selector, image);
    }
    if (styled && OriginalNavigationImageSetTint != NULL) {
        ((void (*)(id, SEL, id))OriginalNavigationImageSetTint)(
            receiver, @selector(setTintColor:),
            YTzoomNavigationForeground(receiver));
    }
}

static void YTzoomMainWindowTraitChanged(UIWindow *receiver,
                                         SEL selector,
                                         UITraitCollection *previous) {
    if (OriginalMainWindowTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalMainWindowTraitChanged)(
            receiver, selector, previous);
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified ||
        style == previous.userInterfaceStyle) return;
    YTzoomNavigationStyle = style;
    if (YTzoomFeatureEnabled(YTzoomOLEDKey)) {
        YTzoomRefreshNavigationAppearance();
    }
}

static void YTzoomRightNavigationTraitChanged(UIView *receiver,
                                              SEL selector,
                                              UITraitCollection *previous) {
    if (OriginalRightNavigationTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalRightNavigationTraitChanged)(
            receiver, selector, previous);
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style != UIUserInterfaceStyleUnspecified) {
        YTzoomNavigationStyle = style;
    }
    if (YTzoomFeatureEnabled(YTzoomOLEDKey)) {
        YTzoomApplyRightNavigationVisibility(receiver);
    }
}

static void YTzoomYTImageViewLayout(UIView *receiver, SEL selector) {
    if (OriginalYTImageViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalYTImageViewLayout)(receiver, selector);
    }
    NSString *label = receiver.accessibilityLabel;
    if ([receiver.accessibilityIdentifier isEqualToString:@"id.youtube.logo"] ||
        (label.length != 0 &&
         [label caseInsensitiveCompare:@"YouTube"] == NSOrderedSame)) {
        YTzoomSetNavigationHidden(
            receiver,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.LogoHidden")
        );
    }
}

void YTzoomInstallNavigationVisibilityHooks(void) {
    YTzoomInstallNavigationMethodHooks();
    YTzoomInstallInstanceHook(@"YTHeaderLogoView",
                              @"layoutSubviews",
                              (IMP)YTzoomHeaderLogoLayout,
                              &OriginalHeaderLogoLayout);
    YTzoomInstallInstanceHook(@"YTHeaderLogoView",
                              @"setHidden:",
                              (IMP)YTzoomHeaderLogoSetHidden,
                              &OriginalHeaderLogoSetHidden);
    YTzoomInstallInstanceHook(@"YTLogoView",
                              @"layoutSubviews",
                              (IMP)YTzoomLogoViewLayout,
                              &OriginalLogoViewLayout);
    YTzoomInstallInstanceHook(@"YTLogoView",
                              @"setHidden:",
                              (IMP)YTzoomLogoViewSetHidden,
                              &OriginalLogoViewSetHidden);
    YTzoomInstallInstanceHook(@"YTQTMButton",
                              @"layoutSubviews",
                              (IMP)YTzoomQTMButtonLayout,
                              &OriginalQTMButtonLayout);
    YTzoomInstallInstanceHook(@"YTQTMButton",
                              @"setTintColor:",
                              (IMP)YTzoomQTMButtonSetTint,
                              &OriginalQTMButtonSetTint);
    YTzoomInstallInstanceHook(@"YTQTMButton",
                              @"setImage:forState:",
                              (IMP)YTzoomQTMButtonSetImage,
                              &OriginalQTMButtonSetImage);
    YTzoomInstallInstanceHook(@"UIImageView",
                              @"setTintColor:",
                              (IMP)YTzoomNavigationImageSetTint,
                              &OriginalNavigationImageSetTint);
    YTzoomInstallInstanceHook(@"UIImageView",
                              @"setImage:",
                              (IMP)YTzoomNavigationImageSetImage,
                              &OriginalNavigationImageSetImage);
    YTzoomInstallInstanceHook(@"YTImageView",
                              @"layoutSubviews",
                              (IMP)YTzoomYTImageViewLayout,
                              &OriginalYTImageViewLayout);
    YTzoomInstallInstanceHook(@"YTImageView",
                              @"setHidden:",
                              (IMP)YTzoomYTImageSetHidden,
                              &OriginalYTImageSetHidden);
    YTzoomInstallInstanceHook(@"YTMainWindow",
                              @"traitCollectionDidChange:",
                              (IMP)YTzoomMainWindowTraitChanged,
                              &OriginalMainWindowTraitChanged);
    YTzoomInstallInstanceHook(@"YTRightNavigationButtons",
                              @"traitCollectionDidChange:",
                              (IMP)YTzoomRightNavigationTraitChanged,
                              &OriginalRightNavigationTraitChanged);
    YTzoomApplyNavigationWindows();
    if (!YTzoomNavigationObserverInstalled) {
        YTzoomNavigationObserverInstalled = YES;
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                NSString *version = NSBundle.mainBundle
                    .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
                NSString *cacheKey = [@"YTzoomNavigationHookTargets."
                    stringByAppendingString:version];
                if ([NSUserDefaults.standardUserDefaults
                        arrayForKey:cacheKey].count == 0) {
                    static dispatch_once_t discoveryToken;
                    dispatch_once(&discoveryToken, ^{
                        dispatch_async(
                            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                                YTzoomDiscoverNavigationMethodHooks();
                            }
                        );
                    });
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        YTzoomApplyNavigationWindows();
                    });
            }];
    }
}
