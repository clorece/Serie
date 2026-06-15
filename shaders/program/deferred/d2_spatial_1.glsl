
// d2_spatial_1: a-trous wavelet pass 1 (variance-guided). Shared body in giSpatial.glsl.

#include "/lib/options.glsl"

#ifdef VERTEX
out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}
#endif

#ifdef FRAGMENT
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

in vec2 texCoord;
vec3 clipSpace;
#include "/lib/util/positions.glsl"

#define STEP_SIZE 1.0
#define INPUT_TEX colortex11
#include "/lib/giSpatial.glsl"

void main() {
    /* RENDERTARGETS: 6 */
    gl_FragData[0] = giSpatialFilter();
}
#endif
