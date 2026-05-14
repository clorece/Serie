/*
    --------------------------------------------PLEASE READ--------------------------------------------
    The pathtracing implementation used here is derived from the Bliss Shaders by Xonk,
    and has been heavily modified from Bliss's version of Chocapic13's original ray tracing code.

    This ray tracing code was originally developed by Chocapic13.
    --------------------------------------------PLEASE READ--------------------------------------------
    LICENSE, AS STATED BY Chocapic13: SHARING A MODIFIED VERSION OF MY SHADERS:
        You are not allowed to claim any of the code included in "Chocapic13' shaders" as your own

        You can share a modified version of my shaders if you respect the following title scheme : " -Name of the shaderpack- (Chocapic13' Shaders edit) "

        You cannot use any monetizing links (for example adfoc.us ; adf.ly)

        The rules of modification and sharing have to be same as the one here (copy paste all these rules in your post and change depending if you allow modification or not), you cannot make your own rules, you can only choose if you allow redistribution.

        I have to be clearly credited

        You cannot use any version older than "Chocapic13' Shaders V4" as a base, however you can modify older versions for personal use
    --------------------------------------------PLEASE READ--------------------------------------------
    Special level of permission; with written permission from Chocapic13, on request if you think your shaderpack is an huge modification from the original:
        Allows to use monetizing links

        Allows to create your own sharing rules

        Shaderpack name can be chosen

        Listed on Chocapic13' shaders official thread

        Chocapic13 still have to be clearly credited
    --------------------------------------------PLEASE READ--------------------------------------------
    Using this shaderpack in a video or a picture:
        You are allowed to use this shaderpack for screenshots and videos if you give the shaderpack name in the description/message

        You are allowed to use this shaderpack in monetized videos if you respect the rule above.

    Minecraft websites:
        The download link must redirect to the download link given in the shaderpack's official thread

        There has to be a link to the shaderpack's official thread

        You are not allowed to add any monetizing link to the shaderpack download
    --------------------------------------------PLEASE READ--------------------------------------------
*/

/*
    CREDITS:
        Xonk
        Chocapic13
*/

vec2 texelSize = 1.0 / vec2(viewWidth, viewHeight);

#include "/lib/colors/blocklightColors.glsl"

#define PT_USE_RUSSIAN_ROULETTE
//#define DEBUG_SHADOW_VIEW
#if COLORED_LIGHTING_INTERNAL > 0
    #define PT_USE_VOXEL_LIGHT
#endif
#define PT_TRANSPARENT_TINTS

#define MINIMUM_AMBIENT ambientColor * 0.1

#include "/lib/misc/voxelization.glsl"

#if COLORED_LIGHTING_INTERNAL > 0
    #include "/lib/misc/voxelization.glsl"

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
        vec4 endWorld4 = gbufferModelViewInverse * vec4(endViewPos, 1.0);
        vec3 startWorld = startWorld4.xyz;
        vec3 endWorld = endWorld4.xyz;
        
        vec3 startVoxel = SceneToVoxel(startWorld);
        vec3 endVoxel = SceneToVoxel(endWorld);
        vec3 volumeSize = vec3(voxelVolumeSize);

        int steps = 24; 
        vec3 dir = endVoxel - startVoxel;
        float dist = length(dir);
        if (dist < 0.001) return tint;
        
        vec3 stepDir = dir / float(steps);
        vec3 pos = startVoxel;

        for(int i = 0; i < steps; i++) {
            pos += stepDir;

            if (any(lessThan(pos, vec3(0.5))) || any(greaterThanEqual(pos, volumeSize - 0.5))) continue;

            uint id = texelFetch(voxel_sampler, ivec3(pos), 0).r;

            if (id <= 1u) continue;
            
            if ((id >= 200u && id <= 218u) || id == 254u) {
                int idx = int(id) - 200;
                tint *= specialTintColorPT[idx];
            }
        }
        return tint;
    }
#else
    vec3 CheckVoxelTint(vec3 startViewPos, vec3 endViewPos) {
        return vec3(1.0);
    }
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

vec3 toClipSpace3(vec3 viewSpacePosition) {
    vec4 clipSpace = gbufferProjection * vec4(viewSpacePosition, 1.0);
    return clipSpace.xyz / clipSpace.w * 0.5 + 0.5;
}

struct RayHit {
    bool hit;
    vec3 screenPos;
    vec3 worldPos;
    float hitDist;
    float border;
};

