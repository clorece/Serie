// ============================================================================
//  d_denoise_common : one SVGF a-trous iteration
// ----------------------------------------------------------------------------
//  The including pass sets:
//      DENOISE_SRC         - colour+variance input from prev iteration
//      DENOISE_STEP        - kernel dilation for this iteration
//      DENOISE_LAST_ITER   - (optional) write to history (colortex8)
//  and the .fsh wrapper picks the output via its DRAWBUFFERS comment.
//  Output: .rgb = filtered irradiance, .a = filtered variance.
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
uniform sampler2D depthtex0;
uniform mat4 gbufferProjectionInverse; // for world-space tap distance (SVGF_WORLD_RADIUS)
uniform sampler2D DENOISE_SRC; // colour (.rgb) + variance (.a)

#ifdef DENOISE_LAST_ITER
    uniform sampler2D colortex8;   // read history length (.a) to preserve it
#endif

void main() {
    float depthC   = texture(depthtex0, texCoord).r;
    float linDepth = getDepth(depthC);
    // Screen-space depth gradient in uniform control flow (valid derivatives).
    vec2  depthGrad = vec2(dFdx(linDepth), dFdy(linDepth));
    vec3  nrm = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);

    // World blocks spanned per screen-pixel per unit linear depth (vertical FOV
    // term). The a-trous taps then convert their pixel offset into a world-space
    // distance so the kernel's WORLD footprint stays bounded at any range.
    float pxWorld = 2.0 * gbufferProjectionInverse[1][1] * texelSize.y;

    vec4 outv = texture(DENOISE_SRC, texCoord);
    #if defined(GI_DENOISE) && (defined(VOXEL_GI) || defined(VOXEL_AO))
        if (depthC < 1.0) {
            outv = svgfAtrous(DENOISE_SRC, depthtex0, colortex1, texCoord,
                              float(DENOISE_STEP), linDepth, depthGrad, nrm, pxWorld);
        }
    #endif

    #ifdef DENOISE_LAST_ITER
        // colortex8 holds the history length from d0_accum/d0_restir
        vec4  c8      = texture(colortex8, texCoord);
        float histLen = c8.a;

        // ---- Displayed result (colortex6 or colortex8 via DRAWBUFFERS) ----
        vec3 displayColor = outv.rgb;
        #ifdef SVGF_DETAIL_PRESERVE
            float preserve = clamp(histLen / float(SVGF_PRESERVE_FRAMES), 0.0, 1.0)
                           * (float(SVGF_PRESERVE_MAX) / 100.0);
            displayColor = mix(outv.rgb, c8.rgb, preserve);
        #endif
        gl_FragData[0] = vec4(displayColor, outv.a);

        // ---- Temporal history feedback (colortex8) ----
        #ifdef SVGF_RAW_HISTORY
            // Keep the history as the RAW accumulated GI.
            gl_FragData[1] = vec4(c8.rgb, histLen);
        #else
            // Classic SVGF: spatially-filtered result is also the temporal history.
            gl_FragData[1] = vec4(outv.rgb, histLen);
        #endif
    #else
        gl_FragData[0] = outv;
    #endif
}

#endif
