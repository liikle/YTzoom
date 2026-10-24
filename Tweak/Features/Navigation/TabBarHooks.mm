#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Settings/YTzoomDownloadsController.h"
#import "../../UI/Assets.h"
#import "../Interface/NavigationVisibility.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetPivotRenderer;
static IMP OriginalPivotItemLayout;
static IMP OriginalPivotItemSetSelected;
static IMP OriginalPivotItemTraitChanged;
static IMP OriginalPivotLabelSetHidden;
static IMP OriginalPivotLabelSetAlpha;
static IMP OriginalPivotButtonLayout;
static IMP OriginalPivotBarLayout;
static IMP OriginalPivotControllerAppear;
static IMP OriginalSetDefaultSelectedPivot;
static BOOL YTzoomStartupNative;
static IMP OriginalPivotBarStyleColors;
static IMP OriginalPivotBarSetBackgroundStyle;
static IMP OriginalAppViewDidLoad;
static IMP OriginalBrowseViewDidLoad;
static IMP OriginalBrowseResponseViewDidLoad;
static IMP OriginalWrapperViewDidLoad;
static const void *YTzoomDownloadsAssociation = &YTzoomDownloadsAssociation;
static const void *YTzoomTabAssociation = &YTzoomTabAssociation;
static const void *YTzoomTabSelectedAssociation = &YTzoomTabSelectedAssociation;
static const void *YTzoomTabDragOutAssociation = &YTzoomTabDragOutAssociation;
static BOOL YTzoomStencilRendering;
static NSString * const YTzoomPivotIdentifier = @"FEYTzoom";
static NSInteger const YTzoomExtraIconTag = 0x59414349;
static NSInteger const YTzoomExtraLabelTag = 0x5941434A;
static BOOL YTzoomStartupApplied;

static BOOL YTzoomNavigationRefreshScheduled;

static id YTzoomValue(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector)
        : nil;
}

static void YTzoomSetValue(id receiver, NSString *selectorName, id value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (receiver != nil && [receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, selector, value);
    }
}

static id YTzoomNew(NSString *className) {
    Class cls = NSClassFromString(className);
    return cls == Nil ? nil : [[cls alloc] init];
}

static id YTzoomMakePivotItem(void) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass,
            factory,
            YTzoomPivotIdentifier,
            @"YTzoom",
            77
        );
        id item = YTzoomValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            YTzoomSetValue(item, @"setPivotIdentifier:", YTzoomPivotIdentifier);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = YTzoomNew(@"YTIBrowseEndpoint");
    id command = YTzoomNew(@"YTICommand");
    id itemRenderer = YTzoomNew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = YTzoomNew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }

    YTzoomSetValue(browseEndpoint, @"setBrowseId:", YTzoomPivotIdentifier);
    YTzoomSetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    YTzoomSetValue(itemRenderer, @"setPivotIdentifier:", YTzoomPivotIdentifier);
    YTzoomSetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id title = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass,
        formattedSelector,
        @"YTzoom"
    );
    YTzoomSetValue(itemRenderer, @"setTitle:", title);

    id icon = YTzoomValue(itemRenderer, @"icon");
    SEL iconSelector = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:iconSelector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, iconSelector, 77);
    }
    YTzoomSetValue(
        supportedRenderer,
        @"setPivotBarItemRenderer:",
        itemRenderer
    );
    return supportedRenderer;
}

static id YTzoomMakeBrowsePivotItem(NSString *browseID,
                                    NSString *title,
                                    NSInteger iconType) {
    Class rendererClass = NSClassFromString(@"YTIPivotBarRenderer");
    SEL factory = NSSelectorFromString(@"pivotSupportedRenderersWithBrowseId:title:iconType:");
    if (rendererClass != Nil && [rendererClass respondsToSelector:factory]) {
        id renderer = ((id (*)(id, SEL, id, id, NSInteger))objc_msgSend)(
            rendererClass, factory, browseID, title, iconType
        );
        id item = YTzoomValue(renderer, @"pivotBarItemRenderer");
        if (item != nil) {
            YTzoomSetValue(item, @"setPivotIdentifier:", browseID);
        }
        if (renderer != nil) {
            return renderer;
        }
    }
    id browseEndpoint = YTzoomNew(@"YTIBrowseEndpoint");
    id command = YTzoomNew(@"YTICommand");
    id itemRenderer = YTzoomNew(@"YTIPivotBarItemRenderer");
    id supportedRenderer = YTzoomNew(@"YTIPivotBarSupportedRenderers");
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    if (browseEndpoint == nil || command == nil || itemRenderer == nil ||
        supportedRenderer == nil || formattedClass == Nil ||
        ![formattedClass respondsToSelector:formattedSelector]) {
        return nil;
    }
    YTzoomSetValue(browseEndpoint, @"setBrowseId:", browseID);
    YTzoomSetValue(command, @"setBrowseEndpoint:", browseEndpoint);
    YTzoomSetValue(itemRenderer, @"setPivotIdentifier:", browseID);
    YTzoomSetValue(itemRenderer, @"setNavigationEndpoint:", command);
    id icon = YTzoomValue(itemRenderer, @"icon");
    SEL setIconType = NSSelectorFromString(@"setIconType:");
    if ([icon respondsToSelector:setIconType]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(icon, setIconType, iconType);
    }
    id formatted = ((id (*)(id, SEL, id))objc_msgSend)(
        formattedClass, formattedSelector, title
    );
    YTzoomSetValue(itemRenderer, @"setTitle:", formatted);
    YTzoomSetValue(supportedRenderer, @"setPivotBarItemRenderer:", itemRenderer);
    return supportedRenderer;
}

static NSInteger YTzoomInteger(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector)
        : 0;
}

static NSString *YTzoomBrowseIdentifier(UIViewController *controller) {
    id endpoint = YTzoomValue(controller, @"navigationEndpoint");
    if (endpoint == nil) {
        endpoint = YTzoomValue(controller, @"navEndpoint");
    }
    if (endpoint == nil) {
        @try {
            endpoint = [controller valueForKey:@"_navEndpoint"];
        } @catch (__unused NSException *exception) {
        }
    }
    id browseEndpoint = YTzoomValue(endpoint, @"browseEndpoint");
    if (browseEndpoint == nil &&
        [endpoint respondsToSelector:NSSelectorFromString(@"browseId")]) {
        browseEndpoint = endpoint;
    }
    return YTzoomValue(browseEndpoint, @"browseId");
}

static void YTzoomAttachDownloads(UIViewController *controller) {
    if (!YTzoomMasterEnabled() ||
        ![YTzoomBrowseIdentifier(controller) isEqualToString:YTzoomPivotIdentifier] ||
        objc_getAssociatedObject(controller, YTzoomDownloadsAssociation) != nil) {
        return;
    }
    YTzoomDownloadsController *downloads = [YTzoomDownloadsController new];
    [controller addChildViewController:downloads];
    downloads.view.frame = controller.view.bounds;
    downloads.view.autoresizingMask = UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;
    [controller.view addSubview:downloads.view];
    [downloads didMoveToParentViewController:controller];
    objc_setAssociatedObject(controller,
                             YTzoomDownloadsAssociation,
                             downloads,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomTryAttachDownloads(UIViewController *controller) {
    YTzoomAttachDownloads(controller);
    if (objc_getAssociatedObject(controller, YTzoomDownloadsAssociation) == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomAttachDownloads(controller);
        });
    }
}

static void YTzoomAppViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalAppViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalAppViewDidLoad)(receiver, selector);
    }
    YTzoomTryAttachDownloads(receiver);
}

static void YTzoomBrowseViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalBrowseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseViewDidLoad)(receiver, selector);
    }
    YTzoomTryAttachDownloads(receiver);
}

static void YTzoomBrowseResponseViewDidLoad(UIViewController *receiver,
                                            SEL selector) {
    if (OriginalBrowseResponseViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalBrowseResponseViewDidLoad)(receiver, selector);
    }
    YTzoomTryAttachDownloads(receiver);
}

static void YTzoomWrapperViewDidLoad(UIViewController *receiver, SEL selector) {
    if (OriginalWrapperViewDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalWrapperViewDidLoad)(receiver, selector);
    }
    YTzoomTryAttachDownloads(receiver);
}

static id YTzoomTabValue(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
            if (value != nil) {
                return value;
            }
        }
    }
    return nil;
}

static NSString *YTzoomTabToken(id item) {
    for (NSString *selectorName in @[
        @"pivotIdentifier",
        @"tabIdentifier",
        @"browseId"
    ]) {
        id value = YTzoomTabValue(item, @[selectorName]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return [value lowercaseString];
        }
    }
    NSArray<NSString *> *activeRenderers =
        YTzoomInteger(item, @"hasPivotBarItemRenderer") != 0
            ? @[@"pivotBarItemRenderer"]
            : (YTzoomInteger(item, @"hasPivotBarIconOnlyItemRenderer") != 0
                ? @[@"pivotBarIconOnlyItemRenderer"]
                : @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer"]);
    for (NSString *rendererName in activeRenderers) {
        id nested = YTzoomTabValue(item, @[rendererName]);
        if (nested != nil && nested != item) {
            NSString *token = YTzoomTabToken(nested);
            if (token.length != 0) {
                return token;
            }
        }
    }
    id renderer = YTzoomTabValue(item, @[@"renderer"]);
    if (renderer != nil && renderer != item) {
        NSString *token = YTzoomTabToken(renderer);
        if (token.length != 0) {
            return token;
        }
    }
    id endpoint = YTzoomTabValue(item, @[@"navigationEndpoint", @"endpoint"]);
    id browseEndpoint = YTzoomTabValue(endpoint, @[@"browseEndpoint"]);
    id browseID = YTzoomTabValue(browseEndpoint ?: endpoint, @[@"browseId"]);
    if ([browseID isKindOfClass:NSString.class] && [browseID length] != 0) {
        return [browseID lowercaseString];
    }
    id identifier = YTzoomTabValue(item, @[@"identifier"]);
    return [identifier isKindOfClass:NSString.class]
        ? [identifier lowercaseString]
        : @"";
}

static NSMutableDictionary<NSString *, NSString *> *YTzoomStartupIdentifiers;

static NSString *YTzoomRawTabIdentifier(id item, NSUInteger depth) {
    if (item == nil || depth > 3) return nil;
    for (NSString *name in @[@"pivotIdentifier", @"tabIdentifier", @"browseId"]) {
        id value = YTzoomTabValue(item, @[name]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    for (NSString *name in @[@"pivotBarItemRenderer", @"pivotBarIconOnlyItemRenderer",
                             @"renderer", @"navigationEndpoint", @"endpoint",
                             @"browseEndpoint"]) {
        id nested = YTzoomTabValue(item, @[name]);
        if (nested == nil || nested == item) continue;
        NSString *found = YTzoomRawTabIdentifier(nested, depth + 1);
        if (found.length != 0) return found;
    }
    return nil;
}

static void YTzoomNoteStartupIdentifier(NSString *canonical, id item) {
    if (canonical.length == 0) return;
    NSString *identifier = YTzoomRawTabIdentifier(item, 0);
    if (identifier.length == 0) return;
    if (YTzoomStartupIdentifiers == nil) {
        YTzoomStartupIdentifiers = [NSMutableDictionary dictionary];
    }
    if ([YTzoomStartupIdentifiers[canonical] isEqualToString:identifier]) return;
    YTzoomStartupIdentifiers[canonical] = identifier;
    [NSUserDefaults.standardUserDefaults
        setObject:YTzoomStartupIdentifiers.allKeys
           forKey:@"YTzoom.Preference.Tabs.Known"];
}

static NSString *YTzoomHideKeyForToken(NSString *token) {
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"YTzoom.Preference.Tabs.Hidden.News";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"YTzoom.Preference.Tabs.Hidden.History";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Notifs";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"YTzoom.Preference.Tabs.Hidden.WatchLater";
    }
    if ([token containsString:@"short"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Library";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"YTzoom.Preference.Tabs.Hidden.Home";
    }
    return nil;
}

static NSString *YTzoomCanonicalTabToken(NSString *token) {
    if ([token containsString:@"uc-9-kytw8zkzndhqj6fgpwq"] ||
        [token containsString:@"music_home"]) {
        return @"music";
    }
    if ([token containsString:@"uc4r8dwomoi7cawx8_ljqhig"] ||
        [token containsString:@"trending_live"]) {
        return @"live";
    }
    if ([token containsString:@"ucopncn46ubxvtpkmrmu4abg"] ||
        [token containsString:@"gaming"]) {
        return @"gaming";
    }
    if ([token containsString:@"ucyfdidrxb8qhf0nx7iooyw"] ||
        [token containsString:@"news"]) {
        return @"news";
    }
    if ([token containsString:@"fecommunity"] ||
        [token containsString:@"communit"] ||
        [token containsString:@"post"]) {
        return @"posts";
    }
    if ([token containsString:@"ucegdi0xixxz-qjofpf4jskw"] ||
        [token containsString:@"sports"]) {
        return @"sports";
    }
    if ([token containsString:@"uctfrv9o2ahqozjjynzrv-xg"] ||
        [token containsString:@"learning"]) {
        return @"learning";
    }
    if ([token containsString:@"ucrpq4p1ql_hg8rkxikm1moq"] ||
        [token containsString:@"fashion"]) {
        return @"fashion";
    }
    if ([token containsString:@"feplaylist_aggregation"] ||
        [token containsString:@"playlist_aggregation"]) {
        return @"playlists";
    }
    if ([token containsString:@"fehistory"] ||
        [token isEqualToString:@"history"]) {
        return @"history";
    }
    if ([token containsString:@"fenotifications_inbox"] ||
        [token containsString:@"notifications_inbox"]) {
        return @"notifications";
    }
    if ([token isEqualToString:@"vlwl"] ||
        [token containsString:@"watch_later"]) {
        return @"watchlater";
    }
    if ([token containsString:@"short"] || [token containsString:@"reel"]) {
        return @"shorts";
    }
    if ([token containsString:@"subscription"]) {
        return @"subscriptions";
    }
    if ([token containsString:@"library"] ||
        [token containsString:@"you_tab"] ||
        [token isEqualToString:@"you"]) {
        return @"you";
    }
    if ([token containsString:@"create"] ||
        [token containsString:@"upload"] ||
        [token containsString:@"plus"]) {
        return @"create";
    }
    if ([token containsString:@"home"] ||
        [token containsString:@"what_to_watch"]) {
        return @"home";
    }
    return token;
}

static NSArray *YTzoomTabItems(id renderer, NSString **setterName) {
    NSArray<NSString *> *getters = @[
        @"itemsArray",
        @"items",
        @"pivotBarItemsArray",
        @"pivotBarItems"
    ];
    NSArray<NSString *> *setters = @[
        @"setItemsArray:",
        @"setItems:",
        @"setPivotBarItemsArray:",
        @"setPivotBarItems:"
    ];
    for (NSUInteger index = 0; index < getters.count; index++) {
        id value = YTzoomTabValue(renderer, @[getters[index]]);
        if ([value isKindOfClass:NSArray.class]) {
            if (setterName != NULL) {
                *setterName = setters[index];
            }
            return value;
        }
    }
    return nil;
}

static NSInteger YTzoomTabOrderIndex(NSString *token, NSArray *order) {
    NSString *canonical = YTzoomCanonicalTabToken(token);
    for (NSUInteger index = 0; index < order.count; index++) {
        id value = order[index];
        if (![value isKindOfClass:NSString.class]) continue;
        NSString *entry = [value lowercaseString];
        if ([canonical isEqualToString:entry] ||
            [canonical isEqualToString:YTzoomCanonicalTabToken(entry)] ||
            [token containsString:entry]) {
            return (NSInteger)index;
        }
    }
    return NSIntegerMax;
}

static void YTzoomApplyTabName(id item, NSString *token) {
    NSDictionary *names =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTzoom.Preference.Tabs.Names"];
    NSString *replacement = names[token] ?: names[YTzoomCanonicalTabToken(token)];
    if (![replacement isKindOfClass:NSString.class] || replacement.length == 0) {
        return;
    }
    id target = YTzoomTabValue(item, @[
        @"pivotBarItemRenderer",
        @"pivotBarIconOnlyItemRenderer"
    ]) ?: item;
    Class formattedClass = NSClassFromString(@"YTIFormattedString");
    SEL formattedSelector = NSSelectorFromString(@"formattedStringWithString:");
    id value = replacement;
    if (formattedClass != Nil && [formattedClass respondsToSelector:formattedSelector]) {
        value = ((id (*)(id, SEL, id))objc_msgSend)(
            formattedClass,
            formattedSelector,
            replacement
        );
    }
    SEL selector = NSSelectorFromString(@"setTitle:");
    if ([target respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, selector, value);
    }
}

static BOOL YTzoomIsDownloadTab(id item) {
    NSString *token = YTzoomTabToken(item);
    if ([token containsString:@"ytzoom"]) {
        return YES;
    }
    NSString *identifier = YTzoomRawTabIdentifier(item, 0);
    if (identifier.length != 0) {
        return [[identifier lowercaseString] containsString:@"ytzoom"];
    }
    NSString *description = [[item description] lowercaseString];
    return [description containsString:@"feytzoom"] ||
        [description containsString:@"ytzoom"];
}

static void YTzoomSetPivotRenderer(id receiver, SEL selector, id renderer) {
    if (renderer != nil) {
        NSString *setterName = nil;
        NSArray *items = YTzoomTabItems(renderer, &setterName);
        if (items != nil) {
            NSMutableArray *filtered = [NSMutableArray array];
            BOOL hasDownloadTab = NO;
            for (id item in items) {
                id candidate = item;
                NSString *token = YTzoomTabToken(candidate);
                if (YTzoomIsDownloadTab(candidate)) {
                    BOOL duplicate = hasDownloadTab;
                    hasDownloadTab = YES;
                    YTzoomNoteStartupIdentifier(@"ytzoom", candidate);
                    if (!duplicate && YTzoomMasterEnabled() &&
                        ![NSUserDefaults.standardUserDefaults boolForKey:@"YTzoom.Preference.Tabs.Hidden.YTzoomTab"]) {
                        [filtered addObject:candidate];
                    }
                    continue;
                }
                NSString *hideKey = YTzoomHideKeyForToken(token);
                YTzoomNoteStartupIdentifier(YTzoomCanonicalTabToken(token), candidate);
                if (YTzoomMasterEnabled() && hideKey != nil &&
                    [NSUserDefaults.standardUserDefaults boolForKey:hideKey]) {
                    continue;
                }
                if (YTzoomMasterEnabled() &&
                    [YTzoomCanonicalTabToken(token) isEqualToString:@"create"]) {
                    [filtered addObject:candidate];
                    continue;
                }
                if (YTzoomMasterEnabled()) {
                    YTzoomApplyTabName(candidate, token);
                }
                [filtered addObject:candidate];
            }

            NSArray<NSDictionary *> *extraTabs = @[
                @{@"token": @"music", @"id": @"UC-9-kyTW8ZkZNDHQJ6FgpwQ",
                  @"title": @"Music", @"key": @"YTzoom.Preference.Tabs.Hidden.Music", @"icon": @1001},
                @{@"token": @"live", @"id": @"UC4R8DWoMoI7CAwX8_LjQHig",
                  @"title": @"Live", @"key": @"YTzoom.Preference.Tabs.Hidden.Live", @"icon": @1002},
                @{@"token": @"gaming", @"id": @"UCOpNcN46UbXVtpKMrmU4Abg",
                  @"title": @"Gaming", @"key": @"YTzoom.Preference.Tabs.Hidden.Gaming", @"icon": @1003},
                @{@"token": @"news", @"id": @"UCYfdidRxbB8Qhf0Nx7ioOYw",
                  @"title": @"News", @"key": @"YTzoom.Preference.Tabs.Hidden.News", @"icon": @1004},
                @{@"token": @"sports", @"id": @"UCEgdi0XIXXZ-qJOFPf4JSKw",
                  @"title": @"Sports", @"key": @"YTzoom.Preference.Tabs.Hidden.Sports", @"icon": @1005},
                @{@"token": @"learning", @"id": @"UCtFRv9O2AHqOZjjynzrv-xg",
                  @"title": @"Learning", @"key": @"YTzoom.Preference.Tabs.Hidden.Learning", @"icon": @1006},
                @{@"token": @"fashion", @"id": @"UCrpQ4p1Ql_hG8rKXIKM1MOQ",
                  @"title": @"Fashion", @"key": @"YTzoom.Preference.Tabs.Hidden.Fashion", @"icon": @1007},
                @{@"token": @"playlists", @"id": @"FEplaylist_aggregation",
                  @"title": @"Playlists", @"key": @"YTzoom.Preference.Tabs.Hidden.Playlists", @"icon": @1008},
                @{@"token": @"history", @"id": @"FEhistory",
                  @"title": @"History", @"key": @"YTzoom.Preference.Tabs.Hidden.History", @"icon": @1009},
                @{@"token": @"notifications", @"id": @"FEnotifications_inbox",
                  @"title": @"Notifs", @"key": @"YTzoom.Preference.Tabs.Hidden.Notifs", @"icon": @1010},
                @{@"token": @"watchlater", @"id": @"VLWL",
                  @"title": @"WLater", @"key": @"YTzoom.Preference.Tabs.Hidden.WatchLater", @"icon": @1011},
                @{@"token": @"posts", @"id": @"FEpost_home",
                  @"title": @"Posts", @"key": @"YTzoom.Preference.Tabs.Hidden.Posts", @"icon": @1012}
            ];
            NSMutableSet<NSString *> *present = [NSMutableSet set];
            for (id item in filtered) {
                [present addObject:YTzoomCanonicalTabToken(YTzoomTabToken(item))];
            }
            NSDictionary *customNames =
                [NSUserDefaults.standardUserDefaults dictionaryForKey:@"YTzoom.Preference.Tabs.Names"];
            for (NSDictionary *entry in extraTabs) {
                NSString *token = entry[@"token"];
                if ([NSUserDefaults.standardUserDefaults boolForKey:entry[@"key"]] ||
                    [present containsObject:token]) {
                    continue;
                }
                NSString *title = customNames[token] ?: entry[@"title"];
                id item = YTzoomMakeBrowsePivotItem(entry[@"id"],
                                                     title,
                                                     [entry[@"icon"] integerValue]);
                if (item != nil) {
                    YTzoomNoteStartupIdentifier(token, item);
                    [filtered addObject:item];
                    [present addObject:token];
                }
            }

            if (YTzoomMasterEnabled() && !hasDownloadTab &&
                ![NSUserDefaults.standardUserDefaults boolForKey:@"YTzoom.Preference.Tabs.Hidden.YTzoomTab"]) {
                id downloadItem = YTzoomMakePivotItem();
                if (downloadItem != nil) {
                    YTzoomNoteStartupIdentifier(@"ytzoom", downloadItem);
                    [filtered addObject:downloadItem];
                }
            }

            NSArray *order =
                [NSUserDefaults.standardUserDefaults arrayForKey:@"YTzoom.Preference.Tabs.Order"];
            if (YTzoomMasterEnabled() && order.count != 0) {
                [filtered sortUsingComparator:^NSComparisonResult(id left, id right) {
                    NSInteger leftIndex =
                        YTzoomTabOrderIndex(YTzoomTabToken(left), order);
                    NSInteger rightIndex =
                        YTzoomTabOrderIndex(YTzoomTabToken(right), order);
                    if (leftIndex == rightIndex) {
                        return NSOrderedSame;
                    }
                    return leftIndex < rightIndex
                        ? NSOrderedAscending
                        : NSOrderedDescending;
                }];
            }

            SEL setter = NSSelectorFromString(setterName);
            if ([items isKindOfClass:NSMutableArray.class]) {
                [(NSMutableArray *)items setArray:filtered];
            } else if ([renderer respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(renderer, setter, filtered);
            }
        }
    }

    if (OriginalSetPivotRenderer != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPivotRenderer)(
            receiver, selector, renderer
        );
    }
}

static void YTzoomSetLabelsHidden(UIView *view, BOOL hidden) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) {
            subview.hidden = hidden;
            subview.alpha = hidden ? 0.0 : 1.0;
        }
        YTzoomSetLabelsHidden(subview, hidden);
    }
}

