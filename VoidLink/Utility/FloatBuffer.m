#import "FloatBuffer.h"

@implementation FloatBuffer {
    float *_buffer;       // raw C array holding up to capacity floats
    int _head;            // index of next write (0…capacity−1)
    int _count;           // how many valid entries are in the buffer (≤ capacity)
    float _minValue;      // current minimum across all valid entries
    float _maxValue;      // current maximum across all valid entries
    double _sum;          // running sum of all valid entries (for average)
    dispatch_queue_t _sq; // serial queue for thread safety
}

@synthesize capacity = _capacity;
@synthesize count = _count;
@synthesize minValue = _minValue;
@synthesize maxValue = _maxValue;
@synthesize averageValue = _averageValue; // custom getter below

- (instancetype)init {
    return [self initWithCapacity:256];
}

- (instancetype)initWithCapacity:(int)capacity {
    self = [super init];
    if (self) {
        // Enforce capacity > 0 and a power of two
        if (capacity <= 0 || (capacity & (capacity - 1)) != 0) {
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"FloatBuffer capacity must be a nonzero power of two" userInfo:nil];
        }
        _capacity = capacity;
        _buffer = calloc(capacity, sizeof(float));
        _head = 0;
        _count = 0;
        _minValue = 0.0f;
        _maxValue = 0.0f;
        _sum = 0.0;

        _sq = dispatch_queue_create("com.floatbuffer.serial", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    if (_buffer) {
        free(_buffer);
        _buffer = NULL;
    }
}

- (void)addValue:(float)value {
    dispatch_sync(_sq, ^{
      [self _unsafeAddValue:value];
    });
}

- (void)_unsafeAddValue:(float)value {
    BOOL wasFull = (_count == _capacity);
    float overwrittenValue = 0.0f;
    if (wasFull) {
        // The slot at _head is about to be overwritten
        overwrittenValue = _buffer[_head];
    }

    // 1) Write the new value into the “head” slot:
    _buffer[_head] = value;
    _head = (_head + 1) & (_capacity - 1); // wrap via bitmask

    // 2) Update count / sum / min / max
    if (!wasFull) {
        // We had room to grow
        _count += 1;
        _sum += value;

        if (_count == 1) {
            // Very first element:
            _minValue = value;
            _maxValue = value;
        } else {
            // Compare to existing min/max
            if (value < _minValue)
                _minValue = value;
            if (value > _maxValue)
                _maxValue = value;
        }
    } else {
        // Buffer was full: dropped overwrittenValue, added new value
        _sum += (double)value - (double)overwrittenValue;

        // If overwrittenValue was equal to old min or max, we must rescan
        if (overwrittenValue == _minValue || overwrittenValue == _maxValue) {
            float newMin = _buffer[0];
            float newMax = _buffer[0];
            for (int i = 1; i < _capacity; i++) {
                float v = _buffer[i];
                if (v < newMin)
                    newMin = v;
                if (v > newMax)
                    newMax = v;
            }
            _minValue = newMin;
            _maxValue = newMax;
        }
        // Finally, make sure the newly written `value` updates min/max if needed
        if (value < _minValue)
            _minValue = value;
        if (value > _maxValue)
            _maxValue = value;
    }
}

- (float)averageValue {
    __block float result;
    dispatch_sync(_sq, ^{
      result = (self->_count > 0) ? (float)(self->_sum / (double)self->_count) : 0.0f;
    });
    return result;
}

- (int)copyValuesIntoBuffer:(float *)outBuffer min:(nullable float *)outMin max:(nullable float *)outMax {
    __block int result;
    dispatch_sync(_sq, ^{
      result = [self _unsafeCopyValuesIntoBuffer:outBuffer min:outMin max:outMax];
    });
    return result;
}

- (int)_unsafeCopyValuesIntoBuffer:(float *)outBuffer min:(nullable float *)outMin max:(nullable float *)outMax {
    if (_count == 0) {
        // Empty buffer → zero, and set min/max to zero if requested
        if (outMin)
            *outMin = 0.0f;
        if (outMax)
            *outMax = 0.0f;
        return 0;
    }

    // Compute "tail" index (oldest element)
    NSUInteger tail = (_head + _capacity - _count) & (_capacity - 1);

    // 1) Copy first chunk from buffer[tail] up to either end or _count elements
    NSUInteger firstChunkSize = MIN(_capacity - tail, _count);
    memcpy(outBuffer, &_buffer[tail], firstChunkSize * sizeof(float));

    NSUInteger copiedSoFar = firstChunkSize;

    // 2) If wrapped, copy remainder from index 0
    if (firstChunkSize < _count) {
        NSUInteger remainder = _count - firstChunkSize;
        memcpy(&outBuffer[copiedSoFar], _buffer, remainder * sizeof(float));
    }

    if (outMin)
        *outMin = _minValue;
    if (outMax)
        *outMax = _maxValue;

    return _count;
}

@end
