// ============================================================================
//  d1_prefilter : firefly suppression and variance estimation
// ----------------------------------------------------------------------------
//  Reads the accumulated GI (colortex8) and moments (colortex9).
//  Suppresses fireflies with a 3x3 filter and bootstraps the variance channel
//  for the SVGF a-trous chain.
//
//  Output: colortex3 = filtered GI (.rgb) + variance (.a)
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

uniform sampler2D colortex1;   // normals
uniform sampler2D colortex8;   // accumulated GI (.rgb) + history length (.a)
uniform sampler2D colortex9;   // linear depth (.r) + luminance moments (.g, .b)
uniform sampler2D depthtex0;

void main() {
    float depthC = texture(depthtex0, texCoord).r;
    if (depthC >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        return;
    }

    vec4  c8      = texture(colortex8, texCoord);
    float histLen = c8.a;
    vec4  cm      = texture(colortex9, texCoord);
    
    // 1. Initial variance estimate from temporal moments
    float cVar = varFromMoments(cm.g, cm.b);
    
    // 2. Bootstrap variance spatially if history is short
    if (histLen < float(SVGF_VAR_BOOST)) {
        float sv = spatialLumaVariance(colortex8, texCoord);
        cVar = max(cVar, sv) * (1.0 + (float(SVGF_VAR_BOOST) - histLen));
    }

    // 3. Lightweight Firefly Prefilter & Variance Stabilization (3x3)
    // We use a small weighted blur to suppress outliers and stabilize the variance
    // channel before it enters the a-trous chain.
    vec3 sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;
    
    vec3 centerColor = c8.rgb;
    float centerLuma = luma(centerColor);
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 nUV = texCoord + vec2(x, y) * texelSize;
            vec4 n8  = textureLod(colortex8, nUV, 0.0);
            vec4 nm_sample = textureLod(colortex9, nUV, 0.0);
            
            float nLuma = luma(n8.rgb);
            float nVar  = varFromMoments(nm_sample.g, nm_sample.b);
            
            // Firefly suppression: down-weight samples that are much brighter than the center
            float fw = 1.0 / (1.0 + max(nLuma - centerLuma * 2.0, 0.0));
            float w = fw * ((x == 0 && y == 0) ? 4.0 : (x == 0 || y == 0) ? 2.0 : 1.0);
            
            sumC += n8.rgb * w;
            sumV += nVar * w;
            wsum += w;
        }
    }
    
    vec3 filteredGI = sumC / wsum;
    float filteredVar = sumV / wsum;

    /* RENDERTARGETS: 3 */
    gl_FragData[0] = vec4(filteredGI, filteredVar);
}

#endif
