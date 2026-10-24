#import "YTzoomTabEditorController.h"
#import "../UI/Notice.h"
#import "YTzoomRootOptionsController.h"
#import "YTzoomSettingsPages.h"
#import "../YTzoom.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"

#import <objc/runtime.h>

static const void *YTzoomTabSwitchKey = &YTzoomTabSwitchKey;

static UIImage *YTzoomTabEditorIcon(NSString *token, NSString *fallback) {
    if ([token isEqualToString:@"shorts"]) {
        return [YTzoomShortsImage(NO)
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    NSDictionary *assets = @{
        @"music": @"yt_outline_music_24pt_3x_Normal",
        @"live": @"live_24pt_3x_Normal",
        @"gaming": @"gaming_24pt_3x_Normal",
        @"news": @"news_24pt_3x_Normal",
        @"sports": @"G_sport",
        @"learning": @"G_Learning",
        @"fashion": @"fashion_24pt_3x_Normal",
        @"playlists": @"playlist",
        @"history": @"history",
        @"notifications": @"ic_notifications_none_3x_Normal",
        @"watchlater": @"clock_24pt_3x_Normal"
    };
    return YTzoomAssetImage(assets[token], fallback);
}

@interface YTzoomTabEditorController ()
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *activeTabs;
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary *> *inactiveTabs;
@end

static NSArray<NSString *> *YTzoomTintTitles(void) {
    return @[YTzoomLocalized(@"Off"), YTzoomLocalized(@"Text Only"), YTzoomLocalized(@"Text and Icon")];
}

static NSArray<NSString *> *YTzoomFrostedTitles(void) {
    return @[YTzoomLocalized(@"Default"), YTzoomLocalized(@"On"), YTzoomLocalized(@"Off")];
}

static NSUInteger YTzoomTintIndex(void) {
    NSInteger mode = [YTzoomPreferenceObject(@"YTzoom.Preference.Tabs.SelectedTint") integerValue];
    return (NSUInteger)MAX(0, MIN(2, mode));
}

static NSString *YTzoomTintHex(void) {
    id stored = YTzoomPreferenceObject(@"YTzoom.Preference.Tabs.SelectedTintColor");
    return [stored isKindOfClass:NSString.class] ? stored : @"#0A84FF";
}

static UIColor *YTzoomTintSwatchColor(void) {
    NSString *value = [[YTzoomTintHex() stringByReplacingOccurrencesOfString:@"#" withString:@""] uppercaseString];
    unsigned int rgb = 0x0A84FF;
    if (value.length == 6) [[NSScanner scannerWithString:value] scanHexInt:&rgb];
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

static NSString *YTzoomTintHexFromColor(UIColor *color) {
    CGFloat red = 0.0, green = 0.0, blue = 0.0, alpha = 0.0;
    if (![color getRed:&red green:&green blue:&blue alpha:&alpha]) return @"#0A84FF";
    return [NSString stringWithFormat:@"#%02X%02X%02X",
            (int)lround(red * 255.0), (int)lround(green * 255.0),
            (int)lround(blue * 255.0)];
}

@interface YTzoomTabEditorController () <UIColorPickerViewControllerDelegate>
@end

@implementation YTzoomTabEditorController

- (NSArray<NSString *> *)mainRows {
    NSMutableArray<NSString *> *rows = [@[@"labels", @"shorts", @"frosted"] mutableCopy];
    [rows addObject:@"tint"];
    [rows addObject:@"tintColor"];
    return rows;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = YTzoomLocalized(@"Tabs");
    self.tableView.cellLayoutMarginsFollowReadableWidth = NO;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.rowHeight = 48.0;
    if (@available(iOS 15.0, *)) {
        self.tableView.sectionHeaderTopPadding = 0.0;
    }
    [self loadTabs];
    [self setEditing:YES animated:NO];
    self.tableView.allowsSelectionDuringEditing = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:NO];
    YTzoomApplyAppearance(self);
    self.tableView.backgroundColor =
        YTzoomInterfaceBackgroundColor(self.traitCollection);
    [self.tableView reloadData];
}

- (NSMutableDictionary *)tab:(NSString *)token
                       title:(NSString *)title
                      symbol:(NSString *)symbol
                         key:(NSString *)key {
    return [@{
        @"token": token,
        @"title": title,
        @"symbol": symbol,
        @"key": key
    } mutableCopy];
}

- (void)loadTabs {
    NSArray *defaults = @[
        [self tab:@"home" title:YTzoomLocalized(@"Home") symbol:@"house" key:@"YTzoom.Preference.Tabs.Hidden.Home"],
        [self tab:@"shorts" title:YTzoomLocalized(@"Shorts") symbol:@"play.rectangle" key:@"YTzoom.Preference.Tabs.Hidden.Shorts"],
        [self tab:@"subscriptions" title:YTzoomLocalized(@"Subscriptions") symbol:@"rectangle.stack" key:@"YTzoom.Preference.Tabs.Hidden.Subscriptions"],
        [self tab:@"library" title:YTzoomLocalized(@"Library") symbol:@"person.circle" key:@"YTzoom.Preference.Tabs.Hidden.Library"],
        [self tab:@"ytzoom" title:@"YTzoom" symbol:@"arrow.down.circle" key:@"YTzoom.Preference.Tabs.Hidden.YTzoomTab"],
        [self tab:@"create" title:YTzoomLocalized(@"Create") symbol:@"plus.circle" key:@"YTzoom.Preference.Tabs.Hidden.Create"],
        [self tab:@"music" title:YTzoomLocalized(@"Music") symbol:@"music.note" key:@"YTzoom.Preference.Tabs.Hidden.Music"],
        [self tab:@"live" title:YTzoomLocalized(@"Live") symbol:@"dot.radiowaves.left.and.right" key:@"YTzoom.Preference.Tabs.Hidden.Live"],
        [self tab:@"gaming" title:YTzoomLocalized(@"Gaming") symbol:@"gamecontroller" key:@"YTzoom.Preference.Tabs.Hidden.Gaming"],
        [self tab:@"news" title:YTzoomLocalized(@"News") symbol:@"newspaper" key:@"YTzoom.Preference.Tabs.Hidden.News"],
        [self tab:@"posts" title:YTzoomLocalized(@"Posts") symbol:@"bubble.left.and.bubble.right" key:@"YTzoom.Preference.Tabs.Hidden.Posts"],
        [self tab:@"sports" title:YTzoomLocalized(@"Sports") symbol:@"trophy" key:@"YTzoom.Preference.Tabs.Hidden.Sports"],
        [self tab:@"learning" title:YTzoomLocalized(@"Learning") symbol:@"graduationcap" key:@"YTzoom.Preference.Tabs.Hidden.Learning"],
        [self tab:@"fashion" title:YTzoomLocalized(@"Fashion") symbol:@"tshirt" key:@"YTzoom.Preference.Tabs.Hidden.Fashion"],
        [self tab:@"playlists" title:YTzoomLocalized(@"Playlists") symbol:@"music.note.list" key:@"YTzoom.Preference.Tabs.Hidden.Playlists"],
        [self tab:@"history" title:YTzoomLocalized(@"History") symbol:@"clock.arrow.circlepath" key:@"YTzoom.Preference.Tabs.Hidden.History"],
        [self tab:@"notifications" title:YTzoomLocalized(@"Notifs") symbol:@"bell" key:@"YTzoom.Preference.Tabs.Hidden.Notifs"],
        [self tab:@"watchlater" title:YTzoomLocalized(@"WLater") symbol:@"clock" key:@"YTzoom.Preference.Tabs.Hidden.WatchLater"]
    ];
    self.activeTabs = [NSMutableArray array];
    self.inactiveTabs = [NSMutableArray array];
    for (NSMutableDictionary *tab in defaults) {
        BOOL initiallyInactive = [@[
            @"create", @"music", @"live", @"gaming", @"news", @"sports",
            @"learning", @"fashion", @"playlists", @"history",
            @"notifications", @"watchlater"
        ] containsObject:tab[@"token"]];
        id stored = YTzoomPreferenceObject(tab[@"key"]);
        BOOL hidden = [stored respondsToSelector:@selector(boolValue)] ? [stored boolValue] : initiallyInactive;
        YTzoomSetPreference(tab[@"key"], hidden);
        [(hidden ? self.inactiveTabs : self.activeTabs) addObject:tab];
    }
    NSArray *order = [NSUserDefaults.standardUserDefaults arrayForKey:@"YTzoom.Preference.Tabs.Order"];
    if (order.count != 0) {
        [self.activeTabs sortUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            NSUInteger leftIndex = [order indexOfObject:left[@"token"]];
            NSUInteger rightIndex = [order indexOfObject:right[@"token"]];
            leftIndex = leftIndex == NSNotFound ? NSUIntegerMax : leftIndex;
            rightIndex = rightIndex == NSNotFound ? NSUIntegerMax : rightIndex;
            return leftIndex < rightIndex ? NSOrderedAscending : (leftIndex > rightIndex ? NSOrderedDescending : NSOrderedSame);
        }];
    }
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    (void)tableView;
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return (NSInteger)[self mainRows].count;
    if (section == 1) return 1;
    if (section == 2) return (NSInteger)self.activeTabs.count;
    return (NSInteger)self.inactiveTabs.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return YTzoomLocalized(@"MAIN");
    if (section == 2) return YTzoomLocalized(@"ACTIVE TABS");
    if (section == 3) return YTzoomLocalized(@"INACTIVE TABS");
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return section == 1 ? 24.0 : 38.0;
}

- (void)tableView:(UITableView *)tableView
willDisplayHeaderView:(UIView *)view
        forSection:(NSInteger)section {
    (void)tableView;
    (void)section;
    UITableViewHeaderFooterView *header = (UITableViewHeaderFooterView *)view;
    header.textLabel.font = [UIFont systemFontOfSize:11.0];
    header.textLabel.textColor = UIColor.secondaryLabelColor;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *identifier = indexPath.section < 2 ? @"YTzoomTabOption" : @"YTzoomTabItem";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:identifier];
    }
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    cell.imageView.image = nil;
    cell.accessoryView = nil;
    cell.editingAccessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.editingAccessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.font = [UIFont systemFontOfSize:17.0];
    cell.backgroundColor = YTzoomInterfaceBackgroundColor(self.traitCollection);
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.indentationLevel = 0;
    cell.indentationWidth = 0.0;

    NSString *row = indexPath.section == 0 ? [self mainRows][(NSUInteger)indexPath.row] : nil;
    if ([row isEqualToString:@"tint"]) {
        cell.textLabel.text = YTzoomLocalized(@"Selected Tab Color");
        cell.detailTextLabel.text = YTzoomTintTitles()[YTzoomTintIndex()];
        cell.detailTextLabel.textColor = YTzoomAccentColor();
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if ([row isEqualToString:@"frosted"]) {
        cell.textLabel.text = YTzoomLocalized(@"Frosted Tab Bar");
        cell.detailTextLabel.text = YTzoomFrostedTitles()[(NSUInteger)YTzoomFrostedTabBarMode()];
        cell.detailTextLabel.textColor = YTzoomAccentColor();
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }
    if ([row isEqualToString:@"tintColor"]) {
        cell.textLabel.text = YTzoomLocalized(@"Color");
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0.0, 0.0, 28.0, 28.0)];
        dot.backgroundColor = YTzoomTintSwatchColor();
        dot.layer.cornerRadius = 14.0;
        dot.layer.borderWidth = 2.0;
        dot.layer.borderColor = UIColor.secondaryLabelColor.CGColor;
        cell.accessoryView = dot;
        cell.editingAccessoryView = dot;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    if (indexPath.section == 0) {
        NSDictionary *titles = @{@"labels": YTzoomLocalized(@"Hide Tab Labels"),
                                 @"shorts": YTzoomLocalized(@"Don't Open App in Shorts"),
                                 };
        NSDictionary *keys = @{@"labels": @"YTzoom.Preference.Tabs.LabelsHidden",
                               @"shorts": @"YTzoom.Preference.Shorts.PreventAutoOpen",
                               };
        cell.textLabel.text = titles[row];
        UISwitch *toggle = [UISwitch new];
        toggle.transform = CGAffineTransformMakeScale(0.95, 0.95);
        toggle.onTintColor = YTzoomAccentColor();
        NSString *key = keys[row];
        toggle.on = [YTzoomPreferenceObject(key) boolValue];
        objc_setAssociatedObject(toggle, YTzoomTabSwitchKey, key, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.editingAccessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }

    if (indexPath.section == 1) {
        cell.textLabel.text = YTzoomLocalized(@"Default Startup Tab");
        NSArray<NSString *> *startupTitles = nil;
        NSArray<NSString *> *startupValues = nil;
        YTzoomStartupDestinations(&startupTitles, &startupValues);
        cell.detailTextLabel.text = YTzoomPickerSummary(
            @"YTzoom.Preference.Tabs.Startup", startupTitles, startupValues, 0);
        cell.detailTextLabel.textColor = YTzoomAccentColor();
        return cell;
    }

    NSDictionary *tab = indexPath.section == 2
        ? self.activeTabs[(NSUInteger)indexPath.row]
        : self.inactiveTabs[(NSUInteger)indexPath.row];
    NSString *token = tab[@"token"];
    NSDictionary *customNames = [NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"YTzoom.Preference.Tabs.Names"];
    NSString *custom = customNames[token];
    if (custom.length != 0 && ![custom isEqualToString:tab[@"title"]]) {
        cell.textLabel.text = [NSString stringWithFormat:@"%@ (%@)",
                               tab[@"title"], custom];
    } else {
        cell.textLabel.text = tab[@"title"];
    }
    UIImage *image = nil;
    if ([token isEqualToString:@"shorts"]) {
        image = YTzoomShortsImage(NO);
    } else if ([token isEqualToString:@"ytzoom"]) {
        image = YTzoomDownloadTabImage(NO);
    } else {
        image = YTzoomTabEditorIcon(token, tab[@"symbol"]);
    }
    cell.imageView.image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    cell.imageView.tintColor = UIColor.labelColor;
    cell.showsReorderControl = indexPath.section == 2;
    return cell;
}

