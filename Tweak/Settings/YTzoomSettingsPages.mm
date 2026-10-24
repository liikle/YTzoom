#import "YTzoomSettingsPages.h"
#import "../UI/OverlayButtonHost.h"
#import "YTzoomSettingsSearch.h"
#import "../Features/Downloads/SABRDownloader.h"
#import "YTzoomRootOptionsController.h"
#import "YTzoomTabEditorController.h"
#import "../Runtime/Preferences.h"
#import "../YTzoom.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../Features/Downloads/YTzoomBackupManager.h"
#import "../Features/Downloads/YTzoomMediaImporter.h"
#import "../Features/SponsorBlock/SponsorPreferences.h"
#import "../Features/SponsorBlock/DeArrow.h"

#import <objc/runtime.h>
#import <objc/message.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

typedef UIViewController * _Nonnull (^YTzoomControllerBuilder)(void);
typedef void (^YTzoomAction)(UIViewController *controller);

static const void *YTzoomItemAssociation = &YTzoomItemAssociation;
static const void *YTzoomValueLabelAssociation = &YTzoomValueLabelAssociation;

static NSArray<NSString *> *YTzoomLocalizedList(NSArray<NSString *> *titles) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        [out addObject:YTzoomLocalized(title)];
    }
    return out;
}

static NSDictionary *YTzoomToggle(NSString *title,
                                   NSString *key,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"toggle",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSDictionary *YTzoomToggleDetail(NSString *title,
                                         NSString *subtitle,
                                         NSString *key) {
    return @{
        @"type": @"toggle",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"subtitle": YTzoomLocalized(subtitle ?: @""),
        @"key": key,
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *YTzoomPickerDetail(NSString *title,
                                        NSString *subtitle,
                                        NSString *key,
                                        NSArray<NSString *> *titles,
                                        NSArray *values,
                                        NSUInteger defaultIndex) {
    return @{
        @"type": @"picker",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"subtitle": YTzoomLocalized(subtitle ?: @""),
        @"key": key,
        @"titles": YTzoomLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": @"",
        @"symbol": @""
    };
}

static NSDictionary *YTzoomPicker(NSString *title,
                                   NSString *key,
                                   NSArray<NSString *> *titles,
                                   NSArray *values,
                                   NSUInteger defaultIndex,
                                   NSString *asset,
                                   NSString *symbol) {
    return @{
        @"type": @"picker",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"titles": YTzoomLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex),
        @"asset": asset ?: @"",
        @"symbol": symbol ?: @""
    };
}

static NSString *YTzoomStepperText(NSDictionary *item, double value) {
    NSString *number = [NSString stringWithFormat:@"%.0f", value];
    if ([item[@"unit"] isEqualToString:@"count"]) {
        return [NSString stringWithFormat:@"%@: %@",
                item[@"title"] ?: YTzoomLocalized(@"Limit"), number];
    }
    return [NSString stringWithFormat:YTzoomLocalized(@"Seconds: %@"), number];
}

static NSDictionary *YTzoomStepper(NSString *title,
                                    NSString *key,
                                    double minimum,
                                    double maximum,
                                    double step,
                                    double fallback) {
    return @{
        @"type": @"stepper",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static NSDictionary *YTzoomCountStepper(NSString *title,
                                        NSString *key,
                                        double minimum,
                                        double maximum,
                                        double step,
                                        double fallback) {
    NSMutableDictionary *row =
        [YTzoomStepper(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = @"count";
    return row;
}

static NSDictionary *YTzoomSegmentedStacked(NSString *title,
                                            NSString *key,
                                            NSArray<NSString *> *titles,
                                            NSArray *values,
                                            NSUInteger defaultIndex) {
    return @{
        @"type": @"segmented",
        @"stacked": @YES,
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"titles": YTzoomLocalizedList(titles),
        @"values": values,
        @"default": @(defaultIndex)
    };
}

static NSDictionary *YTzoomSlider(NSString *title,
                                   NSString *key,
                                   double minimum,
                                   double maximum,
                                   double step,
                                   double fallback) {
    return @{
        @"type": @"slider",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"minimum": @(minimum),
        @"maximum": @(maximum),
        @"step": @(step),
        @"fallback": @(fallback)
    };
}

static const void *YTzoomStepTargetAssociation = &YTzoomStepTargetAssociation;

static NSDictionary *YTzoomStackedSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback,
                                         NSString *unit) {
    NSMutableDictionary *row =
        [YTzoomSlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    row[@"unit"] = unit ?: @"";
    row[@"stacked"] = @YES;
    return row;
}

static NSDictionary *YTzoomPercentSlider(NSString *title,
                                         NSString *key,
                                         double minimum,
                                         double maximum,
                                         double step,
                                         double fallback) {
    NSMutableDictionary *item =
        [YTzoomSlider(title, key, minimum, maximum, step, fallback) mutableCopy];
    item[@"unit"] = @"percent";
    item[@"stacked"] = @YES;
    return item;
}

static UIButton *YTzoomStepControl(BOOL increment,
                                   UISlider *slider,
                                   id target,
                                   SEL action) {
    UIImageSymbolConfiguration *glyph =
        [UIImageSymbolConfiguration configurationWithPointSize:14.0
                                                        weight:UIImageSymbolWeightSemibold];
    UIButton *control = [UIButton buttonWithType:UIButtonTypeSystem];
    control.tag = increment ? 1 : -1;
    control.tintColor = YTzoomAccentColor();
    [control setImage:[UIImage systemImageNamed:increment ? @"plus" : @"minus"
                              withConfiguration:glyph]
             forState:UIControlStateNormal];
    [control.widthAnchor constraintEqualToConstant:30.0].active = YES;
    objc_setAssociatedObject(control, YTzoomStepTargetAssociation, slider,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [control addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    return control;
}

static NSString *YTzoomTrimmedNumber(double value) {
    NSString *text = [NSString stringWithFormat:@"%.2f", value];
    while ([text containsString:@"."] && [text hasSuffix:@"0"]) {
        text = [text substringToIndex:text.length - 1];
    }
    if ([text hasSuffix:@"."]) text = [text substringToIndex:text.length - 1];
    return text;
}

static NSString *YTzoomSliderValueText(NSDictionary *item, double value) {
    NSString *unit = item[@"unit"];
    if ([unit isEqualToString:@"percent"]) {
        return [NSString stringWithFormat:@"%.0f%%", value];
    }
    if ([unit isEqualToString:@"speed"]) {
        return [YTzoomTrimmedNumber(value) stringByAppendingString:@"x"];
    }
    return [NSString stringWithFormat:YTzoomLocalized(@"%@ seconds"),
            [NSString stringWithFormat:@"%.0f", value]];
}

static NSDictionary *YTzoomColor(NSString *title,
                                 NSString *key,
                                 NSString *fallback) {
    return @{
        @"type": @"color",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"key": key,
        @"fallback": fallback
    };
}

static NSDictionary *YTzoomColorDetail(NSString *title, NSString *subtitle, NSString *key, NSString *fallback) {
    NSMutableDictionary *item = [YTzoomColor(title, key, fallback) mutableCopy];
    item[@"subtitle"] = YTzoomLocalized(subtitle ?: @"");
    return item;
}

static NSString *YTzoomHexFromColor(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#00D400";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lround(red * 255.0), (int)lround(green * 255.0),
            (int)lround(blue * 255.0)];
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

static NSDictionary *YTzoomActionDetail(NSString *title,
                                         NSString *subtitle,
                                         YTzoomAction action) {
    return @{
        @"type": @"action",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"subtitle": YTzoomLocalized(subtitle ?: @""),
        @"asset": @"",
        @"symbol": @"",
        @"action": [action copy]
    };
}

static NSDictionary *YTzoomTextEntry(NSString *title,
                                      NSString *subtitle,
                                      NSString *key,
                                      NSString *placeholder,
                                      BOOL secure) {
    return @{
        @"type": @"entry",
        @"title": YTzoomLocalized(title),
        @"en": title,
        @"subtitle": YTzoomLocalized(subtitle ?: @""),
        @"key": key,
        @"placeholder": placeholder ?: @"",
        @"secure": @(secure),
        @"asset": @"",
        @"symbol": @""
    };
}

static NSString *YTzoomTextEntrySummary(NSDictionary *item) {
    id stored = YTzoomPreferenceObject(item[@"key"]);
    NSString *value = [stored isKindOfClass:NSString.class] ? stored : @"";
    if (value.length == 0) {
        return [item[@"secure"] boolValue] ? YTzoomLocalized(@"Not Set") : item[@"placeholder"];
    }
    if (![item[@"secure"] boolValue]) return value;
    return value.length > 4
        ? [@"••••" stringByAppendingString:[value substringFromIndex:value.length - 4]]
        : @"••••";
}

static UIColor *YTzoomSettingsBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTzoomInterfaceBackgroundColor(traits);
    }];
}

static UIColor *YTzoomSettingsCellBackground(void) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        return YTzoomInterfaceBackgroundColor(traits);
    }];
}

BOOL YTzoomPreferenceNeedsRestart(NSString *key) {
    return [@[
        YTzoomOLEDKey,
        @"YTzoom.Preference.Navigation.PremiumLogo",
        @"YTzoom.Preference.Navigation.LogoHidden",
        @"YTzoom.Preference.App.LayoutIdiom",
        @"YTzoom.Preference.App.RTLDisabled",
        @"YTzoom.Preference.Playback.LegacyQualityMenu",
        @"YTzoom.Preference.Navigation.StatusBarHidden",
        @"YTzoom.Preference.Tabs.Glass",
        @"YTzoom.Preference.Glass.TopBar",
        @"YTzoom.Preference.Glass.Menus",
        @"YTzoom.Preference.Glass.Notices",
        @"YTzoom.Preference.Glass.Player",
        @"YTzoom.Preference.Tabs.Startup",
        @"YTzoom.Preference.Playback.CaptionsAlwaysOn",
        @"YTzoom.Preference.Playback.CaptionsMode",
        @"YTzoom.Preference.Feed.HomeTabsHidden",
        @"YTzoom.Preference.Language",
        @"YTzoom.Preference.Navigation.NotificationsHidden",
        YTzoomMoshCameraKey,
        YTzoomRegionCountryKey,
        YTzoomRegionLanguageKey,
        YTzoomRegionTimeZoneKey,
        YTzoomRegionLocaleKey
    ] containsObject:key];
}

void YTzoomShowRestartNotice(UIViewController *controller) {
    UIView *host = controller.navigationController.view ?: controller.view;
    UIView *old = [host viewWithTag:0x594B524E];
    [old removeFromSuperview];
    UIView *notice = [UIView new];
    notice.tag = 0x594B524E;
    notice.backgroundColor = [UIColor colorWithWhite:0.72 alpha:0.96];
    notice.layer.cornerRadius = 8.0;
    notice.layer.masksToBounds = YES;
    notice.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *label = [UILabel new];
    label.text = YTzoomLocalized(@"Your changes take effect once YouTube restarts.");
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:13.0];
    label.numberOfLines = 2;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [notice addSubview:label];
    if (YTzoomApplyGlassBackground(notice, NO)) notice.layer.cornerRadius = 16.0;
    [host addSubview:notice];
    UILayoutGuide *safe = host.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [notice.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8.0],
        [notice.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8.0],
        [notice.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8.0],
        [notice.heightAnchor constraintEqualToConstant:48.0],
        [label.leadingAnchor constraintEqualToAnchor:notice.leadingAnchor constant:14.0],
        [label.trailingAnchor constraintEqualToAnchor:notice.trailingAnchor constant:-14.0],
        [label.centerYAnchor constraintEqualToAnchor:notice.centerYAnchor]
    ]];
    notice.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 1.0; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ notice.alpha = 0.0; }
                         completion:^(__unused BOOL finished) { [notice removeFromSuperview]; }];
    });
}

static void YTzoomStorePickerValue(NSString *key, id value,
                                   __unused NSUInteger index) {
    YTzoomSetPreferenceObject(key, value);
}

static UIImage *YTzoomBlankChoiceIcon(void) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(24.0, 24.0), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

