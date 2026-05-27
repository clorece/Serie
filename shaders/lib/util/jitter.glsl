#ifndef JITTER_GLSL
#define JITTER_GLSL

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"

#ifndef FRAME_COUNTER_DECLARE
#define FRAME_COUNTER_DECLARE
#endif

vec2 getTaaJitter(int frame) {
    #ifdef TAA
        int index = frame % 8;
        const vec2 jitterPoints[8] = vec2[](
            vec2(-0.125, -0.375),
            vec2( 0.375, -0.125),
            vec2(-0.375,  0.125),
            vec2( 0.125,  0.375),
            vec2( 0.25,  -0.25 ),
            vec2(-0.25,   0.25 ),
            vec2( 0.0,    0.0  ),
            vec2( 0.125, -0.125)
        );
        return jitterPoints[index] * 0.45;
    #else
        return vec2(0.0);
    #endif
}

vec2 getTaaJitter() {
    return getTaaJitter(frameCounter);
}

#endif
