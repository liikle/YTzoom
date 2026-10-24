#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTzoomYouTubeIdentifier = @"com.google.ios.youtube";
static NSString * const YTzoomYouTubeName = @"YouTube";

static IMP OriginalBundleWithIdentifier;
static IMP OriginalBundleIdentifier;
static IMP OriginalInfoDictionary;
static IMP OriginalInfoValue;
static IMP OriginalSSOSetTemporary;
static IMP OriginalSSOConfigurationInit;
static IMP OriginalGroupContainerURL;
static IMP OriginalApplicationSetDelegate;

static BOOL YTzoomIsSideloaded(void) {
    NSURL *receiptURL = NSBundle.mainBundle.appStoreReceiptURL;
    NSString *path = receiptURL.path;
    return path.length == 0 ||
        ![NSFileManager.defaultManager fileExistsAtPath:path];
}

static NSString *YTzoomCurrentAccessGroup(void) {
    static NSString *accessGroup;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrAccount: @"YTzoomDummyItem",
            (__bridge id)kSecAttrService: @"YTzoomDummyService",
            (__bridge id)kSecReturnAttributes: @YES
        };
        CFTypeRef result = NULL;
        OSStatus status = SecItemCopyMatching(
            (__bridge CFDictionaryRef)query,
            &result
        );
        if (status == errSecItemNotFound) {
            status = SecItemAdd((__bridge CFDictionaryRef)query, &result);
        }
        if (status == errSecDuplicateItem) {
            status = SecItemCopyMatching(
                (__bridge CFDictionaryRef)query,
                &result
            );
        }
        if (status == errSecSuccess && result != NULL) {
            NSDictionary *attributes = CFBridgingRelease(result);
            id value = attributes[(__bridge id)kSecAttrAccessGroup];
            if ([value isKindOfClass:NSString.class]) {
                accessGroup = [value copy];
            }
        } else if (result != NULL) {
            CFRelease(result);
        }
    });
    return accessGroup;
}

static NSString *YTzoomAccessGroup(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YTzoomCurrentAccessGroup();
}

static NSBundle *YTzoomBundleWithIdentifier(id receiver,
                                            SEL selector,
                                            NSString *identifier) {
    if ([identifier isEqualToString:YTzoomYouTubeIdentifier]) {
        return NSBundle.mainBundle;
    }
    return OriginalBundleWithIdentifier == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalBundleWithIdentifier)(
            receiver, selector, identifier
        );
}

static NSString *YTzoomBundleIdentifier(NSBundle *receiver, SEL selector) {
    if (receiver == NSBundle.mainBundle) {
        return YTzoomYouTubeIdentifier;
    }
    return OriginalBundleIdentifier == NULL
        ? nil
        : ((id (*)(id, SEL))OriginalBundleIdentifier)(receiver, selector);
}

static NSDictionary *YTzoomInfoDictionary(NSBundle *receiver, SEL selector) {
    NSDictionary *info = OriginalInfoDictionary == NULL
        ? nil
        : ((id (*)(id, SEL))OriginalInfoDictionary)(receiver, selector);
    if (receiver != NSBundle.mainBundle || info == nil) {
        return info;
    }
    NSMutableDictionary *updated = [info mutableCopy];
    updated[@"CFBundleIdentifier"] = YTzoomYouTubeIdentifier;
    updated[@"CFBundleDisplayName"] = YTzoomYouTubeName;
    updated[@"CFBundleName"] = YTzoomYouTubeName;
    return [updated copy];
}

static id YTzoomInfoValue(NSBundle *receiver,
                          SEL selector,
                          NSString *key) {
    if (receiver == NSBundle.mainBundle) {
        if ([key isEqualToString:@"CFBundleIdentifier"]) {
            return YTzoomYouTubeIdentifier;
        }
        if ([key isEqualToString:@"CFBundleDisplayName"] ||
            [key isEqualToString:@"CFBundleName"]) {
            return YTzoomYouTubeName;
        }
    }
    return OriginalInfoValue == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalInfoValue)(receiver, selector, key);
}

