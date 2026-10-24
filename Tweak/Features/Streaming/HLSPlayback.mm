#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>

// visionOS client identifiers from yt-dlp (Unlicense, public domain)
static NSString *const YTzoomVisionClientName    = @"VISIONOS";
static NSString *const YTzoomVisionClientVersion = @"1.02";
static NSString *const YTzoomVisionDeviceMake    = @"Apple";
static NSString *const YTzoomVisionDeviceModel   = @"RealityDevice17,1";
static NSString *const YTzoomVisionOSName        = @"visionOS";
static NSString *const YTzoomVisionOSVersion     = @"26.5.23O471";
static NSString *const YTzoomVisionUserAgent     =
    @"Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
     "(KHTML, like Gecko) Version/26.0 Safari/605.1.15";

static const NSTimeInterval YTzoomHLSCacheLifetime = 4.0 * 60.0 * 60.0;

static IMP YTzoomHLSOrigInitFull;
static IMP YTzoomHLSOrigInitShort;
static IMP YTzoomHLSOrigInitRental;
static IMP YTzoomHLSOrigParseString;
static IMP YTzoomHLSOrigSetConstraint;
static IMP YTzoomHLSOrigPlay;
static IMP YTzoomHLSOrigPause;
static IMP YTzoomHLSOrigScrubStart;
static IMP YTzoomHLSOrigScrubEnd;

static NSMutableDictionary<NSString *, NSDictionary *> *YTzoomHLSCache;
static NSMutableSet<NSString *> *YTzoomHLSPending;
static NSMutableDictionary<NSString *, id> *YTzoomHLSOriginals;

static NSMutableDictionary<NSString *, NSString *> *YTzoomHLSSources;
static NSMutableSet<NSString *> *YTzoomHLSFallbacks;
static BOOL YTzoomHLSInScrubStart;
static BOOL YTzoomHLSScrubPaused;
static NSUInteger YTzoomHLSScrubGeneration;

static BOOL YTzoomHLSEnabled(void) {
    return YTzoomPlaybackFixMode() == 2;
}

static id YTzoomHLSGet(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL YTzoomHLSBool(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static long long YTzoomHLSInteger(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (object == nil || ![object respondsToSelector:selector]) return LLONG_MIN;
    const char *type = [object methodSignatureForSelector:selector].methodReturnType;
    if (type[0] == 'i') return ((int (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'q' || type[0] == 'l') return ((long long (*)(id, SEL))objc_msgSend)(object, selector);
    if (type[0] == 'B' || type[0] == 'c') return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    return LLONG_MIN;
}

static NSDictionary *YTzoomVisionContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": YTzoomVisionClientName,
        @"clientVersion": YTzoomVisionClientVersion,
        @"deviceMake": YTzoomVisionDeviceMake,
        @"deviceModel": YTzoomVisionDeviceModel,
        @"osName": YTzoomVisionOSName,
        @"osVersion": YTzoomVisionOSVersion,
        @"userAgent": YTzoomVisionUserAgent,
        @"hl": @"en",
        @"gl": @"US"
    } mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client};
}

static NSMutableURLRequest *YTzoomVisionRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *url = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 12;
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:YTzoomVisionUserAgent forHTTPHeaderField:@"User-Agent"];
    if (visitor.length != 0) [request setValue:visitor forHTTPHeaderField:@"X-Goog-Visitor-Id"];
    return request;
}

static NSString *YTzoomVisionVisitor(void) {
    NSDictionary *cached = YTzoomPreferenceObject(@"YTzoom.Cache.DirectVisitor");
    NSString *value = [cached isKindOfClass:NSDictionary.class] ? cached[@"id"] : nil;
    if ([value isKindOfClass:NSString.class] && value.length != 0) return value;
    static NSString *fetched;
    if (fetched.length != 0) return fetched;
    __block NSString *visitor = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:YTzoomVisionRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": YTzoomVisionContext(nil)}, nil)
        completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        id found = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
        if ([found isKindOfClass:NSString.class]) visitor = found;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)));
    fetched = visitor;
    return visitor;
}

static NSString *YTzoomHLSCachedURL(NSString *videoID) {
    @synchronized (YTzoomHLSCache) {
        NSDictionary *entry = YTzoomHLSCache[videoID];
        if (entry == nil) return nil;
        if (NSDate.date.timeIntervalSince1970 - [entry[@"time"] doubleValue] > YTzoomHLSCacheLifetime) {
            [YTzoomHLSCache removeObjectForKey:videoID];
            return nil;
        }
        return entry[@"url"];
    }
}

