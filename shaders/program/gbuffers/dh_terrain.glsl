#include "/lib/options.glsl"

// dh_terrain : Distant Horizons LOD terrain G-buffer writer.
//
// DH LODs have no texture atlas coords — the averaged block colour arrives in
// gl_Color, and the DH block category in the dhMaterialId uniform. This writes
// the DEFERRED G-BUFFER (albedo -> colortex0, view normal + material ->
// colortex1, lightmap + emission -> colortex2), exactly like gbuffers_terrain
// but without an atlas/PBR. d7_composite then lights these pixels (shadow map +
// far screen-space shadow + lightmap/sky ambient), so DH terrain receives the
// same shadows / fog / volumetric light as the near scene. (No voxel GI — DH is
// beyond the voxel grid, so it falls back to lightmap ambient.)
//
// The near edge is dither-faded to 0 across the vanilla render distance so the
// real (textured, voxel-GI-lit) terrain shows through and the LOD only fills the
// far ring beyond it.

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

flat out int  mat;
out vec2 lmCoord;
out vec3 viewNormal;
out vec3 playerPos;
out vec4 glColor;

void main() {
    gl_Position = ftransform();

    mat      = dhMaterialId;
    glColor  = gl_Color;
    lmCoord  = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;

    viewNormal = normalize(gl_NormalMatrix * gl_Normal);
    playerPos  = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz;

    #ifdef TAA
        gl_Position.xy += getTaaJitter() * 2.0 * gl_Position.w / vec2(viewWidth, viewHeight);
    #endif

    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/util/common.glsl"
#include "/lib/util/dither.glsl"

flat in int  mat;
in vec2 lmCoord;
in vec3 viewNormal;
in vec3 playerPos;
in vec4 glColor;

void main() {
#ifndef DISTANT_HORIZONS
    discard;
#else
    // Near-edge dither fade so vanilla terrain (closer than `far`) wins.
    float dist     = length(playerPos);
    float dither   = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);
    float nearFade = smoothstep(far * 0.5, far * 0.7, dist);
    if (nearFade < dither) discard;

    vec3 albedo = glColor.rgb;

    // Material code (matches gbuffers_terrain colortex1.a packing):
    //   1/3 = foliage (leaves, wrap NdotL), 2/3 = grass (soft), 1.0 = emissive.
    float matAlpha = 0.0;
    float emission = 0.0;
    if (mat == DH_BLOCK_LEAVES)      { matAlpha = 1.0 / 3.0; }
    else if (mat == DH_BLOCK_GRASS)  { matAlpha = 2.0 / 3.0; }
    else if (mat == DH_BLOCK_ILLUMINATED) { matAlpha = 1.0; emission = 0.6; }
    else if (mat == DH_BLOCK_LAVA)        { matAlpha = 1.0; emission = 1.0; }

    /* DRAWBUFFERS:012 */
    gl_FragData[0] = vec4(albedo, 1.0);                          // colortex0: albedo
    gl_FragData[1] = vec4(viewNormal * 0.5 + 0.5, matAlpha);     // colortex1: view normal + material
    gl_FragData[2] = vec4(lmCoord, 0.0, emission);              // colortex2: lightmap, flag=0, emission
#endif
}

#endif
