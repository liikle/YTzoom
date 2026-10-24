#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTzoomStreamOption : NSObject
@property(nonatomic, strong, nullable) NSURL *URL;
@property(nonatomic, copy) NSString *mimeType;
@property(nonatomic, copy) NSString *qualityLabel;
@property(nonatomic, copy) NSString *languageLabel;
@property(nonatomic, copy) NSString *audioTrackID;
@property(nonatomic, copy) NSString *xtags;
@property(nonatomic, assign) NSInteger bitrate;
@property(nonatomic, assign) NSInteger itag;
@property(nonatomic, assign) NSInteger contentLength;
@property(nonatomic, assign) NSInteger lastModified;
@property(nonatomic, assign) NSInteger width;
@property(nonatomic, assign) NSInteger height;
@property(nonatomic, assign, getter=isAudioOnly) BOOL audioOnly;
@property(nonatomic, assign, getter=isAdaptive) BOOL adaptive;
@property(nonatomic, assign, getter=isDefaultAudio) BOOL defaultAudio;
@property(nonatomic, strong) id rawFormat;
@end

@interface YTzoomStreamResolver : NSObject
+ (NSArray<YTzoomStreamOption *> *)optionsFromPlayerResponse:(id)playerResponse;
+ (NSArray<YTzoomStreamOption *> *)videoOptionsFromPlayerResponse:(id)playerResponse;
+ (NSArray<YTzoomStreamOption *> *)audioOptionsFromPlayerResponse:(id)playerResponse;
+ (nullable YTzoomStreamOption *)bestVideoFromPlayerResponse:(id)playerResponse;
+ (nullable YTzoomStreamOption *)bestPiPVideoFromPlayerResponse:(id)playerResponse;
+ (nullable YTzoomStreamOption *)bestAudioFromPlayerResponse:(id)playerResponse;
+ (NSString *)titleFromPlayerResponse:(id)playerResponse;
+ (NSString *)authorFromPlayerResponse:(id)playerResponse;
+ (NSString *)descriptionFromPlayerResponse:(id)playerResponse;
+ (nullable NSString *)videoIDFromPlayerResponse:(id)playerResponse;
+ (nullable NSURL *)thumbnailURLFromPlayerResponse:(id)playerResponse;
@end

NS_ASSUME_NONNULL_END
