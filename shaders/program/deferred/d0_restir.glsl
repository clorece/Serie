// ============================================================================
//  d0_restir : indirect-light estimation (ReSTIR GI / plain GI / voxel AO)
// ----------------------------------------------------------------------------
//  Produces the NOISY indirect estimate + temporal history. It does NOT light
//  the scene or touch colortex0 (raw albedo is preserved for d7_composite).
//    colortex8  = resolved indirect (.rgb) + history length (.a)
//    colortex9  = linear depth (.r)                 [reprojection validation]
//    colortex10 = ReSTIR reservoir radiance (.rgb) + M (.a)
//    colortex11 = ReSTIR reservoir samplePos (.xyz) + W (.a)
//    colortex15 = surface normal history (.xy octahedral world-space)
//  The denoise chain (d1..d3) reads colortex8; nothing else writes 8/9/10/11/15,
//  so they survive the frame and become "previous frame" history next frame.
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;

uniform int worldTime;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;

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

uniform float rainStrength;
uniform vec3 cameraPosition;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
#ifndef GBUFFER_PROJECTION_INVERSE_DECLARED
#define GBUFFER_PROJECTION_INVERSE_DECLARED
uniform mat4 gbufferProjectionInverse;
#endif
uniform mat4 gbufferModelViewInverse;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/util/sampling.glsl"
#include "/lib/pt/voxelData.glsl"
#include "/lib/pt/ao.glsl"
#include "/lib/pt/gi.glsl"
#include "/lib/pt/restir.glsl"
#include "/lib/pt/denoise.glsl"

// Voxel atlas + persistent history
uniform usampler2D colortex7;
uniform sampler2D colortex5;   // prev-frame resolved HDR scene (radiance cache for multi-bounce)
uniform sampler2D colortex13;  // directional sky LUT (octahedral, written by d6_skylut last frame)
uniform sampler2D colortex14;  // ReSTIR reservoir sample-hit normal (octahedral)
uniform sampler2D colortex15;  // primary surface normal history (.xy octahedral world-space)
uniform sampler2D colortex8;   // indirect history (.rgb + histLen .a)
uniform sampler2D colortex9;   // linear-depth history (.r)
uniform sampler2D colortex10;  // ReSTIR reservoir: radiance.rgb + M
uniform sampler2D colortex11;  // ReSTIR reservoir: samplePos.xyz + W

#ifdef RESTIR_GI
uniform sampler3D irradianceCache3D;
uniform sampler3D irradianceCache3D_Alt;
#endif

