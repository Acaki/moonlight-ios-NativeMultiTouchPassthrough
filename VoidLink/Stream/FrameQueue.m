#import <VideoToolbox/VideoToolbox.h>
#import "FrameQueue.h"

@implementation Frame

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType {
    if (self = [super init]) {
        _frameNumber  = frameNumber;
        _frameType    = frameType;
        _sampleBuffer = sampleBuffer;
        _pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer));
        //Log(LOG_I, @"[%d / %f] Frame init", _frameNumber, _pts);
    }
    return self;
}

- (void)dealloc {
    //Log(LOG_I, @"[%d / %f] Frame dealloc", _frameNumber, _pts);
    CFRelease(_sampleBuffer);
}

- (NSString *)description {
    return [NSString stringWithFormat:@"{%d / %f}", self.frameNumber, self.pts];
}

@end

////

@implementation FrameQueue {
    NSMutableArray<Frame *> *_queue;
}

- (instancetype)init {
    if (self = [super init]) {
        _maxCapacity = 15;
        _desiredQueueSize = 1;
        _queue = [NSMutableArray arrayWithCapacity:_maxCapacity];
    }
    return self;
}

- (void)pushFrame:(Frame *)frame {
    @synchronized(self) {
        if (_queue.count >= _maxCapacity) {
            // Drop oldest
            Log(LOG_I, @"[x %d] queue full, dropping oldest", _queue.firstObject.frameNumber);
            [_queue removeObjectAtIndex:0];
        }
        [_queue addObject:frame];
        Log(LOG_I, @"[-> %d / %f] pushFrame, queue size %d", frame.frameNumber, frame.pts, _queue.count);
    }
}

- (Frame *)popFrame {
    @synchronized(self) {
        if (_queue.count == 0) return nil;
        Frame *selected = _queue.firstObject;
        [_queue removeObjectAtIndex:0];
        Log(LOG_I, @"[<- %d / %f] popFrame, queue size %d", selected.frameNumber, selected.pts, _queue.count);
        return selected;
    }
}

- (Frame *)popFrameForPTS:(CFTimeInterval)pts {
    @synchronized(self) {
        if (_queue.count == 0) return nil;
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
        if (selected != nil) {
            Log(LOG_I, @"[<- %d / %f] popFrameForPTS:%f, queue size %d: %@",
                selected.frameNumber, selected.pts, pts, _queue.count, self);
        }
        return selected;
    }
}

- (Frame *)popFrameForQueueSize:(int)desiredQueueSize {
    @synchronized(self) {
        if (_queue.count == 0) return nil;
        Frame *selected = nil;
        while (_queue.count > _desiredQueueSize) {
            selected = _queue.firstObject;
            [_queue removeObjectAtIndex:0];
        }
        if (selected != nil) {
            Log(LOG_I, @"[<- %d / %f] popFrameForQueueSize:%d, queue size %d: %@",
                selected.frameNumber, selected.pts, desiredQueueSize, _queue.count, self);
        }
        return selected;
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

// Debug output lists each frame in the queue's pts value
- (NSString *)description {
    @synchronized(self) {
        NSMutableArray *desc = [NSMutableArray arrayWithCapacity:_queue.count];
        for (Frame *f in _queue) {
            [desc addObject:[f description]];
        }
        return [NSString stringWithFormat:@"[%@]", [desc componentsJoinedByString:@", "]];
    }
}

@end
