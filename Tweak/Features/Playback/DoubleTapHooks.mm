#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <math.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSValue *> *YTzoomDoubleTapOriginals;
static const void *YTzoomTapSeekHelperKey = &YTzoomTapSeekHelperKey;

static BOOL YTzoomCommitTapSeek(UIResponder *first, double time) {
    for (UIResponder *responder = first; responder != nil;
         responder = responder.nextResponder) {
        SEL detailed = NSSelectorFromString(@"seekToTime:seekSource:");
        SEL simple = NSSelectorFromString(@"seekToTime:");
        SEL legacy = NSSelectorFromString(
            @"didSeekToTime:toleranceBefore:toleranceAfter:");
        if ([responder respondsToSelector:detailed]) {
            ((void (*)(id, SEL, double, NSInteger))objc_msgSend)(
                responder, detailed, time, 0);
            return YES;
        }
        if ([responder respondsToSelector:simple]) {
            ((void (*)(id, SEL, double))objc_msgSend)(responder, simple, time);
            return YES;
        }
        if ([responder respondsToSelector:legacy]) {
            ((void (*)(id, SEL, double, double, double))objc_msgSend)(
                responder, legacy, time, 0.0, 0.0);
            return YES;
        }
    }
    return NO;
}

static double YTzoomMaximumSeekableTime(UIResponder *responder,
                                        NSString **providerName) {
    SEL selector = NSSelectorFromString(@"maximumSeekableTime");
    for (NSUInteger depth = 0; responder != nil && depth < 20; depth++) {
        Method method = class_getInstanceMethod(responder.class, selector);
        if (method != NULL) {
            char returnType[16] = {};
            method_getReturnType(method, returnType, sizeof(returnType));
            double value = 0.0;
            if (strcmp(returnType, @encode(double)) == 0) {
                value = ((double (*)(id, SEL))objc_msgSend)(responder,
                                                             selector);
            } else if (strcmp(returnType, @encode(float)) == 0) {
                value = ((float (*)(id, SEL))objc_msgSend)(responder,
                                                            selector);
            }
            if (isfinite(value) && value > 0.0) {
                if (providerName != NULL) {
                    *providerName = NSStringFromClass(responder.class);
                }
                return value;
            }
        }
        responder = responder.nextResponder;
    }
    return 0.0;
}

static UIView *YTzoomScrubberDot(UIView *view) {
    SEL selector = NSSelectorFromString(@"scrubberDot");
    if ([view respondsToSelector:selector]) {
        id dot = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if ([dot isKindOfClass:UIView.class]) return dot;
    }
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:view.subviews];
    while (queue.count != 0) {
        UIView *candidate = queue.firstObject;
        [queue removeObjectAtIndex:0];
        NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
            NSStringFromClass(candidate.class).lowercaseString,
            candidate.accessibilityIdentifier.lowercaseString ?: @"",
            candidate.accessibilityLabel.lowercaseString ?: @""];
        if ([token containsString:@"scrubber"] &&
            CGRectGetWidth(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) <= 64.0) {
            return candidate;
        }
        [queue addObjectsFromArray:candidate.subviews];
    }
    return nil;
}

static BOOL YTzoomTapHitsScrubber(UIView *view, CGPoint point,
                                  CGFloat *trackY) {
    UIView *dot = YTzoomScrubberDot(view);
    CGFloat centerY = MAX(CGRectGetMinY(view.bounds),
                          CGRectGetMaxY(view.bounds) - 2.0);
    if (dot != nil && dot.superview != nil) {
        centerY = [dot.superview convertPoint:dot.center toView:view].y;
    }
    if (trackY != NULL) *trackY = centerY;
    return fabs(point.y - centerY) <= 14.0;
}

static BOOL YTzoomTapHitsOverlayControl(UIView *view, CGPoint point,
                                        NSString **controlName) {
    UIView *candidate = [view hitTest:point withEvent:nil];
    while (candidate != nil && candidate != view) {
        if ([candidate isKindOfClass:UIControl.class]) {
            NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                NSStringFromClass(candidate.class).lowercaseString,
                candidate.accessibilityIdentifier.lowercaseString ?: @"",
                candidate.accessibilityLabel.lowercaseString ?: @""];
            BOOL scrubberControl = [token containsString:@"scrub"] ||
                                   [token containsString:@"progress"] ||
                                   [token containsString:@"playerbar"];
            if (!scrubberControl) {
                if (controlName != NULL) *controlName = token;
                return YES;
            }
        }
        candidate = candidate.superview;
    }
    return NO;
}

