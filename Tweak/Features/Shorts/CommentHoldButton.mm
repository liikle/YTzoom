#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// A comments toggle on the Shorts upload page, below the AI title button.
// Tapping it drives YouTube's own Comments → moderation menu in one shot:
//   on  — a crossed-out comment icon, sets "Hold all"
//   off — a normal comment icon, sets "Basic"
// YouTube sends that menu's text from the server, so both options are
// configurable for other languages.

NSString * const YTzoomHoldAllButtonKey = @"YTzoom.Preference.Upload.HoldAllButton";
NSString * const YTzoomHoldAllActiveKey = @"YTzoom.Preference.Upload.HoldAll";
NSString * const YTzoomHoldAllTextKey = @"YTzoom.Preference.Upload.HoldAllText";
NSString * const YTzoomHoldAllBasicTextKey = @"YTzoom.Preference.Upload.BasicText";

static const void *YTzoomHoldAllAssociation = &YTzoomHoldAllAssociation;

static NSString *YTzoomHoldAllOptionText(void) {
    id stored = YTzoomPreferenceObject(YTzoomHoldAllTextKey);
    NSString *text = [stored isKindOfClass:NSString.class]
        ? [(NSString *)stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    return text.length != 0 ? text : @"Hold all";
}

static NSString *YTzoomBasicOptionText(void) {
    id stored = YTzoomPreferenceObject(YTzoomHoldAllBasicTextKey);
    NSString *text = [stored isKindOfClass:NSString.class]
        ? [(NSString *)stored stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
    return text.length != 0 ? text : @"Basic";
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

static BOOL YTzoomHoldAllInsideText(UIView *view) {
    for (UIView *current = view; current != nil; current = current.superview) {
        if ([current isKindOfClass:UITextField.class] || [current isKindOfClass:UITextView.class]) return YES;
    }
    return NO;
}

// Selects the list cell `view` sits in the way UIKit does on a tap: through
// the list's own delegate.
static BOOL YTzoomHoldAllSelectCell(UIView *view) {
    UIView *cell = view;
    while (cell != nil && ![cell isKindOfClass:UICollectionViewCell.class] &&
           ![cell isKindOfClass:UITableViewCell.class]) {
        cell = cell.superview;
    }
    UIView *list = cell.superview;
    while (list != nil && ![list isKindOfClass:UICollectionView.class] && ![list isKindOfClass:UITableView.class]) {
        list = list.superview;
    }
    if (cell == nil || list == nil) return NO;
    if ([list isKindOfClass:UICollectionView.class] && [cell isKindOfClass:UICollectionViewCell.class]) {
        UICollectionView *collection = (UICollectionView *)list;
        NSIndexPath *path = [collection indexPathForCell:(UICollectionViewCell *)cell];
        id<UICollectionViewDelegate> delegate = collection.delegate;
        if (path == nil || ![delegate respondsToSelector:@selector(collectionView:didSelectItemAtIndexPath:)]) return NO;
        if ([delegate respondsToSelector:@selector(collectionView:shouldSelectItemAtIndexPath:)] &&
            ![delegate collectionView:collection shouldSelectItemAtIndexPath:path]) {
            return NO;
        }
        [delegate collectionView:collection didSelectItemAtIndexPath:path];
        return YES;
    }
    if ([list isKindOfClass:UITableView.class] && [cell isKindOfClass:UITableViewCell.class]) {
        UITableView *table = (UITableView *)list;
        NSIndexPath *path = [table indexPathForCell:(UITableViewCell *)cell];
        id<UITableViewDelegate> delegate = table.delegate;
        if (path == nil || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
        if ([delegate respondsToSelector:@selector(tableView:willSelectRowAtIndexPath:)]) {
            path = [delegate tableView:table willSelectRowAtIndexPath:path];
            if (path == nil) return NO;
        }
        [delegate tableView:table didSelectRowAtIndexPath:path];
        return YES;
    }
    return NO;
}

// For rows that only answer a tap gesture (YouTube's Elements rows): runs the
// row's own tap handler. Only recognizers on the row or a parent of about its
// height, never UIKit's own handlers (text selection, sheet dismissal), and
// only handlers taking no argument or one object.
static BOOL YTzoomHoldAllFireTapGesture(UIView *view) {
    CGFloat limit = MAX(view.bounds.size.height * 3.0, 120.0);
    NSUInteger depth = 0;
    for (UIView *current = view; current != nil && depth < 4; current = current.superview, depth++) {
        if ([current isKindOfClass:UIScrollView.class] || [current isKindOfClass:UIWindow.class] ||
            current.bounds.size.height > limit) {
            break;
        }
        for (UIGestureRecognizer *recognizer in current.gestureRecognizers) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class] || !recognizer.enabled ||
                ((UITapGestureRecognizer *)recognizer).numberOfTapsRequired != 1) {
                continue;
            }
            id targets = nil;
            @try { targets = [recognizer valueForKey:@"_targets"]; } @catch (__unused NSException *exception) {}
            if (![targets isKindOfClass:NSArray.class]) continue;
            for (id entry in (NSArray *)targets) {
                Ivar targetIvar = class_getInstanceVariable(object_getClass(entry), "_target");
                Ivar actionIvar = class_getInstanceVariable(object_getClass(entry), "_action");
                if (targetIvar == NULL || actionIvar == NULL) continue;
                const char *targetType = ivar_getTypeEncoding(targetIvar);
                const char *actionType = ivar_getTypeEncoding(actionIvar);
                if (targetType == NULL || targetType[0] != '@' || actionType == NULL || strcmp(actionType, ":") != 0) {
                    continue;
                }
                id target = object_getIvar(entry, targetIvar);
                SEL action = *(SEL *)((uint8_t *)(__bridge void *)entry + ivar_getOffset(actionIvar));
                if (target == nil || action == NULL || ![target respondsToSelector:action]) continue;
                NSString *targetClass = NSStringFromClass(object_getClass(target));
                if ([targetClass hasPrefix:@"UI"] || [targetClass hasPrefix:@"_UI"]) continue;
                NSMethodSignature *signature = [target methodSignatureForSelector:action];
                if (signature == nil || signature.numberOfArguments > 3 ||
                    (signature.numberOfArguments == 3 && [signature getArgumentTypeAtIndex:2][0] != '@')) {
                    continue;
                }
                @try {
                    if (signature.numberOfArguments == 2) {
                        ((void (*)(id, SEL))objc_msgSend)(target, action);
                    } else {
                        ((void (*)(id, SEL, id))objc_msgSend)(target, action, recognizer);
                    }
                    return YES;
                } @catch (NSException *exception) {
                    YTzoomDownloadLog(@"holdall", @"tap handler %@ %@ threw %@", targetClass,
                                      NSStringFromSelector(action), exception.reason);
                }
            }
        }
    }
    return NO;
}

// Taps a view the way the user would: the enclosing button, the accessibility
// action VoiceOver uses, the row's tap gesture, then list-cell selection. A
// handler that throws is caught here so a failed tap can't take the app down.
static BOOL YTzoomHoldAllTap(UIView *view) {
    if (view == nil || view.window == nil || YTzoomHoldAllInsideText(view)) return NO;
    @try {
        NSUInteger depth = 0;
        for (UIView *current = view; current != nil && depth < 4; current = current.superview, depth++) {
            if ([current isKindOfClass:UISwitch.class]) return NO;
            if ([current isKindOfClass:UIControl.class] && ((UIControl *)current).enabled) {
                [(UIControl *)current sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
        depth = 0;
        for (UIView *current = view; current != nil && depth < 4; current = current.superview, depth++) {
            if ([current accessibilityActivate]) return YES;
        }
        if (YTzoomHoldAllFireTapGesture(view)) return YES;
        return YTzoomHoldAllSelectCell(view);
    } @catch (NSException *exception) {
        YTzoomDownloadLog(@"holdall", @"tap on %@ threw %@", NSStringFromClass(view.class), exception.reason);
        return NO;
    }
}

static UIViewController *YTzoomHoldAllOwner(UIView *view) {
    for (UIResponder *responder = view; responder != nil; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UIViewController.class]) return (UIViewController *)responder;
    }
    return nil;
}

// The page's top-level view: the nearest view controller's root view that
// actually contains `input`, so constraints between the two always share an
// ancestor (activating them otherwise throws).
static UIView *YTzoomHoldAllHost(UIView *input) {
    for (UIView *current = input.superview; current != nil; current = current.superview) {
        if ([current isKindOfClass:UIWindow.class]) return nil;
        UIResponder *next = current.nextResponder;
        if ([next isKindOfClass:UIViewController.class] && ((UIViewController *)next).viewIfLoaded == current) {
            return current;
        }
    }
    return nil;
}

static BOOL YTzoomHoldAllTextMatches(NSString *candidate, NSString *option) {
    NSString *lower = [candidate stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
        .lowercaseString;
    NSString *target = option.lowercaseString;
    return [lower isEqualToString:target] || [lower hasPrefix:[target stringByAppendingString:@","]] ||
        [lower hasPrefix:[target stringByAppendingString:@"\n"]] ||
        [lower hasPrefix:[target stringByAppendingString:@" "]];
}

@interface YTzoomHoldAllButton : UIButton
@property(nonatomic, weak) UIView *anchor;
@property(nonatomic, strong) CAShapeLayer *slash;
@property(nonatomic) BOOL busy;
@end

@implementation YTzoomHoldAllButton

- (UIView *)commentsRow {
    __weak YTzoomHoldAllButton *weakSelf = self;
    NSString *hold = YTzoomHoldAllOptionText().lowercaseString;
    NSString *basic = YTzoomBasicOptionText().lowercaseString;
    YTzoomHoldAllMatcher matcher = ^BOOL(UIView *view, NSString *text) {
        if (view == weakSelf || [view isDescendantOfView:weakSelf] || YTzoomHoldAllInsideText(view)) return NO;
        NSString *lower = text.lowercaseString;
        if ([lower containsString:hold] || [lower containsString:basic]) return NO;
        return [lower hasPrefix:@"comment"] || ([lower containsString:@"comment"] && lower.length < 60);
    };
    UIView *page = self.anchor != nil ? YTzoomHoldAllHost(self.anchor) : nil;
    return YTzoomHoldAllFind(page ?: self.superview, 0, matcher) ?: YTzoomHoldAllFind(self.window, 0, matcher);
}

- (void)refresh {
    BOOL on = YTzoomFeatureEnabled(YTzoomHoldAllActiveKey);
    self.slash.hidden = !on;
    self.tintColor = on ? [UIColor colorWithRed:1.0 green:0.84 blue:0.04 alpha:1.0] : UIColor.whiteColor;
    self.accessibilityLabel = on ? YTzoomLocalized(@"Comments: Hold All")
                                  : YTzoomLocalized(@"Comments: Basic");
    self.accessibilityValue = on ? YTzoomLocalized(@"On") : YTzoomLocalized(@"Off");
}

- (void)toggle {
    if (self.busy) return;
    BOOL on = !YTzoomFeatureEnabled(YTzoomHoldAllActiveKey);
    YTzoomSetPreference(YTzoomHoldAllActiveKey, on);
    [self refresh];
    // Drive YouTube's menu on the next turn of the run loop, outside this
    // button's own touch handling.
    self.busy = YES;
    __weak YTzoomHoldAllButton *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        YTzoomHoldAllButton *button = weakSelf;
        button.busy = NO;
        [button applyState:on];
    });
}

- (void)applyState:(BOOL)on {
    UIView *row = [self commentsRow];
    if (row == nil) {
        [self revertTo:!on];
        YTzoomShowNotice(YTzoomLocalized(@"Couldn't find the Comments setting on this page."));
        return;
    }
    if (!YTzoomHoldAllTap(row)) {
        [self revertTo:!on];
        YTzoomShowNotice(YTzoomLocalized(@"Couldn't open the Comments setting. Hold the button to copy details."));
        return;
    }
    self.busy = YES;
    [self waitForOption:on ? YTzoomHoldAllOptionText() : YTzoomBasicOptionText() on:on attempt:0];
}

// The menu wasn't driven, so the icon goes back to what YouTube still has.
- (void)revertTo:(BOOL)on {
    YTzoomSetPreference(YTzoomHoldAllActiveKey, on);
    [self refresh];
}

- (void)waitForOption:(NSString *)option on:(BOOL)on attempt:(NSUInteger)attempt {
    __weak YTzoomHoldAllButton *weakSelf = self;
    UIView *found = YTzoomHoldAllFindInWindows(^BOOL(UIView *view, NSString *text) {
        if (view == weakSelf || [view isDescendantOfView:weakSelf] || YTzoomHoldAllInsideText(view)) return NO;
        return YTzoomHoldAllTextMatches(text, option);
    });
    if (found != nil) {
        BOOL tapped = YTzoomHoldAllTap(found);
        self.busy = NO;
        YTzoomDownloadLog(@"holdall", @"%@ option %@ tapped %d", on ? @"hold" : @"basic",
                          NSStringFromClass(found.class), tapped);
        if (tapped) {
            YTzoomShowNotice(on ? YTzoomLocalized(@"Comments set to Hold all.")
                                : YTzoomLocalized(@"Comments set to Basic."));
        } else {
            YTzoomShowNotice([NSString stringWithFormat:YTzoomLocalized(@"Tap \"%@\" to finish."), option]);
        }
        return;
    }
    if (attempt >= 26) {
        self.busy = NO;
        [self revertTo:!on];
        YTzoomShowNotice([NSString stringWithFormat:YTzoomLocalized(@"Couldn't find \"%@\" in the menu. Pick it yourself, or change the text in YTzoom settings."), option]);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf waitForOption:option on:on attempt:attempt + 1];
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
        @"YTzoom comments toggle\nYouTube %@\nPage: %@\nComments row: %@\nRow text: %@\nHold text: %@\nBasic text: %@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        NSStringFromClass(YTzoomHoldAllOwner(self.anchor).class),
        row != nil ? [chain componentsJoinedByString:@" > "] : @"not found",
        YTzoomHoldAllText(row) ?: @"", YTzoomHoldAllOptionText(), YTzoomBasicOptionText()];
    YTzoomShowNotice(YTzoomLocalized(@"Copied this screen's class names."));
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // A diagonal slash across the comment icon for the on (Hold all) state.
    CGFloat inset = self.bounds.size.width * 0.24;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(inset, self.bounds.size.height - inset)];
    [path addLineToPoint:CGPointMake(self.bounds.size.width - inset, inset)];
    self.slash.path = path.CGPath;
    self.slash.frame = self.bounds;
    self.slash.strokeColor = self.tintColor.CGColor;
    self.slash.lineWidth = MAX(2.0, self.bounds.size.width * 0.06);
}

