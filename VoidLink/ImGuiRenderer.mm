#import "ImGuiRenderer.h"
#import <Metal/Metal.h>

#import "imgui.h"
#import "imgui_impl_metal.h"
//#import "implot.h"

// ImGui code needs to live in this file because it's an Objective-C++ class, and can call C++ code.

@implementation ImGuiRenderer

-(nonnull instancetype)initWithFrame:(CGRect)bounds;
{
    self = [super init];

    _bounds = bounds;
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    //ImPlot::CreateContext();
    (void)ImGui::GetIO();

    ImGui::StyleColorsDark();

    ImGui_ImplMetal_Init(_device);

    // Graphs init
    _graphAreaHeight = 200.0f;
    const int graphs = PlotCount;
    _plots = (PlotDef *)malloc(sizeof(PlotDef) * graphs);

    _plots[PLOT_FRAMETIME] = {
        .title  = "Frametime",
        .unit   = "ms",
        .scaleTarget = 1000.0 / self.mtkView.preferredFramesPerSecond,
        .buffer = [[FloatBuffer alloc] initWithCapacity:512] // 4.3s @ 120hz
    };

    _plots[PLOT_DRIFT] = {
        .title  = "Drift",
        .unit   = "ms",
        .buffer = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_DISPLAYLINK] = {
        .title  = "DisplayLink interval",
        .unit   = "ms",
        .scaleTarget = 1000.0 / self.mtkView.preferredFramesPerSecond,
        .buffer = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_LI_WAIT_TIME] = {
        .title  = "LiWait time",
        .unit   = "us",
        .buffer = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _desiredQueueSize = 1;

    return self;
}

-(MTKView *)mtkView
{
    return (MTKView *)self.view;
}

-(void)loadView
{
    self.view = [[MTKView alloc] initWithFrame:self.bounds];
}

-(void)viewDidLoad
{
    [super viewDidLoad];

    self.mtkView.device = self.device;
    self.mtkView.delegate = self;
    self.mtkView.preferredFramesPerSecond = 60; // ImGui overlay will always render at this rate
    self.mtkView.opaque = NO;
    self.mtkView.enableSetNeedsDisplay = NO;
}

- (void)drawInMTKView:(MTKView *)view
{
    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize.x = view.bounds.size.width;
    io.DisplaySize.y = view.bounds.size.height;

    CGFloat framebufferScale = view.window.screen.scale ?: UIScreen.mainScreen.scale;
    io.DisplayFramebufferScale = ImVec2(framebufferScale, framebufferScale);

    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

    MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;
    if (renderPassDescriptor == nil) {
        [commandBuffer commit];
        return;
    }

    // Start the Dear ImGui frame
    ImGui_ImplMetal_NewFrame(renderPassDescriptor);
    ImGui::NewFrame();

    // Our state (make them static = more or less global) as a convenience to keep the example terse.
    static bool show_demo_window = false;
    static ImVec4 clear_color = ImVec4(0, 0, 0, 0);

    // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
    if (show_demo_window) {
        ImGui::ShowDemoWindow(&show_demo_window);
    }

    // Custom Moonlight stuff goes here
    [self drawStatsGraphs];

    // Rendering
    ImGui::Render();
    ImDrawData* draw_data = ImGui::GetDrawData();

    // This looks silly when clear_color is all zeros but the original example uses this method to tint or make transparent the rest of the viewport
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(clear_color.x * clear_color.w, clear_color.y * clear_color.w, clear_color.z * clear_color.w, clear_color.w);

    id <MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder pushDebugGroup:@"Dear ImGui rendering"];
    ImGui_ImplMetal_RenderDrawData(draw_data, commandBuffer, renderEncoder);
    [renderEncoder popDebugGroup];
    [renderEncoder endEncoding];

    // Present
    [commandBuffer presentDrawable:view.currentDrawable afterMinimumDuration:1.0 / view.preferredFramesPerSecond];
    [commandBuffer commit];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];

    ImGui_ImplMetal_Shutdown();
    //ImPlot::DestroyContext();
    ImGui::DestroyContext();
}

