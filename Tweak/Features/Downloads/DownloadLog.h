#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void YTzoomDownloadLog(NSString *identifier,
                                         NSString *format, ...)
    NS_FORMAT_FUNCTION(2, 3);
FOUNDATION_EXPORT NSString *YTzoomDownloadLogContents(void);
FOUNDATION_EXPORT void YTzoomClearDownloadLog(void);

NS_ASSUME_NONNULL_END
