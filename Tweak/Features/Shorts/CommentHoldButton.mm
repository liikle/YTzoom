#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"

#import <QuartzCore/QuartzCore.h>
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

#pragma mark - What's on screen

// Something on screen with text: a view, or an accessibility element of a
// view. YouTube's Elements UI (Texture) draws a lot of text without any view;
// that text only exists as accessibility elements of the container view.
@interface YTzoomHoldAllItem : NSObject
@property(nonatomic, weak) UIView *view;        // the view, or the element's container
@property(nonatomic, weak) UIWindow *window;
@property(nonatomic, strong) id element;        // a non-view accessibility element, or nil
@property(nonatomic, copy) NSString *text;      // lowercased, whitespace collapsed
@property(nonatomic, copy) NSString *original;
@property(nonatomic) CGRect frame;              // window coordinates
@property(nonatomic) UIAccessibilityTraits traits;
@property(nonatomic) NSUInteger order;          // traversal order; later is drawn on top
@end

@implementation YTzoomHoldAllItem
@end

static NSString *YTzoomHoldAllNormalize(NSString *text) {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [text.lowercaseString
             componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (word.length != 0) [words addObject:word];
    }
    return [words componentsJoinedByString:@" "];
}

static NSString *YTzoomHoldAllCombine(NSString *label, NSString *value) {
    if (label.length == 0) return value.length != 0 ? value : nil;
    return value.length != 0 && ![value isEqualToString:label] ? [NSString stringWithFormat:@"%@, %@", label, value] : label;
}

static NSString *YTzoomHoldAllViewText(UIView *view) {
    NSString *label = view.accessibilityLabel;
    if (label.length == 0 && [view isKindOfClass:UILabel.class]) label = ((UILabel *)view).text;
    if (label.length == 0 && [view isKindOfClass:UIButton.class]) label = [(UIButton *)view titleForState:UIControlStateNormal];
    return YTzoomHoldAllCombine(label, view.accessibilityValue);
}

static void YTzoomHoldAllAdd(NSMutableArray<YTzoomHoldAllItem *> *items, UIView *view, UIWindow *window, id element,
                             NSString *text, CGRect frame, UIAccessibilityTraits traits) {
    NSString *normalized = YTzoomHoldAllNormalize(text);
    if (normalized.length == 0) return;
    YTzoomHoldAllItem *item = [YTzoomHoldAllItem new];
    item.view = view;
    item.window = window;
    item.element = element;
    item.text = normalized;
    item.original = text;
    item.frame = frame;
    item.traits = traits;
    item.order = items.count;
    [items addObject:item];
}

static void YTzoomHoldAllCollect(UIView *view, UIWindow *window, NSUInteger depth, UIView *exclude,
                                 NSMutableArray<YTzoomHoldAllItem *> *items) {
    if (view == nil || depth > 60 || view.hidden || view.alpha < 0.01 || view == exclude) return;
    if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) return;
    CGRect frame = [view convertRect:view.bounds toView:window];
    BOOL onScreen = frame.size.width >= 1.0 && frame.size.height >= 1.0 && CGRectIntersectsRect(frame, window.bounds);
    if (onScreen) {
        NSString *text = YTzoomHoldAllViewText(view);
        if (text.length != 0) YTzoomHoldAllAdd(items, view, window, nil, text, frame, view.accessibilityTraits);
        NSArray *elements = nil;
        @try { elements = view.accessibilityElements; } @catch (__unused NSException *exception) {}
        for (id element in elements) {
            if ([element isKindOfClass:UIView.class] || ![element respondsToSelector:@selector(accessibilityFrame)]) continue;
            NSString *elementText = YTzoomHoldAllCombine([element accessibilityLabel], [element accessibilityValue]);
            if (elementText.length == 0) continue;
            CGRect elementFrame = [window convertRect:[element accessibilityFrame]
                                  fromCoordinateSpace:window.screen.coordinateSpace];
            if (!CGRectIntersectsRect(elementFrame, window.bounds)) continue;
            YTzoomHoldAllAdd(items, view, window, element, elementText, elementFrame, [element accessibilityTraits]);
        }
    } else if (view.clipsToBounds) {
        return;
    }
    for (UIView *child in view.subviews) YTzoomHoldAllCollect(child, window, depth + 1, exclude, items);
}

