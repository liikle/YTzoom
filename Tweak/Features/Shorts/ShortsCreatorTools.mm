#import "../../YTzoom.h"
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

static NSString *const YTzoomUnlimitedStickersKey = @"YTzoom.Preference.Shorts.UnlimitedStickers";
static NSString *const YTzoomLongerPollsKey = @"YTzoom.Preference.Shorts.LongerPolls";
static NSString *const YTzoomPollOptionsKey = @"YTzoom.Preference.Shorts.PollOptions";
static NSString *const YTzoomStickerFontNameKey = @"YTzoom.Preference.Shorts.StickerFontName";
static NSString *const YTzoomStickerFontFileKey = @"YTzoom.Preference.Shorts.StickerFontFile";

static NSString *YTzoomActiveStickerFont;

static id YTzoomCreatorSend(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(receiver, selector) : nil;
}

static void YTzoomCreatorSetInt(id receiver, NSString *name, int value) {
    SEL selector = NSSelectorFromString(name);
    if ([receiver respondsToSelector:selector]) {
        ((void (*)(id, SEL, int))objc_msgSend)(receiver, selector, value);
    }
}

static int YTzoomCreatorInt(id receiver, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [receiver respondsToSelector:selector]
        ? ((int (*)(id, SEL))objc_msgSend)(receiver, selector) : 0;
}

#pragma mark - Sticker limits

static IMP YTzoomOrigCanAddText;
static BOOL YTzoomCanAddText(id self, SEL _cmd) {
    if (YTzoomFeatureEnabled(YTzoomUnlimitedStickersKey)) return YES;
    return ((BOOL (*)(id, SEL))YTzoomOrigCanAddText)(self, _cmd);
}

static IMP YTzoomOrigCanAddImage;
static BOOL YTzoomCanAddImage(id self, SEL _cmd) {
    if (YTzoomFeatureEnabled(YTzoomUnlimitedStickersKey)) return YES;
    return ((BOOL (*)(id, SEL))YTzoomOrigCanAddImage)(self, _cmd);
}

#pragma mark - Custom font

static NSURL *YTzoomStickerFontDirectory(void) {
    return [YTzoomApplicationSupportDirectory() URLByAppendingPathComponent:@"Fonts"
                                                                 isDirectory:YES];
}

static NSString *YTzoomFontPostScriptName(NSURL *url) {
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
static NSString *YTzoomRegisterStickerFont(NSURL *url) {
    NSString *name = YTzoomFontPostScriptName(url);
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

static void YTzoomLoadStoredStickerFont(void) {
    YTzoomActiveStickerFont = nil;
    id file = YTzoomPreferenceObject(YTzoomStickerFontFileKey);
    if (![file isKindOfClass:NSString.class] || [file length] == 0) return;
    NSURL *url = [YTzoomStickerFontDirectory() URLByAppendingPathComponent:file];
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) return;
    YTzoomActiveStickerFont = YTzoomRegisterStickerFont(url);
}

static void YTzoomClearStickerFont(void) {
    id file = YTzoomPreferenceObject(YTzoomStickerFontFileKey);
    if ([file isKindOfClass:NSString.class] && [file length] != 0) {
        NSURL *url = [YTzoomStickerFontDirectory() URLByAppendingPathComponent:file];
        CTFontManagerUnregisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, NULL);
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    }
    YTzoomSetPreferenceObject(YTzoomStickerFontFileKey, @"");
    YTzoomSetPreferenceObject(YTzoomStickerFontNameKey, @"");
    YTzoomActiveStickerFont = nil;
}

static NSString *YTzoomInstallStickerFont(NSURL *source) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *directory = YTzoomStickerFontDirectory();
    [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *destination = [directory URLByAppendingPathComponent:source.lastPathComponent];
    NSURL *staging = [directory URLByAppendingPathComponent:
        [NSString stringWithFormat:@".import-%@", NSUUID.UUID.UUIDString]];
    if (![files copyItemAtURL:source toURL:staging error:nil]) return nil;
    if (YTzoomFontPostScriptName(staging) == nil) {
        [files removeItemAtURL:staging error:nil];
        return nil;
    }
    YTzoomClearStickerFont();
    [files removeItemAtURL:destination error:nil];
    if (![files moveItemAtURL:staging toURL:destination error:nil]) {
        [files removeItemAtURL:staging error:nil];
        return nil;
    }
    NSString *name = YTzoomRegisterStickerFont(destination);
    if (name == nil) {
        [files removeItemAtURL:destination error:nil];
        return nil;
    }
    YTzoomSetPreferenceObject(YTzoomStickerFontFileKey, destination.lastPathComponent);
    YTzoomSetPreferenceObject(YTzoomStickerFontNameKey, name);
    YTzoomActiveStickerFont = name;
    return name;
}

