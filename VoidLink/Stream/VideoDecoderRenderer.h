//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;

#import "ConnectionCallbacks.h"
#import "FrameQueue.h"

#include "Limelight.h"

typedef enum {
    PACING_MODE_VSYNC,
    PACING_MODE_PTS
} FramePacingMode;

@interface VideoDecoderRenderer : NSObject

@property (atomic, readonly) CFTimeInterval displayRefreshRate;
@property (atomic, readonly) float avgDecodeTime;
@property (atomic, readonly) NSUInteger frameQueueSize;
@property (atomic, readonly) FramePacingMode framePacingMode;

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)renderFrame:(Frame *)frame atTime:(CMTime)targetTime;
- (void)cleanup;
- (void)setHdrMode:(BOOL)enabled;

- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
               decodeUnit:(PDECODE_UNIT)du
          decodeStartTime:(CFTimeInterval)decodeStartTime;

- (OSStatus)decodeFrameWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            frameNumber:(int)frameNumber
                              frameType:(int)frameType
                        decodeStartTime:(CFTimeInterval)decodeStartTime;

@end
