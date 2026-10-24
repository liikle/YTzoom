#import <Foundation/Foundation.h>

@class UIImage;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTzoomGeminiAPIKeyKey;
FOUNDATION_EXPORT NSString * const YTzoomGeminiModelKey;
FOUNDATION_EXPORT NSString * const YTzoomGeminiDefaultModel;

typedef void (^YTzoomGeminiTitlesCompletion)(NSArray<NSString *> *_Nullable titles,
                                             NSString *_Nullable error);

FOUNDATION_EXPORT BOOL YTzoomGeminiHasAPIKey(void);

// Calls back on the main queue.
FOUNDATION_EXPORT void YTzoomGeminiGenerateTitles(NSArray<UIImage *> *images,
                                                  BOOL imagesAreScreenshot,
                                                  NSArray<NSString *> *editorTexts,
                                                  NSString *_Nullable currentTitle,
                                                  NSUInteger count,
                                                  BOOL hashtags,
                                                  YTzoomGeminiTitlesCompletion completion);

NS_ASSUME_NONNULL_END
