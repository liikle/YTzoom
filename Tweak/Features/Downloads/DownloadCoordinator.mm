#import "DownloadCoordinator.h"
#import "../../UI/OverlayButtonHost.h"
#import "../../YTzoom.h"
#import "DownloadLog.h"
#import "DownloadSponsor.h"
#import "DownloadProgressView.h"
#import "FFmpegMuxer.h"
#import "SABRDownloader.h"
#import "DirectDownloader.h"
#import <VideoToolbox/VideoToolbox.h>
#import "StreamResolver.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"
#import "../../Settings/YTzoomDownloadsController.h"
#import "../../Settings/YTzoomRootOptionsController.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"

#import <AVKit/AVKit.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>

@interface YTzoomDownloadJob : NSObject
@property(nonatomic, strong) NSURLSessionDownloadTask *task;
@property(nonatomic, strong) YTzoomSABRTask *sabrTask;
@property(nonatomic, strong) YTzoomDirectTask *directTask;
@property(nonatomic, assign) BOOL useDirect;
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *author;
@property(nonatomic, copy) NSString *videoID;
@property(nonatomic, copy) NSString *category;
@property(nonatomic, copy) NSString *extension;
@property(nonatomic, strong) NSURL *thumbnailURL;
@property(nonatomic, strong) id playerResponse;
@property(nonatomic, strong) YTzoomStreamOption *videoOption;
@property(nonatomic, strong) YTzoomStreamOption *audioOption;
@property(nonatomic, assign) BOOL audioOnly;
@property(nonatomic, assign) BOOL cancelled;
@property(nonatomic, assign) NSInteger fallbackCount;
@property(nonatomic, assign) int64_t audioBytes;
@property(nonatomic, assign) int64_t videoBytes;
@property(nonatomic, strong, nullable) NSURL *savedURL;
@property(nonatomic, assign) BOOL savesToPhotos;
@property(nonatomic, assign) BOOL sharesFile;
@property(nonatomic, strong, nullable) NSURL *captionURL;
@property(nonatomic, copy, nullable) NSString *captionLanguage;
@end

static const void *YTzoomShortsFullscreenKey = &YTzoomShortsFullscreenKey;
static const void *YTzoomShortsFullscreenAlphaKey =
    &YTzoomShortsFullscreenAlphaKey;
static NSInteger const YTzoomShortsDownloadButtonTag = 0x59544B44;

static BOOL YTzoomContainsShortsDownloadButton(UIView *view) {
    if (view.tag == YTzoomShortsDownloadButtonTag) return YES;
    for (UIView *subview in view.subviews) {
        if (YTzoomContainsShortsDownloadButton(subview)) return YES;
    }
    return NO;
}

void YTzoomSetShortsOverlayFullscreen(UIView *overlay,
                                      BOOL fullscreen) {
    for (UIView *subview in overlay.subviews) {
        if (YTzoomContainsShortsDownloadButton(subview)) continue;
        if (fullscreen) {
            if (objc_getAssociatedObject(
                    subview, YTzoomShortsFullscreenAlphaKey) == nil) {
                objc_setAssociatedObject(subview,
                    YTzoomShortsFullscreenAlphaKey, @(subview.alpha),
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            subview.alpha = 0.0;
        } else {
            NSNumber *alpha = objc_getAssociatedObject(
                subview, YTzoomShortsFullscreenAlphaKey);
            if (alpha != nil) {
                subview.alpha = alpha.doubleValue;
                objc_setAssociatedObject(subview,
                    YTzoomShortsFullscreenAlphaKey, nil,
                    OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        }
    }
}

static void YTzoomCollectShortsElements(UIView *view, NSMutableArray<UIView *> *found, NSUInteger depth) {
    if (view == nil || depth > 12) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name isEqualToString:@"YTReelElementAsyncComponentView"] ||
        [name isEqualToString:@"YTReelGradientView"] ||
        [name hasPrefix:@"YTShortsStickersView"]) {
        [found addObject:view];
        return;
    }
    for (UIView *subview in view.subviews) YTzoomCollectShortsElements(subview, found, depth + 1);
}

void YTzoomSetShortsElementsFullscreen(UIView *container, BOOL fullscreen) {
    NSMutableArray<UIView *> *elements = [NSMutableArray array];
    YTzoomCollectShortsElements(container, elements, 0);
    for (UIView *element in elements) {
        if (YTzoomContainsShortsDownloadButton(element)) continue;
        if (fullscreen) {
            if (objc_getAssociatedObject(element, YTzoomShortsFullscreenAlphaKey) == nil) {
                objc_setAssociatedObject(element, YTzoomShortsFullscreenAlphaKey, @(element.alpha),
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            element.alpha = 0.0;
        } else {
            NSNumber *alpha = objc_getAssociatedObject(element, YTzoomShortsFullscreenAlphaKey);
            element.alpha = alpha != nil ? alpha.doubleValue : 1.0;
            objc_setAssociatedObject(element, YTzoomShortsFullscreenAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

UIView *YTzoomShortsContainerForView(UIView *view, UIView *fallbackRoot) {
    Class containerClass = NSClassFromString(@"YTReelContainerView");
    if (containerClass == Nil) return nil;
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:containerClass]) return candidate;
    }
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:fallbackRoot ?: [UIView new]];
    while (stack.count != 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:containerClass] && candidate.window != nil &&
            CGRectIntersectsRect([candidate convertRect:candidate.bounds toView:nil], candidate.window.bounds)) {
            return candidate;
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL YTzoomShortsGlobalFullscreen;
static NSHashTable<UIView *> *YTzoomFadedShortsContainers;
static BOOL YTzoomShortsPivotBypass;

BOOL YTzoomShortsPivotShowBlocked(void) {
    return YTzoomShortsGlobalFullscreen && !YTzoomShortsPivotBypass;
}

BOOL YTzoomShortsNewFullscreenActive(void) {
    return YTzoomShortsGlobalFullscreen;
}

void YTzoomFadeShortsElement(UIView *element) {
    if (element == nil || element.alpha <= 0.01 || YTzoomContainsShortsDownloadButton(element)) return;
    if (objc_getAssociatedObject(element, YTzoomShortsFullscreenAlphaKey) == nil) {
        objc_setAssociatedObject(element, YTzoomShortsFullscreenAlphaKey, @(element.alpha),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    element.alpha = 0.0;
}

void YTzoomRegisterFadedShortsContainer(UIView *container) {
    if (container == nil) return;
    if (YTzoomFadedShortsContainers == nil) YTzoomFadedShortsContainers = [NSHashTable weakObjectsHashTable];
    [YTzoomFadedShortsContainers addObject:container];
}

void YTzoomSetShortsNewFullscreen(UIView *container, BOOL fullscreen) {
    YTzoomShortsGlobalFullscreen = fullscreen;
    SEL pivotSelector = NSSelectorFromString(fullscreen ? @"hidePivotBar" : @"showPivotBar");
    YTzoomShortsPivotBypass = YES;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            id root = window.rootViewController;
            if ([root respondsToSelector:pivotSelector]) ((void (*)(id, SEL))objc_msgSend)(root, pivotSelector);
        }
    }
    YTzoomShortsPivotBypass = NO;
    if (fullscreen) {
        if (container == nil) return;
        YTzoomRegisterFadedShortsContainer(container);
        [UIView animateWithDuration:0.25 animations:^{
            YTzoomSetShortsElementsFullscreen(container, YES);
        }];
        return;
    }
    NSArray<UIView *> *faded = YTzoomFadedShortsContainers.allObjects;
    [YTzoomFadedShortsContainers removeAllObjects];
    [UIView animateWithDuration:0.25 animations:^{
        for (UIView *view in faded) YTzoomSetShortsElementsFullscreen(view, NO);
    }];
}

@implementation YTzoomDownloadJob
@end

@interface YTzoomDownloadCoordinator () <NSURLSessionDownloadDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, YTzoomDownloadJob *> *jobs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTzoomDownloadJob *> *activeJobs;
@property(nonatomic, strong) NSMutableDictionary<NSString *, YTzoomDownloadJob *> *retryableJobs;
@property(nonatomic, weak) UIView *downloadSourceView;
@property(nonatomic, strong, nullable) id externalResponse;
@property(nonatomic, weak) UIView *externalSourceView;
@property(nonatomic, assign) BOOL pendingSavesToPhotos;
@property(nonatomic, assign) BOOL pendingSharesFile;
@property(nonatomic, assign) BOOL batchSharing;
@property(nonatomic, strong) NSMutableArray<NSURL *> *batchShareURLs;
@property(nonatomic, copy, nullable) NSArray<YTzoomStreamOption *> *directOptions;
@property(nonatomic, copy, nullable) NSString *directOptionsVideoID;
@property(nonatomic, assign) BOOL forceSABRNext;
- (void)resolveSaveDestinationFromView:(nullable UIView *)sourceView
                                  then:(dispatch_block_t)continuation;
- (void)showAudioLanguagesForVideo:(nullable YTzoomStreamOption *)videoOption
                         audioOnly:(BOOL)audioOnly
                          category:(NSString *)category;
- (void)beginSABRDownloadVideo:(nullable YTzoomStreamOption *)videoOption
                         audio:(YTzoomStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                      category:(NSString *)category;
- (void)presentShareSheetForURL:(NSURL *)url;
- (void)launchJob:(YTzoomDownloadJob *)job;
- (void)retryJobWithIdentifier:(NSString *)identifier;
- (void)resolveAudioDestinationFromView:(nullable UIView *)sourceView
                                   then:(dispatch_block_t)continuation;
- (void)mergeVideoURL:(NSURL *)videoURL audioURL:(NSURL *)audioURL
                   job:(YTzoomDownloadJob *)job;
- (void)saveCompletedURL:(NSURL *)URL job:(YTzoomDownloadJob *)job
                extension:(NSString *)extension;
- (void)startSABRJob:(YTzoomDownloadJob *)job;
- (nullable YTzoomStreamOption *)fallbackVideoForJob:(YTzoomDownloadJob *)job;
- (NSString *)safeFilename:(NSString *)filename;
- (NSString *)failureMessageForError:(nullable NSError *)error
                                  job:(nullable YTzoomDownloadJob *)job;
@end

static NSString * const YTzoomSaveLocationKey =
    @"YTzoom.Preference.Downloads.SaveLocation";
static NSString * const YTzoomAudioSaveLocationKey =
    @"YTzoom.Preference.Downloads.AudioSaveLocation";

void YTzoomSaveVideoToPhotosFile(NSURL *url,
                                 void (^completion)(BOOL, NSError *)) {
    if (url == nil) {
        if (completion != NULL) completion(NO, nil);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSNumber *size = nil;
        [url getResourceValue:&size forKey:NSURLFileSizeKey error:NULL];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSMutableString *codecs = [NSMutableString string];
        for (AVAssetTrack *track in asset.tracks) {
            for (id description in track.formatDescriptions) {
                const FourCharCode subtype = CMFormatDescriptionGetMediaSubType(
                    (CMFormatDescriptionRef)description);
                [codecs appendFormat:@"%c%c%c%c ",
                 (char)((subtype >> 24) & 0xFF), (char)((subtype >> 16) & 0xFF),
                 (char)((subtype >> 8) & 0xFF), (char)(subtype & 0xFF)];
            }
        }
        YTzoomDownloadLog(@"photos", @"save %@ bytes=%@ codecs=[%@]",
                          url.lastPathComponent, size, codecs);

        void (^save)(void) = ^{
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:url];
            } completionHandler:^(BOOL success, NSError *error) {
                if (!success) {
                    YTzoomDownloadLog(@"photos", @"failed domain=%@ code=%ld",
                                      error.domain, (long)error.code);
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion != NULL) completion(success, error);
                });
            }];
        };

        void (^afterAuthorization)(PHAuthorizationStatus) =
            ^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized ||
                status == PHAuthorizationStatusLimited) {
                save();
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                YTzoomShowNotice(YTzoomLocalized(
                    @"YouTube needs permission to add to Photos."));
                if (completion != NULL) completion(NO, nil);
            });
        };

        if (@available(iOS 14.0, *)) {
            [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                       handler:afterAuthorization];
        } else {
            [PHPhotoLibrary requestAuthorization:afterAuthorization];
        }
    });
}

