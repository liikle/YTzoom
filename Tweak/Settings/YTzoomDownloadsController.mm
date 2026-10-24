#import "YTzoomDownloadsController.h"
#import <Photos/Photos.h>
#import "../Features/Downloads/DownloadCoordinator.h"
#import "../Features/Downloads/DownloadLog.h"
#import "YTzoomRootOptionsController.h"
#import "../YTzoom.h"
#import "../Runtime/Preferences.h"
#import "../Runtime/Localization.h"
#import "../UI/Assets.h"
#import "../UI/Notice.h"
#import "../UI/OverlayButtonHost.h"
#import "../Features/Downloads/YTzoomDownloadPlayerController.h"
#import "../Features/Downloads/YTzoomAudioPlayerController.h"
#import "../Features/Downloads/MediaArtwork.h"
#import "../Features/Downloads/DownloadSponsor.h"
#import "../Features/Downloads/DownloadProgressView.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreMedia/CoreMedia.h>
#import <AVKit/AVKit.h>
#import <math.h>
#import <objc/message.h>

static NSString *const YTzoomDownloadLibraryChanged =
    @"YTzoomDownloadLibraryChanged";

static NSArray<NSURL *> *YTzoomSidecarURLs(NSURL *URL) {
    NSURL *base = URL.URLByDeletingPathExtension;
    return @[
        [base URLByAppendingPathExtension:@"jpg"],
        [base URLByAppendingPathExtension:@"png"],
        [base URLByAppendingPathExtension:@"ytzoom.json"],
        [base URLByAppendingPathExtension:@"srt"],
        [base URLByAppendingPathExtension:@"vtt"]
    ];
}

static NSString *YTzoomDurationText(NSTimeInterval duration) {
    if (!isfinite(duration) || duration <= 0.0) {
        return @"--:--";
    }
    NSInteger seconds = (NSInteger)llround(duration);
    NSInteger hours = seconds / 3600;
    NSInteger minutes = (seconds % 3600) / 60;
    NSInteger remainder = seconds % 60;
    if (hours > 0) {
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld",
            (long)hours, (long)minutes, (long)remainder];
    }
    return [NSString stringWithFormat:@"%ld:%02ld",
        (long)minutes, (long)remainder];
}

static NSString *YTzoomResolutionText(CGSize size) {
    CGFloat height = MIN(fabs(size.width), fabs(size.height));
    if (height <= 0.0) {
        return @"";
    }
    NSArray<NSNumber *> *standards = @[@144, @240, @360, @480, @720, @1080, @1440, @2160];
    NSNumber *closest = standards.firstObject;
    CGFloat distance = CGFLOAT_MAX;
    for (NSNumber *standard in standards) {
        CGFloat candidate = fabs(height - standard.doubleValue);
        if (candidate < distance) {
            closest = standard;
            distance = candidate;
        }
    }
    return [NSString stringWithFormat:@"%@p", closest];
}

static UIAlertAction *YTzoomMenuAction(
    NSString *title,
    NSString *symbol,
    UIAlertActionStyle style,
    void (^handler)(UIAlertAction *action)
) {
    UIAlertAction *action = [UIAlertAction actionWithTitle:title
                                                     style:style
                                                   handler:handler];
    if (symbol.length != 0) {
        @try {
            [action setValue:[UIImage systemImageNamed:symbol] forKey:@"image"];
        } @catch (__unused NSException *exception) {
        }
    }
    return action;
}

@interface YTzoomMiniPlayerView : UIView
@property(nonatomic, strong) AVPlayer *player;
@end

static void YTzoomSaveVideoToPhotos(NSURL *url) {
    YTzoomSaveVideoToPhotosFile(url, ^(BOOL success, NSError *error) {
        if (success) {
            YTzoomShowNotice(YTzoomLocalized(@"Saved to Photos"));
        } else if (error.code == 3302 &&
                   [error.domain isEqualToString:PHPhotosErrorDomain]) {
            YTzoomShowNotice(YTzoomLocalized(
                @"Photos cannot import this video's format. Use Share to "
                @"save it to Files instead."));
        } else if (error != nil) {
            YTzoomShowNotice(error.localizedDescription ?:
                YTzoomLocalized(@"The video could not be saved."));
        }
    });
}

@implementation YTzoomMiniPlayerView
+ (Class)layerClass { return AVPlayerLayer.class; }
- (void)setPlayer:(AVPlayer *)player {
    _player = player;
    AVPlayerLayer *layer = (AVPlayerLayer *)self.layer;
    layer.player = player;
    layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
}
@end

@interface YTzoomDownloadCell : UICollectionViewCell
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UIImageView *thumbnailView;
@property(nonatomic, strong) UIImageView *placeholderView;
@property(nonatomic, strong) UILabel *resolutionLabel;
@property(nonatomic, strong) UILabel *durationLabel;
@property(nonatomic, strong) UILabel *nameLabel;
@property(nonatomic, strong) UILabel *metadataLabel;
@property(nonatomic, copy) NSString *representedPath;
@property(nonatomic, assign) NSInteger layoutMode;
@property(nonatomic, strong) UIView *progressTrack;
@property(nonatomic, strong) UIImageView *progressFill;
@property(nonatomic, assign) CGFloat watchedRatio;
@end

@implementation YTzoomDownloadCell

- (void)applyTheme {
    self.cardView.backgroundColor = UIColor.clearColor;
    self.thumbnailView.backgroundColor =
        YTzoomInterfaceSurfaceColor(self.traitCollection);
    self.placeholderView.tintColor = UIColor.tertiaryLabelColor;
    self.nameLabel.textColor = UIColor.labelColor;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.cardView = [UIView new];
    self.thumbnailView = [UIImageView new];
    self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
    self.thumbnailView.clipsToBounds = YES;
    self.thumbnailView.layer.cornerRadius = 12.0;
    self.thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
    self.placeholderView = [[UIImageView alloc] initWithImage:
        [[UIImage systemImageNamed:@"video.slash.fill"]
            imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]];
    self.placeholderView.contentMode = UIViewContentModeScaleAspectFit;
    self.resolutionLabel = [self badgeLabel];
    self.durationLabel = [self badgeLabel];
    self.nameLabel = [UILabel new];
    self.nameLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
    self.nameLabel.numberOfLines = 2;
    self.metadataLabel = [UILabel new];
    self.metadataLabel.font = [UIFont systemFontOfSize:12.0];
    self.metadataLabel.textColor = UIColor.secondaryLabelColor;
    [self.contentView addSubview:self.cardView];
    [self.cardView addSubview:self.thumbnailView];
    [self.thumbnailView addSubview:self.placeholderView];

    self.progressTrack = [UIView new];
    self.progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
    self.progressTrack.hidden = YES;
    self.progressTrack.userInteractionEnabled = NO;
    self.progressFill = [UIImageView new];
    self.progressFill.contentMode = UIViewContentModeScaleToFill;
    self.progressFill.clipsToBounds = YES;
    [self.progressTrack addSubview:self.progressFill];
    [self.thumbnailView addSubview:self.progressTrack];
    [self.cardView addSubview:self.resolutionLabel];
    [self.cardView addSubview:self.durationLabel];
    [self.cardView addSubview:self.nameLabel];
    [self.cardView addSubview:self.metadataLabel];
    [self applyTheme];
    return self;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection == nil ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self applyTheme];
    }
}

