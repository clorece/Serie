/*
    Atrous Wavelet Filter Library
    Requires: IsActivePixel(vec2) function to be defined before inclusion.
    Requires: colortex11 (GI/AO), colortex5 (Normal), colortex13 (Moments/History), depthtex0
*/

// Helper checks
bool IsValid_Atrous(float x) { return !isnan(x); }
bool IsValid_Atrous(vec3 v) { return !isnan(v.x) && !isnan(v.y) && !isnan(v.z); }
bool IsValid_Atrous(vec2 v) { return !isnan(v.x) && !isnan(v.y); }

float GetLuminance_Atrous(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

vec4 AtrousFilter(vec2 texCoord, int stepSize) {
    vec4 centerGIData = texture2D(colortex11, texCoord);
    vec3 centerGI = centerGIData.rgb;
    float centerAO = centerGIData.a;

    if (!IsValid_Atrous(centerGI)) centerGI = vec3(0.0);
    if (!IsValid_Atrous(centerAO)) centerAO = 0.0;

    float z0 = texture2D(depthtex0, texCoord).r;
    float centerDepth = GetLinearDepth(z0);
    vec3 centerNormal = normalize(mat3(gbufferModelView) * texture2D(colortex5, texCoord).rgb);
    if (!IsValid_Atrous(centerNormal)) centerNormal = vec3(0.0, 0.0, 1.0);

    float centerLum = GetLuminance_Atrous(centerGI);

    float stepScale = 1.0 / max(1.0, float(stepSize) * 0.5);

    // Variance-guided luminance threshold (Schied et al. 2017 SVGF eq. 9)
    vec2 moments = texture2D(colortex13, texCoord).gb;
    float variance = max(moments.y - moments.x * moments.x, 0.0);
    float phiColor = 0.45 * stepScale * max(1.0, sqrt(variance));

    float phiNormal = 128.0;
    float phiDepth = 0.5;
    
    float kWeights[2]; 
    kWeights[0] = 0.5;
    kWeights[1] = 0.25;

    vec3 giAccum = centerGI * 0.25; 
    float aoAccum = centerAO * 0.25;
    float weightSum = 0.25;

    vec2 filterStepSize = vec2(float(stepSize * DENOISER_STEP_SIZE)) / vec2(viewWidth, viewHeight);

    // 3. Filter Loop (3x3) - Skipping center (0,0)
    for (int y = -1; y <= 1; y++) {
        float ky = kWeights[abs(y)];
        
        for (int x = -1; x <= 1; x++) {
            if (x == 0 && y == 0) continue; // Already added center

            float k = kWeights[abs(x)] * ky;
            
            vec2 offset = vec2(x, y) * filterStepSize;
            vec2 sampleCoord = texCoord + offset;
            
            // Bounds check
            if ( clamp(sampleCoord, 0.0, 1.0) != sampleCoord ) continue;

            // Active Pixel check
            if (!IsActivePixel(sampleCoord * vec2(viewWidth, viewHeight))) continue;

            vec4 sampleGIData = texture2D(colortex11, sampleCoord);
            vec3 sampleGI = sampleGIData.rgb;
            if (!IsValid_Atrous(sampleGI)) sampleGI = vec3(0.0);
            
            float sampleAO = sampleGIData.a;

            vec3 sampleNormal = normalize(mat3(gbufferModelView) * texture2D(colortex5, sampleCoord).rgb);
            float sampleDepth = GetLinearDepth(texture2D(depthtex0, sampleCoord).r);

            // Edge Stopping
            
            // Normal - Optimization: fast reject
            float dotN = dot(centerNormal, sampleNormal);
            if (dotN < 0.9) continue; 
            float wNormal = pow(dotN, phiNormal);

            // Depth
            float wDepth = 0.0;
            float diffDepth = abs(centerDepth - sampleDepth);
            
            // Adaptive depth threshold
            float distBase = max(length(vec2(x, y)) * 0.01, 1e-5); 
            if (diffDepth * far < 0.5 * (1.0 + abs(x) + abs(y))) {
                wDepth = exp(-diffDepth / (phiDepth * distBase + 1e-5));
            } else {
                 continue; 
            }

            // Luminance
            float sampleLum = GetLuminance_Atrous(sampleGI);
            float wColor = exp(-abs(centerLum - sampleLum) / phiColor);

            // Combined Weight
            float w = wNormal * wDepth * wColor;

            float finalWeight = w * k;

            giAccum += sampleGI * finalWeight;
            aoAccum += sampleAO * finalWeight;
            weightSum += finalWeight;
        }
    }

    if (weightSum > 0.001) {
        return vec4(giAccum / weightSum, aoAccum / weightSum);
    } else {
        return vec4(centerGI, centerAO);
    }
}
