#import "../Downloads/DownloadLog.h"
#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTzoomProgressStyleKey = @"YTzoom.Preference.Progress.Style";
static NSString * const YTzoomProgressMainColorKey = @"YTzoom.Preference.Progress.MainColor";
static NSString * const YTzoomProgressGradientColorKey = @"YTzoom.Preference.Progress.HighlightColor";
static NSString * const YTzoomProgressScrubberColorKey = @"YTzoom.Preference.Progress.ScrubberColor";

static IMP OriginalDecorationViewColor;
static IMP OriginalDecorationControllerColor;
static IMP OriginalContainerQuietColor;
static IMP OriginalScrubberDotColorV1;
static IMP OriginalScrubberDotColorV2;
static IMP OriginalSetScrubberDotColor;
static IMP OriginalSetScrubberDotColorV1;
static IMP OriginalSetScrubberDotColorV2;

static UIColor *YTzoomProgressColorFromHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:NSString.class]) return fallback;
    NSString *value = [[hex stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet]
        stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (value.length != 6) return fallback;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:value] scanHexInt:&rgb]) return fallback;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSInteger YTzoomStyleCache = -1;
static NSMutableDictionary<NSString *, UIColor *> *YTzoomPatternCache = nil;
static NSMutableDictionary<NSString *, UIImage *> *YTzoomStripCache = nil;
static NSMutableDictionary<NSString *, UIColor *> *YTzoomColorCache = nil;
static NSUInteger YTzoomProgressGeneration = 0;
static NSUInteger YTzoomCachedGeneration = NSUIntegerMax;

static void YTzoomRelayoutBars(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 14) return;
    NSString *name = NSStringFromClass(view.class);
    if ([name containsString:@"PlayerBar"] ||
        [name containsString:@"MiniplayerProgressBar"] ||
        [name isEqualToString:@"YTBrandGradientView"] ||
        [name isEqualToString:@"YTGridVideoCell"]) {
        [view setNeedsLayout];
        [view setNeedsDisplay];
    }
    for (UIView *subview in view.subviews) {
        YTzoomRelayoutBars(subview, depth + 1);
    }
}

static void YTzoomProgressSyncGeneration(void) {
    static dispatch_once_t observerToken;
    dispatch_once(&observerToken, ^{
        [NSNotificationCenter.defaultCenter
            addObserverForName:YTzoomPreferencesDidChangeNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *note) {
            NSString *key = note.userInfo[@"key"];
            if (![key hasPrefix:@"YTzoom.Preference.Progress."]) return;
            YTzoomProgressGeneration++;
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                    YTzoomRelayoutBars(window, 0);
                }
            }
        }];
    });
    if (YTzoomCachedGeneration == YTzoomProgressGeneration) return;
    YTzoomCachedGeneration = YTzoomProgressGeneration;
    YTzoomStyleCache = -1;
    YTzoomColorCache = nil;
    YTzoomPatternCache = nil;
    YTzoomStripCache = nil;
}

static NSInteger YTzoomProgressStyle(void) {
    YTzoomProgressSyncGeneration();
    if (YTzoomStyleCache >= 0) return YTzoomStyleCache;
    id value = YTzoomPreferenceObject(YTzoomProgressStyleKey);
    YTzoomStyleCache =
        [value respondsToSelector:@selector(integerValue)] ? [value integerValue] : 0;
    return YTzoomStyleCache;
}

static UIColor *YTzoomStoredColor(NSString *key, UIColor *fallback) {
    YTzoomProgressSyncGeneration();
    UIColor *hit = YTzoomColorCache[key];
    if (hit != nil) return hit;
    UIColor *value = YTzoomProgressColorFromHex(YTzoomPreferenceObject(key), fallback);
    if (YTzoomColorCache == nil) YTzoomColorCache = [NSMutableDictionary dictionary];
    if (value != nil) YTzoomColorCache[key] = value;
    return value;
}

static UIColor *YTzoomMainColor(void) {
    return YTzoomStoredColor(YTzoomProgressMainColorKey, UIColor.systemRedColor);
}

static UIColor *YTzoomPlayedColor(void) {
    UIColor *main = YTzoomMainColor();
    if (YTzoomProgressStyle() != 2) return main;
    UIColor *highlight = YTzoomStoredColor(YTzoomProgressGradientColorKey, main);
    static UIImage *cached = nil;
    static NSString *cachedKey = nil;
    NSString *key = [NSString stringWithFormat:@"%@|%@", main, highlight];
    if (cached == nil || ![key isEqualToString:cachedKey]) {
        CGSize size = CGSizeMake(CGRectGetWidth(UIScreen.mainScreen.bounds), 6.0);
        UIGraphicsImageRenderer *renderer =
            [[UIGraphicsImageRenderer alloc] initWithSize:size];
        cached = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
            NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
            CGFloat locations[] = {0.0, 1.0};
            CGGradientRef gradient = CGGradientCreateWithColors(
                space, (__bridge CFArrayRef)colors, locations);
            CGContextDrawLinearGradient(context.CGContext, gradient,
                                        CGPointZero, CGPointMake(size.width, 0.0), 0);
            CGGradientRelease(gradient);
            CGColorSpaceRelease(space);
        }];
        cachedKey = key;
    }
    return [UIColor colorWithPatternImage:cached];
}

