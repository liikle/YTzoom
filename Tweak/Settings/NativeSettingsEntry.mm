#import "YTzoomSettingsPages.h"
#import "YTzoomSettingsSearch.h"
#import "../Runtime/Localization.h"
#import "YTzoomRootOptionsController.h"
#import "YTzoomDownloadsController.h"
#import "../Runtime/Hooking.h"
#import "../UI/Assets.h"
#import "../YTzoom.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const NSUInteger YTzoomNativeSettingsCategory = 0x796b6361;
static const NSUInteger YTzoomNativeSettingsGroup = 0x796b6163;
static NSString *const YTzoomInertIdentifier = @"YTzoomInertItem";
static const NSInteger YTzoomSearchFieldTag = 0x5954534B;
static const void *YTzoomDeveloperHoldKey = &YTzoomDeveloperHoldKey;
static const void *YTzoomSettingIconImageKey = &YTzoomSettingIconImageKey;
static IMP OriginalSettingsCategoryOrder;
static IMP OriginalUpdateSettingsSection;
static IMP OriginalOrderedSettingsGroups;
static IMP OriginalSettingsGroupTitle;
static IMP OriginalOrderedGroupCategories;
static IMP OriginalSettingsCellLayout;

typedef UIViewController * _Nonnull (^YTzoomNativeBuilder)(void);

static NSArray<NSDictionary *> *YTzoomNativeLayout(void) {
    NSMutableArray *layout = [NSMutableArray arrayWithArray:@[
        @{@"kind": @"search"},
        @{@"kind": @"row", @"title": @"Downloads & Library"}
    ]];
    for (NSDictionary *section in YTzoomSettingsMenu()) {
        [layout addObject:@{@"kind": @"header", @"title": section[@"header"]}];
        for (NSDictionary *row in section[@"rows"]) {
            [layout addObject:@{@"kind": @"row", @"title": row[@"title"], @"id": row[@"id"]}];
        }
    }
    [layout addObjectsFromArray:@[
        @{@"kind": @"header", @"title": @"ABOUT"},
        @{@"kind": @"row", @"title": @"itzzace", @"developer": @YES},
        @{@"kind": @"footer"}
    ]];
    return layout;
}

static NSDictionary *YTzoomNativeMenuRow(NSString *title) {
    for (NSDictionary *section in YTzoomSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            if ([row[@"title"] isEqualToString:title]) return row;
        }
    }
    return nil;
}

static NSArray *YTzoomSettingsCategoryOrder(id receiver, SEL selector) {
    NSArray *order = OriginalSettingsCategoryOrder == NULL ? @[] :
        ((id (*)(id, SEL))OriginalSettingsCategoryOrder)(receiver, selector);
    if ([order containsObject:@(YTzoomNativeSettingsCategory)]) return order;
    NSMutableArray *updated = [order mutableCopy] ?: [NSMutableArray array];
    NSUInteger index = [updated indexOfObject:@1];
    [updated insertObject:@(YTzoomNativeSettingsCategory)
                  atIndex:index == NSNotFound ? updated.count : index + 1];
    return updated;
}

static NSArray *YTzoomOrderedSettingsGroups(id receiver, SEL selector) {
    NSArray *groups = OriginalOrderedSettingsGroups == NULL ? @[] :
        ((id (*)(id, SEL))OriginalOrderedSettingsGroups)(receiver, selector);
    Class groupClass = NSClassFromString(@"YTSettingsGroupData");
    SEL initializer = NSSelectorFromString(@"initWithGroupType:");
    if (groupClass == Nil || ![groupClass instancesRespondToSelector:initializer]) return groups;
    id group = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(
        [groupClass alloc], initializer, YTzoomNativeSettingsGroup);
    if (group == nil) return groups;
    NSMutableArray *updated = [groups mutableCopy] ?: [NSMutableArray array];
    [updated insertObject:group atIndex:0];
    return updated;
}

static NSString *YTzoomSettingsGroupTitle(id receiver, SEL selector, NSUInteger type) {
    if (type == YTzoomNativeSettingsGroup) return @"YTzoom";
    return OriginalSettingsGroupTitle == NULL ? nil :
        ((id (*)(id, SEL, NSUInteger))OriginalSettingsGroupTitle)(receiver, selector, type);
}

