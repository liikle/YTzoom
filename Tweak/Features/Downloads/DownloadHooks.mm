#import "DownloadCoordinator.h"
#import "DownloadLog.h"
#import "SABRDownloader.h"
#import "StreamResolver.h"
#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../../Runtime/Localization.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../UI/Assets.h"
#import <objc/message.h>
#import <objc/runtime.h>

UIImage *YTzoomDownloadGlyphImage(void) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:22.0
                                                        weight:UIImageSymbolWeightMedium];
    UIImage *image = [YTzoomDownloadTabImage(NO)
        imageByApplyingSymbolConfiguration:configuration];
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static IMP OriginalSetPlayerResponse;
static IMP OriginalSetPoToken;
static IMP OriginalMintWithVideoID;
static IMP OriginalMakePlayerRequest;
static IMP OriginalMakePlaybackRequest;
static IMP OriginalMakePrefetchPlayerRequest;
static IMP OriginalFactoryRequest;
static IMP OriginalFactoryRequestExtended;
static IMP OriginalOnesieRequest;
static IMP OriginalOnesieRequestAsync;
static IMP OriginalOnesieRequestCompletion;
static IMP OriginalHAMBuildURLRequest;
static id YTzoomLastPlayerService;
static id YTzoomLastPlayerRequest;
static id YTzoomLastPlaybackRequest;
static id YTzoomLastPlayerFactory;
static id YTzoomLastRequestProperties;
static NSMutableDictionary<NSString *, NSArray *> *YTzoomPlayerRequests;
static NSMutableDictionary<NSString *, id> *YTzoomPlaybackRequests;
static NSInteger YTzoomPlayerHookAttempts;
static NSString *YTzoomLastCapturedVideoID;
id YTzoomLatestPlayerAuthorization;

NSString *YTzoomLastVideoID(void) {
    return [YTzoomLastCapturedVideoID copy];
}
static NSString *YTzoomRequestVideoID(id request);
static void YTzoomPersistPlayerRequest(id request);
static BOOL YTzoomUsingRestoredRequest;
static id YTzoomCopyObject(id object);

static NSURLRequest *YTzoomURLRequestFromObject(id object) {
    if ([object isKindOfClass:NSURLRequest.class]) return object;
    SEL builder = NSSelectorFromString(@"buildURLRequest");
    if ([object respondsToSelector:builder]) {
        id result = ((id (*)(id, SEL))objc_msgSend)(object, builder);
        if ([result isKindOfClass:NSURLRequest.class]) return result;
    }
    return nil;
}

@interface YTzoomOnesieSessionState : NSObject
@property(nonatomic, strong) id factory;
@property(nonatomic, strong) id playerRequest;
@property(nonatomic, strong, nullable) id authorization;
@property(nonatomic, strong) id dataLoader;
@property(nonatomic, strong) id context;
@property(nonatomic, strong) id cryptor;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, assign) NSInteger observedRequestNumber;
@property(nonatomic, assign) NSInteger nextRequestNumber;
@property(nonatomic, assign) BOOL asynchronous;
@property(nonatomic, strong) NSDate *capturedAt;
@end

@implementation YTzoomOnesieSessionState
@end

static NSMutableDictionary<NSString *, YTzoomOnesieSessionState *> *
    YTzoomOnesieSessions;
static YTzoomOnesieSessionState *YTzoomLastOnesieSession;

static void YTzoomPruneOnesieSessions(void) {
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-900.0];
    NSMutableArray<NSString *> *expired = [NSMutableArray array];
    for (NSString *key in YTzoomOnesieSessions) {
        YTzoomOnesieSessionState *state = YTzoomOnesieSessions[key];
        if ([state.capturedAt compare:cutoff] == NSOrderedAscending) {
            [expired addObject:key];
        }
    }
    [YTzoomOnesieSessions removeObjectsForKeys:expired];
    if (YTzoomOnesieSessions.count <= 16) return;
    NSArray<NSString *> *keys = [YTzoomOnesieSessions keysSortedByValueUsingComparator:
        ^NSComparisonResult(YTzoomOnesieSessionState *left,
                            YTzoomOnesieSessionState *right) {
            return [left.capturedAt compare:right.capturedAt];
        }];
    NSUInteger removeCount = YTzoomOnesieSessions.count - 16;
    [YTzoomOnesieSessions removeObjectsForKeys:
        [keys subarrayWithRange:NSMakeRange(0, removeCount)]];
}

static void YTzoomCaptureOnesieSession(id factory,
                                       id playerRequest,
                                       id authorization,
                                       id dataLoader,
                                       id context,
                                       id cryptor,
                                       NSInteger requestNumber,
                                       BOOL asynchronous) {
    if (factory == nil || playerRequest == nil || dataLoader == nil ||
        context == nil || cryptor == nil) {
        return;
    }
    NSString *videoID = YTzoomRequestVideoID(playerRequest);
    if (videoID.length == 0) videoID = YTzoomLastCapturedVideoID;
    YTzoomOnesieSessionState *state = [YTzoomOnesieSessionState new];
    state.factory = factory;
    state.playerRequest = YTzoomCopyObject(playerRequest);
    state.authorization = YTzoomCopyObject(authorization);
    if (authorization != nil) YTzoomLatestPlayerAuthorization = authorization;
    state.dataLoader = dataLoader;
    state.context = context;
    state.cryptor = cryptor;
    state.videoID = videoID ?: @"";
    state.observedRequestNumber = requestNumber;
    state.nextRequestNumber = requestNumber + 1;
    state.asynchronous = asynchronous;
    state.capturedAt = NSDate.date;
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomOnesieSessions == nil) {
            YTzoomOnesieSessions = [NSMutableDictionary dictionary];
        }
        YTzoomLastOnesieSession = state;
        if (videoID.length != 0) YTzoomOnesieSessions[videoID] = state;
        YTzoomPruneOnesieSessions();
    }
}

static YTzoomOnesieSessionState *YTzoomOnesieSessionForVideo(
    NSString *videoID) {
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomPruneOnesieSessions();
        YTzoomOnesieSessionState *state = YTzoomOnesieSessions[videoID];
        if (state != nil) return state;
        if (YTzoomLastOnesieSession.videoID.length == 0 ||
            [YTzoomLastOnesieSession.videoID isEqualToString:videoID]) {
            return YTzoomLastOnesieSession;
        }
        return nil;
    }
}

BOOL YTzoomHasNativeOnesieSession(NSString *videoID) {
    return YTzoomOnesieSessionForVideo(videoID) != nil;
}

