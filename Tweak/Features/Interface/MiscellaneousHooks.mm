#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

static IMP OriginalAddInteraction;
static IMP OriginalSemanticContent;
static IMP OriginalSetSemanticContent;
static IMP OriginalCaptionTracks;
static IMP OriginalCaptionControllerAlloc;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomMiscOriginals;
static const void *YTzoomCaptionTracksAssociation =
    &YTzoomCaptionTracksAssociation;
static const void *YTzoomLastCaptionTrackAssociation =
    &YTzoomLastCaptionTrackAssociation;
static const void *YTzoomAppliedCaptionAssociation =
    &YTzoomAppliedCaptionAssociation;
static NSHashTable *YTzoomCaptionControllers;

static NSString *YTzoomCaptionTrackKey(id track) {
    if (track == nil) {
        return nil;
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *key in @[@"languageCode", @"displayName", @"vssId",
                             @"kind"]) {
        @try {
            id value = [track valueForKey:key];
            if (value != nil) {
                [parts addObject:[value description]];
            }
        } @catch (__unused NSException *exception) {
        }
    }
    return parts.count != 0 ? [parts componentsJoinedByString:@"|"] :
        [NSString stringWithFormat:@"%p", (__bridge void *)track];
}

static BOOL YTzoomCaptionRequestReceiver(id receiver, SEL selector) {
    NSString *className = NSStringFromClass([receiver class]).lowercaseString;
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    return [className containsString:@"request"] ||
        [className containsString:@"params"] ||
        [className containsString:@"config"] ||
        [name containsString:@"requested"] ||
        [name containsString:@"devicecaptions"] ||
        [name containsString:@"persistence"] ||
        [name containsString:@"respectdevice"] ||
        [name containsString:@"hiddenonstart"];
}

static NSString *YTzoomMiscKey(Class cls, SEL selector) {
    return [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls),
                                      NSStringFromSelector(selector)];
}

static IMP YTzoomMiscOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        IMP original = (IMP)[YTzoomMiscOriginals[
            YTzoomMiscKey(cls, selector)] pointerValue];
        if (original != NULL) {
            return original;
        }
    }
    return NULL;
}

static BOOL YTzoomMiniPlayerEnabled(void) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.KidsMiniPlayer");
}

static NSString *const YTzoomLayoutIdiomKey = @"YTzoom.Preference.App.LayoutIdiom";

static BOOL YTzoomIdiomForced;
static UIUserInterfaceIdiom YTzoomForcedIdiom;
static UIUserInterfaceIdiom YTzoomRealIdiom;
static IMP OriginalDeviceIdiom;

typedef struct {
    uintptr_t start;
    uintptr_t end;
} YTzoomTextRange;

static YTzoomTextRange YTzoomIdiomRanges[2];
static NSUInteger YTzoomIdiomRangeCount;

static void YTzoomAddTextRange(const struct mach_header *header) {
    if (header == NULL || YTzoomIdiomRangeCount >= 2) return;
    unsigned long size = 0;
    const uint8_t *text = getsectiondata(
        (const struct mach_header_64 *)header, "__TEXT", "__text", &size);
    if (text == NULL || size == 0) return;
    YTzoomIdiomRanges[YTzoomIdiomRangeCount].start = (uintptr_t)text;
    YTzoomIdiomRanges[YTzoomIdiomRangeCount].end = (uintptr_t)text + size;
    YTzoomIdiomRangeCount++;
}

static void YTzoomComputeIdiomRanges(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header == NULL) continue;
        if (header->filetype != MH_EXECUTE) continue;
        YTzoomAddTextRange(header);
        break;
    }
    Dl_info info;
    if (dladdr((const void *)&YTzoomComputeIdiomRanges, &info) != 0) {
        YTzoomAddTextRange((const struct mach_header *)info.dli_fbase);
    }
}

static inline BOOL YTzoomCallerIsApp(uintptr_t caller) {
    for (NSUInteger index = 0; index < YTzoomIdiomRangeCount; index++) {
        if (caller >= YTzoomIdiomRanges[index].start &&
            caller < YTzoomIdiomRanges[index].end) {
            return YES;
        }
    }
    return NO;
}