static NSArray *YTzoomOrderedGroupCategories(id receiver, SEL selector, NSUInteger type) {
    if (type == YTzoomNativeSettingsGroup) return @[@(YTzoomNativeSettingsCategory)];
    return OriginalOrderedGroupCategories == NULL ? @[] :
        ((id (*)(id, SEL, NSUInteger))OriginalOrderedGroupCategories)(receiver, selector, type);
}

static NSString *YTzoomNativeSettingsSubtitle(NSString *title) {
    NSString *value = YTzoomNativeMenuRow(title)[@"detail"];
    if ([title isEqualToString:@"Downloads & Library"]) value = @"Saved video, audio, Shorts, imports and backups";
    if ([title isEqualToString:@"itzzace"]) value = @"Developer";
    return value != nil ? YTzoomLocalized(value) : nil;
}

static UIImage *YTzoomSettingIconStoredImage(id receiver) {
    return objc_getAssociatedObject(receiver, YTzoomSettingIconImageKey);
}

static UIImage *YTzoomTintedIcon(UIImage *image, UIColor *color) {
    if (image == nil) return nil;
    UIColor *fill = color ?: UIColor.labelColor;
    UIGraphicsImageRendererFormat *format =
        UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:image.size format:format];
    UIImage *tinted = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        CGRect bounds = CGRectMake(0.0, 0.0, image.size.width, image.size.height);
        [image drawInRect:bounds];
        [fill set];
        UIRectFillUsingBlendMode(bounds, kCGBlendModeSourceIn);
    }];
    return [tinted imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

static id YTzoomIconImageForStyle(id receiver, SEL selector, long long style) {
    (void)selector;
    (void)style;
    return YTzoomTintedIcon(YTzoomSettingIconStoredImage(receiver), nil);
}

static id YTzoomIconImageForColor(id receiver, SEL selector, UIColor *color) {
    (void)selector;
    return YTzoomTintedIcon(YTzoomSettingIconStoredImage(receiver), color);
}

static id YTzoomIconImageForSelected(id receiver, SEL selector, BOOL selected) {
    (void)selector;
    (void)selected;
    return YTzoomTintedIcon(YTzoomSettingIconStoredImage(receiver), nil);
}

static id YTzoomIconImagePlain(id receiver, SEL selector) {
    (void)selector;
    return YTzoomTintedIcon(YTzoomSettingIconStoredImage(receiver), nil);
}

static Class YTzoomSettingIconClass(void) {
    static Class iconClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class superclass = NSClassFromString(@"YTIIcon");
        if (superclass == Nil) return;
        iconClass = objc_allocateClassPair(superclass, "YTzoomSettingIcon", 0);
        if (iconClass == Nil) return;
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithPageStyle:"),
                        (IMP)YTzoomIconImageForStyle, "@24@0:8q16");
        class_addMethod(iconClass, NSSelectorFromString(@"delhiIconImageWithPageStyle:"),
                        (IMP)YTzoomIconImageForStyle, "@24@0:8q16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithColor:"),
                        (IMP)YTzoomIconImageForColor, "@24@0:8@16");
        class_addMethod(iconClass, NSSelectorFromString(@"newIconImageWithColor:"),
                        (IMP)YTzoomIconImageForColor, "@24@0:8@16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageWithSelected:"),
                        (IMP)YTzoomIconImageForSelected, "@20@0:8B16");
        class_addMethod(iconClass, NSSelectorFromString(@"delhiIconImageWithSelected:"),
                        (IMP)YTzoomIconImageForSelected, "@20@0:8B16");
        class_addMethod(iconClass, NSSelectorFromString(@"iconImageForContextMenu"),
                        (IMP)YTzoomIconImagePlain, "@16@0:8");
        objc_registerClassPair(iconClass);
    });
    return iconClass;
}

