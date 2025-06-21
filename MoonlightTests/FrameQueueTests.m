
#import <XCTest/XCTest.h>
#import <CoreMedia/CoreMedia.h>

#define FRAME_QUEUE_VERBOSE

#import "FrameQueue.h"
#import "Logger.h"
#include "Limelight.h"

@interface FrameQueueTests : XCTestCase
@property (nonatomic, strong) FrameQueue *queue;
@end

@implementation FrameQueueTests {
    int _frameNumber;
}

- (void)setUp {
    [super setUp];
    self.queue = [[FrameQueue alloc] init];
    _frameNumber = 0;
}

- (void)tearDown {
    [self.queue clear];
    self.queue = nil;
    [super tearDown];
}

- (CMSampleBufferRef)makeEmptySampleBufferFor:(uint32_t)tick {
    CMSampleTimingInfo sampleTiming = {
        .duration              = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake((int64_t)tick, 90000),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer = NULL;
    OSStatus status = CMSampleBufferCreate(kCFAllocatorDefault,
                                           NULL, NO, NULL, NULL, NULL,
                                           1, 1, &sampleTiming, 0, NULL,
                                           &sampleBuffer);
    XCTAssertEqual(status, noErr, @"makeEmptySampleBufferFor:%d ok", tick);
    return sampleBuffer;
}

- (Frame *)makeFrameNumber:(int)num type:(int)type pts:(uint32_t)tick {
    CMSampleBufferRef buf = [self makeEmptySampleBufferFor:tick];
    CFRetain(buf); // emulate retain that happens in CMSampleBufferCreateReadyWithImageBuffer
    Frame *frame = [[Frame alloc] initWithSampleBuffer:buf
                                           frameNumber:num
                                             frameType:type];
    if (!_frameNumber) {
        _frameNumber = num;
    }
    return frame;
}

- (Frame *)makeFrame {
    const uint32_t ONE_FRAME = 90000 / 60;
    static uint32_t tick = 0;
    Frame *frame = [self makeFrameNumber:++_frameNumber
                                    type:FRAME_TYPE_PFRAME
                                    pts:tick];
    tick += ONE_FRAME;
    return frame;
}

// Test plan:
// enqueue to max, should drop max - 2
// enqueue to max with IDR, should leave IDR
// enqueue, dequeue, enqueue, dequeueWithTimeout: should return instantly
// dequeue empty: return nil
// dequeueWithTimeout empty: wait timeout, return nil
// dequeueWithTimeout empty, enqueue: immediately return new frame
// enqueue few times: count is accurate
// enqueue + dequeue few times: count is accurate
// enqueue few times: clear removes everything
// enqueue 6x, dropWithTarget:2: should drop #2, #4
// enqueue 9x, dropWithTarget:1: should drop #2, #4, #6, #8
// dropWithTarget with callback
// dropWithTarget without callback
// dropWithTarget with callback returning false
// dropWithTarget dropMode ALL (maybe remove this)
// wantsDuration enabled
// wantsDuration disabled


- (void)testEnqueueThenDequeue {
    Frame *f1 = [self makeFrameNumber:1 type:FRAME_TYPE_IDR pts:0];
    Frame *f2 = [self makeFrame];

    [self.queue enqueue:f1];
    [self.queue enqueue:f2];
    XCTAssertEqual([self.queue count], 2);

    Frame *out1 = [self.queue dequeue];
    XCTAssertEqual(out1.frameNumber, 1);
    XCTAssertEqual([self.queue count], 1);

    Frame *out2 = [self.queue dequeue];
    XCTAssertEqual(out2.frameNumber, 2);
    XCTAssertEqual([self.queue count], 0);

    // empty now
    XCTAssertNil([self.queue dequeue]);
}

- (void)testOverflowClear {
    for (int i = 0; i < self.queue.maxCapacity; i++) {
        [self.queue enqueue:[self makeFrame]];
        XCTAssertEqual([self.queue count], i + 1);
    }

    // queue should be full, adding frames 1-16 results
    // in 1, 2, 16 being returned. XXX This is probably wrong, newest 
    [self.queue enqueue:[self makeFrame]];
    XCTAssertEqual([self.queue count], 3);
    Frame *frame = [self.queue dequeue];
    XCTAssertEqual(frame.frameNumber, 1);
    frame = [self.queue dequeue];
    XCTAssertEqual(frame.frameNumber, 2);
    frame = [self.queue dequeue];
    XCTAssertEqual(frame.frameNumber, 16);

    [self.queue clear];
    XCTAssertEqual([self.queue count], 0);
    XCTAssertNil([self.queue dequeue]);
}

- (void)testOverflowWithIDR {
    [self.queue enqueue:[self makeFrameNumber:1 type:FRAME_TYPE_IDR pts:0]];
    [self.queue enqueue:[self makeFrame]];
    [self.queue enqueue:[self makeFrameNumber:3 type:FRAME_TYPE_IDR pts:0]];

    int size = 3;
    while ([self.queue count] < self.queue.maxCapacity) {
        [self.queue enqueue:[self makeFrame]];
        XCTAssertEqual([self.queue count], size++);
    }

    // overflow
    [self.queue enqueue:[self makeFrame]];
    XCTAssert
    for (int i = 0; i < self.queue.maxCapacity; i++) {
        [self.queue enqueue:[self makeFrame]];
        XCTAssertEqual([self.queue count], i + 1);
    }
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
    Frame *f = [self makeFrame];
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

// wantsDuration enabled & disabled
- (void)testWantsDurationYes {
    [self.queue setWantsDuration:YES];

    // 1 frame in queue, cannot be dequeued yet
    [self.queue enqueue:[self makeFrame]];
    XCTAssertEqual([self.queue count], 1);
    XCTAssertNil([self.queue dequeue]);

    // 2nd frame will compute 1st frame's duration. makeFrame generates sequential frames at 60fps
    [self.queue enqueue:[self makeFrame]];
    XCTAssertEqual([self.queue count], 2);
    Frame *first = [self.queue dequeue];
    XCTAssertEqualWithAccuracy(first.duration, 1.0f / 60, 0.0001, @"first frame missing duration");

    // Try to drop the new frame that doesn't yet have a duration
    Log(LOG_I, @"%@", self.queue);
    int dropCount = [self.queue dropWithTarget:0 dropMode:DROP_ALL usingBlock:nil];
    XCTAssertEqual(dropCount, 0, @"dropWithTarget:0 should not drop lone frame when wantsDuration is true");
}

- (void)testWantsDurationNo {
    [self.queue setWantsDuration:NO];

    // 1 frame in queue, can be dequeued
    [self.queue enqueue:[self makeFrame]];
    XCTAssertEqual([self.queue count], 1);
    Frame *first = [self.queue dequeue];
    XCTAssertEqual(first.frameNumber, 1, @"Couldn't dequeue lone frame when wantsDuration=NO");

    // 2nd frame will not compute 1st frame's duration
    [self.queue enqueue:[self makeFrame]];
    [self.queue enqueue:[self makeFrame]];
    XCTAssertEqual([self.queue count], 2);
    first = [self.queue dequeue];
    XCTAssertTrue(CMTIME_IS_INVALID(first.duration90), @"first frame has a duration but shouldn't");
    XCTAssertTrue(first.duration == NAN, @"first frame has a duration but shouldn't");

    // Try to drop the new frames
    Log(LOG_I, @"%@", self.queue);
    int dropCount = [self.queue dropWithTarget:0 dropMode:DROP_ALL usingBlock:nil];
    XCTAssertEqual(dropCount, 1, @"dropWithTarget:0 wasn't able to drop all frames when wantsDuration=NO");
}

@end