void YTzoomBuildNativeOnesieRequest(
    NSString *videoID,
    YTzoomNativeRequestCompletion completion) {
    YTzoomOnesieSessionState *state = YTzoomOnesieSessionForVideo(videoID);
    if (state == nil) {
        completion(nil, NSNotFound, [NSError errorWithDomain:@"YTzoomOnesie"
            code:1 userInfo:@{NSLocalizedDescriptionKey:
                @"No native Onesie session is available."}]);
        return;
    }
    NSInteger requestNumber = 0;
    @synchronized (YTzoomSABRDownloader.class) {
        requestNumber = MAX(state.nextRequestNumber,
            state.observedRequestNumber + 1);
        state.nextRequestNumber = requestNumber + 1;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (state.asynchronous && OriginalOnesieRequestAsync != NULL) {
            void (^nativeCompletion)(id, NSError *) = ^(id result, NSError *error) {
                NSURLRequest *request = YTzoomURLRequestFromObject(result);
                if (request != nil) YTzoomSABRSetNativeRequest(request);
                completion(request, requestNumber, error);
            };
            ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))
                OriginalOnesieRequestAsync)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:authorization:dataLoader:"
                         "context:cryptor:requestNumber:completionHandler:"),
                    YTzoomCopyObject(state.playerRequest), state.authorization,
                    state.dataLoader, state.context, state.cryptor,
                    requestNumber, nativeCompletion);
            return;
        }
        if (OriginalOnesieRequest != NULL) {
            NSError *error = nil;
            id result = ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))
                OriginalOnesieRequest)(
                    state.factory,
                    NSSelectorFromString(
                        @"onesieRequestForPlayerRequest:dataLoader:context:"
                         "cryptor:requestNumber:error:"),
                    YTzoomCopyObject(state.playerRequest), state.dataLoader,
                    state.context, state.cryptor, requestNumber, &error);
            NSURLRequest *request = YTzoomURLRequestFromObject(result);
            if (request != nil) YTzoomSABRSetNativeRequest(request);
            completion(request, requestNumber, error);
            return;
        }
        completion(nil, requestNumber, [NSError errorWithDomain:@"YTzoomOnesie"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's native Onesie factory is unavailable."}]);
    });
}

static id YTzoomOnesieRequest(id receiver,
                              SEL selector,
                              id playerRequest,
                              id dataLoader,
                              id context,
                              id cryptor,
                              NSInteger requestNumber,
                              NSError **error) {
    if (YTzoomPlaybackFixMode() == 2) {
        if (error != NULL) {
            *error = [NSError errorWithDomain:@"YTzoomHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}];
        }
        return nil;
    }
    id result = OriginalOnesieRequest != NULL
        ? ((id (*)(id, SEL, id, id, id, id, NSInteger, NSError **))OriginalOnesieRequest)(
            receiver, selector, playerRequest, dataLoader, context, cryptor,
            requestNumber, error)
        : nil;
    NSURLRequest *builtRequest = YTzoomURLRequestFromObject(result);
    if (builtRequest != nil) {
        NSURLRequest *request = builtRequest;
        YTzoomSABRSetNativeRequest(request);
    }
    YTzoomCaptureOnesieSession(receiver, playerRequest, nil, dataLoader,
        context, cryptor, requestNumber, NO);
    return result;
}

static void YTzoomOnesieRequestAsync(id receiver,
                                     SEL selector,
                                     id playerRequest,
                                     id authorization,
                                     id dataLoader,
                                     id context,
                                     id cryptor,
                                     NSInteger requestNumber,
                                     void (^completion)(id, NSError *)) {
    if (YTzoomPlaybackFixMode() == 2) {
        if (completion != nil) {
            completion(nil, [NSError errorWithDomain:@"YTzoomHLS" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Onesie is off for HLS streams."}]);
        }
        return;
    }
    void (^wrapped)(id, NSError *) = ^(id result, NSError *error) {
        NSURLRequest *builtRequest = YTzoomURLRequestFromObject(result);
        if (builtRequest != nil) {
            NSURLRequest *request = builtRequest;
            YTzoomSABRSetNativeRequest(request);
        }
        YTzoomCaptureOnesieSession(receiver, playerRequest, authorization,
            dataLoader, context, cryptor, requestNumber, YES);
        if (completion != nil) completion(result, error);
    };
    if (OriginalOnesieRequestAsync != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id, NSInteger, id))OriginalOnesieRequestAsync)(
            receiver, selector, playerRequest, authorization, dataLoader, context,
            cryptor, requestNumber, wrapped);
    }
}

static void YTzoomOnesieRequestCompletion(id receiver,
                                          SEL selector,
                                          id request,
                                          id error) {
    NSURLRequest *builtRequest = YTzoomURLRequestFromObject(request);
    if (builtRequest != nil) {
        NSURLRequest *URLRequest = builtRequest;
        YTzoomSABRSetNativeRequest(URLRequest);
    }
    if (OriginalOnesieRequestCompletion != NULL) {
        ((void (*)(id, SEL, id, id))OriginalOnesieRequestCompletion)(
            receiver, selector, request, error);
    }
}

static id YTzoomHAMBuildURLRequest(id receiver, SEL selector) {
    id result = OriginalHAMBuildURLRequest != NULL
        ? ((id (*)(id, SEL))OriginalHAMBuildURLRequest)(receiver, selector)
        : nil;
    if ([result isKindOfClass:NSURLRequest.class]) {
        NSURLRequest *request = result;
        NSString *host = request.URL.host.lowercaseString;
        if ([host containsString:@"googlevideo.com"] &&
            [request.HTTPMethod.uppercaseString isEqualToString:@"POST"]) {
            NSData *rawBody = nil;
            SEL bodySelector = NSSelectorFromString(@"HTTPBody");
            if ([receiver respondsToSelector:bodySelector]) {
                rawBody = ((id (*)(id, SEL))objc_msgSend)(receiver, bodySelector);
            }
            NSMutableURLRequest *nativeRequest = [request mutableCopy];
            if ([rawBody isKindOfClass:NSData.class] && rawBody.length != 0) {
                nativeRequest.HTTPBody = rawBody;
                [nativeRequest setValue:nil forHTTPHeaderField:@"Content-Encoding"];
            }
            YTzoomSABRSetNativeRequest(nativeRequest);
        }
    }
    return result;
}

static id YTzoomGetValue(id object, NSArray<NSString *> *keys) {
    if (object == nil) return nil;
    for (NSString *key in keys) {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        }
        @try {
            id value = [object valueForKey:key];
            if (value != nil) return value;
        } @catch (__unused NSException *exception) {
        }
    }
    return nil;
}