static UIImage *YTzoomNativeSettingsIconImage(NSString *title) {
    if ([title isEqualToString:@"SponsorBlock"]) {
        return YTzoomAssetImage(@"sponsorblock_shield_template", @"play.shield");
    }
    if ([title isEqualToString:@"Shorts"]) return YTzoomShortsImage(NO);
    if ([title isEqualToString:@"Downloads & Library"]) {
        return YTzoomDownloadTabImage(NO);
    }
    NSString *symbol = [title isEqualToString:@"itzzace"] ? @"person.crop.circle" : YTzoomNativeMenuRow(title)[@"symbol"];
    return symbol.length != 0 ? [UIImage systemImageNamed:symbol] : nil;
}

static UIImage *YTzoomSquaredIcon(UIImage *image) {
    if (image == nil) return nil;
    CGFloat side = MAX(image.size.width, image.size.height);
    if (side <= 0.0) return image;
    UIGraphicsImageRendererFormat *format =
        UIGraphicsImageRendererFormat.preferredFormat;
    format.opaque = NO;
    format.scale = image.scale;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)
                                               format:format];
    UIImage *padded = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [image drawInRect:CGRectMake((side - image.size.width) / 2.0,
                                     (side - image.size.height) / 2.0,
                                     image.size.width, image.size.height)];
    }];
    return [padded imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static void YTzoomApplyNativeSettingsIcon(id item, NSString *title) {
    SEL setSettingIcon = NSSelectorFromString(@"setSettingIcon:");
    if (item == nil || ![item respondsToSelector:setSettingIcon]) return;
    Class iconClass = YTzoomSettingIconClass();
    UIImage *image = YTzoomSquaredIcon(YTzoomNativeSettingsIconImage(title));
    if (iconClass == Nil || image == nil) return;
    id icon = [iconClass new];
    objc_setAssociatedObject(icon, YTzoomSettingIconImageKey, image,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    ((void (*)(id, SEL, id))objc_msgSend)(item, setSettingIcon, icon);
}

static id YTzoomNativePlainItem(NSString *title, NSString *description) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    if (itemClass == Nil) return nil;
    SEL described = NSSelectorFromString(
        @"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:"
         "selectBlock:");
    if (description != nil && [itemClass respondsToSelector:described]) {
        return ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            itemClass, described, title, description,
            YTzoomInertIdentifier, nil, nil);
    }
    SEL plain = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (![itemClass respondsToSelector:plain]) return nil;
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        itemClass, plain, title, YTzoomInertIdentifier, nil, nil);
}

static void YTzoomMakeItemInert(id item) {
    if (item == nil) return;
    for (NSString *name in @[@"setInkEnabled:", @"setEnabled:", @"setSettingEnabled:"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, selector, NO);
        }
    }
}

@interface YTzoomDeveloperHoldTarget : NSObject
@property(nonatomic, weak) UIView *cell;
@end

@implementation YTzoomDeveloperHoldTarget

- (void)handleHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIResponder *responder = self.cell;
    while (responder != nil && ![responder isKindOfClass:UIViewController.class]) {
        responder = responder.nextResponder;
    }
    UINavigationController *navigation =
        ((UIViewController *)responder).navigationController;
    if (navigation == nil) return;
    [navigation pushViewController:YTzoomMakeDownloadLogController() animated:YES];
}

@end

