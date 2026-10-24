//
//  MoshEngine.h
//  Objective-C++ wrapper around the portable datamosh core (from Moshly).
//
//  Handles CVPixelBuffer locking, row padding and the two pixel formats an
//  iPhone camera delivers: 32BGRA and 4:2:0 bi-planar YCbCr. Not thread-safe:
//  use it from the capture queue. -drop and -reset only set a flag, so they
//  are safe from any thread.
//

#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MoshEngine : NSObject

- (nullable instancetype)initWithWidth:(int)width
                                height:(int)height
                           pixelFormat:(OSType)pixelFormat NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

+ (BOOL)supportsPixelFormat:(OSType)pixelFormat;

@property(nonatomic, readonly) int width;
@property(nonatomic, readonly) int height;
@property(nonatomic, readonly) OSType pixelFormat;

/// Starts a mosh: the reference picture holds while the world moves on.
- (void)drop;
/// Ends a mosh: the reference snaps back to the live picture.
- (void)reset;

/// Splices onto a previous clip: makes `lastFrame` the reference picture and
/// drops the next keyframe, so the following frames smear that picture across
/// their motion. `lastFrame` is read, never written.
- (BOOL)seedWithPixelBuffer:(CVPixelBufferRef)lastFrame;

/// Processes a frame in place. NO (buffer untouched) if the size or format
/// doesn't match this engine.
- (BOOL)processPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@property(nonatomic, readonly) float ghostStrength;

@end

NS_ASSUME_NONNULL_END