static BOOL YTzoomSetValue(id object, NSString *key, id value) {
    if (object == nil || key.length == 0) return NO;
    NSString *first = [[key substringToIndex:1] uppercaseString];
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:", first,
        [key substringFromIndex:1]];
    SEL setter = NSSelectorFromString(setterName);
    if ([object respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(object, setter, value);
        return YES;
    }
    @try {
        [object setValue:value forKey:key];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id YTzoomCopyObject(id object) {
    if ([object respondsToSelector:@selector(copyWithZone:)]) {
        return [object copy];
    }
    return object;
}

static NSString *YTzoomRequestVideoID(id request) {
    id value = YTzoomGetValue(request, @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static void YTzoomCaptureService(id receiver, id request) {
    NSString *videoID = YTzoomRequestVideoID(request);
    if (videoID.length != 0) YTzoomLastCapturedVideoID = videoID;
    YTzoomSABRSetCurrentVideoID(videoID);
    id requestCopy = YTzoomCopyObject(request);
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomLastPlayerService = receiver;
        YTzoomLastPlayerRequest = requestCopy;
        YTzoomUsingRestoredRequest = NO;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTzoomPersistPlayerRequest(requestCopy ?: request);
        });
        if (YTzoomPlayerRequests == nil) YTzoomPlayerRequests = [NSMutableDictionary dictionary];
        if (videoID.length != 0) {
            YTzoomPlayerRequests[videoID] = @[receiver, requestCopy ?: request];
        }
    }
}

static NSMutableDictionary<NSString *, id> *YTzoomPlayerResponses;
static NSMutableArray<NSString *> *YTzoomPlayerResponseOrder;

static NSString *YTzoomResponseVideoID(id response) {
    if (response == nil) return nil;
    id details = YTzoomGetValue(response, @[@"videoDetails"]);
    id value = YTzoomGetValue(details != nil ? details : response,
                              @[@"videoId", @"videoID", @"videoIdString"]);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

__attribute__((unused))
static void YTzoomReportStreamingData(id response) {
    static NSUInteger logged = 0;
    if (response == nil || logged >= 2) return;
    SEL selector = NSSelectorFromString(@"streamingData");
    if (![response respondsToSelector:selector]) {
        YTzoomDownloadLog(@"spoof", @"player response has no streamingData (%@)",
                          NSStringFromClass([response class]));
        logged++;
        return;
    }
    id streaming = ((id (*)(id, SEL))objc_msgSend)(response, selector);
    if (streaming == nil) {
        YTzoomDownloadLog(@"spoof", @"player response streamingData nil");
        logged++;
        return;
    }
    logged++;
    NSString *text = [[streaming description]
        stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([text containsString:@"  "]) {
        text = [text stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    const NSUInteger limit = 1500;
    for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
         offset += limit) {
        const NSUInteger length = MIN(limit, text.length - offset);
        YTzoomDownloadLog(@"spoof", @"streaming[%lu] %@",
                          (unsigned long)(offset / limit),
                          [text substringWithRange:NSMakeRange(offset, length)]);
    }
}

static void YTzoomCachePlayerResponse(id response) {
    if (response == nil) return;
    NSString *videoID =
        [YTzoomStreamResolver videoIDFromPlayerResponse:response];
    if (videoID.length == 0) videoID = YTzoomResponseVideoID(response);
    if (videoID.length == 0) return;
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomPlayerResponses == nil) {
            YTzoomPlayerResponses = [NSMutableDictionary dictionary];
            YTzoomPlayerResponseOrder = [NSMutableArray array];
        }
        if (YTzoomPlayerResponses[videoID] == nil) {
            [YTzoomPlayerResponseOrder addObject:videoID];
        }
        YTzoomPlayerResponses[videoID] = response;
        while (YTzoomPlayerResponseOrder.count > 8) {
            NSString *oldest = YTzoomPlayerResponseOrder.firstObject;
            [YTzoomPlayerResponseOrder removeObjectAtIndex:0];
            [YTzoomPlayerResponses removeObjectForKey:oldest];
        }
    }
}

void YTzoomStorePlayerResponse(NSString *videoID, id response) {
    if (videoID.length == 0 || response == nil) return;
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomPlayerResponses == nil) {
            YTzoomPlayerResponses = [NSMutableDictionary dictionary];
            YTzoomPlayerResponseOrder = [NSMutableArray array];
        }
        if (YTzoomPlayerResponses[videoID] == nil) {
            [YTzoomPlayerResponseOrder addObject:videoID];
        }
        YTzoomPlayerResponses[videoID] = response;
        while (YTzoomPlayerResponseOrder.count > 8) {
            NSString *oldest = YTzoomPlayerResponseOrder.firstObject;
            [YTzoomPlayerResponseOrder removeObjectAtIndex:0];
            [YTzoomPlayerResponses removeObjectForKey:oldest];
        }
    }
}

id YTzoomCachedPlayerResponse(NSString *videoID) {
    if (videoID.length == 0) return nil;
    id original = YTzoomHLSOriginalResponse(videoID);
    if (original != nil) return original;
    @synchronized (YTzoomSABRDownloader.class) {
        return YTzoomPlayerResponses[videoID];
    }
}

static id YTzoomObservedResponseBlock(id responseBlock) {
    if (responseBlock == nil) return nil;
    void (^original)(id, void *) = responseBlock;
    return [^(id playerResponse, void *cacheContext) {
        YTzoomCachePlayerResponse(playerResponse);
        original(playerResponse, cacheContext);
    } copy];
}

static void YTzoomMakePlayerRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    YTzoomCaptureService(receiver, request);
    if (OriginalMakePlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            receiver, selector, request,
            YTzoomObservedResponseBlock(responseBlock), errorBlock
        );
    }
}

static id YTzoomMakePlaybackRequest(id receiver,
                                    SEL selector,
                                    id request,
                                    id responseBlock,
                                    id errorBlock) {
    YTzoomCaptureService(receiver, request);
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomLastPlaybackRequest = YTzoomCopyObject(request);
        NSString *videoID = YTzoomRequestVideoID(request);
        if (YTzoomPlaybackRequests == nil) {
            YTzoomPlaybackRequests = [NSMutableDictionary dictionary];
        }
        if (videoID.length != 0) {
            YTzoomPlaybackRequests[videoID] = YTzoomCopyObject(request);
        }
    }
    return OriginalMakePlaybackRequest != NULL
        ? ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
            receiver, selector, request,
            YTzoomObservedResponseBlock(responseBlock), errorBlock)
        : nil;
}

static void YTzoomMakePrefetchPlayerRequest(id receiver,
                                            SEL selector,
                                            id request,
                                            id responseBlock,
                                            id errorBlock) {
    YTzoomCaptureService(receiver, request);
    if (OriginalMakePrefetchPlayerRequest != NULL) {
        ((void (*)(id, SEL, id, id, id))OriginalMakePrefetchPlayerRequest)(
            receiver, selector, request, responseBlock, errorBlock
        );
    }
}