static BOOL YTzoomInsidePivotItem(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return YES;
        }
    }
    return NO;
}

static UIView *YTzoomPivotItemAncestor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        if ([NSStringFromClass(current.class) containsString:@"PivotBarItemView"]) {
            return current;
        }
    }
    return nil;
}

static void YTzoomPivotLabelSetHidden(UILabel *receiver,
                                      SEL selector,
                                      BOOL hidden) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden") &&
        YTzoomInsidePivotItem(receiver)) {
        hidden = YES;
    }
    if (OriginalPivotLabelSetHidden != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotLabelSetHidden)(
            receiver, selector, hidden
        );
    }
}

static void YTzoomPivotLabelSetAlpha(UILabel *receiver,
                                     SEL selector,
                                     CGFloat alpha) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden") &&
        YTzoomInsidePivotItem(receiver)) {
        alpha = 0.0;
    }
    if (OriginalPivotLabelSetAlpha != NULL) {
        ((void (*)(id, SEL, CGFloat))OriginalPivotLabelSetAlpha)(
            receiver, selector, alpha
        );
    }
}

static UIImageView *YTzoomFindImageView(UIView *view);

static BOOL YTzoomContainsLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) return YES;
    for (UIView *child in view.subviews) {
        if (YTzoomContainsLabel(child)) return YES;
    }
    return NO;
}

static void YTzoomCollectIconCandidates(UIView *view,
                                        UIView *root,
                                        NSMutableArray<UIView *> *candidates) {
    if (view != root && ![view isKindOfClass:UILabel.class]) {
        NSString *name = NSStringFromClass(view.class).lowercaseString;
        CGFloat width = CGRectGetWidth(view.bounds);
        CGFloat height = CGRectGetHeight(view.bounds);
        BOOL iconClass = [view isKindOfClass:UIImageView.class] ||
            [name containsString:@"icon"] || [name containsString:@"image"];
        BOOL iconSize = width >= 12.0 && height >= 12.0 &&
            width <= 64.0 && height <= 64.0;
        if ((view.tag == 0x59414345 || view.tag == YTzoomExtraIconTag ||
             iconClass) && iconSize) {
            [candidates addObject:view];
        }
    }
    for (UIView *child in view.subviews) {
        YTzoomCollectIconCandidates(child, root, candidates);
    }
}

static UIView *YTzoomIconContainer(UIView *candidate, UIView *root) {
    UIView *container = candidate;
    while (container.superview != nil && container.superview != root) {
        UIView *parent = container.superview;
        if (YTzoomContainsLabel(parent) ||
            CGRectGetWidth(parent.bounds) > 80.0 ||
            CGRectGetHeight(parent.bounds) > 80.0) {
            break;
        }
        container = parent;
    }
    return container;
}

static void YTzoomCenterPivotIcon(UIView *view, BOOL centered) {
    if (!centered) return;
    NSMutableArray<UIView *> *candidates = [NSMutableArray array];
    YTzoomCollectIconCandidates(view, view, candidates);
    UIView *candidate = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    CGPoint rootCenter = CGPointMake(CGRectGetMidX(view.bounds),
                                     CGRectGetMidY(view.bounds));
    for (UIView *item in candidates) {
        CGPoint center = [item.superview convertPoint:item.center toView:view];
        CGFloat score = fabs(center.x - rootCenter.x) +
            fabs(CGRectGetWidth(item.bounds) - 24.0) * 0.25 +
            (item.hidden ? 100.0 : 0.0);
        if (item.tag == 0x59414345 || item.tag == YTzoomExtraIconTag) {
            score -= 1000.0;
        }
        if (score < bestScore) {
            bestScore = score;
            candidate = item;
        }
    }
    UIView *iconView = candidate == nil ? nil : YTzoomIconContainer(candidate, view);
    if (iconView == nil || iconView.superview == nil) return;
    CGPoint target = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds),
                                                     CGRectGetMidY(view.bounds))
                                toView:iconView.superview];
    iconView.center = target;
}

static UILabel *YTzoomFindNativeLabel(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return (view.tag == 0x59414347 || view.tag == YTzoomExtraLabelTag)
            ? nil : (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *label = YTzoomFindNativeLabel(subview);
        if (label != nil) {
            return label;
        }
    }
    return nil;
}

static UIColor *YTzoomTabForegroundColor(UIView *view) {
    for (UIView *current = view.superview; current != nil; current = current.superview) {
        UIColor *color = [current.backgroundColor
            resolvedColorWithTraitCollection:view.traitCollection];
        CGFloat red = 0.0;
        CGFloat green = 0.0;
        CGFloat blue = 0.0;
        CGFloat alpha = 0.0;
        if ([color getRed:&red green:&green blue:&blue alpha:&alpha] &&
            alpha > 0.2) {
            CGFloat luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722;
            return luminance < 0.5 ? UIColor.whiteColor : UIColor.blackColor;
        }
    }
    return [UIColor.labelColor
        resolvedColorWithTraitCollection:view.traitCollection];
}

static UIImageView *YTzoomFindImageView(UIView *view) {
    if ([view isKindOfClass:UIImageView.class]) {
        return (view.tag == 0x59414345 || view.tag == YTzoomExtraIconTag)
            ? nil : (UIImageView *)view;
    }
    for (UIView *subview in view.subviews) {
        UIImageView *imageView = YTzoomFindImageView(subview);
        if (imageView != nil) {
            return imageView;
        }
    }
    return nil;
}

static BOOL YTzoomViewIsVisible(UIView *view) {
    if (view.window == nil) {
        return NO;
    }
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) {
            return NO;
        }
    }
    return YES;
}

static UIView *YTzoomFindDownloadsRoot(UIView *view) {
    if ([view.accessibilityIdentifier isEqualToString:@"YTzoomDownloadsRoot"]) {
        return view;
    }
    for (UIView *subview in view.subviews) {
        UIView *result = YTzoomFindDownloadsRoot(subview);
        if (result != nil) {
            return result;
        }
    }
    return nil;
}

static BOOL YTzoomDownloadsAreVisible(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *root = YTzoomFindDownloadsRoot(window);
            if (root != nil && YTzoomViewIsVisible(root)) {
                return YES;
            }
        }
    }
    return NO;
}

static void YTzoomRestorePivotItem(UIView *view,
                                   UILabel *nativeLabel,
                                   BOOL hideLabel) {
    [[view viewWithTag:0x59414347] removeFromSuperview];
    [[view viewWithTag:0x59414345] removeFromSuperview];
    objc_setAssociatedObject(view,
                             YTzoomTabAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (nativeLabel != nil) {
        nativeLabel.hidden = hideLabel;
        nativeLabel.alpha = 1.0;
    }
    UIImageView *nativeImageView = YTzoomFindImageView(view);
    if (nativeImageView != nil) {
        nativeImageView.hidden = NO;
    }
}

static void YTzoomApplyDownloadIcon(UIView *view) {
    UILabel *nativeLabel = YTzoomFindNativeLabel(view);
    NSString *token = YTzoomTabToken(view);
    NSString *text = nativeLabel.text ?: @"";
    BOOL exactIdentifier = [token isEqualToString:@"feytzoom"];
    BOOL exactLabel = [text caseInsensitiveCompare:@"YTzoom"] == NSOrderedSame;
    BOOL associated = [objc_getAssociatedObject(
        view,
        YTzoomTabAssociation
    ) boolValue];
    BOOL definiteOther = (token.length != 0 && !exactIdentifier) ||
        (text.length != 0 && !exactLabel);
    BOOL hideLabel = YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden");
    if (definiteOther) {
        YTzoomRestorePivotItem(view, nativeLabel, hideLabel);
        return;
    }
    BOOL recognized = exactIdentifier || exactLabel || associated;
    if (!recognized) {
        return;
    }
    objc_setAssociatedObject(view,
                             YTzoomTabAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIImageView *nativeImageView = YTzoomFindImageView(view);
    UIColor *tabColor = YTzoomTabForegroundColor(view);
    UILabel *label = (UILabel *)[view viewWithTag:0x59414347];
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = 0x59414347;
        label.text = @"YTzoom";
        label.font = nativeLabel.font ?: [UIFont systemFontOfSize:10.0];
        label.textAlignment = NSTextAlignmentCenter;
        label.autoresizingMask = UIViewAutoresizingFlexibleWidth |
            UIViewAutoresizingFlexibleTopMargin;
        [view addSubview:label];
    }
    label.textColor = tabColor;
    label.hidden = hideLabel;
    label.alpha = 1.0;
    BOOL selected = [objc_getAssociatedObject(
        view,
        YTzoomTabSelectedAssociation
    ) boolValue];
    SEL selectedSelector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selectedSelector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selectedSelector);
    }
    selected = selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0) ||
        YTzoomDownloadsAreVisible();
    if ([objc_getAssociatedObject(view, YTzoomTabDragOutAssociation) boolValue]) selected = NO;
    UIImage *image = YTzoomDownloadTabImage(selected);
    UIImageView *imageView = (UIImageView *)[view viewWithTag:0x59414345];
    if (imageView == nil) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x59414345;
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
            UIViewAutoresizingFlexibleRightMargin |
            UIViewAutoresizingFlexibleBottomMargin;
        [view addSubview:imageView];
    }
    if (nativeImageView != nil && nativeImageView != imageView) {
        nativeImageView.hidden = YES;
    }
    imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    imageView.tintColor = tabColor;
    imageView.hidden = NO;
    CGFloat size = 24.0;
    imageView.frame = CGRectMake(
        (CGRectGetWidth(view.bounds) - size) * 0.5,
        hideLabel ? (CGRectGetHeight(view.bounds) - size) * 0.5 : 4.0,
        size,
        size
    );
    label.frame = CGRectMake(0.0,
                             MAX(0.0, CGRectGetHeight(view.bounds) - 16.0),
                             CGRectGetWidth(view.bounds),
                             14.0);
}

static NSDictionary *YTzoomExtraTabIcon(NSString *token) {
    static NSDictionary *icons;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        icons = @{
            @"music": @[@"yt_outline_music_24pt_3x_Normal",
                         @"music_24pt_3x_Normal",
                         @"music.note", @"music.note"],
            @"live": @[@"live_24pt_3x_Normal", @"ic_youtube_live_3x_Normal",
                        @"dot.radiowaves.left.and.right",
                        @"dot.radiowaves.left.and.right"],
            @"gaming": @[@"gaming_24pt_3x_Normal",
                          @"gaming_24pt_3x_Normal_fill",
                          @"gamecontroller", @"gamecontroller.fill"],
            @"news": @[@"news_24pt_3x_Normal", @"news_24pt_3x_Normal",
                        @"newspaper", @"newspaper.fill"],
            @"sports": @[@"G_sport", @"G_sport_fill",
                          @"trophy", @"trophy.fill"],
            @"learning": @[@"G_Learning", @"G_Learning_fill",
                            @"graduationcap", @"graduationcap.fill"],
            @"fashion": @[@"fashion_24pt_3x_Normal",
                           @"fashion_24pt_3x_Normal",
                           @"tshirt", @"tshirt.fill"],
            @"playlists": @[@"playlist", @"playlist_fill",
                             @"music.note.list", @"music.note.list"],
            @"history": @[@"history", @"history_fill",
                           @"clock.arrow.circlepath",
                           @"clock.arrow.circlepath"],
            @"notifications": @[@"ic_notifications_none_3x_Normal",
                                 @"ic_notifications_3x_Normal",
                                 @"bell", @"bell.fill"],
            @"watchlater": @[@"clock_24pt_3x_Normal",
                              @"yt_fill_clock_24pt_3x_Normal",
                              @"clock", @"clock.fill"],
            @"posts": @[@"", @"",
                         @"bubble.left.and.bubble.right",
                         @"bubble.left.and.bubble.right.fill"]
        };
    });
    NSArray *values = icons[token];
    return values == nil ? nil : @{
        @"normalAsset": values[0],
        @"selectedAsset": values[1],
        @"normalSymbol": values[2],
        @"selectedSymbol": values[3]
    };
}

static BOOL YTzoomPivotItemSelected(UIView *view) {
    if ([objc_getAssociatedObject(view, YTzoomTabDragOutAssociation) boolValue]) return NO;
    BOOL selected = [objc_getAssociatedObject(
        view,
        YTzoomTabSelectedAssociation
    ) boolValue];
    SEL selector = NSSelectorFromString(@"isSelected");
    if ([view respondsToSelector:selector]) {
        selected = selected ||
            ((BOOL (*)(id, SEL))objc_msgSend)(view, selector);
    }
    return selected ||
        ((view.accessibilityTraits & UIAccessibilityTraitSelected) != 0);
}