static UIImage *YTzoomGradientStrip(CGFloat width, CGFloat height) {
    UIColor *main = YTzoomMainColor();
    UIColor *highlight = YTzoomStoredColor(YTzoomProgressGradientColorKey, main);
    NSString *stripKey = [NSString stringWithFormat:@"%.0f|%.0f|%@|%@",
                          width, height, main, highlight];
    UIImage *cachedStrip = YTzoomStripCache[stripKey];
    if (cachedStrip != nil) return cachedStrip;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *strip = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)main.CGColor, (id)highlight.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient,
                                    CGPointZero, CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    if (YTzoomStripCache == nil) YTzoomStripCache = [NSMutableDictionary dictionary];
    if (YTzoomStripCache.count > 24) [YTzoomStripCache removeAllObjects];
    YTzoomStripCache[stripKey] = strip;
    return strip;
}

UIImage *YTzoomProgressFillImage(CGFloat width, CGFloat height) {
    if (!isfinite(width) || width <= 0.0) width = 1.0;
    if (!isfinite(height) || height <= 0.0) height = 1.0;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    NSInteger style = YTzoomProgressStyle();
    UIColor *start = nil;
    UIColor *end = nil;
    if (style == 1) {
        start = YTzoomMainColor();
        end = start;
    } else if (style == 2) {
        start = YTzoomMainColor();
        end = YTzoomStoredColor(YTzoomProgressGradientColorKey, start);
    } else {
        start = [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
        end = [UIColor colorWithRed:1.0 green:0.29 blue:0.16 alpha:1.0];
    }
    NSString *key = [NSString stringWithFormat:@"fill|%.0f|%.0f|%ld|%@|%@",
                     size.width, size.height, (long)style, start, end];
    UIImage *cached = YTzoomStripCache[key];
    if (cached != nil) return cached;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)start.CGColor, (id)end.CGColor];
        CGFloat locations[] = {0.0, 1.0};
        CGGradientRef gradient = CGGradientCreateWithColors(
            space, (__bridge CFArrayRef)colors, locations);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero,
                                    CGPointMake(size.width, 0.0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    if (YTzoomStripCache == nil) YTzoomStripCache = [NSMutableDictionary dictionary];
    if (YTzoomStripCache.count > 40) [YTzoomStripCache removeAllObjects];
    YTzoomStripCache[key] = image;
    return image;
}

static UIView *YTzoomBarAncestor(UIView *view) {
    UIView *node = view;
    while (node != nil) {
        NSString *name = NSStringFromClass(node.class);
        if ([name isEqualToString:@"YTModularPlayerBarView"] ||
            [name isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            return node;
        }
        node = node.superview;
    }
    return view.superview ?: view;
}

static UIColor *YTzoomPlayedColorForView(id receiver) {
    if (YTzoomProgressStyle() != 2) return YTzoomMainColor();
    if (![receiver isKindOfClass:UIView.class]) return YTzoomPlayedColor();
    UIView *view = (UIView *)receiver;
    UIView *bar = YTzoomBarAncestor(view);
    CGFloat barWidth = CGRectGetWidth(bar.bounds);
    CGFloat viewWidth = CGRectGetWidth(view.bounds);
    CGFloat height = MAX(CGRectGetHeight(view.bounds), 2.0);
    if (barWidth < 2.0 || viewWidth < 1.0) return YTzoomPlayedColor();
    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0) offset = 0.0;
    if (barWidth - offset < viewWidth) barWidth = offset + viewWidth;

    NSString *patternKey = [NSString stringWithFormat:@"%.0f|%.0f|%.0f|%.0f",
                            offset, viewWidth, height, barWidth];
    UIColor *cachedPattern = YTzoomPatternCache[patternKey];
    if (cachedPattern != nil) return cachedPattern;
    CGFloat scale = UIScreen.mainScreen.scale;
    UIImage *full = YTzoomGradientStrip(barWidth, height);
    CGRect crop = CGRectMake(offset * scale, 0.0,
                             viewWidth * scale, height * scale);
    CGImageRef slice = CGImageCreateWithImageInRect(full.CGImage, crop);
    if (slice == NULL) return YTzoomPlayedColor();
    UIImage *tile = [UIImage imageWithCGImage:slice
                                        scale:scale
                                  orientation:UIImageOrientationUp];
    CGImageRelease(slice);
    UIColor *pattern = [UIColor colorWithPatternImage:tile];
    if (YTzoomPatternCache == nil) YTzoomPatternCache = [NSMutableDictionary dictionary];
    if (YTzoomPatternCache.count > 96) [YTzoomPatternCache removeAllObjects];
    YTzoomPatternCache[patternKey] = pattern;
    return pattern;
}

static UIColor *YTzoomScrubberColor(void) {
    return YTzoomStoredColor(YTzoomProgressScrubberColorKey, YTzoomMainColor());
}

UIColor *YTzoomProgressScrubberTint(void) {
    UIColor *tint = YTzoomProgressStyle() != 0 ? YTzoomScrubberColor()
        : [UIColor colorWithRed:1.0 green:0.0 blue:0.0 alpha:1.0];
    static NSString *logged;
    NSString *state = [NSString stringWithFormat:@"style=%ld main=%@ highlight=%@ scrubber=%@",
                       (long)YTzoomProgressStyle(), YTzoomPreferenceObject(YTzoomProgressMainColorKey),
                       YTzoomPreferenceObject(YTzoomProgressGradientColorKey),
                       YTzoomPreferenceObject(YTzoomProgressScrubberColorKey)];
    if (![state isEqualToString:logged]) {
        logged = state;
    }
    return tint;
}


static id YTzoomDecorationViewColor(id receiver, SEL selector) {
    if (YTzoomProgressStyle() != 0) return YTzoomPlayedColorForView(receiver);
    return OriginalDecorationViewColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationViewColor)(receiver, selector);
}