- (UILabel *)badgeLabel {
    UILabel *label = [UILabel new];
    label.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.82];
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:10.0 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.layer.cornerRadius = 3.0;
    label.layer.masksToBounds = YES;
    return label;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGAffineTransform pressTransform = self.cardView.transform;
    self.cardView.transform = CGAffineTransformIdentity;
    CGFloat width = CGRectGetWidth(self.contentView.bounds);
    CGFloat height = CGRectGetHeight(self.contentView.bounds);
    if (self.layoutMode == 0) {
        CGFloat cardWidth = MIN(720.0, width - 24.0);
        CGFloat thumb = round(cardWidth * 9.0 / 16.0);
        self.cardView.frame = CGRectMake((width - cardWidth) * 0.5, 6.0, cardWidth, height - 12.0);
        self.thumbnailView.frame = CGRectMake(0.0, 0.0, cardWidth, thumb);
        self.placeholderView.frame = CGRectMake((cardWidth - 92.0) * 0.5, (thumb - 92.0) * 0.5, 92.0, 92.0);
        self.resolutionLabel.frame = CGRectMake(8.0, thumb - 27.0, 42.0, 19.0);
        self.durationLabel.frame = CGRectMake(cardWidth - 52.0, thumb - 27.0, 44.0, 19.0);
        self.nameLabel.frame = CGRectMake(2.0, thumb + 10.0, cardWidth - 4.0, 38.0);
        self.metadataLabel.frame = CGRectMake(2.0, thumb + 50.0, cardWidth - 4.0, 18.0);
        self.metadataLabel.textAlignment = NSTextAlignmentLeft;
    } else if (self.layoutMode == 1) {
        self.cardView.frame = CGRectMake(12.0, 6.0, width - 24.0, height - 12.0);
        CGFloat cardWidth = CGRectGetWidth(self.cardView.bounds);
        CGFloat cardHeight = CGRectGetHeight(self.cardView.bounds);
        CGFloat thumbWidth = round(cardHeight * 16.0 / 9.0);
        self.thumbnailView.frame = CGRectMake(0.0, 0.0, thumbWidth, cardHeight);
        self.placeholderView.frame = CGRectMake((thumbWidth - 40.0) * 0.5, (cardHeight - 40.0) * 0.5, 40.0, 40.0);
        self.resolutionLabel.frame = CGRectMake(6.0, cardHeight - 24.0, 42.0, 18.0);
        self.durationLabel.frame = CGRectMake(thumbWidth - 50.0, cardHeight - 24.0, 44.0, 18.0);
        CGFloat textX = thumbWidth + 12.0;
        self.nameLabel.frame = CGRectMake(textX, 2.0, MAX(0.0, cardWidth - textX), 38.0);
        self.metadataLabel.frame = CGRectMake(textX, 42.0, MAX(0.0, cardWidth - textX), 18.0);
        self.metadataLabel.textAlignment = NSTextAlignmentLeft;
    } else {
        self.cardView.frame = CGRectInset(self.contentView.bounds, 3.0, 4.0);
        CGFloat cardWidth = CGRectGetWidth(self.cardView.bounds);
        CGFloat thumb = round(cardWidth * 9.0 / 16.0);
        self.thumbnailView.frame = CGRectMake(0.0, 0.0, cardWidth, thumb);
        self.placeholderView.frame = CGRectMake((cardWidth - 56.0) * 0.5, (thumb - 56.0) * 0.5, 56.0, 56.0);
        self.resolutionLabel.frame = CGRectMake(6.0, thumb - 24.0, 42.0, 18.0);
        self.durationLabel.frame = CGRectMake(cardWidth - 50.0, thumb - 24.0, 44.0, 18.0);
        self.nameLabel.frame = CGRectMake(1.0, thumb + 7.0, cardWidth - 2.0, 36.0);
        self.metadataLabel.frame = CGRectMake(1.0, thumb + 44.0, cardWidth - 2.0, 17.0);
        self.metadataLabel.textAlignment = NSTextAlignmentLeft;
    }
    [self layoutProgressBar];
    self.cardView.transform = pressTransform;
}

- (void)setWatchedRatio:(CGFloat)watchedRatio {
    _watchedRatio = isfinite(watchedRatio)
        ? MAX(0.0, MIN(1.0, watchedRatio)) : 0.0;
    self.progressTrack.hidden = _watchedRatio <= 0.001;
    [self setNeedsLayout];
}

- (void)layoutProgressBar {
    if (self.progressTrack.hidden) return;
    CGFloat height = 3.0;
    CGRect thumbnail = self.thumbnailView.bounds;
    CGFloat trackWidth = CGRectGetWidth(thumbnail);
    CGFloat trackHeight = CGRectGetHeight(thumbnail);
    if (!isfinite(trackWidth) || !isfinite(trackHeight) ||
        trackWidth <= 0.0 || trackHeight < height) {
        self.progressTrack.frame = CGRectZero;
        self.progressFill.frame = CGRectZero;
        return;
    }
    self.progressTrack.frame = CGRectMake(0.0,
                                          trackHeight - height,
                                          trackWidth, height);
    CGFloat ratio = isfinite(self.watchedRatio)
        ? MAX(0.0, MIN(1.0, self.watchedRatio)) : 0.0;
    CGFloat width = trackWidth * ratio;
    if (!isfinite(width)) width = 0.0;
    width = MAX(0.0, MIN(trackWidth, width));
    self.progressFill.frame = CGRectMake(0.0, 0.0, width, height);
    if (width >= 1.0) {
        self.progressFill.image = YTzoomProgressFillImage(trackWidth, height);
    }
    [self.thumbnailView bringSubviewToFront:self.progressTrack];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:highlighted ? 0.12 : 0.25 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.cardView.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
        self.cardView.alpha = highlighted ? 0.8 : 1.0;
    } completion:nil];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.cardView.transform = CGAffineTransformIdentity;
    self.cardView.alpha = 1.0;
    self.watchedRatio = 0.0;
    self.representedPath = nil;
    self.thumbnailView.image = nil;
    self.placeholderView.hidden = NO;
    self.resolutionLabel.text = YTzoomLocalized(@"Video");
    self.durationLabel.text = YTzoomLocalized(@"--:--");
    self.metadataLabel.textAlignment = NSTextAlignmentLeft;
}

@end


@interface YTzoomDownloadJobRow : UIView
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, strong) UIView *cardView;
@property(nonatomic, strong) UIImageView *thumbnailView;
@property(nonatomic, strong) UIView *dimView;
@property(nonatomic, strong) UILabel *percentLabel;
@property(nonatomic, strong) UIImageView *failedIcon;
@property(nonatomic, strong) UIView *trackView;
@property(nonatomic, strong) UIView *fillView;
@property(nonatomic, assign) double progress;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *statusLabel;
@property(nonatomic, strong) UIButton *retryButton;
@property(nonatomic, strong) UIButton *closeButton;
@end

@implementation YTzoomDownloadJobRow
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.cardView = [UIView new];
        [self addSubview:self.cardView];
        self.thumbnailView = [UIImageView new];
        self.thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        self.thumbnailView.clipsToBounds = YES;
        self.thumbnailView.layer.cornerRadius = 12.0;
        self.thumbnailView.layer.cornerCurve = kCACornerCurveContinuous;
        [self.cardView addSubview:self.thumbnailView];
        self.dimView = [UIView new];
        self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        [self.thumbnailView addSubview:self.dimView];
        self.percentLabel = [UILabel new];
        self.percentLabel.font = [UIFont monospacedDigitSystemFontOfSize:17.0 weight:UIFontWeightBold];
        self.percentLabel.textColor = UIColor.whiteColor;
        self.percentLabel.textAlignment = NSTextAlignmentCenter;
        [self.thumbnailView addSubview:self.percentLabel];
        self.failedIcon = [[UIImageView alloc] initWithImage:
            [UIImage systemImageNamed:@"exclamationmark.triangle.fill"]];
        self.failedIcon.tintColor = UIColor.systemRedColor;
        self.failedIcon.contentMode = UIViewContentModeScaleAspectFit;
        [self.thumbnailView addSubview:self.failedIcon];
        self.trackView = [UIView new];
        self.trackView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        [self.thumbnailView addSubview:self.trackView];
        self.fillView = [UIView new];
        [self.trackView addSubview:self.fillView];
        self.titleLabel = [UILabel new];
        self.titleLabel.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightSemibold];
        self.titleLabel.numberOfLines = 2;
        [self.cardView addSubview:self.titleLabel];
        self.statusLabel = [UILabel new];
        self.statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:12.0 weight:UIFontWeightRegular];
        self.statusLabel.adjustsFontSizeToFitWidth = YES;
        self.statusLabel.minimumScaleFactor = 0.8;
        [self.cardView addSubview:self.statusLabel];
        self.retryButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.retryButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
        [self.retryButton addTarget:self action:@selector(retryTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:self.retryButton];
        self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.closeButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
        [self.closeButton addTarget:self action:@selector(closeTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.cardView addSubview:self.closeButton];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.cardView.frame = CGRectMake(12.0, 6.0, CGRectGetWidth(self.bounds) - 24.0, CGRectGetHeight(self.bounds) - 12.0);
    CGFloat cardWidth = CGRectGetWidth(self.cardView.bounds);
    CGFloat cardHeight = CGRectGetHeight(self.cardView.bounds);
    CGFloat thumbWidth = round(cardHeight * 16.0 / 9.0);
    self.thumbnailView.frame = CGRectMake(0.0, 0.0, thumbWidth, cardHeight);
    self.dimView.frame = self.thumbnailView.bounds;
    self.percentLabel.frame = self.thumbnailView.bounds;
    self.failedIcon.frame = CGRectMake((thumbWidth - 28.0) * 0.5, (cardHeight - 28.0) * 0.5, 28.0, 28.0);
    self.trackView.frame = CGRectMake(0.0, cardHeight - 3.0, thumbWidth, 3.0);
    self.fillView.frame = CGRectMake(0.0, 0.0, thumbWidth * self.progress, 3.0);
    CGFloat buttons = self.retryButton.hidden ? 36.0 : 70.0;
    self.closeButton.frame = CGRectMake(cardWidth - 36.0, (cardHeight - 32.0) * 0.5, 32.0, 32.0);
    self.retryButton.frame = CGRectMake(cardWidth - 70.0, (cardHeight - 32.0) * 0.5, 32.0, 32.0);
    CGFloat textX = thumbWidth + 12.0;
    CGFloat textWidth = MAX(0.0, cardWidth - textX - buttons - 6.0);
    self.titleLabel.frame = CGRectMake(textX, 2.0, textWidth, 38.0);
    self.statusLabel.frame = CGRectMake(textX, 42.0, textWidth, 18.0);
}

- (void)applyJob:(NSDictionary *)job {
    self.identifier = job[@"identifier"];
    BOOL failed = [job[@"failed"] boolValue];
    self.cardView.backgroundColor = UIColor.clearColor;
    self.thumbnailView.backgroundColor = YTzoomInterfaceSurfaceColor(self.traitCollection);
    self.titleLabel.text = job[@"title"];
    self.titleLabel.textColor = UIColor.labelColor;
    id thumbnail = job[@"thumbnail"];
    self.thumbnailView.image = [thumbnail isKindOfClass:UIImage.class] ? thumbnail : nil;
    double progress = [job[@"progress"] doubleValue];
    self.progress = isfinite(progress) ? MAX(0.0, MIN(1.0, progress)) : 0.0;
    self.percentLabel.text = [NSString stringWithFormat:@"%.0f%%", self.progress * 100.0];
    self.percentLabel.hidden = failed;
    self.failedIcon.hidden = !failed;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:failed ? 0.6 : 0.45];
    self.fillView.backgroundColor = failed ? UIColor.systemRedColor : YTzoomAccentColor();
    NSString *status = job[@"stage"];
    if (failed) {
        NSString *detail = job[@"detail"];
        if (detail.length != 0) status = [NSString stringWithFormat:@"%@ · %@", status, detail];
    } else {
        int64_t done = [job[@"downloadedBytes"] longLongValue];
        int64_t total = [job[@"totalBytes"] longLongValue];
        if (done > 0 && total > 0) {
            status = [NSString stringWithFormat:@"%@ · %@ / %@", status,
                [NSByteCountFormatter stringFromByteCount:done countStyle:NSByteCountFormatterCountStyleFile],
                [NSByteCountFormatter stringFromByteCount:total countStyle:NSByteCountFormatterCountStyleFile]];
        }
    }
    self.statusLabel.text = status;
    self.statusLabel.textColor = failed ? UIColor.systemRedColor : UIColor.secondaryLabelColor;
    self.retryButton.tintColor = UIColor.labelColor;
    self.closeButton.tintColor = UIColor.secondaryLabelColor;
    self.retryButton.hidden = !failed;
    [self setNeedsLayout];
}

