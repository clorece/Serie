// ============================================================================
//  d_denoise_common : one SVGF a-trous iteration (shared by d1/d2/d3)
// ----------------------------------------------------------------------------
//  The including pass sets:
//      DENOISE_FIRST_ITER  - (d1 only) seed from colortex8 + moments colortex9
//      DENOISE_SRC         - (d2/d3) colour+variance input from prev iteration
//      DENOISE_STEP        - kernel dilation for this iteration (1.0, 2.0, 4.0)
//  and the .fsh wrapper picks the output via its DRAWBUFFERS comment.
//  Output: .rgb = filtered irradiance, .a = filtered variance.
// ============================================================================

#if !defined(DENOISE_FIRST_ITER) && !defined(DENOISE_SRC)
    #error "d_denoise_common.glsl: define DENOISE_FIRST_ITER or DENOISE_SRC"
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
#ifdef DENOISE_FIRST_ITER
    uniform sampler2D colortex8;   // integrated irradiance (.rgb) + history length (.a)
    uniform sampler2D colortex9;   // linear depth (.r) + luminance moments (.g, .b)
#else
    uniform sampler2D DENOISE_SRC; // colour (.rgb) + variance (.a)
    #ifdef DENOISE_LAST_ITER
        uniform sampler2D colortex8;   // read history length (.a) to preserve it
    #endif
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

    vec4 outv;

    #ifdef DENOISE_FIRST_ITER
        vec4 c8 = texture(colortex8, texCoord);
        outv = vec4(c8.rgb, 0.0);
        #if defined(GI_DENOISE) && (defined(VOXEL_GI) || defined(VOXEL_AO))
            if (depthC < 1.0) {
                outv = svgfAtrousFirst(colortex8, colortex9, depthtex0, colortex1, texCoord,
                                       float(DENOISE_STEP), linDepth, depthGrad, nrm, c8.a, pxWorld);
            }
        #endif
    #else
        outv = texture(DENOISE_SRC, texCoord);
        #if defined(GI_DENOISE) && (defined(VOXEL_GI) || defined(VOXEL_AO))
            if (depthC < 1.0) {
                outv = svgfAtrous(DENOISE_SRC, depthtex0, colortex1, texCoord,
                                  float(DENOISE_STEP), linDepth, depthGrad, nrm, pxWorld);
            }
        #endif
    #endif

    #ifdef DENOISE_LAST_ITER
        // colortex8 still holds d0_restir's output this pass (we overwrite it below):
        //   .rgb = raw temporally-accumulated GI, .a = history length.
        vec4  c8      = texture(colortex8, texCoord);
        float histLen = c8.a;

        // ---- Displayed result (colortex6) ----
        // Default: the FULL variance-guided a-trous output (it denoises noisy pixels and,
        // because the history below is kept raw/detailed, naturally preserves converged
        // detail via its low-variance edge-stopping). DETAIL_PRESERVE is an optional extra
        // nudge that fades the spatial blur out as a pixel converges (more detail, less
        // denoise) — leave it off unless converged areas still look over-smoothed.
        vec3 displayColor = outv.rgb;
        #ifdef SVGF_DETAIL_PRESERVE
            float preserve = clamp(histLen / float(SVGF_PRESERVE_FRAMES), 0.0, 1.0)
                           * (float(SVGF_PRESERVE_MAX) / 100.0);
            displayColor = mix(outv.rgb, c8.rgb, preserve);
        #endif
        gl_FragData[0] = vec4(displayColor, outv.a);

        // ---- Temporal history feedback (colortex8) ----
        #ifdef SVGF_RAW_HISTORY
            // Keep the history as the RAW accumulated GI. Feeding the spatial blur back makes
            // colortex8 converge to the flattened signal over frames (with histLen->big the
            // new sample barely contributes) — that was baking distance/contrast flat. Raw
            // history keeps the detailed signal the a-trous filters fresh each frame.
            // (d4 still WRITES colortex8 -> ping-pong flip parity unchanged.)
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
