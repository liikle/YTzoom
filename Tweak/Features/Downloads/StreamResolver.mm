#import "StreamResolver.h"
#import "DownloadLog.h"
#import "../../Runtime/Localization.h"

#import <UIKit/UIKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

@implementation YTzoomStreamOption
@end

static id YTzoomStreamObject(id receiver, NSArray<NSString *> *selectors) {
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

static NSInteger YTzoomStreamInteger(id receiver, NSArray<NSString *> *selectors) {
    for (NSString *name in selectors) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            return ((NSInteger (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    return 0;
}

static NSArray *YTzoomArrayValue(id receiver, NSArray<NSString *> *selectors) {
    id value = YTzoomStreamObject(receiver, selectors);
    return [value isKindOfClass:NSArray.class] ? value : @[];
}

static NSURL *YTzoomURLValue(id value) {
    if ([value isKindOfClass:NSURL.class]) {
        return value;
    }
    if ([value isKindOfClass:NSString.class]) {
        return [NSURL URLWithString:value];
    }
    return nil;
}

static id YTzoomFindNestedObject(id object,
                                 NSString *target,
                                 NSHashTable *visited,
                                 NSUInteger depth) {
    if (object == nil || depth > 8 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    id value = YTzoomStreamObject(object, @[target]);
    if (value != nil) {
        return value;
    }
    for (NSString *name in @[@"playerData", @"contentPlayerResponse",
                              @"playerResponse", @"playbackData", @"video",
                              @"response", @"shortsPlayerData"]) {
        id nested = YTzoomStreamObject(object, @[name]);
        id found = YTzoomFindNestedObject(nested, target, visited, depth + 1);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static id YTzoomNestedObject(id object, NSString *target) {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return YTzoomFindNestedObject(object, target, visited, 0);
}

static NSString *YTzoomStringValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return value;
    }
    for (NSString *name in @[@"text", @"string", @"simpleText"]) {
        id nested = YTzoomStreamObject(value, @[name]);
        if ([nested isKindOfClass:NSString.class]) {
            return nested;
        }
    }
    return nil;
}

static NSInteger YTzoomQualityHeight(NSString *label) {
    NSScanner *scanner = [NSScanner scannerWithString:label ?: @""];
    NSInteger height = 0;
    return [scanner scanInteger:&height] ? height : 0;
}

static NSInteger YTzoomVideoPreference(YTzoomStreamOption *option) {
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"avc1"]) return 4;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) return 3;
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) return 2;
    if ([mime containsString:@"video/mp4"]) return 1;
    return 0;
}

static BOOL YTzoomHighResolutionSupported(YTzoomStreamOption *option) {
    if (option.height <= 1080) return YES;
    NSString *mime = option.mimeType.lowercaseString;
    if ([mime containsString:@"av01"] || [mime containsString:@"av1"]) {
        return VTIsHardwareDecodeSupported('av01');
    }
    if ([mime containsString:@"vp09"] || [mime containsString:@"vp9"]) {
        return VTIsHardwareDecodeSupported('vp09');
    }
    if ([mime containsString:@"hvc1"] || [mime containsString:@"hev1"] ||
        [mime containsString:@"hevc"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC);
    }
    if ([mime containsString:@"avc1"] || [mime containsString:@"h264"]) {
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_H264);
    }
    return NO;
}

static NSString *YTzoomVideoRejectReason(YTzoomStreamOption *option) {
    if (![option.mimeType hasPrefix:@"video/"]) return @"not video";
    if (option.itag <= 0) return @"no itag";
    if (![option.mimeType containsString:@"video/mp4"] &&
        ![option.mimeType containsString:@"video/webm"]) {
        return @"container unsupported";
    }
    if (option.height <= 0) return @"no height";
    if (!YTzoomHighResolutionSupported(option)) return @"no hardware decode";
    return nil;
}

