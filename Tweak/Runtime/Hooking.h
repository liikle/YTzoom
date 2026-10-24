#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL YTzoomInstallInstanceHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTzoomInstallClassHook(
    NSString *className,
    NSString *selectorName,
    IMP replacement,
    IMP _Nullable * _Nullable originalStorage
);

FOUNDATION_EXPORT BOOL YTzoomAddInstanceMethod(
    NSString *className,
    NSString *selectorName,
    IMP implementation,
    const char *typeEncoding
);

FOUNDATION_EXPORT NSUInteger YTzoomInstalledHookCount(void);

FOUNDATION_EXPORT NSArray<NSString *> *YTzoomAppClassNames(void);

NS_ASSUME_NONNULL_END