RayHit MarchRay(vec3 start, vec3 rayDir, sampler2D depthtex, vec2 screenEdge, float dither, vec2 jitterOffset) {
    RayHit result;
    result.hit = false;
    result.hitDist = 0.0;
    result.border = 0.0;
    
    float maxRayDistance = float(COLORED_LIGHTING_INTERNAL);

    float baseStepSize = 0.05 * (0.5 + dither);
    float stepSize = baseStepSize;
    
    vec3 rayPos = start;
    
    vec4 initialClip = gbufferProjection * vec4(rayPos, 1.0);
    vec3 initialScreen = initialClip.xyz / initialClip.w * 0.5 + 0.5;
    float minZ = initialScreen.z;
    float maxZ = initialScreen.z;

    for (int j = 0; j < int(PT_STEPS); j++) {
        rayPos += rayDir * stepSize;
        
        vec4 rayClip = gbufferProjection * vec4(rayPos, 1.0);
        vec3 rayScreen = rayClip.xyz / rayClip.w * 0.5 + 0.5;
        
        float rayDistance = length(rayPos - start);
        
        if (rayDistance > maxRayDistance) break;
        if (rayScreen.x < 0.0 || rayScreen.x > 1.0 || 
            rayScreen.y < 0.0 || rayScreen.y > 1.0 ||
            rayScreen.z < 0.0 || rayScreen.z > 1.0) break;
        
        // ADD Jitter to sampling coordinates to match Jittered Depth Buffer
        vec2 sampleUV = (rayScreen.xy + jitterOffset) * RENDER_SCALE;
        float sampledDepth = texture2D(depthtex, sampleUV).r;
        
        float currZ = GetLinearDepth(rayScreen.z);
        float nextZ = GetLinearDepth(sampledDepth);
        
        if (nextZ < currZ && (sampledDepth <= max(minZ, maxZ) && sampledDepth >= min(minZ, maxZ))) {
            vec3 hitPos = rayPos - rayDir * stepSize * 0.5;
            float hitDist = length(hitPos - start);
            
            // Reject hit if beyond max ray distance
            if (hitDist > maxRayDistance) {
                return result; // Return no hit
            }
            
            vec4 hitClip = gbufferProjection * vec4(hitPos, 1.0);
            vec3 hitScreen = hitClip.xyz / hitClip.w * 0.5 + 0.5;
            
            result.screenPos = hitScreen;
            result.worldPos = hitPos;
            result.hitDist = hitDist;
            
            vec2 absPos = abs(result.screenPos.xy - 0.5);
            vec2 cdist = absPos / screenEdge;
            result.border = clamp(1.0 - pow(max(cdist.x, cdist.y), 50.0), 0.0, 1.0);
            
            result.hit = true;
            break;
        }
        
        float biasamount = 0.00005;
        minZ = maxZ - biasamount / currZ;
        maxZ = rayScreen.z;

        stepSize = min(stepSize, 0.1) * 2.5;
    }
    
    return result;
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

vec4 GetGI(inout vec3 occlusion, inout vec3 emissiveOut, vec3 normalM, vec3 viewPos, vec3 unscaledViewPos, vec3 nViewPos, sampler2D depthtex, 
           float dither, float smoothness, float VdotU, float VdotS, bool entityOrHand, float skyLightFactor) {
    vec2 screenEdge = vec2(0.6, 0.55);
    vec3 normalMR = normalM;

    vec4 gi = vec4(0.0);
    vec3 totalRadiance = vec3(0.0);
    vec3 emissiveRadiance = vec3(0.0);
    
    vec3 startPos = viewPos + normalMR * 0.01;
    
    if (length(viewPos) > float(PT_RENDER_DISTANCE) * 0.5) {
         #if defined OVERWORLD && !defined NETHER
            vec3 fallbackSky = ambientColor * 0.01;

            fallbackSky += ambientColor * max(normalM.y, 0.0) * 0.5;
            fallbackSky += lightColor * max(dot(normalM, lightVec), 0.5);
            fallbackSky *= skyLightFactor;
            fallbackSky *= 1.01;
            
            gi.rgb = fallbackSky;
            gi.rgb = max(gi.rgb, vec3(0.0));
            return gi;
         #else
            return vec4(0.0);
         #endif
    }

    vec3 startWorldPos = mat3(gbufferModelViewInverse) * startPos;
    
    float distanceScale = clamp(1.0 - startPos.z / far, 0.1, 1.0);
    int numPaths = int(PT_MAX_BOUNCES * distanceScale);

    vec3 receiverScenePos = (gbufferModelViewInverse * vec4(unscaledViewPos, 1.0)).xyz;
    vec3 receiverWorldPos = receiverScenePos + cameraPosition;

    vec3 worldGeoNormal = mat3(gbufferModelViewInverse) * normalM;
    float distanceBias = pow(dot(receiverScenePos, receiverScenePos), 0.75);
    distanceBias = 0.12 + 0.0008 * distanceBias;
    
    vec3 sunDirBias = mat3(gbufferModelViewInverse) * lightVec;
    float receiverNdotL = max(dot(worldGeoNormal, sunDirBias), 0.0);
    
    vec3 receiverBias = worldGeoNormal * distanceBias * (2.0 - 0.95 * receiverNdotL);
    vec3 receiverWorldPosBiased = receiverWorldPos + receiverBias;

    bool receiverInShadow = GetShadow(receiverWorldPosBiased, cameraPosition);
    float receiverShadowMask = receiverInShadow ? 0.5 : 0.25;
    float receiverShadowMask2 = receiverInShadow ? 0.1 : 0.1;
    
    vec3 receiverVoxelPos = SceneToVoxel(receiverScenePos);
    bool outsideVolume = !CheckInsideVoxelVolume(receiverVoxelPos);

    #ifdef DEBUG_SHADOW_VIEW
        gi.rgb = receiverInShadow ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        return gi;
    #endif
    
    vec3 directSunLight = vec3(0.0);
    vec3 indirectFill = vec3(0.0);
    vec3 coloredLightContrib = vec3(0.0);
    bool isDaytime = sunVisibility > 0.5;
    float shadowStrength = receiverInShadow ? 1.0 : 0.0;
    
    vec3 receiverNormPos = receiverVoxelPos / vec3(voxelVolumeSize);
    vec4 receiverLPV = vec4(0.0);

    
    #if defined OVERWORLD && !defined NETHER
        vec3 worldNormal = mat3(gbufferModelViewInverse) * normalM;
        vec3 sunDir = mat3(gbufferModelViewInverse) * lightVec;
        float NdotSun = max(dot(worldNormal, sunDir), 0.0);
        float ambientNdotU = max(dot(worldNormal, vec3(0.0, 1.0, 0.0)), 0.0) * 0.5 + 0.5;

        if (!receiverInShadow && NdotSun > 0.0) {
            
            float directShadowMask = smoothstep(0.1, 0.3, NdotSun);

            directSunLight = lightColor * NdotSun * 1.0 * (1.0 - rainFactor * 0.8);
        }

    #endif
    
    coloredLightContrib = receiverLPV.rgb;

    for (int i = 0; i < numPaths; i++) {
        vec3 pathRadiance = vec3(0.0);
        vec3 pathThroughput = vec3(1.0);
        
        vec3 currentPos = startPos;
        vec3 currentNormal = normalMR;
        int bounce = 0;
        
        for (bounce = 0; bounce < PT_MAX_BOUNCES; bounce++) {
            int seed = i * PT_MAX_BOUNCES + bounce;
            vec3 rayDir = RayDirection(currentNormal, dither, seed);
            float NdotL = max(dot(currentNormal, rayDir), 0.0);

            float rayDither = fract(dither + float(seed) * PHI_INV);

            vec2 jitterOffset = (TAAJitter(vec2(0.5), 1.0) - 0.5);

            RayHit hit = MarchRay(currentPos, rayDir, depthtex, screenEdge, rayDither, jitterOffset);
            
            bool useScreenspace = hit.hit && hit.screenPos.z < 0.99997 && hit.border > 0.001;
            
            #ifdef PT_USE_VOXEL_LIGHT
                if (useScreenspace) {
                    vec3 hitScenePos = (gbufferModelViewInverse * vec4(hit.worldPos, 1.0)).xyz;
                    vec3 voxelHitPos = SceneToVoxel(hitScenePos);
                    if (CheckInsideVoxelVolume(voxelHitPos)) {
                        uint voxelData = texelFetch(voxel_sampler, ivec3(voxelHitPos), 0).r;

                        if (voxelData > 0u && voxelData != 225u) {
                            useScreenspace = false;
                        }
                    }
                }
            #endif

            
            if (useScreenspace) {
                vec2 edgeFactor = pow2(pow2(pow2(abs(hit.screenPos.xy - 0.5) / screenEdge)));
                vec2 jitteredUV = hit.screenPos.xy + jitterOffset;
                jitteredUV.y += (dither - 0.5) * (0.05 * (edgeFactor.x + edgeFactor.y));
                
                // Deferred texture sampling - sample once with appropriate LOD
                float lod = max(log2(hit.hitDist * 0.5) * 0.5, 0.0);
                vec2 sampleUV = jitteredUV * RENDER_SCALE;
                
                // Single albedo fetch at LOD (used for color + BRDF)
                vec3 hitAlbedo = texture2DLod(colortex0, sampleUV, lod).rgb;
                vec3 hitColor = hitAlbedo * (1.0 - nightFactor * 0.2);
                
                // Normal fetch at LOD 0 for accuracy
                vec3 hitNormal = normalize(texture2DLod(colortex5, sampleUV, 0.0).rgb * 2.0 - 1.0);



                vec3 voxelTint = CheckVoxelTint(currentPos, hit.worldPos);

                vec3 brdf = EvaluateBRDF(hitAlbedo, currentNormal, rayDir, -normalize(currentPos));
                float pdf = CosinePDF(NdotL);

                vec3 throughputMult = brdf * NdotL / max(pdf, 0.0001);
                pathThroughput *= sqrt(throughputMult + 0.01);

                #if defined (PT_TRANSPARENT_TINTS) && defined (PT_USE_VOXEL_LIGHT)
                    pathThroughput *= voxelTint;
                #endif

                float blockLightMask = 1.0;

                #ifdef PT_USE_RUSSIAN_ROULETTE
                if (bounce > 0) {
                    float continueProbability = min(max(pathThroughput.x, max(pathThroughput.y, pathThroughput.z)), 0.95);
                    if (randWithSeed(dither, seed + 1000) > continueProbability) {
                        break;
                    }
                    pathThroughput /= continueProbability;
                }
                #endif

                currentPos = hit.worldPos + rayDir * 0.01;
                currentNormal = hitNormal;

                
                #ifdef TEMPORAL_FILTER
                    vec3 cameraOffset = cameraPosition - previousCameraPosition;
                    vec2 prevHitUV = Reprojection(hit.screenPos, cameraOffset);
                    
                    if (prevHitUV.x > 0.0 && prevHitUV.x < 1.0 && prevHitUV.y > 0.0 && prevHitUV.y < 1.0) {
                        float prevDepth = texture2D(colortex1, prevHitUV * RENDER_SCALE).r;
                        float currDepth = texture2D(depthtex, prevHitUV * RENDER_SCALE).r; 

                        if (abs(GetLinearDepth(prevDepth) - GetLinearDepth(currDepth)) < 0.5) {
                             vec3 historyRadiance = texture2D(colortex11, prevHitUV * RENDER_SCALE).rgb;
                             pathRadiance += pathThroughput * historyRadiance * 0.9;

                             break;
                        }
                    }
                #endif
                

                pathRadiance += pathThroughput * hitColor * blockLightMask;
                
                //float giBoost = mix(0.2, 0.6, shadowStrength);
                //pathRadiance *= giBoost;
                
            } else {
            
                vec3 worldRayDir = mat3(gbufferModelViewInverse) * rayDir;
                vec3 currentScenePos = (gbufferModelViewInverse * vec4(currentPos, 1.0)).xyz;
                
                #ifdef PT_USE_VOXEL_LIGHT
                    // --- Volumetric floodfill sampling with occlusion ---
                    // Sample the floodfill volume along the ray, stopping at solid geometry
                    {
                        vec3 volSamplePos = currentScenePos;
                        vec3 volStep = worldRayDir * 2.0; // Step every 2 blocks
                        int volSteps = min(int(32.0 / 2.0), 16);
                        vec3 volLight = vec3(0.0);
                        for (int vs = 0; vs < volSteps; vs++) {
                            volSamplePos += volStep;
                            vec3 voxP = SceneToVoxel(volSamplePos);
                            if (!CheckInsideVoxelVolume(voxP)) break;
                            
                            // Stop accumulating if we hit solid geometry
                            uint volVoxel = texelFetch(voxel_sampler, ivec3(voxP), 0).r;
                            if (volVoxel == 1u) break;
                            
                            vec3 normP = voxP / vec3(voxelVolumeSize);
                            vec4 lSample = GetLightVolume(normP);
                            volLight += lSample.rgb;
                        }
                        pathRadiance += pathThroughput * volLight * 0.1;
                        #ifdef NETHER
                            pathRadiance *= 0.25;
                        #endif
                    }

                    // --- Phase 1: Self-sufficient emissive discovery ---
                    VoxelHitResult voxelHit = TraceVoxelHit(currentScenePos, worldRayDir, shadowDistance);
                    
                    if (voxelHit.hit) {
                        // === If we hit an emissive block, use its light directly ===
                        if (voxelHit.isEmissive) {
                            vec3 emissiveLight = voxelHit.light;
                            float emissiveDist = max(length(voxelHit.hitPos - currentScenePos), 0.5);
                            float emissiveFalloff = 1.0 / (1.0 + emissiveDist * emissiveDist * 0.02);
                            pathRadiance += pathThroughput * emissiveLight * emissiveFalloff;
                            break;
                        }
                        
                        // === Non-emissive solid block hit — evaluate lighting at that surface ===
                        vec3 hitWorldPos = voxelHit.hitPos + cameraPosition;

                        float distanceBias = pow(dot(voxelHit.hitPos, voxelHit.hitPos), 0.75);
                        distanceBias = 0.25 + 0.002 * distanceBias;
                        
                        vec3 sunDirBias = mat3(gbufferModelViewInverse) * lightVec;
                        float hitNdotLBias = max(dot(voxelHit.hitNormal, sunDirBias), 0.0);
                        
                        vec3 bias = voxelHit.hitNormal * distanceBias * (2.0 - 0.95 * hitNdotLBias);
                        hitWorldPos += bias;

                        vec3 shadowPos = GetShadowPosition(hitWorldPos, cameraPosition);
                        
                        vec3 shadowTint = vec3(1.0);
                        bool inShadow = true;
                        
                        if (length(shadowPos.xy * 2.0 - 1.0) < 0.99) {
                            float shadow0 = shadow2D(shadowtex0, shadowPos).x;
                            if (shadow0 > 0.01) {
                                float shadow1 = shadow2D(shadowtex1, shadowPos).x;
                                if (shadow1 > 0.01) {
                                    inShadow = false;
                                } else {
                                    shadowTint = texture2D(shadowcolor0, shadowPos.xy).rgb;
                                    inShadow = false;
                                }
                            }
                        }

                        vec3 directLight = vec3(0.0);
                        
                        vec3 albedoPos = voxelHit.hitPos - voxelHit.hitNormal * 0.05;
                        vec3 voxelAlbedo = GetVoxelAlbedo(albedoPos);
                        
                        // --- Direct sunlight at bounce hit ---
                        if (!inShadow) {
                            float hitNdotL = max(dot(voxelHit.hitNormal, sunDirBias), 0.0);
                            vec3 sunAlbedo = voxelAlbedo * 20.0 * min(0.25, receiverShadowMask);
                            directLight = (lightColor * 0.5 + sunAlbedo * 0.5) * 2.0 * hitNdotL * (1.0 - rainFactor * 0.8) * (1.0 - nightFactor * 2.0) + pow2(1.0 - skyLightFactor) * receiverShadowMask;
                            directLight *= shadowTint;
                        }

                        // --- Self-sufficient emissive discovery with shadow verification ---
                        // Trace short rays from the bounce hit to find nearby emissive blocks,
                        // then verify line-of-sight with a shadow ray
                        vec3 discoveredEmissive = vec3(0.0);
                        vec3 hitScenePos = voxelHit.hitPos + voxelHit.hitNormal * 0.1;
                        
                        const int EMISSIVE_DISCOVERY_RAYS = 3;
                        for (int er = 0; er < EMISSIVE_DISCOVERY_RAYS; er++) {
                            int erSeed = seed * 100 + er + bounce * 37;
                            vec3 erDir = RayDirection(voxelHit.hitNormal, dither, erSeed);
                            VoxelRayResult emissiveTrace = TraceVoxelRay(hitScenePos, erDir, 24.0, fract(dither + float(erSeed) * PHI_INV));
                            
                            if (emissiveTrace.hitEmissive) {
                                // The ray traced directly to the emitter through the DDA,
                                // so line-of-sight is already confirmed (it would have hit
                                // a solid block first if occluded). Apply NdotL weighting.
                                float erNdotL = max(dot(voxelHit.hitNormal, erDir), 0.0);
                                float erDist = max(emissiveTrace.distance, 0.5);
                                float erFalloff = 1.0 / (1.0 + erDist * erDist * 0.04);
                                discoveredEmissive += emissiveTrace.light * erNdotL * erFalloff;
                            }
                        }
                        discoveredEmissive /= float(EMISSIVE_DISCOVERY_RAYS);
                        
                        // --- LPV for ambient fill with directional weighting ---
                        vec3 samplePos = voxelHit.hitPos + voxelHit.hitNormal * 0.5;
                        vec3 voxelPos = SceneToVoxel(samplePos);
                        vec3 normPos = voxelPos / vec3(voxelVolumeSize);
                        vec4 lpvLight = GetLightVolume(normPos);
                        
                        // Direction-aware LPV: sample from offset in normal direction
                        // to reduce light bleeding through walls
                        vec3 samplePosDeep = voxelHit.hitPos + voxelHit.hitNormal * 1.5;
                        vec3 voxelPosDeep = SceneToVoxel(samplePosDeep);
                        vec3 normPosDeep = voxelPosDeep / vec3(voxelVolumeSize);
                        vec4 lpvLightDeep = GetLightVolume(normPosDeep);
                        
                        // Use the minimum of near and deep samples to reduce bleed
                        vec3 lpvFinal = min(lpvLight.rgb, lpvLightDeep.rgb);
                        vec3 lpvAmbient = lpvFinal * voxelAlbedo * 0.1;

                        // --- Sky ambient approximation ---
                        float skyExposure = max(lpvLight.a, lpvLightDeep.a);
                        vec3 skyAmbient = ambientColor * 0.05 * max(voxelHit.hitNormal.y * 0.5 + 0.5, 0.2) * skyExposure;

                        // --- Combine ---
                        vec3 bounceColor = directLight 
                                         + discoveredEmissive * voxelAlbedo
                                         + lpvAmbient
                                         + skyAmbient;
                        
                        pathRadiance += pathThroughput * bounceColor;
                        
                    } else {
                        // Ray escaped — sky contribution
                        float groundOcclusion = exp(-max(0.0, -worldRayDir.y) * 9.87);
                        vec3 sampledSky = ambientColor * 0.01;
                        vec3 skyContribution = sampledSky * max(worldRayDir.y, 0.0) * groundOcclusion;
                        skyContribution -= nightFactor * 0.1;
                        pathRadiance += pathThroughput * skyContribution;
                        pathRadiance += pathThroughput * MINIMUM_AMBIENT * (groundOcclusion * 0.5 + 0.5);
                    }
                    
                #else
                    float groundOcclusion = exp(-max(0.0, -worldRayDir.y) * 9.87);
                    vec3 sampledSky = ambientColor * 0.01;
                    vec3 skyContribution = sampledSky * max(worldRayDir.y, 0.0) * groundOcclusion;
                    skyContribution -= nightFactor * 0.1;
                    pathRadiance += pathThroughput * skyContribution;
                    pathRadiance += pathThroughput * MINIMUM_AMBIENT * (groundOcclusion * 0.5 + 0.5);
                #endif
                
                break;
            }
        } 
        
        totalRadiance += pathRadiance;
        
        float aoDither = fract(dither + float(i) * PHI_INV);
        
        /*float screenSpaceAO = 0.0;
        RayHit firstHit = MarchRay(startPos, RayDirection(normalMR, dither, i), depthtex, screenEdge, aoDither);
        if (firstHit.hit) {
            float aoRadius = AO_RADIUS;
            float curve = 1.0 - clamp(firstHit.hitDist / aoRadius, 0.0, 1.0);
            curve = pow(curve, 2.0);
            screenSpaceAO = curve * AO_I * 1.5 * max(skyLightFactor, 0.1) - (nightFactor * 1.5 + invNoonFactor * 1.0);
        }
        */
        
        #ifdef PT_USE_VOXEL_LIGHT
            vec3 worldNormalAO = mat3(gbufferModelViewInverse) * normalMR;
            float voxelAO = GetVoxelAO(startWorldPos, worldNormalAO, aoDither) * AO_I;// * max(skyLightFactor, 0.1);

            occlusion += voxelAO;
        #else
        #endif
    }
    
    totalRadiance /= float(numPaths);
    occlusion /= float(numPaths);
    
    #if defined DEFERRED1 && defined TEMPORAL_FILTER
        giScreenPos = vec3(texCoord, 1.0);
    #endif
    
    gi.rgb = directSunLight + indirectFill + coloredLightContrib + totalRadiance;
    gi.rgb = max(gi.rgb, vec3(0.0));
    //gi.rgb = clamp(gi.rgb, vec3(0.0), vec3(1.0));
    return gi;
}