- (void)saveTintColor:(UIColor *)color {
    if (color == nil) return;
    YTzoomSetPreferenceObject(@"YTzoom.Preference.Tabs.SelectedTintColor", YTzoomTintHexFromColor(color));
    NSUInteger row = [[self mainRows] indexOfObject:@"tintColor"];
    if (row != NSNotFound) {
        [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]]
                              withRowAnimation:UITableViewRowAnimationNone];
    }
    YTzoomRefreshPivotBarBackground();
}

- (void)colorPickerViewController:(UIColorPickerViewController *)viewController
                   didSelectColor:(UIColor *)color
                     continuously:(BOOL)continuously {
    (void)viewController;
    if (!continuously) [self saveTintColor:color];
}

- (void)colorPickerViewControllerDidFinish:(UIColorPickerViewController *)viewController {
    [self saveTintColor:viewController.selectedColor];
}

- (void)toggleChanged:(UISwitch *)sender {
    NSString *key = objc_getAssociatedObject(sender, YTzoomTabSwitchKey);
    YTzoomSetPreference(key, sender.isOn);
    if ([key isEqualToString:@"YTzoom.Preference.Tabs.Glass"] ||
        [key isEqualToString:@"YTzoom.Preference.Tabs.GlassMinimize"]) {
        YTzoomRefreshPivotBarBackground();
        return;
    }
    YTzoomShowRestartNotice(self);
}

