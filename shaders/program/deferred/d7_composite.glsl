// d7_composite : final scene lighting
// Combines raw albedo (colortex0, untouched since the gbuffers) with direct
// sunlight (shadows + contact shadows) and an indirect term. The indirect term
// is the integration seam for the Lumen stack -- see the "Indirect" block below
// for the contract it must satisfy; until Phase 3 lands the GI buffer it falls
// back to the analytic lightmap ambient.
// Writes colortex0 (lit HDR scene) and colortex6 (pbrSunVis).
// Sky pixels are left as-is here and replaced by d8_fog_sky.

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


#include "/lib/dh/dh.glsl"

float depth0 = texture(depthtex0, texCoord * renderScale).r;
float material = texelFetch(colortex1, ivec2(gl_FragCoord.xy), 0).a;
vec3 normal = normalize(texture(colortex1, texCoord * renderScale).rgb * 2.0 - 1.0);
vec3 lightmap = texture(colortex2, texCoord * renderScale).rgb;

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

        float depth = textureLod(depthtex0, uv * renderScale, 0.0).r;
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



#include "/lib/util/positions.glsl"
#include "/lib/pt/voxelTrace.glsl"

// Read-only access to the surface cache, for GI_DEBUG_VIEW 3.
#define SC_READ

// GI_DEBUG_VIEW 8 inspects the feedback request volume, so bind it only for that
// view -- this pass must never STAMP requests (no SC_FEEDBACK_WRITE), or the
// debug ray would keep bricks warm that nothing real is looking at and the view
// would report on itself.
#if GI_DEBUG_VIEW == 8 && defined(SURFACE_CACHE_FEEDBACK)
    #define SC_FEEDBACK
#endif

#include "/lib/pt/surfaceCache.glsl"

#ifdef DISTANT_HORIZONS
// dhLighting.glsl provides dhSunShadow (the shadow-map term used below).
#include "/lib/fragment/dhLighting.glsl"
#include "/lib/fragment/pbrCommon.glsl"
#include "/lib/fragment/directSpecular.glsl"
#include "/lib/fragment/sky.glsl"