static NSArray<UIWindow *> *YTzoomHoldAllWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
        }
    }
    [windows sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        return a.windowLevel < b.windowLevel ? NSOrderedAscending
             : a.windowLevel > b.windowLevel ? NSOrderedDescending : NSOrderedSame;
    }];
    return windows;
}

// Everything with text on screen, bottom to top.
static NSArray<YTzoomHoldAllItem *> *YTzoomHoldAllItems(UIView *exclude) {
    NSMutableArray<YTzoomHoldAllItem *> *items = [NSMutableArray array];
    for (UIWindow *window in YTzoomHoldAllWindows()) YTzoomHoldAllCollect(window, window, 0, exclude, items);
    return items;
}

// What a finger at the item's centre would land on, and whether that is the
// item (or its row) rather than something covering it, like a sheet.
static UIView *YTzoomHoldAllHitView(YTzoomHoldAllItem *item, BOOL *reachable) {
    UIWindow *window = item.window;
    UIView *view = item.view;
    CGPoint center = CGPointMake(CGRectGetMidX(item.frame), CGRectGetMidY(item.frame));
    UIView *hit = window != nil && CGRectContainsPoint(window.bounds, center) ? [window hitTest:center withEvent:nil] : nil;
    if (reachable != NULL) {
        *reachable = hit != nil && view != nil &&
            (hit == view || [hit isDescendantOfView:view] || [view isDescendantOfView:hit]);
    }
    return hit;
}

static BOOL YTzoomHoldAllReachable(YTzoomHoldAllItem *item) {
    BOOL reachable = NO;
    YTzoomHoldAllHitView(item, &reachable);
    return reachable;
}

static BOOL YTzoomHoldAllIsLetter(unichar character) {
    return [NSCharacterSet.letterCharacterSet characterIsMember:character];
}

// How well `text` names `option`: 3 exactly, 2 starts with it ("hold all
// comments for review"), 1 has it as whole words in a short label ("selected,
// hold all"), 0 not at all.
static NSInteger YTzoomHoldAllScore(NSString *text, NSString *option) {
    if (option.length == 0 || text.length < option.length) return 0;
    if ([text isEqualToString:option]) return 3;
    if ([text hasPrefix:option] && !YTzoomHoldAllIsLetter([text characterAtIndex:option.length])) return 2;
    if (text.length > 100 || [text hasPrefix:@"comment"]) return 0;
    NSRange range = [text rangeOfString:option];
    while (range.location != NSNotFound) {
        NSUInteger end = NSMaxRange(range);
        BOOL startsWord = range.location == 0 || !YTzoomHoldAllIsLetter([text characterAtIndex:range.location - 1]);
        BOOL endsWord = end == text.length || !YTzoomHoldAllIsLetter([text characterAtIndex:end]);
        if (startsWord && endsWord) return 1;
        range = [text rangeOfString:option options:0 range:NSMakeRange(range.location + 1, text.length - range.location - 1)];
    }
    return 0;
}

typedef NSInteger (^YTzoomHoldAllScorer)(YTzoomHoldAllItem *item);

// The best match, preferring one a finger can reach, then the one on top.
static YTzoomHoldAllItem *YTzoomHoldAllBest(NSArray<YTzoomHoldAllItem *> *items, YTzoomHoldAllScorer scorer) {
    YTzoomHoldAllItem *best = nil;
    NSInteger bestScore = 0;
    BOOL bestReachable = NO;
    for (YTzoomHoldAllItem *item in items) {
        NSInteger score = scorer(item);
        if (score <= 0) continue;
        BOOL reachable = YTzoomHoldAllReachable(item);
        if (best == nil || (reachable && !bestReachable) ||
            (reachable == bestReachable && (score > bestScore || (score == bestScore && item.order > best.order)))) {
            best = item;
            bestScore = score;
            bestReachable = reachable;
        }
    }
    return best;
}

#pragma mark - Tapping

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