@implementation YTzoomDownloadCoordinator

+ (instancetype)sharedCoordinator {
    static YTzoomDownloadCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTzoomDownloadCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _jobs = [NSMutableDictionary dictionary];
        _activeJobs = [NSMutableDictionary dictionary];
        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForRequest = 30.0;
        configuration.timeoutIntervalForResource = 60.0 * 60.0;
        NSOperationQueue *queue = [NSOperationQueue new];
        queue.maxConcurrentOperationCount = 3;
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:queue];
        __weak YTzoomDownloadCoordinator *weakSelf = self;
        YTzoomDownloadProgressView.sharedView.retryHandler = ^(NSString *identifier) {
            [weakSelf retryJobWithIdentifier:identifier];
        };
        YTzoomDownloadProgressView.sharedView.cancelHandler = ^(NSString *identifier) {
            YTzoomDownloadJob *job = weakSelf.activeJobs[identifier];
            if (job != nil && job.sabrTask == nil && job.task == nil && job.directTask == nil) {
                job.cancelled = YES;
                [YTzoomDownloadProgressView.sharedView finishJob:identifier
                    success:NO message:YTzoomLocalized(@"Cancelled")];
                [weakSelf.activeJobs removeObjectForKey:identifier];
                YTzoomDownloadLog(identifier, @"cancelled before start");
                return;
            }
            [job.sabrTask cancel];
            [job.directTask cancel];
            YTzoomFFmpegCancelConversion(identifier);
        };
    }
    return self;
}

- (UIViewController *)topViewController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        controller = ((UINavigationController *)controller).visibleViewController;
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        controller = ((UITabBarController *)controller).selectedViewController;
    }
    return controller;
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    NSString *notice = title.length != 0 && message.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", title, message]
        : (title.length != 0 ? title : message);
    [self showCompactNotice:notice];
}

- (NSString *)failureMessageForError:(NSError *)error
                                  job:(YTzoomDownloadJob *)job {
    NSString *detail = error.localizedDescription ?: YTzoomLocalized(@"The download did not complete.");
    if (error.code == NSURLErrorCancelled) return YTzoomLocalized(@"The download was cancelled.");
    if ([error.domain isEqualToString:@"YTzoomSABR"]) {
        switch (error.code) {
            case 1:
            case 2:
                return YTzoomLocalized(@"No usable download session came back. Start the video briefly so a fresh one is issued, then try again.");
            case 4:
                return YTzoomLocalized(@"The stream request was turned down. Close and reopen the video, let it play for a moment, then try again.");
            case 5:
            case 8:
                return YTzoomLocalized(@"The transfer ended early. Try once more, or drop to a lower quality.");
            case 6:
                return YTzoomLocalized(@"This format is not permitted on this device. Pick a different quality.");
            case 9:
                return YTzoomLocalized(@"The high-resolution stream could not be refreshed. Give the video a moment of playback and try again.");
            case 10:
                return YTzoomLocalized(@"This video has not been set up for streaming yet. Start playing it for a second or two, then try the download again.");
            default:
                break;
        }
    }
    if ([error.domain isEqualToString:@"YTzoomFFmpeg"]) {
        NSString *quality = job.videoOption.qualityLabel.length != 0
            ? job.videoOption.qualityLabel : YTzoomLocalized(@"selected quality");
        return [NSString stringWithFormat:
            YTzoomLocalized(@"%@ downloaded, but its video and audio could not be merged. Try another %@ format.\n%@"),
            quality, quality, detail];
    }
    if ([error.domain isEqualToString:NSURLErrorDomain]) {
        if (error.code == NSURLErrorNotConnectedToInternet) {
            return YTzoomLocalized(@"The network connection is offline. Reconnect and retry.");
        }
        if (error.code == NSURLErrorTimedOut) {
            return YTzoomLocalized(@"The download timed out. Retry on a stable connection.");
        }
    }
    return detail;
}

- (id)findPlayerResponseFromObject:(id)object
                           visited:(NSHashTable *)visited
                             depth:(NSUInteger)depth
                             trace:(BOOL)trace {
    if (object == nil || depth > 14 || [visited containsObject:object]) {
        return nil;
    }
    [visited addObject:object];
    SEL dataSelector = NSSelectorFromString(@"playerData");
    if ([object respondsToSelector:dataSelector]) {
        id data = ((id (*)(id, SEL))objc_msgSend)(object, dataSelector);
        if (data != nil) {
            return object;
        }
    }
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse",
                              @"_youtubeiOSPlayerViewController",
                              @"parentViewController", @"eventsDelegate",
                              @"parentResponder", @"playbackController"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id related = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        id response = [self findPlayerResponseFromObject:related
                                                 visited:visited
                                                   depth:depth + 1
                                                   trace:trace];
        if (response != nil) {
            return response;
        }
    }
    if ([object isKindOfClass:UIResponder.class]) {
        return [self findPlayerResponseFromObject:
            ((UIResponder *)object).nextResponder visited:visited
                                                   depth:depth + 1
                                                   trace:trace];
    }
    return nil;
}

- (id)playerResponseFromView:(UIView *)view {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return [self findPlayerResponseFromObject:view visited:visited depth:0 trace:NO];
}

- (id)tracedPlayerResponseFromView:(UIView *)view {
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality];
    return [self findPlayerResponseFromObject:view visited:visited depth:0 trace:NO];
}

- (id)videoOverlayControllerFromView:(UIView *)view {
    UIResponder *current = view;
    Class overlayClass = NSClassFromString(
        @"YTMainAppVideoPlayerOverlayViewController");
    for (NSUInteger depth = 0; current != nil && depth < 24; depth++) {
        if (overlayClass != Nil && [current isKindOfClass:overlayClass]) {
            return current;
        }
        current = current.nextResponder;
    }
    return nil;
}

- (id)videoPlayerResponseFromView:(UIView *)view {
    id overlay = [self videoOverlayControllerFromView:view];
    SEL parentSelector = NSSelectorFromString(@"parentViewController");
    id playerController = [overlay respondsToSelector:parentSelector]
        ? ((id (*)(id, SEL))objc_msgSend)(overlay, parentSelector) : nil;
    for (NSString *name in @[@"contentPlayerResponse", @"playerResponse"]) {
        SEL selector = NSSelectorFromString(name);
        if ([playerController respondsToSelector:selector]) {
            id response = ((id (*)(id, SEL))objc_msgSend)(playerController, selector);
            if (response != nil) {
                return response;
            }
        }
    }
    return [self playerResponseFromView:view];
}

- (UIImage *)menuIcon:(NSString *)symbol {
    NSDictionary<NSString *, NSString *> *assets = @{
        @"play": @"ig_icon_play_outline_24_Normal",
        @"music.note": @"yt_outline_music_24pt",
        @"play.circle": @"play_arrow_circle_24pt_3x_Normal",
        @"photo": @"youtube_outline_image_24pt",
        @"doc.on.doc": @"yt_outline_copy_24pt",
        @"chevron.right": @"yt_outline_chevron_right_24pt_2x_Normal",
        @"arrow.up.left.and.arrow.down.right": @"ic_fullscreen_3x_Normal",
        @"arrow.down.right.and.arrow.up.left": @"ic_fullscreen_exit_3x_Normal",
        @"ytzoom.system": @"ig_icon_play_outline_24_Normal",
        @"ytzoom.infuse": @"play.tv",
        @"ytzoom.vlc": @"play.circle"
    };
    UIImage *image = YTzoomAssetImage(assets[symbol] ?: @"", symbol);
    if (image != nil) {
        if ([symbol isEqualToString:@"ytzoom.infuse"])
            return [[UIImage systemImageNamed:@"play.tv"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        if ([symbol isEqualToString:@"ytzoom.vlc"])
            return [[UIImage systemImageNamed:@"play.circle"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:20.0
                                                        weight:UIImageSymbolWeightRegular];
    return [[UIImage systemImageNamed:symbol withConfiguration:configuration]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (void)presentNativeSheetWithTitle:(NSString *)title
                           subtitle:(NSString *)subtitle
                         sourceView:(UIView *)sourceView
                            actions:(NSArray<NSDictionary *> *)actions {

    id presenter = [self topViewController];
    UIResponder *responder = sourceView;
    id sourceController = nil;
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        if ([responder isKindOfClass:UIViewController.class]) {
            sourceController = (UIViewController *)responder;
        }
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([responder respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(responder, eventsSelector);
            if (events != nil) {
                sourceController = events;
                break;
            }
        }
        responder = responder.nextResponder;
    }
    presenter = sourceController ?: presenter;
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeDetailed = NSSelectorFromString(
        @"actionWithTitle:iconImage:secondaryIconImage:accessibilityIdentifier:handler:");
    SEL makeSimple = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    id sheet = actionClass != Nil
        ? YTzoomMakeSheet(title.length != 0 ? title : nil, subtitle.length != 0 ? subtitle : nil)
        : nil;
    if (sheet != nil) {
        if (title.length != 0 || subtitle.length != 0) {
            @try {
                id header = [sheet valueForKey:@"_headerView"];
                SEL divider = NSSelectorFromString(@"showHeaderDivider");
                if ([header respondsToSelector:divider]) {
                    ((void (*)(id, SEL))objc_msgSend)(header, divider);
                }
            } @catch (__unused NSException *exception) {
            }
        }
        for (NSDictionary *item in actions) {
            dispatch_block_t handler = item[@"handler"];
            UIImage *icon = item[@"icon"];
            UIImage *secondary = item[@"secondary"];
            id action = nil;
            if (secondary != nil && [actionClass respondsToSelector:makeDetailed]) {
                action = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
                    actionClass, makeDetailed, item[@"title"], icon, secondary, nil,
                    handler);
            } else if ([actionClass respondsToSelector:makeSimple]) {
                action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                    actionClass, makeSimple, item[@"title"], icon, 0, handler);
            }
            if (action != nil && [sheet respondsToSelector:NSSelectorFromString(@"addAction:")]) {
                ((void (*)(id, SEL, id))objc_msgSend)(
                    sheet, NSSelectorFromString(@"addAction:"), action);
            }
        }
        YTzoomShowSheet(sheet, presenter);
        return;
    }
    [self showCompactNotice:YTzoomLocalized(@"YouTube menu unavailable")];
}

- (NSDictionary *)sheetAction:(NSString *)title
                          icon:(NSString *)icon
                     secondary:(UIImage *)secondary
                       handler:(dispatch_block_t)handler {
    NSMutableDictionary *item = [@{
        @"title": title,
        @"icon": [self menuIcon:icon] ?: [UIImage new],
        @"handler": [handler copy]
    } mutableCopy];
    if (secondary != nil) {
        item[@"secondary"] = secondary;
    }
    return item;
}

- (void)resolveSaveDestinationFromView:(UIView *)sourceView
                                  then:(dispatch_block_t)continuation {
    const NSInteger mode = [NSUserDefaults.standardUserDefaults
        integerForKey:YTzoomSaveLocationKey];
    YTzoomDownloadLog(@"save", @"destination mode=%ld", (long)mode);
    if (mode != 2) {
        self.pendingSavesToPhotos = mode == 1;
        self.pendingSharesFile = mode == 3;
        if (continuation != NULL) continuation();
        return;
    }
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"YTzoom Library") icon:@"arrow.down.circle"
            secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTzoomLocalized(@"Photos") icon:@"photo.on.rectangle"
            secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = YES;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTzoomLocalized(@"Share Sheet")
            icon:@"square.and.arrow.up" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = YES;
                if (continuation != NULL) continuation();
            }]
    ];
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (void)resolveAudioDestinationFromView:(UIView *)sourceView
                                   then:(dispatch_block_t)continuation {
    const NSInteger mode = [NSUserDefaults.standardUserDefaults
        integerForKey:YTzoomAudioSaveLocationKey];
    YTzoomDownloadLog(@"save", @"audio destination mode=%ld", (long)mode);
    if (mode != 2) {
        self.pendingSavesToPhotos = mode == 1;
        self.pendingSharesFile = mode == 3;
        if (continuation != NULL) continuation();
        return;
    }
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"YTzoom Library")
            icon:@"arrow.down.circle" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTzoomLocalized(@"Photos")
            icon:@"photo.on.rectangle" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = YES;
                weakSelf.pendingSharesFile = NO;
                if (continuation != NULL) continuation();
            }],
        [self sheetAction:YTzoomLocalized(@"Share Sheet")
            icon:@"square.and.arrow.up" secondary:nil handler:^{
                weakSelf.pendingSavesToPhotos = NO;
                weakSelf.pendingSharesFile = YES;
                if (continuation != NULL) continuation();
            }]
    ];
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (void)showDownloadMenu {
    [self showDownloadMenuFromButton:nil];
}

