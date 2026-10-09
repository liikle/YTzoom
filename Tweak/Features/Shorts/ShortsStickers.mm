#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "../../UI/Notice.h"

#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <float.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Shorts editor stickers (verified against YouTube 21.40.5):
// - Interactive stickers are YTCreationBaseInteractiveStickerView subclasses
//   (poll, quiz, prompt, product, video response, ...) and
//   YTCreationCommentStickerView. YouTube's own test for "interactive" is
//   -[UIView isInteractiveStickerCategory].
// - What viewers see is a snapshot of the sticker's content view
//   (renderStickerImage: / -[UIView yt_renderImage]) burned into the exported
//   video by the media engine. The tappable part is uploaded separately as
//   positionable layer metadata built from the view's transform.
// - Stickers whose -skipBurnIn is YES are left out of the exported video by
//   YouTube itself (interactiveStickerViewsToHideForUpload), while their
//   metadata is still uploaded.
// - Pinch scale is clamped by TOKOverlayGestureManager to the view's
//   -stickerScaleLimit, which is 0.5x-1.5x (0.7x-1.5x for products).

static NSString *const YTKACEInvisibleStickersKey =
    @"YTKACE.Preference.Shorts.InvisibleStickers";
static NSString *const YTKACEStickerMaxScaleKey =
    @"YTKACE.Preference.Shorts.StickerMaxScale";

static const void *YTKACEStickerAlphaAssociation = &YTKACEStickerAlphaAssociation;
static NSHashTable<UIView *> *YTKACEStickerViews;
static NSHashTable<UIView *> *YTKACEStickerToolbelts;
static const void *YTKACEStickerToggleAssociation = &YTKACEStickerToggleAssociation;

@protocol YTKACEStickerScaleLimit <NSObject>
- (instancetype)initWithMinScale:(double)minScale maxScale:(double)maxScale;
- (double)minScale;
- (double)maxScale;
@end

static BOOL YTKACEStickersInvisible(void) {
    return YTKACEFeatureEnabled(YTKACEInvisibleStickersKey);
}

static BOOL YTKACEIsInteractiveSticker(UIView *view) {
    static Class baseClass;
    static Class commentClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        baseClass = NSClassFromString(@"YTCreationBaseInteractiveStickerView");
        commentClass = NSClassFromString(@"YTCreationCommentStickerView");
    });
    if (view == nil) return NO;
    if (!(baseClass != Nil && [view isKindOfClass:baseClass]) &&
        !(commentClass != Nil && [view isKindOfClass:commentClass])) {
        return NO;
    }
    SEL selector = NSSelectorFromString(@"isInteractiveStickerCategory");
    return [view respondsToSelector:selector] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(view, selector);
}

static id YTKACEStickerIvar(id object, const char *name) {
    if (object == nil) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *type = ivar != NULL ? ivar_getTypeEncoding(ivar) : NULL;
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

// The view YouTube snapshots for the sticker's appearance.
static UIView *YTKACEStickerContentView(UIView *sticker) {
    id content = nil;
    SEL selector = NSSelectorFromString(@"contentView");
    if ([sticker respondsToSelector:selector]) {
        content = ((id (*)(id, SEL))objc_msgSend)(sticker, selector);
    } else {
        content = YTKACEStickerIvar(sticker, "_contentView");
    }
    if (![content isKindOfClass:UIView.class] || content == sticker) return nil;
    return content;
}

static UIView *YTKACEStickerOwningView(UIView *view) {
    if (YTKACEIsInteractiveSticker(view)) return view;
    UIView *candidate = view.superview;
    for (NSInteger depth = 0; candidate != nil && depth < 4; depth++) {
        if (YTKACEIsInteractiveSticker(candidate)) {
            return YTKACEStickerContentView(candidate) == view ? candidate : nil;
        }
        candidate = candidate.superview;
    }
    return nil;
}

static UIImage *YTKACETransparentImage(UIImage *source) {
    if (source == nil || source.size.width <= 0.0 || source.size.height <= 0.0) {
        return source;
    }
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = source.scale;
    format.opaque = NO;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:source.size format:format];
    return [renderer imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {}];
}

