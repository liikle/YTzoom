#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

static IMP OriginalPlayableInBackground;
static IMP OriginalMLPlayableInBackground;
static IMP OriginalBackgroundEnabled;
static IMP OriginalPlayableInPiP;

static BOOL YTzoomBackgroundBoolean(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(YTzoomBackgroundPlaybackKey)) {
        return YES;
    }

    IMP original = NULL;
    if ([NSStringFromSelector(selector) isEqualToString:@"isPlayableInBackground"]) {
        original = OriginalPlayableInBackground;
    } else if ([NSStringFromSelector(selector) isEqualToString:@"playableInBackground"]) {
        original = OriginalMLPlayableInBackground;
    } else {
        original = OriginalBackgroundEnabled;
    }
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTzoomPlayableInPiP(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(YTzoomBackgroundPlaybackKey)) return YES;
    return OriginalPlayableInPiP != NULL &&
        ((BOOL (*)(id, SEL))OriginalPlayableInPiP)(receiver, selector);
}

void YTzoomInstallBackgroundPlaybackHooks(void) {
    YTzoomInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInPictureInPicture",
                              (IMP)YTzoomPlayableInPiP,
                              &OriginalPlayableInPiP);
    YTzoomInstallInstanceHook(@"YTIPlayabilityStatus",
                              @"isPlayableInBackground",
                              (IMP)YTzoomBackgroundBoolean,
                              &OriginalPlayableInBackground);
    YTzoomInstallInstanceHook(@"MLVideo",
                              @"playableInBackground",
                              (IMP)YTzoomBackgroundBoolean,
                              &OriginalMLPlayableInBackground);
    if (!YTzoomInstallInstanceHook(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)YTzoomBackgroundBoolean,
            &OriginalBackgroundEnabled)) {
        YTzoomAddInstanceMethod(
            @"YTIBackgroundOfflineSettingCategoryEntryRenderer",
            @"isBackgroundEnabled",
            (IMP)YTzoomBackgroundBoolean,
            "B@:"
        );
    }
}