static void YTzoomHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready));

static void YTzoomHLSFetchVision(NSString *videoID) {
    YTzoomHLSFetchVisionThen(videoID, nil);
}

static void YTzoomHLSFetchVisionThen(NSString *videoID, void (^done)(BOOL ready)) {
    @synchronized (YTzoomHLSCache) {
        const BOOL cached = YTzoomHLSCache[videoID] != nil;
        if (cached) {
            if (done != nil) done(YES);
            return;
        }
        if ([YTzoomHLSPending containsObject:videoID]) {
            if (done != nil) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                               dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                    done(YTzoomHLSCachedURL(videoID) != nil);
                });
            }
            return;
        }
        [YTzoomHLSPending addObject:videoID];
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *visitor = YTzoomVisionVisitor();
        NSDictionary *body = @{
            @"context": YTzoomVisionContext(visitor),
            @"videoId": videoID,
            @"contentCheckOk": @YES,
            @"racyCheckOk": @YES
        };
        [[NSURLSession.sharedSession dataTaskWithRequest:YTzoomVisionRequest(@"player?prettyPrint=false", body, visitor)
            completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSDictionary *root = [json isKindOfClass:NSDictionary.class] ? json : @{};
            NSDictionary *playability = [root[@"playabilityStatus"] isKindOfClass:NSDictionary.class]
                ? root[@"playabilityStatus"] : @{};
            NSDictionary *streaming = [root[@"streamingData"] isKindOfClass:NSDictionary.class]
                ? root[@"streamingData"] : @{};
            NSString *hls = [streaming[@"hlsManifestUrl"] isKindOfClass:NSString.class] ? streaming[@"hlsManifestUrl"] : nil;
            @synchronized (YTzoomHLSCache) {
                [YTzoomHLSPending removeObject:videoID];
                if (hls.length != 0) {
                    YTzoomHLSCache[videoID] = @{@"url": hls, @"time": @(NSDate.date.timeIntervalSince1970)};
                }
            }
            if (hls.length == 0) {
                YTzoomDownloadLog(@"hls", @"vision video=%@ playability=%@ no manifest", videoID,
                                  playability[@"status"] ?: @"-");
            }
            if (done != nil) done(hls.length != 0);
        }] resume];
    });
}

BOOL YTzoomHLSBeginFallback(NSString *videoID, void (^ready)(BOOL available)) {
    if (!YTzoomHLSEnabled() || videoID.length == 0 || YTzoomHLSSources == nil) return NO;
    @synchronized (YTzoomHLSSources) {
        if (![YTzoomHLSSources[videoID] isEqualToString:@"ios"] || [YTzoomHLSFallbacks containsObject:videoID]) {
            return NO;
        }
        [YTzoomHLSFallbacks addObject:videoID];
    }
    YTzoomHLSFetchVisionThen(videoID, ^(BOOL available) {
        dispatch_async(dispatch_get_main_queue(), ^{ ready(available); });
    });
    return YES;
}

id YTzoomHLSOriginalResponse(NSString *videoID) {
    if (videoID.length == 0 || YTzoomHLSOriginals == nil) return nil;
    @synchronized (YTzoomHLSOriginals) {
        return YTzoomHLSOriginals[videoID];
    }
}

static void YTzoomHLSKeepOriginal(NSString *videoID, id data) {
    if (![data respondsToSelector:@selector(copyWithZone:)]) return;
    id copy = [data copy];
    if (copy == nil) return;
    @synchronized (YTzoomHLSOriginals) {
        if (YTzoomHLSOriginals.count > 20) [YTzoomHLSOriginals removeAllObjects];
        YTzoomHLSOriginals[videoID] = copy;
    }
}

