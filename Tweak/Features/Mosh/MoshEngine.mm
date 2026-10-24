//
//  MoshEngine.mm
//  Objective-C++ wrapper around the portable datamosh core (from Moshly).
//

#import "MoshEngine.h"
#include "datamosh.h"

#include <cstring>
#include <vector>

static BOOL YTzoomMoshIsBiPlanar(OSType format) {
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

@implementation MoshEngine {
    dm_context *_ctx;
    int _w, _h;
    OSType _format;
    std::vector<uint8_t> _packed;
}

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat {
    return pixelFormat == kCVPixelFormatType_32BGRA || YTzoomMoshIsBiPlanar(pixelFormat);
}

- (nullable instancetype)initWithWidth:(int)width height:(int)height pixelFormat:(OSType)pixelFormat {
    self = [super init];
    if (self == nil || width <= 0 || height <= 0 || ![MoshEngine supportsPixelFormat:pixelFormat]) {
        return nil;
    }
    _w = width;
    _h = height;
    _format = pixelFormat;
    dm_config cfg = dm_default_config();
    cfg.pixel_order = pixelFormat == kCVPixelFormatType_32BGRA ? DM_PIXEL_BGRA : DM_PIXEL_YCBCR;
    _ctx = dm_create(width, height, &cfg);
    if (_ctx == NULL) return nil;
    _packed.resize((size_t)width * height * 4);
    return self;
}

- (void)dealloc {
    if (_ctx != NULL) dm_destroy(_ctx);
}

- (int)width { return _w; }
- (int)height { return _h; }
- (OSType)pixelFormat { return _format; }

- (void)drop { if (_ctx != NULL) dm_drop(_ctx); }
- (void)reset { if (_ctx != NULL) dm_reset(_ctx); }

- (float)ghostStrength { return _ctx != NULL ? dm_ghost_strength(_ctx) : 0.0f; }

- (BOOL)matches:(CVPixelBufferRef)buffer {
    return buffer != NULL &&
        CVPixelBufferGetPixelFormatType(buffer) == _format &&
        (int)CVPixelBufferGetWidth(buffer) == _w &&
        (int)CVPixelBufferGetHeight(buffer) == _h;
}

// Packs the buffer into _packed: BGRA rows without padding, or Y/Cb/Cr/0 per
// pixel with chroma repeated over each 2x2 block.
- (BOOL)pack:(CVPixelBufferRef)buffer {
    const size_t rowBytes = (size_t)_w * 4;
    uint8_t *packed = _packed.data();
    if (_format == kCVPixelFormatType_32BGRA) {
        const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddress(buffer);
        const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        if (base == NULL) return NO;
        for (int y = 0; y < _h; ++y) memcpy(packed + (size_t)y * rowBytes, base + (size_t)y * stride, rowBytes);
        return YES;
    }
    const uint8_t *luma = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    const uint8_t *chroma = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    if (luma == NULL || chroma == NULL) return NO;
    const int w = _w, h = _h;
    dispatch_apply((size_t)h, DISPATCH_APPLY_AUTO, ^(size_t row) {
        const uint8_t *y = luma + row * lumaStride;
        const uint8_t *c = chroma + (row / 2) * chromaStride;
        uint8_t *out = packed + row * rowBytes;
        for (int x = 0; x < w; ++x) {
            out[x * 4] = y[x];
            out[x * 4 + 1] = c[(x / 2) * 2];
            out[x * 4 + 2] = c[(x / 2) * 2 + 1];
            out[x * 4 + 3] = 0;
        }
    });
    return YES;
}

- (void)unpack:(CVPixelBufferRef)buffer {
    const size_t rowBytes = (size_t)_w * 4;
    const uint8_t *packed = _packed.data();
    if (_format == kCVPixelFormatType_32BGRA) {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(buffer);
        const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        for (int y = 0; y < _h; ++y) memcpy(base + (size_t)y * stride, packed + (size_t)y * rowBytes, rowBytes);
        return;
    }
    uint8_t *luma = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 0);
    uint8_t *chroma = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, 1);
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1);
    const int w = _w, h = _h;
    dispatch_apply((size_t)h, DISPATCH_APPLY_AUTO, ^(size_t row) {
        const uint8_t *in = packed + row * rowBytes;
        uint8_t *y = luma + row * lumaStride;
        for (int x = 0; x < w; ++x) y[x] = in[x * 4];
        // Chroma is subsampled 2x2; take it from the top-left pixel of each block.
        if ((row & 1) == 0) {
            uint8_t *c = chroma + (row / 2) * chromaStride;
            for (int x = 0; x < w; x += 2) {
                c[x] = in[x * 4 + 1];
                c[x + 1] = in[x * 4 + 2];
            }
        }
    });
}

- (BOOL)seedWithPixelBuffer:(CVPixelBufferRef)lastFrame {
    if (_ctx == NULL || ![self matches:lastFrame]) return NO;
    if (CVPixelBufferLockBaseAddress(lastFrame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return NO;
    BOOL packed = [self pack:lastFrame];
    CVPixelBufferUnlockBaseAddress(lastFrame, kCVPixelBufferLock_ReadOnly);
    if (!packed) return NO;
    dm_reset(_ctx);
    dm_process(_ctx, _packed.data(), _packed.data());
    dm_drop(_ctx);
    return YES;
}

- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (_ctx == NULL || ![self matches:pixelBuffer]) return NO;
    if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) return NO;
    BOOL ok = [self pack:pixelBuffer];
    if (ok) {
        dm_process(_ctx, _packed.data(), _packed.data());
        [self unpack:pixelBuffer];
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return ok;
}

@end
