#ifndef OPTIONS_GLSL
#define OPTIONS_GLSL

#define SHADOW_FILTER
#define DITHER_FILTER

#define SHADOW_RESOLUTION 2048 //[512 1024 1563 2048 3072 4096 6144 8192]
#define SHADOW_FILTER_QUALITY 8 //[1 2 3 4 6 8 10 12 14 16 18 20 22 24]
#define SHADOW_MAP_BIAS 0.85 //Increase this if you get shadow acne. Decrease this if you get peter panning. [0.000 0.001 0.002 0.003 0.004 0.005 0.006 0.007 0.008 0.009 0.010 0.012 0.014 0.016 0.018 0.020 0.022 0.024 0.026 0.028 0.030 0.035 0.040 0.045 0.050]
#define SCREENSPACE_SHADOWS // Screen-space contact + infinite shadows multiplied onto the shadow map.

//#define FAKE_SSS  // WIP
#define SCATTER_AMOUNT 2.0; // [1.0 1.5 2.0 2.5 3.0 3.5 4.0 4.5 5.0]

#define VOLUMETRIC_LIGHT
#define VL_STEPS 3 // [2 3 4 6 8 12 16 20 24 32 48] dithered raymarch steps for atmospheric god rays (3 looks fine with TAA)
#define VL_INTENSITY 5.0 // [0.1 0.25 0.5 0.75 1.0 1.25 1.5 2.0 2.5 3.0] brightness of the in-scattered sun term
#define VL_NOON_STRENGTH 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at noon.
#define VL_SUN_RISE_SET_STRENGTH 25.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at sunrise and sunset.
#define VL_NIGHT_STRENGTH 1.0 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0] Volumetric light multiplier at night.

#define SKY_LUT_STEPS 10       // [4 6 8 10 12 14 16 20 24 28 32 40 48] uniform raymarching steps for the SkyView LUT build (lib/fragment/atmosphereLUT.glsl)

// --- Sky-View debug (set non-zero to diagnose the sunrise "layers" artifact) ---
// Sky pixels only. Output bypasses dynamic-light/discs/ground-blend so you see
// the raw thing. Exposure/tonemap still apply but won't hide hard edges.
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

// --- Belt of Venus (Earth's-shadow term in the SkyView build) ---
// Per-march-sample smooth planet-shadow on the DIRECT sun in-scatter: the low
// anti-solar atmosphere falls into shadow (dark band) while the atmosphere above
// stays lit (pink band). Kept smooth/wide so it can't alias into march "shells".
#define BELT_OF_VENUS
#define BELT_SHADOW_SOFTNESS 0.06 // [0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.14 0.20] angular half-width of Earth's shadow penumbra (sun cosine units). Smaller = crisper belt (more banding risk); larger = softer/washed out.

#define SUN_ILLUMINANCE 10.0  // [1.0 2.5 5.0 7.5 10.0 12.5 15.0 20.0] Sun light intensity multiplier for atmospheric scattering
#define MOON_ILLUMINANCE 0.02 // [0.005 0.01 0.02 0.04 0.06 0.08 0.10] Moon light intensity multiplier for atmospheric scattering
#define MIE_G 0.80            // [0.60 0.65 0.70 0.75 0.80 0.85 0.90 0.95] Mie phase function asymmetry factor (controls sun glow size/sharpness)

// Rayleigh scattering coefficients for R, G, B channels (scaled by 1e-6, default: 5.8e-6, 1.35e-5, 3.31e-5)
#define RAYLEIGH_SCATTER_R 5.8   // [1.0 2.0 3.0 4.0 5.0 5.8 7.0 8.0 10.0] Rayleigh scattering red channel
#define RAYLEIGH_SCATTER_G 13.5  // [5.0 8.0 11.0 13.5 16.0 19.0 22.0 25.0] Rayleigh scattering green channel
#define RAYLEIGH_SCATTER_B 33.1  // [15.0 20.0 25.0 30.0 33.1 38.0 43.0 50.0] Rayleigh scattering blue channel

// Mie scattering coefficients for R, G, B channels (scaled by 1e-6, default: 3.0e-6, 3.0e-6, 3.0e-6)
#define MIE_SCATTER_R 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering red channel
#define MIE_SCATTER_G 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering green channel
#define MIE_SCATTER_B 3.0 // [0.5 1.0 1.5 2.0 2.5 3.0 4.0 5.0 6.0] Mie scattering blue channel

// Ozone concentration peak (scaled by 1e-6, default: 8e-6)
#define OZONE_PEAK 8.0 // [0.0 2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0] Peak ozone concentration

