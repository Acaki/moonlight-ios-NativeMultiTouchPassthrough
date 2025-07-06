#import <QuartzCore/QuartzCore.h>
#import <QuartzCore/CAMetalLayer.h>
#import "ConnectionCallbacks.h"
#import "Frame.h"
#import "Plot.h"

@interface MetalVideoRenderer : NSObject

- (nonnull instancetype)initWithMetalDevice:(nonnull id<MTLDevice>)device
                        drawablePixelFormat:(MTLPixelFormat)drawablePixelFormat
                                  framerate:(float)framerate;

- (void)renderFrame:(nonnull Frame *)frame
            toLayer:(nonnull CAMetalLayer *)layer
               with:(CAMetalDisplayLinkUpdate *_Nonnull)update
                 at:(CFTimeInterval)deltaTime;

/// Responds to the drawable's size or orientation changes.
- (void)drawableResize:(CGSize)drawableSize;

@property (atomic) CFTimeInterval averageGPUTime;
@property (nonatomic) NSUInteger sampleCount;
@property (nonatomic) MTLPixelFormat colorPixelFormat;
@property (nonatomic, nonnull) CGColorSpaceRef colorspace;

@end
