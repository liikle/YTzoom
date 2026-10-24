#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "GeminiClient.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString * const YTzoomAITitlesKey = @"YTzoom.Preference.AITitles.Enabled";
NSString * const YTzoomAITitlesPlacementKey = @"YTzoom.Preference.AITitles.Placement";

static const NSUInteger YTzoomTitleSuggestionCount = 5;
static const NSTimeInterval YTzoomTitleMediaLifetime = 3.0 * 60.0 * 60.0;
static const NSTimeInterval YTzoomTitleTextLifetime = 45.0 * 60.0;
static const void *YTzoomTitleButtonAssociation = &YTzoomTitleButtonAssociation;
static const void *YTzoomTitleInsetAssociation = &YTzoomTitleInsetAssociation;

#pragma mark - Screen matching

// YouTube's upload screens have no public class names, so they are matched by
// keywords in the view controller and view class names. Long-press the button
// to copy the names for a screen.
static NSString *YTzoomTitleClassChain(UIView *view) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIView.class] || [responder isKindOfClass:UIViewController.class]) {
            [names addObject:NSStringFromClass(responder.class)];
        }
    }
    return [names componentsJoinedByString:@" > "];
}

static BOOL YTzoomTitleChainExcluded(NSString *chain) {
    NSString *lower = chain.lowercaseString;
    for (NSString *word in @[@"search", @"comment", @"chat", @"backstage", @"settings",
                             @"ytzoom", @"reply", @"message", @"alert"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static BOOL YTzoomTitleChainMatches(NSString *chain, NSArray<NSString *> *keywords) {
    if (YTzoomTitleChainExcluded(chain)) return NO;
    NSString *lower = chain.lowercaseString;
    for (NSString *word in keywords) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static BOOL YTzoomTitleIsUploadScreen(UIView *input) {
    return YTzoomTitleChainMatches(YTzoomTitleClassChain(input),
        @[@"upload", @"metadata", @"publish", @"details"]);
}

static BOOL YTzoomTitleIsEditorScreen(UIView *input) {
    return YTzoomTitleChainMatches(YTzoomTitleClassChain(input),
        @[@"creation", @"camera", @"edit", @"shorts", @"text", @"sticker", @"overlay",
          @"reel", @"upload", @"metadata"]);
}

static BOOL YTzoomTitleIsEditable(UIView *view) {
    if (view.hidden || view.alpha < 0.01 || view.window == nil) return NO;
    if ([view isKindOfClass:UITextView.class]) return ((UITextView *)view).editable;
    if ([view isKindOfClass:UITextField.class]) return ((UITextField *)view).enabled;
    return NO;
}

static UIViewController *YTzoomTitleOwner(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }
    return nil;
}

static void YTzoomTitleCollectInputs(UIView *view, NSMutableArray<UIView *> *inputs, NSUInteger depth) {
    if (depth > 40 || inputs.count > 20) return;
    if (YTzoomTitleIsEditable(view)) {
        [inputs addObject:view];
        return;
    }
    for (UIView *child in view.subviews) YTzoomTitleCollectInputs(child, inputs, depth + 1);
}

// The title is the first text box on the screen; the description sits below it.
static BOOL YTzoomTitleIsTopmostInput(UIView *input) {
    UIView *root = YTzoomTitleOwner(input).view ?: input.window;
    NSMutableArray<UIView *> *inputs = [NSMutableArray array];
    YTzoomTitleCollectInputs(root, inputs, 0);
    CGFloat top = [input convertRect:input.bounds toView:nil].origin.y;
    for (UIView *other in inputs) {
        if (other == input) continue;
        if ([other convertRect:other.bounds toView:nil].origin.y < top - 1.0) return NO;
    }
    return YES;
}

static NSString *YTzoomTitleTextOf(UIView *input) {
    if ([input isKindOfClass:UITextView.class]) return ((UITextView *)input).text ?: @"";
    if ([input isKindOfClass:UITextField.class]) return ((UITextField *)input).text ?: @"";
    return @"";
}

#pragma mark - Video frames

static NSMutableArray<NSDictionary *> *YTzoomTitleMedia;

static BOOL YTzoomTitleAssetIsLocal(AVAsset *asset) {
    if ([asset isKindOfClass:AVComposition.class]) return YES;
    if (![asset isKindOfClass:AVURLAsset.class]) return NO;
    NSURL *URL = ((AVURLAsset *)asset).URL;
    // Skip YTzoom's own download library.
    return URL.isFileURL && ![URL.path containsString:@"/Documents/YTzoom/"];
}

static void YTzoomTitleRememberAsset(AVAsset *asset) {
    if (asset == nil || !YTzoomFeatureEnabled(YTzoomAITitlesKey) ||
        !YTzoomTitleAssetIsLocal(asset)) {
        return;
    }
    @synchronized (YTzoomTitleMedia) {
        for (NSUInteger index = 0; index < YTzoomTitleMedia.count; index++) {
            if (YTzoomTitleMedia[index][@"asset"] == asset) {
                [YTzoomTitleMedia removeObjectAtIndex:index];
                break;
            }
        }
        [YTzoomTitleMedia insertObject:@{@"asset": asset, @"date": NSDate.date} atIndex:0];
        while (YTzoomTitleMedia.count > 8) [YTzoomTitleMedia removeLastObject];
    }
}

static IMP OriginalItemInitWithURL;
static IMP OriginalItemInitWithAsset;
static IMP OriginalItemInitWithAssetKeys;
static IMP OriginalReaderInit;
static IMP OriginalExportInit;
static IMP OriginalGeneratorInit;

static id YTzoomItemInitWithURL(id receiver, SEL selector, NSURL *URL) {
    id item = ((id (*)(id, SEL, id))OriginalItemInitWithURL)(receiver, selector, URL);
    YTzoomTitleRememberAsset([(AVPlayerItem *)item asset]);
    return item;
}

static id YTzoomItemInitWithAsset(id receiver, SEL selector, AVAsset *asset) {
    YTzoomTitleRememberAsset(asset);
    return ((id (*)(id, SEL, id))OriginalItemInitWithAsset)(receiver, selector, asset);
}

static id YTzoomItemInitWithAssetKeys(id receiver, SEL selector, AVAsset *asset, NSArray *keys) {
    YTzoomTitleRememberAsset(asset);
    return ((id (*)(id, SEL, id, id))OriginalItemInitWithAssetKeys)(receiver, selector, asset, keys);
}

static id YTzoomReaderInit(id receiver, SEL selector, AVAsset *asset, NSError **error) {
    YTzoomTitleRememberAsset(asset);
    return ((id (*)(id, SEL, id, NSError **))OriginalReaderInit)(receiver, selector, asset, error);
}

static id YTzoomExportInit(id receiver, SEL selector, AVAsset *asset, NSString *preset) {
    YTzoomTitleRememberAsset(asset);
    return ((id (*)(id, SEL, id, id))OriginalExportInit)(receiver, selector, asset, preset);
}

static id YTzoomGeneratorInit(id receiver, SEL selector, AVAsset *asset) {
    YTzoomTitleRememberAsset(asset);
    return ((id (*)(id, SEL, id))OriginalGeneratorInit)(receiver, selector, asset);
}

// Runs off the main thread: loading tracks and decoding frames can block.
static NSArray<UIImage *> *YTzoomTitleVideoFrames(void) {
    NSArray<NSDictionary *> *media;
    @synchronized (YTzoomTitleMedia) {
        media = [YTzoomTitleMedia copy];
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (NSDictionary *entry in media) {
        if (-[entry[@"date"] timeIntervalSinceNow] > YTzoomTitleMediaLifetime) continue;
        AVAsset *asset = entry[@"asset"];
        if ([asset tracksWithMediaType:AVMediaTypeVideo].count == 0) continue;
        Float64 duration = CMTimeGetSeconds(asset.duration);
        if (!(duration > 0.0)) continue;
        AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
        generator.appliesPreferredTrackTransform = YES;
        generator.maximumSize = CGSizeMake(768.0, 768.0);
        generator.requestedTimeToleranceBefore = CMTimeMakeWithSeconds(0.5, 600);
        generator.requestedTimeToleranceAfter = CMTimeMakeWithSeconds(0.5, 600);
        NSMutableArray<UIImage *> *frames = [NSMutableArray array];
        for (NSNumber *fraction in @[@0.1, @0.35, @0.6, @0.85]) {
            CMTime time = CMTimeMakeWithSeconds(duration * fraction.doubleValue, 600);
            CGImageRef image = [generator copyCGImageAtTime:time actualTime:NULL error:NULL];
            if (image == NULL) continue;
            [frames addObject:[UIImage imageWithCGImage:image]];
            CGImageRelease(image);
        }
        if (frames.count != 0) return frames;
    }
#pragma clang diagnostic pop
    return @[];
}

static UIImage *YTzoomTitleScreenshot(UIWindow *window) {
    if (window == nil) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    return [[[UIGraphicsImageRenderer alloc] initWithBounds:window.bounds format:format]
        imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:NO];
        }];
}

#pragma mark - Editor text

static NSMutableDictionary<NSString *, NSDictionary *> *YTzoomTitleTexts;
static NSMutableArray<NSString *> *YTzoomTitleTextOrder;

static void YTzoomTitleTextChanged(NSNotification *notification) {
    UIView *input = notification.object;
    if (![input isKindOfClass:UIView.class] || !YTzoomFeatureEnabled(YTzoomAITitlesKey)) return;
    if (objc_getAssociatedObject(input, YTzoomTitleButtonAssociation) != nil) return;
    if (!YTzoomTitleIsEditorScreen(input)) return;
    NSString *text = [YTzoomTitleTextOf(input) stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *identifier = [NSString stringWithFormat:@"%p", input];
    @synchronized (YTzoomTitleTexts) {
        [YTzoomTitleTextOrder removeObject:identifier];
        if (text.length == 0) {
            [YTzoomTitleTexts removeObjectForKey:identifier];
            return;
        }
        YTzoomTitleTexts[identifier] = @{@"text": text, @"date": NSDate.date};
        [YTzoomTitleTextOrder addObject:identifier];
        while (YTzoomTitleTextOrder.count > 20) {
            [YTzoomTitleTexts removeObjectForKey:YTzoomTitleTextOrder.firstObject];
            [YTzoomTitleTextOrder removeObjectAtIndex:0];
        }
    }
}

static NSArray<NSString *> *YTzoomTitleEditorTexts(NSString *currentTitle) {
    NSMutableOrderedSet<NSString *> *texts = [NSMutableOrderedSet orderedSet];
    @synchronized (YTzoomTitleTexts) {
        for (NSString *identifier in YTzoomTitleTextOrder) {
            NSDictionary *entry = YTzoomTitleTexts[identifier];
            if (-[entry[@"date"] timeIntervalSinceNow] > YTzoomTitleTextLifetime) continue;
            if ([entry[@"text"] isEqualToString:currentTitle]) continue;
            [texts addObject:entry[@"text"]];
        }
    }
    return texts.array;
}

#pragma mark - Button

static void YTzoomTitleApply(UIView *input, NSString *title) {
    if (input.window == nil) return;
    [input becomeFirstResponder];
    id<UITextInput> textInput = (id<UITextInput>)input;
    UITextRange *all = [textInput textRangeFromPosition:textInput.beginningOfDocument
                                             toPosition:textInput.endOfDocument];
    if (all != nil) {
        textInput.selectedTextRange = all;
        [textInput insertText:title];
    }
    if ([YTzoomTitleTextOf(input) isEqualToString:title]) return;
    // The delegate refused the edit, so set the text and announce it ourselves.
    if ([input isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)input;
        textView.text = title;
        if ([textView.delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [textView.delegate textViewDidChange:textView];
        }
        [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification
                                                          object:textView];
    } else if ([input isKindOfClass:UITextField.class]) {
        UITextField *textField = (UITextField *)input;
        textField.text = title;
        [textField sendActionsForControlEvents:UIControlEventEditingChanged];
        [NSNotificationCenter.defaultCenter postNotificationName:UITextFieldTextDidChangeNotification
                                                          object:textField];
    }
}

static UIViewController *YTzoomTitlePresenter(UIView *view) {
    UIViewController *controller = view.window.rootViewController;
    while (controller.presentedViewController != nil &&
           !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

@interface YTzoomTitleButton : UIButton
@property(nonatomic, weak) UIView *textInput;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) NSMutableOrderedSet<NSString *> *rejectedTitles;
@end

@implementation YTzoomTitleButton

+ (instancetype)buttonForInput:(UIView *)input {
    YTzoomTitleButton *button = [self buttonWithType:UIButtonTypeSystem];
    button.textInput = input;
    button.rejectedTitles = [NSMutableOrderedSet orderedSet];
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightSemibold];
    [button setImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:configuration]
            forState:UIControlStateNormal];
    button.tintColor = YTzoomAccentColor();
    button.accessibilityLabel = YTzoomLocalized(@"Generate Title with AI");
    button.accessibilityIdentifier = @"YTzoom.AITitleButton";
    [button addTarget:button action:@selector(generate) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:button action:@selector(copyDiagnostics:)]];
    button.spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    button.spinner.hidesWhenStopped = YES;
    button.spinner.userInteractionEnabled = NO;
    button.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [button addSubview:button.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [button.spinner.centerXAnchor constraintEqualToAnchor:button.centerXAnchor],
        [button.spinner.centerYAnchor constraintEqualToAnchor:button.centerYAnchor]
    ]];
    return button;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.imageView.alpha = busy ? 0.0 : 1.0;
    if (busy) [self.spinner startAnimating];
    else [self.spinner stopAnimating];
}

- (void)generate {
    [self.rejectedTitles removeAllObjects];
    [self requestTitles];
}

- (void)requestTitles {
    UIView *input = self.textInput;
    if (self.busy || input == nil) return;
    if (!YTzoomGeminiHasAPIKey()) {
        YTzoomShowNotice(YTzoomLocalized(@"Add your Gemini API key in YTzoom settings under AI & Region."));
        return;
    }
    self.busy = YES;
    NSString *current = [YTzoomTitleTextOf(input) stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *texts = YTzoomTitleEditorTexts(current);
    UIImage *screenshot = YTzoomTitleScreenshot(input.window);
    NSArray<NSString *> *avoid = self.rejectedTitles.array;
    __weak YTzoomTitleButton *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<UIImage *> *frames = YTzoomTitleVideoFrames();
        BOOL useScreenshot = frames.count == 0 && screenshot != nil;
        YTzoomGeminiGenerateTitles(useScreenshot ? @[screenshot] : frames, useScreenshot,
                                   texts, current, avoid, YTzoomTitleSuggestionCount,
                                   ^(NSArray<NSString *> *titles, NSString *error) {
            YTzoomTitleButton *button = weakSelf;
            button.busy = NO;
            if (button.textInput.window == nil) return;
            if (titles.count == 0) {
                YTzoomShowNotice(error ?: YTzoomLocalized(@"Gemini didn't return any titles. Try again."));
                return;
            }
            [button presentTitles:titles];
        });
    });
}

