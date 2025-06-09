#import <Foundation/Foundation.h>

@interface IntQueue : NSObject <NSFastEnumeration>

@property (nonatomic, strong, readonly) NSMutableArray<NSNumber*> *queue;

- (void)enqueue:(int)value;
- (int)dequeue;
- (NSUInteger)count;

@end

@implementation IntQueue

- (instancetype)init {
    if (self = [super init]) {
        _queue = [NSMutableArray array];
    }
    return self;
}

- (void)enqueue:(int)value {
    [self.queue addObject:@(value)];
}

- (int)dequeue {
    if (self.queue.count == 0) return 0;
    NSNumber *n = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    return n.intValue;
}

- (NSUInteger)count {
    return self.queue.count;
}

// NSFastEnumeration support
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(__unsafe_unretained id [])buffer
                                    count:(NSUInteger)len
{
    return [self.queue countByEnumeratingWithState:state
                                           objects:buffer
                                             count:len];
}

@end
