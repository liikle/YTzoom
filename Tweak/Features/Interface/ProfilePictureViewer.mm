#import "../../YTzoom.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"

#import <Photos/Photos.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static const NSTimeInterval YTzoomAvatarHoldDuration = 0.8;
static const NSTimeInterval YTzoomAvatarWindowHoldDuration = 0.3;

static const void *YTzoomAvatarGestureAssociation = &YTzoomAvatarGestureAssociation;
static const void *YTzoomAvatarNodeAssociation = &YTzoomAvatarNodeAssociation;

static id YTzoomAvatarValue(id object, NSString *key);

@interface YTzoomAvatarNodeTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedTarget;
- (void)avatarNodeHeld:(UILongPressGestureRecognizer *)gesture;
- (void)presentBestForView:(UIView *)view node:(id)node fallback:(UIImage *)fallback;
@end

static UIViewController *YTzoomAvatarPresenter(UIView *view) {
    UIResponder *responder = view;
    while (responder != nil) {
        if ([responder isKindOfClass:UIViewController.class]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    UIViewController *controller = view.window.rootViewController;
    while (controller.presentedViewController != nil) {
        controller = controller.presentedViewController;
    }
    return controller;
}

static BOOL YTzoomAvatarToken(UIView *view) {
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate != nil && depth < 7; depth++) {
        NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
            NSStringFromClass(candidate.class) ?: @"",
            candidate.accessibilityIdentifier ?: @"",
            candidate.accessibilityLabel ?: @""].lowercaseString;
        if ([token containsString:@"ytzoom"]) return NO;
        if ([token containsString:@"avatar"] ||
            [token containsString:@"profile"] ||
            [token containsString:@"account"] ||
            [token containsString:@"channelreel"] ||
            [token containsString:@"reelround"]) {
            return YES;
        }
        candidate = candidate.superview;
    }
    return NO;
}

