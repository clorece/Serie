#include "/lib/options.glsl"

#ifdef VERTEX

#include "/lib/util/jitter.glsl"

const float PI = 3.14159265359;

out float material;
out float foliage;
out vec2 texCoord;
out vec2 lightmapCoord;
out vec3 normal;
out vec4 color;

attribute vec4 mc_Entity;

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
    if (mc_Entity.x == 10001) material = 2.0; // emissive
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
in float foliage;
in vec2 texCoord;
in vec2 lightmapCoord;
in vec3 normal;
in vec4 color;


void main() {
    vec4 albedo = texture(texture, texCoord) * color;
    
    /* DRAWBUFFERS:0124 */
    gl_FragData[0] = albedo;
    gl_FragData[1] = vec4(normal * 0.5 + 0.5, 1.0);
    gl_FragData[2] = vec4(lightmapCoord, 0.0, 1.0);
    gl_FragData[3] = vec4(material);
    gl_FragData[6] = color;
}

#endif
