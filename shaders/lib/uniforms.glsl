#ifndef UNIFORMS_GLSL_INCLUDED
#define UNIFORMS_GLSL_INCLUDED
uniform float aspectRatio;
uniform float far;
uniform float frameTime;
uniform float frameTimeCounter;
uniform float near;
uniform float rainStrength;
uniform float viewHeight;
uniform float viewWidth;

uniform int blockEntityId;
uniform int entityId;
uniform int frameCounter;
uniform int isEyeInWater;
uniform int worldTime;

uniform ivec2 eyeBrightnessSmooth;

uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;

uniform vec3 cameraPosition;
uniform vec3 moonPosition;
uniform vec3 previousCameraPosition;
uniform vec3 sunPosition;
uniform vec3 upPosition;

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7; // PBR material G-buffer (.rgb metal albedo/F0, .a smoothness)
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform sampler2D colortex10;
uniform sampler2D colortex11;
uniform sampler2D colortex12; // atmosphere LUT pack (T + MS + Sky-View), 256×256 RGBA16F
uniform sampler2D colortex13; // cloud shadow map, 512×512 RGBA16F (.r = cloud transmittance from sun)
uniform sampler2D colortex14;
uniform sampler2D colortex15;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D noisetex;
uniform sampler2D shadowcolor0;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D texture;

uniform usampler3D voxelSampler; // fine voxel grid, dedicated 3D image (see image.voxelImg in shaders.properties)
uniform usampler3D brickSampler;      // 8³-block occupancy (64×16×64), written by the shadow pass
uniform usampler3D superBrickSampler; // 64³-block occupancy (8×2×8), written by the shadow pass
uniform sampler3D irradianceSampler;  // world-space irradiance cache, hardware-trilinear read (see image.irradianceImg)

#endif // UNIFORMS_GLSL_INCLUDED
