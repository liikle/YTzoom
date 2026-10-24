#import <Foundation/Foundation.h>
#import "SABRDownloader.h"

@class YTzoomStreamOption;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTzoomDownloadMethodKey;
FOUNDATION_EXPORT BOOL YTzoomDirectDownloadsEnabled(void);
FOUNDATION_EXPORT BOOL YTzoomTVDownloadsEnabled(void);

@interface YTzoomDirectTask : NSObject
- (void)cancel;
@end

@interface YTzoomDirectDownloader : NSObject

+ (void)fetchOptionsForVideoID:(NSString *)videoID
                    completion:(void (^)(NSArray<YTzoomStreamOption *> *options))completion;
+ (NSString *)codecNameForOption:(YTzoomStreamOption *)option;

+ (YTzoomDirectTask *)downloadVideoID:(NSString *)videoID
                          videoOption:(nullable YTzoomStreamOption *)videoOption
                          audioOption:(YTzoomStreamOption *)audioOption
                            audioOnly:(BOOL)audioOnly
                           identifier:(NSString *)identifier
                             progress:(nullable YTzoomSABRProgress)progress
                           completion:(YTzoomSABRCompletion)completion;

@end

NS_ASSUME_NONNULL_END