static id YTzoomPlayerData(id playerResponse) {
    return YTzoomNestedObject(playerResponse, @"playerData") ?: playerResponse;
}

static id YTzoomVideoDetails(id playerResponse) {
    return YTzoomNestedObject(playerResponse, @"videoDetails") ?:
        YTzoomPlayerData(playerResponse);
}

static id YTzoomStreamingData(id playerResponse) {
    id direct = YTzoomStreamObject(playerResponse, @[@"streamingData"]);
    return direct ?: YTzoomStreamObject(YTzoomPlayerData(playerResponse),
                                         @[@"streamingData"]);
}


static YTzoomStreamOption *YTzoomOptionFromFormat(id format, BOOL adaptive) {
    NSURL *url = YTzoomURLValue(YTzoomStreamObject(format, @[@"URL", @"url"]));
    if (url != nil && ![url.scheme.lowercaseString hasPrefix:@"http"]) {
        url = nil;
    }

    NSString *mime = YTzoomStreamObject(format, @[@"mimeType"]);
    if (![mime isKindOfClass:NSString.class]) {
        mime = @"application/octet-stream";
    }

    YTzoomStreamOption *option = [YTzoomStreamOption new];
    option.URL = url;
    option.mimeType = mime;
    option.qualityLabel = YTzoomStreamObject(format, @[@"qualityLabel", @"audioQuality"]) ?: @"";
    option.xtags = YTzoomStreamObject(format, @[@"xtags"]) ?: @"";
    option.bitrate = YTzoomStreamInteger(format, @[@"bitrate"]);
    option.itag = YTzoomStreamInteger(format, @[@"itag"]);
    option.contentLength = YTzoomStreamInteger(format, @[@"contentLength"]);
    option.lastModified = YTzoomStreamInteger(format, @[@"lastModified"]);
    option.width = YTzoomStreamInteger(format, @[@"width"]);
    option.height = YTzoomStreamInteger(format, @[@"height"]);
    option.audioOnly = [mime hasPrefix:@"audio/"] ||
        (adaptive && ![mime hasPrefix:@"video/"]);
    option.adaptive = adaptive;
    option.rawFormat = format;
    id audioTrack = YTzoomStreamObject(format, @[@"audioTrack"]);
    NSString *language = YTzoomStringValue(YTzoomStreamObject(
        audioTrack, @[@"displayName", @"display_name", @"name"]));
    if (language.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"display_name: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                language = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.languageLabel = language.length != 0 ? language : YTzoomLocalized(@"Original audio");
    NSString *trackID = YTzoomStringValue(YTzoomStreamObject(
        audioTrack, @[@"id_p", @"audioTrackId", @"audioTrackID"]));
    if (trackID.length == 0) {
        NSString *description = [audioTrack description];
        NSRange marker = [description rangeOfString:@"id: \""];
        if (marker.location != NSNotFound) {
            NSUInteger start = NSMaxRange(marker);
            NSRange rest = NSMakeRange(start, description.length - start);
            NSRange end = [description rangeOfString:@"\"" options:0 range:rest];
            if (end.location != NSNotFound) {
                trackID = [description substringWithRange:
                    NSMakeRange(start, end.location - start)];
            }
        }
    }
    option.audioTrackID = trackID ?: @"";
    option.defaultAudio = YTzoomStreamInteger(
        audioTrack, @[@"audioIsDefault", @"isDefault", @"defaultAudio"]) != 0;
    return option;
}

@implementation YTzoomStreamResolver

+ (NSArray<YTzoomStreamOption *> *)optionsFromPlayerResponse:(id)playerResponse {
    id streamingData = YTzoomStreamingData(playerResponse);
    if (streamingData == nil) {
        return @[];
    }
    NSMutableArray<YTzoomStreamOption *> *result = [NSMutableArray array];
    for (id format in YTzoomArrayValue(streamingData, @[@"formatsArray", @"formats"])) {
        YTzoomStreamOption *option = YTzoomOptionFromFormat(format, NO);
        if (option != nil) {
            [result addObject:option];
        }
    }
    for (id format in YTzoomArrayValue(
             streamingData,
             @[@"adaptiveFormatsArray", @"adaptiveFormats"])) {
        YTzoomStreamOption *option = YTzoomOptionFromFormat(format, YES);
        if (option != nil) {
            [result addObject:option];
        }
    }
    return result;
}

+ (NSArray<YTzoomStreamOption *> *)videoOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, YTzoomStreamOption *> *byQuality =
        [NSMutableDictionary dictionary];
    YTzoomDownloadLog(@"quality", @"formats=%lu video=%@ decode avc1=%d hevc=%d vp9=%d av1=%d",
        (unsigned long)options.count,
        [self videoIDFromPlayerResponse:playerResponse] ?: @"?",
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
        VTIsHardwareDecodeSupported('vp09'),
        VTIsHardwareDecodeSupported('av01'));
    for (YTzoomStreamOption *option in options) {
        if (option.height <= 0) {
            option.height = YTzoomQualityHeight(option.qualityLabel);
        }
        NSString *reason = YTzoomVideoRejectReason(option);
        if (reason != nil) {
            if (option.height >= 1080) {
                YTzoomDownloadLog(@"quality", @"dropped itag=%ld %@ %@ -> %@",
                    (long)option.itag,
                    option.qualityLabel.length != 0 ? option.qualityLabel : @"-",
                    option.mimeType, reason);
            }
            continue;
        }
        NSString *key = option.qualityLabel.length != 0
            ? option.qualityLabel : [NSString stringWithFormat:@"%ldp", (long)option.height];
        YTzoomStreamOption *current = byQuality[key];
        NSInteger preference = YTzoomVideoPreference(option);
        NSInteger currentPreference = YTzoomVideoPreference(current);
        if (current == nil || preference > currentPreference ||
            (preference == currentPreference && option.bitrate > current.bitrate)) {
            byQuality[key] = option;
        }
    }
    YTzoomDownloadLog(@"quality", @"offering %@",
        [[byQuality.allKeys sortedArrayUsingSelector:@selector(compare:)]
            componentsJoinedByString:@", "]);
    return [byQuality.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(YTzoomStreamOption *left, YTzoomStreamOption *right) {
            if (left.height == right.height) {
                return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
            }
            return left.height > right.height ? NSOrderedAscending : NSOrderedDescending;
        }];
}

