#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static BOOL YTzoomShortsSuggestionPillHidden(void) {
    id stored = [NSUserDefaults.standardUserDefaults objectForKey:@"YTzoom.Preference.Shorts.SuggestionPillHidden"];
    if (stored == nil) {
        BOOL legacy = [NSUserDefaults.standardUserDefaults boolForKey:@"YTzoom.Preference.Overlay.CommentPreviewsHidden"];
        [NSUserDefaults.standardUserDefaults setBool:legacy forKey:@"YTzoom.Preference.Shorts.SuggestionPillHidden"];
    }
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.SuggestionPillHidden");
}

static IMP OriginalDisplayViewDidMove;
static IMP OriginalActionCellPrepareForReuse;
static IMP OriginalFixedBarLayout;
static IMP OriginalDisplayViewSetIdentifier;
static IMP OriginalAddSections;
static IMP OriginalSectionControllers;
static IMP OriginalEnableSubheaderBar;
static IMP OriginalChipBarUpdate;
static IMP OriginalChipCloudSetEntry;
static IMP OriginalSubsChipFilter;
static IMP OriginalChipCloudLayout;
static IMP OriginalFeedHeaderScrollMode;
static IMP OriginalSubsSetChipFilterView;
static IMP OriginalMaximumSubheaderHeight;
static IMP OriginalMaximumSubheaderHeightGetter;
static IMP OriginalSubheaderDefaultHeight;
static IMP OriginalSetHeaderHeights;
static IMP OriginalShouldHideSubheader;
static IMP OriginalPaidContentLayout;
static IMP OriginalPaidContentDidAppear;
static IMP OriginalPaidContentPlaybackStarted;
static IMP OriginalSetPaidContentPlayerData;
static IMP OriginalSetPaidContentRenderer;
static IMP OriginalHasPaidContentOverlay;
static IMP OriginalPaidContentOverlay;
static IMP OriginalOverlayPaidContentPlayerData;
static IMP OriginalInlinePaidContentPlayerData;
static IMP OriginalDidInsertPlayerOverlay;
static IMP OriginalScrollableActionButtonsArray;
static IMP OriginalScrollableActionBarButtonsArray;
static IMP OriginalScrollableButtonsArray;
static IMP OriginalScrollableActionsArray;
static IMP OriginalActionButtonsArray;
static IMP OriginalActionBarButtonsArray;
static IMP OriginalButtonsArray;
static IMP OriginalActionsArray;
static IMP OriginalActionViewDidMove;
static IMP OriginalActionsViewDidMove;
static IMP OriginalActionCellDidMove;
static IMP OriginalCreateActionViews;
static IMP OriginalActionCellControllerInit;
static IMP OriginalActionCellSize;
static IMP OriginalActionCellSizeWithInsets;
static IMP OriginalASCollectionViewLayout;
static const void *YTzoomContentHiddenAssociation = &YTzoomContentHiddenAssociation;
static NSString *YTzoomNormalizedDescription(id object);
static const void *YTzoomActionCellPreferenceAssociation =
    &YTzoomActionCellPreferenceAssociation;
static const void *YTzoomActionLayoutRefreshAssociation =
    &YTzoomActionLayoutRefreshAssociation;
static const void *YTzoomActionGroupCompactAssociation =
    &YTzoomActionGroupCompactAssociation;
static BOOL YTzoomContentContains(NSString *token,
                                  NSArray<NSString *> *needles);
static id YTzoomContentValue(id object, NSString *key);
static NSArray<NSString *> *YTzoomProductsMarkers(void);
static BOOL YTzoomHideTopics(void);
static BOOL YTzoomEnsureStructuralActionHook(void);
static BOOL YTzoomEnsureActionCellControllerHooks(void);
static BOOL YTzoomEnsureActionCollectionLayoutHook(void);

static BOOL YTzoomViewIsInsideWatchActionBar(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        NSString *identifier = [candidate.accessibilityIdentifier lowercaseString] ?: @"";
        NSString *className = NSStringFromClass(candidate.class) ?: @"";
        if ([identifier containsString:@"scrollable_action_bar"] ||
            [className containsString:@"SlimVideoScrollableDetailsActionsView"] ||
            [className containsString:@"SlimVideoScrollableActionBarCell"]) {
            return YES;
        }
        if ([candidate isKindOfClass:UICollectionView.class] &&
            CGRectGetHeight(candidate.bounds) <= 64.0 &&
            CGRectGetHeight(candidate.bounds) > 0.0) {
            return YES;
        }
    }
    return NO;
}

static NSString *YTzoomActionPreference(id item) {
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass([item class]), YTzoomNormalizedDescription(item)] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTzoom.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTzoom.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTzoom.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTzoom.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTzoom.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTzoom.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTzoom.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTzoom.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTzoom.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTzoom.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTzoom.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTzoom.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static BOOL YTzoomAnyActionPreferenceEnabled(void) {
    for (NSString *key in @[
        @"YTzoom.Preference.ActionBar.LikeHidden",
        @"YTzoom.Preference.ActionBar.DislikeHidden",
        @"YTzoom.Preference.ActionBar.ShareHidden",
        @"YTzoom.Preference.ActionBar.DownloadHidden",
        @"YTzoom.Preference.ActionBar.SaveHidden",
        @"YTzoom.Preference.ActionBar.ClipHidden",
        @"YTzoom.Preference.ActionBar.RemixHidden",
        @"YTzoom.Preference.ActionBar.ThanksHidden",
        @"YTzoom.Preference.ActionBar.HypeHidden",
        @"YTzoom.Preference.ActionBar.ReportHidden",
        @"YTzoom.Preference.ActionBar.AskHidden",
        @"YTzoom.Preference.ActionBar.OverflowHidden"
    ]) {
        if (YTzoomFeatureEnabled(key)) return YES;
    }
    return NO;
}

static NSString *YTzoomActionPreferenceForView(UIView *view) {
    if (view == nil || !YTzoomViewIsInsideWatchActionBar(view)) return nil;
    for (NSString *name in @[@"entry", @"renderer", @"buttonRenderer",
                             @"model", @"elementRenderer"]) {
        SEL selector = NSSelectorFromString(name);
        if (![view respondsToSelector:selector]) continue;
        id related = ((id (*)(id, SEL))objc_msgSend)(view, selector);
        if (related == nil || [related isKindOfClass:UIView.class]) continue;
        NSString *preference = YTzoomActionPreference(related);
        if (preference.length != 0) {
            return preference;
        }
    }
    NSString *token = [[[NSString stringWithFormat:@"%@ %@",
        NSStringFromClass(view.class), view.accessibilityIdentifier ?: @""]
        lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *wide = [[NSString stringWithFormat:@"%@ %@", token,
        view.accessibilityLabel ?: @""] lowercaseString];
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTzoom.Preference.ActionBar.DislikeHidden", @"id_video_dislike_button", @"dislike"],
        @[@"YTzoom.Preference.ActionBar.ShareHidden", @"id_video_share_button", @"share"],
        @[@"YTzoom.Preference.ActionBar.DownloadHidden", @"offline", @"download"],
        @[@"YTzoom.Preference.ActionBar.SaveHidden", @"save", @"add_to"],
        @[@"YTzoom.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTzoom.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTzoom.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTzoom.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTzoom.Preference.ActionBar.ReportHidden", @"id_player_watch_flag_button", @"report"],
        @[@"YTzoom.Preference.ActionBar.AskHidden", @"ask", @"gemini"],
        @[@"YTzoom.Preference.ActionBar.LikeHidden", @"id_video_like_button", @"like"]
    ];
    BOOL dislikeToken = [token containsString:@"dislike"] ||
        [wide containsString:@"dislike"];
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTzoom.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([token containsString:rule[index]]) {
                return rule.firstObject;
            }
        }
    }
    for (NSArray<NSString *> *rule in rules) {
        if (dislikeToken &&
            [rule.firstObject isEqualToString:
                @"YTzoom.Preference.ActionBar.LikeHidden"]) {
            continue;
        }
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([wide containsString:rule[index]]) {
                NSMutableArray<NSString *> *shape = [NSMutableArray array];
                NSMutableArray<UIView *> *pending =
                    [NSMutableArray arrayWithObject:view];
                NSUInteger seen = 0;
                while (pending.count != 0 && seen < 40) {
                    UIView *node = pending.firstObject;
                    [pending removeObjectAtIndex:0];
                    seen++;
                    NSMutableString *entry = [NSMutableString stringWithString:
                        NSStringFromClass([node class])];
                    if (node.accessibilityIdentifier.length != 0) {
                        [entry appendFormat:@"#%@", node.accessibilityIdentifier];
                    }
                    for (NSString *probe in @[@"iconType", @"icon", @"image",
                                              @"renderer", @"entry", @"model"]) {
                        SEL selector = NSSelectorFromString(probe);
                        if (![node respondsToSelector:selector]) continue;
                        [entry appendFormat:@" %@?", probe];
                    }
                    [shape addObject:entry];
                    [pending addObjectsFromArray:node.subviews];
                }
                return rule.firstObject;
            }
        }
    }
    return nil;
}

static void YTzoomCreateActionViews(id receiver, SEL selector,
                                    NSArray *renderers) {
    NSArray *filtered = renderers;
    if ([renderers isKindOfClass:NSArray.class]) {
        static NSUInteger rendererLogged = 0;
        if (rendererLogged < 3) {
            rendererLogged++;
            NSMutableArray<NSString *> *shape = [NSMutableArray array];
            for (id renderer in renderers) {
                NSString *match = YTzoomActionPreference(renderer);
                NSMutableString *entry = [NSMutableString stringWithString:
                    NSStringFromClass([renderer class])];
                for (NSString *probe in @[@"likeButton", @"dislikeButton",
                                          @"segmentedLikeDislikeButton",
                                          @"buttonRenderer", @"targetId",
                                          @"trackingParams"]) {
                    SEL selector = NSSelectorFromString(probe);
                    if ([renderer respondsToSelector:selector]) {
                        [entry appendFormat:@" %@?", probe];
                    }
                }
                if (match.length != 0) {
                    [entry appendFormat:@" ->%@",
                        [match componentsSeparatedByString:@"."].lastObject];
                }
                [shape addObject:entry];
            }
        }
    }
    if ([renderers isKindOfClass:NSArray.class] &&
        renderers.count != 0 && YTzoomAnyActionPreferenceEnabled()) {
        NSMutableArray *kept = [NSMutableArray arrayWithCapacity:renderers.count];
        for (id renderer in renderers) {
            NSString *preference = YTzoomActionPreference(renderer);
            if (preference.length != 0 && YTzoomFeatureEnabled(preference)) {
                continue;
            }
            [kept addObject:renderer];
        }
        if (kept.count != renderers.count) filtered = kept;
    }
    if (OriginalCreateActionViews != NULL) {
        ((void (*)(id, SEL, id))OriginalCreateActionViews)(
            receiver, selector, filtered);
    }
}

static void YTzoomEnsureActionCellReuseHook(void);

static BOOL YTzoomEnsureStructuralActionHook(void) {
    YTzoomEnsureActionCellReuseHook();
    if (OriginalCreateActionViews != NULL) return YES;

    BOOL installed = YTzoomInstallInstanceHook(
        @"YTSlimVideoScrollableDetailsActionsView",
        @"createActionViewsFromSupportedRenderers:",
        (IMP)YTzoomCreateActionViews,
        &OriginalCreateActionViews
    );
    if (installed && OriginalCreateActionViews != NULL) return YES;
    return NO;
}

static NSString *YTzoomActionPreferenceForController(id controller) {
    NSString *cached = objc_getAssociatedObject(
        controller, YTzoomActionCellPreferenceAssociation);
    if (cached.length != 0) return cached;

    for (Class cls = [controller class]; cls != Nil; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            const char *name = ivar_getName(ivars[index]);
            if (type == NULL || type[0] != '@' || name == NULL) continue;
            NSString *ivarName = [[NSString stringWithUTF8String:name] lowercaseString];
            if (![ivarName containsString:@"entry"] &&
                ![ivarName containsString:@"render"] &&
                ![ivarName containsString:@"button"] &&
                ![ivarName containsString:@"cell"]) {
                continue;
            }
            id value = object_getIvar(controller, ivars[index]);
            if (value == nil) continue;
            NSString *preference = [value isKindOfClass:UIView.class]
                ? YTzoomActionPreferenceForView(value)
                : YTzoomActionPreference(value);
            if (preference.length == 0) continue;
            free(ivars);
            objc_setAssociatedObject(controller,
                                     YTzoomActionCellPreferenceAssociation,
                                     preference,
                                     OBJC_ASSOCIATION_COPY_NONATOMIC);
            return preference;
        }
        free(ivars);
    }
    return nil;
}