static void YTzoomApplyExtraTabIcon(UIView *view) {
    NSString *token = YTzoomCanonicalTabToken(YTzoomTabToken(view));
    NSDictionary *config = YTzoomExtraTabIcon(token);
    if (config == nil) {
        UILabel *nativeLabel = YTzoomFindNativeLabel(view);
        NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@ %@",
            nativeLabel.text ?: @"", view.accessibilityLabel ?: @"",
            view.accessibilityIdentifier ?: @"", view.description ?: @""] lowercaseString];
        NSDictionary *aliases = @{
            @"music": @[@"music"],
            @"live": @[@"live"],
            @"gaming": @[@"gaming"],
            @"news": @[@"news"],
            @"sports": @[@"sports"],
            @"learning": @[@"learning"],
            @"fashion": @[@"fashion"],
            @"playlists": @[@"playlists", @"playlist"],
            @"history": @[@"history"],
            @"notifications": @[@"notifs", @"notifications"],
            @"watchlater": @[@"wlater", @"watch later"],
            @"posts": @[@"posts", @"post"]
        };
        for (NSString *candidate in aliases) {
            for (NSString *alias in aliases[candidate]) {
                if ([hint containsString:alias]) {
                    token = candidate;
                    config = YTzoomExtraTabIcon(token);
                    break;
                }
            }
            if (config != nil) break;
        }
    }
    if (config == nil) {
        [[view viewWithTag:YTzoomExtraIconTag] removeFromSuperview];
        [[view viewWithTag:YTzoomExtraLabelTag] removeFromSuperview];
        return;
    }
    UIImageView *nativeImage = YTzoomFindImageView(view);
    if (nativeImage != nil) {
        nativeImage.hidden = YES;
    }
    UIImageView *icon = (UIImageView *)[view viewWithTag:YTzoomExtraIconTag];
    if (icon == nil) {
        icon = [[UIImageView alloc] initWithFrame:CGRectZero];
        icon.tag = YTzoomExtraIconTag;
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.userInteractionEnabled = NO;
        [view addSubview:icon];
    }
    BOOL selected = YTzoomPivotItemSelected(view);
    NSString *asset = config[selected ? @"selectedAsset" : @"normalAsset"];
    NSString *symbol = config[selected ? @"selectedSymbol" : @"normalSymbol"];
    UIImage *image = YTzoomAssetImage(asset, symbol);
    if (image == nil) {
        image = [UIImage systemImageNamed:@"circle"];
    }
    icon.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    icon.tintColor = YTzoomTabForegroundColor(view);
    icon.hidden = NO;
    CGFloat size = 24.0;
    BOOL hideLabel = YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden");
    icon.frame = CGRectMake(
        (CGRectGetWidth(view.bounds) - size) * 0.5,
        hideLabel ? (CGRectGetHeight(view.bounds) - size) * 0.5 : 4.0,
        size,
        size
    );
    UILabel *nativeLabel = YTzoomFindNativeLabel(view);
    UILabel *label = (UILabel *)[view viewWithTag:YTzoomExtraLabelTag];
    NSString *title = nativeLabel.text.length != 0
        ? nativeLabel.text : label.text;
    UIFont *font = nativeLabel.font ?: label.font;
    if (nativeLabel != nil) {
        nativeLabel.text = @"";
        nativeLabel.hidden = YES;
        nativeLabel.alpha = 0.0;
    }
    if (label == nil) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.tag = YTzoomExtraLabelTag;
        label.textAlignment = NSTextAlignmentCenter;
        label.userInteractionEnabled = NO;
        [view addSubview:label];
    }
    label.text = title;
    label.font = font ?: [UIFont systemFontOfSize:10.0];
    label.textColor = icon.tintColor;
    label.hidden = hideLabel;
    label.alpha = hideLabel ? 0.0 : 1.0;
    label.frame = CGRectMake(
        0.0,
        MAX(0.0, CGRectGetHeight(view.bounds) - 16.0),
        CGRectGetWidth(view.bounds),
        14.0
    );
}

static NSString *const YTzoomTintModeKey = @"YTzoom.Preference.Tabs.SelectedTint";
static NSString *const YTzoomTintColorKey = @"YTzoom.Preference.Tabs.SelectedTintColor";
static const void *YTzoomNativeTextColorAssociation = &YTzoomNativeTextColorAssociation;
static const void *YTzoomNativeIconAssociation = &YTzoomNativeIconAssociation;
static IMP OriginalPivotLabelSetTextColor;
static NSInteger YTzoomTintMode;
static UIColor *YTzoomTintColor;

static NSString *YTzoomPivotItemIdentifier(UIView *item);
static UIImageView *YTzoomFindPhotoView(UIView *view);

static BOOL YTzoomRefreshTabTint(void) {
    NSInteger mode = [YTzoomPreferenceObject(YTzoomTintModeKey) integerValue];
    id stored = YTzoomPreferenceObject(YTzoomTintColorKey);
    NSString *value = [[([stored isKindOfClass:NSString.class] ? stored : @"#0A84FF")
        stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    unsigned int rgb = 0x0A84FF;
    if (value.length == 6) [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    UIColor *color = [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                                     green:((rgb >> 8) & 0xFF) / 255.0
                                      blue:(rgb & 0xFF) / 255.0
                                     alpha:1.0];
    BOOL changed = mode != YTzoomTintMode || ![color isEqual:YTzoomTintColor];
    YTzoomTintMode = mode;
    YTzoomTintColor = color;
    return changed;
}

static void YTzoomSetLabelColor(UILabel *label, UIColor *color) {
    if (color == nil || [label.textColor isEqual:color]) return;
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(label, @selector(setTextColor:), color);
    } else {
        label.textColor = color;
    }
}

static void YTzoomPivotLabelSetTextColor(UILabel *receiver, SEL selector, UIColor *color) {
    if (YTzoomTintMode != 0) {
        UIView *item = YTzoomPivotItemAncestor(receiver);
        if (item != nil) {
            objc_setAssociatedObject(receiver, YTzoomNativeTextColorAssociation, color,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if (YTzoomPivotItemSelected(item)) color = YTzoomTintColor;
        }
    }
    if (OriginalPivotLabelSetTextColor != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotLabelSetTextColor)(receiver, selector, color);
    }
}

static void YTzoomCollectLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)subview];
        YTzoomCollectLabels(subview, labels);
    }
}

static void YTzoomApplyTabTint(UIView *item) {
    BOOL tinted = YTzoomTintMode != 0 && YTzoomPivotItemSelected(item);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    YTzoomCollectLabels(item, labels);
    for (UILabel *label in labels) {
        UIColor *native = objc_getAssociatedObject(label, YTzoomNativeTextColorAssociation);
        if (YTzoomTintMode == 0) {
            if (native == nil) continue;
            objc_setAssociatedObject(label, YTzoomNativeTextColorAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTzoomSetLabelColor(label, native);
            continue;
        }
        if (native == nil && label.textColor != nil && ![label.textColor isEqual:YTzoomTintColor]) {
            native = label.textColor;
            objc_setAssociatedObject(label, YTzoomNativeTextColorAssociation, native,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        YTzoomSetLabelColor(label, tinted ? YTzoomTintColor : native);
    }
    BOOL avatar = [YTzoomPivotItemIdentifier(item) isEqualToString:@"FElibrary"] &&
        YTzoomFindPhotoView(item) != nil;
    BOOL tintIcon = tinted && YTzoomTintMode == 2 && !avatar;
    for (NSNumber *tag in @[@0x59414345, @(YTzoomExtraIconTag)]) {
        UIView *custom = [item viewWithTag:tag.integerValue];
        if (tintIcon && [custom isKindOfClass:UIImageView.class]) custom.tintColor = YTzoomTintColor;
    }
    UIImageView *icon = YTzoomFindImageView(item);
    NSArray *native = icon != nil ? objc_getAssociatedObject(icon, YTzoomNativeIconAssociation) : nil;
    if (native == nil) return;
    objc_setAssociatedObject(icon, YTzoomNativeIconAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (icon.image == native[1]) icon.image = native[0];
    icon.tintColor = native[2];
}

static IMP OriginalIconTintSelected;

static UIColor *YTzoomIconTintSelected(UIView *receiver, SEL selector) {
    if (YTzoomTintMode == 2 && ![YTzoomPivotItemIdentifier(receiver) isEqualToString:@"FElibrary"]) {
        return YTzoomTintColor;
    }
    return OriginalIconTintSelected == NULL ? nil
        : ((id (*)(id, SEL))OriginalIconTintSelected)(receiver, selector);
}

static void YTzoomRestyleSelectedTab(UIView *item) {
    SEL setter = NSSelectorFromString(@"setSelected:");
    if (!YTzoomPivotItemSelected(item) || ![item respondsToSelector:setter]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setter, YES);
}

static void YTzoomApplyPivotItemPresentation(UIView *view) {
    BOOL hideLabels = YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden");
    YTzoomSetLabelsHidden(view, hideLabels);
    YTzoomApplyDownloadIcon(view);
    YTzoomApplyExtraTabIcon(view);
    YTzoomCenterPivotIcon(view, hideLabels);
    YTzoomApplyTabTint(view);
}

static void YTzoomPivotButtonLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotButtonLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotButtonLayout)(receiver, selector);
    }
    if (YTzoomTintMode != 0) {
        UIView *tintItem = YTzoomPivotItemAncestor(receiver);
        if (tintItem != nil) YTzoomApplyTabTint(tintItem);
    }
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.LabelsHidden")) return;
    UIView *item = YTzoomPivotItemAncestor(receiver);
    if (item == nil || CGRectIsEmpty(item.bounds)) return;
    YTzoomSetLabelsHidden(receiver, YES);
    UIImageView *icon = nil;
    for (UIView *child in receiver.subviews) {
        if (![child isKindOfClass:UIImageView.class] || child.hidden ||
            CGRectGetWidth(child.bounds) < 12.0 ||
            CGRectGetHeight(child.bounds) < 12.0) {
            continue;
        }
        icon = (UIImageView *)child;
        break;
    }
    if (icon == nil) return;
    CGPoint target = [item convertPoint:CGPointMake(CGRectGetMidX(item.bounds),
                                                    CGRectGetMidY(item.bounds))
                                  toView:receiver];
    icon.center = target;
}

static BOOL YTzoomContainsCreateText(NSString *value) {
    NSString *text = value.lowercaseString;
    return [text containsString:@"create"] ||
        [text containsString:@"upload"] ||
        [text containsString:@"add video"];
}

static void YTzoomHideCreateViews(UIView *view) {
    BOOL hideCreate = [NSUserDefaults.standardUserDefaults boolForKey:@"YTzoom.Preference.Tabs.Hidden.Create"];
    for (UIView *subview in view.subviews) {
        NSString *label = subview.accessibilityLabel;
        NSString *identifier = subview.accessibilityIdentifier;
        NSString *className = NSStringFromClass(subview.class);
        if (hideCreate &&
            (YTzoomContainsCreateText(label) ||
             YTzoomContainsCreateText(identifier) ||
             YTzoomContainsCreateText(className))) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
        }
        YTzoomHideCreateViews(subview);
    }
}

static IMP YTzoomOrigInfoDictionary;
static IMP YTzoomOrigInfoObject;
static NSString * const YTzoomDesignCompatibilityKey = @"UIDesignRequiresCompatibility";

static NSDictionary *YTzoomInfoDictionary(NSBundle *self, SEL _cmd) {
    NSDictionary *info = ((id (*)(id, SEL))YTzoomOrigInfoDictionary)(self, _cmd);
    if (self != NSBundle.mainBundle || info[YTzoomDesignCompatibilityKey] == nil) return info;
    NSMutableDictionary *copy = [info mutableCopy];
    [copy removeObjectForKey:YTzoomDesignCompatibilityKey];
    return copy;
}

static id YTzoomInfoObject(NSBundle *self, SEL _cmd, NSString *key) {
    if (self == NSBundle.mainBundle && [key isEqualToString:YTzoomDesignCompatibilityKey]) {
        return nil;
    }
    return ((id (*)(id, SEL, id))YTzoomOrigInfoObject)(self, _cmd, key);
}

__attribute__((constructor)) static void YTzoomInstallLiquidGlassDesign(void) {
    if (NSClassFromString(@"UIGlassEffect") == Nil) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    BOOL any = NO;
    for (NSString *key in @[@"YTzoom.Preference.Tabs.Glass", @"YTzoom.Preference.Glass.TopBar",
                            @"YTzoom.Preference.Glass.Menus", @"YTzoom.Preference.Glass.Notices",
                            @"YTzoom.Preference.Glass.Player"]) {
        if ([defaults boolForKey:key]) any = YES;
    }
    if (!any) return;
    id info = (__bridge id)CFBundleGetInfoDictionary(CFBundleGetMainBundle());
    if ([info respondsToSelector:@selector(removeObjectForKey:)]) {
        @try {
            [info removeObjectForKey:YTzoomDesignCompatibilityKey];
        } @catch (__unused NSException *exception) {
        }
    }
    YTzoomInstallInstanceHook(@"NSBundle", @"infoDictionary",
        (IMP)YTzoomInfoDictionary, &YTzoomOrigInfoDictionary);
    YTzoomInstallInstanceHook(@"NSBundle", @"objectForInfoDictionaryKey:",
        (IMP)YTzoomInfoObject, &YTzoomOrigInfoObject);
}

static const void *YTzoomPivotBarSolidAssociation = &YTzoomPivotBarSolidAssociation;
static const void *YTzoomPivotBarGlassAssociation = &YTzoomPivotBarGlassAssociation;
static const void *YTzoomPivotBarPillAssociation = &YTzoomPivotBarPillAssociation;
static const void *YTzoomPivotBarLensAssociation = &YTzoomPivotBarLensAssociation;
static const void *YTzoomPivotBarMagnifyAssociation = &YTzoomPivotBarMagnifyAssociation;
static const void *YTzoomPivotBarHoleAssociation = &YTzoomPivotBarHoleAssociation;
static const void *YTzoomPivotBarPressTimeAssociation = &YTzoomPivotBarPressTimeAssociation;
static const void *YTzoomPivotBarFadedAssociation = &YTzoomPivotBarFadedAssociation;

static BOOL YTzoomViewContainsPivotItem(UIView *view) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) return YES;
    for (UIView *subview in view.subviews) {
        if (YTzoomViewContainsPivotItem(subview)) return YES;
    }
    return NO;
}

static void YTzoomCollectPivotItems(UIView *view, NSMutableArray<UIView *> *items) {
    static Class itemClass;
    if (itemClass == Nil) itemClass = NSClassFromString(@"YTPivotBarItemView");
    if (itemClass != Nil && [view isKindOfClass:itemClass]) {
        [items addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) YTzoomCollectPivotItems(subview, items);
}

static NSHashTable<UIView *> *YTzoomPivotFadedViews(UIView *bar) {
    NSHashTable *faded = objc_getAssociatedObject(bar, YTzoomPivotBarFadedAssociation);
    if (faded == nil) {
        faded = [NSHashTable weakObjectsHashTable];
        objc_setAssociatedObject(bar, YTzoomPivotBarFadedAssociation, faded,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return faded;
}

static UIVisualEffect *YTzoomMakeGlassEffect(BOOL interactive) {
    Class effectClass = NSClassFromString(@"UIGlassEffect");
    SEL styleSelector = NSSelectorFromString(@"effectWithStyle:");
    UIVisualEffect *effect = [effectClass respondsToSelector:styleSelector]
        ? ((id (*)(id, SEL, NSInteger))objc_msgSend)(effectClass, styleSelector, interactive ? 1 : 0)
        : [effectClass new];
    SEL interactiveSelector = NSSelectorFromString(@"setInteractive:");
    if (interactive && [effect respondsToSelector:interactiveSelector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(effect, interactiveSelector, YES);
    }
    return effect;
}


static UIView *YTzoomSelectedPivotItem(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTzoomCollectPivotItems(bar, items);
    for (UIView *item in items) {
        if ([objc_getAssociatedObject(item, YTzoomTabSelectedAssociation) boolValue]) return item;
    }
    return nil;
}

static NSArray<UIView *> *YTzoomSortedPivotItems(UIView *bar) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTzoomCollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    return visible;
}

static void YTzoomTabGeometry(CGRect glass, NSUInteger count, CGFloat *start, CGFloat *step, CGFloat *overlap) {
    CGFloat spill = count <= 4 ? 8.0 : 16.0;
    CGFloat pitch = count == 0 ? 0.0 : (CGRectGetWidth(glass) - 8.0 - spill) / (CGFloat)count;
    if (start) *start = CGRectGetMinX(glass) + 4.0;
    if (step) *step = pitch;
    if (overlap) *overlap = spill;
}

static CGRect YTzoomPillFrameForItem(UIView *bar, UIVisualEffectView *glass, UIView *item) {
    NSArray<UIView *> *sorted = YTzoomSortedPivotItems(bar);
    NSUInteger index = [sorted indexOfObject:item];
    CGRect itemFrame = [item convertRect:item.bounds toView:bar];
    CGFloat inset = 4.0;
    CGFloat left = CGRectGetMinX(itemFrame) + 2.0;
    CGFloat right = CGRectGetMaxX(itemFrame) - 2.0;
    if (index != NSNotFound) {
        CGFloat start = 0.0, step = 0.0, overlap = 0.0;
        YTzoomTabGeometry(glass.frame, sorted.count, &start, &step, &overlap);
        left = start + step * (CGFloat)index;
        right = left + step + overlap;
    }
    left = MAX(left, CGRectGetMinX(glass.frame) + inset);
    right = MIN(right, CGRectGetMaxX(glass.frame) - inset);
    return CGRectMake(left, CGRectGetMinY(glass.frame) + inset,
                      MAX(right - left, 20.0), CGRectGetHeight(glass.frame) - inset * 2.0);
}

static void YTzoomLayoutItemsInGlass(UIView *bar, CGRect glassFrame) {
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTzoomCollectPivotItems(bar, items);
    NSMutableArray<UIView *> *visible = [NSMutableArray array];
    for (UIView *item in items) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) [visible addObject:item];
    }
    if (visible.count == 0) return;
    [visible sortUsingComparator:^NSComparisonResult(UIView *left, UIView *right) {
        CGFloat a = CGRectGetMinX([left convertRect:left.bounds toView:bar]);
        CGFloat b = CGRectGetMinX([right convertRect:right.bounds toView:bar]);
        return a < b ? NSOrderedAscending : (a > b ? NSOrderedDescending : NSOrderedSame);
    }];
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    YTzoomTabGeometry(glassFrame, visible.count, &start, &slot, &overlap);
    for (NSUInteger index = 0; index < visible.count; index++) {
        UIView *item = visible[index];
        if (item.superview == nil) continue;
        CGRect current = [item convertRect:item.bounds toView:bar];
        CGRect target = CGRectMake(start + overlap * 0.5 + slot * index,
                                   CGRectGetMidY(glassFrame) - CGRectGetHeight(current) * 0.5,
                                   slot, CGRectGetHeight(current));
        CGRect local = [bar convertRect:target toView:item.superview];
        if (!CGRectEqualToRect(CGRectIntegral(item.frame), CGRectIntegral(local))) {
            item.frame = local;
        }
    }
}

static void YTzoomSelectPivotItem(UIView *item) {
    id controller = nil;
    id renderer = nil;
    @try {
        controller = [item valueForKey:@"delegate"];
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    NSString *identifier = nil;
    @try {
        identifier = [renderer valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (renderer != nil && [controller respondsToSelector:tap]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, renderer);
        return;
    }
    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0 &&
        [controller respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(controller, select, identifier);
        return;
    }
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    UIControl *button = [item respondsToSelector:buttonSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector) : nil;
    if ([button isKindOfClass:UIControl.class]) {
        [button sendActionsForControlEvents:UIControlEventTouchUpInside];
    }
}

static UIColor *YTzoomPillColor(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return traits.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithWhite:0.0 alpha:0.4]
            : [UIColor colorWithWhite:0.0 alpha:0.08];
    }];
}

