#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT CGFloat YTzoomDownloadProgressRatio(NSURL *URL);
FOUNDATION_EXPORT UIView *YTzoomLibraryVideoView(void);

@class AVPlayer;
@class AVPlayerLayer;

extern NSNotificationName const YTzoomDownloadPlaybackDidChangeNotification;
extern NSNotificationName const YTzoomDownloadPlaybackDidStopNotification;
extern NSNotificationName const YTzoomDownloadSponsorDidSkipNotification;
extern NSNotificationName const YTzoomDownloadSponsorPromptNotification;
extern NSNotificationName const YTzoomLibraryPiPDidChangeNotification;
extern NSNotificationName const YTzoomLibraryFullPlayerWillShowNotification;
extern NSNotificationName const YTzoomLibraryFullPlayerWillHideNotification;

@interface YTzoomDownloadPlaybackSession : NSObject

+ (instancetype)sharedSession;
+ (nullable instancetype)existingSession;

@property(nonatomic, strong, readonly) AVPlayer *player;
@property(nonatomic, copy, readonly, nullable) NSURL *currentURL;
@property(nonatomic, copy, readonly) NSArray<NSURL *> *playlist;
@property(nonatomic, assign, readonly) NSInteger currentIndex;
@property(nonatomic, assign) BOOL autoplayEnabled;
@property(nonatomic, assign) BOOL gesturesEnabled;
@property(nonatomic, assign) BOOL repeatEnabled;
@property(nonatomic, assign) BOOL pauseAtEnd;
@property(nonatomic, assign) float playbackRate;
@property(nonatomic, copy, readonly) NSArray<NSDictionary<NSString *, id> *> *sponsorSegments;
@property(nonatomic, copy, readonly, nullable) NSDictionary<NSString *, id> *promptedSegment;

- (void)loadURL:(NSURL *)URL
       playlist:(NSArray<NSURL *> *)playlist
          index:(NSInteger)index;
- (void)updatePlaylist:(NSArray<NSURL *> *)playlist;
- (void)play;
- (void)pause;
- (void)togglePlayback;
- (void)seekBy:(NSTimeInterval)seconds;
- (void)playNext;
- (void)playPrevious;
- (void)stop;
- (void)skipSegment:(NSDictionary<NSString *, id> *)segment;
- (void)seekToTime:(NSTimeInterval)seconds;

@end

@interface YTzoomLibraryPiP : NSObject

+ (instancetype)sharedPiP;

@property(nonatomic, assign, readonly) BOOL active;
@property(nonatomic, assign) BOOL automatic;
@property(nonatomic, copy, nullable) void (^restoreHandler)(UIView * _Nullable owner);

- (void)useLayer:(AVPlayerLayer *)layer owner:(UIView *)owner;
- (BOOL)isUsingLayer:(AVPlayerLayer *)layer;
- (void)silenceOtherControllers;
- (void)start;
- (void)stop;

@end

@interface YTzoomDownloadPlayerController : UIViewController

- (instancetype)initWithSession:(YTzoomDownloadPlaybackSession *)session;
@property(nonatomic, copy, nullable) dispatch_block_t minimizeHandler;
@property(nonatomic, assign) CGRect sourceFrame;

@end

NS_ASSUME_NONNULL_END
