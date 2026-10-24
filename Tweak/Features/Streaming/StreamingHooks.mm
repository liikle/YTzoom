#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <objc/message.h>
#import <objc/runtime.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <CoreGraphics/CoreGraphics.h>

static IMP OriginalLegacyQuality;
static IMP OriginalSetUserSelectableFormats;
static IMP OriginalDidLoadContentPlaybackData;
static IMP OriginalQualityHandleTap;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomStreamingOriginals;
static const void *YTzoomRedesignedQualityControllerKey =
    &YTzoomRedesignedQualityControllerKey;

static NSString *YTzoomStreamingKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTzoomStreamingOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP value = (IMP)[YTzoomStreamingOriginals[
            YTzoomStreamingKey(cls, selector)] pointerValue];
        if (value != NULL) {
            return value;
        }
    }
    return NULL;
}

static BOOL YTzoomLegacyQuality(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.LegacyQualityMenu")) {
        return NO;
    }
    return OriginalLegacyQuality != NULL
        ? ((BOOL (*)(id, SEL))OriginalLegacyQuality)(receiver, selector)
        : NO;
}

static id YTzoomValue(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return nil;
    }
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray<NSString *> *YTzoomQualityLabels(void) {
    return @[@"", @"2160p60", @"2160p", @"1440p60", @"1440p",
             @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
             @"360p", @"240p", @"144p"];
}

static NSInteger YTzoomQualityIndex(void) {
    SCNetworkReachabilityRef reachability =
        SCNetworkReachabilityCreateWithName(NULL, "youtube.com");
    SCNetworkReachabilityFlags flags = 0;
    BOOL hasFlags = reachability != NULL &&
        SCNetworkReachabilityGetFlags(reachability, &flags);
    if (reachability != NULL) {
        CFRelease(reachability);
    }
    BOOL onCellular = hasFlags &&
        (flags & kSCNetworkReachabilityFlagsIsWWAN) != 0;
    BOOL onWiFi = !onCellular;
    NSString *key = onWiFi ? @"YTzoom.Preference.Playback.WiFiQuality" : @"YTzoom.Preference.Playback.CellularQuality";
    id value = YTzoomPreferenceObject(key);
    NSInteger index = [value respondsToSelector:@selector(integerValue)]
        ? [value integerValue] : 0;
    return index >= 0 && index < (NSInteger)YTzoomQualityLabels().count ? index : 0;
}

static NSInteger YTzoomResolution(NSString *label) {
    NSScanner *scanner = [NSScanner scannerWithString:label ?: @""];
    NSInteger value = 0;
    return [scanner scanInteger:&value] ? value : 0;
}

static NSString *YTzoomTargetQualityLabel(NSArray *formats, NSString *target) {
    NSString *nearest = nil;
    NSInteger nearestDistance = NSIntegerMax;
    NSInteger targetResolution = YTzoomResolution(target);
    for (id format in formats) {
        id value = YTzoomValue(format, @"qualityLabel");
        if (![value isKindOfClass:NSString.class]) {
            continue;
        }
        NSString *label = value;
        if ([label isEqualToString:target]) {
            return label;
        }
        if ([label rangeOfString:@"Premium"
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }
        NSInteger resolution = YTzoomResolution(label);
        NSInteger distance = labs(resolution - targetResolution);
        if (resolution > 0 && distance < nearestDistance) {
            nearest = label;
            nearestDistance = distance;
        }
    }
    return nearest;
}

static void YTzoomApplyPreferredQuality(id controller) {
    NSInteger index = YTzoomQualityIndex();
    if (index == 0) {
        return;
    }
    id activeVideo = YTzoomValue(controller, @"activeVideo");
    id formats = YTzoomValue(activeVideo, @"selectableVideoFormats");
    if (![formats isKindOfClass:NSArray.class] || [formats count] == 0) {
        return;
    }
    NSString *label = YTzoomTargetQualityLabel(formats, YTzoomQualityLabels()[index]);
    Class constraintClass = NSClassFromString(
        @"MLQuickMenuVideoQualitySettingFormatConstraint");
    SEL initializer = NSSelectorFromString(
        @"initWithVideoQualitySetting:formatSelectionReason:qualityLabel:");
    SEL setter = NSSelectorFromString(@"setVideoFormatConstraint:");
    if (label.length == 0 || constraintClass == Nil ||
        ![activeVideo respondsToSelector:setter]) {
        return;
    }
    id allocated = [constraintClass alloc];
    if (![allocated respondsToSelector:initializer]) {
        return;
    }
    id constraint = ((id (*)(id, SEL, NSInteger, NSInteger, id))objc_msgSend)(
        allocated, initializer, 3, 2, label);
    if (constraint != nil) {
        ((void (*)(id, SEL, id))objc_msgSend)(activeVideo, setter, constraint);
    }
}

BOOL YTzoomPlayerIsShorts(id player) {
    SEL parentSelector = NSSelectorFromString(@"parentViewController");
    id current = player;
    for (NSUInteger depth = 0; current != nil && depth < 6; depth++) {
        NSString *name = NSStringFromClass(object_getClass(current));
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"]) {
            return YES;
        }
        if (![current respondsToSelector:parentSelector]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSelector);
    }
    return NO;
}

