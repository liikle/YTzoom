#import "../Downloads/DownloadLog.h"
#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <objc/message.h>

static IMP OriginalBrowseLoadResponse;
static IMP OriginalBrowseLoadInitialResponse;

static BOOL YTzoomHomeBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] && ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static NSInteger YTzoomHomeInt(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? (NSInteger)((int (*)(id, SEL))objc_msgSend)(object, selector) : -1;
}

static id YTzoomHomeObject(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static void YTzoomHomeSetBool(id object, NSString *name, BOOL value) {
    SEL selector = NSSelectorFromString(name);
    if ([object respondsToSelector:selector]) ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static IMP OriginalFoxScrollableTabs;
static IMP OriginalFoxCollapsingTabs;
static IMP OriginalFoxIosCollapsingTabs;

static BOOL YTzoomFoxFlag(IMP original, id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.HomeTabsHidden")) return NO;
    return original != NULL && ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTzoomFoxScrollableTabs(id receiver, SEL selector) {
    return YTzoomFoxFlag(OriginalFoxScrollableTabs, receiver, selector);
}

static BOOL YTzoomFoxCollapsingTabs(id receiver, SEL selector) {
    return YTzoomFoxFlag(OriginalFoxCollapsingTabs, receiver, selector);
}

static BOOL YTzoomFoxIosCollapsingTabs(id receiver, SEL selector) {
    return YTzoomFoxFlag(OriginalFoxIosCollapsingTabs, receiver, selector);
}

static NSString *YTzoomHomeTabBrowseID(id tab) {
    id renderer = YTzoomHomeObject(tab, @"tabRenderer");
    id endpoint = YTzoomHomeObject(YTzoomHomeObject(renderer, @"endpoint"), @"browseEndpoint");
    id browseID = YTzoomHomeObject(endpoint, @"browseId");
    return [browseID isKindOfClass:NSString.class] ? browseID : nil;
}

static id YTzoomHomeNew(NSString *name) {
    Class cls = NSClassFromString(name);
    return cls != Nil ? [cls new] : nil;
}

static void YTzoomHomeSet(id object, NSString *name, id value) {
    SEL selector = NSSelectorFromString(name);
    if (object != nil && value != nil && [object respondsToSelector:selector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
    }
}

static id YTzoomHomeExtension(NSString *className, NSInteger field) {
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%@|%ld", className, (long)field];
    if (cache[key] != nil) return cache[key] == NSNull.null ? nil : cache[key];
    if (cache == nil) cache = [NSMutableDictionary dictionary];
    id result = nil;
    Class registryClass = NSClassFromString(@"GoogleGlobalExtensionRegistry");
    Class target = NSClassFromString(className);
    SEL registrySel = NSSelectorFromString(@"extensionRegistry");
    SEL lookup = NSSelectorFromString(@"extensionForDescriptor:fieldNumber:");
    if (registryClass != Nil && target != Nil && [registryClass respondsToSelector:registrySel] &&
        [target respondsToSelector:@selector(descriptor)]) {
        id registry = ((id (*)(id, SEL))objc_msgSend)(registryClass, registrySel);
        id descriptor = ((id (*)(id, SEL))objc_msgSend)(target, @selector(descriptor));
        if ([registry respondsToSelector:lookup]) {
            result = ((id (*)(id, SEL, id, NSInteger))objc_msgSend)(registry, lookup, descriptor, field);
        }
    }
    cache[key] = result ?: NSNull.null;
    return result;
}

static id YTzoomHomeWrap(NSString *className, NSInteger field, id value) {
    id extension = YTzoomHomeExtension(className, field);
    id wrapper = YTzoomHomeNew(className);
    SEL setter = NSSelectorFromString(@"setExtension:value:");
    if (extension == nil || wrapper == nil || value == nil || ![wrapper respondsToSelector:setter]) return nil;
    ((void (*)(id, SEL, id, id))objc_msgSend)(wrapper, setter, extension, value);
    return wrapper;
}

static id YTzoomHomeReloadData(id tab) {
    id list = YTzoomHomeObject(YTzoomHomeObject(YTzoomHomeObject(tab, @"tabRenderer"), @"content"), @"sectionListRenderer");
    for (id continuation in YTzoomHomeObject(list, @"continuationsArray")) {
        id data = YTzoomHomeObject(continuation, @"reloadContinuationData");
        if ([YTzoomHomeObject(data, @"continuation") length] != 0) return data;
    }
    return nil;
}

static id YTzoomHomeReloadCommand(id data) {
    id endpoint = YTzoomHomeNew(@"YTIBrowseSectionListReloadEndpoint");
    id continuations = YTzoomHomeNew(@"YTIBrowseSectionListReloadSupportedContinuations");
    if (data == nil || endpoint == nil || continuations == nil) return nil;
    YTzoomHomeSet(continuations, @"setReloadContinuationData:", data);
    YTzoomHomeSet(endpoint, @"setContinuation:", continuations);
    return YTzoomHomeWrap(@"YTICommand", 120837120, endpoint);
}

static id YTzoomHomeChip(NSString *title, NSInteger icon, id command, BOOL selected) {
    id chip = YTzoomHomeNew(@"YTIChipCloudChipRenderer");
    if (chip == nil) return nil;
    id style = YTzoomHomeNew(@"YTIChipCloudChipStyle");
    id styleDescriptor = ((id (*)(id, SEL))objc_msgSend)(NSClassFromString(@"YTIChipCloudChipStyle"), @selector(descriptor));
    id field = ((id (*)(id, SEL, id))objc_msgSend)(styleDescriptor, NSSelectorFromString(@"fieldWithName:"), @"styleType");
    id enumDescriptor = YTzoomHomeObject(field, @"enumDescriptor");
    int32_t value = 0;
    SEL lookup = NSSelectorFromString(@"getValue:forEnumTextFormatName:");
    if ([enumDescriptor respondsToSelector:lookup] &&
        ((BOOL (*)(id, SEL, int32_t *, id))objc_msgSend)(enumDescriptor, lookup, &value, @"STYLE_HOME_FILTER")) {
        ((void (*)(id, SEL, int))objc_msgSend)(style, NSSelectorFromString(@"setStyleType:"), value);
        YTzoomHomeSet(chip, @"setStyle:", style);
    }
    if (title.length != 0) {
        Class formatted = NSClassFromString(@"YTIFormattedString");
        SEL make = NSSelectorFromString(@"formattedStringWithString:");
        if ([formatted respondsToSelector:make]) {
            YTzoomHomeSet(chip, @"setText:", ((id (*)(id, SEL, id))objc_msgSend)(formatted, make, title));
        }
    }
    if (icon > 0) {
        id image = YTzoomHomeNew(@"YTIIcon");
        ((void (*)(id, SEL, int))objc_msgSend)(image, NSSelectorFromString(@"setIconType:"), (int)icon);
        YTzoomHomeSet(chip, @"setIcon:", image);
    }
    YTzoomHomeSet(chip, @"setNavigationEndpoint:", command);
    YTzoomHomeSetBool(chip, @"setIsSelected:", selected);
    return YTzoomHomeWrap(@"YTIRenderer", 91394224, chip);
}

static void YTzoomHomeBuildChips(NSArray *tabs, id home) {
    id list = YTzoomHomeObject(YTzoomHomeObject(YTzoomHomeObject(home, @"tabRenderer"), @"content"), @"sectionListRenderer");
    if (list == nil) return;
    id header = YTzoomHomeObject(list, @"header");
    if (YTzoomHomeBool(list, @"hasHeader") && YTzoomHomeBool(header, @"hasFeedFilterChipBarRenderer")) return;
    id bar = YTzoomHomeNew(@"YTIFeedFilterChipBarRenderer");
    NSMutableArray *contents = YTzoomHomeObject(bar, @"contentsArray");
    if (![contents isKindOfClass:NSMutableArray.class]) return;
    id homeReload = nil;
    for (id continuation in YTzoomHomeObject(list, @"continuationsArray")) {
        id data = YTzoomHomeObject(continuation, @"reloadContinuationData");
        if ([YTzoomHomeObject(data, @"continuation") length] != 0) homeReload = data;
    }
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = YTzoomHomeObject(tab, @"tabRenderer");
        if (!YTzoomHomeBool(renderer, @"unselectable")) continue;
        id command = YTzoomHomeObject(renderer, @"endpoint");
        NSInteger icon = YTzoomHomeInt(renderer, @"tabIcon");
        if (command == nil || icon <= 0) continue;
        id chip = YTzoomHomeChip(nil, icon, command, NO);
        if (chip != nil) [contents addObject:chip];
        Class dividerClass = YTzoomHomeObject(YTzoomHomeExtension(@"YTIRenderer", 325920579), @"msgClass");
        id divider = dividerClass != Nil ? YTzoomHomeWrap(@"YTIRenderer", 325920579, [dividerClass new]) : nil;
        if (divider != nil) [contents addObject:divider];
    }
    NSString *homeTitle = YTzoomHomeObject(YTzoomHomeObject(home, @"tabRenderer"), @"title");
    id all = YTzoomHomeChip(homeTitle.length != 0 ? homeTitle : @"All", 0, YTzoomHomeReloadCommand(homeReload), YES);
    if (all != nil) [contents addObject:all];
    for (id tab in tabs) {
        if (tab == home) continue;
        id renderer = YTzoomHomeObject(tab, @"tabRenderer");
        NSString *title = YTzoomHomeObject(renderer, @"title");
        if (title.length == 0 || YTzoomHomeBool(renderer, @"unselectable")) continue;
        id command = YTzoomHomeReloadCommand(YTzoomHomeReloadData(tab)) ?: YTzoomHomeObject(renderer, @"endpoint");
        id chip = YTzoomHomeChip(title, 0, command, NO);
        if (chip != nil) [contents addObject:chip];
    }
    YTzoomDownloadLog(@"home", @"redesign chips=%lu", (unsigned long)contents.count);
    if (contents.count < 2) return;
    YTzoomHomeSet(bar, @"setOnFiltersCleared:", YTzoomHomeReloadCommand(homeReload));
    id newHeader = header ?: YTzoomHomeNew(@"YTISectionListHeaderSupportedRenderers");
    YTzoomHomeSet(newHeader, @"setFeedFilterChipBarRenderer:", bar);
    YTzoomHomeSet(list, @"setHeader:", newHeader);
}

static void YTzoomTrimHomeTabsInRenderer(id single) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.HomeTabsHidden")) return;
    NSMutableArray *tabs = YTzoomHomeObject(single, @"tabsArray");
    if (![tabs isKindOfClass:NSMutableArray.class] || tabs.count < 2) return;
    id home = nil;
    BOOL subscriptions = NO;
    for (id tab in tabs) {
        NSString *browseID = YTzoomHomeTabBrowseID(tab);
        if (home == nil && [browseID isEqualToString:@"FEwhat_to_watch"]) home = tab;
        if ([browseID isEqualToString:@"FEsubscriptions"]) subscriptions = YES;
    }
    if (home == nil && subscriptions) home = tabs.firstObject;
    if (home == nil) return;
    YTzoomHomeBuildChips([tabs copy], home);
    [tabs setArray:@[home]];
    YTzoomHomeSetBool(single, @"setHideTabBar:", YES);
    YTzoomHomeSetBool(single, @"setDisableTabSwiping:", YES);
    YTzoomHomeSetBool(YTzoomHomeObject(home, @"tabRenderer"), @"setHasPresentationStyle:", NO);
}

static void YTzoomTrimHomeTabs(id response) {
    YTzoomTrimHomeTabsInRenderer(YTzoomHomeObject(YTzoomHomeObject(response, @"contents"),
                                                  @"singleColumnBrowseResultsRenderer"));
}

static IMP OriginalTabsLoadModel;
static IMP OriginalTabsLoadModelReload;
static IMP OriginalTabsUpdateModel;

static void YTzoomTabsLoadModel(id receiver, SEL selector, id model) {
    YTzoomTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id))OriginalTabsLoadModel)(receiver, selector, model);
}

