#ifdef VERTEX

out vec2 texCoord;

void main() {
    gl_Position = ftransform();
    texCoord = gl_MultiTexCoord0.xy;
}

#endif

#ifdef FRAGMENT

#include "/lib/options.glsl"

in vec2 texCoord;

// LUT code/asset credit: Query. Ported from Allium's Luts2.png color-grading path.
void applyLookupTable(inout vec3 color) {
    const vec2 inverseSize = vec2(1.0 / 512.0, 1.0 / 5120.0);

    const mat2 correctGrid = mat2(
        vec2(1.0, inverseSize.y * 512.0),
        vec2(0.0, float(OVERWORLD_LUT) * inverseSize.y * 512.0)
    );

    vec3 originalColor = color;
    color = clamp(color, 0.0, 1.0);

    float blueColor = color.b * 63.0;

    vec4 quad = vec4(0.0);
    quad.y = floor(floor(blueColor) * 0.125);
    quad.x = floor(blueColor) - (quad.y * 8.0);
    quad.w = floor(ceil(blueColor) * 0.125);
    quad.z = ceil(blueColor) - (quad.w * 8.0);

    vec4 texPos = (quad * 0.125) + (0.123046875 * color.rg).xyxy + 0.0009765625;

    vec3 lutColor1 = texture(colortex6, texPos.xy * correctGrid[0] + correctGrid[1]).rgb;
    vec3 lutColor2 = texture(colortex6, texPos.zw * correctGrid[0] + correctGrid[1]).rgb;
    vec3 lutColor = mix(lutColor1, lutColor2, fract(blueColor));

    color = mix(originalColor, lutColor, OVERWORLD_LUT_I);
}

#include "/lib/util/common.glsl"
#include "/lib/util/dither.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/sharpen.glsl"

void main() {
    #if defined(TAA) && TAA_SHARPNESS > 0.0
    vec4 sceneColor = vec4(casSharpen(colortex0, texCoord, vec2(viewWidth, viewHeight), TAA_SHARPNESS), texture(colortex0, texCoord).a);
    #else
    vec4 sceneColor = texture(colortex0, texCoord);
    #endif

    #if FILM_GRAIN_I > 0
    float noise = fract(sin(dot((texCoord * RENDER_SCALE) * sin(frameTimeCounter) + 1.0, vec2(12.9898, 78.233) * 2.0)) * 43758.5453);
    sceneColor.rgb *= max(noise, 1.0 - (float(FILM_GRAIN_I) / 10.0));
    sceneColor.rgb *= 1.3;
    #endif

    vec3 color = sceneColor.rgb;

    float totalExposure = EXPOSURE;
    #ifdef AUTO_EXPOSURE
    float autoExposure = texelFetch(colortex0, ivec2(0), 0).a;
    if (autoExposure > 0.001 && !isnan(autoExposure) && !isinf(autoExposure)) {
        totalExposure *= autoExposure;
    }
    #endif

    color *= totalExposure;

    #ifdef BLOOM
    vec3 bloomColor = ReadBloomAtlas(colortex3, texCoord) * totalExposure;
    color = mix(color, bloomColor, BLOOM_STRENGTH);
    #endif

    vec3 tempShift = vec3(1.0);
    if (COLOR_TEMP > 0.0) {
        tempShift = vec3(1.0 + COLOR_TEMP * 0.25, 1.0 + COLOR_TEMP * 0.08, 1.0 - COLOR_TEMP * 0.25);
    } else {
        tempShift = vec3(1.0 + COLOR_TEMP * 0.25, 1.0 + COLOR_TEMP * 0.08, 1.0 - COLOR_TEMP * 0.35);
    }
    color = clamp(color * tempShift, 0.0, 10.0);

    #ifdef VIGNETTE
    vec2 vignCoord = texCoord * (1.0 - texCoord.yx);
    float vign = vignCoord.x * vignCoord.y * 15.0;
    vign = clamp(pow(vign, 0.25), 0.0, 1.0);
    color *= vign;
    #endif

    color = applyTonemap(color);

    color = clamp((color - vec3(0.5)) * COLOR_CONTRAST + vec3(0.5), 0.0, 1.0);

    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = clamp(mix(vec3(luma), color, COLOR_SATURATION), 0.0, 1.0);

    color = pow(color, vec3(1.0 / 2.09));

    if (OVERWORLD_LUT_I > 0.0) {
        applyLookupTable(color);
    }

    color += vec3(dither) / 255.0;

    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(clamp(color, 0.0, 1.0), 1.0);
}

#endif
