#ifndef CLOUDS_GLSL
#define CLOUDS_GLSL

// SerieVX volumetric clouds — Schneider/Decima multi-octave 3D raymarch.
// Phase 5 scope: cloud density + single-tap optical depth (cone-marched along
// sun ray). Consumed by program/prepare/p1_cloud_shadow.glsl to build the
// 512² R16F cloud-shadow map. Phase 6 will add the full primary raymarch
// + light-cone-march + Wrenninge MS using the same cloudDensity().
//
// Noise layout (see shaderpacks/volume-noise-generator/input/cloud_*.txt):
//   cloudNoiseBase   128³ RGBA8 : R=perlin-worley shape, G=worley erode mid,
//                                  B=worley erode hi,    A=coverage perlin
//   cloudNoiseDetail  32³ RGBA8 : R=curl, G=worley wisp, B=worley sharp wisp,
//                                  A=boiling perlin
//
// Requires: atmosphereConstants.glsl (PLANET_RADIUS, GetRaySphereIntersection)
//           options.glsl            (CLOUDS_* defines)
//           uniforms.glsl           (cloudNoiseBase/Detail, frameTimeCounter)

#include "/lib/fragment/atmosphereConstants.glsl"
// raymarchClouds samples the atmosphere T-LUT per step (sunset-orange tint
// on backlit cores) and does an aerial-perspective wrap at the end (far
// cumulus dissolves into sky). Included here for self-sufficiency — both
// consumer wrappers (d8 deferred + p1 prepare) already pull in
// `lib/uniforms.glsl` first, which declares colortex12 that the LUT reads.
#include "/lib/fragment/atmosphereLUT.glsl"

// 3D cloud noise samplers. Bound globally via `customTexture.cloudNoiseBase`
// in shaders.properties. Iris only accepts custom GLSL uniform names under
// the customTexture.* directive — `texture.<stage>.<custom_name>` is reserved
// for built-ins (noisetex / colortex0..15 / depthtex / shadowtex) or rebinds
// via the `.N` slot-index suffix. Declared in this header rather than in
// uniforms.glsl just for locality (only the two consumers actually sample).
uniform sampler3D cloudNoiseBase;
uniform sampler3D cloudNoiseDetail;

// World→noise scale. ~5.5 km base tile (small enough that the cloud-layer
// thickness covers significant noise variation, large enough that visible
// repetitions across the horizon aren't obvious). Detail at ~700 m tile.
const float CLOUDS_BASE_SCALE   = 0.00018 / CLOUDS_SIZE_MULTIPLIER;
const float CLOUDS_DETAIL_SCALE = 0.0014  / CLOUDS_SIZE_MULTIPLIER;

// Cloud-layer radii in planet-centered coordinates (m from planet center).
const float CLOUDS_R_BOTTOM = PLANET_RADIUS + (CLOUDS_LAYER_BOTTOM * CLOUDS_ALTITUDE_MULTIPLIER);
const float CLOUDS_THICKNESS = (CLOUDS_LAYER_TOP - CLOUDS_LAYER_BOTTOM) * CLOUDS_HEIGHT_MULTIPLIER;
const float CLOUDS_R_TOP    = CLOUDS_R_BOTTOM + CLOUDS_THICKNESS;


// Linear remap with clamp at 0.
float remap01(float x, float oldLo, float oldHi) {
    return clamp((x - oldLo) / max(oldHi - oldLo, 1e-6), 0.0, 1.0);
}

// Photon-style edge sharpener. k=0 → identity, k>0 → pushes mids up, edges
// down; gives the "wispy below, hard above" silhouette real cumulus have.
float lift(float x, float k) {
    return clamp(x * (1.0 + k) - k, 0.0, 1.0);
}


// Cumulus height profile. Flat (zero) at the very bottom for the
// characteristic crisp condensation base, quick ramp to a high shoulder,
// gentle taper to zero at the top. Bumping peak from h01≈0.30 to ≈0.50
// gives the cauliflower bulge above the base instead of clouds sitting
// flat on the bottom of the layer.
float cloudHeightProfile(float h01) {
    float ramp    = smoothstep(0.0, 0.05, h01);    // extremely sharp ramp = very flat base
    float fallOff = smoothstep(1.00, 0.55, h01);   // slower taper over the upper half = rounded dome tops
    return ramp * fallOff;
}


