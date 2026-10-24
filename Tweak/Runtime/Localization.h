#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTzoomLanguageKey;

FOUNDATION_EXPORT NSString *YTzoomLocalized(NSString *key);
FOUNDATION_EXPORT NSArray<NSString *> *YTzoomAvailableLanguages(void);
FOUNDATION_EXPORT NSString *YTzoomLanguageDisplayName(NSString *code);
FOUNDATION_EXPORT void YTzoomResetLocalizationCache(void);

NS_ASSUME_NONNULL_END