static id YTzoomDecorationControllerColor(id receiver, SEL selector) {
    if (YTzoomProgressStyle() != 0) return YTzoomPlayedColor();
    return OriginalDecorationControllerColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalDecorationControllerColor)(receiver, selector);
}

static id YTzoomContainerQuietColor(id receiver, SEL selector) {
    if (YTzoomProgressStyle() != 0) return YTzoomPlayedColor();
    return OriginalContainerQuietColor == NULL ? nil :
        ((id (*)(id, SEL))OriginalContainerQuietColor)(receiver, selector);
}


static id YTzoomDotColorV1(id receiver, SEL selector) {
    if (YTzoomProgressStyle() != 0) return YTzoomScrubberColor();
    return OriginalScrubberDotColorV1 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV1)(receiver, selector);
}

static id YTzoomDotColorV2(id receiver, SEL selector) {
    if (YTzoomProgressStyle() != 0) return YTzoomScrubberColor();
    return OriginalScrubberDotColorV2 == NULL ? nil :
        ((id (*)(id, SEL))OriginalScrubberDotColorV2)(receiver, selector);
}

static void YTzoomSetDotColor(id receiver, SEL selector, id color) {
    id replacement = YTzoomProgressStyle() != 0 ? YTzoomScrubberColor() : color;
    if (OriginalSetScrubberDotColor != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColor)(receiver, selector, replacement);
    }
}

static void YTzoomSetDotColorV1(id receiver, SEL selector, id color) {
    id replacement = YTzoomProgressStyle() != 0 ? YTzoomScrubberColor() : color;
    if (OriginalSetScrubberDotColorV1 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV1)(receiver, selector, replacement);
    }
}

static void YTzoomSetDotColorV2(id receiver, SEL selector, id color) {
    id replacement = YTzoomProgressStyle() != 0 ? YTzoomScrubberColor() : color;
    if (OriginalSetScrubberDotColorV2 != NULL) {
        ((void (*)(id, SEL, id))OriginalSetScrubberDotColorV2)(receiver, selector, replacement);
    }
}

static IMP OriginalModularBarLayout;
static IMP OriginalDrawProgressRectWithColor;
static IMP OriginalDecorationDrawRect;
static IMP OriginalDrawProgressRect;
static IMP OriginalDrawRectDecorationProgress;
static IMP OriginalDrawRectDecoration;
static IMP OriginalSegmentedLayout;

static UIImage *YTzoomThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth);

static BOOL YTzoomColorIsYouTubeRed(CGColorRef color) {
    if (color == NULL) return NO;
    const CGFloat *components = CGColorGetComponents(color);
    if (components == NULL || CGColorGetNumberOfComponents(color) < 3) return NO;
    return components[0] > 0.6 && components[1] < 0.4 && components[2] < 0.4;
}

static void YTzoomApplyLayerFill(CALayer *layer, UIColor *colour,
                                 CGFloat width, CGFloat height) {
    if (colour == nil) return;
    CGColorRef reference = colour.CGColor;
    if (CGColorGetPattern(reference) == NULL) {
        layer.backgroundColor = reference;
        return;
    }
    CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
    if (track < width) track = width;
    UIImage *fill = YTzoomThumbBarImage(width, height, track);
    layer.backgroundColor = YTzoomMainColor().CGColor;
    if (fill.CGImage != NULL) {
        layer.contents = (__bridge id)fill.CGImage;
        layer.contentsScale = fill.scale;
        layer.contentsGravity = kCAGravityResize;
    }
}

static void YTzoomPaintLayers(CALayer *layer, UIColor *played, UIColor *dot,
                              NSUInteger depth) {
    if (layer == nil || depth > 7) return;
    CGRect bounds = layer.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width > 0.0 && height > 0.0 && YTzoomColorIsYouTubeRed(layer.backgroundColor)) {
        YTzoomApplyLayerFill(layer, (width <= height + 2.0) ? dot : played,
                             width, height);
    }
    for (CALayer *sublayer in layer.sublayers) {
        YTzoomPaintLayers(sublayer, played, dot, depth + 1);
    }
}

static void YTzoomModularBarLayout(UIView *receiver, SEL selector) {
    if (OriginalModularBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalModularBarLayout)(receiver, selector);
    }
    if (YTzoomProgressStyle() == 0) return;
    YTzoomPaintLayers(receiver.layer, YTzoomPlayedColor(), YTzoomScrubberColor(), 0);
    UIView *node = receiver;
    while (node != nil) {
        if ([NSStringFromClass(node.class)
                isEqualToString:@"YTInlinePlayerBarContainerView"]) {
            SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
            if ([node respondsToSelector:setter]) {
                ((void (*)(id, SEL, id))objc_msgSend)(node, setter, YTzoomPlayedColor());
            }
            YTzoomPaintLayers(node.layer, YTzoomPlayedColor(), YTzoomScrubberColor(), 0);
            break;
        }
        node = node.superview;
    }
}

static BOOL YTzoomDrawGradientInRect(id receiver, CGRect rect) {
    if (YTzoomProgressStyle() != 2) return NO;
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL || ![receiver isKindOfClass:UIView.class]) return NO;
    CGFloat height = CGRectGetHeight(rect);
    if (height < 0.5 || CGRectGetWidth(rect) < 0.5) return NO;

    UIView *view = (UIView *)receiver;
    UIView *bar = YTzoomBarAncestor(view);
    CGFloat track = CGRectGetWidth(bar.bounds);
    CGFloat own = CGRectGetWidth(view.bounds);
    if (track < own) track = own;
    if (track < 2.0) return NO;

    CGRect inBar = [view convertRect:view.bounds toView:bar];
    CGFloat offset = CGRectGetMinX(inBar);
    if (offset < 0.0 || offset > track) offset = 0.0;

    UIImage *strip = YTzoomGradientStrip(track, height);
    if (strip == nil) return NO;

    CGContextSaveGState(context);
    CGContextClipToRect(context, rect);
    [strip drawInRect:CGRectMake(-offset, CGRectGetMinY(rect), track, height)];
    CGContextRestoreGState(context);
    return YES;
}

