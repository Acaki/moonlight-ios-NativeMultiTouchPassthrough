#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CAMetalDisplayLink.h>
#import <Metal/Metal.h>
#import "MetalConfig.h"

#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#define PlatformView UIView
#else
#import <AppKit/AppKit.h>
#define PlatformView NSView
#endif

// The protocol to provide resize and redraw callbacks to a delegate.
@protocol MetalViewDelegate <NSObject>

- (void)renderTo:(nonnull CAMetalLayer *)metalLayer
            with:(CAMetalDisplayLinkUpdate *_Nonnull)update
              at:(CFTimeInterval)deltaTime;

@end

// The Metal game view base class.
@interface MetalView : PlatformView <CALayerDelegate, CAMetalDisplayLinkDelegate>

@property(nonatomic, nonnull, readonly) CAMetalLayer *metalLayer;

@property(nonatomic, getter=isPaused) BOOL paused;

@property(nonatomic, nullable) id<MetalViewDelegate> delegate;

@property (nonatomic) float framerate;

- (void)initCommon;

#if AUTOMATICALLY_RESIZE
- (void)resizeDrawable:(CGFloat)scaleFactor;
#endif

- (void)stopRenderLoop;

- (void)renderUpdate:(CAMetalDisplayLinkUpdate *_Nonnull)update
                with:(CFTimeInterval)deltaTime;

@end
