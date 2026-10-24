#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"
#import "../Downloads/SABRDownloader.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static NSString *const YTzoomQueueKey = @"YTzoom.Preference.Playback.LocalQueue";

static NSString *YTzoomQueueClip(id object, NSUInteger limit);
static NSUInteger YTzoomQueueIndexOfVideo(NSString *videoID);
static NSUInteger YTzoomQueueEnsureCurrent(void);
static id YTzoomQueueItemMenu(NSString *videoID);
static BOOL YTzoomQueueIsActive(void);
static NSString *YTzoomQueueCurrentVideoID(void);
static id YTzoomQueueValue(id object, NSArray<NSString *> *keys);
static id YTzoomQueueSentinelCommand(NSString *action, NSString *videoID);
static void YTzoomQueueRefreshPanel(void);
static void YTzoomQueueRebuildWatchPage(void);
static void YTzoomQueueRestoreLoopMode(id controller);
static long long YTzoomQueueSavedLoopMode(void);
static void YTzoomQueueStoreLoopMode(long long mode);
static void YTzoomQueueApplyLoopMode(id controller, long long mode);
static void YTzoomQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex);

static IMP OriginalDiscoveryExecute;
static IMP OriginalPanelParse;
static IMP OriginalResponsePanel;
static IMP OriginalSetWatchNext;
static IMP OriginalPrepareWatchNext;
static IMP OriginalViewUpdateWatchNext;
static IMP OriginalPanelInit;
static IMP OriginalPanelInitQueue;
static IMP OriginalQueueControllerInit;
static IMP OriginalDidPressNext;
static IMP OriginalDidPressPrevious;
static IMP OriginalAutonavPlayNext;
static IMP OriginalMoveItem;
static IMP OriginalRemoveItem;
static IMP OriginalRemoveIndex;
static IMP OriginalClearQueue;
static IMP OriginalIsQueue;
static IMP OriginalHasQueueContents;
static IMP OriginalCanMoveItem;
static IMP OriginalNextVideoTitle;
static IMP OriginalNextVideoIndex;
static IMP OriginalReplaceAutoplay;
static IMP OriginalSetCanReorder;
static IMP OriginalAllowsReordering;
static IMP OriginalCellControllerSetCell;
static IMP OriginalCellPrepareForReuse;
static IMP OriginalAlphaForIndex;
static IMP OriginalUpdateCellForIndex;
static IMP OriginalSlideLayoutSubviews;
static NSTimeInterval YTzoomQueueActiveVideoTime;
static IMP OriginalSetVideoCountText;
static IMP OriginalDidTapShuffle;
static IMP OriginalDidTapLoop;
static IMP OriginalDidTapAction;
static IMP OriginalAutonavHasNext;
static IMP OriginalAutonavHasPrevious;
static IMP OriginalQueueHasNext;
static IMP OriginalQueueHasPrevious;
static IMP OriginalNextNavigable;
static IMP OriginalPreviousNavigable;
static IMP OriginalPanelByline;
static NSString *const YTzoomQueueLoopKey = @"YTzoom.Preference.Playback.QueueLoopMode";
static __weak id YTzoomQueuePlayerViewController;
static NSString *YTzoomQueueCurrentOverride;
static NSString *YTzoomQueueActiveVideo;
static __weak id YTzoomQueuePanelController;
static __weak id YTzoomQueueControllerInstance;
static id YTzoomLastWatchNextResponse;
static BOOL YTzoomQueuePanelInjected;
static __weak id YTzoomQueueWatchViewController;
static IMP OriginalRouterHandle;
static IMP OriginalRouterHandleCompletion;
static IMP OriginalScopedRouterHandle;
static IMP OriginalScopedRouterHandleCompletion;

static NSMutableArray<NSDictionary *> *YTzoomQueueItems;
static __weak id YTzoomQueueResponder;
static NSString *YTzoomQueueActiveVideoID;
static NSString *YTzoomQueueAdvancedFromVideoID;

static NSString *YTzoomQueueStorePath(void) {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (documents.length == 0) return nil;
    NSString *folder = [documents stringByAppendingPathComponent:@"YTzoom"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    return [folder stringByAppendingPathComponent:@"queue.plist"];
}

static void YTzoomQueueSave(void) {
    NSString *path = YTzoomQueueStorePath();
    if (path.length == 0) return;
    if (YTzoomQueueItems.count == 0) {
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        return;
    }
    [YTzoomQueueItems writeToFile:path atomically:YES];
}

static NSMutableArray<NSDictionary *> *YTzoomQueue(void) {
    if (YTzoomQueueItems != nil) return YTzoomQueueItems;
    NSString *path = YTzoomQueueStorePath();
    NSArray *stored = path.length != 0
        ? [NSArray arrayWithContentsOfFile:path]
        : nil;
    YTzoomQueueItems = stored != nil ? [stored mutableCopy] : [NSMutableArray array];
    return YTzoomQueueItems;
}

BOOL YTzoomQueueHasItems(void) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSUInteger current = YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
    if (current == NSNotFound) return YTzoomQueue().count != 0;
    return current + 1 < YTzoomQueue().count;
}

BOOL YTzoomQueueOwnsCurrentVideo(void) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    return YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID()) != NSNotFound;
}

static NSString *YTzoomQueueVideoIDFromParams(NSData *data, int *position) {
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    const NSUInteger length = data.length;
    if (position != NULL) *position = 0;
    for (NSUInteger index = 0; index + 1 < length; index++) {
        if (bytes[index] == 0x08 && (bytes[index + 1] == 0x02 ||
                                     bytes[index + 1] == 0x03)) {
            if (position != NULL) *position = bytes[index + 1];
            break;
        }
    }
    for (NSUInteger index = 0; index + 12 < length; index++) {
        if (bytes[index] != 0x0a || bytes[index + 1] != 0x0b) continue;
        NSString *candidate = [[NSString alloc]
            initWithBytes:bytes + index + 2 length:11
                 encoding:NSUTF8StringEncoding];
        if (candidate.length != 11) continue;
        NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"]
            invertedSet];
        if ([candidate rangeOfCharacterFromSet:invalid].location != NSNotFound) {
            continue;
        }
        return candidate;
    }
    return nil;
}

static NSString *YTzoomQueueDiscoveryParams(id command) {
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    if (![dump containsString:@"discovery_params"]) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:@"discovery_params:\\s*\"([^\"]+)\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return nil;
    return [dump substringWithRange:[match rangeAtIndex:1]];
}

static NSString *YTzoomQueueTitleNearView(id view) {
    UIView *current = [view isKindOfClass:UIView.class] ? view : nil;
    NSString *best = nil;
    for (NSUInteger depth = 0; depth < 6 && current != nil; depth++) {
        NSString *label = current.accessibilityLabel;
        if (label.length > best.length) best = label;
        current = current.superview;
    }
    if (best.length < 6) return nil;
    return best;
}


static void YTzoomQueueUpdateEntry(NSString *videoID, NSString *title,
                                   NSString *author, NSString *length) {
    if (videoID.length == 0 || title.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *queue = YTzoomQueue();
        for (NSUInteger index = 0; index < queue.count; index++) {
            if (![queue[index][@"videoId"] isEqualToString:videoID]) continue;
            NSMutableDictionary *entry = [queue[index] mutableCopy];
            entry[@"title"] = title;
            if (author.length != 0) entry[@"author"] = author;
            if (length.length != 0) entry[@"length"] = length;
            queue[index] = entry;
            YTzoomQueueSave();
            YTzoomQueueRefreshPanel();
            break;
        }
    });
}


static id YTzoomQueueValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector]) continue;
        NSMethodSignature *signature =
            [object methodSignatureForSelector:selector];
        const char *type = signature.methodReturnType;
        if (type == NULL) continue;
        if (strcmp(type, @encode(id)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            void *raw = NULL;
            [invocation getReturnValue:&raw];
            id value = (__bridge id)raw;
            if (value != nil) return value;
            continue;
        }
        if (strcmp(type, @encode(int)) == 0 ||
            strcmp(type, @encode(unsigned int)) == 0 ||
            strcmp(type, @encode(long long)) == 0 ||
            strcmp(type, @encode(unsigned long long)) == 0) {
            NSInvocation *invocation =
                [NSInvocation invocationWithMethodSignature:signature];
            invocation.selector = selector;
            [invocation invokeWithTarget:object];
            long long number = 0;
            [invocation getReturnValue:&number];
            if (number != 0) return @(number);
        }
    }
    return nil;
}

static id YTzoomQueueVideoDetails(id response) {
    id details = YTzoomQueueValue(response, @[@"videoDetails"]);
    if (details != nil) return details;
    for (NSString *wrapper in @[@"playerData", @"playerResponse",
                                @"playerResponseData"]) {
        id inner = YTzoomQueueValue(response, @[wrapper]);
        details = YTzoomQueueValue(inner, @[@"videoDetails"]);
        if (details != nil) return details;
    }
    return nil;
}

static NSString *YTzoomQueueLengthText(NSString *seconds) {
    const NSInteger total = seconds.integerValue;
    if (total <= 0) return nil;
    const NSInteger hours = total / 3600;
    const NSInteger minutes = (total % 3600) / 60;
    const NSInteger remainder = total % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours,
            (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes,
        (long)remainder];
}

static void YTzoomQueueFetchFromOEmbed(NSString *videoID) {
    NSString *address = [NSString stringWithFormat:
        @"https://www.youtube.com/oembed?url=https%%3A%%2F%%2Fwww.youtube.com"
        @"%%2Fwatch%%3Fv%%3D%@&format=json", videoID];
    NSURL *url = [NSURL URLWithString:address];
    if (url == nil) return;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:url
      completionHandler:^(NSData *data, __unused NSURLResponse *response,
                          __unused NSError *error) {
        if (data.length == 0) return;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
            options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) return;
        YTzoomQueueUpdateEntry(videoID, json[@"title"], json[@"author_name"],
                               nil);
    }];
    [task resume];
}