static void YTzoomCaptureFactory(id receiver, id request, id properties, id result) {
    NSString *videoID = YTzoomRequestVideoID(request);
    if (videoID.length != 0) YTzoomLastCapturedVideoID = videoID;
    YTzoomSABRSetCurrentVideoID(videoID);
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomLastPlayerFactory = receiver;
        YTzoomLastPlayerRequest = YTzoomCopyObject(request);
        YTzoomUsingRestoredRequest = NO;
        id persistCopy = YTzoomLastPlayerRequest;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            YTzoomPersistPlayerRequest(persistCopy);
        });
        YTzoomLastRequestProperties = properties;
        if (videoID.length != 0 && YTzoomLastPlayerService != nil) {
            if (YTzoomPlayerRequests == nil) {
                YTzoomPlayerRequests = [NSMutableDictionary dictionary];
            }
            YTzoomPlayerRequests[videoID] = @[
                YTzoomLastPlayerService, YTzoomCopyObject(request)
            ];
            if (YTzoomLastPlaybackRequest != nil) {
                if (YTzoomPlaybackRequests == nil) {
                    YTzoomPlaybackRequests = [NSMutableDictionary dictionary];
                }
                YTzoomPlaybackRequests[videoID] =
                    YTzoomCopyObject(YTzoomLastPlaybackRequest);
            }
        }
    }
    static BOOL dumped = YES;
    if (!dumped) {
        dumped = YES;
        for (NSArray *pair in @[@[@"request", request ?: [NSNull null]],
                                @[@"result", result ?: [NSNull null]]]) {
            id value = pair[1];
            if (value == [NSNull null]) continue;
            NSString *text = [[value description]
                stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            while ([text containsString:@"  "]) {
                text = [text stringByReplacingOccurrencesOfString:@"  "
                                                       withString:@" "];
            }
            const NSUInteger limit = 1800;
            for (NSUInteger offset = 0; offset < text.length && offset < limit * 3;
                 offset += limit) {
                const NSUInteger length = MIN(limit, text.length - offset);
                YTzoomDownloadLog(@"spoof", @"%@[%lu] %@", pair[0],
                                  (unsigned long)(offset / limit),
                                  [text substringWithRange:NSMakeRange(offset, length)]);
            }
        }
    }
}

static id YTzoomFactoryRequest(id receiver, SEL selector, id request, id properties) {
    YTzoomSABRSetCurrentVideoID(YTzoomRequestVideoID(request));
    id result = OriginalFactoryRequest != NULL
        ? ((id (*)(id, SEL, id, id))OriginalFactoryRequest)(receiver, selector, request, properties)
        : nil;
    YTzoomCaptureFactory(receiver, request, properties, result);
    return result;
}

static id YTzoomFactoryRequestExtended(id receiver,
                                       SEL selector,
                                       id request,
                                       id properties,
                                       BOOL relaxation,
                                       id cacheToken,
                                       BOOL skipCache) {
    YTzoomSABRSetCurrentVideoID(YTzoomRequestVideoID(request));
    id result = OriginalFactoryRequestExtended != NULL
        ? ((id (*)(id, SEL, id, id, BOOL, id, BOOL))OriginalFactoryRequestExtended)(
            receiver, selector, request, properties, relaxation, cacheToken, skipCache)
        : nil;
    YTzoomCaptureFactory(receiver, request, properties, result);
    return result;
}

static id YTzoomLastInnerTubeContext;
static IMP OriginalContextShort;
static IMP OriginalContextMedium;
static IMP OriginalContextLong;

static void YTzoomCaptureContext(id context) {
    if (context == nil) return;
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomLastInnerTubeContext == nil) {
        }
        YTzoomLastInnerTubeContext = context;
    }
}

static id YTzoomContextShort(id receiver, SEL selector, id pageID,
                             BOOL incognito, int criticality, id tracking,
                             BOOL sendIdentifier, long long serviceType) {
    id result = OriginalContextShort == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, long long))OriginalContextShort)(
            receiver, selector, pageID, incognito, criticality, tracking,
            sendIdentifier, serviceType);
    YTzoomCaptureContext(result);
    return result;
}

static id YTzoomContextMedium(id receiver, SEL selector, id pageID,
                              BOOL incognito, int criticality, id tracking,
                              BOOL sendIdentifier, id nonce, id jars,
                              id attestation, long long serviceType) {
    id result = OriginalContextMedium == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, long long))
            OriginalContextMedium)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars,
                attestation, serviceType);
    YTzoomCaptureContext(result);
    return result;
}

static id YTzoomContextLong(id receiver, SEL selector, id pageID,
                            BOOL incognito, int criticality, id tracking,
                            BOOL sendIdentifier, id nonce, id jars,
                            id attestation, id reauth, long long serviceType,
                            BOOL isPrefetch) {
    id result = OriginalContextLong == NULL ? nil :
        ((id (*)(id, SEL, id, BOOL, int, id, BOOL, id, id, id, id, long long, BOOL))
            OriginalContextLong)(receiver, selector, pageID, incognito,
                criticality, tracking, sendIdentifier, nonce, jars, attestation,
                reauth, serviceType, isPrefetch);
    YTzoomCaptureContext(result);
    return result;
}

static IMP OriginalPlayerServiceInit;

static id YTzoomPlayerServiceInit(id receiver, SEL selector) {
    id result = OriginalPlayerServiceInit == NULL ? receiver :
        ((id (*)(id, SEL))OriginalPlayerServiceInit)(receiver, selector);
    if (result != nil) {
        @synchronized (YTzoomSABRDownloader.class) {
            if (YTzoomLastPlayerService == nil) {
                YTzoomLastPlayerService = result;
            }
        }
    }
    return result;
}

static void YTzoomInstallPlayerServiceHook(void) {
    YTzoomInstallInstanceHook(@"YTPlayerService", @"init",
                              (IMP)YTzoomPlayerServiceInit,
                              &OriginalPlayerServiceInit);
    YTzoomInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:serviceType:",
        (IMP)YTzoomContextShort, &OriginalContextShort);
    YTzoomInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:serviceType:",
        (IMP)YTzoomContextMedium, &OriginalContextMedium);
    YTzoomInstallInstanceHook(@"YTAccountScopedInnerTubeContextFactory",
        @"contextWithPageID:isIncognitoActive:criticality:clickTrackingInfo:sendDeviceIdentifier:clientScreenNonce:consistencyTokenJars:attestationResponseData:reauthProofToken:serviceType:isPrefetch:",
        (IMP)YTzoomContextLong, &OriginalContextLong);
    BOOL serviceInstalled = YTzoomInstallInstanceHook(
        @"YTPlayerService",
        @"makePlayerRequest:responseBlock:errorBlock:",
        (IMP)YTzoomMakePlayerRequest,
        &OriginalMakePlayerRequest
    );
    BOOL playbackInstalled = YTzoomInstallInstanceHook(
        @"YTPlayerService",
        @"makePlaybackRequest:responseBlock:errorBlock:",
        (IMP)YTzoomMakePlaybackRequest,
        &OriginalMakePlaybackRequest
    );
    BOOL prefetchInstalled = YTzoomInstallInstanceHook(
        @"YTPlayerService",
        @"makePrefetchPlayerRequest:responseBlock:errorBlock:",
        (IMP)YTzoomMakePrefetchPlayerRequest,
        &OriginalMakePrefetchPlayerRequest
    );
    BOOL factoryInstalled = YTzoomInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:",
        (IMP)YTzoomFactoryRequest,
        &OriginalFactoryRequest
    );
    BOOL extendedInstalled = YTzoomInstallInstanceHook(
        @"YTPlayerRequestFactoryImpl",
        @"requestForPlayerWithPlayerRequest:URLRequestProperties:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:skipInnertubeCacheLookup:",
        (IMP)YTzoomFactoryRequestExtended,
        &OriginalFactoryRequestExtended
    );
    BOOL onesieInstalled = YTzoomInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
        (IMP)YTzoomOnesieRequest,
        &OriginalOnesieRequest
    );
    BOOL onesieAsyncInstalled = YTzoomInstallInstanceHook(
        @"MLOnesieRequestFactory",
        @"onesieRequestForPlayerRequest:authorization:dataLoader:context:cryptor:requestNumber:completionHandler:",
        (IMP)YTzoomOnesieRequestAsync,
        &OriginalOnesieRequestAsync
    );
    BOOL onesieCompletionInstalled = YTzoomInstallInstanceHook(
        @"MLOnesieUMPFetcherTask",
        @"onRequestFactoryCompletionWithRequest:error:",
        (IMP)YTzoomOnesieRequestCompletion,
        &OriginalOnesieRequestCompletion
    );
    BOOL HAMRequestInstalled = YTzoomInstallInstanceHook(
        @"HAMDataLoadRequest",
        @"buildURLRequest",
        (IMP)YTzoomHAMBuildURLRequest,
        &OriginalHAMBuildURLRequest
    );
    if (serviceInstalled && playbackInstalled && prefetchInstalled &&
        factoryInstalled && extendedInstalled && onesieInstalled &&
        onesieAsyncInstalled && onesieCompletionInstalled && HAMRequestInstalled) {
        YTzoomDownloadLog(@"reload", @"player path hooked");
        return;
    }
    YTzoomPlayerHookAttempts += 1;
    if (YTzoomPlayerHookAttempts >= 30) {
        YTzoomDownloadLog(@"reload", @"player path unavailable service=%d playback=%d prefetch=%d factory=%d extended=%d onesie=%d async=%d completion=%d ham=%d",
            serviceInstalled, playbackInstalled, prefetchInstalled,
            factoryInstalled, extendedInstalled, onesieInstalled,
            onesieAsyncInstalled, onesieCompletionInstalled, HAMRequestInstalled);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
        dispatch_get_main_queue(), ^{ YTzoomInstallPlayerServiceHook(); });
}

