#import "SABRDownloader.h"
#import "DownloadLog.h"
#import "StreamResolver.h"
#import "DirectDownloader.h"
#import "../../Runtime/Preferences.h"
#import "../../YTzoom.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#ifndef YTzoom_COMBINED_SABR
#define YTzoom_COMBINED_SABR 0
#endif

static NSString *const YTzoomSABRErrorDomain = @"YTzoomSABR";
static NSData *YTzoomSABRPoToken;
static NSDictionary<NSString *, NSString *> *YTzoomSABRNativeHeaders;
static NSData *YTzoomSABRNativeBody;
static NSString *YTzoomSABRCurrentVideoID;
static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *YTzoomSABRHeadersByVideo;
static NSMutableDictionary<NSString *, NSData *> *YTzoomSABRBodiesByVideo;
static NSMutableDictionary<NSData *, NSDictionary<NSString *, NSString *> *> *YTzoomSABRHeadersByConfig;
static NSMutableDictionary<NSData *, NSData *> *YTzoomSABRBodiesByConfig;
static NSString *YTzoomPBFieldSummary(NSData *data);
static BOOL YTzoomSABRIsPlaybackBody(NSData *data);
static NSData *YTzoomPBDataField(NSData *data, NSUInteger wanted);

void YTzoomSABRSetCurrentVideoID(NSString *videoID) {
    if (videoID.length == 0) return;
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomSABRCurrentVideoID = [videoID copy];
    }
}

static NSURL *YTzoomSABRSeedURL(void) {
    NSURL *directory = YTzoomApplicationSupportDirectory();
    return [directory URLByAppendingPathComponent:@"sabr-seed.plist"];
}

static void YTzoomSABRPersistSeed(NSData *body, NSDictionary *headers) {
    static NSTimeInterval lastWrite;
    static BOOL wroteWithHeaders;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    BOOL upgrade = headers.count != 0 && !wroteWithHeaders;
    if (!upgrade && now - lastWrite < 30.0) return;
    if (headers.count != 0) wroteWithHeaders = YES;
    if (body.length == 0) {
        YTzoomDownloadLog(@"resolve", @"seed skip body=0");
        return;
    }
    lastWrite = now;
    NSDictionary *seed = headers.count != 0
        ? @{@"body": body, @"headers": headers} : @{@"body": body};
    NSError *error = nil;
    NSData *encoded = [NSPropertyListSerialization dataWithPropertyList:seed
        format:NSPropertyListBinaryFormat_v1_0 options:0 error:&error];
    NSURL *url = YTzoomSABRSeedURL();
    BOOL wrote = encoded.length != 0 &&
        [encoded writeToURL:url atomically:YES];
    YTzoomDownloadLog(@"resolve",
        @"seed write ok=%d bytes=%lu headers=%lu error=%@ path=%@",
        wrote, (unsigned long)encoded.length, (unsigned long)headers.count,
        error.localizedDescription ?: @"none", url.path);
}

void YTzoomSABRRestoreSeed(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomSABRNativeBody.length != 0) return;
    }
    NSData *encoded = [NSData dataWithContentsOfURL:YTzoomSABRSeedURL()];
    if (encoded.length == 0) return;
    NSDictionary *seed = [NSPropertyListSerialization
        propertyListWithData:encoded options:NSPropertyListImmutable
                      format:NULL error:NULL];
    NSData *body = seed[@"body"];
    NSDictionary *headers = seed[@"headers"];
    if (![body isKindOfClass:NSData.class]) return;
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomSABRNativeBody = [body copy];
        if ([headers isKindOfClass:NSDictionary.class] && headers.count != 0) {
            YTzoomSABRNativeHeaders = [headers copy];
        }
    }
    YTzoomDownloadLog(@"resolve", @"restored sabr seed body=%lu headers=%lu",
        (unsigned long)body.length, (unsigned long)headers.count);
}

NSString *YTzoomSABRCurrentVideoIDValue(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        return [YTzoomSABRCurrentVideoID copy];
    }
}

void YTzoomSABRSetNativeHeaders(NSDictionary<NSString *, NSString *> *headers) {
    if (headers.count == 0) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSData *body = nil;
        NSDictionary *current = nil;
        @synchronized (YTzoomSABRDownloader.class) {
            body = [YTzoomSABRNativeBody copy];
            current = [headers copy];
        }
        if (body.length != 0) YTzoomSABRPersistSeed(body, current);
    });
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomSABRNativeHeaders = [headers copy];
        if (YTzoomSABRCurrentVideoID.length != 0) {
            if (YTzoomSABRHeadersByVideo == nil) {
                YTzoomSABRHeadersByVideo = [NSMutableDictionary dictionary];
            }
            YTzoomSABRHeadersByVideo[YTzoomSABRCurrentVideoID] = [headers copy];
        }
    }
    NSMutableArray<NSString *> *summary = [NSMutableArray array];
    for (NSString *key in headers) {
        [summary addObject:[NSString stringWithFormat:@"%@:%lu", key,
            (unsigned long)[headers[key] length]]];
    }
}

static NSDictionary<NSString *, NSString *> *YTzoomSABRCurrentNativeHeaders(
    NSString *videoID, NSData *config) {
    @synchronized (YTzoomSABRDownloader.class) {
        NSDictionary *matched = config.length != 0
            ? YTzoomSABRHeadersByConfig[config] : nil;
        if (matched.count != 0) return [matched copy];
        NSDictionary *byVideo = videoID.length != 0
            ? YTzoomSABRHeadersByVideo[videoID] : nil;
        if (byVideo.count != 0) return [byVideo copy];
        return [YTzoomSABRNativeHeaders copy];
    }
}

void YTzoomSABRSetNativeRequest(NSURLRequest *request) {
    if (request == nil) return;
    BOOL usable = YTzoomSABRIsPlaybackBody(request.HTTPBody);
    if (!usable) {
        return;
    }
    YTzoomSABRSetNativeHeaders(request.allHTTPHeaderFields);
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomSABRNativeBody = [request.HTTPBody copy];
        if (YTzoomSABRCurrentVideoID.length != 0 && request.HTTPBody.length != 0) {
            if (YTzoomSABRBodiesByVideo == nil) {
                YTzoomSABRBodiesByVideo = [NSMutableDictionary dictionary];
            }
            YTzoomSABRBodiesByVideo[YTzoomSABRCurrentVideoID] = [request.HTTPBody copy];
        }
        NSData *config = YTzoomPBDataField(request.HTTPBody, 5);
        NSData *seedBody = [request.HTTPBody copy];
        NSDictionary *seedHeaders = [YTzoomSABRNativeHeaders copy];
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTzoomSABRPersistSeed(seedBody, seedHeaders);
        });
        if (config.length != 0) {
            if (YTzoomSABRBodiesByConfig == nil) {
                YTzoomSABRBodiesByConfig = [NSMutableDictionary dictionary];
                YTzoomSABRHeadersByConfig = [NSMutableDictionary dictionary];
            }
            if (YTzoomSABRBodiesByConfig.count >= 32) {
                [YTzoomSABRBodiesByConfig removeAllObjects];
                [YTzoomSABRHeadersByConfig removeAllObjects];
            }
            YTzoomSABRBodiesByConfig[config] = [request.HTTPBody copy];
            YTzoomSABRHeadersByConfig[config] = [request.allHTTPHeaderFields copy];
        }
    }
}

static BOOL YTzoomSABRHasExactNativeBody(NSString *videoID, NSData *config) {
    @synchronized (YTzoomSABRDownloader.class) {
        if (config.length != 0 && YTzoomSABRBodiesByConfig[config].length != 0) {
            return YES;
        }
        if (videoID.length != 0 && YTzoomSABRBodiesByVideo[videoID].length != 0) {
            return YES;
        }
        return NO;
    }
}

static NSData *YTzoomSABRCurrentNativeBody(NSString *videoID, NSData *config) {
    @synchronized (YTzoomSABRDownloader.class) {
        NSData *matched = config.length != 0 ? YTzoomSABRBodiesByConfig[config] : nil;
        if (matched.length != 0) return [matched copy];
        NSData *byVideo = videoID.length != 0 ? YTzoomSABRBodiesByVideo[videoID] : nil;
        if (byVideo.length != 0) return [byVideo copy];
        return [YTzoomSABRNativeBody copy];
    }
}

static NSData *YTzoomSABRDecodeTokenString(NSString *value) {
    if (value.length == 0) return nil;
    NSString *decoded = [value stringByRemovingPercentEncoding] ?: value;
    NSMutableString *base64 = [decoded mutableCopy];
    [base64 replaceOccurrencesOfString:@"-" withString:@"+"
        options:0 range:NSMakeRange(0, base64.length)];
    [base64 replaceOccurrencesOfString:@"_" withString:@"/"
        options:0 range:NSMakeRange(0, base64.length)];
    while (base64.length % 4 != 0) [base64 appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:base64 options:0];
}

void YTzoomSABRSetPoToken(id token) {
    NSData *data = nil;
    if ([token isKindOfClass:NSData.class]) {
        data = token;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (text.length != 0) {
            NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=%"] invertedSet];
            if ([text rangeOfCharacterFromSet:invalid].location == NSNotFound) {
                NSData *decoded = YTzoomSABRDecodeTokenString(text);
                if (decoded.length != 0) {
                    data = decoded;
                }
            }
        }
    } else if ([token isKindOfClass:NSString.class]) {
        data = YTzoomSABRDecodeTokenString(token);
    } else if ([token respondsToSelector:NSSelectorFromString(@"poToken")]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(token, NSSelectorFromString(@"poToken"));
        if (value != token) YTzoomSABRSetPoToken(value);
        return;
    }
    if (data.length == 0) return;
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomSABRPoToken = [data copy];
    }
}

NSUInteger YTzoomSABRPoTokenLength(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        return YTzoomSABRPoToken.length;
    }
}