NSInteger YTzoomRealUserInterfaceIdiom(void) {
    if (YTzoomIdiomForced) {
        return (NSInteger)YTzoomRealIdiom;
    }
    return (NSInteger)UIDevice.currentDevice.userInterfaceIdiom;
}

static UIUserInterfaceIdiom YTzoomUserInterfaceIdiom(id receiver, SEL selector) {
    if (YTzoomIdiomForced &&
        YTzoomCallerIsApp((uintptr_t)__builtin_return_address(0))) {
        return YTzoomForcedIdiom;
    }
    return OriginalDeviceIdiom != NULL
        ? ((UIUserInterfaceIdiom (*)(id, SEL))OriginalDeviceIdiom)(receiver,
                                                                   selector)
        : YTzoomRealIdiom;
}

static void YTzoomResolveForcedIdiom(void) {
    UIUserInterfaceIdiom actual = UIDevice.currentDevice.userInterfaceIdiom;
    id stored = YTzoomPreferenceObject(YTzoomLayoutIdiomKey);
    NSInteger choice = [stored respondsToSelector:@selector(integerValue)]
        ? [stored integerValue] : 0;
    if (choice == 0 &&
        YTzoomFeatureEnabled(@"YTzoom.Preference.App.iPadLayout")) {
        choice = 2;
    }
    UIUserInterfaceIdiom desired;
    if (choice == 1) {
        desired = UIUserInterfaceIdiomPhone;
    } else if (choice == 2) {
        desired = UIUserInterfaceIdiomPad;
    } else {
        return;
    }
    if (desired == actual) return;
    YTzoomRealIdiom = actual;
    YTzoomForcedIdiom = desired;
    YTzoomIdiomForced = YES;
}

static BOOL YTzoomForcedIsIPad(__unused id receiver, __unused SEL selector) {
    return YTzoomForcedIdiom == UIUserInterfaceIdiomPad;
}

static void YTzoomAddInteraction(UIView *receiver, SEL selector, id interaction) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.App.DragDropDisabled") &&
        ([interaction isKindOfClass:UIDragInteraction.class] ||
         [interaction isKindOfClass:UIDropInteraction.class])) {
        return;
    }
    if (OriginalAddInteraction != NULL) {
        ((void (*)(id, SEL, id))OriginalAddInteraction)(receiver, selector, interaction);
    }
}

static UISemanticContentAttribute YTzoomSemanticContent(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.App.RTLDisabled")) {
        return UISemanticContentAttributeForceLeftToRight;
    }
    return OriginalSemanticContent != NULL
        ? ((UISemanticContentAttribute (*)(id, SEL))OriginalSemanticContent)(receiver, selector)
        : UISemanticContentAttributeUnspecified;
}

static void YTzoomSetSemanticContent(id receiver,
                                     SEL selector,
                                     UISemanticContentAttribute value) {
    if (OriginalSetSemanticContent != NULL) {
        ((void (*)(id, SEL, UISemanticContentAttribute))OriginalSetSemanticContent)(
            receiver,
            selector,
            YTzoomFeatureEnabled(@"YTzoom.Preference.App.RTLDisabled")
                ? UISemanticContentAttributeForceLeftToRight
                : value
        );
    }
}

