#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/OverlayButtonHost.h"

#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import <string.h>

static NSMutableDictionary<NSString *, NSNumber *> *YTzoomMaximumRateOriginals;

static NSString * const YTzoomLastRateKey = @"YTzoom.Preference.Player.SavedRate";
static NSString * const YTzoomStartRateKey = @"YTzoom.Preference.Player.StartRate";
static NSString * const YTzoomLegacyRateKey = @"YTzoom.Preference.Player.DefaultRate";
static NSString * const YTzoomLegacyModeKey =
    @"YTzoom.Preference.Player.DefaultRateMode";

static NSString * const YTzoomCustomRateKey = @"YTzoom.Preference.Player.CustomRate";
static NSString * const YTzoomShortsRateKey = @"YTzoom.Preference.Shorts.PlaybackRate";

static const double YTzoomRateFollowApp = 0.0;
static const double YTzoomRateReuseLast = -1.0;
static const double YTzoomRateUseCustom = -2.0;
static const double YTzoomRateFloor = 0.25;
static const double YTzoomRateCeiling = 5.0;

static BOOL YTzoomRateIsUsable(double rate) {
    return isfinite(rate) && rate >= YTzoomRateFloor && rate <= YTzoomRateCeiling;
}

static double YTzoomLastPlayedRate(void) {
    double rate = [NSUserDefaults.standardUserDefaults doubleForKey:YTzoomLastRateKey];
    return YTzoomRateIsUsable(rate) ? rate : 0.0;
}

static NSString * const YTzoomRateMigratedKey =
    @"YTzoom.Preference.Player.StartRateMigrated";

static double YTzoomConfiguredStartRate(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:YTzoomRateMigratedKey]) {
        return [defaults doubleForKey:YTzoomStartRateKey];
    }
    [defaults setBool:YES forKey:YTzoomRateMigratedKey];
    double migrated = YTzoomRateFollowApp;
    switch ([defaults integerForKey:YTzoomLegacyModeKey]) {
        case 1:
            migrated = YTzoomRateReuseLast;
            break;
        case 2: {
            double legacy = [defaults doubleForKey:YTzoomLegacyRateKey];
            if (YTzoomRateIsUsable(legacy)) {
                [defaults setDouble:legacy forKey:YTzoomCustomRateKey];
                migrated = YTzoomRateUseCustom;
            }
            break;
        }
        default:
            break;
    }
    [defaults setDouble:migrated forKey:YTzoomStartRateKey];
    return migrated;
}

static double YTzoomShortsRate(void) {
    const double rate =
        [NSUserDefaults.standardUserDefaults doubleForKey:YTzoomShortsRateKey];
    return YTzoomRateIsUsable(rate) ? rate : 0.0;
}

static BOOL YTzoomSourceUsesShortsRate(id source) {
    return YTzoomShortsRate() > 0.0 && source != nil && YTzoomPlayerIsShorts(source);
}

double YTzoomStartPlaybackRate(void) {
    const double configured = YTzoomConfiguredStartRate();
    if (configured == YTzoomRateReuseLast) {
        const double last = YTzoomLastPlayedRate();
        return last > 0.0 ? last : 1.0;
    }
    if (configured == YTzoomRateUseCustom) {
        const double custom =
            [NSUserDefaults.standardUserDefaults doubleForKey:YTzoomCustomRateKey];
        return YTzoomRateIsUsable(custom) ? custom : 1.0;
    }
    return YTzoomRateIsUsable(configured) ? configured : 1.0;
}

static BOOL YTzoomSpeedMenuStyle(void) {
    return [YTzoomPreferenceObject(@"YTzoom.Preference.Player.SpeedButtonStyle") integerValue] == 1;
}

static BOOL YTzoomRateCeilingRaised(void) {
    return YES;
}

