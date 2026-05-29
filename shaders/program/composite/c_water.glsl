// c_water : deferred water surface shading (runs before TAA / bloom).
// Reads the intact lit scene (colortex0, written by the deferred chain), the
// water G-buffer (colortex1: view-space wave normal + sentinel a=1.0 written by
// gbuffers_water) and the depth pair (depthtex0 = water surface, depthtex1 =
// opaque behind). For water pixels it composites:
//   refraction (screen-space UV offset, depth-guarded)
//     * per-channel Beer-Lambert absorption + in-scatter tint (thickness)
//   reflection (screen-space ray trace vs opaque depth, sky fallback)
//   mixed by a Schlick dielectric Fresnel term.
// Writes colortex0 only -> bloom (colortex3) ping-pong parity is untouched.
//
// Buffer budget: ZERO new allocations. The wave normal + flag are packed into
// the existing colortex1 (free after the deferred chain consumes the opaque
// material codes); thickness comes from the existing depth pair.

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
#include "/lib/fragment/sky.glsl"

in vec2 texCoord;

vec3 screenToView(vec2 uv, float depth) {
    vec3 ndc = vec3(uv, depth) * 2.0 - 1.0;
    vec4 v = gbufferProjectionInverse * vec4(ndc, 1.0);
    return v.xyz / v.w;
}

