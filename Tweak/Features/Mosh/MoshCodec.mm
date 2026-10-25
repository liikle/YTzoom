//
//  MoshCodec.mm
//  Real H.264 datamosh, matching Moshly's Classic effect.
//

#import "MoshCodec.h"
#import "../Downloads/DownloadLog.h"

#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <vector>

static BOOL YTzoomCodecIsBiPlanar(OSType format) {
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
}

// Copies one pixel buffer into another of the same size and format.
static void YTzoomCodecCopy(CVPixelBufferRef source, CVPixelBufferRef destination) {
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destination, 0);
    if (CVPixelBufferIsPlanar(source) && CVPixelBufferIsPlanar(destination)) {
        size_t planes = MIN(CVPixelBufferGetPlaneCount(source), CVPixelBufferGetPlaneCount(destination));
        for (size_t plane = 0; plane < planes; plane++) {
            const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, plane);
            uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destination, plane);
            size_t fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
            size_t toStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane);
            size_t rows = MIN(CVPixelBufferGetHeightOfPlane(source, plane),
                              CVPixelBufferGetHeightOfPlane(destination, plane));
            size_t length = MIN(fromStride, toStride);
            if (from != NULL && to != NULL) {
                for (size_t row = 0; row < rows; row++) memcpy(to + row * toStride, from + row * fromStride, length);
            }
        }
    } else if (!CVPixelBufferIsPlanar(source) && !CVPixelBufferIsPlanar(destination)) {
        const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddress(source);
        uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddress(destination);
        size_t fromStride = CVPixelBufferGetBytesPerRow(source);
        size_t toStride = CVPixelBufferGetBytesPerRow(destination);
        size_t rows = MIN(CVPixelBufferGetHeight(source), CVPixelBufferGetHeight(destination));
        size_t length = MIN(fromStride, toStride);
        if (from != NULL && to != NULL) {
            for (size_t row = 0; row < rows; row++) memcpy(to + row * toStride, from + row * fromStride, length);
        }
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
}

// Copies a bi-planar picture through per-plane level maps (decoder output →
// camera levels); a plain copy when there is nothing to correct.
static void YTzoomCodecCopyMapped(CVPixelBufferRef source, CVPixelBufferRef destination,
                                  const uint8_t *lumaMap, const uint8_t *chromaMap) {
    if (lumaMap == NULL || chromaMap == NULL || !YTzoomCodecIsBiPlanar(CVPixelBufferGetPixelFormatType(source)) ||
        CVPixelBufferGetPlaneCount(destination) < 2) {
        YTzoomCodecCopy(source, destination);
        return;
    }
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destination, 0);
    for (size_t plane = 0; plane < 2; plane++) {
        const uint8_t *map = plane == 0 ? lumaMap : chromaMap;
        const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, plane);
        uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destination, plane);
        size_t fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
        size_t toStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane);
        size_t rows = MIN(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(destination, plane));
        size_t bytes = MIN(CVPixelBufferGetWidthOfPlane(source, plane), CVPixelBufferGetWidthOfPlane(destination, plane)) *
            (plane == 0 ? 1 : 2);
        if (from == NULL || to == NULL) continue;
        for (size_t row = 0; row < rows; row++) {
            const uint8_t *in = from + row * fromStride;
            uint8_t *out = to + row * toStride;
            for (size_t col = 0; col < bytes; col++) out[col] = map[in[col]];
        }
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
}

// Mean and spread of one plane, from a sparse grid.
static BOOL YTzoomCodecPlaneStats(CVPixelBufferRef buffer, size_t plane, double *mean, double *spread) {
    if (!CVPixelBufferIsPlanar(buffer) || CVPixelBufferGetPlaneCount(buffer) <= plane) return NO;
    const uint8_t *base = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(buffer, plane);
    if (base == NULL) return NO;
    size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane);
    size_t rows = CVPixelBufferGetHeightOfPlane(buffer, plane);
    size_t bytes = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2);
    double sum = 0.0, squares = 0.0, count = 0.0;
    for (size_t row = 2; row < rows; row += 6) {
        const uint8_t *line = base + row * stride;
        for (size_t col = 2; col < bytes; col += 6) {
            double value = line[col];
            sum += value;
            squares += value * value;
            count += 1.0;
        }
    }
    if (count < 64.0) return NO;
    *mean = sum / count;
    *spread = sqrt(MAX(0.0, squares / count - *mean * *mean));
    return YES;
}