- (void)retryTapped {
    if (self.identifier.length != 0) [YTzoomDownloadProgressView.sharedView retryJob:self.identifier];
}

- (void)closeTapped {
    if (self.identifier.length != 0) [YTzoomDownloadProgressView.sharedView cancelOrDismissJob:self.identifier];
}
@end

@interface YTzoomDownloadJobsHeader : UICollectionReusableView
@property(nonatomic, strong) UILabel *headerLabel;
@property(nonatomic, strong) NSMutableArray<YTzoomDownloadJobRow *> *rows;
- (void)applyJobs:(NSArray<NSDictionary *> *)jobs;
@end

@implementation YTzoomDownloadJobsHeader
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.clipsToBounds = YES;
        self.rows = [NSMutableArray array];
        self.headerLabel = [UILabel new];
        self.headerLabel.text = YTzoomLocalized(@"Downloading");
        self.headerLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
        self.headerLabel.textColor = UIColor.secondaryLabelColor;
        [self addSubview:self.headerLabel];
    }
    return self;
}

- (void)applyJobs:(NSArray<NSDictionary *> *)jobs {
    while (self.rows.count < jobs.count) {
        YTzoomDownloadJobRow *row = [YTzoomDownloadJobRow new];
        [self addSubview:row];
        [self.rows addObject:row];
    }
    while (self.rows.count > jobs.count) {
        [self.rows.lastObject removeFromSuperview];
        [self.rows removeLastObject];
    }
    for (NSUInteger index = 0; index < jobs.count; index++) [self.rows[index] applyJob:jobs[index]];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = CGRectGetWidth(self.bounds);
    self.headerLabel.frame = CGRectMake(18.0, 6.0, width - 36.0, 20.0);
    for (NSUInteger index = 0; index < self.rows.count; index++) {
        self.rows[index].frame = CGRectMake(0.0, 28.0 + 92.0 * index, width, 92.0);
    }
}
@end

@interface YTzoomDownloadsController ()
    <UICollectionViewDataSource, UICollectionViewDelegateFlowLayout,
     UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIStackView *controlBar;
@property(nonatomic, strong) UILabel *libraryTitleLabel;
@property(nonatomic, strong) UISegmentedControl *segmentedControl;
@property(nonatomic, strong) UICollectionView *collectionView;
@property(nonatomic, strong) UILabel *emptyLabel;
@property(nonatomic, strong) UIButton *libraryButton;
@property(nonatomic, strong) UIButton *sortButton;
@property(nonatomic, copy) NSArray<NSURL *> *files;
@property(nonatomic, copy) NSArray<NSDictionary *> *jobs;
@property(nonatomic, assign) NSInteger layoutMode;
@property(nonatomic, assign) NSInteger sortMode;
@property(nonatomic, strong) NSCache<NSString *, NSDictionary *> *metadataCache;
@property(nonatomic, strong) NSOperationQueue *metadataQueue;
@property(nonatomic, strong) NSMutableSet<NSString *> *metadataLoading;
@property(nonatomic, strong) UIView *miniPlayerBar;
@property(nonatomic, strong) YTzoomMiniPlayerView *miniVideoView;
@property(nonatomic, strong) UILabel *miniTitleLabel;
@property(nonatomic, strong) UILabel *miniSubtitleLabel;
@property(nonatomic, strong) UIButton *miniPlayButton;
@end

static NSString *YTzoomCategoryKey(NSInteger segment) {
    NSArray<NSString *> *names = @[@"All", @"Video", @"Audio", @"Shorts"];
    NSInteger index = MAX(0, MIN(segment, 3));
    return names[(NSUInteger)index];
}

static NSInteger YTzoomStoredMode(NSString *field, NSInteger segment,
                                  NSInteger limit) {
    NSString *key = [NSString stringWithFormat:@"YTzoomDownloads%@.%@",
                     field, YTzoomCategoryKey(segment)];
    id value = YTzoomPreferenceObject(key);
    if (![value respondsToSelector:@selector(integerValue)]) return 0;
    return MAX(0, MIN([value integerValue], limit - 1));
}

static void YTzoomStoreMode(NSString *field, NSInteger segment, NSInteger mode) {
    NSString *key = [NSString stringWithFormat:@"YTzoomDownloads%@.%@",
                     field, YTzoomCategoryKey(segment)];
    YTzoomSetPreferenceObject(key, @(mode));
}

@implementation YTzoomDownloadsController