static void YTzoomQueueFetchTitle(NSString *videoID) {
    if (videoID.length == 0) return;
    static NSMutableSet<NSString *> *pending;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pending = [NSMutableSet set];
    });
    @synchronized (pending) {
        if ([pending containsObject:videoID]) return;
        [pending addObject:videoID];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @synchronized (pending) {
            [pending removeObject:videoID];
        }
    });
    YTzoomQueueFetchFromOEmbed(videoID);
    YTzoomResolvePlayerResponse(videoID, ^(id response, __unused NSError *error) {
        id details = YTzoomQueueVideoDetails(response);
        id rawTitle = YTzoomQueueValue(details, @[@"title"]);
        NSString *title = [rawTitle isKindOfClass:NSString.class] ? rawTitle : nil;
        id rawAuthor = YTzoomQueueValue(details,
            @[@"author", @"channelTitle", @"ownerChannelName"]);
        NSString *author = [rawAuthor isKindOfClass:NSString.class]
            ? rawAuthor : nil;
        id rawSeconds = YTzoomQueueValue(details,
            @[@"lengthSeconds", @"lengthSecondsString", @"videoLengthSeconds"]);
        NSString *seconds = nil;
        if ([rawSeconds isKindOfClass:NSString.class]) {
            seconds = rawSeconds;
        } else if ([rawSeconds isKindOfClass:NSNumber.class]) {
            seconds = [rawSeconds stringValue];
        }
        NSString *length = YTzoomQueueLengthText(seconds);

        if (title.length != 0) {
            YTzoomQueueUpdateEntry(videoID, title, author, length);
        }
    });
}

static void YTzoomQueueAdd(NSString *videoID, NSString *title,
                           BOOL playNext) {
    NSMutableArray *queue = YTzoomQueue();
    NSUInteger existing = YTzoomQueueIndexOfVideo(videoID);
    if (existing != NSNotFound) [queue removeObjectAtIndex:existing];
    if (queue.count == 0) {
        NSString *playing = YTzoomQueueCurrentVideoID();
        if (playing.length != 0 && ![playing isEqualToString:videoID]) {
            NSMutableDictionary *seed = [NSMutableDictionary dictionary];
            seed[@"videoId"] = playing;
            [queue addObject:seed];
            YTzoomQueueFetchTitle(playing);
        }
    }
    NSUInteger currentIndex = YTzoomQueueEnsureCurrent();
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"videoId"] = videoID;
    if (title.length != 0) item[@"title"] = title;
    if (playNext && currentIndex != NSNotFound) {
        [queue insertObject:item atIndex:currentIndex + 1];
    } else {
        [queue addObject:item];
    }
    YTzoomQueueSave();
    if (title.length == 0) YTzoomQueueFetchTitle(videoID);
    YTzoomShowNotice(playNext ? YTzoomLocalized(@"Playing next")
                              : YTzoomLocalized(@"Added to queue"));
    YTzoomQueueAppendToController(item, YTzoomQueueIndexOfVideo(videoID));
    if (!YTzoomQueuePanelInjected || queue.count <= 2) {
        YTzoomQueueRebuildWatchPage();
    }
    YTzoomQueueRefreshPanel();
}

static BOOL YTzoomQueuePlay(NSString *videoID) {
    id responder = YTzoomQueueResponder;
    Class endpointClass = NSClassFromString(@"YTIWatchEndpoint");
    Class commandClass = NSClassFromString(@"YTICommand");
    Class eventClass = NSClassFromString(@"YTCommandResponderEvent");
    if (responder == nil || endpointClass == Nil || commandClass == Nil ||
        eventClass == Nil) {
        return NO;
    }
    @try {
        id endpoint = ((id (*)(id, SEL))objc_msgSend)(endpointClass,
            @selector(message));
        [endpoint setValue:videoID forKey:@"videoId"];
        id command = ((id (*)(id, SEL))objc_msgSend)(commandClass,
            @selector(message));
        [command setValue:endpoint forKey:@"watchEndpoint"];
        id event = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
            eventClass,
            @selector(eventWithCommand:fromView:displayTitle:firstResponder:),
            command, nil, nil, responder);
        if (event == nil) return NO;
        ((void (*)(id, SEL))objc_msgSend)(event, @selector(send));
    } @catch (NSException *exception) {
        return NO;
    }
    YTzoomQueueActiveVideo = videoID;
    YTzoomQueueActiveVideoTime = NSDate.timeIntervalSinceReferenceDate;
    return YES;
}

static BOOL YTzoomQueueReplayCurrent(void) {
    id player = YTzoomQueuePlayerViewController;
    if (player == nil) return NO;
    @try {
        if ([player respondsToSelector:@selector(replayWithSeekSource:)]) {
            ((void (*)(id, SEL, int))objc_msgSend)(player,
                @selector(replayWithSeekSource:), 0);
            return YES;
        }
        if ([player respondsToSelector:@selector(seekToTime:)]) {
            ((void (*)(id, SEL, double))objc_msgSend)(player,
                @selector(seekToTime:), 0.0);
            if ([player respondsToSelector:@selector(play)]) {
                ((void (*)(id, SEL))objc_msgSend)(player, @selector(play));
            }
            return YES;
        }
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return NO;
}

static BOOL YTzoomQueueStep(NSInteger offset) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSArray *queue = [YTzoomQueue() copy];
    NSUInteger current = YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
    if (current == NSNotFound) return NO;
    const long long loop = YTzoomQueueSavedLoopMode();
    NSInteger target = (NSInteger)current + offset;
    if (loop == 2) return YTzoomQueueReplayCurrent();
    if (target < 0 || target >= (NSInteger)queue.count) {
        if (loop != 1 || queue.count == 0) return NO;
        target = target < 0 ? (NSInteger)queue.count - 1 : 0;
    }
    NSString *videoID = queue[(NSUInteger)target][@"videoId"];
    if (videoID.length == 0) return NO;
    return YTzoomQueuePlay(videoID);
}

static long long YTzoomQueueLoopMode(void) {
    return YTzoomQueueSavedLoopMode();
}

static void YTzoomQueueAdvance(void) {
    NSArray *queue = [YTzoomQueue() copy];
    NSString *currentID = YTzoomQueueCurrentVideoID();
    NSUInteger current = YTzoomQueueIndexOfVideo(currentID);
    if (current == NSNotFound) return;
    const long long loop = YTzoomQueueLoopMode();
    if (loop == 2) {
        YTzoomQueueReplayCurrent();
        return;
    }
    if (current + 1 >= queue.count) {
        if (loop != 1 || queue.count == 0) return;
        NSString *first = queue.firstObject[@"videoId"];
        if (first.length != 0) YTzoomQueuePlay(first);
        return;
    }
    (void)currentID;
    NSString *videoID = queue[current + 1][@"videoId"];
    if (videoID.length == 0) return;
    YTzoomQueuePlay(videoID);
}

static id YTzoomQueueMessage(NSString *className) {
    Class cls = NSClassFromString(className);
    if (cls == Nil) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(message));
}

static id YTzoomQueueFormatted(NSString *text) {
    Class cls = NSClassFromString(@"YTIFormattedString");
    if (cls == Nil || text.length == 0) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        cls, @selector(formattedStringWithString:), text);
}

static id YTzoomQueueWatchCommand(NSString *videoID) {
    id endpoint = YTzoomQueueMessage(@"YTIWatchEndpoint");
    id command = YTzoomQueueMessage(@"YTICommand");
    if (endpoint == nil || command == nil) return nil;
    [endpoint setValue:videoID forKey:@"videoId"];
    [endpoint setValue:@0 forKey:@"startTimeSeconds"];
    [command setValue:endpoint forKey:@"watchEndpoint"];
    return command;
}

static NSString *YTzoomQueueTitleForVideo(NSString *videoID, NSString *stored) {
    if (stored.length != 0) return stored;
    id response = YTzoomCachedPlayerResponse(videoID);
    if (response == nil) return nil;
    @try {
        id details = [response valueForKey:@"videoDetails"];
        id title = [details valueForKey:@"title"];
        if ([title isKindOfClass:NSString.class] && [title length] != 0) {
            return title;
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return nil;
}

static void YTzoomQueueSafeSet(id object, id value, NSString *key) {
    if (object == nil) return;
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
        static NSMutableSet<NSString *> *reported;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ reported = [NSMutableSet set]; });
        NSString *name = [NSString stringWithFormat:@"%@.%@", NSStringFromClass([object class]), key];
        @synchronized (reported) {
            if ([reported containsObject:name]) return;
            [reported addObject:name];
        }
        YTzoomDownloadLog(@"queue", @"skipped unsupported field %@", name);
    }
}

