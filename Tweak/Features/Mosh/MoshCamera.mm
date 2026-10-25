#import "../../YTzoom.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Localization.h"
#import "../../Runtime/Preferences.h"
#import "../../UI/Assets.h"
#import "../../UI/Notice.h"
#import "../Downloads/DownloadLog.h"
#import "MoshCodec.h"
#import "MoshLens.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <arm_neon.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// Moshly camera for the Shorts camera. YouTube keeps its own screen, music
// picker and upload flow; this sits underneath it:
//   - every recorded frame passes through a delegate proxy, which runs it
//     through MoshCodec (a live H.264 encoder/decoder pair) in place before
//     YouTube records it, so the preview and the file both carry the mosh;
//   - the codec keeps one open GOP for the whole camera session, so each new
//     clip resumes against the previous clip's reference picture and its first
//     frame is withheld — the desync that starts the mosh (Moshly Classic);
//   - clip 1 stops and its last frame is shown as a ghost for lining up the
//     next clip; deleting a clip re-anchors onto the one before it;
//   - 0.5x via zoom or a temporary ultra-wide input swap, 60 fps, and a
//     stabilization toggle.

NSString * const YTzoomMoshCameraKey = @"YTzoom.Preference.Mosh.Enabled";
NSString * const YTzoomMoshActiveKey = @"YTzoom.Preference.Mosh.Active";
NSString * const YTzoomMoshUltraWideKey = @"YTzoom.Preference.Mosh.UltraWide";
NSString * const YTzoomMoshStabilizationKey = @"YTzoom.Preference.Mosh.Stabilization";
NSString * const YTzoomMoshHighFrameRateKey = @"YTzoom.Preference.Mosh.HighFrameRate";
NSString * const YTzoomMoshGhostKey = @"YTzoom.Preference.Mosh.Ghost";
NSString * const YTzoomMoshIntensityKey = @"YTzoom.Preference.Mosh.Intensity";

static const int YTzoomMoshFrameRate = 60;
// A segment counts as recording while YouTube's writer took a live frame this recently.
static const CFTimeInterval YTzoomMoshRecordingGap = 0.35;
// Clips more than this far apart belong to different Shorts.
static const CFTimeInterval YTzoomMoshClipLifetime = 30.0 * 60.0;

static BOOL YTzoomMoshEnabled(void) {
    return YTzoomFeatureEnabled(YTzoomMoshCameraKey);
}

static BOOL YTzoomMoshPreference(NSString *key) {
    return YTzoomMoshEnabled() && YTzoomFeatureEnabled(key);
}

#pragma mark - Shared state

static os_unfair_lock YTzoomMoshLock = OS_UNFAIR_LOCK_INIT;
static __weak AVCaptureSession *YTzoomMoshSession;
static __weak AVCaptureDevice *YTzoomMoshDevice;
static __weak AVCaptureConnection *YTzoomMoshConnection;
static CFTimeInterval YTzoomMoshLastLiveAppend;
static BOOL YTzoomMoshMovieRecording;
// Set by hooks on YouTube's own recorder, found at runtime by selector.
static BOOL YTzoomMoshRecorderHooked;
static BOOL YTzoomMoshRecorderRecording;

// Capture-queue state.
static MoshCodec *YTzoomMoshCodecInstance;
static BOOL YTzoomMoshProjectStarted;         // a first clip has been recorded this session
static BOOL YTzoomMoshWasRecording;
static BOOL YTzoomMoshMoshing;
static BOOL YTzoomMoshMoshedThisClip;          // the clip's first frame has been written back
// Set when the camera (re)opens or the user starts over; the capture queue tears
// down the codec and clip state on the next frame so nothing from the previous
// project bleeds in. Guarded by the lock.
static BOOL YTzoomMoshResetPending;
// The clip's last recorded camera frame. A frame counts as recorded once
// YouTube appends to its writer after we handed the frame on: YouTube stamps
// its writer from its own counter, so timestamps can't pair them, but the order
// can. Frames after the last append (the end-of-recording gap) never count.
static CVPixelBufferRef YTzoomMoshPendingFrame;        // retained, handed on, not yet confirmed
static CFTimeInterval YTzoomMoshPendingAt;
static CVPixelBufferRef YTzoomMoshLastRecordedFrame;   // retained, newest confirmed frame

// Writer-side state, guarded by the lock.
static CFTimeInterval YTzoomMoshLastCaptureAt;         // the camera is live while this is recent
static CVPixelBufferRef YTzoomMoshAppendedFrame;       // retained, the last picture YouTube recorded
static CVPixelBufferRef YTzoomMoshOpeningFrame;        // retained, covers a moshing clip's unmoshed opening
static CFTimeInterval YTzoomMoshFirstMoshedAt;         // when this clip's first moshed frame was handed on
static int YTzoomMoshOpeningCovers;                    // frames fully covered so far this clip
static int YTzoomMoshOpeningBlend = -1;                // crossfade step, -1 before it starts
// Frames that only hold the previous clip's last picture are fully covered;
// if the mosh somehow never shows up, the hold ends here rather than freeze.
static const int YTzoomMoshMaxOpeningCovers = 12;
// Then a short crossfade from that exact picture into the clip (~0.17 s at
// 60 fps), so whatever small difference is left dissolves instead of jumping.
static const int YTzoomMoshOpeningFadeFrames = 10;
// Mean luma difference under which the clip's picture counts as "the same
// frame" as the previous clip's last one (noise and encode loss only).
static const float YTzoomMoshSameFrameDifference = 6.0f;

// How each clip ended, newest last, so deleting the last clip in YouTube brings
// back the end of the one before it. `camera` is in the camera's own format
// (anchor and ghost); `recorded` is the picture YouTube actually wrote, in the
// writer's format. Guarded by the lock.
@interface YTzoomMoshClipEnd : NSObject
@property(nonatomic) CVPixelBufferRef camera;
@property(nonatomic) CVPixelBufferRef recorded;
@end

@implementation YTzoomMoshClipEnd
- (void)dealloc {
    if (_camera != NULL) CVPixelBufferRelease(_camera);
    if (_recorded != NULL) CVPixelBufferRelease(_recorded);
}
@end

static NSMutableArray<YTzoomMoshClipEnd *> *YTzoomMoshClipEnds;
static CFTimeInterval YTzoomMoshClipFrameTime;

static void YTzoomMoshCopyInto(CVPixelBufferRef source, CVPixelBufferRef destination) {
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destination, 0);
    if (CVPixelBufferIsPlanar(source) && CVPixelBufferIsPlanar(destination)) {
        size_t planes = MIN(CVPixelBufferGetPlaneCount(source), CVPixelBufferGetPlaneCount(destination));
        for (size_t plane = 0; plane < planes; plane++) {
            const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, plane);
            uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(destination, plane);
            size_t fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
            size_t toStride = CVPixelBufferGetBytesPerRowOfPlane(destination, plane);
            size_t rows = MIN(CVPixelBufferGetHeightOfPlane(source, plane), CVPixelBufferGetHeightOfPlane(destination, plane));
            size_t length = MIN(fromStride, toStride);
            if (from == NULL || to == NULL) continue;
            for (size_t row = 0; row < rows; row++) memcpy(to + row * toStride, from + row * fromStride, length);
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

static BOOL YTzoomMoshSameLayout(CVPixelBufferRef a, CVPixelBufferRef b) {
    return a != NULL && b != NULL && CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b) &&
        CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b) &&
        CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b);
}

