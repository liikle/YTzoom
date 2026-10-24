#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomSponsorCompletion)(
    NSArray<NSDictionary<NSString *, id> *> *segments
);

@interface YTzoomSponsorClient : NSObject
+ (instancetype)sharedClient;
- (void)segmentsForVideoID:(NSString *)videoID
                completion:(YTzoomSponsorCompletion)completion;
- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(YTzoomSponsorCompletion)completion;
@end

NS_ASSUME_NONNULL_END
