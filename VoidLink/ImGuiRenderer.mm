#import "ImGuiRenderer.h"
#import "Logger.h"
#import <Metal/Metal.h>

// Comment out to enable ImGui
//#define IMGUI_DISABLE

#import "imgui.h"
#import "imgui_impl_metal.h"
//#import "implot.h"

// ImGui code needs to live in this file because it's an Objective-C++ class, and can call C++ code.

@implementation ImGuiRenderer

-(nonnull instancetype)initWithFrame:(CGRect)bounds streamFps:(int)streamFps;
{
    self = [super init];

    _bounds = bounds;
    _device = MTLCreateSystemDefaultDevice();
    _commandQueue = [_device newCommandQueue];

#if !defined(IMGUI_DISABLE)
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    //ImPlot3D::CreateContext();
    //ImPlot::CreateContext();
    ImGuiIO& io = ImGui::GetIO(); (void)io;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableGamepad;      // Enable Gamepad Controls

    ImGui::StyleColorsDark();

    ImGui_ImplMetal_Init(_device);
#endif

    _desiredQueueSize = 2; // changed by StreamFrameViewController from app settings

    // Graphs init
    _graphAreaHeight = 200.0f;
    const int graphs = PlotCount;
    _plots = (PlotDef *)malloc(sizeof(PlotDef) * graphs);

    _plots[PLOT_FRAMETIME] = {
        .title  = "Frametime",
        .unit   = "ms",
        .scaleMin = (1000.0 / streamFps) - 1,
        .scaleMax = 50.0f, // (1000.0 / streamFps) * 3,
        .buffer = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_HOST_FRAMETIME] = {
        .title  = "Host Frametime",
        .unit   = "ms",
        .scaleMin = (1000.0 / streamFps) - 1,
        .scaleMax = 50.0f, // (1000.0 / streamFps) * 3,
        .buffer = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_QUEUED_FRAMES] = {
        .title       = "Frame queue",
        .labelType   = PLOT_LABEL_MIN_MAX_AVG_INT,
        .unit        = "",
        .scaleMin    = -0.5,
        .scaleMax    = 15,
        .buffer      = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_DRIFT] = {
        .title     = "Drift",
        .labelType = PLOT_LABEL_MIN_MAX_AVG,
        .unit      = "ms",
        .buffer    = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_DISPLAYLINK] = {
        .title       = "DisplayLink interval",
        .labelType   = PLOT_LABEL_MIN_MAX_AVG,
        .unit        = "ms",
        .scaleTarget = 1000.0 / self.mtkView.preferredFramesPerSecond,
        .buffer      = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_DECODE] = {
        .title     = "Decode time",
        .labelType = PLOT_LABEL_MIN_MAX_AVG,
        .unit      = "ms",
        .buffer    = [[FloatBuffer alloc] initWithCapacity:512],
        .hidden    = YES
    };

    _plots[PLOT_DROPPED] = {
        .title     = "Frames dropped for pacing",
        .labelType = PLOT_LABEL_TOTAL_INT,
        .unit      = "",
        .scaleTarget = 2,
        .buffer    = [[FloatBuffer alloc] initWithCapacity:512]
    };

    _plots[PLOT_FRAME_BYTES] = {
        .title     = "Bytes per frame",
        .labelType = PLOT_LABEL_MIN_MAX_AVG,
        .unit      = "KB",
        .scaleMin  = 0.0f,
        .buffer    = [[FloatBuffer alloc] initWithCapacity:512]
    };

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
#if !defined(IMGUI_DISABLE)
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
    static bool show_implot3d_demo = false;
    static ImVec4 clear_color = ImVec4(0, 0, 0, 0);

    // 1. Show the big demo window (Most of the sample code is in ImGui::ShowDemoWindow()! You can browse its code to learn more about Dear ImGui!).
    if (show_demo_window)
        ImGui::ShowDemoWindow(&show_demo_window);

    // if (show_implot3d_demo)
    //    ImPlot3D::ShowDemoWindow(&show_implot3d_demo);

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
#endif
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
}

- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];

#if !defined(IMGUI_DISABLE)
    ImGui_ImplMetal_Shutdown();
    //ImPlot::DestroyContext();
    //ImPlot3D::DestroyContext();
    ImGui::DestroyContext();
#endif
}

//-----------------------------------------------------------------------------------
// Input processing
//-----------------------------------------------------------------------------------

// This touch mapping is super cheesy/hacky. We treat any touch on the screen
// as if it were a depressed left mouse button, and we don't bother handling
// multitouch correctly at all. This causes the "cursor" to behave very erratically
// when there are multiple active touches. But for demo purposes, single-touch
// interaction actually works surprisingly well.
#if !defined(IMGUI_DISABLE)
-(BOOL)updateIOWithTouchEvent:(UIEvent *)event
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
    return YES;
}
#endif