NSString *YTzoomSABRPoTokenString(void) {
    NSData *token = nil;
    @synchronized (YTzoomSABRDownloader.class) {
        token = [YTzoomSABRPoToken copy];
    }
    if (token.length == 0) return nil;
    NSMutableString *text = [[token base64EncodedStringWithOptions:0] mutableCopy];
    [text replaceOccurrencesOfString:@"+" withString:@"-"
                             options:0 range:NSMakeRange(0, text.length)];
    [text replaceOccurrencesOfString:@"/" withString:@"_"
                             options:0 range:NSMakeRange(0, text.length)];
    while ([text hasSuffix:@"="]) {
        [text deleteCharactersInRange:NSMakeRange(text.length - 1, 1)];
    }
    return text;
}

static NSData *YTzoomSABRCurrentPoToken(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        return [YTzoomSABRPoToken copy];
    }
}

static id YTzoomSABRObject(id receiver, NSArray<NSString *> *names) {
    for (NSString *name in names) {
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

static id YTzoomSABRFindPlayerData(id object,
                                   NSHashTable *visited,
                                   NSUInteger depth) {
    if (object == nil || depth > 8 || [visited containsObject:object]) return nil;
    [visited addObject:object];
    if (YTzoomSABRObject(object, @[@"streamingData"]) != nil) return object;
    for (NSString *name in @[@"playerData", @"playerResponse", @"playbackData",
                              @"contentPlaybackData", @"contentPlayerResponse",
                              @"response", @"video", @"shortsPlayerData"]) {
        id nested = YTzoomSABRObject(object, @[name]);
        id found = YTzoomSABRFindPlayerData(nested, visited, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

static id YTzoomSABRPlayerData(id response) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return YTzoomSABRFindPlayerData(response, visited, 0) ?: response;
}

static void YTzoomPBVarint(NSMutableData *data, uint64_t value) {
    while (value >= 0x80) {
        uint8_t byte = (uint8_t)(value | 0x80);
        [data appendBytes:&byte length:1];
        value >>= 7;
    }
    uint8_t byte = (uint8_t)value;
    [data appendBytes:&byte length:1];
}

static void YTzoomPBKey(NSMutableData *data, NSUInteger field, uint8_t wire) {
    YTzoomPBVarint(data, ((uint64_t)field << 3) | wire);
}

static void YTzoomPBInteger(NSMutableData *data, NSUInteger field, uint64_t value) {
    YTzoomPBKey(data, field, 0);
    YTzoomPBVarint(data, value);
}

static void YTzoomPBBytes(NSMutableData *data, NSUInteger field, NSData *value) {
    if (value.length == 0) {
        return;
    }
    YTzoomPBKey(data, field, 2);
    YTzoomPBVarint(data, value.length);
    [data appendData:value];
}

static void YTzoomPBString(NSMutableData *data, NSUInteger field, NSString *value) {
    YTzoomPBBytes(data, field, [value dataUsingEncoding:NSUTF8StringEncoding]);
}

static void YTzoomPBFloat(NSMutableData *data, NSUInteger field, float value) {
    YTzoomPBKey(data, field, 5);
    [data appendBytes:&value length:sizeof(value)];
}

static BOOL YTzoomPBReadVarint(NSData *data, NSUInteger *offset, uint64_t *value) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint64_t result = 0;
    NSUInteger shift = 0;
    while (*offset < data.length && shift < 70) {
        uint8_t byte = bytes[(*offset)++];
        result |= ((uint64_t)(byte & 0x7f)) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
        shift += 7;
    }
    return NO;
}

static BOOL YTzoomPBSkip(NSData *data, NSUInteger *offset, uint8_t wire) {
    if (wire == 0) {
        uint64_t value = 0;
        return YTzoomPBReadVarint(data, offset, &value);
    }
    if (wire == 1) {
        if (*offset + 8 > data.length) return NO;
        *offset += 8;
        return YES;
    }
    if (wire == 2) {
        uint64_t length = 0;
        if (!YTzoomPBReadVarint(data, offset, &length) || *offset + length > data.length) {
            return NO;
        }
        *offset += (NSUInteger)length;
        return YES;
    }
    if (wire == 5) {
        if (*offset + 4 > data.length) return NO;
        *offset += 4;
        return YES;
    }
    return NO;
}

static uint64_t YTzoomPBIntegerField(NSData *data, NSUInteger wanted, uint64_t fallback) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        uint64_t key = 0;
        if (!YTzoomPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (field == wanted && wire == 0) {
            uint64_t value = 0;
            return YTzoomPBReadVarint(data, &offset, &value) ? value : fallback;
        }
        if (!YTzoomPBSkip(data, &offset, wire)) break;
    }
    return fallback;
}

static NSData *YTzoomPBDataField(NSData *data, NSUInteger wanted) {
    NSUInteger offset = 0;
    while (offset < data.length) {
        uint64_t key = 0;
        if (!YTzoomPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (wire == 2) {
            uint64_t length = 0;
            if (!YTzoomPBReadVarint(data, &offset, &length) || offset + length > data.length) {
                break;
            }
            NSData *value = [data subdataWithRange:NSMakeRange(offset, (NSUInteger)length)];
            if (field == wanted) {
                return value;
            }
            offset += (NSUInteger)length;
            continue;
        }
        if (!YTzoomPBSkip(data, &offset, wire)) break;
    }
    return nil;
}

static BOOL YTzoomSABRIsPlaybackBody(NSData *data) {
    return YTzoomPBDataField(data, 1).length != 0 &&
        YTzoomPBDataField(data, 5).length != 0 &&
        YTzoomPBDataField(data, 19).length != 0;
}

static NSString *YTzoomPBFieldSummary(NSData *data) {
    if (data.length == 0) return @"empty";
    NSMutableArray<NSString *> *fields = [NSMutableArray array];
    NSUInteger offset = 0;
    while (offset < data.length && fields.count < 40) {
        uint64_t key = 0;
        if (!YTzoomPBReadVarint(data, &offset, &key)) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        uint8_t wire = (uint8_t)(key & 7);
        if (wire == 2) {
            uint64_t length = 0;
            if (!YTzoomPBReadVarint(data, &offset, &length) || offset + length > data.length) break;
            [fields addObject:[NSString stringWithFormat:@"%lu:%llu",
                (unsigned long)field, length]];
            offset += (NSUInteger)length;
        } else {
            [fields addObject:[NSString stringWithFormat:@"%lu/w%u",
                (unsigned long)field, wire]];
            if (!YTzoomPBSkip(data, &offset, wire)) break;
        }
    }
    return fields.count != 0 ? [fields componentsJoinedByString:@","] : @"unparsed";
}

static NSString *YTzoomPBStringField(NSData *data, NSUInteger field) {
    NSData *value = YTzoomPBDataField(data, field);
    return value != nil ? [[NSString alloc] initWithData:value encoding:NSUTF8StringEncoding] : nil;
}

static NSString *YTzoomSABRHex(NSData *data, NSUInteger limit) {
    if (data.length == 0) return @"";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger length = MIN(data.length, limit);
    NSMutableString *result = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger index = 0; index < length; index++) {
        [result appendFormat:@"%02x", bytes[index]];
    }
    return result;
}

static BOOL YTzoomUMPValue(NSData *data, NSUInteger *offset, uint32_t *result) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    if (*offset >= data.length) return NO;
    uint8_t first = bytes[*offset];
    NSUInteger count = first < 128 ? 1 : first < 192 ? 2 : first < 224 ? 3 : first < 240 ? 4 : 5;
    if (*offset + count > data.length) return NO;
    uint32_t value = 0;
    if (count == 1) {
        value = first;
    } else if (count == 2) {
        value = (first & 0x3f) + 64u * bytes[*offset + 1];
    } else if (count == 3) {
        value = (first & 0x1f) + 32u * (bytes[*offset + 1] + 256u * bytes[*offset + 2]);
    } else if (count == 4) {
        value = (first & 0x0f) + 16u * (bytes[*offset + 1] +
            256u * (bytes[*offset + 2] + 256u * bytes[*offset + 3]));
    } else {
        memcpy(&value, bytes + *offset + 1, sizeof(value));
    }
    *offset += count;
    *result = value;
    return YES;
}

static NSData *YTzoomSABRFormatID(YTzoomStreamOption *option) {
    NSMutableData *data = [NSMutableData data];
    YTzoomPBInteger(data, 1, (uint64_t)option.itag);
    if (option.lastModified > 0) {
        YTzoomPBInteger(data, 2, (uint64_t)option.lastModified);
    }
    if (option.xtags.length != 0) {
        YTzoomPBString(data, 3, option.xtags);
    } else {
        YTzoomPBKey(data, 3, 2);
        YTzoomPBVarint(data, 0);
    }
    return data;
}

static NSMutableDictionary<NSString *, NSDictionary *> *YTzoomSABRStandalone;

void YTzoomSABRSetStandaloneClient(NSString *identifier, NSData *clientInfo,
                                   NSDictionary<NSString *, NSString *> *headers) {
    if (identifier.length == 0) return;
    @synchronized (NSStringFromClass(YTzoomSABRDownloader.class)) {
        if (YTzoomSABRStandalone == nil) YTzoomSABRStandalone = [NSMutableDictionary dictionary];
        if (clientInfo == nil) [YTzoomSABRStandalone removeObjectForKey:identifier];
        else YTzoomSABRStandalone[identifier] = @{@"client": clientInfo, @"headers": headers ?: @{}};
    }
}

static NSDictionary *YTzoomSABRStandaloneFor(NSString *identifier) {
    if (identifier.length == 0) return nil;
    @synchronized (NSStringFromClass(YTzoomSABRDownloader.class)) {
        return YTzoomSABRStandalone[identifier];
    }
}

static NSData *YTzoomSABRClientInfo(void) {
    NSMutableData *data = [NSMutableData data];
    UIDevice *device = UIDevice.currentDevice;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *version = info[@"CFBundleShortVersionString"] ?: @"21.28.3";
    NSString *language = NSLocale.preferredLanguages.firstObject ?: @"en-US";
    NSString *region = NSLocale.currentLocale.countryCode ?: @"US";
    CGSize points = UIScreen.mainScreen.bounds.size;
    YTzoomPBString(data, 12, @"Apple");
    YTzoomPBString(data, 13, device.model ?: @"iOS");
    YTzoomPBInteger(data, 16, 5);
    YTzoomPBString(data, 17, version);
    YTzoomPBString(data, 18, @"IOS");
    YTzoomPBString(data, 19, device.systemVersion ?: @"16.0");
    YTzoomPBString(data, 21, language);
    YTzoomPBString(data, 22, region);
    YTzoomPBInteger(data, 37, (uint64_t)llround(points.width));
    YTzoomPBInteger(data, 38, (uint64_t)llround(points.height));
    YTzoomPBInteger(data, 41, (uint64_t)llround(UIScreen.mainScreen.scale));
    YTzoomPBInteger(data, 46, device.userInterfaceIdiom == UIUserInterfaceIdiomPad ? 2 : 1);
    YTzoomPBString(data, 80, NSTimeZone.localTimeZone.name ?: @"UTC");
    return data;
}

@interface YTzoomSABRHeader : NSObject
@property(nonatomic, assign) NSInteger headerID;
@property(nonatomic, assign) NSInteger itag;
@property(nonatomic, copy) NSString *xtags;
@property(nonatomic, assign) BOOL initialization;
@property(nonatomic, assign) NSInteger sequence;
@property(nonatomic, assign) int64_t startTime;
@property(nonatomic, assign) int64_t duration;
@property(nonatomic, assign) int64_t contentLength;
@property(nonatomic, strong) NSMutableData *data;
@end

@implementation YTzoomSABRHeader
@end

@interface YTzoomSABRTrack : NSObject
@property(nonatomic, strong) YTzoomStreamOption *option;
@property(nonatomic, strong) NSURL *URL;
@property(nonatomic, strong) NSFileHandle *handle;
@property(nonatomic, strong) NSMutableSet<NSString *> *segments;
@property(nonatomic, assign) BOOL initialized;
@property(nonatomic, assign) BOOL initializationWritten;
@property(nonatomic, assign) NSInteger endSequence;
@property(nonatomic, assign) NSInteger lastSequence;
@property(nonatomic, assign) int64_t endTime;
@property(nonatomic, assign) int64_t downloadedDuration;
@property(nonatomic, assign) int64_t downloadedBytes;
@property(nonatomic, assign) BOOL hasRound;
@property(nonatomic, assign) int64_t roundStart;
@property(nonatomic, assign) int64_t roundDuration;
@property(nonatomic, assign) NSInteger roundStartSequence;
@property(nonatomic, assign) NSInteger roundEndSequence;
@end

@implementation YTzoomSABRTrack
@end

@interface YTzoomSABRSession : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) id playerResponse;
@property(nonatomic, strong) id streamingData;
@property(nonatomic, strong) NSData *ustreamerConfig;
@property(nonatomic, copy) NSString *serverURL;
@property(nonatomic, strong) YTzoomSABRTrack *video;
@property(nonatomic, strong) YTzoomSABRTrack *audio;
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YTzoomSABRHeader *> *headers;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSData *> *contexts;
@property(nonatomic, strong, nullable) NSData *playbackCookie;
@property(nonatomic, assign) NSInteger requestNumber;
@property(nonatomic, assign) NSInteger stalledRequests;
@property(nonatomic, assign) NSInteger backoffMilliseconds;
@property(nonatomic, copy, nullable) YTzoomSABRProgress progress;
@property(nonatomic, copy) YTzoomSABRCompletion completion;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, assign) NSInteger retryCount;
@property(nonatomic, assign) NSInteger attestationRetries;
@property(nonatomic, assign) NSInteger reloadCount;
@property(nonatomic, assign) BOOL reloadInFlight;
@property(nonatomic, assign) BOOL audioOnly;
@property(nonatomic, assign) BOOL combinedMode;
@property(nonatomic, assign) NSInteger mediaPhase;
@property(nonatomic, assign) NSInteger preparationAttempts;
@property(nonatomic, assign) BOOL preparationInFlight;
@property(nonatomic, assign) NSTimeInterval lastPreparationRequest;
@property(nonatomic, assign) NSInteger audioStalledRequests;
@property(nonatomic, assign) NSInteger videoStalledRequests;
@property(nonatomic, assign) NSInteger stallRecoveryCount;
@property(nonatomic, assign) BOOL sequentialFallback;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, strong) NSMutableData *activeResponseData;
@property(nonatomic, strong, nullable) NSHTTPURLResponse *activeResponse;
@property(nonatomic, assign) NSInteger activeRequestNumber;
@property(nonatomic, assign) NSTimeInterval activeRequestStart;
@property(nonatomic, assign) NSTimeInterval lastLiveProgress;
@property(nonatomic, assign) int64_t activeBaseAudioBytes;
@property(nonatomic, assign) int64_t activeBaseVideoBytes;
@property(nonatomic, assign) int64_t activeNetworkBytes;
@property(nonatomic, assign) BOOL requestBuildInFlight;
@property(nonatomic, assign) BOOL nativeRefreshInFlight;
@property(nonatomic, assign) NSInteger nativeRefreshAttempts;
@property(nonatomic, assign) NSInteger authRecoveryStep;
@property(nonatomic, assign) BOOL authRecoveryInFlight;
@property(nonatomic, assign) BOOL usingTVClient;
@property(nonatomic, assign) BOOL triedTVClient;
@property(nonatomic, assign) NSInteger tvRefreshCount;
@property(nonatomic, assign) NSInteger nativeBuildFailures;
- (void)start;
- (void)cancel;
- (void)sendPreparedRequest:(NSURLRequest * _Nullable)nativeRequest
        nativeRequestNumber:(NSInteger)nativeRequestNumber;
