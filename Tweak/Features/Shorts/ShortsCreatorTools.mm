#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Notice.h"

#import <CoreText/CoreText.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Shorts editor creator tools (verified against YouTube 21.33.6 and 21.40.5):
// - Text and image sticker caps live in -[YTCreationStickerOverlayViewController
//   canAddMoreTextStickers] / canAddMoreImageStickers.
// - Text sticker fonts come from +[TOKStyle attributesForTextStyle:...], which
//   asks +[UIFont fontForTextStyle:ofSize:] (YouTube's bundled fonts) first and
//   only falls back to +[TOKStyle fontNameForTextStyle:] when that returns nil.
//   Text stickers are rendered by UIKit into the images that get burned into
//   the export, so a font registered with the process ends up in the video.
// - A poll sticker builds one option row per entry in its server config
//   (stickerDisplayData.optionsArray) and takes its text limits from the same
//   config. +[YTEditPollStickerViewModel defaultViewModelWithInteractiveStickerRenderer:]
//   serializes that config into the poll, so changes made there persist.

static NSString *const YTKACEUnlimitedStickersKey = @"YTKACE.Preference.Shorts.UnlimitedStickers";
static NSString *const YTKACELongerPollsKey = @"YTKACE.Preference.Shorts.LongerPolls";
static NSString *const YTKACEPollOptionsKey = @"YTKACE.Preference.Shorts.PollOptions";
static NSString *const YTKACEStickerFontNameKey = @"YTKACE.Preference.Shorts.StickerFontName";
static NSString *const YTKACEStickerFontFileKey = @"YTKACE.Preference.Shorts.StickerFontFile";

static NSString *YTKACEActiveStickerFont;

static id YTKACECreatorSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static void YTKACECreatorSetInt(id receiver, NSString *name, int value) {
    SEL selector = NSSelectorFromString(name);
    if ([receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, int))objc_msgSend)(receiver, selector, value);
    }
}

static int YTKACECreatorInt(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((int (*)(id, SEL))objc_msgSend)(receiver, selector) : 0;
}

#pragma mark - Sticker limits

static IMP YTKACEOrigCanAddText;
static BOOL YTKACECanAddText(id self, SEL _cmd) {
    if (YTKACEFeatureEnabled(YTKACEUnlimitedStickersKey)) return YES;
    return ((BOOL (*)(id, SEL))YTKACEOrigCanAddText)(self, _cmd);
}

static IMP YTKACEOrigCanAddImage;
static BOOL YTKACECanAddImage(id self, SEL _cmd) {
    if (YTKACEFeatureEnabled(YTKACEUnlimitedStickersKey)) return YES;
    return ((BOOL (*)(id, SEL))YTKACEOrigCanAddImage)(self, _cmd);
}

#pragma mark - Custom font

static NSURL *YTKACEStickerFontDirectory(void) {
    return [YTKACEApplicationSupportDirectory() URLByAppendingPathComponent:@"Fonts"
                                                                 isDirectory:YES];
}

static NSString *YTKACEFontPostScriptName(NSURL *url) {
    CGDataProviderRef provider = CGDataProviderCreateWithURL((__bridge CFURLRef)url);
    if (provider == NULL) return nil;
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (font == NULL) return nil;
    NSString *name = CFBridgingRelease(CGFontCopyPostScriptName(font));
    CGFontRelease(font);
    return name.length != 0 ? name : nil;
}

// Registers the font for this process only and returns its PostScript name.
static NSString *YTKACERegisterStickerFont(NSURL *url) {
    NSString *name = YTKACEFontPostScriptName(url);
    if (name == nil) return nil;
    if ([UIFont fontWithName:name size:12.0] == nil) {
        CFErrorRef error = NULL;
        if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,
                                              kCTFontManagerScopeProcess, &error) &&
            error != NULL) {
            CFRelease(error);
        }
    }
    return [UIFont fontWithName:name size:12.0] != nil ? name : nil;
}

static void YTKACELoadStoredStickerFont(void) {
    YTKACEActiveStickerFont = nil;
    id file = YTKACEPreferenceObject(YTKACEStickerFontFileKey);
    if (![file isKindOfClass:NSString.class] || [file length] == 0) return;
    NSURL *url = [YTKACEStickerFontDirectory() URLByAppendingPathComponent:file];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return;
    YTKACEActiveStickerFont = YTKACERegisterStickerFont(url);
}