+ (NSArray<YTzoomStreamOption *> *)audioOptionsFromPlayerResponse:(id)playerResponse {
    NSArray *options = [self optionsFromPlayerResponse:playerResponse];
    NSMutableDictionary<NSString *, YTzoomStreamOption *> *byLanguage =
        [NSMutableDictionary dictionary];
    for (YTzoomStreamOption *option in options) {
        if (![option.mimeType hasPrefix:@"audio/mp4"]) {
            continue;
        }
        NSString *key = option.languageLabel.length != 0
            ? option.languageLabel : YTzoomLocalized(@"Original audio");
        YTzoomStreamOption *current = byLanguage[key];
        if (current == nil || option.isDefaultAudio || option.bitrate > current.bitrate) {
            byLanguage[key] = option;
        }
    }
    return [byLanguage.allValues sortedArrayUsingComparator:
        ^NSComparisonResult(YTzoomStreamOption *left, YTzoomStreamOption *right) {
            if (left.isDefaultAudio != right.isDefaultAudio) {
                return left.isDefaultAudio ? NSOrderedAscending : NSOrderedDescending;
            }
            return [left.languageLabel localizedCaseInsensitiveCompare:right.languageLabel];
        }];
}

+ (YTzoomStreamOption *)bestPiPVideoFromPlayerResponse:(id)playerResponse {
    id streamingData = YTzoomStreamingData(playerResponse);
    NSURL *hls = YTzoomURLValue(YTzoomStreamObject(
        streamingData,
        @[@"hlsManifestURL", @"hlsManifestUrl"]
    ));
    if (hls != nil) {
        YTzoomStreamOption *option = [YTzoomStreamOption new];
        option.URL = hls;
        option.mimeType = @"application/x-mpegURL";
        option.qualityLabel = @"HLS";
        return option;
    }
    return [self bestVideoFromPlayerResponse:playerResponse];
}

