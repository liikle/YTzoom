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
static CVPixelBufferRef YTzoomMoshReanchorFrame;   // owned; the frame to re-anchor onto
static BOOL YTzoomMoshReanchorPending;
static BOOL YTzoomMoshWasRecording;
static BOOL YTzoomMoshMoshing;
// Set when the camera (re)opens or the user starts over; the capture queue tears
// down the codec and clip state on the next frame so nothing from the previous
// project bleeds in. Guarded by the lock.
static BOOL YTzoomMoshResetPending;
static CVPixelBufferRef YTzoomMoshLatestFrame;   // retained, newest recorded frame
// Last frame of every clip recorded so far, newest last, so deleting the last
// clip in YouTube brings back the frame of the one before it. Guarded by the lock.
static NSMutableArray *YTzoomMoshClipFrames;
static CFTimeInterval YTzoomMoshClipFrameTime;

static void YTzoomMoshNoteLiveAppend(CMTime time) {
    (void)time;
    // Any video append counts as recording. (An earlier host-clock gate meant
    // to exclude editor exports also rejected real recording, because YouTube,
    // like Moshly, timestamps its writer from a counter near zero rather than
    // the host clock.) The recorder hooks below are preferred when present and
    // avoid treating an export as a clip.
    os_unfair_lock_lock(&YTzoomMoshLock);
    BOOL first = YTzoomMoshLastLiveAppend == 0.0;
    YTzoomMoshLastLiveAppend = CACurrentMediaTime();
    os_unfair_lock_unlock(&YTzoomMoshLock);
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

static CVPixelBufferRef YTzoomMoshCopyLastClipFrame(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    id last = YTzoomMoshClipFrames.lastObject;
    BOOL fresh = CACurrentMediaTime() - YTzoomMoshClipFrameTime < YTzoomMoshClipLifetime;
    CVPixelBufferRef frame = last != nil && fresh ? CVPixelBufferRetain((__bridge CVPixelBufferRef)last) : NULL;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    return frame;
}

static void YTzoomMoshPushClipFrame(CVPixelBufferRef frame) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    if (YTzoomMoshClipFrames == nil) YTzoomMoshClipFrames = [NSMutableArray array];
    if (CACurrentMediaTime() - YTzoomMoshClipFrameTime >= YTzoomMoshClipLifetime) {
        [YTzoomMoshClipFrames removeAllObjects];
    }
    [YTzoomMoshClipFrames addObject:(__bridge id)frame];
    while (YTzoomMoshClipFrames.count > 30) [YTzoomMoshClipFrames removeObjectAtIndex:0];
    YTzoomMoshClipFrameTime = CACurrentMediaTime();
    os_unfair_lock_unlock(&YTzoomMoshLock);
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
    CVPixelBufferLockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferLockBaseAddress(copy, 0);
    if (CVPixelBufferIsPlanar(source)) {
        for (size_t plane = 0; plane < CVPixelBufferGetPlaneCount(source); plane++) {
            const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(source, plane);
            uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(copy, plane);
            size_t fromStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane);
            size_t toStride = CVPixelBufferGetBytesPerRowOfPlane(copy, plane);
            size_t rows = CVPixelBufferGetHeightOfPlane(source, plane);
            size_t length = MIN(fromStride, toStride);
            for (size_t row = 0; row < rows; row++) memcpy(to + row * toStride, from + row * fromStride, length);
        }
    } else {
        const uint8_t *from = (const uint8_t *)CVPixelBufferGetBaseAddress(source);
        uint8_t *to = (uint8_t *)CVPixelBufferGetBaseAddress(copy);
        size_t fromStride = CVPixelBufferGetBytesPerRow(source);
        size_t toStride = CVPixelBufferGetBytesPerRow(copy);
        size_t length = MIN(fromStride, toStride);
        for (size_t row = 0; row < CVPixelBufferGetHeight(source); row++) {
            memcpy(to + row * toStride, from + row * fromStride, length);
        }
    }
    CVPixelBufferUnlockBaseAddress(copy, 0);
    CVPixelBufferUnlockBaseAddress(source, kCVPixelBufferLock_ReadOnly);
    return copy;
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
    os_unfair_lock_lock(&YTzoomMoshLock);
    BOOL doReset = YTzoomMoshResetPending;
    YTzoomMoshResetPending = NO;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    if (doReset) {
        YTzoomMoshCodecInstance = nil;
        if (YTzoomMoshLatestFrame != NULL) { CVPixelBufferRelease(YTzoomMoshLatestFrame); YTzoomMoshLatestFrame = NULL; }
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
        // If a clip was deleted, feed the frame that now ends the project back
        // as a deliberate keyframe before this clip, so it moshes out of that
        // rather than out of the deleted footage.
        if (YTzoomMoshReanchorPending && codec != nil && YTzoomMoshProjectStarted) {
            if (YTzoomMoshReanchorFrame != NULL) [codec reanchorWithPixelBuffer:YTzoomMoshReanchorFrame];
            YTzoomMoshReanchorPending = NO;
        }
        BOOL firstClip = !YTzoomMoshProjectStarted;
        BOOL moshing = codec != nil && !firstClip && YTzoomMoshPreference(YTzoomMoshActiveKey);
        YTzoomMoshMoshing = moshing;
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
        static int logCounter;
        if ((logCounter++ % 30) == 0) {
            YTzoomDownloadLog(@"mosh", @"recording mosh %d wroteDecoded %d ghost %.1f",
                              YTzoomMoshMoshing, wrote, YTzoomMoshCodecInstance.ghostStrength);
        }
        if (YTzoomMoshLatestFrame != frame) {
            if (YTzoomMoshLatestFrame != NULL) CVPixelBufferRelease(YTzoomMoshLatestFrame);
            YTzoomMoshLatestFrame = CVPixelBufferRetain(frame);
        }
    } else if (!recording && YTzoomMoshWasRecording) {
        // Clip end: drain the decoder and keep this clip's last frame for the
        // ghost overlay and for re-anchoring if it is later deleted.
        [YTzoomMoshCodecInstance endClip];
        YTzoomMoshProjectStarted = YES;
        CVPixelBufferRef last = YTzoomMoshCopyPixelBuffer(YTzoomMoshLatestFrame);
        if (YTzoomMoshLatestFrame != NULL) CVPixelBufferRelease(YTzoomMoshLatestFrame);
        YTzoomMoshLatestFrame = NULL;
        if (last != NULL) {
            YTzoomMoshPushClipFrame(last);
            YTzoomDownloadLog(@"mosh", @"clip end, kept last frame");
            if (YTzoomMoshPreference(YTzoomMoshGhostKey)) {
                UIImage *ghost = YTzoomMoshGhostImage(last, position);
                if (ghost != nil) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay showGhost:ghost]; });
                }
            }
            CVPixelBufferRelease(last);
        }
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
    [YTzoomMoshClipFrames removeAllObjects];
    if (YTzoomMoshReanchorFrame != NULL) { CVPixelBufferRelease(YTzoomMoshReanchorFrame); YTzoomMoshReanchorFrame = NULL; }
    YTzoomMoshReanchorPending = NO;
    YTzoomMoshProjectStarted = NO;
    YTzoomMoshRecorderRecording = NO;
    YTzoomMoshMovieRecording = NO;
    YTzoomMoshLastLiveAppend = 0.0;
    YTzoomMoshResetPending = YES;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    dispatch_async(dispatch_get_main_queue(), ^{ [YTzoomMoshOverlay hideGhost]; });
}


