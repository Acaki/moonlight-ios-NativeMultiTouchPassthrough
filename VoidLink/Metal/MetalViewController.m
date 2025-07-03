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

    // Initialize the app asynchronously to avoid blocking the main thread.
    dispatch_async(_dispatch_queue, ^{
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
                                                                   drawablePixelFormat:MTLPixelFormatBGRA8Unorm
                                                                             framerate:self->_framerate];
        if (!renderer)
        {
            Log(LOG_E, @"The renderer couldn't be initialized.");
            return;
        }

        // Initialize the renderer-dependent view properties.
#if !TARGET_OS_TV
        view.metalLayer.wantsExtendedDynamicRangeContent = YES;

        // XXX experimental
        view.metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
        CFStringRef name = kCGColorSpaceExtendedLinearITUR_2020;
        CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(name);
        view.metalLayer.colorspace = colorspace;


        /* The following two selectors are for static mastering display color volume and
         * content light level info - typically associated with "HDR10" content. The
         * data is treated as display referred with 1.0 mapping to diffuse white of 100
         * nits in a reference grading environment. */

        /* Initialize with SEI MDCV and CLLI as defined by ISO/IEC 23008-2:2017
         *
         * `displayData'
         * The value is 24 bytes containing a big-endian structure as defined in D.2.28
         * Mastering display colour volume SEI message. If nil, uses system defaults.
         *
         * `contentData'
         * The value is 4 bytes containing a big-endian structure as defined in D.2.35
         * Content light level information SEI message. If nil, uses system defaults.
         *
         * `scale'
         * Scale factor relating (display-referred linear) extended range buffer values
         * (such as MTLPixelFormatRGBA16Float) to optical output of a reference display.
         * Values y in the buffer are assumed to be proportional to the optical output
         * C (in cd/m^2) of a reference display; denoting the opticalOutputScale as C1
         * (cd/m^2), the relationship is C = C1 * y. As an example, if C1 = 100 cd/m^2,
         * the optical output corresponding to y = 1 is C = C1 = 100 cd/m^2, and the
         * display-referred linear value corresponding to C = 4,000 cd/m^2 is y = 40.
         * If the content, y, is in a normalized pixel format then `scale' is
         * assumed to be 10,000. */


//        + (CAEDRMetadata *)HDR10MetadataWithDisplayInfo:(nullable NSData *)displayData
//                                            contentInfo:(nullable NSData *)contentData
//                                     opticalOutputScale:(float)scale;

        // `displayData'
        // The value is 24 bytes containing a big-endian structure as defined in D.2.28
        // Mastering display colour volume SEI message. If nil, uses system defaults.
        //
        // `contentData'
        // The value is 4 bytes containing a big-endian structure as defined in D.2.35
        // Content light level information SEI message. If nil, uses system defaults.
//        CAEDRMetadata *edrMetaData = [CAEDRMetadata HDR10MetadataWithDisplayInfo:displayData
//                                                                     contentInfo:contentData
//                                                              opticalOutputScale:100.0f];

//        `minNits'
//        Minimum nits (cd/m^2) of the mastering display
//
//        `maxNits'
//        Maximum nits (cd/m^2) of the mastering display
        CAEDRMetadata *edrMetaData = [CAEDRMetadata HDR10MetadataWithMinLuminance:0.005f
                                                                     maxLuminance:1000.0f
                                                               opticalOutputScale:100.0f];
        view.metalLayer.EDRMetadata = edrMetaData;
#else
        view.metalLayer.pixelFormat = renderer.colorPixelFormat;
        view.metalLayer.colorspace = renderer.colorspace;
#endif

        self->_renderer = renderer;
    });
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
    CFTimeInterval targetPts = update.targetPresentationTimestamp;

    if (now > deadline) {
        Log(LOG_W, @"Metal renderTo was called late: missed deadline by %.3f ms", (now - deadline) * 1000.0);
    }

    Frame *frame = [_frameQueue dequeueWithTimeout:(deadline - now)];
    if (frame) {
        FQLog(LOG_I, @"Metal renderTo frame %d, CAMetalDisplayLink deadline %.3f, targetPts %.3f",
              frame.frameNumber, deadline, targetPts);
        [_renderer renderFrame:frame
                       toLayer:layer
                          with:update
                            at:deltaTime];
    }
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