void YTzoomPresentSelectionMenu(UIViewController *presenter,
                                UIView *sourceView,
                                NSString *title,
                                NSArray<NSString *> *titles,
                                NSUInteger selectedIndex,
                                YTzoomChoiceHandler handler) {
    (void)title;
    (void)sourceView;
    if (titles.count == 0) {
        return;
    }
    selectedIndex = MIN(selectedIndex, titles.count - 1);
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL makeAction = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    id sheet = [actionClass respondsToSelector:makeAction] ? YTzoomMakeSheet(nil, nil) : nil;
    if (sheet != nil) {
        UIImage *check = [[UIImage systemImageNamed:@"checkmark"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        UIImage *blank = YTzoomBlankChoiceIcon();
        [titles enumerateObjectsUsingBlock:^(NSString *choice, NSUInteger index, BOOL *stop) {
            (void)stop;
            dispatch_block_t selection = ^{
                if (handler != nil) {
                    handler(index);
                }
            };
            id action = ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
                actionClass, makeAction, choice,
                index == selectedIndex ? check : blank, 0, selection);
            SEL addAction = NSSelectorFromString(@"addAction:");
            if ([sheet respondsToSelector:addAction]) {
                ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
            }
        }];
        YTzoomShowSheet(sheet, presenter);
        return;
    }
    YTzoomShowNotice(YTzoomLocalized(@"YouTube menu unavailable"));
}

void YTzoomPresentChoiceMenu(UIViewController *presenter,
                             UIView *sourceView,
                             NSString *title,
                             NSArray<NSString *> *titles,
                             NSArray *values,
                             NSString *key,
                             NSUInteger defaultIndex,
                             YTzoomChoiceHandler handler) {
    id selected = YTzoomPreferenceObject(key);
    NSUInteger selectedIndex = [values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(defaultIndex, values.count - 1);
    }
    YTzoomPresentSelectionMenu(presenter, sourceView, title, titles, selectedIndex,
        ^(NSUInteger index) {
            YTzoomStorePickerValue(key, values[index], index);
            if (([key isEqualToString:@"YTzoom.Preference.Gestures.BrightnessSide"] ||
                 [key isEqualToString:@"YTzoom.Preference.Gestures.VolumeSide"]) && index < 2) {
                NSString *otherKey = [key isEqualToString:@"YTzoom.Preference.Gestures.BrightnessSide"]
                    ? @"YTzoom.Preference.Gestures.VolumeSide" : @"YTzoom.Preference.Gestures.BrightnessSide";
                id otherValue = YTzoomPreferenceObject(otherKey);
                NSInteger otherSide = otherValue == nil
                    ? ([otherKey isEqualToString:@"YTzoom.Preference.Gestures.BrightnessSide"] ? 1 : 0)
                    : [otherValue integerValue];
                if (otherSide == [values[index] integerValue] || otherSide == 3) {
                    YTzoomStorePickerValue(otherKey, @([values[index] integerValue] == 0),
                                           [values[index] integerValue] == 0 ? 1 : 0);
                }
            }
            if ([key isEqualToString:@"YTzoom.Preference.Gestures.VolumeSide"] &&
                [values[index] integerValue] == 3) {
                YTzoomStorePickerValue(@"YTzoom.Preference.Gestures.BrightnessSide", @2, 2);
            }
            if (handler != nil) handler(index);
        });
}

NSString *YTzoomPickerSummary(NSString *key,
                              NSArray<NSString *> *titles,
                              NSArray *values,
                              NSUInteger defaultIndex) {
    id selected = YTzoomPreferenceObject(key);
    NSUInteger index = [values indexOfObject:selected];
    if (index == NSNotFound || index >= titles.count) {
        index = MIN(defaultIndex, titles.count - 1);
    }
    return titles.count == 0 ? @"" : titles[index];
}

@interface YTzoomPickerController : UITableViewController
- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex;
@end

@implementation YTzoomPickerController {
    NSString *_preferenceKey;
    NSArray<NSString *> *_titles;
    NSArray *_values;
    NSUInteger _defaultIndex;
}

- (instancetype)initWithTitle:(NSString *)title
                           key:(NSString *)key
                        titles:(NSArray<NSString *> *)titles
                        values:(NSArray *)values
                  defaultIndex:(NSUInteger)defaultIndex {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _preferenceKey = [key copy];
        _titles = [titles copy];
        _values = [values copy];
        _defaultIndex = defaultIndex;
    }
    return self;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTzoomOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTzoomApplyAppearance(self);
    self.tableView.backgroundColor = YTzoomSettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    return (NSInteger)_titles.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *identifier = @"YTzoomPickerCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:identifier];
    }
    id selected = YTzoomPreferenceObject(_preferenceKey);
    NSUInteger selectedIndex = [_values indexOfObject:selected];
    if (selectedIndex == NSNotFound) {
        selectedIndex = MIN(_defaultIndex, _values.count - 1);
    }
    cell.textLabel.text = _titles[(NSUInteger)indexPath.row];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.textLabel.textColor = UIColor.labelColor;
    cell.backgroundColor = YTzoomSettingsCellBackground();
    cell.accessoryType = (NSUInteger)indexPath.row == selectedIndex
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id value = _values[(NSUInteger)indexPath.row];
    YTzoomStorePickerValue(_preferenceKey, value, (NSUInteger)indexPath.row);
    [tableView reloadData];
}

@end

@interface YTzoomOptionsController : UITableViewController
    <UIDocumentPickerDelegate, UIColorPickerViewControllerDelegate>
- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles;
- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles;
@end

@implementation YTzoomOptionsController {
    NSArray<NSArray<NSDictionary *> *> *_sections;
    NSArray<NSString *> *_sectionTitles;
    NSInteger _pickerMode;
    NSString *_importCategory;
    NSString *_colorKey;
    NSIndexPath *_colorPath;
    UIView *_backupOverlay;
    UILabel *_backupOverlayLabel;
    NSURL *_pendingBackupURL;
    BOOL _backupRunning;
    BOOL _restoreRunning;
}

- (instancetype)initWithTitle:(NSString *)title
                      sections:(NSArray<NSArray<NSDictionary *> *> *)sections
                sectionTitles:(NSArray<NSString *> *)sectionTitles {
    self = [super initWithStyle:UITableViewStylePlain];
    if (self != nil) {
        self.title = title;
        _sections = [sections copy];
        _sectionTitles = [sectionTitles copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 50.0;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0.0;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (YTzoomOwnsNavigationController(self.navigationController)) {
        [self.navigationController setNavigationBarHidden:NO animated:NO];
    }
    YTzoomApplyAppearance(self);
    self.tableView.backgroundColor = YTzoomSettingsBackground();
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    return (NSInteger)_sections[(NSUInteger)section].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if ((NSUInteger)section >= _sectionTitles.count) {
        return nil;
    }
    NSString *title = _sectionTitles[(NSUInteger)section];
    return title.length == 0 ? nil : title;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    NSString *title = (NSUInteger)section < _sectionTitles.count
        ? _sectionTitles[(NSUInteger)section]
        : @"";
    return title.length == 0 ? 18.0 : 38.0;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    if ([type isEqualToString:@"text"]) {
        return 92.0;
    }
    if ([type isEqualToString:@"slider"]) {
        return [item[@"stacked"] boolValue] ? 78.0 : 58.0;
    }
    if ([type isEqualToString:@"segmented"] && [item[@"stacked"] boolValue]) {
        return 74.0;
    }
    return [item[@"subtitle"] length] == 0 ? 40.0 : 56.0;
}

- (void)tableView:(UITableView *)tableView
willDisplayHeaderView:(UIView *)view
        forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    if ([view isKindOfClass:UITableViewHeaderFooterView.class]) {
        UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
        header.textLabel.font = [UIFont systemFontOfSize:11.0 weight:UIFontWeightRegular];
        header.textLabel.textColor = UIColor.secondaryLabelColor;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    UITableViewCellStyle style;
    if ([type isEqualToString:@"picker"]) {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleValue1
            : UITableViewCellStyleSubtitle;
    } else {
        style = [item[@"subtitle"] length] == 0
            ? UITableViewCellStyleDefault
            : UITableViewCellStyleSubtitle;
    }
    NSString *identifier = [NSString stringWithFormat:@"YTzoomOption-%ld", (long)style];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:identifier];
    }

    [[cell.contentView viewWithTag:8801] removeFromSuperview];
    [[cell.contentView viewWithTag:8802] removeFromSuperview];
    [[cell.contentView viewWithTag:4271] removeFromSuperview];

    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"subtitle"];
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12.0];
    cell.textLabel.numberOfLines = 1;
    cell.detailTextLabel.numberOfLines = 2;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.backgroundColor = YTzoomSettingsCellBackground();
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    cell.imageView.image = nil;

    if ([type isEqualToString:@"toggle"]) {
        UISwitch *toggle = [UISwitch new];
        toggle.transform = CGAffineTransformMakeScale(0.95, 0.95);
        toggle.onTintColor = YTzoomAccentColor();
        id stored = YTzoomPreferenceObject(item[@"key"]);
        toggle.on = [stored respondsToSelector:@selector(boolValue)] && [stored boolValue];
        objc_setAssociatedObject(toggle,
                                 YTzoomItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [toggle addTarget:self
                   action:@selector(toggleChanged:)
         forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"segmented"]) {
        UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:item[@"titles"]];
        id selected = YTzoomPreferenceObject(item[@"key"]);
        NSUInteger selectedIndex = [item[@"values"] indexOfObject:selected];
        control.selectedSegmentIndex = selectedIndex == NSNotFound
            ? [item[@"default"] unsignedIntegerValue]
            : selectedIndex;
        objc_setAssociatedObject(control,
                                 YTzoomItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [control addTarget:self
                    action:@selector(segmentChanged:)
          forControlEvents:UIControlEventValueChanged];
        if ([item[@"stacked"] boolValue]) {
            UILabel *caption = [UILabel new];
            caption.tag = 8802;
            caption.text = item[@"title"];
            caption.font = [UIFont systemFontOfSize:16.0];
            caption.textColor = UIColor.labelColor;
            caption.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:caption];
            control.tag = 8801;
            control.translatesAutoresizingMaskIntoConstraints = NO;
            [cell.contentView addSubview:control];
            UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
            [NSLayoutConstraint activateConstraints:@[
                [caption.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [caption.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [caption.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                  constant:8.0],
                [control.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
                [control.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
                [control.topAnchor constraintEqualToAnchor:caption.bottomAnchor
                                                  constant:8.0],
                [control.heightAnchor constraintEqualToConstant:30.0]
            ]];
            cell.textLabel.text = nil;
            cell.accessoryView = nil;
        } else {
            CGFloat width = MAX(128.0, [item[@"titles"] count] * 68.0);
            control.frame = CGRectMake(0.0, 0.0, width, 30.0);
            cell.accessoryView = control;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"stepper"]) {
        double stored = [YTzoomPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        cell.textLabel.text = YTzoomStepperText(item, value);
        UIStepper *stepper = [UIStepper new];
        stepper.tintColor = YTzoomAccentColor();
        stepper.minimumValue = [item[@"minimum"] doubleValue];
        stepper.maximumValue = [item[@"maximum"] doubleValue];
        stepper.stepValue = [item[@"step"] doubleValue];
        stepper.value = value;
        objc_setAssociatedObject(stepper,
                                 YTzoomItemAssociation,
                                 item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(stepper,
                                 YTzoomValueLabelAssociation,
                                 cell,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [stepper addTarget:self
                    action:@selector(stepperChanged:)
          forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = stepper;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"] && [item[@"stacked"] boolValue]) {
        double stored = [YTzoomPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];

        UILabel *caption = [UILabel new];
        caption.text = item[@"title"];
        caption.font = [UIFont systemFontOfSize:16.0];
        caption.textColor = UIColor.labelColor;

        UILabel *readout = [UILabel new];
        readout.font = [UIFont monospacedDigitSystemFontOfSize:15.0
                                                        weight:UIFontWeightSemibold];
        readout.textColor = YTzoomAccentColor();
        readout.textAlignment = NSTextAlignmentRight;
        readout.text = YTzoomSliderValueText(item, value);
        [readout setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                 forAxis:UILayoutConstraintAxisHorizontal];

        UISlider *slider = [UISlider new];
        slider.minimumTrackTintColor = YTzoomAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        objc_setAssociatedObject(slider, YTzoomItemAssociation, item,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, YTzoomValueLabelAssociation, readout,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self
                   action:@selector(sliderChanged:)
         forControlEvents:UIControlEventValueChanged];

        UIStackView *heading = [[UIStackView alloc] initWithArrangedSubviews:@[caption, readout]];
        heading.axis = UILayoutConstraintAxisHorizontal;
        heading.spacing = 8.0;

        UIStackView *track = [[UIStackView alloc] initWithArrangedSubviews:@[
            YTzoomStepControl(NO, slider, self, @selector(sliderStepped:)),
            slider,
            YTzoomStepControl(YES, slider, self, @selector(sliderStepped:))
        ]];
        track.axis = UILayoutConstraintAxisHorizontal;
        track.alignment = UIStackViewAlignmentCenter;
        track.spacing = 10.0;

        UIStackView *container = [[UIStackView alloc] initWithArrangedSubviews:@[heading, track]];
        container.tag = 4271;
        container.axis = UILayoutConstraintAxisVertical;
        container.spacing = 6.0;
        container.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:container];

        UILayoutGuide *guide = cell.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:guide.leadingAnchor],
            [container.trailingAnchor constraintEqualToAnchor:guide.trailingAnchor],
            [container.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor
                                                constant:8.0],
            [container.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor
                                                   constant:-8.0]
        ]];
        cell.textLabel.text = nil;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"slider"]) {
        double stored = [YTzoomPreferenceObject(item[@"key"]) doubleValue];
        double value = stored > 0.0 ? stored : [item[@"fallback"] doubleValue];
        UIView *accessory = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 46.0)];
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0.0, 0.0, 158.0, 30.0)];
        slider.minimumTrackTintColor = YTzoomAccentColor();
        slider.minimumValue = [item[@"minimum"] floatValue];
        slider.maximumValue = [item[@"maximum"] floatValue];
        slider.value = (float)value;
        UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(0.0, 28.0, 158.0, 14.0)];
        valueLabel.font = [UIFont systemFontOfSize:10.0];
        valueLabel.textColor = UIColor.tertiaryLabelColor;
        valueLabel.textAlignment = NSTextAlignmentRight;
        valueLabel.text = YTzoomSliderValueText(item, value);
        objc_setAssociatedObject(slider, YTzoomItemAssociation, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, YTzoomValueLabelAssociation, valueLabel, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [accessory addSubview:slider];
        [accessory addSubview:valueLabel];
        cell.accessoryView = accessory;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"picker"]) {
        NSString *summary = YTzoomPickerSummary(
            item[@"key"],
            item[@"titles"],
            item[@"values"],
            [item[@"default"] unsignedIntegerValue]
        );
        if ([item[@"subtitle"] length] == 0) {
            cell.detailTextLabel.text = summary;
            cell.detailTextLabel.textColor = YTzoomAccentColor();
        } else {
            UILabel *value = [UILabel new];
            value.text = summary;
            value.font = [UIFont systemFontOfSize:15.0];
            value.textColor = YTzoomAccentColor();
            value.textAlignment = NSTextAlignmentRight;
            [value sizeToFit];
            cell.accessoryView = value;
        }
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = YTzoomPreferenceObject(item[@"key"]);
        UIColor *color = YTzoomColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 28.0, 28.0)];
        dot.backgroundColor = color;
        dot.layer.cornerRadius = 14.0;
        dot.layer.borderWidth = 2.0;
        dot.layer.borderColor = UIColor.secondaryLabelColor.CGColor;
        cell.accessoryView = dot;
    } else if ([type isEqualToString:@"entry"]) {
        UILabel *value = [UILabel new];
        value.text = YTzoomTextEntrySummary(item);
        value.font = [UIFont systemFontOfSize:15.0];
        value.textColor = YTzoomAccentColor();
        value.textAlignment = NSTextAlignmentRight;
        value.lineBreakMode = NSLineBreakByTruncatingMiddle;
        [value sizeToFit];
        CGRect frame = value.frame;
        frame.size.width = MIN(frame.size.width, 160.0);
        value.frame = frame;
        cell.accessoryView = value;
    } else if ([type isEqualToString:@"text"]) {
        cell.textLabel.font = [UIFont systemFontOfSize:10.0];
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTzoomItemAssociation);
    NSArray *values = item[@"values"];
    if ((NSUInteger)sender.selectedSegmentIndex < values.count) {
        YTzoomSetPreferenceObject(item[@"key"], values[(NSUInteger)sender.selectedSegmentIndex]);
        if (YTzoomPreferenceNeedsRestart(item[@"key"])) {
            YTzoomShowRestartNotice(self);
        }
    }
}

