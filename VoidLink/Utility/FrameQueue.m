@import AVFoundation;
@import VideoToolbox;

#import <os/lock.h>
#import <Limelight.h>
#import "Logger.h"
#import "FloatBuffer.h"
#import "FrameQueue.h"

@implementation FrameQueue {
    NSMutableArray<id> *_buffer;
    int _capacity;
    int _head;
    int _tail;
    int _count;

    BOOL _droppedLast;
    int _framesIn;
    CMTime _ptsCorrection;
    os_unfair_lock _lock;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _droppedLast      = NO;
        _frameDropMetrics = [[FloatBuffer alloc] initWithCapacity:512];
        _framesIn         = 0;
        _highWaterMark    = 2;
        _maxCapacity      = 15;
        _ptsCorrection    = CMTimeMake(0, 90000);
        _lock             = OS_UNFAIR_LOCK_INIT;

	    // ring buffer
	    _capacity = (int)_maxCapacity;
        _buffer = [NSMutableArray arrayWithCapacity:_capacity];
        for (int i = 0; i < _capacity; i++) {
            [_buffer addObject:[NSNull null]];
        }
        _head = _tail = _count = 0;

        // ping estimatedFramerate to set initial last value
        [self estimatedFramerate];
    }
	return self;
}

// Push into buffer at _tail
- (void)_pushFrame:(Frame *)frame {
    [_buffer replaceObjectAtIndex:_tail withObject:frame];
    _tail = (_tail + 1) % _capacity;
    _count++;
	FQLog(LOG_I, @"[-> %@ %d / %f] enqueue frame, queue size %d / %d",
		frame.frameType == FRAME_TYPE_IDR ? @"IDR" : @"P",
		frame.frameNumber, frame.pts, _count, _highWaterMark);
}

// Pop oldest frame from _head
- (Frame *)_popFrame {
    id obj = _buffer[_head];
    Frame *frame = (obj == [NSNull null] ? nil : obj);
    [_buffer replaceObjectAtIndex:_head withObject:[NSNull null]];
    _head = (_head + 1) % _capacity;
    _count--;
    return frame;
}

// Peek next frame (without removing)
- (Frame *)_peekFrame {
    id frame = (_count > 0) ? _buffer[_head] : nil;
    return (frame == [NSNull null]) ? nil : frame;
}

// enumerate in‐buffer frames
- (void)_enumerateFrames:(void(^)(Frame *frame, NSUInteger idx, BOOL *stop))block {
    BOOL stop = NO;
    for (int i = 0; i < _count; i++) {
        int idx = (_head + i) % _capacity;
        block([_buffer objectAtIndex:idx], i, &stop);
        if (stop) break;
    }
}

- (void)_noteDroppedFrame:(Frame *)frame {
    if ([frame durationIsValid]) {
        _ptsCorrection = CMTimeAdd(_ptsCorrection, frame.duration90);
		FQLog(LOG_W, @"dropped frame %d with duration %.3f ms", frame.frameNumber, frame.duration * 1000.0);
    } else {
		// count unknowns as 1 avg frametime
        CFTimeInterval fps = (_framesIn > 1000) ? [self _unsafeEstimatedFramerate] : 0.0f;
        CMTime oneFrame = (_framesIn > 1000) ? CMTimeMake((int)(90000.0f / fps), 90000) : kCMTimeZero;
        _ptsCorrection = CMTimeAdd(_ptsCorrection, oneFrame);
        FQLog(LOG_W, @"dropped frame %d with unknown duration, using %.3f ms (%.1f fps) instead",
            frame.frameNumber, CMTimeGetSeconds(oneFrame) * 1000.0, fps);
    }
}

- (int)enqueue:(Frame *)frame {
    os_unfair_lock_lock(&_lock);
    int dropCount = 0;

    // Always accept IDR frames, allow exceeding HWM
    if (frame.frameType == FRAME_TYPE_IDR || _count < _highWaterMark) {
        [self _pushFrame:frame];
        _droppedLast = NO;
    } else {
        if (!_droppedLast) {
			// alternate between: drop newest...
            [self _noteDroppedFrame:frame];
            dropCount = 1;
            _droppedLast = YES;
        } else {
            // and: drop oldest & enqueue new
            if ([self _peekFrame].frameType != FRAME_TYPE_IDR) {
				Frame *oldest = [self _popFrame];
                [oldest setDurationFromNext:[self _peekFrame]];
                [self _noteDroppedFrame:oldest];
                dropCount = 1;
            }
            [self _pushFrame:frame];
            _droppedLast = NO;
        }
    }
	// regardless of drop status, every enqueue is a frame
    // for estimatedFramerate purposes
    _framesIn++;
    [_frameDropMetrics addValue:(float)dropCount];
    os_unfair_lock_unlock(&_lock);
    return dropCount;
}

- (Frame *)dequeue {
    os_unfair_lock_lock(&_lock);
    Frame *frame = nil;
    if (_count > 0) {
        frame = [self _popFrame];
        // compute duration from next
        Frame *next = [self _peekFrame];
        if (next) {
			[frame setDurationFromNext:next];
		}
		FQLog(LOG_I, @"[<- %d / %f%@] dequeue frame, queue size %d",
			frame.frameNumber, frame.pts,
			[frame durationIsValid] ? [NSString stringWithFormat:@" dur %.3f ms", frame.duration * 1000.0] : @"",
			_count);
    }
    os_unfair_lock_unlock(&_lock);
    return frame;
}

- (Frame *)dequeueWithTimeout:(CFTimeInterval)timeout {
    CFTimeInterval start = CACurrentMediaTime();
    CFTimeInterval deadline = start + timeout;
    int round = 0;

    // Always attempt to dequeue at least once
    do {
        if (round > 0) {
            usleep(100); // 0.1ms
        }
        Frame *frame = [self dequeue];
        if (frame) {
            return frame;
        }
        round++;
    } while (CACurrentMediaTime() < deadline);

    FQLog(LOG_I, @"dequeueWithTimeout timed out after %.3f ms", (CACurrentMediaTime() - start) * 1000.0);
    return nil;
}

- (NSUInteger)count {
    os_unfair_lock_lock(&_lock);
    NSUInteger c = _count;
    os_unfair_lock_unlock(&_lock);
    return c;
}

- (void)clear {
    os_unfair_lock_lock(&_lock);
    _head = _tail = _count = 0;
    os_unfair_lock_unlock(&_lock);
}

- (CFTimeInterval)_unsafeEstimatedFramerate {
    static CFTimeInterval lastTime = 0;
    static int lastFrames = 0;
    static CFTimeInterval estimate = 0;

    CFTimeInterval now = CACurrentMediaTime();
    if (now - lastTime > 1.0) {
        estimate = (_framesIn - lastFrames) / (now - lastTime);
		FQLog(LOG_I, @"fps calc using framesIn %d - lastFrames %d / now %f - lastTime %f = %.1f fps",
		              _framesIn, lastFrames, now, lastTime, estimate);
        lastTime   = now;
        lastFrames = _framesIn;
    }
    return estimate;
}

- (CFTimeInterval)estimatedFramerate {
    os_unfair_lock_lock(&_lock);
    CFTimeInterval fps = [self _unsafeEstimatedFramerate];
    os_unfair_lock_unlock(&_lock);
    return fps;
}

// For use with NSLog("%@", franeQueue);
- (NSString *)description {
    __block NSMutableArray *parts = [NSMutableArray arrayWithCapacity:_count];
    [self _enumerateFrames:^(Frame *frame, NSUInteger idx, BOOL *stop) {
        [parts addObject:[frame description]];
    }];
    return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@",\n"]];
}

@end
