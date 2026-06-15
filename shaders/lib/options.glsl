#ifndef OPTIONS_GLSL
#define OPTIONS_GLSL

#define RENDER_SCALE 0.67 // [0.33 0.5 0.59 0.67 0.77 1.0] ultra performance, performance, balanced, quality, ultra quality, native
const float renderScale = RENDER_SCALE;

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

//#define VOLUMETRIC_LIGHT
#define VL_STEPS 3 // [2 3 4 6 8 12 16 20 24 32 48] dithered raymarch steps for atmospheric god rays (3 looks fine with TAA)
#define VL_INTENSITY 5.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0] brightness of the in-scattered sun term
#define VL_NOON_STRENGTH 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at noon.
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

#define SUN_ILLUMINANCE 10.0  // [1.0 2.5 5.0 7.5 10.0 12.5 15.0 20.0] Sun light intensity multiplier for atmospheric scattering
#define MOON_ILLUMINANCE 0.02 // [0.005 0.01 0.02 0.04 0.06 0.08 0.10] Moon light intensity multiplier for atmospheric scattering
#define MIE_G 0.80            // [0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95] Mie phase function asymmetry factor (controls sun glow size/sharpness)

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

#define CLOUDS
#define CLOUDS_COVERAGE 0.80          // [0.20 0.30 0.40 0.45 0.50 0.55 0.60 0.65 0.70 75 0.80 0.90] global cumulus coverage (0 = clear sky, 1 = overcast)
#define CLOUDS_ALTITUDE_MULTIPLIER 0.75 // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00] Multiplier for how high in the air clouds render
#define CLOUDS_HEIGHT_MULTIPLIER 0.35 // [0.1 0.15 0.2 0.25 0.30 0.35 0.40 0.45 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95 1.0 1.05 1.10 1.15 1.20 1.25 1.30 1.50 1.75 2.00] Multiplier for the cloud layer's vertical thickness
#define CLOUDS_SIZE_MULTIPLIER 1.00    // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00 4.00 5.00] Size multiplier for both cloud base and detail shapes
#define CLOUDS_DENSITY 0.03           // [0.01 0.02 0.03 0.05 0.08 0.12 0.18 0.25] cloud extinction coefficient (higher = denser/darker interiors)
#define CLOUDS_LAYER_BOTTOM 1500.0    // [600.0 900.0 1200.0 1500.0 1800.0 2400.0 3000.0] cumulus base altitude (m above planet surface)
#define CLOUDS_LAYER_TOP    5400.0    // [2400.0 3000.0 3600.0 4500.0 5400.0 6400.0 7500.0] cumulus top altitude (m above planet surface)
#define CLOUDS_WIND_SPEED 12.0         // [0.0 1.0 2.0 4.0 6.0 9.0 12.0 18.0 25.0] m/s — cloud advection speed
#define CLOUDS_WIND_DIR_X 1.0         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction X
#define CLOUDS_WIND_DIR_Z 0.3         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction Z
//#define CLOUDS_SHADOW                
#define CLOUDS_SHADOW_STEPS 6         // [2 3 4 6 8 12]
#define CLOUDS_SHADOW_EXTENT 2048.0   // [512.0 1024.0 1536.0 2048.0 3072.0 4096.0]
#define CLOUDS_PRIMARY_STEPS 16       // [8 16 24 32 48 64 96]
#define CLOUDS_LIGHT_STEPS 4          // [2 3 4 6 8]
#define CLOUDS_MS_OCTAVES 6           // [1 2 3 4 6]
#define CLOUDS_MAX_DISTANCE 16000.0   // [4000.0 8000.0 12000.0 16000.0 24000.0 32000.0]
#define CLOUDS_MIN_TRANSMITTANCE 0.01 // [0.001 0.005 0.01 0.02 0.05] early-out when accumulated transmittance falls below this
#define CLOUDS_DEBUG 0

#define TAA
#define TAA_JITTER_SCALE 0.75 // [0.0 0.1 0.15 0.2 0.25 0.3 0.35 0.4 0.45 0.5 0.55 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0]
#define TAA_BLEND_WEIGHT 0.95 // [0.85 0.86 0.87 0.88 0.89 0.90 0.91 0.92 0.93 0.94 0.95 0.96 0.97 0.98 0.99]
#define TAA_SHARPNESS 0.6 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]