static UIImage *YTzoomAvatarImage(UIView *view) {
    if ([view isKindOfClass:UIImageView.class] &&
        ((UIImageView *)view).image != nil) {
        return ((UIImageView *)view).image;
    }
    SEL imageSelector = NSSelectorFromString(@"image");
    if ([view respondsToSelector:imageSelector]) {
        id image = ((id (*)(id, SEL))objc_msgSend)(view, imageSelector);
        if ([image isKindOfClass:UIImage.class]) return image;
    }
    UIImage *best = nil;
    CGFloat bestArea = 0.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:view.subviews];
    while (stack.count != 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if ([candidate isKindOfClass:UIImageView.class]) {
            UIImage *image = ((UIImageView *)candidate).image;
            CGFloat area = image.size.width * image.size.height;
            if (image != nil && area >= bestArea) {
                best = image;
                bestArea = area;
            }
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    return best;
}

static BOOL YTzoomAvatarImageShape(UIImageView *view) {
    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    if (width < 18.0 || height < 18.0 || width > 240.0 || height > 240.0) {
        return NO;
    }
    CGFloat ratio = width / MAX(height, 1.0);
    if (ratio < 0.82 || ratio > 1.18) return NO;
    return view.layer.cornerRadius >= MIN(width, height) * 0.28 ||
        view.layer.mask != nil || YTzoomAvatarToken(view);
}

static UIView *YTzoomAvatarViewAtPoint(UIWindow *window,
                                       CGPoint point,
                                       UIImage **imageOutput) {
    UIView *hit = [window hitTest:point withEvent:nil];
    for (UIView *candidate = hit; candidate != nil; candidate = candidate.superview) {
        if (!YTzoomAvatarToken(candidate)) continue;
        UIImage *image = YTzoomAvatarImage(candidate);
        if (image != nil) {
            if (imageOutput != NULL) *imageOutput = image;
            return candidate;
        }
    }

    if ([hit isKindOfClass:UICollectionView.class]) {
        UICollectionView *collection = (UICollectionView *)hit;
        CGPoint local = [window convertPoint:point toView:collection];
        NSIndexPath *indexPath = [collection indexPathForItemAtPoint:local];
        UICollectionViewCell *cell = indexPath == nil
            ? nil : [collection cellForItemAtIndexPath:indexPath];
        UIImage *image = YTzoomAvatarImage(cell);
        if (image != nil) {
            if (imageOutput != NULL) *imageOutput = image;
            return cell;
        }
    }

    UIImageView *bestView = nil;
    CGFloat bestArea = CGFLOAT_MAX;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
    while (stack.count != 0) {
        UIView *candidate = stack.lastObject;
        [stack removeLastObject];
        if (candidate.hidden || candidate.alpha < 0.05) {
            continue;
        }
        if ([candidate isKindOfClass:UIImageView.class]) {
            UIImageView *imageView = (UIImageView *)candidate;
            CGPoint local = [window convertPoint:point toView:imageView];
            CGFloat area = CGRectGetWidth(imageView.bounds) *
                CGRectGetHeight(imageView.bounds);
            if (imageView.image != nil &&
                [imageView pointInside:local withEvent:nil] &&
                YTzoomAvatarImageShape(imageView) && area < bestArea) {
                bestView = imageView;
                bestArea = area;
            }
        }
        [stack addObjectsFromArray:candidate.subviews];
    }
    if (bestView != nil && imageOutput != NULL) *imageOutput = bestView.image;
    if (bestView != nil) return bestView;

    CALayer *layer = [window.layer hitTest:point];
    for (CALayer *candidate = layer; candidate != nil; candidate = candidate.superlayer) {
        id contents = candidate.contents;
        CGFloat width = CGRectGetWidth(candidate.bounds);
        CGFloat height = CGRectGetHeight(candidate.bounds);
        CGFloat ratio = width / MAX(height, 1.0);
        BOOL avatarSize = width >= 18.0 && height >= 18.0 &&
            width <= 240.0 && height <= 240.0 && ratio >= 0.82 && ratio <= 1.18;
        if (!avatarSize || contents == nil) continue;
        CFTypeRef value = (__bridge CFTypeRef)contents;
        if (CFGetTypeID(value) != CGImageGetTypeID()) continue;
        UIImage *image = [UIImage imageWithCGImage:(CGImageRef)value
            scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
        if (image != nil) {
            if (imageOutput != NULL) *imageOutput = image;
            return hit;
        }
    }
    return nil;
}

static NSString *YTzoomAvatarURLString(id node) {
    id URL = YTzoomAvatarValue(node, @"URL");
    NSString *absolute = [URL isKindOfClass:NSURL.class]
        ? ((NSURL *)URL).absoluteString : nil;
    if (absolute.length == 0) return nil;
    BOOL avatarHost = [absolute containsString:@"ggpht"] ||
        [absolute containsString:@"googleusercontent"];
    if (!avatarHost) return nil;
    if ([absolute containsString:@"fcrop64"]) return nil;
    if ([absolute rangeOfString:@"=s"].location == NSNotFound) return nil;
    return absolute;
}

static id YTzoomAvatarNodeInTree(id node, NSUInteger depth) {
    if (node == nil || depth > 10) return nil;
    if (YTzoomAvatarURLString(node) != nil) return node;
    id subnodes = YTzoomAvatarValue(node, @"subnodes");
    if (![subnodes isKindOfClass:NSArray.class]) {
        subnodes = YTzoomAvatarValue(node, @"yogaChildren");
    }
    if ([subnodes isKindOfClass:NSArray.class]) {
        for (id child in subnodes) {
            id found = YTzoomAvatarNodeInTree(child, depth + 1);
            if (found != nil) return found;
        }
    }
    return nil;
}

static id YTzoomAvatarNodeUnderPoint(UIView *view, UIWindow *window,
                                     CGPoint point, NSUInteger depth) {
    if (view == nil || depth > 30 || view.hidden || view.alpha < 0.05) return nil;
    CGPoint local = [window convertPoint:point toView:view];
    if (depth != 0 && ![view pointInside:local withEvent:nil]) return nil;

    id found = YTzoomAvatarNodeInTree(
        YTzoomAvatarValue(view, @"keepalive_node"), 0);
    if (found != nil) return found;

    for (UIView *subview in view.subviews.reverseObjectEnumerator) {
        id found = YTzoomAvatarNodeUnderPoint(subview, window, point, depth + 1);
        if (found != nil) return found;
    }
    return nil;
}


static CGSize YTzoomNativePoints(UIImage *image) {
    CGFloat scale = UIScreen.mainScreen.scale > 0.0
        ? UIScreen.mainScreen.scale : 2.0;
    CGFloat pixelsWide = image.size.width * (image.scale > 0.0 ? image.scale : 1.0);
    CGFloat pixelsHigh = image.size.height * (image.scale > 0.0 ? image.scale : 1.0);
    if (pixelsWide < 1.0 || pixelsHigh < 1.0) return CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX);
    return CGSizeMake(pixelsWide / scale, pixelsHigh / scale);
}

@interface YTzoomAvatarViewerController : UIViewController
    <UIScrollViewDelegate>
- (instancetype)initWithImage:(UIImage *)image;
@end

@implementation YTzoomAvatarViewerController {
    UIImage *_image;
    UIScrollView *_scrollView;
    UIImageView *_imageView;
}

- (instancetype)initWithImage:(UIImage *)image {
    self = [super initWithNibName:nil bundle:nil];
    if (self != nil) {
        _image = image;
        self.modalPresentationStyle = UIModalPresentationFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    _scrollView = [UIScrollView new];
    _scrollView.delegate = self;
    _scrollView.minimumZoomScale = 1.0;
    _scrollView.maximumZoomScale = 8.0;
    _scrollView.showsHorizontalScrollIndicator = NO;
    _scrollView.showsVerticalScrollIndicator = NO;
    _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_scrollView];

    _imageView = [[UIImageView alloc] initWithImage:_image];
    _imageView.contentMode = UIViewContentModeScaleAspectFit;
    _imageView.translatesAutoresizingMaskIntoConstraints = NO;
    [_scrollView addSubview:_imageView];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    close.tintColor = UIColor.whiteColor;
    close.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.82];
    close.layer.cornerRadius = 19.0;
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [close addTarget:self action:@selector(closeTapped)
      forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    [save setImage:[UIImage systemImageNamed:@"square.and.arrow.down"]
          forState:UIControlStateNormal];
    save.tintColor = UIColor.whiteColor;
    save.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.82];
    save.layer.cornerRadius = 19.0;
    save.translatesAutoresizingMaskIntoConstraints = NO;
    [save addTarget:self action:@selector(saveTapped)
     forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:save];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(doubleTapped:)];
    doubleTap.numberOfTapsRequired = 2;
    [_scrollView addGestureRecognizer:doubleTap];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scrollView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_imageView.topAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.topAnchor],
        [_imageView.leadingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.leadingAnchor],
        [_imageView.trailingAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.trailingAnchor],
        [_imageView.bottomAnchor constraintEqualToAnchor:_scrollView.contentLayoutGuide.bottomAnchor],
        [_imageView.widthAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.widthAnchor],
        [_imageView.heightAnchor constraintEqualToAnchor:_scrollView.frameLayoutGuide.heightAnchor],
        [_imageView.widthAnchor constraintLessThanOrEqualToConstant:
            YTzoomNativePoints(_image).width],
        [_imageView.heightAnchor constraintLessThanOrEqualToConstant:
            YTzoomNativePoints(_image).height],
        [close.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16.0],
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [close.widthAnchor constraintEqualToConstant:38.0],
        [close.heightAnchor constraintEqualToConstant:38.0],
        [save.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16.0],
        [save.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [save.widthAnchor constraintEqualToConstant:38.0],
        [save.heightAnchor constraintEqualToConstant:38.0]
    ]];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    (void)scrollView;
    return _imageView;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)doubleTapped:(UITapGestureRecognizer *)gesture {
    if (_scrollView.zoomScale > 1.05) {
        [_scrollView setZoomScale:1.0 animated:YES];
        return;
    }
    CGPoint point = [gesture locationInView:_imageView];
    CGFloat scale = MIN(3.0, _scrollView.maximumZoomScale);
    CGSize size = CGSizeMake(CGRectGetWidth(_scrollView.bounds) / scale,
                             CGRectGetHeight(_scrollView.bounds) / scale);
    [_scrollView zoomToRect:CGRectMake(point.x - size.width * 0.5,
                                       point.y - size.height * 0.5,
                                       size.width, size.height)
                   animated:YES];
}