static BOOL YTzoomDeliverRate(id target, NSString *name, double rate) {
    SEL selector = NSSelectorFromString(name);
    if (![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments != 3) return NO;

    NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
    call.target = target;
    call.selector = selector;

    const long long scaled = llround(rate * 100.0);
    switch ([signature getArgumentTypeAtIndex:2][0]) {
        case 'd': {
            double value = rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'f': {
            float value = (float)rate;
            [call setArgument:&value atIndex:2];
            break;
        }
        case '@': {
            id value = @(rate);
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'c': case 'C': {
            char value = (char)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 's': case 'S': {
            short value = (short)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'i': case 'I': {
            int value = (int)scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        case 'l': case 'L': case 'q': case 'Q': {
            long long value = scaled;
            [call setArgument:&value atIndex:2];
            break;
        }
        default:
            return NO;
    }
    [call invoke];
    return YES;
}

static NSString *YTzoomSpeedText(double rate) {
    if (fabs(rate - round(rate)) < 0.001) {
        return [NSString stringWithFormat:@"%.0fx", rate];
    }
    if (fabs(rate * 2.0 - round(rate * 2.0)) < 0.001) {
        return [NSString stringWithFormat:@"%.1fx", rate];
    }
    return [NSString stringWithFormat:@"%.2fx", rate];
}

static UIImage *YTzoomSpeedButtonImage(BOOL plus) {
    CGSize size = CGSizeMake(22.0, 22.0);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0.0);
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
    CGContextSetLineWidth(context, 2.0);
    CGContextAddEllipseInRect(context, CGRectInset((CGRect){CGPointZero, size}, 1.5, 1.5));
    CGContextMoveToPoint(context, 6.5, 11.0);
    CGContextAddLineToPoint(context, 15.5, 11.0);
    if (plus) {
        CGContextMoveToPoint(context, 11.0, 6.5);
        CGContextAddLineToPoint(context, 11.0, 15.5);
    }
    CGContextStrokePath(context);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

@interface YTzoomSpeedCoordinator : NSObject
+ (instancetype)sharedCoordinator;
@property(nonatomic, weak) UIView *overlay;
@property(nonatomic, weak) UIButton *valueButton;
@property(nonatomic, weak) id rateSource;
@property(nonatomic, copy) NSString *primedVideo;
@property(nonatomic, assign) double observedRate;
@property(nonatomic, readonly) double currentRate;
- (void)decrease;
- (void)increase;
- (void)reset;
- (void)valueTapped:(UIButton *)sender;
@end

@implementation YTzoomSpeedCoordinator

+ (instancetype)sharedCoordinator {
    static YTzoomSpeedCoordinator *coordinator;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        coordinator = [YTzoomSpeedCoordinator new];
    });
    return coordinator;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _observedRate = 0.0;
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(playbackTimeChanged:)
                   name:@"YTzoomPlaybackTimeDidChange"
                 object:nil];
        [NSNotificationCenter.defaultCenter
            addObserver:self
               selector:@selector(preferencesChanged:)
                   name:YTzoomPreferencesDidChangeNotification
                 object:nil];
    }
    return self;
}

- (double)rateFromObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return 0.0;
    }
    for (NSString *name in @[@"playbackRate", @"currentPlaybackRate", @"rate"]) {
        SEL selector = NSSelectorFromString(name);
        NSMethodSignature *signature = [object methodSignatureForSelector:selector];
        if (![object respondsToSelector:selector] || signature == nil) {
            continue;
        }
        const char *type = signature.methodReturnType;
        double rate = 0.0;
        if (type[0] == 'd') {
            rate = ((double (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == 'f') {
            rate = ((float (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (strchr("cislqCISLQ", type[0]) != NULL) {
            rate = ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
        } else if (type[0] == '@') {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if ([value respondsToSelector:@selector(doubleValue)]) {
                rate = [value doubleValue];
            }
        }
        if (isfinite(rate) && rate >= 0.25 && rate <= 5.0) {
            return rate;
        }
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController", @"player"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        double rate = [self rateFromObject:child depth:depth + 1];
        if (rate >= 0.25) {
            return rate;
        }
    }
    return 0.0;
}

- (NSString *)identifierForSource:(id)source {
    NSString *resolved = nil;
    for (NSString *probe in @[@"currentVideoID", @"videoID", @"videoId"]) {
        SEL selector = NSSelectorFromString(probe);
        if (![source respondsToSelector:selector]) continue;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(source, selector);
        if (![candidate isKindOfClass:NSString.class]) continue;
        if ([candidate length] == 0) continue;
        resolved = candidate;
        break;
    }
    return resolved.length != 0 ? resolved : YTzoomLastVideoID();
}

- (BOOL)primeStartRateForSource:(id)source {
    NSString *identifier = [self identifierForSource:source];
    if (identifier.length == 0) return NO;
    if ([self.primedVideo isEqualToString:identifier]) return NO;
    self.primedVideo = identifier;

    const double target = YTzoomSourceUsesShortsRate(source)
        ? YTzoomShortsRate() : YTzoomStartPlaybackRate();
    if (!YTzoomRateIsUsable(target)) return NO;
    const double playing = [self rateFromObject:source depth:0];
    if (fabs(playing - target) < 0.01) return NO;

    [self setRate:target];
    return YES;
}

- (void)preferencesChanged:(NSNotification *)notification {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:YTzoomStartRateKey] &&
        ![key isEqualToString:YTzoomLegacyRateKey] &&
        ![key isEqualToString:YTzoomLegacyModeKey] &&
        ![key isEqualToString:YTzoomShortsRateKey]) {
        return;
    }
    self.primedVideo = nil;
    id source = self.rateSource;
    if ([self rateFromObject:source depth:0] >= 0.25) {
        [self primeStartRateForSource:source];
    }
}

- (void)playbackTimeChanged:(NSNotification *)notification {
    self.rateSource = notification.object;
    if ([self primeStartRateForSource:notification.object]) {
        return;
    }
    double rate = [self rateFromObject:notification.object depth:0];
    if (rate < 0.25) {
        AVPlayer *player = self.activePlayer;
        if (player.rate >= 0.25f) {
            rate = player.rate;
        }
    }
    if (rate < 0.25 || rate > 5.0) {
        return;
    }
    self.observedRate = rate;
    if (!YTzoomSourceUsesShortsRate(notification.object)) {
        [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                               forKey:YTzoomLastRateKey];
    }
    [self.valueButton setTitle:YTzoomSpeedText(rate)
                      forState:UIControlStateNormal];
}

- (id)eventsDelegate {
    SEL selector = NSSelectorFromString(@"eventsDelegate");
    if ([self.overlay respondsToSelector:selector]) {
        return ((id (*)(id, SEL))objc_msgSend)(self.overlay, selector);
    }
    return nil;
}

- (double)currentRate {
    if (isfinite(self.observedRate) && self.observedRate >= 0.25 &&
        self.observedRate <= 5.0) {
        return self.observedRate;
    }
    double saved = YTzoomLastPlayedRate();
    return saved >= 0.25 ? saved : 1.0;
}

- (AVPlayer *)activePlayerInLayer:(CALayer *)layer {
    if ([layer isKindOfClass:AVPlayerLayer.class]) {
        AVPlayer *player = ((AVPlayerLayer *)layer).player;
        if (player != nil) {
            return player;
        }
    }
    for (CALayer *child in layer.sublayers) {
        AVPlayer *player = [self activePlayerInLayer:child];
        if (player != nil) {
            return player;
        }
    }
    return nil;
}

- (AVPlayer *)activePlayer {
    UIView *root = self.overlay;
    while (root.superview != nil) {
        root = root.superview;
    }
    return [self activePlayerInLayer:root.layer];
}

- (BOOL)applyRate:(double)rate toObject:(id)object depth:(NSUInteger)depth {
    if (object == nil || depth > 2) {
        return NO;
    }
    if (YTzoomDeliverRate(object, @"setPlaybackRate:", rate)) {
        return YES;
    }
    if (depth == 0 && YTzoomDeliverRate(object, @"setRate:", rate)) {
        return YES;
    }
    for (NSString *name in @[@"eventsDelegate", @"playbackController",
                              @"playerController"]) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) {
            continue;
        }
        id child = ((id (*)(id, SEL))objc_msgSend)(object, selector);
        if (child == object) {
            continue;
        }
        if ([self applyRate:rate toObject:child depth:depth + 1]) {
            return YES;
        }
    }
    return NO;
}

- (void)setRate:(double)rate {
    rate = MIN(5.0, MAX(0.25, rate));
    if (![self applyRate:rate toObject:self.eventsDelegate depth:0]) {
        [self applyRate:rate toObject:self.rateSource depth:0];
    }
    if (!YTzoomSourceUsesShortsRate(self.rateSource)) {
        [NSUserDefaults.standardUserDefaults setFloat:(float)rate
                                               forKey:YTzoomLastRateKey];
    }
    self.observedRate = rate;
    [self.valueButton setTitle:YTzoomSpeedText(rate)
                      forState:UIControlStateNormal];
}

- (void)decrease {
    [self setRate:(ceil(self.currentRate * 4.0 - 0.001) - 1.0) / 4.0];
}

- (void)increase {
    [self setRate:(floor(self.currentRate * 4.0 + 0.001) + 1.0) / 4.0];
}

- (void)reset {
    [self setRate:1.0];
}

- (void)valueTapped:(UIButton *)sender {
    if (!YTzoomSpeedMenuStyle()) {
        [self reset];
        return;
    }
    SEL open = NSSelectorFromString(@"didPressVarispeed:");
    for (UIResponder *responder = self.overlay; responder != nil;
         responder = responder.nextResponder) {
        if ([responder respondsToSelector:open]) {
            ((void (*)(id, SEL, id))objc_msgSend)(responder, open, sender);
            return;
        }
    }
    [self reset];
}

@end

static IMP YTzoomMaximumOriginal(id receiver, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
        NSStringFromClass([receiver class]), NSStringFromSelector(selector)];
    return (IMP)(uintptr_t)YTzoomMaximumRateOriginals[key].unsignedLongLongValue;
}

static double YTzoomMaximumPlaybackRateDouble(id receiver, SEL selector) {
    if (YTzoomRateCeilingRaised()) {
        return 5.0;
    }
    IMP original = YTzoomMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0
        : ((double (*)(id, SEL))original)(receiver, selector);
}

static float YTzoomMaximumPlaybackRateFloat(id receiver, SEL selector) {
    if (YTzoomRateCeilingRaised()) {
        return 5.0f;
    }
    IMP original = YTzoomMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2.0f
        : ((float (*)(id, SEL))original)(receiver, selector);
}

static NSInteger YTzoomMaximumPlaybackRateInteger(id receiver, SEL selector) {
    if (YTzoomRateCeilingRaised()) {
        return 500;
    }
    IMP original = YTzoomMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSInteger (*)(id, SEL))original)(receiver, selector);
}

