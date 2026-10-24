#import <Foundation/Foundation.h>

@class YTzoomStreamOption;

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomSABRProgress)(double audioProgress,
                                  double videoProgress,
                                  int64_t audioBytes,
                                  int64_t videoBytes,
                                  NSInteger mediaPhase);
typedef void (^YTzoomSABRCompletion)(NSURL * _Nullable videoURL,
                                    NSURL * _Nullable audioURL,
                                    NSError * _Nullable error);
typedef void (^YTzoomPlayerReloadCompletion)(id _Nullable playerResponse,
                                             NSError * _Nullable error);
typedef void (^YTzoomNativeRequestCompletion)(
    NSURLRequest * _Nullable request,
    NSInteger requestNumber,
    NSError * _Nullable error);

FOUNDATION_EXPORT void YTzoomSABRSetPoToken(id _Nullable token);
FOUNDATION_EXPORT void YTzoomSABRSetStandaloneClient(NSString *identifier,
    NSData * _Nullable clientInfo, NSDictionary<NSString *, NSString *> * _Nullable headers);
FOUNDATION_EXPORT NSString *_Nullable YTzoomSABRPoTokenString(void);
FOUNDATION_EXPORT NSUInteger YTzoomSABRPoTokenLength(void);
FOUNDATION_EXPORT void YTzoomSABRSetNativeHeaders(
    NSDictionary<NSString *, NSString *> *headers);
FOUNDATION_EXPORT void YTzoomSABRSetNativeRequest(NSURLRequest *request);
FOUNDATION_EXPORT void YTzoomSABRSetCurrentVideoID(NSString * _Nullable videoID);
FOUNDATION_EXPORT id _Nullable YTzoomCachedPlayerResponse(NSString *videoID);
FOUNDATION_EXPORT void YTzoomStorePlayerResponse(NSString *videoID, id response);
FOUNDATION_EXPORT NSString * _Nullable YTzoomSABRCurrentVideoIDValue(void);
FOUNDATION_EXPORT NSUInteger YTzoomPurgeDownloadScratch(BOOL includeActive);
FOUNDATION_EXPORT void YTzoomPreparePlayerWithRoute(NSString *videoID,
                                                    BOOL forcePlayerRoute,
                                                    YTzoomPlayerReloadCompletion completion);
FOUNDATION_EXPORT void YTzoomPreparePlayer(NSString *videoID,
                                           YTzoomPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL YTzoomPlaybackTemplateReady(void);
FOUNDATION_EXPORT void YTzoomSABRRestoreSeed(void);
FOUNDATION_EXPORT void YTzoomRestorePlayerRequest(void);
FOUNDATION_EXPORT void YTzoomInstallFeedDownloadHooks(void);
FOUNDATION_EXPORT void YTzoomDiscardRestoredRequest(void);
FOUNDATION_EXPORT void YTzoomResolvePlayerResponse(
    NSString *videoID,
    YTzoomPlayerReloadCompletion completion);
FOUNDATION_EXPORT void YTzoomReloadPlayer(NSString * _Nullable videoID,
                                         NSString *token,
                                         YTzoomPlayerReloadCompletion completion);
FOUNDATION_EXPORT BOOL YTzoomHasNativeOnesieSession(NSString *videoID);
FOUNDATION_EXPORT void YTzoomBuildNativeOnesieRequest(
    NSString *videoID,
    YTzoomNativeRequestCompletion completion);

@interface YTzoomSABRTask : NSObject
- (void)cancel;
@end

@interface YTzoomSABRDownloader : NSObject

+ (YTzoomSABRTask *)downloadPlayerResponse:(id)playerResponse
                   videoOption:(YTzoomStreamOption *)videoOption
                   audioOption:(YTzoomStreamOption *)audioOption
                     audioOnly:(BOOL)audioOnly
                       videoID:(NSString *)videoID
                     identifier:(NSString *)identifier
                      progress:(nullable YTzoomSABRProgress)progress
                    completion:(YTzoomSABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END