- (void)toggleChanged:(UISwitch *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTzoomItemAssociation);
    NSString *key = item[@"key"];
    YTzoomSetPreference(key, sender.isOn);
    if ([key isEqualToString:YTzoomOLEDKey]) {
        YTzoomApplyAppearance(self);
        self.tableView.backgroundColor = YTzoomSettingsBackground();
        [self.tableView reloadData];
    }
    if (YTzoomPreferenceNeedsRestart(key)) {
        YTzoomShowRestartNotice(self);
    }
}

- (void)stepperChanged:(UIStepper *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTzoomItemAssociation);
    UITableViewCell *cell = objc_getAssociatedObject(sender, YTzoomValueLabelAssociation);
    YTzoomSetPreferenceObject(item[@"key"], @(sender.value));
    cell.textLabel.text = YTzoomStepperText(item, sender.value);
}

- (void)sliderStepped:(UIButton *)sender {
    UISlider *slider = objc_getAssociatedObject(sender, YTzoomStepTargetAssociation);
    NSDictionary *item = objc_getAssociatedObject(slider, YTzoomItemAssociation);
    if (slider == nil || item == nil) return;
    const double step = MAX(0.01, [item[@"step"] doubleValue]);
    const double lower = [item[@"minimum"] doubleValue];
    const double upper = [item[@"maximum"] doubleValue];
    double shifted = slider.value + step * (double)sender.tag;
    shifted = MIN(upper, MAX(lower, shifted));
    slider.value = (float)shifted;
    [self sliderChanged:slider];
}

- (void)sliderChanged:(UISlider *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, YTzoomItemAssociation);
    UILabel *label = objc_getAssociatedObject(sender, YTzoomValueLabelAssociation);
    double step = MAX(0.01, [item[@"step"] doubleValue]);
    double value = round(round(sender.value / step) * step * 100.0) / 100.0;
    YTzoomSetPreferenceObject(item[@"key"], @(value));
    label.text = YTzoomSliderValueText(item, value);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = _sections[(NSUInteger)indexPath.section][(NSUInteger)indexPath.row];
    NSString *type = item[@"type"];
    UIViewController *controller = nil;
    if ([type isEqualToString:@"controller"]) {
        YTzoomControllerBuilder builder = item[@"builder"];
        controller = builder();
    } else if ([type isEqualToString:@"picker"]) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        YTzoomPresentChoiceMenu(self, cell, item[@"title"], item[@"titles"],
            item[@"values"], item[@"key"],
            [item[@"default"] unsignedIntegerValue], ^(__unused NSUInteger index) {
                NSString *key = item[@"key"];
                if ([key isEqualToString:@"YTzoom.Preference.Gestures.BrightnessSide"] ||
                    [key isEqualToString:@"YTzoom.Preference.Gestures.VolumeSide"]) {
                    [self.tableView reloadData];
                } else {
                    [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                          withRowAnimation:UITableViewRowAnimationNone];
                }
                if (YTzoomPreferenceNeedsRestart(item[@"key"])) {
                    YTzoomShowRestartNotice(self);
                }
            });
    } else if ([type isEqualToString:@"action"]) {
        YTzoomAction action = item[@"action"];
        action(self);
    } else if ([type isEqualToString:@"entry"]) {
        [self editTextEntry:item atIndexPath:indexPath];
    } else if ([type isEqualToString:@"color"]) {
        NSString *stored = YTzoomPreferenceObject(item[@"key"]);
        UIColorPickerViewController *picker = [UIColorPickerViewController new];
        picker.title = item[@"title"];
        picker.supportsAlpha = NO;
        picker.selectedColor = YTzoomColorFromHex(
            [stored isKindOfClass:NSString.class] ? stored : item[@"fallback"]);
        picker.delegate = self;
        _colorKey = [item[@"key"] copy];
        _colorPath = indexPath;
        [self presentViewController:picker animated:YES completion:nil];
    }
    if (controller != nil) {
        [self.navigationController pushViewController:controller animated:YES];
    }
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    if (_pickerMode == 3) {
        if (_pendingBackupURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
        }
        _pendingBackupURL = nil;
        _pickerMode = 0;
        return;
    }
    if (urls.count == 0) return;
    NSMutableArray<NSURL *> *scoped = [NSMutableArray array];
    for (NSURL *URL in urls) {
        if ([URL startAccessingSecurityScopedResource]) [scoped addObject:URL];
    }
    if (_pickerMode == 1) {
        _restoreRunning = YES;
        [self setBackupProgressVisible:YES message:YTzoomLocalized(@"Restoring Backup...")];
        [YTzoomBackupManager restoreBackupFromURL:urls.firstObject
            completion:^(NSError *error) {
                for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
                self->_restoreRunning = NO;
                [self setBackupProgressVisible:NO message:nil];
                [self showResult:error == nil ? YTzoomLocalized(@"Backup Restored") : YTzoomLocalized(@"Restore Failed")
                          message:error.localizedDescription];
            }];
        _pickerMode = 0;
        return;
    }
    NSString *category = _importCategory ?: YTzoomLocalized(@"Video");
    [YTzoomMediaImporter importURLs:urls category:category
        completion:^(NSUInteger count, NSError *error) {
            for (NSURL *URL in scoped) [URL stopAccessingSecurityScopedResource];
            NSString *message = error.localizedDescription ?: [NSString
                stringWithFormat:YTzoomLocalized(@"%lu items added to %@."),
                (unsigned long)count, category];
            [self showResult:error == nil ? YTzoomLocalized(@"Import Complete") : YTzoomLocalized(@"Import Failed")
                      message:message];
        }];
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    (void)continuously;
    if (_colorKey.length == 0 || color == nil) return;
    YTzoomSetPreferenceObject(_colorKey, YTzoomHexFromColor(color));
    if (_colorPath != nil) {
        [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    if (_colorKey.length != 0) {
        YTzoomSetPreferenceObject(_colorKey, YTzoomHexFromColor(viewController.selectedColor));
        if (_colorPath != nil) {
            [self.tableView reloadRowsAtIndexPaths:@[_colorPath]
                                  withRowAnimation:UITableViewRowAnimationNone];
        }
    }
    _colorKey = nil;
    _colorPath = nil;
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    (void)controller;
    NSInteger mode = _pickerMode;
    _pickerMode = 0;
    if (mode == 3) {
        if (_pendingBackupURL != nil) {
            [NSFileManager.defaultManager removeItemAtURL:_pendingBackupURL error:nil];
        }
        _pendingBackupURL = nil;
        NSString *message = YTzoomLocalized(@"The backup was not saved to the Files app.");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
                if (!YTzoomShowYouTubeDialog(YTzoomLocalized(@"Backup Not Saved"), message)) {
                    YTzoomShowNotice(YTzoomLocalized(@"Warning: Backup was not saved to Files app."));
                }
            });
    }
}

