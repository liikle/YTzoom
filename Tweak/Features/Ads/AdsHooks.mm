#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static IMP OriginalShouldBlockUpgradeDialog;
static IMP OriginalAdShieldSignals;
static IMP OriginalAdShieldSignalsWithoutIDFA;
static IMP OriginalDataSignals;
static IMP OriginalDataSignalsWithoutIDFA;
static IMP OriginalAdsDecorateContext;
static IMP OriginalAccountAdsDecorateContext;
static IMP OriginalPlayerAdsArray;
static IMP OriginalAdSlotsArray;
static IMP OriginalAdPlacementsArray;
static IMP OriginalAdBreakParams;
static IMP OriginalAdNextParams;
static IMP OriginalAdParams;
static IMP OriginalEnableSkippableAd;
static IMP OriginalMDXSessionImplAdPlaying;
static IMP OriginalMDXSessionAdPlaying;
static IMP OriginalIsPlayingAd;
static IMP OriginalIsPlayingAdSurvey;
static IMP OriginalIsPlayingAdIntro;
static IMP OriginalCreateAdsPlaybackCoordinator;
static IMP OriginalReelContentModel;
static IMP OriginalInfiniteReelContentModel;
static IMP OriginalReelShouldDisplay;
static IMP OriginalCompanionAd;
static IMP OriginalHasCompanionAdRenderer;
static IMP OriginalHasAppPromoCompanionAdRenderer;
static IMP OriginalHasShoppingCompanionAdRenderer;
static IMP OriginalElementContentsArray;
static IMP OriginalItemSectionContentsArray;
static IMP OriginalAdCellLayout;
static IMP OriginalAdCellReuse;
static NSMutableDictionary<NSString *, NSValue *> *YTzoomPromotedSizeOriginals;
static IMP OriginalVideoNodeSetEntry;
static IMP OriginalVideoNodeHeight;
static IMP OriginalVideoNodeSize;
static IMP OriginalVideoNodeShrink;
static const void *YTzoomAdNodeAssociation = &YTzoomAdNodeAssociation;
static const void *YTzoomAdMatchAssociation = &YTzoomAdMatchAssociation;
static const void *YTzoomAdEmptyAssociation = &YTzoomAdEmptyAssociation;

static id YTzoomCallObjectGetter(IMP implementation, id receiver, SEL selector) {
    return implementation == NULL
        ? nil
        : ((id (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL YTzoomCallBooleanGetter(IMP implementation, id receiver, SEL selector) {
    return implementation != NULL &&
        ((BOOL (*)(id, SEL))implementation)(receiver, selector);
}

static BOOL YTzoomShouldBlockUpgradeDialog(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? YES
        : YTzoomCallBooleanGetter(OriginalShouldBlockUpgradeDialog, receiver, selector);
}

static id YTzoomEmptyDictionary(IMP original, id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? @{}
        : YTzoomCallObjectGetter(original, receiver, selector);
}

static id YTzoomAdShieldSignals(id receiver, SEL selector) {
    return YTzoomEmptyDictionary(OriginalAdShieldSignals, receiver, selector);
}

static id YTzoomAdShieldSignalsWithoutIDFA(id receiver, SEL selector) {
    return YTzoomEmptyDictionary(OriginalAdShieldSignalsWithoutIDFA, receiver, selector);
}

static id YTzoomDataSignals(id receiver, SEL selector) {
    return YTzoomEmptyDictionary(OriginalDataSignals, receiver, selector);
}

static id YTzoomDataSignalsWithoutIDFA(id receiver, SEL selector) {
    return YTzoomEmptyDictionary(OriginalDataSignalsWithoutIDFA, receiver, selector);
}

static void YTzoomAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) && OriginalAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAdsDecorateContext)(receiver, selector, context);
    }
}

static void YTzoomAccountAdsDecorateContext(id receiver, SEL selector, id context) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) &&
        OriginalAccountAdsDecorateContext != NULL) {
        ((void (*)(id, SEL, id))OriginalAccountAdsDecorateContext)(
            receiver,
            selector,
            context
        );
    }
}

static id YTzoomPlayerAdsArray(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? [NSMutableArray array]
        : YTzoomCallObjectGetter(OriginalPlayerAdsArray, receiver, selector);
}

static id YTzoomAdSlotsArray(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? [NSMutableArray array]
        : YTzoomCallObjectGetter(OriginalAdSlotsArray, receiver, selector);
}

static id YTzoomAdPlacementsArray(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? [NSMutableArray array]
        : YTzoomCallObjectGetter(OriginalAdPlacementsArray, receiver, selector);
}

