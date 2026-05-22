// SVGF a-trous iteration 6 (LAST): colortex6 -> colortex3 + colortex8, dilation 32
#define DENOISE_SRC  colortex6
#define DENOISE_STEP 32.0
#define DENOISE_LAST_ITER
/* RENDERTARGETS: 3,8 */
#include "/program/deferred/d_denoise_common.glsl"