- (UIView *)sheetAnchorForView:(UIView *)source {
    UIViewController *top = [self topViewController];
    UIView *host = top.viewIfLoaded;
    if (host == nil || host.window == nil) return source;
    if (source != nil && source.window != nil &&
        [source isDescendantOfView:host]) {
        return source;
    }
    static UIView *anchor;
    if (anchor == nil) {
        anchor = [[UIView alloc] initWithFrame:CGRectZero];
        anchor.userInteractionEnabled = NO;
        anchor.backgroundColor = UIColor.clearColor;
        anchor.accessibilityIdentifier = @"YTzoom Sheet Anchor";
    }
    if (anchor.superview != host) {
        [anchor removeFromSuperview];
        [host addSubview:anchor];
    }
    CGRect frame;
    if (source != nil && source.window != nil) {
        frame = [source convertRect:source.bounds toView:host];
    } else {
        frame = CGRectMake(CGRectGetWidth(host.bounds) - 60.0,
                           CGRectGetHeight(host.bounds) * 0.5, 44.0, 44.0);
    }
    anchor.frame = frame;
    [host sendSubviewToBack:anchor];
    return anchor;
}

- (void)showDownloadMenuForResponse:(id)response sourceView:(UIView *)sourceView {
    sourceView = [self sheetAnchorForView:sourceView];
    self.externalResponse = response;
    self.externalSourceView = sourceView;
    [self showDownloadMenuFromButton:nil];
    self.externalResponse = nil;
    self.externalSourceView = nil;
}

- (void)showDownloadMenuFromButton:(UIButton *)button {
    if (!YTzoomDownloadsEnabled()) {
        return;
    }
    UIView *anchor = self.externalSourceView ?: button;
    id currentResponse = self.externalResponse
        ? self.externalResponse : [self videoPlayerResponseFromView:button];
    if (currentResponse != nil) {
        self.playerResponse = currentResponse;
    }
    if (self.playerResponse == nil) {
        [self showAlertWithTitle:@"YTzoom" message:YTzoomLocalized(@"No active video was found.")];
        return;
    }
    self.downloadSourceView = anchor;

    __weak YTzoomDownloadCoordinator *weakSelf = self;
    UIImage *chevron = [self menuIcon:@"chevron.right"];
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"Download Video") icon:@"play"
            secondary:chevron handler:^{
                [weakSelf resolveSaveDestinationFromView:anchor then:^{
                    [weakSelf startVideoDownloadForCategory:@"Video"];
                }];
            }],
        [self sheetAction:YTzoomLocalized(@"Download Audio") icon:@"music.note"
            secondary:chevron handler:^{
                [weakSelf resolveAudioDestinationFromView:anchor then:^{
                    [weakSelf startAudioDownload];
                }];
            }],
        [self sheetAction:YTzoomLocalized(@"Play in External Player") icon:@"play.circle"
            secondary:chevron handler:^{ [weakSelf showExternalPlayerMenuFromView:anchor]; }],
        [self sheetAction:YTzoomLocalized(@"Save Image") icon:@"photo"
            secondary:nil handler:^{ [weakSelf saveThumbnail]; }],
        [self sheetAction:YTzoomLocalized(@"Copy Information") icon:@"doc.on.doc"
            secondary:chevron handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf showCopyInformationMenuFromView:anchor];
                    });
            }]
    ];
    [self presentNativeSheetWithTitle:
        [YTzoomStreamResolver authorFromPlayerResponse:self.playerResponse]
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:anchor actions:actions];
}

- (void)showCompactNotice:(NSString *)message {
    YTzoomShowNotice(message);
}

- (void)showCopyInformationMenuFromView:(UIView *)sourceView {
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"Copy Title") icon:@"textformat"
            secondary:nil handler:^{
                UIPasteboard.generalPasteboard.string =
                    [YTzoomStreamResolver titleFromPlayerResponse:weakSelf.playerResponse];
                [weakSelf showCompactNotice:YTzoomLocalized(@"Title copied")];
            }],
        [self sheetAction:YTzoomLocalized(@"Copy Description") icon:@"line.3.horizontal"
            secondary:nil handler:^{
                NSString *description = [YTzoomStreamResolver
                    descriptionFromPlayerResponse:weakSelf.playerResponse];
                if (description.length == 0) {
                    [weakSelf showCompactNotice:YTzoomLocalized(@"No description found")];
                } else {
                    UIPasteboard.generalPasteboard.string = description;
                    [weakSelf showCompactNotice:YTzoomLocalized(@"Description copied")];
                }
            }]
    ];
    [self presentNativeSheetWithTitle:nil subtitle:nil
        sourceView:sourceView actions:actions];
}

- (void)showExternalPlayerMenuFromView:(UIView *)sourceView {
    YTzoomStreamOption *option =
        [YTzoomStreamResolver bestPiPVideoFromPlayerResponse:self.playerResponse];
    if (option.URL == nil) {
        [self showAlertWithTitle:YTzoomLocalized(@"External Player")
                         message:YTzoomLocalized(@"No playable stream is available.")];
        return;
    }
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSString *escaped = [option.URL.absoluteString
        stringByAddingPercentEncodingWithAllowedCharacters:
            NSCharacterSet.URLQueryAllowedCharacterSet];
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"System Player") icon:@"ytzoom.system"
            secondary:nil handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf playInSystemPlayer:option.URL sourceView:sourceView];
                    });
            }],
        [self sheetAction:YTzoomLocalized(@"Infuse") icon:@"ytzoom.infuse"
            secondary:nil handler:^{
                NSURL *url = [NSURL URLWithString:[NSString
                    stringWithFormat:@"infuse://x-callback-url/play?url=%@",
                    escaped ?: @""]];
                [UIApplication.sharedApplication openURL:url options:@{}
                    completionHandler:^(BOOL success) {
                        if (!success) {
                            [weakSelf showAlertWithTitle:YTzoomLocalized(@"Infuse")
                                message:YTzoomLocalized(@"Infuse is not installed.")];
                        }
                    }];
            }],
        [self sheetAction:YTzoomLocalized(@"VLC") icon:@"ytzoom.vlc"
            secondary:nil handler:^{
                NSURL *url = [NSURL URLWithString:[NSString
                    stringWithFormat:@"vlc-x-callback://x-callback-url/stream?url=%@",
                    escaped ?: @""]];
                [UIApplication.sharedApplication openURL:url options:@{}
                    completionHandler:^(BOOL success) {
                        if (!success) {
                            [weakSelf showAlertWithTitle:YTzoomLocalized(@"VLC")
                                message:YTzoomLocalized(@"VLC is not installed.")];
                        }
                    }];
            }]
    ];
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"External Player") subtitle:nil
        sourceView:sourceView actions:actions];
}

- (double)mediaTimeFromObject:(id)object {
    for (NSString *name in @[@"currentVideoMediaTime", @"currentVideoTime",
                              @"currentMediaTime", @"mediaTime"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod([object class], selector);
        if (method == NULL) {
            continue;
        }
        char type[16] = {};
        method_getReturnType(method, type, sizeof(type));
        if (strcmp(type, @encode(double)) == 0) {
            return ((double (*)(id, SEL))objc_msgSend)(object, selector);
        }
        if (strcmp(type, @encode(float)) == 0) {
            return ((float (*)(id, SEL))objc_msgSend)(object, selector);
        }
    }
    return 0.0;
}

- (void)playInSystemPlayer:(NSURL *)URL sourceView:(UIView *)sourceView {
    if (URL == nil) {
        return;
    }
    double mediaTime = 0.0;
    UIViewController *presenter = nil;
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 20; depth++) {
        if (mediaTime <= 0.0) {
            mediaTime = [self mediaTimeFromObject:current];
        }
        for (NSString *name in @[@"pauseVideo", @"pausePlayback", @"pause"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = class_getInstanceMethod([current class], selector);
            if (method != NULL && method_getNumberOfArguments(method) == 2) {
                ((void (*)(id, SEL))objc_msgSend)(current, selector);
                break;
            }
        }
        SEL eventsSelector = NSSelectorFromString(@"eventsDelegate");
        if ([current respondsToSelector:eventsSelector]) {
            id events = ((id (*)(id, SEL))objc_msgSend)(current, eventsSelector);
            if (mediaTime <= 0.0) {
                mediaTime = [self mediaTimeFromObject:events];
                SEL parentSelector = NSSelectorFromString(@"parentResponder");
                if ([events respondsToSelector:parentSelector]) {
                    id parent = ((id (*)(id, SEL))objc_msgSend)(events, parentSelector);
                    mediaTime = MAX(mediaTime, [self mediaTimeFromObject:parent]);
                }
            }
            if ([events isKindOfClass:UIViewController.class]) {
                presenter = events;
            }
        }
        if (presenter == nil && [current isKindOfClass:UIViewController.class]) {
            presenter = (UIViewController *)current;
        }
        current = current.nextResponder;
    }
    presenter = presenter ?: [self topViewController];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    if (![NSUserDefaults.standardUserDefaults
            boolForKey:@"YTzoom.Preference.Downloads.SubtitlesHidden"]) {
        NSString *key = @"availableMediaCharacteristicsWithMediaSelectionOptions";
        [asset loadValuesAsynchronouslyForKeys:@[key] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                AVMediaSelectionGroup *group = [asset
                    mediaSelectionGroupForMediaCharacteristic:
                        AVMediaCharacteristicLegible];
                if (group == nil) {
                    YTzoomDownloadLog(@"subs", @"default player no legible group");
                    return;
                }
                for (AVMediaSelectionOption *option in group.options) {
                    if (option.displayName.length == 0) continue;
                    if ([option hasMediaCharacteristic:
                            AVMediaCharacteristicContainsOnlyForcedSubtitles]) {
                        continue;
                    }
                    [item selectMediaOption:option inMediaSelectionGroup:group];
                    YTzoomDownloadLog(@"subs", @"default player selected %@",
                                      option.displayName);
                    return;
                }
                YTzoomDownloadLog(@"subs", @"default player %lu options, none used",
                                  (unsigned long)group.options.count);
            });
        }];
    }
    AVPlayer *player = [AVPlayer playerWithPlayerItem:item];
    AVPlayerViewController *controller = [AVPlayerViewController new];
    controller.player = player;
    controller.showsPlaybackControls = YES;
    controller.allowsPictureInPicturePlayback = YES;
    if (mediaTime > 0.0) {
        [player seekToTime:CMTimeMakeWithSeconds(mediaTime, NSEC_PER_SEC)
           toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
    }
    [presenter presentViewController:controller animated:YES completion:^{
        [player play];
    }];
}