static id YTzoomQueuePanelItem(NSString *videoID, NSString *title,
                               NSString *author, NSString *length,
                               BOOL selected, NSUInteger index) {
    id renderer = YTzoomQueueMessage(@"YTIPlaylistPanelVideoRenderer");
    id wrapper = YTzoomQueueMessage(
        @"YTIPlaylistPanelRenderer_PlaylistPanelVideoSupportedRenderers");
    if (renderer == nil || wrapper == nil) return nil;
    YTzoomQueueSafeSet(renderer, videoID, @"videoId");
    YTzoomQueueSafeSet(renderer, videoID, @"playlistSetVideoId");
    id titleText = YTzoomQueueFormatted(
        YTzoomQueueTitleForVideo(videoID, title) ?: videoID);
    if (titleText != nil) YTzoomQueueSafeSet(renderer, titleText, @"title");
    id indexText = YTzoomQueueFormatted(
        [NSString stringWithFormat:@"%lu", (unsigned long)(index + 1)]);
    if (indexText != nil) YTzoomQueueSafeSet(renderer, indexText, @"indexText");
    id thumbnails = YTzoomQueueMessage(@"YTIThumbnailDetails");
    if (thumbnails != nil) {
        NSArray<NSArray *> *sizes = @[@[@"mqdefault", @320, @180],
                                      @[@"hqdefault", @480, @360]];
        for (NSArray *size in sizes) {
            id thumbnail = YTzoomQueueMessage(@"YTIThumbnailDetails_Thumbnail");
            if (thumbnail == nil) continue;
            YTzoomQueueSafeSet(thumbnail, [NSString stringWithFormat:
                @"https://i.ytimg.com/vi/%@/%@.jpg", videoID, size[0]], @"URL");
            YTzoomQueueSafeSet(thumbnail, size[1], @"width");
            YTzoomQueueSafeSet(thumbnail, size[2], @"height");
            [[thumbnails valueForKey:@"thumbnailsArray"] addObject:thumbnail];
        }
        YTzoomQueueSafeSet(renderer, thumbnails, @"thumbnail");
    }
    id style = YTzoomQueueMessage(@"YTIMainAppCompactRendererStyle");
    if (style != nil) {
        YTzoomQueueSafeSet(style, @2, @"value");
        YTzoomQueueSafeSet(renderer, style, @"mainAppStyle");
    }
    if (length.length != 0) {
        id overlay = YTzoomQueueMessage(@"YTIThumbnailOverlaySupportedRenderers");
        id timeStatus =
            YTzoomQueueMessage(@"YTIThumbnailOverlayTimeStatusRenderer");
        id overlayText = YTzoomQueueFormatted(length);
        if (overlay != nil && timeStatus != nil && overlayText != nil) {
            YTzoomQueueSafeSet(timeStatus, overlayText, @"text");
            YTzoomQueueSafeSet(overlay, timeStatus, @"thumbnailOverlayTimeStatusRenderer");
            [[renderer valueForKey:@"thumbnailOverlaysArray"]
                addObject:overlay];
        }
    }
    id menu = YTzoomQueueItemMenu(videoID);
    if (menu != nil) YTzoomQueueSafeSet(renderer, menu, @"menu");
    id removeCommand = YTzoomQueueSentinelCommand(@"remove", videoID);
    if (removeCommand != nil) {
        YTzoomQueueSafeSet(renderer, removeCommand, @"onSwipeLeftCommand");
        YTzoomQueueSafeSet(renderer, removeCommand, @"onItemRemovedCommand");
    }
    if (!selected) {
        id swipe = YTzoomQueueMessage(
            @"YTIPlaylistPanelVideoSwipeToRevealButtonSupportedRenderers");
        id button = YTzoomQueueMessage(@"YTIButtonRenderer");
        id swipeCommand = YTzoomQueueSentinelCommand(@"remove", videoID);
        if (swipe != nil && button != nil && swipeCommand != nil) {
            id label = YTzoomQueueFormatted(YTzoomLocalized(@"Remove"));
            if (label != nil) YTzoomQueueSafeSet(button, label, @"text");
            YTzoomQueueSafeSet(button, swipeCommand, @"serviceEndpoint");
            YTzoomQueueSafeSet(swipe, button, @"buttonRenderer");
            [[renderer valueForKey:@"swipeButtonsArray"] addObject:swipe];
        }
    }
    id byline = YTzoomQueueFormatted(author);
    if (byline != nil) {
        YTzoomQueueSafeSet(renderer, byline, @"shortBylineText");
        YTzoomQueueSafeSet(renderer, byline, @"longBylineText");
    }
    id command = YTzoomQueueWatchCommand(videoID);
    if (command != nil) YTzoomQueueSafeSet(renderer, command, @"navigationEndpoint");
    YTzoomQueueSafeSet(renderer, @(selected), @"selected");
    YTzoomQueueSafeSet(wrapper, renderer, @"playlistPanelVideoRenderer");
    return wrapper;
}

static NSUInteger YTzoomQueueIndexOfVideo(NSString *videoID) {
    if (videoID.length == 0) return NSNotFound;
    NSArray *queue = YTzoomQueue();
    for (NSUInteger index = 0; index < queue.count; index++) {
        if ([queue[index][@"videoId"] isEqualToString:videoID]) return index;
    }
    return NSNotFound;
}

static NSString *YTzoomQueueCurrentVideoID(void) {
    if (YTzoomQueueCurrentOverride.length != 0) {
        return YTzoomQueueCurrentOverride;
    }
    id player = YTzoomQueuePlayerViewController;
    id playerValue =
        YTzoomQueueValue(player, @[@"currentVideoID", @"contentVideoID"]);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    const NSTimeInterval age =
        NSDate.timeIntervalSinceReferenceDate - YTzoomQueueActiveVideoTime;
    const BOOL preferOwn =
        YTzoomQueueActiveVideo.length != 0 && age < 4.0;
    if (preferOwn) [candidates addObject:YTzoomQueueActiveVideo];
    if ([playerValue isKindOfClass:NSString.class] &&
        [playerValue length] != 0) {
        [candidates addObject:playerValue];
    }
    if (!preferOwn && YTzoomQueueActiveVideo.length != 0) {
        [candidates addObject:YTzoomQueueActiveVideo];
    }
    NSString *last = YTzoomLastVideoID();
    if (last.length != 0) [candidates addObject:last];
    for (NSString *candidate in candidates) {
        if (YTzoomQueueIndexOfVideo(candidate) != NSNotFound) return candidate;
    }
    return candidates.firstObject;
}

static NSUInteger YTzoomQueueEnsureCurrent(void) {
    NSString *current = YTzoomQueueCurrentVideoID();
    if (current.length == 0) return NSNotFound;
    if (YTzoomQueue().count == 0) return NSNotFound;
    NSUInteger index = YTzoomQueueIndexOfVideo(current);
    if (index != NSNotFound) return index;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"videoId"] = current;
    [YTzoomQueue() insertObject:entry atIndex:0];
    YTzoomQueueSave();
    YTzoomQueueFetchTitle(current);
    return 0;
}

static id YTzoomQueuePanelRenderer(void) {
    NSUInteger currentIndex = YTzoomQueueEnsureCurrent();
    NSArray<NSDictionary *> *queue = [YTzoomQueue() copy];
    if (queue.count < 2) return nil;
    id panel = YTzoomQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return nil;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    if (contents == nil) return nil;
    for (NSUInteger index = 0; index < queue.count; index++) {
        NSDictionary *entry = queue[index];
        NSString *videoID = entry[@"videoId"];
        if (videoID.length == 0) continue;
        if (entry[@"title"] == nil || entry[@"length"] == nil) {
            YTzoomQueueFetchTitle(videoID);
        }
        id item = YTzoomQueuePanelItem(videoID, entry[@"title"],
                                       entry[@"author"], entry[@"length"],
                                       index == currentIndex, index);
        if (item == nil) continue;
        [contents addObject:item];
    }
    if (contents.count == 0) return nil;
    [panel setValue:@"YTzoomQueue" forKey:@"playlistId"];
    [panel setValue:YTzoomLocalized(@"Queue") forKey:@"title"];
    id title = YTzoomQueueFormatted(YTzoomLocalized(@"Queue"));
    if (title != nil) [panel setValue:title forKey:@"titleText"];
    [panel setValue:@(contents.count) forKey:@"totalVideos"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"currentIndex"];
    [panel setValue:@(currentIndex == NSNotFound ? 0 : currentIndex)
             forKey:@"localCurrentIndex"];
    [panel setValue:@YES forKey:@"isEditable"];
    id reorder = YTzoomQueueSentinelCommand(@"reorder", @"");
    if (reorder != nil) [panel setValue:reorder forKey:@"onReorderEndpoint"];
    return panel;
}

static void YTzoomQueueAppendToController(NSDictionary *entry,
                                          NSUInteger insertIndex) {
    id controller = YTzoomQueueControllerInstance;
    if (controller == nil || entry[@"videoId"] == nil) return;
    SEL selector = @selector(addItemsFromPlaylistPanel:response:atIndex:
                             ignoreSelectedProperty:notifyObservers:);
    if (![controller respondsToSelector:selector]) return;
    id panel = YTzoomQueueMessage(@"YTIPlaylistPanelRenderer");
    if (panel == nil) return;
    NSMutableArray *contents = [panel valueForKey:@"contentsArray"];
    id item = YTzoomQueuePanelItem(entry[@"videoId"], entry[@"title"],
                                   entry[@"author"], entry[@"length"], NO,
                                   insertIndex);
    if (contents == nil || item == nil) return;
    [contents addObject:item];
    [panel setValue:@"YTzoomQueue" forKey:@"playlistId"];
    [panel setValue:@1 forKey:@"totalVideos"];
    @try {
        ((void (*)(id, SEL, id, id, unsigned long long, BOOL, BOOL))objc_msgSend)(
            controller, selector, panel, YTzoomLastWatchNextResponse,
            (unsigned long long)insertIndex, YES, YES);
    } @catch (NSException *exception) {
        return;
    }
}

static void YTzoomQueueRebuildWatchPage(void) {
    id watch = YTzoomQueueWatchViewController;
    id response = YTzoomLastWatchNextResponse;
    if (watch == nil || response == nil) return;
    if (YTzoomQueuePanelInjected) {
        YTzoomQueueRefreshPanel();
        return;
    }
    if (![watch respondsToSelector:@selector(updateWithWatchNextResponse:)]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(watch,
                @selector(updateWithWatchNextResponse:), response);
        } @catch (NSException *exception) {
            return;
        }
    });
}

