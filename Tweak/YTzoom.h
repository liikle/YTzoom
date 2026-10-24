#import <Foundation/Foundation.h>

@class UIView;
@class CALayer;
@class UIImage;
@class UIColor;
@class UIViewController;

NS_ASSUME_NONNULL_BEGIN

void YTzoomRouteSpeedMenuItem(id _Nullable renderers, id _Nullable actions, UIView *_Nullable view, id _Nullable responder);

FOUNDATION_EXPORT NSString * const YTzoomVersion;

void YTzoomInstallAdsHooks(void);
void YTzoomHandleAdDisplayView(UIView *view);
void YTzoomCollapseHostCell(UIView *view);
void YTzoomHandleAdCellLayout(UIView *cell);
void YTzoomHandleAdCellReuse(UIView *cell);
NSArray *YTzoomFilterAdSections(NSArray *sections);
void YTzoomInstallPromoHooks(void);
void YTzoomInstallSponsorBlockHooks(void);
void YTzoomInstallDownloadHooks(void);
void YTzoomInstallQueueHooks(void);
void YTzoomQueuePrepareMenuRenderers(id _Nullable renderers);
BOOL YTzoomQueueHasItems(void);
BOOL YTzoomQueueOwnsCurrentVideo(void);
NSString * _Nullable YTzoomLastVideoID(void);
void YTzoomInstallGlobalDownloadMiniPlayer(void);
void YTzoomInstallOLEDHooks(void);
void YTzoomInstallStartupHooks(void);
void YTzoomInstallPremiumLogoHooks(void);
void YTzoomInstallBackgroundPlaybackHooks(void);
void YTzoomInstallPiPHooks(void);
void YTzoomInstallSpeedHooks(void);
double YTzoomStartPlaybackRate(void);
void YTzoomInstallLoopHooks(void);
void YTzoomInstallAutoplayHooks(void);
void YTzoomOpenPausedVideoActivated(id player);
void YTzoomInstallCaptionHooks(void);
void YTzoomInstallTranscriptHooks(void);
NSArray<NSDictionary *> *_Nullable YTzoomParseCaptionCues(NSData *data);
NSArray *_Nullable YTzoomCaptionTracksForResponse(id playerResponse);
NSArray<NSDictionary *> *_Nullable YTzoomCaptionChoicesForResponse(id playerResponse);
NSString *YTzoomCaptionTrackLabel(id track);
NSString *_Nullable YTzoomCaptionTrackLanguage(id track);
NSURL *_Nullable YTzoomCaptionTrackURL(id track);
void YTzoomFetchCuesForURL(NSURL *_Nullable url,
                           void (^completion)(NSArray<NSDictionary *> *_Nullable cues));
void YTzoomFetchCaptionCues(id playerResponse,
                            void (^completion)(NSArray<NSDictionary *> *_Nullable cues,
                                               NSString *_Nullable language));