static void YTzoomDrawProgressRectWithColor(id receiver, SEL selector,
                                            CGRect rect, id color) {
    if (YTzoomDrawGradientInRect(receiver, rect)) return;
    id replacement = YTzoomProgressStyle() != 0 ? YTzoomMainColor() : color;
    if (OriginalDrawProgressRectWithColor != NULL) {
        ((void (*)(id, SEL, CGRect, id))OriginalDrawProgressRectWithColor)(
            receiver, selector, rect, replacement);
    }
}

static void YTzoomForceBarColor(id receiver) {
    if (YTzoomProgressStyle() == 0) return;
    SEL setter = NSSelectorFromString(@"setPlayedProgressBarColor:");
    if (![receiver respondsToSelector:setter]) return;
    UIColor *colour = YTzoomPlayedColorForView(receiver);
    if (CGColorGetPattern(colour.CGColor) != NULL) {
        colour = YTzoomMainColor();
    }
    ((void (*)(id, SEL, id))objc_msgSend)(receiver, setter, colour);
}

static void YTzoomDecorationDrawRect(id receiver, SEL selector, CGRect rect) {
    YTzoomForceBarColor(receiver);
    if (OriginalDecorationDrawRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDecorationDrawRect)(receiver, selector, rect);
    }
}

static void YTzoomRecolorSegments(id receiver) {
    if (YTzoomProgressStyle() == 0) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    YTzoomPaintLayers(((UIView *)receiver).layer,
                      YTzoomPlayedColor(), YTzoomScrubberColor(), 0);
    SEL segments = NSSelectorFromString(@"segmentViews");
    if (![receiver respondsToSelector:segments]) return;
    NSArray *views = ((id (*)(id, SEL))objc_msgSend)(receiver, segments);
    if (![views isKindOfClass:NSArray.class]) return;
    for (id view in views) {
        if ([view isKindOfClass:UIView.class]) {
            YTzoomPaintLayers(((UIView *)view).layer,
                              YTzoomPlayedColor(), YTzoomScrubberColor(), 0);
        }
    }
}


static void YTzoomSegmentedLayout(id receiver, SEL selector) {
    if (OriginalSegmentedLayout != NULL) {
        ((void (*)(id, SEL))OriginalSegmentedLayout)(receiver, selector);
    }
    YTzoomRecolorSegments(receiver);
}


static void YTzoomDrawProgressRect(id receiver, SEL selector, CGRect rect) {
    if (YTzoomDrawGradientInRect(receiver, rect)) return;
    YTzoomForceBarColor(receiver);
    if (OriginalDrawProgressRect != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawProgressRect)(receiver, selector, rect);
    }
}

static void YTzoomDrawRectDecorationProgress(id receiver, SEL selector, CGRect rect) {
    YTzoomForceBarColor(receiver);
    if (OriginalDrawRectDecorationProgress != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecorationProgress)(
            receiver, selector, rect);
    }
}

static void YTzoomDrawRectDecoration(id receiver, SEL selector, CGRect rect) {
    YTzoomForceBarColor(receiver);
    if (OriginalDrawRectDecoration != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalDrawRectDecoration)(receiver, selector, rect);
    }
}

static UIView *YTzoomFindProgressView(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return nil;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTProgressView"]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = YTzoomFindProgressView(subview, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}

void YTzoomStyleProgressLayer(CALayer *layer, CGFloat trackWidth) {
    if (layer == nil) return;
    if (YTzoomProgressStyle() == 0) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (width < 1.0 || height < 1.0) return;
    if (trackWidth < width) trackWidth = width;
    if (YTzoomProgressStyle() == 2) {
        UIImage *fill = YTzoomThumbBarImage(width, height, trackWidth);
        layer.backgroundColor = YTzoomMainColor().CGColor;
        if (fill.CGImage != NULL) {
            layer.contents = (__bridge id)fill.CGImage;
            layer.contentsScale = fill.scale;
            layer.contentsGravity = kCAGravityResize;
        }
    } else {
        layer.contents = nil;
        layer.backgroundColor = YTzoomMainColor().CGColor;
    }
}

void YTzoomApplyProgressStyleToBar(UIView *bar) {
    if (YTzoomProgressStyle() == 0 || ![bar isKindOfClass:UIView.class]) return;
    UIView *progress = YTzoomFindProgressView(bar, 0);
    if (progress == nil) return;

    SEL brand = NSSelectorFromString(@"setBrandGradientEnabled:");
    if ([progress respondsToSelector:brand]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(progress, brand, NO);
    }

    UIColor *color = YTzoomMainColor();
    CGFloat width = CGRectGetWidth(bar.bounds);
    CGFloat height = MAX(CGRectGetHeight(progress.bounds), 2.0);
    if (YTzoomProgressStyle() == 2 && width > 2.0) {
        color = [UIColor colorWithPatternImage:YTzoomGradientStrip(width, height)];
    }
    SEL setter = NSSelectorFromString(@"setProgressBarColor:");
    if ([progress respondsToSelector:setter]) {
        ((void (*)(id, SEL, id))objc_msgSend)(progress, setter, color);
    }
    YTzoomPaintLayers(progress.layer, color, YTzoomScrubberColor(), 0);
}

static IMP OriginalThumbBarLayout;
static IMP OriginalThumbContainerLayout;
static const void *YTzoomThumbBarFillAssociation = &YTzoomThumbBarFillAssociation;
static const void *YTzoomThumbBarGenerationAssociation =
    &YTzoomThumbBarGenerationAssociation;

static const void *YTzoomThumbGeneratedAssociation =
    &YTzoomThumbGeneratedAssociation;
static const void *YTzoomBarTouchedAssociation = &YTzoomBarTouchedAssociation;

static CGFloat YTzoomThumbTrackWidth(id node, CGFloat fillWidth,
                                     CGFloat fillHeight) {
    CGFloat track = fillWidth;
    SEL supernode = NSSelectorFromString(@"supernode");
    id parent = node;
    for (NSUInteger depth = 0; depth < 4; depth++) {
        if (![parent respondsToSelector:supernode]) break;
        parent = ((id (*)(id, SEL))objc_msgSend)(parent, supernode);
        if (parent == nil) break;
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            parent, NSSelectorFromString(@"bounds"));
        if (fabs(CGRectGetHeight(bounds) - fillHeight) > 1.5) continue;
        if (CGRectGetWidth(bounds) > track) track = CGRectGetWidth(bounds);
    }
    return track;
}