- (void)refreshNativeSession:(NSString *)reason;
- (void)recoverAuthorization:(NSError *)error;
- (void)switchToTVClient:(NSString *)reason then:(void (^)(BOOL switched))next;
- (void)refreshTVClient:(NSString *)reason then:(void (^)(BOOL refreshed))next;
- (BOOL)restartStalledSession:(NSString *)reason;
- (BOOL)switchToSequentialFallback:(NSString *)reason;
@end

@implementation YTzoomSABRSession

- (NSError *)error:(NSString *)message code:(NSInteger)code {
    return [NSError errorWithDomain:YTzoomSABRErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"SABR failed"}];
}

- (YTzoomSABRTrack *)trackForItag:(NSInteger)itag xtags:(NSString *)xtags {
    if (self.video.option.itag == itag &&
        (xtags.length == 0 || self.video.option.xtags.length == 0 ||
         [self.video.option.xtags isEqualToString:xtags])) {
        return self.video;
    }
    if (self.audio.option.itag == itag &&
        (xtags.length == 0 || self.audio.option.xtags.length == 0 ||
         [self.audio.option.xtags isEqualToString:xtags])) {
        return self.audio;
    }
    return nil;
}

- (YTzoomSABRTrack *)makeTrack:(YTzoomStreamOption *)option
                           name:(NSString *)name
                      directory:(NSURL *)directory
                         error:(NSError **)error {
    YTzoomSABRTrack *track = [YTzoomSABRTrack new];
    track.option = option;
    track.segments = [NSMutableSet set];
    track.endSequence = NSIntegerMax;
    track.lastSequence = -1;
    track.roundStartSequence = NSIntegerMax;
    NSString *extension = [option.mimeType containsString:@"webm"] ? @"webm" :
        ([option.mimeType hasPrefix:@"audio/"] ? @"m4a" : @"mp4");
    track.URL = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", name, extension]];
    [NSFileManager.defaultManager createFileAtPath:track.URL.path contents:nil attributes:nil];
    track.handle = [NSFileHandle fileHandleForWritingToURL:track.URL error:error];
    return track;
}

- (BOOL)applyPlayerResponse:(id)response error:(NSError **)error {
    id playerData = YTzoomSABRPlayerData(response);
    id streamingData = YTzoomSABRObject(playerData, @[@"streamingData"]);
    id playerConfig = YTzoomSABRObject(playerData, @[@"playerConfig"]);
    id common = YTzoomSABRObject(playerConfig, @[@"mediaCommonConfig"]);
    id requestConfig = YTzoomSABRObject(common, @[@"mediaUstreamerRequestConfig"]);
    NSData *ustreamerConfig = YTzoomSABRObject(requestConfig,
        @[@"videoPlaybackUstreamerConfig"]);
    NSString *serverURL = YTzoomSABRObject(streamingData, @[@"serverAbrStreamingURL"]);
    if (![ustreamerConfig isKindOfClass:NSData.class] || ustreamerConfig.length == 0 ||
        ![serverURL isKindOfClass:NSString.class] || serverURL.length == 0) {
        if (error != NULL) *error = [self error:@"YouTube did not provide SABR session data." code:1];
        return NO;
    }
    self.playerResponse = response;
    self.streamingData = streamingData;
    self.ustreamerConfig = ustreamerConfig;
    self.serverURL = serverURL;
    NSArray<YTzoomStreamOption *> *options =
        [YTzoomStreamResolver optionsFromPlayerResponse:playerData];
    for (YTzoomStreamOption *option in options) {
        YTzoomSABRTrack *track = [self trackForItag:option.itag xtags:option.xtags];
        if (track == nil) continue;
        YTzoomDownloadLog(self.identifier,
            @"refreshed itag=%ld lmt=%ld->%ld xtags=%@->%@",
            (long)option.itag, (long)track.option.lastModified,
            (long)option.lastModified, track.option.xtags, option.xtags);
        track.option.lastModified = option.lastModified;
        track.option.xtags = option.xtags ?: @"";
        track.option.rawFormat = option.rawFormat;
    }
    return YES;
}

