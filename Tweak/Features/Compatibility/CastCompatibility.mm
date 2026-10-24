#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

static BOOL YTzoomCastYes(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YES;
}

static BOOL YTzoomCastNo(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return NO;
}

static NSInteger YTzoomCastAllowedStatus(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return 1;
}

static void YTzoomSkipLocalNetworkPage(id receiver,
                                       SEL selector,
                                       id completion) {
    (void)receiver;
    (void)selector;
    YTzoomDownloadLog(@"cast", @"permission page bypassed");
    YTzoomStartCastDiscovery();
    if (completion == nil) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            ((void (^)(BOOL))completion)(YES);
        } @catch (__unused NSException *exception) {
            YTzoomDownloadLog(@"cast", @"permission completion failed");
        }
    });
}

static void YTzoomRefreshCastHooks(void) {
    YTzoomInstallInstanceHook(@"MDXRoutePresentationController",
                              @"hasSufficientLocalNetworkPermissions",
                              (IMP)YTzoomCastYes,
                              NULL);
    YTzoomInstallInstanceHook(@"MDXLocalNetworkPermissions",
                              @"lastKnownPermissionsStatus",
                              (IMP)YTzoomCastAllowedStatus,
                              NULL);
    YTzoomInstallInstanceHook(@"MDXLocalNetworkPermissions",
                              @"isAuthorized",
                              (IMP)YTzoomCastYes,
                              NULL);
    YTzoomInstallInstanceHook(@"MDXLocalStorage",
                              @"localNetworkPermissionsStatus",
                              (IMP)YTzoomCastAllowedStatus,
                              NULL);
    YTzoomInstallInstanceHook(
        @"MDXPermissionsController",
        @"showLocalNetworkPermissionsRequiredPageWithCompletion:",
        (IMP)YTzoomSkipLocalNetworkPage,
        NULL
    );
    YTzoomInstallInstanceHook(@"CADPLocalNetworkPermissionInfo",
                              @"isLocalNetworkPermissionAllowed",
                              (IMP)YTzoomCastYes,
                              NULL);
    YTzoomInstallInstanceHook(@"CADPLocalNetworkPermissionInfo",
                              @"wasLocalNetworkPermissionAllowed",
                              (IMP)YTzoomCastYes,
                              NULL);
    YTzoomInstallInstanceHook(
        @"CADPLocalNetworkPermissionInfo",
        @"shouldPresentLocalNetworkAccessPermissionDialog",
        (IMP)YTzoomCastNo,
        NULL
    );
    YTzoomInstallInstanceHook(
        @"YTBAMediaHubUiDeviceItemsResult",
        @"shouldShowLocalNetworkPermissionPrompt",
        (IMP)YTzoomCastNo,
        NULL
    );
}

void YTzoomStartCastDiscovery(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            Class contextClass = NSClassFromString(@"GCKCastContext");
            SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
            if (contextClass == Nil ||
                ![contextClass respondsToSelector:sharedSelector]) {
                YTzoomDownloadLog(@"cast", @"context unavailable");
                return;
            }
            id context = ((id (*)(id, SEL))objc_msgSend)(contextClass,
                                                         sharedSelector);
            SEL managerSelector = NSSelectorFromString(@"discoveryManager");
            if (context == nil || ![context respondsToSelector:managerSelector]) {
                YTzoomDownloadLog(@"cast", @"manager unavailable");
                return;
            }
            id manager = ((id (*)(id, SEL))objc_msgSend)(context,
                                                         managerSelector);
            SEL startSelector = NSSelectorFromString(@"startDiscovery");
            if (manager != nil && [manager respondsToSelector:startSelector]) {
                ((void (*)(id, SEL))objc_msgSend)(manager, startSelector);
                YTzoomDownloadLog(@"cast", @"discovery started");
                dispatch_after(
                    dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                    dispatch_get_main_queue(), ^{
                        SEL countSelector = NSSelectorFromString(@"deviceCount");
                        if ([manager respondsToSelector:countSelector]) {
                            NSUInteger count = ((NSUInteger (*)(id, SEL))objc_msgSend)(
                                manager,
                                countSelector
                            );
                            YTzoomDownloadLog(@"cast", @"devices=%lu",
                                             (unsigned long)count);
                        }
                    }
                );
            }
        } @catch (__unused NSException *exception) {
            YTzoomDownloadLog(@"cast", @"discovery exception");
        }
    });
}

void YTzoomInstallCastCompatibilityHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomRefreshCastHooks();

        [NSNotificationCenter.defaultCenter
            addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *notification) {
                        YTzoomRefreshCastHooks();
                        YTzoomDownloadLog(@"cast", @"app active");
                    }];
    });
}