@interface YTzoomTapSeekTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIView *view;
@end

@implementation YTzoomTapSeekTarget
- (void)tap:(UITapGestureRecognizer *)recognizer {
    UIView *view = self.view;
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.TapToSeek") || view == nil ||
        CGRectGetWidth(view.bounds) <= 1.0) return;
    CGPoint point = [recognizer locationInView:view];
    if (YTzoomTapHitsOverlayControl(view, point, NULL)) {
        return;
    }
    if (!YTzoomTapHitsScrubber(view, point, NULL)) {
        return;
    }
    double x = point.x;
    SEL rangeSelector = NSSelectorFromString(@"scrubRangeForScrubX:");
    SEL nativeSeek = NSSelectorFromString(@"fineScrubberDidSeekToTime:");
    if (![view respondsToSelector:rangeSelector]) {
        return;
    }
    double ratio = ((double (*)(id, SEL, double))objc_msgSend)(
        view, rangeSelector, x);
    if (!isfinite(ratio)) return;
    ratio = MIN(1.0, MAX(0.0, ratio));
    double duration = YTzoomMaximumSeekableTime(view, NULL);
    if (!isfinite(duration) || duration <= 0.0) {
        return;
    }
    double time = ratio * duration;
    BOOL committed = YTzoomCommitTapSeek(view, time);
    if (!committed && [view respondsToSelector:nativeSeek]) {
        ((void (*)(id, SEL, double))objc_msgSend)(view, nativeSeek, time);
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.TapToSeek");
}
@end

