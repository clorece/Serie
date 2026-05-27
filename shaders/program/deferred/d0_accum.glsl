// ============================================================================
//  d0_accum : spatiotemporal accumulation for indirect light
// ----------------------------------------------------------------------------
//  Reads the noisy raw GI from d0_restir (colortex3) and blends it with the
//  history (colortex8) using bilateral reprojection and YCoCg neighborhood
//  clamping to suppress ghosting.
//
//  Output: colortex8 = accumulated GI (.rgb) + history length (.a)
//          colortex9 = linear depth (.r) + luminance moments (.g, .b)
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
#include "/lib/util/jitter.glsl"
#include "/lib/pt/denoise.glsl"

in vec2 texCoord;

uniform sampler2D colortex1;   // normals
uniform sampler2D colortex2;   // lightmap
uniform sampler2D colortex3;   // raw noisy GI (from d0_restir)
uniform sampler2D colortex6;   // raw moments (from d0_restir)
uniform sampler2D colortex8;   // GI history
uniform sampler2D colortex9;   // moments history
uniform sampler2D colortex10;  // ReSTIR reservoir radiance/M
uniform sampler2D colortex11;  // ReSTIR reservoir samplePos/W
uniform sampler2D colortex14;  // irradiance cache atlas (used for spatial-reject fallback)
uniform sampler2D colortex15;  // .xy primary normal hist + .zw reservoir sample normal hist
uniform sampler2D depthtex0;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;

vec3 clipSpace;
#include "/lib/util/positions.glsl"
#include "/lib/pt/restir.glsl"
#include "/lib/pt/ircache.glsl"

