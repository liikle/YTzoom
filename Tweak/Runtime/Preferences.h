#import <Foundation/Foundation.h>

@class UIColor, UITraitCollection;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const YTzoomMasterEnabledKey;
FOUNDATION_EXPORT NSString * const YTzoomOLEDKey;
FOUNDATION_EXPORT NSString * const YTzoomNoAdsKey;
FOUNDATION_EXPORT NSString * const YTzoomSponsorBlockKey;
FOUNDATION_EXPORT NSString * const YTzoomDownloadKey;
FOUNDATION_EXPORT NSString * const YTzoomBackgroundPlaybackKey;
FOUNDATION_EXPORT NSString * const YTzoomPiPKey;
FOUNDATION_EXPORT NSString * const YTzoomSpeedKey;
FOUNDATION_EXPORT NSString * const YTzoomLoopKey;
FOUNDATION_EXPORT NSString * const YTzoomSleepTimerKey;
FOUNDATION_EXPORT NSString * const YTzoomPreferencesDidChangeNotification;

FOUNDATION_EXPORT void YTzoomRegisterDefaults(void);
FOUNDATION_EXPORT BOOL YTzoomMasterEnabled(void);
FOUNDATION_EXPORT BOOL YTzoomFeatureEnabled(NSString *key);
FOUNDATION_EXPORT BOOL YTzoomDownloadsEnabled(void);
FOUNDATION_EXPORT NSInteger YTzoomDownloadPlacement(void);
FOUNDATION_EXPORT BOOL YTzoomOLEDActive(UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *YTzoomInterfaceBackgroundColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT UIColor *YTzoomInterfaceSurfaceColor(
    UITraitCollection * _Nullable traits);
FOUNDATION_EXPORT BOOL YTzoomSponsorBlockEnabled(void);
FOUNDATION_EXPORT void YTzoomSetPreference(NSString *key, BOOL enabled);
FOUNDATION_EXPORT id _Nullable YTzoomPreferenceObject(NSString *key);
FOUNDATION_EXPORT void YTzoomSetPreferenceObject(NSString *key, id _Nullable value);
FOUNDATION_EXPORT NSURL *YTzoomApplicationSupportDirectory(void);
FOUNDATION_EXPORT NSUInteger YTzoomPurgeSystemCaches(void);

NS_ASSUME_NONNULL_END
