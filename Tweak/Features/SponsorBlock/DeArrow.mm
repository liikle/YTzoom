#import "DeArrow.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/lock.h>
#import <stdatomic.h>

NSString * const YTzoomDeArrowThumbModeKey = @"YTzoom.Preference.DeArrow.ThumbnailMode";
NSString * const YTzoomDeArrowTitlesKey = @"YTzoom.Preference.DeArrow.Titles";

static NSString * const YTzoomBrandingStoreKey = @"YTzoom.Preference.DeArrow.Branding";

static const NSUInteger YTzoomStoreLimit = 800;
static const NSUInteger YTzoomMaxConcurrent = 4;
static const NSUInteger YTzoomRequestsPerMinute = 90;
static const NSUInteger YTzoomPendingLimit = 300;
static const NSUInteger YTzoomAncestorDepth = 12;
static const NSUInteger YTzoomCellTextDepth = 10;
static const NSUInteger YTzoomMaxCellText = 10;
static const NSTimeInterval YTzoomNegativeTTL = 7 * 24 * 60 * 60;
static const NSInteger YTzoomStoreVersion = 2;

static IMP OriginalDownloadImage;
static IMP OriginalCachedImage;
static IMP OriginalApplyProperties;

static const void *YTzoomNodeVideoIDKey = &YTzoomNodeVideoIDKey;
static const void *YTzoomCellVideoIDKey = &YTzoomCellVideoIDKey;

static os_unfair_lock YTzoomLock = OS_UNFAIR_LOCK_INIT;
static NSUInteger YTzoomActiveRequests;
static NSUInteger YTzoomWindowCount;
static NSTimeInterval YTzoomWindowStart;
static NSMutableSet<NSString *> *YTzoomInFlight;
static NSMutableSet<NSString *> *YTzoomThumbInFlight;
static NSMutableArray<NSString *> *YTzoomPendingIDs;
static NSMapTable *YTzoomPendingNodes;
static NSMapTable *YTzoomPendingCells;
static NSMutableDictionary<NSString *, NSDictionary *> *YTzoomStore;
static NSCache<NSString *, UIImage *> *YTzoomImageCache;

static atomic_int YTzoomModeCache = -1;
static atomic_int YTzoomTitlesCache = -1;

static void YTzoomPumpQueue(void);
static void YTzoomApplyTitleToCell(id root, NSString *videoID);

static NSInteger YTzoomThumbMode(void) {
    int cached = atomic_load(&YTzoomModeCache);
    if (cached >= 0) return cached;
    id stored = YTzoomPreferenceObject(YTzoomDeArrowThumbModeKey);
    NSInteger mode = [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 1)) : 0;
    atomic_store(&YTzoomModeCache, (int)mode);
    return mode;
}

static BOOL YTzoomReplacingTitles(void) {
    int cached = atomic_load(&YTzoomTitlesCache);
    if (cached >= 0) return cached != 0;
    BOOL enabled = YTzoomFeatureEnabled(YTzoomDeArrowTitlesKey);
    atomic_store(&YTzoomTitlesCache, enabled ? 1 : 0);
    return enabled;
}

static BOOL YTzoomReplacingThumbs(void) {
    return YTzoomThumbMode() > 0;
}

static BOOL YTzoomAnyFeatureOn(void) {
    return YTzoomReplacingThumbs() || YTzoomReplacingTitles();
}

