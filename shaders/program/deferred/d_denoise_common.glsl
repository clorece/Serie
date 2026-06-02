// d_denoise_common : one SVGF a-trous iteration
// The including pass sets:
//     DENOISE_SRC         - colour+variance input from prev iteration
//     DENOISE_STEP        - kernel dilation for this iteration
//     DENOISE_LAST_ITER   - (optional) write to history (colortex8)
// and the .fsh wrapper picks the output via its DRAWBUFFERS comment.
// Output: .rgb = filtered irradiance, .a = filtered variance.

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


#ifdef DENOISE_LAST_ITER
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

    // accumulated temporal history length (colortex8.a) — preserved into the
    // history feedback (last iter), and used by the optional early-out /
    // detail-preserve blend.
    float histLen = texture(colortex8, texCoord).a;

    vec4 outv = texture(DENOISE_SRC, texCoord);
    #if defined(GI_DENOISE) && (defined(VOXEL_GI) || defined(VOXEL_AO))
        // The a-trous spatial filter runs on EVERY surface pixel. (SVGF_EARLY_OUT,
        // off by default, would skip it on long-converged pixels — but at 1 spp
        // the temporal mean still carries spatial noise, so that leaves the static
        // image undenoised while only in-motion pixels get filtered.)
        if (depthC < 1.0
            #ifdef SVGF_EARLY_OUT
                && histLen <= 48.0
            #endif
        ) {
            outv = svgfAtrous(DENOISE_SRC, depthtex0, colortex1, texCoord,
                              float(DENOISE_STEP), linDepth, depthGrad, nrm, pxWorld);
        }
    #endif

    #ifdef DENOISE_LAST_ITER
        // colortex8 holds the RAW accumulated GI + history length (histLen,
        // already read above) from d0_accum.
        vec4  c8 = texture(colortex8, texCoord);

        // Displayed result (colortex6 or colortex8 via DRAWBUFFERS)
        vec3 displayColor = outv.rgb;
        #ifdef SVGF_DETAIL_PRESERVE
            float preserve = clamp(histLen / float(SVGF_PRESERVE_FRAMES), 0.0, 1.0)
                           * (float(SVGF_PRESERVE_MAX) / 100.0);
            displayColor = mix(outv.rgb, c8.rgb, preserve);
        #endif
        gl_FragData[0] = vec4(displayColor, outv.a);

        // Temporal history feedback (colortex8)
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
