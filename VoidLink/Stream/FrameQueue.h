#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "Limelight.h"

@interface Frame : NSObject
@property (nonatomic) int frameNumber;
@property (nonatomic) int frameType;
@property (nonatomic) CFTimeInterval pts;
@property (nonatomic) CMSampleBufferRef sampleBuffer;

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType;
- (void)dealloc;
@end

@interface FrameQueue : NSObject

@property (nonatomic, assign) NSUInteger maxCapacity;
@property (nonatomic) int desiredQueueSize;

- (void)pushFrame:(Frame *)frame;
- (Frame *)popFrame;
- (Frame *)popFrameForPTS:(CFTimeInterval)targetPTS;
- (Frame *)popFrameForQueueSize:(int)desiredQueueSize;
- (NSUInteger)count;
- (void)clear;

@end
