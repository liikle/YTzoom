#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../../UI/OverlayButtonHost.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const YTzoomTranscriptKey =
    @"YTzoom.Preference.Playback.Transcript";

static id YTzoomTranscriptSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    if (receiver == nil || ![receiver respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id YTzoomTranscriptPlayer(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder respondsToSelector:NSSelectorFromString(@"activeVideo")]) {
            return responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static NSArray *YTzoomTranscriptTracks(id player) {
    id video = YTzoomTranscriptSend(player, @"activeVideo");
    id tracks = YTzoomTranscriptSend(video, @"availableCaptionTracks")
        ?: YTzoomTranscriptSend(player, @"availableCaptionTracks");
    return [tracks isKindOfClass:NSArray.class] ? tracks : nil;
}

static NSString *YTzoomTrackLabel(id track) {
    NSString *name = YTzoomTranscriptSend(track, @"displayName");
    if ([name isKindOfClass:NSString.class] && name.length != 0) return name;
    NSString *language = YTzoomTranscriptSend(track, @"languageCode");
    if ([language isKindOfClass:NSString.class] && language.length != 0) {
        return language;
    }
    return YTzoomLocalized(@"Captions");
}

static NSURL *YTzoomTrackJSONURL(id track) {
    id value = YTzoomTranscriptSend(track, @"URL");
    NSURL *URL = [value isKindOfClass:NSURL.class] ? value
        : ([value isKindOfClass:NSString.class]
            ? [NSURL URLWithString:value] : nil);
    if (URL == nil) return nil;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (components == nil) return URL;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL ?: URL;
}

static NSString *YTzoomTimestamp(double seconds) {
    if (seconds < 0.0) seconds = 0.0;
    const NSInteger total = (NSInteger)seconds;
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total % 3600) / 60;
    const NSInteger remainder = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
                (long)hours, (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
            (long)minutes, (long)remainder];
}

static NSString *YTzoomParseTranscript(NSData *data, BOOL timestamps) {
    if (data.length == 0) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0
                                                           error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    NSArray *events = root[@"events"];
    if (![events isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSArray *segments = event[@"segs"];
        if (![segments isKindOfClass:NSArray.class]) continue;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class]) continue;
            NSString *text = segment[@"utf8"];
            if ([text isKindOfClass:NSString.class]) [line appendString:text];
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) continue;
        if (timestamps) {
            NSNumber *start = event[@"tStartMs"];
            const double seconds = [start isKindOfClass:NSNumber.class]
                ? start.doubleValue / 1000.0 : 0.0;
            [lines addObject:[NSString stringWithFormat:@"[%@] %@",
                              YTzoomTimestamp(seconds), trimmed]];
        } else {
            [lines addObject:trimmed];
        }
    }
    if (lines.count == 0) return nil;
    return [lines componentsJoinedByString:timestamps ? @"\n" : @" "];
}


static id YTzoomProbe(id object, NSArray<NSString *> *names) {
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if (object != nil && [object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        }
    }
    return nil;
}

static NSString *YTzoomFormattedText(id value);

static NSURL *YTzoomURLFromValue(id value) {
    if ([value isKindOfClass:NSURL.class]) return value;
    if ([value isKindOfClass:NSString.class]) return [NSURL URLWithString:value];
    id nested = YTzoomProbe(value, @[@"baseUrl", @"URL", @"url", @"privateDoNotAccessOrElseSafeUrlStringValue"]);
    if (nested != nil && nested != value) return YTzoomURLFromValue(nested);
    return nil;
}

