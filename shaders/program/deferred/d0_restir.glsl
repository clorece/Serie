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
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;

vec3 clipSpace;

#include "/lib/util/positions.glsl"
#include "/lib/util/sampling.glsl"
#include "/lib/pt/voxelData.glsl"
#include "/lib/pt/ao.glsl"
#include "/lib/pt/gi.glsl"
#include "/lib/pt/screenTrace.glsl"
#include "/lib/pt/restir.glsl"

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
uniform mat4 gbufferProjection;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 previousCameraPosition;

// Custom 2x2 Bilateral History Fetch
// Evaluates depth and normal similarity for each of the 4 neighboring texels in 
// the history buffer and rejects those that belong to a different surface.
bool fetchBilateralHistory(vec2 uv, float expectedClipZ, vec3 expectedNormalWorld, sampler2D hist8, sampler2D hist9, sampler2D hist15, out vec4 outHistory8, out vec4 outHistory9) {
    vec2 res = vec2(viewWidth, viewHeight);
    vec2 pos = uv * res - 0.5;
    vec2 pos00 = floor(pos);
    vec2 f = pos - pos00;

    ivec2 i00 = ivec2(pos00);
    ivec2 i10 = i00 + ivec2(1, 0);
    ivec2 i01 = i00 + ivec2(0, 1);
    ivec2 i11 = i00 + ivec2(1, 1);

    vec4 w = vec4(
        (1.0 - f.x) * (1.0 - f.y),
        f.x * (1.0 - f.y),
        (1.0 - f.x) * f.y,
        f.x * f.y
    );

    vec4 c9_00 = texelFetch(hist9, i00, 0);
    vec4 c9_10 = texelFetch(hist9, i10, 0);
    vec4 c9_01 = texelFetch(hist9, i01, 0);
    vec4 c9_11 = texelFetch(hist9, i11, 0);

    // Depth rejection: 0 if depth difference is too large (> 0.005 clip-space difference)
    vec4 clipZ = vec4(c9_00.r, c9_10.r, c9_01.r, c9_11.r) * 2.0 - 1.0;
    vec4 validW = step(abs(clipZ - expectedClipZ), vec4(0.005));
    
    // Normal rejection: use world-space normal similarity to identify surface boundaries.
    vec3 n00 = octDecodeNormal(texelFetch(hist15, i00, 0).xy);
    vec3 n10 = octDecodeNormal(texelFetch(hist15, i10, 0).xy);
    vec3 n01 = octDecodeNormal(texelFetch(hist15, i01, 0).xy);
    vec3 n11 = octDecodeNormal(texelFetch(hist15, i11, 0).xy);
    
    vec4 normalW = vec4(
        max(dot(n00, expectedNormalWorld), 0.0),
        max(dot(n10, expectedNormalWorld), 0.0),
        max(dot(n01, expectedNormalWorld), 0.0),
        max(dot(n11, expectedNormalWorld), 0.0)
    );
    // Pow 16.0 provides a good balance between edge sharpness and noise stability.
    validW *= pow(normalW, vec4(16.0));
    
    w *= validW;

    float wSum = dot(w, vec4(1.0));
    if (wSum > 1e-5) {
        vec4 c8_00 = texelFetch(hist8, i00, 0);
        vec4 c8_10 = texelFetch(hist8, i10, 0);
        vec4 c8_01 = texelFetch(hist8, i01, 0);
        vec4 c8_11 = texelFetch(hist8, i11, 0);

        outHistory8 = (c8_00 * w.x + c8_10 * w.y + c8_01 * w.z + c8_11 * w.w) / wSum;
        outHistory9 = (c9_00 * w.x + c9_10 * w.y + c9_01 * w.z + c9_11 * w.w) / wSum;
        return true;
    }
    return false;
}

