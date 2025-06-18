#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#import "FloatBuffer.h"
#import "Plot.h"

struct PlotDef {
    FloatBuffer * _Nonnull buffer;
    const char * _Nonnull title;
    PlotLabelType labelType;
    const char * _Nonnull unit;
    double scaleMin, scaleMax, scaleTarget;
    float minY;
    float maxY;
    BOOL hidden;
};

@interface ImGuiRenderer : UIViewController
@end

@interface ImGuiRenderer () <MTKViewDelegate>
@property (nonatomic) CGRect bounds;
@property (nonatomic, readonly) MTKView * _Nonnull mtkView;
@property (nonatomic, strong) id <MTLDevice> _Nonnull device;
@property (nonatomic, strong) id <MTLCommandQueue> _Nonnull commandQueue;
@property (nonatomic) struct PlotDef * _Nonnull plots;
@property (nonatomic) FloatBuffer * _Nonnull frametimes;
@property (nonatomic) BOOL enableGraphs;

-(nonnull instancetype) initWithFrame:(CGRect)bounds streamFps:(int)streamFps enableGraphs:(BOOL)enableGraphs;
-(void) observeFloat:(int)plotId value:(CFTimeInterval)value;
-(void) observeFloatReturnMetrics:(int)plotId value:(CFTimeInterval)value plotMetrics:(PlotMetrics * _Nullable)plotMetrics;
@end