static id YTzoomActionCellControllerInit(id receiver, SEL selector,
                                          id entry, id parentResponder) {
    id result = OriginalActionCellControllerInit == NULL ? receiver :
        ((id (*)(id, SEL, id, id))OriginalActionCellControllerInit)(
            receiver, selector, entry, parentResponder);
    NSString *preference = YTzoomActionPreference(entry);
    if (result != nil && preference.length != 0) {
        objc_setAssociatedObject(result,
                                 YTzoomActionCellPreferenceAssociation,
                                 preference,
                                 OBJC_ASSOCIATION_COPY_NONATOMIC);
    }
    return result;
}

static NSArray<NSString *> *YTzoomActionButtonIdentifiers(UIView *view);
static BOOL YTzoomIsActionButtonIdentifier(NSString *identifier);

static NSString *YTzoomPreferenceForButtonIdentifier(NSString *identifier) {
    NSString *token = [[identifier lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (token.length == 0) return nil;
    if ([token containsString:@"dislike"]) {
        return @"YTzoom.Preference.ActionBar.DislikeHidden";
    }
    if ([token containsString:@"like"]) {
        return @"YTzoom.Preference.ActionBar.LikeHidden";
    }
    if ([token containsString:@"share"]) {
        return @"YTzoom.Preference.ActionBar.ShareHidden";
    }
    if ([token containsString:@"offline"] || [token containsString:@"download"]) {
        return @"YTzoom.Preference.ActionBar.DownloadHidden";
    }
    if ([token containsString:@"add_to"] || [token containsString:@"save"]) {
        return @"YTzoom.Preference.ActionBar.SaveHidden";
    }
    if ([token containsString:@"clip"]) {
        return @"YTzoom.Preference.ActionBar.ClipHidden";
    }
    if ([token containsString:@"remix"]) {
        return @"YTzoom.Preference.ActionBar.RemixHidden";
    }
    if ([token containsString:@"thanks"]) {
        return @"YTzoom.Preference.ActionBar.ThanksHidden";
    }
    if ([token containsString:@"hype"]) {
        return @"YTzoom.Preference.ActionBar.HypeHidden";
    }
    return nil;
}

static NSArray<NSString *> *YTzoomControllerButtonIdentifiers(id controller) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    for (Class cls = [controller class]; cls != Nil;
         cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);
        for (unsigned int index = 0; index < count; index++) {
            const char *type = ivar_getTypeEncoding(ivars[index]);
            if (type == NULL || type[0] != '@') continue;
            id value = object_getIvar(controller, ivars[index]);
            if (![value isKindOfClass:UIView.class]) continue;
            [found addObjectsFromArray:
                YTzoomActionButtonIdentifiers((UIView *)value)];
        }
        free(ivars);
    }
    return found.array;
}

static BOOL YTzoomControllerCellCollapsed(id receiver) {
    static NSUInteger logged = 0;
    NSString *preference = YTzoomActionPreferenceForController(receiver);
    NSArray<NSString *> *identifiers = YTzoomControllerButtonIdentifiers(receiver);
    BOOL collapsed = preference.length != 0 && YTzoomFeatureEnabled(preference);
    if (identifiers.count > 1) {
        collapsed = YES;
        for (NSString *identifier in identifiers) {
            NSString *key = YTzoomPreferenceForButtonIdentifier(identifier);
            if (key.length == 0 || !YTzoomFeatureEnabled(key)) {
                collapsed = NO;
                break;
            }
        }
    }
    if (logged < 60) {
        logged++;
    }
    return collapsed;
}

static CGSize YTzoomActionCellSize(id receiver, SEL selector, CGSize size) {
    CGSize result = OriginalActionCellSize == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize))OriginalActionCellSize)(
            receiver, selector, size);
    if (YTzoomControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static CGSize YTzoomActionCellSizeWithInsets(id receiver, SEL selector,
                                               CGSize size,
                                               UIEdgeInsets insets) {
    CGSize result = OriginalActionCellSizeWithInsets == NULL ? size :
        ((CGSize (*)(id, SEL, CGSize, UIEdgeInsets))
            OriginalActionCellSizeWithInsets)(receiver, selector, size, insets);
    if (YTzoomControllerCellCollapsed(receiver)) {
        result.width = 0.0;
    }
    return result;
}

static BOOL YTzoomEnsureActionCellControllerHooks(void) {
    if (OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL) return YES;

    YTzoomInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"initWithEntry:parentResponder:",
        (IMP)YTzoomActionCellControllerInit,
        &OriginalActionCellControllerInit);
    YTzoomInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:",
        (IMP)YTzoomActionCellSize,
        &OriginalActionCellSize);
    YTzoomInstallInstanceHook(
        @"YTSlimVideoScrollableActionBarCellController",
        @"cellSizeWithSize:safeAreaInsets:",
        (IMP)YTzoomActionCellSizeWithInsets,
        &OriginalActionCellSizeWithInsets);
    return OriginalActionCellSize != NULL ||
        OriginalActionCellSizeWithInsets != NULL;
}

static NSSet<NSString *> *YTzoomActionPreferencesInCell(UIView *cell) {
    NSMutableSet<NSString *> *preferences = [NSMutableSet set];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 120) {
        UIView *candidate = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = candidate.accessibilityIdentifier ?: @"";
        NSString *label = candidate.accessibilityLabel ?: @"";
        if (identifier.length != 0 || label.length != 0) {
            NSString *preference = YTzoomActionPreference(
                [NSString stringWithFormat:@"%@ %@", identifier, label]);
            if (preference.length != 0) [preferences addObject:preference];
        }
        [pending addObjectsFromArray:candidate.subviews];
    }
    return preferences;
}

static void YTzoomHiddenActionWidths(UIView *cell,
                                     CGFloat *outTotal,
                                     CGFloat *outLeading,
                                     NSUInteger *outVisible,
                                     CGFloat *outVisibleRight,
                                     CGFloat *outInset) {
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:cell];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (YTzoomIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [buttons addObject:node];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    buttons = [[buttons sortedArrayUsingComparator:
        ^NSComparisonResult(UIView *left, UIView *right) {
            CGFloat leftX = [left convertPoint:CGPointZero toView:cell].x;
            CGFloat rightX = [right convertPoint:CGPointZero toView:cell].x;
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }] mutableCopy];

    CGFloat separators = 0.0;
    UIView *group = buttons.firstObject.superview;
    for (UIView *child in group.subviews) {
        CGFloat width = CGRectGetWidth(child.bounds);
        if (width > 0.0 && width <= 3.0 &&
            CGRectGetHeight(child.bounds) >= 6.0) {
            separators += width;
        }
    }

    CGFloat total = 0.0;
    CGFloat leading = 0.0;
    NSUInteger visible = 0;
    CGFloat visibleRight = 0.0;
    BOOL seenVisible = NO;
    for (UIView *button in buttons) {
        NSString *key = YTzoomPreferenceForButtonIdentifier(
            button.accessibilityIdentifier);
        BOOL hidden = key.length != 0 && YTzoomFeatureEnabled(key);
        CGFloat width = CGRectGetWidth(button.bounds);
        if (!hidden) {
            visible++;
            seenVisible = YES;
            CGRect inCell = [button convertRect:button.bounds toView:cell];
            visibleRight = MAX(visibleRight, CGRectGetMaxX(inCell));
            continue;
        }
        total += width;
        if (!seenVisible) leading += width;
    }
    CGFloat inset = 0.0;
    if (group != nil) {
        inset = MAX(0.0, CGRectGetMinX([group convertRect:group.bounds
                                                  toView:cell]));
    }
    if (outVisibleRight != NULL) *outVisibleRight = visibleRight;
    if (outInset != NULL) *outInset = inset;
    if (total > 0.0) total += separators;
    if (leading > 0.0) leading += separators;
    if (outTotal != NULL) *outTotal = total;
    if (outLeading != NULL) *outLeading = leading;
    if (outVisible != NULL) *outVisible = visible;
}

static void YTzoomASCollectionViewLayout(UICollectionView *receiver,
                                          SEL selector) {
    if (OriginalASCollectionViewLayout != NULL) {
        ((void (*)(id, SEL))OriginalASCollectionViewLayout)(receiver, selector);
    }
    if (!YTzoomAnyActionPreferenceEnabled() || receiver.window == nil) return;
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;

    NSArray<UICollectionViewCell *> *visible = [receiver.visibleCells
        sortedArrayUsingComparator:^NSComparisonResult(UICollectionViewCell *left,
                                                       UICollectionViewCell *right) {
            NSIndexPath *leftPath = [receiver indexPathForCell:left];
            NSIndexPath *rightPath = [receiver indexPathForCell:right];
            if (leftPath != nil && rightPath != nil) {
                return [leftPath compare:rightPath];
            }
            CGFloat leftX = CGRectGetMinX(left.frame);
            CGFloat rightX = CGRectGetMinX(right.frame);
            if (leftX < rightX) return NSOrderedAscending;
            if (leftX > rightX) return NSOrderedDescending;
            return NSOrderedSame;
        }];
    if (visible.count == 0) return;

    static NSUInteger layoutLogged = 0;
    CGFloat removedWidth = 0.0;
    NSUInteger matchedCells = 0;
    for (UICollectionViewCell *cell in visible) {
        CGRect frame = cell.frame;
        NSArray<NSString *> *cellButtons = YTzoomActionButtonIdentifiers(cell);
        if (layoutLogged < 80 && cellButtons.count != 0) {
            layoutLogged++;
        }
        frame.origin.x -= removedWidth;
        NSSet<NSString *> *preferences = YTzoomActionPreferencesInCell(cell);
        if (preferences.count != 0) {
            matchedCells++;
            NSUInteger hiddenCount = 0;
            for (NSString *preference in preferences) {
                if (YTzoomFeatureEnabled(preference)) hiddenCount++;
            }
            if (hiddenCount != 0) {
                CGFloat oldWidth = CGRectGetWidth(frame);
                CGFloat measuredTotal = 0.0;
                CGFloat measuredLeading = 0.0;
                NSUInteger visibleButtons = 0;
                YTzoomHiddenActionWidths(cell, &measuredTotal,
                                         &measuredLeading, &visibleButtons,
                                         NULL, NULL);
                CGFloat newWidth = oldWidth;
                BOOL collapse = visibleButtons == 0;
                BOOL trailingOnly = measuredLeading <= 0.5 &&
                    measuredTotal > 0.5;
                if (collapse) {
                    newWidth = 0.0;
                } else if (trailingOnly) {
                    newWidth = floor(MAX(0.0, oldWidth - measuredTotal));
                }
                if (layoutLogged < 80) {
                    layoutLogged++;
                }
                removedWidth += oldWidth - newWidth;
                frame.size.width = newWidth;
                cell.hidden = collapse;
                cell.userInteractionEnabled = !collapse;
                cell.clipsToBounds = trailingOnly && !collapse;
                cell.contentView.clipsToBounds = cell.clipsToBounds;
                cell.contentView.transform = CGAffineTransformIdentity;
            } else {
                cell.hidden = NO;
                cell.userInteractionEnabled = YES;
                cell.clipsToBounds = NO;
                cell.contentView.clipsToBounds = NO;
                cell.contentView.transform = CGAffineTransformIdentity;
            }
        }
        cell.frame = frame;
    }
    if (matchedCells == 0 || removedWidth <= 0.0) return;

    CGSize contentSize = receiver.contentSize;
    contentSize.width = MAX(CGRectGetWidth(receiver.bounds),
                            contentSize.width - removedWidth);
    receiver.contentSize = contentSize;
}

static BOOL YTzoomEnsureActionCollectionLayoutHook(void) {
    if (OriginalASCollectionViewLayout != NULL) return YES;
    BOOL installed = YTzoomInstallInstanceHook(
        @"ASCollectionView", @"layoutSubviews",
        (IMP)YTzoomASCollectionViewLayout,
        &OriginalASCollectionViewLayout);
    if (installed && OriginalASCollectionViewLayout != NULL) return YES;
    return NO;
}

