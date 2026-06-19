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

const float DH_TERRAIN_FLAG = 0.0625;

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

flat out int  mat;
out vec2 lmCoord;
out vec3 viewNormal;
out vec3 playerPos;
out vec4 glColor;

void main() {
    gl_Position = ftransform();

#ifndef DISTANT_HORIZONS
    mat       = 0;
    glColor   = vec4(0.0);
    lmCoord   = vec2(0.0);
    viewNormal = vec3(0.0, 1.0, 0.0);
    playerPos = vec3(0.0);
    return;
#else
    mat      = dhMaterialId;
    glColor  = gl_Color;
    lmCoord  = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;

    viewNormal = normalize(gl_NormalMatrix * gl_Normal);
    playerPos  = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz;

    #ifdef TAA
        gl_Position.xy += getTaaJitter() * 2.0 * gl_Position.w / vec2(viewWidth, viewHeight);
    #endif

    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
#endif
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
    // (No manual depthtex1 occlusion discard here: Iris already depth-tests the
    // opaque DH terrain against the vanilla scene. Adding one created a 1-texel
    // seam at near-terrain silhouettes that TAA read as disocclusion.)

    // Near-edge dither fade so vanilla terrain (closer than `far`) wins.
    float dist     = length(playerPos);
    float dither   = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);
    float nearFade = smoothstep(far * 0.5, far * 0.7, dist);
    if (nearFade < dither) discard;

    vec3 albedo = glColor.rgb;

    // Material code (matches gbuffers_terrain colortex1.a packing):
    //   1/3 = foliage (wrap NdotL + SSS), 1.0 = emissive, 0 = normal Lambert.
    // NOTE: only true foliage (leaves) wraps. DH_BLOCK_GRASS is the grass-topped
    // GROUND block — near terrain shades grass_block (10003) with NORMAL Lambert,
    // so it must be matAlpha 0 here too; the old 2/3 code gave the whole grassy
    // landscape wrap-around NdotL (never darkens) = flat, wrong directional light.
    float matAlpha = 0.0;
    float emission = 0.0;
    if (mat == DH_BLOCK_LEAVES)           { matAlpha = 1.0 / 3.0; }
    else if (mat == DH_BLOCK_ILLUMINATED) { matAlpha = 1.0; emission = 0.6; }
    else if (mat == DH_BLOCK_LAVA)        { matAlpha = 1.0; emission = 1.0; }

    /* DRAWBUFFERS:012 */
    gl_FragData[0] = vec4(albedo, 1.0);                          // colortex0: albedo
    gl_FragData[1] = vec4(viewNormal * 0.5 + 0.5, matAlpha);     // colortex1: view normal + material
    gl_FragData[2] = vec4(lmCoord, DH_TERRAIN_FLAG, emission);  // colortex2: lightmap, DH terrain flag, emission
#endif
}

#endif
