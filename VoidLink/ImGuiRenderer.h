#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

#import "FloatBuffer.h"
#import "Plot.h"

@interface ImGuiRenderer : UIViewController
@end

@interface ImGuiRenderer () <MTKViewDelegate>
@property (nonatomic) CGRect bounds;
@property (nonatomic, readonly) MTKView * _Nonnull mtkView;
@property (nonatomic, strong) id <MTLDevice> _Nonnull device;
@property (nonatomic, strong) id <MTLCommandQueue> _Nonnull commandQueue;
@property (nonatomic) struct PlotDef * _Nonnull plots;
@property (nonatomic) FloatBuffer * _Nonnull frametimes;
@property (nonatomic) int desiredQueueSize;
@property (nonatomic) float graphAreaHeight;

-(nonnull instancetype) initWithFrame:(CGRect)bounds streamFps:(int)streamFps;
-(void) observeFloat:(int)plotId value:(CFTimeInterval)value;
-(float) observeFloatReturnAvg:(int)plotId value:(CFTimeInterval)value;
-(int) getDesiredQueueSize;
@end
