//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import VideoToolbox;

#import "VideoDecoderRenderer.h"
#import "FrameQueue.h"
#import "StreamView.h"
#import "Plot.h"
#import "Queue.h"

#include <libavcodec/avcodec.h>
#include <libavcodec/cbs.h>
#include <libavcodec/cbs_av1.h>
#include <libavformat/avio.h>
#include <libavutil/mem.h>
#include <mach/mach_time.h>

#define DISPLAYLINK_VERBOSE
// Define for extra logging related to frame pacing

// Private libavformat API for writing the AV1 Codec Configuration Box
extern int ff_isom_write_av1c(AVIOContext *pb, const uint8_t *buf, int size,
                              int write_seq_header);

@implementation VideoDecoderRenderer {
    StreamView* _view;
    id<ConnectionCallbacks> _callbacks;
    float _streamAspectRatio;

    AVSampleBufferDisplayLayer* displayLayer;
    int videoFormat;
    int frameRate;

    NSMutableArray *parameterSetBuffers;
    NSData *masteringDisplayColorVolume;
    NSData *contentLightLevelInfo;
    CMVideoFormatDescriptionRef formatDesc;
    CMVideoFormatDescriptionRef formatDescImageBuffer;
    VTDecompressionSessionRef decompressionSession;

    CADisplayLink* _displayLink;
    FrameQueue *frameQueue;
    IntQueue *pacingHistory;
}

- (void)reinitializeDisplayLayer
{
    CALayer *oldLayer = displayLayer;

    displayLayer = [[AVSampleBufferDisplayLayer alloc] init];
    displayLayer.backgroundColor = [UIColor blackColor].CGColor;

    // Ensure the AVSampleBufferDisplayLayer is sized to preserve the aspect ratio
    // of the video stream. We used to use AVLayerVideoGravityResizeAspect, but that
    // respects the PAR encoded in the SPS which causes our computed video-relative
    // touch location to be wrong in StreamView if the aspect ratio of the host
    // desktop doesn't match the aspect ratio of the stream.
    CGSize videoSize;
    if (_view.bounds.size.width > _view.bounds.size.height * _streamAspectRatio) {
        videoSize = CGSizeMake(_view.bounds.size.height * _streamAspectRatio, _view.bounds.size.height);
    } else {
        videoSize = CGSizeMake(_view.bounds.size.width, _view.bounds.size.width / _streamAspectRatio);
    }
    displayLayer.position = CGPointMake(CGRectGetMidX(_view.bounds), CGRectGetMidY(_view.bounds));
    displayLayer.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
    displayLayer.videoGravity = AVLayerVideoGravityResize;

    // Hide the layer until we get an IDR frame. This ensures we
    // can see the loading progress label as the stream is starting.
    displayLayer.hidden = YES;

    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:displayLayer];
    }
    else {
        [_view.layer addSublayer:displayLayer];
    }

    if (formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }

    if (formatDescImageBuffer != nil) {
        CFRelease(formatDescImageBuffer);
        formatDescImageBuffer = nil;
    }

    if (decompressionSession != nil){
        VTDecompressionSessionInvalidate(decompressionSession);
        CFRelease(decompressionSession);
        decompressionSession = nil;
    }
}

