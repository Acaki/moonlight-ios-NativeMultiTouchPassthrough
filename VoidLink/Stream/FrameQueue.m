#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import "FrameQueue.h"

// The logging in this class is very heavy
#if !defined(NDEBUG)
//# define FRAME_QUEUE_VERBOSE
#endif

#pragma mark Frame

@implementation Frame

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType {
    if (self = [super init]) {
        _frameNumber  = frameNumber;
        _frameType    = frameType;
        _sampleBuffer = sampleBuffer;

        // 90 kHz pts from RTP
        _pts90        = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);

#ifdef FRAME_QUEUE_VERBOSE
        Log(LOG_D, @"[%d / %f] Frame init, pts90 %d", _frameNumber, CMTimeGetSeconds(_pts90), _pts90.value);
#endif
    }
    return self;
}

- (CFTimeInterval)pts {
    return CMTimeGetSeconds(_pts90);
}

- (void)dealloc {
#ifdef FRAME_QUEUE_VERBOSE
    Log(LOG_I, @"[%d / %f] Frame dealloc", _frameNumber, CMTimeGetSeconds(_pts90));
#endif
    // sampleBuffer comes from CMSampleBufferCreateReadyWithImageBuffer
    // so we don't need to CFRetain in init, but do need to release it
    CFRelease(_sampleBuffer);
}

#ifdef FRAME_QUEUE_VERBOSE
- (NSString *)description {
    return [NSString stringWithFormat:@"{%d / %f}", self.frameNumber, self.pts];
}
#endif

@end

#pragma mark FrameQueue

@implementation FrameQueue {
    NSMutableArray<Frame *> *_queue;
    os_unfair_lock _lock;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxCapacity = 15;
        _desiredQueueSize = 2;
        _queue = [NSMutableArray arrayWithCapacity:_maxCapacity];
        _lock = OS_UNFAIR_LOCK_INIT;
        // start with count = 0, so waits will block
        _semaphore = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)enqueue:(Frame *)frame {
    os_unfair_lock_lock(&_lock);
    if (_queue.count >= _maxCapacity) {
        // Emergency drop everything past 2, except IDR frames
        NSMutableIndexSet *toDrop = [[NSMutableIndexSet alloc] init];
        for (int i = 2; i < _queue.count; i++) {
            if ([_queue objectAtIndex:i].frameType != FRAME_TYPE_IDR) {
                [toDrop addIndex:i];
            }
        }
        [_queue removeObjectsAtIndexes:toDrop];
        Log(LOG_E, @"Error: Frame queue overflow (max %d), dropped %d frames",
            _maxCapacity, [toDrop count]);
    }
    [_queue addObject:frame];
#ifdef FRAME_QUEUE_VERBOSE
    Log(LOG_I, @"[-> %d / %f] enqueue frame, queue size %d", frame.frameNumber, frame.pts, _queue.count);
#endif
    os_unfair_lock_unlock(&_lock);
    dispatch_semaphore_signal(_semaphore);
}

- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout {
    Frame *frame = [self dequeue];
    if (frame || timeout <= 0.0) {
        return frame;
    }

    dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(self.semaphore, when) != 0) {
        // timed out
#ifdef FRAME_QUEUE_VERBOSE
        Log(LOG_I, @"[-] dequeueWithTimeout timed out after %.3f ms", timeout * 1000.0);
#endif
        return nil;
    }

    return [self dequeue];
}

- (Frame *)dequeue {
    os_unfair_lock_lock(&_lock);
    Frame *selected = nil;
    if (_queue.count > 0) {
        selected = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
#ifdef FRAME_QUEUE_VERBOSE
        Log(LOG_I, @"[<- %d / %f] dequeue frame, queue size %d", selected.frameNumber, selected.pts, _queue.count);
#endif
    }
    os_unfair_lock_unlock(&_lock);
    return selected;
}

- (Frame *)dequeueAtIndex:(NSUInteger)index {
    os_unfair_lock_lock(&_lock);
    Frame *selected = nil;
    if (_queue.count > index) {
        selected = [_queue objectAtIndex:index];
        [_queue removeObjectAtIndex:index];
#ifdef FRAME_QUEUE_VERBOSE
        Log(LOG_I, @"[<- %d / %f] dequeueAtIndex:%d, queue size %d", selected.frameNumber, selected.pts, index, _queue.count);
#endif
    }
    os_unfair_lock_unlock(&_lock);
    return selected;
}

- (int)peekFrameType {
    int ret = -1;
    os_unfair_lock_lock(&_lock);
    if (_queue.count > 0) {
        ret = _queue.firstObject.frameType;
    }
    os_unfair_lock_unlock(&_lock);
    return ret;
}

// Catch up if the queue is too large, but drop every other frame instead of multiple consecutive frames
- (int)dropWithTarget:(int)frameDropTarget
             dropMode:(FrameQueueDropMode)dropMode
           usingBlock:(FrameDropCallback)frameDropCallback {
    os_unfair_lock_lock(&_lock);
    int framesToDrop = (int)_queue.count - frameDropTarget;
    bool shouldDrop = YES;
    int dropCount = 0;
    NSMutableIndexSet *toDrop = [[NSMutableIndexSet alloc] init];

    if (framesToDrop > 0) {
        for (int i = 0; i < framesToDrop; i++) {
            // Never drop IDR frames
            if ([_queue objectAtIndex:i].frameType == FRAME_TYPE_IDR)
                break;

            if (dropMode == DROP_ALTERNATING && !shouldDrop) {
                // spare this frame but drop the next
                shouldDrop = YES;
                continue;
            }

            // Drop the frame, either because of DROP_ALL or shouldDrop.
            // It is ok to drop any non-IDR frame in the queue because
            // the decoder has already decoded it.
            [toDrop addIndex:i];

            if (dropMode == DROP_ALTERNATING) {
                shouldDrop = NO;
            }
        }
        // Callback with each frame before removal, for stats purposes
        if (frameDropCallback) {
            [_queue enumerateObjectsAtIndexes:toDrop
                                      options:0
                                   usingBlock:^(Frame *frame, NSUInteger idx, BOOL *stop) {
                // Callback receives the frame about to be dropped, and the queue count before any frames have been removed.
                // If it returns NO, no more callbacks will be sent for this batch.
                BOOL ok = frameDropCallback([_queue objectAtIndex:idx], _queue.count);
                if (!ok) {
                    *stop = YES;
                }
            }];
        }

        [_queue removeObjectsAtIndexes:toDrop];
        dropCount = (int)[toDrop count];
    }

    os_unfair_lock_unlock(&_lock);
    return dropCount;
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger c = _queue.count;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    [_queue removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

#ifdef FRAME_QUEUE_VERBOSE
// Debug output lists each frame in the queue's pts value
- (NSString *)description {
    NSMutableArray *desc = [NSMutableArray arrayWithCapacity:_queue.count];
    for (Frame *f in _queue) {
        [desc addObject:[f description]];
    }
    return [NSString stringWithFormat:@"[%@]", [desc componentsJoinedByString:@", "]];
}
#endif

@end