- (void)applyTheme {
    UIColor *background = YTzoomInterfaceBackgroundColor(self.traitCollection);
    self.view.backgroundColor = background;
    self.collectionView.backgroundColor = background;
    self.miniPlayerBar.backgroundColor =
        YTzoomInterfaceSurfaceColor(self.traitCollection);
    self.miniVideoView.backgroundColor =
        YTzoomInterfaceSurfaceColor(self.traitCollection);
    self.miniTitleLabel.textColor = UIColor.labelColor;
    self.miniSubtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.miniPlayButton.tintColor = UIColor.labelColor;
    self.libraryTitleLabel.textColor = UIColor.labelColor;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"YTzoomDownloadsRoot";
    self.title = YTzoomLocalized(@"Downloads");
    self.metadataCache = [NSCache new];
    self.metadataQueue = [NSOperationQueue new];
    self.metadataQueue.maxConcurrentOperationCount = 3;
    self.metadataQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    self.metadataLoading = [NSMutableSet set];
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[
        YTzoomLocalized(@"All"), YTzoomLocalized(@"Video"), YTzoomLocalized(@"Audio"),
        YTzoomLocalized(@"Shorts")
    ]];
    id storedTab = YTzoomPreferenceObject(@"YTzoom.Preference.Downloads.SelectedSegment");
    if (![storedTab respondsToSelector:@selector(integerValue)]) {
        id legacy = YTzoomPreferenceObject(@"YTzoom.Preference.Downloads.SelectedTab");
        storedTab = [legacy respondsToSelector:@selector(integerValue)] ? @([legacy integerValue] + 1) : @0;
    }
    NSInteger tab = MAX(0, MIN([storedTab integerValue], 3));
    self.segmentedControl.selectedSegmentIndex = tab;
    self.layoutMode = YTzoomStoredMode(@"Layout", tab, 3);
    self.sortMode = YTzoomStoredMode(@"Sort", tab, 4);
    [self.segmentedControl addTarget:self action:@selector(segmentChanged)
                    forControlEvents:UIControlEventValueChanged];

    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.libraryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setImage:[[YTzoomGearImage()
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate]
        imageWithAlignmentRectInsets:UIEdgeInsetsMake(-1.0, -1.0, -1.0, -1.0)]
                    forState:UIControlStateNormal];
    [self applyLayoutButtonImage];
    for (UIButton *button in @[settingsButton, self.libraryButton]) {
        button.tintColor = UIColor.labelColor;
        [button.widthAnchor constraintEqualToConstant:36.0].active = YES;
    }
    settingsButton.accessibilityLabel = YTzoomLocalized(@"Settings");
    self.libraryButton.accessibilityLabel = YTzoomLocalized(@"View Options");
    [settingsButton addTarget:self action:@selector(openSettings)
             forControlEvents:UIControlEventTouchUpInside];
    [self.libraryButton addTarget:self action:@selector(showLibraryOptions:)
                  forControlEvents:UIControlEventTouchUpInside];

    NSArray *controls = self.hidesSettingsButton
        ? @[self.libraryButton]
        : @[settingsButton, self.libraryButton];
    self.controlBar = [[UIStackView alloc] initWithArrangedSubviews:controls];
    self.controlBar.axis = UILayoutConstraintAxisHorizontal;
    self.controlBar.spacing = 4.0;
    self.controlBar.translatesAutoresizingMaskIntoConstraints = NO;

    self.libraryTitleLabel = [UILabel new];
    self.libraryTitleLabel.text = @"YTzoom";
    self.libraryTitleLabel.font = [UIFont systemFontOfSize:22.0
                                                    weight:UIFontWeightBold];
    self.libraryTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.segmentedControl.translatesAutoresizingMaskIntoConstraints = NO;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.minimumLineSpacing = 0.0;
    self.collectionView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                              collectionViewLayout:layout];
    self.collectionView.translatesAutoresizingMaskIntoConstraints = NO;
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    [self.collectionView registerClass:YTzoomDownloadCell.class
             forCellWithReuseIdentifier:@"YTzoomDownloadCell"];
    [self.collectionView registerClass:YTzoomDownloadJobsHeader.class
            forSupplementaryViewOfKind:UICollectionElementKindSectionHeader
                   withReuseIdentifier:@"YTzoomDownloadJobsHeader"];
    self.jobs = YTzoomDownloadProgressView.sharedView.jobSnapshot;
    self.emptyLabel = [UILabel new];
    self.emptyLabel.text = YTzoomLocalized(@"No Downloads");
    self.emptyLabel.textColor = UIColor.secondaryLabelColor;
    self.emptyLabel.font = [UIFont systemFontOfSize:17.0 weight:UIFontWeightSemibold];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [self.view addSubview:self.libraryTitleLabel];
    [self.view addSubview:self.controlBar];
    [self.view addSubview:self.segmentedControl];
    [self.view addSubview:self.collectionView];
    [self.view addSubview:self.emptyLabel];
    UILayoutGuide *safeArea = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.libraryTitleLabel.topAnchor constraintEqualToAnchor:safeArea.topAnchor constant:9.0],
        [self.libraryTitleLabel.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:14.0],
        [self.libraryTitleLabel.heightAnchor constraintEqualToConstant:34.0],
        [self.controlBar.centerYAnchor constraintEqualToAnchor:self.libraryTitleLabel.centerYAnchor],
        [self.controlBar.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.libraryTitleLabel.trailingAnchor constant:12.0],
        [self.controlBar.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-10.0],
        [self.controlBar.heightAnchor constraintEqualToConstant:36.0],
        [self.segmentedControl.topAnchor constraintEqualToAnchor:self.libraryTitleLabel.bottomAnchor constant:7.0],
        [self.segmentedControl.leadingAnchor constraintEqualToAnchor:safeArea.leadingAnchor constant:14.0],
        [self.segmentedControl.trailingAnchor constraintEqualToAnchor:safeArea.trailingAnchor constant:-14.0],
        [self.segmentedControl.heightAnchor constraintEqualToConstant:32.0],
        [self.collectionView.topAnchor constraintEqualToAnchor:self.segmentedControl.bottomAnchor constant:8.0],
        [self.collectionView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.collectionView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.collectionView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadPlaybackChanged:)
        name:YTzoomDownloadPlaybackDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadPlaybackStopped:)
        name:YTzoomDownloadPlaybackDidStopNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadLibraryChanged:)
        name:YTzoomDownloadLibraryChanged object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadInfoChanged:)
        name:YTzoomDownloadInfoDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(downloadJobsChanged:)
        name:YTzoomDownloadJobsDidChangeNotification object:nil];
}

- (void)downloadJobsChanged:(NSNotification *)notification {
    (void)notification;
    NSArray<NSDictionary *> *jobs = YTzoomDownloadProgressView.sharedView.jobSnapshot;
    NSArray *oldIDs = [self.jobs valueForKey:@"identifier"];
    NSArray *newIDs = [jobs valueForKey:@"identifier"];
    self.jobs = jobs;
    if (![oldIDs isEqualToArray:newIDs]) {
        self.emptyLabel.hidden = self.files.count != 0 || self.jobs.count != 0;
        self.collectionView.hidden = self.files.count == 0 && self.jobs.count == 0;
        [self.collectionView.collectionViewLayout invalidateLayout];
        [self.collectionView reloadData];
        return;
    }
    for (UICollectionReusableView *view in
         [self.collectionView visibleSupplementaryViewsOfKind:UICollectionElementKindSectionHeader]) {
        if ([view isKindOfClass:YTzoomDownloadJobsHeader.class]) [(YTzoomDownloadJobsHeader *)view applyJobs:jobs];
    }
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView
           viewForSupplementaryElementOfKind:(NSString *)kind
                                 atIndexPath:(NSIndexPath *)indexPath {
    YTzoomDownloadJobsHeader *header = [collectionView
        dequeueReusableSupplementaryViewOfKind:kind
                           withReuseIdentifier:@"YTzoomDownloadJobsHeader"
                                  forIndexPath:indexPath];
    [header applyJobs:self.jobs ?: @[]];
    return header;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                  layout:(UICollectionViewLayout *)collectionViewLayout
referenceSizeForHeaderInSection:(NSInteger)section {
    (void)collectionViewLayout;
    (void)section;
    if (self.jobs.count == 0) return CGSizeZero;
    return CGSizeMake(CGRectGetWidth(collectionView.bounds), 36.0 + 92.0 * self.jobs.count);
}

- (void)downloadInfoChanged:(NSNotification *)notification {
    (void)notification;
    [self.collectionView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    YTzoomDownloadProgressView.sharedView.suppressed = YES;
    YTzoomApplyAppearance(self);
    [self applyTheme];
    [self reloadFiles];
    [self updateMiniPlayer];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    YTzoomDownloadProgressView.sharedView.suppressed = NO;
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (previousTraitCollection == nil ||
        [self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self applyTheme];
        [self.collectionView reloadData];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)closeDownloads {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)buildMiniPlayer {
    self.miniPlayerBar = [UIView new];
    self.miniPlayerBar.layer.cornerRadius = 11.0;
    self.miniPlayerBar.layer.masksToBounds = YES;
    self.miniPlayerBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.miniPlayerBar.hidden = YES;
    [self.view addSubview:self.miniPlayerBar];

    self.miniVideoView = [YTzoomMiniPlayerView new];
    self.miniVideoView.clipsToBounds = YES;
    self.miniVideoView.layer.cornerRadius = 8.0;
    self.miniVideoView.translatesAutoresizingMaskIntoConstraints = NO;
    self.miniTitleLabel = [UILabel new];
    self.miniTitleLabel.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    self.miniTitleLabel.numberOfLines = 1;
    self.miniSubtitleLabel = [UILabel new];
    self.miniSubtitleLabel.textColor = UIColor.secondaryLabelColor;
    self.miniSubtitleLabel.font = [UIFont systemFontOfSize:10.0];
    UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.miniTitleLabel, self.miniSubtitleLabel
    ]];
    labels.axis = UILayoutConstraintAxisVertical;
    labels.spacing = 2.0;

    self.miniPlayButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.miniPlayButton addTarget:self action:@selector(toggleMiniPlayback)
                  forControlEvents:UIControlEventTouchUpInside];
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.tintColor = UIColor.secondaryLabelColor;
    [close setImage:[UIImage systemImageNamed:@"xmark.circle.fill"]
           forState:UIControlStateNormal];
    [close addTarget:self action:@selector(closeMiniPlayer)
      forControlEvents:UIControlEventTouchUpInside];
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[
        self.miniVideoView, labels, self.miniPlayButton, close
    ]];
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    content.spacing = 9.0;
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [self.miniVideoView.widthAnchor constraintEqualToConstant:72.0].active = YES;
    [self.miniVideoView.heightAnchor constraintEqualToConstant:48.0].active = YES;
    [self.miniPlayButton.widthAnchor constraintEqualToConstant:32.0].active = YES;
    [close.widthAnchor constraintEqualToConstant:24.0].active = YES;
    [self.miniPlayerBar addSubview:content];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(openMiniPlayer)];
    tap.delegate = self;
    [self.miniPlayerBar addGestureRecognizer:tap];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.miniPlayerBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10.0],
        [self.miniPlayerBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10.0],
        [self.miniPlayerBar.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-7.0],
        [self.miniPlayerBar.heightAnchor constraintEqualToConstant:58.0],
        [content.topAnchor constraintEqualToAnchor:self.miniPlayerBar.topAnchor constant:5.0],
        [content.leadingAnchor constraintEqualToAnchor:self.miniPlayerBar.leadingAnchor constant:5.0],
        [content.trailingAnchor constraintEqualToAnchor:self.miniPlayerBar.trailingAnchor constant:-7.0],
        [content.bottomAnchor constraintEqualToAnchor:self.miniPlayerBar.bottomAnchor constant:-5.0]
    ]];
    [self applyTheme];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
       shouldReceiveTouch:(UITouch *)touch {
    (void)gestureRecognizer;
    return ![touch.view isKindOfClass:UIControl.class];
}

