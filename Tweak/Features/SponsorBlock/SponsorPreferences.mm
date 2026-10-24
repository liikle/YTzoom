#import "SponsorPreferences.h"
#import "../../Runtime/Preferences.h"
#import "../../Runtime/Localization.h"

NSArray<NSDictionary<NSString *, NSString *> *> *YTzoomSponsorCategoryDefinitions(void) {
    static NSArray *definitions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        definitions = @[
            @{@"id": @"sponsor", @"title": YTzoomLocalized(@"Sponsor"), @"color": @"#00D400"},
            @{@"id": @"selfpromo", @"title": YTzoomLocalized(@"Self Promotion"), @"color": @"#FFFF00"},
            @{@"id": @"interaction", @"title": YTzoomLocalized(@"Interaction Reminder"), @"color": @"#CC00FF"},
            @{@"id": @"intro", @"title": YTzoomLocalized(@"Intermission / Intro"), @"color": @"#00FFFF"},
            @{@"id": @"outro", @"title": YTzoomLocalized(@"Endcards / Credits"), @"color": @"#0202ED"},
            @{@"id": @"preview", @"title": YTzoomLocalized(@"Preview / Recap"), @"color": @"#008FD6"},
            @{@"id": @"music_offtopic", @"title": YTzoomLocalized(@"Non-Music Section"), @"color": @"#FF9900"},
            @{@"id": @"filler", @"title": YTzoomLocalized(@"Filler"), @"color": @"#7300FF"},
            @{@"id": @"poi_highlight", @"title": YTzoomLocalized(@"Highlight"), @"color": @"#FF1684"}
        ];
    });
    return definitions;
}

NSString *YTzoomSponsorBehaviorKey(NSString *category) {
    return [@"YTzoom.Preference.SponsorBlock.Behavior."
        stringByAppendingString:category ?: @""];
}

NSString *YTzoomSponsorColorKey(NSString *category) {
    return [@"YTzoom.Preference.SponsorBlock.Color."
        stringByAppendingString:category ?: @""];
}

static NSDictionary<NSString *, NSString *> *YTzoomSponsorDefinition(NSString *category) {
    for (NSDictionary *definition in YTzoomSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isEqualToString:category]) return definition;
    }
    return nil;
}

NSInteger YTzoomSponsorCategoryBehavior(NSString *category) {
    id stored = YTzoomPreferenceObject(YTzoomSponsorBehaviorKey(category));
    if ([stored respondsToSelector:@selector(integerValue)]) {
        return MAX(0, MIN([stored integerValue], 3));
    }
    if ([category isEqualToString:@"sponsor"]) {
        id legacy = YTzoomPreferenceObject(@"YTzoom.Preference.SponsorBlock.Mode");
        return [legacy respondsToSelector:@selector(integerValue)] &&
            [legacy integerValue] == 1 ? 1 : 0;
    }
    return 2;
}

NSArray<NSString *> *YTzoomSponsorEnabledCategories(void) {
    NSMutableArray *categories = [NSMutableArray array];
    for (NSDictionary *definition in YTzoomSponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        if (YTzoomSponsorCategoryBehavior(category) != 2) {
            [categories addObject:category];
        }
    }
    return categories;
}

static UIColor *YTzoomColorFromHex(NSString *hex) {
    NSString *value = [[hex ?: @"" stringByReplacingOccurrencesOfString:@"#"
                                                              withString:@""] uppercaseString];
    if (value.length != 6) return UIColor.systemGreenColor;
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

UIColor *YTzoomSponsorCategoryColor(NSString *category) {
    NSDictionary *definition = YTzoomSponsorDefinition(category);
    NSString *stored = YTzoomPreferenceObject(YTzoomSponsorColorKey(category));
    NSString *hex = [stored isKindOfClass:NSString.class] && stored.length != 0
        ? stored : definition[@"color"];
    return YTzoomColorFromHex(hex);
}

NSInteger YTzoomSponsorNotificationMode(void) {
    id stored = YTzoomPreferenceObject(@"YTzoom.Preference.SponsorBlock.NotificationMode");
    return [stored respondsToSelector:@selector(integerValue)]
        ? MAX(0, MIN([stored integerValue], 2)) : 0;
}

static NSTimeInterval YTzoomSponsorDuration(NSString *key) {
    id stored = YTzoomPreferenceObject(key);
    double value = [stored respondsToSelector:@selector(doubleValue)]
        ? [stored doubleValue] : 4.0;
    return MAX(1.0, MIN(value, 10.0));
}

NSTimeInterval YTzoomSponsorSkipAlertDuration(void) {
    return YTzoomSponsorDuration(@"YTzoom.Preference.SponsorBlock.SkipAlertSeconds");
}

NSTimeInterval YTzoomSponsorUnskipAlertDuration(void) {
    return YTzoomSponsorDuration(@"YTzoom.Preference.SponsorBlock.UnskipAlertSeconds");
}
