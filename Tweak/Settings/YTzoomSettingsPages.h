#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIViewController *YTzoomMakeSettingsPage(NSString *pageID);
FOUNDATION_EXPORT NSArray<NSDictionary *> *YTzoomSettingsMenu(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakePlayerControlsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeSponsorBlockController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeTabBarOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeOverlayOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeStreamingOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeNavigationOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeShortsOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeGlassOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeMiscOptionsController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeGestureOptionsController(void);
FOUNDATION_EXPORT void YTzoomStartupDestinations(
    NSArray<NSString *> * _Nullable * _Nullable titles,
    NSArray<NSString *> * _Nullable * _Nullable values);
FOUNDATION_EXPORT UIViewController *YTzoomMakeStartupPickerController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeWiFiQualityController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeCellularQualityController(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeCreditsController(void);
FOUNDATION_EXPORT NSString *YTzoomPickerSummary(NSString *key,
                                                NSArray<NSString *> *titles,
                                                NSArray *values,
                                                NSUInteger defaultIndex);
FOUNDATION_EXPORT void YTzoomShowRestartNotice(UIViewController *controller);
FOUNDATION_EXPORT BOOL YTzoomPreferenceNeedsRestart(NSString *key);
typedef void (^YTzoomChoiceHandler)(NSUInteger index);
FOUNDATION_EXPORT void YTzoomPresentSelectionMenu(UIViewController *presenter,
                                                  UIView *sourceView,
                                                  NSString *title,
                                                  NSArray<NSString *> *titles,
                                                  NSUInteger selectedIndex,
                                                  YTzoomChoiceHandler handler);
FOUNDATION_EXPORT void YTzoomPresentChoiceMenu(UIViewController *presenter,
                                               UIView *sourceView,
                                               NSString *title,
                                               NSArray<NSString *> *titles,
                                               NSArray *values,
                                               NSString *key,
                                               NSUInteger defaultIndex,
                                               YTzoomChoiceHandler handler);

FOUNDATION_EXPORT NSArray<NSDictionary *> *YTzoomAllPageDefinitions(void);
FOUNDATION_EXPORT UIViewController *YTzoomMakeSettingsResultsController(
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);
FOUNDATION_EXPORT void YTzoomUpdateSettingsResultsController(
    UIViewController *controller,
    NSArray<NSArray<NSDictionary *> *> *sections,
    NSArray<NSString *> *sectionTitles);

NS_ASSUME_NONNULL_END