static float YTzoomCodecMeanDifference(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (a == NULL || b == NULL) return 0.0f;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pa = (const uint8_t *)(CVPixelBufferIsPlanar(a)
        ? CVPixelBufferGetBaseAddressOfPlane(a, 0) : CVPixelBufferGetBaseAddress(a));
    const uint8_t *pb = (const uint8_t *)(CVPixelBufferIsPlanar(b)
        ? CVPixelBufferGetBaseAddressOfPlane(b, 0) : CVPixelBufferGetBaseAddress(b));
    size_t strideA = CVPixelBufferIsPlanar(a) ? CVPixelBufferGetBytesPerRowOfPlane(a, 0) : CVPixelBufferGetBytesPerRow(a);
    size_t strideB = CVPixelBufferIsPlanar(b) ? CVPixelBufferGetBytesPerRowOfPlane(b, 0) : CVPixelBufferGetBytesPerRow(b);
    size_t rows = MIN(CVPixelBufferGetHeight(a), CVPixelBufferGetHeight(b));
    size_t cols = MIN(strideA, strideB);
    unsigned long long total = 0; unsigned long long count = 0;
    if (pa != NULL && pb != NULL) {
        for (size_t row = 0; row < rows; row += 8) {
            const uint8_t *ra = pa + row * strideA, *rb = pb + row * strideB;
            for (size_t col = 0; col < cols; col += 8) {
                int d = (int)ra[col] - (int)rb[col];
                total += (unsigned)(d < 0 ? -d : d);
                count++;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return count ? (float)((double)total / (double)count) : 0.0f;
}

@implementation MoshCodec {
    int _w, _h, _fps;
    OSType _format;

    VTCompressionSessionRef _compression;
    VTDecompressionSessionRef _decompression;
    CMVideoFormatDescriptionRef _decoderFormat;

    os_unfair_lock _lock;
    CVPixelBufferPoolRef _encodePool;  // copies of camera frames fed to the encoder

    CVPixelBufferRef _latestDecoded;   // decoder output, YouTube's format
    CVPixelBufferRef _spareDecoded;    // the next decoder output is mapped into this, then swapped in
    os_unfair_lock _outputLock;        // serialises decoder output handling
    CVPixelBufferRef _lastInput;       // most recent encoder input, for ghost strength
    BOOL _hasDecoded;                  // the decoder has produced at least one picture
    BOOL _writeBack;                   // overwrite the camera frame with the decoded picture

    int64_t _encodeIndex;              // monotonic, carried as each frame's PTS
    int64_t _desyncAtIndex;            // withhold the first frame at/after this index; -1 when none
    int64_t _retimeCounter;            // unique, increasing decode timestamps
    int64_t _anchorIndex;              // index of the anchor keyframe in flight; -1 when none
    CVPixelBufferRef _anchorSource;    // the anchor picture, compared with its decode

    BOOL _correctLevels;               // decoder output needs mapping to the camera's levels
    uint8_t _lumaMap[256];
    uint8_t _chromaMap[256];

    BOOL _needDecoderParams;           // the decoder's very first frame must be a keyframe
    BOOL _allowNextKeyframe;           // a keyframe we deliberately asked for (clip 1)
    BOOL _allowRecoveryKeyframe;       // the decoder genuinely stalled
    BOOL _forceNextKeyframe;           // force the encoder to emit one on the next encode
    BOOL _allowsRecoveryKeyframes;     // off during a mosh window

    int _framesSinceClipStart;
    int _framesWithoutOutput;
    int _lastAppliedBitrate;
    BOOL _restoreBitrate;              // the anchor's boost is still set; undo it on the next frame
    float _ghost;
}

static const int kFullBitrate = 24 * 1000 * 1000;
static const int kOpeningBitrate = 18 * 1000 * 1000;
// The anchor keyframe is the picture a whole clip is built on and should be
// indistinguishable from the frame it reproduces, so it gets far more bits.
static const int kAnchorBitrate = 120 * 1000 * 1000;
static const float kStickSeconds = 0.5f;
static const int kStallFrames = 150;

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat {
    return pixelFormat == kCVPixelFormatType_32BGRA || YTzoomCodecIsBiPlanar(pixelFormat);
}

#pragma mark - Lifecycle

- (nullable instancetype)initWithWidth:(int)width height:(int)height
                           pixelFormat:(OSType)pixelFormat frameRate:(int)frameRate {
    self = [super init];
    if (self == nil || width <= 0 || height <= 0 || frameRate <= 0 ||
        ![MoshCodec supportsPixelFormat:pixelFormat]) {
        return nil;
    }
    _w = width;
    _h = height;
    _fps = frameRate;
    _format = pixelFormat;
    _lock = OS_UNFAIR_LOCK_INIT;
    _outputLock = OS_UNFAIR_LOCK_INIT;
    _desyncAtIndex = -1;
    _anchorIndex = -1;
    _intensity = 3;
    _allowsRecoveryKeyframes = YES;
    NSDictionary *bufferAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(pixelFormat),
        (id)kCVPixelBufferWidthKey: @(width),
        (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL,
                                (__bridge CFDictionaryRef)bufferAttrs, &_encodePool) != kCVReturnSuccess ||
        ![self buildCompression] ||
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}},
                            &_latestDecoded) != kCVReturnSuccess ||
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat,
                            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}},
                            &_spareDecoded) != kCVReturnSuccess) {
        return nil;
    }
    return self;
}