- (void)saveTapped {
    UIImage *image = _image;
    if (image == nil) return;
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        [PHAssetChangeRequest creationRequestForAssetFromImage:image];
    } completionHandler:^(BOOL success, __unused NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomShowNotice(success ? @"Profile picture saved" :
                @"Profile picture could not be saved");
        });
    }];
}

@end

@interface YTzoomAvatarTarget : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)sharedTarget;
- (void)avatarHeld:(UILongPressGestureRecognizer *)gesture;
@end

@implementation YTzoomAvatarTarget

+ (instancetype)sharedTarget {
    static YTzoomAvatarTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomAvatarTarget new]; });
    return target;
}

- (void)avatarHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Profiles.Preview")) {
        return;
    }
    UIWindow *window = [gesture.view isKindOfClass:UIWindow.class]
        ? (UIWindow *)gesture.view : gesture.view.window;
    CGPoint point = [gesture locationInView:window];
    UIImage *image = nil;
    UIView *view = YTzoomAvatarViewAtPoint(window, point, &image);
    if (image == nil) return;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    UIViewController *presenter = YTzoomAvatarPresenter(view);
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    if ([presenter isKindOfClass:YTzoomAvatarViewerController.class]) return;
    id node = objc_getAssociatedObject(view, YTzoomAvatarNodeAssociation);
    if (YTzoomAvatarURLString(node) == nil) {
        node = YTzoomAvatarValue(view, @"keepalive_node");
    }
    if (YTzoomAvatarURLString(node) == nil) {
        node = YTzoomAvatarNodeUnderPoint(view, window, point, 0);
    }
    if (YTzoomAvatarURLString(node) == nil) {
        node = YTzoomAvatarNodeUnderPoint(window, window, point, 0);
    }
    [YTzoomAvatarNodeTarget.sharedTarget presentBestForView:view
                                                       node:node
                                                   fallback:image];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