static NSUInteger YTzoomMaximumPlaybackRateUnsigned(id receiver, SEL selector) {
    if (YTzoomRateCeilingRaised()) {
        return 500;
    }
    IMP original = YTzoomMaximumOriginal(receiver, selector);
    return original == NULL
        ? 2
        : ((NSUInteger (*)(id, SEL))original)(receiver, selector);
}

static void YTzoomInstallMaximumRateHook(NSString *className,
                                         NSString *selectorName) {
    Class cls = NSClassFromString(className);
    Method method = class_getInstanceMethod(
        cls,
        NSSelectorFromString(selectorName)
    );
    if (method == NULL) {
        return;
    }
    char returnType[16] = {};
    method_getReturnType(method, returnType, sizeof(returnType));
    IMP replacement = NULL;
    if (strcmp(returnType, @encode(float)) == 0) {
        replacement = (IMP)YTzoomMaximumPlaybackRateFloat;
    } else if (strcmp(returnType, @encode(double)) == 0) {
        replacement = (IMP)YTzoomMaximumPlaybackRateDouble;
    } else if (strcmp(returnType, @encode(NSInteger)) == 0 ||
               strcmp(returnType, @encode(int)) == 0) {
        replacement = (IMP)YTzoomMaximumPlaybackRateInteger;
    } else if (strcmp(returnType, @encode(NSUInteger)) == 0 ||
               strcmp(returnType, @encode(unsigned int)) == 0) {
        replacement = (IMP)YTzoomMaximumPlaybackRateUnsigned;
    }
    if (replacement != NULL) {
        IMP original = NULL;
        if (YTzoomInstallInstanceHook(className,
                                      selectorName,
                                      replacement,
                                      &original)) {
            NSString *key = [NSString stringWithFormat:@"%@|%@",
                className, selectorName];
            YTzoomMaximumRateOriginals[key] = @((uintptr_t)original);
        }
    }
}