NSUInteger YTzoomPurgeDownloadScratch(BOOL includeActive) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
        includingPropertiesForKeys:@[NSURLContentModificationDateKey,
                                     NSURLTotalFileAllocatedSizeKey,
                                     NSURLIsDirectoryKey]
                           options:0 error:nil];
    NSUInteger freed = 0;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-600.0];
    for (NSURL *entry in entries) {
        NSString *name = entry.lastPathComponent;
        BOOL scratch = [name hasPrefix:@"YTzoom-"];
        BOOL dump = [name hasPrefix:@"ytzoom-"] && [name hasSuffix:@".pb"];
        if (!scratch && !dump) continue;
        if (!includeActive) {
            NSDate *modified = nil;
            [entry getResourceValue:&modified forKey:NSURLContentModificationDateKey
                              error:nil];
            if (modified != nil && [modified compare:cutoff] == NSOrderedDescending) {
                continue;
            }
        }
        NSNumber *size = nil;
        [entry getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey error:nil];
        NSDirectoryEnumerator *walker = [manager enumeratorAtURL:entry
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 errorHandler:nil];
        NSUInteger nested = 0;
        for (NSURL *child in walker) {
            NSNumber *childSize = nil;
            [child getResourceValue:&childSize forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            nested += childSize.unsignedIntegerValue;
        }
        if ([manager removeItemAtURL:entry error:nil]) {
            freed += nested + size.unsignedIntegerValue;
        }
    }
    if (freed != 0) {
        YTzoomDownloadLog(@"cache", @"purged scratch bytes=%lu",
            (unsigned long)freed);
    }
    return freed;
}

- (BOOL)prepare:(NSError **)error {
    if (![self applyPlayerResponse:self.playerResponse error:error]) return NO;
    NSURL *directory = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
    directory = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTzoom-%@", NSUUID.UUID.UUIDString]
        isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    self.video = [self makeTrack:self.video.option name:@"video" directory:directory error:error];
    if (self.video.handle == nil) return NO;
    self.audio = [self makeTrack:self.audio.option name:@"audio" directory:directory error:error];
    return self.audio.handle != nil;
}

- (NSData *)bufferedRangeForTrack:(YTzoomSABRTrack *)track {
    if (!track.hasRound || track.roundDuration <= 0) {
        return nil;
    }
    NSMutableData *timeRange = [NSMutableData data];
    YTzoomPBInteger(timeRange, 1, (uint64_t)MAX(track.roundStart, 0));
    YTzoomPBInteger(timeRange, 2, (uint64_t)track.roundDuration);
    YTzoomPBInteger(timeRange, 3, 1000);
    NSMutableData *range = [NSMutableData data];
    YTzoomPBBytes(range, 1, YTzoomSABRFormatID(track.option));
    YTzoomPBInteger(range, 2, (uint64_t)MAX(track.roundStart, 0));
    YTzoomPBInteger(range, 3, (uint64_t)track.roundDuration);
    YTzoomPBInteger(range, 4, (uint64_t)MAX(track.roundStartSequence, 0));
    YTzoomPBInteger(range, 5, (uint64_t)MAX(track.roundEndSequence, 0));
    YTzoomPBBytes(range, 6, timeRange);
    return range;
}

- (void)clearRound:(YTzoomSABRTrack *)track {
    track.hasRound = NO;
    track.roundStart = 0;
    track.roundDuration = 0;
    track.roundStartSequence = NSIntegerMax;
    track.roundEndSequence = 0;
}

- (NSData *)requestBody {
    BOOL formatsInitialized = self.video.initialized || self.audio.initialized;
    if (formatsInitialized && self.mediaPhase == 0) {
        self.mediaPhase = self.combinedMode ? 3 : 1;
    }
    NSInteger trackMode = self.combinedMode ? 0 : (self.mediaPhase == 2 ? 2 :
        ((self.mediaPhase == 1 || self.audioOnly) ? 1 : 0));
    int64_t playerTime = (self.mediaPhase == 2 || self.combinedMode)
        ? self.video.downloadedDuration : self.audio.downloadedDuration;
    NSInteger resolution = MAX(self.video.option.height, 360);
    NSDictionary *standalone = YTzoomSABRStandaloneFor(self.identifier);
    NSData *nativeBody = standalone ? nil
        : YTzoomSABRCurrentNativeBody(self.videoID, self.ustreamerConfig);
    NSData *nativeState = !standalone && YTzoomSABRHasExactNativeBody(self.videoID,
                                                       self.ustreamerConfig)
        ? YTzoomPBDataField(nativeBody, 1) : nil;
    NSMutableData *state = [NSMutableData data];
    if (nativeState.length != 0) {
        [state appendData:nativeState];
        YTzoomPBInteger(state, 16, (uint64_t)resolution);
        YTzoomPBInteger(state, 28, (uint64_t)MAX(playerTime, 0));
        YTzoomPBInteger(state, 40, (uint64_t)trackMode);
    } else {
        YTzoomPBInteger(state, 16, (uint64_t)resolution);
        YTzoomPBInteger(state, 21, (uint64_t)resolution);
        YTzoomPBInteger(state, 22, 0);
        YTzoomPBInteger(state, 28, (uint64_t)MAX(playerTime, 0));
        YTzoomPBInteger(state, 34, 1);
        YTzoomPBFloat(state, 35, 1.0f);
        YTzoomPBInteger(state, 40, (uint64_t)trackMode);
        YTzoomPBInteger(state, 46, 0);
    }
    if (self.audio.option.audioTrackID.length != 0) {
        YTzoomPBString(state, 69, self.audio.option.audioTrackID);
    }

    NSData *nativeContext = YTzoomPBDataField(nativeBody, 19);
    NSMutableData *context = [NSMutableData data];
    if (nativeContext.length != 0) {
        [context appendData:nativeContext];
    } else {
        YTzoomPBBytes(context, 1, standalone ? standalone[@"client"] : YTzoomSABRClientInfo());
        NSData *poToken = standalone ? nil : YTzoomSABRCurrentPoToken();
        if (poToken.length != 0) {
            YTzoomPBBytes(context, 2, poToken);
        }
    }
    if (self.playbackCookie.length != 0) {
        YTzoomPBBytes(context, 3, self.playbackCookie);
    }
    for (NSNumber *type in self.contexts) {
        NSMutableData *item = [NSMutableData data];
        YTzoomPBInteger(item, 1, type.unsignedIntegerValue);
        YTzoomPBBytes(item, 2, self.contexts[type]);
        YTzoomPBBytes(context, 5, item);
    }

    NSMutableData *request = [NSMutableData data];
    YTzoomPBBytes(request, 1, state);
    NSData *videoID = YTzoomSABRFormatID(self.video.option);
    NSData *audioID = YTzoomSABRFormatID(self.audio.option);
    if (formatsInitialized) {
        if (self.combinedMode) {
            YTzoomPBBytes(request, 2, videoID);
            YTzoomPBBytes(request, 2, audioID);
        } else if (self.mediaPhase == 1) {
            YTzoomPBBytes(request, 2, audioID);
        } else {
            YTzoomPBBytes(request, 2, videoID);
        }
    }
    NSData *videoRange = [self bufferedRangeForTrack:self.video];
    NSData *audioRange = [self bufferedRangeForTrack:self.audio];
    if (videoRange != nil) YTzoomPBBytes(request, 3, videoRange);
    if (audioRange != nil) YTzoomPBBytes(request, 3, audioRange);
    YTzoomPBBytes(request, 5, self.ustreamerConfig);
    YTzoomPBBytes(request, 16, audioID);
    YTzoomPBBytes(request, 17, videoID);
    YTzoomPBBytes(request, 19, context);
    [self clearRound:self.video];
    [self clearRound:self.audio];
    if (self.requestNumber == 0) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytzoom-outgoing.pb"];
        [request writeToFile:path atomically:YES];
        YTzoomDownloadLog(self.identifier, @"request fields native=%lu outgoing=%lu summary=%@ dump=%@",
            (unsigned long)nativeBody.length, (unsigned long)request.length,
            YTzoomPBFieldSummary(request), path);
    }
    return request;
}

- (NSURL *)requestURLForBaseURL:(NSURL *)baseURL
                  requestNumber:(NSInteger)requestNumber {
    NSURLComponents *components = [NSURLComponents componentsWithURL:baseURL
        resolvingAgainstBaseURL:NO];
    NSMutableArray *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems ?: @[]) {
        if (![item.name isEqualToString:@"rn"]) [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"rn"
        value:[NSString stringWithFormat:@"%ld", (long)requestNumber]]];
    components.queryItems = items;
    return components.URL;
}

- (void)start {
    if (self.finished) return;
    if (!self.triedTVClient && YTzoomTVDownloadsEnabled()) {
        __weak YTzoomSABRSession *weakSelf = self;
        [self switchToTVClient:@"preference" then:^(__unused BOOL switched) {
            [weakSelf start];
        }];
        return;
    }
    if (self.ustreamerConfig.length == 0) {
        NSError *responseError = nil;
        if (![self applyPlayerResponse:self.playerResponse error:&responseError]) {
            [self fail:responseError ?: [self error:@"SABR setup failed." code:2]];
            return;
        }
    }
    if (!self.usingTVClient &&
        YTzoomSABRCurrentNativeBody(self.videoID, self.ustreamerConfig).length == 0) {
        if (self.preparationAttempts == 0) {
            YTzoomDownloadLog(self.identifier, @"waiting native video=%@", self.videoID);
        }
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (!self.preparationInFlight &&
            (self.lastPreparationRequest == 0.0 ||
             now - self.lastPreparationRequest >= 2.0)) {
            self.preparationInFlight = YES;
            self.lastPreparationRequest = now;
            __weak YTzoomSABRSession *weakSelf = self;
            YTzoomPreparePlayer(self.videoID, ^(id playerResponse, NSError *prepareError) {
                YTzoomSABRSession *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf.finished) return;
                strongSelf.preparationInFlight = NO;
                if (playerResponse != nil) {
                    NSError *applyError = nil;
                    [strongSelf applyPlayerResponse:playerResponse error:&applyError];
                }
                YTzoomDownloadLog(strongSelf.identifier,
                    @"prepare result=%@ error=%@",
                    playerResponse != nil ? @"response" : @"none",
                    prepareError.localizedDescription ?: @"none");
                dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf start]; });
            });
        }
        self.preparationAttempts += 1;
        if (self.preparationAttempts > 300) {
            [self fail:[self error:
                @"YouTube could not prepare this video automatically. Play it briefly and retry."
                code:10]];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{ [self start]; });
        return;
    }
    YTzoomDownloadLog(self.identifier, @"native ready video=%@ wait=%ld",
        self.videoID, (long)self.preparationAttempts);
    NSError *error = nil;
    if (![self prepare:&error]) {
        [self fail:error ?: [self error:@"SABR setup failed." code:2]];
        return;
    }
    self.headers = [NSMutableDictionary dictionary];
    self.contexts = [NSMutableDictionary dictionary];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 60.0;
    configuration.timeoutIntervalForResource = 3600.0;
    configuration.waitsForConnectivity = YES;
    configuration.allowsCellularAccess = YES;
    configuration.allowsExpensiveNetworkAccess = YES;
    configuration.allowsConstrainedNetworkAccess = YES;
    configuration.networkServiceType = (NSURLRequestNetworkServiceType)8;
    configuration.HTTPMaximumConnectionsPerHost = 4;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    queue.qualityOfService = NSQualityOfServiceUtility;
    self.session = [NSURLSession sessionWithConfiguration:configuration
        delegate:self delegateQueue:queue];
    NSString *serverHost = [NSURL URLWithString:self.serverURL].host ?: @"unknown";
    YTzoomDownloadLog(self.identifier,
        @"SABR start video=%ld audio=%ld server=%@ mode=%@ connections=%ld native=%d",
        (long)self.video.option.itag, (long)self.audio.option.itag, serverHost,
        self.combinedMode ? @"combined" : @"sequential", 4L,
        YTzoomHasNativeOnesieSession(self.videoID));
    YTzoomDownloadLog(self.identifier,
        @"formats video=%ld lmt=%ld xtags=%@ quality=%@ mime=%@ audio=%ld lmt=%ld xtags=%@",
        (long)self.video.option.itag, (long)self.video.option.lastModified,
        self.video.option.xtags, self.video.option.qualityLabel, self.video.option.mimeType,
        (long)self.audio.option.itag, (long)self.audio.option.lastModified,
        self.audio.option.xtags);
    YTzoomDownloadLog(self.identifier, @"PoToken bytes=%lu",
        (unsigned long)YTzoomSABRCurrentPoToken().length);
    [self sendRequest];
}

