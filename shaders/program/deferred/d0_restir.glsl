// d0_restir : indirect-light estimation (ReSTIR GI / plain GI / voxel AO)
// Produces the NOISY indirect estimate + temporal history. It does NOT light
// the scene or touch colortex0 (raw albedo is preserved for d7_composite).
//   colortex8  = resolved indirect (.rgb) + history length (.a)
//   colortex9  = linear depth (.r)                 [reprojection validation]
//   colortex10 = ReSTIR reservoir radiance (.rgb) + M (.a)
//   colortex11 = ReSTIR reservoir samplePos (.xyz) + W (.a)
//   colortex15 = surface normal history (.xy octahedral world-space)
// The denoise chain (d1..d3) reads colortex8; nothing else writes 8/9/10/11/15,
// so they survive the frame and become "previous frame" history next frame.

#ifdef VERTEX

out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;


void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;


vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/util/sampling.glsl"
#include "/lib/fragment/atmosphereLUT.glsl"
#include "/lib/pt/voxelData.glsl"
#include "/lib/pt/ao.glsl"
#include "/lib/pt/gi.glsl"
#include "/lib/pt/restir.glsl"
#include "/lib/pt/denoise.glsl"



void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    vec2 uvUnjittered = texCoord - currentJitter;
    float depth0 = texture(depthtex0, uvUnjittered).r;
    vec3  normal = normalize(texture(colortex1, uvUnjittered).rgb * 2.0 - 1.0);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
    
    clipSpace = vec3(uvUnjittered, depth0) * 2.0 - 1.0;
    float linDepth = getDepth(depth0);


    vec4 hist8Out  = vec4(0.0);
    vec4 hist9Out  = vec4(depth0, 0.0, 0.0, 1.0);
    vec4 resv10Out = vec4(0.0);
    vec4 resv11Out = vec4(0.0);
    vec4 resv14Out = vec4(0.0);
    vec4 resv15Out = vec4(octEncodeNormal(normalWorld), 0.0, 1.0);

    #if defined(VOXEL_GI) || defined(VOXEL_AO)
        float skyLightmap = texture(colortex2, texCoord).y;
    #endif

    #if defined(VOXEL_GI)
        // GI sky probe — sampled from the Hillaire 2020 sky-view LUT looking
        // upward. Replaces the legacy flat `ambientColor * ambientScale` (the
        // LUT carries time-of-day modulation naturally, dim at night via the
        // moon-only scatter integral). Direct skylight in d7_composite still
        // uses ambientColor for now (v2 will unify it).
        float eyeAlt = cameraPosition.y - 64.0;
        vec3 giSky = getSkyAmbient(eyeAlt) * GI_SKY_BRIGHTNESS;
        vec3 rawGI = giSky; // sky fallback
        float lr   = luma(rawGI);
        float rawAO = 1.0;

        if (depth0 < 1.0) {
            vec3 worldRel    = getWorldPosition().xyz;
            vec3 worldAbs    = worldRel + cameraPosition;
            vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

            #ifdef AO_RTAO
                uint aoSeed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter * 37 + 9);
                rawAO = computeRTAO(colortex7, worldAbs, normalWorld, aoSeed, cameraPosition,
                                    depthtex0, gbufferProjection, gbufferModelView);
            #endif

            vec3 worldPrevRel = worldRel;
            bool isHand = depth0 < 0.56;
            
            vec2 uvPrev;
            float expectedClipZ;
            float expectedLinDepth;
            if (isHand) {
                uvPrev = texCoord;
                expectedClipZ = clipSpace.z;
                expectedLinDepth = linDepth;
            } else {
                if (depth0 >= 0.7) {
                    worldPrevRel += (cameraPosition - previousCameraPosition);
                }
                vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
                vec4 clipPrev = gbufferPreviousProjection * viewPrev;
                uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
                uvPrev += prevJitter;
                expectedClipZ = clipPrev.z / clipPrev.w;
                expectedLinDepth = -viewPrev.z;
            }
            
            vec2 padding = 1.5 * texelSize;
            bool validReproj = all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding));

          #ifdef RESTIR_GI
            vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
            vec3 origin = worldAbs + normalWorld * 0.15;

            Reservoir res = newReservoir();
            for (int i = 0; i < RESTIR_INITIAL_SAMPLES; i++) {
                vec3 dir = cosHemisphereDir(normalWorld, randFloat(seed), randFloat(seed));
                vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCategory; vec3 rayEmission;


                float dither = randFloat(seed);
                vec3 rad = giRayRadiance(
                    colortex7, cameraPosition, gridOrigin, origin, dir, sunDirWorld, lightColor, giSky,
                    depthtex0, colortex5, colortex1, gbufferProjection, gbufferModelView,
                    hitPos, hitNormal, wasHit, hitCategory, rayEmission, skyLightmap, dither
                );

                if (wasHit && hitCategory != VOXEL_EMISSIVE && hitCategory < 100u) {
                    vec3  hitRelPrev = hitPos - previousCameraPosition;
                    vec4  viewHit    = gbufferPreviousModelView * vec4(hitRelPrev, 1.0);
                    vec4  clipHit    = gbufferPreviousProjection * viewHit;
                    if (clipHit.w > 0.0) {
                        vec2 uvHit = clipHit.xy / clipHit.w * 0.5 + 0.5;
                        uvHit += prevJitter;
                        if (all(greaterThanEqual(uvHit, vec2(0.0))) && all(lessThan(uvHit, vec2(1.0)))) {
                            float prevDepthRaw   = texture(colortex9, uvHit).r;
                            float expectedRawD   = clamp(clipHit.z / clipHit.w * 0.5 + 0.5, 0.0, 1.0);
                            float expectedLinD   = getDepth(expectedRawD);
                            float actualLinD     = getDepth(prevDepthRaw);
                            float relErr         = abs(expectedLinD - actualLinD) / max(expectedLinD, 0.1);
                            
                            // ReSTIR multi-bounce: overwrite radiance with previous frame if depth matches
                            if (prevDepthRaw < 0.9999 && relErr < 0.05) {
                                rad = texture(colortex5, uvHit).rgb;
                            }
                        }
                    }
                }

                // add emission from non-occluding blocklights the ray passed through, done after the multi-bounce overwrite so it is never discarded
                if (isnan(rad.r) || isnan(rad.g) || isnan(rad.b) || isinf(rad.r) || isinf(rad.g) || isinf(rad.b)) {
                    rad = vec3(0.0);
                }
                if (isnan(rayEmission.r) || isnan(rayEmission.g) || isnan(rayEmission.b) || isinf(rayEmission.r) || isinf(rayEmission.g) || isinf(rayEmission.b)) {
                    rayEmission = vec3(0.0);
                }
                rad = max(rad, vec3(0.0)) + max(rayEmission, vec3(0.0));

                updateReservoir(res, rad, hitPos - cameraPosition, hitNormal, luma(rad), seed);
            }

            // temporal reuse from the reprojected reservoir (M-capped)
            if (validReproj) {
                vec4  p9 = texture(colortex9, uvPrev);
                float prevDepthRaw = p9.r;
                float actualClipZ = prevDepthRaw * 2.0 - 1.0;
                float actualLinDepth = getDepth(prevDepthRaw);
                
                bool depthValid = false;
                if (isHand) {
                    float relDepthErr = abs(actualLinDepth - expectedLinDepth) / max(expectedLinDepth, 1e-3);
                    depthValid = (relDepthErr < 0.15);
                } else {
                    depthValid = (abs(expectedClipZ - actualClipZ) < 0.002);
                }
                

                vec3 prevNormalWorld = octDecodeNormal(texture(colortex15, uvPrev).xy);
                float normalSim = max(dot(normalWorld, prevNormalWorld), 0.0);

                if (depthValid && normalSim > 0.5) {
                    Reservoir prev = readReservoir(colortex10, colortex11, colortex14, uvPrev);

                    float reject = 1.0 - pow(normalSim, 8.0);
                    float motion = length(cameraPosition - previousCameraPosition);
                    reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.5);

                    prev.M = min(prev.M, float(RESTIR_M_CAP));
                    prev.M = mix(prev.M, 0.0, reject);

                    mergeReservoir(res, prev, 1.0, seed);
                }
            }
            finalizeReservoir(res);
            
            float unbiasedLuma = luma(res.radiance * res.W);
            if (unbiasedLuma > float(RESTIR_CLAMP)) {
                res.W *= float(RESTIR_CLAMP) / unbiasedLuma;
            }


            resv10Out = vec4(res.radiance, res.M);
            resv11Out = vec4(res.samplePos, res.W);
            resv14Out = vec4(octEncodeNormal(res.sampleNormal), 0.0, 0.0);

            Reservoir shade = res;

            rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);
            lr    = luma(rawGI);

            vec4 p9_tmp = validReproj ? textureCatmullRom(colortex9, uvPrev, vec2(viewWidth, viewHeight)) : vec4(0.0);
            if (validReproj && p9_tmp.g > 1e-3) {
                float maxL = p9_tmp.g * GI_FIREFLY;
                if (lr > maxL) { rawGI *= maxL / lr; lr = maxL; }
            }
          #else
            rawGI = computeGI(
                colortex7, worldAbs, normalWorld, seed, cameraPosition,
                sunDirWorld, lightColor, giSky, skyLightmap,
                depthtex0, colortex5, colortex1, gbufferProjection, gbufferModelView
            ) * (float(GI_STRENGTH) / 100.0);
            lr    = luma(rawGI);
          #endif
        }

        if (isnan(rawGI.r) || isnan(rawGI.g) || isnan(rawGI.b) || isinf(rawGI.r) || isinf(rawGI.g) || isinf(rawGI.b)) {
            rawGI = vec3(0.0);
        }
        rawGI = max(rawGI, vec3(0.0));
        lr    = luma(rawGI);

        hist8Out = vec4(rawGI, 1.0);
        hist9Out = vec4(depth0, lr, lr * lr, 1.0);

        resv14Out.w = rawAO;

    #elif defined(VOXEL_AO)
        float rawAO = 1.0;
        if (depth0 < 1.0) {
            vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
            vec3 worldRel = getWorldPosition().xyz;
            vec3 worldAbs = worldRel + cameraPosition;
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);
            rawAO = computeAO(
                colortex7, worldAbs, normalWorld, seed, cameraPosition, skyLightmap,
                depthtex0, gbufferProjection, gbufferModelView
            );
        }
        hist8Out = vec4(vec3(rawAO), 1.0);
        hist9Out = vec4(depth0, rawAO, rawAO * rawAO, 1.0);
    #endif

    /* RENDERTARGETS: 3,6,10,11,14,15 */
    gl_FragData[0] = hist8Out; // Writes to colortex3 (Raw GI)
    gl_FragData[1] = hist9Out; // Writes to colortex6 (Raw Moments)
    gl_FragData[2] = resv10Out;
    gl_FragData[3] = resv11Out;
    gl_FragData[4] = resv14Out;
    gl_FragData[5] = resv15Out;
}

#endif