static void YTzoomInstallMaximumRateHooks(void) {
    YTzoomMaximumRateOriginals = [NSMutableDictionary dictionary];
    for (NSString *name in YTzoomAppClassNames()) {
        BOOL candidate = [name containsString:@"GranularVariableSpeedConfig"] ||
            [name containsString:@"PlayerHotConfig"];
        if (!candidate) {
            continue;
        }
        Class cls = NSClassFromString(name);
        if (cls == Nil) {
            continue;
        }
        for (NSString *selector in @[@"maximumPlaybackRate", @"maxPlaybackRate"]) {
            if (class_getInstanceMethod(cls,
                                        NSSelectorFromString(selector)) != NULL) {
                YTzoomInstallMaximumRateHook(name, selector);
            }
        }
    }

}

static NSString *const YTzoomHoldSpeedKey =
    @"YTzoom.Preference.Player.HoldSpeedEnabled";
static NSString *const YTzoomHoldSpeedRateKey =
    @"YTzoom.Preference.Player.HoldSpeedRate";


static IMP OriginalSpeedmasterActivated;
static IMP OriginalSpeedmasterLongPress;

static double YTzoomHoldPreviousRate;
static BOOL YTzoomHoldOverrideActive;
static BOOL YTzoomHoldPillActive;

static void YTzoomRestoreHoldRate(void);

