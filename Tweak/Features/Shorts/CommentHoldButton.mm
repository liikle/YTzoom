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

// Taps a view the way the user would: the enclosing control, then the
// accessibility action VoiceOver uses, then the view's own tap gestures.
static BOOL YTzoomHoldAllTap(UIView *view) {
    NSUInteger depth = 0;
    for (UIView *current = view; current != nil && depth < 6; current = current.superview, depth++) {
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

- (UIView *)pageRoot {
    return YTzoomHoldAllOwner(self.anchor).view ?: self.window;
}

- (UIView *)commentsRow {
    __weak YTzoomHoldAllButton *weakSelf = self;
    NSString *hold = YTzoomHoldAllOptionText().lowercaseString;
    NSString *basic = YTzoomBasicOptionText().lowercaseString;
    return YTzoomHoldAllFind([self pageRoot], 0, ^BOOL(UIView *view, NSString *text) {
        if (view == weakSelf || [view isDescendantOfView:weakSelf]) return NO;
        NSString *lower = text.lowercaseString;
        if ([lower containsString:hold] || [lower containsString:basic]) return NO;
        return [lower hasPrefix:@"comment"] || ([lower containsString:@"comment"] && lower.length < 60);
    });
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
    [self applyState:on];
}

- (void)applyState:(BOOL)on {
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
    [self waitForOption:on ? YTzoomHoldAllOptionText() : YTzoomBasicOptionText() on:on attempt:0];
}

- (void)waitForOption:(NSString *)option on:(BOOL)on attempt:(NSUInteger)attempt {
    UIView *found = YTzoomHoldAllFindInWindows(^BOOL(UIView *view, NSString *text) {
        (void)view;
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
        YTzoomShowNotice([NSString stringWithFormat:YTzoomLocalized(@"Couldn't find \"%@\" in the menu. Pick it yourself, or change the text in YTzoom settings."), option]);
        return;
    }
    __weak YTzoomHoldAllButton *weakSelf = self;
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
// it sits under the AI title button at the field's right edge. Climbs out of a
// clipping container if one would hide it.
void YTzoomCommentHoldAttachForInput(UIView *input) {
    if (!YTzoomFeatureEnabled(YTzoomHoldAllButtonKey) || input == nil || input.window == nil) return;
    YTzoomHoldAllButton *existing = objc_getAssociatedObject(input, YTzoomHoldAllAssociation);
    if (existing != nil && existing.superview != nil && existing.window != nil) {
        [existing refresh];
        return;
    }
    [existing removeFromSuperview];

    CGFloat side = 36.0;
    UIView *page = YTzoomHoldAllOwner(input).view;
    UIView *host = input.superview;
    while (host != nil && host != page && host.clipsToBounds &&
           CGRectGetMaxY([input convertRect:input.bounds toView:host]) + side + 10.0 > host.bounds.size.height &&
           ![host isKindOfClass:UIScrollView.class]) {
        host = host.superview;
    }
    if (host == nil) return;

    YTzoomHoldAllButton *button = YTzoomHoldAllMake(input, side);
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:input.trailingAnchor constant:-2.0],
        [button.topAnchor constraintEqualToAnchor:input.bottomAnchor constant:8.0],
        [button.widthAnchor constraintEqualToConstant:side],
        [button.heightAnchor constraintEqualToConstant:side]
    ]];
    objc_setAssociatedObject(input, YTzoomHoldAllAssociation, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomDownloadLog(@"holdall", @"attached below %@ host %@", NSStringFromClass(input.class),
                      NSStringFromClass(host.class));
}

void YTzoomCommentHoldDetachForInput(UIView *input) {
    YTzoomHoldAllButton *button = objc_getAssociatedObject(input, YTzoomHoldAllAssociation);
    [button removeFromSuperview];
    objc_setAssociatedObject(input, YTzoomHoldAllAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