// Mean absolute difference of the first plane (luma), from a sparse grid.
static float YTzoomMoshDifference(CVPixelBufferRef a, CVPixelBufferRef b) {
    if (!YTzoomMoshSameLayout(a, b)) return FLT_MAX;
    CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    BOOL planar = CVPixelBufferIsPlanar(a);
    const uint8_t *pa = (const uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(a, 0) : CVPixelBufferGetBaseAddress(a));
    const uint8_t *pb = (const uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(b, 0) : CVPixelBufferGetBaseAddress(b));
    size_t strideA = planar ? CVPixelBufferGetBytesPerRowOfPlane(a, 0) : CVPixelBufferGetBytesPerRow(a);
    size_t strideB = planar ? CVPixelBufferGetBytesPerRowOfPlane(b, 0) : CVPixelBufferGetBytesPerRow(b);
    size_t rows = planar ? CVPixelBufferGetHeightOfPlane(a, 0) : CVPixelBufferGetHeight(a);
    size_t bytes = MIN(strideA, strideB);
    double total = 0.0, count = 0.0;
    if (pa != NULL && pb != NULL) {
        for (size_t row = 3; row < rows; row += 8) {
            const uint8_t *ra = pa + row * strideA, *rb = pb + row * strideB;
            for (size_t col = 3; col < bytes; col += 8) {
                total += abs((int)ra[col] - (int)rb[col]);
                count += 1.0;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
    return count > 0.0 ? (float)(total / count) : FLT_MAX;
}

// destination = from * (1 - weight) + destination * weight, every byte of
// every plane (same layout), sixteen bytes at a time with NEON. weight 0 is a
// plain copy of `from`.
static void YTzoomMoshBlendInto(CVPixelBufferRef from, CVPixelBufferRef destination, float weight) {
    if (weight <= 0.0f) {
        YTzoomMoshCopyInto(from, destination);
        return;
    }
    if (weight >= 1.0f) return;
    uint8_t keep = (uint8_t)MIN(255L, MAX(1L, lroundf(weight * 256.0f)));
    uint8_t fade = (uint8_t)(256 - keep);
    uint8x8_t keepLanes = vdup_n_u8(keep), fadeLanes = vdup_n_u8(fade);
    CVPixelBufferLockBaseAddress(from, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(destination, 0);
    BOOL planar = CVPixelBufferIsPlanar(from) && CVPixelBufferIsPlanar(destination);
    size_t planes = planar ? MIN(CVPixelBufferGetPlaneCount(from), CVPixelBufferGetPlaneCount(destination)) : 1;
    for (size_t plane = 0; plane < planes; plane++) {
        const uint8_t *in = (const uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(from, plane)
                                                     : CVPixelBufferGetBaseAddress(from));
        uint8_t *out = (uint8_t *)(planar ? CVPixelBufferGetBaseAddressOfPlane(destination, plane)
                                          : CVPixelBufferGetBaseAddress(destination));
        size_t inStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(from, plane) : CVPixelBufferGetBytesPerRow(from);
        size_t outStride = planar ? CVPixelBufferGetBytesPerRowOfPlane(destination, plane)
                                  : CVPixelBufferGetBytesPerRow(destination);
        size_t rows = planar ? MIN(CVPixelBufferGetHeightOfPlane(from, plane), CVPixelBufferGetHeightOfPlane(destination, plane))
                             : MIN(CVPixelBufferGetHeight(from), CVPixelBufferGetHeight(destination));
        size_t bytes = MIN(inStride, outStride);
        if (in == NULL || out == NULL) continue;
        for (size_t row = 0; row < rows; row++) {
            const uint8_t *a = in + row * inStride;
            uint8_t *b = out + row * outStride;
            size_t col = 0;
            for (; col + 16 <= bytes; col += 16) {
                uint8x16_t va = vld1q_u8(a + col), vb = vld1q_u8(b + col);
                uint16x8_t low = vmlal_u8(vmull_u8(vget_low_u8(va), fadeLanes), vget_low_u8(vb), keepLanes);
                uint16x8_t high = vmlal_u8(vmull_u8(vget_high_u8(va), fadeLanes), vget_high_u8(vb), keepLanes);
                vst1q_u8(b + col, vcombine_u8(vrshrn_n_u16(low, 8), vrshrn_n_u16(high, 8)));
            }
            for (; col < bytes; col++) b[col] = (uint8_t)((a[col] * fade + b[col] * keep + 128u) >> 8);
        }
    }
    CVPixelBufferUnlockBaseAddress(destination, 0);
    CVPixelBufferUnlockBaseAddress(from, kCVPixelBufferLock_ReadOnly);
}

static CVPixelBufferRef YTzoomMoshCopyPixelBuffer(CVPixelBufferRef source) {
    if (source == NULL) return NULL;
    CVPixelBufferRef copy = NULL;
    NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
    if (CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source), (__bridge CFDictionaryRef)attributes,
                            &copy) != kCVReturnSuccess) {
        return NULL;
    }
    YTzoomMoshCopyInto(source, copy);
    return copy;
}

static BOOL YTzoomMoshPreferenceActive(void) {
    return YTzoomMoshPreference(YTzoomMoshActiveKey);
}

// Every video frame YouTube writes. Marks recording, remembers the picture, and
// makes a moshing clip open on exactly the previous clip's last recorded
// picture: every frame YouTube writes before the mosh shows up (it is only
// detected from these appends, and YouTube's pipeline can have frames in
// flight) is replaced by that picture, then the clip crossfades in from it.
// Done here, on the frames actually written, so it holds whatever YouTube's
// pipeline latency is: the cut is seamless in the file.
static void YTzoomMoshNoteLiveAppend(CVPixelBufferRef buffer) {
    // Any video append counts as recording. (An earlier host-clock gate meant
    // to exclude editor exports also rejected real recording, because YouTube,
    // like Moshly, timestamps its writer from a counter near zero rather than
    // the host clock.) The recorder hooks below are preferred when present and
    // avoid treating an export as a clip.
    CFTimeInterval now = CACurrentMediaTime();
    // Preferences are only read when this could be a new clip.
    BOOL moshActive = now - YTzoomMoshLastLiveAppend >= YTzoomMoshRecordingGap && YTzoomMoshPreferenceActive();
    CVPixelBufferRef opening = NULL;
    BOOL moshedSent = NO;
    int covers = 0, blend = -1;
    os_unfair_lock_lock(&YTzoomMoshLock);
    BOOL first = YTzoomMoshLastLiveAppend == 0.0;
    BOOL newClip = first || now - YTzoomMoshLastLiveAppend >= YTzoomMoshRecordingGap;
    YTzoomMoshLastLiveAppend = now;
    // Only while the camera is delivering frames: never touch an export.
    BOOL live = YTzoomMoshLastCaptureAt != 0.0 && now - YTzoomMoshLastCaptureAt < 0.3;
    if (live && buffer != NULL) {
        if (newClip) {
            if (YTzoomMoshOpeningFrame != NULL) CVPixelBufferRelease(YTzoomMoshOpeningFrame);
            YTzoomMoshOpeningFrame = NULL;
            YTzoomMoshFirstMoshedAt = 0.0;
            YTzoomMoshOpeningCovers = 0;
            YTzoomMoshOpeningBlend = -1;
            YTzoomMoshClipEnd *end = YTzoomMoshClipEnds.lastObject;
            if (YTzoomMoshProjectStarted && moshActive && end.recorded != NULL &&
                CACurrentMediaTime() - YTzoomMoshClipFrameTime < YTzoomMoshClipLifetime) {
                YTzoomMoshOpeningFrame = CVPixelBufferRetain(end.recorded);
            }
        }
        if (YTzoomMoshOpeningFrame != NULL) {
            opening = CVPixelBufferRetain(YTzoomMoshOpeningFrame);
            moshedSent = YTzoomMoshFirstMoshedAt != 0.0 && now >= YTzoomMoshFirstMoshedAt;
            covers = YTzoomMoshOpeningCovers;
            blend = YTzoomMoshOpeningBlend;
        }
        if (YTzoomMoshAppendedFrame != buffer) {
            if (YTzoomMoshAppendedFrame != NULL) CVPixelBufferRelease(YTzoomMoshAppendedFrame);
            YTzoomMoshAppendedFrame = CVPixelBufferRetain(buffer);
        }
    }
    os_unfair_lock_unlock(&YTzoomMoshLock);

    if (opening != NULL) {
        BOOL usable = YTzoomMoshSameLayout(opening, buffer);
        if (usable && blend < 0) {
            // Hold until YouTube writes a moshed frame, recognised by being the
            // same picture as the previous clip's end (the mosh opens on it).
            // Frames still in flight from before the mosh are the raw view.
            float difference = moshedSent ? YTzoomMoshDifference(opening, buffer) : FLT_MAX;
            if (difference <= YTzoomMoshSameFrameDifference || covers >= YTzoomMoshMaxOpeningCovers) {
                blend = 0;
                YTzoomDownloadLog(@"mosh", @"opening held %d frames, fading in (difference %.1f)", covers,
                                  difference == FLT_MAX ? -1.0f : difference);
            }
        }
        if (!usable) {
            blend = YTzoomMoshOpeningFadeFrames;
        } else if (blend < 0) {
            YTzoomMoshCopyInto(opening, buffer);
            covers++;
        } else if (blend < YTzoomMoshOpeningFadeFrames) {
            float t = (float)(blend + 1) / (float)(YTzoomMoshOpeningFadeFrames + 1);
            YTzoomMoshBlendInto(opening, buffer, t * t * (3.0f - 2.0f * t));
            blend++;
        }
        CVPixelBufferRelease(opening);
        os_unfair_lock_lock(&YTzoomMoshLock);
        YTzoomMoshOpeningCovers = covers;
        YTzoomMoshOpeningBlend = blend;
        if (blend >= YTzoomMoshOpeningFadeFrames && YTzoomMoshOpeningFrame != NULL) {
            CVPixelBufferRelease(YTzoomMoshOpeningFrame);
            YTzoomMoshOpeningFrame = NULL;
        }
        os_unfair_lock_unlock(&YTzoomMoshLock);
    }
    if (first) YTzoomDownloadLog(@"mosh", @"first writer append seen");
}

static BOOL YTzoomMoshIsRecording(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    // Any signal counts. The recorder hooks matching at install time does NOT
    // mean they fire at runtime (YouTube may record through a different class),
    // and relying on them alone meant recording was never detected and nothing
    // ran. The writer-append signal is the reliable one when YouTube records
    // through AVAssetWriter, which the binary scan shows it does.
    BOOL recording = YTzoomMoshRecorderRecording || YTzoomMoshMovieRecording ||
        (YTzoomMoshLastLiveAppend != 0.0 &&
         CACurrentMediaTime() - YTzoomMoshLastLiveAppend < YTzoomMoshRecordingGap);
    os_unfair_lock_unlock(&YTzoomMoshLock);
    return recording;
}

static YTzoomMoshClipEnd *YTzoomMoshLastClipEnd(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    YTzoomMoshClipEnd *last = YTzoomMoshClipEnds.lastObject;
    BOOL fresh = CACurrentMediaTime() - YTzoomMoshClipFrameTime < YTzoomMoshClipLifetime;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    return fresh ? last : nil;
}

static void YTzoomMoshPushClipEnd(YTzoomMoshClipEnd *end) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    if (YTzoomMoshClipEnds == nil) YTzoomMoshClipEnds = [NSMutableArray array];
    if (CACurrentMediaTime() - YTzoomMoshClipFrameTime >= YTzoomMoshClipLifetime) {
        [YTzoomMoshClipEnds removeAllObjects];
    }
    [YTzoomMoshClipEnds addObject:end];
    while (YTzoomMoshClipEnds.count > 30) [YTzoomMoshClipEnds removeObjectAtIndex:0];
    YTzoomMoshClipFrameTime = CACurrentMediaTime();
    os_unfair_lock_unlock(&YTzoomMoshLock);
}

// Promotes the pending frame to the last recorded one if YouTube has appended
// since it was handed on, else drops it. Capture queue only.
static void YTzoomMoshSettlePendingFrame(void) {
    if (YTzoomMoshPendingFrame == NULL) return;
    os_unfair_lock_lock(&YTzoomMoshLock);
    BOOL recorded = YTzoomMoshLastLiveAppend > YTzoomMoshPendingAt;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    if (recorded) {
        if (YTzoomMoshLastRecordedFrame != NULL) CVPixelBufferRelease(YTzoomMoshLastRecordedFrame);
        YTzoomMoshLastRecordedFrame = YTzoomMoshPendingFrame;
    } else {
        CVPixelBufferRelease(YTzoomMoshPendingFrame);
    }
    YTzoomMoshPendingFrame = NULL;
}

static void YTzoomMoshForgetRecordedFrames(void) {
    if (YTzoomMoshPendingFrame != NULL) CVPixelBufferRelease(YTzoomMoshPendingFrame);
    if (YTzoomMoshLastRecordedFrame != NULL) CVPixelBufferRelease(YTzoomMoshLastRecordedFrame);
    YTzoomMoshPendingFrame = NULL;
    YTzoomMoshLastRecordedFrame = NULL;
}

#pragma mark - Ghost preview

@interface YTzoomMoshOverlay : NSObject
+ (void)showGhost:(UIImage *)image;
+ (void)hideGhost;
+ (void)attachControls;
+ (void)detachControls;
+ (void)refreshControls;
@end

static UIImage *YTzoomMoshGhostImage(CVPixelBufferRef frame, AVCaptureDevicePosition position) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CIImage *image = [CIImage imageWithCVPixelBuffer:frame];
    CGImageRef rendered = [context createCGImage:image fromRect:image.extent];
    if (rendered == NULL) return nil;
    BOOL landscape = CVPixelBufferGetWidth(frame) > CVPixelBufferGetHeight(frame);
    BOOL front = position == AVCaptureDevicePositionFront;
    UIImageOrientation orientation = landscape
        ? (front ? UIImageOrientationLeftMirrored : UIImageOrientationRight)
        : (front ? UIImageOrientationUpMirrored : UIImageOrientationUp);
    UIImage *result = [UIImage imageWithCGImage:rendered scale:1.0 orientation:orientation];
    CGImageRelease(rendered);
    return result;
}

