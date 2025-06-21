#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>

@interface Frame : NSObject
@property (nonatomic) int frameNumber;
@property (nonatomic) int frameType;
@property (nonatomic) CMTime pts90;
@property (nonatomic) CMTime duration90;
@property (nonatomic) CMSampleBufferRef sampleBuffer;

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameNumber:(int)frameNumber frameType:(int)frameType;
- (CFTimeInterval)pts;
- (CFTimeInterval)duration;
- (void)setDurationFromNext:(Frame *)nextFrame;
- (BOOL)durationIsValid;
- (void)dealloc;
@end