static BOOL YTzoomTrue(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YES;
}

static BOOL YTzoomFalse(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return NO;
}

static NSString *YTzoomAppName(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YTzoomYouTubeName;
}

static NSString *YTzoomAppIdentifier(id receiver, SEL selector) {
    (void)receiver;
    (void)selector;
    return YTzoomYouTubeIdentifier;
}

static void YTzoomSetTemporaryDisabled(id receiver,
                                       SEL selector,
                                       BOOL disabled) {
    (void)disabled;
    if (OriginalSSOSetTemporary != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalSSOSetTemporary)(
            receiver, selector, NO
        );
    }
}

static id YTzoomConfigurationInit(id receiver,
                                  SEL selector,
                                  id clientID,
                                  id services) {
    id value = OriginalSSOConfigurationInit == NULL
        ? receiver
        : ((id (*)(id, SEL, id, id))OriginalSSOConfigurationInit)(
            receiver, selector, clientID, services
        );
    if (value != nil) {
        @try {
            [value setValue:YTzoomYouTubeName forKey:@"_shortAppName"];
            [value setValue:YTzoomYouTubeIdentifier
                     forKey:@"_applicationIdentifier"];
        } @catch (__unused NSException *exception) {
        }
    }
    return value;
}

static NSURL *YTzoomGroupContainerURL(NSFileManager *receiver,
                                      SEL selector,
                                      NSString *identifier) {
    NSURL *original = OriginalGroupContainerURL == NULL
        ? nil
        : ((id (*)(id, SEL, id))OriginalGroupContainerURL)(
            receiver, selector, identifier
        );
    if (original != nil || ![identifier containsString:@"group."]) {
        return original;
    }
    NSURL *support = [[receiver URLsForDirectory:NSApplicationSupportDirectory
                                        inDomains:NSUserDomainMask] lastObject];
    if (support == nil) {
        return nil;
    }
    NSURL *fallback = [support URLByAppendingPathComponent:@"AppGroup"
                                               isDirectory:YES];
    [receiver createDirectoryAtURL:fallback
       withIntermediateDirectories:YES
                        attributes:nil
                             error:nil];
    return fallback;
}

static BOOL YTzoomApplicationOpenURL(id receiver,
                                     SEL selector,
                                     UIApplication *application,
                                     NSURL *URL,
                                     NSDictionary *options) {
    (void)selector;
    SEL legacy = NSSelectorFromString(
        @"application:openURL:sourceApplication:annotation:"
    );
    if ([receiver respondsToSelector:legacy]) {
        id source = options[UIApplicationOpenURLOptionsSourceApplicationKey];
        id annotation = options[UIApplicationOpenURLOptionsAnnotationKey];
        return ((BOOL (*)(id, SEL, id, id, id, id))objc_msgSend)(
            receiver,
            legacy,
            application,
            URL,
            source,
            annotation
        );
    }
    SEL older = NSSelectorFromString(@"application:handleOpenURL:");
    if ([receiver respondsToSelector:older]) {
        return ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
            receiver,
            older,
            application,
            URL
        );
    }
    return NO;
}

static void YTzoomApplicationSetDelegate(UIApplication *receiver,
                                         SEL selector,
                                         id delegate) {
    if (delegate != nil &&
        [NSBundle.mainBundle objectForInfoDictionaryKey:
            @"LSSupportsOpeningDocumentsInPlace"] != nil) {
        SEL openSelector = NSSelectorFromString(@"application:openURL:options:");
        Class delegateClass = object_getClass(delegate);
        if (class_getInstanceMethod(delegateClass, openSelector) == NULL) {
            class_addMethod(delegateClass,
                            openSelector,
                            (IMP)YTzoomApplicationOpenURL,
                            "B@:@@@");
        }
    }
    if (OriginalApplicationSetDelegate != NULL) {
        ((void (*)(id, SEL, id))OriginalApplicationSetDelegate)(
            receiver,
            selector,
            delegate
        );
    }
}

