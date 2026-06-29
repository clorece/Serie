// d0_restir : indirect-light estimation (ReSTIR GI / plain GI / voxel AO)
// Produces the NOISY indirect estimate + temporal history. It does NOT light
// the scene or touch colortex0 (raw albedo is preserved for d7_composite).
//   colortex3  = raw noisy GI (.rgb)               [consumed by d0_accum]
//   colortex10 = ReSTIR reservoir radiance (.rgb) + M (.a)
//   colortex11 = ReSTIR reservoir samplePos (.xyz) + W (.a)
//   colortex14 = reservoir sample-hit normal (.xy octahedral)
//   colortex15 = packed G-buffer/normal history (.xy oct world normal, .z linear depth)
// colortex8/9 (history + moments) are written by d0_accum; nothing else writes
// 10/11/14/15, so they survive the frame and become "previous frame" history.

#ifdef VERTEX

#include "/lib/options.glsl"

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

    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);

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
    vec2 sampleCenter = clamp((texCoord + currentJitter) * renderScale, vec2(0.0), vec2(renderScale));
    float depth0 = texture(depthtex0, sampleCenter).r;
    vec3  normal = normalize(texture(colortex1, sampleCenter).rgb * 2.0 - 1.0);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);

    clipSpace = vec3(texCoord, depth0) * 2.0 - 1.0;
    float linDepth = getDepth(depth0);


    vec4 hist8Out  = vec4(0.0);
    vec4 resv10Out = vec4(0.0);
    vec4 resv11Out = vec4(0.0);
    vec4 resv14Out = vec4(0.0);

    vec4 resv15Out = vec4(octEncodeNormal(normalWorld), linDepth, 1.0);

    #if defined(VOXEL_GI) || defined(VOXEL_AO)
        float skyLightmap = texture(colortex2, sampleCenter).y; // jitter-free: gbuffer sampled at jittered buffer pos
    #endif

    #if defined(VOXEL_GI)
        vec3 giSky = ambientColor * GI_SKY_BRIGHTNESS;
        giSky *= mix(vec3(1.0), vec3(1.25, 1.04, 0.72), GI_SKY_WARMTH);

        vec3 rawGI = giSky; // sky fallback
        float lr   = luma(rawGI);

        if (depth0 < 1.0) {
            vec3 worldRel    = getWorldPosition().xyz;
            vec3 worldAbs    = worldRel + cameraPosition;
            vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

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
                // jitter-free: reservoir history indexed by logical pixel (no prevJitter).
                expectedClipZ = clipPrev.z / clipPrev.w;
                expectedLinDepth = -viewPrev.z;
            }
            
            vec2 padding = 1.5 * texelSize;
            bool validReproj = all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding));

          #ifdef RESTIR_GI
            vec3 gridOrigin = floor(cameraPosition) - VOXEL_RADIUS_VEC;
            vec3 origin = worldAbs + normalWorld * 0.15;

            #ifndef RESTIR_BLUE_NOISE
            uint dirSeed = pixelSeed(ivec2(gl_FragCoord.xy) / RESTIR_COHERENT_TILE, frameCounter * 31 + 17);
            #endif

            int numCandidates = RESTIR_INITIAL_SAMPLES;
            #ifdef RESTIR_CONVERGED_SKIP
                if (validReproj && length(cameraPosition - previousCameraPosition) < 1e-3) {
                    float prevMpeek = texture(colortex10, uvPrev * renderScale).a;
                    if (prevMpeek >= float(RESTIR_M_CAP) - 0.5 && randFloat(seed) < RESTIR_CONVERGED_SKIP_PROB) {
                        numCandidates = 0;
                    }
                }
            #endif

            vec3 sunVec = normalize(sunPosition);
            vec3 upVec  = normalize(upPosition);
            float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
            float skyExposure = smoothstep(0.75, 0.9, skyLightmap);
            float blocklightSuppression = mix(1.0, 0.05, sunUp * skyExposure);
            float skyOcc = max(skyLightmap, 0.0);

            Reservoir res = newReservoir();
            for (int i = 0; i < numCandidates; i++) {
                #ifdef RESTIR_BLUE_NOISE
                vec3 dir = stbnCosineHemisphere(normalWorld, ivec2(gl_FragCoord.xy), frameCounter + i);
                #else
                vec3 dir = cosHemisphereDir(normalWorld, randFloat(dirSeed), randFloat(dirSeed));
                #endif
                vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCategory; vec3 rayEmission;

                VoxelHit h = traceVoxelGI(voxelSampler, gridOrigin, origin, dir, float(GI_RADIUS));
                rayEmission = h.emission * blocklightSuppression;

                wasHit = h.hit;
                hitCategory = h.hit ? h.category : VOXEL_AIR;
                hitPos = h.pos;
                hitNormal = h.hit ? h.normal : -dir;

                vec3 rad = vec3(0.0);
                bool reprojected = false;

              #if RESTIR_SCREEN_BOUNCE
                if (wasHit && hitCategory != VOXEL_EMISSIVE && hitCategory < 100u) {
                    vec3  hitRelPrev = hitPos - previousCameraPosition;
                    vec4  viewHit    = gbufferPreviousModelView * vec4(hitRelPrev, 1.0);
                    vec4  clipHit    = gbufferPreviousProjection * viewHit;
                    if (clipHit.w > 0.0) {
                        vec2 uvHit = clipHit.xy / clipHit.w * 0.5 + 0.5;
                        if (all(greaterThanEqual(uvHit, vec2(0.0))) && all(lessThan(uvHit, vec2(1.0)))) {
                            float prevDepthRaw   = texture(colortex9, uvHit * renderScale).r;
                            float expectedRawD   = clamp(clipHit.z / clipHit.w * 0.5 + 0.5, 0.0, 1.0);
                            float expectedLinD   = getDepth(expectedRawD);
                            float actualLinD     = getDepth(prevDepthRaw);
                            float relErr         = abs(expectedLinD - actualLinD) / max(expectedLinD, 0.1);
                            
                            if (prevDepthRaw < 0.9999 && relErr < 0.05) {
                                rad = texture(colortex5, uvHit).rgb;
                                reprojected = true;
                            }
                        }
                    }
                }

              #endif

                if (!reprojected) {
                    if (wasHit) {
                        float ndl = max(dot(h.normal, sunDirWorld), 0.0);
                        if (ndl > 0.0 && skyOcc > 0.01) {
                            #ifdef GI_BOUNCE_SHADOWMAP
                                bool occluded = isInShadow(h.pos + h.normal * 0.1 - cameraPosition);
                            #else
                                bool occluded = traceVoxelRay(voxelSampler, h.pos + h.normal * 0.1, sunDirWorld, float(GI_RADIUS), cameraPosition, depthtex0, gbufferProjection, gbufferModelView, false);
                            #endif
                            if (!occluded) rad += h.albedo * lightColor * ndl * skyOcc;
                        }

                        vec3  skyProbeRaw    = h.normal + vec3(0.0, 1.0, 0.0);
                        float skyProbeLenSq  = dot(skyProbeRaw, skyProbeRaw);
                        if (skyProbeLenSq > 1e-4 && skyOcc > 0.01) { // sky probe stays a voxel ray (the shadow map can't answer "can I see sky")
                            vec3  skyProbeDir   = skyProbeRaw * inversesqrt(skyProbeLenSq);
                            float lambertWeight = dot(h.normal, skyProbeDir);
                            bool  skyEscape     = !traceVoxelRay(voxelSampler, h.pos + h.normal * 0.15, skyProbeDir, float(GI_SKY_PROBE_DIST), cameraPosition, depthtex0, gbufferProjection, gbufferModelView, false);

                            if (skyEscape) rad += vec3(luma(h.albedo)) * giSky * lambertWeight * GI_BOUNCE_SKY * skyOcc;
                        }
                    } else {
                        vec3 skyRad = giSky * skyOcc;
                        rad = skyRad * smoothstep(-0.2, 0.4, dir.y);
                    }
                }

                if (isnan(rad.r) || isnan(rad.g) || isnan(rad.b) || isinf(rad.r) || isinf(rad.g) || isinf(rad.b)) {
                    rad = vec3(0.0);
                }
                if (isnan(rayEmission.r) || isnan(rayEmission.g) || isnan(rayEmission.b) || isinf(rayEmission.r) || isinf(rayEmission.g) || isinf(rayEmission.b)) {
                    rayEmission = vec3(0.0);
                }
                rad = max(rad, vec3(0.0)) + max(rayEmission, vec3(0.0));

                updateReservoir(res, rad, hitPos - cameraPosition, hitNormal, wasHit ? 1.0 : 0.0, luma(rad), seed);
            }

            if (validReproj) {
                vec4  p9 = texture(colortex9, uvPrev * renderScale);
                float prevDepthRaw = p9.r;
                float actualClipZ = prevDepthRaw * 2.0 - 1.0;
                float actualLinDepth = getDepth(prevDepthRaw);

                // Clip-space Z test (original). The relative linear-depth variant
                // rejected valid history on grazing-angle surfaces: their steep
                // screen-space depth gradient makes the reprojected depth differ from
                // the stored texel depth, so the 5% test failed -> view-angle-dependent
                // streaks that swam under panning. Clip-Z is compressed at far/grazing,
                // so it tolerates that. (Hand keeps a relative linear test for bobbing.)
                bool depthValid = false;
                if (isHand) {
                    float relDepthErr = abs(actualLinDepth - expectedLinDepth) / max(expectedLinDepth, 1e-3);
                    depthValid = (relDepthErr < 0.15);
                } else {
                    depthValid = (abs(expectedClipZ - actualClipZ) < 0.002);
                }


                vec3 prevNormalWorld = octDecodeNormal(texture(colortex15, uvPrev * renderScale).xy);
                float normalSim = max(dot(normalWorld, prevNormalWorld), 0.0);

                // 0.5 (original). 0.8 over-rejected temporal history on bump/curved
                // surfaces -> pixels dropped to fresh (M~1), which both flickers like
                // disocclusion AND starves the spatial pass of converged neighbours to
                // borrow from, so real disocclusions filled in worse.
                if (depthValid && normalSim > 0.5) {
                    Reservoir prev = readReservoir(colortex10, colortex11, colortex14, uvPrev * renderScale);

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
            resv14Out = vec4(octEncodeNormal(res.sampleNormal), res.wasHit, 0.0);

            Reservoir shade = res;

            rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);

            vec3 normLightCol = lightColor / max(luma(lightColor), 0.1);
            rawGI = mix(rawGI, rawGI * normLightCol, 0.10);

            lr    = luma(rawGI);

            vec4 p9_tmp = validReproj ? texture(colortex9, uvPrev * renderScale) : vec4(0.0);
            if (validReproj && p9_tmp.g > 1e-3) {
                float maxL = p9_tmp.g * GI_FIREFLY;
                if (lr > maxL) { rawGI *= maxL / lr; lr = maxL; }
            }
          #else
            rawGI = computeGI(
                voxelSampler, worldAbs, normalWorld, seed, cameraPosition,
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

        hist8Out = vec4(rawGI, 1.0);

        #elif defined(VOXEL_AO)
            float rawAO = 1.0;
            if (depth0 < 1.0) {
                vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
                vec3 worldRel = getWorldPosition().xyz;
                vec3 worldAbs = worldRel + cameraPosition;
                uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);
                rawAO = computeAO(
                    voxelSampler, worldAbs, normalWorld, seed, cameraPosition, skyLightmap,
                    depthtex0, gbufferProjection, gbufferModelView
                );
            }
            hist8Out = vec4(vec3(rawAO), 1.0);
        #endif

    // NOTE: the old second output (colortex6 "raw moments") was never read by
    // any pass — d0_accum recomputes the moments itself and the a-trous chain
    // overwrites ct6 — so the full-screen RGBA16F write was dropped.
    /* RENDERTARGETS: 3,10,11,14,15 */
    gl_FragData[0] = hist8Out; // Writes to colortex3 (Raw GI)
    gl_FragData[1] = resv10Out;
    gl_FragData[2] = resv11Out;
    gl_FragData[3] = resv14Out;
    gl_FragData[4] = resv15Out;
}

#endif