static void YTzoomSettingsCellLayout(id receiver, SEL selector) {
    if (OriginalSettingsCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalSettingsCellLayout)(receiver, selector);
    }
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *cell = receiver;
    NSString *identifier = cell.accessibilityIdentifier;
    UIView *host = cell;
    if ([cell respondsToSelector:@selector(contentView)]) {
        UIView *content = ((UIView *(*)(id, SEL))objc_msgSend)(
            cell, @selector(contentView));
        if (content != nil) host = content;
    }
    UISearchBar *field = (UISearchBar *)[host viewWithTag:YTzoomSearchFieldTag];
    if ([identifier isEqualToString:@"YTzoomSearchItem"]) {
        if (field == nil) {
            field = [UISearchBar new];
            field.tag = YTzoomSearchFieldTag;
            field.placeholder = YTzoomLocalized(@"Search");
            field.searchBarStyle = UISearchBarStyleMinimal;
            field.userInteractionEnabled = NO;
            [host addSubview:field];
        }
        field.frame = CGRectInset(host.bounds, -8.0, 0.0);
        [host bringSubviewToFront:field];
        cell.userInteractionEnabled = YES;
        return;
    }
    if (field != nil) [field removeFromSuperview];
    if ([identifier isEqualToString:@"YTzoomDeveloperItem"] &&
        objc_getAssociatedObject(cell, YTzoomDeveloperHoldKey) == nil) {
        YTzoomDeveloperHoldTarget *target = [YTzoomDeveloperHoldTarget new];
        target.cell = cell;
        UILongPressGestureRecognizer *hold =
            [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                          action:@selector(handleHold:)];
        hold.minimumPressDuration = 4.0;
        [cell addGestureRecognizer:hold];
        objc_setAssociatedObject(cell, YTzoomDeveloperHoldKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    cell.userInteractionEnabled = ![identifier isEqualToString:YTzoomInertIdentifier];
}

static id YTzoomNativeSearchRow(id settingsController) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL plain = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:plain]) return nil;
    __weak id weakController = settingsController;
    BOOL (^select)(id, NSUInteger) = ^BOOL(__unused id cell, __unused NSUInteger index) {
        id controller = weakController;
        if (![controller isKindOfClass:UIViewController.class]) return NO;
        YTzoomPresentSettingsSearchOverlay(controller);
        return YES;
    };
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        itemClass, plain, @" ", @"YTzoomSearchItem", nil, [select copy]);
}

static id YTzoomNativeSettingsItem(NSString *title,
                                   id settingsController,
                                   YTzoomNativeBuilder builder) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL selector = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:selector]) return nil;
    NSString *(^detail)(void) = builder == nil
        ? (NSString *(^)(void))nil
        : ^NSString *{ return @"›"; };
    BOOL (^select)(id, NSUInteger) = builder == nil
        ? (BOOL (^)(id, NSUInteger))nil
        : ^BOOL(__unused id cell, __unused NSUInteger index) {
            UIViewController *controller = builder();
            if (controller == nil) return NO;
            SEL push = NSSelectorFromString(@"pushViewController:");
            if ([settingsController respondsToSelector:push]) {
                ((void (*)(id, SEL, id))objc_msgSend)(settingsController, push, controller);
                return YES;
            }
            UINavigationController *navigation =
                [settingsController isKindOfClass:UIViewController.class]
                    ? ((UIViewController *)settingsController).navigationController : nil;
            [navigation pushViewController:controller animated:YES];
            return navigation != nil;
        };
    SEL described = NSSelectorFromString(
        @"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:"
         "selectBlock:");
    NSString *subtitle = YTzoomNativeSettingsSubtitle(title);
    NSString *localizedTitle = YTzoomLocalized(title);
    id item = nil;
    if (subtitle.length != 0 && [itemClass respondsToSelector:described]) {
        item = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
            itemClass, described, localizedTitle, subtitle,
            @"YTzoomNativeSettingsItem", detail, select);
    } else {
        item = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            itemClass, selector, localizedTitle, @"YTzoomNativeSettingsItem",
            detail, select);
    }
    YTzoomApplyNativeSettingsIcon(item, title);
    return item;
}

