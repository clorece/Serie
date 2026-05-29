// d0_accum : spatiotemporal accumulation for indirect light
// reads the noisy raw GI from d0_restir (colortex3) and blends it with the
// history (colortex8) using bilateral reprojection and YCoCg neighborhood
// clamping to suppress ghosting.
//
// Output: colortex8 = accumulated GI (.rgb) + history length (.a)
//         colortex9 = linear depth (.r) + luminance moments (.g, .b)

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

in vec2 texCoord;



#include "/lib/pt/denoise.glsl"

vec3 clipSpace;
#include "/lib/util/positions.glsl"
#include "/lib/pt/restir.glsl"

vec3 getNeighborWorldPosition(vec2 nUV, float nDepthRaw) {
    vec3 viewPos = convertScreenSpaceToWorldSpace(nUV, nDepthRaw);
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

float calculateJacobian(vec3 shadingPos, vec3 neighborShadingPos, vec3 samplePos, vec3 sampleNormal) {
    vec3 vOriginal = samplePos - neighborShadingPos;
    vec3 vNew      = samplePos - shadingPos;
    
    float dOriginal2 = dot(vOriginal, vOriginal);
    float dNew2      = dot(vNew, vNew);

    if (dOriginal2 < 0.01 || dNew2 < 0.01) return 1.0;
    
    float dOriginal = sqrt(dOriginal2);
    float dNew      = sqrt(dNew2);
    
    float cosOriginal = abs(dot(sampleNormal, vOriginal)) / dOriginal;
    float cosNew      = abs(dot(sampleNormal, vNew)) / dNew;

    if (cosOriginal < 0.05 || cosNew < 0.05) return 1.0;
    
    float jacobian = (cosNew * dOriginal2) / (cosOriginal * dNew2);

    return clamp(jacobian, 0.05, 20.0);
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
    float rawAO = texture(colortex14, texCoord).w;
    
    vec3 neighborSum = vec3(0.0);
    float neighborWeight = 0.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            if (x == 0 && y == 0) continue;
            vec2 nUV = texCoord + vec2(x, y) * texelSize;
            

            if (nUV.x < 0.0 || nUV.x > 1.0 || nUV.y < 0.0 || nUV.y > 1.0) continue;
            
            float nDepth0 = textureLod(depthtex0, nUV, 0.0).r;
            float nLinDepth = getDepth(nDepth0);
            vec3 nNormal = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
            
            if (abs(nLinDepth - linDepth) < 0.1 * linDepth && dot(normal, nNormal) > 0.8) {
                neighborSum += textureLod(colortex3, nUV, 0.0).rgb;
                neighborWeight += 1.0;
            }
        }
    }
    float centerLumaRaw = dot(rawGI, vec3(0.2126, 0.7152, 0.0722));
    float neighborLuma = centerLumaRaw;
    if (neighborWeight > 0.1) {
        vec3 neighborAvg = neighborSum / neighborWeight;
        neighborLuma = dot(neighborAvg, vec3(0.2126, 0.7152, 0.0722));
        
        // if the center pixel is drastically brighter than its VALID neighbors, clamp it.
        if (centerLumaRaw > neighborLuma * 3.0 + 0.02) {
            rawGI = neighborAvg; 
        }
    }
    
    #if defined(VOXEL_GI) && defined(RESTIR_GI) && defined(RESTIR_SPATIAL)
        uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter + 1);
        Reservoir shade = readReservoir(colortex10, colortex11, colortex14, texCoord);
        shade.wSum = luma(shade.radiance) * shade.W * shade.M;
        
        const float spDepthGate  = 0.10; // 10% relative depth
        const float spNormalGate = 0.90; // Approx 25 degrees

        vec2 paddingSpatial = 2.0 * texelSize;
        
        int spatialSamples = RESTIR_SPATIAL_SAMPLES;
        if (shade.M > float(RESTIR_M_CAP) * 0.8) {
            spatialSamples = 0; // fully converged: skip spatial
        } else if (shade.M > float(RESTIR_M_CAP) * 0.4) {
            spatialSamples = min(RESTIR_SPATIAL_SAMPLES, 1); // partially converged: scale down
        }
        
        for (int i = 0; i < spatialSamples; i++) {
            vec2 uniformOffset = getUniformOffset(i, frameCounter);
            ivec2 delta = ivec2(round(uniformOffset));
            
            if (delta.x == 0 && delta.y == 0) {
                delta.x = 1;
            }
            
            ivec2 p = ivec2(gl_FragCoord.xy);
            ivec2 q = p ^ delta;
            vec2 nUV = (vec2(q) + 0.5) * texelSize;

            if (nUV.x < paddingSpatial.x || nUV.x > 1.0 - paddingSpatial.x || 
                nUV.y < paddingSpatial.y || nUV.y > 1.0 - paddingSpatial.y) continue;


            float nDepthRaw = textureLod(depthtex0, nUV, 0.0).r;
            float actualNDepth = getDepth(nDepthRaw);
            if (abs(actualNDepth - linDepth) / max(linDepth, 0.001) > spDepthGate) continue;


            vec3 nNormal = normalize(textureLod(colortex1, nUV, 0.0).rgb * 2.0 - 1.0);
            if (dot(normal, nNormal) < spNormalGate) continue;

            Reservoir n = readReservoir(colortex10, colortex11, colortex14, nUV);
            n.M = min(n.M, float(RESTIR_M_CAP));

            mergeReservoir(shade, n, 1.0, seed);
        }
        finalizeReservoir(shade);
        rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);
    #endif

    float lr    = dot(rawGI, vec3(0.2126, 0.7152, 0.0722)); // Use clamped luma for moments


    vec3 worldPrevRel = worldRel;
    bool isHand = depth0 < 0.56;
    
    vec2 uvPrev;
    float expectedClipZ;
    if (isHand) {
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
    float blendedAO = rawAO;

    vec2 padding = 1.5 * texelSize;
    bool validReproj = all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding));

    if (validReproj) {
        vec4 prev8, p9_tmp;
        if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, prev8, p9_tmp)) {
            if (prev8.a > 0.5) {
                giHist = min(prev8.a + 1.0, float(GI_ACCUM_FRAMES));

                vec3 clampedHistory = clipHistory(prev8.rgb, rawGI, colortex3, texCoord);
                float prevStd = sqrt(max(p9_tmp.b - p9_tmp.g * p9_tmp.g, 0.0));
                float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9_tmp.g + 0.01;
                float reject  = clamp((abs(neighborLuma - p9_tmp.g) - tol) / (tol + 1e-3), 0.0, 1.0);


                float motion = length(cameraPosition - previousCameraPosition);
                reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);
                
                float clampDiff = length(prev8.rgb - clampedHistory) / max(luma(prev8.rgb), 0.001);
                reject = max(reject, clamp(clampDiff * 0.5, 0.0, 0.8));
                
                reject *= reject; 

                giHist = mix(giHist, 1.0, reject);
                float a = 1.0 / giHist;

                blendedGI = mix(clampedHistory, rawGI, a);
                giM1 = mix(p9_tmp.g, lr, a);
                giM2 = mix(p9_tmp.b, lr * lr, a);

                blendedAO = mix(p9_tmp.a, rawAO, a);
            }
        }
    }

    /* RENDERTARGETS: 8,9 */
    gl_FragData[0] = vec4(blendedGI, giHist);
    gl_FragData[1] = vec4(depth0, giM1, giM2, blendedAO);
}

#endif
