#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// One-tap "Comments: Hold all" on the Shorts upload page. YouTube's server
// sends the comment moderation options, so there is no setting to write
// directly; the button opens YouTube's Comments menu and taps the option.

NSString * const YTzoomHoldAllButtonKey = @"YTzoom.Preference.Upload.HoldAllButton";
NSString * const YTzoomHoldAllTextKey = @"YTzoom.Preference.Upload.HoldAllText";

static const void *YTzoomHoldAllAssociation = &YTzoomHoldAllAssociation;

static NSString *YTzoomHoldAllOptionText(void) {
    id stored = YTzoomPreferenceObject(YTzoomHoldAllTextKey);
    NSString *text = [stored isKindOfClass:NSString.class]
        ? [(NSString *)stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    return text.length != 0 ? text : @"Hold all";
}

// YouTube's label for the upload page's download button, in the app's language.
static NSString *YTzoomHoldAllDownloadLabel(void) {
    static NSString *label;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"Edit_Resources" ofType:@"bundle"];
        NSBundle *bundle = path != nil ? [NSBundle bundleWithPath:path] : nil;
        label = [bundle localizedStringForKey:@"download.access" value:@"Save to camera roll" table:@"Edit"]
            ?: @"Save to camera roll";
    });
    return label;
}

static NSString *YTzoomHoldAllText(UIView *view) {
    NSString *label = view.accessibilityLabel;
    if (label.length != 0) return label;
    if ([view isKindOfClass:UILabel.class]) return ((UILabel *)view).text;
    if ([view isKindOfClass:UIButton.class]) return [(UIButton *)view titleForState:UIControlStateNormal];
    return nil;
}

static BOOL YTzoomHoldAllVisible(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if (current.hidden || current.alpha < 0.01) return NO;
    }
    return view.window != nil;
}

typedef BOOL (^YTzoomHoldAllMatcher)(UIView *view, NSString *text);

static UIView *YTzoomHoldAllFind(UIView *root, NSUInteger depth, YTzoomHoldAllMatcher matcher) {
    if (root == nil || depth > 60 || root.hidden) return nil;
    NSString *text = YTzoomHoldAllText(root);
    if (text.length != 0 && matcher(root, text) && YTzoomHoldAllVisible(root)) return root;
    for (UIView *child in root.subviews) {
        UIView *found = YTzoomHoldAllFind(child, depth + 1, matcher);
        if (found != nil) return found;
    }
    return nil;
}

static UIView *YTzoomHoldAllFindInWindows(YTzoomHoldAllMatcher matcher) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        NSArray<UIWindow *> *windows = [((UIWindowScene *)scene).windows reverseObjectEnumerator].allObjects;
        for (UIWindow *window in windows) {
            UIView *found = YTzoomHoldAllFind(window, 0, matcher);
            if (found != nil) return found;
        }
    }
    return nil;
}

// Taps a view the way the user would, trying in order: the enclosing control,
// the accessibility action VoiceOver uses, then the view's tap gestures.
static BOOL YTzoomHoldAllTap(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *current = view; current != nil && depth < 6; current = current.superview, depth++) {
        if ([current isKindOfClass:UISwitch.class]) return NO;   // never flip a toggle
        if ([current isKindOfClass:UIControl.class] && ((UIControl *)current).enabled) {
            [(UIControl *)current sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
    }
    depth = 0;
    for (UIView *current = view; current != nil && depth < 4; current = current.superview, depth++) {
        if ([current accessibilityActivate]) return YES;
    }
    depth = 0;
    for (UIView *current = view; current != nil && depth < 6; current = current.superview, depth++) {
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled) continue;
            NSArray *targets = nil;
            @try { targets = [recognizer valueForKey:@"_targets"]; } @catch (__unused NSException *exception) {}
            BOOL fired = NO;
            for (id entry in targets) {
                Ivar targetIvar = class_getInstanceVariable(object_getClass(entry), "_target");
                Ivar actionIvar = class_getInstanceVariable(object_getClass(entry), "_action");
                if (targetIvar == NULL || actionIvar == NULL) continue;
                id target = object_getIvar(entry, targetIvar);
                SEL action = *(SEL *)((uint8_t *)(__bridge void *)entry + ivar_getOffset(actionIvar));
                if (target == nil || action == NULL || ![target respondsToSelector:action]) continue;
                ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
                fired = YES;
            }
            if (fired) return YES;
        }
    }
    return NO;
}

static UIViewController *YTzoomHoldAllOwner(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }
    return nil;
}

@interface YTzoomHoldAllButton : UIButton
@property(nonatomic, weak) UIView *downloadView;
@property(nonatomic) BOOL busy;
@end

@implementation YTzoomHoldAllButton

- (UIView *)pageRoot {
    return YTzoomHoldAllOwner(self.downloadView).view ?: self.window;
}

- (UIView *)commentsRow {
    __weak YTzoomHoldAllButton *weakSelf = self;
    NSString *option = YTzoomHoldAllOptionText().lowercaseString;
    return YTzoomHoldAllFind([self pageRoot], 0, ^BOOL(UIView *view, NSString *text) {
        if (view == weakSelf || [view isDescendantOfView:weakSelf]) return NO;
        NSString *lower = text.lowercaseString;
        return [lower hasPrefix:@"comment"] || ([lower containsString:@"comment"] && lower.length < 60 &&
                                                ![lower containsString:option]);
    });
}

- (void)holdAll {
    if (self.busy) return;
    UIView *row = [self commentsRow];
    if (row == nil) {
        YTzoomShowNotice(YTzoomLocalized(@"Couldn't find the Comments setting on this page."));
        return;
    }
    if (!YTzoomHoldAllTap(row)) {
        YTzoomShowNotice(YTzoomLocalized(@"Couldn't open the Comments setting. Hold the button to copy details."));
        return;
    }
    self.busy = YES;
    [self waitForOption:0];
}