static BOOL YTzoomMiniPlayerValue(id receiver, SEL selector) {
    if (YTzoomMiniPlayerEnabled()) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return !([name containsString:@"disable"] ||
                 [name containsString:@"unavailable"] ||
                 [name containsString:@"blocked"] ||
                 [name containsString:@"prevent"] ||
                 [name containsString:@"hide"] ||
                 [name containsString:@"onlywhenplaying"]);
    }
    IMP original = YTzoomMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL YTzoomMiniPlayerPauseOnlyValue(id receiver, SEL selector) {
    if (YTzoomMiniPlayerEnabled()) {
        return NO;
    }
    IMP original = YTzoomMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static BOOL YTzoomAgeValue(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Content.AgeGateBypass")) {
        NSString *name = NSStringFromSelector(selector).lowercaseString;
        return [name containsString:@"verified"] ||
            [name containsString:@"allowed"];
    }
    IMP original = YTzoomMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static NSInteger YTzoomCaptionsMode(void) {
    if (!YTzoomMasterEnabled()) return 0;
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTzoom.Preference.Playback.CaptionsMode"];
    if ([stored respondsToSelector:@selector(integerValue)]) return MAX(0, MIN(2, [stored integerValue]));
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CaptionsDisabled")) return 2;
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CaptionsAlwaysOn")) return 1;
    return 0;
}

static BOOL YTzoomCaptionValue(id receiver, SEL selector) {
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    if ((YTzoomCaptionsMode() == 2)) {
        return negative;
    }
    if ((YTzoomCaptionsMode() == 1)) {
        if (!YTzoomCaptionRequestReceiver(receiver, selector)) {
            IMP original = YTzoomMiscOriginal(receiver, selector);
            return original != NULL
                ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
        }
        if ([name containsString:@"respectdevicecaption"] ||
            [name containsString:@"hiddenonstart"]) {
            return NO;
        }
        return !negative;
    }
    IMP original = YTzoomMiscOriginal(receiver, selector);
    return original != NULL ? ((BOOL (*)(id, SEL))original)(receiver, selector) : NO;
}

static void YTzoomCaptionSetter(id receiver, SEL selector, BOOL enabled) {
    IMP original = YTzoomMiscOriginal(receiver, selector);
    if (original == NULL) {
        return;
    }
    NSString *name = NSStringFromSelector(selector).lowercaseString;
    BOOL negative = [name containsString:@"disabled"] ||
        [name containsString:@"hidden"];
    BOOL value = enabled;
    if ((YTzoomCaptionsMode() == 2)) {
        value = negative;
    } else if ((YTzoomCaptionsMode() == 1) &&
               YTzoomCaptionRequestReceiver(receiver, selector)) {
        value = !negative;
    }
    ((void (*)(id, SEL, BOOL))original)(receiver, selector, value);
}

static id YTzoomFirstCaptionTrack(id tracks) {
    if ([tracks isKindOfClass:NSArray.class]) {
        return [tracks firstObject];
    }
    if ([tracks respondsToSelector:@selector(allObjects)]) {
        id objects = ((id (*)(id, SEL))objc_msgSend)(tracks,
                                                     @selector(allObjects));
        return [objects isKindOfClass:NSArray.class] ? [objects firstObject] : nil;
    }
    return nil;
}

static NSString *YTzoomTrackText(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTzoomBestCaptionTrackForLanguage(NSArray *tracks, NSString *language) {
    if (language.length == 0) return nil;
    NSString *base = [[language.lowercaseString componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
    id best = nil;
    NSInteger bestRank = NSIntegerMax;
    for (id track in tracks) {
        NSString *code = YTzoomTrackText(track, @"languageCode").lowercaseString;
        if (code.length == 0) continue;
        NSString *codeBase = [[code componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"-_"]] firstObject];
        if (![code isEqualToString:language.lowercaseString] && ![codeBase isEqualToString:base]) continue;
        NSString *vss = YTzoomTrackText(track, @"VSSID") ?: @"";
        NSInteger rank = [vss hasPrefix:@"."] ? 0 : ([vss hasPrefix:@"a."] ? 1 : 2);
        if (rank < bestRank) {
            bestRank = rank;
            best = track;
        }
    }
    return best;
}

static id YTzoomPreferredCaptionTrack(id tracks) {
    id first = YTzoomFirstCaptionTrack(tracks);
    if (first == nil) return nil;
    NSArray *list = [tracks isKindOfClass:NSArray.class] ? tracks
        : ([tracks respondsToSelector:@selector(allObjects)]
            ? ((id (*)(id, SEL))objc_msgSend)(tracks, @selector(allObjects)) : nil);
    if (![list isKindOfClass:NSArray.class]) return first;
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:@"YTzoom.Preference.Playback.CaptionLanguage"];
    id match = YTzoomBestCaptionTrackForLanguage(list, preferred);
    for (NSString *language in NSLocale.preferredLanguages) {
        if (match != nil) break;
        match = YTzoomBestCaptionTrackForLanguage(list, language);
    }
    if (match != nil) return match;
    for (id track in list) {
        if (![[YTzoomTrackText(track, @"VSSID") ?: @"" lowercaseString] hasPrefix:@"t"]) return track;
    }
    return first;
}

static void YTzoomScheduleCaptionSelection(id track) {
    if (track == nil || !(YTzoomCaptionsMode() == 1)) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                  (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *key = YTzoomCaptionTrackKey(track);
        NSArray *controllers = nil;
        @synchronized (YTzoomCaptionControllers) {
            controllers = YTzoomCaptionControllers.allObjects;
        }
        for (id controller in controllers) {
            NSString *applied = objc_getAssociatedObject(
                controller, YTzoomAppliedCaptionAssociation);
            if ([applied isEqualToString:key]) {
                continue;
            }
            SEL selector = NSSelectorFromString(
                @"setSelectedCaptionTrack:selectionReason:");
            if (![controller respondsToSelector:selector]) {
                continue;
            }
            objc_setAssociatedObject(controller,
                YTzoomAppliedCaptionAssociation, key,
                OBJC_ASSOCIATION_COPY_NONATOMIC);
            ((void (*)(id, SEL, id, NSInteger))objc_msgSend)(
                controller, selector, track, 1);
        }
    });
}

static id YTzoomCaptionControllerAlloc(id receiver, SEL selector, NSZone *zone) {
    id result = OriginalCaptionControllerAlloc != NULL
        ? ((id (*)(id, SEL, NSZone *))OriginalCaptionControllerAlloc)(
            receiver, selector, zone) : nil;
    if (result != nil) {
        @synchronized (YTzoomCaptionControllers) {
            [YTzoomCaptionControllers addObject:result];
        }
    }
    return result;
}

static id YTzoomCaptionControllerInit(id receiver, SEL selector) {
    IMP original = YTzoomMiscOriginal(receiver, selector);
    id result = original != NULL
        ? ((id (*)(id, SEL))original)(receiver, selector) : receiver;
    if (result != nil) {
        @synchronized (YTzoomCaptionControllers) {
            [YTzoomCaptionControllers addObject:result];
        }
    }
    return result;
}

static void YTzoomCaptionTracksSetter(id receiver, SEL selector, id tracks) {
    IMP original = YTzoomMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, tracks);
    }
    id track = YTzoomPreferredCaptionTrack(tracks);
    id previousTrack = objc_getAssociatedObject(
        receiver, YTzoomLastCaptionTrackAssociation);
    if (previousTrack != track) {
        objc_setAssociatedObject(receiver, YTzoomLastCaptionTrackAssociation,
                                 track, OBJC_ASSOCIATION_ASSIGN);
        YTzoomScheduleCaptionSelection(track);
    }
    if (track == nil) {
        return;
    }
    objc_setAssociatedObject(receiver,
                             YTzoomCaptionTracksAssociation,
                             tracks,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomCaptionTrackSetter(id receiver, SEL selector, id track) {
    IMP original = YTzoomMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, track);
    }
}