#pragma mark - Frames

static __weak AVCaptureOutput *YTzoomMoshMainOutput;
static size_t YTzoomMoshMainArea;

// Runs on YouTube's capture queue, before YouTube's own delegate.
static void YTzoomMoshHandleFrame(AVCaptureOutput *output, CMSampleBufferRef sampleBuffer,
                                  AVCaptureConnection *connection) {
    if (!YTzoomMoshEnabled()) return;
    CVPixelBufferRef frame = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (frame == NULL) return;
    // YouTube can run a second, smaller output for effects; only the largest
    // one is recorded, and mixing two streams would wreck the mosh.
    size_t area = CVPixelBufferGetWidth(frame) * CVPixelBufferGetHeight(frame);
    AVCaptureOutput *main = YTzoomMoshMainOutput;
    if (main == nil || (output != main && area > YTzoomMoshMainArea)) {
        YTzoomMoshMainOutput = output;
        main = output;
        YTzoomDownloadLog(@"mosh", @"main output %@ %zux%zu fmt %u recorderHooked %d",
                          NSStringFromClass(output.class), CVPixelBufferGetWidth(frame),
                          CVPixelBufferGetHeight(frame),
                          (unsigned)CVPixelBufferGetPixelFormatType(frame), YTzoomMoshRecorderHooked);
    }
    if (output != main) return;
    YTzoomMoshMainArea = area;
    YTzoomMoshConnection = connection;

    // Tear down a previous project's state so no stale frame or reference bleeds
    // into a new recording (camera reopened, or the user started over).
    CFTimeInterval handedAt = CACurrentMediaTime();
    os_unfair_lock_lock(&YTzoomMoshLock);
    BOOL doReset = YTzoomMoshResetPending;
    YTzoomMoshResetPending = NO;
    YTzoomMoshLastCaptureAt = handedAt;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    if (doReset) {
        YTzoomMoshCodecInstance = nil;
        YTzoomMoshForgetRecordedFrames();
        YTzoomMoshWasRecording = NO;
        YTzoomMoshMoshing = NO;
        YTzoomDownloadLog(@"mosh", @"project reset");
    }

    // Keep the on-camera controls present: YouTube can rebuild the camera view
    // without restarting the session, which drops them. attachControls no-ops
    // when they are already in place and the live camera is showing.
    static int YTzoomMoshControlTick;
    if ((YTzoomMoshControlTick++ % 45) == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay attachControls]; });
    }

    AVCaptureDevicePosition position = AVCaptureDevicePositionUnspecified;
    for (AVCaptureInputPort *port in connection.inputPorts) {
        if ([port.input isKindOfClass:AVCaptureDeviceInput.class]) {
            position = ((AVCaptureDeviceInput *)port.input).device.position;
        }
    }

    BOOL recording = YTzoomMoshIsRecording();
    if (recording && !YTzoomMoshWasRecording) {
        // Clip start. The codec keeps its own reference across clips (open GOP,
        // sessions built once), so clip 2 onward resume against clip 1's last
        // picture automatically; a clip just declares whether it moshes.
        OSType format = CVPixelBufferGetPixelFormatType(frame);
        int width = (int)CVPixelBufferGetWidth(frame);
        int height = (int)CVPixelBufferGetHeight(frame);
        MoshCodec *codec = YTzoomMoshCodecInstance;
        if (codec == nil || codec.width != width || codec.height != height || codec.pixelFormat != format) {
            // A new codec can only resume from its own first keyframe, so this
            // is a fresh project whatever came before (e.g. a resolution change).
            codec = [[MoshCodec alloc] initWithWidth:width height:height pixelFormat:format
                                           frameRate:YTzoomMoshFrameRate];
            YTzoomMoshCodecInstance = codec;
            YTzoomMoshProjectStarted = NO;
        }
        BOOL firstClip = !YTzoomMoshProjectStarted;
        BOOL moshing = codec != nil && !firstClip && YTzoomMoshPreference(YTzoomMoshActiveKey);
        YTzoomMoshMoshing = moshing;
        YTzoomMoshMoshedThisClip = NO;
        YTzoomMoshForgetRecordedFrames();
        // Every clip after the first continues from exactly the last recorded
        // frame of the project (after a delete, that of the clip now last):
        // it becomes a keyframe and the picture the new clip opens on, so the
        // mosh lines up with the previous clip frame for frame.
        YTzoomMoshClipEnd *end = firstClip ? nil : YTzoomMoshLastClipEnd();
        if (codec != nil && end.camera != NULL) [codec anchorToPixelBuffer:end.camera];
        codec.intensity = (int)[YTzoomPreferenceObject(YTzoomMoshIntensityKey) integerValue];
        [codec beginClipFirst:firstClip moshing:moshing];
        YTzoomDownloadLog(@"mosh", @"clip start %dx%d fmt %u first %d mosh %d", width, height,
                          (unsigned)format, firstClip, moshing);
        dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay hideGhost]; });
    }

    if (recording && YTzoomMoshCodecInstance != nil) {
        // Runs every recorded frame: encodes it and writes the decoder's latest
        // picture back in place. While a mosh holds the decoder that picture is
        // the held reference, which is the effect, in the preview and the file.
        BOOL wrote = [YTzoomMoshCodecInstance processPixelBuffer:frame];
        if (wrote && !YTzoomMoshMoshedThisClip) {
            // From here on YouTube receives moshed frames; anything it writes
            // before this was handed on unmoshed and gets covered at append.
            YTzoomMoshMoshedThisClip = YES;
            os_unfair_lock_lock(&YTzoomMoshLock);
            YTzoomMoshFirstMoshedAt = handedAt;
            os_unfair_lock_unlock(&YTzoomMoshLock);
        }
        static int logCounter;
        if ((logCounter++ % 30) == 0) {
            YTzoomDownloadLog(@"mosh", @"recording mosh %d wroteDecoded %d ghost %.1f",
                              YTzoomMoshMoshing, wrote, YTzoomMoshCodecInstance.ghostStrength);
        }
        // The frame as handed on (moshed or not) is what YouTube records.
        YTzoomMoshSettlePendingFrame();
        YTzoomMoshPendingFrame = CVPixelBufferRetain(frame);
        YTzoomMoshPendingAt = handedAt;
    } else if (!recording && YTzoomMoshWasRecording) {
        // Clip end: drain the decoder and keep the clip's exact last recorded
        // frame for the ghost overlay and to anchor the next clip on.
        [YTzoomMoshCodecInstance endClip];
        YTzoomMoshSettlePendingFrame();
        CVPixelBufferRef last = YTzoomMoshCopyPixelBuffer(YTzoomMoshLastRecordedFrame);
        YTzoomMoshForgetRecordedFrames();
        os_unfair_lock_lock(&YTzoomMoshLock);
        CVPixelBufferRef appended = YTzoomMoshAppendedFrame;
        YTzoomMoshAppendedFrame = NULL;
        os_unfair_lock_unlock(&YTzoomMoshLock);
        CVPixelBufferRef recorded = YTzoomMoshCopyPixelBuffer(appended);
        if (appended != NULL) CVPixelBufferRelease(appended);
        os_unfair_lock_lock(&YTzoomMoshLock);
        YTzoomMoshProjectStarted = YES;
        os_unfair_lock_unlock(&YTzoomMoshLock);
        // The written picture is the exact last frame whatever YouTube's
        // latency; when it has the camera's layout and is that same frame
        // (not mirrored or filtered), the next clip anchors on it directly.
        float writtenDifference = YTzoomMoshDifference(recorded, last);
        if (writtenDifference < 12.0f) {
            CVPixelBufferRelease(last);
            last = CVPixelBufferRetain(recorded);
        }
        if (last != NULL) {
            YTzoomMoshClipEnd *end = [YTzoomMoshClipEnd new];
            end.camera = CVPixelBufferRetain(last);
            end.recorded = recorded != NULL ? CVPixelBufferRetain(recorded) : NULL;
            YTzoomMoshPushClipEnd(end);
            YTzoomDownloadLog(@"mosh", @"clip end, kept last frame (written %d, difference %.1f, anchor %@)",
                              recorded != NULL, writtenDifference == FLT_MAX ? -1.0f : writtenDifference,
                              writtenDifference < 12.0f ? @"written" : @"camera");
            if (YTzoomMoshPreference(YTzoomMoshGhostKey)) {
                UIImage *ghost = YTzoomMoshGhostImage(last, position);
                if (ghost != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay showGhost:ghost]; });
                }
            }
            CVPixelBufferRelease(last);
        }
        if (recorded != NULL) CVPixelBufferRelease(recorded);
        YTzoomMoshMoshing = NO;
    }
    YTzoomMoshWasRecording = recording;
}

