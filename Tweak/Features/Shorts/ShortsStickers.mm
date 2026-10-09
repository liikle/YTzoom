#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

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

static id YTKACEStickerIvar(UIView *sticker, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(sticker), name);
    const char *type = ivar != NULL ? ivar_getTypeEncoding(ivar) : NULL;
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(sticker, ivar);
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

static void YTKACEStickerPreferencesChanged(NSNotification *notification) {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:YTKACEInvisibleStickersKey] &&
        ![key isEqualToString:YTKACEMasterEnabledKey]) {
        return;
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

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTKACEPreferencesDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    YTKACEStickerPreferencesChanged(notification);
                }];
}
