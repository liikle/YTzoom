#import "YTzoomBackupManager.h"
#import "DownloadLog.h"
#import "../../Runtime/Preferences.h"

#include <zlib.h>

static NSString * const YTzoomBackupErrorDomain = @"YTzoomBackup";

static NSError *YTzoomBackupError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:YTzoomBackupErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message ?: @"Backup failed"}];
}

static NSError *YTzoomBackupException(NSException *exception) {
    NSString *message = exception.reason.length != 0
        ? exception.reason : @"The backup file could not be written";
    return YTzoomBackupError(13, message);
}

static NSData *YTzoomReadData(NSFileHandle *handle,
                              NSUInteger length,
                              NSError **error) {
    @try {
        return [handle readDataOfLength:length];
    } @catch (NSException *exception) {
        if (error != NULL) *error = YTzoomBackupException(exception);
        return nil;
    }
}

static BOOL YTzoomWriteData(NSFileHandle *handle,
                            NSData *data,
                            NSError **error) {
    @try {
        [handle writeData:data];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) *error = YTzoomBackupException(exception);
        return NO;
    }
}

static void YTzoomAppend16(NSMutableData *data, uint16_t value) {
    uint8_t bytes[] = {(uint8_t)value, (uint8_t)(value >> 8)};
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void YTzoomAppend32(NSMutableData *data, uint32_t value) {
    uint8_t bytes[] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void YTzoomAppend64(NSMutableData *data, uint64_t value) {
    uint8_t bytes[] = {
        (uint8_t)value, (uint8_t)(value >> 8),
        (uint8_t)(value >> 16), (uint8_t)(value >> 24),
        (uint8_t)(value >> 32), (uint8_t)(value >> 40),
        (uint8_t)(value >> 48), (uint8_t)(value >> 56)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint16_t YTzoomRead16(const uint8_t *bytes) {
    return (uint16_t)(bytes[0] | (bytes[1] << 8));
}

static uint32_t YTzoomRead32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
        ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint64_t YTzoomRead64(const uint8_t *bytes) {
    return (uint64_t)YTzoomRead32(bytes) |
        ((uint64_t)YTzoomRead32(bytes + 4) << 32);
}

static NSString *YTzoomRelativePath(NSURL *URL, NSURL *baseURL) {
    NSString *path = URL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *base = baseURL.URLByResolvingSymlinksInPath.path.stringByStandardizingPath;
    NSString *prefix = [base stringByAppendingString:@"/"];
    if (![path hasPrefix:prefix]) return nil;
    return [path substringFromIndex:prefix.length];
}

static NSDictionary *YTzoomBackupSettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
    // dictionaryRepresentation is the reliable source: preferences are written
    // through standardUserDefaults, and persistentDomainForName: returns nil for
    // the app's own domain here, which produced an empty backup plist.
    NSMutableDictionary *domain =
        [[defaults dictionaryRepresentation] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (bundleID.length != 0) {
        NSDictionary *persistent = [defaults persistentDomainForName:bundleID];
        if ([persistent isKindOfClass:NSDictionary.class]) {
            [domain addEntriesFromDictionary:persistent];
        }
    }
    NSMutableDictionary *settings = [NSMutableDictionary dictionary];
    NSSet *named = [NSSet setWithArray:@[
        @"YTzoom.Preference.Playback.WiFiQuality", @"YTzoom.Preference.Playback.CellularQuality", @"YTzoom.Preference.SponsorBlock.Mode",
        @"YTzoom.Preference.SponsorBlock.Enabled", @"YTzoom.Preference.Downloads.ClearOnStartup",
        @"YTzoom.Preference.SponsorBlock.AudioFeedback"
    ]];
    [domain enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if (![key isKindOfClass:NSString.class]) return;
        if (![key hasPrefix:@"YTzoom.Preference."] &&
            ![named containsObject:key]) {
            return;
        }
        if (![NSPropertyListSerialization propertyList:value
                                     isValidForFormat:NSPropertyListXMLFormat_v1_0]) {
            return;
        }
        settings[key] = value;
    }];
    YTzoomDownloadLog(@"backup", @"captured %lu settings",
                      (unsigned long)settings.count);
    return settings;
}

static void YTzoomApplyBackupSettings(NSDictionary *settings) {
    if (![settings isKindOfClass:NSDictionary.class]) {
        YTzoomDownloadLog(@"backup", @"restore skipped: no settings in backup");
        return;
    }
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    __block NSUInteger applied = 0;
    [settings enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
        (void)stop;
        if ([key isKindOfClass:NSString.class] && value != nil) {
            [defaults setObject:value forKey:key];
            applied++;
        }
    }];
    [defaults synchronize];
    YTzoomDownloadLog(@"backup", @"restored %lu of %lu settings",
                      (unsigned long)applied, (unsigned long)settings.count);
}

static uint32_t YTzoomCRCAndSize(NSURL *URL, uint64_t *size, NSError **error) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (handle == nil) return 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    uint64_t total = 0;
    while (true) {
        @autoreleasepool {
            NSData *chunk = YTzoomReadData(handle, 4 * 1024 * 1024, error);
            if (chunk == nil || chunk.length == 0) break;
            crc = crc32(crc, (const Bytef *)chunk.bytes, (uInt)chunk.length);
            total += chunk.length;
        }
        if (error != NULL && *error != nil) break;
    }
    [handle closeFile];
    if (error != NULL && *error != nil) return 0;
    *size = total;
    return (uint32_t)crc;
}

static BOOL YTzoomCopyFileToHandle(NSURL *URL, NSFileHandle *output, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (input == nil) return NO;
    while (true) {
        @autoreleasepool {
            NSData *chunk = YTzoomReadData(input, 4 * 1024 * 1024, error);
            if (chunk == nil || chunk.length == 0) break;
            if (!YTzoomWriteData(output, chunk, error)) break;
        }
        if (error != NULL && *error != nil) break;
    }
    [input closeFile];
    return error == NULL || *error == nil;
}

static BOOL YTzoomWriteZip(NSURL *outputURL,
                           NSArray<NSDictionary *> *entries,
                           NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager removeItemAtURL:outputURL error:nil];
    [manager createFileAtPath:outputURL.path contents:nil attributes:nil];
    NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
    if (output == nil) return NO;
    NSMutableArray<NSDictionary *> *central = [NSMutableArray array];
    for (NSDictionary *entry in entries) {
        NSURL *URL = entry[@"url"];
        NSData *name = [entry[@"name"] dataUsingEncoding:NSUTF8StringEncoding];
        if (name.length > UINT16_MAX) {
            if (error != NULL) *error = YTzoomBackupError(3, @"A backup path is too long");
            [output closeFile];
            return NO;
        }
        uint64_t size = 0;
        uint32_t crc = YTzoomCRCAndSize(URL, &size, error);
        if (error != NULL && *error != nil) {
            [output closeFile];
            return NO;
        }
        uint64_t offset64 = output.offsetInFile;
        BOOL largeFile = size >= UINT32_MAX;
        NSMutableData *extra = [NSMutableData data];
        if (largeFile) {
            YTzoomAppend16(extra, 0x0001);
            YTzoomAppend16(extra, 16);
            YTzoomAppend64(extra, size);
            YTzoomAppend64(extra, size);
        }
        NSMutableData *header = [NSMutableData data];
        YTzoomAppend32(header, 0x04034b50);
        YTzoomAppend16(header, largeFile ? 45 : 20);
        YTzoomAppend16(header, 0x0800);
        YTzoomAppend16(header, 0);
        YTzoomAppend16(header, 0);
        YTzoomAppend16(header, 0);
        YTzoomAppend32(header, crc);
        YTzoomAppend32(header, largeFile ? UINT32_MAX : (uint32_t)size);
        YTzoomAppend32(header, largeFile ? UINT32_MAX : (uint32_t)size);
        YTzoomAppend16(header, (uint16_t)name.length);
        YTzoomAppend16(header, (uint16_t)extra.length);
        [header appendData:name];
        [header appendData:extra];
        if (!YTzoomWriteData(output, header, error)) {
            [output closeFile];
            return NO;
        }
        if (!YTzoomCopyFileToHandle(URL, output, error)) {
            [output closeFile];
            return NO;
        }
        [central addObject:@{
            @"name": name, @"crc": @(crc), @"size": @(size),
            @"offset": @(offset64)
        }];
    }
    uint64_t centralOffset = output.offsetInFile;
    BOOL needsZip64 = central.count >= UINT16_MAX || centralOffset >= UINT32_MAX;
    for (NSDictionary *entry in central) {
        NSData *name = entry[@"name"];
        uint64_t size = [entry[@"size"] unsignedLongLongValue];
        uint64_t offset = [entry[@"offset"] unsignedLongLongValue];
        BOOL largeFile = size >= UINT32_MAX;
        BOOL largeOffset = offset >= UINT32_MAX;
        BOOL largeEntry = largeFile || largeOffset;
        needsZip64 = needsZip64 || largeEntry;
        NSMutableData *extra = [NSMutableData data];
        if (largeEntry) {
            NSMutableData *values = [NSMutableData data];
            if (largeFile) {
                YTzoomAppend64(values, size);
                YTzoomAppend64(values, size);
            }
            if (largeOffset) YTzoomAppend64(values, offset);
            YTzoomAppend16(extra, 0x0001);
            YTzoomAppend16(extra, (uint16_t)values.length);
            [extra appendData:values];
        }
        NSMutableData *record = [NSMutableData data];
        YTzoomAppend32(record, 0x02014b50);
        YTzoomAppend16(record, largeEntry ? 45 : 20);
        YTzoomAppend16(record, largeEntry ? 45 : 20);
        YTzoomAppend16(record, 0x0800);
        YTzoomAppend16(record, 0);
        YTzoomAppend16(record, 0);
        YTzoomAppend16(record, 0);
        YTzoomAppend32(record, [entry[@"crc"] unsignedIntValue]);
        YTzoomAppend32(record, largeFile ? UINT32_MAX : (uint32_t)size);
        YTzoomAppend32(record, largeFile ? UINT32_MAX : (uint32_t)size);
        YTzoomAppend16(record, (uint16_t)name.length);
        YTzoomAppend16(record, (uint16_t)extra.length);
        YTzoomAppend16(record, 0);
        YTzoomAppend16(record, 0);
        YTzoomAppend16(record, 0);
        YTzoomAppend32(record, 0);
        YTzoomAppend32(record, largeOffset ? UINT32_MAX : (uint32_t)offset);
        [record appendData:name];
        [record appendData:extra];
        if (!YTzoomWriteData(output, record, error)) {
            [output closeFile];
            return NO;
        }
    }
    uint64_t centralSize = output.offsetInFile - centralOffset;
    needsZip64 = needsZip64 || centralSize >= UINT32_MAX;
    if (needsZip64) {
        uint64_t zip64Offset = output.offsetInFile;
        NSMutableData *zip64 = [NSMutableData data];
        YTzoomAppend32(zip64, 0x06064b50);
        YTzoomAppend64(zip64, 44);
        YTzoomAppend16(zip64, 45);
        YTzoomAppend16(zip64, 45);
        YTzoomAppend32(zip64, 0);
        YTzoomAppend32(zip64, 0);
        YTzoomAppend64(zip64, central.count);
        YTzoomAppend64(zip64, central.count);
        YTzoomAppend64(zip64, centralSize);
        YTzoomAppend64(zip64, centralOffset);
        if (!YTzoomWriteData(output, zip64, error)) {
            [output closeFile];
            return NO;
        }
        NSMutableData *locator = [NSMutableData data];
        YTzoomAppend32(locator, 0x07064b50);
        YTzoomAppend32(locator, 0);
        YTzoomAppend64(locator, zip64Offset);
        YTzoomAppend32(locator, 1);
        if (!YTzoomWriteData(output, locator, error)) {
            [output closeFile];
            return NO;
        }
    }
    NSMutableData *end = [NSMutableData data];
    YTzoomAppend32(end, 0x06054b50);
    YTzoomAppend16(end, 0);
    YTzoomAppend16(end, 0);
    YTzoomAppend16(end, needsZip64 ? UINT16_MAX : (uint16_t)central.count);
    YTzoomAppend16(end, needsZip64 ? UINT16_MAX : (uint16_t)central.count);
    YTzoomAppend32(end, needsZip64 ? UINT32_MAX : (uint32_t)centralSize);
    YTzoomAppend32(end, needsZip64 ? UINT32_MAX : (uint32_t)centralOffset);
    YTzoomAppend16(end, 0);
    if (!YTzoomWriteData(output, end, error)) {
        [output closeFile];
        return NO;
    }
    [output closeFile];
    return YES;
}

