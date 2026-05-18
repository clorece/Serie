/*
    Serie VX — Indirect Lighting
    Voxel-primary path traced GI with Irradiance Cache (IRC) lookup.
    DDA traversal: Amanatides & Woo (1987).
    BRDF: cosine-weighted hemisphere importance sampling.
*/

vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

#include "/lib/colors/blocklightColors.glsl"

#if COLORED_LIGHTING_INTERNAL > 0
    #define PT_USE_VOXEL_LIGHT
#endif
#define PT_TRANSPARENT_TINTS

#define MINIMUM_AMBIENT ambientColor * 0.1

#include "/lib/misc/voxelization.glsl"

#if COLORED_LIGHTING_INTERNAL > 0

    const vec3[] specialTintColorPT = vec3[](
        vec3(1.0, 1.0, 1.0),       // 200 White
        vec3(0.95, 0.65, 0.2),     // 201 Orange
        vec3(0.9, 0.2, 0.9),       // 202 Magenta
        vec3(0.4, 0.6, 0.85),      // 203 Light Blue
        vec3(0.9, 0.9, 0.2),       // 204 Yellow
        vec3(0.5, 0.8, 0.2),       // 205 Lime
        vec3(1.0, 0.4, 0.7),       // 206 Pink
        vec3(0.3, 0.3, 0.3),       // 207 Gray
        vec3(0.6, 0.6, 0.6),       // 208 Light Gray
        vec3(0.3, 0.5, 0.6),       // 209 Cyan
        vec3(0.5, 0.25, 0.7),      // 210 Purple
        vec3(0.2, 0.25, 0.7),      // 211 Blue
        vec3(0.45, 0.3, 0.2),      // 212 Brown
        vec3(0.45, 0.75, 0.35),    // 213 Green
        vec3(1.0, 0.05, 0.05),     // 214 Red
        vec3(0.1, 0.1, 0.1),       // 215 Black
        vec3(0.6, 0.8, 1.0),       // 216 Ice
        vec3(1.0, 1.0, 1.0),       // 217 Glass
        vec3(1.0, 1.0, 1.0),       // 218 Glass Pane
        vec3(1.0, 1.0, 1.0),       // 219
        vec3(0.95, 0.65, 0.2),     // 220 Honey
        vec3(0.45, 0.75, 0.35),    // 221 Slime
        vec3(1.0, 1.0, 1.0),       // 222
        vec3(1.0, 1.0, 1.0),       // 223
        vec3(1.0, 1.0, 1.0),       // 224
        vec3(1.0, 1.0, 1.0),       // 225
        vec3(1.0, 1.0, 1.0),       // 226
        vec3(1.0, 1.0, 1.0),       // 227
        vec3(1.0, 1.0, 1.0),       // 228
        vec3(1.0, 1.0, 1.0),       // 229
        vec3(1.0, 1.0, 1.0),       // 230
        vec3(1.0, 1.0, 1.0),       // 231
        vec3(1.0, 1.0, 1.0),       // 232
        vec3(1.0, 1.0, 1.0),       // 233
        vec3(1.0, 1.0, 1.0),       // 234
        vec3(1.0, 1.0, 1.0),       // 235
        vec3(1.0, 1.0, 1.0),       // 236
        vec3(1.0, 1.0, 1.0),       // 237
        vec3(1.0, 1.0, 1.0),       // 238
        vec3(1.0, 1.0, 1.0),       // 239
        vec3(1.0, 1.0, 1.0),       // 240
        vec3(1.0, 1.0, 1.0),       // 241
        vec3(1.0, 1.0, 1.0),       // 242
        vec3(1.0, 1.0, 1.0),       // 243
        vec3(1.0, 1.0, 1.0),       // 244
        vec3(1.0, 1.0, 1.0),       // 245
        vec3(1.0, 1.0, 1.0),       // 246
        vec3(1.0, 1.0, 1.0),       // 247
        vec3(1.0, 1.0, 1.0),       // 248
        vec3(1.0, 1.0, 1.0),       // 249
        vec3(1.0, 1.0, 1.0),       // 250
        vec3(1.0, 1.0, 1.0),       // 251
        vec3(1.0, 1.0, 1.0),       // 252
        vec3(1.0, 1.0, 1.0),       // 253
        vec3(0.15, 0.15, 0.15)     // 254 Tinted Glass
    );

    vec3 CheckVoxelTint(vec3 startViewPos, vec3 endViewPos) {
        vec3 tint = vec3(1.0);

        vec4 startWorld4 = gbufferModelViewInverse * vec4(startViewPos, 1.0);
        vec4 endWorld4   = gbufferModelViewInverse * vec4(endViewPos,   1.0);
        vec3 startVoxel = SceneToVoxel(startWorld4.xyz);
        vec3 endVoxel   = SceneToVoxel(endWorld4.xyz);
        vec3 volumeSize = vec3(voxelVolumeSize);

        vec3 dir  = endVoxel - startVoxel;
        float dist = length(dir);
        if (dist < 0.2) return tint;

        int steps = clamp(int(dist * 1.2), 2, 20);
        vec3 stepDir = dir / float(steps);
        vec3 pos = startVoxel;

        for (int i = 0; i < steps; i++) {
            pos += stepDir;
            if (any(lessThan(pos, vec3(0.5))) || any(greaterThanEqual(pos, volumeSize - 0.5))) continue;
            uint id = texelFetch(voxel_sampler, ivec3(pos), 0).r;
            if (id <= 1u) continue;
            if ((id >= 200u && id <= 218u) || id == 254u) {
                int idx = int(id) - 200;
                tint *= specialTintColorPT[idx];
            }
            if (dot(tint, tint) < 0.001) break;
        }
        return tint;
    }