static void YTzoomHLSSwap(id data) {
    if (!YTzoomHLSEnabled() || data == nil) return;
    NSString *videoID = YTzoomHLSGet(YTzoomHLSGet(data, @"videoDetails"), @"videoId");
    if (![videoID isKindOfClass:NSString.class] || videoID.length == 0) return;
    id streaming = YTzoomHLSGet(data, @"streamingData");
    if (streaming == nil || YTzoomHLSBool(streaming, @"isLivePlayback")) return;
    SEL setHLS = NSSelectorFromString(@"setHlsManifestURL:");
    SEL setSABR = NSSelectorFromString(@"setHasServerAbrStreamingURL:");
    SEL setOnesie = NSSelectorFromString(@"setHasOnesieStreamingURL:");
    if (![streaming respondsToSelector:setHLS] || ![streaming respondsToSelector:setSABR] ||
        ![streaming respondsToSelector:setOnesie]) return;
    NSString *ios = YTzoomHLSGet(streaming, @"hlsManifestURL");
    NSString *vision = YTzoomHLSCachedURL(videoID);
    NSString *chosen = vision.length != 0 ? vision : ([ios isKindOfClass:NSString.class] ? ios : nil);
    YTzoomHLSFetchVision(videoID);
    if (chosen.length == 0) return;
    YTzoomHLSKeepOriginal(videoID, data);
    ((void (*)(id, SEL, id))objc_msgSend)(streaming, setHLS, chosen);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setSABR, NO);
    ((void (*)(id, SEL, BOOL))objc_msgSend)(streaming, setOnesie, NO);
    NSMutableArray *formats = YTzoomHLSGet(streaming, @"adaptiveFormatsArray");
    if ([formats respondsToSelector:@selector(removeAllObjects)]) [formats removeAllObjects];
    @synchronized (YTzoomHLSSources) {
        if (YTzoomHLSSources.count > 50) [YTzoomHLSSources removeAllObjects];
        YTzoomHLSSources[videoID] = vision.length != 0 ? @"vision" : @"ios";
    }
    YTzoomDownloadLog(@"hls", @"swap video=%@ source=%@", videoID, vision.length != 0 ? @"vision" : @"ios");
}

static id YTzoomHLSInitFull(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                            id qoe, id key, id context, id latency, BOOL rental) {
    YTzoomHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, id, id, id, id, BOOL))YTzoomHLSOrigInitFull)(
        self, _cmd, data, date, offline, state, trailer, qoe, key, context, latency, rental);
}

static id YTzoomHLSInitShort(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer) {
    YTzoomHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL))YTzoomHLSOrigInitShort)(
        self, _cmd, data, date, offline, state, trailer);
}

static id YTzoomHLSInitRental(id self, SEL _cmd, id data, id date, id offline, id state, BOOL trailer,
                              BOOL rental) {
    YTzoomHLSSwap(data);
    return ((id (*)(id, SEL, id, id, id, id, BOOL, BOOL))YTzoomHLSOrigInitRental)(
        self, _cmd, data, date, offline, state, trailer, rental);
}

static BOOL YTzoomHLSDeviceDecodesVP9(void) {
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = VTIsHardwareDecodeSupported('vp09');
        YTzoomDownloadLog(@"hls", @"device vp9=%d", supported);
    });
    return supported;
}

static NSString *YTzoomHLSFilterManifest(NSString *text) {
    if (![text containsString:@"vp09"] || YTzoomHLSDeviceDecodesVP9()) return text;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSUInteger dropped = 0, total = 0;
    BOOL skipNext = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (skipNext) {
            skipNext = NO;
            if (![line hasPrefix:@"#"]) continue;
        }
        if ([line hasPrefix:@"#EXT-X-STREAM-INF"]) {
            total++;
            if ([line containsString:@"vp09"]) {
                dropped++;
                skipNext = YES;
                continue;
            }
        }
        [kept addObject:line];
    }
    if (dropped == 0 || dropped == total) return text;
    return [kept componentsJoinedByString:@"\n"];
}

static id YTzoomHLSParseString(id self, SEL _cmd, NSString *string, NSError **error) {
    if (YTzoomHLSEnabled() && [string isKindOfClass:NSString.class]) string = YTzoomHLSFilterManifest(string);
    return ((id (*)(id, SEL, id, NSError **))YTzoomHLSOrigParseString)(self, _cmd, string, error);
}

static BOOL YTzoomHLSSameConstraint(id current, id incoming) {
    if (current == incoming) return YES;
    if (current == nil || incoming == nil) return NO;
    if ([current isEqual:incoming]) return YES;
    if ([current class] != [incoming class]) return NO;
    for (NSString *key in @[@"videoQualitySetting", @"stickyResolutionCap", @"disableTrack"]) {
        if (YTzoomHLSInteger(current, key) != YTzoomHLSInteger(incoming, key)) return NO;
    }
    id currentLabel = YTzoomHLSGet(current, @"qualityLabel");
    id incomingLabel = YTzoomHLSGet(incoming, @"qualityLabel");
    return currentLabel == incomingLabel || [currentLabel isEqual:incomingLabel];
}