// World-space wind offset. CLOUDS_WIND_DIR_X/Z need not be normalized — the
// vector magnitude just multiplies into the speed.
vec3 cloudWindOffset(float speedMul) {
    return vec3(CLOUDS_WIND_DIR_X, 0.0, CLOUDS_WIND_DIR_Z)
         * (CLOUDS_WIND_SPEED * speedMul * frameTimeCounter);
}


// Manually wrap a UV coordinate to [0,1) before passing to texture().
//
// Critical for players far from the world origin: GPU texture units' built-in
// GL_REPEAT wrap performs `fract()` at fixed-point precision (often only ~16-
// bit), so at large UV magnitudes (e.g. worldPos.x = -2 000 000 × 3.3e-4 →
// UV.x = -660) adjacent pixels' UVs collapse to the same texel and the
// texture "stretches" along that axis. Doing the wrap in float32 here keeps
// per-pixel UV variation resolvable. floor() is exact on integers, and
// `x - floor(x)` only loses bits equal to the integer part — for UV
// magnitudes ≤ ~10⁶, that's well within float32 mantissa.
vec3 wrapUV(vec3 uv) {
    return uv - floor(uv);
}


// Cloud density at world position. Returns 0 outside the cumulus shell.
//
// Stage-1 redesign:
//   1. altitude early-out
//   2. 3D perlin-worley shape + 3D coverage (base.a, sampled at the same UV)
//      → height-profile × NUBIS carve. 3D coverage means a given XZ has
//      different "presence" at different altitudes, so cloud bottoms/tops
//      vary naturally per-XZ instead of locking to one altitude band.
//   3. base.g mid-freq erosion via multiplicative `linearStep` (preserves cores)
//   4. curl-distorted detail UVs + boiling temporal warp (when !cheapMode)
//      → wisp + sharp-wisp erosion via `linearStep`
//   5. per-altitude `lift()` edge-sharpening: wispy below, hard above
//   6. × CLOUDS_DENSITY (the extinction coefficient, separate from shaping)
//
// `cheapMode` = skip detail+curl sampling. Used by the cloud-shadow map and the
// light cone-march where detail-frequency aliasing buys nothing.
float cloudDensity(vec3 worldPos, bool cheapMode) {
    float r = length(vec3(worldPos.x, worldPos.y + PLANET_RADIUS, worldPos.z));
    if (r < CLOUDS_R_BOTTOM || r > CLOUDS_R_TOP) return 0.0;

    float h01 = clamp((r - CLOUDS_R_BOTTOM) / CLOUDS_THICKNESS, 0.0, 1.0);

    // (1) Wind advection. We evaluate wind once for the base position so that
    // the entire cloud structure moves cohesively. We also offset the entire
    // grid by half a tile so that the mathematical 0,0 tile seams don't 
    // spawn directly over the player's head at world origin!
    vec3 basePos = worldPos + cloudWindOffset(1.0) + vec3(0.5 / CLOUDS_BASE_SCALE, 0.0, 0.5 / CLOUDS_BASE_SCALE);

    // (2) Base shape sample. We sample the pre-baked 3D texture for the 
    // cauliflower bubbles (.r) and mid-frequency erosion (.g). 
    // We do NOT use any domain warping here so the bubbles stay perfectly crisp.
    vec4 base = textureLod(cloudNoiseBase, wrapUV(basePos * CLOUDS_BASE_SCALE), 0.0);

    // (3) Row-Free Coverage. The 3D texture's Perlin (.a) channel inherently 
    // forms grid rows. The math warp was too swirly. 
    // Solution: We completely ignore the Perlin channel. Instead, we fetch the 
    // Worley channel (.g) at a 0.35x macro scale to act as our coverage map.
    // Worley noise is naturally cellular, so it inherently forms spherical, organic 
    // cloud banks with absolutely ZERO grid rows or swirls!
    float macroCov = textureLod(cloudNoiseBase, wrapUV(basePos * (CLOUDS_BASE_SCALE * 0.35)), 0.0).g;
    
    // Worley .g is an erosion channel, so 1.0 - g gives solid bubble shapes.
    // We smoothstep it to create solid cohesive banks with soft edges.
    float covNoise = smoothstep(0.2, 0.8, 1.0 - macroCov);

    // Varying in Y is maintained because we are sampling a 3D texture for coverage.
    float weather  = mix(0.5, covNoise, 0.85);
    float coverage = clamp(CLOUDS_COVERAGE * 2.0 * weather, 0.0, 1.0);
    if (coverage <= 1e-3) return 0.0;

    float density = base.r * cloudHeightProfile(h01);
    // NUBIS carve, normalized so density stays in [0,1] without coverage→0
    // collapsing the shape.
    density = clamp((density - (1.0 - coverage)) / max(coverage, 1e-3), 0.0, 1.0);
    if (density <= 0.0) return 0.0;

    // (4) Mid-freq base erosion via linearStep — multiplicative remap, cores
    // remain at 1.0, edges get pulled toward 0. Detail fade ramps up with
    // altitude so cauliflower carving concentrates at the tops.
    float baseEroFade = mix(0.30, 0.85, smoothstep(0.0, 0.7, h01));
    float baseEro     = base.g * base.g * baseEroFade;
    density = remap01(density, baseEro, 1.0);
    if (density <= 0.0) return 0.0;

    if (!cheapMode) {
        // (5) Detail with curl distortion + boiling temporal warp.
        vec3 detailPos = worldPos + cloudWindOffset(2.5);

        // First fetch of detail: only need .r (curl, scalar) and .a (boiling).
        // The sixthsurge curl mode emits a scalar field, so we treat it as a
        // magnitude and project along the wind-perpendicular XZ axis — that
        // gives true cross-wind swirl rather than diagonal shear. Boiling
        // drives a small vertical warp so cores animate in place.
        vec4 detailC = textureLod(cloudNoiseDetail, wrapUV(detailPos * CLOUDS_DETAIL_SCALE), 0.0);
        vec2 windPerp = normalize(vec2(-CLOUDS_WIND_DIR_Z, CLOUDS_WIND_DIR_X)
                                  + vec2(1e-4));  // 1e-4 keeps it valid if both dirs are 0
        float curlS = detailC.r * 2.0 - 1.0;
        float boilS = detailC.a * 2.0 - 1.0;
        // Distortion grows with altitude — bases stay calm, tops swirl.
        // Reduced curl magnitude from 40.0 to 12.0 so tops stay bubbly rather than shredded.
        float curlMag = 12.0 * (0.1 + 0.9 * h01 * h01);
        vec3 distortedPos = detailPos
                          + vec3(windPerp.x, 0.0, windPerp.y) * (curlS * curlMag)
                          + vec3(0.0, boilS * 12.0, 0.0);

        // Re-sample at the distorted UV for the actual erosion channels.
        vec4 detail = textureLod(cloudNoiseDetail, wrapUV(distortedPos * CLOUDS_DETAIL_SCALE), 0.0);

        // Wisp erosion: blend mid-freq (.g) at the base to sharp (.b) at the
        // top so the silhouette gets sharper as you climb the tower.
        float wisp        = mix(detail.g, detail.b, smoothstep(0.2, 0.9, h01));
        float wispErode   = wisp * wisp * mix(0.45, 0.90, h01);
        density = remap01(density, wispErode, 1.0);
    }

    // (6) Per-altitude edge sharpening: wispy below (low k), harder above.
    // Previous k upper bound of 0.45 was clipping anything below density 0.31
    // — collapsed clouds into a thin horizontal sheet. Dropped to 0.18 (and
    // bottom to 0.02) so lift sharpens silhouette edges without erasing mid-
    // density wisps.
    float k = mix(0.02, 0.18, smoothstep(0.20, 0.85, h01));
    density = lift(density, k);

    // (7) Scale to extinction coefficient.
    return density * CLOUDS_DENSITY;
}