- (void)sendRequest {
    if (self.finished || self.requestBuildInFlight) return;
    if (self.requestNumber > 10000) {
        [self fail:[self error:@"The SABR stream did not finish." code:3]];
        return;
    }
    [self sendPreparedRequest:nil nativeRequestNumber:self.requestNumber];
}

- (void)sendPreparedRequest:(NSURLRequest *)nativeRequest
        nativeRequestNumber:(NSInteger)nativeRequestNumber {
    if (self.finished) return;
    (void)nativeRequest;
    (void)nativeRequestNumber;
    NSInteger logicalRequestNumber = self.requestNumber;
    NSInteger wireRequestNumber = logicalRequestNumber;
    NSURL *baseURL = [NSURL URLWithString:self.serverURL];
    if (baseURL == nil) {
        [self fail:[self error:@"SABR setup did not provide a request URL." code:2]];
        return;
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:baseURL];
    request.URL = [self requestURLForBaseURL:baseURL
        requestNumber:wireRequestNumber];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [self requestBody];
    NSDictionary *standalone = YTzoomSABRStandaloneFor(self.identifier);
    NSDictionary<NSString *, NSString *> *nativeHeaders = standalone
        ? standalone[@"headers"]
        : YTzoomSABRCurrentNativeHeaders(self.videoID, self.ustreamerConfig);
    for (NSString *key in nativeHeaders) {
        NSString *lower = key.lowercaseString;
        if ([lower isEqualToString:@"host"] ||
            [lower isEqualToString:@"content-length"] ||
            [lower isEqualToString:@"content-encoding"] ||
            [lower isEqualToString:@"content-type"] ||
            [lower isEqualToString:@"accept"] ||
            [lower isEqualToString:@"accept-encoding"]) continue;
        [request setValue:nativeHeaders[key] forHTTPHeaderField:key];
    }
    [request setValue:nil forHTTPHeaderField:@"Content-Length"];
    [request setValue:nil forHTTPHeaderField:@"Content-Encoding"];
    [request setValue:@"application/x-protobuf" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
    [request setValue:@"application/vnd.yt-ump" forHTTPHeaderField:@"Accept"];
    self.activeRequestNumber = logicalRequestNumber;
    self.activeRequestStart = NSDate.date.timeIntervalSinceReferenceDate;
    self.lastLiveProgress = 0.0;
    self.activeBaseAudioBytes = self.audio.downloadedBytes;
    self.activeBaseVideoBytes = self.video.downloadedBytes;
    self.activeNetworkBytes = 0;
    self.activeResponseData = [NSMutableData data];
    self.activeResponse = nil;
    YTzoomDownloadLog(self.identifier,
        @"request logical=%ld wire=%ld source=%@ url=%@ body=%lu",
        (long)logicalRequestNumber, (long)wireRequestNumber,
        standalone ? @"standalone" : (nativeHeaders.count != 0 ? @"native-session" : @"raw"), request.URL.host,
        (unsigned long)request.HTTPBody.length);
    self.requestNumber += 1;
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    task.taskDescription = [NSString stringWithFormat:@"%ld",
        (long)logicalRequestNumber];
    task.priority = NSURLSessionTaskPriorityHigh;
    [task resume];
}

- (void)refreshNativeSession:(NSString *)reason {
    if (self.finished) return;
    if (self.nativeRefreshInFlight) return;
    if (self.usingTVClient) {
        self.nativeRefreshInFlight = YES;
        __weak YTzoomSABRSession *weakSelf = self;
        [self refreshTVClient:reason then:^(BOOL refreshed) {
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.nativeRefreshInFlight = NO;
            if (refreshed) [strongSelf sendRequest];
            else [strongSelf retryOrFail:[strongSelf error:
                @"YouTube could not refresh the TV stream." code:9]];
        }];
        return;
    }
    if (self.nativeRefreshAttempts >= 3) {
        [self retryOrFail:[self error:
            @"YouTube could not refresh the native download session." code:9]];
        return;
    }
    self.nativeRefreshInFlight = YES;
    self.nativeRefreshAttempts += 1;
    YTzoomDownloadLog(self.identifier, @"native refresh attempt=%ld reason=%@",
        (long)self.nativeRefreshAttempts, reason ?: @"authorization");
    __weak YTzoomSABRSession *weakSelf = self;
    YTzoomPreparePlayer(self.videoID, ^(id playerResponse, NSError *error) {
        YTzoomSABRSession *strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf.finished) return;
        strongSelf.nativeRefreshInFlight = NO;
        NSError *applyError = nil;
        BOOL applied = playerResponse != nil &&
            [strongSelf applyPlayerResponse:playerResponse error:&applyError];
        if (!applied) {
            NSError *finalError = error ?: applyError ?: [strongSelf error:
                @"YouTube could not refresh the native download session." code:9];
            [strongSelf retryOrFail:finalError];
            return;
        }
        strongSelf.retryCount = 0;
        strongSelf.stalledRequests = 0;
        strongSelf.playbackCookie = nil;
        [strongSelf.contexts removeAllObjects];
        [strongSelf.headers removeAllObjects];
        [strongSelf sendRequest];
    });
}

- (void)switchToTVClient:(NSString *)reason then:(void (^)(BOOL switched))next {
    if (self.triedTVClient || self.finished) {
        next(NO);
        return;
    }
    self.triedTVClient = YES;
    YTzoomDownloadLog(self.identifier, @"switching to tv client reason=%@", reason);
    [self refreshTVClient:reason then:next];
}

- (void)refreshTVClient:(NSString *)reason then:(void (^)(BOOL refreshed))next {
    if (self.finished) {
        next(NO);
        return;
    }
    if (self.usingTVClient) {
        if (self.tvRefreshCount >= 3) {
            YTzoomDownloadLog(self.identifier, @"tv client refresh exhausted reason=%@", reason);
            next(NO);
            return;
        }
        self.tvRefreshCount += 1;
        YTzoomDownloadLog(self.identifier, @"tv client refresh attempt=%ld reason=%@",
            (long)self.tvRefreshCount, reason);
    }
    __weak YTzoomSABRSession *weakSelf = self;
    YTzoomTVFetchPlayerResponse(self.videoID, ^(id response, NSString *visitor, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.finished) return;
            NSError *applyError = nil;
            if (response == nil) {
                YTzoomDownloadLog(strongSelf.identifier, @"tv client unavailable error=%@",
                    error.localizedDescription ?: @"none");
                next(NO);
                return;
            }
            YTzoomSABRSetStandaloneClient(strongSelf.identifier, YTzoomTVClientInfo(),
                                          YTzoomTVHeaders(visitor));
            if (![strongSelf applyPlayerResponse:response error:&applyError]) {
                YTzoomSABRSetStandaloneClient(strongSelf.identifier, nil, nil);
                YTzoomDownloadLog(strongSelf.identifier, @"tv client apply failed error=%@",
                    applyError.localizedDescription ?: @"none");
                next(NO);
                return;
            }
            strongSelf.usingTVClient = YES;
            strongSelf.stalledRequests = 0;
            strongSelf.retryCount = 0;
            strongSelf.requestNumber = 0;
            strongSelf.playbackCookie = nil;
            [strongSelf.contexts removeAllObjects];
            [strongSelf.headers removeAllObjects];
            YTzoomDownloadLog(strongSelf.identifier, @"tv client active host=%@",
                [NSURL URLWithString:strongSelf.serverURL].host);
            next(YES);
        });
    });
}

