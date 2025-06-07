#import "FloatBuffer.h"

typedef enum {
    PLOT_FRAMETIME = 0,
    PLOT_DRIFT,
    PLOT_DISPLAYLINK,
    PlotCount
} PlotType;

struct PlotDef {
    FloatBuffer * _Nonnull buffer;
    const char * _Nonnull title;
    const char * _Nonnull unit;
    double scaleTarget;
    float minY;
    float maxY;
};
