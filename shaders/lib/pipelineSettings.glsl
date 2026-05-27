#ifndef PIPELINE_SETTINGS_GLSL
#define PIPELINE_SETTINGS_GLSL

const int RGBA8 = 0;
const int RGB10_A2 = 1;
const int RGBA16 = 3;
const int RGBA16F = 5;
const int RGBA32F = 7;
const int RGBA8UI = 11;

const int colortex1Format = RGB10_A2; // View normals
const int colortex2Format = RGBA16;   // Lightmap data
const int colortex3Format = RGBA16F; // gaussian blurred bloom color
const int colortex4Format = RGBA8;   // material data
const int colortex5Format = RGBA16F; // TAA history + auto exposure (alpha) / prev-frame HDR scene
const int colortex6Format = RGBA16F; // horizontally blurred bloom input
const int colortex7Format = RGBA8UI; // voxel data atlas (.x = block type, .y = light level, .z = emissive light, .w = unused)
const int colortex8Format = RGBA16F; // temporal GI history (.rgb = accumulated irradiance, .a = history length; colortex9 .r = linear depth)
const int colortex9Format = RGBA16F; // temporal AO history (.r = accumulated AO, .g = history length, .b = linear depth)
const int colortex10Format = RGBA32F; // ReSTIR reservoir radiance.rgb + M
const int colortex11Format = RGBA32F; // ReSTIR reservoir samplePos.xyz + W
const int colortex12Format = RGBA16F; // GTAO
const int colortex13Format = RGBA16F; // skyLut
const int colortex14Format = RGBA16F; // ReSTIR reservoir sample-hit normal
const int colortex15Format = RGBA16F; // temporal normal history

const bool colortex3Clear = true;
const bool colortex5Clear = false;
const bool colortex6Clear = true;
const bool colortex7Clear = true;
const bool colortex8Clear = false;
const bool colortex9Clear = false;
const bool colortex10Clear = false;
const bool colortex11Clear = false;
const bool colortex12Clear = false;
const bool colortex13Clear = false;
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

// TODO free up what buffers we can free by merging, or getting rid of dead buffers
// maybe colortex3 and colortex6 can be merged into one bloom buffer
#endif