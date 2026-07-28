#ifndef OPTIONS_GLSL
#define OPTIONS_GLSL

#define RENDER_SCALE 0.67 // [0.33 0.5 0.59 0.67 0.77 1.0] ultra performance, performance, balanced, quality, ultra quality, native
const float renderScale = RENDER_SCALE;

#define DISTANT_HORIZONS
#define DH_FOG // apply the atmospheric aerial perspective to DH LOD terrain/water

// Upscaler / TAA reconstruction filter (lib/post/taa.glsl, runs in c0_taa).
//   0 = TAA     : variance clamp, bilinear current. Softest & most temporally
//                 stable, but the least sharp / least detail.
//   1 = TAAU    : min/max neighbourhood clamp, Catmull-Rom current. Sharper
//                 edges than TAA with still-good stability — a balanced default.
//   2 = Lanczos : Lanczos-2 reconstruction. Most clarity / detail,
//                 but more prone to temporal instability (shimmer / fireflies).
// Pair any mode with TAA_SHARPNESS (CAS) below to recover TAA blur.
#define UPSCALE_MODE 2 // [0 1 2]

//   0 = off (normal image)
//   1 = raw SOURCE colortex0, upscaled bilinear (no TAA) — specks here = pre-TAA
//   2 = SOURCE anomaly map: RED = NaN/Inf, GREEN = magenta(green-deficient) pixel
//   3 = OUTPUT anomaly map: same classifier on the resolved TAA output
//   4 = SOURCE green-deficit heatmap (continuous) — how green-starved each pixel is
// Source is CLEAN (1/2 confirmed) -> taa() makes the specks. Split taa internals:
//   5 = currentColor only (reconstruction, NO history blend) — specks here = recon
//   6 = clipped history only (prevColor)                      — specks here = history
//   7 = |reconstruction - history| x6 (where they disagree, amplified)
#define TAA_DEBUG 0 // [0 1 2 3 4 5 6 7]

#define SHADOW_FILTER
#define DITHER_FILTER

#define SHADOW_RESOLUTION 3072 //[512 1024 1563 2048 3072 4096 6144 8192]
#define SHADOW_FILTER_QUALITY 12 //[1 2 3 4 6 8 10 12 14 16 18 20 22 24]
#define SHADOW_MAP_BIAS 0.85 //Increase this if you get shadow acne. Decrease this if you get peter panning. [0.000 0.001 0.002 0.003 0.004 0.005 0.006 0.007 0.008 0.009 0.010 0.012 0.014 0.016 0.018 0.020 0.022 0.024 0.026 0.028 0.030 0.035 0.040 0.045 0.050]
#define SCREENSPACE_SHADOWS // Screen-space contact + infinite shadows multiplied onto the shadow map.

//#define FAKE_SSS  // WIP
#define SCATTER_AMOUNT 2.0; // [1.0 1.5 2.0 2.5 3.0 3.5 4.0 4.5 5.0]

#define VOLUMETRIC_LIGHT
#define VL_STEPS 3 // [2 3 4 6 8 12 16 20 24 32 48] dithered raymarch steps for atmospheric god rays (3 looks fine with TAA)
#define VL_INTENSITY 5.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0] brightness of the in-scattered sun term
#define VL_NOON_STRENGTH 5.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at noon.
#define VL_SUN_RISE_SET_STRENGTH 25.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at sunrise and sunset.
#define VL_NIGHT_STRENGTH 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at night.

#define SKY_LUT_STEPS 10       // [4 6 8 10 12 14 16 20 24 28 32 40 48]

//   0  off (normal sky)
//   1  raw SkyView LUT, bilinear  (is the artifact already in the LUT?)
//   2  raw SkyView LUT, NEAREST   (compare to 1: layers only here = upscale/filter)
//   3  LUT texel-grid overlay     (do the layers line up with LUT texels?)
//   10 build term: sun Rayleigh only
//   11 build term: sun Mie only
//   12 build term: multi-scatter (sun) only
//   13 build term: sun transmittance (sunT) accumulated
//   14 build term: moon total
#define SKY_DEBUG 0
#define SKY_DEBUG_GAIN 1.0   // [0.05 0.1 0.25 0.5 1.0 2.0 4.0 8.0 16.0] brightness multiplier for debug terms (10-14) so dim ones are visible

#define BELT_OF_VENUS
#define BELT_SHADOW_SOFTNESS 0.06 // [0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.14 0.20] angular half-width of Earth's shadow penumbra (sun cosine units). Smaller = crisper belt (more banding risk); larger = softer/washed out.
#define BELT_VIEW_SHADOW 1.0 // [0.0 0.25 0.5 0.75 1.0] strength of the view-space horizon anchor on the direct warm glow.

#define SUN_ILLUMINANCE 10.0  // [1.0 2.5 5.0 7.5 10.0 12.5 15.0 20.0] Sun light intensity multiplier for atmospheric scattering
#define MOON_ILLUMINANCE 0.02 // [0.005 0.01 0.02 0.04 0.06 0.08 0.10] Moon light intensity multiplier for atmospheric scattering
#define MIE_G 1.0            // [0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95] Mie phase function asymmetry factor (controls sun glow size/sharpness)

// Rayleigh scattering coefficients for R, G, B channels (scaled by 1e-6, default: 5.8e-6, 1.35e-5, 3.31e-5)
#define RAYLEIGH_SCATTER_R 5.8   // [1.0 2.0 3.0 4.0 5.0 5.8 6.5 7.0 8.0 10.0] Rayleigh scattering red channel
#define RAYLEIGH_SCATTER_G 13.5  // [5.0 8.0 11.0 13.5 14.5 16.0 19.0 22.0 25.0] Rayleigh scattering green channel
#define RAYLEIGH_SCATTER_B 33.1  // [15.0 20.0 25.0 30.0 33.1 38.0 43.0 50.0] Rayleigh scattering blue channel

// Mie scattering coefficients for R, G, B channels (scaled by 1e-6, default: 3.0e-6, 3.0e-6, 3.0e-6)
#define MIE_SCATTER_R 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering red channel
#define MIE_SCATTER_G 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering green channel
#define MIE_SCATTER_B 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering blue channel

// Ozone concentration peak (scaled by 1e-6, default: 8e-6)
#define OZONE_PEAK 8.0 // [0.0 2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0] Peak ozone concentration

