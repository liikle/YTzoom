#import "../../YTzoom.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>



static IMP OriginalCommentNodeDidLoad;
static IMP OriginalCommentViewSetNode;
static IMP OriginalCommentUIViewDidMove;
static IMP OriginalCommentNodeSetFrame;
static const void *YTzoomStoredCommentAssociation = &YTzoomStoredCommentAssociation;
static const void *YTzoomCommentTextAssociation = &YTzoomCommentTextAssociation;
static const void *YTzoomCommentNodeAssociation = &YTzoomCommentNodeAssociation;
static const void *YTzoomCommentGestureAssociation = &YTzoomCommentGestureAssociation;

static id YTzoomObjectMessage(id receiver, NSString *selectorName) {
    SEL selector = NSSelectorFromString(selectorName);
    return receiver != nil && [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static NSString *YTzoomCleanCommentText(NSString *text) {
    if (![text isKindOfClass:NSString.class]) {
        return nil;
    }
    NSString *cleaned = [text stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return cleaned.length == 0 ? nil : cleaned;
}

static BOOL YTzoomIsCommentToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment"] ||
           [lower containsString:@"id_ui_comment_cell"];
}

static BOOL YTzoomIsCommentTextToken(NSString *token) {
    NSString *lower = token.lowercaseString;
    return [lower containsString:@"comment_content"] ||
           [lower containsString:@"comment_text"] ||
           [lower containsString:@"comment_body"];
}

static NSString *YTzoomCommentTextInNode(id node, NSUInteger depth) {
    if (node == nil || depth > 16) {
        return nil;
    }
    NSString *stored = YTzoomCleanCommentText(
        objc_getAssociatedObject(node, YTzoomCommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    NSString *identifier = YTzoomObjectMessage(node, @"accessibilityIdentifier");
    NSString *description = [node description];
    id attributedText = YTzoomObjectMessage(node, @"attributedText");
    NSString *text = YTzoomCleanCommentText(
        YTzoomObjectMessage(attributedText, @"string")
    );
    if (text.length != 0 && YTzoomIsCommentTextToken(
        [NSString stringWithFormat:@"%@ %@", identifier ?: @"", description ?: @""])) {
        return text;
    }
    NSArray *children = YTzoomObjectMessage(node, @"subnodes");
    if (![children isKindOfClass:NSArray.class]) {
        children = YTzoomObjectMessage(node, @"children");
    }
    for (id child in children) {
        NSString *candidate = YTzoomCommentTextInNode(child, depth + 1);
        if (candidate.length != 0) {
            return candidate;
        }
    }
    return nil;
}

static NSString *YTzoomTextFromView(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        return YTzoomCleanCommentText(((UILabel *)view).text);
    }
    if ([view isKindOfClass:UITextView.class]) {
        return YTzoomCleanCommentText(((UITextView *)view).text);
    }
    NSString *label = YTzoomCleanCommentText(view.accessibilityLabel);
    return [view isKindOfClass:UIControl.class] ? nil : label;
}

static NSString *YTzoomCommentTextInView(UIView *view, BOOL exact,
                                         NSUInteger depth) {
    if (view == nil || depth > 16) {
        return nil;
    }
    NSString *stored = YTzoomCleanCommentText(
        objc_getAssociatedObject(view, YTzoomCommentTextAssociation)
    );
    if (stored.length != 0) {
        return stored;
    }
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"",
        NSStringFromClass(view.class) ?: @"",
        [view description] ?: @""];
    NSString *ownText = YTzoomTextFromView(view);
    if (ownText.length != 0 && (!exact || YTzoomIsCommentTextToken(token))) {
        return ownText;
    }
    id node = objc_getAssociatedObject(view, YTzoomCommentNodeAssociation);
    if (node == nil) {
        node = YTzoomObjectMessage(view, @"keepalive_node");
    }
    NSString *nodeText = YTzoomCommentTextInNode(node, 0);
    if (nodeText.length != 0) {
        return nodeText;
    }
    NSString *best = nil;
    for (UIView *subview in view.subviews) {
        NSString *candidate = YTzoomCommentTextInView(subview, exact, depth + 1);
        if (candidate.length > best.length) {
            best = candidate;
        }
    }
    NSArray *elements = view.accessibilityElements;
    for (id element in elements) {
        NSString *identifier = YTzoomObjectMessage(element, @"accessibilityIdentifier");
        NSString *label = YTzoomCleanCommentText(
            YTzoomObjectMessage(element, @"accessibilityLabel")
        );
        if (label.length != 0 &&
            (!exact || YTzoomIsCommentTextToken(identifier ?: @"")) &&
            label.length > best.length) {
            best = label;
        }
    }
    return best;
}

static UIViewController *YTzoomControllerForView(UIView *view) {
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

static NSString *YTzoomStoredCommentForView(UIView *view) {
    for (UIView *candidate = view; candidate != nil;
         candidate = candidate.superview) {
        NSString *direct = objc_getAssociatedObject(
            candidate, YTzoomStoredCommentAssociation);
        if ([direct isKindOfClass:NSString.class] && direct.length != 0) {
            return direct;
        }
        id node = objc_getAssociatedObject(candidate, YTzoomCommentNodeAssociation);
        if (node == nil) node = YTzoomObjectMessage(candidate, @"keepalive_node");
        for (NSUInteger depth = 0; node != nil && depth < 14; depth++) {
            NSString *stored = objc_getAssociatedObject(
                node, YTzoomStoredCommentAssociation);
            if ([stored isKindOfClass:NSString.class] && stored.length != 0) {
                return stored;
            }
            node = YTzoomObjectMessage(node, @"supernode");
        }
    }
    return nil;
}

static NSString *YTzoomCommentTextForView(UIView *view) {
    NSString *stored = YTzoomStoredCommentForView(view);
    if (stored.length != 0) return stored;
    UIView *candidate = view;
    for (NSUInteger depth = 0; candidate != nil && depth < 8; depth++) {
        NSString *text = YTzoomCommentTextInView(candidate, YES, 0);
        if (text.length != 0) {
            return text;
        }
        candidate = candidate.superview;
    }
    return nil;
}

@interface YTzoomCopyCommentTarget : NSObject
+ (instancetype)sharedTarget;
- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture;
@end

@implementation YTzoomCopyCommentTarget
+ (instancetype)sharedTarget {
    static YTzoomCopyCommentTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [YTzoomCopyCommentTarget new]; });
    return target;
}

- (void)handleCopyComment:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan || !YTzoomMasterEnabled()) {
        return;
    }
    UIView *view = gesture.view;
    NSString *text = YTzoomCommentTextForView(view);
    if (text.length == 0) {
        return;
    }
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:nil
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Copy Comment")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            UINotificationFeedbackGenerator *confirmation =
                [UINotificationFeedbackGenerator new];
            [confirmation notificationOccurred:UINotificationFeedbackTypeSuccess];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = view;
    menu.popoverPresentationController.sourceRect = view.bounds;
    UIViewController *controller = YTzoomControllerForView(view);
    if (controller.presentedViewController == nil) {
        [controller presentViewController:menu animated:YES completion:nil];
    }
}
@end

