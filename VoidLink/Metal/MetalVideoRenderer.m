#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import "MetalVideoRenderer.h"

#include <Limelight.h>

#define MAX_VIDEO_PLANES 3

struct CscParams {
    vector_float3 matrix[3];
    vector_float3 offsets;
};

struct ParamBuffer {
    struct CscParams cscParams;
};

static const struct CscParams k_CscParams_Bt601Lim = {
    // CSC Matrix
    {
        {1.1644f, 0.0f, 1.5960f},
        {1.1644f, -0.3917f, -0.8129f},
        {1.1644f, 2.0172f, 0.0f}
    },

    // Offsets
    {16.0f / 255.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};
static const struct CscParams k_CscParams_Bt601Full = {
    {
        {1.0f, 0.0f, 1.4020f},
        {1.0f, -0.3441f, -0.7141f},
        {1.0f, 1.7720f, 0.0f},
    },
    {0.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};
static const struct CscParams k_CscParams_Bt709Lim = {
    {
        {1.1644f, 0.0f, 1.7927f},
        {1.1644f, -0.2132f, -0.5329f},
        {1.1644f, 2.1124f, 0.0f},
    },
    {16.0f / 255.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};
static const struct CscParams k_CscParams_Bt709Full = {
    {
        {1.0f, 0.0f, 1.5748f},
        {1.0f, -0.1873f, -0.4681f},
        {1.0f, 1.8556f, 0.0f},
    },
    {0.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};
static const struct CscParams k_CscParams_Bt2020Lim = {
    {
        {1.1644f, 0.0f, 1.6781f},
        {1.1644f, -0.1874f, -0.6505f},
        {1.1644f, 2.1418f, 0.0f},
    },
    {16.0f / 255.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};
static const struct CscParams k_CscParams_Bt2020Full = {
    {
        {1.0f, 0.0f, 1.4746f},
        {1.0f, -0.1646f, -0.5714f},
        {1.0f, 1.8814f, 0.0f},
    },
    {0.0f, 128.0f / 255.0f, 128.0f / 255.0f},
};

struct Vertex {
  vector_float4 position;
  vector_float2 texCoord;
};

@implementation MetalVideoRenderer {
    id<MTLDevice> _device;
    float _framerate;
    id<MTLCommandQueue> _commandQueue;
    id<MTLLibrary> _shaderLibrary;
    id<MTLRenderPipelineState> _videoPipelineState;
    MTLRenderPassDescriptor *_renderPassDescriptor;
    id<MTLTexture> _videoTexture;
    CVMetalTextureCacheRef _textureCache;

    int _lastColorSpace;
    BOOL _lastFullRange;
    size_t _lastFrameWidth;
    size_t _lastFrameHeight;
    size_t _lastDrawableWidth;
    size_t _lastDrawableHeight;
    id<MTLBuffer> _CscParamsBuffer;
    id<MTLBuffer> _VideoVertexBuffer;

}

- (instancetype)initWithMetalDevice:(id<MTLDevice>)device
                drawablePixelFormat:(MTLPixelFormat)drawablePixelFormat
                          framerate:(float)framerate
{
    self = [super init];
    if (self) {
        _device = device;
        _colorPixelFormat = drawablePixelFormat;
        _colorspace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ); // XXX
        _framerate = framerate;
        _commandQueue = [_device newCommandQueue];
        _lastColorSpace = -1;
        _lastFullRange = NO;

        CVMetalTextureCacheCreate(NULL, NULL, _device, NULL, &_textureCache);
    }
    return self;
}

- (int)getFrameColorspaceAndRange:(Frame *)frame isFullRange:(BOOL *)isFullRange {
    CFDictionaryRef ext = [frame getFormatDescExtensions];

    // Full Range boolean
    CFBooleanRef fullRangeRef = CFDictionaryGetValue(ext, kCMFormatDescriptionExtension_FullRangeVideo);
    *isFullRange = NO;
    if ( fullRangeRef && CFGetTypeID(fullRangeRef) == CFBooleanGetTypeID() ) {
        *isFullRange = CFBooleanGetValue(fullRangeRef);
    }

    // Colorspace
    CFStringRef frame_color = CFDictionaryGetValue(ext, kCVImageBufferColorPrimariesKey);
    if (CFEqual(frame_color, kCVImageBufferColorPrimaries_ITU_R_709_2)) {
        return COLORSPACE_REC_709;
    } else if (CFEqual(frame_color, kCVImageBufferColorPrimaries_ITU_R_2020)) {
        return COLORSPACE_REC_2020;
    }
    return COLORSPACE_REC_601;
}


- (BOOL) updateColorSpaceForFrame:(Frame *)frame
                          toLayer:(CAMetalLayer *)layer
{
    BOOL fullRange = NO;
    int colorspace = [self getFrameColorspaceAndRange:frame isFullRange:&fullRange];
    if (colorspace != _lastColorSpace || fullRange != _lastFullRange) {
        CGColorSpaceRef newColorSpace = nil;
        struct ParamBuffer paramBuffer;

        // XXX do we need to do this?
        // Free any unpresented drawable since we're changing pixel formats
        // discardNextDrawable();

        switch (colorspace) {
        case COLORSPACE_REC_709:
            layer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_709);
            layer.pixelFormat = MTLPixelFormatBGR10A2Unorm; // MTLPixelFormatBGRA8Unorm;
            paramBuffer.cscParams = (fullRange ? k_CscParams_Bt709Full : k_CscParams_Bt709Lim);
            break;
        case COLORSPACE_REC_2020: {
            CFDictionaryRef ext = [frame getFormatDescExtensions];
            CFStringRef frame_trc = CFDictionaryGetValue(ext, kCVImageBufferTransferFunctionKey);
            if (CFEqual(frame_trc, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) {
                layer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2100_PQ);
                layer.pixelFormat = MTLPixelFormatBGR10A2Unorm;
            } else {
                // SDR 2020
                layer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceITUR_2020);
                layer.pixelFormat = MTLPixelFormatBGR10A2Unorm; // MTLPixelFormatBGRA8Unorm;
            }
            paramBuffer.cscParams = (fullRange ? k_CscParams_Bt2020Full : k_CscParams_Bt2020Lim);
            break;
        }
        case COLORSPACE_REC_601:
            layer.colorspace = newColorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            layer.pixelFormat = MTLPixelFormatBGR10A2Unorm; // MTLPixelFormatBGRA8Unorm;
            paramBuffer.cscParams = (fullRange ? k_CscParams_Bt601Full : k_CscParams_Bt601Lim);
        }

        // The CAMetalLayer retains the CGColorSpace
        if (newColorSpace) {
            CGColorSpaceRelease(newColorSpace);
        }

        // Create the new colorspace parameter buffer for our fragment shader
        MTLResourceOptions bufferOptions = MTLResourceStorageModeShared;
        _CscParamsBuffer = [_device newBufferWithBytes:(void*)&paramBuffer length:sizeof(paramBuffer) options:bufferOptions];
        if (!_CscParamsBuffer) {
            Log(LOG_E, @"Failed to create CSC parameters buffer");
            return NO;
        }

        size_t planes = CVPixelBufferGetPlaneCount(frame.pixelBuffer);
        assert(planes == 2 || planes == 3);

        MTLRenderPipelineDescriptor *pipelineDesc = [MTLRenderPipelineDescriptor new];
        id<MTLLibrary> defaultLibrary = [_device newDefaultLibrary];
        pipelineDesc.vertexFunction = [defaultLibrary newFunctionWithName:@"vs_draw"];
        pipelineDesc.fragmentFunction = [defaultLibrary newFunctionWithName:planes == 2 ? @"ps_draw_biplanar" : @"ps_draw_triplanar"];
        pipelineDesc.colorAttachments[0].pixelFormat = layer.pixelFormat;

        NSError *error = nil;
        _videoPipelineState = [_device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
        if (!_videoPipelineState) {
            Log(LOG_E, @"Failed to create video pipeline state: %@", error);
            return NO;
        }

        _lastColorSpace = colorspace;
        _lastFullRange = fullRange;
    }

    return YES;
}

- (void)scaleSource:(CGRect *)src toDest:(CGRect *)dst {
    int dstH = ceilf((float)dst->size.width * src->size.height / src->size.width);
    int dstW = ceilf((float)dst->size.height * src->size.width / src->size.height);

    if (dstH > dst->size.height) {
        dst->origin.x += (dst->size.width - dstW) / 2;
        dst->size.width = dstW;
    } else {
        dst->origin.y += (dst->size.height - dstH) / 2;
        dst->size.height = dstH;
    }
}

- (void)screenSpace:(CGRect *)src toNormalizedDeviceCoords:(CGRect *)dst withDrawableWidth:(int)viewportWidth drawableHeight:(int)viewportHeight
{
    dst->origin.x = ((float)src->origin.x / (viewportWidth / 2.0f)) - 1.0f;
    dst->origin.y = ((float)src->origin.y / (viewportHeight / 2.0f)) - 1.0f;
    dst->size.width = (float)src->size.width / (viewportWidth / 2.0f);
    dst->size.height = (float)src->size.height / (viewportHeight / 2.0f);
}

- (BOOL)updateVideoRegionSizeForFrame:(Frame *)frame
                              toLayer:(CAMetalLayer *)layer
{
    int drawableWidth = layer.drawableSize.width;
    int drawableHeight = layer.drawableSize.height;

    // Check if anything has changed since the last vertex buffer upload
    if (_VideoVertexBuffer
        && [frame width] == _lastFrameWidth && [frame height] == _lastFrameHeight
        && drawableWidth == _lastDrawableWidth && drawableHeight == _lastDrawableHeight
    ) {
        // Nothing to do
        return YES;
    }

    // Determine the correct scaled size for the video region
    CGRect src = CGRectMake(0.0, 0.0, [frame width], [frame height]);
    CGRect dst = CGRectMake(0.0, 0.0, drawableWidth, drawableHeight);
    [self scaleSource:&src toDest:&dst];

    // Convert screen space to normalized device coordinates
    CGRect renderRect;
    [self screenSpace:&dst toNormalizedDeviceCoords:&renderRect withDrawableWidth:drawableWidth drawableHeight:drawableHeight];

    struct Vertex verts[] =
    {
        { { renderRect.origin.x, renderRect.origin.y, 0.0f, 1.0f }, { 0.0f, 1.0f } },
        { { renderRect.origin.x, renderRect.origin.y + renderRect.size.height, 0.0f, 1.0f }, { 0.0f, 0} },
        { { renderRect.origin.x + renderRect.size.width, renderRect.origin.y, 0.0f, 1.0f }, { 1.0f, 1.0f} },
        { { renderRect.origin.x + renderRect.size.width, renderRect.origin.y + renderRect.size.height, 0.0f, 1.0f }, { 1.0f, 0} },
    };

    MTLResourceOptions bufferOptions = MTLResourceStorageModeShared;
    _VideoVertexBuffer = [_device newBufferWithBytes:verts length:sizeof(verts) options:bufferOptions];
    if (!_VideoVertexBuffer) {
        Log(LOG_E, @"Failed to create video vertex buffer");
        return NO;
    }

    _lastFrameWidth = [frame width];
    _lastFrameHeight = [frame height];
    _lastDrawableWidth = drawableWidth;
    _lastDrawableHeight = drawableHeight;

    return YES;
}

- (void)renderFrame:(Frame *)frame
            toLayer:(CAMetalLayer *)layer
               with:(CAMetalDisplayLinkUpdate *_Nonnull)update
                 at:(CFTimeInterval)deltaTime
{
    // Handle changes to the frame's colorspace from last time we rendered
    if (![self updateColorSpaceForFrame:frame toLayer:layer]) {
        // XXX Trigger the main thread to recreate the decoder
//        SDL_Event event;
//        event.type = SDL_RENDER_DEVICE_RESET;
//        SDL_PushEvent(&event);
       return;
    }

    // Handle changes to the video size or drawable size
    if (![self updateVideoRegionSizeForFrame:frame toLayer:layer]) {
        // Trigger the main thread to recreate the decoder
//        SDL_Event event;
//        event.type = SDL_RENDER_DEVICE_RESET;
//        SDL_PushEvent(&event);
        return;
    }

    CVMetalTextureRef *cvMetalTextures = malloc(sizeof(CVMetalTextureRef) * MAX_VIDEO_PLANES);
    size_t planes = CVPixelBufferGetPlaneCount(frame.pixelBuffer);
    for (size_t i = 0; i < planes; i++) {
        MTLPixelFormat fmt;

        switch (CVPixelBufferGetPixelFormatType(frame.pixelBuffer)) {
            case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
            case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
                fmt = (i == 0) ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm;
                break;

            case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
                fmt = (i == 0) ? MTLPixelFormatR16Unorm : MTLPixelFormatRG16Unorm;
                break;

            default:
                Log(LOG_E, @"Unknown pixel format: %@", CVPixelBufferGetPixelFormatType(frame.pixelBuffer));
                return;
        }

        CVReturn err = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                 _textureCache,
                                                                 frame.pixelBuffer,
                                                                 NULL,
                                                                 fmt,
                                                                 CVPixelBufferGetWidthOfPlane(frame.pixelBuffer, i),
                                                                 CVPixelBufferGetHeightOfPlane(frame.pixelBuffer, i),
                                                                 i,
                                                                 &cvMetalTextures[i]);
        if (err != kCVReturnSuccess) {
            Log(LOG_E, @"CVMetalTextureCacheCreateTextureFromImage() failed: %d", err);
            return;
        }
    }

    id<CAMetalDrawable> drawable = update.drawable;
    if (!drawable) {
        Log(LOG_E, @"No drawable available");
        return;
    }

    _renderPassDescriptor = [MTLRenderPassDescriptor new];
    _renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
    _renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    _renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    _renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:_renderPassDescriptor];

    [renderEncoder setRenderPipelineState:_videoPipelineState];
    for (size_t i = 0; i < planes; i++) {
        [renderEncoder setFragmentTexture:CVMetalTextureGetTexture(cvMetalTextures[i]) atIndex:i];
    }
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        // Free textures after completion of rendering per CVMetalTextureCache requirements
        // XXX any way to reuse these buffers?
        for (size_t i = 0; i < planes; i++) {
            CVBufferRelease(cvMetalTextures[i]);
        }
        free(cvMetalTextures);
    }];

    [renderEncoder setFragmentBuffer:_CscParamsBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:_VideoVertexBuffer offset:0 atIndex:0];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [renderEncoder endEncoding];

    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    // Wait for the command buffer to complete and free our CVMetalTextureCache references
    [commandBuffer waitUntilCompleted];
}

@end


// TODO; test this for automatic tone mapping to match Windows
//CAMetalLayer *metalLayer = [CAMetalLayer new];
//metalLayer.wantsExtendedDynamicRangeContent = YES;
//metalLayer.pixelFormat = MTLPixelFormatRGBA16Float;
//
//
//const CFStringRef name = kCGColorSpaceExtendedLinearITUR_2020;
//CGColorSpaceRef colorspace = CGColorSpaceCreateWithName(name);
//metalLayer.colorspace = colorspace;
//
//
//CGColorSpaceRelease(colorspace);
//CAEDRMetadata *edrMetaData = [CAEDRMetadata HDR10MetadataWithMinLuminance: 0.005 maxLuminance: 1000 opticalOutputScale: 100];
//metalLayer.EDRMetadata = edrMetaData;