- (void)presentTitles:(NSArray<NSString *> *)titles {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:YTzoomLocalized(@"Pick a Title")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    __weak YTzoomTitleButton *weakSelf = self;
    for (NSString *title in titles) {
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            UIView *input = weakSelf.textInput;
            if (input != nil) YTzoomTitleApply(input, title);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Regenerate")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        YTzoomTitleButton *button = weakSelf;
        [button.rejectedTitles addObjectsFromArray:titles];
        [button requestTitles];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = self;
    sheet.popoverPresentationController.sourceRect = self.bounds;
    [YTzoomTitlePresenter(self) presentViewController:sheet animated:YES completion:nil];
}

- (void)copyDiagnostics:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || self.textInput == nil) return;
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:
        @"YTzoom AI title button\nYouTube %@\n%@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        YTzoomTitleClassChain(self.textInput)];
    YTzoomShowNotice(YTzoomLocalized(@"Copied this screen's class names."));
}

@end

static void YTzoomTitleDetach(UIView *input) {
    YTzoomTitleButton *button = objc_getAssociatedObject(input, YTzoomTitleButtonAssociation);
    if (button == nil) return;
    if ([input isKindOfClass:UITextField.class] && ((UITextField *)input).rightView == button) {
        ((UITextField *)input).rightView = nil;
    } else {
        [button removeFromSuperview];
    }
    NSValue *inset = objc_getAssociatedObject(input, YTzoomTitleInsetAssociation);
    if (inset != nil && [input isKindOfClass:UITextView.class]) {
        ((UITextView *)input).textContainerInset = inset.UIEdgeInsetsValue;
    }
    objc_setAssociatedObject(input, YTzoomTitleButtonAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(input, YTzoomTitleInsetAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomTitleAttach(UIView *input) {
    YTzoomTitleButton *existing = objc_getAssociatedObject(input, YTzoomTitleButtonAssociation);
    if (existing != nil && (existing.superview != nil || existing.window != nil)) return;
    if (existing != nil) YTzoomTitleDetach(input);

    YTzoomTitleButton *button = [YTzoomTitleButton buttonForInput:input];
    if ([input isKindOfClass:UITextField.class] && ((UITextField *)input).rightView == nil) {
        UITextField *textField = (UITextField *)input;
        button.frame = CGRectMake(0.0, 0.0, 36.0, 32.0);
        textField.rightView = button;
        textField.rightViewMode = UITextFieldViewModeAlways;
    } else {
        UIView *host = input.superview;
        if (host == nil) return;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.trailingAnchor constraintEqualToAnchor:input.trailingAnchor constant:-2.0],
            [button.topAnchor constraintEqualToAnchor:input.topAnchor constant:2.0],
            [button.widthAnchor constraintEqualToConstant:34.0],
            [button.heightAnchor constraintEqualToConstant:34.0]
        ]];
        if ([input isKindOfClass:UITextView.class]) {
            UITextView *textView = (UITextView *)input;
            UIEdgeInsets inset = textView.textContainerInset;
            objc_setAssociatedObject(input, YTzoomTitleInsetAssociation,
                                     [NSValue valueWithUIEdgeInsets:inset],
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            inset.right += 34.0;
            textView.textContainerInset = inset;
        }
    }
    objc_setAssociatedObject(input, YTzoomTitleButtonAssociation, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void YTzoomTitleEvaluate(UIView *input) {
    if (input.window == nil) return;
    BOOL wanted = NO;
    if (YTzoomFeatureEnabled(YTzoomAITitlesKey) && YTzoomTitleIsEditable(input) &&
        ![input isKindOfClass:NSClassFromString(@"UISearchTextField")]) {
        id placement = YTzoomPreferenceObject(YTzoomAITitlesPlacementKey);
        if ([placement integerValue] == 1) {
            wanted = !YTzoomTitleChainExcluded(YTzoomTitleClassChain(input));
        } else {
            wanted = YTzoomTitleIsUploadScreen(input) && YTzoomTitleIsTopmostInput(input);
        }
    }
    if (wanted) YTzoomTitleAttach(input);
    else YTzoomTitleDetach(input);
}

static void YTzoomTitleConsider(UIView *input) {
    if (input.window == nil) return;
    YTzoomCommentHoldConsider(input);
    if (!YTzoomFeatureEnabled(YTzoomAITitlesKey) &&
        objc_getAssociatedObject(input, YTzoomTitleButtonAssociation) == nil) {
        return;
    }
    // Wait for the screen to finish laying out so the topmost check is right.
    __weak UIView *weakInput = input;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongInput = weakInput;
        if (strongInput != nil) YTzoomTitleEvaluate(strongInput);
    });
}

static IMP OriginalTextViewDidMoveToWindow;
static IMP OriginalTextFieldDidMoveToWindow;

static void YTzoomTextViewDidMoveToWindow(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalTextViewDidMoveToWindow)(receiver, selector);
    YTzoomTitleConsider(receiver);
}