static void YTzoomScheduleStructuralActionHook(void) {
    NSArray<NSNumber *> *delays =
        @[@0.0, @0.5, @1.5, @3.0, @6.0, @9.0, @12.0, @18.0];
    for (NSNumber *delay in delays) {
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
            dispatch_get_main_queue(),
            ^{
                YTzoomEnsureStructuralActionHook();
                YTzoomEnsureActionCellControllerHooks();
                YTzoomEnsureActionCollectionLayoutHook();
            }
        );
    }
}

static UICollectionView *YTzoomActionCollectionView(UIView *view) {
    for (UIView *candidate = view; candidate != nil; candidate = candidate.superview) {
        if ([candidate isKindOfClass:UICollectionView.class]) {
            return (UICollectionView *)candidate;
        }
    }
    return nil;
}

static void YTzoomRefreshActionCollection(UIView *view) {
    if (!YTzoomEnsureActionCellControllerHooks()) return;
    UICollectionView *collectionView = YTzoomActionCollectionView(view);
    if (collectionView == nil || objc_getAssociatedObject(
            collectionView, YTzoomActionLayoutRefreshAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(collectionView,
                             YTzoomActionLayoutRefreshAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        [collectionView.collectionViewLayout invalidateLayout];
        [collectionView reloadData];
        [collectionView layoutIfNeeded];
    });
}

static BOOL YTzoomIsActionButtonIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *lower = identifier.lowercaseString;
    if (![lower hasPrefix:@"id."]) return NO;
    return [lower containsString:@"button"];
}

static NSArray<NSString *> *YTzoomActionButtonIdentifiers(UIView *view) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSet];
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:view];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 160) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        if (YTzoomIsActionButtonIdentifier(node.accessibilityIdentifier)) {
            [found addObject:node.accessibilityIdentifier];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    return found.array;
}

static void YTzoomRestoreHiddenView(UIView *view) {
    NSNumber *baseline = objc_getAssociatedObject(
        view, YTzoomContentHiddenAssociation);
    if (baseline == nil) return;
    view.hidden = NO;
    view.userInteractionEnabled = YES;
    objc_setAssociatedObject(view,
                             YTzoomContentHiddenAssociation,
                             nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSUInteger YTzoomSizableChildCount(UIView *view) {
    NSUInteger count = 0;
    for (UIView *child in view.subviews) {
        if (child.hidden) continue;
        if (CGRectGetWidth(child.bounds) >= 40.0 &&
            CGRectGetHeight(child.bounds) >= 28.0) {
            count++;
        }
    }
    return count;
}

static void YTzoomActionCellPrepareForReuse(UIView *receiver, SEL selector) {
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, YTzoomContentHiddenAssociation);
    if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 YTzoomContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (OriginalActionCellPrepareForReuse != NULL) {
        ((void (*)(id, SEL))OriginalActionCellPrepareForReuse)(receiver, selector);
    }
}

static NSString *YTzoomBarSlotPreference(UIView *slot) {
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:slot];
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    NSUInteger visited = 0;
    while (pending.count != 0 && visited < 40) {
        UIView *node = pending.firstObject;
        [pending removeObjectAtIndex:0];
        visited++;
        NSString *identifier = node.accessibilityIdentifier;
        if (YTzoomIsActionButtonIdentifier(identifier)) {
            NSString *preference =
                YTzoomPreferenceForButtonIdentifier(identifier);
            if (preference.length != 0) return preference;
        }
        if (node.accessibilityLabel.length != 0) {
            [labels addObject:node.accessibilityLabel.lowercaseString];
        }
        [pending addObjectsFromArray:node.subviews];
    }
    NSString *joined = [labels componentsJoinedByString:@" "];
    if (joined.length == 0) return nil;
    NSArray<NSArray<NSString *> *> *rules = @[
        @[@"YTzoom.Preference.ActionBar.DislikeHidden", @"dislike"],
        @[@"YTzoom.Preference.ActionBar.ShareHidden", @"share"],
        @[@"YTzoom.Preference.ActionBar.DownloadHidden", @"download"],
        @[@"YTzoom.Preference.ActionBar.SaveHidden", @"save"],
        @[@"YTzoom.Preference.ActionBar.ClipHidden", @"clip"],
        @[@"YTzoom.Preference.ActionBar.RemixHidden", @"remix"],
        @[@"YTzoom.Preference.ActionBar.ThanksHidden", @"thanks"],
        @[@"YTzoom.Preference.ActionBar.HypeHidden", @"hype"],
        @[@"YTzoom.Preference.ActionBar.ReportHidden", @"report"],
        @[@"YTzoom.Preference.ActionBar.AskHidden", @"ask"],
        @[@"YTzoom.Preference.ActionBar.OverflowHidden", @"overflow"],
        @[@"YTzoom.Preference.ActionBar.LikeHidden", @"like"]
    ];
    for (NSArray<NSString *> *rule in rules) {
        for (NSUInteger index = 1; index < rule.count; index++) {
            if ([joined containsString:rule[index]]) return rule.firstObject;
        }
    }
    return nil;
}

static void YTzoomFixedBarLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalFixedBarLayout != NULL) {
        ((void (*)(id, SEL))OriginalFixedBarLayout)(receiver, selector);
    }
    CGFloat height = CGRectGetHeight(receiver.bounds);
    if (height < 36.0 || height > 68.0) return;
    NSArray<UIView *> *slots = receiver.subviews;
    if (slots.count < 3 || slots.count > 10) return;
    NSString *identifier = receiver.accessibilityIdentifier;
    if (![identifier containsString:@"non_scrollable_action_bar"]) return;
    if (!YTzoomAnyActionPreferenceEnabled()) return;

    CGFloat barWidth = CGRectGetWidth(receiver.bounds);
    if (barWidth <= 0.0) return;
    CGFloat naturalSlot = barWidth / (CGFloat)slots.count;
    NSMutableArray<UIView *> *keep = [NSMutableArray array];
    NSMutableArray<NSString *> *trace = [NSMutableArray array];
    for (UIView *slot in slots) {
        NSString *preference = YTzoomBarSlotPreference(slot);
        BOOL hidden = preference.length != 0 &&
            YTzoomFeatureEnabled(preference);
        [trace addObject:[NSString stringWithFormat:@"%@%@",
            preference.length == 0 ? @"-"
                : [preference componentsSeparatedByString:@"."].lastObject,
            hidden ? @"!" : @""]];
        if (!hidden) [keep addObject:slot];
    }
    if (keep.count == 0 || keep.count == slots.count) return;

    CGFloat share = barWidth / (CGFloat)keep.count;
    NSUInteger position = 0;
    for (UIView *slot in keep) {
        CGRect frame = slot.frame;
        frame.size.width = naturalSlot;
        frame.origin.x = (CGFloat)position * share +
            (share - naturalSlot) / 2.0;
        slot.frame = frame;
        position++;
    }

    static NSTimeInterval lastLog = 0.0;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (now - lastLog > 2.0) {
        lastLog = now;
    }
}

static void YTzoomEnsureFixedBarHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomInstallInstanceHook(
            @"_ASDisplayView",
            @"layoutSubviews",
            (IMP)YTzoomFixedBarLayoutSubviews,
            &OriginalFixedBarLayout
        );
    });
}

static void YTzoomEnsureActionCellReuseHook(void) {
    YTzoomEnsureFixedBarHook();
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomInstallInstanceHook(
            @"_ASCollectionViewCell",
            @"prepareForReuse",
            (IMP)YTzoomActionCellPrepareForReuse,
            &OriginalActionCellPrepareForReuse
        );
    });
}

static UIView *YTzoomActionContainer(UIView *view) {
    if (YTzoomIsActionButtonIdentifier(view.accessibilityIdentifier)) {
        return view;
    }
    UIView *candidate = view;
    UIView *best = view;
    for (NSUInteger index = 0; candidate.superview != nil && index < 7; index++) {
        UIView *parent = candidate.superview;
        NSArray<NSString *> *buttons = YTzoomActionButtonIdentifiers(parent);
        NSUInteger sizable = YTzoomSizableChildCount(parent);
        if ([parent isKindOfClass:UIStackView.class]) {
            YTzoomRestoreHiddenView(parent);
            best = candidate;
            break;
        }
        CGFloat width = CGRectGetWidth(parent.bounds);
        CGFloat height = CGRectGetHeight(parent.bounds);
        if (width <= 0.0 || height <= 0.0) {
            break;
        }
        if (width > 180.0 || height > 130.0) {
            break;
        }
        if (buttons.count > 1 || sizable > 1) {
            YTzoomRestoreHiddenView(parent);
            break;
        }
        best = parent;
        candidate = parent;
    }
    return best;
}

static void YTzoomCompactFixedActionGroup(UIView *target) {
    UIView *group = target.superview;
    if (group == nil || CGRectGetHeight(group.bounds) < 40.0 ||
        CGRectGetHeight(group.bounds) > 56.0 ||
        CGRectGetWidth(group.bounds) < 160.0 ||
        CGRectGetWidth(group.bounds) > 260.0) {
        return;
    }
    if (objc_getAssociatedObject(group,
            YTzoomActionGroupCompactAssociation) != nil) {
        return;
    }
    objc_setAssociatedObject(group,
                             YTzoomActionGroupCompactAssociation,
                             @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak UIView *weakGroup = group;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongGroup = weakGroup;
        if (strongGroup == nil) return;
        NSArray<UIView *> *slots = [strongGroup.subviews
            filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
                ^BOOL(UIView *view, __unused NSDictionary *bindings) {
                    CGFloat width = CGRectGetWidth(view.frame);
                    CGFloat height = CGRectGetHeight(view.frame);
                    return width >= 32.0 && width <= 56.0 &&
                           height >= 40.0 && height <= 56.0;
                }]];
        slots = [slots sortedArrayUsingComparator:
            ^NSComparisonResult(UIView *left, UIView *right) {
                CGFloat leftX = CGRectGetMinX(left.frame);
                CGFloat rightX = CGRectGetMinX(right.frame);
                if (leftX < rightX) return NSOrderedAscending;
                if (leftX > rightX) return NSOrderedDescending;
                return NSOrderedSame;
            }];
        if (slots.count < 3) {
            objc_setAssociatedObject(strongGroup,
                                     YTzoomActionGroupCompactAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        CGFloat cursor = CGRectGetMinX(slots.firstObject.frame);
        for (UIView *slot in slots) {
            if (slot.hidden || slot.alpha <= 0.01) continue;
            CGRect frame = slot.frame;
            frame.origin.x = cursor;
            slot.frame = frame;
            cursor += CGRectGetWidth(frame);
        }
        objc_setAssociatedObject(strongGroup,
                                 YTzoomActionGroupCompactAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    });
}

static NSArray *YTzoomFilterActionButtons(id receiver, SEL selector,
                                           IMP original) {
    NSArray *items = original == NULL ? nil :
        ((id (*)(id, SEL))original)(receiver, selector);
    if (![items isKindOfClass:NSArray.class] || items.count == 0) return items;
    if (!YTzoomAnyActionPreferenceEnabled()) return items;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        NSString *preference = YTzoomActionPreference(item);
        if (preference.length != 0 && YTzoomFeatureEnabled(preference)) continue;
        [filtered addObject:item];
    }
    return filtered.count == items.count ? items : filtered;
}

static void YTzoomActionViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionViewDidMove)(receiver, selector);
    }
}

static void YTzoomActionsViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionsViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionsViewDidMove)(receiver, selector);
    }
}

static void YTzoomActionCellDidMove(UIView *receiver, SEL selector) {
    if (OriginalActionCellDidMove != NULL) {
        ((void (*)(id, SEL))OriginalActionCellDidMove)(receiver, selector);
    }
}

#define YTzoom_ACTION_WRAPPER(name, storage) \
static NSArray *name(id receiver, SEL selector) { \
    return YTzoomFilterActionButtons(receiver, selector, storage); \
}