NSArray<NSDictionary *> *YTzoomParseCaptionCues(NSData *data) {
    if (data.length == 0) return nil;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:data
                                                         options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class]) return nil;
    NSArray *events = root[@"events"];
    if (![events isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<NSDictionary *> *cues = [NSMutableArray array];
    for (NSDictionary *event in events) {
        if (![event isKindOfClass:NSDictionary.class]) continue;
        NSArray *segments = event[@"segs"];
        if (![segments isKindOfClass:NSArray.class]) continue;
        NSMutableString *line = [NSMutableString string];
        for (NSDictionary *segment in segments) {
            if (![segment isKindOfClass:NSDictionary.class]) continue;
            NSString *piece = segment[@"utf8"];
            if ([piece isKindOfClass:NSString.class]) [line appendString:piece];
        }
        NSString *trimmed = [line stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (trimmed.length == 0) continue;
        NSNumber *startMs = event[@"tStartMs"];
        NSNumber *durationMs = event[@"dDurationMs"];
        if (![startMs isKindOfClass:NSNumber.class]) continue;
        const double start = startMs.doubleValue / 1000.0;
        const double duration = [durationMs isKindOfClass:NSNumber.class]
            ? durationMs.doubleValue / 1000.0 : 2.0;
        [cues addObject:@{ @"start": @(start),
                           @"end": @(start + MAX(duration, 0.4)),
                           @"text": trimmed }];
    }
    return cues.count != 0 ? cues : nil;
}

static BOOL YTzoomSkipObject(id object) {
    return object == nil ||
        [object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSURL.class] ||
        [object isKindOfClass:NSValue.class];
}

static id YTzoomDeepCaptionTracks(id root, int depth, NSMutableSet *seen) {
    if (root == nil || depth < 0 || YTzoomSkipObject(root)) return nil;
    NSValue *identity = [NSValue valueWithNonretainedObject:root];
    if ([seen containsObject:identity]) return nil;
    [seen addObject:identity];
    if (seen.count > 400) return nil;

    id direct = YTzoomProbe(root, @[@"captionTracksArray", @"captionTracks"]);
    if ([direct isKindOfClass:NSArray.class] && [direct count] != 0) {
        YTzoomDownloadLog(@"subs", @"tracks on %@",
                          NSStringFromClass(object_getClass(root)));
        return direct;
    }
    if ([root isKindOfClass:NSArray.class]) {
        for (id child in (NSArray *)root) {
            id found = YTzoomDeepCaptionTracks(child, depth - 1, seen);
            if (found != nil) return found;
        }
        return nil;
    }
    for (Class cls = object_getClass(root); cls != Nil;
         cls = class_getSuperclass(cls)) {
        const char *name = class_getName(cls);
        if (strncmp(name, "NS", 2) == 0) break;
        unsigned int count = 0;
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        if (properties == NULL) continue;
        for (unsigned int index = 0; index < count; index++) {
            const char *attributes = property_getAttributes(properties[index]);
            if (attributes == NULL || attributes[1] != '@') continue;
            NSString *key = [NSString stringWithUTF8String:
                property_getName(properties[index])];
            if (key.length == 0) continue;
            if ([key hasPrefix:@"thumbnail"] || [key hasPrefix:@"streaming"] ||
                [key hasPrefix:@"adPlacement"] || [key hasPrefix:@"contents"]) {
                continue;
            }
            SEL getter = NSSelectorFromString(key);
            if (![root respondsToSelector:getter]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(root, getter);
            id found = YTzoomDeepCaptionTracks(value, depth - 1, seen);
            if (found != nil) {
                free(properties);
                return found;
            }
        }
        free(properties);
    }
    return nil;
}


NSArray *YTzoomCaptionTracksForResponse(id playerResponse) {
    id data = YTzoomProbe(playerResponse, @[@"playerData"]) ?: playerResponse;
    id captionsRoot = YTzoomProbe(data, @[@"captions"]);
    if (captionsRoot != nil) {
        NSMutableSet *budget = [NSMutableSet set];
        id found = YTzoomDeepCaptionTracks(captionsRoot, 6, budget);
        if ([found isKindOfClass:NSArray.class] && [found count] != 0) {
            YTzoomDownloadLog(@"subs", @"tracks via captions -> %lu",
                              (unsigned long)[found count]);
            return found;
        }
        YTzoomDownloadLog(@"subs", @"captions node %@ had no tracks",
                          NSStringFromClass(object_getClass(captionsRoot)));
    }
    id captions = YTzoomProbe(playerResponse, @[@"captions"]);
    id renderer = YTzoomProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    id tracks = YTzoomProbe(renderer, @[@"captionTracksArray", @"captionTracks"]);
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        NSMutableSet *seen = [NSMutableSet set];
        tracks = YTzoomDeepCaptionTracks(playerResponse, 6, seen);
    }
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        id data = YTzoomProbe(playerResponse, @[@"playerData", @"playerResponse"]);
        if (data != nil) {
            NSMutableSet *other = [NSMutableSet set];
            tracks = YTzoomDeepCaptionTracks(data, 6, other);
        }
    }
    YTzoomDownloadLog(@"subs", @"tracks for %@ -> %lu",
                      NSStringFromClass(object_getClass(playerResponse)),
                      (unsigned long)([tracks isKindOfClass:NSArray.class]
                                          ? [tracks count] : 0));
    return [tracks isKindOfClass:NSArray.class] ? tracks : nil;
}


NSArray<NSDictionary *> *YTzoomCaptionChoicesForResponse(id playerResponse) {
    NSArray *tracks = YTzoomCaptionTracksForResponse(playerResponse);
    if (tracks.count == 0) return nil;
    NSMutableArray<NSDictionary *> *choices = [NSMutableArray array];
    for (id track in tracks) {
        NSURL *URL = YTzoomCaptionTrackURL(track);
        if (URL == nil) continue;
        [choices addObject:@{
            @"label": YTzoomCaptionTrackLabel(track),
            @"url": URL,
            @"language": YTzoomCaptionTrackLanguage(track) ?: @""
        }];
    }

    id data = YTzoomProbe(playerResponse, @[@"playerData"]) ?: playerResponse;
    id captions = YTzoomProbe(data, @[@"captions"]);
    id renderer = YTzoomProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    if (renderer == nil && captions != nil) {
        NSMutableSet *seen = [NSMutableSet set];
        renderer = YTzoomDeepCaptionTracks(captions, 4, seen) != nil
            ? captions : nil;
    }
    id languages = YTzoomProbe(renderer, @[@"translationLanguagesArray",
                                           @"translationLanguages"]);
    YTzoomDownloadLog(@"subs", @"translations=%lu",
                      (unsigned long)([languages isKindOfClass:NSArray.class]
                                          ? [languages count] : 0));
    NSMutableSet<NSString *> *seenCodes = [NSMutableSet set];
    for (NSDictionary *choice in choices) {
        NSString *code = choice[@"language"];
        if (code.length != 0) [seenCodes addObject:code];
    }
    NSURL *base = choices.firstObject[@"url"];
    if ([languages isKindOfClass:NSArray.class] && base != nil) {
        for (id language in (NSArray *)languages) {
            id codeValue = YTzoomProbe(language, @[@"languageCode"]);
            if (![codeValue isKindOfClass:NSString.class] ||
                [codeValue length] == 0) {
                continue;
            }
            if ([seenCodes containsObject:codeValue]) continue;
            [seenCodes addObject:codeValue];
            NSString *label = YTzoomFormattedText(
                YTzoomProbe(language, @[@"languageName"]));
            if (label.length == 0) {
                label = [NSLocale.currentLocale
                    localizedStringForLanguageCode:codeValue];
            }
            if (label.length == 0) label = [codeValue uppercaseString];
            NSURLComponents *components =
                [NSURLComponents componentsWithURL:base
                           resolvingAgainstBaseURL:NO];
            if (components == nil) continue;
            NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
            for (NSURLQueryItem *item in components.queryItems) {
                if ([item.name isEqualToString:@"tlang"]) continue;
                [items addObject:item];
            }
            [items addObject:[NSURLQueryItem queryItemWithName:@"tlang"
                                                         value:codeValue]];
            components.queryItems = items;
            if (components.URL == nil) continue;
            [choices addObject:@{
                @"label": [NSString stringWithFormat:@"%@ (auto)", label],
                @"url": components.URL,
                @"language": codeValue
            }];
        }
    }
    YTzoomDownloadLog(@"subs", @"choices=%lu", (unsigned long)choices.count);
    return choices.count != 0 ? choices : nil;
}

static NSString *YTzoomFormattedText(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return [value length] != 0 ? value : nil;
    }
    id simple = YTzoomProbe(value, @[@"simpleText", @"stringValue"]);
    if ([simple isKindOfClass:NSString.class] && [simple length] != 0) {
        return simple;
    }
    id runs = YTzoomProbe(value, @[@"runsArray", @"runs"]);
    if ([runs isKindOfClass:NSArray.class]) {
        NSMutableString *joined = [NSMutableString string];
        for (id run in (NSArray *)runs) {
            id text = YTzoomProbe(run, @[@"text"]);
            if ([text isKindOfClass:NSString.class]) [joined appendString:text];
        }
        if (joined.length != 0) return joined;
    }
    return nil;
}

