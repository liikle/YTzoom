#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class UIView;

FOUNDATION_EXPORT void YTzoomShowNotice(NSString *message);
FOUNDATION_EXPORT BOOL YTzoomApplyGlassBackground(UIView *view, BOOL dark);
FOUNDATION_EXPORT BOOL YTzoomShowYouTubeDialog(NSString *title,
                                                NSString *message);
FOUNDATION_EXPORT BOOL YTzoomShowYouTubeConfirmation(
    NSString *title,
    NSString *message,
    NSString *actionTitle,
    dispatch_block_t action
);

NS_ASSUME_NONNULL_END
