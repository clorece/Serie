// d1_prefilter : firefly suppression and variance estimation
// Reads the accumulated GI (colortex8) and moments (colortex9).
// Suppresses fireflies with a 3x3 filter and bootstraps the variance channel
// for the SVGF a-trous chain.
//
// Output: colortex3 = filtered GI (.rgb) + variance (.a)

// TODO: optimizations

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

in vec2 texCoord;


#include "/lib/pt/denoise.glsl"

void main() {
    float depthC = texture(depthtex0, texCoord).r;
    if (depthC >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        return;
    }

    vec4  c8      = texture(colortex8, texCoord);
    float histLen = c8.a;
    vec4  cm      = texture(colortex9, texCoord);
    
    float cVar = varFromMoments(cm.g, cm.b);

    if (histLen < float(SVGF_VAR_BOOST)) {
        float sv = spatialLumaVariance(colortex8, texCoord);
        cVar = max(cVar, sv) * (1.0 + (float(SVGF_VAR_BOOST) - histLen));
    }

    vec3 sumC = vec3(0.0);
    float sumV = 0.0, wsum = 0.0;
    
    vec3 centerColor = c8.rgb;
    float centerLuma = luma(centerColor);
    float centerDepthRaw = texture(depthtex0, texCoord).r;
    float centerDepth = getDepth(centerDepthRaw);
    vec3 centerN = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
    
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec2 nUV = texCoord + vec2(x, y) * texelSize;
            vec4 n8  = textureLod(colortex8, nUV, 0.0);
            vec4 nm_sample = textureLod(colortex9, nUV, 0.0);
            
            float nLuma = luma(n8.rgb);
            
            float nVar = varFromMoments(nm_sample.g, nm_sample.b);
            if (n8.a < float(SVGF_VAR_BOOST)) {
                nVar = max(nVar, cVar);
            }
            
            float nDepthRaw = textureLod(depthtex0, nUV, 0.0).r;
            float nDepth = getDepth(nDepthRaw);
            vec3 nN = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
            
            float wDepth = exp(-abs(centerDepth - nDepth) * 10.0 / max(centerDepth, 0.01));
            float wNormal = pow(max(dot(centerN, nN), 0.0), 32.0);
            
            // Smooth based on luminance difference and local variance
            float lumaDiff = abs(nLuma - centerLuma);
            float wLuma = exp(-lumaDiff / (sqrt(max(cVar, 1e-4)) + 0.01));
            
            // Gaussian spatial weights
            float wSpatial = ((x == 0 && y == 0) ? 4.0 : (x == 0 || y == 0) ? 2.0 : 1.0);
            float w = wLuma * wSpatial * wDepth * wNormal;
            
            sumC += n8.rgb * w;
            sumV += nVar * w;
            wsum += w;
        }
    }
    
    vec3 filteredGI = sumC / max(wsum, 1e-5);
    float filteredVar = sumV / max(wsum, 1e-5);

    /* RENDERTARGETS: 3 */
    gl_FragData[0] = vec4(filteredGI, filteredVar);
}

#endif