static id YTzoomNilParameter(IMP original, id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? nil
        : YTzoomCallObjectGetter(original, receiver, selector);
}

static id YTzoomAdBreakParams(id receiver, SEL selector) {
    return YTzoomNilParameter(OriginalAdBreakParams, receiver, selector);
}

static id YTzoomAdNextParams(id receiver, SEL selector) {
    return YTzoomNilParameter(OriginalAdNextParams, receiver, selector);
}

static id YTzoomAdParams(id receiver, SEL selector) {
    return YTzoomNilParameter(OriginalAdParams, receiver, selector);
}

static BOOL YTzoomEnableSkippableAd(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? YES
        : YTzoomCallBooleanGetter(OriginalEnableSkippableAd, receiver, selector);
}

static void YTzoomMDXSessionImplAdPlaying(id receiver,
                                          SEL selector,
                                          uintptr_t value) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) &&
        OriginalMDXSessionImplAdPlaying != NULL) {
        ((void (*)(id, SEL, uintptr_t))OriginalMDXSessionImplAdPlaying)(
            receiver,
            selector,
            value
        );
    }
}

static void YTzoomMDXSessionAdPlaying(id receiver,
                                      SEL selector,
                                      uintptr_t value) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) && OriginalMDXSessionAdPlaying != NULL) {
        ((void (*)(id, SEL, uintptr_t))OriginalMDXSessionAdPlaying)(
            receiver,
            selector,
            value
        );
    }
}

static BOOL YTzoomNotPlayingAd(IMP original, id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? NO
        : YTzoomCallBooleanGetter(original, receiver, selector);
}

static BOOL YTzoomIsPlayingAd(id receiver, SEL selector) {
    return YTzoomNotPlayingAd(OriginalIsPlayingAd, receiver, selector);
}

static BOOL YTzoomIsPlayingAdSurvey(id receiver, SEL selector) {
    return YTzoomNotPlayingAd(OriginalIsPlayingAdSurvey, receiver, selector);
}

static BOOL YTzoomIsPlayingAdIntro(id receiver, SEL selector) {
    return YTzoomNotPlayingAd(OriginalIsPlayingAdIntro, receiver, selector);
}

static id YTzoomNoAdsPlaybackCoordinator(id receiver, SEL selector) {
    id coordinator = YTzoomCallObjectGetter(
        OriginalCreateAdsPlaybackCoordinator,
        receiver,
        selector
    );
    return YTzoomFeatureEnabled(YTzoomNoAdsKey) ? nil : coordinator;
}

static id YTzoomFilterReelModel(IMP original,
                                id receiver,
                                SEL selector,
                                id entry) {
    if (original == NULL) {
        return nil;
    }
    id model = ((id (*)(id, SEL, id))original)(receiver, selector, entry);
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) || model == nil) {
        return model;
    }
    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    if (![model respondsToSelector:videoTypeSelector]) {
        return model;
    }
    NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
        model,
        videoTypeSelector
    );
    return videoType == 3 ? nil : model;
}

static id YTzoomReelContentModel(id receiver, SEL selector, id entry) {
    return YTzoomFilterReelModel(
        OriginalReelContentModel,
        receiver,
        selector,
        entry
    );
}

static id YTzoomInfiniteReelContentModel(id receiver, SEL selector, id entry) {
    return YTzoomFilterReelModel(
        OriginalInfiniteReelContentModel,
        receiver,
        selector,
        entry
    );
}

