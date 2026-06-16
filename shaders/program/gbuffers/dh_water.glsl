#include "/lib/options.glsl"

// dh_water : Distant Horizons LOD water writer.
//
// Distant water is a flat sheet with no screen-space refraction background (that
// lives in c_water, near-field only). We FORWARD-shade it here — sky-tinted deep
// colour mixed toward the atmospheric sky reflection by Fresnel + a shadowed sun
// glint — and write it OPAQUELY to colortex0, plus a water flag to colortex2.b so
// d7 routes the pixel to passthrough (and c_water, gated to d0<1.0, ignores it).
// Blend is off so the flag survives. d8/d9 apply atmosphere / VL on top.

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

flat out int   mat;
out vec2  lmCoord;
out vec3  worldNormal;
out vec3  playerPos;
out vec4  glColor;

out vec3  lightColor;
out vec3  ambientColor;
out vec3  lightVector;
out vec3  upVector;
out vec3  sunVector;
out vec3  moonVector;
out vec3  worldLightVector;
out vec3  worldSunDir;

void main() {
    gl_Position = ftransform();

    mat      = dhMaterialId;
    glColor  = gl_Color;
    lmCoord  = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;

    vec3 viewNormal = normalize(gl_NormalMatrix * gl_Normal);
    worldNormal = normalize(mat3(gbufferModelViewInverse) * viewNormal);
    playerPos   = (gbufferModelViewInverse * gl_ModelViewMatrix * gl_Vertex).xyz;

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
    worldLightVector = mat3(gbufferModelViewInverse) * lightVector;
    worldSunDir      = mat3(gbufferModelViewInverse) * sunVector;

    #ifdef TAA
        gl_Position.xy += getTaaJitter() * 2.0 * gl_Position.w / vec2(viewWidth, viewHeight);
    #endif

    gl_Position.xy = gl_Position.xy * renderScale + gl_Position.w * (renderScale - 1.0);
}

#endif

#ifdef FRAGMENT

#include "/lib/util/common.glsl"
#include "/lib/util/dither.glsl"

flat in int   mat;
in vec2  lmCoord;
in vec3  worldNormal;
in vec3  playerPos;
in vec4  glColor;

in vec3  lightColor;
in vec3  ambientColor;
in vec3  lightVector;
in vec3  upVector;
in vec3  sunVector;
in vec3  moonVector;
in vec3  worldLightVector;
in vec3  worldSunDir;

vec3 clipSpace; // referenced by positions.glsl helpers we don't call here
#include "/lib/util/positions.glsl"
#include "/lib/fragment/dhLighting.glsl"
#include "/lib/fragment/sky.glsl"

void main() {
#ifndef DISTANT_HORIZONS
    discard;
#else
    if (mat != DH_BLOCK_WATER) discard;

    float dist = length(playerPos);

    // Near-edge dither fade so vanilla water (closer than `far`) owns its pixels.
    // (Dither + discard, not alpha blend: this writes the g-buffer opaquely so the
    // colortex2.b water flag below survives for d7's routing.)
    float dither   = interleavedGradientNoise(gl_FragCoord.xy, frameCounter);
    float nearFade = smoothstep(far * 0.5, far * 0.7, dist);
    if (nearFade < dither) discard;

    vec3  N        = worldNormal;
    vec3  viewDir  = normalize(playerPos);        // camera -> surface
    float cosT     = max(dot(N, -viewDir), 0.0);
    vec3  reflDir  = reflect(viewDir, N);

    // Single-scattering deep-water tint lit by sky ambient + a touch of direct.
    vec3 absorption  = vec3(WATER_ABSORPTION_R, WATER_ABSORPTION_G, WATER_ABSORPTION_B);
    vec3 scatterCoef = vec3(WATER_SCATTER_R, WATER_SCATTER_G, WATER_SCATTER_B);
    vec3 ssAlbedo    = scatterCoef / max(absorption + scatterCoef, vec3(1e-4));
    float skyOcc     = sqrt(lmCoord.y);
    vec3 shadow      = dhSunShadow(playerPos, N, lmCoord.y);
    float NdotL      = max(dot(N, worldLightVector), 0.0);
    vec3 deep = ssAlbedo * (ambientColor * skyOcc
                            + lightColor * shadow * NdotL * (1.0 - rainStrength * 0.75) * 0.25);

    // Sky reflection.
    float eyeAlt   = cameraPosition.y - 64.0;
    vec3  reflCol  = getSkyReflection(reflDir, eyeAlt);
    float fresnel  = 0.02 + 0.98 * pow(1.0 - cosT, 5.0);

    // Sun glint.
    float spec = pow(max(dot(reflDir, worldLightVector), 0.0), 200.0);
    vec3  glint = spec * lightColor * shadow * (1.0 - rainStrength * 0.9);

    vec3 color = mix(deep, reflCol, fresnel) + glint;

    // Opaque g-buffer write: colortex0 = forward-shaded water, colortex2.b = water
    // flag so d7 routes this pixel to passthrough (and c_water, gated to d0<1.0,
    // ignores it). d8/d9 still apply atmosphere / volumetric light on top.
    /* DRAWBUFFERS:02 */
    gl_FragData[0] = vec4(color, 1.0);
    gl_FragData[1] = vec4(lmCoord, 1.0, 0.0);
#endif
}

#endif