@end

static id YTzoomAvatarValue(id object, NSString *key) {
    if (object == nil || key.length == 0) return nil;
    @try {
        SEL selector = NSSelectorFromString(key);
        if (![object respondsToSelector:selector]) return nil;
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *YTzoomHighResAvatarURL(NSString *absolute) {
    if (absolute.length == 0) return nil;
    NSRange size = [absolute rangeOfString:@"=s"];
    if (size.location == NSNotFound) return nil;
    NSRange tail = NSMakeRange(size.location, absolute.length - size.location);
    NSRange dash = [absolute rangeOfString:@"-" options:0 range:tail];
    if (dash.location == NSNotFound) return nil;
    NSRange digits = NSMakeRange(size.location + 2,
                                 dash.location - size.location - 2);
    if (digits.length == 0 || digits.length > 5) return nil;
    CGRect bounds = UIScreen.mainScreen.bounds;
    CGFloat longest = MAX(CGRectGetWidth(bounds), CGRectGetHeight(bounds));
    CGFloat wanted = longest * UIScreen.mainScreen.scale;
    NSInteger requested = wanted >= 1600.0 ? 2048 : (wanted >= 800.0 ? 1024 : 512);
    return [absolute stringByReplacingCharactersInRange:digits
        withString:[NSString stringWithFormat:@"%ld", (long)requested]];
}

static const void *YTzoomAvatarViewGestureAssociation =
    &YTzoomAvatarViewGestureAssociation;


@implementation YTzoomAvatarNodeTarget

+ (instancetype)sharedTarget {
    static YTzoomAvatarNodeTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomAvatarNodeTarget new]; });
    return target;
}