static id YTzoomObjectValue(id object, NSString *selectorName) {
    if (object == nil) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL YTzoomObjectBool(id object, NSString *selectorName) {
    if (object == nil) return NO;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL YTzoomReelObjectLooksLikeAd(id object, NSUInteger depth) {
    if (object == nil || depth > 3) return NO;

    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"nonvideoad"] ||
        [className containsString:@"reelad"] ||
        [className containsString:@"adselection"] ||
        [className containsString:@"miniappad"]) {
        return YES;
    }

    for (NSString *selectorName in @[
        @"isAd", @"isAdVideo", @"isVideoAd", @"hasAdLoggingData"
    ]) {
        if (YTzoomObjectBool(object, selectorName)) return YES;
    }

    SEL videoTypeSelector = NSSelectorFromString(@"videoType");
    if ([object respondsToSelector:videoTypeSelector]) {
        NSInteger videoType = ((NSInteger (*)(id, SEL))objc_msgSend)(
            object,
            videoTypeSelector
        );
        if (videoType == 3) return YES;
    }

    for (NSString *selectorName in @[
        @"adLoggingData",
        @"adSlotRenderer",
        @"reelNonVideoAdRenderer",
        @"nonVideoAdRenderer",
        @"sequenceItemAdSelectionRenderer"
    ]) {
        if (YTzoomObjectValue(object, selectorName) != nil) return YES;
    }

    for (NSString *selectorName in @[
        @"reelModel", @"command", @"watchModel", @"parentWatchModel"
    ]) {
        id child = YTzoomObjectValue(object, selectorName);
        if (child != object && YTzoomReelObjectLooksLikeAd(child, depth + 1)) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTzoomReelShouldDisplay(id receiver, SEL selector) {
    BOOL shouldDisplay = OriginalReelShouldDisplay == NULL ||
        ((BOOL (*)(id, SEL))OriginalReelShouldDisplay)(receiver, selector);
    if (!shouldDisplay || !YTzoomFeatureEnabled(YTzoomNoAdsKey)) {
        return shouldDisplay;
    }
    if (YTzoomObjectValue(receiver, @"nonVideoContentModel") != nil) {
        return NO;
    }
    return !YTzoomReelObjectLooksLikeAd(receiver, 0);
}

static BOOL YTzoomIsAdLayoutIdentifier(NSString *identifier) {
    if (identifier.length == 0) return NO;
    NSString *normalized = [[identifier lowercaseString]
        stringByReplacingOccurrencesOfString:@"." withString:@"_"];
    normalized = [normalized stringByReplacingOccurrencesOfString:@"-"
                                                        withString:@"_"];
    return [normalized hasPrefix:@"eml_ad_"];
}

static BOOL YTzoomObjectLooksLikeAd(id object) {
    if (object == nil) return NO;
    if ([objc_getAssociatedObject(object, YTzoomAdMatchAssociation) boolValue]) {
        return YES;
    }
    BOOL matched = NO;
    NSString *className = NSStringFromClass([object class]).lowercaseString;
    if ([className containsString:@"adrenderer"] ||
        ([className containsString:@"promoted"] &&
         [className containsString:@"renderer"]) ||
        [className containsString:@"promorenderer"] ||
        [className containsString:@"adslotrenderer"] ||
        [className containsString:@"companionadrenderer"] ||
        [className containsString:@"shoppingadinfocardcontentrenderer"] ||
        [className containsString:@"infeedad"] ||
        [className containsString:@"displayad"]) {
        matched = YES;
    }
    for (NSString *selectorName in @[@"isAdRenderer", @"isAd",
                                      @"hasAdLoggingData",
                                      @"hasAdBadgeRenderer",
                                      @"hasNativeAdBadgeRenderer",
                                      @"hasSimpleAdBadgeRenderer",
                                      @"hasAdSlotRenderer",
                                      @"hasCompanionAdRenderer",
                                      @"hasCompactCompanionAdRenderer",
                                      @"hasMultiItemCompanionAdRenderer",
                                      @"hasAppPromoCompanionAdRenderer",
                                      @"hasShoppingCompanionAdRenderer",
                                      @"hasSuggestedVideosCompanionAdRenderer",
                                      @"hasCompactPromotedBannerRenderer",
                                      @"hasCompactPromotedItemRenderer",
                                      @"hasCompactPromotedVideoRenderer",
                                      @"hasGridPromotedBannerRenderer",
                                      @"hasGridPromotedVideoRenderer",
                                      @"hasPromoted15ClickPtTextCtdWatchRenderer",
                                      @"hasPromoted15ClickPtTextWatchRenderer",
                                      @"hasPromoted15ClickTextCtdWatchRenderer",
                                      @"hasPromoted15ClickTextWatchRenderer",
                                      @"hasPromotedAppInstallRenderer",
                                      @"hasPromotedDiscoveryAppPromoCompactFormRenderer",
                                      @"hasPromotedSparklesTextCtdHomeCompactFormRenderer",
                                      @"hasPromotedSparklesTextCtdHomeRenderer",
                                      @"hasPromotedSparklesTextCtdWatch15ClickRenderer",
                                      @"hasPromotedSparklesTextCtdWatchGridFormRenderer",
                                      @"hasPromotedSparklesTextCtdWatchWideFormRenderer",
                                      @"hasPromotedSparklesTextHomeRenderer",
                                      @"hasPromotedSparklesTextProductHomeRenderer",
                                      @"hasPromotedSparklesTextProductWatchRenderer",
                                      @"hasPromotedSparklesTextSearchRenderer",
                                      @"hasPromotedSparklesTextWatch15ClickRenderer",
                                      @"hasPromotedSparklesTextWatchGridFormRenderer",
                                      @"hasPromotedSparklesTextWatchWideFormRenderer",
                                      @"hasPromotedTextBannerRenderer",
                                      @"hasPromotedVideoInlineMutedRenderer",
                                      @"hasPromotedVideoRenderer",
                                      @"hasShoppingAdInfoCardContentRenderer"]) {
        if (matched) break;
        SEL selector = NSSelectorFromString(selectorName);
        if ([object respondsToSelector:selector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(object, selector)) {
            matched = YES;
        }
    }
    if (!matched && YTzoomObjectValue(object, @"adLoggingData") != nil) {
        matched = YES;
    }
    for (NSString *selectorName in @[
        @"adBadgeRenderer", @"nativeAdBadgeRenderer",
        @"simpleAdBadgeRenderer"
    ]) {
        if (matched) break;
        id value = YTzoomObjectValue(object, selectorName);
        if (value != nil) {
            matched = YES;
        }
    }
    for (NSString *selectorName in @[
        @"identifier", @"layoutIdentifier", @"elementIdentifier",
        @"accessibilityIdentifier", @"templateIdentifier"
    ]) {
        if (matched) break;
        id value = YTzoomObjectValue(object, selectorName);
        if ([value isKindOfClass:NSString.class] &&
            YTzoomIsAdLayoutIdentifier(value)) {
            matched = YES;
        }
    }
    if (!matched) {
        id options = YTzoomObjectValue(object, @"compatibilityOptions");
        SEL loggingSelector = NSSelectorFromString(@"hasAdLoggingData");
        matched = [options respondsToSelector:loggingSelector] &&
            ((BOOL (*)(id, SEL))objc_msgSend)(options, loggingSelector);
    }
    if (matched) {
        objc_setAssociatedObject(object, YTzoomAdMatchAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return matched;
}

static const void *YTzoomAdCellAssociation = &YTzoomAdCellAssociation;

typedef struct {
    NSUInteger unit;
    CGFloat value;
} YTzoomASDimension;

static void YTzoomCollapseCellNode(id node) {
    SEL styleSelector = NSSelectorFromString(@"style");
    if ([node respondsToSelector:styleSelector]) {
        id style = ((id (*)(id, SEL))objc_msgSend)(node, styleSelector);
        YTzoomASDimension zero = {1, 0.0};
        for (NSString *name in @[@"setHeight:", @"setMaxHeight:"]) {
            SEL selector = NSSelectorFromString(name);
            if (![style respondsToSelector:selector]) continue;
            ((void (*)(id, SEL, YTzoomASDimension))objc_msgSend)(
                style, selector, zero);
        }
    }
    for (NSString *name in @[@"invalidateCalculatedLayout", @"setNeedsLayout"]) {
        SEL selector = NSSelectorFromString(name);
        if ([node respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(node, selector);
        }
    }
}

static void YTzoomCollapseAdCell(UIView *cell) {
    CGRect frame = cell.frame;
    if (frame.size.height == 0.0 && cell.hidden) return;
    frame.size.height = 0.0;
    cell.frame = frame;
    cell.hidden = YES;
    cell.userInteractionEnabled = NO;
    for (UIView *ancestor = cell.superview; ancestor != nil;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionView.class]) {
            [((UICollectionView *)ancestor).collectionViewLayout invalidateLayout];
            break;
        }
    }
}

void YTzoomHandleAdCellLayout(UIView *cell) {
    if (![objc_getAssociatedObject(cell, YTzoomAdCellAssociation) boolValue]) return;
    YTzoomCollapseAdCell(cell);
}

void YTzoomHandleAdCellReuse(UIView *cell) {
    if (![objc_getAssociatedObject(cell, YTzoomAdCellAssociation) boolValue]) return;
    objc_setAssociatedObject(cell, YTzoomAdCellAssociation, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    cell.hidden = NO;
    cell.userInteractionEnabled = YES;
}

void YTzoomCollapseHostCell(UIView *view) {
    if (view == nil) return;
    UIView *cell = nil;
    for (UIView *ancestor = view; ancestor != nil;
         ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionViewCell.class] ||
            [NSStringFromClass([ancestor class]) hasSuffix:@"CollectionViewCell"]) {
            cell = ancestor;
            break;
        }
    }
    view.hidden = YES;
    if (cell == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        return;
    }
    objc_setAssociatedObject(cell, YTzoomAdCellAssociation, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTzoomCollapseAdCell(cell);
    SEL nodeSelector = NSSelectorFromString(@"node");
    if ([cell respondsToSelector:nodeSelector]) {
        id node = ((id (*)(id, SEL))objc_msgSend)(cell, nodeSelector);
        if (node != nil) {
            objc_setAssociatedObject(node, YTzoomAdNodeAssociation, @YES,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            YTzoomCollapseCellNode(node);
        }
    }
}

void YTzoomHandleAdDisplayView(UIView *view) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) || view.window == nil) return;
    if (!YTzoomIsAdLayoutIdentifier(view.accessibilityIdentifier)) return;
    YTzoomCollapseHostCell(view);
}

static id YTzoomElementRenderer(id object) {
    SEL selector = NSSelectorFromString(@"elementRenderer");
    return [object respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(object, selector)
        : nil;
}

static NSArray *YTzoomFilterAdContents(NSArray *contents, id owner) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) ||
        ![contents isKindOfClass:NSArray.class] || contents.count == 0) {
        return contents;
    }
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:contents.count];
    for (id content in contents) {
        id renderer = YTzoomElementRenderer(content);
        BOOL contentAd = YTzoomObjectLooksLikeAd(content);
        BOOL rendererAd = YTzoomObjectLooksLikeAd(renderer);
        if (!contentAd && !rendererAd) {
            [filtered addObject:content];
        }
    }
    NSUInteger removed = contents.count - filtered.count;
    if (removed == 0) return contents;
    if (filtered.count == 0 && owner != nil) {
        objc_setAssociatedObject(owner, YTzoomAdEmptyAssociation, @YES,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return filtered;
}

static NSArray *YTzoomElementContentsArray(id receiver, SEL selector) {
    NSArray *contents = OriginalElementContentsArray == NULL ? nil :
        ((id (*)(id, SEL))OriginalElementContentsArray)(receiver, selector);
    return YTzoomFilterAdContents(contents, receiver);
}

static NSArray *YTzoomItemSectionContentsArray(id receiver, SEL selector) {
    NSArray *contents = OriginalItemSectionContentsArray == NULL ? nil :
        ((id (*)(id, SEL))OriginalItemSectionContentsArray)(receiver, selector);
    return YTzoomFilterAdContents(contents, receiver);
}

NSArray *YTzoomFilterAdSections(NSArray *sections) {
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey) ||
        ![sections isKindOfClass:NSArray.class] || sections.count == 0) {
        return sections;
    }
    NSMutableArray *filtered = [NSMutableArray arrayWithCapacity:sections.count];
    for (id section in sections) {
        if (YTzoomObjectLooksLikeAd(section) ||
            YTzoomObjectLooksLikeAd(YTzoomElementRenderer(section))) {
            continue;
        }
        NSArray *contents = YTzoomObjectValue(section, @"contentsArray");
        if ([objc_getAssociatedObject(section, YTzoomAdEmptyAssociation) boolValue] ||
            ([contents isKindOfClass:NSArray.class] && contents.count != 0 &&
             YTzoomFilterAdContents(contents, section).count == 0)) {
            continue;
        }
        [filtered addObject:section];
    }
    return filtered.count == sections.count ? sections : filtered;
}

