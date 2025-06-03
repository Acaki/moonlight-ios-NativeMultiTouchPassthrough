#import "FloatBuffer.h"

@implementation FloatBuffer {
    float *_buffer;  // raw C array holding up to capacity floats
    int _head;       // index of next write (0…capacity−1)
    int _count;      // how many valid entries are in the buffer (≤ capacity)
    float _minValue; // current minimum across all valid entries
    float _maxValue; // current maximum across all valid entries
    double _sum;     // running sum of all valid entries (for average)
}

@synthesize capacity = _capacity;
@synthesize count = _count;
@synthesize minValue = _minValue;
@synthesize maxValue = _maxValue;
@synthesize averageValue = _averageValue; // custom getter below

- (instancetype)init {
    return [self initWithCapacity:256]; // default = 256
}

- (instancetype)initWithCapacity:(int)capacity {
    self = [super init];
    if (self) {
        // Enforce capacity > 0 and a power of two
        if (capacity <= 0 || (capacity & (capacity - 1)) != 0) {
            @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"FloatBuffer capacity must be a nonzero power of two" userInfo:nil];
        }
        _capacity = capacity;
        _buffer = (float *)malloc(sizeof(float) * capacity);
        _head = 0;
        _count = 0;
        _minValue = 0.0f;
        _maxValue = 0.0f;
        _sum = 0.0;
    }
    return self;
}

- (void)dealloc {
    if (_buffer) {
        free(_buffer);
        _buffer = NULL;
    }
}

- (void)push:(float)value {
    @synchronized(self) {
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
}

- (float)averageValue {
    @synchronized(self) {
        return (_count > 0) ? (float)(_sum / (double)_count) : 0.0f;
    }
}

- (int)copyValuesIntoBuffer:(float *)outBuffer size:(int)outBufferSize min:(float *_Nullable)outMin max:(float *_Nullable)outMax {
    int written = 0;
    @synchronized(self) {
        if (_count == 0) {
            // Empty buffer → zero, and set min/max to zero if requested
            if (outMin)
                *outMin = 0.0f;
            if (outMax)
                *outMax = 0.0f;
            return 0;
        }

        // Compute “tail” index (oldest element)
        int tail = (_head + _capacity - _count) & (_capacity - 1);

        // 1) Copy first chunk from buffer[tail] up to either end or _count elements
        int firstChunkSize = MIN(_capacity - tail, _count);
        int toCopyFirst = MIN(firstChunkSize, outBufferSize);
        for (int i = 0; i < toCopyFirst; i++) {
            outBuffer[i] = _buffer[tail + i];
        }

        int copiedSoFar = toCopyFirst;
        // 2) If wrapped, copy remainder from index 0
        if (firstChunkSize < _count && copiedSoFar < outBufferSize) {
            int remainder = _count - firstChunkSize;
            int toCopyRem = MIN(remainder, outBufferSize - copiedSoFar);
            for (int i = 0; i < toCopyRem; i++) {
                outBuffer[copiedSoFar + i] = _buffer[i];
            }
            copiedSoFar += toCopyRem;
        }

        // We return the logical count, even if outBufferSize < _count
        written = _count;
        if (outMin)
            *outMin = _minValue;
        if (outMax)
            *outMax = _maxValue;
    }
    return written;
}

@end