// Inverse of the distortion-warp used by p1_cloud_shadow.glsl. Given a world
// position, returns the cloud-shadow-map UV that texel was baked from.
// Algebra: ndc = offsetNorm / (1 + |offsetNorm|), where offsetNorm =
// (worldXZ - cameraXZ) / CLOUDS_SHADOW_EXTENT. Inverse of ndc/(1-|ndc|).
vec2 cloudShadowUV(vec3 worldPos) {
    vec2 offsetNorm = (worldPos.xz - cameraPosition.xz) / CLOUDS_SHADOW_EXTENT;
    vec2 ndc = offsetNorm / (1.0 + abs(offsetNorm));
    return ndc * 0.5 + 0.5;
}

// Sample cloud-shadow transmittance for a world-space surface point. Returns 1.0
// when CLOUDS_SHADOW is disabled, when the sample falls off the projected disc,
// or when no cloud is occluding the sun for that XZ position.
float sampleCloudShadow(vec3 worldPos) {
#ifndef CLOUDS_SHADOW
    return 1.0;
#else
    vec2 uv = cloudShadowUV(worldPos);
    // Disc clip: |ndc| approaches 1 at infinity. Fade out near the edge so
    // far terrain doesn't latch onto whatever junk the clamped boundary texel
    // holds.
    vec2 ndcAbs = abs(uv * 2.0 - 1.0);
    float edge = smoothstep(0.98, 0.92, max(ndcAbs.x, ndcAbs.y));
    float t = texture(colortex13, uv).r;
    return mix(1.0, t, edge);
#endif
}