static void YTzoomCaptionSelectedTrackSetter(id receiver,
                                             SEL selector,
                                             id track,
                                             NSInteger reason) {
    IMP original = YTzoomMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id, NSInteger))original)(receiver,
                                                      selector,
                                                      track,
                                                      reason);
    }
}

static id YTzoomCaptionTracks(id receiver, SEL selector) {
    if ((YTzoomCaptionsMode() == 2)) {
        return @[];
    }
    id tracks = OriginalCaptionTracks != NULL
        ? ((id (*)(id, SEL))OriginalCaptionTracks)(receiver, selector)
        : nil;
    return tracks;
}

static void YTzoomHUDMessage(id receiver, SEL selector, id message) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.App.HUDAlertsHidden")) {
        return;
    }
    NSString *text = nil;
    if ([message isKindOfClass:NSString.class]) {
        text = message;
    } else if ([message isKindOfClass:NSAttributedString.class]) {
        text = [(NSAttributedString *)message string];
    } else {
        for (NSString *name in @[@"text", @"message", @"title"]) {
            SEL valueSelector = NSSelectorFromString(name);
            if (![message respondsToSelector:valueSelector]) {
                continue;
            }
            id value = ((id (*)(id, SEL))objc_msgSend)(message,
                                                       valueSelector);
            if ([value isKindOfClass:NSString.class]) {
                text = value;
                break;
            }
            if ([value isKindOfClass:NSAttributedString.class]) {
                text = [(NSAttributedString *)value string];
                break;
            }
        }
    }
    NSString *lower = text.lowercaseString;
    if (YTzoomMiniPlayerEnabled() &&
        [lower containsString:@"miniplayer"] &&
        [lower containsString:@"kids"]) {
        return;
    }
    IMP original = YTzoomMiscOriginal(receiver, selector);
    if (original != NULL) {
        ((void (*)(id, SEL, id))original)(receiver, selector, message);
    }
}

