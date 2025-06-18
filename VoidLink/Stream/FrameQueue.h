#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#include "Limelight.h"

@interface Frame : NSObject
@property (nonatomic) int frameNumber;
@property (nonatomic) int frameType;
@property (nonatomic) CMTime pts90;
@property (nonatomic) CMTime duration;
@property (nonatomic) CMSampleBufferRef sampleBuffer;

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType;
- (CFTimeInterval)pts;
- (CMTime)maybeSetDuration:(Frame *)nextFrame;
- (BOOL)durationIsValid;
- (void)dealloc;
@end

@interface FrameQueue : NSObject

@property (nonatomic, assign) NSUInteger maxCapacity;
@property (nonatomic) NSInteger desiredQueueSize;
@property (nonatomic) int frameRate;
@property (nonatomic) CMTime ptsCorrection;
@property (nonatomic) dispatch_semaphore_t semaphore;

typedef enum {
    DROP_ALTERNATING,
    DROP_ALL
} FrameQueueDropMode;

typedef BOOL (^FrameDropCallback)(Frame *frame, CMTime frameDuration, NSUInteger index);

- (void)enqueue:(Frame *)frame;
- (int)peekFrameType;
- (Frame *)dequeue;
- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout;
- (int)dropWithTarget:(int)frameDropTarget
             dropMode:(FrameQueueDropMode)dropMode
           usingBlock:(FrameDropCallback)block;
- (NSUInteger)count;
- (void)clear;

@end
