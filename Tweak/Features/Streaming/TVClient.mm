#import "../../YTzoom.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

static NSString *const YTzoomTVName = @"TVHTML5";
static NSString *const YTzoomTVVersion = @"7.20260707.07.00";
static NSString *const YTzoomTVNumber = @"7";
static NSString *const YTzoomTVDeviceMake = @"Sony";
static NSString *const YTzoomTVDeviceModel = @"PS4";
static NSString *const YTzoomTVOSName = @"PlayStation 4";
static NSString *const YTzoomTVPlatform = @"GAME_CONSOLE";
static NSString *const YTzoomTVUserAgent =
    @"Mozilla/5.0 (PS4; Leanback Shell) Gecko/20100101 Firefox/65.0 "
     "LeanbackShell/01.00.01.75 Sony PS4/ (PS4, , no, CH)";
static NSString *const YTzoomTVVisitorKey = @"YTzoom.Cache.TVVisitor";
static NSString *const YTzoomTVTimestampKey = @"YTzoom.Cache.TVSignatureTimestamps";
static const NSTimeInterval YTzoomTVVisitorLifetime = 30.0 * 24.0 * 60.0 * 60.0;

static NSDictionary *YTzoomTVContext(NSString *visitor) {
    NSMutableDictionary *client = [@{
        @"clientName": YTzoomTVName, @"clientVersion": YTzoomTVVersion,
        @"platform": YTzoomTVPlatform, @"deviceMake": YTzoomTVDeviceMake,
        @"deviceModel": YTzoomTVDeviceModel, @"osName": YTzoomTVOSName, @"osVersion": @"",
        @"hl": @"en-GB", @"gl": @"GB", @"utcOffsetMinutes": @0} mutableCopy];
    if (visitor.length != 0) client[@"visitorData"] = visitor;
    return @{@"client": client, @"request": @{@"useSsl": @YES},
             @"user": @{@"lockedSafetyMode": @NO}};
}

NSDictionary<NSString *, NSString *> *YTzoomTVHeaders(NSString *visitor) {
    NSMutableDictionary *headers = [@{
        @"User-Agent": YTzoomTVUserAgent, @"X-YouTube-Client-Name": YTzoomTVNumber,
        @"X-YouTube-Client-Version": YTzoomTVVersion, @"Origin": @"https://www.youtube.com"} mutableCopy];
    if (visitor.length != 0) headers[@"X-Goog-Visitor-Id"] = visitor;
    return headers;
}

static void YTzoomTVAppendField(NSMutableData *data, uint64_t key, NSData *value) {
    while (key >= 0x80) { uint8_t byte = (uint8_t)(key | 0x80); [data appendBytes:&byte length:1]; key >>= 7; }
    uint8_t last = (uint8_t)key;
    [data appendBytes:&last length:1];
    if (value == nil) return;
    uint64_t length = value.length;
    while (length >= 0x80) { uint8_t byte = (uint8_t)(length | 0x80); [data appendBytes:&byte length:1]; length >>= 7; }
    uint8_t tail = (uint8_t)length;
    [data appendBytes:&tail length:1];
    [data appendData:value];
}

NSData *YTzoomTVClientInfo(void) {
    NSMutableData *data = [NSMutableData data];
    NSData *(^text)(NSString *) = ^NSData *(NSString *value) {
        return [value dataUsingEncoding:NSUTF8StringEncoding];
    };
    YTzoomTVAppendField(data, (12 << 3) | 2, text(YTzoomTVDeviceMake));
    YTzoomTVAppendField(data, (13 << 3) | 2, text(YTzoomTVDeviceModel));
    YTzoomTVAppendField(data, (16 << 3) | 0, nil);
    uint8_t name = 7;
    [data appendBytes:&name length:1];
    YTzoomTVAppendField(data, (17 << 3) | 2, text(YTzoomTVVersion));
    YTzoomTVAppendField(data, (18 << 3) | 2, text(YTzoomTVOSName));
    YTzoomTVAppendField(data, (21 << 3) | 2, text(@"en"));
    YTzoomTVAppendField(data, (22 << 3) | 2, text(@"GB"));
    return data;
}

