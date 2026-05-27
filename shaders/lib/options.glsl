#ifndef OPTIONS_GLSL
#define OPTIONS_GLSL

#define SHADOW_FILTER
#define DITHER_FILTER

#define SHADOW_RESOLUTION 3072 //[512 1024 1563 2048 3072 4096 6144 8192]
#define SHADOW_FILTER_QUALITY 8 //[1 2 3 4 6 8 10 12 14 16 18 20 22 24]
#define SHADOW_MAP_BIAS 0.85 //Increase this if you get shadow acne. Decrease this if you get peter panning. [0.000 0.001 0.002 0.003 0.004 0.005 0.006 0.007 0.008 0.009 0.010 0.012 0.014 0.016 0.018 0.020 0.022 0.024 0.026 0.028 0.030 0.035 0.040 0.045 0.050]

//#define FAKE_SSS  // WIP
#define SCATTER_AMOUNT 2.0; // [1.0 1.5 2.0 2.5 3.0 3.5 4.0 4.5 5.0]

//#define VOLUMETRIC_LIGHT
#define VL_STEPS 2 // [1 2 3 4]
#define VL_INTENSITY 0.3 // [0.1 0.15 0.2 0.25 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]


#define TAA
#define TAA_JITTER_AMOUNT 1.0
#define TAA_JITTER_SPREAD 1.0
#define taaBlendWeight 0.9 // [0.8 0.85 0.9 0.95 0.99]
#define taaSharpenAmount 0.01 // [0.01 0.025 0.05 0.075 0.1 0.125 0.15 0.175 0.2 0.225 0.25 0.3]

#define BLOOM
#define BLOOM_STRENGTH 0.015 // [0.01 0.03 0.06 0.08 0.10 0.12 0.15 0.18 0.22 0.26 0.30]

#define AUTO_EXPOSURE
#define EXPOSURE 3.00 // [0.10 0.20 0.30 0.40 0.50 0.60 0.70 0.80 0.90 1.00 1.10 1.20 1.30 1.40 1.50 1.60 1.70 1.80 1.90 2.00 2.20 2.40 2.60 2.80 3.00]
#define AUTO_EXPOSURE_TARGET 0.035 // [0.10 0.12 0.14 0.16 0.18 0.20 0.22 0.24 0.26 0.28 0.30 0.35 0.40 0.45 0.50]
#define AUTO_EXPOSURE_SPEED 1.0 // [0.1 0.2 0.4 0.6 0.8 1.0 1.2 1.4 1.6 1.8 2.0]
#define AUTO_EXPOSURE_CENTER_WEIGHT 0.5 // [0.0 0.1 0.2 0.3 0.4 0.5 0.6 0.7 0.8 0.9 1.0]
#define AUTO_EXPOSURE_MIN 0.1 // [0.01 0.02 0.03 0.04 0.05 0.06 0.08 0.10 0.15 0.20]
#define AUTO_EXPOSURE_MAX 128.0 // [2.0 4.0 6.0 8.0 10.0 12.0 15.0 20.0 25.0 30.0]

#define TONEMAP_OPERATOR 0 // [0 1 2 3 4]
#define COLOR_CONTRAST 1.0 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_SATURATION 1.04 // [0.8 0.9 0.95 1.0 1.04 1.08 1.12 1.16 1.2 1.25 1.3]
#define COLOR_TEMP 0.0 // [-0.5 -0.4 -0.3 -0.2 -0.1 0.0 0.1 0.2 0.3 0.4 0.5]
//#define VIGNETTE

