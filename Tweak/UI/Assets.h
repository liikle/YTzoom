#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT UIColor *YTzoomAccentColor(void);
FOUNDATION_EXPORT NSBundle * _Nullable YTzoomAssetsBundle(void);
FOUNDATION_EXPORT UIImage * _Nullable YTzoomAssetImage(
    NSString *name,
    NSString * _Nullable fallbackSymbol
);
FOUNDATION_EXPORT UIImage * _Nullable YTzoomYouTubeImage(
    NSArray<NSString *> *names,
    NSString * _Nullable fallbackSymbol
);
FOUNDATION_EXPORT UIImage * _Nullable YTzoomGearImage(void);
FOUNDATION_EXPORT UIImage * _Nullable YTzoomShortsImage(BOOL selected);
FOUNDATION_EXPORT UIImage * _Nullable YTzoomDownloadTabImage(BOOL selected);

NS_ASSUME_NONNULL_END