YTzoom_ACTION_WRAPPER(YTzoomScrollableActionButtonsArray, OriginalScrollableActionButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomScrollableActionBarButtonsArray, OriginalScrollableActionBarButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomScrollableButtonsArray, OriginalScrollableButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomScrollableActionsArray, OriginalScrollableActionsArray)
YTzoom_ACTION_WRAPPER(YTzoomActionButtonsArray, OriginalActionButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomActionBarButtonsArray, OriginalActionBarButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomButtonsArray, OriginalButtonsArray)
YTzoom_ACTION_WRAPPER(YTzoomActionsArray, OriginalActionsArray)

static id YTzoomContentValue(id object, NSString *key) {
    if (object == nil || key.length == 0) {
        return nil;
    }
    @try {
        SEL selector = NSSelectorFromString(key);
        if ([object respondsToSelector:selector]) {
            return ((id (*)(id, SEL))objc_msgSend)(object, selector);
        }
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTzoomClassContains(id object, NSArray<NSString *> *needles);


/// Field names on `cls` whose name matches something we filter, paired with the
/// generated -has<Field> selector. Computed once per class.



static const void *YTzoomStructuralTokenAssociation =
    &YTzoomStructuralTokenAssociation;




static const void *YTzoomClassTokenAssociation = &YTzoomClassTokenAssociation;

static NSString *YTzoomClassToken(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(object,
                                                YTzoomClassTokenAssociation);
    if (cached != nil) return cached;
    NSString *value = NSStringFromClass([object class]).lowercaseString;
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, YTzoomClassTokenAssociation, value,
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    return value;
}

__attribute__((unused))
static BOOL YTzoomClassLooksLikeContainer(id object) {
    NSString *token = YTzoomClassToken(object);
    return [token containsString:@"shelfrenderer"] ||
           [token containsString:@"richsectionrenderer"] ||
           [token containsString:@"itemsectionrenderer"] ||
           [token containsString:@"richshelfrenderer"] ||
           [token containsString:@"sectionrenderer"] ||
           [token containsString:@"elementrenderer"];
}

static BOOL YTzoomClassContains(id object, NSArray<NSString *> *needles) {
    NSString *token = YTzoomClassToken(object);
    if (token.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([token containsString:needle]) return YES;
    }
    return NO;
}

__attribute__((unused))
static BOOL YTzoomChildClassContains(id section, NSArray<NSString *> *needles) {
    NSArray *entries = YTzoomContentValue(section, @"contentsArray");
    if ([entries isKindOfClass:NSArray.class]) {
        for (id entry in entries) {
            if (YTzoomClassContains(entry, needles)) return YES;
        }
    }
    return NO;
}

static const NSUInteger YTzoomFeedChildScanLimit = 64;

static _Atomic BOOL YTzoomFeedHideShorts = NO;
static _Atomic BOOL YTzoomFeedKeepSubsShorts = NO;
static _Atomic BOOL YTzoomFeedHideProducts = NO;
static _Atomic BOOL YTzoomFeedHideCommunity = NO;
static _Atomic BOOL YTzoomFeedHideHorizontalShelves = NO;
static _Atomic BOOL YTzoomFeedHideMixes = NO;
static _Atomic BOOL YTzoomFeedHidePlayables = NO;
static _Atomic BOOL YTzoomFeedHideAny = NO;
static _Atomic BOOL YTzoomFeedActionHideAny = NO;
static _Atomic BOOL YTzoomContentHideAny = NO;

static void YTzoomFeedRefreshFlags(void) {
    BOOL hideShorts =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.FeedHidden");
    BOOL hideProducts =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden");
    BOOL hideCommunity =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.CommunityPostsHidden");
    BOOL hideHorizontalShelves =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.HorizontalShelvesHidden");
    BOOL hideMixes =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.MixesHidden");
    BOOL hidePlayables =
        YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.PlayablesHidden");
    BOOL hideAny = (hideShorts || hideProducts ||
        hideCommunity || hideHorizontalShelves || hideMixes || hidePlayables);
    BOOL actionHideAny = YTzoomAnyActionPreferenceEnabled();
    BOOL contentHideAny = (hideAny ||
        actionHideAny ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentsHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentPreviewsHidden") ||
        YTzoomShortsSuggestionPillHidden() ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentGuidelinesHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.TopicsHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Privacy.SearchHistoryDisabled") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Ads.PremiumPromosHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.App.UpdatePromptHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.SuggestedVideosHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.RelatedVideosHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ContinueWatchingDisabled") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.PauseCardHidden") ||
        YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.StickerAdsHidden"));
    atomic_store(&YTzoomFeedHideShorts, hideShorts);
    atomic_store(&YTzoomFeedKeepSubsShorts,
        YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.SubscriptionsKept"));
    atomic_store(&YTzoomFeedHideProducts, hideProducts);
    atomic_store(&YTzoomFeedHideCommunity, hideCommunity);
    atomic_store(&YTzoomFeedHideHorizontalShelves, hideHorizontalShelves);
    atomic_store(&YTzoomFeedHideMixes, hideMixes);
    atomic_store(&YTzoomFeedHidePlayables, hidePlayables);
    atomic_store(&YTzoomFeedHideAny, hideAny);
    atomic_store(&YTzoomFeedActionHideAny, actionHideAny);
    atomic_store(&YTzoomContentHideAny, contentHideAny);
}

static void YTzoomFeedScheduleRefresh(void) {
    static BOOL pending = NO;
    if (pending) return;
    pending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        pending = NO;
        YTzoomFeedRefreshFlags();
    });
}

static void YTzoomFeedEnsureFlagObserver(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomFeedRefreshFlags();
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:YTzoomPreferencesDidChangeNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            YTzoomFeedScheduleRefresh();
                        }];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
                            YTzoomFeedScheduleRefresh();
                        }];
    });
}

static SEL YTzoomSelContentsArray;
static SEL YTzoomSelItemsArray;
static SEL YTzoomSelContent;
static SEL YTzoomSelElementRenderer;
static SEL YTzoomSelShelfRenderer;
static SEL YTzoomSelHorizontalListRenderer;
static SEL YTzoomSelItemSectionRenderer;
static SEL YTzoomSelExpandedShelfContentsRenderer;
static SEL YTzoomSelElementIdentifier;
static SEL YTzoomSelSharedElementIdentifier;
static SEL YTzoomSelData;
static SEL YTzoomSelHasReelItemRenderer;
static SEL YTzoomSelHasMerchShelfRenderer;
static SEL YTzoomSelHasMerchItemRenderer;
static SEL YTzoomSelHasCommunity[5];
static SEL YTzoomSelHasMix[6];
static SEL YTzoomSelHasGame[2];
static SEL YTzoomFeedContainerSels[8];

static void YTzoomFeedInitSels(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomSelContentsArray = @selector(contentsArray);
        YTzoomSelItemsArray = @selector(itemsArray);
        YTzoomSelContent = @selector(content);
        YTzoomSelElementRenderer = @selector(elementRenderer);
        YTzoomSelShelfRenderer = @selector(shelfRenderer);
        YTzoomSelHorizontalListRenderer = @selector(horizontalListRenderer);
        YTzoomSelItemSectionRenderer = @selector(itemSectionRenderer);
        YTzoomSelExpandedShelfContentsRenderer =
            @selector(expandedShelfContentsRenderer);
        YTzoomSelElementIdentifier = @selector(elementIdentifier);
        YTzoomSelSharedElementIdentifier = @selector(sharedElementIdentifier);
        YTzoomSelData = @selector(data);
        YTzoomSelHasReelItemRenderer = @selector(hasReelItemRenderer);
        YTzoomSelHasMerchShelfRenderer =
            @selector(hasMerchandiseShelfRenderer);
        YTzoomSelHasMerchItemRenderer =
            @selector(hasMerchandiseItemRenderer);
        YTzoomSelHasCommunity[0] =
            @selector(hasCommunityPostSectionRenderer);
        YTzoomSelHasCommunity[1] = @selector(hasCommunityPost);
        YTzoomSelHasCommunity[2] =
            @selector(hasBackstagePostElementRenderer);
        YTzoomSelHasCommunity[3] = @selector(hasPostsContainerRenderer);
        YTzoomSelHasCommunity[4] =
            @selector(hasChannelPostBulletinRenderer);
        YTzoomSelHasMix[0] = @selector(hasAutomixPreviewVideoRenderer);
        YTzoomSelHasMix[1] = @selector(hasAutomixPlaylistVideoRenderer);
        YTzoomSelHasMix[2] = @selector(hasRadioRenderer);
        YTzoomSelHasMix[3] = @selector(hasPivotRadioRenderer);
        YTzoomSelHasMix[4] = @selector(hasRadioAutomixPlaylistId);
        YTzoomSelHasMix[5] = @selector(hasRadioPlaylistMixPlaylistId);
        YTzoomSelHasGame[0] = @selector(hasGameCardRenderer);
        YTzoomSelHasGame[1] = @selector(hasGameDetailsRenderer);
        YTzoomFeedContainerSels[0] = YTzoomSelContentsArray;
        YTzoomFeedContainerSels[1] = YTzoomSelItemsArray;
        YTzoomFeedContainerSels[2] = YTzoomSelContent;
        YTzoomFeedContainerSels[3] = YTzoomSelElementRenderer;
        YTzoomFeedContainerSels[4] = YTzoomSelShelfRenderer;
        YTzoomFeedContainerSels[5] = YTzoomSelHorizontalListRenderer;
        YTzoomFeedContainerSels[6] = YTzoomSelItemSectionRenderer;
        YTzoomFeedContainerSels[7] =
            YTzoomSelExpandedShelfContentsRenderer;
    });
}

static inline BOOL YTzoomFastHasSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return NO;
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static inline BOOL YTzoomFastHasAnySel(id object, SEL *selectors,
                                       NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if (YTzoomFastHasSel(object, selectors[i])) return YES;
    }
    return NO;
}

static inline id YTzoomFastChildSel(id object, SEL selector) {
    if (object == nil || selector == NULL) return nil;
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSArray *YTzoomFastContents(id object) {
    if (object == nil) return nil;
    YTzoomFeedInitSels();
    id value = YTzoomFastChildSel(object, YTzoomSelContentsArray);
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static BOOL YTzoomFastEntryMatchesSel(id entry,
                                      SEL *flags, NSUInteger flagCount,
                                      NSArray<NSString *> *classes) {
    if (entry == nil) return NO;
    if (classes != nil && YTzoomClassContains(entry, classes)) return YES;
    if (flags != NULL && flagCount != 0 &&
        YTzoomFastHasAnySel(entry, flags, flagCount)) {
        return YES;
    }
    id nested = YTzoomFastChildSel(entry, YTzoomSelElementRenderer);
    if (nested != nil && nested != entry) {
        if (classes != nil && YTzoomClassContains(nested, classes)) return YES;
        if (flags != NULL && flagCount != 0 &&
            YTzoomFastHasAnySel(nested, flags, flagCount)) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTzoomFastIdentifierMatches(id object,
                                         NSArray<NSString *> *markers) {
    if (object == nil || markers == nil || markers.count == 0) return NO;
    YTzoomFeedInitSels();
    SEL keys[2] = { YTzoomSelElementIdentifier,
                    YTzoomSelSharedElementIdentifier };
    for (NSUInteger k = 0; k < 2; k++) {
        id value = YTzoomFastChildSel(object, keys[k]);
        if (![value isKindOfClass:NSString.class] ||
            ((NSString *)value).length == 0) {
            continue;
        }
        NSString *valueStr = (NSString *)value;
        if ([valueStr rangeOfString:@"."].location == NSNotFound &&
            [valueStr canBeConvertedToEncoding:NSASCIIStringEncoding]) {
            for (NSString *marker in markers) {
                if (marker.length != 0 &&
                    [valueStr rangeOfString:marker
                                    options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
            }
        } else {
            NSString *token = [[valueStr lowercaseString]
                stringByReplacingOccurrencesOfString:@"." withString:@"_"];
            for (NSString *marker in markers) {
                if (marker.length != 0 && [token containsString:marker]) return YES;
            }
        }
    }
    return NO;
}

typedef NS_OPTIONS(NSUInteger, YTzoomFeedKind) {
    YTzoomFeedKindShorts    = 1 << 0,
    YTzoomFeedKindProducts  = 1 << 1,
    YTzoomFeedKindCommunity = 1 << 2,
    YTzoomFeedKindMix       = 1 << 3,
    YTzoomFeedKindPlayable  = 1 << 4,
    YTzoomFeedKindHorizontalShelves = 1 << 5,
};

static NSArray<NSString *> *YTzoomShortsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"reelitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTzoomShortsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"shorts_shelf", @"reel_shelf",
        @"shorts_lockup", @"shortslockup",
        @"shorts_video_cell", @"reelwatchendpoint"]; });
    return v;
}
static NSArray<NSString *> *YTzoomProductsClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandiseshelfrenderer",
        @"merchandiseitemrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTzoomProductsIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"product_in_video", @"products_in_video",
        @"promoted_sparkles_text_product"]; });
    return v;
}
static NSArray<NSString *> *YTzoomCommunityClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"communitypostsectionrenderer",
        @"postscontainerrenderer", @"communitypostrenderer",
        @"backstagepostrenderer", @"backstageimagerenderer",
        @"sharedpostrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTzoomCommunityIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"community_post", @"communitypost",
        @"backstage"]; });
    return v;
}
static NSArray<NSString *> *YTzoomMixClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"automixpreviewvideorenderer",
        @"automixplaylistvideorenderer", @"mixradiorenderer",
        @"radiorenderer", @"feednudgerenderer"]; });
    return v;
}
static NSArray<NSString *> *YTzoomMixIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"automix", @"radio_playlist_mix",
        @"feed_nudge"]; });
    return v;
}
static NSArray<NSString *> *YTzoomPlayableClasses(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playablesshelfrenderer",
        @"playableitemrenderer", @"compactboxgamerenderer",
        @"playablegamerenderer", @"gamecardrenderer",
        @"gamedetailsrenderer"]; });
    return v;
}
static NSArray<NSString *> *YTzoomPlayableIdentifiers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[@"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"horizontal_gaming_shelf", @"mini_game_card"]; });
    return v;
}