static void YTzoomUpdateNativeSettingsSection(id receiver, SEL selector,
                                              NSUInteger category, id entry) {
    if (category != YTzoomNativeSettingsCategory) {
        if (OriginalUpdateSettingsSection != NULL) {
            ((void (*)(id, SEL, NSUInteger, id))OriginalUpdateSettingsSection)(
                receiver, selector, category, entry);
        }
        return;
    }

    id settingsController = nil;
    @try {
        settingsController = [receiver valueForKey:@"_settingsViewControllerDelegate"];
    } @catch (__unused NSException *exception) {
        return;
    }
    NSMutableDictionary<NSString *, YTzoomNativeBuilder> *builders = [@{
        @"Downloads & Library": [^UIViewController *{
            YTzoomDownloadsController *controller = [YTzoomDownloadsController new];
            controller.hidesSettingsButton = YES;
            return controller;
        } copy],
        @"itzzace": [^UIViewController *{
            NSURL *URL = [NSURL URLWithString:@"https://github.com/liikle/ytzoom"];
            [UIApplication.sharedApplication openURL:URL options:@{}
                                   completionHandler:nil];
            return nil;
        } copy]
    } mutableCopy];
    for (NSDictionary *section in YTzoomSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            NSString *pageID = row[@"id"];
            builders[row[@"title"]] = [^UIViewController *{ return YTzoomMakeSettingsPage(pageID); } copy];
        }
    }

    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *definition in YTzoomNativeLayout()) {
        NSString *kind = definition[@"kind"];
        NSString *title = definition[@"title"];
        id item = nil;
        if ([kind isEqualToString:@"search"]) {
            item = YTzoomNativeSearchRow(settingsController);
        } else if ([kind isEqualToString:@"header"]) {
            item = YTzoomNativePlainItem(nil, YTzoomLocalized(title));
            YTzoomMakeItemInert(item);
        } else if ([kind isEqualToString:@"footer"]) {
            NSString *info = [YTzoomDeviceInformationText()
                stringByReplacingOccurrencesOfString:@"\n" withString:@"  •  "];
            item = YTzoomNativePlainItem(nil, info);
            YTzoomMakeItemInert(item);
        } else {
            item = YTzoomNativeSettingsItem(title, settingsController, builders[title]);
            if ([definition[@"developer"] boolValue] && item != nil) {
                SEL setIdentifier = NSSelectorFromString(@"setAccessibilityIdentifier:");
                if ([item respondsToSelector:setIdentifier]) {
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        item, setIdentifier, @"YTzoomDeveloperItem");
                }
            }
        }
        if (item != nil) [items addObject:item];
    }

    SEL modern = NSSelectorFromString(
        @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
    SEL legacy = NSSelectorFromString(
        @"setSectionItems:forCategory:title:titleDescription:headerHidden:");
    if ([settingsController respondsToSelector:modern]) {
        id icon = [NSClassFromString(@"YTIIcon") new];
        SEL setIconType = NSSelectorFromString(@"setIconType:");
        if ([icon respondsToSelector:setIconType]) {
            ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, 44);
        }
        ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(
            settingsController, modern, items, category, @"YTzoom", icon, nil, NO);
    } else if ([settingsController respondsToSelector:legacy]) {
        ((void (*)(id, SEL, id, NSUInteger, id, id, BOOL))objc_msgSend)(
            settingsController, legacy, items, category, @"YTzoom", nil, NO);
    }
}

void YTzoomInstallNativeSettingsHooks(void) {
    YTzoomInstallClassHook(@"YTAppSettingsPresentationData", @"settingsCategoryOrder",
                           (IMP)YTzoomSettingsCategoryOrder,
                           &OriginalSettingsCategoryOrder);
    YTzoomInstallInstanceHook(@"YTSettingsSectionItemManager",
                              @"updateSectionForCategory:withEntry:",
                              (IMP)YTzoomUpdateNativeSettingsSection,
                              &OriginalUpdateSettingsSection);
    YTzoomInstallInstanceHook(@"YTSettingsCell", @"layoutSubviews",
                              (IMP)YTzoomSettingsCellLayout,
                              &OriginalSettingsCellLayout);
    YTzoomInstallClassHook(@"YTAppSettingsGroupPresentationData", @"orderedGroups",
                           (IMP)YTzoomOrderedSettingsGroups,
                           &OriginalOrderedSettingsGroups);
    YTzoomInstallInstanceHook(@"YTSettingsGroupData", @"titleForSettingGroupType:",
                              (IMP)YTzoomSettingsGroupTitle,
                              &OriginalSettingsGroupTitle);
    YTzoomInstallInstanceHook(@"YTSettingsGroupData", @"orderedCategoriesForGroupType:",
                              (IMP)YTzoomOrderedGroupCategories,
                              &OriginalOrderedGroupCategories);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (NSUInteger attempt = 1; attempt <= 60; attempt++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                (int64_t)(attempt * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                YTzoomInstallNativeSettingsHooks();
            });
        }
    });
}