static id YTzoomSend(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    @try {
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static id YTzoomSupernode(id node) {
    return YTzoomSend(node, @selector(supernode));
}

static NSArray *YTzoomSubnodes(id node) {
    id value = YTzoomSend(node, @selector(subnodes));
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static NSString *YTzoomNodeText(id node) {
    id value = YTzoomSend(node, @selector(attributedText));
    if ([value isKindOfClass:NSAttributedString.class]) {
        return ((NSAttributedString *)value).string;
    }
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static id YTzoomCellRoot(id node) {
    static Class cellClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cellClass = NSClassFromString(@"ELMCellNode");
    });
    if (cellClass == Nil) return nil;
    id current = node;
    for (NSUInteger level = 0; level < YTzoomAncestorDepth; level++) {
        if ([current isKindOfClass:cellClass]) return current;
        current = YTzoomSupernode(current);
        if (current == nil) break;
    }
    return nil;
}

static NSString *YTzoomVideoIDFromURL(NSString *absolute) {
    if (absolute.length == 0) return nil;
    if ([absolute rangeOfString:@"/vi"].location == NSNotFound) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"/(?:vi|vi_webp)/([A-Za-z0-9_-]{11})/" options:0 error:nil];
    });
    NSTextCheckingResult *match =
        [expression firstMatchInString:absolute options:0
                                 range:NSMakeRange(0, absolute.length)];
    if (match.numberOfRanges < 2) return nil;
    return [absolute substringWithRange:[match rangeAtIndex:1]];
}

static NSString *YTzoomURLString(id value) {
    if ([value isKindOfClass:NSURL.class]) return ((NSURL *)value).absoluteString;
    if ([value isKindOfClass:NSString.class]) return (NSString *)value;
    id resolved = YTzoomSend(value, @selector(absoluteString));
    return [resolved isKindOfClass:NSString.class] ? resolved : nil;
}

static void YTzoomLoadStore(void) {
    if (YTzoomStore != nil) return;
    NSDictionary *stored =
        [NSUserDefaults.standardUserDefaults dictionaryForKey:YTzoomBrandingStoreKey];
    YTzoomStore = [stored isKindOfClass:NSDictionary.class]
        ? [stored mutableCopy] : [NSMutableDictionary dictionary];
    YTzoomImageCache = [NSCache new];
    YTzoomImageCache.countLimit = 160;
    YTzoomInFlight = [NSMutableSet set];
    YTzoomThumbInFlight = [NSMutableSet set];
    YTzoomPendingIDs = [NSMutableArray array];
    YTzoomPendingNodes = [NSMapTable strongToWeakObjectsMapTable];
    YTzoomPendingCells = [NSMapTable strongToWeakObjectsMapTable];
}

