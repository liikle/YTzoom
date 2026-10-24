#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomFFmpegCompletion)(NSError * _Nullable error);
typedef void (^YTzoomFFmpegProgress)(double fraction);

FOUNDATION_EXPORT void YTzoomFFmpegCancelConversion(NSString *identifier);

@interface YTzoomFFmpegMuxer : NSObject
+ (void)remuxAudioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTzoomFFmpegCompletion)completion;
+ (void)remuxVideoURL:(NSURL *)videoURL
             audioURL:(NSURL *)audioURL
            outputURL:(NSURL *)outputURL
           completion:(YTzoomFFmpegCompletion)completion;
+ (void)normalizeMediaURL:(NSURL *)mediaURL
                outputURL:(NSURL *)outputURL
               completion:(YTzoomFFmpegCompletion)completion;
+ (void)videoFromAudioURL:(NSURL *)audioURL
             artworkData:(nullable NSData *)artworkData
                outputURL:(NSURL *)outputURL
                 progress:(nullable YTzoomFFmpegProgress)progress
               completion:(YTzoomFFmpegCompletion)completion;
+ (void)muxSubtitlesIntoURL:(NSURL *)mediaURL
                       cues:(NSArray<NSDictionary *> *)cues
                   language:(nullable NSString *)language
                  outputURL:(NSURL *)outputURL
                 completion:(YTzoomFFmpegCompletion)completion;
+ (void)embedArtworkData:(NSData *)artworkData
                 mediaURL:(NSURL *)mediaURL
               completion:(YTzoomFFmpegCompletion)completion;
@end

NS_ASSUME_NONNULL_END