#define BLOOM
#define BLOOM_STRENGTH 0.15 // [0.01 0.03 0.06 0.08 0.10 0.12 0.15 0.18 0.22 0.26 0.30]

#define AUTO_EXPOSURE
#define EXPOSURE 0.80 // [0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 1.00 1.10 1.20 1.30 1.40 1.50 1.60 1.70 1.80 1.90 2.00 2.20 2.40 2.60 2.80 3.00]
#define AUTO_EXPOSURE_TARGET 0.22 // [0.10 0.12 0.14 0.16 0.18 0.20 0.22 0.24 0.26 0.28 0.30 0.35 0.40 0.45 0.50]
#define AUTO_EXPOSURE_SPEED 2.0 // [0.1 0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0]
#define AUTO_EXPOSURE_CENTER_WEIGHT 0.1 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
#define AUTO_EXPOSURE_MIN 0.001 // [0.01 0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.15 0.20]
#define AUTO_EXPOSURE_MAX 6.0 // [2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0 25.0 30.0]

#define TONEMAP_OPERATOR 0 // [0 1 2 3 4]
#define COLOR_CONTRAST 1.001 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_SATURATION 1.12 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_TEMP 0.0 // [-0.5 -0.4 -0.3 -0.2 -0.1 0.0 0.1 0.2 0.3 0.4 0.5]
//#define VIGNETTE

#define LIGHTING_DIRECT 110   // [50 75 100 110 125 150 200]
#define LIGHTING_INDIRECT 70  // [25 40 55 70 85 100 125 150]
#define PT_RASTER_AMBIENT_FLOOR 0 // [0 5 10 15 20 35 50] neutral indirect-light floor for path-traced GI. Fades out where real PT energy exists; does not inject sky or block lightmap color.
//#define LIGHTING_AO_FULL

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

#define WATER_ROUGHNESS 0.02 // [0.0 0.005 0.01 0.02 0.04 0.08 0.16] surface roughness for reflections (higher = blurrier/more diffuse reflections, lower = sharper/mirror-like reflections)

#define WATER_FOG
//#define WATER_GODRAYS
#define WATER_GODRAY_STEPS 2     // [4 6 8 10 12 16 20 24] dithered raymarch steps from camera to fragment
#define WATER_GODRAY_STRENGTH 20.0 // [0.0 0.1 0.2 0.4 0.6 0.8 1.0 1.5 2.0] overall scatter intensity
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

// ---------------------------------------------------------------------------
// PBR / specular reflections (opaque) — v2 rebuild, metals first.
// Material (metal albedo + smoothness) is written per-texel to colortex7 by the
// gbuffers (block IDs 21001). The d7b_reflections deferred pass does VNDF
// importance-sampled SSR that reflects the PREVIOUS frame (colortex5) reprojected,
// with a sky-view fallback.
// ---------------------------------------------------------------------------
#define INTEGRATED_PBR        // write per-block-ID material to colortex7
#define SPECULAR_REFLECTIONS  // opaque reflection pass (gates d7b_reflections)

// Per-texel roughness: metal smoothness is derived from each pixel's albedo
// lightness (using a `sqrt(linear_step)` response), so bright facets read
// near-mirror and dark / worn texels read rough — varying roughness WITHIN one
// block's texture. METAL_SMOOTHNESS is the center, _VARIATION the per-texel spread.
#define METAL_SMOOTHNESS 0.9          // [0.40 0.50 0.55 0.60 0.65 0.70 0.75 0.80 0.85 0.90] center smoothness of metals
#define METAL_ROUGHNESS_VARIATION 1.0 // [0.0 0.1 0.2 0.3 0.4 0.45 0.5 0.6 0.7 0.8] how much per-texel roughness varies with the texture's brightness (0 = uniform, high = bright spots mirror / dark spots rough)

// Auto-generated normals: perturb the surface normal by the albedo's luminance
// gradient (same finite-difference bump used for ice), so reflections pick up the
// texture's relief — adds detail to the reflection without a normal map.
#define PBR_GEN_NORMALS                // generate bump normals for PBR blocks from the texture
#define PBR_NORMAL_STRENGTH 0.6        // [0.1 0.2 0.3 0.4 0.5 0.6 0.8 1.0 1.5 2.0] bump strength (higher = more relief / wavier reflections)
#define PBR_DIELECTRIC_NORMAL 2.0      // [1.0 1.25 1.5 1.75 2.0 2.5 3.0 4.0] extra bump-normal strength for NON-metals (stone/wood/etc.), on top of PBR_NORMAL_STRENGTH