static void YTzoomEvictLocked(void) {
    if (YTzoomStore.count <= YTzoomStoreLimit) return;
    NSArray<NSString *> *ordered = [YTzoomStore.allKeys sortedArrayUsingComparator:
        ^NSComparisonResult(NSString *left, NSString *right) {
            double a = [YTzoomStore[left][@"a"] doubleValue];
            double b = [YTzoomStore[right][@"a"] doubleValue];
            if (a < b) return NSOrderedAscending;
            if (a > b) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    NSUInteger drop = YTzoomStore.count - (YTzoomStoreLimit * 3 / 4);
    if (drop > ordered.count) drop = ordered.count;
    for (NSUInteger index = 0; index < drop; index++) {
        [YTzoomStore removeObjectForKey:ordered[index]];
    }
}

static void YTzoomPersistStore(void) {
    os_unfair_lock_lock(&YTzoomLock);
    YTzoomEvictLocked();
    NSDictionary *snapshot = [YTzoomStore copy];
    os_unfair_lock_unlock(&YTzoomLock);
    if (snapshot != nil) {
        [NSUserDefaults.standardUserDefaults setObject:snapshot
                                                forKey:YTzoomBrandingStoreKey];
    }
}

static NSDictionary *YTzoomFreshEntryLocked(NSString *videoID) {
    NSDictionary *entry = YTzoomStore[videoID];
    if (entry == nil) return nil;
    if ([entry[@"v"] integerValue] < YTzoomStoreVersion) {
        [YTzoomStore removeObjectForKey:videoID];
        return nil;
    }
    if (entry[@"t"] != nil || entry[@"ti"] != nil) return entry;
    double added = [entry[@"a"] doubleValue];
    if (NSDate.date.timeIntervalSince1970 - added > YTzoomNegativeTTL) {
        [YTzoomStore removeObjectForKey:videoID];
        return nil;
    }
    return entry;
}

static void YTzoomStoreBranding(NSString *videoID, NSNumber *timestamp,
                                NSString *title) {
    if (videoID.length == 0) return;
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"a"] = @(NSDate.date.timeIntervalSince1970);
    entry[@"v"] = @(YTzoomStoreVersion);
    if (timestamp != nil) entry[@"t"] = timestamp;
    if (title.length != 0) entry[@"ti"] = title;
    if (timestamp == nil && title.length == 0) entry[@"n"] = @YES;
    os_unfair_lock_lock(&YTzoomLock);
    YTzoomStore[videoID] = entry;
    [YTzoomInFlight removeObject:videoID];
    if (YTzoomActiveRequests > 0) YTzoomActiveRequests--;
    os_unfair_lock_unlock(&YTzoomLock);
    YTzoomPersistStore();
    YTzoomPumpQueue();
}

static NSString *YTzoomStoredTitle(NSString *videoID) {
    if (videoID.length == 0) return nil;
    os_unfair_lock_lock(&YTzoomLock);
    id title = YTzoomStore[videoID][@"ti"];
    os_unfair_lock_unlock(&YTzoomLock);
    return [title isKindOfClass:NSString.class] ? title : nil;
}

static void YTzoomApplyImage(id node, NSString *videoID, UIImage *image) {
    if (node == nil || image == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        id current = objc_getAssociatedObject(node, YTzoomNodeVideoIDKey);
        if (![current isEqual:videoID]) return;
        SEL setter = NSSelectorFromString(@"setImage:");
        if (![node respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(node, setter, image);
        } @catch (__unused NSException *exception) {
        }
    });
}

static void YTzoomFetchThumbnail(NSString *videoID, double timestamp, id node) {
    if (!YTzoomReplacingThumbs()) return;
    os_unfair_lock_lock(&YTzoomLock);
    BOOL busy = [YTzoomThumbInFlight containsObject:videoID];
    if (!busy) [YTzoomThumbInFlight addObject:videoID];
    os_unfair_lock_unlock(&YTzoomLock);
    if (busy) return;

    NSString *address = [NSString stringWithFormat:
        @"https://dearrow-thumb.ajay.app/api/v1/getThumbnail?videoID=%@&time=%.3f",
        videoID, timestamp];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) {
        os_unfair_lock_lock(&YTzoomLock);
        [YTzoomThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&YTzoomLock);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 20.0;
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        os_unfair_lock_lock(&YTzoomLock);
        [YTzoomThumbInFlight removeObject:videoID];
        os_unfair_lock_unlock(&YTzoomLock);
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        UIImage *decoded = (error == nil && http.statusCode == 200 && data.length != 0)
            ? [UIImage imageWithData:data] : nil;
        if (decoded == nil) return;
        os_unfair_lock_lock(&YTzoomLock);
        [YTzoomImageCache setObject:decoded forKey:videoID];
        os_unfair_lock_unlock(&YTzoomLock);
        YTzoomApplyImage(weakNode, videoID, decoded);
    }] resume];
}

static void YTzoomCollectTextNodes(id node, NSUInteger depth, NSMutableArray *out) {
    if (node == nil || depth > YTzoomCellTextDepth ||
        out.count >= YTzoomMaxCellText) {
        return;
    }
    static Class textClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        textClass = NSClassFromString(@"ELMTextNode");
    });
    if (textClass != Nil && [node isKindOfClass:textClass]) {
        if (YTzoomNodeText(node).length != 0) [out addObject:node];
    }
    for (id child in YTzoomSubnodes(node)) {
        YTzoomCollectTextNodes(child, depth + 1, out);
    }
}

static BOOL YTzoomLooksLikeDuration(NSString *text) {
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression regularExpressionWithPattern:
            @"^\\d{1,2}:\\d{2}(:\\d{2})?$" options:0 error:nil];
    });
    return [expression numberOfMatchesInString:text options:0
                                         range:NSMakeRange(0, text.length)] != 0;
}

