// d6_denoise : 6th SVGF a-trous iteration (step 32), the LAST iteration.
// Chain: d1_atrous_first (step1 -> ct3) -> d1..d4_denoise (steps 2/4/8/16) ->
// THIS (step32). Six post-first iterations land the final result on colortex6
// (odd count flips the ct3<->ct6 ping-pong), so d7_composite reads colortex6.
// Writes colortex6 (filtered, read by composite) + colortex8 (raw history feedback).
#define DENOISE_SRC  colortex3
#define DENOISE_STEP 32.0
#define DENOISE_LAST_ITER
/* RENDERTARGETS: 6,8 */
#include "/program/deferred/d_denoise_common.glsl"