- (id)initWithView:(StreamView*)view callbacks:(id<ConnectionCallbacks>)callbacks streamAspectRatio:(float)aspectRatio
{
    self = [super init];

    _view = view;
    _callbacks = callbacks;
    _streamAspectRatio = aspectRatio;

    parameterSetBuffers = [[NSMutableArray alloc] init];
    frameQueue = [[FrameQueue alloc] init];
    pacingHistory = [[IntQueue alloc] init];

    [self reinitializeDisplayLayer];

    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat width:(int)videoWidth height:(int)videoHeight frameRate:(int)frameRate
{
    self->videoFormat = videoFormat;
    self->frameRate = frameRate;

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(framePacingUsingQueue:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        UIScreen *screen = [UIScreen mainScreen];
        NSInteger maxFPS = screen.maximumFramesPerSecond;
        float minFPS = MIN(self->frameRate, maxFPS);
        _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(minFPS, maxFPS, minFPS);
    }
    else {
        _displayLink.preferredFramesPerSecond = self->frameRate;
    }
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (void) setupDecompressionSession {
    if (decompressionSession != NULL) {
        VTDecompressionSessionInvalidate(decompressionSession);
        CFRelease(decompressionSession);
        decompressionSession = nil;
    }

    int status = VTDecompressionSessionCreate(kCFAllocatorDefault, formatDesc, nil, nil, nil, &decompressionSession);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create VTDecompressionSession, status %d", status);
    }
}

int DrSubmitDecodeUnit(PDECODE_UNIT decodeUnit);

// This frame pacing method attempts to match the behavior of moonlight-qt's Pacer class. Incoming frames from
// Sunshine are asynchronously processed into a queue by another thread. This method is called every vsync and aims
// to present the most recent frame each vsync, while retaining a buffer of 1 frame. Frames may be dropped from the queue
// if it grows too large, but the queue is allowed to grow as large as 3 frames if the stream framerate is slower
// than the display refresh rate. The user may adjust the 1 frame buffer size using ImGui.
//
// Pseudocode:
// frameDropTarget = 1
// Each Vsync:
//   If streamFps >= displayHz:
//     frameDropTarget = 3 (Be lenient as long as the queue length was 1 within the last 500ms)
//   Track queue size in rolling history
//   while (queue size > frameDropTarget) {
//     drop frame
//   }
//   take pending frame or wait for a frame for (deadline - 3ms or avg render time)
//   render frame before vblank
- (void)framePacingUsingQueue:(CADisplayLink *)link {
    static CFTimeInterval lastTargetLocal = 0.0f;

    CFTimeInterval deadline = link.targetTimestamp;
    _displayRefreshRate = 1.0f / link.duration;

    int frameDropTarget = [self->_callbacks getDesiredQueueSize]; // default 1, but allow user control using ImGui slider

    if (self->frameRate >= _displayRefreshRate) {
        // Be lenient as long as the queue length resolves before the end of frame history
        for (NSNumber *entry in pacingHistory) {
            if (entry.intValue <= frameDropTarget) {
                frameDropTarget += 3;
                break;
            }
        }

        // Keep a rolling 500 ms window of pacing queue history
        if ([pacingHistory count] >= _displayRefreshRate / 2) {
            [pacingHistory dequeue];
        }
        [pacingHistory enqueue:(int)[frameQueue count]];
    }

    // Catch up if we're several frames ahead
    int pacingDroppedFrames = 0;
    while ([frameQueue count] > frameDropTarget) {
        [frameQueue dequeue];
        pacingDroppedFrames++;
        // TODO: pass to stats
    }

    // Get the next frame or wait if necessary. Aim to present the frame 3ms before deadline to allow
    // time for processing. If no frame arrives the previous one will be redisplayed automatically.
    CFTimeInterval targetLocal = deadline - 0.003f;
    Frame *frame = [frameQueue dequeueWithTimeout:(targetLocal - CACurrentMediaTime())];
    if (frame != nil) {
        [self renderFrame:frame targetTimestamp:targetLocal];

        // Update metrics
        if (lastTargetLocal != 0) {
            [self->_callbacks observeFloat:PLOT_FRAMETIME value:(targetLocal - lastTargetLocal) * 1000.0];
        }
        lastTargetLocal = targetLocal;

        [self->_callbacks observeFloat:PLOT_DROPPED value:pacingDroppedFrames];
    }
}

// This frame pacing method attempts to use timestamps from Sunshine to determine when
// frames should be displayed. Sunshine v2025.600+ required.
- (void)framePacingUsingTimestamps:(CADisplayLink *)link {
    // All times are in seconds
    static BOOL setAnchor = NO;
    static CFTimeInterval anchorLocal = 0.0f;
    static CFTimeInterval anchorHost = 0.0f;
    static CFTimeInterval lastTargetLocal = 0.0f;
    static CFTimeInterval lastStart = 0.0f;
    static int lastFrameNumber = 0;

    // |------------------<-current frame->-------------------|
    // |--------|---------------------------------------------|
    // start   nowStart                                    deadline

    CFTimeInterval start = link.timestamp;
    CFTimeInterval deadline = link.targetTimestamp;
    _displayRefreshRate = 1.0f / (deadline - start);

    // Inform the frameQueue of our desired queue size, which can be changed on the fly via ImGui
    int desiredQueueSize = [self->_callbacks getDesiredQueueSize];
    [frameQueue setDesiredQueueSize:desiredQueueSize];

    CFTimeInterval now = CACurrentMediaTime();

    Frame *frame = nil;
    if (!setAnchor) {
        frame = [frameQueue dequeue];
        if (!frame) {
            return;
        }

        // special case frame 1, this is a slow setup frame
        // It can also indicate the server has restarted, so we need to reset our anchor frame status
        if (frame.frameNumber == 1) {
            [self renderFrame:frame targetTimestamp:CACurrentMediaTime()];
            setAnchor = NO;
            return;
        }

        anchorHost = frame.pts;
        anchorLocal = now;
        setAnchor = YES;
        Log(LOG_I, @"Setting anchor point: anchorHost=%f == anchorLocal=%f", anchorHost, anchorLocal);
    }
    else {
        // we might not have very accurate sync with the correct pts values, so if we notice that the queue
        // has too many frames in it, it means we are too far behind, and should request to skip to the newest
        // frame, based on desiredQueueSize
        if (frameQueue.count > desiredQueueSize + 1) {
            frame = [frameQueue dequeueForQueueSize:desiredQueueSize];
            if (!frame) {
                return;
            }
        }
        else {
            // get frame nearest to this vsync deadline
            CFTimeInterval targetPTS = anchorHost + (deadline - anchorLocal);
            frame = [frameQueue dequeueForPTS:targetPTS];
            if (!frame) {
                // if no frames are available, the last frame will be repeated automatically
                return;
            }
        }
    }

    // TODO: handle presentationTimeUs rollover every 13 hours

    // work out how much time has passed on both sides, and check our drift
    CFTimeInterval localElapsed = now - anchorLocal;
    CFTimeInterval hostElapsed = frame.pts - anchorHost;
    CFTimeInterval drift = hostElapsed - localElapsed;

    // determine when to present this frame
    CFTimeInterval targetLocal = anchorLocal + hostElapsed + drift;
    CFTimeInterval frametime = (targetLocal - lastTargetLocal) * 1000.0;
    if (lastTargetLocal != 0) {
        [self->_callbacks observeFloat:PLOT_FRAMETIME value:frametime];
    }

    // Correct for drift in small increments after it reaches half a frame
    CFTimeInterval driftThreshold = (deadline - start) / 2;
    const CFTimeInterval maxDriftCorrection = 0.001f;
    if (fabs(drift) > driftThreshold) {
        CFTimeInterval correction = drift < 0 ? maxDriftCorrection : -maxDriftCorrection;
        anchorLocal += correction;
        Log(LOG_I, @"Correcting anchorLocal's drift of %fms by %fms",
            drift * 1000.0, correction * 1000.0);
    }
    [self->_callbacks observeFloat:PLOT_DRIFT value:drift * 1000.0];

    // Graph the displayLink callback interval, it should be perfectly flat
    if (lastStart != 0.0) {
        [self->_callbacks observeFloat:PLOT_DISPLAYLINK value:(start - lastStart) * 1000.0];
    }
    lastStart = start;

    // Graph the number of frames dropped because of popFrameForQueueSize
    if (lastFrameNumber > 0) {
        int pacingDroppedFrames = frame.frameNumber - lastFrameNumber - 1;
        [self->_callbacks observeFloat:PLOT_DROPPED value:pacingDroppedFrames];
    }

    // XXX should we snap this frame to vsync interval?
    //targetLocal = deadline - 0.003f;

#ifdef DISPLAYLINK_VERBOSE
    Log(LOG_I, @"[%f] frame %d, anchorLocal %f, localElapsed %fs, hostElapsed %fs, drift %fs, targetLocal %f (%fms before deadline), deadline %f",
        start, frame.frameNumber, anchorLocal, localElapsed, hostElapsed, drift,
        targetLocal, (deadline - targetLocal) * 1000.0, deadline);
#endif

    lastTargetLocal = targetLocal;
    lastFrameNumber = frame.frameNumber;

    [self renderFrame:frame targetTimestamp:targetLocal];
}

- (void)renderFrame:(Frame *)frame targetTimestamp:(CFTimeInterval)targetTimestamp {
    CMSampleBufferSetOutputPresentationTimeStamp(frame.sampleBuffer,
                                                 CMTimeMakeWithSeconds((Float64)targetTimestamp, NSEC_PER_SEC));

    if (frame.frameNumber == 1) {
        // On first frame, set timebase to equal the initial presentation time.
        // This will sync the display clocks between client and server
        CMTimebaseRef timebase = NULL;
        CMTimebaseCreateWithSourceClock(CFAllocatorGetDefault(), CMClockGetHostTimeClock(), &timebase);

        // Set the timebase to the initial pts here
        CMTimebaseSetTime(timebase, CMSampleBufferGetOutputPresentationTimeStamp(frame.sampleBuffer));
        CMTimebaseSetRate(timebase, 1.0);

        [self->displayLayer setControlTimebase:timebase];
    }

    //Log(LOG_I, @"renderFrame %d @ pts %f", frame.frameNumber, targetTimestamp);

    [self->displayLayer enqueueSampleBuffer:frame.sampleBuffer];

    if (frame.frameType == FRAME_TYPE_IDR) {
        // Ensure the layer is visible now
        self->displayLayer.hidden = NO;

        // Tell our parent VC to hide the progress indicator
        [self->_callbacks videoContentShown];
    }
}

- (void)cleanup
{
    [_displayLink invalidate];

    if (decompressionSession != NULL) {
        VTDecompressionSessionInvalidate(decompressionSession);
        CFRelease(decompressionSession);
        decompressionSession = nil;
    }
}

#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (void)updateAnnexBBufferForRange:(CMBlockBufferRef)frameBuffer dataBlock:(CMBlockBufferRef)dataBuffer offset:(int)offset length:(int)nalLength
{
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(frameBuffer);

    // Append a 4 byte buffer to the frame block for the length prefix
    status = CMBlockBufferAppendMemoryBlock(frameBuffer, NULL,
                                            NAL_LENGTH_PREFIX_SIZE,
                                            kCFAllocatorDefault, NULL, 0,
                                            NAL_LENGTH_PREFIX_SIZE, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int)status);
        return;
    }

    // Write the length prefix to the new buffer
    const int dataLength = nalLength - NALU_START_PREFIX_SIZE;
    const uint8_t lengthBytes[] = {(uint8_t)(dataLength >> 24), (uint8_t)(dataLength >> 16),
        (uint8_t)(dataLength >> 8), (uint8_t)dataLength};
    status = CMBlockBufferReplaceDataBytes(lengthBytes, frameBuffer,
                                           oldOffset, NAL_LENGTH_PREFIX_SIZE);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int)status);
        return;
    }

    // Attach the data buffer to the frame buffer by reference
    status = CMBlockBufferAppendBufferReference(frameBuffer, dataBuffer, offset + NALU_START_PREFIX_SIZE, dataLength, 0);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
        return;
    }
}