static void YTzoomStoreMiscOriginal(NSString *className,
                                    NSString *selectorName,
                                    IMP original) {
    Class cls = NSClassFromString(className);
    if (cls != Nil && original != NULL) {
        YTzoomMiscOriginals[YTzoomMiscKey(
            cls,
            NSSelectorFromString(selectorName)
        )] = [NSValue valueWithPointer:(const void *)original];
    }
}

static void YTzoomInstallMiscBool(NSString *className,
                                  NSString *selectorName,
                                  IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 2) {
        return;
    }
    char type[8] = {0};
    method_getReturnType(method, type, sizeof(type));
    if (type[0] != 'B' && type[0] != 'c') {
        return;
    }
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className, selectorName, replacement, &original)) {
        YTzoomStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTzoomInstallMiscSetter(NSString *className,
                                    NSString *selectorName,
                                    IMP replacement) {
    Class cls = NSClassFromString(className);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className, selectorName, replacement, &original)) {
        YTzoomStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTzoomInstallMiscObjectSetter(NSString *className,
                                          NSString *selectorName,
                                          IMP replacement) {
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 3) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className, selectorName,
                                  replacement, &original)) {
        YTzoomStoreMiscOriginal(className, selectorName, original);
    }
}

static void YTzoomInstallCaptionSelectedSetter(NSString *className) {
    NSString *selectorName = @"setSelectedCaptionTrack:selectionReason:";
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(selectorName);
    Method method = cls == Nil ? NULL : class_getInstanceMethod(cls, selector);
    if (method == NULL || method_getNumberOfArguments(method) != 4) {
        return;
    }
    char type[8] = {0};
    method_getArgumentType(method, 2, type, sizeof(type));
    if (type[0] != '@') {
        return;
    }
    IMP original = NULL;
    if (YTzoomInstallInstanceHook(className, selectorName,
                                  (IMP)YTzoomCaptionSelectedTrackSetter,
                                  &original)) {
        YTzoomStoreMiscOriginal(className, selectorName, original);
    }
}

static BOOL YTzoomClassNameMatches(NSString *className,
                                   NSArray<NSString *> *tokens) {
    NSString *lower = className.lowercaseString;
    for (NSString *token in tokens) {
        if ([lower containsString:token]) {
            return YES;
        }
    }
    return NO;
}

static NSString *YTzoomMiscDiscoveryCacheKey(void) {
    NSString *version = NSBundle.mainBundle
        .infoDictionary[@"CFBundleShortVersionString"] ?: @"unknown";
    return [@"YTzoomMiscHookTargets." stringByAppendingString:version];
}