static uint64_t YTzoomBackupSize(NSArray<NSDictionary *> *entries) {
    uint64_t total = 0;
    for (NSDictionary *entry in entries) {
        @autoreleasepool {
            NSNumber *size = nil;
            [entry[@"url"] getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            uint64_t value = size.unsignedLongLongValue;
            if (UINT64_MAX - total < value) return UINT64_MAX;
            total += value;
        }
    }
    return total;
}

static BOOL YTzoomHasBackupSpace(NSURL *URL,
                                 uint64_t required,
                                 NSError **error) {
    NSNumber *available = nil;
    [URL getResourceValue:&available
                   forKey:NSURLVolumeAvailableCapacityForImportantUsageKey
                    error:nil];
    if (available == nil) return YES;
    uint64_t reserve = 128ULL * 1024ULL * 1024ULL;
    if (required <= UINT64_MAX - reserve &&
        available.unsignedLongLongValue >= required + reserve) return YES;
    if (error != NULL) {
        *error = YTzoomBackupError(14, @"Not enough free space to create the backup");
    }
    return NO;
}

static NSArray<NSDictionary *> *YTzoomBackupEntries(NSError **error) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *root = YTzoomApplicationSupportDirectory();
    NSURL *settingsURL = [root URLByAppendingPathComponent:@"SettingsBackup.plist"];
    if (![YTzoomBackupSettings() writeToURL:settingsURL atomically:YES]) {
        if (error != NULL) *error = YTzoomBackupError(6, @"Settings could not be saved");
        return nil;
    }
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray arrayWithObject:@{
        @"url": settingsURL, @"name": @"SettingsBackup.plist"
    }];
    NSURL *downloads = [root URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    NSDirectoryEnumerator<NSURL *> *items = [manager enumeratorAtURL:downloads
        includingPropertiesForKeys:@[NSURLIsRegularFileKey]
                           options:NSDirectoryEnumerationSkipsHiddenFiles
                      errorHandler:nil];
    for (NSURL *URL in items) {
        NSNumber *regular = nil;
        [URL getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
        if (!regular.boolValue) continue;
        NSString *relative = YTzoomRelativePath(URL, downloads);
        if (relative.length == 0) continue;
        [entries addObject:@{
            @"url": URL,
            @"name": [@"Downloads" stringByAppendingPathComponent:relative]
        }];
    }
    return entries;
}

static BOOL YTzoomExtractStoredZip(NSURL *URL, NSURL *destination, NSError **error) {
    NSFileHandle *input = [NSFileHandle fileHandleForReadingFromURL:URL error:error];
    if (input == nil) return NO;
    NSFileManager *manager = NSFileManager.defaultManager;
    while (true) {
        NSData *fixed = [input readDataOfLength:30];
        if (fixed.length == 0) break;
        if (fixed.length < 4) {
            if (error != NULL) *error = YTzoomBackupError(7, @"The backup is incomplete");
            [input closeFile];
            return NO;
        }
        const uint8_t *bytes = (const uint8_t *)fixed.bytes;
        uint32_t signature = YTzoomRead32(bytes);
        if (signature == 0x02014b50 || signature == 0x06054b50) break;
        if (signature != 0x04034b50 || fixed.length != 30) {
            if (error != NULL) *error = YTzoomBackupError(8, @"This is not a YTzoom backup");
            [input closeFile];
            return NO;
        }
        uint16_t flags = YTzoomRead16(bytes + 6);
        uint16_t method = YTzoomRead16(bytes + 8);
        uint32_t expectedCRC = YTzoomRead32(bytes + 14);
        uint32_t compressedSize32 = YTzoomRead32(bytes + 18);
        uint32_t size32 = YTzoomRead32(bytes + 22);
        uint16_t nameLength = YTzoomRead16(bytes + 26);
        uint16_t extraLength = YTzoomRead16(bytes + 28);
        if ((flags & 0x0008) != 0 || method != 0) {
            if (error != NULL) *error = YTzoomBackupError(9, @"Unsupported ZIP compression");
            [input closeFile];
            return NO;
        }
        NSData *nameData = YTzoomReadData(input, nameLength, error);
        if (nameData == nil || nameData.length != nameLength) {
            if (error != NULL && *error == nil) {
                *error = YTzoomBackupError(11, @"The backup is incomplete");
            }
            [input closeFile];
            return NO;
        }
        NSString *name = [[NSString alloc] initWithData:nameData encoding:NSUTF8StringEncoding];
        NSData *extra = extraLength == 0 ? NSData.data :
            YTzoomReadData(input, extraLength, error);
        if (extra == nil || extra.length != extraLength) {
            if (error != NULL && *error == nil) {
                *error = YTzoomBackupError(11, @"The backup is incomplete");
            }
            [input closeFile];
            return NO;
        }
        uint64_t compressedSize = compressedSize32;
        uint64_t size = size32;
        if (compressedSize32 == UINT32_MAX || size32 == UINT32_MAX) {
            const uint8_t *extraBytes = (const uint8_t *)extra.bytes;
            NSUInteger cursor = 0;
            BOOL parsedSize = size32 != UINT32_MAX;
            BOOL parsedCompressedSize = compressedSize32 != UINT32_MAX;
            while (cursor + 4 <= extra.length) {
                uint16_t identifier = YTzoomRead16(extraBytes + cursor);
                uint16_t length = YTzoomRead16(extraBytes + cursor + 2);
                cursor += 4;
                if (cursor + length > extra.length) break;
                if (identifier == 0x0001) {
                    NSUInteger valueCursor = cursor;
                    if (size32 == UINT32_MAX && valueCursor + 8 <= cursor + length) {
                        size = YTzoomRead64(extraBytes + valueCursor);
                        valueCursor += 8;
                        parsedSize = YES;
                    }
                    if (compressedSize32 == UINT32_MAX &&
                        valueCursor + 8 <= cursor + length) {
                        compressedSize = YTzoomRead64(extraBytes + valueCursor);
                        valueCursor += 8;
                        parsedCompressedSize = YES;
                    }
                    break;
                }
                cursor += length;
            }
            if (!parsedSize || !parsedCompressedSize) {
                if (error != NULL) *error = YTzoomBackupError(9, @"Invalid ZIP64 backup");
                [input closeFile];
                return NO;
            }
        }
        if (compressedSize != size) {
            if (error != NULL) *error = YTzoomBackupError(9, @"Unsupported ZIP compression");
            [input closeFile];
            return NO;
        }
        NSString *clean = name.stringByStandardizingPath;
        BOOL allowed = [clean isEqualToString:@"SettingsBackup.plist"] ||
            [clean hasPrefix:@"Downloads/"];
        if (!allowed || [clean isEqualToString:@".."] ||
            [clean hasPrefix:@"/"] || [clean containsString:@"../"]) {
            if (error != NULL) *error = YTzoomBackupError(10, @"The backup contains an unsafe path");
            [input closeFile];
            return NO;
        }
        NSURL *outputURL = [destination URLByAppendingPathComponent:clean];
        [manager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        [manager createFileAtPath:outputURL.path contents:nil attributes:nil];
        NSFileHandle *output = [NSFileHandle fileHandleForWritingToURL:outputURL error:error];
        if (output == nil) {
            [input closeFile];
            return NO;
        }
        uint64_t remaining = size;
        uLong crc = crc32(0L, Z_NULL, 0);
        while (remaining != 0) {
            @autoreleasepool {
                NSUInteger amount = (NSUInteger)MIN((uint64_t)(1024 * 1024), remaining);
                NSData *chunk = YTzoomReadData(input, amount, error);
                if (chunk.length != amount) {
                    [output closeFile];
                    [input closeFile];
                    if (error != NULL && *error == nil) {
                        *error = YTzoomBackupError(11, @"The backup is incomplete");
                    }
                    return NO;
                }
                if (!YTzoomWriteData(output, chunk, error)) {
                    [output closeFile];
                    [input closeFile];
                    return NO;
                }
                crc = crc32(crc, (const Bytef *)chunk.bytes, (uInt)chunk.length);
                remaining -= chunk.length;
            }
        }
        [output closeFile];
        if ((uint32_t)crc != expectedCRC) {
            [input closeFile];
            if (error != NULL) *error = YTzoomBackupError(12, @"A backup file is damaged");
            return NO;
        }
    }
    [input closeFile];
    return YES;
}

static void YTzoomRestoreDownloads(NSURL *source, NSURL *destination) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSDirectoryEnumerator<NSURL *> *items = [manager enumeratorAtURL:source
        includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                           options:0 errorHandler:nil];
    for (NSURL *URL in items) {
        NSNumber *directory = nil;
        [URL getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
        if (directory.boolValue) continue;
        NSString *relative = YTzoomRelativePath(URL, source);
        NSArray<NSString *> *components = relative.pathComponents;
        NSUInteger categoryIndex = NSNotFound;
        NSString *category = nil;
        for (NSUInteger index = 0; index < components.count; index++) {
            for (NSString *candidate in @[@"Video", @"Audio", @"Shorts"]) {
                if ([components[index] caseInsensitiveCompare:candidate] == NSOrderedSame) {
                    categoryIndex = index;
                    category = candidate;
                    break;
                }
            }
            if (categoryIndex != NSNotFound) break;
        }
        if (categoryIndex == NSNotFound || categoryIndex + 1 >= components.count) continue;
        NSURL *target = [destination URLByAppendingPathComponent:category isDirectory:YES];
        for (NSUInteger index = categoryIndex + 1; index < components.count; index++) {
            target = [target URLByAppendingPathComponent:components[index]];
        }
        [manager createDirectoryAtURL:target.URLByDeletingLastPathComponent
          withIntermediateDirectories:YES attributes:nil error:nil];
        [manager removeItemAtURL:target error:nil];
        [manager copyItemAtURL:URL toURL:target error:nil];
    }
}

@implementation YTzoomBackupManager

+ (void)createBackupWithCompletion:(YTzoomBackupCreationCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSFileManager *manager = NSFileManager.defaultManager;
            NSURL *URL = nil;
            @try {
                NSURL *backups = [[NSURL fileURLWithPath:NSTemporaryDirectory()
                                              isDirectory:YES]
                    URLByAppendingPathComponent:@"YTzoomBackups" isDirectory:YES];
                [manager removeItemAtURL:backups error:nil];
                [manager createDirectoryAtURL:backups
                  withIntermediateDirectories:YES attributes:nil error:&error];
                NSDateFormatter *formatter = [NSDateFormatter new];
                formatter.dateFormat = @"yyyyMMdd-HHmmss";
                NSString *name = [NSString stringWithFormat:@"YTzoom-Backup-%@.zip",
                    [formatter stringFromDate:NSDate.date]];
                URL = error == nil ? [backups URLByAppendingPathComponent:name] : nil;
                NSArray *entries = error == nil ? YTzoomBackupEntries(&error) : nil;
                uint64_t size = entries == nil ? 0 : YTzoomBackupSize(entries);
                if (entries != nil && !YTzoomHasBackupSpace(backups, size, &error)) {
                    entries = nil;
                }
                if (entries != nil && !YTzoomWriteZip(URL, entries, &error)) {
                    [manager removeItemAtURL:URL error:nil];
                    URL = nil;
                }
            } @catch (NSException *exception) {
                error = YTzoomBackupException(exception);
                if (URL != nil) [manager removeItemAtURL:URL error:nil];
                URL = nil;
            }
            if (error != nil) URL = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ completion(URL, error); });
        }
    });
}

