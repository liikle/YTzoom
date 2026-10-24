#import "../../YTzoom.h"
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

static NSString *const YTzoomInvisibleStickersKey =
    @"YTzoom.Preference.Shorts.InvisibleStickers";
static NSString *const YTzoomStickerMaxScaleKey =
    @"YTzoom.Preference.Shorts.StickerMaxScale";

static const void *YTzoomStickerAlphaAssociation = &YTzoomStickerAlphaAssociation;
static NSHashTable<UIView *> *YTzoomStickerViews;
static NSHashTable<UIView *> *YTzoomStickerToolbelts;
static const void *YTzoomStickerToggleAssociation = &YTzoomStickerToggleAssociation;

@protocol YTzoomStickerScaleLimit <NSObject>
- (instancetype)initWithMinScale:(double)minScale maxScale:(double)maxScale;
- (double)minScale;
- (double)maxScale;
@end

static BOOL YTzoomStickersInvisible(void) {
    return YTzoomFeatureEnabled(YTzoomInvisibleStickersKey);
}

static BOOL YTzoomIsInteractiveSticker(UIView *view) {
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

static id YTzoomStickerIvar(id object, const char *name) {
    if (object == nil) return nil;
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    const char *type = ivar != NULL ? ivar_getTypeEncoding(ivar) : NULL;
    if (type == NULL || type[0] != '@') return nil;
    return object_getIvar(object, ivar);
}

// The view YouTube snapshots for the sticker's appearance.
static UIView *YTzoomStickerContentView(UIView *sticker) {
    id content = nil;
    SEL selector = NSSelectorFromString(@"contentView");
    if ([sticker respondsToSelector:selector]) {
        content = ((id (*)(id, SEL))objc_msgSend)(sticker, selector);
    } else {
        content = YTzoomStickerIvar(sticker, "_contentView");
    }
    if (![content isKindOfClass:UIView.class] || content == sticker) return nil;
    return content;
}

static UIView *YTzoomStickerOwningView(UIView *view) {
    if (YTzoomIsInteractiveSticker(view)) return view;
    UIView *candidate = view.superview;
    for (NSInteger depth = 0; candidate != nil && depth < 4; depth++) {
        if (YTzoomIsInteractiveSticker(candidate)) {
            return YTzoomStickerContentView(candidate) == view ? candidate : nil;
        }
        candidate = candidate.superview;
    }
    return nil;
}

static UIImage *YTzoomTransparentImage(UIImage *source) {
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
static BOOL YTzoomStickerBeingEdited(UIView *sticker) {
    Class editorView = NSClassFromString(@"YTCreationInteractiveStickerEditorView");
    if (editorView == Nil) return NO;
    for (UIView *view = sticker.superview; view != nil; view = view.superview) {
        if ([view isKindOfClass:editorView]) return YES;
    }
    return NO;
}

static void YTzoomSetStickerPartHidden(id part, BOOL hidden) {
    BOOL isView = [part isKindOfClass:UIView.class];
    if (!isView && ![part isKindOfClass:CALayer.class]) return;
    NSNumber *saved = objc_getAssociatedObject(part, YTzoomStickerAlphaAssociation);
    if (hidden) {
        if (saved == nil) {
            double alpha = isView ? ((UIView *)part).alpha : ((CALayer *)part).opacity;
            objc_setAssociatedObject(part, YTzoomStickerAlphaAssociation, @(alpha),
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
        objc_setAssociatedObject(part, YTzoomStickerAlphaAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// Hides only the drawn content. The sticker view keeps its frame, transform,
// alpha and gestures, so selecting, moving and pinching keep working.
static void YTzoomApplyStickerVisibility(UIView *sticker) {
    if (!YTzoomIsInteractiveSticker(sticker)) return;
    [YTzoomStickerViews addObject:sticker];
    BOOL hidden = YTzoomStickersInvisible() && !YTzoomStickerBeingEdited(sticker);
    YTzoomSetStickerPartHidden(YTzoomStickerContentView(sticker), hidden);
    YTzoomSetStickerPartHidden(YTzoomStickerIvar(sticker, "_shadowLayer"), hidden);
}

// Only read when the editor builds the list of stickers to leave out of an
// upload or a save to Photos. If YouTube already returns YES for a sticker
// type, viewers' apps draw that sticker themselves and the uploader can't hide it.
static BOOL YTzoomStickerSkipBurnIn(id self, SEL _cmd, IMP original) {
    BOOL native = original != NULL && ((BOOL (*)(id, SEL))original)(self, _cmd);
    if (!YTzoomStickersInvisible() || !YTzoomIsInteractiveSticker(self)) return native;
    YTzoomDownloadLog(@"stickers", @"%@ left out of export (YouTube skipBurnIn %@)",
                      NSStringFromClass([self class]), native ? @"YES" : @"NO");
    return YES;
}

static double YTzoomStickerMaxScale(void) {
    if (!YTzoomMasterEnabled()) return 0.0;
    id stored = YTzoomPreferenceObject(YTzoomStickerMaxScaleKey);
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 0.0;
    return value < 0.0 ? DBL_MAX : value;
}

// Keeps YouTube's minimum and only raises the maximum. A nil limit means
// YouTube applies no clamp to this sticker, so it is returned unchanged.
static id YTzoomStickerScaleLimit(id self, SEL _cmd, IMP original) {
    id<YTzoomStickerScaleLimit> limit = original != NULL
        ? ((id (*)(id, SEL))original)(self, _cmd) : nil;
    double requested = YTzoomStickerMaxScale();
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

static void YTzoomStickerViewChanged(UIView *self, SEL _cmd, IMP original) {
    if (original != NULL) ((void (*)(id, SEL))original)(self, _cmd);
    YTzoomApplyStickerVisibility(self);
}

#define YTzoom_STICKER_VIEW_HOOKS(Suffix)                                     \
    static IMP YTzoomOrigSkipBurnIn##Suffix;                                   \
    static IMP YTzoomOrigScaleLimit##Suffix;                                   \
    static IMP YTzoomOrigLayout##Suffix;                                       \
    static IMP YTzoomOrigMove##Suffix;                                         \
    static BOOL YTzoomSkipBurnIn##Suffix(id self, SEL _cmd) {                  \
        return YTzoomStickerSkipBurnIn(self, _cmd, YTzoomOrigSkipBurnIn##Suffix); \
    }                                                                          \
    static id YTzoomScaleLimit##Suffix(id self, SEL _cmd) {                    \
        return YTzoomStickerScaleLimit(self, _cmd, YTzoomOrigScaleLimit##Suffix); \
    }                                                                          \
    static void YTzoomLayout##Suffix(UIView *self, SEL _cmd) {                 \
        YTzoomStickerViewChanged(self, _cmd, YTzoomOrigLayout##Suffix);        \
    }                                                                          \
    static void YTzoomMove##Suffix(UIView *self, SEL _cmd) {                   \
        YTzoomStickerViewChanged(self, _cmd, YTzoomOrigMove##Suffix);          \
    }

YTzoom_STICKER_VIEW_HOOKS(Base)
YTzoom_STICKER_VIEW_HOOKS(Comment)

static IMP YTzoomOrigScaleLimitProduct;
static id YTzoomScaleLimitProduct(id self, SEL _cmd) {
    return YTzoomStickerScaleLimit(self, _cmd, YTzoomOrigScaleLimitProduct);
}

// Every sticker image YouTube produces goes through here: the editor preview
// and timeline snapshots (renderStickerImage:) and the PNGs handed to the
// export session (renderedStickerURLsWithMediaSize:). The image keeps its size
// and scale so all geometry derived from it stays the same.
static IMP YTzoomOrigRenderImage;
static UIImage *YTzoomRenderImage(UIView *self, SEL _cmd) {
    UIImage *image = YTzoomOrigRenderImage != NULL
        ? ((UIImage *(*)(id, SEL))YTzoomOrigRenderImage)(self, _cmd) : nil;
    if (image == nil || !YTzoomStickersInvisible() ||
        YTzoomStickerOwningView(self) == nil) {
        return image;
    }
    return YTzoomTransparentImage(image);
}

// The AI image sticker draws its snapshot itself instead of using yt_renderImage.
static IMP YTzoomOrigTextToImageRender;
static void YTzoomTextToImageRender(UIView *self, SEL _cmd, void (^completion)(UIImage *)) {
    void (^handler)(UIImage *) = completion;
    if (completion != nil && YTzoomStickersInvisible() && YTzoomIsInteractiveSticker(self)) {
        handler = ^(UIImage *image) {
            completion(YTzoomTransparentImage(image));
        };
    }
    ((void (*)(id, SEL, id))YTzoomOrigTextToImageRender)(self, _cmd, handler);
}

// Toggle under the Shorts editor's tool rail (YTCreationToolbeltView with the
// "YTCreationToolbelt.editor" identifier). The rail clips to its bounds, so
// the button lives in the rail's superview and follows its frame and alpha.
@interface YTzoomStickerToggleTarget : NSObject
+ (instancetype)sharedTarget;
- (void)toggleTapped:(UIButton *)sender;
@end

@implementation YTzoomStickerToggleTarget
+ (instancetype)sharedTarget {
    static YTzoomStickerToggleTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomStickerToggleTarget new]; });
    return target;
}
- (void)toggleTapped:(__unused UIButton *)sender {
    BOOL invisible = !YTzoomStickersInvisible();
    YTzoomSetPreference(YTzoomInvisibleStickersKey, invisible);
    YTzoomShowNotice(YTzoomLocalized(invisible ? @"Stickers are invisible" : @"Stickers are visible"));
}
@end

static BOOL YTzoomIsShortsEditorToolbelt(UIView *toolbelt) {
    UIResponder *controller = toolbelt.nextResponder;
    if (![controller isKindOfClass:UIViewController.class]) return NO;
    NSString *identifier = YTzoomStickerIvar(controller, "_toolbeltIdentifier");
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

static void YTzoomStyleStickerToggle(UIButton *button) {
    BOOL invisible = YTzoomStickersInvisible();
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:19.0
                                                        weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:invisible ? @"eye.slash" : @"eye"
                             withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.accessibilityLabel = YTzoomLocalized(@"Invisible Interactive Stickers");
    button.accessibilityValue = YTzoomLocalized(invisible ? @"On" : @"Off");
}

static void YTzoomSyncStickerToggle(UIView *toolbelt) {
    UIButton *button = objc_getAssociatedObject(toolbelt, YTzoomStickerToggleAssociation);
    UIView *host = toolbelt.superview;
    if (!YTzoomMasterEnabled() || host == nil || !YTzoomIsShortsEditorToolbelt(toolbelt)) {
        [button removeFromSuperview];
        return;
    }
    if (button == nil) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tintColor = UIColor.whiteColor;
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.4];
        button.clipsToBounds = YES;
        [button addTarget:[YTzoomStickerToggleTarget sharedTarget]
                   action:@selector(toggleTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(toolbelt, YTzoomStickerToggleAssociation, button,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [YTzoomStickerToolbelts addObject:toolbelt];
    }
    if (button.superview != host) {
        [host insertSubview:button aboveSubview:toolbelt];
    }
    UIView *pill = YTzoomStickerIvar(toolbelt, "_toolbeltBackgroundView");
    CGRect anchor = [pill isKindOfClass:UIView.class] && !CGRectIsEmpty(pill.bounds)
        ? [pill convertRect:pill.bounds toView:host]
        : [toolbelt convertRect:toolbelt.bounds toView:host];
    CGFloat side = MIN(48.0, MAX(36.0, CGRectGetWidth(anchor)));
    button.frame = CGRectMake(round(CGRectGetMidX(anchor) - side / 2.0),
                              round(CGRectGetMaxY(anchor) + 10.0), side, side);
    button.layer.cornerRadius = side / 2.0;
    button.hidden = toolbelt.hidden;
    button.alpha = toolbelt.alpha;
    YTzoomStyleStickerToggle(button);
}

static IMP YTzoomOrigToolbeltLayout;
static void YTzoomToolbeltLayout(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTzoomOrigToolbeltLayout)(self, _cmd);
    YTzoomSyncStickerToggle(self);
}

static IMP YTzoomOrigToolbeltMove;
static void YTzoomToolbeltMove(UIView *self, SEL _cmd) {
    ((void (*)(id, SEL))YTzoomOrigToolbeltMove)(self, _cmd);
    YTzoomSyncStickerToggle(self);
}

static IMP YTzoomOrigToolbeltFrame;
static void YTzoomToolbeltFrame(UIView *self, SEL _cmd, CGRect frame) {
    ((void (*)(id, SEL, CGRect))YTzoomOrigToolbeltFrame)(self, _cmd, frame);
    YTzoomSyncStickerToggle(self);
}

static IMP YTzoomOrigToolbeltCenter;
static void YTzoomToolbeltCenter(UIView *self, SEL _cmd, CGPoint center) {
    ((void (*)(id, SEL, CGPoint))YTzoomOrigToolbeltCenter)(self, _cmd, center);
    YTzoomSyncStickerToggle(self);
}

static IMP YTzoomOrigToolbeltAlpha;
static void YTzoomToolbeltAlpha(UIView *self, SEL _cmd, CGFloat alpha) {
    ((void (*)(id, SEL, CGFloat))YTzoomOrigToolbeltAlpha)(self, _cmd, alpha);
    YTzoomSyncStickerToggle(self);
}

static IMP YTzoomOrigToolbeltHidden;
static void YTzoomToolbeltHidden(UIView *self, SEL _cmd, BOOL hidden) {
    ((void (*)(id, SEL, BOOL))YTzoomOrigToolbeltHidden)(self, _cmd, hidden);
    YTzoomSyncStickerToggle(self);
}

static void YTzoomStickerPreferencesChanged(NSNotification *notification) {
    NSString *key = notification.userInfo[@"key"];
    if (![key isEqualToString:YTzoomInvisibleStickersKey] &&
        ![key isEqualToString:YTzoomMasterEnabledKey]) {
        return;
    }
    for (UIView *toolbelt in YTzoomStickerToolbelts.allObjects) {
        YTzoomSyncStickerToggle(toolbelt);
    }
    SEL regenerate = NSSelectorFromString(@"forceSnapshotRegeneration");
    for (UIView *sticker in YTzoomStickerViews.allObjects) {
        YTzoomApplyStickerVisibility(sticker);
        if ([sticker respondsToSelector:regenerate]) {
            ((void (*)(id, SEL))objc_msgSend)(sticker, regenerate);
        }
        [sticker setNeedsLayout];
    }
}

static void YTzoomInstallStickerViewHooks(NSString *className,
                                          IMP skipBurnIn, IMP *originalSkipBurnIn,
                                          IMP scaleLimit, IMP *originalScaleLimit,
                                          IMP layout, IMP *originalLayout,
                                          IMP move, IMP *originalMove) {
    YTzoomInstallInstanceHook(className, @"skipBurnIn", skipBurnIn, originalSkipBurnIn);
    YTzoomInstallInstanceHook(className, @"stickerScaleLimit", scaleLimit, originalScaleLimit);
    YTzoomInstallInstanceHook(className, @"layoutSubviews", layout, originalLayout);
    YTzoomInstallInstanceHook(className, @"didMoveToSuperview", move, originalMove);
}

void YTzoomInstallShortsStickerHooks(void) {
    if (YTzoomStickerViews != nil) return;
    YTzoomStickerViews = [NSHashTable weakObjectsHashTable];
    YTzoomStickerToolbelts = [NSHashTable weakObjectsHashTable];

    YTzoomInstallStickerViewHooks(@"YTCreationBaseInteractiveStickerView",
        (IMP)YTzoomSkipBurnInBase, &YTzoomOrigSkipBurnInBase,
        (IMP)YTzoomScaleLimitBase, &YTzoomOrigScaleLimitBase,
        (IMP)YTzoomLayoutBase, &YTzoomOrigLayoutBase,
        (IMP)YTzoomMoveBase, &YTzoomOrigMoveBase);
    YTzoomInstallStickerViewHooks(@"YTCreationCommentStickerView",
        (IMP)YTzoomSkipBurnInComment, &YTzoomOrigSkipBurnInComment,
        (IMP)YTzoomScaleLimitComment, &YTzoomOrigScaleLimitComment,
        (IMP)YTzoomLayoutComment, &YTzoomOrigLayoutComment,
        (IMP)YTzoomMoveComment, &YTzoomOrigMoveComment);
    YTzoomInstallInstanceHook(@"YTCreationProductStickerView", @"stickerScaleLimit",
                              (IMP)YTzoomScaleLimitProduct, &YTzoomOrigScaleLimitProduct);

    YTzoomInstallInstanceHook(@"UIView", @"yt_renderImage",
                              (IMP)YTzoomRenderImage, &YTzoomOrigRenderImage);
    YTzoomInstallInstanceHook(@"YTCreationTextToImageStickerView", @"renderStickerImage:",
                              (IMP)YTzoomTextToImageRender, &YTzoomOrigTextToImageRender);

    NSString *toolbelt = @"YTCreationToolbeltView";
    YTzoomInstallInstanceHook(toolbelt, @"layoutSubviews",
                              (IMP)YTzoomToolbeltLayout, &YTzoomOrigToolbeltLayout);
    YTzoomInstallInstanceHook(toolbelt, @"didMoveToSuperview",
                              (IMP)YTzoomToolbeltMove, &YTzoomOrigToolbeltMove);
    YTzoomInstallInstanceHook(toolbelt, @"setFrame:",
                              (IMP)YTzoomToolbeltFrame, &YTzoomOrigToolbeltFrame);
    YTzoomInstallInstanceHook(toolbelt, @"setCenter:",
                              (IMP)YTzoomToolbeltCenter, &YTzoomOrigToolbeltCenter);
    YTzoomInstallInstanceHook(toolbelt, @"setAlpha:",
                              (IMP)YTzoomToolbeltAlpha, &YTzoomOrigToolbeltAlpha);
    YTzoomInstallInstanceHook(toolbelt, @"setHidden:",
                              (IMP)YTzoomToolbeltHidden, &YTzoomOrigToolbeltHidden);

    [NSNotificationCenter.defaultCenter
        addObserverForName:YTzoomPreferencesDidChangeNotification
                    object:nil
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    YTzoomStickerPreferencesChanged(notification);
                }];
}