static UIImage *YTzoomThumbBarImage(CGFloat width, CGFloat height,
                                    CGFloat trackWidth) {
    if (YTzoomProgressStyle() == 2) {
        if (trackWidth <= width + 1.0) return YTzoomGradientStrip(width, height);
        NSString *sliceKey = [NSString stringWithFormat:@"thumb|%.0f|%.0f|%.0f|%@|%@",
                              width, height, trackWidth, YTzoomMainColor(),
                              YTzoomStoredColor(YTzoomProgressGradientColorKey,
                                                YTzoomMainColor())];
        UIImage *cachedSlice = YTzoomStripCache[sliceKey];
        if (cachedSlice != nil) return cachedSlice;
        UIImage *full = YTzoomGradientStrip(trackWidth, height);
        CGFloat scale = full.scale;
        CGImageRef cropped = CGImageCreateWithImageInRect(
            full.CGImage, CGRectMake(0.0, 0.0, width * scale, height * scale));
        if (cropped == NULL) return YTzoomGradientStrip(width, height);
        UIImage *slice = [UIImage imageWithCGImage:cropped
                                             scale:scale
                                       orientation:UIImageOrientationUp];
        CGImageRelease(cropped);
        if (YTzoomStripCache == nil) YTzoomStripCache = [NSMutableDictionary dictionary];
        if (YTzoomStripCache.count > 24) [YTzoomStripCache removeAllObjects];
        objc_setAssociatedObject(slice, YTzoomThumbGeneratedAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        YTzoomStripCache[sliceKey] = slice;
        return slice;
    }
    UIColor *main = YTzoomMainColor();
    NSString *key = [NSString stringWithFormat:@"solid|%.0f|%.0f|%@",
                     width, height, main];
    UIImage *cached = YTzoomStripCache[key];
    if (cached != nil) return cached;
    CGSize size = CGSizeMake(MAX(width, 1.0), MAX(height, 1.0));
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:
        ^(UIGraphicsImageRendererContext *context) {
        [main setFill];
        CGRect rect = CGRectMake(0.0, 0.0, size.width, size.height);
        [[UIBezierPath bezierPathWithRoundedRect:rect
                                    cornerRadius:size.height / 2.0] fill];
        (void)context;
    }];
    if (YTzoomStripCache == nil) YTzoomStripCache = [NSMutableDictionary dictionary];
    if (YTzoomStripCache.count > 24) [YTzoomStripCache removeAllObjects];
    objc_setAssociatedObject(image, YTzoomThumbGeneratedAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomStripCache[key] = image;
    return image;
}

static void YTzoomThumbBarApply(id node) {
    if (YTzoomProgressStyle() == 0) return;

    CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
        node, NSSelectorFromString(@"bounds"));
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);

    NSString *name = NSStringFromClass([node class]);
    SEL imageGetter = NSSelectorFromString(@"image");
    SEL imageSetter = NSSelectorFromString(@"setImage:");
    UIImage *current = [node respondsToSelector:imageGetter]
        ? ((id (*)(id, SEL))objc_msgSend)(node, imageGetter) : nil;

    if (height < 1.0 || height > 4.0 || width < 8.0) return;
    if (![name isEqualToString:@"ELMImageNode"]) return;
    if (![node respondsToSelector:imageSetter]) return;
    if (current == nil) return;

    BOOL ours = objc_getAssociatedObject(
        current, YTzoomThumbGeneratedAssociation) != nil;
    NSNumber *appliedWidth = objc_getAssociatedObject(
        node, YTzoomThumbBarFillAssociation);
    NSNumber *applied = objc_getAssociatedObject(
        node, YTzoomThumbBarGenerationAssociation);
    if (ours && applied != nil &&
        applied.unsignedIntegerValue == YTzoomProgressGeneration &&
        appliedWidth != nil &&
        fabs(appliedWidth.doubleValue - width) < 1.0) return;

    UIImage *replacement = YTzoomThumbBarImage(
        width, height, YTzoomThumbTrackWidth(node, width, height));
    if (current == replacement) return;

    SEL modifier = NSSelectorFromString(@"imageModificationBlock");
    SEL setModifier = NSSelectorFromString(@"setImageModificationBlock:");
    BOOL hadModifier = NO;
    if ([node respondsToSelector:modifier]) {
        hadModifier = ((id (*)(id, SEL))objc_msgSend)(node, modifier) != nil;
    }
    if (hadModifier && [node respondsToSelector:setModifier]) {
        ((void (*)(id, SEL, id))objc_msgSend)(node, setModifier, nil);
    }
    SEL setTint = NSSelectorFromString(@"setTintColor:");
    if ([node respondsToSelector:NSSelectorFromString(@"tintColor")] &&
        [node respondsToSelector:setTint]) {
        ((void (*)(id, SEL, id))objc_msgSend)(
            node, setTint, YTzoomProgressStyle() == 2
                ? YTzoomStoredColor(YTzoomProgressGradientColorKey,
                                    YTzoomMainColor())
                : YTzoomMainColor());
    }

    ((void (*)(id, SEL, id))objc_msgSend)(node, imageSetter, replacement);
    SEL redisplay = NSSelectorFromString(@"setNeedsDisplay");
    if ([node respondsToSelector:redisplay]) {
        __weak id weakNode = node;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongNode = weakNode;
            if (strongNode == nil) return;
            UIImage *shown = ((id (*)(id, SEL))objc_msgSend)(
                strongNode, NSSelectorFromString(@"image"));
            if (objc_getAssociatedObject(
                    shown, YTzoomThumbGeneratedAssociation) == nil) return;
            ((void (*)(id, SEL))objc_msgSend)(strongNode, redisplay);
        });
    }
    objc_setAssociatedObject(node, YTzoomThumbBarFillAssociation, @(width),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(node, YTzoomThumbBarGenerationAssociation,
                             @(YTzoomProgressGeneration),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

}

static void YTzoomThumbBarLayout(id node, SEL selector) {
    if (OriginalThumbBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbBarLayout)(node, selector);
    }
    YTzoomThumbBarApply(node);
}