NSString *YTzoomCaptionTrackLabel(id track) {
    NSString *text = YTzoomFormattedText(
        YTzoomProbe(track, @[@"name", @"displayName", @"trackName"]));
    if (text.length != 0) return text;
    id language = YTzoomProbe(track, @[@"languageCode"]);
    if ([language isKindOfClass:NSString.class] && [language length] != 0) {
        NSString *display = [NSLocale.currentLocale
            localizedStringForLanguageCode:language];
        return display.length != 0 ? display : [language uppercaseString];
    }
    return YTzoomLocalized(@"Captions");
}

NSString *YTzoomCaptionTrackLanguage(id track) {
    id language = YTzoomProbe(track, @[@"languageCode"]);
    return [language isKindOfClass:NSString.class] ? language : nil;
}

NSURL *YTzoomCaptionTrackURL(id track) {
    NSURL *URL = YTzoomURLFromValue(YTzoomProbe(track, @[@"baseUrl", @"baseURL"]));
    if (URL == nil) return nil;
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    if (components == nil) return URL;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL ?: URL;
}

void YTzoomFetchCuesForURL(NSURL *url,
                           void (^completion)(NSArray<NSDictionary *> *cues)) {
    if (url == nil) {
        completion(nil);
        return;
    }
    [[NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
        (void)response;
        NSArray<NSDictionary *> *cues =
            error != nil ? nil : YTzoomParseCaptionCues(data);
        YTzoomDownloadLog(@"subs", @"fetched %lu cues",
                          (unsigned long)cues.count);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(cues); });
    }] resume];
}