static id YTzoomNoCompanionAd(id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? nil
        : YTzoomCallObjectGetter(OriginalCompanionAd, receiver, selector);
}

static BOOL YTzoomNoCompanionFlag(IMP original, id receiver, SEL selector) {
    return YTzoomFeatureEnabled(YTzoomNoAdsKey)
        ? NO
        : YTzoomCallBooleanGetter(original, receiver, selector);
}

static BOOL YTzoomHasCompanionAdRenderer(id receiver, SEL selector) {
    return YTzoomNoCompanionFlag(
        OriginalHasCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL YTzoomHasAppPromoCompanionAdRenderer(id receiver, SEL selector) {
    return YTzoomNoCompanionFlag(
        OriginalHasAppPromoCompanionAdRenderer,
        receiver,
        selector
    );
}

static BOOL YTzoomHasShoppingCompanionAdRenderer(id receiver, SEL selector) {
    return YTzoomNoCompanionFlag(
        OriginalHasShoppingCompanionAdRenderer,
        receiver,
        selector
    );
}

static void YTzoomInstallObjectHookOrMethod(NSString *className,
                                            NSString *selectorName,
                                            IMP replacement,
                                            IMP *originalStorage) {
    if (!YTzoomInstallInstanceHook(
            className,
            selectorName,
            replacement,
            originalStorage
        )) {
        YTzoomAddInstanceMethod(className, selectorName, replacement, "@@:");
    }
}

static void YTzoomInstallBooleanHookOrMethod(NSString *className,
                                             NSString *selectorName,
                                             IMP replacement,
                                             IMP *originalStorage) {
    if (!YTzoomInstallInstanceHook(
            className,
            selectorName,
            replacement,
            originalStorage
        )) {
        YTzoomAddInstanceMethod(className, selectorName, replacement, "B@:");
    }
}

static void YTzoomAdCellLayoutSubviews(UIView *receiver, SEL selector) {
    if (OriginalAdCellLayout != NULL) {
        ((void (*)(id, SEL))OriginalAdCellLayout)(receiver, selector);
    }
    YTzoomHandleAdCellLayout(receiver);
}

static void YTzoomAdCellPrepareForReuse(UIView *receiver, SEL selector) {
    YTzoomHandleAdCellReuse(receiver);
    if (OriginalAdCellReuse != NULL) {
        ((void (*)(id, SEL))OriginalAdCellReuse)(receiver, selector);
    }
}

static IMP YTzoomPromotedSizeOriginal(id receiver, SEL selector) {
    NSString *key = [NSString stringWithFormat:@"%@|%@",
        NSStringFromClass([receiver class]), NSStringFromSelector(selector)];
    @synchronized (YTzoomPromotedSizeOriginals) {
        return (IMP)[YTzoomPromotedSizeOriginals[key] pointerValue];
    }
}

static CGSize YTzoomPromotedCellSize(id receiver, SEL selector, CGSize size) {
    IMP original = YTzoomPromotedSizeOriginal(receiver, selector);
    CGSize resolved = original == NULL
        ? size
        : ((CGSize (*)(id, SEL, CGSize))original)(receiver, selector, size);
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey)) return resolved;
    return CGSizeMake(resolved.width, 0.0);
}