//#define CLOUDS
#define CLOUDS_COVERAGE 0.80          // [0.20 0.30 0.40 0.45 0.50 0.55 0.60 0.65 0.70 75 0.80 0.90] global cumulus coverage (0 = clear sky, 1 = overcast)
#define CLOUDS_ALTITUDE_MULTIPLIER 0.75 // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00] Multiplier for how high in the air clouds render
#define CLOUDS_HEIGHT_MULTIPLIER 0.35 // [0.1 0.15 0.2 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.0 1.05 1.10 1.15 1.20 1.25 1.30 1.50 1.75 2.00] Multiplier for the cloud layer's vertical thickness
#define CLOUDS_SIZE_MULTIPLIER 1.00    // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00 4.00 5.00] Size multiplier for both cloud base and detail shapes
#define CLOUDS_DENSITY 0.03           // [0.01 0.02 0.03 0.05 0.08 0.12 0.18 0.25] cloud extinction coefficient (higher = denser/darker interiors)
#define CLOUDS_PUFFINESS 0.2         // [0.0 0.2 0.3 0.4 0.5 0.6 0.8 1.0] rounds the cumulus toward the puffy worley-cell look of the altocumulus (0 = original cauliflower, 1 = fully rounded blobs)
#define CLOUDS_LAYER_BOTTOM 1500.0    // [600.0 900.0 1200.0 1500.0 1800.0 2400.0 3000.0] cumulus base altitude (m above planet surface)
#define CLOUDS_LAYER_TOP    5400.0    // [2400.0 3000.0 3600.0 4500.0 5400.0 6400.0 7500.0] cumulus top altitude (m above planet surface)
#define CLOUDS_WIND_SPEED 0.6          // [0.0 0.1 0.2 0.3 0.4 0.6 0.8 1.0 1.5 2.0 3.0] blocks the clouds travel per WORLD TICK (world-time driven; ~0.6 matches the old 12 m/s)
#define CLOUDS_WIND_DIR_X 1.0         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction X
#define CLOUDS_WIND_DIR_Z 0.3         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction Z
#define CLOUDS_SHADOW                
#define CLOUDS_SHADOW_STEPS 6         // [2 3 4 6 8 12]
#define CLOUDS_SHADOW_EXTENT 2048.0   // [512.0 1024.0 1536.0 2048.0 3072.0 4096.0]
#define CLOUDS_PRIMARY_STEPS 16       // [8 16 24 32 48 64 96]
#define CLOUDS_LIGHT_STEPS 4          // [2 3 4 6 8]
#define CLOUDS_MS_OCTAVES 6           // [1 2 3 4 6]
#define CLOUDS_MAX_DISTANCE 16000.0   // [4000.0 8000.0 12000.0 16000.0 24000.0 32000.0]
#define CLOUDS_MIN_TRANSMITTANCE 0.01 // [0.001 0.005 0.01 0.02 0.05] early-out when accumulated transmittance falls below this
#define CLOUDS_DEBUG 0

//#define CLOUDS_ALTO
#define CLOUDS_ALTO_ALTITUDE 2000.0   // [2000.0 3000.0 4000.0 5000.0 6000.0 6200.0 7000.0 8000.0 9000.0] shell base altitude (m above surface). The cumulus layer always composites over (occludes) the altocumulus regardless of this.
#define CLOUDS_ALTO_THICKNESS 200.0   // [200.0 300.0 400.0 500.0 700.0 1000.0] shell vertical thickness (m) — altocumulus is a thin layer
#define CLOUDS_ALTO_MAP_COVERAGE 0.5 // [0.0 0.1 0.2 0.3 0.4 0.5 0.55 0.6 0.7 0.8 0.9 1.0] CLOUD MAP coverage — how much of the SKY the altocumulus fills (low = isolated patches in lots of clear sky, high = near-overcast). Macro placement.
#define CLOUDS_ALTO_MAP_SIZE 0.5     // [0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] CLOUD MAP size — scale of the dense-patch/clear-hole regions (higher = larger, broader patches; lower = smaller, more frequent patches)
#define CLOUDS_ALTO_COVERAGE 0.90     // [0.20 0.30 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.80 0.90] density of cells WITHIN a covered patch (higher = puffs fill in, fewer blue gaps between them). Local fill, NOT sky coverage — see CLOUDS_ALTO_MAP_COVERAGE.
#define CLOUDS_ALTO_SCALE 1.00        // [0.50 0.65 0.75 0.85 1.00 1.25 1.50 2.00] element size multiplier (smaller value = larger puffs)
#define CLOUDS_ALTO_DENSITY 0.10      // [0.03 0.05 0.08 0.10 0.14 0.20 0.30] extinction coefficient (higher = denser/whiter)
#define CLOUDS_ALTO_DETAIL 1.0        // [0.0 0.5 1.0 1.5 2.0] 3D-worley detail erosion that granulates the puffs
#define CLOUDS_ALTO_WIND_SPEED 1.0    // [0.0 0.2 0.4 0.5 0.8 1.0 1.5 2.0] drift speed multiplier (relative to cumulus wind, same direction)
#define CLOUDS_ALTO_WAVE 0.6          // [0.0 0.2 0.4 0.6 0.8 1.0] undulatus billow strength — lines the puffs into wavy parallel rows (0 = uniform field)
#define CLOUDS_ALTO_WAVE_SCALE 5.0    // [1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0 8.0 10.0] billow roll frequency (higher = tighter/closer rows)
#define CLOUDS_ALTO_WARP 0.05         // [0.0 0.1 0.2 0.3 0.35 0.45 0.6 0.8] domain-warp strength — breaks up the repetitive cell tiling (0 = raw repeating worley)
#define CLOUDS_ALTO_PRIMARY_STEPS 12  // [8 12 16 24 32] primary raymarch steps through the shell
#define CLOUDS_ALTO_LIGHT_STEPS 4     // [2 3 4 6] sun cone-march steps for self-shadow
#define CLOUDS_ALTO_SKY_BLEND 2.5     // [0.0 0.5 1.0 1.5 2.0 2.5 3.5 5.0 7.0] aerial-perspective: how strongly the high layer washes toward sky colour with distance (0 = crisp like the cumulus, higher = hazier/recedes more)

#define TAA
#define TAA_JITTER_SCALE 0.75 // [0.0 0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.45 0.5 0.55 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0]
#define TAA_BLEND_WEIGHT 0.97 // [0.85 0.86 0.87 0.88 0.89 0.90 0.91 0.92 0.93 0.94 0.95 0.96 0.97 0.98 0.99]
#define TAA_SHARPNESS 0.6 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]

#define BLOOM
#define BLOOM_STRENGTH 0.18 // [0.01 0.03 0.06 0.08 0.10 0.12 0.15 0.18 0.22 0.26 0.30]

#define CINEMATIC_LENS_FLARE
#define LENS_FLARE_STRENGTH 0.01 // [0.0 0.25 0.5 0.75 1.0 1.25 1.5 2.0 3.0 4.0]
#define LENS_FLARE_THRESHOLD 1.0 // [0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0 4.0 6.0]
#define LENS_FLARE_STREAK
#define LENS_FLARE_STREAK_STRENGTH 0.5 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define LENS_FLARE_GHOSTS
#define LENS_FLARE_GHOSTS_STRENGTH 0.5 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define LENS_FLARE_HALO
#define LENS_FLARE_HALO_STRENGTH 1.0 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0]
#define LENS_FLARE_STARBURST
#define LENS_FLARE_STARBURST_STRENGTH 0.5 // [0.1 0.25 0.5 0.75 1.0 1.5 2.0 3.0]

#define CHROMATIC_ABERRATION
#define CHROMATIC_ABERRATION_STRENGTH 1.0 // [0.25 0.5 0.75 1.0 1.5 2.0 3.0]


