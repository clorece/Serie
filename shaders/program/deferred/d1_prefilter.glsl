// ============================================================================
//  d1_prefilter : seed the a-trous chain.
//  Reads the temporally-accumulated GI (colortex8.rgb) + history length (.a) and
//  the luminance moments (colortex9.gb), estimates per-pixel variance, and writes
//  colortex3 = (accumulated GI, variance) for the spatial passes.
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/pt/denoise.glsl"

in vec2 texCoord;

uniform sampler2D colortex8;   // accumulated GI (.rgb) + history length (.a)
uniform sampler2D colortex9;   // LINEAR depth (.r) + luminance moments (.g = E[L], .b = E[L^2])
uniform sampler2D depthtex0;

void main() {
    float depthC = texture(depthtex0, texCoord).r;
    if (depthC >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        return;
    }

    vec4  c8     = texture(colortex8, texCoord);
    float frames = c8.a;
    float var    = estimateVariance(colortex8, colortex9, texCoord, frames);

    /* RENDERTARGETS: 3 */
    gl_FragData[0] = vec4(c8.rgb, var);
}

#endif
