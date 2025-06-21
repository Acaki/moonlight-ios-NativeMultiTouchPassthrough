#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "Frame.h"

@interface FrameQueue : NSObject

@property (nonatomic, assign) NSUInteger maxCapacity;
@property (nonatomic) NSInteger desiredQueueSize;
@property (nonatomic) int frameRate;
@property (nonatomic) int framesIn;
@property (nonatomic) CMTime ptsCorrection;
@property (nonatomic) BOOL wantsDuration;
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
- (CFTimeInterval)estimatedFramerate;
- (void)clear;

@end
