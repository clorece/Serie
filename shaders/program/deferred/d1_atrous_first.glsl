// d1_atrous_first : fused prefilter + first SVGF a-trous iteration (step 1).
// Replaces the old standalone d1_prefilter pass. Reads the accumulated GI
// (colortex8.rgb) and the moment buffer (colortex9.g/.b) DIRECTLY, bootstraps
// variance from the real moments (+ spatial estimate for short histories), and
// runs the first a-trous tap. Output: colortex3 = filtered GI (.rgb) + variance.
//
// Folding the prefilter into the first iteration removes a full-screen pass and
// is strictly more correct than the old prefilter (which approximated variance).

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

void main() {
    float depthC = texture(depthtex0, texCoord).r;
    if (depthC >= 1.0) {
        /* RENDERTARGETS: 3 */
        gl_FragData[0] = vec4(0.0);
        return;
    }

    float linDepth  = getDepth(depthC);
    vec2  depthGrad = vec2(dFdx(linDepth), dFdy(linDepth));
    vec3  nrm = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
    float pxWorld = 2.0 * gbufferProjectionInverse[1][1] * texelSize.y;

    float histLen = texture(colortex8, texCoord).a;

    vec4 outv = vec4(texture(colortex8, texCoord).rgb, 0.0);
    #if defined(GI_DENOISE) && (defined(VOXEL_GI) || defined(VOXEL_AO))
        outv = svgfAtrousFirst(colortex8, colortex9, depthtex0, colortex1, texCoord,
                               1.0, linDepth, depthGrad, nrm, histLen, pxWorld);
    #endif

    /* RENDERTARGETS: 3 */
    gl_FragData[0] = outv;
}

#endif
