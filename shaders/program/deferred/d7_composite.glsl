// d7_composite : final scene lighting
// Combines raw albedo (colortex0, untouched since the gbuffers) with direct
// sunlight (shadows + contact shadows) and the denoised indirect term
// (colortex6, produced by d0_restir -> d1..d6 denoise). Writes colortex0.
// Sky pixels are left as-is here and replaced by d8_fog_sky.

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


float depth0 = texture(depthtex0, texCoord).r;
float material = texelFetch(colortex1, ivec2(gl_FragCoord.xy), 0).a;
vec3 normal = normalize(texture(colortex1, texCoord).rgb * 2.0 - 1.0);
vec3 lightmap = texture(colortex2, texCoord).rgb;

vec3 clipSpace;

#include "/lib/util/dither.glsl"
#include "/lib/util/positions.glsl"

vec3 getLightmap(vec3 l) {
    l.x = 1.0 * pow(l.x, 5.06);

    vec3 sunVec = normalize(sunPosition);
    vec3 upVec  = normalize(upPosition);
    float sunUp = clamp(dot(sunVec, upVec), 0.0, 1.0);
    float skyExposure = smoothstep(0.75, 0.9, l.y);
    float blocklightSuppression = mix(1.0, 0.05, sunUp * skyExposure);

    vec3 torchLighting = l.x * torchColor * blocklightSuppression;
    vec3 skyLighting = l.y * ambientColor;
    return torchLighting + skyLighting;
}

float getNdotL(vec3 n, vec3 l) {
    float dotNL = dot(n, l);


    if (material > 0.16 && material < 0.83) {
        return max(dotNL * 0.5 + 0.5, 0.0);
    }

    float roughness = 0.5;
    vec3 v = normalize(-getFragPosition().xyz);
    vec3 h = normalize(l + v);
    float dotNV = clamp(dot(n, v), 1e-5, 1.0);
    float dotLH = clamp(dot(l, h), 0.0, 1.0);

    float fd90 = 0.5 + 2.0 * dotLH * dotLH * roughness;
    float lightScatter = 1.0 + (fd90 - 1.0) * pow(1.0 - clamp(dotNL, 0.0, 1.0), 5.0);
    float viewScatter  = 1.0 + (fd90 - 1.0) * pow(1.0 - dotNV, 5.0);

    return max(dotNL, 0.0) * lightScatter * viewScatter;
}

float getInfiniteShadows(vec3 viewPos, vec3 lightDir, float dither, vec3 normalView, float material) {
    float viewDist = length(viewPos);
    
    float isFar = smoothstep(shadowDistance * 0.8, shadowDistance * 1.2, viewDist);
    bool isFoliage = (material > 0.16 && material < 0.83);
    
    if (isFoliage && isFar <= 0.0) {
        return 1.0;
    }
    
    float rayLength = mix(clamp(viewDist * 0.1, 0.25, 2.5), 128.0, isFar);
    int steps = int(mix(12.0, 32.0, isFar));
    
    vec3 stepVec = lightDir * (rayLength / float(steps));
    float stepLen = length(stepVec);


    float nBias = mix(0.05 + viewDist * 0.005, 0.2, isFar);
    vec3 rayPos = viewPos + normalView * nBias + stepVec * dither;

    float sscs = 1.0;
    

    float thickness = max(stepLen * 1.5, mix(0.15, 8.0, isFar));
    

    float distTolerance = mix(0.005, 0.002, isFar) + abs(viewPos.z) * 0.001;

    for (int i = 0; i < steps; i++) {
        rayPos += stepVec;

        vec4 clipPos = gbufferProjection * vec4(rayPos, 1.0);
        vec3 ndcPos = clipPos.xyz / clipPos.w;
        vec2 uv = ndcPos.xy * 0.5 + 0.5;

        if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) break;

        float depth = textureLod(depthtex0, uv, 0.0).r;
        if (depth >= 1.0) break;

        vec4 sampleClip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
        vec4 sampleView = gbufferProjectionInverse * sampleClip;
        float sampleZ = sampleView.z / sampleView.w;


        float zDiff = sampleZ - rayPos.z;
        if (zDiff > distTolerance && zDiff < thickness) {
            sscs = smoothstep(0.6, 1.0, float(i) / float(steps));
            break;
        }
    }


    vec4 startClip = gbufferProjection * vec4(viewPos, 1.0);
    vec2 startUV = (startClip.xy / startClip.w) * 0.5 + 0.5;
    float edgeFade = smoothstep(0.0, 0.1, min(min(startUV.x, 1.0 - startUV.x), min(startUV.y, 1.0 - startUV.y)));

    float shadowResult = mix(1.0, sscs, edgeFade);
    if (isFoliage) {
        // fade in the shadow based on distance to prevent glowing distant trees, while preserving subsurface scattering up close.
        shadowResult = mix(1.0, shadowResult, isFar);
    }
    return shadowResult;
}

#include "/lib/fragment/shadows.glsl"
#include "/lib/fragment/clouds.glsl"

#ifdef PT_DEBUG_VOXELS
#include "/lib/pt/voxelData.glsl"
#endif