void YTzoomInstallSideloadCompatibilityHooks(void) {
    if (!YTzoomIsSideloaded()) {
        return;
    }
    YTzoomCurrentAccessGroup();

    YTzoomInstallInstanceHook(@"UIApplication", @"setDelegate:",
                              (IMP)YTzoomApplicationSetDelegate,
                              &OriginalApplicationSetDelegate);

    NSString *realIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if (![realIdentifier isEqualToString:YTzoomYouTubeIdentifier]) {
        YTzoomInstallClassHook(@"NSBundle", @"bundleWithIdentifier:",
                               (IMP)YTzoomBundleWithIdentifier,
                               &OriginalBundleWithIdentifier);
        YTzoomInstallInstanceHook(@"NSBundle", @"bundleIdentifier",
                                  (IMP)YTzoomBundleIdentifier,
                                  &OriginalBundleIdentifier);
        YTzoomInstallInstanceHook(@"NSBundle", @"infoDictionary",
                                  (IMP)YTzoomInfoDictionary,
                                  &OriginalInfoDictionary);
        YTzoomInstallInstanceHook(@"NSBundle", @"objectForInfoDictionaryKey:",
                                  (IMP)YTzoomInfoValue,
                                  &OriginalInfoValue);
    }

    YTzoomInstallClassHook(@"YTVersionUtils", @"appName",
                           (IMP)YTzoomAppName, NULL);
    YTzoomInstallClassHook(@"YTVersionUtils", @"appID",
                           (IMP)YTzoomAppIdentifier, NULL);
    YTzoomInstallInstanceHook(@"SSOConfiguration", @"shouldEnableSafariSignIn",
                              (IMP)YTzoomTrue, NULL);
    YTzoomInstallInstanceHook(@"SSOConfiguration", @"temporarilyDisableSafariSignIn",
                              (IMP)YTzoomFalse, NULL);
    YTzoomInstallInstanceHook(@"SSOConfiguration", @"setTemporarilyDisableSafariSignIn:",
                              (IMP)YTzoomSetTemporaryDisabled,
                              &OriginalSSOSetTemporary);
    YTzoomInstallInstanceHook(@"SSOConfiguration",
                              @"initWithClientID:supportedAccountServices:",
                              (IMP)YTzoomConfigurationInit,
                              &OriginalSSOConfigurationInit);

    YTzoomInstallClassHook(@"SSOKeychainHelper", @"accessGroup",
                           (IMP)YTzoomAccessGroup, NULL);
    YTzoomInstallClassHook(@"SSOKeychainHelper", @"sharedAccessGroup",
                           (IMP)YTzoomAccessGroup, NULL);
    YTzoomInstallClassHook(@"SSOKeychainCore", @"accessGroup",
                           (IMP)YTzoomAccessGroup, NULL);
    YTzoomInstallClassHook(@"SSOKeychainCore", @"sharedAccessGroup",
                           (IMP)YTzoomAccessGroup, NULL);
    YTzoomInstallInstanceHook(@"UICKeyChainStore", @"accessGroup",
                              (IMP)YTzoomAccessGroup, NULL);

    YTzoomInstallInstanceHook(@"NSFileManager",
                              @"containerURLForSecurityApplicationGroupIdentifier:",
                              (IMP)YTzoomGroupContainerURL,
                              &OriginalGroupContainerURL);
    YTzoomInstallClassHook(@"GULAppEnvironmentUtil", @"isFromAppStore",
                           (IMP)YTzoomTrue, NULL);
    YTzoomInstallClassHook(@"APMAEU", @"isFAS",
                           (IMP)YTzoomTrue, NULL);
    YTzoomInstallClassHook(@"SSOClientLogin", @"defaultSourceString",
                           (IMP)YTzoomAppIdentifier, NULL);
}