static void YTzoomQueueRefreshPanel(void) {
    id controller = YTzoomQueuePanelController;
    if (controller == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id panel = YTzoomQueuePanelRenderer();
        if (panel == nil) return;
        @try {
            [controller setValue:panel forKey:@"playlistPanelRenderer"];
            if ([controller respondsToSelector:
                    @selector(refreshPlaylistCollectionViewController)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(refreshPlaylistCollectionViewController));
            }
            if ([controller respondsToSelector:
                    @selector(updateViewForCurrentVideo)]) {
                ((void (*)(id, SEL))objc_msgSend)(controller,
                    @selector(updateViewForCurrentVideo));
            }
        } @catch (NSException *exception) {
            return;
        }
        YTzoomQueueRestoreLoopMode(controller);
        id watchController = YTzoomQueueWatchViewController;
        if ([watchController respondsToSelector:
                @selector(showPlaylistMiniBarIfNeeded)]) {
            @try {
                ((void (*)(id, SEL))objc_msgSend)(watchController,
                    @selector(showPlaylistMiniBarIfNeeded));
            } @catch (__unused NSException *exception) {
            }
        }
    });
}

static id YTzoomQueuePanelParse(id receiver, SEL selector, id response) {
    id original = nil;
    if (OriginalPanelParse != NULL) {
        original = ((id (*)(id, SEL, id))OriginalPanelParse)(
            receiver, selector, response);
    }
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return original;
    if (YTzoomQueue().count == 0) return original;
    if (original != nil) {
        return original;
    }
    id panel = YTzoomQueuePanelRenderer();
    return panel ?: original;
}

static id YTzoomQueueResponsePanel(id receiver, SEL selector) {
    id original = NULL;
    if (OriginalResponsePanel != NULL) {
        original = ((id (*)(id, SEL))OriginalResponsePanel)(receiver, selector);
    }
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return original;
    if (YTzoomQueue().count == 0) return original;
    if (original != nil) return original;
    id panel = YTzoomQueuePanelRenderer();
    return panel ?: original;
}








static NSString *YTzoomQueuePanelField(id wrapper) {
    static NSString *cached;
    if (cached != nil) return cached;
    NSString *found = nil;
    SEL descriptorSel = NSSelectorFromString(@"descriptor");
    id descriptor = [[wrapper class] respondsToSelector:descriptorSel]
        ? ((id (*)(id, SEL))objc_msgSend)([wrapper class], descriptorSel) : nil;
    NSArray *fields = [descriptor respondsToSelector:NSSelectorFromString(@"fields")]
        ? [descriptor valueForKey:@"fields"] : nil;
    Class panelClass = NSClassFromString(@"YTIPlaylistPanelRenderer");
    for (id field in fields) {
        NSString *name = [field valueForKey:@"name"];
        if (![name isKindOfClass:NSString.class]) continue;
        SEL msgClassSel = NSSelectorFromString(@"msgClass");
        Class type = [field respondsToSelector:msgClassSel]
            ? ((Class (*)(id, SEL))objc_msgSend)(field, msgClassSel) : Nil;
        if (found == nil && panelClass != Nil && type == panelClass) found = name;
    }
    cached = found ?: @"playlist";
    return cached;
}

static void YTzoomQueueInjectPanel(id response) {
    YTzoomLastWatchNextResponse = response;
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return;
    if (YTzoomQueue().count == 0) return;
    @try {
        id contents = [response valueForKey:@"contents"];
        id single = [contents valueForKey:@"singleColumnWatchNextResults"];
        if (single == nil) return;
        id existing = [single valueForKey:@"playlist"];
        NSString *field = existing != nil ? YTzoomQueuePanelField(existing) : @"playlist";
        id current = existing != nil ? [existing valueForKey:field] : nil;
        id owner = current != nil ? YTzoomQueueValue(current, @[@"playlistId"]) : nil;
        if ([owner isKindOfClass:NSString.class] && [owner length] != 0) {
            if (![owner isEqual:@"YTzoomQueue"]) {
                    return;
            }
        }
        id panel = YTzoomQueuePanelRenderer();
        if (panel == nil) return;
        id wrapper = YTzoomQueueMessage(
            @"YTISingleColumnWatchNextResultsRenderer_"
            @"SingleColumnWatchNextPlaylistSupportedRenderers");
        if (wrapper == nil) return;
        [wrapper setValue:panel forKey:YTzoomQueuePanelField(wrapper)];
        [single setValue:wrapper forKey:@"playlist"];
        YTzoomQueuePanelInjected = YES;
    } @catch (__unused NSException *exception) {
    }
}

static void YTzoomQueueSetWatchNext(id receiver, SEL selector, id response) {
    YTzoomQueuePlayerViewController = receiver;
    id fresh = YTzoomQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    YTzoomQueueCurrentOverride =
        [fresh isKindOfClass:NSString.class] ? fresh : nil;
    if (YTzoomQueueCurrentOverride.length != 0) {
        YTzoomQueueActiveVideo = YTzoomQueueCurrentOverride;
        YTzoomQueueActiveVideoTime = 0;
    }
    YTzoomQueueInjectPanel(response);
    YTzoomQueueCurrentOverride = nil;
    if (OriginalSetWatchNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalSetWatchNext)(receiver, selector, response);
}

static void YTzoomQueuePrepareWatchNext(id receiver, SEL selector, id response) {
    YTzoomQueueInjectPanel(response);
    if (OriginalPrepareWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalPrepareWatchNext)(
            receiver, selector, response);
    }
}




static void YTzoomQueueViewUpdateWatchNext(id receiver, SEL selector,
                                           id response) {
    YTzoomQueueWatchViewController = receiver;
    YTzoomQueuePanelInjected = NO;
    YTzoomQueueInjectPanel(response);
    if (OriginalViewUpdateWatchNext != NULL) {
        ((void (*)(id, SEL, id))OriginalViewUpdateWatchNext)(
            receiver, selector, response);
    }
}


static void YTzoomQueueEnableEditing(id panelController, id queueController) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return;
    NSArray<NSString *> *flags = @[@"_enableSwipeToRemove",
                                   @"_enableQueueEditBuffer",
                                   @"_queuePhase4Enabled"];
    for (NSString *flag in flags) {
        @try {
            [panelController setValue:@YES forKey:flag];
        } @catch (__unused NSException *exception) {
        }
    }
    @try {
        [queueController setValue:@YES forKey:@"userModifiedQueue"];
    } @catch (__unused NSException *exception) {
    }
}

static id YTzoomQueuePanelInit(id receiver, SEL selector, id account,
                               id responder) {
    id result = NULL;
    if (OriginalPanelInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalPanelInit)(
            receiver, selector, account, responder);
    }
    YTzoomQueuePanelController = result;
    return result;
}

static id YTzoomQueuePanelInitQueue(id receiver, SEL selector, id account,
                                    id responder, id controller) {
    id result = NULL;
    if (OriginalPanelInitQueue != NULL) {
        result = ((id (*)(id, SEL, id, id, id))OriginalPanelInitQueue)(
            receiver, selector, account, responder, controller);
    }
    YTzoomQueuePanelController = result;
    YTzoomQueueControllerInstance = controller;
    YTzoomQueueEnableEditing(result, controller);
    YTzoomQueueRestoreLoopMode(result);
    return result;
}

static id YTzoomQueueControllerInit(id receiver, SEL selector, id account,
                                    id responder) {
    id result = NULL;
    if (OriginalQueueControllerInit != NULL) {
        result = ((id (*)(id, SEL, id, id))OriginalQueueControllerInit)(
            receiver, selector, account, responder);
    }
    YTzoomQueueControllerInstance = result;
    return result;
}

static BOOL YTzoomQueueIsActive(void) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    return YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID()) != NSNotFound;
}

static void YTzoomQueueDidPressNext(id receiver, SEL selector, id sender) {
    if (YTzoomQueueStep(1)) {
        return;
    }
    if (YTzoomQueueIsActive()) {
        return;
    }
    if (OriginalDidPressNext == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressNext)(receiver, selector, sender);
}

static void YTzoomQueueDidPressPrevious(id receiver, SEL selector, id sender) {
    if (YTzoomQueueStep(-1)) {
        return;
    }
    if (YTzoomQueueIsActive()) {
        return;
    }
    if (OriginalDidPressPrevious == NULL) return;
    ((void (*)(id, SEL, id))OriginalDidPressPrevious)(receiver, selector,
                                                      sender);
}

static void YTzoomQueueAutonavPlayNext(id receiver, SEL selector) {
    if (YTzoomQueueStep(1)) {
        return;
    }
    if (YTzoomQueueIsActive()) {
        return;
    }
    if (OriginalAutonavPlayNext == NULL) return;
    ((void (*)(id, SEL))OriginalAutonavPlayNext)(receiver, selector);
}


static void YTzoomQueueSyncFromController(id controller) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return;
    NSArray *items = nil;
    @try {
        items = [controller valueForKey:@"playbackQueueItems"];
    } @catch (__unused NSException *exception) {
        return;
    }
    NSMutableArray *ordered = [NSMutableArray array];
    for (id item in items) {
        NSString *videoID = nil;
        @try {
            videoID = [[item valueForKey:@"videoRenderer"] valueForKey:@"videoId"];
        } @catch (__unused NSException *exception) {
            videoID = nil;
        }
        if (videoID.length == 0) continue;
        NSUInteger existing = YTzoomQueueIndexOfVideo(videoID);
        if (existing == NSNotFound) continue;
        [ordered addObject:YTzoomQueue()[existing]];
    }
    if (ordered.count == 0) return;
    if (ordered.count == YTzoomQueue().count) {
        BOOL identical = YES;
        for (NSUInteger index = 0; index < ordered.count; index++) {
            if (ordered[index] == YTzoomQueue()[index]) continue;
            identical = NO;
            break;
        }
        if (identical) return;
    }
    [YTzoomQueue() setArray:ordered];
    YTzoomQueueSave();
}

