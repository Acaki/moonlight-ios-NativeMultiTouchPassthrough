#import "FrameBuffer.h"

@implementation Frame

- (instancetype)init {
    self = [self initWithHandle:nil];
    return self;
}

- (instancetype)initWithHandle:(VIDEO_FRAME_HANDLE)handle {
    if (handle == nil) {
        @throw [NSException exceptionWithName:NSInvalidArgumentException
                                       reason:@"initWithHandle requires a VIDEO_FRAME_HANDLE"
                                     userInfo:nil];
    }
    if (self = [super init]) {
        PDECODE_UNIT du = (DECODE_UNIT *)handle;
        _handle = handle;
        _pts = du->presentationTimeUs / 1000000.0;
    }
    return self;
}

- (PDECODE_UNIT)du {
    return (DECODE_UNIT *)_handle;
}

- (void)markComplete {
    return LiCompleteVideoFrame(self.handle, DR_OK);
}

@end

////

@implementation FrameBuffer {
    NSMutableArray<Frame *> *_queue;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxCapacity = 16;
        _queue = [NSMutableArray arrayWithCapacity:_maxCapacity];
    }
    return self;
}

- (void)pushFrame:(Frame *)frame {
    @synchronized(self) {
        if (_queue.count >= _maxCapacity) {
            // Drop oldest
            [_queue removeObjectAtIndex:0];
        }
        [_queue addObject:frame];
    }
}

- (Frame *)popFrame {
    @synchronized(self) {
        if (_queue.count == 0) return nil;
        Frame *selected = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        return selected;
    }
}

- (Frame *)popFrameForPTS:(CFTimeInterval)pts {
    @synchronized(self) {
        if (_queue.count == 0) return nil;
        Frame *selected = nil;
        while (_queue.count > 0) {
            Frame *first = _queue.firstObject;
            if (first.pts <= pts) {
                selected = first;
                [_queue removeObjectAtIndex:0];
                // XXX when to cleanup dropped frames?
            } else {
                break; // The next frame is for the future
            }
        }
        return selected;
    }
}

- (Frame *)peekNextFrame {
    @synchronized(self) {
        return _queue.firstObject;
    }
}

- (NSUInteger)count {
    @synchronized(self) {
        return _queue.count;
    }
}

- (void)clear {
    @synchronized(self) {
        [_queue removeAllObjects];
    }
}

@end