// Deferred shading for a Distant Horizons LOD terrain pixel. Reads the same
// globals d7 already populated from colortex1/2 (normal, lightmap, material) —
// those hold the DH g-buffer at DH pixels — and reconstructs view position from
// the DH depth. Mirrors the near-scene lighting (direct sun + foliage SSS +
// lightmap/sky ambient + emissive) but without voxel GI (DH is out of range) and
// with a far screen-space shadow that marches the DH depth buffer.
vec3 shadeDhTerrain(vec3 viewPos, vec3 albedo) {
    vec3  worldNormal = normalize(mat3(gbufferModelViewInverse) * normal);
    vec3  playerPos   = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
    bool  foliage     = (material > 0.16 && material < 0.83);

    // Diffuse NdotL — identical model to the near scene's getNdotL: wrap-around for
    // foliage, Burley/Disney diffuse otherwise (using the DH view position for V).
    float NdotL = dot(normal, lightVector);
    float diffuse;
    if (foliage) {
        diffuse = max(NdotL * 0.5 + 0.5, 0.0);
    } else {
        float roughness = 0.5;
        vec3  v     = normalize(-viewPos);
        vec3  h     = normalize(lightVector + v);
        float dotNV = clamp(dot(normal, v), 1e-5, 1.0);
        float dotLH = clamp(dot(lightVector, h), 0.0, 1.0);
        float fd90  = 0.5 + 2.0 * dotLH * dotLH * roughness;
        float ls    = 1.0 + (fd90 - 1.0) * pow(1.0 - clamp(NdotL, 0.0, 1.0), 5.0);
        float vs    = 1.0 + (fd90 - 1.0) * pow(1.0 - dotNV, 5.0);
        diffuse     = max(NdotL, 0.0) * ls * vs;
    }
    // DH LODs are outdoors; if the LOD lightmap is missing/low, don't let the
    // whole tile go black — floor the sky exposure so it still receives sun+sky.
    // A large safety floor lifts genuinely dark DH faces and makes the LOD ring
    // flatter/brighter than regular terrain, especially at high indirect light.
    float skyLight = max(lightmap.y, 0.08);
    float skyOcc   = sqrt(skyLight);

    vec3 shadow = dhSunShadow(playerPos, worldNormal, lightmap.y, NdotL, material); // shadow map (near range)
    #ifdef SCREENSPACE_SHADOWS
        float dith = interleavedGradientNoise(floor(gl_FragCoord.xy), frameCounter);
        shadow *= dhScreenShadow(viewPos, normal, lightVector, dith); // far LOD self-shadowing
    #endif

    float cloudShadow = mix(1.0, sampleCloudShadow(playerPos + cameraPosition), 1.0 - rainStrength);
    vec3  direct = diffuse * lightColor * shadow * cloudShadow * (1.0 - rainStrength * 0.75) * skyOcc;

    if (foliage) {
        float VdotL    = max(dot(normalize(-viewPos), lightVector), 0.0);
        float sssPhase = pow(VdotL, 10.0) * 0.6;
        float backface = clamp(1.0 - NdotL, 0.0, 1.0);
        direct += lightColor * shadow * cloudShadow * sssPhase * backface
                * (1.0 - rainStrength * 0.75) * lightmap.y * 2.5;
    }

    // Ambient. DH is out of the voxel-GI range, so approximate the near scene's
    // resolved sky irradiance with the SAME base the cache is fed (irc_update.glsl:
    // ambientColor * GI_SKY_BRIGHTNESS, warmed by GI_SKY_WARMTH) — this is what
    // makes the LODs read warm/golden like the near terrain instead of flat-blue.
    // Hemisphere weight + a mild "sky ambient dims where directly sunlit" term
    // (mirrors d7's giSkyComponent modulation) give it shape instead of flatness.
    float shadowLuma = dot(shadow, vec3(0.2126, 0.7152, 0.0722));
    vec3  giSky = ambientColor * float(GI_SKY_BRIGHTNESS);
    giSky *= mix(vec3(1.0), vec3(1.25, 1.04, 0.72), GI_SKY_WARMTH);
    // DH has no voxel GI/AO, so recover large-scale form from its geometry normal.
    // The previous 65% wall floor erased most of the slope contrast.
    float hemi = 0.14 + 0.86 * pow(max(worldNormal.y, 0.0), 1.35);
    // Match the near GI path: sky irradiance yields to visible direct light
    // instead of stacking a half-strength ambient wash on sun-facing surfaces.
    vec3 ambient = giSky * skyLight * hemi;

    #ifdef VOXEL_GI
        // Reproduce d0_trace's energy pipeline for the raster DH fallback. Near
        // terrain applies GI_STRENGTH, a small light-colour tint, and the source
        // luminance clamp before d7 receives the resolved indirect buffer. DH
        // previously skipped all three, so LIGHTING_INDIRECT amplified a much
        // larger raw ambient value than it did on regular terrain.
        ambient *= float(GI_STRENGTH) / 100.0;

        vec3 normLightCol = lightColor
                          / max(dot(lightColor, vec3(0.2126, 0.7152, 0.0722)), 0.1);
        ambient = mix(ambient, ambient * normLightCol, 0.10);

        float ambientLuma = dot(ambient, vec3(0.2126, 0.7152, 0.0722));
        if (GI_FIREFLY_MAX < 1000.0 && ambientLuma > GI_FIREFLY_MAX) {
            ambient *= GI_FIREFLY_MAX / ambientLuma;
        }
    #endif

    float directSkyMask = 1.0 - shadowLuma * max(NdotL, 0.0);
    ambient *= directSkyMask;

    // Torch term (matches getLightmap's daylight suppression).
    float sunUpA = clamp(dot(normalize(sunPosition), normalize(upPosition)), 0.0, 1.0);
    float blockSupp = mix(1.0, 0.05, sunUpA * smoothstep(0.75, 0.9, skyLight));
    vec3  torch = pow(lightmap.x, 5.06) * torchColor * blockSupp;

    vec3 indirect = ambient + torch;

    direct   *= float(LIGHTING_DIRECT)   / 100.0;
    // LIGHTING_INDIRECT DOES apply here, and this is the path it is really for.
    // Everything in `indirect` above is a rasterised fill: `ambient` is a pure
    // hemisphere term (hemi = 0.14 + 0.86 * pow(n.y, 1.35)) with no occlusion of
    // any kind, and `torch` is the vanilla blocklight lightmap. Both are scaled
    // by GI_STRENGTH and GI_SKY_BRIGHTNESS just above so DH LOD matches the
    // near-field GI's brightness -- but having no occlusion term, it goes flat
    // as those are raised, which is exactly what LIGHTING_INDIRECT is for
    // trimming. Phase 3.2 replaces this block with a far-field probe lookup.
    indirect *= float(LIGHTING_INDIRECT) / 100.0;

    // Small DH-only exposure trim. The LOD albedo is a spatially averaged block
    // colour and therefore retains less dark texture detail than regular terrain;
    // this keeps its perceived brightness aligned without changing either global
    // lighting multiplier.
    const float DH_LIGHTING_EXPOSURE = 0.86;
    vec3 outColor = albedo * (direct + indirect) * DH_LIGHTING_EXPOSURE;

    #ifdef SPECIAL_BLOCKLIGHT
    if (material > 0.83) {
        float emission = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).a;
        vec3  sunVec = normalize(sunPosition);
        vec3  upVec  = normalize(upPosition);
        float sunUp  = clamp(dot(sunVec, upVec), 0.0, 1.0);
        float skyExposure = smoothstep(0.75, 0.9, lightmap.y);
        float suppression = mix(1.0, 0.2, sunUp * skyExposure);
        outColor += albedo * emission * float(EMISSIVE_BRIGHTNESS) * suppression;
    }
    #endif

    // Integrated-PBR cohesion: give the LODs the same soft sun glint + faint sky
    // Fresnel the near dielectric terrain gets (grass/dirt read as a matte
    // dielectric — smoothness ~0.18, F0 0.04), so the sun's sheen runs continuously
    // from near to far instead of stopping at the LOD boundary.
    #ifdef INTEGRATED_PBR
    {
        const float dhSmoothness = 0.18;
        float roughness = 1.0 - dhSmoothness;
        vec3  V      = normalize(-viewPos);
        float sunVis = clamp(shadowLuma * skyOcc * cloudShadow, 0.0, 1.0);

        vec3 spec = vec3(0.0);
        #if SPECULAR_SUN == 1
            spec = sunMoonSpecular(normal, V, viewPos, roughness, vec3(0.04), sunVis)
                 * float(PBR_DIELECTRIC_SUN);
        #endif

        #ifdef SPECULAR_REFLECTIONS
            float NoV     = clamp(dot(normal, V), 1e-3, 1.0);
            float fres    = pbrFresnel(NoV, vec3(0.04)).r;
            float skyGate = pow(clamp(skyLight / 0.75, 0.0, 1.0), REFLECTION_SKY_FADE);
            vec3  reflW   = mat3(gbufferModelViewInverse) * reflect(normalize(viewPos), normal);
            vec3  skyRefl = getSkyReflection(reflW, cameraPosition.y - 64.0)
                          * REFLECTION_SKY_STRENGTH * PBR_DIELECTRIC_REFLECT * skyGate;
            spec += skyRefl * fres * (0.5 + 0.5 * sunVis); // dimmer in shadow
        #endif

        outColor += spec;
    }
    #endif

    return outColor;
}
#endif

