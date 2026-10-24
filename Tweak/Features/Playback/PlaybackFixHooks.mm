/*
 * Playback error recovery adapted from YTPlaybackFix by Mark02.
 * https://github.com/Mark02-2012/YTPlaybackFix
 *
 * Copyright (c) 2026 Mark02
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTzoomPlaybackFixKey = @"YTzoom.Preference.Playback.Fix";
static const NSTimeInterval YTzoomStallGrace = 0.8;
static const double YTzoomProgressEpsilon = 0.15;

static NSString *const YTzoomPlaybackErrorDomain =
    @"com.google.ios.youtube.ErrorDomain.playback";

static double gLatestTime = 0.0;
static BOOL gIsTimeToRetry = NO;
static bool gEmergencyCheckRunning = false;

static IMP OriginalCurrentVideoMediaTime;
static IMP OriginalSeekToTime;
static IMP OriginalHandleError;

NSInteger YTzoomPlaybackFixMode(void) {
    if (!YTzoomMasterEnabled()) return 0;
    id stored = YTzoomPreferenceObject(@"YTzoom.Preference.Playback.FixMode");
    if ([stored respondsToSelector:@selector(integerValue)]) {
        const NSInteger mode = [stored integerValue];
        return mode >= 0 && mode <= 2 ? mode : 0;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.HLSMode")) return 2;
    return YTzoomFeatureEnabled(YTzoomPlaybackFixKey) ? 1 : 0;
}

static BOOL YTzoomPlaybackFixEnabled(void) {
    return YTzoomPlaybackFixMode() == 1;
}

static id YTzoomParentResponder(id overlay) {
    SEL responderGetter = NSSelectorFromString(@"parentResponder");
    if (![overlay respondsToSelector:responderGetter]) {
        YTzoomDownloadLog(@"fix", @"parentResponder unavailable");
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(overlay, responderGetter);
}

static void YTzoomSendRetryEvent(id overlay, NSString *stage) {
    id responder = YTzoomParentResponder(overlay);
    if (responder == nil) {
        YTzoomDownloadLog(@"fix", @"%@ no responder", stage);
        return;
    }
    Class eventClass = NSClassFromString(@"YTPlayerTapToRetryResponderEvent");
    SEL factory = NSSelectorFromString(@"eventWithFirstResponder:");
    if (eventClass == Nil || ![eventClass respondsToSelector:factory]) {
        YTzoomDownloadLog(@"fix", @"%@ event class missing", stage);
        return;
    }
    id event = ((id (*)(Class, SEL, id))objc_msgSend)(eventClass, factory,
                                                      responder);
    SEL send = NSSelectorFromString(@"send");
    if (event == nil || ![event respondsToSelector:send]) {
        YTzoomDownloadLog(@"fix", @"%@ event not created", stage);
        return;
    }
    ((void (*)(id, SEL))objc_msgSend)(event, send);
    YTzoomDownloadLog(@"fix", @"%@ retry event sent to %@", stage,
                      NSStringFromClass([responder class]));
}

static BOOL YTzoomReloadPlayer(id pvc, NSString *stage) {
    SEL activeGetter = NSSelectorFromString(@"activeVideo");
    if (pvc == nil || ![pvc respondsToSelector:activeGetter]) return NO;
    id video = ((id (*)(id, SEL))objc_msgSend)(pvc, activeGetter);
    SEL reloadSel = NSSelectorFromString(@"player:reloadWithContext:");
    SEL mediaGetter = NSSelectorFromString(@"mediaPlayer");
    Class contextClass = NSClassFromString(@"MLPlayerReloadContext");
    SEL contextInit = NSSelectorFromString(
        @"initWithStartPlayback:refreshStreamingData:");
    if (video == nil || contextClass == Nil ||
        ![video respondsToSelector:reloadSel] ||
        ![video respondsToSelector:mediaGetter]) {
        YTzoomDownloadLog(@"fix", @"%@ player reload unavailable on %@", stage,
                          video == nil ? @"nil" : NSStringFromClass([video class]));
        return NO;
    }
    id allocated = [contextClass alloc];
    if (![allocated respondsToSelector:contextInit]) return NO;
    id context = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
        allocated, contextInit, YES, YES);
    if (context == nil) return NO;
    id media = ((id (*)(id, SEL))objc_msgSend)(video, mediaGetter);
    ((void (*)(id, SEL, id, id))objc_msgSend)(video, reloadSel, media, context);
    YTzoomDownloadLog(@"fix", @"%@ player reload on %@", stage,
                      NSStringFromClass([video class]));
    return YES;
}

static void YTzoomSeek(id player, double position, NSString *stage) {
    SEL seek = NSSelectorFromString(@"seekToTime:");
    if (![player respondsToSelector:seek]) {
        YTzoomDownloadLog(@"fix", @"%@ seek unavailable", stage);
        return;
    }
    ((void (*)(id, SEL, double))objc_msgSend)(player, seek, position);
    YTzoomDownloadLog(@"fix", @"%@ seek %.2f", stage, position);
}


static void YTzoomScheduleCaptionRestore(id player) {
    __weak id weakPlayer = player;
    const double delays[] = { 0.6, 1.5, 3.0 };
    for (size_t index = 0; index < sizeof(delays) / sizeof(delays[0]); index++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[index] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTzoomCaptionsRestore(weakPlayer);
        });
    }
}

static double YTzoomPosition(id player) {
    SEL time = NSSelectorFromString(@"currentVideoMediaTime");
    if (![player respondsToSelector:time]) return -1.0;
    return ((double (*)(id, SEL))objc_msgSend)(player, time);
}

static double YTzoomCurrentVideoMediaTime(id receiver, SEL selector) {
    const double value = OriginalCurrentVideoMediaTime == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalCurrentVideoMediaTime)(receiver, selector);
    gLatestTime = value;
    return value;
}

static void YTzoomSeekToTime(id receiver, SEL selector, double time) {
    gLatestTime = time;
    if (OriginalSeekToTime != NULL) {
        ((void (*)(id, SEL, double))OriginalSeekToTime)(receiver, selector, time);
    }
}

static void YTzoomCallOriginalHandleError(id receiver, SEL selector, id error) {
    if (OriginalHandleError != NULL) {
        ((void (*)(id, SEL, id))OriginalHandleError)(receiver, selector, error);
    }
}

static void YTzoomHandleError(id receiver, SEL selector, id error) {
    if (YTzoomPlaybackFixMode() == 2) {
        NSError *hlsError = [error isKindOfClass:NSError.class] ? error : nil;
        YTzoomDownloadLog(@"hls", @"player error domain=%@ code=%ld", hlsError.domain ?: @"-",
                          (long)hlsError.code);
        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter) : nil;
        SEL videoGetter = NSSelectorFromString(@"currentVideoID");
        NSString *videoID = [pvc respondsToSelector:videoGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(pvc, videoGetter) : nil;
        __weak id weakReceiver = receiver;
        __weak id weakPlayer = pvc;
        const BOOL started = [videoID isKindOfClass:NSString.class] &&
            YTzoomHLSBeginFallback(videoID, ^(BOOL available) {
                id strongReceiver = weakReceiver;
                id strongPlayer = weakPlayer;
                if (available && strongPlayer != nil && YTzoomReloadPlayer(strongPlayer, @"hls fallback")) {
                    YTzoomDownloadLog(@"hls", @"fallback to vision video=%@", videoID);
                    return;
                }
                YTzoomDownloadLog(@"hls", @"fallback unavailable video=%@", videoID);
                if (strongReceiver != nil) YTzoomCallOriginalHandleError(strongReceiver, selector, error);
            });
        if (started) return;
        YTzoomCallOriginalHandleError(receiver, selector, error);
        return;
    }
    if (!YTzoomPlaybackFixEnabled()) {
        YTzoomCallOriginalHandleError(receiver, selector, error);
        return;
    }

    if (gIsTimeToRetry) {
        YTzoomDownloadLog(@"fix", @"retry already in flight, passing through");
        YTzoomCallOriginalHandleError(receiver, selector, error);
        return;
    }

    NSError *failure = [error isKindOfClass:NSError.class] ? (NSError *)error : nil;
    if (failure != nil) {
        YTzoomDownloadLog(@"fix", @"handleError domain=%@ code=%ld",
                          failure.domain, (long)failure.code);
    } else {
        YTzoomDownloadLog(@"fix", @"handleError non-NSError %@",
                          NSStringFromClass([error class]));
    }

    if (failure != nil &&
        [failure.domain isEqualToString:YTzoomPlaybackErrorDomain] &&
        (failure.code == 14 || failure.code == 0)) {
        gIsTimeToRetry = YES;

        SEL parentGetter = NSSelectorFromString(@"parentViewController");
        id pvc = [receiver respondsToSelector:parentGetter]
            ? ((id (*)(id, SEL))objc_msgSend)(receiver, parentGetter)
            : nil;
        const double savedTime = gLatestTime;
        YTzoomDownloadLog(@"fix", @"intercepted code=%ld at %.2f parent=%@",
                          (long)failure.code, savedTime,
                          pvc == nil ? @"nil" : NSStringFromClass([pvc class]));

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(YTzoomStallGrace * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            const double moved = YTzoomPosition(pvc);
            if (moved > savedTime + YTzoomProgressEpsilon) {
                gIsTimeToRetry = NO;
                YTzoomDownloadLog(@"fix", @"still playing %.2f -> %.2f, no retry",
                                  savedTime, moved);
                return;
            }
            YTzoomDownloadLog(@"fix", @"stalled at %.2f, retrying", savedTime);
            YTzoomCaptionsSnapshot(pvc);
            if (!YTzoomReloadPlayer(pvc, @"primary")) {
                YTzoomSendRetryEvent(receiver, @"primary");
            }

            if (pvc) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.20 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    YTzoomSeek(pvc, savedTime, @"primary");

                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(0.10 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        YTzoomScheduleCaptionRestore(pvc);

                        if (!gEmergencyCheckRunning) {
                            gEmergencyCheckRunning = true;

                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                         (int64_t)(3.00 * NSEC_PER_SEC)),
                                           dispatch_get_main_queue(), ^{
                                const double currentTime = YTzoomPosition(pvc);
                                YTzoomDownloadLog(@"fix",
                                    @"verify saved=%.2f now=%.2f", savedTime,
                                    currentTime);

                                if (currentTime <= savedTime + 0.05) {
                                    YTzoomDownloadLog(@"fix", @"still stalled");
                                    if (!YTzoomReloadPlayer(pvc, @"emergency")) {
                                        YTzoomSendRetryEvent(receiver, @"emergency");
                                    }
                                    YTzoomSeek(pvc, savedTime, @"emergency");

                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                                 (int64_t)(0.20 * NSEC_PER_SEC)),
                                                   dispatch_get_main_queue(), ^{
                                        YTzoomScheduleCaptionRestore(pvc);
                                        gIsTimeToRetry = NO;
                                        YTzoomDownloadLog(@"fix", @"emergency done");
                                    });
                                } else {
                                    gIsTimeToRetry = NO;
                                    YTzoomDownloadLog(@"fix", @"recovered");
                                }

                                gEmergencyCheckRunning = false;
                            });
                        } else {
                            YTzoomDownloadLog(@"fix", @"emergency check busy");
                        }
                    });
                });
            } else {
                gIsTimeToRetry = NO;
                YTzoomDownloadLog(@"fix", @"no parent view controller");
            }
        });

        return;
    }

    YTzoomCallOriginalHandleError(receiver, selector, error);
}

void YTzoomInstallPlaybackFixHooks(void) {
    const BOOL time = YTzoomInstallInstanceHook(
        @"YTPlayerViewController", @"currentVideoMediaTime",
        (IMP)YTzoomCurrentVideoMediaTime, &OriginalCurrentVideoMediaTime);
    const BOOL seek = YTzoomInstallInstanceHook(
        @"YTPlayerViewController", @"seekToTime:",
        (IMP)YTzoomSeekToTime, &OriginalSeekToTime);
    const BOOL handle = YTzoomInstallInstanceHook(
        @"YTMainAppVideoPlayerOverlayViewController", @"handleError:",
        (IMP)YTzoomHandleError, &OriginalHandleError);
    YTzoomDownloadLog(@"fix", @"hooks time=%d seek=%d handle=%d enabled=%d",
                      time, seek, handle, YTzoomPlaybackFixEnabled());
}