static void YTzoomDidLoadContentPlaybackData(id receiver,
                                              SEL selector,
                                              id playbackController,
                                              id playbackData) {
    if (OriginalDidLoadContentPlaybackData != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidLoadContentPlaybackData)(
            receiver, selector, playbackController, playbackData);
    }
    if (playbackController == nil || playbackData == nil ||
        YTzoomQualityIndex() == 0) {
        return;
    }
    if (YTzoomPlayerIsShorts(receiver)) {
        return;
    }
    __weak id weakReceiver = receiver;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                   dispatch_get_main_queue(), ^{
        YTzoomApplyPreferredQuality(weakReceiver);
    });
}




static IMP OriginalAVEligibleForHDR;
static IMP OriginalAVAvailableHDRModes;

static BOOL YTzoomCallerIsYouTube(const void *address) {
    static const void *mainBase;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        for (uint32_t index = 0; index < _dyld_image_count(); index++) {
            const struct mach_header *header = _dyld_get_image_header(index);
            if (header != NULL && header->filetype == MH_EXECUTE) {
                mainBase = header;
                break;
            }
        }
    });
    Dl_info info;
    return address != NULL && mainBase != NULL &&
        dladdr(address, &info) != 0 && info.dli_fbase == mainBase;
}

static BOOL YTzoomHDRSuppressed(const void *caller) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.HDRDisabled") &&
        YTzoomCallerIsYouTube(caller);
}

static BOOL YTzoomAVEligibleForHDR(id receiver, SEL selector) {
    if (YTzoomHDRSuppressed(__builtin_return_address(0))) return NO;
    return OriginalAVEligibleForHDR != NULL
        ? ((BOOL (*)(id, SEL))OriginalAVEligibleForHDR)(receiver, selector) : NO;
}

static NSInteger YTzoomAVAvailableHDRModes(id receiver, SEL selector) {
    if (YTzoomHDRSuppressed(__builtin_return_address(0))) return 0;
    return OriginalAVAvailableHDRModes != NULL
        ? ((NSInteger (*)(id, SEL))OriginalAVAvailableHDRModes)(receiver, selector) : 0;
}


static NSArray *YTzoomFormatsWithoutPremium(NSArray *formats) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.PremiumQualityHidden") ||
        ![formats isKindOfClass:NSArray.class]) {
        return formats;
    }
    NSMutableArray *kept = [NSMutableArray array];
    for (id format in formats) {
        id label = YTzoomValue(format, @"qualityLabel");
        if ([label isKindOfClass:NSString.class] &&
            [label rangeOfString:@"Premium"
                         options:NSCaseInsensitiveSearch].location != NSNotFound) {
            continue;
        }
        [kept addObject:format];
    }
    return kept.count != 0 ? kept : formats;
}

static IMP OriginalRedesignedSetFormats;

