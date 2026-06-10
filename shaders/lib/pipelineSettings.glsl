#ifndef PIPELINE_SETTINGS_GLSL
#define PIPELINE_SETTINGS_GLSL

const int RGBA8 = 0;
const int RGB10_A2 = 1;
const int RGBA16 = 3;
const int RGBA16F = 5;
const int RGBA32F = 7;
const int RGBA8UI = 11;

const int colortex1Format = RGB10_A2; // .rgb = view normals, .a = material code (2-bit: 0=normal, 1/3=foliage, 2/3=grass, 1=emissive)
const int colortex2Format = RGBA16;   // Lightmap data
const int colortex3Format = RGBA16F; // bloom atlas (composite) + SVGF a-trous ping-pong A (deferred); final denoised GI lands here for d7_composite
const int colortex5Format = RGBA16F; // TAA history + auto exposure (alpha) / prev-frame HDR scene
const int colortex6Format = RGBA16F; // SVGF a-trous ping-pong B (deferred). Bloom no longer uses this.
const int colortex8Format = RGBA16F; // temporal GI history (.rgb = accumulated irradiance, .a = history length)
const int colortex9Format = RGBA16F; // SVGF moments (.r = raw depth, .g = luma M1, .b = luma M2, .a = accumulated RTAO)
const int colortex10Format = RGBA16F; // ReSTIR reservoir radiance.rgb (clamped <=RESTIR_CLAMP) + M (<=RESTIR_M_CAP); both exact in half, saves bandwidth on this per-frame R/W buffer
const int colortex11Format = RGBA16F; // ReSTIR reservoir samplePos.xyz + W. samplePos is camera-relative (|x| <= 256); half precision worst-case ~0.25 blocks at the grid edge, and it only feeds the reconnection Jacobian (distance ratios), so 16F is plenty — halves the bandwidth of this per-frame R/W buffer vs the old RGBA32F.
// Atmosphere rewrite (see shaderpacks/serievx_atmosphere_plan.md):
// colortex12 = packed atmosphere LUT (Hillaire 2020): T-LUT (0..255,0..63),
//   MS-LUT (0..31,64..95), Sky-View LUT (0..255,96..255). 256×256 RGBA16F.
//   Rebuilt every frame by world0/prepare.fsh.
// colortex13 = cloud shadow map (sun visibility through clouds), distortion-warped
//   projection. 512×512 RGBA16F (only .r used; using RGBA16F until R16F is
//   wired into this pack's format-enum). Rebuilt every frame by world0/prepare1.fsh.
const int colortex12Format = RGBA16F;
const int colortex13Format = RGBA16F;
const int colortex14Format = RGBA16F; // .xy = ReSTIR reservoir sample-hit normal, .z = selected sample target, .w unused
const int colortex15Format = RGBA16F; // packed denoise G-buffer + temporal normal history: .xy = octahedral WORLD normal, .z = linear depth, .w = 1. Written once by d0_restir; every a-trous tap reads normal+depth in ONE fetch instead of depthtex0 + colortex1.

const bool colortex3Clear = true;
const bool colortex5Clear = false;
const bool colortex6Clear = true;
const bool colortex8Clear = false;
const bool colortex9Clear = false;
const bool colortex10Clear = false;
const bool colortex11Clear = false;
const bool colortex12Clear = false;  // prepare.fsh fully overwrites it every frame
const bool colortex13Clear = false;  // prepare1.fsh fully overwrites it every frame

// LINEAR filter on the LUT buffers — Iris's default for resolution-overridden
// buffers can be NEAREST. Without this, the sky-view LUT shows visible row
// boundaries as horizontal sky bands.
const bool colortex12Nearest = false;
const bool colortex13Nearest = false;
const bool colortex14Clear = false;
const bool colortex15Clear = false;

const int shadowMapResolution = SHADOW_RESOLUTION;
// Must cover the voxel grid's horizontal radius or the outer grid never gets
// voxelized (blocks are only written where the shadow pass rasterizes them).
// Tracks the VOXEL_DISTANCE option (chunks * 16 blocks; macro chain in
// options.glsl). If distant voxels show holes, raise SHADOW_RESOLUTION.
const float shadowDistance = VOXEL_SHADOW_DISTANCE;
const float sunPathRotation = -40.0; // [10.0 20.0 30.0 40.0 50.0 60.0]
const float ambientOcclusionLevel = 0.5;
const float ambientStrength = 0.0;
const vec3 torchColor = vec3(0.9922, 0.6471, 0.1922);

const bool shadowHardwareFiltering = false;
const bool shadowtex1Mipmap = false;
const bool shadowtex1Nearest = false;

// Required for the multi-scale bloom atlas (mip-sampling colortex0 at LODs 2..8).
const bool colortex0MipmapEnabled = true;

// colortex6 is SVGF-only: ping-pong B for the a-trous chain
// (d1_atrous_first step1 -> ct3, then 2->ct6, 4->ct3, 8->ct6, 16->ct3).
// The final filtered GI therefore lands on colortex3, which d7_composite reads.
#endif