static void YTzoomTextFieldDidMoveToWindow(UIView *receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalTextFieldDidMoveToWindow)(receiver, selector);
    YTzoomTitleConsider(receiver);
}

void YTzoomInstallAITitleHooks(void) {
    YTzoomTitleMedia = [NSMutableArray array];
    YTzoomTitleTexts = [NSMutableDictionary dictionary];
    YTzoomTitleTextOrder = [NSMutableArray array];

    YTzoomInstallInstanceHook(@"UITextView", @"didMoveToWindow",
                              (IMP)YTzoomTextViewDidMoveToWindow, &OriginalTextViewDidMoveToWindow);
    YTzoomInstallInstanceHook(@"UITextField", @"didMoveToWindow",
                              (IMP)YTzoomTextFieldDidMoveToWindow, &OriginalTextFieldDidMoveToWindow);

    YTzoomInstallInstanceHook(@"AVPlayerItem", @"initWithURL:",
                              (IMP)YTzoomItemInitWithURL, &OriginalItemInitWithURL);
    YTzoomInstallInstanceHook(@"AVPlayerItem", @"initWithAsset:",
                              (IMP)YTzoomItemInitWithAsset, &OriginalItemInitWithAsset);
    YTzoomInstallInstanceHook(@"AVPlayerItem", @"initWithAsset:automaticallyLoadedAssetKeys:",
                              (IMP)YTzoomItemInitWithAssetKeys, &OriginalItemInitWithAssetKeys);
    YTzoomInstallInstanceHook(@"AVAssetReader", @"initWithAsset:error:",
                              (IMP)YTzoomReaderInit, &OriginalReaderInit);
    YTzoomInstallInstanceHook(@"AVAssetExportSession", @"initWithAsset:presetName:",
                              (IMP)YTzoomExportInit, &OriginalExportInit);
    YTzoomInstallInstanceHook(@"AVAssetImageGenerator", @"initWithAsset:",
                              (IMP)YTzoomGeneratorInit, &OriginalGeneratorInit);

    for (NSString *name in @[UITextViewTextDidChangeNotification, UITextFieldTextDidChangeNotification,
                             UITextViewTextDidEndEditingNotification,
                             UITextFieldTextDidEndEditingNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            YTzoomTitleTextChanged(notification);
        }];
    }
}
