#import "../YTzoom.h"
#import "../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

static NSString *const YTzoomExtraDimKey = @"YTzoom.Preference.Appearance.ExtraDim";
static UIWindow *YTzoomDimWindow;

static UIWindowScene *YTzoomActiveScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)scene;
    }
    return nil;
}

static void YTzoomUpdateExtraDim(void) {
    double percent = YTzoomMasterEnabled() ? [YTzoomPreferenceObject(YTzoomExtraDimKey) doubleValue] : 0.0;
    CGFloat alpha = (CGFloat)MAX(0.0, MIN(85.0, percent)) / 100.0;
    if (alpha <= 0.001) {
        YTzoomDimWindow.hidden = YES;
        return;
    }
    UIWindowScene *scene = YTzoomActiveScene();
    if (scene == nil) return;
    if (YTzoomDimWindow == nil || YTzoomDimWindow.windowScene != scene) {
        YTzoomDimWindow = [[UIWindow alloc] initWithWindowScene:scene];
        YTzoomDimWindow.windowLevel = UIWindowLevelStatusBar + 100.0;
        YTzoomDimWindow.userInteractionEnabled = NO;
    }
    YTzoomDimWindow.backgroundColor = [UIColor colorWithWhite:0.0 alpha:alpha];
    YTzoomDimWindow.hidden = NO;
}

__attribute__((constructor)) static void YTzoomInstallExtraDim(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidBecomeActiveNotification,
                                       YTzoomPreferencesDidChangeNotification]) {
        [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            YTzoomUpdateExtraDim();
        }];
    }
}