//-----------------------------------------------------------------------------------
// Input processing
//-----------------------------------------------------------------------------------

// This touch mapping is super cheesy/hacky. We treat any touch on the screen
// as if it were a depressed left mouse button, and we don't bother handling
// multitouch correctly at all. This causes the "cursor" to behave very erratically
// when there are multiple active touches. But for demo purposes, single-touch
// interaction actually works surprisingly well.
-(void)updateIOWithTouchEvent:(UIEvent *)event
{
    UITouch *anyTouch = event.allTouches.anyObject;
    CGPoint touchLocation = [anyTouch locationInView:self.view];
    ImGuiIO &io = ImGui::GetIO();
    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
    io.AddMousePosEvent(touchLocation.x, touchLocation.y);

    BOOL hasActiveTouch = NO;
    for (UITouch *touch in event.allTouches)
    {
        if (touch.phase != UITouchPhaseEnded && touch.phase != UITouchPhaseCancelled)
        {
            hasActiveTouch = YES;
            break;
        }
    }
    io.AddMouseButtonEvent(0, hasActiveTouch);
}

-(void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event  { [self updateIOWithTouchEvent:event]; }
-(void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }

/// Stats Graphs

- (void) observeFloat:(int)plotId value:(CFTimeInterval)value {
    [self.plots[plotId].buffer addValue:(float)value];
}

- (int) getDesiredQueueSize {
    return self.desiredQueueSize;
}

- (void) drawStatsGraphs {
    const int graphs = PlotCount;

    // we malloc a buffer for frametimes once and reuse it
    static float * buffers[4] = {
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512)
    };

    ImGuiIO &io = ImGui::GetIO();
    ImVec2 windowSize(450.0f, _graphAreaHeight); // 450x100 works for iPad, other devices will need tweaks
    ImVec2 windowPos(io.DisplaySize.x - 10.0f, 10.0f);    // 10px margin
    ImGui::SetNextWindowPos(windowPos, ImGuiCond_Always, ImVec2(1.0f, 0.0f));  // pivot (1,0) = top-right
    ImGui::SetNextWindowSize(windowSize, ImGuiCond_Always);
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoNavFocus |
                             ImGuiWindowFlags_NoBackground;
    ImGui::Begin("##Stats", nullptr, flags);

    // Figure out how tall each sub‐plot should be, with spacing
    int modules = graphs + 1;
    float spacing = ImGui::GetStyle().ItemSpacing.y;
    ImVec2 avail  = ImGui::GetContentRegionAvail();
    float plotH   = (avail.y - (modules - 1) * spacing) / modules;
    float fullW   = avail.x;

    for (int i = 0; i < graphs; ++i) {
        float minY, maxY;
        int countF = [self.plots[i].buffer copyValuesIntoBuffer:buffers[i] min:&minY max:&maxY];
        float avgF = [self.plots[i].buffer averageValue];

        // Ugly, but can't get ImPlot to build for iOS
        char label[64];
        sprintf(label, "%s  %.1f/%.1f/%.1f %s", self.plots[i].title, minY, maxY, avgF, self.plots[i].unit);
        float scaleMin = FLT_MAX;
        float scaleMax = FLT_MAX;
        if (self.plots[i].scaleTarget) {
            // optionally center the graph on a target such as the ideal frametime
            float ideal = (float)self.plots[i].scaleTarget;
            scaleMin = ideal - (2 * ideal);
            scaleMax = ideal + (2 * ideal);
        }
        ImGui::PlotLines("##xx", buffers[i], countF, 0, (countF > 0 ? label : "no data"), scaleMin, scaleMax, ImVec2(fullW, plotH));
    }

    static int dqs = self.desiredQueueSize;
    ImGui::SliderInt("Frame queue size", &dqs, 0, 10);
    if (dqs != self.desiredQueueSize) {
        self.desiredQueueSize = dqs;
    }

    ImGui::End();
}

@end