static CGSize YTzoomPromotedCellSizeInsets(id receiver, SEL selector,
                                           CGSize size, UIEdgeInsets insets) {
    IMP original = YTzoomPromotedSizeOriginal(receiver, selector);
    CGSize resolved = original == NULL
        ? size
        : ((CGSize (*)(id, SEL, CGSize, UIEdgeInsets))original)(
            receiver, selector, size, insets);
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey)) return resolved;
    return CGSizeMake(resolved.width, 0.0);
}

static BOOL YTzoomShouldShowPromotedItems(id receiver, SEL selector) {
    if (YTzoomFeatureEnabled(YTzoomNoAdsKey)) return NO;
    IMP original = YTzoomPromotedSizeOriginal(receiver, selector);
    return original != NULL && ((BOOL (*)(id, SEL))original)(receiver, selector);
}

static void YTzoomInstallPromotedCellHooks(void) {
    YTzoomPromotedSizeOriginals = [NSMutableDictionary dictionary];
    NSArray<NSString *> *classes = @[@"YTCompactPromotedItemCellController",
                                     @"YTCompactPromotedVideoCellController",
                                     @"YTPromotedVideoCellController"];
    NSDictionary<NSString *, NSValue *> *replacements = @{
        @"cellSizeWithSize:": [NSValue valueWithPointer:(void *)YTzoomPromotedCellSize],
        @"cellSizeWithSize:safeAreaInsets:":
            [NSValue valueWithPointer:(void *)YTzoomPromotedCellSizeInsets],
        @"shouldShowPromotedItems":
            [NSValue valueWithPointer:(void *)YTzoomShouldShowPromotedItems]
    };
    for (NSString *className in classes) {
        for (NSString *selectorName in replacements) {
            IMP original = NULL;
            if (!YTzoomInstallInstanceHook(className, selectorName,
                    (IMP)replacements[selectorName].pointerValue, &original)) {
                continue;
            }
            NSString *key = [NSString stringWithFormat:@"%@|%@",
                className, selectorName];
            @synchronized (YTzoomPromotedSizeOriginals) {
                YTzoomPromotedSizeOriginals[key] =
                    [NSValue valueWithPointer:(void *)original];
            }
        }
    }
}