vec3 getNeighborWorldPosition(vec2 nUV, float nDepthRaw) {
    vec3 viewPos = convertScreenSpaceToWorldSpace(nUV, nDepthRaw);
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

float calculateJacobian(vec3 shadingPos, vec3 neighborShadingPos, vec3 samplePos, vec3 sampleNormal) {
    vec3 vOriginal = samplePos - neighborShadingPos;
    vec3 vNew      = samplePos - shadingPos;
    
    float dOriginal2 = dot(vOriginal, vOriginal);
    float dNew2      = dot(vNew, vNew);
    
    // Footprint-based threshold: if the sample is extremely close to either shading point,
    // the shift mapping is unstable. Reject by returning 0.0.
    if (dOriginal2 < 0.01 || dNew2 < 0.01) return 0.0;
    
    float dOriginal = sqrt(dOriginal2);
    float dNew      = sqrt(dNew2);
    
    float cosOriginal = abs(dot(sampleNormal, vOriginal)) / dOriginal;
    float cosNew      = abs(dot(sampleNormal, vNew)) / dNew;
    
    // Footprint-based threshold: if the path is almost parallel to the surface (grazing),
    // reconnection is extremely unstable. Reject.
    if (cosOriginal < 0.05 || cosNew < 0.05) return 0.0;
    
    float jacobian = (cosNew * dOriginal2) / (cosOriginal * dNew2);
    
    // Clamp Jacobian to a safe range to prevent fireflies/spikes
    return clamp(jacobian, 0.1, 10.0);
}

vec2 getUniformOffset(int sampleIdx, int frame) {
    uint seedX = pcgHash(uint(frame) * 7U + uint(sampleIdx) * 101U);
    uint seedY = pcgHash(uint(frame) * 13U + uint(sampleIdx) * 197U);
    
    float randX = float(seedX >> 8u) * (1.0 / float(1u << 24u));
    float randY = float(seedY >> 8u) * (1.0 / float(1u << 24u));
    
    float ang = randX * 6.2831853;
    float dist = sqrt(randY) * RESTIR_SPATIAL_RADIUS;
    
    return vec2(cos(ang), sin(ang)) * dist;
}

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    vec2 uvUnjittered = texCoord - currentJitter;
    float depth0 = texture(depthtex0, uvUnjittered).r;
    
    if (depth0 >= 1.0) {
        gl_FragData[0] = vec4(0.0);
        gl_FragData[1] = vec4(1.0, 0.0, 0.0, 1.0);
        return;
    }

    clipSpace = vec3(uvUnjittered, depth0) * 2.0 - 1.0;
    float linDepth = getDepth(depth0);

    vec3  normal = normalize(texture(colortex1, uvUnjittered).rgb * 2.0 - 1.0);
    vec3  normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3  worldRel = getWorldPosition().xyz;
    
    vec3  rawGI = texture(colortex3, texCoord).rgb;
    
    // --- ReSTIR Spatial Reuse (Current Frame) with Stochastic Pairwise MIS (SPMIS) ---
    // By doing spatial reuse in this pass, we can read the reservoirs written
    // by d0_restir.glsl on the CURRENT frame, fixing the geometric misalignment bug.
    #if defined(VOXEL_GI) && defined(RESTIR_GI) && defined(RESTIR_SPATIAL)
        uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter + 1);
        Reservoir shade = readReservoir(colortex10, colortex11, colortex15,texCoord);
        shade.wSum = luma(shade.radiance) * shade.W * shade.M;
        
        const float spDepthGate  = 0.10;
        const float spNormalGate = 0.8;
        
        // Large-kernel parameters for Stochastic Pairwise MIS
        float M_total = 3.14159265 * RESTIR_SPATIAL_RADIUS * RESTIR_SPATIAL_RADIUS;
        float N_tilde = float(RESTIR_SPATIAL_SAMPLES);
        
        // Defensive Canonical Weighting: scale initial weight sum of the canonical reservoir
        shade.wSum *= (M_total - 1.0) / M_total;
        shade.M    *= (M_total - 1.0) / M_total;
        
        // Adaptive view-aligned depth gate: widens the gate on grazing surfaces
        // where depth changes rapidly, preventing false spatial rejection.
        float cosView = abs(dot(normalWorld, normalize(worldRel)));
        float adaptiveDepthGate = spDepthGate * (1.0 + 2.0 * (1.0 - cosView));
        
        for (int i = 0; i < RESTIR_SPATIAL_SAMPLES; i++) {
            // Reciprocal Neighbor Selection: generate a screen-uniform random offset
            vec2 uniformOffset = getUniformOffset(i, frameCounter);
            ivec2 delta = ivec2(round(uniformOffset));
            
            // Avoid choosing ourselves
            if (delta.x == 0 && delta.y == 0) {
                delta.x = 1;
            }
            
            // XOR-based reciprocal neighbor selection
            ivec2 p = ivec2(gl_FragCoord.xy);
            ivec2 q = p ^ delta;
            vec2 nUV = (vec2(q) + 0.5) * texelSize;
            
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            float nDepthRaw = texture(depthtex0, nUV).r;
            float actualNDepth = getDepth(nDepthRaw);
            if (abs(actualNDepth - linDepth) / max(linDepth, 0.001) > adaptiveDepthGate) continue;

            vec3 nNormal = normalize(texture(colortex1, nUV).rgb * 2.0 - 1.0);
            if (dot(normal, nNormal) < spNormalGate) continue;

            Reservoir n = readReservoir(colortex10, colortex11, colortex15,nUV);
            
            // De-duplication: if the neighbor holds the exact same sample,
            // we down-weight its confidence to 0 to prevent artificial inflation and correlation noise.
            if (distance(n.samplePos, shade.samplePos) < 0.01) {
                n.M = 0.0;
            }
            
            n.M = min(n.M, float(RESTIR_M_CAP));

            float jacobian = 1.0;
            #ifdef RESTIR_JACOBIAN
                // Reconstruct neighbor's camera-relative world position
                vec3 nWorldRel = getNeighborWorldPosition(nUV, nDepthRaw);
                jacobian = calculateJacobian(worldRel, nWorldRel, n.samplePos, n.sampleNormal);
            #endif

            // --- Stochastic Pairwise MIS weighting ---
            float p_hat_i = luma(n.radiance);
            float p_hat_c = luma(n.radiance) * jacobian;
            
            // Pairwise MIS weight
            float m_i = p_hat_c / (p_hat_c + p_hat_i / (M_total - 1.0) + 1e-5);
            
            // Stochastic factor scaling
            float stochastic_factor = (M_total / N_tilde) * m_i;
            
            // Scale both the neighbor sample contribution and confidence M
            float weight = p_hat_c * n.W * n.M * stochastic_factor;
            
            shade.wSum += weight;
            shade.M    += n.M * m_i;
            
            if (randFloat(seed) * shade.wSum < weight) {
                shade.radiance     = n.radiance;
                shade.samplePos    = n.samplePos;
                shade.sampleNormal = n.sampleNormal;
            }
        }
        finalizeReservoir(shade);
        rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);
    #endif
    
    // --- Pre-Accumulation Firefly / Outlier Rejection ---
    // We must check depth and normals so we don't accidentally blur
    // the dark background into the bright foreground edges.
    vec3 neighborSum = vec3(0.0);
    float neighborWeight = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            if (x == 0 && y == 0) continue;
            vec2 nUV = texCoord + vec2(x, y) * texelSize;
            
            float nDepth0 = textureLod(depthtex0, nUV, 0.0).r;
            float nLinDepth = getDepth(nDepth0);
            vec3 nNormal = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
            
            // Strictly reject pixels on different depth planes or surfaces
            if (abs(nLinDepth - linDepth) < 0.1 * linDepth && dot(normal, nNormal) > 0.8) {
                neighborSum += textureLod(colortex3, nUV, 0.0).rgb;
                neighborWeight += 1.0;
            }
        }
    }
    
    float centerLumaRaw = dot(rawGI, vec3(0.2126, 0.7152, 0.0722));
    float neighborLuma = centerLumaRaw; // Default to center if no neighbors valid
    
    if (neighborWeight > 0.1) {
        vec3 neighborAvg = neighborSum / neighborWeight;
        neighborLuma = dot(neighborAvg, vec3(0.2126, 0.7152, 0.0722));
        
        // If the center pixel is drastically brighter than its VALID neighbors, clamp it.
        if (centerLumaRaw > neighborLuma * 3.0 + 0.02) {
            rawGI = neighborAvg; 
        }
    }

    vec4  p6    = texture(colortex6, texCoord);
    float lr    = dot(rawGI, vec3(0.2126, 0.7152, 0.0722)); // Use clamped luma for moments

    // Reproject
    vec3 worldPrevRel = worldRel;
    bool isHand = depth0 < 0.56; // Standard hand depth threshold
    
    vec2 uvPrev;
    float expectedClipZ;
    if (isHand) {
        // The hand moves with the camera. Its screen-space position is roughly static.
        // If we apply world-space reprojection, it will smear massively when rotating the camera.
        uvPrev = texCoord;
        expectedClipZ = clipSpace.z;
    } else {
        worldPrevRel += (cameraPosition - previousCameraPosition);
        vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
        vec4 clipPrev = gbufferPreviousProjection * viewPrev;
        uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
        uvPrev += prevJitter;
        expectedClipZ = clipPrev.z / clipPrev.w;
    }

    vec3  blendedGI = rawGI;
    float giHist    = 1.0;
    float giM1      = lr;
    float giM2      = lr * lr;

    // Tighten screen bounds to prevent bilinear/fetch sampling off the edge of the screen
    vec2 padding = 1.5 * texelSize;
    bool validReproj = all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding));

    if (validReproj) {
        vec4 prev8, p9_tmp;
        if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, prev8, p9_tmp)) {
            if (prev8.a > 0.5) {
                giHist = min(prev8.a + 1.0, float(GI_ACCUM_FRAMES));

                // 1. Box Clamping (YCoCg) - Modern anti-ghosting
                vec3 clampedHistory = clipHistory(prev8.rgb, rawGI, colortex3, texCoord);

                // 2. Variance-based rejection (Controlled by GI_TEMPORAL_REJECT)
                // We use the 'neighborLuma' (3x3 spatial average) to detect lighting changes.
                // Comparing raw 1spp noise to the history will constantly trigger false rejections,
                // preventing the accumulation from ever smoothing out.
                float prevStd = sqrt(max(p9_tmp.b - p9_tmp.g * p9_tmp.g, 0.0));
                float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9_tmp.g + 0.01;
                float reject  = clamp((abs(neighborLuma - p9_tmp.g) - tol) / (tol + 1e-3), 0.0, 1.0);

                // Motion-based history rejection
                float motion = length(cameraPosition - previousCameraPosition);
                reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);
                
                // If the history was heavily clamped (meaning a massive lighting change occurred),
                // we should reduce the history length so the variance moments can adapt faster.
                float clampDiff = length(prev8.rgb - clampedHistory) / max(luma(prev8.rgb), 0.001);
                reject = max(reject, clamp(clampDiff * 0.5, 0.0, 0.8));
                
                reject *= reject; // Smooth the rejection curve

                giHist = mix(giHist, 1.0, reject);
                float a = 1.0 / giHist;

                blendedGI = mix(clampedHistory, rawGI, a);
                // Track the raw variance so the GI_TEMPORAL_REJECT macro works properly
                giM1 = mix(p9_tmp.g, lr, a);
                giM2 = mix(p9_tmp.b, lr * lr, a);
            }
        }
    }

    /* RENDERTARGETS: 8,9 */
    gl_FragData[0] = vec4(blendedGI, giHist);
    gl_FragData[1] = vec4(depth0, giM1, giM2, 1.0);
}

#endif