- (BOOL)tableView:(UITableView *)tableView
shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section >= 2;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView
           editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    if (indexPath.section == 2) return UITableViewCellEditingStyleDelete;
    if (indexPath.section == 3) return UITableViewCellEditingStyleInsert;
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    return indexPath.section == 2;
}

- (NSIndexPath *)tableView:(UITableView *)tableView
targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)sourceIndexPath
       toProposedIndexPath:(NSIndexPath *)proposedDestinationIndexPath {
    (void)tableView;
    if (proposedDestinationIndexPath.section != 2) {
        return [NSIndexPath indexPathForRow:MAX(0, (NSInteger)self.activeTabs.count - 1) inSection:2];
    }
    return proposedDestinationIndexPath;
}

- (void)tableView:(UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    (void)tableView;
    NSMutableDictionary *tab = self.activeTabs[(NSUInteger)sourceIndexPath.row];
    [self.activeTabs removeObjectAtIndex:(NSUInteger)sourceIndexPath.row];
    [self.activeTabs insertObject:tab atIndex:(NSUInteger)destinationIndexPath.row];
    [self saveOrder];
    YTzoomShowRestartNotice(self);
}

- (void)tableView:(UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSMutableDictionary *tab = editingStyle == UITableViewCellEditingStyleDelete
        ? self.activeTabs[(NSUInteger)indexPath.row]
        : self.inactiveTabs[(NSUInteger)indexPath.row];
    if (editingStyle == UITableViewCellEditingStyleDelete) {
        NSString *key = tab[@"key"];
        BOOL isSettingsRoute =
            [key isEqualToString:@"YTzoom.Preference.Tabs.Hidden.YTzoomTab"] ||
            [key isEqualToString:@"YTzoom.Preference.Tabs.Hidden.Library"];
        if (isSettingsRoute) {
            NSString *other = [key isEqualToString:
                @"YTzoom.Preference.Tabs.Hidden.YTzoomTab"]
                ? @"YTzoom.Preference.Tabs.Hidden.Library"
                : @"YTzoom.Preference.Tabs.Hidden.YTzoomTab";
            BOOL otherHidden = NO;
            for (NSMutableDictionary *entry in self.inactiveTabs) {
                if ([entry[@"key"] isEqualToString:other]) {
                    otherHidden = YES;
                    break;
                }
            }
            if (otherHidden) {
                [tableView setEditing:NO animated:YES];
                YTzoomShowNotice(YTzoomLocalized(
                    @"Keep the YTzoom or Library tab so settings stay reachable."));
                return;
            }
        }
        [self.activeTabs removeObjectAtIndex:(NSUInteger)indexPath.row];
        [self.inactiveTabs addObject:tab];
    } else if (editingStyle == UITableViewCellEditingStyleInsert) {
        [self.inactiveTabs removeObjectAtIndex:(NSUInteger)indexPath.row];
        [self.activeTabs addObject:tab];
    }
    YTzoomSetPreference(tab[@"key"], editingStyle == UITableViewCellEditingStyleDelete);
    [self saveOrder];
    [tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(2, 2)]
             withRowAnimation:UITableViewRowAnimationAutomatic];
    YTzoomShowRestartNotice(self);
}

