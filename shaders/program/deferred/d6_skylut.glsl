// ============================================================================
//  d6_skylut : directional sky-irradiance LUT for GI
// ----------------------------------------------------------------------------
//  Renders a disc-free atmosphere into a SKY_LUT_RES x SKY_LUT_RES corner region
//  of colortex13, addressed octahedrally (texel ip <-> world direction). The GI
//  pass (d0_restir) samples this on the NEXT frame via sampleSkyLut() so its rays
//  get a real directional sky colour instead of a flat ambient tint. 1-frame sky
//  latency is imperceptible. Only the corner region does the (cheap, ~RES^2 px)
//  atmosphere march; the rest of the buffer is written 0.
// ============================================================================

#ifdef VERTEX

out vec2 texCoord;
out vec3 lightColor;
out vec3 ambientColor;
out vec3 lightVector;
out vec3 upVector;
out vec3 sunVector;
out vec3 moonVector;


void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    #include "/lib/vectors.glsl"
    #include "/lib/colors.glsl"
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"
#include "/lib/util/common.glsl"

in vec2 texCoord;
in vec3 lightColor;
in vec3 ambientColor;
in vec3 lightVector;
in vec3 upVector;
in vec3 sunVector;
in vec3 moonVector;


#include "/lib/fragment/sky.glsl"

void main() {
    #ifndef GI_SKY_DIRECTIONAL
        gl_FragData[0] = vec4(0.0);
        return;
    #endif

    ivec2 ip = ivec2(floor(gl_FragCoord.xy));
    if (ip.x >= SKY_LUT_RES || ip.y >= SKY_LUT_RES) {
        gl_FragData[0] = vec4(0.0);
        return;
    }

    vec2 o   = vec2(ip) / float(SKY_LUT_RES - 1);
    vec3 dir = octDecodeNormal(o);

    vec3 worldSunDir  = mat3(gbufferModelViewInverse) * sunVector;
    vec3 worldMoonDir = mat3(gbufferModelViewInverse) * moonVector;
    float eyeAltitude = cameraPosition.y - 64.0;

    vec3 sky = getSkyNoDisc(dir, worldSunDir, worldMoonDir, eyeAltitude);

    #if GI_SKY_WARMTH > 0
        // Instead of multiplying by lightColor (which gets extremely saturated at sunset),
        // we add a fixed warm offset to make the sky comfortably warm without blowing out.
        vec3 warmOffset = vec3(0.1, 0.03, 0.0);
        sky += warmOffset * (float(GI_SKY_WARMTH) / 100.0);
    #endif

    /* RENDERTARGETS: 13 */
    gl_FragData[0] = vec4(max(sky, 0.0), 1.0);
}

#endif