// Cone-marched optical depth from a cloud-layer point along the sun direction.
// Used by the shadow map (Phase 5) and by the primary raymarch's light term
// (Phase 6). Exponentially growing step length so we sample densely near the
// origin (where the most accurate occlusion matters) and sparsely far away.
//
// Returns Σ density·ds, ready to be folded through Beer (`exp(-od)`).
float singleTapCloudOpticalDepth(vec3 origin, vec3 sunDir) {
    // Sun below horizon → return 0 optical depth so the consumer sees
    // transmittance=exp(0)=1 (no occlusion). The direct sun term is already
    // zero at night via NdotL, so this is a clean no-op rather than a
    // mistaken double-darkening.
    if (sunDir.y < 0.02) return 0.0;

    // March until we exit the cloud-layer top, or fall back to a small fixed
    // extent if sun is near-horizontal. ray-sphere from planet-centered origin:
    vec3 originPC = vec3(origin.x, origin.y + PLANET_RADIUS, origin.z);
    vec2 tTop = GetRaySphereIntersection(originPC, sunDir, CLOUDS_R_TOP);
    float tMax = max(tTop.y, 0.0);
    tMax = min(tMax, 4.0 * CLOUDS_THICKNESS); // hard clamp — beyond ~4×thickness the contribution is negligible
    if (tMax <= 0.0) return 0.0;

    float od = 0.0;
    float t  = 0.0;
    float dt = tMax / float(CLOUDS_SHADOW_STEPS);
    // Exponential step growth keeps near-origin sampling dense.
    float growth = 1.5;
    float invSum = 0.0;
    for (int i = 0; i < CLOUDS_SHADOW_STEPS; ++i) invSum += pow(growth, float(i));
    float stepScale = tMax / invSum;

    for (int i = 0; i < CLOUDS_SHADOW_STEPS; ++i) {
        float thisStep = stepScale * pow(growth, float(i));
        vec3 p = origin + sunDir * (t + thisStep * 0.5);
        od += cloudDensity(p, true) * thisStep;
        t  += thisStep;
    }

    return od;
}


// =============================================================================
// PHASE 6 — Primary cloud raymarch
// =============================================================================
//
// Schneider/Decima style cumulus raymarch. Spherical-shell intersection between
// CLOUDS_R_BOTTOM and CLOUDS_R_TOP, adaptive step count by elevation, per-step
// density via cloudDensity() (with detail texture), self-shadowing via a
// 5-tap exponential cone-march toward the sun, Wrenninge multi-scatter
// approximated as N attenuating octaves.
//
// Performance assumes camera is BELOW the cloud bottom (true for any normal
// MC altitude — CLOUDS_LAYER_BOTTOM defaults to 1500m above sea level,
// players sit ~80m). Ray must travel through-vacuum until tStart, then
// integrate from cloud entry to cloud exit (or CLOUDS_MAX_DISTANCE).