#define REFLECTION_RAYS 3          // [1 2 3 4 6 8] VNDF rays per pixel (rough reflections scatter these; more = cleaner, costs more)
#define REFLECTION_STEPS 32        // [12 16 20 24 32 48 64] SSR march steps per ray
#define REFLECTION_REFINE_STEPS 4  // [0 2 4 6 8] binary-search refinement steps after a hit
#define REFLECTION_SMOOTHNESS_MIN 0.04 // [0.0 0.02 0.04 0.08 0.12 0.18 0.25 0.35] reflection cutoff / PERF knob: pixels below this smoothness skip the pass. 0.04 = full parity (even dirt/wool reflect faintly); ~0.25 skips the matte families (dirt/wood/wool/rough-stone) for performance
#define REFLECTION_SKY_FADE 12.0   // [4.0 6.0 8.0 10.0 12.0 16.0 20.0] skylight power for the sky-reflection gate (higher = indoor blocks stop reflecting sky)
#define REFLECTION_SKY_STRENGTH 0.5 // [0.0 0.2 0.3 0.4 0.5 0.6 0.7 0.8 1.0] brightness of the environment SKY reflection on PBR blocks (lower = less flat sky wash; SSR scene hits + sun glint unaffected)
#define SPECULAR_SUN 1              // [0 1] direct GGX sun/moon specular highlight (glint) on PBR blocks
#define SPECULAR_SUN_STRENGTH 1.0   // [0.0 0.25 0.5 0.75 1.0 1.5 2.0 3.0 4.0] brightness of the sun/moon glint
// Non-metals (stone, wood, concrete, glass-like) -> strong SUN glint, weak SKY wash.
// The SCENE (surroundings) reflection strength is set per-class by F0 in
// terrain.glsl (polished/gem high = glossy; dirt/wood low = matte). This knob only
// scales the SKY portion, so you can keep glossy surroundings while killing sky.
#define PBR_DIELECTRIC_REFLECT 0.1 // [0.0 0.05 0.1 0.15 0.2 0.3 0.4 0.6 0.8 1.0] non-metal SKY reflection strength only (scene reflection is F0-driven per class)
#define PBR_DIELECTRIC_SUN 5.0      // [1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0 8.0] non-metal SUN/MOON glint boost. Higher = stronger sun highlight on non-metals
#define REFLECTION_DENOISE         // temporal accumulation of the reflection across frames (colortex4) — removes the stochastic ray noise
#define REFLECTION_ACCUM_FRAMES 48 // [4 8 12 16 24 32 48] frames blended by the reflection temporal filter (higher = cleaner but more ghosting on motion)
#define REFLECTION_FIREFLY_CLAMP 8.0 // [2.0 4.0 6.0 8.0 12.0 16.0 24.0 1000.0] max brightness a single reflected sample may contribute — kills sparkly fireflies from bright HDR hits (1000 = off)
#define REFLECTION_SPATIAL_RADIUS 14.0 // [0.0 6.0 8.0 10.0 14.0 18.0 24.0] max blur radius (px) of the spatial reflection denoise; scales UP when temporal history is low (in motion), so motion noise is blurred but converged pixels stay sharp

//   0 = off   1 = smoothness   2 = metal albedo(F0)   3 = skyVis gate   4 = raw reflection
#define PBR_DEBUG 0 // [0 1 2 3 4]

#define VOXEL_GI
#define VOXEL_DISTANCE 12 // [8 12 16 24 32] horizontal voxelization radius (chunks)
#if VOXEL_DISTANCE == 8
    #define VOXEL_SHADOW_DISTANCE 128.0
#elif VOXEL_DISTANCE == 12
    #define VOXEL_SHADOW_DISTANCE 192.0
#elif VOXEL_DISTANCE == 16
    #define VOXEL_SHADOW_DISTANCE 256.0
#elif VOXEL_DISTANCE == 24
    #define VOXEL_SHADOW_DISTANCE 384.0
#else
    #define VOXEL_SHADOW_DISTANCE 512.0