- (void)saveOrder {
    NSMutableArray *order = [NSMutableArray array];
    for (NSDictionary *tab in self.activeTabs) {
        [order addObject:tab[@"token"]];
    }
    [NSUserDefaults.standardUserDefaults setObject:order forKey:@"YTzoom.Preference.Tabs.Order"];
    [NSNotificationCenter.defaultCenter postNotificationName:@"YTzoomTabConfigDidChange" object:nil];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *row = indexPath.section == 0 ? [self mainRows][(NSUInteger)indexPath.row] : nil;
    if ([row isEqualToString:@"tint"]) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        YTzoomPresentSelectionMenu(self, cell, YTzoomLocalized(@"Selected Tab Color"), YTzoomTintTitles(),
            YTzoomTintIndex(), ^(NSUInteger index) {
                YTzoomSetPreferenceObject(@"YTzoom.Preference.Tabs.SelectedTint", @(index));
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
                YTzoomRefreshPivotBarBackground();
            });
        return;
    }
    if ([row isEqualToString:@"frosted"]) {
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        YTzoomPresentSelectionMenu(self, cell, YTzoomLocalized(@"Frosted Tab Bar"), YTzoomFrostedTitles(),
            (NSUInteger)YTzoomFrostedTabBarMode(), ^(NSUInteger index) {
                YTzoomSetPreferenceObject(@"YTzoom.Preference.Tabs.Frosted", @(index));
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
                YTzoomRefreshPivotBarBackground();
                YTzoomShowRestartNotice(self);
            });
        return;
    }
    if ([row isEqualToString:@"tintColor"]) {
        UIColorPickerViewController *picker = [UIColorPickerViewController new];
        picker.title = YTzoomLocalized(@"Selected Tab Color");
        picker.supportsAlpha = NO;
        picker.selectedColor = YTzoomTintSwatchColor();
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
        return;
    }
    if (indexPath.section == 1) {
        NSArray<NSString *> *titles = nil;
        NSArray<NSString *> *values = nil;
        YTzoomStartupDestinations(&titles, &values);
        UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
        YTzoomPresentChoiceMenu(self, cell, @"Default Startup Tab", titles, values,
            @"YTzoom.Preference.Tabs.Startup", 0, ^(__unused NSUInteger position) {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath]
                                      withRowAnimation:UITableViewRowAnimationNone];
                YTzoomShowRestartNotice(self);
            });
    } else if (indexPath.section == 2) {
        NSMutableDictionary *tab = self.activeTabs[(NSUInteger)indexPath.row];
        NSString *token = tab[@"token"];
        NSDictionary *names = [NSUserDefaults.standardUserDefaults
            dictionaryForKey:@"YTzoom.Preference.Tabs.Names"];
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:YTzoomLocalized(@"Rename Tab")
            message:YTzoomLocalized(@"Leave blank to restore the default name.")
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.placeholder = tab[@"title"];
            field.text = names[token];
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
            style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction
            actionWithTitle:YTzoomLocalized(@"Save")
            style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) {
                NSMutableDictionary *updated = [names mutableCopy] ?:
                    [NSMutableDictionary dictionary];
                NSString *value = [alert.textFields.firstObject.text
                    stringByTrimmingCharactersInSet:
                        NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (value.length == 0) {
                    [updated removeObjectForKey:token];
                } else {
                    updated[token] = value;
                }
                [NSUserDefaults.standardUserDefaults setObject:updated
                                                        forKey:@"YTzoom.Preference.Tabs.Names"];
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"YTzoomTabConfigDidChange"
                    object:nil];
                [self.tableView reloadData];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

@end