#if !defined(IMGUI_DISABLE)
-(void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
-(void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event  { [self updateIOWithTouchEvent:event]; }
-(void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event      { [self updateIOWithTouchEvent:event]; }
#endif

/// Stats Graphs, we can still track data this way even with ImGui disabled

- (void) observeFloat:(int)plotId value:(CFTimeInterval)value {
    [self.plots[plotId].buffer addValue:(float)value];
}

- (void) observeFloatReturnMetrics:(int)plotId value:(CFTimeInterval)value plotMetrics:(PlotMetrics *)plotMetrics {
    [self.plots[plotId].buffer addValue:(float)value];
    if (plotMetrics != nil) {
        plotMetrics->min = [self.plots[plotId].buffer minValue];
        plotMetrics->max = [self.plots[plotId].buffer maxValue];
        plotMetrics->avg = [self.plots[plotId].buffer averageValue];
    }
}

- (int) getDesiredQueueSize {
    return self.desiredQueueSize;
}

#if !defined(IMGUI_DISABLE)
// Helper to display a little (?) mark which shows a tooltip when hovered.
// In your own code you may want to display an actual icon if you are using a merged icon fonts (see docs/FONTS.md)
static void HelpMarker(const char* desc)
{
    ImGui::TextDisabled("(?)");
    if (ImGui::BeginItemTooltip())
    {
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 35.0f);
        ImGui::TextUnformatted(desc);
        ImGui::PopTextWrapPos();
        ImGui::EndTooltip();
    }
}

inline static float getValue(void *buffer, int idx) {
    float *fbuffer = (float *)buffer;
    float v = fbuffer[idx];
    // clip the top of frametime graphs so they're less ugly
    if (v > 50)
        v = 49.9;

    return v;
}

- (void) drawStatsGraphs {
    const int graphs = PlotCount;

    // we malloc a buffer for frametimes once and reuse it
    static float * buffers[8] = {
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512),
        (float *)malloc(sizeof(float) * 512)
    };

    ImGuiIO &io = ImGui::GetIO();

    // Left side - 2 graphs
    ImVec2 windowSize(450.0f, _graphAreaHeight); // 450x100 works for iPad, other devices will need tweaks
    ImVec2 windowPos(10.0f, 10.0f);
    ImGui::SetNextWindowPos(windowPos, ImGuiCond_Always, ImVec2(0.0f, 0.0f));  // pivot (0,0) = top-left
    ImGui::SetNextWindowSize(windowSize, ImGuiCond_Always);
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoDecoration |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoNavFocus |
                             ImGuiWindowFlags_NoBackground |
                             ImGuiWindowFlags_NoSavedSettings;
    ImGui::Begin("##StatsLeft", nullptr, flags);

    // Dimensions of each graph
    ImVec2 avail  = ImGui::GetContentRegionAvail();
    float plotH = 45.0;
    float fullW = avail.x;

    // First 2 on left
    for (int i = 0; i < 2; i++) {
        if (self.plots[i].hidden) continue;

        float minY, maxY;
        int countF = [self.plots[i].buffer copyValuesIntoBuffer:buffers[i] min:&minY max:&maxY];
        float avgF = [self.plots[i].buffer averageValue];
        if (!countF) {
            continue;
        }

        // Ugly, but can't get ImPlot to build for iOS
        char label[64];
        switch (self.plots[i].labelType) {
            case PLOT_LABEL_MIN_MAX_AVG:
                sprintf(label, "%s  %.1f/%.1f/%.1f %s", self.plots[i].title, minY, maxY, avgF, self.plots[i].unit);
                break;
            case PLOT_LABEL_MIN_MAX_AVG_INT:
                sprintf(label, "%s  %d/%d/%.1f %s", self.plots[i].title, (int)minY, (int)maxY, avgF, self.plots[i].unit);
                break;
            case PLOT_LABEL_TOTAL_INT:
                sprintf(label, "%s  %d %s", self.plots[i].title, (int)[self.plots[i].buffer total], self.plots[i].unit);
                break;
        }
        float scaleMin = FLT_MAX;
        float scaleMax = FLT_MAX;
        if (self.plots[i].scaleTarget) {
            // optionally center the graph on a target such as the ideal frametime
            float ideal = (float)self.plots[i].scaleTarget;
            scaleMin = ideal - (2 * ideal);
            scaleMax = ideal + (2 * ideal);
        }
        if (self.plots[i].scaleMin)
            scaleMin = self.plots[i].scaleMin;
        if (self.plots[i].scaleMax)
            scaleMax = self.plots[i].scaleMax;
        ImGui::PushID(i);
        //ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        //ImGui::PushStyleColor(ImGuiCol_PlotLines, ImVec4(0.90f, 0.70f, 0.00f, 1.00f)); // yellow
        ImGui::PushStyleColor(ImGuiCol_PlotLines, ImVec4(0.0f, 1.0f, 0.0f, 1.0f)); // green
        ImGui::PlotLines("##xx", buffers[i], countF, 0, (countF > 0 ? label : "no data"), scaleMin, scaleMax, ImVec2(fullW, plotH));
        ImGui::PopStyleColor(1);
        ImGui::PopID();
    }
    ImGui::End();

    // Right side - 2 graphs
    windowPos = ImVec2(io.DisplaySize.x - 10.0f, 10.0f);    // 10px margin
    ImGui::SetNextWindowPos(windowPos, ImGuiCond_Always, ImVec2(1.0f, 0.0f));  // pivot (1,0) = top-right
    ImGui::SetNextWindowSize(windowSize, ImGuiCond_Always);
    flags = ImGuiWindowFlags_NoDecoration |
            ImGuiWindowFlags_NoMove |
            ImGuiWindowFlags_NoNavFocus |
            ImGuiWindowFlags_NoBackground |
            ImGuiWindowFlags_NoSavedSettings;
    ImGui::Begin("##StatsRight", nullptr, flags);

    // 2+ on right
    for (int i = 2; i < graphs; i++) {
        if (self.plots[i].hidden) continue;

        float minY, maxY;
        int countF = [self.plots[i].buffer copyValuesIntoBuffer:buffers[i] min:&minY max:&maxY];
        float avgF = [self.plots[i].buffer averageValue];
        if (!countF) {
            continue;
        }

        // Ugly, but can't get ImPlot to build for iOS
        char label[64];
        switch (self.plots[i].labelType) {
            case PLOT_LABEL_MIN_MAX_AVG:
                sprintf(label, "%s  %.1f/%.1f/%.1f %s", self.plots[i].title, minY, maxY, avgF, self.plots[i].unit);
                break;
            case PLOT_LABEL_MIN_MAX_AVG_INT:
                sprintf(label, "%s  %d/%d/%.1f %s", self.plots[i].title, (int)minY, (int)maxY, avgF, self.plots[i].unit);
                break;
            case PLOT_LABEL_TOTAL_INT:
                sprintf(label, "%s  %d %s", self.plots[i].title, (int)[self.plots[i].buffer total], self.plots[i].unit);
                break;
        }
        float scaleMin = FLT_MAX;
        float scaleMax = FLT_MAX;
        if (self.plots[i].scaleTarget) {
            // optionally center the graph on a target such as the ideal frametime
            float ideal = (float)self.plots[i].scaleTarget;
            scaleMin = ideal - (2 * ideal);
            scaleMax = ideal + (2 * ideal);
        }
        if (self.plots[i].scaleMin)
            scaleMin = self.plots[i].scaleMin;
        if (self.plots[i].scaleMax)
            scaleMax = self.plots[i].scaleMax;
        ImGui::PushID(i);
        //ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
        //ImGui::PushStyleColor(ImGuiCol_PlotLines, ImVec4(0.90f, 0.70f, 0.00f, 1.00f)); // yellow
        ImGui::PushStyleColor(ImGuiCol_PlotLines, ImVec4(0.0f, 1.0f, 0.0f, 1.0f)); // green
        if (i == PLOT_FRAMETIME || i == PLOT_HOST_FRAMETIME) {
            // getValue() clips at max 50
            ImGui::PlotLines("##xx", getValue, buffers[i], countF, 0, (countF > 0 ? label : "no data"), scaleMin, scaleMax, ImVec2(fullW, plotH));
        } else {
            ImGui::PlotLines("##xx", buffers[i], countF, 0, (countF > 0 ? label : "no data"), scaleMin, scaleMax, ImVec2(fullW, plotH));
        }
        ImGui::PopStyleColor(1);
        ImGui::PopID();
    }
    ImGui::End();

//    static int dqs = self.desiredQueueSize;
//    ImGui::SliderInt("Frame queue size", &dqs, 0, 10);
//    if (dqs != self.desiredQueueSize) {
//        self.desiredQueueSize = dqs;
//    }

//    const char* items[] = { "Standard Frame Pacing", "PTS Frame Pacing" };
//    static int item_current = 0;
//    ImGui::Combo("Frame pacing method", &item_current, items, IM_ARRAYSIZE(items));
//    ImGui::SameLine(); HelpMarker(
//        "Standard Frame Pacing: This frame pacing method attempts to match the behavior of moonlight-qt's Pacer class. Incoming frames from "
//        "Sunshine are asynchronously processed into a queue by another thread. This method is called every vsync and aims "
//        "to present the most recent frame each vsync, while retaining a buffer of 1 frame. Frames may be dropped from the queue "
//        "if it grows too large, but the queue is allowed to grow as large as 3 frames if the stream framerate is slower than the display refresh rate. "
//        "The queue size can be adjusted using the slider.\n\n"
//        "PTS Frame Pacing: This experimental frame pacing method uses timestamps from Sunshine to pace frames.");

}
#endif

@end
