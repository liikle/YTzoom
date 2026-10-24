#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^YTzoomOverlayConfigurator)(UIView *overlay, UIStackView *stack);

FOUNDATION_EXPORT void YTzoomRegisterOverlayConfigurator(
    NSString *identifier,
    YTzoomOverlayConfigurator configurator
);

FOUNDATION_EXPORT UIButton *YTzoomOverlayButton(
    UIStackView *stack,
    NSString *identifier,
    NSString *symbolName,
    id target,
    SEL action
);

FOUNDATION_EXPORT void YTzoomPresentNativeSheet(
    NSString *_Nullable title,
    NSString *_Nullable subtitle,
    UIView *_Nullable sourceView,
    NSArray<NSDictionary *> *actions
);

FOUNDATION_EXPORT id _Nullable YTzoomMakeSheet(NSString *_Nullable title, NSString *_Nullable subtitle);

FOUNDATION_EXPORT BOOL YTzoomShowSheet(id _Nullable sheet, UIViewController *_Nullable presenter);

NS_ASSUME_NONNULL_END