static void YTzoomRedesignedSetFormats(id receiver, SEL selector, NSArray *formats) {
    NSArray *selected = YTzoomFormatsWithoutPremium(formats);
    if (OriginalRedesignedSetFormats != NULL) {
        ((void (*)(id, SEL, id))OriginalRedesignedSetFormats)(receiver, selector,
                                                              selected);
    }
}

static void YTzoomSetUserSelectableFormats(id receiver,
                                            SEL selector,
                                            NSArray *formats) {
    NSArray *selectedFormats = formats;
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.LegacyQualityMenu")) {
        id redesigned = objc_getAssociatedObject(
            receiver, YTzoomRedesignedQualityControllerKey);
        if (redesigned == nil) {
            Class controllerClass = NSClassFromString(
                @"YTVideoQualitySwitchRedesignedController");
            SEL initializer = NSSelectorFromString(
                @"initWithServiceRegistryScope:parentResponder:");
            id allocated = [controllerClass alloc];
            if ([allocated respondsToSelector:initializer]) {
                redesigned = ((id (*)(id, SEL, id, id))objc_msgSend)(
                    allocated, initializer, nil, nil);
                objc_setAssociatedObject(receiver,
                    YTzoomRedesignedQualityControllerKey,
                    redesigned,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
        id video = YTzoomValue(receiver, @"_video");
        if (redesigned != nil && video != nil) {
            @try {
                [redesigned setValue:video forKey:@"_video"];
            } @catch (__unused NSException *exception) {
            }
        }
        SEL restrictSelector = NSSelectorFromString(@"addRestrictedFormats:");
        if ([redesigned respondsToSelector:restrictSelector]) {
            id restricted = ((id (*)(id, SEL, id))objc_msgSend)(
                redesigned, restrictSelector, formats);
            if ([restricted isKindOfClass:NSArray.class]) {
                selectedFormats = restricted;
            }
        }
    }
    selectedFormats = YTzoomFormatsWithoutPremium(selectedFormats);
    if (OriginalSetUserSelectableFormats != NULL) {
        ((void (*)(id, SEL, id))OriginalSetUserSelectableFormats)(
            receiver, selector, selectedFormats);
    }
}

static void YTzoomQualityHandleTap(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.LegacyQualityMenu")) {
        id controller = YTzoomValue(receiver, @"_controller");
        id node = YTzoomValue(controller, @"node");
        SEL identifierSelector = NSSelectorFromString(@"accessibilityIdentifier");
        SEL labelSelector = NSSelectorFromString(@"accessibilityLabel");
        NSString *identifier = [node respondsToSelector:identifierSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, identifierSelector) : nil;
        NSString *label = [node respondsToSelector:labelSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, labelSelector) : nil;
        NSRegularExpression *quality = [NSRegularExpression
            regularExpressionWithPattern:@"\\d+p" options:0 error:nil];
        BOOL qualityRow = [identifier hasPrefix:
            @"id.elements.components.overflow_menu_item_"] &&
            [label isKindOfClass:NSString.class] &&
            [quality firstMatchInString:label options:0
                range:NSMakeRange(0, label.length)] != nil;
        SEL closestSelector = NSSelectorFromString(@"closestViewController");
        id sheet = qualityRow && [node respondsToSelector:closestSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(node, closestSelector) : nil;
        Class sheetClass = NSClassFromString(@"YTActionSheetDialogViewController");
        Class bottomSheetClass = NSClassFromString(@"YTBottomSheetController");
        SEL parentSelector = NSSelectorFromString(@"parentViewController");
        id parent = [sheet respondsToSelector:parentSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(sheet, parentSelector) : nil;
        if (sheetClass != Nil && bottomSheetClass != Nil &&
            [sheet isKindOfClass:sheetClass] && [parent isKindOfClass:bottomSheetClass]) {
            id delegate = YTzoomValue(sheet, @"delegate");
            id overlay = YTzoomValue(delegate, @"parentResponder");
            Class overlayClass = NSClassFromString(
                @"YTMainAppVideoPlayerOverlayViewController");
            SEL qualitySelector = NSSelectorFromString(@"didPressVideoQuality:");
            if (overlayClass != Nil && [overlay isKindOfClass:overlayClass] &&
                [overlay respondsToSelector:qualitySelector]) {
                __weak id weakOverlay = overlay;
                SEL dismissSelector = NSSelectorFromString(
                    @"dismissViewControllerAnimated:completion:");
                void (^completion)(void) = ^{
                    id strongOverlay = weakOverlay;
                    if ([strongOverlay respondsToSelector:qualitySelector]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(
                            strongOverlay, qualitySelector, nil);
                    }
                };
                ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
                    overlay, dismissSelector, YES, completion);
                return;
            }
        }
    }
    if (OriginalQualityHandleTap != NULL) {
        ((void (*)(id, SEL))OriginalQualityHandleTap)(receiver, selector);
    }
}

static BOOL YTzoomAutoplayIsQueueConfig(id receiver) {
    NSString *name = NSStringFromClass(object_getClass(receiver));
    return [name containsString:@"QueueConfig"] ||
        [name containsString:@"GaplessPlaybackCoordinator"];
}

static BOOL YTzoomAutoplayValue(id receiver, SEL selector) {
    const BOOL disabled =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.AutoplayDisabled");
    BOOL result;
    if (disabled) {
        result = NO;
    } else if (YTzoomQueueHasItems() && YTzoomQueueOwnsCurrentVideo() &&
               !YTzoomAutoplayIsQueueConfig(receiver)) {
        result = NO;
    } else {
        IMP original = YTzoomStreamingOriginal(receiver, selector);
        result = original != NULL
            ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
    }

    return result;
}

static void YTzoomAutoplaySetter(id receiver, SEL selector, BOOL enabled) {
    IMP original = YTzoomStreamingOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, BOOL))original)(
            receiver,
            selector,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.AutoplayDisabled") ? NO : enabled
        );
    }
}

