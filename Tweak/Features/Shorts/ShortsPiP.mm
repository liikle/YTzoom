#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/YTzoomDownloadPlayerController.h"

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const YTzoomShortsPiPKey = @"YTzoom.Preference.Shorts.PiPDisabled";

static IMP YTzoomShortsOrigAllowed;
static IMP YTzoomShortsOrigEligible;
static IMP YTzoomShortsOrigCanEnable;

static id YTzoomShortsPiPOwner(id controller) {
    Ivar ivar = class_getInstanceVariable(object_getClass(controller), "_delegate");
    if (ivar == NULL) return nil;
    const char *type = ivar_getTypeEncoding(ivar);
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(controller, ivar);
}

static BOOL YTzoomLibraryOwnsPiP(void) {
    YTzoomDownloadPlaybackSession *session = YTzoomDownloadPlaybackSession.existingSession;
    return session.currentURL != nil && session.player.rate != 0.0f;
}

static BOOL YTzoomShortsBlocksPiP(id controller) {
    if (YTzoomLibraryOwnsPiP()) return YES;
    if (!YTzoomFeatureEnabled(YTzoomShortsPiPKey)) return NO;
    SEL parentSel = NSSelectorFromString(@"parentResponder");
    id current = YTzoomShortsPiPOwner(controller);
    for (NSUInteger depth = 0; current != nil && depth < 10; depth++) {
        NSString *name = NSStringFromClass([current class]);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"] ||
            YTzoomPlayerIsShorts(current)) {
            return YES;
        }
        if (![current respondsToSelector:parentSel]) break;
        current = ((id (*)(id, SEL))objc_msgSend)(current, parentSel);
    }
    return NO;
}

static BOOL YTzoomShortsAllowed(id self, SEL _cmd) {
    if (YTzoomShortsBlocksPiP(self)) return NO;
    return ((BOOL (*)(id, SEL))YTzoomShortsOrigAllowed)(self, _cmd);
}

static BOOL YTzoomShortsEligible(id self, SEL _cmd) {
    if (YTzoomShortsBlocksPiP(self)) return NO;
    BOOL eligible = ((BOOL (*)(id, SEL))YTzoomShortsOrigEligible)(self, _cmd);
    if (!eligible && YTzoomFeatureEnabled(YTzoomBackgroundPlaybackKey)) return YES;
    return eligible;
}

static BOOL YTzoomShortsCanEnable(id self, SEL _cmd) {
    if (YTzoomShortsBlocksPiP(self)) return NO;
    return ((BOOL (*)(id, SEL))YTzoomShortsOrigCanEnable)(self, _cmd);
}

void YTzoomInstallShortsPiPHooks(void) {
    NSString *pipClass = @"YTPlayerPIPController";
    YTzoomInstallInstanceHook(pipClass, @"isPictureInPictureAllowed",
        (IMP)YTzoomShortsAllowed, &YTzoomShortsOrigAllowed);
    YTzoomInstallInstanceHook(pipClass, @"isEligibleForPictureInPicture",
        (IMP)YTzoomShortsEligible, &YTzoomShortsOrigEligible);
    YTzoomInstallInstanceHook(pipClass, @"canEnablePictureInPicture",
        (IMP)YTzoomShortsCanEnable, &YTzoomShortsOrigCanEnable);
}