#else
    vec3 CheckVoxelTint(vec3 startViewPos, vec3 endViewPos) { return vec3(1.0); }
#endif

#include "/lib/antialiasing/jitter.glsl"
#include "/lib/lighting/voxelPathTracing.glsl"

vec3 GetShadowPosition(vec3 tracePos, vec3 cameraPos) {
    vec3 worldPos = PlayerToShadow(tracePos - cameraPos);
    float distB = sqrt(worldPos.x * worldPos.x + worldPos.y * worldPos.y);
    float distortFactor = 1.0 - shadowMapBias + distB * shadowMapBias;
    vec3 shadowPosition = vec3(vec2(worldPos.xy / distortFactor), worldPos.z * 0.2);
    return shadowPosition * 0.5 + 0.5;
}

bool GetShadow(vec3 tracePos, vec3 cameraPos) {
    vec3 shadowPosition0 = GetShadowPosition(tracePos, cameraPos);
    if (length(shadowPosition0.xy * 2.0 - 1.0) < 0.99) {
        float shadowDepth = shadow2D(shadowtex0, shadowPosition0).x;
        if (shadowDepth < 0.01) return true;
    }
    return false;
}

#include "/lib/lighting/ggx.glsl"

vec3 EvaluateBRDF(vec3 albedo, vec3 normal, vec3 wi, vec3 wo, float smoothness) {
    float NdotL = max(dot(normal, wi), 0.0);
    vec3 diffuse = albedo / 3.14159265;
    float ggxSpec = GGX(normal, -wo, wi, NdotL, smoothness);
    return diffuse + albedo * ggxSpec;
}

vec3 EvaluateBRDF(vec3 albedo, vec3 normal, vec3 wi, vec3 wo) {
    return albedo / 3.14159265;
}

float CosinePDF(float NdotL) {
    return NdotL / 3.14159265;
}

vec3 giScreenPos = vec3(0.0);

