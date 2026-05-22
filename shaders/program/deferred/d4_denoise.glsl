// SVGF a-trous iteration 4 (LAST): colortex3 -> colortex6 + colortex8, dilation 8
#define DENOISE_SRC  colortex3
#define DENOISE_STEP 8.0
#define DENOISE_LAST_ITER
#include "/program/deferred/d_denoise_common.glsl"