static BOOL YTzoomFastShouldDescend(id object) {
    if (object == nil) return NO;
    if ([object isKindOfClass:NSString.class] ||
        [object isKindOfClass:NSNumber.class] ||
        [object isKindOfClass:NSData.class] ||
        [object isKindOfClass:NSDate.class] ||
        [object isKindOfClass:NSValue.class] ||
        [object isKindOfClass:NSURL.class]) {
        return NO;
    }
    return YES;
}

static inline YTzoomFeedKind YTzoomFeedKindForNode(id node,
                                                  YTzoomFeedKind wanted) {
    YTzoomFeedKind found = 0;
    if (wanted & YTzoomFeedKindShorts) {
        if (YTzoomClassContains(node, YTzoomShortsClasses()) ||
            YTzoomFastHasSel(node, YTzoomSelHasReelItemRenderer) ||
            YTzoomFastIdentifierMatches(node, YTzoomShortsIdentifiers())) {
            found |= YTzoomFeedKindShorts;
        } else {
            id nested = YTzoomFastChildSel(node, YTzoomSelElementRenderer);
            if (nested != nil && nested != node &&
                (YTzoomClassContains(nested, YTzoomShortsClasses()) ||
                 YTzoomFastHasSel(nested, YTzoomSelHasReelItemRenderer))) {
                found |= YTzoomFeedKindShorts;
            }
        }
    }
    if ((wanted & YTzoomFeedKindProducts) && !(found & YTzoomFeedKindProducts)) {
        SEL f[2] = { YTzoomSelHasMerchShelfRenderer,
                     YTzoomSelHasMerchItemRenderer };
        if (YTzoomFastEntryMatchesSel(node, f, 2,
                                      YTzoomProductsClasses()) ||
            YTzoomFastIdentifierMatches(node,
                                        YTzoomProductsIdentifiers())) {
            found |= YTzoomFeedKindProducts;
        }
    }
    if ((wanted & YTzoomFeedKindCommunity) &&
        !(found & YTzoomFeedKindCommunity)) {
        if (YTzoomFastEntryMatchesSel(node, YTzoomSelHasCommunity, 5,
                                      YTzoomCommunityClasses()) ||
            YTzoomFastIdentifierMatches(node,
                                        YTzoomCommunityIdentifiers())) {
            found |= YTzoomFeedKindCommunity;
        }
    }
    if ((wanted & YTzoomFeedKindMix) && !(found & YTzoomFeedKindMix)) {
        if (YTzoomFastEntryMatchesSel(node, YTzoomSelHasMix, 6,
                                      YTzoomMixClasses()) ||
            YTzoomFastIdentifierMatches(node, YTzoomMixIdentifiers())) {
            found |= YTzoomFeedKindMix;
        }
    }
    if ((wanted & YTzoomFeedKindPlayable) &&
        !(found & YTzoomFeedKindPlayable)) {
        if (YTzoomFastEntryMatchesSel(node, YTzoomSelHasGame, 2,
                                      YTzoomPlayableClasses()) ||
            YTzoomFastIdentifierMatches(node,
                                        YTzoomPlayableIdentifiers())) {
            found |= YTzoomFeedKindPlayable;
        }
    }
    return found;
}

static YTzoomFeedKind YTzoomFeedKindStructural(id section,
                                              YTzoomFeedKind wanted,
                                              BOOL *outTruncated) {
    if (outTruncated != NULL) *outTruncated = NO;
    if (section == nil || wanted == 0) return 0;
    YTzoomFeedInitSels();
    NSHashTable *visited = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsObjectPointerPersonality |
        NSPointerFunctionsWeakMemory];
    NSMutableArray *pending = [NSMutableArray arrayWithObject:section];
    NSMutableArray *depths = [NSMutableArray arrayWithObject:@0];
    YTzoomFeedKind found = 0;
    NSUInteger scanned = 0;
    while (pending.count != 0 && pending.count < 4096) {
        if (scanned >= YTzoomFeedChildScanLimit) {
            if (outTruncated != NULL) *outTruncated = YES;
            break;
        }
        id node = pending.lastObject;
        [pending removeLastObject];
        NSNumber *depth = depths.lastObject;
        [depths removeLastObject];
        if (node == nil || [visited containsObject:node]) continue;
        [visited addObject:node];
        scanned++;
        found |= YTzoomFeedKindForNode(node, wanted & ~found);
        if ((found & wanted) == wanted) return found;
        if (depth.unsignedIntegerValue >= 3) continue;
        NSNumber *next = @(depth.unsignedIntegerValue + 1);
        if ([node isKindOfClass:NSArray.class]) {
            for (id child in (NSArray *)node) {
                if (!YTzoomFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
            continue;
        }
        if (!YTzoomFastShouldDescend(node)) continue;
        for (NSUInteger i = 0; i < 8; i++) {
            id child = YTzoomFastChildSel(node, YTzoomFeedContainerSels[i]);
            if (child == nil || child == node) continue;
            if ([child isKindOfClass:NSArray.class]) {
                for (id grand in (NSArray *)child) {
                    if (!YTzoomFastShouldDescend(grand)) continue;
                    if ([visited containsObject:grand]) continue;
                    [pending addObject:grand];
                    [depths addObject:next];
                }
            } else {
                if (!YTzoomFastShouldDescend(child)) continue;
                if ([visited containsObject:child]) continue;
                [pending addObject:child];
                [depths addObject:next];
            }
        }
    }
    return found;
}

static BOOL YTzoomFastEntryIsReel(id entry) {
    if (entry == nil) return NO;
    YTzoomFeedInitSels();
    if (YTzoomClassContains(entry, YTzoomShortsClasses())) return YES;
    if (YTzoomFastHasSel(entry, YTzoomSelHasReelItemRenderer)) return YES;
    id nested = YTzoomFastChildSel(entry, YTzoomSelElementRenderer);
    if (nested != nil && nested != entry) {
        if (YTzoomClassContains(nested, YTzoomShortsClasses())) return YES;
        if (YTzoomFastHasSel(nested, YTzoomSelHasReelItemRenderer)) return YES;
    }
    return NO;
}

static BOOL YTzoomFastAllChildrenReel(id section) {
    NSArray *entries = YTzoomFastContents(section);
    if (![entries isKindOfClass:NSArray.class] || entries.count == 0) return NO;
    for (id entry in entries) {
        if (!YTzoomFastEntryIsReel(entry)) return NO;
    }
    return YES;
}



static const void *YTzoomNormalizedDescriptionAssociation =
    &YTzoomNormalizedDescriptionAssociation;

static NSString *YTzoomNormalizedDescription(id object) {
    if (object == nil) return @"";
    NSString *cached = objc_getAssociatedObject(
        object, YTzoomNormalizedDescriptionAssociation);
    if (cached != nil) return cached;
    NSString *value = [[[object description] lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    if (value == nil) value = @"";
    objc_setAssociatedObject(object, YTzoomNormalizedDescriptionAssociation, value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return value;
}

static const void *YTzoomSectionBytesAssociation =
    &YTzoomSectionBytesAssociation;

static NSData *YTzoomSectionBytes(id section) {
    if (section == nil) return nil;
    NSData *cached = objc_getAssociatedObject(section,
                                              YTzoomSectionBytesAssociation);
    if (cached != nil) {
        return cached.length == 0 ? nil : cached;
    }
    YTzoomFeedInitSels();
    id data = YTzoomFastChildSel(section, YTzoomSelData);
    if (![data isKindOfClass:NSData.class]) data = nil;
    objc_setAssociatedObject(section, YTzoomSectionBytesAssociation,
                             data ?: [NSData data],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data;
}

static NSData *YTzoomDescendantBytes(id section) {
    YTzoomFeedInitSels();
    NSMutableData *combined = nil;
    for (NSUInteger i = 0; i < 8; i++) {
        id child = YTzoomFastChildSel(section, YTzoomFeedContainerSels[i]);
        if (child == nil) continue;
        NSArray *entries = [child isKindOfClass:NSArray.class]
            ? (NSArray *)child : @[child];
        NSUInteger taken = 0;
        for (id entry in entries) {
            if (taken >= 12) break;
            taken++;
            NSData *bytes = YTzoomSectionBytes(entry);
            if (bytes.length == 0) continue;
            if (combined == nil) combined = [NSMutableData data];
            [combined appendData:bytes];
        }
    }
    return combined;
}


static BOOL YTzoomBytesContain(NSData *haystack, NSArray<NSString *> *needles) {
    if (haystack.length == 0) return NO;
    for (NSString *needle in needles) {
        if ([needle containsString:@"renderer"] &&
            ![needle containsString:@"_"]) {
            continue;  // class-name style marker, never present in the wire form
        }
        NSData *pattern = [needle dataUsingEncoding:NSASCIIStringEncoding];
        if (pattern.length == 0) continue;
        if ([haystack rangeOfData:pattern
                           options:0
                             range:NSMakeRange(0, haystack.length)].location
                != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static NSArray<NSString *> *YTzoomProductsMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"merchandise_shelf", @"merchandise_item",
        @"product_shelf", @"products_shelf", @"shopping_shelf",
        @"promoted_sparkles_text_product_watch",
        @"product_in_video", @"products_in_video"
    ]; });
    return v;
}

static NSArray<NSString *> *YTzoomShortsBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"/oar2.jpg", @"reel_shelf", @"reelwatchendpoint",
        @"shorts_lockup", @"shorts_shelf", @"shorts_video_cell",
        @"shortslockup", @"shortslockupviewmodel", @"shortsshelfeml"
    ]; });
    return v;
}
static NSArray<NSString *> *YTzoomCommunityBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"backstage_post",
        @"community_post",
        @"community_post_section",
        @"id.ui.backstage.original_post",
        @"id.ui.backstage.post",
        @"id.ui.backstage.post_menu_button",
        @"id_ui_backstage_original_post",
        @"image_post_root.eml",
        @"images_post_responsive_root",
        @"images_post_root",
        @"images_post_root.eml",
        @"images_post_root_slim",
        @"images_post_root_slim.eml",
        @"images_post_slim",
        @"options_post_responsive_root",
        @"options_post_root",
        @"poll_post_responsive_root",
        @"poll_post_root",
        @"post_base_wrapper",
        @"post_base_wrapper.eml",
        @"post_base_wrapper_slim",
        @"post_base_wrapper_slim.eml",
        @"post_shelf",
        @"post_shelf_slim",
        @"shared_post_responsive_root",
        @"shared_post_root",
        @"text_post_responsive_root",
        @"text_post_root",
        @"text_post_root.eml",
        @"text_post_root_slim",
        @"videos_post_responsive_root",
        @"videos_post_root"
    ]; });
    return v;
}
static NSArray<NSString *> *YTzoomMixBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"feed_nudge_view", @"feed_nudge",
        @"radioautomixplaylistid", @"radioplaylistmixplaylistid",
        @"radio_playlist_mix"
    ]; });
    return v;
}
static NSArray<NSString *> *YTzoomPlayableBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"playables_shelf", @"playableshelf",
        @"playable_game", @"playablegame",
        @"playables.shelf", @"playable.game",
        @".com/playables/", @"playables_shelf.eml",
        @"playable_card.eml",
        @"horizontal_gaming_shelf", @"mini_game_card"
    ]; });
    return v;
}