uniform mat4 gbufferProjection;
uniform mat4 gbufferModelView;

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    // Sample the gbuffer at the ACTUAL pixel (texCoord); the TAA jitter is baked into the
    // gbuffer projection, so we only remove it from the NDC we use to reconstruct world
    // position. This matches d7_composite exactly, so the GI we store is perfectly aligned
    // with the albedo/normal/depth the denoiser and composite read back. (Previously the
    // gbuffer was sampled at texCoord-jitter, offsetting the GI from the geometry by the
    // jitter -> the a-trous then smeared that misalignment, drifting edges.)
    vec2 uvUnjittered = texCoord - currentJitter;
    float depth0 = texture(depthtex0, texCoord).r;
    vec3  normal = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);

    clipSpace = vec3(uvUnjittered, depth0) * 2.0 - 1.0;
    float linDepth = getDepth(depth0);

    // History outputs are written every frame so the persistent buffers stay valid.
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
        // ambientColor is a dim stylistic tint; scale it up to a usable sky irradiance.
        vec3 giSky = ambientColor * GI_SKY_BRIGHTNESS;
        vec3 rawGI = giSky; // sky fallback
        float lr   = luma(rawGI);

        if (depth0 < 1.0) {
            vec3 worldRel    = getWorldPosition().xyz;
            vec3 worldAbs    = worldRel + cameraPosition;
            vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

            // Reproject into previous frame (avoid precision loss by staying relative)
            vec3 worldPrevRel = worldRel;
            bool isHand = depth0 < 0.56;
            
            vec2 uvPrev;
            float expectedClipZ;
            if (isHand) {
                uvPrev = texCoord;
                expectedClipZ = clipSpace.z;
            } else {
                // Always apply camera translation for world-space reprojection (matches
                // d0_accum). The previous gate skipped it for near surfaces (depth0 < 0.7),
                // which misaligned their reservoir history during movement -> ghosting on
                // nearby blocks.
                worldPrevRel += (cameraPosition - previousCameraPosition);
                vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
                vec4 clipPrev = gbufferPreviousProjection * viewPrev;
                uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
                uvPrev  -= prevJitter;
                expectedClipZ = clipPrev.z / clipPrev.w;
            }
            
            vec2 padding = 1.5 * texelSize;
            bool validReproj = all(greaterThanEqual(uvPrev, padding)) && all(lessThan(uvPrev, 1.0 - padding));

          #ifdef RESTIR_GI
            // ---- ReSTIR GI: spatio-temporal reservoir resampling ----
            vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
            vec3 origin = worldAbs + normalWorld * 0.15;

            // 1. Initial RIS over a few cosine-weighted candidate rays
            Reservoir res = newReservoir();
            for (int i = 0; i < RESTIR_INITIAL_SAMPLES; i++) {
                vec3 dir = cosHemisphereDir(normalWorld, randFloat(seed), randFloat(seed));
                vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCategory;
                
                // Hybrid Voxel/SSRT Raytrace
                vec3 rad = giRayRadiance(
                    colortex7, cameraPosition, gridOrigin, origin, dir, sunDirWorld, lightColor, giSky,
                    colortex13, depthtex0, colortex5, colortex1, gbufferProjection, gbufferModelView,
                    hitPos, hitNormal, wasHit, hitCategory, skyLightmap
                );

                // Infinite multi-bounce logic (ReSTIR-only; the resolved scene from last
                // frame becomes the bounce radiance when the hit projects to a visible pixel).
                if (wasHit && hitCategory != VOXEL_EMISSIVE) {
                    vec3  hitRelPrev = hitPos - previousCameraPosition;
                    vec4  viewHit    = gbufferPreviousModelView * vec4(hitRelPrev, 1.0);
                    vec4  clipHit    = gbufferPreviousProjection * viewHit;
                    if (clipHit.w > 0.0) {
                        vec2 uvHit = clipHit.xy / clipHit.w * 0.5 + 0.5;
                        uvHit += prevJitter;
                        if (all(greaterThanEqual(uvHit, vec2(0.0))) && all(lessThan(uvHit, vec2(1.0)))) {
                            float prevLinD     = texture(colortex9, uvHit).r;
                            float expectedLinD = getDepth(clamp(clipHit.z / clipHit.w * 0.5 + 0.5, 0.0, 1.0));
                            float relErr       = abs(expectedLinD - prevLinD) / max(expectedLinD, 0.1);
                            if (prevLinD < far * 0.999 && relErr < 0.05) {
                                rad = texture(colortex5, uvHit).rgb;
                            } else {
                                vec3 edgeBleed = textureLod(colortex5, clamp(uvHit, 0.0, 1.0), 5.0).rgb;
                                vec2 primaryLM = texture(colortex2, texCoord).rg;
                                vec3 fakeAmbient = min(edgeBleed, vec3(0.1)) * 0.1 + primaryLM.x * vec3(1.0, 0.85, 0.6) * 0.02;
                                rad += fakeAmbient;
                            }
                        } else {
                            vec3 edgeBleed = textureLod(colortex5, clamp(uvHit, 0.0, 1.0), 5.0).rgb;
                            vec2 primaryLM = texture(colortex2, texCoord).rg;
                            vec3 fakeAmbient = min(edgeBleed, vec3(0.1)) * 0.1 + primaryLM.x * vec3(1.0, 0.85, 0.6) * 0.02;
                            rad += fakeAmbient;
                        }
                    } else {
                        vec3 edgeBleed = textureLod(colortex5, texCoord, 5.0).rgb;
                        vec2 primaryLM = texture(colortex2, texCoord).rg;
                        vec3 fakeAmbient = min(edgeBleed, vec3(0.1)) * 0.1 + primaryLM.x * vec3(1.0, 0.85, 0.6) * 0.02;
                        rad += fakeAmbient;
                    }
                }

                updateReservoir(res, rad, hitPos - cameraPosition, hitNormal, luma(rad), seed);
            }

            // 2. Temporal reuse from the reprojected reservoir (M-capped)
            if (validReproj) {
                vec4  p9 = texture(colortex9, uvPrev);
                float prevLinD = p9.r;                                 // colortex9.r = LINEAR depth
                float expectedLinD = getDepth(expectedClipZ * 0.5 + 0.5);
                float depthRelErr = abs(expectedLinD - prevLinD) / max(expectedLinD, 0.1);

                // Normal similarity check for reservoir reuse
                vec3 prevNormalWorld = octDecodeNormal(texture(colortex15, uvPrev).xy);
                float normalSim = max(dot(normalWorld, prevNormalWorld), 0.0);

                // Relative linear-depth test (was a 0.002 clip-Z test: far too tight near the
                // far plane, and itself a source of depth-banded reservoir reuse).
                if (depthRelErr < 0.05 && normalSim > 0.5) {
                    Reservoir prev = readReservoir(colortex10, colortex11, colortex14, uvPrev);

                    // Geometry and Motion-based rejection for reservoirs.
                    // We DO NOT use luminance rejection here because 1spp path tracing
                    // noise makes luminance highly volatile. We rely on the AABB clamp
                    // in d0_accum to handle lighting changes, and geometry to handle occlusions.

                    // Aggressive normal-based rejection for reservoirs
                    float reject = 1.0 - pow(normalSim, 8.0);
                    
                    // Motion-aware reservoir rejection
                    float motion = length(cameraPosition - previousCameraPosition);
                    reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.5);

                    prev.M = min(prev.M, float(RESTIR_M_CAP));
                    prev.M = mix(prev.M, 0.0, reject);

                    mergeReservoir(res, prev, 1.0, seed);
                }
            }
            finalizeReservoir(res);
            
            // Hard clamp the temporal reservoir's unbiased contribution before it goes into history.
            // This prevents a single massive firefly from permanently poisoning the spatial 
            // reuse passes in subsequent frames (which causes the "cloudy blotches").
            float unbiasedLuma = luma(res.radiance * res.W);
            if (unbiasedLuma > float(RESTIR_CLAMP)) {
                res.W *= float(RESTIR_CLAMP) / unbiasedLuma;
            }

            // Store the temporal reservoir (pre-spatial) for next frame
            resv10Out = vec4(res.radiance, res.M);
            resv11Out = vec4(res.samplePos, res.W);
            resv14Out = vec4(octEncodeNormal(res.sampleNormal), 0.0, 0.0);

            // 3. Spatial reuse moved to d0_accum to prevent buffer read/write conflicts.
            Reservoir shade = res;
            
            // 4. Resolve GI estimate
            rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);
            lr    = luma(rawGI);

            // 4b. Relative firefly clamp
            vec4 p9_tmp = validReproj ? textureCatmullRom(colortex9, uvPrev, vec2(viewWidth, viewHeight)) : vec4(0.0);
            if (validReproj && p9_tmp.g > 1e-3) {
                float maxL = p9_tmp.g * GI_FIREFLY;
                if (lr > maxL) { rawGI *= maxL / lr; lr = maxL; }
            }
          #else
            // ---- Plain single-bounce GI ----
            rawGI = computeGI(
                colortex7, worldAbs, normalWorld, seed, cameraPosition,
                sunDirWorld, lightColor, giSky, colortex13, skyLightmap,
                depthtex0, colortex5, colortex1, gbufferProjection, gbufferModelView
            ) * (float(GI_STRENGTH) / 100.0);
            lr    = luma(rawGI);
          #endif
        }
        hist8Out = vec4(rawGI, 1.0);
        hist9Out = vec4(depth0, lr, lr * lr, 1.0);

    #elif defined(VOXEL_AO)
        // ---- Voxel AO fallback (output raw for accumulation) ----
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