void YTzoomPreparePlayerWithRoute(NSString *videoID,
                                  BOOL forcePlayerRoute,
                                  YTzoomPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (YTzoomSABRDownloader.class) {
        NSArray *pair = YTzoomPlayerRequests[videoID];
        service = pair.count > 0 ? pair[0] : nil;
        request = pair.count > 1 ? pair[1] : nil;
        playbackRequest = YTzoomPlaybackRequests[videoID];
        if (service == nil &&
            [YTzoomRequestVideoID(YTzoomLastPlayerRequest) isEqualToString:videoID]) {
            service = YTzoomLastPlayerService;
            request = YTzoomLastPlayerRequest;
            playbackRequest = YTzoomLastPlaybackRequest;
        }
    }
    if (service == nil || request == nil) {
        NSError *error = [NSError errorWithDomain:@"YTzoomPlayerPrepare" code:1
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube has not created a player request for this video."}];
        completion(nil, error);
        return;
    }
    if (forcePlayerRoute) playbackRequest = nil;
    YTzoomSABRSetCurrentVideoID(videoID);
    YTzoomDownloadLog(@"prepare", @"native request video=%@ route=%@", videoID,
        playbackRequest != nil && OriginalMakePlaybackRequest != NULL
            ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            completion(YTzoomHLSOriginalResponse(videoID) ?: playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            completion(nil, error);
        };
        if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service,
                NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                YTzoomCopyObject(playbackRequest), response, failure);
        } else if (OriginalMakePlayerRequest != NULL) {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service,
                NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                YTzoomCopyObject(request), response, failure);
        } else {
            NSError *error = [NSError errorWithDomain:@"YTzoomPlayerPrepare" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    @"YouTube's player service is unavailable."}];
            completion(nil, error);
        }
    });
}

void YTzoomPreparePlayer(NSString *videoID,
                         YTzoomPlayerReloadCompletion completion) {
    YTzoomPreparePlayerWithRoute(videoID, NO, completion);
}

static NSURL *YTzoomRequestSeedURL(void) {
    return [YTzoomApplicationSupportDirectory()
        URLByAppendingPathComponent:@"player-request.pb"];
}

static void YTzoomPersistPlayerRequest(id request) {
    static NSTimeInterval lastWrite;
    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - lastWrite < 60.0) return;
    if (![request respondsToSelector:NSSelectorFromString(@"data")]) {
        return;
    }
    NSData *encoded = ((id (*)(id, SEL))objc_msgSend)(
        request, NSSelectorFromString(@"data"));
    if (![encoded isKindOfClass:NSData.class] || encoded.length == 0) return;
    lastWrite = now;
    [encoded writeToURL:YTzoomRequestSeedURL() atomically:YES];
}

void YTzoomDiscardRestoredRequest(void) {
    BOOL restored = NO;
    @synchronized (YTzoomSABRDownloader.class) {
        restored = YTzoomUsingRestoredRequest;
        if (restored) {
            YTzoomLastPlayerRequest = nil;
            YTzoomUsingRestoredRequest = NO;
        }
    }
    if (!restored) return;
    [NSFileManager.defaultManager removeItemAtURL:YTzoomRequestSeedURL()
                                            error:NULL];
    YTzoomDownloadLog(@"resolve", @"discarded stale player request seed");
}

void YTzoomRestorePlayerRequest(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomLastPlayerRequest != nil) return;
    }
    NSData *encoded = [NSData dataWithContentsOfURL:YTzoomRequestSeedURL()];
    if (encoded.length == 0) return;
    Class requestClass = NSClassFromString(@"YTIPlayerRequest");
    SEL parse = NSSelectorFromString(@"parseFromData:error:");
    if (requestClass == Nil || ![requestClass respondsToSelector:parse]) return;
    NSError *error = nil;
    id restored = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(
        requestClass, parse, encoded, &error);
    if (restored == nil) {
        YTzoomDownloadLog(@"resolve", @"request seed parse failed error=%@",
            error.localizedDescription ?: @"unknown");
        return;
    }
    @synchronized (YTzoomSABRDownloader.class) {
        YTzoomLastPlayerRequest = restored;
        YTzoomUsingRestoredRequest = YES;
    }
    YTzoomDownloadLog(@"resolve", @"restored player request bytes=%lu",
        (unsigned long)encoded.length);
}

static IMP OriginalOfflineVideoExecute;
static IMP OriginalOfflineVideoExecuteCompletion;

static __weak UIView *YTzoomMenuSourceView;

static void YTzoomCaptureMenuSource(id view) {
    if ([view isKindOfClass:UIView.class]) {
        YTzoomMenuSourceView = view;
    }
}

static IMP OriginalShowMenuCompletion;
static IMP OriginalShowMenuSkipCompletion;
static IMP OriginalActionsForRenderersLog;

static void YTzoomShowMenuCompletion(id receiver, SEL selector, id renderer,
                                     id view, id entry, id block, BOOL cancel,
                                     BOOL log, id responder, id completion) {
    YTzoomCaptureMenuSource(view);
    if (OriginalShowMenuCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, id, id))
        OriginalShowMenuCompletion)(receiver, selector, renderer, view, entry,
                                    block, cancel, log, responder, completion);
}

