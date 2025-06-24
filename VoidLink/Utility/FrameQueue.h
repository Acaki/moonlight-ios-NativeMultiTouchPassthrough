#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

#import "Frame.h"

NS_ASSUME_NONNULL_BEGIN

@interface FrameQueue : NSObject

@property (nonatomic, readonly) NSUInteger count;
@property (nonatomic) NSUInteger highWaterMark;
@property (nonatomic, readonly) NSUInteger maxCapacity;

typedef void (^FrameDropCallback)(Frame *frame, NSUInteger index);

- (void)clear;
- (void)enqueue:(Frame *)frame;
- (nullable Frame *)dequeue;
- (nullable Frame *)dequeueWithTimeout:(CFTimeInterval)timeout;
- (int)dropCount;
- (CFTimeInterval)estimatedFramerate;

@end

NS_ASSUME_NONNULL_END
