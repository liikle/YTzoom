#import "GeminiClient.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"

#import <UIKit/UIKit.h>

// Kept outside the YTzoom.Preference prefix so backups never include it.
NSString * const YTzoomGeminiAPIKeyKey = @"YTzoom.Secret.GeminiAPIKey";
NSString * const YTzoomGeminiModelKey = @"YTzoom.Preference.AITitles.Model";
NSString * const YTzoomGeminiDefaultModel = @"gemini-flash-latest";

static const NSUInteger YTzoomTitleMaxLength = 100;

static NSString *YTzoomGeminiString(NSString *key) {
    id value = YTzoomPreferenceObject(key);
    if (![value isKindOfClass:NSString.class]) return @"";
    return [(NSString *)value stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

BOOL YTzoomGeminiHasAPIKey(void) {
    return YTzoomGeminiString(YTzoomGeminiAPIKeyKey).length != 0;
}

static NSString *YTzoomGeminiLanguageName(void) {
    NSString *code = NSLocale.preferredLanguages.firstObject ?: @"en";
    NSString *name = [[NSLocale localeWithLocaleIdentifier:@"en_US"]
        localizedStringForLocaleIdentifier:code];
    return name.length != 0 ? name : code;
}

static NSString *YTzoomGeminiPrompt(NSUInteger imageCount,
                                    BOOL screenshot,
                                    NSArray<NSString *> *texts,
                                    NSString *currentTitle,
                                    NSUInteger count,
                                    BOOL hashtags) {
    NSMutableString *prompt = [NSMutableString string];
    [prompt appendFormat:@"You write titles for YouTube Shorts. Suggest %lu different titles "
                          "for the Short described below.\n\n", (unsigned long)count];
    if (imageCount != 0 && screenshot) {
        [prompt appendString:@"The attached image is a screenshot of the upload screen. "
                              "Use the video thumbnail in it and ignore the app's buttons and labels.\n"];
    } else if (imageCount != 0) {
        [prompt appendFormat:@"The %lu attached images are frames from the video, in order.\n",
                             (unsigned long)imageCount];
    }
    if (texts.count != 0) {
        [prompt appendString:@"Text the creator added in the Shorts editor:\n"];
        for (NSString *text in texts) [prompt appendFormat:@"- %@\n", text];
    } else {
        [prompt appendString:@"The creator added no text in the editor.\n"];
    }
    if (currentTitle.length != 0) {
        [prompt appendFormat:@"The creator's current draft title is: %@\n", currentTitle];
    }
    [prompt appendFormat:
        @"\nRules:\n"
         "- Describe what actually happens in the video. Don't invent details.\n"
         "- Keep each title under 70 characters.\n"
         "- Write in the same language as the creator's text. If there is none, write in %@.\n"
         "- No quotation marks around titles. At most one emoji per title.\n"
         "- %@\n"
         "\nReturn JSON with a \"titles\" array of strings.",
        YTzoomGeminiLanguageName(),
        hashtags ? @"End each title with one or two relevant hashtags."
                 : @"Don't use hashtags."];
    return prompt;
}

static NSString *YTzoomGeminiJPEGBase64(UIImage *image) {
    CGFloat longest = MAX(image.size.width, image.size.height);
    if (longest <= 0.0) return nil;
    CGFloat scale = MIN(1.0, 768.0 / longest);
    CGSize size = CGSizeMake(round(image.size.width * scale), round(image.size.height * scale));
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIImage *resized = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(__unused UIGraphicsImageRendererContext *context) {
            [image drawInRect:CGRectMake(0.0, 0.0, size.width, size.height)];
        }];
    return [UIImageJPEGRepresentation(resized, 0.7) base64EncodedStringWithOptions:0];
}

static NSString *YTzoomGeminiCleanTitle(NSString *raw) {
    NSString *title = [[raw componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]
        componentsJoinedByString:@" "];
    title = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSCharacterSet *quotes = [NSCharacterSet characterSetWithCharactersInString:@"\"'“”‘’"];
    title = [title stringByTrimmingCharactersInSet:quotes];
    if (title.length > YTzoomTitleMaxLength) {
        NSRange range = [title rangeOfComposedCharacterSequencesForRange:
            NSMakeRange(0, YTzoomTitleMaxLength)];
        if (NSMaxRange(range) > YTzoomTitleMaxLength) {
            range = [title rangeOfComposedCharacterSequenceAtIndex:YTzoomTitleMaxLength - 1];
            range = NSMakeRange(0, range.location);
        }
        title = [[title substringWithRange:range]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    }
    return title;
}

static NSArray<NSString *> *YTzoomGeminiParseTitles(NSString *text) {
    NSArray *raw = nil;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([json isKindOfClass:NSDictionary.class]) raw = json[@"titles"];
    else if ([json isKindOfClass:NSArray.class]) raw = json;
    if (![raw isKindOfClass:NSArray.class]) {
        raw = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    }
    NSMutableOrderedSet<NSString *> *titles = [NSMutableOrderedSet orderedSet];
    for (id entry in raw) {
        if (![entry isKindOfClass:NSString.class]) continue;
        NSString *title = YTzoomGeminiCleanTitle(entry);
        if (title.length != 0) [titles addObject:title];
    }
    return titles.array;
}

static NSString *YTzoomGeminiErrorMessage(NSDictionary *json, NSInteger status, NSError *error) {
    NSDictionary *apiError = [json isKindOfClass:NSDictionary.class] ? json[@"error"] : nil;
    NSString *message = [apiError isKindOfClass:NSDictionary.class] ? apiError[@"message"] : nil;
    if ([message isKindOfClass:NSString.class] && message.length != 0) {
        return [NSString stringWithFormat:@"Gemini: %@", message];
    }
    if (error != nil) return error.localizedDescription;
    return [NSString stringWithFormat:YTzoomLocalized(@"Gemini returned HTTP %ld."), (long)status];
}

void YTzoomGeminiGenerateTitles(NSArray<UIImage *> *images,
                                BOOL imagesAreScreenshot,
                                NSArray<NSString *> *editorTexts,
                                NSString *currentTitle,
                                NSUInteger count,
                                BOOL hashtags,
                                YTzoomGeminiTitlesCompletion completion) {
    void (^finish)(NSArray *, NSString *) = ^(NSArray *titles, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(titles, message); });
    };
    NSString *key = YTzoomGeminiString(YTzoomGeminiAPIKeyKey);
    if (key.length == 0) {
        finish(nil, YTzoomLocalized(@"Add your Gemini API key in YTzoom settings under AI & Region."));
        return;
    }
    NSString *model = YTzoomGeminiString(YTzoomGeminiModelKey);
    if ([model hasPrefix:@"models/"]) model = [model substringFromIndex:7];
    if (model.length == 0) model = YTzoomGeminiDefaultModel;
    NSString *path = [model stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:
        @"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", path]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *parts = [NSMutableArray array];
        for (UIImage *image in images) {
            NSString *encoded = YTzoomGeminiJPEGBase64(image);
            if (encoded.length == 0) continue;
            [parts addObject:@{@"inline_data": @{@"mime_type": @"image/jpeg", @"data": encoded}}];
        }
        [parts insertObject:@{@"text": YTzoomGeminiPrompt(parts.count, imagesAreScreenshot,
                                                          editorTexts, currentTitle, count, hashtags)}
                    atIndex:0];
        NSDictionary *body = @{
            @"contents": @[@{@"role": @"user", @"parts": parts}],
            @"generationConfig": @{
                @"temperature": @1.0,
                @"responseMimeType": @"application/json",
                @"responseSchema": @{
                    @"type": @"OBJECT",
                    @"properties": @{
                        @"titles": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}}
                    },
                    @"required": @[@"titles"]
                }
            }
        };
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
        request.HTTPMethod = @"POST";
        request.timeoutInterval = 45.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

        [[NSURLSession.sharedSession dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class]
                ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id json = data != nil ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if (error != nil || status != 200 || ![json isKindOfClass:NSDictionary.class]) {
                finish(nil, YTzoomGeminiErrorMessage(json, status, error));
                return;
            }
            NSArray *candidates = json[@"candidates"];
            NSDictionary *first = [candidates isKindOfClass:NSArray.class] ? candidates.firstObject : nil;
            NSDictionary *content = [first isKindOfClass:NSDictionary.class] ? first[@"content"] : nil;
            NSArray *contentParts = [content isKindOfClass:NSDictionary.class] ? content[@"parts"] : nil;
            NSMutableString *text = [NSMutableString string];
            if ([contentParts isKindOfClass:NSArray.class]) {
                for (NSDictionary *part in contentParts) {
                    if (![part isKindOfClass:NSDictionary.class]) continue;
                    if ([part[@"thought"] boolValue]) continue;
                    if ([part[@"text"] isKindOfClass:NSString.class]) [text appendString:part[@"text"]];
                }
            }
            NSArray *titles = YTzoomGeminiParseTitles(text);
            if (titles.count == 0) {
                NSDictionary *feedback = json[@"promptFeedback"];
                NSString *blocked = [feedback isKindOfClass:NSDictionary.class]
                    ? feedback[@"blockReason"] : nil;
                finish(nil, [blocked isKindOfClass:NSString.class]
                    ? [NSString stringWithFormat:YTzoomLocalized(@"Gemini blocked this request (%@)."), blocked]
                    : YTzoomLocalized(@"Gemini didn't return any titles. Try again."));
                return;
            }
            finish(titles, nil);
        }] resume];
    });
}