static void YTzoomTabsLoadModelReload(id receiver, SEL selector, id model, BOOL reload) {
    YTzoomTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL))OriginalTabsLoadModelReload)(receiver, selector, model, reload);
}

static void YTzoomTabsUpdateModel(id receiver, SEL selector, id model, BOOL isDefault, BOOL reload) {
    YTzoomTrimHomeTabsInRenderer(model);
    ((void (*)(id, SEL, id, BOOL, BOOL))OriginalTabsUpdateModel)(receiver, selector, model, isDefault, reload);
}

static void YTzoomBrowseLoadResponse(id receiver, SEL selector, id response) {
    YTzoomTrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadResponse)(receiver, selector, response);
}

static void YTzoomBrowseLoadInitialResponse(id receiver, SEL selector, id response) {
    YTzoomTrimHomeTabs(response);
    ((void (*)(id, SEL, id))OriginalBrowseLoadInitialResponse)(receiver, selector, response);
}

__attribute__((constructor)) static void YTzoomInstallHomeTabs(void) {
    YTzoomInstallInstanceHook(@"YTBrowseViewController", @"loadWithResponse:",
                              (IMP)YTzoomBrowseLoadResponse, &OriginalBrowseLoadResponse);
    YTzoomInstallInstanceHook(@"YTBrowseViewController", @"loadWithInitialResponse:",
                              (IMP)YTzoomBrowseLoadInitialResponse, &OriginalBrowseLoadInitialResponse);
    YTzoomInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableScrollableTabsInFox",
                              (IMP)YTzoomFoxScrollableTabs, &OriginalFoxScrollableTabs);
    YTzoomInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientEnableCollapsingTabsAfterDwellInFox",
                              (IMP)YTzoomFoxCollapsingTabs, &OriginalFoxCollapsingTabs);
    YTzoomInstallInstanceHook(@"YTColdConfig", @"mainAppCoreClientIosEnableCollapsingTabsAfterDwellInFox",
                              (IMP)YTzoomFoxIosCollapsingTabs, &OriginalFoxIosCollapsingTabs);
    YTzoomInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:",
                              (IMP)YTzoomTabsLoadModel, &OriginalTabsLoadModel);
    YTzoomInstallInstanceHook(@"YTTabsViewController", @"loadWithModel:reloadContentViewControllers:",
                              (IMP)YTzoomTabsLoadModelReload, &OriginalTabsLoadModelReload);
    YTzoomInstallInstanceHook(@"YTTabsViewController", @"updateWithModel:isDefaultModel:reloadContentViewControllers:",
                              (IMP)YTzoomTabsUpdateModel, &OriginalTabsUpdateModel);
}
