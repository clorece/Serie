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
   

#include "/lib/util/common.glsl"
#include "/lib/post/taa.glsl"

void main() {
    vec2 currentPos = texCoord / texelSize;

    #ifdef TAA
        vec4 finalColor = taa(currentPos, vec2(viewWidth, viewHeight), colortex0, colortex5);
    #else
        vec4 finalColor = texture(colortex0, texCoord);
    #endif
    
    float prevExposure = texelFetch(colortex5, ivec2(0), 0).a;
    if (prevExposure <= 0.001 || isnan(prevExposure) || isinf(prevExposure)) {
        prevExposure = 1.0;
    }
    
    float exposure = prevExposure;
    
    #ifdef AUTO_EXPOSURE
    if (ivec2(gl_FragCoord.xy) == ivec2(0)) {
        float sumLuma = 0.0;
        float totalWeight = 0.0;

        for (float x = -0.01; x <= 0.011; x += 0.01) {
            for (float y = -0.01; y <= 0.011; y += 0.01) {
                vec2 uv = vec2(0.5) + vec2(x, y);
                vec3 rawColor = texture(colortex0, uv).rgb;
                float luma = dot(rawColor, vec3(0.2126, 0.7152, 0.0722));
                
                sumLuma += log2(max(luma, 0.0001));
                totalWeight += 1.0;
            }
        }
        
        float avgLuma = exp2(sumLuma / totalWeight);
        avgLuma = clamp(avgLuma, 0.001, 10.0);

        float targetExposure = AUTO_EXPOSURE_TARGET / avgLuma;
        

        targetExposure = clamp(targetExposure, AUTO_EXPOSURE_MIN, AUTO_EXPOSURE_MAX);

        float rate = targetExposure > prevExposure ? 1.0 : 2.0;
        rate *= AUTO_EXPOSURE_SPEED;
        exposure = mix(prevExposure, targetExposure, 1.0 - exp(-rate * frameTime));
    }
    #else
    exposure = EXPOSURE;
    #endif
    
    /* DRAWBUFFERS:0 */
    gl_FragData[0] = vec4(finalColor.rgb, exposure);
}

#endif
