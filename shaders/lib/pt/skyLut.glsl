#ifndef SKYLUT_GLSL
#define SKYLUT_GLSL

// ============================================================================
//  Octahedral sky-irradiance LUT addressing
// ----------------------------------------------------------------------------
//  d6_skylut renders a disc-free directional sky into a SKY_LUT_RES x SKY_LUT_RES
//  corner region of colortex13 (texel ip <-> octahedral direction). GI rays sample
//  it with a cheap texture fetch instead of re-marching the atmosphere per ray.
//  Requires common.glsl (octEncodeNormal/octDecodeNormal, viewWidth/viewHeight)
//  and options.glsl (SKY_LUT_RES) to be included first.
// ============================================================================

// Direction -> screen UV inside the LUT corner region. Matches d6_skylut's
// generation mapping: texel ip stores octEncodeNormal direction o = ip/(RES-1).
vec2 skyLutSampleUV(vec3 dir) {
    vec2 px = octEncodeNormal(normalize(dir)) * float(SKY_LUT_RES - 1) + 0.5;
    return px / vec2(viewWidth, viewHeight);
}

vec3 sampleSkyLut(sampler2D lut, vec3 dir) {
    vec3 s = textureLod(lut, skyLutSampleUV(dir), 0.0).rgb;
    s = max(s, vec3(0.0));
    if (any(isnan(s)) || any(isinf(s))) s = vec3(0.0); // guard uninitialised first frame
    return s;
}

#endif