static void YTzoomApplyMiscDiscoveryTarget(NSString *target) {
    NSArray<NSString *> *parts = [target componentsSeparatedByString:@"|"];
    if (parts.count != 3) return;
    NSString *kind = parts[0];
    NSString *className = parts[1];
    NSString *selectorName = parts[2];
    if ([kind isEqualToString:@"mini"]) {
        YTzoomInstallMiscBool(className, selectorName,
                              (IMP)YTzoomMiniPlayerValue);
    } else if ([kind isEqualToString:@"miniPause"]) {
        YTzoomInstallMiscBool(className, selectorName,
                              (IMP)YTzoomMiniPlayerPauseOnlyValue);
    } else if ([kind isEqualToString:@"captionBool"]) {
        YTzoomInstallMiscBool(className, selectorName,
                              (IMP)YTzoomCaptionValue);
    } else if ([kind isEqualToString:@"captionSetter"]) {
        YTzoomInstallMiscSetter(className, selectorName,
                                (IMP)YTzoomCaptionSetter);
    } else if ([kind isEqualToString:@"captionTracks"]) {
        YTzoomInstallMiscObjectSetter(className, selectorName,
                                      (IMP)YTzoomCaptionTracksSetter);
    } else if ([kind isEqualToString:@"captionTrack"]) {
        YTzoomInstallMiscObjectSetter(className, selectorName,
                                      (IMP)YTzoomCaptionTrackSetter);
    } else if ([kind isEqualToString:@"captionSelected"]) {
        YTzoomInstallCaptionSelectedSetter(className);
    }
}

static void YTzoomApplyCachedMiscDiscovery(void) {
    NSArray<NSString *> *targets = [NSUserDefaults.standardUserDefaults
        arrayForKey:YTzoomMiscDiscoveryCacheKey()];
    for (NSString *target in targets) {
        YTzoomApplyMiscDiscoveryTarget(target);
    }
}

static void YTzoomDiscoverMiscHooks(void) {
    NSSet<NSString *> *miniSelectors = [NSSet setWithArray:@[
        @"isPlayableInMiniPlayer", @"isPlayableInMiniplayer",
        @"miniplayerEnabled", @"isMiniplayerDisabled",
        @"miniPlayerDisabled", @"isMiniplayerUnavailable",
        @"enableIosFloatingMiniplayer", @"enableMiniPlayerOnlyWhenPlaying",
        @"disableMiniPlayerWhenPaused", @"disableIphoneMiniplayerTransitionFix",
        @"enableIosFloatingMiniplayerTransitionBugFix",
        @"enableMiniplayerErrorFix", @"enableMiniplayerChangesPostCairo",
        @"shouldOpenMiniplayerOnStateChange", @"shouldShowMiniPlayer",
        @"hasShouldShowMiniPlayer", @"hasDisplayMiniPlayer",
        @"hasMiniplayer", @"isMiniplayer", @"allowDockingForMiniplayer",
        @"blockedForKidsContent", @"hasBlockedForKidsContent"
    ]];
    NSSet<NSString *> *captionGetters = [NSSet setWithArray:@[
        @"captionsEnabled", @"areCaptionsEnabled", @"captionEnabled",
        @"isCaptionEnabled", @"closedCaptionsEnabled",
        @"closedCaptioningEnabled", @"captionsEnabledWhenAvailable",
        @"shouldShowCaptions", @"captionsActive", @"captionVisible",
        @"captionsVisible", @"captionsRequested", @"deviceCaptionsOn",
        @"captionsDisabled", @"captionsHidden",
        @"captionVisibilityPersistenceEnabled",
        @"captionLanguagePersistenceEnabled", @"respectDeviceCaptionSetting",
        @"inlinePlaybackCaptionHiddenOnStartEnabled"
    ]];
    NSSet<NSString *> *captionSetters = [NSSet setWithArray:@[
        @"setCaptionsEnabled:", @"setClosedCaptionsEnabled:",
        @"setCaptionEnabled:", @"setIsCaptionEnabled:",
        @"setCaptionsActive:", @"setCaptionVisible:",
        @"setCaptionsVisible:", @"setCaptionsRequested:",
        @"setDeviceCaptionsOn:", @"setCaptionsDisabled:",
        @"setCaptionsHidden:", @"setPersistentUserCaptionVisibility:",
        @"setUserPreferredCaptionVisibilityAsHidden:"
    ]];
    NSSet<NSString *> *trackLists = [NSSet setWithArray:@[
        @"setAvailableCaptionTracks:", @"setCaptionTrackArray:",
        @"setUserVisibleCaptionTracks:", @"setTracklistCaptionTracks:"
    ]];
    NSSet<NSString *> *trackSetters = [NSSet setWithArray:@[
        @"setActiveCaptionTrack:", @"setCaptionTrack:"
    ]];
    NSArray<NSString *> *miniTokens = @[
        @"mini", @"playability", @"playerresponse",
        @"watch", @"playerhotconfig", @"globalconfig"
    ];
    NSArray<NSString *> *captionTokens = @[
        @"caption", @"player", @"playback", @"watch", @"globalconfig"
    ];
    NSMutableOrderedSet<NSString *> *targets = [NSMutableOrderedSet orderedSet];
    for (NSString *className in YTzoomAppClassNames()) {
        BOOL mini = YTzoomClassNameMatches(className, miniTokens);
        BOOL caption = YTzoomClassNameMatches(className, captionTokens);
        if (!mini && !caption) continue;
        Class cls = NSClassFromString(className);
        if (cls == Nil) continue;
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(cls, &methodCount);
        for (unsigned int methodIndex = 0;
             methodIndex < methodCount;
             methodIndex++) {
            NSString *selectorName = NSStringFromSelector(
                method_getName(methods[methodIndex])
            );
            NSString *kind = nil;
            if (mini && [selectorName isEqualToString:
                         @"isMiniplayerRendererPlaybackModePauseOnly"]) {
                kind = @"miniPause";
            } else if (mini && [miniSelectors containsObject:selectorName]) {
                kind = @"mini";
            } else if (caption &&
                       [captionGetters containsObject:selectorName]) {
                kind = @"captionBool";
            } else if (caption &&
                       [captionSetters containsObject:selectorName]) {
                kind = @"captionSetter";
            } else if (caption &&
                       [trackLists containsObject:selectorName]) {
                kind = @"captionTracks";
            } else if (caption &&
                       [trackSetters containsObject:selectorName]) {
                kind = @"captionTrack";
            } else if (caption && [selectorName isEqualToString:
                       @"setSelectedCaptionTrack:selectionReason:"]) {
                kind = @"captionSelected";
            }
            if (kind != nil) {
                [targets addObject:[NSString stringWithFormat:@"%@|%@|%@",
                    kind, className, selectorName]];
            }
        }
        free(methods);
    }

    NSArray<NSString *> *result = targets.array;
    [NSUserDefaults.standardUserDefaults setObject:result
                                    forKey:YTzoomMiscDiscoveryCacheKey()];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (NSString *target in result) {
            YTzoomApplyMiscDiscoveryTarget(target);
        }
    });
}