static void YTzoomAttachCommentGesture(UIView *view, id node) {
    if (view == nil) {
        return;
    }
    if (node != nil) {
        objc_setAssociatedObject(view, YTzoomCommentNodeAssociation,
                                 node, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (objc_getAssociatedObject(view, YTzoomCommentGestureAssociation) != nil) {
        return;
    }
    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:YTzoomCopyCommentTarget.sharedTarget
                action:@selector(handleCopyComment:)];
    gesture.minimumPressDuration = 0.25;
    gesture.cancelsTouchesInView = NO;
    [view addGestureRecognizer:gesture];
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view, YTzoomCommentGestureAssociation,
                             gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL YTzoomIsCommentContainer(id node) {
    NSString *description = [node description];
    return [description containsString:@"id.ui.comment_cell"] ||
           [description containsString:@"id.ui.comment_thread"] ||
           [description containsString:@"comment_reply"];
}

static NSString *YTzoomNodeIdentifier(id node) {
    NSString *identifier = YTzoomObjectMessage(node, @"accessibilityIdentifier");
    if ([identifier isKindOfClass:NSString.class] && identifier.length != 0) {
        return identifier;
    }
    @try {
        id value = [node valueForKey:@"_accessibilityIdentifier"];
        return [value isKindOfClass:NSString.class] ? value : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void YTzoomStoreCommentOnContainers(id node, NSString *text) {
    id supernodes = YTzoomObjectMessage(node, @"supernodes");
    NSArray *all = nil;
    if ([supernodes respondsToSelector:@selector(allObjects)]) {
        all = [supernodes allObjects];
    } else if ([supernodes isKindOfClass:NSArray.class]) {
        all = supernodes;
    }
    for (id container in all) {
        if (!YTzoomIsCommentContainer(container)) continue;
        objc_setAssociatedObject(container, YTzoomStoredCommentAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        UIView *rendered = YTzoomObjectMessage(container, @"view");
        if ([rendered isKindOfClass:UIView.class]) {
            objc_setAssociatedObject(rendered, YTzoomStoredCommentAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        return;
    }
}

static void YTzoomCommentNodeSetFrame(id receiver, SEL selector, CGRect frame) {
    if (OriginalCommentNodeSetFrame != NULL) {
        ((void (*)(id, SEL, CGRect))OriginalCommentNodeSetFrame)(receiver, selector,
                                                                 frame);
    }
    NSString *identifier = YTzoomNodeIdentifier(receiver);
    if (identifier.length == 0) return;
    if (![identifier isEqualToString:@"id.comment.content.label"]) return;
    id attributed = YTzoomObjectMessage(receiver, @"attributedText");
    NSString *text = YTzoomCleanCommentText(
        YTzoomObjectMessage(attributed, @"string"));
    if (text.length == 0) return;
    YTzoomStoreCommentOnContainers(receiver, text);
}

static void YTzoomCommentNodeDidLoad(id receiver, SEL selector) {
    if (OriginalCommentNodeDidLoad != NULL) {
        ((void (*)(id, SEL))OriginalCommentNodeDidLoad)(receiver, selector);
    }
    NSString *identifier = YTzoomObjectMessage(receiver, @"accessibilityIdentifier");
    NSString *token = [NSString stringWithFormat:@"%@ %@",
        identifier ?: @"", [receiver description] ?: @""];
    if (!YTzoomIsCommentTextToken(token)) {
        return;
    }
    id attributedText = YTzoomObjectMessage(receiver, @"attributedText");
    NSString *text = YTzoomCleanCommentText(
        YTzoomObjectMessage(attributedText, @"string")
    );
    if (text.length == 0) {
        return;
    }
    objc_setAssociatedObject(receiver, YTzoomCommentTextAssociation,
                             text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIView *renderedView = YTzoomObjectMessage(receiver, @"view");
    if ([renderedView isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(renderedView, YTzoomCommentTextAssociation,
                                 text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        YTzoomAttachCommentGesture(renderedView, receiver);
    }
    id parent = YTzoomObjectMessage(receiver, @"yogaParent");
    for (NSUInteger depth = 0; parent != nil && depth < 16; depth++) {
        if (YTzoomIsCommentToken([parent description])) {
            objc_setAssociatedObject(parent, YTzoomCommentTextAssociation,
                                     text, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
        parent = YTzoomObjectMessage(parent, @"yogaParent");
    }
}

static void YTzoomCommentViewSetNode(UIView *receiver, SEL selector, id node) {
    if (OriginalCommentViewSetNode != NULL) {
        ((void (*)(id, SEL, id))OriginalCommentViewSetNode)(receiver, selector, node);
    }
    YTzoomProfileConsiderDisplayView(receiver, node);
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class) ?: @"",
        [receiver description] ?: @"", [node description] ?: @""];
    NSString *text = YTzoomCommentTextInNode(node, 0);
    BOOL tokenMatch = YTzoomIsCommentToken(token);
    if (tokenMatch || text.length != 0) {
        YTzoomAttachCommentGesture(receiver, node);
    }
}

static void YTzoomCommentUIViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalCommentUIViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalCommentUIViewDidMove)(receiver, selector);
    }
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
        NSStringFromClass(receiver.class) ?: @"",
        receiver.accessibilityIdentifier ?: @"",
        [receiver description] ?: @""];
    if (YTzoomIsCommentToken(token)) {
        YTzoomAttachCommentGesture(receiver,
            YTzoomObjectMessage(receiver, @"keepalive_node"));
    }
}

void YTzoomInstallCopyCommentHooks(void) {
    YTzoomInstallInstanceHook(@"ASDisplayNode", @"didLoad",
        (IMP)YTzoomCommentNodeDidLoad, &OriginalCommentNodeDidLoad);
    YTzoomInstallInstanceHook(@"_ASDisplayView", @"setKeepalive_node:",
        (IMP)YTzoomCommentViewSetNode, &OriginalCommentViewSetNode);
    YTzoomInstallInstanceHook(@"UIView", @"didMoveToWindow",
        (IMP)YTzoomCommentUIViewDidMove, &OriginalCommentUIViewDidMove);
    YTzoomInstallInstanceHook(@"ASDisplayNode", @"setFrame:",
        (IMP)YTzoomCommentNodeSetFrame, &OriginalCommentNodeSetFrame);
}