#endif
#define GI_SAMPLES 1    // [1 2 3 4] TODO might be dead due to ReSTIR
#define GI_RADIUS  48   // [12 16 24 32 48 64 96 128] GI/sun-shadow ray reach (blocks). Raised to 48 for the doubled (radius-256) grid; brick-skip keeps this affordable.
#define GI_MAX_STEPS 192 // [64 96 128 192 256 384] The maximum number of individual 1-block steps a ray can take before giving up. Lowering this drastically improves framerates in dense areas like forests.
#define GI_STRENGTH 100 // [25 50 75 100 150 200] NOTE: the irradiance cache does infinite bounce and is a different scale than the old ReSTIR resolve — lowered from 200. Tune to taste.
#define GI_SKY_BRIGHTNESS 1.0 // [1.0 2.0 3.0 4.0 6.0 8.0]
#define GI_SKY_WARMTH 0.30 // [0.0 0.05 0.10 0.15 0.20 0.25 0.30 0.40 0.50 0.65 0.80 1.00] warms the path-traced SKYLIGHT illumination on terrain (more golden, less blue) WITHOUT tinting the rendered sky/clouds/fog. 0 = raw sky color.
#define GI_BOUNCE_SHADOWMAP
#define GI_BOUNCE_SKY 1.0 // [0.25 0.4 0.6 0.8 1.0 1.5] sky contribution weight at bounce surfaces
#define GI_SKY_PROBE_DIST 64   // [8 12 16 24 32 48 64 96] max blocks the sky-probe DDA ray travels from a bounce surface (raised for the doubled grid)
#define GI_EMISSION 1.0   // [1 2 3 4 5 6 7 8] emissive block glow strength
#define VOXEL_SHAPES

// --- Special blocklight detail ------------------------------------------------
// A dedicated lighting path for light-emitting blocks (torches, lava, lanterns,
// redstone...). Without it, emissive blocks are shaded like any opaque surface
// (NdotL sun + GI) plus a flat whole-block glow hack -> lava darkens when it
// faces away from the sun and a torch's wooden stick glows as brightly as the
// flame. With it ON, a per-texel emissive MASK (heuristic from albedo, no labPBR
// needed) drives an UNSHADED self-emission term, so only the genuinely glowing
// texels (flame, hot lava, lit filament) emit and the rest shade normally.
#define SPECIAL_BLOCKLIGHT // master toggle for the per-texel self-emission path (d7_composite)
#define EMISSIVE_THRESHOLD_LO 0.42 // [0.20 0.28 0.35 0.42 0.50 0.58 0.66] albedo value below which a texel is treated as non-emissive (the stick). Lower = more of the block glows.
#define EMISSIVE_THRESHOLD_HI 0.72 // [0.55 0.62 0.66 0.72 0.78 0.85 0.92] albedo value at/above which a texel is fully emissive (the flame). Raise to confine the glow to only the brightest texels.
#define EMISSIVE_BRIGHTNESS 6.0 // [1.0 2.0 3.0 4.0 6.0 8.0 12.0 16.0] HDR strength of the self-emission added to emissive texels. The texel's own albedo supplies the color.
// Experimental: make the voxelization aware of WHERE on a blocklight the emission
// comes from. A torch's emission is concentrated in a flame sub-box at the top of
// its post while the post stays an opaque occluder, so nearby surfaces low behind
// the stick fall into its shadow (fancy directional blocklight detail in GI).
#define VOXEL_EMISSIVE_SHAPES // gate the gi.glsl emissive sub-box logic; off = whole-voxel emission (legacy)
// --- World-space irradiance cache (IRC) --------------------------------------
// Indirect light is gathered into a persistent, camera-relative 3D grid (the
// irradiance cache) by compute passes in the shadowcomp stage, then sampled
// per-pixel during shading. Because the cache lives in WORLD space, lighting is
// stable under camera motion (no screen-space temporal crawl) and newly revealed
// surfaces read an already-converged cell (no disocclusion flush). This replaces
// the old per-pixel ReSTIR reservoirs + screen-space SVGF denoiser entirely.
//
// Grid: 1 cell = 1 world block (IRC_CELL 1) for sharp, per-block GI resolution.
// The cache is a NEAR-FIELD grid DECOUPLED from the big voxel grid (the voxel grid
// reaches VOXEL_DISTANCE chunks for ray tracing, but storing 1-block irradiance over
// all of it would be tens of millions of cells). IRC_QUALITY sets the cache extent;
// beyond it, surfaces fall back to sky ambient. Origin is snapped to 1 block so the
// camera reprojects the cache by integer cells. The image dims in shaders.properties
// (IRC_XZ / IRC_Y) MUST match the IRC_QUALITY chain below.
#define IRC_CELL 1             // world blocks per cache cell (keep 1 — sharp GI)
#define IRC_QUALITY 1          // [0 1 2] cache extent/res: 0 = 128x96x128 near-field (fast), 1 = 192x128x192 (balanced), 2 = 256x128x256 (wide, costly). MUST match IRC_XZ/IRC_Y in shaders.properties.
#if IRC_QUALITY == 0
    #define IRC_DIM_XZ 128
    #define IRC_DIM_Y  96
    #define IRC_WG ivec3(16, 12, 16)
