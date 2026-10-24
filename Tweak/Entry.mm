#import "YTzoom.h"
#import "Features/Downloads/SABRDownloader.h"
#import "Features/Downloads/DownloadLog.h"
#import "Features/SponsorBlock/DeArrow.h"
#import "Runtime/Preferences.h"

#import <UIKit/UIKit.h>

#ifndef YTzoom_COMBINED_SABR
#define YTzoom_COMBINED_SABR 0
#endif

NSString * const YTzoomVersion = @YTzoom_VERSION_STRING;

static void YTzoomInstallModules(void) {
    YTzoomInstallSideloadCompatibilityHooks();
    YTzoomInstallCastCompatibilityHooks();
    YTzoomInstallAdsHooks();
    YTzoomInstallPromoHooks();
    YTzoomInstallSponsorBlockHooks();
    YTzoomInstallDeArrow();
    YTzoomInstallOLEDHooks();
    YTzoomInstallStartupHooks();
    YTzoomInstallPremiumLogoHooks();
    YTzoomInstallBackgroundPlaybackHooks();
    YTzoomInstallSpeedHooks();
    YTzoomInstallLoopHooks();
    YTzoomInstallAutoplayHooks();
    YTzoomInstallCaptionHooks();
    YTzoomInstallTranscriptHooks();
    YTzoomInstallSleepTimerHooks();
    YTzoomInstallPiPHooks();
    YTzoomInstallPlaybackFixHooks();
    YTzoomInstallDownloadHooks();
    YTzoomSABRRestoreSeed();
    YTzoomRestorePlayerRequest();
    YTzoomInstallPlaylistDownloaderHooks();
    YTzoomInstallFeedDownloadHooks();
    YTzoomInstallQueueHooks();
    YTzoomInstallGlobalDownloadMiniPlayer();
    YTzoomInstallDoubleTapHooks();
    YTzoomInstallVideoZoomHooks();
    YTzoomInstallShortsLimitHooks();
    YTzoomInstallShortsStartupHooks();
    YTzoomInstallShortsPinchHooks();
    YTzoomInstallShortsPiPHooks();
    YTzoomInstallProgressBarHooks();
    YTzoomInstallStreamingHooks();
    YTzoomInstallHLSPlaybackHooks();
    YTzoomInstallShortsHooks();
    YTzoomInstallTabBarHooks();
    YTzoomInstallNavigationBehaviorHooks();
    YTzoomInstallPlayerGestureHooks();
    YTzoomInstallOverlayVisibilityHooks();
    YTzoomInstallContentVisibilityHooks();
    YTzoomInstallNavigationVisibilityHooks();
    YTzoomInstallMiscellaneousHooks();
    YTzoomInstallCopyCommentHooks();
    YTzoomInstallProfilePictureHooks();
    YTzoomInstallPostImageSaverHooks();
    YTzoomInstallNativeShareHooks();
    YTzoomInstallSettingsEntryHooks();
    YTzoomInstallNativeSettingsHooks();
}

__attribute__((constructor))
static void YTzoomEntryPoint(void) {
    @autoreleasepool {
        YTzoomClearDownloadLog();
        YTzoomRegisterDefaults();
        YTzoomScheduleFirstLaunch();
        YTzoomInstallModules();
    }
}
