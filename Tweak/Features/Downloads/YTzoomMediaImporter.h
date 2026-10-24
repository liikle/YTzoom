#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomMediaImportCompletion)(NSUInteger importedCount,
                                            NSError * _Nullable error);

@interface YTzoomMediaImporter : NSObject

+ (void)importURLs:(NSArray<NSURL *> *)URLs
          category:(NSString *)category
        completion:(YTzoomMediaImportCompletion)completion;

@end

NS_ASSUME_NONNULL_END
