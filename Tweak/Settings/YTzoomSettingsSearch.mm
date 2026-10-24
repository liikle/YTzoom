#import "YTzoomSettingsSearch.h"
#import "YTzoomSettingsPages.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"

#import <objc/message.h>
#import <objc/runtime.h>

static UIViewController *YTzoomControllerForPageID(NSString *pageID) {
    return pageID.length != 0 ? YTzoomMakeSettingsPage(pageID) : nil;
}

static NSArray<NSDictionary *> *YTzoomSearchIndex(void) {
    NSMutableArray<NSDictionary *> *records = [NSMutableArray array];
    for (NSDictionary *page in YTzoomAllPageDefinitions()) {
        NSArray *sections = page[@"sections"];
        NSArray *headers = page[@"headers"];
        NSString *pageTitle = YTzoomLocalized(page[@"title"]);
        for (NSUInteger section = 0; section < sections.count; section++) {
            NSArray *items = sections[section];
            NSString *header = section < headers.count
                ? YTzoomLocalized(headers[section]) : @"";
            for (NSUInteger row = 0; row < items.count; row++) {
                NSDictionary *item = items[row];
                NSString *title = item[@"title"];
                if (![title isKindOfClass:NSString.class] || title.length == 0) continue;
                if ([item[@"type"] isEqualToString:@"text"]) continue;
                NSString *subtitle = [item[@"subtitle"] isKindOfClass:NSString.class]
                    ? item[@"subtitle"] : @"";
                [records addObject:@{
                    @"en": [item[@"en"] isKindOfClass:NSString.class] ? item[@"en"] : @"",
                    @"item": item,
                    @"pageID": page[@"id"],
                    @"pageTitle": pageTitle,
                    @"header": header,
                    @"title": title,
                    @"subtitle": subtitle,
                    @"section": @(section),
                    @"row": @(row)
                }];
            }
        }
    }
    return records;
}

static NSInteger YTzoomMatchScore(NSDictionary *record, NSString *query) {
    NSStringCompareOptions options = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
    NSRange inTitle = [record[@"title"] rangeOfString:query options:options];
    if (inTitle.location == 0) return 0;
    if (inTitle.location != NSNotFound) return 1;
    NSRange inEnglish = [record[@"en"] rangeOfString:query options:options];
    if (inEnglish.location == 0) return 1;
    if (inEnglish.location != NSNotFound) return 2;
    if ([record[@"subtitle"] rangeOfString:query options:options].location != NSNotFound) return 2;
    if ([record[@"header"] rangeOfString:query options:options].location != NSNotFound ||
        [record[@"pageTitle"] rangeOfString:query options:options].location != NSNotFound) return 3;
    return NSNotFound;
}

NSArray<NSDictionary *> *YTzoomFilterSettings(NSString *query) {
    NSString *trimmed = [query stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    if (trimmed.length == 0) return @[];
    NSMutableArray<NSDictionary *> *scored = [NSMutableArray array];
    for (NSDictionary *record in YTzoomSearchIndex()) {
        NSInteger score = YTzoomMatchScore(record, trimmed);
        if (score == NSNotFound) continue;
        NSMutableDictionary *entry = [record mutableCopy];
        entry[@"score"] = @(score);
        [scored addObject:entry];
    }
    [scored sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult order = [a[@"score"] compare:b[@"score"]];
        return order != NSOrderedSame ? order : [a[@"title"] compare:b[@"title"]];
    }];
    return scored;
}

void YTzoomOpenSettingsRecord(NSDictionary *record, UIViewController *presenter) {
    UIViewController *page = YTzoomControllerForPageID(record[@"pageID"]);
    if (page == nil || presenter == nil) return;
    NSIndexPath *target = [NSIndexPath indexPathForRow:[record[@"row"] integerValue]
                                             inSection:[record[@"section"] integerValue]];
    SEL push = NSSelectorFromString(@"pushViewController:");
    if ([presenter respondsToSelector:push]) {
        ((void (*)(id, SEL, id))objc_msgSend)(presenter, push, page);
    } else if (presenter.navigationController != nil) {
        [presenter.navigationController pushViewController:page animated:YES];
    } else {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![page isKindOfClass:UITableViewController.class]) return;
        UITableView *table = ((UITableViewController *)page).tableView;
        if (target.section >= [table numberOfSections] ||
            target.row >= [table numberOfRowsInSection:target.section]) return;
        [table scrollToRowAtIndexPath:target
                     atScrollPosition:UITableViewScrollPositionMiddle
                             animated:YES];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UITableViewCell *cell = [table cellForRowAtIndexPath:target];
            if (cell == nil) return;
            UIColor *original = cell.contentView.backgroundColor;
            cell.contentView.backgroundColor =
                [YTzoomAccentColor() colorWithAlphaComponent:0.28];
            [UIView animateWithDuration:0.9 delay:0.4
                                options:UIViewAnimationOptionCurveEaseOut
                             animations:^{ cell.contentView.backgroundColor = original; }
                             completion:nil];
        });
    });
}