- (void)recoverAuthorization:(NSError *)error {
    if (self.finished || self.authRecoveryInFlight) return;
    if (self.usingTVClient) {
        self.authRecoveryInFlight = YES;
        __weak YTzoomSABRSession *weakSelf = self;
        [self refreshTVClient:error.localizedDescription then:^(BOOL refreshed) {
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.authRecoveryInFlight = NO;
            if (refreshed) [strongSelf sendRequest];
            else [strongSelf fail:error];
        }];
        return;
    }
    if (!self.triedTVClient) {
        self.authRecoveryInFlight = YES;
        __weak YTzoomSABRSession *weakSelf = self;
        [self switchToTVClient:error.localizedDescription then:^(BOOL switched) {
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.authRecoveryInFlight = NO;
            if (switched) [strongSelf sendRequest];
            else [strongSelf recoverAuthorization:error];
        }];
        return;
    }
    static const NSTimeInterval waits[] = {0.0, 20.0, 45.0};
    const NSInteger steps = (NSInteger)(sizeof(waits) / sizeof(waits[0]));
    if (self.authRecoveryStep >= steps) {
        YTzoomDownloadLog(self.identifier, @"authorization recovery exhausted");
        [self fail:error];
        return;
    }
    const NSTimeInterval wait = waits[self.authRecoveryStep];
    self.authRecoveryStep += 1;
    self.authRecoveryInFlight = YES;
    YTzoomDownloadLog(self.identifier, @"authorization recovery step=%ld wait=%.0f route=player",
        (long)self.authRecoveryStep, wait);
    __weak YTzoomSABRSession *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        YTzoomSABRSession *waiting = weakSelf;
        if (waiting == nil || waiting.finished) return;
        YTzoomPreparePlayerWithRoute(waiting.videoID, YES, ^(id playerResponse, NSError *prepareError) {
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.finished) return;
            strongSelf.authRecoveryInFlight = NO;
            NSError *applyError = nil;
            if (playerResponse == nil ||
                ![strongSelf applyPlayerResponse:playerResponse error:&applyError]) {
                YTzoomDownloadLog(strongSelf.identifier, @"authorization recovery step=%ld failed error=%@",
                    (long)strongSelf.authRecoveryStep,
                    (prepareError ?: applyError).localizedDescription ?: @"no response");
                [strongSelf recoverAuthorization:error];
                return;
            }
            strongSelf.stalledRequests = 0;
            strongSelf.retryCount = 0;
            strongSelf.requestNumber = 0;
            strongSelf.playbackCookie = nil;
            [strongSelf.contexts removeAllObjects];
            [strongSelf.headers removeAllObjects];
            YTzoomDownloadLog(strongSelf.identifier, @"authorization recovery step=%ld applied host=%@ config=%lu",
                (long)strongSelf.authRecoveryStep,
                [NSURL URLWithString:strongSelf.serverURL].host,
                (unsigned long)strongSelf.ustreamerConfig.length);
            [strongSelf sendRequest];
        });
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
 didReceiveResponse:(NSURLResponse *)response
  completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    (void)session;
    if (dataTask.taskDescription.integerValue == self.activeRequestNumber) {
        self.activeResponse = (NSHTTPURLResponse *)response;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    (void)session;
    if (self.finished || dataTask.taskDescription.integerValue != self.activeRequestNumber) return;
    [self.activeResponseData appendData:data];
    self.activeNetworkBytes += (int64_t)data.length;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (self.mediaPhase == 0 || now - self.lastLiveProgress < 0.08) return;
    self.lastLiveProgress = now;
    int64_t audioBytes = self.activeBaseAudioBytes;
    int64_t videoBytes = self.activeBaseVideoBytes;
    if (self.combinedMode) {
        int64_t estimatedMediaBytes =
            (int64_t)llround((double)self.activeNetworkBytes * 0.985);
        double audioWeight = MAX(self.audio.option.bitrate, 0);
        double videoWeight = MAX(self.video.option.bitrate, 0);
        if (audioWeight + videoWeight <= 0.0) {
            audioWeight = MAX(self.audio.option.contentLength - audioBytes, 0);
            videoWeight = MAX(self.video.option.contentLength - videoBytes, 0);
        }
        double totalWeight = audioWeight + videoWeight;
        double audioShare = totalWeight > 0.0 ? audioWeight / totalWeight : 0.04;
        audioShare = MIN(MAX(audioShare, 0.005), 0.30);
        int64_t estimatedAudio =
            (int64_t)llround((double)estimatedMediaBytes * audioShare);
        audioBytes += estimatedAudio;
        videoBytes += estimatedMediaBytes - estimatedAudio;
        if (self.audio.option.contentLength > 0) {
            audioBytes = MIN(audioBytes, self.audio.option.contentLength);
        }
        if (self.video.option.contentLength > 0) {
            videoBytes = MIN(videoBytes, self.video.option.contentLength);
        }
    } else if (self.mediaPhase == 1) {
        audioBytes += self.activeNetworkBytes;
        if (self.audio.option.contentLength > 0) {
            audioBytes = MIN(audioBytes, self.audio.option.contentLength);
        }
    } else {
        videoBytes += self.activeNetworkBytes;
        if (self.video.option.contentLength > 0) {
            videoBytes = MIN(videoBytes, self.video.option.contentLength);
        }
    }
    [self sendProgressWithAudioBytes:audioBytes videoBytes:videoBytes];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
 didCompleteWithError:(NSError *)error {
    (void)session;
    if (self.finished || task.taskDescription.integerValue != self.activeRequestNumber) return;
    NSData *data = [self.activeResponseData copy];
    NSHTTPURLResponse *http = self.activeResponse ?: (NSHTTPURLResponse *)task.response;
    NSTimeInterval elapsed = MAX(NSDate.date.timeIntervalSinceReferenceDate -
        self.activeRequestStart, 0.001);
    double megabytesPerSecond = ((double)data.length / 1048576.0) / elapsed;
    YTzoomDownloadLog(self.identifier,
        @"response %ld status=%ld bytes=%lu seconds=%.2f speed=%.2fMB/s error=%@",
        (long)self.activeRequestNumber, (long)http.statusCode, (unsigned long)data.length,
        elapsed, megabytesPerSecond, error.localizedDescription ?: @"none");
    if (error != nil || http.statusCode < 200 || http.statusCode >= 300 || data.length == 0) {
        NSError *requestError = error ?: [self error:
            [NSString stringWithFormat:@"SABR returned HTTP %ld.", (long)http.statusCode]
            code:4];
        BOOL expired = http.statusCode == 401 || http.statusCode == 403 ||
            http.statusCode == 409 || http.statusCode == 410;
        if (expired && self.usingTVClient) {
            __weak YTzoomSABRSession *weakSelf = self;
            NSString *reason = requestError.localizedDescription;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf refreshTVClient:reason then:^(BOOL refreshed) {
                    YTzoomSABRSession *strongSelf = weakSelf;
                    if (strongSelf == nil) return;
                    if (refreshed) [strongSelf sendRequest];
                    else [strongSelf retryOrFail:requestError];
                }];
            });
        } else if (expired && YTzoomHasNativeOnesieSession(self.videoID)) {
            [self refreshNativeSession:requestError.localizedDescription];
        } else {
            [self retryOrFail:requestError];
        }
        return;
    }
    [self processResponse:data];
}

- (void)retryOrFail:(NSError *)error {
    if (self.combinedMode && self.retryCount >= 2 &&
        [self switchToSequentialFallback:error.localizedDescription]) {
        return;
    }
    self.retryCount += 1;
    if (self.retryCount > 8) {
        [self fail:error];
        return;
    }
    NSTimeInterval delay = MIN(pow(2.0, self.retryCount - 1) * 0.5, 12.0);
    YTzoomDownloadLog(self.identifier, @"retry %ld delay=%.1f reason=%@",
        (long)self.retryCount, delay, error.localizedDescription);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
}

- (void)handleInitialization:(NSData *)data {
    NSData *formatID = YTzoomPBDataField(data, 2);
    NSInteger itag = (NSInteger)YTzoomPBIntegerField(formatID, 1, 0);
    NSString *xtags = YTzoomPBStringField(formatID, 3) ?: @"";
    YTzoomSABRTrack *track = [self trackForItag:itag xtags:xtags];
    if (track == nil) return;
    track.initialized = YES;
    track.endTime = (int64_t)YTzoomPBIntegerField(data, 3, 0);
    track.endSequence = (NSInteger)YTzoomPBIntegerField(data, 4, NSIntegerMax);
    YTzoomDownloadLog(self.identifier, @"init itag=%ld end=%lld sequence=%ld",
        (long)itag, track.endTime, (long)track.endSequence);
}

- (void)handlePolicy:(NSData *)data {
    self.backoffMilliseconds = (NSInteger)YTzoomPBIntegerField(data, 4, 0);
    NSData *cookie = YTzoomPBDataField(data, 7);
    if (cookie.length != 0) self.playbackCookie = cookie;
}

- (void)handleContext:(NSData *)data {
    NSNumber *type = @((NSInteger)YTzoomPBIntegerField(data, 1, 0));
    NSData *value = YTzoomPBDataField(data, 3);
    BOOL send = YTzoomPBIntegerField(data, 4, 0) != 0;
    NSInteger policy = (NSInteger)YTzoomPBIntegerField(data, 5, 0);
    if (type.integerValue == 0 || value.length == 0 || !send) return;
    if (policy != 2 || self.contexts[type] == nil) self.contexts[type] = value;
}

- (void)handleHeader:(NSData *)data {
    YTzoomSABRHeader *header = [YTzoomSABRHeader new];
    header.headerID = (NSInteger)YTzoomPBIntegerField(data, 1, 0);
    header.itag = (NSInteger)YTzoomPBIntegerField(data, 3, 0);
    header.xtags = YTzoomPBStringField(data, 5) ?: @"";
    header.initialization = YTzoomPBIntegerField(data, 8, 0) != 0;
    header.sequence = (NSInteger)YTzoomPBIntegerField(data, 9, 0);
    header.startTime = (int64_t)YTzoomPBIntegerField(data, 11, 0);
    header.duration = (int64_t)YTzoomPBIntegerField(data, 12, 0);
    NSData *timeRange = YTzoomPBDataField(data, 15);
    int64_t timescale = (int64_t)YTzoomPBIntegerField(timeRange, 3, 0);
    if (timescale > 0) {
        if (header.startTime == 0) {
            int64_t ticks = (int64_t)YTzoomPBIntegerField(timeRange, 1, 0);
            header.startTime = (ticks * 1000) / timescale;
        }
        if (header.duration == 0) {
            int64_t ticks = (int64_t)YTzoomPBIntegerField(timeRange, 2, 0);
            header.duration = (ticks * 1000) / timescale;
        }
    }
    header.contentLength = (int64_t)YTzoomPBIntegerField(data, 14, 0);
    NSData *formatID = YTzoomPBDataField(data, 13);
    if (header.itag == 0 && formatID != nil) {
        header.itag = (NSInteger)YTzoomPBIntegerField(formatID, 1, 0);
        header.xtags = YTzoomPBStringField(formatID, 3) ?: header.xtags;
    }
    header.data = [NSMutableData data];
    if (header.headerID >= 0) self.headers[@(header.headerID)] = header;
}