// ---- Lighting blend (final composite: direct sun vs indirect/ambient balance) ----
// Final colour = albedo * (direct_sun * LIGHTING_DIRECT + indirect_GI * LIGHTING_INDIRECT).
// The sun is the directional contrast source; when the indirect/ambient term is nearly as
// strong as the sun, sunlit and shaded faces read the same and the scene goes flat. Lowering
// LIGHTING_INDIRECT (or raising LIGHTING_DIRECT) restores the sun-vs-shade contrast.
#define LIGHTING_DIRECT 110   // [50 75 100 110 125 150 200] Direct sunlight weight (%) in the final blend
#define LIGHTING_INDIRECT 70  // [25 40 55 70 85 100 125 150] Indirect/ambient (GI) weight (%); lower = more contrast, less flat
#define LIGHTING_AO_FULL      // Occlude the ambient/GI by the FULL GTAO term (physically correct) instead of the partial AO_GI_STRENGTH mix

//#define WIND_MOVEMENT // WIP

const int RGBA16F = 5;
const int RGBA16 = 3;
const bool colortex5Clear = false;
const int colortex5Format = RGBA16F;

const bool colortex3Clear = true;
const int colortex3Format = RGBA16F;

const bool colortex6Clear = true;
const int colortex6Format = RGBA16F;

// G-buffer data formats
const int RGB10_A2 = 1;
const int colortex1Format = RGB10_A2; // View normals
const int colortex2Format = RGBA16;   // Lightmap data

// Path tracing: voxel grid atlas (128^3 stored as 2048x1024 RGBA8UI)
// Cleared to 0 (VOXEL_AIR) each frame so the shadow pass repopulates from scratch
const int RGBA8UI = 11;
const int colortex7Format = RGBA8UI;
const bool colortex7Clear = true;

// Indirect light temporal history (persistent).
//   GI mode: colortex8 .rgb = accumulated irradiance, .a = history length; colortex9 .r = linear depth
//   AO mode: colortex8 .r = accumulated AO, .g = history length, .b = linear depth
const int colortex8Format = RGBA16F;
const bool colortex8Clear = false;
const int colortex9Format = RGBA16F;
const bool colortex9Clear = false;

// ReSTIR reservoirs (persistent): colortex10 = radiance.rgb + M, colortex11 = samplePos.xyz + W
const int RGBA32F = 7;
const int colortex10Format = RGBA32F;
const bool colortex10Clear = false;
const int colortex11Format = RGBA32F;
const bool colortex11Clear = false;

// Screen-space AO (persistent, written by d5_gtao):
//   .xy = octahedral-encoded world-space bent normal, .z = linear depth (disocclusion), .w = AO
const int colortex12Format = RGBA16F;
const bool colortex12Clear = false;

// Directional sky-irradiance LUT (persistent, octahedral). Written by d6_skylut into a
// SKY_LUT_RES x SKY_LUT_RES corner region; sampled by GI rays (1-frame latency).
const int colortex13Format = RGBA16F;
const bool colortex13Clear = false;

// ReSTIR reservoir sample-hit normal (persistent): .xy = octahedral world normal of the
// stored sample's hit surface — needed for the world-space reconnection Jacobian on reuse.
const int colortex14Format = RGBA16F;
const bool colortex14Clear = false;

// Temporal normal history (persistent): .xy = octahedral world-space normal of the primary
// visible surface — used for bilateral history rejection to prevent ghosting on moving geometry.
const int colortex15Format = RGBA16F;
const bool colortex15Clear = false;