#define AUTO_EXPOSURE
#define EXPOSURE 1.00 // [0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 1.00 1.10 1.20 1.30 1.40 1.50 1.60 1.70 1.80 1.90 2.00 2.20 2.40 2.60 2.80 3.00]
#define AUTO_EXPOSURE_TARGET 0.16 // [0.10 0.12 0.14 0.16 0.18 0.20 0.22 0.24 0.26 0.28 0.30 0.35 0.40 0.45 0.50]
#define AUTO_EXPOSURE_SPEED 3.0 // [0.1 0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0 3.0 5.0]
#define AUTO_EXPOSURE_CENTER_WEIGHT 0.6 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
#define AUTO_EXPOSURE_MIN 0.001 // [0.01 0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.15 0.20]
#define AUTO_EXPOSURE_MAX 6.0 // [2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0 25.0 30.0]

#define TONEMAP_OPERATOR 0 // [0 1 2 3 4]
#define COLOR_CONTRAST 1.0 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_SATURATION 1.08 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]

//#define PURKINJE_EFFECT
#define PURKINJE_STRENGTH 0.6 // [0.2 0.4 0.6 0.8 1.0 1.2 1.5 2.0]

//#define HALATION
#define HALATION_STRENGTH 0.8 // [0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.5 2.0]

//#define SPLIT_TONING
#define SPLIT_TONING_STRENGTH 0.5 // [0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
#define COLOR_TEMP 0.0 // [-0.5 -0.4 -0.3 -0.2 -0.1 0.0 0.1 0.2 0.3 0.4 0.5]
#define FILM_GRAIN_I 1 // [0 1 2 3 4 5 6 7 8 9 10]
#define OVERWORLD_LUT 5 // [0 1 2 3 4 5 6 7 8 9]
#define OVERWORLD_LUT_I 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
//#define VIGNETTE

#define LIGHTING_DIRECT 200   // [50 75 100 110 125 150 200]

// RASTERISED ambient only. This scales the two flat, occlusion-free ambient
// fills in the pack -- the analytic lightmap wash used when VOXEL_GI is off, and
// the hemisphere ambient shadeDhTerrain applies to Distant Horizons LOD terrain.
// It does NOT touch the path-traced GI buffer; scale that with GI_STRENGTH.
//
// Those DH fills are deliberately scaled by GI_STRENGTH and GI_SKY_BRIGHTNESS so
// distant terrain matches the near field's brightness, but they carry no
// occlusion term at all, so raising either makes distant shaded areas go flat.
// Lowering this is the correct response to that, and it no longer costs you any
// path-traced lighting to do it.
//
// The range now goes below 25: values that low used to be a way of fighting the
// GI itself, and are legitimate for trimming a flat fill.
#define LIGHTING_INDIRECT 100  // [0 5 10 15 25 40 55 70 85 100 125 150]

//#define WIND_MOVEMENT // WIP

#define WATER_WAVES
#define WATER_PARALLAX
#define WATER_PARALLAX_STEPS 4 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32]
#define WATER_PARALLAX_HEIGHT 2.00 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00 3.00] Multiplier for the visual depth of the parallax waves
#define WATER_WAVE_OCTAVES 3 // [2 3 4 5 6] FBM octaves for the surface height field
#define WATER_WAVE_AMPLITUDE 0.24 // [0.02 0.04 0.06 0.08 0.10 0.14 0.18 0.24 0.32] bump height (blocks)
#define WATER_WAVE_SPEED 5.0 // [0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0] wave advection speed
#define WATER_NORMAL_STRENGTH 0.75 // [0.25 0.3 0.35 0.4 0.45 0.5 0.55 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0 1.25 1.5 1.75 2.0] 0 = flat, 1 = full waves
#define WATER_NORMAL_FADE 128.0 // [0.0 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0 48.0 64.0 96.0 128.0] distance (blocks) over which wave normals LOD back toward flat (anti-aliases / hides tiling at range)
#define WATER_NORMAL_FADE_MIN 100.0 // [0.0 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0 48.0 64.0 96.0 100.0] Minimum normal strength percentage at the fade distance. 0 = fully flat, 50 = 50% less strength.

#define WATER_DISPLACEMENT
#define WATER_DISPLACEMENT_HEIGHT 0.12 // [0.04 0.06 0.08 0.10 0.12 0.16 0.20 0.28 0.32 0.35 0.40] swell height (blocks)
#define WATER_DISPLACEMENT_OCTAVES 1 // [1 2 3] big FBM octaves that move the mesh (low = only the largest swells)
#define WATER_DISPLACEMENT_STEEPNESS 1.0 // [0.0 0.15 0.30 0.45 0.60 0.80 1.00] trochoidal crest sharpening (0 = rounded vertical-only)
#define WATER_DISPLACEMENT_OFFSET 0.20 // [0.0 0.02 0.04 0.06 0.08 0.10 0.14 0.20 0.30] sink the rest water level this many blocks so cranked-up crests stay at/below the vanilla waterline (raise alongside _HEIGHT)

#define WATER_REFRACTION
#define WATER_REFRACTION_STRENGTH 0.24 // [0.02 0.04 0.06 0.08 0.10 0.14 0.18 0.24 0.32 0.35 0.40 0.50] screen-space refraction offset

#define WATER_REFLECTIONS
#define WATER_REFLECTION_STEPS 32 // [16 20 24 32 48 64 96 128] screen-space SSR march steps (higher = sharper / catches more)
#define WATER_SKYLIGHT_THRESHOLD 0.1 // [0.0 0.3 0.5 0.6 0.7 0.8 0.9] min sky access before water reflects sky / in-scatters (higher = caves & covered water stay dark)
#define WATER_CLOUD_REFLECTIONS // reflect the volumetric cloud deck in water (low step count, composited over the sky reflection on an SSR miss; rides the global TAA resolve so it reads clean)
#define WATER_CLOUD_REFLECTION_STEPS 8 // [4 6 8 12 16 24] primary raymarch steps for the water cloud reflection (low = cheap; the reflection is Fresnel-dimmed + TAA-filtered, so few steps suffice)

#define WATER_ROUGHNESS 0.02 // [0.0 0.005 0.01 0.02 0.04 0.08 0.16] surface roughness for reflections (higher = blurrier/more diffuse reflections, lower = sharper/mirror-like reflections)

#define WATER_FOG
//#define WATER_GODRAYS
#define WATER_GODRAY_STEPS 3     // [4 6 8 10 12 16 20 24] dithered shadow-marched steps from camera to fragment
#define WATER_GODRAY_STRENGTH 1.5 // [0.0 0.2 0.4 0.6 0.8 1.0 1.5 2.0 3.0 4.0] overall sun-shaft intensity
#define WATER_GODRAY_PHASE_G 0.7  // [0.0 0.3 0.5 0.7 0.8 0.9] Henyey-Greenstein asymmetry (forward-peak strength)

#define WATER_CAUSTICS
#define WATER_CAUSTICS_STRENGTH 2.0 // [0.0 0.2 0.4 0.6 0.8 1.0 1.2 1.6 2.0 2.5 3.0] brightness of caustic bands on submerged terrain
#define WATER_CAUSTICS_SCALE 1.0    // [0.30 0.50 0.70 1.00 1.40 1.80 2.40 3.20] >1 = denser pattern (smaller bands); 1 = matches the visible wave field
#define WATER_CAUSTICS_DEPTH_MAX 12.0 // [4.0 6.0 8.0 10.0 12.0 16.0 24.0 32.0] no caustics on terrain deeper than this below the water surface

