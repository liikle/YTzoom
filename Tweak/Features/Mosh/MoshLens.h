//
//  MoshLens.h
//  Objective-C port of Moshly's MoshlyLens: 0.5x ultra-wide, stabilization
//  and 60 fps on a capture device someone else's session already owns.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Best back camera for 0.5x: a virtual device that includes the ultra-wide,
/// so the system switches lenses itself. nil when there is no such device.
FOUNDATION_EXPORT AVCaptureDevice *_Nullable YTzoomMoshUltraWideCapableDevice(AVCaptureDevicePosition position);

/// videoZoomFactor that is a user-facing "1x" on this device: the first
/// switch-over factor on a virtual device that contains the ultra-wide, else 1.
FOUNDATION_EXPORT CGFloat YTzoomMoshWideBaseFactor(AVCaptureDevice *device);

/// Picks a format of the same size and pixel format that can sustain `fps` and pins both frame
/// durations to it. NO when the device can't (the ultra-wide and 10-bit HDR
/// formats often top out at 30), in which case nothing is changed.
FOUNDATION_EXPORT BOOL YTzoomMoshConfigureFrameRate(AVCaptureDevice *device, int fps);

/// A format with the same size and pixel format as `format` that supports
/// `fps`, or nil.
FOUNDATION_EXPORT AVCaptureDeviceFormat *_Nullable YTzoomMoshFormatSupporting(AVCaptureDevice *device,
                                                                              AVCaptureDeviceFormat *format,
                                                                              int fps);

FOUNDATION_EXPORT BOOL YTzoomMoshFormatSupportsRate(AVCaptureDeviceFormat *format, int fps);

/// Strongest stabilization the connection accepts, stepping down
/// cinematicExtended → cinematic → standard → off. Returns the mode applied.
FOUNDATION_EXPORT AVCaptureVideoStabilizationMode YTzoomMoshApplyStabilization(AVCaptureConnection *connection,
                                                                               BOOL enabled);

NS_ASSUME_NONNULL_END
