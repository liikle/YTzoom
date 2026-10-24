#import "Preferences.h"
#import "Localization.h"
#import "../Features/Downloads/SABRDownloader.h"

#import <UIKit/UIKit.h>

NSString * const YTzoomMasterEnabledKey = @"YTzoom.Preference.Enabled";
NSString * const YTzoomOLEDKey = @"YTzoom.Preference.Appearance.OLED";
NSString * const YTzoomNoAdsKey = @"YTzoom.Preference.Ads.Blocking";
NSString * const YTzoomSponsorBlockKey = @"YTzoom.Preference.SponsorBlock.Enabled";
NSString * const YTzoomDownloadKey = @"YTzoom.Preference.Downloads.Enabled";
NSString * const YTzoomBackgroundPlaybackKey = @"YTzoom.Preference.Playback.BackgroundAudio";
NSString * const YTzoomPiPKey = @"YTzoom.Preference.Player.PiP";
NSString * const YTzoomSpeedKey = @"YTzoom.Preference.Player.SpeedControls";
NSString * const YTzoomLoopKey = @"YTzoom.Preference.Player.Loop";
NSString * const YTzoomSleepTimerKey = @"YTzoom.Preference.Player.SleepTimer";
NSString * const YTzoomPreferencesDidChangeNotification =
    @"YTzoomPreferencesDidChangeNotification";

static NSUserDefaults *YTzoomDefaults(void) {
    return NSUserDefaults.standardUserDefaults;
}

static void YTzoomAnnouncePreferenceChange(NSString *key) {
    if (key.length == 0) return;
    if ([key isEqualToString:@"YTzoom.Preference.Language"]) {
        YTzoomResetLocalizationCache();
    }
    void (^post)(void) = ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTzoomPreferencesDidChangeNotification
                          object:nil
                        userInfo:@{@"key": key}];
    };
    if (NSThread.isMainThread) {
        post();
    } else {
        dispatch_async(dispatch_get_main_queue(), post);
    }
}

static id YTzoomRenameLegacyValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        return [value isEqualToString:@"ytkace"] ? @"ytzoom" : value;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *values = [NSMutableArray array];
        for (id entry in (NSArray *)value) [values addObject:YTzoomRenameLegacyValue(entry)];
        return values;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        [(NSDictionary *)value enumerateKeysAndObjectsUsingBlock:^(id key, id entry, BOOL *stop) {
            (void)stop;
            values[YTzoomRenameLegacyValue(key)] = YTzoomRenameLegacyValue(entry);
        }];
        return values;
    }
    return value;
}

// Settings saved before the rename use the YTKACE prefix. Copy them over once.
static void YTzoomMigrateLegacyPreferences(void) {
    NSUserDefaults *defaults = YTzoomDefaults();
    if ([defaults boolForKey:@"YTzoom.Migration.LegacyPreferences"]) return;
    NSDictionary<NSString *, id> *stored = defaults.dictionaryRepresentation;
    for (NSString *key in stored) {
        if (![key hasPrefix:@"YTKACE."]) continue;
        NSString *renamed = [@"YTzoom." stringByAppendingString:[key substringFromIndex:7]];
        renamed = [renamed stringByReplacingOccurrencesOfString:@"YTKACE" withString:@"YTzoom"];
        if ([defaults objectForKey:renamed] == nil) {
            [defaults setObject:YTzoomRenameLegacyValue(stored[key]) forKey:renamed];
        }
        [defaults removeObjectForKey:key];
    }
    [defaults setBool:YES forKey:@"YTzoom.Migration.LegacyPreferences"];
}

