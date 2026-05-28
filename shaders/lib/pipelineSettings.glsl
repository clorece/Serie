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
const int colortex3Format = RGBA16F; // bloom atlas (composite) + SVGF a-trous ping-pong A (deferred)
// colortex4 deleted — material code now packed into colortex1.a (was the only consumer).
const int colortex5Format = RGBA16F; // TAA history + auto exposure (alpha) / prev-frame HDR scene
const int colortex6Format = RGBA16F; // SVGF a-trous ping-pong B (deferred). Bloom no longer uses this.
const int colortex7Format = RGBA8UI; // voxel data atlas (.x = block type, .y = light level, .z = emissive light, .w = unused)
const int colortex8Format = RGBA16F; // temporal GI history (.rgb = accumulated irradiance, .a = history length)
const int colortex9Format = RGBA16F; // SVGF moments (.r = linear depth, .g = luma M1, .b = luma M2)
const int colortex10Format = RGBA32F; // ReSTIR reservoir radiance.rgb + M
const int colortex11Format = RGBA32F; // ReSTIR reservoir samplePos.xyz + W
// colortex12 deleted — RTAO replaces GTAO; raw AO from d0_restir lives in c14.w
// and the temporally-accumulated AO lives in c9.a.
// colortex13 deleted — GI rays use flat skyColor instead of the directional LUT.
const int colortex14Format = RGBA16F; // .xy = ReSTIR reservoir sample-hit normal, .w = raw RTAO scalar
const int colortex15Format = RGBA16F; // temporal normal history

const bool colortex3Clear = true;
const bool colortex5Clear = false;
const bool colortex6Clear = true;
const bool colortex7Clear = true;
const bool colortex8Clear = false;
const bool colortex9Clear = false;
const bool colortex10Clear = false;
const bool colortex11Clear = false;
const bool colortex14Clear = false;
const bool colortex15Clear = false;

const int shadowMapResolution = SHADOW_RESOLUTION;
const float shadowDistance = 160.0;
const float sunPathRotation = -40.0; // [10.0 20.0 30.0 40.0 50.0 60.0]
const float ambientOcclusionLevel = 0.5;
const float ambientStrength = 0.3;
const vec3 torchColor = vec3(0.9922, 0.6471, 0.1922);

const bool shadowHardwareFiltering = false;
const bool shadowtex1Mipmap = false;
const bool shadowtex1Nearest = false;

// Required for the multi-scale bloom atlas (mip-sampling colortex0 at LODs 2..8).
const bool colortex0MipmapEnabled = true;

// TODO colortex6 is now SVGF-only (no longer touched by bloom). To delete it entirely,
// refactor the a-trous chain (d1/d3/d5_denoise) to single-buffer ping-pong on colortex3.
// Watch the c3 ping-pong parity warning when doing that.
#endif