// ---- Voxel GI (single-bounce indirect light; subsumes AO) ----
#define VOXEL_GI
#define GI_SAMPLES 1    // [1 2 3 4] Rays per pixel per frame (higher = less noise, lower fps)
#define GI_RADIUS  24   // [12 16 24 32 48] Max ray distance in blocks
#define GI_STRENGTH 200 // [25 50 75 100 150 200] Indirect light intensity (percent)
#define GI_SKY_DIRECTIONAL    // Sample a real directional sky (octahedral LUT) for GI rays instead of a flat ambient tint
#define GI_SKY_BRIGHTNESS 1.0 // [1.0 2.0 3.0 4.0 6.0 8.0] Sky irradiance multiplier for GI rays (lower this when GI_SKY_DIRECTIONAL is on)
#define GI_SKY_WARMTH 50      // [0 10 15 20 25 30 40 50] Tilt skylight hue toward the sun colour (percent) for a warmer, less cold feel
#define SKY_LUT_RES 256       // Octahedral sky-LUT side length in texels (sharper sky gradient = higher); kept <= screen size
#define SKY_LUT_STEPS 4       // [4 6 8 12] Atmosphere primary-march steps for the sky LUT (quality vs cost)
#define GI_BOUNCE_SKY 1.0 // [0.25 0.4 0.6 0.8 1.0 1.5] Sky contribution weight at bounce surfaces (sky probe)
#define GI_SKY_PROBE_DIST 32   // [8 12 16 24 32] Max blocks the sky-probe DDA ray travels from a bounce surface
#define GI_FLOOR 100    // [0 50 100 150 200] Ambient floor (percent of ambientColor); gated by skylight
#define GI_EMISSION 2   // [1 2 3 4 5 6 7 8] Emissive block glow strength
#define GI_ACCUM_FRAMES 128 // [8 16 32 48 64 128 192 256] Temporal frames to blend
#define GI_FIREFLY 4.0  // [1.5 2.0 3.0 4.0 6.0 8.0] Relative firefly clamp (x temporal-mean luminance)
#define GI_TEMPORAL_REJECT 8.0 // [1.0 1.5 2.0 3.0 4.0 8.0] History rejection in sigmas; lower = less ghosting, more noise
#define GI_DENOISE      // SVGF variance-guided spatial filter to clean up GI noise


// ---- SVGF denoiser (Schied et al. 2017, re-implemented from the paper) ----
#define SVGF_SIGMA_Z 2.0  // [0.5 1.0 2.0 4.0] Depth edge-stopping tolerance
#define SVGF_SIGMA_N 32.0  // [4.0 8.0 16.0 32.0 64.0] Normal edge-stopping sharpness (power); lower = smoother
#define SVGF_SIGMA_L 8.0 // [2.0 4.0 5.0 8.0 10.0 12.0 16.0] Luminance edge-stopping (variance-scaled); higher = smoother
#define SVGF_VAR_BOOST 8  // [2 4 6 8 12 16] History length below which variance is estimated spatially
#define PT_DETAIL_RECONSTRUCT // Reconstruct contact shadows / fine GI detail in the filter
#define SVGF_WORLD_RADIUS // Bound the a-trous footprint in WORLD space so distant GI keeps detail (fixes far-away flatness)
#define SVGF_SIGMA_WORLD 2.0 // [0.75 1.0 1.5 2.0 3.0 4.0 6.0] World-space blur radius in blocks; taps farther than this (e.g. across distant surfaces) are down-weighted

// Keep the TEMPORAL HISTORY raw/detailed instead of feeding the spatial blur back into it.
// Feeding the a-trous output back makes the accumulation converge to the flattened signal
// over frames (the real cause of the distance/contrast flatness). With this on, the a-trous
// filters a detailed signal fresh each frame -> it still denoises noise but preserves
// converged detail via its variance edge-stopping. Leave ON for this pack (heavy temporal
// accumulation). Off = classic SVGF feedback (denoised result becomes the history).
#define SVGF_RAW_HISTORY

// Optional extra: fade the spatial blur out as a pixel converges (mix the displayed result
// toward the raw accumulated GI by history length). Trades denoising for detail; at high
// PRESERVE_MAX converged areas look ~like the denoiser is OFF (it isn't — it's just showing
// the raw history). OFF by default: SVGF_RAW_HISTORY already lets the normal a-trous keep
// converged detail. Enable only if converged areas still look over-smoothed.
//#define SVGF_DETAIL_PRESERVE   // Re-inject raw detail on temporally-converged pixels
#define SVGF_PRESERVE_MAX 85     // [0 25 50 70 85 95 100] Max % of raw (un-blurred) GI kept once a pixel is fully converged
#define SVGF_PRESERVE_FRAMES 16  // [8 16 24 32 48 64] History length (frames) at which max preservation is reached