void YTzoomCaptionsSnapshot(id player);
void YTzoomCaptionsRestore(id player);
void YTzoomApplyPreferredCaptionLanguage(id player);
void YTzoomInstallSleepTimerHooks(void);
void YTzoomInstallDoubleTapHooks(void);
void YTzoomInstallVideoZoomHooks(void);
void YTzoomPauseYouTubePlayer(void);
void YTzoomConfigureTapToSeek(UIView *view);
void YTzoomInstallShortsLimitHooks(void);
void YTzoomInstallShortsStartupHooks(void);
void YTzoomInstallShortsPinchHooks(void);
void YTzoomInstallShortsPiPHooks(void);
void YTzoomInstallShortsStickerHooks(void);
void YTzoomInstallShortsCreatorHooks(void);
void YTzoomPresentStickerFontMenu(UIViewController *controller);
void YTzoomSetShortsOverlayFullscreen(UIView *overlay, BOOL fullscreen);
void YTzoomSetShortsElementsFullscreen(UIView *container, BOOL fullscreen);
UIView *YTzoomShortsContainerForView(UIView *view, UIView *fallbackRoot);
BOOL YTzoomShortsNewFullscreenActive(void);
void YTzoomRegisterFadedShortsContainer(UIView *container);
void YTzoomFadeShortsElement(UIView *element);
BOOL YTzoomShortsPivotShowBlocked(void);
void YTzoomSetShortsNewFullscreen(UIView *_Nullable container, BOOL fullscreen);
BOOL YTzoomShortsLimitReached(void);
BOOL YTzoomPlayerIsShorts(id player);
NSInteger YTzoomRealUserInterfaceIdiom(void);
void YTzoomInstallProgressBarHooks(void);
void YTzoomApplyProgressStyleToBar(UIView *bar);
void YTzoomStyleProgressLayer(CALayer *layer, CGFloat trackWidth);
UIImage *YTzoomProgressFillImage(CGFloat width, CGFloat height);
UIColor *YTzoomProgressScrubberTint(void);
void YTzoomInstallStreamingHooks(void);
void YTzoomInstallHLSPlaybackHooks(void);
NSInteger YTzoomPlaybackFixMode(void);
id _Nullable YTzoomHLSOriginalResponse(NSString * _Nullable videoID);
BOOL YTzoomHLSBeginFallback(NSString * _Nullable videoID, void (^ _Nonnull ready)(BOOL available));
void YTzoomInstallShortsHooks(void);
void YTzoomInstallSideloadCompatibilityHooks(void);
void YTzoomInstallCastCompatibilityHooks(void);
void YTzoomStartCastDiscovery(void);
void YTzoomInstallTabBarHooks(void);
void YTzoomRefreshPivotBarBackground(void);
BOOL YTzoomLiquidGlassAvailable(void);
NSInteger YTzoomFrostedTabBarMode(void);
void YTzoomApplyTopNavigationGlass(UIView *container);
UIView *YTzoomMakeSettingsGlass(void);
void YTzoomInstallNavigationBehaviorHooks(void);
void YTzoomInstallPlayerGestureHooks(void);
void YTzoomInstallSettingsEntryHooks(void);
void YTzoomInstallNativeSettingsHooks(void);
void YTzoomInstallOverlayVisibilityHooks(void);
void YTzoomInstallContentVisibilityHooks(void);
void YTzoomInstallNavigationVisibilityHooks(void);
void YTzoomInstallMiscellaneousHooks(void);
void YTzoomInstallCopyCommentHooks(void);
void YTzoomInstallProfilePictureHooks(void);
void YTzoomInstallPostImageSaverHooks(void);
void YTzoomInstallPlaylistDownloaderHooks(void);
BOOL YTzoomProductIdentifierMatches(NSString * _Nullable identifier);
BOOL YTzoomViewIsInsidePlayerOverlay(UIView *view);
void YTzoomHideProductSubtree(UIView *view);
BOOL YTzoomProductOverlayMatches(id overlay);
void YTzoomInstallNativeShareHooks(void);
void YTzoomProfileConsiderDisplayView(UIView *view, id node);
void YTzoomScheduleFirstLaunch(void);
void YTzoomInstallAITitleHooks(void);
void YTzoomInstallMoshCameraHooks(void);
void YTzoomCommentHoldConsider(UIView *input);
FOUNDATION_EXPORT NSString * const YTzoomMoshCameraKey;
FOUNDATION_EXPORT NSString * const YTzoomMoshActiveKey;
FOUNDATION_EXPORT NSString * const YTzoomMoshUltraWideKey;
FOUNDATION_EXPORT NSString * const YTzoomMoshStabilizationKey;
FOUNDATION_EXPORT NSString * const YTzoomMoshHighFrameRateKey;
FOUNDATION_EXPORT NSString * const YTzoomMoshGhostKey;
FOUNDATION_EXPORT NSString * const YTzoomHoldAllButtonKey;
FOUNDATION_EXPORT NSString * const YTzoomHoldAllActiveKey;
FOUNDATION_EXPORT NSString * const YTzoomHoldAllBasicTextKey;
FOUNDATION_EXPORT NSString * const YTzoomHoldAllTextKey;
void YTzoomInstallRegionHooks(void);
void YTzoomApplyRegionOverride(id _Nullable context);
NSString * _Nullable YTzoomRegionOverride(void);
NSArray<NSString *> *YTzoomRegionCountryCodes(void);
FOUNDATION_EXPORT NSString * const YTzoomAITitlesKey;
FOUNDATION_EXPORT NSString * const YTzoomAITitlesPlacementKey;
FOUNDATION_EXPORT NSString * const YTzoomRegionCountryKey;
FOUNDATION_EXPORT NSString * const YTzoomRegionLanguageKey;
FOUNDATION_EXPORT NSString * const YTzoomRegionTimeZoneKey;
FOUNDATION_EXPORT NSString * const YTzoomRegionLocaleKey;

NS_ASSUME_NONNULL_END
void YTzoomInstallPlaybackFixHooks(void);
NSDictionary<NSString *, NSString *> * _Nullable YTzoomSolveChallenges(NSString * _Nullable playerID,
    NSString * _Nullable playerJS, NSString * _Nonnull type, NSArray<NSString *> * _Nonnull challenges);
NSData * _Nonnull YTzoomTVClientInfo(void);
NSDictionary<NSString *, NSString *> * _Nonnull YTzoomTVHeaders(NSString * _Nullable visitor);
void YTzoomTVFetchPlayerResponse(NSString * _Nonnull videoID,
    void (^ _Nonnull completion)(id _Nullable response, NSString * _Nullable visitor, NSError * _Nullable error));
NSString * _Nonnull YTzoomSolveURLParameterN(NSString * _Nullable playerID, NSString * _Nullable playerJS,
    NSString * _Nonnull URLString);