- (void)downloadPlaybackChanged:(NSNotification *)notification {
    (void)notification;
    [self updateMiniPlayer];
}

- (void)downloadPlaybackStopped:(NSNotification *)notification {
    (void)notification;
    [self updateMiniPlayer];
}

- (void)downloadLibraryChanged:(NSNotification *)notification {
    (void)notification;
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self reloadFiles]; });
        return;
    }
    [self reloadFiles];
}

- (void)updateMiniPlayer {
    if (self.miniPlayerBar == nil) {
        self.collectionView.contentInset = UIEdgeInsetsZero;
        self.collectionView.scrollIndicatorInsets = UIEdgeInsetsZero;
        return;
    }
    YTzoomDownloadPlaybackSession *session =
        YTzoomDownloadPlaybackSession.sharedSession;
    NSURL *URL = session.currentURL;
    BOOL active = URL != nil;
    self.miniPlayerBar.hidden = !active;
    self.collectionView.contentInset = UIEdgeInsetsMake(0.0, 0.0,
        active ? 74.0 : 0.0, 0.0);
    self.collectionView.scrollIndicatorInsets = self.collectionView.contentInset;
    if (!active) {
        self.miniVideoView.player = nil;
        return;
    }
    self.miniTitleLabel.text = URL.lastPathComponent.stringByDeletingPathExtension;
    self.miniSubtitleLabel.text = YTzoomLocalized(URL.URLByDeletingLastPathComponent.lastPathComponent);
    NSString *symbol = session.player.rate == 0.0f ? @"play.fill" : @"pause.fill";
    [self.miniPlayButton setImage:[UIImage systemImageNamed:symbol]
                         forState:UIControlStateNormal];
    self.miniVideoView.player = session.player;
}

- (void)toggleMiniPlayback {
    [YTzoomDownloadPlaybackSession.sharedSession togglePlayback];
    [self updateMiniPlayer];
}

- (void)closeMiniPlayer {
    [YTzoomDownloadPlaybackSession.sharedSession stop];
}

- (void)openMiniPlayer {
    if (YTzoomDownloadPlaybackSession.sharedSession.currentURL == nil ||
        self.presentedViewController != nil) {
        return;
    }
    BOOL audio = [YTzoomDownloadPlaybackSession.sharedSession.currentURL.path
        containsString:@"/Downloads/Audio/"];
    UIViewController *player = audio
        ? [[YTzoomAudioPlayerController alloc]
            initWithSession:YTzoomDownloadPlaybackSession.sharedSession]
        : [[YTzoomDownloadPlayerController alloc]
            initWithSession:YTzoomDownloadPlaybackSession.sharedSession];
    self.miniVideoView.player = nil;
    __weak YTzoomDownloadsController *weakSelf = self;
    if ([player isKindOfClass:YTzoomAudioPlayerController.class]) {
        ((YTzoomAudioPlayerController *)player).minimizeHandler = ^{
            [weakSelf updateMiniPlayer];
        };
    } else {
        ((YTzoomDownloadPlayerController *)player).minimizeHandler = ^{
            [weakSelf updateMiniPlayer];
        };
    }
    [self presentViewController:player animated:YES completion:nil];
}

- (void)openSettings {
    [self presentViewController:YTzoomMakeSettingsNavigationController()
                       animated:YES completion:nil];
}

- (NSArray<NSURL *> *)selectedDirectories {
    NSArray<NSString *> *names = @[@"Video", @"Audio", @"Shorts"];
    NSInteger segment = MAX(0, MIN(self.segmentedControl.selectedSegmentIndex, 3));
    NSURL *downloads = [YTzoomApplicationSupportDirectory()
        URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSMutableArray<NSURL *> *directories = [NSMutableArray array];
    for (NSUInteger index = 0; index < names.count; index++) {
        if (segment != 0 && (NSInteger)index != segment - 1) continue;
        NSURL *directory = [downloads URLByAppendingPathComponent:names[index] isDirectory:YES];
        [NSFileManager.defaultManager createDirectoryAtURL:directory
                               withIntermediateDirectories:YES
                                                attributes:nil error:nil];
        [directories addObject:directory];
    }
    return directories;
}

- (void)reloadFiles {
    NSMutableArray<NSURL *> *contents = [NSMutableArray array];
    for (NSURL *directory in self.selectedDirectories) {
        [contents addObjectsFromArray:
            [NSFileManager.defaultManager contentsOfDirectoryAtURL:directory
                                       includingPropertiesForKeys:@[
                                           NSURLContentModificationDateKey,
                                           NSURLFileSizeKey,
                                           NSURLIsRegularFileKey
                                       ] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] ?: @[]];
    }
    NSPredicate *regular = [NSPredicate predicateWithBlock:
        ^BOOL(NSURL *url, NSDictionary<NSString *, id> *bindings) {
            (void)bindings;
            NSNumber *value = nil;
            [url getResourceValue:&value forKey:NSURLIsRegularFileKey error:nil];
            static NSSet<NSString *> *extensions;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                extensions = [NSSet setWithArray:@[
                    @"mp4", @"m4v", @"mov", @"m4a", @"mp3", @"aac", @"webm"
                ]];
            });
            return value.boolValue &&
                [extensions containsObject:url.pathExtension.lowercaseString];
        }];
    NSArray<NSURL *> *filtered = [contents filteredArrayUsingPredicate:regular];
    self.files = [filtered sortedArrayUsingComparator:
        ^NSComparisonResult(NSURL *left, NSURL *right) {
            if (self.sortMode >= 2) {
                NSComparisonResult result = [left.lastPathComponent
                    localizedCaseInsensitiveCompare:right.lastPathComponent];
                return self.sortMode == 2 ? result : (NSComparisonResult)(-result);
            }
            NSDate *leftDate = nil;
            NSDate *rightDate = nil;
            [left getResourceValue:&leftDate forKey:NSURLContentModificationDateKey error:nil];
            [right getResourceValue:&rightDate forKey:NSURLContentModificationDateKey error:nil];
            NSComparisonResult result = [leftDate ?: NSDate.distantPast
                compare:rightDate ?: NSDate.distantPast];
            return self.sortMode == 1 ? result : (NSComparisonResult)(-result);
        }];
    self.emptyLabel.hidden = self.files.count != 0 || self.jobs.count != 0;
    self.collectionView.hidden = self.files.count == 0 && self.jobs.count == 0;
    [self.collectionView reloadData];
}

- (void)segmentChanged {
    NSInteger tab = self.segmentedControl.selectedSegmentIndex;
    YTzoomSetPreferenceObject(@"YTzoom.Preference.Downloads.SelectedSegment", @(tab));
    self.layoutMode = YTzoomStoredMode(@"Layout", tab, 3);
    self.sortMode = YTzoomStoredMode(@"Sort", tab, 4);
    [self applyLayoutButtonImage];
    [self applySortButtonImage];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self reloadFiles];
}

- (void)applySortButtonImage {
    [self updateLibraryMenu];
}

- (void)toggleSort {
    self.sortMode = (self.sortMode + 1) % 4;
    YTzoomStoreMode(@"Sort", self.segmentedControl.selectedSegmentIndex,
                    self.sortMode);
    [self applySortButtonImage];
    [self reloadFiles];
}

