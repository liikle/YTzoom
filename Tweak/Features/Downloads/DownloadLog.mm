#import "DownloadLog.h"



static const NSUInteger YTzoomDownloadLogLimit = 512 * 1024;

static NSURL *YTzoomDownloadLogURL(void) {
    static NSURL *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSNumber *> *candidates = @[@(NSDocumentDirectory),
                                            @(NSApplicationSupportDirectory),
                                            @(NSCachesDirectory)];
        for (NSNumber *candidate in candidates) {
            NSURL *base = [NSFileManager.defaultManager
                URLsForDirectory:(NSSearchPathDirectory)candidate.unsignedIntegerValue
                       inDomains:NSUserDomainMask].firstObject;
            if (base == nil) continue;
            NSURL *directory = [[base URLByAppendingPathComponent:@"YTzoom" isDirectory:YES]
                URLByAppendingPathComponent:@"Logs" isDirectory:YES];
            NSError *error = nil;
            if (![NSFileManager.defaultManager createDirectoryAtURL:directory
                                       withIntermediateDirectories:YES
                                                        attributes:nil
                                                             error:&error]) {
                continue;
            }
            NSURL *probe = [directory URLByAppendingPathComponent:@"downloads.log"];
            if (![NSFileManager.defaultManager fileExistsAtPath:probe.path] &&
                ![[NSData data] writeToURL:probe atomically:YES]) {
                continue;
            }
            cached = probe;
            break;
        }
        if (cached == nil) {
            cached = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:@"ytzoom-downloads.log"]];
        }
        [NSUserDefaults.standardUserDefaults setObject:cached.path
                                                forKey:@"YTzoomLogPath"];
    });
    return cached;
}

static dispatch_queue_t YTzoomDownloadLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.ytzoom.download-log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void YTzoomDownloadLog(NSString *identifier, NSString *format, ...) {
    if (format.length == 0) return;
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    if (message.length > 4096) message = [message substringToIndex:4096];
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
        NSDate.date, identifier.length == 0 ? @"download" : identifier, message];
    dispatch_async(YTzoomDownloadLogQueue(), ^{
        NSURL *URL = YTzoomDownloadLogURL();
        NSData *existing = [NSData dataWithContentsOfURL:URL] ?: NSData.data;
        NSMutableData *data = [existing mutableCopy];
        [data appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        if (data.length > YTzoomDownloadLogLimit) {
            NSUInteger keep = YTzoomDownloadLogLimit * 3 / 4;
            NSData *tail = [data subdataWithRange:NSMakeRange(data.length - keep, keep)];
            data = [tail mutableCopy];
        }
        [data writeToURL:URL atomically:YES];
    });
}

NSString *YTzoomDownloadLogContents(void) {
    __block NSString *contents = @"No download activity yet.";
    dispatch_sync(YTzoomDownloadLogQueue(), ^{
        NSString *value = [NSString stringWithContentsOfURL:YTzoomDownloadLogURL()
            encoding:NSUTF8StringEncoding error:nil];
        if (value.length != 0) contents = value;
    });
    return contents;
}

void YTzoomClearDownloadLog(void) {
    dispatch_sync(YTzoomDownloadLogQueue(), ^{
        [NSFileManager.defaultManager removeItemAtURL:YTzoomDownloadLogURL() error:nil];
    });
}