static void YTzoomQueueMoveItem(id receiver, SEL selector, id from, id to,
                                BOOL triggered) {
    if (OriginalMoveItem != NULL) {
        ((void (*)(id, SEL, id, id, BOOL))OriginalMoveItem)(
            receiver, selector, from, to, triggered);
    }
    YTzoomQueueSyncFromController(receiver);
}

static void YTzoomQueueRemoveItem(id receiver, SEL selector, id path,
                                  BOOL triggered) {
    if (OriginalRemoveItem != NULL) {
        ((void (*)(id, SEL, id, BOOL))OriginalRemoveItem)(
            receiver, selector, path, triggered);
    }
    YTzoomQueueSyncFromController(receiver);
}

static void YTzoomQueueRemoveIndex(id receiver, SEL selector,
                                   unsigned long long index) {
    if (OriginalRemoveIndex != NULL) {
        ((void (*)(id, SEL, unsigned long long))OriginalRemoveIndex)(
            receiver, selector, index);
    }
    YTzoomQueueSyncFromController(receiver);
}

static void YTzoomQueueClearQueue(id receiver, SEL selector) {
    if (OriginalClearQueue != NULL) {
        ((void (*)(id, SEL))OriginalClearQueue)(receiver, selector);
    }
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return;
    [YTzoomQueue() removeAllObjects];
    YTzoomQueueSave();
}

static BOOL YTzoomQueueCanMoveItem(id receiver, SEL selector, id from, id to) {
    if (YTzoomQueueIsActive()) return YES;
    if (OriginalCanMoveItem == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id))OriginalCanMoveItem)(receiver, selector,
                                                            from, to);
}

static NSDictionary *YTzoomQueueUpcomingEntry(void) {
    NSArray *queue = [YTzoomQueue() copy];
    NSUInteger current = YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
    if (current == NSNotFound || current + 1 >= queue.count) return nil;
    return queue[current + 1];
}

static id YTzoomQueueNextVideoTitle(id receiver, SEL selector) {
    NSDictionary *entry = YTzoomQueueIsActive() ? YTzoomQueueUpcomingEntry()
                                                : nil;
    NSString *title = entry[@"title"];
    if (title.length != 0) return title;
    if (entry != nil) return entry[@"videoId"];
    if (OriginalNextVideoTitle == NULL) return nil;
    return ((id (*)(id, SEL))OriginalNextVideoTitle)(receiver, selector);
}

static long long YTzoomQueueNextVideoIndex(id receiver, SEL selector) {
    if (YTzoomQueueIsActive()) {
        NSUInteger current =
            YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
        if (current != NSNotFound && current + 1 < YTzoomQueue().count) {
            return (long long)(current + 1);
        }
    }
    if (OriginalNextVideoIndex == NULL) return -1;
    return ((long long (*)(id, SEL))OriginalNextVideoIndex)(receiver, selector);
}

static void YTzoomQueueReplaceAutoplay(id receiver, SEL selector, id response) {
    if (YTzoomQueueIsActive()) {
        return;
    }
    if (OriginalReplaceAutoplay == NULL) return;
    ((void (*)(id, SEL, id))OriginalReplaceAutoplay)(receiver, selector,
                                                     response);
}

static void YTzoomQueueCellControllerSetCell(id receiver, SEL selector,
                                             id cell) {
    if (YTzoomQueueIsActive()) {
        for (NSString *flag in @[@"_enableSwipeToRemove",
                                 @"_enableSwipeToRemoveInPlaylistWatchEp2"]) {
            @try {
                [receiver setValue:@YES forKey:flag];
            } @catch (__unused NSException *exception) {
            }
        }
    }
    if (OriginalCellControllerSetCell == NULL) return;
    ((void (*)(id, SEL, id))OriginalCellControllerSetCell)(receiver, selector,
                                                            cell);
}

static double YTzoomQueueAlphaForIndex(id receiver, SEL selector,
                                       unsigned long long index) {
    double value = 1.0;
    if (OriginalAlphaForIndex != NULL) {
        value = ((double (*)(id, SEL, unsigned long long))OriginalAlphaForIndex)(
            receiver, selector, index);
    }
    if (YTzoomQueueIsActive()) {
        if (value < 1.0) {
        }
        return 1.0;
    }
    return value;
}




static void YTzoomQueueClearSlideBackground(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 3) return;
    if ([NSStringFromClass([view class]) isEqualToString:
            @"YTSlideForActionsView"]) {
        view.backgroundColor = UIColor.clearColor;
        view.opaque = NO;
    }
    for (UIView *child in view.subviews) {
        YTzoomQueueClearSlideBackground(child, depth + 1);
    }
}

static void YTzoomQueueSlideLayoutSubviews(id receiver, SEL selector) {
    if (OriginalSlideLayoutSubviews != NULL) {
        ((void (*)(id, SEL))OriginalSlideLayoutSubviews)(receiver, selector);
    }
    if (!YTzoomQueueIsActive()) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *view = receiver;
    UIView *content = nil;
    @try {
        id value = [receiver valueForKey:@"contentView"];
        content = [value isKindOfClass:UIView.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        content = nil;
    }
    const BOOL sliding = content != nil &&
        fabs(CGRectGetMinX(content.frame)) > 0.5;
    view.backgroundColor = sliding
        ? [UIColor colorWithWhite:0.62 alpha:1.0]
        : UIColor.clearColor;
}

static void YTzoomQueueUpdateCellForIndex(id receiver, SEL selector, id cell,
                                          __unused long long index) {
    if (OriginalUpdateCellForIndex != NULL) {
        ((void (*)(id, SEL, id, long long))OriginalUpdateCellForIndex)(
            receiver, selector, cell, index);
    }
    if (!YTzoomQueueIsActive()) return;
    if ([cell isKindOfClass:UIView.class]) {
        YTzoomQueueClearSlideBackground(cell, 0);
    }
}

static void YTzoomQueueCellPrepareForReuse(id receiver, SEL selector) {
    @try {
        id button = [receiver valueForKey:@"_swipeToRevealButton"];
        if ([button isKindOfClass:UIView.class]) {
            UIView *view = button;
            view.hidden = YES;
            view.frame = CGRectZero;
        }
    } @catch (__unused NSException *exception) {
    }
    @try {
        [receiver setValue:@NO forKey:@"_isRemovingWithAnimation"];
    } @catch (__unused NSException *exception) {
    }
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = receiver;
        YTzoomQueueClearSlideBackground(cell, 0);
        cell.alpha = 1.0;
        cell.transform = CGAffineTransformIdentity;
        for (UIView *subview in cell.subviews) {
            subview.alpha = 1.0;
            subview.transform = CGAffineTransformIdentity;
        }
    }
    if (OriginalCellPrepareForReuse == NULL) return;
    ((void (*)(id, SEL))OriginalCellPrepareForReuse)(receiver, selector);
}

static void YTzoomQueueSetCanReorder(id receiver, SEL selector, BOOL value) {
    if (OriginalSetCanReorder == NULL) return;
    ((void (*)(id, SEL, BOOL))OriginalSetCanReorder)(receiver, selector,
        YTzoomQueueIsActive() ? YES : value);
}

static BOOL YTzoomQueueAllowsReordering(id receiver, SEL selector,
                                        CGPoint point) {
    if (YTzoomQueueIsActive()) return YES;
    if (OriginalAllowsReordering == NULL) return NO;
    return ((BOOL (*)(id, SEL, CGPoint))OriginalAllowsReordering)(
        receiver, selector, point);
}

static void YTzoomQueueSetVideoCountText(id receiver, SEL selector, id text,
                                         BOOL countHidden, BOOL shuffleEnabled,
                                         BOOL shuffleSelected,
                                         BOOL loopEnabled, BOOL loopSelected,
                                         BOOL saveEnabled, BOOL shareEnabled,
                                         BOOL saveSelected, BOOL actionEnabled,
                                         long long loopMode, id renderer,
                                         BOOL useRendererSaveIcons,
                                         BOOL headerHidden) {
    if (OriginalSetVideoCountText == NULL) return;
    if (YTzoomQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = YTzoomQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL, BOOL))OriginalSetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons, headerHidden);
}

static IMP OriginalLegacySetVideoCountText;
static IMP OriginalShouldShowPlaylist;

static void YTzoomQueueLegacySetVideoCountText(id receiver, SEL selector, id text,
                                               BOOL countHidden, BOOL shuffleEnabled,
                                               BOOL shuffleSelected,
                                               BOOL loopEnabled, BOOL loopSelected,
                                               BOOL saveEnabled, BOOL shareEnabled,
                                               BOOL saveSelected, BOOL actionEnabled,
                                               long long loopMode, id renderer,
                                               BOOL useRendererSaveIcons) {
    if (OriginalLegacySetVideoCountText == NULL) return;
    if (YTzoomQueueIsActive()) {
        shuffleEnabled = YES;
        loopEnabled = YES;
        actionEnabled = YES;
        loopMode = YTzoomQueueSavedLoopMode();
        loopSelected = loopMode != 0;
    }
    ((void (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL, BOOL,
               BOOL, long long, id, BOOL))OriginalLegacySetVideoCountText)(
        receiver, selector, text, countHidden, shuffleEnabled, shuffleSelected,
        loopEnabled, loopSelected, saveEnabled, shareEnabled, saveSelected,
        actionEnabled, loopMode, renderer, useRendererSaveIcons);
}

static BOOL YTzoomQueueShouldShowPlaylist(id receiver, SEL selector) {
    if (YTzoomQueuePanelController != receiver) {
        YTzoomQueuePanelController = receiver;
    }
    if (YTzoomQueueIsActive()) return YES;
    if (OriginalShouldShowPlaylist == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalShouldShowPlaylist)(receiver, selector);
}