- (void)setBackupProgressVisible:(BOOL)visible message:(NSString *)message {
    if (!visible) {
        UIView *overlay = _backupOverlay;
        _backupOverlay = nil;
        _backupOverlayLabel = nil;
        [UIView animateWithDuration:0.18 animations:^{
            overlay.alpha = 0.0;
        } completion:^(__unused BOOL finished) {
            [overlay removeFromSuperview];
        }];
        return;
    }
    if (_backupOverlay != nil) {
        _backupOverlayLabel.text = message.length == 0 ? YTzoomLocalized(@"Please Wait...") : message;
        return;
    }
    UIView *host = self.navigationController.view ?: self.view;
    UIView *overlay = [UIView new];
    overlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
    overlay.translatesAutoresizingMaskIntoConstraints = NO;
    overlay.alpha = 0.0;

    UIView *card = [UIView new];
    card.backgroundColor = YTzoomInterfaceSurfaceColor(self.traitCollection);
    card.layer.cornerRadius = 12.0;
    card.layer.masksToBounds = YES;
    card.translatesAutoresizingMaskIntoConstraints = NO;

    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.color = UIColor.labelColor;
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];

    UILabel *label = [UILabel new];
    label.text = message.length == 0 ? YTzoomLocalized(@"Please Wait...") : message;
    label.textColor = UIColor.labelColor;
    label.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;

    [card addSubview:spinner];
    [card addSubview:label];
    [overlay addSubview:card];
    [host addSubview:overlay];
    [NSLayoutConstraint activateConstraints:@[
        [overlay.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [overlay.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [overlay.topAnchor constraintEqualToAnchor:host.topAnchor],
        [overlay.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [card.centerXAnchor constraintEqualToAnchor:overlay.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:overlay.centerYAnchor],
        [card.widthAnchor constraintEqualToConstant:190.0],
        [card.heightAnchor constraintEqualToConstant:94.0],
        [spinner.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [spinner.topAnchor constraintEqualToAnchor:card.topAnchor constant:17.0],
        [label.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12.0],
        [label.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-17.0]
    ]];
    _backupOverlay = overlay;
    _backupOverlayLabel = label;
    [UIView animateWithDuration:0.18 animations:^{ overlay.alpha = 1.0; }];
}

- (void)performBackup {
    if (_backupRunning) return;
    _backupRunning = YES;
    [self setBackupProgressVisible:YES message:YTzoomLocalized(@"Preparing Backup...")];
    __weak YTzoomOptionsController *weakSelf = self;
    [YTzoomBackupManager createBackupWithCompletion:^(NSURL *URL, NSError *error) {
        YTzoomOptionsController *controller = weakSelf;
        if (controller == nil) return;
        controller->_backupRunning = NO;
        [controller setBackupProgressVisible:NO message:nil];
        if (URL == nil || error != nil) {
            NSString *message = error.localizedDescription ?: YTzoomLocalized(@"The backup could not be created.");
            if (!YTzoomShowYouTubeDialog(YTzoomLocalized(@"Backup Failed"), message)) {
                [controller showResult:YTzoomLocalized(@"Backup Failed") message:message];
            }
            return;
        }
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
            initForExportingURLs:@[URL] asCopy:YES];
        controller->_pickerMode = 3;
        controller->_pendingBackupURL = URL;
        picker.delegate = controller;
        [controller presentViewController:picker animated:YES completion:nil];
    }];
}

- (void)beginBackup {
    if (_backupRunning) return;
    __weak YTzoomOptionsController *weakSelf = self;
    BOOL shown = YTzoomShowYouTubeConfirmation(
        @"YTzoom",
        YTzoomLocalized(@"Do you want to create a backup?"),
        YTzoomLocalized(@"Create"),
        ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf performBackup];
            });
        }
    );
    if (!shown) {
        YTzoomShowNotice(YTzoomLocalized(@"Backup confirmation unavailable"));
    }
}

- (void)beginRestore {
    if (_restoreRunning) return;
    _pickerMode = 1;
    UTType *zip = [UTType typeWithFilenameExtension:@"zip"] ?: UTTypeData;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[zip] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)beginImportForCategory:(NSString *)category {
    _pickerMode = 2;
    _importCategory = [category copy];
    NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObjects:
        UTTypeMovie, UTTypeAudio, UTTypeImage, nil];
    UTType *srt = [UTType typeWithFilenameExtension:@"srt"];
    UTType *vtt = [UTType typeWithFilenameExtension:@"vtt"];
    if (srt != nil) [types addObject:srt];
    if (vtt != nil) [types addObject:vtt];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)chooseImportCategory {
    YTzoomPresentChoiceMenu(self, self.view, YTzoomLocalized(@"Import Media"),
        @[YTzoomLocalized(@"Video"), YTzoomLocalized(@"Audio"), YTzoomLocalized(@"Shorts")],
        @[@"Video", @"Audio", @"Shorts"],
        @"YTzoomImportMediaType", 0, ^(NSUInteger index) {
            NSArray *categories = @[@"Video", @"Audio", @"Shorts"];
            [self beginImportForCategory:categories[index]];
        });
}

