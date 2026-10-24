#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface YTzoomRootOptionsController : UIViewController
@end

FOUNDATION_EXPORT UINavigationController *YTzoomMakeSettingsNavigationController(void);
FOUNDATION_EXPORT void YTzoomApplyAppearance(UIViewController *controller);
FOUNDATION_EXPORT UIViewController *YTzoomMakeDownloadLogController(void);
FOUNDATION_EXPORT NSString *YTzoomDeviceInformationText(void);
FOUNDATION_EXPORT BOOL YTzoomOwnsNavigationController(
    UINavigationController *_Nullable navigation);

NS_ASSUME_NONNULL_END
