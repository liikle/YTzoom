#import "SponsorClient.h"
#import "SponsorPreferences.h"
#import <math.h>

@interface YTzoomSponsorClient ()
@property(nonatomic, strong) NSCache<NSString *, NSArray *> *cache;
@property(nonatomic, strong) NSURLSession *session;
@end

@implementation YTzoomSponsorClient

+ (instancetype)sharedClient {
    static YTzoomSponsorClient *client;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [YTzoomSponsorClient new];
    });
    return client;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cache = [NSCache new];
        _cache.countLimit = 128;

        NSURLSessionConfiguration *configuration =
            NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 10.0;
        configuration.timeoutIntervalForResource = 15.0;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}

- (void)segmentsForVideoID:(NSString *)videoID
                completion:(YTzoomSponsorCompletion)completion {
    if (videoID.length == 0) {
        completion(@[]);
        return;
    }

    [self segmentsForVideoID:videoID categories:YTzoomSponsorEnabledCategories()
                  completion:completion];
}

- (void)segmentsForVideoID:(NSString *)videoID
                categories:(NSArray<NSString *> *)categories
                completion:(YTzoomSponsorCompletion)completion {
    if (videoID.length == 0 || categories.count == 0) {
        completion(@[]);
        return;
    }
    NSString *cacheKey = [NSString stringWithFormat:@"%@|%@", videoID,
                          [categories componentsJoinedByString:@","]];

    NSArray *cached = [self.cache objectForKey:cacheKey];
    if (cached != nil) {
        completion(cached);
        return;
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithString:@"https://sponsor.ajay.app/api/skipSegments"];
    NSData *categoryData = [NSJSONSerialization dataWithJSONObject:categories
                                                            options:0 error:nil];
    NSString *categoryJSON = categoryData == nil ? @"[]" :
        [[NSString alloc] initWithData:categoryData encoding:NSUTF8StringEncoding];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"videoID" value:videoID],
        [NSURLQueryItem queryItemWithName:@"categories" value:categoryJSON]
    ];
    NSURL *url = components.URL;
    if (url == nil) {
        completion(@[]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

    __weak YTzoomSponsorClient *weakSelf = self;
    NSURLSessionDataTask *task =
        [self.session dataTaskWithRequest:request
                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray<NSDictionary<NSString *, id> *> *segments =
            [NSMutableArray array];
        NSHTTPURLResponse *http =
            [response isKindOfClass:NSHTTPURLResponse.class]
                ? (NSHTTPURLResponse *)response
                : nil;

        if (error == nil && http.statusCode == 200 && data.length <= 1024 * 1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSArray.class]) {
                for (id item in (NSArray *)json) {
                    if (![item isKindOfClass:NSDictionary.class]) {
                        continue;
                    }
                    id category = item[@"category"];
                    id values = item[@"segment"];
                    id actionType = item[@"actionType"];
                    if (![category isKindOfClass:NSString.class] ||
                        ![categories containsObject:category] ||
                        ([actionType isKindOfClass:NSString.class] &&
                         ![actionType isEqualToString:@"skip"]) ||
                        ![values isKindOfClass:NSArray.class] ||
                        [values count] != 2) {
                        continue;
                    }
                    id startValue = values[0];
                    id endValue = values[1];
                    if (![startValue isKindOfClass:NSNumber.class] ||
                        ![endValue isKindOfClass:NSNumber.class]) {
                        continue;
                    }
                    double start = [startValue doubleValue];
                    double end = [endValue doubleValue];
                    if (!isfinite(start) || !isfinite(end) || start < 0.0 || end <= start) {
                        continue;
                    }
                    [segments addObject:@{@"start": @(start), @"end": @(end),
                                          @"category": category}];
                }
            }
        }

        NSArray *result = [segments sortedArrayUsingComparator:
            ^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
                return [left[@"start"] compare:right[@"start"]];
            }];
        if (result.count != 0) {
            [weakSelf.cache setObject:result forKey:cacheKey];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    }];
    [task resume];
}

@end