// Start a fresh project: the next recording is clip 1 again, on a new keyframe,
// with no state (codec reference, clip frames, ghost) left from before. The
// codec and the latest-frame pointer are owned by the capture queue, so they
// are torn down there via the pending flag rather than from here.
static void YTzoomMoshResetProject(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    [YTzoomMoshClipEnds removeAllObjects];
    YTzoomMoshProjectStarted = NO;
    YTzoomMoshRecorderRecording = NO;
    YTzoomMoshMovieRecording = NO;
    YTzoomMoshLastLiveAppend = 0.0;
    if (YTzoomMoshAppendedFrame != NULL) { CVPixelBufferRelease(YTzoomMoshAppendedFrame); YTzoomMoshAppendedFrame = NULL; }
    if (YTzoomMoshOpeningFrame != NULL) { CVPixelBufferRelease(YTzoomMoshOpeningFrame); YTzoomMoshOpeningFrame = NULL; }
    YTzoomMoshFirstMoshedAt = 0.0;
    YTzoomMoshResetPending = YES;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay hideGhost]; });
}

// YouTube deleted its last clip: the next clip anchors on the end of the clip
// before it (the new last entry), and that clip's ghost comes back.
static void YTzoomMoshDropLastClip(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    if (YTzoomMoshClipEnds.count != 0) [YTzoomMoshClipEnds removeLastObject];
    if (YTzoomMoshClipEnds.count == 0) YTzoomMoshProjectStarted = NO;   // nothing left: next clip is clip 1
    os_unfair_lock_unlock(&YTzoomMoshLock);
    YTzoomMoshClipEnd *previous = YTzoomMoshLastClipEnd();
    UIImage *ghost = previous.camera != NULL && YTzoomMoshPreference(YTzoomMoshGhostKey)
        ? YTzoomMoshGhostImage(previous.camera, YTzoomMoshDevice.position) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (ghost != nil) [YTzoomMoshOverlay showGhost:ghost];
        else [YTzoomMoshOverlay hideGhost];
    });
}

@interface YTzoomMoshDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@end

@implementation YTzoomMoshDelegateProxy

- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.target respondsToSelector:selector];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    return self.target;
}

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    YTzoomMoshHandleFrame(output, sampleBuffer, connection);
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if ([target respondsToSelector:_cmd]) {
        [target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output
      didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target = self.target;
    if ([target respondsToSelector:_cmd]) {
        [target captureOutput:output didDropSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

@end

static const void *YTzoomMoshProxyAssociation = &YTzoomMoshProxyAssociation;
static IMP OriginalSetSampleBufferDelegate;

static void YTzoomMoshSetSampleBufferDelegate(id output, SEL selector, id delegate, dispatch_queue_t queue) {
    id forwarded = delegate;
    if (delegate != nil && YTzoomMoshEnabled() && ![delegate isKindOfClass:YTzoomMoshDelegateProxy.class]) {
        YTzoomMoshDelegateProxy *proxy = [YTzoomMoshDelegateProxy new];
        proxy.target = delegate;
        // The output holds its delegate weakly, so the output keeps the proxy alive.
        objc_setAssociatedObject(output, YTzoomMoshProxyAssociation, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        forwarded = proxy;
    } else if (delegate == nil) {
        objc_setAssociatedObject(output, YTzoomMoshProxyAssociation, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    ((void (*)(id, SEL, id, dispatch_queue_t))OriginalSetSampleBufferDelegate)(output, selector, forwarded, queue);
}

#pragma mark - Recording detection

static IMP OriginalAppendSampleBuffer;
static IMP OriginalAppendPixelBuffer;
static IMP OriginalMovieStart;
static IMP OriginalMovieStop;

static BOOL YTzoomMoshAppendSampleBuffer(AVAssetWriterInput *input, SEL selector, CMSampleBufferRef sampleBuffer) {
    if (sampleBuffer != NULL && [input.mediaType isEqualToString:AVMediaTypeVideo]) {
        YTzoomMoshNoteLiveAppend(CMSampleBufferGetImageBuffer(sampleBuffer));
    }
    return ((BOOL (*)(id, SEL, CMSampleBufferRef))OriginalAppendSampleBuffer)(input, selector, sampleBuffer);
}

static BOOL YTzoomMoshAppendPixelBuffer(id adaptor, SEL selector, CVPixelBufferRef pixelBuffer, CMTime time) {
    YTzoomMoshNoteLiveAppend(pixelBuffer);
    return ((BOOL (*)(id, SEL, CVPixelBufferRef, CMTime))OriginalAppendPixelBuffer)(adaptor, selector, pixelBuffer, time);
}

static void YTzoomMoshMovieStart(id output, SEL selector, NSURL *URL, id delegate) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    YTzoomMoshMovieRecording = YES;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    ((void (*)(id, SEL, id, id))OriginalMovieStart)(output, selector, URL, delegate);
}

static void YTzoomMoshMovieStop(id output, SEL selector) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    YTzoomMoshMovieRecording = NO;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    ((void (*)(id, SEL))OriginalMovieStop)(output, selector);
}

// YouTube's Shorts recorder has no public class name, so the classes that
// implement these selectors are found at runtime. Each is only hooked when its
// type encoding matches what the replacement expects.
static NSMutableDictionary<NSString *, NSValue *> *YTzoomMoshRecorderOriginals;

static IMP YTzoomMoshRecorderOriginal(id receiver, SEL selector) {
    for (Class cls = object_getClass(receiver); cls != Nil; cls = class_getSuperclass(cls)) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(cls), NSStringFromSelector(selector)];
        NSValue *value;
        @synchronized (YTzoomMoshRecorderOriginals) { value = YTzoomMoshRecorderOriginals[key]; }
        if (value != nil) return (IMP)value.pointerValue;
    }
    return NULL;
}

static void YTzoomMoshSetRecorderRecording(BOOL recording) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    YTzoomMoshRecorderRecording = recording;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    YTzoomDownloadLog(@"mosh", @"recorder %@", recording ? @"started" : @"stopped");
}

static void YTzoomMoshBeginRecording(id receiver, SEL selector, CMTimeRange range) {
    YTzoomMoshSetRecorderRecording(YES);
    IMP original = YTzoomMoshRecorderOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, CMTimeRange))original)(receiver, selector, range);
}

static void YTzoomMoshStopRecording(id receiver, SEL selector, id segment) {
    YTzoomMoshSetRecorderRecording(NO);
    IMP original = YTzoomMoshRecorderOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, id))original)(receiver, selector, segment);
}

static void YTzoomMoshDidRemoveSegment(id receiver, SEL selector, id manager, id segment) {
    if (YTzoomMoshEnabled()) YTzoomMoshDropLastClip();
    IMP original = YTzoomMoshRecorderOriginal(receiver, selector);
    if (original != NULL) ((void (*)(id, SEL, id, id))original)(receiver, selector, manager, segment);
}