// While the sticker sits in YouTube's text entry sheet it stays visible so the
// question and options can be typed.
static BOOL YTKACEStickerBeingEdited(UIView *sticker) {
    Class editorView = NSClassFromString(@"YTCreationInteractiveStickerEditorView");
    if (editorView == Nil) return NO;
    for (UIView *view = sticker.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:editorView]) return YES;
    }
    return NO;
}

static void YTKACESetStickerPartHidden(id part, BOOL hidden) {
    BOOL isView = [part isKindOfClass:UIView.class];
    if (!isView && ![part isKindOfClass:CALayer.class]) return;
    NSNumber *saved = objc_getAssociatedObject(part, YTKACEStickerAlphaAssociation);
    if (hidden) {
        if (saved == nil) {
            double alpha = isView ? ((UIView *)part).alpha : ((CALayer *)part).opacity;
            objc_setAssociatedObject(part, YTKACEStickerAlphaAssociation, @(alpha),
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (isView) {
            ((UIView *)part).alpha = 0.0;
        } else {
            ((CALayer *)part).opacity = 0.0f;
        }
    } else if (saved != nil) {
        if (isView) {
            ((UIView *)part).alpha = saved.doubleValue;
        } else {
            ((CALayer *)part).opacity = saved.floatValue;
        }
        objc_setAssociatedObject(part, YTKACEStickerAlphaAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Hides only the drawn content. The sticker view keeps its frame, transform,
// alpha and gestures, so selecting, moving and pinching keep working.
static void YTKACEApplyStickerVisibility(UIView *sticker) {
    if (!YTKACEIsInteractiveSticker(sticker)) return;
    [YTKACEStickerViews addObject:sticker];
    BOOL hidden = YTKACEStickersInvisible() && !YTKACEStickerBeingEdited(sticker);
    YTKACESetStickerPartHidden(YTKACEStickerContentView(sticker), hidden);
    YTKACESetStickerPartHidden(YTKACEStickerIvar(sticker, "_shadowLayer"), hidden);
}

// Only read when the editor builds the list of stickers to leave out of an
// upload or a save to Photos. If YouTube already returns YES for a sticker
// type, viewers' apps draw that sticker themselves and the uploader can't hide it.
static BOOL YTKACEStickerSkipBurnIn(id self, SEL _cmd, IMP original) {
    BOOL native = original != NULL && ((BOOL (*)(id, SEL))original)(self, _cmd);
    if (!YTKACEStickersInvisible() || !YTKACEIsInteractiveSticker(self)) return native;
    YTKACEDownloadLog(@"stickers", @"%@ left out of export (YouTube skipBurnIn %@)",
                      NSStringFromClass([self class]), native ? @"YES" : @"NO");
    return YES;
}

static double YTKACEStickerMaxScale(void) {
    if (!YTKACEMasterEnabled()) return 0.0;
    id stored = YTKACEPreferenceObject(YTKACEStickerMaxScaleKey);
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 0.0;
    return value < 0.0 ? DBL_MAX : value;
}

// Keeps YouTube's minimum and only raises the maximum. A nil limit means
// YouTube applies no clamp to this sticker, so it is returned unchanged.
static id YTKACEStickerScaleLimit(id self, SEL _cmd, IMP original) {
    id<YTKACEStickerScaleLimit> limit = original != NULL
        ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
    double requested = YTKACEStickerMaxScale();
    if (limit == nil || requested <= 0.0 ||
        ![limit respondsToSelector:@selector(minScale)] ||
        ![limit respondsToSelector:@selector(maxScale)]) {
        return limit;
    }
    if (requested <= [limit maxScale]) return limit;
    Class limitClass = [limit class];
    if (![limitClass instancesRespondToSelector:@selector(initWithMinScale:maxScale:)]) {
        return limit;
    }
    return [[limitClass alloc] initWithMinScale:[limit minScale] maxScale:requested] ?: limit;
}

static void YTKACEStickerViewChanged(UIView *self, SEL _cmd, IMP original) {
    if (original != NULL) ((void (*)(id, SEL))original)(self, _cmd);
    YTKACEApplyStickerVisibility(self);
}

#define YTKACE_STICKER_VIEW_HOOKS(Suffix)                                     \
    static IMP YTKACEOrigSkipBurnIn##Suffix;                                   \
    static IMP YTKACEOrigScaleLimit##Suffix;                                   \
    static IMP YTKACEOrigLayout##Suffix;                                       \
    static IMP YTKACEOrigMove##Suffix;                                         \
    static BOOL YTKACESkipBurnIn##Suffix(id self, SEL _cmd) {                  \
        return YTKACEStickerSkipBurnIn(self, _cmd, YTKACEOrigSkipBurnIn##Suffix); \
    }                                                                          \
    static id YTKACEScaleLimit##Suffix(id self, SEL _cmd) {                    \
        return YTKACEStickerScaleLimit(self, _cmd, YTKACEOrigScaleLimit##Suffix); \
    }                                                                          \
    static void YTKACELayout##Suffix(UIView *self, SEL _cmd) {                 \
        YTKACEStickerViewChanged(self, _cmd, YTKACEOrigLayout##Suffix);        \
    }                                                                          \
    static void YTKACEMove##Suffix(UIView *self, SEL _cmd) {                   \
        YTKACEStickerViewChanged(self, _cmd, YTKACEOrigMove##Suffix);          \
    }

YTKACE_STICKER_VIEW_HOOKS(Base)
YTKACE_STICKER_VIEW_HOOKS(Comment)

static IMP YTKACEOrigScaleLimitProduct;
static id YTKACEScaleLimitProduct(id self, SEL _cmd) {
    return YTKACEStickerScaleLimit(self, _cmd, YTKACEOrigScaleLimitProduct);
}

// Every sticker image YouTube produces goes through here: the editor preview
// and timeline snapshots (renderStickerImage:) and the PNGs handed to the
// export session (renderedStickerURLsWithMediaSize:). The image keeps its size
// and scale so all geometry derived from it stays the same.
static IMP YTKACEOrigRenderImage;
static UIImage *YTKACERenderImage(UIView *self, SEL _cmd) {
    UIImage *image = YTKACEOrigRenderImage != NULL
        ? ((UIImage *(*)(id, SEL))YTKACEOrigRenderImage)(self, _cmd) : nil;
    if (image == nil || !YTKACEStickersInvisible() ||
        YTKACEStickerOwningView(self) == nil) {
        return image;
    }
    return YTKACETransparentImage(image);
}

// The AI image sticker draws its snapshot itself instead of using yt_renderImage.
static IMP YTKACEOrigTextToImageRender;
static void YTKACETextToImageRender(UIView *self, SEL _cmd, void (^completion)(UIImage *)) {
    void (^handler)(UIImage *) = completion;
    if (completion != nil && YTKACEStickersInvisible() && YTKACEIsInteractiveSticker(self)) {
        handler = ^(UIImage *image) {
            completion(YTKACETransparentImage(image));
        };
    }
    ((void (*)(id, SEL, id))YTKACEOrigTextToImageRender)(self, _cmd, handler);
}

// Toggle under the Shorts editor's tool rail (YTCreationToolbeltView with the
// "YTCreationToolbelt.editor" identifier). The rail clips to its bounds, so
// the button lives in the rail's superview and follows its frame and alpha.
@interface YTKACEStickerToggleTarget : NSObject
+ (instancetype)sharedTarget;
- (void)toggleTapped:(UIButton *)sender;
@end

@implementation YTKACEStickerToggleTarget
+ (instancetype)sharedTarget {
    static YTKACEStickerToggleTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTKACEStickerToggleTarget new]; });
    return target;
}
- (void)toggleTapped:(__unused UIButton *)sender {
    BOOL invisible = !YTKACEStickersInvisible();
    YTKACESetPreference(YTKACEInvisibleStickersKey, invisible);
    YTKACEShowNotice(YTKACELocalized(invisible ? @"Stickers are invisible" : @"Stickers are visible"));
}
@end

static BOOL YTKACEIsShortsEditorToolbelt(UIView *toolbelt) {
    UIResponder *controller = toolbelt.nextResponder;
    if (![controller isKindOfClass:UIViewController.class]) return NO;
    NSString *identifier = YTKACEStickerIvar(controller, "_toolbeltIdentifier");
    if (![identifier isKindOfClass:NSString.class] ||
        ![identifier isEqualToString:@"YTCreationToolbelt.editor"]) {
        return NO;
    }
    Class editor = NSClassFromString(@"YTShortsEditorViewController");
    UIViewController *parent = ((UIViewController *)controller).parentViewController;
    for (NSInteger depth = 0; parent != nil && depth < 4; depth++) {
        if (editor != Nil && [parent isKindOfClass:editor]) return YES;
        parent = parent.parentViewController;
    }
    return NO;
}

static void YTKACEStyleStickerToggle(UIButton *button) {
    BOOL invisible = YTKACEStickersInvisible();
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:invisible ? @"eye.slash" : @"eye"
                             withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.accessibilityLabel = YTKACELocalized(@"Invisible Interactive Stickers");
    button.accessibilityValue = YTKACELocalized(invisible ? @"On" : @"Off");
}

static void YTKACESyncStickerToggle(UIView *toolbelt) {
    UIButton *button = objc_getAssociatedObject(toolbelt, YTKACEStickerToggleAssociation);
    UIView *host = toolbelt.superview;
    if (!YTKACEMasterEnabled() || host == nil || !YTKACEIsShortsEditorToolbelt(toolbelt)) {
        [button removeFromSuperview];
        return;
    }
    if (button == nil) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        button.clipsToBounds = YES;
        [button addTarget:[YTKACEStickerToggleTarget sharedTarget]
                   action:@selector(toggleTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(toolbelt, YTKACEStickerToggleAssociation, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [YTKACEStickerToolbelts addObject:toolbelt];
    }
    if (button.superview != host) {
        [host insertSubview:button aboveSubview:toolbelt];
    }
    UIView *pill = YTKACEStickerIvar(toolbelt, "_toolbeltBackgroundView");
    CGRect anchor = [pill isKindOfClass:UIView.class] && !CGRectIsEmpty(pill.bounds)
        ? [pill convertRect:pill.bounds toView:host]
        : [toolbelt convertRect:toolbelt.bounds toView:host];
    CGFloat side = MIN(48.0, MAX(36.0, CGRectGetWidth(anchor)));
    button.frame = CGRectMake(round(CGRectGetMidX(anchor) - side / 2.0),
                              round(CGRectGetMaxY(anchor) + 10.0), side, side);
    button.layer.cornerRadius = side / 2.0;
    button.hidden = toolbelt.hidden;
    button.alpha = toolbelt.alpha;
    YTKACEStyleStickerToggle(button);
}

static IMP YTKACEOrigToolbeltLayout;
static void YTKACEToolbeltLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTKACEOrigToolbeltLayout)(self, _cmd);
    YTKACESyncStickerToggle(self);
}

static IMP YTKACEOrigToolbeltMove;
static void YTKACEToolbeltMove(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTKACEOrigToolbeltMove)(self, _cmd);
    YTKACESyncStickerToggle(self);
}

static IMP YTKACEOrigToolbeltFrame;
static void YTKACEToolbeltFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))YTKACEOrigToolbeltFrame)(self, _cmd, frame);
    YTKACESyncStickerToggle(self);
}