// --- Volumetric clouds (see shaderpacks/serievx_atmosphere_plan.md §5) ---
#define CLOUDS // master toggle; cloud raymarch (Phase 6) and cloud-shadow build (Phase 5) both gated on this
#define CLOUDS_COVERAGE 0.80          // [0.20 0.30 0.40 0.45 0.50 0.55 0.60 0.65 0.70 75 0.80 0.90] global cumulus coverage (0 = clear sky, 1 = overcast)
#define CLOUDS_ALTITUDE_MULTIPLIER 0.75 // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00] Multiplier for how high in the air clouds render
#define CLOUDS_HEIGHT_MULTIPLIER 0.50 // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00] Multiplier for the cloud layer's vertical thickness
#define CLOUDS_SIZE_MULTIPLIER 1.50    // [0.25 0.50 0.75 1.00 1.25 1.50 1.75 2.00 2.50 3.00 4.00 5.00] Size multiplier for both cloud base and detail shapes
#define CLOUDS_DENSITY 0.02           // [0.01 0.02 0.03 0.05 0.08 0.12 0.18 0.25] cloud extinction coefficient (higher = denser/darker interiors)
#define CLOUDS_LAYER_BOTTOM 1500.0    // [600.0 900.0 1200.0 1500.0 1800.0 2400.0 3000.0] cumulus base altitude (m above planet surface)
#define CLOUDS_LAYER_TOP    5400.0    // [2400.0 3000.0 3600.0 4500.0 5400.0 6400.0 7500.0] cumulus top altitude (m above planet surface)
#define CLOUDS_WIND_SPEED 6.0         // [0.0 1.0 2.0 4.0 6.0 9.0 12.0 18.0 25.0] m/s — cloud advection speed
#define CLOUDS_WIND_DIR_X 1.0         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction X
#define CLOUDS_WIND_DIR_Z 0.3         // [-1.0 -0.7 -0.5 -0.3 0.0 0.3 0.5 0.7 1.0] wind direction Z
//#define CLOUDS_SHADOW                 // cloud shadow on terrain (Phase 5); cheap, free terrain shadowing under clouds
#define CLOUDS_SHADOW_STEPS 6         // [2 3 4 6 8 12] light-march steps along sun ray when building the cloud shadow map
#define CLOUDS_SHADOW_EXTENT 2048.0   // [512.0 1024.0 1536.0 2048.0 3072.0 4096.0] world extent (m, half-width) covered by the 512² distortion-warped shadow projection
// Phase 6 — primary cloud raymarch (only fires when CLOUDS is defined above)
#define CLOUDS_PRIMARY_STEPS 16       // [8 16 24 32 48 64 96] primary raymarch steps through the cloud layer (lerped horizon→zenith)
#define CLOUDS_LIGHT_STEPS 4          // [2 3 4 6 8] cone-march taps along sun ray for self-shadowing
#define CLOUDS_MS_OCTAVES 6           // [1 2 3 4 6] Wrenninge multiple-scattering octaves (each octave attenuates scatter/extinction)
#define CLOUDS_MAX_DISTANCE 16000.0   // [4000.0 8000.0 12000.0 16000.0 24000.0 32000.0] hard cap on cloud-layer ray distance (m); skip far cloud sampling
#define CLOUDS_MIN_TRANSMITTANCE 0.01 // [0.001 0.005 0.01 0.02 0.05] early-out when accumulated transmittance falls below this
#define CLOUDS_DEBUG 0

#define TAA
#define TAA_JITTER_AMOUNT 1.0
#define TAA_JITTER_SPREAD 1.0
#define TAA_BLEND_WEIGHT 0.95 // [0.85 0.86 0.87 0.88 0.89 0.90 0.91 0.92 0.93 0.94 0.95 0.96 0.97 0.98 0.99]

#define BLOOM
#define BLOOM_STRENGTH 0.15 // [0.01 0.03 0.06 0.08 0.10 0.12 0.15 0.18 0.22 0.26 0.30]

#define AUTO_EXPOSURE
#define EXPOSURE 1.00 // [0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 1.00 1.10 1.20 1.30 1.40 1.50 1.60 1.70 1.80 1.90 2.00 2.20 2.40 2.60 2.80 3.00]
#define AUTO_EXPOSURE_TARGET 0.22 // [0.10 0.12 0.14 0.16 0.18 0.20 0.22 0.24 0.26 0.28 0.30 0.35 0.40 0.45 0.50]
#define AUTO_EXPOSURE_SPEED 2.0 // [0.1 0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0]
#define AUTO_EXPOSURE_CENTER_WEIGHT 0.5 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
#define AUTO_EXPOSURE_MIN 0.001 // [0.01 0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.15 0.20]
#define AUTO_EXPOSURE_MAX 6.0 // [2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0 25.0 30.0]

#define TONEMAP_OPERATOR 0 // [0 1 2 3 4]
#define COLOR_CONTRAST 1.001 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_SATURATION 1.1 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_TEMP 0.0 // [-0.5 -0.4 -0.3 -0.2 -0.1 0.0 0.1 0.2 0.3 0.4 0.5]
//#define VIGNETTE