void YTzoomRegisterDefaults(void) {
    YTzoomMigrateLegacyPreferences();
    id legacyBrightnessSide = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Gestures.BrightnessSide"];
    id legacyVolumeSide = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Gestures.VolumeSide"];
    BOOL hasLeftAction = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Gestures.LeftAction"] != nil;
    BOOL hasRightAction = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Gestures.RightAction"] != nil;
    id legacyDownloadButton = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Downloads.Enabled"];
    BOOL hasPlacement = [YTzoomDefaults()
        objectForKey:@"YTzoom.Preference.Downloads.Placement"] != nil;
    [YTzoomDefaults() registerDefaults:@{
        YTzoomMasterEnabledKey: @YES,
        YTzoomNoAdsKey: @YES,
        YTzoomOLEDKey: @NO,
        YTzoomDownloadKey: @NO,
        YTzoomBackgroundPlaybackKey: @YES,
        YTzoomPiPKey: @NO,
        YTzoomSpeedKey: @NO,
        YTzoomLoopKey: @NO,
        @"YTzoom.Preference.Playback.CustomDoubleTap": @NO,
        @"YTzoom.Preference.Playback.TapToSeek": @NO,
        @"YTzoom.Preference.Sharing.NativeSheet": @NO,
        @"YTzoom.Preference.Playback.OpenPaused": @NO,
        @"YTzoom.Preference.Playback.Transcript": @NO,
        @"YTzoom.Preference.Downloads.Subtitles": @NO,
        @"YTzoom.Preference.Playback.CaptionLanguage": @"",
        @"YTzoom.Preference.Shorts.PinchFullscreen": @NO,
        @"YTzoom.Preference.Shorts.InvisibleStickers": @NO,
        @"YTzoom.Preference.Shorts.StickerMaxScale": @0,
        @"YTzoom.Preference.Shorts.UnlimitedStickers": @NO,
        @"YTzoom.Preference.Shorts.LongerPolls": @NO,
        @"YTzoom.Preference.Shorts.PollOptions": @0,
        @"YTzoom.Preference.Shorts.StickerFontName": @"",
        @"YTzoom.Preference.Shorts.StickerFontFile": @"",
        @"YTzoom.Preference.Shorts.RemixHidden": @NO,
        @"YTzoom.Preference.Shorts.ShareHidden": @NO,
        @"YTzoom.Preference.Shorts.SaveHidden": @NO,
        @"YTzoom.Preference.Downloads.PlaylistEnabled": @NO,
        @"YTzoom.Preference.Downloads.Placement": @0,
        @"YTzoom.Preference.Shorts.CommentsHidden": @NO,
        @"YTzoom.Preference.Shorts.LikeHidden": @NO,
        @"YTzoom.Preference.Shorts.SoundHidden": @NO,
        @"YTzoom.Preference.Shorts.DownloadPosition": @0,
        @"YTzoom.Preference.Overlay.ProductsHidden": @NO,
        @"YTzoom.Preference.Feed.CommunityPostsHidden": @NO,
        @"YTzoom.Preference.Feed.HorizontalShelvesHidden": @NO,
        @"YTzoom.Preference.Feed.MixesHidden": @NO,
        @"YTzoom.Preference.Feed.PlayablesHidden": @NO,
        @"YTzoom.Preference.Navigation.MessagesHidden": @NO,
        @"YTzoom.Preference.ActionBar.LikeHidden": @NO,
        @"YTzoom.Preference.ActionBar.DislikeHidden": @NO,
        @"YTzoom.Preference.ActionBar.ShareHidden": @NO,
        @"YTzoom.Preference.ActionBar.DownloadHidden": @NO,
        @"YTzoom.Preference.ActionBar.SaveHidden": @NO,
        @"YTzoom.Preference.ActionBar.ClipHidden": @NO,
        @"YTzoom.Preference.ActionBar.RemixHidden": @NO,
        @"YTzoom.Preference.ActionBar.ThanksHidden": @NO,
        @"YTzoom.Preference.ActionBar.HypeHidden": @NO,
        @"YTzoom.Preference.ActionBar.ReportHidden": @NO,
        @"YTzoom.Preference.ActionBar.AskHidden": @NO,
        @"YTzoom.Preference.ActionBar.OverflowHidden": @NO,
        @"YTzoom.Preference.Overlay.FullscreenActionsHidden": @NO,
        @"YTzoom.Preference.Player.HoldSpeedEnabled": @NO,
        @"YTzoom.Preference.Player.HoldSpeedRate": @2.0,
        @"YTzoom.Preference.Gestures.LandscapeOnly": @NO,
        @"YTzoom.Preference.Profiles.Preview": @YES,
        @"YTzoom.Preference.Posts.SaveImage": @YES,
        @"YTzoom.Preference.Downloads.SaveLocation": @0,
        @"YTzoom.Preference.Appearance.LaunchAnimationDisabled": @NO,
        @"YTzoom.Preference.Player.StartRate": @0,
        @"YTzoom.Preference.Player.CustomRate": @1.5,
        @"YTzoom.Preference.Playback.DoubleTapSeconds": @10.0,
        @"YTzoom.Preference.Gestures.HoldSeekSeconds": @10.0,
        @"YTzoom.Preference.Gestures.VolumeSide": @2,
        @"YTzoom.Preference.Gestures.BrightnessSide": @2,
        @"YTzoom.Preference.Gestures.Enabled": @NO,
        @"YTzoom.Preference.Gestures.ActivationArea": @20.0,
        @"YTzoom.Preference.Gestures.LeftAction": @0,
        @"YTzoom.Preference.Gestures.RightAction": @0,
        @"YTzoom.Preference.Gestures.HUDEnabled": @YES,
        @"YTzoom.Preference.Gestures.HUDSize": @1,
        @"YTzoom.Preference.Gestures.HUDPosition": @0,
        @"YTzoom.Preference.Tabs.Startup": @"",
        @"YTzoom.Preference.Feed.HomeTabsHidden": @NO,
        @"YTzoom.Preference.Shorts.LimitEnabled": @NO,
        @"YTzoom.Preference.Playback.HLSMode": @NO,
        @"YTzoom.Preference.Playback.Fix": @NO,
        @"YTzoom.Preference.Shorts.LimitCount": @20,
        @"YTzoom.Preference.Tabs.FrostedHidden": @NO,
        @"YTzoom.Preference.Tabs.GlassMinimize": @NO,
        @"YTzoom.Preference.Tabs.SelectedTint": @0,
        @"YTzoom.Preference.Glass.Menus": @NO,
        @"YTzoom.Preference.Glass.Notices": @NO,
        @"YTzoom.Preference.Glass.Player": @NO,
        @"YTzoom.Preference.Playback.WiFiQuality": @0,
        @"YTzoom.Preference.Playback.CellularQuality": @0,
        @"YTzoom.Preference.SponsorBlock.Mode": @0,
        @"YTzoom.Preference.SponsorBlock.SkipAlertSeconds": @4.0,
        @"YTzoom.Preference.SponsorBlock.UnskipAlertSeconds": @4.0,
        @"YTzoom.Preference.Downloads.ClearOnStartup": @NO,
        @"YTzoom.Preference.Tabs.Hidden.Create": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Music": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Live": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Gaming": @YES,
        @"YTzoom.Preference.Tabs.Hidden.News": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Posts": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Sports": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Learning": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Fashion": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Playlists": @YES,
        @"YTzoom.Preference.Tabs.Hidden.History": @YES,
        @"YTzoom.Preference.Tabs.Hidden.Notifs": @YES,
        @"YTzoom.Preference.Tabs.Hidden.WatchLater": @YES,
        @"YTzoom.Preference.AITitles.Enabled": @NO,
        @"YTzoom.Preference.AITitles.Placement": @0,
        @"YTzoom.Preference.Region.Country": @"",
        @"YTzoom.Preference.Mosh.Enabled": @YES,
        @"YTzoom.Preference.Mosh.Active": @YES,
        @"YTzoom.Preference.Mosh.UltraWide": @NO,
        @"YTzoom.Preference.Mosh.Stabilization": @NO,
        @"YTzoom.Preference.Mosh.HighFrameRate": @YES,
        @"YTzoom.Preference.Mosh.Ghost": @YES,
        @"YTzoom.Preference.Upload.HoldAllButton": @YES,
        @"YTzoom.Preference.Upload.HoldAllText": @"",
        @"YTzoom.Preference.Region.Language": @YES,
        @"YTzoom.Preference.Region.TimeZone": @YES,
        @"YTzoom.Preference.Region.Locale": @YES,
        @"YTzoom.Preference.Tabs.Order": @[@"home", @"shorts", @"subscriptions", @"library", @"ytzoom"]
    }];
    if (!hasPlacement && [legacyDownloadButton boolValue]) {
        [YTzoomDefaults() setInteger:1
                              forKey:@"YTzoom.Preference.Downloads.Placement"];
    }
    if ((!hasLeftAction || !hasRightAction) &&
        (legacyBrightnessSide != nil || legacyVolumeSide != nil)) {
        NSInteger brightness = legacyBrightnessSide != nil
            ? [legacyBrightnessSide integerValue] : 2;
        NSInteger volume = legacyVolumeSide != nil
            ? [legacyVolumeSide integerValue] : 2;
        BOOL leftBrightness = brightness == 1;
        BOOL rightBrightness = brightness == 0;
        BOOL leftVolume = volume == 1 || volume == 3;
        BOOL rightVolume = volume == 0 || volume == 3;
        NSInteger leftAction = leftBrightness && leftVolume
            ? 3 : (leftVolume ? 2 : (leftBrightness ? 1 : 0));
        NSInteger rightAction = rightBrightness && rightVolume
            ? 3 : (rightVolume ? 2 : (rightBrightness ? 1 : 0));
        if (!hasLeftAction) {
            [YTzoomDefaults() setInteger:leftAction
                                  forKey:@"YTzoom.Preference.Gestures.LeftAction"];
        }
        if (!hasRightAction) {
            [YTzoomDefaults() setInteger:rightAction
                                   forKey:@"YTzoom.Preference.Gestures.RightAction"];
        }
    }
    [YTzoomDefaults() setBool:YES forKey:YTzoomMasterEnabledKey];
    if ([YTzoomDefaults() objectForKey:@"YTzoom.Preference.Shorts.ProductsHidden"] != nil) {
        if ([YTzoomDefaults() boolForKey:@"YTzoom.Preference.Shorts.ProductsHidden"]) {
            [YTzoomDefaults() setBool:YES
                               forKey:@"YTzoom.Preference.Overlay.ProductsHidden"];
        }
        [YTzoomDefaults() removeObjectForKey:@"YTzoom.Preference.Shorts.ProductsHidden"];
    }
    if ([YTzoomDefaults() boolForKey:@"YTzoom.Preference.Downloads.ClearOnStartup"]) {
        NSDate *lastClear = [YTzoomDefaults() objectForKey:@"YTzoom.Preference.Downloads.LastCacheClear"];
        if (![lastClear isKindOfClass:NSDate.class] ||
            -lastClear.timeIntervalSinceNow >= 86400.0) {
            NSURL *cache = [YTzoomApplicationSupportDirectory()
                URLByAppendingPathComponent:@"Cache"
                                isDirectory:YES];
            [NSFileManager.defaultManager removeItemAtURL:cache error:nil];
            YTzoomPurgeSystemCaches();
            [YTzoomDefaults() setObject:NSDate.date
                                 forKey:@"YTzoom.Preference.Downloads.LastCacheClear"];
        }
    }
    YTzoomPurgeDownloadScratch(NO);
}