// higher = water clears faster to scatter tint.
#define WATER_ABSORPTION_R 0.45 // [0.10 0.20 0.30 0.45 0.60 0.80 1.00]
#define WATER_ABSORPTION_G 0.13 // [0.05 0.08 0.13 0.18 0.25 0.35]
#define WATER_ABSORPTION_B 0.08 // [0.03 0.05 0.08 0.12 0.18 0.25]
#define WATER_SCATTER_R 0.015 // [0.0 0.005 0.010 0.015 0.025 0.04 0.06]
#define WATER_SCATTER_G 0.045 // [0.0 0.02 0.03 0.045 0.06 0.09 0.12]
#define WATER_SCATTER_B 0.060 // [0.0 0.03 0.045 0.060 0.08 0.11 0.15]

//#define INTEGRATED_PBR        // write per-block-ID material to colortex7
#define SPECULAR_REFLECTIONS  // opaque reflection pass. Its screen-space implementation (d7b/d7c) was removed in Phase 1; Phase 3.4 rebuilds it on the Lumen tracing stack.

#define METAL_SMOOTHNESS 0.9          // [0.40 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90] center smoothness of metals
#define METAL_ROUGHNESS_VARIATION 1.0 // [0.0 0.1 0.2 0.3 0.4 0.45 0.5 0.6 0.7 0.8] how much per-texel roughness varies with the texture's brightness (0 = uniform, high = bright spots mirror / dark spots rough)
#define PBR_GEN_NORMALS                // generate bump normals for PBR blocks from the texture
#define PBR_NORMAL_STRENGTH 0.6        // [0.1 0.2 0.3 0.4 0.5 0.6 0.8 1.0 1.5 2.0] bump strength (higher = more relief / wavier reflections)
#define PBR_DIELECTRIC_NORMAL 2.0      // [1.0 1.25 1.5 1.75 2.0 2.5 3.0 4.0] extra bump-normal strength for NON-metals (stone/wood/etc.), on top of PBR_NORMAL_STRENGTH

#define REFLECTION_SKY_FADE 12.0   // [4.0 6.0 8.0 10.0 12.0 16.0 20.0] skylight power for the sky-reflection gate (higher = indoor blocks stop reflecting sky)
#define REFLECTION_SKY_STRENGTH 0.5 // [0.0 0.2 0.3 0.4 0.5 0.6 0.7 0.8 1.0] brightness of the environment SKY reflection on PBR blocks (lower = less flat sky wash; SSR scene hits + sun glint unaffected)
#define SPECULAR_SUN 1              // [0 1] direct GGX sun/moon specular highlight (glint) on PBR blocks
#define SPECULAR_SUN_STRENGTH 1.0   // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] brightness of the sun/moon glint
#define PBR_DIELECTRIC_REFLECT 0.1 // [0.0 0.05 0.1 0.15 0.2 0.3 0.4 0.6 0.8 1.0] non-metal SKY reflection strength only (scene reflection is F0-driven per class)
#define PBR_DIELECTRIC_SUN 1.0      // [1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0 8.0] non-metal SUN/MOON glint boost. Higher = stronger sun highlight on non-metals

// --- Traced reflections (Phase 3.4) -----------------------------------------
// Rays are GGX-VNDF importance sampled, traced through the same voxel cascades
// the diffuse gather uses, and resolved through the same surface cache. No
// screen-space march: reflections show the whole world, including what is behind
// the camera, off the edge of the frame, or hidden from the camera's own view --
// the three things the deleted screen-space pass (d7b/d7c) could never show.
//
// REQUIRES INTEGRATED_PBR. The material buffer these read (colortex7) is only
// written by gbuffers_terrain under that define; with it off, colortex7 clears
// to zero, every pixel takes the early-out, and this stack costs one texture
// fetch per pixel and draws nothing.
//
// What it cannot do: the surface cache stores DIFFUSE outgoing radiance, so a
// reflection cannot contain a reflection. A mirror facing a mirror resolves to
// the diffuse colour of the second mirror's blocks. Lumen has the same property
// for the same reason.

// Rays per pixel. Low is fine -- the temporal accumulation in dr0 and the
// history-driven spatial blur in dr1 are what actually resolve the estimate,
// and each ray is a DDA walk plus one texel fetch with no shading at the hit.
#define REFLECTION_RAYS 1 // [1 2 3 4 6 8]

// How far a reflection ray travels before giving up and taking the far field.
// Longer than the diffuse gather on purpose: a reflection is a near-delta lobe,
// so its ray genuinely points at one place and truncating it is visible, whereas
// a diffuse ray is one of many being averaged.
#define REFLECTION_DIST 96 // [32 48 64 96 128 192 256] blocks

// Cone-step promotion distance, SCALED BY ROUGHNESS. A near-mirror gets ~0 and
// keeps cascade-0 detail the whole way out, because a promoted ray visibly
// coarsens a sharp reflection; a rough surface integrates over a wide lobe and
// cannot resolve what promotion discards, so it gets the full value and the
// speed that comes with it.
#define REFLECTION_CONE_BASE 32.0 // [8.0 16.0 32.0 64.0 128.0] blocks at roughness 1

// Smoothness below which a pixel is not worth reflecting. Doubles as the
// performance cutoff: raise it to skip the matte families (dirt, wood, wool,
// rough stone) while keeping metals and polished blocks.
#define REFLECTION_SMOOTHNESS_MIN 0.25 // [0.0 0.15 0.25 0.35 0.5 0.65 0.8]

// Reflection denoise: demodulate -> temporally accumulate -> blur spatially ->
// re-modulate with a sharp per-texel Fresnel. Off composites the raw per-frame
// rays, which is only useful for A/B-ing the tracer against its filter.
#define REFLECTION_DENOISE
#define REFLECTION_ACCUM_FRAMES 24 // [4 8 12 16 24 32 48] max frames blended
#define REFLECTION_SPATIAL_RADIUS 12.0 // [0.0 4.0 8.0 12.0 16.0 24.0 32.0] max blur radius in pixels, at zero history
// Skip a spatial tap whose luma exceeds the centre's by this factor, so an
// emissive spike cannot smear into a streak. 0 disables the test entirely.
#define REFLECTION_SPATIAL_FIREFLY 4.0 // [0.0 2.0 3.0 4.0 6.0 10.0]

// Per-ray clamps. The hard ceiling catches pathological HDR values before they
// enter the mean; the Karis weight suppresses a lone bright ray only where rays
// diverge, so a legitimately bright reflection on a smooth surface is untouched.
#define REFLECTION_FIREFLY_CLAMP 8.0 // [1.0 2.0 4.0 8.0 16.0 32.0 1000.0]
#define REFLECTION_FIREFLY_WEIGHT 1.0 // [0.0 0.5 1.0 2.0 4.0]

// How much a reflection dims in shadow / low sky access, driven by the same
// filtered sun visibility d7 writes to colortex6. 0 = reflections ignore shadow
// (shiny caves), 1 = fully dark in shadow.
#define PBR_REFLECT_SHADE 0.5 // [0.0 0.2 0.35 0.5 0.65 0.8 1.0]

#define VOXEL_GI

