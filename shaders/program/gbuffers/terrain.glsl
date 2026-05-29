#include "/lib/options.glsl"

#ifdef VERTEX

#include "/lib/util/jitter.glsl"



out float material;
out vec2 texCoord;
out vec2 lightmapCoord;
out vec3 normal;
out vec4 color;
flat out float isSolidIce;
out vec3 viewTangent;
out float tangentW;

attribute vec4 mc_Entity;
attribute vec4 at_tangent;

vec3 wind(vec3 position) {
    position.xy -= abs(sin(2.0 * PI * (frameTimeCounter * 0.7 + position.x /  11.0 + position.y / 5.0)) * 0.015);
    return position;
}

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;

    material = 0.0;
    
    color = gl_Color;

    if (mc_Entity.x == 10000) material = 1.0; // foliage 2 (leaves) - wrap-around NdotL
    if (mc_Entity.x == 10001 || (mc_Entity.x >= 10100 && mc_Entity.x <= 10199)) material = 2.0; // emissive
    if (mc_Entity.x == 10002) material = 0.0; // structural excluded (slabs, fences) - normal shading
    if (mc_Entity.x == 10005) material = 1.1; // grass, flowers (soft constant NdotL)

    #ifdef WIND_MOVEMENT
        if (mc_Entity.x == 10000 || mc_Entity.x == 10005) gl_Position.xyz = wind(gl_Position.xyz);
    #endif

    /*
    Normal and Lightmap Source Code By saada2006:
    https://github.com/saada2006/MinecraftShaderProgramming
    */
    normal = normalize(gl_NormalMatrix * gl_Normal);
    isSolidIce = (mc_Entity.x == 10008.0) ? 1.0 : 0.0; // packed_ice / blue_ice (opaque)
    viewTangent = normalize(gl_NormalMatrix * at_tangent.xyz);
    tangentW = at_tangent.w;
    lightmapCoord = mat2(gl_TextureMatrix[1]) * gl_MultiTexCoord1.st;

    #ifdef TAA
        gl_Position.xy += getTaaJitter() * 2.0 * gl_Position.w / vec2(viewWidth, viewHeight);
    #endif
}

#endif

#ifdef FRAGMENT

/*
Normal and Lightmap Source Code By saada2006:
https://github.com/saada2006/MinecraftShaderProgramming
*/

in float material;
in vec2 texCoord;
in vec2 lightmapCoord;
in vec3 normal;
in vec4 color;
flat in float isSolidIce;
in vec3 viewTangent;
in float tangentW;


void main() {
    vec4 albedo = texture(texture, texCoord) * color;
    
    // Material packed into colortex1.a (RGB10_A2 -> 2-bit alpha = 4 codes):
    //   material == 0.0 -> alpha 0    (normal/excluded)
    //   material == 1.0 -> alpha 1/3  (foliage leaves)
    //   material == 1.1 -> alpha 2/3  (grass / flowers)
    //   material == 2.0 -> alpha 3/3  (emissive)
    // Decoded in d7_composite. RGB10_A2 alpha rounds writes to {0, 1/3, 2/3, 1.0}
    // exactly, so the four codes survive storage.
    float matAlpha = (material >= 1.95) ? 1.0
                   : (material >= 1.05) ? (2.0 / 3.0)
                   : (material >= 0.95) ? (1.0 / 3.0)
                   :                       0.0;

    // Packed/blue ice (opaque, id 10008): GENERATED NORMALS from the texture luminance gradient
    // (tangent space) for surface relief, and colortex2.b = 0.25 so c_water adds a glossy reflection
    // on top of the lit ice. All other opaque blocks are unchanged.
    vec3  outNormal = normal;
    float iceFlag   = 0.0;
    if (isSolidIce > 0.5) {
        const float ICE_NORMAL_STRENGTH = 2.0;
        const vec3  LUMA = vec3(0.2126, 0.7152, 0.0722);
        vec2  atlasTexel = 1.0 / vec2(textureSize(texture, 0));
        float l  = dot(albedo.rgb, LUMA);
        float lu = dot((texture(texture, texCoord + vec2(atlasTexel.x, 0.0)) * color).rgb, LUMA);
        float lv = dot((texture(texture, texCoord + vec2(0.0, atlasTexel.y)) * color).rgb, LUMA);
        vec3 T = normalize(viewTangent);
        vec3 B = normalize(cross(normal, T) * tangentW);
        outNormal = normalize(normal - ICE_NORMAL_STRENGTH * ((lu - l) * T + (lv - l) * B));
        iceFlag = 0.25;
    }

    /* DRAWBUFFERS:012 */
    gl_FragData[0] = albedo;
    gl_FragData[1] = vec4(outNormal * 0.5 + 0.5, matAlpha);
    gl_FragData[2] = vec4(lightmapCoord, iceFlag, 1.0);
}

#endif