- (void)saveThumbnail {
    NSURL *url = [YTzoomStreamResolver thumbnailURLFromPlayerResponse:self.playerResponse];
    if (url == nil) {
        [self showAlertWithTitle:YTzoomLocalized(@"Save Image") message:YTzoomLocalized(@"No thumbnail is available.")];
        return;
    }
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithURL:url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)response;
            UIImage *image = error == nil ? [UIImage imageWithData:data] : nil;
            if (image == nil) {
                [weakSelf showAlertWithTitle:YTzoomLocalized(@"Save Image")
                    message:error.localizedDescription ?: YTzoomLocalized(@"The image could not be loaded.")];
                return;
            }
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                [PHAssetChangeRequest creationRequestForAssetFromImage:image];
            } completionHandler:^(BOOL success, NSError *saveError) {
                if (success) {
                    [weakSelf showCompactNotice:YTzoomLocalized(@"Image saved")];
                } else {
                    [weakSelf showAlertWithTitle:YTzoomLocalized(@"Save Image")
                        message:saveError.localizedDescription ?:
                            YTzoomLocalized(@"The image could not be saved.")];
                }
            }];
        }];
    [task resume];
}

- (UIViewController *)shortsControllerFromView:(UIView *)sourceView {
    UIResponder *responder = sourceView.nextResponder;
    UIViewController *controller = nil;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            controller = (UIViewController *)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    Class shortsClass = NSClassFromString(@"YTShortsPlayerViewController");
    while (controller != nil) {
        if (shortsClass != Nil && [controller isKindOfClass:shortsClass]) {
            return controller;
        }
        controller = controller.parentViewController;
    }
    return nil;
}

- (void)toggleShortsFullscreenFromView:(UIView *)sourceView {
    UIViewController *controller = [self shortsControllerFromView:sourceView];
    if (controller == nil) {
        UIView *container = YTzoomShortsContainerForView(sourceView, sourceView.window);
        if (container == nil) return;
        YTzoomSetShortsNewFullscreen(container, !YTzoomShortsGlobalFullscreen);
        return;
    }
    if (controller != nil) {
            BOOL fullscreen = [objc_getAssociatedObject(
                controller, YTzoomShortsFullscreenKey) boolValue];
            id pivotController = controller.navigationController.parentViewController;
            SEL pivotSelector = NSSelectorFromString(
                fullscreen ? @"showPivotBar" : @"hidePivotBar");
            if ([pivotController respondsToSelector:pivotSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(pivotController, pivotSelector);
            }
            id shortsView = controller.view;
            SEL overlaySelector = NSSelectorFromString(@"playbackOverlay");
            id overlay = [shortsView respondsToSelector:overlaySelector]
                ? ((id (*)(id, SEL))objc_msgSend)(shortsView, overlaySelector) : nil;
            UIView *container = [overlay isKindOfClass:UIView.class]
                ? nil : YTzoomShortsContainerForView(sourceView, controller.view);
            [UIView animateWithDuration:0.3 animations:^{
                if ([overlay isKindOfClass:UIView.class]) {
                    YTzoomSetShortsOverlayFullscreen(
                        (UIView *)overlay, !fullscreen);
                } else if (container != nil) {
                    YTzoomSetShortsElementsFullscreen(container, !fullscreen);
                }
            }];
            objc_setAssociatedObject(controller, YTzoomShortsFullscreenKey, @(!fullscreen),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            for (NSNumber *delay in @[@0.05, @0.20]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                    dispatch_get_main_queue(), ^{
                        [controller.view setNeedsLayout];
                        [controller.view layoutIfNeeded];
                    });
            }
            return;
    }
}

- (void)presentShortsDownloadMenuFromView:(UIView *)sourceView
                                  response:(id)response {
    if (!YTzoomDownloadsEnabled() || response == nil) {
        [self showAlertWithTitle:@"YTzoom" message:YTzoomLocalized(@"No active Short was found.")];
        return;
    }
    self.playerResponse = response;
    self.downloadSourceView = sourceView;
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    UIImage *chevron = [self menuIcon:@"chevron.right"];
    BOOL autoSkip = YTzoomFeatureEnabled(@"autoSkipShorts");
    UIViewController *shortsController = [self shortsControllerFromView:sourceView];
    BOOL fullscreen = shortsController != nil
        ? [objc_getAssociatedObject(shortsController, YTzoomShortsFullscreenKey) boolValue]
        : YTzoomShortsGlobalFullscreen;
    NSString *fullscreenTitle = fullscreen ? YTzoomLocalized(@"Exit Fullscreen") : YTzoomLocalized(@"Fullscreen");
    NSString *fullscreenIcon = fullscreen
        ? @"arrow.down.right.and.arrow.up.left"
        : @"arrow.up.left.and.arrow.down.right";
    NSArray *actions = @[
        [self sheetAction:YTzoomLocalized(@"Download Video") icon:@"play"
            secondary:chevron handler:^{
                [weakSelf resolveSaveDestinationFromView:sourceView then:^{
                    [weakSelf startVideoDownloadForCategory:@"Shorts"];
                }];
            }],
        [self sheetAction:YTzoomLocalized(@"Download Audio") icon:@"music.note"
            secondary:chevron handler:^{
                [weakSelf resolveAudioDestinationFromView:sourceView then:^{
                    [weakSelf startAudioDownload];
                }];
            }],
        [self sheetAction:fullscreenTitle icon:fullscreenIcon
            secondary:chevron handler:^{
                [weakSelf toggleShortsFullscreenFromView:sourceView];
            }],
        [self sheetAction:YTzoomLocalized(@"Auto-Skip") icon:@"forward.end.fill"
            secondary:[self menuIcon:autoSkip ? @"checkmark.square" : @"square"]
            handler:^{ YTzoomSetPreference(@"autoSkipShorts", !autoSkip); }]
    ];
    [self presentNativeSheetWithTitle:
        [YTzoomStreamResolver authorFromPlayerResponse:self.playerResponse]
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:sourceView actions:actions];
}

- (NSString *)activeReelVideoIDFromView:(UIView *)sourceView {
    SEL activeSelector = NSSelectorFromString(@"activeReelPlaybackVideoID");
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 16; depth++) {
        if ([current respondsToSelector:activeSelector]) {
            id value = ((id (*)(id, SEL))objc_msgSend)(current, activeSelector);
            if ([value isKindOfClass:NSString.class] && [value length] != 0) {
                return value;
            }
        }
        current = current.nextResponder;
    }
    return nil;
}

- (id)reelModelFromView:(UIView *)sourceView {
    SEL contentModel = NSSelectorFromString(@"contentModel");
    UIResponder *current = sourceView;
    for (NSUInteger depth = 0; current != nil && depth < 14; depth++) {
        if ([current respondsToSelector:contentModel]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(current, contentModel);
            if (model != nil) return model;
        }
        current = current.nextResponder;
    }
    return nil;
}

- (void)showShortsDownloadMenuFromView:(UIView *)sourceView {
    id currentResponse = [self tracedPlayerResponseFromView:sourceView];
    if (currentResponse != nil) {
        [self presentShortsDownloadMenuFromView:sourceView
                                       response:currentResponse];
        return;
    }

    id reel = [self reelModelFromView:sourceView];
    NSString *reelID = nil;
    SEL videoSelector = NSSelectorFromString(@"videoId");
    if ([reel respondsToSelector:videoSelector]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(reel, videoSelector);
        if ([value isKindOfClass:NSString.class]) reelID = value;
    }
    NSString *activeID = [self activeReelVideoIDFromView:sourceView];
    NSString *videoID = activeID.length != 0 ? activeID : reelID;

    id cached = YTzoomCachedPlayerResponse(videoID);
    if (cached != nil) {
        [self presentShortsDownloadMenuFromView:sourceView response:cached];
        return;
    }

    SEL overrideSelector = NSSelectorFromString(@"playerResponseOverride");
    BOOL reelIsCurrent = reelID.length != 0 &&
        (activeID.length == 0 || [reelID isEqualToString:activeID]);
    if (reelIsCurrent && [reel respondsToSelector:overrideSelector]) {
        id override = ((id (*)(id, SEL))objc_msgSend)(reel, overrideSelector);
        if (override != nil) {
            [self presentShortsDownloadMenuFromView:sourceView response:override];
            return;
        }
    }
    if (videoID.length == 0) {
        [self presentShortsDownloadMenuFromView:sourceView response:nil];
        return;
    }

    __weak YTzoomDownloadCoordinator *weakSelf = self;
    __weak UIView *weakSource = sourceView;
    YTzoomPreparePlayerWithRoute(videoID, NO, ^(id playerResponse,
                                                __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomDownloadCoordinator *strongSelf = weakSelf;
            UIView *strongSource = weakSource;
            if (strongSelf == nil || strongSource == nil) return;
            NSString *resolvedID = [YTzoomStreamResolver
                videoIDFromPlayerResponse:playerResponse];
            BOOL matched = playerResponse != nil &&
                (resolvedID.length == 0 ||
                 [resolvedID isEqualToString:videoID]);
            if (matched) {
                YTzoomStorePlayerResponse(videoID, playerResponse);
                [strongSelf presentShortsDownloadMenuFromView:strongSource
                    response:playerResponse];
                return;
            }
            YTzoomPreparePlayerWithRoute(videoID, YES, ^(id retryResponse,
                                                        __unused NSError *retryError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    YTzoomDownloadCoordinator *retrySelf = weakSelf;
                    UIView *retrySource = weakSource;
                    if (retrySelf == nil || retrySource == nil) return;
                    NSString *retryID = [YTzoomStreamResolver
                        videoIDFromPlayerResponse:retryResponse];
                    BOOL retryMatched = retryResponse != nil &&
                        (retryID.length == 0 ||
                         [retryID isEqualToString:videoID]);
                    if (retryMatched) {
                        YTzoomStorePlayerResponse(videoID, retryResponse);
                    }
                    [retrySelf presentShortsDownloadMenuFromView:retrySource
                        response:retryMatched ? retryResponse : nil];
                });
            });
        });
    });
}

