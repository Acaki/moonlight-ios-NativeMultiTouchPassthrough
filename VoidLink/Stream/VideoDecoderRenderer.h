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
#import "Plot.h"

#include "Limelight.h"

@interface VideoDecoderRenderer : NSObject

@property (atomic, readonly) CFTimeInterval displayRefreshRate;
@property (atomic, readonly) PlotMetrics decodeMetrics;
@property (atomic, readonly) PlotMetrics frameDropMetrics;
@property (atomic, readonly) PlotMetrics frameQueueMetrics;
@property (atomic, readonly) FramePacingMode framePacingMode;
@property (atomic, readonly) CMTime ptsCorrection;

- (id)initWithView:(UIView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio;

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate;
- (void)renderFrame:(Frame *)frame atTime:(CMTime)targetTime;
- (void)cleanup;
- (void)setHdrMode:(BOOL)enabled;
- (void)getAllStats:(video_stats_t *)stats;

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