static void YTzoomQueueDidTapShuffle(id receiver, SEL selector) {
    if (!YTzoomQueueIsActive()) {
        if (OriginalDidTapShuffle == NULL) return;
        ((void (*)(id, SEL))OriginalDidTapShuffle)(receiver, selector);
        return;
    }
    NSMutableArray *queue = YTzoomQueue();
    NSString *currentID = YTzoomQueueCurrentVideoID();
    NSUInteger current = YTzoomQueueIndexOfVideo(currentID);
    if (current == NSNotFound || queue.count < 3) return;
    NSDictionary *entry = queue[current];
    [queue removeObjectAtIndex:current];
    for (NSUInteger index = queue.count; index > 1; index--) {
        const uint32_t pick = arc4random_uniform((uint32_t)index);
        [queue exchangeObjectAtIndex:index - 1 withObjectAtIndex:pick];
    }
    [queue insertObject:entry atIndex:0];
    YTzoomQueueSave();
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (NSDictionary *item in queue) {
        [order addObject:item[@"videoId"] ?: @"?"];
    }
    YTzoomQueueRebuildWatchPage();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTzoomQueueRefreshPanel();
        YTzoomQueueApplyLoopMode(YTzoomQueuePanelController,
                                 YTzoomQueueSavedLoopMode());
    });
}

static long long YTzoomQueueSavedLoopMode(void) {
    id value = YTzoomPreferenceObject(YTzoomQueueLoopKey);
    return [value respondsToSelector:@selector(longLongValue)]
        ? [value longLongValue] : 0;
}

static void YTzoomQueueStoreLoopMode(long long mode) {
    YTzoomSetPreferenceObject(YTzoomQueueLoopKey, @(mode));
}

static void YTzoomQueueApplyLoopMode(id controller, long long mode) {
    if (controller == nil) return;
    @try {
        [controller setValue:@(mode) forKey:@"loopMode"];
    } @catch (__unused NSException *exception) {
    }
    id collection = nil;
    @try {
        collection =
            [controller valueForKey:@"playlistPanelCollectionViewController"];
    } @catch (__unused NSException *exception) {
        collection = nil;
    }
    if (collection == nil) return;
    @try {
        if ([collection respondsToSelector:@selector(setLoopButtonMode:)]) {
            ((void (*)(id, SEL, long long))objc_msgSend)(collection,
                @selector(setLoopButtonMode:), mode);
        }
        if ([collection respondsToSelector:@selector(setLoopButtonSelected:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(collection,
                @selector(setLoopButtonSelected:), mode != 0);
        }
    } @catch (__unused NSException *exception) {
    }
}

static void YTzoomQueueRestoreLoopMode(id controller) {
    if (controller == nil || !YTzoomQueueIsActive()) return;
    YTzoomQueueApplyLoopMode(controller, YTzoomQueueSavedLoopMode());
}

static void YTzoomQueueClearAll(void) {
    [YTzoomQueue() removeAllObjects];
    YTzoomQueueSave();
    id controller = YTzoomQueueControllerInstance;
    if ([controller respondsToSelector:@selector(clearQueue)]) {
        @try {
            ((void (*)(id, SEL))objc_msgSend)(controller,
                @selector(clearQueue));
        } @catch (__unused NSException *exception) {
        }
    }
    YTzoomShowNotice(YTzoomLocalized(@"Queue cleared"));
    YTzoomQueueRebuildWatchPage();
}

static void YTzoomQueueDidTapAction(id receiver, SEL selector, id button) {
    if (!YTzoomQueueIsActive()) {
        if (OriginalDidTapAction == NULL) return;
        ((void (*)(id, SEL, id))OriginalDidTapAction)(receiver, selector,
                                                      button);
        return;
    }
    YTzoomShowYouTubeConfirmation(YTzoomLocalized(@"Clear queue"),
        YTzoomLocalized(@"Remove every video from the queue?"),
        YTzoomLocalized(@"Clear"), ^{
        YTzoomQueueClearAll();
    });
}

static void YTzoomQueueDidTapLoop(id receiver, SEL selector) {
    if (OriginalDidTapLoop != NULL) {
        ((void (*)(id, SEL))OriginalDidTapLoop)(receiver, selector);
    }
    if (!YTzoomQueueIsActive()) return;
    const long long resolved = (YTzoomQueueSavedLoopMode() + 1) % 3;
    YTzoomQueueStoreLoopMode(resolved);
    YTzoomQueueApplyLoopMode(receiver, resolved);
}

static BOOL YTzoomQueueHasStep(NSInteger offset) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSUInteger current = YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
    if (current == NSNotFound) return NO;
    if (YTzoomQueueSavedLoopMode() != 0) return YTzoomQueue().count > 1;
    const NSInteger target = (NSInteger)current + offset;
    return target >= 0 && target < (NSInteger)YTzoomQueue().count;
}

static BOOL YTzoomQueueAutonavHasNext(id receiver, SEL selector) {
    if (YTzoomQueueHasStep(1)) return YES;
    if (OriginalAutonavHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasNext)(receiver, selector);
}

static BOOL YTzoomQueueAutonavHasPrevious(id receiver, SEL selector) {
    if (YTzoomQueueHasStep(-1)) return YES;
    if (OriginalAutonavHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalAutonavHasPrevious)(receiver, selector);
}

static BOOL YTzoomQueueControllerHasNext(id receiver, SEL selector) {
    if (YTzoomQueueHasStep(1)) return YES;
    if (OriginalQueueHasNext == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasNext)(receiver, selector);
}

static BOOL YTzoomQueueControllerHasPrevious(id receiver, SEL selector) {
    if (YTzoomQueueHasStep(-1)) return YES;
    if (OriginalQueueHasPrevious == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalQueueHasPrevious)(receiver, selector);
}

static unsigned long long YTzoomQueueNextNavigable(id receiver, SEL selector) {
    if (YTzoomQueueHasStep(1)) {
        NSUInteger current =
            YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
        if (current != NSNotFound) {
            const NSUInteger count = YTzoomQueue().count;
            return (unsigned long long)((current + 1) % MAX(count, 1u));
        }
    }
    if (OriginalNextNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalNextNavigable)(receiver,
                                                                    selector);
}

static unsigned long long YTzoomQueuePreviousNavigable(id receiver,
                                                       SEL selector) {
    if (YTzoomQueueHasStep(-1)) {
        NSUInteger current =
            YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
        const NSUInteger count = YTzoomQueue().count;
        if (current != NSNotFound && count != 0) {
            return (unsigned long long)(current == 0 ? count - 1 : current - 1);
        }
    }
    if (OriginalPreviousNavigable == NULL) return 0;
    return ((unsigned long long (*)(id, SEL))OriginalPreviousNavigable)(
        receiver, selector);
}

static id YTzoomQueuePanelByline(id receiver, SEL selector) {
    if (YTzoomQueueIsActive()) {
        NSUInteger current =
            YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
        const NSUInteger count = YTzoomQueue().count;
        if (current != NSNotFound && count != 0) {
            return [NSString stringWithFormat:@"%@ • %lu/%lu",
                YTzoomLocalized(@"Queue"), (unsigned long)(current + 1),
                (unsigned long)count];
        }
    }
    if (OriginalPanelByline == NULL) return nil;
    return ((id (*)(id, SEL))OriginalPanelByline)(receiver, selector);
}

static BOOL YTzoomQueueIsQueue(id receiver, SEL selector) {
    if (YTzoomQueuePanelController != receiver) {
        YTzoomQueuePanelController = receiver;
    }
    if (YTzoomQueueIsActive()) return YES;
    if (OriginalIsQueue == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalIsQueue)(receiver, selector);
}

static BOOL YTzoomQueueHasContents(id receiver, SEL selector) {
    if (YTzoomQueuePanelController != receiver) {
        YTzoomQueuePanelController = receiver;
    }
    if (YTzoomQueueIsActive()) return YES;
    if (OriginalHasQueueContents == NULL) return NO;
    return ((BOOL (*)(id, SEL))OriginalHasQueueContents)(receiver, selector);
}

static void YTzoomQueueHandlePlaybackTime(NSNotification *notification) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return;
    id receiver = notification.object;
    if (receiver == nil) return;
    YTzoomQueueResponder = receiver;
    id live = YTzoomQueueValue(receiver, @[@"currentVideoID", @"contentVideoID"]);
    if ([live isKindOfClass:NSString.class] && [live length] != 0 &&
        ![live isEqualToString:YTzoomQueueActiveVideo]) {
        YTzoomQueueActiveVideo = live;
        YTzoomQueueActiveVideoTime = 0;
    }
    if (YTzoomQueue().count == 0) return;
    SEL totalSelector = NSSelectorFromString(@"currentVideoTotalMediaTime");
    if (![receiver respondsToSelector:totalSelector]) return;
    const double total = ((double (*)(id, SEL))objc_msgSend)(receiver, totalSelector);
    const double time = [notification.userInfo[@"time"] doubleValue];
    if (total <= 0.0 || time <= 0.0) return;
    NSString *videoID = YTzoomLastVideoID();
    if (![videoID isEqualToString:YTzoomQueueActiveVideoID]) {
        YTzoomQueueActiveVideoID = videoID;
        YTzoomQueueAdvancedFromVideoID = nil;
    }
    if (time < total - 0.75) return;
    if (videoID.length != 0 &&
        [videoID isEqualToString:YTzoomQueueAdvancedFromVideoID]) {
        return;
    }

    NSString *finishing = [live isKindOfClass:NSString.class] && [live length] != 0
        ? (NSString *)live : videoID;
    if (finishing.length == 0 ||
        YTzoomQueueIndexOfVideo(finishing) == NSNotFound) {
        return;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.AutoplayDisabled")) {
        return;
    }
    YTzoomQueueAdvancedFromVideoID = videoID;
    YTzoomQueueAdvance();
}