static void YTzoomShowMenuSkipCompletion(id receiver, SEL selector, id renderer,
                                         id view, id entry, id block,
                                         BOOL cancel, BOOL log, BOOL skip,
                                         id responder, id completion) {
    YTzoomCaptureMenuSource(view);
    if (OriginalShowMenuSkipCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, BOOL, BOOL, BOOL, id, id))
        OriginalShowMenuSkipCompletion)(receiver, selector, renderer, view,
                                        entry, block, cancel, log, skip,
                                        responder, completion);
}

static id YTzoomActionsForRenderersLog(id receiver, SEL selector, id renderers,
                                       id view, id entry, BOOL log,
                                       id responder) {
    YTzoomQueuePrepareMenuRenderers(renderers);
    YTzoomCaptureMenuSource(view);
    if (OriginalActionsForRenderersLog == NULL) return nil;
    id actions = ((id (*)(id, SEL, id, id, id, BOOL, id))OriginalActionsForRenderersLog)(
        receiver, selector, renderers, view, entry, log, responder);
    YTzoomRouteSpeedMenuItem(renderers, actions, view, responder);
    return actions;
}

static UIView *YTzoomOverflowButtonInside(UIView *root) {
    if (root == nil || root.window == nil) return nil;
    NSString *identifier = root.accessibilityIdentifier.lowercaseString ?: @"";
    if ([identifier containsString:@"menu"] ||
        [identifier containsString:@"overflow"] ||
        [identifier containsString:@"action_button"]) {
        CGRect frame = root.bounds;
        if (CGRectGetWidth(frame) > 8.0 && CGRectGetWidth(frame) < 80.0 &&
            CGRectGetHeight(frame) > 8.0) {
            return root;
        }
    }
    for (UIView *child in root.subviews) {
        UIView *found = YTzoomOverflowButtonInside(child);
        if (found != nil) return found;
    }
    return nil;
}