static NSArray<NSString *> *YTzoomHorizontalShelfBytesMarkers(void) {
    static NSArray<NSString *> *v;
    static dispatch_once_t t;
    dispatch_once(&t, ^{ v = @[
        @"horizontal_shelf.eml",
    ]; });
    return v;
}

static const void *YTzoomFeedKindKey = &YTzoomFeedKindKey;
static const void *YTzoomFeedSearchedKey = &YTzoomFeedSearchedKey;

static YTzoomFeedKind YTzoomFeedKindForSection(id section,
                                              YTzoomFeedKind wanted) {
    if (section == nil || wanted == 0) return 0;
    if ([NSStringFromClass([section class])
            isEqualToString:@"YTIFeedFilterChipBarRenderer"]) {
        return 0;
    }
    NSNumber *memo = objc_getAssociatedObject(section, YTzoomFeedKindKey);
    YTzoomFeedKind cached = memo.unsignedIntegerValue;
    YTzoomFeedKind searched = [objc_getAssociatedObject(
        section, YTzoomFeedSearchedKey) unsignedIntegerValue];
    if (memo != nil && ((searched & wanted) == wanted)) {
        return cached & wanted;
    }
    BOOL truncated = NO;
    YTzoomFeedKind structural = YTzoomFeedKindStructural(
        section, wanted & ~YTzoomFeedKindHorizontalShelves, &truncated);
    if ((wanted & YTzoomFeedKindShorts) &&
        !(structural & YTzoomFeedKindShorts)) {
        if (YTzoomFastAllChildrenReel(section)) {
            structural |= YTzoomFeedKindShorts;
        }
    }
    YTzoomFeedKind missing = wanted & ~structural;
    if (missing != 0) {
        NSData *bytes = YTzoomSectionBytes(section);
        if (bytes.length == 0) bytes = YTzoomDescendantBytes(section);
        if (bytes.length != 0) {
            if ((missing & YTzoomFeedKindShorts) &&
                YTzoomBytesContain(bytes, YTzoomShortsBytesMarkers())) {
                structural |= YTzoomFeedKindShorts;
            }
            if ((missing & YTzoomFeedKindProducts) &&
                YTzoomBytesContain(bytes, YTzoomProductsMarkers())) {
                structural |= YTzoomFeedKindProducts;
            }
            if ((missing & YTzoomFeedKindCommunity) &&
                YTzoomBytesContain(bytes, YTzoomCommunityBytesMarkers())) {
                structural |= YTzoomFeedKindCommunity;
            }
            if ((missing & YTzoomFeedKindMix) &&
                YTzoomBytesContain(bytes, YTzoomMixBytesMarkers())) {
                structural |= YTzoomFeedKindMix;
            }
            if ((missing & YTzoomFeedKindPlayable) &&
                YTzoomBytesContain(bytes, YTzoomPlayableBytesMarkers())) {
                structural |= YTzoomFeedKindPlayable;
            }
            if ((missing & YTzoomFeedKindHorizontalShelves) &&
                YTzoomBytesContain(bytes,
                                   YTzoomHorizontalShelfBytesMarkers())) {
                structural |= YTzoomFeedKindHorizontalShelves;
            }
        }
    }
    objc_setAssociatedObject(section, YTzoomFeedKindKey, @(structural),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    const YTzoomFeedKind settled =
        truncated ? (searched | (wanted & structural)) : (searched | wanted);
    objc_setAssociatedObject(section, YTzoomFeedSearchedKey, @(settled),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return structural & wanted;
}

static BOOL YTzoomIsGuidelinesSection(id section);

static BOOL YTzoomKeepsShortsInFeed(id receiver) {
    static SEL browseSel;
    if (browseSel == NULL) browseSel = NSSelectorFromString(@"browseID");
    if (![receiver respondsToSelector:browseSel]) return NO;
    id browseID = ((id (*)(id, SEL))objc_msgSend)(receiver, browseSel);
    if (![browseID isKindOfClass:NSString.class]) return NO;
    if ([browseID isEqualToString:@"FEsubscriptions"]) {
        return atomic_load(&YTzoomFeedKeepSubsShorts);
    }
    static NSSet<NSString *> *personal;
    if (personal == nil) personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary", @"FEplaylist_aggregation"]];
    return [personal containsObject:browseID];
}

static BOOL YTzoomKeepsShelvesInFeed(id receiver) {
    static SEL browseSel;
    if (browseSel == NULL) browseSel = NSSelectorFromString(@"browseID");
    if (![receiver respondsToSelector:browseSel]) return NO;
    id browseID = ((id (*)(id, SEL))objc_msgSend)(receiver, browseSel);
    if (![browseID isKindOfClass:NSString.class]) return NO;
    static NSSet<NSString *> *personal;
    if (personal == nil) personal = [NSSet setWithArray:@[@"FEhistory", @"FElibrary"]];
    return [personal containsObject:browseID];
}

static NSArray *YTzoomFilteredFeedSections(id receiver, NSArray *sections) {
    YTzoomFeedEnsureFlagObserver();
    NSArray *adFiltered = YTzoomFilterAdSections(sections);
    if ([adFiltered isKindOfClass:NSArray.class] && adFiltered.count != 0 &&
        YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentGuidelinesHidden")) {
        NSIndexSet *guidelines = [adFiltered indexesOfObjectsPassingTest:
            ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
            return YTzoomIsGuidelinesSection(section);
        }];
        if (guidelines.count != 0) {
            NSMutableArray *kept = [adFiltered mutableCopy];
            [kept removeObjectsAtIndexes:guidelines];
            adFiltered = kept;
        }
    }
    if (!atomic_load(&YTzoomFeedHideAny) ||
        ![adFiltered isKindOfClass:NSArray.class]) {
        return adFiltered;
    }
    BOOL hideShorts = atomic_load(&YTzoomFeedHideShorts) && !YTzoomKeepsShortsInFeed(receiver);
    BOOL hideProducts = atomic_load(&YTzoomFeedHideProducts);
    BOOL hideCommunity = atomic_load(&YTzoomFeedHideCommunity);
    BOOL hideHorizontalShelves = atomic_load(&YTzoomFeedHideHorizontalShelves) &&
        !YTzoomKeepsShelvesInFeed(receiver);
    BOOL hideMixes = atomic_load(&YTzoomFeedHideMixes);
    BOOL hidePlayables = atomic_load(&YTzoomFeedHidePlayables);
    YTzoomFeedKind wanted = 0;
    if (hideShorts) wanted |= YTzoomFeedKindShorts;
    if (hideProducts) wanted |= YTzoomFeedKindProducts;
    if (hideCommunity) wanted |= YTzoomFeedKindCommunity;
    if (hideMixes) wanted |= YTzoomFeedKindMix;
    if (hidePlayables) wanted |= YTzoomFeedKindPlayable;
    if (hideHorizontalShelves) wanted |= YTzoomFeedKindHorizontalShelves;
    if (wanted == 0) return adFiltered;
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:adFiltered.count];
    for (id section in adFiltered) {
        YTzoomFeedKind kind = YTzoomFeedKindForSection(section, wanted);
        NSString *cut = nil;
        if (hideShorts && (kind & YTzoomFeedKindShorts)) cut = @"shorts";
        else if (hideProducts && (kind & YTzoomFeedKindProducts)) cut = @"products";
        else if (hideCommunity && (kind & YTzoomFeedKindCommunity)) cut = @"community";
        else if (hideMixes && (kind & YTzoomFeedKindMix)) cut = @"mixes";
        else if (hidePlayables && (kind & YTzoomFeedKindPlayable)) cut = @"playables";
        else if (hideHorizontalShelves &&
            (kind & YTzoomFeedKindHorizontalShelves)) cut = @"shelves";
        if (cut != nil) {
            continue;
        }
        [filtered addObject:section];
    }
    return filtered;
}

static id YTzoomSectionControllers(id receiver, SEL selector,
                                   NSArray *sections, id reloadMap) {
    if (OriginalSectionControllers == NULL) return nil;
    YTzoomEnsureStructuralActionHook();
    NSArray *filtered = YTzoomFilteredFeedSections(receiver, sections);
    return ((id (*)(id, SEL, id, id))OriginalSectionControllers)(
        receiver, selector, filtered, reloadMap);
}