static void YTzoomApplyHoldRate(NSString *source) {
    const BOOL on = YTzoomFeatureEnabled(YTzoomHoldSpeedKey);
    const double stored =
        [YTzoomPreferenceObject(YTzoomHoldSpeedRateKey) doubleValue];
    (void)source;
    if (!on || stored < 0.25 || stored > 5.0) return;
    if (!YTzoomHoldOverrideActive) {
        const double base = [YTzoomSpeedCoordinator sharedCoordinator].currentRate;
        YTzoomHoldPreviousRate =
            (base >= 0.25 && base <= 5.0) ? base : 1.0;
        YTzoomHoldOverrideActive = YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTzoomSpeedCoordinator sharedCoordinator] setRate:stored];
    });
}

static void YTzoomRestoreHoldRate(void) {
    if (!YTzoomHoldOverrideActive) return;
    YTzoomHoldOverrideActive = NO;
    const double previous = YTzoomHoldPreviousRate;
    YTzoomHoldPreviousRate = 0.0;
    if (previous < 0.25 || previous > 5.0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YTzoomSpeedCoordinator sharedCoordinator] setRate:previous];
    });
}

static void YTzoomSpeedmasterActivated(id receiver, SEL selector, BOOL active) {
    if (active) YTzoomHoldPillActive = YES;
    if (OriginalSpeedmasterActivated != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalSpeedmasterActivated)(receiver,
                                                                selector, active);
    }
    if (!active) {
        YTzoomHoldPillActive = NO;
        YTzoomRestoreHoldRate();
        return;
    }
    YTzoomApplyHoldRate(@"activated");
}

static void YTzoomSpeedmasterLongPress(id receiver, SEL selector,
                                       UILongPressGestureRecognizer *recognizer) {
    if (recognizer.state == UIGestureRecognizerStateBegan) YTzoomHoldPillActive = YES;
    if (OriginalSpeedmasterLongPress != NULL) {
        ((void (*)(id, SEL, id))OriginalSpeedmasterLongPress)(receiver, selector,
                                                              recognizer);
    }
    if (recognizer.state == UIGestureRecognizerStateBegan) {
        YTzoomApplyHoldRate(@"longpress");
        return;
    }
    if (recognizer.state == UIGestureRecognizerStateEnded ||
        recognizer.state == UIGestureRecognizerStateCancelled ||
        recognizer.state == UIGestureRecognizerStateFailed) {
        YTzoomHoldPillActive = NO;
        YTzoomRestoreHoldRate();
    }
}

static BOOL YTzoomLooksLikeSpeedPill(NSString *text) {
    if (text.length < 2 || ![text hasSuffix:@"x"]) return NO;
    NSString *number = [text substringToIndex:text.length - 1];
    NSCharacterSet *allowed =
        [NSCharacterSet characterSetWithCharactersInString:@"0123456789.,"];
    return [number stringByTrimmingCharactersInSet:allowed].length == 0;
}

static IMP OriginalTextNodeSetAttributedText;

