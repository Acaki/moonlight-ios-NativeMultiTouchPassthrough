#import <VideoToolbox/VideoToolbox.h>
#import <os/lock.h>
#import <pthread.h>
#import "FrameQueue.h"

// The logging in this class is very heavy
#if !defined(NDEBUG)
# define FRAME_QUEUE_VERBOSE
#endif

static inline NSString *FQQoSString(qos_class_t qos) {
    switch (qos) {
        case QOS_CLASS_USER_INTERACTIVE: return @"UI-25";
        case QOS_CLASS_USER_INITIATED:   return @"IN-19";
        case QOS_CLASS_DEFAULT:          return @"DF-15";
        case QOS_CLASS_UTILITY:          return @"UT-11";
        case QOS_CLASS_BACKGROUND:       return @"BG-09";
        default:                         return [NSString stringWithFormat:@"??-%d", qos];
    }
}

static inline NSString *FQLogPrefix(void) {
    CFTimeInterval now = CACurrentMediaTime();
    NSString *qos = FQQoSString(qos_class_self());
    return [NSString stringWithFormat:@"[%.3f] [%@]", now, qos];
}

#if defined(FRAME_QUEUE_VERBOSE)
  #define FQLog(level, fmt, ...) \
    Log(level, @"%@ " fmt, FQLogPrefix(), ##__VA_ARGS__)
#else
  #define FQLog(level, fmt, ...) do {} while(0)
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
        _duration     = kCMTimeInvalid;

//        FQLog(LOG_I, @"init Frame %d - type %@ [host pts %.3f]",
//            _frameNumber, _frameType == FRAME_TYPE_IDR ? @"IDR" : @"P",
//            CMTimeGetSeconds(_pts90));
    }
    return self;
}

- (CFTimeInterval)pts {
    return CMTimeGetSeconds(_pts90);
}

// TODO: rethink this using better data structure
- (CMTime)maybeSetDuration:(Frame *)next {
    if (next.frameNumber == _frameNumber + 1) {
        _duration = CMTimeSubtract(next.pts90, _pts90);
        _duration.flags = kCMTimeFlags_Valid;

        FQLog(LOG_I, @"previous frame [%d / %.3f] got duration %.3f ms",
            CACurrentMediaTime(), _frameNumber, CMTimeGetSeconds(_pts90),
            CMTimeGetSeconds(_duration) * 1000.0);
    }
    return _duration;
}

- (BOOL)durationIsValid {
    return CMTIME_IS_VALID(_duration);
}

- (void)dealloc {
    //FQLog(LOG_I, @"[%d / %f] Frame dealloc", _frameNumber, CMTimeGetSeconds(_pts90));

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
        _maxCapacity      = 15;
        _desiredQueueSize = 2;
        _frameRate        = 60;
        _ptsCorrection    = CMTimeMake(0, 90000);
        _queue            = [NSMutableArray arrayWithCapacity:_maxCapacity];
        _lock             = OS_UNFAIR_LOCK_INIT;
        _semaphore        = dispatch_semaphore_create(0);
    }
    return self;
}

- (void)enqueue:(Frame *)frame {
    os_unfair_lock_lock(&_lock);
    if (_queue.count >= _maxCapacity) {
        // Emergency drop everything past 2, except IDR frames
        NSMutableIndexSet *toDrop = [[NSMutableIndexSet alloc] init];
        for (int i = 2; i < _queue.count; i++) {
            Frame *f = [_queue objectAtIndex:i];
            if (f.frameType != FRAME_TYPE_IDR) {
                [toDrop addIndex:i];
                if ([f durationIsValid]) {
                    _ptsCorrection = CMTimeAdd(_ptsCorrection, f.duration);
                }
                else {
                    // count unknowns as 1 frametime
                    _ptsCorrection = CMTimeAdd(_ptsCorrection, CMTimeMake(90000 / _frameRate, 90000));
                }
            }
        }
        [_queue removeObjectsAtIndexes:toDrop];
        Log(LOG_E, @"Error: Frame queue overflow (max %d), dropped %d frames",
            _maxCapacity, [toDrop count]);
    }

    // Try to update the previous frame's duration based on this frame's timestamp
//    Frame *prev = [_queue lastObject];
//    if (prev != nil) {
//        [prev maybeSetDuration:frame];
//    }

    [_queue addObject:frame];
    FQLog(LOG_I, @"[-> %d / %f] enqueue frame, queue size %d", frame.frameNumber, frame.pts, _queue.count);

    os_unfair_lock_unlock(&_lock);
    dispatch_semaphore_signal(_semaphore);
}

- (Frame *)dequeue {
    os_unfair_lock_lock(&_lock);
    Frame *selected = nil;
    if (_queue.count > 0) {
        selected = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        FQLog(LOG_I, @"[<- %d / %f] dequeue frame, queue size %d", selected.frameNumber, selected.pts, _queue.count);
    }
    os_unfair_lock_unlock(&_lock);
    return selected;
}

- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout {
    dispatch_time_t when;
    if (timeout <= 0.0) {
        when = DISPATCH_TIME_NOW;
    }
    else {
        when = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC));
    }

    if (dispatch_semaphore_wait(_semaphore, when) != 0) {
        FQLog(LOG_I, @"dequeueWithTimeout timed out after %.3f ms", timeout * 1000.0);
        return nil;
    }

    return [self dequeue];
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

    if (framesToDrop > 0) {
        NSMutableIndexSet *toDrop = [[NSMutableIndexSet alloc] init];

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
                // Callback receives the frame about to be dropped, its duration (calculated by loooking at the next frame's pts),
                // and the queue count before any frames have been removed. If it returns NO, no more callbacks will be sent for this batch.
                CMTime frameDuration = kCMTimeInvalid;
                if (self->_queue.count >= idx + 2) {
                    // we have access to the next frame, and can determine the duration
                    Frame *next = [self->_queue objectAtIndex:idx+1];
                    if (next.frameNumber == frame.frameNumber + 1) {
                        frameDuration = CMTimeSubtract(next.pts90, frame.pts90);
                        frameDuration.flags = kCMTimeFlags_Valid;
                    }
                }

                BOOL ok = frameDropCallback(frame, frameDuration, _queue.count);
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
