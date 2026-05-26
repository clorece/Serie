// a-trous iteration 6 (LAST): colortex6 -> colortex3, dilation 32
#define DENOISE_SRC  colortex6
#define DENOISE_STEP 32.0
/* RENDERTARGETS: 3 */
#include "/program/deferred/d_denoise_common.glsl"