void main() {
    vec2 currentJitter = getTaaJitter(frameCounter) * texelSize;
    vec2 prevJitter    = getTaaJitter(frameCounter - 1) * texelSize;

    vec2 uvUnjittered = texCoord - currentJitter;
    float depth0 = texture(depthtex0, uvUnjittered).r;
    vec3  normal = normalize(texture(colortex1, uvUnjittered).rgb * 2.0 - 1.0);
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
        vec3  blendedGI = giSky; // sky fallback for sky pixels / no history
        float giHist    = 0.0;
        float giM1      = 0.0;   // integrated 1st luminance moment (E[L])  -> colortex9.g
        float giM2      = 0.0;   // integrated 2nd luminance moment (E[L^2])-> colortex9.b

        if (depth0 < 1.0) {
            vec3 worldRel    = getWorldPosition().xyz;
            vec3 worldAbs    = worldRel + cameraPosition;
            vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * lightVector);
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

            // Reproject into previous frame (avoid precision loss by staying relative)
            vec3 worldPrevRel = worldRel;
            if (depth0 >= 0.7) {
                // Environment: account for camera movement.
                worldPrevRel += (cameraPosition - previousCameraPosition);
            } else {
                // View-model (hand): pinned to the camera, so don't subtract global motion.
                // This significantly reduces ghosting on the player's tools/hands.
            }
            
            vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
            vec4 clipPrev = gbufferPreviousProjection * viewPrev;
            vec2 uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
            
            // Re-jitter to match the previous frame's subpixel offset in history buffers
            uvPrev += prevJitter;
            
            float expectedClipZ = clipPrev.z / clipPrev.w;
            bool validReproj = all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)));

          #ifdef RESTIR_GI
            // ---- ReSTIR GI: spatio-temporal reservoir resampling ----
            vec3 gridOrigin = floor(cameraPosition) - vec3(VOXEL_RADIUS);
            vec3 origin = worldAbs + normalWorld * 0.15;

            // 1. Initial RIS over a few cosine-weighted candidate rays
            Reservoir res = newReservoir();
            for (int i = 0; i < RESTIR_INITIAL_SAMPLES; i++) {
                vec3 dir = cosHemisphereDir(normalWorld, randFloat(seed), randFloat(seed));
                vec3 hitPos; vec3 hitNormal; bool wasHit; uint hitCategory;
                vec3 rad = giRayRadiance(colortex7, cameraPosition, gridOrigin, origin, dir, sunDirWorld, lightColor, giSky, colortex13, hitPos, hitNormal, wasHit, hitCategory, skyLightmap);

                // Infinite multi-bounce logic (optimized lookup)
                if (wasHit && hitCategory != VOXEL_EMISSIVE) {
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
                            if (prevDepthRaw < 0.9999 && relErr < 0.05) {
                                rad = texture(colortex5, uvHit).rgb;
                            }
                        }
                    }
                }

                updateReservoir(res, rad, hitPos - cameraPosition, hitNormal, luma(rad), seed);
            }

            // 2. Temporal reuse from the reprojected reservoir (M-capped)
            if (validReproj) {
                vec4  p9 = texture(colortex9, uvPrev);
                float prevDepthRaw = p9.r;
                float actualClipZ = prevDepthRaw * 2.0 - 1.0;
                
                // Normal similarity check for reservoir reuse
                vec3 prevNormalWorld = octDecodeNormal(texture(colortex15, uvPrev).xy);
                float normalSim = max(dot(normalWorld, prevNormalWorld), 0.0);

                if (abs(expectedClipZ - actualClipZ) < 0.002 && normalSim > 0.5) {
                    Reservoir prev = readReservoir(colortex10, colortex11, colortex14, uvPrev);

                    // Anti-ghosting for reservoirs: discard history on significant luminance change
                    float lr_initial = luma(res.radiance);
                    float prevStd = sqrt(max(p9.b - p9.g * p9.g, 0.0));
                    float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9.g + 0.01;
                    float reject  = clamp((abs(lr_initial - p9.g) - tol) / (tol + 1e-3), 0.0, 1.0);

                    // Aggressive normal-based rejection for reservoirs
                    reject = max(reject, 1.0 - pow(normalSim, 8.0));
                    
                    // Motion-aware reservoir rejection
                    float motion = length(cameraPosition - previousCameraPosition);
                    reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.5);

                    prev.M = min(prev.M, float(RESTIR_M_CAP));
                    prev.M = mix(prev.M, 0.0, reject);

                    // Temporal reuse maps the current point back to the SAME world surface,
                    // so the reconnection Jacobian is ~1 (no geometry change).
                    mergeReservoir(res, prev, 1.0, seed);
                }
            }
            finalizeReservoir(res);

            // Store the temporal reservoir (pre-spatial) for next frame
            resv10Out = vec4(res.radiance, res.M);
            resv11Out = vec4(res.samplePos, res.W);
            resv14Out = vec4(octEncodeNormal(res.sampleNormal), 0.0, 0.0);

            // 3. Spatial reuse for shading only, drawing on last frame's reservoirs
            Reservoir shade = res;
            #ifdef RESTIR_SPATIAL
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
            #endif

            // 4. Resolve GI estimate = radiance * W, clamped against fireflies
            vec3 rawGI = min(shade.radiance * shade.W, vec3(RESTIR_CLAMP)) * (float(GI_STRENGTH) / 100.0);

            // 4b. Relative firefly clamp: a single frame's estimate may not exceed
            //     GI_FIREFLY x the established temporal-mean luminance (colortex9.g).
            float lr = luma(rawGI);
            vec4  p9_tmp = validReproj ? textureCatmullRom(colortex9, uvPrev, vec2(viewWidth, viewHeight)) : vec4(0.0);
            if (validReproj && p9_tmp.g > 1e-3) {
                float maxL = p9_tmp.g * GI_FIREFLY;
                if (lr > maxL) { rawGI *= maxL / lr; lr = maxL; }
            }

            // 5. Temporal accumulation of the RESOLVED GI + luminance moments (for SVGF).
            blendedGI = rawGI;
            giHist    = 1.0;
            giM1      = lr;
            giM2      = lr * lr;
            if (validReproj) {
                vec4 prev8, p9_tmp;
                if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, prev8, p9_tmp)) {
                    if (prev8.a > 0.5) {
                        giHist = min(prev8.a + 1.0, float(GI_ACCUM_FRAMES));
                        // Anti-ghosting: shorten history when this frame's luminance leaves the
                        // historical distribution (e.g. a moving shadow), so it adapts instead
                        // of trailing. The SVGF spatial pass re-blurs the resulting noise.
                        float prevStd = sqrt(max(p9_tmp.b - p9_tmp.g * p9_tmp.g, 0.0));
                        float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9_tmp.g + 0.01;
                        float reject  = clamp((abs(lr - p9_tmp.g) - tol) / (tol + 1e-3), 0.0, 1.0);
                        
                        // Motion-aware accumulation shortening
                        float motion = length(cameraPosition - previousCameraPosition);
                        reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);

                        reject *= reject; // soften partial rejection so history survives noise
                        giHist = mix(giHist, 1.0, reject);
                        float a = 1.0 / giHist;
                        blendedGI = mix(prev8.rgb, rawGI, a);
                        giM1 = mix(p9_tmp.g, lr,      a);
                        giM2 = mix(p9_tmp.b, lr * lr, a);
                    }
                }
            }
          #else
            // ---- Plain single-bounce GI with temporal accumulation ----
            vec3 rawGI = computeGI(colortex7, worldAbs, normalWorld, seed, cameraPosition,
                                   sunDirWorld, lightColor, giSky, colortex13, skyLightmap) * (float(GI_STRENGTH) / 100.0);
            float lr = luma(rawGI);
            blendedGI = rawGI;
            giHist    = 1.0;
            giM1      = lr;
            giM2      = lr * lr;
            if (validReproj) {
                vec4 h, p9;
                if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, h, p9)) {
                    if (h.a > 0.5) {
                        giHist = min(h.a + 1.0, float(GI_ACCUM_FRAMES));
                        // Anti-ghosting (see ReSTIR branch): reject history on luminance change.
                        float prevStd = sqrt(max(p9.b - p9.g * p9.g, 0.0));
                        float tol     = prevStd * GI_TEMPORAL_REJECT + 0.05 * p9.g + 0.01;
                        float reject  = clamp((abs(lr - p9.g) - tol) / (tol + 1e-3), 0.0, 1.0);
                        
                        float motion = length(cameraPosition - previousCameraPosition);
                        reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);

                        reject *= reject;
                        giHist = mix(giHist, 1.0, reject);
                        float a = 1.0 / giHist;
                        blendedGI = mix(h.rgb, rawGI, a);
                        giM1 = mix(p9.g, lr,      a);
                        giM2 = mix(p9.b, lr * lr, a);
                    }
                }
            }
          #endif
        }
        hist8Out = vec4(blendedGI, giHist);
        hist9Out = vec4(depth0, giM1, giM2, 1.0);

    #elif defined(VOXEL_AO)
        // ---- Voxel AO fallback with temporal accumulation ----
        float accumAO = 1.0;
        float aoHist  = 0.0;
        float aoM1    = 0.0;
        float aoM2    = 0.0;
        if (depth0 < 1.0) {
            vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normal);
            vec3 worldRel = getWorldPosition().xyz;
            vec3 worldAbs = worldRel + cameraPosition;
            uint seed = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);
            float rawAO = computeAO(colortex7, worldAbs, normalWorld, seed, cameraPosition, skyLightmap);

            // Reproject
            vec3 worldPrevRel = worldRel;
            if (depth0 >= 0.7) {
                worldPrevRel += (cameraPosition - previousCameraPosition);
            }

            vec4 viewPrev = gbufferPreviousModelView * vec4(worldPrevRel, 1.0);
            vec4 clipPrev = gbufferPreviousProjection * viewPrev;
            vec2 uvPrev   = (clipPrev.xy / clipPrev.w) * 0.5 + 0.5;
            uvPrev += prevJitter;
            float expectedClipZ = clipPrev.z / clipPrev.w;

            accumAO = rawAO;
            aoHist  = 1.0;
            aoM1    = rawAO;
            aoM2    = rawAO * rawAO;
            if (all(greaterThanEqual(uvPrev, vec2(0.0))) && all(lessThan(uvPrev, vec2(1.0)))) {
                vec4 prev8, p9;
                if (fetchBilateralHistory(uvPrev, expectedClipZ, normalWorld, colortex8, colortex9, colortex15, prev8, p9)) {
                    if (prev8.a > 0.5) {
                        aoHist = min(prev8.a + 1.0, float(AO_ACCUM_FRAMES));
                        // Anti-ghosting: reject history on AO change.
                        float prevStd = sqrt(max(p9.b - p9.g * p9.g, 0.0));
                        float tol     = prevStd * 1.5 + 0.05 * p9.g + 0.01;
                        float reject  = clamp((abs(rawAO - p9.g) - tol) / (tol + 1e-3), 0.0, 1.0);
                        
                        float motion = length(cameraPosition - previousCameraPosition);
                        reject = max(reject, smoothstep(0.1, 1.0, motion) * 0.75);

                        reject *= reject;
                        aoHist = mix(aoHist, 1.0, reject);
                        float a = 1.0 / aoHist;
                        accumAO = mix(prev8.r, rawAO,          a);
                        aoM1    = mix(p9.g,    rawAO,          a);
                        aoM2    = mix(p9.b,    rawAO * rawAO,  a);
                    }
                }
            }
        }
        // Replicate the scalar AO across rgb so the a-trous chain can filter it uniformly.
        hist8Out = vec4(vec3(accumAO), aoHist);
        hist9Out = vec4(depth0, aoM1, aoM2, 1.0);
    #endif

    /* RENDERTARGETS: 8,9,10,11,14,15 */
    gl_FragData[0] = hist8Out;
    gl_FragData[1] = hist9Out;
    gl_FragData[2] = resv10Out;
    gl_FragData[3] = resv11Out;
    gl_FragData[4] = resv14Out;
    gl_FragData[5] = resv15Out;
}

#endif