static UIView *YTzoomPivotItemsContainer(UIView *bar) {
    for (UIView *subview in bar.subviews) {
        if (YTzoomViewContainsPivotItem(subview)) return subview;
    }
    return nil;
}

static void YTzoomLensSetObject(id lens, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(lens, selector, value);
    }
}

static void YTzoomLensSetInteger(id lens, NSString *name, NSInteger value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(lens, selector, value);
    }
}

static void YTzoomLensSetBool(id lens, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([lens respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(lens, selector, value);
    }
}

static UIView *YTzoomMakeSystemLens(UIView *bar) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    SEL initSelector = NSSelectorFromString(@"initWithRestingBackground:");
    if (lensClass == Nil || ![lensClass instancesRespondToSelector:initSelector]) return nil;
    Class selectionClass = NSClassFromString(@"_UITabSelectionView");
    BOOL native = selectionClass != Nil && [selectionClass isSubclassOfClass:UIView.class];
    UIView *resting = native ? [selectionClass new] : [UIView new];
    if (!native) resting.backgroundColor = YTzoomPillColor();
    UIView *lens = ((id (*)(id, SEL, id))objc_msgSend)([lensClass alloc], initSelector, resting);
    if (![lens isKindOfClass:UIView.class]) return nil;
    YTzoomLensSetObject(lens, @"setLiftedContainerView:", bar);
    YTzoomLensSetInteger(lens, @"setLiftedContentMode:", 1);
    YTzoomLensSetInteger(lens, @"setStyle:", 1);
    YTzoomLensSetBool(lens, @"setWarpsContentBelow:", YES);
    if (!native) {
        @try {
            [lens setValue:YTzoomPillColor() forKey:@"restingBackgroundColor"];
        } @catch (__unused NSException *exception) {
        }
    }
    lens.userInteractionEnabled = YES;
    return lens;
}

static BOOL YTzoomIsSystemLens(UIView *view) {
    Class lensClass = NSClassFromString(@"_UILiquidLensView");
    return lensClass != Nil && [view isKindOfClass:lensClass];
}

static void YTzoomTrackLens(UIView *lens, CFTimeInterval seconds);
static void YTzoomLowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower);

static void YTzoomLensSpring(NSTimeInterval response, CGFloat bounce, CGFloat velocity, dispatch_block_t animations) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, bounce, velocity, 0.0, options, animations, nil);
    } else {
        [UIView animateWithDuration:response delay:0.0 usingSpringWithDamping:1.0 - bounce
              initialSpringVelocity:velocity options:options animations:animations completion:nil];
    }
}

static const void *YTzoomPivotBarExpandedAssociation = &YTzoomPivotBarExpandedAssociation;

static const void *YTzoomPivotBarMinimizedAssociation = &YTzoomPivotBarMinimizedAssociation;
static const void *YTzoomPivotBarMiniAppliedAssociation = &YTzoomPivotBarMiniAppliedAssociation;
static const void *YTzoomPivotBarMiniMaskAssociation = &YTzoomPivotBarMiniMaskAssociation;
static NSString *const YTzoomMinimizeKey = @"YTzoom.Preference.Tabs.GlassMinimize";
static __weak UIView *YTzoomMinimizeBar;
static BOOL YTzoomMinimizeEnabled;
static CGFloat YTzoomMinimizeProgress;

static BOOL YTzoomBarMinimized(UIView *bar) {
    return bar != nil && [objc_getAssociatedObject(bar, YTzoomPivotBarMinimizedAssociation) boolValue];
}


static NSString *YTzoomPivotItemIdentifier(UIView *item);

static void YTzoomBarSpring(NSTimeInterval response, CGFloat damping, NSTimeInterval delay,
                            dispatch_block_t animations, void (^completion)(BOOL)) {
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState |
        UIViewAnimationOptionAllowUserInteraction;
    SEL spring = NSSelectorFromString(@"animateWithSpringDuration:bounce:initialSpringVelocity:delay:options:animations:completion:");
    if ([UIView respondsToSelector:spring]) {
        ((void (*)(id, SEL, NSTimeInterval, CGFloat, CGFloat, NSTimeInterval, UIViewAnimationOptions, id, id))objc_msgSend)(
            UIView.class, spring, response, 1.0 - damping, 0.0, delay, options, animations, completion);
    } else {
        [UIView animateWithDuration:response * 1.5 delay:delay usingSpringWithDamping:damping
              initialSpringVelocity:0.0 options:options animations:animations completion:completion];
    }
}

static void YTzoomSetBarScale(UIView *bar, CGFloat scale, NSTimeInterval response, CGFloat damping) {
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    CATransform3D transform = CATransform3DIdentity;
    if (glass != nil && fabs(scale - 1.0) > 0.0001) {
        CGFloat dx = CGRectGetMidX(glass.frame) - CGRectGetMidX(bar.bounds);
        CGFloat dy = CGRectGetMidY(glass.frame) - CGRectGetMidY(bar.bounds);
        transform = CATransform3DTranslate(transform, dx, dy, 0.0);
        transform = CATransform3DScale(transform, scale, scale, 1.0);
        transform = CATransform3DTranslate(transform, -dx, -dy, 0.0);
    }
    CALayer *layer = bar.layer;
    if (CATransform3DEqualToTransform(layer.sublayerTransform, transform)) return;
    CALayer *shown = layer.presentationLayer ?: layer;
    CATransform3D from = shown.sublayerTransform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.sublayerTransform = transform;
    [CATransaction commit];
    if (response <= 0.0) {
        [layer removeAnimationForKey:@"ytzoom.scale"];
        return;
    }
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = [NSValue valueWithCATransform3D:from];
    animation.toValue = [NSValue valueWithCATransform3D:transform];
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:@"ytzoom.scale"];
}

static const void *YTzoomPivotBarMiniIconAssociation = &YTzoomPivotBarMiniIconAssociation;
static const void *YTzoomPivotBarMiniIconRectAssociation = &YTzoomPivotBarMiniIconRectAssociation;
static NSTimeInterval YTzoomMiniMaskResponse;
static CGFloat YTzoomMiniMaskDamping;

static void YTzoomSpringLayer(CALayer *layer, NSString *key, id from, id to, NSTimeInterval response, CGFloat damping) {
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:key];
    animation.mass = 1.0;
    animation.stiffness = pow(2.0 * M_PI / response, 2.0);
    animation.damping = 4.0 * M_PI * damping / response;
    animation.fromValue = from;
    animation.toValue = to;
    animation.duration = animation.settlingDuration;
    [layer addAnimation:animation forKey:[@"ytzoom." stringByAppendingString:key]];
}