static void YTKACEClearStickerFont(void) {
    id file = YTKACEPreferenceObject(YTKACEStickerFontFileKey);
    if ([file isKindOfClass:NSString.class] && [file length] != 0) {
        NSURL *url = [YTKACEStickerFontDirectory() URLByAppendingPathComponent:file];
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
    YTKACESetPreferenceObject(YTKACEStickerFontFileKey, @"");
    YTKACESetPreferenceObject(YTKACEStickerFontNameKey, @"");
    YTKACEActiveStickerFont = nil;
}

static NSString *YTKACEInstallStickerFont(NSURL *source) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *directory = YTKACEStickerFontDirectory();
    [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [directory URLByAppendingPathComponent:source.lastPathComponent];
    NSURL *staging = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@".import-%@", NSUUID.UUID.UUIDString]];
    if (![files copyItemAtURL:source toURL:staging error:nil]) return nil;
    if (YTKACEFontPostScriptName(staging) == nil) {
        [files removeItemAtURL:staging error:nil];
        return nil;
    }
    YTKACEClearStickerFont();
    [files removeItemAtURL:destination error:nil];
    if (![files moveItemAtURL:staging toURL:destination error:nil]) {
        [files removeItemAtURL:staging error:nil];
        return nil;
    }
    NSString *name = YTKACERegisterStickerFont(destination);
    if (name == nil) {
        [files removeItemAtURL:destination error:nil];
        return nil;
    }
    YTKACESetPreferenceObject(YTKACEStickerFontFileKey, destination.lastPathComponent);
    YTKACESetPreferenceObject(YTKACEStickerFontNameKey, name);
    YTKACEActiveStickerFont = name;
    return name;
}

static IMP YTKACEOrigFontName;
static id YTKACEFontName(id self, SEL _cmd, long long style) {
    if (YTKACEMasterEnabled() && YTKACEActiveStickerFont != nil) return YTKACEActiveStickerFont;
    return ((id (*)(id, SEL, long long))YTKACEOrigFontName)(self, _cmd, style);
}

static IMP YTKACEOrigStyleFont;
static UIFont *YTKACEStyleFont(id self, SEL _cmd, long long style, double size) {
    if (YTKACEMasterEnabled() && YTKACEActiveStickerFont != nil) {
        UIFont *font = [UIFont fontWithName:YTKACEActiveStickerFont size:size];
        if (font != nil) return font;
    }
    return ((UIFont *(*)(id, SEL, long long, double))YTKACEOrigStyleFont)(self, _cmd, style, size);
}

@interface YTKACEStickerFontPicker : NSObject <UIDocumentPickerDelegate>
@end

static YTKACEStickerFontPicker *YTKACEActiveFontPicker;

@implementation YTKACEStickerFontPicker
- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    YTKACEActiveFontPicker = nil;
    NSURL *source = urls.firstObject;
    if (source == nil) return;
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSString *name = YTKACEInstallStickerFont(source);
    if (scoped) [source stopAccessingSecurityScopedResource];
    YTKACEShowNotice(name != nil
        ? [NSString stringWithFormat:YTKACELocalized(@"Text stickers now use %@"), name]
        : YTKACELocalized(@"This font couldn't be loaded. Use a .ttf or .otf file."));
}

- (void)documentPickerWasCancelled:(__unused UIDocumentPickerViewController *)controller {
    YTKACEActiveFontPicker = nil;
}
@end

static void YTKACEPresentFontFilePicker(UIViewController *controller) {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *extension in @[@"ttf", @"otf"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type != nil) [types addObject:type];
    }
    if (types.count == 0) [types addObject:UTTypeFont];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    YTKACEActiveFontPicker = [YTKACEStickerFontPicker new];
    picker.delegate = YTKACEActiveFontPicker;
    [controller presentViewController:picker animated:YES completion:nil];
}