// YouTube deleted its last clip: re-anchor onto the clip before it so the next
// clip moshes out of that, and show its ghost.
static void YTzoomMoshDropLastClip(void) {
    os_unfair_lock_lock(&YTzoomMoshLock);
    if (YTzoomMoshClipFrames.count != 0) [YTzoomMoshClipFrames removeLastObject];
    BOOL empty = YTzoomMoshClipFrames.count == 0;
    os_unfair_lock_unlock(&YTzoomMoshLock);
    CVPixelBufferRef previous = YTzoomMoshCopyLastClipFrame();
    os_unfair_lock_lock(&YTzoomMoshLock);
    if (YTzoomMoshReanchorFrame != NULL) CVPixelBufferRelease(YTzoomMoshReanchorFrame);
    YTzoomMoshReanchorFrame = previous != NULL ? CVPixelBufferRetain(previous) : NULL;
    YTzoomMoshReanchorPending = previous != NULL;
    if (empty) YTzoomMoshProjectStarted = NO;   // nothing left: next clip is clip 1
    os_unfair_lock_unlock(&YTzoomMoshLock);
    UIImage *ghost = previous != NULL && YTzoomMoshPreference(YTzoomMoshGhostKey)
        ? YTzoomMoshGhostImage(previous, YTzoomMoshDevice.position) : nil;
    if (previous != NULL) CVPixelBufferRelease(previous);
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
        YTzoomMoshNoteLiveAppend(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
    }
    return ((BOOL (*)(id, SEL, CMSampleBufferRef))OriginalAppendSampleBuffer)(input, selector, sampleBuffer);
}

