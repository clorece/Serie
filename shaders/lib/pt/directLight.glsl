#ifndef PT_DIRECT_LIGHT_GLSL
#define PT_DIRECT_LIGHT_GLSL

// Sun/moon direction and colour, in WORLD space, callable from anywhere.
// ---------------------------------------------------------------------------
// lib/vectors.glsl and lib/colors.glsl compute the same quantities, but they are
// straight-line code #included into a vertex main() that assigns to `out`
// variables -- unusable from a compute pass. This is the same maths in function
// form.
//
// The originals work in VIEW space: sunPosition is an eye-space vector, and
// d7_composite pairs it with the view-space normals in colortex1. The surface
// cache and every voxel-space consumer needs world space, so the direction is
// rotated through gbufferModelViewInverse here. Getting this wrong tilts the sun
// with the camera, which looks almost right while standing still.

#include "/lib/options.glsl"

// World-space direction TOWARD the dominant celestial light.
vec3 ptWorldLightVector() {
    // Same 23250 < worldTime < 12700 handover as lib/vectors.glsl.
    vec3 viewLight = (worldTime < 12700 || worldTime > 23250)
                   ? normalize(sunPosition)
                   : normalize(-sunPosition);
    return normalize(mat3(gbufferModelViewInverse) * viewLight);
}

// Direct light colour, matching lib/colors.glsl exactly (sun + moon, each gated
// by its own activity curve so twilight blends rather than snaps).
vec3 ptLightColor() {
    vec3 sunVector  = normalize(sunPosition);
    vec3 moonVector = normalize(-sunPosition);
    vec3 upVector   = normalize(upPosition);

    float sunUp  = dot(sunVector,  upVector);
    float moonUp = dot(moonVector, upVector);

    float sunActivity  = smoothstep(-0.1, 0.16, sunUp);
    float moonActivity = smoothstep(-0.1, 0.10, moonUp);

    vec3 sunColorBase  = mix(vec3(1.0, 0.65, 0.35) * 0.15, vec3(1.0, 0.95, 0.9), max(sunUp, 0.0));
    vec3 moonColorBase = vec3(0.65, 0.85, 1.0) * 0.02;

    return sunColorBase * sunActivity + moonColorBase * moonActivity;
}

// Eye altitude argument expected by the atmosphere LUT samplers.
float ptEyeAltitude() { return cameraPosition.y - 64.0; }

#endif