static IMP YTzoomOrigFontName;
static id YTzoomFontName(id self, SEL _cmd, long long style) {
    if (YTzoomMasterEnabled() && YTzoomActiveStickerFont != nil) return YTzoomActiveStickerFont;
    return ((id (*)(id, SEL, long long))YTzoomOrigFontName)(self, _cmd, style);
}

static IMP YTzoomOrigStyleFont;
static UIFont *YTzoomStyleFont(id self, SEL _cmd, long long style, double size) {
    if (YTzoomMasterEnabled() && YTzoomActiveStickerFont != nil) {
        UIFont *font = [UIFont fontWithName:YTzoomActiveStickerFont size:size];
        if (font != nil) return font;
    }
    return ((UIFont *(*)(id, SEL, long long, double))YTzoomOrigStyleFont)(self, _cmd, style, size);
}

@interface YTzoomStickerFontPicker : NSObject <UIDocumentPickerDelegate>
@end

static YTzoomStickerFontPicker *YTzoomActiveFontPicker;

@implementation YTzoomStickerFontPicker
- (void)documentPicker:(__unused UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    YTzoomActiveFontPicker = nil;
    NSURL *source = urls.firstObject;
    if (source == nil) return;
    BOOL scoped = [source startAccessingSecurityScopedResource];
    NSString *name = YTzoomInstallStickerFont(source);
    if (scoped) [source stopAccessingSecurityScopedResource];
    YTzoomShowNotice(name != nil
        ? [NSString stringWithFormat:YTzoomLocalized(@"Text stickers now use %@"), name]
        : YTzoomLocalized(@"This font couldn't be loaded. Use a .ttf or .otf file."));
}

- (void)documentPickerWasCancelled:(__unused UIDocumentPickerViewController *)controller {
    YTzoomActiveFontPicker = nil;
}
@end

static void YTzoomPresentFontFilePicker(UIViewController *controller) {
    NSMutableArray<UTType *> *types = [NSMutableArray array];
    for (NSString *extension in @[@"ttf", @"otf"]) {
        UTType *type = [UTType typeWithFilenameExtension:extension];
        if (type != nil) [types addObject:type];
    }
    if (types.count == 0) [types addObject:UTTypeFont];
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    YTzoomActiveFontPicker = [YTzoomStickerFontPicker new];
    picker.delegate = YTzoomActiveFontPicker;
    [controller presentViewController:picker animated:YES completion:nil];
}

