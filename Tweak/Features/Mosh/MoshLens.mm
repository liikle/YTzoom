//
//  MoshLens.mm
//  Objective-C port of Moshly's MoshlyLens.
//

#import "MoshLens.h"

AVCaptureDevice *YTzoomMoshUltraWideCapableDevice(AVCaptureDevicePosition position) {
    if (position != AVCaptureDevicePositionBack) return nil;
    NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        [types addObject:AVCaptureDeviceTypeBuiltInTripleCamera];
        [types addObject:AVCaptureDeviceTypeBuiltInDualWideCamera];
    }
    if (types.count == 0) return nil;
    NSArray<AVCaptureDevice *> *found = [AVCaptureDeviceDiscoverySession
        discoverySessionWithDeviceTypes:types mediaType:AVMediaTypeVideo position:position].devices;
    for (AVCaptureDeviceType type in types) {
        for (AVCaptureDevice *device in found) {
            if ([device.deviceType isEqualToString:type]) return device;
        }
    }
    return nil;
}

CGFloat YTzoomMoshWideBaseFactor(AVCaptureDevice *device) {
    if (@available(iOS 13.0, *)) {
        // Only a virtual device has lenses to zoom across; the ultra-wide on
        // its own (swapped in for 0.5x) is a plain camera whose 1.0 is 0.5x.
        if (!device.isVirtualDevice) return 1.0;
        // Test the constituents for a real ultra-wide: on a wide+tele pairing
        // the first switch-over is the tele crossover, which would put "1x" at 2x.
        BOOL hasUltraWide = NO;
        for (AVCaptureDevice *constituent in device.constituentDevices) {
            if ([constituent.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInUltraWideCamera]) hasUltraWide = YES;
        }
        NSNumber *first = device.virtualDeviceSwitchOverVideoZoomFactors.firstObject;
        if (hasUltraWide) return first != nil ? first.doubleValue : 2.0;
    }
    return 1.0;
}

BOOL YTzoomMoshFormatSupportsRate(AVCaptureDeviceFormat *format, int fps) {
    for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        if (fps >= range.minFrameRate - 0.01 && fps <= range.maxFrameRate + 0.01) return YES;
    }
    return NO;
}

AVCaptureDeviceFormat *YTzoomMoshFormatSupporting(AVCaptureDevice *device, AVCaptureDeviceFormat *format, int fps) {
    if (format == nil) return nil;
    if (YTzoomMoshFormatSupportsRate(format, fps)) return format;
    // Only the same size and pixel format: YouTube's pipeline is set up for
    // the frames it asked for, so a different size or a 10-bit format would
    // break it. Among matches, prefer one that isn't binned (more detail).
    CMVideoDimensions want = CMVideoFormatDescriptionGetDimensions(format.formatDescription);
    FourCharCode subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription);
    AVCaptureDeviceFormat *best = nil;
    for (AVCaptureDeviceFormat *candidate in device.formats) {
        if (!YTzoomMoshFormatSupportsRate(candidate, fps)) continue;
        CMVideoDimensions dims = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription);
        if (dims.width != want.width || dims.height != want.height) continue;
        if (CMFormatDescriptionGetMediaSubType(candidate.formatDescription) != subtype) continue;
        if (best == nil || (best.isVideoBinned && !candidate.isVideoBinned)) best = candidate;
    }
    return best;
}

BOOL YTzoomMoshConfigureFrameRate(AVCaptureDevice *device, int fps) {
    AVCaptureDeviceFormat *format = YTzoomMoshFormatSupporting(device, device.activeFormat, fps);
    if (format == nil || ![device lockForConfiguration:nil]) return NO;
    // Assigning activeFormat switches the session to inputPriority, and both
    // durations must be pinned or the camera lowers the rate in low light.
    if (format != device.activeFormat) device.activeFormat = format;
    CMTime duration = CMTimeMake(1, fps);
    device.activeVideoMinFrameDuration = duration;
    device.activeVideoMaxFrameDuration = duration;
    [device unlockForConfiguration];
    return YES;
}

AVCaptureVideoStabilizationMode YTzoomMoshApplyStabilization(AVCaptureConnection *connection, BOOL enabled) {
    if (!connection.isVideoStabilizationSupported) return AVCaptureVideoStabilizationModeOff;
    // Standard only. The cinematic modes add a lot of latency and crop, which
    // is the delay the camera showed; Standard is responsive.
    AVCaptureVideoStabilizationMode mode = AVCaptureVideoStabilizationModeOff;
    if (enabled) {
        AVCaptureDeviceFormat *format = nil;
        for (AVCaptureInputPort *port in connection.inputPorts) {
            if ([port.input isKindOfClass:AVCaptureDeviceInput.class]) {
                format = ((AVCaptureDeviceInput *)port.input).device.activeFormat;
            }
        }
        if (format == nil || [format isVideoStabilizationModeSupported:AVCaptureVideoStabilizationModeStandard]) {
            mode = AVCaptureVideoStabilizationModeStandard;
        }
    }
    connection.preferredVideoStabilizationMode = mode;
    return mode;
}