#elif IRC_QUALITY == 1
    #define IRC_DIM_XZ 192
    #define IRC_DIM_Y  128
    #define IRC_WG ivec3(24, 16, 24)
#else
    #define IRC_DIM_XZ 256
    #define IRC_DIM_Y  128
    #define IRC_WG ivec3(32, 16, 32)
#endif
#define IRC_RAYS 1             // [1 2 3 4] GI rays traced per cell per update
#define IRC_DECAY 0.99         // [0.90 0.94 0.96 0.97 0.98 0.99 0.992 0.995] per-frame temporal retention of the cache. Higher = more effective samples = far less per-frame flicker ("disco"), at the cost of slower response to lighting changes. The reference packs run ~0.99.
#define IRC_MULTIBOUNCE 0.30   // [0.0 0.15 0.30 0.5 0.7 1.0] strength of the cache self-feedback (infinite bounce). 0 = single bounce (darker, closer to the old ReSTIR look); 1 = full multi-bounce (brighter, more color bleed, can wash out dark interiors).
#define IRC_AMORTIZE 1         // [1 2 4 8 16 32] far cells update 1-in-N frames (1 = every cell every frame). >1 saves perf but the per-cell phased updates produce a flickering "disco" patchwork — keep at 1 unless you need the perf.
#define IRC_AMORTIZE_DIST 0.5  // [0.25 0.35 0.5 0.65 0.8] fraction of the grid half-extent beyond which amortization applies
#define IRC_SPATIAL_FILTER     // 7-tap neighbour blur at read (suppresses residual 1-spp flicker). Turn OFF for the sharpest (but noisier) cache read.
#define IRC_NORMAL_OFFSET 0.85 // [0.5 0.65 0.75 0.85 1.0 1.25 1.5] blocks the read point is pushed along the surface normal into the air. Lower = reads closer to the surface (better local occlusion / darker corners) but more leak risk; higher = smoother but flatter. The occlusion guard catches the leak case. (Now in BLOCKS since IRC_CELL=1.)
#define IRC_OCCLUSION_GUARD    // reject the trilinear read when the offset sample point lands inside solid geometry (anti-leak); falls back to the surface cell
//#define IRC_DEBUG            // visualize the resolved cache irradiance directly (no albedo) in d7_composite

#define AO_GTAO              // ON: the irradiance cache is isotropic (no per-pixel directional occlusion), so screen-space GTAO restores the contact shadows / small-scale darkening the old per-pixel ReSTIR provided.
#define AO_GI_STRENGTH 70    // [0 25 50 70 100] how strongly AO occludes the indirect (GI) term
#define AO_DIRECT_STRENGTH 0 // [0 25 50 75 100] AO applied to direct sunlight (0 = leave shadows untouched)
#define GTAO_SLICES 2        // [1 2 3 4] horizon slices per pixel per frame (rotates over the TAA cycle)
#define GTAO_STEPS 4         // [2 3 4 6 8] horizon-march taps per slice side
#define GTAO_RADIUS 1.0      // [0.5 0.75 1.0 1.5 2.0 3.0] AO world radius (blocks); short = tight contact shading