+ (void)restoreBackupFromURL:(NSURL *)URL
                  completion:(YTzoomBackupRestoreCompletion)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *manager = NSFileManager.defaultManager;
        NSError *error = nil;
        NSURL *temporary = [YTzoomApplicationSupportDirectory()
            URLByAppendingPathComponent:[@"Restore-" stringByAppendingString:NSUUID.UUID.UUIDString]
                             isDirectory:YES];
        [manager createDirectoryAtURL:temporary withIntermediateDirectories:YES
                           attributes:nil error:nil];
        if (YTzoomExtractStoredZip(URL, temporary, &error)) {
            NSURL *restoredDownloads = [temporary URLByAppendingPathComponent:@"Downloads"
                                                                   isDirectory:YES];
            NSURL *downloads = [YTzoomApplicationSupportDirectory()
                URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
            if ([manager fileExistsAtPath:restoredDownloads.path]) {
                [manager createDirectoryAtURL:downloads withIntermediateDirectories:YES
                                   attributes:nil error:nil];
                YTzoomRestoreDownloads(restoredDownloads, downloads);
            }
            NSDictionary *settings = [NSDictionary dictionaryWithContentsOfURL:
                [temporary URLByAppendingPathComponent:@"SettingsBackup.plist"]];
            YTzoomApplyBackupSettings(settings);
        }
        [manager removeItemAtURL:temporary error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error == nil) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"YTzoomDownloadLibraryChanged" object:nil];
            }
            completion(error);
        });
    });
}

@end