NSInteger YTzoomDownloadPlacement(void) {
    return [YTzoomDefaults() integerForKey:@"YTzoom.Preference.Downloads.Placement"];
}

BOOL YTzoomDownloadsEnabled(void) {
    return YTzoomDownloadPlacement() != 0;
}

BOOL YTzoomMasterEnabled(void) {
    return YES;
}

BOOL YTzoomFeatureEnabled(NSString *key) {
    if (!YTzoomMasterEnabled() || key.length == 0) {
        return NO;
    }
    return [YTzoomDefaults() boolForKey:key];
}

BOOL YTzoomOLEDActive(UITraitCollection *traits) {
    if (!YTzoomFeatureEnabled(YTzoomOLEDKey)) {
        return NO;
    }
    UITraitCollection *current = traits;
    if (current == nil) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class] ||
                scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    current = window.traitCollection;
                    break;
                }
            }
            if (current != nil) break;
        }
    }
    current = current ?: UIScreen.mainScreen.traitCollection;
    return current.userInterfaceStyle == UIUserInterfaceStyleDark;
}

UIColor *YTzoomInterfaceBackgroundColor(UITraitCollection *traits) {
    if (YTzoomOLEDActive(traits)) return UIColor.blackColor;
    UIUserInterfaceStyle style = traits.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return style == UIUserInterfaceStyleDark
        ? [UIColor colorWithWhite:0.075 alpha:1.0]
        : UIColor.whiteColor;
}