static void YTzoomMoshHookRecorder(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        YTzoomMoshRecorderOriginals = [NSMutableDictionary dictionary];
        NSString *timeRange = [NSString stringWithUTF8String:@encode(CMTimeRange)];
        NSArray<NSArray *> *targets = @[
            @[@"beginRecordingWithPendingSegmentsTimeRange:", [NSValue valueWithPointer:(void *)YTzoomMoshBeginRecording],
              [@"v@:" stringByAppendingString:timeRange]],
            @[@"actuallyStopRecordingWithSegment:", [NSValue valueWithPointer:(void *)YTzoomMoshStopRecording], @"v@:@"],
            @[@"cameraUndoRedoManager:didRemoveCameraSegment:",
              [NSValue valueWithPointer:(void *)YTzoomMoshDidRemoveSegment], @"v@:@@"]
        ];
        NSUInteger startStopHooks = 0;
        NSArray<NSString *> *hints = @[@"Camera", @"Record", @"Capture", @"Creation", @"Shorts",
                                       @"Segment", @"Reel", @"Undo"];
        for (NSString *className in YTzoomAppClassNames()) {
            BOOL hinted = NO;
            for (NSString *hint in hints) {
                if ([className rangeOfString:hint].location != NSNotFound) { hinted = YES; break; }
            }
            Class cls = hinted ? NSClassFromString(className) : Nil;
            if (cls == Nil) continue;
            unsigned int count = 0;
            Method *methods = class_copyMethodList(cls, &count);
            for (NSArray *target in targets) {
                SEL selector = NSSelectorFromString(target[0]);
                Method found = NULL;
                for (unsigned int index = 0; index < count; index++) {
                    if (method_getName(methods[index]) == selector) found = methods[index];
                }
                if (found == NULL) continue;
                // Compare the encoding without its frame offsets.
                NSString *encoding = [NSString stringWithUTF8String:method_getTypeEncoding(found) ?: ""];
                NSString *bare = [[encoding componentsSeparatedByCharactersInSet:
                    NSCharacterSet.decimalDigitCharacterSet] componentsJoinedByString:@""];
                if (![bare isEqualToString:target[2]]) {
                    YTzoomDownloadLog(@"mosh", @"skip %@ %@ (%@)", className, target[0], bare);
                    continue;
                }
                IMP original = NULL;
                if (YTzoomInstallInstanceHook(className, target[0], (IMP)[target[1] pointerValue], &original) &&
                    original != NULL) {
                    @synchronized (YTzoomMoshRecorderOriginals) {
                        YTzoomMoshRecorderOriginals[[NSString stringWithFormat:@"%@|%@", className, target[0]]] =
                            [NSValue valueWithPointer:(void *)original];
                    }
                    if (target != targets.lastObject) startStopHooks++;
                    YTzoomDownloadLog(@"mosh", @"hooked %@ %@", className, target[0]);
                }
            }
            free(methods);
        }
        // Only trust the recorder for start and stop when both were found.
        os_unfair_lock_lock(&YTzoomMoshLock);
        YTzoomMoshRecorderHooked = startStopHooks >= 2;
        os_unfair_lock_unlock(&YTzoomMoshLock);
    });
}

#pragma mark - Lens, frame rate and stabilization

static NSMutableDictionary<NSString *, NSValue *> *YTzoomMoshDeviceOriginals;

static IMP YTzoomMoshDeviceOriginal(AVCaptureDevice *device, NSString *selector) {
    @synchronized (YTzoomMoshDeviceOriginals) {
        NSString *key = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(object_getClass(device)), selector];
        return (IMP)YTzoomMoshDeviceOriginals[key].pointerValue;
    }
}

// YouTube asks for 30 fps; keep 60 when the format allows it.
static void YTzoomMoshSetFrameDuration(AVCaptureDevice *device, SEL selector, CMTime duration) {
    IMP setter = YTzoomMoshDeviceOriginal(device, NSStringFromSelector(selector));
    if (YTzoomMoshPreference(YTzoomMoshHighFrameRateKey) && YTzoomMoshSession != nil &&
        YTzoomMoshFormatSupportsRate(device.activeFormat, YTzoomMoshFrameRate)) {
        duration = CMTimeMake(1, YTzoomMoshFrameRate);
    }
    if (setter != NULL) ((void (*)(id, SEL, CMTime))setter)(device, selector, duration);
}

static void YTzoomMoshSetActiveFormat(AVCaptureDevice *device, SEL selector, AVCaptureDeviceFormat *format) {
    IMP setter = YTzoomMoshDeviceOriginal(device, NSStringFromSelector(selector));
    if (YTzoomMoshPreference(YTzoomMoshHighFrameRateKey) && YTzoomMoshSession != nil) {
        AVCaptureDeviceFormat *faster = YTzoomMoshFormatSupporting(device, format, YTzoomMoshFrameRate);
        if (faster != nil) format = faster;
    }
    if (setter != NULL) ((void (*)(id, SEL, id))setter)(device, selector, format);
}

// While 0.5x has the ultra-wide swapped in, YouTube keeps zooming its own
// camera, which isn't running; its zoom is passed on to the ultra-wide,
// relative to where YouTube's zoom stood at the swap.
static __weak AVCaptureDevice *YTzoomMoshSwappedOutDevice;
static __weak AVCaptureDevice *YTzoomMoshSwappedInDevice;
static CGFloat YTzoomMoshSwapBaseZoom = 1.0;

static BOOL YTzoomMoshRampZoom(AVCaptureDevice *device, CGFloat factor, float rate) {
    CGFloat low = MAX(1.0, device.minAvailableVideoZoomFactor);
    CGFloat high = MIN(device.activeFormat.videoMaxZoomFactor, device.maxAvailableVideoZoomFactor);
    if (high < low) return NO;
    @try {
        [device rampToVideoZoomFactor:MIN(MAX(factor, low), high) withRate:rate];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// YouTube's own zoom goes straight through, untouched: its pinch drives the
// camera directly. Only while the ultra-wide is swapped in for 0.5x is the
// same zoom also applied to the ultra-wide, since YouTube's camera isn't
// running then.
static void YTzoomMoshSetZoomFactor(AVCaptureDevice *device, SEL selector, CGFloat factor) {
    IMP setter = YTzoomMoshDeviceOriginal(device, NSStringFromSelector(selector));
    if (setter != NULL) ((void (*)(id, SEL, CGFloat))setter)(device, selector, factor);
    AVCaptureDevice *ultraWide = YTzoomMoshSwappedInDevice;
    if (!YTzoomMoshEnabled() || ultraWide == nil || device == ultraWide || device != YTzoomMoshSwappedOutDevice) return;
    IMP ultraWideSetter = YTzoomMoshDeviceOriginal(ultraWide, NSStringFromSelector(selector));
    if (ultraWideSetter == NULL || ![ultraWide lockForConfiguration:nil]) return;
    CGFloat low = MAX(1.0, ultraWide.minAvailableVideoZoomFactor);
    CGFloat high = MIN(ultraWide.activeFormat.videoMaxZoomFactor, ultraWide.maxAvailableVideoZoomFactor);
    CGFloat target = factor / MAX(YTzoomMoshSwapBaseZoom, 1.0);
    @try {
        if (high >= low) {
            ((void (*)(id, SEL, CGFloat))ultraWideSetter)(ultraWide, selector, MIN(MAX(target, low), high));
        }
    } @catch (__unused NSException *exception) {}
    [ultraWide unlockForConfiguration];
}

static void YTzoomMoshHookDeviceClass(AVCaptureDevice *device) {
    static NSMutableSet<NSString *> *hooked;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hooked = [NSMutableSet set];
        YTzoomMoshDeviceOriginals = [NSMutableDictionary dictionary];
    });
    NSString *className = NSStringFromClass(object_getClass(device));
    @synchronized (YTzoomMoshDeviceOriginals) {
        if ([hooked containsObject:className]) return;
        [hooked addObject:className];
    }
    NSDictionary<NSString *, NSValue *> *hooks = @{
        @"setActiveVideoMinFrameDuration:": [NSValue valueWithPointer:(void *)YTzoomMoshSetFrameDuration],
        @"setActiveVideoMaxFrameDuration:": [NSValue valueWithPointer:(void *)YTzoomMoshSetFrameDuration],
        @"setActiveFormat:": [NSValue valueWithPointer:(void *)YTzoomMoshSetActiveFormat],
        @"setVideoZoomFactor:": [NSValue valueWithPointer:(void *)YTzoomMoshSetZoomFactor]
    };
    [hooks enumerateKeysAndObjectsUsingBlock:^(NSString *selector, NSValue *replacement, BOOL *stop) {
        (void)stop;
        IMP original = NULL;
        if (YTzoomInstallInstanceHook(className, selector, (IMP)replacement.pointerValue, &original) &&
            original != NULL) {
            @synchronized (YTzoomMoshDeviceOriginals) {
                YTzoomMoshDeviceOriginals[[NSString stringWithFormat:@"%@|%@", className, selector]] =
                    [NSValue valueWithPointer:(void *)original];
            }
        }
    }];
}

static AVCaptureDeviceInput *YTzoomMoshVideoInput(AVCaptureSession *session) {
    for (AVCaptureInput *input in session.inputs) {
        if (![input isKindOfClass:AVCaptureDeviceInput.class]) continue;
        if ([((AVCaptureDeviceInput *)input).device hasMediaType:AVMediaTypeVideo]) return (AVCaptureDeviceInput *)input;
    }
    return nil;
}