static NSString *const YTzoomQueueSentinelPrefix = @"YTzoomQ|";

static id YTzoomQueueSentinelCommand(NSString *action, NSString *videoID) {
    id command = YTzoomQueueMessage(@"YTICommand");
    if (command == nil) return nil;
    NSString *marker = [NSString stringWithFormat:@"%@%@|%@",
        YTzoomQueueSentinelPrefix, action, videoID];
    [command setValue:[marker dataUsingEncoding:NSUTF8StringEncoding]
               forKey:@"clickTrackingParams"];
    return command;
}

static id YTzoomQueueMenuItem(NSString *label, NSString *action,
                              NSString *videoID) {
    id wrapper = YTzoomQueueMessage(@"YTIMenuItemSupportedRenderers");
    id item = YTzoomQueueMessage(@"YTIMenuServiceItemRenderer");
    id command = YTzoomQueueSentinelCommand(action, videoID);
    if (wrapper == nil || item == nil || command == nil) return nil;
    id text = YTzoomQueueFormatted(label);
    if (text != nil) [item setValue:text forKey:@"text"];
    [item setValue:command forKey:@"serviceEndpoint"];
    [wrapper setValue:item forKey:@"menuServiceItemRenderer"];
    return wrapper;
}

static id YTzoomQueueItemMenu(NSString *videoID) {
    id supported = YTzoomQueueMessage(@"YTIMenuSupportedRenderers");
    id renderer = YTzoomQueueMessage(@"YTIMenuRenderer");
    if (supported == nil || renderer == nil) return nil;
    NSMutableArray *items = [renderer valueForKey:@"itemsArray"];
    if (items == nil) return nil;
    id playNext = YTzoomQueueMenuItem(YTzoomLocalized(@"Play next in queue"),
                                      @"next", videoID);
    id remove = YTzoomQueueMenuItem(YTzoomLocalized(@"Remove from queue"),
                                    @"remove", videoID);
    if (playNext != nil) [items addObject:playNext];
    if (remove != nil) [items addObject:remove];
    if (items.count == 0) return nil;
    [supported setValue:renderer forKey:@"menuRenderer"];
    return supported;
}

static BOOL YTzoomQueueHandleSentinel(id command) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSString *dump = YTzoomQueueClip(command, 600);
    NSRange range = [dump rangeOfString:YTzoomQueueSentinelPrefix];
    if (range.location == NSNotFound) return NO;
    NSString *tail = [dump substringFromIndex:NSMaxRange(range)];
    NSArray<NSString *> *parts = [tail componentsSeparatedByString:@"|"];
    if (parts.count < 2) return NO;
    NSString *action = parts[0];
    NSString *videoID = [parts[1] substringToIndex:
        MIN((NSUInteger)11, [parts[1] length])];
    NSUInteger index = YTzoomQueueIndexOfVideo(videoID);
    if (index == NSNotFound) return NO;
    NSDictionary *entry = YTzoomQueue()[index];
    if ([action isEqualToString:@"remove"]) {
        [YTzoomQueue() removeObjectAtIndex:index];
        YTzoomQueueSave();
        id controller = YTzoomQueueControllerInstance;
        if ([controller respondsToSelector:@selector(removeVideoID:)]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(controller,
                    @selector(removeVideoID:), videoID);
            } @catch (__unused NSException *exception) {
            }
        }
        YTzoomShowNotice(YTzoomLocalized(@"Removed from queue"));
        YTzoomQueueRebuildWatchPage();
    } else if ([action isEqualToString:@"next"]) {
        NSUInteger current = YTzoomQueueIndexOfVideo(YTzoomQueueCurrentVideoID());
        if (current == NSNotFound) return NO;
        [YTzoomQueue() removeObjectAtIndex:index];
        NSUInteger target = current < index ? current + 1 : current;
        [YTzoomQueue() insertObject:entry atIndex:MIN(target,
            YTzoomQueue().count)];
        YTzoomQueueSave();
        YTzoomShowNotice(YTzoomLocalized(@"Playing next"));
    } else {
        return NO;
    }
    YTzoomQueueRefreshPanel();
    return YES;
}

static BOOL YTzoomQueueHandleDiscovery(id command, id view) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSString *params = nil;
    @try {
        params = YTzoomQueueDiscoveryParams(command);
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (params.length == 0) return NO;
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (data.length == 0) return NO;
    int position = 0;
    NSString *videoID = YTzoomQueueVideoIDFromParams(data, &position);
    if (videoID.length == 0) return NO;
    if (position != 2 && position != 3) return NO;
    YTzoomQueueAdd(videoID, YTzoomQueueTitleNearView(view), position == 2);
    return YES;
}

static void YTzoomQueueDiscoveryExecute(id receiver, SEL selector, id command,
                                        id entry, id view, id sender) {
    if (YTzoomQueueHandleDiscovery(command, view)) return;
    if (OriginalDiscoveryExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalDiscoveryExecute)(
        receiver, selector, command, entry, view, sender);
}


static NSString *YTzoomQueueClip(id object, NSUInteger limit) {
    NSString *text = nil;
    @try {
        text = [object description];
    } @catch (__unused NSException *exception) {
        return @"<description failed>";
    }
    if (text.length == 0) return @"<empty>";
    text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (text.length <= limit) return text;
    return [text substringToIndex:limit];
}




static BOOL YTzoomQueueHandleMenuAdd(id command, id view) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey)) return NO;
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    if (![dump containsString:@"getWatchNextQueueAddCommand"]) return NO;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"getWatchNextQueueAddCommand\\]\\s*params:\\s*\"([^\"]+)\""
                                                               options:0 error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match == nil) return NO;
    NSString *params = [dump substringWithRange:[match rangeAtIndex:1]];
    NSString *decoded = [params stringByRemovingPercentEncoding] ?: params;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:decoded
        options:NSDataBase64DecodingIgnoreUnknownCharacters];
    NSString *videoID = data.length ? YTzoomQueueVideoIDFromParams(data, NULL) : nil;
    if (videoID.length == 0) return NO;
    BOOL playNext = YES;
    const unsigned char *bytes = (const unsigned char *)data.bytes;
    for (NSUInteger index = 0; index + 1 < data.length; index++) {
        if (bytes[index] == 0x18 && (bytes[index + 1] == 0x01 || bytes[index + 1] == 0x02)) {
            playNext = bytes[index + 1] == 0x01;
            break;
        }
    }
    YTzoomQueueAdd(videoID, YTzoomQueueTitleNearView(view), playNext);
    return YES;
}

static id YTzoomQueueConditionalItem(id wrapper) {
    SEL getter = NSSelectorFromString(@"menuConditionalServiceItemRenderer");
    SEL has = NSSelectorFromString(@"hasMenuConditionalServiceItemRenderer");
    if (![wrapper respondsToSelector:getter] || ![wrapper respondsToSelector:has]) return nil;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(wrapper, has)) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(wrapper, getter);
}

void YTzoomQueuePrepareMenuRenderers(id renderers) {
    if (!YTzoomFeatureEnabled(YTzoomQueueKey) || ![renderers isKindOfClass:NSArray.class]) return;
    NSMutableDictionary<NSString *, id> *commands = [NSMutableDictionary dictionary];
    NSMutableArray *upsells = [NSMutableArray array];
    for (id wrapper in renderers) {
        id item = YTzoomQueueConditionalItem(wrapper);
        if (item == nil) continue;
        NSString *dump = [item description];
        NSString *icon = [dump containsString:@"QUEUE_PLAY_NEXT"] ? @"next"
            : ([dump containsString:@"ADD_TO_REMOTE_QUEUE"] ? @"last" : nil);
        if (icon == nil) continue;
        if ([dump containsString:@"getWatchNextQueueAddCommand"]) {
            if (commands[icon] == nil) commands[icon] = [item valueForKey:@"serviceEndpoint"];
        } else if ([dump containsString:@"SPunlimited"]) {
            [upsells addObject:@[item, icon]];
        }
    }
    for (NSArray *pair in upsells) {
        id command = commands[pair[1]];
        if (command == nil) continue;
        id item = pair[0];
        [item setValue:command forKey:@"serviceEndpoint"];
        SEL clearIcon = NSSelectorFromString(@"setSecondaryIcon:");
        if ([item respondsToSelector:clearIcon]) {
            ((void (*)(id, SEL, id))objc_msgSend)(item, clearIcon, nil);
        }
    }
}

static BOOL YTzoomQueueRouterHandle(id receiver, SEL selector, id command,
                                    id entry, id view, id sender) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return YES;
    if (YTzoomQueueHandleSentinel(command)) return YES;
    if (YTzoomQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL YTzoomQueueRouterHandleCompletion(id receiver, SEL selector,
                                              id command, id entry, id view,
                                              id sender, id block) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return YES;
    if (YTzoomQueueHandleSentinel(command)) return YES;
    if (YTzoomQueueHandleDiscovery(command, view)) return YES;
    if (OriginalRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))OriginalRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static BOOL YTzoomQueueScopedRouterHandle(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return YES;
    if (YTzoomQueueHandleSentinel(command)) return YES;
    if (YTzoomQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandle == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id))OriginalScopedRouterHandle)(
        receiver, selector, command, entry, view, sender);
}