// --- Cascaded voxel grid -----------------------------------------------------
// Four cascades share one stacked 3D image, each covering twice the world of the
// one before at half the resolution (1/2/4/8 blocks per voxel). Total reach is
// VOXEL_CASCADE_SIZE * 8 blocks for the same memory a single uniform grid of
// VOXEL_CASCADE_SIZE * 2 would have cost. See lib/pt/voxelCascade.glsl.
//
//   size   cascade 0 reach   total reach   voxel memory   surface cache
//    128       128 blocks     1024 blocks     33 MB          100 MB
//    256       256            2048           134 MB          402 MB   (default)
//
// MUST be a power of two. The surface cache indexes itself by world voxel
// coordinate wrapped with a bitmask (see lib/pt/surfaceCache.glsl); 192 has no
// mask, so the old 192 default is gone. 256 is the recommended size -- it keeps
// cascade 0, the only cascade the surface cache covers, a full 256 blocks wide.
#define VOXEL_CASCADE_SIZE 256 // [128 256] voxels per axis in EACH cascade

// How far the shadow pass rasterises geometry, which is what actually fills the
// grid. Cascades beyond this radius stay empty until chunks load, so raising it
// extends usable GI range at real rasterisation cost. Coarse cascades only need
// occupancy, but Minecraft has no cheaper source for it without Distant Horizons.
#define VOXEL_SHADOW_DISTANCE 384.0 // [128.0 192.0 256.0 384.0 512.0 768.0] shadow/voxelization radius (blocks)

// Entities are excluded from the voxel grid (they move every frame), so they are
// invisible to the path tracer unless their bounds are captured separately. With
// this on, the shadow pass records a per-entity AABB and shadowcomp builds a small
// BVH over them, letting mobs, players and items cast path-traced shadows.
// Shadows are box-shaped: an entity's silhouette is not resolved.
#define ENTITY_SHADOWS
// The maximum number of individual 1-block steps a ray may take inside ONE
// cascade before giving up. Lowering it improves framerates in dense areas like
// forests.
//
// This is a SAFE knob now. A ray that exhausted the budget used to jump to the
// far side of the cascade and carry on, silently skipping everything in between
// and reporting that it had escaped to open sky -- so lowering this leaked light
// rather than merely costing reach. A starved ray now stops where it is and
// reports an unknown far field, which every caller already gates by sky access.
//
// For reference a ray takes up to ~1.73 steps per block, so covering
// GI_GATHER_DIST 48 needs ~83 steps.
#define GI_MAX_STEPS 96 // [64 96 128 192 256 384] steps per cascade before a ray gives up

// --- Cone stepping (Phase 3.2) ----------------------------------------------
// Promote a ray to a coarser cascade by how far it has TRAVELLED, not only by
// which box it has left. This is the voxel analogue of Lumen's software tracer
// widening its cone with distance and sampling coarser SDF mips, and it is the
// single largest ray-cost win available here.
//
// A 48-block gather ray used to walk cascade 0 at one block per step for its
// whole length -- up to 83 steps. Promoting at GI_CONE_BASE and again at double
// that puts most of the ray on 2- and 4-block voxels: roughly 32 steps for the
// same reach.
//
// This was BLOCKED before SC_CASCADES existed. A promoted ray resolves its hit
// against the coarser cascade's surface cache, and with the cache covering only
// cascade 0 every one of those lookups came back black. Turning this on with
// SC_CASCADES 1 will visibly darken everything past GI_CONE_BASE.
//
// The trade is occlusion detail at range: past GI_CONE_BASE a ray sees 2-block
// voxels, so a one-block gap stops letting light through. That over-occludes
// slightly, which is the safe direction and is already how the coarse cascades
// behave for anything that reaches them.
#define GI_CONE_STEP
#define GI_CONE_BASE 16.0 // [8.0 12.0 16.0 24.0 32.0 48.0 64.0] blocks before the first promotion
// Scales the PATH-TRACED GI and nothing else. Applied by the producer
// (dg0_gather) before the buffer ever reaches d7_composite.
//
// This is now the ONLY control over traced GI brightness. LIGHTING_INDIRECT used
// to attenuate the traced buffer as well, which is why this needed absurd
// out-of-range values to compensate; with that decoupled, 100 means "the
// tracer's own answer, unscaled" and the slider range is meaningful again.
//
// Note it also scales shadeDhTerrain's raster ambient, deliberately, so Distant
// Horizons LOD tracks the near field's brightness. LIGHTING_INDIRECT trims that
// DH fill independently.
#define GI_STRENGTH 150 // [25 50 75 100 150 200]
#define GI_SKY_BRIGHTNESS 0.2 // [0.1 0.2 0.3 0.4 0.5 0.6 0.75 1.0 2.0 3.0 4.0 6.0 8.0] strength of the path-traced SKYLIGHT (sky-miss) ambient ONLY. Does NOT scale colored sun-bounce or block emission, so LOWER this to prioritize colored GI over the flat skylight wash; raise it for a brighter open-sky ambient.
#define GI_SKY_WARMTH 0.30 // [0.0 0.05 0.10 0.15 0.20 0.25 0.30 0.40 0.50 0.65 0.80 1.00] warms the path-traced SKYLIGHT illumination on terrain (more golden, less blue) WITHOUT tinting the rendered sky/clouds/fog. 0 = raw sky color.
#define GI_EMISSION 0.1   // [0.1 0.25 0.5 0.75 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0] emissive block glow strength
// Write the 10-bit model-derived shape id into the voxel word. Leave this ON.
// Its #else branch in gbuffers/shadow.glsl maps shaped blocks to VOXEL_AIR,
// which deletes every stair, slab, fence and wall from the grid rather than
// cubing them. The bits already exist in the word, so writing the id is free.
#define VOXEL_SHAPES

// Sub-block intersection: trace rays against the generated block BLAS (761
// shapes / 3080 boxes) instead of treating each occupied voxel as a full cube.
// OFF for the Lumen bring-up -- everything traces as a unit cube. The table and
// the traversal code stay in the tree and the setup pass still uploads the SSBO
// (24 KB, once at load), so re-enabling is exactly this one line. Emitter
// silhouettes (lib/pt/lightShapes.glsl) are independent of this and stay live,
// which is why a torch still reads as a stick rather than a solid block.
//#define VOXEL_BLAS

#define SPECIAL_BLOCKLIGHT // master toggle for the per-texel self-emission path (d7_composite)
#define EMISSIVE_THRESHOLD_LO 0.42 // [0.20 0.28 0.35 0.42 0.50 0.58 0.66] albedo value below which a texel is treated as non-emissive (the stick). Lower = more of the block glows.
#define EMISSIVE_THRESHOLD_HI 0.72 // [0.55 0.62 0.66 0.72 0.78 0.85 0.92] albedo value at/above which a texel is fully emissive (the flame). Raise to confine the glow to only the brightest texels.
#define EMISSIVE_BRIGHTNESS 6.0 // [1.0 2.0 3.0 4.0 6.0 8.0 12.0 16.0] HDR strength of the self-emission added to emissive texels. The texel's own albedo supplies the color.
#define VOXEL_EMISSIVE_SHAPES // gate the gi.glsl emissive sub-box logic; off = whole-voxel emission (legacy)

// --- Surface cache (Phase 3.1) -----------------------------------------------
// Persistent per-voxel-face outgoing radiance over cascade 0. Rays look their
// hit radiance up here instead of shading it, which is what decouples lighting
// cost from ray count. See lib/pt/surfaceCache.glsl for the toroidal addressing
// that lets it survive camera motion.
#define SURFACE_CACHE

