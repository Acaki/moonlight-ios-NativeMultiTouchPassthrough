#import "Frame.h"

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

@implementation Frame

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType {
    self = [super init];
    if (self) {
        _frameNumber  = frameNumber;
        _frameType    = frameType;
        _sampleBuffer = sampleBuffer;

        // 90 kHz pts from RTP
        _pts90        = CMSampleBufferGetOutputPresentationTimeStamp(sampleBuffer);
        _duration90   = kCMTimeInvalid;

//        FQLog(LOG_I, @"init Frame %d - type %@ [host pts %.3f]",
//            _frameNumber, _frameType == FRAME_TYPE_IDR ? @"IDR" : @"P",
//            CMTimeGetSeconds(_pts90));
    }
    return self;
}

- (void)dealloc {
    //FQLog(LOG_I, @"[%d / %f] Frame dealloc", _frameNumber, CMTimeGetSeconds(_pts90));

    // sampleBuffer comes from CMSampleBufferCreateReadyWithImageBuffer
    // so we don't need to CFRetain in init, but do need to release it
    CFRelease(_sampleBuffer);
}

- (CFTimeInterval)pts {
    return CMTimeGetSeconds(_pts90);
}

- (CFTimeInterval)duration {
    if (CMTIME_IS_VALID(_duration90)) {
        return CMTimeGetSeconds(_duration90);
    }
    return NAN;
}

- (void)setDurationFromNext:(Frame *)nextFrame {
    if (nextFrame.frameNumber == _frameNumber + 1) {
        _duration90 = CMTimeSubtract(nextFrame.pts90, _pts90);
        _duration90.flags = kCMTimeFlags_Valid;

        FQLog(LOG_I, @"frame [%d / %.3f] set duration %.3f ms",
            _frameNumber, CMTimeGetSeconds(_pts90),
            CMTimeGetSeconds(_duration90) * 1000.0);
    }
}

- (BOOL)durationIsValid {
    return CMTIME_IS_VALID(_duration90);
}

// Debug output when using %@
- (NSString *)description {
    return [NSString stringWithFormat:@"{Frame: %d, type %@, pts90 %lld, pts %.3f ms, duration %@}",
        self.frameNumber,
        self.frameType == 1 ? @"IDR" : @"PFRAME",
        self.pts90.value,
        self.pts * 1000.0,
        [self durationIsValid] ? [ NSString stringWithFormat:@"%.3f ms", self.duration * 1000.0] : @"--"
    ];
}

@end