- (NSData*)getAv1CodecConfigurationBox:(NSData*)frameData  {
    AVIOContext* ioctx = NULL;
    int err;

    err = avio_open_dyn_buf(&ioctx);
    if (err < 0) {
        Log(LOG_E, @"avio_open_dyn_buf() failed: %d", err);
        return nil;
    }

    // Submit the IDR frame to write the av1C blob
    err = ff_isom_write_av1c(ioctx, (uint8_t*)frameData.bytes, (int)frameData.length, 1);
    if (err < 0) {
        Log(LOG_E, @"ff_isom_write_av1c() failed: %d", err);
        // Fall-through to close and free buffer
    }

    // Close the dynbuf and get the underlying buffer back (which we must free)
    uint8_t* av1cBuf = NULL;
    int av1cBufLen = avio_close_dyn_buf(ioctx, &av1cBuf);

    Log(LOG_I, @"av1C block is %d bytes", av1cBufLen);

    // Only return data if ff_isom_write_av1c() was successful
    NSData* data = nil;
    if (err >= 0 && av1cBufLen > 0) {
        data = [NSData dataWithBytes:av1cBuf length:av1cBufLen];
    }
    else {
        data = nil;
    }

    av_free(av1cBuf);
    return data;
}

// Much of this logic comes from Chrome
- (CMVideoFormatDescriptionRef)createAV1FormatDescriptionForIDRFrame:(NSData*)frameData {
    NSMutableDictionary* extensions = [[NSMutableDictionary alloc] init];

    CodedBitstreamContext* cbsCtx = NULL;
    int err = ff_cbs_init(&cbsCtx, AV_CODEC_ID_AV1, NULL);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_init() failed: %d", err);
        return nil;
    }

    AVPacket avPacket = {};
    avPacket.data = (uint8_t*)frameData.bytes;
    avPacket.size = (int)frameData.length;

    // Read the sequence header OBU
    CodedBitstreamFragment cbsFrag = {};
    err = ff_cbs_read_packet(cbsCtx, &cbsFrag, &avPacket);
    if (err < 0) {
        Log(LOG_E, @"ff_cbs_read_packet() failed: %d", err);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

#define SET_CFSTR_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (__bridge NSString*)(value)
#define SET_EXTENSION(key, value) extensions[(__bridge NSString*)key] = (value)

    SET_EXTENSION(kCMFormatDescriptionExtension_FormatName, @"av01");

    // We use the value for YUV without alpha, same as Chrome
    // https://developer.apple.com/library/archive/qa/qa1183/_index.html
    SET_EXTENSION(kCMFormatDescriptionExtension_Depth, @24);

    CodedBitstreamAV1Context* bitstreamCtx = (CodedBitstreamAV1Context*)cbsCtx->priv_data;
    AV1RawSequenceHeader* seqHeader = bitstreamCtx->sequence_header;
    if (seqHeader == NULL) {
        Log(LOG_E, @"AV1 sequence header not found in IDR frame!");
        ff_cbs_fragment_free(&cbsFrag);
        ff_cbs_close(&cbsCtx);
        return nil;
    }

    switch (seqHeader->color_config.color_primaries) {
        case 1: // CP_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_709_2);
            break;

        case 6: // CP_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_SMPTE_C);
            break;

        case 9: // CP_BT_2020
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ColorPrimaries,
                                kCMFormatDescriptionColorPrimaries_ITU_R_2020);
            break;

        default:
            Log(LOG_W, @"Unsupported color_primaries value: %d", seqHeader->color_config.color_primaries);
            break;
    }

    switch (seqHeader->color_config.transfer_characteristics) {
        case 1: // TC_BT_709
        case 6: // TC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_709_2);
            break;

        case 7: // TC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_240M_1995);
            break;

        case 8: // TC_LINEAR
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_Linear);
            break;

        case 14: // TC_BT_2020_10_BIT
        case 15: // TC_BT_2020_12_BIT
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2020);
            break;

        case 16: // TC_SMPTE_2084
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ);
            break;

        case 17: // TC_HLG
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_TransferFunction,
                                kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG);
            break;

        default:
            Log(LOG_W, @"Unsupported transfer_characteristics value: %d", seqHeader->color_config.transfer_characteristics);
            break;
    }

    switch (seqHeader->color_config.matrix_coefficients) {
        case 1: // MC_BT_709
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2);
            break;

        case 6: // MC_BT_601
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4);
            break;

        case 7: // MC_SMPTE_240
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_SMPTE_240M_1995);
            break;

        case 9: // MC_BT_2020_NCL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_YCbCrMatrix,
                                kCMFormatDescriptionYCbCrMatrix_ITU_R_2020);
            break;

        default:
            Log(LOG_W, @"Unsupported matrix_coefficients value: %d", seqHeader->color_config.matrix_coefficients);
            break;
    }

    SET_EXTENSION(kCMFormatDescriptionExtension_FullRangeVideo, @(seqHeader->color_config.color_range == 1));

    // Progressive content
    SET_EXTENSION(kCMFormatDescriptionExtension_FieldCount, @(1));

    switch (seqHeader->color_config.chroma_sample_position) {
        case 1: // CSP_VERTICAL
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_Left);
            break;

        case 2: // CSP_COLOCATED
            SET_CFSTR_EXTENSION(kCMFormatDescriptionExtension_ChromaLocationTopField,
                                kCMFormatDescriptionChromaLocation_TopLeft);
            break;

        default:
            Log(LOG_W, @"Unsupported chroma_sample_position value: %d", seqHeader->color_config.chroma_sample_position);
            break;
    }

    if (contentLightLevelInfo) {
        SET_EXTENSION(kCMFormatDescriptionExtension_ContentLightLevelInfo, contentLightLevelInfo);
    }

    if (masteringDisplayColorVolume) {
        SET_EXTENSION(kCMFormatDescriptionExtension_MasteringDisplayColorVolume, masteringDisplayColorVolume);
    }

    // Referenced the VP9 code in Chrome that performs a similar function
    // https://source.chromium.org/chromium/chromium/src/+/main:media/gpu/mac/vt_config_util.mm;drc=977dc02c431b4979e34c7792bc3d646f649dacb4;l=155
    extensions[(__bridge NSString*)kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] =
    @{
        @"av1C" : [self getAv1CodecConfigurationBox:frameData],
    };
    extensions[@"BitsPerComponent"] = @(bitstreamCtx->bit_depth);