static void YTzoomTextNodeSetAttributedText(id receiver, SEL selector,
                                            NSAttributedString *value) {
    NSAttributedString *replacement = value;
    NSString *text = [value isKindOfClass:NSAttributedString.class]
        ? value.string : nil;
    if (text.length != 0 && YTzoomHoldPillActive &&
        YTzoomFeatureEnabled(YTzoomHoldSpeedKey) && YTzoomLooksLikeSpeedPill(text)) {
        const double stored =
            [YTzoomPreferenceObject(YTzoomHoldSpeedRateKey) doubleValue];
        NSString *wanted = YTzoomSpeedText(stored);
        if (stored >= 0.25 && stored <= 5.0 && ![text isEqualToString:wanted]) {
            NSDictionary *attributes = value.length != 0
                ? [value attributesAtIndex:0 effectiveRange:NULL] : @{};
            replacement = [[NSAttributedString alloc] initWithString:wanted
                                                          attributes:attributes];
        }
    }
    if (OriginalTextNodeSetAttributedText != NULL) {
        ((void (*)(id, SEL, id))OriginalTextNodeSetAttributedText)(
            receiver, selector, replacement);
    }
}

static void YTzoomInstallHoldSpeedHooks(void) {
    const BOOL node = YTzoomInstallInstanceHook(
        @"ELMTextNode", @"setAttributedText:",
        (IMP)YTzoomTextNodeSetAttributedText, &OriginalTextNodeSetAttributedText);
    const BOOL press = YTzoomInstallInstanceHook(
        @"YTSpeedmasterController", @"speedmasterDidLongPressWithRecognizer:",
        (IMP)YTzoomSpeedmasterLongPress, &OriginalSpeedmasterLongPress);
    const BOOL activated = YTzoomInstallInstanceHook(
        @"YTSpeedmasterController", @"setIsSpeedmasterActivated:",
        (IMP)YTzoomSpeedmasterActivated, &OriginalSpeedmasterActivated);
    (void)node;
    (void)activated;
    (void)press;
}

static IMP OriginalVarispeedInit;

static id YTzoomVarispeedInit(id receiver, SEL selector) {
    id controller = ((id (*)(id, SEL))OriginalVarispeedInit)(receiver, selector);
    if (controller == nil || !YTzoomRateCeilingRaised()) return controller;
    Class optionClass = NSClassFromString(@"YTVarispeedSwitchControllerOption");
    SEL initializer = NSSelectorFromString(@"initWithTitle:rate:");
    if (optionClass == Nil || ![optionClass instancesRespondToSelector:initializer]) return controller;
    NSMutableDictionary<NSNumber *, NSString *> *titles = [NSMutableDictionary dictionary];
    id existing = [controller valueForKey:@"_options"];
    for (id option in [existing isKindOfClass:NSArray.class] ? existing : @[]) {
        if (![option respondsToSelector:@selector(rate)]) continue;
        const float rate = ((float (*)(id, SEL))objc_msgSend)(option, @selector(rate));
        id title = [option respondsToSelector:@selector(title)] ? [option valueForKey:@"title"] : nil;
        if ([title isKindOfClass:NSString.class]) titles[@(llroundf(rate * 100.0f))] = title;
    }
    static const float rates[] = {0.25f, 0.5f, 0.75f, 1.0f, 1.25f, 1.5f, 1.75f, 2.0f,
                                  2.5f, 3.0f, 3.5f, 4.0f, 4.5f, 5.0f};
    NSMutableArray *options = [NSMutableArray array];
    for (size_t index = 0; index < sizeof(rates) / sizeof(rates[0]); index++) {
        NSString *title = titles[@(llroundf(rates[index] * 100.0f))] ?: YTzoomSpeedText(rates[index]);
        id option = ((id (*)(id, SEL, id, float))objc_msgSend)(
            [optionClass alloc], initializer, title, rates[index]);
        if (option != nil) [options addObject:option];
    }
    if (options.count != 0) [controller setValue:[options copy] forKey:@"_options"];
    return controller;
}

