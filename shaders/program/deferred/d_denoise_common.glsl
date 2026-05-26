// ============================================================================
//  d_denoise_common : one a-trous spatial iteration of the GI denoiser.
//  The including pass sets DENOISE_SRC (colour+variance input) and DENOISE_STEP
//  (kernel dilation), and picks the output buffer via its RENDERTARGETS comment.
//  Output: .rgb = filtered irradiance, .a = filtered variance.
//  The temporal history (colortex8) is NOT written here - it stays the raw
//  accumulated signal from d0_accum so the blur is never fed back / compounded.
// ============================================================================

#ifndef DENOISE_SRC
    #error "d_denoise_common.glsl: define DENOISE_SRC"
#endif
#ifndef DENOISE_STEP
    #define DENOISE_STEP 1.0
#endif

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

uniform sampler2D colortex1;   // view normals
uniform sampler2D colortex8;   // accumulated GI (.rgb) + history length (.a)
uniform sampler2D depthtex0;
uniform sampler2D DENOISE_SRC; // colour (.rgb) + variance (.a)

void main() {
    vec4 outv = texture(DENOISE_SRC, texCoord);

    #if defined(GI_DENOISE) && defined(VOXEL_GI)
        float frames = texture(colortex8, texCoord).a;
        outv = atrousFilter(DENOISE_SRC, depthtex0, colortex1, texCoord, float(DENOISE_STEP), frames);
    #endif

    gl_FragData[0] = outv;
}

#endif