@interface YTzoomSearchOverlayController : UIViewController <UISearchBarDelegate>
@property(nonatomic, weak) UIViewController *hostController;
@property(nonatomic, strong) UISearchBar *searchBar;
@property(nonatomic, strong) UIViewController *results;
@property(nonatomic, strong) UILabel *emptyLabel;
@end

@implementation YTzoomSearchOverlayController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.searchBar = [UISearchBar new];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = YTzoomLocalized(@"Search settings");
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.tintColor = YTzoomAccentColor();
    self.searchBar.searchTextField.tintColor = YTzoomAccentColor();
    self.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.searchBar];

    self.results = YTzoomMakeSettingsResultsController(@[], @[]);
    [self addChildViewController:self.results];
    UIView *resultsView = self.results.view;
    resultsView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:resultsView];
    [self.results didMoveToParentViewController:self];
    if ([self.results isKindOfClass:UITableViewController.class]) {
        ((UITableViewController *)self.results).tableView.keyboardDismissMode =
            UIScrollViewKeyboardDismissModeOnDrag;
    }

    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = YTzoomLocalized(@"No matching settings");
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.hidden = YES;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.emptyLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.searchBar.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [resultsView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor],
        [resultsView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [resultsView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [resultsView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:40.0],
        [self.emptyLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [self.emptyLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0]
    ]];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.searchBar becomeFirstResponder];
}

- (void)dismissOverlay {
    [self.searchBar resignFirstResponder];
    [self willMoveToParentViewController:nil];
    [self.view removeFromSuperview];
    [self removeFromParentViewController];
}

- (void)searchBarTextDidBeginEditing:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:YES animated:YES];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)text {
    (void)searchBar;
    NSString *query = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSString *> *titles = @[];
    NSArray *sections = query.length != 0 ? YTzoomSearchResultSections(query, &titles) : @[];
    YTzoomUpdateSettingsResultsController(self.results, sections, titles);
    self.emptyLabel.hidden = query.length == 0 || sections.count != 0;
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    [searchBar setShowsCancelButton:NO animated:YES];
    [self dismissOverlay];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

@end

void YTzoomPresentSettingsSearchOverlay(UIViewController *host) {
    if (host == nil || !host.isViewLoaded) return;
    for (UIViewController *child in host.childViewControllers) {
        if ([child isKindOfClass:YTzoomSearchOverlayController.class]) return;
    }
    YTzoomSearchOverlayController *overlay = [YTzoomSearchOverlayController new];
    overlay.hostController = host;
    [host addChildViewController:overlay];
    overlay.view.frame = host.view.bounds;
    overlay.view.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host.view addSubview:overlay.view];
    [overlay didMoveToParentViewController:host];
}

NSArray<NSArray<NSDictionary *> *> *YTzoomSearchResultSections(
        NSString *query, NSArray<NSString *> **sectionTitles) {
    NSArray<NSDictionary *> *matches = YTzoomFilterSettings(query);
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSDictionary *> *> *sections =
        [NSMutableArray array];
    for (NSDictionary *record in matches) {
        NSDictionary *item = record[@"item"];
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *page = record[@"pageTitle"] ?: @"";
        NSString *area = record[@"header"] ?: @"";
        NSString *group = area.length != 0
            ? [NSString stringWithFormat:@"%@ › %@", page, area] : page;
        NSUInteger index = [titles indexOfObject:group];
        if (index == NSNotFound) {
            [titles addObject:group];
            [sections addObject:[NSMutableArray array]];
            index = titles.count - 1;
        }
        [sections[index] addObject:item];
    }
    if (sectionTitles != NULL) *sectionTitles = [titles copy];
    return [sections copy];
}
