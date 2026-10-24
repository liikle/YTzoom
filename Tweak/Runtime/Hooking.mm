#import "Hooking.h"

#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <string.h>
#import "../Features/Downloads/DownloadLog.h"

static NSObject *YTzoomHookLock(void) {
    static NSObject *lock;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lock = [NSObject new];
    });
    return lock;
}

static NSMutableSet<NSString *> *YTzoomHookKeys(void) {
    static NSMutableSet<NSString *> *keys;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSMutableSet set];
    });
    return keys;
}

static BOOL YTzoomInstallHook(NSString *className,
                              NSString *selectorName,
                              BOOL classMethod,
                              IMP replacement,
                              IMP *originalStorage) {
    if (className.length == 0 || selectorName.length == 0 || replacement == NULL) {
        return NO;
    }

    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return NO;
    }

    Class targetClass = classMethod ? object_getClass(cls) : cls;
    if (targetClass == Nil) {
        return NO;
    }

    SEL selector = NSSelectorFromString(selectorName);
    Method method = class_getInstanceMethod(targetClass, selector);
    if (method == NULL) {
        return NO;
    }

    NSString *key = [NSString stringWithFormat:@"%@|%@|%@",
                     className,
                     classMethod ? @"+" : @"-",
                     selectorName];

    @synchronized (YTzoomHookLock()) {
        if ([YTzoomHookKeys() containsObject:key]) {
            return YES;
        }

        IMP original = method_getImplementation(method);
        const char *types = method_getTypeEncoding(method);

        BOOL added = class_addMethod(targetClass, selector, replacement, types);
        if (!added) {
            Method directMethod = class_getInstanceMethod(targetClass, selector);
            if (directMethod == NULL) {
                return NO;
            }
            method_setImplementation(directMethod, replacement);
        }

        if (originalStorage != NULL) {
            *originalStorage = original;
        }
        [YTzoomHookKeys() addObject:key];
        return YES;
    }
}

BOOL YTzoomInstallInstanceHook(NSString *className,
                               NSString *selectorName,
                               IMP replacement,
                               IMP *originalStorage) {
    return YTzoomInstallHook(className, selectorName, NO, replacement, originalStorage);
}

BOOL YTzoomInstallClassHook(NSString *className,
                            NSString *selectorName,
                            IMP replacement,
                            IMP *originalStorage) {
    return YTzoomInstallHook(className, selectorName, YES, replacement, originalStorage);
}

BOOL YTzoomAddInstanceMethod(NSString *className,
                             NSString *selectorName,
                             IMP implementation,
                             const char *typeEncoding) {
    if (className.length == 0 || selectorName.length == 0 ||
        implementation == NULL || typeEncoding == NULL) {
        return NO;
    }

    Class cls = NSClassFromString(className);
    if (cls == Nil) {
        return NO;
    }

    NSString *key = [NSString stringWithFormat:@"%@|add|%@", className, selectorName];
    @synchronized (YTzoomHookLock()) {
        if ([YTzoomHookKeys() containsObject:key]) {
            return YES;
        }

        BOOL added = class_addMethod(cls,
                                     NSSelectorFromString(selectorName),
                                     implementation,
                                     typeEncoding);
        if (added) {
            [YTzoomHookKeys() addObject:key];
            [YTzoomHookKeys() addObject:
                [NSString stringWithFormat:@"%@|-|%@", className, selectorName]];
        }
        return added;
    }
}

NSUInteger YTzoomInstalledHookCount(void) {
    @synchronized (YTzoomHookLock()) {
        return YTzoomHookKeys().count;
    }
}

typedef struct {
    void *isa;
    void *superclass;
    void *cacheBuckets;
    void *cacheMask;
    uintptr_t bits;
} YTzoomClassLayout;

static const uintptr_t YTzoomSwiftFlags = 3;
static const uintptr_t YTzoomDataMask = 0x00007ffffffffff8UL;
static const uint32_t YTzoomRealizedFlag = 1u << 31;

static const char *YTzoomSafeClassName(Class cls) {
    if (cls == Nil) return NULL;
    const uintptr_t bits =
        ((const YTzoomClassLayout *)(__bridge const void *)cls)->bits;
    if (bits & YTzoomSwiftFlags) return NULL;
    const uintptr_t data = bits & YTzoomDataMask;
    if (data == 0) return NULL;
    if (*(const uint32_t *)data & YTzoomRealizedFlag) {
        return class_getName(cls);
    }
    return *(const char *const *)(data + 24);
}

static void YTzoomCollectSection(const struct mach_header *header,
                                 const char *segment,
                                 NSMutableArray<NSString *> *names) {
    unsigned long size = 0;
    void *section = getsectiondata(
        (const struct mach_header_64 *)header, segment, "__objc_classlist", &size);
    if (section == NULL) return;
    uintptr_t *list = (uintptr_t *)section;
    for (unsigned long index = 0; index < size / sizeof(uintptr_t); index++) {
        const char *name =
            YTzoomSafeClassName((__bridge Class)(void *)list[index]);
        if (name == NULL) continue;
        if (strncmp(name, "_Tt", 3) == 0) continue;
        if (strstr(name, "$s") != NULL) continue;
        NSString *value = [NSString stringWithUTF8String:name];
        if (value.length != 0) [names addObject:value];
    }
}

NSArray<NSString *> *YTzoomAppClassNames(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    const uint32_t imageCount = _dyld_image_count();
    for (uint32_t imageIndex = 0; imageIndex < imageCount; imageIndex++) {
        const char *path = _dyld_get_image_name(imageIndex);
        if (path == NULL) continue;
        if (strstr(path, "/System/") != NULL) continue;
        if (strstr(path, "/usr/lib/") != NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(imageIndex);
        if (header == NULL) continue;
        YTzoomCollectSection(header, "__DATA_CONST", names);
        YTzoomCollectSection(header, "__AUTH_CONST", names);
        YTzoomCollectSection(header, "__DATA", names);
    }
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        YTzoomDownloadLog(@"scan", @"%lu objc classes across %u images",
                          (unsigned long)names.count, imageCount);
    });
    return names;
}