static NSData *YTzoomTVFetch(NSURLRequest *request, NSInteger *status) {
    __block NSData *result = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, __unused NSError *error) {
        result = data;
        code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    if (status != NULL) *status = code;
    return result;
}

static NSMutableURLRequest *YTzoomTVRequest(NSString *path, NSDictionary *body, NSString *visitor) {
    NSURL *URL = [NSURL URLWithString:[@"https://youtubei.googleapis.com/youtubei/v1/" stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *headers = YTzoomTVHeaders(visitor);
    for (NSString *key in headers) [request setValue:headers[key] forHTTPHeaderField:key];
    return request;
}

static NSString *YTzoomTVVisitor(BOOL refresh) {
    NSDictionary *cached = YTzoomPreferenceObject(YTzoomTVVisitorKey);
    if (!refresh && [cached isKindOfClass:NSDictionary.class]) {
        NSString *value = cached[@"id"];
        NSNumber *time = cached[@"time"];
        if ([value isKindOfClass:NSString.class] && value.length != 0 &&
            NSDate.date.timeIntervalSince1970 - time.doubleValue < YTzoomTVVisitorLifetime) {
            return value;
        }
    }
    NSInteger status = 0;
    NSData *data = YTzoomTVFetch(YTzoomTVRequest(
        @"guide?prettyPrint=false&fields=responseContext.visitorData",
        @{@"context": YTzoomTVContext(nil)}, nil), &status);
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString *visitor = [json isKindOfClass:NSDictionary.class] ? json[@"responseContext"][@"visitorData"] : nil;
    if ([visitor isKindOfClass:NSString.class] && visitor.length != 0) {
        YTzoomSetPreferenceObject(YTzoomTVVisitorKey,
            @{@"id": visitor, @"time": @(NSDate.date.timeIntervalSince1970)});
        return visitor;
    }
    YTzoomDownloadLog(@"tv", @"visitor failed http=%ld", (long)status);
    return nil;
}

static NSString *YTzoomTVFirstMatch(NSString *text, NSString *pattern) {
    if (text.length == 0) return nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : nil;
}

static BOOL YTzoomTVPlayer(NSString **playerID, NSString **playerJS, NSInteger *timestamp) {
    static NSString *cachedIdentifier;
    static CFAbsoluteTime cachedAt;
    NSString *identifier = nil;
    @synchronized (YTzoomTVTimestampKey) {
        if (cachedIdentifier.length != 0 && CFAbsoluteTimeGetCurrent() - cachedAt < 6.0 * 60.0 * 60.0) {
            identifier = cachedIdentifier;
        }
    }
    if (identifier.length == 0) {
        NSData *api = YTzoomTVFetch([NSURLRequest requestWithURL:
            [NSURL URLWithString:@"https://www.youtube.com/iframe_api"]], NULL);
        identifier = YTzoomTVFirstMatch(
            api ? [[NSString alloc] initWithData:api encoding:NSUTF8StringEncoding] : nil,
            @"player\\\\?/([0-9a-f]{8})\\\\?/");
        if (identifier.length == 0) return NO;
        @synchronized (YTzoomTVTimestampKey) {
            cachedIdentifier = identifier;
            cachedAt = CFAbsoluteTimeGetCurrent();
        }
    }
    *playerID = identifier;
    NSDictionary *known = YTzoomPreferenceObject(YTzoomTVTimestampKey);
    NSNumber *stored = [known isKindOfClass:NSDictionary.class] ? known[identifier] : nil;
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    NSString *prepared = [caches URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTzoom-player-%@.js", identifier]].path;
    if (stored != nil && [NSFileManager.defaultManager fileExistsAtPath:prepared]) {
        *timestamp = stored.integerValue;
        return YES;
    }
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/s/player/%@/player_ias.vflset/en_US/base.js", identifier];
    NSData *js = YTzoomTVFetch([NSURLRequest requestWithURL:[NSURL URLWithString:address]], NULL);
    NSString *source = js ? [[NSString alloc] initWithData:js encoding:NSUTF8StringEncoding] : nil;
    NSString *value = YTzoomTVFirstMatch(source, @"(?:signatureTimestamp|sts)\\s*:\\s*(\\d{5})");
    if (source.length == 0) return NO;
    *playerJS = source;
    *timestamp = value.integerValue;
    NSMutableDictionary *updated = [known isKindOfClass:NSDictionary.class] ? [known mutableCopy] : [NSMutableDictionary dictionary];
    if (updated.count > 8) [updated removeAllObjects];
    updated[identifier] = @(value.integerValue);
    YTzoomSetPreferenceObject(YTzoomTVTimestampKey, updated);
    return YES;
}

void YTzoomTVFetchPlayerResponse(NSString *videoID, void (^completion)(id _Nullable response,
                                                                      NSString * _Nullable visitor,
                                                                      NSError * _Nullable error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *(^failure)(NSString *) = ^NSError *(NSString *message) {
            YTzoomDownloadLog(@"tv", @"video=%@ %@", videoID, message);
            return [NSError errorWithDomain:@"YTzoomTVClient" code:1
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
        };
        NSString *playerID = nil, *playerJS = nil;
        NSInteger timestamp = 0;
        if (!YTzoomTVPlayer(&playerID, &playerJS, &timestamp)) {
            completion(nil, nil, failure(@"player script unavailable"));
            return;
        }
        id response = nil;
        NSString *visitor = nil;
        NSString *reason = nil;
        for (NSInteger attempt = 0; attempt < 2 && response == nil; attempt++) {
            visitor = YTzoomTVVisitor(attempt > 0);
            NSMutableDictionary *body = [@{
                @"context": YTzoomTVContext(visitor), @"videoId": videoID,
                @"contentCheckOk": @YES, @"racyCheckOk": @YES} mutableCopy];
            if (timestamp != 0) {
                body[@"playbackContext"] = @{@"contentPlaybackContext": @{
                    @"html5Preference": @"HTML5_PREF_WANTS", @"signatureTimestamp": @(timestamp)}};
            }
            NSInteger status = 0;
            NSData *proto = YTzoomTVFetch(YTzoomTVRequest(@"player?alt=proto", body, visitor), &status);
            Class responseClass = NSClassFromString(@"YTIPlayerResponse");
            id parsed = responseClass && proto.length
                ? ((id (*)(id, SEL, id, NSError **))objc_msgSend)([responseClass alloc],
                    NSSelectorFromString(@"initWithData:error:"), proto, NULL) : nil;
            id streaming = [parsed valueForKey:@"streamingData"];
            NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
            if ([serverURL isKindOfClass:NSString.class] && serverURL.length != 0) {
                response = parsed;
            } else {
                id playability = [parsed valueForKey:@"playabilityStatus"];
                reason = [NSString stringWithFormat:@"no stream http=%ld reason=%@", (long)status,
                          [playability valueForKey:@"reason"] ?: @"none"];
            }
        }
        if (response == nil) {
            completion(nil, nil, failure(reason ?: @"no response"));
            return;
        }
        id streaming = [response valueForKey:@"streamingData"];
        NSString *serverURL = [streaming valueForKey:@"serverAbrStreamingURL"];
        NSString *solved = YTzoomSolveURLParameterN(playerID, playerJS, serverURL);
        if ([solved isEqualToString:serverURL] && [serverURL containsString:@"&n="]) {
            completion(nil, nil, failure(@"n challenge unsolved"));
            return;
        }
        [streaming setValue:solved forKey:@"serverAbrStreamingURL"];
        YTzoomDownloadLog(@"tv", @"video=%@ ready player=%@", videoID, playerID);
        completion(response, visitor, nil);
    });
}
