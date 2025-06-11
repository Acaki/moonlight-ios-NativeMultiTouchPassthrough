#import "FloatBuffer.h"

typedef enum {
    PLOT_FRAMETIME = 0,
    PLOT_QUEUED_FRAMES,
    PLOT_DRIFT,
    PLOT_DISPLAYLINK,
    PLOT_DECODE,
    PLOT_DROPPED,
    PlotCount
} PlotType;

typedef enum {
    PLOT_LABEL_MIN_MAX_AVG = 0,
    PLOT_LABEL_MIN_MAX_NOW_INT,
    PLOT_LABEL_TOTAL_INT
} PlotLabelType;

struct PlotDef {
    FloatBuffer * _Nonnull buffer;
    const char * _Nonnull title;
    PlotLabelType labelType;
    const char * _Nonnull unit;
    double scaleTarget;
    float minY;
    float maxY;
    BOOL hidden;
};