vec4 GetGI(inout vec3 occlusion, inout vec3 emissiveOut, vec3 normalM, vec3 viewPos,
           vec3 unscaledViewPos, vec3 nViewPos, sampler2D depthtex,
           float dither, float smoothness, float VdotU, float VdotS,
           bool entityOrHand, float skyLightFactor) {

    vec4 gi = vec4(0.0);

    // Distance fallback — skip expensive voxel trace beyond render distance
    if (length(viewPos) > float(PT_RENDER_DISTANCE) * 0.5) {
        #if defined OVERWORLD && !defined NETHER
            vec3 worldNorm = mat3(gbufferModelViewInverse) * normalM;
            vec3 sunDir    = mat3(gbufferModelViewInverse) * lightVec;
            gi.rgb  = ambientColor * (max(worldNorm.y, 0.0) * 0.5 + 0.5) * skyLightFactor;
            gi.rgb += lightColor * max(dot(worldNorm, sunDir), 0.0) * skyLightFactor;
            gi.rgb  = max(gi.rgb, vec3(0.0));
        #endif
        return gi;
    }

    // Convert receiver to world/scene space
    vec3 receiverScenePos = (gbufferModelViewInverse * vec4(unscaledViewPos, 1.0)).xyz;
    vec3 worldGeoNormal   = mat3(gbufferModelViewInverse) * normalM;
    vec3 sunDirWorld      = mat3(gbufferModelViewInverse) * lightVec;

    // Bias origin off surface to avoid self-intersection
    vec3 startScenePos = receiverScenePos + worldGeoNormal * 0.08;

    // Shadow at receiver
    bool receiverInShadow = false;
    #if defined OVERWORLD && !defined NETHER
        vec3 receiverWorldPos = receiverScenePos + cameraPosition;
        float distBias = pow(dot(receiverScenePos, receiverScenePos), 0.75);
        distBias = 0.12 + 0.0008 * distBias;
        float receiverNdotL = max(dot(worldGeoNormal, sunDirWorld), 0.0);
        vec3 receiverBias = worldGeoNormal * distBias * (2.0 - 0.95 * receiverNdotL);
        receiverInShadow = GetShadow(receiverWorldPos + receiverBias, cameraPosition);
    #endif

    // Direct sun at receiver surface
    vec3 directSunLight = vec3(0.0);
    #if defined OVERWORLD && !defined NETHER
        float NdotSun = max(dot(worldGeoNormal, sunDirWorld), 0.0);
        if (!receiverInShadow && NdotSun > 0.0) {
            directSunLight = lightColor * NdotSun * (1.0 - rainFactor * 0.8);
        }
    #endif

    float receiverShadowMask = receiverInShadow ? 0.5 : 0.25;

    float distanceScale = clamp(1.0 - length(viewPos) / far, 0.1, 1.0);
    int numPaths = max(int(PT_MAX_BOUNCES * distanceScale), 1);

    vec3 totalRadiance = vec3(0.0);

    for (int i = 0; i < numPaths; i++) {
        vec3 pathRadiance   = vec3(0.0);
        vec3 pathThroughput = vec3(1.0);

        vec3 currentScenePos = startScenePos;
        vec3 currentNormal   = worldGeoNormal;

        for (int bounce = 0; bounce < PT_MAX_BOUNCES; bounce++) {
            int seed    = i * PT_MAX_BOUNCES + bounce;
            vec3 rayDir = RayDirection(currentNormal, dither, seed);
            float NdotL = max(dot(currentNormal, rayDir), 0.0);

            #ifdef PT_USE_VOXEL_LIGHT
                // Use volume diagonal as maxDist so rays can always reach the sky.
                // shadowDistance is too short for deep caves, causing false sky hits.
                VoxelHitResult voxelHit = TraceVoxelHit(currentScenePos, rayDir, float(voxelVolumeSize.x));

                if (voxelHit.hit) {
                    if (voxelHit.isEmissive) {
                        // Direct emissive discovery — inverse-square falloff
                        float emissiveDist  = max(length(voxelHit.hitPos - currentScenePos), 0.5);
                        float emissiveFalloff = 1.0 / (1.0 + emissiveDist * emissiveDist * 0.01);
                        pathRadiance += pathThroughput * voxelHit.light * emissiveFalloff;
                        break;
                    }

                    // Non-emissive solid hit — sample IRC + direct sun
                    vec3 hitAlbedo = GetVoxelAlbedo(voxelHit.hitPos - voxelHit.hitNormal * 0.05);

                    // IRC lookup just off the hit surface
                    vec3 ircSamplePos  = voxelHit.hitPos + voxelHit.hitNormal * 0.5;
                    vec3 ircVoxelPos   = SceneToVoxel(ircSamplePos);
                    vec3 ircNormPos    = ircVoxelPos / vec3(voxelVolumeSize);
                    vec4 ircSample     = GetLightVolume(ircNormPos);
                    vec3 ircAmbient    = ircSample.rgb * hitAlbedo * GI_I;
                    float skyExposure  = ircSample.a;
                    vec3 skyAmbient    = ambientColor * skyExposure
                                        * max(voxelHit.hitNormal.y * 0.5 + 0.5, 0.2);

                    // Direct sun at bounce point
                    vec3 hitWorldPos = voxelHit.hitPos + cameraPosition;
                    float hitDistBias = pow(dot(voxelHit.hitPos, voxelHit.hitPos), 0.75);
                    hitDistBias = 0.25 + 0.002 * hitDistBias;
                    float hitNdotLBias = max(dot(voxelHit.hitNormal, sunDirWorld), 0.0);
                    vec3 hitBias = voxelHit.hitNormal * hitDistBias * (2.0 - 0.95 * hitNdotLBias);
                    vec3 shadowPos = GetShadowPosition(hitWorldPos + hitBias, cameraPosition);

                    vec3 directLight = vec3(0.0);
                    if (length(shadowPos.xy * 2.0 - 1.0) < 0.99) {
                        float shadow0 = shadow2D(shadowtex0, shadowPos).x;
                        if (shadow0 > 0.01) {
                            float shadow1 = shadow2D(shadowtex1, shadowPos).x;
                            float hitNdotL = max(dot(voxelHit.hitNormal, sunDirWorld), 0.0);
                            float sunFactor = hitNdotL * (1.0 - rainFactor * 0.8) * (1.0 - nightFactor * 0.5);
                            if (shadow1 > 0.01) {
                                directLight = lightColor * sunFactor;
                            } else {
                                vec3 shadowTint = texture2D(shadowcolor0, shadowPos.xy).rgb;
                                directLight = lightColor * shadowTint * sunFactor;
                            }
                        }
                    }

                    vec3 bounceColor = directLight
                                     + ircAmbient * 2.0
                                     + skyAmbient;
                    pathRadiance += pathThroughput * bounceColor;

                    // Update path state for next bounce
                    pathThroughput *= hitAlbedo;
                    currentScenePos  = voxelHit.hitPos + voxelHit.hitNormal * 0.01;
                    currentNormal    = voxelHit.hitNormal;

                } else {
                    // Ray escaped to sky
                    float groundOcclusion = exp(-max(0.0, -rayDir.y) * 9.87);
                    vec3 skyContrib = ambientColor * max(rayDir.y, 0.0) * groundOcclusion;
                    skyContrib = max(skyContrib - nightFactor * 0.05, vec3(0.0));
                    pathRadiance += pathThroughput * skyContrib;
                    pathRadiance += pathThroughput * MINIMUM_AMBIENT * (groundOcclusion * 0.5 + 0.5);
                    break;
                }
            #else
                // Fallback when voxel lighting disabled
                float groundOcclusion = exp(-max(0.0, -rayDir.y) * 9.87);
                vec3 skyContrib = ambientColor * 0.01 * max(rayDir.y, 0.0) * groundOcclusion;
                skyContrib = max(skyContrib - nightFactor * 0.1, vec3(0.0));
                pathRadiance += pathThroughput * skyContrib;
                pathRadiance += pathThroughput * MINIMUM_AMBIENT * (groundOcclusion * 0.5 + 0.5);
                break;
            #endif
        }

        totalRadiance += pathRadiance;

        #ifdef PT_USE_VOXEL_LIGHT
            float aoDither = fract(dither + float(i) * PHI_INV);
            float voxelAO = GetVoxelAO(startScenePos, worldGeoNormal, aoDither) * AO_I;
            occlusion += voxelAO;
        #endif
    }

    totalRadiance /= float(numPaths);
    occlusion     /= float(numPaths);

    // gi is purely indirect. directSunLight is already in the rasterized color that deferred9
    // mixes with gi, so including it here would double-count the sun on outdoor surfaces.
    gi.rgb = totalRadiance * 4.0;
    gi.rgb = max(gi.rgb, vec3(0.0));
    return gi;
}
