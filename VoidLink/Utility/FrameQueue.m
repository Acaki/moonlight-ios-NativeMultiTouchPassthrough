@import AVFoundation;
@import VideoToolbox;

#import <objc/runtime.h>  // for objc_retain/objc_release
#import <os/lock.h>
#import <Limelight.h>
#import "Logger.h"
#import "FrameQueue.h"

// The logging in this class is very heavy
#if !defined(NDEBUG)
//# define FRAME_QUEUE_VERBOSE
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

@implementation FrameQueue {
    __unsafe_unretained Frame **_buffer;
    int         _capacity;
    int         _head;
    int         _tail;
    int         _count;

    int         _arrivals;
    int         _drops;
    BOOL        _droppedLast;
    int         _dropCount;
    int         _tempHWM;
    int         _framesIn;
    CMTime      _ptsCorrection;
    os_unfair_lock _lock;
    dispatch_semaphore_t _semaphore;
}

static int const MAX_HWM = 5;
static int const WINDOW_SIZE = 1200;

- (instancetype)init {
    self = [super init];
    if (self) {
        _arrivals         = 0;
        _drops            = 0;
        _droppedLast      = NO;
        _dropCount        = 0;
        _framesIn         = 0;
        _highWaterMark    = 2;
        _tempHWM          = -1;
        _maxCapacity      = 15;
        _ptsCorrection    = CMTimeMake(0, 90000);
        _lock             = OS_UNFAIR_LOCK_INIT;
        _semaphore        = dispatch_semaphore_create(0);

	    // ring buffer
	    _capacity = (int)_maxCapacity;
        _buffer   = (__unsafe_unretained Frame **)calloc(_capacity, sizeof(Frame *));
        _head = _tail = _count = 0;

        // ping estimatedFramerate to set initial last value
        [self estimatedFramerate];
    }
	return self;
}

- (void)dealloc {
    // in case there are still frames in the buffer
    while (_count--) {
        CFRelease((__bridge CFTypeRef)_buffer[_head]);
        _head = (_head + 1) % _capacity;
    }
    free(_buffer);
}

- (BOOL)_hasRoom {
    return _count < _tempHWM;
}

// Push into buffer at _tail
- (void)_pushFrame:(Frame *)frame {
    CFRetain((__bridge CFTypeRef)frame);
    _buffer[_tail] = frame;
    _tail = (_tail + 1) % _capacity;
    _count++;
	FQLog(LOG_I, @"[-> %@ %d / %f] enqueue frame, queue size %d / %d",
		frame.frameType == FRAME_TYPE_IDR ? @"IDR" : @"P",
		frame.frameNumber, frame.pts, _count, _highWaterMark);
    dispatch_semaphore_signal(_semaphore);
}

// Pop oldest frame from _head
- (Frame *)_popFrame {
    Frame *frame = _buffer[_head];
    _buffer[_head] = nil;
    _head = (_head + 1) % _capacity;
    _count--;
    CFRelease((__bridge CFTypeRef)frame);
    return frame;
}

// Peek next frame (without removing)
- (Frame *)_peekFrame {
    return _count > 0 ? _buffer[_head] : nil;
}

// enumerate in‐buffer frames
- (void)_enumerateFrames:(void(^)(Frame *frame, NSUInteger idx, BOOL *stop))block {
    BOOL stop = NO;
    for (int i = 0; i < _count; i++) {
        int idx = (_head + i) % _capacity;
        block(_buffer[idx], i, &stop);
        if (stop) break;
    }
}

- (void)_noteDroppedFrame:(Frame *)frame {
    _dropCount++;
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

- (void)enqueue:(Frame *)frame {
    os_unfair_lock_lock(&_lock);

    if (_tempHWM < 0) {
		// user setting is _highWaterMark, only adjust _tempHWM
        _tempHWM = (int)_highWaterMark;
    }

    // allow a bit of flex in buffer size
    _arrivals++;
    if (_arrivals >= WINDOW_SIZE) {
        double dropRatio = (double)_drops / _arrivals;
        if (dropRatio > 0.10 && _tempHWM < MAX_HWM) {
            _tempHWM++;
			Log(LOG_W, @"FrameQueue increasing high water mark to %d (dropRatio: %.2f)", _tempHWM, dropRatio);
        } else if (dropRatio < 0.02 && _tempHWM > _highWaterMark) {
            _tempHWM--;
			Log(LOG_W, @"FrameQueue decreasing high water mark to %d (dropRatio: %.2f)", _tempHWM, dropRatio);
        }
        _arrivals = _drops = 0;
    }

    // Always accept IDR frames, allow exceeding HWM
    if (frame.frameType == FRAME_TYPE_IDR || [self _hasRoom]) {
        [self _pushFrame:frame];
        _droppedLast = NO;
    } else {
        if (!_droppedLast) {
			// alternate between: drop newest...
            [self _noteDroppedFrame:frame];
            _drops++;
            _droppedLast = YES;
        } else {
            // and: drop oldest & enqueue new
            if ([self _peekFrame].frameType != FRAME_TYPE_IDR) {
				Frame *oldest = [self _popFrame];
                [oldest setDurationFromNext:[self _peekFrame]];
                [self _noteDroppedFrame:oldest];
                _drops++;
            }
            [self _pushFrame:frame];
            _droppedLast = NO;
        }
    }
	// regardless of drop status, every enqueue is a frame
    // for estimatedFramerate purposes
    _framesIn++;
    os_unfair_lock_unlock(&_lock);
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
    dispatch_time_t when = timeout > 0
      ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))
      : DISPATCH_TIME_NOW;

    if (dispatch_semaphore_wait(_semaphore, when) != 0) {
		FQLog(LOG_I, @"dequeueWithTimeout timed out after %.3f ms", timeout * 1000.0);
        return nil;
    }
    return [self dequeue];
}

// Number of frames dropped since the last time this was called
- (int)dropCount {
    os_unfair_lock_lock(&_lock);
    int c = _dropCount;
    _dropCount = 0;
    os_unfair_lock_unlock(&_lock);
    return c;
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

// For use with NSog("%@", franeQueue);
- (NSString *)description {
    __block NSMutableArray *parts = [NSMutableArray arrayWithCapacity:_count];
    [self _enumerateFrames:^(Frame *frame, NSUInteger idx, BOOL *stop) {
        [parts addObject:[frame description]];
    }];
    return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@",\n"]];
}

@end
