#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const YTzoomDownloadInfoDidChangeNotification;

FOUNDATION_EXPORT void YTzoomAttachSponsorSegments(NSURL *fileURL, NSString *videoID,
                                                 NSString * _Nullable author);
FOUNDATION_EXPORT NSString * _Nullable YTzoomStoredChannelName(NSURL *fileURL);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *YTzoomStoredSponsorSegments(NSURL *fileURL);
FOUNDATION_EXPORT void YTzoomRefreshSponsorSegments(
    NSURL *fileURL, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *segments));

NS_ASSUME_NONNULL_END
