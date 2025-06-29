#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "Frame.h"
#import "FloatBuffer.h"

NS_ASSUME_NONNULL_BEGIN

@interface FrameQueue : NSObject

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic) FloatBuffer *frameDropMetrics;
@property (nonatomic) NSUInteger highWaterMark;
@property (nonatomic, readonly) NSUInteger maxCapacity;

- (void)clear;
- (int)enqueue:(Frame *)frame;
- (nullable Frame *)dequeue;
- (nullable Frame *)dequeueWithTimeout:(CFTimeInterval)timeout;
- (CFTimeInterval)estimatedFramerate;

@end

NS_ASSUME_NONNULL_END