- (BOOL)loadDirectOptionsThen:(dispatch_block_t)continuation {
    if (!YTzoomDirectDownloadsEnabled()) {
        self.directOptions = nil;
        return NO;
    }
    NSString *videoID = [YTzoomStreamResolver videoIDFromPlayerResponse:self.playerResponse];
    if (videoID.length != 0 && [videoID isEqualToString:self.directOptionsVideoID]) return NO;
    self.directOptionsVideoID = videoID;
    self.directOptions = nil;
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    [YTzoomDirectDownloader fetchOptionsForVideoID:videoID completion:^(NSArray *options) {
        weakSelf.directOptions = options;
        continuation();
    }];
    return YES;
}

- (BOOL)isStableVolumeOption:(YTzoomStreamOption *)option {
    if (option.xtags.length == 0) return NO;
    NSString *padded = [option.xtags stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
    padded = [padded stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (padded.length % 4 != 0) padded = [padded stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:padded options:0];
    NSString *text = data == nil ? nil :
        [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
    return [text containsString:@"drc"];
}

- (NSString *)sizeTextForOption:(YTzoomStreamOption *)option {
    return option.contentLength > 0
        ? [NSByteCountFormatter stringFromByteCount:option.contentLength
            countStyle:NSByteCountFormatterCountStyleFile] : YTzoomLocalized(@"Unknown size");
}

- (void)presentDirectVideoMenuForCategory:(NSString *)category {
    NSArray<NSString *> *codecOrder = @[@"H.264", @"VP9", @"AV1"];
    NSMutableArray<YTzoomStreamOption *> *videos = [NSMutableArray array];
    BOOL vp9 = VTIsHardwareDecodeSupported('vp09');
    BOOL av1 = VTIsHardwareDecodeSupported('av01');
    for (YTzoomStreamOption *option in self.directOptions) {
        if (option.audioOnly || option.height <= 0) continue;
        NSString *codec = [YTzoomDirectDownloader codecNameForOption:option];
        if ([codec isEqualToString:@"VP9"] && !vp9) continue;
        if ([codec isEqualToString:@"AV1"] && !av1) continue;
        [videos addObject:option];
    }
    [videos sortUsingComparator:^NSComparisonResult(YTzoomStreamOption *left,
                                                    YTzoomStreamOption *right) {
        if (left.height != right.height) {
            return left.height > right.height ? NSOrderedAscending : NSOrderedDescending;
        }
        BOOL leftHigh = [left.qualityLabel hasSuffix:@"60"];
        BOOL rightHigh = [right.qualityLabel hasSuffix:@"60"];
        if (leftHigh != rightHigh) return leftHigh ? NSOrderedAscending : NSOrderedDescending;
        NSUInteger leftCodec = [codecOrder indexOfObject:[YTzoomDirectDownloader codecNameForOption:left]];
        NSUInteger rightCodec = [codecOrder indexOfObject:[YTzoomDirectDownloader codecNameForOption:right]];
        return leftCodec < rightCodec ? NSOrderedAscending :
            (leftCodec > rightCodec ? NSOrderedDescending : NSOrderedSame);
    }];
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTzoomStreamOption *option in videos) {
        NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
            option.qualityLabel.length != 0 ? option.qualityLabel
                : [NSString stringWithFormat:@"%ldp", (long)option.height],
            [YTzoomDirectDownloader codecNameForOption:option], [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"play" secondary:nil handler:^{
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                dispatch_get_main_queue(), ^{
                    [weakSelf showAudioLanguagesForVideo:option audioOnly:NO category:category];
                });
        }]];
    }
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Video Quality")
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)presentDirectAudioMenuForVideo:(YTzoomStreamOption *)videoOption
                             audioOnly:(BOOL)audioOnly
                              category:(NSString *)category {
    NSMutableArray<YTzoomStreamOption *> *audios = [NSMutableArray array];
    for (YTzoomStreamOption *option in self.directOptions) {
        if (option.audioOnly) [audios addObject:option];
    }
    [audios sortUsingComparator:^NSComparisonResult(YTzoomStreamOption *left,
                                                    YTzoomStreamOption *right) {
        if (left.isDefaultAudio != right.isDefaultAudio) {
            return left.isDefaultAudio ? NSOrderedAscending : NSOrderedDescending;
        }
        NSComparisonResult language = [left.languageLabel compare:right.languageLabel];
        if (language != NSOrderedSame) return language;
        BOOL leftStable = [self isStableVolumeOption:left];
        BOOL rightStable = [self isStableVolumeOption:right];
        if (leftStable != rightStable) return leftStable ? NSOrderedDescending : NSOrderedAscending;
        return left.bitrate > right.bitrate ? NSOrderedAscending : NSOrderedDescending;
    }];
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTzoomStreamOption *option in audios) {
        NSString *stable = [self isStableVolumeOption:option]
            ? [@" · " stringByAppendingString:YTzoomLocalized(@"Stable volume")] : @"";
        NSString *title = [NSString stringWithFormat:@"%@ · %@ %ld kbps%@ · %@",
            option.languageLabel, [YTzoomDirectDownloader codecNameForOption:option],
            (long)(option.bitrate / 1000), stable, [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"music.note" secondary:nil handler:^{
            [weakSelf beginSABRDownloadVideo:videoOption audio:option
                                   audioOnly:audioOnly category:category];
        }]];
    }
    NSMutableSet<NSString *> *directLanguages = [NSMutableSet set];
    for (YTzoomStreamOption *option in audios) {
        [directLanguages addObject:option.languageLabel.lowercaseString ?: @""];
    }
    for (YTzoomStreamOption *option in
         [YTzoomStreamResolver audioOptionsFromPlayerResponse:self.playerResponse]) {
        NSString *language = option.languageLabel.lowercaseString ?: @"";
        BOOL covered = NO;
        for (NSString *direct in directLanguages) {
            if ([direct isEqualToString:language] ||
                (direct.length != 0 && language.length != 0 &&
                 ([direct hasPrefix:language] || [language hasPrefix:direct]))) {
                covered = YES;
                break;
            }
        }
        if (covered) continue;
        NSString *title = [NSString stringWithFormat:@"%@ · %@ · %@",
            option.languageLabel, YTzoomLocalized(@"via SABR"), [self sizeTextForOption:option]];
        [actions addObject:[self sheetAction:title icon:@"music.note" secondary:nil handler:^{
            weakSelf.forceSABRNext = YES;
            [weakSelf beginSABRDownloadVideo:videoOption audio:option
                                   audioOnly:audioOnly category:category];
        }]];
    }
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Audio Language")
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)startVideoDownloadForCategory:(NSString *)category {
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    if ([self loadDirectOptionsThen:^{ [weakSelf startVideoDownloadForCategory:category]; }]) {
        return;
    }
    if (self.directOptions.count != 0) {
        [self presentDirectVideoMenuForCategory:category];
        return;
    }
    NSArray<YTzoomStreamOption *> *options =
        [YTzoomStreamResolver videoOptionsFromPlayerResponse:self.playerResponse];
    YTzoomDownloadLog(@"resolver", @"video menu count=%lu category=%@",
        (unsigned long)options.count, category);
    if (options.count == 0) {
        [self showAlertWithTitle:YTzoomLocalized(@"Download unavailable")
                         message:YTzoomLocalized(@"No compatible video formats were found.")];
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    for (YTzoomStreamOption *option in options) {
        NSString *size = option.contentLength > 0
            ? [NSByteCountFormatter stringFromByteCount:option.contentLength
                countStyle:NSByteCountFormatterCountStyleFile] : YTzoomLocalized(@"Unknown size");
        NSString *title = [NSString stringWithFormat:@"%@ (mp4) · %@",
            option.qualityLabel.length != 0 ? option.qualityLabel : YTzoomLocalized(@"Video"), size];
        [actions addObject:[self sheetAction:title icon:@"play"
            secondary:nil handler:^{
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        [weakSelf showAudioLanguagesForVideo:option audioOnly:NO
                            category:category];
                    });
            }]];
    }
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Video Quality")
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)startAudioDownload {
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    if ([self loadDirectOptionsThen:^{ [weakSelf startAudioDownload]; }]) return;
    [self showAudioLanguagesForVideo:nil audioOnly:YES category:@"Audio"];
}

- (void)showAudioLanguagesForVideo:(YTzoomStreamOption *)videoOption
                         audioOnly:(BOOL)audioOnly
                          category:(NSString *)category {
    if (self.directOptions.count != 0) {
        [self presentDirectAudioMenuForVideo:videoOption audioOnly:audioOnly category:category];
        return;
    }
    NSArray<YTzoomStreamOption *> *options =
        [YTzoomStreamResolver audioOptionsFromPlayerResponse:self.playerResponse];
    if (options.count == 0) {
        [self showAlertWithTitle:YTzoomLocalized(@"Download unavailable")
                         message:YTzoomLocalized(@"No compatible audio formats were found.")];
        return;
    }
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    NSMutableArray *actions = [NSMutableArray array];
    for (YTzoomStreamOption *option in options) {
        NSString *size = option.contentLength > 0
            ? [NSByteCountFormatter stringFromByteCount:option.contentLength
                countStyle:NSByteCountFormatterCountStyleFile] : YTzoomLocalized(@"Unknown size");
        NSString *defaultText = option.isDefaultAudio ? YTzoomLocalized(@" (Default)") : @"";
        NSString *title = [NSString stringWithFormat:@"%@%@ · %@",
            option.languageLabel, defaultText, size];
        [actions addObject:[self sheetAction:title icon:@"music.note"
            secondary:nil handler:^{
                [weakSelf beginSABRDownloadVideo:videoOption
                    audio:option audioOnly:audioOnly category:category];
            }]];
    }
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Audio Language")
        subtitle:[YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]
        sourceView:self.downloadSourceView actions:actions];
}