#define LIGHTING_DIRECT 110   // [50 75 100 110 125 150 200]
#define LIGHTING_INDIRECT 70  // [25 40 55 70 85 100 125 150]
//#define LIGHTING_AO_FULL

//#define WIND_MOVEMENT // WIP

#define WATER_WAVES
#define WATER_PARALLAX
#define WATER_PARALLAX_STEPS 4 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32]
#define WATER_PARALLAX_HEIGHT 2.00 // [0.25 0.50 0.75 1.00 1.25 1.50 2.00 3.00] Multiplier for the visual depth of the parallax waves
#define WATER_WAVE_OCTAVES 3 // [2 3 4 5 6] FBM octaves for the surface height field
#define WATER_WAVE_AMPLITUDE 0.24 // [0.02 0.04 0.06 0.08 0.10 0.14 0.18 0.24 0.32] bump height (blocks)
#define WATER_WAVE_SPEED 5.0 // [0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0 1.2 1.4 1.6 1.8 2.0 3.0 4.0 5.0 6.0 7.0 8.0 9.0 10.0] wave advection speed
#define WATER_NORMAL_STRENGTH 1.0 // [0.25 0.3 0.35 0.4 0.45 0.5 0.55 0.6 0.65 0.7 0.75 0.8 0.85 0.9 0.95 1.0 1.25 1.5 1.75 2.0] 0 = flat, 1 = full waves
#define WATER_NORMAL_FADE 128.0 // [0.0 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0 48.0 64.0 96.0 128.0] distance (blocks) over which wave normals LOD back toward flat (anti-aliases / hides tiling at range)
#define WATER_NORMAL_FADE_MIN 100.0 // [0.0 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0 48.0 64.0 96.0 100.0] Minimum normal strength percentage at the fade distance. 0 = fully flat, 50 = 50% less strength.

#define WATER_DISPLACEMENT
#define WATER_DISPLACEMENT_HEIGHT 0.28 // [0.04 0.06 0.08 0.10 0.12 0.16 0.20 0.28 0.32 0.35 0.40] swell height (blocks)
#define WATER_DISPLACEMENT_OCTAVES 1 // [1 2 3] big FBM octaves that move the mesh (low = only the largest swells)
#define WATER_DISPLACEMENT_STEEPNESS 1.0 // [0.0 0.15 0.30 0.45 0.60 0.80 1.00] trochoidal crest sharpening (0 = rounded vertical-only)
#define WATER_DISPLACEMENT_OFFSET 0.30 // [0.0 0.02 0.04 0.06 0.08 0.10 0.14 0.20 0.30] sink the rest water level this many blocks so cranked-up crests stay at/below the vanilla waterline (raise alongside _HEIGHT)

#define WATER_REFRACTION
#define WATER_REFRACTION_STRENGTH 0.24 // [0.02 0.04 0.06 0.08 0.10 0.14 0.18 0.24 0.32 0.35 0.40 0.50] screen-space refraction offset

#define WATER_REFLECTIONS
#define WATER_REFLECTION_STEPS 32 // [16 20 24 32 48 64 96 128] screen-space SSR march steps (higher = sharper / catches more)
#define WATER_SKYLIGHT_THRESHOLD 0.1 // [0.0 0.3 0.5 0.6 0.7 0.8 0.9] min sky access before water reflects sky / in-scatters (higher = caves & covered water stay dark)

#define WATER_ROUGHNESS 0.02 // [0.0 0.005 0.01 0.02 0.04 0.08 0.16] surface roughness for reflections (higher = blurrier/more diffuse reflections, lower = sharper/mirror-like reflections)

#define WATER_FOG

// Underwater sun-shaft godray raymarch (Phase 7). Additive on top of the
// analytic Beer-Lambert fog. Samples computeWaterCaustics() at each volume
// step so caustic banding propagates along the visible shafts.
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

#define VOXEL_GI
#define VOXEL_GRID_SIZE 128 // [64 128 256 512 1024 2048]
#define GI_SAMPLES 1    // [1 2 3 4] TODO might be dead due to ReSTIR
#define GI_RADIUS  24   // [12 16 24 32 48 64 96 128] TODO might also be dead due to ReSTIR
#define GI_STRENGTH 100 // [25 50 75 100 150 200]
#define GI_SKY_BRIGHTNESS 1.0 // [1.0 2.0 3.0 4.0 6.0 8.0]