- (void)dealloc {
    if (_compression != NULL) {
        VTCompressionSessionInvalidate(_compression);
        CFRelease(_compression);
    }
    if (_decompression != NULL) {
        VTDecompressionSessionInvalidate(_decompression);
        CFRelease(_decompression);
    }
    if (_decoderFormat != NULL) CFRelease(_decoderFormat);
    if (_latestDecoded != NULL) CVPixelBufferRelease(_latestDecoded);
    if (_spareDecoded != NULL) CVPixelBufferRelease(_spareDecoded);
    if (_anchorSource != NULL) CVPixelBufferRelease(_anchorSource);
    if (_lastInput != NULL) CVPixelBufferRelease(_lastInput);
    if (_encodePool != NULL) CVPixelBufferPoolRelease(_encodePool);
}

- (int)width { return _w; }
- (int)height { return _h; }
- (OSType)pixelFormat { return _format; }

static void YTzoomCodecCompressionOutput(void *outputRefCon, void *sourceFrameRefCon, OSStatus status,
                                         VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer);
static void YTzoomCodecDecompressionOutput(void *decompressionOutputRefCon, void *sourceFrameRefCon,
                                           OSStatus status, VTDecodeInfoFlags infoFlags,
                                           CVImageBufferRef imageBuffer, CMTime presentationTimeStamp,
                                           CMTime presentationDuration);