// --- Screen-space GI denoiser (per-pixel PT path: d1 temporal + d2..d5 a-trous) --
// The per-pixel ray (d0_trace) is a noisy 1-spp signal. d1 reprojects + accumulates
// it across frames; d2..d5 run four variance-guided a-trous wavelet passes that blur
// noise while preserving geometric/lighting edges. History length (the .a channel)
// drives BOTH the temporal blend rate and the spatial filter width per pixel.
#define GID_TEMPORAL_MAX_FRAMES 48 // [8 12 16 24 32 48 64 128] max temporal history. Higher = cleaner/steadier but more ghosting when lighting changes.
#define GID_NORMAL_EXP_MIN 8.0     // loose normal rejection for LOW-history pixels: accepts slightly off-normal history at curved edges so disocclusions FILL IN instead of locking at 1-spp (the old fixed pow-128 caused permanent edge fireflies).
#define GID_NORMAL_EXP_MAX 64.0    // sharp normal rejection once history has CONVERGED (keeps edges crisp).
#define GID_CLAMP_K 4.0            // [2.0 3.0 4.0 6.0 8.0 1000.0] firefly clamp width (xσ) for the current sample vs its planar neighbourhood, in LUMA space so chroma survives and only bright outliers are rescaled. Lower = stronger firefly kill but dims sparse light; 1000 = off.
#define GID_SIGMA_L 4.0            // [1.0 2.0 3.0 4.0 6.0 8.0] luminance edge-stop strength of the a-trous filter. Lower = more blur (smoother, softer detail); higher = preserves detail but lets through more noise.
#define GID_DISOCC_BOOST 8.0       // [0.0 2.0 4.0 8.0 16.0] extra blur for freshly disoccluded (low-history) pixels: inflates the variance estimate so newly revealed geometry blurs out fast instead of showing raw 1-spp.
#define GID_MOTION_TOLERANCE 1.0   // [0.5 1.0 1.5 2.0 3.0 4.0 6.0] how loose the temporal motion/disocclusion rejection is. Higher = history survives camera motion far more (much less motion noise) at the cost of some ghosting; lower = sharper/more responsive but noisier in motion. Was effectively ~0.2 before.
#define GID_DEPTH_STRICTNESS 0.5   // [0.1 0.25 0.5 0.75 1.0 1.5 2.0] tightness of the SPATIAL à-trous depth edge-stop. Lower = looser: GI blurs more freely across depth so the filter denoises harder (smoother), at the risk of bleeding across depth edges; higher = preserves depth edges but keeps more noise. Lower this if the spatial filter rejects neighbours too aggressively.
#define GID_LUMA_FLOOR 0.02        // [0.005 0.01 0.02 0.04 0.08 0.15] dark cutoff for the SCALE-INVARIANT luma edge-stop. The luma weight compares neighbours RELATIVE to local brightness (so dark interiors filter as hard as lit surfaces — fixes low-light "boiling"); below this brightness the relative metric is clamped so near-black noise is just blurred away instead of treated as detail. Raise if dark areas still boil; lower if dark GI detail washes out.
#define GID_FIREFLY_MAX 0.5        // [1.0 2.0 3.0 4.0 6.0 8.0 12.0 20.0 1000.0] SOURCE firefly clamp (d0_trace): max luminance a single 1-spp GI ray may return, rescaled to keep chroma. A lone ray catching the bright sky/sun through a gap returns a huge spike no screen-space filter can tell from signal (neighbours near a bright opening are also bright) — bloom then smears it into glowing white blobs. Clamping at the source kills the blobs. LOWER if blobs remain; RAISE if GI next to bright openings looks dimmed/capped. 1000 = off.

//#define VOXEL_AO
#define AO_SAMPLES 2   // [2 4 6 8] 
#define AO_RADIUS  8   // [4 6 8 10 12 16 24 32 48 64] 
#define AO_STRENGTH 100 // [25 50 75 100] 

//#define PT_DEBUG_VOXELS  // voxel debug view
//#define GI_DEBUG_VIEW 1   // irradiance debug
#define PT_LIGHT_DEBUG 0 // [0 1 2 3 4] Diagnostic isolation: 0=off, 1=RTAO/AO term, 2=indirect(GI), 3=direct-shadow visibility, 4=raw albedo. Shows the chosen lighting component alone so we can see which one makes the dark halo around torches.
#define WATER_DEBUG 0 // [0 1 2]

#include "/lib/pipelineSettings.glsl"
#include "/lib/uniforms.glsl"

#endif
// --- Utility Macros ---
#ifndef PI
#define PI 3.14159265359
#endif

#ifndef GTAO_HALF_PI
#define GTAO_HALF_PI 1.57079632679
#endif

#ifndef clamp01
#define clamp01(x) clamp(x, 0.0, 1.0)
#endif