static void YTzoomWriteTitle(id textNode, NSString *title) {
    void (^work)(void) = ^{
        id current = YTzoomSend(textNode, @selector(attributedText));
        if (![current isKindOfClass:NSAttributedString.class]) return;
        NSAttributedString *existing = current;
        if ([existing.string isEqualToString:title]) return;
        NSDictionary *attributes = existing.length != 0
            ? [existing attributesAtIndex:0 effectiveRange:NULL] : nil;
        NSAttributedString *replacement =
            [[NSAttributedString alloc] initWithString:title attributes:attributes];
        SEL setter = NSSelectorFromString(@"setAttributedText:");
        if (![textNode respondsToSelector:setter]) return;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(textNode, setter, replacement);
        } @catch (__unused NSException *exception) {
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

static void YTzoomApplyTitleToCell(id root, NSString *videoID) {
    if (root == nil || videoID.length == 0 || !YTzoomReplacingTitles()) return;

    NSString *title = YTzoomStoredTitle(videoID);
    if (title.length == 0) {
        os_unfair_lock_lock(&YTzoomLock);
        [YTzoomPendingCells setObject:root forKey:videoID];
        os_unfair_lock_unlock(&YTzoomLock);
        return;
    }

    NSMutableArray *nodes = [NSMutableArray array];
    YTzoomCollectTextNodes(root, 0, nodes);
    if (nodes.count < 2) return;
    id candidate = nodes[nodes.count - 2];
    NSString *text = YTzoomNodeText(candidate);
    if ([text isEqualToString:title]) return;
    if (YTzoomLooksLikeDuration(text)) return;
    YTzoomWriteTitle(candidate, title);
}

static void YTzoomApplyPendingTitle(NSString *videoID) {
    if (videoID.length == 0 || !YTzoomReplacingTitles()) return;
    os_unfair_lock_lock(&YTzoomLock);
    id root = [YTzoomPendingCells objectForKey:videoID];
    os_unfair_lock_unlock(&YTzoomLock);
    if (root != nil) YTzoomApplyTitleToCell(root, videoID);
}

static BOOL YTzoomClaimSlotLocked(void) {
    if (YTzoomActiveRequests >= YTzoomMaxConcurrent) return NO;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - YTzoomWindowStart >= 60.0) {
        YTzoomWindowStart = now;
        YTzoomWindowCount = 0;
    }
    if (YTzoomWindowCount >= YTzoomRequestsPerMinute) return NO;
    YTzoomWindowCount++;
    YTzoomActiveRequests++;
    return YES;
}

static void YTzoomFetchBranding(NSString *videoID, id node) {
    NSString *address = [NSString stringWithFormat:
        @"https://sponsor.ajay.app/api/branding?videoID=%@", videoID];
    NSURL *URL = [NSURL URLWithString:address];
    if (URL == nil) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.timeoutInterval = 15.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    __weak id weakNode = node;
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class]
            ? (NSHTTPURLResponse *)response : nil;
        if (error != nil) {
            os_unfair_lock_lock(&YTzoomLock);
            [YTzoomInFlight removeObject:videoID];
            if (YTzoomActiveRequests > 0) YTzoomActiveRequests--;
            os_unfair_lock_unlock(&YTzoomLock);
            YTzoomPumpQueue();
            return;
        }
        id json = (http.statusCode == 200 && data.length != 0)
            ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            YTzoomStoreBranding(videoID, nil, nil);
            return;
        }
        NSDictionary *payload = json;
        NSArray *titles = [payload[@"titles"] isKindOfClass:NSArray.class]
            ? payload[@"titles"] : @[];
        NSArray *thumbnails = [payload[@"thumbnails"] isKindOfClass:NSArray.class]
            ? payload[@"thumbnails"] : @[];

        NSString *useTitle = nil;
        NSDictionary *bestTitle = titles.firstObject;
        if ([bestTitle isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestTitle[@"locked"] boolValue] ||
                [bestTitle[@"votes"] integerValue] >= 0;
            id text = bestTitle[@"title"];
            if (trusted && ![bestTitle[@"original"] boolValue] &&
                [text isKindOfClass:NSString.class]) {
                NSString *cleaned = [(NSString *)text
                    stringByReplacingOccurrencesOfString:@">" withString:@""];
                cleaned = [cleaned stringByTrimmingCharactersInSet:
                    NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (cleaned.length != 0) useTitle = cleaned;
            }
        }

        NSNumber *useTimestamp = nil;
        NSDictionary *bestThumb = thumbnails.firstObject;
        if ([bestThumb isKindOfClass:NSDictionary.class]) {
            BOOL trusted = [bestThumb[@"locked"] boolValue] ||
                [bestThumb[@"votes"] integerValue] >= 0;
            id timestamp = bestThumb[@"timestamp"];
            if (trusted && ![bestThumb[@"original"] boolValue] &&
                [timestamp isKindOfClass:NSNumber.class]) {
                useTimestamp = timestamp;
            }
        }

        YTzoomStoreBranding(videoID, useTimestamp, useTitle);
        if (useTitle.length != 0) YTzoomApplyPendingTitle(videoID);
        if (useTimestamp != nil) {
            YTzoomFetchThumbnail(videoID, useTimestamp.doubleValue, weakNode);
        }
    }] resume];
}

