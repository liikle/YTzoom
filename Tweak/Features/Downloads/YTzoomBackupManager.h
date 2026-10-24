#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomBackupCreationCompletion)(NSURL * _Nullable URL,
                                                NSError * _Nullable error);
typedef void (^YTzoomBackupRestoreCompletion)(NSError * _Nullable error);

@interface YTzoomBackupManager : NSObject

+ (void)createBackupWithCompletion:(YTzoomBackupCreationCompletion)completion;
+ (void)restoreBackupFromURL:(NSURL *)URL
                  completion:(YTzoomBackupRestoreCompletion)completion;

@end

NS_ASSUME_NONNULL_END