static IMP YTKACEOrigToolbeltCenter;
static void YTKACEToolbeltCenter(UIView *self, SEL _cmd, CGPoint center) {
    ((void (*)(id, SEL, CGPoint))YTKACEOrigToolbeltCenter)(self, _cmd, center);
    YTKACESyncStickerToggle(self);
}

static IMP YTKACEOrigToolbeltAlpha;
static void YTKACEToolbeltAlpha(UIView *self, SEL _cmd, CGFloat alpha) {
    ((void (*)(id, SEL, CGFloat))YTKACEOrigToolbeltAlpha)(self, _cmd, alpha);
    YTKACESyncStickerToggle(self);
}

static IMP YTKACEOrigToolbeltHidden;
static void YTKACEToolbeltHidden(UIView *self, SEL _cmd, BOOL hidden) {
    ((void (*)(id, SEL, BOOL))YTKACEOrigToolbeltHidden)(self, _cmd, hidden);
    YTKACESyncStickerToggle(self);
}

static void YTKACEStickerPreferencesChanged(NSNotification *notification) {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:YTKACEInvisibleStickersKey] &&
        ![key isEqualToString:YTKACEMasterEnabledKey]) {
        return;
    }
    for (UIView *toolbelt in YTKACEStickerToolbelts.allObjects) {
        YTKACESyncStickerToggle(toolbelt);
    }
    SEL regenerate = NSSelectorFromString(@"forceSnapshotRegeneration");
    for (UIView *sticker in YTKACEStickerViews.allObjects) {
        YTKACEApplyStickerVisibility(sticker);
        if ([sticker respondsToSelector:regenerate]) {
            ((void (*)(id, SEL))objc_msgSend)(sticker, regenerate);
        }
        [sticker setNeedsLayout];
    }
}