static BOOL YTzoomQueueScopedRouterHandleCompletion(id receiver, SEL selector,
                                                    id command, id entry,
                                                    id view, id sender,
                                                    id block) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return YES;
    if (YTzoomQueueHandleSentinel(command)) return YES;
    if (YTzoomQueueHandleDiscovery(command, view)) return YES;
    if (OriginalScopedRouterHandleCompletion == NULL) return NO;
    return ((BOOL (*)(id, SEL, id, id, id, id, id))
        OriginalScopedRouterHandleCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

static IMP OriginalLegacyQueueMenuAdd;
static IMP OriginalLegacyWatchNextQueueAdd;

static void YTzoomLegacyQueueMenuAdd(id receiver, SEL selector, id command,
                                     id entry, id view, id sender) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyQueueMenuAdd)(
        receiver, selector, command, entry, view, sender);
}

static void YTzoomLegacyWatchNextQueueAdd(id receiver, SEL selector, id command,
                                          id entry, id view, id sender) {
    if (YTzoomQueueHandleMenuAdd(command, view)) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyWatchNextQueueAdd)(
        receiver, selector, command, entry, view, sender);
}

void YTzoomInstallQueueHooks(void) {
    YTzoomInstallInstanceHook(@"YTQueueAddMenuItemCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTzoomLegacyQueueMenuAdd, &OriginalLegacyQueueMenuAdd);
    YTzoomInstallInstanceHook(@"YTGetWatchNextQueueAddCommandHandler",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTzoomLegacyWatchNextQueueAdd, &OriginalLegacyWatchNextQueueAdd);
    YTzoomInstallInstanceHook(
        @"MDXRequestDeviceDiscoveryCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTzoomQueueDiscoveryExecute, &OriginalDiscoveryExecute);
    YTzoomInstallInstanceHook(
        @"YTDefaultQueueWatchNextResponseParser",
        @"playlistPanelRendererFromWatchNextResponse:",
        (IMP)YTzoomQueuePanelParse, &OriginalPanelParse);
    if (!YTzoomInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
        @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
        @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:"
        @"headerHidden:",
        (IMP)YTzoomQueueSetVideoCountText, &OriginalSetVideoCountText)) {
        YTzoomInstallInstanceHook(@"YTPlaylistPanelSectionController",
            @"setVideoCountText:videoCountHidden:shuffleEnabled:shuffleSelected:"
            @"loopEnabled:loopSelected:saveEnabled:shareEnabled:saveSelected:"
            @"actionEnabled:loopMode:playlistPanelRenderer:useRendererSaveIcons:",
            (IMP)YTzoomQueueLegacySetVideoCountText, &OriginalLegacySetVideoCountText);
    }
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapShuffleButton", (IMP)YTzoomQueueDidTapShuffle,
        &OriginalDidTapShuffle);
    YTzoomInstallInstanceHook(@"YTAutoplayAutonavController", @"hasNextVideo",
        (IMP)YTzoomQueueAutonavHasNext, &OriginalAutonavHasNext);
    YTzoomInstallInstanceHook(@"YTAutoplayAutonavController",
        @"hasPreviousVideo", (IMP)YTzoomQueueAutonavHasPrevious,
        &OriginalAutonavHasPrevious);
    YTzoomInstallInstanceHook(@"YTQueueController", @"nextNavigableVideoIndex",
        (IMP)YTzoomQueueNextNavigable, &OriginalNextNavigable);
    YTzoomInstallInstanceHook(@"YTQueueController",
        @"previousNavigableVideoIndex", (IMP)YTzoomQueuePreviousNavigable,
        &OriginalPreviousNavigable);
    YTzoomInstallInstanceHook(@"YTQueueController", @"hasNextVideo",
        (IMP)YTzoomQueueControllerHasNext, &OriginalQueueHasNext);
    YTzoomInstallInstanceHook(@"YTQueueController", @"hasPreviousVideo",
        (IMP)YTzoomQueueControllerHasPrevious, &OriginalQueueHasPrevious);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController",
        @"didTapActionButton:", (IMP)YTzoomQueueDidTapAction,
        &OriginalDidTapAction);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController", @"didTapLoopButton",
        (IMP)YTzoomQueueDidTapLoop, &OriginalDidTapLoop);
    YTzoomInstallInstanceHook(
        @"YTPlaylistPanelProminentThumbnailVideoCellController", @"setCell:",
        (IMP)YTzoomQueueCellControllerSetCell, &OriginalCellControllerSetCell);
    YTzoomInstallInstanceHook(@"YTSlideForActionsView", @"layoutSubviews",
        (IMP)YTzoomQueueSlideLayoutSubviews, &OriginalSlideLayoutSubviews);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"updateCell:forIndex:", (IMP)YTzoomQueueUpdateCellForIndex,
        &OriginalUpdateCellForIndex);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelSectionController",
        @"alphaForIndex:", (IMP)YTzoomQueueAlphaForIndex,
        &OriginalAlphaForIndex);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"prepareForReuse", (IMP)YTzoomQueueCellPrepareForReuse,
        &OriginalCellPrepareForReuse);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"setCanReorder:", (IMP)YTzoomQueueSetCanReorder,
        &OriginalSetCanReorder);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelProminentThumbnailVideoCell",
        @"allowsReorderingAtPoint:", (IMP)YTzoomQueueAllowsReordering,
        &OriginalAllowsReordering);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoTitle",
        (IMP)YTzoomQueueNextVideoTitle, &OriginalNextVideoTitle);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController", @"nextVideoIndex",
        (IMP)YTzoomQueueNextVideoIndex, &OriginalNextVideoIndex);
    YTzoomInstallInstanceHook(@"YTQueueAutoplayController",
        @"replaceAutoplayItemsWithWatchNextResponse:",
        (IMP)YTzoomQueueReplaceAutoplay, &OriginalReplaceAutoplay);
    YTzoomInstallInstanceHook(@"YTQueueController",
        @"canMoveItemAtIndexPath:toIndexPath:", (IMP)YTzoomQueueCanMoveItem,
        &OriginalCanMoveItem);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController", @"byline",
        (IMP)YTzoomQueuePanelByline, &OriginalPanelByline);
    YTzoomInstallInstanceHook(@"YTPlaylistPanelController", @"isQueue",
        (IMP)YTzoomQueueIsQueue, &OriginalIsQueue);
    if (!YTzoomInstallInstanceHook(@"YTPlaylistPanelController",
        @"hasQueueContents", (IMP)YTzoomQueueHasContents,
        &OriginalHasQueueContents)) {
        YTzoomInstallInstanceHook(@"YTPlaylistPanelController",
            @"shouldShowPlaylist", (IMP)YTzoomQueueShouldShowPlaylist,
            &OriginalShouldShowPlaylist);
    }
    YTzoomInstallInstanceHook(@"YTQueueController",
        @"moveItemAtIndexPath:toIndexPath:userTriggered:",
        (IMP)YTzoomQueueMoveItem, &OriginalMoveItem);
    YTzoomInstallInstanceHook(@"YTQueueController",
        @"removeItemAtIndexPath:userTriggered:",
        (IMP)YTzoomQueueRemoveItem, &OriginalRemoveItem);
    YTzoomInstallInstanceHook(@"YTQueueController", @"removeQueueItemAtIndex:",
        (IMP)YTzoomQueueRemoveIndex, &OriginalRemoveIndex);
    YTzoomInstallInstanceHook(@"YTQueueController", @"clearQueue",
        (IMP)YTzoomQueueClearQueue, &OriginalClearQueue);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressNext:", (IMP)YTzoomQueueDidPressNext, &OriginalDidPressNext);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
        @"didPressPrevious:", (IMP)YTzoomQueueDidPressPrevious,
        &OriginalDidPressPrevious);
    YTzoomInstallInstanceHook(@"YTAutoplayAutonavController", @"playNext",
        (IMP)YTzoomQueueAutonavPlayNext, &OriginalAutonavPlayNext);
    YTzoomInstallInstanceHook(
        @"YTWatchViewController", @"updateWithWatchNextResponse:",
        (IMP)YTzoomQueueViewUpdateWatchNext, &OriginalViewUpdateWatchNext);
    YTzoomInstallInstanceHook(
        @"YTPlaylistPanelController", @"initWithAccountID:parentResponder:",
        (IMP)YTzoomQueuePanelInit, &OriginalPanelInit);
    YTzoomInstallInstanceHook(
        @"YTPlaylistPanelController",
        @"initWithAccountID:parentResponder:queueController:",
        (IMP)YTzoomQueuePanelInitQueue, &OriginalPanelInitQueue);
    YTzoomInstallInstanceHook(
        @"YTQueueController", @"initWithAccountID:parentResponder:",
        (IMP)YTzoomQueueControllerInit, &OriginalQueueControllerInit);
    YTzoomInstallInstanceHook(
        @"YTWatchController", @"prepareWithWatchNextResponse:",
        (IMP)YTzoomQueuePrepareWatchNext, &OriginalPrepareWatchNext);
    YTzoomInstallInstanceHook(
        @"YTPlayerViewController", @"setWatchNextResponse:",
        (IMP)YTzoomQueueSetWatchNext, &OriginalSetWatchNext);
    YTzoomInstallInstanceHook(
        @"YTIWatchNextResponse", @"yt_playlistPanelRenderer",
        (IMP)YTzoomQueueResponsePanel, &OriginalResponsePanel);
    YTzoomInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)YTzoomQueueRouterHandle, &OriginalRouterHandle);
    YTzoomInstallInstanceHook(@"YTCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTzoomQueueRouterHandleCompletion, &OriginalRouterHandleCompletion);
    YTzoomInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:",
        (IMP)YTzoomQueueScopedRouterHandle, &OriginalScopedRouterHandle);
    YTzoomInstallInstanceHook(@"YTAccountScopedCommandRouter",
        @"handleCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTzoomQueueScopedRouterHandleCompletion,
        &OriginalScopedRouterHandleCompletion);
    [NSNotificationCenter.defaultCenter
        addObserverForName:@"YTzoomPlaybackTimeDidChange"
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
        YTzoomQueueHandlePlaybackTime(notification);
    }];
}