static void YTzoomPumpQueue(void) {
    while (YES) {
        NSString *videoID = nil;
        id node = nil;
        os_unfair_lock_lock(&YTzoomLock);
        while (YTzoomPendingIDs.count != 0 && videoID == nil) {
            NSString *candidate = YTzoomPendingIDs.firstObject;
            [YTzoomPendingIDs removeObjectAtIndex:0];
            if (YTzoomFreshEntryLocked(candidate) != nil ||
                [YTzoomInFlight containsObject:candidate]) {
                [YTzoomPendingNodes removeObjectForKey:candidate];
                continue;
            }
            if (!YTzoomClaimSlotLocked()) {
                [YTzoomPendingIDs insertObject:candidate atIndex:0];
                break;
            }
            [YTzoomInFlight addObject:candidate];
            node = [YTzoomPendingNodes objectForKey:candidate];
            [YTzoomPendingNodes removeObjectForKey:candidate];
            videoID = candidate;
        }
        os_unfair_lock_unlock(&YTzoomLock);
        if (videoID == nil) return;
        YTzoomFetchBranding(videoID, node);
    }
}

static void YTzoomEnqueueLookup(NSString *videoID, id node) {
    os_unfair_lock_lock(&YTzoomLock);
    BOOL known = YTzoomFreshEntryLocked(videoID) != nil ||
        [YTzoomInFlight containsObject:videoID] ||
        [YTzoomPendingIDs containsObject:videoID];
    if (!known) {
        if (YTzoomPendingIDs.count >= YTzoomPendingLimit) {
            [YTzoomPendingIDs removeObjectAtIndex:0];
        }
        [YTzoomPendingIDs addObject:videoID];
        if (node != nil) [YTzoomPendingNodes setObject:node forKey:videoID];
    }
    os_unfair_lock_unlock(&YTzoomLock);
    if (!known) YTzoomPumpQueue();
}

static void YTzoomConsiderVideo(id node, NSString *videoID) {
    BOOL replacing = YTzoomReplacingThumbs();
    os_unfair_lock_lock(&YTzoomLock);
    YTzoomLoadStore();
    UIImage *ready = replacing ? [YTzoomImageCache objectForKey:videoID] : nil;
    NSDictionary *known = YTzoomFreshEntryLocked(videoID);
    os_unfair_lock_unlock(&YTzoomLock);

    if (ready != nil) {
        YTzoomApplyImage(node, videoID, ready);
        return;
    }
    if (known != nil) {
        NSNumber *timestamp = known[@"t"];
        if (replacing && [timestamp isKindOfClass:NSNumber.class]) {
            YTzoomFetchThumbnail(videoID, timestamp.doubleValue, node);
        }
        return;
    }
    YTzoomEnqueueLookup(videoID, node);
}