static BOOL YTzoomContentContains(NSString *token,
                                  NSArray<NSString *> *needles) {
    for (NSString *needle in needles) {
        if ([token containsString:needle]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTzoomViewInsideReelOverlay(UIView *view);

static BOOL YTzoomContentShouldHide(UIView *view, BOOL *hideSuperview) {
    NSString *identifier = [view.accessibilityIdentifier.lowercaseString
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    NSString *token = [NSString stringWithFormat:@"%@ %@ %@",
                       identifier ?: @"",
                       view.accessibilityLabel.lowercaseString ?: @"",
                       NSStringFromClass(view.class).lowercaseString];

    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentsHidden")) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"]) {
            if (hideSuperview != NULL) {
                *hideSuperview = YES;
            }
            return YES;
        }
        if (YTzoomContentContains(token, @[
            @"id_ui_comments_composite_entry_point_teaser",
            @"id_ui_comments_entry_point_teaser",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container"
        ])) {
            return YES;
        }
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentPreviewsHidden") &&
        [identifier isEqualToString:@"id_ui_comments_entry_point_teaser"]) {
        return YES;
    }
    if (YTzoomShortsSuggestionPillHidden() &&
        [identifier isEqualToString:
            @"id_elements_components_suggested_action"] &&
        YTzoomViewInsideReelOverlay(view)) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentGuidelinesHidden") &&
        YTzoomContentContains(token, @[
            @"id_comment_guidelines_text",
            @"id_comment_channel_guidelines_bottom_sheet_container",
            @"id_comment_channel_guidelines_entry_banner_container",
            @"channel_guidelines_entry_banner",
            @"community_guidelines",
            @"viewer_engagement_message"
        ])) {
        if ([identifier isEqualToString:@"id_comment_guidelines_text"] &&
            hideSuperview != NULL) {
            *hideSuperview = YES;
        }
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.TopicsHidden") &&
        YTzoomContentContains(token, @[@"topic_chip", @"feed_filter", @"chip_cloud"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Privacy.SearchHistoryDisabled") &&
        YTzoomContentContains(token, @[@"search_history", @"history_suggestion"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        YTzoomContentContains(token, @[@"paid_promotion", @"paidpromotion"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Ads.PremiumPromosHidden") &&
        YTzoomContentContains(token, @[@"premium_upsell", @"premium_promo"])) {
        return YES;
    }
    if ((YTzoomFeatureEnabled(@"YTzoom.Preference.Ads.PremiumPromosHidden") ||
         YTzoomFeatureEnabled(@"YTzoom.Preference.App.UpdatePromptHidden")) &&
        YTzoomContentContains(token, @[@"update_dialog", @"upgrade_dialog"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.SuggestedVideosHidden") &&
        YTzoomContentContains(token, @[@"suggested_video", @"related_video"])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.RelatedVideosHidden") &&
        YTzoomContentContains(token, @[
            @"related_video", @"relatedvideo", @"more_videos", @"watch_next"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ContinueWatchingDisabled") &&
        YTzoomContentContains(token, @[
            @"continue_watching", @"continuewatching", @"resume_watching"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.PauseCardHidden") &&
        YTzoomContentContains(token, @[
            @"shorts_pause", @"reel_pause", @"pause_card", @"pausecard",
            @"paused_state_carousel", @"reelpausedstatecarousel"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        YTzoomContentContains(token, @[
            @"shorts_product", @"product_sticker", @"shopping_carousel",
            @"shopping_destination", @"tagged_product", @"creator_product"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Shorts.StickerAdsHidden") &&
        YTzoomContentContains(token, @[
            @"brand_link_sticker", @"product_sticker", @"promoted_sticker",
            @"sponsored_sticker", @"shorts_ads_shopping"
        ])) {
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        YTzoomContentContains(token, YTzoomProductsMarkers())) {
        return YES;
    }
    if (YTzoomFeatureEnabled(
            @"YTzoom.Preference.Feed.CommunityPostsHidden") &&
        [identifier isEqualToString:@"id_ui_backstage_original_post"]) {
        YTzoomCollapseHostCell(view);
        return YES;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Feed.MixesHidden") &&
        [identifier isEqualToString:@"feed_nudge_view"]) {
        return YES;
    }
    return NO;
}

static void YTzoomScheduleFixedBarLayout(UIView *view) {
    UIView *bar = nil;
    UIView *walk = view;
    for (NSUInteger depth = 0; walk != nil && depth < 8; depth++) {
        if ([walk.accessibilityIdentifier
                containsString:@"non_scrollable_action_bar"]) {
            bar = walk;
            break;
        }
        walk = walk.superview;
    }
    if (bar == nil) return;
    __weak UIView *weakBar = bar;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *strongBar = weakBar;
        if (strongBar == nil) return;
        [strongBar setNeedsLayout];
        [strongBar layoutIfNeeded];
    });
}

static void YTzoomApplyContentVisibility(UIView *view) {
    YTzoomFeedEnsureFlagObserver();
    if (!atomic_load(&YTzoomContentHideAny) &&
        !atomic_load(&YTzoomFeedActionHideAny)) {
        NSNumber *idleBaseline = objc_getAssociatedObject(
            view, YTzoomContentHiddenAssociation);
        if (idleBaseline == nil) return;
        view.hidden = NO;
        view.userInteractionEnabled = YES;
        objc_setAssociatedObject(view, YTzoomContentHiddenAssociation, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    NSString *actionPreference = atomic_load(&YTzoomFeedActionHideAny)
        ? YTzoomActionPreferenceForView(view) : nil;
    if (actionPreference.length != 0) {
        YTzoomEnsureStructuralActionHook();
        UIView *target = YTzoomActionContainer(view);
        BOOL hidden = YTzoomFeatureEnabled(actionPreference);
        NSNumber *baseline = objc_getAssociatedObject(
            target,
            YTzoomContentHiddenAssociation
        );
        if (hidden) {
            if (baseline == nil) {
                objc_setAssociatedObject(target,
                                         YTzoomContentHiddenAssociation, @YES,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            target.hidden = YES;
            target.userInteractionEnabled = NO;
            YTzoomRefreshActionCollection(view);
        } else if (baseline != nil) {
            target.hidden = NO;
            target.userInteractionEnabled = YES;
            objc_setAssociatedObject(target,
                                     YTzoomContentHiddenAssociation,
                                     nil,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        YTzoomCompactFixedActionGroup(target);
        YTzoomScheduleFixedBarLayout(view);
        return;
    }

    BOOL hideSuperview = NO;
    BOOL hidden = YTzoomContentShouldHide(view, &hideSuperview);

    UIView *target = hideSuperview ? view.superview : view;
    if (target == nil) {
        return;
    }

    NSNumber *baseline = objc_getAssociatedObject(
        target,
        YTzoomContentHiddenAssociation
    );
    if (hidden) {
        if (baseline == nil) {
            objc_setAssociatedObject(target,
                                     YTzoomContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        target.hidden = YES;
        target.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        target.hidden = NO;
        target.userInteractionEnabled = YES;
        objc_setAssociatedObject(target,
                                 YTzoomContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTzoomConsiderProductDisplayView(UIView *view, NSString *identifier) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        YTzoomProductIdentifierMatches(identifier)) {
        YTzoomHideProductSubtree(view);
    }
}




static void YTzoomDisplayViewDidMove(UIView *receiver, SEL selector) {
    if (OriginalDisplayViewDidMove != NULL) {
        ((void (*)(id, SEL))OriginalDisplayViewDidMove)(receiver, selector);
    }
    YTzoomApplyContentVisibility(receiver);
    YTzoomHandleAdDisplayView(receiver);
    YTzoomConsiderProductDisplayView(receiver, receiver.accessibilityIdentifier);
}




static BOOL YTzoomViewInsideReelOverlay(UIView *view) {
    UIView *walker = view;
    for (NSUInteger depth = 0; depth < 12 && walker != nil; depth++) {
        if ([walker.accessibilityIdentifier isEqualToString:@"id.reel_overlay"]) {
            return YES;
        }
        walker = walker.superview;
    }
    return NO;
}




static void YTzoomDisplayViewSetIdentifier(UIView *receiver,
                                           SEL selector,
                                           NSString *identifier) {
    if (OriginalDisplayViewSetIdentifier != NULL) {
        ((void (*)(id, SEL, id))OriginalDisplayViewSetIdentifier)(
            receiver,
            selector,
            identifier
        );
    }
    YTzoomApplyContentVisibility(receiver);
    YTzoomHandleAdDisplayView(receiver);
    YTzoomConsiderProductDisplayView(receiver, identifier);
}

static BOOL YTzoomHideTopics(void) {
    return YTzoomFeatureEnabled(@"YTzoom.Preference.Navigation.TopicsHidden");
}

static void YTzoomCollapseSubheader(id receiver) {
    SEL height = NSSelectorFromString(@"setMaximumSubheaderHeight:");
    if ([receiver respondsToSelector:height]) {
        ((void (*)(id, SEL, double))objc_msgSend)(receiver, height, 0.0);
    }
    for (NSString *name in @[@"hideSubheaderBar", @"disableSubheaderBar",
                             @"setSubheaderHeightToZero",
                             @"resetScrollViewInsetOffset"]) {
        SEL selector = NSSelectorFromString(name);
        if ([receiver respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, selector);
        }
    }
    SEL enabled = NSSelectorFromString(@"setSubheaderBarEnabled:");
    if ([receiver respondsToSelector:enabled]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(receiver, enabled, NO);
    }
}

static double YTzoomMaximumSubheaderHeightGetter(id receiver, SEL selector) {
    if (YTzoomHideTopics()) return 0.0;
    return OriginalMaximumSubheaderHeightGetter == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalMaximumSubheaderHeightGetter)(
            receiver, selector);
}

static double YTzoomSubheaderDefaultHeight(id receiver, SEL selector) {
    if (YTzoomHideTopics()) return 0.0;
    return OriginalSubheaderDefaultHeight == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalSubheaderDefaultHeight)(
            receiver, selector);
}

static void YTzoomPaidContentLayout(UIView *receiver, SEL selector) {
    if (OriginalPaidContentLayout != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentLayout)(receiver, selector);
    }
    BOOL hide = YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden");
    NSNumber *baseline = objc_getAssociatedObject(
        receiver, YTzoomContentHiddenAssociation);
    if (hide) {
        if (baseline == nil) {
            objc_setAssociatedObject(receiver,
                                     YTzoomContentHiddenAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        receiver.hidden = YES;
        receiver.userInteractionEnabled = NO;
    } else if (baseline != nil) {
        receiver.hidden = NO;
        receiver.userInteractionEnabled = YES;
        objc_setAssociatedObject(receiver,
                                 YTzoomContentHiddenAssociation,
                                 nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void YTzoomPaidContentDidAppear(UIViewController *receiver,
                                       SEL selector,
                                       BOOL animated) {
    if (OriginalPaidContentDidAppear != NULL) {
        ((void (*)(id, SEL, BOOL))OriginalPaidContentDidAppear)(
            receiver, selector, animated);
    }
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden")) return;
    receiver.view.hidden = YES;
    receiver.view.userInteractionEnabled = NO;
    for (NSString *name in @[@"hidePaidContent",
                             @"removePaidContentViewController"]) {
        SEL action = NSSelectorFromString(name);
        if ([receiver respondsToSelector:action]) {
            ((void (*)(id, SEL))objc_msgSend)(receiver, action);
        }
    }
}

static void YTzoomPaidContentPlaybackStarted(id receiver, SEL selector) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        OriginalPaidContentPlaybackStarted != NULL) {
        ((void (*)(id, SEL))OriginalPaidContentPlaybackStarted)(receiver, selector);
    }
}

static void YTzoomSetPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        OriginalSetPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTzoomSetPaidContentRenderer(id receiver, SEL selector, id renderer) {
    if (OriginalSetPaidContentRenderer != NULL) {
        ((void (*)(id, SEL, id))OriginalSetPaidContentRenderer)(
            receiver, selector,
            YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") ? nil : renderer);
    }
}

static BOOL YTzoomHasPaidContentOverlay(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden")) return NO;
    return OriginalHasPaidContentOverlay != NULL &&
        ((BOOL (*)(id, SEL))OriginalHasPaidContentOverlay)(receiver, selector);
}

static id YTzoomPaidContentOverlay(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden")) return nil;
    return OriginalPaidContentOverlay == NULL ? nil :
        ((id (*)(id, SEL))OriginalPaidContentOverlay)(receiver, selector);
}

static void YTzoomOverlayPaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        OriginalOverlayPaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalOverlayPaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTzoomInlinePaidContentPlayerData(id receiver, SEL selector, id data) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        OriginalInlinePaidContentPlayerData != NULL) {
        ((void (*)(id, SEL, id))OriginalInlinePaidContentPlayerData)(
            receiver, selector, data);
    }
}

static void YTzoomDidInsertPlayerOverlay(id receiver, SEL selector,
                                         id provider, id overlay) {
    NSString *identifier = YTzoomContentValue(overlay, @"overlayIdentifier");
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.PaidPromotionHidden") &&
        [identifier isEqualToString:@"player_overlay_paid_content"]) {
        return;
    }
    if (YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.ProductsHidden") &&
        [identifier isEqualToString:@"player_overlay_product_in_video"]) {
        return;
    }
    if (OriginalDidInsertPlayerOverlay != NULL) {
        ((void (*)(id, SEL, id, id))OriginalDidInsertPlayerOverlay)(
            receiver, selector, provider, overlay);
    }
}

static void YTzoomEnableSubheaderBar(__unsafe_unretained id receiver, SEL selector,
                                     __unsafe_unretained id view) {
    BOOL hide = YTzoomHideTopics();
    if (hide) {
        YTzoomCollapseSubheader(receiver);
        return;
    }
    if (OriginalEnableSubheaderBar != NULL) {
        ((void (*)(id, SEL, id))OriginalEnableSubheaderBar)(receiver, selector, view);
    }
}

static void YTzoomChipBarUpdate(__unsafe_unretained id receiver, SEL selector,
                                __unsafe_unretained id collectionViewController,
                                __unsafe_unretained id host,
                                __unsafe_unretained id renderer,
                                __unsafe_unretained id browseIdentifier,
                                __unsafe_unretained id sectionList) {
    BOOL hide = YTzoomHideTopics();
    if (hide) return;
    if (OriginalChipBarUpdate != NULL) {
        ((void (*)(id, SEL, id, id, id, id, id))OriginalChipBarUpdate)(
            receiver, selector, collectionViewController, host, renderer,
            browseIdentifier, sectionList);
    }
}

static void YTzoomChipCloudSetEntry(__unsafe_unretained id receiver, SEL selector,
                                    __unsafe_unretained id entry) {
    if (OriginalChipCloudSetEntry != NULL) {
        ((void (*)(id, SEL, id))OriginalChipCloudSetEntry)(receiver, selector, entry);
    }
    BOOL hide = YTzoomHideTopics();
    if (!hide) return;
    if ([receiver isKindOfClass:UIView.class]) {
        UIView *cell = (UIView *)receiver;
        cell.hidden = YES;
        cell.userInteractionEnabled = NO;
    }
}

static void YTzoomChipCloudLayout(__unsafe_unretained id receiver, SEL selector) {
    if (OriginalChipCloudLayout != NULL) {
        ((void (*)(id, SEL))OriginalChipCloudLayout)(receiver, selector);
    }
    BOOL hide = YTzoomHideTopics();
    if (!hide) return;
    if (![receiver isKindOfClass:UIView.class]) return;
    UIView *cell = (UIView *)receiver;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    CGRect frame = cell.frame;
    if (frame.size.height != 0.0) {
        frame.size.height = 0.0;
        cell.frame = frame;
    }
    for (UIView *subview in cell.subviews) {
        subview.hidden = YES;
    }
}

static void YTzoomFeedHeaderScrollMode(__unsafe_unretained id receiver, SEL selector,
                                       int mode) {
    if (OriginalFeedHeaderScrollMode != NULL) {
        ((void (*)(id, SEL, int))OriginalFeedHeaderScrollMode)(
            receiver, selector, YTzoomHideTopics() ? 0 : mode);
    }
}

static IMP OriginalChipViewFrames;

static id YTzoomChipViewFrames(__unsafe_unretained id receiver, SEL selector, double width) {
    if (YTzoomHideTopics()) return nil;
    return OriginalChipViewFrames == NULL ? nil
        : ((id (*)(id, SEL, double))OriginalChipViewFrames)(receiver, selector, width);
}

static void YTzoomSubsSetChipFilterView(__unsafe_unretained id receiver, SEL selector,
                                        __unsafe_unretained id view) {
    BOOL hide = YTzoomHideTopics();
    if (hide) return;
    if (OriginalSubsSetChipFilterView != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsSetChipFilterView)(receiver, selector, view);
    }
}

static void YTzoomSubsChipFilter(__unsafe_unretained id receiver, SEL selector,
                                 __unsafe_unretained id model) {
    BOOL hide = YTzoomHideTopics();
    if (hide) return;
    if (OriginalSubsChipFilter != NULL) {
        ((void (*)(id, SEL, id))OriginalSubsChipFilter)(receiver, selector, model);
    }
}

static void YTzoomMaximumSubheaderHeight(__unsafe_unretained id receiver,
                                        SEL selector, double height) {
    BOOL hide = YTzoomHideTopics();
    if (hide) height = 0.0;
    if (OriginalMaximumSubheaderHeight != NULL) {
        ((void (*)(id, SEL, double))OriginalMaximumSubheaderHeight)(
            receiver, selector, height);
    }
}

static void YTzoomSetHeaderHeights(id receiver, SEL selector,
                                    double headerHeight,
                                    double subheaderHeight,
                                    double topOffset,
                                    BOOL animated) {
    if (YTzoomHideTopics()) {
        subheaderHeight = 0.0;
    }
    if (OriginalSetHeaderHeights != NULL) {
        ((void (*)(id, SEL, double, double, double, BOOL))OriginalSetHeaderHeights)(
            receiver, selector, headerHeight, subheaderHeight, topOffset, animated);
    }
}

static BOOL YTzoomShouldHideSubheader(id receiver, SEL selector) {
    if (YTzoomHideTopics()) return YES;
    return OriginalShouldHideSubheader != NULL &&
        ((BOOL (*)(id, SEL))OriginalShouldHideSubheader)(receiver, selector);
}

static void YTzoomAddSections(id receiver, SEL selector, NSArray *sections) {
    if (OriginalAddSections != NULL) {
        YTzoomEnsureStructuralActionHook();
        NSArray *filtered = YTzoomFilteredFeedSections(receiver, sections);
        ((void (*)(id, SEL, id))OriginalAddSections)(
            receiver, selector, filtered);
    }
}

static IMP OriginalSetupSectionList;

static BOOL YTzoomIsGuidelinesSection(id section) {
    NSData *pattern = [@"community_guidelines.eml" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *bytes = YTzoomSectionBytes(section) ?: YTzoomDescendantBytes(section);
    if (bytes.length == 0 ||
        [bytes rangeOfData:pattern options:0
                     range:NSMakeRange(0, bytes.length)].location == NSNotFound) {
        return NO;
    }
    id itemSection = YTzoomFastChildSel(section, YTzoomSelItemSectionRenderer) ?: section;
    return YTzoomFastContents(itemSection).count <= 1;
}

static void YTzoomStripGuidelinesSections(id model) {
    if (!YTzoomFeatureEnabled(@"YTzoom.Preference.Overlay.CommentGuidelinesHidden")) {
        return;
    }
    NSArray *sections = YTzoomFastContents(model);
    if (![sections isKindOfClass:NSMutableArray.class] || sections.count == 0) return;
    NSIndexSet *drop = [sections indexesOfObjectsPassingTest:
        ^BOOL(id section, __unused NSUInteger index, __unused BOOL *stop) {
        return YTzoomIsGuidelinesSection(section);
    }];
    if (drop.count == 0) return;
    [(NSMutableArray *)sections removeObjectsAtIndexes:drop];
}

static void YTzoomSetupSectionList(id receiver, SEL selector, id model, BOOL loadingMore,
                                   BOOL refreshing, BOOL preserveHeader) {
    YTzoomStripGuidelinesSections(model);
    if (OriginalSetupSectionList != NULL) {
        ((void (*)(id, SEL, id, BOOL, BOOL, BOOL))OriginalSetupSectionList)(
            receiver, selector, model, loadingMore, refreshing, preserveHeader);
    }
}

void YTzoomInstallContentVisibilityHooks(void) {
    YTzoomInstallInstanceHook(
        @"YTAppCollectionViewController",
        @"setupSectionListWithModel:isLoadingMore:isRefreshingFromContinuation:"
         "shouldPreserveHeaderOnRefresh:",
        (IMP)YTzoomSetupSectionList, &OriginalSetupSectionList);
    __unused NSArray<NSNumber *> *actionHooks = @[
        @(YTzoomInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)YTzoomScrollableActionButtonsArray,
                                    &OriginalScrollableActionButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)YTzoomScrollableActionBarButtonsArray,
                                    &OriginalScrollableActionBarButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)YTzoomScrollableButtonsArray,
                                    &OriginalScrollableButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoScrollableActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)YTzoomScrollableActionsArray,
                                    &OriginalScrollableActionsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionButtonsArray",
                                    (IMP)YTzoomActionButtonsArray,
                                    &OriginalActionButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionBarButtonsArray",
                                    (IMP)YTzoomActionBarButtonsArray,
                                    &OriginalActionBarButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"buttonsArray",
                                    (IMP)YTzoomButtonsArray,
                                    &OriginalButtonsArray)),
        @(YTzoomInstallInstanceHook(@"YTISlimVideoActionBarRenderer",
                                    @"actionsArray",
                                    (IMP)YTzoomActionsArray,
                                    &OriginalActionsArray))
    ];
    YTzoomInstallInstanceHook(@"YTSlimVideoDetailsActionView",
                              @"didMoveToWindow",
                              (IMP)YTzoomActionViewDidMove,
                              &OriginalActionViewDidMove);
    YTzoomEnsureStructuralActionHook();
    YTzoomEnsureActionCellControllerHooks();
    YTzoomEnsureActionCollectionLayoutHook();
    YTzoomScheduleStructuralActionHook();
    YTzoomInstallInstanceHook(@"YTSlimVideoScrollableDetailsActionsView",
                              @"didMoveToWindow",
                              (IMP)YTzoomActionsViewDidMove,
                              &OriginalActionsViewDidMove);
    YTzoomInstallInstanceHook(@"YTSlimVideoScrollableActionBarCell",
                              @"didMoveToWindow",
                              (IMP)YTzoomActionCellDidMove,
                              &OriginalActionCellDidMove);
    YTzoomInstallInstanceHook(@"_ASDisplayView",
                              @"didMoveToWindow",
                              (IMP)YTzoomDisplayViewDidMove,
                              &OriginalDisplayViewDidMove);
    YTzoomInstallInstanceHook(@"_ASDisplayView",
                              @"setAccessibilityIdentifier:",
                              (IMP)YTzoomDisplayViewSetIdentifier,
                              &OriginalDisplayViewSetIdentifier);
    YTzoomInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"addSectionsFromArray:",
                              (IMP)YTzoomAddSections,
                              &OriginalAddSections);
    YTzoomInstallInstanceHook(@"YTInnerTubeCollectionViewController",
                              @"sectionControllersForSectionRenderers:reloadingSectionControllerByRenderer:",
                              (IMP)YTzoomSectionControllers,
                              &OriginalSectionControllers);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"enableSubheaderBarWithView:",
                              (IMP)YTzoomEnableSubheaderBar,
                              &OriginalEnableSubheaderBar);
    YTzoomInstallInstanceHook(@"YTFeedFilterChipBarController",
                              @"updateWithCollectionViewController:feedFilterChipBarHost:feedFilterChipBarRenderer:browseIdentifier:sectionList:",
                              (IMP)YTzoomChipBarUpdate,
                              &OriginalChipBarUpdate);
    YTzoomInstallInstanceHook(@"YTChipCloudCell",
                              @"setEntry:",
                              (IMP)YTzoomChipCloudSetEntry,
                              &OriginalChipCloudSetEntry);
    YTzoomInstallInstanceHook(@"YTMySubsFilterHeaderViewController",
                              @"loadChipFilterFromModel:",
                              (IMP)YTzoomSubsChipFilter,
                              &OriginalSubsChipFilter);
    YTzoomInstallInstanceHook(@"YTChipCloudCell",
                              @"layoutSubviews",
                              (IMP)YTzoomChipCloudLayout,
                              &OriginalChipCloudLayout);
    YTzoomInstallInstanceHook(@"YTChipCloudCell",
                              @"framesForChipViewsWithWidth:",
                              (IMP)YTzoomChipViewFrames,
                              &OriginalChipViewFrames);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setFeedHeaderScrollMode:",
                              (IMP)YTzoomFeedHeaderScrollMode,
                              &OriginalFeedHeaderScrollMode);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setMaximumSubheaderHeight:",
                              (IMP)YTzoomMaximumSubheaderHeight,
                              &OriginalMaximumSubheaderHeight);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"maximumSubheaderHeight",
                              (IMP)YTzoomMaximumSubheaderHeightGetter,
                              &OriginalMaximumSubheaderHeightGetter);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"subheaderDefaultHeight",
                              (IMP)YTzoomSubheaderDefaultHeight,
                              &OriginalSubheaderDefaultHeight);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"setHeaderHeight:subheaderHeight:topOffset:animated:",
                              (IMP)YTzoomSetHeaderHeights,
                              &OriginalSetHeaderHeights);
    YTzoomInstallInstanceHook(@"YTHeaderContentComboView",
                              @"shouldHideSubHeader",
                              (IMP)YTzoomShouldHideSubheader,
                              &OriginalShouldHideSubheader);
    YTzoomInstallInstanceHook(@"YTMySubsFilterHeaderView",
                              @"setChipFilterView:",
                              (IMP)YTzoomSubsSetChipFilterView,
                              &OriginalSubsSetChipFilterView);
    YTzoomInstallInstanceHook(@"YTPaidContentOverlayView",
                              @"layoutSubviews",
                              (IMP)YTzoomPaidContentLayout,
                              &OriginalPaidContentLayout);
    YTzoomInstallInstanceHook(@"YTPaidContentViewController",
                              @"viewDidAppear:",
                              (IMP)YTzoomPaidContentDidAppear,
                              &OriginalPaidContentDidAppear);
    YTzoomInstallInstanceHook(@"YTPaidContentController",
                              @"playbackDidStart",
                              (IMP)YTzoomPaidContentPlaybackStarted,
                              &OriginalPaidContentPlaybackStarted);
    YTzoomInstallInstanceHook(@"YTPaidContentController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTzoomSetPaidContentPlayerData,
                              &OriginalSetPaidContentPlayerData);
    YTzoomInstallInstanceHook(@"YTPaidContentViewController",
                              @"setPaidContentRenderer:",
                              (IMP)YTzoomSetPaidContentRenderer,
                              &OriginalSetPaidContentRenderer);
    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"hasPaidContentOverlay",
                              (IMP)YTzoomHasPaidContentOverlay,
                              &OriginalHasPaidContentOverlay);
    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"paidContentOverlay",
                              (IMP)YTzoomPaidContentOverlay,
                              &OriginalPaidContentOverlay);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTzoomOverlayPaidContentPlayerData,
                              &OriginalOverlayPaidContentPlayerData);
    YTzoomInstallInstanceHook(@"YTInlineMutedPlaybackPlayerOverlayViewController",
                              @"setPaidContentWithPlayerData:",
                              (IMP)YTzoomInlinePaidContentPlayerData,
                              &OriginalInlinePaidContentPlayerData);
    YTzoomInstallInstanceHook(@"YTMainAppVideoPlayerOverlayViewController",
                              @"playerOverlayProvider:didInsertPlayerOverlay:",
                              (IMP)YTzoomDidInsertPlayerOverlay,
                              &OriginalDidInsertPlayerOverlay);
}
