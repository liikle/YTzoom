#import "DownloadSponsor.h"
#import "../../Runtime/Preferences.h"
#import "../SponsorBlock/SponsorClient.h"
#import "../SponsorBlock/SponsorPreferences.h"

#import <sys/xattr.h>

static const char *YTzoomSponsorAttribute = "com.ytzoom.sponsorblock";

NSNotificationName const YTzoomDownloadInfoDidChangeNotification =
    @"YTzoomDownloadInfoDidChangeNotification";

static NSArray<NSString *> *YTzoomAllSponsorCategories(void) {
    NSMutableArray<NSString *> *categories = [NSMutableArray array];
    for (NSDictionary *definition in YTzoomSponsorCategoryDefinitions()) {
        if ([definition[@"id"] isKindOfClass:NSString.class]) {
            [categories addObject:definition[@"id"]];
        }
    }
    return categories;
}

static NSDictionary *YTzoomReadSponsorRecord(NSURL *fileURL) {
    const char *path = fileURL.fileSystemRepresentation;
    if (path == NULL) return nil;
    ssize_t length = getxattr(path, YTzoomSponsorAttribute, NULL, 0, 0, 0);
    if (length <= 0 || length > 256 * 1024) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)length];
    if (getxattr(path, YTzoomSponsorAttribute, data.mutableBytes,
                 (size_t)length, 0, 0) != length) {
        return nil;
    }
    id record = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [record isKindOfClass:NSDictionary.class] ? record : nil;
}

static void YTzoomWriteSponsorRecord(NSURL *fileURL, NSString *videoID,
                                     NSString *author, NSArray *segments) {
    const char *path = fileURL.fileSystemRepresentation;
    if (path == NULL || videoID.length == 0) return;
    NSMutableDictionary *record = [@{@"id": videoID, @"segments": segments ?: @[]} mutableCopy];
    if (author.length != 0) record[@"author"] = author;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (data.length == 0) return;
    setxattr(path, YTzoomSponsorAttribute, data.bytes, data.length, 0, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTzoomDownloadInfoDidChangeNotification object:fileURL];
    });
}

static NSArray *YTzoomValidSegments(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *segments = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        id start = item[@"start"];
        id end = item[@"end"];
        id category = item[@"category"];
        if (![start isKindOfClass:NSNumber.class] || ![end isKindOfClass:NSNumber.class] ||
            ![category isKindOfClass:NSString.class] ||
            [end doubleValue] <= [start doubleValue]) {
            continue;
        }
        [segments addObject:@{@"start": start, @"end": end, @"category": category}];
    }
    return segments;
}

void YTzoomAttachSponsorSegments(NSURL *fileURL, NSString *videoID, NSString *author) {
    if (fileURL == nil || videoID.length == 0) return;
    NSURL *target = fileURL.copy;
    NSString *channel = author.copy;
    YTzoomWriteSponsorRecord(target, videoID, channel, @[]);
    if (!YTzoomSponsorBlockEnabled()) return;
    [YTzoomSponsorClient.sharedClient segmentsForVideoID:videoID
        categories:YTzoomAllSponsorCategories()
        completion:^(NSArray<NSDictionary<NSString *, id> *> *segments) {
            YTzoomWriteSponsorRecord(target, videoID, channel, segments);
        }];
}

NSString *YTzoomStoredChannelName(NSURL *fileURL) {
    if (fileURL == nil) return nil;
    id author = YTzoomReadSponsorRecord(fileURL)[@"author"];
    return [author isKindOfClass:NSString.class] && [author length] != 0 ? author : nil;
}

NSArray<NSDictionary<NSString *, id> *> *YTzoomStoredSponsorSegments(NSURL *fileURL) {
    if (fileURL == nil) return @[];
    return YTzoomValidSegments(YTzoomReadSponsorRecord(fileURL)[@"segments"]);
}

void YTzoomRefreshSponsorSegments(
    NSURL *fileURL, void (^completion)(NSArray<NSDictionary<NSString *, id> *> *segments)) {
    NSDictionary *record = fileURL == nil ? nil : YTzoomReadSponsorRecord(fileURL);
    NSString *videoID = [record[@"id"] isKindOfClass:NSString.class] ? record[@"id"] : nil;
    NSString *author = [record[@"author"] isKindOfClass:NSString.class] ? record[@"author"] : nil;
    if (videoID.length == 0 || !YTzoomSponsorBlockEnabled()) return;
    NSURL *target = fileURL.copy;
    [YTzoomSponsorClient.sharedClient segmentsForVideoID:videoID
        categories:YTzoomAllSponsorCategories()
        completion:^(NSArray<NSDictionary<NSString *, id> *> *segments) {
            if (segments.count == 0) return;
            YTzoomWriteSponsorRecord(target, videoID, author, segments);
            completion(YTzoomValidSegments(segments));
        }];
}