static void YTzoomNoteImage(id receiver, id URL) {
    NSString *videoID = YTzoomVideoIDFromURL(YTzoomURLString(URL));
    if (videoID.length == 0) return;

    objc_setAssociatedObject(receiver, YTzoomNodeVideoIDKey, videoID,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    id root = YTzoomCellRoot(receiver);
    if (root != nil) {
        objc_setAssociatedObject(root, YTzoomCellVideoIDKey, videoID,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    YTzoomConsiderVideo(receiver, videoID);
    if (root != nil) YTzoomApplyTitleToCell(root, videoID);
}

static id YTzoomDownloadImage(id receiver, SEL selector, id URL, BOOL shouldRetry,
                              id callbackQueue, id progress, id completion) {
    if (YTzoomAnyFeatureOn()) YTzoomNoteImage(receiver, URL);
    if (OriginalDownloadImage == NULL) return nil;
    return ((id (*)(id, SEL, id, BOOL, id, id, id))OriginalDownloadImage)(
        receiver, selector, URL, shouldRetry, callbackQueue, progress, completion);
}

static void YTzoomCachedImage(id receiver, SEL selector, id URL,
                              id callbackQueue, id completion) {
    if (YTzoomAnyFeatureOn()) YTzoomNoteImage(receiver, URL);
    if (OriginalCachedImage == NULL) return;
    ((void (*)(id, SEL, id, id, id))OriginalCachedImage)(
        receiver, selector, URL, callbackQueue, completion);
}

static void YTzoomApplyProperties(id receiver, SEL selector) {
    if (OriginalApplyProperties != NULL) {
        ((void (*)(id, SEL))OriginalApplyProperties)(receiver, selector);
    }
    if (!YTzoomReplacingTitles()) return;
    id root = YTzoomCellRoot(receiver);
    if (root == nil) return;
    id stored = objc_getAssociatedObject(root, YTzoomCellVideoIDKey);
    if (![stored isKindOfClass:NSString.class]) return;
    if (YTzoomStoredTitle(stored).length == 0) return;
    YTzoomApplyTitleToCell(root, stored);
}

void YTzoomDeArrowClearCache(void) {
    os_unfair_lock_lock(&YTzoomLock);
    [YTzoomStore removeAllObjects];
    [YTzoomImageCache removeAllObjects];
    [YTzoomPendingIDs removeAllObjects];
    [YTzoomPendingCells removeAllObjects];
    os_unfair_lock_unlock(&YTzoomLock);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:YTzoomBrandingStoreKey];
}

void YTzoomInstallDeArrow(void) {
    os_unfair_lock_lock(&YTzoomLock);
    YTzoomLoadStore();
    os_unfair_lock_unlock(&YTzoomLock);

    YTzoomInstallInstanceHook(@"ELMImageNode",
        @"downloadImageWithURL:shouldRetry:callbackQueue:downloadProgress:completion:",
        (IMP)YTzoomDownloadImage, &OriginalDownloadImage);
    YTzoomInstallInstanceHook(@"ELMImageNode",
        @"cachedImageWithURL:callbackQueue:completion:",
        (IMP)YTzoomCachedImage, &OriginalCachedImage);
    YTzoomInstallInstanceHook(@"ELMTextNode",
        @"controllerDidApplyProperties", (IMP)YTzoomApplyProperties,
        &OriginalApplyProperties);

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTzoomPreferencesDidChangeNotification
                    object:nil queue:nil
                usingBlock:^(__unused NSNotification *note) {
        atomic_store(&YTzoomModeCache, -1);
        atomic_store(&YTzoomTitlesCache, -1);
    }];
}