void YTzoomConfigureTapToSeek(UIView *receiver) {
    if (receiver == nil) return;
    YTzoomTapSeekTarget *target = objc_getAssociatedObject(
        receiver, YTzoomTapSeekHelperKey);
    if (target == nil) {
        target = [YTzoomTapSeekTarget new];
        target.view = receiver;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:target action:@selector(tap:)];
        tap.cancelsTouchesInView = NO;
        tap.delegate = target;
        [receiver addGestureRecognizer:tap];
        objc_setAssociatedObject(receiver, YTzoomTapSeekHelperKey, target,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static NSValue *YTzoomDoubleTapValueForIMP(IMP implementation) {
    return [NSValue value:&implementation withObjCType:@encode(IMP)];
}

static IMP YTzoomDoubleTapIMPFromValue(NSValue *value) {
    IMP implementation = NULL;
    [value getValue:&implementation];
    return implementation;
}

static double YTzoomDoubleTapValue(void) {
    double value = [NSUserDefaults.standardUserDefaults
        doubleForKey:@"YTzoom.Preference.Playback.DoubleTapSeconds"];
    return MIN(60.0, MAX(5.0, value > 0.0 ? value : 10.0));
}

static NSString *YTzoomDoubleTapKey(Class cls,
                                    BOOL classMethod,
                                    SEL selector) {
    return [NSString stringWithFormat:@"%@|%@|%@",
            NSStringFromClass(cls),
            classMethod ? @"+" : @"-",
            NSStringFromSelector(selector)];
}

static IMP YTzoomDoubleTapOriginal(id receiver, SEL selector) {
    BOOL classMethod = object_isClass(receiver);
    Class cls = classMethod ? (Class)receiver : [receiver class];
    while (cls != Nil) {
        NSValue *value =
            YTzoomDoubleTapOriginals[YTzoomDoubleTapKey(cls, classMethod, selector)];
        if (value != nil) {
            return YTzoomDoubleTapIMPFromValue(value);
        }
        cls = class_getSuperclass(cls);
    }
    return NULL;
}

static double YTzoomDoubleTapDoubleNoArg(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return YTzoomDoubleTapValue();
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float YTzoomDoubleTapFloatNoArg(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return (float)YTzoomDoubleTapValue();
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger YTzoomDoubleTapIntegerNoArg(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(YTzoomDoubleTapValue());
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static double YTzoomDoubleTapDouble(id receiver,
                                    SEL selector,
                                    id __unsafe_unretained config) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return YTzoomDoubleTapValue();
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0
        : ((double (*)(id, SEL, id))original)(receiver, selector, config);
}

static float YTzoomDoubleTapFloat(id receiver,
                                  SEL selector,
                                  id __unsafe_unretained config) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return (float)YTzoomDoubleTapValue();
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10.0f
        : ((float (*)(id, SEL, id))original)(receiver, selector, config);
}

static NSInteger YTzoomDoubleTapInteger(id receiver,
                                        SEL selector,
                                        id __unsafe_unretained config) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.CustomDoubleTap")) {
        return (NSInteger)llround(YTzoomDoubleTapValue());
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? 10
        : ((NSInteger (*)(id, SEL, id))original)(receiver, selector, config);
}

static BOOL YTzoomTapToSeekDisabled(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.TapToSeek")) {
        return NO;
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original == NULL
        ? NO
        : ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTzoomTapToSeekEnabled(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Playback.TapToSeek")) {
        return YES;
    }
    IMP original = YTzoomDoubleTapOriginal(receiver, selector);
    return original != NULL &&
        ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static BOOL YTzoomInstallTapToSeekHook(NSString *className,
                                       NSString *selectorName,
                                       IMP replacement,
                                       BOOL classMethod) {
    SEL selector = NSSelectorFromString(selectorName);
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(target, selector);
    if (method == NULL) return NO;
    IMP original = NULL;
    BOOL installed = classMethod
        ? YTzoomInstallClassHook(className, selectorName,
                                 replacement, &original)
        : YTzoomInstallInstanceHook(className, selectorName,
                                    replacement, &original);
    if (installed && original != NULL) {
        NSString *key = YTzoomDoubleTapKey(cls, classMethod, selector);
        if (YTzoomDoubleTapOriginals[key] == nil) {
            YTzoomDoubleTapOriginals[key] =
                YTzoomDoubleTapValueForIMP(original);
        }
    }
    return installed;
}

static void YTzoomInstallDoubleTapHook(NSString *className,
                                      NSString *selectorName,
                                      BOOL classMethod) {
    Class cls = NSClassFromString(className);
    Class target = classMethod ? object_getClass(cls) : cls;
    Method method = class_getInstanceMethod(
        target,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }

    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    BOOL takesArgument = [selectorName containsString:@":"];
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(double)) == 0) {
        replacement = takesArgument
            ? (IMP)YTzoomDoubleTapDouble
            : (IMP)YTzoomDoubleTapDoubleNoArg;
    } else if (strcmp(returnType, @encode(float)) == 0) {
        replacement = takesArgument
            ? (IMP)YTzoomDoubleTapFloat
            : (IMP)YTzoomDoubleTapFloatNoArg;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = takesArgument
            ? (IMP)YTzoomDoubleTapInteger
            : (IMP)YTzoomDoubleTapIntegerNoArg;
    }
    if (replacement == NULL) {
        return;
    }

    IMP original = NULL;
    BOOL installed = classMethod
        ? YTzoomInstallClassHook(className, selectorName, replacement, &original)
        : YTzoomInstallInstanceHook(className, selectorName, replacement, &original);
    if (installed && original != NULL) {
        NSString *key =
            YTzoomDoubleTapKey(cls, classMethod, NSSelectorFromString(selectorName));
        if (YTzoomDoubleTapOriginals[key] == nil) {
            YTzoomDoubleTapOriginals[key] =
                YTzoomDoubleTapValueForIMP(original);
        }
    }
}

void YTzoomInstallDoubleTapHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomDoubleTapOriginals = [NSMutableDictionary dictionary];
    });

    YTzoomInstallDoubleTapHook(@"YTSettings", @"doubleTapSeekDuration", NO);
    YTzoomInstallDoubleTapHook(@"YTUserDefaults", @"doubleTapSeekDuration", NO);
    for (NSString *selector in @[
        @"doubleTapSeekDurationForVideoPlayerOverlayConfig:",
        @"doubleTapSeekIntervalForVideoPlayerOverlayConfig:"
    ]) {
        YTzoomInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            NO
        );
        YTzoomInstallDoubleTapHook(
            @"YTVideoPlayerOverlayConfigTransformer",
            selector,
            YES
        );
    }
    for (NSString *className in @[
        @"YTHotConfig",
        @"YTColdConfig",
        @"YTGlobalConfig",
        @"YTSettings"
    ]) {
        for (NSNumber *classMethodValue in @[@NO, @YES]) {
            BOOL classMethod = classMethodValue.boolValue;
            YTzoomInstallTapToSeekHook(
                className, @"androidDisableTimeBarTapToSeek",
                (IMP)YTzoomTapToSeekDisabled, classMethod);
            YTzoomInstallTapToSeekHook(
                className, @"iosEnableVideoPlayerScrubber",
                (IMP)YTzoomTapToSeekEnabled, classMethod);
        }
    }
}
