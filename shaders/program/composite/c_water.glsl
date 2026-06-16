#ifdef VERTEX

#include "/lib/options.glsl"

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    // TAAU: render into the bottom-left renderScale region (no-op at 1.0).
    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"
#include "/lib/util/jitter.glsl"
#include "/lib/fragment/sky.glsl"
#include "/lib/fragment/clouds.glsl"
#include "/lib/fragment/pbrCommon.glsl"
#include "/lib/fragment/vlFog.glsl"
#ifdef WATER_CAUSTICS
#include "/lib/fragment/caustics.glsl"
#endif

in vec2 texCoord;

vec3 screenToView(vec2 uv, float depth) {
    vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
    vec4 v = gbufferProjectionInverse * vec4(ndc, 1.0);
    return v.xyz / v.w;
}

float waterDither(vec2 p, int frame) {
    p += 5.588238 * float(frame & 63);
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec3 viewToScreen(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return (clip.xyz / clip.w) * 0.5 + 0.5; // xy = screen UV, z = window depth, all [0,1]
}

bool waterReflectSSR(vec3 viewOrigin, vec3 viewDir, float dither, out vec2 hitUV) {
    if (viewDir.z > 0.0 && viewDir.z >= -viewOrigin.z) return false;

    vec3 screenPos = viewToScreen(viewOrigin);
    vec3 screenDir = normalize(viewToScreen(viewOrigin + viewDir) - screenPos);

    vec2 tEdge;
    tEdge.x = (screenDir.x > 0.0) ? (1.0 - screenPos.x) : screenPos.x;
    tEdge.y = (screenDir.y > 0.0) ? (1.0 - screenPos.y) : screenPos.y;
    tEdge /= max(abs(screenDir.xy), vec2(1e-6));
    float rayLen = min(tEdge.x, tEdge.y);

    vec3  rayStep = screenDir * (rayLen / float(WATER_REFLECTION_STEPS));
    // Scaled-region buffer size: the ray marches in LOGICAL screen uv [0,1] but
    // the depth/flag buffers only hold data in the bottom-left renderScale
    // region, so every ivec2(logicalUv * viewSize) below lands on the right
    // texel once viewSize carries the renderScale factor.
    vec2  viewSize = vec2(viewWidth, viewHeight) * renderScale;

    // Dynamic depth tolerance scaled to prevent background ghosting & near-plane skipping
    float depthTol = max(abs(rayStep.z) * 3.0, 0.02 / max(1.0, viewOrigin.z * viewOrigin.z));

    // Cheap early check for near-contact reflections (bypasses loop entirely)
    ivec2 startTexel = ivec2(screenPos.xy * viewSize);
    if (clamp(startTexel, ivec2(0), ivec2(viewSize) - 1) == startTexel) {
        float initialDepth = texelFetch(depthtex1, startTexel, 0).r;
        if (initialDepth < screenPos.z && (screenPos.z - initialDepth) < depthTol) {
            if (texelFetch(colortex2, startTexel, 0).b <= 0.125 && initialDepth < 1.0) {
                hitUV = screenPos.xy;
                return true;
            }
        }
    }

    vec3 rayPos = screenPos + rayStep * (1.0 + dither);

    for (int i = 0; i < WATER_REFLECTION_STEPS; i++, rayPos += rayStep) {
        // Tight viewport boundary out-of-bounds break
        if (clamp(rayPos.xy, 0.0, 1.0) != rayPos.xy) break;

        ivec2 texelCoords = ivec2(rayPos.xy * viewSize);
        float sceneDepth = texelFetch(depthtex1, texelCoords, 0).r;

        if (sceneDepth < rayPos.z && (rayPos.z - sceneDepth) < depthTol) {
            // Skim over translucent objects (colortex2.b > 0.125)
            if (texelFetch(colortex2, texelCoords, 0).b > 0.125) continue;
            if (sceneDepth >= 1.0) break; // Hits sky, exit early

            // Binary search refinement
            vec3 p = rayPos, st = rayStep;
            for (int j = 0; j < 4; j++) {
                st *= 0.5;
                ivec2 pTexel = ivec2(p.xy * viewSize);
                float d = texelFetch(depthtex1, pTexel, 0).r;
                p += (d < p.z) ? -st : st;
            }
            hitUV = p.xy;
            return true;
        }
    }
    return false;
}

void main() {
    vec2 uv = texCoord;

    float d0 = texture(depthtex0, uv * renderScale).r; // water surface (translucent depth)
    float d1 = texture(depthtex1, uv * renderScale).r; // opaque behind (may equal d0 in this pack)
    vec4  c1 = texture(colortex1, uv * renderScale);
    vec3  scene = texture(colortex0, uv * renderScale).rgb;

    vec4  c2 = texture(colortex2, uv * renderScale);      // .rg = lightmap, .b = flag, .a = packed glass colour

    float flag       = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).b;
    // Distant Horizons LOD pixels are vanilla-sky depth (d0 == 1.0). DH water also
    // sets colortex2.b = 1.0, but it's already forward-shaded into colortex0 and
    // handled by d7 — exclude it here so this near-field screen-space water path
    // doesn't reprocess it with garbage (vanilla) depth.
    bool  isNear     = d0 < 1.0;
    bool  isWater    = isNear && flag > 0.875;
    bool  isGlass    = isNear && flag > 0.625 && flag <= 0.875;
    bool  isClearIce = isNear && flag > 0.375 && flag <= 0.625;
    bool  isSolidIce = isNear && flag > 0.125 && flag <= 0.375;
    bool  isTranslucent = isGlass || isClearIce || isSolidIce;
    float skylight = clamp(c2.g, 0.0, 1.0); 
    float skyVis = max(skylight - WATER_SKYLIGHT_THRESHOLD, 0.0) / max(1.0 - WATER_SKYLIGHT_THRESHOLD, 0.001);
    skyVis *= skyVis;

    /* DRAWBUFFERS:0 */

    #if WATER_DEBUG == 1

    gl_FragData[0] = vec4(c2.b, 0.0, 0.0, 1.0);
    return;
    #endif

    #if WATER_DEBUG == 2

    if (isWater) {
        float tdbg = distance(screenToView(uv, d0), screenToView(uv, d1));
        gl_FragData[0] = vec4(vec3(clamp(tdbg / 8.0, 0.0, 1.0)), 1.0);
    } else {
        gl_FragData[0] = vec4(scene, 1.0);
    }
    return;
    #endif

    #ifdef WATER_FOG

    if (isEyeInWater == 1) {
        vec3  wSun  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
        vec3  wMoon = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
        float eyeAlt = cameraPosition.y - 64.0;
        float dayFactor = clamp(wSun.y * 1.5 + 0.2, 0.04, 1.0); // dim at night / dusk
        vec3 absorption = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);

        // Ambient in-scatter ("fog") colour. The OLD code keyed this off the
        // OPAQUE fragment's skylight (skyVis from c2.g), so the haze tint changed
        // blotchily with whatever terrain happened to sit behind each pixel —
        // that's the "weird/patchy" fog. Underwater haze should be ~uniform
        // across the view, set by how much sky reaches the WATER COLUMN THE EYE
        // IS IN. Key it off the camera's own smoothed sky exposure (stable,
        // screen-wide), and mix only a little per-pixel skyVis back so genuinely
        // enclosed nooks still darken.
        vec3  scatterCoeff = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B);
        float eyeSky = clamp(float(eyeBrightnessSmooth.y) / 240.0, 0.0, 1.0);
        eyeSky = max(eyeSky - WATER_SKYLIGHT_THRESHOLD, 0.0) / max(1.0 - WATER_SKYLIGHT_THRESHOLD, 0.001);
        float ambientVis = mix(eyeSky, skyVis, 0.3);
        vec3  scatter = scatterCoeff * ambientVis * dayFactor;

        vec2 unjitU = uv;
        #ifdef TAA
        unjitU -= getTaaJitter() / vec2(viewWidth, viewHeight);
        #endif

        if (isWater) {

            vec3 viewWater = screenToView(unjitU, d0);
            vec3 N  = normalize(c1.rgb * 2.0 - 1.0); // surface normal, points up toward air
            vec3 Nb = -N;                            // toward the submerged camera
            vec3 I  = normalize(viewWater);          // camera -> surface (points up)

            bool tir = refract(I, Nb, 1.333) == vec3(0.0); // water(1.333) -> air; 0 vector == TIR

            float surfDist = length(viewWater);

            float windowDist = min(surfDist, 3.0); // cap at 3 blocks so window stays clear
            vec3 windowTrans = exp(-absorption * windowDist * 0.5);
            vec3 windowColor = scene * windowTrans + scatter * (1.0 - windowTrans);

            float reflDist = surfDist * 2.0;
            vec3 reflTrans = exp(-absorption * reflDist);

            vec3 reflColor = scatter; // fallback when SSR misses
            #ifdef WATER_REFLECTIONS
            {
                float nz = waterDither(gl_FragCoord.xy, frameCounter);
                vec2 hUV;
                if (waterReflectSSR(viewWater + Nb * 0.1, reflect(I, Nb), nz, hUV)) {
                    vec3 rawRefl = textureLod(colortex0, hUV * renderScale, 0.0).rgb;
                    reflColor = rawRefl * reflTrans + scatter * (1.0 - reflTrans);
                }
            }
            #endif

            float cosT = abs(dot(I, N));
            float F = tir ? 1.0 : (0.02 + 0.98 * pow(1.0 - cosT, 5.0));
            gl_FragData[0] = vec4(mix(windowColor, reflColor, F), 1.0);
            return;
        }


        float dist = (d0 >= 1.0) ? 64.0 : length(screenToView(unjitU, d0));

        vec3 sceneCaustic = scene;
        #ifdef WATER_CAUSTICS
        if (d0 < 1.0) {
            vec3 opaqueView   = screenToView(unjitU, d0);
            vec3 opaqueWorldR = (gbufferModelViewInverse * vec4(opaqueView, 1.0)).xyz; // camera-relative
            vec3 opaqueWorld  = opaqueWorldR + cameraPosition;
            float surfaceY    = cameraPosition.y + 1.0;
            float depthBelow  = max(surfaceY - opaqueWorld.y, 0.0);
            if (depthBelow < WATER_CAUSTICS_DEPTH_MAX && !isInShadow(opaqueWorldR)) {
                vec3 sampleWorld = opaqueWorld * vec3(WATER_CAUSTICS_SCALE, 1.0, WATER_CAUSTICS_SCALE);
                float k = computeWaterCaustics(sampleWorld, depthBelow, wSun,
                                               frameTimeCounter * WATER_WAVE_SPEED);
                float mod = 1.0 + k * WATER_CAUSTICS_STRENGTH * skyVis * dayFactor;
                sceneCaustic = scene * max(mod, 0.05);
            }
        }
        #endif

        vec3 trans = exp(-absorption * dist);
        vec3 foggedScene = sceneCaustic * trans + scatter * (1.0 - trans);

        #ifdef WATER_GODRAYS
        // Directional sun-shaft raymarch through the underwater volume.
        //
        // The Beer-Lambert term above is uniform AMBIENT haze. This layer adds
        // the DIRECTIONAL sun contribution: light that pierces the surface and
        // scatters toward the eye, forming visible shafts. Two things shape the
        // shafts so they read as real light columns *and* line up with the
        // caustics painted on the floor:
        //   1. shadow map -> the column is cut wherever terrain ABOVE the water
        //                    blocks the sun (true crepuscular shafts). The old
        //                    version had no occlusion at all, so it was just a
        //                    uniform glow modulated by noise — the main reason
        //                    the shafts "didn't work".
        //   2. caustics   -> the SAME wave-focusing pattern (same eval, same
        //                    surfaceY reference) that paints the seabed also
        //                    modulates the in-scatter, so a bright shaft lands on
        //                    a bright floor band. This is the "match caustics".
        if (wSun.y > 0.02) {
            const float pi_local = 3.14159265359;
            vec3  viewDirW   = normalize(mat3(gbufferModelViewInverse) * screenToView(unjitU, d0));
            float gStepLen   = dist / float(WATER_GODRAY_STEPS);
            float gDither    = waterDither(gl_FragCoord.xy, frameCounter);
            float surfaceY   = cameraPosition.y + 1.0;

            // Henyey-Greenstein phase: forward-peaked for water particle scattering.
            float gHG     = WATER_GODRAY_PHASE_G;
            float gHG2    = gHG * gHG;
            float cosT    = dot(viewDirW, wSun);
            float phase   = (1.0 - gHG2) / (4.0 * pi_local
                          * pow(max(1.0 + gHG2 - 2.0 * gHG * cosT, 1e-4), 1.5));

            // Sun reaching the water surface (T-LUT at sea level).
            vec3 sunAtSurface = SUN_COLOR_BASE
                              * sampleTransmittanceLUT_fast(wSun.y, PLANET_RADIUS)
                              * dayFactor;

            float resScale = 4096.0 / float(SHADOW_RESOLUTION);

            vec3 godray = vec3(0.0);
            for (int gi = 0; gi < WATER_GODRAY_STEPS; ++gi) {
                float t          = gStepLen * (float(gi) + gDither);
                vec3  samplePosR = viewDirW * t;              // camera-relative world
                vec3  samplePos  = cameraPosition + samplePosR;
                float depthBelow = max(surfaceY - samplePos.y, 0.0);

                // Shadow test: is this volume sample in direct sun, or behind
                // terrain above the water? Inlined shadow-space transform, same
                // as lib/util/common.glsl::isInShadow.
                //
                // MUST sample shadowtex1 (OPAQUE-only), NOT shadowtex0. The water
                // SURFACE is a translucent caster, so it lives in shadowtex0 — and
                // every underwater volume sample is below it, so against shadowtex0
                // every sample reads as self-occluded by the surface => shadow==0
                // everywhere => no shafts at all (this is why they didn't show up).
                // shadowtex1 excludes the water surface, leaving only real terrain
                // to cut the shafts.
                vec4 sp = shadowProjection * shadowModelView * vec4(samplePosR, 1.0);
                sp /= sp.w;
                float distb   = length(sp.xy);
                float distort = (1.0 - SHADOW_MAP_BIAS) + distb * SHADOW_MAP_BIAS;
                sp.xy /= distort;
                sp = sp * 0.5 + 0.5;
                float shadow = 1.0;
                if (sp.x >= 0.0 && sp.x <= 1.0 && sp.y >= 0.0 && sp.y <= 1.0) {
                    shadow = step(sp.z - 0.0004 * resScale, texture(shadowtex1, sp.xy).r);
                }

                // Caustic banding focused by the surface waves above. Same eval +
                // same surfaceY reference as the seabed caustics, so the shaft
                // banding registers with the floor caustics.
                float caustic = 1.0;
                #ifdef WATER_CAUSTICS
                vec3 sampleScaled = samplePos
                                  * vec3(WATER_CAUSTICS_SCALE, 1.0, WATER_CAUSTICS_SCALE);
                caustic = 1.0 + computeWaterCaustics(sampleScaled, depthBelow, wSun,
                                                     frameTimeCounter * WATER_WAVE_SPEED)
                              * WATER_CAUSTICS_STRENGTH;
                #endif

                // Multiply by the RAW scatter coefficient (not the skyVis-modulated
                // ambient `scatter`): dayFactor is already in sunAtSurface and the
                // shaft must not be re-killed by the terrain's per-pixel lightmap.
                vec3 lightAtSample = sunAtSurface * shadow * max(caustic, 0.0)
                                   * exp(-absorption * depthBelow);
                vec3 transCam      = exp(-absorption * t);

                godray += lightAtSample * phase * scatterCoeff * gStepLen * transCam;
            }

            foggedScene += godray * WATER_GODRAY_STRENGTH;
        }
        #endif

        float we0 = textureLod(colortex2, uv * renderScale + vec2(-1.5, 0.0) * texelSize, 0.0).b;
        float we1 = textureLod(colortex2, uv * renderScale + vec2( 1.5, 0.0) * texelSize, 0.0).b;
        float we2 = textureLod(colortex2, uv * renderScale + vec2(0.0, -1.5) * texelSize, 0.0).b;
        float we3 = textureLod(colortex2, uv * renderScale + vec2(0.0,  1.5) * texelSize, 0.0).b;
        float waterNeighbor = (we0 + we1 + we2 + we3) * 0.25;

        foggedScene = mix(foggedScene, foggedScene * exp(-absorption * 1.0) + scatter * (1.0 - exp(-absorption * 1.0)), smoothstep(0.0, 0.5, waterNeighbor));

        gl_FragData[0] = vec4(foggedScene, 1.0);
        return;
    }
    #endif

    if (isTranslucent) {
        const float GLASS_OPACITY     = 0.05; // see-through
        const float CLEAR_ICE_OPACITY = 0.15; // frosted
        const float SOLID_ICE_OPACITY = 0.80; // mostly solid
        const float TRANSLUCENT_REFRACTION_DEPTH = 0.6;

        float ior; float opacity; bool doRefract;
        if (isSolidIce)      { ior = 1.31; opacity = SOLID_ICE_OPACITY; doRefract = false; }
        else if (isClearIce) { ior = 1.31; opacity = CLEAR_ICE_OPACITY; doRefract = true;  }
        else                 { ior = 1.50; opacity = GLASS_OPACITY;     doRefract = true;  }

        vec3 wSunT  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
        vec3 wMoonT = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
        float dayFactor = clamp(wSunT.y * 1.5 + 0.2, 0.04, 1.0);
        const vec3 torchColor = vec3(0.9922, 0.6471, 0.1922);

        vec2 unjitT = uv;
        #ifdef TAA
        unjitT -= getTaaJitter() / vec2(viewWidth, viewHeight);
        #endif
        vec3 viewSurf = screenToView(unjitT, d0);
        vec3 tN = normalize(c1.rgb * 2.0 - 1.0);
        vec3 tV = normalize(-viewSurf);

        tN = normalize(tN + tV * clamp(-dot(tN, tV) + 1e-5, 0.0, 1.0));
        
        vec3 albedoT = unpackColor565(texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).a);

        vec3 bg = scene;
        #ifdef WATER_REFRACTION
        if (doRefract) {
            vec3 rDir = refract(normalize(viewSurf), tN, 1.0 / ior);
            if (dot(rDir, rDir) > 1e-6) {
                vec2 rUV = viewToScreen(viewSurf + rDir * TRANSLUCENT_REFRACTION_DEPTH).xy;
                if (clamp(rUV, 0.0, 1.0) == rUV &&
                    texelFetch(colortex2, ivec2(rUV * vec2(viewWidth, viewHeight) * renderScale), 0).b > 0.125) {
                    bg = textureLod(colortex0, rUV * renderScale, 0.0).rgb;
                }
            }
        }
        #endif

        vec3 base;
        if (isSolidIce) {
            base = bg; // colortex0 already holds the lit opaque ice
        } else {
            vec3 seeThrough = bg * albedoT;
            // Scale skylight and ambient floor by dayFactor so glass doesn't glow at night.
            // Torchlight uses the warm blocklight color and is not suppressed at night.
            vec3 ownColor   = albedoT * ((0.05 + 0.95 * skylight) * dayFactor + 1.2 * c2.r * torchColor);
            base = mix(seeThrough, ownColor, opacity);
        }

        vec3 tGeoCross = cross(dFdx(viewSurf), dFdy(viewSurf));
        vec3 tGeoN = (dot(tGeoCross, tGeoCross) > 1e-12) ? normalize(tGeoCross) : tN;
        if (dot(tGeoN, tN) < 0.0) tGeoN = -tGeoN;

        vec3 viewReflDir = reflect(normalize(viewSurf), tN);

        viewReflDir = normalize(viewReflDir + tGeoN * clamp(-dot(viewReflDir, tGeoN) + 1e-5, 0.0, 1.0));
        vec3 worldRefl   = mat3(gbufferModelViewInverse) * viewReflDir;
        float eyeAltT = cameraPosition.y - 64.0;
        vec3 reflectColor = getSkyReflection(worldRefl, eyeAltT) * skyVis;
        #ifdef WATER_REFLECTIONS
        {
            float nz = waterDither(gl_FragCoord.xy, frameCounter);
            vec2 hUV;
            if (waterReflectSSR(viewSurf + tN * 0.1, viewReflDir, nz, hUV)) {
                reflectColor = textureLod(colortex0, hUV * renderScale, 0.0).rgb;
            }
        }
        #endif
        
        float cosV = clamp(max(dot(tV, tN), dot(tV, tGeoN)), 0.0, 1.0);
        float F0t  = (isClearIce || isSolidIce) ? 0.12 : 0.04; // ice glossier so reflections read; glass dielectric
        float fres = F0t + (1.0 - F0t) * pow(1.0 - cosV, 5.0);

        vec3 tResult = mix(base, reflectColor, fres);

        // Sun/moon glint on glass/ice (shared GGX, matching water + PBR blocks).
        #if SPECULAR_SUN == 1
        {
            vec3  sunV = normalize(sunPosition);
            vec3  wS   = mat3(gbufferModelViewInverse) * sunV;
            bool  dayT = wS.y > -0.04;
            vec3  Lt   = dayT ? sunV : -sunV;
            float upT  = dayT ? wS.y : -wS.y;
            vec3  lcT  = (dayT ? mix(vec3(1.0, 0.55, 0.28), vec3(1.0, 0.96, 0.90), clamp(upT, 0.0, 1.0))
                               : vec3(0.55, 0.66, 0.95) * 0.05)
                       * smoothstep(-0.04, 0.08, upT) * SPECULAR_SUN_STRENGTH;
            float roughT = isSolidIce ? 0.28 : 0.05;
            tResult += ggxSpecular(tN, tV, Lt, roughT, vec3(F0t), lcT) * skyVis * (1.0 - rainStrength * 0.75);
        }
        #endif

        // Atmospheric fog for the translucent surface. The deferred fog/VL pass
        // (d8/d9) ran BEFORE translucents were drawn, so it only fogged the
        // opaque scene behind this surface — the glass/ice/portal surface itself
        // (own light + reflections) never received the camera->surface haze.
        // Without this, transparents keep full brightness and pop out of the fog
        // (and at night their reflections read as a glow against the dark, fogged
        // surroundings). Match whichever fog the opaque scene got this frame:
        // d9's shadow-aware volumetric integration when VOLUMETRIC_LIGHT is on,
        // else d8's flat aerial perspective. Same function/intensity, so the
        // transparent surface fogs to the same density as everything around it.
        {
            vec3  fogWorldDir = normalize(mat3(gbufferModelViewInverse) * viewSurf);
            float fogDist     = length(viewSurf);
            #ifdef VOLUMETRIC_LIGHT
                float fogDither = waterDither(gl_FragCoord.xy, frameCounter);
                VolFog vf = computeVolumetricFog(fogWorldDir, fogDist, eyeAltT, fogDither);
                tResult = tResult * vf.transmittance + vf.scatter;
            #else
                AerialPerspective ap = computeAerialPerspective(fogWorldDir, wSunT, wMoonT, eyeAltT, fogDist);
                tResult = tResult * ap.transmittance + ap.scatter;
            #endif
        }

        gl_FragData[0] = vec4(tResult, 1.0);
        return;
    }

    if (!isWater) {
        gl_FragData[0] = vec4(scene, 1.0);
        return;
    }

    vec2 unjit = uv;
    #ifdef TAA
    unjit -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif

    const float WATER_THICKNESS_MAX = 16.0; // cap optical depth (blocks)

    vec3  viewWater  = screenToView(unjit, d0);
    vec3  viewOpaque = screenToView(unjit, d1);

    float thickness = min(distance(viewWater, viewOpaque), WATER_THICKNESS_MAX);

    vec3 viewNormal = normalize(c1.rgb * 2.0 - 1.0);
    vec3 V = normalize(-viewWater); // surface -> camera, view space
    
    viewNormal = normalize(viewNormal + V * clamp(-dot(viewNormal, V) + 1e-5, 0.0, 1.0));

    vec3 geoCross = cross(dFdx(viewWater), dFdy(viewWater));
    vec3 geoViewN = (dot(geoCross, geoCross) > 1e-12) ? normalize(geoCross) : viewNormal;
    if (dot(geoViewN, viewNormal) < 0.0) geoViewN = -geoViewN;

    vec3 geoWorldN = mat3(gbufferModelViewInverse) * geoViewN;
    vec3 absN = abs(geoWorldN);
    vec3 flatWorldN;
    if (absN.x > absN.y && absN.x > absN.z) {
        flatWorldN = vec3(sign(geoWorldN.x), 0.0, 0.0);
    } else if (absN.z > absN.y) {
        flatWorldN = vec3(0.0, 0.0, sign(geoWorldN.z));
    } else {
        flatWorldN = vec3(0.0, sign(geoWorldN.y), 0.0);
    }
    geoViewN = mat3(gbufferModelView) * flatWorldN;

    vec2 distortN = (viewNormal - geoViewN).xy;

    vec3  worldSunDir  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
    vec3  worldMoonDir = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
    float eyeAltitude  = cameraPosition.y - 64.0;
    float dayFactor    = clamp(worldSunDir.y * 1.5 + 0.2, 0.04, 1.0);

    vec3 refractColor = scene;
    #ifdef WATER_REFRACTION

    float dist = length(viewWater);
    float distFade = 3.0 / max(dist, 3.0);

    float w0 = textureLod(colortex2, uv * renderScale + vec2(-1.5, 0.0) * texelSize, 0.0).b;
    float w1 = textureLod(colortex2, uv * renderScale + vec2(1.5, 0.0) * texelSize, 0.0).b;
    float w2 = textureLod(colortex2, uv * renderScale + vec2(0.0, -1.5) * texelSize, 0.0).b;
    float w3 = textureLod(colortex2, uv * renderScale + vec2(0.0, 1.5) * texelSize, 0.0).b;
    float edgeFade = clamp((w0 + w1 + w2 + w3) * 0.25, 0.0, 1.0);
    edgeFade = smoothstep(0.0, 1.0, edgeFade);

    float depthFade = clamp(thickness * 0.5, 0.0, 1.0);
    vec2  refrUV = clamp(uv + distortN * (WATER_REFRACTION_STRENGTH * depthFade * distFade * edgeFade), vec2(0.0), vec2(1.0));

    bool refractedHit = false;
    float seabedDepth = 0.0;
    vec3  seabedWorld = vec3(0.0);
    if (texture(colortex2, refrUV * renderScale).b > 0.875) {
        refractColor = textureLod(colortex0, refrUV * renderScale, 0.0).rgb;
        float dR = texture(depthtex1, refrUV * renderScale).r;
        thickness = min(distance(screenToView(refrUV, d0), screenToView(refrUV, dR)), WATER_THICKNESS_MAX);
        if (dR < 1.0) {
            vec3 seabedView   = screenToView(refrUV, dR);
            vec3 surfaceView  = screenToView(unjit, d0);
            vec3 seabedWorldR = (gbufferModelViewInverse * vec4(seabedView, 1.0)).xyz; // camera-relative
            seabedWorld       = seabedWorldR + cameraPosition;
            vec3 surfaceWorld = (gbufferModelViewInverse * vec4(surfaceView, 1.0)).xyz + cameraPosition;
            seabedDepth = max(surfaceWorld.y - seabedWorld.y, 0.0);
            refractedHit = !isInShadow(seabedWorldR);
        }
    }
    #endif

    #if defined(WATER_CAUSTICS) && defined(WATER_REFRACTION)
    if (refractedHit && seabedDepth > 0.05 && seabedDepth < WATER_CAUSTICS_DEPTH_MAX) {
        vec3 sampleWorld = seabedWorld * vec3(WATER_CAUSTICS_SCALE, 1.0, WATER_CAUSTICS_SCALE);
        float k = computeWaterCaustics(sampleWorld, seabedDepth, worldSunDir,
                                       frameTimeCounter * WATER_WAVE_SPEED);
        float mod = 1.0 + k * WATER_CAUSTICS_STRENGTH * skyVis * dayFactor;
        refractColor = refractColor * max(mod, 0.05);
    }
    #endif

    vec3 absorption = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);

    vec3 scatter = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B) * skyVis * dayFactor;
    vec3 trans = exp(-absorption * thickness);
    refractColor = refractColor * trans + scatter * (1.0 - trans);

    vec3 viewReflDir = reflect(normalize(viewWater), viewNormal); // incident = camera->surface
        viewReflDir = normalize(viewReflDir + geoViewN * clamp(-dot(viewReflDir, geoViewN) + 1e-5, 0.0, 1.0));

    vec3 worldRefl   = mat3(gbufferModelViewInverse) * viewReflDir;

    vec3 reflectColor = getSkyReflection(worldRefl, eyeAltitude);
    #ifdef WATER_CLOUD_REFLECTIONS
    reflectColor = cloudReflection(reflectColor, cameraPosition, worldRefl);
    #endif
    reflectColor *= skyVis;
    #ifdef WATER_REFLECTIONS
    {
        float nz = waterDither(gl_FragCoord.xy, frameCounter);
        vec2 hitUV;
        if (waterReflectSSR(viewWater + viewNormal * 0.1, viewReflDir, nz, hitUV)) {
            reflectColor = textureLod(colortex0, hitUV * renderScale, 0.0).rgb;
        }
    }
    #endif

    vec3  sunDir  = normalize(sunPosition);
    vec3  moonDir = normalize(-sunPosition);

    vec3 L = (worldTime < 12700 || worldTime > 23250) ? sunDir : moonDir;

    float sunUp     = max(dot(worldSunDir, vec3(0.0, 1.0, 0.0)), 0.0);
    vec3  sunCol    = mix(vec3(1.0, 0.65, 0.35) * 0.15, vec3(1.0, 1.0, 1.1), sunUp);
    float moonUp    = max(dot(worldMoonDir, vec3(0.0, 1.0, 0.0)), 0.0);
    vec3  moonCol   = vec3(0.65, 0.85, 1.0) * 0.02;
    float moonVis   = pow(clamp(dot(worldMoonDir, vec3(0.0, 1.0, 0.0)) + 0.1, 0.0, 0.1) / 0.1, 2.0);
    vec3  lightCol  = mix(sunCol, moonCol, moonVis);

    // Sun/moon glint via the shared GGX (same Cook-Torrance as the integrated-PBR
    // blocks — water/glass/PBR now share one specular model).
    const float F0 = 0.02;
    vec3 specular = ggxSpecular(viewNormal, V, L, WATER_ROUGHNESS, vec3(F0), lightCol)
                  * (1.0 - rainStrength * 0.75) * skyVis;

    float cosT = clamp(max(dot(V, viewNormal), dot(V, geoViewN)), 0.0, 1.0);
    float Fmax = max(1.0 - WATER_ROUGHNESS, F0);
    float fresnel = F0 + (Fmax - F0) * pow(1.0 - cosT, 5.0);

    vec3 result = mix(refractColor, reflectColor, fresnel) + specular;

    // Atmospheric fog for the water surface (above-water view). Same reason as
    // the translucent path above: d8/d9 fogged only the opaque scene before the
    // water surface existed, so the surface's reflection/specular/scatter would
    // otherwise sit unfogged and pop out of the haze. Match the opaque scene's
    // fog: d9 volumetric when VOLUMETRIC_LIGHT is on, else d8 aerial perspective.
    // (Eye-in-water has its own absorption fog and returns earlier.)
    {
        vec3  fogWorldDir = normalize(mat3(gbufferModelViewInverse) * viewWater);
        float fogDist     = length(viewWater);
        #ifdef VOLUMETRIC_LIGHT
            float fogDither = waterDither(gl_FragCoord.xy, frameCounter);
            VolFog vf = computeVolumetricFog(fogWorldDir, fogDist, eyeAltitude, fogDither);
            result = result * vf.transmittance + vf.scatter;
        #else
            AerialPerspective ap = computeAerialPerspective(fogWorldDir, worldSunDir, worldMoonDir, eyeAltitude, fogDist);
            result = result * ap.transmittance + ap.scatter;
        #endif
    }

    gl_FragData[0] = vec4(result, 1.0);
}

#endif
