#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary *> *YTzoomFilterSettings(NSString *query);
FOUNDATION_EXPORT void YTzoomPresentSettingsSearchOverlay(UIViewController *host);
FOUNDATION_EXPORT NSArray<NSArray<NSDictionary *> *> *YTzoomSearchResultSections(
    NSString *query, NSArray<NSString *> *_Nullable *_Nullable sectionTitles);
FOUNDATION_EXPORT void YTzoomOpenSettingsRecord(NSDictionary *record,
                                                UIViewController *presenter);

NS_ASSUME_NONNULL_END
