#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class YTzoomDownloadPlaybackSession;

@interface YTzoomAudioPlayerController : UIViewController
- (instancetype)initWithSession:(YTzoomDownloadPlaybackSession *)session;
@property(nonatomic, copy, nullable) dispatch_block_t minimizeHandler;
@end

NS_ASSUME_NONNULL_END