- (void)beginSABRDownloadVideo:(YTzoomStreamOption *)videoOption
                         audio:(YTzoomStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                      category:(NSString *)category {
    if (videoOption == nil) {
        videoOption = [YTzoomStreamResolver
            videoOptionsFromPlayerResponse:self.playerResponse].firstObject;
    }
    if (videoOption == nil || audioOption == nil) {
        [self showAlertWithTitle:YTzoomLocalized(@"Download unavailable")
                         message:YTzoomLocalized(@"The selected formats are unavailable.")];
        return;
    }
    id response = self.playerResponse;
    YTzoomDownloadJob *job = [YTzoomDownloadJob new];
    job.identifier = NSUUID.UUID.UUIDString;
    job.title = [self safeFilename:
        [YTzoomStreamResolver titleFromPlayerResponse:response]];
    job.author = [YTzoomStreamResolver authorFromPlayerResponse:response];
    job.videoID = [YTzoomStreamResolver videoIDFromPlayerResponse:response] ?: @"";
    job.thumbnailURL = [YTzoomStreamResolver thumbnailURLFromPlayerResponse:response];
    job.category = audioOnly ? @"Audio" : category;
    job.playerResponse = response;
    job.videoOption = videoOption;
    job.audioOption = audioOption;
    job.audioOnly = audioOnly;
    job.savesToPhotos = self.pendingSavesToPhotos;
    job.sharesFile = self.pendingSharesFile;
    job.useDirect = YTzoomDirectDownloadsEnabled() && !self.forceSABRNext;
    self.forceSABRNext = NO;
    if (!job.useDirect && self.directOptions.count != 0 &&
        ![self prepareSABRFallbackForJob:job]) {
        [self showAlertWithTitle:YTzoomLocalized(@"Download unavailable")
                         message:YTzoomLocalized(@"The selected formats are unavailable.")];
        return;
    }
    YTzoomDownloadLog(job.identifier, @"destination photos=%d share=%d",
        job.savesToPhotos, job.sharesFile);
    [self chooseCaptionsForJob:job then:^{
        [self launchJob:job];
    }];
}

- (void)launchJob:(YTzoomDownloadJob *)job {
    {
        if (self.retryableJobs == nil) self.retryableJobs = [NSMutableDictionary dictionary];
        if (self.retryableJobs.count >= 24) [self.retryableJobs removeAllObjects];
        self.retryableJobs[job.identifier] = job;
        self.activeJobs[job.identifier] = job;
        [YTzoomDownloadProgressView.sharedView beginJob:job.identifier
            title:job.title thumbnailURL:job.thumbnailURL];
        YTzoomDownloadLog(job.identifier,
            @"queued title=%@ author=%@ category=%@ audioOnly=%d active=%lu",
            job.title, job.author, job.category, job.audioOnly,
            (unsigned long)self.activeJobs.count);
        [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTzoomLocalized(@"Preparing download") progress:0.0 downloadedBytes:0 totalBytes:0];
        if (job.useDirect) {
            [self startDirectJob:job];
        } else {
            [self startSABRJob:job];
        }
    }
}

- (void)retryJobWithIdentifier:(NSString *)identifier {
    YTzoomDownloadJob *old = self.retryableJobs[identifier];
    if (old == nil) {
        YTzoomShowNotice(YTzoomLocalized(@"Download unavailable"));
        return;
    }
    [self.retryableJobs removeObjectForKey:identifier];
    YTzoomDownloadJob *job = [YTzoomDownloadJob new];
    job.identifier = NSUUID.UUID.UUIDString;
    job.title = old.title;
    job.author = old.author;
    job.videoID = old.videoID;
    job.thumbnailURL = old.thumbnailURL;
    job.category = old.category;
    job.playerResponse = old.playerResponse;
    job.videoOption = old.videoOption;
    job.audioOption = old.audioOption;
    job.audioOnly = old.audioOnly;
    job.savesToPhotos = old.savesToPhotos;
    job.sharesFile = old.sharesFile;
    job.useDirect = old.useDirect;
    job.captionURL = old.captionURL;
    job.captionLanguage = old.captionLanguage;
    YTzoomDownloadLog(job.identifier, @"retry of %@", identifier);
    [self launchJob:job];
}

- (void)chooseCaptionsForJob:(YTzoomDownloadJob *)job
                        then:(dispatch_block_t)handler {
    if (job.audioOnly ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Downloads.Subtitles")) {
        handler();
        return;
    }
    NSArray<NSDictionary *> *choices =
        YTzoomCaptionChoicesForResponse(job.playerResponse);
    if (choices.count == 0) {
        YTzoomDownloadLog(@"subs", @"no caption tracks for %@", job.videoID);
        handler();
        return;
    }
    if (choices.count == 1) {
        job.captionURL = choices.firstObject[@"url"];
        job.captionLanguage = choices.firstObject[@"language"];
        handler();
        return;
    }
    NSMutableArray<NSDictionary *> *actions = [NSMutableArray array];
    for (NSDictionary *choice in choices) {
        [actions addObject:@{
            @"title": choice[@"label"],
            @"handler": ^{
                job.captionURL = choice[@"url"];
                job.captionLanguage = choice[@"language"];
                handler();
            }
        }];
    }
    [actions addObject:@{
        @"title": YTzoomLocalized(@"No Subtitles"),
        @"handler": ^{ handler(); }
    }];
    UIView *anchor = self.downloadSourceView ?: self.externalSourceView;
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Subtitles")
                             subtitle:YTzoomLocalized(@"Choose a caption track")
                           sourceView:[self sheetAnchorForView:anchor]
                              actions:actions];
}

- (NSDictionary *)nativeSheetAction:(NSString *)title
                               icon:(NSString *)icon
                            handler:(dispatch_block_t)handler {
    return [self sheetAction:title icon:icon secondary:nil handler:handler];
}

- (void)presentPlaylistSheetWithTitle:(NSString *)title
                             subtitle:(NSString *)subtitle
                           sourceView:(UIView *)sourceView
                              actions:(NSArray<NSDictionary *> *)actions {
    [self presentNativeSheetWithTitle:title subtitle:subtitle
                           sourceView:sourceView actions:actions];
}

- (NSUInteger)activeJobCount {
    return self.activeJobs.count;
}

- (void)resolvePlaylistDestinationFromView:(UIView *)sourceView
                                 audioOnly:(BOOL)audioOnly
                                      then:(void (^)(BOOL, BOOL))handler {
    NSString *key = audioOnly ? YTzoomAudioSaveLocationKey
                              : YTzoomSaveLocationKey;
    const NSInteger mode =
        [NSUserDefaults.standardUserDefaults integerForKey:key];
    YTzoomDownloadLog(@"save", @"playlist destination mode=%ld audio=%d",
        (long)mode, audioOnly);
    if (mode != 2) {
        handler(mode == 1, mode == 3);
        return;
    }
    NSMutableArray *actions = [NSMutableArray array];
    [actions addObject:[self sheetAction:YTzoomLocalized(@"YTzoom Library")
        icon:@"arrow.down.circle" secondary:nil
        handler:^{ handler(NO, NO); }]];
    [actions addObject:[self sheetAction:YTzoomLocalized(@"Photos")
        icon:@"photo.on.rectangle" secondary:nil
        handler:^{ handler(YES, NO); }]];
    [actions addObject:[self sheetAction:YTzoomLocalized(@"Share Sheet")
        icon:@"square.and.arrow.up" secondary:nil
        handler:^{ handler(NO, YES); }]];
    [self presentNativeSheetWithTitle:YTzoomLocalized(@"Save to")
        subtitle:nil sourceView:sourceView actions:actions];
}

- (BOOL)enqueueDownloadForResponse:(id)response
                           quality:(NSInteger)quality
                         audioOnly:(BOOL)audioOnly
                     savesToPhotos:(BOOL)savesToPhotos
                        sharesFile:(BOOL)sharesFile {
    if (response == nil) return NO;
    YTzoomStreamOption *audio =
        [YTzoomStreamResolver audioOptionsFromPlayerResponse:response].firstObject;
    if (audio == nil) return NO;
    YTzoomStreamOption *video = nil;
    if (!audioOnly) {
        NSArray<YTzoomStreamOption *> *options =
            [YTzoomStreamResolver videoOptionsFromPlayerResponse:response];
        if (options.count == 0) return NO;
        if (quality > 0) {
            for (YTzoomStreamOption *option in options) {
                if (option.height <= quality) {
                    video = option;
                    break;
                }
            }
        }
        if (video == nil) video = options.firstObject;
    }
    id previousResponse = self.playerResponse;
    BOOL previousPhotos = self.pendingSavesToPhotos;
    BOOL previousShare = self.pendingSharesFile;
    self.playerResponse = response;
    self.pendingSavesToPhotos = savesToPhotos;
    self.pendingSharesFile = sharesFile;
    [self beginSABRDownloadVideo:video audio:audio audioOnly:audioOnly
                        category:audioOnly ? @"Audio" : @"Video"];
    self.playerResponse = previousResponse;
    self.pendingSavesToPhotos = previousPhotos;
    self.pendingSharesFile = previousShare;
    return YES;
}

- (YTzoomStreamOption *)fallbackVideoForJob:(YTzoomDownloadJob *)job {
    if (job.fallbackCount >= 3) return nil;
    NSArray<YTzoomStreamOption *> *options =
        [YTzoomStreamResolver videoOptionsFromPlayerResponse:job.playerResponse];
    NSInteger currentIndex = NSNotFound;
    for (NSUInteger index = 0; index < options.count; index++) {
        YTzoomStreamOption *option = options[index];
        if (option.itag == job.videoOption.itag &&
            [option.xtags isEqualToString:job.videoOption.xtags]) {
            currentIndex = (NSInteger)index;
            break;
        }
    }
    if (currentIndex == NSNotFound) return nil;
    for (NSUInteger index = (NSUInteger)currentIndex + 1; index < options.count; index++) {
        YTzoomStreamOption *option = options[index];
        if (option.itag != job.videoOption.itag) return option;
    }
    return nil;
}

- (void)reportProgressForJob:(YTzoomDownloadJob *)job
               audioProgress:(double)audioProgress
               videoProgress:(double)videoProgress
                  audioBytes:(int64_t)audioBytes
                  videoBytes:(int64_t)videoBytes
                       phase:(NSInteger)mediaPhase {
    job.audioBytes = audioBytes;
    job.videoBytes = videoBytes;
    int64_t audioTotal = MAX((int64_t)job.audioOption.contentLength, 0);
    int64_t videoTotal = job.audioOnly ? 0 :
        MAX((int64_t)job.videoOption.contentLength, 0);
    int64_t downloaded = audioBytes + (job.audioOnly ? 0 : videoBytes);
    int64_t total = audioTotal + videoTotal;
    double transferProgress = 0.0;
    if (total > 0) {
        transferProgress = (double)downloaded / (double)total;
    } else if (job.audioOnly) {
        transferProgress = audioProgress;
    } else {
        transferProgress = audioProgress * 0.08 + videoProgress * 0.92;
    }
    transferProgress = MIN(MAX(transferProgress, 0.0), 1.0);
    NSString *stage = job.audioOnly || mediaPhase == 1
        ? YTzoomLocalized(@"Downloading audio") : YTzoomLocalized(@"Downloading video");
    [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
        stage:stage progress:transferProgress * 0.95
        downloadedBytes:downloaded totalBytes:total];
}

- (void)completeJob:(YTzoomDownloadJob *)job
           videoURL:(NSURL *)videoURL
           audioURL:(NSURL *)audioURL {
    if (job.audioOnly) {
        if (videoURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:videoURL error:nil];
        }
        [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTzoomLocalized(@"Finalizing") progress:0.96
            downloadedBytes:job.audioBytes totalBytes:job.audioBytes];
        NSURL *output = [audioURL.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:@"final.m4a"];
        YTzoomDownloadLog(job.identifier, @"audio remux start");
        [YTzoomFFmpegMuxer remuxAudioURL:audioURL outputURL:output
            completion:^(NSError *remuxError) {
                if (remuxError != nil) {
                    [YTzoomDownloadProgressView.sharedView
                        finishJob:job.identifier success:NO message:YTzoomLocalized(@"Failed")];
                    YTzoomDownloadLog(job.identifier,
                        @"audio remux failed error=%@",
                        remuxError.localizedDescription);
                    [NSFileManager.defaultManager
                        removeItemAtURL:audioURL.URLByDeletingLastPathComponent
                        error:nil];
                    [self showAlertWithTitle:YTzoomLocalized(@"Download failed")
                        message:[self failureMessageForError:remuxError
                            job:job]];
                    [self.activeJobs removeObjectForKey:job.identifier];
                    return;
                }
                [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
                YTzoomDownloadLog(job.identifier, @"audio remux complete");
                [self saveCompletedURL:output job:job extension:@"m4a"];
            }];
        return;
    }
    [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
        stage:YTzoomLocalized(@"Merging") progress:0.96
        downloadedBytes:job.audioBytes + job.videoBytes
        totalBytes:job.audioBytes + job.videoBytes];
    [self mergeVideoURL:videoURL audioURL:audioURL job:job];
}