void YTzoomInstallMiscellaneousHooks(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:@"YTzoom.Preference.Playback.CaptionsMode"] == nil) {
        NSInteger legacy = [defaults boolForKey:@"YTzoom.Preference.Playback.CaptionsDisabled"] ? 2
            : ([defaults boolForKey:@"YTzoom.Preference.Playback.CaptionsAlwaysOn"] ? 1 : 0);
        if (legacy != 0) [defaults setInteger:legacy forKey:@"YTzoom.Preference.Playback.CaptionsMode"];
    }
    if (YTzoomMiscOriginals == nil) {
        YTzoomMiscOriginals = [NSMutableDictionary dictionary];
        YTzoomCaptionControllers = [NSHashTable weakObjectsHashTable];
    }
    YTzoomResolveForcedIdiom();
    if (YTzoomIdiomForced) {
        YTzoomComputeIdiomRanges();
        for (NSString *name in @[@"YTCommonUtils", @"OGLMetrics"]) {
            YTzoomInstallClassHook(name, @"isIPad",
                                   (IMP)YTzoomForcedIsIPad, NULL);
        }
        YTzoomInstallInstanceHook(@"UIDevice", @"userInterfaceIdiom",
                                  (IMP)YTzoomUserInterfaceIdiom,
                                  &OriginalDeviceIdiom);
    }
    YTzoomInstallInstanceHook(@"UIView", @"addInteraction:",
                              (IMP)YTzoomAddInteraction,
                              &OriginalAddInteraction);
    YTzoomInstallInstanceHook(@"UIView", @"semanticContentAttribute",
                              (IMP)YTzoomSemanticContent,
                              &OriginalSemanticContent);
    YTzoomInstallInstanceHook(@"UIView", @"setSemanticContentAttribute:",
                              (IMP)YTzoomSetSemanticContent,
                              &OriginalSetSemanticContent);
    NSArray<NSString *> *miniClasses = @[
        @"YTIPlayabilityStatus",
        @"YTPlayerResponse",
        @"YTIPlayerResponse",
        @"YTMiniplayerController"
    ];
    NSArray<NSString *> *miniSelectors = @[
        @"isPlayableInMiniPlayer",
        @"isPlayableInMiniplayer",
        @"miniplayerEnabled",
        @"isMiniplayerDisabled",
        @"miniPlayerDisabled",
        @"isMiniplayerUnavailable"
    ];
    for (NSString *className in miniClasses) {
        YTzoomInstallMiscBool(className,
            @"isMiniplayerRendererPlaybackModePauseOnly",
            (IMP)YTzoomMiniPlayerPauseOnlyValue);
        for (NSString *selectorName in miniSelectors) {
            YTzoomInstallMiscBool(className, selectorName, (IMP)YTzoomMiniPlayerValue);
        }
    }

    for (NSString *className in @[@"YTIPlayabilityStatus", @"YTPlayerResponse"] ) {
        for (NSString *selectorName in @[
            @"isAgeRestricted",
            @"requiresAgeVerification",
            @"shouldShowAgeGate",
            @"ageGateRequired",
            @"isAgeVerified",
            @"isAgeAllowed"
        ]) {
            YTzoomInstallMiscBool(className, selectorName, (IMP)YTzoomAgeValue);
        }
    }

    NSArray<NSString *> *captionClasses = @[
        @"YTPlayerViewController",
        @"YTLocalPlaybackController",
        @"YTMainAppVideoPlayerOverlayViewController",
        @"YTCaptionController"
    ];
    for (NSString *className in captionClasses) {
        for (NSString *selectorName in @[
            @"captionsEnabled",
            @"areCaptionsEnabled",
            @"isCaptionTrackSelected",
            @"closedCaptionsEnabled",
            @"captionsDisabled"
        ]) {
            YTzoomInstallMiscBool(className, selectorName, (IMP)YTzoomCaptionValue);
        }
        for (NSString *selectorName in @[
            @"setCaptionsEnabled:",
            @"setClosedCaptionsEnabled:"
        ]) {
            YTzoomInstallMiscSetter(className, selectorName, (IMP)YTzoomCaptionSetter);
        }
    }

    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"captionTracksArray",
                              (IMP)YTzoomCaptionTracks,
                              &OriginalCaptionTracks);
    NSString *controllerClass = @"MLInnerTubeCaptionController";
    YTzoomInstallClassHook(controllerClass, @"allocWithZone:",
                          (IMP)YTzoomCaptionControllerAlloc,
                          &OriginalCaptionControllerAlloc);
    IMP controllerOriginal = NULL;
    if (YTzoomInstallInstanceHook(controllerClass, @"init",
                                  (IMP)YTzoomCaptionControllerInit,
                                  &controllerOriginal)) {
        YTzoomStoreMiscOriginal(controllerClass, @"init",
                                controllerOriginal);
    }
    YTzoomApplyCachedMiscDiscovery();
    static dispatch_once_t discoveryObserverToken;
    dispatch_once(&discoveryObserverToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:nil
                    usingBlock:^(__unused NSNotification *notification) {
            if ([NSUserDefaults.standardUserDefaults
                    arrayForKey:YTzoomMiscDiscoveryCacheKey()].count != 0) {
                return;
            }
            static dispatch_once_t discoveryToken;
            dispatch_once(&discoveryToken, ^{
                for (NSNumber *delay in @[@0.5, @5.0]) {
                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            YTzoomDiscoverMiscHooks();
                        }
                    );
                }
            });
        }];
    });

    for (NSString *selectorName in @[@"showMessageMainThread:", @"showMessage:"]) {
        IMP original = NULL;
        if (YTzoomInstallInstanceHook(@"GOOHUDManagerInternal",
                                      selectorName,
                                      (IMP)YTzoomHUDMessage,
                                      &original)) {
            YTzoomStoreMiscOriginal(@"GOOHUDManagerInternal", selectorName, original);
        }
    }
}