UIColor *YTzoomInterfaceSurfaceColor(UITraitCollection *traits) {
    if (YTzoomOLEDActive(traits)) {
        return UIColor.blackColor;
    }
    UIUserInterfaceStyle style = traits.userInterfaceStyle;
    if (style == UIUserInterfaceStyleUnspecified) {
        style = UIScreen.mainScreen.traitCollection.userInterfaceStyle;
    }
    return style == UIUserInterfaceStyleDark
        ? [UIColor colorWithWhite:0.16 alpha:1.0]
        : [UIColor colorWithWhite:0.95 alpha:1.0];
}

BOOL YTzoomSponsorBlockEnabled(void) {
    if (!YTzoomMasterEnabled()) {
        return NO;
    }

    return [YTzoomDefaults() boolForKey:YTzoomSponsorBlockKey];
}

void YTzoomSetPreference(NSString *key, BOOL enabled) {
    if (key.length == 0) {
        return;
    }

    if ([key isEqualToString:YTzoomMasterEnabledKey]) {
        [YTzoomDefaults() setBool:YES forKey:key];
        YTzoomAnnouncePreferenceChange(key);
        return;
    }
    [YTzoomDefaults() setBool:enabled forKey:key];
    YTzoomAnnouncePreferenceChange(key);
}