void YTzoomResolveCaptionTrack(id playerResponse,
                               void (^completion)(NSURL *url,
                                                  NSString *language)) {
    id captions = YTzoomProbe(playerResponse, @[@"captions"]);
    id renderer = YTzoomProbe(captions, @[@"playerCaptionsTracklistRenderer",
                                          @"playerCaptionsTrackListRenderer"]);
    id tracks = YTzoomProbe(renderer, @[@"captionTracksArray", @"captionTracks"]);
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        NSMutableSet *seen = [NSMutableSet set];
        tracks = YTzoomDeepCaptionTracks(playerResponse, 6, seen);
        if (tracks == nil) {
            id data = YTzoomProbe(playerResponse, @[@"playerData", @"playerResponse"]);
            if (data != nil) {
                NSMutableSet *other = [NSMutableSet set];
                tracks = YTzoomDeepCaptionTracks(data, 6, other);
            }
        }
    }
    YTzoomDownloadLog(@"subs", @"resolve root=%@ captions=%d renderer=%d tracks=%lu",
                      NSStringFromClass(object_getClass(playerResponse)),
                      captions != nil, renderer != nil,
                      (unsigned long)([tracks isKindOfClass:NSArray.class]
                                          ? [tracks count] : 0));
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0) {
        completion(nil, nil);
        return;
    }
    id track = [tracks firstObject];
    NSURL *URL = YTzoomURLFromValue(YTzoomProbe(track, @[@"baseUrl", @"baseURL"]));
    id languageValue = YTzoomProbe(track, @[@"languageCode"]);
    NSString *language = [languageValue isKindOfClass:NSString.class]
        ? languageValue : nil;
    if (URL == nil) {
        completion(nil, nil);
        return;
    }
    NSURLComponents *components =
        [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    completion(components.URL ?: URL, language);
}

void YTzoomFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *cues,
                                               NSString *language)) {
    YTzoomResolveCaptionTrack(playerResponse, ^(NSURL *url, NSString *language) {
        if (url == nil) {
            completion(nil, nil);
            return;
        }
        [[NSURLSession.sharedSession dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response,
                                NSError *error) {
            (void)response;
            NSArray<NSDictionary *> *cues =
                error != nil ? nil : YTzoomParseCaptionCues(data);
            YTzoomDownloadLog(@"subs", @"fetched %lu cues lang=%@",
                              (unsigned long)cues.count, language ?: @"?");
            completion(cues, language);
        }] resume];
    });
}

