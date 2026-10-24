#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"

#import <Foundation/Foundation.h>
#import <objc/message.h>

// Testing aid: tells YouTube it runs in another country. Only what the app sends
// changes (the gl, hl and time zone fields of every InnerTube request, plus the
// locale YouTube reads). YouTube can still see the real IP address.

NSString * const YTzoomRegionCountryKey = @"YTzoom.Preference.Region.Country";
NSString * const YTzoomRegionLanguageKey = @"YTzoom.Preference.Region.Language";
NSString * const YTzoomRegionTimeZoneKey = @"YTzoom.Preference.Region.TimeZone";
NSString * const YTzoomRegionLocaleKey = @"YTzoom.Preference.Region.Locale";

static NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *YTzoomRegionTable(void) {
    static NSDictionary *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"US": @{@"hl": @"en-US", @"zone": @"America/New_York"},
            @"GB": @{@"hl": @"en-GB", @"zone": @"Europe/London"},
            @"CA": @{@"hl": @"en-CA", @"zone": @"America/Toronto"},
            @"AU": @{@"hl": @"en-AU", @"zone": @"Australia/Sydney"},
            @"IN": @{@"hl": @"en-IN", @"zone": @"Asia/Kolkata"},
            @"JP": @{@"hl": @"ja-JP", @"zone": @"Asia/Tokyo"},
            @"KR": @{@"hl": @"ko-KR", @"zone": @"Asia/Seoul"},
            @"BR": @{@"hl": @"pt-BR", @"zone": @"America/Sao_Paulo"},
            @"DE": @{@"hl": @"de-DE", @"zone": @"Europe/Berlin"},
            @"FR": @{@"hl": @"fr-FR", @"zone": @"Europe/Paris"}
        };
    });
    return table;
}

NSArray<NSString *> *YTzoomRegionCountryCodes(void) {
    return @[@"US", @"GB", @"CA", @"AU", @"IN", @"JP", @"KR", @"BR", @"DE", @"FR"];
}

NSString *YTzoomRegionOverride(void) {
    if (!YTzoomMasterEnabled()) return nil;
    id code = YTzoomPreferenceObject(YTzoomRegionCountryKey);
    if (![code isKindOfClass:NSString.class]) return nil;
    NSString *country = [(NSString *)code uppercaseString];
    return YTzoomRegionTable()[country] != nil ? country : nil;
}

static NSString *YTzoomRegionLanguageOverride(void) {
    NSString *country = YTzoomRegionOverride();
    if (country == nil || !YTzoomFeatureEnabled(YTzoomRegionLanguageKey)) return nil;
    return YTzoomRegionTable()[country][@"hl"];
}

static NSTimeZone *YTzoomRegionTimeZoneOverride(void) {
    NSString *country = YTzoomRegionOverride();
    if (country == nil || !YTzoomFeatureEnabled(YTzoomRegionTimeZoneKey)) return nil;
    return [NSTimeZone timeZoneWithName:YTzoomRegionTable()[country][@"zone"]];
}

#pragma mark - InnerTube client info

static IMP OriginalClientSetGl;
static IMP OriginalClientSetHl;

static void YTzoomClientSetGl(id receiver, SEL selector, NSString *value) {
    NSString *country = YTzoomRegionOverride();
    ((void (*)(id, SEL, id))OriginalClientSetGl)(receiver, selector, country ?: value);
}

static void YTzoomClientSetHl(id receiver, SEL selector, NSString *value) {
    NSString *language = YTzoomRegionLanguageOverride();
    ((void (*)(id, SEL, id))OriginalClientSetHl)(receiver, selector, language ?: value);
}

static void YTzoomRegionSetString(id object, NSString *selectorName, NSString *value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (value.length == 0 || ![object respondsToSelector:selector]) return;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

void YTzoomApplyRegionOverride(id context) {
    NSString *country = YTzoomRegionOverride();
    SEL clientSelector = NSSelectorFromString(@"client");
    if (country == nil || ![context respondsToSelector:clientSelector]) return;
    id client = ((id (*)(id, SEL))objc_msgSend)(context, clientSelector);
    if (client == nil) return;

    // Hook the client info setters too, so contexts built elsewhere get the
    // same values. The protobuf class is only known once a context exists.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *className = NSStringFromClass([client class]);
        YTzoomInstallInstanceHook(className, @"setGl:", (IMP)YTzoomClientSetGl, &OriginalClientSetGl);
        YTzoomInstallInstanceHook(className, @"setHl:", (IMP)YTzoomClientSetHl, &OriginalClientSetHl);
    });

    YTzoomRegionSetString(client, @"setGl:", country);
    YTzoomRegionSetString(client, @"setHl:", YTzoomRegionLanguageOverride());
    NSTimeZone *zone = YTzoomRegionTimeZoneOverride();
    if (zone != nil) {
        YTzoomRegionSetString(client, @"setTimeZone:", zone.name);
        SEL setOffset = NSSelectorFromString(@"setUtcOffsetMinutes:");
        if ([client respondsToSelector:setOffset]) {
            ((void (*)(id, SEL, int32_t))objc_msgSend)(
                client, setOffset, (int32_t)(zone.secondsFromGMT / 60));
        }
    }
}

#pragma mark - Locale

static NSLocale *YTzoomRegionLocale;
static IMP OriginalCurrentLocale;
static IMP OriginalAutoupdatingCurrentLocale;

static id YTzoomCurrentLocale(id receiver, SEL selector) {
    return YTzoomRegionLocale ?: ((id (*)(id, SEL))OriginalCurrentLocale)(receiver, selector);
}

static id YTzoomAutoupdatingCurrentLocale(id receiver, SEL selector) {
    return YTzoomRegionLocale
        ?: ((id (*)(id, SEL))OriginalAutoupdatingCurrentLocale)(receiver, selector);
}

static NSLocale *YTzoomMakeRegionLocale(NSString *country) {
    NSMutableDictionary *components = [[NSLocale componentsFromLocaleIdentifier:
        NSLocale.currentLocale.localeIdentifier] mutableCopy] ?: [NSMutableDictionary dictionary];
    // iOS stores a separate region choice in the rg keyword; drop it so the
    // country below wins.
    [components removeObjectForKey:@"rg"];
    components[NSLocaleCountryCode] = country;
    NSString *language = YTzoomRegionLanguageOverride();
    if (language.length != 0) {
        components[NSLocaleLanguageCode] = [language componentsSeparatedByString:@"-"].firstObject;
        [components removeObjectForKey:NSLocaleScriptCode];
    }
    return [NSLocale localeWithLocaleIdentifier:[NSLocale localeIdentifierFromComponents:components]];
}

void YTzoomInstallRegionHooks(void) {
    NSString *country = YTzoomRegionOverride();
    if (country == nil || !YTzoomFeatureEnabled(YTzoomRegionLocaleKey)) return;
    YTzoomRegionLocale = YTzoomMakeRegionLocale(country);
    YTzoomInstallClassHook(@"NSLocale", @"currentLocale",
                           (IMP)YTzoomCurrentLocale, &OriginalCurrentLocale);
    YTzoomInstallClassHook(@"NSLocale", @"autoupdatingCurrentLocale",
                           (IMP)YTzoomAutoupdatingCurrentLocale,
                           &OriginalAutoupdatingCurrentLocale);
}
