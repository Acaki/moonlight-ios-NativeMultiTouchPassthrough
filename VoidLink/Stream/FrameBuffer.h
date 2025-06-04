#import <Foundation/Foundation.h>

#include "Limelight.h"

@interface Frame : NSObject
@property (nonatomic, assign) CFTimeInterval pts;
@property (nonatomic) VIDEO_FRAME_HANDLE handle;

- (instancetype)initWithHandle:(VIDEO_FRAME_HANDLE)handle NS_DESIGNATED_INITIALIZER;
- (PDECODE_UNIT)du;
- (void)markComplete;
@end

@interface FrameBuffer : NSObject

@property (nonatomic, assign) NSUInteger maxCapacity;

- (void)pushFrame:(Frame *)frame;
- (Frame *)popFrame;
- (Frame *)popFrameForPTS:(CFTimeInterval)targetPTS;
- (Frame *)peekNextFrame;
- (NSUInteger)count;
- (void)clear;

@end