float _cloudHG(float cosTheta, float g) {
    float g2 = g * g;
    return (1.0 - g2) / (4.0 * pi * pow(max(1.0 + g2 - 2.0 * g * cosTheta, 1e-4), 1.5));
}

// Dual-lobe HG: forward lobe carries the sun corona, back lobe gives silver
// linings + ambient. Weights and g values from Schneider's NUBIS slides
// (mix=0.7 forward biases the visual toward the bright halo).
float cloudPhase(float cosTheta) {
    float forward = _cloudHG(cosTheta, 0.75);
    float back    = _cloudHG(cosTheta, -0.30);
    return mix(back, forward, 0.7);
}

// Exponential cone-march along the sun ray for self-shadowing. Returns Σ
// density·ds (optical depth), ready to feed into Beer/Wrenninge MS.
//
// Step length grows by `growth` each iteration so the first few taps sample
// the immediate vicinity (most opaque self-shadow contributor) and later
// taps reach far into the cloud volume cheaply.
float _cloudLightOD(vec3 pos, vec3 sunDir) {
    // During twilight (dawn/dusk), the sun/moon dips below the horizon.
    // If we march downward, the ray exits the cloud layer immediately, returning
    // 0 density and causing the clouds to unnaturally lose all self-shadowing.
    // By clamping the Y-axis of the march direction to be at least horizontal,
    // we ensure the ray evaluates the cloud volume for proper multi-scatter shadowing.
    vec3 marchDir = normalize(vec3(sunDir.x, max(sunDir.y, 0.05), sunDir.z));
    
    const float baseStep = 60.0;
    const float growth   = 1.7;
    float od = 0.0;
    float stepLen = baseStep;
    for (int i = 0; i < CLOUDS_LIGHT_STEPS; ++i) {
        pos += marchDir * stepLen;
        od += cloudDensity(pos, true) * stepLen;  // cheap mode — no detail sampling
        stepLen *= growth;
    }
    return od;
}