void main() {
    vec2 unjitteredTexCoord = texCoord;
    #ifdef TAA
    unjitteredTexCoord -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif
    clipSpace = vec3(unjitteredTexCoord, depth0) * 2.0 - 1.0;

    vec3 color = texture(colortex0, texCoord * renderScale).rgb;
    // sRGB->linear: the block atlas arrives gamma-encoded on Mesa/radeonsi (no implicit
    // sRGB sampler decode, unlike the Windows GL stack Serie was tuned on). Lighting must
    // run in linear space so the single final pow(1/2.09) encode isn't a double-gamma -> the
    // washed-out/low-contrast look. The decode is done here where albedo meets lighting
    // (covers terrain, entities, hand, DH) rather than on input.
    color = pow(max(color, 0.0), vec3(2.2));

    #ifdef DISTANT_HORIZONS
    // Distant Horizons LOD opaque terrain (vanilla sky depth, DH depth + current
    // frame terrain marker present).
    // DH WATER is translucent — it writes the vanilla depth buffer (depth0 < 1) and
    // is shaded by the water composite (c_water) like near water, so it is NOT
    // handled here.
    float dhFlag = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).b;
    if (isDhTerrainPixel(depth0, texCoord * renderScale, dhFlag)) {
        gl_FragData[1] = vec4(0.0, 0.0, 0.0, 1.0); // pbrSunVis = 0 (no PBR on LODs)
        vec3 dhViewP = dhViewPos(unjitteredTexCoord, dhSampleDepth(texCoord * renderScale));
        gl_FragData[0] = vec4(shadeDhTerrain(dhViewP, color), 1.0);
        return;
    }
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

    // ---- Indirect ----------------------------------------------------------
    // THE integration seam for the Lumen stack: one read of the GI buffer that
    // dg0_gather produced. The contract it honours:
    //   1. albedo-demodulated  -- incident light only; the composite below
    //      multiplies by albedoRaw.
    //   2. irradiance / PI     -- the composite does albedo * indirect, not
    //      albedo/PI * indirect, so the Lambert 1/PI is folded into the buffer.
    //   3. no NdotL applied here; the cosine lives in the sampling distribution.
    //   4. GI_STRENGTH and firefly clamps pre-applied by the producer.
    //      LIGHTING_INDIRECT is NOT applied to it -- see below.
    //   5. AO is NOT pre-applied.
    //   6. linear HDR, unbounded; sampled at the logical, un-jittered uv.
    //   7. diffuse only -- no emission (added separately below), no specular.
    vec3 indirect;
    #ifdef VOXEL_GI
        // Jitter-free buffer, so this samples at the surface's LOGICAL uv.
        //
        // Deliberately NOT scaled by LIGHTING_INDIRECT. That control exists to
        // trim RASTERISED ambient -- the analytic lightmap wash below, and the
        // hemisphere ambient shadeDhTerrain uses for Distant Horizons LOD, both
        // of which are flat fills with no occlusion term. Applying it here too
        // meant the only way to tame that flat fill was to attenuate the
        // path-traced GI by the same factor, which is backwards: the traced
        // result is the thing that should survive. Use GI_STRENGTH to scale GI.
        //
        // Which buffer this is depends on how many a-trous passes ran, because
        // they ping-pong 8 -> 9 -> 10 -> 9 -> 10 and the ladder therefore ends on
        // a different one for an odd or even pass count. Resolved at compile time
        // from the same option that gates the passes, so the two cannot disagree:
        //   0 off      -> colortex8   (raw temporal accumulation)
        //   1 low      -> colortex10  (2 passes)
        //   2 balanced -> colortex9   (3 passes)
        //   3 quality  -> colortex10  (4 passes)
        #if GI_DENOISE_QUALITY == 0
            indirect = texture(colortex8,  unjitteredTexCoord * renderScale).rgb;
        #elif GI_DENOISE_QUALITY == 2
            indirect = texture(colortex9,  unjitteredTexCoord * renderScale).rgb;
        #else
            indirect = texture(colortex10, unjitteredTexCoord * renderScale).rgb;
        #endif
    #else
        // Analytic lightmap ambient: the pre-path-tracer fallback, and genuinely
        // rasterised, so LIGHTING_INDIRECT applies to it here.
        indirect = (getLightmap(lightmap) + vec3(ambientStrength))
                 * (float(LIGHTING_INDIRECT) / 100.0);
    #endif

    #if GI_DEBUG_VIEW > 0
        if (depth0 < 1.0) {
            vec3 dbg;
            #if GI_DEBUG_VIEW == 1
                // The indirect buffer itself, no albedo. Black here means the
                // gather produced nothing.
                dbg = indirect;
            #elif GI_DEBUG_VIEW == 2
                // Temporal history length: blue = fresh, red = converged. Broad
                // blue areas mean history is being rejected every frame.
                float hl = clamp(texture(colortex8, unjitteredTexCoord * renderScale).a
                                 / float(GI_ACCUM_FRAMES), 0.0, 1.0);
                dbg = vec3(hl, 0.15, 1.0 - hl);
            #elif GI_DEBUG_VIEW == 3
                // The surface cache sampled straight down the primary ray. This
                // isolates the cache from the gather: if the world is lit but
                // this is black, sc1_surface_direct is at fault, not dg0.
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                dbg = dh.hit ? scLookup(dh.pos, dh.normal) : vec3(0.0);
            #elif GI_DEBUG_VIEW == 4
                // Same, but IGNORING the validity tag. Compare against view 3:
                // lit here and black there means the tag is rejecting entries
                // (an addressing bug); black in both means the slot was never
                // written (a coverage or lighting bug in the update pass).
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                dbg = dh.hit ? scLookupRaw(dh.pos, dh.normal) : vec3(0.0);
            #elif GI_DEBUG_VIEW == 5
                // Cache coverage: green where the slot's tag matches, red where
                // it does not, black where the primary ray hit nothing. Shows
                // directly which parts of the volume the update pass reaches.
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                dbg = !dh.hit ? vec3(0.0)
                    : scTagValid(dh.pos, dh.normal) ? vec3(0.0, 1.0, 0.0)
                                                    : vec3(1.0, 0.0, 0.0);
            #elif GI_DEBUG_VIEW == 6
                // The tag actually STORED in the slot, as a 0..63 grey ramp.
                // Pure black = the slot holds alpha 0, i.e. it was never written.
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                dbg = dh.hit ? vec3(scStoredTag(dh.pos, dh.normal) / 63.0) : vec3(0.0);
            #elif GI_DEBUG_VIEW == 7
                // The tag the reader EXPECTS, same ramp. Compare against view 6:
                // 6 black while 7 is grey means nothing was written there; both
                // grey but different means writer and reader disagree on
                // addressing; identical means the slot is valid.
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                dbg = dh.hit ? vec3(scExpectedTag(dh.pos, dh.normal) / 63.0) : vec3(0.0);
            #elif GI_DEBUG_VIEW == 8
                // Which bricks the feedback gate is keeping alive. GREEN = a
                // gather ray stamped this brick within SC_REQUEST_TTL, so
                // sc1_surface_direct is refreshing it. RED = stamped too long
                // ago; that brick is frozen, which is correct only if nothing
                // visible depends on it.
                //
                // This is the view that tells you whether the feedback volume is
                // saving anything: mostly green over the whole scene means the
                // requested set has saturated (check that bounce-ray stamping is
                // still confined to the near field), while red on surfaces you
                // are looking straight at means the gather is not stamping and
                // the cache will go stale on screen.
                vec3 rd = normalize(getWorldPosition().xyz);
                VoxelHit dh = traceVoxelCascaded(cameraPosition, rd, 256.0, false);
                #ifdef SC_FEEDBACK
                    dbg = !dh.hit ? vec3(0.0)
                        : scRequested(scVoxelForHit(dh.pos, dh.normal))
                            ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
                #else
                    dbg = vec3(0.0, 0.0, 1.0); // feedback compiled out
                #endif
            #endif
            /* RENDERTARGETS: 0,6 */
            gl_FragData[0] = vec4(dbg, 1.0);
            gl_FragData[1] = vec4(0.0, 0.0, 0.0, 1.0);
            return;
        }
    #endif

    // LIGHTING_INDIRECT is applied at the point `indirect` is BUILT, not here:
    // only the rasterised branch above takes it, so the path-traced buffer is
    // passed through untouched.
    direct *= float(LIGHTING_DIRECT) / 100.0;

    vec3 albedoRaw = color; // colortex0 is untouched albedo here

    #ifdef SPECIAL_BLOCKLIGHT
        // Separate blocklight path: shade the surface normally, then ADD an
        // unshaded self-emission term driven by the per-texel emissive strength
        // (colortex2.a, written in gbuffers_terrain). Only the glowing texels emit
        // -> a torch's stick shades like wood while its flame blazes, and lava
        // self-emits regardless of which way its face points (no NdotL darkening).
        color = albedoRaw * (direct + indirect);
        if (material > 0.83) {
            float emissionStrength = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).a;
            // damp emissive surfaces in open daylight, matching getLightmap's suppression
            vec3  sunVec = normalize(sunPosition);
            vec3  upVec  = normalize(upPosition);
            float sunUp  = clamp(dot(sunVec, upVec), 0.0, 1.0);
            float skyExposure = smoothstep(0.75, 0.9, lightmap.y);
            float blocklightSuppression = mix(1.0, 0.2, sunUp * skyExposure);
            color += albedoRaw * emissionStrength * float(EMISSIVE_BRIGHTNESS) * blocklightSuppression;
        }
    #else
        // Legacy whole-block glow hack (kept for A/B comparison).
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
    #endif

    #ifdef PT_DEBUG_VOXELS
    if (depth0 < 1.0) {
        // Debug view of the cascaded grid: trace the primary ray through it and
        // shade by what was hit. Tint encodes the category, brightness encodes
        // which cascade resolved the hit, so cascade seams are directly visible.
        vec3 rayDir = normalize(getWorldPosition().xyz);
        VoxelHit dbg = traceVoxelCascaded(cameraPosition, rayDir, 4096.0, false);
        if (dbg.hit) {
            vec3 tint = dbg.category == VOXEL_EMISSIVE || dbg.category == VOXEL_LIGHT
                      ? vec3(1.0, 1.0, 0.1)                              // yellow = emissive
                      : dbg.category == VOXEL_FOLIAGE ? vec3(0.1, 0.5, 1.0)  // blue = foliage
                      : dbg.shapeId != 0u             ? vec3(0.1, 1.0, 0.1)  // green = sub-block shape
                                                      : vec3(1.0, 0.1, 0.1); // red = full cube
            int k = clamp(cascadeFor(dbg.pos), 0, VOXEL_CASCADES - 1);
            float cascadeDim = 1.0 - 0.18 * float(k);
            color = mix(dbg.albedo, tint, 0.4) * cascadeDim
                  * (0.55 + 0.45 * abs(dot(dbg.normal, normalize(vec3(0.4, 0.8, 0.3)))));
        }
    }
    #endif

    // Sun visibility for the reflection passes: the SAME filtered PCSS +
    // screen-space contact + cloud shadow that gates the diffuse sun, times sky
    // access (skyOcc). A reflection pass multiplies the sun glint and dims the
    // reflections by this, so PBR is shadowed/darkened exactly like the rest of
    // the surface instead of revealing the raw shadow map or shining in caves.
    // Kept live with no consumer: the screen-space reflection passes (d7b/d7c)
    // are gone and Phase 3.4 rebuilds reflections on the Lumen tracing stack.
    float pbrSunVis = clamp(dot(directShadow, vec3(0.2126, 0.7152, 0.0722))
                          * cloudShadow * skyOcc * (1.0 - rainStrength * 0.75), 0.0, 1.0);
    gl_FragData[1] = vec4(pbrSunVis, 0.0, 0.0, 1.0);

    /* RENDERTARGETS: 0,6 */
    gl_FragData[0] = vec4(color, 1.0);
}

#endif
