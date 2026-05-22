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
uniform float aspectRatio;
uniform ivec2 eyeBrightnessSmooth;
uniform sampler2D colortex0; // Resolved HDR scene color (contains exposure in alpha)
uniform sampler2D colortex3; // Gaussian blurred bloom color
uniform sampler2D colortex4;

#include "/lib/util/common.glsl"
#include "/lib/util/dither.glsl"
#include "/lib/post/tonemap.glsl"

void main() {
    // ----------------------------------------------------
    // SCENE & EXPOSURE FETCH
    // ----------------------------------------------------
    vec3 sceneColor = texture(colortex0, texCoord).rgb;
    
    // Apply dynamic camera-like temporal auto-exposure with manual bias
    float totalExposure = EXPOSURE;
    #ifdef AUTO_EXPOSURE
    float autoExposure = texelFetch(colortex0, ivec2(0), 0).a;
    if (autoExposure > 0.001 && !isnan(autoExposure) && !isinf(autoExposure)) {
        totalExposure *= autoExposure;
    }
    #endif
    
    sceneColor *= totalExposure;

    // ----------------------------------------------------
    // BLOOM BLENDING
    // ----------------------------------------------------
    #ifdef BLOOM
    vec3 bloomColor = texture(colortex3, texCoord).rgb;
    // Apply exposure to bloom since it was extracted from raw HDR scene color
    sceneColor += (bloomColor * totalExposure) * BLOOM_STRENGTH;
    #endif

    vec3 color = sceneColor;

    // ----------------------------------------------------
    // CINEMATIC COLOR GRADING SUITE (HDR Pass)
    // ----------------------------------------------------
    // 1. Color Temperature / White Balance Shifting (HDR space)
    vec3 tempShift = vec3(1.0);
    if (COLOR_TEMP > 0.0) {
        tempShift = vec3(1.0 + COLOR_TEMP * 0.25, 1.0 + COLOR_TEMP * 0.08, 1.0 - COLOR_TEMP * 0.25);
    } else {
        tempShift = vec3(1.0 + COLOR_TEMP * 0.25, 1.0 + COLOR_TEMP * 0.08, 1.0 - COLOR_TEMP * 0.35);
    }
    color = clamp(color * tempShift, 0.0, 10.0);

    // 2. Cinematic Lens Vignette (HDR space)
    #ifdef VIGNETTE
    vec2 vignCoord = texCoord * (1.0 - texCoord.yx);
    float vign = vignCoord.x * vignCoord.y * 15.0;
    vign = clamp(pow(vign, 0.25), 0.0, 1.0);
    color *= vign;
    #endif

    // ----------------------------------------------------
    // TONEMAPPING (HDR -> LDR)
    // ----------------------------------------------------
    color = applyTonemap(color);

    // ----------------------------------------------------
    // CINEMATIC COLOR GRADING SUITE (LDR Pass for deep blacks & vibrant punch)
    // ----------------------------------------------------
    // 3. Contrast (pivot around middle LDR gray 0.5)
    color = clamp((color - vec3(0.5)) * COLOR_CONTRAST + vec3(0.5), 0.0, 1.0);
    
    // 4. Saturation (luminance-based blend in LDR space)
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));
    color = clamp(mix(vec3(luma), color, COLOR_SATURATION), 0.0, 1.0);

    // Apply standard sRGB gamma correction with a 5% boost for lighter midtones (2.09)
    color = pow(color, vec3(1.0 / 2.09));

    // ----------------------------------------------------
    // SPATIAL DITHERING (ANTI-BANDING)
    // ----------------------------------------------------
    // Apply low-frequency spatial noise to eliminate color banding in dark gradients
    color += vec3(dither) / 255.0;

    gl_FragColor = vec4(clamp(color, 0.0, 1.0), 1.0);
}