#include "/lib/util/positions.glsl"
#include "/lib/pt/ddaTrace.glsl"

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord).rgb;

    #ifdef SSPT_DEBUG
        if (depth0 < 1.0) {
            vec3 viewPos = convertScreenSpaceToWorldSpace(unjitteredTexCoord, depth0); // view space
            vec3 originV = viewPos + normal * 0.15;                 // colortex1 is view normals
            vec2 cj      = texCoord - unjitteredTexCoord;           // TAA jitter (buffer = geom + cj)
            uint seed    = pixelSeed(ivec2(gl_FragCoord.xy), frameCounter);

            vec3  acc  = vec3(0.0);
            float hits = 0.0;
            for (int i = 0; i < SSPT_DEBUG_SAMPLES; i++) {
                vec3 dir = sspt_dbgHemisphere(normal, randFloat(seed), randFloat(seed));
                vec2 uvh; float rawh;
                if (traceScreenSpace(depthtex0, gbufferProjection, originV, dir,
                                     float(SSPT_DIST), SSPT_STEPS, SSPT_THICKNESS,
                                     randFloat(seed), cj, uvh, rawh)) {
                    acc += texture(colortex5, uvh + cj).rgb;
                    hits += 1.0;
                }
            }
            float frac = hits / float(SSPT_DEBUG_SAMPLES);
            #if SSPT_DEBUG == 1
                gl_FragData[0] = vec4(1.0 - frac, frac, 0.0, 1.0);     // red=miss, green=hit
            #else
                gl_FragData[0] = vec4(acc / float(SSPT_DEBUG_SAMPLES), 1.0);
            #endif
        } else {
            gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0);
        }
        return;
    #endif

    float diffuse = getNdotL(normal, lightVector);
    float skyOcc = sqrt(lightmap.y);
    
    vec3 directShadow = getShadow(material);
    #ifdef SCREENSPACE_SHADOWS
    if (depth0 < 1.0) {
        float ditherVal = interleavedGradientNoise(floor(gl_FragCoord.xy), frameCounter);
        vec3 viewPos = getFragPosition().xyz;

        directShadow *= getInfiniteShadows(viewPos, lightVector, ditherVal, normal, material);
    }
    #endif
    // Cloud shadow on direct sun. The 512² distortion-warped projection
    // (built in prepare1) gives free per-pixel sun occlusion under cumulus.
    // Fade with rainStrength because vanilla rain replaces cumulus rendering
    // with a uniform overcast — applying cumulus-shaped shadows during rain
    // would look out of place.
    float cloudShadow = 1.0;
    if (depth0 < 1.0) {
        vec3 worldPosAbs = getWorldPosition().xyz + cameraPosition;
        cloudShadow = mix(1.0, sampleCloudShadow(worldPosAbs), 1.0 - rainStrength);
    }

    vec3 direct = diffuse * lightColor * directShadow * cloudShadow * (1.0 - (rainStrength * 0.75)) * skyOcc;


    if (material > 0.16 && material < 0.83 && depth0 < 1.0) {
        vec3 viewPos = getFragPosition().xyz;
        float VdotL = max(dot(normalize(-viewPos), lightVector), 0.0);
        
        float sssPhase = pow(VdotL, 10.0) * 0.6;
        
        float NdotL = max(dot(normal, lightVector), 0.0);
        float backfaceMask = clamp(1.0 - NdotL, 0.0, 1.0);
        
        vec3 sssLight = lightColor * directShadow * cloudShadow * sssPhase * backfaceMask * (1.0 - rainStrength * 0.75);

        direct += sssLight * lightmap.y * 2.5;
    }

    float aoTerm = 1.0;
    #ifdef AO_GTAO
        if (depth0 < 1.0) {
            aoTerm = texture(colortex9, texCoord).a;
        }
    #endif

    vec3 indirect;
    #if defined(VOXEL_GI)
        #ifdef GI_DENOISE
            vec3 gi = texture(colortex3, texCoord).rgb; // denoised GI: the a-trous chain lands on colortex3
        #else
            vec3 gi = texture(colortex8, texCoord).rgb; // denoiser off: raw temporally-accumulated GI (chain passes are disabled)
        #endif
        #ifdef AO_GTAO
            #ifdef LIGHTING_AO_FULL
                gi *= aoTerm;
            #else
                gi *= mix(1.0, aoTerm, float(AO_GI_STRENGTH) / 100.0);
            #endif
        #endif

        float rasterAmbientFloor = float(PT_RASTER_AMBIENT_FLOOR) * 0.001;
        if (rasterAmbientFloor > 0.0) {
            float giLuma = dot(gi, vec3(0.2126, 0.7152, 0.0722));
            float floorMask = 1.0 - smoothstep(rasterAmbientFloor, rasterAmbientFloor * 4.0, giLuma);
            gi = max(gi, vec3(rasterAmbientFloor * floorMask));
        }

        // prevent skylight illumination from the path tracer from illuminating sunlit terrain, but ensure that path-traced emissives (blocklight, warm bounces) ignore this restriction.
        float skyRatio = 0.22 / 0.4;
        float emissiveWeight = clamp((gi.r - gi.b * skyRatio) / max(gi.r, 1e-5), 0.0, 1.0);
        emissiveWeight = max(emissiveWeight, clamp(lightmap.x * 4.0, 0.0, 1.0));

        vec3 giSkyComponent = gi * (1.0 - emissiveWeight);
        vec3 giEmissiveComponent = gi * emissiveWeight;

        giSkyComponent *= vec3(1.0) - (directShadow * max(dot(normal, lightVector), 0.0));
        gi = giSkyComponent + giEmissiveComponent;

        indirect = gi;
    #elif defined(AO_GTAO)
        indirect = (getLightmap(lightmap) + vec3(ambientStrength)) * aoTerm;
    #elif defined(VOXEL_AO)
        #ifdef GI_DENOISE
            float ao = texture(colortex3, texCoord).r; // denoised AO: the a-trous chain lands on colortex3
        #else
            float ao = texture(colortex8, texCoord).r; // denoiser off: raw temporally-accumulated AO
        #endif
        float aoFactor = mix(1.0, ao, float(AO_STRENGTH) / 100.0);
        indirect = (getLightmap(lightmap) + vec3(ambientStrength)) * aoFactor;
    #else
        indirect = getLightmap(lightmap) + vec3(ambientStrength);
    #endif

    #if defined(AO_GTAO) && (AO_DIRECT_STRENGTH > 0)
        direct *= mix(1.0, aoTerm, float(AO_DIRECT_STRENGTH) / 100.0);
    #endif

    #if PT_LIGHT_DEBUG > 0
        if (depth0 < 1.0) {
            #if PT_LIGHT_DEBUG == 1
                gl_FragData[0] = vec4(vec3(aoTerm), 1.0);
            #elif PT_LIGHT_DEBUG == 2
                gl_FragData[0] = vec4(indirect, 1.0);
            #elif PT_LIGHT_DEBUG == 3
                gl_FragData[0] = vec4(directShadow, 1.0);
            #else
                gl_FragData[0] = vec4(color, 1.0);
            #endif
            return;
        }
    #endif

    direct   *= float(LIGHTING_DIRECT)   / 100.0;
    indirect *= float(LIGHTING_INDIRECT) / 100.0;

    // TODO reimplement
    if (material > 0.83) {
        float albedoBrightness = max(color.r, max(color.g, color.b));
        float isGlowing = smoothstep(0.3, 0.7, albedoBrightness);

        vec3 shadedColor = color * (direct + indirect);
        float emissiveBoost = mix(2.5 * float(GI_EMISSION), 1.0, lightmap.y);
        vec3 glowingColor = color * (direct + indirect * emissiveBoost);

        color = mix(shadedColor, glowingColor, isGlowing);
    } else {
        color = color * (direct + indirect);
    }

    // voxel grid debug overlay (enable PT_DEBUG_VOXELS in options.glsl)
    #ifdef PT_DEBUG_VOXELS
    if (depth0 < 1.0) {
        vec3 gridOrigin = floor(cameraPosition) - VOXEL_RADIUS_VEC;
        vec3 rayOrig = cameraPosition - gridOrigin;
        vec3 rayDir  = normalize(getWorldPosition().xyz);

        ivec3 voxPos = ivec3(floor(rayOrig));
        ivec3 rayStep = ivec3(sign(rayDir));
        vec3 tDelta = 1.0 / max(abs(rayDir), vec3(1e-6));
        vec3 tMax   = (vec3(voxPos) + max(vec3(rayStep), vec3(0.0)) - rayOrig) / rayDir;

        bool hit = false;
        vec3 hitAlbedo = vec3(0.0);
        for (int i = 0; i < 768; i++) {
            if (any(lessThan(voxPos, ivec3(0))) || any(greaterThanEqual(voxPos, VOXEL_DIMS))) break;
            VoxelSample vs = readVoxel(voxelSampler, voxPos);
            if (vs.category != VOXEL_AIR) { hit = true; hitAlbedo = vs.albedo; break; }
            bvec3 mask = lessThanEqual(tMax.xyz, min(tMax.yzx, tMax.zxy));
            tMax  += vec3(mask) * tDelta;
            voxPos += ivec3(mask) * rayStep;
        }
        if (hit) color = hitAlbedo;
    }
    #endif

    // DEBUG VIEW: Skylight Illumination
    // We output the raw/denoised GI buffer (colortex6) directly to the screen.
    // This allows you to see exactly the indirect light reaching the surface!
    #ifdef GI_DEBUG_VIEW
        #ifdef GI_DENOISE
            vec3 debugIllum = texture(colortex3, texCoord).rgb;
        #else
            vec3 debugIllum = texture(colortex8, texCoord).rgb;
        #endif
        /* RENDERTARGETS: 0 */
        gl_FragData[0] = vec4(debugIllum, 1.0);
    #else
        /* RENDERTARGETS: 0 */
        gl_FragData[0] = vec4(color, 1.0);
    #endif
}

#endif