- (BOOL)buildCompression {
    OSStatus status = VTCompressionSessionCreate(kCFAllocatorDefault, _w, _h, kCMVideoCodecType_H264,
                                                 NULL, NULL, NULL,
                                                 YTzoomCodecCompressionOutput, (__bridge void *)self,
                                                 &_compression);
    if (status != noErr || _compression == NULL) {
        YTzoomDownloadLog(@"mosh", @"compression session failed %d", (int)status);
        return NO;
    }
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_Baseline_AutoLevel);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_H264EntropyMode,
                         kVTH264EntropyMode_CAVLC);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AllowTemporalCompression, kCFBooleanTrue);
    // Open-ended GOP: the only keyframe in a project is the first one, so there
    // is never an IDR at a cut to desynchronise encoder and decoder fatally.
    int32_t maxInterval = INT32_MAX;
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_MaxKeyFrameInterval,
                         (__bridge CFNumberRef)@(maxInterval));
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                         (__bridge CFNumberRef)@(86400.0));
    // Multiple slices per frame keep damage inside a slice and give the tearing
    // its horizontal banding.
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_MaxH264SliceBytes,
                         (__bridge CFNumberRef)@(40000));
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(kFullBitrate));
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_ExpectedFrameRate,
                         (__bridge CFNumberRef)@(_fps));
    // Everything tagged BT.709 so preview, clips and export agree on colour.
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_ColorPrimaries,
                         kCVImageBufferColorPrimaries_ITU_R_709_2);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_TransferFunction,
                         kCVImageBufferTransferFunction_ITU_R_709_2);
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_YCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    VTCompressionSessionPrepareToEncodeFrames(_compression);
    _lastAppliedBitrate = kFullBitrate;
    return YES;
}

#pragma mark - Public controls

- (void)beginClipFirst:(BOOL)firstClip moshing:(BOOL)moshing {
    os_unfair_lock_lock(&_lock);
    _framesSinceClipStart = 0;
    _framesWithoutOutput = 0;
    // Only overwrite YouTube's frame with the decoded picture while moshing, so
    // clip 1 (and any non-moshing clip) stays the pristine live camera.
    _writeBack = moshing;
    if (firstClip) {
        // Clip 1 opens on a fresh baseline keyframe and never moshes.
        _forceNextKeyframe = YES;
        _allowNextKeyframe = YES;
        _desyncAtIndex = -1;
        _allowsRecoveryKeyframes = YES;
    } else if (moshing) {
        // Resume against the previous clip's reference and withhold this clip's
        // first frame: that is the desync that starts the mosh.
        _desyncAtIndex = _encodeIndex;
        _allowsRecoveryKeyframes = NO;   // the mosh is meant to stall the decoder
    } else {
        _desyncAtIndex = -1;
        _allowsRecoveryKeyframes = YES;
    }
    os_unfair_lock_unlock(&_lock);
}

- (void)endClip {
    // Drain so pictures still in flight don't bleed into the next clip. Never
    // complete-until-pts with a flush: that can reset the reference.
    if (_compression != NULL) {
        VTCompressionSessionCompleteFrames(_compression, kCMTimeInvalid);
    }
    if (_decompression != NULL) {
        VTDecompressionSessionWaitForAsynchronousFrames(_decompression);
    }
}

- (void)anchorToPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (_compression == NULL || pixelBuffer == NULL ||
        CVPixelBufferGetPixelFormatType(pixelBuffer) != _format ||
        (int)CVPixelBufferGetWidth(pixelBuffer) != _w || (int)CVPixelBufferGetHeight(pixelBuffer) != _h) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    int64_t index = _encodeIndex++;
    _anchorIndex = index;
    _forceNextKeyframe = NO;
    _desyncAtIndex = -1;
    if (_anchorSource != NULL) CVPixelBufferRelease(_anchorSource);
    _anchorSource = CVPixelBufferRetain(pixelBuffer);
    // Until the keyframe comes back from the decoder, the picture written into
    // the new clip is the anchor itself: the clip opens on exactly that frame.
    YTzoomCodecCopy(pixelBuffer, _latestDecoded);
    _hasDecoded = YES;
    _framesWithoutOutput = 0;
    os_unfair_lock_unlock(&_lock);

    // Near-lossless for the picture the whole next clip is built on, so the
    // decoded keyframe replacing the exact anchor a frame or two later is not
    // a visible step. (Not a QP cap: that lets the encoder drop the frame.)
    _lastAppliedBitrate = kAnchorBitrate;
    _restoreBitrate = YES;
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(kAnchorBitrate));
    NSDictionary *properties = @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES};
    OSStatus status = VTCompressionSessionEncodeFrame(_compression, pixelBuffer, CMTimeMake(index, _fps),
                                                      CMTimeMake(1, _fps), (__bridge CFDictionaryRef)properties,
                                                      NULL, NULL);
    if (status != noErr) YTzoomDownloadLog(@"mosh", @"anchor encode failed %d", (int)status);
}

