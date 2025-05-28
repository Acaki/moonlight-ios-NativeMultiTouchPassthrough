#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

@interface ImGuiRenderer : UIViewController
@end

@interface ImGuiRenderer () <MTKViewDelegate>
@property (nonatomic) CGRect bounds;
@property (nonatomic, readonly) MTKView * _Nonnull mtkView;
@property (nonatomic, strong) id <MTLDevice> _Nonnull device;
@property (nonatomic, strong) id <MTLCommandQueue> _Nonnull commandQueue;

-(nonnull instancetype)initWithFrame:(CGRect)bounds;
@end