#define GI_BOUNCE_SKY 1.0 // [0.25 0.4 0.6 0.8 1.0 1.5] sky contribution weight at bounce surfaces
#define GI_SKY_PROBE_DIST 32   // [8 12 16 24 32] max blocks the sky-probe DDA ray travels from a bounce surface
#define GI_FLOOR 100    // [0 50 100 150 200] TODO probably dont need this as a macro
#define GI_EMISSION 0.25   // [1 2 3 4 5 6 7 8] emissive block glow strength
//#define EXCLUDE_BLOCKLIGHTS_VOXELIZATION // Excludes custom blocklights (torches, lanterns, etc.) from the path-traced GI voxel grid entirely.
#define GI_FIREFLY 4.0  // TODO might be dead macro
#define GI_TEMPORAL_REJECT 4.0 // [1.0 1.5 2.0 3.0 4.0 8.0] TODO remove this and just rely on RESTIR_M_CLAMP for temporal blending

// TODO double check if any of these SVGF options are now redundant or can be tuned more aggressively with the new PT implementation
#define GI_DENOISE      // SVGF TODO: change macro name to SVGF_DENOISE
#define SVGF_SIGMA_Z 2.0  // [0.5 1.0 2.0 4.0] Depth edge-stopping tolerance
#define SVGF_SIGMA_N 32.0  // [4.0 8.0 16.0 32.0 64.0] Normal edge-stopping sharpness (power); lower = smoother
#define SVGF_SIGMA_L 8.0 // [2.0 4.0 5.0 8.0 10.0 12.0 16.0] Luminance edge-stopping (variance-scaled); higher = smoother
#define SVGF_VAR_BOOST 8  // [2 4 6 8 12 16] history length below which variance is estimated spatially
#define PT_DETAIL_RECONSTRUCT // reconstructs fine detail in the filter
#define SVGF_WORLD_RADIUS // TODO might not need?
#define SVGF_SIGMA_WORLD 2.0 // TODO might not need?
#define SVGF_RAW_HISTORY
//#define SVGF_DETAIL_PRESERVE // TODO delete this as it is old and outdated, disabling the denoiser when enabled
#define SVGF_PRESERVE_MAX 85     // [0 25 50 70 85 95 100] max % of raw (un-blurred) GI kept once a pixel is fully converged
#define SVGF_PRESERVE_FRAMES 16  // [8 16 24 32 48 64] history length (frames) at which max preservation is reached
//TODO merge GI_ACCUM_FRAMES and AO_ACCUM_FRAMES into one general "temporal accumulation length" macro and use it for both GI and AO denoising, call it SVGF_ACCUMULATION_LENGTH or something
#define GI_ACCUM_FRAMES 128 // [8 16 32 48 64 128 192 256] temporal frames to blend in denoiser
#define AO_ACCUM_FRAMES 128   // [8 16 32 48 64 128 192 256]

#define RESTIR_GI
#define RESTIR_INITIAL_SAMPLES 1 // [1 2 4 6] candidate rays generated per frame
#define RESTIR_M_CAP 48         // [8 12 16 24 32 48] max reservoir confidence (history clamp)
#define RESTIR_JACOBIAN
#define RESTIR_SPATIAL          // enable spatial reservoir reuse from neighbours
#define RESTIR_SPATIAL_SAMPLES 2 // [1 2 3 4 5] neighbour reservoirs merged per pixel
#define RESTIR_SPATIAL_RADIUS 16.0 // [4.0 8.0 16.0 24.0 32.0] neighbour search radius (pixels)

// TODO these might be dead macros to fix spatial reservoir reuse
#define RESTIR_W_MAX 8.0         // [2.0 4.0 8.0 16.0 32.0] clamp on the unbiased reservoir weight W 
#define RESTIR_CLAMP 8.0         // [2.0 4.0 8.0 16.0 32.0] absolute firefly clamp on the resolved GI

// Ray-traced AO (RTAO): short cosine rays through the voxel atlas, computed in
// d0_restir alongside the GI pass and temporally accumulated by d0_accum into
// colortex9.a. Replaces the old screen-space GTAO (which lived in colortex12 +
// a dedicated d5_gtao pass). Cheaper, single design, no separate buffer.
#define AO_RTAO
#define AO_GI_STRENGTH 50    // [0 25 50 70 100] how strongly AO occludes the indirect (GI) term
#define AO_DIRECT_STRENGTH 0 // [0 25 50 75 100] AO applied to direct sunlight (0 = leave shadows untouched)
#define RTAO_SAMPLES 1       // [2 3 4 6 8] cosine rays fired per pixel per frame
#define RTAO_RADIUS  1       // [1 2 3 4 6] AO ray length in blocks (short = contact AO)

//#define VOXEL_AO
#define AO_SAMPLES 2   // [2 4 6 8] 
#define AO_RADIUS  8   // [4 6 8 10 12 16 24 32 48 64] 
#define AO_STRENGTH 100 // [25 50 75 100] 

//#define PT_DEBUG_VOXELS  // voxel debug view
//#define GI_DEBUG_VIEW    // irradiance debug
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