static IMP OriginalThumbVisible;
static IMP OriginalThumbDisplayWillStart;

static void YTzoomThumbDisplayWillStart(id node, SEL selector) {
    if (OriginalThumbDisplayWillStart != NULL) {
        ((void (*)(id, SEL))OriginalThumbDisplayWillStart)(node, selector);
    }
    YTzoomThumbBarApply(node);
}

static void YTzoomThumbDidEnterVisible(id node, SEL selector) {
    if (OriginalThumbVisible != NULL) {
        ((void (*)(id, SEL))OriginalThumbVisible)(node, selector);
    }
    YTzoomThumbBarApply(node);
}

static void YTzoomThumbContainerLayout(id node, SEL selector) {
    if (OriginalThumbContainerLayout != NULL) {
        ((void (*)(id, SEL))OriginalThumbContainerLayout)(node, selector);
    }
    YTzoomThumbBarApply(node);
}

static IMP OriginalInlineScrubberLayout;
static IMP OriginalInlinePostScrubberLayout;

static void YTzoomTintInlineSliders(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 4) return;
    if ([view isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)view;
        UIColor *dot = YTzoomScrubberColor();
        UIImage *thumb = [slider thumbImageForState:UIControlStateNormal];
        if (thumb == nil) {
            if (CGColorGetPattern(dot.CGColor) == NULL) slider.thumbTintColor = dot;
        } else {
            if (thumb.renderingMode != UIImageRenderingModeAlwaysTemplate) {
                [slider setThumbImage:
                    [thumb imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
                             forState:UIControlStateNormal];
            }
            slider.tintColor = dot;
        }
        UIColor *played = YTzoomMainColor();
        if (CGColorGetPattern(played.CGColor) == NULL) {
            slider.minimumTrackTintColor = played;
        }
    }
    for (UIView *subview in view.subviews) {
        YTzoomTintInlineSliders(subview, depth + 1);
    }
}

static void YTzoomInlineScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlineScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlineScrubberLayout)(receiver, selector);
    }
    if (YTzoomProgressStyle() == 0) return;
    YTzoomTintInlineSliders(receiver, 0);
}

static void YTzoomInlinePostScrubberLayout(UIView *receiver, SEL selector) {
    if (OriginalInlinePostScrubberLayout != NULL) {
        ((void (*)(id, SEL))OriginalInlinePostScrubberLayout)(receiver, selector);
    }
    if (YTzoomProgressStyle() == 0) return;
    YTzoomTintInlineSliders(receiver, 0);
}