// How many cascades of the clipmap the surface cache covers (Phase 3.2).
//
//   1  cascade 0 only -- 256 blocks of lit radiance, 402 MB. Anything a ray hits
//      beyond that resolves to BLACK, because the slot it addresses belongs to a
//      different world voxel and the tag correctly rejects it. This was the
//      pre-3.2 behaviour and it is what made distant geometry unlit rather than
//      merely approximate.
//   2  cascades 0-1 -- 512 blocks, 804 MB. Also what makes GI_CONE_STEP sound:
//      a ray may only be promoted to a coarser cascade if there is radiance
//      stored there for it to resolve against.
//
// Capped at 2 by hardware, not by taste: the image is 128 * 6 * SC_CASCADES
// texels tall, so three cascades at VOXEL_CASCADE_SIZE 256 would need 2304 and
// GL_MAX_3D_TEXTURE_SIZE is 2048 on a good deal of hardware.
//
// MUST stay in sync with the faceRadianceImg / scRequestImg heights in
// shaders.properties.
#define SC_CASCADES 2 // [1 2] cascades of lit radiance

// Refresh period for the FAR field, in frames. Voxels closer than SC_NEAR_DIST
// refresh every frame regardless; the two bands between there and SC_FAR_DIST
// interpolate (period/4, period/2). Higher = cheaper, at the cost of distant
// geometry lagging further behind a lighting change.
//
// This used to be a flat stride over Z slabs, which spent as much work on the
// far corner of the cascade as on the block underfoot and relit the world in
// visible planar sweeps. Distance-banding is Lumen's per-frame card-capture
// budget in miniature: prioritise by what the camera can actually resolve.
#define SC_UPDATE_STRIDE 8 // [1 2 4 8 16] far-field frames per refresh

// Distance bands for the above, in blocks. Inside NEAR every voxel refreshes
// every frame; past FAR everything runs at the full SC_UPDATE_STRIDE period.
// SC_NEAR_DIST also sets the always-warm radius for the feedback gate below,
// so it is what covers a fast camera turn without a visible warm-up.
#define SC_NEAR_DIST 32 // [16 24 32 48 64 96] always-refresh radius
#define SC_MID_DIST  64 // [32 48 64 96 128]   quarter-period radius
#define SC_FAR_DIST  96 // [48 64 96 128 192]  half-period radius

// --- Update feedback ---------------------------------------------------------
// Only refresh the parts of the cache something has actually looked at. Every
// gather ray stamps the 8^3 brick it resolved through into a 16 KB request
// volume, and the update pass skips any brick outside SC_NEAR_DIST that carries
// no recent stamp. This is Lumen's LumenSurfaceCacheFeedback: rays report which
// card pages they hit and only those get captured.
//
// Turning this OFF falls back to refreshing everything occupied, which is
// correct but pays for the whole cascade rather than the visible part of it.
// Worth switching off to isolate a suspected staleness bug.
#define SURFACE_CACHE_FEEDBACK

// How many frames a stamp keeps a brick eligible. MUST be >= SC_UPDATE_STRIDE,
// or a brick can be stamped, have its scheduled phase fall outside the window,
// and never refresh at all. Larger values keep more of the cache warm behind
// you, which costs work but softens fast camera turns.
#define SC_REQUEST_TTL 16 // [4 8 16 32 64 128] frames a request stays live

// Faces refreshed per voxel per frame, as one in every N of the six. A face's
// lighting changes slowly and SC_BLEND is a much longer time constant than this,
// so 2 is close to free; 3 is still hard to catch. Slots with no valid history
// ignore this and fill immediately, so it never leaves visible holes.
#define SC_FACE_STRIDE 2 // [1 2 3 6] one face in every N per frame

// How much of a block's sky access a DOWNWARD-facing face receives -- ceilings
// and the undersides of overhangs. 0 makes them fully blind to the sky (the old
// probe's behaviour), which is too dark for an outdoor overhang; a little bounce
// is more truthful. Upward faces always get the full amount.
#define SC_SKY_DOWN_FACE 0.15 // [0.0 0.05 0.1 0.15 0.25 0.4 0.6]

// Safety cap on the update pass's grid-stride loop. With a dispatch of the
// requested size this is one iteration and the cap is inert; it exists so that a
// dispatch far smaller than requested degrades into partial coverage instead of
// one invocation walking millions of voxels and hanging the GPU.
#define SC_MAX_ITERS 64 // [1 4 16 64 256 1024]

// Extra gain on VOXEL_EMISSIVE blocks (lava, magma) when injected into the
// cache. VOXEL_LIGHT emitters take their colour from the blocklight palette and
// are already calibrated, so this does not apply to them.
#define SC_EMISSIVE_BOOST 2.0 // [0.5 1.0 1.5 2.0 3.0 4.0 6.0]

// Bounce rays cast per voxel face per refresh. Each one resolves its hit through
// the cache rather than shading it, so this buys angular accuracy, NOT bounce
// count -- bounces come free from the feedback loop, one more per refresh.
#define SC_BOUNCE_RAYS 2 // [1 2 3 4 6 8]

// How far a bounce ray travels before giving up and taking the sky. Short is
// fine: anything past this is the far field, which the world radiance cache
// covers rather than the surface cache.
#define SC_BOUNCE_DIST 32 // [8 16 24 32 48 64 96]

// (SC_SKY_PROBE_DIST is gone. Per-face sky visibility used to be an occlusion
// ray of that length cast six times per voxel per refresh -- the longest and
// most numerous ray in the renderer. It now comes from the vanilla skylight
// lightmap, which the voxeliser banks into three previously spare bits of the
// voxel word. See lib/pt/voxelFormat.glsl. Shape it with SC_SKY_DOWN_FACE and
// GI_SKY_LEAK_FALLOFF.)

// Temporal blend weight for a cache slot: how much of each refresh is the new
// estimate. Low values denoise a sparse ray budget hard but make relighting lag;
// note a slot only refreshes every SC_UPDATE_STRIDE frames at distance (every
// frame within SC_NEAR_DIST), and only one face in SC_FACE_STRIDE per turn, so
// the effective far-field time constant is
// SC_UPDATE_STRIDE * SC_FACE_STRIDE / SC_BLEND frames.
#define SC_BLEND 0.25 // [0.05 0.1 0.15 0.25 0.4 0.6 1.0]

// --- World radiance cache (Phase 3.2) ----------------------------------------
// A sparse volume of irradiance probes that answers "what does the far field
// look like from here" -- the question a ray that ran out of range is actually
// asking, and one the surface cache structurally cannot answer because such a
// ray has no hit point to look up.
//
// It replaces two placeholders:
//   - gather and surface-cache-bounce rays that exhaust their distance used to
//     receive flat sky scaled by the surface's skylight, which is why a large
//     room lit through a doorway read as a uniform blue wash instead of as light
//     coming from the doorway;
//   - shadeDhTerrain had no traced answer at all and used a hardcoded
//     ambientColor * GI_SKY_BRIGHTNESS constant.
//
// 32 x 16 x 32 = 16384 probes of L1 spherical harmonics, four RGBA16F texels
// each: 512 KB total, and a few thousand rays a frame. It is by an order of
// magnitude the cheapest pass in the tracing stack.
//
// Turn it off to fall back to the flat-sky and hardcoded-ambient behaviour.
#define RADIANCE_CACHE