// The anchor's decode should reproduce the anchor. A systematic difference in
// level (video vs full range, a gamma or matrix mismatch) shows up as a gain
// and offset per plane; when it is more than noise, every later decoded picture
// is mapped back so the mosh keeps the brightness of the frame it continues.
// Called under _outputLock.
- (void)calibrateDecoded:(CVPixelBufferRef)decoded against:(CVPixelBufferRef)source {
    if (!YTzoomCodecIsBiPlanar(_format)) return;
    double decodedMean = 0, decodedSpread = 0, sourceMean = 0, sourceSpread = 0;
    double decodedChromaMean = 0, decodedChromaSpread = 0, sourceChromaMean = 0, sourceChromaSpread = 0;
    CVPixelBufferLockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    BOOL luma = YTzoomCodecPlaneStats(decoded, 0, &decodedMean, &decodedSpread) &&
                YTzoomCodecPlaneStats(source, 0, &sourceMean, &sourceSpread);
    BOOL chroma = YTzoomCodecPlaneStats(decoded, 1, &decodedChromaMean, &decodedChromaSpread) &&
                  YTzoomCodecPlaneStats(source, 1, &sourceChromaMean, &sourceChromaSpread);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(decoded, kCVPixelBufferLock_ReadOnly);
    // A flat frame can't tell gain from offset; keep what an earlier clip found.
    if (!luma || sourceSpread < 8.0 || decodedSpread < 8.0) return;

    double gain = MIN(1.2, MAX(0.85, sourceSpread / decodedSpread));
    double offset = MIN(24.0, MAX(-24.0, sourceMean - gain * decodedMean));
    double chromaGain = 1.0 + (gain - 1.0) * 0.87;   // video-range chroma spans 224 of 219 luma steps
    if (chroma && sourceChromaSpread > 6.0 && decodedChromaSpread > 6.0) {
        chromaGain = MIN(1.2, MAX(0.85, sourceChromaSpread / decodedChromaSpread));
    }
    double worst = 0.0;
    for (int value = 0; value < 256; value++) {
        double mapped = MIN(255.0, MAX(0.0, gain * value + offset));
        if (value >= 16 && value <= 235) worst = MAX(worst, fabs(mapped - value));
        _lumaMap[value] = (uint8_t)lround(mapped);
        _chromaMap[value] = (uint8_t)lround(MIN(255.0, MAX(0.0, 128.0 + chromaGain * (value - 128.0))));
    }
    _correctLevels = worst > 3.0;
    YTzoomDownloadLog(@"mosh", @"levels gain %.3f offset %.1f chroma %.3f %@", gain, offset, chromaGain,
                      _correctLevels ? @"corrected" : @"match");
}

- (float)ghostStrength {
    os_unfair_lock_lock(&_lock);
    float ghost = _ghost;
    os_unfair_lock_unlock(&_lock);
    return ghost;
}

#pragma mark - Per frame

- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (_compression == NULL || pixelBuffer == NULL) return NO;
    if (CVPixelBufferGetPixelFormatType(pixelBuffer) != _format ||
        (int)CVPixelBufferGetWidth(pixelBuffer) != _w || (int)CVPixelBufferGetHeight(pixelBuffer) != _h) {
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    int64_t index = _encodeIndex++;
    BOOL forceKeyframe = _forceNextKeyframe;
    _forceNextKeyframe = NO;
    _framesSinceClipStart++;
    _framesWithoutOutput++;
    BOOL stalled = _allowsRecoveryKeyframes && _framesWithoutOutput > kStallFrames;
    if (stalled) {
        _allowRecoveryKeyframe = YES;
        forceKeyframe = YES;
    }
    if (_lastInput != NULL) CVPixelBufferRelease(_lastInput);
    _lastInput = CVPixelBufferRetain(pixelBuffer);
    os_unfair_lock_unlock(&_lock);

    if (_restoreBitrate) {
        // Straight back to the clip's own curve, not through the throttle.
        _restoreBitrate = NO;
        _lastAppliedBitrate = [self bitrateForFrame:_framesSinceClipStart];
        VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AverageBitRate,
                             (__bridge CFNumberRef)@(_lastAppliedBitrate));
    } else {
        [self applyBitrateForFrame:_framesSinceClipStart];
    }

    // When writing back (a moshing clip), encode a copy: encoding is
    // asynchronous and the decoded picture overwrites YouTube's buffer below,
    // so encoding that same buffer would feed the decoder its own output. When
    // not writing back (clip 1), the buffer is left untouched, so it can be
    // encoded directly — skipping a full-frame copy on the capture queue.
    os_unfair_lock_lock(&_lock);
    BOOL willWriteBack = _writeBack;
    os_unfair_lock_unlock(&_lock);
    CVPixelBufferRef toEncode = NULL;
    if (willWriteBack &&
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _encodePool, &toEncode) == kCVReturnSuccess &&
        toEncode != NULL) {
        YTzoomCodecCopy(pixelBuffer, toEncode);
    } else {
        toEncode = CVPixelBufferRetain(pixelBuffer);
    }

    NSDictionary *frameProperties = forceKeyframe
        ? @{(id)kVTEncodeFrameOptionKey_ForceKeyFrame: @YES} : nil;
    CMTime pts = CMTimeMake(index, _fps);
    VTEncodeInfoFlags flags = 0;
    OSStatus status = VTCompressionSessionEncodeFrame(_compression, toEncode, pts,
                                                      CMTimeMake(1, _fps),
                                                      (__bridge CFDictionaryRef)frameProperties,
                                                      NULL, &flags);
    CVPixelBufferRelease(toEncode);
    if (status != noErr) {
        YTzoomDownloadLog(@"mosh", @"encode failed %d", (int)status);
        return NO;
    }

    // Never block the capture queue: a blocked queue makes AVFoundation discard
    // camera frames, and the mosh deliberately stalls the decoder. Write back
    // whatever the decoder has most recently produced; the pipeline lag is a
    // few frames and, while a mosh holds the decoder, the held reference is the
    // effect. The encode→decode path runs on its own VideoToolbox threads.
    os_unfair_lock_lock(&_lock);
    BOOL wrote = _hasDecoded && _writeBack;
    if (wrote) YTzoomCodecCopy(_latestDecoded, pixelBuffer);
    os_unfair_lock_unlock(&_lock);
    return wrote;
}

- (int)bitrateForFrame:(int)frame {
    // A moshing clip opens starved so the held pixels survive, then climbs back
    // to full quality over the stick window; clip 1 just ramps opening → full.
    float ramp = MAX(6.0f, kStickSeconds * _fps);
    float t = MIN(1.0f, frame / ramp);
    BOOL moshing;
    os_unfair_lock_lock(&_lock);
    moshing = _desyncAtIndex >= 0 || !_allowsRecoveryKeyframes;
    os_unfair_lock_unlock(&_lock);
    if (moshing) {
        int stick = (int)(kFullBitrate * 0.25f);
        float eased = t * t * t;
        return stick + (int)((kFullBitrate - stick) * eased);
    }
    float eased = MIN(1.0f, frame / MAX(6.0f, 0.3f * _fps));
    return kOpeningBitrate + (int)((kFullBitrate - kOpeningBitrate) * eased);
}

- (void)applyBitrateForFrame:(int)frame {
    [self setBitrate:[self bitrateForFrame:frame] frame:frame];
}

- (void)setBitrate:(int)bitrate frame:(int)frame {
    // Only every 3 frames and only on a real move, to avoid thrashing.
    if (frame % 3 != 0) return;
    if (abs(bitrate - _lastAppliedBitrate) < kFullBitrate / 50) return;
    _lastAppliedBitrate = bitrate;
    VTSessionSetProperty(_compression, kVTCompressionPropertyKey_AverageBitRate,
                         (__bridge CFNumberRef)@(bitrate));
}

