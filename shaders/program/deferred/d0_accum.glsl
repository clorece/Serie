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
uniform sampler2D colortex14;  // ReSTIR reservoir sampleNormal
uniform sampler2D colortex15;  // normal history
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
    
    // --- ReSTIR Spatial Reuse (Current Frame) ---
    // By doing spatial reuse in this pass, we can read the reservoirs written
    // by d0_restir.glsl on the CURRENT frame, fixing the geometric misalignment bug.
    #if defined(VOXEL_GI) && defined(RESTIR_GI) && defined(RESTIR_SPATIAL)
        uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter + 1);
        Reservoir shade = readReservoir(colortex10, colortex11, colortex14, texCoord);
        shade.wSum = luma(shade.radiance) * shade.W * shade.M;
        
        const float spDepthGate  = 0.10;
        const float spNormalGate = 0.8;
        
        for (int i = 0; i < RESTIR_SPATIAL_SAMPLES; i++) {
            float ang = randFloat(seed) * 6.2831853;
            float dist = sqrt(randFloat(seed)) * RESTIR_SPATIAL_RADIUS;
            vec2 nUV = texCoord + vec2(cos(ang), sin(ang)) * dist * texelSize;
            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;

            float nDepthRaw = texture(depthtex0, nUV).r;
            float actualNDepth = getDepth(nDepthRaw);
            if (abs(actualNDepth - linDepth) / max(linDepth, 0.001) > spDepthGate) continue;

            vec3 nNormal = normalize(texture(colortex1, nUV).rgb * 2.0 - 1.0);
            if (dot(normal, nNormal) < spNormalGate) continue;

            Reservoir n = readReservoir(colortex10, colortex11, colortex14, nUV);
            n.M = min(n.M, float(RESTIR_M_CAP));

            mergeReservoir(shade, n, 1.0, seed);
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
