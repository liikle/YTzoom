#import "Assets.h"

#import <dlfcn.h>

static NSString *YTzoomLoadedImagePath(void) {
    Dl_info image;
    memset(&image, 0, sizeof(image));
    if (dladdr((const void *)&YTzoomAssetsBundle, &image) == 0) return nil;
    if (image.dli_fname == NULL) return nil;
    return [NSString stringWithUTF8String:image.dli_fname];
}

static NSArray<NSString *> *YTzoomCandidateBundlePaths(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *loaded = YTzoomLoadedImagePath();
    if (loaded.length != 0) {
        NSString *directory = loaded.stringByDeletingLastPathComponent;
        while (directory.length > 1) {
            [candidates addObject:
                [directory stringByAppendingPathComponent:@"YTzoom.bundle"]];
            if (candidates.count >= 2) break;
            directory = directory.stringByDeletingLastPathComponent;
        }
    }
    NSString *packaged = [NSBundle.mainBundle pathForResource:@"YTzoom"
                                                       ofType:@"bundle"];
    if (packaged.length != 0) [candidates addObject:packaged];
    return candidates;
}

NSBundle *YTzoomAssetsBundle(void) {
    static NSBundle *bundle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        for (NSString *path in YTzoomCandidateBundlePaths()) {
            BOOL directory = NO;
            if (![manager fileExistsAtPath:path isDirectory:&directory]) continue;
            if (!directory) continue;
            bundle = [NSBundle bundleWithPath:path];
            if (bundle != nil) break;
        }
    });
    return bundle;
}

UIImage *YTzoomAssetImage(NSString *name, NSString *fallbackSymbol) {
    UIImage *image = nil;
    NSBundle *bundle = YTzoomAssetsBundle();
    if (bundle != nil && name.length != 0) {
        image = [UIImage imageNamed:name
                           inBundle:bundle
      compatibleWithTraitCollection:nil];
    }
    if (image == nil && fallbackSymbol.length != 0) {
        if (@available(iOS 13.0, *)) {
            image = [UIImage systemImageNamed:fallbackSymbol];
        }
    }
    return image;
}

UIImage *YTzoomYouTubeImage(NSArray<NSString *> *names, NSString *fallbackSymbol) {
    for (NSString *name in names) {
        UIImage *image = [UIImage imageNamed:name];
        if (image != nil) return image;
    }
    return fallbackSymbol.length == 0 ? nil : [UIImage systemImageNamed:fallbackSymbol];
}

UIImage *YTzoomGearImage(void) {
    return YTzoomYouTubeImage(@[
        @"yt_outline_gear_24pt",
        @"yt_outline_gear_vd_theme_24",
        @"yt_outline_experimental_gear_vd_theme_24"
    ], @"gearshape");
}

UIImage *YTzoomShortsImage(BOOL selected) {
    return selected
        ? YTzoomYouTubeImage(@[
            @"yt_fill_youtube_shorts_24pt",
            @"yt_fill_youtube_shorts_vd_theme_24"
        ], @"play.rectangle.fill")
        : YTzoomYouTubeImage(@[
            @"yt_outline_youtube_shorts_24pt",
            @"yt_outline_youtube_shorts_vd_theme_24"
        ], @"play.rectangle");
}

UIImage *YTzoomDownloadTabImage(BOOL selected) {
    return [UIImage systemImageNamed:selected
        ? @"arrow.down.square.fill" : @"arrow.down.square"];
}

UIColor *YTzoomAccentColor(void) {
    return [UIColor colorWithRed:0.749 green:0.0 blue:0.075 alpha:1.0];
}