#pragma mark - Encoded frames (the effect)

- (int)repeatCountForFrame:(int)frame {
    int intensity = _thermalLimited ? 1 : MAX(1, MIN(5, _intensity));
    if (intensity <= 1) return 1;
    float ramp = MAX(6.0f, kStickSeconds * _fps);
    float t = MIN(1.0f, frame / ramp);
    return 1 + (int)lroundf((intensity - 1) * (1.0f - t));
}

- (void)handleEncoded:(CMSampleBufferRef)sampleBuffer {
    if (sampleBuffer == NULL || !CMSampleBufferDataIsReady(sampleBuffer)) return;

    BOOL isKeyframe = YES;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    if (attachments != NULL && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = (CFBooleanRef)CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        if (notSync != NULL && CFBooleanGetValue(notSync)) isKeyframe = NO;
    }

    int64_t thisIndex = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).value;

    os_unfair_lock_lock(&_lock);
    BOOL isAnchor = thisIndex == _anchorIndex;
    if (isAnchor) _anchorIndex = -1;
    if (isKeyframe) {
        BOOL allowed = _needDecoderParams || _allowNextKeyframe || _allowRecoveryKeyframe || isAnchor;
        _allowNextKeyframe = NO;
        _allowRecoveryKeyframe = NO;
        if (!allowed) {
            // An unsolicited IDR would repaint the decoder with a clean frame in
            // the middle of a project; drop it.
            os_unfair_lock_unlock(&_lock);
            return;
        }
        _needDecoderParams = NO;
    }
    if (!isAnchor && _desyncAtIndex >= 0 && thisIndex >= _desyncAtIndex) {
        // Withhold the first frame of the new clip, matched by its own index so
        // a stale in-flight frame from the previous clip doesn't spend it.
        _desyncAtIndex = -1;
        os_unfair_lock_unlock(&_lock);
        return;
    }
    int repeats = isKeyframe ? 1 : [self repeatCountForFrame:_framesSinceClipStart];
    os_unfair_lock_unlock(&_lock);

    if (![self ensureDecoderForSample:sampleBuffer]) return;

    for (int pass = 0; pass < repeats; pass++) {
        BOOL shown = pass == repeats - 1;
        [self submitToDecoder:sampleBuffer tag:shown ? (isAnchor ? 2 : 1) : 0];
    }
}

- (BOOL)ensureDecoderForSample:(CMSampleBufferRef)sampleBuffer {
    CMVideoFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (format == NULL) return NO;
    os_unfair_lock_lock(&_lock);
    BOOL needRebuild = _decompression == NULL || _decoderFormat == NULL ||
        !CMFormatDescriptionEqual(format, _decoderFormat);
    os_unfair_lock_unlock(&_lock);
    if (!needRebuild) return YES;

    VTDecompressionSessionRef session = NULL;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(_format),
        (id)kCVPixelBufferWidthKey: @(_w),
        (id)kCVPixelBufferHeightKey: @(_h),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord callback = { YTzoomCodecDecompressionOutput, (__bridge void *)self };
    OSStatus status = VTDecompressionSessionCreate(kCFAllocatorDefault, format, NULL,
                                                   (__bridge CFDictionaryRef)attrs, &callback, &session);
    if (status != noErr || session == NULL) {
        YTzoomDownloadLog(@"mosh", @"decoder session failed %d", (int)status);
        return NO;
    }
    os_unfair_lock_lock(&_lock);
    if (_decompression != NULL) {
        VTDecompressionSessionInvalidate(_decompression);
        CFRelease(_decompression);
    }
    if (_decoderFormat != NULL) CFRelease(_decoderFormat);
    _decompression = session;
    _decoderFormat = (CMVideoFormatDescriptionRef)CFRetain(format);
    os_unfair_lock_unlock(&_lock);
    return YES;
}