static BOOL YTzoomIsAdNode(id node) {
    return [objc_getAssociatedObject(node, YTzoomAdNodeAssociation) boolValue];
}

static void YTzoomVideoNodeSetEntry(id receiver, SEL selector, id entry) {
    if (OriginalVideoNodeSetEntry != NULL) {
        ((void (*)(id, SEL, id))OriginalVideoNodeSetEntry)(receiver, selector, entry);
    }
    if (!YTzoomFeatureEnabled(YTzoomNoAdsKey)) return;
    BOOL isAd = YTzoomObjectLooksLikeAd(entry) ||
        YTzoomObjectLooksLikeAd(YTzoomElementRenderer(entry));
    objc_setAssociatedObject(receiver, YTzoomAdNodeAssociation,
                             isAd ? @YES : nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!isAd) return;
    YTzoomCollapseCellNode(receiver);
    SEL overlay = NSSelectorFromString(@"dismissedCellOverlayView");
    SEL setOverlay = NSSelectorFromString(@"setDismissedCellOverlayView:");
    SEL resize = NSSelectorFromString(@"resizeDismissedView");
    if ([receiver respondsToSelector:overlay] &&
        [receiver respondsToSelector:setOverlay] &&
        ((id (*)(id, SEL))objc_msgSend)(receiver, overlay) == nil) {
        UIView *placeholder = [[UIView alloc] initWithFrame:CGRectZero];
        placeholder.hidden = YES;
        ((void (*)(id, SEL, id))objc_msgSend)(receiver, setOverlay, placeholder);
    }
    if (![receiver respondsToSelector:resize]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!YTzoomIsAdNode(receiver)) return;
        ((void (*)(id, SEL))objc_msgSend)(receiver, resize);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
        });
    });
}

