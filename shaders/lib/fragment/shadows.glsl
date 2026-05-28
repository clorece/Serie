#ifndef SHADOWS_GLSL
#define SHADOWS_GLSL

#ifndef FRAME_COUNTER_DECLARE
#define FRAME_COUNTER_DECLARE
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

vec3 getShadow(float material) {
    vec4 worldPos = getWorldPosition();
    vec3 playerPos = worldPos.xyz;
    
    // NdotL strictly in view-space (normal and lightVector both view-space here) so the
    // shadow boundary doesn't slide/rotate as the camera pans.
    float NdotL = max(dot(normal, lightVector), 0.0);

    float distance = length(playerPos);

    // World-space face normal used for the positional bias.
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);

    // Positional shadow bias without peter-panning: push along the surface normal only
    // (never along the light vector — that detaches the shadow and leaks light at contact
    // edges). Scales mildly with distance, and grazing faces (NdotL -> 0, where acne is
    // worst) get up to ~2x the bias of sun-facing faces.
    vec3 bias = 0.25 * normalWorld * clamp(0.12 + 0.01 * distance, 0.0, 1.0) * (2.0 - clamp(NdotL, 0.0, 1.0));

    // Edge nudge: shift the lookup toward the interior of the block it belongs to — up to
    // ~0.1 blocks per axis at the faces, zero at the centre. A receiver sitting on a block
    // seam then tests a point safely inside its occluder instead of leaking sun through the
    // gap. Scaled by (1 - skylight) so it only kicks in for enclosed/dark surfaces where
    // leaks happen; in open sky it is zero and never displaces outdoor shadows.
    vec3 edge = (0.1 - 0.2 * fract(playerPos + cameraPosition + normalWorld * 0.01)) * (1.0 - lightmap.y);

    playerPos += bias + edge;

    worldPos.xyz = playerPos;

    vec4 shadowPos = toShadowSpace(worldPos);
    
    // Out of bounds check
    if (shadowPos.x < 0.0 || shadowPos.x > 1.0 || shadowPos.y < 0.0 || shadowPos.y > 1.0 || shadowPos.z < 0.0 || shadowPos.z > 1.0) {
        return vec3(1.0);
    }

    // 1. Solve the non-linear shadow map distortion factor closed-form directly from distorted coordinates.
    float distortedDist = length(shadowPos.xy * 2.0 - 1.0);
    float distortFactor = (1.0 - SHADOW_MAP_BIAS) / max(1.0 - distortedDist * SHADOW_MAP_BIAS, 0.0001);

    // 2. Small constant depth bias only. The positional normal + edge bias above prevent
    // acne; adding a large slope-scaled depth bias on top peter-pans and leaks light
    // through block seams, so it is intentionally kept tiny here.
    float resolutionScale = 4096.0 / float(shadowMapResolution);
    float receiverDepth = shadowPos.z - 0.00006 * resolutionScale;

    // Subsurface scattering offset for foliage.
    if (material > 0.16 && material < 0.83) {
        receiverDepth -= 0.000175;
    }

    #ifdef SHADOW_FILTER
        // 3. High-Frequency Temporal Dither using Interleaved Gradient Noise (perfect for TAA blending)
        // Snap to pixel coordinates. IGN requires integer coordinates to prevent moiré patterns.
        vec2 ditherCoord = floor(gl_FragCoord.xy);
        float ditherVal = interleavedGradientNoise(ditherCoord, frameCounter);
        float phi = ditherVal * 6.283185307179586;
        
        // Golden Angle constant (2.399963229728653 radians) for isotropic Vogel spiral distribution
        const float cosGold = -0.7373688220971415; // cos(2.399963229728653)
        const float sinGold = 0.6754902942615236;  // sin(2.399963229728653)

        // A physically accurate solar angular diameter is ~0.53 degrees, which gives a tangent of ~0.0092
        float penumbraScale = 0.0092; 
        float minFilterRadius = 0.375 / (float(shadowMapResolution) * max(distortFactor, 0.001)); 
        float maxFilterRadius = 0.0015 / max(distortFactor, 0.001); 

        // 4. Blocker Search
        // Blocker search radius MUST match maxFilterRadius to prevent sharp cutoffs at the edge 
        // of wide penumbrae, otherwise the filter snaps to minimum radius when the search misses.
        int blockerSearchSteps = 16; // Increased to 16 (64 taps) to prevent missing thin objects in the wide search area
        float blockerSum = 0.0;
        int numBlockers = 0;
        float searchRadius = maxFilterRadius; 

        vec2 bDir = vec2(cos(phi), sin(phi));
        float rcpSqrtBlocker = 1.0 / sqrt(float(blockerSearchSteps));

        for (int i = 0; i < blockerSearchSteps; i++) {
            float r = sqrt(float(i) + ditherVal) * rcpSqrtBlocker;
            vec2 offset = bDir * r * searchRadius;
            vec4 gatheredDepths = textureGather(shadowtex0, shadowPos.xy + offset);
            
            // Check all 4 gathered depths per tap (total 64 samples)
            if (gatheredDepths.x < receiverDepth) { blockerSum += gatheredDepths.x; numBlockers++; }
            if (gatheredDepths.y < receiverDepth) { blockerSum += gatheredDepths.y; numBlockers++; }
            if (gatheredDepths.z < receiverDepth) { blockerSum += gatheredDepths.z; numBlockers++; }
            if (gatheredDepths.w < receiverDepth) { blockerSum += gatheredDepths.w; numBlockers++; }

            bDir = vec2(bDir.x * cosGold - bDir.y * sinGold, bDir.x * sinGold + bDir.y * cosGold);
        }

        // 5. Penumbra Estimation & PCF Filtering
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
        if (material > 0.16 && material < 0.83) {
            // Force a large minimum blur radius for subsurface scattering
            // to prevent sharp self-shadowing from nearby leaves.
            filterRadius = max(filterRadius, maxFilterRadius * 0.8);
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
