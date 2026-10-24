#import "../../YTzoom.h"
#import "../Downloads/DownloadLog.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>

static IMP OriginalMealbarPromo;
static IMP OriginalPromosheet;
static IMP OriginalUpgradeDialog;
static IMP OriginalOldUpgradeDialog;
static IMP OriginalShouldShowUpgrade;
static IMP OriginalShouldShowUpgradeDialog;
static IMP OriginalYouTherePrompt;
static IMP OriginalThrottleInterstitial;

static BOOL YTzoomHidePromos(void) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Ads.PremiumPromosHidden");
}

static void YTzoomMealbarPromo(id receiver, SEL selector, id event) {
    if (!YTzoomHidePromos() && OriginalMealbarPromo != NULL) {
        ((void (*)(id, SEL, id))OriginalMealbarPromo)(receiver, selector, event);
    }
}

static void YTzoomPromosheet(id receiver, SEL selector, id event) {
    if (!YTzoomHidePromos() && OriginalPromosheet != NULL) {
        ((void (*)(id, SEL, id))OriginalPromosheet)(receiver, selector, event);
    }
}

static void YTzoomUpgradeDialog(id receiver, SEL selector) {
    if (!YTzoomHidePromos() && OriginalUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalUpgradeDialog)(receiver, selector);
    }
}

static void YTzoomOldUpgradeDialog(id receiver, SEL selector) {
    if (!YTzoomHidePromos() && OriginalOldUpgradeDialog != NULL) {
        ((void (*)(id, SEL))OriginalOldUpgradeDialog)(receiver, selector);
    }
}

static BOOL YTzoomShouldShowUpgrade(id receiver, SEL selector) {
    return YTzoomHidePromos() ? NO :
        (OriginalShouldShowUpgrade != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgrade)(receiver, selector));
}

static BOOL YTzoomShouldShowUpgradeDialog(id receiver, SEL selector) {
    return YTzoomHidePromos() ? NO :
        (OriginalShouldShowUpgradeDialog != NULL &&
         ((BOOL (*)(id, SEL))OriginalShouldShowUpgradeDialog)(receiver, selector));
}

static BOOL YTzoomShouldShowYouThere(id receiver, SEL selector) {
    return YTzoomHidePromos() ? NO :
        (OriginalYouTherePrompt != NULL &&
         ((BOOL (*)(id, SEL))OriginalYouTherePrompt)(receiver, selector));
}

static BOOL YTzoomInterstitialIsPromo(id command, NSString **outMatch) {
    if (command == nil) return NO;
    NSString *text = [[command description] lowercaseString];
    if (text.length == 0) return NO;
    if ([text containsString:@"post"] || [text containsString:@"image"] ||
        [text containsString:@"lightbox"] || [text containsString:@"attachment"]) {
        if (outMatch != NULL) *outMatch = @"post content";
        return NO;
    }
    for (NSString *marker in @[@"premium", @"upsell", @"mealbar",
                               @"promo_sheet", @"promosheet"]) {
        if ([text containsString:marker]) {
            if (outMatch != NULL) *outMatch = marker;
            return YES;
        }
    }
    return NO;
}

static BOOL YTzoomShouldThrottleInterstitial(id receiver, SEL selector) {
    if (YTzoomHidePromos()) {
        NSString *match = nil;
        BOOL promo = YTzoomInterstitialIsPromo(receiver, &match);
        if (promo) {
            return YES;
        }
    }
    return OriginalThrottleInterstitial != NULL &&
        ((BOOL (*)(id, SEL))OriginalThrottleInterstitial)(receiver, selector);
}

void YTzoomInstallPromoHooks(void) {
    YTzoomInstallInstanceHook(@"YTMealbarPromoController",
                              @"showMealbarPromoWithEvent:",
                              (IMP)YTzoomMealbarPromo,
                              &OriginalMealbarPromo);
    YTzoomInstallInstanceHook(@"YTPromosheetController",
                              @"presentPromosheetWithEvent:",
                              (IMP)YTzoomPromosheet,
                              &OriginalPromosheet);
    YTzoomInstallInstanceHook(@"YTUpgradeController", @"showUpgradeDialog",
                              (IMP)YTzoomUpgradeDialog,
                              &OriginalUpgradeDialog);
    YTzoomInstallInstanceHook(@"YTUpgradeController", @"showOldUpgradeDialog",
                              (IMP)YTzoomOldUpgradeDialog,
                              &OriginalOldUpgradeDialog);
    YTzoomInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgrade",
                              (IMP)YTzoomShouldShowUpgrade,
                              &OriginalShouldShowUpgrade);
    YTzoomInstallInstanceHook(@"YTGlobalConfig", @"shouldShowUpgradeDialog",
                              (IMP)YTzoomShouldShowUpgradeDialog,
                              &OriginalShouldShowUpgradeDialog);
    YTzoomInstallInstanceHook(@"YTYouThereControllerImpl",
                              @"shouldShowYouTherePrompt",
                              (IMP)YTzoomShouldShowYouThere,
                              &OriginalYouTherePrompt);
    YTzoomInstallInstanceHook(@"YTIShowFullscreenInterstitialCommand",
                              @"shouldThrottleInterstitial",
                              (IMP)YTzoomShouldThrottleInterstitial,
                              &OriginalThrottleInterstitial);
}