void YTzoomPresentStickerFontMenu(UIViewController *controller) {
    NSString *current = YTzoomActiveStickerFont;
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:YTzoomLocalized(@"Text Sticker Font")
                         message:current ?: YTzoomLocalized(@"YouTube fonts")
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Choose Font File")
                                             style:UIAlertActionStyleDefault
                                           handler:^(__unused UIAlertAction *action) {
        YTzoomPresentFontFilePicker(controller);
    }]];
    if (current != nil) {
        [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Use YouTube Fonts")
                                                 style:UIAlertActionStyleDestructive
                                               handler:^(__unused UIAlertAction *action) {
            YTzoomClearStickerFont();
            YTzoomShowNotice(YTzoomLocalized(@"Text stickers use YouTube fonts"));
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    popover.sourceView = controller.view;
    popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                    CGRectGetMidY(controller.view.bounds), 1.0, 1.0);
    [controller presentViewController:menu animated:YES completion:nil];
}

#pragma mark - Polls

static NSInteger YTzoomPollOptionTarget(void) {
    id stored = YTzoomPreferenceObject(YTzoomPollOptionsKey);
    return [stored respondsToSelector:@selector(integerValue)] ? [stored integerValue] : 0;
}

// "Option 4" becomes "Option 5", "Option 6", ... for the rows we add.
static NSString *YTzoomNextPlaceholder(NSString *last, NSUInteger number) {
    NSRange digits = [last rangeOfString:@"[0-9]+$" options:NSRegularExpressionSearch];
    if (digits.location == NSNotFound) return last;
    return [last stringByReplacingCharactersInRange:digits
                                         withString:[NSString stringWithFormat:@"%lu",
                                                     (unsigned long)number]];
}

static void YTzoomAddPollOptions(id displayData, NSInteger target) {
    NSMutableArray *options = YTzoomCreatorSend(displayData, @"optionsArray");
    if (![options isKindOfClass:NSMutableArray.class] || options.count == 0) return;
    Class formatted = NSClassFromString(@"YTIFormattedString");
    SEL make = NSSelectorFromString(@"formattedStringWithString:");
    while ((NSInteger)options.count < target) {
        id option = [options.lastObject copy];
        NSString *last = YTzoomCreatorSend(YTzoomCreatorSend(option, @"placeholderText"),
                                           @"stringWithFormattingRemoved");
        SEL setPlaceholder = NSSelectorFromString(@"setPlaceholderText:");
        if ([last isKindOfClass:NSString.class] && [formatted respondsToSelector:make] &&
            [option respondsToSelector:setPlaceholder]) {
            id text = ((id (*)(id, SEL, id))objc_msgSend)(
                formatted, make, YTzoomNextPlaceholder(last, options.count + 1));
            ((void (*)(id, SEL, id))objc_msgSend)(option, setPlaceholder, text);
        }
        [options addObject:option];
    }
}

static void YTzoomRaisePollLimit(id displayData, NSString *name, int value) {
    if (YTzoomCreatorInt(displayData, name) >= value) return;
    NSString *setter = [NSString stringWithFormat:@"set%@%@:",
                        [name substringToIndex:1].uppercaseString, [name substringFromIndex:1]];
    YTzoomCreatorSetInt(displayData, setter, value);
}

// Works on a copy so YouTube's cached sticker config stays untouched.
static id YTzoomAdjustedPollRenderer(id renderer) {
    if (!YTzoomMasterEnabled() || ![renderer conformsToProtocol:@protocol(NSCopying)]) return nil;
    BOOL longer = YTzoomFeatureEnabled(YTzoomLongerPollsKey);
    NSInteger target = YTzoomPollOptionTarget();
    if (!longer && target <= 0) return nil;
    id copy = [renderer copy];
    id displayData = YTzoomCreatorSend(YTzoomCreatorSend(copy, @"yt_pollStickerRenderer"),
                                       @"stickerDisplayData");
    if (displayData == nil) return nil;
    if (target > 0) YTzoomAddPollOptions(displayData, target);
    if (longer) {
        YTzoomRaisePollLimit(displayData, @"questionCharacterLimit", 500);
        YTzoomRaisePollLimit(displayData, @"questionLineLimit", 10);
        YTzoomRaisePollLimit(displayData, @"optionCharacterLimit", 200);
        YTzoomRaisePollLimit(displayData, @"optionLineLimit", 4);
    }
    return copy;
}

static IMP YTzoomOrigPollViewModel;
static id YTzoomPollViewModel(id self, SEL _cmd, id renderer) {
    id adjusted = YTzoomAdjustedPollRenderer(renderer);
    return ((id (*)(id, SEL, id))YTzoomOrigPollViewModel)(self, _cmd, adjusted ?: renderer);
}

#pragma mark - Install

void YTzoomInstallShortsCreatorHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomInstallInstanceHook(@"YTCreationStickerOverlayViewController",
                                  @"canAddMoreTextStickers",
                                  (IMP)YTzoomCanAddText, &YTzoomOrigCanAddText);
        YTzoomInstallInstanceHook(@"YTCreationStickerOverlayViewController",
                                  @"canAddMoreImageStickers",
                                  (IMP)YTzoomCanAddImage, &YTzoomOrigCanAddImage);
        YTzoomLoadStoredStickerFont();
        YTzoomInstallClassHook(@"UIFont", @"fontForTextStyle:ofSize:",
                               (IMP)YTzoomStyleFont, &YTzoomOrigStyleFont);
        YTzoomInstallClassHook(@"TOKStyle", @"fontNameForTextStyle:",
                               (IMP)YTzoomFontName, &YTzoomOrigFontName);
        YTzoomInstallClassHook(@"YTEditPollStickerViewModel",
                               @"defaultViewModelWithInteractiveStickerRenderer:",
                               (IMP)YTzoomPollViewModel, &YTzoomOrigPollViewModel);
    });
}