void YTKACEPresentStickerFontMenu(UIViewController *controller) {
    NSString *current = YTKACEActiveStickerFont;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:YTKACELocalized(@"Text Sticker Font")
                         message:current ?: YTKACELocalized(@"YouTube fonts")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Choose Font File")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        YTKACEPresentFontFilePicker(controller);
    }]];
    if (current != nil) {
        [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Use YouTube Fonts")
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *action) {
            YTKACEClearStickerFont();
            YTKACEShowNotice(YTKACELocalized(@"Text stickers use YouTube fonts"));
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:YTKACELocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    popover.sourceView = controller.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                    CGRectGetMidY(controller.view.bounds), 1.0, 1.0);
    [controller presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Polls

static NSInteger YTKACEPollOptionTarget(void) {
    id stored = YTKACEPreferenceObject(YTKACEPollOptionsKey);
    return [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
}

// "Option 4" becomes "Option 5", "Option 6", ... for the rows we add.
static NSString *YTKACENextPlaceholder(NSString *last, NSUInteger number) {
    NSRange digits = [last rangeOfString:@"[0-9]+$" options:NSRegularExpressionSearch];
    if (digits.location == NSNotFound) return last;
    return [last stringByReplacingCharactersInRange:digits
                                         withString:[NSString stringWithFormat:@"%lu",
                                                     (unsigned long)number]];
}

static void YTKACEAddPollOptions(id displayData, NSInteger target) {
    NSMutableArray *options = YTKACECreatorSend(displayData, @"optionsArray");
    if (![options isKindOfClass:NSMutableArray.class] || options.count == 0) return;
    Class formatted = NSClassFromString(@"YTIFormattedString");
    SEL make = NSSelectorFromString(@"formattedStringWithString:");
    while ((NSInteger)options.count < target) {
        id option = [options.lastObject copy];
        NSString *last = YTKACECreatorSend(YTKACECreatorSend(option, @"placeholderText"),
                                           @"stringWithFormattingRemoved");
        SEL setPlaceholder = NSSelectorFromString(@"setPlaceholderText:");
        if ([last isKindOfClass:NSString.class] && [formatted respondsToSelector:make] &&
            [option respondsToSelector:setPlaceholder]) {
            id text = ((id (*)(id, SEL, id))objc_msgSend)(
                formatted, make, YTKACENextPlaceholder(last, options.count + 1));
            ((void (*)(id, SEL, id))objc_msgSend)(option, setPlaceholder, text);
        }
        [options addObject:option];
    }
}

static void YTKACERaisePollLimit(id displayData, NSString *name, int value) {
    if (YTKACECreatorInt(displayData, name) >= value) return;
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]];
    YTKACECreatorSetInt(displayData, setter, value);
}

// Works on a copy so YouTube's cached sticker config stays untouched.
static id YTKACEAdjustedPollRenderer(id renderer) {
    if (!YTKACEMasterEnabled() || ![renderer conformsToProtocol:@protocol(NSCopying)]) return nil;
    BOOL longer = YTKACEFeatureEnabled(YTKACELongerPollsKey);
    NSInteger target = YTKACEPollOptionTarget();
    if (!longer && target <= 0) return nil;
    id copy = [renderer copy];
    id displayData = YTKACECreatorSend(YTKACECreatorSend(copy, @"yt_pollStickerRenderer"),
                                       @"stickerDisplayData");
    if (displayData == nil) return nil;
    if (target > 0) YTKACEAddPollOptions(displayData, target);
    if (longer) {
        YTKACERaisePollLimit(displayData, @"questionCharacterLimit", 500);
        YTKACERaisePollLimit(displayData, @"questionLineLimit", 10);
        YTKACERaisePollLimit(displayData, @"optionCharacterLimit", 200);
        YTKACERaisePollLimit(displayData, @"optionLineLimit", 4);
    }
    return copy;
}

static IMP YTKACEOrigPollViewModel;
static id YTKACEPollViewModel(id self, SEL _cmd, id renderer) {
    id adjusted = YTKACEAdjustedPollRenderer(renderer);
    return ((id (*)(id, SEL, id))YTKACEOrigPollViewModel)(self, _cmd, adjusted ?: renderer);
}

#pragma mark - Install

void YTKACEInstallShortsCreatorHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTKACEInstallInstanceHook(@"YTCreationStickerOverlayViewController",
                                  @"canAddMoreTextStickers",
                                  (IMP)YTKACECanAddText, &YTKACEOrigCanAddText);
        YTKACEInstallInstanceHook(@"YTCreationStickerOverlayViewController",
                                  @"canAddMoreImageStickers",
                                  (IMP)YTKACECanAddImage, &YTKACEOrigCanAddImage);
        YTKACELoadStoredStickerFont();
        YTKACEInstallClassHook(@"UIFont", @"fontForTextStyle:ofSize:",
                               (IMP)YTKACEStyleFont, &YTKACEOrigStyleFont);
        YTKACEInstallClassHook(@"TOKStyle", @"fontNameForTextStyle:",
                               (IMP)YTKACEFontName, &YTKACEOrigFontName);
        YTKACEInstallClassHook(@"YTEditPollStickerViewModel",
                               @"defaultViewModelWithInteractiveStickerRenderer:",
                               (IMP)YTKACEPollViewModel, &YTKACEOrigPollViewModel);
    });
}