// tag: 0 a hidden duplicate, 1 shown, 2 shown and the anchor keyframe.
- (void)submitToDecoder:(CMSampleBufferRef)sampleBuffer tag:(intptr_t)tag {
    // A decoder discards a picture whose PTS isn't ahead of the last, so every
    // submission (duplicates included) gets a fresh, increasing timestamp.
    os_unfair_lock_lock(&_lock);
    int64_t stamp = _retimeCounter++;
    os_unfair_lock_unlock(&_lock);

    CMSampleTimingInfo timing;
    timing.presentationTimeStamp = CMTimeMake(stamp, _fps * 8);
    timing.duration = CMTimeMake(1, _fps * 8);
    timing.decodeTimeStamp = kCMTimeInvalid;

    CMSampleBufferRef retimed = NULL;
    if (CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sampleBuffer, 1, &timing, &retimed) != noErr ||
        retimed == NULL) {
        return;
    }
    VTDecodeInfoFlags info = 0;
    VTDecompressionSessionDecodeFrame(_decompression, retimed,
                                      kVTDecodeFrame_EnableAsynchronousDecompression,
                                      (void *)tag, &info);
    CFRelease(retimed);
}

- (void)handleDecoded:(CVImageBufferRef)imageBuffer tag:(intptr_t)tag {
    if (imageBuffer == NULL || tag == 0) return;
    if (CVPixelBufferGetWidth(imageBuffer) != (size_t)_w ||
        CVPixelBufferGetHeight(imageBuffer) != (size_t)_h ||
        CVPixelBufferGetPixelFormatType(imageBuffer) != _format) {
        return;
    }
    // Map into the spare picture off the main lock, then swap it in, so the
    // capture queue's write-back never waits on a full-frame conversion.
    os_unfair_lock_lock(&_outputLock);
    if (tag == 2) {
        os_unfair_lock_lock(&_lock);
        CVPixelBufferRef anchor = _anchorSource;
        _anchorSource = NULL;
        os_unfair_lock_unlock(&_lock);
        if (anchor != NULL) {
            [self calibrateDecoded:imageBuffer against:anchor];
            CVPixelBufferRelease(anchor);
        }
    }
    YTzoomCodecCopyMapped(imageBuffer, _spareDecoded, _correctLevels ? _lumaMap : NULL,
                          _correctLevels ? _chromaMap : NULL);
    os_unfair_lock_lock(&_lock);
    CVPixelBufferRef previous = _latestDecoded;
    _latestDecoded = _spareDecoded;
    _spareDecoded = previous;
    _hasDecoded = YES;
    _framesWithoutOutput = 0;
    if (_lastInput != NULL) _ghost = YTzoomCodecMeanDifference(_latestDecoded, _lastInput);
    os_unfair_lock_unlock(&_lock);
    os_unfair_lock_unlock(&_outputLock);
}

@end

static void YTzoomCodecCompressionOutput(void *outputRefCon, void *sourceFrameRefCon, OSStatus status,
                                         VTEncodeInfoFlags infoFlags, CMSampleBufferRef sampleBuffer) {
    (void)sourceFrameRefCon;
    (void)infoFlags;
    if (status != noErr || sampleBuffer == NULL) return;
    [(__bridge MoshCodec *)outputRefCon handleEncoded:sampleBuffer];
}

static void YTzoomCodecDecompressionOutput(void *decompressionOutputRefCon, void *sourceFrameRefCon,
                                           OSStatus status, VTDecodeInfoFlags infoFlags,
                                           CVImageBufferRef imageBuffer, CMTime presentationTimeStamp,
                                           CMTime presentationDuration) {
    (void)infoFlags;
    (void)presentationTimeStamp;
    (void)presentationDuration;
    if (status != noErr || imageBuffer == NULL) return;
    [(__bridge MoshCodec *)decompressionOutputRefCon handleDecoded:imageBuffer
                                                               tag:(intptr_t)sourceFrameRefCon];
}