- (void)applyLayoutButtonImage {
    UIImage *image = [[UIImage systemImageNamed:@"slider.horizontal.3"]
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    [self.libraryButton setImage:image forState:UIControlStateNormal];
    [self updateLibraryMenu];
}

- (BOOL)presentNativeLibrarySheetWithTitle:(NSString *)title
                                    actions:(NSArray *)actions
                                 sourceView:(UIView *)sourceView {
    (void)sourceView;
    id sheet = YTzoomMakeSheet(@"", title);
    if (sheet == nil) return NO;
    @try {
        id header = [sheet valueForKey:@"_headerView"];
        SEL divider = NSSelectorFromString(@"showHeaderDivider");
        if ([header respondsToSelector:divider]) {
            ((void (*)(id, SEL))objc_msgSend)(header, divider);
        }
    } @catch (__unused NSException *exception) {
    }
    SEL addAction = NSSelectorFromString(@"addAction:");
    for (id action in actions) {
        if (action != NSNull.null && [sheet respondsToSelector:addAction]) {
            ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
        }
    }
    if (YTzoomShowSheet(sheet, self)) return YES;
    return NO;
}

- (void)showLibraryOptions:(UIButton *)sender {
    __weak __typeof__(self) weakSelf = self;
    NSArray<NSString *> *titles = @[
        YTzoomLocalized(@"Cards"), YTzoomLocalized(@"List"),
        YTzoomLocalized(@"Grid"), YTzoomLocalized(@"Newest"),
        YTzoomLocalized(@"Oldest"), YTzoomLocalized(@"A-Z"), YTzoomLocalized(@"Z-A")
    ];
    NSArray<NSString *> *symbols = @[
        @"rectangle.grid.1x2", @"list.bullet", @"square.grid.2x2",
        @"clock.arrow.circlepath", @"clock.arrow.2.circlepath",
        @"arrow.down", @"arrow.up"
    ];
    NSMutableArray *actions = [NSMutableArray array];
    for (NSInteger index = 0; index < 7; index++) {
        BOOL selected = index < 3 ? self.layoutMode == index
                                  : self.sortMode == index - 3;
        NSString *title = titles[(NSUInteger)index];
        if (selected) title = [@"\u2713  " stringByAppendingString:title];
        NSInteger capturedIndex = index;
        id action = [self nativeActionWithTitle:title asset:@""
            symbol:symbols[(NSUInteger)index]
            handler:^(__unused UIAlertAction *alertAction) {
                __typeof__(self) strongSelf = weakSelf;
                if (strongSelf == nil) return;
                if (capturedIndex < 3) {
                    strongSelf.layoutMode = capturedIndex;
                    YTzoomStoreMode(@"Layout",
                        strongSelf.segmentedControl.selectedSegmentIndex,
                        capturedIndex);
                    [strongSelf.collectionView.collectionViewLayout invalidateLayout];
                    [strongSelf.collectionView reloadData];
                } else {
                    strongSelf.sortMode = capturedIndex - 3;
                    YTzoomStoreMode(@"Sort",
                        strongSelf.segmentedControl.selectedSegmentIndex,
                        capturedIndex - 3);
                    [strongSelf reloadFiles];
                }
            }];
        [actions addObject:action ?: NSNull.null];
    }
    if ([self presentNativeLibrarySheetWithTitle:YTzoomLocalized(@"View Options")
                                         actions:actions sourceView:sender]) {
        return;
    }
    self.libraryButton.showsMenuAsPrimaryAction = YES;
}

- (void)updateLibraryMenu {
    if (self.libraryButton == nil) return;
    __weak __typeof__(self) weakSelf = self;
    NSArray<NSString *> *layoutTitles = @[
        YTzoomLocalized(@"Cards"), YTzoomLocalized(@"List"),
        YTzoomLocalized(@"Grid")
    ];
    NSArray<NSString *> *layoutSymbols = @[
        @"rectangle.grid.1x2", @"list.bullet", @"square.grid.2x2"
    ];
    NSMutableArray<UIMenuElement *> *layoutActions = [NSMutableArray array];
    for (NSInteger mode = 0; mode < 3; mode++) {
        UIAction *action = [UIAction actionWithTitle:layoutTitles[(NSUInteger)mode]
            image:[UIImage systemImageNamed:layoutSymbols[(NSUInteger)mode]]
            identifier:nil handler:^(__unused UIAction *selected) {
                __typeof__(self) strongSelf = weakSelf;
                if (strongSelf == nil) return;
                strongSelf.layoutMode = mode;
                YTzoomStoreMode(@"Layout",
                    strongSelf.segmentedControl.selectedSegmentIndex, mode);
                [strongSelf updateLibraryMenu];
                [strongSelf.collectionView.collectionViewLayout invalidateLayout];
                [strongSelf.collectionView reloadData];
            }];
        action.state = self.layoutMode == mode
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layoutActions addObject:action];
    }

    NSArray<NSString *> *sortTitles = @[
        YTzoomLocalized(@"Newest"), YTzoomLocalized(@"Oldest"),
        YTzoomLocalized(@"A-Z"), YTzoomLocalized(@"Z-A")
    ];
    NSArray<NSString *> *sortSymbols = @[
        @"arrow.down.to.line.circle", @"arrow.up.to.line.circle",
        @"textformat.abc", @"textformat.abc"
    ];
    NSMutableArray<UIMenuElement *> *sortActions = [NSMutableArray array];
    for (NSInteger mode = 0; mode < 4; mode++) {
        UIImage *sortImage = [UIImage systemImageNamed:sortSymbols[(NSUInteger)mode]];
        if (mode == 3 && sortImage != nil) {
            sortImage = [UIImage imageWithCGImage:sortImage.CGImage
                                           scale:sortImage.scale
                                     orientation:UIImageOrientationUpMirrored];
        }
        UIAction *action = [UIAction actionWithTitle:sortTitles[(NSUInteger)mode]
            image:sortImage
            identifier:nil handler:^(__unused UIAction *selected) {
                __typeof__(self) strongSelf = weakSelf;
                if (strongSelf == nil) return;
                strongSelf.sortMode = mode;
                YTzoomStoreMode(@"Sort",
                    strongSelf.segmentedControl.selectedSegmentIndex, mode);
                [strongSelf updateLibraryMenu];
                [strongSelf reloadFiles];
            }];
        action.state = self.sortMode == mode
            ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sortActions addObject:action];
    }
    UIMenu *layoutMenu = [UIMenu menuWithTitle:YTzoomLocalized(@"Layout")
                                      children:layoutActions];
    UIMenu *sortMenu = [UIMenu menuWithTitle:YTzoomLocalized(@"Sort")
                                    children:sortActions];
    self.libraryButton.menu = [UIMenu menuWithTitle:@""
                                           children:@[layoutMenu, sortMenu]];
    self.libraryButton.showsMenuAsPrimaryAction = NO;
}

- (void)toggleLayout {
    self.layoutMode = (self.layoutMode + 1) % 3;
    YTzoomStoreMode(@"Layout", self.segmentedControl.selectedSegmentIndex,
                    self.layoutMode);
    [self applyLayoutButtonImage];
    [self.collectionView.collectionViewLayout invalidateLayout];
    [self.collectionView reloadData];
}

- (NSInteger)collectionView:(UICollectionView *)collectionView
     numberOfItemsInSection:(NSInteger)section {
    (void)collectionView;
    (void)section;
    return (NSInteger)self.files.count;
}

- (CGSize)collectionView:(UICollectionView *)collectionView
                   layout:(UICollectionViewLayout *)collectionViewLayout
   sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionViewLayout;
    (void)indexPath;
    CGFloat width = CGRectGetWidth(collectionView.bounds);
    if (self.layoutMode == 0) {
        CGFloat cardWidth = MIN(720.0, width - 24.0);
        return CGSizeMake(width, round(cardWidth * 9.0 / 16.0) + 86.0);
    }
    if (self.layoutMode == 1) {
        return CGSizeMake(width, 92.0);
    }
    NSInteger columns = width >= 700.0 ? 3 : 2;
    CGFloat itemWidth = floor((width - 12.0 - 6.0 * (columns - 1)) / columns);
    return CGSizeMake(itemWidth, round((itemWidth - 6.0) * 9.0 / 16.0) + 70.0);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)collectionView
                        layout:(UICollectionViewLayout *)collectionViewLayout
        insetForSectionAtIndex:(NSInteger)section {
    (void)collectionView;
    (void)collectionViewLayout;
    (void)section;
    return self.layoutMode == 2
        ? UIEdgeInsetsMake(4.0, 6.0, 18.0, 6.0)
        : UIEdgeInsetsMake(3.0, 0.0, 18.0, 0.0);
}

- (CGFloat)collectionView:(UICollectionView *)collectionView
                    layout:(UICollectionViewLayout *)collectionViewLayout
minimumInteritemSpacingForSectionAtIndex:(NSInteger)section {
    (void)collectionView;
    (void)collectionViewLayout;
    (void)section;
    return self.layoutMode == 2 ? 6.0 : 0.0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView
                   cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    YTzoomDownloadCell *cell = [collectionView
        dequeueReusableCellWithReuseIdentifier:@"YTzoomDownloadCell"
                                  forIndexPath:indexPath];
    NSURL *url = self.files[(NSUInteger)indexPath.item];
    NSNumber *size = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    cell.layoutMode = self.layoutMode;
    cell.representedPath = url.path;
    cell.watchedRatio = YTzoomDownloadProgressRatio(url);
    cell.nameLabel.text = url.lastPathComponent.stringByDeletingPathExtension;
    cell.metadataLabel.text = [NSByteCountFormatter stringFromByteCount:size.longLongValue
                                                              countStyle:NSByteCountFormatterCountStyleFile];
    if (![cell.representedPath isEqualToString:url.path] || [self.metadataCache objectForKey:url.path] == nil) {
        cell.thumbnailView.image = nil;
        cell.placeholderView.hidden = NO;
        cell.resolutionLabel.text = YTzoomLocalized(@"Video");
        cell.durationLabel.text = YTzoomLocalized(@"--:--");
    }
    [cell applyTheme];
    BOOL hasLongPress = NO;
    for (UIGestureRecognizer *recognizer in cell.gestureRecognizers) {
        if ([recognizer isKindOfClass:UILongPressGestureRecognizer.class]) {
            hasLongPress = YES;
            break;
        }
    }
    if (!hasLongPress) {
        UILongPressGestureRecognizer *press =
            [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                         action:@selector(cellHeld:)];
        press.minimumPressDuration = 0.25;
        [cell addGestureRecognizer:press];
    }
    [cell setNeedsLayout];
    [self loadMetadataForURL:url cell:cell size:size.longLongValue];
    return cell;
}