- (void)handleMedia:(NSData *)data {
    if (data.length < 1) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    YTzoomSABRHeader *header = self.headers[@(bytes[0])];
    if (header == nil || data.length == 1) return;
    [header.data appendData:[data subdataWithRange:NSMakeRange(1, data.length - 1)]];
}

- (void)finishHeader:(NSData *)data {
    if (data.length < 1) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSNumber *key = @(bytes[0]);
    YTzoomSABRHeader *header = self.headers[key];
    [self.headers removeObjectForKey:key];
    YTzoomSABRTrack *track = [self trackForItag:header.itag xtags:header.xtags];
    if (track == nil || header.data.length == 0) {
        YTzoomDownloadLog(self.identifier,
            @"segment ignored itag=%ld bytes=%lu", (long)header.itag,
            (unsigned long)header.data.length);
        return;
    }
    NSString *segmentKey = [NSString stringWithFormat:@"%ld:%@:%ld:%d",
        (long)header.itag, header.xtags, (long)header.sequence, header.initialization];
    if ([track.segments containsObject:segmentKey]) return;
    if (header.contentLength > 0 && header.data.length != (NSUInteger)header.contentLength) {
        YTzoomDownloadLog(self.identifier,
            @"segment size mismatch itag=%ld got=%lu expected=%lld",
            (long)header.itag, (unsigned long)header.data.length,
            header.contentLength);
        return;
    }
    [track.segments addObject:segmentKey];
    if (header.initialization) {
        if (!track.initializationWritten) {
            [track.handle writeData:header.data];
            track.initializationWritten = YES;
        }
        return;
    }
    [track.handle writeData:header.data];
    track.downloadedBytes += (int64_t)header.data.length;
    track.lastSequence = MAX(track.lastSequence, header.sequence);
    track.downloadedDuration += MAX(header.duration, 0);
    if (!track.hasRound) {
        track.hasRound = YES;
        track.roundStart = header.startTime;
        track.roundStartSequence = header.sequence;
    }
    track.roundDuration += MAX(header.duration, 0);
    track.roundStartSequence = MIN(track.roundStartSequence, header.sequence);
    track.roundEndSequence = MAX(track.roundEndSequence, header.sequence);
}

- (void)handleRedirect:(NSData *)data {
    NSString *redirect = YTzoomPBStringField(data, 1);
    if (redirect.length != 0) {
        self.serverURL = redirect;
        YTzoomDownloadLog(self.identifier, @"redirect host=%@",
            [NSURL URLWithString:redirect].host);
    }
}

- (BOOL)trackComplete:(YTzoomSABRTrack *)track {
    if (track.endSequence != NSIntegerMax && track.lastSequence >= track.endSequence) {
        return YES;
    }
    return track.endTime > 0 && track.downloadedDuration + 1000 >= track.endTime;
}

- (YTzoomSABRTrack *)activeTrack {
    return self.mediaPhase == 2 ? self.video : self.audio;
}

- (void)advanceOrFinish {
    if (self.audioOnly || self.mediaPhase == 2 ||
        (self.mediaPhase == 1 && [self trackComplete:self.video])) {
        [self finish];
        return;
    }
    self.mediaPhase = 2;
    self.stalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    YTzoomDownloadLog(self.identifier, @"phase video");
    [self sendProgress];
    [self sendRequest];
}

- (void)sendProgressWithAudioBytes:(int64_t)audioBytes videoBytes:(int64_t)videoBytes {
    double video = self.video.endTime > 0
        ? (double)self.video.downloadedDuration / (double)self.video.endTime : 0.0;
    double audio = self.audio.endTime > 0
        ? (double)self.audio.downloadedDuration / (double)self.audio.endTime : 0.0;
    if (self.progress != nil) {
        audio = MIN(MAX(audio, 0.0), 1.0);
        video = MIN(MAX(video, 0.0), 1.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progress(audio, video, audioBytes, videoBytes, self.mediaPhase);
        });
    }
}

- (void)sendProgress {
    [self sendProgressWithAudioBytes:self.audio.downloadedBytes
        videoBytes:self.video.downloadedBytes];
}

- (void)processResponse:(NSData *)response {
    int64_t beforeAudio = self.audio.downloadedDuration;
    int64_t beforeVideo = self.video.downloadedDuration;
    int64_t before = beforeVideo + beforeAudio;
    BOOL rejected = NO;
    BOOL attestation = NO;
    NSString *rejectionType = nil;
    NSInteger rejectionCode = 0;
    NSInteger protectionStatus = 0;
    NSInteger protectionRetries = 0;
    BOOL terminalMarker = NO;
    NSString *reloadToken = nil;
    NSMutableDictionary<NSNumber *, NSNumber *> *partCounts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSNumber *> *partBytes = [NSMutableDictionary dictionary];
    NSUInteger offset = 0;
    while (offset < response.length) {
        uint32_t type = 0;
        uint32_t size = 0;
        if (!YTzoomUMPValue(response, &offset, &type) ||
            !YTzoomUMPValue(response, &offset, &size) || offset + size > response.length) {
            [self retryOrFail:[self error:@"YouTube returned an incomplete SABR response." code:5]];
            return;
        }
        NSData *part = [response subdataWithRange:NSMakeRange(offset, size)];
        offset += size;
        NSNumber *partType = @(type);
        partCounts[partType] = @([partCounts[partType] unsignedIntegerValue] + 1);
        partBytes[partType] = @([partBytes[partType] unsignedLongLongValue] + size);
        if (self.requestNumber <= 1 && (type == 46 || type == 51)) {
            YTzoomDownloadLog(self.identifier, @"directive type=%u data=%@", type,
                [part base64EncodedStringWithOptions:0]);
        }
        if (type == 20) [self handleHeader:part];
        else if (type == 21) [self handleMedia:part];
        else if (type == 22) [self finishHeader:part];
        else if (type == 35) [self handlePolicy:part];
        else if (type == 42) [self handleInitialization:part];
        else if (type == 43) [self handleRedirect:part];
        else if (type == 46) {
            NSData *params = YTzoomPBDataField(part, 1);
            reloadToken = YTzoomPBStringField(params, 1);
        }
        else if (type == 44) {
            rejected = YES;
            rejectionType = YTzoomPBStringField(part, 1);
            rejectionCode = (NSInteger)YTzoomPBIntegerField(part, 2, 0);
            YTzoomDownloadLog(self.identifier, @"SABR error type=%@ code=%ld data=%@",
                rejectionType ?: @"unknown", (long)rejectionCode,
                YTzoomSABRHex(part, 64));
        }
        else if (type == 47 && size <= 8) terminalMarker = YES;
        else if (type == 57) [self handleContext:part];
        else if (type == 58) {
            protectionStatus = (NSInteger)YTzoomPBIntegerField(part, 1, 0);
            protectionRetries = (NSInteger)YTzoomPBIntegerField(part, 2, 0);
            attestation = protectionStatus >= 3;
            YTzoomDownloadLog(self.identifier,
                @"protection status=%ld retries=%ld data=%@", (long)protectionStatus,
                (long)protectionRetries, YTzoomSABRHex(part, 64));
        }
    }
    NSMutableArray<NSString *> *partSummary = [NSMutableArray array];
    NSArray<NSNumber *> *sortedTypes = [partCounts.allKeys
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSNumber *partType in sortedTypes) {
        [partSummary addObject:[NSString stringWithFormat:@"%@:%@/%@",
            partType, partCounts[partType], partBytes[partType]]];
    }
    YTzoomDownloadLog(self.identifier, @"UMP parts=%@",
        [partSummary componentsJoinedByString:@","]);
    if (reloadToken.length != 0 && !self.reloadInFlight && self.reloadCount < 3) {
        self.reloadInFlight = YES;
        self.reloadCount += 1;
        YTzoomDownloadLog(self.identifier, @"reload requested attempt=%ld token=%lu",
            (long)self.reloadCount, (unsigned long)reloadToken.length);
        __weak YTzoomSABRSession *weakSelf = self;
        if (self.usingTVClient) {
            [self refreshTVClient:@"reload requested" then:^(BOOL refreshed) {
                YTzoomSABRSession *strongSelf = weakSelf;
                if (strongSelf == nil) return;
                strongSelf.reloadInFlight = NO;
                if (refreshed) [strongSelf sendRequest];
                else [strongSelf retryOrFail:[strongSelf error:
                    @"YouTube could not refresh the TV stream." code:9]];
            }];
            return;
        }
        YTzoomReloadPlayer(self.videoID, reloadToken,
            ^(id playerResponse, NSError *error) {
            YTzoomSABRSession *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.finished) return;
            strongSelf.reloadInFlight = NO;
            NSError *applyError = nil;
            if (playerResponse == nil || ![strongSelf applyPlayerResponse:playerResponse
                                                                     error:&applyError]) {
                NSError *finalError = error ?: applyError ?: [strongSelf error:
                    @"YouTube could not refresh the high-resolution stream." code:9];
                YTzoomDownloadLog(strongSelf.identifier, @"reload failed error=%@",
                    finalError.localizedDescription);
                [strongSelf retryOrFail:finalError];
                return;
            }
            strongSelf.stalledRequests = 0;
            strongSelf.retryCount = 0;
            strongSelf.requestNumber = 0;
            strongSelf.playbackCookie = nil;
            [strongSelf.contexts removeAllObjects];
            [strongSelf.headers removeAllObjects];
            YTzoomDownloadLog(strongSelf.identifier, @"reload applied host=%@ config=%lu",
                [NSURL URLWithString:strongSelf.serverURL].host,
                (unsigned long)strongSelf.ustreamerConfig.length);
            [strongSelf sendRequest];
            });
        return;
    }
    if (protectionStatus == 2 && [partCounts[@21] unsignedIntegerValue] == 0) {
        attestation = YES;
    }
    if (attestation || rejected) {
        NSString *message = attestation
            ? [NSString stringWithFormat:@"YouTube requires stream authorization (%ld).",
                (long)protectionStatus]
            : [NSString stringWithFormat:@"YouTube rejected the SABR request (%@/%ld).",
                rejectionType ?: @"unknown", (long)rejectionCode];
        NSError *error = [self error:message
            code:attestation ? 7 : 6];
        if (attestation) {
            [self recoverAuthorization:error];
        } else if (self.attestationRetries < 3) {
            self.attestationRetries += 1;
            if (YTzoomHasNativeOnesieSession(self.videoID)) {
                [self refreshNativeSession:message];
            } else {
                [self retryOrFail:error];
            }
        } else {
            [self fail:error];
        }
        return;
    }
    [self sendProgress];
    YTzoomSABRTrack *activeTrack = [self activeTrack];
    if (self.combinedMode && [self trackComplete:self.video] &&
        [self trackComplete:self.audio]) {
        [self finish];
        return;
    }
    int64_t afterAudio = self.audio.downloadedDuration;
    int64_t afterVideo = self.video.downloadedDuration;
    if (self.combinedMode) {
        self.audioStalledRequests = [self trackComplete:self.audio] ||
            afterAudio > beforeAudio ? 0 : self.audioStalledRequests + 1;
        self.videoStalledRequests = [self trackComplete:self.video] ||
            afterVideo > beforeVideo ? 0 : self.videoStalledRequests + 1;
        BOOL trackStalled = self.audioStalledRequests >= 3 ||
            self.videoStalledRequests >= 3;
        BOOL endedEarly = terminalMarker && afterAudio + afterVideo <= before;
        if ((trackStalled || endedEarly) &&
            [self switchToSequentialFallback:trackStalled
                ? @"one track stopped advancing" : @"combined stream ended early"]) {
            return;
        }
    }
    if (self.mediaPhase > 0 && [self trackComplete:activeTrack]) {
        if (!self.combinedMode) [self advanceOrFinish];
        else [self sendRequest];
        return;
    }
    int64_t after = afterVideo + afterAudio;
    BOOL hasActiveMedia = self.combinedMode
        ? ((self.video.initializationWritten && self.video.downloadedBytes > 0) ||
           (self.audio.initializationWritten && self.audio.downloadedBytes > 0))
        : (activeTrack.initializationWritten && activeTrack.downloadedBytes > 0);
    if (!self.combinedMode && self.mediaPhase > 0 && terminalMarker &&
        after <= before && hasActiveMedia) {
        if ([self restartStalledSession:@"early terminal marker"]) return;
        [self fail:[self error:@"The SABR stream ended before all media was received."
                               code:8]];
        return;
    }
    if (after <= before) self.stalledRequests += 1;
    else {
        if (self.authRecoveryStep > 0) {
            YTzoomDownloadLog(self.identifier, @"authorization recovered at step=%ld",
                (long)self.authRecoveryStep);
            self.authRecoveryStep = 0;
        }
        self.stalledRequests = 0;
        self.retryCount = 0;
        self.stallRecoveryCount = 0;
        self.nativeRefreshAttempts = 0;
        self.attestationRetries = 0;
        self.tvRefreshCount = 0;
    }
    YTzoomDownloadLog(self.identifier,
        @"progress audio=%.3f/%lld video=%.3f/%lld bytes=%lld+%lld stalled=%ld",
        (double)self.audio.downloadedDuration, self.audio.endTime,
        (double)self.video.downloadedDuration, self.video.endTime,
        self.audio.downloadedBytes, self.video.downloadedBytes,
        (long)self.stalledRequests);
    BOOL missingInitialization = self.audio.endTime == 0 ||
        (!self.audioOnly && self.video.endTime == 0);
    if (self.combinedMode && missingInitialization && self.stalledRequests >= 3 &&
        [self switchToSequentialFallback:@"missing combined initialization"]) {
        return;
    }
    if (!self.combinedMode && self.mediaPhase > 0 &&
        self.stalledRequests >= 3 && hasActiveMedia &&
        [self restartStalledSession:@"media stopped advancing"]) {
        return;
    }
    if ((missingInitialization && self.stalledRequests >= 3) || self.stalledRequests > 8) {
        [self fail:[self error:@"The SABR download stopped making progress." code:8]];
        return;
    }
    NSTimeInterval delay = MAX(self.backoffMilliseconds, 0) / 1000.0;
    self.backoffMilliseconds = 0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
}