- (void)editTextEntry:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath {
    NSString *key = item[@"key"];
    id stored = YTzoomPreferenceObject(key);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                   message:item[@"subtitle"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = [stored isKindOfClass:NSString.class] ? stored : @"";
        field.placeholder = item[@"placeholder"];
        field.secureTextEntry = [item[@"secure"] boolValue];
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak YTzoomOptionsController *weakSelf = self;
    void (^store)(NSString *) = ^(NSString *value) {
        YTzoomSetPreferenceObject(key, value.length != 0 ? value : nil);
        [weakSelf.tableView reloadRowsAtIndexPaths:@[indexPath]
                                  withRowAnimation:UITableViewRowAnimationNone];
    };
    [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    if ([stored isKindOfClass:NSString.class] && [stored length] != 0) {
        [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Clear")
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            store(nil);
        }]];
    }
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Save")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        store([weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet]);
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showResult:(NSString *)title message:(NSString *)message {
    NSString *notice = message.length != 0
        ? [NSString stringWithFormat:@"%@\n%@", title, message] : title;
    YTzoomShowNotice(notice);
}

- (void)replaceSections:(NSArray<NSArray<NSDictionary *> *> *)sections
          sectionTitles:(NSArray<NSString *> *)sectionTitles {
    _sections = [sections copy];
    _sectionTitles = [sectionTitles copy];
    [self.tableView reloadData];
}

@end

UIViewController *YTzoomMakeSettingsResultsController(
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    return [[YTzoomOptionsController alloc] initWithTitle:@""
                                                 sections:sections
                                            sectionTitles:sectionTitles];
}

void YTzoomUpdateSettingsResultsController(UIViewController *controller,
        NSArray<NSArray<NSDictionary *> *> *sections,
        NSArray<NSString *> *sectionTitles) {
    if (![controller isKindOfClass:YTzoomOptionsController.class]) return;
    [(YTzoomOptionsController *)controller replaceSections:sections
                                            sectionTitles:sectionTitles];
}

static YTzoomOptionsController *YTzoomPage(NSString *title,
                                           NSArray *sections,
                                           NSArray *sectionTitles) {
    return [[YTzoomOptionsController alloc] initWithTitle:YTzoomLocalized(title)
                                                 sections:sections
                                           sectionTitles:YTzoomLocalizedList(sectionTitles)];
}

static NSArray<NSString *> *YTzoomQualityTitles(void) {
    return @[YTzoomLocalized(@"Auto"), @"2160p60", @"2160p", @"1440p60", @"1440p", @"1080p60",
             @"1080p", @"720p60", @"720p", @"480p", @"360p", @"240p", @"144p"];
}

static NSArray *YTzoomQualityValues(void) {
    return @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
}

static NSDictionary *YTzoomPageDefinition(NSString *pageID,
                                          NSString *title,
                                          NSArray *sections,
                                          NSArray *headers) {
    return @{
        @"id": pageID,
        @"title": title,
        @"sections": sections,
        @"headers": headers
    };
}

static YTzoomOptionsController *YTzoomPageFromDefinition(NSDictionary *definition) {
    return YTzoomPage(definition[@"title"],
                      definition[@"sections"],
                      definition[@"headers"]);
}

void YTzoomStartupDestinations(NSArray<NSString *> * _Nullable * _Nullable outTitles,
                               NSArray<NSString *> * _Nullable * _Nullable outValues) {
    NSArray<NSArray<NSString *> *> *destinations = @[
        @[@"", YTzoomLocalized(@"Default"), @""],
        @[@"home", YTzoomLocalized(@"Home"), @"YTzoom.Preference.Tabs.Hidden.Home"],
        @[@"explore", YTzoomLocalized(@"Explore"), @""],
        @[@"subscriptions", YTzoomLocalized(@"Subscriptions"), @"YTzoom.Preference.Tabs.Hidden.Subscriptions"],
        @[@"shorts", YTzoomLocalized(@"Shorts"), @"YTzoom.Preference.Tabs.Hidden.Shorts"],
        @[@"library", YTzoomLocalized(@"You"), @"YTzoom.Preference.Tabs.Hidden.Library"],
        @[@"ytzoom", @"YTzoom", @"YTzoom.Preference.Tabs.Hidden.YTzoomTab"],
        @[@"create", YTzoomLocalized(@"Create"), @"YTzoom.Preference.Tabs.Hidden.Create"],
        @[@"music", YTzoomLocalized(@"Music"), @"YTzoom.Preference.Tabs.Hidden.Music"],
        @[@"live", YTzoomLocalized(@"Live"), @"YTzoom.Preference.Tabs.Hidden.Live"],
        @[@"gaming", YTzoomLocalized(@"Gaming"), @"YTzoom.Preference.Tabs.Hidden.Gaming"],
        @[@"news", YTzoomLocalized(@"News"), @"YTzoom.Preference.Tabs.Hidden.News"],
        @[@"posts", YTzoomLocalized(@"Posts"), @"YTzoom.Preference.Tabs.Hidden.Posts"],
        @[@"sports", YTzoomLocalized(@"Sports"), @"YTzoom.Preference.Tabs.Hidden.Sports"],
        @[@"learning", YTzoomLocalized(@"Learning"), @"YTzoom.Preference.Tabs.Hidden.Learning"],
        @[@"fashion", YTzoomLocalized(@"Fashion"), @"YTzoom.Preference.Tabs.Hidden.Fashion"],
        @[@"playlists", YTzoomLocalized(@"Playlists"), @"YTzoom.Preference.Tabs.Hidden.Playlists"],
        @[@"history", YTzoomLocalized(@"History"), @"YTzoom.Preference.Tabs.Hidden.History"],
        @[@"notifications", YTzoomLocalized(@"Notifs"), @"YTzoom.Preference.Tabs.Hidden.Notifs"],
        @[@"watchlater", YTzoomLocalized(@"WLater"), @"YTzoom.Preference.Tabs.Hidden.WatchLater"]
    ];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *selected = [defaults stringForKey:@"YTzoom.Preference.Tabs.Startup"];
    NSArray<NSString *> *known = [defaults arrayForKey:@"YTzoom.Preference.Tabs.Known"];
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSString *> *values = [NSMutableArray array];
    for (NSArray<NSString *> *entry in destinations) {
        NSString *token = entry[0];
        NSString *hideKey = entry[2];
        BOOL hidden = hideKey.length != 0 && [defaults boolForKey:hideKey];
        NSString *canonical =
            [token isEqualToString:@"library"] ? @"you" : token;
        if (token.length != 0 && known.count != 0 &&
            ![known containsObject:canonical] && ![token isEqualToString:selected]) {
            continue;
        }
        if (hidden && ![token isEqualToString:selected]) continue;
        [titles addObject:entry[1]];
        [values addObject:token];
    }
    if (outTitles != NULL) *outTitles = titles;
    if (outValues != NULL) *outValues = values;
}

UIViewController *YTzoomMakeStartupPickerController(void) {
    NSArray<NSString *> *titles = nil;
    NSArray<NSString *> *values = nil;
    YTzoomStartupDestinations(&titles, &values);
    return [[YTzoomPickerController alloc]
        initWithTitle:YTzoomLocalized(@"Startup Page")
                   key:@"YTzoom.Preference.Tabs.Startup"
                titles:titles
                values:values
          defaultIndex:0];
}

UIViewController *YTzoomMakeWiFiQualityController(void) {
    return [[YTzoomPickerController alloc] initWithTitle:YTzoomLocalized(@"Wi-Fi Quality")
                                                    key:@"YTzoom.Preference.Playback.WiFiQuality"
                                                 titles:YTzoomQualityTitles()
                                                 values:YTzoomQualityValues()
                                           defaultIndex:0];
}

UIViewController *YTzoomMakeCellularQualityController(void) {
    return [[YTzoomPickerController alloc] initWithTitle:YTzoomLocalized(@"Cellular Quality")
                                                    key:@"YTzoom.Preference.Playback.CellularQuality"
                                                 titles:YTzoomQualityTitles()
                                                 values:YTzoomQualityValues()
                                           defaultIndex:0];
}

static NSDictionary *YTzoomSponsorBlockDefinition(void) {
    NSMutableArray *sections = [NSMutableArray arrayWithObject:@[
        YTzoomToggleDetail(@"SponsorBlock",
                           @"Skip or mark video segments. Set each category below.",
                           YTzoomSponsorBlockKey),
        YTzoomPickerDetail(@"Skip Notice", @"Shown after a segment is skipped.",
                     @"YTzoom.Preference.SponsorBlock.NotificationMode",
                     @[@"With Unskip", @"Text Only", @"Off"],
                     @[@0, @1, @2], 0),
        YTzoomToggleDetail(@"Skip Sound", @"Play a sound and vibrate when a segment is skipped.",
                           @"YTzoom.Preference.SponsorBlock.AudioFeedback"),
        YTzoomSlider(@"Notice Duration", @"YTzoom.Preference.SponsorBlock.SkipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0),
        YTzoomSlider(@"Unskip Duration", @"YTzoom.Preference.SponsorBlock.UnskipAlertSeconds",
                     1.0, 10.0, 1.0, 4.0)
    ]];
    NSMutableArray<NSString *> *titles = [NSMutableArray arrayWithObject:YTzoomLocalized(@"MAIN")];

    [sections addObject:@[
        YTzoomToggleDetail(@"DeArrow Thumbnails",
                           @"Replace clickbait thumbnails with community-picked "
                            "frames from DeArrow. Videos without a submission are "
                            "left untouched.",
                           YTzoomDeArrowThumbModeKey),
        YTzoomToggleDetail(@"DeArrow Titles",
                           @"Replace clickbait titles with community-written ones "
                            "from DeArrow. Videos without a submission keep their "
                            "original title.",
                           YTzoomDeArrowTitlesKey)
    ]];
    [titles addObject:YTzoomLocalized(@"DEARROW")];

    for (NSDictionary<NSString *, NSString *> *definition in
         YTzoomSponsorCategoryDefinitions()) {
        NSString *category = definition[@"id"];
        BOOL highlight = [category isEqualToString:@"poi_highlight"];
        [sections addObject:@[
            highlight
                ? YTzoomPicker(@"Behavior", YTzoomSponsorBehaviorKey(category),
                               @[@"Show Marker", @"Disabled"], @[@3, @2], 1, @"", @"")
                : YTzoomPicker(@"Behavior", YTzoomSponsorBehaviorKey(category),
                               @[@"Auto-skip", @"Ask", @"Show Marker", @"Disabled"],
                               @[@0, @1, @3, @2],
                               [category isEqualToString:@"sponsor"] ? 0 : 3,
                               @"", @""),
            YTzoomColor(@"Segment Color", YTzoomSponsorColorKey(category),
                        definition[@"color"])
        ]];
        [titles addObject:YTzoomLocalized([definition[@"title"] uppercaseString])];
    }
    return YTzoomPageDefinition(@"sponsorblock", @"SponsorBlock", sections, titles);
}

static NSDictionary *YTzoomPlayerDefinition(void) {
    return YTzoomPageDefinition(@"player", @"Player", @[
        @[
            YTzoomToggleDetail(@"PiP Button", @"Add a button that opens the video in picture in picture.", YTzoomPiPKey),
            YTzoomToggle(@"Loop Button", YTzoomLoopKey, @"", @""),
            YTzoomToggle(@"Sleep Timer Button", YTzoomSleepTimerKey, @"", @""),
            YTzoomToggle(@"Speed Button", YTzoomSpeedKey, @"", @""),
            YTzoomPickerDetail(@"Speed Button Style",
                @"Speed Menu shows the current speed and opens YouTube's speed menu with speeds up to 5x.",
                @"YTzoom.Preference.Player.SpeedButtonStyle",
                @[@"− / +", @"Speed Menu"], @[@0, @1], 0)
        ],
        @[
            YTzoomPicker(@"Default Playback Speed",
                         @"YTzoom.Preference.Player.StartRate",
                         @[@"Follow YouTube", @"Match last used", @"Custom"],
                         @[@0, @(-1), @(-2)], 0, @"", @""),
            YTzoomStackedSlider(@"Custom speed",
                                @"YTzoom.Preference.Player.CustomRate",
                                0.25, 5.0, 0.05, 1.0, @"speed"),
            YTzoomToggleDetail(@"Custom Hold Speed",
                               @"Change the speed used when you hold to speed up. "
                               @"Restart YouTube after changing.",
                               @"YTzoom.Preference.Player.HoldSpeedEnabled"),
            YTzoomStackedSlider(@"Hold speed",
                                @"YTzoom.Preference.Player.HoldSpeedRate",
                                0.25, 5.0, 0.25, 2.0, @"speed")
        ],
        @[
            YTzoomToggleDetail(@"Background Audio",
                               @"Keep playing when you leave the app or lock the screen.",
                               YTzoomBackgroundPlaybackKey),
            YTzoomToggleDetail(@"Stop Autoplay Next",
                               @"Do not roll into the next video when one ends.",
                               @"YTzoom.Preference.Playback.AutoplayDisabled"),
            YTzoomToggleDetail(@"Open Videos Paused",
                               @"Videos load without starting playback.",
                               @"YTzoom.Preference.Playback.OpenPaused"),
            YTzoomToggleDetail(@"Local Queue",
                               @"Play next and play last without Premium.",
                               @"YTzoom.Preference.Playback.LocalQueue"),
            YTzoomPickerDetail(@"Lock Screen Skip",
                @"Replace next and previous on the lock screen and in Control Center with skip buttons.",
                @"YTzoom.Preference.Playback.RemoteSkip",
                @[@"Off", @"10 seconds", @"15 seconds", @"30 seconds"], @[@0, @10, @15, @30], 0),
            YTzoomToggle(@"Remove Ads", YTzoomNoAdsKey, @"", @""),
            YTzoomPickerDetail(@"Playback Fix",
                @"Try this if videos won't load or keep buffering. Restart YouTube after changing.",
                @"YTzoom.Preference.Playback.FixMode",
                @[@"Off", @"Reload", @"HLS Streams"],
                @[@0, @1, @2], (NSUInteger)YTzoomPlaybackFixMode())
        ],
        @[
            YTzoomToggleDetail(@"Keep Controls Visible", @"Player controls never fade out.",
                               @"YTzoom.Preference.Overlay.AlwaysShowControls"),
            YTzoomToggle(@"Keep Play Button Visible", @"YTzoom.Preference.Overlay.AlwaysShowPlayPause", @"", @""),
            YTzoomToggle(@"Keep Timeline Visible", @"YTzoom.Preference.Overlay.ProgressAlwaysVisible", @"", @""),
            YTzoomToggleDetail(@"Remove Player Dimming",
                               @"Stop the video from darkening when the controls show.",
                               @"YTzoom.Preference.Overlay.DimmingRemoved"),
            YTzoomToggle(@"Show Status Bar in Fullscreen", @"YTzoom.Preference.Overlay.StatusBarVisible", @"", @""),
            YTzoomPickerDetail(@"Video Zoom",
                @"Stop pinch zoom at fill, or zoom past YouTube's 8x limit.",
                @"YTzoom.Preference.Playback.VideoZoom",
                @[@"Original", @"Cap to Fill", @"Unlimited"],
                @[@0, @1, @2], 0)
        ],
        @[
            YTzoomToggleDetail(@"Disable Previous/Next", @"Grey out previous and next so they can't be tapped.",
                               @"YTzoom.Preference.Overlay.PreviousNextDisabled"),
            YTzoomToggle(@"Smaller Previous/Next", @"YTzoom.Preference.Overlay.CompactPreviousNext", @"", @""),
            YTzoomToggle(@"Remove Previous/Next", @"YTzoom.Preference.Overlay.PreviousNextHidden", @"", @"")
        ],
        @[
            YTzoomToggle(@"Remove Play Button", @"YTzoom.Preference.Overlay.PlayPauseHidden", @"", @""),
            YTzoomToggle(@"Remove Settings Button", @"YTzoom.Preference.Overlay.MoreButtonHidden", @"", @""),
            YTzoomToggle(@"Remove Captions Button", @"YTzoom.Preference.Overlay.CaptionsButtonHidden", @"", @""),
            YTzoomToggle(@"Remove Cast Button", @"YTzoom.Preference.Overlay.CastHidden", @"", @""),
            YTzoomToggle(@"Remove Autoplay Switch", @"YTzoom.Preference.Overlay.AutoplayHidden", @"", @""),
            YTzoomToggle(@"Remove Info Cards", @"YTzoom.Preference.Overlay.InfoCardsHidden", @"", @""),
            YTzoomToggle(@"Remove Channel Watermark", @"YTzoom.Preference.Overlay.WatermarkHidden", @"", @""),
            YTzoomToggle(@"Remove End Screen", @"YTzoom.Preference.Overlay.EndScreenHidden", @"", @""),
            YTzoomToggleDetail(@"Remove Fullscreen Actions",
                               @"Hide the row of buttons under the progress bar in fullscreen.",
                               @"YTzoom.Preference.Overlay.FullscreenActionsHidden"),
            YTzoomToggle(@"Remove Quick Actions", @"YTzoom.Preference.Overlay.QuickActionsHidden", @"", @""),
            YTzoomToggle(@"Remove Continue Watching", @"YTzoom.Preference.Overlay.ContinueWatchingDisabled", @"", @"")
        ],
        @[
            YTzoomSegmentedStacked(@"Progress bar style", @"YTzoom.Preference.Progress.Style",
                                   @[@"Default", @"Solid color", @"Gradient"], @[@0, @1, @2], 0),
            YTzoomColor(@"Main color", @"YTzoom.Preference.Progress.MainColor", @"#FF0000"),
            YTzoomColorDetail(@"Gradient highlight", @"Used only with Gradient.",
                              @"YTzoom.Preference.Progress.HighlightColor", @"#8E8EFF"),
            YTzoomColorDetail(@"Scrubber color", @"Not used with the Default style.",
                              @"YTzoom.Preference.Progress.ScrubberColor", @"#FF0000")
        ]
    ], @[YTzoomLocalized(@"BUTTONS"), YTzoomLocalized(@"SPEED"), YTzoomLocalized(@"PLAYBACK"),
         YTzoomLocalized(@"CONTROLS"), YTzoomLocalized(@"PREVIOUS & NEXT"),
         YTzoomLocalized(@"HIDE FROM PLAYER"), YTzoomLocalized(@"PROGRESS BAR")]);
}

static NSDictionary *YTzoomQualityDefinition(void) {
    NSArray *qualities = @[@"Auto", @"2160p60", @"2160p", @"1440p60", @"1440p",
                           @"1080p60", @"1080p", @"720p60", @"720p", @"480p",
                           @"360p", @"240p", @"144p"];
    NSArray *values = @[@0, @1, @2, @3, @4, @5, @6, @7, @8, @9, @10, @11, @12];
    return YTzoomPageDefinition(@"quality", @"Video Quality", @[
        @[
            YTzoomPicker(@"Wi-Fi Quality", @"YTzoom.Preference.Playback.WiFiQuality",
                         qualities, values, 0, @"", @""),
            YTzoomPicker(@"Mobile Data Quality", @"YTzoom.Preference.Playback.CellularQuality",
                         qualities, values, 0, @"", @""),
            YTzoomToggleDetail(@"HD on Mobile Data", @"Remove YouTube's quality limit on mobile data.",
                               @"YTzoom.Preference.Playback.HDOnCellular")
        ],
        @[
            YTzoomToggleDetail(@"Classic Quality Menu", @"Show the full resolution list instead of YouTube's simple menu.",
                               @"YTzoom.Preference.Playback.LegacyQualityMenu"),
            YTzoomToggleDetail(@"Hide Premium Quality",
                               @"Removes 1080p Premium from the quality menu.",
                               @"YTzoom.Preference.Playback.PremiumQualityHidden"),
            YTzoomToggleDetail(@"Disable HDR",
                               @"Play videos in standard dynamic range.",
                               @"YTzoom.Preference.Playback.HDRDisabled")
        ]
    ], @[YTzoomLocalized(@"DEFAULT QUALITY"), YTzoomLocalized(@"QUALITY MENU")]);
}

static NSDictionary *YTzoomCaptionsDefinition(void) {
    return YTzoomPageDefinition(@"captions", @"Captions", @[
        @[
            YTzoomPickerDetail(@"Captions",
                @"Default follows YouTube. Restart YouTube after changing.",
                @"YTzoom.Preference.Playback.CaptionsMode",
                @[@"Default", @"Always On", @"Always Off"], @[@0, @1, @2], 0),
            YTzoomPickerDetail(@"Caption Language",
                         @"Turns captions on in this language when a video has them.",
                         @"YTzoom.Preference.Playback.CaptionLanguage",
                         @[@"Default", @"English", @"Spanish", @"Portuguese",
                           @"French", @"German", @"Italian", @"Dutch",
                           @"Polish", @"Turkish", @"Russian", @"Arabic",
                           @"Hindi", @"Indonesian", @"Vietnamese", @"Thai",
                           @"Japanese", @"Korean", @"Chinese"],
                         @[@"", @"en", @"es", @"pt", @"fr", @"de", @"it",
                           @"nl", @"pl", @"tr", @"ru", @"ar", @"hi", @"id",
                           @"vi", @"th", @"ja", @"ko", @"zh"],
                         0)
        ],
        @[
            YTzoomToggleDetail(@"Transcript Button",
                               @"Copy or share a video's captions from the player.",
                               @"YTzoom.Preference.Playback.Transcript")
        ]
    ], @[YTzoomLocalized(@"CAPTIONS"), YTzoomLocalized(@"TRANSCRIPT")]);
}

static NSDictionary *YTzoomWatchPageDefinition(void) {
    return YTzoomPageDefinition(@"watch", @"Watch Page", @[
        @[
            YTzoomToggle(@"Remove Suggested Videos", @"YTzoom.Preference.Overlay.SuggestedVideosHidden", @"", @""),
            YTzoomToggle(@"Remove Related Videos", @"YTzoom.Preference.Overlay.RelatedVideosHidden", @"", @""),
            YTzoomToggleDetail(@"Remove Comments", @"Hide the comments box under the video.",
                               @"YTzoom.Preference.Overlay.CommentsHidden"),
            YTzoomToggle(@"Remove Comment Preview", @"YTzoom.Preference.Overlay.CommentPreviewsHidden", @"", @""),
            YTzoomToggle(@"Remove Comment Guidelines", @"YTzoom.Preference.Overlay.CommentGuidelinesHidden", @"", @""),
            YTzoomToggle(@"Remove Paid Promotion Label", @"YTzoom.Preference.Overlay.PaidPromotionHidden", @"", @""),
            YTzoomToggleDetail(@"Remove Products", @"Hide shopping and product tags in videos, Shorts and feeds.",
                               @"YTzoom.Preference.Overlay.ProductsHidden")
        ],
        @[
            YTzoomToggle(@"Remove Like", @"YTzoom.Preference.ActionBar.LikeHidden", @"", @""),
            YTzoomToggle(@"Remove Dislike", @"YTzoom.Preference.ActionBar.DislikeHidden", @"", @""),
            YTzoomToggle(@"Remove Share", @"YTzoom.Preference.ActionBar.ShareHidden", @"", @""),
            YTzoomToggle(@"Remove Download", @"YTzoom.Preference.ActionBar.DownloadHidden", @"", @""),
            YTzoomToggle(@"Remove Save", @"YTzoom.Preference.ActionBar.SaveHidden", @"", @""),
            YTzoomToggle(@"Remove Clip", @"YTzoom.Preference.ActionBar.ClipHidden", @"", @""),
            YTzoomToggle(@"Remove Remix", @"YTzoom.Preference.ActionBar.RemixHidden", @"", @""),
            YTzoomToggle(@"Remove Thanks", @"YTzoom.Preference.ActionBar.ThanksHidden", @"", @""),
            YTzoomToggle(@"Remove Hype", @"YTzoom.Preference.ActionBar.HypeHidden", @"", @""),
            YTzoomToggle(@"Remove Report", @"YTzoom.Preference.ActionBar.ReportHidden", @"", @""),
            YTzoomToggle(@"Remove Ask Button", @"YTzoom.Preference.ActionBar.AskHidden", @"", @""),
            YTzoomToggle(@"Remove ⋯ Button", @"YTzoom.Preference.ActionBar.OverflowHidden", @"", @"")
        ]
    ], @[YTzoomLocalized(@"UNDER THE VIDEO"), YTzoomLocalized(@"ACTION BAR")]);
}

static NSDictionary *YTzoomFeedDefinition(void) {
    return YTzoomPageDefinition(@"feed", @"Home & Feed", @[
        @[
            YTzoomToggleDetail(@"Normal Home Layout",
                               @"Switches the tabbed Home redesign some accounts get back to the normal layout.",
                               @"YTzoom.Preference.Feed.HomeTabsHidden"),
            YTzoomToggleDetail(@"Remove Filter Chips", @"Hide the filter chips at the top of Home and Subscriptions.",
                               @"YTzoom.Preference.Navigation.TopicsHidden")
        ],
        @[
            YTzoomToggle(@"Remove Shorts Shelves", @"YTzoom.Preference.Shorts.FeedHidden", @"", @""),
            YTzoomToggleDetail(@"Keep Shorts in Subscriptions",
                @"Still show Shorts in the Subscriptions feed when shelves are removed.",
                @"YTzoom.Preference.Shorts.SubscriptionsKept"),
            YTzoomToggleDetail(@"Remove Horizontal Shelves",
                               @"Removes horizontal shelves like Watch again from the feed.",
                               @"YTzoom.Preference.Feed.HorizontalShelvesHidden"),
            YTzoomToggleDetail(@"Remove Community Posts",
                               @"Removes community posts from the feed.",
                               @"YTzoom.Preference.Feed.CommunityPostsHidden"),
            YTzoomToggleDetail(@"Remove Mixes",
                               @"Removes YouTube Mix playlists from the feed.",
                               @"YTzoom.Preference.Feed.MixesHidden"),
            YTzoomToggleDetail(@"Remove Playables",
                               @"Removes playable games from the feed.",
                               @"YTzoom.Preference.Feed.PlayablesHidden")
        ]
    ], @[YTzoomLocalized(@"HOME"), YTzoomLocalized(@"FEED")]);
}

static NSDictionary *YTzoomShortsOptionsDefinition(void) {
    return YTzoomPageDefinition(@"shorts", @"Shorts", @[
        @[
            YTzoomToggleDetail(@"Shorts Progress Bar", @"Show a thin progress line at the bottom of Shorts.", @"shortsProgress"),
            YTzoomToggle(@"Auto-Scroll to Next Short", @"autoSkipShorts", @"", @""),
            YTzoomToggleDetail(@"Play Shorts Once",
                               @"Pause at the end instead of replaying.",
                               @"YTzoom.Preference.Shorts.LoopDisabled"),
            YTzoomPicker(@"Shorts Speed", @"YTzoom.Preference.Shorts.PlaybackRate",
                         @[@"Same as videos", @"0.5x", @"0.75x", @"1x", @"1.25x",
                           @"1.5x", @"1.75x", @"2x"],
                         @[@0, @0.5, @0.75, @1, @1.25, @1.5, @1.75, @2], 0, @"", @""),
            YTzoomToggleDetail(@"Pinch to Fullscreen",
                               @"Pinch out in Shorts to hide the overlay and tab bar.",
                               @"YTzoom.Preference.Shorts.PinchFullscreen"),
            YTzoomToggle(@"Disable PiP for Shorts", @"YTzoom.Preference.Shorts.PiPDisabled", @"", @""),
            YTzoomPickerDetail(@"Download Button Position", @"Needs Download Button turned on in Downloads.",
                         @"YTzoom.Preference.Shorts.DownloadPosition",
                         @[@"Top Corner", @"Action Buttons"], @[@0, @1], 0)
        ],
        @[
            YTzoomToggleDetail(@"Limit Shorts",
                @"Stop scrolling after a set number of Shorts. Resets when YouTube restarts.",
                @"YTzoom.Preference.Shorts.LimitEnabled"),
            YTzoomCountStepper(@"Shorts limit", @"YTzoom.Preference.Shorts.LimitCount",
                               5.0, 200.0, 5.0, 20.0)
        ],
        @[
            YTzoomToggleDetail(@"Remove Pause Suggestions", @"Hide the videos shown when you pause a Short.",
                               @"YTzoom.Preference.Shorts.PauseCardHidden"),
            YTzoomToggle(@"Remove Sticker Ads", @"YTzoom.Preference.Shorts.StickerAdsHidden", @"", @""),
            YTzoomToggleDetail(@"Remove Suggestion Pill",
                               @"Hide the suggestion pill above a Short's title.",
                               @"YTzoom.Preference.Shorts.SuggestionPillHidden"),
            YTzoomToggle(@"Remove Like", @"YTzoom.Preference.Shorts.LikeHidden", @"", @""),
            YTzoomToggle(@"Remove Comments", @"YTzoom.Preference.Shorts.CommentsHidden", @"", @""),
            YTzoomToggle(@"Remove Share", @"YTzoom.Preference.Shorts.ShareHidden", @"", @""),
            YTzoomToggle(@"Remove Save", @"YTzoom.Preference.Shorts.SaveHidden", @"", @""),
            YTzoomToggle(@"Remove Remix", @"YTzoom.Preference.Shorts.RemixHidden", @"", @""),
            YTzoomToggle(@"Remove Sound Button", @"YTzoom.Preference.Shorts.SoundHidden", @"", @"")
        ],
        @[
            YTzoomToggleDetail(@"Invisible Interactive Stickers",
                @"Polls, questions and other interactive stickers you add stay tappable but aren't drawn in the editor or the uploaded Short.",
                @"YTzoom.Preference.Shorts.InvisibleStickers"),
            YTzoomPickerDetail(@"Sticker Max Size",
                @"Pinch interactive stickers past YouTube's 1.5x limit in the Shorts editor.",
                @"YTzoom.Preference.Shorts.StickerMaxScale",
                @[@"Original", @"3x", @"5x", @"10x", @"Unlimited"],
                @[@0, @3, @5, @10, @-1], 0),
            YTzoomToggleDetail(@"Unlimited Text & Image Stickers",
                @"Remove YouTube's cap on how many text and image stickers a Short can have.",
                @"YTzoom.Preference.Shorts.UnlimitedStickers"),
            YTzoomActionDetail(@"Text Sticker Font",
                @"Use a .ttf or .otf font from Files for every text sticker style.",
                ^(UIViewController *controller) {
                    YTzoomPresentStickerFontMenu(controller);
                }),
            YTzoomToggleDetail(@"Longer Polls",
                @"Allow up to 500 characters in poll questions and 200 in answers.",
                @"YTzoom.Preference.Shorts.LongerPolls"),
            YTzoomPickerDetail(@"Poll Answer Options",
                @"How many answers a new poll sticker can have.",
                @"YTzoom.Preference.Shorts.PollOptions",
                @[@"Original", @"6", @"10", @"20"],
                @[@0, @6, @10, @20], 0)
        ],
        @[
            YTzoomToggleDetail(@"Moshly Camera",
                @"Datamosh between clips in the Shorts camera: record a clip, line up the next one over its ghost, and the next clip smears out of it. Adds lens, stabilization, 60 fps and datamosh buttons to the camera.",
                YTzoomMoshCameraKey),
            YTzoomPickerDetail(@"Mosh Strength",
                @"How hard clips mosh into each other. 1 is clean.",
                @"YTzoom.Preference.Mosh.Intensity",
                @[@"1", @"2", @"3", @"4", @"5"], @[@1, @2, @3, @4, @5], 2),
            YTzoomToggleDetail(@"Ghost Preview",
                @"Show the last frame of the previous clip over the camera until you record again.",
                YTzoomMoshGhostKey),
            YTzoomToggleDetail(@"Record at 60 fps",
                @"Falls back to 30 fps on lenses that can't do 60.",
                YTzoomMoshHighFrameRateKey),
            YTzoomToggleDetail(@"Stabilization",
                @"Standard stabilization, on by default. It changes how the mosh moves.",
                YTzoomMoshStabilizationKey)
        ],
        @[
            YTzoomToggleDetail(@"Comments Toggle",
                @"Adds a comment button below the AI title button on the upload page. On sets Comments to Hold all, off sets it to Basic.",
                YTzoomHoldAllButtonKey),
            YTzoomTextEntry(@"\"Hold All\" Option Text",
                @"The option's name as YouTube shows it in the Comments menu. Change it if your YouTube isn't in English.",
                YTzoomHoldAllTextKey, @"Hold all", NO),
            YTzoomTextEntry(@"\"Basic\" Option Text",
                @"The name of the normal moderation option in the Comments menu.",
                YTzoomHoldAllBasicTextKey, @"Basic", NO)
        ]
    ], @[YTzoomLocalized(@"PLAYBACK"), YTzoomLocalized(@"SCREEN TIME"), YTzoomLocalized(@"HIDE FROM SHORTS"),
         YTzoomLocalized(@"CREATE"), YTzoomLocalized(@"MOSHLY CAMERA"), YTzoomLocalized(@"UPLOAD")]);
}

static NSDictionary *YTzoomTopBarDefinition(void) {
    return YTzoomPageDefinition(@"topbar", @"Top Bar", @[
        @[
            YTzoomToggle(@"Premium Logo", @"YTzoom.Preference.Navigation.PremiumLogo", @"", @""),
            YTzoomToggle(@"Remove YouTube Logo", @"YTzoom.Preference.Navigation.LogoHidden", @"", @"")
        ],
        @[
            YTzoomToggle(@"Remove Notifications Button", @"YTzoom.Preference.Navigation.NotificationsHidden", @"", @""),
            YTzoomToggle(@"Remove Messages Button", @"YTzoom.Preference.Navigation.MessagesHidden", @"", @""),
            YTzoomToggle(@"Remove Search Button", @"YTzoom.Preference.Navigation.SearchHidden", @"", @""),
            YTzoomToggle(@"Remove Account Button", @"YTzoom.Preference.Navigation.AccountHidden", @"", @""),
            YTzoomToggle(@"Remove Cast Button", @"YTzoom.Preference.Navigation.CastHidden", @"", @""),
            YTzoomToggleDetail(@"Confirm Before Casting", @"Ask before opening the Cast menu.",
                               @"YTzoom.Preference.Navigation.CastConfirmation")
        ],
        @[
            YTzoomToggle(@"Hide Status Bar", @"YTzoom.Preference.Navigation.StatusBarHidden", @"", @"")
        ]
    ], @[YTzoomLocalized(@"LOGO"), YTzoomLocalized(@"BUTTONS"), YTzoomLocalized(@"STATUS BAR")]);
}

static NSDictionary *YTzoomGlassOptionsDefinition(void) {
    return YTzoomPageDefinition(@"glass", @"Liquid Glass", @[
        @[
            YTzoomToggle(@"Tab Bar", @"YTzoom.Preference.Tabs.Glass", @"", @""),
            YTzoomToggle(@"Top Bar Buttons", @"YTzoom.Preference.Glass.TopBar", @"", @""),
            YTzoomToggle(@"Menus and Sheets", @"YTzoom.Preference.Glass.Menus", @"", @""),
            YTzoomToggle(@"YTzoom Toasts and Popups", @"YTzoom.Preference.Glass.Notices", @"", @""),
            YTzoomToggle(@"Player Buttons", @"YTzoom.Preference.Glass.Player", @"", @"")
        ],
        @[
            YTzoomToggleDetail(@"Shrink Tab Bar When Scrolling", @"Needs the Liquid Glass tab bar.",
                               @"YTzoom.Preference.Tabs.GlassMinimize"),
            YTzoomPicker(@"Selected Tab Color", @"YTzoom.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            YTzoomColor(@"Color", @"YTzoom.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[YTzoomLocalized(@"GLASS"), YTzoomLocalized(@"EXTRAS")]);
}

static NSDictionary *YTzoomGeneralDefinition(void) {
    NSMutableArray *languageTitles = [NSMutableArray array];
    for (NSString *code in YTzoomAvailableLanguages()) {
        [languageTitles addObject:[code isEqualToString:@"system"]
            ? @"System" : YTzoomLanguageDisplayName(code)];
    }
    return YTzoomPageDefinition(@"general", @"General", @[
        @[
            YTzoomPickerDetail(@"Language",
                @"Language for YTzoom menus. System follows your iPhone.",
                YTzoomLanguageKey, languageTitles, YTzoomAvailableLanguages(), 0)
        ],
        @[
            YTzoomToggleDetail(@"OLED Black", @"Pure black background in dark mode.", YTzoomOLEDKey),
            YTzoomPercentSlider(@"Extra Dim",
                                @"YTzoom.Preference.Appearance.ExtraDim",
                                0.0, 80.0, 5.0, 0.0),
            YTzoomToggleDetail(@"Skip Launch Animation", @"Starts YouTube faster.",
                               @"YTzoom.Preference.Appearance.LaunchAnimationDisabled"),
            YTzoomPickerDetail(@"Device Layout",
                @"Force the iPhone or iPad layout instead of following the device.",
                @"YTzoom.Preference.App.LayoutIdiom",
                @[@"Default", @"iPhone", @"iPad"],
                @[@0, @1, @2], 0),
            YTzoomToggleDetail(@"Force Left-to-Right Layout", @"Keep a left-to-right layout in right-to-left languages.",
                               @"YTzoom.Preference.App.RTLDisabled"),
            YTzoomToggleDetail(@"Block Drag and Drop", @"Stop thumbnails and text from being dragged.",
                               @"YTzoom.Preference.App.DragDropDisabled")
        ],
        @[
            YTzoomToggleDetail(@"Use iOS Share Sheet", @"Use the iOS share sheet instead of YouTube's.",
                               @"YTzoom.Preference.Sharing.NativeSheet"),
            YTzoomToggleDetail(@"Share at Current Time",
                               @"Links shared from the iOS share sheet start where you are in the video.",
                               @"YTzoom.Preference.Sharing.Timestamp"),
            YTzoomToggle(@"Hold Avatar to Enlarge", @"YTzoom.Preference.Profiles.Preview", @"", @""),
            YTzoomToggleDetail(@"Save Post Images",
                @"Adds a save button when you open an image from a community post.",
                @"YTzoom.Preference.Posts.SaveImage"),
            YTzoomToggleDetail(@"Hold to Copy Text", @"Hold a post or comment to copy its text.",
                               @"YTzoom.Preference.Posts.CopyText"),
            YTzoomToggleDetail(@"Mini Player for Kids Videos",
                @"Allow the mini player on made-for-kids videos.",
                @"YTzoom.Preference.Playback.KidsMiniPlayer")
        ],
        @[
            YTzoomToggleDetail(@"Remove Search History", @"Hides past searches. Searches are still saved.",
                               @"YTzoom.Preference.Privacy.SearchHistoryDisabled"),
            YTzoomToggleDetail(@"Block Premium Prompts", @"Also hides \"Are you still watching?\" and upgrade dialogs.",
                               @"YTzoom.Preference.Ads.PremiumPromosHidden"),
            YTzoomToggleDetail(@"Hide YouTube Pop-up Messages",
                @"Hides the small messages YouTube shows at the bottom, like Saved to Watch later.",
                @"YTzoom.Preference.App.HUDAlertsHidden"),
            YTzoomToggleDetail(@"Skip Age Gate", @"Skip the age check screen. Some videos may still be blocked.",
                               @"YTzoom.Preference.Content.AgeGateBypass")
        ]
    ], @[YTzoomLocalized(@"LANGUAGE"), YTzoomLocalized(@"APPEARANCE"), YTzoomLocalized(@"SHARING & EXTRAS"),
         YTzoomLocalized(@"PRIVACY & PROMPTS")]);
}

static NSDictionary *YTzoomDownloadsDefinition(void) {
    YTzoomAction backup = ^(UIViewController *controller) {
        [(YTzoomOptionsController *)controller beginBackup];
    };
    YTzoomAction restore = ^(UIViewController *controller) {
        [(YTzoomOptionsController *)controller beginRestore];
    };
    YTzoomAction importMedia = ^(UIViewController *controller) {
        [(YTzoomOptionsController *)controller chooseImportCategory];
    };
    YTzoomAction clearCache = ^(UIViewController *controller) {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSURL *cache = [YTzoomApplicationSupportDirectory()
            URLByAppendingPathComponent:@"Cache"
                            isDirectory:YES];
        NSUInteger freed = 0;
        NSDirectoryEnumerator *walker = [manager enumeratorAtURL:cache
            includingPropertiesForKeys:@[NSURLTotalFileAllocatedSizeKey]
                               options:0 errorHandler:nil];
        for (NSURL *child in walker) {
            NSNumber *size = nil;
            [child getResourceValue:&size forKey:NSURLTotalFileAllocatedSizeKey
                              error:nil];
            freed += size.unsignedIntegerValue;
        }
        [manager removeItemAtURL:cache error:nil];
        freed += YTzoomPurgeDownloadScratch(YES);
        freed += YTzoomPurgeSystemCaches();
        NSString *summary = freed == 0
            ? YTzoomLocalized(@"Nothing to clear.")
            : [NSString stringWithFormat:YTzoomLocalized(@"Freed %@."),
               [NSByteCountFormatter stringFromByteCount:(long long)freed
                   countStyle:NSByteCountFormatterCountStyleFile]];
        [(YTzoomOptionsController *)controller
            showResult:YTzoomLocalized(@"Cache Cleared") message:summary];
    };
    return YTzoomPageDefinition(@"downloads", @"Downloads", @[
        @[
            YTzoomPickerDetail(@"Download Button",
                         @"Off turns off all downloads, including Shorts and playlists.",
                         @"YTzoom.Preference.Downloads.Placement",
                         @[@"Off", @"Player overlay", @"YouTube's button", @"Both"],
                         @[@0, @1, @2, @3], 0),
            YTzoomToggle(@"Playlist Download Button",
                         @"YTzoom.Preference.Downloads.PlaylistEnabled", @"", @""),
            YTzoomPicker(@"Save Videos To",
                         @"YTzoom.Preference.Downloads.SaveLocation",
                         @[@"YTzoom Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            YTzoomPicker(@"Save Audio To",
                         @"YTzoom.Preference.Downloads.AudioSaveLocation",
                         @[@"YTzoom Library", @"Photos", @"Ask", @"Share Sheet"],
                         @[@0, @1, @2, @3], 0, @"", @""),
            YTzoomToggleDetail(@"Include Subtitles",
                               @"Embed captions into downloaded videos.",
                               @"YTzoom.Preference.Downloads.Subtitles"),
            YTzoomPickerDetail(@"Download Method",
                @"SABR is the default. Use TV Client or Direct if downloads fail.",
                @"YTzoom.Preference.Downloads.Method",
                @[@"SABR", @"TV Client", @"Direct"], @[@0, @2, @1], 0)
        ],
        @[
            YTzoomActionDetail(@"Back Up", @"Save settings and media to a ZIP file.", backup),
            YTzoomActionDetail(@"Restore", @"Open a YTzoom backup from Files.", restore),
            YTzoomActionDetail(@"Import", @"Add video, audio, Shorts, artwork, or subtitles.", importMedia)
        ],
        @[
            YTzoomToggleDetail(@"Clear Cache at Launch", @"Clear cache when YouTube opens, at most once a day.",
                               @"YTzoom.Preference.Downloads.ClearOnStartup"),
            YTzoomActionDetail(@"Clear Cache Now", @"Delete temporary files and YouTube's cache.", clearCache)
        ]
    ], @[YTzoomLocalized(@"DOWNLOADS"), YTzoomLocalized(@"BACKUP"), YTzoomLocalized(@"STORAGE")]);
}

static NSDictionary *YTzoomGestureOptionsDefinition(void) {
    NSArray *actionTitles = @[@"None", @"Brightness", @"Volume", @"Brightness + Volume"];
    NSArray *actionValues = @[@0, @1, @2, @3];
    return YTzoomPageDefinition(@"gestures", @"Gestures", @[
        @[
            YTzoomPicker(@"Left Side", @"YTzoom.Preference.Gestures.LeftAction",
                         actionTitles, actionValues, 0, @"", @""),
            YTzoomPicker(@"Right Side", @"YTzoom.Preference.Gestures.RightAction",
                         actionTitles, actionValues, 0, @"", @""),
            YTzoomPercentSlider(@"Edge Width",
                                @"YTzoom.Preference.Gestures.ActivationArea",
                                10.0, 50.0, 5.0, 20.0),
            YTzoomToggleDetail(@"Landscape Only",
                               @"Disable gestures while the player is in portrait.",
                               @"YTzoom.Preference.Gestures.LandscapeOnly")
        ],
        @[
            YTzoomToggleDetail(@"Level Indicator",
                               @"Show the current brightness or volume level.",
                               @"YTzoom.Preference.Gestures.HUDEnabled"),
            YTzoomPicker(@"Indicator Size", @"YTzoom.Preference.Gestures.HUDSize",
                         @[@"Compact", @"Standard", @"Large"], @[@0, @1, @2],
                         1, @"", @""),
            YTzoomPicker(@"Indicator Position", @"YTzoom.Preference.Gestures.HUDPosition",
                         @[@"Top", @"Center", @"Bottom"], @[@0, @1, @2],
                         0, @"", @"")
        ],
        @[
            YTzoomToggleDetail(@"Turn Off Double Tap", @"Double tapping the video does nothing.",
                               @"YTzoom.Preference.Overlay.DoubleTapDisabled"),
            YTzoomToggle(@"Custom Double-Tap Skip", @"YTzoom.Preference.Playback.CustomDoubleTap", @"", @""),
            YTzoomStepper(@"Seconds", @"YTzoom.Preference.Playback.DoubleTapSeconds", 5.0, 60.0, 5.0, 10.0)
        ],
        @[
            YTzoomToggleDetail(@"Hold to Seek", @"Hold the left or right side to rewind or fast-forward.",
                               @"YTzoom.Preference.Gestures.HoldToSeek"),
            YTzoomSlider(@"Seek Step", @"YTzoom.Preference.Gestures.HoldSeekSeconds", 1.0, 60.0, 1.0, 10.0),
            YTzoomToggleDetail(@"Tap to Seek", @"Tap the progress bar to jump to that point.",
                               @"YTzoom.Preference.Playback.TapToSeek"),
            YTzoomToggleDetail(@"Two-Finger Tap to Pause",
                               @"Tap the video with two fingers to pause or play.",
                               @"YTzoom.Preference.Gestures.TwoFingerTap")
        ]
    ], @[YTzoomLocalized(@"SWIPE ON EDGES"), YTzoomLocalized(@"LEVEL INDICATOR"),
         YTzoomLocalized(@"DOUBLE TAP"), YTzoomLocalized(@"SEEK")]);
}

static NSDictionary *YTzoomAIDefinition(void) {
    NSMutableArray *regionTitles = [NSMutableArray arrayWithObject:@"Off"];
    NSMutableArray *regionValues = [NSMutableArray arrayWithObject:@""];
    NSLocale *english = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    for (NSString *code in YTzoomRegionCountryCodes()) {
        [regionTitles addObject:[english localizedStringForCountryCode:code] ?: code];
        [regionValues addObject:code];
    }
    return YTzoomPageDefinition(@"ai", @"AI & Region", @[
        @[
            YTzoomToggleDetail(@"AI Title Button",
                @"Adds a button next to the title box when you upload a Short. Gemini suggests 5 short titles from the video and the text you added.",
                YTzoomAITitlesKey),
            YTzoomTextEntry(@"Gemini API Key",
                @"Get a key at aistudio.google.com. It stays on this device and isn't included in backups.",
                @"YTzoom.Secret.GeminiAPIKey", @"AIza...", YES),
            YTzoomTextEntry(@"Gemini Model", @"Leave empty to use the latest Flash model.",
                @"YTzoom.Preference.AITitles.Model", @"gemini-flash-latest", NO),
            YTzoomPickerDetail(@"Show Button On",
                @"If the button doesn't appear on the upload screen, use Any Text Box and hold the button to copy the screen's class names.",
                YTzoomAITitlesPlacementKey,
                @[@"Upload Screen", @"Any Text Box"], @[@0, @1], 0)
        ],
        @[
            YTzoomPickerDetail(@"Pretend to Be In",
                @"For testing region-locked features. Changes what YouTube is told about your region; YouTube can still see your real location from your IP address and account.",
                YTzoomRegionCountryKey, regionTitles, regionValues, 0),
            YTzoomToggleDetail(@"Match Language", @"Also send that country's language.",
                YTzoomRegionLanguageKey),
            YTzoomToggleDetail(@"Match Time Zone", @"Also send that country's time zone.",
                YTzoomRegionTimeZoneKey),
            YTzoomToggleDetail(@"Change App Locale", @"YouTube also reads that country from iOS.",
                YTzoomRegionLocaleKey)
        ]
    ], @[YTzoomLocalized(@"AI TITLES"), YTzoomLocalized(@"REGION (TESTING)")]);
}

UIViewController *YTzoomMakeTabBarOptionsController(void) {
    return [YTzoomTabEditorController new];
}

NSArray<NSDictionary *> *YTzoomSettingsMenu(void) {
    NSMutableArray *look = [NSMutableArray arrayWithArray:@[
        @{@"id": @"watch", @"title": @"Watch Page", @"detail": @"Comments, suggestions, and the button row", @"symbol": @"rectangle.on.rectangle"},
        @{@"id": @"feed", @"title": @"Home & Feed", @"detail": @"Home redesign, shelves, mixes, and posts", @"symbol": @"house"},
        @{@"id": @"shorts", @"title": @"Shorts", @"detail": @"Playback, limit, and buttons", @"symbol": @"shorts"},
        @{@"id": @"tabs", @"title": @"Tabs", @"detail": @"Choose, reorder, and rename tabs", @"symbol": @"rectangle.bottomthird.inset.filled"},
        @{@"id": @"topbar", @"title": @"Top Bar", @"detail": @"Logo, buttons, and status bar", @"symbol": @"rectangle.topthird.inset.filled"}
    ]];
    if (YTzoomLiquidGlassAvailable()) {
        [look addObject:@{@"id": @"glass", @"title": @"Liquid Glass", @"detail": @"Tab bar, menus, toasts, and player", @"symbol": @"drop"}];
    }
    return @[
        @{@"header": @"PLAYBACK", @"rows": @[
            @{@"id": @"player", @"title": @"Player", @"detail": @"Buttons, speed, background audio, and controls", @"symbol": @"play.rectangle"},
            @{@"id": @"quality", @"title": @"Video Quality", @"detail": @"Default quality on Wi-Fi and mobile data", @"symbol": @"sparkles.tv"},
            @{@"id": @"captions", @"title": @"Captions", @"detail": @"Captions on or off, language, and transcript", @"symbol": @"captions.bubble"},
            @{@"id": @"gestures", @"title": @"Gestures", @"detail": @"Brightness, volume, double tap, and seeking", @"symbol": @"hand.draw"},
            @{@"id": @"sponsorblock", @"title": @"SponsorBlock", @"detail": @"Skip or mark sponsored segments", @"symbol": @"sponsor"}
        ]},
        @{@"header": @"LOOK & LAYOUT", @"rows": look},
        @{@"header": @"APP", @"rows": @[
            @{@"id": @"downloads", @"title": @"Downloads", @"detail": @"Download button, where to save, and backups", @"symbol": @"arrow.down.circle"},
            @{@"id": @"ai", @"title": @"AI & Region", @"detail": @"Gemini titles and region testing", @"symbol": @"sparkles"},
            @{@"id": @"general", @"title": @"General", @"detail": @"Language, appearance, privacy, and prompts", @"symbol": @"gearshape"}
        ]}
    ];
}

static NSDictionary *YTzoomDefinitionForPage(NSString *pageID) {
    if ([pageID isEqualToString:@"sponsorblock"]) return YTzoomSponsorBlockDefinition();
    if ([pageID isEqualToString:@"player"]) return YTzoomPlayerDefinition();
    if ([pageID isEqualToString:@"quality"]) return YTzoomQualityDefinition();
    if ([pageID isEqualToString:@"captions"]) return YTzoomCaptionsDefinition();
    if ([pageID isEqualToString:@"gestures"]) return YTzoomGestureOptionsDefinition();
    if ([pageID isEqualToString:@"watch"]) return YTzoomWatchPageDefinition();
    if ([pageID isEqualToString:@"feed"]) return YTzoomFeedDefinition();
    if ([pageID isEqualToString:@"shorts"]) return YTzoomShortsOptionsDefinition();
    if ([pageID isEqualToString:@"topbar"]) return YTzoomTopBarDefinition();
    if ([pageID isEqualToString:@"glass"]) return YTzoomGlassOptionsDefinition();
    if ([pageID isEqualToString:@"general"]) return YTzoomGeneralDefinition();
    if ([pageID isEqualToString:@"downloads"]) return YTzoomDownloadsDefinition();
    if ([pageID isEqualToString:@"ai"]) return YTzoomAIDefinition();
    return nil;
}

UIViewController *YTzoomMakeSettingsPage(NSString *pageID) {
    if ([pageID isEqualToString:@"tabs"]) return YTzoomMakeTabBarOptionsController();
    NSDictionary *definition = YTzoomDefinitionForPage(pageID);
    return definition != nil ? YTzoomPageFromDefinition(definition) : nil;
}

UIViewController *YTzoomMakeSponsorBlockController(void) { return YTzoomMakeSettingsPage(@"sponsorblock"); }
UIViewController *YTzoomMakePlayerControlsController(void) { return YTzoomMakeSettingsPage(@"player"); }
UIViewController *YTzoomMakeOverlayOptionsController(void) { return YTzoomMakeSettingsPage(@"watch"); }
UIViewController *YTzoomMakeStreamingOptionsController(void) { return YTzoomMakeSettingsPage(@"quality"); }
UIViewController *YTzoomMakeNavigationOptionsController(void) { return YTzoomMakeSettingsPage(@"topbar"); }
UIViewController *YTzoomMakeGlassOptionsController(void) { return YTzoomMakeSettingsPage(@"glass"); }
UIViewController *YTzoomMakeShortsOptionsController(void) { return YTzoomMakeSettingsPage(@"shorts"); }
UIViewController *YTzoomMakeMiscOptionsController(void) { return YTzoomMakeSettingsPage(@"general"); }
UIViewController *YTzoomMakeGestureOptionsController(void) { return YTzoomMakeSettingsPage(@"gestures"); }

NSArray<NSDictionary *> *YTzoomAllPageDefinitions(void) {
    NSMutableArray *pages = [NSMutableArray array];
    for (NSDictionary *section in YTzoomSettingsMenu()) {
        for (NSDictionary *row in section[@"rows"]) {
            NSDictionary *definition = YTzoomDefinitionForPage(row[@"id"]);
            if (definition != nil) [pages addObject:definition];
        }
    }
    [pages addObject:YTzoomPageDefinition(@"tabs", @"Tabs", @[
        @[
            YTzoomToggle(@"Hide Tab Labels", @"YTzoom.Preference.Tabs.LabelsHidden", @"", @""),
            YTzoomToggle(@"Don't Open App in Shorts", @"YTzoom.Preference.Shorts.PreventAutoOpen", @"", @""),
            YTzoomPicker(@"Frosted Tab Bar", @"YTzoom.Preference.Tabs.Frosted",
                         @[@"Default", @"On", @"Off"], @[@0, @1, @2], 0, @"", @""),
            YTzoomPicker(@"Selected Tab Color", @"YTzoom.Preference.Tabs.SelectedTint",
                         @[@"Off", @"Text Only", @"Text and Icon"],
                         @[@0, @1, @2], 0, @"", @""),
            YTzoomColor(@"Color", @"YTzoom.Preference.Tabs.SelectedTintColor", @"#0A84FF")
        ]
    ], @[YTzoomLocalized(@"MAIN")])];
    return pages;
}

UIViewController *YTzoomMakeCreditsController(void) {
    UILabel *label = [UILabel new];
    label.text = YTzoomLocalized(@"YTzoom\nClean-room implementation\nMIT licensed code\nBuilt by Epic");
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    UIViewController *controller = [UIViewController new];
    controller.title = YTzoomLocalized(@"Credits");
    controller.view.backgroundColor = YTzoomSettingsBackground();
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [label.leadingAnchor constraintGreaterThanOrEqualToAnchor:controller.view.leadingAnchor constant:24.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:controller.view.trailingAnchor constant:-24.0]
    ]];
    return controller;
}
