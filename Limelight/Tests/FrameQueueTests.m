//#import <XCTest/XCTest.h>
//#import <CoreMedia/CoreMedia.h>
//#import "FrameQueue.h"
//
//@interface FrameQueueTests : XCTestCase
//@property (nonatomic, strong) FrameQueue *queue;
//@end
//
//@implementation FrameQueueTests
//
//- (void)setUp {
//    [super setUp];
//    self.queue = [[FrameQueue alloc] init];
//}
//
//- (void)tearDown {
//    self.queue = nil;
//    [super tearDown];
//}
//
///// Helper: make an “empty” CMSampleBuffer
//- (CMSampleBufferRef)makeEmptySampleBuffer {
//    CMSampleBufferRef buf = NULL;
//    OSStatus status = CMSampleBufferCreate(
//        kCFAllocatorDefault,
//        NULL,       // no block buffer
//        NO,         // not ready callback
//        NULL, NULL, // no invalidation callback
//        NULL,       // no format description
//        0,         // zero samples
//        0, NULL,   // no timing
//        0, NULL,   // no sample size array
//        &buf
//    );
//    XCTAssertEqual(status, noErr, @"Should create empty sample buffer");
//    return buf;
//}
//
///// Helper: wrap that in a Frame
//- (Frame *)makeFrameNumber:(int)num type:(int)type {
//    CMSampleBufferRef buf = [self makeEmptySampleBuffer];
//    // balance the CFRelease in Frame.dealloc
//    CFRetain(buf);
//    Frame *f = [[Frame alloc] initWithSampleBuffer:buf
//                                        frameNumber:num
//                                          frameType:type];
//    // drop our extra retain
//    CFRelease(buf);
//    return f;
//}
//
//- (void)testEnqueueThenDequeue {
//    Frame *f1 = [self makeFrameNumber:1 type:100];
//    Frame *f2 = [self makeFrameNumber:2 type:200];
//
//    [self.queue enqueue:f1];
//    [self.queue enqueue:f2];
//    XCTAssertEqual([self.queue count], (NSUInteger)2);
//
//    Frame *out1 = [self.queue dequeue];
//    XCTAssertEqual(out1.frameNumber, 1);
//    XCTAssertEqual([self.queue count], (NSUInteger)1);
//
//    Frame *out2 = [self.queue dequeue];
//    XCTAssertEqual(out2.frameNumber, 2);
//    XCTAssertEqual([self.queue count], (NSUInteger)0);
//
//    // empty now
//    XCTAssertNil([self.queue dequeue]);
//}
//
//- (void)testPeekFrameType {
//    Frame *f = [self makeFrameNumber:42 type:999];
//    [self.queue enqueue:f];
//    XCTAssertEqual([self.queue peekFrameType], 999);
//}
//
//- (void)testClear {
//    Frame *f = [self makeFrameNumber:7 type:7];
//    [self.queue enqueue:f];
//    XCTAssertEqual([self.queue count], (NSUInteger)1);
//    [self.queue clear];
//    XCTAssertEqual([self.queue count], (NSUInteger)0);
//    XCTAssertNil([self.queue dequeue]);
//}
//
//- (void)testDropAllMode {
//    // enqueue 5 dummy frames
//    for (int i = 1; i <= 5; i++) {
//        [self.queue enqueue:[self makeFrameNumber:i type:0]];
//    }
//    XCTAssertEqual([self.queue count], (NSUInteger)5);
//
//    // drop down to 2, in DROP_ALL mode
//    int dropped = [self.queue dropWithTarget:2
//                                    dropMode:DROP_ALL];
//    XCTAssertEqual(dropped, 3);
//    XCTAssertEqual([self.queue count], (NSUInteger)2);
//
//    // the two remaining should be the last two we enqueued (4 and 5)
//    Frame *r1 = [self.queue dequeue];
//    Frame *r2 = [self.queue dequeue];
//    XCTAssertEqual(r1.frameNumber, 4);
//    XCTAssertEqual(r2.frameNumber, 5);
//}
//
//- (void)testDequeueWithTimeoutReturnsFrameIfAvailable {
//    Frame *f = [self makeFrameNumber:99 type:0];
//    [self.queue enqueue:f];
//
//    Frame *out = [self.queue dequeueWithTimeout:0.1];
//    XCTAssertNotNil(out);
//    XCTAssertEqual(out.frameNumber, 99);
//}
//
//- (void)testDequeueWithTimeoutReturnsNilWhenEmpty {
//    // zero timeout ⇒ immediate return
//    XCTAssertNil([self.queue dequeueWithTimeout:0]);
//}
//
//@end
