#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalSetActiveCaptionTrack;
static IMP OriginalSetSingleVideoCaptionTrack;
static IMP OriginalSetCaptionError;
static IMP OriginalSetLocalCaptionTrack;
static IMP OriginalSetMDXCaptionTrack;
static BOOL YTzoomHasRememberedSource;
static NSMutableSet<NSString *> *YTzoomAppliedKeys;
static NSMutableDictionary<NSString *, NSNumber *> *YTzoomRestoredAt;
static const NSTimeInterval YTzoomRestoreWindow = 4.0;
static NSMutableSet<NSString *> *YTzoomFailedKeys;
static NSString *YTzoomLastAppliedKey;

static BOOL YTzoomCaptionKeyFailed(NSString *key) {
    if (key.length == 0 || YTzoomFailedKeys == nil) return NO;
    @synchronized (YTzoomFailedKeys) {
        return [YTzoomFailedKeys containsObject:key];
    }
}

static void YTzoomNoteCaptionFailure(NSString *key) {
    if (key.length == 0) return;
    if (YTzoomFailedKeys == nil) {
        YTzoomFailedKeys = [NSMutableSet set];
    }
    @synchronized (YTzoomFailedKeys) {
        if (YTzoomFailedKeys.count >= 128) {
            [YTzoomFailedKeys removeAllObjects];
        }
        [YTzoomFailedKeys addObject:key];
    }
}