- (BOOL)restartStalledSession:(NSString *)reason {
    if (self.finished || self.stallRecoveryCount >= 3) return NO;
    self.stallRecoveryCount += 1;
    NSTimeInterval delay = MAX(self.backoffMilliseconds, 250) / 1000.0;
    self.requestNumber = 0;
    self.stalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    self.playbackCookie = nil;
    [self.headers removeAllObjects];
    [self.contexts removeAllObjects];
    YTzoomDownloadLog(self.identifier,
        @"session restart attempt=%ld phase=%ld reason=%@ audio=%.0f/%lld video=%.0f/%lld",
        (long)self.stallRecoveryCount, (long)self.mediaPhase, reason ?: @"stalled",
        (double)self.audio.downloadedDuration, self.audio.endTime,
        (double)self.video.downloadedDuration, self.video.endTime);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ [self sendRequest]; });
    return YES;
}

- (BOOL)switchToSequentialFallback:(NSString *)reason {
    if (!self.combinedMode || self.finished) return NO;
    self.combinedMode = NO;
    self.sequentialFallback = YES;
    self.mediaPhase = [self trackComplete:self.audio] ? 2 : 1;
    self.stalledRequests = 0;
    self.audioStalledRequests = 0;
    self.videoStalledRequests = 0;
    self.retryCount = 0;
    self.backoffMilliseconds = 0;
    [self.headers removeAllObjects];
    YTzoomDownloadLog(self.identifier,
        @"combined fallback phase=%@ reason=%@ audio=%lld video=%lld",
        self.mediaPhase == 1 ? @"audio" : @"video", reason ?: @"unknown",
        self.audio.downloadedBytes, self.video.downloadedBytes);
    [self sendProgress];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self sendRequest];
    });
    return YES;
}

- (void)finish {
    if (self.finished) return;
    if (![self trackComplete:self.audio] ||
        (!self.audioOnly && ![self trackComplete:self.video])) {
        [self fail:[self error:@"The SABR stream ended before all media was received."
                               code:8]];
        return;
    }
    self.finished = YES;
    [self.video.handle closeFile];
    [self.audio.handle closeFile];
    [self.session invalidateAndCancel];
    YTzoomDownloadLog(self.identifier, @"SABR complete audio=%lld video=%lld",
        self.audio.downloadedBytes, self.video.downloadedBytes);
    dispatch_async(dispatch_get_main_queue(), ^{
        self.completion(self.video.URL, self.audio.URL, nil);
    });
}

- (void)fail:(NSError *)error {
    if (self.finished) return;
    self.finished = YES;
    [self.video.handle closeFile];
    [self.audio.handle closeFile];
    [self.session invalidateAndCancel];
    YTzoomDownloadLog(self.identifier, @"SABR failed code=%ld error=%@",
        (long)error.code, error.localizedDescription);
    NSURL *scratch = self.video.URL.URLByDeletingLastPathComponent
        ?: self.audio.URL.URLByDeletingLastPathComponent;
    if (self.video.URL != nil) [NSFileManager.defaultManager removeItemAtURL:self.video.URL error:nil];
    if (self.audio.URL != nil) [NSFileManager.defaultManager removeItemAtURL:self.audio.URL error:nil];
    if ([scratch.lastPathComponent hasPrefix:@"YTzoom-"]) {
        [NSFileManager.defaultManager removeItemAtURL:scratch error:nil];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ self.completion(nil, nil, error); });
}

- (void)cancel {
    if (self.finished) return;
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain
        code:NSURLErrorCancelled userInfo:@{
            NSLocalizedDescriptionKey: @"Download cancelled"
        }];
    [self fail:error];
}

@end

@interface YTzoomSABRTask ()
@property(nonatomic, copy) dispatch_block_t cancelBlock;
@end

@implementation YTzoomSABRTask

- (void)cancel {
    if (self.cancelBlock != nil) self.cancelBlock();
}

@end

@implementation YTzoomSABRDownloader

+ (YTzoomSABRTask *)downloadPlayerResponse:(id)playerResponse
                   videoOption:(YTzoomStreamOption *)videoOption
                   audioOption:(YTzoomStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                       videoID:(NSString *)videoID
                     identifier:(NSString *)identifier
                      progress:(YTzoomSABRProgress)progress
                    completion:(YTzoomSABRCompletion)completion {
    YTzoomSABRSession *session = [YTzoomSABRSession new];
    YTzoomSABRTask *task = [YTzoomSABRTask new];
    session.playerResponse = playerResponse;
    session.video = [YTzoomSABRTrack new];
    session.video.option = videoOption;
    session.audio = [YTzoomSABRTrack new];
    session.audio.option = audioOption;
    session.audioOnly = audioOnly;
    session.combinedMode = YTzoom_COMBINED_SABR && !audioOnly;
    session.videoID = videoID ?: @"";
    session.identifier = identifier;
    session.progress = progress;
    session.completion = completion;
    __weak YTzoomSABRSession *weakSession = session;
    task.cancelBlock = ^{ [weakSession cancel]; };
    objc_setAssociatedObject(session, @selector(start), session, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomSABRCompletion original = [completion copy];
    __weak YTzoomSABRTask *weakTask = task;
    session.completion = ^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
        YTzoomSABRSetStandaloneClient(identifier, nil, nil);
        original(videoURL, audioURL, error);
        weakTask.cancelBlock = nil;
        YTzoomSABRSession *strongSession = weakSession;
        objc_setAssociatedObject(strongSession, @selector(start), nil,
            OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    };
    [session start];
    return task;
}

@end