static void YTzoomHLSSetConstraint(id self, SEL _cmd, id constraint) {
    if (YTzoomHLSSameConstraint(YTzoomHLSGet(self, @"videoFormatConstraint"), constraint)) return;
    ((void (*)(id, SEL, id))YTzoomHLSOrigSetConstraint)(self, _cmd, constraint);
}

static void YTzoomHLSScrubStart(id self, SEL _cmd, BOOL bar) {
    YTzoomHLSScrubPaused = NO;
    YTzoomHLSScrubGeneration++;
    YTzoomHLSInScrubStart = YES;
    ((void (*)(id, SEL, BOOL))YTzoomHLSOrigScrubStart)(self, _cmd, bar);
    YTzoomHLSInScrubStart = NO;
}

static void YTzoomHLSScrubEnd(id self, SEL _cmd, BOOL bar, BOOL cancelled, int source) {
    ((void (*)(id, SEL, BOOL, BOOL, int))YTzoomHLSOrigScrubEnd)(self, _cmd, bar, cancelled, source);
    if (!YTzoomHLSScrubPaused) return;
    const NSUInteger generation = YTzoomHLSScrubGeneration;
    __weak id weakOverlay = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id overlay = weakOverlay;
        if (overlay == nil || !YTzoomHLSScrubPaused || generation != YTzoomHLSScrubGeneration) return;
        YTzoomHLSScrubPaused = NO;
        SEL play = NSSelectorFromString(@"didPressPlay:");
        if ([overlay respondsToSelector:play]) ((void (*)(id, SEL, id))objc_msgSend)(overlay, play, nil);
    });
}

static void YTzoomHLSPlay(id self, SEL _cmd) {
    YTzoomHLSScrubPaused = NO;
    ((void (*)(id, SEL))YTzoomHLSOrigPlay)(self, _cmd);
}

static void YTzoomHLSPause(id self, SEL _cmd, int reason) {
    if (YTzoomHLSInScrubStart) YTzoomHLSScrubPaused = YES;
    ((void (*)(id, SEL, int))YTzoomHLSOrigPause)(self, _cmd, reason);
}

void YTzoomInstallHLSPlaybackHooks(void) {
    if (!YTzoomHLSEnabled()) return;
    YTzoomHLSCache = [NSMutableDictionary dictionary];
    YTzoomHLSPending = [NSMutableSet set];
    YTzoomHLSOriginals = [NSMutableDictionary dictionary];
    YTzoomHLSSources = [NSMutableDictionary dictionary];
    YTzoomHLSFallbacks = [NSMutableSet set];
    NSString *response = @"YTPlayerResponse";
    YTzoomInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:QOEController:cacheKey:cacheContext:latencyLogger:offlineRentalActivated:",
        (IMP)YTzoomHLSInitFull, &YTzoomHLSOrigInitFull);
    YTzoomInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:",
        (IMP)YTzoomHLSInitShort, &YTzoomHLSOrigInitShort);
    YTzoomInstallInstanceHook(response,
        @"initWithPlayerData:responseDate:offlineStateDate:mutableState:trailer:offlineRentalActivated:",
        (IMP)YTzoomHLSInitRental, &YTzoomHLSOrigInitRental);
    YTzoomInstallInstanceHook(@"MLHLSMasterPlaylistParser", @"parseFromString:error:",
        (IMP)YTzoomHLSParseString, &YTzoomHLSOrigParseString);
    YTzoomInstallInstanceHook(@"MLAVPlayer", @"setVideoFormatConstraint:",
        (IMP)YTzoomHLSSetConstraint, &YTzoomHLSOrigSetConstraint);
    YTzoomInstallInstanceHook(@"MLAVPlayer", @"play", (IMP)YTzoomHLSPlay, &YTzoomHLSOrigPlay);
    YTzoomInstallInstanceHook(@"MLAVPlayer", @"pauseWithStoppageReason:",
        (IMP)YTzoomHLSPause, &YTzoomHLSOrigPause);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didStartPlayerBarScrubbingWithGestureOriginatingInPlayerBar:",
        (IMP)YTzoomHLSScrubStart, &YTzoomHLSOrigScrubStart);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didEndPlayerBarScrubbingWithGestureOriginatingInPlayerBar:withSeekCancelled:seekSource:",
        (IMP)YTzoomHLSScrubEnd, &YTzoomHLSOrigScrubEnd);
}
