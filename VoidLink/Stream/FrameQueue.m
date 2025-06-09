#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import "FrameQueue.h"

// The logging in this class is very heavy
#if !defined(NDEBUG)
//# define FRAME_QUEUE_VERBOSE
#endif

@implementation Frame

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType {
    if (self = [super init]) {
        _frameNumber  = frameNumber;
        _frameType    = frameType;
        _sampleBuffer = sampleBuffer;
        _pts = CMTimeGetSeconds(CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer));
        //Log(LOG_I, @"[%d / %f] Frame init", _frameNumber, _pts);
    }
    return self;
}

- (void)dealloc {
    //Log(LOG_I, @"[%d / %f] Frame dealloc", _frameNumber, _pts);
    CFRelease(_sampleBuffer);
}

#ifdef FRAME_QUEUE_VERBOSE
- (NSString *)description {
    return [NSString stringWithFormat:@"{%d / %f}", self.frameNumber, self.pts];
}
#endif

@end

////

@implementation FrameQueue {
    NSMutableArray<Frame *> *_queue;
    os_unfair_lock _lock;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxCapacity = 15;
        _desiredQueueSize = 1;
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
        // Drop oldest
#ifdef FRAME_QUEUE_VERBOSE
        Log(LOG_I, @"[x %d] queue full, dropping oldest", _queue.firstObject.frameNumber);
#endif
        [_queue removeObjectAtIndex:0];
    }
    [_queue addObject:frame];
#ifdef FRAME_QUEUE_VERBOSE
    Log(LOG_I, @"[-> %d / %f] enqueue frame, queue size %d", frame.frameNumber, frame.pts, _queue.count);
#endif
    os_unfair_lock_unlock(&_lock);
    dispatch_semaphore_signal(_semaphore);
}

- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout {
    if (_queue.count == 0 && timeout > 0.0) {
        dispatch_time_t when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(self.semaphore, when) != 0) {
            // timed out
#ifdef FRAME_QUEUE_VERBOSE
            Log(LOG_I, @"[-] dequeue timed out after %f", timeout);
#endif
            return nil;
        }
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

- (Frame *)dequeueForPTS:(CFTimeInterval)pts {
    os_unfair_lock_lock(&_lock);
    Frame *selected = nil;
    while (_queue.count > _desiredQueueSize) {
        Frame *first = _queue.firstObject;
        if (first.pts <= pts) {
            selected = first;
            [_queue removeObjectAtIndex:0];
        } else {
            break; // The next frame is in the future
        }
    }
#ifdef FRAME_QUEUE_VERBOSE
    if (selected != nil) {
        Log(LOG_I, @"[<- %d / %f] dequeueForPTS:%f, queue size %d: %@",
            selected.frameNumber, selected.pts, pts, _queue.count, self);
    }
#endif
    os_unfair_lock_unlock(&_lock);
    return selected;
}

- (Frame *)dequeueForQueueSize:(int)desiredQueueSize {
    os_unfair_lock_lock(&_lock);
    Frame *selected = nil;
    while (_queue.count > desiredQueueSize) {
        selected = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
    }
#ifdef FRAME_QUEUE_VERBOSE
    if (selected != nil) {
        Log(LOG_I, @"[<- %d / %f] dequeueForQueueSize:%d, queue size %d: %@",
            selected.frameNumber, selected.pts, desiredQueueSize, _queue.count, self);
    }
#endif
    os_unfair_lock_unlock(&_lock);
    return selected;
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
