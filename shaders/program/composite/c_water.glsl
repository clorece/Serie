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
            if (texture(colortex2, rayPos.xy).b > 0.5) continue; // skim over water, keep going
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

    vec4  c2 = texture(colortex2, uv);      // .rg = lightmap, .b = water flag
    bool  isWater  = c2.b > 0.5;
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
                    vec3 rawRefl = texture(colortex0, hUV).rgb;
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

    vec3  viewWater  = screenToView(unjit, d0);
    vec3  viewOpaque = screenToView(unjit, d1);
    float thickness  = distance(viewWater, viewOpaque);
    // depthtex1 may not separate translucents in this pack -> thickness collapses to ~0.
    // Fall back to a default depth so water still gets an absorption tint.
    if (thickness < 0.05) thickness = 1.5;

    vec3 viewNormal = normalize(c1.rgb * 2.0 - 1.0);
    vec3 V = normalize(-viewWater); // surface -> camera, view space

    // Refraction is driven by the wave normal's DEVIATION from the FACE's geometric normal,
    // reconstructed from depth via screen-space derivatives. This yields zero screen offset for
    // still water on ANY orientation, so the refracted scene doesn't slide as the camera moves.
    // (Using world-up as the reference only worked for flat tops; vertical side faces have a
    // horizontal geo-normal, so subtracting world-up sheared them.)
    vec3 geoViewN = normalize(cross(dFdx(viewWater), dFdy(viewWater)));
    if (dot(geoViewN, viewNormal) < 0.0) geoViewN = -geoViewN;
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
    // Reject the offset if it lands on foreground geometry in front of the water.
    if (getDepth(texture(depthtex0, refrUV).r) >= getDepth(d0) - 0.05) {
        refractColor = texture(colortex0, refrUV).rgb;
        float dR = texture(depthtex1, refrUV).r;
        thickness = distance(screenToView(refrUV, d0), screenToView(refrUV, dR));
    }
    #endif

    // Beer-Lambert absorption + in-scatter tint
    if (thickness < 0.05) thickness = 1.5; // re-apply fallback after the refraction recompute
    vec3 absorption = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);
    // In-scatter is skylight scattered in the water -> gate by skylight (caves/rooms dark) and
    // by the day/night factor, so it doesn't glow bright in shadowed or enclosed water.
    vec3 scatter = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B) * skyVis * dayFactor;
    vec3 trans = exp(-absorption * thickness);
    refractColor = refractColor * trans + scatter * (1.0 - trans);

    // Reflection: dedicated view-space SSR, sky fallback gated by skylight
    vec3 viewReflDir = reflect(normalize(viewWater), viewNormal); // incident = camera->surface
    vec3 worldRefl   = mat3(gbufferModelViewInverse) * viewReflDir;

    // Sky fallback is scaled by skyVis so water in caves / enclosed rooms doesn't reflect bright
    // sky. SSR hits sample the already-lit scene (colortex0) and stay un-gated.
    vec3 reflectColor = getSky(worldRefl, worldSunDir, worldMoonDir, eyeAltitude) * skyVis;
    #ifdef WATER_REFLECTIONS
    {
        float nz = waterDither(gl_FragCoord.xy, frameCounter);
        vec2 hitUV;
        if (waterReflectSSR(viewWater + viewNormal * 0.1, viewReflDir, nz, hitUV)) {
            reflectColor = texture(colortex0, hitUV).rgb;
        }
    }
    #endif


    // Schlick dielectric Fresnel (water F0 = 0.02), evaluated in view space
    float cosT = clamp(dot(V, viewNormal), 0.0, 1.0);
    float F0 = 0.02;
    float fresnel = F0 + (1.0 - F0) * pow(1.0 - cosT, 5.0);

    vec3 result = mix(refractColor, reflectColor, fresnel);

    gl_FragData[0] = vec4(result, 1.0);
}

#endif