static UIImage *YTzoomDecodedThumbnail(CGImageSourceRef source) {
    if (source == NULL) return nil;
    NSDictionary *options = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @1280
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    if (image == NULL) return nil;
    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

- (void)loadMetadataForURL:(NSURL *)url
                       cell:(YTzoomDownloadCell *)cell
                       size:(long long)size {
    NSString *path = url.path;
    NSDictionary *cached = [self.metadataCache objectForKey:path];
    if (cached != nil && ![cached[@"artwork"] boolValue]) {
        NSURL *base = url.URLByDeletingPathExtension;
        for (NSString *extension in @[@"jpg", @"png"]) {
            if ([NSFileManager.defaultManager fileExistsAtPath:[base URLByAppendingPathExtension:extension].path]) {
                [self.metadataCache removeObjectForKey:path];
                cached = nil;
                break;
            }
        }
    }
    if (cached != nil && [cached[@"size"] longLongValue] == size) {
        [self applyMetadata:cached toCell:cell path:path size:size];
        return;
    }
    if ([self.metadataLoading containsObject:path]) return;
    [self.metadataLoading addObject:path];
    __weak YTzoomDownloadsController *weakSelf = self;
    [self.metadataQueue addOperationWithBlock:^{
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        CGSize dimensions = track == nil ? CGSizeZero
            : CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
        UIImage *thumbnail = nil;
        NSData *artwork = YTzoomMediaArtworkData(url);
        if (artwork.length != 0) {
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)artwork, NULL);
            thumbnail = YTzoomDecodedThumbnail(source);
            if (source != NULL) CFRelease(source);
        }
        if (thumbnail == nil && track != nil) {
            AVAssetImageGenerator *generator =
                [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
            generator.appliesPreferredTrackTransform = YES;
            generator.maximumSize = CGSizeMake(1280.0, 720.0);
            CGImageRef image = [generator copyCGImageAtTime:
                CMTimeMakeWithSeconds(duration > 2.0 ? 1.0 : 0.0, 600)
                                                    actualTime:NULL error:nil];
            if (image != NULL) {
                thumbnail = [UIImage imageWithCGImage:image];
                CGImageRelease(image);
            }
        }
        NSDictionary *metadata = @{
            @"duration": YTzoomDurationText(duration),
            @"resolution": YTzoomResolutionText(dimensions),
            @"image": thumbnail ?: NSNull.null,
            @"artwork": @(artwork.length != 0),
            @"size": @(size)
        };
        dispatch_async(dispatch_get_main_queue(), ^{
            YTzoomDownloadsController *strongSelf = weakSelf;
            if (strongSelf == nil) return;
            [strongSelf.metadataLoading removeObject:path];
            NSNumber *current = nil;
            NSURL *fresh = [NSURL fileURLWithPath:path];
            [fresh getResourceValue:&current forKey:NSURLFileSizeKey error:nil];
            if (current != nil && current.longLongValue != size) {
                for (YTzoomDownloadCell *visible in strongSelf.collectionView.visibleCells) {
                    if ([visible isKindOfClass:YTzoomDownloadCell.class] &&
                        [visible.representedPath isEqualToString:path]) {
                        [strongSelf loadMetadataForURL:fresh cell:visible size:current.longLongValue];
                        break;
                    }
                }
                return;
            }
            [strongSelf.metadataCache setObject:metadata forKey:path];
            for (YTzoomDownloadCell *visible in strongSelf.collectionView.visibleCells) {
                if ([visible isKindOfClass:YTzoomDownloadCell.class] &&
                    [visible.representedPath isEqualToString:path]) {
                    [strongSelf applyMetadata:metadata toCell:visible path:path size:size];
                }
            }
        });
    }];
}

- (void)applyMetadata:(NSDictionary *)metadata
                toCell:(YTzoomDownloadCell *)cell
                  path:(NSString *)path
                  size:(long long)size {
    if (![cell.representedPath isEqualToString:path]) {
        return;
    }
    NSString *duration = metadata[@"duration"];
    NSString *resolution = metadata[@"resolution"];
    UIImage *image = [metadata[@"image"] isKindOfClass:UIImage.class]
        ? metadata[@"image"] : nil;
    cell.durationLabel.text = duration;
    cell.resolutionLabel.text = resolution.length != 0 ? resolution : YTzoomLocalized(@"Audio");
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:size
                                                        countStyle:NSByteCountFormatterCountStyleFile];
    NSString *details = sizeText;
    NSString *channel = YTzoomStoredChannelName([NSURL fileURLWithPath:path]);
    cell.metadataLabel.text = channel.length != 0
        ? [NSString stringWithFormat:@"%@  ·  %@", channel, details] : details;
    cell.thumbnailView.image = image;
    cell.placeholderView.hidden = image != nil;
}

- (void)collectionView:(UICollectionView *)collectionView
didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    (void)collectionView;
    NSURL *URL = self.files[(NSUInteger)indexPath.item];
    YTzoomDownloadPlaybackSession *session =
        YTzoomDownloadPlaybackSession.sharedSession;
    [session loadURL:URL playlist:self.files index:indexPath.item];
    [self openMiniPlayer];
}

- (void)playURLWithSystemPlayer:(NSURL *)url {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:asset];
    if (![NSUserDefaults.standardUserDefaults
            boolForKey:@"YTzoom.Preference.Downloads.SubtitlesHidden"]) {
        NSString *key = @"availableMediaCharacteristicsWithMediaSelectionOptions";
        [asset loadValuesAsynchronouslyForKeys:@[key] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                AVMediaSelectionGroup *group = [asset
                    mediaSelectionGroupForMediaCharacteristic:
                        AVMediaCharacteristicLegible];
                if (group == nil) {
                    YTzoomDownloadLog(@"subs", @"system player no legible group");
                    return;
                }
                for (AVMediaSelectionOption *option in group.options) {
                    if (option.displayName.length == 0) continue;
                    if ([option hasMediaCharacteristic:
                            AVMediaCharacteristicContainsOnlyForcedSubtitles]) {
                        continue;
                    }
                    [item selectMediaOption:option inMediaSelectionGroup:group];
                    YTzoomDownloadLog(@"subs", @"system player selected %@",
                                      option.displayName);
                    return;
                }
                YTzoomDownloadLog(@"subs", @"system player %lu options unused",
                                  (unsigned long)group.options.count);
            });
        }];
    }
    AVPlayerViewController *playerController = [AVPlayerViewController new];
    playerController.player = [AVPlayer playerWithPlayerItem:item];
    playerController.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:playerController animated:YES completion:^{
        [playerController.player play];
    }];
}

- (void)cellHeld:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) {
        return;
    }
    YTzoomDownloadCell *cell = [gesture.view isKindOfClass:YTzoomDownloadCell.class]
        ? (YTzoomDownloadCell *)gesture.view
        : nil;
    NSIndexPath *indexPath = cell == nil
        ? nil
        : [self.collectionView indexPathForCell:cell];
    if (indexPath == nil) {
        return;
    }
    UIImpactFeedbackGenerator *feedback =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [feedback impactOccurred];
    NSURL *url = self.files[(NSUInteger)indexPath.item];
    [UIView animateWithDuration:0.14 delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        cell.cardView.transform = CGAffineTransformMakeScale(0.94, 0.94);
        cell.cardView.alpha = 0.75;
    } completion:^(__unused BOOL finished) {
        [UIView animateWithDuration:0.3 delay:0.0 usingSpringWithDamping:0.6 initialSpringVelocity:0.0
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            cell.cardView.transform = CGAffineTransformIdentity;
            cell.cardView.alpha = 1.0;
        } completion:nil];
        [self showItemMenuForURL:url sourceView:cell];
    }];
}

