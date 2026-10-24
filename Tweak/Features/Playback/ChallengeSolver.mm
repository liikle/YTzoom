#import "../../YTzoom.h"
#import "../../UI/Assets.h"
#import "../Downloads/DownloadLog.h"

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

static NSString *YTzoomChallengeScript(NSString *name) {
    NSString *path = [YTzoomAssetsBundle() pathForResource:name ofType:@"js" inDirectory:@"ejs"];
    return path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] : nil;
}

static NSURL *YTzoomChallengeCacheURL(NSString *playerID) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory
                                                         inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:
        [NSString stringWithFormat:@"YTzoom-player-%@.js", playerID]];
}

NSDictionary<NSString *, NSString *> *YTzoomSolveChallenges(NSString *playerID, NSString *playerJS,
                                                            NSString *type, NSArray<NSString *> *challenges) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("ytzoom.challenge", DISPATCH_QUEUE_SERIAL); });
    __block NSDictionary *result = nil;
    dispatch_sync(queue, ^{ @autoreleasepool {
        static JSContext *context;
        static NSString *failure;
        static NSString *preparedID;
        static NSString *preparedPlayer;
        if (challenges.count == 0) return;
        if (context == nil) {
            NSString *library = YTzoomChallengeScript(@"yt.solver.lib.min");
            NSString *core = YTzoomChallengeScript(@"yt.solver.core.min");
            if (library.length == 0 || core.length == 0) {
                YTzoomDownloadLog(@"nsolver", @"missing solver files lib=%lu core=%lu",
                                  (unsigned long)library.length, (unsigned long)core.length);
                return;
            }
            context = [JSContext new];
            context.exceptionHandler = ^(__unused JSContext *ctx, JSValue *exception) {
                failure = exception.toString;
            };
            [context evaluateScript:library];
            [context evaluateScript:@"var meriyah = lib.meriyah, astring = lib.astring;"];
            [context evaluateScript:core];
        }
        failure = nil;
        NSURL *cacheURL = playerID.length ? YTzoomChallengeCacheURL(playerID) : nil;
        NSString *prepared = nil;
        if (playerID.length != 0 && [preparedID isEqualToString:playerID]) {
            prepared = preparedPlayer;
        } else if (cacheURL != nil) {
            prepared = [NSString stringWithContentsOfURL:cacheURL encoding:NSUTF8StringEncoding error:nil];
            if (prepared.length != 0) {
                preparedID = playerID;
                preparedPlayer = prepared;
            }
        }
        if (prepared.length == 0 && playerJS.length == 0) return;
        NSDictionary *input = prepared.length
            ? @{@"type": @"preprocessed", @"preprocessed_player": prepared,
                @"requests": @[@{@"type": type, @"challenges": challenges}]}
            : @{@"type": @"player", @"player": playerJS, @"output_preprocessed": @YES,
                @"requests": @[@{@"type": type, @"challenges": challenges}]};
        const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
        JSValue *output = [context[@"jsc"] callWithArguments:@[input]];
        NSDictionary *value = output.toDictionary;
        NSString *preprocessed = value[@"preprocessed_player"];
        if (preprocessed.length != 0 && cacheURL != nil) {
            [preprocessed writeToURL:cacheURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
            preparedID = playerID;
            preparedPlayer = preprocessed;
        }
        NSDictionary *response = [value[@"responses"] firstObject];
        if ([response[@"type"] isEqual:@"result"]) result = response[@"data"];
        YTzoomDownloadLog(@"nsolver", @"%@ solved=%lu/%lu cached=%d ms=%.0f error=%@", type,
                          (unsigned long)result.count, (unsigned long)challenges.count, prepared.length != 0,
                          (CFAbsoluteTimeGetCurrent() - start) * 1000.0,
                          failure ?: response[@"error"] ?: @"none");
    }});
    return result;
}

NSString *YTzoomSolveURLParameterN(NSString *playerID, NSString *playerJS, NSString *URLString) {
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"([?&])n=([^&]+)"
                                                                             options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:URLString options:0
                                                        range:NSMakeRange(0, URLString.length)];
    if (match == nil) return URLString;
    NSString *challenge = [URLString substringWithRange:[match rangeAtIndex:2]].stringByRemovingPercentEncoding;
    NSString *solved = YTzoomSolveChallenges(playerID, playerJS, @"n", @[challenge ?: @""])[challenge];
    if (solved.length == 0) return URLString;
    NSString *encoded = [solved stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet];
    return [URLString stringByReplacingCharactersInRange:[match rangeAtIndex:2] withString:encoded];
}