// Primary cloud raymarch.
//   `origin`         = camera world position (cameraPosition uniform)
//   `dir`            = normalized view direction (world space)
//   `sunDir`         = normalized world-space sun direction
//   `sunIlluminance` = **raw** SUN_COLOR_BASE (no atmospheric T baked in).
//                      Per-step T(cosLightZenith, sampleHeight) is sampled
//                      inside the loop so backlit cores get sunset orange.
//   `ambient`        = sky-ambient color from getSkyAmbient(cloudMidAlt).
// Returns: (scatter.rgb, transmittance.alpha). Compose into the sky pixel as
//   `finalSky = skyColor * cloud.a + cloud.rgb`.
vec4 raymarchClouds(vec3 origin, vec3 dir, vec3 sunDir, vec3 sunIlluminance, vec3 ambient) {
#if CLOUDS_DEBUG == 3
    // Sanity-check: sample the base noise at the cloud-layer midpoint above the
    // camera. If the texture isn't loaded, this returns 0 everywhere (black sky).
    // If it loads, we get the perlin-worley R channel visualized as grayscale.
    float cloudMidY = (CLOUDS_LAYER_BOTTOM + CLOUDS_LAYER_TOP) * 0.5;
    float t_dbg = (cloudMidY - origin.y) / max(dir.y, 1e-3);
    vec3 p_dbg = origin + dir * t_dbg;
    vec4 n = texture(cloudNoiseBase, wrapUV(p_dbg * CLOUDS_BASE_SCALE));
    return vec4(vec3(n.r), 0.0);  // alpha=0 → fully opaque, replaces sky
#endif

    // Layer intersection in planet-centered coordinates. Handles the camera
    // ANYWHERE relative to the shell — below it (normal MC altitude), inside it
    // (flying through the cumulus), or above it (looking down on the deck). The
    // old code assumed camera-below: it took only the upward sphere exits and
    // culled every downward ray, so the deck got sliced off at the horizon the
    // moment the player climbed into it and vanished entirely once above it.
    vec3  originPC = vec3(origin.x, origin.y + PLANET_RADIUS, origin.z);
    float rOrig    = length(originPC);

    vec2 sBottom = GetRaySphereIntersection(originPC, dir, CLOUDS_R_BOTTOM);
    vec2 sTop    = GetRaySphereIntersection(originPC, dir, CLOUDS_R_TOP);

    float tStart, tEnd;
    if (rOrig > CLOUDS_R_TOP) {
        // Above the deck: enter through the top sphere (must be looking down
        // into it). No forward top hit → the layer is behind us.
        if (sTop.y <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
        tStart = max(sTop.x, 0.0);
        // Leave the shell at the bottom-sphere entry if the ray descends
        // through it, otherwise at the top-sphere far exit.
        tEnd   = (sBottom.x > 0.0) ? sBottom.x : sTop.y;
    } else if (rOrig < CLOUDS_R_BOTTOM) {
        // Below the deck (the normal case): enter at the bottom-sphere far
        // exit, leave at the top-sphere far exit.
        if (sTop.y <= 0.0) return vec4(0.0, 0.0, 0.0, 1.0);
        tStart = max(sBottom.y, 0.0);
        tEnd   = sTop.y;
    } else {
        // Inside the deck: start at the camera and leave at whichever shell
        // boundary we reach first (bottom if descending, else top).
        tStart = 0.0;
        tEnd   = (sBottom.x > 0.0) ? min(sBottom.x, sTop.y) : sTop.y;
    }

    // Ground clip: solid planet between us and the shell exit hides the clouds
    // beyond it. Only bites on downward rays, which are no longer culled.
    vec2 sPlanet = GetRaySphereIntersection(originPC, dir, PLANET_RADIUS);
    if (sPlanet.x > 0.0) tEnd = min(tEnd, sPlanet.x);

    if (tEnd <= tStart) return vec4(0.0, 0.0, 0.0, 1.0);

#if CLOUDS_DEBUG == 1
    return vec4(1.0, 0.0, 0.0, 0.0);  // pure red where the march would run
#endif

    // Adaptive distance cap with smooth blending. We want clouds to render far into
    // the horizon (up to ~80km), so we give low-angle rays a larger reach.
    // Using length() instead of max() creates a perfectly smooth hyperbolic boundary
    // instead of a sharp crease, eliminating geometric cut-off lines in the sky.
    float verticalReach = CLOUDS_THICKNESS * 0.5;
    float distForReach  = verticalReach / max(dir.y, 0.02);
    float effectiveMax  = length(vec2(CLOUDS_MAX_DISTANCE, distForReach));
    tEnd = min(tEnd, tStart + effectiveMax);

    // More steps near horizon (long path through layer) than zenith (short path).
    int steps = int(mix(float(CLOUDS_PRIMARY_STEPS) * 2.0,
                        float(CLOUDS_PRIMARY_STEPS),
                        smoothstep(0.0, 0.7, dir.y)));
    steps = clamp(steps, 8, 128);

    // Exponential step growth for primary raymarch.
    // Increases step size as distance from camera increases, improving performance
    // and maintaining high quality near the player.
    float growth = 1.04; // 4% growth per step
    float sumProgression = (pow(growth, float(steps)) - 1.0) / (growth - 1.0);
    float baseStep = (tEnd - tStart) / sumProgression;

    float cosTheta = dot(dir, sunDir);
    float phase    = cloudPhase(cosTheta);

    // Spatiotemporal jitter — Jorge Jimenez's Interleaved Gradient Noise
    // (different value per pixel) blended with a golden-ratio frame counter
    // (rotates per frame). This decorrelates adjacent pixels' sample
    // positions, so TAA averages cleanly instead of seeing all pixels jump
    // together (which causes the cloud-edge flicker the previous purely-
    // temporal jitter produced). Same idea as Photon's `texelFetch(noisetex,
    // pos & 511, 0).b + r1(frameCounter, ...)` but doesn't need a noise tex.
    float ignSpatial = fract(52.9829189 * fract(0.06711056 * gl_FragCoord.x
                                              + 0.00583715 * gl_FragCoord.y));
    float jitter     = fract(ignSpatial + 0.61803398875 * float(frameCounter));

    vec3  scatter = vec3(0.0);
    float trans   = 1.0;

    // Density-weighted distance to "where the cloud is" along this ray.
    // Used after the loop to scale AP strength by apparent cloud distance:
    // a thin haze at 30 km should blend fully into sky, while a fat cumulus
    // at 5 km should stay clearly visible. Without this the AP wrap is
    // uniform (one fixed strength) and either erases close clouds or leaves
    // far ones too opaque.
    float distSum    = 0.0;
    float distWeight = 0.0;

    for (int i = 0; i < steps; ++i) {
        float thisStep = baseStep * pow(growth, float(i));
        float t_base = tStart + baseStep * (pow(growth, float(i)) - 1.0) / (growth - 1.0);
        float t = t_base + jitter * thisStep;
        vec3  p = origin + dir * t;

        float density = cloudDensity(p, false);
        
        // Volumetric distance erosion: smoothly thin out the cloud volume over the
        // last 25% of the render distance. This guarantees the cloud physically
        // tapers to 0 density before hitting the cap.
        float distFade = 1.0 - smoothstep(effectiveMax * 0.75, effectiveMax, t - tStart);
        density *= distFade;

        if (density <= 0.0) continue;

#if CLOUDS_DEBUG == 2
        return vec4(0.0, 1.0, 1.0, 0.0);  // cyan on first density-positive sample
#endif

        // Beer through the step.
        float sigma_e = density;
        float sigma_s = density;  // assume single-scatter albedo ≈ 1 for water clouds
        float stepT   = exp(-sigma_e * thisStep);

        // Self-shadow (sun visibility through cloud volume).
        float lightOD = _cloudLightOD(p, sunDir);

        // Per-step atmospheric transmittance from the sun to *this* sample.
        // Cheap (1 LUT tap) but pays for itself at every sunrise/sunset —
        // low cosLightZenith + low sample altitude give a strong red-orange T,
        // so backlit cloud cores tint warm even when they're optically thick.
        // Pre-multiplying T at cloudMidAlt (the old approach) clobbered this.
        vec3  pPC     = vec3(p.x, p.y + PLANET_RADIUS, p.z);
        float r_p     = length(pPC);
        float cosLZ   = dot(pPC / max(r_p, 1.0), sunDir);
        
        // Planet shadow: T-LUT only encodes atmospheric extinction, so we must
        // manually block light if the ray to the sun/moon intersects the planet.
        // A soft penumbra (PLANET_RADIUS to +1500m) gives a beautiful Earth shadow fade.
        float planetShadow = 1.0;
        if (cosLZ < 0.0) {
            float d_min = r_p * sqrt(max(1.0 - cosLZ * cosLZ, 0.0));
            planetShadow = smoothstep(PLANET_RADIUS, PLANET_RADIUS + 1500.0, d_min);
        }
        
        vec3  sunHere = sunIlluminance * sampleTransmittanceLUT(cosLZ, r_p) * planetShadow;

        // Wrenninge multi-scatter octaves with Beer-Powder modulation. Each
        // octave: extinction/scatter/phase eccentricity halve per step. The
        // Beer-Powder combination gives the iconic "silver lining" — bright
        // edges where light scatters forward through thin areas, with proper
        // Beer absorption inside dense cores.
        vec3 directLight = vec3(0.0);
        float a = 1.0;   // extinction attenuation per octave
        float b = 1.0;   // scatter attenuation per octave
        float c = 1.0;   // phase eccentricity attenuation per octave
        for (int o = 0; o < CLOUDS_MS_OCTAVES; ++o) {
            float beer_o   = exp(-lightOD * a);
            float powder_o = 1.0 - exp(-lightOD * a * 2.0);
            // Energy: Beer in dense cores (high lightOD), 2× Powder at thin
            // edges (low lightOD) — gives the silver-lining glow.
            float energy_o = beer_o * mix(2.0 * powder_o, 1.0, beer_o);
            // Phase: blend toward isotropic as octaves go up.
            float phase_o  = mix(0.25 / pi, phase, c);
            directLight += b * energy_o * phase_o * sunHere;
            a *= 0.5;
            b *= 0.5;
            c *= 0.5;
        }

        // Ambient sky illumination. lightOD-based occlusion is correct under
        // strong direct light (dense cores get less sky penetration), but
        // wrong during twilight: the moon is ~140× dimmer than the sun, and
        // its near-horizontal lightOD cone hits a lot of cloud → fake-shadow
        // bands across cores even though the moon contributes ~0 lighting.
        // Photon avoids this by computing a separate upward sky_optical_depth;
        // we get the same effect more cheaply by scaling lightOD by the
        // light-source brightness so a dim moon can't false-occlude the sky.
        // Using sunHere (which includes planet shadow) ensures that when the
        // planet blocks the light, we scale down the directional occlusion.
        // We retain a baseline to act as ambient occlusion so the clouds
        // don't lose all internal depth and flatten completely during twilight.
        float lightLum      = clamp(dot(sunHere, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);
        float effectiveOD   = lightOD * max(lightLum, 0.25);
        
        // Calculate relative altitude (0.0 to 1.0) for this specific raymarch step
        float h01_step = clamp((r_p - CLOUDS_R_BOTTOM) / CLOUDS_THICKNESS, 0.0, 1.0);

        // Local ambient occlusion: denser parts get darker, revealing 3D shapes even in shadow.
        // This completely fixes the "flat shaded" look on the cloud underbellies.
        float localAO = mix(1.0, 0.4, density);
        float ambientFactor = 0.6 * mix(1.0, 0.25, smoothstep(0.0, 4.0, effectiveOD)) * localAO;
        
        // Ground bounce (Earthshine): Upwelling light from the terrain reflecting onto the 
        // flat cloud bottoms. We use a powder effect so the edges glow and the centers shadow.
        // Scaled by lightLum so it naturally darkens when the sun sets, but retains a minimum
        // so night clouds aren't pitch black underneath.
        float basePowder = exp(-density * 0.5) * (1.0 - exp(-density * 2.0));
        float earthShine = exp(-h01_step * 8.0) * basePowder * 0.7 * max(lightLum, 0.25);
        
        vec3  inscatterColor = directLight + ambient * (ambientFactor + earthShine);

        // Energy-conserving step integration.
        vec3 contrib = inscatterColor * sigma_s * (1.0 - stepT) / max(sigma_e, 1e-7);
        scatter += trans * contrib;
        trans   *= stepT;

        // Track density-weighted apparent distance for the AP-distance fade
        // after the loop. Use density (not contrib) so the mean represents
        // "where the matter is" not "where the lit matter is".
        distSum    += t * density;
        distWeight += density;

        if (trans < CLOUDS_MIN_TRANSMITTANCE) {
            trans = 0.0;
            break;
        }
    }

    // Remap transmittance so the early-out cutoff is invisible.
    trans = (trans - CLOUDS_MIN_TRANSMITTANCE) / max(1.0 - CLOUDS_MIN_TRANSMITTANCE, 1e-6);
    trans = clamp(trans, 0.0, 1.0);

    // Aerial-perspective wrap. Atmospheric transmittance dims the scattering
    // and expands the silhouette so distant cumulus dissolves into the sky.
    // (originPC / rOrig already computed for the shell intersection above.)

    // Evaluate atmospheric transmittance to the actual visible cloud depth.
    // We use a midpoint analytic evaluation rather than T-LUT division. T-LUT division 
    // suffers from massive precision collapse on long horizontal paths, causing the 
    // transmittance to drop to 0 way too early (which makes clouds 'fade out too close').
    // The lower atmosphere density gradient is extremely smooth, so a single midpoint 
    // Riemann sum gives mathematically perfect, artifact-free transmittance up to 100km.
    float distToCloud = distWeight > 0.0 ? (distSum / distWeight) : tEnd;
    vec3  midPosPC    = originPC + dir * (distToCloud * 0.1);
    float midR        = length(midPosPC * 0.9995);
    
    vec3  midDens     = GetAtmosphereDensity(midR);
    vec3  extinction  = COEFF_ATTENUATION * midDens;
    vec3  air_T       = exp(-extinction * distToCloud);

    // Pure physical AP. At 70km+ distances, physical air transmittance is naturally
    // low enough to perfectly dissolve the clouds into the sky background without
    // any artificial bounds, starting points, or hacks.
    float effAirT   = dot(air_T, vec3(0.2126, 0.7152, 0.0722));

    scatter *= effAirT;
    trans    = 1.0 - effAirT * (1.0 - trans);

    return vec4(scatter, trans);
}

#endif