static AVCaptureDevice *YTzoomMoshVideoDevice(AVCaptureSession *session) {
    return YTzoomMoshVideoInput(session).device;
}

static void YTzoomMoshApplySessionStabilization(AVCaptureSession *session) {
    for (AVCaptureOutput *output in session.outputs) {
        AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
        if (connection != nil) {
            YTzoomMoshApplyStabilization(connection, YTzoomMoshPreference(YTzoomMoshStabilizationKey));
        }
    }
}

// 0.5x. When YouTube already runs a virtual device that contains the
// ultra-wide, 0.5x is just zoom factor 1.0. Otherwise the session's input is
// swapped for the ultra-wide while 0.5x is on and YouTube's own input is put
// back for 1x, so YouTube's zoom, focus and flash keep driving the camera it
// knows about. Input swaps run on this queue.
typedef NS_ENUM(NSInteger, YTzoomMoshLensMode) {
    YTzoomMoshLensNone = 0,
    YTzoomMoshLensZoom,
    YTzoomMoshLensSwap
};

static dispatch_queue_t YTzoomMoshConfigQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.ytzoom.mosh.config", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

static AVCaptureDeviceInput *YTzoomMoshUltraWideInput;   // ours, while 0.5x is swapped in
static AVCaptureDeviceInput *YTzoomMoshSavedInput;       // YouTube's, while it is swapped out
static BOOL YTzoomMoshSwapping;

// Looking a camera up is slow (it asks the media server), and the controls
// refresh on the main thread, so it is done once.
static BOOL YTzoomMoshHasUltraWideCamera(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 13.0, *)) {
            available = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInUltraWideCamera
                                                           mediaType:AVMediaTypeVideo
                                                            position:AVCaptureDevicePositionBack] != nil;
        }
    });
    return available;
}

static YTzoomMoshLensMode YTzoomMoshLensModeFor(AVCaptureDevice *device) {
    if (device == nil) return YTzoomMoshLensNone;
    if (YTzoomMoshUltraWideInput != nil) return YTzoomMoshLensSwap;
    if (device.position != AVCaptureDevicePositionBack) return YTzoomMoshLensNone;
    if (YTzoomMoshWideBaseFactor(device) > 1.0) return YTzoomMoshLensZoom;
    if (@available(iOS 13.0, *)) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] &&
            YTzoomMoshHasUltraWideCamera()) {
            return YTzoomMoshLensSwap;
        }
    }
    return YTzoomMoshLensNone;
}

// Connection settings YouTube made (portrait, mirroring) are lost when the
// input changes, so they are copied over to the new connections.
static NSArray<NSDictionary *> *YTzoomMoshConnectionStates(AVCaptureSession *session) {
    NSMutableArray *states = [NSMutableArray array];
    for (AVCaptureOutput *output in session.outputs) {
        AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
        if (connection == nil) continue;
        NSMutableDictionary *state = [@{@"output": output} mutableCopy];
        if ([connection respondsToSelector:NSSelectorFromString(@"videoRotationAngle")]) {
            state[@"angle"] = [connection valueForKey:@"videoRotationAngle"];
        } else if (connection.isVideoOrientationSupported) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            state[@"orientation"] = @(connection.videoOrientation);
#pragma clang diagnostic pop
        }
        state[@"automaticMirroring"] = @(connection.automaticallyAdjustsVideoMirroring);
        state[@"mirrored"] = @(connection.isVideoMirrored);
        [states addObject:state];
    }
    return states;
}

static void YTzoomMoshRestoreConnectionStates(NSArray<NSDictionary *> *states) {
    for (NSDictionary *state in states) {
        AVCaptureConnection *connection = [(AVCaptureOutput *)state[@"output"] connectionWithMediaType:AVMediaTypeVideo];
        if (connection == nil) continue;
        @try {
            if (state[@"angle"] != nil) {
                [connection setValue:state[@"angle"] forKey:@"videoRotationAngle"];
            } else if (state[@"orientation"] != nil && connection.isVideoOrientationSupported) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                connection.videoOrientation = (AVCaptureVideoOrientation)[state[@"orientation"] integerValue];
#pragma clang diagnostic pop
            }
            connection.automaticallyAdjustsVideoMirroring = [state[@"automaticMirroring"] boolValue];
            if (!connection.automaticallyAdjustsVideoMirroring && connection.isVideoMirroringSupported) {
                connection.videoMirrored = [state[@"mirrored"] boolValue];
            }
        } @catch (__unused NSException *exception) {}
    }
}

static BOOL YTzoomMoshReplaceInput(AVCaptureSession *session, AVCaptureInput *from, AVCaptureInput *to) {
    NSArray *states = YTzoomMoshConnectionStates(session);
    YTzoomMoshSwapping = YES;
    [session beginConfiguration];
    [session removeInput:from];
    BOOL added = [session canAddInput:to];
    [session addInput:added ? to : from];
    [session commitConfiguration];
    YTzoomMoshSwapping = NO;
    YTzoomMoshRestoreConnectionStates(states);
    return added;
}

// Puts YouTube's own input back. Call on the config queue or before the session stops.
static void YTzoomMoshRestoreYouTubeInput(AVCaptureSession *session) {
    AVCaptureDeviceInput *ours = YTzoomMoshUltraWideInput;
    AVCaptureDeviceInput *theirs = YTzoomMoshSavedInput;
    YTzoomMoshUltraWideInput = nil;
    YTzoomMoshSavedInput = nil;
    YTzoomMoshSwappedInDevice = nil;
    YTzoomMoshSwappedOutDevice = nil;
    if (session == nil || ours == nil || theirs == nil) return;
    if ([session.inputs containsObject:ours]) YTzoomMoshReplaceInput(session, ours, theirs);
}

static void YTzoomMoshSetLens(AVCaptureSession *session, BOOL wide, void (^done)(BOOL ok)) {
    dispatch_async(YTzoomMoshConfigQueue(), ^{
        AVCaptureDevice *device = YTzoomMoshVideoDevice(session);
        BOOL ok = NO;
        switch (YTzoomMoshLensModeFor(device)) {
            case YTzoomMoshLensZoom: {
                CGFloat base = YTzoomMoshWideBaseFactor(device);
                if ([device lockForConfiguration:nil]) {
                    // Glide between the lenses (one doubling in a quarter second).
                    ok = YTzoomMoshRampZoom(device, wide ? 1.0 : base, 4.0f);
                    [device unlockForConfiguration];
                }
                break;
            }
            case YTzoomMoshLensSwap:
                if (wide && YTzoomMoshUltraWideInput == nil) {
                    AVCaptureDeviceInput *theirs = YTzoomMoshVideoInput(session);
                    AVCaptureDevice *ultraWide = nil;
                    if (@available(iOS 13.0, *)) {
                        ultraWide = [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInUltraWideCamera
                                                                       mediaType:AVMediaTypeVideo
                                                                        position:AVCaptureDevicePositionBack];
                    }
                    AVCaptureDeviceInput *ours = ultraWide != nil
                        ? [AVCaptureDeviceInput deviceInputWithDevice:ultraWide error:nil] : nil;
                    CGFloat theirZoom = theirs.device.videoZoomFactor;
                    if (theirs != nil && ours != nil && YTzoomMoshReplaceInput(session, theirs, ours)) {
                        YTzoomMoshSavedInput = theirs;
                        YTzoomMoshUltraWideInput = ours;
                        YTzoomMoshSwapBaseZoom = MAX(theirZoom, 1.0);
                        YTzoomMoshSwappedOutDevice = theirs.device;
                        YTzoomMoshSwappedInDevice = ultraWide;
                        YTzoomMoshHookDeviceClass(ultraWide);
                        ok = YES;
                    }
                } else if (!wide) {
                    AVCaptureDevice *theirDevice = YTzoomMoshSavedInput.device;
                    YTzoomMoshRestoreYouTubeInput(session);
                    // 1x means 1x: back to YouTube's camera unzoomed.
                    if (theirDevice != nil && [theirDevice lockForConfiguration:nil]) {
                        YTzoomMoshRampZoom(theirDevice, 1.0, 4.0f);
                        [theirDevice unlockForConfiguration];
                    }
                    ok = YES;
                } else {
                    ok = YES;
                }
                break;
            case YTzoomMoshLensNone:
                break;
        }
        AVCaptureDevice *active = YTzoomMoshVideoDevice(session);
        if (active != nil) {
            YTzoomMoshDevice = active;
            if (YTzoomMoshPreference(YTzoomMoshHighFrameRateKey)) YTzoomMoshConfigureFrameRate(active, YTzoomMoshFrameRate);
        }
        YTzoomMoshApplySessionStabilization(session);
        dispatch_async(dispatch_get_main_queue(), ^{ if (done != nil) done(ok); });
    });
}

static IMP OriginalRemoveInput;

