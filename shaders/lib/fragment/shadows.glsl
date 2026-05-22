#ifndef SHADOWS_GLSL
#define SHADOWS_GLSL

#ifndef FRAME_COUNTER_DECLARE
#define FRAME_COUNTER_DECLARE
uniform int frameCounter;
#endif


// Mathematically perfect PCSS Soft Shadows utilizing on-the-fly Vogel disk spirals

// High-performance manual bilinear depth comparison utilizing textureGather
float shadow2DLinear(sampler2D shadowTex, vec2 uv, float receiverDepth) {
    ivec2 texSize = textureSize(shadowTex, 0);
    vec2 f = fract(uv * vec2(texSize) - 0.5);
    
    // Gather 4 depth texels in a single instruction
    vec4 depths = textureGather(shadowTex, uv);
    vec4 comparisons = step(receiverDepth, depths);
    
    // Bilinear interpolation
    float shadowBottom = mix(comparisons.w, comparisons.z, f.x);
    float shadowTop = mix(comparisons.x, comparisons.y, f.x);
    return mix(shadowBottom, shadowTop, f.y);
}

vec3 getShadow() {
    vec4 worldPos = getWorldPosition();
    vec3 playerPos = worldPos.xyz;
    
    // Normal-based distance bias to fix shadow acne
    // We calculate NdotL strictly in view-space where both normal and lightVector match correctly.
    // Comparing a world-space normal against a view-space lightVector was causing NdotL to fluctuate
    // based on the camera's view angle, causing the shadow boundary lines to slide and rotate as you pan.
    float NdotL = max(dot(normal, lightVector), 0.0);
    
    float distanceBias = pow(dot(playerPos, playerPos), 0.75);
    distanceBias = 0.12 + 0.0008 * distanceBias;
    
    // We reconstruct the world normal from the view normal to apply the positional bias in world space
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3 positionBias = normalWorld * distanceBias * (2.0 - 0.95 * NdotL);
    
    // Push the player-relative world position along the normal
    worldPos.xyz += positionBias;
    
    vec4 shadowPos = toShadowSpace(worldPos);
    
    // Out of bounds check
    if (shadowPos.x < 0.0 || shadowPos.x > 1.0 || shadowPos.y < 0.0 || shadowPos.y > 1.0 || shadowPos.z < 0.0 || shadowPos.z > 1.0) {
        return vec3(1.0);
    }

    // 1. Solve the non-linear shadow map distortion factor closed-form directly from distorted coordinates.
    float distortedDist = length(shadowPos.xy * 2.0 - 1.0);
    float distortFactor = (1.0 - SHADOW_MAP_BIAS) / max(1.0 - distortedDist * SHADOW_MAP_BIAS, 0.0001);

    // 2. Calculate high-fidelity slope-scaled and resolution-aware depth bias.
    float cosTheta = max(dot(normal, lightVector), 0.0);
    float tanTheta = sqrt(1.0 - cosTheta * cosTheta) / max(cosTheta, 0.0001);
    
    float resolutionScale = 4096.0 / float(shadowMapResolution);
    float bias = (0.00012 + 0.0006 * clamp(tanTheta, 0.0, 5.0)) * distortFactor * resolutionScale;
    bias = clamp(bias, 0.00005, 0.004 * resolutionScale); 

    float receiverDepth = shadowPos.z - bias;

    #ifdef SHADOW_FILTER
        // 3. High-Frequency Temporal Dither using Interleaved Gradient Noise (perfect for TAA blending)
        // Snap to pixel coordinates. IGN requires integer coordinates to prevent moiré patterns.
        vec2 ditherCoord = floor(gl_FragCoord.xy);
        float ditherVal = interleavedGradientNoise(ditherCoord, frameCounter);
        float phi = ditherVal * 6.283185307179586;
        
        // Golden Angle constant (2.399963229728653 radians) for isotropic Vogel spiral distribution
        const float cosGold = -0.7373688220971415; // cos(2.399963229728653)
        const float sinGold = 0.6754902942615236;  // sin(2.399963229728653)

        // 4. Blocker Search Loop using 8 Vogel spiral taps with textureGather (total 32 depth checks!)
        int blockerSearchSteps = 8;
        float blockerSum = 0.0;
        int numBlockers = 0;
        // Tighter search radius for sharper contact shadows
        float searchRadius = 0.0006 / max(distortFactor, 0.001); 

        vec2 bDir = vec2(cos(phi), sin(phi));
        float rcpSqrtBlocker = 1.0 / sqrt(float(blockerSearchSteps));

        for (int i = 0; i < blockerSearchSteps; i++) {
            float r = sqrt(float(i) + ditherVal) * rcpSqrtBlocker;
            vec2 offset = bDir * r * searchRadius;
            vec4 gatheredDepths = textureGather(shadowtex0, shadowPos.xy + offset);
            
            // Check all 4 gathered depths per tap (total 32 samples)
            if (gatheredDepths.x < receiverDepth) { blockerSum += gatheredDepths.x; numBlockers++; }
            if (gatheredDepths.y < receiverDepth) { blockerSum += gatheredDepths.y; numBlockers++; }
            if (gatheredDepths.z < receiverDepth) { blockerSum += gatheredDepths.z; numBlockers++; }
            if (gatheredDepths.w < receiverDepth) { blockerSum += gatheredDepths.w; numBlockers++; }

            bDir = vec2(bDir.x * cosGold - bDir.y * sinGold, bDir.x * sinGold + bDir.y * cosGold);
        }

        // 5. Penumbra Estimation & PCF Filtering
        float penumbraScale = 0.015; // Significantly reduced scale for much sharper shadows over distance
        float minFilterRadius = 1.2 / (float(shadowMapResolution) * max(distortFactor, 0.001)); 
        float maxFilterRadius = 0.0015 / max(distortFactor, 0.001); // Halved max radius
        
        float filterRadius = minFilterRadius;
        
        if (numBlockers > 0) {
            float avgBlockerDepth = blockerSum / float(numBlockers);
            float penumbra = max(receiverDepth - avgBlockerDepth, 0.0);
            
            // Calculate absolute radius in UV space, clamped to our limits.
            // My previous attempt incorrectly mapped this to a 0-1 ratio, breaking the physics.
            float calculatedRadius = penumbra * penumbraScale / max(distortFactor, 0.001);
            filterRadius = clamp(calculatedRadius, minFilterRadius, maxFilterRadius);
            
            // Jitter the filter radius itself to break up concentric banding rings
            filterRadius *= mix(0.65, 1.35, ditherVal);
        }

        // Artistic Foliage adjustment
        if (material.x > 0.9) {
            filterRadius *= 1.5;
        }

        // Removed the dynamic early-out for numBlockers == 0.
        // Earlying out here causes a hard edge because it suddenly stops filtering 
        // the moment the center sample finds no blockers, even if the edge of the shadow 
        // should be smoothly blending.
        if (numBlockers == blockerSearchSteps * 4) {
            // Completely shadowed near-contact early-out is still relatively safe, 
            // but we must be careful. We'll leave it but make it stricter.
            float avgBlockerDepth = blockerSum / float(numBlockers);
            float penumbra = max(receiverDepth - avgBlockerDepth, 0.0);
            if (penumbra < 0.0001) {
                float shadow0 = shadow2DLinear(shadowtex0, shadowPos.xy, receiverDepth);
                float shadow1 = shadow2DLinear(shadowtex1, shadowPos.xy, receiverDepth);
                vec4 shadowCol = texture(shadowcolor0, shadowPos.xy);
                return mix(shadowCol.rgb * shadow1, vec3(1.0), shadow0);
            }
        }

        // 6. PCF Filter Loop using perfectly distributed Vogel Disk with smooth Gaussian-like weight falloff
        int pcfSamples = SHADOW_FILTER_QUALITY;
        vec3 finalShading = vec3(0.0);
        float weightSum = 0.0;

        // Initialize direction vector rotated by the dither angle
        vec2 dir = vec2(cos(phi), sin(phi));
        float rcpSqrtSamples = 1.0 / sqrt(float(pcfSamples));

        for (int i = 0; i < pcfSamples; i++) {
            float r = sqrt(float(i) + ditherVal) * rcpSqrtSamples;
            // Use a smoother Gaussian-like falloff for weights to prevent ringing at the edges
            float weight = exp(-3.0 * r * r); 
            vec2 offset = dir * r * filterRadius;

            float shadow0 = shadow2DLinear(shadowtex0, shadowPos.xy + offset, receiverDepth);
            float shadow1 = shadow2DLinear(shadowtex1, shadowPos.xy + offset, receiverDepth);
            vec4 shadowCol = texture(shadowcolor0, shadowPos.xy + offset);

            finalShading += mix(shadowCol.rgb * shadow1, vec3(1.0), shadow0) * weight;
            weightSum += weight;

            // Rotate the direction vector by the golden angle for the next sample
            dir = vec2(dir.x * cosGold - dir.y * sinGold, dir.x * sinGold + dir.y * cosGold);
        }

        finalShading /= max(weightSum, 0.0001);
        return finalShading;
    #else
        float shadow0 = shadow2DLinear(shadowtex0, shadowPos.xy, receiverDepth);
        float shadow1 = shadow2DLinear(shadowtex1, shadowPos.xy, receiverDepth);
        vec4 shadowCol = texture(shadowcolor0, shadowPos.xy);
        return mix(shadowCol.rgb * shadow1, vec3(1.0), shadow0);
    #endif
}

#endif