static void YTzoomInstallMiniMask(UIView *bar) {
    UIView *container = YTzoomPivotItemsContainer(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    if (container == nil || glass == nil) return;
    CALayer *mask = objc_getAssociatedObject(bar, YTzoomPivotBarMiniMaskAssociation);
    if (mask == nil) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        mask.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(bar, YTzoomPivotBarMiniMaskAssociation, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (container.layer.mask == mask) return;
    CGRect frame = [bar convertRect:glass.frame toView:container];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [mask removeAllAnimations];
    mask.bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    mask.position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    mask.cornerRadius = CGRectGetHeight(frame) * 0.5;
    container.layer.mask = mask;
    [CATransaction commit];
}

static void YTzoomUpdateMiniMask(UIView *bar, CGRect glassFrame) {
    CALayer *mask = objc_getAssociatedObject(bar, YTzoomPivotBarMiniMaskAssociation);
    UIView *container = YTzoomPivotItemsContainer(bar);
    if (mask == nil || container == nil || container.layer.mask != mask) return;
    CGRect frame = [bar convertRect:glassFrame toView:container];
    CGRect bounds = CGRectMake(0, 0, CGRectGetWidth(frame), CGRectGetHeight(frame));
    CGPoint position = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    CGFloat radius = CGRectGetHeight(frame) * 0.5;
    if (CGRectEqualToRect(mask.bounds, bounds) && CGPointEqualToPoint(mask.position, position)) return;
    CALayer *shown = mask.presentationLayer ?: mask;
    CGRect fromBounds = shown.bounds;
    CGPoint fromPosition = shown.position;
    CGFloat fromRadius = shown.cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.bounds = bounds;
    mask.position = position;
    mask.cornerRadius = radius;
    [CATransaction commit];
    if (YTzoomMiniMaskResponse <= 0.0) return;
    YTzoomSpringLayer(mask, @"bounds", [NSValue valueWithCGRect:fromBounds], [NSValue valueWithCGRect:bounds],
                      YTzoomMiniMaskResponse, YTzoomMiniMaskDamping);
    YTzoomSpringLayer(mask, @"position", [NSValue valueWithCGPoint:fromPosition], [NSValue valueWithCGPoint:position],
                      YTzoomMiniMaskResponse, YTzoomMiniMaskDamping);
    YTzoomSpringLayer(mask, @"cornerRadius", @(fromRadius), @(radius), YTzoomMiniMaskResponse, YTzoomMiniMaskDamping);
}

static void YTzoomRemoveMiniMask(UIView *bar) {
    CALayer *mask = objc_getAssociatedObject(bar, YTzoomPivotBarMiniMaskAssociation);
    UIView *container = YTzoomPivotItemsContainer(bar);
    if (mask != nil && container.layer.mask == mask) container.layer.mask = nil;
}

static UIImage *YTzoomRenderItemIcon(UIView *item, CGRect *iconRect) {
    CGSize size = item.bounds.size;
    CGFloat scale = item.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    YTzoomCollectLabels(item, labels);
    NSMutableArray<NSNumber *> *opacity = [NSMutableArray array];
    for (UILabel *label in labels) {
        [opacity addObject:@(label.layer.opacity)];
        label.layer.opacity = 0.0;
    }
    CGFloat alpha = item.alpha;
    item.layer.opacity = 1.0;
    [item.layer renderInContext:context];
    item.layer.opacity = (float)alpha;
    for (NSUInteger index = 0; index < labels.count; index++) {
        labels[index].layer.opacity = opacity[index].floatValue;
    }
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    size_t minX = width, minY = height, maxX = 0, maxY = 0;
    for (size_t y = 0; y < height; y++) {
        for (size_t x = 0; x < width; x++) {
            if (pixels[(y * width + x) * 4 + 3] < 24) continue;
            minX = MIN(minX, x); maxX = MAX(maxX, x);
            minY = MIN(minY, y); maxY = MAX(maxY, y);
        }
    }
    CGImageRef full = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (full == NULL || maxX < minX || maxY < minY) {
        if (full != NULL) CGImageRelease(full);
        return nil;
    }
    CGRect pixelsRect = CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1);
    CGImageRef cropped = CGImageCreateWithImageInRect(full, pixelsRect);
    CGImageRelease(full);
    if (cropped == NULL) return nil;
    UIImage *image = [UIImage imageWithCGImage:cropped scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    if (iconRect != NULL) {
        *iconRect = CGRectMake(pixelsRect.origin.x / scale, pixelsRect.origin.y / scale,
                               pixelsRect.size.width / scale, pixelsRect.size.height / scale);
    }
    return image;
}

static UIImageView *YTzoomMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, YTzoomPivotBarMiniIconAssociation);
    if (icon == nil) {
        icon = [UIImageView new];
        icon.userInteractionEnabled = NO;
        icon.hidden = YES;
        objc_setAssociatedObject(bar, YTzoomPivotBarMiniIconAssociation, icon, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return icon;
}

static CGPoint YTzoomMiniIconHome(UIView *bar, UIView *glass, UIView *selected) {
    NSValue *stored = objc_getAssociatedObject(bar, YTzoomPivotBarMiniIconRectAssociation);
    CGRect rect = stored != nil ? stored.CGRectValue : selected.bounds;
    CGRect inBar = [selected convertRect:rect toView:bar];
    return CGPointMake(CGRectGetMidX(inBar) - CGRectGetMinX(glass.frame),
                       CGRectGetMidY(inBar) - CGRectGetMinY(glass.frame));
}

static void YTzoomApplyMiniAlpha(UIView *bar, BOOL minimized) {
    BOOL applied = [objc_getAssociatedObject(bar, YTzoomPivotBarMiniAppliedAssociation) boolValue];
    if (applied == minimized) return;
    objc_setAssociatedObject(bar, YTzoomPivotBarMiniAppliedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *selected = YTzoomSelectedPivotItem(bar);
    UIView *pill = objc_getAssociatedObject(bar, YTzoomPivotBarPillAssociation);
    pill.alpha = minimized ? 0.0 : 1.0;
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        if (item != selected) item.alpha = minimized ? 0.0 : 1.0;
    }
}

static void YTzoomRestoreMiniIcon(UIView *bar) {
    UIImageView *icon = objc_getAssociatedObject(bar, YTzoomPivotBarMiniIconAssociation);
    if (icon != nil) icon.hidden = YES;
    for (UIView *item in YTzoomSortedPivotItems(bar)) item.alpha = 1.0;
}

static void YTzoomSetBarMinimized(UIView *bar, BOOL minimized) {
    if (bar == nil || YTzoomBarMinimized(bar) == minimized) return;
    UIView *selected = YTzoomSelectedPivotItem(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    if (minimized && (selected == nil || glass == nil ||
                      [YTzoomPivotItemIdentifier(selected) isEqualToString:@"FEshorts"])) return;
    if (minimized) {
        CGRect rect = CGRectZero;
        UIImage *image = YTzoomRenderItemIcon(selected, &rect);
        if (image == nil) return;
        objc_setAssociatedObject(bar, YTzoomPivotBarMiniIconRectAssociation, [NSValue valueWithCGRect:rect],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        UIImageView *icon = YTzoomMiniIcon(bar);
        UIView *host = ((UIVisualEffectView *)glass).contentView;
        if (icon.superview != host) [host addSubview:icon];
        [host bringSubviewToFront:icon];
        [UIView performWithoutAnimation:^{
            icon.image = image;
            icon.bounds = CGRectMake(0, 0, CGRectGetWidth(rect), CGRectGetHeight(rect));
            icon.center = YTzoomMiniIconHome(bar, glass, selected);
            icon.alpha = 1.0;
            icon.hidden = NO;
            selected.alpha = 0.0;
        }];
    }
    objc_setAssociatedObject(bar, YTzoomPivotBarMinimizedAssociation, minimized ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomMinimizeProgress = minimized ? 1.0 : 0.0;
    YTzoomSetBarScale(bar, 1.0, 0.3, 0.8);
    YTzoomInstallMiniMask(bar);
    __weak UIView *weakBar = bar;
    NSTimeInterval response = minimized ? 0.36 : 0.3;
    YTzoomMiniMaskResponse = response;
    YTzoomMiniMaskDamping = 0.72;
    YTzoomBarSpring(response, 0.72, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !YTzoomBarMinimized(strongBar)) YTzoomRestoreMiniIcon(strongBar);
    });
    YTzoomMiniMaskResponse = 0.0;
    UIImageView *miniIcon = objc_getAssociatedObject(bar, YTzoomPivotBarMiniIconAssociation);
    YTzoomBarSpring(minimized ? 0.42 : 0.36, minimized ? 0.76 : 0.72, 0.05, ^{
        YTzoomApplyMiniAlpha(bar, minimized);
        if (!minimized) {
            selected.alpha = 1.0;
            miniIcon.alpha = 0.0;
        }
    }, ^(__unused BOOL finished) {
        UIView *strongBar = weakBar;
        if (strongBar != nil && !YTzoomBarMinimized(strongBar)) YTzoomRemoveMiniMask(strongBar);
    });
}

static void YTzoomSetBarExpanded(UIView *bar, BOOL expanded) {
    if (bar == nil || [objc_getAssociatedObject(bar, YTzoomPivotBarExpandedAssociation) boolValue] == expanded) return;
    objc_setAssociatedObject(bar, YTzoomPivotBarExpandedAssociation, expanded ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *lens = objc_getAssociatedObject(bar, YTzoomPivotBarPillAssociation);
    if (lens != nil) YTzoomTrackLens(lens, 0.7);
    YTzoomLensSpring(0.4, expanded ? 0.5 : 0.25, 0.0, ^{
        [bar setNeedsLayout];
        [bar layoutIfNeeded];
    });
}

static void YTzoomSetSystemLensLifted(UIView *lens, BOOL lifted, __unused NSString *tag,
                                      dispatch_block_t animations, dispatch_block_t done) {
    YTzoomTrackLens(lens, 0.8);
    SEL selector = NSSelectorFromString(@"setLifted:animated:alongsideAnimations:completion:");
    if (![lens respondsToSelector:selector]) {
        [UIView animateWithDuration:0.3 animations:animations completion:^(__unused BOOL finished) {
            if (done != nil) done();
        }];
        return;
    }
    void (^completion)(BOOL) = ^(__unused BOOL finished) {
        if (done != nil) done();
    };
    ((void (*)(id, SEL, BOOL, BOOL, id, id))objc_msgSend)(lens, selector, lifted, YES,
        animations, completion);
}

static void YTzoomUpdateGlassPill(UIView *bar, UIVisualEffectView *glass) {
    UIView *pill = objc_getAssociatedObject(bar, YTzoomPivotBarPillAssociation);
    if (pill == nil) {
        pill = YTzoomMakeSystemLens(bar);
        if (pill == nil) {
            pill = [UIView new];
            pill.userInteractionEnabled = NO;
            pill.layer.cornerCurve = kCACornerCurveContinuous;
            pill.backgroundColor = YTzoomPillColor();
        }
        objc_setAssociatedObject(bar, YTzoomPivotBarPillAssociation, pill,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL dragging = objc_getAssociatedObject(pill, YTzoomPivotBarFadedAssociation) != nil;
    if (dragging) return;
    if (YTzoomIsSystemLens(pill)) {
        UIView *host = glass.contentView;
        if (pill.superview != host) {
            [pill removeFromSuperview];
            host.clipsToBounds = NO;
            [host addSubview:pill];
            YTzoomLensSetObject(pill, @"setLiftedContainerView:", host);
            for (UIView *subview in bar.subviews.copy) {
                if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
            }
        }
    } else if (pill.superview != bar) {
        [pill removeFromSuperview];
        [bar insertSubview:pill aboveSubview:glass];
    } else {
        [bar insertSubview:pill aboveSubview:glass];
    }
    UIView *selected = YTzoomSelectedPivotItem(bar);
    if (selected == nil) {
        pill.hidden = YES;
        return;
    }
    CGRect target = YTzoomPillFrameForItem(bar, glass, selected);
    BOOL systemLens = YTzoomIsSystemLens(pill);
    if (systemLens) target = [bar convertRect:target toView:pill.superview];
    CGRect current = pill.frame;
    if (systemLens) {
        current = CGRectMake(pill.center.x - CGRectGetWidth(pill.bounds) * 0.5,
                             pill.center.y - CGRectGetHeight(pill.bounds) * 0.5,
                             CGRectGetWidth(pill.bounds), CGRectGetHeight(pill.bounds));
    }
    BOOL moved = fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) > 1.0 ||
        fabs(CGRectGetMidY(current) - CGRectGetMidY(target)) > 1.0 ||
        fabs(CGRectGetWidth(current) - CGRectGetWidth(target)) > 1.0 ||
        fabs(CGRectGetHeight(current) - CGRectGetHeight(target)) > 1.0;
    BOOL animate = !pill.hidden && !CGRectIsEmpty(current) && moved;
    pill.hidden = NO;
    if (!systemLens) pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    if (systemLens && !moved) return;
    if (systemLens && (!animate || fabs(CGRectGetMidX(current) - CGRectGetMidX(target)) < 12.0)) {
        [UIView performWithoutAnimation:^{
            pill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
            pill.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        }];
    } else if (animate && systemLens) {
        id token = [NSObject new];
        objc_setAssociatedObject(pill, YTzoomPivotBarFadedAssociation, token,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGPoint center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        CGRect lifted = CGRectMake(0, 0, CGRectGetWidth(target) + 16.0, CGRectGetHeight(target) + 16.0);
        __weak UIView *weakPill = pill;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakPill;
            if (settled != nil && objc_getAssociatedObject(settled, YTzoomPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, YTzoomPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        CGPoint start = pill.center;
        YTzoomSetSystemLensLifted(pill, YES, @"tap", ^{
            pill.bounds = lifted;
            pill.center = start;
        }, nil);
        YTzoomLensSpring(0.4, 0.15, 0.0, ^{ pill.center = center; });
        YTzoomLowerWhenArrived(pill, center, token, ^{
            UIView *strongPill = weakPill;
            if (strongPill == nil ||
                objc_getAssociatedObject(strongPill, YTzoomPivotBarFadedAssociation) != token) return;
            YTzoomSetSystemLensLifted(strongPill, NO, @"tap", ^{
                strongPill.bounds = CGRectMake(0, 0, CGRectGetWidth(target), CGRectGetHeight(target));
                strongPill.center = center;
            }, ^{
                UIView *lens = weakPill;
                if (lens != nil && objc_getAssociatedObject(lens, YTzoomPivotBarFadedAssociation) == token) {
                    objc_setAssociatedObject(lens, YTzoomPivotBarFadedAssociation, nil,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
            });
        });
    } else if (animate) {
        [UIView animateWithDuration:0.35 delay:0.0 usingSpringWithDamping:0.8
              initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ pill.frame = target; } completion:nil];
    } else {
        pill.frame = target;
    }
}

@interface YTzoomGlassSlideHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, assign) BOOL dragging;
@property (nonatomic, assign) BOOL lifted;
@property (nonatomic, assign) CGPoint startPoint;
@property (nonatomic, assign) CGFloat restingWidth;
@property (nonatomic, assign) CFTimeInterval pressStart;
@property (nonatomic, assign) CFTimeInterval lastMove;
@property (nonatomic, assign) CGFloat lastX;
@property (nonatomic, assign) CGFloat velocityX;
@property (nonatomic, assign) CGFloat anchorX;
@property (nonatomic, weak) UIView *touchedItem;
@property (nonatomic, weak) UIControl *heldButton;
@property (nonatomic, assign) NSUInteger pressID;
+ (instancetype)sharedHandler;
- (void)handlePress:(UILongPressGestureRecognizer *)gesture;
- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar;
@end

static NSString *YTzoomPivotItemIdentifier(UIView *item) {
    id renderer = nil;
    @try {
        renderer = [item valueForKey:@"renderer"];
    } @catch (__unused NSException *exception) {
    }
    id identifier = nil;
    @try {
        identifier = [renderer valueForKey:@"pivotIdentifier"];
    } @catch (__unused NSException *exception) {
    }
    return [identifier isKindOfClass:NSString.class] && [identifier length] != 0 ? identifier : nil;
}

static UIImageView *YTzoomFindPhotoView(UIView *view) {
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:UIImageView.class] && !subview.hidden) {
            UIImage *image = ((UIImageView *)subview).image;
            if (image != nil && image.renderingMode != UIImageRenderingModeAlwaysTemplate &&
                CGRectGetWidth(subview.bounds) >= 12.0) {
                return (UIImageView *)subview;
            }
        }
        UIImageView *found = YTzoomFindPhotoView(subview);
        if (found != nil) return found;
    }
    return nil;
}

static UIImageView *YTzoomAvatarView(UIView *bar) {
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        id renderer = nil;
        @try {
            renderer = [item valueForKey:@"renderer"];
        } @catch (__unused NSException *exception) {
        }
        id identifier = nil;
        @try {
            identifier = [renderer valueForKey:@"pivotIdentifier"];
        } @catch (__unused NSException *exception) {
        }
        if ([identifier isEqual:@"FElibrary"]) return YTzoomFindPhotoView(item);
    }
    return nil;
}

static const void *YTzoomStencilSlicesAssociation = &YTzoomStencilSlicesAssociation;

static UIView *YTzoomItemContaining(UIView *view, UIView *bar) {
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        if ([view isDescendantOfView:item]) return item;
    }
    return nil;
}

static void YTzoomSyncStencilSlices(UIView *copy) {
    NSMapTable<UIView *, UIView *> *slices = objc_getAssociatedObject(copy, YTzoomStencilSlicesAssociation);
    if (slices.count == 0) return;
    [UIView performWithoutAnimation:^{
        for (UIView *item in slices) {
            UIView *slice = [slices objectForKey:item];
            if (item.superview == nil) continue;
            CALayer *shown = item.layer.presentationLayer ?: item.layer;
            CGRect frame = [item.superview convertRect:shown.frame toView:copy];
            slice.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
        }
    }];
}

static void YTzoomSyncLensMask(UIView *lens) {
    UIView *copy = objc_getAssociatedObject(lens, YTzoomPivotBarMagnifyAssociation);
    if (copy == nil || lens.superview == nil) return;
    YTzoomSyncStencilSlices(copy);
    UIView *mask = copy.maskView;
    if (mask == nil) {
        mask = [UIView new];
        mask.backgroundColor = UIColor.blackColor;
        mask.layer.cornerCurve = kCACornerCurveContinuous;
        copy.maskView = mask;
    }
    CALayer *shown = lens.layer.presentationLayer ?: lens.layer;
    CGRect lensFrame = shown.frame;
    CGRect frame = [lens.superview convertRect:lensFrame toView:copy];
    mask.frame = frame;
    mask.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    UIView *items = objc_getAssociatedObject(lens, YTzoomPivotBarHoleAssociation);
    if (items == nil) return;
    CAShapeLayer *hole = [items.layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer *)items.layer.mask : nil;
    if (hole == nil) {
        hole = [CAShapeLayer layer];
        hole.fillRule = kCAFillRuleEvenOdd;
        items.layer.mask = hole;
    }
    CGRect lensRect = CGRectInset([lens.superview convertRect:lensFrame toView:items], 4.0, 4.0);
    UIBezierPath *path = [UIBezierPath bezierPathWithRect:CGRectInset(items.bounds, -200.0, -200.0)];
    [path appendPath:[UIBezierPath bezierPathWithRoundedRect:lensRect cornerRadius:CGRectGetHeight(lensRect) * 0.5]];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    hole.frame = items.bounds;
    hole.path = path.CGPath;
    [CATransaction commit];
}

@interface YTzoomLensTracker : NSObject
@property(nonatomic, weak) UIView *lens;
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic, assign) CFTimeInterval until;
@property(nonatomic, copy) dispatch_block_t pendingLower;
@property(nonatomic, assign) CGPoint lowerTarget;
@property(nonatomic, weak) id lowerToken;
@end

@implementation YTzoomLensTracker

- (void)tick {
    UIView *lens = self.lens;
    if (lens == nil || CACurrentMediaTime() > self.until) {
        [self.link invalidate];
        self.link = nil;
        if (lens != nil) YTzoomSyncLensMask(lens);
        return;
    }
    YTzoomSyncLensMask(lens);
    [self checkArrival];
}

- (void)checkArrival {
    UIView *lens = self.lens;
    if (lens == nil || self.pendingLower == nil) return;
    CGPoint shown = (lens.layer.presentationLayer ?: lens.layer).position;
    if (fabs(shown.x - self.lowerTarget.x) >= 8.0) return;
    dispatch_block_t lower = self.pendingLower;
    self.pendingLower = nil;
    if (objc_getAssociatedObject(lens, YTzoomPivotBarFadedAssociation) == self.lowerToken) lower();
}

@end

static const void *YTzoomLensTrackerAssociation = &YTzoomLensTrackerAssociation;

static void YTzoomTrackLens(UIView *lens, CFTimeInterval seconds) {
    if (lens == nil) return;
    YTzoomLensTracker *tracker = objc_getAssociatedObject(lens, YTzoomLensTrackerAssociation);
    if (tracker == nil) {
        tracker = [YTzoomLensTracker new];
        tracker.lens = lens;
        objc_setAssociatedObject(lens, YTzoomLensTrackerAssociation, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tracker.until = MAX(tracker.until, CACurrentMediaTime() + seconds);
    if (tracker.link == nil) {
        tracker.link = [CADisplayLink displayLinkWithTarget:tracker selector:@selector(tick)];
        [tracker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

static void YTzoomLowerWhenArrived(UIView *lens, CGPoint target, id token, dispatch_block_t lower) {
    if (lens == nil) return;
    YTzoomTrackLens(lens, 1.0);
    YTzoomLensTracker *tracker = objc_getAssociatedObject(lens, YTzoomLensTrackerAssociation);
    tracker.pendingLower = lower;
    tracker.lowerTarget = target;
    tracker.lowerToken = token;
    __weak YTzoomLensTracker *weakTracker = tracker;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTzoomLensTracker *strongTracker = weakTracker;
        if (strongTracker.pendingLower == nil || strongTracker.pendingLower != lower) return;
        strongTracker.pendingLower = nil;
        UIView *strongLens = strongTracker.lens;
        if (strongLens != nil && objc_getAssociatedObject(strongLens, YTzoomPivotBarFadedAssociation) == token) lower();
    });
}

static void YTzoomClearLensHole(UIView *lens) {
    UIView *items = objc_getAssociatedObject(lens, YTzoomPivotBarHoleAssociation);
    items.layer.mask = nil;
    objc_setAssociatedObject(lens, YTzoomPivotBarHoleAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static UIView *YTzoomScrubTarget(UIView *bar, CGPoint point, UIEvent *event);
static UIView *YTzoomInlinePlayerBar(UIView *bar);

@implementation YTzoomGlassSlideHandler

+ (instancetype)sharedHandler {
    static YTzoomGlassSlideHandler *handler;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ handler = [YTzoomGlassSlideHandler new]; });
    return handler;
}

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    if (glass == nil) return NO;
    if (YTzoomBarMinimized(bar)) {
        YTzoomSetBarMinimized(bar, NO);
        return NO;
    }
    CGPoint point = [gesture locationInView:bar];
    if (!CGRectContainsPoint(glass.frame, point)) return NO;
    UIView *scrub = YTzoomScrubTarget(bar, point, nil);
    if (scrub != nil && scrub != YTzoomInlinePlayerBar(bar)) return NO;
    UIView *touched = [self pivotItemNearX:point.x inView:bar bar:bar];
    if (touched != nil && YTzoomPivotItemIdentifier(touched) == nil) return NO;
    gesture.cancelsTouchesInView = touched == nil || touched != YTzoomSelectedPivotItem(bar);
    return YES;
}



- (UIVisualEffectView *)lensForBar:(UIView *)bar {
    UIVisualEffectView *lens = objc_getAssociatedObject(bar, YTzoomPivotBarLensAssociation);
    if (lens == nil) {
        lens = [[UIVisualEffectView alloc] initWithEffect:YTzoomMakeGlassEffect(YES)];
        lens.userInteractionEnabled = NO;
        lens.layer.cornerCurve = kCACornerCurveContinuous;
        lens.clipsToBounds = YES;
        objc_setAssociatedObject(bar, YTzoomPivotBarLensAssociation, lens,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (lens.superview != bar) [bar addSubview:lens];
    [bar bringSubviewToFront:lens];
    return lens;
}

- (UIView *)pivotItemNearX:(CGFloat)x inView:(UIView *)view bar:(UIView *)bar {
    NSArray<UIView *> *sorted = YTzoomSortedPivotItems(bar);
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    if (sorted.count == 0 || glass == nil) return nil;
    CGFloat barX = [view convertPoint:CGPointMake(x, 0.0) toView:bar].x;
    CGFloat start = 0.0, slot = 0.0, overlap = 0.0;
    YTzoomTabGeometry(glass.frame, sorted.count, &start, &slot, &overlap);
    NSInteger index = slot > 0.0 ? (NSInteger)floor((barX - start - overlap * 0.5) / slot) : 0;
    index = MAX(0, MIN((NSInteger)sorted.count - 1, index));
    return sorted[(NSUInteger)index];
}

- (UIControl *)buttonForItem:(UIView *)item {
    SEL buttonSelector = NSSelectorFromString(@"navigationButton");
    if (![item respondsToSelector:buttonSelector]) return nil;
    UIControl *button = ((id (*)(id, SEL))objc_msgSend)(item, buttonSelector);
    return [button isKindOfClass:UIControl.class] ? button : nil;
}

- (UIView *)stencilForItems:(UIView *)items {
    CGSize size = items.bounds.size;
    CGFloat scale = items.window.screen.scale ?: 3.0;
    size_t width = (size_t)ceil(size.width * scale);
    size_t height = (size_t)ceil(size.height * scale);
    if (width == 0 || height == 0) return nil;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return nil;
    CGContextTranslateCTM(context, 0.0, (CGFloat)height);
    CGContextScaleCTM(context, scale, -scale);
    NSMutableArray<UIView *> *flipped = [NSMutableArray array];
    SEL setSelected = NSSelectorFromString(@"setSelected:");
    YTzoomStencilRendering = YES;
    UIView *bar = items.superview;
    UIImageView *avatar = YTzoomAvatarView(bar);
    BOOL avatarHidden = avatar.hidden;
    avatar.hidden = YES;
    NSMutableArray<UIView *> *draggedOut = [NSMutableArray array];
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        if ([objc_getAssociatedObject(item, YTzoomTabDragOutAssociation) boolValue]) {
            objc_setAssociatedObject(item, YTzoomTabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [draggedOut addObject:item];
        }
    }
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        if (YTzoomPivotItemSelected(item) || ![item respondsToSelector:setSelected]) continue;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, YES);
        [item layoutIfNeeded];
        [flipped addObject:item];
    }
    CALayer *hole = items.layer.mask;
    items.layer.mask = nil;
    [items.layer renderInContext:context];
    items.layer.mask = hole;
    for (UIView *item in flipped) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, setSelected, NO);
        [item layoutIfNeeded];
    }
    for (UIView *item in draggedOut) {
        objc_setAssociatedObject(item, YTzoomTabDragOutAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    avatar.hidden = avatarHidden;
    YTzoomStencilRendering = NO;
    uint8_t *pixels = (uint8_t *)CGBitmapContextGetData(context);
    double total = 0.0;
    double weight = 0.0;
    for (size_t index = 0; index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        if (pixel[3] < 128) continue;
        uint8_t peak = MAX(pixel[0], MAX(pixel[1], pixel[2]));
        total += (double)peak / (double)pixel[3];
        weight += 1.0;
    }
    BOOL brightIcons = weight == 0.0 || total / weight > 0.5;
    BOOL keepColor = YTzoomTintMode != 0;
    for (size_t index = 0; !keepColor && index < width * height; index++) {
        uint8_t *pixel = pixels + index * 4;
        uint8_t alpha = pixel[3];
        uint8_t level = 0;
        if (alpha > 0) {
            CGFloat color = (CGFloat)MAX(pixel[0], MAX(pixel[1], pixel[2])) / (CGFloat)alpha;
            CGFloat contrast = brightIcons ? color : 1.0 - color;
            CGFloat ratio = MAX(0.0, MIN(1.0, (contrast - 0.5) / 0.35));
            level = (uint8_t)(ratio * (CGFloat)alpha);
        }
        pixel[0] = level;
        pixel[1] = level;
        pixel[2] = level;
        pixel[3] = level;
    }
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == NULL) return nil;
    UIView *view = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, size.width, size.height)];
    UIColor *tint = brightIcons ? UIColor.whiteColor : UIColor.blackColor;
    NSMapTable<UIView *, UIView *> *slices = [NSMapTable weakToStrongObjectsMapTable];
    CGRect whole = CGRectMake(0.0, 0.0, size.width, size.height);
    for (UIView *item in YTzoomSortedPivotItems(bar)) {
        CGRect frame = CGRectIntersection([item convertRect:item.bounds toView:items], whole);
        if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) continue;
        CGRect pixels = CGRectMake(floor(frame.origin.x * scale), floor(frame.origin.y * scale),
                                   ceil(frame.size.width * scale), ceil(frame.size.height * scale));
        CGImageRef piece = CGImageCreateWithImageInRect(image, pixels);
        if (piece == NULL) continue;
        UIImageView *slice = [[UIImageView alloc] initWithImage:
            [[UIImage imageWithCGImage:piece scale:scale orientation:UIImageOrientationUp]
                imageWithRenderingMode:keepColor ? UIImageRenderingModeAlwaysOriginal
                                                 : UIImageRenderingModeAlwaysTemplate]];
        CGImageRelease(piece);
        slice.frame = CGRectMake(pixels.origin.x / scale, pixels.origin.y / scale,
                                 pixels.size.width / scale, pixels.size.height / scale);
        slice.tintColor = tint;
        [view addSubview:slice];
        [slices setObject:slice forKey:item];
    }
    CGImageRelease(image);
    if (avatar != nil && !avatarHidden && avatar.image != nil && avatar.window != nil) {
        CGRect face = [avatar convertRect:avatar.bounds toView:items];
        CGFloat radius = MIN(avatar.layer.cornerRadius, MIN(face.size.width, face.size.height) * 0.5);
        if (radius <= 0.0) radius = MIN(face.size.width, face.size.height) * 0.5;
        UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
        format.scale = scale;
        UIImage *photo = [[[UIGraphicsImageRenderer alloc] initWithSize:face.size format:format]
            imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            CGRect bounds = CGRectMake(0.0, 0.0, face.size.width, face.size.height);
            [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius] addClip];
            CGSize source = avatar.image.size;
            CGFloat fill = source.width > 0.0 && source.height > 0.0
                ? MAX(bounds.size.width / source.width, bounds.size.height / source.height) : 1.0;
            CGSize drawn = CGSizeMake(source.width * fill, source.height * fill);
            [avatar.image drawInRect:CGRectMake((bounds.size.width - drawn.width) * 0.5,
                                                (bounds.size.height - drawn.height) * 0.5,
                                                drawn.width, drawn.height)];
        }];
        UIImageView *photoSlice = [[UIImageView alloc] initWithImage:photo];
        photoSlice.frame = face;
        [view addSubview:photoSlice];
        UIView *owner = YTzoomItemContaining(avatar, bar);
        if (owner != nil) {
            UIView *holder = [slices objectForKey:owner];
            if (holder != nil) {
                photoSlice.frame = [view convertRect:face toView:holder];
                [holder addSubview:photoSlice];
            }
        }
    }
    objc_setAssociatedObject(view, YTzoomStencilSlicesAssociation, slices, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return view;
}