static NSString *YTzoomOfflineCommandVideoID(id command) {
    for (NSString *name in @[@"offlineVideoEndpoint", @"offlineVideoCommand"]) {
        id endpoint = YTzoomGetValue(command, @[name]);
        id value = YTzoomGetValue(endpoint, @[@"videoId", @"videoID"]);
        if ([value isKindOfClass:NSString.class] && [value length] != 0) {
            return value;
        }
    }
    id direct = YTzoomGetValue(command, @[@"videoId", @"videoID"]);
    if ([direct isKindOfClass:NSString.class] && [direct length] != 0) {
        return direct;
    }
    NSString *dump = nil;
    @try {
        dump = [command description];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    if (dump.length == 0) return nil;
    static NSRegularExpression *expression;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        expression = [NSRegularExpression
            regularExpressionWithPattern:
                @"video_?[Ii]d:\\s*\"([A-Za-z0-9_-]{11})\""
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *match = [expression firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (match != nil) {
        return [dump substringWithRange:[match rangeAtIndex:1]];
    }
    static NSRegularExpression *packed;
    static dispatch_once_t packedToken;
    dispatch_once(&packedToken, ^{
        packed = [NSRegularExpression
            regularExpressionWithPattern:@"\\\\n\\\\013([A-Za-z0-9_-]{11})"
                                 options:0
                                   error:NULL];
    });
    NSTextCheckingResult *packedMatch = [packed firstMatchInString:dump options:0
        range:NSMakeRange(0, dump.length)];
    if (packedMatch != nil) {
        return [dump substringWithRange:[packedMatch rangeAtIndex:1]];
    }
    YTzoomDownloadLog(@"feed", @"no video id in command dump=%@",
        dump.length > 300 ? [dump substringToIndex:300] : dump);
    return nil;
}

static BOOL YTzoomHandleFeedDownload(id command, id view, id sender) {
    const NSInteger placement = YTzoomDownloadPlacement();
    NSString *videoID = YTzoomOfflineCommandVideoID(command);
    UIView *anchor = [view isKindOfClass:UIView.class] ? view : nil;
    if (anchor.window == nil && [sender isKindOfClass:UIView.class]) {
        anchor = sender;
    }
    if (anchor.window == nil) {
        id senderView = YTzoomGetValue(sender, @[@"view", @"contentView", @"cell", @"_cell"]);
        if ([senderView respondsToSelector:@selector(contentView)] &&
            ![senderView isKindOfClass:UIView.class]) {
            senderView = YTzoomGetValue(senderView, @[@"contentView"]);
        }
        if ([senderView isKindOfClass:UIView.class]) {
            UIView *cell = senderView;
            UIView *overflow = YTzoomOverflowButtonInside(cell);
            anchor = overflow ?: cell;
        }
    }
    if (anchor.window == nil && YTzoomMenuSourceView.window != nil) {
        anchor = YTzoomMenuSourceView;
    }
    if (placement != 2 && placement != 3) return NO;
    if (videoID.length == 0) return NO;
    YTzoomShowNotice(YTzoomLocalized(@"Preparing download"));
    YTzoomResolvePlayerResponse(videoID, ^(id response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (response == nil) {
                YTzoomDownloadLog(@"feed", @"resolve failed video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                YTzoomShowNotice(YTzoomLocalized(@"Download unavailable"));
                return;
            }
            [YTzoomDownloadCoordinator.sharedCoordinator
                showDownloadMenuForResponse:response
                                 sourceView:anchor];
        });
    });
    return YES;
}

static void YTzoomOfflineVideoExecute(id receiver, SEL selector, id command,
                                      id entry, id view, id sender) {
    if (YTzoomHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static IMP OriginalLegacyOfflineVideoExecute;

static void YTzoomLegacyOfflineVideoExecute(id receiver, SEL selector, id command,
                                            id entry, id view, id sender) {
    if (YTzoomHandleFeedDownload(command, view, sender)) return;
    if (OriginalLegacyOfflineVideoExecute == NULL) return;
    ((void (*)(id, SEL, id, id, id, id))OriginalLegacyOfflineVideoExecute)(
        receiver, selector, command, entry, view, sender);
}

static void YTzoomOfflineVideoExecuteCompletion(id receiver, SEL selector,
                                                id command, id entry, id view,
                                                id sender, id block) {
    if (YTzoomHandleFeedDownload(command, view, sender)) return;
    if (OriginalOfflineVideoExecuteCompletion == NULL) return;
    ((void (*)(id, SEL, id, id, id, id, id))OriginalOfflineVideoExecuteCompletion)(
        receiver, selector, command, entry, view, sender, block);
}

void YTzoomInstallFeedDownloadHooks(void) {
    YTzoomInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:firstResponder:completion:",
        (IMP)YTzoomShowMenuCompletion, &OriginalShowMenuCompletion);
    YTzoomInstallInstanceHook(@"YTMenuController",
        @"showMenuWithMenuRenderer:fromView:entry:dismissalBlock:addCancelAction:shouldLogItems:skipCollapsedState:firstResponder:completion:",
        (IMP)YTzoomShowMenuSkipCompletion, &OriginalShowMenuSkipCompletion);
    YTzoomInstallInstanceHook(@"YTMenuController",
        @"actionsForRenderers:fromView:entry:shouldLogItems:firstResponder:",
        (IMP)YTzoomActionsForRenderersLog, &OriginalActionsForRenderersLog);
    BOOL a = YTzoomInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:",
        (IMP)YTzoomOfflineVideoExecute, &OriginalOfflineVideoExecute);
    BOOL b = YTzoomInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandlerImpl",
        @"executeWithCommand:entry:fromView:sender:completionBlock:",
        (IMP)YTzoomOfflineVideoExecuteCompletion,
        &OriginalOfflineVideoExecuteCompletion);
    BOOL legacy = NO;
    if (!a) {
        legacy = YTzoomInstallInstanceHook(@"YTOfflineVideoEndpointCommandHandler",
            @"executeWithCommand:entry:fromView:sender:",
            (IMP)YTzoomLegacyOfflineVideoExecute, &OriginalLegacyOfflineVideoExecute);
    }
    YTzoomDownloadLog(@"feed", @"hooks execute=%d completion=%d legacy=%d", a, b, legacy);
}

BOOL YTzoomPlaybackTemplateReady(void) {
    @synchronized (YTzoomSABRDownloader.class) {
        if (YTzoomLastPlayerRequest == nil) return NO;
        if (YTzoomLastPlayerService != nil) return YES;
    }
    return NSClassFromString(@"YTPlayerService") != Nil;
}

void YTzoomResolvePlayerResponse(NSString *videoID,
                                 YTzoomPlayerReloadCompletion completion) {
    if (videoID.length == 0) {
        completion(nil, [NSError errorWithDomain:@"YTzoomPlayerResolve" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No video identifier."}]);
        return;
    }
    id cached = YTzoomCachedPlayerResponse(videoID);
    if (cached != nil) {
        YTzoomDownloadLog(@"resolve", @"cached video=%@", videoID);
        completion(cached, nil);
        return;
    }
    id service = nil;
    id sourceRequest = nil;
    @synchronized (YTzoomSABRDownloader.class) {
        NSArray *pair = YTzoomPlayerRequests[videoID];
        if (pair.count > 1) {
            service = pair[0];
            sourceRequest = pair[1];
        } else {
            service = YTzoomLastPlayerService;
            sourceRequest = YTzoomLastPlayerRequest;
        }
    }
    if (service == nil) {
        Class serviceClass = NSClassFromString(@"YTPlayerService");
        if (serviceClass != Nil) {
            @try {
                service = [[serviceClass alloc] init];
            } @catch (__unused NSException *exception) {
                service = nil;
            }
            YTzoomDownloadLog(@"resolve", @"constructed player service=%d",
                service != nil);
            if (service != nil) {
                @synchronized (YTzoomSABRDownloader.class) {
                    if (YTzoomLastPlayerService == nil) {
                        YTzoomLastPlayerService = service;
                    }
                }
            }
        }
    }
    if (sourceRequest == nil && YTzoomLastInnerTubeContext != nil) {
        id built = [NSClassFromString(@"YTIPlayerRequest") new];
        if (YTzoomSetValue(built, @"context",
                           YTzoomCopyObject(YTzoomLastInnerTubeContext))) {
            sourceRequest = built;
        }
    }
    if (service == nil || sourceRequest == nil || OriginalMakePlayerRequest == NULL) {
        completion(nil, [NSError errorWithDomain:@"YTzoomPlayerResolve" code:2
            userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:
                    @"No player request template (service=%d context=%d).",
                    service != nil, YTzoomLastInnerTubeContext != nil]}]);
        return;
    }
    id request = YTzoomCopyObject(sourceRequest);
    if (!YTzoomSetValue(request, @"videoId", videoID)) {
        completion(nil, [NSError errorWithDomain:@"YTzoomPlayerResolve" code:3
            userInfo:@{NSLocalizedDescriptionKey:
                @"YouTube's player request could not be retargeted."}]);
        return;
    }
    YTzoomSetValue(request, @"playlistId", @"");
    YTzoomSetValue(request, @"params", @"");
    YTzoomSetValue(request, @"playlistIndex", @0);
    id playback = YTzoomGetValue(request, @[@"playbackContext"]);
    id contentPlayback = YTzoomGetValue(playback, @[@"contentPlaybackContext"]);
    YTzoomSetValue(contentPlayback, @"currentUrl", @"");
    YTzoomSetValue(contentPlayback, @"referer", @"");
    YTzoomDownloadLog(@"resolve", @"request video=%@", videoID);
    dispatch_async(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
            service,
            NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
            request,
            ^(id receivedResponse, __unused id cacheContext) {
                id playerResponse = YTzoomHLSOriginalResponse(videoID) ?: receivedResponse;
                NSString *resolved = nil;
                id details = YTzoomGetValue(playerResponse, @[@"videoDetails"]);
                id value = YTzoomGetValue(details, @[@"videoId", @"videoID"]);
                if ([value isKindOfClass:NSString.class]) resolved = value;
                id streaming = YTzoomGetValue(playerResponse, @[@"streamingData"]);
                if (streaming == nil) {
                    id nested = YTzoomGetValue(playerResponse, @[@"playerData"]);
                    streaming = YTzoomGetValue(nested, @[@"streamingData"]);
                }
                id ustreamer = YTzoomGetValue(streaming,
                    @[@"mediaUstreamerRequestConfig"]);
                id config = YTzoomGetValue(ustreamer,
                    @[@"videoPlaybackUstreamerConfig"]);
                YTzoomDownloadLog(@"resolve",
                    @"response video=%@ resolved=%@ streaming=%d ustreamer=%d config=%d",
                    videoID, resolved ?: @"none", streaming != nil,
                    ustreamer != nil, config != nil);
                if (playerResponse != nil) {
                    YTzoomStorePlayerResponse(videoID, playerResponse);
                }
                completion(playerResponse, nil);
            },
            ^(NSError *error) {
                YTzoomDownloadLog(@"resolve", @"error video=%@ error=%@",
                    videoID, error.localizedDescription ?: @"unknown");
                completion(nil, error);
            });
    });
}