#undef SET_EXTENSION
#undef SET_CFSTR_EXTENSION

    // AV1 doesn't have a special format description function like H.264 and HEVC have, so we just use the generic one
    CMVideoFormatDescriptionRef formatDesc = NULL;
    OSStatus status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_AV1,
                                                     bitstreamCtx->frame_width, bitstreamCtx->frame_height,
                                                     (__bridge CFDictionaryRef)extensions,
                                                     &formatDesc);
    if (status != noErr) {
        Log(LOG_E, @"Failed to create AV1 format description: %d", (int)status);
        formatDesc = NULL;
    }

    ff_cbs_fragment_free(&cbsFrag);
    ff_cbs_close(&cbsCtx);
    return formatDesc;
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data
                   length:(int)length
               bufferType:(int)bufferType
               decodeUnit:(PDECODE_UNIT)du
          decodeStartTime:(CFTimeInterval)decodeStartTime
{
    OSStatus status;

    // Construct a new format description object each time we receive an IDR frame
    if (du->frameType == FRAME_TYPE_IDR) {
        if (bufferType != BUFFER_TYPE_PICDATA) {
            if (bufferType == BUFFER_TYPE_VPS || bufferType == BUFFER_TYPE_SPS || bufferType == BUFFER_TYPE_PPS) {
                // Add new parameter set into the parameter set array
                int startLen = data[2] == 0x01 ? 3 : 4;
                [parameterSetBuffers addObject:[NSData dataWithBytes:&data[startLen] length:length - startLen]];
            }

            // Data is NOT to be freed here. It's a direct usage of the caller's buffer.

            // No frame data to submit for these NALUs
            return DR_OK;
        }

        // Create the new format description when we get the first picture data buffer of an IDR frame.
        // This is the only way we know that there is no more CSD for this frame.
        //
        // NB: This logic depends on the fact that we submit all picture data in one buffer!

        // Free the old format description
        if (formatDesc != NULL) {
            CFRelease(formatDesc);
            formatDesc = NULL;
        }

        if (videoFormat & VIDEO_FORMAT_MASK_H264) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }

            Log(LOG_I, @"Constructing new H264 format description");
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         &formatDesc);
            if (status != noErr) {
                Log(LOG_E, @"Failed to create H264 format description: %d", (int)status);
                formatDesc = NULL;
            }

            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_H265) {
            // Construct parameter set arrays for the format description
            size_t parameterSetCount = [parameterSetBuffers count];
            const uint8_t* parameterSetPointers[parameterSetCount];
            size_t parameterSetSizes[parameterSetCount];
            for (int i = 0; i < parameterSetCount; i++) {
                NSData* parameterSet = parameterSetBuffers[i];
                parameterSetPointers[i] = parameterSet.bytes;
                parameterSetSizes[i] = parameterSet.length;
            }

            Log(LOG_I, @"Constructing new HEVC format description");

            NSMutableDictionary* videoFormatParams = [[NSMutableDictionary alloc] init];

            if (contentLightLevelInfo) {
                [videoFormatParams setObject:contentLightLevelInfo forKey:(__bridge NSString*)kCMFormatDescriptionExtension_ContentLightLevelInfo];
            }

            if (masteringDisplayColorVolume) {
                [videoFormatParams setObject:masteringDisplayColorVolume forKey:(__bridge NSString*)kCMFormatDescriptionExtension_MasteringDisplayColorVolume];
            }

            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                         parameterSetCount,
                                                                         parameterSetPointers,
                                                                         parameterSetSizes,
                                                                         NAL_LENGTH_PREFIX_SIZE,
                                                                         (__bridge CFDictionaryRef)videoFormatParams,
                                                                         &formatDesc);

            if (status != noErr) {
                Log(LOG_E, @"Failed to create HEVC format description: %d", (int)status);
                formatDesc = NULL;
            }

            // Free parameter set buffers after submission
            [parameterSetBuffers removeAllObjects];
        }
        else if (videoFormat & VIDEO_FORMAT_MASK_AV1) {
            NSData* fullFrameData = [NSData dataWithBytesNoCopy:data length:length freeWhenDone:NO];

            Log(LOG_I, @"Constructing new AV1 format description");
            formatDesc = [self createAV1FormatDescriptionForIDRFrame:fullFrameData];
        }
        else {
            // Unsupported codec!
            abort();
        }
    }

    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }

//    // Check for previous decoder errors before doing anything
//    if (displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
//        Log(LOG_E, @"Display layer rendering failed: %@", displayLayer.error);
//
//        // Recreate the display layer. We are already on the main thread,
//        // so this is safe to do right here.
//        [self reinitializeDisplayLayer];
//
//        // Request an IDR frame to initialize the new decoder
//        free(data);
//        return DR_NEED_IDR;
//    }

    // Now we're decoding actual frame data here
    CMBlockBufferRef frameBlockBuffer;
    CMBlockBufferRef dataBlockBuffer;

    status = CMBlockBufferCreateWithMemoryBlock(NULL, data, length, kCFAllocatorDefault, NULL, 0, length, 0, &dataBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
        free(data);
        return DR_NEED_IDR;
    }

    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced

    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &frameBlockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        return DR_NEED_IDR;
    }

    // H.264 and HEVC formats require NAL prefix fixups from Annex B to length-delimited
    if (videoFormat & (VIDEO_FORMAT_MASK_H264 | VIDEO_FORMAT_MASK_H265)) {
        int lastOffset = -1;
        for (int i = 0; i < length - NALU_START_PREFIX_SIZE; i++) {
            // Search for a NALU
            if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
                // It's the start of a new NALU
                if (lastOffset != -1) {
                    // We've seen a start before this so enqueue that NALU
                    [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:i - lastOffset];
                }

                lastOffset = i;
            }
        }

        if (lastOffset != -1) {
            // Enqueue the remaining data
            [self updateAnnexBBufferForRange:frameBlockBuffer dataBlock:dataBlockBuffer offset:lastOffset length:length - lastOffset];
        }
    }
    else {
        // For formats that require no length-changing fixups, just append a reference to the raw data block
        status = CMBlockBufferAppendBufferReference(frameBlockBuffer, dataBlockBuffer, 0, length, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendBufferReference failed: %d", (int)status);
            return DR_NEED_IDR;
        }
    }

    // Set pts to the current frame's pts
    CMSampleTimingInfo sampleTiming = {
        .duration              = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMakeWithSeconds((Float64)du->presentationTimeUs / 1000000.0, NSEC_PER_SEC),
        .decodeTimeStamp       = kCMTimeInvalid,
    };

    CMSampleBufferRef sampleBuffer;
    status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                  frameBlockBuffer,
                                  formatDesc, 1, 1,
                                  &sampleTiming, 0, NULL,
                                  &sampleBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int)status);
        CFRelease(dataBlockBuffer);
        CFRelease(frameBlockBuffer);
        return DR_NEED_IDR;
    }

    OSStatus decodeStatus = [self decodeFrameWithSampleBuffer:sampleBuffer
                                                  frameNumber:du->frameNumber
                                                    frameType:du->frameType
                                              decodeStartTime:decodeStartTime];
    if (decodeStatus != noErr) {
        Log(LOG_E, @"Failed to decompress frame: %d", decodeStatus);
        return DR_NEED_IDR;
    }

    // Dereference the buffers
    CFRelease(dataBlockBuffer);
    CFRelease(frameBlockBuffer);
    CFRelease(sampleBuffer);

    return DR_OK;
}

