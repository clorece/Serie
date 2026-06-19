#include "/lib/options.glsl"

// dh_water : Distant Horizons LOD water G-buffer writer.
//
// Writes the deferred water g-buffer (wave normal -> colortex1, lightmap + water
// flag -> colortex2), but deliberately leaves colortex0 untouched. The composite
// water pass shades DH water from this flag later. Writing a deep fallback color
// to colortex0 here leaks through nearby normal water, because vanilla water also
// leaves colortex0 as its refraction background.
//
// Occlusion: DH renders beyond the vanilla far plane, so ANY vanilla opaque
// geometry (depthtex1 < 1.0) at this pixel is closer — discard so DH water never
// draws THROUGH near Minecraft chunks.

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

flat out int  mat;
out vec2 lmCoord;
out vec3 viewNormal;
out vec3 worldPos;
out vec3 playerPos;
out vec3 viewPosDH; // view-space position (for the occlusion depth compare)

void main() {
    gl_Position = ftransform();

#ifndef DISTANT_HORIZONS
    mat        = 0;
    lmCoord    = vec2(0.0);
    viewNormal = vec3(0.0, 1.0, 0.0);
    viewPosDH  = vec3(0.0);
    playerPos  = vec3(0.0);
    worldPos   = vec3(0.0);
    return;
#else
    mat        = dhMaterialId;
    lmCoord    = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;
    viewNormal = normalize(gl_NormalMatrix * gl_Normal);
    viewPosDH  = (gl_ModelViewMatrix * gl_Vertex).xyz;
    playerPos  = (gbufferModelViewInverse * vec4(viewPosDH, 1.0)).xyz;
    worldPos   = playerPos + cameraPosition;

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
#include "/lib/fragment/water.glsl"

flat in int  mat;
in vec2 lmCoord;
in vec3 viewNormal;
in vec3 worldPos;
in vec3 playerPos;
in vec3 viewPosDH;

void main() {
#ifndef DISTANT_HORIZONS
    discard;
#else
    if (mat != DH_BLOCK_WATER) discard;

    // Occlusion by the near scene: compare this DH-water fragment's view-space depth
    // (passed from the vertex stage, so no dhProjectionInverse — Iris doesn't inject
    // it into DH programs) against the vanilla scene depth. If vanilla geometry is
    // nearer, the water is behind it — discard so DH water never draws THROUGH near
    // Minecraft chunks. View space is shared (camera); only the projection differs.
    {
        float backMC = texelFetch(depthtex0, ivec2(gl_FragCoord.xy), 0).r;
        if (backMC < 1.0) {
            vec4 vmc = gbufferProjectionInverse * vec4(0.0, 0.0, backMC * 2.0 - 1.0, 1.0);
            if (vmc.z / vmc.w > viewPosDH.z) discard; // vanilla nearer (less -z) -> occluded
        }
    }

    // Near-edge dither fade for the soft hand-off at the vanilla render boundary.
    float dist     = length(playerPos);
    float dither   = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);
    float nearFade = smoothstep(far * 0.5, far * 0.7, dist);
    if (nearFade < dither) discard;

    // Wave normal (distance-faded like near water so it isn't sub-pixel noise far out).
    vec3 worldGeoN = normalize(mat3(gbufferModelViewInverse) * viewNormal);
    vec3 worldN    = worldGeoN;
    #ifdef WATER_WAVES
    {
        float t        = frameTimeCounter * WATER_WAVE_SPEED;
        float lod      = clamp(dist / WATER_NORMAL_FADE, 0.0, 1.0);
        float fadeMin  = WATER_NORMAL_FADE_MIN * 0.01;
        float strength = WATER_NORMAL_STRENGTH * mix(1.0, fadeMin, lod);
        float eps      = mix(0.10, 0.45, lod);
        worldN = waterSurfaceNormal(worldPos, worldGeoN, t, WATER_WAVE_AMPLITUDE, strength, eps);
    }
    #endif
    vec3 viewWaveN = normalize(mat3(gbufferModelView) * worldN);

    /* DRAWBUFFERS:12 */
    gl_FragData[0] = vec4(viewWaveN * 0.5 + 0.5, 0.0);         // colortex1: wave view normal, alpha marks DH water
    gl_FragData[1] = vec4(lmCoord, 1.0, 0.0);                  // colortex2: lightmap, water flag=1, emission 0
#endif
}

#endif