// Interleaved-gradient noise, animated per frame (hides SSR stepping).
float waterDither(vec2 p, int frame) {
    p += 5.588238 * float(frame & 63);
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec3 viewToScreen(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return (clip.xyz / clip.w) * 0.5 + 0.5; // xy = screen UV, z = window depth, all [0,1]
}

// Screen-space reflection: march in SCREEN space sized so the ray
// reaches the screen edge in a fixed step count, so reflections extend to the horizon rather
// than a fixed world distance. Binary-refines the hit and skips the water surface itself
// (depthtex1 includes translucents here, so the flat water plane would otherwise self-reflect).
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
    vec3  rayPos  = screenPos + rayStep * (1.0 + dither);
    float depthTol = max(abs(rayStep.z) * 3.0, 0.0008);

    for (int i = 0; i < WATER_REFLECTION_STEPS; i++, rayPos += rayStep) {
        if (clamp(rayPos.xy, 0.0, 1.0) != rayPos.xy) return false;

        float sceneDepth = texture(depthtex1, rayPos.xy).r;
        if (sceneDepth < rayPos.z && (rayPos.z - sceneDepth) < depthTol) {
            if (texture(colortex2, rayPos.xy).b > 0.125) continue; // skim over any translucent, keep going
            if (sceneDepth >= 1.0) return false;                  // sky


            vec3 p = rayPos, st = rayStep;
            for (int j = 0; j < 4; j++) {
                st *= 0.5;
                float d = texture(depthtex1, p.xy).r;
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

    float d0 = texture(depthtex0, uv).r; // water surface (translucent depth)
    float d1 = texture(depthtex1, uv).r; // opaque behind (may equal d0 in this pack)
    vec4  c1 = texture(colortex1, uv);
    vec3  scene = texture(colortex0, uv).rgb;

    vec4  c2 = texture(colortex2, uv);      // .rg = lightmap, .b = flag, .a = packed glass colour
    // 4-state flag, POINT-sampled (texelFetch) so bilinear can't blend states at edges:
    //   0 opaque / 0.25 solid ice (packed,blue) / 0.5 clear ice / 0.75 glass / 1.0 water.
    float flag       = texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).b;
    bool  isWater    = flag > 0.875;
    bool  isGlass    = flag > 0.625 && flag <= 0.875;
    bool  isClearIce = flag > 0.375 && flag <= 0.625;
    bool  isSolidIce = flag > 0.125 && flag <= 0.375;
    bool  isTranslucent = isGlass || isClearIce || isSolidIce;
    float skylight = clamp(c2.g, 0.0, 1.0); // ~0 in caves, partial under cover, ~1 under open sky
    // Allium-style hard remap: only near-full sky access reflects sky / in-scatters. Skylight below
    // the threshold (caves, rooms, covered/partial water — which still carry a non-zero lightmap)
    // reads as NO sky access, so it doesn't reflect the sky or glow underground.
    float skyVis = max(skylight - WATER_SKYLIGHT_THRESHOLD, 0.0) / max(1.0 - WATER_SKYLIGHT_THRESHOLD, 0.001);
    skyVis *= skyVis;

    /* DRAWBUFFERS:0 */

    #if WATER_DEBUG == 1

    gl_FragData[0] = vec4(c2.b, 0.0, 0.0, 1.0);
    return;
    #endif

    #if WATER_DEBUG == 2
    // Visualize water thickness = depthtex1(opaque behind) - depthtex0(water surface), view-space
    // blocks, greyscale (black = 0, white = >=8). This is what Allium scales
    // refraction by. If water reads near-BLACK everywhere -> depthtex1 is collapsed (no translucent
    // separation) and we genuinely can't depth-scale. If it ramps dark-at-shore -> bright-in-deep
    // water -> depthtex1 works and the refraction/absorption should use it (kills the edge outline).
    if (isWater) {
        float tdbg = distance(screenToView(uv, d0), screenToView(uv, d1));
        gl_FragData[0] = vec4(vec3(clamp(tdbg / 8.0, 0.0, 1.0)), 1.0);
    } else {
        gl_FragData[0] = vec4(scene, 1.0);
    }
    return;
    #endif

    #ifdef WATER_FOG
    // Underwater: everything is seen through water -> tint by absorption/scatter; the water
    // SURFACE seen from below additionally does total internal reflection + a Snell-window of sky.
    if (isEyeInWater == 1) {
        vec3  wSun  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
        vec3  wMoon = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
        float eyeAlt = cameraPosition.y - 64.0;
        float dayFactor = clamp(wSun.y * 1.5 + 0.2, 0.04, 1.0); // dim at night / dusk
        vec3 absorption = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);
        vec3 scatter = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B) * skyVis * dayFactor;

        vec2 unjitU = uv;
        #ifdef TAA
        unjitU -= getTaaJitter() / vec2(viewWidth, viewHeight);
        #endif

        if (isWater) {
            // Underside of the surface: a Snell's window where you see straight through to the
            // above-water scene, surrounded by total internal reflection of the underwater scene.
            vec3 viewWater = screenToView(unjitU, d0);
            vec3 N  = normalize(c1.rgb * 2.0 - 1.0); // surface normal, points up toward air
            vec3 Nb = -N;                            // toward the submerged camera
            vec3 I  = normalize(viewWater);          // camera -> surface (points up)

            bool tir = refract(I, Nb, 1.333) == vec3(0.0); // water(1.333) -> air; 0 vector == TIR

            // The above-water view is already in colortex0 here (gbuffers_water writes depth but
            // not colortex0, so d8's sky/scene stays) -> `scene` IS the through-surface image.
            float surfDist = length(viewWater);

            // Snell's window: keep the above-water scene nearly clear so the window reads as
            // transparent. Only apply a light tint (capped distance) — the visual contrast
            // with the heavily-tinted TIR region is what makes the window visible.
            float windowDist = min(surfDist, 3.0); // cap at 3 blocks so window stays clear
            vec3 windowTrans = exp(-absorption * windowDist * 0.5);
            vec3 windowColor = scene * windowTrans + scatter * (1.0 - windowTrans);

            // TIR mirror = reflect the view back down into the underwater scene (SSR).
            // Reflected light travels: terrain -> surface -> camera, entirely through water.
            // Use full absorption distance for the round-trip so the reflection is properly tinted.
            float reflDist = surfDist * 2.0;
            vec3 reflTrans = exp(-absorption * reflDist);

            vec3 reflColor = scatter; // fallback when SSR misses
            #ifdef WATER_REFLECTIONS
            {
                float nz = waterDither(gl_FragCoord.xy, frameCounter);
                vec2 hUV;
                if (waterReflectSSR(viewWater + Nb * 0.1, reflect(I, Nb), nz, hUV)) {
                    vec3 rawRefl = textureLod(colortex0, hUV, 0.0).rgb;
                    // Tint the reflected scene by water absorption + scatter for the round trip.
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
        vec3 trans = exp(-absorption * dist);
        vec3 foggedScene = scene * trans + scatter * (1.0 - trans);

        // Edge-blend: at the boundary of water blocks, smoothly transition between
        // the water-surface treatment and the plain underwater fog. This eliminates
        // bright aliased seams at block edges where the water flag flickers.
        float we0 = textureLod(colortex2, uv + vec2(-1.5, 0.0) * texelSize, 0.0).b;
        float we1 = textureLod(colortex2, uv + vec2( 1.5, 0.0) * texelSize, 0.0).b;
        float we2 = textureLod(colortex2, uv + vec2(0.0, -1.5) * texelSize, 0.0).b;
        float we3 = textureLod(colortex2, uv + vec2(0.0,  1.5) * texelSize, 0.0).b;
        float waterNeighbor = (we0 + we1 + we2 + we3) * 0.25;
        // If this non-water pixel borders water, darken it toward the water scatter
        // color to hide the bright seam.
        foggedScene = mix(foggedScene, foggedScene * exp(-absorption * 1.0) + scatter * (1.0 - exp(-absorption * 1.0)), smoothstep(0.0, 0.5, waterNeighbor));

        gl_FragData[0] = vec4(foggedScene, 1.0);
        return;
    }
    #endif

    // --- Translucents: glass / clear ice / solid (packed,blue) ice ---
    // Shared inputs: face normal (colortex1), RGB565 block colour (colortex2.a), lightmap
    // (colortex2.rg). Per-material: glass = colour tint + refraction + see-through; clear ice =
    // tint + refraction + frosted (moderate opacity); solid ice = tint + NO refraction + opaque.
    // All three get a Fresnel reflection (sky + SSR) from the stored normal.
    if (isTranslucent) {
        const float GLASS_OPACITY     = 0.1; // see-through
        const float CLEAR_ICE_OPACITY = 0.3; // frosted
        const float SOLID_ICE_OPACITY = 0.80; // mostly solid
        const float TRANSLUCENT_REFRACTION_DEPTH = 0.6;

        float ior; float opacity; bool doRefract;
        if (isSolidIce)      { ior = 1.31; opacity = SOLID_ICE_OPACITY; doRefract = false; }
        else if (isClearIce) { ior = 1.31; opacity = CLEAR_ICE_OPACITY; doRefract = true;  }
        else                 { ior = 1.50; opacity = GLASS_OPACITY;     doRefract = true;  }

        vec2 unjitT = uv;
        #ifdef TAA
        unjitT -= getTaaJitter() / vec2(viewWidth, viewHeight);
        #endif
        vec3 viewSurf = screenToView(unjitT, d0);
        vec3 tN = normalize(c1.rgb * 2.0 - 1.0);
        vec3 tV = normalize(-viewSurf);
        
        // Prevent normal from pointing away from the view vector at grazing angles
        tN = normalize(tN + tV * clamp(-dot(tN, tV) + 1e-5, 0.0, 1.0));
        
        vec3 albedoT = unpackColor565(texelFetch(colortex2, ivec2(gl_FragCoord.xy), 0).a);

        // Refraction (glass + clear ice only): bend the view ray through the face, reproject, accept
        // only if it stays on a translucent pixel. Solid ice is not see-through so it skips this.
        vec3 bg = scene;
        #ifdef WATER_REFRACTION
        if (doRefract) {
            vec3 rDir = refract(normalize(viewSurf), tN, 1.0 / ior);
            if (dot(rDir, rDir) > 1e-6) {
                vec2 rUV = viewToScreen(viewSurf + rDir * TRANSLUCENT_REFRACTION_DEPTH).xy;
                if (clamp(rUV, 0.0, 1.0) == rUV &&
                    texelFetch(colortex2, ivec2(rUV * vec2(viewWidth, viewHeight)), 0).b > 0.125) {
                    bg = textureLod(colortex0, rUV, 0.0).rgb;
                }
            }
        }
        #endif

        // Base colour. Solid ice (packed/blue) is OPAQUE -> gbuffers_terrain already wrote its
        // albedo and d7 lit it, so colortex0 = the lit ice; just reflect on top (no re-tint). Glass /
        // clear ice are see-through: tint the background, blend toward own lit colour by opacity.
        vec3 base;
        if (isSolidIce) {
            base = bg; // colortex0 already holds the lit opaque ice
        } else {
            vec3 seeThrough = bg * albedoT;
            vec3 ownColor   = albedoT * (0.2 + 0.8 * skylight + 0.5 * c2.r); // ambient floor + sky + blocklight
            base = mix(seeThrough, ownColor, opacity);
        }

        vec3 tGeoCross = cross(dFdx(viewSurf), dFdy(viewSurf));
        vec3 tGeoN = (dot(tGeoCross, tGeoCross) > 1e-12) ? normalize(tGeoCross) : tN;
        if (dot(tGeoN, tN) < 0.0) tGeoN = -tGeoN;

        // Fresnel reflection (sky gated by sky access; SSR hit otherwise).
        vec3 viewReflDir = reflect(normalize(viewSurf), tN);
        // Prevent reflection vector from plunging below the surface
        viewReflDir = normalize(viewReflDir + tGeoN * clamp(-dot(viewReflDir, tGeoN) + 1e-5, 0.0, 1.0));
        vec3 worldRefl   = mat3(gbufferModelViewInverse) * viewReflDir;
        vec3 wSunT  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
        vec3 wMoonT = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
        float eyeAltT = cameraPosition.y - 64.0;
        vec3 reflectColor = getSky(worldRefl, wSunT, wMoonT, eyeAltT) * skyVis;
        #ifdef WATER_REFLECTIONS
        {
            float nz = waterDither(gl_FragCoord.xy, frameCounter);
            vec2 hUV;
            if (waterReflectSSR(viewSurf + tN * 0.1, viewReflDir, nz, hUV)) {
                reflectColor = textureLod(colortex0, hUV, 0.0).rgb;
            }
        }
        #endif
        
        float cosV = clamp(max(dot(tV, tN), dot(tV, tGeoN)), 0.0, 1.0);
        float F0t  = (isClearIce || isSolidIce) ? 0.12 : 0.04; // ice glossier so reflections read; glass dielectric
        float fres = F0t + (1.0 - F0t) * pow(1.0 - cosV, 5.0);

        gl_FragData[0] = vec4(mix(base, reflectColor, fres), 1.0);
        return;
    }

    if (!isWater) {
        gl_FragData[0] = vec4(scene, 1.0);
        return;
    }

    // Un-jitter so the stored depth lines up with the (un-jittered) projection,
    // matching the reconstruction convention used in d8_fog_sky.
    vec2 unjit = uv;
    #ifdef TAA
    unjit -= getTaaJitter() / vec2(viewWidth, viewHeight);
    #endif

    const float WATER_THICKNESS_MAX = 16.0; // cap optical depth (blocks)

    vec3  viewWater  = screenToView(unjit, d0);
    vec3  viewOpaque = screenToView(unjit, d1);
    // Real water thickness (optical depth). depthtex1 DOES separate translucents here (verified via
    // WATER_DEBUG 2): this is ~0 at shorelines, ramping up in deep water -- which is exactly how
    // Allium scales refraction. NO `<0.05 -> 1.5` fallback: that fallback (a
    // leftover from a stale "depthtex1 is collapsed" belief) forced FULL thickness onto the thin
    // shoreline water, so refraction ran at full strength right at the edge -> the bright OUTLINE.
    // Cap so water with sky/void behind it (d1==1.0 -> huge distance) doesn't over-absorb to black.
    float thickness = min(distance(viewWater, viewOpaque), WATER_THICKNESS_MAX);

    vec3 viewNormal = normalize(c1.rgb * 2.0 - 1.0);
    vec3 V = normalize(-viewWater); // surface -> camera, view space
    
    // Prevent normal from pointing away from the view vector at grazing angles
    viewNormal = normalize(viewNormal + V * clamp(-dot(viewNormal, V) + 1e-5, 0.0, 1.0));

    // Refraction is driven by the wave normal's DEVIATION from the FACE's geometric normal,
    // reconstructed from depth via screen-space derivatives. This yields zero screen offset for
    // still water on ANY orientation, so the refracted scene doesn't slide as the camera moves.
    // (Using world-up as the reference only worked for flat tops; vertical side faces have a
    // horizontal geo-normal, so subtracting world-up sheared them.)
    // NaN GUARD: at water silhouettes / degenerate pixels the depth-derivative cross product
    // collapses to ~0, so normalize() returns NaN -> distortN is NaN -> `distortN * STRENGTH` stays
    // NaN even when STRENGTH==0 (NaN*0 == NaN) -> refrUV = clamp(uv + NaN) is garbage -> samples a
    // stray bright pixel = the edge OUTLINE. (That is exactly why setting STRENGTH to 0 did NOT kill
    // the lines but disabling the macro did.) When the cross collapses, fall back to the wave normal
    // so distortN is exactly 0.
    vec3 geoCross = cross(dFdx(viewWater), dFdy(viewWater));
    vec3 geoViewN = (dot(geoCross, geoCross) > 1e-12) ? normalize(geoCross) : viewNormal;
    if (dot(geoViewN, viewNormal) < 0.0) geoViewN = -geoViewN;
    
    // Snap the faceted depth-derivative normal to the nearest cardinal axis in world space.
    // This perfectly reconstructs the flat, un-displaced block face normal (since water blocks
    // are axis-aligned), preventing per-triangle refraction jumps on displaced water.
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

    // Lighting context: sky direction (for the reflection sky fallback) + a cheap day/night
    // factor that dims the in-scatter term at dusk/night.
    vec3  worldSunDir  = mat3(gbufferModelViewInverse) * normalize(sunPosition);
    vec3  worldMoonDir = mat3(gbufferModelViewInverse) * normalize(-sunPosition);
    float eyeAltitude  = cameraPosition.y - 64.0;
    float dayFactor    = clamp(worldSunDir.y * 1.5 + 0.2, 0.04, 1.0);

    // Refraction: offset the background sample by the surface ripple slope
    vec3 refractColor = scene;
    #ifdef WATER_REFRACTION
    // Distance-based refraction fade: keeps physical refraction size stable and
    // prevents extreme screen-space warping/noise on distant water.
    float dist = length(viewWater);
    float distFade = 3.0 / max(dist, 3.0);

    // Edge-aware refraction fade: checks if neighboring pixels are also water
    // in colortex2 (where water flag .b = 1.0). Fades refraction to 0 at the shore
    // boundaries to prevent dry-land color bleeding and enable clean TAA edge anti-aliasing.
    float w0 = textureLod(colortex2, uv + vec2(-1.5, 0.0) * texelSize, 0.0).b;
    float w1 = textureLod(colortex2, uv + vec2(1.5, 0.0) * texelSize, 0.0).b;
    float w2 = textureLod(colortex2, uv + vec2(0.0, -1.5) * texelSize, 0.0).b;
    float w3 = textureLod(colortex2, uv + vec2(0.0, 1.5) * texelSize, 0.0).b;
    float edgeFade = clamp((w0 + w1 + w2 + w3) * 0.25, 0.0, 1.0);
    edgeFade = smoothstep(0.0, 1.0, edgeFade);

    float depthFade = clamp(thickness * 0.5, 0.0, 1.0);
    vec2  refrUV = clamp(uv + distortN * (WATER_REFRACTION_STRENGTH * depthFade * distFade * edgeFade), vec2(0.0), vec2(1.0));
    // Accept the offset only if it stayed inside the water body (colortex2.b water flag at the
    // refracted location), the way Allium gates refraction by material. The old test compared
    // depthtex0 (the water SURFACE) at refrUV to the current surface depth, which FAILED wherever a
    // wave pushed the offset toward nearer surface -> patchy unrefracted HOLES. The flag test has no
    // depth-comparison failure: interior offsets stay in water (always refract -> no holes), and an
    // offset crossing a shoreline onto land/foreground (flag 0) falls back to the unrefracted bg.
    if (texture(colortex2, refrUV).b > 0.875) {
        refractColor = textureLod(colortex0, refrUV, 0.0).rgb;
        float dR = texture(depthtex1, refrUV).r;
        thickness = min(distance(screenToView(refrUV, d0), screenToView(refrUV, dR)), WATER_THICKNESS_MAX);
    }
    #endif

    // Beer-Lambert absorption + in-scatter tint, using the real thickness -> shallow shore water is
    // nearly clear, deep water tinted. No 1.5 fallback (see thickness note above).
    vec3 absorption = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);
    // In-scatter is skylight scattered in the water -> gate by skylight (caves/rooms dark) and
    // by the day/night factor, so it doesn't glow bright in shadowed or enclosed water.
    vec3 scatter = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B) * skyVis * dayFactor;
    vec3 trans = exp(-absorption * thickness);
    refractColor = refractColor * trans + scatter * (1.0 - trans);

    // Reflection: dedicated view-space SSR, sky fallback gated by skylight
    vec3 viewReflDir = reflect(normalize(viewWater), viewNormal); // incident = camera->surface
    // Prevent reflection vector from plunging below the surface (fixes underworld reflection on peaks)
    viewReflDir = normalize(viewReflDir + geoViewN * clamp(-dot(viewReflDir, geoViewN) + 1e-5, 0.0, 1.0));
    vec3 worldRefl   = mat3(gbufferModelViewInverse) * viewReflDir;

    // Sky fallback is scaled by skyVis so water in caves / enclosed rooms doesn't reflect bright
    // sky. SSR hits sample the already-lit scene (colortex0) and stay un-gated.
    vec3 reflectColor = getSky(worldRefl, worldSunDir, worldMoonDir, eyeAltitude) * skyVis;
    #ifdef WATER_REFLECTIONS
    {
        float nz = waterDither(gl_FragCoord.xy, frameCounter);
        vec2 hitUV;
        if (waterReflectSSR(viewWater + viewNormal * 0.1, viewReflDir, nz, hitUV)) {
            reflectColor = textureLod(colortex0, hitUV, 0.0).rgb;
        }
    }
    #endif


    // --- GGX sun/moon specular highlight (Cook-Torrance microfacet BRDF) ---
    // Analytical per-pixel evaluation against the wave normal — produces the
    // dancing sun glint that makes normals visually pronounced without relying
    // on noisy SSR. Perfectly stable regardless of normal strength.
    vec3  sunDir  = normalize(sunPosition);       // view-space
    vec3  moonDir = normalize(-sunPosition);

    // Pick the active celestial light (same logic as vectors.glsl)
    vec3 L = (worldTime < 12700 || worldTime > 23250) ? sunDir : moonDir;

    // Reconstruct light colour (same maths as colors.glsl, inlined here)
    float sunUp     = max(dot(worldSunDir, vec3(0.0, 1.0, 0.0)), 0.0);
    vec3  sunCol    = mix(vec3(1.0, 0.65, 0.35) * 0.15, vec3(1.0, 1.0, 1.1), sunUp);
    float moonUp    = max(dot(worldMoonDir, vec3(0.0, 1.0, 0.0)), 0.0);
    vec3  moonCol   = vec3(0.65, 0.85, 1.0) * 0.02;
    float moonVis   = pow(clamp(dot(worldMoonDir, vec3(0.0, 1.0, 0.0)) + 0.1, 0.0, 0.1) / 0.1, 2.0);
    vec3  lightCol  = mix(sunCol, moonCol, moonVis);

    // GGX NDF (Trowbridge-Reitz)
    vec3  H     = normalize(V + L);
    float NdotH = max(dot(viewNormal, H), 0.0);
    float NdotL = max(dot(viewNormal, L), 0.0);
    float NdotV = max(dot(viewNormal, V), 1e-5);
    float VdotH = max(dot(V, H), 0.0);

    float a  = WATER_ROUGHNESS * WATER_ROUGHNESS;   // alpha = roughness²
    float a2 = a * a;
    float denom = NdotH * NdotH * (a2 - 1.0) + 1.0;
    float D = a2 / (PI * denom * denom);

    // Height-correlated Smith GGX Visibility (replaces separated G and the 1 / 4*NdotV*NdotL term)
    // This formulation avoids division by near-zero at wave peaks and perfectly conserves energy,
    // which prevents the analytical sun reflection from blowing out.
    float GGXV = NdotL * sqrt(NdotV * NdotV * (1.0 - a2) + a2);
    float GGXL = NdotV * sqrt(NdotL * NdotL * (1.0 - a2) + a2);
    float Vis = 0.5 / max(GGXV + GGXL, 1e-5);

    // Schlick Fresnel for the specular lobe
    float F0 = 0.02;
    float Fspec = F0 + (1.0 - F0) * pow(1.0 - VdotH, 5.0);

    // Cook-Torrance: D * Vis * F
    float specBRDF = D * Vis * Fspec;
    vec3  specular = specBRDF * NdotL * lightCol * (1.0 - rainStrength * 0.75);

    // Gate by sky access so caves don't get a specular highlight
    specular *= skyVis;

    // Roughness-corrected Schlick Fresnel for reflection/refraction blend.
    // Caps grazing-angle reflectance at (1 - roughness) instead of 1.0.
    // Use the maximum of the wave normal dot and the geometric normal dot to prevent
    // steep wave peaks from over-reflecting (acting like grazing angles).
    float cosT = clamp(max(dot(V, viewNormal), dot(V, geoViewN)), 0.0, 1.0);
    float Fmax = max(1.0 - WATER_ROUGHNESS, F0);
    float fresnel = F0 + (Fmax - F0) * pow(1.0 - cosT, 5.0);

    vec3 result = mix(refractColor, reflectColor, fresnel) + specular;

    gl_FragData[0] = vec4(result, 1.0);
}

#endif