- (void)present:(UIImage *)image fromView:(UIView *)view {
    if (image == nil) return;
    UIViewController *presenter = YTzoomAvatarPresenter(view);
    while (presenter.presentedViewController != nil) {
        presenter = presenter.presentedViewController;
    }
    if ([presenter isKindOfClass:YTzoomAvatarViewerController.class]) return;
    [presenter presentViewController:
        [[YTzoomAvatarViewerController alloc] initWithImage:image]
                            animated:YES completion:nil];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldBeRequiredToFailByGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRequireFailureOfGestureRecognizer:
            (UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return NO;
}

- (void)presentBestForView:(UIView *)view node:(id)node fallback:(UIImage *)fallback {
    NSString *absolute = YTzoomAvatarURLString(node);
    NSString *upgraded = YTzoomHighResAvatarURL(absolute);
    if (upgraded == nil) return;
    __weak UIView *weakView = view;
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:upgraded]
        completionHandler:^(NSData *data, __unused NSURLResponse *response,
                            __unused NSError *error) {
        UIImage *full = data.length != 0 ? [UIImage imageWithData:data] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self present:full ?: fallback fromView:weakView];
        });
    }] resume];
}

- (void)avatarNodeHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan ||
        !YTzoomFeatureEnabled(@"YTzoom.Preference.Profiles.Preview")) {
        return;
    }
    UIView *view = gesture.view;
    id node = objc_getAssociatedObject(view, YTzoomAvatarNodeAssociation);
    if (node == nil) node = YTzoomAvatarValue(view, @"keepalive_node");

    if (YTzoomAvatarURLString(node) == nil) return;
    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc]
        initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    [self presentBestForView:view node:node fallback:YTzoomAvatarImage(view)];
}

@end

void YTzoomProfileConsiderDisplayView(UIView *view, id node) {
    if (view == nil || !YTzoomFeatureEnabled(@"YTzoom.Preference.Profiles.Preview")) return;
    if (![[view description] containsString:@"ELMImageNode-View"]) return;
    if (node != nil) {
        objc_setAssociatedObject(view, YTzoomAvatarNodeAssociation, node,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (objc_getAssociatedObject(view, YTzoomAvatarViewGestureAssociation) != nil) {
        return;
    }
    for (id<UIInteraction> interaction in [view.interactions copy]) {
        if ([interaction isKindOfClass:UIDragInteraction.class]) {
            ((UIDragInteraction *)interaction).enabled = NO;
        }
    }

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:YTzoomAvatarNodeTarget.sharedTarget
                action:@selector(avatarNodeHeld:)];
    gesture.minimumPressDuration = YTzoomAvatarHoldDuration;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;
    gesture.delegate = YTzoomAvatarNodeTarget.sharedTarget;
    [view addGestureRecognizer:gesture];
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view, YTzoomAvatarViewGestureAssociation, gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomAttachAvatarGesture(UIWindow *window) {
    if (window == nil ||
        objc_getAssociatedObject(window, YTzoomAvatarGestureAssociation) != nil) {
        return;
    }
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:YTzoomAvatarTarget.sharedTarget
                action:@selector(avatarHeld:)];
    gesture.minimumPressDuration = YTzoomAvatarWindowHoldDuration;
    gesture.cancelsTouchesInView = NO;
    gesture.delegate = YTzoomAvatarTarget.sharedTarget;
    [window addGestureRecognizer:gesture];
    objc_setAssociatedObject(window, YTzoomAvatarGestureAssociation, gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomAttachAvatarWindows(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *name = NSStringFromClass(window.class).lowercaseString;
            if ([name containsString:@"texteffects"] ||
                [name containsString:@"keyboard"]) {
                continue;
            }
            YTzoomAttachAvatarGesture(window);
        }
    }
}

void YTzoomInstallProfilePictureHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSNotificationCenter.defaultCenter addObserverForName:
            UIWindowDidBecomeKeyNotification object:nil
            queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) {
                YTzoomAttachAvatarWindows();
            }];
    });
    dispatch_async(dispatch_get_main_queue(), ^{ YTzoomAttachAvatarWindows(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ YTzoomAttachAvatarWindows(); });
}