- (id)nativeActionWithTitle:(NSString *)title
                       asset:(NSString *)asset
                      symbol:(NSString *)symbol
                     handler:(void (^)(UIAlertAction *action))handler {
    Class actionClass = NSClassFromString(@"YTActionSheetAction");
    SEL selector = NSSelectorFromString(@"actionWithTitle:iconImage:style:handler:");
    if (actionClass == Nil || ![actionClass respondsToSelector:selector]) {
        return nil;
    }
    UIImage *image = [YTzoomAssetImage(asset, symbol)
        imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return ((id (*)(id, SEL, id, id, NSInteger, id))objc_msgSend)(
        actionClass, selector, title, image, 0, handler
    );
}

- (BOOL)showNativeMenuForURL:(NSURL *)url sourceView:(UIView *)sourceView {
    (void)sourceView;
    NSString *title = url.lastPathComponent.stringByDeletingPathExtension;
    id sheet = YTzoomMakeSheet(@"", title);
    if (sheet == nil) {
        return NO;
    }
    @try {
        id header = [sheet valueForKey:@"_headerView"];
        SEL divider = NSSelectorFromString(@"showHeaderDivider");
        if ([header respondsToSelector:divider]) {
            ((void (*)(id, SEL))objc_msgSend)(header, divider);
        }
    } @catch (__unused NSException *exception) {
    }
    NSArray *actions = @[
        [self nativeActionWithTitle:YTzoomLocalized(@"Default Player") asset:@"ig_icon_play_outline_24_Normal"
                             symbol:@"play" handler:^(__unused UIAlertAction *action) {
            [self playURLWithSystemPlayer:url];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Video Info") asset:@"ic_info_outline_3x_Normal"
                             symbol:@"info.circle" handler:^(__unused UIAlertAction *action) {
            [self showInfoForURL:url];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Save to Photos") asset:@"ig_icon_photo_outline_24_Normal"
                             symbol:@"photo" handler:^(__unused UIAlertAction *action) {
            YTzoomSaveVideoToPhotos(url);
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Save Artwork") asset:@"ig_icon_photo_gallery_outline_24_Normal"
                             symbol:@"photo.on.rectangle" handler:^(__unused UIAlertAction *action) {
            [self saveArtworkForURL:url];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Share") asset:@"share_24pt_3x_Normal"
                             symbol:@"square.and.arrow.up" handler:^(__unused UIAlertAction *action) {
            [self shareURL:url sourceView:sourceView];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Delete") asset:@"delete_24pt_3x_Normal"
                             symbol:@"trash" handler:^(__unused UIAlertAction *action) {
            [self deleteURL:url];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Rename") asset:@"pencil_24pt_3x_Normal"
                             symbol:@"pencil" handler:^(__unused UIAlertAction *action) {
            [self renameURL:url];
        }] ?: NSNull.null,
        [self nativeActionWithTitle:YTzoomLocalized(@"Delete All") asset:@"qtm_ic_delete_3x_Normal"
                             symbol:@"trash.fill" handler:^(__unused UIAlertAction *action) {
            [self confirmDeleteAll];
        }] ?: NSNull.null
    ];
    SEL addAction = NSSelectorFromString(@"addAction:");
    for (id action in actions) {
        if (action != NSNull.null && [sheet respondsToSelector:addAction]) {
            ((void (*)(id, SEL, id))objc_msgSend)(sheet, addAction, action);
        }
    }
    if (YTzoomShowSheet(sheet, self)) return YES;
    return NO;
}

- (void)showItemMenuForURL:(NSURL *)url sourceView:(UIView *)sourceView {
    if ([self showNativeMenuForURL:url sourceView:sourceView]) {
        return;
    }
    UIAlertController *menu = [UIAlertController
        alertControllerWithTitle:url.lastPathComponent.stringByDeletingPathExtension
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Default Player"), @"play", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            [self playURLWithSystemPlayer:url];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Video Info"), @"info.circle", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            [self showInfoForURL:url];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Save to Photos"), @"photo", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            YTzoomSaveVideoToPhotos(url);
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Save Artwork"), @"photo.on.rectangle", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            [self saveArtworkForURL:url];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Share"), @"square.and.arrow.up", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            [self shareURL:url sourceView:sourceView];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Delete"), @"trash", UIAlertActionStyleDestructive,
        ^(__unused UIAlertAction *action) {
            [self deleteURL:url];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Rename"), @"pencil", UIAlertActionStyleDefault,
        ^(__unused UIAlertAction *action) {
            [self renameURL:url];
        })];
    [menu addAction:YTzoomMenuAction(YTzoomLocalized(@"Delete All"), @"trash.fill", UIAlertActionStyleDestructive,
        ^(__unused UIAlertAction *action) {
            [self confirmDeleteAll];
        })];
    [menu addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    if (menu.popoverPresentationController != nil) {
        menu.popoverPresentationController.sourceView = sourceView;
        menu.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)showInfoForURL:(NSURL *)url {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    NSNumber *size = nil;
    NSDate *created = nil;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    [url getResourceValue:&created forKey:NSURLCreationDateKey error:nil];
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    CGSize dimensions = track == nil ? CGSizeZero
        : CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterMediumStyle;
    formatter.timeStyle = NSDateFormatterMediumStyle;
    NSString *fileSize = [NSByteCountFormatter
        stringFromByteCount:size.longLongValue
        countStyle:NSByteCountFormatterCountStyleFile];
    NSMutableString *details = [NSMutableString string];
    [details appendFormat:YTzoomLocalized(@"Format: %@\n"), url.pathExtension.uppercaseString];
    [details appendFormat:YTzoomLocalized(@"File Size: %@\n"), fileSize];
    [details appendFormat:YTzoomLocalized(@"Duration: %@\n"), YTzoomDurationText(duration)];
    if (track != nil) {
        [details appendFormat:YTzoomLocalized(@"Dimensions: %.0f×%.0f\n"),
            fabs(dimensions.width), fabs(dimensions.height)];
        [details appendFormat:YTzoomLocalized(@"Bitrate: %.2f Kbps\n"),
            track.estimatedDataRate / 1000.0];
        [details appendFormat:YTzoomLocalized(@"Frame Rate: %.2f fps\n"), track.nominalFrameRate];
    }
    if (created != nil) {
        [details appendFormat:YTzoomLocalized(@"Created: %@"), [formatter stringFromDate:created]];
    }

    if (!YTzoomShowYouTubeDialog(YTzoomLocalized(@"Video Info"), details)) {
        YTzoomShowNotice(YTzoomLocalized(@"Video information unavailable"));
    }
}

- (void)saveArtworkForURL:(NSURL *)url {
    NSDictionary *metadata = [self.metadataCache objectForKey:url.path];
    UIImage *image = [metadata[@"image"] isKindOfClass:UIImage.class]
        ? metadata[@"image"] : nil;
    if (image != nil) {
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, NULL);
    }
}

- (void)shareURL:(NSURL *)url sourceView:(UIView *)sourceView {
    UIActivityViewController *share =
        [[UIActivityViewController alloc] initWithActivityItems:@[url]
                                         applicationActivities:nil];
    if (share.popoverPresentationController != nil) {
        share.popoverPresentationController.sourceView = sourceView;
        share.popoverPresentationController.sourceRect = sourceView.bounds;
    }
    [self presentViewController:share animated:YES completion:nil];
}

- (void)deleteURL:(NSURL *)url {
    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    for (NSURL *sidecar in YTzoomSidecarURLs(url)) {
        [NSFileManager.defaultManager removeItemAtURL:sidecar error:nil];
    }
    [self.metadataCache removeObjectForKey:url.path];
    [self reloadFiles];
}

- (void)renameURL:(NSURL *)url {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:YTzoomLocalized(@"Rename")
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = url.lastPathComponent.stringByDeletingPathExtension;
        field.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Cancel")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:YTzoomLocalized(@"Save")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *name = alert.textFields.firstObject.text;
            if (name.length == 0) {
                return;
            }
            NSURL *destination = [[url URLByDeletingLastPathComponent]
                URLByAppendingPathComponent:[name stringByAppendingPathExtension:url.pathExtension]];
            [NSFileManager.defaultManager moveItemAtURL:url toURL:destination error:nil];
            NSArray<NSURL *> *oldSidecars = YTzoomSidecarURLs(url);
            NSArray<NSURL *> *newSidecars = YTzoomSidecarURLs(destination);
            for (NSUInteger index = 0; index < oldSidecars.count; index++) {
                if ([NSFileManager.defaultManager fileExistsAtPath:oldSidecars[index].path]) {
                    [NSFileManager.defaultManager moveItemAtURL:oldSidecars[index]
                        toURL:newSidecars[index] error:nil];
                }
            }
            [self.metadataCache removeObjectForKey:url.path];
            [self reloadFiles];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmDeleteAll {
    __weak __typeof__(self) weakSelf = self;
    BOOL shown = YTzoomShowYouTubeConfirmation(
        YTzoomLocalized(@"Delete All"),
        YTzoomLocalized(@"Delete every item in this section?"),
        YTzoomLocalized(@"Delete All"),
        ^{
            __typeof__(self) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            for (NSURL *url in strongSelf.files) {
                [NSFileManager.defaultManager removeItemAtURL:url error:nil];
                for (NSURL *sidecar in YTzoomSidecarURLs(url)) {
                    [NSFileManager.defaultManager removeItemAtURL:sidecar error:nil];
                }
            }
            [strongSelf.metadataCache removeAllObjects];
            [strongSelf reloadFiles];
        }
    );
    if (!shown) {
        YTzoomShowNotice(YTzoomLocalized(@"Delete confirmation unavailable"));
    }
}

@end