static UIViewController *YTzoomTranscriptPresenter(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow) key = window;
        }
    }
    UIViewController *controller = key.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static void YTzoomShareTranscript(NSString *text, UIView *sourceView) {
    UIViewController *presenter = YTzoomTranscriptPresenter();
    if (presenter == nil) return;
    UIActivityViewController *sheet =
        [[UIActivityViewController alloc] initWithActivityItems:@[text]
                                          applicationActivities:nil];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover != nil) {
        popover.sourceView = sourceView ?: presenter.view;
        popover.sourceRect = CGRectMake(
            CGRectGetMidX((sourceView ?: presenter.view).bounds),
            CGRectGetMidY((sourceView ?: presenter.view).bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [presenter presentViewController:sheet animated:YES completion:nil];
}

static void YTzoomFetchTranscript(id track,
                                  BOOL timestamps,
                                  void (^completion)(NSString *)) {
    NSURL *URL = YTzoomTrackJSONURL(track);
    if (URL == nil) {
        completion(nil);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:URL
      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *text = error != nil
            ? nil : YTzoomParseTranscript(data, timestamps);
        dispatch_async(dispatch_get_main_queue(), ^{ completion(text); });
    }];
    [task resume];
}

@interface YTzoomTranscriptCoordinator : NSObject
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *button;
+ (instancetype)sharedCoordinator;
- (void)presentTranscript;
@end

@implementation YTzoomTranscriptCoordinator

+ (instancetype)sharedCoordinator {
    static YTzoomTranscriptCoordinator *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [self new]; });
    return shared;
}

- (void)deliver:(id)track timestamps:(BOOL)timestamps share:(BOOL)share {
    __weak YTzoomTranscriptCoordinator *weakSelf = self;
    YTzoomShowNotice(YTzoomLocalized(@"Loading transcript…"));
    YTzoomFetchTranscript(track, timestamps, ^(NSString *text) {
        if (text.length == 0) {
            YTzoomShowNotice(YTzoomLocalized(@"No transcript available"));
            return;
        }
        if (share) {
            YTzoomShareTranscript(text, weakSelf.button);
            return;
        }
        UIPasteboard.generalPasteboard.string = text;
        YTzoomShowNotice(YTzoomLocalized(@"Transcript copied"));
    });
}

- (void)presentOptionsForTrack:(id)track {
    __weak YTzoomTranscriptCoordinator *weakSelf = self;
    YTzoomPresentNativeSheet(YTzoomLocalized(@"Transcript"),
                             YTzoomTrackLabel(track),
                             self.button, @[
        @{ @"title": YTzoomLocalized(@"Copy Text"),
           @"handler": ^{ [weakSelf deliver:track timestamps:NO share:NO]; } },
        @{ @"title": YTzoomLocalized(@"Copy With Timestamps"),
           @"handler": ^{ [weakSelf deliver:track timestamps:YES share:NO]; } },
        @{ @"title": YTzoomLocalized(@"Share…"),
           @"handler": ^{ [weakSelf deliver:track timestamps:YES share:YES]; } }
    ]);
}

- (void)presentTranscript {
    id player = YTzoomTranscriptPlayer(self.overlay);
    NSArray *tracks = YTzoomTranscriptTracks(player);
    if (tracks.count == 0) {
        YTzoomShowNotice(YTzoomLocalized(@"No captions for this video"));
        return;
    }
    if (tracks.count == 1) {
        [self presentOptionsForTrack:tracks.firstObject];
        return;
    }
    __weak YTzoomTranscriptCoordinator *weakSelf = self;
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    for (id track in tracks) {
        [actions addObject:@{
            @"title": YTzoomTrackLabel(track),
            @"handler": ^{ [weakSelf presentOptionsForTrack:track]; }
        }];
    }
    YTzoomPresentNativeSheet(YTzoomLocalized(@"Transcript"),
                             YTzoomLocalized(@"Choose a caption track"),
                             self.button, actions);
}

@end

void YTzoomInstallTranscriptHooks(void) {
    YTzoomRegisterOverlayConfigurator(@"transcript",
        ^(UIView *overlay, UIStackView *stack) {
        YTzoomTranscriptCoordinator *coordinator =
            YTzoomTranscriptCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;
        UIButton *button = YTzoomOverlayButton(
            stack,
            @"YTzoom Transcript",
            @"text.bubble",
            coordinator,
            @selector(presentTranscript)
        );
        coordinator.button = button;
        button.hidden = !YTzoomFeatureEnabled(YTzoomTranscriptKey);
    });
}
