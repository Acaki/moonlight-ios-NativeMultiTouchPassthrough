#import <Metal/Metal.h>
#import "MetalVideoRenderer.h"
#import "MetalView.h"
#import "FrameQueue.h"
#import "ImGuiRenderer.h"

#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#define PlatformViewController UIViewController
#else
#import <AppKit/AppKit.h>
#define PlatformViewController NSViewController
#endif

typedef enum {
    RENDER_METAL = 0,
    RENDER_AVSB
} RenderingBackend;

@interface MetalViewController : PlatformViewController <MetalViewDelegate>

@property (nonatomic) CGRect bounds;

-(nonnull instancetype)initWithFrame:(CGRect)bounds
                           framerate:(float)framerate
                           enableHdr:(BOOL)enableHdr
                      metricsHandler:(MetricsHandler _Nonnull )metricsHandler;

@end