+ (YTzoomStreamOption *)bestVideoFromPlayerResponse:(id)playerResponse {
    NSArray<YTzoomStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *video = [NSPredicate predicateWithBlock:
        ^BOOL(YTzoomStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return !option.isAdaptive &&
                !option.isAudioOnly &&
                [option.mimeType hasPrefix:@"video/"];
        }];
    return [[options filteredArrayUsingPredicate:video]
        sortedArrayUsingComparator:^NSComparisonResult(YTzoomStreamOption *left,
                                                        YTzoomStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (YTzoomStreamOption *)bestAudioFromPlayerResponse:(id)playerResponse {
    NSArray<YTzoomStreamOption *> *options = [self optionsFromPlayerResponse:playerResponse];
    NSPredicate *audio = [NSPredicate predicateWithBlock:
        ^BOOL(YTzoomStreamOption *option, NSDictionary *bindings) {
            (void)bindings;
            return option.isAudioOnly || [option.mimeType hasPrefix:@"audio/"];
        }];
    return [[options filteredArrayUsingPredicate:audio]
        sortedArrayUsingComparator:^NSComparisonResult(YTzoomStreamOption *left,
                                                        YTzoomStreamOption *right) {
            if (left.bitrate == right.bitrate) {
                return NSOrderedSame;
            }
            return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
        }].firstObject;
}

+ (NSString *)titleFromPlayerResponse:(id)playerResponse {
    id details = YTzoomVideoDetails(playerResponse);
    NSString *title = YTzoomStringValue(YTzoomStreamObject(
        details, @[@"title", @"videoTitle", @"headline"]));
    return title.length != 0
        ? title
        : @"YouTube Video";
}

+ (NSString *)authorFromPlayerResponse:(id)playerResponse {
    id details = YTzoomVideoDetails(playerResponse);
    NSString *author = YTzoomStringValue(YTzoomStreamObject(
        details, @[@"author", @"channelTitle", @"ownerChannelName"]));
    return author.length != 0
        ? author : @"YouTube";
}

+ (NSString *)descriptionFromPlayerResponse:(id)playerResponse {
    id details = YTzoomVideoDetails(playerResponse);
    id description = YTzoomStreamObject(details,
        @[@"shortDescription", @"videoDescription", @"descriptionText"]);
    return [description isKindOfClass:NSString.class]
        ? description : @"";
}

+ (NSString *)videoIDFromPlayerResponse:(id)playerResponse {
    id details = YTzoomVideoDetails(playerResponse);
    id videoID = YTzoomStreamObject(details, @[@"videoId", @"videoID"]);
    if (![videoID isKindOfClass:NSString.class] || [videoID length] == 0) {
        videoID = YTzoomStreamObject(playerResponse, @[@"videoId", @"videoID"]);
    }
    return [videoID isKindOfClass:NSString.class] ? videoID : nil;
}

+ (NSURL *)thumbnailURLFromPlayerResponse:(id)playerResponse {
    id details = YTzoomVideoDetails(playerResponse);
    id thumbnail = YTzoomStreamObject(details, @[@"thumbnail"]);
    NSArray *items = YTzoomArrayValue(thumbnail, @[@"thumbnailsArray", @"thumbnails"]);
    id candidate = items.lastObject;
    return YTzoomURLValue(YTzoomStreamObject(candidate, @[@"URL", @"url"]));
}

@end
