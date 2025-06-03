#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A thread-safe circular buffer of `float` values (capacity must be a power of two).
/// This is a mostly automated conversion of my C++ FloatBuffer.h class to Objective-C.
@interface FloatBuffer : NSObject

/// The total capacity (always a power of two).
@property(nonatomic, readonly) int capacity;

/// The current number of valid entries (≤ capacity).
@property(nonatomic, readonly) int count;

/// The minimum value among all entries currently in the buffer.
@property(nonatomic, readonly) float minValue;

/// The maximum value among all entries currently in the buffer.
@property(nonatomic, readonly) float maxValue;

/// The arithmetic average (sum / count) of all entries. Zero if count=0.
@property (nonatomic, readonly) float averageValue;

/// Designated initializer. `capacity` must be >0 and a power of two, otherwise throws an exception.
- (instancetype)initWithCapacity:(int)capacity NS_DESIGNATED_INITIALIZER;

/// Convenience initializer: same as `initWithCapacity:`.
- (instancetype)init;

/// Adds a new float into the buffer (overwriting the oldest if full). Thread-safe.
- (void)push:(float)value;

/// Copies the buffer’s contents (oldest→newest) into `outBuffer`, which must be able to hold at least `self.count` floats.
/// Returns the number of floats written (i.e. the current `count`).
/// If non-NULL, `outMin` and `outMax` are set to the buffer’s current minimum/maximum.
- (int)copyValuesIntoBuffer:(float *)outBuffer
                       size:(int)outBufferSize
                        min:(float * _Nullable)outMin
                        max:(float * _Nullable)outMax;

@end

NS_ASSUME_NONNULL_END