static BOOL YTzoomCellularQualityValue(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.HDOnCellular")) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        BOOL limiter = [name containsString:@"limit"] ||
            [name containsString:@"restrict"] ||
            [name containsString:@"datasaver"] ||
            [name containsString:@"data_saver"];
        return !limiter;
    }
    IMP original = YTzoomStreamingOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static void YTzoomStoreStreamingOriginal(NSString *className,
                                         NSString *selectorName,
                                         IMP original) {
    if (original == NULL) {
        return;
    }
    Class cls = NSClassFromString(className);
    if (cls != Nil) {
        YTzoomStreamingOriginals[YTzoomStreamingKey(cls,
            NSSelectorFromString(selectorName))] =
            [NSValue valueWithPointer:(const void *)original];
    }
}

static BOOL YTzoomInstallBoolGetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return NO;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return NO;
    }
    IMP original = NULL;
    if (!YTzoomInstallInstanceHook(className, selectorName, replacement, &original)) {
        return NO;
    }
    YTzoomStoreStreamingOriginal(className, selectorName, original);
    return YES;
}

static BOOL YTzoomInstallBoolSetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return NO;
    }
    IMP original = NULL;
    if (!YTzoomInstallInstanceHook(className, selectorName, replacement, &original)) {
        return NO;
    }
    YTzoomStoreStreamingOriginal(className, selectorName, original);
    return YES;
}

