
#import <XCTest/XCTest.h>
#import <CoreMedia/CoreMedia.h>

#define FRAME_QUEUE_VERBOSE

#import "FrameQueue.h"
#include "Limelight.h"

@interface FrameQueueTests : XCTestCase
@property (nonatomic, strong) FrameQueue *queue;
@end

@implementation FrameQueueTests

- (void)setUp {
    [super setUp];
    self.queue = [[FrameQueue alloc] init];
}

- (void)tearDown {
    self.queue = nil;
    [super tearDown];
}

/// Helper: make an “empty” CMSampleBuffer
- (CMSampleBufferRef)makeEmptySampleBuffer {
    // Set pts to the current frame's pts, in RTP 90khz units
    CMSampleTimingInfo sampleTiming = {
        .duration              = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)1500, 90000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault,
                                           NULL, NO, NULL, NULL, NULL,
                                           1, 1, &sampleTiming, 0, NULL,
                                           &sampleBuffer);
    XCTAssertEqual(status, noErr, @"Should create empty sample buffer");
    return sampleBuffer;
}

/// Helper: wrap that in a Frame
- (Frame *)makeFrameNumber:(int)num type:(int)type {
    CMSampleBufferRef buf = [self makeEmptySampleBuffer];
    // balance the CFRelease in Frame.dealloc
    CFRetain(buf);
    Frame *f = [[Frame alloc] initWithSampleBuffer:buf
                                       frameNumber:num
                                         frameType:type];
    // drop our extra retain
    CFRelease(buf);
    return f;
}

- (void)testEnqueueThenDequeue {
    Frame *f1 = [self makeFrameNumber:1 type:FRAME_TYPE_IDR];
    Frame *f2 = [self makeFrameNumber:2 type:FRAME_TYPE_PFRAME];

    [self.queue enqueue:f1];
    [self.queue enqueue:f2];
    XCTAssertEqual([self.queue count], (NSUInteger)2);

    Frame *out1 = [self.queue dequeue];
    XCTAssertEqual(out1.frameNumber, 1);
    XCTAssertEqual([self.queue count], (NSUInteger)1);

    Frame *out2 = [self.queue dequeue];
    XCTAssertEqual(out2.frameNumber, 2);
    XCTAssertEqual([self.queue count], (NSUInteger)0);

    // empty now
    XCTAssertNil([self.queue dequeue]);
}

- (void)testPeekFrameType {
    [self.queue enqueue:[self makeFrameNumber:10 type:FRAME_TYPE_IDR]];
    [self.queue enqueue:[self makeFrameNumber:11 type:FRAME_TYPE_PFRAME]];

    // peek looks at the first frame
    XCTAssertEqual([self.queue peekFrameType], FRAME_TYPE_IDR);
}

- (void)testClear {
    Frame *f = [self makeFrameNumber:20 type:FRAME_TYPE_IDR];
    [self.queue enqueue:f];
    XCTAssertEqual([self.queue count], (NSUInteger)1);
    [self.queue clear];
    XCTAssertEqual([self.queue count], (NSUInteger)0);
    XCTAssertNil([self.queue dequeue]);
}

//- (void)testDropAllMode {
//    // enqueue 5 dummy frames
//    for (int i = 1; i <= 5; i++) {
//        [self.queue enqueue:[self makeFrameNumber:i type:0]];
//    }
//    XCTAssertEqual([self.queue count], (NSUInteger)5);
//
//    // drop down to 2, in DROP_ALL mode
//    int queueCountBefore = [self.queue compact:I
//    int dropped = [self.queue dropWithTarget:2
//                                    dropMode:DROP_ALTERNATING
//                                  usingBlock:^BOOL(Frame *frame, NSUInteger queueCount) {
//        XCTAssertEqual(queueCount, queueCountBefore);
//    }];
//
//    int dropped = [self.queue dropWithTarget:2
//                                    dropMode:DROP_ALL
//                                  usingBlock:nil];
//    XCTAssertEqual(dropped, 3);
//    XCTAssertEqual([self.queue count], (NSUInteger)2);
//
//    // the two remaining should be the last two we enqueued (4 and 5)
//    Frame *r1 = [self.queue dequeue];
//    Frame *r2 = [self.queue dequeue];
//    XCTAssertEqual(r1.frameNumber, 4);
//    XCTAssertEqual(r2.frameNumber, 5);
//}

- (void)testDequeueWithTimeout {
    Frame *f = [self makeFrameNumber:30 type:FRAME_TYPE_PFRAME];
    [self.queue enqueue:f];

    Frame *out = [self.queue dequeueWithTimeout:0.1];
    XCTAssertNotNil(out);
    XCTAssertEqual(out.frameNumber, 30);

    // should return nil after waiting
    CFTimeInterval t0 = CACurrentMediaTime();
    XCTAssertNil([self.queue dequeueWithTimeout:0.2]);
    XCTAssertGreaterThan(CACurrentMediaTime() - t0, 0.2);

    // no timeout
    XCTAssertNil([self.queue dequeueWithTimeout:0]);
}

@end