// ---- ReSTIR GI (reservoir resampling; replaces plain temporal accumulation when enabled) ----
#define RESTIR_GI               // Use ReSTIR reservoirs instead of simple GI accumulation
#define RESTIR_INITIAL_SAMPLES 1 // [1 2 4 6] Candidate rays generated per frame
#define RESTIR_M_CAP 48         // [8 12 16 24 32 48] Max reservoir confidence (history clamp)
#define RESTIR_JACOBIAN         // World-space reconnection Jacobian for spatial reuse (correct cross-geometry resampling; enables wider reuse)/
#define RESTIR_SPATIAL          // Enable spatial reservoir reuse from neighbours
#define RESTIR_SPATIAL_SAMPLES 2 // [1 2 3 4 5] Neighbour reservoirs merged per pixel
#define RESTIR_SPATIAL_RADIUS 16.0 // [4.0 8.0 16.0 24.0 32.0] Neighbour search radius (pixels)
#define RESTIR_W_MAX 8.0         // [2.0 4.0 8.0 16.0 32.0] Clamp on the unbiased reservoir weight W (anti-firefly)
#define RESTIR_CLAMP 8.0         // [2.0 4.0 8.0 16.0 32.0] Absolute firefly clamp on the resolved GI

// ---- Ambient Occlusion (screen-space GTAO; complements Voxel GI's macro occlusion) ----
// GTAO adds the sub-voxel CONTACT darkening the 1-block voxel grid cannot resolve. It is
// computed in d5_gtao -> colortex12 and applied in d7_composite. Keep the radius small so it
// only adds contact detail and does NOT re-darken occlusion the Voxel GI already captures.
#define AO_GTAO              // Master toggle for screen-space GTAO
#define AO_GI_STRENGTH 70    // [0 25 50 70 100] Contact-AO strength applied on top of Voxel GI (percent)
#define AO_DIRECT_STRENGTH 0 // [0 25 50 75 100] AO applied to direct sunlight (0 = leave shadows untouched)
#define GTAO_SLICES 2        // [1 2 3 4] Azimuthal slices per pixel (higher = smoother, slower)
#define GTAO_HORIZON_STEPS 4 // [2 3 4 6 8] Horizon march steps per slice direction
#define GTAO_RADIUS 0.5      // [1.0 1.5 2.0 3.0 4.0] Search radius (view-space units ~ blocks)
#define GTAO_FALLOFF 1.0    // [0.5 0.6 0.75 0.85] Fraction of radius where occlusion starts fading
#define AO_MULTIBOUNCE       // Jimenez multibounce compensation (less over-darkening on bright albedo)
#define AO_BENT_NORMAL       // Use the GTAO bent normal for directional skylight (GI-off / Voxel-AO mode)
#define AO_ACCUM_FRAMES 128   // [8 16 32 48 64 128 192 256] Temporal frames to accumulate AO (higher = smoother, more ghosting)
#define AO_DENOISE           // Depth-aware spatial bilateral filter on the AO (removes horizon-march stepping/noise)
#define AO_DENOISE_RADIUS 3  // [1 2 3] Bilateral kernel radius in taps ((2R+1)^2 samples; higher = smoother, slower)

// ---- Legacy voxel-DDA AO (only used when both VOXEL_GI and AO_GTAO are disabled) ----
#define VOXEL_AO
#define AO_SAMPLES 2   // [2 4 6 8] Rays per pixel (higher = less noise, lower fps)
#define AO_RADIUS  8   // [4 6 8 10 12] Max occlusion search distance in blocks
#define AO_STRENGTH 100 // [25 50 75 100] AO darkening intensity (percent)

//#define PT_DEBUG_VOXELS  // Enable DDA debug overlay in deferred pass
//#define GI_DEBUG_VIEW    // Enable raw GI debug overlay in deferred pass (skylight illumination)

#endif