#import "Localization.h"
#import "Preferences.h"
#import "../UI/Assets.h"

#import <UIKit/UIKit.h>

NSString * const YTzoomLanguageKey = @"YTzoom.Preference.Language";

NSArray<NSString *> *YTzoomAvailableLanguages(void) {
    return @[@"system", @"en", @"ar", @"ckb", @"de", @"es", @"fr", @"it",
             @"ja", @"ko", @"pl", @"pt-BR", @"ru", @"tr", @"vi", @"zh-Hans", @"zh-Hant"];
}

NSString *YTzoomLanguageDisplayName(NSString *code) {
    if ([code isEqualToString:@"system"]) return @"System";
    static NSDictionary<NSString *, NSString *> *names;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @{
            @"en": @"English",
            @"ar": @"العربية",
            @"ckb": @"کوردی",
            @"de": @"Deutsch",
            @"es": @"Español",
            @"fr": @"Français",
            @"it": @"Italiano",
            @"ja": @"日本語",
            @"ko": @"한국어",
            @"pl": @"Polski",
            @"pt-BR": @"Português (Brasil)",
            @"ru": @"Русский",
            @"tr": @"Türkçe",
            @"vi": @"Tiếng Việt",
            @"zh-Hans": @"简体中文",
            @"zh-Hant": @"繁體中文"
        };
    });
    return names[code] ?: code;
}

static NSString *YTzoomPreferredLanguage(void) {
    id stored = YTzoomPreferenceObject(YTzoomLanguageKey);
    NSString *choice = [stored isKindOfClass:NSString.class] ? stored : @"system";
    if (![choice isEqualToString:@"system"]) return choice;

    NSArray<NSString *> *available = YTzoomAvailableLanguages();
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *code = preferred;
        if ([code hasPrefix:@"zh-Hans"] || [code hasPrefix:@"zh-CN"] ||
            [code hasPrefix:@"zh-SG"]) {
            return @"zh-Hans";
        }
        if ([code hasPrefix:@"zh"]) return @"zh-Hant";
        if ([code hasPrefix:@"pt"]) return @"pt-BR";
        NSRange separator = [code rangeOfString:@"-"];
        if (separator.location != NSNotFound) {
            code = [code substringToIndex:separator.location];
        }
        if ([available containsObject:code]) return code;
    }
    return @"en";
}

static NSDictionary<NSString *, NSString *> *YTzoomStringsForLanguage(NSString *code) {
    NSBundle *bundle = YTzoomAssetsBundle();
    if (bundle == nil) return nil;
    NSString *path = [bundle pathForResource:@"Localizable"
                                      ofType:@"strings"
                                 inDirectory:nil
                             forLocalization:code];
    if (path == nil) {
        path = [bundle.resourcePath stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.lproj/Localizable.strings", code]];
    }
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

static NSDictionary<NSString *, NSString *> *YTzoomActiveStrings;
static NSString *YTzoomActiveLanguage;

void YTzoomResetLocalizationCache(void) {
    YTzoomActiveStrings = nil;
    YTzoomActiveLanguage = nil;
}

NSString *YTzoomLocalized(NSString *key) {
    if (key.length == 0) return key;
    NSString *language = YTzoomPreferredLanguage();
    if (![language isEqualToString:YTzoomActiveLanguage]) {
        YTzoomActiveLanguage = language;
        YTzoomActiveStrings = YTzoomStringsForLanguage(language);
    }
    NSString *value = YTzoomActiveStrings[key];
    return value.length != 0 ? value : key;
}