// Probe spacing in blocks. The probe COUNT is fixed, so this is purely a
// range-vs-resolution trade: 16 covers 512 x 256 x 512 blocks around the camera,
// which comfortably contains the gather's reach and the near Distant Horizons
// ring. Raising it reaches further into the DH field at the cost of interpolating
// far-field light across larger rooms.
#define RC_SPACING 16 // [8 12 16 24 32] blocks between probes

// Rays per probe per refresh, uniform over the sphere (a probe has no normal, so
// nothing privileges a hemisphere). This buys angular accuracy in the L1 fit,
// not bounce count -- bounces come from resolving each hit through the surface
// cache, which already contains them.
#define RC_RAYS 16 // [4 8 16 24 32 48 64]

// How far a probe ray travels. Long on purpose: a ray that crosses this much
// Minecraft geometry without hitting anything is outdoors essentially by
// definition, which is what lets sc3 treat every miss as sky without the
// cave-flooding that the same assumption would cause in the 48-block gather.
#define RC_RAY_DIST 128 // [64 96 128 192 256 384] blocks

// Probe rays cone-step hard from the first metre: this volume stores far-field
// light at 16-block spacing, so cascade-0 detail along its rays is precision
// nothing downstream could resolve.
#define RC_CONE_BASE 8.0 // [4.0 8.0 16.0 32.0 0.0] blocks before promotion; 0 = off

// Frames between refreshes for a probe that already holds a valid estimate.
// Probes with NO history ignore this and trace immediately, so a newly exposed
// shell of the volume never reads as "no coverage".
#define RC_UPDATE_STRIDE 4 // [1 2 4 8 16] frames per probe refresh

// Temporal blend weight per refresh. RC_RAYS is far too few to use raw, so the
// volume is its own accumulator, exactly as the surface cache is.
#define RC_BLEND 0.15 // [0.05 0.1 0.15 0.25 0.4 0.6 1.0]

// --- Lumen GI ----------------------------------------------------------------
// The ReSTIR reservoirs, the SVGF a-trous denoiser, GTAO and the voxel-AO path
// are gone (Phase 1). What remains here are the options that surviving code
// still reads; Phase 3 adds the surface-cache / radiance-cache / screen-probe
// knobs as those passes land.

// --- Final gather (Phase 3.3) ------------------------------------------------
// Per-pixel cosine rays that resolve through the surface cache rather than
// shading their hit. Cheap enough to do per pixel precisely because there is no
// shading at the hit: a DDA walk plus one texel fetch.
#define GI_GATHER_RAYS 2  // [1 2 3 4 6 8 12 16] rays per pixel per frame

// Adaptive ray budget. GI_GATHER_RAYS is what a pixel with NO temporal history
// gets; a pixel whose history has reached GI_ADAPTIVE_FRAMES drops to a single
// ray, interpolating in between. A converged pixel is already averaging dozens
// of frames and gains almost nothing from more rays this frame, so the full
// budget is paid only where it buys something: disocclusions, silhouettes and
// moving geometry.
//
// This exists to make a higher GI_GATHER_RAYS affordable. Lower values ramp down
// sooner (cheaper, but noisier just after a disocclusion); at GI_GATHER_RAYS 1
// the whole mechanism compiles out and the loop bound stays constant.
#define GI_ADAPTIVE_FRAMES 8 // [2 4 6 8 12 16 24 32] history length at which the budget bottoms out

// Let fully converged, near-static pixels skip the gather entirely on most
// frames. At GI_ACCUM_FRAMES a pixel blends each new estimate at alpha = 1/33,
// so it is already 97% resampled history and re-tracing it barely moves it.
//
// Only pixels that are BOTH fully converged and nearly stationary qualify, so
// disocclusions, newly visible surfaces and anything on moving geometry always
// trace at full rate. Which pixels skip is hashed per pixel, so the skipped set
// is scattered rather than a pattern that could read as structure.
//
// This is where the gather's remaining cost goes in a mostly-static view. Turn
// it off if GI is visibly slow to respond to a light changing while standing
// still -- that is the one thing it trades away.
#define GI_CONVERGED_SKIP
#define GI_SKIP_PERIOD 3 // [2 3 4 6 8] a qualifying pixel traces 1 frame in N
#define GI_SKIP_MOTION 1.5 // [0.5 1.0 1.5 3.0 8.0] max screen motion in pixels to still qualify

// Answer diffuse ray misses from a per-frame spherical-harmonic projection of
// the sky instead of sampling the atmosphere LUT per ray.
//
// sampleSky_fast costs four texelFetches into the 256x256 LUT plus a handful of
// transcendentals, and it runs PER MISSED RAY in both the final gather and the
// surface cache's bounce loop -- the common case in open terrain. Nine
// coefficients replace that with ~20 FMAs and no memory traffic, and because SH
// is smooth it also lowers the variance the temporal filter has to remove.
//
// The trade: second-order SH cannot hold a sharp edge, and the sky has one at
// the horizon. Measured against a worst-case hard step, the cosine-weighted
// error is +0.0% on floors, -0.7% on walls and +4.3% on ceilings, with no shift
// in overall brightness -- so in practice only ceilings change, picking up
// slightly more bounce. Turn this off to A/B against the exact LUT path.
#define GI_SKY_SH
#define GI_GATHER_DIST 48 // [16 24 32 48 64 96 128] ray reach in blocks

// How sharply the sky term falls off with the surface's skylight lightmap.
// THIS IS THE CAVE-LEAK CONTROL. A ray that dies on GI_GATHER_DIST without
// leaving the grid knows nothing about the far field, so it receives sky scaled
// by pow(skylight, this) instead of the full sky it used to get. 1.0 is linear;
// raise it to darken tunnels and cave mouths further, lower it if shaded outdoor
// spots (under trees, north-facing walls) lose too much ambient.
// --- GI denoiser (a-trous) ---------------------------------------------------
// A short edge-stopping stride ladder over the GI buffer, ReLAX-flavoured.
//
// Deliberately much smaller than the SVGF chain Phase 1 deleted. That one had to
// rescue a 1-spp ReSTIR signal and needed five passes plus per-pixel variance and
// moment accumulation. Here the surface cache is already converged before the
// gather runs, so what arrives is a mild residual -- a couple of rays of sampling
// noise plus the contact-AO term, both already through 32 frames of temporal
// accumulation. Every pass skipped is a full-res RGBA16F read AND write saved.
//
//   0 off       d7 reads the raw accumulation                  (0 passes)
//   1 low       strides 1,2      -> 7x7 effective footprint    (2 passes)
//   2 balanced  strides 1,2,4    -> 15x15                      (3 passes)
//   3 quality   strides 1,2,4,8  -> 31x31                      (4 passes)
//
// 3x3 taps per pass (9), not SVGF's 5x5 (25). Four passes reach a 31x31 footprint
// for 36 taps, where one 31x31 gather would be 961.
#define GI_DENOISE_QUALITY 3 // [0 1 2 3] off / low / balanced / quality