- (BOOL)prepareSABRFallbackForJob:(YTzoomDownloadJob *)job {
    NSArray<YTzoomStreamOption *> *audios =
        [YTzoomStreamResolver audioOptionsFromPlayerResponse:job.playerResponse];
    YTzoomStreamOption *audio = nil;
    for (YTzoomStreamOption *option in audios) {
        if ([option.languageLabel isEqualToString:job.audioOption.languageLabel]) {
            audio = option;
            break;
        }
    }
    audio = audio ?: audios.firstObject;
    if (audio == nil) return NO;
    YTzoomStreamOption *video = nil;
    if (!job.audioOnly) {
        NSArray<YTzoomStreamOption *> *videos =
            [YTzoomStreamResolver videoOptionsFromPlayerResponse:job.playerResponse];
        for (YTzoomStreamOption *option in videos) {
            if (option.height <= job.videoOption.height) {
                video = option;
                break;
            }
        }
        video = video ?: videos.lastObject;
        if (video == nil) return NO;
    }
    job.audioOption = audio;
    job.videoOption = video ?: job.videoOption;
    return YES;
}

- (void)startDirectJob:(YTzoomDownloadJob *)job {
    if (job.cancelled) return;
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    job.directTask = [YTzoomDirectDownloader downloadVideoID:job.videoID
        videoOption:job.audioOnly ? nil : job.videoOption audioOption:job.audioOption
        audioOnly:job.audioOnly identifier:job.identifier
        progress:^(double audioProgress, double videoProgress,
                   int64_t audioBytes, int64_t videoBytes, NSInteger mediaPhase) {
            [weakSelf reportProgressForJob:job audioProgress:audioProgress
                videoProgress:videoProgress audioBytes:audioBytes
                videoBytes:videoBytes phase:mediaPhase];
        }
        completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
            job.directTask = nil;
            YTzoomDownloadCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (error == nil && audioURL != nil && (job.audioOnly || videoURL != nil)) {
                [strongSelf completeJob:job videoURL:videoURL audioURL:audioURL];
                return;
            }
            if ([error.domain isEqualToString:NSURLErrorDomain] &&
                error.code == NSURLErrorCancelled) {
                [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTzoomLocalized(@"Cancelled")];
                [strongSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            YTzoomDownloadLog(job.identifier, @"direct failed error=%@ fallback=sabr",
                error.localizedDescription ?: @"incomplete");
            if (![strongSelf prepareSABRFallbackForJob:job]) {
                [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTzoomLocalized(@"Failed")];
                [strongSelf showAlertWithTitle:YTzoomLocalized(@"Download failed")
                    message:[strongSelf failureMessageForError:error job:job]];
                [strongSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            job.useDirect = NO;
            [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
                stage:YTzoomLocalized(@"Preparing download") progress:0.0
                downloadedBytes:0 totalBytes:0];
            [strongSelf startSABRJob:job];
        }];
}

- (void)startSABRJob:(YTzoomDownloadJob *)job {
    if (job.cancelled) return;
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    job.sabrTask = [YTzoomSABRDownloader downloadPlayerResponse:job.playerResponse
        videoOption:job.videoOption audioOption:job.audioOption audioOnly:job.audioOnly
        videoID:job.videoID identifier:job.identifier
        progress:^(double audioProgress, double videoProgress,
                   int64_t audioBytes, int64_t videoBytes,
                   NSInteger mediaPhase) {
            [weakSelf reportProgressForJob:job audioProgress:audioProgress
                videoProgress:videoProgress audioBytes:audioBytes
                videoBytes:videoBytes phase:mediaPhase];
        }
        completion:^(NSURL *videoURL, NSURL *audioURL, NSError *error) {
            if (error != nil || audioURL == nil || (!job.audioOnly && videoURL == nil)) {
                YTzoomStreamOption *fallback = nil;
                if ([error.domain isEqualToString:@"YTzoomSABR"] &&
                    error.code == 8) {
                    fallback = [weakSelf fallbackVideoForJob:job];
                }
                if (fallback != nil) {
                    NSInteger previous = job.videoOption.itag;
                    job.videoOption = fallback;
                    job.fallbackCount += 1;
                    YTzoomDownloadLog(job.identifier,
                        @"fallback video itag=%ld to=%ld attempt=%ld",
                        (long)previous, (long)fallback.itag,
                        (long)job.fallbackCount);
                    [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
                        stage:YTzoomLocalized(@"Retrying lower quality") progress:0.0
                        downloadedBytes:0 totalBytes:job.audioOption.contentLength +
                            (job.audioOnly ? 0 : job.videoOption.contentLength)];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                        (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [weakSelf startSABRJob:job];
                        });
                    return;
                }
                NSString *message = error.code == NSURLErrorCancelled
                    ? YTzoomLocalized(@"Cancelled") : YTzoomLocalized(@"Failed");
                [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:message];
                YTzoomDownloadLog(job.identifier, @"job failed error=%@",
                    error.localizedDescription ?: @"incomplete stream");
                if (error.code != NSURLErrorCancelled) {
                    [weakSelf showAlertWithTitle:YTzoomLocalized(@"Download failed")
                        message:[weakSelf failureMessageForError:error job:job]];
                }
                [weakSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            [weakSelf completeJob:job videoURL:videoURL audioURL:audioURL];
        }];
}

- (NSString *)safeFilename:(NSString *)filename {
    NSCharacterSet *invalid =
        [NSCharacterSet characterSetWithCharactersInString:@"/\\:?%*|\"<>"];
    NSArray<NSString *> *parts = [filename componentsSeparatedByCharactersInSet:invalid];
    NSString *safe = [parts componentsJoinedByString:@"-"];
    if (safe.length > 120) {
        safe = [safe substringToIndex:120];
    }
    return safe.length == 0 ? YTzoomLocalized(@"YouTube Video") : safe;
}

- (NSURL *)destinationForTitle:(NSString *)title
                       category:(NSString *)category
                      extension:(NSString *)extension {
    NSURL *downloads = [YTzoomApplicationSupportDirectory()
        URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSURL *directory = [downloads URLByAppendingPathComponent:category isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
        withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@"%@.%@", title, extension]];
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        destination = [directory URLByAppendingPathComponent:
            [NSString stringWithFormat:@"%@ %ld.%@", title, (long)suffix++, extension]];
    }
    return destination;
}

- (void)writeMetadataForJob:(YTzoomDownloadJob *)job
                destination:(NSURL *)destination {
    NSURL *base = [destination URLByDeletingPathExtension];
    NSString *videoID = job.videoID;
    NSString *author = job.author;
    YTzoomAttachSponsorSegments(destination, videoID, author);
    if (job.thumbnailURL == nil) return;
    NSURL *imageURL = [base URLByAppendingPathExtension:@"jpg"];
    NSString *identifier = job.identifier;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:job.thumbnailURL completionHandler:^(NSData *data,
            NSURLResponse *response, NSError *error) {
        (void)response;
        if (error == nil && data.length != 0) {
            UIImage *image = [UIImage imageWithData:data];
            NSData *artwork = image == nil ? data : UIImageJPEGRepresentation(image, 0.9);
            [artwork writeToURL:imageURL atomically:YES];
            YTzoomDownloadLog(identifier, @"thumbnail saved bytes=%lu",
                (unsigned long)artwork.length);
            [YTzoomFFmpegMuxer embedArtworkData:artwork mediaURL:destination
                completion:^(NSError *embedError) {
                    if (embedError == nil) {
                        [NSFileManager.defaultManager removeItemAtURL:imageURL error:nil];
                        YTzoomDownloadLog(identifier, @"thumbnail embedded");
                    } else {
                        YTzoomDownloadLog(identifier, @"thumbnail sidecar kept error=%@",
                            embedError.localizedDescription);
                    }
                    YTzoomAttachSponsorSegments(destination, videoID, author);
                    [NSNotificationCenter.defaultCenter
                        postNotificationName:@"YTzoomDownloadLibraryChanged" object:nil];
                }];
        } else {
            YTzoomDownloadLog(identifier, @"thumbnail failed error=%@",
                error.localizedDescription ?: @"empty response");
            YTzoomAttachSponsorSegments(destination, videoID, author);
        }
    }];
    [task resume];
}

- (void)attachSubtitlesForJob:(YTzoomDownloadJob *)job
                  destination:(NSURL *)destination
                         then:(dispatch_block_t)handler {
    if (job.audioOnly ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Downloads.Subtitles")) {
        handler();
        return;
    }
    if (job.captionURL == nil) {
        handler();
        return;
    }
    NSString *language = job.captionLanguage;
    YTzoomFetchCuesForURL(job.captionURL, ^(NSArray<NSDictionary *> *cues) {
        if (cues.count == 0) {
            YTzoomDownloadLog(@"subs", @"no captions for %@", job.identifier);
            handler();
            return;
        }
        NSURL *staging = [destination.URLByDeletingPathExtension
            URLByAppendingPathExtension:@"subs.mp4"];
        [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
        [YTzoomFFmpegMuxer muxSubtitlesIntoURL:destination
                                          cues:cues
                                      language:language
                                     outputURL:staging
                                    completion:^(NSError *muxError) {
            if (muxError == nil &&
                [NSFileManager.defaultManager fileExistsAtPath:staging.path]) {
                [NSFileManager.defaultManager removeItemAtURL:destination
                                                        error:nil];
                [NSFileManager.defaultManager moveItemAtURL:staging
                                                      toURL:destination
                                                      error:nil];
            } else {
                [NSFileManager.defaultManager removeItemAtURL:staging error:nil];
            }
            handler();
        }];
    });
}

- (void)saveCompletedURL:(NSURL *)URL
                      job:(YTzoomDownloadJob *)job
                extension:(NSString *)extension {
    NSURL *destination = [self destinationForTitle:job.title
        category:job.category extension:extension];
    NSError *error = nil;
    [NSFileManager.defaultManager moveItemAtURL:URL toURL:destination error:&error];
    NSURL *temporaryDirectory = URL.URLByDeletingLastPathComponent;
    [NSFileManager.defaultManager removeItemAtURL:temporaryDirectory error:nil];
    if (error != nil) {
        [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
            success:NO message:YTzoomLocalized(@"Failed")];
        YTzoomDownloadLog(job.identifier, @"save failed error=%@",
            error.localizedDescription);
        [self showAlertWithTitle:YTzoomLocalized(@"Save failed")
            message:[self failureMessageForError:error job:job]];
    } else {
        __weak YTzoomDownloadCoordinator *weakSelf = self;
        [self attachSubtitlesForJob:job destination:destination then:^{
            YTzoomDownloadCoordinator *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (job.savesToPhotos) {
                YTzoomDownloadLog(job.identifier, @"saved path=%@ pending photos",
                    destination.path);
                [strongSelf prepareForPhotosJob:job destination:destination
                                           then:^(NSURL *ready) {
                    [strongSelf deliverToPhotosJob:job importURL:ready
                                        libraryURL:destination];
                }];
            } else {
                [strongSelf writeMetadataForJob:job destination:destination];
                [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
                    success:YES message:YTzoomLocalized(@"Complete")];
                YTzoomDownloadLog(job.identifier, @"saved path=%@",
                                  destination.path);
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"YTzoomDownloadLibraryChanged"
                                  object:nil];
                if (job.sharesFile) {
                    [strongSelf presentShareSheetForURL:destination];
                }
            }
            [strongSelf.activeJobs removeObjectForKey:job.identifier];
        }];
        return;
    }
    [self.activeJobs removeObjectForKey:job.identifier];
}

- (void)squareArtworkForJob:(YTzoomDownloadJob *)job
                       then:(void (^)(NSData *artwork))handler {
    if (job.thumbnailURL == nil) {
        handler(nil);
        return;
    }
    NSURLSessionDataTask *task = [NSURLSession.sharedSession
        dataTaskWithURL:job.thumbnailURL
      completionHandler:^(NSData *data, __unused NSURLResponse *response,
                          __unused NSError *error) {
        UIImage *image = data.length != 0 ? [UIImage imageWithData:data] : nil;
        if (image == nil) {
            YTzoomDownloadLog(job.identifier, @"artwork decode failed bytes=%lu",
                (unsigned long)data.length);
            handler(nil);
            return;
        }
        const CGFloat side = 720.0;
        UIGraphicsImageRendererFormat *format =
            [UIGraphicsImageRendererFormat defaultFormat];
        format.scale = 1.0;
        format.opaque = YES;
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)
                                                   format:format];
        UIImage *square = [renderer imageWithActions:
            ^(UIGraphicsImageRendererContext *context) {
            [UIColor.blackColor setFill];
            [context fillRect:CGRectMake(0, 0, side, side)];
            const CGFloat scale = MIN(side / image.size.width,
                                      side / image.size.height);
            const CGSize target = CGSizeMake(image.size.width * scale,
                                             image.size.height * scale);
            [image drawInRect:CGRectMake((side - target.width) / 2.0,
                                         (side - target.height) / 2.0,
                                         target.width, target.height)];
        }];
        NSData *jpeg = UIImageJPEGRepresentation(square, 0.9);
        YTzoomDownloadLog(job.identifier, @"artwork ready bytes=%lu",
            (unsigned long)jpeg.length);
        handler(jpeg);
    }];
    [task resume];
}