- (void)waitForOption:(NSUInteger)attempt {
    NSString *option = YTzoomHoldAllOptionText().lowercaseString;
    UIView *found = YTzoomHoldAllFindInWindows(^BOOL(UIView *view, NSString *text) {
        (void)view;
        NSString *lower = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
            .lowercaseString;
        return [lower isEqualToString:option] || [lower hasPrefix:[option stringByAppendingString:@","]] ||
            [lower hasPrefix:[option stringByAppendingString:@"\n"]] ||
            [lower hasPrefix:[option stringByAppendingString:@" "]];
    });
    if (found != nil) {
        BOOL tapped = YTzoomHoldAllTap(found);
        self.busy = NO;
        YTzoomDownloadLog(@"holdall", @"option %@ tapped %d", NSStringFromClass(found.class), tapped);
        YTzoomShowNotice(tapped ? YTzoomLocalized(@"Comments set to Hold all.")
                                : YTzoomLocalized(@"Tap Hold all to finish."));
        return;
    }
    if (attempt >= 26) {
        self.busy = NO;
        YTzoomShowNotice([NSString stringWithFormat:YTzoomLocalized(@"Couldn't find \"%@\" in the menu. Pick it yourself, or change the text in YTzoom settings."),
                          YTzoomHoldAllOptionText()]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self waitForOption:attempt + 1];
    });
}

- (void)copyDiagnostics:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    UIView *row = [self commentsRow];
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (UIView *view = row; view != nil && chain.count < 8; view = view.superview) {
        [chain addObject:NSStringFromClass(view.class)];
    }
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:
        @"YTzoom Hold all button\nYouTube %@\nPage: %@\nComments row: %@\nRow text: %@\nOption text: %@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        NSStringFromClass(YTzoomHoldAllOwner(self.downloadView).class),
        row != nil ? [chain componentsJoinedByString:@" > "] : @"not found",
        YTzoomHoldAllText(row) ?: @"", YTzoomHoldAllOptionText()];
    YTzoomShowNotice(YTzoomLocalized(@"Copied this screen's class names."));
}

@end

static void YTzoomHoldAllAttach(UIView *download) {
    YTzoomHoldAllButton *existing = objc_getAssociatedObject(download, YTzoomHoldAllAssociation);
    if (existing != nil && existing.superview != nil) return;

    CGSize size = download.bounds.size;
    CGFloat side = MAX(32.0, MIN(MAX(size.width, size.height), 56.0));
    // Climb out of containers that would clip a button placed below the download button.
    UIView *host = download.superview;
    UIView *page = YTzoomHoldAllOwner(download).view;
    while (host != nil && host != page && host.clipsToBounds &&
           CGRectGetMaxY([download convertRect:download.bounds toView:host]) + side + 12.0 > host.bounds.size.height &&
           ![host isKindOfClass:UIScrollView.class]) {
        host = host.superview;
    }
    if (host == nil) return;

    YTzoomHoldAllButton *button = [YTzoomHoldAllButton buttonWithType:UIButtonTypeSystem];
    button.downloadView = download;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:side * 0.42 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"bubble.left.and.exclamationmark.bubble.right"
                             withConfiguration:configuration]
        ?: [UIImage systemImageNamed:@"exclamationmark.bubble" withConfiguration:configuration];
    [button setImage:image forState:UIControlStateNormal];
    button.tintColor = download.tintColor ?: UIColor.whiteColor;
    button.backgroundColor = download.backgroundColor ?: [UIColor colorWithWhite:0.0 alpha:0.35];
    if (CGColorGetAlpha(button.backgroundColor.CGColor) < 0.05) {
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    }
    button.layer.cornerRadius = side / 2.0;
    button.layer.masksToBounds = YES;
    button.accessibilityLabel = YTzoomLocalized(@"Hold All Comments");
    button.accessibilityIdentifier = @"YTzoom.HoldAllButton";
    [button addTarget:button action:@selector(holdAll) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:button action:@selector(copyDiagnostics:)]];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.centerXAnchor constraintEqualToAnchor:download.centerXAnchor],
        [button.topAnchor constraintEqualToAnchor:download.bottomAnchor constant:10.0],
        [button.widthAnchor constraintEqualToConstant:side],
        [button.heightAnchor constraintEqualToConstant:side]
    ]];
    objc_setAssociatedObject(download, YTzoomHoldAllAssociation, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomDownloadLog(@"holdall", @"attached below %@", NSStringFromClass(download.class));
}

static void YTzoomHoldAllScan(UIView *input) {
    if (!YTzoomFeatureEnabled(YTzoomHoldAllButtonKey) || input.window == nil) return;
    UIView *page = YTzoomHoldAllOwner(input).view ?: input.window;
    NSString *label = YTzoomHoldAllDownloadLabel().lowercaseString;
    UIView *download = YTzoomHoldAllFind(page, 0, ^BOOL(UIView *view, NSString *text) {
        return [text.lowercaseString isEqualToString:label] && view.bounds.size.width <= 120.0;
    });
    if (download != nil) YTzoomHoldAllAttach(download);
}

void YTzoomCommentHoldConsider(UIView *input) {
    if (!YTzoomFeatureEnabled(YTzoomHoldAllButtonKey) || input.window == nil) return;
    // The download button can lay out after the text box, so look twice.
    __weak UIView *weakInput = input;
    for (NSNumber *delay in @[@0.3, @1.2]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIView *strongInput = weakInput;
            if (strongInput != nil) YTzoomHoldAllScan(strongInput);
        });
    }
}