id YTzoomPreferenceObject(NSString *key) {
    if (key.length == 0) {
        return nil;
    }
    return [YTzoomDefaults() objectForKey:key];
}

void YTzoomSetPreferenceObject(NSString *key, id value) {
    if (key.length == 0) {
        return;
    }
    if (value == nil) {
        [YTzoomDefaults() removeObjectForKey:key];
    } else {
        [YTzoomDefaults() setObject:value forKey:key];
    }
    YTzoomAnnouncePreferenceChange(key);
}

static NSString *YTzoomRelativeStoragePath(NSURL *URL, NSURL *baseURL) {
    NSString *path = URL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *base = baseURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *prefix = [base stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    return [path substringFromIndex:prefix.length];
}

static void YTzoomRepairDownloads(NSURL *root) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *downloads = [root URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSArray<NSURL *> *items = [[manager enumeratorAtURL:downloads
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                           options:0 errorHandler:nil] allObjects];
    for (NSURL *source in items) {
        NSNumber *directory = nil;
        [source getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue) continue;
        NSString *relative = YTzoomRelativeStoragePath(source, downloads);
        NSArray<NSString *> *components = relative.pathComponents;
        NSUInteger categoryIndex = NSNotFound;
        NSString *category = nil;
        for (NSUInteger index = 0; index < components.count; index++) {
            for (NSString *candidate in @[@"Video", @"Audio", @"Shorts"]) {
                if ([components[index] caseInsensitiveCompare:candidate] == NSOrderedSame) {
                    categoryIndex = index;
                    category = candidate;
                    break;
                }
            }
            if (categoryIndex != NSNotFound) break;
        }
        if (categoryIndex == NSNotFound || categoryIndex + 1 >= components.count) continue;
        NSURL *target = [downloads URLByAppendingPathComponent:category isDirectory:YES];
        for (NSUInteger index = categoryIndex + 1; index < components.count; index++) {
            target = [target URLByAppendingPathComponent:components[index]];
        }
        if ([source.URLByResolvingSymlinksInPath.path
                isEqualToString:target.URLByResolvingSymlinksInPath.path]) continue;
        [manager createDirectoryAtURL:target.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        if ([manager fileExistsAtPath:target.path]) {
            [manager removeItemAtURL:source error:nil];
        } else {
            [manager moveItemAtURL:source toURL:target error:nil];
        }
    }
    for (NSString *name in @[@"Downloads", @"ownloads"]) {
        [manager removeItemAtURL:[downloads URLByAppendingPathComponent:name isDirectory:YES]
                           error:nil];
    }
}

NSUInteger YTzoomPurgeSystemCaches(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSArray<NSURL *> *roots = [manager URLsForDirectory:NSCachesDirectory
                                             inDomains:NSUserDomainMask];
    NSUInteger freed = 0;
    for (NSURL *root in roots) {
        NSArray<NSURL *> *entries = [manager contentsOfDirectoryAtURL:root
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 error:nil];
        for (NSURL *entry in entries) {
            NSDirectoryEnumerator *walker = [manager enumeratorAtURL:entry
                includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                                   options:0 errorHandler:nil];
            NSNumber *own = nil;
            [entry getResourceValue:&own forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            freed += own.unsignedIntegerValue;
            for (NSURL *child in walker) {
                NSNumber *size = nil;
                [child getResourceValue:&size
                                 forKey:NSURLTotalFileAllocatedSizeKey error:nil];
                freed += size.unsignedIntegerValue;
            }
            [manager removeItemAtURL:entry error:nil];
        }
    }
    return freed;
}

NSURL *YTzoomApplicationSupportDirectory(void) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *documents = [manager URLsForDirectory:NSDocumentDirectory
                                        inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [documents URLByAppendingPathComponent:@"YTzoom"
                                                   isDirectory:YES];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *support = [manager URLsForDirectory:NSApplicationSupportDirectory
                                         inDomains:NSUserDomainMask].firstObject;
        // Folders from older builds, including the ones made before the YTzoom rename.
        NSArray<NSURL *> *legacyFolders = @[
            [documents URLByAppendingPathComponent:@"YTKACE" isDirectory:YES],
            [support URLByAppendingPathComponent:@"YTKACE" isDirectory:YES],
            [support URLByAppendingPathComponent:@"YTzoom" isDirectory:YES]
        ];
        for (NSURL *legacy in legacyFolders) {
            BOOL targetExists = [manager fileExistsAtPath:directory.path];
            if (!targetExists && [manager fileExistsAtPath:legacy.path]) {
                [manager moveItemAtURL:legacy toURL:directory error:nil];
            }
        }
        [manager createDirectoryAtURL:directory
          withIntermediateDirectories:YES
                           attributes:nil
                                error:nil];
        for (NSURL *legacy in legacyFolders) {
            if (![manager fileExistsAtPath:legacy.path]) continue;
            NSDirectoryEnumerator<NSURL *> *items = [manager
                enumeratorAtURL:legacy
     includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                        options:0
                   errorHandler:nil];
            for (NSURL *source in items) {
                NSString *relative = YTzoomRelativeStoragePath(source, legacy);
                if (relative.length == 0) continue;
                NSURL *destination = [directory URLByAppendingPathComponent:relative];
                NSNumber *isDirectory = nil;
                [source getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
                if (isDirectory.boolValue) {
                    [manager createDirectoryAtURL:destination
                      withIntermediateDirectories:YES attributes:nil error:nil];
                } else if (![manager fileExistsAtPath:destination.path]) {
                    [manager createDirectoryAtURL:destination.URLByDeletingLastPathComponent
                      withIntermediateDirectories:YES attributes:nil error:nil];
                    [manager moveItemAtURL:source toURL:destination error:nil];
                }
            }
            [manager removeItemAtURL:legacy error:nil];
        }
        YTzoomRepairDownloads(directory);
    });
    return directory;
}