static BOOL YTzoomMoshAppendPixelBuffer(id adaptor, SEL selector, CVPixelBufferRef pixelBuffer, CMTime time) {
    YTzoomMoshNoteLiveAppend(time);
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
        @"setActiveFormat:": [NSValue valueWithPointer:(void *)YTzoomMoshSetActiveFormat]
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

static YTzoomMoshLensMode YTzoomMoshLensModeFor(AVCaptureDevice *device) {
    if (device == nil || device.position != AVCaptureDevicePositionBack) return YTzoomMoshLensNone;
    if (YTzoomMoshWideBaseFactor(device) > 1.0) return YTzoomMoshLensZoom;
    if (YTzoomMoshUltraWideInput != nil) return YTzoomMoshLensSwap;
    if (@available(iOS 13.0, *)) {
        if ([device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInWideAngleCamera] &&
            [AVCaptureDevice defaultDeviceWithDeviceType:AVCaptureDeviceTypeBuiltInUltraWideCamera
                                               mediaType:AVMediaTypeVideo
                                                position:AVCaptureDevicePositionBack] != nil) {
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
                    CGFloat target = wide ? 1.0 : base;
                    device.videoZoomFactor = MIN(MAX(target, device.minAvailableVideoZoomFactor),
                                                 device.maxAvailableVideoZoomFactor);
                    [device unlockForConfiguration];
                    ok = YES;
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
                    if (theirs != nil && ours != nil && YTzoomMoshReplaceInput(session, theirs, ours)) {
                        YTzoomMoshSavedInput = theirs;
                        YTzoomMoshUltraWideInput = ours;
                        YTzoomMoshHookDeviceClass(ultraWide);
                        ok = YES;
                    }
                } else if (!wide) {
                    YTzoomMoshRestoreYouTubeInput(session);
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
    self.lensButton.hidden = YTzoomMoshLensModeFor(YTzoomMoshVideoDevice(YTzoomMoshSession)) == YTzoomMoshLensNone;
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

// The view showing the camera picture: a preview layer, a Metal layer or a
// sample buffer display layer covering most of the screen.
+ (UIView *)previewViewIn:(UIView *)root depth:(NSUInteger)depth {
    if (depth > 30 || root.hidden) return nil;
    CGRect screen = UIScreen.mainScreen.bounds;
    CGFloat area = root.bounds.size.width * root.bounds.size.height;
    if (area >= screen.size.width * screen.size.height * 0.4) {
        for (CALayer *layer in [@[root.layer] arrayByAddingObjectsFromArray:root.layer.sublayers ?: @[]]) {
            if ([layer isKindOfClass:AVCaptureVideoPreviewLayer.class] ||
                [layer isKindOfClass:NSClassFromString(@"CAMetalLayer")] ||
                [layer isKindOfClass:NSClassFromString(@"AVSampleBufferDisplayLayer")]) {
                return root;
            }
        }
    }
    for (UIView *child in root.subviews) {
        UIView *found = [self previewViewIn:child depth:depth + 1];
        if (found != nil) return found;
    }
    return nil;
}

+ (void)showGhost:(UIImage *)image {
    [self hideGhost];
    UIViewController *controller = [self cameraController];
    UIView *preview = [self previewViewIn:controller.view depth:0];
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
    [NSLayoutConstraint activateConstraints:@[
        [ghost.leadingAnchor constraintEqualToAnchor:reference.leadingAnchor],
        [ghost.trailingAnchor constraintEqualToAnchor:reference.trailingAnchor],
        [ghost.topAnchor constraintEqualToAnchor:reference.topAnchor],
        [ghost.bottomAnchor constraintEqualToAnchor:reference.bottomAnchor]
    ]];
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
    if ([self previewViewIn:controller.view depth:0] == nil) {
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