- (OSStatus)decodeFrameWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
                            frameNumber:(int)frameNumber
                              frameType:(int)frameType
                        decodeStartTime:(CFTimeInterval)decodeStartTime
{
    if (frameType == FRAME_TYPE_IDR || decompressionSession == nil) {
        [self setupDecompressionSession];
    }

    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    return VTDecompressionSessionDecodeFrameWithOutputHandler(
        decompressionSession, sampleBuffer, flags, NULL,
        ^(OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef _Nullable imageBuffer, CMTime presentationTimestamp, CMTime presentationDuration) {
          if (status != noErr) {
              NSError *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
              Log(LOG_E, @"Decompression session error: %@", error);
              LiRequestIdrFrame();
              return;
          }

          if (self->formatDescImageBuffer == NULL || !CMVideoFormatDescriptionMatchesImageBuffer(self->formatDescImageBuffer, imageBuffer)) {
              OSStatus res = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &(self->formatDescImageBuffer));
              if (res != noErr) {
                  Log(LOG_E, @"Failed to create video format description from imageBuffer");
                  return;
              }
          }

          CMSampleBufferRef sampleBuffer;
          CMSampleTimingInfo sampleTiming = {kCMTimeInvalid, presentationTimestamp, presentationDuration};

          OSStatus err = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, imageBuffer, self->formatDescImageBuffer, &sampleTiming, &sampleBuffer);
          if (err != noErr) {
              Log(LOG_E, @"Error creating sample buffer for decompressed image buffer %d", (int)err);
              return;
          }

          Frame *frame = [[Frame alloc] initWithSampleBuffer:sampleBuffer frameNumber:frameNumber frameType:frameType];
          [self->frameQueue enqueue:frame];
          self->_frameQueueSize = self->frameQueue.count; // this is the count shown in stats

          self->_avgDecodeTime = [self->_callbacks observeFloatReturnAvg:PLOT_DECODE value:(CACurrentMediaTime() - decodeStartTime) * 1000.0];
        });
}

