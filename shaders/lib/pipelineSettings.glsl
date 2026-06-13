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
// colortex4 placeholder
const int colortex5Format = RGBA16F; // TAA history + auto exposure (alpha) / prev-frame HDR scene
const int colortex6Format = RGBA16F; // SVGF a-trous ping-pong B (deferred). Bloom no longer uses this.
// colortex7 placeholder
const int colortex8Format = RGBA16F; // temporal GI history (.rgb = accumulated irradiance, .a = history length)
const int colortex9Format = RGBA16F; // SVGF moments (.r = raw depth, .g = luma M1, .b = luma M2, .a = accumulated RTAO)
const int colortex10Format = RGBA16F; // ReSTIR reservoir radiance.rgb (clamped <=RESTIR_CLAMP) + M (<=RESTIR_M_CAP); both exact in half, saves bandwidth on this per-frame R/W buffer
const int colortex11Format = RGBA16F; // ReSTIR reservoir samplePos.xyz + W. samplePos is camera-relative (|x| <= 256); half precision worst-case ~0.25 blocks at the grid edge, and it only feeds the reconnection Jacobian (distance ratios), so 16F is plenty — halves the bandwidth of this per-frame R/W buffer vs the old RGBA32F.
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
const bool colortex12Nearest = false;
const bool colortex13Nearest = false;
const bool colortex14Clear = false;
const bool colortex15Clear = false;

const int shadowMapResolution = SHADOW_RESOLUTION;

const float shadowDistance = VOXEL_SHADOW_DISTANCE;
const float sunPathRotation = -40.0; // [10.0 20.0 30.0 40.0 50.0 60.0]
const float ambientOcclusionLevel = 0.5;
const float ambientStrength = 0.0;
const vec3 torchColor = vec3(0.9922, 0.6471, 0.1922);

const bool shadowHardwareFiltering = false;
const bool shadowtex1Mipmap = false;
const bool shadowtex1Nearest = false;

const bool colortex0MipmapEnabled = true;
#endif
