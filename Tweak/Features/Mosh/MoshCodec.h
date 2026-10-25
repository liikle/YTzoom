//
//  MoshCodec.h
//  Real H.264 datamosh, matching Moshly's Classic effect.
//
//  Runs a live VTCompressionSession and VTDecompressionSession against each
//  other and mistreats the stream between them in the three canonical ways:
//  it never emits a keyframe after the first and drops any that appear, it
//  withholds the first frame of each new clip so the decoder keeps the previous
//  clip's reference picture (the desync), and it resubmits each P-frame N times
//  so motion compounds into the stretch. Baseline + CAVLC so a desynced decoder
//  smears instead of falling apart into noise.
//
//  THREADING: created and driven from the capture queue. The VideoToolbox
//  callbacks land on their own threads; everything they touch is behind a lock.
//

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MoshCodec : NSObject

/// Fails on bad dimensions, an unsupported pixel format or session creation
/// failure. The sessions are built once and reused for the whole camera
/// session, because building a VTCompressionSession on the record tap stalls
/// the capture queue.
- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                           pixelFormat:(OSType)pixelFormat
                             frameRate:(int)frameRate NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat;

@property(nonatomic, readonly) int width;
@property(nonatomic, readonly) int height;
@property(nonatomic, readonly) OSType pixelFormat;

/// Mosh strength, 1 (clean) to 5. Drives how many times each P-frame is
/// resubmitted. Matches Moshly's Mosh intensity.
@property(nonatomic) int intensity;

/// Collapse to intensity 1 regardless of the setting, for thermal pressure.
@property(nonatomic) BOOL thermalLimited;

/// A clip is starting. `firstClip` forces a fresh baseline keyframe (clip 1
/// only); every other clip resumes against the previous clip's reference and
/// withholds its own first frame, which is what creates the mosh.
- (void)beginClipFirst:(BOOL)firstClip moshing:(BOOL)moshing;

/// A clip is ending. Drains the decoder so late pictures don't bleed into the
/// next clip; never flushes, which would reset the reference.
- (void)endClip;

/// Processes one recorded frame: encodes it, then overwrites it in place with
/// the decoder's latest output. Returns NO (buffer untouched) on a size or
/// format mismatch. While a mosh holds the decoder, the latest output is the
/// held reference, which is the effect.
- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// Anchors the stream on `pixelBuffer`, the exact last frame recorded so far
/// (an owned copy that stays unmodified). It is encoded as a deliberate
/// keyframe and becomes the written-back picture immediately, so the next
/// clip opens on precisely that frame and moshes out of it. The decoded
/// keyframe is also compared with it to correct any level shift (e.g. video
/// vs full range) in the decoder's output, so the mosh never comes out lighter
/// or darker than the frame it continues. Called at the start of every clip
/// after the first, including after a clip was deleted.
- (void)anchorToPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// How far the decoder has drifted from the encoder's input, 0 when no mosh is
/// running. Drives the ghost-hide and a UI meter.
@property(nonatomic, readonly) float ghostStrength;

@end

NS_ASSUME_NONNULL_END