- (void)setHdrMode:(BOOL)enabled {
    SS_HDR_METADATA hdrMetadata;

    BOOL hasMetadata = enabled && LiGetHdrMetadata(&hdrMetadata);
    BOOL metadataChanged = NO;

    if (hasMetadata && hdrMetadata.displayPrimaries[0].x != 0 && hdrMetadata.maxDisplayLuminance != 0) {
        // This data is all in big-endian
        struct {
          vector_ushort2 primaries[3];
          vector_ushort2 white_point;
          uint32_t luminance_max;
          uint32_t luminance_min;
        } __attribute__((packed, aligned(4))) mdcv;

        // mdcv is in GBR order while SS_HDR_METADATA is in RGB order
        mdcv.primaries[0].x = __builtin_bswap16(hdrMetadata.displayPrimaries[1].x);
        mdcv.primaries[0].y = __builtin_bswap16(hdrMetadata.displayPrimaries[1].y);
        mdcv.primaries[1].x = __builtin_bswap16(hdrMetadata.displayPrimaries[2].x);
        mdcv.primaries[1].y = __builtin_bswap16(hdrMetadata.displayPrimaries[2].y);
        mdcv.primaries[2].x = __builtin_bswap16(hdrMetadata.displayPrimaries[0].x);
        mdcv.primaries[2].y = __builtin_bswap16(hdrMetadata.displayPrimaries[0].y);

        mdcv.white_point.x = __builtin_bswap16(hdrMetadata.whitePoint.x);
        mdcv.white_point.y = __builtin_bswap16(hdrMetadata.whitePoint.y);

        // These luminance values are in 10000ths of a nit
        mdcv.luminance_max = __builtin_bswap32((uint32_t)hdrMetadata.maxDisplayLuminance * 10000);
        mdcv.luminance_min = __builtin_bswap32(hdrMetadata.minDisplayLuminance);

        NSData* newMdcv = [NSData dataWithBytes:&mdcv length:sizeof(mdcv)];
        if (masteringDisplayColorVolume == nil || ![newMdcv isEqualToData:masteringDisplayColorVolume]) {
            masteringDisplayColorVolume = newMdcv;
            metadataChanged = YES;
        }
    }
    else if (masteringDisplayColorVolume != nil) {
        masteringDisplayColorVolume = nil;
        metadataChanged = YES;
    }

    if (hasMetadata && hdrMetadata.maxContentLightLevel != 0 && hdrMetadata.maxFrameAverageLightLevel != 0) {
        // This data is all in big-endian
        struct {
            uint16_t max_content_light_level;
            uint16_t max_frame_average_light_level;
        } __attribute__((packed, aligned(2))) cll;

        cll.max_content_light_level = __builtin_bswap16(hdrMetadata.maxContentLightLevel);
        cll.max_frame_average_light_level = __builtin_bswap16(hdrMetadata.maxFrameAverageLightLevel);

        NSData* newCll = [NSData dataWithBytes:&cll length:sizeof(cll)];
        if (contentLightLevelInfo == nil || ![newCll isEqualToData:contentLightLevelInfo]) {
            contentLightLevelInfo = newCll;
            metadataChanged = YES;
        }
    }
    else if (contentLightLevelInfo != nil) {
        contentLightLevelInfo = nil;
        metadataChanged = YES;
    }

    // If the metadata changed, request an IDR frame to re-create the CMVideoFormatDescription
    if (metadataChanged) {
        LiRequestIdrFrame();
    }
}

@end