static void YTKACEInstallStickerViewHooks(NSString *className,
                                          IMP skipBurnIn, IMP *originalSkipBurnIn,
                                          IMP scaleLimit, IMP *originalScaleLimit,
                                          IMP layout, IMP *originalLayout,
                                          IMP move, IMP *originalMove) {
    YTKACEInstallInstanceHook(className, @"skipBurnIn", skipBurnIn, originalSkipBurnIn);
    YTKACEInstallInstanceHook(className, @"stickerScaleLimit", scaleLimit, originalScaleLimit);
    YTKACEInstallInstanceHook(className, @"layoutSubviews", layout, originalLayout);
    YTKACEInstallInstanceHook(className, @"didMoveToSuperview", move, originalMove);
}

void YTKACEInstallShortsStickerHooks(void) {
    if (YTKACEStickerViews != nil) return;
    YTKACEStickerViews = [NSHashTable weakObjectsHashTable];
    YTKACEStickerToolbelts = [NSHashTable weakObjectsHashTable];

    YTKACEInstallStickerViewHooks(@"YTCreationBaseInteractiveStickerView",
        (IMP)YTKACESkipBurnInBase, &YTKACEOrigSkipBurnInBase,
        (IMP)YTKACEScaleLimitBase, &YTKACEOrigScaleLimitBase,
        (IMP)YTKACELayoutBase, &YTKACEOrigLayoutBase,
        (IMP)YTKACEMoveBase, &YTKACEOrigMoveBase);
    YTKACEInstallStickerViewHooks(@"YTCreationCommentStickerView",
        (IMP)YTKACESkipBurnInComment, &YTKACEOrigSkipBurnInComment,
        (IMP)YTKACEScaleLimitComment, &YTKACEOrigScaleLimitComment,
        (IMP)YTKACELayoutComment, &YTKACEOrigLayoutComment,
        (IMP)YTKACEMoveComment, &YTKACEOrigMoveComment);
    YTKACEInstallInstanceHook(@"YTCreationProductStickerView", @"stickerScaleLimit",
                              (IMP)YTKACEScaleLimitProduct, &YTKACEOrigScaleLimitProduct);

    YTKACEInstallInstanceHook(@"UIView", @"yt_renderImage",
                              (IMP)YTKACERenderImage, &YTKACEOrigRenderImage);
    YTKACEInstallInstanceHook(@"YTCreationTextToImageStickerView", @"renderStickerImage:",
                              (IMP)YTKACETextToImageRender, &YTKACEOrigTextToImageRender);

    NSString *toolbelt = @"YTCreationToolbeltView";
    YTKACEInstallInstanceHook(toolbelt, @"layoutSubviews",
                              (IMP)YTKACEToolbeltLayout, &YTKACEOrigToolbeltLayout);
    YTKACEInstallInstanceHook(toolbelt, @"didMoveToSuperview",
                              (IMP)YTKACEToolbeltMove, &YTKACEOrigToolbeltMove);
    YTKACEInstallInstanceHook(toolbelt, @"setFrame:",
                              (IMP)YTKACEToolbeltFrame, &YTKACEOrigToolbeltFrame);
    YTKACEInstallInstanceHook(toolbelt, @"setCenter:",
                              (IMP)YTKACEToolbeltCenter, &YTKACEOrigToolbeltCenter);
    YTKACEInstallInstanceHook(toolbelt, @"setAlpha:",
                              (IMP)YTKACEToolbeltAlpha, &YTKACEOrigToolbeltAlpha);
    YTKACEInstallInstanceHook(toolbelt, @"setHidden:",
                              (IMP)YTKACEToolbeltHidden, &YTKACEOrigToolbeltHidden);

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTKACEPreferencesDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    YTKACEStickerPreferencesChanged(notification);
                }];
}