@end

static YTzoomHoldAllButton *YTzoomHoldAllMake(UIView *anchor, CGFloat side) {
    YTzoomHoldAllButton *button = [YTzoomHoldAllButton buttonWithType:UIButtonTypeSystem];
    button.anchor = anchor;
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:side * 0.46 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"bubble.left" withConfiguration:configuration]
        ?: [UIImage systemImageNamed:@"text.bubble" withConfiguration:configuration];
    [button setImage:image forState:UIControlStateNormal];
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.35];
    button.layer.cornerRadius = side / 2.0;
    button.layer.masksToBounds = YES;
    button.accessibilityIdentifier = @"YTzoom.HoldAllButton";
    button.slash = [CAShapeLayer layer];
    button.slash.fillColor = UIColor.clearColor.CGColor;
    button.slash.lineCap = kCALineCapRound;
    [button.layer addSublayer:button.slash];
    [button addTarget:button action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
        initWithTarget:button action:@selector(copyDiagnostics:)]];
    [button refresh];
    return button;
}

// Attaches the toggle just below the title field `input`, trailing-aligned so
// it sits under the AI title button at the field's right edge. The button goes
// on the page's top-level view, not nested in the title field's container, so
// nothing clips it; it is clamped inside the safe area so it is never cut off.
void YTzoomCommentHoldAttachForInput(UIView *input) {
    if (!YTzoomFeatureEnabled(YTzoomHoldAllButtonKey) || input == nil || input.window == nil) return;
    YTzoomHoldAllButton *existing = objc_getAssociatedObject(input, YTzoomHoldAllAssociation);
    if (existing != nil && existing.superview != nil && existing.window != nil) {
        [existing refresh];
        return;
    }
    [existing removeFromSuperview];

    CGFloat side = 36.0;
    UIView *host = YTzoomHoldAllHost(input);
    if (host == nil || ![input isDescendantOfView:host]) return;

    YTzoomHoldAllButton *button = YTzoomHoldAllMake(input, side);
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:button];
    [host bringSubviewToFront:button];
    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    // Below the title field, aligned to its right edge, but kept fully inside
    // the safe area so it can't fall off the bottom or the side.
    NSLayoutConstraint *below = [button.topAnchor constraintEqualToAnchor:input.bottomAnchor constant:8.0];
    below.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *right = [button.trailingAnchor constraintEqualToAnchor:input.trailingAnchor constant:-2.0];
    right.priority = UILayoutPriorityDefaultHigh;
    @try {
        [NSLayoutConstraint activateConstraints:@[
            below, right,
            [button.widthAnchor constraintEqualToConstant:side],
            [button.heightAnchor constraintEqualToConstant:side],
            [button.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:4.0],
            [button.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-4.0],
            [button.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-4.0],
            [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:4.0]
        ]];
    } @catch (NSException *exception) {
        YTzoomDownloadLog(@"holdall", @"couldn't place the toggle: %@", exception.reason);
        [button removeFromSuperview];
        return;
    }
    objc_setAssociatedObject(input, YTzoomHoldAllAssociation, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomDownloadLog(@"holdall", @"attached below %@ host %@", NSStringFromClass(input.class),
                      NSStringFromClass(host.class));
}

void YTzoomCommentHoldDetachForInput(UIView *input) {
    YTzoomHoldAllButton *button = objc_getAssociatedObject(input, YTzoomHoldAllAssociation);
    [button removeFromSuperview];
    objc_setAssociatedObject(input, YTzoomHoldAllAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