static void YTzoomMoshRemoveInput(AVCaptureSession *session, SEL selector, AVCaptureInput *input) {
    // YouTube removing the input it thinks is running (a camera flip) while
    // the ultra-wide is swapped in: remove ours instead and forget the swap.
    if (!YTzoomMoshSwapping && input != nil && input == YTzoomMoshSavedInput && YTzoomMoshUltraWideInput != nil) {
        AVCaptureDeviceInput *ours = YTzoomMoshUltraWideInput;
        YTzoomMoshUltraWideInput = nil;
        YTzoomMoshSavedInput = nil;
        YTzoomMoshSwappedInDevice = nil;
        YTzoomMoshSwappedOutDevice = nil;
        YTzoomSetPreference(YTzoomMoshUltraWideKey, NO);
        ((void (*)(id, SEL, id))OriginalRemoveInput)(session, selector, ours);
        dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay refreshControls]; });
        return;
    }
    ((void (*)(id, SEL, id))OriginalRemoveInput)(session, selector, input);
}

static void YTzoomMoshApplyCameraSettings(AVCaptureSession *session) {
    AVCaptureDevice *device = YTzoomMoshVideoDevice(session);
    if (device == nil) return;
    YTzoomMoshDevice = device;
    YTzoomMoshHookDeviceClass(device);
    if (YTzoomMoshPreference(YTzoomMoshHighFrameRateKey) &&
        !YTzoomMoshConfigureFrameRate(device, YTzoomMoshFrameRate)) {
        YTzoomDownloadLog(@"mosh", @"60 fps not available on %@", device.localizedName);
    }
    YTzoomMoshApplySessionStabilization(session);
}

static IMP OriginalStartRunning;
static IMP OriginalStopRunning;
static IMP OriginalSetStabilization;

static BOOL YTzoomMoshSessionHasVideo(AVCaptureSession *session) {
    return YTzoomMoshVideoDevice(session) != nil;
}

static void YTzoomMoshStartRunning(AVCaptureSession *session, SEL selector) {
    ((void (*)(id, SEL))OriginalStartRunning)(session, selector);
    if (!YTzoomMoshEnabled() || !YTzoomMoshSessionHasVideo(session)) return;
    YTzoomMoshSession = session;
    // Opening the camera starts a fresh project: no reference, clips or ghost
    // from a previous recording. The camera opens at 1x, like YouTube's.
    YTzoomMoshResetProject();
    YTzoomSetPreference(YTzoomMoshUltraWideKey, NO);
    YTzoomMoshHookRecorder();
    YTzoomMoshApplyCameraSettings(session);
    dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay attachControls]; });
}

static void YTzoomMoshStopRunning(AVCaptureSession *session, SEL selector) {
    if (YTzoomMoshSession == session && YTzoomMoshUltraWideInput != nil) {
        dispatch_sync(YTzoomMoshConfigQueue(), ^{ YTzoomMoshRestoreYouTubeInput(session); });
    }
    ((void (*)(id, SEL))OriginalStopRunning)(session, selector);
    if (YTzoomMoshSession != session) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [YTzoomMoshOverlay hideGhost];
        [YTzoomMoshOverlay detachControls];
    });
}

static void YTzoomMoshSetStabilization(AVCaptureConnection *connection, SEL selector,
                                       AVCaptureVideoStabilizationMode mode) {
    // While the Moshly camera is on, stabilization follows its toggle and is
    // forced to Standard (not the laggy cinematic modes) when on, off otherwise.
    if (YTzoomMoshEnabled() && YTzoomMoshSession != nil && connection.isVideoStabilizationSupported) {
        mode = YTzoomMoshPreference(YTzoomMoshStabilizationKey)
            ? AVCaptureVideoStabilizationModeStandard : AVCaptureVideoStabilizationModeOff;
    }
    ((void (*)(id, SEL, AVCaptureVideoStabilizationMode))OriginalSetStabilization)(connection, selector, mode);
}

#pragma mark - On-camera controls

@interface YTzoomMoshControls : UIStackView
@property(nonatomic, strong) UIButton *lensButton;
@property(nonatomic, strong) UIButton *stabilizationButton;
@property(nonatomic, strong) UIButton *frameRateButton;
@property(nonatomic, strong) UIButton *moshButton;
@property(nonatomic, strong) UIButton *startOverButton;
@end

static __weak YTzoomMoshControls *YTzoomMoshCurrentControls;
static __weak UIImageView *YTzoomMoshCurrentGhost;

static UIButton *YTzoomMoshRoundButton(NSString *title, NSString *symbol, SEL action, id target) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
    button.layer.cornerRadius = 21.0;
    button.layer.masksToBounds = YES;
    button.tintColor = UIColor.whiteColor;
    button.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
    if (symbol.length != 0) {
        UIImageSymbolConfiguration *configuration =
            [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIImageSymbolWeightSemibold];
        [button setImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]
                forState:UIControlStateNormal];
    }
    if (title.length != 0) [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:target action:action forControlEvents:UIControlEventTouchUpInside];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:42.0],
        [button.heightAnchor constraintEqualToConstant:42.0]
    ]];
    return button;
}

static UIColor *YTzoomMoshOnColor(void) {
    return [UIColor colorWithRed:1.0 green:0.84 blue:0.04 alpha:1.0];
}

@implementation YTzoomMoshControls

- (instancetype)init {
    self = [super initWithFrame:CGRectZero];
    if (self != nil) {
        self.axis = UILayoutConstraintAxisVertical;
        self.spacing = 12.0;
        self.alignment = UIStackViewAlignmentCenter;
        self.accessibilityIdentifier = @"YTzoom.MoshControls";
        self.moshButton = YTzoomMoshRoundButton(nil, @"wand.and.rays", @selector(toggleMosh), self);
        self.moshButton.accessibilityLabel = YTzoomLocalized(@"Datamosh");
        [self.moshButton addGestureRecognizer:[[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(clearGhost:)]];
        self.lensButton = YTzoomMoshRoundButton(@"1×", nil, @selector(toggleLens), self);
        self.lensButton.accessibilityLabel = YTzoomLocalized(@"Lens");
        self.stabilizationButton = YTzoomMoshRoundButton(nil, @"hand.raised", @selector(toggleStabilization), self);
        self.stabilizationButton.accessibilityLabel = YTzoomLocalized(@"Stabilization");
        self.frameRateButton = YTzoomMoshRoundButton(@"60", nil, @selector(toggleFrameRate), self);
        self.frameRateButton.accessibilityLabel = YTzoomLocalized(@"Frame Rate");
        self.startOverButton = YTzoomMoshRoundButton(nil, @"arrow.counterclockwise", @selector(startOver), self);
        self.startOverButton.accessibilityLabel = YTzoomLocalized(@"Start Over");
        for (UIView *view in @[self.moshButton, self.lensButton, self.stabilizationButton,
                               self.frameRateButton, self.startOverButton]) {
            [self addArrangedSubview:view];
        }
        [self refresh];
    }
    return self;
}

- (void)refresh {
    self.lensButton.hidden = YTzoomMoshLensModeFor(YTzoomMoshDevice) == YTzoomMoshLensNone;
    BOOL wide = YTzoomFeatureEnabled(YTzoomMoshUltraWideKey);
    [self.lensButton setTitle:wide ? @".5×" : @"1×" forState:UIControlStateNormal];
    [self.lensButton setTitleColor:wide ? YTzoomMoshOnColor() : UIColor.whiteColor forState:UIControlStateNormal];
    self.stabilizationButton.tintColor = YTzoomFeatureEnabled(YTzoomMoshStabilizationKey)
        ? YTzoomMoshOnColor() : UIColor.whiteColor;
    BOOL high = YTzoomFeatureEnabled(YTzoomMoshHighFrameRateKey);
    [self.frameRateButton setTitle:high ? @"60" : @"30" forState:UIControlStateNormal];
    [self.frameRateButton setTitleColor:high ? YTzoomMoshOnColor() : UIColor.whiteColor
                               forState:UIControlStateNormal];
    self.moshButton.tintColor = YTzoomFeatureEnabled(YTzoomMoshActiveKey) ? YTzoomMoshOnColor() : UIColor.whiteColor;
}

- (void)toggleMosh {
    BOOL active = !YTzoomFeatureEnabled(YTzoomMoshActiveKey);
    YTzoomSetPreference(YTzoomMoshActiveKey, active);
    if (!active) [YTzoomMoshOverlay hideGhost];
    YTzoomShowNotice(active ? YTzoomLocalized(@"Datamosh on: the next clip moshes out of the last one.")
                            : YTzoomLocalized(@"Datamosh off: clips record normally."));
    [self refresh];
}

- (void)clearGhost:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan) return;
    [self startOver];
}

- (void)startOver {
    YTzoomMoshResetProject();
    YTzoomShowNotice(YTzoomLocalized(@"Started over. The next clip begins a fresh mosh."));
    [self refresh];
}

- (void)toggleLens {
    AVCaptureSession *session = YTzoomMoshSession;
    if (session == nil) return;
    BOOL wide = !YTzoomFeatureEnabled(YTzoomMoshUltraWideKey);
    self.lensButton.enabled = NO;
    __weak YTzoomMoshControls *weakSelf = self;
    YTzoomMoshSetLens(session, wide, ^(BOOL ok) {
        YTzoomMoshControls *controls = weakSelf;
        controls.lensButton.enabled = YES;
        if (ok) YTzoomSetPreference(YTzoomMoshUltraWideKey, wide);
        else YTzoomShowNotice(YTzoomLocalized(@"Couldn't switch lenses."));
        [controls refresh];
    });
}

