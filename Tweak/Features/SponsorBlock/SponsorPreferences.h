#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTzoomSponsorCategoryDefinitions(void);
FOUNDATION_EXPORT NSString *YTzoomSponsorBehaviorKey(NSString *category);
FOUNDATION_EXPORT NSString *YTzoomSponsorColorKey(NSString *category);
FOUNDATION_EXPORT NSInteger YTzoomSponsorCategoryBehavior(NSString *category);
FOUNDATION_EXPORT NSArray<NSString *> *YTzoomSponsorEnabledCategories(void);
FOUNDATION_EXPORT UIColor *YTzoomSponsorCategoryColor(NSString *category);
FOUNDATION_EXPORT NSInteger YTzoomSponsorNotificationMode(void);
FOUNDATION_EXPORT NSTimeInterval YTzoomSponsorSkipAlertDuration(void);
FOUNDATION_EXPORT NSTimeInterval YTzoomSponsorUnskipAlertDuration(void);

NS_ASSUME_NONNULL_END
