/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The implementation of the cross-platform game view controller.
*/

#import "MetalViewController.h"
#import "MetalVideoRenderer.h"
#import "FrameQueue.h"
#import "ImGuiRenderer.h"

@implementation MetalViewController
{
    /// A queue to initialize the renderer asynchronously from the main thread.
    dispatch_queue_t _dispatch_queue;
    FrameQueue *_frameQueue;
    float _framerate;
    BOOL _enableHdr;
    MetalView *_metalView;
    MetalVideoRenderer *_renderer;
    MetricsHandler _metricsHandler;
}

-(nonnull instancetype)initWithFrame:(CGRect)bounds
                           framerate:(float)framerate
                           enableHdr:(BOOL)enableHdr
                      metricsHandler:(MetricsHandler)metricsHandler
{
    self = [super init];
    if (self) {
        _bounds = bounds;
        _frameQueue = [FrameQueue sharedInstance];
        _framerate = framerate;
        _enableHdr = enableHdr;
        _metricsHandler = metricsHandler;
    }
    return self;
}

-(void)loadView
{
    self.view = [[MetalView alloc] initWithFrame:_bounds];
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    /// A queue to initialize the renderer asynchronously from the main thread.
    _dispatch_queue = dispatch_queue_create("com.moonlight.Metal", DISPATCH_QUEUE_CONCURRENT);

    __block MetalView *view = (MetalView *)self.view;
    if (!view)
    {
        Log(LOG_E, @"The view attached to MetalViewController isn't a MetalView.");
        return;
    }
    _metalView = view;
    _metalView.delegate = self;
    _metalView.framerate = _framerate;

    // Select the device to render with.
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device)
    {
        Log(LOG_E, @"Metal isn't supported on this device.");
        self.view = [[PlatformView alloc] initWithFrame:self.view.frame];
        return;
    }
    view.metalLayer.device = device;

    // Initialize the renderer.
    MetalVideoRenderer* renderer = [[MetalVideoRenderer alloc] initWithMetalDevice:device
                                                               drawablePixelFormat:MTLPixelFormatBGR10A2Unorm
                                                                         framerate:self->_framerate];
    if (!renderer)
    {
        Log(LOG_E, @"The renderer couldn't be initialized.");
        return;
    }

    // Initialize the renderer-dependent view properties.
    view.metalLayer.pixelFormat = renderer.colorPixelFormat;
    view.metalLayer.colorspace = renderer.colorspace;

    self->_renderer = renderer;
}

/// Draws the graphics frame.
- (void)renderTo:(nonnull CAMetalLayer *)layer
            with:(CAMetalDisplayLinkUpdate *_Nonnull)update
              at:(CFTimeInterval)deltaTime
{
    if (!_renderer) {
        return;
    }

    CFTimeInterval now = CACurrentMediaTime();
    CFTimeInterval deadline = update.targetTimestamp;

    CFTimeInterval timeout = deadline - now - _renderer.averageGPUTime;
    Log(LOG_I, @"_renderer.averageGPUTime: %.3f ms", _renderer.averageGPUTime * 1000.0);
    if (now > deadline || timeout < 0.0f) {
        Log(LOG_W, @"Metal renderTo was called late: missed deadline by %.3f ms", (now - deadline) * 1000.0);
        timeout = 0.0f;
    }

    Frame *frame = [_frameQueue dequeueWithTimeout:timeout];
    if (frame) {
        [_renderer renderFrame:frame
                       toLayer:layer
                          with:update
                            at:deltaTime];
    }
}

- (void)drawableResize:(CGSize)size {
    [_renderer drawableResize:size];
}


#if TARGET_OS_IOS
/// Hides the Home indicator button automatically.
- (BOOL)prefersHomeIndicatorAutoHidden
{
    return YES;
}
#endif

#if TARGET_OS_OSX
/// Makes the view controller the first responder to receive keyboard events.
- (void)viewDidAppear
{
    [_metalView.window makeFirstResponder:self];
}

/// Receives the keydown events to avoid system beeps.
///
/// The `GameInputKeyboardMouse` class handles keyboard events.
- (void)keyDown:(NSEvent *)event
{
    // Reference the parameter to avoid an unused parameter warning.
    (void)(event);
}

/// Receives the keyup events to avoid system beeps.
///
/// The `GameInputKeyboardMouse` class handles keyboard events.
- (void)keyUp:(NSEvent *)event
{
    // Reference the parameter to avoid an unused parameter warning.
    (void)(event);
}
#endif

@end