// Edge-stopping tolerances. Raise to blur across more of an edge, lower to
// preserve more detail at the cost of leaving noise.
#define GI_DN_SIGMA_N 64.0  // [8.0 16.0 32.0 64.0 128.0 256.0] normal falloff exponent; HIGHER = stricter
#define GI_DN_SIGMA_Z 0.02  // [0.005 0.01 0.02 0.04 0.08 0.15] depth tolerance, fraction of view distance
#define GI_DN_SIGMA_L 0.35  // [0.1 0.2 0.35 0.5 0.8 1.5] luma tolerance; widened automatically where history is short

// --- Contact ambient occlusion ----------------------------------------------
// THIS IS THE FLAT-SHADING CONTROL.
//
// Ray occlusion by itself barely darkens anything in daylight. A gather ray that
// hits a nearby block resolves it through the surface cache, which stores
// direct + albedo*indirect -- so a SUNLIT occluder hands back roughly what the
// sky would have. The geometry blocks the ray without lowering what the ray
// returns, so corners, creases and block seams come back nearly as bright as
// open ground and shaded areas read as a flat wash.
//
// Lumen hits the same wall and answers it the same way: a separate Short-Range
// AO applied on top of the screen-probe gather, because traced GI at probe
// density cannot resolve contact-scale occlusion. This pack lost its equivalent
// when GTAO was deleted in Phase 1 and nothing took its place.
//
// Costs no extra rays -- it reuses the hit distance the gather already has.
#define GI_CONTACT_AO
#define GI_AO_RADIUS 4.0 // [1.0 2.0 3.0 4.0 6.0 8.0 12.0] blocks; hits nearer than this darken, further ones do not
#define GI_AO_STRENGTH 2.0 // [0.0 0.25 0.4 0.55 0.7 0.85 1.0] 0 = off, 1 = fully dark in a sealed corner

#define GI_SKY_LEAK_FALLOFF 2.0 // [1.0 1.5 2.0 3.0 4.0 6.0]

// Isolate one stage of the GI pipeline. 0 = off (normal render).
//   1 = the indirect buffer, no albedo -- is the gather producing anything?
//   2 = temporal history length (blue = fresh, red = converged)
//   3 = the surface cache down the primary ray -- is the CACHE populated?
//   4 = same as 3 but IGNORING the validity tag
//   5 = cache coverage: green = tag valid, red = tag rejected, black = ray miss
//   6 = tag actually STORED in the slot (grey ramp; pure black = never written)
//   7 = tag the reader EXPECTS (same ramp) -- compare with 6
//   8 = feedback coverage: green = brick stamped recently and being refreshed,
//       red = frozen, blue = SURFACE_CACHE_FEEDBACK compiled out
//   9 = world radiance cache at the primary ray's hit (Phase 3.2). Black = the
//       probe volume does not cover that point; magenta = RADIANCE_CACHE is off
//  10 = which surface-cache cascade resolves the primary ray: green = 0,
//       blue = 1, RED = no coverage (at SC_CASCADES 1 everything past 256
//       blocks reads red, and every hit out there is resolving to black)
// If 3 is lit but 1 is black, the gather is at fault. If 3 is black, the surface
// cache update (sc1_surface_direct) is -- then compare 4 and 5: lit in 4 but
// black in 3 means the tag is wrongly rejecting entries; black in both means
// those slots are simply never written (a dispatch-coverage problem).
#define GI_DEBUG_VIEW 0 // [0 1 2 3 4 5 6 7 8 9 10]

// Temporal accumulation. The surface cache is already converged, so this is a
// light denoise rather than the old SVGF-scale machinery.
#define GI_ACCUM_FRAMES 16 // [8 16 24 32 48 64 128] max frames blended
#define GI_REJECT_DEPTH 0.1 // [0.02 0.05 0.1 0.15 0.25] relative depth jump that counts as disocclusion
#define GI_REJECT_NORMAL 0.85 // [0.5 0.7 0.8 0.85 0.92 0.97] min dot(prevNormal, normal) to reuse history

// Blue-noise ray directions. Formerly RESTIR_BLUE_NOISE -- the name outlived
// ReSTIR because the STBN texture is still how every hemisphere ray is drawn.
// Cosine hemisphere, noise/stbn_cosine.dat via customTexture.blueNoise; much
// less low-spp boiling than white-noise PCG. Comment out for white noise.
// Consumed by stbnCosineHemisphere (lib/pt/sampling.glsl).
#define GI_BLUE_NOISE

// Minimum relative-luminance variance floor, boosted in the dark. Formerly
// SVGF_MIN_LUMA_SIGMA. Consumed by svgfVarianceFloor (lib/pt/reproject.glsl).
#define GI_MIN_LUMA_SIGMA 0.08 // [0.0 0.02 0.035 0.05 0.08 0.12 0.16] higher removes more residual/checker noise; lower keeps crisper fine bounce detail.

// Source firefly clamp: max luminance a single GI sample may contribute,
// rescaled to keep chroma. A lone ray catching the bright sky through a gap
// returns a spike no screen-space filter can tell from signal, and bloom then
// smears it into a glowing blob. Formerly GID_FIREFLY_MAX. Currently read only
// by the Distant Horizons raster-ambient fallback in d7_composite, which Phase
// 3.2 replaces with a far-field radiance-cache probe lookup.
#define GI_FIREFLY_MAX 0.5 // [1.0 2.0 3.0 4.0 6.0 8.0 12.0 20.0 1000.0] 1000 = off

// --- Disocclusion fill (history reconstruction) ------------------------------
// Pixels that never build temporal history -- silhouette edges, convex corners,
// disocclusions -- would otherwise display raw low-spp radiance as edge
// fireflies. historyFixGI (lib/pt/reproject.glsl) pools accumulated GI from
// geometrically-similar, higher-history neighbours (Karis-weighted to damp
// outliers) and blends it in by (1 - history). Converged pixels pass through
// untouched. Survives the denoiser wipe: screen probes converge, but a freshly
// disoccluded pixel still has no history to converge from.
#define HISTORYFIX_MIN_FRAMES 1   // [1 2 4] history length at/below which the fix is full strength
#define HISTORYFIX_MAX_FRAMES 12  // [4 6 8 12 16 24] history length at/above which no fix is applied (detail preserved)
#define HISTORYFIX_SAMPLES 16     // [8 12 16] pooled taps (Vogel disk)
#define HISTORYFIX_RADIUS 32.0    // [8.0 16.0 24.0 32.0 48.0] max pooling radius in pixels (scaled by 1-history)
#define HISTORYFIX_SIGMA_N 8.0    // [2.0 4.0 8.0 16.0 32.0] normal edge-stopping for taps (higher = tighter to surface)
#define HISTORYFIX_DEPTH_TOL 0.1  // [0.03 0.05 0.1 0.2 0.5] relative depth tolerance for taps

//#define PT_DEBUG_VOXELS  // voxel debug view

#define WATER_DEBUG 0 // [0 1 2]

#include "/lib/pipelineSettings.glsl"
#include "/lib/uniforms.glsl"

#endif
// --- Utility Macros ---
#ifndef PI
#define PI 3.14159265359
#endif

#ifndef clamp01
#define clamp01(x) clamp(x, 0.0, 1.0)
#endif