static NSUInteger YTzoomInstallProgressHookSet(void) {
    NSUInteger landed = 0;
    struct { const char *cls; const char *sel; IMP replacement; IMP *storage; } entries[] = {
        {"YTPlayerBarProgressDecorationView", "playedProgressBarColor",
         (IMP)YTzoomDecorationViewColor, &OriginalDecorationViewColor},
        {"YTPlayerBarProgressDecorationController", "playedProgressBarColor",
         (IMP)YTzoomDecorationControllerColor, &OriginalDecorationControllerColor},
        {"YTInlinePlayerBarContainerView", "quietProgressBarColor",
         (IMP)YTzoomContainerQuietColor, &OriginalContainerQuietColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "scrubberDotColor",
         (IMP)YTzoomDotColorV1, &OriginalScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "scrubberDotColor",
         (IMP)YTzoomDotColorV2, &OriginalScrubberDotColorV2},
        {"YTPlayerBarScrubberDotDecorationView", "setScrubberDotColor:",
         (IMP)YTzoomSetDotColor, &OriginalSetScrubberDotColor},
        {"YTPlayerBarScrubberDotDecorationViewV1", "setScrubberDotColor:",
         (IMP)YTzoomSetDotColorV1, &OriginalSetScrubberDotColorV1},
        {"YTPlayerBarScrubberDotDecorationViewV2", "setScrubberDotColor:",
         (IMP)YTzoomSetDotColorV2, &OriginalSetScrubberDotColorV2},
        {"YTModularPlayerBarView", "layoutSubviews",
         (IMP)YTzoomModularBarLayout, &OriginalModularBarLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:withColor:",
         (IMP)YTzoomDrawProgressRectWithColor, &OriginalDrawProgressRectWithColor},
        {"YTPlayerBarProgressDecorationView", "drawRect:",
         (IMP)YTzoomDecorationDrawRect, &OriginalDecorationDrawRect},
        {"YTPlayerBarScrubberDotDecorationViewV1", "layoutSubviews",
         (IMP)YTzoomSegmentedLayout, &OriginalSegmentedLayout},
        {"YTPlayerBarProgressDecorationView", "drawProgressRect:",
         (IMP)YTzoomDrawProgressRect, &OriginalDrawProgressRect},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecorationWithProgress:",
         (IMP)YTzoomDrawRectDecorationProgress, &OriginalDrawRectDecorationProgress},
        {"YTPlayerBarProgressDecorationView", "drawRectangleDecoration:",
         (IMP)YTzoomDrawRectDecoration, &OriginalDrawRectDecoration},
        {"YTInlineMutedPlaybackScrubberView", "layoutSubviews",
         (IMP)YTzoomInlineScrubberLayout, &OriginalInlineScrubberLayout},
        {"YTInlineMutedPlaybackPostVideoScrubberView", "layoutSubviews",
         (IMP)YTzoomInlinePostScrubberLayout, &OriginalInlinePostScrubberLayout}
    };
    for (size_t i = 0; i < sizeof(entries) / sizeof(entries[0]); i++) {
        NSString *cls = @(entries[i].cls);
        NSString *sel = @(entries[i].sel);
        BOOL ok = YTzoomInstallInstanceHook(cls, sel, entries[i].replacement,
                                            entries[i].storage);
        if (ok) landed++;
    }
    return landed;
}