static BOOL YTzoomVideoNodeShouldShrink(id receiver, SEL selector) {
    if (YTzoomIsAdNode(receiver)) {
        return YES;
    }
    return OriginalVideoNodeShrink != NULL &&
        ((BOOL (*)(id, SEL))OriginalVideoNodeShrink)(receiver, selector);
}

static double YTzoomVideoNodeHeight(id receiver, SEL selector) {
    double height = OriginalVideoNodeHeight == NULL
        ? 0.0
        : ((double (*)(id, SEL))OriginalVideoNodeHeight)(receiver, selector);
    if (!YTzoomIsAdNode(receiver)) return height;
    return 0.0;
}

static CGSize YTzoomVideoNodeSize(id receiver, SEL selector) {
    CGSize size = OriginalVideoNodeSize == NULL
        ? CGSizeZero
        : ((CGSize (*)(id, SEL))OriginalVideoNodeSize)(receiver, selector);
    if (!YTzoomIsAdNode(receiver)) return size;
    return CGSizeMake(size.width, 0.0);
}

void YTzoomInstallAdsHooks(void) {
    YTzoomInstallInstanceHook(@"YTVideoWithContextNode", @"setEntry:",
                              (IMP)YTzoomVideoNodeSetEntry,
                              &OriginalVideoNodeSetEntry);
    YTzoomInstallInstanceHook(@"YTVideoWithContextNode", @"yt_height",
                              (IMP)YTzoomVideoNodeHeight,
                              &OriginalVideoNodeHeight);
    YTzoomInstallInstanceHook(@"YTVideoWithContextNode", @"yt_size",
                              (IMP)YTzoomVideoNodeSize,
                              &OriginalVideoNodeSize);
    YTzoomInstallInstanceHook(@"YTVideoWithContextNode",
                              @"shouldShrinkDismissalView",
                              (IMP)YTzoomVideoNodeShouldShrink,
                              &OriginalVideoNodeShrink);
    YTzoomInstallPromotedCellHooks();
    YTzoomInstallInstanceHook(@"_ASCollectionViewCell",
                              @"layoutSubviews",
                              (IMP)YTzoomAdCellLayoutSubviews,
                              &OriginalAdCellLayout);
    YTzoomInstallInstanceHook(@"_ASCollectionViewCell",
                              @"prepareForReuse",
                              (IMP)YTzoomAdCellPrepareForReuse,
                              &OriginalAdCellReuse);
    YTzoomInstallInstanceHook(@"YTGlobalConfig",
                              @"shouldBlockUpgradeDialog",
                              (IMP)YTzoomShouldBlockUpgradeDialog,
                              &OriginalShouldBlockUpgradeDialog);
    YTzoomInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionary",
                           (IMP)YTzoomAdShieldSignals,
                           &OriginalAdShieldSignals);
    YTzoomInstallClassHook(@"YTAdShieldUtils",
                           @"spamSignalsDictionaryWithoutIDFA",
                           (IMP)YTzoomAdShieldSignalsWithoutIDFA,
                           &OriginalAdShieldSignalsWithoutIDFA);
    YTzoomInstallClassHook(@"YTDataUtils",
                           @"spamSignalsDictionary",
                           (IMP)YTzoomDataSignals,
                           &OriginalDataSignals);
    YTzoomInstallClassHook(@"YTDataUtils",
                           @"spamSignalsDictionaryWithoutIDFA",
                           (IMP)YTzoomDataSignalsWithoutIDFA,
                           &OriginalDataSignalsWithoutIDFA);
    YTzoomInstallInstanceHook(@"YTAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTzoomAdsDecorateContext,
                              &OriginalAdsDecorateContext);
    YTzoomInstallInstanceHook(@"YTAccountScopedAdsInnerTubeContextDecorator",
                              @"decorateContext:",
                              (IMP)YTzoomAccountAdsDecorateContext,
                              &OriginalAccountAdsDecorateContext);

    YTzoomInstallObjectHookOrMethod(@"YTIPlayerResponse",
                                    @"playerAdsArray",
                                    (IMP)YTzoomPlayerAdsArray,
                                    &OriginalPlayerAdsArray);
    YTzoomInstallObjectHookOrMethod(@"YTIPlayerResponse",
                                    @"adSlotsArray",
                                    (IMP)YTzoomAdSlotsArray,
                                    &OriginalAdSlotsArray);
    YTzoomInstallObjectHookOrMethod(@"YTIPlayerResponse",
                                    @"adPlacementsArray",
                                    (IMP)YTzoomAdPlacementsArray,
                                    &OriginalAdPlacementsArray);
    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"adBreakParams",
                              (IMP)YTzoomAdBreakParams,
                              &OriginalAdBreakParams);
    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"adNextParams",
                              (IMP)YTzoomAdNextParams,
                              &OriginalAdNextParams);
    YTzoomInstallInstanceHook(@"YTIPlayerResponse",
                              @"adParams",
                              (IMP)YTzoomAdParams,
                              &OriginalAdParams);
    YTzoomInstallBooleanHookOrMethod(@"YTIClientMdxGlobalConfig",
                                     @"enableSkippableAd",
                                     (IMP)YTzoomEnableSkippableAd,
                                     &OriginalEnableSkippableAd);

    YTzoomInstallInstanceHook(@"MDXSessionImpl",
                              @"adPlaying:",
                              (IMP)YTzoomMDXSessionImplAdPlaying,
                              &OriginalMDXSessionImplAdPlaying);
    YTzoomInstallInstanceHook(@"MDXSession",
                              @"adPlaying:",
                              (IMP)YTzoomMDXSessionAdPlaying,
                              &OriginalMDXSessionAdPlaying);
    YTzoomInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAd",
                              (IMP)YTzoomIsPlayingAd,
                              &OriginalIsPlayingAd);
    YTzoomInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdSurvey",
                              (IMP)YTzoomIsPlayingAdSurvey,
                              &OriginalIsPlayingAdSurvey);
    YTzoomInstallInstanceHook(@"YTLocalPlaybackController",
                              @"isPlayingAdIntro",
                              (IMP)YTzoomIsPlayingAdIntro,
                              &OriginalIsPlayingAdIntro);
    YTzoomInstallInstanceHook(@"YTLocalPlaybackController",
                              @"createAdsPlaybackCoordinator",
                              (IMP)YTzoomNoAdsPlaybackCoordinator,
                              &OriginalCreateAdsPlaybackCoordinator);

    YTzoomInstallInstanceHook(@"YTReelDataSource",
                              @"makeContentModelForEntry:",
                              (IMP)YTzoomReelContentModel,
                              &OriginalReelContentModel);
    YTzoomInstallInstanceHook(@"YTReelInfinitePlaybackDataSource",
                              @"makeContentModelForEntry:",
                              (IMP)YTzoomInfiniteReelContentModel,
                              &OriginalInfiniteReelContentModel);
    YTzoomInstallInstanceHook(@"YTReelContentModel",
                              @"shouldDisplay",
                              (IMP)YTzoomReelShouldDisplay,
                              &OriginalReelShouldDisplay);
    YTzoomInstallInstanceHook(@"YTIElementRenderer",
                              @"companionAd",
                              (IMP)YTzoomNoCompanionAd,
                              &OriginalCompanionAd);
    YTzoomInstallInstanceHook(@"YTIElementRenderer",
                              @"hasCompanionAdRenderer",
                              (IMP)YTzoomHasCompanionAdRenderer,
                              &OriginalHasCompanionAdRenderer);
    YTzoomInstallInstanceHook(@"YTIElementRenderer",
                              @"hasAppPromoCompanionAdRenderer",
                              (IMP)YTzoomHasAppPromoCompanionAdRenderer,
                              &OriginalHasAppPromoCompanionAdRenderer);
    YTzoomInstallInstanceHook(@"YTIElementRenderer",
                              @"hasShoppingCompanionAdRenderer",
                              (IMP)YTzoomHasShoppingCompanionAdRenderer,
                              &OriginalHasShoppingCompanionAdRenderer);
    YTzoomInstallInstanceHook(@"YTIElementRenderer",
                              @"contentsArray",
                              (IMP)YTzoomElementContentsArray,
                              &OriginalElementContentsArray);
    YTzoomInstallInstanceHook(@"YTIItemSectionRenderer",
                              @"contentsArray",
                              (IMP)YTzoomItemSectionContentsArray,
                              &OriginalItemSectionContentsArray);
}