- (void)toggleStabilization {
    BOOL enabled = !YTzoomFeatureEnabled(YTzoomMoshStabilizationKey);
    YTzoomSetPreference(YTzoomMoshStabilizationKey, enabled);
    AVCaptureSession *session = YTzoomMoshSession;
    AVCaptureVideoStabilizationMode applied = AVCaptureVideoStabilizationModeOff;
    for (AVCaptureOutput *output in session.outputs) {
        AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
        if (connection != nil) applied = YTzoomMoshApplyStabilization(connection, enabled);
    }
    if (enabled && applied == AVCaptureVideoStabilizationModeOff) {
        YTzoomShowNotice(YTzoomLocalized(@"This lens can't stabilize at the current frame rate."));
    } else {
        YTzoomShowNotice(enabled ? YTzoomLocalized(@"Stabilization on. It changes how the mosh moves.")
                                 : YTzoomLocalized(@"Stabilization off"));
    }
    [self refresh];
}

- (void)toggleFrameRate {
    BOOL high = !YTzoomFeatureEnabled(YTzoomMoshHighFrameRateKey);
    YTzoomSetPreference(YTzoomMoshHighFrameRateKey, high);
    AVCaptureDevice *device = YTzoomMoshDevice;
    if (device != nil) {
        if (!YTzoomMoshConfigureFrameRate(device, high ? YTzoomMoshFrameRate : 30) && high) {
            YTzoomShowNotice(YTzoomLocalized(@"This lens can't record at 60 fps."));
        }
    }
    [self refresh];
}

@end

@implementation YTzoomMoshOverlay

+ (UIViewController *)cameraController {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) window = candidate;
        }
    }
    UIViewController *controller = window.rootViewController;
    while (controller.presentedViewController != nil && !controller.presentedViewController.isBeingDismissed) {
        controller = controller.presentedViewController;
    }
    return controller;
}

// The layer drawing the camera picture in `view`: a preview layer, a Metal
// layer or a sample buffer display layer, on the view or directly under it.
+ (CALayer *)previewLayerOf:(UIView *)view {
    for (CALayer *layer in [@[view.layer] arrayByAddingObjectsFromArray:view.layer.sublayers ?: @[]]) {
        if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class] ||
            [layer isKindOfClass:NSClassFromString(@"CAMetalLayer")] ||
            [layer isKindOfClass:NSClassFromString(@"AVSampleBufferDisplayLayer")]) {
            return layer;
        }
    }
    return nil;
}

// The view showing the camera picture, covering most of the screen.
+ (UIView *)previewViewIn:(UIView *)root depth:(NSUInteger)depth {
    if (depth > 30 || root.hidden) return nil;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat area = root.bounds.size.width * root.bounds.size.height;
    if (area >= screen.size.width * screen.size.height * 0.4 && [self previewLayerOf:root] != nil) return root;
    for (UIView *child in root.subviews) {
        UIView *found = [self previewViewIn:child depth:depth + 1];
        if (found != nil) return found;
    }
    return nil;
}

static __weak UIView *YTzoomMoshCachedPreview;

// previewViewIn: walks the whole camera screen, and the controls check runs
// on the main thread twice a second; the last hit is reused while it is still
// on screen inside `root`, so the walk only runs when the screen changed.
+ (UIView *)livePreviewIn:(UIView *)root {
    UIView *cached = YTzoomMoshCachedPreview;
    if (cached != nil && cached.window != nil && [cached isDescendantOfView:root]) {
        BOOL visible = YES;
        for (UIView *view = cached; view != nil && view != root; view = view.superview) {
            if (view.hidden || view.alpha < 0.01) { visible = NO; break; }
        }
        if (visible) return cached;
    }
    UIView *found = [self previewViewIn:root depth:0];
    YTzoomMoshCachedPreview = found;
    return found;
}

+ (void)showGhost:(UIImage *)image {
    [self hideGhost];
    UIViewController *controller = [self cameraController];
    UIView *preview = [self livePreviewIn:controller.view];
    // Over the camera picture but under YouTube's controls: just above the
    // preview view if found, else low in the controller's z-order (index 1),
    // which still sits above the camera layer at the back.
    UIView *host = preview.superview ?: controller.view;
    if (host == nil) return;
    UIImageView *ghost = [[UIImageView alloc] initWithImage:image];
    ghost.contentMode = UIViewContentModeScaleAspectFill;
    ghost.clipsToBounds = YES;
    ghost.alpha = 0.0;
    ghost.userInteractionEnabled = NO;
    ghost.accessibilityIdentifier = @"YTzoom.MoshGhost";
    ghost.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *reference = preview ?: host;
    if (preview != nil) {
        [host insertSubview:ghost aboveSubview:preview];
    } else if (host.subviews.count > 0) {
        [host insertSubview:ghost atIndex:MIN((NSUInteger)1, host.subviews.count)];
    } else {
        [host addSubview:ghost];
    }
    // Lay the ghost exactly over the picture so lining it up lines up the
    // mosh: same rectangle as the layer drawing the camera (which can be a
    // sublayer smaller than its view) and the same fit that layer uses.
    CALayer *layer = preview != nil ? [self previewLayerOf:preview] : nil;
    if ([layer respondsToSelector:@selector(videoGravity)]) {
        NSString *gravity = [layer valueForKey:@"videoGravity"];
        if ([gravity isEqualToString:AVLayerVideoGravityResizeAspect]) ghost.contentMode = UIViewContentModeScaleAspectFit;
        else if ([gravity isEqualToString:AVLayerVideoGravityResize]) ghost.contentMode = UIViewContentModeScaleToFill;
    }
    if (layer != nil && layer != preview.layer) {
        ghost.translatesAutoresizingMaskIntoConstraints = YES;
        ghost.frame = [host.layer convertRect:layer.bounds fromLayer:layer];
        ghost.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [ghost.leadingAnchor constraintEqualToAnchor:reference.leadingAnchor],
            [ghost.trailingAnchor constraintEqualToAnchor:reference.trailingAnchor],
            [ghost.topAnchor constraintEqualToAnchor:reference.topAnchor],
            [ghost.bottomAnchor constraintEqualToAnchor:reference.bottomAnchor]
        ]];
    }
    YTzoomMoshCurrentGhost = ghost;
    YTzoomDownloadLog(@"mosh", @"ghost shown, preview %@ host %@",
                      preview != nil ? NSStringFromClass(preview.class) : @"nil",
                      NSStringFromClass(host.class));
    [UIView animateWithDuration:0.2 animations:^{ ghost.alpha = 0.45; }];
}

+ (void)hideGhost {
    UIImageView *ghost = YTzoomMoshCurrentGhost;
    YTzoomMoshCurrentGhost = nil;
    [ghost removeFromSuperview];
}

+ (void)attachControls {
    YTzoomMoshControls *existing = YTzoomMoshCurrentControls;
    UIViewController *controller = [self cameraController];
    if (controller.view == nil) return;
    // Only on a live-camera screen: if the top controller has no camera preview
    // (e.g. the editor or review screen is up), leave its UI alone.
    if ([self livePreviewIn:controller.view] == nil) {
        [existing removeFromSuperview];
        return;
    }
    if (existing != nil && existing.window != nil && existing.superview == controller.view) {
        [existing refresh];
        return;
    }
    [existing removeFromSuperview];
    YTzoomMoshControls *controls = [YTzoomMoshControls new];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:controls];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [controls.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-40.0]
    ]];
    YTzoomMoshCurrentControls = controls;
}

+ (void)detachControls {
    [YTzoomMoshCurrentControls removeFromSuperview];
}

+ (void)refreshControls {
    [YTzoomMoshCurrentControls refresh];
}

@end

#pragma mark - Install

void YTzoomInstallMoshCameraHooks(void) {
    YTzoomInstallInstanceHook(@"AVCaptureVideoDataOutput", @"setSampleBufferDelegate:queue:",
                              (IMP)YTzoomMoshSetSampleBufferDelegate, &OriginalSetSampleBufferDelegate);
    YTzoomInstallInstanceHook(@"AVAssetWriterInput", @"appendSampleBuffer:",
                              (IMP)YTzoomMoshAppendSampleBuffer, &OriginalAppendSampleBuffer);
    YTzoomInstallInstanceHook(@"AVAssetWriterInputPixelBufferAdaptor", @"appendPixelBuffer:withPresentationTime:",
                              (IMP)YTzoomMoshAppendPixelBuffer, &OriginalAppendPixelBuffer);
    YTzoomInstallInstanceHook(@"AVCaptureMovieFileOutput", @"startRecordingToOutputFileURL:recordingDelegate:",
                              (IMP)YTzoomMoshMovieStart, &OriginalMovieStart);
    YTzoomInstallInstanceHook(@"AVCaptureMovieFileOutput", @"stopRecording",
                              (IMP)YTzoomMoshMovieStop, &OriginalMovieStop);
    YTzoomInstallInstanceHook(@"AVCaptureSession", @"removeInput:",
                              (IMP)YTzoomMoshRemoveInput, &OriginalRemoveInput);
    YTzoomInstallInstanceHook(@"AVCaptureSession", @"startRunning",
                              (IMP)YTzoomMoshStartRunning, &OriginalStartRunning);
    YTzoomInstallInstanceHook(@"AVCaptureSession", @"stopRunning",
                              (IMP)YTzoomMoshStopRunning, &OriginalStopRunning);
    YTzoomInstallInstanceHook(@"AVCaptureConnection", @"setPreferredVideoStabilizationMode:",
                              (IMP)YTzoomMoshSetStabilization, &OriginalSetStabilization);
}