static BOOL YTzoomCGImageIsRed(CGImageRef bitmap) {
    if (bitmap == NULL) return NO;
    size_t pixelWidth = CGImageGetWidth(bitmap);
    size_t pixelHeight = CGImageGetHeight(bitmap);
    if (pixelWidth == 0 || pixelHeight == 0) return NO;
    unsigned char pixel[4] = {0, 0, 0, 0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixel, 1, 1, 8, 4, space,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (context == NULL) return NO;
    CGContextDrawImage(context,
                       CGRectMake(-(CGFloat)(pixelWidth / 2),
                                  -(CGFloat)(pixelHeight / 2),
                                  (CGFloat)pixelWidth, (CGFloat)pixelHeight),
                       bitmap);
    CGContextRelease(context);
    return pixel[3] > 100 && pixel[0] > 120 &&
           pixel[1] < 100 && pixel[2] < 100;
}

static BOOL YTzoomColourIsRed(CGColorRef colour) {
    if (colour == NULL) return NO;
    size_t count = CGColorGetNumberOfComponents(colour);
    const CGFloat *parts = CGColorGetComponents(colour);
    if (parts == NULL || count < 4) return NO;
    return parts[3] > 0.4 && parts[0] > 0.5 && parts[1] < 0.4 && parts[2] < 0.4;
}

static void YTzoomRecolourRedBars(CALayer *layer, NSUInteger depth,
                                  UIView *host, NSString *trail) {
    if (layer == nil || depth > 8) return;
    CGFloat width = CGRectGetWidth(layer.bounds);
    CGFloat height = CGRectGetHeight(layer.bounds);
    if (height >= 1.0 && height <= 6.0 && width >= 6.0) {
        BOOL redBackground = YTzoomColourIsRed(layer.backgroundColor);
        CGImageRef drawn = (__bridge CGImageRef)layer.contents;
        BOOL redContents = drawn != NULL &&
            CFGetTypeID(drawn) == CGImageGetTypeID() &&
            YTzoomCGImageIsRed(drawn);
        NSNumber *touched = objc_getAssociatedObject(
            layer, YTzoomBarTouchedAssociation);
        BOOL stale = touched != nil &&
            touched.unsignedIntegerValue != YTzoomProgressGeneration;
        if (redBackground || redContents || stale) {
            CGFloat track = CGRectGetWidth(layer.superlayer.bounds);
            if (track < width) track = width;
            UIImage *fill = YTzoomThumbBarImage(width, height, track);
            layer.backgroundColor = YTzoomMainColor().CGColor;
            layer.cornerRadius = height / 2.0;
            if (YTzoomProgressStyle() == 2 && fill.CGImage != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
                layer.contentsGravity = kCAGravityResize;
            } else if (fill.CGImage != NULL && layer.contents != NULL) {
                layer.contents = (__bridge id)fill.CGImage;
                layer.contentsScale = fill.scale;
            }
            if (host != nil && host.layer == layer) {
                host.backgroundColor = YTzoomMainColor();
            }
            objc_setAssociatedObject(layer, YTzoomBarTouchedAssociation,
                                     @(YTzoomProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    for (CALayer *sublayer in layer.sublayers) {
        YTzoomRecolourRedBars(sublayer, depth + 1, host, trail);
    }
}

static IMP OriginalThumbSetImage;

static void YTzoomThumbSetImage(id node, SEL selector, UIImage *image) {
    UIImage *use = image;
    if (image != nil && YTzoomProgressStyle() != 0 &&
        objc_getAssociatedObject(image, YTzoomThumbGeneratedAssociation) == nil) {
        CGRect bounds = ((CGRect (*)(id, SEL))objc_msgSend)(
            node, NSSelectorFromString(@"bounds"));
        CGFloat width = CGRectGetWidth(bounds);
        CGFloat height = CGRectGetHeight(bounds);
        if (width < 1.0 || height < 1.0) {
            CGFloat scale = image.scale > 0.0 ? image.scale : 1.0;
            width = image.size.width / (scale > 1.0 ? 1.0 : 2.0);
            height = image.size.height / (scale > 1.0 ? 1.0 : 2.0);
        }
        if (height >= 1.0 && height <= 4.0 && width >= 8.0) {
            use = YTzoomThumbBarImage(
                width, height, YTzoomThumbTrackWidth(node, width, height));
        }
    }
    if (OriginalThumbSetImage != NULL) {
        ((void (*)(id, SEL, id))OriginalThumbSetImage)(node, selector, use);
    }
}

static IMP OriginalGridCellLayout;
static IMP OriginalBrandGradientDraw;

static void YTzoomBrandGradientDraw(UIView *receiver, SEL selector, CGRect rect) {
    CGRect bounds = receiver.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    CGContextRef context = UIGraphicsGetCurrentContext();
    BOOL eligible = YTzoomProgressStyle() != 0 && context != NULL &&
                    height >= 1.0 && height <= 6.0 && width >= 4.0;

    if (!eligible) {
        if (OriginalBrandGradientDraw != NULL) {
            ((void (*)(id, SEL, CGRect))OriginalBrandGradientDraw)(
                receiver, selector, rect);
        }
        return;
    }
    CGFloat track = width;
    UIView *ancestor = receiver.superview;
    for (NSUInteger level = 0; ancestor != nil && level < 5; level++) {
        CGFloat ancestorHeight = CGRectGetHeight(ancestor.bounds);
        CGFloat ancestorWidth = CGRectGetWidth(ancestor.bounds);
        if (ancestorHeight <= 10.0 && ancestorWidth > track) {
            track = ancestorWidth;
        }
        ancestor = ancestor.superview;
    }
    UIImage *fill = YTzoomThumbBarImage(width, height, track);
    [fill drawInRect:bounds];
}

static void YTzoomRefreshBrandGradients(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        NSNumber *drawn = objc_getAssociatedObject(
            view, YTzoomBarTouchedAssociation);
        if (drawn == nil ||
            drawn.unsignedIntegerValue != YTzoomProgressGeneration) {
            objc_setAssociatedObject(view, YTzoomBarTouchedAssociation,
                                     @(YTzoomProgressGeneration),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [view setNeedsDisplay];
        }
        return;
    }
    for (UIView *subview in view.subviews) {
        YTzoomRefreshBrandGradients(subview, depth + 1);
    }
}

static BOOL YTzoomHasBrandGradient(UIView *view, NSUInteger depth) {
    if (view == nil || depth > 10) return NO;
    if ([NSStringFromClass(view.class) isEqualToString:@"YTBrandGradientView"]) {
        return YES;
    }
    for (UIView *subview in view.subviews) {
        if (YTzoomHasBrandGradient(subview, depth + 1)) return YES;
    }
    return NO;
}

static void YTzoomGridCellLayout(UIView *receiver, SEL selector) {
    if (OriginalGridCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalGridCellLayout)(receiver, selector);
    }
    if (YTzoomProgressStyle() == 0) return;
    BOOL brand = YTzoomHasBrandGradient(receiver, 0);
    if (brand) {
        YTzoomRefreshBrandGradients(receiver, 0);
        return;
    }
    YTzoomRecolourRedBars(receiver.layer, 0, receiver,
                          NSStringFromClass(receiver.class));
}

void YTzoomInstallProgressBarHooks(void) {
    static dispatch_once_t sweepToken;
    dispatch_once(&sweepToken, ^{
        BOOL grid = YTzoomInstallInstanceHook(@"YTGridVideoCell", @"layoutSubviews",
                                              (IMP)YTzoomGridCellLayout,
                                              &OriginalGridCellLayout);
        BOOL brand = YTzoomInstallInstanceHook(@"YTBrandGradientView", @"drawRect:",
                                               (IMP)YTzoomBrandGradientDraw,
                                               &OriginalBrandGradientDraw);
        (void)grid;
        (void)brand;
    });
    static dispatch_once_t thumbToken;
    dispatch_once(&thumbToken, ^{
        BOOL image = YTzoomInstallInstanceHook(@"ELMImageNode", @"layoutDidFinish",
                                               (IMP)YTzoomThumbBarLayout,
                                               &OriginalThumbBarLayout);
        BOOL container = YTzoomInstallInstanceHook(@"ELMContainerNode",
                                                   @"layoutDidFinish",
                                                   (IMP)YTzoomThumbContainerLayout,
                                                   &OriginalThumbContainerLayout);
        YTzoomInstallInstanceHook(@"ELMImageNode", @"displayWillStart",
                                  (IMP)YTzoomThumbDisplayWillStart,
                                  &OriginalThumbDisplayWillStart);
        YTzoomInstallInstanceHook(@"ELMImageNode", @"didEnterVisibleState",
                                  (IMP)YTzoomThumbDidEnterVisible,
                                  &OriginalThumbVisible);
        YTzoomInstallInstanceHook(@"ELMImageNode", @"setImage:",
                                  (IMP)YTzoomThumbSetImage,
                                  &OriginalThumbSetImage);
        (void)image;
        (void)container;
    });
    static NSUInteger attempt = 0;
    NSUInteger landed = YTzoomInstallProgressHookSet();
    attempt++;
    if (landed >= 15 || attempt >= 20) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        YTzoomInstallProgressBarHooks();
    });
}