void YTzoomInstallStreamingHooks(void) {
    if (YTzoomStreamingOriginals == nil) {
        YTzoomStreamingOriginals = [NSMutableDictionary dictionary];
    }
    YTzoomInstallClassHook(@"AVPlayer", @"eligibleForHDRPlayback",
                           (IMP)YTzoomAVEligibleForHDR, &OriginalAVEligibleForHDR);
    YTzoomInstallClassHook(@"AVPlayer", @"availableHDRModes",
                           (IMP)YTzoomAVAvailableHDRModes, &OriginalAVAvailableHDRModes);
    YTzoomInstallInstanceHook(
        @"YTVideoQualitySwitchRedesignedController", @"setUserSelectableFormats:",
        (IMP)YTzoomRedesignedSetFormats, &OriginalRedesignedSetFormats);

    Class qualityClass = NSClassFromString(@"YTIMediaQualitySettingsHotConfig");
    Method qualityMethod = qualityClass == Nil ? NULL : class_getInstanceMethod(
        qualityClass,
        NSSelectorFromString(@"enableQuickMenuVideoQualitySettings")
    );
    if (qualityMethod != NULL) {
        YTzoomInstallInstanceHook(@"YTIMediaQualitySettingsHotConfig",
                                  @"enableQuickMenuVideoQualitySettings",
                                  (IMP)YTzoomLegacyQuality,
                                  &OriginalLegacyQuality);
    } else {
        YTzoomAddInstanceMethod(@"YTIMediaQualitySettingsHotConfig",
                                @"enableQuickMenuVideoQualitySettings",
                                (IMP)YTzoomLegacyQuality,
                                "B@:");
    }

    YTzoomInstallInstanceHook(@"YTVideoQualitySwitchOriginalController",
                              @"setUserSelectableFormats:",
                              (IMP)YTzoomSetUserSelectableFormats,
                              &OriginalSetUserSelectableFormats);
    YTzoomInstallInstanceHook(@"YTPlayerViewController",
                              @"playbackController:didLoadContentPlaybackData:",
                              (IMP)YTzoomDidLoadContentPlaybackData,
                              &OriginalDidLoadContentPlaybackData);
    YTzoomInstallInstanceHook(@"ELMTouchCommandPropertiesHandler",
                              @"handleTap",
                              (IMP)YTzoomQualityHandleTap,
                              &OriginalQualityHandleTap);

    NSArray<NSString *> *autoplayClasses = @[
        @"YTDefaultQueueConfig",
        @"YTGaplessPlaybackCoordinator",
        @"YTAdsControlFlowPlaybackCoordinator",
        @"YTSettings",
        @"YTSettingsImpl",
        @"YTUserDefaults",
        @"YTAutonavEndscreenController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTOverflowMenuView",
        @"YTOverflowMenuViewController",
        @"YTWatchFloatingMiniplayerViewController",
        @"YTWatchMiniBarViewController",
        @"YTAutoplayAutonavWatchFeedLayoutController",
        @"YTAutoplayAutonavController",
        @"YTAutonavController",
        @"YTLocalPlaybackController",
        @"YTPlayerViewController"
    ];
    NSArray<NSString *> *autoplayGetters = @[
        @"isAutonavEnabled",
        @"autonavEnabled",
        @"isAutoplayEnabled",
        @"autoplayEnabled",
        @"isAutoplayEnabledForContent",
        @"shouldAutoplay",
        @"shouldStartAutoplay"
    ];
    NSArray<NSString *> *autoplaySetters = @[
        @"setAutonavEnabled:",
        @"setAutoplayEnabled:",
        @"setIsAutoplayEnabled:"
    ];
    NSUInteger autoplayBound = 0;
    for (NSString *className in autoplayClasses) {
        if (NSClassFromString(className) == Nil) continue;
        for (NSString *selectorName in autoplayGetters) {
            if (YTzoomInstallBoolGetter(className, selectorName,
                                        (IMP)YTzoomAutoplayValue)) {
                autoplayBound++;
            }
        }
        for (NSString *selectorName in autoplaySetters) {
            if (YTzoomInstallBoolSetter(className, selectorName,
                                        (IMP)YTzoomAutoplaySetter)) {
                autoplayBound++;
            }
        }
    }
    YTzoomDownloadLog(@"autoplay", @"bound %lu hooks",
                      (unsigned long)autoplayBound);

    NSArray<NSString *> *qualityClasses = @[
        @"YTUserDefaults",
        @"YTPlaybackConfig",
        @"YTIPlayerConfig",
        @"YTIMediaQualitySettingsHotConfig"
    ];
    NSArray<NSString *> *qualitySelectors = @[
        @"isHDOnCellularEnabled",
        @"allowHDOnCellular",
        @"allowsHDOnCellular",
        @"isHighDefinitionOnCellularEnabled",
        @"shouldLimitVideoQualityOnCellular",
        @"isDataSaverEnabled"
    ];
    for (NSString *className in qualityClasses) {
        for (NSString *selectorName in qualitySelectors) {
            YTzoomInstallBoolGetter(className,
                                    selectorName,
                                    (IMP)YTzoomCellularQualityValue);
        }
    }
}