// Runs the tap handler a real touch at that spot would trigger: the innermost
// single-tap recognizer on the touched view or its parents (YouTube's Elements
// rows answer taps this way). Never UIKit's own handlers (text selection,
// sheet dismissal), only handlers taking nothing or one object, and an
// exception from the handler is caught.
static BOOL YTzoomHoldAllFireTapGesture(UIView *start, NSString **detail) {
    NSUInteger depth = 0;
    for (UIView *current = start; current != nil && depth < 10; current = current.superview, depth++) {
        if ([current isKindOfClass:UIWindow.class]) break;
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
                    if (detail != NULL) {
                        *detail = [NSString stringWithFormat:@"%@ %@ on %@", targetClass, NSStringFromSelector(action),
                                   NSStringFromClass(current.class)];
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

// The ways to tap something, tried one at a time until one visibly works.
typedef NS_ENUM(NSInteger, YTzoomHoldAllMethod) {
    YTzoomHoldAllMethodControl = 0,   // the button (UIControl) under the finger
    YTzoomHoldAllMethodActivate,      // the accessibility action VoiceOver uses
    YTzoomHoldAllMethodGesture,       // the tap handler a touch there would run
    YTzoomHoldAllMethodCell,          // select the list cell
    YTzoomHoldAllMethodCount
};

static NSString *YTzoomHoldAllMethodName(NSInteger method) {
    switch (method) {
        case YTzoomHoldAllMethodControl: return @"control";
        case YTzoomHoldAllMethodActivate: return @"accessibility";
        case YTzoomHoldAllMethodGesture: return @"gesture";
        case YTzoomHoldAllMethodCell: return @"cell";
    }
    return @"?";
}

// Tries one method on the item. NO when it doesn't apply (nothing done).
static BOOL YTzoomHoldAllTapItem(YTzoomHoldAllItem *item, NSInteger method, NSString **detail) {
    UIView *view = item.view;
    if (view == nil || view.window == nil || YTzoomHoldAllInsideText(view)) return NO;
    BOOL reachable = NO;
    UIView *hit = YTzoomHoldAllHitView(item, &reachable);
    UIView *start = reachable && hit != nil ? hit : view;
    @try {
        switch (method) {
            case YTzoomHoldAllMethodControl: {
                NSUInteger depth = 0;
                for (UIView *current = start; current != nil && depth < 6; current = current.superview, depth++) {
                    if ([current isKindOfClass:UISwitch.class] || [current isKindOfClass:UIWindow.class]) return NO;
                    if ([current isKindOfClass:UIControl.class] && ((UIControl *)current).enabled) {
                        [(UIControl *)current sendActionsForControlEvents:UIControlEventTouchUpInside];
                        if (detail != NULL) *detail = NSStringFromClass(current.class);
                        return YES;
                    }
                }
                return NO;
            }
            case YTzoomHoldAllMethodActivate: {
                if (item.element != nil && [item.element accessibilityActivate]) {
                    if (detail != NULL) *detail = NSStringFromClass([item.element class]);
                    return YES;
                }
                NSUInteger depth = 0;
                for (UIView *current = item.element != nil ? view : start; current != nil && depth < 4;
                     current = current.superview, depth++) {
                    if ([current accessibilityActivate]) {
                        if (detail != NULL) *detail = NSStringFromClass(current.class);
                        return YES;
                    }
                }
                return NO;
            }
            case YTzoomHoldAllMethodGesture:
                return YTzoomHoldAllFireTapGesture(start, detail);
            case YTzoomHoldAllMethodCell:
                if (YTzoomHoldAllSelectCell(start)) {
                    if (detail != NULL) *detail = @"list delegate";
                    return YES;
                }
                return NO;
        }
    } @catch (NSException *exception) {
        YTzoomDownloadLog(@"holdall", @"%@ tap threw %@", YTzoomHoldAllMethodName(method), exception.reason);
    }
    return NO;
}

#pragma mark - Pages

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

static UIWindow *YTzoomHoldAllKeyWindow(void) {
    UIWindow *key = nil;
    for (UIWindow *window in YTzoomHoldAllWindows()) {
        if (window.isKeyWindow) key = window;
    }
    return key ?: YTzoomHoldAllWindows().lastObject;
}

static NSString *YTzoomHoldAllTopControllers(void) {
    UIWindow *key = YTzoomHoldAllKeyWindow();
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (UIViewController *controller = key.rootViewController; controller != nil && chain.count < 8;
         controller = controller.presentedViewController) {
        UIViewController *shown = controller;
        if ([controller isKindOfClass:UINavigationController.class]) {
            shown = ((UINavigationController *)controller).topViewController ?: controller;
        }
        [chain addObject:NSStringFromClass(shown.class)];
    }
    return [chain componentsJoinedByString:@" > "];
}

// Vertical scroll views a finger can reach that can still scroll down,
// frontmost first (never one covered by a sheet, like the page behind it).
static NSArray<UIScrollView *> *YTzoomHoldAllScrollables(UIView *root, NSMutableArray<UIScrollView *> *found) {
    if (root == nil || root.hidden || root.alpha < 0.01) return found;
    if ([root isKindOfClass:UIScrollView.class] && ![root isKindOfClass:UITextView.class]) {
        UIScrollView *scroll = (UIScrollView *)root;
        CGFloat maxOffset = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.size.height;
        UIWindow *window = scroll.window;
        if (scroll.scrollEnabled && window != nil && scroll.bounds.size.height > 80.0 &&
            scroll.contentOffset.y < maxOffset - 1.0) {
            CGRect frame = [scroll convertRect:scroll.bounds toView:window];
            UIView *hit = [window hitTest:CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame)) withEvent:nil];
            if (hit == scroll || [hit isDescendantOfView:scroll]) [found insertObject:scroll atIndex:0];
        }
    }
    for (UIView *child in root.subviews) YTzoomHoldAllScrollables(child, found);
    return found;
}



@interface YTzoomHoldAllButton : UIButton
@property(nonatomic, weak) UIView *anchor;
@property(nonatomic, strong) CAShapeLayer *slash;
@property(nonatomic) BOOL busy;
// One run of the menu: open Comments, find the option, tap it, come back.
@property(nonatomic) NSUInteger run;
@property(nonatomic) BOOL targetOn;
@property(nonatomic, copy) NSString *option;
@property(nonatomic) NSInteger method;
@property(nonatomic) CFTimeInterval stepStart;
@property(nonatomic) CFTimeInterval lastScroll;
@property(nonatomic) CFTimeInterval runStart;
@property(nonatomic, copy) NSString *rowText;
@property(nonatomic) CGRect rowFrame;
@property(nonatomic) NSUInteger scrolls;
@property(nonatomic, strong) NSMutableArray<NSString *> *trace;
@property(nonatomic, copy) NSString *lastReport;
@property(nonatomic) BOOL sawSelected;
@end

@implementation YTzoomHoldAllButton

- (void)note:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list arguments;
    va_start(arguments, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    [self.trace addObject:[NSString stringWithFormat:@"%.2fs %@", CACurrentMediaTime() - self.runStart, line]];
    YTzoomDownloadLog(@"holdall", @"%@", line);
}

- (NSArray<YTzoomHoldAllItem *> *)items {
    return YTzoomHoldAllItems(self);
}

// The Comments row on the upload page. The option rows of the menu also say
// "comments" ("Hold all comments for review"), so those are not it.
- (YTzoomHoldAllItem *)commentsRowIn:(NSArray<YTzoomHoldAllItem *> *)items {
    NSString *hold = YTzoomHoldAllNormalize(YTzoomHoldAllOptionText());
    NSString *basic = YTzoomHoldAllNormalize(YTzoomBasicOptionText());
    return YTzoomHoldAllBest(items, ^NSInteger(YTzoomHoldAllItem *item) {
        NSString *text = item.text;
        if ([text hasPrefix:hold] || [text hasPrefix:basic]) return 0;
        if ([text hasPrefix:@"comment"]) return 2;
        return text.length < 60 && YTzoomHoldAllScore(text, @"comments") > 0 ? 1 : 0;
    });
}

- (YTzoomHoldAllItem *)optionIn:(NSArray<YTzoomHoldAllItem *> *)items {
    NSString *option = YTzoomHoldAllNormalize(self.option);
    return YTzoomHoldAllBest(items, ^NSInteger(YTzoomHoldAllItem *item) {
        return YTzoomHoldAllScore(item.text, option);
    });
}

- (NSString *)visibleTexts:(NSArray<YTzoomHoldAllItem *> *)items {
    NSMutableOrderedSet<NSString *> *texts = [NSMutableOrderedSet orderedSet];
    for (YTzoomHoldAllItem *item in items.reverseObjectEnumerator) {
        if (!YTzoomHoldAllReachable(item)) continue;
        NSString *text = item.original.length > 60 ? [[item.original substringToIndex:60] stringByAppendingString:@"…"]
                                                   : item.original;
        [texts addObject:[text stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
        if (texts.count >= 50) break;
    }
    return [texts.array componentsJoinedByString:@" | "];
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
    self.run++;
    self.targetOn = on;
    self.option = on ? YTzoomHoldAllOptionText() : YTzoomBasicOptionText();
    self.method = YTzoomHoldAllMethodControl;
    self.scrolls = 0;
    self.sawSelected = NO;
    self.trace = [NSMutableArray array];
    self.runStart = CACurrentMediaTime();
    [self note:@"set \"%@\" (YouTube %@, page %@)", self.option,
               NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?", YTzoomHoldAllTopControllers()];
    [self after:0.0 step:@selector(openComments)];
}

- (void)after:(NSTimeInterval)delay step:(SEL)step {
    NSUInteger run = self.run;
    __weak YTzoomHoldAllButton *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        YTzoomHoldAllButton *button = weakSelf;
        if (button == nil || button.run != run || !button.busy) return;
        if (CACurrentMediaTime() - button.runStart > 12.0) {
            [button failWith:YTzoomLocalized(@"Couldn't finish the Comments setting in time.")];
            return;
        }
        ((void (*)(id, SEL))objc_msgSend)(button, step);
    });
}

// Step 1: tap the Comments row, one method at a time.
- (void)openComments {
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    // Already showing (a menu left open, or the options sit on the page)?
    YTzoomHoldAllItem *option = [self optionIn:items];
    if (option != nil && YTzoomHoldAllReachable(option)) {
        [self note:@"option already on screen: \"%@\"", option.original];
        [self tapOption:option method:YTzoomHoldAllMethodControl];
        return;
    }
    YTzoomHoldAllItem *row = [self commentsRowIn:items];
    if (row == nil) {
        [self note:@"no Comments row. On screen: %@", [self visibleTexts:items]];
        [self failWith:YTzoomLocalized(@"Couldn't find the Comments setting on this page.")];
        return;
    }
    for (; self.method < YTzoomHoldAllMethodCount; self.method++) {
        NSString *detail = nil;
        if (YTzoomHoldAllTapItem(row, self.method, &detail)) {
            [self note:@"tapped Comments row \"%@\" (%@%@) via %@ (%@)", row.original,
                       NSStringFromClass(row.view.class), row.element != nil ? @", element" : @"",
                       YTzoomHoldAllMethodName(self.method), detail ?: @""];
            self.rowText = row.text;
            self.rowFrame = row.frame;
            self.stepStart = CACurrentMediaTime();
            [self after:0.15 step:@selector(waitForMenu)];
            return;
        }
    }
    [self note:@"no tap method worked on the Comments row (%@)", NSStringFromClass(row.view.class)];
    [self failWith:YTzoomLocalized(@"Couldn't open the Comments setting.")];
}

// Step 2: did that tap open anything? The option showing up, or the row no
// longer being reachable (a page or sheet covers it), means yes; the row still
// sitting there untouched after a while means that method did nothing.
- (void)waitForMenu {
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    YTzoomHoldAllItem *option = [self optionIn:items];
    if (option != nil && YTzoomHoldAllReachable(option)) {
        [self note:@"menu open (%@), found \"%@\"", YTzoomHoldAllTopControllers(), option.original];
        [self tapOption:option method:YTzoomHoldAllMethodControl];
        return;
    }
    YTzoomHoldAllItem *row = [self commentsRowIn:items];
    BOOL rowStillThere = row != nil && YTzoomHoldAllReachable(row) && [row.text isEqualToString:self.rowText] &&
        fabs(CGRectGetMidY(row.frame) - CGRectGetMidY(self.rowFrame)) < 4.0;
    if (!rowStillThere) {
        [self note:@"menu open (%@), looking for \"%@\"", YTzoomHoldAllTopControllers(), self.option];
        self.stepStart = CACurrentMediaTime();
        self.lastScroll = self.stepStart;
        [self after:0.15 step:@selector(findOption)];
        return;
    }
    if (CACurrentMediaTime() - self.stepStart < 1.2) {
        [self after:0.15 step:@selector(waitForMenu)];
        return;
    }
    [self note:@"%@ tap didn't open anything", YTzoomHoldAllMethodName(self.method)];
    self.method++;
    [self openComments];
}

// Step 3: find the option on the new screen, scrolling down to it if needed.
- (void)findOption {
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    YTzoomHoldAllItem *option = [self optionIn:items];
    if (option != nil && YTzoomHoldAllReachable(option)) {
        [self note:@"found \"%@\" (%@%@)", option.original, NSStringFromClass(option.view.class),
                   option.element != nil ? @", element" : @""];
        [self tapOption:option method:YTzoomHoldAllMethodControl];
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastScroll >= 0.45 && self.scrolls < 12) {
        // Off screen options don't exist yet in a list; scroll the frontmost
        // scrollable list down a step.
        NSArray<UIScrollView *> *scrollables = YTzoomHoldAllScrollables(YTzoomHoldAllKeyWindow(), [NSMutableArray array]);
        for (UIScrollView *scroll in scrollables) {
            CGFloat maxOffset = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.size.height;
            CGPoint offset = scroll.contentOffset;
            offset.y = MIN(maxOffset, offset.y + scroll.bounds.size.height * 0.6);
            [scroll setContentOffset:offset animated:NO];
            self.scrolls++;
            self.lastScroll = now;
            [self note:@"scrolled %@ to %.0f", NSStringFromClass(scroll.class), offset.y];
            break;
        }
        if (self.lastScroll != now && now - self.stepStart > 4.0) {
            [self note:@"\"%@\" not on screen. On screen: %@", self.option, [self visibleTexts:items]];
            [self failWith:[NSString stringWithFormat:YTzoomLocalized(@"Couldn't find \"%@\" in the menu. Hold the comments button to copy what YTzoom saw."), self.option]];
            return;
        }
    }
    if (now - self.stepStart > 7.0) {
        [self note:@"\"%@\" not found after scrolling. On screen: %@", self.option, [self visibleTexts:items]];
        [self failWith:[NSString stringWithFormat:YTzoomLocalized(@"Couldn't find \"%@\" in the menu. Hold the comments button to copy what YTzoom saw."), self.option]];
        return;
    }
    [self after:0.15 step:@selector(findOption)];
}

// Step 4: tap the option, then check it took: it shows as selected, or the
// menu closed. Otherwise the next method.
- (void)tapOption:(YTzoomHoldAllItem *)option method:(NSInteger)method {
    for (; method < YTzoomHoldAllMethodCount; method++) {
        NSString *detail = nil;
        if (YTzoomHoldAllTapItem(option, method, &detail)) {
            [self note:@"tapped \"%@\" via %@ (%@)", option.original, YTzoomHoldAllMethodName(method), detail ?: @""];
            self.method = method;
            self.stepStart = CACurrentMediaTime();
            [self after:0.4 step:@selector(checkOption)];
            return;
        }
    }
    [self note:@"no tap method worked on \"%@\"", option.original];
    [self failWith:[NSString stringWithFormat:YTzoomLocalized(@"Tap \"%@\" to finish."), self.option]];
}

- (void)checkOption {
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    YTzoomHoldAllItem *option = [self optionIn:items];
    BOOL gone = option == nil || !YTzoomHoldAllReachable(option);
    BOOL selected = option != nil && ((option.traits & UIAccessibilityTraitSelected) != 0 ||
        [option.text containsString:@"selected"] || [option.text containsString:@"checked"]);
    if (gone || selected) {
        self.sawSelected = selected && !gone;
        [self note:@"option took (%@)", gone ? @"menu closed" : @"selected"];
        [self finish];
        return;
    }
    if (self.method + 1 < YTzoomHoldAllMethodCount) {
        [self note:@"no sign the %@ tap took, trying the next way", YTzoomHoldAllMethodName(self.method)];
        [self tapOption:option method:self.method + 1];
        return;
    }
    // YouTube doesn't always mark the choice for accessibility; the tap went
    // through, so carry on.
    [self note:@"can't confirm the selection; assuming it took"];
    [self finish];
}

// Step 5: confirm if the menu asks for it, then back to the upload page.
- (void)finish {
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    YTzoomHoldAllItem *confirm = YTzoomHoldAllBest(items, ^NSInteger(YTzoomHoldAllItem *item) {
        for (NSString *word in @[@"save", @"done", @"apply", @"confirm", @"ok"]) {
            if ([item.text isEqualToString:word]) return 1;
        }
        return 0;
    });
    if (confirm != nil && YTzoomHoldAllReachable(confirm)) {
        for (NSInteger method = 0; method < YTzoomHoldAllMethodCount; method++) {
            if (YTzoomHoldAllTapItem(confirm, method, NULL)) {
                [self note:@"tapped \"%@\"", confirm.original];
                break;
            }
        }
    }
    [self after:0.5 step:@selector(returnToPage)];
}

- (void)returnToPage {
    BOOL visible = self.window != nil;
    if (visible) {
        CGPoint center = [self convertPoint:CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds))
                                     toView:self.window];
        UIView *hit = [self.window hitTest:center withEvent:nil];
        visible = hit == self || [hit isDescendantOfView:self];
    }
    if (!visible) {
        // The options are on a page pushed over the upload page: go back.
        UIViewController *page = YTzoomHoldAllOwner(self.anchor);
        UINavigationController *navigation = page.navigationController;
        while (page != nil && navigation != nil && ![navigation.viewControllers containsObject:page]) {
            page = page.parentViewController;
        }
        if (page != nil && navigation.topViewController != page) {
            [navigation popToViewController:page animated:YES];
            [self note:@"went back to %@", NSStringFromClass(page.class)];
        } else if (self.sawSelected) {
            // A sheet over the upload page, showing the choice as selected.
            UIViewController *host = YTzoomHoldAllOwner(self.anchor);
            UIViewController *sheet = host.presentedViewController;
            while (host != nil && sheet == nil) {
                host = host.parentViewController;
                sheet = host.presentedViewController;
            }
            if (sheet != nil && !sheet.isBeingDismissed) {
                [sheet dismissViewControllerAnimated:YES completion:nil];
                [self note:@"closed %@", NSStringFromClass(sheet.class)];
            }
        }
    }
    self.busy = NO;
    self.lastReport = [self.trace componentsJoinedByString:@"\n"];
    YTzoomShowNotice(self.targetOn ? YTzoomLocalized(@"Comments set to Hold all.")
                                   : YTzoomLocalized(@"Comments set to Basic."));
}

- (void)failWith:(NSString *)message {
    self.busy = NO;
    self.run++;
    // The menu wasn't driven, so the icon goes back to what YouTube still has.
    YTzoomSetPreference(YTzoomHoldAllActiveKey, !self.targetOn);
    [self refresh];
    self.lastReport = [self.trace componentsJoinedByString:@"\n"];
    YTzoomShowNotice(message);
}

- (void)copyDiagnostics:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    NSArray<YTzoomHoldAllItem *> *items = [self items];
    YTzoomHoldAllItem *row = [self commentsRowIn:items];
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:
        @"YTzoom comments toggle\nYouTube %@\nScreens: %@\nComments row: %@ (%@)\nHold text: %@\nBasic text: %@\n"
        @"On screen now: %@\n\nLast run:\n%@",
        NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
        YTzoomHoldAllTopControllers(), row.original ?: @"not found",
        row != nil ? NSStringFromClass(row.view.class) : @"-", YTzoomHoldAllOptionText(), YTzoomBasicOptionText(),
        [self visibleTexts:items], self.lastReport ?: @"(not run yet)"];
    YTzoomShowNotice(YTzoomLocalized(@"Copied what YTzoom saw. Paste it to whoever is helping you."));
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