- (void)attachMagnifierToLens:(UIView *)lens bar:(UIView *)bar {
    UIView *old = objc_getAssociatedObject(lens, YTzoomPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = YTzoomPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy == nil || lens.superview == nil) return;
    copy.userInteractionEnabled = NO;
    copy.frame = [items convertRect:items.bounds toView:lens.superview];
    [lens.superview insertSubview:copy atIndex:0];
    YTzoomLensSetObject(lens, @"setLiftedContentView:", copy);
    objc_setAssociatedObject(lens, YTzoomPivotBarMagnifyAssociation, copy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(lens, YTzoomPivotBarHoleAssociation, items, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomSyncLensMask(lens);
}

- (void)liftLens:(UIView *)lens bar:(UIView *)bar size:(CGSize)size center:(CGPoint)center {
    YTzoomSetBarExpanded(bar, YES);
    NSUInteger pressID = self.pressID;
    __weak UIView *weakLens = lens;
    __weak UIView *weakBar = bar;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *strongLens = weakLens;
        if (strongLens == nil || weakBar == nil || !self.lifted || self.pressID != pressID) return;
        [self attachMagnifierToLens:strongLens bar:weakBar];
    });
    UIView *old = objc_getAssociatedObject(lens, YTzoomPivotBarMagnifyAssociation);
    [old removeFromSuperview];
    UIView *items = YTzoomPivotItemsContainer(bar);
    UIView *copy = [self stencilForItems:items];
    if (copy != nil && lens.superview != nil) {
        copy.userInteractionEnabled = NO;
        copy.frame = [items convertRect:items.bounds toView:lens.superview];
        [lens.superview insertSubview:copy atIndex:0];
        YTzoomLensSetObject(lens, @"setLiftedContentView:", copy);
        objc_setAssociatedObject(lens, YTzoomPivotBarMagnifyAssociation, copy,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(lens, YTzoomPivotBarHoleAssociation, items,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTzoomSyncLensMask(lens);
    }
    self.lifted = YES;
    YTzoomSetSystemLensLifted(lens, YES, @"press", ^{
        lens.bounds = CGRectMake(0, 0, size.width, size.height);
        YTzoomSyncLensMask(lens);
    }, nil);
    YTzoomLensSpring(0.4, 0.15, 0.0, ^{ lens.center = center; });
}

- (void)handleSystemLens:(UIView *)lens gesture:(UILongPressGestureRecognizer *)gesture
                     bar:(UIView *)bar glass:(UIView *)glass {
    UIView *host = lens.superview ?: bar;
    CGPoint point = [gesture locationInView:bar];
    UIView *selectedNow = YTzoomSelectedPivotItem(bar);
    CGRect restingFrame = selectedNow != nil
        ? [bar convertRect:YTzoomPillFrameForItem(bar, (UIVisualEffectView *)glass, selectedNow) toView:host]
        : lens.frame;
    CGFloat lensWidth = self.lifted ? self.restingWidth : CGRectGetWidth(restingFrame);
    CGFloat width = lensWidth + 16.0;
    CGFloat height = CGRectGetHeight(restingFrame) + 16.0;
    if (gesture.state == UIGestureRecognizerStateBegan) {
        UIView *grabbed = [self pivotItemNearX:point.x inView:bar bar:bar];
        CGRect slot = grabbed != nil ? YTzoomPillFrameForItem(bar, (UIVisualEffectView *)glass, grabbed) : CGRectNull;
        self.anchorX = CGRectIsNull(slot) || CGRectGetWidth(slot) <= 0.0
            ? 0.5 : MAX(0.0, MIN(1.0, (point.x - CGRectGetMinX(slot)) / CGRectGetWidth(slot)));
    }
    CGFloat anchor = self.anchorX;
    CGFloat clamped = MAX(CGRectGetMinX(glass.frame) + lensWidth * anchor,
                          MIN(point.x, CGRectGetMaxX(glass.frame) - lensWidth * (1.0 - anchor)));
    CGFloat centerX = clamped - lensWidth * anchor + lensWidth * 0.5;
    CGPoint center = [bar convertPoint:CGPointMake(centerX, CGRectGetMidY(glass.frame)) toView:host];
    CFTimeInterval now = CACurrentMediaTime();
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(lens, YTzoomPivotBarFadedAssociation, [NSObject new],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        self.pressStart = now;
        self.lastMove = now;
        self.lastX = point.x;
        self.velocityX = 0.0;
        self.startPoint = point;
        self.dragging = NO;
        self.lifted = NO;
        self.restingWidth = CGRectGetWidth(restingFrame);
        self.touchedItem = [self pivotItemNearX:point.x inView:bar bar:bar];
        self.heldButton = nil;
        self.pressID += 1;
        UIView *selected = YTzoomSelectedPivotItem(bar);
        BOOL same = self.touchedItem == selected;
        for (UIView *subview in bar.subviews.copy) {
            if ([NSStringFromClass(subview.class) containsString:@"DestOutView"]) [subview removeFromSuperview];
        }
        (void)same;
        if (self.touchedItem != nil) {
            [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
        }
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        CFTimeInterval step = now - self.lastMove;
        if (step > 0.001) {
            CGFloat instant = (point.x - self.lastX) / step;
            self.velocityX = instant * 0.6 + self.velocityX * 0.4;
            self.lastX = point.x;
            self.lastMove = now;
        }
        if (!self.dragging && fabs(point.x - self.startPoint.x) > 4.0) {
            self.dragging = YES;
            if (!gesture.cancelsTouchesInView) {
                self.heldButton = [self buttonForItem:self.touchedItem];
            }
            if (!self.lifted) {
                [self liftLens:lens bar:bar size:CGSizeMake(width, height) center:center];
                return;
            }
        }
        if (!self.lifted) return;
        YTzoomLensSpring(0.2, 0.15, 0.0, ^{ lens.center = center; });
        YTzoomTrackLens(lens, 0.4);
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    BOOL dragging = self.dragging;
    self.pressID += 1;
    YTzoomSetBarExpanded(bar, NO);
    UIView *draggedFrom = self.touchedItem;
    if ([objc_getAssociatedObject(draggedFrom, YTzoomTabDragOutAssociation) boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            objc_setAssociatedObject(draggedFrom, YTzoomTabDragOutAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTzoomApplyPivotItemPresentation(draggedFrom);
        });
    }
    UIControl *heldButton = self.heldButton;
    self.heldButton = nil;
    if (!self.lifted) {
        BOOL bump = !dragging && gesture.state == UIGestureRecognizerStateEnded &&
            self.touchedItem != nil && self.touchedItem == YTzoomSelectedPivotItem(bar);
        if (!bump) {
            objc_setAssociatedObject(lens, YTzoomPivotBarFadedAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *tapped = self.touchedItem;
            if (gesture.state == UIGestureRecognizerStateEnded && tapped != nil &&
                YTzoomPivotItemIdentifier(tapped) != nil && tapped != YTzoomSelectedPivotItem(bar)) {
                YTzoomSelectPivotItem(tapped);
            }
            return;
        }
        id bumpToken = [NSObject new];
        objc_setAssociatedObject(lens, YTzoomPivotBarFadedAssociation, bumpToken,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CGRect resting = restingFrame;
        CGPoint middle = CGPointMake(CGRectGetMidX(resting), CGRectGetMidY(resting));
        __weak UIView *weakBump = lens;
        YTzoomSetSystemLensLifted(lens, YES, @"bump", ^{
            lens.bounds = CGRectMake(0, 0, CGRectGetWidth(resting) + 14.0, CGRectGetHeight(resting) + 10.0);
            lens.center = middle;
        }, nil);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped == nil || objc_getAssociatedObject(bumped, YTzoomPivotBarFadedAssociation) != bumpToken) return;
            YTzoomSetSystemLensLifted(bumped, NO, @"bump", ^{
                bumped.bounds = CGRectMake(0, 0, CGRectGetWidth(resting), CGRectGetHeight(resting));
                bumped.center = middle;
            }, nil);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *bumped = weakBump;
            if (bumped != nil && objc_getAssociatedObject(bumped, YTzoomPivotBarFadedAssociation) == bumpToken) {
                objc_setAssociatedObject(bumped, YTzoomPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        return;
    }
    self.lifted = NO;
    id token = [NSObject new];
    objc_setAssociatedObject(lens, YTzoomPivotBarFadedAssociation, token,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *nearest = dragging ? [self pivotItemNearX:point.x inView:bar bar:bar] : self.touchedItem;
    if (gesture.state == UIGestureRecognizerStateCancelled) nearest = YTzoomSelectedPivotItem(bar);
    if (nearest != nil && YTzoomPivotItemIdentifier(nearest) == nil) nearest = YTzoomSelectedPivotItem(bar);
    CGRect target = nearest != nil
        ? [bar convertRect:YTzoomPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) toView:host]
        : lens.frame;
    __weak UIView *weakLens = lens;
    CGPoint slide = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
    YTzoomLensSpring(0.4, 0.15, 0.0, ^{
        lens.center = slide;
        YTzoomSyncLensMask(lens);
    });
    YTzoomLowerWhenArrived(lens, slide, token, ^{
        UIView *lowering = weakLens;
        if (lowering == nil || objc_getAssociatedObject(lowering, YTzoomPivotBarFadedAssociation) != token) return;
        UIView *copy = objc_getAssociatedObject(lowering, YTzoomPivotBarMagnifyAssociation);
        copy.hidden = YES;
        YTzoomClearLensHole(lowering);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIView *settled = weakLens;
            if (settled != nil && objc_getAssociatedObject(settled, YTzoomPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(settled, YTzoomPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
        YTzoomSetSystemLensLifted(lowering, NO, @"up", ^{
            lowering.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
            lowering.center = slide;
            YTzoomSyncLensMask(lowering);
        }, ^{
            UIView *strongLens = weakLens;
            if (strongLens != nil && objc_getAssociatedObject(strongLens, YTzoomPivotBarFadedAssociation) == token) {
                objc_setAssociatedObject(strongLens, YTzoomPivotBarFadedAssociation, nil,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        });
    });
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != YTzoomSelectedPivotItem(bar)) {
        if (heldButton != nil) {
            __weak UIView *weakNearest = nearest;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *pick = weakNearest;
                if (pick != nil && pick != YTzoomSelectedPivotItem(bar)) YTzoomSelectPivotItem(pick);
            });
        } else {
            YTzoomSelectPivotItem(nearest);
        }
    }
}

- (CGFloat)lensCenterForPoint:(CGPoint)point bar:(UIView *)bar glass:(UIView *)glass width:(CGFloat)width {
    return MAX(CGRectGetMinX(glass.frame) + width * 0.35,
               MIN(point.x, CGRectGetMaxX(glass.frame) - width * 0.35));
}

- (void)handlePress:(UILongPressGestureRecognizer *)gesture {
    UIView *bar = gesture.view;
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    UIView *pill = objc_getAssociatedObject(bar, YTzoomPivotBarPillAssociation);
    if (glass == nil || pill == nil) return;
    if (YTzoomIsSystemLens(pill)) {
        [self handleSystemLens:pill gesture:gesture bar:bar glass:glass];
        return;
    }
    UIVisualEffectView *lens = [self lensForBar:bar];
    CGPoint point = [gesture locationInView:bar];
    CGFloat width = MAX(CGRectGetWidth(pill.frame), 80.0) + 26.0;
    CGFloat height = CGRectGetHeight(glass.frame) + 18.0;
    CGFloat centerX = [self lensCenterForPoint:point bar:bar glass:glass width:width];
    CGPoint center = CGPointMake(centerX, CGRectGetMidY(glass.frame));
    if (gesture.state == UIGestureRecognizerStateBegan) {
        objc_setAssociatedObject(pill, YTzoomPivotBarFadedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        lens.bounds = pill.bounds.size.width > 0 ? pill.bounds : CGRectMake(0, 0, width, height);
        lens.center = pill.frame.size.width > 0
            ? CGPointMake(CGRectGetMidX(pill.frame), CGRectGetMidY(pill.frame)) : center;
        lens.layer.cornerRadius = CGRectGetHeight(lens.bounds) * 0.5;
        lens.alpha = 0.0;
        lens.hidden = NO;
        [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.7
              initialSpringVelocity:0.5 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            lens.alpha = 1.0;
            lens.bounds = CGRectMake(0, 0, width, height);
            lens.layer.cornerRadius = height * 0.5;
            lens.center = center;
            pill.alpha = 0.0;
        } completion:nil];
        return;
    }
    if (gesture.state == UIGestureRecognizerStateChanged) {
        [UIView animateWithDuration:0.12 delay:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState |
                                    UIViewAnimationOptionCurveEaseOut
                         animations:^{ lens.center = center; } completion:nil];
        return;
    }
    if (gesture.state != UIGestureRecognizerStateEnded &&
        gesture.state != UIGestureRecognizerStateCancelled) {
        return;
    }
    objc_setAssociatedObject(pill, YTzoomPivotBarFadedAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIView *> *items = [NSMutableArray array];
    YTzoomCollectPivotItems(bar, items);
    UIView *nearest = nil;
    CGFloat best = CGFLOAT_MAX;
    for (UIView *item in items) {
        if (item.hidden || CGRectGetWidth(item.bounds) <= 0.0) continue;
        CGFloat distance = fabs(CGRectGetMidX([item convertRect:item.bounds toView:bar]) - lens.center.x);
        if (distance < best) {
            best = distance;
            nearest = item;
        }
    }
    CGRect target = nearest != nil
        ? YTzoomPillFrameForItem(bar, (UIVisualEffectView *)glass, nearest) : pill.frame;
    pill.frame = target;
    pill.layer.cornerRadius = CGRectGetHeight(target) * 0.5;
    [UIView animateWithDuration:0.32 delay:0.0 usingSpringWithDamping:0.8
          initialSpringVelocity:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        lens.bounds = CGRectMake(0, 0, target.size.width, target.size.height);
        lens.layer.cornerRadius = target.size.height * 0.5;
        lens.center = CGPointMake(CGRectGetMidX(target), CGRectGetMidY(target));
        lens.alpha = 0.0;
        pill.alpha = 1.0;
    } completion:^(BOOL finished) {
        if (finished) lens.hidden = YES;
    }];
    if (gesture.state == UIGestureRecognizerStateEnded && nearest != nil &&
        nearest != YTzoomSelectedPivotItem(bar)) {
        YTzoomSelectPivotItem(nearest);
    }
}

@end

static void YTzoomInstallGlassSlide(UIView *bar) {
    for (UIGestureRecognizer *recognizer in bar.gestureRecognizers) {
        if (recognizer.delegate == [YTzoomGlassSlideHandler sharedHandler]) return;
    }
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[YTzoomGlassSlideHandler sharedHandler] action:@selector(handlePress:)];
    press.minimumPressDuration = 0.0;
    press.allowableMovement = CGFLOAT_MAX;
    press.cancelsTouchesInView = NO;
    press.delaysTouchesEnded = NO;
    press.delegate = [YTzoomGlassSlideHandler sharedHandler];
    [bar addGestureRecognizer:press];
}

BOOL YTzoomLiquidGlassAvailable(void) {
    return NSClassFromString(@"UIGlassEffect") != Nil;
}

static BOOL YTzoomViewLooksLikeScrubber(UIView *view, NSUInteger depth) {
    NSString *name = NSStringFromClass(view.class).lowercaseString;
    for (NSString *word in @[@"scrub", @"progress", @"playerbar", @"slider", @"seek", @"timebar"]) {
        if ([name containsString:word]) return YES;
    }
    if (depth == 0) return NO;
    for (UIView *subview in view.subviews) {
        if (YTzoomViewLooksLikeScrubber(subview, depth - 1)) return YES;
    }
    return NO;
}

static UIView *YTzoomInlinePlayerBar(UIView *bar) {
    Class playerBarClass = NSClassFromString(@"YTInlinePlayerBarContainerView");
    if (playerBarClass == Nil || objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation) == nil) return nil;
    for (UIView *child in bar.subviews) {
        if ([child isKindOfClass:playerBarClass] && !child.hidden && child.alpha > 0.01 &&
            child.userInteractionEnabled && child.window != nil) {
            return child;
        }
    }
    return nil;
}

static UIView *YTzoomScrubTarget(UIView *bar, CGPoint point, UIEvent *event) {
    UIView *playerBar = YTzoomInlinePlayerBar(bar);
    if (playerBar == nil) return nil;
    CGPoint local = [bar convertPoint:point toView:playerBar];
    if (CGRectContainsPoint(playerBar.bounds, local)) return [playerBar hitTest:local withEvent:event];
    UIView *glass = objc_getAssociatedObject(bar, YTzoomPivotBarGlassAssociation);
    if (point.y >= CGRectGetMinY(glass.frame) + 12.0) return nil;
    Class gestureClass = NSClassFromString(@"YTInlineScrubGestureView");
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:playerBar];
    while (queue.count != 0) {
        UIView *node = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (gestureClass != Nil && [node isKindOfClass:gestureClass] && !node.hidden && node.userInteractionEnabled) {
            CGPoint inside = [bar convertPoint:point toView:node];
            return CGRectContainsPoint(node.bounds, inside) ? node : nil;
        }
        [queue addObjectsFromArray:node.subviews];
    }
    return nil;
}

static IMP OriginalPivotBarPointInside;
static IMP OriginalPivotBarHitTest;

static BOOL YTzoomPivotBarPointInside(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    BOOL inside = OriginalPivotBarPointInside != NULL &&
        ((BOOL (*)(id, SEL, CGPoint, id))OriginalPivotBarPointInside)(receiver, selector, point, event);
    if (YTzoomBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, YTzoomPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point);
    }
    if (inside) return YES;
    UIView *playerBar = YTzoomInlinePlayerBar(receiver);
    return playerBar != nil && CGRectContainsPoint(playerBar.frame, point);
}

static UIView *YTzoomPivotBarHitTest(UIView *receiver, SEL selector, CGPoint point, UIEvent *event) {
    if (YTzoomBarMinimized(receiver)) {
        UIView *glass = objc_getAssociatedObject(receiver, YTzoomPivotBarGlassAssociation);
        return glass != nil && CGRectContainsPoint(CGRectInset(glass.frame, -6.0, -6.0), point) ? receiver : nil;
    }
    UIView *scrub = YTzoomScrubTarget(receiver, point, event);
    if (scrub != nil && scrub != YTzoomInlinePlayerBar(receiver)) return scrub;
    if (!CGRectContainsPoint(receiver.bounds, point)) return nil;
    return OriginalPivotBarHitTest == NULL ? nil
        : ((id (*)(id, SEL, CGPoint, id))OriginalPivotBarHitTest)(receiver, selector, point, event);
}

static CGFloat const YTzoomMinimizeDistance = 64.0;
static BOOL YTzoomMinimizeActive;
static __weak UIScrollView *YTzoomMinimizeScroll;
static CGFloat YTzoomMinimizeLastOffset;
static const void *YTzoomMinimizePanAssociation = &YTzoomMinimizePanAssociation;

static BOOL YTzoomMinimizeEligible(UIScrollView *scrollView, UIView *bar) {
    UIWindow *window = bar.window;
    if (window == nil || scrollView.window != window || bar.hidden || bar.alpha < 0.01) return NO;
    if (CGRectGetHeight(scrollView.bounds) < CGRectGetHeight(window.bounds) * 0.4) return NO;
    CGFloat range = scrollView.contentSize.height + scrollView.adjustedContentInset.top +
        scrollView.adjustedContentInset.bottom - CGRectGetHeight(scrollView.bounds);
    if (range < YTzoomMinimizeDistance * 1.5) return NO;
    if (!CGRectIntersectsRect([bar convertRect:bar.bounds toView:window], window.bounds)) return NO;
    UIView *selected = YTzoomSelectedPivotItem(bar);
    return selected != nil && ![YTzoomPivotItemIdentifier(selected) isEqualToString:@"FEshorts"];
}

static void YTzoomApplyMinimizeProgress(UIView *bar, CGFloat progress, BOOL tracking) {
    YTzoomMinimizeProgress = progress;
    CGFloat scale = (progress <= 0.0 || progress >= 1.0) ? 1.0 : 1.0 - progress * 0.05;
    if (tracking) YTzoomSetBarScale(bar, scale, 0.1, 0.8);
    else YTzoomSetBarScale(bar, scale, 0.3, 0.8);
}

@interface YTzoomMinimizePanTracker : NSObject
@end

@implementation YTzoomMinimizePanTracker

- (void)pan:(UIPanGestureRecognizer *)pan {
    UIScrollView *scrollView = (UIScrollView *)pan.view;
    UIView *bar = YTzoomMinimizeBar;
    if (!YTzoomMinimizeEnabled || bar == nil || ![scrollView isKindOfClass:UIScrollView.class]) return;
    if (pan.state == UIGestureRecognizerStateBegan) {
        if (!YTzoomMinimizeEligible(scrollView, bar)) return;
        YTzoomMinimizeActive = YES;
        YTzoomMinimizeScroll = scrollView;
        YTzoomMinimizeLastOffset = scrollView.contentOffset.y;
        return;
    }
    if (pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled &&
        pan.state != UIGestureRecognizerStateFailed) return;
    if (!YTzoomMinimizeActive || YTzoomMinimizeScroll != scrollView) return;
    YTzoomMinimizeActive = NO;
    BOOL minimized = YTzoomBarMinimized(bar);
    CGFloat progress = YTzoomMinimizeProgress;
    CGFloat velocity = -[pan velocityInView:scrollView].y;
    if (pan.state == UIGestureRecognizerStateEnded && fabs(velocity) > 50.0) {
        CGFloat rate = scrollView.decelerationRate;
        CGFloat travel = velocity / 1000.0 * rate / MAX(0.0001, 1.0 - rate);
        CGFloat minY = -scrollView.adjustedContentInset.top;
        CGFloat maxY = MAX(minY, scrollView.contentSize.height + scrollView.adjustedContentInset.bottom -
                                 CGRectGetHeight(scrollView.bounds));
        CGFloat target = MAX(minY, MIN(maxY, scrollView.contentOffset.y + travel));
        progress += (target - scrollView.contentOffset.y) / YTzoomMinimizeDistance;
        if (target <= minY + 0.5) progress = 0.0;
    }
    if (progress >= 1.0) {
        if (minimized) YTzoomApplyMinimizeProgress(bar, 1.0, NO);
        else YTzoomSetBarMinimized(bar, YES);
    } else if (minimized) {
        YTzoomSetBarMinimized(bar, NO);
    } else {
        YTzoomApplyMinimizeProgress(bar, 0.0, NO);
    }
}

@end

static IMP OriginalScrollSetContentOffset;

static NSUInteger YTzoomShortsClipGeneration;

static NSArray<UIView *> *YTzoomShortsClipViews(UIScrollView *pager) {
    NSMutableArray<UIView *> *views = [NSMutableArray arrayWithObject:pager];
    for (UIView *view = pager.superview.superview.superview; view != nil && views.count < 3; view = view.superview) {
        if ([view isKindOfClass:NSClassFromString(@"YTAppView")]) break;
        if (view.clipsToBounds) [views addObject:view];
    }
    return views;
}

static const void *YTzoomShortsClipViewsAssociation = &YTzoomShortsClipViewsAssociation;
static const void *YTzoomShortsCoverAssociation = &YTzoomShortsCoverAssociation;

static UIView *YTzoomShortsCover(UIScrollView *pager, NSArray<UIView *> *views, BOOL create) {
    UIView *cover = objc_getAssociatedObject(pager, YTzoomShortsCoverAssociation);
    if (cover != nil || !create) return cover;
    UIView *outer = views.lastObject;
    if (outer == nil || outer.window == nil) return nil;
    CGRect frame = [outer convertRect:outer.bounds toView:nil];
    CGFloat below = CGRectGetHeight(outer.window.bounds) - CGRectGetMaxY(frame);
    if (below <= 0.5) return nil;
    cover = [[UIView alloc] initWithFrame:CGRectMake(0.0, CGRectGetHeight(outer.bounds), CGRectGetWidth(outer.bounds), below)];
    cover.backgroundColor = UIColor.blackColor;
    cover.userInteractionEnabled = NO;
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;
    [outer addSubview:cover];
    UIView *backing = [[UIView alloc] initWithFrame:[outer.superview convertRect:cover.frame fromView:outer]];
    backing.backgroundColor = UIColor.blackColor;
    backing.userInteractionEnabled = NO;
    backing.autoresizingMask = cover.autoresizingMask;
    [outer.superview insertSubview:backing belowSubview:outer];
    objc_setAssociatedObject(cover, YTzoomShortsCoverAssociation, backing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(pager, YTzoomShortsCoverAssociation, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return cover;
}

static void YTzoomFadeShortsCover(UIView *cover, CGFloat alpha, void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:0.2 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ cover.alpha = alpha; }
                     completion:completion];
}

static void YTzoomSetShortsClipping(UIScrollView *pager, BOOL clips) {
    NSArray<UIView *> *views = objc_getAssociatedObject(pager, YTzoomShortsClipViewsAssociation);
    if (!clips) {
        if (views == nil) {
            views = YTzoomShortsClipViews(pager);
            objc_setAssociatedObject(pager, YTzoomShortsClipViewsAssociation, views, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        UIView *cover = YTzoomShortsCover(pager, views, YES);
        cover.alpha = 1.0;
        for (UIView *view in views) view.clipsToBounds = NO;
        if (cover != nil) YTzoomFadeShortsCover(cover, 0.0, nil);
        return;
    }
    UIView *cover = YTzoomShortsCover(pager, views, NO);
    void (^reclip)(void) = ^{
        for (UIView *view in views) view.clipsToBounds = YES;
        [(UIView *)objc_getAssociatedObject(cover, YTzoomShortsCoverAssociation) removeFromSuperview];
        [cover removeFromSuperview];
        objc_setAssociatedObject(pager, YTzoomShortsCoverAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(pager, YTzoomShortsClipViewsAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    if (cover == nil) {
        reclip();
        return;
    }
    NSUInteger generation = YTzoomShortsClipGeneration;
    __weak UIScrollView *weakPager = pager;
    YTzoomFadeShortsCover(cover, 1.0, ^(__unused BOOL finished) {
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != YTzoomShortsClipGeneration ||
            strongPager.isDragging || strongPager.isDecelerating) return;
        reclip();
    });
}

static void YTzoomScheduleShortsReclip(UIScrollView *pager, NSUInteger generation) {
    __weak UIScrollView *weakPager = pager;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIScrollView *strongPager = weakPager;
        if (strongPager == nil || generation != YTzoomShortsClipGeneration) return;
        if (strongPager.isDragging || strongPager.isDecelerating) {
            YTzoomScheduleShortsReclip(strongPager, generation);
            return;
        }
        YTzoomSetShortsClipping(strongPager, YES);
    });
}

static void YTzoomShortsSeeThrough(UIScrollView *receiver) {
    static Class pagerClass;
    static Class rootClass;
    if (pagerClass == Nil) {
        pagerClass = NSClassFromString(@"YTAsyncCollectionView");
        rootClass = NSClassFromString(@"YTReelWatchRootView");
    }
    if (pagerClass == Nil || rootClass == Nil || [receiver class] != pagerClass) return;
    if (![receiver.superview.superview isKindOfClass:rootClass]) return;
    if (!receiver.isDragging && !receiver.isDecelerating) return;
    UIView *cover = objc_getAssociatedObject(receiver, YTzoomShortsCoverAssociation);
    if (cover != nil && cover.layer.presentationLayer.opacity > 0.01 && cover.alpha > 0.0) {
        YTzoomFadeShortsCover(cover, 0.0, nil);
    }
    if (objc_getAssociatedObject(receiver, YTzoomShortsClipViewsAssociation) == nil) {
        YTzoomSetShortsClipping(receiver, NO);
        static BOOL logged;
        if (!logged) {
            logged = YES;
            NSMutableArray *names = [NSMutableArray array];
            for (UIView *view in objc_getAssociatedObject(receiver, YTzoomShortsClipViewsAssociation))
                [names addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(view.class),
                                  NSStringFromCGRect([view convertRect:view.bounds toView:nil])]];
            YTzoomDownloadLog(@"glass", @"shorts unclip %@", [names componentsJoinedByString:@" < "]);
        }
    }
    YTzoomScheduleShortsReclip(receiver, ++YTzoomShortsClipGeneration);
}

static void YTzoomScrollSetContentOffset(UIScrollView *receiver, SEL selector, CGPoint offset) {
    if (OriginalScrollSetContentOffset != NULL) {
        ((void (*)(id, SEL, CGPoint))OriginalScrollSetContentOffset)(receiver, selector, offset);
    }
    YTzoomShortsSeeThrough(receiver);
    if (!YTzoomMinimizeEnabled) return;
    UIView *bar = YTzoomMinimizeBar;
    if (bar == nil) return;
    if (objc_getAssociatedObject(receiver, YTzoomMinimizePanAssociation) == nil && receiver.isTracking) {
        static YTzoomMinimizePanTracker *tracker;
        if (tracker == nil) tracker = [YTzoomMinimizePanTracker new];
        objc_setAssociatedObject(receiver, YTzoomMinimizePanAssociation, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [receiver.panGestureRecognizer addTarget:tracker action:@selector(pan:)];
        if (YTzoomMinimizeEligible(receiver, bar)) {
            YTzoomMinimizeActive = YES;
            YTzoomMinimizeScroll = receiver;
            YTzoomMinimizeLastOffset = receiver.contentOffset.y;
        }
        return;
    }
    if (receiver != YTzoomMinimizeScroll) return;
    CGFloat y = receiver.contentOffset.y;
    BOOL minimized = YTzoomBarMinimized(bar);
    if (y <= -receiver.adjustedContentInset.top + 0.5) {
        YTzoomMinimizeLastOffset = y;
        if (minimized) YTzoomSetBarMinimized(bar, NO);
        else if (YTzoomMinimizeProgress > 0.0) YTzoomApplyMinimizeProgress(bar, 0.0, receiver.isTracking);
        return;
    }
    if (!YTzoomMinimizeActive || !receiver.isTracking) return;
    CGFloat delta = y - YTzoomMinimizeLastOffset;
    YTzoomMinimizeLastOffset = y;
    if (fabs(delta) < 0.01) return;
    CGFloat progress = YTzoomMinimizeProgress + delta / YTzoomMinimizeDistance;
    progress = MAX(minimized ? 0.01 : 0.0, MIN(1.0, progress));
    if (!minimized && progress >= 1.0) {
        YTzoomMinimizeActive = NO;
        YTzoomSetBarMinimized(bar, YES);
        return;
    }
    YTzoomApplyMinimizeProgress(bar, progress, YES);
}

static IMP OriginalHidePivotBarOnScroll;
static IMP OriginalUpdatePivotBarVisibility;

static BOOL YTzoomHidePivotBarOnScroll(id receiver, SEL selector) {
    if (YTzoomMinimizeEnabled) return NO;
    return OriginalHidePivotBarOnScroll != NULL &&
        ((BOOL (*)(id, SEL))OriginalHidePivotBarOnScroll)(receiver, selector);
}

static void YTzoomUpdatePivotBarVisibility(id receiver, SEL selector, UIScrollView *scrollView,
                                           CGFloat offsetY, BOOL atBottom) {
    if (YTzoomMinimizeEnabled) return;
    if (OriginalUpdatePivotBarVisibility != NULL) {
        ((void (*)(id, SEL, id, CGFloat, BOOL))OriginalUpdatePivotBarVisibility)(
            receiver, selector, scrollView, offsetY, atBottom);
    }
}

static const void *YTzoomShortsBackdropAssociation = &YTzoomShortsBackdropAssociation;

static void YTzoomApplyShortsBackdrop(UIView *bar, BOOL shorts) {
    UIView *host = bar.superview;
    if (host == nil) return;
    id saved = objc_getAssociatedObject(host, YTzoomShortsBackdropAssociation);
    if (shorts) {
        if (saved == nil) {
            objc_setAssociatedObject(host, YTzoomShortsBackdropAssociation, host.backgroundColor ?: (id)NSNull.null,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        host.backgroundColor = UIColor.blackColor;
    } else if (saved != nil) {
        host.backgroundColor = saved == NSNull.null ? nil : saved;
        objc_setAssociatedObject(host, YTzoomShortsBackdropAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static BOOL YTzoomApplyPivotBarGlass(UIView *receiver, UIView *blur) {
    UIVisualEffectView *glass = objc_getAssociatedObject(receiver, YTzoomPivotBarGlassAssociation);
    BOOL wanted = YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.Glass") &&
        YTzoomLiquidGlassAvailable();
    if (!wanted) {
        if (glass != nil) {
            [glass removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, YTzoomPivotBarPillAssociation) removeFromSuperview];
            [(UIView *)objc_getAssociatedObject(receiver, YTzoomPivotBarLensAssociation) removeFromSuperview];
            objc_setAssociatedObject(receiver, YTzoomPivotBarLensAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, YTzoomPivotBarPillAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(receiver, YTzoomPivotBarGlassAssociation, nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            blur.hidden = NO;
            for (UIView *view in YTzoomPivotFadedViews(receiver).allObjects) view.alpha = 1.0;
            [YTzoomPivotFadedViews(receiver) removeAllObjects];
        }
        return NO;
    }
    if (glass == nil) {
        glass = [[UIVisualEffectView alloc] initWithEffect:YTzoomMakeGlassEffect(NO)];
        glass.userInteractionEnabled = NO;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = NO;
        objc_setAssociatedObject(receiver, YTzoomPivotBarGlassAssociation, glass,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    blur.hidden = YES;
    NSHashTable<UIView *> *faded = YTzoomPivotFadedViews(receiver);
    UIView *ownPill = objc_getAssociatedObject(receiver, YTzoomPivotBarPillAssociation);
    UIView *ownLens = objc_getAssociatedObject(receiver, YTzoomPivotBarLensAssociation);
    for (UIView *sibling in receiver.subviews) {
        if (sibling == glass || sibling == ownPill || sibling == ownLens) continue;
        if (YTzoomViewContainsPivotItem(sibling)) {
            sibling.opaque = NO;
            sibling.backgroundColor = UIColor.clearColor;
        } else if (sibling.alpha > 0.0 && !YTzoomViewLooksLikeScrubber(sibling, 3) &&
                   (CGRectGetHeight(sibling.frame) >= CGRectGetHeight(receiver.bounds) * 0.6 ||
                    CGRectGetHeight(sibling.frame) <= 1.5)) {
            sibling.alpha = 0.0;
            [faded addObject:sibling];
        }
    }
    receiver.backgroundColor = UIColor.clearColor;
    receiver.layer.backgroundColor = UIColor.clearColor.CGColor;
    receiver.opaque = NO;
    if (glass.superview != receiver) {
        [glass removeFromSuperview];
        [receiver insertSubview:glass atIndex:0];
    } else {
        [receiver sendSubviewToBack:glass];
    }
    CGFloat itemHeight = CGRectGetHeight(receiver.bounds) - receiver.safeAreaInsets.bottom;
    CGFloat extra = 7.0;
    CGFloat glassHeight = MAX(itemHeight, 44.0) + extra * 2.0;
    CGFloat glassTop = MIN(0.0, CGRectGetHeight(receiver.bounds) - glassHeight - 4.0);
    BOOL expanded = [objc_getAssociatedObject(receiver, YTzoomPivotBarExpandedAssociation) boolValue];
    NSUInteger tabs = 0;
    for (UIView *item in YTzoomSortedPivotItems(receiver)) {
        if (!item.hidden && CGRectGetWidth(item.bounds) > 0.0) tabs += 1;
    }
    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    CGFloat margin = expanded ? 14.0 : 21.0;
    CGFloat glassWidth = barWidth - margin * 2.0;
    if (tabs > 0 && tabs <= 4) {
        glassWidth = MIN(glassWidth, 86.0 * (CGFloat)tabs + 16.0);
    }
    CGRect frame = CGRectMake((barWidth - glassWidth) * 0.5, glassTop, glassWidth, glassHeight);
    UIView *current = YTzoomSelectedPivotItem(receiver);
    BOOL darkBar = current != nil && [YTzoomPivotItemIdentifier(current) isEqualToString:@"FEshorts"];
    YTzoomMinimizeEnabled = YTzoomFeatureEnabled(YTzoomMinimizeKey);
    YTzoomMinimizeBar = receiver;
    BOOL minimized = YTzoomBarMinimized(receiver);
    if (minimized && (!YTzoomMinimizeEnabled || darkBar || current == nil)) {
        objc_setAssociatedObject(receiver, YTzoomPivotBarMinimizedAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        minimized = NO;
        YTzoomApplyMiniAlpha(receiver, NO);
        YTzoomRestoreMiniIcon(receiver);
        YTzoomRemoveMiniMask(receiver);
    }
    if (!YTzoomMinimizeEnabled || darkBar) {
        YTzoomMinimizeProgress = 0.0;
        YTzoomSetBarScale(receiver, 1.0, 0.0, 1.0);
    }
    CGRect fullFrame = frame;
    CGFloat circle = MIN(48.0, glassHeight);
    if (minimized) {
        frame = CGRectMake(28.0, CGRectGetMidY(frame) - circle * 0.5, circle, circle);
    }
    receiver.clipsToBounds = NO;
    receiver.layer.masksToBounds = NO;
    glass.frame = frame;
    glass.layer.cornerRadius = CGRectGetHeight(frame) * 0.5;
    YTzoomUpdateMiniMask(receiver, frame);
    YTzoomApplyShortsBackdrop(receiver, darkBar);
    UIUserInterfaceStyle style = darkBar ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleUnspecified) {
        glass.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
    }
    if (!YTzoomStencilRendering && current != nil && receiver.overrideUserInterfaceStyle != style) {
        receiver.overrideUserInterfaceStyle = style;
        for (UIView *item in YTzoomSortedPivotItems(receiver)) YTzoomApplyPivotItemPresentation(item);
    }
    glass.alpha = 1.0;
    YTzoomLayoutItemsInGlass(receiver, fullFrame);
    UIImageView *miniIcon = objc_getAssociatedObject(receiver, YTzoomPivotBarMiniIconAssociation);
    if (miniIcon != nil && !miniIcon.hidden && current != nil) {
        miniIcon.center = minimized ? CGPointMake(CGRectGetWidth(frame) * 0.5, CGRectGetHeight(frame) * 0.5)
                                    : YTzoomMiniIconHome(receiver, glass, current);
    }
    if (!minimized) YTzoomUpdateGlassPill(receiver, glass);
    YTzoomInstallGlassSlide(receiver);
    return YES;
}

static IMP OriginalSearchOptOutFrostedPivot;

static BOOL YTzoomSearchOptOutFrostedPivot(__unused id receiver, __unused SEL selector) {
    return NO;
}

NSInteger YTzoomFrostedTabBarMode(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTzoom.Preference.Tabs.Frosted"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.FrostedHidden") ? 2 : 0;
}

static IMP OriginalFrostedPermitted;

static BOOL YTzoomFrostedPermitted(id receiver, SEL selector) {
    NSInteger mode = YTzoomMasterEnabled() ? YTzoomFrostedTabBarMode() : 0;
    if (YTzoomLiquidGlassAvailable() && YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.Glass")) return YES;
    if (mode == 1) return YES;
    if (mode == 2) return NO;
    return OriginalFrostedPermitted != NULL && ((BOOL (*)(id, SEL))OriginalFrostedPermitted)(receiver, selector);
}

static void YTzoomApplyPivotBarBackground(UIView *receiver) {
    if (YTzoomRefreshTabTint()) {
        for (UIView *item in YTzoomSortedPivotItems(receiver)) {
            YTzoomRestyleSelectedTab(item);
            YTzoomApplyPivotItemPresentation(item);
        }
    }
    SEL blurSelector = NSSelectorFromString(@"blurView");
    UIView *blur = [receiver respondsToSelector:blurSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, blurSelector)
        : nil;
    if (YTzoomApplyPivotBarGlass(receiver, blur)) return;
    BOOL applied = [objc_getAssociatedObject(
        receiver, YTzoomPivotBarSolidAssociation) boolValue];
    if (!YTzoomMasterEnabled() || YTzoomFrostedTabBarMode() != 2) {
        if (!applied) return;
        blur.hidden = NO;
        receiver.backgroundColor = UIColor.clearColor;
        receiver.opaque = NO;
        objc_setAssociatedObject(receiver, YTzoomPivotBarSolidAssociation,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    UIUserInterfaceStyle style = receiver.traitCollection.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = receiver.window.traitCollection.userInterfaceStyle;
    }
    UIColor *solid = style == UIUserInterfaceStyleDark
        ? UIColor.blackColor
        : UIColor.whiteColor;
    blur.hidden = YES;
    for (UIView *sibling in receiver.subviews) {
        if (sibling != blur && [sibling isKindOfClass:UIVisualEffectView.class]) {
            sibling.hidden = YES;
        }
    }
    receiver.backgroundColor = solid;
    receiver.opaque = YES;
    objc_setAssociatedObject(receiver, YTzoomPivotBarSolidAssociation,
                             @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomRefreshPivotBarsInView(UIView *view) {
    if ([NSStringFromClass(view.class) isEqualToString:@"YTPivotBarView"]) {
        YTzoomApplyPivotBarBackground(view);
        return;
    }
    for (UIView *subview in view.subviews) {
        YTzoomRefreshPivotBarsInView(subview);
    }
}

void YTzoomRefreshPivotBarBackground(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden) YTzoomRefreshPivotBarsInView(window);
        }
    }
}

static void YTzoomPivotBarStyleColors(UIView *receiver, SEL selector) {
    if (OriginalPivotBarStyleColors != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarStyleColors)(receiver, selector);
    }
    YTzoomApplyPivotBarBackground(receiver);
}

static void YTzoomPivotBarSetBackgroundStyle(UIView *receiver, SEL selector,
                                             int style) {
    if (OriginalPivotBarSetBackgroundStyle != NULL) {
        ((void (*)(id, SEL, int))OriginalPivotBarSetBackgroundStyle)(
            receiver, selector, style);
    }
    YTzoomApplyPivotBarBackground(receiver);
}

static NSString *YTzoomStartupTabToken(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:@"YTzoom.Preference.Tabs.Startup"];
    if ([stored isKindOfClass:NSString.class]) return stored;
    NSArray<NSString *> *legacy = @[@"", @"explore", @"subscriptions",
                                    @"shorts", @"library"];
    NSInteger index = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    NSString *token = (index > 0 && index < (NSInteger)legacy.count)
        ? legacy[(NSUInteger)index] : @"";
    [defaults setObject:token forKey:@"YTzoom.Preference.Tabs.Startup"];
    return token;
}

static NSString *YTzoomStartupPivotIdentifier(NSString *token) {
    if (token.length == 0) return nil;
    NSDictionary<NSString *, NSString *> *known = @{
        @"home": @"FEwhat_to_watch",
        @"explore": @"FEexplore",
        @"subscriptions": @"FEsubscriptions",
        @"shorts": @"FEshorts",
        @"library": @"FElibrary",
        @"you": @"FElibrary"
    };
    NSString *identifier = known[token];
    if (identifier.length != 0) return identifier;
    return YTzoomStartupIdentifiers[token];
}

static __weak id YTzoomPivotBarControllerRef;

static id YTzoomPivotControllerForView(UIView *view) {
    if (YTzoomPivotBarControllerRef != nil) return YTzoomPivotBarControllerRef;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder respondsToSelector:lookup]) {
            YTzoomPivotBarControllerRef = responder;
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static BOOL YTzoomNavigateToPivot(id controller, NSString *identifier) {
    if (controller == nil || identifier.length == 0) return NO;
    SEL lookup = NSSelectorFromString(@"pivotBarItemForIdentifier:");
    SEL tap = NSSelectorFromString(@"didTapItemWithRenderer:");
    if (![controller respondsToSelector:lookup] ||
        ![controller respondsToSelector:tap]) {
        return NO;
    }
    id item = ((id (*)(id, SEL, id))objc_msgSend)(controller, lookup, identifier);
    if (item == nil) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, tap, item);
    return YES;
}

static void YTzoomApplyStartupTab(UIView *receiver) {
    if (YTzoomStartupApplied) return;
    NSString *token = YTzoomStartupTabToken();
    if (token.length == 0) {
        YTzoomStartupApplied = YES;
        return;
    }
    static NSTimeInterval firstSeen = 0.0;
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (firstSeen == 0.0) firstSeen = now;
    if (now - firstSeen > 8.0) {
        YTzoomStartupApplied = YES;
        return;
    }

    NSString *identifier = YTzoomStartupPivotIdentifier(token);
    id controller = YTzoomPivotControllerForView(receiver);
    if (identifier.length == 0) return;

    id target = controller ?: receiver;
    SEL current = NSSelectorFromString(@"selectedPivotIdentifier");
    if ([target respondsToSelector:current]) {
        id selected = ((id (*)(id, SEL))objc_msgSend)(target, current);
        if ([selected isKindOfClass:NSString.class] &&
            [selected caseInsensitiveCompare:identifier] == NSOrderedSame) {
            YTzoomStartupApplied = YES;
            return;
        }
    }

    if (YTzoomNavigateToPivot(controller, identifier)) return;

    SEL select = NSSelectorFromString(@"selectItemWithPivotIdentifier:");
    if ([target respondsToSelector:select]) {
        ((void (*)(id, SEL, id))objc_msgSend)(target, select, identifier);
    }
}

static void YTzoomSetDefaultSelectedPivot(id receiver, SEL selector, id identifier) {
    NSString *wanted = YTzoomStartupPivotIdentifier(YTzoomStartupTabToken());
    if (wanted.length != 0 && !YTzoomStartupApplied) {
        YTzoomStartupNative = YES;
        identifier = wanted;
    }
    if (OriginalSetDefaultSelectedPivot != NULL) {
        ((void (*)(id, SEL, id))OriginalSetDefaultSelectedPivot)(receiver, selector,
                                                                identifier);
    }
}

static void YTzoomScheduleStartupTab(id controller) {
    if (YTzoomStartupApplied) return;
    if (YTzoomStartupTabToken().length == 0) {
        YTzoomStartupApplied = YES;
        return;
    }
    static BOOL scheduled = NO;
    if (scheduled) return;
    scheduled = YES;
    const double delay = YTzoomStartupNative ? 0.0 : 0.35;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        scheduled = NO;
        SEL pivotView = NSSelectorFromString(@"pivotBarView");
        UIView *view = [controller respondsToSelector:pivotView]
            ? ((id (*)(id, SEL))objc_msgSend)(controller, pivotView)
            : nil;
        YTzoomApplyStartupTab(view);
        if (!YTzoomStartupApplied) YTzoomScheduleStartupTab(controller);
    });
}

static void YTzoomPivotControllerAppear(id receiver, SEL selector, BOOL animated) {
    if (OriginalPivotControllerAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotControllerAppear)(receiver, selector,
                                                                animated);
    }
    YTzoomPivotBarControllerRef = receiver;
    YTzoomScheduleStartupTab(receiver);
}

static void YTzoomPivotBarLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotBarLayout)(receiver, selector);
    }
    YTzoomHideCreateViews(receiver);
    YTzoomApplyPivotBarBackground(receiver);
}

static void YTzoomPivotItemLayout(UIView *receiver, SEL selector) {
    if (OriginalPivotItemLayout != NULL) {
        ((void (*)(id, SEL))OriginalPivotItemLayout)(receiver, selector);
    }
    YTzoomApplyPivotItemPresentation(receiver);
}

static void YTzoomPivotItemSetSelected(UIView *receiver,
                                       SEL selector,
                                       BOOL selected) {
    BOOL wasSelected = [objc_getAssociatedObject(receiver, YTzoomTabSelectedAssociation) boolValue];
    if (OriginalPivotItemSetSelected != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPivotItemSetSelected)(
            receiver, selector, selected
        );
    }
    objc_setAssociatedObject(receiver,
                             YTzoomTabSelectedAssociation,
                             @(selected),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomApplyPivotItemPresentation(receiver);
    if (YTzoomStencilRendering) return;
    if (selected) {
        UIView *bar = receiver.superview;
        while (bar != nil && ![NSStringFromClass(bar.class) isEqualToString:@"YTPivotBarView"]) {
            bar = bar.superview;
        }
        if (!wasSelected) YTzoomSetBarMinimized(bar, NO);
        [bar setNeedsLayout];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomApplyPivotItemPresentation(receiver);
    });
}

static void YTzoomPivotItemTraitChanged(UIView *receiver,
                                        SEL selector,
                                        UITraitCollection *previous) {
    if (OriginalPivotItemTraitChanged != NULL) {
        ((void (*)(id, SEL, id))OriginalPivotItemTraitChanged)(
            receiver, selector, previous
        );
    }
    YTzoomApplyPivotItemPresentation(receiver);
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomApplyPivotItemPresentation(receiver);
    });
    if (YTzoomFeatureEnabled(YTzoomOLEDKey) &&
        !YTzoomNavigationRefreshScheduled) {
        YTzoomNavigationRefreshScheduled = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomNavigationRefreshScheduled = NO;
            YTzoomRefreshNavigationAppearance();
        });
    }
}

void YTzoomInstallTabBarHooks(void) {
    YTzoomRefreshTabTint();
    YTzoomInstallInstanceHook(@"YTPivotBarItemView",
                              @"iconTintColorSelected",
                              (IMP)YTzoomIconTintSelected,
                              &OriginalIconTintSelected);
    YTzoomInstallInstanceHook(@"UILabel",
                              @"setTextColor:",
                              (IMP)YTzoomPivotLabelSetTextColor,
                              &OriginalPivotLabelSetTextColor);
    YTzoomInstallInstanceHook(@"UILabel",
                              @"setHidden:",
                              (IMP)YTzoomPivotLabelSetHidden,
                              &OriginalPivotLabelSetHidden);
    YTzoomInstallInstanceHook(@"UILabel",
                              @"setAlpha:",
                              (IMP)YTzoomPivotLabelSetAlpha,
                              &OriginalPivotLabelSetAlpha);
    YTzoomInstallInstanceHook(@"YTQTMButton",
                              @"layoutSubviews",
                              (IMP)YTzoomPivotButtonLayout,
                              &OriginalPivotButtonLayout);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"setRenderer:",
                              (IMP)YTzoomSetPivotRenderer,
                              &OriginalSetPivotRenderer);
    YTzoomInstallInstanceHook(@"YTPivotBarItemView",
                              @"layoutSubviews",
                              (IMP)YTzoomPivotItemLayout,
                              &OriginalPivotItemLayout);
    YTzoomInstallInstanceHook(@"YTPivotBarItemView",
                              @"setSelected:",
                              (IMP)YTzoomPivotItemSetSelected,
                              &OriginalPivotItemSetSelected);
    YTzoomInstallInstanceHook(@"YTPivotBarItemView",
                              @"traitCollectionDidChange:",
                              (IMP)YTzoomPivotItemTraitChanged,
                              &OriginalPivotItemTraitChanged);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"layoutSubviews",
                              (IMP)YTzoomPivotBarLayout,
                              &OriginalPivotBarLayout);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"pointInside:withEvent:",
                              (IMP)YTzoomPivotBarPointInside,
                              &OriginalPivotBarPointInside);
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Tabs.Glass") && YTzoomLiquidGlassAvailable()) {
        YTzoomInstallInstanceHook(@"UIScrollView",
                                  @"setContentOffset:",
                                  (IMP)YTzoomScrollSetContentOffset,
                                  &OriginalScrollSetContentOffset);
        YTzoomInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"hidePivotBarOnScroll",
                                  (IMP)YTzoomHidePivotBarOnScroll,
                                  &OriginalHidePivotBarOnScroll);
        YTzoomInstallInstanceHook(@"YTScrollableNavigationController",
                                  @"updatePivotBarVisibilityForScrollView:contentOffsetY:isAtBottom:",
                                  (IMP)YTzoomUpdatePivotBarVisibility,
                                  &OriginalUpdatePivotBarVisibility);
        YTzoomInstallInstanceHook(@"YTSearchResultsViewController",
                                  @"optOutOfFrostedPivotBar",
                                  (IMP)YTzoomSearchOptOutFrostedPivot,
                                  &OriginalSearchOptOutFrostedPivot);
    }
    YTzoomInstallInstanceHook(@"YTPivotBarViewController",
                              @"isFrostedPivotBarPermitted",
                              (IMP)YTzoomFrostedPermitted,
                              &OriginalFrostedPermitted);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"hitTest:withEvent:",
                              (IMP)YTzoomPivotBarHitTest,
                              &OriginalPivotBarHitTest);
    YTzoomInstallInstanceHook(@"YTPivotBarViewController",
                              @"viewDidAppear:",
                              (IMP)YTzoomPivotControllerAppear,
                              &OriginalPivotControllerAppear);
    YTzoomInstallInstanceHook(@"YTAppPivotBarController",
                              @"setDefaultSelectedPivotIdentifier:",
                              (IMP)YTzoomSetDefaultSelectedPivot,
                              &OriginalSetDefaultSelectedPivot);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"styleBackgroundColors",
                              (IMP)YTzoomPivotBarStyleColors,
                              &OriginalPivotBarStyleColors);
    YTzoomInstallInstanceHook(@"YTPivotBarView",
                              @"setBackgroundStyle:",
                              (IMP)YTzoomPivotBarSetBackgroundStyle,
                              &OriginalPivotBarSetBackgroundStyle);
    YTzoomInstallInstanceHook(@"YTAppViewController",
                              @"viewDidLoad",
                              (IMP)YTzoomAppViewDidLoad,
                              &OriginalAppViewDidLoad);
    YTzoomInstallInstanceHook(@"YTBrowseViewController",
                              @"viewDidLoad",
                              (IMP)YTzoomBrowseViewDidLoad,
                              &OriginalBrowseViewDidLoad);
    YTzoomInstallInstanceHook(@"YTBrowseResponseViewController",
                              @"viewDidLoad",
                              (IMP)YTzoomBrowseResponseViewDidLoad,
                              &OriginalBrowseResponseViewDidLoad);
    YTzoomInstallInstanceHook(@"YTWrapperFlatViewController",
                              @"viewDidLoad",
                              (IMP)YTzoomWrapperViewDidLoad,
                              &OriginalWrapperViewDidLoad);
}