void YTzoomReloadPlayer(NSString * _Nullable videoID,
                        NSString *token,
                        YTzoomPlayerReloadCompletion completion) {
    id service = nil;
    id request = nil;
    id playbackRequest = nil;
    @synchronized (YTzoomSABRDownloader.class) {
        NSArray *pair = videoID.length != 0 ? YTzoomPlayerRequests[videoID] : nil;
        service = pair.count > 0 ? pair[0] : YTzoomLastPlayerService;
        request = pair.count > 1 ? pair[1] : YTzoomLastPlayerRequest;
        playbackRequest = YTzoomLastPlaybackRequest;
    }
    if ((OriginalMakePlayerRequest == NULL && OriginalMakePlaybackRequest == NULL) ||
        service == nil || request == nil || token.length == 0) {
        NSError *error = [NSError errorWithDomain:@"YTzoomPlayerReload" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No matching YouTube player request is available."}];
        completion(nil, error);
        return;
    }
    id mutableRequest = YTzoomCopyObject(request);
    id playback = YTzoomCopyObject(YTzoomGetValue(mutableRequest, @[@"playbackContext"]));
    if (playback == nil) playback = [NSClassFromString(@"YTIPlaybackContext") new];
    id params = [NSClassFromString(@"YTIReloadPlaybackParams") new];
    id reload = [NSClassFromString(@"YTIReloadPlaybackContext") new];
    BOOL configured = YTzoomSetValue(params, @"token", token) &&
        YTzoomSetValue(reload, @"reloadPlaybackParams", params) &&
        YTzoomSetValue(playback, @"reloadPlaybackContext", reload) &&
        YTzoomSetValue(mutableRequest, @"playbackContext", playback);
    if (!configured) {
        NSError *error = [NSError errorWithDomain:@"YTzoomPlayerReload" code:2
            userInfo:@{NSLocalizedDescriptionKey: @"YouTube's reload request could not be configured."}];
        completion(nil, error);
        return;
    }
    id routedRequest = nil;
    if (playbackRequest != nil && OriginalMakePlaybackRequest != NULL) {
        Class playbackClass = NSClassFromString(@"YTPlaybackRequest");
        SEL initializer = NSSelectorFromString(
            @"initWithProtoRequest:URLRequestProperties:CPN:QOEController:latencyLogger:streamingWatchEnabled:enablePlayerResponseCacheKeyRelaxation:playerResponseCacheToken:streamingWatchHandlers:");
        id allocated = [playbackClass alloc];
        if ([allocated respondsToSelector:initializer]) {
            BOOL streaming = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"streamingWatchEnabled"));
            BOOL relaxation = ((BOOL (*)(id, SEL))objc_msgSend)(
                playbackRequest, NSSelectorFromString(@"enablePlayerResponseCacheKeyRelaxation"));
            routedRequest = ((id (*)(id, SEL, id, id, id, id, id, BOOL, BOOL, id, id))objc_msgSend)(
                allocated,
                initializer,
                mutableRequest,
                YTzoomGetValue(playbackRequest, @[@"URLRequestProperties"]),
                YTzoomGetValue(playbackRequest, @[@"CPN"]),
                YTzoomGetValue(playbackRequest, @[@"QOEController"]),
                YTzoomGetValue(playbackRequest, @[@"latencyLogger"]),
                streaming,
                relaxation,
                YTzoomGetValue(playbackRequest, @[@"playerResponseCacheToken"]),
                YTzoomGetValue(playbackRequest, @[@"streamingWatchHandlers"])
            );
        }
    }
    YTzoomDownloadLog(@"reload", @"native request video=%@ token=%lu route=%@",
        videoID ?: @"unknown", (unsigned long)token.length,
        routedRequest != nil ? @"playback" : @"player");
    dispatch_async(dispatch_get_main_queue(), ^{
        void (^response)(id, id) = ^(id playerResponse, __unused id cacheContext) {
            YTzoomDownloadLog(@"reload", @"native response video=%@ class=%@",
                videoID ?: @"unknown", NSStringFromClass([playerResponse class]));
            completion(playerResponse, nil);
        };
        void (^failure)(NSError *) = ^(NSError *error) {
            YTzoomDownloadLog(@"reload", @"native error video=%@ error=%@",
                videoID ?: @"unknown", error.localizedDescription ?: @"unknown");
            completion(nil, error);
        };
        if (routedRequest != nil && OriginalMakePlaybackRequest != NULL) {
            ((id (*)(id, SEL, id, id, id))OriginalMakePlaybackRequest)(
                service, NSSelectorFromString(@"makePlaybackRequest:responseBlock:errorBlock:"),
                routedRequest, response, failure
            );
        } else {
            ((void (*)(id, SEL, id, id, id))OriginalMakePlayerRequest)(
                service, NSSelectorFromString(@"makePlayerRequest:responseBlock:errorBlock:"),
                mutableRequest, response, failure
            );
        }
    });
}

static id YTzoomMintWithVideoID(id receiver, SEL selector, id videoID) {
    if ([videoID isKindOfClass:NSString.class]) YTzoomSABRSetCurrentVideoID(videoID);
    id result = nil;
    if (OriginalMintWithVideoID != NULL) {
        result = ((id (*)(id, SEL, id))OriginalMintWithVideoID)(receiver, selector, videoID);
    }
    YTzoomSABRSetPoToken(result);
    if ([videoID isKindOfClass:NSString.class]) {
        static NSMutableArray<NSString *> *logged;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ logged = [NSMutableArray array]; });
        BOOL fresh = NO;
        @synchronized (logged) {
            if (![logged containsObject:videoID]) {
                [logged addObject:videoID];
                if (logged.count > 30) [logged removeObjectAtIndex:0];
                fresh = YES;
            }
        }
        if (fresh) {
            YTzoomDownloadLog(@"token", @"video=%@ potoken=%lu", videoID,
                              (unsigned long)YTzoomSABRPoTokenLength());
        }
    }
    return result;
}

static void YTzoomSetPlayerResponse(id receiver,
                                    SEL selector,
                                    id playerResponse,
                                    id cpn) {
    if (OriginalSetPlayerResponse != NULL) {
        ((void (*)(id, SEL, id, id))OriginalSetPlayerResponse)(
            receiver, selector, playerResponse, cpn
        );
    }
    YTzoomDownloadCoordinator.sharedCoordinator.playerResponse = playerResponse;
}

static void YTzoomSetPoToken(id receiver, SEL selector, NSData *token) {
    if (OriginalSetPoToken != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPoToken)(receiver, selector, token);
    }
    YTzoomSABRSetPoToken(token);
}

void YTzoomInstallDownloadHooks(void) {
    YTzoomInstallInstanceHook(@"YTProofOfOriginTokenManager",
                              @"mintWithVideoID:",
                              (IMP)YTzoomMintWithVideoID,
                              &OriginalMintWithVideoID);
    YTzoomInstallInstanceHook(@"YTIServiceIntegrityDimensions",
                              @"setPoToken:",
                              (IMP)YTzoomSetPoToken,
                              &OriginalSetPoToken);
    YTzoomInstallPlayerServiceHook();
    YTzoomInstallInstanceHook(@"MLOnesieRequestFactory",
                              @"onesieRequestForPlayerRequest:dataLoader:context:cryptor:requestNumber:error:",
                              (IMP)YTzoomOnesieRequest,
                              &OriginalOnesieRequest);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPlayerResponse:CPN:",
                              (IMP)YTzoomSetPlayerResponse,
                              &OriginalSetPlayerResponse);


    YTzoomRegisterOverlayConfigurator(@"downloads", ^(UIView *overlay, UIStackView *stack) {
        (void)overlay;
        UIButton *button = YTzoomOverlayButton(
            stack,
            @"YTzoom Download",
            @"arrow.down.circle.fill",
            YTzoomDownloadCoordinator.sharedCoordinator,
            @selector(showDownloadMenuFromButton:)
        );
        [button setImage:YTzoomDownloadGlyphImage()
                forState:UIControlStateNormal];
        const NSInteger placement = YTzoomDownloadPlacement();
        button.hidden = placement != 1 && placement != 3;
    });
}