static NSString *YTzoomCurrentVideoID(id player) {
    SEL selector = NSSelectorFromString(@"currentVideoID");
    if (![player respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(player, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}
static NSTimeInterval YTzoomCaptionBackoffUntil;

static __weak id YTzoomRememberedTrack;
static NSString *YTzoomRememberedVSSID;
static NSString *YTzoomRememberedLanguage;
static long long YTzoomRememberedSource;
static BOOL YTzoomHasRememberedTrack;

static NSString *YTzoomCaptionString(id track, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (track == nil || ![track respondsToSelector:selector]) return nil;
    id value = ((id (*)(id, SEL))objc_msgSend)(track, selector);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTzoomCaptionValueForKey(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static void YTzoomRememberTrack(id track, long long source) {
    YTzoomRememberedTrack = track;
    YTzoomRememberedVSSID = [YTzoomCaptionString(track, @"VSSID") copy];
    YTzoomRememberedLanguage = [YTzoomCaptionString(track, @"languageCode") copy];
    YTzoomRememberedSource = source;
    YTzoomHasRememberedSource = YES;
    YTzoomHasRememberedTrack = YES;
}

static void YTzoomSetActiveCaptionTrack(id receiver,
                                        SEL selector,
                                        id track,
                                        long long source) {
    YTzoomDownloadLog(@"caption", @"app set track=%@ source=%lld class=%@",
                      YTzoomCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track != nil) {
        YTzoomRememberTrack(track, source);
    } else {
        YTzoomHasRememberedTrack = NO;
        YTzoomRememberedTrack = nil;
        YTzoomRememberedVSSID = nil;
        YTzoomRememberedLanguage = nil;
    }
    if (OriginalSetActiveCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetActiveCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTzoomSetSingleVideoCaptionTrack(id receiver,
                                             SEL selector,
                                             id track,
                                             long long source) {
    YTzoomDownloadLog(@"caption", @"single set track=%@ source=%lld class=%@",
                      YTzoomCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (track != nil) {
        YTzoomRememberTrack(track, source);
    }
    if (OriginalSetSingleVideoCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetSingleVideoCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTzoomSetCaptionError(id receiver, SEL selector, id error) {
    if (error != nil) {
        NSError *value = [error isKindOfClass:NSError.class] ? error : nil;
        YTzoomDownloadLog(@"caption",
                          @"ERROR domain=%@ code=%ld desc=%@ class=%@",
                          value.domain ?: @"?", (long)value.code,
                          value.localizedDescription ?: [error description],
                          NSStringFromClass(object_getClass(receiver)));
        if (value.code == 429) {
            YTzoomNoteCaptionFailure(YTzoomLastAppliedKey);
            YTzoomCaptionBackoffUntil = CACurrentMediaTime() + 30;
            YTzoomDownloadLog(@"caption",
                              @"429 cooldown 30s blamed=%@",
                              YTzoomLastAppliedKey ?: @"nil");
        }
    }
    if (OriginalSetCaptionError != NULL) {
        ((void (*)(id, SEL, id))OriginalSetCaptionError)(receiver, selector,
                                                        error);
    }
}

static void YTzoomSetLocalCaptionTrack(id receiver, SEL selector, id track,
                                       long long source) {
    YTzoomDownloadLog(@"caption", @"local set track=%@ source=%lld class=%@",
                      YTzoomCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetLocalCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetLocalCaptionTrack)(
            receiver, selector, track, source);
    }
}

static void YTzoomSetMDXCaptionTrack(id receiver, SEL selector, id track,
                                     long long source) {
    YTzoomDownloadLog(@"caption", @"mdx set track=%@ source=%lld class=%@",
                      YTzoomCaptionString(track, @"languageCode") ?: @"nil",
                      source, NSStringFromClass(object_getClass(receiver)));
    if (OriginalSetMDXCaptionTrack != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalSetMDXCaptionTrack)(
            receiver, selector, track, source);
    }
}

static id YTzoomMatchingTrack(id player) {
    id video = YTzoomCaptionValueForKey(player, @"activeVideo");
    id available = YTzoomCaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTzoomCaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class]) return YTzoomRememberedTrack;
    for (id track in (NSArray *)available) {
        NSString *vssID = YTzoomCaptionString(track, @"VSSID");
        if (YTzoomRememberedVSSID.length != 0 &&
            [vssID isEqualToString:YTzoomRememberedVSSID]) {
            return track;
        }
    }
    for (id track in (NSArray *)available) {
        NSString *language = YTzoomCaptionString(track, @"languageCode");
        if (YTzoomRememberedLanguage.length != 0 &&
            [language isEqualToString:YTzoomRememberedLanguage]) {
            return track;
        }
    }
    return YTzoomRememberedTrack;
}


static NSString *const YTzoomPreferredLanguageKey =
    @"YTzoom.Preference.Playback.CaptionLanguage";

static NSString *YTzoomTrackLanguage(id track) {
    id value = YTzoomCaptionValueForKey(track, @"languageCode");
    return [value isKindOfClass:NSString.class] ? value : nil;
}

void YTzoomApplyPreferredCaptionLanguage(id player) {
    NSString *preferred = [NSUserDefaults.standardUserDefaults
        stringForKey:YTzoomPreferredLanguageKey];
    if (preferred.length == 0) return;

    id video = YTzoomCaptionValueForKey(player, @"activeVideo");
    id available = YTzoomCaptionValueForKey(video, @"availableCaptionTracks")
        ?: YTzoomCaptionValueForKey(player, @"availableCaptionTracks");
    if (![available isKindOfClass:NSArray.class] || [available count] == 0) {
        return;
    }
    id active = YTzoomCaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil &&
        [YTzoomTrackLanguage(active) hasPrefix:preferred]) {
        return;
    }

    if (YTzoomCaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < YTzoomCaptionBackoffUntil) {
        return;
    }

    NSString *videoID = nil;
    SEL videoIDSel = NSSelectorFromString(@"currentVideoID");
    if ([player respondsToSelector:videoIDSel]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(player, videoIDSel);
        if ([value isKindOfClass:NSString.class]) videoID = value;
    }
    NSString *appliedKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, preferred] : nil;
    if (YTzoomAppliedKeys == nil) {
        YTzoomAppliedKeys = [NSMutableSet set];
    }
    if (appliedKey != nil && [YTzoomAppliedKeys containsObject:appliedKey]) {
        return;
    }
    if (YTzoomCaptionKeyFailed(appliedKey)) {
        YTzoomDownloadLog(@"caption", @"skip known-failed %@", appliedKey);
        return;
    }

    id exact = nil;
    NSInteger exactRank = NSIntegerMax;
    id prefix = nil;
    NSMutableArray<NSString *> *vssList = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        NSString *code = YTzoomTrackLanguage(track);
        if (code.length == 0) continue;
        NSString *vss = YTzoomCaptionString(track, @"VSSID") ?: @"";
        if ([code caseInsensitiveCompare:preferred] == NSOrderedSame) {
            [vssList addObject:vss.length != 0 ? vss : @"-"];
            NSInteger rank = 2;
            if ([vss hasPrefix:@"."]) {
                rank = 0;
            } else if ([vss hasPrefix:@"a."]) {
                rank = 1;
            }
            if (rank < exactRank) {
                exactRank = rank;
                exact = track;
            }
            continue;
        }
        if (prefix == nil && [code.lowercaseString
                hasPrefix:preferred.lowercaseString]) {
            prefix = track;
        }
    }
    if (vssList.count > 1) {
        YTzoomDownloadLog(@"caption", @"candidates %@ picked rank=%ld",
                          [vssList componentsJoinedByString:@","],
                          (long)exactRank);
    }
    NSMutableArray<NSString *> *codes = [NSMutableArray array];
    for (id track in (NSArray *)available) {
        [codes addObject:YTzoomTrackLanguage(track) ?: @"?"];
    }
    YTzoomDownloadLog(@"caption",
                      @"apply preferred=%@ count=%lu tracks=%@ active=%@ "
                       "haveSource=%d source=%lld",
                      preferred, (unsigned long)[available count],
                      [codes componentsJoinedByString:@","],
                      YTzoomTrackLanguage(active) ?: @"nil",
                      YTzoomHasRememberedSource, YTzoomRememberedSource);

    id chosen = exact ?: prefix;
    if (chosen == nil) {
        YTzoomDownloadLog(@"caption",
                          @"no usable track for %@ translatedOnly=%@",
                          preferred,
                          vssList.count != 0
                            ? [vssList componentsJoinedByString:@","] : @"-");
        return;
    }
    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (appliedKey != nil) {
        if (YTzoomAppliedKeys.count >= 64) {
            [YTzoomAppliedKeys removeAllObjects];
        }
        [YTzoomAppliedKeys addObject:appliedKey];
        YTzoomLastAppliedKey = appliedKey;
    }
    const long long applySource = 3;
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, chosen, applySource);
    YTzoomDownloadLog(@"caption",
                      @"applied preferred=%@ chosen=%@ vss=%@ exact=%d "
                       "source=%lld video=%@",
                      preferred, YTzoomTrackLanguage(chosen) ?: @"?",
                      YTzoomCaptionString(chosen, @"VSSID") ?: @"-",
                      exact != nil, applySource,
                      videoID ?: @"?");
}

void YTzoomCaptionsSnapshot(id player) {
    id video = YTzoomCaptionValueForKey(player, @"activeVideo");
    id active = YTzoomCaptionValueForKey(video, @"activeCaptionTrack");
    if (active != nil) {
        YTzoomRememberTrack(active, YTzoomRememberedSource);
    }
}

void YTzoomCaptionsRestore(id player) {
    if (!YTzoomHasRememberedTrack) return;
    if (YTzoomCaptionBackoffUntil != 0 &&
        CACurrentMediaTime() < YTzoomCaptionBackoffUntil) {
        return;
    }
    id video = YTzoomCaptionValueForKey(player, @"activeVideo");
    if (YTzoomCaptionValueForKey(video, @"activeCaptionTrack") != nil) return;

    id track = YTzoomMatchingTrack(player);
    if (track == nil) return;

    NSString *videoID = YTzoomCurrentVideoID(player);
    NSString *language = YTzoomCaptionString(track, @"languageCode") ?: @"?";
    NSString *restoreKey = videoID.length != 0
        ? [NSString stringWithFormat:@"%@|%@", videoID, language] : nil;
    if (YTzoomRestoredAt == nil) {
        YTzoomRestoredAt = [NSMutableDictionary dictionary];
    }
    const NSTimeInterval now = CACurrentMediaTime();
    NSNumber *lastRestore = restoreKey != nil ? YTzoomRestoredAt[restoreKey] : nil;
    if (lastRestore != nil && now - lastRestore.doubleValue < YTzoomRestoreWindow) {
        return;
    }
    if (YTzoomCaptionKeyFailed(restoreKey)) return;

    SEL setter = NSSelectorFromString(@"setActiveCaptionTrack:source:");
    if (![player respondsToSelector:setter]) return;
    if (restoreKey != nil) {
        if (YTzoomRestoredAt.count >= 64) {
            [YTzoomRestoredAt removeAllObjects];
        }
        YTzoomRestoredAt[restoreKey] = @(now);
        YTzoomLastAppliedKey = restoreKey;
    }
    ((void (*)(id, SEL, id, long long))objc_msgSend)(
        player, setter, track, YTzoomRememberedSource);
    YTzoomDownloadLog(@"fix", @"captions restored %@ video=%@", language,
                      videoID ?: @"?");
}

void YTzoomInstallCaptionHooks(void) {
    BOOL pvc = YTzoomInstallInstanceHook(@"YTPlayerViewController",
                                        @"setActiveCaptionTrack:source:",
                                        (IMP)YTzoomSetActiveCaptionTrack,
                                        &OriginalSetActiveCaptionTrack);
    BOOL svc = YTzoomInstallInstanceHook(
        @"YTSingleVideoController", @"setActiveCaptionTrack:source:",
        (IMP)YTzoomSetSingleVideoCaptionTrack,
        &OriginalSetSingleVideoCaptionTrack);
    BOOL err = YTzoomInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"setCaptionError:",
        (IMP)YTzoomSetCaptionError, &OriginalSetCaptionError);
    BOOL loc = YTzoomInstallInstanceHook(
        @"YTLocalPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)YTzoomSetLocalCaptionTrack, &OriginalSetLocalCaptionTrack);
    BOOL mdx = YTzoomInstallInstanceHook(
        @"MDXPlaybackController", @"setActiveCaptionTrack:source:",
        (IMP)YTzoomSetMDXCaptionTrack, &OriginalSetMDXCaptionTrack);
    YTzoomDownloadLog(@"caption",
                      @"hooks pvc=%d single=%d error=%d local=%d mdx=%d",
                      pvc, svc, err, loc, mdx);
}
