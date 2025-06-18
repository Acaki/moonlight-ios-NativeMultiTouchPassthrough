typedef enum {
    PACING_MODE_VSYNC,
    PACING_MODE_PTS
} FramePacingMode;

typedef enum {
    PLOT_FRAMETIME = 0,
    PLOT_HOST_FRAMETIME,
    PLOT_QUEUED_FRAMES,
    PLOT_DRIFT,
    PLOT_DISPLAYLINK,
    PLOT_DECODE,
    PLOT_DROPPED,
    PLOT_FRAME_BYTES,
    PlotCount
} PlotType;

typedef enum {
    PLOT_LABEL_MIN_MAX_AVG = 0,
    PLOT_LABEL_MIN_MAX_AVG_INT,
    PLOT_LABEL_TOTAL_INT
} PlotLabelType;

typedef struct {
    float min;
    float max;
    float avg;
    float total;
    int nsamples;
    float samplerate;
} PlotMetrics;

typedef struct {
    CFTimeInterval startTime;
    CFTimeInterval endTime;
    int totalFrames;
    int receivedFrames;
    int networkDroppedFrames;
    int totalHostProcessingLatency;
    int framesWithHostProcessingLatency;
    int maxHostProcessingLatency;
    int minHostProcessingLatency;
    CFTimeInterval displayRefreshRate;
    PlotMetrics decodeMetrics;
    PlotMetrics frameQueueMetrics;
    PlotMetrics frameDropMetrics;
    FramePacingMode framePacingMode;
} video_stats_t;
