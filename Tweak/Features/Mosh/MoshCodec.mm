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
    CVPixelBufferRef _lastInput;       // most recent encoder input, for ghost strength
    BOOL _hasDecoded;                  // the decoder has produced at least one picture
    BOOL _writeBack;                   // overwrite the camera frame with the decoded picture

    int64_t _encodeIndex;              // monotonic, carried as each frame's PTS
    int64_t _desyncAtIndex;            // withhold the first frame at/after this index; -1 when none
    int64_t _retimeCounter;            // unique, increasing decode timestamps

    BOOL _needDecoderParams;           // the decoder's very first frame must be a keyframe
    BOOL _allowNextKeyframe;           // a keyframe we deliberately asked for (reanchor / clip 1)
    BOOL _allowRecoveryKeyframe;       // the decoder genuinely stalled
    BOOL _forceNextKeyframe;           // force the encoder to emit one on the next encode
    BOOL _allowsRecoveryKeyframes;     // off during a mosh window

    int _framesSinceClipStart;
    int _framesWithoutOutput;
    int _lastAppliedBitrate;
    float _ghost;
}

static const int kFullBitrate = 24 * 1000 * 1000;
static const int kOpeningBitrate = 18 * 1000 * 1000;
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
    _desyncAtIndex = -1;
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
                            &_latestDecoded) != kCVReturnSuccess) {
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

- (void)reanchorWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    os_unfair_lock_lock(&_lock);
    _forceNextKeyframe = YES;
    _allowNextKeyframe = YES;
    _desyncAtIndex = -1;
    os_unfair_lock_unlock(&_lock);
    if (pixelBuffer != NULL) [self processPixelBuffer:pixelBuffer];
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

    [self applyBitrateForFrame:_framesSinceClipStart];

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

- (void)applyBitrateForFrame:(int)frame {
    // A moshing clip opens starved so the held pixels survive, then climbs back
    // to full quality over the stick window; clip 1 just ramps opening → full.
    float ramp = MAX(6.0f, kStickSeconds * _fps);
    float t = MIN(1.0f, frame / ramp);
    int stick;
    BOOL moshing;
    os_unfair_lock_lock(&_lock);
    moshing = _desyncAtIndex >= 0 || !_allowsRecoveryKeyframes;
    os_unfair_lock_unlock(&_lock);
    if (moshing) {
        stick = (int)(kFullBitrate * 0.25f);
        float eased = t * t * t;
        int bitrate = stick + (int)((kFullBitrate - stick) * eased);
        [self setBitrate:bitrate frame:frame];
    } else {
        float eased = MIN(1.0f, frame / MAX(6.0f, 0.3f * _fps));
        int bitrate = kOpeningBitrate + (int)((kFullBitrate - kOpeningBitrate) * eased);
        [self setBitrate:bitrate frame:frame];
    }
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
    if (isKeyframe) {
        BOOL allowed = _needDecoderParams || _allowNextKeyframe || _allowRecoveryKeyframe;
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
    if (_desyncAtIndex >= 0 && thisIndex >= _desyncAtIndex) {
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
        [self submitToDecoder:sampleBuffer shown:shown];
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

- (void)submitToDecoder:(CMSampleBufferRef)sampleBuffer shown:(BOOL)shown {
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
                                      (void *)(intptr_t)(shown ? 1 : 0), &info);
    CFRelease(retimed);
}

- (void)handleDecoded:(CVImageBufferRef)imageBuffer shown:(BOOL)shown {
    if (imageBuffer == NULL || !shown) return;
    if (CVPixelBufferGetWidth(imageBuffer) != (size_t)_w ||
        CVPixelBufferGetHeight(imageBuffer) != (size_t)_h ||
        CVPixelBufferGetPixelFormatType(imageBuffer) != _format) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    YTzoomCodecCopy(imageBuffer, _latestDecoded);
    _hasDecoded = YES;
    _framesWithoutOutput = 0;
    if (_lastInput != NULL) _ghost = YTzoomCodecMeanDifference(_latestDecoded, _lastInput);
    os_unfair_lock_unlock(&_lock);
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
                                                             shown:(intptr_t)sourceFrameRefCon != 0];
}