static id YTzoomSpeedValue(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

void YTzoomRouteSpeedMenuItem(id renderers, id actions, UIView *view, id responder) {
    SEL open = NSSelectorFromString(@"didPressVarispeed:");
    SEL extensionSelector = NSSelectorFromString(@"messageForFieldNumber:");
    if (![renderers isKindOfClass:NSArray.class] || ![actions isKindOfClass:NSArray.class] ||
        ![responder respondsToSelector:open]) {
        return;
    }
    NSArray *items = renderers;
    NSArray *built = actions;
    for (NSUInteger index = 0; index < items.count && index < built.count; index++) {
        id options = YTzoomSpeedValue(YTzoomSpeedValue(items[index], @"elementRenderer"), @"compatibilityOptions");
        if (![options respondsToSelector:extensionSelector]) continue;
        id extension = ((id (*)(id, SEL, NSUInteger))objc_msgSend)(options, extensionSelector, 396644439);
        id identifier = YTzoomSpeedValue(extension, @"menuItemIdentifier");
        if (![identifier isKindOfClass:NSString.class] ||
            ![identifier isEqualToString:@"menu_item_playback_speed"]) {
            continue;
        }
        id action = built[index];
        SEL setHandler = NSSelectorFromString(@"setHandler:");
        if (![action respondsToSelector:setHandler]) return;
        __weak id weakResponder = responder;
        __weak UIView *weakView = view;
        dispatch_block_t handler = ^{
            id target = weakResponder;
            if ([target respondsToSelector:open]) {
                ((void (*)(id, SEL, id))objc_msgSend)(target, open, weakView);
            }
        };
        ((void (*)(id, SEL, id))objc_msgSend)(action, setHandler, handler);
        @try {
            UIView *elementView = [YTzoomSpeedValue(action, @"button") valueForKey:@"_elementView"];
            if ([elementView isKindOfClass:UIView.class]) elementView.userInteractionEnabled = NO;
        } @catch (__unused NSException *exception) {
        }
        return;
    }
}

void YTzoomInstallSpeedHooks(void) {
    YTzoomInstallInstanceHook(@"YTVarispeedSwitchControllerImpl", @"init",
                              (IMP)YTzoomVarispeedInit, &OriginalVarispeedInit);
    YTzoomInstallHoldSpeedHooks();
    if (YTzoomRateCeilingRaised()) {
        YTzoomInstallMaximumRateHooks();
    }
    (void)YTzoomSpeedCoordinator.sharedCoordinator;

    YTzoomRegisterOverlayConfigurator(@"speed", ^(UIView *overlay, UIStackView *stack) {
        YTzoomSpeedCoordinator *coordinator = YTzoomSpeedCoordinator.sharedCoordinator;
        coordinator.overlay = overlay;

        UIButton *minus = YTzoomOverlayButton(
            stack,
            @"YTzoom Slower",
            @"minus.circle",
            coordinator,
            @selector(decrease)
        );
        UIButton *value = YTzoomOverlayButton(
            stack,
            @"YTzoom Speed",
            @"speedometer",
            coordinator,
            @selector(valueTapped:)
        );
        UIButton *plus = YTzoomOverlayButton(
            stack,
            @"YTzoom Faster",
            @"plus.circle",
            coordinator,
            @selector(increase)
        );
        [minus setImage:YTzoomSpeedButtonImage(NO) forState:UIControlStateNormal];
        [plus setImage:YTzoomSpeedButtonImage(YES) forState:UIControlStateNormal];
        coordinator.valueButton = value;
        [value setTitle:YTzoomSpeedText(coordinator.currentRate)
               forState:UIControlStateNormal];
        [value setImage:nil forState:UIControlStateNormal];
        [value setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        value.titleLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
        for (NSLayoutConstraint *constraint in value.constraints) {
            if (constraint.firstAttribute == NSLayoutAttributeWidth) {
                constraint.active = NO;
            }
        }
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:52.0].active = YES;
        value.titleLabel.adjustsFontSizeToFitWidth = NO;
        value.titleLabel.lineBreakMode = NSLineBreakByClipping;
        [value sizeToFit];

        BOOL hidden = !YTzoomFeatureEnabled(YTzoomSpeedKey);
        minus.hidden = hidden || YTzoomSpeedMenuStyle();
        value.hidden = hidden;
        plus.hidden = hidden || YTzoomSpeedMenuStyle();
    });
}