- (void)prepareForPhotosJob:(YTzoomDownloadJob *)job
                destination:(NSURL *)destination
                       then:(void (^)(NSURL *ready))handler {
    NSURL *converted = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSString stringWithFormat:@"photos-%@.mp4",
            job.identifier]];
    void (^report)(double) = ^(double fraction) {
        [YTzoomDownloadProgressView.sharedView updateJob:job.identifier
            stage:YTzoomLocalized(@"Converting") progress:fraction
            downloadedBytes:0 totalBytes:0];
    };
    if (job.audioOnly) {
        [self squareArtworkForJob:job then:^(NSData *artwork) {
            [YTzoomFFmpegMuxer videoFromAudioURL:destination artworkData:artwork
                outputURL:converted progress:report completion:^(NSError *error) {
                handler(error == nil ? converted : destination);
            }];
        }];
        return;
    }
    handler(destination);
}

- (void)deliverToPhotosJob:(YTzoomDownloadJob *)job
                 importURL:(NSURL *)importURL
                libraryURL:(NSURL *)libraryURL {
    {
        [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
            success:YES message:YTzoomLocalized(@"Complete")];
        __weak YTzoomDownloadCoordinator *weakSelf = self;
        const BOOL converted = ![importURL isEqual:libraryURL];
        YTzoomSaveVideoToPhotosFile(importURL, ^(BOOL success, NSError *error) {
            if (success) {
                [NSFileManager.defaultManager removeItemAtURL:importURL error:nil];
                if (converted) {
                    [NSFileManager.defaultManager removeItemAtURL:libraryURL
                        error:nil];
                }
                YTzoomDownloadLog(job.identifier, @"moved to photos converted=%d",
                    converted);
                YTzoomShowNotice(YTzoomLocalized(@"Saved to Photos"));
            } else {
                if (converted) {
                    [NSFileManager.defaultManager removeItemAtURL:importURL
                        error:nil];
                }
                [weakSelf writeMetadataForJob:job destination:libraryURL];
                if (error.code == 3302 &&
                    [error.domain isEqualToString:PHPhotosErrorDomain]) {
                    YTzoomShowNotice(YTzoomLocalized(
                        @"Photos cannot import this format. Kept in the YTzoom "
                        @"library instead."));
                } else if (error != nil) {
                    YTzoomShowNotice(YTzoomLocalized(
                        @"Could not add to Photos. Kept in the YTzoom library "
                        @"instead."));
                }
            }
            [NSNotificationCenter.defaultCenter
                postNotificationName:@"YTzoomDownloadLibraryChanged" object:nil];
        });
    }
}

- (void)beginBatchSharing {
    self.batchSharing = YES;
    self.batchShareURLs = [NSMutableArray array];
}

- (void)flushBatchSharingFromView:(UIView *)sourceView {
    NSArray<NSURL *> *urls = [self.batchShareURLs copy];
    self.batchSharing = NO;
    self.batchShareURLs = nil;
    if (urls.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (top == nil) return;
        UIActivityViewController *controller =
            [[UIActivityViewController alloc] initWithActivityItems:urls
                                             applicationActivities:nil];
        UIView *anchor = [self sheetAnchorForView:sourceView];
        controller.popoverPresentationController.sourceView = anchor;
        controller.popoverPresentationController.sourceRect = anchor.bounds;
        YTzoomDownloadLog(@"save", @"share sheet batch count=%lu",
            (unsigned long)urls.count);
        [top presentViewController:controller animated:YES completion:nil];
    });
}

- (void)presentShareSheetForURL:(NSURL *)url {
    if (url == nil) return;
    if (self.batchSharing) {
        [self.batchShareURLs addObject:url];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = [self topViewController];
        if (top == nil) return;
        UIActivityViewController *controller =
            [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                             applicationActivities:nil];
        UIView *anchor = [self sheetAnchorForView:self.downloadSourceView];
        controller.popoverPresentationController.sourceView = anchor;
        controller.popoverPresentationController.sourceRect = anchor.bounds;
        YTzoomDownloadLog(@"save", @"share sheet path=%@", url.lastPathComponent);
        [top presentViewController:controller animated:YES completion:nil];
    });
}

- (void)mergeVideoURL:(NSURL *)videoURL
              audioURL:(NSURL *)audioURL
                   job:(YTzoomDownloadJob *)job {
    NSURL *output = [videoURL.URLByDeletingLastPathComponent
        URLByAppendingPathComponent:@"merged.mp4"];
    YTzoomDownloadLog(job.identifier, @"merge start video=%@ audio=%@",
        videoURL.lastPathComponent, audioURL.lastPathComponent);
    __weak YTzoomDownloadCoordinator *weakSelf = self;
    [YTzoomFFmpegMuxer remuxVideoURL:videoURL audioURL:audioURL
        outputURL:output completion:^(NSError *error) {
            if (error != nil) {
                [YTzoomDownloadProgressView.sharedView finishJob:job.identifier
                    success:NO message:YTzoomLocalized(@"Failed")];
                YTzoomDownloadLog(job.identifier, @"merge failed error=%@",
                    error.localizedDescription);
                [weakSelf showAlertWithTitle:YTzoomLocalized(@"Merge failed")
                    message:[weakSelf failureMessageForError:error job:job]];
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                [NSFileManager.defaultManager
                    removeItemAtURL:videoURL.URLByDeletingLastPathComponent error:nil];
                [weakSelf.activeJobs removeObjectForKey:job.identifier];
                return;
            }
            [NSFileManager.defaultManager removeItemAtURL:videoURL error:nil];
            [NSFileManager.defaultManager removeItemAtURL:audioURL error:nil];
            YTzoomDownloadLog(job.identifier, @"merge complete");
            [weakSelf saveCompletedURL:output job:job extension:@"mp4"];
        }];
}

- (void)startDownload:(NSURL *)url
              category:(NSString *)category
             extension:(NSString *)extension {
    NSURLSessionDownloadTask *task = [self.session downloadTaskWithURL:url];
    YTzoomDownloadJob *job = [YTzoomDownloadJob new];
    job.task = task;
    job.title = [self safeFilename:
        [YTzoomStreamResolver titleFromPlayerResponse:self.playerResponse]];
    job.category = category;
    job.extension = extension;
    @synchronized (self.jobs) {
        self.jobs[@(task.taskIdentifier)] = job;
    }

    [self showCompactNotice:YTzoomLocalized(@"Download started")];
    [task resume];
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session;
    (void)bytesWritten;
    YTzoomDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(downloadTask.taskIdentifier)];
    }
    if (job == nil || totalBytesExpectedToWrite <= 0) {
        return;
    }
    (void)totalBytesWritten;
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    YTzoomDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(downloadTask.taskIdentifier)];
    }
    if (job == nil) {
        return;
    }

    NSURL *downloads = [YTzoomApplicationSupportDirectory()
        URLByAppendingPathComponent:@"Downloads"
                        isDirectory:YES];
    NSURL *directory = [downloads URLByAppendingPathComponent:job.category isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    NSString *filename =
        [NSString stringWithFormat:@"%@.%@", job.title, job.extension];
    NSURL *destination = [directory URLByAppendingPathComponent:filename];
    NSInteger suffix = 2;
    while ([NSFileManager.defaultManager fileExistsAtPath:destination.path]) {
        filename = [NSString stringWithFormat:@"%@ %ld.%@",
                    job.title,
                    (long)suffix++,
                    job.extension];
        destination = [directory URLByAppendingPathComponent:filename];
    }

    NSError *error = nil;
    [NSFileManager.defaultManager moveItemAtURL:location
                                         toURL:destination
                                         error:&error];
    if (error == nil) {
        job.savedURL = destination;
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    YTzoomDownloadJob *job = nil;
    @synchronized (self.jobs) {
        job = self.jobs[@(task.taskIdentifier)];
    }
    if (job == nil) {
        return;
    }
    @synchronized (self.jobs) {
        [self.jobs removeObjectForKey:@(task.taskIdentifier)];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (error != nil) {
            if (error.code != NSURLErrorCancelled) {
                [self showAlertWithTitle:YTzoomLocalized(@"Download failed")
                                 message:error.localizedDescription ?: YTzoomLocalized(@"Unknown error")];
            }
        } else if (job.savedURL != nil) {
            [self showAlertWithTitle:YTzoomLocalized(@"Download complete")
                             message:job.savedURL.lastPathComponent];
        } else {
            [self showAlertWithTitle:YTzoomLocalized(@"Download failed")
                             message:YTzoomLocalized(@"The file could not be saved.")];
        }
    });
}

@end
