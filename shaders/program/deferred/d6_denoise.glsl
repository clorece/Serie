// a-trous denoise iteration 6: colortex3 -> colortex6, dilation 32
// (Currently unused — d4 is the last active pass. Re-enable by restoring
// deferred6.fsh and moving DENOISE_LAST_ITER here from d4.)
#define DENOISE_SRC  colortex3
#define DENOISE_STEP 32.0
#include "/program/deferred/d_denoise_common.glsl"
