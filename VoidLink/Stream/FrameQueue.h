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
@property (nonatomic) dispatch_semaphore_t semaphore;

- (void)enqueue:(Frame *)frame;
- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout;
- (Frame *)dequeue;
- (Frame *)dequeueForPTS:(CFTimeInterval)targetPTS;
- (Frame *)dequeueForQueueSize:(int)desiredQueueSize;
- (NSUInteger)count;
- (void)clear;

@end
